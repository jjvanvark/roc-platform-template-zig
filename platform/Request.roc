## An incoming HTTP request.
##
## Headers are not modelled yet; they are the next thing to marshal across the
## host boundary.
Request := {
    ## The HTTP method, uppercased: `"GET"`, `"POST"`, and so on.
    method : Str,
    ## The full request URL, including scheme, host, path and query string.
    url : Str,
    ## The request body, or `""` when there is none.
    body : Str,
}
