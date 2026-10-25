# Stylist Chrome extension

MV3 extension that lets the PersonalStylist backend drive your real, visible Chrome. The backend queues browser actions; the extension opens tabs in a **Stylist** tab group, extracts product data, and posts results back. There is no new-tab override or canvas UI here — the iOS app is the UI.

## Build & load

```bash
cd extension
npm install
npm run build        # tsc --noEmit && vite build -> extension/dist
```

1. Open `chrome://extensions`
2. Turn on **Developer mode** (top right)
3. **Load unpacked** and pick `extension/dist`
4. Pin **Stylist** from the puzzle-piece menu. The popup shows backend status, recent actions, and a **Close Stylist tabs** button.
5. Backend URL defaults to `http://localhost:8000`. Change it in **Settings** (popup) or the extension's Options page.

After rebuilding, click the reload icon on the extension card. `npm run dev` gives HMR while you iterate.

## How it talks to the backend

Same protocol as moodboard's `browser_bridge.py`, polling only (no SSE):

| Call | When |
| --- | --- |
| `POST /extension/hello` `{ version }` | on start, every ~10 s, and on each `chrome.alarms` keepalive (30 s) |
| `GET /extension/pending-actions` -> `{ actions: [...] }` | every 1 s while online, every 4 s while the backend is unreachable |
| `POST /browser/result` `{ action_id, result, error? }` | once per action |

Queued actions may be `{ id, tool, args }` (AGENTS.md) or moodboard-style `{ kind: "browser_action", action_id, scout_id, tool, args }`. Actions are de-duplicated by id, so the backend can leave an action in the queue until its result arrives.

Supported tools: `open_tab` (alias `open_link`), `extract_products` (alias `extract_page`), `google_search`, `scroll` (alias `scroll_and_capture`), `click`. New tabs open active (visible) by default (pass `args.active: false` to suppress), join the Stylist group, and the group is capped at 6 tabs (oldest closed first). Tools without `tab_id` act on the most recently opened Stylist tab.

## Manual test with the mock bridge

Stop the real backend (both use port 8000), then:

```bash
python3 extension/scripts/mock_bridge.py                       # open_tab -> extract_products on a Patagonia product page
python3 extension/scripts/mock_bridge.py --url https://...     # any product URL
python3 extension/scripts/mock_bridge.py --search "olive chore jacket" --scroll
python3 extension/scripts/mock_bridge.py --legacy-shape        # queue moodboard-style actions
```

Within a few seconds a tab should open in the Stylist group, and the mock prints each result JSON (long strings truncated). If nothing happens, open the popup (it wakes the service worker), or inspect the worker from `chrome://extensions` -> Stylist -> "service worker".
