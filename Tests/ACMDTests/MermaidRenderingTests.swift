import AppKit
import PDFKit
import WebKit
import XCTest
@testable import ACMD

final class MermaidRenderingTests: XCTestCase {
    private let diagrams = """
    # Diagrams

    ```mermaid
    flowchart LR
      A[Start] --> B[Finish]
    ```

    ```mermaid
    sequenceDiagram
      Alice->>Bob: Hello
      Bob-->>Alice: Hi
    ```

    ```mermaid
    this is not a diagram
    ```

    ```mermaid
    pie title Tasks
      "Done" : 3
      "Open" : 1
    ```
    """

    func testOnlyStandaloneMermaidDocumentsIncludeTrustedScripts() {
        let preview = MarkdownHTMLRenderer().renderDocument(markdown: diagrams)
        XCTAssertTrue(preview.contains("script-src 'none'"))
        XCTAssertFalse(preview.contains("<script"))

        let export = MarkdownExportContent(markdown: diagrams, sourceURL: nil).portableHTML()
        XCTAssertTrue(export.contains("script-src 'nonce-"))
        XCTAssertTrue(export.contains("src=\"data:text/javascript;base64,"))
        XCTAssertFalse(export.contains("<script src=\"https:"))
        XCTAssertFalse(export.contains("data-source-start="))

        let ordinary = MarkdownExportContent(markdown: "```swift\nlet x = 1\n```", sourceURL: nil).portableHTML()
        XCTAssertTrue(ordinary.contains("script-src 'none'"))
        XCTAssertFalse(ordinary.contains("<script"))
    }

    @MainActor
    func testIsolatedPreviewRendersMultipleDiagramTypesAndRecoversFromInvalidSource() async throws {
        try await withWebView(markdown: diagrams) { webView, world in
            let result = try await self.diagramState(in: webView, world: world)
            XCTAssertEqual(result["states"] as? [String], ["rendered", "rendered", "error", "rendered"])
            XCTAssertEqual(result["visibleSources"] as? Int, 1)
            XCTAssertEqual(result["sizedSVGs"] as? Int, 3)
            XCTAssertEqual(result["errors"] as? Int, 1)
            XCTAssertEqual(result["sourceStart"] as? String, "2")
            XCTAssertTrue((result["text"] as? String)?.contains("Alice") == true)
            XCTAssertTrue((result["text"] as? String)?.contains("Unable to render Mermaid diagram") == true)
        }
    }

    @MainActor
    func testStandaloneHTMLRendersOfflineWithNonceCSP() async throws {
        try await withWebView(markdown: diagrams, standalone: true) { webView, world in
            let result = try await self.diagramState(in: webView, world: world)
            XCTAssertEqual(result["states"] as? [String], ["rendered", "rendered", "error", "rendered"])
            XCTAssertEqual(result["sizedSVGs"] as? Int, 3)
        }
    }

    @MainActor
    func testPreviewRerendersWhenAppearanceChanges() async throws {
        try await withWebView(markdown: diagrams, appearance: .darkAqua) { webView, world in
            _ = try await self.diagramState(in: webView, world: world)
            let initialTheme = try await webView.callAsyncJavaScript(
                "return mermaid.mermaidAPI.getConfig().theme;",
                arguments: [:], in: nil, contentWorld: world
            ) as? String
            XCTAssertEqual(initialTheme, "dark")

            _ = try await webView.callAsyncJavaScript(
                """
                window.__testAppearanceChanged = new Promise(resolve => {
                  window.matchMedia('(prefers-color-scheme: dark)').addEventListener('change', () => {
                    Promise.resolve().then(async () => { await window.__acmdMermaidReady; resolve(true); });
                  }, { once: true });
                });
                return true;
                """,
                arguments: [:], in: nil, contentWorld: world
            )
            webView.appearance = NSAppearance(named: .aqua)
            let updatedTheme = try await webView.callAsyncJavaScript(
                """
                await Promise.race([
                  window.__testAppearanceChanged,
                  new Promise((_, reject) => setTimeout(() => reject(new Error('Appearance did not change')), 5000))
                ]);
                return mermaid.mermaidAPI.getConfig().theme;
                """,
                arguments: [:], in: nil, contentWorld: world
            ) as? String
            XCTAssertEqual(updatedTheme, "default")
            let result = try await self.diagramState(in: webView, world: world)
            XCTAssertEqual(result["sizedSVGs"] as? Int, 3)
            XCTAssertEqual(result["visibleSources"] as? Int, 1)
        }
    }

    @MainActor
    func testPrintReadinessWaitsForDiagramsAndUsesLightTheme() async throws {
        try await withWebView(markdown: diagrams, forPrint: true, appearance: .darkAqua) { webView, world in
            _ = try await webView.callAsyncJavaScript(
                MarkdownPrintReadiness.waitForImagesScript,
                arguments: [:], in: nil, contentWorld: world
            )
            let result = try await self.diagramState(in: webView, world: world)
            XCTAssertEqual(result["states"] as? [String], ["rendered", "rendered", "error", "rendered"])
            let theme = try await webView.callAsyncJavaScript(
                "return mermaid.mermaidAPI.getConfig().theme;",
                arguments: [:], in: nil, contentWorld: world
            ) as? String
            XCTAssertEqual(theme, "default")
            let pdfData = try await webView.pdf(configuration: WKPDFConfiguration())
            let pdf = try XCTUnwrap(PDFDocument(data: pdfData))
            XCTAssertGreaterThan(pdf.pageCount, 0)
            XCTAssertTrue(pdf.string?.contains("Alice") == true)
        }
    }

    @MainActor
    func testDiagramDirectivesCannotEnableScriptsOrClickHandlers() async throws {
        let markdown = """
        <script>window.mermaidInjection = true</script>

        ```mermaid
        %%{init: {"securityLevel":"loose", "dompurifyConfig":{"ADD_TAGS":["script"]}}}%%
        flowchart LR
          A[Start] --> B[Finish]
          click A "javascript:window.mermaidInjection=true"
        ```
        """
        for standalone in [false, true] {
            try await withWebView(markdown: markdown, standalone: standalone) { webView, world in
                let result = try await webView.callAsyncJavaScript(
                    """
                    await window.__acmdMermaidReady;
                    return {
                      state: document.querySelector('.mermaid-diagram').dataset.mermaidState,
                      security: mermaid.mermaidAPI.getConfig().securityLevel,
                      injected: window.mermaidInjection === true,
                      links: Array.from(document.querySelectorAll('.mermaid-rendered a')).filter(element =>
                        element.hasAttribute('href') || element.hasAttributeNS('http://www.w3.org/1999/xlink', 'href')
                      ).length,
                      scripts: document.querySelectorAll('.mermaid-rendered script, .mermaid-rendered [onclick]').length
                    };
                    """,
                    arguments: [:], in: nil, contentWorld: world
                ) as? [String: Any]
                XCTAssertEqual(result?["state"] as? String, "rendered")
                XCTAssertEqual(result?["security"] as? String, "strict")
                XCTAssertEqual(result?["injected"] as? Bool, false)
                XCTAssertEqual(result?["links"] as? Int, 0)
                XCTAssertEqual(result?["scripts"] as? Int, 0)
            }
        }
    }

    @MainActor
    private func diagramState(in webView: WKWebView, world: WKContentWorld) async throws -> [String: Any] {
        let result = try await webView.callAsyncJavaScript(
            """
            await window.__acmdMermaidReady;
            return {
              states: Array.from(document.querySelectorAll('.mermaid-diagram')).map(element => element.dataset.mermaidState),
              visibleSources: document.querySelectorAll('.mermaid-source:not([hidden])').length,
              sizedSVGs: Array.from(document.querySelectorAll('.mermaid-rendered svg')).filter(svg => svg.getBoundingClientRect().height > 0).length,
              errors: document.querySelectorAll('.mermaid-error').length,
              sourceStart: document.querySelector('.mermaid-diagram').dataset.sourceStart,
              text: document.body.textContent
            };
            """,
            arguments: [:], in: nil, contentWorld: world
        )
        return try XCTUnwrap(result as? [String: Any])
    }

    @MainActor
    private func withWebView(
        markdown: String,
        standalone: Bool = false,
        forPrint: Bool = false,
        appearance: NSAppearance.Name = .aqua,
        check: (WKWebView, WKContentWorld) async throws -> Void
    ) async throws {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = standalone
        if !standalone {
            MermaidRendering.install(in: configuration, forPrint: forPrint)
        }
        let webView = WKWebView(
            frame: NSRect(x: 0, y: 0, width: 800, height: 600),
            configuration: configuration
        )
        webView.appearance = NSAppearance(named: appearance)
        let loaded = expectation(description: "Mermaid document loaded")
        let waiter = MermaidNavigationWaiter(expectation: loaded)
        webView.navigationDelegate = waiter
        defer {
            webView.navigationDelegate = nil
            webView.stopLoading()
        }
        let sourceURL = URL(fileURLWithPath: "/tmp/Mermaid Example.md")
        let html = standalone
            ? MarkdownExportContent(markdown: markdown, sourceURL: sourceURL).portableHTML()
            : MarkdownHTMLRenderer().renderDocument(markdown: markdown, documentURL: sourceURL)
        webView.loadHTMLString(html, baseURL: standalone ? nil : sourceURL.deletingLastPathComponent())
        await fulfillment(of: [loaded], timeout: 15)
        try await check(webView, standalone ? .page : .defaultClient)
    }
}

@MainActor
private final class MermaidNavigationWaiter: NSObject, WKNavigationDelegate {
    let expectation: XCTestExpectation

    init(expectation: XCTestExpectation) {
        self.expectation = expectation
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        expectation.fulfill()
    }
}
