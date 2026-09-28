import Foundation

enum MarkdownHTMLRenderingMode: Sendable {
    case preview
    case output
}

/// Wraps parsed Markdown in a self-contained HTML document. App WebViews use
/// isolated scripts; standalone exports can include the trusted Mermaid runtime.
struct MarkdownHTMLRenderer {
    func renderDocument(
        markdown: String,
        documentURL: URL? = nil,
        title: String? = nil,
        includingSourceMap: Bool = true,
        mode: MarkdownHTMLRenderingMode = .preview,
        baseURLOverride: URL? = nil,
        includingMermaidRuntime: Bool = false
    ) -> String {
        let baseElement = (baseURLOverride ?? Self.baseURL(for: documentURL)).map {
            #"<base href="\#(HTMLEscaping.attribute($0.absoluteString))">"#
        } ?? ""

        let normalizedMarkdown = markdown
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let sourceLineCount = normalizedMarkdown.components(separatedBy: "\n").count
        let sourceLineCountAttribute = includingSourceMap
            ? #" data-source-line-count="\#(sourceLineCount)""#
            : ""
        let titleElement = title.map { "<title>\(HTMLEscaping.text($0))</title>" } ?? ""
        let isEmpty = markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        var content: String
        if isEmpty, mode == .preview {
            content = """
            <section class="empty-state" role="status" aria-label="Empty Markdown preview">
              <div class="empty-symbol" aria-hidden="true">M↓</div>
              <h1>Nothing to preview yet</h1>
              <p>Start writing Markdown and the rendered document will appear here.</p>
            </section>
            """
        } else if isEmpty {
            content = ""
        } else {
            content = MarkdownParser(markdown).render(includingSourceMap: includingSourceMap)
        }
        if mode == .output {
            content = content
                .replacingOccurrences(of: #"loading="lazy""#, with: #"loading="eager""#)
                .replacingOccurrences(of: #"decoding="async""#, with: #"decoding="sync""#)
        }

        let bodyElement: String
        if isEmpty, mode == .output {
            bodyElement = ""
        } else {
            bodyElement = """
              <main class="markdown-body" aria-label="Markdown preview"\(sourceLineCountAttribute)>
                \(content)
              </main>
            """
        }

        let includesMermaid = includingMermaidRuntime && content.contains(#"<div class="mermaid-diagram""#)
        let scriptNonce = UUID().uuidString
        let scriptPolicy = includesMermaid ? "'nonce-\(scriptNonce)'" : "'none'"
        let scripts = includesMermaid ? MermaidRendering.standaloneScripts(nonce: scriptNonce) : ""

        return #"""
        <!doctype html>
        <html lang="en">
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
          <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src https: http: file: data: acmd-local:; style-src 'unsafe-inline'; script-src \#(scriptPolicy); connect-src 'none'; object-src 'none'; frame-src 'none'; media-src 'none'; form-action 'none'">
          \#(titleElement)
          \#(baseElement)
          <style>
            :root {
              color-scheme: light dark;
              --background: #ffffff;
              --foreground: #202124;
              --muted: #686b72;
              --faint: #8b8e96;
              --border: #d8dbe0;
              --soft-border: #e8eaed;
              --secondary-background: #f6f7f8;
              --code-background: #f4f5f7;
              --link: #1769c2;
              --quote: #69717c;
              --selection: rgba(35, 116, 217, .22);
              --find-selection: #ffff00;
              --find-selection-foreground: #000000;
              --keyword: #9a1b7a;
              --string: #0b6e44;
              --comment: #747980;
              --number: #9a4d00;
              --shadow: rgba(23, 25, 29, .08);
            }

            @media (prefers-color-scheme: dark) {
              :root {
                --background: #1c1d20;
                --foreground: #eceef1;
                --muted: #a9adb5;
                --faint: #858a93;
                --border: #44474e;
                --soft-border: #34373c;
                --secondary-background: #24262a;
                --code-background: #26282d;
                --link: #64a8f4;
                --quote: #a7adb7;
                --selection: rgba(73, 146, 235, .30);
                --keyword: #ef85d2;
                --string: #7acb9c;
                --comment: #9298a2;
                --number: #e9a86e;
                --shadow: rgba(0, 0, 0, .25);
              }
            }

            * { box-sizing: border-box; }

            html {
              background: var(--background);
              -webkit-text-size-adjust: 100%;
            }

            body {
              margin: 0;
              min-width: 240px;
              min-height: 100vh;
              background: var(--background);
              color: var(--foreground);
              font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", sans-serif;
              font-size: 16px;
              font-weight: 400;
              line-height: 1.62;
              overflow-wrap: anywhere;
              -webkit-font-smoothing: antialiased;
              -webkit-user-select: text;
              user-select: text;
            }

            ::selection { background: var(--selection); }
            html.acmd-find-active ::selection {
              background: var(--find-selection);
              color: var(--find-selection-foreground);
            }

            .markdown-body {
              width: min(100%, 940px);
              margin: 0 auto;
              padding: 30px clamp(24px, 5vw, 58px) 64px;
            }

            h1, h2, h3, h4, h5, h6 {
              margin: 1.45em 0 .55em;
              color: var(--foreground);
              font-weight: 650;
              line-height: 1.25;
              letter-spacing: -.015em;
              scroll-margin-top: 20px;
            }

            h1:first-child, h2:first-child, h3:first-child { margin-top: 0; }
            h1 { padding-bottom: .32em; border-bottom: 1px solid var(--soft-border); font-size: 2em; }
            h2 { padding-bottom: .28em; border-bottom: 1px solid var(--soft-border); font-size: 1.52em; }
            h3 { font-size: 1.26em; }
            h4 { font-size: 1.08em; }
            h5 { font-size: .96em; }
            h6 { color: var(--muted); font-size: .88em; }

            p { margin: 0 0 1em; }
            strong { font-weight: 650; }
            del { color: var(--muted); }

            a {
              color: var(--link);
              text-decoration: none;
              text-underline-offset: .17em;
            }

            a:hover { text-decoration: underline; }
            a:focus-visible { outline: 2px solid var(--link); outline-offset: 3px; border-radius: 2px; }

            code, pre {
              font-family: ui-monospace, "SFMono-Regular", Menlo, Monaco, Consolas, monospace;
              font-variant-ligatures: none;
              tab-size: 4;
            }

            :not(pre) > code {
              margin: 0 .08em;
              padding: .15em .37em;
              border: 1px solid var(--soft-border);
              border-radius: 5px;
              background: var(--code-background);
              font-size: .86em;
              white-space: break-spaces;
            }

            pre {
              margin: 0 0 1.2em;
              padding: 15px 17px;
              overflow: auto;
              border: 1px solid var(--soft-border);
              border-radius: 9px;
              background: var(--code-background);
              box-shadow: 0 1px 0 var(--shadow);
              font-size: .84em;
              line-height: 1.55;
              overflow-wrap: normal;
              -webkit-overflow-scrolling: touch;
            }

            pre code { display: block; min-width: max-content; white-space: pre; }
            .mermaid-diagram { margin: 0 0 1.2em; }
            .mermaid-rendered { overflow-x: auto; text-align: center; }
            .mermaid-rendered svg { display: block; max-width: 100%; height: auto; margin: 0 auto; }
            .mermaid-error { color: var(--muted); font-size: .9em; white-space: pre-wrap; }
            .tok-keyword { color: var(--keyword); font-weight: 600; }
            .tok-string { color: var(--string); }
            .tok-comment { color: var(--comment); font-style: italic; }
            .tok-number { color: var(--number); }

            blockquote {
              margin: 0 0 1.15em;
              padding: .15em 1em;
              border-left: 4px solid var(--border);
              color: var(--quote);
            }

            blockquote > :last-child { margin-bottom: 0; }

            ul, ol {
              margin: 0 0 1em;
              padding-left: 1.85em;
            }

            li { padding-left: .18em; }
            li + li { margin-top: .25em; }
            li > p { margin: 0; }
            li > ul, li > ol { margin-top: .25em; margin-bottom: .25em; }

            .contains-task-list { padding-left: .35em; list-style: none; }
            .task-list-item { position: relative; padding-left: 1.7em; }
            .task-list-item > input[type="checkbox"] {
              position: absolute;
              top: .33em;
              left: 0;
              width: 1.05em;
              height: 1.05em;
              margin: 0;
              accent-color: var(--link);
            }

            hr {
              height: 1px;
              margin: 1.8em 0;
              border: 0;
              background: var(--border);
            }

            .table-scroll {
              max-width: 100%;
              margin: 0 0 1.25em;
              overflow-x: auto;
              border: 1px solid var(--border);
              border-radius: 8px;
            }

            table {
              width: 100%;
              min-width: max-content;
              border-spacing: 0;
              border-collapse: separate;
              font-size: .93em;
            }

            th, td {
              padding: .48em .75em;
              border-right: 1px solid var(--soft-border);
              border-bottom: 1px solid var(--soft-border);
              text-align: left;
              vertical-align: top;
            }

            th:last-child, td:last-child { border-right: 0; }
            tr:last-child td { border-bottom: 0; }
            th { background: var(--secondary-background); font-weight: 650; }
            tbody tr:nth-child(even) { background: color-mix(in srgb, var(--secondary-background) 55%, transparent); }
            .align-left { text-align: left; }
            .align-center { text-align: center; }
            .align-right { text-align: right; }
            .align-none { text-align: left; }

            img {
              display: block;
              max-width: 100%;
              height: auto;
              margin: .35em auto 1.2em;
              border-radius: 7px;
            }

            p > img { margin-bottom: .3em; }

            .empty-state {
              display: grid;
              min-height: min(68vh, 560px);
              place-content: center;
              justify-items: center;
              padding: 32px;
              color: var(--muted);
              text-align: center;
            }

            .empty-symbol {
              display: grid;
              width: 52px;
              height: 52px;
              margin-bottom: 15px;
              place-items: center;
              border: 1px solid var(--border);
              border-radius: 12px;
              background: var(--secondary-background);
              color: var(--faint);
              font: 600 17px/1 ui-monospace, "SFMono-Regular", Menlo, monospace;
              box-shadow: 0 4px 16px var(--shadow);
            }

            .empty-state h1 {
              margin: 0 0 5px;
              padding: 0;
              border: 0;
              color: var(--foreground);
              font-size: 1.05em;
              letter-spacing: 0;
            }

            .empty-state p { max-width: 350px; margin: 0; font-size: .91em; }

            @media (max-width: 520px) {
              .markdown-body { padding: 22px 18px 48px; }
              h1 { font-size: 1.72em; }
              h2 { font-size: 1.38em; }
              pre { margin-left: -5px; margin-right: -5px; border-radius: 7px; }
            }

            @media print {
              @page { margin: .65in .7in .7in; }
              :root {
                color-scheme: light;
                --background: #ffffff;
                --foreground: #000000;
                --muted: #555555;
                --faint: #666666;
                --border: #b8b8b8;
                --soft-border: #d8d8d8;
                --secondary-background: #f4f4f4;
                --code-background: #f3f3f3;
                --link: #000000;
                --quote: #444444;
                --keyword: #54134f;
                --string: #145c35;
                --comment: #555555;
                --number: #713a00;
                --shadow: transparent;
              }
              html, body {
                min-width: 0;
                min-height: 0;
                background: #ffffff !important;
                color: #000000 !important;
                -webkit-print-color-adjust: exact;
                print-color-adjust: exact;
              }
              .markdown-body { width: 100%; max-width: none; padding: 0; }
              a { color: inherit; text-decoration: underline; }
              h1, h2, h3, h4, h5, h6 { break-after: avoid-page; }
              p, blockquote, img, pre, table, .table-scroll, .mermaid-diagram { break-inside: avoid-page; }
              pre {
                overflow: visible;
                white-space: pre-wrap;
                overflow-wrap: anywhere;
                box-shadow: none;
              }
              pre code { min-width: 0; white-space: pre-wrap; }
              .table-scroll { overflow: visible; box-shadow: none; }
              table { min-width: 0; }
              thead { display: table-header-group; }
            }
          </style>
        </head>
        <body>
        \#(bodyElement)
        \#(scripts)
        </body>
        </html>
        """#
    }

    static func baseURL(for documentURL: URL?) -> URL? {
        guard let documentURL else { return nil }
        if documentURL.isFileURL {
            let directory = documentURL.hasDirectoryPath
                ? documentURL
                : documentURL.deletingLastPathComponent()
            return URL(fileURLWithPath: directory.standardizedFileURL.path, isDirectory: true)
        }
        return documentURL.hasDirectoryPath ? documentURL : documentURL.deletingLastPathComponent()
    }
}
