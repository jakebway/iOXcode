"""ioxsh: a small POSIX-style shell that runs inside iOXcode.

iPhone apps can't start other programs, so there is no /bin/sh to run a project's build scripts
(Xcode "Run Script" phases, XcodeGen scripts, GitHub workflow `run:` steps). ioxsh understands the
shell language those scripts use and runs the common commands itself, in-process:

  control:  ; && || | if/elif/else/fi  for/while/until  case/esac  { }  ( )  functions
  words:    'single' "double" \\escapes  $VAR ${VAR} ${VAR:-x} ${#VAR} $(cmd) `cmd` $((1+2)) ~ globs
  redirect: > >> < 2> 2>&1 &> /dev/null
  commands: echo printf cd pwd mkdir cp mv rm ls cat touch ln chmod test [ [[ true false : set export
            unset exit return which command type basename dirname head tail wc grep sed tr sort uniq
            find xargs env sleep source . python python3 pip curl wget unzip zip tar shasum date
            mktemp realpath readlink ditto seq yes
            (Mac-only tools like brew, xcodebuild, codesign are reported and skipped.)
"""
import fnmatch, glob, io, os, re, shlex, shutil, stat, sys, time

RESERVED = {"if", "then", "elif", "else", "fi", "for", "in", "do", "done", "while", "until",
            "case", "esac", "{", "}", "function", "!"}


class ShellExit(Exception):
    def __init__(self, code): self.code = code

class FuncReturn(Exception):
    def __init__(self, code): self.code = code

class LoopBreak(Exception):
    def __init__(self, n=1): self.n = n

class LoopContinue(Exception):
    def __init__(self, n=1): self.n = n

class ShellSyntaxError(Exception):
    pass


# ---------------------------------------------------------------- lexer

def _scan_balanced(s, i, open_c, close_c):
    """s[i] is just after open_c; return index just after the matching close_c."""
    depth, n = 1, len(s)
    while i < n:
        c = s[i]
        if c == "\\":
            i += 2; continue
        if c == "'" and open_c == "(":
            j = s.find("'", i + 1); i = (j + 1) if j >= 0 else n; continue
        if c == '"':
            i = _scan_dquote(s, i + 1); continue
        if c == open_c:
            depth += 1
        elif c == close_c:
            depth -= 1
            if depth == 0:
                return i + 1
        i += 1
    raise ShellSyntaxError("missing '%s'" % close_c)


def _scan_dquote(s, i):
    """s[i] is just after the opening quote; return index just after the closing quote."""
    n = len(s)
    while i < n:
        c = s[i]
        if c == "\\":
            i += 2; continue
        if c == '"':
            return i + 1
        if c == "$" and i + 1 < n and s[i + 1] == "(":
            i = _scan_balanced(s, i + 2, "(", ")"); continue
        if c == "`":
            j = i + 1
            while j < n and s[j] != "`":
                j += 2 if s[j] == "\\" else 1
            i = j + 1; continue
        i += 1
    raise ShellSyntaxError("missing closing \"")


def lex(src):
    toks, cur, i, n = [], None, 0, len(src)

    def add(kind, text):
        nonlocal cur
        if cur is None:
            cur = []
        if cur and cur[-1][0] == kind and kind == "lit":
            cur[-1] = ("lit", cur[-1][1] + text)
        else:
            cur.append((kind, text))

    def flush():
        nonlocal cur
        if cur is not None:
            toks.append(("W", cur)); cur = None

    while i < n:
        c = src[i]
        if c in " \t\r":
            flush(); i += 1
        elif c == "\\":
            if i + 1 < n and src[i + 1] == "\n":
                i += 2
            else:
                add("sq", src[i + 1] if i + 1 < n else ""); i += 2
        elif c == "\n":
            flush(); toks.append(("OP", "\n")); i += 1
        elif c == "#" and cur is None:
            while i < n and src[i] != "\n":
                i += 1
        elif c == "'":
            j = src.find("'", i + 1)
            if j < 0:
                raise ShellSyntaxError("missing closing '")
            add("sq", src[i + 1:j]); i = j + 1
        elif c == '"':
            j = _scan_dquote(src, i + 1)
            add("dq", src[i + 1:j - 1]); i = j
        elif c == "$" and i + 1 < n and src[i + 1] == "(":
            j = _scan_balanced(src, i + 2, "(", ")")
            add("lit", src[i:j]); i = j
        elif c == "$" and i + 1 < n and src[i + 1] == "{":
            j = _scan_balanced(src, i + 2, "{", "}")
            add("lit", src[i:j]); i = j
        elif c == "`":
            j = i + 1
            while j < n and src[j] != "`":
                j += 2 if src[j] == "\\" else 1
            add("lit", src[i:j + 1]); i = j + 1
        elif c in ";&|<>()":
            # fd prefix for redirections: 2>file, 1>&2
            fd = None
            if c in "<>" and cur is not None and len(cur) == 1 and cur[0][0] == "lit" and cur[0][1].isdigit():
                fd = cur[0][1]; cur = None
            flush()
            for op in (";;", "&&", "||", "&>>", "&>", ">>", ">&", "<&", ">|", "<<", ";", "&", "|", "<", ">", "(", ")"):
                if src.startswith(op, i):
                    break
            if op == "<<":
                # here-document: <<EOF ... EOF  (or <<-EOF, <<'EOF')
                m = re.match(r"<<(-?)\s*(['\"]?)(\w+)\2", src[i:])
                if not m:
                    raise ShellSyntaxError("bad here-document")
                i += m.end()
                eol = src.find("\n", i)
                rest_of_line = src[i:eol if eol >= 0 else n]
                body_start = (eol + 1) if eol >= 0 else n
                lines, k = [], body_start
                while k < n:
                    e = src.find("\n", k)
                    line = src[k:e if e >= 0 else n]
                    k = (e + 1) if e >= 0 else n
                    if (line.lstrip("\t") if m.group(1) else line) == m.group(3):
                        break
                    lines.append(line.lstrip("\t") if m.group(1) else line)
                toks.append(("OP", "<<"))
                toks.append(("HEREDOC", ("\n".join(lines) + "\n", bool(m.group(2)))))
                # keep the rest of the command line, then continue after the body
                src = src[:i] + rest_of_line + "\n" + src[k:]
                n = len(src)
                continue
            toks.append(("OP", (fd or "") + op)); i += len(op)
        else:
            add("lit", c); i += 1
    flush()
    return toks


# ---------------------------------------------------------------- parser

class Parser:
    def __init__(self, toks):
        self.t, self.i = toks, 0

    def peek(self):
        return self.t[self.i] if self.i < len(self.t) else ("EOF", None)

    def next(self):
        tok = self.peek(); self.i += 1; return tok

    @staticmethod
    def word_text(tok):
        if tok[0] == "W" and len(tok[1]) == 1 and tok[1][0][0] == "lit":
            return tok[1][0][1]
        return None

    def at_reserved(self, names):
        return self.word_text(self.peek()) in names

    def expect(self, name):
        tok = self.next()
        if self.word_text(tok) != name:
            raise ShellSyntaxError("expected '%s'" % name)

    def skip_newlines(self):
        while self.peek() in (("OP", "\n"), ("OP", ";")):
            self.i += 1

    def parse_list(self, stop=()):
        items = []
        while True:
            while self.peek() in (("OP", "\n"), ("OP", ";"), ("OP", "&")):
                self.i += 1
            tok = self.peek()
            if tok[0] == "EOF" or tok == ("OP", ")") or tok == ("OP", ";;") or self.at_reserved(stop):
                return items
            items.append(self.parse_and_or())

    def parse_and_or(self):
        node = self.parse_pipeline()
        while self.peek() in (("OP", "&&"), ("OP", "||")):
            op = self.next()[1]
            while self.peek() == ("OP", "\n"):
                self.i += 1
            node = ("andor", op, node, self.parse_pipeline())
        return node

    def parse_pipeline(self):
        negate = False
        if self.at_reserved({"!"}):
            self.next(); negate = True
        cmds = [self.parse_command()]
        while self.peek() == ("OP", "|"):
            self.next()
            while self.peek() == ("OP", "\n"):
                self.i += 1
            cmds.append(self.parse_command())
        node = cmds[0] if len(cmds) == 1 else ("pipe", cmds)
        return ("not", node) if negate else node

    def parse_redirects(self):
        reds = []
        while True:
            tok = self.peek()
            if tok[0] == "OP" and re.fullmatch(r"\d?(>>|>&|<&|>\||&>>|&>|<|>|<<)", tok[1]):
                op = self.next()[1]
                if op.endswith("<<"):
                    reds.append(("heredoc", self.next()[1]))
                    continue
                target = self.next()
                if target[0] != "W":
                    raise ShellSyntaxError("missing file name after " + op)
                reds.append((op, target[1]))
            else:
                return reds

    def parse_command(self):
        w = self.word_text(self.peek())
        if w == "if":
            self.next()
            branches = []
            cond = self.parse_list({"then"}); self.expect("then")
            body = self.parse_list({"elif", "else", "fi"})
            branches.append((cond, body))
            else_body = None
            while True:
                k = self.word_text(self.next())
                if k == "elif":
                    cond = self.parse_list({"then"}); self.expect("then")
                    branches.append((cond, self.parse_list({"elif", "else", "fi"})))
                elif k == "else":
                    else_body = self.parse_list({"fi"}); self.expect("fi"); break
                elif k == "fi":
                    break
                else:
                    raise ShellSyntaxError("expected 'fi'")
            return ("if", branches, else_body, self.parse_redirects())
        if w == "for":
            self.next()
            name = self.word_text(self.next())
            items = None
            if self.peek() == ("OP", "(") :
                raise ShellSyntaxError("C-style for loops are not supported")
            while self.peek() == ("OP", "\n"):
                self.i += 1
            if self.at_reserved({"in"}):
                self.next(); items = []
                while self.peek()[0] == "W":
                    items.append(self.next()[1])
            self.skip_newlines(); self.expect("do")
            body = self.parse_list({"done"}); self.expect("done")
            return ("for", name, items, body, self.parse_redirects())
        if w in ("while", "until"):
            self.next()
            cond = self.parse_list({"do"}); self.expect("do")
            body = self.parse_list({"done"}); self.expect("done")
            return ("while", w == "until", cond, body, self.parse_redirects())
        if w == "case":
            self.next()
            subject = self.next()[1]
            self.skip_newlines(); self.expect("in")
            arms = []
            while True:
                self.skip_newlines()
                if self.at_reserved({"esac"}):
                    self.next(); break
                if self.peek() == ("OP", "("):
                    self.next()
                pats = [self.next()[1]]
                while self.peek() == ("OP", "|"):
                    self.next(); pats.append(self.next()[1])
                if self.next() != ("OP", ")"):
                    raise ShellSyntaxError("expected ')' in case")
                body = self.parse_list({"esac"})
                arms.append((pats, body))
                if self.peek() == ("OP", ";;"):
                    self.next()
            return ("case", subject, arms, self.parse_redirects())
        if w == "{":
            self.next()
            body = self.parse_list({"}"}); self.expect("}")
            return ("group", body, self.parse_redirects())
        if self.peek() == ("OP", "("):
            self.next()
            body = self.parse_list()
            if self.next() != ("OP", ")"):
                raise ShellSyntaxError("expected ')'")
            return ("subshell", body, self.parse_redirects())
        if w == "function":
            self.next()
            name = self.word_text(self.next())
            if self.peek() == ("OP", "("):
                self.next(); self.next()
            self.skip_newlines()
            return ("func", name, self.parse_command())
        # name() { ... }
        if w is not None and self.i + 2 < len(self.t) and self.t[self.i + 1] == ("OP", "(") and self.t[self.i + 2] == ("OP", ")"):
            self.i += 3
            self.skip_newlines()
            return ("func", w, self.parse_command())
        # simple command
        words, reds, assigns = [], [], []
        while True:
            tok = self.peek()
            if tok[0] == "W":
                txt = self.word_text(tok)
                if not words and tok[1][0][0] == "lit" and re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", tok[1][0][1]):
                    assigns.append(self.next()[1]); continue
                words.append(self.next()[1])
            elif tok[0] == "OP" and re.fullmatch(r"\d?(>>|>&|<&|>\||&>>|&>|<|>|<<)", tok[1]):
                reds.extend(self.parse_redirects())
            else:
                break
        if not words and not assigns and not reds:
            tok = self.peek()
            raise ShellSyntaxError("unexpected %r" % (tok[1] if tok[0] != "W" else self.word_text(tok)))
        return ("cmd", assigns, words, reds)


# ---------------------------------------------------------------- shell

class Null(io.StringIO):
    def write(self, s): return len(s)


class Shell:
    def __init__(self, out, err=None):
        self.out, self.err = out, err or out
        self.funcs = {}
        self.positional = []
        self.last = 0
        self.errexit = False
        self.xtrace = False
        self.in_condition = 0
        self.script_name = "ioxsh"

    # ---- variables
    def getvar(self, name):
        if name == "?": return str(self.last)
        if name == "#": return str(len(self.positional))
        if name in ("@", "*"): return " ".join(self.positional)
        if name == "$": return str(os.getpid())
        if name == "0": return self.script_name
        if name.isdigit():
            k = int(name)
            return self.positional[k - 1] if 0 < k <= len(self.positional) else ""
        if name == "PWD": return os.getcwd()
        if name == "RANDOM":
            import random; return str(random.randint(0, 32767))
        return os.environ.get(name, "")

    def setvar(self, name, value):
        os.environ[name] = value

    # ---- expansion
    def expand_text(self, s, quoted):
        """Expand $... and `...` in s. Returns a list of (text, from_expansion) chunks."""
        out, i, n = [], 0, len(s)
        buf = ""
        while i < n:
            c = s[i]
            if quoted and c == "\\" and i + 1 < n and s[i + 1] in '$`"\\\n':
                buf += "" if s[i + 1] == "\n" else s[i + 1]; i += 2; continue
            if c == "$" and i + 1 < n:
                nx = s[i + 1]
                if s.startswith("$((", i):
                    j = _scan_balanced(s, i + 3, "(", ")")
                    expr = s[i + 3:j - 1]
                    if j < n and s[j] == ")":
                        j += 1
                    out.append((buf, False)); buf = ""
                    out.append((str(self.arith(expr)), True)); i = j; continue
                if nx == "(":
                    j = _scan_balanced(s, i + 2, "(", ")")
                    out.append((buf, False)); buf = ""
                    out.append((self.capture(s[i + 2:j - 1]), True)); i = j; continue
                if nx == "{":
                    j = _scan_balanced(s, i + 2, "{", "}")
                    out.append((buf, False)); buf = ""
                    out.append((self.param(s[i + 2:j - 1]), True)); i = j; continue
                m = re.match(r"[A-Za-z_][A-Za-z0-9_]*|[0-9?#@*$!-]", s[i + 1:])
                if m:
                    out.append((buf, False)); buf = ""
                    out.append((self.getvar(m.group(0)), True)); i += 1 + m.end(); continue
            if c == "`":
                j = i + 1
                while j < n and s[j] != "`":
                    j += 2 if s[j] == "\\" else 1
                out.append((buf, False)); buf = ""
                out.append((self.capture(s[i + 1:j].replace("\\`", "`")), True)); i = j + 1; continue
            buf += c; i += 1
        out.append((buf, False))
        return out

    def param(self, body):
        if body.startswith("#"):
            return str(len(self.getvar(body[1:])))
        m = re.match(r"([A-Za-z_][A-Za-z0-9_]*|[0-9]+|[?#@*])(.*)$", body, re.S)
        if not m:
            return ""
        name, rest = m.group(1), m.group(2)
        val = self.getvar(name)
        isset = name in os.environ or (name.isdigit() and int(name) <= len(self.positional)) or name in "?#@*"
        if not rest:
            return val
        def word(w): return self.expand_word_to_string([("dq", w)])
        for op in (":-", ":=", ":+", ":?", "-", "=", "+", "?"):
            if rest.startswith(op):
                w = rest[len(op):]
                empty = (not val) if op.startswith(":") else (not isset)
                if op.endswith("-"): return word(w) if empty else val
                if op.endswith("="):
                    if empty: self.setvar(name, word(w)); return word(w)
                    return val
                if op.endswith("+"): return "" if empty else word(w)
                if op.endswith("?"):
                    if empty:
                        self.err.write("%s: %s\n" % (name, word(w) or "parameter not set")); raise ShellExit(1)
                    return val
        for op in ("##", "#", "%%", "%"):
            if rest.startswith(op):
                pat = fnmatch.translate(word(rest[len(op):]))[4:-3]  # strip (?s: ... )\Z
                if op == "#": m2 = re.match("(?s)" + _lazy(pat), val)
                elif op == "##": m2 = re.match("(?s)" + pat, val)
                elif op == "%": m2 = _rmatch(pat, val, greedy=False)
                else: m2 = _rmatch(pat, val, greedy=True)
                if m2 is None: return val
                if op.startswith("#"): return val[m2.end():]
                return val[:m2]
        if rest.startswith("/"):
            parts = rest[1:].split("/", 1)
            pat, rep = parts[0], (parts[1] if len(parts) > 1 else "")
            allm = pat.startswith("/")
            if allm: pat = pat[1:]
            return val.replace(word(pat), word(rep)) if allm else val.replace(word(pat), word(rep), 1)
        if rest.startswith(":"):
            nums = rest[1:].split(":")
            try:
                off = int(self.arith(nums[0])); ln = int(self.arith(nums[1])) if len(nums) > 1 else None
                return val[off:] if ln is None else val[off:off + ln]
            except Exception:
                return val
        return val

    def arith(self, expr):
        e = re.sub(r"\$?\{?([A-Za-z_][A-Za-z0-9_]*)\}?", lambda m: str(_int(self.getvar(m.group(1)))), expr)
        e = e.replace("&&", " and ").replace("||", " or ").replace("/", "//")
        try:
            return int(eval(e, {"__builtins__": {}}, {}))
        except Exception:
            return 0

    def capture(self, src):
        buf = io.StringIO()
        saved = (self.out, self.last)
        self.out = buf
        try:
            self.run_source(src)
        except ShellExit:
            pass
        finally:
            self.out = saved[0]
        return buf.getvalue().rstrip("\n")

    def expand_word(self, parts, split=True, globbing=True):
        """Expand one word into zero or more fields."""
        fields = [[]]          # list of fields, each a list of (text, glob_ok)
        had_quotes = False
        def append(text, glob_ok):
            fields[-1].append((text, glob_ok))
        for idx, (kind, text) in enumerate(parts):
            if kind == "sq":
                had_quotes = True; append(text, False)
            elif kind == "dq":
                had_quotes = True
                for t, _ in self.expand_text(text, True):
                    append(t, False)
            else:
                if idx == 0 and text.startswith("~") and (len(text) == 1 or text[1] == "/"):
                    text = os.environ.get("HOME", "/") + text[1:]
                for t, from_exp in self.expand_text(text, False):
                    if from_exp and split:
                        pieces = re.split(r"[ \t\n]+", t)
                        if len(pieces) > 1:
                            for k, p in enumerate(pieces):
                                if k > 0:
                                    fields.append([])
                                if p:
                                    append(p, True)
                            continue
                    append(t, not from_exp or split)
        result = []
        for f in fields:
            plain = "".join(t for t, _ in f)
            if not f or (plain == "" and not had_quotes):
                continue
            if globbing and any(ok and re.search(r"[*?\[]", t) for t, ok in f):
                pattern = "".join(t if ok else glob.escape(t) for t, ok in f)
                matches = sorted(glob.glob(pattern))
                if matches:
                    result.extend(matches); continue
            result.append(plain)
        if not result and had_quotes:
            result.append("")
        return result

    def expand_word_to_string(self, parts):
        return " ".join(self.expand_word(parts, split=False, globbing=False))

    def expand_words(self, words):
        out = []
        for w in words:
            if len(w) == 1 and w[0] == ("dq", "$@"):
                out.extend(self.positional); continue
            out.extend(self.expand_word(w))
        return out

    # ---- running
    def run_source(self, src):
        tree = Parser(lex(src)).parse_list()
        return self.run_list(tree)

    def run_list(self, items):
        code = 0
        for node in items:
            code = self.run_node(node)
        return code

    def check_errexit(self, code):
        if code != 0 and self.errexit and self.in_condition == 0:
            raise ShellExit(code)

    def run_node(self, node, stdin=None):
        kind = node[0]
        if kind == "andor":
            _, op, left, right = node
            self.in_condition += 1
            try:
                code = self.run_node(left, stdin)
            finally:
                self.in_condition -= 1
            if (op == "&&" and code == 0) or (op == "||" and code != 0):
                code = self.run_node(right, stdin)
            self.last = code
            return code
        if kind == "not":
            self.in_condition += 1
            try:
                code = 0 if self.run_node(node[1], stdin) != 0 else 1
            finally:
                self.in_condition -= 1
            self.last = code
            return code
        if kind == "pipe":
            data = stdin
            saved = self.out
            code = 0
            for k, cmd in enumerate(node[1]):
                last = k == len(node[1]) - 1
                buf = saved if last else io.StringIO()
                self.out = buf
                try:
                    code = self.run_node(cmd, data)
                finally:
                    self.out = saved
                if not last:
                    data = buf.getvalue()
            self.last = code
            self.check_errexit(code)
            return code
        if kind == "cmd":
            code = self.run_simple(node, stdin)
            self.last = code
            self.check_errexit(code)
            return code
        if kind == "func":
            self.funcs[node[1]] = node[2]
            return 0
        return self.with_redirects(node[-1], stdin, lambda s: self.run_compound(node, s))

    def run_compound(self, node, stdin):
        kind = node[0]
        if kind == "if":
            for cond, body in node[1]:
                self.in_condition += 1
                try:
                    c = self.run_list(cond)
                finally:
                    self.in_condition -= 1
                if c == 0:
                    return self.run_list(body)
            return self.run_list(node[2]) if node[2] is not None else 0
        if kind == "for":
            _, name, items, body, _ = node
            values = self.positional if items is None else self.expand_words(items)
            code = 0
            for v in values:
                self.setvar(name, v)
                try:
                    code = self.run_list(body)
                except LoopBreak as b:
                    if b.n > 1: raise LoopBreak(b.n - 1)
                    break
                except LoopContinue as c:
                    if c.n > 1: raise LoopContinue(c.n - 1)
                    continue
            return code
        if kind == "while":
            _, until, cond, body, _ = node
            code, guard = 0, 0
            while True:
                self.in_condition += 1
                try:
                    c = self.run_list(cond)
                finally:
                    self.in_condition -= 1
                if (c == 0) == until:
                    break
                guard += 1
                if guard > 1_000_000:
                    self.err.write("ioxsh: loop ran a million times, stopping\n"); return 1
                try:
                    code = self.run_list(body)
                except LoopBreak as b:
                    if b.n > 1: raise LoopBreak(b.n - 1)
                    break
                except LoopContinue as c2:
                    if c2.n > 1: raise LoopContinue(c2.n - 1)
                    continue
            return code
        if kind == "case":
            subject = self.expand_word_to_string(node[1])
            for pats, body in node[2]:
                for p in pats:
                    if fnmatch.fnmatchcase(subject, self.expand_word_to_string(p)):
                        return self.run_list(body)
            return 0
        if kind == "group":
            return self.run_list(node[1])
        if kind == "subshell":
            cwd, env = os.getcwd(), dict(os.environ)
            try:
                return self.run_list(node[1])
            except ShellExit as e:
                return e.code
            finally:
                os.chdir(cwd); os.environ.clear(); os.environ.update(env)
        return 0

    def with_redirects(self, reds, stdin, body):
        saved_out, saved_err = self.out, self.err
        opened = []
        try:
            for op, target in reds:
                if op == "heredoc":
                    text, literal = target
                    stdin = text if literal else "".join(t for t, _ in self.expand_text(text, True))
                    continue
                if op.endswith(">&") or op.endswith("<&"):
                    fd = op[0] if op[0].isdigit() else "1"
                    t = self.expand_word_to_string(target)
                    if fd == "2" and t == "1": self.err = self.out
                    elif fd == "1" and t == "2": self.out = self.err
                    continue
                path = self.expand_word_to_string(target)
                if op.lstrip("0123456789") == "<":
                    with open(path, encoding="utf-8", errors="replace") as f:
                        stdin = f.read()
                    continue
                append = ">>" in op
                if path == "/dev/null":
                    f = Null()
                elif path in ("/dev/stderr",):
                    f = saved_err
                elif path in ("/dev/stdout",):
                    f = saved_out
                else:
                    f = open(path, "a" if append else "w", encoding="utf-8")
                    opened.append(f)
                if op.startswith("&"):
                    self.out = self.err = f
                elif op.startswith("2"):
                    self.err = f
                else:
                    self.out = f
            return body(stdin)
        finally:
            for f in opened:
                f.close()
            self.out, self.err = saved_out, saved_err

    def run_simple(self, node, stdin):
        _, assigns, words, reds = node
        argv = self.expand_words(words)
        temp_env = {}
        for a in assigns:
            name, _, rest = a[0][1].partition("=")
            parts = ([("lit", rest)] if rest else []) + a[1:]
            value = self.expand_word_to_string(parts) if parts else ""
            if argv:
                temp_env[name] = value
            else:
                self.setvar(name, value)
        if not argv:
            return self.with_redirects(reds, stdin, lambda s: 0) if reds else 0
        if self.xtrace:
            self.err.write("+ " + " ".join(shlex.quote(a) for a in argv) + "\n")
        saved_env = {k: os.environ.get(k) for k in temp_env}
        os.environ.update(temp_env)
        try:
            return self.with_redirects(reds, stdin, lambda s: self.call(argv, s))
        finally:
            for k, v in saved_env.items():
                if v is None: os.environ.pop(k, None)
                else: os.environ[k] = v

    def call(self, argv, stdin):
        name = argv[0]
        if name in self.funcs:
            saved = self.positional
            self.positional = argv[1:]
            try:
                return self.run_node(self.funcs[name], stdin)
            except FuncReturn as r:
                return r.code
            finally:
                self.positional = saved
        fn = BUILTINS.get(name) or BUILTINS.get(os.path.basename(name))
        if fn is None and re.fullmatch(r"python3(\.\d+)?|python", os.path.basename(name)):
            fn = BUILTINS["python3"]
        if fn is None and (name.endswith(".sh") or name.endswith(".py")) and os.path.isfile(name):
            return run_file(self, name, argv[1:], stdin)
        if fn is None:
            if os.path.isfile(name):
                return run_file(self, name, argv[1:], stdin)
            if name in MAC_ONLY:
                self.err.write("note: %s %s\n" % (name, MAC_ONLY[name]))
                return 0 if MAC_ONLY[name].startswith("is not needed") else 127
            self.err.write("%s: command not found (not available on iPhone)\n" % name)
            return 127
        try:
            r = fn(self, argv[1:], stdin)
            return 0 if r is None else int(r)
        except (ShellExit, FuncReturn, LoopBreak, LoopContinue):
            raise
        except FileNotFoundError as e:
            self.err.write("%s: %s: No such file or directory\n" % (name, e.filename or e)); return 1
        except Exception as e:
            self.err.write("%s: %s\n" % (name, e)); return 1


def _int(s):
    try: return int(str(s).strip() or 0)
    except ValueError: return 0

def _lazy(pat):
    return re.sub(r"(\.\*)(?!\?)", r"\1?", pat)

def _rmatch(pat, val, greedy):
    """Index where the shortest/longest suffix matching pat starts, or None."""
    rng = range(len(val) + 1) if greedy else range(len(val), -1, -1)
    for k in rng:
        if re.fullmatch("(?s)" + pat, val[k:]):
            return k
    return None


def run_file(sh, path, args, stdin):
    with open(path, encoding="utf-8", errors="replace") as f:
        first = f.readline()
    if path.endswith(".py") or "python" in first:
        return BUILTINS["python3"](sh, [path] + list(args), stdin)
    with open(path, encoding="utf-8", errors="replace") as f:
        src = f.read()
    sub = Shell(sh.out, sh.err)
    sub.funcs = dict(sh.funcs)
    sub.positional = list(args)
    sub.script_name = path
    cwd = os.getcwd()
    try:
        return sub.run_source(src)
    except ShellExit as e:
        return e.code
    finally:
        os.chdir(cwd)


# ---------------------------------------------------------------- commands

BUILTINS = {}
def builtin(*names):
    def deco(f):
        for n in names: BUILTINS[n] = f
        return f
    return deco

MAC_ONLY = {
    "brew": "is not needed on iPhone; skipping",
    "sudo": "is not available on iPhone",
    "xcodebuild": "is iOXcode's job on iPhone; skipping",
    "xcrun": "is not available on iPhone",
    "xcode-select": "is not needed on iPhone; skipping",
    "codesign": "is not needed (FlareStore signs the app); skipping",
    "security": "is not needed on iPhone; skipping",
    "plutil": "is not available on iPhone",
    "swiftlint": "is not available on iPhone",
    "swiftformat": "is not available on iPhone",
    "pod": "(CocoaPods) is not available on iPhone",
    "cargo": "(Rust) is not available on iPhone",
    "rustup": "(Rust) is not available on iPhone",
    "npm": "is not available on iPhone",
    "node": "is not available on iPhone",
    "git": "is not available inside a build on iPhone",
    "gh": "is not available on iPhone",
}

def _opts(args, flags):
    """Split leading -abc flags (only letters in `flags`) from the rest."""
    on, rest = set(), list(args)
    while rest and rest[0].startswith("-") and len(rest[0]) > 1 and rest[0] != "--" and not rest[0][1].isdigit():
        a = rest.pop(0)
        if a.startswith("--"):
            on.add(a); continue
        for ch in a[1:]:
            on.add(ch)
    if rest and rest[0] == "--":
        rest.pop(0)
    return on, rest

@builtin("true", ":")
def _true(sh, a, i): return 0

@builtin("false")
def _false(sh, a, i): return 1

@builtin("echo")
def _echo(sh, a, i):
    newline, escapes = True, False
    while a and re.fullmatch(r"-[neE]+", a[0]):
        f = a.pop(0)
        if "n" in f: newline = False
        if "e" in f: escapes = True
    s = " ".join(a)
    if escapes:
        s = s.encode("utf-8").decode("unicode_escape")
    sh.out.write(s + ("\n" if newline else ""))

@builtin("printf")
def _printf(sh, a, i):
    if not a: return 1
    fmt, args = a[0], a[1:]
    fmt = fmt.encode("utf-8").decode("unicode_escape")
    specs = re.findall(r"%[-+ #0]*\d*(?:\.\d+)?[sdifxXoc%]", fmt)
    n = len([s for s in specs if s != "%%"]) or 1
    out = ""
    while True:
        chunk, k = fmt, 0
        def conv(m):
            nonlocal k
            spec = m.group(0)
            if spec == "%%": return "%"
            v = args[k] if k < len(args) else ""
            k += 1
            t = spec[-1]
            if t in "dixXoc": return spec.replace("i", "d") % _int(v) if t != "c" else (v[:1])
            if t == "f": return spec % float(v or 0)
            return spec % v
        out += re.sub(r"%[-+ #0]*\d*(?:\.\d+)?[sdifxXoc%]", conv, chunk)
        args = args[n:]
        if not args: break
    sh.out.write(out)

@builtin("cd", "pushd")
def _cd(sh, a, i):
    target = a[0] if a else os.environ.get("HOME", "/")
    if target == "-": target = os.environ.get("OLDPWD", os.getcwd())
    old = os.getcwd()
    os.chdir(target)
    os.environ["OLDPWD"] = old
    os.environ["PWD"] = os.getcwd()

@builtin("popd")
def _popd(sh, a, i):
    os.chdir(os.environ.get("OLDPWD", os.getcwd()))

@builtin("pwd")
def _pwd(sh, a, i): sh.out.write(os.getcwd() + "\n")

@builtin("mkdir")
def _mkdir(sh, a, i):
    o, rest = _opts(a, "pvm")
    for d in rest:
        if "p" in o: os.makedirs(d, exist_ok=True)
        else: os.mkdir(d)

def _copy(src, dst, recursive):
    if os.path.isdir(dst) and not (src.endswith("/") and os.path.isdir(src)):
        dst = os.path.join(dst, os.path.basename(src.rstrip("/")))
    if os.path.isdir(src):
        if not recursive:
            raise Exception("%s is a directory (not copied)" % src)
        if src.endswith("/") and os.path.isdir(dst):
            shutil.copytree(src, dst, dirs_exist_ok=True, symlinks=True)
        else:
            shutil.copytree(src, dst, dirs_exist_ok=True, symlinks=True)
    else:
        shutil.copy2(src, dst)

@builtin("cp")
def _cp(sh, a, i):
    o, rest = _opts(a, "rRfapvnXL")
    if len(rest) < 2: raise Exception("missing destination")
    dst = rest[-1]
    for s in rest[:-1]:
        _copy(s, dst, bool(o & {"r", "R", "a"}))

@builtin("ditto")
def _ditto(sh, a, i):
    o, rest = _opts(a, "ckV")
    src, dst = rest[0], rest[1]
    if os.path.isdir(src): shutil.copytree(src, dst, dirs_exist_ok=True, symlinks=True)
    else:
        os.makedirs(os.path.dirname(dst) or ".", exist_ok=True); shutil.copy2(src, dst)

@builtin("mv")
def _mv(sh, a, i):
    o, rest = _opts(a, "fvn")
    dst = rest[-1]
    for s in rest[:-1]:
        d = os.path.join(dst, os.path.basename(s.rstrip("/"))) if os.path.isdir(dst) else dst
        shutil.move(s, d)

@builtin("rm", "rmdir")
def _rm(sh, a, i):
    o, rest = _opts(a, "rRfdv")
    for p in rest:
        if os.path.isdir(p) and not os.path.islink(p):
            if o & {"r", "R"} or not os.listdir(p): shutil.rmtree(p)
            else: raise Exception("%s is a directory" % p)
        elif os.path.lexists(p): os.remove(p)
        elif "f" not in o: raise FileNotFoundError(2, "No such file", p)

@builtin("ls")
def _ls(sh, a, i):
    o, rest = _opts(a, "laAhR1tSF")
    for p in rest or ["."]:
        if os.path.isdir(p):
            names = sorted(n for n in os.listdir(p) if "a" in o or "A" in o or not n.startswith("."))
            for n in names:
                full = os.path.join(p, n)
                if "l" in o:
                    st = os.lstat(full)
                    sh.out.write("%s %10d %s %s\n" % (stat.filemode(st.st_mode), st.st_size, time.strftime("%b %d %H:%M", time.localtime(st.st_mtime)), n))
                else:
                    sh.out.write(n + "\n")
        elif os.path.lexists(p):
            if "l" in o:
                st = os.lstat(p)
                sh.out.write("%s %10d %s\n" % (stat.filemode(st.st_mode), st.st_size, p))
            else:
                sh.out.write(p + "\n")
        else:
            sh.err.write("ls: %s: No such file or directory\n" % p); return 1

@builtin("cat")
def _cat(sh, a, i):
    if not a or a == ["-"]:
        sh.out.write(i or ""); return
    for p in a:
        if p == "-": sh.out.write(i or ""); continue
        with open(p, encoding="utf-8", errors="replace") as f:
            sh.out.write(f.read())

@builtin("touch")
def _touch(sh, a, i):
    _, rest = _opts(a, "acm")
    for p in rest:
        with open(p, "a"): pass
        os.utime(p, None)

@builtin("ln")
def _ln(sh, a, i):
    o, rest = _opts(a, "sfnhv")
    src, dst = rest[0], rest[1] if len(rest) > 1 else os.path.basename(rest[0])
    if os.path.isdir(dst) and not os.path.islink(dst): dst = os.path.join(dst, os.path.basename(src))
    if os.path.lexists(dst) and "f" in o: os.remove(dst)
    if "s" in o: os.symlink(src, dst)
    else: shutil.copy2(src, dst)

@builtin("chmod")
def _chmod(sh, a, i):
    _, rest = _opts(a, "R")
    mode = rest[0]
    for p in rest[1:]:
        if re.fullmatch(r"[0-7]+", mode): os.chmod(p, int(mode, 8))
        elif "x" in mode: os.chmod(p, os.stat(p).st_mode | 0o111)

def _test(sh, args):
    a = list(args)
    if not a: return False
    if a[0] == "!": return not _test(sh, a[1:])
    for op in ("-o", "||"):
        if op in a:
            k = a.index(op); return _test(sh, a[:k]) or _test(sh, a[k + 1:])
    for op in ("-a", "&&"):
        if op in a:
            k = a.index(op); return _test(sh, a[:k]) and _test(sh, a[k + 1:])
    if a[0] == "(" and a[-1] == ")": return _test(sh, a[1:-1])
    if len(a) == 1: return a[0] != ""
    if len(a) == 2:
        op, p = a
        if op == "-n": return p != ""
        if op == "-z": return p == ""
        if op == "-e": return os.path.exists(p)
        if op == "-f": return os.path.isfile(p)
        if op == "-d": return os.path.isdir(p)
        if op == "-s": return os.path.isfile(p) and os.path.getsize(p) > 0
        if op in ("-L", "-h"): return os.path.islink(p)
        if op == "-r": return os.access(p, os.R_OK)
        if op == "-w": return os.access(p, os.W_OK)
        if op == "-x": return os.access(p, os.X_OK)
        if op == "-v": return p in os.environ
        return False
    if len(a) == 3:
        x, op, y = a
        if op in ("=", "=="): return fnmatch.fnmatchcase(x, y) if sh_dbl[0] else x == y
        if op == "!=": return not (fnmatch.fnmatchcase(x, y) if sh_dbl[0] else x == y)
        if op == "=~": return re.search(y, x) is not None
        if op == "<": return x < y
        if op == ">": return x > y
        nums = {"-eq": lambda p, q: p == q, "-ne": lambda p, q: p != q, "-lt": lambda p, q: p < q,
                "-le": lambda p, q: p <= q, "-gt": lambda p, q: p > q, "-ge": lambda p, q: p >= q}
        if op in nums: return nums[op](_int(x), _int(y))
        if op == "-nt": return os.path.exists(x) and (not os.path.exists(y) or os.path.getmtime(x) > os.path.getmtime(y))
        if op == "-ot": return os.path.exists(y) and (not os.path.exists(x) or os.path.getmtime(x) < os.path.getmtime(y))
    return False

sh_dbl = [False]

@builtin("test")
def _test_cmd(sh, a, i): return 0 if _test(sh, a) else 1

@builtin("[")
def _bracket(sh, a, i):
    if a and a[-1] == "]": a = a[:-1]
    return 0 if _test(sh, a) else 1

@builtin("[[")
def _dbracket(sh, a, i):
    if a and a[-1] == "]]": a = a[:-1]
    sh_dbl[0] = True
    try: return 0 if _test(sh, a) else 1
    finally: sh_dbl[0] = False

@builtin("set")
def _set(sh, a, i):
    k = 0
    while k < len(a):
        x = a[k]
        if x in ("-o", "+o") and k + 1 < len(a):
            if a[k + 1] == "errexit": sh.errexit = x == "-o"
            k += 2; continue
        if x == "--":
            sh.positional = a[k + 1:]; return 0
        if x.startswith("-") or x.startswith("+"):
            if "e" in x: sh.errexit = x[0] == "-"
            if "x" in x: sh.xtrace = x[0] == "-"
            k += 1; continue
        sh.positional = a[k:]; return 0
    return 0

@builtin("shopt", "trap", "ulimit", "umask", "hash", "wait", "sync", "disown", "caffeinate", "local", "declare", "typeset", "readonly")
def _ignored(sh, a, i):
    for x in a:
        if "=" in x and not x.startswith("-"):
            k, _, v = x.partition("="); sh.setvar(k, v)
    return 0

@builtin("export")
def _export(sh, a, i):
    for x in a:
        if x.startswith("-"): continue
        if "=" in x:
            k, _, v = x.partition("="); sh.setvar(k, v)

@builtin("unset")
def _unset(sh, a, i):
    for x in a:
        if not x.startswith("-"):
            os.environ.pop(x, None); sh.funcs.pop(x, None)

@builtin("exit")
def _exit(sh, a, i): raise ShellExit(_int(a[0]) if a else sh.last)

@builtin("return")
def _return(sh, a, i): raise FuncReturn(_int(a[0]) if a else sh.last)

@builtin("break")
def _break(sh, a, i): raise LoopBreak(_int(a[0]) if a else 1)

@builtin("continue")
def _continue(sh, a, i): raise LoopContinue(_int(a[0]) if a else 1)

@builtin("shift")
def _shift(sh, a, i):
    n = _int(a[0]) if a else 1
    sh.positional = sh.positional[n:]

def _known(sh, name):
    return name in BUILTINS or name in sh.funcs or re.fullmatch(r"python3(\.\d+)?|python", name)

@builtin("which")
def _which(sh, a, i):
    _, rest = _opts(a, "as")
    code = 0
    for n in rest:
        if _known(sh, n): sh.out.write("/usr/bin/%s\n" % n)
        else: code = 1
    return code

@builtin("command", "type")
def _command(sh, a, i):
    o, rest = _opts(a, "vVp")
    if o & {"v", "V"} or BUILTINS.get("type") is None:
        code = 0
        for n in rest:
            if _known(sh, n): sh.out.write(n + "\n")
            else: code = 1
        return code
    return sh.call(rest, i) if rest else 0

@builtin("eval")
def _eval(sh, a, i): return sh.run_source(" ".join(a))

@builtin("source", ".")
def _source(sh, a, i):
    with open(a[0], encoding="utf-8", errors="replace") as f:
        src = f.read()
    saved = sh.positional
    if len(a) > 1: sh.positional = a[1:]
    try: return sh.run_source(src)
    finally: sh.positional = saved

@builtin("basename")
def _basename(sh, a, i):
    _, rest = _opts(a, "a")
    b = os.path.basename(rest[0].rstrip("/")) if rest else ""
    if len(rest) > 1 and b.endswith(rest[1]): b = b[:-len(rest[1])]
    sh.out.write(b + "\n")

@builtin("dirname")
def _dirname(sh, a, i): sh.out.write((os.path.dirname(a[0].rstrip("/")) or ".") + "\n")

@builtin("realpath", "readlink")
def _realpath(sh, a, i):
    _, rest = _opts(a, "fme")
    for p in rest: sh.out.write(os.path.realpath(p) + "\n")

def _input_lines(a, i):
    if a:
        text = ""
        for p in a:
            with open(p, encoding="utf-8", errors="replace") as f: text += f.read()
        return text
    return i or ""

@builtin("head", "tail")
def _headtail(sh, a, i, _which=None):
    n, files, k = 10, [], 0
    while k < len(a):
        x = a[k]
        if x == "-n": n = _int(a[k + 1].lstrip("+")); k += 2; continue
        if re.fullmatch(r"-n?\d+", x): n = _int(x.lstrip("-n")); k += 1; continue
        if x.startswith("-"): k += 1; continue
        files.append(x); k += 1
    lines = _input_lines(files, i).splitlines(True)
    sh.out.write("".join(lines[:n] if _which == "head" else lines[-n:] if n else []))

BUILTINS["head"] = lambda sh, a, i: _headtail(sh, a, i, "head")
BUILTINS["tail"] = lambda sh, a, i: _headtail(sh, a, i, "tail")

@builtin("wc")
def _wc(sh, a, i):
    o, rest = _opts(a, "lwc")
    t = _input_lines(rest, i)
    if "l" in o: sh.out.write("%8d\n" % t.count("\n"))
    elif "w" in o: sh.out.write("%8d\n" % len(t.split()))
    elif "c" in o: sh.out.write("%8d\n" % len(t.encode()))
    else: sh.out.write("%8d %8d %8d\n" % (t.count("\n"), len(t.split()), len(t.encode())))

@builtin("grep", "egrep", "fgrep")
def _grep(sh, a, i):
    o, rest = set(), []
    k = 0
    pats = []
    while k < len(a):
        x = a[k]
        if x == "-e": pats.append(a[k + 1]); k += 2; continue
        if x.startswith("-") and len(x) > 1 and not rest and not pats or (x.startswith("-") and len(x) > 1 and not rest):
            o |= set(x[1:]); k += 1; continue
        rest.append(x); k += 1
    if not pats:
        if not rest: return 2
        pats = [rest.pop(0)]
    flags = re.I if "i" in o else 0
    def rx(p):
        if "F" in o: p = re.escape(p)
        elif "E" not in o: p = p.replace(r"\|", "|").replace(r"\(", "(").replace(r"\)", ")").replace(r"\+", "+")
        if "w" in o: p = r"\b(?:%s)\b" % p
        if "x" in o: p = r"^(?:%s)$" % p
        return re.compile(p, flags)
    rxs = [rx(p) for p in pats]
    found = 0
    sources = rest or [None]
    for src in sources:
        text = (i or "") if src is None else open(src, encoding="utf-8", errors="replace").read()
        for line in text.splitlines():
            hit = any(r.search(line) for r in rxs)
            if hit != ("v" in o):
                found += 1
                if "q" not in o and "c" not in o and "l" not in o:
                    if "o" in o and not "v" in o:
                        for r in rxs:
                            for m in r.finditer(line): sh.out.write(m.group(0) + "\n")
                    else:
                        sh.out.write(((src + ":") if len(sources) > 1 and "h" not in o else "") + line + "\n")
        if "l" in o and found and src: sh.out.write(src + "\n")
    if "c" in o: sh.out.write("%d\n" % found)
    return 0 if found else 1

def _sed_expr(expr, text):
    out_lines = []
    m = re.fullmatch(r"s(.)(.*?)(?<!\\)\1(.*?)(?<!\\)\1([gI0-9]*)", expr, re.S)
    if m:
        d = m.group(1)
        pat = m.group(2).replace("\\" + d, d)
        rep = m.group(3).replace("\\" + d, d)
        rep = re.sub(r"\\(\d)", r"\\\1", rep).replace("&", r"\g<0>")
        pat = pat.replace(r"\(", "(").replace(r"\)", ")").replace(r"\{", "{").replace(r"\}", "}").replace(r"\+", "+").replace(r"\?", "?").replace(r"\|", "|")
        cnt = 0 if "g" in m.group(4) else 1
        fl = re.I if "I" in m.group(4) else 0
        return "".join(re.sub(pat, rep, line, count=cnt, flags=fl) for line in text.splitlines(True))
    m = re.fullmatch(r"/(.*)/d", expr)
    if m:
        return "".join(l for l in text.splitlines(True) if not re.search(m.group(1), l))
    raise Exception("this sed command is not supported: " + expr)

@builtin("sed")
def _sed(sh, a, i):
    inplace, exprs, files, k = False, [], [], 0
    while k < len(a):
        x = a[k]
        if x.startswith("-i"):
            inplace = True
            if x == "-i" and k + 1 < len(a) and a[k + 1] in ("", ".bak", ".orig"): k += 1
            k += 1; continue
        if x in ("-e",): exprs.append(a[k + 1]); k += 2; continue
        if x in ("-E", "-r", "-n"): k += 1; continue
        if not exprs and not files: exprs.append(x)
        else: files.append(x)
        k += 1
    def apply(t):
        for e in exprs:
            for part in re.split(r";\s*(?=s.|/)", e):
                t = _sed_expr(part.strip(), t)
        return t
    if inplace:
        for p in files:
            with open(p, encoding="utf-8", errors="replace") as f: t = f.read()
            with open(p, "w", encoding="utf-8") as f: f.write(apply(t))
    else:
        sh.out.write(apply(_input_lines(files, i)))

@builtin("tr")
def _tr(sh, a, i):
    o, rest = _opts(a, "dsc")
    t = i or ""
    def cls(s):
        s = s.replace("[:upper:]", "A-Z").replace("[:lower:]", "a-z").replace("[:space:]", " \t\n").replace("[:digit:]", "0-9")
        out, k = "", 0
        while k < len(s):
            if k + 2 < len(s) and s[k + 1] == "-":
                out += "".join(chr(c) for c in range(ord(s[k]), ord(s[k + 2]) + 1)); k += 3
            else:
                out += s[k]; k += 1
        return out.encode().decode("unicode_escape")
    if "d" in o:
        sset = set(cls(rest[0])); sh.out.write("".join(c for c in t if c not in sset)); return
    x, y = cls(rest[0]), cls(rest[1]) if len(rest) > 1 else ""
    if y:
        y = (y + y[-1] * len(x))[:len(x)]
        t = t.translate(str.maketrans(x, y))
    sh.out.write(t)

@builtin("sort")
def _sort(sh, a, i):
    o, rest = _opts(a, "rnuf")
    lines = _input_lines(rest, i).splitlines()
    key = (lambda s: _int(s.split()[0]) if s.split() else 0) if "n" in o else (str.lower if "f" in o else None)
    lines = sorted(lines, key=key, reverse="r" in o)
    if "u" in o: lines = list(dict.fromkeys(lines))
    sh.out.write("".join(l + "\n" for l in lines))

@builtin("uniq")
def _uniq(sh, a, i):
    lines, out = _input_lines([], i).splitlines(), []
    for l in lines:
        if not out or out[-1] != l: out.append(l)
    sh.out.write("".join(l + "\n" for l in out))

@builtin("find")
def _find(sh, a, i):
    roots = []
    k = 0
    while k < len(a) and not a[k].startswith("-") and a[k] not in ("!", "("):
        roots.append(a[k]); k += 1
    roots = roots or ["."]
    conds, maxdepth, action, exec_cmd = [], None, "print", None
    neg = False
    while k < len(a):
        x = a[k]
        if x == "!": neg = True; k += 1; continue
        if x in ("-name", "-iname", "-path"):
            conds.append((x, a[k + 1], neg)); neg = False; k += 2; continue
        if x == "-type": conds.append((x, a[k + 1], neg)); neg = False; k += 2; continue
        if x == "-maxdepth": maxdepth = _int(a[k + 1]); k += 2; continue
        if x == "-mindepth": k += 2; continue
        if x == "-delete": action = "delete"; k += 1; continue
        if x == "-print" or x == "-print0": k += 1; continue
        if x == "-exec":
            j = k + 1
            while j < len(a) and a[j] not in (";", "+"): j += 1
            exec_cmd = a[k + 1:j]; action = "exec"; k = j + 1; continue
        k += 1
    def ok(path, isdir):
        for c, v, n in conds:
            r = True
            if c == "-name": r = fnmatch.fnmatchcase(os.path.basename(path), v)
            elif c == "-iname": r = fnmatch.fnmatch(os.path.basename(path).lower(), v.lower())
            elif c == "-path": r = fnmatch.fnmatchcase(path, v)
            elif c == "-type": r = (v == "d") == isdir
            if r == n: return False
        return True
    found = []
    for root in roots:
        if not os.path.exists(root):
            sh.err.write("find: %s: No such file or directory\n" % root); continue
        base_depth = root.rstrip("/").count("/")
        if ok(root, os.path.isdir(root)): found.append(root)
        for dirpath, dirs, files in os.walk(root):
            depth = dirpath.rstrip("/").count("/") - base_depth + 1
            if maxdepth is not None and depth > maxdepth:
                dirs[:] = []; continue
            for d in sorted(dirs):
                p = os.path.join(dirpath, d)
                if ok(p, True): found.append(p)
            for f in sorted(files):
                p = os.path.join(dirpath, f)
                if ok(p, False): found.append(p)
            if maxdepth is not None and depth >= maxdepth:
                dirs[:] = []
    for p in found:
        if action == "delete":
            if os.path.isdir(p) and not os.path.islink(p): shutil.rmtree(p, ignore_errors=True)
            elif os.path.lexists(p): os.remove(p)
        elif action == "exec":
            sh.call([p if w == "{}" else w for w in exec_cmd], None)
        else:
            sh.out.write(p + "\n")

@builtin("xargs")
def _xargs(sh, a, i):
    o, rest = _opts(a, "0rt")
    items = (i or "").split("\0" if "0" in o else None)
    items = [x for x in items if x]
    if not items and "r" in o: return 0
    if "I" in "".join(a):
        pass
    return sh.call((rest or ["echo"]) + items, None)

@builtin("env")
def _env(sh, a, i):
    k = 0
    temp = {}
    while k < len(a) and "=" in a[k]:
        n, _, v = a[k].partition("="); temp[n] = v; k += 1
    if k >= len(a):
        for n, v in sorted(os.environ.items()): sh.out.write("%s=%s\n" % (n, v))
        return 0
    saved = dict(os.environ); os.environ.update(temp)
    try: return sh.call(a[k:], i)
    finally: os.environ.clear(); os.environ.update(saved)

@builtin("sleep")
def _sleep(sh, a, i):
    time.sleep(min(float(a[0].rstrip("s")) if a else 0, 5))

@builtin("date")
def _date(sh, a, i):
    fmt = next((x[1:] for x in a if x.startswith("+")), "%a %b %d %H:%M:%S %Z %Y")
    sh.out.write(time.strftime(fmt, time.gmtime() if "-u" in a else time.localtime()) + "\n")

@builtin("seq")
def _seq(sh, a, i):
    nums = [_int(x) for x in a]
    lo, step, hi = (1, 1, nums[0]) if len(nums) == 1 else (nums[0], 1, nums[1]) if len(nums) == 2 else (nums[0], nums[1], nums[2])
    for v in range(lo, hi + (1 if step > 0 else -1), step): sh.out.write("%d\n" % v)

@builtin("yes")
def _yes(sh, a, i): sh.out.write(((" ".join(a) or "y") + "\n") * 100)

@builtin("mktemp")
def _mktemp(sh, a, i):
    import tempfile
    o, rest = _opts(a, "dtq")
    if "d" in o: p = tempfile.mkdtemp()
    else:
        fd, p = tempfile.mkstemp(); os.close(fd)
    sh.out.write(p + "\n")

@builtin("read")
def _read(sh, a, i):
    _, names = _opts(a, "rsp")
    line = (i or "").split("\n", 1)[0]
    if not line and not i: return 1
    parts = line.split(None, max(len(names) - 1, 0)) if names else []
    for k, n in enumerate(names or ["REPLY"]):
        sh.setvar(n, parts[k] if k < len(parts) else (line if not names else ""))
    return 0

@builtin("python3", "python")
def _python(sh, a, i):
    import ioxc_run
    sys.stdout.flush()
    saved = (sys.stdout, sys.stderr, sys.stdin)
    sys.stdout, sys.stderr = sh.out, sh.err
    sys.stdin = io.StringIO(i or "")
    try:
        return ioxc_run.python_main(a, sh.err)
    finally:
        sys.stdout, sys.stderr, sys.stdin = saved

@builtin("pip", "pip3")
def _pip(sh, a, i):
    sh.err.write("note: pip is not needed on iPhone; Pillow and PyYAML are built in. Skipping: pip %s\n" % " ".join(a))
    return 0

@builtin("curl", "wget")
def _curl(sh, a, i):
    import urllib.request
    out_path, url, k, fail = None, None, 0, False
    wget = sh_is_wget = False
    while k < len(a):
        x = a[k]
        if x in ("-o", "-O", "--output") and k + 1 < len(a) and not (x == "-O" and a[k + 1].startswith("http")):
            out_path = a[k + 1]; k += 2; continue
        if x == "-O": out_path = ""; k += 1; continue
        if x in ("-H", "--header", "-d", "--data", "-X", "-u", "-A", "--retry", "--connect-timeout", "-m"): k += 2; continue
        if x.startswith("-"):
            if "f" in x and not x.startswith("--"): fail = True
            k += 1; continue
        url = x; k += 1
    if not url: raise Exception("no URL given")
    req = urllib.request.Request(url, headers={"User-Agent": "iOXcode"})
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            data = r.read()
    except Exception as e:
        sh.err.write("download failed: %s (%s)\n" % (url, e)); return 22
    if out_path == "":
        out_path = os.path.basename(url.split("?")[0]) or "download"
    if out_path:
        with open(out_path, "wb") as f: f.write(data)
    else:
        sh.out.write(data.decode("utf-8", "replace"))

@builtin("unzip")
def _unzip(sh, a, i):
    import zipfile
    dest, files, k = ".", [], 0
    while k < len(a):
        if a[k] == "-d": dest = a[k + 1]; k += 2; continue
        if a[k].startswith("-"): k += 1; continue
        files.append(a[k]); k += 1
    with zipfile.ZipFile(files[0]) as z:
        z.extractall(dest)

@builtin("zip")
def _zip(sh, a, i):
    import zipfile
    o, rest = _opts(a, "rqyX9")
    target = rest[0] if rest[0].endswith(".zip") else rest[0] + ".zip"
    with zipfile.ZipFile(target, "a", zipfile.ZIP_DEFLATED) as z:
        for p in rest[1:]:
            if os.path.isdir(p):
                for dp, _, fs in os.walk(p):
                    for f in fs: z.write(os.path.join(dp, f))
            else:
                z.write(p)

@builtin("tar")
def _tar(sh, a, i):
    import tarfile
    flags, rest, k, dest, archive = "", [], 0, ".", None
    while k < len(a):
        x = a[k]
        if x == "-C": dest = a[k + 1]; k += 2; continue
        if x == "-f" or x == "--file": archive = a[k + 1]; k += 2; continue
        if x.startswith("-") or (k == 0 and re.fullmatch(r"[a-zA-Z]+", x)):
            flags += x.lstrip("-")
            if flags.endswith("f") and archive is None and k + 1 < len(a):
                archive = a[k + 1]; k += 2; continue
            k += 1; continue
        rest.append(x); k += 1
    if "x" in flags:
        with tarfile.open(archive) as t: t.extractall(dest)
    elif "c" in flags:
        mode = "w:gz" if "z" in flags else "w:bz2" if "j" in flags else "w"
        with tarfile.open(archive, mode) as t:
            for p in rest: t.add(os.path.join(dest, p) if dest != "." else p, arcname=p)
    elif "t" in flags:
        with tarfile.open(archive) as t:
            for n in t.getnames(): sh.out.write(n + "\n")

@builtin("shasum", "sha256sum", "md5", "md5sum")
def _shasum(sh, a, i):
    import hashlib
    algo = "sha256" if ("256" in "".join(a) or True) else "sha1"
    _, rest = _opts([x for x in a if x not in ("-a", "256", "1")], "")
    for p in rest:
        with open(p, "rb") as f: sh.out.write("%s  %s\n" % (hashlib.new(algo, f.read()).hexdigest(), p))

@builtin("xcodegen")
def _xcodegen(sh, a, i):
    sh.err.write("note: xcodegen: iOXcode reads project.yml directly; skipping\n")
    return 0

@builtin("uname")
def _uname(sh, a, i):
    sh.out.write("Darwin\n" if not a or "-s" in a else "arm64\n" if "-m" in a else "Darwin\n")

@builtin("id", "whoami")
def _whoami(sh, a, i): sh.out.write("mobile\n")

@builtin("nproc")
def _nproc(sh, a, i): sh.out.write("%d\n" % (os.cpu_count() or 1))

@builtin("sysctl")
def _sysctl(sh, a, i): sh.out.write("%d\n" % (os.cpu_count() or 1))


# ---------------------------------------------------------------- entry

def run_script(text, args, out, err=None):
    """Runs a script. Returns the exit code."""
    sh = Shell(out, err)
    sh.positional = list(args)
    try:
        return sh.run_source(text)
    except ShellExit as e:
        return e.code
    except ShellSyntaxError as e:
        out.write("ioxsh: syntax error: %s\n" % e)
        return 2
