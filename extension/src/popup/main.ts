import { getApiBase } from '../lib/config';
import { ACTIVITY_KEY, getActivity, type ActivityEntry } from '../lib/activity';

const dot = document.getElementById('dot') as HTMLSpanElement;
const statusEl = document.getElementById('status') as HTMLDivElement;
const list = document.getElementById('actions') as HTMLUListElement;
const closeBtn = document.getElementById('close') as HTMLButtonElement;
const optionsBtn = document.getElementById('options') as HTMLButtonElement;

function ago(ts: number): string {
  const s = Math.max(0, Math.round((Date.now() - ts) / 1000));
  if (s < 60) return `${s}s ago`;
  if (s < 3600) return `${Math.round(s / 60)}m ago`;
  return `${Math.round(s / 3600)}h ago`;
}

function renderActivity(entries: ActivityEntry[]): void {
  list.replaceChildren();
  if (!entries.length) {
    const li = document.createElement('li');
    li.className = 'muted';
    li.textContent = 'No browser actions yet.';
    list.append(li);
    return;
  }
  for (const e of entries) {
    const li = document.createElement('li');
    li.className = e.status;
    const tool = document.createElement('div');
    tool.className = 'tool';
    tool.textContent = e.summary;
    const detail = document.createElement('div');
    detail.className = 'detail muted';
    detail.textContent = `${e.status === 'running' ? 'running' : e.detail || e.status} · ${ago(e.started_at)}`;
    li.append(tool, detail);
    list.append(li);
  }
}

async function refreshStatus(): Promise<void> {
  const base = await getApiBase();
  try {
    const r = await fetch(`${base}/health`);
    const data = (await r.json()) as { ok?: boolean; browser?: string; extension_connected?: boolean };
    const connected = Boolean(data.extension_connected);
    dot.className = `dot ${data.ok && connected ? 'ok' : 'warn'}`;
    statusEl.textContent = `Backend ${base} · ${connected ? 'extension connected' : 'waiting for heartbeat'} · browser=${data.browser ?? '?'}`;
  } catch {
    dot.className = 'dot err';
    statusEl.textContent = `Backend offline at ${base}`;
  }
}

closeBtn.addEventListener('click', () => {
  void chrome.runtime.sendMessage({ type: 'close_stylist_tabs' }).then((r: { closed?: number } | undefined) => {
    closeBtn.textContent = `Closed ${r?.closed ?? 0} tab(s)`;
    setTimeout(() => (closeBtn.textContent = 'Close Stylist tabs'), 1500);
  });
});
optionsBtn.addEventListener('click', () => void chrome.runtime.openOptionsPage());

chrome.storage.onChanged.addListener((changes, area) => {
  if (area === 'session' && changes[ACTIVITY_KEY]) {
    renderActivity((changes[ACTIVITY_KEY].newValue as ActivityEntry[] | undefined) || []);
  }
});

void chrome.runtime.sendMessage({ type: 'wake' }).catch(() => {});
void getActivity().then(renderActivity);
void refreshStatus();
setInterval(() => void refreshStatus(), 3000);
