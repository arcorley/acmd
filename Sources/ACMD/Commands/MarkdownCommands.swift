import ACMDCore
import SwiftUI

struct MarkdownCommands: Commands {
    @FocusedObject private var editor: MarkdownEditorController?
    @FocusedValue(\.editorLayoutMode) private var layoutMode

    var body: some Commands {
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
}
