# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Test suites: RSpec for the CLI (including end-to-end score joining against
  synthetic MXL fixtures) and Jest for the extension (PDF structure, URL
  filtering, injection guard).
- Local CI scripts (`scripts/ci/check-ruby.sh`, `scripts/ci/check-extension.sh`)
  used by GitHub Actions and runnable locally.

## [1.0.0] - 2026-07-22

### Added

- Chrome Manifest V3 extension that exports the MuseScore score pages
  accessible to the logged-in session into a single A4 PDF:
  - Scrolls the score viewer to trigger lazy loading and captures SVG page
    URLs even after MuseScore removes them from the DOM.
  - Renders pages to JPEG on a canvas and assembles the PDF entirely in the
    browser, with no external dependencies.
  - Names the download after the score's visible heading, falling back to
    page metadata, then the tab title.
- `pdf-to-score` CLI (Ruby) that converts a scanned sheet-music PDF into an
  editable score via Audiveris OMR:
  - Rasterizes the PDF with `pdftoppm`, transcribes each page in a fresh
    Audiveris process, and joins the parts detected on every page into one
    continuous score.
  - Exports MusicXML, MXL, and MuseScore (`.mscz`) formats, written into a
    single output folder named after the PDF.
  - Options for output location, format selection, DPI, Audiveris heap size,
    custom Audiveris/MuseScore paths, and keeping intermediate work files.
- GitHub Actions CI: RuboCop and a smoke test for the CLI, syntax checks and
  manifest validation for the extension.
- MIT license.
