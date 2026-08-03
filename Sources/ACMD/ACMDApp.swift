import SwiftUI

@main
struct ACMDApp: App {
    var body: some Scene {
        DocumentGroup(newDocument: MarkdownDocument()) { configuration in
            DocumentView(
                document: configuration.$document,
                fileURL: configuration.fileURL
            )
        }
        .commands {
            MarkdownCommands()
        }
    }
}
