import AppKit
import Combine

/// Keeps corresponding Markdown source blocks aligned while allowing each pane
/// to retain its own native scroll range and scrollbar thumb position.
final class MarkdownScrollSynchronizer: ObservableObject {
    enum Pane {
        case editor
        case preview

        var counterpart: Pane {
            switch self {
            case .editor: return .preview
            case .preview: return .editor
            }
        }
    }

    private weak var editorScrollView: NSScrollView?
    private var previewScrollAction: ((CGFloat) -> Void)?
    private var previewSourceLine: CGFloat = 0
    private var editorObserver: NSObjectProtocol?
    private var expectedEditorSourceLine: CGFloat?
    private var expectedPreviewSourceLine: CGFloat?
    private var editorSuspensionCount = 0
    private var previewSuspensionCount = 0
    private var cachedEditorText = ""
    private var cachedEditorLineStarts = [0]
    private(set) var isEnabled = false

    deinit {
        if let editorObserver {
            NotificationCenter.default.removeObserver(editorObserver)
        }
    }

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
    }

    func attach(_ scrollView: NSScrollView, as pane: Pane) {
        guard pane == .editor, editorScrollView !== scrollView else { return }
        detachEditor()

        editorScrollView = scrollView
        let clipView = scrollView.contentView
        clipView.postsBoundsChangedNotifications = true
        editorObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: clipView,
            queue: .main
        ) { [weak self, weak scrollView] _ in
            guard let self, self.editorScrollView === scrollView else { return }
            self.editorViewportDidMove()
        }
    }

    /// Connects WebKit's remote scrolling implementation, which is not exposed
    /// as an NSScrollView on macOS. The closure receives a fractional source line.
    func attachPreview(scrollToSourceLine: @escaping (CGFloat) -> Void) {
        previewScrollAction = scrollToSourceLine
    }

    func detachPreview() {
        previewScrollAction = nil
        expectedPreviewSourceLine = nil
        previewSuspensionCount = 0
    }

    func previewDidScroll(toSourceLine sourceLine: CGFloat) {
        previewSourceLine = max(0, sourceLine)
        paneDidMove(.preview, toSourceLine: previewSourceLine)
    }

    func detach(_ scrollView: NSScrollView, from pane: Pane) {
        guard pane == .editor, editorScrollView === scrollView else { return }
        detachEditor()
    }

    func synchronize(from sourcePane: Pane) {
        let destinationPane = sourcePane.counterpart
        guard isEnabled,
              !isSuspended(sourcePane),
              !isSuspended(destinationPane),
              isAttached(sourcePane),
              isAttached(destinationPane) else { return }

        switch sourcePane {
        case .editor:
            guard let sourceLine = editorSourceLine() else { return }
            guard abs(sourceLine - previewSourceLine) > 0.05 else { return }
            expectedPreviewSourceLine = sourceLine
            previewSourceLine = sourceLine
            previewScrollAction?(sourceLine)

        case .preview:
            guard let currentEditorLine = editorSourceLine(),
                  abs(previewSourceLine - currentEditorLine) > 0.05 else { return }
            expectedEditorSourceLine = previewSourceLine
            scrollEditor(toSourceLine: previewSourceLine)
        }
    }

    /// Prevents preview document replacement from being mistaken for a user
    /// scroll. Calls may be nested when rapid edits replace a pending load.
    func beginSuspending(_ pane: Pane) {
        setSuspensionCount(suspensionCount(for: pane) + 1, for: pane)
    }

    func endSuspending(_ pane: Pane) {
        setSuspensionCount(max(0, suspensionCount(for: pane) - 1), for: pane)
    }

    private func editorViewportDidMove() {
        guard let sourceLine = editorSourceLine() else { return }
        paneDidMove(.editor, toSourceLine: sourceLine)
    }

    private func paneDidMove(_ pane: Pane, toSourceLine sourceLine: CGFloat) {
        guard !isSuspended(pane) else { return }

        if let expectedSourceLine = expectedSourceLine(for: pane) {
            setExpectedSourceLine(nil, for: pane)
            if abs(sourceLine - expectedSourceLine) <= 0.2 {
                return
            }
        }

        synchronize(from: pane)
    }

    private func editorSourceLine() -> CGFloat? {
        guard let editorScrollView,
              let textView = editorScrollView.documentView as? NSTextView else { return nil }
        let starts = editorLineStarts(for: textView.string)
        return EditorSourceMapper.sourceLine(
            in: textView,
            scrollView: editorScrollView,
            lineStarts: starts
        )
    }

    private func scrollEditor(toSourceLine sourceLine: CGFloat) {
        guard let editorScrollView,
              let textView = editorScrollView.documentView as? NSTextView else { return }
        let starts = editorLineStarts(for: textView.string)
        EditorSourceMapper.scroll(
            textView,
            in: editorScrollView,
            toSourceLine: sourceLine,
            lineStarts: starts
        )
    }

    private func editorLineStarts(for text: String) -> [Int] {
        if cachedEditorText != text {
            cachedEditorText = text
            cachedEditorLineStarts = EditorSourceMapper.lineStarts(in: text)
        }
        return cachedEditorLineStarts
    }

    private func detachEditor() {
        if let editorObserver {
            NotificationCenter.default.removeObserver(editorObserver)
        }
        editorObserver = nil
        editorScrollView = nil
        expectedEditorSourceLine = nil
        editorSuspensionCount = 0
    }

    private func isAttached(_ pane: Pane) -> Bool {
        switch pane {
        case .editor: return editorScrollView != nil
        case .preview: return previewScrollAction != nil
        }
    }

    private func expectedSourceLine(for pane: Pane) -> CGFloat? {
        switch pane {
        case .editor: return expectedEditorSourceLine
        case .preview: return expectedPreviewSourceLine
        }
    }

    private func setExpectedSourceLine(_ sourceLine: CGFloat?, for pane: Pane) {
        switch pane {
        case .editor: expectedEditorSourceLine = sourceLine
        case .preview: expectedPreviewSourceLine = sourceLine
        }
    }

    private func suspensionCount(for pane: Pane) -> Int {
        switch pane {
        case .editor: return editorSuspensionCount
        case .preview: return previewSuspensionCount
        }
    }

    private func setSuspensionCount(_ count: Int, for pane: Pane) {
        switch pane {
        case .editor: editorSuspensionCount = count
        case .preview: previewSuspensionCount = count
        }
    }

    private func isSuspended(_ pane: Pane) -> Bool {
        suspensionCount(for: pane) > 0
    }
}
