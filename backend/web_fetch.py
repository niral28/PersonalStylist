"""HTTP-only page fetching: HTML -> text, OG tags, JSON-LD products, DDG search fallback,
and Vertex grounding-redirect resolution. All functions are sync; call via asyncio.to_thread."""

from __future__ import annotations

import html as html_lib
import json
import logging
import re
from typing import Any, Dict, List, Optional
from urllib.parse import quote, unquote, urljoin, urlparse, parse_qs

import requests

logger = logging.getLogger("stylist.web_fetch")

UA = (
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
    "(KHTML, like Gecko) Chrome/126.0 Safari/537.36"
)
HEADERS = {"User-Agent": UA, "Accept": "text/html,application/xhtml+xml", "Accept-Language": "en-US,en;q=0.9"}

VERTEX_REDIRECTOR_HOST = "vertexaisearch.cloud.google.com"


def is_vertex_redirector(url: str) -> bool:
    return bool(url) and VERTEX_REDIRECTOR_HOST in url


def resolve_vertex_redirect(url: str, timeout: float = 5.0) -> str:
    """Follow Vertex's grounding redirector to the real destination; original URL on failure."""
    if not is_vertex_redirector(url):
        return url
    for method in ("head", "get"):
        try:
            r = requests.request(method, url, allow_redirects=True, timeout=timeout, headers=HEADERS, stream=True)
            final = r.url or url
            r.close()
            if not is_vertex_redirector(final):
                return final
        except Exception:
            continue
    return url


def fetch_html(url: str, timeout: float = 10.0, max_bytes: int = 2_000_000) -> Optional[Dict[str, Any]]:
    try:
        r = requests.get(url, timeout=timeout, headers=HEADERS, allow_redirects=True, stream=True)
        ctype = r.headers.get("Content-Type", "")
        if r.status_code >= 400 or ("html" not in ctype and "xml" not in ctype):
            r.close()
            return {"error": f"HTTP {r.status_code} ({ctype or 'unknown type'})", "url": r.url}
        raw = b""
        for chunk in r.iter_content(65536):
            raw += chunk
            if len(raw) > max_bytes:
                break
        r.close()
        enc = r.encoding or "utf-8"
        return {"url": r.url, "html": raw.decode(enc, errors="replace")}
    except Exception as e:
        return {"error": str(e)[:200], "url": url}


_META_RE = re.compile(r"<meta\b[^>]*>", re.I)
_ATTR_RE = re.compile(r'([a-zA-Z:_-]+)\s*=\s*("([^"]*)"|\'([^\']*)\')')


def meta_tags(html: str) -> Dict[str, str]:
    out: Dict[str, str] = {}
    for tag in _META_RE.findall(html[:400_000]):
        attrs = {m.group(1).lower(): (m.group(3) if m.group(3) is not None else m.group(4)) for m in _ATTR_RE.finditer(tag)}
        key = attrs.get("property") or attrs.get("name") or attrs.get("itemprop")
        if key and "content" in attrs and key.lower() not in out:
            out[key.lower()] = html_lib.unescape(attrs["content"])
    return out


def page_title(html: str) -> str:
    m = re.search(r"<title[^>]*>(.*?)</title>", html, re.I | re.S)
    return html_lib.unescape(m.group(1).strip()) if m else ""


def html_to_text(html: str, max_chars: int = 6000) -> str:
    s = re.sub(r"(?is)<(script|style|noscript|svg|template|iframe)\b.*?</\1>", " ", html)
    s = re.sub(r"(?is)<!--.*?-->", " ", s)
    s = re.sub(r"(?i)<br\s*/?>|</(p|div|li|h[1-6]|tr|section|article)>", "\n", s)
    s = re.sub(r"(?s)<[^>]+>", " ", s)
    s = html_lib.unescape(s)
    s = re.sub(r"[ \t\r\f\v]+", " ", s)
    s = re.sub(r"\n\s*\n+", "\n", s)
    return s.strip()[:max_chars]


def _walk_jsonld(node: Any, out: List[Dict[str, Any]]) -> None:
    if isinstance(node, list):
        for n in node:
            _walk_jsonld(n, out)
        return
    if not isinstance(node, dict):
        return
    t = node.get("@type")
    types_ = t if isinstance(t, list) else [t]
    if any(isinstance(x, str) and x.lower() in ("product", "productgroup") for x in types_):
        out.append(node)
    for key in ("@graph", "itemListElement", "item", "mainEntity", "hasVariant"):
        if key in node:
            _walk_jsonld(node[key], out)


def _first(v: Any) -> Any:
    if isinstance(v, list):
        return v[0] if v else None
    return v


def jsonld_products(html: str, base_url: str) -> List[Dict[str, Any]]:
    nodes: List[Dict[str, Any]] = []
    for m in re.finditer(r'(?is)<script[^>]+type=["\']application/ld\+json["\'][^>]*>(.*?)</script>', html):
        try:
            _walk_jsonld(json.loads(m.group(1).strip()), nodes)
        except Exception:
            continue
    products: List[Dict[str, Any]] = []
    seen = set()
    for n in nodes:
        title = n.get("name")
        if not title or title in seen:
            continue
        seen.add(title)
        offers = _first(n.get("offers")) or {}
        if isinstance(offers, dict) and offers.get("@type") == "AggregateOffer":
            price = offers.get("lowPrice") or offers.get("price")
        else:
            price = offers.get("price") if isinstance(offers, dict) else None
        currency = offers.get("priceCurrency", "") if isinstance(offers, dict) else ""
        img = _first(n.get("image"))
        if isinstance(img, dict):
            img = img.get("url") or img.get("contentUrl")
        brand = n.get("brand")
        if isinstance(brand, dict):
            brand = brand.get("name")
        url = n.get("url") or (offers.get("url") if isinstance(offers, dict) else None) or base_url
        products.append({
            "title": str(title)[:200],
            "brand": brand if isinstance(brand, str) else None,
            "price": format_price(price, currency),
            "image_url": urljoin(base_url, img) if isinstance(img, str) else None,
            "product_url": urljoin(base_url, url) if isinstance(url, str) else base_url,
        })
    return products[:20]


def format_price(amount: Any, currency: str = "") -> Optional[str]:
    if amount in (None, ""):
        return None
    try:
        val = float(str(amount).replace(",", ""))
        sym = {"USD": "$", "EUR": "€", "GBP": "£", "CAD": "CA$", "AUD": "A$", "JPY": "¥"}.get((currency or "").upper())
        num = f"{val:,.0f}" if val == int(val) else f"{val:,.2f}"
        return f"{sym}{num}" if sym else (f"{num} {currency}".strip() if currency else f"${num}")
    except Exception:
        return str(amount)


def fetch_page(url: str, text_chars: int = 5000) -> Dict[str, Any]:
    """Fetch a URL and return {url, title, text, og_image, products, meta_price} or {error}."""
    res = fetch_html(url)
    if not res or "error" in res:
        return res or {"error": "fetch failed", "url": url}
    html, final = res["html"], res["url"]
    meta = meta_tags(html)
    og_image = meta.get("og:image") or meta.get("og:image:secure_url") or meta.get("twitter:image")
    price = meta.get("product:price:amount") or meta.get("og:price:amount")
    currency = meta.get("product:price:currency") or meta.get("og:price:currency") or ""
    return {
        "url": final,
        "title": meta.get("og:title") or page_title(html),
        "description": meta.get("og:description") or meta.get("description") or "",
        "og_image": urljoin(final, og_image) if og_image else None,
        "meta_price": format_price(price, currency),
        "products": jsonld_products(html, final),
        "text": html_to_text(html, text_chars),
    }


def fetch_og_image(url: str, timeout: float = 5.0) -> Optional[str]:
    res = fetch_html(url, timeout=timeout, max_bytes=600_000)
    if not res or "error" in res:
        return None
    meta = meta_tags(res["html"])
    img = meta.get("og:image") or meta.get("og:image:secure_url") or meta.get("twitter:image")
    if img:
        return urljoin(res["url"], img)
    prods = jsonld_products(res["html"], res["url"])
    return prods[0]["image_url"] if prods and prods[0].get("image_url") else None


def ddg_search(query: str, limit: int = 8) -> List[Dict[str, str]]:
    """DuckDuckGo HTML search fallback when Gemini grounding is unavailable."""
    results: List[Dict[str, str]] = []
    try:
        r = requests.post(
            "https://html.duckduckgo.com/html/",
            data={"q": query},
            headers=HEADERS,
            timeout=10,
        )
        if r.status_code == 200:
            for m in re.finditer(
                r'<a[^>]+class="result__a"[^>]+href="([^"]+)"[^>]*>(.*?)</a>.*?(?:class="result__snippet"[^>]*>(.*?)</a>)?',
                r.text,
                re.I | re.S,
            ):
                href = html_lib.unescape(m.group(1))
                if "duckduckgo.com/l/" in href:
                    q = parse_qs(urlparse(href if href.startswith("http") else "https:" + href).query)
                    href = unquote(q.get("uddg", [href])[0])
                if href.startswith("//"):
                    href = "https:" + href
                if not href.startswith("http") or "duckduckgo.com/y.js" in href:
                    continue
                title = html_lib.unescape(re.sub(r"<[^>]+>", "", m.group(2))).strip()
                snippet = html_lib.unescape(re.sub(r"<[^>]+>", "", m.group(3) or "")).strip()
                results.append({"title": title, "url": href, "snippet": snippet[:300]})
                if len(results) >= limit:
                    break
    except Exception as e:
        logger.warning("ddg search failed: %s", e)
    if results:
        return results
    try:
        r = requests.get(f"https://lite.duckduckgo.com/lite/?q={quote(query)}", headers=HEADERS, timeout=10)
        for href, title in re.findall(r'<a[^>]+class=["\']result-link["\'][^>]+href="([^"]+)"[^>]*>(.*?)</a>', r.text, re.I | re.S):
            href = html_lib.unescape(href)
            if "uddg=" in href:
                href = unquote(parse_qs(urlparse("https:" + href if href.startswith("//") else href).query).get("uddg", [href])[0])
            if href.startswith("http"):
                results.append({"title": re.sub(r"<[^>]+>", "", title).strip(), "url": href, "snippet": ""})
            if len(results) >= limit:
                break
    except Exception as e:
        logger.warning("ddg lite search failed: %s", e)
    return results
