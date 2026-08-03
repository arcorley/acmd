import SwiftUI

struct DocumentView: View {
    @Binding var document: MarkdownDocument
    let fileURL: URL?

    @StateObject private var editorController = MarkdownEditorController()
    @SceneStorage("ACMD.editorLayoutMode") private var layoutModeValue = EditorLayoutMode.split.rawValue

    private var layoutMode: EditorLayoutMode {
        get { EditorLayoutMode(rawValue: layoutModeValue) ?? .split }
        nonmutating set { layoutModeValue = newValue.rawValue }
    }

    private var layoutBinding: Binding<EditorLayoutMode> {
        Binding(
            get: { layoutMode },
            set: { newMode in
                layoutMode = newMode
                if newMode == .preview {
                    editorController.resignFocus()
                } else {
                    DispatchQueue.main.async {
                        editorController.focus()
                    }
                }
            }
        )
    }

    private var showsEditor: Bool { layoutMode != .preview }
    private var showsPreview: Bool { layoutMode != .editor }

    var body: some View {
        VStack(spacing: 0) {
            content
            Divider()
            DocumentStatusBar(text: document.text)
        }
        .frame(minWidth: 720, minHeight: 460)
        .toolbarRole(.editor)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Picker("View", selection: layoutBinding) {
                    ForEach(EditorLayoutMode.allCases) { mode in
                        Label(mode.title, systemImage: mode.symbolName)
                            .tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 168)
                .help("Editor and rendered preview layout")
                .accessibilityIdentifier("layoutModePicker")
            }

            if layoutMode != .preview {
                ToolbarItem(placement: .primaryAction) {
                    FormattingToolbar(controller: editorController)
                }
            }
        }
        .focusedValue(\.editorLayoutMode, layoutBinding)
        .onAppear {
            if layoutMode == .preview {
                DispatchQueue.main.async {
                    editorController.resignFocus()
                }
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        HSplitView {
            editorPane
                .frame(
                    minWidth: showsEditor ? 300 : 0,
                    idealWidth: showsEditor ? 480 : 0,
                    maxWidth: showsEditor ? .infinity : 0
                )
                .opacity(showsEditor ? 1 : 0)
                .allowsHitTesting(showsEditor)
                .accessibilityHidden(!showsEditor)

            MarkdownPreviewView(markdown: document.text, documentURL: fileURL)
                .frame(
                    minWidth: showsPreview ? 300 : 0,
                    idealWidth: showsPreview ? 480 : 0,
                    maxWidth: showsPreview ? .infinity : 0
                )
                .opacity(showsPreview ? 1 : 0)
                .allowsHitTesting(showsPreview)
                .accessibilityHidden(!showsPreview)
        }
    }

    private var editorPane: some View {
        ZStack(alignment: .topLeading) {
            MarkdownEditorView(
                text: $document.text,
                controller: editorController,
                isActive: showsEditor
            )
            if document.text.isEmpty {
                Text("Start writing Markdown…")
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 29)
                    .padding(.top, 27)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .focusedObject(editorController)
    }
}
