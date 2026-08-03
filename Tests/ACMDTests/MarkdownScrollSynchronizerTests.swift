import AppKit
import XCTest
@testable import ACMD

final class MarkdownScrollSynchronizerTests: XCTestCase {
    @MainActor
    func testSourceLinesSynchronizeBothDirectionsAndRespectDisabledState() {
        let editor = makeEditorScrollView(lineCount: 80)
        let synchronizer = MarkdownScrollSynchronizer()
        var requestedPreviewLine: CGFloat?
        synchronizer.attach(editor, as: .editor)
        synchronizer.attachPreview { requestedPreviewLine = $0 }
        synchronizer.setEnabled(true)

        scrollEditor(editor, toSourceLine: 18.5)
        synchronizer.synchronize(from: .editor)
        XCTAssertEqual(requestedPreviewLine ?? -1, 18.5, accuracy: 0.2)

        synchronizer.previewDidScroll(toSourceLine: 47.25)
        XCTAssertEqual(editorSourceLine(editor), 47.25, accuracy: 0.2)

        synchronizer.setEnabled(false)
        synchronizer.previewDidScroll(toSourceLine: 6)
        XCTAssertEqual(editorSourceLine(editor), 47.25, accuracy: 0.2)
    }

    @MainActor
    func testSuspendedPreviewMovementDoesNotPullEditor() {
        let editor = makeEditorScrollView(lineCount: 80)
        let synchronizer = MarkdownScrollSynchronizer()
        var requestedPreviewLine: CGFloat?
        synchronizer.attach(editor, as: .editor)
        synchronizer.attachPreview { requestedPreviewLine = $0 }
        synchronizer.setEnabled(true)

        scrollEditor(editor, toSourceLine: 32)
        synchronizer.beginSuspending(.preview)
        synchronizer.previewDidScroll(toSourceLine: 8)
        XCTAssertEqual(editorSourceLine(editor), 32, accuracy: 0.2)

        synchronizer.endSuspending(.preview)
        synchronizer.synchronize(from: .editor)
        XCTAssertEqual(requestedPreviewLine ?? -1, 32, accuracy: 0.2)
    }

    func testLineStartsHandleMixedNewlinesAndUTF16Characters() {
        XCTAssertEqual(
            EditorSourceMapper.lineStarts(in: "😀\r\nsecond\rthird\nfourth"),
            [0, 4, 11, 17]
        )
    }

    func testLineIndexUsesUTF16OffsetsAndClampsBeforeFirstLine() {
        let starts = [0, 4, 11, 17]
        XCTAssertEqual(EditorSourceMapper.lineIndex(atUTF16Location: -4, lineStarts: starts), 0)
        XCTAssertEqual(EditorSourceMapper.lineIndex(atUTF16Location: 3, lineStarts: starts), 0)
        XCTAssertEqual(EditorSourceMapper.lineIndex(atUTF16Location: 4, lineStarts: starts), 1)
        XCTAssertEqual(EditorSourceMapper.lineIndex(atUTF16Location: 16, lineStarts: starts), 2)
        XCTAssertEqual(EditorSourceMapper.lineIndex(atUTF16Location: 100, lineStarts: starts), 3)
    }

    @MainActor
    private func makeEditorScrollView(lineCount: Int) -> NSScrollView {
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        scrollView.hasVerticalScroller = true
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 180, height: 100))
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.string = (0..<lineCount)
            .map { "Source line \($0)" }
            .joined(separator: "\n")
        scrollView.documentView = textView
        if let layoutManager = textView.layoutManager,
           let textContainer = textView.textContainer {
            layoutManager.ensureLayout(for: textContainer)
            let height = layoutManager.usedRect(for: textContainer).height
                + textView.textContainerInset.height * 2
            textView.frame.size.height = max(height, scrollView.contentSize.height)
        }
        scrollView.layoutSubtreeIfNeeded()
        return scrollView
    }

    @MainActor
    private func scrollEditor(_ scrollView: NSScrollView, toSourceLine sourceLine: CGFloat) {
        guard let textView = scrollView.documentView as? NSTextView else {
            XCTFail("Expected an NSTextView document")
            return
        }
        EditorSourceMapper.scroll(
            textView,
            in: scrollView,
            toSourceLine: sourceLine,
            lineStarts: EditorSourceMapper.lineStarts(in: textView.string)
        )
    }

    @MainActor
    private func editorSourceLine(_ scrollView: NSScrollView) -> CGFloat {
        guard let textView = scrollView.documentView as? NSTextView else {
            XCTFail("Expected an NSTextView document")
            return -1
        }
        return EditorSourceMapper.sourceLine(
            in: textView,
            scrollView: scrollView,
            lineStarts: EditorSourceMapper.lineStarts(in: textView.string)
        )
    }
}
