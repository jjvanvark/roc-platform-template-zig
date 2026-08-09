app [main!] { pf: platform "../platform/main.roc" }

import pf.Header exposing [Header]
import pf.Request exposing [Request]
import pf.Response exposing [Response]

## Reads a request header and sets response headers.
##
## Cloudflare lowercases incoming header names, so look them up in lower case.
find_header : List(Header), Str -> Str
find_header = |headers, name|
    match List.find_first(headers, |h| h.name == name) {
        Ok(header) => header.value
        Err(_) => "(absent)"
    }

main! : Request => Response
main! = |request| {
    accept = find_header(request.headers, "accept")

    Response.text(
        200,
        [
            { name: "content-type", value: "text/plain; charset=utf-8" },
            { name: "x-powered-by", value: "roc" },
        ],
        "accept: ${accept}\n",
    )
}
