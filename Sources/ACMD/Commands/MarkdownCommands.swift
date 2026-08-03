import ACMDCore
import AppKit
import SwiftUI

struct MarkdownCommands: Commands {
    @FocusedObject private var editor: MarkdownEditorController?
    @FocusedValue(\.editorLayoutMode) private var layoutMode

    var body: some Commands {
        CommandGroup(after: .pasteboard) {
            Divider()
            Menu("Find") {
                Button("Find…") {
                    performFindAction(.showFindInterface)
                }
                .keyboardShortcut("f", modifiers: .command)

                Button("Find Next") {
                    performFindAction(.nextMatch)
                }
                .keyboardShortcut("g", modifiers: .command)

                Button("Find Previous") {
                    performFindAction(.previousMatch)
                }
                .keyboardShortcut("g", modifiers: [.command, .shift])
            }
        }

        CommandGroup(replacing: .textFormatting) {
            Button("Bold") { editor?.perform(.bold) }
                .keyboardShortcut("b", modifiers: .command)
                .disabled(!canFormat)
            Button("Italic") { editor?.perform(.italic) }
                .keyboardShortcut("i", modifiers: .command)
                .disabled(!canFormat)
            Button("Strikethrough") { editor?.perform(.strikethrough) }
                .keyboardShortcut("x", modifiers: [.command, .shift])
                .disabled(!canFormat)
        }

        CommandMenu("Markdown") {
            Button("Inline Code") { editor?.perform(.inlineCode) }
                .keyboardShortcut("c", modifiers: [.command, .control])
                .disabled(!canFormat)
            Button("Link") { editor?.perform(.link) }
                .keyboardShortcut("k", modifiers: .command)
                .disabled(!canFormat)
            Button("Image") { editor?.perform(.image) }
                .disabled(!canFormat)
            Divider()
            Menu("Heading") {
                ForEach(1...6, id: \.self) { level in
                    Button("Heading \(level)") {
                        editor?.perform(.heading(level))
                    }
                }
            }
            .disabled(!canFormat)
            Button("Bulleted List") { editor?.perform(.unorderedList) }
                .disabled(!canFormat)
            Button("Numbered List") { editor?.perform(.orderedList) }
                .disabled(!canFormat)
            Button("Task List") { editor?.perform(.taskList) }
                .disabled(!canFormat)
            Button("Block Quote") { editor?.perform(.blockQuote) }
                .disabled(!canFormat)
            Divider()
            Button("Code Block") { editor?.perform(.codeBlock) }
                .disabled(!canFormat)
            Button("Horizontal Rule") { editor?.perform(.horizontalRule) }
                .disabled(!canFormat)
        }

        CommandGroup(after: .toolbar) {
            Button("Toggle Rendered Preview") {
                guard let layoutMode else { return }
                layoutMode.wrappedValue = layoutMode.wrappedValue == .preview ? .editor : .preview
            }
            .keyboardShortcut("v", modifiers: [.command, .shift])
            .disabled(layoutMode == nil)

            Divider()

            Button("Editor Only") { layoutMode?.wrappedValue = .editor }
                .keyboardShortcut("1", modifiers: [.command, .control])
                .disabled(layoutMode == nil)
            Button("Editor and Preview") { layoutMode?.wrappedValue = .split }
                .keyboardShortcut("2", modifiers: [.command, .control])
                .disabled(layoutMode == nil)
            Button("Preview Only") { layoutMode?.wrappedValue = .preview }
                .keyboardShortcut("3", modifiers: [.command, .control])
                .disabled(layoutMode == nil)
        }
    }

    private var canFormat: Bool {
        editor?.canEdit == true && layoutMode?.wrappedValue != .preview
    }

    /// Sends the standard AppKit Find action through the active responder
    /// chain. This keeps split-view search focus-aware: NSTextView handles the
    /// source pane, while PreviewFindContainer handles the rendered pane.
    private func performFindAction(_ action: NSTextFinder.Action) {
        let sender = NSMenuItem()
        sender.action = #selector(NSResponder.performTextFinderAction(_:))
        sender.tag = action.rawValue

        if let preview = activePreviewFindContainer() {
            preview.performTextFinderAction(sender)
            return
        }
        NSApp.sendAction(sender.action!, to: nil, from: sender)
    }

    private func activePreviewFindContainer() -> PreviewFindContainer? {
        guard let window = NSApp.keyWindow,
              let contentView = window.contentView,
              let preview = descendantPreview(in: contentView) else { return nil }

        // The collapsed pane can briefly retain AppKit focus while SwiftUI
        // updates the layout. Always honor the visible single-pane mode first.
        if layoutMode?.wrappedValue == .preview {
            return preview
        }
        if layoutMode?.wrappedValue == .editor {
            preview.markInteractionInactive()
            return nil
        }

        let focusedView = window.firstResponder as? NSView
        if let focusedView {
            if let focusedPreview = ancestorPreview(of: focusedView) {
                return focusedPreview
            }
            if focusedView is NSTextView {
                preview.markInteractionInactive()
                return nil
            }
        }

        return preview.hasRecentInteraction ? preview : nil
    }

    private func ancestorPreview(of view: NSView) -> PreviewFindContainer? {
        var candidate: NSView? = view
        while let current = candidate {
            if let preview = current as? PreviewFindContainer {
                return preview
            }
            candidate = current.superview
        }
        return nil
    }

    private func descendantPreview(in view: NSView) -> PreviewFindContainer? {
        if let preview = view as? PreviewFindContainer {
            return preview
        }
        for subview in view.subviews {
            if let preview = descendantPreview(in: subview) {
                return preview
            }
        }
        return nil
    }
}
