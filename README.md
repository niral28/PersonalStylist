# Personal Stylist

An iPhone stylist that learns what you wear from your camera roll, shops the web for pieces that fit that taste, and shows you in them. The try-on is not a single guess: it renders, watches the result, critiques it, and renders again.

## The hackathon problem

The Gemini 4 Argon hackathon asks for work in at least one of two statements.

**Problem Statement One: Million Token Engineering.** Argon is strong at long-horizon software work, with a very large output window. The prompt is to take on a monumental engineering task, such as a legacy migration or framework upgrade, and measure the improvement over a baseline. This app is not that kind of project.

**Problem Statement Two: More Dimensions.** Argon is also strong at long video understanding, and a single generated draft is only a first pass. The prompt is to build a system that renders what it made, watches the result, critiques it against the goal, and fixes it in a loop.

Personal Stylist is built for Problem Statement Two.

**See it on me** is that loop, applied to clothing:

1. Nano Banana renders you wearing a product the shopping agent found, using a real photo of you and the product image.
2. Argon watches that render next to the product photo, your photo, and your taste profile.
3. It scores garment fidelity, identity, fit, style match, and an overall score from 0 to 10, and writes concrete edits.
4. The next render applies those edits. This repeats for at most three passes, or stops when every score is 8 or higher.

The phone shows the first-pass overall score beside the best pass, so the improvement over the baseline is visible.

**Video ingest** uses the same model's long-video strength. Argon watches a camera-roll clip (up to 60 seconds) and returns garments with timestamps. The backend grabs the frame at each timestamp and files the crop in the closet.

## The problem we solved

Taste already exists in the camera roll: outfits you wore, screenshots you saved, and short videos. Shopping search does not know any of that. A recommendation that ignores what you own, what you are dressing for, and what you have already rejected is just another catalog.

Personal Stylist turns that raw material into a closet and a taste profile, then uses both while it shops.

- Photos you are wearing become **Worn**. Screenshots, and photos you add from the Aspirational tab, become **Aspirational**. Clothes on other people in a normal photo are dropped, so the closet does not fill up with strangers.
- One Argon pass reads the whole closet, including the crop images, plus sizes, budget, likes, dislikes, and saved looks. Every claim in the taste profile cites item ids.
- The chat agent plans a search, looks at real product pages, and checks each candidate against the profile and the closet before it recommends it. Weak picks are rejected out loud.
- Likes, dislikes, and saved looks update the profile. Chat text does not.
- Try-on chooses among your own photos (day and evening, city and nature) and uses the occasion you described in chat, such as a hike or an evening gala, when picking the setting.

## Architecture

Three processes. The phone is the only UI. The laptop holds the models, the closet, and the browser. Chrome is visible on purpose: when the agent shops, you see the tabs open.

```
iPhone (SwiftUI)
  photos, closet, chat, try-on
        |  HTTP + server-sent events
        v
FastAPI on the laptop  :8000
  closet, profile, agent, try-on
        |                         |
        | Interactions API        | poll for actions
        v                         v
Gemini                        Chrome extension
  Argon, Flash,               opens a visible tab group,
  Flash-Lite, Nano Banana     searches, extracts products
```

| Piece | Role |
| --- | --- |
| `PersonalStylist/` | SwiftUI app, iOS 18.2. Onboarding (selfie, sizes, photo access), closet, style profile, chat, and try-on. New Swift files under this folder are compiled automatically. |
| `backend/` | FastAPI. Closet, taste profile, shopping agent, try-on loop, and video ingest. State lives in `backend/data/state.json`. Crops, uploads, and renders are files beside it. |
| `extension/` | Chrome extension (Manifest V3) named Stylist. It polls the backend and runs `google_search`, `open_tab`, `extract_products`, `scroll`, and `click` in a visible tab group. |

The phone talks to `http://localhost:8000` in the simulator. On a physical phone, set the laptop's address in the gear menu. The simulator and the phone share one backend, so a closet built on the phone is the closet the agent shops from.

### Who does the thinking

Argon is the orchestrator. Smaller models do the leaf work.

| Job | Model |
| --- | --- |
| Taste profile, shopping-agent loop, try-on critique, video watch | `gemini-4-argon` |
| Per-photo garment extraction, page perception, try-on photo tagging | `gemini-3.8-flash` |
| Intent routing and other cheap checks | `gemini-3.5-flash-lite` |
| Try-on renders | `gemini-nano-banana-2.1` |

Argon calls use `thinking_level` only (`low`, `medium`, or `high`). Chat stays on `low` so a search can finish while someone is watching. Profile rebuild and try-on critique use `high`. The agent keeps a stable prefix (instructions, tools, profile, closet) and chains later steps with `previous_interaction_id`, so closet images are sent once per conversation rather than on every tool call. The first turn of a chat includes closet crops and saved-look images, not just text.

If the Chrome extension is connected, search goes through Chrome's own search engine and the agent reads the results page. If it is not, the backend falls back to Gemini's grounded search.

### Try-on data flow

```
product chosen in chat
        |
        v
pick 1 of your photos (occasion + time of day + place)
        |
        v
Nano Banana render  -->  Argon critique and scores  -->  edits
        ^                                              |
        +------------------ next render --------------+
        |
        v
stop at 3 passes, or when every score is >= 8
baseline overall vs best overall shown under the image
```

A prepared closet can be saved from Settings and restored from onboarding, so a demo can walk through the intro and then open an already indexed wardrobe instead of waiting on a full scan.

## Run

Backend, from `backend/` (Python 3.12+, `GEMINI_API_KEY` in `backend/.env`):

```bash
./run.sh
```

The API listens on `0.0.0.0:8000`.

Extension, from `extension/`:

```bash
npm install
npm run build
```

Load `extension/dist` as an unpacked extension at `chrome://extensions`, then reload it after each build.

Open `PersonalStylist.xcodeproj` in Xcode 16 and run the PersonalStylist scheme on a simulator or a phone. On a phone, set the backend URL to the laptop's address in the gear menu.
