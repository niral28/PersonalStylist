import { DEFAULT_API_BASE, getApiBase, setApiBase } from '../lib/config';

const input = document.getElementById('apiBase') as HTMLInputElement;
const status = document.getElementById('status') as HTMLPreElement;
const saveBtn = document.getElementById('save') as HTMLButtonElement;

input.placeholder = DEFAULT_API_BASE;
void getApiBase().then((url) => {
  input.value = url;
});

saveBtn.addEventListener('click', () => {
  void (async () => {
    await setApiBase(input.value);
    const url = await getApiBase();
    input.value = url;
    status.textContent = 'Testing…';
    try {
      const r = await fetch(`${url}/health`);
      status.textContent = JSON.stringify(await r.json(), null, 2);
      void chrome.runtime.sendMessage({ type: 'wake' }).catch(() => {});
    } catch (e) {
      status.textContent = `Error: ${e}`;
    }
  })();
});
