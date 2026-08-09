app [main!] { pf: platform "../platform/main.roc" }

import pf.D1
import pf.Request exposing [Request]
import pf.Response exposing [Response]

## Creates a table, inserts a row and reads it back.
##
## Rows come back as a JSON array string: Roc has no row type yet.
main! : Request => Response
main! = |request| {
    setup = D1.execute!("DB", "CREATE TABLE IF NOT EXISTS visits (path TEXT)", "[]")

    match setup {
        Err(D1Err(message)) => Response.text(500, [], "D1 error: ${message}\n")
        Ok(_) =>
            match D1.execute!("DB", "INSERT INTO visits (path) VALUES (?)", "[\"${request.url}\"]") {
                Err(D1Err(message)) => Response.text(500, [], "D1 error: ${message}\n")
                Ok(_) =>
                    match D1.query!("DB", "SELECT count(*) AS n FROM visits", "[]") {
                        Ok(rows) => Response.text(200, [], "${rows}\n")
                        Err(D1Err(message)) => Response.text(500, [], "D1 error: ${message}\n")
                    }
            }
    }
}
