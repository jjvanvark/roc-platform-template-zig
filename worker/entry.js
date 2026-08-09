// Cloudflare Worker entrypoint.
//
// Phase 2 glue, written by hand on purpose: instantiate the Roc-built wasm
// module, hand it the request URL, and turn whatever the app logs into the
// response body. This gets replaced once real Request/Response marshalling
// lands.
import wasmModule from "./roc.wasm";

const encoder = new TextEncoder();
const decoder = new TextDecoder();

export default {
  async fetch(request) {
    // A fresh instance per request: Roc's allocator state lives in the wasm
    // instance's linear memory, so reusing one across requests would leak and
    // let requests observe each other's data.
    const lines = [];
    let memory;

    const instance = await WebAssembly.instantiate(wasmModule, {
      env: {
        host_log(stream, ptr, len) {
          const text = decoder.decode(new Uint8Array(memory.buffer, ptr, len));
          if (stream === 2) console.error(text);
          else lines.push(text);
        },
      },
    });

    const exports = instance.exports;
    memory = exports.memory;

    const url = encoder.encode(request.url);
    const capacity = exports.roc_url_buffer_len();
    if (url.length > capacity) {
      return new Response("Request URL too long\n", { status: 414 });
    }
    new Uint8Array(memory.buffer, exports.roc_url_buffer(), capacity).set(url);

    const exitCode = exports.roc_entry(url.length);
    if (exitCode !== 0) {
      return new Response(`Roc app exited with code ${exitCode}\n`, { status: 500 });
    }

    return new Response(lines.join("\n") + "\n", {
      headers: { "content-type": "text/plain; charset=utf-8" },
    });
  },
};
