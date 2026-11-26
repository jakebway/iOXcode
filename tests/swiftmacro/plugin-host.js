// Runs a swift-syntax wasm macro plugin the way the compiler's plugin hosts do: _start registers the handler, then
// swift_wasm_macro_v1_pump is called whenever the compiler wrote something to stdin. (The app does the same with WasmKit.)
const { WASI } = require('wasi');
const fs = require('fs');
const wasmPath = process.argv[2];
const w = new WASI({ version: 'preview1', args: [wasmPath], env: {}, returnOnExit: true, stdin: 0, stdout: 1, stderr: 2 });
const imports = w.getImportObject();
const ns = imports.wasi_snapshot_preview1;
const origRead = ns.fd_read;
let pending = Buffer.alloc(0);
let memory = null;
ns.fd_read = (fd, iovs, iovsLen, nreadPtr) => {
  if (fd !== 0 || pending.length === 0) return origRead(fd, iovs, iovsLen, nreadPtr);
  const view = new DataView(memory.buffer);
  let total = 0;
  for (let i = 0; i < iovsLen && pending.length > 0; i++) {
    const ptr = view.getUint32(iovs + i * 8, true), len = view.getUint32(iovs + i * 8 + 4, true);
    const n = Math.min(len, pending.length);
    Buffer.from(memory.buffer, ptr, n).set(pending.subarray(0, n));
    pending = pending.subarray(n); total += n;
  }
  view.setUint32(nreadPtr, total, true);
  return 0;
};
WebAssembly.instantiate(fs.readFileSync(wasmPath), imports).then(({ instance }) => {
  memory = instance.exports.memory;
  const code = w.start(instance);
  const pump = instance.exports.swift_wasm_macro_v1_pump;
  if (!pump) { process.stderr.write('plugin has no swift_wasm_macro_v1_pump export\n'); process.exit(2); }
  const buf = Buffer.alloc(1 << 20);
  for (;;) {
    let n = 0;
    try { n = fs.readSync(0, buf, 0, buf.length, null); } catch (e) { if (e.code === 'EAGAIN') continue; if (e.code === 'EOF') break; throw e; }
    if (n === 0) break;
    pending = Buffer.from(buf.subarray(0, n));
    pump();
  }
  process.exit(0);
});
