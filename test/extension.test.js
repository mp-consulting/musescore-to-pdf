// Jest tests for the Chrome extension's pure logic. The scripts are evaluated
// in a VM sandbox with minimal window/chrome stubs; no browser required.
'use strict';

const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { Blob } = require('node:buffer');
const { TextEncoder } = require('node:util');

const root = path.join(__dirname, '..');
const read = (file) => fs.readFileSync(path.join(root, file), 'utf8');

function contentSandbox() {
  const sandbox = {
    window: {},
    chrome: { runtime: { onMessage: { addListener() { sandbox.listenerCount++; } } } },
    listenerCount: 0,
    setTimeout,
    TextEncoder,
    Blob
  };
  vm.createContext(sandbox);
  return sandbox;
}

function loadContentApi() {
  const sandbox = contentSandbox();
  vm.runInContext(read('content.js'), sandbox);
  return sandbox.window.museScoreToPdf;
}

function loadBackground() {
  const sandbox = { chrome: { runtime: { onMessage: { addListener() {} } } }, URL };
  vm.createContext(sandbox);
  vm.runInContext(read('background.js'), sandbox);
  return sandbox;
}

describe('content script', () => {
  test('registers its message listener only once when injected twice', () => {
    const sandbox = contentSandbox();
    const code = read('content.js');
    vm.runInContext(code, sandbox);
    vm.runInContext(code, sandbox);
    expect(sandbox.listenerCount).toBe(1);
  });

  test('addPageUrl collects score SVG URLs keyed by page index', () => {
    const api = loadContentApi();
    const pages = new Map();
    api.addPageUrl('https://musescore.com/static/score_3.svg?token=abc', pages);
    api.addPageUrl('https://cdn.ustatik.com/score_10.svg', pages);
    api.addPageUrl('https://musescore.com/static/score_3.svg', pages); // duplicate index
    api.addPageUrl('https://musescore.com/static/cover.png', pages); // not a score page
    api.addPageUrl('https://musescore.com/static/score_3.svg.bak', pages); // wrong suffix
    expect([...pages.keys()].sort((a, b) => a - b)).toEqual([3, 10]);
    expect(pages.get(3).index).toBe(3);
  });

  test('safeName strips filesystem-hostile characters and truncates', () => {
    const api = loadContentApi();
    expect(api.safeName('  My / Great: Score?  ')).toBe('My - Great- Score-');
    expect(api.safeName('a\\b|c<d>e"f')).toBe('a-b-c-d-e-f');
    expect(api.safeName('x'.repeat(200))).toHaveLength(120);
  });

  test('joinBytes concatenates byte arrays in order', () => {
    const api = loadContentApi();
    const joined = api.joinBytes(new Uint8Array([1, 2]), new Uint8Array([]), new Uint8Array([3]));
    expect([...joined]).toEqual([1, 2, 3]);
  });

  test('buildPdf produces a structurally valid PDF', async () => {
    const api = loadContentApi();
    const jpeg = (filler) => ({ bytes: new Uint8Array([0xff, 0xd8, filler, 0xff, 0xd9]), width: 100, height: 150 });
    const blob = api.buildPdf([jpeg(1), { ...jpeg(2), width: 300, height: 200 }]);
    expect(blob.type).toBe('application/pdf');

    const bytes = Buffer.from(await blob.arrayBuffer());
    const text = bytes.toString('latin1'); // 1 byte = 1 char, offsets stay valid
    expect(text.startsWith('%PDF-1.4')).toBe(true);
    expect(text.endsWith('%%EOF\n')).toBe(true);
    expect(text).toMatch(/\/Type \/Catalog/);
    expect(text).toMatch(/\/Count 2/);
    expect(text).toMatch(/\/Filter \/DCTDecode/);
    // First image is portrait, second landscape.
    expect(text).toMatch(/\/MediaBox \[0 0 595\.28 841\.89\]/);
    expect(text).toMatch(/\/MediaBox \[0 0 841\.89 595\.28\]/);

    // Every xref entry must point at the matching "N 0 obj" header.
    const offsets = [...text.matchAll(/^(\d{10}) 00000 n /gm)].map((match) => Number(match[1]));
    expect(offsets.length).toBeGreaterThan(0);
    offsets.forEach((offset, index) => {
      expect(text.startsWith(`${index + 1} 0 obj`, offset)).toBe(true);
    });
    const startxref = Number(text.match(/startxref\n(\d+)/)[1]);
    expect(text.startsWith('xref', startxref)).toBe(true);
  });
});

describe('background worker', () => {
  test('only allows MuseScore score SVG URLs', () => {
    const background = loadBackground();
    const allowed = (url) => background.isAllowedSvgUrl(new URL(url));
    expect(allowed('https://musescore.com/static/score_1.svg')).toBe(true);
    expect(allowed('https://cdn.s3.musescore.com/score_22.svg?token=x')).toBe(true);
    expect(allowed('https://cdn.ustatik.com/img/score_5.svg')).toBe(true);
    expect(allowed('http://musescore.com/static/score_1.svg')).toBe(false); // plain http
    expect(allowed('https://evilmusescore.com/score_1.svg')).toBe(false); // lookalike host
    expect(allowed('https://musescore.com/robots.txt')).toBe(false); // non-score path
    expect(allowed('https://musescore.com/score_1.svg.js')).toBe(false); // suffixed path
  });
});
