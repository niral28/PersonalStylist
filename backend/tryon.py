"""Virtual try-on: Nano Banana renders, Argon critiques, then the next render applies the edits."""

from __future__ import annotations

import asyncio
import hashlib
import io
import logging
import os
import uuid
from typing import Any, Awaitable, Callable, Dict, List, Optional, Tuple

import requests
from pydantic import BaseModel, Field

import gemini
import store

logger = logging.getLogger("stylist.tryon")

TRYON_MODEL = os.environ.get("TRYON_MODEL", "gemini-nano-banana-2.1")
CRITIC_THINKING = os.environ.get("TRYON_CRITIC_THINKING", "high")
MAX_ITERS = int(os.environ.get("TRYON_MAX_ITERS", "3"))
PASS_SCORE = 8.0

Emit = Callable[[Dict[str, Any]], Awaitable[None]]

# Walks forward on each new try-on. Resets when the server restarts, so a demo
# can begin on the first photo again.
_cursor = 0


class Scores(BaseModel):
    garment_fidelity: float = Field(description="0-10, does the garment match the product (color, cut, details)?")
    identity: float = Field(description="0-10, is it still the same person, face and body?")
    fit: float = Field(description="0-10, do proportions and drape look believable?")
    style_match: float = Field(description="0-10, does it suit the taste profile?")
    overall: float


class Critique(BaseModel):
    scores: Scores
    critique: str = Field(description="2-3 specific sentences.")
    edits: List[str] = Field(description="Concrete edit instructions for the next render. Empty if every score is >= 8.")


class ShotTag(BaseModel):
    index: int
    full_body: bool
    time_of_day: str = Field(description="day or evening. evening includes dusk, night, and indoor warm artificial light.")
    place: str = Field(description="city, nature, or indoors.")
    label: str = Field(description="Short label like 'Evening, city street' or 'Daytime, forest'.")


class ShotTags(BaseModel):
    shots: List[ShotTag]


class Occasion(BaseModel):
    summary: str = Field(description="A few words, e.g. 'evening gala', or empty if they named no occasion.")
    time_of_day: str = Field(description="day, evening, or any.")
    place: str = Field(description="city, nature, indoors, or any.")


def _read(url: Optional[str]) -> Optional[bytes]:
    if not url:
        return None
    if url.startswith("/"):
        path = os.path.join(store.DATA_DIR, url.lstrip("/"))
        try:
            with open(path, "rb") as f:
                return f.read()
        except OSError:
            return None
    try:
        r = requests.get(url, timeout=12, headers={"User-Agent": "PersonalStylist/1.0"})
        r.raise_for_status()
        return r.content
    except Exception:
        return None


def _worn_uploads() -> List[Dict[str, Any]]:
    """Full photos that produced worn items, largest first. id is stable for a given file."""
    found: List[Dict[str, Any]] = []
    for rec in store.all_ingested().values():
        url = rec.get("upload_url")
        if not url:
            continue
        items = [store.get_item(i) for i in rec.get("items") or []]
        if not any(it and it.get("signal") == "worn" for it in items):
            continue
        path = os.path.join(store.DATA_DIR, url.lstrip("/"))
        try:
            size = os.path.getsize(path)
        except OSError:
            continue
        found.append({
            "id": hashlib.sha1(url.encode()).hexdigest()[:10],
            "image_url": url,
            "size": size,
        })
    found.sort(key=lambda r: r["size"], reverse=True)
    return found


def _thumb(url: str) -> Optional[bytes]:
    from PIL import Image

    raw = _read(url)
    if not raw:
        return None
    img = Image.open(io.BytesIO(raw)).convert("RGB")
    img.thumbnail((384, 384))
    buf = io.BytesIO()
    img.save(buf, "JPEG", quality=75)
    return buf.getvalue()


_SETTINGS = [
    ("evening", "city"), ("evening", "nature"), ("evening", "indoors"),
    ("day", "city"), ("day", "nature"), ("day", "indoors"),
]


def _variety_cycle(shots: List[Dict[str, Any]]) -> List[Dict[str, Any]]:
    """Up to six photos across settings. Later try-ons walk this list instead of reusing one."""
    full = [s for s in shots if s.get("full_body")]
    evenings = [s for s in shots if s.get("time_of_day") == "evening" and not s.get("full_body")]
    pool = full or list(shots)
    groups: Dict[tuple, List[Dict[str, Any]]] = {}
    for shot in pool:
        groups.setdefault((shot.get("time_of_day"), shot.get("place")), []).append(shot)
    # Leave room for an evening photo when the full-body shots are all daytime.
    cap = 6 - min(2, len(evenings)) if full else 6
    cycle: List[Dict[str, Any]] = []
    seen = set()
    for take in (0, 1):
        for key in _SETTINGS:
            if len(cycle) >= cap:
                break
            group = groups.get(key) or []
            if take >= len(group):
                continue
            shot = group[take]
            if shot["id"] in seen:
                continue
            cycle.append(shot)
            seen.add(shot["id"])
    for shot in pool:
        if len(cycle) >= cap:
            break
        if shot["id"] not in seen:
            cycle.append(shot)
            seen.add(shot["id"])
    for shot in evenings:
        if len(cycle) >= 6:
            break
        if shot["id"] not in seen:
            cycle.append(shot)
            seen.add(shot["id"])
    return cycle[:6]


def _row(cycle: List[Dict[str, Any]], chosen: Dict[str, Any]) -> List[Dict[str, Any]]:
    """Three choices starting at the photo this try-on will use."""
    if not cycle:
        return [chosen]
    if chosen["id"] not in {shot["id"] for shot in cycle}:
        cycle = [chosen] + cycle
    start = next(i for i, shot in enumerate(cycle) if shot["id"] == chosen["id"])
    row: List[Dict[str, Any]] = []
    seen = set()
    for step in range(len(cycle)):
        shot = cycle[(start + step) % len(cycle)]
        if shot["id"] in seen:
            continue
        seen.add(shot["id"])
        row.append(shot)
        if len(row) == 3:
            break
    return row


async def base_options() -> List[Dict[str, Any]]:
    """Worn photos tagged by time of day and place. Cached; the try-on rotates through them."""
    uploads = _worn_uploads()[:12]
    if not uploads:
        selfie = store.get_user().get("selfie_url")
        if not selfie:
            return []
        return [{
            "id": hashlib.sha1(selfie.encode()).hexdigest()[:10],
            "image_url": selfie,
            "time_of_day": "day",
            "place": "indoors",
            "label": "Your selfie",
        }]
    fingerprint = hashlib.sha1("".join(u["image_url"] for u in uploads).encode()).hexdigest()
    cached = store.get_blob("tryon_bases") or {}
    if cached.get("v") == 2 and cached.get("fingerprint") == fingerprint and cached.get("shots"):
        return cached["shots"]

    parts: List[Any] = []
    for i, upload in enumerate(uploads):
        thumb = _thumb(upload["image_url"])
        if not thumb:
            continue
        parts.append(f"Photo {i}.")
        parts.append((thumb, "image/jpeg"))
    parts.append(
        "Tag each photo of the same person. full_body is true only when the body is visible to about the knees or lower. "
        "time_of_day is 'evening' for dusk, night, or clearly artificial nighttime light, otherwise 'day'. "
        "place is city (street, buildings, skyline), nature (park, forest, beach, mountain), or indoors. "
        "label is a short phrase a shopper would understand. index is the photo number, starting at 0."
    )
    try:
        data, _ = await gemini.generate_json("flash", parts, ShotTags, thinking="low", timeout=40)
    except Exception as e:
        logger.warning("base photo tagging failed: %s", str(e)[:160])
        data = {}
    by_index = {int(s.get("index", -1)): s for s in (data or {}).get("shots") or [] if isinstance(s, dict)}
    if 0 not in by_index and 1 in by_index:
        by_index = {k - 1: v for k, v in by_index.items()}
    tagged = []
    for i, upload in enumerate(uploads):
        tag = by_index.get(i) or {}
        tagged.append({
            "id": upload["id"],
            "image_url": upload["image_url"],
            "time_of_day": tag.get("time_of_day") if tag.get("time_of_day") in ("day", "evening") else "day",
            "place": tag.get("place") if tag.get("place") in ("city", "nature", "indoors") else "indoors",
            "label": tag.get("label") or "Photo of you",
            "full_body": bool(tag.get("full_body", True)),
        })
    store.set_blob("tryon_bases", {"v": 2, "fingerprint": fingerprint, "shots": tagged})
    return tagged


async def _occasion(context: Optional[str]) -> Dict[str, str]:
    text = (context or "").strip()
    if not text:
        return {"summary": "", "time_of_day": "any", "place": "any"}
    try:
        data, _ = await gemini.generate_json(
            "lite",
            "The user was chatting with their stylist before trying a garment on. "
            "Pull the occasion they are dressing for, if they named one (a trip, evening gala, date, wedding, "
            "work, hike, night out). If they did not name an occasion, leave summary empty and use 'any'.\n\n"
            f"Chat:\n{text[:1200]}",
            Occasion,
            thinking=None,
            timeout=15,
        )
    except Exception as e:
        logger.warning("occasion parse failed: %s", str(e)[:120])
        return {"summary": "", "time_of_day": "any", "place": "any"}
    data = data or {}
    time_of_day = data.get("time_of_day") if data.get("time_of_day") in ("day", "evening", "any") else "any"
    place = data.get("place") if data.get("place") in ("city", "nature", "indoors", "any") else "any"
    return {"summary": (data.get("summary") or "").strip(), "time_of_day": time_of_day, "place": place}


def _match_score(option: Dict[str, Any], occasion: Dict[str, str]) -> int:
    want_time = occasion.get("time_of_day") or "any"
    want_place = occasion.get("place") or "any"
    points = 0
    if want_time != "any" and option.get("time_of_day") == want_time:
        points += 4
    if want_place != "any" and option.get("place") == want_place:
        points += 2
    return points


def _choose(
    cycle: List[Dict[str, Any]],
    occasion: Dict[str, str],
    base_id: Optional[str],
    cursor: int,
) -> Tuple[Dict[str, Any], bool, int]:
    """Returns (photo, adjust_background, next_cursor).

    A photo the user picked is never restaged and does not move the cursor.
    Otherwise each call walks to the next photo that fits the occasion, so a
    later try-on does not repeat the one just used.
    """
    if base_id:
        for option in cycle:
            if option["id"] == base_id:
                return option, False, cursor
    scores = [_match_score(option, occasion) for option in cycle]
    best = max(scores)
    primary = {option["id"] for option, score in zip(cycle, scores) if score == best}
    # Several photos fit the place: stay with those. Only one does: later try-ons
    # may use another photo from the same time of day so it does not repeat.
    if best >= 4 and len(primary) < 2:
        matches = {option["id"] for option, score in zip(cycle, scores) if score >= 4}
    else:
        matches = primary or {option["id"] for option in cycle}
    start = cursor % len(cycle)
    chosen = cycle[start]
    step_used = 0
    for step in range(len(cycle)):
        option = cycle[(start + step) % len(cycle)]
        if option["id"] in matches:
            chosen = option
            step_used = step
            break
    want_time = occasion.get("time_of_day") or "any"
    adjust = bool(base_id is None and want_time != "any" and chosen.get("time_of_day") != want_time)
    return chosen, adjust, (start + step_used + 1) % len(cycle)


def _save_render(raw: bytes) -> str:
    from PIL import Image
    import io

    name = f"{uuid.uuid4().hex[:12]}.jpg"
    img = Image.open(io.BytesIO(raw)).convert("RGB")
    img.thumbnail((1024, 1024))
    img.save(os.path.join(store.RENDERS_DIR, name), "JPEG", quality=88)
    return f"/renders/{name}"


async def run_tryon(candidate_id: str, emit: Emit, base_id: Optional[str] = None, context: Optional[str] = None) -> None:
    cand = store.get_candidate(candidate_id)
    if not cand:
        await emit({"type": "error", "text": "Unknown product. Ask the stylist to find it again."})
        await emit({"type": "done", "best_iteration": 0, "baseline_score": 0, "final_score": 0, "image_url": None})
        return
    await emit({"type": "status", "text": "Choosing a photo that fits the occasion…"})
    shots = await base_options()
    occasion = await _occasion(context)
    cycle = _variety_cycle(shots)
    if not cycle:
        await emit({"type": "error", "text": "Need a photo of you and a product image before trying this on."})
        await emit({"type": "done", "best_iteration": 0, "baseline_score": 0, "final_score": 0, "image_url": None})
        return
    pinned = next((shot for shot in shots if shot["id"] == base_id), None) if base_id else None
    global _cursor
    if pinned:
        chosen, adjust = pinned, False
    else:
        chosen, adjust, _cursor = _choose(cycle, occasion, None, _cursor)
    options = _row(cycle, chosen)
    await emit({
        "type": "scene",
        "selected_id": chosen["id"],
        "occasion": occasion.get("summary") or "",
        "adjust_background": adjust,
        "options": [
            {"id": o["id"], "image_url": o["image_url"], "label": o.get("label"), "time_of_day": o.get("time_of_day"), "place": o.get("place")}
            for o in options
        ],
    })
    label = chosen.get("label") or "a photo of you"
    if base_id:
        await emit({"type": "status", "text": f"Using {label}"})
    elif occasion.get("summary") and adjust:
        await emit({"type": "status", "text": f"No matching photo, so {label} will be restaged for {occasion['summary']}"})
    elif occasion.get("summary"):
        await emit({"type": "status", "text": f"Using {label} for {occasion['summary']}"})
    else:
        await emit({"type": "status", "text": f"Using {label}"})
    base = await asyncio.to_thread(_read, chosen["image_url"])
    product = await asyncio.to_thread(_read, cand.get("image_url"))
    if not base or not product:
        await emit({"type": "error", "text": "Need a photo of you and a product image before trying this on."})
        await emit({"type": "done", "best_iteration": 0, "baseline_score": 0, "final_score": 0, "image_url": None})
        return
    scene_bits = [
        bit for bit in (occasion.get("time_of_day"), occasion.get("place"))
        if bit and bit != "any"
    ]
    scene = " ".join(scene_bits) or "fitting"
    setting = (
        f"The user is dressing for {occasion.get('summary') or scene}. This photo's time of day does not fit. "
        f"Change the background to a believable {scene} scene. Keep the same person, face, and body."
        if adjust
        else "Keep this photo's background, including its time of day and location."
    )

    profile = store.get_profile() or {}
    summary = profile.get("summary") or ""
    edits: List[str] = []
    best = {"iteration": 0, "overall": -1.0, "url": None}
    baseline = None
    prev_render: Optional[bytes] = None

    for i in range(1, MAX_ITERS + 1):
        await emit({"type": "status", "text": f"Rendering pass {i}…" if i == 1 else f"Applying edits, pass {i}…"})
        instruction = (
            "Dress the person in the FIRST photo in the garment shown in the SECOND photo. "
            "Keep their face, body, and pose. "
            f"{setting} Change the clothing to match the product "
            f"({cand.get('title')}, {cand.get('brand') or ''}). Photorealistic, natural drape, correct color."
        )
        if edits:
            instruction += " Apply these corrections: " + " ".join(edits)
        parts: List[Any] = [(base, "image/jpeg"), (product, "image/jpeg"), instruction]
        if prev_render and edits:
            parts = [(prev_render, "image/jpeg"), (product, "image/jpeg"),
                     "This is the previous try-on. Edit it. " + instruction]
        try:
            raw = await gemini.generate_image(parts, model=TRYON_MODEL)
        except Exception as e:
            logger.exception("render failed")
            await emit({"type": "error", "text": f"Render failed: {str(e)[:180]}"})
            break
        url = await asyncio.to_thread(_save_render, raw)
        prev_render = raw

        await emit({"type": "status", "text": "Argon is critiquing this pass…"})
        critic_parts: List[Any] = [
            (raw, "image/jpeg"), (product, "image/jpeg"), (base, "image/jpeg"),
            "Image 1 is the render, image 2 is the product, image 3 is the real person. "
            f"Taste profile: {summary[:800]}. Occasion: {occasion.get('summary') or 'unspecified'}. "
            + (
                "The background was restaged to fit the occasion; judge whether that setting landed and say so in edits."
                if adjust
                else "The user chose this photo's real background. Do not request a different time of day or location."
            ) + " Score the render and write edits.",
        ]
        try:
            data, _ = await gemini.generate_json(
                "argon", critic_parts, Critique, thinking=CRITIC_THINKING, timeout=90,
            )
        except Exception as e:
            logger.warning("critique failed: %s", e)
            data = {"scores": {"overall": 5}, "critique": "Couldn't score this pass.", "edits": []}
        scores = (data or {}).get("scores") or {}
        overall = float(scores.get("overall") or 0)
        critique = (data or {}).get("critique") or ""
        edits = [str(x) for x in ((data or {}).get("edits") or [])][:6]
        if baseline is None:
            baseline = overall
        if overall > best["overall"]:
            best = {"iteration": i, "overall": overall, "url": url}
        await emit({
            "type": "render",
            "iteration": i,
            "image_url": url,
            "scores": {
                "garment_fidelity": scores.get("garment_fidelity"),
                "identity": scores.get("identity"),
                "fit": scores.get("fit"),
                "style_match": scores.get("style_match"),
                "overall": overall,
            },
            "critique": critique,
            "edits": edits,
        })
        nums = [float(scores.get(k) or 0) for k in ("garment_fidelity", "identity", "fit", "style_match", "overall")]
        if nums and min(nums) >= PASS_SCORE:
            await emit({"type": "status", "text": "Every score is 8 or higher. Stopping."})
            break

    await emit({
        "type": "done",
        "best_iteration": best["iteration"],
        "baseline_score": baseline if baseline is not None else 0,
        "final_score": best["overall"] if best["overall"] >= 0 else 0,
        "image_url": best["url"],
    })
