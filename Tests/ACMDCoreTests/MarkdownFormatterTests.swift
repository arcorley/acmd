import Foundation
import XCTest
@testable import ACMDCore

final class MarkdownFormatterTests: XCTestCase {
    func testBoldWrapsUTF16SelectionAndKeepsContentSelected() {
        let text = "🙂 café"
        let range = (text as NSString).range(of: "café")

        let result = MarkdownFormatter.apply(command: .bold, to: text, selection: range)

        XCTAssertEqual(result.text, "🙂 **café**")
        XCTAssertEqual(selectedText(in: result), "café")
        XCTAssertEqual(result.selection.location, range.location + 2)
    }

    func testBoldInsertsPairedMarkersAtInsertionPoint() {
        let result = MarkdownFormatter.apply(
            command: .bold,
            to: "hello",
            selection: NSRange(location: 5, length: 0)
        )

        XCTAssertEqual(result.text, "hello****")
        XCTAssertEqual(result.selection, NSRange(location: 7, length: 0))
    }

    func testInlineWrapperTogglesWhenMarkupIsSelected() {
        let result = MarkdownFormatter.apply(
            command: .strikethrough,
            to: "before ~~gone~~ after",
            selection: NSRange(location: 7, length: 8)
        )

        XCTAssertEqual(result.text, "before gone after")
        XCTAssertEqual(selectedText(in: result), "gone")
    }

    func testInlineWrapperTogglesWhenContentInsideMarkupIsSelected() {
        let result = MarkdownFormatter.apply(
            command: .bold,
            to: "**strong**",
            selection: NSRange(location: 2, length: 6)
        )

        XCTAssertEqual(result.text, "strong")
        XCTAssertEqual(result.selection, NSRange(location: 0, length: 6))
    }

    func testItalicDoesNotMistakeBoldMarkersForItalic() {
        let result = MarkdownFormatter.apply(
            command: .italic,
            to: "**word**",
            selection: NSRange(location: 2, length: 4)
        )

        XCTAssertEqual(result.text, "***word***")
        XCTAssertEqual(selectedText(in: result), "word")
    }

    func testInlineCodeUsesDelimiterLongerThanSelectedBacktickRunAndToggles() {
        let original = "a ` b"
        let wrapped = MarkdownFormatter.apply(
            command: .inlineCode,
            to: original,
            selection: NSRange(location: 0, length: (original as NSString).length)
        )
        XCTAssertEqual(wrapped.text, "``a ` b``")
        XCTAssertEqual(selectedText(in: wrapped), original)

        let toggled = MarkdownFormatter.apply(
            command: .inlineCode,
            to: wrapped.text,
            selection: NSRange(location: 0, length: (wrapped.text as NSString).length)
        )
        XCTAssertEqual(toggled.text, original)
        XCTAssertEqual(selectedText(in: toggled), original)
    }

    func testInlineCodePadsContentTouchingBacktickDelimitersAndToggles() {
        let original = "`value"
        let wrapped = MarkdownFormatter.apply(
            command: .inlineCode,
            to: original,
            selection: NSRange(location: 0, length: (original as NSString).length)
        )

        XCTAssertEqual(wrapped.text, "`` `value ``")
        XCTAssertEqual(selectedText(in: wrapped), original)

        let toggled = MarkdownFormatter.apply(
            command: .inlineCode,
            to: wrapped.text,
            selection: wrapped.selection
        )
        XCTAssertEqual(toggled.text, original)
        XCTAssertEqual(selectedText(in: toggled), original)
    }

    func testInlineFormattingLeavesBoundaryWhitespaceOutsideMarkers() {
        let original = " before and after "
        let result = MarkdownFormatter.apply(
            command: .bold,
            to: original,
            selection: NSRange(location: 0, length: (original as NSString).length)
        )

        XCTAssertEqual(result.text, " **before and after** ")
        XCTAssertEqual(selectedText(in: result), "before and after")
    }

    func testLinkWrapsSelectionAndTogglesBackToLabel() {
        let wrapped = MarkdownFormatter.apply(
            command: .link,
            to: "OpenAI",
            selection: NSRange(location: 0, length: 6)
        )
        XCTAssertEqual(wrapped.text, "[OpenAI](url)")
        XCTAssertEqual(selectedText(in: wrapped), "OpenAI")

        let toggled = MarkdownFormatter.apply(
            command: .link,
            to: wrapped.text,
            selection: NSRange(location: 0, length: (wrapped.text as NSString).length)
        )
        XCTAssertEqual(toggled.text, "OpenAI")
        XCTAssertEqual(selectedText(in: toggled), "OpenAI")
    }

    func testEmptyImageCreatesUsefulPlaceholderAndSelectsAltText() {
        let result = MarkdownFormatter.apply(
            command: .image,
            to: "",
            selection: NSRange(location: 0, length: 0)
        )

        XCTAssertEqual(result.text, "![alt text](url)")
        XCTAssertEqual(selectedText(in: result), "alt text")
    }

    func testHeadingChangesExistingLevelThenTogglesItOff() {
        let changed = MarkdownFormatter.apply(
            command: .heading(3),
            to: "# Title",
            selection: NSRange(location: 2, length: 5)
        )
        XCTAssertEqual(changed.text, "### Title")
        XCTAssertEqual(selectedText(in: changed), "Title")

        let toggled = MarkdownFormatter.apply(
            command: .heading(3),
            to: changed.text,
            selection: changed.selection
        )
        XCTAssertEqual(toggled.text, "Title")
        XCTAssertEqual(selectedText(in: toggled), "Title")
    }

    func testHeadingLevelIsClampedToMarkdownRange() {
        let low = MarkdownFormatter.apply(command: .heading(0), to: "Title", selection: .init(location: 0, length: 5))
        let high = MarkdownFormatter.apply(command: .heading(99), to: "Title", selection: .init(location: 0, length: 5))
        XCTAssertEqual(low.text, "# Title")
        XCTAssertEqual(high.text, "###### Title")
    }

    func testMultilineListFormattingExcludesLineAtSelectionEnd() {
        let text = "one\ntwo\nthree"
        let result = MarkdownFormatter.apply(
            command: .unorderedList,
            to: text,
            selection: NSRange(location: 0, length: 8)
        )

        XCTAssertEqual(result.text, "- one\n- two\nthree")
        XCTAssertEqual(selectedText(in: result), "one\n- two\n")
    }

    func testListFormattingSwitchesStylesAndRenumbersLines() {
        let text = "- alpha\n- [x] beta\n3) gamma"
        let result = MarkdownFormatter.apply(
            command: .orderedList,
            to: text,
            selection: NSRange(location: 0, length: (text as NSString).length)
        )

        XCTAssertEqual(result.text, "1. alpha\n2. beta\n3. gamma")
        let toggled = MarkdownFormatter.apply(
            command: .orderedList,
            to: result.text,
            selection: NSRange(location: 0, length: (result.text as NSString).length)
        )
        XCTAssertEqual(toggled.text, "alpha\nbeta\ngamma")
    }

    func testTaskListPreservesIndentation() {
        let result = MarkdownFormatter.apply(
            command: .taskList,
            to: "  first\n\tsecond",
            selection: NSRange(location: 0, length: 15)
        )

        XCTAssertEqual(result.text, "  - [ ] first\n\t- [ ] second")
    }

    func testMixedBlockQuotesAreNormalizedThenToggled() {
        let text = "> quoted\nplain"
        let normalized = MarkdownFormatter.apply(
            command: .blockQuote,
            to: text,
            selection: NSRange(location: 0, length: (text as NSString).length)
        )
        XCTAssertEqual(normalized.text, "> quoted\n> plain")

        let toggled = MarkdownFormatter.apply(
            command: .blockQuote,
            to: normalized.text,
            selection: NSRange(location: 0, length: (normalized.text as NSString).length)
        )
        XCTAssertEqual(toggled.text, "quoted\nplain")
    }

    func testCodeBlockWrapsAndUnwrapsSelection() {
        let wrapped = MarkdownFormatter.apply(
            command: .codeBlock,
            to: "let value = 1",
            selection: NSRange(location: 0, length: 13)
        )
        XCTAssertEqual(wrapped.text, "```\nlet value = 1\n```")
        XCTAssertEqual(selectedText(in: wrapped), "let value = 1")

        let toggled = MarkdownFormatter.apply(
            command: .codeBlock,
            to: wrapped.text,
            selection: NSRange(location: 0, length: (wrapped.text as NSString).length)
        )
        XCTAssertEqual(toggled.text, "let value = 1")
        XCTAssertEqual(selectedText(in: toggled), "let value = 1")
    }

    func testCodeBlockTogglesFromCursorInsideExistingFence() {
        let text = "```swift\nlet x = 1\n```"
        let cursor = (text as NSString).range(of: "x").location
        let result = MarkdownFormatter.apply(
            command: .codeBlock,
            to: text,
            selection: NSRange(location: cursor, length: 0)
        )

        XCTAssertEqual(result.text, "let x = 1")
        XCTAssertEqual(result.selection.location, 4)
    }

    func testEmptyCodeBlockPlacesCursorBetweenFenceLinesAndToggles() {
        let wrapped = MarkdownFormatter.apply(command: .codeBlock, to: "", selection: .init(location: 0, length: 0))
        XCTAssertEqual(wrapped.text, "```\n\n```")
        XCTAssertEqual(wrapped.selection, NSRange(location: 4, length: 0))

        let toggled = MarkdownFormatter.apply(command: .codeBlock, to: wrapped.text, selection: wrapped.selection)
        XCTAssertEqual(toggled.text, "")
        XCTAssertEqual(toggled.selection, NSRange(location: 0, length: 0))
    }

    func testCodeBlockTogglePreservesSelectedTrailingNewlineAndFollowingText() {
        let text = "```\nx\n```\nnext"
        let fencedSelection = NSRange(location: 0, length: 10)
        let result = MarkdownFormatter.apply(
            command: .codeBlock,
            to: text,
            selection: fencedSelection
        )

        XCTAssertEqual(result.text, "x\nnext")
        XCTAssertEqual(selectedText(in: result), "x")
    }

    func testHorizontalRuleUsesEmptyLineAndToggles() {
        let inserted = MarkdownFormatter.apply(
            command: .horizontalRule,
            to: "before\n\nafter",
            selection: NSRange(location: 7, length: 0)
        )
        XCTAssertEqual(inserted.text, "before\n---\nafter")

        let removed = MarkdownFormatter.apply(command: .horizontalRule, to: inserted.text, selection: inserted.selection)
        XCTAssertEqual(removed.text, "before\n\nafter")
    }

    func testHorizontalRulePreservesNonemptySelection() {
        let text = "first\nsecond"
        let result = MarkdownFormatter.apply(
            command: .horizontalRule,
            to: text,
            selection: NSRange(location: 0, length: (text as NSString).length)
        )

        XCTAssertEqual(result.text, "first\nsecond\n\n---")
        XCTAssertTrue(result.text.hasPrefix(text))
    }

    func testOutOfBoundsSelectionIsClampedWithoutCrashing() {
        let result = MarkdownFormatter.apply(
            command: .italic,
            to: "abc",
            selection: NSRange(location: 99, length: 99)
        )
        XCTAssertEqual(result.text, "abc**")
        XCTAssertEqual(result.selection, NSRange(location: 4, length: 0))
    }

    private func selectedText(in result: MarkdownEditResult) -> String {
        (result.text as NSString).substring(with: result.selection)
    }
}
