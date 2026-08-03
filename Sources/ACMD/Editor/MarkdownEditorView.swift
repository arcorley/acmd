import AppKit
import SwiftUI
import ACMDCore

/// A native, plain-text Markdown editor hosted in SwiftUI.
struct MarkdownEditorView: NSViewRepresentable {
    static let accessibilityIdentifier = "markdown-editor"

    @Binding private var text: String
    @ObservedObject private var controller: MarkdownEditorController
    private let isActive: Bool

    init(
        text: Binding<String>,
        controller: MarkdownEditorController,
        isActive: Bool = true
    ) {
        _text = text
        self.controller = controller
        self.isActive = isActive
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor
        scrollView.hasVerticalScroller = true
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

        let textView = MarkdownTextView(frame: .zero, textContainer: textContainer)
        configure(textView, in: scrollView)
        textStorage.setAttributedString(
            NSAttributedString(string: text, attributes: Self.baseAttributes)
        )
        textView.typingAttributes = Self.baseAttributes
        textView.delegate = context.coordinator
        scrollView.documentView = textView

        context.coordinator.connect(textView)
        context.coordinator.highlight()
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? MarkdownTextView else { return }
        context.coordinator.update(parent: self, textView: textView)
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
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
        textView.font = Self.editorFont
        textView.textContainerInset = NSSize(width: 18, height: 16)
        textView.setAccessibilityIdentifier(Self.accessibilityIdentifier)
        textView.setAccessibilityLabel("Markdown editor")
    }

    private static let editorFont = NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)

    private static var baseAttributes: [NSAttributedString.Key: Any] {
        [
            .font: editorFont,
            .foregroundColor: NSColor.textColor
        ]
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        private var parent: MarkdownEditorView
        private weak var textView: MarkdownTextView?
        private weak var attachedController: MarkdownEditorController?
        private var isApplyingExternalText = false
        private let highlighter = MarkdownSyntaxHighlighter(baseFont: MarkdownEditorView.editorFont)
        private var highlightTask: Task<Void, Never>?

        init(parent: MarkdownEditorView) {
            self.parent = parent
        }

        fileprivate func connect(_ textView: MarkdownTextView) {
            self.textView = textView
            enforceActivation(on: textView)
            attachedController = parent.controller
            parent.controller.attach(to: textView)
            textView.onAppearanceChange = { [weak self] in
                self?.highlight()
            }
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
                    NSAttributedString(string: parent.text, attributes: MarkdownEditorView.baseAttributes)
                )
                textStorage.endEditing()
            } else {
                textView.string = parent.text
            }
            textView.typingAttributes = MarkdownEditorView.baseAttributes
            let length = (parent.text as NSString).length
            textView.setSelectedRange(Self.clamped(selection, toUTF16Length: length))
            isApplyingExternalText = false

            highlight()
            parent.controller.editorStateDidChange(textView)
        }

        private func enforceActivation(on textView: MarkdownTextView) {
            textView.isEditable = parent.isActive
            textView.isSelectable = parent.isActive

            guard !parent.isActive,
                  textView.window?.firstResponder === textView else { return }
            textView.window?.makeFirstResponder(nil)
        }

        fileprivate func disconnect() {
            guard let textView else { return }
            highlightTask?.cancel()
            highlightTask = nil
            textView.onAppearanceChange = nil
            attachedController?.detach(from: textView)
            textView.delegate = nil
            self.textView = nil
            attachedController = nil
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
            parent.controller.editorStateDidChange(textView)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? MarkdownTextView else { return }
            parent.controller.editorStateDidChange(textView)
        }

        func textDidEndEditing(_ notification: Notification) {
            guard let textView = notification.object as? MarkdownTextView else { return }
            parent.controller.editorStateDidChange(textView)
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

/// NSTextView subclass used only for Markdown-aware editing behavior.
@MainActor
fileprivate final class MarkdownTextView: NSTextView {
    var onAppearanceChange: (() -> Void)?

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        onAppearanceChange?()
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
        }
    }
}

private enum MarkdownLineContinuation {
    enum Action {
        case continueWith(String)
        case exit(range: NSRange, replacement: String)
    }

    private static let ordered = try! NSRegularExpression(
        pattern: #"^([ \t]*(?:>[ \t]*)*)(\d+)([.)])([ \t]+)(.*)$"#
    )
    private static let unordered = try! NSRegularExpression(
        pattern: #"^([ \t]*(?:>[ \t]*)*)([-+*])([ \t]+)(?:\[([ xX])\]([ \t]+))?(.*)$"#
    )
    private static let quote = try! NSRegularExpression(
        pattern: #"^([ \t]*(?:>[ \t]*)+)(.*)$"#
    )

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
            let content = capture(5, match: match, in: lineString)
            let outerPrefix = capture(1, match: match, in: lineString)
            if hasContent(content) {
                let nextNumber = number == Int.max ? number : number + 1
                return .continueWith(
                    outerPrefix
                        + String(nextNumber)
                        + capture(3, match: match, in: lineString)
                        + capture(4, match: match, in: lineString)
                )
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
            if hasContent(content) {
                var marker = outerPrefix
                    + capture(2, match: match, in: lineString)
                    + capture(3, match: match, in: lineString)
                if match.range(at: 4).location != NSNotFound {
                    marker += "[ ]" + capture(5, match: match, in: lineString)
                }
                return .continueWith(marker)
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
    private let baseFont: NSFont
    private let boldFont: NSFont
    private let italicFont: NSFont
    private let headingFont: NSFont

    init(baseFont: NSFont) {
        self.baseFont = baseFont
        boldFont = NSFontManager.shared.convert(baseFont, toHaveTrait: .boldFontMask)
        italicFont = NSFontManager.shared.convert(baseFont, toHaveTrait: .italicFontMask)
        headingFont = NSFont.monospacedSystemFont(ofSize: baseFont.pointSize + 1, weight: .bold)
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
