// Cloudflare Worker entrypoint.
//
// Phase 3 glue, still written by hand: instantiate the Roc-built wasm module,
// marshal the Request into it, and turn the Roc Response back into a real
// Response. This gets replaced by workers-zig's own glue.
import wasmModule from "./roc.wasm";

const encoder = new TextEncoder();
const decoder = new TextDecoder();

export default {
  async fetch(request) {
    // A fresh instance per request: Roc's allocator state lives in the wasm
    // instance's linear memory, so reusing one across requests would leak and
    // let requests observe each other's data.
    let memory;

    const instance = await WebAssembly.instantiate(wasmModule, {
      env: {
        host_log(stream, ptr, len) {
          const text = decoder.decode(new Uint8Array(memory.buffer, ptr, len));
          if (stream === 2) console.error(text);
          else console.log(text);
        },
      },
    });

    const w = instance.exports;
    memory = w.memory;

    const method = encoder.encode(request.method);
    const url = encoder.encode(request.url);
    const body = new Uint8Array(await request.arrayBuffer());

    const total = method.length + url.length + body.length;
    const ptr = w.roc_request_alloc(total);
    if (ptr === 0) {
      return new Response("Out of memory building the request\n", { status: 500 });
    }

    // The pointer is only valid until the next allocation, and roc_request_alloc
    // is the last one before roc_handle, so this view is safe to fill in place.
    const buf = new Uint8Array(memory.buffer, ptr, total);
    buf.set(method, 0);
    buf.set(url, method.length);
    buf.set(body, method.length + url.length);

    if (w.roc_handle(method.length, url.length, body.length) !== 0) {
      return new Response("Roc host rejected the request\n", { status: 500 });
    }

    const status = w.roc_response_status();
    const bodyPtr = w.roc_response_body_ptr();
    const bodyLen = w.roc_response_body_len();
    // Decode before freeing: the bytes live in Roc-owned memory.
    const responseBody = decoder.decode(new Uint8Array(memory.buffer, bodyPtr, bodyLen));
    w.roc_response_free();

    return new Response(responseBody, {
      status,
      headers: { "content-type": "text/plain; charset=utf-8" },
    });
  },
};
