# ACMD

ACMD is a native macOS Markdown editor and renderer built with SwiftUI, AppKit, and WebKit. Its Markdown formatter, syntax tokenizer, parser, and HTML renderer are implemented in this repository; it has no third-party dependencies.

## Features

- Plain UTF-8 `.md` and `.markdown` documents with native open, save, autosave, undo, and redo
- Markdown-aware `NSTextView` editor with find, spellcheck, smart list continuation, and syntax highlighting
- Selection-aware Bold, Italic, Strikethrough, Inline Code, Link, Image, Heading, List, Quote, Code Block, and Horizontal Rule commands
- Editor, split, and rendered-preview layouts
- Rendered headings, inline styles, links, images, block quotes, lists, task lists, fenced code, tables, and horizontal rules
- Dynamic light/dark appearance, selectable preview text, relative image/link resolution, and native accessibility labels
- Word, character, line, and estimated reading-time statistics

## Build

Requirements: macOS 14 or newer and Xcode 15.3 or newer.

```sh
make test
make app
make dmg
make notarized-dmg
open .build/ACMD.app
```

`make dmg` creates a versioned, compressed disk image in `dist/` containing ACMD and an Applications-folder shortcut. When a Developer ID Application identity is installed, release builds use it automatically with hardened runtime and a secure timestamp; otherwise they receive an ad-hoc signature.

`make notarized-dmg` additionally submits the signed disk image through the `ACMD-notary` Keychain profile, waits for Apple to accept it, staples the ticket, and validates the result with Gatekeeper before atomically replacing the release artifact. Signing is pinned to team `AJ64G3AGXL`; override the team, identity, profile, or 30-minute notarization timeout with `ACMD_TEAM_ID`, `ACMD_SIGNING_IDENTITY`, `ACMD_NOTARY_PROFILE`, or `ACMD_NOTARY_TIMEOUT`. Never commit `.p8` or `.p12` credentials; both extensions are ignored by Git.

For development, open `Package.swift` in Xcode or run `make run`.

## Shortcuts

| Action | Shortcut |
| --- | --- |
| Bold | Command-B |
| Italic | Command-I |
| Strikethrough | Command-Shift-X |
| Inline code | Control-Command-C |
| Link | Command-K |
| Toggle rendered preview | Command-Shift-V |
| Editor only | Control-Command-1 |
| Split view | Control-Command-2 |
| Preview only | Control-Command-3 |

All document content remains vanilla Markdown. Editor colors and font traits are temporary display attributes and are never written into the file.
