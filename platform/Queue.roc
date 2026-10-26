import Host

## Send messages to a [Queue](https://developers.cloudflare.com/queues/).
##
## `binding` is the name declared in `wrangler.jsonc` under `queues.producers`.
##
## Only producing is supported. Consuming needs a `queue` handler alongside
## `fetch`, which the platform does not expose yet.
Queue := [].{
    ## Send one message. The body is sent as text.
    send! : Str, Str => Try({}, [QueueErr(Str)])
    send! = |binding, body|
        match Host.queue_send!(binding, body) {
            Ok({}) => Ok({})
            Err(QueueErr(err)) => Err(QueueErr(err))
        }
}
