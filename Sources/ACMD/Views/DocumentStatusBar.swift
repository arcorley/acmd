import ACMDCore
import SwiftUI

struct DocumentStatusBar: View {
    let text: String
    @ObservedObject var controller: MarkdownEditorController
    @State private var statistics = MarkdownStatistics(text: "")

    var body: some View {
        HStack(spacing: 14) {
            Text("\(statistics.wordCount) \(statistics.wordCount == 1 ? "word" : "words")")
            Text("\(statistics.characterCount) characters")
            Text("\(statistics.lineCount) \(statistics.lineCount == 1 ? "line" : "lines")")
            Spacer()
            if controller.selectedCharacterCount > 0 {
                Text("\(controller.selectedCharacterCount) selected")
                    .monospacedDigit()
            }
            Text("Ln \(controller.currentLine), Col \(controller.currentColumn)")
                .monospacedDigit()
            if statistics.estimatedReadingMinutes > 0 {
                Label("\(statistics.estimatedReadingMinutes) min read", systemImage: "clock")
            }
            Text("Markdown")
                .fontWeight(.medium)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .frame(height: 27)
        .background(.bar)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            accessibilitySummary
        )
        .task(id: text) {
            do {
                try await Task.sleep(nanoseconds: 100_000_000)
            } catch {
                return
            }
            let input = text
            let updated = await Task.detached(priority: .utility) {
                MarkdownStatistics(text: input)
            }.value
            guard !Task.isCancelled else { return }
            statistics = updated
        }
    }

    private var accessibilitySummary: String {
        var summary = "Document statistics: \(statistics.wordCount) words, \(statistics.characterCount) characters, \(statistics.lineCount) lines. Line \(controller.currentLine), column \(controller.currentColumn)."
        if controller.selectedCharacterCount > 0 {
            summary += " \(controller.selectedCharacterCount) characters selected."
        }
        return summary
    }
}
