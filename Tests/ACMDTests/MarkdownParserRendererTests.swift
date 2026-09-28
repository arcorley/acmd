import Foundation
import XCTest
@testable import ACMD

final class MarkdownParserRendererTests: XCTestCase {
    func testATXSetextAndQuotedHeadingsReceiveUniqueStableIDs() {
        let markdown = """
        # Hello *World*

        Hello World
        -----------

        > # Hello *World*
        """

        XCTAssertEqual(
            render(markdown),
            """
            <h1 id="hello-world">Hello <em>World</em></h1>
            <h2 id="hello-world-1">Hello World</h2>
            <blockquote>
            <h1 id="hello-world-2">Hello <em>World</em></h1>
            </blockquote>
            """
        )
    }

    func testNestedInlineFormattingAndCodeAreRenderedAndEscaped() {
        let markdown = "**strong with *emphasis*, ~~deleted~~, and `code <>&`**"

        XCTAssertEqual(
            render(markdown),
            "<p><strong>strong with <em>emphasis</em>, <del>deleted</del>, and <code>code &lt;&gt;&amp;</code></strong></p>"
        )
    }

    func testRawHTMLIsEscapedAndUnsafeDestinationsDoNotBecomeElements() {
        let markdown = "<script>alert('x')</script> [run](javascript:alert(1)) [encoded](java%73cript:alert(1)) ![track](data:image/png;base64,AAAA)"
        let html = render(markdown)

        XCTAssertEqual(
            html,
            "<p>&lt;script&gt;alert('x')&lt;/script&gt; run encoded track</p>"
        )
        XCTAssertFalse(html.contains("<script"))
        XCTAssertFalse(html.contains("javascript:"))
        XCTAssertFalse(html.contains("data:image"))
    }

    func testURLSanitizerAllowsExpectedDestinationsAndRejectsDangerousSchemes() {
        XCTAssertEqual(
            MarkdownURLSanitizer.sanitize("https://example.com/a", kind: .link),
            "https://example.com/a"
        )
        XCTAssertEqual(
            MarkdownURLSanitizer.sanitize("../guides/start.md#intro", kind: .link),
            "../guides/start.md#intro"
        )
        XCTAssertEqual(
            MarkdownURLSanitizer.sanitize("www.example.com", kind: .link),
            "https://www.example.com"
        )
        XCTAssertEqual(
            MarkdownURLSanitizer.sanitize("mailto:reader@example.com", kind: .link),
            "mailto:reader@example.com"
        )

        for destination in [
            "javascript:alert(1)",
            "JaVaScRiPt:alert(1)",
            "java%73cript:alert(1)",
            "data:text/html,payload",
            "file:///etc/passwd",
            "vbscript:msgbox(1)",
            "//attacker.example/path",
            "/absolute/path"
        ] {
            XCTAssertNil(
                MarkdownURLSanitizer.sanitize(destination, kind: .link),
                "Expected unsafe link destination to be rejected: \(destination)"
            )
        }

        XCTAssertNil(
            MarkdownURLSanitizer.sanitize("mailto:reader@example.com", kind: .image)
        )
    }

    func testLinksImagesRelativeDestinationsAndAutolinks() {
        let markdown = "[Guide](guides/start.md \"Read & learn\") ![Logo *mark*](images/logo.png \"Logo & badge\") <https://example.com/a?x=1&y=2> www.example.com/docs user@example.com"

        XCTAssertEqual(
            render(markdown),
            """
            <p><a href="guides/start.md" rel="noopener noreferrer" title="Read &amp; learn">Guide</a> <img src="images/logo.png" alt="Logo mark" title="Logo &amp; badge" loading="lazy" decoding="async"> <a href="https://example.com/a?x=1&amp;y=2" rel="noopener noreferrer">https://example.com/a?x=1&amp;y=2</a> <a href="https://www.example.com/docs" rel="noopener noreferrer">www.example.com/docs</a> <a href="mailto:user@example.com" rel="noopener noreferrer">user@example.com</a></p>
            """
        )
    }

    func testFencedSwiftCodeIncludesLanguageMetadataAndSyntaxSpans() {
        let markdown = """
        ```swift
        let value = 42
        print("<tag>") // note
        ```
        """

        XCTAssertEqual(
            render(markdown),
            """
            <pre><code class="language-swift" aria-label="Code block: swift"><span class="tok-keyword">let</span> value = <span class="tok-number">42</span>
            print(<span class="tok-string">"&lt;tag&gt;"</span>) <span class="tok-comment">// note</span></code></pre>
            """
        )
    }

    func testFenceInfoCannotInjectAttributes() {
        let html = render("~~~swift\" onmouseover=alert(1)\nreturn\n~~~")

        XCTAssertTrue(html.contains("class=\"language-swift\""))
        XCTAssertTrue(html.contains("aria-label=\"Code block: swift&quot;\""))
        XCTAssertFalse(html.contains(" onmouseover="))
    }

    func testMermaidFencesKeepEscapedSourceAndSourceMapOnDiagramContainer() {
        let markdown = "~~~MeRmAiD\nflowchart LR\nA[\"<script>alert(1)</script> & text\"] --> B\n~~~"
        let html = MarkdownParser(markdown).render(includingSourceMap: true)

        XCTAssertTrue(html.contains(#"<div class="mermaid-diagram" role="group" aria-label="Mermaid diagram" data-source-start="0" data-source-end="3">"#))
        XCTAssertTrue(html.contains(#"<pre class="mermaid-source"><code>flowchart LR"#))
        XCTAssertTrue(html.contains("&lt;script&gt;alert(1)&lt;/script&gt; &amp; text"))
        XCTAssertFalse(html.contains("<script>"))
        XCTAssertFalse(html.contains("tok-"))
    }

    func testNestedMermaidAndOrdinaryFencesRemainDistinct() {
        let html = render("""
        > ```mermaid
        > flowchart TD
        > A --> B
        > ```

        ```text
        flowchart TD
        A --> B
        ```

        ```mermaid-example
        A --> B
        ```
        """)

        XCTAssertEqual(html.components(separatedBy: #"class="mermaid-diagram""#).count - 1, 1)
        XCTAssertTrue(html.contains("<blockquote>\n<div"))
        XCTAssertTrue(html.contains(#"class="language-text""#))
        XCTAssertTrue(html.contains(#"class="language-mermaid-example""#))
    }

    func testBlockquotesCanContainBlocksAndNestedQuotes() {
        let markdown = """
        > # Quoted
        >
        > Nested **text**.
        >
        > > Deeper
        """

        XCTAssertEqual(
            render(markdown),
            """
            <blockquote>
            <h1 id="quoted">Quoted</h1>
            <p>Nested <strong>text</strong>.</p>
            <blockquote>
            <p>Deeper</p>
            </blockquote>
            </blockquote>
            """
        )
    }

    func testOrderedListPreservesNonDefaultStart() {
        XCTAssertEqual(
            render("3. third\n4. fourth"),
            """
            <ol start="3">
            <li><p>third</p></li>
            <li><p>fourth</p></li>
            </ol>
            """
        )
    }

    func testNestedOrderedListIsContainedByItsParentItem() {
        let markdown = """
        - parent
          1. first
          2. second
        - sibling
        """

        XCTAssertEqual(
            render(markdown),
            """
            <ul>
            <li><p>parent</p>
            <ol>
            <li><p>first</p></li>
            <li><p>second</p></li>
            </ol></li>
            <li><p>sibling</p></li>
            </ul>
            """
        )
    }

    func testDeepMixedNestedListsPreserveHierarchy() {
        let markdown = """
        1. parent
           - [ ] child task
             1. grandchild
                * great-grandchild
        2. sibling
        """

        XCTAssertEqual(
            render(markdown),
            """
            <ol>
            <li><p>parent</p>
            <ul class="contains-task-list">
            <li class="task-list-item"><input type="checkbox" disabled aria-label="Task not completed"><p>child task</p>
            <ol>
            <li><p>grandchild</p>
            <ul>
            <li><p>great-grandchild</p></li>
            </ul></li>
            </ol></li>
            </ul></li>
            <li><p>sibling</p></li>
            </ol>
            """
        )
    }

    func testNestedListsSupportThreeColumnDocumentIndentation() {
        let markdown = """
        ### Specialty
           1. Mapping
              1. Child
                 1. Grandchild
           2. Sibling
        """

        XCTAssertEqual(
            render(markdown),
            """
            <h3 id="specialty">Specialty</h3>
            <ol>
            <li><p>Mapping</p>
            <ol>
            <li><p>Child</p>
            <ol>
            <li><p>Grandchild</p></li>
            </ol></li>
            </ol></li>
            <li><p>Sibling</p></li>
            </ol>
            """
        )
    }

    func testTaskListRendersDisabledCheckboxesAndStateLabels() {
        let html = render("- [x] shipped\n- [ ] pending")

        XCTAssertEqual(
            html,
            """
            <ul class="contains-task-list">
            <li class="task-list-item"><input type="checkbox" disabled checked aria-label="Task completed"><p>shipped</p></li>
            <li class="task-list-item"><input type="checkbox" disabled aria-label="Task not completed"><p>pending</p></li>
            </ul>
            """
        )
    }

    func testTableAlignmentInlineMarkupAndEscapedPipes() {
        let markdown = """
        | Name | Value | Code |
        | :--- | ---: | :---: |
        | A \\| B | **2** | `x|y` |
        """

        XCTAssertEqual(
            render(markdown),
            """
            <div class="table-scroll"><table>
            <thead><tr><th class="align-left">Name</th><th class="align-right">Value</th><th class="align-center">Code</th></tr></thead>
            <tbody>
            <tr><td class="align-left">A | B</td><td class="align-right"><strong>2</strong></td><td class="align-center"><code>x|y</code></td></tr>
            </tbody>
            </table></div>
            """
        )
    }

    func testTwoSpacesAndBackslashProduceHardLineBreaks() {
        XCTAssertEqual(
            render("line one  \nline two\\\nline three"),
            "<p>line one<br>\nline two<br>\nline three</p>"
        )
    }

    func testHorizontalRuleVariantsRenderAsThematicBreaks() {
        XCTAssertEqual(render("---\n\n* * *\n\n_ _ _"), "<hr>\n<hr>\n<hr>")
    }

    func testUnicodeContentAndHeadingIDsArePreserved() {
        let markdown = "# Café 日本語 🚀\n\n**مرحبا** & <タグ>"

        XCTAssertEqual(
            render(markdown),
            """
            <h1 id="café-日本語">Café 日本語 🚀</h1>
            <p><strong>مرحبا</strong> &amp; &lt;タグ&gt;</p>
            """
        )
    }

    func testDocumentRendererWrapsContentWithCSPAndLocalBaseURL() {
        let documentURL = URL(fileURLWithPath: "/tmp/acmd preview/notes.md")
        let html = MarkdownHTMLRenderer().renderDocument(
            markdown: "# Preview\n\n[Guide](guide.md)",
            documentURL: documentURL
        )

        XCTAssertTrue(html.hasPrefix("<!doctype html>"))
        XCTAssertTrue(html.contains("script-src 'none'"))
        XCTAssertTrue(html.contains(#"<base href="file:///tmp/acmd%20preview/">"#))
        XCTAssertTrue(html.contains(#"<main class="markdown-body" aria-label="Markdown preview" data-source-line-count="3">"#))
        XCTAssertTrue(html.contains(#"<h1 id="preview" data-source-start="0" data-source-end="0">Preview</h1>"#))
        XCTAssertTrue(html.contains(#"<p data-source-start="2" data-source-end="2">"#))
        XCTAssertTrue(html.contains(#"<a href="guide.md" rel="noopener noreferrer">Guide</a>"#))
        XCTAssertFalse(html.contains("<script"))
    }

    func testDocumentRendererUsesScopedYellowFindSelection() {
        let html = MarkdownHTMLRenderer().renderDocument(markdown: "Find this text")

        XCTAssertTrue(html.contains("--find-selection: #ffff00"))
        XCTAssertTrue(html.contains("--find-selection-foreground: #000000"))
        XCTAssertTrue(html.contains("html.acmd-find-active ::selection"))
        XCTAssertTrue(html.contains("background: var(--find-selection)"))
        XCTAssertTrue(html.contains("color: var(--find-selection-foreground)"))
    }

    func testSourceMapPreservesOriginalLinesInsideBlockQuotes() {
        let markdown = "# One\n\n> ## Two"

        XCTAssertEqual(
            MarkdownParser(markdown).render(includingSourceMap: true),
            """
            <h1 id="one" data-source-start="0" data-source-end="0">One</h1>
            <blockquote data-source-start="2" data-source-end="2">
            <h2 id="two" data-source-start="2" data-source-end="2">Two</h2>
            </blockquote>
            """
        )
        XCTAssertFalse(render(markdown).contains("data-source-"))
    }

    func testSourceMapAnnotatesEveryNestedListItemWithOriginalLines() {
        let markdown = """
        1. parent
           - [ ] child task
             1. grandchild
                * great-grandchild
        2. sibling
        """

        let html = MarkdownParser(markdown).render(includingSourceMap: true)

        XCTAssertTrue(html.contains(#"<ol data-source-start="0" data-source-end="4">"#))
        XCTAssertTrue(html.contains(#"<li data-source-start="0" data-source-end="3">"#))
        XCTAssertTrue(html.contains(#"<ul class="contains-task-list" data-source-start="1" data-source-end="3">"#))
        XCTAssertTrue(html.contains(#"<li class="task-list-item" data-source-start="1" data-source-end="3">"#))
        XCTAssertTrue(html.contains(#"<ol data-source-start="2" data-source-end="3">"#))
        XCTAssertTrue(html.contains(#"<li data-source-start="2" data-source-end="3">"#))
        XCTAssertTrue(html.contains(#"<ul data-source-start="3" data-source-end="3">"#))
        XCTAssertTrue(html.contains(#"<li data-source-start="3" data-source-end="3">"#))
        XCTAssertTrue(html.contains(#"<li data-source-start="4" data-source-end="4">"#))
    }

    func testDocumentRendererShowsAccessibleEmptyStateForWhitespace() {
        let html = MarkdownHTMLRenderer().renderDocument(markdown: " \n\t")

        XCTAssertTrue(html.contains(#"class="empty-state" role="status" aria-label="Empty Markdown preview""#))
        XCTAssertTrue(html.contains("Nothing to preview yet"))
        XCTAssertFalse(html.contains("<base "))
    }

    private func render(_ markdown: String) -> String {
        MarkdownParser(markdown).render()
    }
}
