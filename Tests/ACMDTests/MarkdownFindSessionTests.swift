import AppKit
import XCTest
@testable import ACMD

final class MarkdownFindSessionTests: XCTestCase {
    @MainActor
    func testSessionPublishesAtomicRepeatableEventsAndPreservesOwnership() {
        let session = MarkdownFindSession()
        XCTAssertEqual(session.state.revision, 0)
        XCTAssertFalse(session.state.active)

        session.activate(source: .preview, query: "needle")
        XCTAssertEqual(session.state.query, "needle")
        XCTAssertTrue(session.state.active)
        XCTAssertEqual(session.state.source, .preview)
        XCTAssertEqual(session.state.action, .queryChanged)
        XCTAssertEqual(session.state.revision, 1)

        session.update(query: "needle", source: .preview)
        XCTAssertEqual(session.state.revision, 1, "Identical query updates should be coalesced")

        session.navigate(.next, source: .preview)
        session.navigate(.next, source: .preview)
        XCTAssertEqual(session.state.action, .next)
        XCTAssertEqual(session.state.revision, 3, "Navigation events must remain repeatable")

        let previewState = session.state
        session.deactivate(source: .editor)
        XCTAssertEqual(session.state, previewState, "One pane must not close the other pane's find")

        session.deactivate(source: .preview)
        XCTAssertFalse(session.state.active)
        XCTAssertEqual(session.state.query, "needle")
        XCTAssertEqual(session.state.action, .closed)
        XCTAssertEqual(session.state.revision, 4)

        session.activate(source: .editor)
        XCTAssertEqual(session.state.query, "needle", "Activation without a query reuses the shared query")
        XCTAssertEqual(session.state.source, .editor)
    }

    func testMatcherReturnsCaseInsensitiveNonoverlappingUTF16Ranges() {
        XCTAssertEqual(
            MarkdownFindMatcher.ranges(of: "test", in: "🙂 Test 🙂test TEST"),
            [
                NSRange(location: 3, length: 4),
                NSRange(location: 10, length: 4),
                NSRange(location: 15, length: 4)
            ]
        )
        XCTAssertEqual(
            MarkdownFindMatcher.ranges(of: "aa", in: "aaaa"),
            [NSRange(location: 0, length: 2), NSRange(location: 2, length: 2)]
        )
        XCTAssertTrue(MarkdownFindMatcher.ranges(of: "", in: "content").isEmpty)
    }

    @MainActor
    func testFindDrawingAttributesOverrideOnlyMatchColors() {
        let font = NSFont.monospacedSystemFont(ofSize: 14, weight: .bold)
        let syntaxBackground = NSColor.systemPink.withAlphaComponent(0.1)
        let input: [NSAttributedString.Key: Any] = [
            MarkdownFindHighlighting.markerAttribute: true,
            .font: font,
            .foregroundColor: NSColor.systemPurple,
            .backgroundColor: syntaxBackground
        ]

        let output = MarkdownFindHighlighting.attributes(input, drawingToScreen: true)

        XCTAssertNil(output?[MarkdownFindHighlighting.markerAttribute])
        XCTAssertTrue(output?[.font] as? NSFont === font)
        XCTAssertEqual(output?[.foregroundColor] as? NSColor, .black)
        XCTAssertEqual(output?[.backgroundColor] as? NSColor, .findHighlightColor)
        XCTAssertNil(MarkdownFindHighlighting.attributes(input, drawingToScreen: false))

        let syntaxOnly: [NSAttributedString.Key: Any] = [.backgroundColor: syntaxBackground]
        let unchanged = MarkdownFindHighlighting.attributes(syntaxOnly, drawingToScreen: true)
        XCTAssertEqual(unchanged?[.backgroundColor] as? NSColor, syntaxBackground)
    }

    @MainActor
    func testSelectedMatchAppearanceRequiresExactMatchRange() {
        let base: [NSAttributedString.Key: Any] = [
            .backgroundColor: NSColor.selectedTextBackgroundColor,
            .foregroundColor: NSColor.selectedTextColor
        ]
        let matches = [NSRange(location: 4, length: 6)]

        let exact = MarkdownFindHighlighting.selectionAttributes(
            base,
            selectedRange: matches[0],
            matchRanges: matches
        )
        XCTAssertEqual(exact[.backgroundColor] as? NSColor, .findHighlightColor)
        XCTAssertEqual(exact[.foregroundColor] as? NSColor, .black)

        let containing = MarkdownFindHighlighting.selectionAttributes(
            base,
            selectedRange: NSRange(location: 0, length: 20),
            matchRanges: matches
        )
        XCTAssertEqual(
            containing[.backgroundColor] as? NSColor,
            NSColor.selectedTextBackgroundColor
        )
        XCTAssertEqual(containing[.foregroundColor] as? NSColor, NSColor.selectedTextColor)
    }
}
