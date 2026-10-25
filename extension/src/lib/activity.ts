export interface ActivityEntry {
  action_id: string;
  tool: string;
  summary: string;
  status: 'running' | 'ok' | 'error';
  detail?: string;
  started_at: number;
  finished_at?: number;
}

export interface BridgeState {
  api_base: string;
  last_ok_at?: number;
  last_error?: string;
  last_error_at?: number;
}

export const ACTIVITY_KEY = 'recentActions';
export const BRIDGE_KEY = 'bridgeState';
const MAX_ENTRIES = 20;

export async function getActivity(): Promise<ActivityEntry[]> {
  const stored = await chrome.storage.session.get(ACTIVITY_KEY);
  return (stored[ACTIVITY_KEY] as ActivityEntry[] | undefined) || [];
}

export async function upsertActivity(entry: ActivityEntry): Promise<void> {
  const list = (await getActivity()).filter((e) => e.action_id !== entry.action_id);
  list.unshift(entry);
  await chrome.storage.session.set({ [ACTIVITY_KEY]: list.slice(0, MAX_ENTRIES) });
}

export async function getBridgeState(): Promise<BridgeState | undefined> {
  const stored = await chrome.storage.session.get(BRIDGE_KEY);
  return stored[BRIDGE_KEY] as BridgeState | undefined;
}

export async function setBridgeState(state: BridgeState): Promise<void> {
  await chrome.storage.session.set({ [BRIDGE_KEY]: state });
}
