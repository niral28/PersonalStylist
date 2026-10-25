# PersonalStylist

Hackathon MVP (Gemini 4 Argon, 1 day). iPhone app scans the camera roll, builds a virtual closet + taste profile, and a chat shopping agent finds items on the web, optionally driving visible laptop Chrome.

## Layout

- `PersonalStylist/` — SwiftUI iOS 18.2 app. Xcode 16 file-system-synchronized groups: any `.swift` file added under `PersonalStylist/` is compiled automatically (no pbxproj edits needed).
- `backend/` — FastAPI (Python 3.12+), Gemini via `google-genai>=2.3.0` Interactions API. Runs on the laptop at port 8000.
- `extension/` — Chrome MV3 extension ("Stylist") that executes browser actions for the backend agent.

## Models

| Job | Model ID |
| --- | --- |
| Orchestrator: taste profile synthesis, shopping agent loop | `gemini-4-argon` |
| Per-photo garment extraction, page perception | `gemini-3.8-flash` |
| Intent routing / cheap checks | `gemini-3.5-flash-lite` |

Gemini 4 Argon: use `thinking_level` (`low|medium|high`). Do not send `temperature`, `top_p`, `top_k`, `thinking_budget`, or `cached_content`. HTTP timeouts >= 15 min for `high`.

### Where Argon must shine (judges want Argon "wow" use cases)

- Taste profile: one long-context Argon call over the *whole* closet, including the actual crop images, not just text, plus feedback; every claim cites item ids.
- Shopping agent: Argon is the orchestrator. It plans sub-queries, fans out parallel Flash scouts, then *verifies* every candidate (product image vs taste profile + closet: "pairs with >= 2 items you own", price/size fit) and visibly rejects weak ones (emit `status` "Rejected X: clashes with ...").
- Video ingest and the try-on critique loop are Argon jobs (Problem Statement Two).
- Flash / Flash-Lite only for leaf tasks: per-photo extraction, page summaries, intent routing.

### Speed + caching rules

- Stable prefix first (system prompt, tools, taste profile, closet summary), volatile content last (user message, tool results) so implicit caching hits.
- Agent loop chains turns with `previous_interaction_id` (server-side state) instead of resending history and images.
- The chat agent gets the closet crop *images* (not just text) in the first turn of a conversation, for fidelity; chaining means they are sent once, not every step.
- Chat agent default `thinking_level="low"` (env `AGENT_THINKING`); `high` only for profile rebuild and try-on critique.
- Log per-call latency and cached vs uncached input tokens.

## Backend API contract (source of truth for iOS + backend)

Base URL: `http://localhost:8000` (iOS Simulator reaches the Mac's localhost). Physical phone: an https tunnel URL, configurable in the app's Settings.

All JSON uses snake_case keys.

### Types

```
UserProfile {
  name: string?, selfie_url: string?,
  top_size: string?, pant_size: string?, shoe_size: string?,
  fit_preference: string?,        // "menswear" | "womenswear" | "any"
  budget: string?                 // free text e.g. "under $200"
}

ClosetItem {
  id: string, category: string,   // "outerwear","top","bottom","shoes","accessory","dress","bag"
  name: string,                   // e.g. "olive waxed cotton chore jacket"
  colors: [string], pattern: string?, material: string?, fit: string?,
  style_tags: [string], brand: string?,
  signal: string,                 // "worn" (user wearing it) | "aspirational" (screenshot / other person)
  crop_url: string,               // relative path, e.g. "/crops/abc.jpg"
  source_asset_id: string
}

TasteProfile {
  summary: string,
  palette: [string], silhouettes: [string], style_keywords: [string],
  preferred_brands: [string], price_band: string?, avoid: [string], gaps: [string],
  evidence: [{ claim: string, item_ids: [string] }],
  updated_at: string              // ISO8601
}

Candidate {
  id: string, title: string, brand: string?, price: string?,   // price is display text e.g. "$148"
  url: string, image_url: string?, why: string,
  matched_item_ids: [string]
}
```

### Endpoints

- `GET /health` -> `{ ok: true, browser: "none"|"extension"|"cdp", extension_connected: bool }`
- `POST /onboarding` JSON `UserProfile` (all optional) -> `UserProfile`
- `GET /onboarding` -> `UserProfile`
- `POST /selfie` multipart field `file` (JPEG) -> `UserProfile` (with `selfie_url`). Used as the identity reference for deciding which person in a photo is the user.
- `POST /ingest` multipart: `file` (JPEG, <=1024px), `asset_id` (string), `source` (`"photo"|"screenshot"`) -> `{ asset_id, items: [ClosetItem], skipped: bool, reason: string? }`. Idempotent per `asset_id`.
- `GET /closet` -> `{ items: [ClosetItem] }`
- `DELETE /closet/{item_id}` -> `{ ok: true }`
- `GET /crops/{file}` and `GET /uploads/{file}` -> static JPEGs
- `POST /profile/rebuild` -> `TasteProfile` (Argon, high thinking)
- `GET /profile` -> `TasteProfile` or `null`
- `POST /chat` JSON `{ message: string, conversation_id: string? }` -> **SSE stream** (`text/event-stream`). Each event is a single `data: <json>\n\n` line with a `type`:
  - `{ type: "status", text }` — short progress line ("Searching the web for chore jackets…")
  - `{ type: "thought", text }` — model thinking summary (collapsible in UI)
  - `{ type: "tool", name, args, summary }` — tool call
  - `{ type: "candidate", candidate: Candidate }`
  - `{ type: "message", text }` — assistant prose (final answer or reply to non-shopping questions)
  - `{ type: "done", conversation_id }`
  - `{ type: "error", text }`
- `POST /feedback` JSON `{ candidate_id, verdict: "like"|"dislike", reason: string? }` -> `{ ok: true, profile: TasteProfile? }`
- `POST /reset` -> clears closet/profile/feedback (demo helper)

### Phase 2 additions (Problem Statement Two: render -> watch -> critique -> fix)

Built after the MVP lands. Do not implement in the first pass unless told to.

- Video ingest: `POST /ingest` also accepts `source = "video"` with an MP4/MOV `file` (iOS exports <= 60s, 720p). Argon watches the full video and returns garments with timestamps; the backend grabs the frame at each timestamp for the crop. `ClosetItem` gains optional `source_timestamp: string?` (e.g. `"00:12"`).
- Virtual try-on loop: `POST /tryon` JSON `{ candidate_id }` -> SSE stream:
  - `{ type: "status", text }`
  - `{ type: "render", iteration, image_url, scores: { garment_fidelity, identity, fit, style_match, overall }, critique, edits }` (scores 0-10)
  - `{ type: "done", best_iteration, baseline_score, final_score, image_url }`
  - `{ type: "error", text }`
  Base photo is chosen automatically: the best "worn" upload (clearest full-body shot of the user). Renders use `gemini-nano-banana-2.1`; Argon critiques each render against the product image, base photo, and taste profile, then writes edit instructions for the next render. Max 3 iterations or stop when every score >= 8.

### Browser bridge (backend <-> extension)

Same protocol as the moodboard project's `browser_bridge.py`:
- `POST /extension/hello` (extension heartbeat)
- `GET /extension/pending-actions` -> `{ actions: [{ id, tool, args }] }` (tools: `open_tab`, `extract_products`, `scroll`, `click`, `google_search`)
- `POST /browser/result` `{ action_id, result?, error? }`. Tool-level failures come back inside `result.error` (check both).
- Result shapes (see `extension/README.md`): `open_tab {url}` -> `{ title, url, cleaned_text, og_image, price, currency, product, tab_id }`; `extract_products {tab_id?, url?}` -> `{ page_url, title, cleaned_text, products_json_ld, product, og, tab_id }`; `google_search {query}` -> `{ results: [{ title, url, snippet }], tab_id }` or `{ error, blocked: "captcha" }`. `product` is `{ name, brand, price, currency, price_text, image, url, source }`; `price_text` is ready for `Candidate.price`.

`BROWSER_BACKEND=none|extension|cdp` env var selects the mode (default `extension` if connected, else fall back to grounded search + HTTP fetch).

## Hackathon rules

Code is written fresh in this repo. Patterns are ported from `~/.gemini/antigravity/scratch/moodboard` (reference only, do not import from it).
