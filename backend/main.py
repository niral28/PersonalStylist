"""PersonalStylist backend — FastAPI app implementing the AGENTS.md contract."""

from __future__ import annotations

import asyncio
import json
import logging
import os
import uuid
from typing import Any, Dict, List, Literal, Optional

from dotenv import load_dotenv

load_dotenv(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".env"))

from fastapi import FastAPI, File, Form, HTTPException, Request, UploadFile  # noqa: E402
from fastapi.middleware.cors import CORSMiddleware  # noqa: E402
from fastapi.responses import StreamingResponse  # noqa: E402
from fastapi.staticfiles import StaticFiles  # noqa: E402
from pydantic import BaseModel  # noqa: E402

import agent  # noqa: E402
import browser_bridge  # noqa: E402
import gemini  # noqa: E402
import ingest as ingest_mod  # noqa: E402
import profile as profile_mod  # noqa: E402
import store  # noqa: E402
import tryon as tryon_mod  # noqa: E402

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s: %(message)s")
logging.getLogger("httpx").setLevel(logging.WARNING)
logger = logging.getLogger("stylist.main")

app = FastAPI(title="PersonalStylist backend")
app.add_middleware(CORSMiddleware, allow_origins=["*"], allow_methods=["*"], allow_headers=["*"])
app.mount("/crops", StaticFiles(directory=store.CROPS_DIR), name="crops")
app.mount("/uploads", StaticFiles(directory=store.UPLOADS_DIR), name="uploads")
app.mount("/renders", StaticFiles(directory=store.RENDERS_DIR), name="renders")

USER_KEYS = ["name", "selfie_url", "top_size", "pant_size", "shoe_size", "fit_preference", "budget"]


def _user_out() -> Dict[str, Any]:
    u = store.get_user()
    return {k: u.get(k) for k in USER_KEYS}


class UserProfileIn(BaseModel):
    name: Optional[str] = None
    selfie_url: Optional[str] = None
    top_size: Optional[str] = None
    pant_size: Optional[str] = None
    shoe_size: Optional[str] = None
    fit_preference: Optional[str] = None
    budget: Optional[str] = None


class ChatIn(BaseModel):
    message: str
    conversation_id: Optional[str] = None


class TryOnIn(BaseModel):
    candidate_id: str
    base_id: Optional[str] = None
    context: Optional[str] = None


class LookIn(BaseModel):
    candidate_id: str
    image_url: str
    iteration: Optional[int] = None


class FeedbackIn(BaseModel):
    candidate_id: str
    verdict: Literal["like", "dislike"]
    reason: Optional[str] = None


class ExtensionHello(BaseModel):
    version: Optional[str] = None

    model_config = {"extra": "allow"}


class BrowserResult(BaseModel):
    action_id: str
    result: Optional[Any] = None
    error: Optional[str] = None


# --- health / onboarding --------------------------------------------------------
@app.get("/health")
async def health():
    return {
        "ok": True,
        "browser": browser_bridge.browser_mode(),
        "extension_connected": browser_bridge.extension_connected(),
        "models": gemini.status(),
    }


@app.post("/onboarding")
async def post_onboarding(body: UserProfileIn):
    store.update_user(body.model_dump(exclude_none=True))
    return _user_out()


@app.get("/onboarding")
async def get_onboarding():
    return _user_out()


@app.post("/selfie")
async def post_selfie(file: UploadFile = File(...)):
    data = await file.read()
    if not data:
        raise HTTPException(400, "empty file")
    img = await asyncio.to_thread(ingest_mod._prepare, data, 1024)
    name = f"selfie_{uuid.uuid4().hex[:8]}.jpg"
    await asyncio.to_thread(img.save, os.path.join(store.UPLOADS_DIR, name), "JPEG", quality=88)
    store.update_user({"selfie_url": f"/uploads/{name}"})
    return _user_out()


# --- closet ---------------------------------------------------------------------
@app.post("/ingest")
async def post_ingest(
    file: UploadFile = File(...),
    asset_id: str = Form(...),
    source: str = Form("photo"),
):
    data = await file.read()
    if not data:
        raise HTTPException(400, "empty file")
    try:
        return await ingest_mod.ingest(data, asset_id, source)
    except Exception as e:
        logger.exception("ingest failed")
        return {"asset_id": asset_id, "items": [], "skipped": True, "reason": f"error: {str(e)[:160]}"}


@app.get("/closet")
async def get_closet():
    return {"items": [ingest_mod._item_out(i) for i in store.get_closet()]}


@app.delete("/closet/{item_id}")
async def delete_closet_item(item_id: str):
    store.delete_item(item_id)
    try:
        os.remove(os.path.join(store.CROPS_DIR, f"{item_id}.jpg"))
    except OSError:
        pass
    return {"ok": True}


# --- taste profile ----------------------------------------------------------------
@app.post("/profile/rebuild")
async def post_profile_rebuild():
    try:
        return await profile_mod.rebuild(thinking="high")
    except Exception as e:
        logger.exception("profile rebuild failed")
        raise HTTPException(503, f"profile rebuild failed: {str(e)[:200]}")


@app.get("/profile")
async def get_profile():
    return store.get_profile()


# --- chat (SSE) -------------------------------------------------------------------
def _sse(event: Dict[str, Any]) -> bytes:
    return f"data: {json.dumps(event, ensure_ascii=False)}\n\n".encode()


@app.post("/chat")
async def post_chat(body: ChatIn, request: Request):
    queue: asyncio.Queue = asyncio.Queue()

    async def emit(ev: Dict[str, Any]) -> None:
        await queue.put(ev)

    task = asyncio.create_task(agent.run_chat(body.message, body.conversation_id, emit))

    async def stream():
        idle = 0
        try:
            while True:
                try:
                    ev = await asyncio.wait_for(queue.get(), timeout=15)
                except asyncio.TimeoutError:
                    if await request.is_disconnected():
                        break
                    idle += 1
                    yield _sse({"type": "status", "text": "Still working…" if idle < 3 else "Still working — the model is taking a while…"})
                    continue
                idle = 0
                yield _sse(ev)
                if ev.get("type") == "done":
                    break
        finally:
            if not task.done():
                task.cancel()

    return StreamingResponse(
        stream(),
        media_type="text/event-stream",
        headers={"Cache-Control": "no-cache", "X-Accel-Buffering": "no"},
    )


@app.post("/tryon")
async def post_tryon(body: TryOnIn, request: Request):
    queue: asyncio.Queue = asyncio.Queue()

    async def emit(ev: Dict[str, Any]) -> None:
        await queue.put(ev)

    task = asyncio.create_task(tryon_mod.run_tryon(body.candidate_id, emit, body.base_id, body.context))

    async def stream():
        try:
            while True:
                try:
                    ev = await asyncio.wait_for(queue.get(), timeout=15)
                except asyncio.TimeoutError:
                    if await request.is_disconnected():
                        break
                    yield _sse({"type": "status", "text": "Still rendering…"})
                    continue
                yield _sse(ev)
                if ev.get("type") == "done":
                    break
        finally:
            if not task.done():
                task.cancel()

    return StreamingResponse(stream(), media_type="text/event-stream", headers={"Cache-Control": "no-cache", "X-Accel-Buffering": "no"})


# --- saved try-on looks -----------------------------------------------------------
@app.get("/looks")
async def get_looks():
    return {"looks": store.get_looks()}


@app.post("/looks")
async def post_look(body: LookIn):
    cand = store.get_candidate(body.candidate_id)
    if not cand:
        raise HTTPException(404, "unknown product")
    if not body.image_url.startswith("/renders/"):
        raise HTTPException(400, "image_url must be a try-on render")
    look = store.save_look({
        "id": uuid.uuid4().hex[:12],
        "candidate_id": body.candidate_id,
        "image_url": body.image_url,
        "iteration": body.iteration,
        "title": cand.get("title"),
        "brand": cand.get("brand"),
        "price": cand.get("price"),
        "url": cand.get("url"),
        "product_image_url": cand.get("image_url"),
        "saved_at": store.now_iso(),
    })
    try:
        look = await profile_mod.note_saved_look(look)
    except Exception:
        logger.exception("saved-look note failed")
    return look


@app.delete("/looks/{look_id}")
async def delete_look(look_id: str):
    ok = store.delete_look(look_id)
    prof = store.get_profile()
    if ok and prof is not None:
        store.set_profile(profile_mod._attach_saved(prof))
    return {"ok": ok}


# --- feedback ---------------------------------------------------------------------
_feedback_tasks: List[asyncio.Task] = []


@app.post("/feedback")
async def post_feedback(body: FeedbackIn):
    cand = store.get_candidate(body.candidate_id)
    store.add_feedback({
        "candidate_id": body.candidate_id,
        "verdict": body.verdict,
        "reason": body.reason,
        "candidate": cand,
        "at": store.now_iso(),
    })
    task = asyncio.create_task(profile_mod.apply_feedback())
    _feedback_tasks.append(task)
    task.add_done_callback(lambda t: _feedback_tasks.remove(t) if t in _feedback_tasks else None)
    try:
        prof = await asyncio.wait_for(asyncio.shield(task), timeout=float(os.environ.get("FEEDBACK_WAIT_S", "25")))
    except Exception as e:  # timeout -> keep updating in the background
        logger.info("feedback profile update pending/failed: %s", str(e)[:120])
        prof = store.get_profile()
    return {"ok": True, "profile": prof}


@app.post("/reset")
async def post_reset():
    store.reset()
    return {"ok": True}


@app.get("/demo")
async def get_demo():
    return store.demo_status()


@app.post("/demo/snapshot")
async def post_demo_snapshot():
    try:
        return await asyncio.to_thread(store.snapshot_demo)
    except ValueError as e:
        raise HTTPException(400, str(e))


@app.post("/demo/restore")
async def post_demo_restore():
    try:
        return await asyncio.to_thread(store.restore_demo)
    except ValueError as e:
        raise HTTPException(400, str(e))


# --- browser bridge (extension) -------------------------------------------------------
@app.post("/extension/hello")
async def extension_hello(body: Optional[ExtensionHello] = None):
    browser_bridge.mark_extension_connected(body.version if body else None)
    return {"ok": True}


@app.get("/extension/pending-actions")
async def extension_pending_actions():
    browser_bridge.mark_extension_connected()
    return {"actions": browser_bridge.pending_actions()}


@app.post("/browser/result")
async def browser_result(body: BrowserResult):
    browser_bridge.mark_extension_connected()
    result = body.result if isinstance(body.result, dict) or body.result is None else {"result": body.result}
    ok = browser_bridge.resolve_action(body.action_id, result, body.error)
    return {"ok": ok} if ok else {"ok": False, "error": "unknown or expired action_id"}


if __name__ == "__main__":
    import uvicorn

    uvicorn.run("main:app", host="0.0.0.0", port=8000)
