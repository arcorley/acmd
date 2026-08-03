import Foundation

/// A small, deterministic lexer used for fenced-code previews.
///
/// It intentionally recognizes only comments, strings, numbers, and common
/// keywords. Unknown languages still receive useful string and number coloring.
struct CodeSyntaxHighlighter {
    func highlight(_ source: String, language: String?) -> String {
        let family = LanguageFamily(language: language)
        let characters = Array(source)
        var output = ""
        output.reserveCapacity(source.utf8.count + source.utf8.count / 3)

        var index = 0
        while index < characters.count {
            if let token = comment(in: characters, at: index, family: family) {
                appendToken(characters[token.range], cssClass: "tok-comment", to: &output)
                index = token.range.upperBound
                continue
            }

            if let token = string(in: characters, at: index, family: family) {
                appendToken(characters[token.range], cssClass: "tok-string", to: &output)
                index = token.range.upperBound
                continue
            }

            if let end = numberEnd(in: characters, at: index) {
                appendToken(characters[index..<end], cssClass: "tok-number", to: &output)
                index = end
                continue
            }

            if isIdentifierStart(characters[index]) {
                let end = identifierEnd(in: characters, at: index)
                let identifier = String(characters[index..<end])
                if family.isKeyword(identifier) {
                    appendToken(characters[index..<end], cssClass: "tok-keyword", to: &output)
                } else {
                    output += HTMLEscaping.text(identifier)
                }
                index = end
                continue
            }

            output += HTMLEscaping.text(String(characters[index]))
            index += 1
        }

        return output
    }
}

private extension CodeSyntaxHighlighter {
    struct Token {
        let range: Range<Int>
    }

    func appendToken(
        _ characters: ArraySlice<Character>,
        cssClass: String,
        to output: inout String
    ) {
        output += #"<span class=""#
        output += cssClass
        output += #"">"#
        output += HTMLEscaping.text(String(characters))
        output += "</span>"
    }

    func comment(
        in characters: [Character],
        at index: Int,
        family: LanguageFamily
    ) -> Token? {
        for (opening, closing) in family.blockComments {
            guard matches(opening, in: characters, at: index) else { continue }
            let contentStart = index + opening.count
            let end = find(closing, in: characters, from: contentStart)
                .map { $0 + closing.count } ?? characters.count
            return Token(range: index..<end)
        }

        for marker in family.lineComments where matches(marker, in: characters, at: index) {
            var end = index + marker.count
            while end < characters.count, characters[end] != "\n", characters[end] != "\r" {
                end += 1
            }
            return Token(range: index..<end)
        }

        return nil
    }

    func string(
        in characters: [Character],
        at index: Int,
        family: LanguageFamily
    ) -> Token? {
        if family.supportsTripleQuotedStrings {
            for delimiter in [Array("\"\"\""), Array("'''")] where matches(delimiter, in: characters, at: index) {
                let contentStart = index + delimiter.count
                let end = find(delimiter, in: characters, from: contentStart)
                    .map { $0 + delimiter.count } ?? characters.count
                return Token(range: index..<end)
            }
        }

        let quote = characters[index]
        guard family.stringDelimiters.contains(quote) else { return nil }

        var end = index + 1
        var escaped = false
        while end < characters.count {
            let character = characters[end]
            if escaped {
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == quote {
                return Token(range: index..<(end + 1))
            } else if (character == "\n" || character == "\r") && quote != "`" {
                return Token(range: index..<end)
            }
            end += 1
        }
        return Token(range: index..<characters.count)
    }

    func numberEnd(in characters: [Character], at index: Int) -> Int? {
        guard characters[index].isNumber else { return nil }
        if index > 0, isIdentifierContinuation(characters[index - 1]) {
            return nil
        }

        var end = index
        if characters[index] == "0", index + 2 <= characters.count, index + 1 < characters.count {
            let prefix = characters[index + 1].lowercased()
            if prefix == "x" || prefix == "b" || prefix == "o" {
                end = index + 2
                let digitsStart = end
                while end < characters.count {
                    let character = characters[end]
                    let isValid: Bool
                    switch prefix {
                    case "x": isValid = character.isHexDigit || character == "_"
                    case "b": isValid = character == "0" || character == "1" || character == "_"
                    default: isValid = ("0"..."7").contains(character) || character == "_"
                    }
                    guard isValid else { break }
                    end += 1
                }
                guard end > digitsStart else { return nil }
            }
        }

        if end == index {
            end = index
            while end < characters.count, characters[end].isNumber || characters[end] == "_" {
                end += 1
            }
            if end + 1 < characters.count, characters[end] == ".", characters[end + 1].isNumber {
                end += 1
                while end < characters.count, characters[end].isNumber || characters[end] == "_" {
                    end += 1
                }
            }
            if end < characters.count, characters[end] == "e" || characters[end] == "E" {
                var exponentEnd = end + 1
                if exponentEnd < characters.count,
                   characters[exponentEnd] == "+" || characters[exponentEnd] == "-" {
                    exponentEnd += 1
                }
                let exponentStart = exponentEnd
                while exponentEnd < characters.count,
                      characters[exponentEnd].isNumber || characters[exponentEnd] == "_" {
                    exponentEnd += 1
                }
                if exponentEnd > exponentStart { end = exponentEnd }
            }
        }

        if end < characters.count, isIdentifierContinuation(characters[end]) {
            return nil
        }
        return end
    }

    func identifierEnd(in characters: [Character], at index: Int) -> Int {
        var end = index + 1
        while end < characters.count, isIdentifierContinuation(characters[end]) {
            end += 1
        }
        return end
    }

    func isIdentifierStart(_ character: Character) -> Bool {
        character == "_" || character == "$" || character.isLetter
    }

    func isIdentifierContinuation(_ character: Character) -> Bool {
        isIdentifierStart(character) || character.isNumber
    }

    func matches(_ token: [Character], in characters: [Character], at index: Int) -> Bool {
        guard !token.isEmpty, index + token.count <= characters.count else { return false }
        return characters[index..<(index + token.count)].elementsEqual(token)
    }

    func find(_ token: [Character], in characters: [Character], from start: Int) -> Int? {
        guard !token.isEmpty, start < characters.count else { return nil }
        var candidate = start
        while candidate + token.count <= characters.count {
            if matches(token, in: characters, at: candidate) {
                return candidate
            }
            candidate += 1
        }
        return nil
    }
}

private enum LanguageFamily {
    case swift
    case cLike
    case javascript
    case python
    case ruby
    case rust
    case go
    case shell
    case sql
    case web
    case css
    case json
    case yaml
    case generic

    init(language: String?) {
        let name = language?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .split(whereSeparator: \.isWhitespace)
            .first
            .map(String.init) ?? ""

        switch name {
        case "swift": self = .swift
        case "c", "h", "cc", "cpp", "c++", "cxx", "hpp", "objc", "objective-c",
             "java", "kotlin", "kt", "c#", "csharp", "cs", "php", "dart": self = .cLike
        case "javascript", "js", "jsx", "mjs", "cjs", "typescript", "ts", "tsx": self = .javascript
        case "python", "py": self = .python
        case "ruby", "rb": self = .ruby
        case "rust", "rs": self = .rust
        case "go", "golang": self = .go
        case "sh", "shell", "bash", "zsh", "fish", "console": self = .shell
        case "sql", "postgres", "postgresql", "mysql", "sqlite": self = .sql
        case "html", "xml", "svg": self = .web
        case "css", "scss", "sass", "less": self = .css
        case "json", "jsonc": self = .json
        case "yaml", "yml", "toml": self = .yaml
        default: self = .generic
        }
    }

    var lineComments: [[Character]] {
        switch self {
        case .python, .ruby, .shell, .yaml: return [Array("#")]
        case .sql: return [Array("--")]
        case .web: return []
        case .generic: return [Array("//")]
        default: return [Array("//")]
        }
    }

    var blockComments: [([Character], [Character])] {
        switch self {
        case .web: return [(Array("<!--"), Array("-->"))]
        case .cLike, .javascript, .swift, .rust, .go, .sql, .css, .json, .generic:
            return [(Array("/*"), Array("*/"))]
        default: return []
        }
    }

    var stringDelimiters: Set<Character> {
        switch self {
        case .shell: return ["\"", "'", "`"]
        case .javascript: return ["\"", "'", "`"]
        default: return ["\"", "'"]
        }
    }

    var supportsTripleQuotedStrings: Bool {
        self == .python
    }

    func isKeyword(_ identifier: String) -> Bool {
        if self == .sql {
            return keywords.contains(identifier.lowercased())
        }
        return keywords.contains(identifier)
    }

    var keywords: Set<String> {
        switch self {
        case .swift:
            return ["actor", "any", "as", "associatedtype", "async", "await", "break", "case", "catch",
                    "class", "continue", "default", "defer", "deinit", "do", "else", "enum", "extension",
                    "fallthrough", "false", "fileprivate", "for", "func", "guard", "if", "import", "in",
                    "indirect", "init", "inout", "internal", "is", "isolated", "let", "macro", "nil",
                    "nonisolated", "open", "operator", "private", "protocol", "public", "repeat", "return",
                    "self", "some", "static", "struct", "subscript", "super", "switch", "throw", "throws",
                    "true", "try", "typealias", "var", "where", "while"]
        case .cLike:
            return ["abstract", "as", "async", "await", "auto", "bool", "break", "case", "catch", "char",
                    "class", "const", "constexpr", "continue", "default", "delete", "do", "double", "else",
                    "enum", "explicit", "extends", "false", "final", "finally", "float", "for", "foreach",
                    "friend", "func", "goto", "if", "implements", "import", "in", "inline", "int", "interface",
                    "internal", "is", "long", "namespace", "new", "nil", "null", "operator", "override",
                    "package", "private", "protected", "public", "record", "return", "sealed", "short", "signed",
                    "sizeof", "static", "string", "struct", "super", "switch", "synchronized", "template", "this",
                    "throw", "throws", "true", "try", "typedef", "typename", "union", "unsigned", "using", "var",
                    "virtual", "void", "volatile", "when", "while"]
        case .javascript:
            return ["async", "await", "break", "case", "catch", "class", "const", "continue", "debugger",
                    "default", "delete", "do", "else", "enum", "export", "extends", "false", "finally", "for",
                    "from", "function", "get", "if", "implements", "import", "in", "instanceof", "interface", "let",
                    "new", "null", "of", "package", "private", "protected", "public", "return", "set", "static",
                    "super", "switch", "this", "throw", "true", "try", "type", "typeof", "undefined", "var",
                    "void", "while", "with", "yield"]
        case .python:
            return ["False", "None", "True", "and", "as", "assert", "async", "await", "break", "case", "class",
                    "continue", "def", "del", "elif", "else", "except", "finally", "for", "from", "global", "if",
                    "import", "in", "is", "lambda", "match", "nonlocal", "not", "or", "pass", "raise", "return",
                    "try", "while", "with", "yield"]
        case .ruby:
            return ["BEGIN", "END", "alias", "and", "begin", "break", "case", "class", "def", "defined", "do",
                    "else", "elsif", "end", "ensure", "false", "for", "if", "in", "module", "next", "nil", "not",
                    "or", "redo", "rescue", "retry", "return", "self", "super", "then", "true", "undef", "unless",
                    "until", "when", "while", "yield"]
        case .rust:
            return ["Self", "as", "async", "await", "break", "const", "continue", "crate", "dyn", "else", "enum",
                    "extern", "false", "fn", "for", "if", "impl", "in", "let", "loop", "match", "mod", "move",
                    "mut", "pub", "ref", "return", "self", "static", "struct", "super", "trait", "true", "type",
                    "unsafe", "use", "where", "while"]
        case .go:
            return ["break", "case", "chan", "const", "continue", "default", "defer", "else", "fallthrough", "for",
                    "func", "go", "goto", "if", "import", "interface", "map", "package", "range", "return", "select",
                    "struct", "switch", "type", "var"]
        case .shell:
            return ["case", "do", "done", "elif", "else", "esac", "export", "fi", "for", "function", "if", "in",
                    "local", "readonly", "return", "select", "then", "time", "until", "while"]
        case .sql:
            return ["add", "all", "alter", "and", "as", "asc", "begin", "between", "by", "case", "check", "column",
                    "commit", "constraint", "create", "database", "default", "delete", "desc", "distinct", "drop", "else",
                    "end", "exists", "false", "foreign", "from", "full", "group", "having", "in", "index", "inner",
                    "insert", "into", "is", "join", "key", "left", "like", "limit", "not", "null", "on", "or", "order",
                    "outer", "primary", "references", "right", "rollback", "select", "set", "table", "then", "true",
                    "union", "unique", "update", "values", "view", "when", "where", "with"]
        case .css:
            return ["and", "important", "media", "not", "only", "supports", "var"]
        case .json:
            return ["false", "null", "true"]
        case .yaml:
            return ["false", "null", "true", "yes", "no"]
        case .web, .generic:
            return []
        }
    }
}

private extension Character {
    var isHexDigit: Bool {
        isNumber || ("a"..."f").contains(self.lowercased().first ?? self)
    }
}
