app [main!] { pf: platform "../platform/main.roc" }

import pf.Request exposing [Request]
import pf.Response exposing [Response]

main! : Request => Response
main! = |_request| {
    { status: 200, headers: [], body: "Hello, World!\n" }
}
