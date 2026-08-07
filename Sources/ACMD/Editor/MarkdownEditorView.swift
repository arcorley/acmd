import AppKit
import Combine
import SwiftUI
import ACMDCore

/// A native, plain-text Markdown editor hosted in SwiftUI.
struct MarkdownEditorView: NSViewRepresentable {
    static let accessibilityIdentifier = "markdown-editor"

    @Binding private var text: String
    @ObservedObject private var controller: MarkdownEditorController
    private let isActive: Bool
    private let showsVerticalScroller: Bool
    private let scrollSynchronizer: MarkdownScrollSynchronizer?
    private let findSession: MarkdownFindSession?

    init(
        text: Binding<String>,
        controller: MarkdownEditorController,
        isActive: Bool = true,
        showsVerticalScroller: Bool = true,
        scrollSynchronizer: MarkdownScrollSynchronizer? = nil,
        findSession: MarkdownFindSession? = nil
    ) {
        _text = text
        self.controller = controller
        self.isActive = isActive
        self.showsVerticalScroller = showsVerticalScroller
        self.scrollSynchronizer = scrollSynchronizer
        self.findSession = findSession
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = MarkdownEditorScrollView()
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor
        scrollView.hasVerticalScroller = showsVerticalScroller
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true

        let textStorage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        let textContainer = NSTextContainer(
            containerSize: NSSize(
                width: max(scrollView.contentSize.width, 1),
                height: .greatestFiniteMagnitude
            )
        )
        textStorage.addLayoutManager(layoutManager)
        layoutManager.addTextContainer(textContainer)
        textContainer.widthTracksTextView = true
        textContainer.heightTracksTextView = false
        textContainer.lineFragmentPadding = 4

        let textView = MarkdownNavigationTextView(frame: .zero, textContainer: textContainer)
        configure(textView, in: scrollView)
        let baseAttributes = Self.baseAttributes(fontSize: controller.fontSize)
        textStorage.setAttributedString(
            NSAttributedString(string: text, attributes: baseAttributes)
        )
        textView.typingAttributes = baseAttributes
        textView.delegate = context.coordinator
        scrollView.documentView = textView

        context.coordinator.connect(textView, in: scrollView)
        scrollSynchronizer?.attach(scrollView, as: .editor)
        context.coordinator.highlight()
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? MarkdownTextView else { return }
        scrollView.hasVerticalScroller = showsVerticalScroller
        scrollSynchronizer?.attach(scrollView, as: .editor)
        context.coordinator.update(parent: self, textView: textView)
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        coordinator.parent.scrollSynchronizer?.detach(scrollView, from: .editor)
        coordinator.disconnect()
    }

    private func configure(_ textView: MarkdownTextView, in scrollView: NSScrollView) {
        textView.minSize = NSSize(width: 0, height: scrollView.contentSize.height)
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]

        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.isEditable = isActive
        textView.isSelectable = isActive
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true

        textView.isContinuousSpellCheckingEnabled = true
        textView.isGrammarCheckingEnabled = true
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false

        textView.drawsBackground = true
        textView.backgroundColor = .textBackgroundColor
        textView.textColor = .textColor
        textView.insertionPointColor = .textColor
        textView.font = Self.editorFont(ofSize: controller.fontSize)
        textView.textContainerInset = NSSize(width: 18, height: 16)
        textView.setAccessibilityIdentifier(Self.accessibilityIdentifier)
        textView.setAccessibilityLabel("Markdown editor")
    }

    private static func editorFont(ofSize size: CGFloat) -> NSFont {
        NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    private static func baseAttributes(fontSize: CGFloat) -> [NSAttributedString.Key: Any] {
        [
            .font: editorFont(ofSize: fontSize),
            .foregroundColor: NSColor.textColor
        ]
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate, @preconcurrency NSLayoutManagerDelegate {
        fileprivate var parent: MarkdownEditorView
        private weak var textView: MarkdownTextView?
        private weak var scrollView: NSScrollView?
        private weak var attachedController: MarkdownEditorController?
        private weak var attachedFindSession: MarkdownFindSession?
        private var isApplyingExternalText = false
        private let highlighter = MarkdownSyntaxHighlighter(
            baseFont: MarkdownEditorView.editorFont(
                ofSize: MarkdownEditorController.defaultFontSize
            )
        )
        private var highlightTask: Task<Void, Never>?
        private var lineNumberRuler: MarkdownLineNumberRulerView?
        private var appliedFontSize: CGFloat?
        private var appliedWordWrap: Bool?
        private var appliedShowsLineNumbers: Bool?
        private var findSessionCancellable: AnyCancellable?
        private var findBarPollTimer: Timer?
        private var hasObservedFindBar = false
        private var observedFindBarVisible = false
        private var observedFindBarQuery: String?
        private var activeFindQuery: String?
        private var renderedFindQuery: String?
        private var renderedFindText: String?
        private var renderedFindRanges: [NSRange] = []
        private var defaultSelectedTextAttributes: [NSAttributedString.Key: Any]?

        init(parent: MarkdownEditorView) {
            self.parent = parent
        }

        fileprivate func connect(_ textView: MarkdownTextView, in scrollView: NSScrollView) {
            self.textView = textView
            self.scrollView = scrollView
            if let editorScrollView = scrollView as? MarkdownEditorScrollView {
                editorScrollView.onViewportLayout = { [weak self, weak textView, weak scrollView] in
                    guard let self,
                          let textView,
                          let scrollView,
                          self.parent.controller.isWordWrapEnabled else { return }
                    MarkdownEditorLayout.synchronizeWrappedWidth(
                        of: textView,
                        in: scrollView
                    )
                }
            }
            defaultSelectedTextAttributes = textView.selectedTextAttributes
            textView.layoutManager?.delegate = self
            enforceActivation(on: textView)
            attachedController = parent.controller
            parent.controller.attach(to: textView)
            let lineNumberRuler = MarkdownLineNumberRulerView(
                textView: textView,
                scrollView: scrollView
            )
            self.lineNumberRuler = lineNumberRuler
            scrollView.verticalRulerView = lineNumberRuler
            applyEditorConfiguration(to: textView)
            if let editorScrollView = scrollView as? MarkdownEditorScrollView {
                DispatchQueue.main.async { [weak self, weak editorScrollView] in
                    guard self != nil else { return }
                    editorScrollView?.tile()
                }
            }
            textView.onAppearanceChange = { [weak self] in
                self?.highlight()
            }
            textView.onFindAction = { [weak self] action in
                self?.nativeFindActionWasPerformed(action)
            }
            observeFindSession()
        }

        fileprivate func update(parent: MarkdownEditorView, textView: MarkdownTextView) {
            let oldController = attachedController
            self.parent = parent
            self.textView = textView
            enforceActivation(on: textView)

            if oldController !== parent.controller {
                if let oldController {
                    oldController.detach(from: textView)
                }
                attachedController = parent.controller
            }
            parent.controller.attach(to: textView)
            applyEditorConfiguration(to: textView)

            if attachedFindSession !== parent.findSession {
                observeFindSession()
            }

            guard textView.string != parent.text else { return }

            let selection = textView.selectedRange()
            isApplyingExternalText = true
            // Native typing undo records target the current TextStorage ranges.
            // Revert/external document updates replace that storage wholesale,
            // so stale range-based actions must be discarded to avoid an
            // NSRangeException on the next Undo.
            textView.breakUndoCoalescing()
            textView.undoManager?.removeAllActions()
            if let textStorage = textView.textStorage {
                textStorage.beginEditing()
                textStorage.setAttributedString(
                    NSAttributedString(
                        string: parent.text,
                        attributes: MarkdownEditorView.baseAttributes(
                            fontSize: parent.controller.fontSize
                        )
                    )
                )
                textStorage.endEditing()
            } else {
                textView.string = parent.text
            }
            textView.typingAttributes = MarkdownEditorView.baseAttributes(
                fontSize: parent.controller.fontSize
            )
            let length = (parent.text as NSString).length
            textView.setSelectedRange(Self.clamped(selection, toUTF16Length: length))
            isApplyingExternalText = false

            lineNumberRuler?.invalidateLineNumbers(recalculateLineStarts: true)
            highlight()
            refreshFindHighlights(force: true)
            parent.controller.editorStateDidChange(textView)
        }

        private func enforceActivation(on textView: MarkdownTextView) {
            textView.isEditable = parent.isActive
            textView.isSelectable = parent.isActive

            guard !parent.isActive,
                  textView.window?.firstResponder === textView else { return }
            textView.window?.makeFirstResponder(nil)
        }

        private func applyEditorConfiguration(to textView: MarkdownTextView) {
            guard let scrollView else { return }

            let fontSize = parent.controller.fontSize
            if appliedFontSize != fontSize {
                appliedFontSize = fontSize
                let font = MarkdownEditorView.editorFont(ofSize: fontSize)
                let length = (textView.string as NSString).length
                let undoManager = textView.undoManager
                let undoRegistrationWasEnabled = undoManager?.isUndoRegistrationEnabled == true
                if undoRegistrationWasEnabled {
                    undoManager?.disableUndoRegistration()
                }
                textView.font = font
                if length > 0, let textStorage = textView.textStorage {
                    textStorage.addAttribute(
                        .font,
                        value: font,
                        range: NSRange(location: 0, length: length)
                    )
                }
                if undoRegistrationWasEnabled {
                    undoManager?.enableUndoRegistration()
                }
                textView.typingAttributes = MarkdownEditorView.baseAttributes(fontSize: fontSize)
                highlighter.update(baseFont: font)
                lineNumberRuler?.update(fontSize: fontSize)
                highlight()
            }

            let wrapsLines = parent.controller.isWordWrapEnabled
            if appliedWordWrap != wrapsLines {
                appliedWordWrap = wrapsLines
                MarkdownEditorLayout.applyWordWrap(
                    wrapsLines,
                    to: textView,
                    in: scrollView
                )
            }

            let showsLineNumbers = parent.controller.showsLineNumbers
            if appliedShowsLineNumbers != showsLineNumbers {
                appliedShowsLineNumbers = showsLineNumbers
                scrollView.hasVerticalRuler = showsLineNumbers
                scrollView.rulersVisible = showsLineNumbers
                lineNumberRuler?.invalidateLineNumbers()
            }
        }

        fileprivate func disconnect() {
            guard let textView else { return }
            highlightTask?.cancel()
            highlightTask = nil
            stopFindBarPolling()
            findSessionCancellable?.cancel()
            findSessionCancellable = nil
            attachedFindSession = nil
            activeFindQuery = nil
            refreshFindHighlights(force: true)
            if let defaultSelectedTextAttributes {
                textView.selectedTextAttributes = defaultSelectedTextAttributes
            }
            textView.onAppearanceChange = nil
            textView.onFindAction = nil
            (scrollView as? MarkdownEditorScrollView)?.onViewportLayout = nil
            scrollView?.verticalRulerView = nil
            lineNumberRuler = nil
            if textView.layoutManager?.delegate === self {
                textView.layoutManager?.delegate = nil
            }
            attachedController?.detach(from: textView)
            textView.delegate = nil
            self.textView = nil
            scrollView = nil
            attachedController = nil
            defaultSelectedTextAttributes = nil
            appliedFontSize = nil
            appliedWordWrap = nil
            appliedShowsLineNumbers = nil
        }

        func textDidBeginEditing(_ notification: Notification) {
            guard let textView = notification.object as? MarkdownTextView else { return }
            if attachedController !== parent.controller {
                attachedController?.detach(from: textView)
                attachedController = parent.controller
            }
            parent.controller.attach(to: textView)
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? MarkdownTextView else { return }

            if !isApplyingExternalText, parent.text != textView.string {
                parent.text = textView.string
            }
            highlight()
            refreshFindHighlights(force: true)
            parent.controller.editorStateDidChange(textView)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? MarkdownTextView else { return }
            refreshFindSelectionAppearance(in: textView)
            parent.controller.editorStateDidChange(textView)
        }

        func textDidEndEditing(_ notification: Notification) {
            guard let textView = notification.object as? MarkdownTextView else { return }
            parent.controller.editorStateDidChange(textView)
        }

        private func observeFindSession() {
            stopFindBarPolling()
            findSessionCancellable?.cancel()
            findSessionCancellable = nil
            attachedFindSession = parent.findSession
            hasObservedFindBar = false
            observedFindBarVisible = false
            observedFindBarQuery = nil

            guard let findSession = parent.findSession else {
                activeFindQuery = nil
                refreshFindHighlights(force: true)
                return
            }

            findSessionCancellable = findSession.$state.sink { [weak self] state in
                self?.applyFindState(state)
            }
            pollNativeFindBar()
        }

        private func applyFindState(_ state: MarkdownFindSession.State) {
            activeFindQuery = state.active ? state.query : nil
            refreshFindHighlights()
        }

        private func startFindBarPolling() {
            if findBarPollTimer == nil {
                let timer = Timer(
                    timeInterval: 0.1,
                    target: self,
                    selector: #selector(pollNativeFindBarTimer(_:)),
                    userInfo: nil,
                    repeats: true
                )
                findBarPollTimer = timer
                RunLoop.main.add(timer, forMode: .common)
            }
        }

        private func stopFindBarPolling() {
            findBarPollTimer?.invalidate()
            findBarPollTimer = nil
        }

        @objc private func pollNativeFindBarTimer(_ timer: Timer) {
            pollNativeFindBar()
        }

        private func pollNativeFindBar() {
            guard let scrollView,
                  let findSession = attachedFindSession else { return }

            let isVisible = scrollView.isFindBarVisible
            let query = isVisible
                ? nativeFindBarQuery(in: scrollView) ?? findSession.state.query
                : nil

            guard hasObservedFindBar else {
                hasObservedFindBar = true
                observedFindBarVisible = isVisible
                observedFindBarQuery = query
                if isVisible {
                    startFindBarPolling()
                    findSession.activate(source: .editor, query: query)
                }
                return
            }

            if isVisible {
                startFindBarPolling()
                if !observedFindBarVisible {
                    findSession.activate(source: .editor, query: query)
                } else if query != observedFindBarQuery, let query {
                    findSession.update(query: query, source: .editor)
                }
            } else if observedFindBarVisible {
                findSession.deactivate(source: .editor)
            }

            observedFindBarVisible = isVisible
            observedFindBarQuery = query
            if !isVisible {
                stopFindBarPolling()
            }
        }

        private func nativeFindActionWasPerformed(_ action: NSTextFinder.Action) {
            guard let findSession = attachedFindSession else { return }

            switch action {
            case .showFindInterface, .showReplaceInterface:
                startFindBarPolling()
                let query = scrollView.flatMap { nativeFindBarQuery(in: $0) }
                    ?? findSession.state.query
                findSession.activate(source: .editor, query: query)
            case .nextMatch, .previousMatch:
                if let query = scrollView.flatMap({ nativeFindBarQuery(in: $0) }),
                   query != findSession.state.query {
                    findSession.update(query: query, source: .editor)
                }
                findSession.navigate(
                    action == .previousMatch ? .previous : .next,
                    source: .editor
                )
            case .setSearchString:
                if let query = scrollView.flatMap({ nativeFindBarQuery(in: $0) }) {
                    findSession.update(query: query, source: .editor)
                }
            case .hideFindInterface:
                findSession.deactivate(source: .editor)
            default:
                break
            }

            // AppKit can finish installing or updating the native bar on the
            // following run-loop turn.
            DispatchQueue.main.async { [weak self] in
                self?.pollNativeFindBar()
            }
        }

        private func nativeFindBarQuery(in scrollView: NSScrollView) -> String? {
            if let findBarView = scrollView.findBarView,
               let searchField = findSearchField(in: findBarView) {
                return searchField.stringValue
            }
            return NSPasteboard(name: .find).string(forType: .string)
        }

        private func findSearchField(in view: NSView) -> NSSearchField? {
            if let searchField = view as? NSSearchField {
                return searchField
            }
            for subview in view.subviews {
                if let searchField = findSearchField(in: subview) {
                    return searchField
                }
            }
            return nil
        }

        private func refreshFindHighlights(force: Bool = false) {
            guard let textView, let layoutManager = textView.layoutManager else { return }

            let text = textView.string
            if force
                || renderedFindQuery != activeFindQuery
                || renderedFindText != text {
                let fullRange = NSRange(location: 0, length: (text as NSString).length)
                renderedFindRanges = activeFindQuery.map {
                    MarkdownFindMatcher.ranges(of: $0, in: text)
                } ?? []

                if fullRange.length > 0 {
                    layoutManager.removeTemporaryAttribute(
                        MarkdownFindHighlighting.markerAttribute,
                        forCharacterRange: fullRange
                    )

                    for range in renderedFindRanges {
                        layoutManager.addTemporaryAttribute(
                            MarkdownFindHighlighting.markerAttribute,
                            value: true,
                            forCharacterRange: range
                        )
                    }
                    layoutManager.invalidateDisplay(forCharacterRange: fullRange)
                }

                renderedFindQuery = activeFindQuery
                renderedFindText = text
            }
            refreshFindSelectionAppearance(in: textView)
        }

        private func refreshFindSelectionAppearance(in textView: NSTextView) {
            guard let defaultSelectedTextAttributes else { return }
            textView.selectedTextAttributes = MarkdownFindHighlighting.selectionAttributes(
                defaultSelectedTextAttributes,
                selectedRange: textView.selectedRange(),
                matchRanges: renderedFindRanges
            )
        }

        func layoutManager(
            _ layoutManager: NSLayoutManager,
            shouldUseTemporaryAttributes attrs: [NSAttributedString.Key: Any],
            forDrawingToScreen toScreen: Bool,
            atCharacterIndex charIndex: Int,
            effectiveRange effectiveCharRange: NSRangePointer?
        ) -> [NSAttributedString.Key: Any]? {
            MarkdownFindHighlighting.attributes(attrs, drawingToScreen: toScreen)
        }

        func highlight() {
            guard let textView else { return }
            highlightTask?.cancel()

            let text = textView.string
            if (text as NSString).length < 75_000 {
                highlighter.apply(to: textView)
                return
            }

            highlightTask = Task { [weak self, weak textView] in
                do {
                    try await Task.sleep(nanoseconds: 90_000_000)
                } catch {
                    return
                }
                let spans = await Task.detached(priority: .userInitiated) {
                    MarkdownSyntaxTokenizer.spans(in: text)
                }.value
                guard !Task.isCancelled,
                      let self,
                      let textView,
                      textView.string == text else { return }
                self.highlighter.apply(spans: spans, to: textView)
            }
        }

        private static func clamped(_ range: NSRange, toUTF16Length length: Int) -> NSRange {
            guard range.location != NSNotFound else { return NSRange(location: 0, length: 0) }
            let location = min(max(0, range.location), length)
            return NSRange(
                location: location,
                length: min(max(0, range.length), length - location)
            )
        }
    }
}

/// Notifies the editor after AppKit has assigned the scroll view its real
/// viewport size. SwiftUI creates representable views at zero width, so using
/// the initial content size for wrapping would collapse the text container.
@MainActor
final class MarkdownEditorScrollView: NSScrollView {
    var onViewportLayout: (() -> Void)?

    override func tile() {
        super.tile()
        onViewportLayout?()
    }

    override func layout() {
        super.layout()
        onViewportLayout?()
    }
}

/// NSTextView subclass used only for Markdown-aware editing behavior.
@MainActor
class MarkdownTextView: NSTextView {
    var onAppearanceChange: (() -> Void)?
    var onFindAction: ((NSTextFinder.Action) -> Void)?

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        onAppearanceChange?()
    }

    override func performTextFinderAction(_ sender: Any?) {
        let action = (sender as? NSValidatedUserInterfaceItem)
            .flatMap { NSTextFinder.Action(rawValue: $0.tag) }
        super.performTextFinderAction(sender)
        if let action {
            onFindAction?(action)
        }
    }

    override func insertNewline(_ sender: Any?) {
        let selection = selectedRange()
        guard selection.length == 0,
              let action = MarkdownLineContinuation.action(
                in: string,
                atUTF16Location: selection.location
              ) else {
            super.insertNewline(sender)
            return
        }

        switch action {
        case .continueWith(let prefix):
            insertText("\n\(prefix)" as NSString, replacementRange: selection)
        case .exit(let range, let replacement):
            insertText(replacement as NSString, replacementRange: range)
        case .edit(let edit):
            _ = performTextEdit(edit, actionName: "Continue List")
        }
    }

    override func insertTab(_ sender: Any?) {
        guard performListIndentation(.indent, actionName: "Indent") else {
            super.insertTab(sender)
            return
        }
    }

    override func insertBacktab(_ sender: Any?) {
        guard performListIndentation(.outdent, actionName: "Outdent") else {
            super.insertBacktab(sender)
            return
        }
    }

    private func performListIndentation(
        _ direction: MarkdownListIndentation.Direction,
        actionName: String
    ) -> Bool {
        guard let edit = MarkdownListIndentation.edit(
            text: string,
            selection: selectedRange(),
            direction: direction
        ) else { return false }

        return performTextEdit(edit, actionName: actionName)
    }

    private func performTextEdit(
        _ edit: MarkdownListIndentation.Edit,
        actionName: String
    ) -> Bool {
        guard edit.changes(string) else { return true }
        guard let textStorage,
              shouldChangeText(
                in: edit.replacementRange,
                replacementString: edit.replacement
              ) else { return true }

        breakUndoCoalescing()
        textStorage.beginEditing()
        textStorage.replaceCharacters(in: edit.replacementRange, with: edit.replacement)
        textStorage.endEditing()
        didChangeText()
        setSelectedRange(edit.selection)
        scrollRangeToVisible(edit.selection)
        undoManager?.setActionName(actionName)
        return true
    }
}

enum MarkdownFindHighlighting {
    static let markerAttribute = NSAttributedString.Key("ACMD.MarkdownFindMatch")

    static func selectionAttributes(
        _ baseAttributes: [NSAttributedString.Key: Any],
        selectedRange: NSRange,
        matchRanges: [NSRange]
    ) -> [NSAttributedString.Key: Any] {
        guard selectedRange.length > 0,
              matchRanges.contains(where: { NSEqualRanges($0, selectedRange) }) else {
            return baseAttributes
        }

        var attributes = baseAttributes
        attributes[.backgroundColor] = NSColor.findHighlightColor
        attributes[.foregroundColor] = NSColor.black
        return attributes
    }

    static func attributes(
        _ temporaryAttributes: [NSAttributedString.Key: Any],
        drawingToScreen: Bool
    ) -> [NSAttributedString.Key: Any]? {
        guard drawingToScreen else { return nil }

        var attributes = temporaryAttributes
        let isMatch = attributes.removeValue(forKey: markerAttribute) != nil
        guard isMatch else { return attributes }

        attributes[.backgroundColor] = NSColor.findHighlightColor
        attributes[.foregroundColor] = NSColor.black
        return attributes
    }
}

enum MarkdownLineContinuation {
    enum Action {
        case continueWith(String)
        case exit(range: NSRange, replacement: String)
        case edit(MarkdownListIndentation.Edit)
    }

    private static let ordered = try! NSRegularExpression(
        pattern: #"^([ \t]*(?:>[ \t]*)*)(\d+)([.)])([ \t]+)(?:\[([ xX])\]([ \t]+))?(.*)$"#
    )
    private static let unordered = try! NSRegularExpression(
        pattern: #"^([ \t]*(?:>[ \t]*)*)([-+*])([ \t]+)(?:\[([ xX])\]([ \t]+))?(.*)$"#
    )
    private static let quote = try! NSRegularExpression(
        pattern: #"^([ \t]*(?:>[ \t]*)+)(.*)$"#
    )
    private static let blockPrefix = try! NSRegularExpression(
        pattern: #"^([ \t]*(?:>[ \t]*)*)"#
    )

    private struct OrderedItem {
        let prefix: String
        let number: Int
        let numberRange: NSRange
        let delimiter: String
    }

    private struct StructuralPosition: Equatable {
        let quoteDepth: Int
        let indentation: Int
    }

    private struct Mutation {
        let range: NSRange
        let replacement: String
    }

    static func action(in text: String, atUTF16Location location: Int) -> Action? {
        let source = text as NSString
        let safeLocation = min(max(0, location), source.length)
        let lineRange = source.lineRange(for: NSRange(location: safeLocation, length: 0))
        let prefixLength = min(max(0, safeLocation - lineRange.location), lineRange.length)
        var lineContentEnd = NSMaxRange(lineRange)
        while lineContentEnd > lineRange.location {
            let character = source.character(at: lineContentEnd - 1)
            guard character == unichar(10) || character == unichar(13) else { break }
            lineContentEnd -= 1
        }
        let isAtLineEnd = safeLocation == lineContentEnd
        let line = source.substring(
            with: NSRange(location: lineRange.location, length: prefixLength)
        )
        let lineString = line as NSString
        let wholeLine = NSRange(location: 0, length: lineString.length)

        if let match = ordered.firstMatch(in: line, range: wholeLine),
           let number = Int(capture(2, match: match, in: lineString)) {
            let content = capture(7, match: match, in: lineString)
            let outerPrefix = capture(1, match: match, in: lineString)
            if hasContent(content) || !isAtLineEnd {
                let isTask = match.range(at: 5).location != NSNotFound
                return .edit(orderedContinuationEdit(
                    in: source,
                    lineRange: lineRange,
                    location: safeLocation,
                    prefix: outerPrefix,
                    number: number,
                    delimiter: capture(3, match: match, in: lineString),
                    spacing: capture(4, match: match, in: lineString),
                    isTask: isTask,
                    taskSpacing: isTask
                        ? capture(6, match: match, in: lineString)
                        : ""
                ))
            }
            if isAtLineEnd,
               let outdent = MarkdownListIndentation.edit(
                    text: text,
                    selection: NSRange(location: safeLocation, length: 0),
                    direction: .outdent
               ),
               outdent.changes(text) {
                return .edit(outdent)
            }
            if isAtLineEnd {
                return .exit(
                    range: NSRange(location: lineRange.location, length: prefixLength),
                    replacement: outerPrefix
                )
            }
        }

        if let match = unordered.firstMatch(in: line, range: wholeLine) {
            let content = capture(6, match: match, in: lineString)
            let outerPrefix = capture(1, match: match, in: lineString)
            if hasContent(content) || !isAtLineEnd {
                var marker = outerPrefix
                    + capture(2, match: match, in: lineString)
                    + capture(3, match: match, in: lineString)
                if match.range(at: 4).location != NSNotFound {
                    marker += "[ ]" + capture(5, match: match, in: lineString)
                }
                return .continueWith(marker)
            }
            if isAtLineEnd,
               let outdent = MarkdownListIndentation.edit(
                    text: text,
                    selection: NSRange(location: safeLocation, length: 0),
                    direction: .outdent
               ),
               outdent.changes(text) {
                return .edit(outdent)
            }
            if isAtLineEnd {
                return .exit(
                    range: NSRange(location: lineRange.location, length: prefixLength),
                    replacement: outerPrefix
                )
            }
        }

        if let match = quote.firstMatch(in: line, range: wholeLine) {
            let content = capture(2, match: match, in: lineString)
            let prefix = capture(1, match: match, in: lineString)
            if hasContent(content) {
                return .continueWith(prefix)
            }
            if isAtLineEnd {
                return .exit(
                    range: NSRange(location: lineRange.location, length: prefixLength),
                    replacement: removingLastQuoteLevel(from: prefix)
                )
            }
        }

        return nil
    }

    private static func orderedContinuationEdit(
        in source: NSString,
        lineRange: NSRange,
        location: Int,
        prefix: String,
        number: Int,
        delimiter: String,
        spacing: String,
        isTask: Bool,
        taskSpacing: String
    ) -> MarkdownListIndentation.Edit {
        let nextNumber = incrementing(number)
        var continuation = "\n\(prefix)\(nextNumber)\(delimiter)\(spacing)"
        if isTask {
            continuation += "[ ]\(taskSpacing)"
        }

        var mutations = [Mutation(
            range: NSRange(location: location, length: 0),
            replacement: continuation
        )]
        var nextOrdinal = incrementing(nextNumber)
        var scanLocation = NSMaxRange(lineRange)
        while scanLocation < source.length {
            let nextRange = source.lineRange(for: NSRange(
                location: scanLocation,
                length: 0
            ))
            guard nextRange.location == scanLocation, nextRange.length > 0 else { break }
            let nextLine = content(of: nextRange, source: source)
            if nextLine.length == 0 {
                scanLocation = NSMaxRange(nextRange)
                continue
            }

            if let item = orderedItem(in: nextLine) {
                if structuralPosition(of: item.prefix) == structuralPosition(of: prefix) {
                    guard item.delimiter == delimiter else { break }
                    let replacement = String(nextOrdinal)
                    if nextLine.substring(with: item.numberRange) != replacement {
                        mutations.append(Mutation(
                            range: NSRange(
                                location: nextRange.location + item.numberRange.location,
                                length: item.numberRange.length
                            ),
                            replacement: replacement
                        ))
                    }
                    nextOrdinal = incrementing(nextOrdinal)
                } else if !isDeeper(item.prefix, than: prefix) {
                    break
                }
            } else if let nextPrefix = structuralPrefix(in: nextLine),
                      !isDeeper(nextPrefix, than: prefix) {
                break
            }
            scanLocation = NSMaxRange(nextRange)
        }

        let replacementEnd = mutations.reduce(location) { end, mutation in
            max(end, NSMaxRange(mutation.range))
        }
        let replacementRange = NSRange(
            location: location,
            length: replacementEnd - location
        )
        let replacement = NSMutableString(string: source.substring(with: replacementRange))
        for mutation in mutations.reversed() {
            replacement.replaceCharacters(
                in: NSRange(
                    location: mutation.range.location - replacementRange.location,
                    length: mutation.range.length
                ),
                with: mutation.replacement
            )
        }
        return MarkdownListIndentation.Edit(
            replacementRange: replacementRange,
            replacement: replacement as String,
            selection: NSRange(
                location: location + (continuation as NSString).length,
                length: 0
            )
        )
    }

    private static func orderedItem(in line: NSString) -> OrderedItem? {
        let range = NSRange(location: 0, length: line.length)
        guard let match = ordered.firstMatch(in: line as String, range: range),
              let number = Int(capture(2, match: match, in: line)) else { return nil }
        return OrderedItem(
            prefix: capture(1, match: match, in: line),
            number: number,
            numberRange: match.range(at: 2),
            delimiter: capture(3, match: match, in: line)
        )
    }

    private static func structuralPrefix(in line: NSString) -> String? {
        let range = NSRange(location: 0, length: line.length)
        if let match = unordered.firstMatch(in: line as String, range: range) {
            return capture(1, match: match, in: line)
        }
        guard let match = blockPrefix.firstMatch(in: line as String, range: range) else {
            return nil
        }
        return capture(1, match: match, in: line)
    }

    private static func isDeeper(_ candidate: String, than prefix: String) -> Bool {
        let candidatePosition = structuralPosition(of: candidate)
        let parentPosition = structuralPosition(of: prefix)
        return (candidatePosition.quoteDepth > parentPosition.quoteDepth
                && candidatePosition.indentation >= parentPosition.indentation)
            || (candidatePosition.quoteDepth >= parentPosition.quoteDepth
                && candidatePosition.indentation > parentPosition.indentation)
    }

    private static func structuralPosition(of prefix: String) -> StructuralPosition {
        var quoteDepth = 0
        var whitespaceWidth = 0
        for character in prefix {
            if character == ">" {
                quoteDepth += 1
            } else if character == "\t" {
                whitespaceWidth += 4
            } else {
                whitespaceWidth += 1
            }
        }
        return StructuralPosition(
            quoteDepth: quoteDepth,
            indentation: max(0, whitespaceWidth - quoteDepth)
        )
    }

    private static func content(of lineRange: NSRange, source: NSString) -> NSString {
        var end = NSMaxRange(lineRange)
        while end > lineRange.location {
            let character = source.character(at: end - 1)
            guard character == 10 || character == 13 else { break }
            end -= 1
        }
        return source.substring(with: NSRange(
            location: lineRange.location,
            length: end - lineRange.location
        )) as NSString
    }

    private static func incrementing(_ number: Int) -> Int {
        number == Int.max ? number : number + 1
    }

    private static func capture(_ index: Int, match: NSTextCheckingResult, in source: NSString) -> String {
        let range = match.range(at: index)
        guard range.location != NSNotFound else { return "" }
        return source.substring(with: range)
    }

    private static func hasContent(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func removingLastQuoteLevel(from prefix: String) -> String {
        let value = prefix as NSString
        let markerRange = value.range(of: ">", options: .backwards)
        guard markerRange.location != NSNotFound else { return prefix }
        return value.substring(to: markerRange.location)
    }
}

@MainActor
private final class MarkdownSyntaxHighlighter {
    private var baseFont: NSFont
    private var boldFont: NSFont
    private var italicFont: NSFont
    private var headingFont: NSFont

    init(baseFont: NSFont) {
        self.baseFont = baseFont
        boldFont = NSFontManager.shared.convert(baseFont, toHaveTrait: .boldFontMask)
        italicFont = NSFontManager.shared.convert(baseFont, toHaveTrait: .italicFontMask)
        headingFont = NSFont.monospacedSystemFont(ofSize: baseFont.pointSize + 1, weight: .bold)
    }

    func update(baseFont: NSFont) {
        self.baseFont = baseFont
        boldFont = NSFontManager.shared.convert(baseFont, toHaveTrait: .boldFontMask)
        italicFont = NSFontManager.shared.convert(baseFont, toHaveTrait: .italicFontMask)
        headingFont = NSFont.monospacedSystemFont(
            ofSize: baseFont.pointSize + 1,
            weight: .bold
        )
    }

    func apply(to textView: NSTextView) {
        let text = textView.string
        apply(spans: MarkdownSyntaxTokenizer.spans(in: text), to: textView)
    }

    func apply(spans: [MarkdownSyntaxSpan], to textView: NSTextView) {
        guard let layoutManager = textView.layoutManager else { return }
        let text = textView.string
        let fullRange = NSRange(location: 0, length: (text as NSString).length)
        let selections = textView.selectedRanges

        for key in Self.temporaryAttributeKeys {
            layoutManager.removeTemporaryAttribute(key, forCharacterRange: fullRange)
        }

        for span in spans {
            let range = NSIntersectionRange(span.range, fullRange)
            guard range.length > 0 else { continue }
            layoutManager.addTemporaryAttributes(attributes(for: span.kind), forCharacterRange: range)
        }

        // Temporary layout attributes should not move selection, but preserving
        // it here also protects against TextKit relayout changes.
        if textView.selectedRanges != selections {
            textView.selectedRanges = selections
        }
    }

    private func attributes(for kind: MarkdownSyntaxKind) -> [NSAttributedString.Key: Any] {
        switch kind {
        case .heading:
            [.foregroundColor: NSColor.systemPurple, .font: headingFont]
        case .strong:
            [.foregroundColor: NSColor.labelColor, .font: boldFont]
        case .emphasis:
            [.foregroundColor: NSColor.labelColor, .font: italicFont]
        case .strikethrough:
            [
                .foregroundColor: NSColor.secondaryLabelColor,
                .strikethroughStyle: NSUnderlineStyle.single.rawValue
            ]
        case .inlineCode:
            [
                .foregroundColor: NSColor.systemPink,
                .backgroundColor: NSColor.systemPink.withAlphaComponent(0.10),
                .font: baseFont
            ]
        case .codeBlock:
            [
                .foregroundColor: NSColor.systemPink,
                .backgroundColor: NSColor.unemphasizedSelectedContentBackgroundColor.withAlphaComponent(0.35),
                .font: baseFont
            ]
        case .link:
            [.foregroundColor: NSColor.linkColor]
        case .image:
            [.foregroundColor: NSColor.systemTeal]
        case .blockQuote:
            [.foregroundColor: NSColor.secondaryLabelColor]
        case .listMarker:
            [.foregroundColor: NSColor.systemOrange, .font: boldFont]
        case .taskMarker:
            [.foregroundColor: NSColor.systemGreen, .font: boldFont]
        case .horizontalRule:
            [.foregroundColor: NSColor.tertiaryLabelColor, .font: boldFont]
        }
    }

    private static let temporaryAttributeKeys: [NSAttributedString.Key] = [
        .foregroundColor,
        .backgroundColor,
        .font,
        .strikethroughStyle
    ]
}
