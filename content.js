// Content script: discovers the score's pages (scrolling to trigger lazy
// loading), renders each to JPEG, assembles a single PDF, and downloads it.
// A score is published either as SVG pages or as PNG ones.
(() => {
  'use strict';

  // The popup injects this script when the manifest-declared copy is not
  // running yet; the guard keeps a second injection from re-registering.
  if (window.museScoreToPdf) return;

  const EXPORT_MESSAGE = 'EXPORT_SCORE_PDF';
  const FETCH_PAGE_MESSAGE = 'FETCH_SCORE_PAGE';

  const VIEWER_SELECTOR = '#jmuse-scroller-component';
  // Captures the asset folder, the page index, and the size marker that image
  // pages carry ("@0" is the full page, "@500x660" a thumbnail).
  const PAGE_URL_PATTERN = /\/([^/]+)\/score_(\d+)\.(svg|png|jpe?g)(@\d+(?:x\d+)?)?(?:[?#]|$)/i;

  // A page the viewer renders is far larger than any thumbnail beside it.
  const MIN_PAGE_EDGE_PX = 400;

  // Rendering: cap page raster size and JPEG quality; fallback dimensions
  // match MuseScore's standard page aspect ratio. SVG pages are worth
  // rendering above their nominal size, image pages have no detail to gain.
  const MAX_RENDER_EDGE_PX = 2200;
  const MAX_VECTOR_SCALE = 2;
  const MAX_IMAGE_SCALE = 1;
  const JPEG_QUALITY = 0.94;
  const FALLBACK_PAGE = { width: 874, height: 1134 };

  // A4 page size in PDF points.
  const A4_SHORT_PT = 595.28;
  const A4_LONG_PT = 841.89;

  // Lazy-load polling: sample every interval, give up after the attempt cap
  // or once several consecutive samples find no new pages.
  const POLL_INTERVAL_MS = 200;
  const POLL_MAX_ATTEMPTS = 15;
  const POLL_IDLE_LIMIT = 6;
  const HEADING_TIMEOUT_MS = 2500;

  const delay = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

  chrome.runtime.onMessage.addListener((message, _sender, sendResponse) => {
    if (message?.type !== EXPORT_MESSAGE) return false;
    exportScore().then(
      (pages) => sendResponse({ ok: true, pages }),
      (error) => sendResponse({ ok: false, error: error.message || String(error) })
    );
    return true;
  });

  // --- export pipeline ---

  async function exportScore() {
    const viewer = document.querySelector(VIEWER_SELECTOR);
    if (!viewer) throw new Error('No MuseScore score viewer was found on this page.');

    const scrollState = captureScrollState(viewer);
    const pages = await discoverPages(viewer);
    restoreScrollState(scrollState);
    if (!pages.length) throw new Error('No accessible score pages were found.');

    const rendered = [];
    for (const page of pages) rendered.push(await renderPageToJpeg(page.src));
    downloadBlob(buildPdf(rendered), `${await resolveScoreName()}.pdf`);
    return rendered.length;
  }

  function captureScrollState(viewer) {
    const scrollHost = findScrollableAncestor(viewer);
    return {
      viewer,
      scrollHost,
      windowY: window.scrollY,
      viewerTop: viewer.scrollTop,
      scrollHostTop: scrollHost?.scrollTop ?? 0
    };
  }

  function restoreScrollState({ viewer, scrollHost, windowY, viewerTop, scrollHostTop }) {
    window.scrollTo({ top: windowY, behavior: 'instant' });
    if (viewer.scrollHeight > viewer.clientHeight) viewer.scrollTop = viewerTop;
    if (scrollHost && scrollHost !== viewer) scrollHost.scrollTop = scrollHostTop;
  }

  // --- page discovery ---

  async function discoverPages(viewer) {
    const collected = new Map();
    let folder = '';
    const collect = () => {
      folder ||= findScoreFolder(viewer);
      if (!folder) return;
      collectVisiblePages(viewer, collected, folder);
      collectLoadedResources(collected, folder);
    };
    collect();

    const observer = new MutationObserver(collect);
    observer.observe(viewer, { subtree: true, childList: true, attributes: true, attributeFilter: ['src'] });
    try {
      await loadLazyPages(viewer, collected, collect);
    } finally {
      observer.disconnect();
    }
    collect();
    return [...collected.values()].sort((a, b) => a.index - b.index);
  }

  // Every page of a score lives in one asset folder. Recommended scores in the
  // sidebar have a page_0 of their own, so pages are only taken from the folder
  // the viewer is actually rendering.
  function findScoreFolder(viewer) {
    for (const img of viewer.querySelectorAll('img[src]')) {
      const rect = img.getBoundingClientRect();
      if (rect.width < MIN_PAGE_EDGE_PX || rect.height < MIN_PAGE_EDGE_PX) continue;
      const match = String(img.currentSrc || img.src).match(PAGE_URL_PATTERN);
      if (match) return match[1];
    }
    return '';
  }

  async function loadLazyPages(viewer, collected, collect) {
    const pageSlots = [...viewer.children].filter((element) => {
      const rect = element.getBoundingClientRect();
      return rect.width > 400 && rect.height > 500 && element.querySelectorAll(':scope > img').length <= 1;
    });

    for (const slot of pageSlots) {
      scrollPageIntoViewport(viewer, slot);
      await collectWhileLoading(collected, collect);
    }
  }

  function scrollPageIntoViewport(viewer, slot) {
    // MuseScore's main score container can be programmatically scrollable even
    // when its computed overflow style does not say "auto" or "scroll".
    const scrollHost = viewer.scrollHeight > viewer.clientHeight + 2
      ? viewer
      : findScrollableAncestor(viewer.parentElement);
    if (scrollHost) {
      const target = slot.offsetTop - Math.max(0, (scrollHost.clientHeight - slot.offsetHeight) / 2);
      scrollHost.scrollTop = Math.max(0, target);
      scrollHost.dispatchEvent(new Event('scroll'));
      return;
    }

    const viewerTop = window.scrollY + viewer.getBoundingClientRect().top;
    const target = viewerTop + slot.offsetTop - Math.max(0, (window.innerHeight - slot.offsetHeight) / 2);
    const documentScroller = document.scrollingElement || document.documentElement;
    documentScroller.scrollTop = Math.max(0, target);
    document.dispatchEvent(new Event('scroll', { bubbles: true }));
  }

  function findScrollableAncestor(element) {
    for (let current = element; current && current !== document.body; current = current.parentElement) {
      const style = getComputedStyle(current);
      const canScroll = /(auto|scroll)/.test(style.overflowY) && current.scrollHeight > current.clientHeight + 2;
      if (canScroll) return current;
    }
    return null;
  }

  async function collectWhileLoading(collected, collect) {
    let idleChecks = 0;
    let previousSize = collected.size;
    for (let attempt = 0; attempt < POLL_MAX_ATTEMPTS && idleChecks < POLL_IDLE_LIMIT; attempt++) {
      await delay(POLL_INTERVAL_MS);
      collect();
      if (collected.size === previousSize) {
        idleChecks++;
      } else {
        previousSize = collected.size;
        idleChecks = 0;
      }
    }
  }

  function collectVisiblePages(viewer, collected, folder) {
    for (const img of viewer.querySelectorAll('img[src]')) {
      addPageUrl(img.currentSrc || img.src, collected, folder);
    }
  }

  function collectLoadedResources(collected, folder) {
    for (const entry of performance.getEntriesByType('resource')) {
      addPageUrl(entry.name, collected, folder);
    }
  }

  function addPageUrl(url, collected, folder) {
    const match = String(url).match(PAGE_URL_PATTERN);
    if (!match) return;
    if (folder && match[1] !== folder) return;

    const index = Number(match[2]);
    const size = pageSizeRank(match[4]);
    const existing = collected.get(index);
    if (existing && existing.size >= size) return;
    collected.set(index, { src: String(url), index, size });
  }

  // MuseScore appends a size marker to image pages: "@0" asks for the page at
  // full size, "@500x660" for a thumbnail of it. The largest wins.
  function pageSizeRank(marker) {
    if (!marker || marker === '@0') return Infinity;
    return Number(marker.match(/@(\d+)/)?.[1]) || 0;
  }

  // --- score title detection ---

  async function resolveScoreName() {
    let heading = readHeading();
    if (!heading) {
      await waitForHeading(HEADING_TIMEOUT_MS);
      heading = readHeading();
    }

    const metadataTitle = document.querySelector('meta[property="og:title"]')?.content?.trim() ||
      document.querySelector('meta[name="twitter:title"]')?.content?.trim() ||
      readStructuredTitle() ||
      readScoreImageTitle();
    const fallback = document.title.replace(/\s*[|–].*$/, '').trim();
    const title = (heading || metadataTitle || fallback).replace(/\bPDF\b/gi, '').replace(/\s+/g, ' ').trim();
    return safeName(title) || 'musescore-score';
  }

  function readHeading() {
    return [...document.querySelectorAll('h1')]
      .map((element) => (element.innerText || element.textContent || '').trim())
      .find(Boolean);
  }

  function waitForHeading(timeout) {
    return new Promise((resolve) => {
      if (readHeading()) return resolve();
      const observer = new MutationObserver(() => {
        if (!readHeading()) return;
        observer.disconnect();
        resolve();
      });
      observer.observe(document.documentElement, { subtree: true, childList: true, characterData: true });
      setTimeout(() => { observer.disconnect(); resolve(); }, timeout);
    });
  }

  function readStructuredTitle() {
    for (const script of document.querySelectorAll('script[type="application/ld+json"]')) {
      try {
        const records = JSON.parse(script.textContent || 'null');
        const items = Array.isArray(records) ? records : [records];
        const title = items.find((item) => item && typeof item.name === 'string')?.name;
        if (title) return title.trim();
      } catch {}
    }
    return '';
  }

  function readScoreImageTitle() {
    const image = document.querySelector(`${VIEWER_SELECTOR} img[src*="/score_"][alt]`);
    return (image?.alt || '').replace(/\s+sheet music.*$/i, '').trim();
  }

  // --- page rendering ---

  async function renderPageToJpeg(url) {
    const image = new Image();
    image.decoding = 'async';
    image.src = await fetchPageDataUrl(url);
    await image.decode();

    const width = image.naturalWidth || FALLBACK_PAGE.width;
    const height = image.naturalHeight || FALLBACK_PAGE.height;
    const maxScale = isVectorPage(url) ? MAX_VECTOR_SCALE : MAX_IMAGE_SCALE;
    const scale = Math.min(maxScale, MAX_RENDER_EDGE_PX / Math.max(width, height));
    const canvas = document.createElement('canvas');
    canvas.width = Math.round(width * scale);
    canvas.height = Math.round(height * scale);
    const context = canvas.getContext('2d', { alpha: false });
    context.fillStyle = '#fff';
    context.fillRect(0, 0, canvas.width, canvas.height);
    context.drawImage(image, 0, 0, canvas.width, canvas.height);

    const blob = await new Promise((resolve) => canvas.toBlob(resolve, 'image/jpeg', JPEG_QUALITY));
    if (!blob) throw new Error('Could not render a score page.');
    return { bytes: new Uint8Array(await blob.arrayBuffer()), width: canvas.width, height: canvas.height };
  }

  function isVectorPage(url) {
    return /\.svg(?:@|[?#]|$)/i.test(String(url));
  }

  async function fetchPageDataUrl(url) {
    const response = await chrome.runtime.sendMessage({ type: FETCH_PAGE_MESSAGE, url });
    if (!response?.ok) throw new Error(response?.error || 'Could not fetch a score page.');
    return response.dataUrl;
  }

  // --- PDF assembly ---

  function buildPdf(images) {
    const encoder = new TextEncoder();
    const objects = [];
    const add = (value) => (objects.push(value), objects.length);
    const catalogId = add('');
    const pagesId = add('');
    const pageIds = images.map((image, index) => addImagePage(objects, add, pagesId, image, index, encoder));

    objects[catalogId - 1] = `<< /Type /Catalog /Pages ${pagesId} 0 R >>`;
    objects[pagesId - 1] = `<< /Type /Pages /Kids [${pageIds.map((id) => `${id} 0 R`).join(' ')}] /Count ${pageIds.length} >>`;
    return serializePdf(objects, catalogId, encoder);
  }

  function addImagePage(objects, add, pagesId, image, index, encoder) {
    const imageId = add({
      dict: `/Type /XObject /Subtype /Image /Width ${image.width} /Height ${image.height} /ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /DCTDecode`,
      bytes: image.bytes
    });
    const portrait = image.height >= image.width;
    const pageWidth = portrait ? A4_SHORT_PT : A4_LONG_PT;
    const pageHeight = portrait ? A4_LONG_PT : A4_SHORT_PT;
    const scale = Math.min(pageWidth / image.width, pageHeight / image.height);
    const drawWidth = image.width * scale;
    const drawHeight = image.height * scale;
    const x = (pageWidth - drawWidth) / 2;
    const y = (pageHeight - drawHeight) / 2;
    const stream = encoder.encode(`q ${drawWidth.toFixed(3)} 0 0 ${drawHeight.toFixed(3)} ${x.toFixed(3)} ${y.toFixed(3)} cm /Im${index} Do Q`);
    const contentId = add({ dict: '', bytes: stream });
    return add(`<< /Type /Page /Parent ${pagesId} 0 R /MediaBox [0 0 ${pageWidth} ${pageHeight}] /Resources << /XObject << /Im${index} ${imageId} 0 R >> >> /Contents ${contentId} 0 R >>`);
  }

  function serializePdf(objects, catalogId, encoder) {
    const chunks = [encoder.encode('%PDF-1.4\n%\xE2\xE3\xCF\xD3\n')];
    const offsets = [];
    let length = chunks[0].length;

    objects.forEach((object, index) => {
      offsets.push(length);
      const header = encoder.encode(`${index + 1} 0 obj\n`);
      const body = typeof object === 'string'
        ? encoder.encode(`${object}\nendobj\n`)
        : joinBytes(encoder.encode(`<< ${object.dict} /Length ${object.bytes.length} >>\nstream\n`), object.bytes, encoder.encode('\nendstream\nendobj\n'));
      chunks.push(header, body);
      length += header.length + body.length;
    });

    const xref = ['xref', `0 ${objects.length + 1}`, '0000000000 65535 f '];
    offsets.forEach((offset) => xref.push(`${String(offset).padStart(10, '0')} 00000 n `));
    xref.push(`trailer\n<< /Size ${objects.length + 1} /Root ${catalogId} 0 R >>`, `startxref\n${length}`, '%%EOF');
    chunks.push(encoder.encode(`${xref.join('\n')}\n`));
    return new Blob(chunks, { type: 'application/pdf' });
  }

  function joinBytes(...parts) {
    const result = new Uint8Array(parts.reduce((sum, part) => sum + part.length, 0));
    let offset = 0;
    for (const part of parts) {
      result.set(part, offset);
      offset += part.length;
    }
    return result;
  }

  // --- utilities ---

  function safeName(value) {
    return value.trim().replace(/[\\/:*?"<>|]+/g, '-').replace(/\s+/g, ' ').slice(0, 120);
  }

  function downloadBlob(blob, filename) {
    const url = URL.createObjectURL(blob);
    const link = document.createElement('a');
    link.href = url;
    link.download = filename;
    link.click();
    setTimeout(() => URL.revokeObjectURL(url), 60_000);
  }

  // Doubles as the double-injection guard and exposes the pure helpers so the
  // test suite can exercise them outside a browser.
  window.museScoreToPdf = { addPageUrl, pageSizeRank, isVectorPage, safeName, joinBytes, buildPdf };
})();
