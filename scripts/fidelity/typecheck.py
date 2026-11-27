#!/usr/bin/env python3
"""Fidelity harness: what would iOXcode's package pipeline hit, checked against the real Xcode toolchain.

Runs iOXcode's own SwiftPM reader and macro emulation (app/Python) over a project's packages, then compiles every
module in build order with Apple's swiftc and the real SDK. Reports, per module:
  - whether the sources iOXcode would hand its compiler (after emulation) compile, and the first errors if not
  - SDK macros still used in them that iOXcode does not emulate (those fail on the phone: no macro plugins there)
usage: typecheck.py <project dir> <out dir> [package dir ...]     (env: SDKROOT-less; uses xcrun)
"""
import glob, json, os, re, subprocess, sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "..", "app", "Python"))
import ioxspm, ioxmacro   # noqa: E402


# macros iOXcode runs itself: the Observation and Swift plugins are bundled in its compiler; @State goes through an alias
HANDLED = {"function", "file", "line", "error", "warning", "column", "filePath", "fileID", "dsohandle", "State", "Observable", "ObservationIgnored", "ObservationTracked", "DebugDescription", "bundle", "Preview", "Previewable"}


def sh(cmd, **kw):
    return subprocess.run(cmd, capture_output=True, text=True, **kw)


def sdk_macro_names(sdk):
    names = set()
    out = sh(["grep", "-rhoE", "--include=*.swiftinterface", r"public macro [A-Za-z][A-Za-z0-9_]*", sdk + "/System/Library/Frameworks", sdk + "/usr/lib/swift"]).stdout
    for line in out.splitlines():
        names.add(line.split()[-1])
    return names


def main():
    project, out = os.path.abspath(sys.argv[1]), os.path.abspath(sys.argv[2])
    pkgs = sys.argv[3:] or sorted(os.path.dirname(p) for p in glob.glob(project + "/Packages/*/Package.swift"))
    os.makedirs(out, exist_ok=True)
    work = os.path.join(out, "work")
    products = []
    for p in pkgs:
        man = ioxspm.load_manifest(os.path.abspath(p))
        for prod in (man or {}).get("products", []):
            if prod["kind"] == "library":
                products.append({"name": prod["name"], "package": man["name"]})
    print("packages: %d, library products: %d" % (len(pkgs), len(products)))
    req = {"work": work, "root": project, "products": products,
           "packages": [{"url": os.path.abspath(p), "req": {"kind": "branch", "value": "HEAD"}} for p in pkgs]}
    with open(os.path.join(out, "request.json"), "w") as f:
        json.dump(req, f)
    res = ioxspm.resolve(os.path.join(out, "request.json"))
    for n in res.get("notes", []):
        if "expanded emulated" not in n and not n.startswith("package ") and "pinned by" not in n:
            print("note:", n)
    sdk = sh(["xcrun", "--sdk", "iphoneos", "--show-sdk-path"]).stdout.strip()
    macros = sdk_macro_names(sdk)
    print("SDK macros: %d (%s...)" % (len(macros), ", ".join(sorted(macros)[:12])))
    mods_dir = os.path.join(out, "modules")
    os.makedirs(mods_dir, exist_ok=True)
    cargs = []
    failed, unemulated = {}, {}
    ok = 0
    for m in res["modules"]:
        name = m["name"]
        name = re.sub(r"[^A-Za-z0-9_]", "_", name)
        files = m["files"]
        # macros that survived emulation
        left = {}
        for f in files:
            try:
                src = open(f, encoding="utf-8", errors="replace").read()
            except OSError:
                continue
            clean = ioxmacro._blank_literals(src)
            for mm in re.finditer(r"(?<![A-Za-z0-9_.])([@#])([A-Za-z][A-Za-z0-9_]*)", clean):
                if mm.group(2) in macros and mm.group(2) not in HANDLED:
                    left.setdefault(mm.group(1) + mm.group(2), set()).add(os.path.basename(f))
        if left:
            unemulated[name] = left
        if m.get("cfiles"):
            inc = m.get("includeDir") or ""
            mm_path = os.path.join(inc, "module.modulemap")
            if not os.path.isfile(mm_path):
                d = os.path.join(out, "modmaps", name)
                os.makedirs(d, exist_ok=True)
                mm_path = os.path.join(d, "module.modulemap")
                open(mm_path, "w").write('module %s {\n  umbrella "%s"\n  export *\n  module * { export * }\n}\n' % (name, inc))
            cargs += ["-Xcc", "-fmodule-map-file=" + mm_path, "-Xcc", "-I", "-Xcc", inc]
        if not files:
            continue
        cmd = ["xcrun", "--sdk", "iphoneos", "swiftc", "-emit-module", "-emit-module-path", os.path.join(mods_dir, name + ".swiftmodule"),
               "-module-name", name, "-parse-as-library", "-target", "arm64-apple-ios18.0", "-swift-version", str(m.get("swiftMode", 5)), "-Onone",
               "-I", mods_dir, "-module-cache-path", os.path.join(out, "mcache"), "-suppress-warnings"] + cargs
        for d in m.get("defines", []):
            cmd += ["-D", d]
        for f in m.get("features", []):
            cmd += f
        if m.get("isolation") == "MainActor":
            cmd += ["-default-isolation", "MainActor"]
        cmd += files
        r = sh(cmd, timeout=1200)
        if r.returncode == 0:
            ok += 1
            print("ok      %s (%d files)" % (name, len(files)))
        else:
            errs = [l for l in (r.stdout + r.stderr).splitlines() if ": error:" in l]
            failed[name] = errs
            print("FAILED  %s (%d files): %d errors" % (name, len(files), len(errs)))
    print("\n== %d modules compile, %d fail" % (ok, len(failed)))
    for name, errs in failed.items():
        print("\n-- %s" % name)
        seen = set()
        for e in errs:
            key = re.sub(r"^.*?/(expanded|Sources|Packages)/", "", e)
            if key in seen:
                continue
            seen.add(key)
            print("   " + key[:300])
            if len(seen) >= 12:
                break
    if unemulated:
        print("\n== SDK macros iOXcode does not emulate (the phone has no macro plugins):")
        for name, left in unemulated.items():
            print("-- %s: %s" % (name, "; ".join("%s in %s" % (k, ", ".join(sorted(v)[:3])) for k, v in sorted(left.items()))))
    sys.exit(1 if failed else 0)


main()
