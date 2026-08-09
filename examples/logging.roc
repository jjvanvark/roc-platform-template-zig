app [main!] { pf: platform "../platform/main.roc" }

import pf.Stdout
import pf.Stderr
import pf.Request exposing [Request]
import pf.Response exposing [Response]

## Anything written to stdout or stderr shows up in `wrangler tail`.
main! : Request => Response
main! = |request| {
    _ = Stdout.line!("handling ${request.method} ${request.url}")
    _ = Stderr.line!("this goes to the error log")

    Response.text(200, [], "Logged.\n")
}
