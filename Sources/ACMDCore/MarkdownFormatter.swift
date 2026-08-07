import Foundation

/// Formatting operations supported by the Markdown editor.
public enum MarkdownFormatCommand: Equatable, Sendable {
    case bold
    case italic
    case strikethrough
    case inlineCode
    case link
    case image
    case heading(Int)
    case unorderedList
    case orderedList
    case taskList
    case blockQuote
    case codeBlock
    case horizontalRule
}

/// The text and UTF-16 selection produced by a formatting operation.
public struct MarkdownEditResult: Equatable, Sendable {
    public var text: String
    public var selection: NSRange

    public init(text: String, selection: NSRange) {
        self.text = text
        self.selection = selection
    }
}

/// Pure, selection-aware Markdown editing operations.
public enum MarkdownFormatter {
    public static func apply(
        command: MarkdownFormatCommand,
        to text: String,
        selection proposedSelection: NSRange
    ) -> MarkdownEditResult {
        let source = text as NSString
        let selection = normalized(proposedSelection, in: source)

        switch command {
        case .bold:
            return toggleWrapper("**", in: source, selection: selection, disallowAdjacentMarker: false)
        case .italic:
            return toggleWrapper("*", in: source, selection: selection, disallowAdjacentMarker: true)
        case .strikethrough:
            return toggleWrapper("~~", in: source, selection: selection, disallowAdjacentMarker: false)
        case .inlineCode:
            return toggleInlineCode(in: source, selection: selection)
        case .link:
            return toggleLink(in: source, selection: selection, image: false)
        case .image:
            return toggleLink(in: source, selection: selection, image: true)
        case let .heading(level):
            return toggleHeading(level: min(max(level, 1), 6), in: source, selection: selection)
        case .unorderedList:
            return toggleList(.unordered, in: source, selection: selection)
        case .orderedList:
            return toggleList(.ordered, in: source, selection: selection)
        case .taskList:
            return toggleList(.task, in: source, selection: selection)
        case .blockQuote:
            return toggleBlockQuote(in: source, selection: selection)
        case .codeBlock:
            return toggleCodeBlock(in: source, selection: selection)
        case .horizontalRule:
            return toggleHorizontalRule(in: source, selection: selection)
        }
    }
}

// MARK: - Inline formatting

private extension MarkdownFormatter {
    static func toggleWrapper(
        _ marker: String,
        in source: NSString,
        selection: NSRange,
        disallowAdjacentMarker: Bool
    ) -> MarkdownEditResult {
        if selection.length > 0 {
            let contentRange = trimmingBoundaryWhitespace(from: selection, in: source)
            guard contentRange.length > 0 else {
                return MarkdownEditResult(text: source as String, selection: selection)
            }
            if contentRange != selection {
                return toggleWrapper(
                    marker,
                    in: source,
                    selection: contentRange,
                    disallowAdjacentMarker: disallowAdjacentMarker
                )
            }
        }

        let markerLength = (marker as NSString).length
        let selected = source.substring(with: selection) as NSString

        if selection.length >= markerLength * 2,
           selected.substring(with: NSRange(location: 0, length: markerLength)) == marker,
           selected.substring(with: NSRange(location: selected.length - markerLength, length: markerLength)) == marker,
           !invalidSingleMarkerBoundary(
               in: selected,
               leftMarkerLocation: 0,
               rightMarkerLocation: selected.length - markerLength,
               marker: marker,
               disallowAdjacentMarker: disallowAdjacentMarker
           ) {
            let innerRange = NSRange(
                location: markerLength,
                length: selected.length - markerLength * 2
            )
            let inner = selected.substring(with: innerRange)
            return replacing(
                selection,
                with: inner,
                in: source,
                selection: NSRange(location: selection.location, length: innerRange.length)
            )
        }

        let end = NSMaxRange(selection)
        if selection.location >= markerLength,
           end + markerLength <= source.length,
           source.substring(with: NSRange(location: selection.location - markerLength, length: markerLength)) == marker,
           source.substring(with: NSRange(location: end, length: markerLength)) == marker,
           !invalidSingleMarkerBoundary(
               in: source,
               leftMarkerLocation: selection.location - markerLength,
               rightMarkerLocation: end,
               marker: marker,
               disallowAdjacentMarker: disallowAdjacentMarker
           ) {
            let edits = [
                TextEdit(range: NSRange(location: selection.location - markerLength, length: markerLength), replacement: ""),
                TextEdit(range: NSRange(location: end, length: markerLength), replacement: "")
            ]
            let result = applying(edits, to: source)
            return MarkdownEditResult(
                text: result,
                selection: NSRange(location: selection.location - markerLength, length: selection.length)
            )
        }

        let replacement = marker + selected.description + marker
        return replacing(
            selection,
            with: replacement,
            in: source,
            selection: NSRange(
                location: selection.location + markerLength,
                length: selection.length
            )
        )
    }

    static func invalidSingleMarkerBoundary(
        in source: NSString,
        leftMarkerLocation: Int,
        rightMarkerLocation: Int,
        marker: String,
        disallowAdjacentMarker: Bool
    ) -> Bool {
        guard disallowAdjacentMarker, marker == "*" else { return false }
        let asterisk = unichar(42)
        let afterLeft = leftMarkerLocation + 1
        return (leftMarkerLocation > 0 && source.character(at: leftMarkerLocation - 1) == asterisk)
            || (afterLeft < source.length && afterLeft != rightMarkerLocation && source.character(at: afterLeft) == asterisk)
            || (rightMarkerLocation > 0 && rightMarkerLocation - 1 != leftMarkerLocation && source.character(at: rightMarkerLocation - 1) == asterisk)
            || (rightMarkerLocation + 1 < source.length && source.character(at: rightMarkerLocation + 1) == asterisk)
    }

    static func toggleInlineCode(in source: NSString, selection: NSRange) -> MarkdownEditResult {
        let selected = source.substring(with: selection) as NSString

        if let inner = inlineCodeInnerRange(in: selected) {
            let replacement = selected.substring(with: inner)
            return replacing(
                selection,
                with: replacement,
                in: source,
                selection: NSRange(location: selection.location, length: inner.length)
            )
        }

        let end = NSMaxRange(selection)
        let hasPadding = selection.location > 0
            && end < source.length
            && source.character(at: selection.location - 1) == unichar(32)
            && source.character(at: end) == unichar(32)
        let leftBoundary = selection.location - (hasPadding ? 1 : 0)
        let rightBoundary = end + (hasPadding ? 1 : 0)
        let leftRun = backwardRun(of: unichar(96), endingAt: leftBoundary, in: source)
        let rightRun = forwardRun(of: unichar(96), startingAt: rightBoundary, in: source)
        if leftRun > 0, leftRun == rightRun {
            let edits = [
                TextEdit(
                    range: NSRange(
                        location: leftBoundary - leftRun,
                        length: leftRun + (hasPadding ? 1 : 0)
                    ),
                    replacement: ""
                ),
                TextEdit(
                    range: NSRange(
                        location: end,
                        length: rightRun + (hasPadding ? 1 : 0)
                    ),
                    replacement: ""
                )
            ]
            return MarkdownEditResult(
                text: applying(edits, to: source),
                selection: NSRange(
                    location: leftBoundary - leftRun,
                    length: selection.length
                )
            )
        }

        let delimiterLength = max(1, longestRun(of: unichar(96), in: selected) + 1)
        let delimiter = String(repeating: "`", count: delimiterLength)
        let needsPadding = selected.length > 0
            && (selected.character(at: 0) == unichar(96)
                || selected.character(at: selected.length - 1) == unichar(96))
        let padding = needsPadding ? " " : ""
        return replacing(
            selection,
            with: delimiter + padding + selected.description + padding + delimiter,
            in: source,
            selection: NSRange(
                location: selection.location + delimiterLength + (needsPadding ? 1 : 0),
                length: selection.length
            )
        )
    }

    static func inlineCodeInnerRange(in value: NSString) -> NSRange? {
        let opening = forwardRun(of: unichar(96), startingAt: 0, in: value)
        guard opening > 0, value.length >= opening * 2 else { return nil }
        let closing = backwardRun(of: unichar(96), endingAt: value.length, in: value)
        guard opening == closing else { return nil }
        var inner = NSRange(location: opening, length: value.length - opening - closing)
        if inner.length >= 2,
           value.character(at: inner.location) == unichar(32),
           value.character(at: NSMaxRange(inner) - 1) == unichar(32) {
            let candidate = value.substring(
                with: NSRange(location: inner.location + 1, length: inner.length - 2)
            )
            if candidate.contains(where: { !$0.isWhitespace }) {
                inner = NSRange(location: inner.location + 1, length: inner.length - 2)
            }
        }
        return inner
    }

    static func toggleLink(in source: NSString, selection: NSRange, image: Bool) -> MarkdownEditResult {
        let selected = source.substring(with: selection) as NSString
        if let label = completeLinkLabel(in: selected, image: image) {
            let replacement = selected.substring(with: label)
            return replacing(
                selection,
                with: replacement,
                in: source,
                selection: NSRange(location: selection.location, length: label.length)
            )
        }

        let prefix = image ? "![" : "["
        let prefixLength = (prefix as NSString).length
        let end = NSMaxRange(selection)
        if selection.location >= prefixLength,
           source.substring(with: NSRange(location: selection.location - prefixLength, length: prefixLength)) == prefix,
           (!image ? selection.location - prefixLength == 0 || source.character(at: selection.location - prefixLength - 1) != unichar(33) : true),
           let suffixEnd = inlineLinkSuffixEnd(startingAt: end, in: source) {
            let edits = [
                TextEdit(range: NSRange(location: selection.location - prefixLength, length: prefixLength), replacement: ""),
                TextEdit(range: NSRange(location: end, length: suffixEnd - end), replacement: "")
            ]
            return MarkdownEditResult(
                text: applying(edits, to: source),
                selection: NSRange(location: selection.location - prefixLength, length: selection.length)
            )
        }

        let label: String
        if selection.length == 0 {
            label = image ? "alt text" : "link text"
        } else {
            label = selected.description
        }
        let replacement = prefix + label + "](url)"
        return replacing(
            selection,
            with: replacement,
            in: source,
            selection: NSRange(location: selection.location + prefixLength, length: (label as NSString).length)
        )
    }

    static func completeLinkLabel(in value: NSString, image: Bool) -> NSRange? {
        let prefixLength = image ? 2 : 1
        guard value.length >= prefixLength + 3 else { return nil }
        if image {
            guard value.character(at: 0) == unichar(33), value.character(at: 1) == unichar(91) else { return nil }
        } else {
            guard value.character(at: 0) == unichar(91) else { return nil }
        }

        let labelStart = prefixLength
        guard let labelEnd = closingBracket(startingAt: labelStart, in: value),
              labelEnd + 1 < value.length,
              value.character(at: labelEnd + 1) == unichar(40),
              let linkEnd = closingParenthesis(startingAt: labelEnd + 2, in: value),
              linkEnd == value.length - 1 else {
            return nil
        }
        return NSRange(location: labelStart, length: labelEnd - labelStart)
    }

    static func inlineLinkSuffixEnd(startingAt location: Int, in source: NSString) -> Int? {
        guard location + 1 < source.length,
              source.character(at: location) == unichar(93),
              source.character(at: location + 1) == unichar(40),
              let closing = closingParenthesis(startingAt: location + 2, in: source) else {
            return nil
        }
        return closing + 1
    }
}

// MARK: - Line formatting

private extension MarkdownFormatter {
    enum ListStyle {
        case unordered
        case ordered
        case task
    }

    struct PrefixMatch {
        var range: NSRange
        var style: ListStyle?
        var headingLevel: Int?
    }

    struct ListLineContext {
        var scope: ListScope
        var insertionLocation: Int
        var match: PrefixMatch?
    }

    struct ListScope: Hashable {
        var quoteDepth: Int
        var indentationColumns: Int
    }

    static func toggleHeading(level: Int, in source: NSString, selection: NSRange) -> MarkdownEditResult {
        let lines = affectedLines(in: source, selection: selection)
        let matches = lines.map { headingPrefix(in: source, line: $0) }
        let allMatch = matches.allSatisfy { $0?.headingLevel == level }
        var edits: [TextEdit] = []

        for (line, match) in zip(lines, matches) {
            if allMatch, let match {
                edits.append(TextEdit(range: match.range, replacement: ""))
            } else if !allMatch {
                let replacement = String(repeating: "#", count: level) + " "
                if let match {
                    edits.append(TextEdit(range: match.range, replacement: replacement))
                } else {
                    edits.append(TextEdit(
                        range: NSRange(location: line.location + indentationLength(in: source, line: line), length: 0),
                        replacement: replacement
                    ))
                }
            }
        }
        return result(applying: edits, to: source, selection: selection)
    }

    static func toggleList(_ style: ListStyle, in source: NSString, selection: NSRange) -> MarkdownEditResult {
        let lines = affectedLines(in: source, selection: selection)
        let contexts = lines.map { listLineContext(in: source, line: $0) }
        let allMatch = contexts.allSatisfy { $0.match?.style == style }
        var orderedCounters: [ListScope: Int] = [:]
        var activeOrderedScopes: [ListScope] = []
        var edits: [TextEdit] = []
        var firstLineContentStart: Int?

        for index in lines.indices {
            let context = contexts[index]
            let match = context.match
            if allMatch, let match {
                let edit = TextEdit(range: match.range, replacement: "")
                edits.append(edit)
                if index == lines.startIndex {
                    firstLineContentStart = edit.range.location
                }
                continue
            }
            guard !allMatch else { continue }
            let replacement: String
            switch style {
            case .unordered:
                replacement = "- "
            case .ordered:
                if let activeIndex = activeOrderedScopes.lastIndex(of: context.scope) {
                    activeOrderedScopes.removeSubrange((activeIndex + 1)..<activeOrderedScopes.endIndex)
                } else {
                    while let active = activeOrderedScopes.last,
                          !isStructuralAncestor(active, of: context.scope) {
                        activeOrderedScopes.removeLast()
                    }
                    activeOrderedScopes.append(context.scope)
                    orderedCounters[context.scope] = 0
                }
                let number = orderedCounters[context.scope, default: 0] + 1
                orderedCounters[context.scope] = number
                replacement = "\(number). "
            case .task:
                replacement = "- [ ] "
            }
            if let match {
                let edit = TextEdit(range: match.range, replacement: replacement)
                edits.append(edit)
                if index == lines.startIndex {
                    firstLineContentStart = edit.range.location + (replacement as NSString).length
                }
            } else {
                let edit = TextEdit(
                    range: NSRange(location: context.insertionLocation, length: 0),
                    replacement: replacement
                )
                edits.append(edit)
                if index == lines.startIndex {
                    firstLineContentStart = edit.range.location + (replacement as NSString).length
                }
            }
        }
        var formatted = result(applying: edits, to: source, selection: selection)
        if selection.length > 0,
           selection.location == lines.first?.location,
           let firstLineContentStart {
            let selectionEnd = NSMaxRange(formatted.selection)
            let contentStart = min(firstLineContentStart, selectionEnd)
            formatted.selection = NSRange(
                location: contentStart,
                length: selectionEnd - contentStart
            )
        }
        return formatted
    }

    static func toggleBlockQuote(in source: NSString, selection: NSRange) -> MarkdownEditResult {
        let lines = affectedLines(in: source, selection: selection)
        let matches = lines.map { blockQuotePrefix(in: source, line: $0) }
        let allMatch = matches.allSatisfy { $0 != nil }
        var edits: [TextEdit] = []

        for (line, match) in zip(lines, matches) {
            if allMatch, let match {
                edits.append(TextEdit(range: match, replacement: ""))
            } else if !allMatch, match == nil {
                edits.append(TextEdit(
                    range: NSRange(location: line.location + indentationLength(in: source, line: line), length: 0),
                    replacement: "> "
                ))
            }
        }
        return result(applying: edits, to: source, selection: selection)
    }

    static func toggleHorizontalRule(in source: NSString, selection: NSRange) -> MarkdownEditResult {
        let lines = affectedLines(in: source, selection: selection)
        if lines.allSatisfy({ isHorizontalRule(source.substring(with: $0)) }) {
            let edits = lines.map { TextEdit(range: $0, replacement: "") }
            return result(applying: edits, to: source, selection: selection)
        }

        let line = selection.length > 0 ? lines[lines.count - 1] : lines[0]
        let contents = source.substring(with: line)
        if contents.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return replacing(
                line,
                with: "---",
                in: source,
                selection: NSRange(location: line.location + 3, length: 0)
            )
        }

        let insertion = "\n\n---"
        return replacing(
            NSRange(location: NSMaxRange(line), length: 0),
            with: insertion,
            in: source,
            selection: NSRange(location: NSMaxRange(line) + (insertion as NSString).length, length: 0)
        )
    }
}

// MARK: - Fenced code blocks

private extension MarkdownFormatter {
    struct Fence {
        var character: unichar
        var length: Int
    }

    static func toggleCodeBlock(in source: NSString, selection: NSRange) -> MarkdownEditResult {
        let selected = source.substring(with: selection) as NSString
        if let fencedContent = fencedInnerRange(in: selected) {
            let replacement = selected.substring(with: fencedContent.range)
                + fencedContent.trailingLineBreaks
            return replacing(
                selection,
                with: replacement,
                in: source,
                selection: NSRange(
                    location: selection.location,
                    length: fencedContent.range.length
                )
            )
        }

        if let external = externalFenceEdits(in: source, selection: selection) {
            return MarkdownEditResult(
                text: applying(external.edits, to: source),
                selection: NSRange(
                    location: external.openingStart,
                    length: selection.length
                )
            )
        }

        if selection.length == 0,
           let containing = MarkdownSyntaxTokenizer.spans(in: source as String).first(where: {
               $0.kind == .codeBlock
                   && selection.location >= $0.range.location
                   && selection.location <= NSMaxRange($0.range)
           }) {
            let block = source.substring(with: containing.range) as NSString
            if let fencedContent = fencedInnerRange(in: block) {
                let replacement = block.substring(with: fencedContent.range)
                    + fencedContent.trailingLineBreaks
                let innerStart = containing.range.location + fencedContent.range.location
                let cursor = containing.range.location
                    + min(max(selection.location - innerStart, 0), fencedContent.range.length)
                return replacing(
                    containing.range,
                    with: replacement,
                    in: source,
                    selection: NSRange(location: cursor, length: 0)
                )
            }
        }

        let delimiterLength = max(3, longestRun(of: unichar(96), in: selected) + 1)
        let delimiter = String(repeating: "`", count: delimiterLength)
        let prefix = delimiter + "\n"
        let suffix = endsInNewline(selected) ? delimiter : "\n" + delimiter
        return replacing(
            selection,
            with: prefix + selected.description + suffix,
            in: source,
            selection: NSRange(
                location: selection.location + (prefix as NSString).length,
                length: selection.length
            )
        )
    }

    struct FencedContent {
        var range: NSRange
        var trailingLineBreaks: String
    }

    static func fencedInnerRange(in value: NSString) -> FencedContent? {
        guard let openingBreak = firstLineBreak(in: value, startingAt: 0) else { return nil }
        let openingLine = value.substring(with: NSRange(location: 0, length: openingBreak.location)) as NSString
        guard let fence = openingFence(in: openingLine) else { return nil }

        let closingEnd = trailingLineContentEnd(in: value)
        let closingStart = lineStart(containing: max(closingEnd - 1, 0), in: value)
        guard closingStart >= NSMaxRange(openingBreak) else { return nil }
        let closingLine = value.substring(with: NSRange(location: closingStart, length: closingEnd - closingStart)) as NSString
        guard isClosingFence(closingLine, for: fence) else { return nil }

        let innerStart = NSMaxRange(openingBreak)
        var innerEnd = closingStart
        if innerEnd > innerStart, value.character(at: innerEnd - 1) == unichar(10) {
            innerEnd -= 1
            if innerEnd > innerStart, value.character(at: innerEnd - 1) == unichar(13) {
                innerEnd -= 1
            }
        } else if innerEnd > innerStart, value.character(at: innerEnd - 1) == unichar(13) {
            innerEnd -= 1
        }
        return FencedContent(
            range: NSRange(location: innerStart, length: max(0, innerEnd - innerStart)),
            trailingLineBreaks: closingEnd < value.length
                ? value.substring(from: closingEnd)
                : ""
        )
    }

    struct ExternalFenceRemoval {
        var edits: [TextEdit]
        var openingStart: Int
    }

    static func externalFenceEdits(in source: NSString, selection: NSRange) -> ExternalFenceRemoval? {
        guard selection.location > 0 else { return nil }
        let openingBreakEnd = selection.location
        var openingBreakStart = openingBreakEnd
        if openingBreakStart > 0, source.character(at: openingBreakStart - 1) == unichar(10) {
            openingBreakStart -= 1
            if openingBreakStart > 0, source.character(at: openingBreakStart - 1) == unichar(13) {
                openingBreakStart -= 1
            }
        } else if openingBreakStart > 0, source.character(at: openingBreakStart - 1) == unichar(13) {
            openingBreakStart -= 1
        } else {
            return nil
        }

        let openingStart = lineStart(containing: max(openingBreakStart - 1, 0), in: source)
        let openingLine = source.substring(with: NSRange(location: openingStart, length: openingBreakStart - openingStart)) as NSString
        guard let fence = openingFence(in: openingLine) else { return nil }

        let selectionEnd = NSMaxRange(selection)
        var closingStart = selectionEnd
        if !endsInNewline(source.substring(with: selection) as NSString) {
            guard closingStart < source.length else { return nil }
            if source.character(at: closingStart) == unichar(13) {
                closingStart += 1
                if closingStart < source.length, source.character(at: closingStart) == unichar(10) {
                    closingStart += 1
                }
            } else if source.character(at: closingStart) == unichar(10) {
                closingStart += 1
            } else {
                return nil
            }
        }
        let closingContentEnd = lineContentEnd(startingAt: closingStart, in: source)
        let closingLine = source.substring(with: NSRange(location: closingStart, length: closingContentEnd - closingStart)) as NSString
        guard isClosingFence(closingLine, for: fence) else { return nil }

        return ExternalFenceRemoval(
            edits: [
                TextEdit(range: NSRange(location: openingStart, length: selection.location - openingStart), replacement: ""),
                TextEdit(range: NSRange(location: selectionEnd, length: closingContentEnd - selectionEnd), replacement: "")
            ],
            openingStart: openingStart
        )
    }

    static func openingFence(in line: NSString) -> Fence? {
        var index = 0
        while index < line.length, index < 3, line.character(at: index) == unichar(32) {
            index += 1
        }
        guard index < line.length else { return nil }
        let character = line.character(at: index)
        guard character == unichar(96) || character == unichar(126) else { return nil }
        let count = forwardRun(of: character, startingAt: index, in: line)
        guard count >= 3 else { return nil }
        if character == unichar(96) {
            var cursor = index + count
            while cursor < line.length {
                if line.character(at: cursor) == character { return nil }
                cursor += 1
            }
        }
        return Fence(character: character, length: count)
    }

    static func isClosingFence(_ line: NSString, for fence: Fence) -> Bool {
        var index = 0
        while index < line.length, index < 3, line.character(at: index) == unichar(32) {
            index += 1
        }
        let count = forwardRun(of: fence.character, startingAt: index, in: line)
        guard count >= fence.length else { return false }
        index += count
        while index < line.length {
            let character = line.character(at: index)
            guard character == unichar(32) || character == unichar(9) else { return false }
            index += 1
        }
        return true
    }
}

// MARK: - Text primitives

private extension MarkdownFormatter {
    struct TextEdit {
        var range: NSRange
        var replacement: String
    }

    enum Affinity {
        case before
        case after
    }

    static func normalized(_ range: NSRange, in source: NSString) -> NSRange {
        guard range.location != NSNotFound else {
            return NSRange(location: source.length, length: 0)
        }
        let location = min(max(range.location, 0), source.length)
        let available = source.length - location
        let length = min(max(range.length, 0), available)
        return NSRange(location: location, length: length)
    }

    static func trimmingBoundaryWhitespace(from range: NSRange, in source: NSString) -> NSRange {
        var start = range.location
        var end = NSMaxRange(range)
        while start < end,
              isBoundaryWhitespace(source.character(at: start)) {
            start += 1
        }
        while end > start,
              isBoundaryWhitespace(source.character(at: end - 1)) {
            end -= 1
        }
        return NSRange(location: start, length: end - start)
    }

    static func isBoundaryWhitespace(_ character: unichar) -> Bool {
        guard let scalar = UnicodeScalar(character) else { return false }
        return CharacterSet.whitespacesAndNewlines.contains(scalar)
    }

    static func replacing(
        _ range: NSRange,
        with replacement: String,
        in source: NSString,
        selection: NSRange
    ) -> MarkdownEditResult {
        let mutable = NSMutableString(string: source)
        mutable.replaceCharacters(in: range, with: replacement)
        return MarkdownEditResult(text: mutable as String, selection: selection)
    }

    static func applying(_ edits: [TextEdit], to source: NSString) -> String {
        let mutable = NSMutableString(string: source)
        for edit in edits.sorted(by: { $0.range.location > $1.range.location }) {
            mutable.replaceCharacters(in: edit.range, with: edit.replacement)
        }
        return mutable as String
    }

    static func result(applying edits: [TextEdit], to source: NSString, selection: NSRange) -> MarkdownEditResult {
        let sorted = edits.sorted { lhs, rhs in
            lhs.range.location == rhs.range.location
                ? lhs.range.length < rhs.range.length
                : lhs.range.location < rhs.range.location
        }
        let start = mapped(selection.location, through: sorted, affinity: .after)
        let oldEnd = NSMaxRange(selection)
        let end = mapped(oldEnd, through: sorted, affinity: selection.length == 0 ? .after : .before)
        return MarkdownEditResult(
            text: applying(sorted, to: source),
            selection: NSRange(location: start, length: max(0, end - start))
        )
    }

    static func mapped(_ offset: Int, through edits: [TextEdit], affinity: Affinity) -> Int {
        var delta = 0
        for edit in edits {
            let start = edit.range.location
            let end = NSMaxRange(edit.range)
            let replacementLength = (edit.replacement as NSString).length
            if offset < start { break }
            if edit.range.length == 0 {
                if offset == start {
                    if affinity == .after { delta += replacementLength }
                } else {
                    delta += replacementLength
                }
                continue
            }
            if offset == start {
                return start + delta + (affinity == .after ? replacementLength : 0)
            }
            if offset < end {
                return start + delta + min(offset - start, replacementLength)
            }
            if offset == end {
                return start + delta + replacementLength
            }
            delta += replacementLength - edit.range.length
        }
        return offset + delta
    }

    static func affectedLines(in source: NSString, selection: NSRange) -> [NSRange] {
        let effectiveEnd = selection.length == 0
            ? selection.location
            : max(selection.location, NSMaxRange(selection) - 1)
        let firstStart = lineStart(containing: selection.location, in: source)
        let lastStart = lineStart(containing: effectiveEnd, in: source)
        var result: [NSRange] = []
        var start = firstStart

        while true {
            let end = lineContentEnd(startingAt: start, in: source)
            result.append(NSRange(location: start, length: end - start))
            if start >= lastStart || end >= source.length { break }
            start = end
            if start < source.length, source.character(at: start) == unichar(13) {
                start += 1
                if start < source.length, source.character(at: start) == unichar(10) { start += 1 }
            } else if start < source.length, source.character(at: start) == unichar(10) {
                start += 1
            }
            if start > lastStart { break }
        }
        return result.isEmpty ? [NSRange(location: selection.location, length: 0)] : result
    }

    static func lineStart(containing offset: Int, in source: NSString) -> Int {
        var index = min(max(offset, 0), source.length)
        while index > 0 {
            let previous = source.character(at: index - 1)
            if previous == unichar(10) || previous == unichar(13) { break }
            index -= 1
        }
        return index
    }

    static func lineContentEnd(startingAt start: Int, in source: NSString) -> Int {
        var index = min(max(start, 0), source.length)
        while index < source.length {
            let character = source.character(at: index)
            if character == unichar(10) || character == unichar(13) { break }
            index += 1
        }
        return index
    }

    static func indentationLength(in source: NSString, line: NSRange) -> Int {
        var length = 0
        while length < line.length {
            let character = source.character(at: line.location + length)
            guard character == unichar(32) || character == unichar(9) else { break }
            length += 1
        }
        return length
    }

    static func headingPrefix(in source: NSString, line: NSRange) -> PrefixMatch? {
        let indentation = indentationLength(in: source, line: line)
        guard indentation <= 3 else { return nil }
        var cursor = line.location + indentation
        let markerStart = cursor
        while cursor < NSMaxRange(line), source.character(at: cursor) == unichar(35), cursor - markerStart < 6 {
            cursor += 1
        }
        let level = cursor - markerStart
        guard level > 0 else { return nil }
        if cursor < NSMaxRange(line) {
            guard source.character(at: cursor) == unichar(32) || source.character(at: cursor) == unichar(9) else { return nil }
            while cursor < NSMaxRange(line) {
                let character = source.character(at: cursor)
                guard character == unichar(32) || character == unichar(9) else { break }
                cursor += 1
            }
        }
        return PrefixMatch(
            range: NSRange(location: markerStart, length: cursor - markerStart),
            style: nil,
            headingLevel: level
        )
    }

    static func listLineContext(in source: NSString, line: NSRange) -> ListLineContext {
        var cursor = line.location
        let end = NSMaxRange(line)
        let initialWhitespaceStart = cursor

        while cursor < end, isHorizontalWhitespace(source.character(at: cursor)) {
            cursor += 1
        }

        var quoteDepth = 0
        var indentationStart = initialWhitespaceStart
        let leadingIndentation = indentationColumns(in: source.substring(with: NSRange(
            location: initialWhitespaceStart,
            length: cursor - initialWhitespaceStart
        )))
        if leadingIndentation <= 3,
           cursor < end,
           source.character(at: cursor) == unichar(62) {
            indentationStart = cursor
            while cursor < end, source.character(at: cursor) == unichar(62) {
                quoteDepth += 1
                cursor += 1
                if cursor < end, isHorizontalWhitespace(source.character(at: cursor)) {
                    cursor += 1
                }
                indentationStart = cursor
                while cursor < end, isHorizontalWhitespace(source.character(at: cursor)) {
                    cursor += 1
                }
                let nestedIndentation = indentationColumns(in: source.substring(with: NSRange(
                    location: indentationStart,
                    length: cursor - indentationStart
                )))
                if cursor >= end
                    || source.character(at: cursor) != unichar(62)
                    || nestedIndentation > 3 {
                    break
                }
            }
        }

        let indentationRange = NSRange(location: indentationStart, length: cursor - indentationStart)
        let context = ListLineContext(
            scope: ListScope(
                quoteDepth: quoteDepth,
                indentationColumns: indentationColumns(in: source.substring(with: indentationRange))
            ),
            insertionLocation: cursor,
            match: nil
        )
        guard cursor < end else { return context }
        let markerStart = cursor
        let first = source.character(at: cursor)

        if first == unichar(45) || first == unichar(43) || first == unichar(42) {
            cursor += 1
            let whitespaceStart = cursor
            while cursor < end, isHorizontalWhitespace(source.character(at: cursor)) { cursor += 1 }
            guard cursor > whitespaceStart || cursor == end else { return context }
            if cursor + 2 < end,
               source.character(at: cursor) == unichar(91),
               (source.character(at: cursor + 1) == unichar(32)
                   || source.character(at: cursor + 1) == unichar(120)
                   || source.character(at: cursor + 1) == unichar(88)),
               source.character(at: cursor + 2) == unichar(93) {
                cursor += 3
                guard cursor == end || isHorizontalWhitespace(source.character(at: cursor)) else { return context }
                while cursor < end, isHorizontalWhitespace(source.character(at: cursor)) { cursor += 1 }
                return ListLineContext(
                    scope: context.scope,
                    insertionLocation: context.insertionLocation,
                    match: PrefixMatch(
                        range: NSRange(location: markerStart, length: cursor - markerStart),
                        style: .task,
                        headingLevel: nil
                    )
                )
            }
            return ListLineContext(
                scope: context.scope,
                insertionLocation: context.insertionLocation,
                match: PrefixMatch(
                    range: NSRange(location: markerStart, length: cursor - markerStart),
                    style: .unordered,
                    headingLevel: nil
                )
            )
        }

        guard first >= unichar(48), first <= unichar(57) else { return context }
        while cursor < end {
            let character = source.character(at: cursor)
            guard character >= unichar(48), character <= unichar(57) else { break }
            cursor += 1
        }
        guard cursor < end,
              source.character(at: cursor) == unichar(46) || source.character(at: cursor) == unichar(41) else {
            return context
        }
        cursor += 1
        let whitespaceStart = cursor
        while cursor < end, isHorizontalWhitespace(source.character(at: cursor)) { cursor += 1 }
        guard cursor > whitespaceStart || cursor == end else { return context }
        return ListLineContext(
            scope: context.scope,
            insertionLocation: context.insertionLocation,
            match: PrefixMatch(
                range: NSRange(location: markerStart, length: cursor - markerStart),
                style: .ordered,
                headingLevel: nil
            )
        )
    }

    static func isStructuralAncestor(_ ancestor: ListScope, of descendant: ListScope) -> Bool {
        if ancestor.quoteDepth == descendant.quoteDepth {
            return ancestor.indentationColumns < descendant.indentationColumns
        }
        return ancestor.quoteDepth > 0 && ancestor.quoteDepth < descendant.quoteDepth
    }

    static func indentationColumns(in indentation: String) -> Int {
        var columns = 0
        for character in indentation.utf16 {
            if character == unichar(9) {
                columns += 4 - (columns % 4)
            } else {
                columns += 1
            }
        }
        return columns
    }

    static func blockQuotePrefix(in source: NSString, line: NSRange) -> NSRange? {
        let indentation = indentationLength(in: source, line: line)
        guard indentation <= 3 else { return nil }
        let marker = line.location + indentation
        guard marker < NSMaxRange(line), source.character(at: marker) == unichar(62) else { return nil }
        var length = 1
        if marker + 1 < NSMaxRange(line), isHorizontalWhitespace(source.character(at: marker + 1)) {
            length += 1
        }
        return NSRange(location: marker, length: length)
    }

    static func isHorizontalRule(_ line: String) -> Bool {
        let value = line as NSString
        var marker: unichar?
        var count = 0
        for index in 0..<value.length {
            let character = value.character(at: index)
            if isHorizontalWhitespace(character) { continue }
            guard character == unichar(45) || character == unichar(42) || character == unichar(95) else { return false }
            if let marker, marker != character { return false }
            marker = character
            count += 1
        }
        return count >= 3
    }

    static func isHorizontalWhitespace(_ character: unichar) -> Bool {
        character == unichar(32) || character == unichar(9)
    }

    static func forwardRun(of character: unichar, startingAt start: Int, in source: NSString) -> Int {
        guard start >= 0, start <= source.length else { return 0 }
        var cursor = start
        while cursor < source.length, source.character(at: cursor) == character { cursor += 1 }
        return cursor - start
    }

    static func backwardRun(of character: unichar, endingAt end: Int, in source: NSString) -> Int {
        guard end >= 0, end <= source.length else { return 0 }
        var cursor = end
        while cursor > 0, source.character(at: cursor - 1) == character { cursor -= 1 }
        return end - cursor
    }

    static func longestRun(of character: unichar, in source: NSString) -> Int {
        var longest = 0
        var cursor = 0
        while cursor < source.length {
            if source.character(at: cursor) == character {
                let count = forwardRun(of: character, startingAt: cursor, in: source)
                longest = max(longest, count)
                cursor += count
            } else {
                cursor += 1
            }
        }
        return longest
    }

    static func closingBracket(startingAt start: Int, in source: NSString) -> Int? {
        var depth = 0
        var cursor = start
        while cursor < source.length {
            let character = source.character(at: cursor)
            if character == unichar(92) { cursor += 2; continue }
            if character == unichar(91) { depth += 1 }
            if character == unichar(93) {
                if depth == 0 { return cursor }
                depth -= 1
            }
            cursor += 1
        }
        return nil
    }

    static func closingParenthesis(startingAt start: Int, in source: NSString) -> Int? {
        var depth = 0
        var cursor = start
        while cursor < source.length {
            let character = source.character(at: cursor)
            if character == unichar(92) { cursor += 2; continue }
            if character == unichar(40) { depth += 1 }
            if character == unichar(41) {
                if depth == 0 { return cursor }
                depth -= 1
            }
            if character == unichar(10) || character == unichar(13) { return nil }
            cursor += 1
        }
        return nil
    }

    static func endsInNewline(_ value: NSString) -> Bool {
        guard value.length > 0 else { return false }
        let character = value.character(at: value.length - 1)
        return character == unichar(10) || character == unichar(13)
    }

    static func firstLineBreak(in source: NSString, startingAt start: Int) -> NSRange? {
        var cursor = start
        while cursor < source.length {
            let character = source.character(at: cursor)
            if character == unichar(13) {
                let length = cursor + 1 < source.length && source.character(at: cursor + 1) == unichar(10) ? 2 : 1
                return NSRange(location: cursor, length: length)
            }
            if character == unichar(10) { return NSRange(location: cursor, length: 1) }
            cursor += 1
        }
        return nil
    }

    static func trailingLineContentEnd(in source: NSString) -> Int {
        var end = source.length
        while end > 0 {
            let character = source.character(at: end - 1)
            guard character == unichar(10) || character == unichar(13) else { break }
            end -= 1
        }
        return end
    }
}
