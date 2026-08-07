import AppKit
import SwiftUI

struct DocumentView: View {
    @Binding var document: MarkdownDocument
    let fileURL: URL?

    @StateObject private var editorController = MarkdownEditorController()
    @StateObject private var exportController = MarkdownExportController()
    @StateObject private var findSession = MarkdownFindSession()
    @StateObject private var scrollSynchronizer = MarkdownScrollSynchronizer()
    @SceneStorage("ACMD.editorLayoutMode") private var layoutModeValue = EditorLayoutMode.split.rawValue

    private var layoutMode: EditorLayoutMode {
        get { EditorLayoutMode(rawValue: layoutModeValue) ?? .split }
        nonmutating set { layoutModeValue = newValue.rawValue }
    }

    private var layoutBinding: Binding<EditorLayoutMode> {
        Binding(
            get: { layoutMode },
            set: { newMode in
                let previousMode = layoutMode
                layoutMode = newMode
                scrollSynchronizer.setEnabled(newMode == .split)
                if newMode == .split {
                    let sourcePane: MarkdownScrollSynchronizer.Pane = previousMode == .preview
                        ? .preview
                        : .editor
                    DispatchQueue.main.async {
                        scrollSynchronizer.synchronize(from: sourcePane)
                    }
                }
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
            DocumentStatusBar(text: document.text, controller: editorController)
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
        .focusedValue(\.documentFileActions, documentFileActionContext)
        .focusedValue(\.editorViewActions, editorViewActionContext)
        .onAppear {
            scrollSynchronizer.setEnabled(layoutMode == .split)
            if layoutMode == .split {
                DispatchQueue.main.async {
                    scrollSynchronizer.synchronize(from: .editor)
                }
            }
            if layoutMode == .preview {
                DispatchQueue.main.async {
                    editorController.resignFocus()
                }
            }
        }
    }

    private var documentFileActionContext: DocumentFileActions {
        DocumentFileActions(
            isExporting: exportController.isPreparingOutput,
            exportHTML: {
                exportController.exportHTML(
                    markdown: document.text,
                    sourceURL: fileURL
                )
            },
            exportPDF: {
                exportController.exportPDF(
                    markdown: document.text,
                    sourceURL: fileURL
                )
            },
            printRenderedDocument: {
                exportController.printDocument(
                    markdown: document.text,
                    sourceURL: fileURL
                )
            },
            revealInFinder: fileURL.map { url in
                {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            }
        )
    }

    private var editorViewActionContext: EditorViewActions {
        EditorViewActions(
            fontSize: editorController.fontSize,
            canZoomIn: editorController.canZoomIn,
            canZoomOut: editorController.canZoomOut,
            isDefaultZoom: editorController.isDefaultZoom,
            wrapsLines: editorController.isWordWrapEnabled,
            showsLineNumbers: editorController.showsLineNumbers,
            currentLine: editorController.currentLine,
            totalLineCount: editorController.totalLineCount,
            zoomIn: editorController.zoomIn,
            zoomOut: editorController.zoomOut,
            resetZoom: editorController.resetZoom,
            toggleLineWrapping: editorController.toggleWordWrap,
            toggleLineNumbers: editorController.toggleLineNumbers,
            goToLine: { line in
                if layoutMode == .preview {
                    layoutBinding.wrappedValue = .editor
                }
                DispatchQueue.main.async {
                    editorController.goToLine(line)
                }
            },
            focusEditor: {
                if layoutMode == .preview {
                    layoutBinding.wrappedValue = .editor
                } else {
                    editorController.focus()
                }
            }
        )
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

            MarkdownPreviewView(
                markdown: document.text,
                documentURL: fileURL,
                scrollSynchronizer: scrollSynchronizer,
                findSession: findSession
            )
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
                isActive: showsEditor,
                showsVerticalScroller: true,
                scrollSynchronizer: scrollSynchronizer,
                findSession: findSession
            )
            if document.text.isEmpty {
                Text("Start writing Markdown…")
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .padding(.leading, editorController.showsLineNumbers ? 57 : 29)
                    .padding(.top, 27)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .focusedObject(editorController)
    }
}
