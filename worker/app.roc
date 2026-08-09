app [main!] { pf: platform "../platform/main.roc" }

import pf.Stdout
import pf.Request exposing [Request]
import pf.Response exposing [Response]

## Responds to every request with a plain-text summary of it.
main! : Request => Response
main! = |request| {
    _ = Stdout.line!("${request.method} ${request.url}")

    header_lines = request.headers.map(|h| "  ${h.name}: ${h.value}")

    {
        status: 200,
        headers: [{ name: "x-powered-by", value: "roc" }],
        body: "Hello from Roc, running on Cloudflare Workers\nMethod: ${request.method}\nURL: ${request.url}\nHeaders:\n${Str.join_with(header_lines, "\n")}\nBody: ${request.body}\n",
    }
}
