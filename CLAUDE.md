# CLAUDE.md

Guidance for Claude Code when working in this repository.

## Commit conventions

- Do not mention Claude in commits: no `Co-Authored-By: Claude`, no
  "Generated with Claude Code" lines, in commit messages or PR descriptions.

## Checks

Run the CI checks locally before committing:

```sh
scripts/ci/check-ruby.sh       # syntax, RuboCop, RSpec, CLI smoke test
scripts/ci/check-extension.sh  # syntax, manifest validation, Jest
```
