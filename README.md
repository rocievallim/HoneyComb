# Honeycomb

Local file converter for macOS. Hold **⌥ Option**, long-press a file in Finder, hover a format on the honeycomb menu, release. Conversion runs in the background. No uploads, no APIs, no internet at runtime.

## Install

1. Download `install-honeycomb.command`.
2. Terminal: `chmod +x ~/Downloads/install-honeycomb.command`
3. Right-click the file → **Open** → **Open** (it's unsigned, so macOS asks once).
4. Let it finish. The first run installs Homebrew packages and LibreOffice, which is slow.
5. Grant **Accessibility**, **Input Monitoring**, and **Automation → Finder** to `/Applications/Honeycomb.app`, then click **Restart** in the app.

Requires macOS 13+. Safe to rerun to update. Rerunning re-signs the app, so macOS may ask for the permissions again.

## Use

- Hold ⌥ and long-press a file (default 250 ms, adjustable in the app).
- Move onto a format hex and release to convert. Release over empty space or press Esc to cancel.
- **More** shows extra formats. Trash… / Copy… variants convert and then trash the original or copy the result.
- Output is saved next to the original and never overwrites (adds ` (1)`).
- Multiple selected files convert as a batch.

## Formats

Images (HEIC, JPG, PNG, WEBP, GIF, TIFF, PDF…), audio (MP3, M4A, WAV, FLAC, OPUS…), video (MP4, MOV, GIF, audio extract), documents (DOCX, PDF, TXT, MD, HTML…), spreadsheets, slides, and PDF to images or text. Plus compress and zip.

## How it works

- Swift, compiled with `swiftc` (no Xcode), packaged as an ad-hoc signed `Honeycomb.app`.
- An active `CGEventTap` catches Option + long-press and swallows the click, so Finder doesn't start its Option-drag copy.
- The menu is a transparent click-through overlay, with hover hit-tested from cursor coordinates.
- The Finder selection is read through AppleScript.
- Conversion engines: `sips`, ffmpeg, pandoc, ImageMagick, poppler, LibreOffice.

## Files

| Path | What |
|---|---|
| `install-honeycomb.command` | The installer. Source of truth. |
| `main.swift` | The app source, extracted from the installer for reading. |
| `~/honeycomb/config.json` | Hold time, hex order per file type, favorites (reloads live). |
| `~/honeycomb/log.txt` | App log. |
| `~/honeycomb/install.log` | Installer log. |

## Notes

- Installs Homebrew if missing and uses its official install script. Read the installer before running anything downloaded.
- Built for personal use. Not notarized.
- Built with AI assistance.

---

Built by Ezékiel Limboc, Industrial Engineering @ Batangas State University.
