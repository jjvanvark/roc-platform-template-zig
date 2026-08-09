app [main!] { pf: platform "../platform/main.roc" }

import pf.Queue
import pf.Request exposing [Request]
import pf.Response exposing [Response]

## Pushes the request body onto a queue.
##
## Only producing is supported; consuming needs a `queue` handler, which the
## platform does not expose yet.
main! : Request => Response
main! = |request| {
    match Queue.send!("JOBS", request.body) {
        Ok({}) => { status: 202, headers: [], body: "queued\n" }
        Err(QueueErr(message)) => { status: 500, headers: [], body: "Queue error: ${message}\n" }
    }
}
