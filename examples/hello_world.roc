app [main!] { pf: platform "../platform/main.roc" }

import pf.Request exposing [Request]
import pf.Response exposing [Response]

main! : Request => Response
main! = |_request| Response.text(200, [], "Hello, World!\n")
