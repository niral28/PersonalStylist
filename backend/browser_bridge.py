"""Backend <-> Chrome extension action queue (same protocol as moodboard).

The agent enqueues `{id, tool, args}`; the extension polls GET /extension/pending-actions,
executes in visible Chrome, and POSTs /browser/result {action_id, result?, error?}.
Tools: open_tab, extract_products, scroll, click, google_search.
"""

from __future__ import annotations

import asyncio
import logging
import os
import time
import uuid
from typing import Any, Dict, List, Optional

logger = logging.getLogger("stylist.browser_bridge")

# none | extension | cdp. Unset = use the extension when connected, else HTTP fallback.
BROWSER_BACKEND = os.environ.get("BROWSER_BACKEND", "").strip().lower()
ACTION_TIMEOUT_SEC = float(os.environ.get("BROWSER_ACTION_TIMEOUT", "60"))

_TOOL_TIMEOUTS: Dict[str, float] = {
    "open_tab": 45.0,
    "google_search": 40.0,
    "click": 20.0,
    "scroll": 20.0,
    "extract_products": 30.0,
}

_pending: Dict[str, asyncio.Future] = {}
_queued: Dict[str, Dict[str, Any]] = {}
_extension_last_seen: float = 0.0
_extension_version: Optional[str] = None


def mark_extension_connected(version: Optional[str] = None) -> None:
    global _extension_last_seen, _extension_version
    _extension_last_seen = time.time()
    if version:
        _extension_version = version


def extension_connected(within_sec: float = 30.0) -> bool:
    return _extension_last_seen > 0 and (time.time() - _extension_last_seen) < within_sec


def use_extension() -> bool:
    if BROWSER_BACKEND == "none":
        return False
    return extension_connected()


def browser_mode() -> str:
    """Value for /health `browser`."""
    if use_extension():
        return "extension"
    if BROWSER_BACKEND == "cdp":
        return "cdp"
    return "none"


def pending_actions() -> List[Dict[str, Any]]:
    return list(_queued.values())


def resolve_action(action_id: str, result: Optional[Dict[str, Any]] = None, error: Optional[str] = None) -> bool:
    _queued.pop(action_id, None)
    fut = _pending.pop(action_id, None)
    if fut is None or fut.done():
        logger.warning("browser result for unknown/settled action %s", action_id)
        return False
    fut.set_result({"error": error} if error else (result if isinstance(result, dict) else {"result": result}))
    return True


async def dispatch(tool: str, args: Optional[Dict[str, Any]] = None, timeout: Optional[float] = None) -> Dict[str, Any]:
    """Queue an action for the extension and wait for its result."""
    if not extension_connected():
        return {"error": "Chrome extension not connected"}
    action_id = uuid.uuid4().hex
    fut: asyncio.Future = asyncio.get_running_loop().create_future()
    _pending[action_id] = fut
    _queued[action_id] = {"id": action_id, "action_id": action_id, "tool": tool, "args": args or {}}
    try:
        return await asyncio.wait_for(fut, timeout=timeout or _TOOL_TIMEOUTS.get(tool, ACTION_TIMEOUT_SEC))
    except asyncio.TimeoutError:
        return {"error": f"extension action timed out ({tool})"}
    finally:
        _pending.pop(action_id, None)
        _queued.pop(action_id, None)
