#!/usr/bin/env bash
# Checks for the Chrome extension: JavaScript syntax, manifest validity, Jest.
# Requires node and npm; installs dev dependencies if needed.
set -euo pipefail
cd "$(dirname "$0")/../.."

[ -d node_modules ] || npm ci

echo "--- JavaScript syntax"
node --check background.js content.js popup.js

echo "--- Manifest validation"
node scripts/ci/validate_manifest.js

echo "--- Jest"
npx jest

echo "All extension checks passed"
