"""More of the command-line tools a Mac runner has, for build scripts: plutil, PlistBuddy, defaults, xcrun (the SDK
questions), sw_vers, cut, tee, awk (the common one-liners), diff, stat, du, base64, printenv.
They register themselves into ioxsh's table of built-in commands."""
import base64 as _b64, difflib, os, plistlib, re, shlex, sys, time


def _read_plist(path):
    with open(path, "rb") as f:
        raw = f.read()
    return plistlib.loads(raw)


def _write_plist(path, obj, fmt="xml1"):
    kind = plistlib.FMT_BINARY if fmt == "binary1" else plistlib.FMT_XML
    with open(path, "wb") as f:
        plistlib.dump(obj, f, fmt=kind, sort_keys=False)


# ------------------------------------------------------------------ plist values

def _fmt_p(v, ind=0):
    """plutil -p / PlistBuddy Print style."""
    pad = "    " * ind
    if isinstance(v, dict):
        if not v:
            return "Dict {\n" + pad + "}"
        return "Dict {\n" + "".join("%s    %s = %s\n" % (pad, k, _fmt_p(x, ind + 1)) for k, x in v.items()) + pad + "}"
    if isinstance(v, list):
        if not v:
            return "Array {\n" + pad + "}"
        return "Array {\n" + "".join("%s    %s\n" % (pad, _fmt_p(x, ind + 1)) for x in v) + pad + "}"
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, bytes):
        return "<%d bytes>" % len(v)
    return str(v)


def _plutil_p(v, ind=0):
    pad = "  " * ind
    if isinstance(v, dict):
        if not v:
            return "{}"
        return "{\n" + "".join('%s  "%s" => %s\n' % (pad, k, _plutil_p(x, ind + 1)) for k, x in v.items()) + pad + "}"
    if isinstance(v, list):
        if not v:
            return "[]"
        return "[\n" + "".join("%s  %d => %s\n" % (pad, n, _plutil_p(x, ind + 1)) for n, x in enumerate(v)) + pad + "]"
    if isinstance(v, bool):
        return "1" if v else "0"
    if isinstance(v, str):
        return '"%s"' % v
    if isinstance(v, bytes):
        return "{length = %d}" % len(v)
    return str(v)


def _path_parts(keypath):
    return [p for p in re.split(r"[.]", keypath) if p != ""]


def _walk(obj, parts):
    for p in parts:
        if isinstance(obj, list):
            obj = obj[int(p)]
        else:
            obj = obj[p]
    return obj


def _json_ready(v):
    if isinstance(v, bytes):
        return _b64.b64encode(v).decode()
    if isinstance(v, dict):
        return {k: _json_ready(x) for k, x in v.items()}
    if isinstance(v, list):
        return [_json_ready(x) for x in v]
    if hasattr(v, "isoformat"):
        return v.isoformat()
    return v


def _typed(kind, text):
    if kind in ("-string", "string"):
        return text
    if kind in ("-integer", "integer"):
        return int(text)
    if kind in ("-float", "real", "-real"):
        return float(text)
    if kind in ("-bool", "bool"):
        return text.lower() in ("yes", "true", "1")
    if kind in ("-date", "date"):
        import datetime
        return datetime.datetime.fromisoformat(text.replace("Z", "+00:00"))
    if kind in ("-array", "array"):
        return []
    if kind in ("-dictionary", "dict"):
        return {}
    return text


def _set_path(root, parts, value, insert=False, replace=True):
    obj = _walk(root, parts[:-1]) if len(parts) > 1 else root
    last = parts[-1]
    if isinstance(obj, list):
        if last == "-1" or (insert and int(last) >= len(obj)):
            obj.append(value)
        elif insert:
            obj.insert(int(last), value)
        else:
            obj[int(last)] = value
    else:
        if insert and last in obj:
            raise KeyError("Value already exists at key path")
        obj[last] = value


def plutil(sh, a, i):
    if not a:
        sh.err.write("usage: plutil [-p|-convert fmt|-replace|-insert|-remove|-extract|-type|-lint] ...\n")
        return 1
    cmd = a[0]
    if cmd in ("-help", "-h"):
        return 0
    rest = a[1:]
    if cmd == "-lint":
        rc = 0
        for p in [x for x in rest if not x.startswith("-")]:
            try:
                _read_plist(p)
                sh.out.write("%s: OK\n" % p)
            except Exception as e:
                sh.out.write("%s: %s\n" % (p, e)); rc = 1
        return rc
    if cmd == "-p":
        for p in rest:
            sh.out.write(_plutil_p(_read_plist(p)) + "\n")
        return 0
    if cmd == "-convert":
        fmt = rest[0]
        out = None
        files = []
        k = 1
        while k < len(rest):
            if rest[k] == "-o":
                out = rest[k + 1]; k += 2; continue
            if rest[k] in ("-e",):
                k += 2; continue
            if rest[k] == "-r" or rest[k] == "-s":
                k += 1; continue
            files.append(rest[k]); k += 1
        for p in files:
            data = _read_plist(p) if p != "-" else plistlib.loads((i or "").encode())
            dst = out if out is not None else p
            if fmt == "json":
                import json
                text = json.dumps(_json_ready(data), indent=2, sort_keys=True)
                if dst == "-":
                    sh.out.write(text + "\n")
                else:
                    open(dst, "w").write(text + "\n")
            elif dst == "-":
                sh.out.write(plistlib.dumps(data).decode())
            else:
                _write_plist(dst, data, "binary1" if fmt == "binary1" else "xml1")
        return 0
    if cmd in ("-replace", "-insert"):
        key, kind, val, files = rest[0], rest[1], None, None
        if kind in ("-array", "-dictionary"):
            files = rest[2:]; val = _typed(kind, "")
        elif kind in ("-xml", "-json"):
            val = plistlib.loads(rest[2].encode()) if kind == "-xml" else __import__("json").loads(rest[2]); files = rest[3:]
        else:
            val = _typed(kind, rest[2]); files = rest[3:]
        for p in [f for f in files if not f.startswith("-")]:
            data = _read_plist(p)
            try:
                _set_path(data, _path_parts(key), val, insert=(cmd == "-insert"))
            except Exception as e:
                sh.err.write("%s: %s\n" % (p, e)); return 1
            _write_plist(p, data)
        return 0
    if cmd == "-remove":
        key = rest[0]
        for p in rest[1:]:
            data = _read_plist(p)
            parts = _path_parts(key)
            try:
                obj = _walk(data, parts[:-1]) if len(parts) > 1 else data
                if isinstance(obj, list):
                    del obj[int(parts[-1])]
                else:
                    del obj[parts[-1]]
            except Exception:
                sh.err.write("Could not remove value at key path %s\n" % key); return 1
            _write_plist(p, data)
        return 0
    if cmd in ("-extract", "-type"):
        key = rest[0]
        if cmd == "-type":
            p = rest[1]
            try:
                v = _walk(_read_plist(p), _path_parts(key))
            except Exception:
                sh.err.write("Could not extract value, error: No value at that key path or invalid key path: %s\n" % key); return 1
            kinds = {str: "string", bool: "bool", int: "integer", float: "float", list: "array", dict: "dictionary", bytes: "data"}
            sh.out.write(kinds.get(type(v), "date") + "\n")
            return 0
        fmt = rest[1]
        k = 2
        out, raw, files = None, False, []
        while k < len(rest):
            if rest[k] == "-o":
                out = rest[k + 1]; k += 2; continue
            if rest[k] == "-expect":
                k += 2; continue
            if rest[k] == "-r":
                raw = True; k += 1; continue
            files.append(rest[k]); k += 1
        for p in files:
            data = _read_plist(p) if p != "-" else plistlib.loads((i or "").encode())
            try:
                v = _walk(data, _path_parts(key)) if key != "" else data
            except Exception:
                sh.err.write("Could not extract value, error: No value at that key path or invalid key path: %s\n" % key); return 1
            if fmt == "raw":
                if isinstance(v, bool):
                    text = "true" if v else "false"
                elif isinstance(v, (dict, list)):
                    text = str(len(v))
                else:
                    text = str(v)
                text += "\n"
            elif fmt == "json":
                import json
                text = json.dumps(_json_ready(v), indent=2, sort_keys=True) + "\n"
            else:
                text = plistlib.dumps(v if isinstance(v, (dict, list)) else [v] if False else v, fmt=plistlib.FMT_XML).decode() if isinstance(v, (dict, list)) else str(v) + "\n"
            if out and out != "-":
                open(out, "w").write(text)
            else:
                sh.out.write(text)
        return 0
    sh.err.write("plutil: unrecognized option %s\n" % cmd)
    return 1


# ------------------------------------------------------------------ PlistBuddy

def _pb_value(kind, text):
    kind = kind.lower()
    if kind == "string":
        return text
    if kind in ("integer", "int"):
        return int(text)
    if kind == "real":
        return float(text)
    if kind == "bool":
        return text.lower() in ("true", "yes", "1")
    if kind == "array":
        return []
    if kind in ("dict", "dictionary"):
        return {}
    if kind == "data":
        return text.encode()
    return text


def plistbuddy(sh, a, i):
    cmds, xml, files, k = [], False, [], 0
    while k < len(a):
        x = a[k]
        if x == "-c":
            cmds.append(a[k + 1]); k += 2; continue
        if x == "-x":
            xml = True; k += 1; continue
        if x in ("-c", "-h", "-d", "-l"):
            k += 1; continue
        files.append(x); k += 1
    if not files:
        sh.err.write("Usage: PlistBuddy [-c \"command\"] file.plist\n"); return 1
    path = files[0]
    exists = os.path.exists(path)
    data = _read_plist(path) if exists else {}
    dirty = False
    for c in cmds:
        parts = shlex.split(c)
        if not parts:
            continue
        op = parts[0].lower()
        key = parts[1].lstrip(":") if len(parts) > 1 else ""
        kp = [p for p in key.split(":") if p != ""]
        try:
            if op == "print":
                v = _walk(data, kp)
                sh.out.write((plistlib.dumps(v).decode() if xml and isinstance(v, (dict, list)) else
                              _fmt_p(v)) + "\n")
            elif op == "set":
                _walk(data, kp)   # must exist
                tgt = _walk(data, kp[:-1]) if len(kp) > 1 else data
                old = _walk(data, kp)
                text = " ".join(parts[2:])
                val = text if isinstance(old, str) else int(text) if isinstance(old, int) and not isinstance(old, bool) else \
                    float(text) if isinstance(old, float) else text.lower() in ("true", "yes", "1") if isinstance(old, bool) else text
                if isinstance(tgt, list):
                    tgt[int(kp[-1])] = val
                else:
                    tgt[kp[-1]] = val
                dirty = True
            elif op == "add":
                kind = parts[2]
                val = _pb_value(kind, " ".join(parts[3:]))
                tgt = _walk(data, kp[:-1]) if len(kp) > 1 else data
                if isinstance(tgt, list):
                    idx = kp[-1]
                    if idx.isdigit():
                        tgt.insert(int(idx), val)
                    else:
                        tgt.append(val)
                else:
                    if kp[-1] in tgt:
                        sh.err.write("Add: \"%s\" Entry Already Exists\n" % key); return 1
                    tgt[kp[-1]] = val
                dirty = True
            elif op == "delete":
                if not kp:
                    data.clear()
                else:
                    tgt = _walk(data, kp[:-1]) if len(kp) > 1 else data
                    if isinstance(tgt, list):
                        del tgt[int(kp[-1])]
                    else:
                        del tgt[kp[-1]]
                dirty = True
            elif op == "clear":
                kind = parts[1] if len(parts) > 1 else "dict"
                data.clear() if not kp else None
                dirty = True
            elif op == "merge":
                other = _read_plist(parts[1])
                tgt = _walk(data, [p for p in (parts[2].lstrip(":").split(":") if len(parts) > 2 else []) if p])
                for kk, vv in other.items():
                    tgt.setdefault(kk, vv)
                dirty = True
            elif op == "copy":
                src = _walk(data, [p for p in parts[1].lstrip(":").split(":") if p])
                dst = [p for p in parts[2].lstrip(":").split(":") if p]
                tgt = _walk(data, dst[:-1]) if len(dst) > 1 else data
                tgt[dst[-1]] = src
                dirty = True
            elif op in ("save", "exit"):
                pass
            else:
                sh.err.write("Unrecognized Command\n"); return 1
        except (KeyError, IndexError, ValueError):
            sh.err.write("%s: Entry, \":%s\", Does Not Exist\n" % (op.capitalize(), key)); return 1
    if dirty:
        _write_plist(path, data)
    return 0


def defaults(sh, a, i):
    """defaults read/write/delete on a plist file path (the only kind that makes sense here)."""
    if len(a) < 2:
        return 1
    op, target = a[0], a[1]
    path = target if target.endswith(".plist") else target + ".plist"
    if op == "read":
        data = _read_plist(path) if os.path.exists(path) else {}
        if len(a) > 2:
            if a[2] not in data:
                sh.err.write("The domain/default pair of (%s, %s) does not exist\n" % (target, a[2])); return 1
            sh.out.write(str(data[a[2]]) + "\n")
        else:
            sh.out.write(_fmt_p(data) + "\n")
        return 0
    if op == "write" and len(a) >= 4:
        data = _read_plist(path) if os.path.exists(path) else {}
        key, val = a[2], a[-1]
        kind = a[3] if len(a) > 4 else "-string"
        data[key] = _typed(kind, val)
        _write_plist(path, data)
        return 0
    if op == "delete" and len(a) > 2:
        data = _read_plist(path) if os.path.exists(path) else {}
        data.pop(a[2], None)
        _write_plist(path, data)
        return 0
    return 1


# ------------------------------------------------------------------ xcrun, sw_vers

def _sdk_path():
    root = os.environ.get("SDKROOT")
    if root:
        return root
    try:
        import glob
        base = os.environ.get("IOX_SDK_ROOT") or ""
        hits = sorted(glob.glob(os.path.join(base, "**", "iPhoneOS*.sdk"), recursive=True)) if base else []
        return hits[-1] if hits else ""
    except Exception:
        return ""


def xcrun(sh, a, i):
    sdk_show = {"--show-sdk-path": lambda: _sdk_path(),
                "--show-sdk-version": lambda: re.sub(r"^iPhoneOS|\.sdk$", "", os.path.basename(_sdk_path())) or "27.1",
                "--show-sdk-platform-path": lambda: "", "--show-toolchain-path": lambda: ""}
    k = 0
    while k < len(a):
        x = a[k]
        if x in ("--sdk", "-sdk", "--toolchain", "-toolchain"):
            k += 2; continue
        if x in sdk_show:
            sh.out.write(sdk_show[x]() + "\n"); return 0
        if x in ("--find", "-f"):
            sh.out.write("/usr/bin/%s\n" % (a[k + 1] if k + 1 < len(a) else "")); return 0
        if x.startswith("-"):
            k += 1; continue
        break
    rest = a[k:]
    if not rest:
        return 1
    if rest[0] in ("simctl", "xctrace", "notarytool", "stapler", "altool", "swift-package"):
        sh.err.write("note: xcrun %s is not available on iPhone\n" % rest[0]); return 0
    return sh.call(rest, i)         # xcrun <tool> ...: run the tool if we have it


def sw_vers(sh, a, i):
    ver = "15.5"
    if "-productName" in a or "--productName" in a:
        sh.out.write("macOS\n")
    elif "-productVersion" in a or "--productVersion" in a:
        sh.out.write(ver + "\n")
    elif "-buildVersion" in a or "--buildVersion" in a:
        sh.out.write("24F74\n")
    else:
        sh.out.write("ProductName:\t\tmacOS\nProductVersion:\t\t%s\nBuildVersion:\t\t24F74\n" % ver)
    return 0


# ------------------------------------------------------------------ text tools

def _text_of(a, i):
    if a:
        out = ""
        for p in a:
            out += open(p, encoding="utf-8", errors="replace").read()
        return out
    return i or ""


def cut(sh, a, i):
    delim, fields, chars, files, only, k = "\t", None, None, [], False, 0
    while k < len(a):
        x = a[k]
        if x == "-d":
            delim = a[k + 1]; k += 2; continue
        if x.startswith("-d") and len(x) > 2:
            delim = x[2:]; k += 1; continue
        if x == "-f":
            fields = a[k + 1]; k += 2; continue
        if x.startswith("-f"):
            fields = x[2:]; k += 1; continue
        if x in ("-c", "-b"):
            chars = a[k + 1]; k += 2; continue
        if x.startswith("-c") or x.startswith("-b"):
            chars = x[2:]; k += 1; continue
        if x == "-s":
            only = True; k += 1; continue
        files.append(x); k += 1

    def picks(spec, n):
        out = []
        for part in spec.split(","):
            if "-" in part:
                lo, hi = part.split("-", 1)
                lo = int(lo) if lo else 1
                hi = int(hi) if hi else n
                out += list(range(lo, min(hi, n) + 1))
            elif part:
                out.append(int(part))
        return out
    for line in _text_of(files, i).splitlines():
        if fields is not None:
            if delim not in line:
                if not only:
                    sh.out.write(line + "\n")
                continue
            cols = line.split(delim)
            sh.out.write(delim.join(cols[n - 1] for n in picks(fields, len(cols)) if n - 1 < len(cols)) + "\n")
        elif chars is not None:
            sh.out.write("".join(line[n - 1] for n in picks(chars, len(line)) if n - 1 < len(line)) + "\n")
    return 0


def tee(sh, a, i):
    append = "-a" in a
    text = i or ""
    for p in [x for x in a if not x.startswith("-")]:
        with open(p, "a" if append else "w", encoding="utf-8") as f:
            f.write(text)
    sh.out.write(text)
    return 0


def diff(sh, a, i):
    unified = any(x.startswith("-u") or x == "-U" for x in a)
    quiet = "-q" in a or "--brief" in a
    files = [x for x in a if not x.startswith("-")]
    if len(files) != 2:
        sh.err.write("usage: diff [-u] [-q] file1 file2\n"); return 2
    try:
        x = open(files[0], encoding="utf-8", errors="replace").read().splitlines(True)
        y = open(files[1], encoding="utf-8", errors="replace").read().splitlines(True)
    except OSError as e:
        sh.err.write("diff: %s\n" % e); return 2
    if x == y:
        return 0
    if quiet:
        sh.out.write("Files %s and %s differ\n" % tuple(files)); return 1
    gen = difflib.unified_diff(x, y, files[0], files[1]) if unified else difflib.ndiff(x, y)
    for line in gen:
        sh.out.write(line if line.endswith("\n") else line + "\n")
    return 1


def stat(sh, a, i):
    fmt, files, k = None, [], 0
    while k < len(a):
        if a[k] in ("-f", "-c"):
            fmt = a[k + 1]; k += 2; continue
        if a[k].startswith("-"):
            k += 1; continue
        files.append(a[k]); k += 1
    rc = 0
    for p in files:
        try:
            st = os.stat(p)
        except OSError:
            sh.err.write("stat: %s: stat: No such file or directory\n" % p); rc = 1; continue
        if fmt:
            out = (fmt.replace("%z", str(st.st_size)).replace("%s", str(st.st_size)).replace("%m", str(int(st.st_mtime)))
                   .replace("%Y", str(int(st.st_mtime))).replace("%N", p).replace("%n", p).replace("%Sp", oct(st.st_mode)[-3:]).replace("%a", oct(st.st_mode)[-3:]))
            sh.out.write(out + "\n")
        else:
            sh.out.write("%s: %d bytes, modified %s\n" % (p, st.st_size, time.ctime(st.st_mtime)))
    return rc


def du(sh, a, i):
    human = any(x.startswith("-") and "h" in x for x in a)
    summary = any(x.startswith("-") and "s" in x for x in a)
    for p in [x for x in a if not x.startswith("-")] or ["."]:
        total = 0
        if os.path.isdir(p):
            for dp, dn, fn in os.walk(p):
                for f in fn:
                    try:
                        total += os.lstat(os.path.join(dp, f)).st_size
                    except OSError:
                        pass
        else:
            total = os.path.getsize(p)
        if human:
            n, unit = float(total), "B"
            for unit in ("B", "K", "M", "G", "T"):
                if n < 1024 or unit == "T":
                    break
                n /= 1024
            sh.out.write("%s\t%s\n" % (("%d%s" % (n, unit)) if unit == "B" else ("%.1f%s" % (n, unit)), p))
        else:
            sh.out.write("%d\t%s\n" % ((total + 511) // 512, p))
    return 0


def base64(sh, a, i):
    dec = "-D" in a or "-d" in a or "--decode" in a
    files = [x for x in a if not x.startswith("-")]
    if files:
        raw = open(files[0], "rb").read()
    else:
        raw = (i or "").encode()
    if dec:
        sh.out.write(_b64.b64decode(raw).decode("utf-8", "replace"))
    else:
        sh.out.write(_b64.b64encode(raw).decode() + "\n")
    return 0


def printenv(sh, a, i):
    if a:
        v = os.environ.get(a[0])
        if v is None:
            return 1
        sh.out.write(v + "\n")
        return 0
    for k, v in sorted(os.environ.items()):
        sh.out.write("%s=%s\n" % (k, v))
    return 0


# ------------------------------------------------------------------ awk (the one-liners people write in build scripts)

def awk(sh, a, i):
    sep, assigns, prog, files, k = None, {}, None, [], 0
    while k < len(a):
        x = a[k]
        if x == "-F":
            sep = a[k + 1]; k += 2; continue
        if x.startswith("-F") and len(x) > 2:
            sep = x[2:]; k += 1; continue
        if x == "-v":
            n, _, v = a[k + 1].partition("="); assigns[n] = v; k += 2; continue
        if x == "-f":
            prog = open(a[k + 1]).read(); k += 2; continue
        if x.startswith("-") and len(x) > 1 and prog is None:
            k += 1; continue
        if prog is None:
            prog = x
        else:
            files.append(x)
        k += 1
    if prog is None:
        return 2
    if sep is not None:
        sep = {"\\t": "\t"}.get(sep, sep)
    items = _awk_parse(prog)
    st = {"NR": 0, "NF": 0, "F": [""], "vars": dict(assigns)}

    def num(v):
        try:
            f = float(v)
            return int(f) if f == int(f) else f
        except (TypeError, ValueError):
            m = re.match(r"\s*[-+]?\d+(\.\d+)?", str(v))
            return float(m.group(0)) if m and "." in m.group(0) else int(m.group(0)) if m else 0

    def show(v):
        if isinstance(v, float):
            return ("%d" % v) if v == int(v) else ("%.6g" % v)
        return str(v)

    def field(n):
        n = int(num(n))
        return st["F"][n] if 0 <= n < len(st["F"]) else ""

    def split_expr(s):
        out, depth, cur, q = [], 0, "", None
        for ch in s:
            if q:
                cur += ch
                if ch == q:
                    q = None
                continue
            if ch in "\"'":
                q = ch
            if ch in "([":
                depth += 1
            elif ch in ")]":
                depth -= 1
            if ch == "," and depth == 0:
                out.append(cur.strip()); cur = ""
            else:
                cur += ch
        if cur.strip():
            out.append(cur.strip())
        return out

    def ev(expr):
        e = expr.strip()
        if not e:
            return ""
        # string and regex literals out of the way
        lits = []

        def keep(m):
            lits.append(m.group(0))
            return "\0%d\0" % (len(lits) - 1)
        e = re.sub(r'"(?:[^"\\]|\\.)*"', keep, e)
        e = re.sub(r"\$\s*NF\b", "FIELD(NF)", e)
        e = re.sub(r"\$\s*\(([^)]*)\)", r"FIELD(\1)", e)
        e = re.sub(r"\$\s*(\d+|[A-Za-z_]\w*)", r"FIELD(\1)", e)
        e = e.replace("&&", " and ").replace("||", " or ")
        e = re.sub(r"!(?!=)", " not ", e)
        e = re.sub(r"\bNR\b", "NRV", e)
        e = re.sub(r"\bNF\b", "NFV", e)
        e = re.sub(r"(\bFIELD\([^)]*\)|\bNRV|\bNFV|\0\d+\0|\b\w+)\s*~\s*(/(?:[^/\\]|\\.)*/|\0\d+\0)", lambda m: "MATCH(%s, %s)" % (m.group(1), m.group(2)), e)
        e = re.sub(r"/((?:[^/\\]|\\.)*)/", lambda m: "MATCH(FIELD(0), r%r)" % m.group(1), e)

        def back(m):
            return lits[int(m.group(1))]
        e = re.sub(r"\0(\d+)\0", back, e)
        env = {"FIELD": lambda n: (lambda v: num(v) if re.fullmatch(r"\s*-?\d+(\.\d+)?\s*", v or "") else v)(field(n)),
               "NRV": st["NR"], "NFV": st["NF"], "NF": st["NF"],
               "MATCH": lambda s, r: re.search(r, str(s)) is not None,
               "length": lambda s=None: len(str(field(0) if s is None else s)),
               "substr": lambda s, b, n=None: str(s)[int(b) - 1:(int(b) - 1 + int(n)) if n is not None else None],
               "toupper": lambda s: str(s).upper(), "tolower": lambda s: str(s).lower(),
               "int": lambda v: int(num(v)), "index": lambda s, t: str(s).find(str(t)) + 1}
        env.update(st["vars"])
        try:
            return eval(e, {"__builtins__": {}}, env)
        except Exception:
            # juxtaposition means concatenation in awk
            pieces = re.findall(r'"(?:[^"\\]|\\.)*"|FIELD\([^)]*\)|\w+|[^\s]', e)
            try:
                return "".join(show(eval(p, {"__builtins__": {}}, env)) for p in pieces)
            except Exception:
                return ""

    def run_action(body):
        for stmt in [s.strip() for s in re.split(r";(?=(?:[^\"]*\"[^\"]*\")*[^\"]*$)", body)]:
            if not stmt:
                continue
            m = re.match(r"print(?:f)?\b(.*)$", stmt, re.S)
            if m:
                is_f = stmt.startswith("printf")
                args = split_expr(m.group(1).strip().strip("()") if m.group(1).strip().startswith("(") and m.group(1).strip().endswith(")") else m.group(1).strip())
                if is_f:
                    fmtv = ev(args[0]) if args else ""
                    vals = tuple(ev(x) for x in args[1:])
                    try:
                        sh.out.write(str(fmtv).encode().decode("unicode_escape") % vals)
                    except Exception:
                        sh.out.write(str(fmtv))
                elif not args:
                    sh.out.write(field(0) + "\n")
                else:
                    sh.out.write(" ".join(show(ev(x)) for x in args) + "\n")
                continue
            m = re.match(r"([A-Za-z_]\w*)\s*(\+=|-=|\*=|/=|=|\+\+|--)\s*(.*)$", stmt)
            if m:
                name, op, rhs = m.groups()
                cur = st["vars"].get(name, 0)
                if op == "++":
                    st["vars"][name] = num(cur) + 1
                elif op == "--":
                    st["vars"][name] = num(cur) - 1
                else:
                    v = ev(rhs)
                    st["vars"][name] = (v if op == "=" else num(cur) + num(v) if op == "+=" else num(cur) - num(v) if op == "-=" else num(cur) * num(v) if op == "*=" else num(cur) / (num(v) or 1))
                continue
            if stmt == "next":
                raise _Next()

    class _Next(Exception):
        pass

    for pat, body in items:
        if pat == "BEGIN":
            run_action(body)
    text = _text_of(files, i)
    for line in text.splitlines():
        st["NR"] += 1
        parts = line.split(sep) if sep and len(sep) == 1 else re.split(sep, line) if sep else line.split()
        st["F"] = [line] + parts
        st["NF"] = len(parts)
        try:
            for pat, body in items:
                if pat in ("BEGIN", "END"):
                    continue
                if pat and not ev(pat):
                    continue
                run_action(body if body is not None else "print")
        except _Next:
            continue
    for pat, body in items:
        if pat == "END":
            run_action(body)
    return 0


def _awk_parse(prog):
    """'pattern { action } pattern2 { action2 }' -> [(pattern, action)]; a pattern alone prints, an action alone always runs."""
    items, k, n = [], 0, len(prog)
    while k < n:
        while k < n and prog[k] in " \t\n;":
            k += 1
        if k >= n:
            break
        start = k
        depth = 0
        q = None
        while k < n:
            ch = prog[k]
            if q:
                if ch == "\\":
                    k += 1
                elif ch == q:
                    q = None
            elif ch in "\"/" and (ch == '"' or prog[start:k].strip() == "" or prog[start:k].rstrip().endswith(("(", "&&", "||", "!", "~"))):
                q = ch
            elif ch == "{":
                break
            elif ch == "\n" or ch == ";":
                break
            k += 1
        pat = prog[start:k].strip()
        body = None
        if k < n and prog[k] == "{":
            depth, j = 1, k + 1
            q = None
            while j < n and depth:
                ch = prog[j]
                if q:
                    if ch == "\\":
                        j += 1
                    elif ch == q:
                        q = None
                elif ch == '"':
                    q = ch
                elif ch == "{":
                    depth += 1
                elif ch == "}":
                    depth -= 1
                j += 1
            body = prog[k + 1:j - 1]
            k = j
        items.append((pat, body if body is not None else None))
    return [(p, b) for p, b in items]


def wasm(sh, a, i):
    import ioxwasm
    return ioxwasm.main(a, sh.out, sh.err, i or "")


def swiftc_wasm(sh, a, i):
    import ioxswiftwasm
    return ioxswiftwasm.swiftc_wasm(sh, a, i)


def register(table):
    table.update({"swiftc-wasm": swiftc_wasm, "swift-wasm": swiftc_wasm})
    table.update({"wasm": wasm, "wasmtime": wasm, "wasmer": wasm, "wasmkit": wasm, "wasmkit-cli": wasm})
    table.update({"plutil": plutil, "PlistBuddy": plistbuddy, "defaults": defaults, "xcrun": xcrun, "sw_vers": sw_vers,
                  "cut": cut, "tee": tee, "diff": diff, "stat": stat, "du": du, "base64": base64, "printenv": printenv,
                  "awk": awk, "gawk": awk, "nawk": awk})
