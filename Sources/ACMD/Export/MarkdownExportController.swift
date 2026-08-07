import AppKit
import Combine
import Foundation
import UniformTypeIdentifiers
import WebKit

enum MarkdownLocalImageResource {
    static let scheme = "acmd-local"
    static let host = "document"
    static let baseURL = URL(string: "\(scheme)://\(host)/")!

    static func rootDirectory(for sourceURL: URL?) -> URL? {
        guard let sourceURL,
              sourceURL.isFileURL,
              !sourceURL.hasDirectoryPath else { return nil }
        let directory = sourceURL.deletingLastPathComponent()
            .standardizedFileURL
            .resolvingSymlinksInPath()
        // Never turn the custom image loader into a read gateway for the
        // entire filesystem, even for an unusual document saved at `/`.
        guard directory.path != "/" else { return nil }
        return directory
    }
}

/// Serves print-only local images from a document's directory without granting
/// WebKit broad file-URL access. Requests cannot traverse or symlink out of the
/// canonical root and non-image files are rejected.
@MainActor
final class MarkdownLocalImageSchemeHandler: NSObject, WKURLSchemeHandler {
    private let rootDirectoryURL: URL
    private var activeTaskIDs: Set<ObjectIdentifier> = []

    init(rootDirectoryURL: URL) {
        self.rootDirectoryURL = rootDirectoryURL.standardizedFileURL.resolvingSymlinksInPath()
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let requestURL = urlSchemeTask.request.url,
              let imageURL = Self.resolvedImageURL(
                for: requestURL,
                rootDirectoryURL: rootDirectoryURL
              ),
              let mimeType = Self.imageMIMEType(for: imageURL) else {
            urlSchemeTask.didFailWithError(Self.resourceError())
            return
        }

        let identifier = ObjectIdentifier(urlSchemeTask)
        activeTaskIDs.insert(identifier)
        let readTask = Task.detached(priority: .userInitiated) {
            try? Data(contentsOf: imageURL, options: .mappedIfSafe)
        }

        Task { @MainActor [weak self] in
            let data = await readTask.value
            guard let self,
                  self.activeTaskIDs.contains(identifier) else { return }
            guard let data else {
                urlSchemeTask.didFailWithError(Self.resourceError())
                self.activeTaskIDs.remove(identifier)
                return
            }

            let response = URLResponse(
                url: requestURL,
                mimeType: mimeType,
                expectedContentLength: data.count,
                textEncodingName: nil
            )
            urlSchemeTask.didReceive(response)
            guard self.activeTaskIDs.contains(identifier) else { return }
            urlSchemeTask.didReceive(data)
            guard self.activeTaskIDs.contains(identifier) else { return }
            urlSchemeTask.didFinish()
            self.activeTaskIDs.remove(identifier)
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        activeTaskIDs.remove(ObjectIdentifier(urlSchemeTask))
    }

    static func resolvedImageURL(for requestURL: URL, rootDirectoryURL: URL) -> URL? {
        guard requestURL.scheme?.lowercased() == MarkdownLocalImageResource.scheme,
              requestURL.host?.lowercased() == MarkdownLocalImageResource.host,
              requestURL.user == nil,
              requestURL.password == nil,
              requestURL.port == nil else { return nil }

        let decodedPath = requestURL.path(percentEncoded: false)
        let relativePath = decodedPath.drop(while: { $0 == "/" })
        guard !relativePath.isEmpty else { return nil }

        let root = rootDirectoryURL.standardizedFileURL.resolvingSymlinksInPath()
        guard root.path != "/" else { return nil }
        let candidate = root
            .appendingPathComponent(String(relativePath), isDirectory: false)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        guard candidate.pathComponents.starts(with: root.pathComponents),
              (try? candidate.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
              imageMIMEType(for: candidate) != nil else { return nil }
        return candidate
    }

    private static func imageMIMEType(for url: URL) -> String? {
        guard let type = UTType(filenameExtension: url.pathExtension),
              type.conforms(to: .image) else { return nil }
        return type.preferredMIMEType ?? "application/octet-stream"
    }

    private static func resourceError() -> NSError {
        NSError(
            domain: "ACMD.MarkdownLocalImage",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "The local image could not be loaded."]
        )
    }
}

/// An immutable snapshot of a document used for export and printing.
///
/// Capturing the source text and URL up front keeps output operations separate
/// from `FileDocument` state: exporting never changes the document's URL or
/// edited status.
struct MarkdownExportContent: Equatable, Sendable {
    enum RenderTarget: Sendable {
        case htmlExport
        case printedDocument
    }

    let markdown: String
    let sourceURL: URL?

    var suggestedBaseName: String {
        Self.suggestedBaseName(for: sourceURL)
    }

    var sourceDirectoryURL: URL? {
        guard let sourceURL,
              sourceURL.isFileURL,
              !sourceURL.hasDirectoryPath else { return nil }
        return sourceURL.deletingLastPathComponent().standardizedFileURL
    }

    var localImageRootURL: URL? {
        MarkdownLocalImageResource.rootDirectory(for: sourceURL)
    }

    var printWebViewBaseURL: URL? {
        localImageRootURL == nil
            ? MarkdownHTMLRenderer.baseURL(for: sourceURL)
            : MarkdownLocalImageResource.baseURL
    }

    func renderedHTML(for target: RenderTarget = .htmlExport) -> String {
        let documentURL = target == .printedDocument ? sourceURL : nil
        let baseURLOverride = target == .printedDocument && localImageRootURL != nil
            ? MarkdownLocalImageResource.baseURL
            : nil
        // The renderer's output mode historically rewrites image-loading text
        // across the complete HTML string. Render nonempty content without that
        // global rewrite, then update only actual generated image elements so
        // code samples containing loading="lazy" remain byte-for-byte intact.
        let renderingMode: MarkdownHTMLRenderingMode = markdown
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty ? .output : .preview
        let html = MarkdownHTMLRenderer().renderDocument(
            markdown: markdown,
            documentURL: documentURL,
            title: suggestedBaseName,
            includingSourceMap: false,
            mode: renderingMode,
            baseURLOverride: baseURLOverride
        )
        return Self.preparingImagesForOutput(in: html)
    }

    func writeHTMLAtomically(to destinationURL: URL) throws {
        try Data(portableHTML().utf8).write(
            to: destinationURL,
            options: .atomic
        )
    }

    /// Makes local relative images survive exporting the HTML anywhere by
    /// embedding files that resolve safely inside the Markdown document's
    /// directory. Remote and unavailable images keep their original URLs.
    func portableHTML() -> String {
        let html = renderedHTML(for: .htmlExport)
        guard let rootDirectory = localImageRootURL else { return html }
        return Self.embeddingLocalImages(in: html, rootDirectory: rootDirectory)
    }

    static func suggestedBaseName(for sourceURL: URL?) -> String {
        guard let sourceURL, !sourceURL.hasDirectoryPath else { return "Untitled" }

        let filename = sourceURL.lastPathComponent
        guard !filename.isEmpty else { return "Untitled" }

        let basename: String
        if sourceURL.pathExtension.isEmpty {
            basename = filename
        } else {
            basename = String(filename.dropLast(sourceURL.pathExtension.count + 1))
        }
        return basename.isEmpty ? "Untitled" : basename
    }

    private static let imageSourceAttribute = try! NSRegularExpression(
        pattern: #"<img\b[^>]*\bsrc=\"([^\"]+)\""#,
        options: [.caseInsensitive]
    )
    private static let imageElement = try! NSRegularExpression(
        pattern: #"<img\b[^>]*>"#,
        options: [.caseInsensitive]
    )

    private static func preparingImagesForOutput(in html: String) -> String {
        let source = html as NSString
        let matches = imageElement.matches(
            in: html,
            range: NSRange(location: 0, length: source.length)
        )
        guard !matches.isEmpty else { return html }

        let result = NSMutableString(string: html)
        for match in matches.reversed() {
            let image = source.substring(with: match.range)
                .replacingOccurrences(of: #"loading="lazy""#, with: #"loading="eager""#)
                .replacingOccurrences(of: #"decoding="async""#, with: #"decoding="sync""#)
            result.replaceCharacters(in: match.range, with: image)
        }
        return result as String
    }

    private static func embeddingLocalImages(
        in html: String,
        rootDirectory: URL
    ) -> String {
        let source = html as NSString
        let fullRange = NSRange(location: 0, length: source.length)
        let matches = imageSourceAttribute.matches(in: html, range: fullRange)
        guard !matches.isEmpty else { return html }

        let root = rootDirectory.standardizedFileURL.resolvingSymlinksInPath()
        let result = NSMutableString(string: html)
        for match in matches.reversed() {
            let sourceRange = match.range(at: 1)
            let attribute = unescapedHTMLAttribute(source.substring(with: sourceRange))
            guard let image = embeddedImage(for: attribute, rootDirectory: root) else {
                continue
            }
            result.replaceCharacters(
                in: sourceRange,
                with: "data:\(image.mimeType);base64,\(image.data.base64EncodedString())"
            )
        }
        return result as String
    }

    private static func embeddedImage(
        for source: String,
        rootDirectory: URL
    ) -> (data: Data, mimeType: String)? {
        guard let components = URLComponents(string: source),
              components.scheme == nil,
              components.host == nil else { return nil }
        let decodedPath = components.percentEncodedPath.removingPercentEncoding
            ?? components.path
        guard !decodedPath.isEmpty, !decodedPath.hasPrefix("/") else { return nil }

        let candidate = rootDirectory
            .appendingPathComponent(decodedPath, isDirectory: false)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        guard candidate.pathComponents.starts(with: rootDirectory.pathComponents),
              (try? candidate.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
              let type = UTType(filenameExtension: candidate.pathExtension),
              type.conforms(to: .image),
              let data = try? Data(contentsOf: candidate, options: .mappedIfSafe) else {
            return nil
        }
        return (data, type.preferredMIMEType ?? "application/octet-stream")
    }

    private static func unescapedHTMLAttribute(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
    }
}

enum MarkdownExportError: LocalizedError {
    case webContentLoadFailed(Error)
    case webContentProcessTerminated
    case renderingTimedOut
    case printOperationInProgress
    case pdfCreationFailed

    var errorDescription: String? {
        switch self {
        case .webContentLoadFailed, .webContentProcessTerminated:
            return "The rendered document could not be prepared."
        case .renderingTimedOut:
            return "Preparing the rendered document took too long."
        case .printOperationInProgress:
            return "Another document is already printing."
        case .pdfCreationFailed:
            return "The PDF could not be created."
        }
    }

    var failureReason: String? {
        switch self {
        case let .webContentLoadFailed(error):
            return error.localizedDescription
        case .webContentProcessTerminated:
            return "The web content process stopped before rendering finished."
        case .renderingTimedOut:
            return "An image or the rendered page did not finish loading in time."
        case .printOperationInProgress:
            return "Wait for the current print operation to finish, then try again."
        case .pdfCreationFailed:
            return "The system print renderer did not complete the PDF operation."
        }
    }
}

enum MarkdownPrintReadiness {
    static let timeoutInterval: TimeInterval = 30

    /// Executed by the app in WebKit's isolated client world after navigation.
    /// Broken images resolve through `error`, and decode failures are ignored,
    /// so one bad image does not prevent the rest of the document from printing.
    static let waitForImagesScript = #"""
    const images = Array.from(document.images);
    await Promise.all(images.map(async image => {
      image.loading = 'eager';
      if (!image.complete) {
        await new Promise(resolve => {
          image.addEventListener('load', resolve, { once: true });
          image.addEventListener('error', resolve, { once: true });
        });
      }
      if (typeof image.decode === 'function') {
        try { await image.decode(); } catch (_) { /* broken images may print as missing */ }
      }
    }));
    void document.documentElement.offsetHeight;
    return images.length;
    """#
}

/// Own one controller per document and call it with the document's current
/// Markdown and source URL when the user chooses an output command.
@MainActor
final class MarkdownExportController: NSObject, ObservableObject {
    @Published private(set) var isPreparingOutput = false

    private var renderSessions: [UUID: MarkdownPrintRenderSession] = [:]
    private var pendingSavePanelCount = 0

    func exportHTML(
        markdown: String,
        sourceURL: URL?,
        presentingWindow: NSWindow? = nil
    ) {
        let presentingWindow = presentingWindow ?? NSApp.keyWindow
        let content = MarkdownExportContent(markdown: markdown, sourceURL: sourceURL)
        let panel = NSSavePanel()
        panel.title = "Export HTML"
        panel.prompt = "Export"
        panel.nameFieldLabel = "Export As:"
        panel.nameFieldStringValue = "\(content.suggestedBaseName).html"
        panel.allowedContentTypes = [.html]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.directoryURL = content.sourceDirectoryURL

        beginPresentingSavePanel()
        present(panel, for: presentingWindow) { [weak self, weak presentingWindow] response in
            guard response == .OK, let destinationURL = panel.url else {
                self?.endPresentingSavePanel()
                return
            }

            let writeTask = Task.detached(priority: .userInitiated) {
                try content.writeHTMLAtomically(to: destinationURL)
            }
            Task { @MainActor [weak self, weak presentingWindow] in
                do {
                    try await writeTask.value
                } catch {
                    self?.present(error: error, in: presentingWindow)
                }
                self?.endPresentingSavePanel()
            }
        }
    }

    func exportPDF(
        markdown: String,
        sourceURL: URL?,
        presentingWindow: NSWindow? = nil
    ) {
        let presentingWindow = presentingWindow ?? NSApp.keyWindow
        let content = MarkdownExportContent(markdown: markdown, sourceURL: sourceURL)
        let panel = NSSavePanel()
        panel.title = "Export PDF"
        panel.prompt = "Export"
        panel.nameFieldLabel = "Export As:"
        panel.nameFieldStringValue = "\(content.suggestedBaseName).pdf"
        panel.allowedContentTypes = [.pdf]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.directoryURL = content.sourceDirectoryURL

        beginPresentingSavePanel()
        present(panel, for: presentingWindow) { [weak self, weak presentingWindow] response in
            defer { self?.endPresentingSavePanel() }
            guard response == .OK, let destinationURL = panel.url else { return }
            self?.beginPrintRender(
                content: content,
                purpose: .pdf(destinationURL),
                presentingWindow: presentingWindow
            )
        }
    }

    func printDocument(
        markdown: String,
        sourceURL: URL?,
        presentingWindow: NSWindow? = nil
    ) {
        beginPrintRender(
            content: MarkdownExportContent(markdown: markdown, sourceURL: sourceURL),
            purpose: .print,
            presentingWindow: presentingWindow ?? NSApp.keyWindow
        )
    }

    nonisolated static func suggestedBaseName(for sourceURL: URL?) -> String {
        MarkdownExportContent.suggestedBaseName(for: sourceURL)
    }

    private func beginPrintRender(
        content: MarkdownExportContent,
        purpose: MarkdownPrintRenderSession.Purpose,
        presentingWindow: NSWindow?
    ) {
        let identifier = UUID()
        let session = MarkdownPrintRenderSession(
            content: content,
            purpose: purpose,
            presentingWindow: presentingWindow
        ) { [weak self, weak presentingWindow] error in
            guard let self else { return }
            self.renderSessions[identifier] = nil
            self.updatePreparingState()
            if let error {
                self.present(error: error, in: presentingWindow)
            }
        }
        renderSessions[identifier] = session
        updatePreparingState()
        session.start()
    }

    private func beginPresentingSavePanel() {
        pendingSavePanelCount += 1
        updatePreparingState()
    }

    private func endPresentingSavePanel() {
        pendingSavePanelCount = max(0, pendingSavePanelCount - 1)
        updatePreparingState()
    }

    private func updatePreparingState() {
        isPreparingOutput = pendingSavePanelCount > 0 || !renderSessions.isEmpty
    }

    private func present(
        _ panel: NSSavePanel,
        for window: NSWindow?,
        completion: @escaping (NSApplication.ModalResponse) -> Void
    ) {
        if let window {
            panel.beginSheetModal(for: window, completionHandler: completion)
        } else {
            completion(panel.runModal())
        }
    }

    private func present(error: Error, in window: NSWindow?) {
        let alert = NSAlert(error: error)
        if let window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }
}

@MainActor
private final class MarkdownPrintRenderSession: NSObject, WKNavigationDelegate {
    enum Purpose {
        case pdf(URL)
        case print
    }

    private let content: MarkdownExportContent
    private let purpose: Purpose
    private weak var presentingWindow: NSWindow?
    private let completion: (Error?) -> Void

    private var preparationTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var localImageSchemeHandler: MarkdownLocalImageSchemeHandler?
    private var webView: WKWebView?
    private var printOperation: NSPrintOperation?
    private var isWaitingForImages = false
    private var processTerminatedDuringPrint = false
    private var didComplete = false

    init(
        content: MarkdownExportContent,
        purpose: Purpose,
        presentingWindow: NSWindow?,
        completion: @escaping (Error?) -> Void
    ) {
        self.content = content
        self.purpose = purpose
        self.presentingWindow = presentingWindow
        self.completion = completion
    }

    func start() {
        schedulePreparationTimeout()

        let content = content
        preparationTask = Task { @MainActor [weak self] in
            let html = await Task.detached(priority: .userInitiated) {
                content.renderedHTML(for: .printedDocument)
            }.value
            guard !Task.isCancelled else { return }
            self?.load(html: html)
        }
    }

    private func load(html: String) {
        guard !didComplete else { return }

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        if let rootDirectoryURL = content.localImageRootURL {
            let handler = MarkdownLocalImageSchemeHandler(rootDirectoryURL: rootDirectoryURL)
            configuration.setURLSchemeHandler(
                handler,
                forURLScheme: MarkdownLocalImageResource.scheme
            )
            localImageSchemeHandler = handler
        }

        let pagePreferences = WKWebpagePreferences()
        pagePreferences.allowsContentJavaScript = false
        configuration.defaultWebpagePreferences = pagePreferences

        let printInfo = makePrintInfo()
        let printableWidth = max(
            printInfo.paperSize.width - printInfo.leftMargin - printInfo.rightMargin,
            320
        )
        let webView = WKWebView(
            frame: NSRect(x: 0, y: 0, width: printableWidth, height: printInfo.paperSize.height),
            configuration: configuration
        )
        webView.navigationDelegate = self
        self.webView = webView

        webView.loadHTMLString(
            html,
            baseURL: content.printWebViewBaseURL
        )
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        waitForImages(in: webView)
    }

    func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation!,
        withError error: Error
    ) {
        finish(with: MarkdownExportError.webContentLoadFailed(error))
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        finish(with: MarkdownExportError.webContentLoadFailed(error))
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        if printOperation == nil {
            finish(with: MarkdownExportError.webContentProcessTerminated)
        } else {
            processTerminatedDuringPrint = true
        }
    }

    private func waitForImages(in webView: WKWebView) {
        guard !didComplete, !isWaitingForImages else { return }
        isWaitingForImages = true

        webView.callAsyncJavaScript(
            MarkdownPrintReadiness.waitForImagesScript,
            arguments: [:],
            in: nil,
            in: .defaultClient
        ) { [weak self, weak webView] result in
            Task { @MainActor [weak self, weak webView] in
                guard let self,
                      let webView,
                      self.webView === webView,
                      !self.didComplete else { return }
                switch result {
                case .success:
                    self.runPrintOperation(for: webView)
                case let .failure(error):
                    self.finish(with: MarkdownExportError.webContentLoadFailed(error))
                }
            }
        }
    }

    private func runPrintOperation(for webView: WKWebView) {
        guard !didComplete, printOperation == nil else { return }
        cancelPreparationTimeout()

        // AppKit permits only one active NSPrintOperation per thread and may
        // otherwise raise NSPrintOperationExistsException. All output sessions
        // reach this point on MainActor, so the guard and construction are
        // serialized across document windows.
        guard NSPrintOperation.current == nil else {
            finish(with: MarkdownExportError.printOperationInProgress)
            return
        }

        let printInfo = makePrintInfo()
        switch purpose {
        case let .pdf(destinationURL):
            printInfo.jobDisposition = .save
            printInfo.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = destinationURL

            let operation = webView.printOperation(with: printInfo)
            operation.jobTitle = content.suggestedBaseName
            operation.showsPrintPanel = false
            operation.showsProgressPanel = true
            printOperation = operation
            finish(with: operation.run() ? nil : MarkdownExportError.pdfCreationFailed)

        case .print:
            let operation = webView.printOperation(with: printInfo)
            operation.jobTitle = content.suggestedBaseName
            operation.showsPrintPanel = true
            operation.showsProgressPanel = true
            printOperation = operation

            if let presentingWindow {
                operation.runModal(
                    for: presentingWindow,
                    delegate: self,
                    didRun: #selector(printOperationDidRun(_:success:contextInfo:)),
                    contextInfo: nil
                )
            } else {
                _ = operation.run()
                finish(
                    with: processTerminatedDuringPrint
                        ? MarkdownExportError.webContentProcessTerminated
                        : nil
                )
            }
        }
    }

    private func makePrintInfo() -> NSPrintInfo {
        let printInfo = (NSPrintInfo.shared.copy() as? NSPrintInfo) ?? NSPrintInfo()
        printInfo.horizontalPagination = .fit
        printInfo.verticalPagination = .automatic
        printInfo.isHorizontallyCentered = false
        printInfo.isVerticallyCentered = false
        return printInfo
    }

    private func schedulePreparationTimeout() {
        timeoutTask = Task { @MainActor [weak self] in
            let nanoseconds = UInt64(MarkdownPrintReadiness.timeoutInterval * 1_000_000_000)
            do {
                try await Task.sleep(nanoseconds: nanoseconds)
            } catch {
                return
            }
            self?.finish(with: MarkdownExportError.renderingTimedOut)
        }
    }

    private func cancelPreparationTimeout() {
        timeoutTask?.cancel()
        timeoutTask = nil
    }

    @objc private func printOperationDidRun(
        _ operation: NSPrintOperation,
        success: Bool,
        contextInfo: UnsafeMutableRawPointer?
    ) {
        // AppKit reports both cancellation and a failed print as `false` and
        // presents printer errors itself. Avoid turning Cancel into an alert.
        finish(
            with: processTerminatedDuringPrint
                ? MarkdownExportError.webContentProcessTerminated
                : nil
        )
    }

    private func finish(with error: Error?) {
        guard !didComplete else { return }
        didComplete = true
        preparationTask?.cancel()
        preparationTask = nil
        cancelPreparationTimeout()
        webView?.navigationDelegate = nil
        webView?.stopLoading()
        printOperation = nil
        webView = nil
        localImageSchemeHandler = nil
        completion(error)
    }
}
