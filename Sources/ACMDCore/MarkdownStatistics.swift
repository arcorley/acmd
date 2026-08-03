import Foundation

/// Text statistics suitable for an editor status bar.
public struct MarkdownStatistics: Equatable, Sendable {
    public let wordCount: Int
    public let characterCount: Int
    public let characterCountExcludingWhitespace: Int
    public let lineCount: Int
    public let estimatedReadingMinutes: Int

    public init(text: String) {
        let source = text as NSString
        let expression = try? NSRegularExpression(
            pattern: #"[\p{L}\p{N}]+(?:['’][\p{L}\p{N}]+)*"#
        )
        wordCount = expression?.numberOfMatches(
            in: text,
            range: NSRange(location: 0, length: source.length)
        ) ?? 0
        characterCount = text.count
        characterCountExcludingWhitespace = text.reduce(into: 0) { count, character in
            if !character.isWhitespace { count += 1 }
        }
        lineCount = Self.countLines(in: source)
        estimatedReadingMinutes = wordCount == 0 ? 0 : Int(ceil(Double(wordCount) / 200.0))
    }

    private static func countLines(in source: NSString) -> Int {
        guard source.length > 0 else { return 1 }
        var count = 1
        var cursor = 0
        while cursor < source.length {
            let character = source.character(at: cursor)
            if character == unichar(13) {
                count += 1
                cursor += 1
                if cursor < source.length, source.character(at: cursor) == unichar(10) { cursor += 1 }
            } else if character == unichar(10) {
                count += 1
                cursor += 1
            } else {
                cursor += 1
            }
        }
        return count
    }
}
