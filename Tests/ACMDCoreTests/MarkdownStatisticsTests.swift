import XCTest
@testable import ACMDCore

final class MarkdownStatisticsTests: XCTestCase {
    func testCountsUnicodeWordsCharactersAndCRLFLines() {
        let statistics = MarkdownStatistics(text: "Hello, café 🙂\r\nSecond line")
        XCTAssertEqual(statistics.wordCount, 4)
        XCTAssertEqual(statistics.characterCount, 25)
        XCTAssertEqual(statistics.characterCountExcludingWhitespace, 21)
        XCTAssertEqual(statistics.lineCount, 2)
        XCTAssertEqual(statistics.estimatedReadingMinutes, 1)
    }

    func testEmptyDocumentHasOneLineAndNoReadingTime() {
        let statistics = MarkdownStatistics(text: "")
        XCTAssertEqual(statistics.wordCount, 0)
        XCTAssertEqual(statistics.characterCount, 0)
        XCTAssertEqual(statistics.lineCount, 1)
        XCTAssertEqual(statistics.estimatedReadingMinutes, 0)
    }
}
