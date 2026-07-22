# MuseScore ⇄ PDF

Two complementary tools for moving sheet music between MuseScore and PDF:

- **Chrome extension** — exports the score pages you can already see on `musescore.com` into a single, print-ready PDF.
- **`pdf-to-score` CLI** — goes the other way: converts a scanned sheet-music PDF into an editable score (MusicXML, MXL, or MuseScore) using [Audiveris](https://audiveris.github.io/audiveris/) optical music recognition.

Neither tool bypasses access controls. The extension only captures SVG pages that are already visible and accessible to your logged-in session — it does **not** discover hidden page URLs, bypass previews, or unlock subscription-only content. Only use these tools for scores you are authorized to download or reproduce.

## Chrome extension

A dependency-free Manifest V3 extension. It renders each SVG page to high-quality JPEG on a canvas and assembles the PDF entirely in the browser — no remote JavaScript, no external services.

### Install locally

1. Open `chrome://extensions` in Chrome.
2. Enable **Developer mode**.
3. Click **Load unpacked** and select this folder.
4. Open a score on `musescore.com` and sign in if needed.
5. Click the extension icon, then **Export accessible pages**.

After updating the extension's files, click **Reload** on `chrome://extensions` before testing again. The popup can inject its page helper into a tab that was already open, so reloading the score page is normally unnecessary.

### How it works

- The extension scrolls the actual MuseScore viewer—or the browser window when the viewer is not independently scrollable—to trigger normal lazy loading. SVG URLs are captured as soon as each virtualized page enters the viewport, even if MuseScore removes that image from the DOM later.
- SVG requests are made by the extension's background worker so MuseScore CDN pages can be read without content-script cross-origin restrictions.
- Pages are embedded into an A4-sized PDF and downloaded as a standard browser download, named after the score page's visible `<h1>` heading (falling back to page metadata, then the tab title).

### Caveats

- MuseScore can change its page markup at any time, which may require selector updates.
- Chrome may need permission to allow downloads from MuseScore.

## PDF to score CLI

A single-file Ruby script that turns a scanned PDF into an editable score:

```sh
./pdf-to-score input.pdf
```

It rasterizes the PDF at 300 DPI with `pdftoppm`, transcribes every page in a fresh Audiveris process to control memory usage, joins the parts detected consistently on every page into one continuous score, and imports the result into MuseScore when the `mscz` or `all` format is requested.

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

CI (GitHub Actions) lints the Ruby script with RuboCop and syntax-checks the extension scripts and manifest on every push. To run the same checks locally:

```sh
rubocop scripts/pdf_to_score.rb
node --check background.js content.js popup.js
```

## License

[MIT](LICENSE)
