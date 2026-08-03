import AppKit
import WebKit
import XCTest
@testable import ACMD

final class PreviewFindTests: XCTestCase {
    @MainActor
    func testFindActionsShowAndHideNativePreviewBar() {
        let webView = PreviewWebView(frame: NSRect(x: 0, y: 0, width: 520, height: 360))
        let container = PreviewFindContainer(webView: webView)
        defer { container.invalidateTextFinder() }

        webView.performTextFinderAction(menuItem(for: .showFindInterface))

        XCTAssertTrue(container.isFindBarVisible)
        XCTAssertFalse(container.findBarView.isHidden)
        XCTAssertTrue(container.contentView === container.webView)

        container.performTextFinderAction(menuItem(for: .hideFindInterface))

        XCTAssertFalse(container.isFindBarVisible)
        XCTAssertTrue(container.findBarView.isHidden)
    }

    @MainActor
    func testFindBarTilesAboveRenderedPreview() {
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 520, height: 360))
        let container = PreviewFindContainer(webView: webView)
        defer { container.invalidateTextFinder() }

        container.frame = NSRect(x: 0, y: 0, width: 520, height: 360)
        container.showFind()
        container.layoutSubtreeIfNeeded()

        let findBar = container.findBarView
        XCTAssertEqual(findBar.frame.width, container.bounds.width, accuracy: 0.5)
        XCTAssertEqual(container.webView.frame.minY, container.bounds.minY, accuracy: 0.5)
        XCTAssertEqual(container.webView.frame.maxY, findBar.frame.minY, accuracy: 0.5)
    }

    @MainActor
    func testRepeatedShowFindOnlyRefocusesExistingSearch() {
        let pasteboard = NSPasteboard(name: .find)
        let previousQuery = pasteboard.string(forType: .string)
        pasteboard.clearContents()
        pasteboard.setString("preview-query", forType: .string)
        defer {
            pasteboard.clearContents()
            if let previousQuery {
                pasteboard.setString(previousQuery, forType: .string)
            }
        }

        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 320, height: 240))
        let container = PreviewFindContainer(webView: webView)
        defer { container.invalidateTextFinder() }

        container.showFind()
        let initialRequestCount = container.searchRequestCount
        container.showFind()

        XCTAssertEqual(initialRequestCount, 1)
        XCTAssertEqual(container.searchRequestCount, initialRequestCount)
    }

    @MainActor
    func testEscapeClosesFindBar() {
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 320, height: 240))
        let container = PreviewFindContainer(webView: webView)
        defer { container.invalidateTextFinder() }

        container.showFind()
        container.searchFieldView.cancelOperation(nil)

        XCTAssertFalse(container.isFindBarVisible)
        XCTAssertTrue(container.findBarView.isHidden)
    }

    @MainActor
    func testYellowFindHighlightIsScopedToActivePreviewSearch() {
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 320, height: 240))
        let container = PreviewFindContainer(webView: webView)
        defer { container.invalidateTextFinder() }
        container.searchFieldView.stringValue = "needle"

        container.showFind()
        XCTAssertTrue(container.isFindHighlightActive)

        container.closeFind()
        XCTAssertFalse(container.isFindHighlightActive)
    }

    @MainActor
    func testRenderedFindMatchUsesYellowSelectionStyle() async throws {
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 420, height: 280))
        let container = PreviewFindContainer(webView: webView)
        let loaded = expectation(description: "Rendered preview loaded")
        let navigationDelegate = PreviewNavigationWaiter(expectation: loaded)
        webView.navigationDelegate = navigationDelegate
        defer {
            webView.navigationDelegate = nil
            container.invalidateTextFinder()
        }

        webView.loadHTMLString(
            MarkdownHTMLRenderer().renderDocument(markdown: "The needle is visible."),
            baseURL: nil
        )
        await fulfillment(of: [loaded], timeout: 5)

        container.searchFieldView.stringValue = "needle"
        container.showFind()
        let classIsActive = try await webView.evaluateJavaScript(
            "document.documentElement.classList.contains('acmd-find-active')"
        ) as? Bool

        let configuration = WKFindConfiguration()
        configuration.wraps = true
        let result = try await webView.find("needle", configuration: configuration)
        let selectedText = try await webView.evaluateJavaScript(
            "window.getSelection().toString()"
        ) as? String
        let selectionColor = try await webView.evaluateJavaScript(
            "getComputedStyle(document.querySelector('p'), '::selection').backgroundColor"
        ) as? String

        XCTAssertEqual(classIsActive, true)
        XCTAssertTrue(result.matchFound)
        XCTAssertEqual(selectedText, "needle")
        XCTAssertEqual(selectionColor, "rgb(255, 255, 0)")

        container.closeFind()
        let classIsInactive = try await webView.evaluateJavaScript(
            "document.documentElement.classList.contains('acmd-find-active')"
        ) as? Bool
        let selectedTextAfterClose = try await webView.evaluateJavaScript(
            "window.getSelection().toString()"
        ) as? String
        XCTAssertEqual(classIsInactive, false)
        XCTAssertEqual(selectedTextAfterClose, "")
    }

    @MainActor
    func testEditorFindSessionMirrorsMatchIntoRenderedPreview() async throws {
        let session = MarkdownFindSession()
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 420, height: 280))
        let container = PreviewFindContainer(webView: webView, findSession: session)
        let loaded = expectation(description: "Rendered preview loaded")
        let navigationDelegate = PreviewNavigationWaiter(expectation: loaded)
        webView.navigationDelegate = navigationDelegate
        defer {
            webView.navigationDelegate = nil
            container.invalidateTextFinder()
        }

        webView.loadHTMLString(
            MarkdownHTMLRenderer().renderDocument(markdown: "The mirrored needle is visible."),
            baseURL: nil
        )
        await fulfillment(of: [loaded], timeout: 5)

        session.activate(source: .editor, query: "needle")
        let selectedText = try await waitForSelectedText("needle", in: webView)
        let selectionColor = try await webView.evaluateJavaScript(
            "getComputedStyle(document.querySelector('p'), '::selection').backgroundColor"
        ) as? String

        XCTAssertEqual(selectedText, "needle")
        XCTAssertEqual(selectionColor, "rgb(255, 255, 0)")
        XCTAssertTrue(container.isFindHighlightActive)

        session.deactivate(source: .editor)
        let classIsInactive = try await webView.evaluateJavaScript(
            "document.documentElement.classList.contains('acmd-find-active')"
        ) as? Bool
        let selectedTextAfterClose = try await webView.evaluateJavaScript(
            "window.getSelection().toString()"
        ) as? String
        XCTAssertEqual(classIsInactive, false)
        XCTAssertEqual(selectedTextAfterClose, "")
    }

    @MainActor
    func testPreviewFindPublishesSharedQuery() {
        let session = MarkdownFindSession()
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 320, height: 240))
        let container = PreviewFindContainer(webView: webView, findSession: session)
        defer { container.invalidateTextFinder() }
        container.searchFieldView.stringValue = "needle"

        container.showFind()

        XCTAssertTrue(session.state.active)
        XCTAssertEqual(session.state.source, .preview)
        XCTAssertEqual(session.state.query, "needle")

        container.closeFind()
        XCTAssertFalse(session.state.active)
    }

    @MainActor
    func testClosingPreviewBarPreservesEditorOwnedSearch() {
        let session = MarkdownFindSession()
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 320, height: 240))
        let container = PreviewFindContainer(webView: webView, findSession: session)
        defer { container.invalidateTextFinder() }
        container.searchFieldView.stringValue = "preview-query"
        container.showFind()

        session.activate(source: .editor, query: "editor-query")
        container.closeFind()

        XCTAssertTrue(session.state.active)
        XCTAssertEqual(session.state.source, .editor)
        XCTAssertEqual(session.state.query, "editor-query")
        XCTAssertTrue(container.isFindHighlightActive)
    }

    @MainActor
    func testClosingPreviewBarDoesNotAdvanceEditorOwnedRenderedMatch() async throws {
        let session = MarkdownFindSession()
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 420, height: 280))
        let container = PreviewFindContainer(webView: webView, findSession: session)
        let loaded = expectation(description: "Rendered preview loaded")
        let navigationDelegate = PreviewNavigationWaiter(expectation: loaded)
        webView.navigationDelegate = navigationDelegate
        defer {
            webView.navigationDelegate = nil
            container.invalidateTextFinder()
        }

        webView.loadHTMLString(
            MarkdownHTMLRenderer().renderDocument(markdown: "needle first; needle second"),
            baseURL: nil
        )
        await fulfillment(of: [loaded], timeout: 5)

        container.searchFieldView.stringValue = "local-query"
        container.showFind()
        session.activate(source: .editor, query: "needle")
        _ = try await waitForSelectedText("needle", in: webView)
        let offsetBeforeClose = try await selectedTextOffset(in: webView)

        container.closeFind()
        try await Task.sleep(nanoseconds: 100_000_000)
        let offsetAfterClose = try await selectedTextOffset(in: webView)

        XCTAssertEqual(offsetBeforeClose, offsetAfterClose)
    }

    @MainActor
    func testShowingExistingPreviewBarRefreshesAfterEditorOwnedSearch() {
        let session = MarkdownFindSession()
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 320, height: 240))
        let container = PreviewFindContainer(webView: webView, findSession: session)
        defer { container.invalidateTextFinder() }
        container.searchFieldView.stringValue = "preview-query"
        container.showFind()
        session.activate(source: .editor, query: "editor-query")
        let requestCountBeforeRefocus = container.searchRequestCount

        container.showFind()

        XCTAssertEqual(session.state.source, .preview)
        XCTAssertEqual(session.state.query, "preview-query")
        XCTAssertEqual(container.searchRequestCount, requestCountBeforeRefocus + 1)
    }

    @MainActor
    func testInvalidatingFinderIsIdempotent() {
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 320, height: 240))
        let container = PreviewFindContainer(webView: webView)

        container.invalidateTextFinder()
        container.invalidateTextFinder()
        container.noteSearchableContentWillChange()

        XCTAssertFalse(container.restoreActiveFindAfterContentLoad())
    }

    @MainActor
    private func menuItem(for action: NSTextFinder.Action) -> NSMenuItem {
        let item = NSMenuItem()
        item.action = #selector(NSResponder.performTextFinderAction(_:))
        item.tag = action.rawValue
        return item
    }

    @MainActor
    private func waitForSelectedText(
        _ expected: String,
        in webView: WKWebView
    ) async throws -> String? {
        for _ in 0..<50 {
            let selected = try await webView.evaluateJavaScript(
                "window.getSelection().toString()"
            ) as? String
            if selected == expected {
                return selected
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        return try await webView.evaluateJavaScript(
            "window.getSelection().toString()"
        ) as? String
    }

    @MainActor
    private func selectedTextOffset(in webView: WKWebView) async throws -> Int? {
        let value = try await webView.evaluateJavaScript(
            """
            (() => {
              const selection = window.getSelection();
              const root = document.querySelector('p');
              if (!selection || selection.rangeCount === 0 || !root) return null;
              const selectedRange = selection.getRangeAt(0);
              const prefix = document.createRange();
              prefix.selectNodeContents(root);
              prefix.setEnd(selectedRange.startContainer, selectedRange.startOffset);
              return prefix.toString().length;
            })()
            """
        )
        return (value as? NSNumber)?.intValue
    }
}

@MainActor
private final class PreviewNavigationWaiter: NSObject, WKNavigationDelegate {
    private let expectation: XCTestExpectation

    init(expectation: XCTestExpectation) {
        self.expectation = expectation
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        expectation.fulfill()
    }
}
