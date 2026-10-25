"""Chat shopping agent: intent routing (lite) + Argon ReAct tool loop streaming SSE events.

Event shapes (contract): status, thought, tool, candidate, message, done, error.
"""

from __future__ import annotations

import asyncio
import json
import logging
import os
import re
import time
import uuid
from typing import Any, Awaitable, Callable, Dict, List, Literal, Optional

from pydantic import BaseModel, Field

import browser_bridge
import gemini
import store
import web_fetch

logger = logging.getLogger("stylist.agent")

MAX_STEPS = int(os.environ.get("AGENT_MAX_STEPS", "8"))
SOFT_DEADLINE_S = float(os.environ.get("AGENT_SOFT_DEADLINE", "55"))
HARD_DEADLINE_S = float(os.environ.get("CHAT_BUDGET_S", os.environ.get("AGENT_HARD_DEADLINE", "75")))
STEP_TIMEOUT_S = float(os.environ.get("AGENT_STEP_TIMEOUT", "30"))
SEARCH_TIMEOUT_S = float(os.environ.get("AGENT_SEARCH_TIMEOUT", "25"))
AGENT_THINKING = os.environ.get("AGENT_THINKING", "low")
VERIFY_THINKING = os.environ.get("VERIFY_THINKING", "low")
TARGET_CANDIDATES = 4

Emit = Callable[[Dict[str, Any]], Awaitable[None]]

# conversation_id -> [{role, text}]
_conversations: Dict[str, List[Dict[str, str]]] = {}


TOOLS: List[Dict[str, Any]] = [
    {
        "name": "search_web",
        "description": (
            "Search the web. Returns up to 8 results [{title, url, snippet}]. Use specific, qualifier-rich "
            "queries (color, material, silhouette, brand, price tier, gender section)."
        ),
        "parameters": {"type": "object", "properties": {"query": {"type": "string"}}, "required": ["query"]},
    },
    {
        "name": "open_page",
        "description": (
            "Open a URL (in the user's visible Chrome when connected, else fetched over HTTP). Returns a perception "
            "insight: whether it shows a viable product, its title/price/image, and a next_action_hint."
        ),
        "parameters": {"type": "object", "properties": {"url": {"type": "string"}}, "required": ["url"]},
    },
    {
        "name": "extract_products",
        "description": "Extract a structured product list [{title, brand, price, image_url, product_url}] from the currently open page.",
        "parameters": {"type": "object", "properties": {}},
    },
    {
        "name": "propose_candidate",
        "description": (
            "Commit ONE product to the user's feed immediately (they watch them arrive live). Call as soon as a "
            "product is verified. url must be the real product page (never a search redirector)."
        ),
        "parameters": {
            "type": "object",
            "properties": {
                "title": {"type": "string"},
                "brand": {"type": "string"},
                "price": {"type": "string", "description": "Display text, e.g. '$148'."},
                "url": {"type": "string"},
                "image_url": {"type": "string"},
                "why": {"type": "string", "description": "One or two sentences tying it to the user's closet/taste."},
                "matched_item_ids": {"type": "array", "items": {"type": "string"}, "description": "Closet item ids it pairs with or echoes."},
            },
            "required": ["title", "url", "why"],
        },
    },
    {
        "name": "done",
        "description": "Finish. `message` is a short friendly wrap-up for the user (2-4 sentences).",
        "parameters": {"type": "object", "properties": {"message": {"type": "string"}}, "required": ["message"]},
    },
]

SYSTEM = """\
You are Stylist, a personal shopping agent. You know the user's closet, sizes, budget, and taste profile.
Your job: find 3-5 specific, purchasable products that fit their taste and request, and commit each one with
propose_candidate the moment it is verified.

Tools: search_web, open_page, extract_products, propose_candidate, done.

Workflow:
1. In your FIRST turn, call search_web TWO or THREE times with diverse specific queries (different brands or
   retailers, same request + taste + budget + menswear/womenswear). Several tool calls in one turn run in parallel.
2. Then open_page the 2-3 most promising PRODUCT pages in one turn (not listicles). Read each perception insight.
3. propose_candidate as soon as you have title + real url (+ price/image when known). You may propose several at once.
4. Call done(message) after 3-5 commits. Do not keep searching once you have enough.

Hard rules:
- Human in the loop: NEVER purchase, add to cart, check out, log in, create accounts, or enter personal data.
  You only find and propose; the user decides.
- Never call search_web twice in a row. Prefer opening pages over refining queries.
- Each candidate must be a real product URL from search results or opened pages, never invented, never a
  vertexaisearch redirector.
- Respect the user's feedback (avoid list, dislikes) as HARD constraints, and their sizes/budget.
- `why` must reference concrete closet items, a saved look, or taste traits; put those closet item ids in matched_item_ids.
- Saved looks are try-on photos the user kept. When they ask for something that goes with a saved look, shop for pieces that match the outfit already on them in that photo (color, formality, season). Do not recommend another copy of the saved product.
- Be fast: aim for 5-8 tool calls total.
"""


class Intent(BaseModel):
    intent: Literal["shopping", "other"] = Field(description="'shopping' if the user wants product suggestions/finding items to buy.")


class Insight(BaseModel):
    is_viable_lead: bool
    candidate_title: Optional[str] = None
    candidate_brand: Optional[str] = None
    candidate_price: Optional[str] = None
    candidate_url: Optional[str] = None
    candidate_image_url: Optional[str] = None
    why: Optional[str] = Field(None, description="One sentence on fit with the request + taste profile.")
    summary: str = Field(description="1-2 sentence digest of the page.")
    next_action_hint: Literal["propose_candidate", "extract_products", "open_different", "done"]


class ExtractedProduct(BaseModel):
    title: str
    brand: Optional[str] = None
    price: Optional[str] = None
    image_url: Optional[str] = None
    product_url: Optional[str] = None


class ExtractedProducts(BaseModel):
    products: List[ExtractedProduct]


class Verdict(BaseModel):
    index: int
    accept: bool
    reason: str = Field(description="One sentence. If rejecting, say exactly why it clashes.")
    matched_item_ids: List[str] = Field(default_factory=list, description="Closet item ids it pairs with or echoes.")


class VerdictBatch(BaseModel):
    verdicts: List[Verdict]


# --- context ------------------------------------------------------------------
class Ctx:
    def __init__(self, message: str, conversation_id: str, emit: Emit):
        self.message = message
        self.conversation_id = conversation_id
        self.emit = emit
        self.started = time.time()
        self.observations: List[Dict[str, Any]] = []
        self.committed: List[Dict[str, Any]] = []
        self.leads: List[Dict[str, Any]] = []
        self.page: Optional[Dict[str, Any]] = None  # last opened page (http mode)
        self.tab_id: Optional[int] = None  # last opened tab (extension mode)
        self.search_results: List[Dict[str, str]] = []

    @property
    def elapsed(self) -> float:
        return time.time() - self.started


def _profile_block() -> str:
    p = store.get_profile()
    if not p:
        return "(no taste profile yet — infer from closet)"
    keep = ["summary", "palette", "silhouettes", "style_keywords", "preferred_brands", "price_band", "avoid", "gaps", "saved_for_later"]
    return json.dumps({k: p.get(k) for k in keep}, ensure_ascii=False)


def _user_block() -> str:
    u = store.get_user()
    keys = ["name", "top_size", "pant_size", "shoe_size", "fit_preference", "budget"]
    return json.dumps({k: u.get(k) for k in keys if u.get(k)}) or "{}"


def _closet_block(limit: int = 60) -> str:
    items = store.get_closet()[:limit]
    if not items:
        return "(empty)"
    return "\n".join(
        f"- {i['id']}: {i['name']} [{i['category']}, {', '.join(i.get('colors') or [])}; {i.get('signal')}]" for i in items
    )


def _feedback_block(limit: int = 10) -> str:
    rows = []
    for f in store.recent_feedback(limit):
        c = f.get("candidate") or {}
        rows.append(f"- {f.get('verdict')}: {c.get('title') or f.get('candidate_id')}" + (f" — \"{f['reason']}\"" if f.get("reason") else ""))
    return "\n".join(rows) or "(none)"


def _history_block(cid: str, limit: int = 6) -> str:
    hist = _conversations.get(cid, [])[-limit:]
    return "\n".join(f"{h['role']}: {h['text'][:400]}" for h in hist) or "(new conversation)"


def _short(obj: Any, limit: int = 320) -> str:
    s = obj if isinstance(obj, str) else json.dumps(obj, default=str, ensure_ascii=False)
    return s if len(s) <= limit else s[:limit] + "…"


def _build_step_prompt(ctx: Ctx) -> str:
    obs_lines: List[str] = []
    for i, o in enumerate(ctx.observations, start=1):
        r = o.get("result") or {}
        ins = r.get("insight") if isinstance(r, dict) else None
        head = f"Step {i}: {o['action']}({_short(o.get('args') or {}, 160)})"
        if ins:
            lead = "LEAD" if ins.get("is_viable_lead") else "no lead"
            bits = [f"{k.replace('candidate_', '')}={ins[k]}" for k in ("candidate_title", "candidate_price", "candidate_url", "candidate_image_url") if ins.get(k)]
            obs_lines.append(f"{head}\n  → [{lead}{' | ' + ', '.join(bits) if bits else ''}] {ins.get('summary', '')}\n  → next_action_hint: {ins.get('next_action_hint')}")
            prods = r.get("products") or []
            if prods:
                obs_lines.append("  products: " + _short(prods[:6], 1400))
        else:
            obs_lines.append(f"{head}\n  → {_short(r, 1400 if o['action'] in ('search_web', 'extract_products') else 400)}")
    obs_block = "\n".join(obs_lines) or "(none yet — this is step 1)"

    committed = len(ctx.committed)
    opens = sum(1 for o in ctx.observations if o["action"] == "open_page")
    searches = sum(1 for o in ctx.observations if o["action"] == "search_web")
    last_two = [o["action"] for o in ctx.observations[-2:]]

    nudge = ""
    if ctx.elapsed > SOFT_DEADLINE_S and (ctx.leads or committed):
        nudge = (
            f"\n[TIME IS UP — {int(ctx.elapsed)}s elapsed]\nCommit your best remaining verified leads with propose_candidate "
            f"right now (you have {committed}), then call done(message). Do not search or open anything else.\n"
        )
    elif ctx.elapsed > SOFT_DEADLINE_S:
        nudge = (
            f"\n[HURRY — {int(ctx.elapsed)}s elapsed, nothing committed]\nIf a search result is clearly a specific product "
            "page, propose_candidate it directly now. Otherwise open_page the single best product result.\n"
        )
    elif (len(last_two) == 2 and all(a == "search_web" for a in last_two)) or (searches >= 2 and opens == 0):
        nudge = (
            f"\n[STOP SEARCHING]\nYou have called search_web {searches} time(s) but open_page {opens} time(s). Pick the most "
            "promising URL from the latest results and call open_page on it NOW, or propose_candidate directly if a result "
            "is clearly a specific product page with a price.\n"
        )
    elif committed == 0 and (opens + searches) >= 4:
        nudge = (
            f"\n[ANTI-LOOP NUDGE]\n{searches} searches and {opens} page opens WITHOUT a single candidate. STOP RESEARCHING. "
            "Re-read the observations: commit the strongest leads with propose_candidate NOW using the details you have. "
            "If truly nothing is viable, call done(message).\n"
        )
    elif ctx.observations and len(ctx.observations) % 4 == 0:
        nudge = (
            f"\n[STATUS CHECK @ STEP {len(ctx.observations)}]\nCandidates committed: {committed}. If any observation surfaced a "
            "viable lead not yet committed, propose_candidate it now. With 3+ commits, call done(message).\n"
        )

    committed_lines = "\n".join(f"- {c['title']} ({c['url']})" for c in ctx.committed) or "(none)"
    return f"""\
[USER REQUEST]
{ctx.message}

[CONVERSATION SO FAR]
{_history_block(ctx.conversation_id)}

[USER PROFILE: sizes / budget / fit]
{_user_block()}

[TASTE PROFILE]
{_profile_block()}

[CLOSET — id: item]
{_closet_block()}

[SAVED LOOKS]
{_saved_looks_block()}
Images of these looks are attached. If the request is "something to go with" one of them, match that outfit.

[FEEDBACK — HARD CONSTRAINTS]
{_feedback_block()}

[COMMITTED CANDIDATES] {committed}
{committed_lines}

[OBSERVATIONS SO FAR]
{obs_block}
{nudge}
Decide your next action (one tool call). Steps used: {len(ctx.observations)}/{MAX_STEPS}. Elapsed: {int(ctx.elapsed)}s.
"""


# --- tools --------------------------------------------------------------------
async def _resolve_urls(rows: List[Dict[str, str]]) -> List[Dict[str, str]]:
    resolved = await asyncio.gather(*(asyncio.to_thread(web_fetch.resolve_vertex_redirect, r["url"]) for r in rows))
    out, seen = [], set()
    for r, url in zip(rows, resolved):
        if web_fetch.is_vertex_redirector(url) or url in seen:
            continue
        seen.add(url)
        out.append({"title": r.get("title", ""), "url": url, "snippet": r.get("snippet", "")})
    return out


async def tool_search_web(ctx: Ctx, query: str) -> Dict[str, Any]:
    rows: List[Dict[str, str]] = []
    source = None
    if browser_bridge.use_extension():
        res = await browser_bridge.dispatch("google_search", {"query": query})
        if isinstance(res.get("results"), list):
            rows = [r for r in res["results"] if isinstance(r, dict) and r.get("url")]
            source = "chrome"
    if not rows:
        # Grounded search is primary; DuckDuckGo runs in parallel as a backstop for quota/latency spikes.
        ddg_task = asyncio.create_task(asyncio.to_thread(web_fetch.ddg_search, query))
        try:
            rows = await asyncio.wait_for(gemini.google_search(query), timeout=SEARCH_TIMEOUT_S)
            source = "google_search"
        except Exception as e:
            logger.warning("grounded search failed: %s", str(e)[:160])
        if rows:
            ddg_task.cancel()
        else:
            rows = await ddg_task
            source = "duckduckgo"
    results = (await _resolve_urls(rows))[:8]
    ctx.search_results.extend(results)
    return {"source": source, "results": results} if results else {"error": "no results", "source": source}


async def _perceive(ctx: Ctx, page_view: str) -> Optional[Dict[str, Any]]:
    prompt = (
        "You are the perception sub-agent for a shopping agent. Judge this page for the user's request.\n\n"
        f"[REQUEST] {ctx.message}\n[TASTE PROFILE] {_profile_block()}\n[USER] {_user_block()}\n"
        f"[FEEDBACK CONSTRAINTS]\n{_feedback_block(6)}\n[ALREADY COMMITTED] {len(ctx.committed)}\n\n"
        f"[PAGE]\n{page_view}\n\n"
        "Is there a specific purchasable product here that fits? If yes fill candidate_* (use the page's real URL and "
        "image). next_action_hint: 'propose_candidate' if a fitting product is clearly shown; 'extract_products' if this "
        "is a listing/category page with several items; 'open_different' if off-topic/blocked; 'done' if nothing more to add."
    )
    try:
        data, _ = await gemini.generate_json("flash", prompt, Insight, thinking="low", timeout=40)
        return data if isinstance(data, dict) else None
    except Exception as e:
        logger.warning("perception failed: %s", e)
        return None


async def tool_open_page(ctx: Ctx, url: str) -> Dict[str, Any]:
    if not url.startswith("http"):
        return {"error": "invalid url"}
    if web_fetch.is_vertex_redirector(url):
        url = await asyncio.to_thread(web_fetch.resolve_vertex_redirect, url)
        if web_fetch.is_vertex_redirector(url):
            return {"error": "unresolvable search redirector; open a different result"}

    page: Dict[str, Any] = {}
    if browser_bridge.use_extension():
        res = await browser_bridge.dispatch("open_tab", {"url": url})
        if "error" not in res:
            if isinstance(res.get("tab_id"), int):
                ctx.tab_id = res["tab_id"]
            page = {
                "url": res.get("url") or url,
                "title": res.get("title") or "",
                "text": (res.get("cleaned_text") or res.get("text") or res.get("page_text") or "")[:5000],
                "og_image": res.get("og_image") or res.get("image_url"),
                "products": res.get("products") or [],
            }
    if not page:
        fetched = await asyncio.to_thread(web_fetch.fetch_page, url)
        if "error" in fetched:
            return {"error": fetched["error"], "url": url}
        page = fetched
    ctx.page = page

    view = (
        f"Title: {page.get('title')}\nURL: {page.get('url')}\n"
        f"og:image: {page.get('og_image')}\nmeta price: {page.get('meta_price')}\n"
        f"Description: {page.get('description', '')[:300]}\n"
        f"JSON-LD products: {_short(page.get('products') or [], 1500)}\n\n"
        f"Page text (truncated):\n{(page.get('text') or '')[:3000]}"
    )
    insight = await _perceive(ctx, view)
    out: Dict[str, Any] = {"url": page.get("url"), "title": page.get("title")}
    if page.get("products"):
        out["products"] = page["products"][:8]
    if insight:
        out["insight"] = insight
        if insight.get("is_viable_lead") and insight.get("candidate_title"):
            ctx.leads.append({
                "title": insight["candidate_title"], "brand": insight.get("candidate_brand"),
                "price": insight.get("candidate_price") or page.get("meta_price"),
                "url": insight.get("candidate_url") or page.get("url"),
                "image_url": insight.get("candidate_image_url") or page.get("og_image"),
                "why": insight.get("why") or "",
            })
    else:
        out["text_preview"] = (page.get("text") or "")[:800]
    return out


async def tool_extract_products(ctx: Ctx) -> Dict[str, Any]:
    products: List[Dict[str, Any]] = []
    page_url = (ctx.page or {}).get("url") or ""
    text = ""
    if browser_bridge.use_extension() and ctx.tab_id is not None:
        res = await browser_bridge.dispatch("extract_products", {"tab_id": ctx.tab_id})
        if "error" not in res:
            products = [p for p in res.get("products") or [] if isinstance(p, dict)]
            page_url = res.get("page_url") or page_url
            text = res.get("cleaned_text") or ""
    if not products and ctx.page:
        products = list(ctx.page.get("products") or [])
        text = text or ctx.page.get("text") or ""
    if not products and text:
        try:
            data, _ = await gemini.generate_json(
                "flash",
                "Extract every distinct product on this page: title, brand, price (as shown), image_url, product_url "
                f"(absolute; page URL is {page_url}). Skip navigation.\n\nPage text:\n{text[:6000]}",
                ExtractedProducts,
                thinking="low",
                timeout=40,
            )
            products = data.get("products") or []
        except Exception as e:
            return {"error": f"extraction failed: {e}"}
    if not products:
        return {"error": "no products found on the current page; open a different result", "page_url": page_url}
    for p in products[:6]:
        if p.get("product_url"):
            ctx.leads.append({
                "title": p.get("title"), "brand": p.get("brand"), "price": p.get("price"),
                "url": p.get("product_url"), "image_url": p.get("image_url"), "why": "",
            })
    return {"page_url": page_url, "count": len(products), "products": products[:12]}


async def tool_propose_candidate(ctx: Ctx, args: Dict[str, Any]) -> Dict[str, Any]:
    url = (args.get("url") or "").strip()
    if not url.startswith("http"):
        return {"error": "missing/invalid url"}
    if web_fetch.is_vertex_redirector(url):
        url = await asyncio.to_thread(web_fetch.resolve_vertex_redirect, url)
        if web_fetch.is_vertex_redirector(url):
            return {"error": "url is a search redirector; open_page it first and use the real URL"}
    if any(c["url"] == url for c in ctx.committed):
        return {"ok": False, "note": "already proposed; pick a different product"}
    if _over_budget(args.get("price")):
        return {"ok": False, "note": f"price {args.get('price')} exceeds the user's budget ({store.get_user().get('budget')}); find a cheaper option"}

    valid_ids = {i["id"] for i in store.get_closet()}
    image_url = args.get("image_url") if isinstance(args.get("image_url"), str) and args["image_url"].startswith("http") else None
    if not image_url:
        image_url = await asyncio.to_thread(web_fetch.fetch_og_image, url)
    cand = {
        "id": uuid.uuid4().hex[:12],
        "title": (args.get("title") or "Untitled").strip()[:180],
        "brand": (args.get("brand") or None),
        "price": (str(args["price"]).strip() if args.get("price") else None),
        "url": url,
        "image_url": image_url,
        "why": (args.get("why") or "").strip()[:600],
        "matched_item_ids": [x for x in (args.get("matched_item_ids") or []) if x in valid_ids],
    }
    ctx.committed.append(cand)
    store.save_candidate(cand)
    await ctx.emit({"type": "candidate", "candidate": cand})
    return {"ok": True, "committed_count": len(ctx.committed)}


def _tool_summary(name: str, args: Dict[str, Any]) -> str:
    if name == "search_web":
        return f"Searching the web for “{args.get('query', '')}”"
    if name == "open_page":
        return f"Opening {args.get('url', '')}"
    if name == "extract_products":
        return "Extracting products from the page"
    if name == "propose_candidate":
        return f"Proposing {args.get('title', 'a product')}"
    if name == "done":
        return "Wrapping up"
    return name


def _amount(text: Any) -> Optional[float]:
    m = re.search(r"(\d[\d,]*(?:\.\d+)?)", str(text or ""))
    try:
        return float(m.group(1).replace(",", "")) if m else None
    except ValueError:
        return None


def _over_budget(price: Any) -> bool:
    """True when price clearly exceeds an 'under $N' / '$A-$B' style budget (+10% slack)."""
    budget = store.get_user().get("budget") or ""
    nums = [float(n.replace(",", "")) for n in re.findall(r"\d[\d,]*(?:\.\d+)?", budget)]
    amt = _amount(price)
    if not nums or amt is None:
        return False
    return amt > max(nums) * 1.1


def _default_why() -> str:
    p = store.get_profile() or {}
    kws = ", ".join((p.get("style_keywords") or [])[:2])
    return f"Fits your {kws} style." if kws else "Matches your request and closet."


async def _leads_from_search(ctx: Ctx, limit: int = 5) -> None:
    """Model-free fallback: fetch top search results over HTTP and harvest JSON-LD / OG product data."""
    urls = [r["url"] for r in ctx.search_results[:limit]]
    if not urls:
        return
    await ctx.emit({"type": "status", "text": "Checking the top results directly…"})
    pages = await asyncio.gather(*(asyncio.to_thread(web_fetch.fetch_page, u, 1500) for u in urls), return_exceptions=True)
    for r, page in zip(ctx.search_results, pages):
        if not isinstance(page, dict) or "error" in page:
            continue
        prods = page.get("products") or []
        if prods:
            p = prods[0]
            ctx.leads.append({
                "title": p.get("title"), "brand": p.get("brand"), "price": p.get("price"),
                "url": page.get("url") if len(prods) == 1 else (p.get("product_url") or page.get("url")),
                "image_url": p.get("image_url") or page.get("og_image"), "why": _default_why(),
            })
        elif page.get("meta_price") and page.get("title"):
            ctx.leads.append({
                "title": page["title"], "brand": None, "price": page["meta_price"], "url": page["url"],
                "image_url": page.get("og_image"), "why": _default_why(),
            })


async def _salvage(ctx: Ctx) -> None:
    """If the loop ends with too few commits, commit the best unconverted leads (with a real url)."""
    if len(ctx.committed) < 3 and len(ctx.leads) < 3:
        await _leads_from_search(ctx)
    for lead in ctx.leads:
        if len(ctx.committed) >= 3:
            break
        if not lead.get("url") or not lead.get("title"):
            continue
        if any(c["url"] == lead["url"] for c in ctx.committed) or _over_budget(lead.get("price")):
            continue
        await tool_propose_candidate(ctx, {**lead, "why": lead.get("why") or f"Matches your request: {ctx.message}"})


# --- entry points ---------------------------------------------------------------
async def _route_intent(message: str) -> str:
    try:
        data, _ = await gemini.generate_json(
            "lite",
            f"Classify the user's message to a personal stylist app.\nMessage: {message!r}\n"
            "'shopping' = wants to find/buy/get suggestions for specific products. 'other' = questions about style, "
            "their closet, outfit advice without buying, greetings.",
            Intent,
            thinking=None,
            timeout=20,
        )
        return data.get("intent", "shopping")
    except Exception as e:
        logger.warning("intent routing failed (%s); defaulting to shopping", e)
        return "shopping"


def _saved_looks_block(limit: int = 4) -> str:
    looks = store.get_looks()[:limit]
    if not looks:
        return "(none)"
    lines = []
    for look in looks:
        lines.append(
            f"- {look.get('title')} ({look.get('brand') or 'unknown brand'}, {look.get('price') or '?'}) "
            f"{look.get('url') or ''}"
            + (f" — {look['aesthetic_note']}" if look.get("aesthetic_note") else "")
        )
    return "\n".join(lines)


def _image_part(url: Optional[str]) -> Optional[bytes]:
    if not url or not str(url).startswith("/"):
        return None
    path = os.path.join(store.DATA_DIR, str(url).lstrip("/"))
    try:
        with open(path, "rb") as f:
            return f.read()
    except OSError:
        return None


def _saved_look_image_parts(limit: int = 3) -> List[Any]:
    """Try-on images the user saved, attached once on the first turn of each chat."""
    parts: List[Any] = []
    for look in store.get_looks()[:limit]:
        data = _image_part(look.get("image_url"))
        if not data:
            continue
        parts.append(
            f"[saved look image] {look.get('title')} | {look.get('brand') or ''} | {look.get('url') or ''}"
        )
        parts.append((data, "image/jpeg"))
    return parts


def _closet_image_parts(limit: int = 6) -> List[Any]:
    """Worn closet crops, attached once on the first agent turn for fidelity."""
    parts: List[Any] = []
    worn = [i for i in store.get_closet() if i.get("signal") == "worn" and i.get("crop_url")]
    for item in worn[:limit]:
        path = os.path.join(store.DATA_DIR, str(item["crop_url"]).lstrip("/"))
        try:
            with open(path, "rb") as f:
                data = f.read()
        except OSError:
            continue
        parts.append(f"[closet image] id={item['id']} {item.get('name')}")
        parts.append((data, "image/jpeg"))
    return parts


async def _verify_proposals(ctx: Ctx, proposals: List[Dict[str, Any]]) -> List[Dict[str, Any]]:
    """Argon accepts or rejects a batch. On failure, keep them so the demo doesn't stall."""
    if not proposals:
        return []
    lines = []
    for i, p in enumerate(proposals):
        lines.append(f"{i}. {p.get('title')} | {p.get('brand') or ''} | {p.get('price') or '?'} | {p.get('url')}")
    prompt = (
        "You are verifying shopping proposals against the user's real taste. Reject anything that clashes "
        "with the avoid-list, budget, fit preference, or closet. Accept only specific products.\n\n"
        f"[REQUEST] {ctx.message}\n[TASTE]\n{_profile_block()}\n[USER]\n{_user_block()}\n"
        f"[CLOSET]\n{_closet_block(40)}\n[SAVED LOOKS]\n{_saved_looks_block()}\n"
        "Reject a proposal that clashes with a saved look the user is trying to complete "
        "(for example sneakers that fight the jacket they just saved).\n"
        f"[AVOID]\n{_feedback_block(8)}\n\n[PROPOSALS]\n" + "\n".join(lines)
    )
    try:
        data, thought = await gemini.generate_json(
            "argon", prompt, VerdictBatch, thinking=VERIFY_THINKING, timeout=22
        )
        if thought:
            await ctx.emit({"type": "thought", "text": thought})
    except Exception as e:
        logger.warning("verification skipped: %s", str(e)[:160])
        return proposals
    by_index = {int(v.get("index", -1)): v for v in (data or {}).get("verdicts") or [] if isinstance(v, dict)}
    kept: List[Dict[str, Any]] = []
    for i, p in enumerate(proposals):
        v = by_index.get(i)
        if v and not v.get("accept", True):
            await ctx.emit({"type": "status", "text": f"Rejected {p.get('title')}: {v.get('reason') or 'not a fit'}"})
            continue
        if v and v.get("matched_item_ids"):
            p = {**p, "matched_item_ids": v["matched_item_ids"]}
            if v.get("reason"):
                p["why"] = v["reason"]
        kept.append(p)
    return kept


async def _execute_call(ctx: Ctx, call: Dict[str, Any]) -> Dict[str, Any]:
    name, args = call["name"], call.get("args") or {}
    if name == "search_web":
        return await tool_search_web(ctx, args.get("query") or ctx.message)
    if name == "open_page":
        return await tool_open_page(ctx, args.get("url") or "")
    if name == "extract_products":
        return await tool_extract_products(ctx)
    if name == "done":
        return {"ok": True}
    return {"error": f"unknown tool {name}"}


async def _answer_directly(ctx: Ctx) -> str:
    prompt = (
        f"[TASTE PROFILE]\n{_profile_block()}\n\n[USER]\n{_user_block()}\n\n[CLOSET]\n{_closet_block(80)}\n\n"
        f"[SAVED LOOKS]\n{_saved_looks_block()}\n\n"
        f"[CONVERSATION SO FAR]\n{_history_block(ctx.conversation_id)}\n\n[USER MESSAGE]\n{ctx.message}\n\n"
        "Reply as their personal stylist: concise, specific, reference their closet and any saved looks."
    )
    text, thought = await gemini.generate_text(
        "argon", [prompt, *_saved_look_image_parts(2)],
        system="You are Stylist, a warm, sharp personal stylist.", thinking="low",
    )
    if thought:
        await ctx.emit({"type": "thought", "text": thought})
    return text.strip()


async def run_chat(message: str, conversation_id: Optional[str], emit: Emit) -> None:
    cid = conversation_id or uuid.uuid4().hex
    ctx = Ctx(message, cid, emit)
    history = _conversations.setdefault(cid, [])
    final_text = ""
    try:
        await emit({"type": "status", "text": "Thinking about your request…"})
        intent = await _route_intent(message)
        if intent != "shopping":
            final_text = await _answer_directly(ctx)
            await emit({"type": "message", "text": final_text})
            return

        await emit({"type": "status", "text": "Planning a search from your taste profile…"})
        interaction_id: Optional[str] = None
        pending_results: Optional[List[Dict[str, Any]]] = None
        for step in range(MAX_STEPS):
            if ctx.elapsed > HARD_DEADLINE_S:
                await emit({"type": "status", "text": "Wrapping up with the best matches so far…"})
                break
            try:
                if interaction_id and pending_results is not None:
                    calls, thought, new_id, _ = await gemini.call_tools(
                        "argon", pending_results, TOOLS, thinking=AGENT_THINKING,
                        timeout=STEP_TIMEOUT_S, previous_interaction_id=interaction_id,
                    )
                else:
                    first: List[Any] = [_build_step_prompt(ctx), *_saved_look_image_parts(), *_closet_image_parts()]
                    calls, thought, new_id, _ = await gemini.call_tools(
                        "argon", first, TOOLS, system=SYSTEM, thinking=AGENT_THINKING, timeout=STEP_TIMEOUT_S,
                    )
                if new_id:
                    interaction_id = new_id
            except Exception as e:
                logger.warning("agent step %d failed: %s", step + 1, e)
                interaction_id = None
                pending_results = None
                await emit({"type": "status", "text": "Model is busy — retrying…"})
                continue
            if thought:
                await emit({"type": "thought", "text": thought})
            if not calls:
                break

            done_call = next((c for c in calls if c["name"] == "done"), None)
            work = [c for c in calls if c["name"] not in ("done", "propose_candidate")]
            proposals = [c for c in calls if c["name"] == "propose_candidate"]
            for c in work + proposals:
                await emit({
                    "type": "tool", "name": c["name"], "args": c["args"],
                    "summary": _tool_summary(c["name"], c["args"]),
                })
                await emit({"type": "status", "text": _tool_summary(c["name"], c["args"]) + "…"})

            executed = list(await asyncio.gather(*(_execute_call(ctx, c) for c in work))) if work else []
            paired: List[tuple] = []
            for c, result in zip(work, executed):
                logger.info("agent step %d %s -> %s", step + 1, c["name"], _short(result, 240))
                ctx.observations.append({"action": c["name"], "args": c["args"], "result": result})
                paired.append((c, result if isinstance(result, dict) else {"result": str(result)}))

            accepted = await _verify_proposals(ctx, [dict(c["args"]) for c in proposals])
            accepted_keys = {(p.get("title"), p.get("url")) for p in accepted}
            for c in proposals:
                key = (c["args"].get("title"), c["args"].get("url"))
                if key not in accepted_keys:
                    paired.append((c, {"rejected": True}))
                    continue
                match = next(p for p in accepted if (p.get("title"), p.get("url")) == key)
                result = await tool_propose_candidate(ctx, match)
                paired.append((c, result))
                accepted_keys.discard(key)

            if done_call and (len(ctx.committed) >= 3 or ctx.elapsed > SOFT_DEADLINE_S or not work):
                final_text = (done_call["args"].get("message") or "").strip()
                break
            if done_call:
                paired.append((done_call, {"error": "keep going — propose more or call done once you have 3"}))
            pending_results = gemini.function_results(paired)

        if len(ctx.committed) < 3:
            await _salvage(ctx)
        if not final_text:
            n = len(ctx.committed)
            final_text = (
                f"I found {n} option{'s' if n != 1 else ''} that fit your style — tap any to open it, and like/dislike to teach me."
                if n else "I couldn't verify good matches this time. Try being more specific (item, color, budget)."
            )
        await emit({"type": "message", "text": final_text})
    except asyncio.CancelledError:
        raise
    except Exception as e:
        logger.exception("chat failed")
        await emit({"type": "error", "text": str(e)[:300]})
    finally:
        history.append({"role": "user", "text": message})
        if final_text:
            history.append({"role": "assistant", "text": final_text})
        if ctx.committed:
            history.append({"role": "assistant", "text": "Proposed: " + "; ".join(c["title"] for c in ctx.committed)})
        await emit({"type": "done", "conversation_id": cid})
