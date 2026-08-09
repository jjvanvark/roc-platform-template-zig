app [main!] { pf: platform "../platform/main.roc" }

import pf.Request exposing [Request]
import pf.Response exposing [Response]

## Echoes the request back as plain text.
main! : Request => Response
main! = |request| {
    { status: 200, body: "${request.method} ${request.url}\n${request.body}" }
}
