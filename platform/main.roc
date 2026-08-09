platform ""
    requires {} { main! : Request => Response }
    exposes [Request, Response, Stdout, Stderr]
    packages {}
    provides { "roc_main": main_for_host! }
    hosted {
        "roc_stderr_line": Host.stderr_line!,
        "roc_stdout_line": Host.stdout_line!,
    }
    targets: {
        inputs_dir: "targets/",
        x64mac: { inputs: ["libhost.a", app] },
        arm64mac: { inputs: ["libhost.a", app] },
        x64musl: { inputs: ["crt1.o", "libhost.a", app, "libc.a"] },
        x64v1musl: { inputs: ["crt1.o", "libhost.a", app, "libc.a"] },
        arm64musl: { inputs: ["crt1.o", "libhost.a", app, "libc.a"] },
        arm64v1musl: { inputs: ["crt1.o", "libhost.a", app, "libc.a"] },
        x64win: { inputs: ["host.lib", app] },
        arm64win: { inputs: ["host.lib", app] },
        wasm32: { inputs: ["libhost.a", app] },
    }

import Request exposing [Request]
import Response exposing [Response]
import Stdout
import Stderr
import Host

main_for_host! : Request => Response
main_for_host! = |request| main!(request)
