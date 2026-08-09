// Minimal embedder used to smoke-test the wasm32 host outside Cloudflare.
//   node dev/run.mjs worker/roc.wasm https://example.com/path GET '' accept:application/json
import { readFile } from "node:fs/promises";

const path = process.argv[2] ?? "worker/roc.wasm";
const url = process.argv[3] ?? "http://localhost/";
const method = process.argv[4] ?? "GET";
const bodyText = process.argv[5] ?? "";
const headerArgs = process.argv.slice(6);

const encoder = new TextEncoder();
const decoder = new TextDecoder();

let memory;
const { instance } = await WebAssembly.instantiate(await readFile(path), {
  env: {
    host_log(stream, ptr, len) {
      const text = decoder.decode(new Uint8Array(memory.buffer, ptr, len));
      (stream === 2 ? process.stderr : process.stdout).write(text + "\n");
    },
  },
});

const w = instance.exports;
memory = w.memory;
console.error(`[embedder] memory: ${memory.buffer.byteLength / 65536} pages`);

const segments = [encoder.encode(method), encoder.encode(url), encoder.encode(bodyText)];
for (const arg of headerArgs) {
  const split = arg.indexOf(":");
  const name = split === -1 ? arg : arg.slice(0, split);
  const value = split === -1 ? "" : arg.slice(split + 1);
  segments.push(encoder.encode(name), encoder.encode(value));
}
const headerCount = headerArgs.length;

const lensPtr = w.roc_request_alloc_lens(segments.length);
if (lensPtr === 0) throw new Error("roc_request_alloc_lens failed");
const lens = new Uint32Array(memory.buffer, lensPtr, segments.length);
let total = 0;
segments.forEach((segment, i) => {
  lens[i] = segment.length;
  total += segment.length;
});

const dataPtr = w.roc_request_alloc_data(total);
if (dataPtr === 0) throw new Error("roc_request_alloc_data failed");
const data = new Uint8Array(memory.buffer, dataPtr, total);
let offset = 0;
for (const segment of segments) {
  data.set(segment, offset);
  offset += segment.length;
}

if (w.roc_handle(headerCount) !== 0) throw new Error("roc_handle rejected the request");

console.error(`[embedder] status: ${w.roc_response_status()}`);
for (let i = 0; i < w.roc_response_header_count(); i += 1) {
  const name = decoder.decode(
    new Uint8Array(memory.buffer, w.roc_response_header_name_ptr(i), w.roc_response_header_name_len(i)),
  );
  const value = decoder.decode(
    new Uint8Array(memory.buffer, w.roc_response_header_value_ptr(i), w.roc_response_header_value_len(i)),
  );
  console.error(`[embedder] header: ${name}: ${value}`);
}
const body = decoder.decode(
  new Uint8Array(memory.buffer, w.roc_response_body_ptr(), w.roc_response_body_len()),
);
w.roc_response_free();
process.stdout.write(body);
