app [main!] { pf: platform "../platform/main.roc" }

import pf.Request exposing [Request]
import pf.Response exposing [Response]

## Returns a different status depending on the path.
main! : Request => Response
main! = |request| {
    match Str.ends_with(request.url, "/health") {
        True => Response.text(200, [], "ok\n")
        False => Response.text(404, [], "not found\n")
    }
}
