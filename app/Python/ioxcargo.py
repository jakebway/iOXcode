"""cargo for iPhone.

Builds a Rust package the way `cargo build` does: reads Cargo.toml (workspaces and inherited fields too) and
Cargo.lock, picks crate versions from crates.io, works out features, downloads the crates and compiles each
one with the real Rust compiler, which iOXcode carries as a library (librustc_driver) and runs in-process.

What a phone can't do, and how it's handled:
  * build scripts (build.rs) are programs cargo runs on the Mac. Well-known ones are reproduced here exactly
    (what they print and the files they write); one that only checks the compiler version is skipped, as its
    checks pass on this compiler. Anything else is reported.
  * proc-macro crates (serde_derive, thiserror, ...) are compiler plug-ins and can't be loaded yet: reported.
  * linking a program (bin, cdylib) needs a linker: reported. rlib and staticlib, what an iOS app links, work.
"""
import ctypes, hashlib, io, json, os, re, shutil, sys, tarfile, threading, time, urllib.request

try:
    import tomllib
except ImportError:  # pragma: no cover
    tomllib = None

HOST = "aarch64-apple-ios"
INDEX = "https://index.crates.io/"
DL = "https://static.crates.io/crates/%s/%s-%s.crate"


class CargoError(Exception):
    pass


# ---------------------------------------------------------------- versions

def parse_version(s):
    s = s.strip().lstrip("v").split("+")[0]
    pre = ""
    if "-" in s:
        s, pre = s.split("-", 1)
    nums = [int(x) for x in s.split(".")[:3]]
    while len(nums) < 3:
        nums.append(0)
    return (nums[0], nums[1], nums[2], pre)


def _vkey(v):
    # a pre-release sorts before its release
    return (v[0], v[1], v[2], 0 if v[3] else 1, v[3])


def _cmp(v, w):
    a, b = _vkey(v), _vkey(w)
    return (a > b) - (a < b)


def parse_req(req):
    """A version requirement as a list of (op, (major, minor, patch, pre), number_of_parts_given)."""
    req = (req or "*").strip()
    out = []
    for part in req.split(","):
        p = part.strip()
        if not p or p == "*":
            continue
        m = re.match(r"^(\^|~|=|>=|<=|>|<)?\s*v?([0-9*xX]+)(?:\.([0-9*xX]+))?(?:\.([0-9*xX]+))?(?:-([0-9A-Za-z.-]+))?(?:\+.*)?$", p)
        if not m:
            raise CargoError("can't read version requirement '%s'" % req)
        op = m.group(1) or "^"
        nums = [m.group(2), m.group(3), m.group(4)]
        given = 0
        vals = []
        wild = False
        for n in nums:
            if n is None or wild:
                vals.append(0)
                continue
            if n in ("*", "x", "X"):
                wild = True
                vals.append(0)
                continue
            vals.append(int(n))
            given += 1
        if wild and op == "^":
            op = "~" if given else "*"   # 1.* behaves like ~1, 1.2.* like ~1.2
        if op == "*":
            continue
        out.append((op, (vals[0], vals[1], vals[2], m.group(5) or ""), given))
    return out


def _caret_upper(v, given):
    major, minor, patch = v[0], v[1], v[2]
    if major > 0 or given == 1:
        return (major + 1, 0, 0, "")
    if minor > 0 or given == 2:
        return (0, minor + 1, 0, "")
    return (0, 0, patch + 1, "")


def matches(req, ver):
    """cargo's semver rules, pre-releases included only when the requirement names one of the same x.y.z."""
    comps = req if isinstance(req, list) else parse_req(req)
    if ver[3] and not any(c[1][3] and c[1][:3] == ver[:3] for c in comps):
        return False
    for op, v, given in comps:
        if op == "=":
            if given == 3:
                if _cmp(ver, v) != 0:
                    return False
            else:
                lo, hi = v, ((v[0] + 1, 0, 0, "") if given == 1 else (v[0], v[1] + 1, 0, ""))
                if not (_cmp(ver, lo) >= 0 and _cmp(ver, hi) < 0):
                    return False
        elif op == ">":
            if given == 3:
                if _cmp(ver, v) <= 0: return False
            else:
                up = (v[0] + 1, 0, 0, "") if given == 1 else (v[0], v[1] + 1, 0, "")
                if _cmp(ver, up) < 0: return False
        elif op == ">=":
            if _cmp(ver, v) < 0: return False
        elif op == "<":
            if _cmp(ver, v) >= 0: return False
        elif op == "<=":
            if given == 3:
                if _cmp(ver, v) > 0: return False
            else:
                up = (v[0] + 1, 0, 0, "") if given == 1 else (v[0], v[1] + 1, 0, "")
                if _cmp(ver, up) >= 0: return False
        elif op == "~":
            hi = (v[0] + 1, 0, 0, "") if given == 1 else (v[0], v[1] + 1, 0, "")
            if not (_cmp(ver, v) >= 0 and _cmp(ver, hi) < 0): return False
        else:  # ^
            if not (_cmp(ver, v) >= 0 and _cmp(ver, _caret_upper(v, given)) < 0): return False
    return True


def compat_key(v):
    """Versions cargo treats as one 'semver-compatible' slot: 1.x.y, 0.3.y, 0.0.4."""
    if v[0]:
        return (v[0],)
    if v[1]:
        return (0, v[1])
    return (0, 0, v[2])


def vstr(v):
    return "%d.%d.%d%s" % (v[0], v[1], v[2], ("-" + v[3]) if v[3] else "")


# ---------------------------------------------------------------- cfg(...) for the iPhone target

def target_cfg(triple):
    arch = triple.split("-")[0]
    cfg = {
        "target_arch": "aarch64" if arch in ("aarch64", "arm64", "arm64e") else arch,
        "target_os": "ios", "target_family": "unix", "target_vendor": "apple", "target_env": "",
        "target_pointer_width": "64", "target_endian": "little", "panic": "unwind", "target_abi": "",
        "target_has_atomic": {"8", "16", "32", "64", "ptr"},
    }
    if triple.endswith("-sim"):
        cfg["target_abi"] = "sim"
    if "macabi" in triple:
        cfg["target_abi"] = "macabi"
    return cfg


def eval_cfg(expr, cfg, triple):
    expr = expr.strip()
    if not expr.startswith("cfg("):
        return expr == triple   # [target.aarch64-apple-ios.dependencies]
    toks = re.findall(r'"[^"]*"|[A-Za-z_][A-Za-z0-9_]*|[(),=]', expr[4:-1])
    pos = [0]

    def peek():
        return toks[pos[0]] if pos[0] < len(toks) else None

    def take():
        t = toks[pos[0]]
        pos[0] += 1
        return t

    def pred():
        name = take()
        if peek() == "(":
            take()
            args = []
            while peek() != ")":
                args.append(pred())
                if peek() == ",":
                    take()
            take()
            if name == "all": return all(args)
            if name == "any": return any(args)
            if name == "not": return not args[0]
            return False
        if peek() == "=":
            take()
            val = take().strip('"')
            have = cfg.get(name)
            return val in have if isinstance(have, set) else have == val
        return name in ("unix", "debug_assertions") and (name == "unix")
    try:
        return pred()
    except Exception:
        return False


# ---------------------------------------------------------------- downloads

def _ctx():
    try:
        import ioxsh
        return ioxsh._ssl_ctx()
    except Exception:
        return None


def _get(url, timeout=120):
    req = urllib.request.Request(url, headers={"User-Agent": "iOXcode (cargo)"})
    with urllib.request.urlopen(req, timeout=timeout, context=_ctx()) as r:
        return r.read()


def cache_dir():
    base = os.environ.get("IOX_CACHES") or os.path.join(os.path.expanduser("~"), "Library", "Caches", "iOXcode")
    d = os.path.join(base, "cargo")
    os.makedirs(d, exist_ok=True)
    return d


def index_path(name):
    n = name.lower()
    if len(n) == 1: return "1/" + n
    if len(n) == 2: return "2/" + n
    if len(n) == 3: return "3/%s/%s" % (n[0], n)
    return "%s/%s/%s" % (n[:2], n[2:4], n)


_index_mem = {}


def index_entries(name, log):
    if name in _index_mem:
        return _index_mem[name]
    path = os.path.join(cache_dir(), "index", index_path(name))
    data = None
    try:
        data = _get(INDEX + index_path(name)).decode("utf-8")
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w") as f:
            f.write(data)
    except Exception as e:
        if os.path.isfile(path):
            data = open(path).read()
        else:
            raise CargoError("can't reach crates.io for '%s' (%s)" % (name, e))
    out = []
    for line in data.splitlines():
        line = line.strip()
        if line:
            try:
                out.append(json.loads(line))
            except ValueError:
                pass
    _index_mem[name] = out
    return out


def fetch_crate(name, version, cksum, log):
    """The unpacked source folder of name-version from crates.io (cached)."""
    dest = os.path.join(cache_dir(), "src", "%s-%s" % (name, version))
    if os.path.isfile(os.path.join(dest, ".ok")):
        return dest
    log("  Downloaded %s v%s" % (name, version))
    data = _get(DL % (name, name, version))
    if cksum and hashlib.sha256(data).hexdigest() != cksum:
        raise CargoError("checksum of %s %s does not match crates.io" % (name, version))
    tmp = dest + ".part"
    shutil.rmtree(tmp, ignore_errors=True)
    os.makedirs(tmp)
    with tarfile.open(fileobj=io.BytesIO(data), mode="r:gz") as t:
        for m in t.getmembers():
            parts = m.name.split("/", 1)
            if len(parts) < 2 or not parts[1] or m.issym() or m.islnk() or ".." in parts[1].split("/"):
                continue
            m.name = parts[1]
            t.extract(m, tmp, filter="data") if hasattr(tarfile, "data_filter") else t.extract(m, tmp)
    shutil.rmtree(dest, ignore_errors=True)
    os.rename(tmp, dest)
    open(os.path.join(dest, ".ok"), "w").close()
    return dest


def fetch_git(url, ref, log):
    import ioxsh
    parts = ioxsh._github_parts(url)
    if not parts:
        raise CargoError("git dependency %s: only github.com can be downloaded on iPhone" % url)
    key = re.sub(r"[^A-Za-z0-9_.-]", "_", "%s__%s__%s" % (parts[0], parts[1], ref or "HEAD"))
    dest = os.path.join(cache_dir(), "git", key)
    if not os.path.isdir(dest):
        log("    Updating git repository `%s`" % url)
        ioxsh._download_repo(parts[0], parts[1], ref, dest)
    return dest


# ---------------------------------------------------------------- manifests

def load_toml(path):
    with open(path, "rb") as f:
        return tomllib.load(f)


def find_workspace(pkg_dir):
    d = os.path.dirname(os.path.abspath(pkg_dir))
    while True:
        m = os.path.join(d, "Cargo.toml")
        if os.path.isfile(m):
            try:
                t = load_toml(m)
            except Exception:
                t = {}
            if "workspace" in t:
                return d, t
        nd = os.path.dirname(d)
        if nd == d:
            return None, None
        d = nd


class Package:
    def __init__(self, directory, source, manifest, ws_dir=None, ws=None):
        self.dir = directory
        self.source = source          # "path" | "registry" | "git"
        self.raw = manifest
        p = dict(manifest.get("package") or {})
        wsp = ((ws or {}).get("workspace") or {}).get("package") or {}
        for k, v in list(p.items()):
            if isinstance(v, dict) and v.get("workspace") is True:
                p[k] = wsp.get(k)
        self.pkg = p
        self.ws_dir, self.ws = ws_dir, ws
        self.name = p.get("name") or os.path.basename(directory)
        self.version = parse_version(str(p.get("version") or "0.0.0"))
        self.edition = str(p.get("edition") or "2015")
        lib = manifest.get("lib") or {}
        self.proc_macro = bool(lib.get("proc-macro") or lib.get("proc_macro"))
        self.lib_name = (lib.get("name") or self.name).replace("-", "_")
        self.lib_path = os.path.join(directory, lib.get("path") or "src/lib.rs")
        self.crate_types = lib.get("crate-type") or lib.get("crate_type") or (["proc-macro"] if self.proc_macro else ["lib"])
        b = p.get("build")
        if b is False:
            self.build_script = None
        elif isinstance(b, str):
            self.build_script = os.path.join(directory, b)
        else:
            self.build_script = os.path.join(directory, "build.rs") if os.path.isfile(os.path.join(directory, "build.rs")) else None
        self.features = {k: list(v) for k, v in (manifest.get("features") or {}).items()}
        self.links = p.get("links")

    @property
    def id(self):
        return "%s %s %s" % (self.name, vstr(self.version), self.source if self.source != "path" else "path+" + self.dir)

    def deps(self, cfg, triple):
        """[(alias, decl)] for normal dependencies that apply to this target."""
        out = []

        def add(table):
            for alias, d in (table or {}).items():
                if isinstance(d, str):
                    d = {"version": d}
                d = dict(d)
                if d.get("workspace") is True:
                    wd = ((self.ws or {}).get("workspace") or {}).get("dependencies", {}).get(alias)
                    base = {"version": wd} if isinstance(wd, str) else dict(wd or {})
                    if "path" in base and self.ws_dir:
                        base["path"] = os.path.join(self.ws_dir, base["path"])
                    feats = list(base.get("features") or []) + list(d.get("features") or [])
                    base.update({k: v for k, v in d.items() if k not in ("workspace", "features")})
                    base["features"] = feats
                    d = base
                elif "path" in d:
                    d["path"] = os.path.join(self.dir, d["path"])
                out.append((alias, d))
        add(self.raw.get("dependencies"))
        for expr, t in (self.raw.get("target") or {}).items():
            if eval_cfg(expr, cfg, triple):
                add((t or {}).get("dependencies"))
        return out


def load_package(directory, source):
    m = os.path.join(directory, "Cargo.toml")
    if not os.path.isfile(m):
        raise CargoError("no Cargo.toml in %s" % directory)
    raw = load_toml(m)
    ws_dir, ws = (None, None)
    if source != "registry":
        ws_dir, ws = find_workspace(directory)
        if "workspace" in raw:
            ws_dir, ws = directory, raw
    return Package(directory, source, raw, ws_dir, ws)


def read_lock(path):
    pins = {}
    if path and os.path.isfile(path):
        try:
            for p in load_toml(path).get("package") or []:
                pins.setdefault(p["name"], []).append(parse_version(p["version"]))
        except Exception:
            pass
    return pins


# ---------------------------------------------------------------- resolver (versions + features)

class Resolver:
    def __init__(self, root, triple, lock, log):
        self.root, self.triple, self.lock, self.log = root, triple, lock, log
        self.cfg = target_cfg(triple)
        self.pkgs = {root.id: root}
        self.slots = {}       # (name, compat) -> chosen version for registry crates
        self.reqs = {}        # (name, compat) -> [requirements]
        self.features = {}    # id -> set of features asked for
        self.edges = {}       # id -> {alias: dep id}
        self.restart = False
        self.forced = {}      # crate name -> version that must be used (to match a carried procedural macro)

    def choose(self, name, req):
        entries = [e for e in index_entries(name, self.log) if not e.get("yanked")]
        cands = sorted(((parse_version(e["vers"]), e) for e in entries), key=lambda x: _vkey(x[0]), reverse=True)
        comps = parse_req(req)
        fits = [(v, e) for v, e in cands if matches(comps, v)]
        if not fits:
            raise CargoError("no version of '%s' on crates.io matches '%s'" % (name, req))
        carried = bundled_macros().get(name) if not building_macros() else None
        if carried:
            mine = [(v, e) for v, e in fits if vstr(v) in carried]
            if mine:
                fits = mine
        forced = self.forced.get(name)
        if forced:
            mine = [(v, e) for v, e in fits if vstr(v) == forced]
            if mine:
                fits = mine
        # a slot already chosen for this compatible range is reused (one version per slot, like cargo)
        for v, e in fits:
            key = (name, compat_key(v))
            if key in self.slots and self.slots[key][0] == v:
                return v, e
        pinned = self.lock.get(name) or []
        for v, e in fits:
            if v in pinned:
                return self._take(name, v, e, req)
        v, e = fits[0]
        return self._take(name, v, e, req)

    def _take(self, name, v, e, req):
        key = (name, compat_key(v))
        self.reqs.setdefault(key, []).append(req)
        if key in self.slots and self.slots[key][0] != v:
            # a newer requirement needs a different version in the same slot: keep the highest that fits all
            allreq = [c for r in self.reqs[key] for c in parse_req(r)]
            entries = [x for x in index_entries(name, self.log) if not x.get("yanked")]
            best = None
            for x in entries:
                xv = parse_version(x["vers"])
                if compat_key(xv) == key[1] and matches(allreq, xv) and (best is None or _cmp(xv, best[0]) > 0):
                    best = (xv, x)
            if best is None:
                raise CargoError("the requirements on '%s' (%s) can't all be met" % (name, ", ".join(self.reqs[key])))
            if best[0] != self.slots[key][0]:
                self.slots[key] = best
                self.restart = True
            return best
        self.slots[key] = (v, e)
        return v, e

    def package_for(self, alias, d):
        name = d.get("package") or alias
        if "path" in d:
            p = load_package(os.path.normpath(d["path"]), "path")
        elif "git" in d:
            ref = d.get("rev") or d.get("tag") or d.get("branch")
            root = fetch_git(d["git"], ref, self.log)
            p = None
            for dirpath, dirs, files in os.walk(root):
                dirs[:] = [x for x in dirs if not x.startswith(".") and x != "target"]
                if "Cargo.toml" in files:
                    try:
                        t = load_toml(os.path.join(dirpath, "Cargo.toml"))
                    except Exception:
                        continue
                    if (t.get("package") or {}).get("name") == name:
                        p = load_package(dirpath, "git")
                        break
            if p is None:
                raise CargoError("git repository %s has no package named %s" % (d["git"], name))
        else:
            v, e = self.choose(name, str(d.get("version") or "*"))
            src = fetch_crate(name, vstr(v), e.get("cksum"), self.log)
            p = load_package(src, "registry")
            if not building_macros():
                for a2, d2 in _all_dep_decls(p):
                    dn = d2.get("package") or a2
                    req2 = str(d2.get("version") or "")
                    carried = bundled_macros().get(dn)
                    if carried and req2.strip().startswith("=") and not any(matches(req2, parse_version(cv)) for cv in carried):
                        # this crate is released in lockstep with the macro iOXcode carries: use the matching release
                        best = sorted(carried, key=lambda x: _vkey(parse_version(x)))[-1]
                        if self.forced.get(name) != best and any(x["vers"] == best for x in index_entries(name, self.log)):
                            self.forced[name] = best
                            key = (name, compat_key(v))
                            self.slots.pop(key, None)
                            self.reqs.pop(key, None)
                            self.restart = True
        if p.id not in self.pkgs:
            self.pkgs[p.id] = p
        return self.pkgs[p.id]

    def resolve(self, root_features, default):
        for _ in range(20):
            self.restart = False
            self.features = {}
            self.edges = {}
            want = set(root_features) | ({"default"} if default else set())
            self._visit(self.root, want)
            if not self.restart:
                return
        raise CargoError("could not settle on crate versions")

    def _visit(self, root, want):
        queue = [(root, set(want))]
        while queue:
            pkg, add = queue.pop()
            have = self.features.setdefault(pkg.id, set())
            first = pkg.id not in self.edges
            new = add - have
            if not new and not first:
                continue
            have |= new
            feats, on_deps, dep_feats = self.closure(pkg, have)
            self.features[pkg.id] = feats
            edges = self.edges.setdefault(pkg.id, {})
            if pkg.proc_macro and not building_macros() and vstr(pkg.version) in (bundled_macros().get(pkg.name) or {}):
                continue   # already built into iOXcode: its own dependencies aren't needed
            for alias, d in pkg.deps(self.cfg, self.triple):
                if d.get("optional") and alias not in on_deps:
                    continue
                child = self.package_for(alias, d)
                if self.restart:
                    return
                # the name the code uses: the dependency's own library name, unless the dependency was renamed
                edges[(alias.replace("-", "_") if d.get("package") else child.lib_name)] = child.id
                ask = set(d.get("features") or [])
                if d.get("default-features", d.get("default_features", True)):
                    ask.add("default")
                ask |= dep_feats.get(alias, set())
                queue.append((child, ask))

    @staticmethod
    def closure(pkg, asked):
        table = pkg.features
        uses_dep_syntax = {x[4:] for v in table.values() for x in v if x.startswith("dep:")}
        optional = {a for a, d in _all_dep_decls(pkg) if d.get("optional")}
        feats, on, dep_feats = set(), set(), {}
        stack = list(asked)
        while stack:
            f = stack.pop()
            if f in feats:
                continue
            if f not in table:
                if f in optional and f not in uses_dep_syntax:
                    feats.add(f)
                    on.add(f)
                continue
            feats.add(f)
            for item in table[f]:
                if item.startswith("dep:"):
                    on.add(item[4:])
                elif "/" in item:
                    dn, df = item.split("/", 1)
                    weak = dn.endswith("?")
                    dn = dn.rstrip("?")
                    if not weak and dn in optional:
                        on.add(dn)
                        if dn not in uses_dep_syntax and dn not in table:
                            feats.add(dn)
                    dep_feats.setdefault(dn, set()).add(df)
                else:
                    stack.append(item)
        # features asked of a dependency through "dep?/feat" only count if the dependency is on
        return feats, on, dep_feats


def _all_dep_decls(pkg):
    out = list((pkg.raw.get("dependencies") or {}).items())
    for t in (pkg.raw.get("target") or {}).values():
        out += list(((t or {}).get("dependencies") or {}).items())
    return [(a, d if isinstance(d, dict) else {"version": d}) for a, d in out]


# ---------------------------------------------------------------- procedural macros carried by iOXcode

_bundled = None


def bundled_macros():
    """{crate name: {version: dylib path}} for the procedural macros built into iOXcode (signed with the app,
    so the compiler may load them)."""
    global _bundled
    if _bundled is None:
        _bundled = {}
        d = os.environ.get("IOX_RUST_PROC_MACROS") or ""
        idx = os.path.join(os.environ.get("IOX_RUST_PROC_MACROS_INDEX") or d, "index.json")
        try:
            for key, f in json.load(open(idx)).items():
                name, ver = key.split(" ", 1)
                path = f if os.path.isabs(f) else os.path.join(d, f)
                _bundled.setdefault(name, {})[ver] = path
        except (OSError, ValueError):
            pass
    return _bundled


def building_macros():
    return bool(os.environ.get("IOX_BUILD_PROC_MACROS"))


# ---------------------------------------------------------------- build scripts

def _run_build_script_for_real(pkg, features, out_dir, triple, log, prof):
    """On a Mac (IOX_RUSTC_EXE set): compile build.rs for the Mac and run it, exactly like cargo."""
    import subprocess
    exe = os.environ["IOX_RUSTC_EXE"]
    bdir = os.path.dirname(out_dir)
    if any(True for _ in (pkg.raw.get("build-dependencies") or {})):
        log("warning: %s: build-dependencies are not built here; the build script may fail" % pkg.name)
    args = [exe, "--crate-name", "build_script_build", "--edition=%s" % pkg.edition, pkg.build_script,
            "--crate-type", "bin", "-C", "opt-level=0", "--out-dir", bdir, "--cap-lints", "allow"]
    for f in features:
        args += ["--cfg", 'feature="%s"' % f]
    r = subprocess.run(args, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    if r.returncode != 0:
        raise CargoError("failed to compile the build script of %s:\n%s" % (pkg.name, r.stdout))
    env = dict(os.environ)
    cfg = target_cfg(triple)
    for k, v in cfg.items():
        env["CARGO_CFG_" + k.upper()] = ",".join(sorted(v)) if isinstance(v, set) else v
    env["CARGO_CFG_UNIX"] = ""
    for f in features:
        env["CARGO_FEATURE_" + f.upper().replace("-", "_")] = "1"
    env.update({"OUT_DIR": out_dir, "TARGET": triple, "HOST": os.environ.get("IOX_HOST_TRIPLE", "aarch64-apple-darwin"),
                "NUM_JOBS": "1", "OPT_LEVEL": str(prof.get("opt-level", 3)), "DEBUG": "true" if prof.get("debug") else "false",
                "PROFILE": "release" if not prof.get("debug-assertions") else "debug", "RUSTC": exe, "RUSTDOC": "rustdoc",
                "CARGO_ENCODED_RUSTFLAGS": ""})
    r = subprocess.run([os.path.join(bdir, "build_script_build")], cwd=pkg.dir, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    if r.returncode != 0:
        raise CargoError("the build script of %s failed:\n%s%s" % (pkg.name, r.stdout, r.stderr))
    cfgs, envs = [], {}
    for line in r.stdout.splitlines():
        m = re.match(r"^cargo::?([a-z-]+)=(.*)$", line.strip())
        if not m:
            continue
        key, val = m.group(1), m.group(2)
        if key == "rustc-cfg":
            cfgs.append(val)
        elif key == "rustc-env" and "=" in val:
            a, b = val.split("=", 1)
            envs[a] = b
        elif key == "warning":
            log("warning: %s: %s" % (pkg.name, val))
    return cfgs, envs


def run_build_script(pkg, features, out_dir, triple, log, prof=None):
    """What `cargo` would get from running build.rs: (cfgs, env). Files go to out_dir."""
    if os.environ.get("IOX_RUSTC_EXE"):
        return _run_build_script_for_real(pkg, features, out_dir, triple, log, prof or {})
    name, v = pkg.name, pkg.version
    cfgs, env = [], {}
    if name in ("serde", "serde_core"):
        mod = "#[doc(hidden)]\npub mod __private%d {\n    #[doc(hidden)]\n    pub use crate::private::*;\n}\n" % v[2]
        if name == "serde":
            src = open(pkg.build_script, encoding="utf-8", errors="replace").read()
            if "serde_core_private" in src:
                mod += "use serde_core::__private%d as serde_core_private;\n" % v[2]
            if "if_docsrs_then_no_serde_core" in src:
                cfgs.append("if_docsrs_then_no_serde_core")
        if "private.rs" in open(pkg.build_script, encoding="utf-8", errors="replace").read():
            with open(os.path.join(out_dir, "private.rs"), "w") as f:
                f.write(mod)
        return cfgs, env
    if name == "serde_json":
        return ['fast_arithmetic="64"'], env
    text = open(pkg.build_script, encoding="utf-8", errors="replace").read()
    if name == "libc":
        # modern libc only adds cfgs for other systems (freebsd versions, emscripten); nothing for Apple
        return cfgs, env
    if name in ("anyhow",):
        if "std_backtrace" in text:
            cfgs.append("std_backtrace")
        return cfgs, env
    if name in ("proc-macro2", "quote", "syn", "rustversion", "thiserror", "paste"):
        return cfgs, env
    if "OUT_DIR" in text or "cc::Build" in text or "bindgen" in text or "rustc-link-lib" in text:
        raise CargoError("the build script of %s %s writes files or builds C code; iOXcode can't run build "
                         "scripts like that on iPhone yet" % (name, vstr(v)))
    log("warning: %s %s: build script not run on iPhone (it only checks the compiler and target, which this "
        "compiler passes)" % (name, vstr(v)))
    return cfgs, env


# ---------------------------------------------------------------- the compiler

_lib = None


def rustc_library():
    global _lib
    if _lib is None:
        path = os.environ.get("IOX_RUSTC_LIB") or ""
        if not os.path.isfile(path):
            return None
        lib = ctypes.CDLL(path)
        lib.ioxrustc_main.argtypes = [ctypes.c_int, ctypes.POINTER(ctypes.c_char_p)]
        lib.ioxrustc_main.restype = ctypes.c_int
        _lib = lib
    return _lib


def sysroot(log):
    """The Rust standard library for iPhone, unpacked once from the copy inside the app."""
    root = os.path.join(cache_dir(), "sysroot")
    archive = os.environ.get("IOX_RUST_SYSROOT_ARCHIVE") or ""
    stamp = os.path.join(root, ".from")
    if os.path.isfile(archive):
        sig = "%s %d" % (archive, os.path.getsize(archive))
        if not (os.path.isfile(stamp) and open(stamp).read() == sig):
            log("    Unpacking the Rust standard library (first Rust build)")
            shutil.rmtree(root, ignore_errors=True)
            dest = os.path.join(root, "lib", "rustlib")
            os.makedirs(dest)
            with tarfile.open(archive, "r:gz") as t:
                t.extractall(dest, filter="data") if hasattr(tarfile, "data_filter") else t.extractall(dest)
            with open(stamp, "w") as f:
                f.write(sig)
    return root


def run_rustc(args, err):
    """One rustc command line, in-process. Diagnostics go to err.
    (On a Mac/CI, IOX_RUSTC_EXE names a rustc program to run instead; iOXcode uses that to build its own parts.)"""
    exe = os.environ.get("IOX_RUSTC_EXE")
    if exe:
        import subprocess
        r = subprocess.run([exe] + args, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        if r.stdout:
            err.write(r.stdout)
        return r.returncode
    lib = rustc_library()
    if lib is None:
        raise CargoError("this copy of iOXcode has no Rust compiler")
    full = ["rustc"] + args
    argv = (ctypes.c_char_p * (len(full) + 1))(*[a.encode() for a in full], None)
    result = [1]
    tmp = os.path.join(cache_dir(), "rustc-output.txt")
    sys.stdout.flush()
    sys.stderr.flush()
    saved_out, saved_err = os.dup(1), os.dup(2)
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o644)
    os.dup2(fd, 1)
    os.dup2(fd, 2)
    os.close(fd)

    def go():
        result[0] = lib.ioxrustc_main(len(full), argv)
    try:
        old = threading.stack_size()
        threading.stack_size(64 * 1024 * 1024)
        t = threading.Thread(target=go)
        t.start()
        threading.stack_size(old)
        t.join()
    finally:
        os.dup2(saved_out, 1)
        os.dup2(saved_err, 2)
        os.close(saved_out)
        os.close(saved_err)
    try:
        text = open(tmp, encoding="utf-8", errors="replace").read()
    except OSError:
        text = ""
    if text:
        err.write(text if text.endswith("\n") else text + "\n")
    return result[0]


# ---------------------------------------------------------------- cargo build

def _profile(ws_manifest, name):
    defaults = {
        "dev": {"opt-level": 0, "debug": True, "lto": False, "codegen-units": 256, "panic": "unwind", "debug-assertions": True, "overflow-checks": True},
        "release": {"opt-level": 3, "debug": False, "lto": False, "codegen-units": 16, "panic": "unwind", "debug-assertions": False, "overflow-checks": False},
    }
    prof = dict(defaults.get(name) or defaults["release"])
    user = ((ws_manifest or {}).get("profile") or {})
    if name not in defaults and name in user:
        prof = dict(defaults.get(user[name].get("inherits", "release"), defaults["release"]))
    prof.update({k: v for k, v in (user.get(name) or {}).items() if k != "package"})
    return prof


def _profile_flags(prof, final, lto_run=False):
    f = ["-C", "opt-level=%s" % prof.get("opt-level", 3)]
    dbg = prof.get("debug")
    if dbg in (True, 2, "full", "true"):
        f += ["-C", "debuginfo=2"]
    elif dbg in (1, "limited"):
        f += ["-C", "debuginfo=1"]
    elif dbg in ("line-tables-only", "line-directives-only"):
        f += ["-C", "debuginfo=%s" % dbg]
    if prof.get("panic") == "abort":
        f += ["-C", "panic=abort"]
    if prof.get("debug-assertions"):
        f += ["-C", "debug-assertions=on"]
    if prof.get("overflow-checks"):
        f += ["-C", "overflow-checks=on"]
    cgu = prof.get("codegen-units")
    if cgu:
        f += ["-C", "codegen-units=%s" % cgu]
    lto = prof.get("lto")
    # like cargo: LTO runs only when every output of the package can take it (bin, staticlib, cdylib); a package
    # that is also an rlib gets plain object code, and so do its dependencies
    if final and lto_run and lto in (True, "fat", "true"):
        f += ["-C", "lto"]
    elif final and lto_run and lto == "thin":
        f += ["-C", "lto=thin"]
    elif not lto_run:
        f += ["-C", "embed-bitcode=no"]
    strip = prof.get("strip")
    if strip in (True, "symbols"):
        f += ["-C", "strip=symbols"]
    elif strip == "debuginfo":
        f += ["-C", "strip=debuginfo"]
    return f


def _rustflags():
    enc = os.environ.get("CARGO_ENCODED_RUSTFLAGS")
    if enc:
        return [x for x in enc.split("\x1f") if x]
    return os.environ.get("RUSTFLAGS", "").split()


def build(argv, out, err):
    t0 = time.time()

    def log(s):
        err.write(s + "\n")
        try:
            err.flush()
        except Exception:
            pass

    if tomllib is None:
        raise CargoError("this Python has no TOML reader")
    release, profile_name, triple = False, None, None
    features, all_features, no_default = [], False, False
    manifest_path, target_dir, only_pkg = None, None, None
    a = list(argv)
    k = 0
    while k < len(a):
        x = a[k]
        val = a[k + 1] if k + 1 < len(a) else ""
        if x in ("-r", "--release"): release = True
        elif x == "--profile": profile_name = val; k += 1
        elif x.startswith("--profile="): profile_name = x.split("=", 1)[1]
        elif x == "--target": triple = val; k += 1
        elif x.startswith("--target="): triple = x.split("=", 1)[1]
        elif x in ("--features", "-F"): features += re.split(r"[ ,]+", val); k += 1
        elif x.startswith("--features="): features += re.split(r"[ ,]+", x.split("=", 1)[1])
        elif x == "--all-features": all_features = True
        elif x == "--no-default-features": no_default = True
        elif x == "--manifest-path": manifest_path = val; k += 1
        elif x.startswith("--manifest-path="): manifest_path = x.split("=", 1)[1]
        elif x == "--target-dir": target_dir = val; k += 1
        elif x.startswith("--target-dir="): target_dir = x.split("=", 1)[1]
        elif x in ("-p", "--package"): only_pkg = val; k += 1
        elif x in ("-j", "--jobs", "--color", "--message-format", "-Z", "--config"): k += 1
        k += 1
    triple = triple or os.environ.get("CARGO_BUILD_TARGET") or None
    prof_name = profile_name or ("release" if release else "dev")
    out_triple = triple or HOST

    start = os.path.abspath(os.path.dirname(manifest_path) if manifest_path else os.getcwd())
    root_toml = os.path.join(start, "Cargo.toml")
    if not os.path.isfile(root_toml):
        raise CargoError("could not find `Cargo.toml` in `%s`" % start)
    raw = load_toml(root_toml)
    ws_dir, ws = find_workspace(start) if "workspace" not in raw else (start, raw)
    if "package" not in raw:
        members = ((raw.get("workspace") or {}).get("members")) or []
        import glob
        dirs = sorted({d for m in members for d in glob.glob(os.path.join(start, m)) if os.path.isfile(os.path.join(d, "Cargo.toml"))})
        if only_pkg:
            dirs = [d for d in dirs if (load_toml(os.path.join(d, "Cargo.toml")).get("package") or {}).get("name") == only_pkg]
        if len(dirs) != 1:
            raise CargoError("this is a workspace with %d packages; build one with `-p <name>` (iOXcode builds one package at a time)" % len(dirs))
        start = dirs[0]
    root = load_package(start, "path")
    ws_root = root.ws_dir or start
    ws_manifest = root.ws if root.ws else root.raw
    lock = read_lock(os.path.join(ws_root, "Cargo.lock"))
    tdir = os.path.abspath(target_dir or os.environ.get("CARGO_TARGET_DIR") or os.path.join(ws_root, "target"))
    prof = _profile(ws_manifest, prof_name)
    pdir = "debug" if prof_name == "dev" else prof_name
    out_dir = os.path.join(tdir, triple, pdir) if triple else os.path.join(tdir, pdir)
    deps_dir = os.path.join(out_dir, "deps")
    os.makedirs(deps_dir, exist_ok=True)

    r = Resolver(root, out_triple, lock, log)
    want = set(f for f in features if f)
    if all_features:
        want |= set(root.features)
    r.resolve(want, not no_default)

    # build order: dependencies first
    order, seen = [], set()

    def visit(pid, stack=()):
        if pid in seen:
            return
        if pid in stack:
            raise CargoError("dependency cycle at %s" % pid)
        for c in r.edges.get(pid, {}).values():
            visit(c, stack + (pid,))
        seen.add(pid)
        order.append(pid)
    visit(root.id)

    root_types = [t for t in root.crate_types if t not in ("bin", "cdylib", "dylib")] if not os.environ.get("IOX_RUSTC_EXE") else root.crate_types
    lto_run = prof.get("lto") not in (False, "false", None, "off") and bool(root_types) and \
        all(t in ("bin", "staticlib", "cdylib") for t in root_types)
    carried_artifacts = {}
    for pid in order:
        p = r.pkgs[pid]
        if p.proc_macro and not building_macros():
            have = (bundled_macros().get(p.name) or {}).get(vstr(p.version))
            if not have:
                versions = ", ".join(sorted(bundled_macros().get(p.name) or {})) or "none"
                raise CargoError("%s %s is a procedural macro (a compiler plug-in, needed by %s). iPhone apps can only load "
                                 "plug-ins signed with the app, and this version isn't one of those built into iOXcode "
                                 "(it has: %s)." % (p.name, vstr(p.version), _who_needs(r, pid), versions))
            carried_artifacts[pid] = have

    sr = os.environ.get("IOX_RUST_SYSROOT") or sysroot(log)
    flags_extra = _rustflags()
    artifacts = {}
    built = 0
    for pid in order:
        p = r.pkgs[pid]
        feats = sorted(r.features.get(pid, set()))
        final = pid == root.id
        if pid in carried_artifacts:
            artifacts[pid] = carried_artifacts[pid]
            continue
        h = hashlib.sha256(json.dumps([p.id, feats, prof, out_triple, final]).encode()).hexdigest()[:16]
        rlib = os.path.join(deps_dir, "lib%s-%s.rlib" % (p.lib_name, h))
        types = [t for t in (p.crate_types if final else ["lib"])]
        if p.proc_macro:
            types = ["proc-macro"]
            ext = ".dylib" if "apple" in out_triple else (".dll" if "windows" in out_triple else ".so")
            rlib = os.path.join(deps_dir, "lib%s-%s%s" % (p.lib_name, h, ext))
        if any(t in ("bin", "cdylib", "dylib") for t in types) and not os.environ.get("IOX_RUSTC_EXE"):
            log("warning: %s: crate-type %s needs a linker, which iOXcode doesn't have for Rust; building the others"
                % (p.name, ", ".join(t for t in types if t in ("bin", "cdylib", "dylib"))))
            types = [t for t in types if t not in ("bin", "cdylib", "dylib")] or ["lib"]
        stamp = os.path.join(deps_dir, ".%s-%s.ok" % (p.lib_name, h))
        fresh = os.path.isfile(stamp) and p.source != "path"
        if fresh:
            artifacts[pid] = rlib
            continue
        log("   Compiling %s v%s%s" % (p.name, vstr(p.version), (" (%s)" % p.dir) if p.source == "path" else ""))
        env_keep = dict(os.environ)
        cfgs = []
        try:
            v = p.version
            os.environ.update({
                "CARGO": "cargo", "CARGO_MANIFEST_DIR": p.dir, "CARGO_MANIFEST_PATH": os.path.join(p.dir, "Cargo.toml"),
                "CARGO_PKG_NAME": p.name, "CARGO_CRATE_NAME": p.lib_name,
                "CARGO_PKG_VERSION": vstr(v), "CARGO_PKG_VERSION_MAJOR": str(v[0]), "CARGO_PKG_VERSION_MINOR": str(v[1]),
                "CARGO_PKG_VERSION_PATCH": str(v[2]), "CARGO_PKG_VERSION_PRE": v[3],
                "CARGO_PKG_AUTHORS": ":".join(p.pkg.get("authors") or []),
                "CARGO_PKG_DESCRIPTION": str(p.pkg.get("description") or ""),
                "CARGO_PKG_HOMEPAGE": str(p.pkg.get("homepage") or ""), "CARGO_PKG_REPOSITORY": str(p.pkg.get("repository") or ""),
                "CARGO_PKG_LICENSE": str(p.pkg.get("license") or ""), "CARGO_PKG_LICENSE_FILE": str(p.pkg.get("license-file") or ""),
                "CARGO_PKG_RUST_VERSION": str(p.pkg.get("rust-version") or ""), "CARGO_PKG_README": str(p.pkg.get("readme") or ""),
            })
            if final:
                os.environ["CARGO_PRIMARY_PACKAGE"] = "1"
            if p.build_script:
                od = os.path.join(out_dir, "build", "%s-%s" % (p.name, h), "out")
                os.makedirs(od, exist_ok=True)
                os.environ["OUT_DIR"] = od
                c, e = run_build_script(p, feats, od, out_triple, log, prof)
                cfgs += c
                os.environ.update(e)
            args = ["--crate-name", p.lib_name, "--edition=%s" % p.edition, p.lib_path, "--error-format=human"]
            for t in types:
                args += ["--crate-type", t]
            args += _profile_flags(prof, final, lto_run)
            for f in feats:
                args += ["--cfg", 'feature="%s"' % f]
            for c in cfgs:
                args += ["--cfg", c]
            args += ["-C", "metadata=%s" % h, "-C", "extra-filename=-%s" % h, "--out-dir", deps_dir,
                     "--target", out_triple, "--sysroot", sr, "-L", "dependency=%s" % deps_dir]
            if p.source != "path":
                args += ["--cap-lints", "allow"]
            if p.proc_macro:
                args += ["--extern", "proc_macro"]
            for alias, cid in sorted(r.edges.get(pid, {}).items()):
                args += ["--extern", "%s=%s" % (alias, artifacts[cid])]
            args += flags_extra
            code = run_rustc(args, err)
        finally:
            os.environ.clear()
            os.environ.update(env_keep)
        if code != 0:
            raise CargoError("could not compile `%s` (lib) due to previous error(s)" % p.name)
        built += 1
        artifacts[pid] = rlib
        open(stamp, "w").close()
        if final:
            # cargo's "uplifted" copies next to deps/
            for t in types:
                ext = {"staticlib": ".a", "lib": ".rlib", "rlib": ".rlib"}.get(t)
                if not ext:
                    continue
                src = os.path.join(deps_dir, "lib%s-%s%s" % (p.lib_name, h, ext))
                if os.path.isfile(src):
                    shutil.copy2(src, os.path.join(out_dir, "lib%s%s" % (p.lib_name, ext)))
    if os.environ.get("IOX_ARTIFACTS_JSON"):
        with open(os.environ["IOX_ARTIFACTS_JSON"], "w") as f:
            json.dump([{"name": r.pkgs[pid].name, "version": vstr(r.pkgs[pid].version), "lib_name": r.pkgs[pid].lib_name,
                        "proc_macro": r.pkgs[pid].proc_macro, "path": artifacts.get(pid)} for pid in order], f, indent=1)
    mode = "optimized" if int(str(prof.get("opt-level", 0)).replace("s", "2").replace("z", "2")) > 0 else "unoptimized"
    log("    Finished `%s` profile [%s%s] target(s) in %.2fs" % (prof_name, mode, " + debuginfo" if prof.get("debug") else "", time.time() - t0))
    return 0


def _who_needs(r, pid):
    for parent, e in r.edges.items():
        if pid in e.values():
            return r.pkgs[parent].name
    return "the package"


def main(argv, out, err):
    """`cargo <args>` as ioxsh runs it. Returns the exit code."""
    if not argv:
        err.write("cargo: which command? (build is available)\n")
        return 1
    cmd, rest = argv[0], argv[1:]
    try:
        if cmd in ("build", "b", "rustc"):
            return build(rest, out, err)
        if cmd in ("--version", "-V", "version"):
            out.write("cargo 1.90.0 (iOXcode)\n")
            return 0
        if cmd in ("fetch",):
            return 0
        err.write("note: cargo %s is not available on iPhone; skipping\n" % cmd)
        return 0
    except CargoError as e:
        err.write("error: %s\n" % e)
        return 101
