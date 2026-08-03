import AppKit
import SwiftUI
import WebKit

public struct MarkdownPreviewView: View {
    public static let accessibilityIdentifier = "markdownPreview"

    private let input: PreviewSnapshot
    @State private var displayedSnapshot: PreviewSnapshot

    public init(markdown: String, documentURL: URL? = nil) {
        let snapshot = PreviewSnapshot(markdown: markdown, documentURL: documentURL)
        self.input = snapshot
        self._displayedSnapshot = State(initialValue: snapshot)
    }

    public var body: some View {
        MarkdownWebView(snapshot: displayedSnapshot)
            .accessibilityIdentifier(Self.accessibilityIdentifier)
            .task(id: input) {
                guard displayedSnapshot != input else { return }
                do {
                    try await Task.sleep(nanoseconds: 140_000_000)
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                displayedSnapshot = input
            }
    }
}

struct PreviewSnapshot: Hashable {
    let markdown: String
    let documentURL: URL?
}

private struct MarkdownWebView: NSViewRepresentable {
    let snapshot: PreviewSnapshot

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false

        let pagePreferences = WKWebpagePreferences()
        pagePreferences.allowsContentJavaScript = false
        configuration.defaultWebpagePreferences = pagePreferences

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.allowsMagnification = true
        webView.allowsBackForwardNavigationGestures = false
        webView.underPageBackgroundColor = .textBackgroundColor
        webView.setAccessibilityIdentifier(MarkdownPreviewView.accessibilityIdentifier)
        webView.setAccessibilityLabel("Markdown preview")
        context.coordinator.webView = webView
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.display(snapshot, in: webView)
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.navigationDelegate = nil
        webView.stopLoading()
        coordinator.webView = nil
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        weak var webView: WKWebView?

        private var lastSnapshot: PreviewSnapshot?
        private var requestedSnapshot: PreviewSnapshot?
        private var pendingScrollOrigin: NSPoint?
        private var activeBaseURL: URL?

        func display(_ snapshot: PreviewSnapshot, in webView: WKWebView) {
            guard snapshot != requestedSnapshot else { return }
            requestedSnapshot = snapshot
            let renderer = MarkdownHTMLRenderer()
            let baseURL = MarkdownHTMLRenderer.baseURL(for: snapshot.documentURL)

            DispatchQueue.global(qos: .userInitiated).async { [weak self, weak webView] in
                let html = renderer.renderDocument(
                    markdown: snapshot.markdown,
                    documentURL: snapshot.documentURL
                )
                DispatchQueue.main.async {
                    guard let self,
                          let webView,
                          self.requestedSnapshot == snapshot else { return }

                    if self.lastSnapshot != nil,
                       let scrollView = webView.markdownScrollView {
                        self.pendingScrollOrigin = scrollView.contentView.bounds.origin
                    }
                    self.lastSnapshot = snapshot
                    self.activeBaseURL = baseURL
                    webView.loadHTMLString(html, baseURL: baseURL)
                }
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard let origin = pendingScrollOrigin else { return }
            pendingScrollOrigin = nil

            DispatchQueue.main.async { [weak webView] in
                guard let webView, let scrollView = webView.markdownScrollView else { return }
                let clipView = scrollView.contentView
                let proposed = NSRect(origin: origin, size: clipView.bounds.size)
                let constrained = clipView.constrainBoundsRect(proposed).origin
                clipView.scroll(to: constrained)
                scrollView.reflectScrolledClipView(clipView)
            }
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            guard navigationAction.navigationType == .linkActivated else {
                decisionHandler(.allow)
                return
            }

            guard let url = navigationAction.request.url else {
                decisionHandler(.cancel)
                return
            }

            if isSameDocumentFragment(url, webView: webView) {
                decisionHandler(.allow)
                return
            }

            decisionHandler(.cancel)
            guard isAllowedExternalDestination(url) else { return }
            NSWorkspace.shared.open(url)
        }

        private func isSameDocumentFragment(_ url: URL, webView: WKWebView) -> Bool {
            guard url.fragment != nil else { return false }
            let destination = removingFragment(from: url)
            if let current = webView.url.map(removingFragment), destination == current {
                return true
            }
            if let activeBaseURL, destination == removingFragment(from: activeBaseURL) {
                return true
            }
            return false
        }

        private func removingFragment(from url: URL) -> URL {
            guard var components = URLComponents(url: url, resolvingAgainstBaseURL: true) else {
                return url
            }
            components.fragment = nil
            return components.url ?? url
        }

        private func isAllowedExternalDestination(_ url: URL) -> Bool {
            if url.isFileURL { return true }
            switch url.scheme?.lowercased() {
            case "http", "https", "mailto": return true
            default: return false
            }
        }
    }
}

private extension NSView {
    var markdownScrollView: NSScrollView? {
        if let scrollView = self as? NSScrollView { return scrollView }
        for subview in subviews {
            if let scrollView = subview.markdownScrollView { return scrollView }
        }
        return nil
    }
}
