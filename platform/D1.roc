import Host

## Query a [D1](https://developers.cloudflare.com/d1/) database.
##
## `binding` is the name declared in `wrangler.jsonc` under `d1_databases`.
##
## Roc has no row type yet, so rows come back as a JSON array string and
## parameters go in as a JSON array string. Use `"[]"` when there are none.
D1 := [].{
    ## Run a query and return the matching rows as JSON.
    ##
    ## ```roc
    ## D1.query!("DB", "SELECT name FROM users WHERE age > ?", "[21]")
    ## ```
    query! : Str, Str, Str => Try(Str, [D1Err(Str), ..])
    query! = |binding, sql, params|
        match Host.d1_query!(binding, sql, params) {
            Ok(rows) => Ok(rows)
            Err(D1Err(err)) => Err(D1Err(err))
        }

    ## Run a statement for its effect, returning the number of rows written.
    ##
    ## ```roc
    ## D1.execute!("DB", "INSERT INTO users (name) VALUES (?)", "[\"alice\"]")
    ## ```
    execute! : Str, Str, Str => Try(U64, [D1Err(Str), ..])
    execute! = |binding, sql, params|
        match Host.d1_execute!(binding, sql, params) {
            Ok(rows_written) => Ok(rows_written)
            Err(D1Err(err)) => Err(D1Err(err))
        }
}
