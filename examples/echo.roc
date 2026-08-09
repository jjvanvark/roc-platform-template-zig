app [main!] { pf: platform "../platform/main.roc" }

import pf.Request exposing [Request]
import pf.Response exposing [Response]

## Echoes the request back as plain text, headers included.
main! : Request => Response
main! = |request| {
    header_lines = request.headers.map(|h| "${h.name}: ${h.value}")

    {
        status: 200,
        headers: [],
        body: "${request.method} ${request.url}\n${Str.join_with(header_lines, "\n")}\n${request.body}",
    }
}
