"""Thin wrapper around every Gemini call (google-genai Interactions API).

All model / API choices live here. Each call names a *tier*:
  argon -> taste profile + shopping agent loop (ARGON_MODEL, default gemini-4-argon)
  flash -> per-photo extraction, page perception, search grounding (FLASH_MODEL)
  lite  -> intent routing / cheap checks (LITE_MODEL)

If a model is unavailable (quota 0 on the key's tier, 503 overload, unknown id), the call
falls through to FALLBACK_MODELS so the demo keeps working. Never sends temperature /
top_p / top_k / thinking_budget / cached_content.
"""

from __future__ import annotations

import asyncio
import base64
import json
import logging
import os
import re
import time
from typing import Any, Dict, List, Optional, Sequence, Tuple, Union

from dotenv import load_dotenv
from google import genai
from google.genai import types

load_dotenv(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".env"))

logger = logging.getLogger("stylist.gemini")

ARGON_MODEL = os.environ.get("ARGON_MODEL", "gemini-4-argon")
FLASH_MODEL = os.environ.get("FLASH_MODEL", "gemini-3.8-flash")
LITE_MODEL = os.environ.get("LITE_MODEL", "gemini-3.5-flash-lite")
FALLBACK_MODELS = [
    m.strip()
    for m in os.environ.get("FALLBACK_MODELS", "gemini-3.6-flash,gemini-3.5-flash-lite").split(",")
    if m.strip()
]

TIERS: Dict[str, List[str]] = {
    "argon": [ARGON_MODEL, FLASH_MODEL],
    "flash": [FLASH_MODEL],
    "lite": [LITE_MODEL],
}

HTTP_TIMEOUT_MS = int(os.environ.get("GEMINI_TIMEOUT_MS", str(15 * 60 * 1000)))
# Per-attempt cap before falling through to the next model in the chain (the last
# model in the chain gets the full HTTP timeout).
ATTEMPT_TIMEOUT_S = {"argon": 300.0, "flash": 60.0, "lite": 25.0}

# A part is either text or (image_bytes, mime_type).
Part = Union[str, Tuple[bytes, str]]

_client: Optional[genai.Client] = None

# model -> unix time until which it is skipped
_cooldown: Dict[str, float] = {}
# model -> last error string (for /health diagnostics)
_last_error: Dict[str, str] = {}
# tier -> last model that actually served a request
last_used: Dict[str, str] = {}


def client() -> genai.Client:
    global _client
    if _client is None:
        key = os.environ.get("GEMINI_API_KEY")
        if not key:
            raise RuntimeError("GEMINI_API_KEY is not set (backend/.env)")
        _client = genai.Client(
            api_key=key,
            http_options=types.HttpOptions(
                timeout=HTTP_TIMEOUT_MS,
                retry_options=types.HttpRetryOptions(attempts=0),
            ),
        )
    return _client


def _chain(tier: str) -> List[str]:
    out: List[str] = []
    for m in TIERS.get(tier, [tier]) + FALLBACK_MODELS:
        if m not in out:
            out.append(m)
    return out


def _classify_error(e: Exception) -> Tuple[str, float]:
    """Return (kind, cooldown_seconds). kind in quota|overload|notfound|other."""
    s = str(e).lower()
    if "limit: 0" in s or "free tier" in s or "permission" in s:
        return "quota", 3600.0
    if "check your plan and billing" in s:
        return "quota", 300.0
    if "not found" in s or "404" in s or "not supported" in s or "invalid model" in s:
        return "notfound", 3600.0
    if "high demand" in s or "503" in s or "unavailable" in s or "overloaded" in s:
        return "overload", 45.0
    if "429" in s or "rate limit" in s or "resource_exhausted" in s or "too_many" in s:
        return "overload", 30.0
    return "other", 0.0


def _content_blocks(parts: Sequence[Part]) -> List[Dict[str, Any]]:
    blocks: List[Dict[str, Any]] = []
    for p in parts:
        if isinstance(p, str):
            blocks.append({"type": "text", "text": p})
        elif isinstance(p, dict):
            blocks.append(p)
        else:
            data, mime = p
            kind = "video" if str(mime).startswith("video/") else "image"
            block: Dict[str, Any] = {
                "type": kind,
                "data": base64.b64encode(data).decode("ascii"),
                "mime_type": mime,
            }
            if kind == "video":
                block["processing"] = "agentic"
            blocks.append(block)
    return blocks


def _log_usage(model: str, it: Any, elapsed: float) -> None:
    u = getattr(it, "usage", None)
    if not u:
        logger.info("gemini %s %.1fs (no usage)", model, elapsed)
        return
    logger.info(
        "gemini %s %.1fs in=%s cached=%s out=%s thought=%s",
        model,
        elapsed,
        getattr(u, "total_input_tokens", None),
        getattr(u, "total_cached_tokens", None),
        getattr(u, "total_output_tokens", None),
        getattr(u, "total_thought_tokens", None),
    )


async def _create(
    tier: str,
    *,
    timeout: Optional[float] = None,
    store: bool = False,
    previous_interaction_id: Optional[str] = None,
    **kwargs: Any,
) -> Tuple[Any, str]:
    """interactions.create with model fallback. Returns (interaction, model_used).
    `timeout` caps each attempt so a slow model falls through to the next one.
    `previous_interaction_id` chains server-side state (implies store=True)."""
    chain = _chain(tier)
    now = time.time()
    candidates = [m for m in chain if _cooldown.get(m, 0) <= now] or chain
    per_try = timeout or ATTEMPT_TIMEOUT_S.get(tier, 120.0)
    last_exc: Optional[Exception] = None
    for i, model in enumerate(candidates):
        is_last = i == len(candidates) - 1
        try:
            extra: Dict[str, Any] = {"store": True if previous_interaction_id else store}
            if previous_interaction_id:
                extra["previous_interaction_id"] = previous_interaction_id
            t0 = time.time()
            it = await asyncio.wait_for(
                client().aio.interactions.create(model=model, **extra, **kwargs),
                timeout=None if is_last else per_try,
            )
            _log_usage(model, it, time.time() - t0)
            status = getattr(it, "status", None)
            if status == "failed":
                raise RuntimeError(f"interaction failed: {getattr(it, 'error', None)}")
            last_used[tier] = model
            return it, model
        except Exception as e:  # noqa: BLE001
            if isinstance(e, asyncio.TimeoutError):
                kind, cool = "timeout", 120.0
                e = RuntimeError(f"timed out after {per_try:.0f}s")
            else:
                kind, cool = _classify_error(e)
            _last_error[model] = f"{kind}: {str(e)[:200]}"
            logger.warning("gemini %s (%s) failed [%s]: %s", model, tier, kind, str(e)[:200])
            last_exc = e
            if cool:
                _cooldown[model] = time.time() + cool
            if kind == "other":
                # Bad request etc. — retry once on the next model only if it might be model-specific.
                continue
    raise RuntimeError(f"all models failed for tier {tier}: {last_exc}")


def _gen_config(thinking: Optional[str], extra: Optional[Dict[str, Any]] = None) -> Dict[str, Any]:
    cfg: Dict[str, Any] = {}
    if thinking:
        cfg["thinking_level"] = thinking
        cfg["thinking_summaries"] = "auto"
    if extra:
        cfg.update(extra)
    return cfg


def _thoughts(it: Any) -> Optional[str]:
    out: List[str] = []
    for step in getattr(it, "steps", None) or []:
        if getattr(step, "type", None) == "thought":
            for block in getattr(step, "summary", None) or []:
                t = getattr(block, "text", None)
                if t:
                    out.append(t.strip())
    return "\n\n".join(out) if out else None


def _output_text(it: Any) -> str:
    try:
        t = it.output_text
        if t:
            return t
    except Exception:
        pass
    texts: List[str] = []
    for step in getattr(it, "steps", None) or []:
        if getattr(step, "type", None) == "model_output":
            for c in getattr(step, "content", None) or []:
                if getattr(c, "type", None) == "text" and getattr(c, "text", None):
                    texts.append(c.text)
    return "".join(texts)


def _parse_json(text: str) -> Any:
    text = (text or "").strip()
    if text.startswith("```"):
        text = re.sub(r"^```(?:json)?\s*|\s*```$", "", text)
    try:
        return json.loads(text)
    except json.JSONDecodeError:
        for open_c, close_c in (("{", "}"), ("[", "]")):
            s, e = text.find(open_c), text.rfind(close_c)
            if s >= 0 and e > s:
                try:
                    return json.loads(text[s : e + 1])
                except json.JSONDecodeError:
                    pass
        raise


def _schema_of(schema: Any) -> Dict[str, Any]:
    if hasattr(schema, "model_json_schema"):
        return schema.model_json_schema()
    return schema


# --- public API ---------------------------------------------------------------
async def generate_text(
    tier: str,
    parts: Union[str, Sequence[Part]],
    *,
    system: Optional[str] = None,
    thinking: Optional[str] = "low",
    timeout: Optional[float] = None,
) -> Tuple[str, Optional[str]]:
    """Plain text answer. Returns (text, thought_summary)."""
    if isinstance(parts, str):
        parts = [parts]
    kwargs: Dict[str, Any] = {"input": _content_blocks(parts), "generation_config": _gen_config(thinking)}
    if system:
        kwargs["system_instruction"] = system
    it, _ = await _create(tier, timeout=timeout, **kwargs)
    return _output_text(it), _thoughts(it)


async def generate_json(
    tier: str,
    parts: Union[str, Sequence[Part]],
    schema: Any,
    *,
    system: Optional[str] = None,
    thinking: Optional[str] = "low",
    timeout: Optional[float] = None,
) -> Tuple[Any, Optional[str]]:
    """Structured JSON output. `schema` is a pydantic model class or JSON schema dict."""
    if isinstance(parts, str):
        parts = [parts]
    kwargs: Dict[str, Any] = {
        "input": _content_blocks(parts),
        "generation_config": _gen_config(thinking),
        "response_format": {"type": "text", "mime_type": "application/json", "schema": _schema_of(schema)},
    }
    if system:
        kwargs["system_instruction"] = system
    it, _ = await _create(tier, timeout=timeout, **kwargs)
    return _parse_json(_output_text(it)), _thoughts(it)


async def call_tool(
    tier: str,
    prompt: str,
    tools: List[Dict[str, Any]],
    *,
    system: Optional[str] = None,
    thinking: Optional[str] = "medium",
    timeout: Optional[float] = None,
) -> Tuple[Optional[str], Dict[str, Any], Optional[str], str]:
    """Single forced function call. Returns (name, args, thought_summary, text)."""
    kwargs: Dict[str, Any] = {
        "input": prompt,
        "tools": [{"type": "function", **t} for t in tools],
        "generation_config": _gen_config(thinking, {"tool_choice": "any"}),
    }
    if system:
        kwargs["system_instruction"] = system
    it, _ = await _create(tier, timeout=timeout, **kwargs)
    for step in getattr(it, "steps", None) or []:
        if getattr(step, "type", None) == "function_call":
            args = getattr(step, "arguments", None) or {}
            if isinstance(args, str):
                try:
                    args = json.loads(args)
                except json.JSONDecodeError:
                    args = {}
            return step.name, dict(args), _thoughts(it), _output_text(it)
    return None, {}, _thoughts(it), _output_text(it)


def _function_calls(it: Any) -> List[Dict[str, Any]]:
    calls: List[Dict[str, Any]] = []
    for step in getattr(it, "steps", None) or []:
        if getattr(step, "type", None) != "function_call":
            continue
        args = getattr(step, "arguments", None) or {}
        if isinstance(args, str):
            try:
                args = json.loads(args)
            except json.JSONDecodeError:
                args = {}
        calls.append({
            "id": getattr(step, "id", None) or f"call_{len(calls)}",
            "name": step.name,
            "args": dict(args),
        })
    return calls


async def call_tools(
    tier: str,
    parts: Union[str, Sequence[Any]],
    tools: List[Dict[str, Any]],
    *,
    system: Optional[str] = None,
    thinking: Optional[str] = "low",
    timeout: Optional[float] = None,
    previous_interaction_id: Optional[str] = None,
) -> Tuple[List[Dict[str, Any]], Optional[str], Optional[str], str]:
    """One agent turn. Returns (function_calls, thought_summary, interaction_id, text).

    `parts` is a prompt (str or content blocks) or a list of function_result dicts when
    continuing via previous_interaction_id. Stored so the next turn can chain.
    """
    if isinstance(parts, str):
        inp: Any = parts
    elif parts and isinstance(parts[0], dict) and parts[0].get("type") == "function_result":
        inp = list(parts)
    else:
        inp = _content_blocks(parts)  # type: ignore[arg-type]
    kwargs: Dict[str, Any] = {
        "input": inp,
        "tools": [{"type": "function", **t} for t in tools],
        "generation_config": _gen_config(thinking, {"tool_choice": "any"}),
    }
    if system and not previous_interaction_id:
        kwargs["system_instruction"] = system
    it, _ = await _create(
        tier,
        timeout=timeout,
        store=True,
        previous_interaction_id=previous_interaction_id,
        **kwargs,
    )
    return _function_calls(it), _thoughts(it), getattr(it, "id", None), _output_text(it)


def function_results(calls_and_results: Sequence[Tuple[Dict[str, Any], Dict[str, Any]]]) -> List[Dict[str, Any]]:
    """Build the next-turn input for previous_interaction_id chaining."""
    out: List[Dict[str, Any]] = []
    for call, result in calls_and_results:
        text = json.dumps(result, ensure_ascii=False, default=str)
        if len(text) > 6000:
            text = text[:6000] + "…"
        out.append({
            "type": "function_result",
            "call_id": call["id"],
            "name": call["name"],
            "result": text,
            "is_error": bool(isinstance(result, dict) and result.get("error")),
        })
    return out


def _image_bytes(it: Any) -> Optional[bytes]:
    for step in getattr(it, "steps", None) or []:
        for c in getattr(step, "content", None) or []:
            if getattr(c, "type", None) != "image":
                continue
            data = getattr(c, "data", None)
            if not data:
                continue
            raw = data if isinstance(data, (bytes, bytearray)) else base64.b64decode(str(data))
            if raw:
                return bytes(raw)
    return None


async def generate_image(
    parts: Sequence[Part],
    *,
    model: Optional[str] = None,
    aspect_ratio: str = "3:4",
    timeout: float = 180.0,
) -> bytes:
    """Image generation (Nano Banana). Does not send thinking_level — that model rejects it."""
    model = model or os.environ.get("TRYON_MODEL", "gemini-nano-banana-2.1")
    t0 = time.time()
    it = await asyncio.wait_for(
        client().aio.interactions.create(
            model=model,
            store=False,
            input=_content_blocks(parts),
            response_format={"type": "image", "aspect_ratio": aspect_ratio, "image_size": "1K"},
        ),
        timeout=timeout,
    )
    _log_usage(model, it, time.time() - t0)
    if getattr(it, "status", None) == "failed":
        raise RuntimeError(f"image generation failed: {getattr(it, 'error', None)}")
    raw = _image_bytes(it)
    if not raw:
        raise RuntimeError("image model returned no image")
    return raw


async def google_search(query: str) -> List[Dict[str, str]]:
    """Grounded Google Search via the google_search tool. Returns [{title, url, snippet}].
    URLs may be vertexaisearch redirectors; callers resolve them."""
    it, _ = await _create(
        "flash",
        input=(
            f"Search the web for: {query}\n\n"
            "Focus on specific product pages at online retailers (not listicles when avoidable). "
            "Return the top 6-8 results as lines formatted 'TITLE — URL — one-line snippet with price if known'."
        ),
        tools=[{"type": "google_search"}],
        generation_config=_gen_config("low"),
    )
    results: List[Dict[str, str]] = []
    seen = set()
    for step in getattr(it, "steps", None) or []:
        if getattr(step, "type", None) != "model_output":
            continue
        for c in getattr(step, "content", None) or []:
            text = getattr(c, "text", "") or ""
            for ann in getattr(c, "annotations", None) or []:
                url = getattr(ann, "url", None)
                if not url or url in seen:
                    continue
                seen.add(url)
                s, e = getattr(ann, "start_index", None), getattr(ann, "end_index", None)
                snippet = text[s:e] if isinstance(s, int) and isinstance(e, int) else ""
                results.append({"title": getattr(ann, "title", "") or "", "url": url, "snippet": snippet[:300]})
    text = _output_text(it)
    for line in text.splitlines():
        line = line.strip().lstrip("•-*0123456789. ").strip()
        m = re.search(r"https?://[^\s)\]—]+", line)
        if not m:
            continue
        url = m.group(0).rstrip(".,")
        if url in seen:
            continue
        seen.add(url)
        chunks = [p.strip() for p in line.split(" — ")]
        results.append({
            "title": chunks[0] if chunks and "http" not in chunks[0] else "",
            "url": url,
            "snippet": chunks[2] if len(chunks) > 2 else "",
        })
    return results


def status() -> Dict[str, Any]:
    now = time.time()
    return {
        "tiers": {t: _chain(t) for t in TIERS},
        "last_used": dict(last_used),
        "cooling_down": {m: round(t - now) for m, t in _cooldown.items() if t > now},
        "last_errors": dict(_last_error),
    }
