## A single HTTP header.
##
## Cloudflare lowercases incoming header names, and joins repeated headers into
## one comma-separated value, so `name` is unique within a request's headers.
Header := {
    ## The header name, e.g. `"content-type"`.
    name : Str,
    ## The header value.
    value : Str,
}
