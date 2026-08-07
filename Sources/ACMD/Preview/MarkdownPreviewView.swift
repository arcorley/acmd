import AppKit
import Combine
import SwiftUI
import WebKit

public struct MarkdownPreviewView: View {
    public static let accessibilityIdentifier = "markdownPreview"

    private let input: PreviewSnapshot
    private let scrollSynchronizer: MarkdownScrollSynchronizer?
    private let findSession: MarkdownFindSession?
    @State private var displayedSnapshot: PreviewSnapshot

    public init(markdown: String, documentURL: URL? = nil) {
        let snapshot = PreviewSnapshot(markdown: markdown, documentURL: documentURL)
        self.input = snapshot
        self.scrollSynchronizer = nil
        self.findSession = nil
        self._displayedSnapshot = State(initialValue: snapshot)
    }

    init(
        markdown: String,
        documentURL: URL? = nil,
        scrollSynchronizer: MarkdownScrollSynchronizer,
        findSession: MarkdownFindSession? = nil
    ) {
        let snapshot = PreviewSnapshot(markdown: markdown, documentURL: documentURL)
        self.input = snapshot
        self.scrollSynchronizer = scrollSynchronizer
        self.findSession = findSession
        self._displayedSnapshot = State(initialValue: snapshot)
    }

    public var body: some View {
        MarkdownWebView(
            snapshot: displayedSnapshot,
            scrollSynchronizer: scrollSynchronizer,
            findSession: findSession
        )
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
    private static let scrollMessageName = "acmdPreviewScroll"
    private static let scrollObserverScript = #"""
    (() => {
      if (window.__acmdScrollObserverInstalled) return;
      window.__acmdScrollObserverInstalled = true;

      let scheduled = false;
      const root = () => document.scrollingElement || document.documentElement;
      const sourceAnchors = () => {
        const scrollingRoot = root();
        const maximum = Math.max(scrollingRoot.scrollHeight - window.innerHeight, 0);
        const elements = Array.from(document.querySelectorAll('[data-source-start]'));
        const lineCount = Number(
          document.querySelector('.markdown-body')?.dataset.sourceLineCount || 1
        );
        const finalLine = Math.max(0, lineCount - 1);
        const absoluteTop = element => element.getBoundingClientRect().top + scrollingRoot.scrollTop;
        const firstTop = elements.length === 0 ? 0 : absoluteTop(elements[0]);
        const candidates = [{ line: 0, y: 0 }, { line: finalLine, y: maximum }];

        for (const element of elements) {
          const startLine = Number(element.dataset.sourceStart);
          const endLine = Number(element.dataset.sourceEnd ?? element.dataset.sourceStart);
          if (!Number.isFinite(startLine)) continue;

          const rect = element.getBoundingClientRect();
          const top = Math.min(maximum, Math.max(0, absoluteTop(element) - firstTop));
          const bottom = Math.min(
            maximum,
            Math.max(top, rect.bottom + scrollingRoot.scrollTop - firstTop)
          );
          candidates.push({ line: startLine, y: top });
          if (Number.isFinite(endLine) && endLine >= startLine) {
            candidates.push({ line: endLine, y: bottom });
          }
        }

        // Parent list rectangles contain their descendants, so DOM order is
        // not geometric order. Sorting all start/end edges by rendered Y keeps
        // precise nested-item anchors from being hidden by their container.
        candidates.sort((left, right) => left.y - right.y || left.line - right.line);

        const points = [];
        for (const candidate of candidates) {
          const line = Math.min(finalLine, Math.max(0, candidate.line));
          const y = Math.min(maximum, Math.max(0, candidate.y));
          const previous = points[points.length - 1];
          if (previous && (line < previous.line || y < previous.y)) continue;
          if (previous && line === previous.line && y === previous.y) continue;
          points.push({ line, y });
        }
        return points;
      };
      const interpolate = (value, points, inputKey, outputKey) => {
        if (points.length === 0 || value <= points[0][inputKey]) {
          return points.length === 0 ? 0 : points[0][outputKey];
        }
        for (let index = 1; index < points.length; index += 1) {
          const previous = points[index - 1];
          const next = points[index];
          if (value <= next[inputKey]) {
            const span = next[inputKey] - previous[inputKey];
            if (span <= 0) return next[outputKey];
            const fraction = (value - previous[inputKey]) / span;
            return previous[outputKey] + fraction * (next[outputKey] - previous[outputKey]);
          }
        }
        return points[points.length - 1][outputKey];
      };
      const report = () => {
        const scrollingRoot = root();
        const maximum = Math.max(scrollingRoot.scrollHeight - window.innerHeight, 0);
        const points = sourceAnchors();
        const sourceLine = interpolate(scrollingRoot.scrollTop, points, 'y', 'line');
        const progress = maximum > 0 ? scrollingRoot.scrollTop / maximum : 0;
        window.webkit.messageHandlers.acmdPreviewScroll.postMessage({ sourceLine, progress });
      };
      const scheduleReport = () => {
        if (scheduled) return;
        scheduled = true;
        window.requestAnimationFrame(() => {
          scheduled = false;
          report();
        });
      };

      window.addEventListener('scroll', scheduleReport, { passive: true });
      window.addEventListener('resize', scheduleReport, { passive: true });
      window.__acmdSourceScroll = {
        scrollToSourceLine(sourceLine) {
          const points = sourceAnchors();
          root().scrollTop = interpolate(sourceLine, points, 'line', 'y');
        },
        scrollToProgress(progress) {
          const scrollingRoot = root();
          const maximum = Math.max(scrollingRoot.scrollHeight - window.innerHeight, 0);
          scrollingRoot.scrollTop = Math.min(1, Math.max(0, progress)) * maximum;
        }
      };
      report();
    })();
    """#

    let snapshot: PreviewSnapshot
    let scrollSynchronizer: MarkdownScrollSynchronizer?
    let findSession: MarkdownFindSession?

    func makeCoordinator() -> Coordinator {
        Coordinator(scrollSynchronizer: scrollSynchronizer)
    }

    func makeNSView(context: Context) -> PreviewFindContainer {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.userContentController.add(
            context.coordinator,
            name: Self.scrollMessageName
        )
        configuration.userContentController.addUserScript(
            WKUserScript(
                source: Self.scrollObserverScript,
                injectionTime: .atDocumentEnd,
                forMainFrameOnly: true
            )
        )

        let pagePreferences = WKWebpagePreferences()
        pagePreferences.allowsContentJavaScript = false
        configuration.defaultWebpagePreferences = pagePreferences

        let webView = PreviewWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.allowsMagnification = true
        webView.allowsBackForwardNavigationGestures = false
        webView.underPageBackgroundColor = .textBackgroundColor
        webView.setAccessibilityIdentifier(MarkdownPreviewView.accessibilityIdentifier)
        webView.setAccessibilityLabel("Markdown preview")

        let container = PreviewFindContainer(webView: webView, findSession: findSession)
        container.setAccessibilityIdentifier(MarkdownPreviewView.accessibilityIdentifier)
        container.setAccessibilityLabel("Markdown preview")
        context.coordinator.container = container
        context.coordinator.webView = webView
        context.coordinator.attachScrollBridge()
        return container
    }

    func updateNSView(_ container: PreviewFindContainer, context: Context) {
        context.coordinator.container = container
        context.coordinator.webView = container.webView
        context.coordinator.attachScrollBridge()
        context.coordinator.display(snapshot, in: container)
    }

    static func dismantleNSView(_ container: PreviewFindContainer, coordinator: Coordinator) {
        coordinator.detachScrollBridge()
        let webView = container.webView
        webView.configuration.userContentController.removeScriptMessageHandler(
            forName: Self.scrollMessageName
        )
        webView.navigationDelegate = nil
        webView.stopLoading()
        container.invalidateTextFinder()
        coordinator.container = nil
        coordinator.webView = nil
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        weak var container: PreviewFindContainer?
        weak var webView: WKWebView?
        private weak var scrollSynchronizer: MarkdownScrollSynchronizer?

        private var lastSnapshot: PreviewSnapshot?
        private var requestedSnapshot: PreviewSnapshot?
        private var currentPreviewProgress: CGFloat = 0
        private var pendingScrollProgress: CGFloat?
        private var activeBaseURL: URL?

        init(scrollSynchronizer: MarkdownScrollSynchronizer?) {
            self.scrollSynchronizer = scrollSynchronizer
        }

        func attachScrollBridge() {
            guard let webView else { return }
            scrollSynchronizer?.attachPreview { [weak webView] sourceLine in
                guard let webView else { return }
                Self.scroll(webView, toSourceLine: sourceLine)
            }
        }

        func detachScrollBridge() {
            scrollSynchronizer?.detachPreview()
        }

        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            guard message.name == MarkdownWebView.scrollMessageName,
                  let body = message.body as? [String: Any],
                  let sourceLineNumber = body["sourceLine"] as? NSNumber,
                  let progressNumber = body["progress"] as? NSNumber else { return }
            let sourceLine = max(CGFloat(truncating: sourceLineNumber), 0)
            let progress = min(max(CGFloat(truncating: progressNumber), 0), 1)
            currentPreviewProgress = progress
            scrollSynchronizer?.previewDidScroll(toSourceLine: sourceLine)
        }

        private static func scroll(_ webView: WKWebView, toSourceLine sourceLine: CGFloat) {
            let clampedSourceLine = max(sourceLine, 0)
            let script = """
            window.__acmdSourceScroll?.scrollToSourceLine(\(clampedSourceLine));
            """
            webView.evaluateJavaScript(script)
        }

        private static func scroll(_ webView: WKWebView, toProgress progress: CGFloat) {
            let clampedProgress = min(max(progress, 0), 1)
            webView.evaluateJavaScript(
                "window.__acmdSourceScroll?.scrollToProgress(\(clampedProgress));"
            )
        }

        func display(_ snapshot: PreviewSnapshot, in container: PreviewFindContainer) {
            guard snapshot != requestedSnapshot else { return }
            requestedSnapshot = snapshot
            let webView = container.webView
            let renderer = MarkdownHTMLRenderer()
            let baseURL = MarkdownHTMLRenderer.baseURL(for: snapshot.documentURL)

            DispatchQueue.global(qos: .userInitiated).async { [weak self, weak container, weak webView] in
                let html = renderer.renderDocument(
                    markdown: snapshot.markdown,
                    documentURL: snapshot.documentURL
                )
                DispatchQueue.main.async {
                    guard let self,
                          let container,
                          let webView,
                          self.requestedSnapshot == snapshot else { return }

                    if self.lastSnapshot != nil {
                        self.pendingScrollProgress = self.currentPreviewProgress
                    }
                    self.lastSnapshot = snapshot
                    self.activeBaseURL = baseURL
                    container.noteSearchableContentWillChange()
                    self.scrollSynchronizer?.beginSuspending(.preview)
                    webView.loadHTMLString(html, baseURL: baseURL)
                }
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            attachScrollBridge()
            let pendingProgress = pendingScrollProgress
            pendingScrollProgress = nil

            DispatchQueue.main.async { [weak self, weak container, weak webView] in
                guard let self else { return }
                self.scrollSynchronizer?.endSuspending(.preview)
                if self.scrollSynchronizer?.isEnabled == true {
                    self.scrollSynchronizer?.synchronize(from: .editor)
                } else if let pendingProgress, let webView {
                    Self.scroll(webView, toProgress: pendingProgress)
                }

                // Restore/synchronize first. A successful asynchronous find
                // can then reveal its match, while a miss keeps this position.
                container?.restoreActiveFindAfterContentLoad()
            }
        }

        func webView(
            _ webView: WKWebView,
            didFail navigation: WKNavigation!,
            withError error: Error
        ) {
            resumeSynchronizationAfterFailedLoad()
        }

        func webView(
            _ webView: WKWebView,
            didFailProvisionalNavigation navigation: WKNavigation!,
            withError error: Error
        ) {
            resumeSynchronizationAfterFailedLoad()
        }

        private func resumeSynchronizationAfterFailedLoad() {
            scrollSynchronizer?.endSuspending(.preview)
            scrollSynchronizer?.synchronize(from: .editor)
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

/// Hosts WebKit's rendered document and a native AppKit find bar. WebKit's
/// public find API searches rendered text without enabling page JavaScript.
@MainActor
final class PreviewFindContainer: NSView, NSSearchFieldDelegate, NSUserInterfaceValidations {
    static let searchFieldAccessibilityIdentifier = "preview-find-field"

    let webView: WKWebView
    private let findSession: MarkdownFindSession?

    private let findBar = NSVisualEffectView()
    private let searchField = PreviewSearchField()
    private let statusLabel = NSTextField(labelWithString: "")
    private let previousButton = NSButton()
    private let nextButton = NSButton()
    private let doneButton = NSButton()
    private let findBarHeight: CGFloat = 40
    private var searchGeneration = 0
    private var isSearchValid = true
    private var findSessionCancellable: AnyCancellable?

    private(set) var isFindBarVisible = false
    private(set) var hasRecentInteraction = false
    private(set) var isFindHighlightActive = false
    private(set) var searchRequestCount = 0
    var findBarView: NSView { findBar }
    var contentView: NSView { webView }
    var searchFieldView: NSSearchField { searchField }

    init(webView: WKWebView, findSession: MarkdownFindSession? = nil) {
        self.webView = webView
        self.findSession = findSession
        super.init(frame: webView.frame)

        addSubview(webView)
        configureFindBar()
        (webView as? PreviewWebView)?.findActionTarget = self
        observeFindSession()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let result = super.hitTest(point)
        if let result,
           (result === webView || result.isDescendant(of: webView)),
           let event = NSApp.currentEvent,
           [.leftMouseDown, .rightMouseDown, .otherMouseDown].contains(event.type) {
            hasRecentInteraction = true
            // WebKit can leave the source NSTextView as first responder after
            // a blank-area click. Move focus after WebKit handles this event.
            DispatchQueue.main.async { [weak self] in
                guard let self, let window = self.window else { return }
                window.makeFirstResponder(self.webView)
            }
        }
        return result
    }

    override func layout() {
        super.layout()

        let barHeight = isFindBarVisible ? min(findBarHeight, bounds.height) : 0
        findBar.frame = NSRect(
            x: bounds.minX,
            y: bounds.maxY - barHeight,
            width: bounds.width,
            height: barHeight
        )
        webView.frame = NSRect(
            x: bounds.minX,
            y: bounds.minY,
            width: bounds.width,
            height: max(0, bounds.height - barHeight)
        )
    }

    override func performTextFinderAction(_ sender: Any?) {
        guard let action = findAction(from: sender) else {
            super.performTextFinderAction(sender)
            return
        }

        switch action {
        case .showFindInterface:
            showFind()
        case .nextMatch:
            findNext()
        case .previousMatch:
            findPrevious()
        case .hideFindInterface:
            closeFind()
        default:
            super.performTextFinderAction(sender)
        }
    }

    func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        guard item.action == #selector(NSResponder.performTextFinderAction(_:)),
              let action = NSTextFinder.Action(rawValue: item.tag) else {
            return false
        }
        switch action {
        case .showFindInterface, .hideFindInterface:
            return true
        case .nextMatch, .previousMatch:
            return !searchField.stringValue.isEmpty
        default:
            return false
        }
    }

    func controlTextDidChange(_ notification: Notification) {
        guard notification.object as? NSSearchField === searchField else { return }
        storeSharedQuery()
        findSession?.update(query: searchField.stringValue, source: .preview)
        performSearch(backwards: false)
    }

    func control(
        _ control: NSControl,
        textView: NSTextView,
        doCommandBy commandSelector: Selector
    ) -> Bool {
        guard control === searchField,
              commandSelector == #selector(NSResponder.cancelOperation(_:)) else {
            return false
        }
        closeFind()
        return true
    }

    func showFind() {
        guard isSearchValid else { return }
        hasRecentInteraction = true
        if isFindBarVisible {
            let needsSearchRefresh = findSession.map {
                !$0.state.active
                    || $0.state.source != .preview
                    || $0.state.query != searchField.stringValue
            } ?? false
            findSession?.activate(source: .preview, query: searchField.stringValue)
            if needsSearchRefresh {
                performSearch(backwards: false)
            }
            window?.makeFirstResponder(searchField)
            searchField.selectText(nil)
            return
        }
        if searchField.stringValue.isEmpty,
           let sessionQuery = findSession?.state.query,
           !sessionQuery.isEmpty {
            searchField.stringValue = sessionQuery
        }
        if searchField.stringValue.isEmpty,
           let sharedQuery = NSPasteboard(name: .find).string(forType: .string) {
            searchField.stringValue = sharedQuery
        }
        isFindBarVisible = true
        findBar.isHidden = false
        needsLayout = true
        layoutSubtreeIfNeeded()
        window?.makeFirstResponder(searchField)
        findSession?.activate(source: .preview, query: searchField.stringValue)
        performSearch(backwards: false)
    }

    func findNext() {
        guard !searchField.stringValue.isEmpty else {
            showFind()
            return
        }
        findSession?.navigate(.next, source: .preview)
        performSearch(backwards: false)
    }

    func findPrevious() {
        guard !searchField.stringValue.isEmpty else {
            showFind()
            return
        }
        findSession?.navigate(.previous, source: .preview)
        performSearch(backwards: true)
    }

    func closeFind() {
        guard isFindBarVisible else { return }
        let activeSessionState = findSession?.state
        let editorOwnsActiveSearch = activeSessionState?.active == true
            && activeSessionState?.source == .editor
        if !editorOwnsActiveSearch {
            searchGeneration += 1
        }
        findSession?.deactivate(source: .preview)
        if !editorOwnsActiveSearch {
            setFindHighlightActive(false)
        }
        isFindBarVisible = false
        findBar.isHidden = true
        statusLabel.stringValue = ""
        needsLayout = true
        window?.makeFirstResponder(webView)
    }

    func noteInteraction() {
        hasRecentInteraction = true
    }

    func markInteractionInactive() {
        hasRecentInteraction = false
    }

    func noteSearchableContentWillChange() {
        guard isSearchValid else { return }
        searchGeneration += 1
        setFindHighlightActive(false)
        statusLabel.stringValue = ""
    }

    /// Re-runs the active query after WebKit replaces the rendered document.
    @discardableResult
    func restoreActiveFindAfterContentLoad() -> Bool {
        guard isSearchValid else { return false }
        if isFindBarVisible, !searchField.stringValue.isEmpty {
            performSearch(backwards: false)
            return true
        }
        guard let state = findSession?.state,
              state.active,
              state.source == .editor,
              !state.query.isEmpty else { return false }
        performMirroredSearch(query: state.query, backwards: false)
        return true
    }

    func invalidateTextFinder() {
        guard isSearchValid else { return }
        setFindHighlightActive(false)
        isSearchValid = false
        searchGeneration += 1
        findSessionCancellable?.cancel()
        findSessionCancellable = nil
        searchField.delegate = nil
        searchField.onCancel = nil
        (webView as? PreviewWebView)?.findActionTarget = nil
    }

    private func configureFindBar() {
        findBar.material = .headerView
        findBar.blendingMode = .withinWindow
        findBar.state = .active
        findBar.isHidden = true

        searchField.placeholderString = "Find"
        searchField.delegate = self
        searchField.target = self
        searchField.action = #selector(findNextFromControl(_:))
        searchField.setAccessibilityIdentifier(Self.searchFieldAccessibilityIdentifier)
        searchField.setAccessibilityLabel("Find in rendered preview")
        searchField.onCancel = { [weak self] in
            self?.closeFind()
        }

        statusLabel.textColor = .secondaryLabelColor
        statusLabel.alignment = .right
        statusLabel.setContentHuggingPriority(.required, for: .horizontal)

        configureNavigationButton(
            previousButton,
            symbolName: "chevron.up",
            label: "Find Previous",
            action: #selector(findPreviousFromControl(_:))
        )
        configureNavigationButton(
            nextButton,
            symbolName: "chevron.down",
            label: "Find Next",
            action: #selector(findNextFromControl(_:))
        )

        doneButton.title = "Done"
        doneButton.bezelStyle = .inline
        doneButton.target = self
        doneButton.action = #selector(closeFindFromControl(_:))
        doneButton.setAccessibilityLabel("Close Find")

        let stack = NSStackView(views: [
            searchField,
            statusLabel,
            previousButton,
            nextButton,
            doneButton
        ])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 5, left: 8, bottom: 5, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false
        findBar.addSubview(stack)
        addSubview(findBar, positioned: .above, relativeTo: webView)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: findBar.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: findBar.trailingAnchor),
            stack.topAnchor.constraint(equalTo: findBar.topAnchor),
            stack.bottomAnchor.constraint(equalTo: findBar.bottomAnchor),
            searchField.widthAnchor.constraint(greaterThanOrEqualToConstant: 150)
        ])
    }

    private func configureNavigationButton(
        _ button: NSButton,
        symbolName: String,
        label: String,
        action: Selector
    ) {
        button.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: label)
        button.bezelStyle = .inline
        button.target = self
        button.action = action
        button.toolTip = label
        button.setAccessibilityLabel(label)
    }

    private func observeFindSession() {
        findSessionCancellable = findSession?.$state.sink { [weak self] state in
            guard state.source == .editor else { return }
            self?.applyMirroredFindState(state)
        }
    }

    private func applyMirroredFindState(_ state: MarkdownFindSession.State) {
        guard isSearchValid else { return }
        guard state.active, !state.query.isEmpty else {
            searchGeneration += 1
            setFindHighlightActive(false)
            return
        }

        performMirroredSearch(
            query: state.query,
            backwards: state.action == .previous
        )
    }

    private func performSearch(backwards: Bool) {
        performSearch(
            query: searchField.stringValue,
            backwards: backwards,
            updatesFindBar: true
        )
    }

    private func performMirroredSearch(query: String, backwards: Bool) {
        performSearch(query: query, backwards: backwards, updatesFindBar: false)
    }

    private func performSearch(
        query: String,
        backwards: Bool,
        updatesFindBar: Bool
    ) {
        guard isSearchValid else { return }
        searchGeneration += 1
        let generation = searchGeneration

        guard !query.isEmpty else {
            setFindHighlightActive(false)
            if updatesFindBar {
                statusLabel.stringValue = ""
                previousButton.isEnabled = false
                nextButton.isEnabled = false
            }
            return
        }

        if updatesFindBar {
            previousButton.isEnabled = true
            nextButton.isEnabled = true
            statusLabel.stringValue = ""
        }
        searchRequestCount += 1

        setFindHighlightActive(true) { [weak self] in
            guard let self,
                  self.isSearchValid,
                  self.searchGeneration == generation else { return }

            let configuration = WKFindConfiguration()
            configuration.backwards = backwards
            configuration.caseSensitive = false
            configuration.wraps = true
            self.webView.find(query, configuration: configuration) { [weak self] result in
                guard let self,
                      self.isSearchValid,
                      self.searchGeneration == generation else { return }
                if updatesFindBar {
                    self.statusLabel.stringValue = result.matchFound ? "" : "Not Found"
                }
                if !result.matchFound {
                    self.setFindHighlightActive(false)
                }
            }
        }
    }

    private func setFindHighlightActive(
        _ active: Bool,
        completion: (() -> Void)? = nil
    ) {
        isFindHighlightActive = active
        let script = """
        document.documentElement?.classList.toggle('acmd-find-active', \(active));
        if (!\(active)) {
          window.getSelection()?.removeAllRanges();
        }
        """
        webView.evaluateJavaScript(script) { _, _ in
            completion?()
        }
    }

    private func storeSharedQuery() {
        let query = searchField.stringValue
        guard !query.isEmpty else { return }
        let pasteboard = NSPasteboard(name: .find)
        pasteboard.clearContents()
        pasteboard.setString(query, forType: .string)
    }

    private func findAction(from sender: Any?) -> NSTextFinder.Action? {
        guard let item = sender as? NSValidatedUserInterfaceItem else { return nil }
        return NSTextFinder.Action(rawValue: item.tag)
    }

    @objc private func findNextFromControl(_ sender: Any?) {
        findNext()
    }

    @objc private func findPreviousFromControl(_ sender: Any?) {
        findPrevious()
    }

    @objc private func closeFindFromControl(_ sender: Any?) {
        closeFind()
    }
}

@MainActor
private final class PreviewSearchField: NSSearchField {
    var onCancel: (() -> Void)?

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}

@MainActor
final class PreviewWebView: WKWebView {
    weak var findActionTarget: PreviewFindContainer?

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted {
            findActionTarget?.noteInteraction()
        }
        return accepted
    }

    override func performTextFinderAction(_ sender: Any?) {
        findActionTarget?.performTextFinderAction(sender)
    }
}
