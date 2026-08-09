app [main!] { pf: platform "../platform/main.roc" }

import pf.R2
import pf.Request exposing [Request]
import pf.Response exposing [Response]

## Stores the request body at the request path, and reads it back.
##
## PUT writes, GET reads, DELETE removes.
main! : Request => Response
main! = |request| {
    key = request.url

    match request.method {
        "PUT" =>
            match R2.put!("BUCKET", key, request.body) {
                Ok({}) => { status: 201, headers: [], body: "stored\n" }
                Err(R2Err(message)) => { status: 500, headers: [], body: "R2 error: ${message}\n" }
            }

        "DELETE" =>
            match R2.delete!("BUCKET", key) {
                Ok({}) => { status: 204, headers: [], body: "" }
                Err(R2Err(message)) => { status: 500, headers: [], body: "R2 error: ${message}\n" }
            }

        _ =>
            match R2.get!("BUCKET", key) {
                Ok(body) => { status: 200, headers: [], body: body }
                Err(R2NotFound) => { status: 404, headers: [], body: "not found\n" }
                Err(R2Err(message)) => { status: 500, headers: [], body: "R2 error: ${message}\n" }
            }
    }
}
