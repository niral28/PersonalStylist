"""Per-photo garment extraction (flash tier) -> cropped ClosetItems."""

from __future__ import annotations

import asyncio
import io
import logging
import os
import re
import uuid
from typing import Any, Dict, List, Literal, Optional

from PIL import Image, ImageOps, UnidentifiedImageError
from pydantic import BaseModel, Field

import gemini
import store

logger = logging.getLogger("stylist.ingest")

try:  # iOS sometimes hands over HEIC even when JPEG was requested
    from pillow_heif import register_heif_opener

    register_heif_opener()
except ImportError:
    pass

INGEST_CONCURRENCY = int(os.environ.get("INGEST_CONCURRENCY", "8"))
_sema = asyncio.Semaphore(INGEST_CONCURRENCY)
_asset_locks: Dict[str, asyncio.Lock] = {}

CATEGORIES = ["outerwear", "top", "bottom", "shoes", "accessory", "dress", "bag"]


class Garment(BaseModel):
    box_2d: List[int] = Field(description="Bounding box [ymin, xmin, ymax, xmax] normalized to 0-1000.")
    category: Literal["outerwear", "top", "bottom", "shoes", "accessory", "dress", "bag"]
    name: str = Field(description="Specific descriptive name, e.g. 'olive waxed cotton chore jacket'.")
    colors: List[str]
    pattern: Optional[str]
    material: Optional[str]
    fit: Optional[str]
    style_tags: List[str] = Field(description="2-5 short style descriptors, e.g. 'workwear', 'minimal'.")
    brand: Optional[str] = Field(description="Only if a logo/label is clearly visible, else null.")
    wearer: Literal["reference_person", "main_subject", "other_person", "no_person"] = Field(
        description=(
            "Who is wearing it: 'reference_person' if worn by the person in the reference selfie, "
            "'main_subject' if worn by the most prominent person (and not identifiable as the reference), "
            "'other_person' for anyone else, 'no_person' for garments not being worn (hanger, flat lay, product shot)."
        )
    )


class Extraction(BaseModel):
    is_fashion: bool = Field(description="False if the image has no clearly visible clothing/footwear/bags/accessories worth cataloguing.")
    skip_reason: Optional[str] = Field(description="Why the image was skipped when is_fashion is false, else null.")
    people_count: int
    reference_person_present: bool = Field(description="True if the reference selfie person appears in the photo.")
    garments: List[Garment] = Field(description="Every catalogued item. Empty only when is_fashion is false.")


PROMPT = """\
You are cataloguing a user's wardrobe from their camera roll for a personal stylist app.

{reference_note}
Find every distinct, clearly visible garment, pair of shoes, bag, or notable accessory (hats, belts, watches,
sunglasses, jewelry) in the TARGET image. For each one return a tight bounding box `box_2d` as
[ymin, xmin, ymax, xmax] normalized to 0-1000 over the TARGET image, plus attributes.

Rules:
- One entry per physical item (a pair of shoes is ONE item: box both shoes together).
- Name items specifically like a retailer would: color + material + type, e.g. "light-wash ripped slim jeans".
- Skip tiny, heavily occluded, or ambiguous items. Skip items that are not fashion (furniture, phones, food).
- If the image is not fashion-related (landscape, food, document, pet, etc.) or no person/clothing is visible,
  set is_fashion=false with a short skip_reason and return no garments.
- Set `wearer` for every item as described in the schema.
"""

REF_NOTE_SELFIE = (
    "The FIRST image is a REFERENCE SELFIE of the user (do not catalogue items from it). "
    "The SECOND image is the TARGET photo. Decide which person in the target (if any) is the reference person "
    "by face, hair, and build; mark their garments wearer='reference_person'."
)
REF_NOTE_NONE = "There is one image: the TARGET photo. No reference selfie is available."
REF_NOTE_SCREENSHOT = (
    "The image is a SCREENSHOT the user saved for inspiration (social post, product page, lookbook). "
    "Catalogue the featured fashion items regardless of who wears them. Ignore UI chrome, text, and ads."
)


def _prepare(data: bytes, max_dim: int = 1024) -> Image.Image:
    img = Image.open(io.BytesIO(data))
    img = ImageOps.exif_transpose(img).convert("RGB")
    img.thumbnail((max_dim, max_dim))
    return img


def _jpeg(img: Image.Image, quality: int = 85) -> bytes:
    buf = io.BytesIO()
    img.save(buf, "JPEG", quality=quality)
    return buf.getvalue()


def _crop(img: Image.Image, box: List[int], item_id: str) -> Optional[str]:
    if len(box) != 4:
        return None
    ymin, xmin, ymax, xmax = [max(0, min(1000, int(v))) for v in box]
    if ymax <= ymin or xmax <= xmin:
        return None
    w, h = img.size
    pad_y, pad_x = (ymax - ymin) * 0.06, (xmax - xmin) * 0.06
    left = max(0, int((xmin - pad_x) / 1000 * w))
    top = max(0, int((ymin - pad_y) / 1000 * h))
    right = min(w, int((xmax + pad_x) / 1000 * w))
    bottom = min(h, int((ymax + pad_y) / 1000 * h))
    if right - left < 16 or bottom - top < 16:
        return None
    crop = img.crop((left, top, right, bottom))
    crop.thumbnail((512, 512))
    crop.save(os.path.join(store.CROPS_DIR, f"{item_id}.jpg"), "JPEG", quality=88)
    return f"/crops/{item_id}.jpg"


def _selfie_bytes() -> Optional[bytes]:
    url = store.get_user().get("selfie_url")
    if not url:
        return None
    path = os.path.join(store.DATA_DIR, url.lstrip("/"))
    try:
        with open(path, "rb") as f:
            return f.read()
    except OSError:
        return None


def _signal_for(g: Dict[str, Any], source: str, has_selfie: bool, ref_present: bool) -> Optional[str]:
    """Map wearer -> 'worn' | 'aspirational' | None (drop)."""
    if source in ("screenshot", "aspirational"):
        return "aspirational"
    wearer = g.get("wearer")
    if wearer == "reference_person":
        return "worn"
    if wearer == "other_person":
        return None
    if wearer == "main_subject":
        # With a selfie, only keep the main subject when the reference person wasn't found at all
        # (selfie matching is unreliable on faceless/back shots; it's the user's own camera roll).
        return None if (has_selfie and ref_present) else "worn"
    return "worn"  # no_person: hanger / flat lay in the user's own photos


def _item_out(item: Dict[str, Any]) -> Dict[str, Any]:
    keys = ["id", "category", "name", "colors", "pattern", "material", "fit", "style_tags", "brand", "signal", "crop_url", "source_asset_id", "source_timestamp"]
    out = {k: item.get(k) for k in keys}
    if not out.get("source_timestamp"):
        out.pop("source_timestamp", None)
    return out


def _save_upload(img: Image.Image, asset_id: str) -> str:
    safe = re.sub(r"[^A-Za-z0-9_-]", "_", asset_id)[:60]
    name = f"src_{safe}_{uuid.uuid4().hex[:6]}.jpg"
    img.save(os.path.join(store.UPLOADS_DIR, name), "JPEG", quality=85)
    return f"/uploads/{name}"


async def ingest(data: bytes, asset_id: str, source: str) -> Dict[str, Any]:
    if source == "video":
        import video as video_mod
        return await video_mod.ingest_video(data, asset_id)
    source = source if source in ("photo", "screenshot", "aspirational") else "photo"
    lock = _asset_locks.setdefault(asset_id, asyncio.Lock())
    async with lock:
        prev = store.get_ingested(asset_id)
        if prev is not None and source == "aspirational" and prev.get("skipped") and not prev.get("items"):
            # A normal scan dropped this photo (someone else, or not fashion-as-worn).
            # The user is now filing it as inspiration, so extract it again.
            store.forget_ingested(asset_id)
            prev = None
        if prev is not None:
            items = []
            for item_id in prev.get("items") or []:
                if source == "aspirational":
                    updated = store.set_item_signal(item_id, "aspirational")
                    if updated:
                        items.append(updated)
                else:
                    existing = store.get_item(item_id)
                    if existing:
                        items.append(existing)
            return {"asset_id": asset_id, "items": [_item_out(i) for i in items], "skipped": prev["skipped"], "reason": prev.get("reason")}

        try:
            img = await asyncio.to_thread(_prepare, data)
        except (UnidentifiedImageError, OSError) as e:
            head = data[:16]
            logger.warning("undecodable upload %s (%d bytes, head=%r): %s", asset_id, len(data), head, e)
            return {"asset_id": asset_id, "items": [], "skipped": True,
                    "reason": f"could not decode image ({len(data)} bytes, starts {head[:12]!r}); send JPEG"}
        target = await asyncio.to_thread(_jpeg, img)

        selfie = _selfie_bytes() if source == "photo" else None
        parts: List[Any] = []
        if source in ("screenshot", "aspirational"):
            note = REF_NOTE_SCREENSHOT
        elif selfie:
            note = REF_NOTE_SELFIE
            sel_img = await asyncio.to_thread(_prepare, selfie, 512)
            parts.append((await asyncio.to_thread(_jpeg, sel_img, 80), "image/jpeg"))
        else:
            note = REF_NOTE_NONE
        parts.append((target, "image/jpeg"))
        parts.append(PROMPT.format(reference_note=note))

        async with _sema:
            try:
                data_out, _ = await gemini.generate_json("flash", parts, Extraction, thinking="low")
            except Exception as e:
                logger.exception("extraction failed for %s", asset_id)
                # Don't mark as ingested so the client can retry.
                return {"asset_id": asset_id, "items": [], "skipped": True, "reason": f"extraction error: {str(e)[:160]}"}

        d = data_out if isinstance(data_out, dict) else {}
        garments = [g for g in d.get("garments") or [] if isinstance(g, dict) and g.get("name") and g.get("box_2d")]
        if not d.get("is_fashion", bool(garments)) or not garments:
            reason = d.get("skip_reason") or "no fashion items detected"
            store.mark_ingested(asset_id, [], True, reason)
            return {"asset_id": asset_id, "items": [], "skipped": True, "reason": reason}

        items: List[Dict[str, Any]] = []
        for gd in garments:
            if gd.get("category") not in CATEGORIES:
                gd["category"] = "accessory"
            signal = _signal_for(gd, source, bool(selfie), bool(d.get("reference_person_present")))
            if signal is None:
                continue
            item_id = uuid.uuid4().hex[:12]
            crop_url = await asyncio.to_thread(_crop, img, gd["box_2d"], item_id)
            if not crop_url:
                continue
            items.append({
                "id": item_id,
                "category": gd["category"],
                "name": gd["name"],
                "colors": gd.get("colors") or [],
                "pattern": gd.get("pattern"),
                "material": gd.get("material"),
                "fit": gd.get("fit"),
                "style_tags": gd.get("style_tags") or [],
                "brand": gd.get("brand"),
                "signal": signal,
                "crop_url": crop_url,
                "source_asset_id": asset_id,
            })

        reason = None if items else "garments belonged to other people"
        upload_url = await asyncio.to_thread(_save_upload, img, asset_id) if items else None
        store.add_items(items)
        store.mark_ingested(asset_id, [i["id"] for i in items], not items, reason, upload_url)
        return {"asset_id": asset_id, "items": [_item_out(i) for i in items], "skipped": not items, "reason": reason}
