// Background service worker: fetches score pages on behalf of the content
// script, since MuseScore CDN pages cannot be read cross-origin from the page.
'use strict';

const FETCH_PAGE_MESSAGE = 'FETCH_SCORE_PAGE';
// A page is score_<index> as SVG or as an image, optionally followed by the
// size marker MuseScore appends to image pages ("@0", "@500x660").
const PAGE_PATH_PATTERN = /\/score_\d+\.(?:svg|png|jpe?g)(?:@\d+(?:x\d+)?)?$/i;
const ALLOWED_HOST_SUFFIXES = ['.musescore.com', '.ustatik.com'];

chrome.runtime.onMessage.addListener((message, _sender, sendResponse) => {
  if (message?.type !== FETCH_PAGE_MESSAGE) return false;

  fetchScorePage(message.url).then(
    (dataUrl) => sendResponse({ ok: true, dataUrl }),
    (error) => sendResponse({ ok: false, error: error.message || String(error) })
  );
  return true;
});

async function fetchScorePage(url) {
  const parsed = new URL(url);
  if (!isAllowedPageUrl(parsed)) {
    throw new Error('The requested page is not an allowed MuseScore score URL.');
  }

  const response = await fetch(parsed.href, { credentials: 'include', cache: 'no-store' });
  if (!response.ok) throw new Error(`MuseScore returned HTTP ${response.status} for a score page.`);
  return blobToDataUrl(await response.blob());
}

function isAllowedPageUrl(parsed) {
  const allowedHost = parsed.hostname === 'musescore.com' ||
    ALLOWED_HOST_SUFFIXES.some((suffix) => parsed.hostname.endsWith(suffix));
  return parsed.protocol === 'https:' && allowedHost && PAGE_PATH_PATTERN.test(parsed.pathname);
}

function blobToDataUrl(blob) {
  return new Promise((resolve, reject) => {
    const reader = new FileReader();
    reader.onload = () => resolve(reader.result);
    reader.onerror = () => reject(reader.error || new Error('Could not read the score page response.'));
    reader.readAsDataURL(blob);
  });
}
