app [main!] { pf: platform "../platform/main.roc" }

import pf.Queue
import pf.Request exposing [Request]
import pf.Response exposing [Response]

## Pushes the request body onto a queue.
##
## Queue messages are text, but the request body is bytes, so the body has to be
## decoded first — and a body that is not UTF-8 is a client error, not a crash.
##
## Only producing is supported; consuming needs a `queue` handler, which the
## platform does not expose yet.
main! : Request => Response
main! = |request| {
    match request.text() {
        Err(_) => Response.text(400, [], "body must be UTF-8\n")
        Ok(body) =>
            match Queue.send!("JOBS", body) {
                Ok({}) => Response.text(202, [], "queued\n")
                Err(QueueErr(message)) => Response.text(500, [], "Queue error: ${message}\n")
            }
    }
}
