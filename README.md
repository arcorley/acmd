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
open .build/ACMD.app
```

`make dmg` creates a versioned, compressed disk image in `dist/` containing ACMD and an Applications-folder shortcut. Release builds are ad-hoc signed unless a Developer ID signing workflow is added.

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
