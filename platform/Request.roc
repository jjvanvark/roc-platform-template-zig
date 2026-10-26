import Header exposing [Header]

## An incoming HTTP request.
Request := {
    ## The HTTP method, uppercased: `"GET"`, `"POST"`, and so on.
    method : Str,
    ## The full request URL, including scheme, host, path and query string.
    url : Str,
    ## The request headers, with lowercased names.
    headers : List(Header),
    ## The raw request body, empty when there is none.
    ##
    ## Bytes rather than `Str`, because a request body can carry anything —
    ## an image, a protobuf, a gzipped payload. Use `text` for the UTF-8 case.
    body : List(U8),
}.{
    ## Decode the body as UTF-8.
    ##
    ## Returns `Err(BadUtf8(...))` when the body is not valid UTF-8, which for a
    ## request body is a client error: answer with 400 rather than crashing.
    text : Request -> Try(Str, [BadUtf8({ problem : Str.Utf8Problem, index : U64 })])
    text = |request| Str.from_utf8(request.body)

    ## Decode the body as UTF-8, replacing malformed bytes with `U+FFFD`.
    ##
    ## Never fails, so it suits logging and other places where a mangled body is
    ## better than no body.
    text_lossy : Request -> Str
    text_lossy = |request| Str.from_utf8_lossy(request.body)
}
