import {
  clickByText,
  dismissGoogleConsent,
  dismissPopups,
  extractGoogleSerp,
  extractPage,
  scrollPage,
} from './lib/extract';

declare global {
  interface Window {
    __stylistContentLoaded?: boolean;
  }
}

if (!window.__stylistContentLoaded) {
  window.__stylistContentLoaded = true;

  chrome.runtime.onMessage.addListener((msg, _sender, sendResponse) => {
    if (msg?.type === 'ping') {
      sendResponse({ ok: true });
      return false;
    }
    if (msg?.type === 'extract_page') {
      sendResponse(extractPage());
      return false;
    }
    if (msg?.type === 'dismiss_popups') {
      const first = dismissPopups();
      // Newsletter modals often appear a beat after load; take a second pass.
      setTimeout(() => sendResponse({ dismissed: first + dismissPopups() }), 600);
      return true;
    }
    if (msg?.type === 'click_text') {
      const r = clickByText(document, msg.text || '');
      if (r.ok) {
        setTimeout(() => sendResponse({ ...extractPage(), clicked: msg.text }), 900);
        return true;
      }
      sendResponse({ error: r.error });
      return false;
    }
    if (msg?.type === 'scroll') {
      scrollPage(msg.direction === 'up' ? 'up' : 'down', Number(msg.amount_px) || 800);
      setTimeout(() => sendResponse(extractPage()), 700);
      return true;
    }
    if (msg?.type === 'dismiss_google_consent') {
      sendResponse({ dismissed: dismissGoogleConsent() });
      return false;
    }
    if (msg?.type === 'extract_google_serp') {
      const serp = extractGoogleSerp();
      sendResponse({
        results: serp.results,
        blocked: serp.blocked,
        needs_consent: serp.blocked === 'consent',
      });
      return false;
    }
    return false;
  });
}
