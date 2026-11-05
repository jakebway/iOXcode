"""iOXcode's in-app Python entry point.

iOS apps can't start other programs, so a build script runs inside the app's own Python.
The app calls run(<base64 JSON request>); output goes to request["out"], the exit code to
request["out"] + ".code".

Request: {"out": path, "cwd": path, "env": {...}, "args": [...], and one of
          "script": path | "module": name | "code": source | "shell": script text}
"""
import base64, json, os, runpy, sys, traceback

_BASE_MODULES = None


def _forget_project_modules(cwd):
    """Drop modules a script imported from the project, so the next project starts clean."""
    cwd = os.path.realpath(cwd)
    for name, mod in list(sys.modules.items()):
        f = getattr(mod, "__file__", None) or ""
        if f and os.path.realpath(f).startswith(cwd + os.sep):
            del sys.modules[name]


def python_main(argv, out):
    """Behaves like the `python3` command line: python3 [-u|-B|...] (script | -m mod | -c code) args...
    Returns the exit code."""
    args = list(argv)
    while args and args[0].startswith("-") and args[0] not in ("-m", "-c", "-"):
        args.pop(0)  # -u, -B, -E, -I, -O ... have no effect here
    if not args:
        print("python3: interactive mode is not available in a build script", file=out)
        return 2
    saved_argv, saved_path = list(sys.argv), list(sys.path)
    try:
        if args[0] == "-m":
            if len(args) < 2:
                print("python3: -m needs a module name", file=out)
                return 2
            mod = args[1]
            if mod in ("pip", "ensurepip", "venv"):
                print("note: %s is not needed on iPhone (Pillow and PyYAML are built in); skipping" % mod, file=out)
                return 0
            sys.argv = [mod] + args[2:]
            sys.path.insert(0, os.getcwd())
            runpy.run_module(mod, run_name="__main__", alter_sys=True)
        elif args[0] == "-":
            sys.argv = ["-"] + args[1:]
            sys.path.insert(0, "")
            exec(compile(sys.stdin.read(), "<stdin>", "exec"), {"__name__": "__main__"})
        elif args[0] == "-c":
            sys.argv = ["-c"] + args[2:]
            sys.path.insert(0, "")
            exec(compile(args[1] if len(args) > 1 else "", "<string>", "exec"), {"__name__": "__main__"})
        else:
            script = os.path.abspath(args[0])
            sys.argv = [args[0]] + args[1:]
            sys.path.insert(0, os.path.dirname(script))
            runpy.run_path(script, run_name="__main__")
        return 0
    except SystemExit as e:
        c = e.code
        if c is None:
            return 0
        if isinstance(c, int):
            return c
        print(c, file=out)
        return 1
    except BaseException:
        traceback.print_exc(file=out)
        return 1
    finally:
        sys.argv, sys.path[:] = saved_argv, saved_path


def run(b64):
    req = json.loads(base64.b64decode(b64).decode("utf-8"))
    out = open(req["out"], "w", buffering=1, encoding="utf-8", errors="replace")
    saved = (sys.stdout, sys.stderr, os.getcwd(), dict(os.environ))
    code = 1
    try:
        sys.stdout = sys.stderr = out
        os.chdir(req["cwd"])
        os.environ.update(req.get("env") or {})
        if "shell" in req:
            import ioxsh
            code = ioxsh.run_script(req["shell"], req.get("args") or [], out)
        elif "module" in req:
            code = python_main(["-m", req["module"]] + req.get("args", []), out)
        elif "code" in req:
            code = python_main(["-c", req["code"]] + req.get("args", []), out)
        else:
            code = python_main([req["script"]] + req.get("args", []), out)
    except BaseException:
        traceback.print_exc(file=out)
        code = 1
    finally:
        try:
            out.flush()
        except Exception:
            pass
        sys.stdout, sys.stderr = saved[0], saved[1]
        try:
            os.chdir(saved[2])
        except Exception:
            pass
        os.environ.clear()
        os.environ.update(saved[3])
        _forget_project_modules(req.get("cwd") or "/nonexistent")
        out.close()
        with open(req["out"] + ".code", "w") as f:
            f.write(str(code))
