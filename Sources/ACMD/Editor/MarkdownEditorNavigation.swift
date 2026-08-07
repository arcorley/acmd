import AppKit

/// Markdown-aware destinations for the standard AppKit movement commands.
/// All offsets are UTF-16 so they can be applied directly to `NSTextView`.
enum MarkdownEditorNavigation {
    static func beginningOfLine(in text: String, from location: Int) -> Int {
        let bounds = lineBounds(in: text, at: location)
        let location = clamped(location, to: (text as NSString).length)
        return location > bounds.contentStart ? bounds.contentStart : bounds.start
    }

    static func endOfLine(in text: String, from location: Int) -> Int {
        let bounds = lineBounds(in: text, at: location)
        let location = clamped(location, to: (text as NSString).length)
        return location < bounds.meaningfulEnd ? bounds.meaningfulEnd : bounds.end
    }

    static func beginningOfDocument(in text: String, from location: Int) -> Int {
        let source = text as NSString
        let firstContent = source.rangeOfCharacter(
            from: .whitespacesAndNewlines.inverted
        ).location
        guard firstContent != NSNotFound else { return 0 }
        return clamped(location, to: source.length) > firstContent ? firstContent : 0
    }

    static func endOfDocument(in text: String, from location: Int) -> Int {
        let source = text as NSString
        let lastContent = source.rangeOfCharacter(
            from: .whitespacesAndNewlines.inverted,
            options: .backwards
        )
        guard lastContent.location != NSNotFound else { return source.length }
        let meaningfulEnd = NSMaxRange(lastContent)
        return clamped(location, to: source.length) < meaningfulEnd
            ? meaningfulEnd
            : source.length
    }

    static func wordBackward(in text: String, from location: Int) -> Int {
        let source = text as NSString
        let location = clamped(location, to: source.length)
        let initialLine = lineBounds(in: text, at: location)

        // Treat indentation, quote prefixes, list markers, and task markers as
        // one structural unit when moving left from the item's content.
        if location > initialLine.start, location <= initialLine.contentStart {
            return initialLine.start
        }

        var cursor = location
        while let range = composedRange(before: cursor, in: source),
              tokenClass(in: range, source: source) == .whitespace {
            cursor = range.location
        }
        guard let first = composedRange(before: cursor, in: source) else { return 0 }
        let kind = tokenClass(in: first, source: source)
        cursor = first.location
        while let range = composedRange(before: cursor, in: source),
              tokenClass(in: range, source: source) == kind {
            cursor = range.location
        }
        return cursor
    }

    static func wordForward(in text: String, from location: Int) -> Int {
        let source = text as NSString
        let location = clamped(location, to: source.length)
        let initialLine = lineBounds(in: text, at: location)

        // Enter a Markdown item in one step instead of stopping inside `-`,
        // `1.`, `>`, or `[ ]` syntax.
        if location >= initialLine.start, location < initialLine.contentStart {
            return initialLine.contentStart
        }

        var cursor = location
        while let range = composedRange(at: cursor, in: source),
              tokenClass(in: range, source: source) == .whitespace {
            cursor = NSMaxRange(range)
        }

        if cursor < source.length {
            let nextLine = lineBounds(in: text, at: cursor)
            if cursor >= nextLine.start, cursor < nextLine.contentStart {
                return nextLine.contentStart
            }
        }

        guard let first = composedRange(at: cursor, in: source) else {
            return source.length
        }
        let kind = tokenClass(in: first, source: source)
        cursor = NSMaxRange(first)
        while let range = composedRange(at: cursor, in: source),
              tokenClass(in: range, source: source) == kind {
            cursor = NSMaxRange(range)
        }
        return cursor
    }

    // MARK: - Logical line structure

    private struct LineBounds {
        let start: Int
        let contentStart: Int
        let meaningfulEnd: Int
        let end: Int
    }

    private static func lineBounds(in text: String, at location: Int) -> LineBounds {
        let source = text as NSString
        let location = clamped(location, to: source.length)
        let lineRange = source.lineRange(for: NSRange(location: location, length: 0))
        let start = lineRange.location
        var end = NSMaxRange(lineRange)
        while end > start, isNewline(source.character(at: end - 1)) {
            end -= 1
        }

        var meaningfulEnd = end
        while meaningfulEnd > start,
              isHorizontalWhitespace(source.character(at: meaningfulEnd - 1)) {
            meaningfulEnd -= 1
        }

        var cursor = start
        consumeHorizontalWhitespace(in: source, cursor: &cursor, limit: end)

        // One or more block-quote prefixes can precede a list item.
        while cursor < end, source.character(at: cursor) == 62 { // `>`
            cursor += 1
            consumeHorizontalWhitespace(in: source, cursor: &cursor, limit: end)
        }

        if consumeListMarker(in: source, cursor: &cursor, limit: end) {
            consumeHorizontalWhitespace(in: source, cursor: &cursor, limit: end)
            if cursor + 2 < end,
               source.character(at: cursor) == 91, // `[`
               isTaskState(source.character(at: cursor + 1)),
               source.character(at: cursor + 2) == 93 { // `]`
                let afterTask = cursor + 3
                if afterTask < end,
                   isHorizontalWhitespace(source.character(at: afterTask)) {
                    cursor = afterTask
                    consumeHorizontalWhitespace(in: source, cursor: &cursor, limit: end)
                }
            }
        }

        return LineBounds(
            start: start,
            contentStart: cursor,
            meaningfulEnd: meaningfulEnd,
            end: end
        )
    }

    private static func consumeListMarker(
        in source: NSString,
        cursor: inout Int,
        limit: Int
    ) -> Bool {
        guard cursor < limit else { return false }
        let markerStart = cursor
        let character = source.character(at: cursor)

        if character == 45 || character == 43 || character == 42 { // `-`, `+`, `*`
            cursor += 1
        } else if character >= 48, character <= 57 {
            while cursor < limit {
                let digit = source.character(at: cursor)
                guard digit >= 48, digit <= 57 else { break }
                cursor += 1
            }
            guard cursor < limit else {
                cursor = markerStart
                return false
            }
            let delimiter = source.character(at: cursor)
            guard delimiter == 46 || delimiter == 41 else { // `.`, `)`
                cursor = markerStart
                return false
            }
            cursor += 1
        } else {
            return false
        }

        guard cursor < limit, isHorizontalWhitespace(source.character(at: cursor)) else {
            cursor = markerStart
            return false
        }
        return true
    }

    private enum TokenClass: Equatable {
        case whitespace
        case word
        case symbol
    }

    private static func tokenClass(in range: NSRange, source: NSString) -> TokenClass {
        let value = source.substring(with: range)
        let scalars = value.unicodeScalars
        if scalars.allSatisfy({ CharacterSet.whitespacesAndNewlines.contains($0) }) {
            return .whitespace
        }
        if scalars.contains(where: {
            CharacterSet.alphanumerics.contains($0)
                || CharacterSet.nonBaseCharacters.contains($0)
                || $0.value == 95 // `_`
        }) {
            return .word
        }
        return .symbol
    }

    private static func composedRange(before location: Int, in source: NSString) -> NSRange? {
        guard location > 0 else { return nil }
        return source.rangeOfComposedCharacterSequence(at: location - 1)
    }

    private static func composedRange(at location: Int, in source: NSString) -> NSRange? {
        guard location < source.length else { return nil }
        return source.rangeOfComposedCharacterSequence(at: location)
    }

    private static func consumeHorizontalWhitespace(
        in source: NSString,
        cursor: inout Int,
        limit: Int
    ) {
        while cursor < limit, isHorizontalWhitespace(source.character(at: cursor)) {
            cursor += 1
        }
    }

    private static func isHorizontalWhitespace(_ character: unichar) -> Bool {
        character == 32 || character == 9
    }

    private static func isNewline(_ character: unichar) -> Bool {
        character == 10 || character == 13
    }

    private static func isTaskState(_ character: unichar) -> Bool {
        character == 32 || character == 120 || character == 88
    }

    private static func clamped(_ location: Int, to length: Int) -> Int {
        min(max(location, 0), length)
    }
}

/// Applies semantic destinations to the standard macOS key-binding selectors.
/// Shift variants share the same destinations and preserve an explicit anchor,
/// so reversing direction shrinks a selection naturally.
@MainActor
final class MarkdownNavigationTextView: MarkdownTextView {
    private enum Direction {
        case backward
        case forward
    }

    private var navigationAnchor: Int?
    private var navigationFocus: Int?

    var selectionFocusLocation: Int {
        let selection = selectedRange()
        if let navigationAnchor,
           let navigationFocus,
           selection.location == min(navigationAnchor, navigationFocus),
           NSMaxRange(selection) == max(navigationAnchor, navigationFocus) {
            return navigationFocus
        }
        return selection.length == 0 ? selection.location : NSMaxRange(selection)
    }

    override func didChangeText() {
        navigationAnchor = nil
        navigationFocus = nil
        super.didChangeText()
    }

    override func moveToBeginningOfLine(_ sender: Any?) {
        navigate(direction: .backward, modifyingSelection: false) {
            MarkdownEditorNavigation.beginningOfLine(in: self.string, from: $0)
        }
    }

    override func moveToBeginningOfLineAndModifySelection(_ sender: Any?) {
        navigate(direction: .backward, modifyingSelection: true) {
            MarkdownEditorNavigation.beginningOfLine(in: self.string, from: $0)
        }
    }

    override func moveToEndOfLine(_ sender: Any?) {
        navigate(direction: .forward, modifyingSelection: false) {
            MarkdownEditorNavigation.endOfLine(in: self.string, from: $0)
        }
    }

    override func moveToEndOfLineAndModifySelection(_ sender: Any?) {
        navigate(direction: .forward, modifyingSelection: true) {
            MarkdownEditorNavigation.endOfLine(in: self.string, from: $0)
        }
    }

    override func moveWordBackward(_ sender: Any?) {
        moveWordBackwardSemantic(modifyingSelection: false)
    }

    override func moveWordBackwardAndModifySelection(_ sender: Any?) {
        moveWordBackwardSemantic(modifyingSelection: true)
    }

    override func moveWordLeft(_ sender: Any?) {
        moveWordBackwardSemantic(modifyingSelection: false)
    }

    override func moveWordLeftAndModifySelection(_ sender: Any?) {
        moveWordBackwardSemantic(modifyingSelection: true)
    }

    override func moveWordForward(_ sender: Any?) {
        moveWordForwardSemantic(modifyingSelection: false)
    }

    override func moveWordForwardAndModifySelection(_ sender: Any?) {
        moveWordForwardSemantic(modifyingSelection: true)
    }

    override func moveWordRight(_ sender: Any?) {
        moveWordForwardSemantic(modifyingSelection: false)
    }

    override func moveWordRightAndModifySelection(_ sender: Any?) {
        moveWordForwardSemantic(modifyingSelection: true)
    }

    override func moveToBeginningOfDocument(_ sender: Any?) {
        navigate(direction: .backward, modifyingSelection: false) {
            MarkdownEditorNavigation.beginningOfDocument(in: self.string, from: $0)
        }
    }

    override func moveToBeginningOfDocumentAndModifySelection(_ sender: Any?) {
        navigate(direction: .backward, modifyingSelection: true) {
            MarkdownEditorNavigation.beginningOfDocument(in: self.string, from: $0)
        }
    }

    override func moveToEndOfDocument(_ sender: Any?) {
        navigate(direction: .forward, modifyingSelection: false) {
            MarkdownEditorNavigation.endOfDocument(in: self.string, from: $0)
        }
    }

    override func moveToEndOfDocumentAndModifySelection(_ sender: Any?) {
        navigate(direction: .forward, modifyingSelection: true) {
            MarkdownEditorNavigation.endOfDocument(in: self.string, from: $0)
        }
    }

    private func moveWordBackwardSemantic(modifyingSelection: Bool) {
        navigate(direction: .backward, modifyingSelection: modifyingSelection) {
            MarkdownEditorNavigation.wordBackward(in: self.string, from: $0)
        }
    }

    private func moveWordForwardSemantic(modifyingSelection: Bool) {
        navigate(direction: .forward, modifyingSelection: modifyingSelection) {
            MarkdownEditorNavigation.wordForward(in: self.string, from: $0)
        }
    }

    private func navigate(
        direction: Direction,
        modifyingSelection: Bool,
        destination: (Int) -> Int
    ) {
        let selection = selectedRange()

        if !modifyingSelection {
            navigationAnchor = nil
            navigationFocus = nil
            let startingPoint = direction == .backward
                ? selection.location
                : NSMaxRange(selection)
            let target = destination(startingPoint)
            setSelectedRange(NSRange(location: target, length: 0))
            scrollRangeToVisible(NSRange(location: target, length: 0))
            return
        }

        let anchor: Int
        let focus: Int
        if let trackedAnchor = navigationAnchor,
           let trackedFocus = navigationFocus,
           selection.location == min(trackedAnchor, trackedFocus),
           NSMaxRange(selection) == max(trackedAnchor, trackedFocus) {
            anchor = trackedAnchor
            focus = trackedFocus
        } else if selection.length == 0 {
            anchor = selection.location
            focus = selection.location
        } else if direction == .backward {
            anchor = NSMaxRange(selection)
            focus = selection.location
        } else {
            anchor = selection.location
            focus = NSMaxRange(selection)
        }

        let target = destination(focus)
        navigationAnchor = anchor
        navigationFocus = target
        setSelectedRange(NSRange(
            location: min(anchor, target),
            length: abs(target - anchor)
        ))
        scrollRangeToVisible(NSRange(location: target, length: 0))
    }
}
