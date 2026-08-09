app [main!] { pf: platform "../platform/main.roc" }

import pf.Stdout

## Phase 2 worker: the request URL arrives as the single argument, and whatever
## is written to stdout becomes the response body.
main! : List(Str) => Try({}, [Exit(I32), StdoutErr(Str), ..])
main! = |args| {
	url = Str.join_with(args, "")

	Stdout.line!("Hello from Roc, running on Cloudflare Workers")?
	Stdout.line!("You requested: ${url}")?

	Ok({})
}
