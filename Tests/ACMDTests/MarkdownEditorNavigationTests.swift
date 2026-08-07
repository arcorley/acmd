import AppKit
import XCTest
@testable import ACMD

final class MarkdownEditorNavigationTests: XCTestCase {
    func testSmartHomeTreatsNestedTaskPrefixAsOneUnit() {
        let text = "    > - [ ] task item"
        let contentStart = ("    > - [ ] " as NSString).length

        XCTAssertEqual(
            MarkdownEditorNavigation.beginningOfLine(
                in: text,
                from: (text as NSString).length
            ),
            contentStart
        )
        XCTAssertEqual(
            MarkdownEditorNavigation.beginningOfLine(in: text, from: contentStart),
            0
        )
    }

    func testSmartEndStopsBeforeTrailingWhitespaceThenAtPhysicalEnd() {
        let text = "  - item   "
        let meaningfulEnd = ("  - item" as NSString).length

        XCTAssertEqual(
            MarkdownEditorNavigation.endOfLine(in: text, from: 4),
            meaningfulEnd
        )
        XCTAssertEqual(
            MarkdownEditorNavigation.endOfLine(in: text, from: meaningfulEnd),
            (text as NSString).length
        )
    }

    func testDocumentNavigationUsesMeaningfulThenAbsoluteBoundaries() {
        let text = "\n \tTitle\n\n"
        let source = text as NSString
        let firstContent = source.range(of: "Title").location
        let lastContent = NSMaxRange(source.range(of: "Title"))

        XCTAssertEqual(
            MarkdownEditorNavigation.beginningOfDocument(in: text, from: source.length),
            firstContent
        )
        XCTAssertEqual(
            MarkdownEditorNavigation.beginningOfDocument(in: text, from: firstContent),
            0
        )
        XCTAssertEqual(
            MarkdownEditorNavigation.endOfDocument(in: text, from: firstContent),
            lastContent
        )
        XCTAssertEqual(
            MarkdownEditorNavigation.endOfDocument(in: text, from: lastContent),
            source.length
        )
    }

    func testWordNavigationSkipsOrderedListSyntaxAndWhitespaceRuns() {
        let text = "  1.   hello   world"
        let source = text as NSString
        let hello = source.range(of: "hello")
        let world = source.range(of: "world")

        XCTAssertEqual(
            MarkdownEditorNavigation.wordForward(in: text, from: 0),
            hello.location
        )
        XCTAssertEqual(
            MarkdownEditorNavigation.wordForward(in: text, from: hello.location),
            NSMaxRange(hello)
        )
        XCTAssertEqual(
            MarkdownEditorNavigation.wordForward(in: text, from: NSMaxRange(hello)),
            NSMaxRange(world)
        )
        XCTAssertEqual(
            MarkdownEditorNavigation.wordBackward(in: text, from: world.location),
            hello.location
        )
        XCTAssertEqual(
            MarkdownEditorNavigation.wordBackward(in: text, from: hello.location),
            0
        )
    }

    func testWordNavigationNeverSplitsComposedEmoji() {
        let text = "start 👨‍👩‍👧‍👦 end"
        let source = text as NSString
        let emoji = source.range(of: "👨‍👩‍👧‍👦")

        XCTAssertEqual(
            MarkdownEditorNavigation.wordForward(in: text, from: emoji.location),
            NSMaxRange(emoji)
        )
        XCTAssertEqual(
            MarkdownEditorNavigation.wordBackward(in: text, from: NSMaxRange(emoji)),
            emoji.location
        )
    }

    @MainActor
    func testShiftNavigationCanReverseAndCollapseSelection() {
        let text = "- hello world"
        let source = text as NSString
        let hello = source.range(of: "hello")
        let textView = MarkdownNavigationTextView(frame: .zero)
        textView.string = text
        textView.setSelectedRange(NSRange(location: hello.location, length: 0))

        textView.moveWordForwardAndModifySelection(nil)
        XCTAssertEqual(textView.selectedRange(), hello)
        XCTAssertEqual(textView.selectionFocusLocation, NSMaxRange(hello))

        textView.moveWordBackwardAndModifySelection(nil)
        XCTAssertEqual(
            textView.selectedRange(),
            NSRange(location: hello.location, length: 0)
        )
        XCTAssertEqual(textView.selectionFocusLocation, hello.location)
    }
}
