# MuseScore ⇄ PDF

Two complementary tools for moving sheet music between MuseScore and PDF:

- **Chrome extension** — exports the score pages you can already see on `musescore.com` into a single, print-ready PDF, whether the score is published as SVG pages or as images.
- **`pdf-to-score` CLI** — goes the other way: converts a scanned sheet-music PDF into an editable score (MusicXML, MXL, or MuseScore) using [Audiveris](https://audiveris.github.io/audiveris/) optical music recognition.

Neither tool bypasses access controls. The extension only captures pages that are already visible and accessible to your logged-in session — it does **not** discover hidden page URLs, bypass previews, or unlock subscription-only content. Only use these tools for scores you are authorized to download or reproduce.

## Chrome extension

A dependency-free Manifest V3 extension. It renders each page to high-quality JPEG on a canvas and assembles the PDF entirely in the browser — no remote JavaScript, no external services.

### Install locally

1. Open `chrome://extensions` in Chrome.
2. Enable **Developer mode**.
3. Click **Load unpacked** and select this folder.
4. Open a score on `musescore.com` and sign in if needed.
5. Click the extension icon, then **Export accessible pages**.

After updating the extension's files, click **Reload** on `chrome://extensions` before testing again. The popup can inject its page helper into a tab that was already open, so reloading the score page is normally unnecessary.

### How it works

- The extension scrolls the actual MuseScore viewer—or the browser window when the viewer is not independently scrollable—to trigger normal lazy loading. Page URLs are captured as soon as each virtualized page enters the viewport, even if MuseScore removes that image from the DOM later.
- Scores are published either as SVG pages (`score_3.svg`) or as images (`score_3.png@0`). Image pages are taken at their full size marker and drawn at their native resolution, since upscaling a raster adds nothing but bytes; SVG pages are still rendered above their nominal size.
- Recommended scores in the sidebar have a `score_0` of their own, so pages are only accepted from the asset folder the viewer is actually rendering, and a full-size page always beats a thumbnail of the same index.
- Page requests are made by the extension's background worker so MuseScore CDN pages can be read without content-script cross-origin restrictions.
- Pages are embedded into an A4-sized PDF and downloaded as a standard browser download, named after the score page's visible `<h1>` heading (falling back to page metadata, then the tab title).

### Caveats

- MuseScore can change its page markup at any time, which may require selector updates.
- Chrome may need permission to allow downloads from MuseScore.

## PDF to score CLI

A single-file Ruby script that turns a scanned PDF into an editable score:

```sh
./pdf-to-score input.pdf
```

It rasterizes the PDF at 300 DPI with `pdftoppm`, transcribes every page in a fresh Audiveris process to control memory usage, joins the pages into one continuous score, and imports the result into MuseScore when the `mscz` or `all` format is requested.

Audiveris aborts on some combinations of page and resolution, so a page that fails is rasterized again at 400, 300, 500, 250, and 600 DPI until one of them gets through. A page that fails at every resolution is left out and named in an error, after the score has been written from the pages that did work.

Parts are matched across pages by staff count rather than by position, because Audiveris detects parts page by page and may order them differently on each one. A part that no other page shares becomes a part of its own instead of being dropped, and a page missing a part contributes whole-measure rests so the parts stay aligned. Expect stray parts wherever the recognition split one staff across systems; they are yours to merge in MuseScore.

All outputs are written into a single folder named after the PDF (`./input/` in the example above). Use `--output` to relocate or rename that folder: pointing it at an existing directory creates the PDF-named folder inside it, while any other path is used as the folder itself.

```text
Usage: pdf-to-score [options] PDF
    -o, --output PATH                Output folder (default: folder named after the PDF)
    -f, --format FORMAT              musicxml, mxl, mscz, all (default: all)
        --dpi DPI                    Rasterization DPI (default: 300)
        --heap SIZE                  Heap per Audiveris page (default: 2G)
        --audiveris PATH             Audiveris app Contents directory
        --musescore PATH             MuseScore CLI executable
        --keep-work                  Retain PNG, OMR, and page MXL files
```

Requirements: Ruby, `pdftoppm` (Poppler), `zip`, `unzip`, [Audiveris](https://audiveris.github.io/audiveris/), and MuseScore 4 when requesting MSCZ output. Like all optical music recognition, the output normally needs manual correction afterwards.

## Development

CI (GitHub Actions) runs two jobs on every push: RuboCop, RSpec, and a smoke test for the CLI; syntax checks, manifest validation, and Jest for the extension. Run the same checks locally with:

```sh
bundle install && npm install   # once
scripts/ci/check-ruby.sh
scripts/ci/check-extension.sh
```

## License

[MIT](LICENSE)
