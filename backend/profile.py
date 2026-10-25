"""Taste profile synthesis (argon tier) from closet + user prefs + feedback journal."""

from __future__ import annotations

import asyncio
import json
import logging
from typing import Any, Dict, List, Optional

from pydantic import BaseModel, Field

import gemini
import store

logger = logging.getLogger("stylist.profile")

_rebuild_lock = asyncio.Lock()


class Evidence(BaseModel):
    claim: str
    item_ids: List[str]


class TasteProfileOut(BaseModel):
    summary: str = Field(description="2-4 sentence second-person description of the user's style.")
    palette: List[str] = Field(description="Dominant colors, most frequent first.")
    silhouettes: List[str]
    style_keywords: List[str]
    preferred_brands: List[str]
    price_band: Optional[str] = Field(None, description="e.g. '$80-$250 per piece', informed by budget + brands.")
    avoid: List[str] = Field(description="Things to avoid (from dislikes / absent from closet).")
    gaps: List[str] = Field(description="Concrete wardrobe gaps worth shopping for, e.g. 'lightweight rain shell'.")
    evidence: List[Evidence] = Field(description="Each claim backed by closet item ids (use ONLY ids given).")


SYSTEM = (
    "You are an expert personal stylist building a precise, evidence-backed taste profile. "
    "Distinguish what the user actually WEARS (signal='worn') from what they ASPIRE to (signal='aspirational'); "
    "weight worn items for fit/silhouette and aspirational items for direction. Treat feedback dislikes as hard "
    "constraints for `avoid`. Be specific (e.g. 'boxy cropped workwear jackets', not 'jackets')."
)


def _closet_view(items: List[Dict[str, Any]]) -> str:
    rows = []
    for i in items:
        rows.append({
            "id": i["id"], "category": i["category"], "name": i["name"], "colors": i.get("colors"),
            "pattern": i.get("pattern"), "material": i.get("material"), "fit": i.get("fit"),
            "style_tags": i.get("style_tags"), "brand": i.get("brand"), "signal": i.get("signal"),
        })
    return json.dumps(rows, separators=(",", ":"))


def _user_view() -> str:
    u = store.get_user()
    keys = ["name", "top_size", "pant_size", "shoe_size", "fit_preference", "budget"]
    return json.dumps({k: u.get(k) for k in keys if u.get(k)})


def _feedback_view(limit: int = 20) -> str:
    rows = []
    for f in store.recent_feedback(limit):
        c = f.get("candidate") or {}
        rows.append({"verdict": f.get("verdict"), "reason": f.get("reason"), "item": c.get("title"), "brand": c.get("brand"), "price": c.get("price")})
    return json.dumps(rows) if rows else "(none)"


def _finalize(data: Any, valid_ids: set) -> Dict[str, Any]:
    data = dict(data) if isinstance(data, dict) else {}
    for k in ("palette", "silhouettes", "style_keywords", "preferred_brands", "avoid", "gaps", "evidence"):
        if not isinstance(data.get(k), list):
            data[k] = []
    data["evidence"] = [
        {"claim": str(e["claim"]), "item_ids": [str(x) for x in e.get("item_ids") or []]}
        for e in data["evidence"]
        if isinstance(e, dict) and e.get("claim")
    ]
    data["summary"] = data.get("summary") or ""
    data.setdefault("price_band", store.get_user().get("budget"))
    prof = TasteProfileOut.model_validate(data).model_dump()
    ev = []
    for e in prof.get("evidence") or []:
        ids = [x for x in e.get("item_ids") or [] if x in valid_ids]
        if ids:
            ev.append({"claim": e["claim"], "item_ids": ids})
    prof["evidence"] = ev
    prof["updated_at"] = store.now_iso()
    return prof


async def rebuild(thinking: str = "high") -> Dict[str, Any]:
    async with _rebuild_lock:
        items = store.get_closet()
        if not items:
            prof = {
                "summary": "Your closet is empty so far — scan some photos to build your taste profile.",
                "palette": [], "silhouettes": [], "style_keywords": [], "preferred_brands": [],
                "price_band": store.get_user().get("budget"), "avoid": [], "gaps": [], "evidence": [],
                "updated_at": store.now_iso(),
            }
            store.set_profile(prof)
            return prof
        prompt = (
            f"[USER PROFILE]\n{_user_view()}\n\n"
            f"[CLOSET ITEMS] ({len(items)})\n{_closet_view(items)}\n\n"
            f"[RECENT FEEDBACK ON SUGGESTIONS]\n{_feedback_view()}\n\n"
            f"[SAVED FOR LATER]\n{_saved_block()}\n"
            "Saved try-ons are looks the user kept. Treat them as aesthetics they appreciated.\n\n"
            "Synthesize the user's taste profile. Every evidence claim must cite item ids from CLOSET ITEMS. "
            "Include 3-6 evidence entries and 2-5 gaps."
        )
        data, _ = await gemini.generate_json("argon", prompt, TasteProfileOut, system=SYSTEM, thinking=thinking)
        prof = _attach_saved(_finalize(data, {i["id"] for i in items}))
        store.set_profile(prof)
        return prof


def _saved_block() -> str:
    rows = []
    for look in store.get_looks():
        rows.append({
            "title": look.get("title"),
            "brand": look.get("brand"),
            "price": look.get("price"),
            "note": look.get("aesthetic_note"),
        })
    return json.dumps(rows) if rows else "(none)"


def _attach_saved(prof: Dict[str, Any]) -> Dict[str, Any]:
    prof["saved_for_later"] = [
        look.get("aesthetic_note") for look in store.get_looks() if look.get("aesthetic_note")
    ]
    return prof


async def note_saved_look(look: Dict[str, Any]) -> Dict[str, Any]:
    """One sentence on why saving this try-on signals an aesthetic they like."""
    title = look.get("title") or "this piece"
    try:
        text, _ = await gemini.generate_text(
            "flash",
            "The user saved a virtual try-on to keep for later. That means they appreciated this aesthetic.\n"
            f"Product: {title}, {look.get('brand') or 'unknown brand'}, {look.get('price') or 'price unknown'}.\n"
            f"Their taste so far: {(store.get_profile() or {}).get('summary') or 'unknown'}\n\n"
            "Write one specific sentence in the second person naming the trait they responded to "
            "(color, cut, material, or mood). No preamble.",
            thinking="low",
            timeout=20,
        )
        note = " ".join((text or "").strip().split())
    except Exception as e:
        logger.warning("saved-look note failed: %s", str(e)[:160])
        note = ""
    if not note:
        note = f"You saved the {title} for later, a sign you liked this aesthetic."
    updated = store.update_look(look["id"], {"aesthetic_note": note}) or {**look, "aesthetic_note": note}
    prof = store.get_profile()
    if prof:
        store.set_profile(_attach_saved(prof))
    return updated


async def apply_feedback() -> Dict[str, Any]:
    """Lighter update after a like/dislike: revise the existing profile instead of rebuilding."""
    current = store.get_profile()
    if not current:
        return await rebuild(thinking="low")
    async with _rebuild_lock:
        items = store.get_closet()
        prompt = (
            f"[CURRENT TASTE PROFILE]\n{json.dumps({k: v for k, v in current.items() if k != 'updated_at'})}\n\n"
            f"[USER PROFILE]\n{_user_view()}\n\n"
            f"[RECENT FEEDBACK ON SUGGESTIONS] (most recent last)\n{_feedback_view()}\n\n"
            f"[SAVED FOR LATER]\n{_saved_block()}\n"
            "Saved try-ons mean the user appreciated that aesthetic. Reinforce those traits.\n\n"
            f"[VALID ITEM IDS]\n{json.dumps([i['id'] for i in items])}\n\n"
            "Revise the profile to reflect the feedback: add concrete dislikes to `avoid`, reinforce liked "
            "attributes in style_keywords/silhouettes/palette/brands. Keep everything else stable."
        )
        data, _ = await gemini.generate_json("argon", prompt, TasteProfileOut, system=SYSTEM, thinking="low")
        prof = _attach_saved(_finalize(data, {i["id"] for i in items}))
        store.set_profile(prof)
        return prof
