app [main!] { pf: platform "../platform/main.roc" }

import pf.Request exposing [Request]
import pf.Response exposing [Response]

## Echoes the request back as plain text, headers included.
##
## The body is bytes, so echoing it as text means decoding it. This uses the
## lossy decode: an echo endpoint should answer even when handed a JPEG.
main! : Request => Response
main! = |request| {
    header_lines = request.headers.map(|h| "${h.name}: ${h.value}")

    Response.text(
        200,
        [],
        "${request.method} ${request.url}\n${Str.join_with(header_lines, "\n")}\n${request.text_lossy()}",
    )
}
