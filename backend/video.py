"""Argon watches a short camera-roll video and returns timestamped garments."""

from __future__ import annotations

import asyncio
import logging
import os
import subprocess
import tempfile
import uuid
from typing import Any, Dict, List, Optional

from PIL import Image
from pydantic import BaseModel, Field

import gemini
import ingest as ingest_mod
import store

logger = logging.getLogger("stylist.video")


class VideoGarment(BaseModel):
    timestamp: str = Field(description="MM:SS of the clearest frame of this garment.")
    box_2d: List[int] = Field(description="[ymin, xmin, ymax, xmax] on THAT frame, 0-1000.")
    category: str
    name: str
    colors: List[str] = []
    pattern: Optional[str] = None
    material: Optional[str] = None
    fit: Optional[str] = None
    style_tags: List[str] = []
    brand: Optional[str] = None
    wearer: str = "main_subject"


class VideoExtraction(BaseModel):
    is_fashion: bool
    skip_reason: Optional[str] = None
    garments: List[VideoGarment] = []


def _frame_at(path: str, timestamp: str) -> Optional[Image.Image]:
    ts = timestamp.strip()
    if not ts:
        ts = "00:01"
    out = tempfile.mktemp(suffix=".jpg")
    try:
        subprocess.run(
            ["ffmpeg", "-y", "-ss", ts, "-i", path, "-frames:v", "1", "-q:v", "3", out],
            check=True, capture_output=True, timeout=30,
        )
        return Image.open(out).convert("RGB")
    except Exception as e:
        logger.warning("frame grab %s failed: %s", ts, e)
        return None
    finally:
        try:
            os.remove(out)
        except OSError:
            pass


async def ingest_video(data: bytes, asset_id: str) -> Dict[str, Any]:
    prev = store.get_ingested(asset_id)
    if prev is not None:
        items = [i for i in (store.get_item(x) for x in prev["items"]) if i]
        return {"asset_id": asset_id, "items": [ingest_mod._item_out(i) for i in items],
                "skipped": prev["skipped"], "reason": prev.get("reason")}
    if len(data) > 40 * 1024 * 1024:
        return {"asset_id": asset_id, "items": [], "skipped": True, "reason": "video is over 40MB"}

    name = f"vid_{uuid.uuid4().hex[:10]}.mp4"
    path = os.path.join(store.UPLOADS_DIR, name)
    with open(path, "wb") as f:
        f.write(data)

    selfie = ingest_mod._selfie_bytes()
    parts: List[Any] = []
    note = "No selfie reference. Catalogue garments on the most prominent person."
    if selfie:
        parts.append((selfie, "image/jpeg"))
        note = "The FIRST image is a reference selfie of the user. Only catalogue garments THEY wear."
    parts.append((data, "video/mp4"))
    parts.append(
        "Watch this short video. " + note + " Return each distinct garment once, at the timestamp "
        "where it is clearest, with a tight box_2d on that frame. Skip non-fashion videos."
    )
    try:
        data_out, _ = await gemini.generate_json("argon", parts, VideoExtraction, thinking="low", timeout=180)
    except Exception as e:
        logger.exception("video extraction failed")
        return {"asset_id": asset_id, "items": [], "skipped": True, "reason": f"video error: {str(e)[:160]}"}

    d = data_out if isinstance(data_out, dict) else {}
    garments = d.get("garments") or []
    if not d.get("is_fashion", bool(garments)) or not garments:
        reason = d.get("skip_reason") or "no fashion in video"
        store.mark_ingested(asset_id, [], True, reason)
        return {"asset_id": asset_id, "items": [], "skipped": True, "reason": reason}

    items: List[Dict[str, Any]] = []
    seen = set()
    for g in garments:
        if not isinstance(g, dict) or not g.get("name"):
            continue
        key = g["name"].strip().lower()
        if key in seen:
            continue
        seen.add(key)
        frame = await asyncio.to_thread(_frame_at, path, str(g.get("timestamp") or "00:01"))
        if frame is None:
            continue
        item_id = uuid.uuid4().hex[:12]
        crop_url = ingest_mod._crop(frame, g.get("box_2d") or [0, 0, 1000, 1000], item_id)
        if not crop_url:
            continue
        cat = g.get("category") if g.get("category") in ingest_mod.CATEGORIES else "accessory"
        items.append({
            "id": item_id,
            "category": cat,
            "name": g["name"],
            "colors": g.get("colors") or [],
            "pattern": g.get("pattern"),
            "material": g.get("material"),
            "fit": g.get("fit"),
            "style_tags": g.get("style_tags") or [],
            "brand": g.get("brand"),
            "signal": "worn",
            "crop_url": crop_url,
            "source_asset_id": asset_id,
            "source_timestamp": g.get("timestamp"),
        })
    reason = None if items else "could not grab frames"
    store.add_items(items)
    store.mark_ingested(asset_id, [i["id"] for i in items], not items, reason, f"/uploads/{name}")
    return {"asset_id": asset_id, "items": [ingest_mod._item_out(i) for i in items], "skipped": not items, "reason": reason}
