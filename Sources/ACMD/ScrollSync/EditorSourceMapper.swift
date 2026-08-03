import AppKit

/// Converts between an NSTextView viewport and a fractional Markdown source line.
enum EditorSourceMapper {
    static func lineStarts(in text: String) -> [Int] {
        let units = Array(text.utf16)
        var starts = [0]
        starts.reserveCapacity(max(1, units.count / 40))

        for index in units.indices {
            if units[index] == 10 {
                starts.append(index + 1)
            } else if units[index] == 13,
                      index + 1 >= units.count || units[index + 1] != 10 {
                starts.append(index + 1)
            }
        }
        return starts
    }

    static func lineIndex(atUTF16Location location: Int, lineStarts: [Int]) -> Int {
        guard !lineStarts.isEmpty else { return 0 }
        let location = max(0, location)
        var lowerBound = 0
        var upperBound = lineStarts.count
        while lowerBound < upperBound {
            let midpoint = (lowerBound + upperBound) / 2
            if lineStarts[midpoint] <= location {
                lowerBound = midpoint + 1
            } else {
                upperBound = midpoint
            }
        }
        return max(0, lowerBound - 1)
    }

    static func sourceLine(
        in textView: NSTextView,
        scrollView: NSScrollView,
        lineStarts: [Int]
    ) -> CGFloat {
        guard let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer,
              layoutManager.numberOfGlyphs > 0 else { return 0 }

        let visibleTop = scrollView.contentView.bounds.minY
        let containerOrigin = textView.textContainerOrigin
        let containerPoint = NSPoint(
            x: textContainer.lineFragmentPadding,
            y: max(0, visibleTop - containerOrigin.y)
        )
        let glyphIndex = min(
            layoutManager.glyphIndex(for: containerPoint, in: textContainer),
            layoutManager.numberOfGlyphs - 1
        )
        let characterIndex = layoutManager.characterIndexForGlyph(at: glyphIndex)
        let lineIndex = lineIndex(
            atUTF16Location: characterIndex,
            lineStarts: lineStarts
        )
        let fragment = layoutManager.lineFragmentRect(
            forGlyphAt: glyphIndex,
            effectiveRange: nil
        )
        let fragmentTop = fragment.minY + containerOrigin.y
        let fraction = min(
            max((visibleTop - fragmentTop) / max(fragment.height, 1), 0),
            0.999
        )
        return CGFloat(lineIndex) + fraction
    }

    static func scroll(
        _ textView: NSTextView,
        in scrollView: NSScrollView,
        toSourceLine sourceLine: CGFloat,
        lineStarts: [Int]
    ) {
        guard let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer,
              !lineStarts.isEmpty else { return }

        let clampedLine = min(max(sourceLine, 0), CGFloat(lineStarts.count - 1))
        let lineIndex = Int(clampedLine.rounded(.down))
        let fraction = clampedLine - CGFloat(lineIndex)
        let textLength = (textView.string as NSString).length
        let characterIndex = min(lineStarts[lineIndex], textLength)

        let fragment: NSRect
        if textLength == 0 || characterIndex == textLength {
            layoutManager.ensureLayout(for: textContainer)
            let extraFragment = layoutManager.extraLineFragmentRect
            fragment = extraFragment.isEmpty
                ? NSRect(x: 0, y: max(0, textView.bounds.maxY - 1), width: 1, height: 1)
                : extraFragment
        } else {
            layoutManager.ensureLayout(
                forCharacterRange: NSRange(location: characterIndex, length: 1)
            )
            let glyphRange = layoutManager.glyphRange(
                forCharacterRange: NSRange(location: characterIndex, length: 1),
                actualCharacterRange: nil
            )
            guard glyphRange.location < layoutManager.numberOfGlyphs else { return }
            fragment = layoutManager.lineFragmentRect(
                forGlyphAt: glyphRange.location,
                effectiveRange: nil
            )
        }

        let targetY = textView.textContainerOrigin.y
            + fragment.minY
            + (fraction * fragment.height)
        let clipView = scrollView.contentView
        let proposed = NSRect(
            x: clipView.bounds.minX,
            y: targetY,
            width: clipView.bounds.width,
            height: clipView.bounds.height
        )
        clipView.scroll(to: clipView.constrainBoundsRect(proposed).origin)
        scrollView.reflectScrolledClipView(clipView)
    }
}
