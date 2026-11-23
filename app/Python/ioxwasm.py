"""Runs WebAssembly (WASI) programs in the app: the `wasm` command of ioxsh.

iOS can't load code that was compiled on the device, so build-time programs (Swift macros, Rust build scripts and proc
macros, SwiftPM plugins, code generators) are compiled to wasm32-wasip1 and interpreted by WasmKit inside the app.
The interpreter is Swift; the app hands Python its address in IOX_WASM_ENTRY and it is called through ctypes.

    wasm [--dir HOST[::GUEST]]... [--env K=V]... PROGRAM.wasm [ARGS...]
"""
import ctypes, os, sys, threading

_FN = None


def available():
    return bool(os.environ.get("IOX_WASM_ENTRY"))


def _entry():
    global _FN
    if _FN is None:
        addr = os.environ.get("IOX_WASM_ENTRY")
        if not addr:
            raise RuntimeError("this build of iOXcode has no WebAssembly interpreter inside")
        proto = ctypes.CFUNCTYPE(ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.POINTER(ctypes.c_char_p),
                                 ctypes.c_int, ctypes.POINTER(ctypes.c_char_p), ctypes.c_int,
                                 ctypes.POINTER(ctypes.c_char_p), ctypes.c_int, ctypes.c_int, ctypes.c_int)
        _FN = proto(int(addr))
    return _FN


def _cstrings(items):
    arr = (ctypes.c_char_p * (len(items) + 1))(*[s.encode("utf-8") for s in items], None)
    return arr


def _pump(fd, stream):
    with os.fdopen(fd, "rb", closefd=True) as f:
        while True:
            chunk = f.read1(65536) if hasattr(f, "read1") else f.read(65536)
            if not chunk:
                break
            stream.write(chunk.decode("utf-8", "replace"))


def run(program, args=(), env=None, dirs=None, stdin_text="", out=None, err=None):
    """Runs `program` (a .wasm file) and returns its exit code. `dirs` is a list of "host::guest" or host paths."""
    out = out or sys.stdout
    err = err or sys.stderr
    fn = _entry()
    program = os.path.abspath(program)
    argv = [os.path.basename(program)] + list(args)
    environ = dict(os.environ if env is None else env)
    environ.setdefault("PWD", os.getcwd())
    envp = ["%s=%s" % kv for kv in environ.items()]
    if dirs is None:
        dirs = [os.getcwd() + "::.", os.environ.get("TMPDIR", "/tmp") + "::/tmp"]
    preopens = []
    for d in dirs:
        host, _, guest = d.partition("::")
        preopens.append("%s::%s" % (guest or host, host))   # the interpreter wants guest::host
    in_r, in_w = os.pipe()
    out_r, out_w = os.pipe()
    err_r, err_w = os.pipe()
    threads = [threading.Thread(target=_pump, args=(out_r, out), daemon=True),
               threading.Thread(target=_pump, args=(err_r, err), daemon=True)]
    for t in threads:
        t.start()
    if stdin_text:
        os.write(in_w, stdin_text.encode("utf-8"))
    os.close(in_w)
    try:
        code = fn(program.encode(), len(argv), _cstrings(argv), len(envp), _cstrings(envp),
                  len(preopens), _cstrings(preopens), in_r, out_w, err_w)
    finally:
        os.close(in_r)
        os.close(out_w)
        os.close(err_w)
        for t in threads:
            t.join()
    return code


def _hello_module():
    """A tiny WASI program (prints "hello from wasm"), assembled by hand: proves the interpreter works."""
    def u(n):
        b = bytearray()
        while True:
            x = n & 0x7F
            n >>= 7
            if n:
                b.append(x | 0x80)
            else:
                b.append(x)
                return bytes(b)

    def vec(items):
        return u(len(items)) + b"".join(items)

    def name(s):
        return u(len(s)) + s.encode()

    def section(sid, body):
        return bytes([sid]) + u(len(body)) + body

    msg = b"hello from wasm\n"
    types = vec([b"\x60" + vec([b"\x7f"] * 4) + vec([b"\x7f"]), b"\x60\x00\x00"])
    imports = vec([name("wasi_snapshot_preview1") + name("fd_write") + b"\x00" + u(0)])
    funcs = vec([u(1)])
    mem = vec([b"\x00" + u(1)])
    exports = vec([name("memory") + b"\x02" + u(0), name("_start") + b"\x00" + u(1)])
    body = (b"\x00" + b"\x41\x01" + b"\x41\x00" + b"\x41\x01" + b"\x41\xe4\x00" + b"\x10" + u(0) + b"\x1a" + b"\x0b")
    code = vec([u(len(body)) + body])
    iov = (8).to_bytes(4, "little") + len(msg).to_bytes(4, "little")
    data = vec([b"\x00\x41\x00\x0b" + u(len(iov)) + iov, b"\x00\x41\x08\x0b" + u(len(msg)) + msg])
    return (b"\x00asm\x01\x00\x00\x00" + section(1, types) + section(2, imports) + section(3, funcs) +
            section(5, mem) + section(7, exports) + section(10, code) + section(11, data))


def main(a, out, err, stdin_text=""):
    dirs, env_extra, rest = [], {}, list(a)
    while rest and rest[0].startswith("-"):
        o = rest.pop(0)
        if o == "--selftest":
            import tempfile
            p = os.path.join(tempfile.gettempdir(), "ioxwasm-selftest.wasm")
            with open(p, "wb") as f:
                f.write(_hello_module())
            code = run(p, out=out, err=err)
            err.write("wasm selftest: exit %d\n" % code)
            return 0 if code == 0 else 1
        if o in ("--dir", "--mapdir") and rest:
            dirs.append(rest.pop(0))
        elif o.startswith("--dir="):
            dirs.append(o.split("=", 1)[1])
        elif o == "--env" and rest:
            k, _, v = rest.pop(0).partition("=")
            env_extra[k] = v
        elif o == "--":
            break
        elif o in ("run", "-q", "--quiet"):
            pass
    if rest and rest[0] == "run":
        rest.pop(0)
    if not rest:
        err.write("usage: wasm [--dir HOST[::GUEST]] [--env K=V] PROGRAM.wasm [ARGS...]\n")
        return 2
    if not available():
        err.write("wasm: this build of iOXcode has no WebAssembly interpreter inside\n")
        return 127
    env = dict(os.environ)
    env.update(env_extra)
    return run(rest[0], rest[1:], env=env, dirs=(dirs or None), stdin_text=stdin_text, out=out, err=err)


def link(args):
    """Runs the in-process linker (lld). args[0] names the flavor ("wasm-ld", "ld64.lld"). Returns (code, messages)."""
    addr = os.environ.get("IOX_LINK_ENTRY")
    if not addr:
        return 1, "no in-process linker in this build of iOXcode"
    proto = ctypes.CFUNCTYPE(ctypes.c_int, ctypes.c_int, ctypes.POINTER(ctypes.c_char_p), ctypes.c_char_p, ctypes.c_int)
    fn = proto(int(addr))
    buf = ctypes.create_string_buffer(1 << 16)
    code = fn(len(args), _cstrings(list(args)), buf, len(buf))
    return code, buf.value.decode("utf-8", "replace")
