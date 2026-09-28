import Foundation
import WebKit

/// Runs the bundled renderer in WebKit's isolated world. Markdown never gains
/// permission to run page scripts; standalone HTML permits only our runtime.
enum MermaidRendering {
    // SwiftPM's generated accessor looks beside the executable's main bundle.
    // A distributable macOS app stores resources under Contents/Resources.
    private static let resourceBundle: Bundle = {
        if let resourceURL = Bundle.main.resourceURL,
           let bundle = Bundle(url: resourceURL.appendingPathComponent("ACMD_ACMD.bundle")) {
            return bundle
        }
        return Bundle.module
    }()
    private static let librarySource = resource(named: "mermaid.min")
    private static let bootstrapSource = resource(named: "render")

    private static func resource(named name: String) -> String {
        guard let url = resourceBundle.url(
            forResource: name,
            withExtension: "js",
            subdirectory: "Mermaid"
        ), let source = try? String(contentsOf: url, encoding: .utf8) else {
            preconditionFailure("Missing bundled Mermaid resource: \(name)")
        }
        return source
    }

    @MainActor
    static func install(in configuration: WKWebViewConfiguration, forPrint: Bool = false) {
        configuration.userContentController.addUserScript(WKUserScript(
            source: """
            if (document.querySelector('.mermaid-diagram')) {
              \(librarySource)
              window.__acmdMermaidForceLight = \(forPrint);
              \(bootstrapSource)
            }
            """,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true,
            in: .defaultClient
        ))
    }

    /// A data URL keeps the vendored JavaScript separate from HTML parsing and
    /// from export's image rewriting. Both scripts require the document nonce.
    static func standaloneScripts(nonce: String) -> String {
        let encodedLibrary = Data(librarySource.utf8).base64EncodedString()
        return """
        <script nonce="\(nonce)" src="data:text/javascript;base64,\(encodedLibrary)"></script>
        <script nonce="\(nonce)">\(bootstrapSource)</script>
        """
    }

    static let waitUntilReadyScript = "await window.__acmdMermaidReady; return true;"
}
