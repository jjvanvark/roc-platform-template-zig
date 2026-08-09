app [main!] { pf: platform "../platform/main.roc" }

import pf.Stdout
import pf.Request exposing [Request]
import pf.Response exposing [Response]

## Responds to every request with a plain-text summary of it.
main! : Request => Response
main! = |request| {
    _ = Stdout.line!("${request.method} ${request.url}")

    {
        status: 200,
        body: "Hello from Roc, running on Cloudflare Workers\nMethod: ${request.method}\nURL: ${request.url}\n",
    }
}
