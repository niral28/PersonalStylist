import { getApiBase } from './lib/config';
import { getBridgeState, setBridgeState, upsertActivity, type ActivityEntry } from './lib/activity';
import type { PageExtract } from './lib/extract';

const GROUP_TITLE = 'Stylist';
const GROUP_COLOR: chrome.tabGroups.ColorEnum = 'pink';
const MAX_GROUP_TABS = 6;
const SESSION_GROUP_KEY = 'stylistGroupId';
const SESSION_TAB_KEY = 'activeStylistTabId';

const POLL_MS = 1000;
const POLL_OFFLINE_MS = 4000;
const HELLO_EVERY_MS = 10000;

/** Backend queue shape: moodboard sends {kind, action_id, scout_id, tool, args}; AGENTS.md documents {id, tool, args}. */
interface QueuedAction {
  id?: string;
  action_id?: string;
  kind?: string;
  scout_id?: string;
  tool: string;
  args?: Record<string, unknown>;
}

type ToolResult = Record<string, unknown>;

const inFlightActions = new Set<string>();
const doneActions: string[] = [];
let pollLoopRunning = false;
let lastHelloAt = 0;

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

async function postJson(path: string, body: unknown): Promise<Response> {
  const base = await getApiBase();
  return fetch(`${base}${path}`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(body),
  });
}

async function recordBridge(ok: boolean, error?: string): Promise<void> {
  const api_base = await getApiBase();
  const prev = (await getBridgeState()) || { api_base };
  const now = Date.now();
  await setBridgeState(
    ok
      ? { ...prev, api_base, last_ok_at: now }
      : { ...prev, api_base, last_error: error || 'unreachable', last_error_at: now },
  );
}

async function extensionHello(): Promise<void> {
  lastHelloAt = Date.now();
  try {
    await postJson('/extension/hello', { version: chrome.runtime.getManifest().version });
  } catch (e) {
    console.warn('[stylist] hello failed', e);
  }
}

/** Returns true if the backend responded. */
async function pollPendingActions(): Promise<boolean> {
  try {
    if (Date.now() - lastHelloAt > HELLO_EVERY_MS) void extensionHello();
    const base = await getApiBase();
    const resp = await fetch(`${base}/extension/pending-actions`);
    if (!resp.ok) {
      await recordBridge(false, `pending-actions HTTP ${resp.status}`);
      return false;
    }
    await recordBridge(true);
    const data = (await resp.json()) as { actions?: QueuedAction[] } | QueuedAction[];
    const actions = Array.isArray(data) ? data : data.actions || [];
    for (const action of actions) {
      if (action.kind && action.kind !== 'browser_action') continue;
      const id = action.action_id ?? action.id;
      if (typeof id !== 'string' || typeof action.tool !== 'string') continue;
      void handleBrowserAction(id, action.tool, action.args || {});
    }
    return true;
  } catch (e) {
    await recordBridge(false, String(e));
    return false;
  }
}

/** Tight poll loop while the worker is alive; storage writes each tick keep the MV3 worker from idling out. */
async function ensurePollLoop(): Promise<void> {
  if (pollLoopRunning) return;
  pollLoopRunning = true;
  try {
    for (;;) {
      const ok = await pollPendingActions();
      await sleep(ok ? POLL_MS : POLL_OFFLINE_MS);
    }
  } finally {
    pollLoopRunning = false;
  }
}

chrome.alarms.create('keepalive', { periodInMinutes: 0.5 });
chrome.alarms.onAlarm.addListener((alarm) => {
  if (alarm.name === 'keepalive') {
    void extensionHello();
    void ensurePollLoop();
  }
});

chrome.runtime.onInstalled.addListener(() => {
  void extensionHello();
  void ensurePollLoop();
});
chrome.runtime.onStartup.addListener(() => {
  void extensionHello();
  void ensurePollLoop();
});
void extensionHello();
void ensurePollLoop();

// ---------- Tab group ----------

async function getStoredGroupId(): Promise<number | undefined> {
  const stored = await chrome.storage.session.get(SESSION_GROUP_KEY);
  const existing = stored[SESSION_GROUP_KEY] as number | undefined;
  if (existing !== undefined) {
    try {
      await chrome.tabGroups.get(existing);
      return existing;
    } catch {
      await chrome.storage.session.remove(SESSION_GROUP_KEY);
    }
  }
  const found = (await chrome.tabGroups.query({ title: GROUP_TITLE }))[0];
  if (found) {
    await chrome.storage.session.set({ [SESSION_GROUP_KEY]: found.id });
    return found.id;
  }
  return undefined;
}

async function trimGroup(groupId: number, keepTabId: number): Promise<void> {
  const tabs = await chrome.tabs.query({ groupId });
  if (tabs.length <= MAX_GROUP_TABS) return;
  const oldest = tabs
    .filter((t) => t.id !== undefined && t.id !== keepTabId)
    .sort((a, b) => (a.id as number) - (b.id as number))
    .slice(0, tabs.length - MAX_GROUP_TABS)
    .map((t) => t.id as number);
  if (oldest.length) await chrome.tabs.remove(oldest).catch(() => {});
}

async function addTabToGroup(tabId: number): Promise<void> {
  try {
    let groupId = await getStoredGroupId();
    if (groupId === undefined) {
      groupId = await chrome.tabs.group({ tabIds: tabId });
      await chrome.tabGroups.update(groupId, { title: GROUP_TITLE, collapsed: false, color: GROUP_COLOR });
      await chrome.storage.session.set({ [SESSION_GROUP_KEY]: groupId });
    } else {
      await chrome.tabs.group({ tabIds: tabId, groupId });
      await chrome.tabGroups.update(groupId, { collapsed: false });
    }
    await trimGroup(groupId, tabId);
  } catch (e) {
    console.warn('[stylist] grouping failed', e);
  }
  await chrome.storage.session.set({ [SESSION_TAB_KEY]: tabId });
}

async function closeStylistTabs(): Promise<number> {
  const groupId = await getStoredGroupId();
  let closed = 0;
  if (groupId !== undefined) {
    const ids = (await chrome.tabs.query({ groupId })).map((t) => t.id).filter((id): id is number => id !== undefined);
    if (ids.length) {
      await chrome.tabs.remove(ids).catch(() => {});
      closed = ids.length;
    }
  }
  await chrome.storage.session.remove([SESSION_GROUP_KEY, SESSION_TAB_KEY]);
  return closed;
}

async function createStylistTab(url: string, active: boolean): Promise<number | undefined> {
  let tab: chrome.tabs.Tab | undefined;
  try {
    tab = await chrome.tabs.create({ url, active });
  } catch {
    const win = await chrome.windows.create({ url, focused: true });
    tab = win?.tabs?.[0];
  }
  if (!tab?.id) return undefined;
  await addTabToGroup(tab.id);
  if (active && tab.windowId !== undefined) {
    await chrome.windows.update(tab.windowId, { focused: true }).catch(() => {});
  }
  return tab.id;
}

async function resolveTabId(args: Record<string, unknown>): Promise<number> {
  const explicit = Number(args.tab_id);
  const stored = (await chrome.storage.session.get(SESSION_TAB_KEY))[SESSION_TAB_KEY] as number | undefined;
  const tabId = Number.isFinite(explicit) && explicit > 0 ? explicit : stored;
  if (!tabId) throw new Error('no active Stylist tab; call open_tab first');
  try {
    await chrome.tabs.get(tabId);
  } catch {
    throw new Error(`Stylist tab ${tabId} is closed; call open_tab again`);
  }
  return tabId;
}

// ---------- Content-script plumbing ----------

async function waitForTabLoad(tabId: number, timeoutMs = 20000, forceWait = false): Promise<void> {
  if (!forceWait) {
    const existing = await chrome.tabs.get(tabId);
    if (existing.status === 'complete') return;
  }
  await new Promise<void>((resolve) => {
    const timer = setTimeout(() => {
      chrome.tabs.onUpdated.removeListener(listener);
      resolve();
    }, timeoutMs);
    const listener = (id: number, info: chrome.tabs.TabChangeInfo) => {
      if (id === tabId && info.status === 'complete') {
        clearTimeout(timer);
        chrome.tabs.onUpdated.removeListener(listener);
        resolve();
      }
    };
    chrome.tabs.onUpdated.addListener(listener);
  });
}

/** Inject the content script into tabs that predate the extension install/reload. */
async function ensureContentScript(tabId: number): Promise<void> {
  try {
    await chrome.tabs.sendMessage(tabId, { type: 'ping' });
    return;
  } catch {
    /* not injected yet */
  }
  const files = chrome.runtime.getManifest().content_scripts?.[0]?.js || [];
  if (!files.length) return;
  await chrome.scripting.executeScript({ target: { tabId }, files }).catch(() => {});
}

async function sendToTab<T>(tabId: number, msg: unknown, attempts = 8): Promise<T | undefined> {
  for (let i = 0; i < attempts; i++) {
    try {
      return (await chrome.tabs.sendMessage(tabId, msg)) as T;
    } catch {
      if (i === 2) await ensureContentScript(tabId);
      await sleep(400);
    }
  }
  return undefined;
}

async function extractFromTab(tabId: number): Promise<PageExtract | undefined> {
  return sendToTab<PageExtract>(tabId, { type: 'extract_page' });
}

async function dismissPopupsInTab(tabId: number): Promise<number> {
  const r = await sendToTab<{ dismissed: number }>(tabId, { type: 'dismiss_popups' }, 4);
  return r?.dismissed ?? 0;
}

/** captureVisibleTab only captures the active tab in a window, so briefly focus it. */
async function captureTabScreenshot(tabId: number): Promise<string | undefined> {
  try {
    const tab = await chrome.tabs.get(tabId);
    if (!tab.windowId) return undefined;
    if (!tab.active) {
      await chrome.tabs.update(tabId, { active: true });
      await sleep(400);
    }
    const dataUrl = await chrome.tabs.captureVisibleTab(tab.windowId, { format: 'jpeg', quality: 72 });
    const comma = dataUrl.indexOf(',');
    return comma >= 0 ? dataUrl.slice(comma + 1) : dataUrl;
  } catch (e) {
    console.warn('[stylist] tab screenshot failed', e);
    return undefined;
  }
}

// ---------- Tools ----------

async function handleOpenTab(url: string, active: boolean): Promise<ToolResult> {
  if (!/^https?:\/\//i.test(url)) return { error: `invalid url: ${url || '(empty)'}` };
  const tabId = await createStylistTab(url, active);
  if (!tabId) return { error: 'failed to create tab' };
  await waitForTabLoad(tabId);
  await sleep(800);
  const popups_dismissed = await dismissPopupsInTab(tabId);
  if (popups_dismissed) await sleep(400);
  const extracted = await extractFromTab(tabId);
  if (!extracted) return { error: 'content script not ready on tab', tab_id: tabId };
  return {
    title: extracted.title,
    url: extracted.url || url,
    popups_dismissed,
    cleaned_text: extracted.cleaned_text.slice(0, 3000),
    clickables: extracted.clickables,
    og_image: extracted.og_image,
    price: extracted.price,
    currency: extracted.currency,
    product: extracted.product,
    tab_id: tabId,
  };
}

async function handleExtract(tabId: number): Promise<ToolResult> {
  const extracted = await extractFromTab(tabId);
  if (!extracted) return { error: 'content script not ready on tab', tab_id: tabId };
  return {
    page_url: extracted.url,
    title: extracted.title,
    cleaned_text: extracted.cleaned_text.slice(0, 6000),
    products_json_ld: extracted.products_json_ld,
    product: extracted.product,
    og: extracted.og,
    og_image: extracted.og_image,
    price: extracted.price,
    currency: extracted.currency,
    tab_id: tabId,
  };
}

async function handleClick(tabId: number, text: string): Promise<ToolResult> {
  const result = await sendToTab<PageExtract & { error?: string }>(tabId, { type: 'click_text', text }, 4);
  if (!result) return { error: 'content script not ready on tab' };
  if (result.error) return { error: result.error };
  return {
    clicked: text,
    url: result.url,
    page_text_after: (result.cleaned_text || '').slice(0, 2500),
    clickables: result.clickables || [],
    tab_id: tabId,
  };
}

async function handleScroll(tabId: number, direction: string, amountPx: number): Promise<ToolResult> {
  const result = await sendToTab<PageExtract>(tabId, { type: 'scroll', direction, amount_px: amountPx }, 4);
  if (!result) return { error: 'content script not ready on tab' };
  return {
    new_text: (result.cleaned_text || '').slice(0, 2500),
    clickables: result.clickables || [],
    url: result.url,
    tab_id: tabId,
  };
}

interface SerpMessageResult {
  results?: Array<{ title: string; url: string; snippet: string }>;
  blocked?: string;
  needs_consent?: boolean;
}

async function serpFromTab(tabId: number, attempts = 12): Promise<SerpMessageResult> {
  let last: SerpMessageResult = {};
  for (let i = 0; i < attempts; i++) {
    try {
      const resp = (await chrome.tabs.sendMessage(tabId, { type: 'extract_google_serp' })) as SerpMessageResult;
      last = resp || {};
      if (Array.isArray(resp?.results) && resp.results.length > 0) return resp;
      if (resp?.needs_consent || resp?.blocked === 'consent') {
        await chrome.tabs.sendMessage(tabId, { type: 'dismiss_google_consent' });
        await sleep(1800);
        continue;
      }
      if (resp?.blocked === 'captcha') return resp;
    } catch {
      if (i === 2) await ensureContentScript(tabId);
    }
    await sleep(500);
  }
  return last;
}

function googleSearchUrl(query: string, basicHtml: boolean): string {
  const params = new URLSearchParams({ q: query, num: '10', hl: 'en' });
  if (basicHtml) params.set('gbv', '1');
  return `https://www.google.com/search?${params}`;
}

async function handleGoogleSearch(query: string, active: boolean): Promise<ToolResult> {
  const trimmed = query.trim();
  if (!trimmed) return { error: 'empty search query' };

  const tabId = await createStylistTab('about:blank', active);
  if (!tabId) return { error: 'failed to create tab' };
  try {
    await chrome.search.query({ text: trimmed, tabId });
  } catch {
    await chrome.tabs.update(tabId, { url: googleSearchUrl(trimmed, false) });
  }
  await waitForTabLoad(tabId);
  await sleep(1500);

  let serp = await serpFromTab(tabId);
  if (!serp.results?.length && serp.blocked !== 'captcha') {
    await chrome.tabs.update(tabId, { url: googleSearchUrl(trimmed, true) });
    await waitForTabLoad(tabId, 20000, true);
    await sleep(1200);
    serp = await serpFromTab(tabId);
  }

  if (serp.blocked === 'captcha') {
    return {
      error: 'Google CAPTCHA / unusual traffic — complete it in the Stylist tab, then retry',
      tab_id: tabId,
      blocked: 'captcha',
    };
  }
  const results = Array.isArray(serp.results) ? serp.results : [];
  if (results.length === 0) {
    return {
      error: 'no Google results extracted (consent wall or layout change — check the Stylist tab)',
      tab_id: tabId,
      blocked: serp.blocked,
      screenshot_base64: await captureTabScreenshot(tabId),
    };
  }
  return { results, tab_id: tabId };
}

function summarizeArgs(tool: string, args: Record<string, unknown>): string {
  if (args.url) return `${tool} ${String(args.url).slice(0, 80)}`;
  if (args.query) return `${tool} "${String(args.query).slice(0, 60)}"`;
  if (args.text) return `${tool} "${String(args.text).slice(0, 40)}"`;
  return tool;
}

function summarizeResult(tool: string, result: ToolResult): string {
  if (tool === 'google_search' && Array.isArray(result.results)) return `${result.results.length} results`;
  const product = result.product as { name?: string; price_text?: string } | undefined;
  if (product?.name) return [product.name, product.price_text].filter(Boolean).join(' · ').slice(0, 90);
  if (typeof result.title === 'string') return result.title.slice(0, 90);
  return 'done';
}

function markDone(actionId: string): void {
  doneActions.push(actionId);
  if (doneActions.length > 200) doneActions.shift();
}

async function handleBrowserAction(actionId: string, tool: string, args: Record<string, unknown>): Promise<void> {
  if (inFlightActions.has(actionId) || doneActions.includes(actionId)) return;
  inFlightActions.add(actionId);

  const entry: ActivityEntry = {
    action_id: actionId,
    tool,
    summary: summarizeArgs(tool, args),
    status: 'running',
    started_at: Date.now(),
  };
  void upsertActivity(entry);

  let result: ToolResult = {};
  let error: string | undefined;
  const active = args.active === undefined ? true : Boolean(args.active);

  try {
    if (tool === 'open_tab' || tool === 'open_link') {
      result = await handleOpenTab(String(args.url || ''), active);
    } else if (tool === 'extract_products' || tool === 'extract_page') {
      if (args.url && !args.tab_id) {
        const opened = await handleOpenTab(String(args.url), active);
        if (opened.error) result = opened;
        else result = await handleExtract(opened.tab_id as number);
      } else {
        result = await handleExtract(await resolveTabId(args));
      }
    } else if (tool === 'google_search') {
      result = await handleGoogleSearch(String(args.query || ''), active);
    } else if (tool === 'click') {
      result = await handleClick(await resolveTabId(args), String(args.text || ''));
    } else if (tool === 'scroll' || tool === 'scroll_and_capture') {
      result = await handleScroll(
        await resolveTabId(args),
        String(args.direction || 'down'),
        Number(args.amount_px) || 800,
      );
    } else {
      error = `unknown tool: ${tool}`;
    }
  } catch (e) {
    error = e instanceof Error ? e.message : String(e);
  }

  try {
    await postJson('/browser/result', { action_id: actionId, result, error });
  } catch (e) {
    console.error('[stylist] failed to post browser result', e);
  } finally {
    inFlightActions.delete(actionId);
    markDone(actionId);
  }

  const failed = error || (typeof result.error === 'string' ? result.error : undefined);
  void upsertActivity({
    ...entry,
    status: failed ? 'error' : 'ok',
    detail: failed ? failed.slice(0, 160) : summarizeResult(tool, result),
    finished_at: Date.now(),
  });
}

// ---------- Popup / options messages ----------

chrome.runtime.onMessage.addListener((msg, _sender, sendResponse) => {
  if (msg?.type === 'wake') {
    void extensionHello();
    void ensurePollLoop();
    sendResponse({ ok: true });
    return false;
  }
  if (msg?.type === 'close_stylist_tabs') {
    void closeStylistTabs().then((closed) => sendResponse({ ok: true, closed }));
    return true;
  }
  return false;
});
