import Foundation

enum HTMLEscaping {
    static func text(_ value: String) -> String {
        var result = ""
        result.reserveCapacity(value.utf8.count)
        for character in value {
            switch character {
            case "&": result += "&amp;"
            case "<": result += "&lt;"
            case ">": result += "&gt;"
            default: result.append(character)
            }
        }
        return result
    }

    static func attribute(_ value: String) -> String {
        var result = ""
        result.reserveCapacity(value.utf8.count)
        for character in value {
            switch character {
            case "&": result += "&amp;"
            case "<": result += "&lt;"
            case ">": result += "&gt;"
            case "\"": result += "&quot;"
            case "'": result += "&#39;"
            case "\n", "\r", "\0": result += " "
            default: result.append(character)
            }
        }
        return result
    }
}

enum MarkdownURLSanitizer {
    static func sanitize(_ rawValue: String, kind: URLKind) -> String? {
        var value = unescape(rawValue).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !value.contains(where: { $0.isNewline || $0 == "\0" }) else {
            return nil
        }

        if value.hasPrefix("<"), value.hasSuffix(">"), value.count >= 2 {
            value.removeFirst()
            value.removeLast()
        }

        guard !value.hasPrefix("//"), !value.hasPrefix("\\"), !value.hasPrefix("/") else {
            return nil
        }

        if value.lowercased().hasPrefix("www.") {
            value = "https://" + value
        }

        let decodedForInspection = value.removingPercentEncoding ?? value
        if let scheme = detectedScheme(in: decodedForInspection) {
            let allowed: Set<String>
            switch kind {
            case .link: allowed = ["http", "https", "mailto"]
            case .image: allowed = ["http", "https"]
            }
            guard allowed.contains(scheme.lowercased()) else { return nil }
        } else if decodedForInspection.contains(":") {
            let colon = decodedForInspection.firstIndex(of: ":")!
            let slash = decodedForInspection.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" })
            if slash == nil || colon < slash! {
                return nil
            }
        }

        return value
    }

    enum URLKind {
        case link
        case image
    }

    private static func detectedScheme(in value: String) -> String? {
        guard let colon = value.firstIndex(of: ":") else { return nil }
        let prefix = value[..<colon]
        guard let first = prefix.first, first.isASCII, first.isLetter,
              prefix.dropFirst().allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "+" || $0 == "-" || $0 == ".") })
        else {
            return nil
        }
        return String(prefix)
    }

    private static func unescape(_ value: String) -> String {
        let escapable = Set("\\`*{}[]()#+-.!_>~|")
        let characters = Array(value)
        var result = ""
        var index = 0
        while index < characters.count {
            if characters[index] == "\\", index + 1 < characters.count,
               escapable.contains(characters[index + 1]) {
                result.append(characters[index + 1])
                index += 2
            } else {
                result.append(characters[index])
                index += 1
            }
        }
        return result
    }
}

/// Deterministic, dependency-free Markdown block parser.
struct MarkdownParser {
    let source: String

    init(_ source: String) {
        self.source = source
    }

    func render(includingSourceMap: Bool = false) -> String {
        let normalized = source
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        var parser = MarkdownBlockParser(
            lines: normalized.components(separatedBy: "\n"),
            headingIDs: HeadingIDGenerator(),
            sourceLineOffset: includingSourceMap ? 0 : nil
        )
        return parser.render()
    }
}

/// Block-level parser kept internal so parser behavior can be unit tested.
struct MarkdownBlockParser {
    let lines: [String]
    let headingIDs: HeadingIDGenerator
    let sourceLineOffset: Int?
    private(set) var index = 0

    init(
        lines: [String],
        headingIDs: HeadingIDGenerator,
        sourceLineOffset: Int? = nil
    ) {
        self.lines = lines
        self.headingIDs = headingIDs
        self.sourceLineOffset = sourceLineOffset
    }

    mutating func render() -> String {
        var blocks: [String] = []
        while index < lines.count {
            if lines[index].isMarkdownBlank {
                index += 1
                continue
            }

            let blockStart = index
            let block: String
            if let fence = fenceOpening(lines[index]) {
                block = renderFence(fence)
            } else if let heading = atxHeading(lines[index]) {
                index += 1
                block = renderHeading(level: heading.level, source: heading.content)
            } else if isThematicBreak(lines[index]) {
                index += 1
                block = #"<hr>"#
            } else if quoteContent(lines[index]) != nil {
                block = renderBlockquote()
            } else if tableDelimiter(at: index) != nil {
                block = renderTable()
            } else if let marker = listMarker(lines[index]) {
                block = renderList(startingWith: marker)
            } else if indentation(of: lines[index]) >= 4 {
                block = renderIndentedCode()
            } else {
                block = renderParagraphOrSetextHeading()
            }

            if let sourceLineOffset {
                blocks.append(
                    Self.annotate(
                        block,
                        startLine: sourceLineOffset + blockStart,
                        endLine: sourceLineOffset + max(blockStart, index - 1)
                    )
                )
            } else {
                blocks.append(block)
            }
        }
        return blocks.joined(separator: "\n")
    }

    private static func annotate(
        _ html: String,
        startLine: Int,
        endLine: Int
    ) -> String {
        guard html.first == "<", let closingBracket = html.firstIndex(of: ">") else {
            return html
        }
        var annotated = html
        let attributes = " data-source-start=\"\(startLine)\" data-source-end=\"\(endLine)\""
        annotated.insert(contentsOf: attributes, at: closingBracket)
        return annotated
    }
}

extension MarkdownBlockParser {
    struct Heading {
        let level: Int
        let content: String
    }

    struct Fence {
        let marker: Character
        let length: Int
        let indentation: Int
        let info: String
    }

    struct ListMarker {
        let indentation: Int
        let contentIndentation: Int
        let ordered: Bool
        let start: Int
        let content: String
    }

    struct TableDelimiter {
        enum Alignment: String {
            case none
            case left
            case center
            case right
        }

        let alignments: [Alignment]
    }
}

private extension MarkdownBlockParser {
    mutating func renderFence(_ fence: Fence) -> String {
        index += 1
        var codeLines: [String] = []
        while index < lines.count {
            if isFenceClosing(lines[index], for: fence) {
                index += 1
                break
            }
            codeLines.append(removingIndentation(lines[index], count: fence.indentation))
            index += 1
        }

        let code = codeLines.joined(separator: "\n")
        let language = fence.info.split(whereSeparator: \.isWhitespace).first.map(String.init)
        let languageClass = language.flatMap(sanitizedLanguageClass)
        let highlighted = CodeSyntaxHighlighter().highlight(code, language: language)
        let classAttribute = languageClass.map { #" class="language-\#(HTMLEscaping.attribute($0))""# } ?? ""
        let label = language.map { #" aria-label="Code block: \#(HTMLEscaping.attribute($0))""# } ?? #" aria-label="Code block""#
        return "<pre><code\(classAttribute)\(label)>\(highlighted)</code></pre>"
    }

    mutating func renderBlockquote() -> String {
        var quotedLines: [String] = []
        while index < lines.count {
            if let content = quoteContent(lines[index]) {
                quotedLines.append(content)
                index += 1
            } else if lines[index].isMarkdownBlank,
                      nextNonblankLine(after: index).map({ quoteContent(lines[$0]) != nil }) == true {
                quotedLines.append("")
                index += 1
            } else {
                break
            }
        }

        var nested = MarkdownBlockParser(lines: quotedLines, headingIDs: headingIDs)
        return "<blockquote>\n\(nested.render())\n</blockquote>"
    }

    mutating func renderIndentedCode() -> String {
        var codeLines: [String] = []
        while index < lines.count {
            if lines[index].isMarkdownBlank {
                codeLines.append("")
                index += 1
            } else if indentation(of: lines[index]) >= 4 {
                codeLines.append(removingIndentation(lines[index], count: 4))
                index += 1
            } else {
                break
            }
        }
        while codeLines.last?.isEmpty == true { codeLines.removeLast() }
        let code = codeLines.joined(separator: "\n")
        return "<pre><code aria-label=\"Code block\">\(HTMLEscaping.text(code))</code></pre>"
    }

    mutating func renderParagraphOrSetextHeading() -> String {
        var paragraphLines: [String] = []

        while index < lines.count, !lines[index].isMarkdownBlank {
            if !paragraphLines.isEmpty, let level = setextLevel(lines[index]) {
                index += 1
                return renderHeading(level: level, source: paragraphLines.joined(separator: "\n"))
            }
            if !paragraphLines.isEmpty, isInterruptingBlock(at: index) {
                break
            }
            paragraphLines.append(lines[index])
            index += 1
        }

        let content = MarkdownInlineParser().render(paragraphLines.joined(separator: "\n"))
        return "<p>\(content)</p>"
    }

    mutating func renderList(startingWith firstMarker: ListMarker) -> String {
        let baseIndentation = firstMarker.indentation
        let ordered = firstMarker.ordered
        var renderedItems: [(html: String, isTask: Bool)] = []
        var shouldEndList = false

        while index < lines.count, !shouldEndList {
            guard let marker = listMarker(lines[index]),
                  marker.indentation == baseIndentation,
                  marker.ordered == ordered else {
                break
            }

            index += 1
            var itemLines = [marker.content]

            itemLoop: while index < lines.count {
                if lines[index].isMarkdownBlank {
                    var lookahead = index
                    while lookahead < lines.count, lines[lookahead].isMarkdownBlank {
                        lookahead += 1
                    }
                    guard lookahead < lines.count else {
                        index = lookahead
                        shouldEndList = true
                        break itemLoop
                    }

                    if let next = listMarker(lines[lookahead]),
                       next.indentation == baseIndentation,
                       next.ordered == ordered {
                        index = lookahead
                        break itemLoop
                    }

                    if indentation(of: lines[lookahead]) > baseIndentation {
                        itemLines.append("")
                        index = lookahead
                        continue
                    }

                    index = lookahead
                    shouldEndList = true
                    break itemLoop
                }

                if let next = listMarker(lines[index]), next.indentation <= baseIndentation {
                    break itemLoop
                }

                let lineIndentation = indentation(of: lines[index])
                if lineIndentation > baseIndentation {
                    itemLines.append(removingIndentation(
                        lines[index],
                        count: min(lineIndentation, marker.contentIndentation)
                    ))
                    index += 1
                    continue
                }

                if isInterruptingBlock(at: index) {
                    shouldEndList = true
                    break itemLoop
                }

                // CommonMark permits a non-indented lazy continuation of an item paragraph.
                itemLines.append(lines[index])
                index += 1
            }

            let task = extractTask(from: itemLines.first ?? "")
            if task != nil {
                itemLines[0] = task!.content
            }

            var nested = MarkdownBlockParser(lines: itemLines, headingIDs: headingIDs)
            let itemHTML = nested.render()
            let checkbox: String
            if let task {
                let checked = task.checked ? #" checked"# : ""
                let state = task.checked ? "completed" : "not completed"
                checkbox = #"<input type="checkbox" disabled\#(checked) aria-label="Task \#(state)">"#
            } else {
                checkbox = ""
            }
            let itemClass = task == nil ? "" : #" class="task-list-item""#
            renderedItems.append(("<li\(itemClass)>\(checkbox)\(itemHTML)</li>", task != nil))

            if index < lines.count, let next = listMarker(lines[index]),
               next.indentation == baseIndentation, next.ordered != ordered {
                shouldEndList = true
            }
        }

        let containsTasks = renderedItems.contains(where: \.isTask)
        let listClass = containsTasks ? #" class="contains-task-list""# : ""
        let items = renderedItems.map(\.html).joined(separator: "\n")
        if ordered {
            let start = firstMarker.start == 1 ? "" : #" start="\#(firstMarker.start)""#
            return "<ol\(start)\(listClass)>\n\(items)\n</ol>"
        }
        return "<ul\(listClass)>\n\(items)\n</ul>"
    }

    mutating func renderTable() -> String {
        let header = splitTableRow(lines[index])
        let delimiter = tableDelimiter(at: index)!
        index += 2

        var rows: [[String]] = []
        while index < lines.count, !lines[index].isMarkdownBlank,
              containsUnescapedPipe(lines[index]) {
            rows.append(splitTableRow(lines[index]))
            index += 1
        }

        let inline = MarkdownInlineParser()
        let headers = delimiter.alignments.indices.map { column -> String in
            let value = column < header.count ? header[column] : ""
            return #"<th class="align-\#(delimiter.alignments[column].rawValue)">\#(inline.render(value.trimmingCharacters(in: .whitespaces)))</th>"#
        }.joined()

        let bodyRows = rows.map { row in
            let cells = delimiter.alignments.indices.map { column -> String in
                let value = column < row.count ? row[column] : ""
                return #"<td class="align-\#(delimiter.alignments[column].rawValue)">\#(inline.render(value.trimmingCharacters(in: .whitespaces)))</td>"#
            }.joined()
            return "<tr>\(cells)</tr>"
        }.joined(separator: "\n")

        let body = bodyRows.isEmpty ? "" : "\n<tbody>\n\(bodyRows)\n</tbody>"
        return "<div class=\"table-scroll\"><table>\n<thead><tr>\(headers)</tr></thead>\(body)\n</table></div>"
    }

    func renderHeading(level: Int, source: String) -> String {
        let identifier = headingIDs.identifier(for: source)
        let content = MarkdownInlineParser().render(source)
        return #"<h\#(level) id="\#(HTMLEscaping.attribute(identifier))">\#(content)</h\#(level)>"#
    }

    func isInterruptingBlock(at candidate: Int) -> Bool {
        guard candidate < lines.count else { return false }
        let line = lines[candidate]
        return fenceOpening(line) != nil
            || atxHeading(line) != nil
            || isThematicBreak(line)
            || quoteContent(line) != nil
            || listMarker(line) != nil
            || indentation(of: line) >= 4
            || tableDelimiter(at: candidate) != nil
    }

    func atxHeading(_ line: String) -> Heading? {
        let characters = Array(line)
        let indent = leadingSpaces(in: characters)
        guard indent <= 3, indent < characters.count, characters[indent] == "#" else { return nil }

        var markerEnd = indent
        while markerEnd < characters.count, characters[markerEnd] == "#" { markerEnd += 1 }
        let level = markerEnd - indent
        guard (1...6).contains(level),
              markerEnd == characters.count || characters[markerEnd].isWhitespace else { return nil }

        var content = String(characters[markerEnd...]).trimmingCharacters(in: .whitespaces)
        let contentCharacters = Array(content)
        if let lastNonHash = contentCharacters.lastIndex(where: { $0 != "#" }),
           lastNonHash < contentCharacters.index(before: contentCharacters.endIndex),
           contentCharacters[lastNonHash].isWhitespace {
            content = String(contentCharacters[...lastNonHash]).trimmingCharacters(in: .whitespaces)
        } else if !contentCharacters.isEmpty, contentCharacters.allSatisfy({ $0 == "#" }) {
            content = ""
        }
        return Heading(level: level, content: content)
    }

    func setextLevel(_ line: String) -> Int? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.allSatisfy({ $0 == "=" }) { return 1 }
        if trimmed.allSatisfy({ $0 == "-" }) { return 2 }
        return nil
    }

    func fenceOpening(_ line: String) -> Fence? {
        let characters = Array(line)
        let indent = leadingSpaces(in: characters)
        guard indent <= 3, indent < characters.count,
              characters[indent] == "`" || characters[indent] == "~" else { return nil }
        let marker = characters[indent]
        var end = indent
        while end < characters.count, characters[end] == marker { end += 1 }
        guard end - indent >= 3 else { return nil }
        let info = end < characters.count
            ? String(characters[end...]).trimmingCharacters(in: .whitespaces)
            : ""
        if marker == "`", info.contains("`") { return nil }
        return Fence(marker: marker, length: end - indent, indentation: indent, info: info)
    }

    func isFenceClosing(_ line: String, for fence: Fence) -> Bool {
        let characters = Array(line)
        let indent = leadingSpaces(in: characters)
        guard indent <= 3, indent < characters.count, characters[indent] == fence.marker else { return false }
        var end = indent
        while end < characters.count, characters[end] == fence.marker { end += 1 }
        return end - indent >= fence.length && characters[end...].allSatisfy(\.isWhitespace)
    }

    func isThematicBreak(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let marker = trimmed.first, marker == "*" || marker == "-" || marker == "_" else { return false }
        var count = 0
        for character in trimmed {
            if character == marker { count += 1 }
            else if !character.isWhitespace { return false }
        }
        return count >= 3
    }

    func quoteContent(_ line: String) -> String? {
        let characters = Array(line)
        let indent = leadingSpaces(in: characters)
        guard indent <= 3, indent < characters.count, characters[indent] == ">" else { return nil }
        var start = indent + 1
        if start < characters.count, characters[start] == " " { start += 1 }
        return start < characters.count ? String(characters[start...]) : ""
    }

    func listMarker(_ line: String) -> ListMarker? {
        let characters = Array(line)
        let indent = leadingSpaces(in: characters)
        guard indent <= 3, indent < characters.count else { return nil }

        var cursor = indent
        var ordered = false
        var start = 1
        if characters[cursor] == "-" || characters[cursor] == "+" || characters[cursor] == "*" {
            cursor += 1
        } else if characters[cursor].isNumber {
            let numberStart = cursor
            while cursor < characters.count, characters[cursor].isNumber, cursor - numberStart < 9 {
                cursor += 1
            }
            guard cursor > numberStart, cursor < characters.count,
                  characters[cursor] == "." || characters[cursor] == ")" else { return nil }
            start = Int(String(characters[numberStart..<cursor])) ?? 1
            ordered = true
            cursor += 1
        } else {
            return nil
        }

        guard cursor == characters.count || characters[cursor].isWhitespace else { return nil }
        while cursor < characters.count, characters[cursor].isWhitespace, characters[cursor] != "\n" {
            cursor += 1
        }
        let content = cursor < characters.count ? String(characters[cursor...]) : ""
        return ListMarker(
            indentation: indent,
            contentIndentation: max(indent + 2, cursor),
            ordered: ordered,
            start: start,
            content: content
        )
    }

    func extractTask(from line: String) -> (checked: Bool, content: String)? {
        let characters = Array(line)
        guard characters.count >= 3, characters[0] == "[", characters[2] == "]",
              characters[1] == " " || characters[1] == "x" || characters[1] == "X",
              characters.count == 3 || characters[3].isWhitespace else { return nil }
        var start = min(3, characters.count)
        while start < characters.count, characters[start].isWhitespace { start += 1 }
        let content = start < characters.count ? String(characters[start...]) : ""
        return (characters[1] != " ", content)
    }

    func tableDelimiter(at candidate: Int) -> TableDelimiter? {
        guard candidate + 1 < lines.count,
              containsUnescapedPipe(lines[candidate]) || containsUnescapedPipe(lines[candidate + 1]) else {
            return nil
        }
        let cells = splitTableRow(lines[candidate + 1])
        guard !cells.isEmpty else { return nil }

        var alignments: [TableDelimiter.Alignment] = []
        for cell in cells {
            let value = cell.trimmingCharacters(in: .whitespaces)
            let left = value.hasPrefix(":")
            let right = value.hasSuffix(":")
            let dashes = value.drop(while: { $0 == ":" }).dropLast(right ? 1 : 0)
            guard dashes.count >= 3, dashes.allSatisfy({ $0 == "-" }) else { return nil }
            switch (left, right) {
            case (true, true): alignments.append(.center)
            case (true, false): alignments.append(.left)
            case (false, true): alignments.append(.right)
            default: alignments.append(.none)
            }
        }
        return TableDelimiter(alignments: alignments)
    }

    func splitTableRow(_ line: String) -> [String] {
        let characters = Array(line.trimmingCharacters(in: .whitespaces))
        guard !characters.isEmpty else { return [] }

        var cells: [String] = []
        var current = ""
        var index = 0
        var escaped = false
        var codeDelimiterLength = 0

        while index < characters.count {
            let character = characters[index]
            if escaped {
                current.append(character)
                escaped = false
                index += 1
                continue
            }
            if character == "\\" {
                current.append(character)
                escaped = true
                index += 1
                continue
            }
            if character == "`" {
                var end = index
                while end < characters.count, characters[end] == "`" { end += 1 }
                let count = end - index
                if codeDelimiterLength == 0 { codeDelimiterLength = count }
                else if codeDelimiterLength == count { codeDelimiterLength = 0 }
                current += String(repeating: "`", count: count)
                index = end
                continue
            }
            if character == "|", codeDelimiterLength == 0 {
                cells.append(current)
                current = ""
            } else {
                current.append(character)
            }
            index += 1
        }
        cells.append(current)

        if characters.first == "|", cells.first?.isEmpty == true { cells.removeFirst() }
        if characters.last == "|", cells.last?.isEmpty == true { cells.removeLast() }
        return cells
    }

    func containsUnescapedPipe(_ line: String) -> Bool {
        let characters = Array(line)
        var escaped = false
        for character in characters {
            if escaped {
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "|" {
                return true
            }
        }
        return false
    }

    func sanitizedLanguageClass(_ language: String) -> String? {
        let value = language.lowercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "+" || $0 == "-" || $0 == "_") }
        return value.isEmpty ? nil : value
    }

    func indentation(of line: String) -> Int {
        leadingSpaces(in: Array(line))
    }

    func leadingSpaces(in characters: [Character]) -> Int {
        var count = 0
        for character in characters {
            if character == " " { count += 1 }
            else if character == "\t" { count += 4 - (count % 4) }
            else { break }
        }
        return count
    }

    func removingIndentation(_ line: String, count: Int) -> String {
        let characters = Array(line)
        var removed = 0
        var index = 0
        while index < characters.count, removed < count {
            if characters[index] == " " {
                removed += 1
                index += 1
            } else if characters[index] == "\t" {
                removed += 4 - (removed % 4)
                index += 1
            } else {
                break
            }
        }
        return index < characters.count ? String(characters[index...]) : ""
    }

    func nextNonblankLine(after current: Int) -> Int? {
        var candidate = current + 1
        while candidate < lines.count {
            if !lines[candidate].isMarkdownBlank { return candidate }
            candidate += 1
        }
        return nil
    }
}

/// Inline parser that always escapes raw HTML and never emits executable content.
struct MarkdownInlineParser {
    func render(_ source: String) -> String {
        render(Array(source))
    }
}

private extension MarkdownInlineParser {
    struct LinkToken {
        let html: String
        let end: Int
    }

    func render(_ characters: [Character]) -> String {
        var output = ""
        var index = 0

        while index < characters.count {
            if characters[index] == "\\", index + 1 < characters.count {
                if characters[index + 1] == "\n" {
                    output += "<br>\n"
                    index += 2
                    continue
                }
                if isEscapable(characters[index + 1]) {
                    output += HTMLEscaping.text(String(characters[index + 1]))
                    index += 2
                    continue
                }
            }

            if characters[index] == " " {
                var end = index
                while end < characters.count, characters[end] == " " { end += 1 }
                if end - index >= 2, end < characters.count, characters[end] == "\n" {
                    output += "<br>\n"
                    index = end + 1
                    continue
                }
            }

            if characters[index] == "\n" {
                output += "\n"
                index += 1
                continue
            }

            if characters[index] == "`", let code = inlineCode(in: characters, at: index) {
                output += "<code>\(HTMLEscaping.text(code.content))</code>"
                index = code.end
                continue
            }

            if (characters[index] == "[" || (characters[index] == "!" && index + 1 < characters.count && characters[index + 1] == "[")),
               let link = link(in: characters, at: index) {
                output += link.html
                index = link.end
                continue
            }

            if characters[index] == "<", let autolink = angleAutolink(in: characters, at: index) {
                output += autolink.html
                index = autolink.end
                continue
            }

            if let formatted = delimitedSpan(in: characters, at: index) {
                output += formatted.html
                index = formatted.end
                continue
            }

            if let url = bareURL(in: characters, at: index) {
                output += url.html
                index = url.end
                continue
            }

            if let email = bareEmail(in: characters, at: index) {
                output += email.html
                index = email.end
                continue
            }

            output += HTMLEscaping.text(String(characters[index]))
            index += 1
        }

        return output
    }

    func inlineCode(in characters: [Character], at index: Int) -> (content: String, end: Int)? {
        var openingEnd = index
        while openingEnd < characters.count, characters[openingEnd] == "`" { openingEnd += 1 }
        let length = openingEnd - index
        var candidate = openingEnd
        while candidate < characters.count {
            if characters[candidate] == "`" {
                var closingEnd = candidate
                while closingEnd < characters.count, characters[closingEnd] == "`" { closingEnd += 1 }
                if closingEnd - candidate == length {
                    var content = String(characters[openingEnd..<candidate]).replacingOccurrences(of: "\n", with: " ")
                    if content.hasPrefix(" "), content.hasSuffix(" "),
                       content.contains(where: { !$0.isWhitespace }) {
                        content.removeFirst()
                        content.removeLast()
                    }
                    return (content, closingEnd)
                }
                candidate = closingEnd
            } else {
                candidate += 1
            }
        }
        return nil
    }

    func delimitedSpan(in characters: [Character], at index: Int) -> LinkToken? {
        let candidates: [(delimiter: [Character], open: String, close: String)] = [
            (Array("***"), "<strong><em>", "</em></strong>"),
            (Array("___"), "<strong><em>", "</em></strong>"),
            (Array("~~"), "<del>", "</del>"),
            (Array("**"), "<strong>", "</strong>"),
            (Array("__"), "<strong>", "</strong>"),
            (Array("*"), "<em>", "</em>"),
            (Array("_"), "<em>", "</em>")
        ]

        for candidate in candidates where matches(candidate.delimiter, in: characters, at: index) {
            let afterOpening = index + candidate.delimiter.count
            guard afterOpening < characters.count, !characters[afterOpening].isWhitespace else { continue }
            if candidate.delimiter.first == "_", index > 0,
               characters[index - 1].isLetter || characters[index - 1].isNumber,
               characters[afterOpening].isLetter || characters[afterOpening].isNumber {
                continue
            }

            guard let closing = findClosingDelimiter(candidate.delimiter, in: characters, from: afterOpening),
                  closing > afterOpening, !characters[closing - 1].isWhitespace else { continue }
            let inner = render(Array(characters[afterOpening..<closing]))
            return LinkToken(
                html: candidate.open + inner + candidate.close,
                end: closing + candidate.delimiter.count
            )
        }
        return nil
    }

    func link(in characters: [Character], at index: Int) -> LinkToken? {
        let isImage = characters[index] == "!"
        let openingBracket = isImage ? index + 1 : index
        guard let closingBracket = closingBracket(in: characters, from: openingBracket + 1),
              closingBracket + 1 < characters.count, characters[closingBracket + 1] == "(",
              let closingParenthesis = closingParenthesis(in: characters, from: closingBracket + 2) else {
            return nil
        }

        let labelSource = String(characters[(openingBracket + 1)..<closingBracket])
        let destinationSource = String(characters[(closingBracket + 2)..<closingParenthesis])
        guard let parsed = parseDestinationAndTitle(destinationSource) else { return nil }

        if isImage {
            guard let source = MarkdownURLSanitizer.sanitize(parsed.destination, kind: .image) else {
                return LinkToken(html: HTMLEscaping.text(labelSource), end: closingParenthesis + 1)
            }
            let alt = plainText(labelSource)
            let title = parsed.title.map { #" title="\#(HTMLEscaping.attribute($0))""# } ?? ""
            let html = #"<img src="\#(HTMLEscaping.attribute(source))" alt="\#(HTMLEscaping.attribute(alt))"\#(title) loading="lazy" decoding="async">"#
            return LinkToken(html: html, end: closingParenthesis + 1)
        }

        guard let destination = MarkdownURLSanitizer.sanitize(parsed.destination, kind: .link) else {
            return LinkToken(html: render(Array(labelSource)), end: closingParenthesis + 1)
        }
        let title = parsed.title.map { #" title="\#(HTMLEscaping.attribute($0))""# } ?? ""
        let html = #"<a href="\#(HTMLEscaping.attribute(destination))" rel="noopener noreferrer"\#(title)>\#(render(Array(labelSource)))</a>"#
        return LinkToken(html: html, end: closingParenthesis + 1)
    }

    func angleAutolink(in characters: [Character], at index: Int) -> LinkToken? {
        guard let close = characters[(index + 1)...].firstIndex(of: ">") else { return nil }
        let candidate = String(characters[(index + 1)..<close])
        let looksLikeEmail = candidate.contains("@") && !candidate.contains(":")
        let rawDestination = looksLikeEmail ? "mailto:\(candidate)" : candidate
        guard let destination = MarkdownURLSanitizer.sanitize(rawDestination, kind: .link),
              destination.hasPrefix("http://") || destination.hasPrefix("https://") || destination.hasPrefix("mailto:") else {
            return nil
        }
        let label = looksLikeEmail ? candidate : destination
        return LinkToken(
            html: #"<a href="\#(HTMLEscaping.attribute(destination))" rel="noopener noreferrer">\#(HTMLEscaping.text(label))</a>"#,
            end: close + 1
        )
    }

    func bareURL(in characters: [Character], at index: Int) -> LinkToken? {
        let prefixes = [Array("https://"), Array("http://"), Array("www.")]
        guard prefixes.contains(where: { matches($0, in: characters, at: index) }),
              index == 0 || !characters[index - 1].isLetter && !characters[index - 1].isNumber else {
            return nil
        }

        var end = index
        var parenthesisDepth = 0
        while end < characters.count {
            let character = characters[end]
            if character.isWhitespace || character == "<" || character == ">" || character == "\"" {
                break
            }
            if character == "(" { parenthesisDepth += 1 }
            if character == ")" {
                if parenthesisDepth == 0 { break }
                parenthesisDepth -= 1
            }
            end += 1
        }
        while end > index, ".,;:!?".contains(characters[end - 1]) { end -= 1 }
        guard end > index else { return nil }
        let label = String(characters[index..<end])
        guard let destination = MarkdownURLSanitizer.sanitize(label, kind: .link) else { return nil }
        return LinkToken(
            html: #"<a href="\#(HTMLEscaping.attribute(destination))" rel="noopener noreferrer">\#(HTMLEscaping.text(label))</a>"#,
            end: end
        )
    }

    func bareEmail(in characters: [Character], at index: Int) -> LinkToken? {
        guard characters[index].isLetter || characters[index].isNumber,
              index == 0 || !isEmailCharacter(characters[index - 1]) else { return nil }

        var end = index
        while end < characters.count, isEmailCharacter(characters[end]) { end += 1 }
        let candidate = String(characters[index..<end])
        guard candidate.filter({ $0 == "@" }).count == 1,
              let at = candidate.firstIndex(of: "@"),
              candidate[..<at].last?.isLetter == true || candidate[..<at].last?.isNumber == true,
              candidate[candidate.index(after: at)...].contains("."),
              candidate.last?.isLetter == true else { return nil }
        let destination = "mailto:\(candidate)"
        return LinkToken(
            html: #"<a href="\#(HTMLEscaping.attribute(destination))" rel="noopener noreferrer">\#(HTMLEscaping.text(candidate))</a>"#,
            end: end
        )
    }

    func closingBracket(in characters: [Character], from start: Int) -> Int? {
        var depth = 0
        var escaped = false
        var index = start
        while index < characters.count {
            let character = characters[index]
            if escaped { escaped = false }
            else if character == "\\" { escaped = true }
            else if character == "[" { depth += 1 }
            else if character == "]" {
                if depth == 0 { return index }
                depth -= 1
            }
            index += 1
        }
        return nil
    }

    func closingParenthesis(in characters: [Character], from start: Int) -> Int? {
        var depth = 0
        var escaped = false
        var inAngleDestination = false
        var quote: Character?
        var index = start
        while index < characters.count {
            let character = characters[index]
            if escaped { escaped = false }
            else if character == "\\" { escaped = true }
            else if let currentQuote = quote {
                if character == currentQuote { quote = nil }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character == "<", depth == 0 { inAngleDestination = true }
            else if character == ">", inAngleDestination { inAngleDestination = false }
            else if !inAngleDestination, character == "(" { depth += 1 }
            else if !inAngleDestination, character == ")" {
                if depth == 0 { return index }
                depth -= 1
            }
            index += 1
        }
        return nil
    }

    func parseDestinationAndTitle(_ source: String) -> (destination: String, title: String?)? {
        let characters = Array(source.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !characters.isEmpty else { return nil }

        var destination = ""
        var cursor = 0
        if characters[0] == "<" {
            guard let closing = characters.firstIndex(of: ">"), closing > 0 else { return nil }
            destination = String(characters[1..<closing])
            cursor = closing + 1
        } else {
            var depth = 0
            var escaped = false
            while cursor < characters.count {
                let character = characters[cursor]
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "(" {
                    depth += 1
                } else if character == ")", depth > 0 {
                    depth -= 1
                } else if character.isWhitespace, depth == 0 {
                    break
                }
                destination.append(character)
                cursor += 1
            }
        }

        while cursor < characters.count, characters[cursor].isWhitespace { cursor += 1 }
        guard cursor < characters.count else { return (destination, nil) }

        let titleCharacters = Array(characters[cursor...])
        guard titleCharacters.count >= 2 else { return nil }
        let opening = titleCharacters[0]
        let closing: Character = opening == "(" ? ")" : opening
        guard opening == "\"" || opening == "'" || opening == "(", titleCharacters.last == closing else {
            return nil
        }
        return (destination, String(titleCharacters[1..<(titleCharacters.count - 1)]))
    }

    func plainText(_ source: String) -> String {
        let formatting = Set("*_~`")
        let characters = Array(source)
        var result = ""
        var index = 0
        while index < characters.count {
            if characters[index] == "\\", index + 1 < characters.count {
                result.append(characters[index + 1])
                index += 2
            } else if !formatting.contains(characters[index]) {
                result.append(characters[index])
                index += 1
            } else {
                index += 1
            }
        }
        return result
    }

    func findClosingDelimiter(_ delimiter: [Character], in characters: [Character], from start: Int) -> Int? {
        var index = start
        while index + delimiter.count <= characters.count {
            if characters[index] == "\\" {
                index += 2
                continue
            }
            if matches(delimiter, in: characters, at: index) {
                return index
            }
            index += 1
        }
        return nil
    }

    func matches(_ token: [Character], in characters: [Character], at index: Int) -> Bool {
        guard !token.isEmpty, index + token.count <= characters.count else { return false }
        return characters[index..<(index + token.count)].elementsEqual(token)
    }

    func isEscapable(_ character: Character) -> Bool {
        "\\`*{}[]()#+-.!_>~|".contains(character)
    }

    func isEmailCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || ".!#$%&'*+/=?^_`{|}~-@".contains(character)
    }
}

final class HeadingIDGenerator {
    private var occurrences: [String: Int] = [:]

    func identifier(for heading: String) -> String {
        var slug = ""
        var lastWasSeparator = false
        for scalar in heading.lowercased().unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) || scalar == "_" || scalar == "-" {
                slug.unicodeScalars.append(scalar)
                lastWasSeparator = false
            } else if CharacterSet.whitespacesAndNewlines.contains(scalar), !slug.isEmpty, !lastWasSeparator {
                slug.append("-")
                lastWasSeparator = true
            }
        }
        slug = slug.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        if slug.isEmpty { slug = "section" }

        let occurrence = occurrences[slug, default: 0]
        occurrences[slug] = occurrence + 1
        return occurrence == 0 ? slug : "\(slug)-\(occurrence)"
    }
}

private extension String {
    var isMarkdownBlank: Bool {
        allSatisfy(\.isWhitespace)
    }
}
