"""JSON-file persistence in backend/data/state.json. Single process, guarded by a lock."""

from __future__ import annotations

import copy
import json
import os
import shutil
import threading
from datetime import datetime, timezone
from typing import Any, Dict, List, Optional

BASE_DIR = os.path.dirname(os.path.abspath(__file__))
DATA_DIR = os.path.join(BASE_DIR, "data")
CROPS_DIR = os.path.join(DATA_DIR, "crops")
UPLOADS_DIR = os.path.join(DATA_DIR, "uploads")
RENDERS_DIR = os.path.join(DATA_DIR, "renders")
STATE_PATH = os.path.join(DATA_DIR, "state.json")
DEMO_DIR = os.path.join(DATA_DIR, "demo")

for _d in (DATA_DIR, CROPS_DIR, UPLOADS_DIR, RENDERS_DIR):
    os.makedirs(_d, exist_ok=True)

_lock = threading.RLock()


def _empty() -> Dict[str, Any]:
    return {
        "user": {},
        "closet": [],
        "profile": None,
        "feedback": [],
        "ingested": {},  # asset_id -> {items: [ids], skipped, reason}
        "candidates": {},  # candidate_id -> Candidate
        "looks": [],  # saved try-ons, newest first
    }


def _load() -> Dict[str, Any]:
    if not os.path.exists(STATE_PATH):
        return _empty()
    try:
        with open(STATE_PATH) as f:
            data = json.load(f)
        base = _empty()
        base.update(data)
        return base
    except Exception:
        return _empty()


_state: Dict[str, Any] = _load()


def _save() -> None:
    tmp = STATE_PATH + ".tmp"
    with open(tmp, "w") as f:
        json.dump(_state, f, indent=1)
    os.replace(tmp, STATE_PATH)


def now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


# --- user ---------------------------------------------------------------------
def get_user() -> Dict[str, Any]:
    with _lock:
        return copy.deepcopy(_state["user"])


def update_user(fields: Dict[str, Any]) -> Dict[str, Any]:
    with _lock:
        for k, v in fields.items():
            if v is not None:
                _state["user"][k] = v
        _save()
        return copy.deepcopy(_state["user"])


# --- closet -------------------------------------------------------------------
def get_closet() -> List[Dict[str, Any]]:
    with _lock:
        return copy.deepcopy(_state["closet"])


def get_item(item_id: str) -> Optional[Dict[str, Any]]:
    with _lock:
        for it in _state["closet"]:
            if it["id"] == item_id:
                return copy.deepcopy(it)
    return None


def add_items(items: List[Dict[str, Any]]) -> None:
    with _lock:
        _state["closet"].extend(copy.deepcopy(items))
        _save()


def set_item_signal(item_id: str, signal: str) -> Optional[Dict[str, Any]]:
    with _lock:
        for it in _state["closet"]:
            if it["id"] == item_id:
                it["signal"] = signal
                _save()
                return copy.deepcopy(it)
    return None


def forget_ingested(asset_id: str) -> None:
    with _lock:
        _state["ingested"].pop(asset_id, None)
        _save()


def delete_item(item_id: str) -> bool:
    with _lock:
        before = len(_state["closet"])
        _state["closet"] = [i for i in _state["closet"] if i["id"] != item_id]
        _save()
        return len(_state["closet"]) < before


# --- ingest idempotency -------------------------------------------------------
def get_ingested(asset_id: str) -> Optional[Dict[str, Any]]:
    with _lock:
        rec = _state["ingested"].get(asset_id)
        return copy.deepcopy(rec) if rec else None


def all_ingested() -> Dict[str, Any]:
    with _lock:
        return copy.deepcopy(_state["ingested"])


def mark_ingested(
    asset_id: str,
    item_ids: List[str],
    skipped: bool,
    reason: Optional[str],
    upload_url: Optional[str] = None,
) -> None:
    with _lock:
        rec: Dict[str, Any] = {"items": item_ids, "skipped": skipped, "reason": reason}
        if upload_url:
            rec["upload_url"] = upload_url
        _state["ingested"][asset_id] = rec
        _save()


# --- taste profile ------------------------------------------------------------
def get_profile() -> Optional[Dict[str, Any]]:
    with _lock:
        return copy.deepcopy(_state["profile"])


def set_profile(profile: Dict[str, Any]) -> None:
    with _lock:
        _state["profile"] = copy.deepcopy(profile)
        _save()


# --- feedback + candidates ----------------------------------------------------
def add_feedback(entry: Dict[str, Any]) -> None:
    with _lock:
        _state["feedback"].append(copy.deepcopy(entry))
        _save()


def recent_feedback(limit: int = 20) -> List[Dict[str, Any]]:
    with _lock:
        return copy.deepcopy(_state["feedback"][-limit:])


def save_candidate(cand: Dict[str, Any]) -> None:
    with _lock:
        _state["candidates"][cand["id"]] = copy.deepcopy(cand)
        _save()


def get_candidate(cid: str) -> Optional[Dict[str, Any]]:
    with _lock:
        c = _state["candidates"].get(cid)
        return copy.deepcopy(c) if c else None


def get_blob(key: str) -> Any:
    with _lock:
        return copy.deepcopy(_state.get(key))


def set_blob(key: str, value: Any) -> None:
    with _lock:
        _state[key] = copy.deepcopy(value)
        _save()


def get_looks() -> List[Dict[str, Any]]:
    with _lock:
        return copy.deepcopy(_state.get("looks") or [])


def save_look(look: Dict[str, Any]) -> Dict[str, Any]:
    with _lock:
        looks = _state.setdefault("looks", [])
        for existing in looks:
            if existing.get("candidate_id") == look.get("candidate_id") and existing.get("image_url") == look.get("image_url"):
                return copy.deepcopy(existing)
        looks.insert(0, copy.deepcopy(look))
        _save()
        return copy.deepcopy(look)


def update_look(look_id: str, fields: Dict[str, Any]) -> Optional[Dict[str, Any]]:
    with _lock:
        for look in _state.setdefault("looks", []):
            if look.get("id") == look_id:
                look.update(fields)
                _save()
                return copy.deepcopy(look)
    return None


def delete_look(look_id: str) -> bool:
    with _lock:
        looks = _state.setdefault("looks", [])
        before = len(looks)
        _state["looks"] = [l for l in looks if l.get("id") != look_id]
        _save()
        return len(_state["looks"]) < before


def reset() -> None:
    global _state
    with _lock:
        user = _state.get("user") or {}
        _state = _empty()
        _state["user"] = user
        _save()
        for d in (CROPS_DIR,):
            for name in os.listdir(d):
                try:
                    os.remove(os.path.join(d, name))
                except OSError:
                    pass


def _collect_media_urls(value: Any, found: set) -> None:
    if isinstance(value, str) and value.startswith(("/crops/", "/uploads/", "/renders/")):
        found.add(value.split("?", 1)[0])
    elif isinstance(value, dict):
        for child in value.values():
            _collect_media_urls(child, found)
    elif isinstance(value, list):
        for child in value:
            _collect_media_urls(child, found)


def _demo_payload() -> Dict[str, Any]:
    with _lock:
        if not _state.get("closet"):
            raise ValueError("closet is empty")
        return {
            "closet": copy.deepcopy(_state.get("closet") or []),
            "profile": copy.deepcopy(_state.get("profile")),
            "feedback": copy.deepcopy(_state.get("feedback") or []),
            "ingested": copy.deepcopy(_state.get("ingested") or {}),
            "candidates": copy.deepcopy(_state.get("candidates") or {}),
            "looks": copy.deepcopy(_state.get("looks") or []),
            "tryon_bases": copy.deepcopy(_state.get("tryon_bases")),
            "saved_at": now_iso(),
        }


def demo_status() -> Dict[str, Any]:
    path = os.path.join(DEMO_DIR, "state.json")
    if not os.path.exists(path):
        return {"ready": False, "items": 0, "looks": 0, "saved_at": None}
    try:
        with open(path) as f:
            data = json.load(f)
    except (OSError, json.JSONDecodeError):
        return {"ready": False, "items": 0, "looks": 0, "saved_at": None}
    return {
        "ready": True,
        "items": len(data.get("closet") or []),
        "looks": len(data.get("looks") or []),
        "saved_at": data.get("saved_at"),
    }


def snapshot_demo() -> Dict[str, Any]:
    """Copy the live closet aside so onboarding can skip the scan later. Reset does not touch this."""
    payload = _demo_payload()
    urls: set = set()
    _collect_media_urls(payload, urls)
    tmp = DEMO_DIR + ".tmp"
    if os.path.exists(tmp):
        shutil.rmtree(tmp)
    files_root = os.path.join(tmp, "files")
    os.makedirs(files_root, exist_ok=True)
    for url in urls:
        src = os.path.join(DATA_DIR, url.lstrip("/"))
        if not os.path.isfile(src):
            continue
        dest = os.path.join(files_root, url.lstrip("/"))
        os.makedirs(os.path.dirname(dest), exist_ok=True)
        shutil.copy2(src, dest)
    with open(os.path.join(tmp, "state.json"), "w") as f:
        json.dump(payload, f)
    if os.path.exists(DEMO_DIR):
        shutil.rmtree(DEMO_DIR)
    os.rename(tmp, DEMO_DIR)
    return demo_status()


def restore_demo() -> Dict[str, Any]:
    """Put the prepared closet back. Keeps the selfie and sizes from the onboarding just shown."""
    path = os.path.join(DEMO_DIR, "state.json")
    if not os.path.exists(path):
        raise ValueError("no prepared closet")
    with open(path) as f:
        payload = json.load(f)
    files_root = os.path.join(DEMO_DIR, "files")
    if os.path.isdir(files_root):
        for dirpath, _, names in os.walk(files_root):
            for name in names:
                src = os.path.join(dirpath, name)
                rel = os.path.relpath(src, files_root)
                dest = os.path.join(DATA_DIR, rel)
                os.makedirs(os.path.dirname(dest), exist_ok=True)
                shutil.copy2(src, dest)
    with _lock:
        user = _state.get("user") or {}
        for key in ("closet", "profile", "feedback", "ingested", "candidates", "looks", "tryon_bases"):
            if key in payload:
                _state[key] = copy.deepcopy(payload[key])
        _state["user"] = user
        _save()
    return demo_status()
