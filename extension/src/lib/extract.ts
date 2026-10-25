/** Page extraction logic used by the content script. */

export interface ProductSummary {
  name?: string;
  brand?: string;
  price?: string;
  currency?: string;
  price_text?: string;
  image?: string;
  images: string[];
  description?: string;
  sku?: string;
  availability?: string;
  url?: string;
  source: 'json-ld' | 'og' | 'json-ld+og' | 'none';
}

export interface OgTags {
  title?: string;
  description?: string;
  image?: string;
  site_name?: string;
  type?: string;
  url?: string;
  price_amount?: string;
  price_currency?: string;
  brand?: string;
}

export interface PageExtract {
  title: string;
  url: string;
  cleaned_text: string;
  clickables: string[];
  og_image?: string;
  price?: string;
  currency?: string;
  og: OgTags;
  products_json_ld: unknown[];
  product: ProductSummary;
}

type Json = Record<string, unknown>;

function metaContent(doc: Document, selectors: string[]): string | undefined {
  for (const sel of selectors) {
    const el = doc.querySelector(sel);
    const v = (el?.getAttribute('content') || el?.getAttribute('value'))?.trim();
    if (v) return v;
  }
  return undefined;
}

function isType(node: unknown, type: string): boolean {
  if (!node || typeof node !== 'object') return false;
  const t = (node as Json)['@type'];
  if (typeof t === 'string') return t === type || t.endsWith(`/${type}`);
  return Array.isArray(t) && t.some((x) => x === type);
}

const JSON_LD_DROP_KEYS = new Set(['review', 'reviews', '@context', 'potentialAction']);

function slimJsonLd(node: unknown, depth = 0): unknown {
  if (depth > 6 || node === null || typeof node !== 'object') return node;
  if (Array.isArray(node)) return node.slice(0, 20).map((n) => slimJsonLd(n, depth + 1));
  const out: Json = {};
  for (const [k, v] of Object.entries(node as Json)) {
    if (JSON_LD_DROP_KEYS.has(k)) continue;
    out[k] = slimJsonLd(v, depth + 1);
  }
  return out;
}

function parseJsonLdProducts(doc: Document, limit = 5): Json[] {
  const out: Json[] = [];
  const visit = (node: unknown, depth: number) => {
    if (!node || typeof node !== 'object' || depth > 4 || out.length >= limit) return;
    if (Array.isArray(node)) {
      for (const n of node) visit(n, depth + 1);
      return;
    }
    const obj = node as Json;
    if (isType(obj, 'Product') || isType(obj, 'ProductGroup')) {
      out.push(slimJsonLd(obj) as Json);
      return;
    }
    if (Array.isArray(obj['@graph'])) visit(obj['@graph'], depth + 1);
    if (isType(obj, 'ItemList') && Array.isArray(obj.itemListElement)) {
      for (const el of obj.itemListElement as unknown[]) {
        visit((el as Json)?.item ?? el, depth + 1);
      }
    }
    if (obj.mainEntity) visit(obj.mainEntity, depth + 1);
  };
  for (const script of doc.querySelectorAll('script[type="application/ld+json"]')) {
    try {
      visit(JSON.parse(script.textContent || ''), 0);
    } catch {
      /* skip malformed */
    }
  }
  return out;
}

function str(v: unknown): string | undefined {
  if (typeof v === 'string') return v.trim() || undefined;
  if (typeof v === 'number') return String(v);
  return undefined;
}

function nameOf(v: unknown): string | undefined {
  if (Array.isArray(v)) return nameOf(v[0]);
  if (v && typeof v === 'object') return str((v as Json).name);
  return str(v);
}

function imagesOf(v: unknown): string[] {
  if (!v) return [];
  if (Array.isArray(v)) return v.flatMap(imagesOf);
  if (typeof v === 'object') {
    const o = v as Json;
    return imagesOf(o.url || o.contentUrl);
  }
  const s = str(v);
  return s ? [s] : [];
}

function firstOffer(offers: unknown): Json | undefined {
  if (!offers) return undefined;
  if (Array.isArray(offers)) return firstOffer(offers[0]);
  if (typeof offers !== 'object') return undefined;
  const o = offers as Json;
  if (Array.isArray(o.offers) || (o.offers && typeof o.offers === 'object')) {
    const nested = firstOffer(o.offers);
    if (nested) return { ...o, ...nested };
  }
  return o;
}

function offerPrice(offer: Json | undefined): { price?: string; currency?: string; availability?: string } {
  if (!offer) return {};
  let price = str(offer.price) ?? str(offer.lowPrice) ?? str(offer.highPrice);
  let currency = str(offer.priceCurrency);
  const spec = Array.isArray(offer.priceSpecification) ? offer.priceSpecification[0] : offer.priceSpecification;
  if (!price && spec && typeof spec === 'object') {
    price = str((spec as Json).price);
    currency = currency ?? str((spec as Json).priceCurrency);
  }
  const availability = str(offer.availability)?.replace(/^https?:\/\/schema\.org\//, '');
  return { price, currency, availability };
}

export function formatPrice(price?: string, currency?: string): string | undefined {
  if (!price) return undefined;
  const n = Number(String(price).replace(/[^0-9.]/g, ''));
  if (!Number.isFinite(n) || n <= 0) return price;
  try {
    const text = new Intl.NumberFormat('en-US', {
      style: 'currency',
      currency: (currency || 'USD').toUpperCase(),
    }).format(n);
    return text.replace(/\.00$/, '');
  } catch {
    return currency ? `${price} ${currency}` : price;
  }
}

function absUrl(u: string | undefined, base: string): string | undefined {
  if (!u) return undefined;
  try {
    return new URL(u, base).href;
  } catch {
    return u;
  }
}

function readOg(doc: Document): OgTags {
  return {
    title: metaContent(doc, ['meta[property="og:title"]', 'meta[name="twitter:title"]']),
    description: metaContent(doc, [
      'meta[property="og:description"]',
      'meta[name="description"]',
      'meta[name="twitter:description"]',
    ]),
    image: metaContent(doc, [
      'meta[property="og:image:secure_url"]',
      'meta[property="og:image"]',
      'meta[name="og:image"]',
      'meta[name="twitter:image"]',
      'meta[name="twitter:image:src"]',
    ]),
    site_name: metaContent(doc, ['meta[property="og:site_name"]']),
    type: metaContent(doc, ['meta[property="og:type"]']),
    url: metaContent(doc, ['meta[property="og:url"]']),
    price_amount: metaContent(doc, [
      'meta[property="product:price:amount"]',
      'meta[property="og:price:amount"]',
      'meta[property="product:sale_price:amount"]',
      'meta[itemprop="price"]',
      '[itemprop="offers"] [itemprop="price"]',
    ]),
    price_currency: metaContent(doc, [
      'meta[property="product:price:currency"]',
      'meta[property="og:price:currency"]',
      'meta[itemprop="priceCurrency"]',
    ]),
    brand: metaContent(doc, ['meta[property="product:brand"]', 'meta[property="og:brand"]', 'meta[itemprop="brand"]']),
  };
}

/** Largest reasonably-sized visible image as a last-resort product image. */
function largestImage(doc: Document): string | undefined {
  let best: { src: string; area: number } | undefined;
  for (const img of doc.querySelectorAll('img')) {
    const src = img.currentSrc || img.src;
    if (!src || src.startsWith('data:')) continue;
    const w = img.naturalWidth || img.width;
    const h = img.naturalHeight || img.height;
    if (w < 250 || h < 250) continue;
    const area = w * h;
    if (!best || area > best.area) best = { src, area };
  }
  return best?.src;
}

function summarizeProduct(products: Json[], og: OgTags, doc: Document, pageUrl: string): ProductSummary {
  const p = products[0];
  const ld: Partial<ProductSummary> = {};
  if (p) {
    const variant = isType(p, 'ProductGroup') && Array.isArray(p.hasVariant) ? (p.hasVariant[0] as Json) : undefined;
    const offer = firstOffer(p.offers) ?? firstOffer(variant?.offers);
    const { price, currency, availability } = offerPrice(offer);
    ld.name = str(p.name);
    ld.brand = nameOf(p.brand) ?? nameOf(p.manufacturer);
    ld.price = price;
    ld.currency = currency;
    ld.availability = availability;
    ld.images = [...imagesOf(p.image), ...imagesOf(variant?.image)];
    ld.description = str(p.description);
    ld.sku = str(p.sku) ?? str(p.productID) ?? str(p.mpn);
    ld.url = str(p.url) ?? str(offer?.url);
  }
  const hasOg = Boolean(og.title || og.image || og.price_amount);
  const images = [...(ld.images || []), ...(og.image ? [og.image] : [])]
    .map((u) => absUrl(u, pageUrl))
    .filter((u): u is string => Boolean(u));
  const uniqueImages = [...new Set(images)].slice(0, 8);
  const image = uniqueImages[0] ?? largestImage(doc);
  const price = ld.price ?? og.price_amount;
  const currency = ld.currency ?? og.price_currency;
  return {
    name: ld.name ?? og.title ?? (doc.title || undefined),
    brand: ld.brand ?? og.brand ?? og.site_name,
    price,
    currency,
    price_text: formatPrice(price, currency),
    image,
    images: uniqueImages.length ? uniqueImages : image ? [image] : [],
    description: (ld.description ?? og.description)?.slice(0, 600),
    sku: ld.sku,
    availability: ld.availability,
    url: absUrl(ld.url ?? og.url, pageUrl) ?? pageUrl,
    source: p && hasOg ? 'json-ld+og' : p ? 'json-ld' : hasOg ? 'og' : 'none',
  };
}

function captureClickables(doc: Document): string[] {
  const out: string[] = [];
  const seen = new Set<string>();
  const sel =
    'button, a[href], [role="button"], [role="link"], [role="menuitem"], input[type="submit"], input[type="button"]';
  for (const el of doc.querySelectorAll(sel)) {
    const htmlEl = el as HTMLElement;
    const r = htmlEl.getBoundingClientRect();
    if (r.width === 0 || r.height === 0 || r.bottom < 0 || r.top > window.innerHeight) continue;
    const style = window.getComputedStyle(htmlEl);
    if (style.display === 'none' || style.visibility === 'hidden' || style.opacity === '0') continue;
    const role = htmlEl.getAttribute('role') || (htmlEl.tagName.toLowerCase() === 'a' ? 'link' : 'button');
    const text = (htmlEl.innerText || htmlEl.getAttribute('aria-label') || htmlEl.getAttribute('title') || '')
      .trim()
      .replace(/\s+/g, ' ')
      .slice(0, 80);
    if (!text) continue;
    const key = `${role}|${text}`;
    if (seen.has(key)) continue;
    seen.add(key);
    out.push(`${role}: "${text}"`);
    if (out.length >= 40) break;
  }
  return out;
}

function cleanText(raw: string): string {
  return raw
    .split('\n')
    .map((l) => l.replace(/\s+/g, ' ').trim())
    .filter(Boolean)
    .join('\n');
}

export function extractPage(doc: Document = document, pageUrl: string = location.href): PageExtract {
  const og = readOg(doc);
  const products = parseJsonLdProducts(doc);
  const product = summarizeProduct(products, og, doc, pageUrl);
  const main = doc.querySelector('main, [role="main"], #main') as HTMLElement | null;
  const text = cleanText((main?.innerText?.length ?? 0) > 400 ? main!.innerText : doc.body?.innerText || '');
  return {
    title: doc.title || '',
    url: pageUrl,
    cleaned_text: text.slice(0, 6000),
    clickables: captureClickables(doc),
    og_image: product.image,
    price: product.price,
    currency: product.currency,
    og,
    products_json_ld: products,
    product,
  };
}

function isVisible(el: Element): boolean {
  const h = el as HTMLElement;
  const r = h.getBoundingClientRect();
  if (r.width === 0 || r.height === 0) return false;
  const s = window.getComputedStyle(h);
  return s.display !== 'none' && s.visibility !== 'hidden' && s.opacity !== '0';
}

const COOKIE_ACCEPT_SELECTORS = [
  '#onetrust-accept-btn-handler',
  '#accept-recommended-btn-handler',
  'button#truste-consent-button',
  '#truste-consent-button',
  '.cc-allow',
  '.cc-accept',
  '#CybotCookiebotDialogBodyLevelButtonLevelOptinAllowAll',
  '#CybotCookiebotDialogBodyButtonAccept',
  '[data-testid="uc-accept-all-button"]',
  'button[data-cookiebanner="accept_button"]',
  '.osano-cm-accept-all',
  '#didomi-notice-agree-button',
  '.fc-cta-consent',
  'button[aria-label*="accept" i][aria-label*="cookie" i]',
];

const COOKIE_CONTAINER_SEL =
  '[id*="cookie" i], [class*="cookie" i], [id*="consent" i], [class*="consent" i], [id*="gdpr" i], [class*="gdpr" i], [aria-label*="cookie" i]';

const MODAL_SEL =
  '[role="dialog"], [aria-modal="true"], [class*="modal" i], [class*="popup" i], [class*="newsletter" i], [id*="newsletter" i], [class*="klaviyo" i], [id*="attentive" i], [class*="lightbox" i], [class*="overlay" i]';

const CLOSE_SEL =
  'button[aria-label*="close" i], button[aria-label*="dismiss" i], [role="button"][aria-label*="close" i], button[title*="close" i], [class*="close" i]:is(button, a, [role="button"]), [data-testid*="close" i], .needsclick.klaviyo-close-form';

const ACCEPT_LABELS = ['accept all', 'accept all cookies', 'allow all', 'accept cookies', 'i accept', 'accept', 'agree', 'got it', 'ok'];
const DISMISS_LABELS = ['no thanks', 'no, thanks', 'not now', 'maybe later', 'close', 'dismiss', 'continue shopping', '×', '✕', 'x'];

function labelOf(el: Element): string {
  const h = el as HTMLElement;
  return (h.innerText || h.getAttribute('aria-label') || (h as HTMLInputElement).value || '')
    .trim()
    .toLowerCase()
    .replace(/\s+/g, ' ');
}

/** Dismiss common cookie banners and newsletter/promo modals. Returns how many were dismissed. */
export function dismissPopups(doc: Document = document): number {
  let count = 0;
  const clicked = new Set<Element>();
  const click = (el: Element) => {
    if (clicked.has(el)) return;
    clicked.add(el);
    (el as HTMLElement).click();
    count++;
  };

  for (const sel of COOKIE_ACCEPT_SELECTORS) {
    const el = doc.querySelector(sel);
    if (el && isVisible(el)) {
      click(el);
      break;
    }
  }

  if (count === 0) {
    for (const container of doc.querySelectorAll(COOKIE_CONTAINER_SEL)) {
      if (!isVisible(container)) continue;
      const btn = [...container.querySelectorAll('button, a[role="button"], [role="button"]')].find((b) => {
        const l = labelOf(b);
        return isVisible(b) && ACCEPT_LABELS.some((a) => l === a || (a.length > 3 && l.startsWith(a)));
      });
      if (btn) {
        click(btn);
        break;
      }
    }
  }

  for (const modal of doc.querySelectorAll(MODAL_SEL)) {
    if (!isVisible(modal)) continue;
    const rect = modal.getBoundingClientRect();
    if (rect.width < 200 || rect.height < 100) continue;
    const closeBtn =
      [...modal.querySelectorAll(CLOSE_SEL)].find(isVisible) ||
      [...modal.querySelectorAll('button, [role="button"], a')].find(
        (b) => isVisible(b) && DISMISS_LABELS.includes(labelOf(b)),
      );
    if (closeBtn) click(closeBtn);
    if (count >= 4) break;
  }

  doc.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', bubbles: true }));
  for (const el of [doc.documentElement, doc.body]) {
    if (el && window.getComputedStyle(el).overflow === 'hidden') el.style.overflow = 'auto';
  }
  return count;
}

export function clickByText(doc: Document, text: string): { ok: boolean; error?: string } {
  const needle = text.trim().toLowerCase();
  if (!needle) return { ok: false, error: 'empty text' };
  const sel = 'button, a[href], [role="button"], [role="link"], input[type="submit"], input[type="button"]';
  const candidates = [...doc.querySelectorAll(sel)].filter(isVisible);
  const exact = candidates.find((el) => labelOf(el) === needle);
  const partial =
    exact ||
    candidates.find((el) => {
      const label = labelOf(el);
      return label && (label.includes(needle) || (label.length > 2 && needle.includes(label)));
    });
  if (partial) {
    (partial as HTMLElement).scrollIntoView({ block: 'center' });
    (partial as HTMLElement).click();
    return { ok: true };
  }
  return { ok: false, error: `no clickable element found matching '${text}'` };
}

export function scrollPage(direction: 'up' | 'down', amountPx: number): void {
  window.scrollBy({ top: direction === 'down' ? amountPx : -amountPx, behavior: 'smooth' });
}

export interface SearchResult {
  title: string;
  url: string;
  snippet: string;
}

export interface GoogleSerpExtract {
  results: SearchResult[];
  blocked?: 'captcha' | 'consent';
}

const SNIPPET_SEL =
  '.VwiC3b, .yXK7lf, .MUxGbd, .IsZvec, .lEBKkf, [data-sncf], [data-snf], div[style*="line-clamp"]';

function resolveGoogleResultUrl(href: string, base = 'https://www.google.com'): string {
  if (!href || href.startsWith('javascript:')) return '';
  try {
    const u = href.startsWith('http') ? new URL(href) : new URL(href, base);
    if (u.hostname.includes('google.') && (u.pathname === '/url' || u.pathname.endsWith('/url'))) {
      const target = u.searchParams.get('q') || u.searchParams.get('url');
      if (target) return target;
    }
    if (u.protocol === 'http:' || u.protocol === 'https:') return u.href;
  } catch {
    /* ignore bad href */
  }
  return '';
}

function isGoogleInternalUrl(url: string): boolean {
  try {
    const host = new URL(url).hostname.replace(/^www\./, '');
    return (
      host === 'google.com' ||
      host.endsWith('.google.com') ||
      /^google\.[a-z.]+$/.test(host) ||
      host.includes('gstatic.com') ||
      host === 'accounts.google.com'
    );
  } catch {
    return true;
  }
}

/** Click through Google's EU cookie / consent interstitial when present. */
export function dismissGoogleConsent(doc: Document = document): boolean {
  const known = doc.querySelector('#L2AGLb, #W0wltc, button[id*="accept"]') as HTMLElement | null;
  if (known) {
    known.click();
    return true;
  }
  const labels = ['accept all', 'i agree', 'agree', 'accept', 'reject all', 'continue'];
  for (const el of doc.querySelectorAll('button, div[role="button"], input[type="submit"]')) {
    const text = (el.textContent || (el as HTMLInputElement).value || '').trim().toLowerCase();
    if (!text) continue;
    if (labels.some((label) => text === label || text.includes(label))) {
      (el as HTMLElement).click();
      return true;
    }
  }
  return false;
}

function detectGoogleBlock(doc: Document): GoogleSerpExtract['blocked'] | undefined {
  const body = doc.body?.innerText || '';
  if (/unusual traffic|not a robot|systems have detected/i.test(body)) return 'captcha';
  if (doc.querySelector('form#captcha-form, #recaptcha, iframe[src*="recaptcha"]')) return 'captcha';
  const title = doc.title?.toLowerCase() || '';
  if (title.includes('consent') || doc.querySelector('form[action*="consent"]')) return 'consent';
  return undefined;
}

/** Extract organic Google SERP links from the current page. */
export function extractGoogleSerp(doc: Document = document, limit = 8): GoogleSerpExtract {
  const out: SearchResult[] = [];
  const seen = new Set<string>();

  const push = (title: string, href: string, snippet: string) => {
    const url = resolveGoogleResultUrl(href);
    if (!url || isGoogleInternalUrl(url) || seen.has(url)) return;
    seen.add(url);
    out.push({ title, url, snippet: snippet.replace(/\s+/g, ' ').slice(0, 300) });
  };

  const blockSelectors = ['div.g', 'div[data-sokoban-container] div.Gx5Zad', '#rso .MjjYud', '#rso > div', 'div[data-hveid]'];

  for (const sel of blockSelectors) {
    for (const block of doc.querySelectorAll(sel)) {
      const heading = block.querySelector('h3');
      if (!heading) continue;
      const link =
        (heading.closest('a[href]') as HTMLAnchorElement | null) ||
        (block.querySelector('a[href]') as HTMLAnchorElement | null);
      if (!link?.href) continue;
      const title = heading.textContent?.trim() || '';
      if (!title) continue;
      const snippet = block.querySelector(SNIPPET_SEL)?.textContent?.trim() || '';
      push(title, link.href, snippet);
      if (out.length >= limit) return { results: out };
    }
  }

  const searchRoot = doc.querySelector('#search, #rso, #center_col') || doc;
  for (const h3 of searchRoot.querySelectorAll('h3')) {
    const link =
      (h3.closest('a[href]') as HTMLAnchorElement | null) ||
      (h3.parentElement?.closest('a[href]') as HTMLAnchorElement | null) ||
      (h3.closest('[data-hveid], div.g, .MjjYud')?.querySelector('a[href]') as HTMLAnchorElement | null);
    if (!link?.href) continue;
    const title = h3.textContent?.trim() || '';
    if (!title) continue;
    const block = h3.closest('div[data-hveid], div.g, .MjjYud') || h3.parentElement;
    const snippet = block?.querySelector(SNIPPET_SEL)?.textContent?.trim() || '';
    push(title, link.href, snippet);
    if (out.length >= limit) return { results: out };
  }

  const blocked = out.length === 0 ? detectGoogleBlock(doc) : undefined;
  return { results: out, blocked };
}
