// Background service worker: fetches score SVG pages on behalf of the content
// script, since MuseScore CDN pages cannot be read cross-origin from the page.
'use strict';

const FETCH_SVG_MESSAGE = 'FETCH_SVG_PAGE';
const SVG_PATH_PATTERN = /\/score_\d+\.svg(?:$|\?)/i;
const ALLOWED_HOST_SUFFIXES = ['.musescore.com', '.ustatik.com'];

chrome.runtime.onMessage.addListener((message, _sender, sendResponse) => {
  if (message?.type !== FETCH_SVG_MESSAGE) return false;

  fetchSvgPage(message.url).then(
    (dataUrl) => sendResponse({ ok: true, dataUrl }),
    (error) => sendResponse({ ok: false, error: error.message || String(error) })
  );
  return true;
});

async function fetchSvgPage(url) {
  const parsed = new URL(url);
  if (!isAllowedSvgUrl(parsed)) {
    throw new Error('The requested page is not an allowed MuseScore SVG URL.');
  }

  const response = await fetch(parsed.href, { credentials: 'include', cache: 'no-store' });
  if (!response.ok) throw new Error(`MuseScore returned HTTP ${response.status} for a score page.`);
  return blobToDataUrl(await response.blob());
}

function isAllowedSvgUrl(parsed) {
  const allowedHost = parsed.hostname === 'musescore.com' ||
    ALLOWED_HOST_SUFFIXES.some((suffix) => parsed.hostname.endsWith(suffix));
  return parsed.protocol === 'https:' && allowedHost && SVG_PATH_PATTERN.test(parsed.pathname + parsed.search);
}

function blobToDataUrl(blob) {
  return new Promise((resolve, reject) => {
    const reader = new FileReader();
    reader.onload = () => resolve(reader.result);
    reader.onerror = () => reject(reader.error || new Error('Could not read the SVG response.'));
    reader.readAsDataURL(blob);
  });
}
