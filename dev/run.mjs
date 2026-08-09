// Minimal embedder used to smoke-test the wasm32 host outside Cloudflare.
//   node dev/run.mjs worker/roc.wasm https://example.com/some/path
import { readFile } from "node:fs/promises";

const path = process.argv[2] ?? "dev/hello.wasm";
const url = process.argv[3] ?? "http://localhost/";
const bytes = await readFile(path);

let memory;
const decoder = new TextDecoder();

const { instance } = await WebAssembly.instantiate(bytes, {
  env: {
    host_log(stream, ptr, len) {
      const text = decoder.decode(new Uint8Array(memory.buffer, ptr, len));
      if (stream === 2) process.stderr.write(text + "\n");
      else process.stdout.write(text + "\n");
    },
  },
});

memory = instance.exports.memory;
const pages = memory.buffer.byteLength / 65536;
console.error(`[embedder] memory: ${pages} pages (${memory.buffer.byteLength} bytes)`);

const urlBytes = new TextEncoder().encode(url);
const capacity = instance.exports.roc_url_buffer_len();
if (urlBytes.length > capacity) throw new Error("URL too long for host buffer");
new Uint8Array(memory.buffer, instance.exports.roc_url_buffer(), capacity).set(urlBytes);

const exitCode = instance.exports.roc_entry(urlBytes.length);
console.error(`[embedder] roc_entry returned ${exitCode}`);
