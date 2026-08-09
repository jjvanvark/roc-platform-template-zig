app [main!] { pf: platform "../platform/main.roc" }

import pf.Kv
import pf.Request exposing [Request]
import pf.Response exposing [Response]

## A hit counter kept in Workers KV.
##
## KV is eventually consistent, so a read straight after a write can still
## return the old value. Don't use it where you need read-after-write.
main! : Request => Response
main! = |_request| {
    read = Kv.get!("COUNTER", "hits")

    match read {
        Err(KvErr(message)) => { status: 500, headers: [], body: "KV error: ${message}\n" }
        Err(KvNotFound) => bump!("0")
        Ok(value) => bump!(value)
    }
}

bump! : Str => Response
bump! = |previous| {
    count = match U64.from_str(previous) {
        Ok(n) => n
        Err(_) => 0
    }
    next = U64.to_str(count + 1)

    match Kv.put!("COUNTER", "hits", next) {
        Ok({}) => { status: 200, headers: [], body: "hits: ${next}\n" }
        Err(KvErr(message)) => { status: 500, headers: [], body: "KV error: ${message}\n" }
    }
}
