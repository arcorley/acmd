import ACMDCore
import AppKit
import SwiftUI

struct MarkdownCommands: Commands {
    @FocusedObject private var editor: MarkdownEditorController?
    @FocusedValue(\.editorLayoutMode) private var layoutMode
    @FocusedValue(\.documentFileActions) private var documentFileActions
    @FocusedValue(\.editorViewActions) private var editorViewActions

    var body: some Commands {
        CommandGroup(after: .saveItem) {
            Button("Save As…") {
                NSApp.sendAction(
                    #selector(NSDocument.saveAs(_:)),
                    to: nil,
                    from: nil
                )
            }
            .keyboardShortcut("s", modifiers: [.command, .shift])
            .disabled(documentFileActions == nil)
        }

        CommandGroup(after: .importExport) {
            Menu("Export To") {
                Button("HTML…") {
                    documentFileActions?.exportHTML()
                }

                Button("PDF…") {
                    documentFileActions?.exportPDF()
                }
            }
            .disabled(documentFileActions == nil || documentFileActions?.isExporting == true)

            Button("Show in Finder") {
                documentFileActions?.revealInFinder?()
            }
            .disabled(documentFileActions?.revealInFinder == nil)
        }

        CommandGroup(replacing: .printItem) {
            Button("Print…") {
                documentFileActions?.printRenderedDocument()
            }
            .keyboardShortcut("p", modifiers: .command)
            .disabled(documentFileActions == nil || documentFileActions?.isExporting == true)
        }

        CommandGroup(after: .pasteboard) {
            Divider()
            Menu("Find") {
                Button("Find…") {
                    performFindAction(.showFindInterface)
                }
                .keyboardShortcut("f", modifiers: .command)
                .disabled(editorViewActions == nil)

                Button("Find and Replace…") {
                    performFindAndReplace()
                }
                .keyboardShortcut("f", modifiers: [.command, .option])
                .disabled(editorViewActions == nil)

                Button("Find Next") {
                    performFindAction(.nextMatch)
                }
                .keyboardShortcut("g", modifiers: .command)
                .disabled(editorViewActions == nil)

                Button("Find Previous") {
                    performFindAction(.previousMatch)
                }
                .keyboardShortcut("g", modifiers: [.command, .shift])
                .disabled(editorViewActions == nil)

                Divider()

                Button("Go to Line…") {
                    showGoToLinePanel()
                }
                .keyboardShortcut("l", modifiers: .command)
                .disabled(editorViewActions == nil)
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

            Divider()

            Menu("Editor Text Size") {
                Button("Increase") { editorViewActions?.zoomIn() }
                    .keyboardShortcut("+", modifiers: .command)
                    .disabled(editorViewActions?.canZoomIn != true)
                Button("Decrease") { editorViewActions?.zoomOut() }
                    .keyboardShortcut("-", modifiers: .command)
                    .disabled(editorViewActions?.canZoomOut != true)
                Button("Reset") { editorViewActions?.resetZoom() }
                    .keyboardShortcut("0", modifiers: .command)
                    .disabled(editorViewActions?.isDefaultZoom != false)
            }
            .disabled(editorViewActions == nil)

            Toggle("Wrap Lines", isOn: Binding(
                get: { editorViewActions?.wrapsLines ?? true },
                set: { newValue in
                    guard let actions = editorViewActions,
                          actions.wrapsLines != newValue else { return }
                    actions.toggleLineWrapping()
                }
            ))
            .disabled(editorViewActions == nil)

            Toggle("Show Line Numbers", isOn: Binding(
                get: { editorViewActions?.showsLineNumbers ?? true },
                set: { newValue in
                    guard let actions = editorViewActions,
                          actions.showsLineNumbers != newValue else { return }
                    actions.toggleLineNumbers()
                }
            ))
            .disabled(editorViewActions == nil)
        }
    }

    private var canFormat: Bool {
        editor?.canEdit == true && layoutMode?.wrappedValue != .preview
    }

    private func showGoToLinePanel() {
        guard let actions = editorViewActions else { return }

        let lineField = NSTextField(string: String(actions.currentLine))
        lineField.alignment = .right
        lineField.frame = NSRect(x: 0, y: 0, width: 180, height: 24)
        lineField.setAccessibilityLabel("Line number")

        let formatter = NumberFormatter()
        formatter.numberStyle = .none
        formatter.allowsFloats = false
        formatter.minimum = 1
        formatter.maximum = NSNumber(value: max(actions.totalLineCount, 1))
        lineField.formatter = formatter

        let alert = NSAlert()
        alert.messageText = "Go to Line"
        alert.informativeText = "Enter a line number from 1 to \(max(actions.totalLineCount, 1))."
        alert.alertStyle = .informational
        alert.accessoryView = lineField
        alert.addButton(withTitle: "Go")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = lineField

        let handleResponse: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .alertFirstButtonReturn else { return }
            let requestedLine = lineField.integerValue
            let line = min(max(requestedLine, 1), max(actions.totalLineCount, 1))
            actions.goToLine(line)
        }

        if let window = NSApp.keyWindow {
            alert.beginSheetModal(for: window, completionHandler: handleResponse)
            DispatchQueue.main.async {
                lineField.selectText(nil)
            }
        } else {
            handleResponse(alert.runModal())
        }
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

    private func performFindAndReplace() {
        editorViewActions?.focusEditor()
        DispatchQueue.main.async {
            let sender = NSMenuItem()
            sender.action = #selector(NSResponder.performTextFinderAction(_:))
            sender.tag = NSTextFinder.Action.showReplaceInterface.rawValue
            NSApp.sendAction(sender.action!, to: nil, from: sender)
        }
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
