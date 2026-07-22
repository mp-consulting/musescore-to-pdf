// Validates manifest.json: Manifest V3, required keys present, and every
// referenced file exists on disk (catches renames that miss the manifest).
'use strict';

const assert = require('assert');
const fs = require('fs');

const manifest = JSON.parse(fs.readFileSync('manifest.json', 'utf8'));

assert.strictEqual(manifest.manifest_version, 3, 'manifest_version must be 3');
for (const key of ['name', 'version', 'action', 'background', 'content_scripts']) {
  assert.ok(manifest[key], `manifest is missing ${key}`);
}

const referencedFiles = [
  manifest.background.service_worker,
  manifest.action.default_popup,
  ...manifest.content_scripts.flatMap((script) => script.js)
];
for (const file of referencedFiles) {
  assert.ok(fs.existsSync(file), `referenced file does not exist: ${file}`);
}

console.log('manifest OK');
