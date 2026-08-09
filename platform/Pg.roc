import Host

## Query a PostgreSQL database through a
## [Hyperdrive](https://developers.cloudflare.com/hyperdrive/) binding.
##
## `binding` is the name declared in `wrangler.jsonc` under `hyperdrive`. For
## local development, point the binding's `localConnectionString` at a local
## Postgres server.
##
## Roc has no row type yet, so rows come back as a JSON array string and
## parameters go in as a JSON array string. Use `"[]"` when there are none.
## Parameters bind positionally to `$1`, `$2`, ... in the SQL; send them as
## JSON strings and cast in the query (`$1::uuid`, `$2::int`) when another
## type is needed.
Pg := [].{
    ## Run a query and return the matching rows as JSON.
    ##
    ## ```roc
    ## Pg.query!("PG", "SELECT name FROM users WHERE age > $1::int", "[\"21\"]")
    ## ```
    query! : Str, Str, Str => Try(Str, [PgErr(Str), ..])
    query! = |binding, sql, params|
        match Host.pg_query!(binding, sql, params) {
            Ok(rows) => Ok(rows)
            Err(PgErr(err)) => Err(PgErr(err))
        }

    ## Run a statement for its effect, returning the number of rows written.
    ##
    ## ```roc
    ## Pg.execute!("PG", "INSERT INTO users (name) VALUES ($1)", "[\"alice\"]")
    ## ```
    execute! : Str, Str, Str => Try(U64, [PgErr(Str), ..])
    execute! = |binding, sql, params|
        match Host.pg_execute!(binding, sql, params) {
            Ok(rows_written) => Ok(rows_written)
            Err(PgErr(err)) => Err(PgErr(err))
        }
}
