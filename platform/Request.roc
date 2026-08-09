import Header exposing [Header]

## An incoming HTTP request.
Request := {
    ## The HTTP method, uppercased: `"GET"`, `"POST"`, and so on.
    method : Str,
    ## The full request URL, including scheme, host, path and query string.
    url : Str,
    ## The request headers, with lowercased names.
    headers : List(Header),
    ## The request body, or `""` when there is none.
    body : Str,
}
