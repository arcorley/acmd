import AppKit
import Foundation
import WebKit
import XCTest
@testable import ACMD

final class MarkdownExportControllerTests: XCTestCase {
    func testSuggestedBaseNameUsesCurrentFilenameWithoutExtension() {
        XCTAssertEqual(
            MarkdownExportContent.suggestedBaseName(
                for: URL(fileURLWithPath: "/tmp/Project Notes.markdown")
            ),
            "Project Notes"
        )
    }

    func testSuggestedBaseNameFallsBackForUntitledDocument() {
        XCTAssertEqual(MarkdownExportContent.suggestedBaseName(for: nil), "Untitled")
        XCTAssertEqual(
            MarkdownExportContent.suggestedBaseName(for: URL(fileURLWithPath: "/")),
            "Untitled"
        )
    }

    func testExportHTMLHasEscapedTitleCleanMarkupAndNoSourceBaseURL() {
        let content = MarkdownExportContent(
            markdown: "# Heading\n\n[Top](#heading) ![Image](assets/image.png)",
            sourceURL: URL(fileURLWithPath: "/tmp/A & <B>.md")
        )

        let html = content.renderedHTML()

        XCTAssertTrue(html.contains("<title>A &amp; &lt;B&gt;</title>"))
        XCTAssertFalse(html.contains("<base href="))
        XCTAssertFalse(html.contains("file:///tmp/"))
        XCTAssertTrue(html.contains("href=\"#heading\""))
        XCTAssertTrue(html.contains(#"src="assets/image.png""#))
        XCTAssertTrue(html.contains(#"loading="eager" decoding="sync""#))
        XCTAssertFalse(html.contains(#"loading="lazy""#))
        XCTAssertFalse(html.contains("data-source-"))
    }

    func testOutputOnlyRewritesLoadingAttributesOnGeneratedImages() {
        let content = MarkdownExportContent(
            markdown: """
            `loading="lazy" decoding="async"`

            ```
            // loading="lazy" decoding="async"
            ```

            ![Pixel](pixel.png)
            """,
            sourceURL: URL(fileURLWithPath: "/tmp/Notes.md")
        )

        for target in [
            MarkdownExportContent.RenderTarget.htmlExport,
            .printedDocument
        ] {
            let html = content.renderedHTML(for: target)

            XCTAssertEqual(html.components(separatedBy: #"loading="lazy""#).count - 1, 2)
            XCTAssertEqual(html.components(separatedBy: #"decoding="async""#).count - 1, 2)
            XCTAssertTrue(html.contains(#"loading="eager" decoding="sync""#))
        }
    }

    func testPrintHTMLRoutesRelativeAssetsThroughLocalImageScheme() {
        let content = MarkdownExportContent(
            markdown: "![Image](assets/image.png)",
            sourceURL: URL(fileURLWithPath: "/tmp/Notes.md")
        )

        let html = content.renderedHTML(for: .printedDocument)

        XCTAssertTrue(html.contains(#"<base href="acmd-local://document/">"#))
        XCTAssertFalse(html.contains("file:///tmp/"))
        XCTAssertTrue(html.contains(#"loading="eager" decoding="sync""#))
    }

    func testSourceDirectoryDefaultsToMarkdownFileDirectory() {
        XCTAssertEqual(
            MarkdownExportContent(
                markdown: "",
                sourceURL: URL(fileURLWithPath: "/tmp/project/Notes.md")
            ).sourceDirectoryURL,
            URL(fileURLWithPath: "/tmp/project", isDirectory: true)
        )
        XCTAssertNil(
            MarkdownExportContent(markdown: "", sourceURL: nil).sourceDirectoryURL
        )
    }

    func testPreviewRendererKeepsSourceMapByDefault() {
        let html = MarkdownHTMLRenderer().renderDocument(markdown: "# Heading")

        XCTAssertTrue(html.contains(#"data-source-start="0""#))
    }

    func testEmptyOutputHasAnEmptyBodyWhilePreviewKeepsItsPlaceholder() {
        let output = MarkdownExportContent(markdown: " \n\t", sourceURL: nil).renderedHTML()
        let preview = MarkdownHTMLRenderer().renderDocument(markdown: " \n\t")

        XCTAssertFalse(output.contains("Nothing to preview yet"))
        XCTAssertFalse(output.contains("<main"))
        XCTAssertTrue(preview.contains("Nothing to preview yet"))
    }

    func testExportHTMLIncludesLightPaginatedPrintStyles() {
        let html = MarkdownExportContent(markdown: "Text", sourceURL: nil).renderedHTML()

        XCTAssertTrue(html.contains("@page { margin:"))
        XCTAssertTrue(html.contains("color-scheme: light"))
        XCTAssertTrue(html.contains("break-after: avoid-page"))
        XCTAssertTrue(html.contains("break-inside: avoid-page"))
        XCTAssertTrue(html.contains("background: #ffffff !important"))
    }

    func testPrintReadinessWaitsForLoadErrorAndDecodeWithBoundedTimeout() {
        let script = MarkdownPrintReadiness.waitForImagesScript

        XCTAssertTrue(script.contains("image.loading = 'eager'"))
        XCTAssertTrue(script.contains("addEventListener('load'"))
        XCTAssertTrue(script.contains("addEventListener('error'"))
        XCTAssertTrue(script.contains("await image.decode()"))
        XCTAssertTrue(script.contains("document.documentElement.offsetHeight"))
        XCTAssertGreaterThan(MarkdownPrintReadiness.timeoutInterval, 0)
        XCTAssertLessThanOrEqual(MarkdownPrintReadiness.timeoutInterval, 60)
    }

    @MainActor
    func testPrintReadinessLoadsAndDecodesRelativeLocalImage() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let imageURL = directory.appendingPathComponent("pixel.gif")
        let pixelGIF = try XCTUnwrap(
            Data(base64Encoded: "R0lGODlhAQABAIAAAAAAAP///ywAAAAAAQABAAACAUwAOw==")
        )
        try pixelGIF.write(to: imageURL)

        let content = MarkdownExportContent(
            markdown: "![Pixel](pixel.gif)",
            sourceURL: directory.appendingPathComponent("Notes.md")
        )
        let rootDirectoryURL = try XCTUnwrap(content.localImageRootURL)
        let configuration = WKWebViewConfiguration()
        let preferences = WKWebpagePreferences()
        preferences.allowsContentJavaScript = false
        configuration.defaultWebpagePreferences = preferences
        let schemeHandler = MarkdownLocalImageSchemeHandler(
            rootDirectoryURL: rootDirectoryURL
        )
        configuration.setURLSchemeHandler(
            schemeHandler,
            forURLScheme: MarkdownLocalImageResource.scheme
        )

        let webView = WKWebView(
            frame: NSRect(x: 0, y: 0, width: 320, height: 240),
            configuration: configuration
        )
        let loaded = expectation(description: "Output HTML loaded")
        let navigationDelegate = ExportNavigationWaiter(expectation: loaded)
        webView.navigationDelegate = navigationDelegate
        defer {
            webView.navigationDelegate = nil
            webView.stopLoading()
        }

        webView.loadHTMLString(
            content.renderedHTML(for: .printedDocument),
            baseURL: content.printWebViewBaseURL
        )
        await fulfillment(of: [loaded], timeout: 5)

        _ = try await webView.callAsyncJavaScript(
            MarkdownPrintReadiness.waitForImagesScript,
            arguments: [:],
            in: nil,
            contentWorld: .defaultClient
        )
        let naturalWidth = try await webView.callAsyncJavaScript(
            "return document.images[0]?.naturalWidth ?? 0;",
            arguments: [:],
            in: nil,
            contentWorld: .defaultClient
        ) as? NSNumber

        XCTAssertEqual(naturalWidth?.intValue, 1)
    }

    @MainActor
    func testLocalImageSchemeRejectsTraversalSymlinkEscapesAndNonImages() throws {
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let root = container.appendingPathComponent("document", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: container) }

        let outsideImage = container.appendingPathComponent("outside.png")
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: outsideImage)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("linked.png"),
            withDestinationURL: outsideImage
        )
        try Data("not an image".utf8).write(to: root.appendingPathComponent("notes.txt"))

        let traversalURL = try XCTUnwrap(
            URL(string: "acmd-local://document/%2e%2e/outside.png")
        )
        let symlinkURL = try XCTUnwrap(
            URL(string: "acmd-local://document/linked.png")
        )
        let textURL = try XCTUnwrap(
            URL(string: "acmd-local://document/notes.txt")
        )

        XCTAssertNil(
            MarkdownLocalImageSchemeHandler.resolvedImageURL(
                for: traversalURL,
                rootDirectoryURL: root
            )
        )
        XCTAssertNil(
            MarkdownLocalImageSchemeHandler.resolvedImageURL(
                for: symlinkURL,
                rootDirectoryURL: root
            )
        )
        XCTAssertNil(
            MarkdownLocalImageSchemeHandler.resolvedImageURL(
                for: textURL,
                rootDirectoryURL: root
            )
        )
    }

    func testAtomicHTMLWriteUsesUTF8Output() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("Café.html")
        let content = MarkdownExportContent(markdown: "# Café 日本語", sourceURL: nil)

        try content.writeHTMLAtomically(to: destination)

        let data = try Data(contentsOf: destination)
        XCTAssertEqual(String(data: data, encoding: .utf8), content.renderedHTML())
    }

    func testHTMLWriteEmbedsRelativeImagesWhenExportedElsewhere() throws {
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let sourceDirectory = container.appendingPathComponent("source", isDirectory: true)
        let assetDirectory = sourceDirectory.appendingPathComponent("assets", isDirectory: true)
        let exportDirectory = container.appendingPathComponent("exports", isDirectory: true)
        try FileManager.default.createDirectory(
            at: assetDirectory,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: exportDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: container) }

        let pixelGIF = try XCTUnwrap(
            Data(base64Encoded: "R0lGODlhAQABAIAAAAAAAP///ywAAAAAAQABAAACAUwAOw==")
        )
        try pixelGIF.write(to: assetDirectory.appendingPathComponent("pixel.gif"))
        let content = MarkdownExportContent(
            markdown: "![Pixel](assets/pixel.gif)",
            sourceURL: sourceDirectory.appendingPathComponent("Notes.md")
        )
        let destination = exportDirectory.appendingPathComponent("Notes.html")

        try content.writeHTMLAtomically(to: destination)

        let html = try String(contentsOf: destination, encoding: .utf8)
        XCTAssertTrue(html.contains(#"src="data:image/gif;base64,"#))
        XCTAssertFalse(html.contains(#"src="assets/pixel.gif""#))
        XCTAssertFalse(html.contains(sourceDirectory.path))
    }
}

@MainActor
private final class ExportNavigationWaiter: NSObject, WKNavigationDelegate {
    private let expectation: XCTestExpectation

    init(expectation: XCTestExpectation) {
        self.expectation = expectation
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        expectation.fulfill()
    }
}
