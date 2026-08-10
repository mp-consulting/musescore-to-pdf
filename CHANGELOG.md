# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Extension support for scores published as images rather than SVG: page URLs
  ending in `.png`/`.jpg`, with the size marker MuseScore appends to them
  (`score_0.png@0`). Image pages are drawn at native resolution instead of
  being upscaled, and the full-size page is preferred over a thumbnail of it.
  Pages are accepted only from the asset folder the viewer is rendering, so a
  recommended score's own `score_0` cannot be mistaken for a page.
- Per-page DPI retry: a page Audiveris aborts on is rasterized again at 400,
  300, 500, 250, and 600 DPI until one of them transcribes. A page that fails
  at every resolution no longer ends the run - the score is written from the
  pages that worked, and the missing ones are named in an error.
- Test suites: RSpec for the CLI (including end-to-end score joining against
  synthetic MXL fixtures) and Jest for the extension (PDF structure, URL
  filtering, injection guard).
- Local CI scripts (`scripts/ci/check-ruby.sh`, `scripts/ci/check-extension.sh`)
  used by GitHub Actions and runnable locally.

### Changed

- Parts are joined across pages by staff count instead of by position, so a
  page that orders its parts differently no longer mixes instruments into one
  part. Parts unique to a page are kept as their own part rather than dropped
  with everything past the shared part count, and a page missing a part
  contributes whole-measure rests sized by that part's own divisions and time
  signature.

### Fixed

- A successful MuseScore import was reported as a failure when MuseScore 4
  crashed while shutting down, which it does routinely on macOS after writing
  the score. The import is now judged by the `.mscz` it leaves behind - present
  and containing its score entry, so a crash partway through the write is still
  a failure - and a stale file from an earlier run is removed beforehand rather
  than passing for a fresh one.
- MXL packaging failed when `--output` was given a relative path, because
  `zip` runs from a temporary directory.

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
