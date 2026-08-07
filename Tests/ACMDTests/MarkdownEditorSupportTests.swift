import AppKit
import SwiftUI
import XCTest
@testable import ACMD

final class MarkdownEditorSupportTests: XCTestCase {
    func testMetricsUseOneBasedUnicodeLineAndColumnAndCountSelection() {
        let text = "first\n🙂 café\nlast"
        let source = text as NSString
        let selection = source.range(of: "café")

        let metrics = MarkdownEditorTextMetrics.measure(
            text: text,
            selection: selection
        )

        XCTAssertEqual(metrics.line, 2)
        XCTAssertEqual(metrics.column, 3)
        XCTAssertEqual(metrics.selectedCharacterCount, 4)
    }

    func testMetricsCanReportTheActiveSelectionEndpoint() {
        let text = "first\nsecond"
        let selection = NSRange(location: 0, length: ("first\nsec" as NSString).length)

        let metrics = MarkdownEditorTextMetrics.measure(
            text: text,
            selection: selection,
            focusLocation: NSMaxRange(selection)
        )

        XCTAssertEqual(metrics.line, 2)
        XCTAssertEqual(metrics.column, 4)
        XCTAssertEqual(metrics.selectedCharacterCount, selection.length)
    }

    func testLineLocationClampsToDocumentBounds() {
        let text = "one\ntwo\nthree"

        XCTAssertEqual(MarkdownEditorTextMetrics.location(ofLine: -2, in: text), 0)
        XCTAssertEqual(MarkdownEditorTextMetrics.location(ofLine: 2, in: text), 4)
        XCTAssertEqual(MarkdownEditorTextMetrics.location(ofLine: 99, in: text), 8)
    }

    func testTabIndentsCurrentBulletAndKeepsCaretWithContent() throws {
        let text = "- first\n- second"
        let caret = (text as NSString).range(of: "first").location + 2

        let edit = try XCTUnwrap(MarkdownListIndentation.edit(
            text: text,
            selection: NSRange(location: caret, length: 0),
            direction: .indent
        ))

        XCTAssertEqual(apply(edit, to: text), "    - first\n- second")
        XCTAssertEqual(edit.selection, NSRange(location: caret + 4, length: 0))
    }

    func testTabRestartsIndentedOrderedListAtOne() throws {
        let text = "1. parent\n2. child"
        let caret = (text as NSString).range(of: "child").location

        let edit = try XCTUnwrap(MarkdownListIndentation.edit(
            text: text,
            selection: NSRange(location: caret, length: 0),
            direction: .indent
        ))

        XCTAssertEqual(apply(edit, to: text), "1. parent\n    1. child")
        XCTAssertEqual(edit.selection, NSRange(location: caret + 4, length: 0))
    }

    func testTabRestartsAndRenumbersMultipleIndentedOrderedItems() throws {
        let text = "1. parent\n2. first child\n3. second child"
        let start = (text as NSString).range(of: "2. first").location
        let selection = NSRange(location: start, length: (text as NSString).length - start)

        let edit = try XCTUnwrap(MarkdownListIndentation.edit(
            text: text,
            selection: selection,
            direction: .indent
        ))

        XCTAssertEqual(
            apply(edit, to: text),
            "1. parent\n    1. first child\n    2. second child"
        )
        XCTAssertEqual(edit.selection.location, start + 4)
    }

    func testTabRenumbersEachSelectedOrderedDepthIndependently() throws {
        let text = "1. parent\n    1. child\n2. sibling"

        let edit = try XCTUnwrap(MarkdownListIndentation.edit(
            text: text,
            selection: NSRange(location: 0, length: (text as NSString).length),
            direction: .indent
        ))

        XCTAssertEqual(
            apply(edit, to: text),
            "    1. parent\n        1. child\n    2. sibling"
        )
    }

    func testTabContinuesAnExistingNestedOrderedList() throws {
        let text = "1. parent\n    1. existing child\n2. new child"
        let caret = (text as NSString).range(of: "new child").location

        let edit = try XCTUnwrap(MarkdownListIndentation.edit(
            text: text,
            selection: NSRange(location: caret, length: 0),
            direction: .indent
        ))

        XCTAssertEqual(
            apply(edit, to: text),
            "1. parent\n    1. existing child\n    2. new child"
        )
    }

    func testTabDoesNotAdoptAnUnrelatedNestedRunAcrossAParagraph() throws {
        let text = """
        1. old parent
            - [x] old child
        paragraph
        2. selected
        """
        let caret = (text as NSString).range(of: "selected").location

        let edit = try XCTUnwrap(MarkdownListIndentation.edit(
            text: text,
            selection: NSRange(location: caret, length: 0),
            direction: .indent
        ))

        XCTAssertEqual(
            apply(edit, to: text),
            """
            1. old parent
                - [x] old child
            paragraph
                1. selected
            """
        )
    }

    func testSeparateSelectedListsDoNotShareDestinationSequenceState() throws {
        let text = "1. first\nparagraph\n- [x] second"

        let edit = try XCTUnwrap(MarkdownListIndentation.edit(
            text: text,
            selection: NSRange(location: 0, length: (text as NSString).length),
            direction: .indent
        ))

        XCTAssertEqual(
            apply(edit, to: text),
            "    1. first\nparagraph\n    - [x] second"
        )
    }

    func testDestinationLookupIgnoresItemsMovingAwayFromThatLevel() throws {
        let text = "1. outer\n    - [ ] child\n2. sibling"
        let start = (text as NSString).range(of: "- [ ] child").location

        let edit = try XCTUnwrap(MarkdownListIndentation.edit(
            text: text,
            selection: NSRange(location: start, length: (text as NSString).length - start),
            direction: .indent
        ))

        XCTAssertEqual(
            apply(edit, to: text),
            "1. outer\n        - [ ] child\n    1. sibling"
        )
    }

    func testMixedDepthOutdentDoesNotApplyOverlappingMarkerMutations() throws {
        let text = """
        - outer
            1. child parent
                1. grandchild
            9. child to outdent
        - next
        """
        let start = (text as NSString).range(of: "1. grandchild").location
        let end = NSMaxRange((text as NSString).range(of: "9. child to outdent"))

        let edit = try XCTUnwrap(MarkdownListIndentation.edit(
            text: text,
            selection: NSRange(location: start, length: end - start),
            direction: .outdent
        ))

        XCTAssertEqual(
            apply(edit, to: text),
            """
            - outer
                1. child parent
                2. grandchild
            - child to outdent
            - next
            """
        )
    }

    func testMixedDepthOutdentRetainsDeeperDestinationNumbering() throws {
        let text = """
        - parent
            1. anchor
                1. deep
            2. move
            99. next
        """
        let start = (text as NSString).range(of: "1. deep").location
        let end = NSMaxRange((text as NSString).range(of: "2. move"))

        let edit = try XCTUnwrap(MarkdownListIndentation.edit(
            text: text,
            selection: NSRange(location: start, length: end - start),
            direction: .outdent
        ))

        XCTAssertEqual(
            apply(edit, to: text),
            """
            - parent
                1. anchor
                2. deep
            - move
                3. next
            """
        )
    }

    func testBacktabSelectionMovesChildEvenWhenSelectedParentIsTopLevel() throws {
        for (text, expected) in [
            ("- parent\n    - child", "- parent\n- child"),
            ("> - parent\n>     - child", "> - parent\n> - child")
        ] {
            let edit = try XCTUnwrap(MarkdownListIndentation.edit(
                text: text,
                selection: NSRange(location: 0, length: (text as NSString).length),
                direction: .outdent
            ))

            XCTAssertEqual(apply(edit, to: text), expected)
        }
    }

    func testTabResetsOrderedSequenceAfterCrossingShallowerQuoteScope() throws {
        let text = ">> 1. first\n> 1. middle\n>> 1. last"

        let edit = try XCTUnwrap(MarkdownListIndentation.edit(
            text: text,
            selection: NSRange(location: 0, length: (text as NSString).length),
            direction: .indent
        ))

        XCTAssertEqual(
            apply(edit, to: text),
            ">>     1. first\n>     1. middle\n>>     1. last"
        )
    }

    func testTabCarriesIndentedBlockquoteWithListItemSubtree() throws {
        let text = "- parent\n    > quoted child\n- next"
        let caret = (text as NSString).range(of: "parent").location

        let edit = try XCTUnwrap(MarkdownListIndentation.edit(
            text: text,
            selection: NSRange(location: caret, length: 0),
            direction: .indent
        ))

        XCTAssertEqual(
            apply(edit, to: text),
            "    - parent\n        > quoted child\n- next"
        )
    }

    func testTabRecognizesTabIndentedDestinationStyleAtSameDepth() throws {
        let text = "1. parent\n\t- [ ] child\n2. move"
        let caret = (text as NSString).range(of: "move").location

        let edit = try XCTUnwrap(MarkdownListIndentation.edit(
            text: text,
            selection: NSRange(location: caret, length: 0),
            direction: .indent
        ))

        XCTAssertEqual(
            apply(edit, to: text),
            "1. parent\n\t- [ ] child\n    - [ ] move"
        )
    }

    func testMarkerRewritePreservesEstablishedListSpacing() throws {
        for (text, expected) in [
            ("1. parent\n2.\tchild", "1. parent\n    1.\tchild"),
            ("- parent\n    -   existing\n- moved", "- parent\n    -   existing\n    -   moved")
        ] {
            let caret = (text as NSString).range(of: text.contains("child") ? "child" : "moved").location
            let edit = try XCTUnwrap(MarkdownListIndentation.edit(
                text: text,
                selection: NSRange(location: caret, length: 0),
                direction: .indent
            ))
            XCTAssertEqual(apply(edit, to: text), expected)
        }
    }

    func testListRenumberingSaturatesAtMaximumInteger() throws {
        let maximum = String(Int.max)
        let text = """
        \(maximum). parent
            \(maximum). existing
        \(maximum). selected
        """
        let caret = (text as NSString).range(of: "selected").location

        let edit = try XCTUnwrap(MarkdownListIndentation.edit(
            text: text,
            selection: NSRange(location: caret, length: 0),
            direction: .indent
        ))

        XCTAssertEqual(
            apply(edit, to: text),
            """
            \(maximum). parent
                \(maximum). existing
                \(maximum). selected
            """
        )
    }

    func testTabAndBacktabRoundTripQuotedTaskListItem() throws {
        let text = "> - [ ] quoted task"
        let selection = (text as NSString).range(of: "quoted")

        let indent = try XCTUnwrap(MarkdownListIndentation.edit(
            text: text,
            selection: selection,
            direction: .indent
        ))
        let indented = apply(indent, to: text)
        XCTAssertEqual(indented, ">     - [ ] quoted task")

        let outdent = try XCTUnwrap(MarkdownListIndentation.edit(
            text: indented,
            selection: indent.selection,
            direction: .outdent
        ))
        XCTAssertEqual(apply(outdent, to: indented), text)
        XCTAssertEqual(outdent.selection, selection)
    }

    func testMultilineSelectionIndentsEverySelectedListLineAndExcludesNextLine() throws {
        let text = "1. first\n- [x] second\nparagraph"
        let paragraphStart = (text as NSString).range(of: "paragraph").location
        let selection = NSRange(location: 0, length: paragraphStart)

        let edit = try XCTUnwrap(MarkdownListIndentation.edit(
            text: text,
            selection: selection,
            direction: .indent
        ))

        XCTAssertEqual(
            apply(edit, to: text),
            "    1. first\n    2. second\nparagraph"
        )
        XCTAssertEqual(edit.selection.location, 4)
        XCTAssertEqual(NSMaxRange(edit.selection), paragraphStart + 5)
    }

    func testBacktabTaskChildAdoptsOrderedParentAndRenumbersFollowingPeer() throws {
        let text = """
        1. parent
            - [ ] child
                1. grandchild
        2. next
        """
        let caret = (text as NSString).range(of: "child").location

        let edit = try XCTUnwrap(MarkdownListIndentation.edit(
            text: text,
            selection: NSRange(location: caret, length: 0),
            direction: .outdent
        ))

        XCTAssertEqual(
            apply(edit, to: text),
            """
            1. parent
            2. child
                1. grandchild
            3. next
            """
        )
    }

    func testBacktabOrderedChildAdoptsBulletParentStyle() throws {
        let text = "* parent\n    1. child\n* next"
        let caret = (text as NSString).range(of: "child").location

        let edit = try XCTUnwrap(MarkdownListIndentation.edit(
            text: text,
            selection: NSRange(location: caret, length: 0),
            direction: .outdent
        ))

        XCTAssertEqual(apply(edit, to: text), "* parent\n* child\n* next")
    }

    func testTabOrderedItemAdoptsExistingTaskChildrenAndClosesOuterGap() throws {
        let text = """
        1. parent
            - [x] existing
        2. move me
        3. next
        """
        let caret = (text as NSString).range(of: "move me").location

        let edit = try XCTUnwrap(MarkdownListIndentation.edit(
            text: text,
            selection: NSRange(location: caret, length: 0),
            direction: .indent
        ))

        XCTAssertEqual(
            apply(edit, to: text),
            """
            1. parent
                - [x] existing
                - [ ] move me
            2. next
            """
        )
    }

    func testTabOrderedTaskClosesNumberingGapAcrossTaskSyntax() throws {
        let text = "1. parent\n2. [ ] move\n3. next"
        let caret = (text as NSString).range(of: "move").location

        let edit = try XCTUnwrap(MarkdownListIndentation.edit(
            text: text,
            selection: NSRange(location: caret, length: 0),
            direction: .indent
        ))

        XCTAssertEqual(
            apply(edit, to: text),
            "1. parent\n    1. [ ] move\n2. next"
        )
    }

    func testSelectedParagraphSeparatedOrderedListsRenumberIndependently() throws {
        let text = """
        1. keep
        2. move
        paragraph
        10. move too
        11. remains
        """
        let start = (text as NSString).range(of: "2. move").location
        let end = NSMaxRange((text as NSString).range(of: "10. move too"))

        let edit = try XCTUnwrap(MarkdownListIndentation.edit(
            text: text,
            selection: NSRange(location: start, length: end - start),
            direction: .indent
        ))

        XCTAssertEqual(
            apply(edit, to: text),
            """
            1. keep
                1. move
            paragraph
                1. move too
            1. remains
            """
        )
    }

    func testTabTaskItemPreservesStateWhenDestinationIsAlsoTaskList() throws {
        let text = """
        - parent
            - [ ] existing
        - [x] completed
        """
        let caret = (text as NSString).range(of: "completed").location

        let edit = try XCTUnwrap(MarkdownListIndentation.edit(
            text: text,
            selection: NSRange(location: caret, length: 0),
            direction: .indent
        ))

        XCTAssertEqual(
            apply(edit, to: text),
            """
            - parent
                - [ ] existing
                - [x] completed
            """
        )
    }

    func testBacktabMultipleTaskChildrenContinueOrderedDestination() throws {
        let text = """
        1. parent
            - [x] first
            - [ ] second
        2. next
        """
        let start = (text as NSString).range(of: "- [x] first").location
        let end = NSMaxRange((text as NSString).range(of: "- [ ] second"))

        let edit = try XCTUnwrap(MarkdownListIndentation.edit(
            text: text,
            selection: NSRange(location: start, length: end - start),
            direction: .outdent
        ))

        XCTAssertEqual(
            apply(edit, to: text),
            """
            1. parent
            2. first
            3. second
            4. next
            """
        )
    }

    func testTabMovesBlankSeparatedDescendantsAndPreservesTheirMarkers() throws {
        let text = """
        1. parent
        2. move

            - [x] descendant
        3. next
        """
        let caret = (text as NSString).range(of: "move").location

        let edit = try XCTUnwrap(MarkdownListIndentation.edit(
            text: text,
            selection: NSRange(location: caret, length: 0),
            direction: .indent
        ))

        XCTAssertEqual(
            apply(edit, to: text),
            """
            1. parent
                1. move

                    - [x] descendant
            2. next
            """
        )
    }

    func testTopLevelBacktabDoesNotMoveItsNestedSubtree() throws {
        let text = "1. parent\n    - [ ] child"
        let caret = (text as NSString).range(of: "parent").location

        let edit = try XCTUnwrap(MarkdownListIndentation.edit(
            text: text,
            selection: NSRange(location: caret, length: 0),
            direction: .outdent
        ))

        XCTAssertFalse(edit.changes(text))
        XCTAssertEqual(apply(edit, to: text), text)
    }

    func testMultilineListSelectionIndentsContinuationLines() throws {
        let text = "- parent\n  continuation\n- sibling"
        let siblingStart = (text as NSString).range(of: "- sibling").location

        let edit = try XCTUnwrap(MarkdownListIndentation.edit(
            text: text,
            selection: NSRange(location: 0, length: siblingStart),
            direction: .indent
        ))

        XCTAssertEqual(
            apply(edit, to: text),
            "    - parent\n      continuation\n- sibling"
        )
    }

    func testBacktabRemovesTabOrUpToFourSpacesWithoutDamagingMarkers() throws {
        for (text, expected) in [
            ("\t* item", "* item"),
            ("  3) item", "3) item"),
            ("    + [X] item", "+ [X] item")
        ] {
            let edit = try XCTUnwrap(MarkdownListIndentation.edit(
                text: text,
                selection: NSRange(location: (text as NSString).length, length: 0),
                direction: .outdent
            ))
            XCTAssertEqual(apply(edit, to: text), expected)
        }
    }

    func testTopLevelBacktabIsConsumedAsNoOpAndPlainTextUsesNativeTab() throws {
        let listText = "- item"
        let edit = try XCTUnwrap(MarkdownListIndentation.edit(
            text: listText,
            selection: NSRange(location: 2, length: 0),
            direction: .outdent
        ))

        XCTAssertFalse(edit.changes(listText))
        XCTAssertNil(MarkdownListIndentation.edit(
            text: "plain text",
            selection: NSRange(location: 4, length: 0),
            direction: .indent
        ))
    }

    func testStandaloneIndentedCodeUsesNativeTabBehaviorWhenIndenting() {
        let text = "    - literal Markdown-looking code"
        let caret = NSRange(location: (text as NSString).length, length: 0)

        XCTAssertNil(MarkdownListIndentation.edit(
            text: text,
            selection: caret,
            direction: .indent
        ))
    }

    func testContextualNestedListStillUsesSmartIndentation() throws {
        let text = "- parent\n    - child"
        let caret = (text as NSString).range(of: "child").location

        let edit = try XCTUnwrap(MarkdownListIndentation.edit(
            text: text,
            selection: NSRange(location: caret, length: 0),
            direction: .indent
        ))

        XCTAssertEqual(apply(edit, to: text), "- parent\n        - child")
        XCTAssertEqual(edit.selection, NSRange(location: caret + 4, length: 0))
    }

    @MainActor
    func testTextViewIndentationParticipatesInNativeUndo() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 200),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let textView = MarkdownNavigationTextView(frame: .zero)
        textView.allowsUndo = true
        window.contentView = textView
        window.makeFirstResponder(textView)
        textView.string = "- undo me"
        textView.setSelectedRange(NSRange(location: 2, length: 0))

        textView.insertTab(nil)

        XCTAssertEqual(textView.string, "    - undo me")
        let undoManager = try XCTUnwrap(textView.undoManager)
        XCTAssertTrue(undoManager.canUndo)
        undoManager.undo()
        XCTAssertEqual(textView.string, "- undo me")
    }

    @MainActor
    func testOrderedEnterRenumbersFollowingPeersWithoutTouchingDescendants() throws {
        let (window, textView) = makeTextView(
            text: "1. first\n2. second\n    - child\n3. third"
        )
        _ = window
        let caret = NSMaxRange((textView.string as NSString).range(of: "1. first"))
        textView.setSelectedRange(NSRange(location: caret, length: 0))

        textView.insertNewline(nil)

        XCTAssertEqual(
            textView.string,
            "1. first\n2. \n3. second\n    - child\n4. third"
        )
        XCTAssertEqual(
            textView.selectedRange(),
            NSRange(location: caret + ("\n2. " as NSString).length, length: 0)
        )
        let undoManager = try XCTUnwrap(textView.undoManager)
        undoManager.undo()
        XCTAssertEqual(textView.string, "1. first\n2. second\n    - child\n3. third")
    }

    @MainActor
    func testNestedOrderedEnterRenumbersOnlyItsOwnDepth() {
        let (window, textView) = makeTextView(
            text: "1. outer\n    1. first\n    2. second\n2. next"
        )
        _ = window
        let caret = NSMaxRange((textView.string as NSString).range(of: "1. first"))
        textView.setSelectedRange(NSRange(location: caret, length: 0))

        textView.insertNewline(nil)

        XCTAssertEqual(
            textView.string,
            "1. outer\n    1. first\n    2. \n    3. second\n2. next"
        )
    }

    @MainActor
    func testEmptyNestedTaskEnterOutdentsToOrderedParentAndRenumbersSuffix() throws {
        let original = "1. parent\n    - [ ] \n2. next"
        let (window, textView) = makeTextView(text: original)
        _ = window
        let caret = NSMaxRange((textView.string as NSString).range(of: "    - [ ] "))
        textView.setSelectedRange(NSRange(location: caret, length: 0))

        textView.insertNewline(nil)

        XCTAssertEqual(textView.string, "1. parent\n2. \n3. next")
        XCTAssertEqual(textView.selectedRange().location, ("1. parent\n2. " as NSString).length)
        let undoManager = try XCTUnwrap(textView.undoManager)
        undoManager.undo()
        XCTAssertEqual(textView.string, original)
    }

    @MainActor
    func testEmptyNestedOrderedEnterAdoptsBulletParent() {
        let (window, textView) = makeTextView(text: "* parent\n    1. \n* next")
        _ = window
        let caret = NSMaxRange((textView.string as NSString).range(of: "    1. "))
        textView.setSelectedRange(NSRange(location: caret, length: 0))

        textView.insertNewline(nil)

        XCTAssertEqual(textView.string, "* parent\n* \n* next")
    }

    @MainActor
    func testOrderedTaskEnterContinuesUnchecked() {
        let (window, textView) = makeTextView(text: "1. [x] done")
        _ = window
        textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0))

        textView.insertNewline(nil)

        XCTAssertEqual(textView.string, "1. [x] done\n2. [ ] ")
    }

    @MainActor
    func testOrderedTaskEnterRenumbersNormalOrderedSuffix() {
        let (window, textView) = makeTextView(text: "1. [x] done\n2. next")
        _ = window
        let caret = NSMaxRange((textView.string as NSString).range(of: "done"))
        textView.setSelectedRange(NSRange(location: caret, length: 0))

        textView.insertNewline(nil)

        XCTAssertEqual(textView.string, "1. [x] done\n2. [ ] \n3. next")
    }

    @MainActor
    func testOrderedEnterRenumbersTabAndSpaceIndentedPeersAtSameDepth() {
        let (window, textView) = makeTextView(
            text: "1. outer\n    1. first\n\t2. second"
        )
        _ = window
        let caret = NSMaxRange((textView.string as NSString).range(of: "first"))
        textView.setSelectedRange(NSRange(location: caret, length: 0))

        textView.insertNewline(nil)

        XCTAssertEqual(
            textView.string,
            "1. outer\n    1. first\n    2. \n\t3. second"
        )
    }

    @MainActor
    func testEnterAtListContentStartKeepsFollowingContentInTheList() {
        for (text, marker, expected) in [
            ("1. alpha", "1. ", "1. \n2. alpha"),
            ("- alpha", "- ", "- \n- alpha")
        ] {
            let (window, textView) = makeTextView(text: text)
            _ = window
            textView.setSelectedRange(NSRange(
                location: (marker as NSString).length,
                length: 0
            ))

            textView.insertNewline(nil)

            XCTAssertEqual(textView.string, expected)
        }
    }

    @MainActor
    func testQuotedOrderedEnterPreservesDelimiterAndRenumbersQuoteScope() {
        let (window, textView) = makeTextView(text: "> 1) first\n> 2) next")
        _ = window
        let caret = NSMaxRange((textView.string as NSString).range(of: "first"))
        textView.setSelectedRange(NSRange(location: caret, length: 0))

        textView.insertNewline(nil)

        XCTAssertEqual(textView.string, "> 1) first\n> 2) \n> 3) next")
    }

    @MainActor
    func testMixedListBacktabIsOneUndoableEditAndKeepsCaretWithContent() throws {
        let original = "1. parent\n    - [ ] child\n2. next"
        let (window, textView) = makeTextView(text: original)
        _ = window
        let caret = (original as NSString).range(of: "child").location
        textView.setSelectedRange(NSRange(location: caret, length: 0))

        textView.insertBacktab(nil)

        XCTAssertEqual(textView.string, "1. parent\n2. child\n3. next")
        XCTAssertEqual(
            textView.selectedRange().location,
            (textView.string as NSString).range(of: "child").location
        )
        let undoManager = try XCTUnwrap(textView.undoManager)
        undoManager.undo()
        XCTAssertEqual(textView.string, original)
    }

    @MainActor
    func testEmptyTopLevelListEnterExitsWhileQuotedListKeepsQuote() {
        for (text, expected) in [
            ("- [ ] ", ""),
            ("> - ", "> ")
        ] {
            let (window, textView) = makeTextView(text: text)
            _ = window
            textView.setSelectedRange(NSRange(
                location: (text as NSString).length,
                length: 0
            ))

            textView.insertNewline(nil)

            XCTAssertEqual(textView.string, expected)
        }
    }

    @MainActor
    func testControllerZoomClampsAndDisplayTogglesRoundTrip() {
        let controller = MarkdownEditorController()

        controller.setFontSize(1_000)
        XCTAssertEqual(controller.fontSize, MarkdownEditorController.maximumFontSize)
        XCTAssertFalse(controller.canZoomIn)

        controller.setFontSize(-1)
        XCTAssertEqual(controller.fontSize, MarkdownEditorController.minimumFontSize)
        XCTAssertFalse(controller.canZoomOut)

        controller.resetZoom()
        XCTAssertTrue(controller.isDefaultZoom)

        controller.toggleWordWrap()
        XCTAssertFalse(controller.isWordWrapEnabled)
        controller.toggleWordWrap()
        XCTAssertTrue(controller.isWordWrapEnabled)

        controller.toggleLineNumbers()
        XCTAssertFalse(controller.showsLineNumbers)
        controller.toggleLineNumbers()
        XCTAssertTrue(controller.showsLineNumbers)
    }

    @MainActor
    func testControllerGoToLineClampsSelectsRevealsAndFocuses() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 200),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let textView = NSTextView(frame: window.contentView?.bounds ?? .zero)
        textView.string = "one\ntwo\nthree"
        window.contentView = textView

        let controller = MarkdownEditorController()
        controller.attach(to: textView)

        XCTAssertTrue(controller.goToLine(2))
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 4, length: 0))
        XCTAssertTrue(window.firstResponder === textView)

        XCTAssertTrue(controller.goToLine(999))
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 8, length: 0))
    }

    @MainActor
    func testWordWrapConfigurationControlsContainerAndHorizontalScroller() {
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        let textView = NSTextView(frame: scrollView.bounds)
        scrollView.documentView = textView

        MarkdownEditorLayout.applyWordWrap(false, to: textView, in: scrollView)
        XCTAssertTrue(scrollView.hasHorizontalScroller)
        XCTAssertTrue(textView.isHorizontallyResizable)
        XCTAssertFalse(try XCTUnwrap(textView.textContainer).widthTracksTextView)

        MarkdownEditorLayout.applyWordWrap(true, to: textView, in: scrollView)
        XCTAssertFalse(scrollView.hasHorizontalScroller)
        XCTAssertFalse(textView.isHorizontallyResizable)
        XCTAssertTrue(try XCTUnwrap(textView.textContainer).widthTracksTextView)
    }

    @MainActor
    func testWrappedEditorRecoversFromZeroWidthRepresentableLayout() throws {
        let scrollView = MarkdownEditorScrollView(frame: .zero)
        let textView = NSTextView(frame: .zero)
        textView.string = "Text that must remain visible after the viewport is laid out."
        scrollView.documentView = textView
        scrollView.onViewportLayout = {
            MarkdownEditorLayout.synchronizeWrappedWidth(of: textView, in: scrollView)
        }

        MarkdownEditorLayout.applyWordWrap(true, to: textView, in: scrollView)
        XCTAssertLessThanOrEqual(textView.frame.width, 1)

        scrollView.frame = NSRect(x: 0, y: 0, width: 360, height: 220)
        scrollView.tile()

        XCTAssertGreaterThan(textView.frame.width, 300)
        XCTAssertEqual(
            try XCTUnwrap(textView.textContainer).containerSize.width,
            textView.frame.width - textView.textContainerInset.width * 2,
            accuracy: 0.5
        )
    }

    @MainActor
    func testLineNumberRulerDoesNotExpandAcrossEditorFromZeroWidth() throws {
        let scrollView = MarkdownEditorScrollView(frame: .zero)
        let textView = NSTextView(frame: .zero)
        textView.string = "- parent\n    1. child\n        - [ ] nested task"
        scrollView.documentView = textView

        let rulerView = MarkdownLineNumberRulerView(
            textView: textView,
            scrollView: scrollView
        )
        scrollView.verticalRulerView = rulerView
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = true

        scrollView.frame = NSRect(x: 0, y: 0, width: 440, height: 300)
        // SwiftUI can propose the full split-pane width to an AppKit ruler
        // during its zero-width-to-visible transition.
        rulerView.setFrameSize(NSSize(width: 440, height: 300))
        XCTAssertLessThan(rulerView.frame.width, 50)
        scrollView.tile()

        XCTAssertLessThan(rulerView.frame.width, 50)
        XCTAssertEqual(rulerView.frame.width, rulerView.requiredThickness, accuracy: 0.5)
    }

    @MainActor
    func testLineNumberRulerRecalculatesAfterExternalTextReplacement() {
        let scrollView = MarkdownEditorScrollView(
            frame: NSRect(x: 0, y: 0, width: 440, height: 300)
        )
        let textView = NSTextView(frame: scrollView.bounds)
        textView.string = (1...1_000).map { "Line \($0)" }.joined(separator: "\n")
        scrollView.documentView = textView
        let rulerView = MarkdownLineNumberRulerView(
            textView: textView,
            scrollView: scrollView
        )
        let wideThickness = rulerView.requiredThickness

        textView.string = "one line"
        rulerView.invalidateLineNumbers(recalculateLineStarts: true)

        XCTAssertLessThan(rulerView.requiredThickness, wideThickness)
    }

    @MainActor
    func testSwiftUIEditorRepresentableUsesItsVisibleViewportWidth() async throws {
        let controller = MarkdownEditorController()
        let nestedLists = """
        - parent
            1. numbered child
                - [ ] nested task
        """
        let source = nestedLists + "\n\n" + (1...66).map { line in
            "Line \(line): " + String(repeating: "wrapped text ", count: 10)
        }.joined(separator: "\n")
        let editor = MarkdownEditorView(
            text: .constant(source),
            controller: controller
        )
        let hostingView = NSHostingView(rootView: editor)
        hostingView.frame = NSRect(x: 0, y: 0, width: 900, height: 400)
        let window = NSWindow(
            contentRect: hostingView.frame,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView

        for _ in 0..<3 {
            hostingView.layoutSubtreeIfNeeded()
            await Task.yield()
        }

        let scrollView = try XCTUnwrap(
            descendants(of: hostingView).compactMap { $0 as? MarkdownEditorScrollView }.first
        )
        let textView = try XCTUnwrap(scrollView.documentView as? MarkdownTextView)

        XCTAssertTrue(textView.string.hasPrefix(nestedLists))

        XCTAssertTrue(controller.goToLine(70))
        window.setContentSize(NSSize(width: 440, height: 400))
        for _ in 0..<3 {
            hostingView.layoutSubtreeIfNeeded()
            await Task.yield()
        }

        XCTAssertGreaterThan(scrollView.contentSize.width, 300)
        XCTAssertGreaterThan(textView.frame.width, 300)
        XCTAssertGreaterThan(textView.frame.height, 300)
        let rulerView = try XCTUnwrap(scrollView.verticalRulerView)
        XCTAssertLessThan(rulerView.frame.width, 50)
        XCTAssertEqual(rulerView.frame.width, rulerView.requiredThickness, accuracy: 0.5)
        XCTAssertEqual(textView.frame.origin.x, 0, accuracy: 0.5)
        XCTAssertEqual(textView.frame.origin.y, 0, accuracy: 0.5)
        XCTAssertFalse(textView.visibleRect.intersection(textView.bounds).isEmpty)
        XCTAssertEqual(
            try XCTUnwrap(textView.textContainer).containerSize.width,
            textView.frame.width - textView.textContainerInset.width * 2,
            accuracy: 0.5
        )
    }

    private func apply(_ edit: MarkdownListIndentation.Edit, to text: String) -> String {
        let result = NSMutableString(string: text)
        result.replaceCharacters(in: edit.replacementRange, with: edit.replacement)
        return result as String
    }

    @MainActor
    private func descendants(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap(descendants(of:))
    }

    @MainActor
    private func makeTextView(text: String) -> (NSWindow, MarkdownNavigationTextView) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 200),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let textView = MarkdownNavigationTextView(frame: .zero)
        textView.allowsUndo = true
        window.contentView = textView
        window.makeFirstResponder(textView)
        textView.string = text
        return (window, textView)
    }
}
