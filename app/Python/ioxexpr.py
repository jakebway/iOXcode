"""GitHub Actions expressions: ${{ ... }} and `if:` conditions, evaluated the way a runner does.

Operators (! == != < <= > >= && ||), the contexts (github, env, vars, secrets, inputs, matrix, runner, steps, job,
needs) and the functions contains, startsWith, endsWith, format, join, toJSON, fromJSON, hashFiles, success, failure,
always, cancelled. A reference to a context that is only known while the job runs (steps, job, needs) raises
Unresolved when no value was given, so the caller can keep the text and try again later."""
import glob, hashlib, json, os, re


class Unresolved(Exception):
    pass


class ExprError(Exception):
    pass


_TOKEN = re.compile(r"""\s*(?:
    (?P<str>'(?:[^']|'')*')|
    (?P<num>-?\d+(?:\.\d+)?(?:[eE][-+]?\d+)?|0x[0-9a-fA-F]+)|
    (?P<op>&&|\|\||==|!=|<=|>=|<|>|!|\(|\)|,)|
    (?P<id>[A-Za-z_][\w-]*(?:\.[A-Za-z_*][\w-]*|\.\*|\[[^\]]*\])*)
)""", re.X)


def _tokens(src):
    out, pos = [], 0
    src = src.strip()
    while pos < len(src):
        m = _TOKEN.match(src, pos)
        if not m or m.end() == pos:
            raise ExprError("cannot read %r" % src[pos:pos + 12])
        pos = m.end()
        kind = m.lastgroup
        out.append((kind, m.group(kind)))
    return out


def _num(v):
    if v is None or v == "":
        return 0.0
    if isinstance(v, bool):
        return 1.0 if v else 0.0
    if isinstance(v, (int, float)):
        return float(v)
    try:
        return float(int(v, 16)) if str(v).lower().startswith("0x") else float(v)
    except (TypeError, ValueError):
        return float("nan")


def truthy(v):
    return not (v is None or v is False or v == 0 or v == "" or (isinstance(v, float) and v != v))


def _loose_eq(a, b):
    if isinstance(a, str) and isinstance(b, str):
        return a.lower() == b.lower()
    if type(a) is type(b) and not isinstance(a, (dict, list)):
        return a == b
    if isinstance(a, (dict, list)) or isinstance(b, (dict, list)):
        return a is b
    return _num(a) == _num(b)


def _str(v):
    if v is None:
        return ""
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, float) and v == int(v):
        return str(int(v))
    if isinstance(v, (dict, list)):
        return json.dumps(v)
    return str(v)


class _Parser:
    def __init__(self, src, ctx):
        self.t, self.k, self.ctx = _tokens(src), 0, ctx

    def peek(self):
        return self.t[self.k] if self.k < len(self.t) else (None, None)

    def take(self):
        tok = self.peek()
        self.k += 1
        return tok

    def parse(self):
        v = self.or_()
        if self.k != len(self.t):
            raise ExprError("unexpected %r" % (self.peek()[1],))
        return v

    def or_(self):
        v = self.and_()
        while self.peek() == ("op", "||"):
            self.take()
            r = self.and_()
            v = v if truthy(v) else r
        return v

    def and_(self):
        v = self.eq()
        while self.peek() == ("op", "&&"):
            self.take()
            r = self.eq()
            v = r if truthy(v) else v
        return v

    def eq(self):
        v = self.rel()
        while self.peek()[1] in ("==", "!=") and self.peek()[0] == "op":
            op = self.take()[1]
            r = self.rel()
            v = _loose_eq(v, r) if op == "==" else not _loose_eq(v, r)
        return v

    def rel(self):
        v = self.un()
        while self.peek()[0] == "op" and self.peek()[1] in ("<", "<=", ">", ">="):
            op = self.take()[1]
            r = self.un()
            a, b = (v.lower(), r.lower()) if isinstance(v, str) and isinstance(r, str) else (_num(v), _num(r))
            v = a < b if op == "<" else a <= b if op == "<=" else a > b if op == ">" else a >= b
        return v

    def un(self):
        if self.peek() == ("op", "!"):
            self.take()
            return not truthy(self.un())
        return self.primary()

    def primary(self):
        kind, val = self.take()
        if kind == "str":
            return val[1:-1].replace("''", "'")
        if kind == "num":
            return float(int(val, 16)) if val.lower().startswith("0x") else float(val)
        if kind == "op" and val == "(":
            v = self.or_()
            if self.take() != ("op", ")"):
                raise ExprError("missing )")
            return v
        if kind == "id":
            low = val.lower()
            if low in ("true", "false"):
                return low == "true"
            if low == "null":
                return None
            if self.peek() == ("op", "("):
                self.take()
                args = []
                if self.peek() != ("op", ")"):
                    args.append(self.or_())
                    while self.peek() == ("op", ","):
                        self.take()
                        args.append(self.or_())
                if self.take() != ("op", ")"):
                    raise ExprError("missing )")
                return self.call(val, args)
            return self.lookup(val)
        raise ExprError("unexpected %r" % (val,))

    def lookup(self, ref):
        parts = [p for p in re.split(r"\.|\[|\]", ref) if p != ""]
        root = parts[0].lower()
        if root not in self.ctx:
            if root in ("steps", "job", "needs", "jobs", "strategy"):
                raise Unresolved(ref)
            return None
        cur = self.ctx[root]
        for p in parts[1:]:
            p = p.strip("'\"")
            if isinstance(cur, dict):
                nxt = None
                for k, v in cur.items():
                    if str(k).lower() == p.lower():
                        nxt = v
                        break
                cur = nxt
            elif isinstance(cur, list) and p.isdigit() and int(p) < len(cur):
                cur = cur[int(p)]
            else:
                return None
            if cur is None:
                break
        return cur

    def call(self, name, a):
        n = name.lower()
        if n == "contains":
            hay, needle = a[0], a[1]
            if isinstance(hay, list):
                return any(_loose_eq(x, needle) for x in hay)
            return _str(needle).lower() in _str(hay).lower()
        if n == "startswith":
            return _str(a[0]).lower().startswith(_str(a[1]).lower())
        if n == "endswith":
            return _str(a[0]).lower().endswith(_str(a[1]).lower())
        if n == "format":
            s = _str(a[0])
            s = re.sub(r"\{(\d+)\}", lambda m: _str(a[int(m.group(1)) + 1]) if int(m.group(1)) + 1 < len(a) else "", s)
            return s.replace("{{", "{").replace("}}", "}")
        if n == "join":
            sep = _str(a[1]) if len(a) > 1 else ","
            return sep.join(_str(x) for x in (a[0] if isinstance(a[0], list) else [a[0]]))
        if n == "tojson":
            return json.dumps(a[0], indent=2)
        if n == "fromjson":
            try:
                return json.loads(_str(a[0]))
            except ValueError:
                raise ExprError("fromJSON: not JSON")
        if n == "hashfiles":
            h = hashlib.sha256()
            base = os.environ.get("GITHUB_WORKSPACE") or os.getcwd()
            found = False
            for pat in a:
                for f in sorted(glob.glob(os.path.join(base, _str(pat)), recursive=True)):
                    if os.path.isfile(f):
                        found = True
                        h.update(hashlib.sha256(open(f, "rb").read()).digest())
            return h.hexdigest() if found else ""
        if n in ("success", "always"):
            return True
        if n in ("failure", "cancelled"):
            return False
        raise ExprError("unknown function %s" % name)


def evaluate(src, ctx):
    return _Parser(src, ctx).parse()


def interpolate(text, ctx, keep_unresolved=True):
    """Replaces every ${{ ... }} in text. Unresolvable references stay as written when keep_unresolved is set."""
    def sub(m):
        try:
            return _str(evaluate(m.group(1), ctx))
        except Unresolved:
            if keep_unresolved:
                return m.group(0)
            return ""
        except ExprError:
            return ""
    return re.sub(r"\$\{\{(.*?)\}\}", sub, text or "")


def condition(src, ctx):
    """An `if:` value: True/False, or None when it can't be decided yet. Text wrapped in ${{ }} is accepted."""
    s = (src or "").strip()
    if not s:
        return True
    m = re.fullmatch(r"\$\{\{(.*)\}\}", s, re.S)
    if m:
        s = m.group(1)
    try:
        return truthy(evaluate(s, ctx))
    except Unresolved:
        return None
    except ExprError:
        return True


def runtime_context(env=None, steps=None):
    """The contexts a running step can see, from the environment variables the runner sets."""
    e = dict(os.environ if env is None else env)
    repo = e.get("GITHUB_REPOSITORY", "")
    github = {"event_name": e.get("GITHUB_EVENT_NAME", "workflow_dispatch"), "ref": e.get("GITHUB_REF", "refs/heads/main"),
              "ref_name": e.get("GITHUB_REF_NAME", "main"), "ref_type": "branch", "repository": repo,
              "repository_owner": repo.split("/")[0] if repo else "", "sha": e.get("GITHUB_SHA", "0" * 40),
              "workspace": e.get("GITHUB_WORKSPACE", ""), "actor": e.get("GITHUB_ACTOR", repo.split("/")[0] if repo else ""),
              "run_id": e.get("GITHUB_RUN_ID", "1"), "run_number": e.get("GITHUB_RUN_NUMBER", "1"),
              "run_attempt": e.get("GITHUB_RUN_ATTEMPT", "1"), "server_url": "https://github.com", "head_ref": "", "base_ref": "",
              "workflow": e.get("GITHUB_WORKFLOW", ""), "job": e.get("GITHUB_JOB", ""), "token": "", "event": {"inputs": {}}}
    ctx = {"github": github, "env": e, "runner": {"os": "macOS", "arch": "ARM64", "temp": e.get("RUNNER_TEMP", ""), "name": "iOXcode"},
           "secrets": {}, "vars": {}, "inputs": {}, "matrix": {}}
    if steps is not None:
        ctx["steps"] = steps
    return ctx
