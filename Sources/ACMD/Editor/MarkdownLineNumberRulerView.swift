import AppKit

/// A native scroll-view ruler that labels logical Markdown lines. Wrapped
/// continuation fragments intentionally remain unlabeled.
@MainActor
final class MarkdownLineNumberRulerView: NSRulerView {
    private weak var textView: NSTextView?
    private var observerTokens: [NSObjectProtocol] = []
    private var labelFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
    private var lineStarts = [0]
    private var preferredThickness: CGFloat = 30

    override var requiredThickness: CGFloat { preferredThickness }
    override var isOpaque: Bool { false }

    override func setFrameSize(_ newSize: NSSize) {
        // SwiftUI may briefly propose the full pane width while an NSScrollView
        // transitions from zero size. A vertical ruler must never accept it or
        // its background masks the editor until the next explicit retile.
        super.setFrameSize(NSSize(width: preferredThickness, height: newSize.height))
    }

    init(textView: NSTextView, scrollView: NSScrollView) {
        self.textView = textView
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        clientView = textView
        textView.postsFrameChangedNotifications = true
        scrollView.contentView.postsBoundsChangedNotifications = true
        refreshLineStarts()
        installObservers(textView: textView, scrollView: scrollView)
        update(fontSize: textView.font?.pointSize ?? MarkdownEditorController.defaultFontSize)
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        for token in observerTokens {
            NotificationCenter.default.removeObserver(token)
        }
    }

    func update(fontSize: CGFloat) {
        labelFont = .monospacedDigitSystemFont(
            ofSize: min(max(fontSize - 2, 9), 13),
            weight: .regular
        )
        invalidateLineNumbers()
    }

    func invalidateLineNumbers(recalculateLineStarts: Bool = false) {
        if recalculateLineStarts {
            refreshLineStarts()
        }
        let digits = max(2, String(lineStarts.count).count)
        let digitWidth = ("0" as NSString).size(withAttributes: [.font: labelFont]).width
        let thickness = ceil(CGFloat(digits) * digitWidth + 14)
        if preferredThickness != thickness || ruleThickness != thickness {
            preferredThickness = thickness
            ruleThickness = thickness
            setFrameSize(NSSize(width: thickness, height: frame.height))
            scrollView?.tile()
        }
        needsDisplay = true
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView,
              let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer else { return }

        let rulerRect = rect.intersection(NSRect(
            x: bounds.minX,
            y: rect.minY,
            width: preferredThickness,
            height: rect.height
        ))
        NSColor.textBackgroundColor.setFill()
        rulerRect.fill()
        NSColor.separatorColor.setFill()
        NSRect(
            x: bounds.minX + preferredThickness - 1,
            y: rect.minY,
            width: 1,
            height: rect.height
        ).fill()

        layoutManager.ensureLayout(for: textContainer)
        let visibleTextRect = textView.visibleRect
        let containerOrigin = textView.textContainerOrigin
        let visibleContainerRect = visibleTextRect.offsetBy(
            dx: -containerOrigin.x,
            dy: -containerOrigin.y
        )
        let glyphRange = layoutManager.glyphRange(
            forBoundingRect: visibleContainerRect,
            in: textContainer
        )
        let textLength = (textView.string as NSString).length

        let firstCharacter: Int
        let lastCharacter: Int
        if glyphRange.length > 0 {
            firstCharacter = layoutManager.characterIndexForGlyph(at: glyphRange.location)
            lastCharacter = layoutManager.characterIndexForGlyph(
                at: NSMaxRange(glyphRange) - 1
            )
        } else {
            firstCharacter = textLength
            lastCharacter = textLength
        }

        let firstLine = max(
            0,
            EditorSourceMapper.lineIndex(
                atUTF16Location: firstCharacter,
                lineStarts: lineStarts
            ) - 1
        )
        let lastLine = min(
            lineStarts.count - 1,
            EditorSourceMapper.lineIndex(
                atUTF16Location: lastCharacter,
                lineStarts: lineStarts
            ) + 1
        )
        let currentLine = EditorSourceMapper.lineIndex(
            atUTF16Location: (textView as? MarkdownNavigationTextView)?
                .selectionFocusLocation ?? textView.selectedRange().location,
            lineStarts: lineStarts
        )

        for lineIndex in firstLine...lastLine {
            guard let fragment = lineFragment(
                atUTF16Location: lineStarts[lineIndex],
                textLength: textLength,
                layoutManager: layoutManager,
                textContainer: textContainer
            ) else { continue }

            let fragmentInTextView = fragment.offsetBy(
                dx: containerOrigin.x,
                dy: containerOrigin.y
            )
            let origin = convert(fragmentInTextView.origin, from: textView)
            let labelRect = NSRect(
                x: 3,
                y: origin.y,
                width: max(0, ruleThickness - 10),
                height: fragment.height
            )
            drawLabel(lineIndex + 1, in: labelRect, isCurrent: lineIndex == currentLine)
        }
    }

    private func lineFragment(
        atUTF16Location location: Int,
        textLength: Int,
        layoutManager: NSLayoutManager,
        textContainer: NSTextContainer
    ) -> NSRect? {
        let location = min(max(location, 0), textLength)
        if textLength == 0 || location == textLength {
            let extra = layoutManager.extraLineFragmentRect
            return extra.isEmpty ? nil : extra
        }

        let glyphRange = layoutManager.glyphRange(
            forCharacterRange: NSRange(location: location, length: 1),
            actualCharacterRange: nil
        )
        guard glyphRange.location < layoutManager.numberOfGlyphs else { return nil }
        return layoutManager.lineFragmentRect(
            forGlyphAt: glyphRange.location,
            effectiveRange: nil
        )
    }

    private func drawLabel(_ line: Int, in rect: NSRect, isCurrent: Bool) {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .right
        let attributes: [NSAttributedString.Key: Any] = [
            .font: labelFont,
            .foregroundColor: isCurrent ? NSColor.labelColor : NSColor.tertiaryLabelColor,
            .paragraphStyle: paragraphStyle
        ]
        let label = String(line) as NSString
        let labelHeight = label.size(withAttributes: attributes).height
        label.draw(
            in: NSRect(
                x: rect.minX,
                y: rect.midY - labelHeight / 2,
                width: rect.width,
                height: labelHeight
            ),
            withAttributes: attributes
        )
    }

    private func installObservers(textView: NSTextView, scrollView: NSScrollView) {
        let center = NotificationCenter.default
        let notifications: [(Notification.Name, AnyObject)] = [
            (NSText.didChangeNotification, textView),
            (NSTextView.didChangeSelectionNotification, textView),
            (NSView.frameDidChangeNotification, textView),
            (NSView.boundsDidChangeNotification, scrollView.contentView)
        ]
        observerTokens = notifications.map { name, object in
            center.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.invalidateLineNumbers(
                        recalculateLineStarts: name == NSText.didChangeNotification
                    )
                }
            }
        }
    }

    private func refreshLineStarts() {
        guard let textView else {
            lineStarts = [0]
            return
        }
        lineStarts = EditorSourceMapper.lineStarts(in: textView.string)
    }
}
