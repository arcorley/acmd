import AppKit
import XCTest
@testable import ACMD

final class MarkdownEditorControllerTests: XCTestCase {
    @MainActor
    func testLineStartsAreReusedForCaretMovesAndRebuiltForCharacterEdits() async throws {
        let textView = NSTextView()
        textView.string = "one\ntwo\nthree"
        let controller = MarkdownEditorController()
        controller.attach(to: textView)
        await drainMainQueue()

        XCTAssertEqual(controller.lineStartScanCount, 1)
        XCTAssertEqual(controller.totalLineCount, 3)

        for location in 0...(textView.string as NSString).length {
            textView.setSelectedRange(NSRange(location: location, length: 0))
            controller.editorStateDidChange(textView)
        }
        XCTAssertEqual(controller.lineStartScanCount, 1)

        let storage = try XCTUnwrap(textView.textStorage)
        storage.addAttribute(
            .foregroundColor,
            value: NSColor.systemBlue,
            range: NSRange(location: 0, length: 1)
        )
        controller.editorStateDidChange(textView)
        XCTAssertEqual(controller.lineStartScanCount, 1)

        storage.replaceCharacters(in: NSRange(location: 3, length: 1), with: "x")
        controller.editorStateDidChange(textView)
        await drainMainQueue()

        XCTAssertEqual(controller.lineStartScanCount, 2)
        XCTAssertEqual(controller.totalLineCount, 2)
    }

    @MainActor
    func testNativeTextEditInvalidatesLineStartsBeforeTextDidChange() async {
        let textView = NSTextView()
        textView.string = "one\ntwo\nthree"
        let controller = MarkdownEditorController()
        controller.attach(to: textView)
        await drainMainQueue()

        let delegate = ControllerChangeDelegate(controller: controller)
        textView.delegate = delegate
        textView.setSelectedRange(NSRange(location: 3, length: 1))
        textView.insertText("x", replacementRange: textView.selectedRange())
        await drainMainQueue()

        XCTAssertEqual(textView.string, "onextwo\nthree")
        XCTAssertEqual(delegate.scanCounts, [1, 2])
        XCTAssertEqual(controller.lineStartScanCount, 2)
        XCTAssertEqual(controller.totalLineCount, 2)
    }

    @MainActor
    private func drainMainQueue() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                continuation.resume()
            }
        }
    }
}

@MainActor
private final class ControllerChangeDelegate: NSObject, NSTextViewDelegate {
    private let controller: MarkdownEditorController
    private(set) var scanCounts: [Int] = []

    init(controller: MarkdownEditorController) {
        self.controller = controller
    }

    func textDidChange(_ notification: Notification) {
        guard let textView = notification.object as? NSTextView else { return }
        scanCounts.append(controller.lineStartScanCount)
        controller.editorStateDidChange(textView)
        scanCounts.append(controller.lineStartScanCount)
    }
}
