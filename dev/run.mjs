// Minimal embedder used to smoke-test the wasm32 host outside Cloudflare.
//   node dev/run.mjs worker/roc.wasm https://example.com/some/path GET ""
import { readFile } from "node:fs/promises";

const path = process.argv[2] ?? "worker/roc.wasm";
const url = process.argv[3] ?? "http://localhost/";
const method = process.argv[4] ?? "GET";
const bodyText = process.argv[5] ?? "";

const encoder = new TextEncoder();
const decoder = new TextDecoder();

let memory;
const { instance } = await WebAssembly.instantiate(await readFile(path), {
  env: {
    host_log(stream, ptr, len) {
      const text = decoder.decode(new Uint8Array(memory.buffer, ptr, len));
      const stream_ = stream === 2 ? process.stderr : process.stdout;
      stream_.write(text + "\n");
    },
  },
});

const w = instance.exports;
memory = w.memory;
console.error(`[embedder] memory: ${memory.buffer.byteLength / 65536} pages`);

const methodBytes = encoder.encode(method);
const urlBytes = encoder.encode(url);
const bodyBytes = encoder.encode(bodyText);
const total = methodBytes.length + urlBytes.length + bodyBytes.length;

const ptr = w.roc_request_alloc(total);
if (ptr === 0) throw new Error("roc_request_alloc failed");

const buf = new Uint8Array(memory.buffer, ptr, total);
buf.set(methodBytes, 0);
buf.set(urlBytes, methodBytes.length);
buf.set(bodyBytes, methodBytes.length + urlBytes.length);

if (w.roc_handle(methodBytes.length, urlBytes.length, bodyBytes.length) !== 0) {
  throw new Error("roc_handle rejected the request");
}

const status = w.roc_response_status();
const body = decoder.decode(
  new Uint8Array(memory.buffer, w.roc_response_body_ptr(), w.roc_response_body_len()),
);
w.roc_response_free();

console.error(`[embedder] status: ${status}`);
process.stdout.write(body);
