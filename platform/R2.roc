import Host

## Read and write [R2](https://developers.cloudflare.com/r2/) objects.
##
## `binding` is the name declared in `wrangler.jsonc` under `r2_buckets`, not
## the bucket name.
##
## Bodies are `Str`, so this only handles UTF-8 objects. Binary objects need a
## `List(U8)` API, which does not exist yet.
R2 := [].{
    ## Read the object stored at `key`.
    get! : Str, Str => Try(Str, [R2NotFound, R2Err(Str), ..])
    get! = |binding, key|
        match Host.r2_get!(binding, key) {
            Ok(body) => Ok(body)
            Err(R2NotFound) => Err(R2NotFound)
            Err(R2Err(err)) => Err(R2Err(err))
        }

    ## Write `body` at `key`, replacing any existing object.
    put! : Str, Str, Str => Try({}, [R2Err(Str), ..])
    put! = |binding, key, body|
        match Host.r2_put!(binding, key, body) {
            Ok({}) => Ok({})
            Err(R2Err(err)) => Err(R2Err(err))
        }

    ## Delete the object at `key`. Deleting an absent key succeeds.
    delete! : Str, Str => Try({}, [R2Err(Str), ..])
    delete! = |binding, key|
        match Host.r2_delete!(binding, key) {
            Ok({}) => Ok({})
            Err(R2Err(err)) => Err(R2Err(err))
        }
}
