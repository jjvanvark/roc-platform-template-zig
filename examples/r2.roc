app [main!] { pf: platform "../platform/main.roc" }

import pf.R2
import pf.Request exposing [Request]
import pf.Response exposing [Response]

## Stores the request body at the request path, and reads it back.
##
## PUT writes, GET reads, DELETE removes.
##
## Bodies are bytes the whole way through, so this round-trips any content —
## an image or a zip comes back byte for byte, not just UTF-8 text.
main! : Request => Response
main! = |request| {
    key = request.url

    match request.method {
        "PUT" =>
            match R2.put!("BUCKET", key, request.body) {
                Ok({}) => Response.text(201, [], "stored\n")
                Err(R2Err(message)) => Response.text(500, [], "R2 error: ${message}\n")
            }

        "DELETE" =>
            match R2.delete!("BUCKET", key) {
                Ok({}) => Response.text(204, [], "")
                Err(R2Err(message)) => Response.text(500, [], "R2 error: ${message}\n")
            }

        _ =>
            match R2.get!("BUCKET", key) {
                # The object's bytes go straight back out as the response body.
                Ok(body) => { status: 200, headers: [], body }
                Err(R2NotFound) => Response.text(404, [], "not found\n")
                Err(R2Err(message)) => Response.text(500, [], "R2 error: ${message}\n")
            }
    }
}
