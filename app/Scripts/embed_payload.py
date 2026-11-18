"""Puts into the iOXcode app being built what the Mac build puts there after Xcode: the compiler libraries and
macro plug-ins (Frameworks), the Rust compiler and its macros (Rust), the clang headers (ClangResource), Python and
its packages (python, app_packages), and the iOS 27.1 SDK stamp. The copy comes from the iOXcode that is running
this build, with the project's own Python scripts laid over its app_packages, so editing them in the repo and
building takes effect. Without this the result is only the app's own code (about 5 MB) and cannot build anything."""
import os, shutil, struct, sys

src = os.environ.get("IOX_APP_BUNDLE")
app = os.environ.get("CODESIGNING_FOLDER_PATH")
root = os.environ.get("SRCROOT", ".")
if not src or not os.path.isdir(src) or not app:
    print("note: not running inside iOXcode; nothing to embed")
    sys.exit(0)


def clone(s, d):
    try:
        os.link(s, d)
    except OSError:
        shutil.copy2(s, d)


def copy_tree(name):
    s, d = os.path.join(src, name), os.path.join(app, name)
    if not os.path.isdir(s):
        return 0
    n = 0
    for dirpath, dirs, files in os.walk(s):
        rel = os.path.relpath(dirpath, s)
        out = os.path.normpath(os.path.join(d, rel))
        os.makedirs(out, exist_ok=True)
        for f in files:
            t = os.path.join(out, f)
            if os.path.lexists(t):
                continue                          # something the build itself produced wins
            p = os.path.join(dirpath, f)
            if os.path.islink(p):
                os.symlink(os.readlink(p), t)
            else:
                clone(p, t)
            n += 1
    return n


for name in ("Frameworks", "Rust", "ClangResource", "python", "app_packages"):
    print("embedded %-14s %d files" % (name, copy_tree(name)))

# the project's own Python scripts replace the copies from the running app
pysrc = os.path.join(root, "Python")
dst = os.path.join(app, "app_packages")
if os.path.isdir(pysrc):
    os.makedirs(dst, exist_ok=True)
    n = 0
    for f in os.listdir(pysrc):
        if f.endswith(".py"):
            shutil.copy2(os.path.join(pysrc, f), os.path.join(dst, f))
            n += 1
    print("python scripts from the project: %d" % n)

# iOS 27 lays out apps linked against an older SDK with a blank strip: stamp SDK 27.1 like the Mac build does
exe = os.path.join(app, os.environ.get("EXECUTABLE_NAME", "iOXcode"))
try:
    with open(exe, "r+b") as f:
        head = f.read(32)
        magic, _ct, _cs, _ft, ncmds, _sz = struct.unpack("<IiiIII", head[:24])
        if magic == 0xFEEDFACF:
            off = 32
            for _ in range(ncmds):
                f.seek(off)
                cmd, size = struct.unpack("<II", f.read(8))
                if cmd == 0x32:                   # LC_BUILD_VERSION: platform, minos, sdk, ntools
                    f.seek(off + 16)
                    f.write(struct.pack("<I", (27 << 16) | (1 << 8)))
                    print("stamped SDK 27.1")
                    break
                off += size
except OSError as e:
    print("warning: could not stamp the SDK version: %s" % e)
