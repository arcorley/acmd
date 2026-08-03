import Foundation
import UniformTypeIdentifiers
import XCTest
@testable import ACMD

final class MarkdownDocumentTests: XCTestCase {
    func testUnicodeRoundTripUsesUTF8() throws {
        let text = "# Café 🚀\n日本語 and مرحبا"

        let encoded = MarkdownDocument(text: text).encodedUTF8Data
        let decoded = try MarkdownDocument(data: encoded)

        XCTAssertEqual(encoded, text.data(using: .utf8))
        XCTAssertEqual(decoded.text, text)
    }

    func testUTF8BOMIsRemovedWhenReading() throws {
        var data = Data([0xEF, 0xBB, 0xBF])
        data.append(contentsOf: "# BOM ✅".utf8)

        let document = try MarkdownDocument(data: data)

        XCTAssertEqual(document.text, "# BOM ✅")
        XCTAssertFalse(document.encodedUTF8Data.starts(with: [0xEF, 0xBB, 0xBF]))
    }

    func testInvalidUTF8IsRejected() {
        let invalidUTF8 = Data([0xC3, 0x28])

        XCTAssertThrowsError(try MarkdownDocument(data: invalidUTF8)) { error in
            let cocoaError = error as NSError
            XCTAssertEqual(cocoaError.domain, NSCocoaErrorDomain)
            XCTAssertEqual(
                cocoaError.code,
                CocoaError.Code.fileReadInapplicableStringEncoding.rawValue
            )
        }
    }

    func testBlankDataProducesBlankDocument() throws {
        let document = try MarkdownDocument(data: Data())

        XCTAssertEqual(document.text, "")
        XCTAssertEqual(document.encodedUTF8Data, Data())
    }

    func testContentTypesDescribeMarkdownReadWriteSupport() {
        XCTAssertEqual(MarkdownDocument.readableContentTypes, [.acmdMarkdown])
        XCTAssertEqual(MarkdownDocument.writableContentTypes, [.acmdMarkdown])
        XCTAssertEqual(UTType.acmdMarkdown.identifier, "net.daringfireball.markdown")
        XCTAssertTrue(UTType.acmdMarkdown.conforms(to: .plainText))
    }
}
