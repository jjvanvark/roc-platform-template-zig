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

    // Segments in the order the host expects: method, url, body, then each
    // header's name and value.
    const segments = [
      encoder.encode(request.method),
      encoder.encode(request.url),
      new Uint8Array(await request.arrayBuffer()),
    ];
    let headerCount = 0;
    for (const [name, value] of request.headers) {
      segments.push(encoder.encode(name), encoder.encode(value));
      headerCount += 1;
    }

    const lensPtr = w.roc_request_alloc_lens(segments.length);
    if (lensPtr === 0) {
      return new Response("Out of memory building the request\n", { status: 500 });
    }
    const lens = new Uint32Array(memory.buffer, lensPtr, segments.length);
    let total = 0;
    segments.forEach((segment, i) => {
      lens[i] = segment.length;
      total += segment.length;
    });

    const dataPtr = w.roc_request_alloc_data(total);
    if (dataPtr === 0) {
      return new Response("Out of memory building the request\n", { status: 500 });
    }
    const data = new Uint8Array(memory.buffer, dataPtr, total);
    let offset = 0;
    for (const segment of segments) {
      data.set(segment, offset);
      offset += segment.length;
    }

    if (w.roc_handle(headerCount) !== 0) {
      return new Response("Roc host rejected the request\n", { status: 500 });
    }

    // Read everything out before freeing: the bytes live in Roc-owned memory.
    const status = w.roc_response_status();
    const body = decoder.decode(
      new Uint8Array(memory.buffer, w.roc_response_body_ptr(), w.roc_response_body_len()),
    );

    const headers = new Headers();
    for (let i = 0; i < w.roc_response_header_count(); i += 1) {
      headers.append(
        decoder.decode(
          new Uint8Array(memory.buffer, w.roc_response_header_name_ptr(i), w.roc_response_header_name_len(i)),
        ),
        decoder.decode(
          new Uint8Array(memory.buffer, w.roc_response_header_value_ptr(i), w.roc_response_header_value_len(i)),
        ),
      );
    }
    if (!headers.has("content-type")) {
      headers.set("content-type", "text/plain; charset=utf-8");
    }

    w.roc_response_free();

    return new Response(body, { status, headers });
  },
};
