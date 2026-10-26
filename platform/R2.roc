import Host

## Read and write [R2](https://developers.cloudflare.com/r2/) objects.
##
## `binding` is the name declared in `wrangler.jsonc` under `r2_buckets`, not
## the bucket name.
##
## Bodies are `List(U8)`, so an object can hold anything — an image, a zip, a
## gzipped export. `get_text!` and `put_text!` cover the UTF-8 case.
R2 := [].{
    ## Read the object stored at `key`.
    get! : Str, Str => Try(List(U8), [R2NotFound, R2Err(Str)])
    get! = |binding, key|
        match Host.r2_get!(binding, key) {
            Ok(body) => Ok(body)
            Err(R2NotFound) => Err(R2NotFound)
            Err(R2Err(err)) => Err(R2Err(err))
        }

    ## Write `body` at `key`, replacing any existing object.
    put! : Str, Str, List(U8) => Try({}, [R2Err(Str)])
    put! = |binding, key, body|
        match Host.r2_put!(binding, key, body) {
            Ok({}) => Ok({})
            Err(R2Err(err)) => Err(R2Err(err))
        }

    ## Read the object at `key` and decode it as UTF-8.
    ##
    ## An object that is not valid UTF-8 comes back as `R2Err` rather than a
    ## separate tag, so the error union matches `get!`. Reach for `get!` when
    ## the object might not be text.
    get_text! : Str, Str => Try(Str, [R2NotFound, R2Err(Str)])
    get_text! = |binding, key|
        match Host.r2_get!(binding, key) {
            Ok(body) =>
                match Str.from_utf8(body) {
                    Ok(text) => Ok(text)
                    Err(_) => Err(R2Err("the object at ${key} is not valid UTF-8"))
                }

            Err(R2NotFound) => Err(R2NotFound)
            Err(R2Err(err)) => Err(R2Err(err))
        }

    ## Write `body` at `key` as UTF-8 text, replacing any existing object.
    put_text! : Str, Str, Str => Try({}, [R2Err(Str)])
    put_text! = |binding, key, body|
        match Host.r2_put!(binding, key, Str.to_utf8(body)) {
            Ok({}) => Ok({})
            Err(R2Err(err)) => Err(R2Err(err))
        }

    ## Delete the object at `key`. Deleting an absent key succeeds.
    delete! : Str, Str => Try({}, [R2Err(Str)])
    delete! = |binding, key|
        match Host.r2_delete!(binding, key) {
            Ok({}) => Ok({})
            Err(R2Err(err)) => Err(R2Err(err))
        }
}
