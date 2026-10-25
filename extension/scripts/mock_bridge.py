#!/usr/bin/env python3
"""Mock PersonalStylist browser bridge for manually testing the Stylist extension.

Serves the bridge endpoints on :8000 (stop the real backend first), queues a
scripted sequence of actions, and prints each result the extension POSTs back.

    python3 extension/scripts/mock_bridge.py
    python3 extension/scripts/mock_bridge.py --url https://www.patagonia.com/product/mens-better-sweater-fleece-jacket/25528.html
    python3 extension/scripts/mock_bridge.py --search "olive waxed cotton chore jacket" --scroll --legacy-shape

Stdlib only; no dependencies.
"""

from __future__ import annotations

import argparse
import json
import socket
import threading
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any, Dict, List, Optional

DEFAULT_URL = "https://www.patagonia.com/product/mens-better-sweater-fleece-jacket/25528.html"

lock = threading.Lock()
script: List[Dict[str, Any]] = []
queued: Optional[Dict[str, Any]] = None
last_hello = 0.0
legacy_shape = False


class DualStackServer(ThreadingHTTPServer):
    """Listen on both ::1 and 127.0.0.1 since Chrome may resolve localhost to either."""

    address_family = socket.AF_INET6

    def server_bind(self) -> None:
        self.socket.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 0)
        super().server_bind()


def make_action(tool: str, args: Dict[str, Any]) -> Dict[str, Any]:
    action_id = str(uuid.uuid4())
    if legacy_shape:
        return {"kind": "browser_action", "action_id": action_id, "scout_id": "mock", "tool": tool, "args": args}
    return {"id": action_id, "tool": tool, "args": args}


def action_id_of(action: Dict[str, Any]) -> str:
    return action.get("action_id") or action["id"]


def queue_next() -> None:
    global queued
    if not script:
        queued = None
        print("\n[mock] script complete. Ctrl+C to exit.")
        return
    step = script.pop(0)
    queued = make_action(step["tool"], step["args"])
    print(f"\n[mock] queued {queued['tool']} {json.dumps(queued['args'])}  id={action_id_of(queued)}")


def truncate(obj: Any, max_str: int = 300) -> Any:
    if isinstance(obj, str):
        return obj if len(obj) <= max_str else obj[:max_str] + f"… (+{len(obj) - max_str} chars)"
    if isinstance(obj, list):
        out = [truncate(x, max_str) for x in obj[:10]]
        if len(obj) > 10:
            out.append(f"… (+{len(obj) - 10} items)")
        return out
    if isinstance(obj, dict):
        return {k: truncate(v, max_str) for k, v in obj.items()}
    return obj


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt: str, *args: Any) -> None:  # silence per-request logs (polling is 1/s)
        pass

    def _send(self, status: int, body: Any) -> None:
        data = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()
        self.wfile.write(data)

    def _json_body(self) -> Dict[str, Any]:
        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length) if length else b"{}"
        try:
            return json.loads(raw or b"{}")
        except json.JSONDecodeError:
            return {}

    def do_OPTIONS(self) -> None:
        self.send_response(204)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type")
        self.end_headers()

    def do_GET(self) -> None:
        global last_hello
        if self.path.startswith("/extension/pending-actions"):
            with lock:
                if last_hello == 0:
                    print("[mock] extension polling")
                last_hello = time.time()
                actions = [queued] if queued else []
            self._send(200, {"actions": actions})
        elif self.path.startswith("/health"):
            connected = time.time() - last_hello < 120
            self._send(200, {"ok": True, "browser": "extension" if connected else "none", "extension_connected": connected})
        else:
            self._send(404, {"detail": "not found"})

    def do_POST(self) -> None:
        global last_hello
        body = self._json_body()
        if self.path.startswith("/extension/hello"):
            with lock:
                if last_hello == 0:
                    print(f"[mock] extension hello v{body.get('version')}")
                last_hello = time.time()
            self._send(200, {"ok": True})
        elif self.path.startswith("/browser/result"):
            with lock:
                aid = body.get("action_id")
                if not queued or aid != action_id_of(queued):
                    self._send(200, {"ok": False, "error": "unknown or expired action_id"})
                    return
                tool = queued["tool"]
                print(f"[mock] result for {tool} ({aid}):")
                if body.get("error"):
                    print(f"  error: {body['error']}")
                result = body.get("result") or {}
                print(json.dumps(truncate(result), indent=2))
                if result.get("tab_id") and script:
                    for step in script:
                        if step["tool"] in ("extract_products", "scroll", "click"):
                            step["args"].setdefault("tab_id", result["tab_id"])
                queue_next()
            self._send(200, {"ok": True})
        else:
            self._send(404, {"detail": "not found"})


def main() -> None:
    global legacy_shape
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--url", default=DEFAULT_URL, help="product page for open_tab")
    p.add_argument("--search", help="also run google_search with this query first")
    p.add_argument("--scroll", action="store_true", help="also run scroll after extraction")
    p.add_argument("--legacy-shape", action="store_true", help="queue moodboard-style {kind, action_id, scout_id, tool, args}")
    p.add_argument("--port", type=int, default=8000)
    a = p.parse_args()
    legacy_shape = a.legacy_shape

    if a.search:
        script.append({"tool": "google_search", "args": {"query": a.search}})
    script.append({"tool": "open_tab", "args": {"url": a.url}})
    script.append({"tool": "extract_products", "args": {}})
    if a.scroll:
        script.append({"tool": "scroll", "args": {"direction": "down", "amount_px": 900}})

    with lock:
        queue_next()
    server = DualStackServer(("::", a.port), Handler)
    print(f"[mock] listening on http://localhost:{a.port} — waiting for the Stylist extension to poll…")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
