## The HTTP response to send back.
##
## Headers are not modelled yet, so the embedder sends a `text/plain` body.
Response := {
    ## The HTTP status code, e.g. `200` or `404`.
    status : U16,
    ## The response body.
    body : Str,
}
