#!/usr/bin/env bash
# Checks for the pdf-to-score CLI: syntax, RuboCop, RSpec, and a smoke test.
# Requires ruby and bundler; installs gems from the Gemfile if needed.
set -euo pipefail
cd "$(dirname "$0")/../.."

bundle check >/dev/null 2>&1 || bundle install --quiet

echo "--- Ruby syntax"
ruby -c scripts/pdf_to_score.rb

echo "--- RuboCop"
bundle exec rubocop scripts/pdf_to_score.rb

echo "--- RSpec"
bundle exec rspec

echo "--- CLI smoke test"
ruby scripts/pdf_to_score.rb --help >/dev/null
if ruby scripts/pdf_to_score.rb /nonexistent.pdf 2>/dev/null; then
  echo "Expected a non-zero exit for a missing input PDF" >&2
  exit 1
fi
echo "All Ruby checks passed"
