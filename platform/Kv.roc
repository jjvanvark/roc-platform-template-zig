import Host

## Read and write [Workers KV](https://developers.cloudflare.com/kv/).
##
## `binding` is the name declared in `wrangler.jsonc` under `kv_namespaces`,
## not the namespace id.
Kv := [].{
    ## Read the value stored at `key`.
    ##
    ## Returns `Err(KvNotFound)` when the key is absent, and `Err(KvErr(message))`
    ## when the binding does not exist or the read fails.
    get! : Str, Str => Try(Str, [KvNotFound, KvErr(Str)])
    get! = |binding, key|
        match Host.kv_get!(binding, key) {
            Ok(value) => Ok(value)
            Err(KvNotFound) => Err(KvNotFound)
            Err(KvErr(err)) => Err(KvErr(err))
        }

    ## Write `value` at `key`.
    ##
    ## KV is eventually consistent: a read straight after a write can still see
    ## the old value.
    put! : Str, Str, Str => Try({}, [KvErr(Str)])
    put! = |binding, key, value|
        match Host.kv_put!(binding, key, value) {
            Ok({}) => Ok({})
            Err(KvErr(err)) => Err(KvErr(err))
        }
}
