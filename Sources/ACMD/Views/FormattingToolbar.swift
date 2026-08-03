import ACMDCore
import SwiftUI

struct FormattingToolbar: View {
    @ObservedObject var controller: MarkdownEditorController

    var body: some View {
        ControlGroup {
            formatButton("Bold", systemImage: "bold", command: .bold)
            formatButton("Italic", systemImage: "italic", command: .italic)
            formatButton("Strikethrough", systemImage: "strikethrough", command: .strikethrough)
            formatButton("Inline Code", systemImage: "chevron.left.forwardslash.chevron.right", command: .inlineCode)
            formatButton("Link", systemImage: "link", command: .link)

            Menu {
                ForEach(1...6, id: \.self) { level in
                    Button("Heading \(level)") {
                        controller.perform(.heading(level))
                    }
                }
            } label: {
                Label("Heading", systemImage: "textformat.size")
            }
            .help("Heading style")

            Menu {
                commandButton("Bulleted List", systemImage: "list.bullet", command: .unorderedList)
                commandButton("Numbered List", systemImage: "list.number", command: .orderedList)
                commandButton("Task List", systemImage: "checklist", command: .taskList)
                Divider()
                commandButton("Block Quote", systemImage: "text.quote", command: .blockQuote)
            } label: {
                Label("Lists and Quotes", systemImage: "list.bullet")
            }
            .help("Lists and quotes")

            Menu {
                commandButton("Insert Image", systemImage: "photo", command: .image)
                commandButton("Code Block", systemImage: "curlybraces.square", command: .codeBlock)
                commandButton("Horizontal Rule", systemImage: "minus", command: .horizontalRule)
            } label: {
                Label("More Formatting", systemImage: "ellipsis.circle")
            }
            .help("More Markdown formatting")
        }
        .controlGroupStyle(.navigation)
        .disabled(!controller.canEdit)
        .accessibilityIdentifier("formattingToolbar")
    }

    private func formatButton(
        _ title: String,
        systemImage: String,
        command: MarkdownFormatCommand
    ) -> some View {
        Button {
            controller.perform(command)
        } label: {
            Label(title, systemImage: systemImage)
        }
        .help(title)
        .accessibilityLabel(title)
    }

    private func commandButton(
        _ title: String,
        systemImage: String,
        command: MarkdownFormatCommand
    ) -> some View {
        Button {
            controller.perform(command)
        } label: {
            Label(title, systemImage: systemImage)
        }
    }
}
