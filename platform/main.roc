platform ""
    requires {} { main! : Request => Response }
    exposes [Request, Response, Header, Stdout, Stderr, Env, Kv, R2, D1, Pg, Queue]
    packages {}
    provides { "roc_main": main_for_host! }
    hosted {
        "roc_stderr_line": Host.stderr_line!,
        "roc_stdout_line": Host.stdout_line!,
        "roc_kv_get": Host.kv_get!,
        "roc_kv_put": Host.kv_put!,
        "roc_r2_get": Host.r2_get!,
        "roc_r2_put": Host.r2_put!,
        "roc_r2_delete": Host.r2_delete!,
        "roc_d1_query": Host.d1_query!,
        "roc_d1_execute": Host.d1_execute!,
        "roc_pg_query": Host.pg_query!,
        "roc_pg_execute": Host.pg_execute!,
        "roc_queue_send": Host.queue_send!,
        "roc_env_get": Host.env_get!,
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

import Header exposing [Header]
import Request exposing [Request]
import Response exposing [Response]
import Stdout
import Stderr
import Env
import Kv
import R2
import D1
import Pg
import Queue
import Host

main_for_host! : Request => Response
main_for_host! = |request| main!(request)
