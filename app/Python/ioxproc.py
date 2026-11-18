"""subprocess for iPhone.

iOS apps can't start other programs, so a Python build script that calls subprocess.run(["git", ...]) or
os.system("...") would fail. While iOXcode runs a script, these functions run the command through ioxsh
instead (its built-in git, cargo, sed, ...), with the same results a Mac would give for those commands.
"""
import io, os, shlex, subprocess, sys

PIPE, STDOUT, DEVNULL = subprocess.PIPE, subprocess.STDOUT, subprocess.DEVNULL
_orig = {}


def _text(x):
    if x is None:
        return None
    if isinstance(x, (bytes, bytearray)):
        return bytes(x).decode("utf-8", "replace")
    return str(x)


def _execute(args, cwd=None, env=None, input=None, shell=False):
    """Runs one command line in ioxsh. Returns (code, stdout text, stderr text)."""
    import ioxsh
    out, err = io.StringIO(), io.StringIO()
    sh = ioxsh.Shell(out, err)
    saved_cwd, saved_env = os.getcwd(), dict(os.environ)
    try:
        if cwd:
            os.chdir(os.fspath(cwd))
        if env is not None:
            os.environ.clear()
            os.environ.update({str(k): str(v) for k, v in env.items()})
        if isinstance(args, (str, bytes, os.PathLike)):
            args = os.fspath(args)
            args = args.decode() if isinstance(args, bytes) else args
            code = sh.run_source(args) if shell else sh.call([args], _text(input))
        elif shell:
            code = sh.run_source(" ".join(shlex.quote(os.fspath(a)) for a in args))
        else:
            code = sh.call([os.fspath(a) if not isinstance(a, bytes) else a.decode() for a in args], _text(input))
    except ioxsh.ShellExit as e:
        code = e.code
    finally:
        try:
            os.chdir(saved_cwd)
        except OSError:
            pass
        if env is not None:
            os.environ.clear()
            os.environ.update(saved_env)
    return int(code or 0), out.getvalue(), err.getvalue()


def _route(text, dest, as_text, other_buf=None):
    """Where a stream goes: returned (PIPE), merged into stdout (STDOUT), dropped, or printed."""
    if dest == PIPE:
        return text if as_text else text.encode()
    if dest == DEVNULL:
        return None
    if dest is None:
        target = sys.stdout if other_buf is None else sys.stderr
        target.write(text)
        return None
    if hasattr(dest, "write"):
        try:
            dest.write(text)
        except TypeError:
            dest.write(text.encode())
    elif isinstance(dest, int) and dest >= 0:
        os.write(dest, text.encode())
    return None


def run(args, *, stdin=None, input=None, stdout=None, stderr=None, capture_output=False, shell=False, cwd=None,
        timeout=None, check=False, encoding=None, errors=None, text=None, env=None, universal_newlines=None, **kw):
    if capture_output:
        stdout = stderr = PIPE
    as_text = bool(text or universal_newlines or encoding or errors)
    if input is None and stdin is not None and hasattr(stdin, "read"):
        input = stdin.read()
    code, o, e = _execute(args, cwd, env, input, shell)
    if stderr == STDOUT:
        o, e, stderr = o + e, "", DEVNULL
    out_v = _route(o, stdout, as_text)
    err_v = _route(e, stderr, as_text, other_buf=True)
    cp = subprocess.CompletedProcess(args, code, out_v, err_v)
    if check and code != 0:
        raise subprocess.CalledProcessError(code, args, out_v, err_v)
    return cp


def call(args, **kw):
    kw.pop("check", None)
    return run(args, **kw).returncode


def check_call(args, **kw):
    kw["check"] = True
    run(args, **kw)
    return 0


def check_output(args, **kw):
    kw["stdout"] = PIPE
    kw["check"] = True
    return run(args, **kw).stdout


def getstatusoutput(cmd):
    code, o, e = _execute(cmd, shell=True)
    return code, (o + e).rstrip("\n")


def getoutput(cmd):
    return getstatusoutput(cmd)[1]


def system(cmd):
    code, o, e = _execute(cmd, shell=True)
    sys.stdout.write(o)
    sys.stderr.write(e)
    return code << 8


class Popen:
    """Runs the command when its result is first needed (communicate/wait/poll or reading stdout)."""

    def __init__(self, args, bufsize=-1, executable=None, stdin=None, stdout=None, stderr=None, shell=False, cwd=None,
                 env=None, universal_newlines=None, text=None, encoding=None, errors=None, **kw):
        self.args, self._stdin_spec, self._stdout, self._stderr = args, stdin, stdout, stderr
        self._shell, self._cwd, self._env = shell, cwd, env
        self._text = bool(text or universal_newlines or encoding or errors)
        self.returncode = None
        self.pid = 0
        self.stdin = io.StringIO() if stdin == PIPE and self._text else (io.BytesIO() if stdin == PIPE else None)
        self.stdout = None
        self.stderr = None
        self._out = self._err = None
        if stdin != PIPE:
            self._go(None)

    def _go(self, input):
        if self.returncode is not None:
            return
        if input is None and self.stdin is not None:
            input = self.stdin.getvalue()
        code, o, e = _execute(self.args, self._cwd, self._env, input, self._shell)
        if self._stderr == STDOUT:
            o, e, self._stderr = o + e, "", DEVNULL
        self._out = _route(o, self._stdout, self._text)
        self._err = _route(e, self._stderr, self._text, other_buf=True)
        if self._out is not None:
            self.stdout = io.StringIO(self._out) if self._text else io.BytesIO(self._out)
        if self._err is not None:
            self.stderr = io.StringIO(self._err) if self._text else io.BytesIO(self._err)
        self.returncode = code

    def communicate(self, input=None, timeout=None):
        self._go(input)
        return self._out, self._err

    def wait(self, timeout=None):
        self._go(None)
        return self.returncode

    def poll(self):
        return self.wait()

    def kill(self):
        pass

    terminate = kill

    def __enter__(self):
        return self

    def __exit__(self, *a):
        self.wait()


def install():
    """Swaps the real functions for these while a script runs. Returns a function that puts them back."""
    names = ["run", "call", "check_call", "check_output", "getstatusoutput", "getoutput", "Popen"]
    saved = {n: getattr(subprocess, n) for n in names}
    saved_system = os.system
    for n in names:
        setattr(subprocess, n, globals()[n])
    os.system = system

    def restore():
        for n, f in saved.items():
            setattr(subprocess, n, f)
        os.system = saved_system
    return restore
