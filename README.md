# Honeycomb

Honeycomb is a native macOS file converter and editor. Select files on the Desktop or in Finder, hold the configured shortcut, and move the pointer to open a frosted-glass hex menu. This source snapshot is version **2.0.2**.

## Install

Requires macOS 13 or newer and Apple Command Line Tools. The installer can set up Homebrew and the conversion tools. Run it from the project folder:

```sh
/bin/bash ./install-honeycomb.command
```

The installer compiles and ad-hoc signs `/Applications/Honeycomb.app` and updates that app in place. It installs FFmpeg, Pandoc, ImageMagick, Poppler, and LibreOffice as needed. The extended Filee CLI builds locally with .NET and becomes available after its conversion probe passes.

Enable **Accessibility** and **Input Monitoring** for Honeycomb in System Settings. Allow **Automation → Finder** when asked so Honeycomb can read the file selection. Allow notifications for completed conversions and failures. A new app signature can require enabling the permissions again. To repair a stale entry independently:

```sh
/bin/bash ./install-honeycomb.command --repair-accessibility
/bin/bash ./install-honeycomb.command --repair-input-monitoring
```

## Use Honeycomb

1. Select one or more files. With the default shortcut, hold **Option + Space** and move the pointer.
2. Release over an output hex. Choose **More** to show the next ring, then click an option. **Back** returns to the previous ring and **Escape** cancels.
3. For a crop-and-ZIP workflow, choose **Crop**, set the crop, and pick **ZIP outputs**. Pick **Continue editing** instead if you want to convert the crop before zipping it.

Quick conversions cover common images, audio, video, documents, and PDFs. PowerPoint and Impress files (`.ppt`, `.pptx`, `.odp`) can export to PDF, and Excel and Calc files can export to PDF. XLSX and CSV can convert between each other. Filee adds more routes when its engines are available. The editor choices depend on the selected file type and whether you selected one file or a batch.

Conversions run in the background. Outputs go beside the source with a collision-safe filename. In **Open Honeycomb → Glass appearance**, choose a tint and strength or **Reset to neutral**. The same window has shortcut, login, and archive settings.

## Develop

| Path | Contents |
| --- | --- |
| `main.swift` | AppKit event tap and hex overlay, SwiftUI settings, conversion routing, editors, and ZIP workflows |
| `install-honeycomb.command` | Standalone installer with the embedded Swift and Filee CLI sources |
| `vendor/filee-cli/` | Filee CLI and the source projects it builds against |
| `scripts/sync-installer.py` | Embeds the editable sources and updates the Filee payload checksum |
| `LICENSES/` | License and attribution for the native editor code |

Edit `main.swift` or the Filee sources, then regenerate the installer with Python 3:

```sh
python3 scripts/sync-installer.py
python3 scripts/sync-installer.py --check
/bin/bash -n install-honeycomb.command
```

To type-check the Swift without changing the installed app:

```sh
mkdir -p build/module-cache
xcrun swiftc -swift-version 5 -typecheck \
  -module-cache-path build/module-cache \
  -target "$(uname -m)-apple-macosx13.0" main.swift
```

Configuration is stored in `~/honeycomb/config.json`. Runtime diagnostics are in `~/honeycomb/log.txt` and installer output is in `~/honeycomb/install.log`. If extended setup fails, check that log and retry with `/bin/bash ./install-honeycomb.command --extended-only`.

## Start a Git repository

```sh
git init -b main
git add .
git commit -m "Import Honeycomb 2.0.2 source"
```

## Upstream code

The native editors incorporate [Open Tangerine](https://github.com/sintaxerrorpvtltd/Open-Tangerine) code under GPL-3.0-only and retain the MIT attribution for [Satsuma](https://github.com/plyght/satsuma). The separately built [Filee](https://github.com/KnifeLemon/Filee) helper carries its MIT license and third-party notices in `vendor/filee-cli/`.
