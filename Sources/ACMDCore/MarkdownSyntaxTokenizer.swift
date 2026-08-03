import Foundation

/// Semantic Markdown constructs recognized by ``MarkdownSyntaxTokenizer``.
public enum MarkdownSyntaxKind: String, CaseIterable, Hashable, Sendable {
    case heading
    case strong
    case emphasis
    case strikethrough
    case inlineCode
    case codeBlock
    case link
    case image
    case blockQuote
    case listMarker
    case taskMarker
    case horizontalRule
}

/// A semantic Markdown construct located in a UTF-16 text range.
public struct MarkdownSyntaxSpan: Equatable, Hashable, Sendable {
    public let range: NSRange
    public let kind: MarkdownSyntaxKind

    public init(range: NSRange, kind: MarkdownSyntaxKind) {
        self.range = range
        self.kind = kind
    }
}

/// A lightweight tokenizer intended for editor syntax highlighting.
///
/// It is deliberately not a Markdown renderer. It recognizes the constructs an
/// editor needs to style while masking fenced and inline code from other rules.
public enum MarkdownSyntaxTokenizer {
    public typealias Span = MarkdownSyntaxSpan

    public static func spans(in text: String) -> [MarkdownSyntaxSpan] {
        let source = text as NSString
        guard source.length > 0 else { return [] }
        let lines = lineRanges(in: source)

        let codeBlocks = fencedCodeSpans(in: source, lines: lines)
        var result = codeBlocks
        let blockMasks = codeBlocks.map(\.range)

        let inlineCode = inlineCodeSpans(in: source, excluding: blockMasks)
        result.append(contentsOf: inlineCode)
        let codeMasks = blockMasks + inlineCode.map(\.range)

        result.append(contentsOf: linkSpans(in: source, excluding: codeMasks))
        result.append(contentsOf: lineSpans(in: source, lines: lines, excluding: blockMasks))
        result.append(contentsOf: emphasisSpans(in: source, excluding: codeMasks))

        var seen = Set<MarkdownSyntaxSpan>()
        return result
            .filter { seen.insert($0).inserted }
            .sorted { lhs, rhs in
                if lhs.range.location != rhs.range.location {
                    return lhs.range.location < rhs.range.location
                }
                if lhs.range.length != rhs.range.length {
                    return lhs.range.length > rhs.range.length
                }
                return priority(lhs.kind) < priority(rhs.kind)
            }
    }
}

private extension MarkdownSyntaxTokenizer {
    struct Line {
        var content: NSRange
        var full: NSRange
    }

    struct Fence {
        var character: unichar
        var length: Int
    }

    static func lineRanges(in source: NSString) -> [Line] {
        var result: [Line] = []
        var cursor = 0
        while cursor < source.length {
            let start = cursor
            while cursor < source.length {
                let character = source.character(at: cursor)
                if character == unichar(10) || character == unichar(13) { break }
                cursor += 1
            }
            let contentEnd = cursor
            if cursor < source.length, source.character(at: cursor) == unichar(13) {
                cursor += 1
                if cursor < source.length, source.character(at: cursor) == unichar(10) { cursor += 1 }
            } else if cursor < source.length, source.character(at: cursor) == unichar(10) {
                cursor += 1
            }
            result.append(Line(
                content: NSRange(location: start, length: contentEnd - start),
                full: NSRange(location: start, length: cursor - start)
            ))
        }
        return result
    }

    static func fencedCodeSpans(in source: NSString, lines: [Line]) -> [MarkdownSyntaxSpan] {
        var result: [MarkdownSyntaxSpan] = []
        var index = 0
        while index < lines.count {
            let openingLine = source.substring(with: lines[index].content) as NSString
            guard let fence = openingFence(in: openingLine) else {
                index += 1
                continue
            }

            let openingIndex = index
            var closingIndex: Int?
            index += 1
            while index < lines.count {
                let candidate = source.substring(with: lines[index].content) as NSString
                if isClosingFence(candidate, for: fence) {
                    closingIndex = index
                    break
                }
                index += 1
            }

            if let closingIndex {
                let range = NSRange(
                    location: lines[openingIndex].content.location,
                    length: NSMaxRange(lines[closingIndex].content) - lines[openingIndex].content.location
                )
                result.append(MarkdownSyntaxSpan(range: range, kind: .codeBlock))
                index = closingIndex + 1
            } else {
                let range = NSRange(
                    location: lines[openingIndex].content.location,
                    length: source.length - lines[openingIndex].content.location
                )
                result.append(MarkdownSyntaxSpan(range: range, kind: .codeBlock))
                break
            }
        }
        return result
    }

    static func openingFence(in line: NSString) -> Fence? {
        var cursor = 0
        while cursor < line.length, cursor < 3, line.character(at: cursor) == unichar(32) { cursor += 1 }
        guard cursor < line.length else { return nil }
        let character = line.character(at: cursor)
        guard character == unichar(96) || character == unichar(126) else { return nil }
        let length = run(of: character, from: cursor, in: line)
        guard length >= 3 else { return nil }
        if character == unichar(96) {
            var index = cursor + length
            while index < line.length {
                if line.character(at: index) == character { return nil }
                index += 1
            }
        }
        return Fence(character: character, length: length)
    }

    static func isClosingFence(_ line: NSString, for fence: Fence) -> Bool {
        var cursor = 0
        while cursor < line.length, cursor < 3, line.character(at: cursor) == unichar(32) { cursor += 1 }
        let length = run(of: fence.character, from: cursor, in: line)
        guard length >= fence.length else { return false }
        cursor += length
        while cursor < line.length {
            let character = line.character(at: cursor)
            guard character == unichar(32) || character == unichar(9) else { return false }
            cursor += 1
        }
        return true
    }

    static func inlineCodeSpans(in source: NSString, excluding masks: [NSRange]) -> [MarkdownSyntaxSpan] {
        var result: [MarkdownSyntaxSpan] = []
        var cursor = 0
        while cursor < source.length {
            if let mask = containing(cursor, in: masks) {
                cursor = NSMaxRange(mask)
                continue
            }
            guard source.character(at: cursor) == unichar(96), !isEscaped(cursor, in: source) else {
                cursor += 1
                continue
            }
            let openingLength = run(of: unichar(96), from: cursor, in: source)
            var candidate = cursor + openingLength
            var closingEnd: Int?
            while candidate < source.length {
                if let mask = containing(candidate, in: masks) {
                    candidate = NSMaxRange(mask)
                    continue
                }
                if source.character(at: candidate) == unichar(96), !isEscaped(candidate, in: source) {
                    let length = run(of: unichar(96), from: candidate, in: source)
                    if length == openingLength {
                        closingEnd = candidate + length
                        break
                    }
                    candidate += length
                } else {
                    candidate += 1
                }
            }
            if let closingEnd {
                let range = NSRange(location: cursor, length: closingEnd - cursor)
                result.append(MarkdownSyntaxSpan(range: range, kind: .inlineCode))
                cursor = closingEnd
            } else {
                cursor += openingLength
            }
        }
        return result
    }

    static func linkSpans(in source: NSString, excluding masks: [NSRange]) -> [MarkdownSyntaxSpan] {
        var result: [MarkdownSyntaxSpan] = []
        var cursor = 0
        while cursor < source.length {
            if let mask = containing(cursor, in: masks) {
                cursor = NSMaxRange(mask)
                continue
            }
            let isImage = source.character(at: cursor) == unichar(33)
                && cursor + 1 < source.length
                && source.character(at: cursor + 1) == unichar(91)
            let isLink = source.character(at: cursor) == unichar(91)
            guard (isImage || isLink), !isEscaped(cursor, in: source) else {
                cursor += 1
                continue
            }
            let labelStart = cursor + (isImage ? 2 : 1)
            guard let bracket = closingBracket(from: labelStart, in: source, excluding: masks),
                  bracket + 1 < source.length,
                  source.character(at: bracket + 1) == unichar(40),
                  let parenthesis = closingParenthesis(from: bracket + 2, in: source, excluding: masks) else {
                cursor += isImage ? 2 : 1
                continue
            }
            let range = NSRange(location: cursor, length: parenthesis + 1 - cursor)
            result.append(MarkdownSyntaxSpan(range: range, kind: isImage ? .image : .link))
            cursor = parenthesis + 1
        }
        return result
    }

    static func lineSpans(in source: NSString, lines: [Line], excluding masks: [NSRange]) -> [MarkdownSyntaxSpan] {
        var result: [MarkdownSyntaxSpan] = []
        for line in lines where !intersects(line.content, any: masks) {
            let end = NSMaxRange(line.content)
            var cursor = line.content.location
            cursor += upToThreeSpaces(from: cursor, end: end, in: source)

            var quoteStart: Int?
            var quoteEnd: Int?
            while cursor < end, source.character(at: cursor) == unichar(62) {
                quoteStart = quoteStart ?? cursor
                cursor += 1
                if cursor < end, isHorizontalWhitespace(source.character(at: cursor)) { cursor += 1 }
                quoteEnd = cursor
                cursor += upToThreeSpaces(from: cursor, end: end, in: source)
            }
            if let quoteStart, let quoteEnd {
                result.append(MarkdownSyntaxSpan(
                    range: NSRange(location: quoteStart, length: quoteEnd - quoteStart),
                    kind: .blockQuote
                ))
            }

            if isHorizontalRule(from: cursor, to: end, in: source) {
                result.append(MarkdownSyntaxSpan(
                    range: NSRange(location: cursor, length: end - cursor),
                    kind: .horizontalRule
                ))
                continue
            }

            if let heading = headingRange(from: cursor, to: end, in: source) {
                result.append(MarkdownSyntaxSpan(range: heading, kind: .heading))
            }

            if let marker = listMarker(from: cursor, to: end, in: source) {
                result.append(MarkdownSyntaxSpan(
                    range: marker.range,
                    kind: marker.isTask ? .taskMarker : .listMarker
                ))
            }
        }
        return result
    }

    struct ListMarker {
        var range: NSRange
        var isTask: Bool
    }

    static func listMarker(from start: Int, to end: Int, in source: NSString) -> ListMarker? {
        var cursor = start
        guard cursor < end else { return nil }
        let markerStart = cursor
        let first = source.character(at: cursor)
        if first == unichar(45) || first == unichar(43) || first == unichar(42) {
            cursor += 1
            let whitespaceStart = cursor
            while cursor < end, isHorizontalWhitespace(source.character(at: cursor)) { cursor += 1 }
            guard cursor > whitespaceStart else { return nil }
            if cursor + 2 < end,
               source.character(at: cursor) == unichar(91),
               (source.character(at: cursor + 1) == unichar(32)
                   || source.character(at: cursor + 1) == unichar(120)
                   || source.character(at: cursor + 1) == unichar(88)),
               source.character(at: cursor + 2) == unichar(93) {
                cursor += 3
                guard cursor == end || isHorizontalWhitespace(source.character(at: cursor)) else { return nil }
                while cursor < end, isHorizontalWhitespace(source.character(at: cursor)) { cursor += 1 }
                return ListMarker(
                    range: NSRange(location: markerStart, length: cursor - markerStart),
                    isTask: true
                )
            }
            return ListMarker(
                range: NSRange(location: markerStart, length: cursor - markerStart),
                isTask: false
            )
        }

        guard isDigit(first) else { return nil }
        while cursor < end, isDigit(source.character(at: cursor)) { cursor += 1 }
        guard cursor < end,
              source.character(at: cursor) == unichar(46) || source.character(at: cursor) == unichar(41) else {
            return nil
        }
        cursor += 1
        let whitespaceStart = cursor
        while cursor < end, isHorizontalWhitespace(source.character(at: cursor)) { cursor += 1 }
        guard cursor > whitespaceStart else { return nil }
        return ListMarker(
            range: NSRange(location: markerStart, length: cursor - markerStart),
            isTask: false
        )
    }

    static func headingRange(from start: Int, to end: Int, in source: NSString) -> NSRange? {
        var cursor = start
        while cursor < end, source.character(at: cursor) == unichar(35), cursor - start < 6 { cursor += 1 }
        guard cursor > start else { return nil }
        guard cursor == end || isHorizontalWhitespace(source.character(at: cursor)) else { return nil }
        return NSRange(location: start, length: end - start)
    }

    static func isHorizontalRule(from start: Int, to end: Int, in source: NSString) -> Bool {
        var marker: unichar?
        var count = 0
        var cursor = start
        while cursor < end {
            let character = source.character(at: cursor)
            if isHorizontalWhitespace(character) {
                cursor += 1
                continue
            }
            guard character == unichar(45) || character == unichar(42) || character == unichar(95) else { return false }
            if let marker, marker != character { return false }
            marker = character
            count += 1
            cursor += 1
        }
        return count >= 3
    }

    static func emphasisSpans(in source: NSString, excluding masks: [NSRange]) -> [MarkdownSyntaxSpan] {
        var result: [MarkdownSyntaxSpan] = []
        let rules: [(String, MarkdownSyntaxKind)] = [
            (#"~~(?=\S)(?:(?!~~)[^\r\n])+?(?<=\S)~~"#, .strikethrough),
            (#"\*\*(?=\S)(?:(?!\*\*)[^\r\n])+?(?<=\S)\*\*"#, .strong),
            (#"__(?=\S)(?:(?!__)[^\r\n])+?(?<=\S)__"#, .strong),
            (#"(?<!\*)\*(?!\*)(?=\S)[^*\r\n]+?(?<=\S)\*(?!\*)"#, .emphasis),
            (#"(?<![\p{L}\p{N}_])_(?!_)(?=\S)[^_\r\n]+?(?<=\S)_(?![\p{L}\p{N}_])"#, .emphasis)
        ]
        let fullRange = NSRange(location: 0, length: source.length)
        for (pattern, kind) in rules {
            guard let expression = try? NSRegularExpression(pattern: pattern) else { continue }
            for match in expression.matches(in: source as String, range: fullRange) {
                guard !isEscaped(match.range.location, in: source),
                      !intersects(match.range, any: masks) else { continue }
                result.append(MarkdownSyntaxSpan(range: match.range, kind: kind))
            }
        }
        return result
    }

    static func closingBracket(from start: Int, in source: NSString, excluding masks: [NSRange]) -> Int? {
        var depth = 0
        var cursor = start
        while cursor < source.length {
            if containing(cursor, in: masks) != nil { return nil }
            let character = source.character(at: cursor)
            if character == unichar(10) || character == unichar(13) { return nil }
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

    static func closingParenthesis(from start: Int, in source: NSString, excluding masks: [NSRange]) -> Int? {
        var depth = 0
        var cursor = start
        while cursor < source.length {
            if containing(cursor, in: masks) != nil { return nil }
            let character = source.character(at: cursor)
            if character == unichar(10) || character == unichar(13) { return nil }
            if character == unichar(92) { cursor += 2; continue }
            if character == unichar(40) { depth += 1 }
            if character == unichar(41) {
                if depth == 0 { return cursor }
                depth -= 1
            }
            cursor += 1
        }
        return nil
    }

    static func containing(_ offset: Int, in ranges: [NSRange]) -> NSRange? {
        ranges.first { offset >= $0.location && offset < NSMaxRange($0) }
    }

    static func intersects(_ range: NSRange, any masks: [NSRange]) -> Bool {
        masks.contains { NSIntersectionRange(range, $0).length > 0 }
    }

    static func isEscaped(_ offset: Int, in source: NSString) -> Bool {
        var slashes = 0
        var cursor = offset
        while cursor > 0, source.character(at: cursor - 1) == unichar(92) {
            slashes += 1
            cursor -= 1
        }
        return slashes % 2 == 1
    }

    static func run(of character: unichar, from start: Int, in source: NSString) -> Int {
        guard start >= 0, start <= source.length else { return 0 }
        var cursor = start
        while cursor < source.length, source.character(at: cursor) == character { cursor += 1 }
        return cursor - start
    }

    static func upToThreeSpaces(from start: Int, end: Int, in source: NSString) -> Int {
        var cursor = start
        while cursor < end, cursor - start < 3, source.character(at: cursor) == unichar(32) { cursor += 1 }
        return cursor - start
    }

    static func isHorizontalWhitespace(_ character: unichar) -> Bool {
        character == unichar(32) || character == unichar(9)
    }

    static func isDigit(_ character: unichar) -> Bool {
        character >= unichar(48) && character <= unichar(57)
    }

    static func priority(_ kind: MarkdownSyntaxKind) -> Int {
        switch kind {
        case .codeBlock: 0
        case .inlineCode: 1
        case .heading: 2
        case .image: 3
        case .link: 4
        case .strong: 5
        case .emphasis: 6
        case .strikethrough: 7
        case .blockQuote: 8
        case .taskMarker: 9
        case .listMarker: 10
        case .horizontalRule: 11
        }
    }
}
