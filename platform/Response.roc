import Header exposing [Header]

## The HTTP response to send back.
Response := {
    ## The HTTP status code, e.g. `200` or `404`.
    status : U16,
    ## The response headers. When empty, the embedder sends `text/plain`.
    headers : List(Header),
    ## The raw response body. Use `text` to build one from a `Str`.
    body : List(U8),
}.{
    ## Build a response whose body is UTF-8 text.
    ##
    ## ```roc
    ## Response.text(200, [], "Hello, World!\n")
    ## ```
    text : U16, List(Header), Str -> Response
    text = |status, headers, body| {
        status,
        headers,
        body: Str.to_utf8(body),
    }
}
