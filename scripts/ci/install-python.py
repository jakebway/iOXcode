#!/usr/bin/env python3
"""Puts an embeddable Python for iOS into a built .app (what CPython's install_python does in Xcode).

usage: install-python.py <Python.xcframework> <App.app> <app_packages dir>

- Python.framework           -> App.app/Frameworks/Python.framework
- standard library           -> App.app/python/lib/python3.X
- third-party packages       -> App.app/app_packages
- every binary module (.so)  -> its own App.app/Frameworks/<dotted.name>.framework, with a .fwork
                                marker left where the .so was and a .origin file pointing back
                                (iOS only loads code from frameworks).
"""
import os, plistlib, shutil, sys

xcf, app, packages = sys.argv[1], sys.argv[2], sys.argv[3]
slice_dir = os.path.join(xcf, "ios-arm64")
fw = os.path.join(app, "Frameworks")
os.makedirs(fw, exist_ok=True)

shutil.rmtree(os.path.join(fw, "Python.framework"), ignore_errors=True)
shutil.copytree(os.path.join(slice_dir, "Python.framework"), os.path.join(fw, "Python.framework"), symlinks=True)

# standard library: either a shared lib/ plus per-slice lib-arm64/, or a full lib/ inside the slice
dst_lib = os.path.join(app, "python", "lib")
shutil.rmtree(os.path.join(app, "python"), ignore_errors=True)
ignore = shutil.ignore_patterns("libpython*.dylib", "__pycache__", "test", "tests", "idlelib", "tkinter", "turtledemo", "ensurepip")
if os.path.isdir(os.path.join(xcf, "lib")):
    shutil.copytree(os.path.join(xcf, "lib"), dst_lib, ignore=ignore)
    extra = os.path.join(slice_dir, "lib-arm64")
    if os.path.isdir(extra):
        shutil.copytree(extra, dst_lib, ignore=ignore, dirs_exist_ok=True)
else:
    shutil.copytree(os.path.join(slice_dir, "lib"), dst_lib, ignore=ignore)

shutil.rmtree(os.path.join(app, "app_packages"), ignore_errors=True)
shutil.copytree(packages, os.path.join(app, "app_packages"), ignore=shutil.ignore_patterns("__pycache__"))

ver = next(d for d in os.listdir(dst_lib) if d.startswith("python3."))
print("Python", ver)

def frameworkify(base_rel):
    """Turn every .so under App.app/<base_rel> into a framework."""
    base = os.path.join(app, base_rel)
    count = 0
    for root, _, files in os.walk(base):
        for f in files:
            if not f.endswith(".so"):
                continue
            full = os.path.join(root, f)
            rel_to_bundle = os.path.relpath(full, app)
            rel_to_base = os.path.relpath(full, base)
            dotted = rel_to_base.split(".")[0].replace("/", ".")
            folder = os.path.join(fw, dotted + ".framework")
            os.makedirs(folder, exist_ok=True)
            with open(os.path.join(folder, "Info.plist"), "wb") as p:
                plistlib.dump({
                    "CFBundleDevelopmentRegion": "en",
                    "CFBundleExecutable": dotted,
                    "CFBundleIdentifier": "com.jakebway.ioxcode." + dotted.replace("_", "-"),
                    "CFBundleInfoDictionaryVersion": "6.0",
                    "CFBundleName": dotted,
                    "CFBundlePackageType": "FMWK",
                    "CFBundleShortVersionString": "1.0",
                    "CFBundleSupportedPlatforms": ["iPhoneOS"],
                    "CFBundleVersion": "1",
                    "MinimumOSVersion": "13.0",
                }, p)
            shutil.move(full, os.path.join(folder, dotted))
            with open(full[:-3] + ".fwork", "w") as m:
                m.write("Frameworks/%s.framework/%s" % (dotted, dotted))
            with open(os.path.join(folder, dotted + ".origin"), "w") as o:
                o.write(rel_to_bundle[:-3] + ".fwork")
            count += 1
    print("frameworks made from", base_rel + ":", count)

frameworkify(os.path.join("python", "lib", ver, "lib-dynload"))
frameworkify("app_packages")
