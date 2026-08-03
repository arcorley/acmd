import Foundation
import XCTest
@testable import ACMDCore

final class MarkdownSyntaxTokenizerTests: XCTestCase {
    func testRecognizesEditorSyntaxConstructs() {
        let text = """
        # **Title**
        > quote
        - item
        1. ordered
        - [x] task
        ---
        [link](https://example.com/a_(b)) and ![alt](image.png)
        *em* ~~deleted~~ `code`
        """
        let spans = MarkdownSyntaxTokenizer.spans(in: text)

        assertContains(spans, kind: .heading, text: "# **Title**", in: text)
        assertContains(spans, kind: .strong, text: "**Title**", in: text)
        assertContains(spans, kind: .blockQuote, text: "> ", in: text)
        assertContains(spans, kind: .listMarker, text: "- ", in: text)
        assertContains(spans, kind: .listMarker, text: "1. ", in: text)
        assertContains(spans, kind: .taskMarker, text: "- [x] ", in: text)
        assertContains(spans, kind: .horizontalRule, text: "---", in: text)
        assertContains(spans, kind: .link, text: "[link](https://example.com/a_(b))", in: text)
        assertContains(spans, kind: .image, text: "![alt](image.png)", in: text)
        assertContains(spans, kind: .emphasis, text: "*em*", in: text)
        assertContains(spans, kind: .strikethrough, text: "~~deleted~~", in: text)
        assertContains(spans, kind: .inlineCode, text: "`code`", in: text)
    }

    func testFencedCodeMasksAllOtherSyntax() {
        let text = """
        # visible
        ```markdown
        # hidden
        **also hidden**
        [hidden](url)
        ```
        *visible*
        """
        let spans = MarkdownSyntaxTokenizer.spans(in: text)
        let blocks = spans.filter { $0.kind == .codeBlock }
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(substring(blocks[0], in: text), "```markdown\n# hidden\n**also hidden**\n[hidden](url)\n```")

        let hiddenLocation = (text as NSString).range(of: "# hidden").location
        XCTAssertFalse(spans.contains { $0.kind != .codeBlock && NSLocationInRange(hiddenLocation, $0.range) })
        XCTAssertEqual(spans.filter { $0.kind == .heading }.count, 1)
        assertContains(spans, kind: .emphasis, text: "*visible*", in: text)
    }

    func testInlineCodeMasksEmphasisAndLinks() {
        let text = "`**not bold** [not a link](url)` **bold**"
        let spans = MarkdownSyntaxTokenizer.spans(in: text)
        XCTAssertEqual(spans.filter { $0.kind == .inlineCode }.count, 1)
        XCTAssertEqual(spans.filter { $0.kind == .strong }.count, 1)
        XCTAssertEqual(spans.filter { $0.kind == .link }.count, 0)
        assertContains(spans, kind: .strong, text: "**bold**", in: text)
    }

    func testTildeFenceAndUnclosedFenceRunToEndOfDocument() {
        let text = "~~~js\nconst x = '*';"
        let spans = MarkdownSyntaxTokenizer.spans(in: text)
        XCTAssertEqual(spans, [
            MarkdownSyntaxSpan(
                range: NSRange(location: 0, length: (text as NSString).length),
                kind: .codeBlock
            )
        ])
    }

    func testUTF16RangesRemainCorrectAfterEmoji() {
        let text = "🙂 **bold** and [link](url)"
        let spans = MarkdownSyntaxTokenizer.spans(in: text)
        let strong = try! XCTUnwrap(spans.first { $0.kind == .strong })
        let link = try! XCTUnwrap(spans.first { $0.kind == .link })

        XCTAssertEqual(strong.range, (text as NSString).range(of: "**bold**"))
        XCTAssertEqual(link.range, (text as NSString).range(of: "[link](url)"))
    }

    func testEscapedDelimitersAreNotTokens() {
        let text = #"\*not emphasis* and \[not](link) but _yes_"#
        let spans = MarkdownSyntaxTokenizer.spans(in: text)
        XCTAssertEqual(spans.filter { $0.kind == .link }.count, 0)
        XCTAssertEqual(spans.filter { $0.kind == .emphasis }.count, 1)
        assertContains(spans, kind: .emphasis, text: "_yes_", in: text)
    }

    func testHeadingAndListInsideBlockQuoteAreRecognized() {
        let text = "> # Heading\n> - [ ] task"
        let spans = MarkdownSyntaxTokenizer.spans(in: text)
        XCTAssertEqual(spans.filter { $0.kind == .blockQuote }.count, 2)
        assertContains(spans, kind: .heading, text: "# Heading", in: text)
        assertContains(spans, kind: .taskMarker, text: "- [ ] ", in: text)
    }

    func testEmptyTextHasNoSpans() {
        XCTAssertEqual(MarkdownSyntaxTokenizer.spans(in: ""), [])
    }

    private func assertContains(
        _ spans: [MarkdownSyntaxSpan],
        kind: MarkdownSyntaxKind,
        text expected: String,
        in source: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(
            spans.contains { $0.kind == kind && substring($0, in: source) == expected },
            "Missing \(kind) span for \(expected)",
            file: file,
            line: line
        )
    }

    private func substring(_ span: MarkdownSyntaxSpan, in text: String) -> String {
        (text as NSString).substring(with: span.range)
    }
}
