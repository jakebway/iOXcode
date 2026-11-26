"""Swift for WebAssembly (wasm32-wasip1), built on the device.

The compiler inside the app has the WebAssembly backend and wasm-ld; swift.org's official Swift 6.4.0 wasm SDK (the same
release as that compiler) provides the standard library, the C library and the swiftmodules. This module turns a list of
Swift files into a .wasm program the same way `swift build --swift-sdk wasm32-unknown-wasip1` does, and the `wasm`
command runs the result in the in-app interpreter. Swift macros and SwiftPM plugins run as such wasm programs.

`frontend` and `link` are callables taking an argument list and returning (exit code, messages); the app passes the
in-process compiler (ioxwasm.frontend / ioxwasm.link), CI passes the real tools to check the same recipe.
"""
import os
import re
import shutil
import tarfile

TRIPLE = "wasm32-unknown-wasip1"


def sdk_root(log=lambda s: None):
    """Directory holding WASI.sdk and usr/lib/swift_static (unpacked once from the archive inside the app)."""
    direct = os.environ.get("IOX_SWIFT_WASM_SDK")
    if direct and os.path.isdir(os.path.join(direct, "WASI.sdk")):
        return direct
    archive = os.environ.get("IOX_SWIFT_WASM_ARCHIVE") or ""
    if not os.path.isfile(archive):
        return ""
    base = os.environ.get("IOX_CACHES") or os.path.join(os.path.expanduser("~"), "Library", "Caches", "iOXcode")
    dest = os.path.join(base, "swiftwasm")
    stamp = os.path.join(dest, ".from")
    sig = "%s %d" % (archive, os.path.getsize(archive))
    root = os.path.join(dest, "swift-wasm-sdk")
    if not (os.path.isfile(stamp) and open(stamp).read() == sig and os.path.isdir(root)):
        log("    Unpacking the Swift WebAssembly SDK (first use)")
        shutil.rmtree(dest, ignore_errors=True)
        os.makedirs(dest)
        with tarfile.open(archive, "r:gz") as t:
            t.extractall(dest, filter="data") if hasattr(tarfile, "data_filter") else t.extractall(dest)
        with open(stamp, "w") as f:
            f.write(sig)
    return root


def _leb(data, pos):
    n = shift = 0
    while True:
        b = data[pos]; pos += 1
        n |= (b & 0x7F) << shift
        shift += 7
        if not b & 0x80:
            return n, pos


def autolink_entries(obj_path):
    """The libraries a Swift object asks the linker for (what swift-autolink-extract prints)."""
    data = open(obj_path, "rb").read()
    out = []
    pos = 8
    while pos < len(data):
        sid = data[pos]; pos += 1
        size, pos = _leb(data, pos)
        end = pos + size
        if sid == 0:
            nlen, p = _leb(data, pos)
            name = data[p:p + nlen].decode("utf-8", "replace")
            if name == ".swift1_autolink_entries":
                body = data[p + nlen:end].decode("utf-8", "replace")
                out += [w for w in re.split(r"[\0\s]+", body) if w]
        pos = end
    return out


def _static_args(sdk):
    """static-executable-args.lnk, mapped to wasm-ld words (the swift driver hands these to clang)."""
    words = []
    path = os.path.join(sdk, "usr", "lib", "swift_static", "wasi", "static-executable-args.lnk")
    try:
        lines = open(path).read().split("\n")
    except OSError:
        lines = ["-lswiftSwiftOnoneSupport", "-ldl", "-lstdc++", "-lm", "-lwasi-emulated-mman", "-lwasi-emulated-signal",
                 "-lwasi-emulated-process-clocks"]
    for ln in lines:
        ln = ln.strip()
        if not ln or ln == "-static":
            continue
        if ln.startswith("-Xlinker "):
            words.append(ln[len("-Xlinker "):])
        elif ln == "-lstdc++":
            words += ["-lc++", "-lc++abi"]
        else:
            words.append(ln)
    return words


def frontend_args(sources, obj, name, sdk, cache, opt="none", swift_version="5", parse_as_library=None, extra=()):
    static = os.path.join(sdk, "usr", "lib", "swift_static")
    if parse_as_library is None:
        parse_as_library = not any(os.path.basename(s) == "main.swift" for s in sources)
    a = ["-c"] + list(sources)
    a += ["-target", TRIPLE, "-sdk", os.path.join(sdk, "WASI.sdk"), "-resource-dir", static,
          "-module-name", name, "-swift-version", swift_version, "-module-cache-path", cache,
          "-no-color-diagnostics", "-o", obj]
    if parse_as_library:
        a.append("-parse-as-library")
    a += {"speed": ["-O"], "size": ["-Osize"]}.get(opt, ["-Onone"])
    return a + list(extra)


def link_args(obj, out, sdk, stack_size=8 * 1024 * 1024):
    static = os.path.join(sdk, "usr", "lib", "swift_static")
    wasi = os.path.join(sdk, "WASI.sdk", "lib", "wasm32-wasip1")
    libs = []
    for e in autolink_entries(obj):
        if e.startswith("-l") and e not in libs:
            libs.append(e)
    for e in ("-lswiftCore",):
        if e not in libs:
            libs.append(e)
    builtins = os.path.join(static, "clang", "lib", "wasip1", "libclang_rt.builtins-wasm32.a")
    args = ["wasm-ld", "--error-limit=0", "--threads=1", "-z", "stack-size=%d" % stack_size,
            "-o", out,
            os.path.join(wasi, "crt1-command.o"), os.path.join(static, "wasi", "wasm32", "swiftrt.o"), obj,
            "-L" + os.path.join(static, "wasi"), "-L" + wasi,
            ] + libs + _static_args(sdk) + ["-lc", builtins]
    return args


def compile(sources, out, name, frontend, link, log=lambda s: None, opt="none", swift_version="5", extra=(), work=None):
    """Swift sources -> out (a wasm32-wasip1 command). Returns (exit code, messages)."""
    sdk = sdk_root(log)
    if not sdk:
        return 1, "the Swift WebAssembly SDK is not in this build of iOXcode"
    work = work or os.path.join(os.path.dirname(os.path.abspath(out)), ".iox-swiftwasm-" + name)
    os.makedirs(work, exist_ok=True)
    cache = os.path.join(work, "modulecache")
    obj = os.path.join(work, name + ".o")
    code, msg = frontend(frontend_args(sources, obj, name, sdk, cache, opt, swift_version, extra=extra))
    if code != 0:
        return code, msg
    code2, msg2 = link(link_args(obj, out, sdk))
    return code2, (msg + "\n" + msg2).strip()


def swiftc_wasm(sh, a, i):
    """swiftc-wasm [-O|-Osize|-Onone] [-module-name N] [-swift-version V] -o OUT.wasm FILE.swift..."""
    import ioxwasm
    out = "a.wasm"; name = None; opt = "none"; ver = "5"; srcs = []; extra = []
    k = 0
    while k < len(a):
        x = a[k]
        if x == "-o" and k + 1 < len(a):
            out = a[k + 1]; k += 2; continue
        if x == "-module-name" and k + 1 < len(a):
            name = a[k + 1]; k += 2; continue
        if x == "-swift-version" and k + 1 < len(a):
            ver = a[k + 1]; k += 2; continue
        if x == "-O":
            opt = "speed"
        elif x == "-Osize":
            opt = "size"
        elif x in ("-Onone", "-g", "-wmo", "-whole-module-optimization", "-static-stdlib"):
            pass
        elif x.endswith(".swift"):
            srcs.append(os.path.abspath(x))
        elif x.startswith("-"):
            extra.append(x)
        k += 1
    if not srcs:
        sh.err.write("swiftc-wasm: no input files\n"); return 1
    if not name:
        name = re.sub(r"\W", "_", os.path.splitext(os.path.basename(out))[0]) or "main"
    outp = os.path.abspath(out)
    code, msg = compile(srcs, outp, name, ioxwasm.frontend, ioxwasm.link, opt=opt, swift_version=ver, extra=extra)
    if msg:
        sh.err.write(msg + "\n")
    return code
