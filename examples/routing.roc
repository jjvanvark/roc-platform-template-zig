app [main!] { pf: platform "../platform/main.roc" }

import pf.Request exposing [Request]
import pf.Response exposing [Response]

## Returns a different status depending on the path.
main! : Request => Response
main! = |request| {
    match Str.ends_with(request.url, "/health") {
        True => { status: 200, headers: [], body: "ok\n" }
        False => { status: 404, headers: [], body: "not found\n" }
    }
}
