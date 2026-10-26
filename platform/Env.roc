import Host

## Read text bindings: [environment variables and secrets](https://developers.cloudflare.com/workers/configuration/environment-variables/).
##
## Variables come from `vars` in `wrangler.jsonc`; secrets are set with
## `wrangler secret put NAME` and read the same way. Roc cannot tell them apart,
## which is the point — a secret is just a var you did not commit.
Env := [].{
    ## Read the text binding called `name`.
    ##
    ## Returns `Err(EnvNotFound)` when there is no such binding, or when the
    ## binding exists but is not text — a KV namespace, say. Use `Kv`, `R2`,
    ## `D1` or `Queue` for those.
    get! : Str => Try(Str, [EnvNotFound, EnvErr(Str)])
    get! = |name|
        match Host.env_get!(name) {
            Ok(value) => Ok(value)
            Err(EnvNotFound) => Err(EnvNotFound)
            Err(EnvErr(err)) => Err(EnvErr(err))
        }

    ## Read the text binding called `name`, falling back to `default`.
    get_or! : Str, Str => Str
    get_or! = |name, default|
        match Host.env_get!(name) {
            Ok(value) => value
            Err(_) => default
        }
}
