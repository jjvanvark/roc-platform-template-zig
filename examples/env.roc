app [main!] { pf: platform "../platform/main.roc" }

import pf.Env
import pf.Request exposing [Request]
import pf.Response exposing [Response]

## Reads text bindings: `vars` from wrangler config, and secrets.
##
## Natively these come from the process environment, so this example runs
## either way.
main! : Request => Response
main! = |_request| {
    greeting = Env.get_or!("GREETING", "(no GREETING set)")

    missing =
        match Env.get!("DEFINITELY_NOT_SET") {
            Ok(value) => value
            Err(EnvNotFound) => "(absent, as expected)"
            Err(EnvErr(message)) => "error: ${message}"
        }

    { status: 200, headers: [], body: "GREETING: ${greeting}\nDEFINITELY_NOT_SET: ${missing}\n" }
}
