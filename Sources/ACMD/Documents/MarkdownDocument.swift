import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static let acmdMarkdown = UTType(
        importedAs: "net.daringfireball.markdown",
        conformingTo: .plainText
    )
}

struct MarkdownDocument: FileDocument {
    static var readableContentTypes: [UTType] {
        [.acmdMarkdown]
    }

    static var writableContentTypes: [UTType] {
        [.acmdMarkdown]
    }

    var text: String

    init(text: String = "") {
        self.text = text
    }

    init(data: Data) throws {
        let utf8Data: Data
        if data.starts(with: [0xEF, 0xBB, 0xBF]) {
            utf8Data = data.dropFirst(3)
        } else {
            utf8Data = data
        }

        guard let decoded = String(data: utf8Data, encoding: .utf8) else {
            throw CocoaError(
                .fileReadInapplicableStringEncoding,
                userInfo: [NSLocalizedDescriptionKey: "This Markdown file is not valid UTF-8."]
            )
        }
        text = decoded
    }

    var encodedUTF8Data: Data {
        Data(text.utf8)
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }

        try self.init(data: data)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: encodedUTF8Data)
    }
}
