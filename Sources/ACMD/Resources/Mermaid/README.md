# Bundled Mermaid runtime

`mermaid.min.js` is the unmodified browser bundle from Mermaid 12.0.0 (MIT):
https://registry.npmjs.org/mermaid/-/mermaid-12.0.0.tgz

Package integrity (SHA-512, base64):
`/wQXC9iBxoGV8p3erbvaXs9h77VyLDBH6GdayVjj3hEcSQhFU4N1WUhUppotCEqlIxI2pRMwjwBSwTB1MfZBgQ==`

The upstream license is in `LICENSE`; dependency notices are retained in the
bundle. `render.js` is ACMD's integration. No network access or Node installation
is needed to build or use the app. When updating, verify the npm archive's
integrity and replace the browser bundle and license together, then run the
WebKit integration tests (including standalone HTML and print readiness).
