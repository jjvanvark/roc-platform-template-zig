// Minimal embedder used to smoke-test the wasm32 host outside Cloudflare.
//   node dev/run.mjs dev/hello.wasm
import { readFile } from "node:fs/promises";

const path = process.argv[2] ?? "dev/hello.wasm";
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

const exitCode = instance.exports.roc_entry();
console.error(`[embedder] roc_entry returned ${exitCode}`);
