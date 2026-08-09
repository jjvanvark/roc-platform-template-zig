import Header exposing [Header]

## The HTTP response to send back.
Response := {
    ## The HTTP status code, e.g. `200` or `404`.
    status : U16,
    ## The response headers. When empty, the embedder sends `text/plain`.
    headers : List(Header),
    ## The response body.
    body : Str,
}
