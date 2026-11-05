"""ioxspm: Swift Package Manager for iOXcode.

SwiftPM normally *runs* Package.swift to learn what a package contains. An iPhone app can't run code it just
compiled, so ioxspm reads the manifest instead: it parses the Package(...) declaration (the declarative part
every manifest has) and resolves the dependency graph itself, downloading packages from GitHub.

resolve(request_json_path) -> writes <work>/packages.json:
  {"modules": [{"name", "dir", "files": [...], "deps": [...], "cfiles": [...], "resources": [...], "flags": [...]}],
   "notes": [...]}
modules come out in build order (dependencies first).
"""
import io, json, os, re, shutil, ssl, sys, urllib.request, zipfile

# ---------------------------------------------------------------- Swift expression parser (just enough)

class Call:
    def __init__(self, name, args):
        self.name, self.args = name, args       # args: list of (label or None, value)
    def get(self, label, default=None):
        for k, v in self.args:
            if k == label:
                return v
        return default
    def positional(self):
        return [v for k, v in self.args if k is None]
    def __repr__(self):
        return "Call(%s, %r)" % (self.name, self.args)


class Member:
    def __init__(self, name):
        self.name = name
    def __repr__(self):
        return ".%s" % self.name


class Ident:
    def __init__(self, name):
        self.name = name
    def __repr__(self):
        return "Ident(%s)" % self.name


_TOKEN = re.compile(r'''
    (?P<ws>\s+|//[^\n]*|/\*.*?\*/)
  | (?P<str>"""(?:\\.|[^\\])*?"""|"(?:\\.|[^"\\])*")
  | (?P<num>\d+(?:\.\d+)*)
  | (?P<id>[A-Za-z_][A-Za-z0-9_]*)
  | (?P<op>\.\.\.|\.\.<|[()\[\]{},:.+\-*/<>=!?&|])
''', re.X | re.S)


def tokenize(src):
    out, i = [], 0
    while i < len(src):
        m = _TOKEN.match(src, i)
        if not m:
            i += 1
            continue
        i = m.end()
        kind = m.lastgroup
        if kind == "ws":
            continue
        out.append((kind, m.group(kind)))
    return out


def _unescape(s):
    if s.startswith('"""'):
        s = s[3:-3]
    else:
        s = s[1:-1]
    return s.replace('\\"', '"').replace("\\n", "\n").replace("\\\\", "\\")


class Parser:
    def __init__(self, toks):
        self.t, self.i = toks, 0

    def peek(self, k=0):
        return self.t[self.i + k] if self.i + k < len(self.t) else (None, None)

    def eat(self, val=None):
        tok = self.peek()
        self.i += 1
        return tok

    def parse_expr(self):
        node = self.parse_primary()
        # binary operators (+ for array/string concatenation, ternaries are not supported)
        while self.peek()[1] in ("+",):
            self.eat()
            rhs = self.parse_primary()
            if isinstance(node, list) and isinstance(rhs, list):
                node = node + rhs
            elif isinstance(node, str) and isinstance(rhs, str):
                node = node + rhs
        return node

    def parse_primary(self):
        kind, val = self.peek()
        if kind == "str":
            self.eat()
            return _unescape(val)
        if kind == "num":
            self.eat()
            return val
        if val == "[":
            self.eat()
            items, is_dict = [], False
            if self.peek()[1] == ":":
                self.eat(); self.eat()
                return {}
            while self.peek()[1] not in ("]", None):
                v = self.parse_expr()
                if self.peek()[1] == ":":
                    self.eat(); is_dict = True
                    items.append((v, self.parse_expr()))
                else:
                    items.append(v)
                if self.peek()[1] == ",":
                    self.eat()
            self.eat()
            return dict(items) if is_dict else items
        if val == "(":
            self.eat()
            v = self.parse_expr()
            while self.peek()[1] not in (")", None):
                self.eat()
            self.eat()
            return v
        if val == ".":
            self.eat()
            name = self.eat()[1]
            node = self.parse_postfix(Member(name))
            return node
        if kind == "id":
            self.eat()
            if val in ("true", "false"):
                return val == "true"
            node = Ident(val)
            # Foo.bar, Foo(...)
            while self.peek()[1] == "." and self.peek(1)[0] == "id":
                self.eat()
                node = Ident(node.name + "." + self.eat()[1]) if isinstance(node, Ident) else node
            return self.parse_postfix(node)
        # anything else: skip a token
        self.eat()
        return None

    def parse_postfix(self, node):
        name = node.name if isinstance(node, (Member, Ident)) else None
        while True:
            if self.peek()[1] == "(" and name is not None:
                self.eat()
                args = []
                while self.peek()[1] not in (")", None):
                    label = None
                    if self.peek()[0] == "id" and self.peek(1)[1] == ":":
                        label = self.eat()[1]; self.eat()
                    args.append((label, self.parse_expr()))
                    if self.peek()[1] == ",":
                        self.eat()
                self.eat()
                node = Call(name, args)
                name = None
            elif self.peek()[1] == "." and self.peek(1)[0] == "id" and self.peek(2)[1] != "(" and isinstance(node, (Call, Member, Ident)):
                # .package(...).product trailing members: keep the call, drop the member chain
                self.eat(); self.eat()
            elif self.peek()[1] == "." and self.peek(1)[0] == "id" and self.peek(2)[1] == "(":
                # chained call like .define("X", .when(...)): treat as a new call on the same node
                self.eat()
                nxt = self.eat()[1]
                name = nxt
                continue
            else:
                break
        return node


def extract_package_call(src):
    """Finds `let package = Package(...)` / `Package(...)` and returns the parsed Call."""
    # collect simple `let name = "string"` constants so references can be resolved
    consts = {}
    for m in re.finditer(r'(?m)^\s*(?:let|var)\s+(\w+)\s*(?::\s*[^=\n]+)?=\s*', src):
        if src[m.end():m.end() + 8].startswith("Package("):
            continue
        try:
            p = Parser(tokenize(src[m.end():m.end() + 6000]))
            val = p.parse_expr()
        except Exception:
            continue
        if isinstance(val, (str, list, Call)):
            consts[m.group(1)] = val
    idx = src.find("Package(")
    if idx < 0:
        return None, consts
    toks = tokenize(src[idx:])
    p = Parser(toks)
    call = p.parse_expr()
    return call, consts


def _resolve_consts(node, consts, depth=0):
    if depth > 6:
        return node
    if isinstance(node, Ident) and node.name in consts:
        return _resolve_consts(consts[node.name], consts, depth + 1)
    if isinstance(node, list):
        return [_resolve_consts(x, consts, depth + 1) for x in node]
    if isinstance(node, Call):
        return Call(node.name, [(k, _resolve_consts(v, consts, depth + 1)) for k, v in node.args])
    return node


def as_list(x):
    return x if isinstance(x, list) else []


# ---------------------------------------------------------------- manifest model

def _name_of(x):
    return x.name if isinstance(x, (Member, Ident)) else x


def load_manifest(pkg_dir):
    path = os.path.join(pkg_dir, "Package.swift")
    if not os.path.isfile(path):
        return None
    with open(path, encoding="utf-8", errors="replace") as f:
        src = f.read()
    # drop #if blocks: keep the first branch (the normal one)
    src = re.sub(r"#if\b[^\n]*\n(.*?)(?:#else.*?)?#endif", lambda m: m.group(1), src, flags=re.S)
    call, consts = extract_package_call(src)
    if not isinstance(call, Call):
        return None
    call = _resolve_consts(call, consts)
    man = {"name": call.get("name") or os.path.basename(pkg_dir), "targets": [], "products": [], "deps": []}
    for prod in as_list(call.get("products")):
        if not isinstance(prod, Call):
            continue
        kind = prod.name
        if kind not in ("library", "executable"):
            continue
        pos = prod.positional()
        man["products"].append({"name": prod.get("name") or (pos[0] if pos else ""), "kind": kind,
                                "targets": [x for x in (as_list(prod.get("targets"))) if isinstance(x, str)]})
    for dep in as_list(call.get("dependencies")):
        if isinstance(dep, Call) and dep.name == "package":
            man["deps"].append(parse_dependency(dep))
    for t in as_list(call.get("targets")):
        if not isinstance(t, Call):
            continue
        kind = t.name
        td = {"kind": kind, "name": t.get("name"), "path": t.get("path"), "sources": t.get("sources"),
              "exclude": as_list(t.get("exclude")), "resources": [], "deps": [], "flags": [], "defines": [],
              "publicHeadersPath": t.get("publicHeadersPath")}
        for d in as_list(t.get("dependencies")):
            td["deps"].append(parse_target_dep(d))
        for r in as_list(t.get("resources")):
            if isinstance(r, Call):
                td["resources"].append({"kind": r.name, "path": (r.positional() or [None])[0]})
        for s in as_list(t.get("swiftSettings")):
            if isinstance(s, Call) and s.name == "define":
                td["defines"].append((s.positional() or [""])[0])
            elif isinstance(s, Call) and s.name == "unsafeFlags":
                fl = (s.positional() or [[]])[0]
                td["flags"] += [x for x in fl if isinstance(x, str)]
        for s in as_list(t.get("cSettings")):
            if isinstance(s, Call) and s.name == "define":
                td["defines"].append("C:" + (s.positional() or [""])[0])
        man["targets"].append(td)
    if not man["targets"]:
        infer_targets(pkg_dir, man)
    return man


def infer_targets(pkg_dir, man):
    """The manifest builds its target list with code (map/filter/helpers). Fall back to the folder layout:
    every folder under Sources/ is a module, and `import X` lines tell which modules depend on which."""
    root = None
    for cand in ("Sources", "Source", "src"):
        if os.path.isdir(os.path.join(pkg_dir, cand)):
            root = os.path.join(pkg_dir, cand)
            break
    if not root:
        return
    names = sorted(d for d in os.listdir(root) if os.path.isdir(os.path.join(root, d)) and not d.startswith("."))
    imports = {}
    for n in names:
        found = set()
        for dp, _, fs in os.walk(os.path.join(root, n)):
            for f in fs:
                if f.endswith(".swift"):
                    try:
                        with open(os.path.join(dp, f), encoding="utf-8", errors="replace") as fh:
                            for line in fh:
                                m = re.match(r"\s*(?:@\w+(?:\([^)]*\))?\s+)*(?:public\s+|internal\s+)?import\s+(?:struct\s+|class\s+|enum\s+|func\s+)?(\w+)", line)
                                if m:
                                    found.add(m.group(1))
                    except OSError:
                        pass
        imports[n] = found
    for n in names:
        if n.lower().endswith(("tests", "benchmarks", "benchmark")) or n.startswith("_"):
            kind = "internal"
        else:
            kind = "target"
        deps = [{"kind": "target", "name": i} for i in sorted(imports[n]) if i in names and i != n]
        deps += [{"kind": "byName", "name": i} for i in sorted(imports[n]) if i not in names and i not in SYSTEM_MODULES]
        man["targets"].append({"kind": kind if kind != "internal" else "target", "name": n, "path": None, "sources": None,
                               "exclude": [], "resources": [], "deps": deps, "flags": [], "defines": [], "publicHeadersPath": None})
        if not n.lower().endswith(("tests", "benchmarks", "benchmark")):
            man["products"].append({"name": n, "kind": "library", "targets": [n]})


SYSTEM_MODULES = {"Foundation", "Swift", "SwiftUI", "UIKit", "Combine", "Dispatch", "os", "Darwin", "CoreGraphics", "CoreFoundation",
                  "Security", "Network", "Observation", "SwiftData", "CryptoKit", "AVFoundation", "CoreData", "CoreLocation",
                  "MapKit", "WebKit", "StoreKit", "Metal", "MetalKit", "QuartzCore", "Accelerate", "Synchronization", "RegexBuilder",
                  "_Concurrency", "XCTest", "Testing", "AppKit", "Glibc", "Musl", "WinSDK", "Android", "Bionic", "WASILibc", "ucrt", "CoreImage", "CoreText"}


def parse_target_dep(d):
    if isinstance(d, str):
        return {"kind": "target", "name": d}
    if isinstance(d, Call):
        pos = d.positional()
        if d.name == "product":
            return {"kind": "product", "name": d.get("name") or (pos[0] if pos else ""), "package": d.get("package")}
        if d.name == "byName":
            return {"kind": "byName", "name": d.get("name") or (pos[0] if pos else "")}
        if d.name == "target":
            return {"kind": "target", "name": d.get("name") or (pos[0] if pos else "")}
    return {"kind": "unknown", "name": ""}


def parse_dependency(dep):
    url = dep.get("url") or dep.get("path") or ""
    req = {"kind": "branch", "value": "HEAD"}
    if dep.get("from") is not None:
        req = {"kind": "from", "value": dep.get("from")}
    elif dep.get("exact") is not None:
        req = {"kind": "exact", "value": dep.get("exact")}
    elif dep.get("branch") is not None:
        req = {"kind": "branch", "value": dep.get("branch")}
    elif dep.get("revision") is not None:
        req = {"kind": "revision", "value": dep.get("revision")}
    else:
        # .package(url:, .upToNextMajor(from: "1.0.0")) / "1.0.0"..<"2.0.0"
        for k, v in dep.args:
            if k is None and isinstance(v, Call):
                inner = v.get("from") or (v.positional() or [None])[0]
                if v.name in ("upToNextMajor", "upToNextMinor"):
                    req = {"kind": "from" if v.name == "upToNextMajor" else "minor", "value": inner}
                elif v.name == "exact":
                    req = {"kind": "exact", "value": inner}
                elif v.name == "branch":
                    req = {"kind": "branch", "value": inner}
                elif v.name == "revision":
                    req = {"kind": "revision", "value": inner}
    return {"url": url, "name": dep.get("name"), "req": req}


# ---------------------------------------------------------------- GitHub access

_ctx = ssl.create_default_context()


def _get(url, timeout=120, accept=None):
    h = {"User-Agent": "iOXcode"}
    if accept:
        h["Accept"] = accept
    req = urllib.request.Request(url, headers=h)
    with urllib.request.urlopen(req, timeout=timeout, context=_ctx) as r:
        return r.read()


def github_parts(url):
    m = re.match(r"(?:https?://)?(?:www\.)?github\.com[/:]([^/]+)/([^/#?]+?)(?:\.git)?/?$", url.strip())
    return (m.group(1), m.group(2)) if m else None


def list_refs(owner, repo):
    """Tags and branches of a repo, without the API (git's smart HTTP ref advertisement)."""
    data = _get("https://github.com/%s/%s.git/info/refs?service=git-upload-pack" % (owner, repo),
                accept="application/x-git-upload-pack-advertisement")
    tags, heads, head_sha, i = {}, {}, None, 0
    while i < len(data):
        try:
            n = int(data[i:i + 4], 16)
        except ValueError:
            break
        if n == 0:
            i += 4
            continue
        line = data[i + 4:i + n].decode("utf-8", "replace").strip("\n")
        i += n
        line = line.split("\0")[0]
        parts = line.split(" ", 1)
        if len(parts) != 2:
            continue
        sha, ref = parts
        if ref.startswith("refs/tags/") and not ref.endswith("^{}"):
            tags[ref[len("refs/tags/"):]] = sha
        elif ref.startswith("refs/heads/"):
            heads[ref[len("refs/heads/"):]] = sha
        elif ref == "HEAD":
            head_sha = sha
    return tags, heads, head_sha


def _ver(tag):
    m = re.match(r"^v?(\d+)(?:\.(\d+))?(?:\.(\d+))?(?:-([0-9A-Za-z.\-]+))?(?:\+.*)?$", tag)
    if not m:
        return None
    pre = m.group(4)
    return (int(m.group(1)), int(m.group(2) or 0), int(m.group(3) or 0), pre is None, pre or "")


def pick_tag(tags, req):
    vers = [(_ver(t), t) for t in tags]
    vers = [(v, t) for v, t in vers if v and v[3]]   # no prereleases
    vers.sort(key=lambda x: x[0])
    kind, value = req["kind"], str(req.get("value") or "")
    if kind == "exact":
        want = _ver(value)
        for v, t in vers:
            if want and v[:3] == want[:3]:
                return t
        return None
    lo = _ver(value) if value else None
    pool = [(v, t) for v, t in vers if lo is None or v[:3] >= lo[:3]]
    if kind == "from" and lo:
        pool = [(v, t) for v, t in pool if v[0] == lo[0]] or pool
    if kind == "minor" and lo:
        pool = [(v, t) for v, t in pool if v[0] == lo[0] and v[1] == lo[1]] or pool
    return pool[-1][1] if pool else None


def fetch_package(url, req, cache_dir, notes):
    gp = github_parts(url)
    if not gp:
        notes.append("package %s is not on github.com; only GitHub packages can be fetched on iPhone" % url)
        return None, None
    owner, repo = gp
    ref = None
    kind = req["kind"]
    try:
        if kind in ("from", "minor", "exact"):
            tags, heads, head = list_refs(owner, repo)
            tag = pick_tag(tags, req)
            if tag:
                ref = "refs/tags/" + tag
            else:
                ref = "HEAD"
                notes.append("%s/%s: no tag matches %s %s; using the default branch" % (owner, repo, kind, req.get("value")))
        elif kind == "branch":
            ref = "refs/heads/" + req["value"] if req["value"] != "HEAD" else "HEAD"
        elif kind == "revision":
            ref = req["value"]
    except Exception as e:
        notes.append("could not list versions of %s/%s (%s); using the default branch" % (owner, repo, e))
        ref = "HEAD"
    key = "%s__%s__%s" % (owner, repo, re.sub(r"[^A-Za-z0-9._-]", "_", ref))
    dest = os.path.join(cache_dir, key)
    if os.path.isdir(dest) and os.path.isfile(os.path.join(dest, ".ioxcode-complete")):
        return dest, ref
    data = None
    for u in ("https://codeload.github.com/%s/%s/zip/%s" % (owner, repo, ref),):
        try:
            data = _get(u)
            break
        except Exception as e:
            notes.append("download failed for %s: %s" % (u, e))
    if data is None:
        return None, ref
    stage = dest + ".tmp"
    shutil.rmtree(stage, ignore_errors=True)
    with zipfile.ZipFile(io.BytesIO(data)) as z:
        z.extractall(stage)
    kids = os.listdir(stage)
    top = os.path.join(stage, kids[0]) if len(kids) == 1 else stage
    shutil.rmtree(dest, ignore_errors=True)
    shutil.move(top, dest)
    shutil.rmtree(stage, ignore_errors=True)
    open(os.path.join(dest, ".ioxcode-complete"), "w").close()
    return dest, ref


# ---------------------------------------------------------------- graph

SWIFT_EXT = {".swift"}
C_EXT = {".c", ".m", ".mm", ".cpp", ".cc", ".cxx"}


def target_sources(pkg_dir, td):
    base = td.get("path")
    if base is None:
        cands = [os.path.join("Sources", td["name"]), os.path.join("Source", td["name"]),
                 os.path.join("src", td["name"]), os.path.join("srcs", td["name"]), td["name"]]
        # a single-target package may keep sources directly in Sources/
        if not any(os.path.isdir(os.path.join(pkg_dir, c)) for c in cands):
            cands.append("Sources")
        base = next((c for c in cands if os.path.isdir(os.path.join(pkg_dir, c))), cands[0])
    root = os.path.join(pkg_dir, base)
    excl = [os.path.normpath(os.path.join(root, e)) for e in td.get("exclude") or []]
    roots = [os.path.join(root, s) for s in td["sources"]] if td.get("sources") else [root]
    swift, cfiles, resources = [], [], []
    for r in roots:
        walk = [(r, [], [os.path.basename(r)])] if os.path.isfile(r) else os.walk(r)
        for dp, dirs, files in walk:
            dirs[:] = [d for d in dirs if not d.startswith(".") and os.path.normpath(os.path.join(dp, d)) not in excl]
            for f in sorted(files):
                full = os.path.join(dp, f) if not os.path.isfile(r) else r
                if os.path.normpath(full) in excl:
                    continue
                ext = os.path.splitext(f)[1].lower()
                if ext in SWIFT_EXT:
                    swift.append(full)
                elif ext in C_EXT:
                    cfiles.append(full)
    for res in td.get("resources") or []:
        if res.get("path"):
            resources.append(os.path.join(root, res["path"]))
    return root, swift, cfiles, resources


def resolve(request_path):
    with open(request_path) as f:
        req = json.load(f)
    work = req["work"]
    cache = req.get("cache") or os.path.join(work, "packages")
    os.makedirs(cache, exist_ok=True)
    notes = []
    packages = {}       # url key -> {"dir", "manifest"}
    queue = list(req.get("packages") or [])      # [{"url", "req": {...}}]
    order = []
    while queue:
        item = queue.pop(0)
        key = (github_parts(item["url"]) or (item["url"], ""))
        key = "/".join(key).lower()
        if key in packages:
            continue
        local = item["url"] if os.path.isdir(item["url"]) else None
        if local:
            d, ref = local, "local"
        else:
            d, ref = fetch_package(item["url"], item["req"], cache, notes)
        if not d:
            packages[key] = None
            continue
        man = load_manifest(d)
        if not man:
            notes.append("%s has no readable Package.swift" % item["url"])
            packages[key] = None
            continue
        packages[key] = {"dir": d, "manifest": man, "url": item["url"], "ref": ref}
        order.append(key)
        for dep in man["deps"]:
            if dep["url"]:
                queue.append({"url": dep["url"], "req": dep["req"]})
        notes.append("package %s %s" % (man["name"], ref))

    # index every target by (package key, name) and products by name
    modules = {}
    product_targets = {}    # (pkgkey, product) -> [target names]
    for key, p in packages.items():
        if not p:
            continue
        for prod in p["manifest"]["products"]:
            product_targets[(key, prod["name"])] = prod["targets"]
        for td in p["manifest"]["targets"]:
            modules[(key, td["name"])] = td

    wanted = []      # module ids to build (ordered, deps first)
    state = {}

    def key_for_url(url):
        gp = github_parts(url)
        return ("/".join(gp).lower() if gp else url.lower())

    def find_product(name, pkg_hint, from_key):
        if pkg_hint:
            for k, p in packages.items():
                if p and (p["manifest"]["name"].lower() == str(pkg_hint).lower() or k.endswith("/" + str(pkg_hint).lower())):
                    if (k, name) in product_targets:
                        return k, product_targets[(k, name)]
        for (k, pn), tgts in product_targets.items():
            if pn == name:
                return k, tgts
        # fall back to a target of that name
        for (k, tn) in modules:
            if tn == name:
                return k, [tn]
        return None, []

    def visit(mid):
        if state.get(mid) == 2:
            return
        if state.get(mid) == 1:
            return
        state[mid] = 1
        k, name = mid
        td = modules[mid]
        for d in td["deps"]:
            if d["kind"] == "target" or (d["kind"] == "byName" and (k, d["name"]) in modules):
                if (k, d["name"]) in modules:
                    visit((k, d["name"]))
            elif d["kind"] in ("product", "byName"):
                pk, tgts = find_product(d["name"], d.get("package"), k)
                for t in tgts:
                    if (pk, t) in modules:
                        visit((pk, t))
        state[mid] = 2
        wanted.append(mid)

    for ask in req.get("products") or []:
        pk, tgts = find_product(ask["name"], ask.get("package"), None)
        if not tgts:
            notes.append("product %s was not found in any package" % ask["name"])
        for t in tgts:
            if (pk, t) in modules:
                visit((pk, t))

    out = []
    for mid in wanted:
        k, name = mid
        p = packages[k]
        td = modules[mid]
        root, swift, cfiles, resources = target_sources(p["dir"], td)
        deps = []
        for d in td["deps"]:
            if d["kind"] == "target" or (d["kind"] == "byName" and (k, d["name"]) in modules):
                deps.append(d["name"])
            else:
                pk, tgts = find_product(d["name"], d.get("package"), k)
                deps += [t for t in tgts if (pk, t) in modules]
        kind = td["kind"]
        if kind in ("testTarget", "executableTarget", "plugin", "systemLibrary", "binaryTarget", "macro"):
            notes.append("%s (%s) is a %s target; not built on iPhone yet" % (name, p["manifest"]["name"], kind))
            if kind in ("plugin", "macro", "binaryTarget", "systemLibrary"):
                continue
        out.append({"name": name, "package": p["manifest"]["name"], "dir": root, "files": swift, "cfiles": cfiles,
                    "deps": sorted(set(deps)), "resources": resources, "flags": td["flags"], "defines": [d for d in td["defines"] if not d.startswith("C:")],
                    "cdefines": [d[2:] for d in td["defines"] if d.startswith("C:")],
                    "includeDir": os.path.join(root, td.get("publicHeadersPath") or "include") if cfiles else None})
    result = {"modules": out, "notes": notes}
    with open(os.path.join(work, "packages.json"), "w") as f:
        json.dump(result, f, indent=1)
    return result


if __name__ == "__main__":
    print(json.dumps(resolve(sys.argv[1]), indent=1))
