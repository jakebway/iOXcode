"""ioxgen: turns what a repo uses to describe its build into something iOXcode can run.

- XcodeGen's project.yml  -> an iOXcode manifest (what `xcodegen generate` + Xcode would build)
- .github/workflows/*.yml -> the steps a macOS runner would run before `xcodebuild`, as one ioxsh
                             script (iOXcode replaces the runner: it runs those steps on the phone,
                             then does the xcodebuild part itself)

generate(project_dir) writes <project_dir>/.ioxcode/generated.json and returns it.
"""
import base64, glob, json, os, re

try:
    import yaml
except Exception:  # pragma: no cover
    yaml = None


def _load_yaml(path):
    with open(path, encoding="utf-8") as f:
        text = f.read()
    if yaml is None:
        raise RuntimeError("PyYAML is missing")
    return yaml.safe_load(text) or {}


def _merge(a, b):
    """XcodeGen include semantics: dicts merge recursively, later values win, lists append."""
    if isinstance(a, dict) and isinstance(b, dict):
        out = dict(a)
        for k, v in b.items():
            out[k] = _merge(a[k], v) if k in a else v
        return out
    if isinstance(a, list) and isinstance(b, list):
        return a + b
    return b


def _load_spec(path, seen=None):
    seen = seen or set()
    spec = _load_yaml(path)
    base = os.path.dirname(path)
    inc = spec.pop("include", []) or []
    if isinstance(inc, (str, dict)):
        inc = [inc]
    merged = {}
    for item in inc:
        p = item["path"] if isinstance(item, dict) else item
        full = os.path.normpath(os.path.join(base, p))
        if full in seen or not os.path.exists(full):
            continue
        seen.add(full)
        merged = _merge(merged, _load_spec(full, seen))
    return _merge(merged, spec)


def find_spec(project_dir):
    for cand in [project_dir] + sorted(glob.glob(os.path.join(project_dir, "*"))):
        p = os.path.join(cand, "project.yml")
        if os.path.isfile(p):
            return p
    return None


def _str(v):
    if isinstance(v, bool):
        return "YES" if v else "NO"
    if isinstance(v, list):
        return " ".join(_str(x) for x in v)
    return "" if v is None else str(v)


def _settings(block, config="Release"):
    """Flatten an XcodeGen settings block (base + configs[Release] or a plain dict)."""
    if not isinstance(block, dict):
        return {}
    if "base" in block or "configs" in block or "groups" in block:
        out = dict(block.get("base") or {})
        for name, vals in (block.get("configs") or {}).items():
            if name.lower() == config.lower() and isinstance(vals, dict):
                out.update(vals)
        return out
    return dict(block)


def manifest_from_spec(spec_path):
    spec = _load_spec(spec_path)
    root = os.path.dirname(spec_path)
    notes = []
    targets = spec.get("targets") or {}
    target_name, target = None, None
    for name, t in targets.items():
        if not isinstance(t, dict):
            continue
        plat = t.get("platform") or t.get("supportedDestinations") or ""
        plat = " ".join(plat) if isinstance(plat, list) else str(plat)
        if str(t.get("type", "")).startswith("application") and ("iOS" in plat or plat == "" or "auto" in plat):
            target_name, target = name, t
            break
    if target is None:
        return None, ["project.yml has no iOS app target"]
    options = spec.get("options") or {}
    s = {}
    s.update(_settings(spec.get("settings")))
    s.update(_settings(target.get("settings")))

    def expand(v):
        v = _str(v)
        for k in ("PROJECT_DIR", "SRCROOT", "SOURCE_ROOT"):
            v = v.replace("$(%s)/" % k, "").replace("${%s}/" % k, "").replace("$(%s)" % k, ".").replace("${%s}" % k, ".")
        v = v.replace("$(TARGET_NAME)", target_name).replace("${TARGET_NAME}", target_name)
        return v.replace('"', "")

    name = expand(s.get("PRODUCT_NAME") or target_name)
    if "$(" in name:
        name = target_name
    m = {"name": re.sub(r"[^A-Za-z0-9_]", "", name) or "App"}
    dt = (target.get("deploymentTarget") or (options.get("deploymentTarget") or {}).get("iOS")
          or s.get("IPHONEOS_DEPLOYMENT_TARGET"))
    if isinstance(dt, dict):
        dt = dt.get("iOS")
    if dt:
        m["minOS"] = str(dt)
    prefix = options.get("bundleIdPrefix")
    bid = s.get("PRODUCT_BUNDLE_IDENTIFIER") or (prefix + "." + target_name if prefix else None)
    if bid:
        m["bundleId"] = expand(bid)
    if s.get("MARKETING_VERSION"):
        m["version"] = _str(s["MARKETING_VERSION"])
    if s.get("CURRENT_PROJECT_VERSION"):
        m["build"] = _str(s["CURRENT_PROJECT_VERSION"])
    if s.get("SWIFT_VERSION"):
        m["swiftVersion"] = _str(s["SWIFT_VERSION"]).replace(".0", "")
    if s.get("SWIFT_OBJC_BRIDGING_HEADER"):
        m["bridgingHeader"] = expand(s["SWIFT_OBJC_BRIDGING_HEADER"])
    opt = _str(s.get("SWIFT_OPTIMIZATION_LEVEL"))
    m["optimization"] = "speed" if opt in ("-O", "-Ounchecked") else "size" if opt == "-Osize" else "none"
    info = target.get("info") or {}
    plist = info.get("path") or s.get("INFOPLIST_FILE")
    if plist:
        m["infoPlistFile"] = expand(plist)
    props = {}
    for k, v in (info.get("properties") or {}).items():
        if isinstance(v, (str, int, float)) and not isinstance(v, bool):
            props[k] = str(v)
    for k, v in s.items():
        if k.startswith("INFOPLIST_KEY_") and isinstance(v, (str, int, float)) and not isinstance(v, bool):
            props[k[len("INFOPLIST_KEY_"):]] = str(v)
    if s.get("PRODUCT_DISPLAY_NAME"):
        props["CFBundleDisplayName"] = _str(s["PRODUCT_DISPLAY_NAME"])
    if props:
        m["infoPlist"] = props

    # sources: folders/files compiled; non-code files inside them become resources (XcodeGen does that)
    sources, resources, excludes = [], [], []
    src_list = target.get("sources") or []
    if isinstance(src_list, (str, dict)):
        src_list = [src_list]
    for item in src_list:
        if isinstance(item, str):
            item = {"path": item}
        p = expand(item.get("path", "."))
        if item.get("buildPhase") == "resources" or item.get("type") == "folder":
            resources.append(p)
            continue
        if item.get("buildPhase") == "none":
            continue
        sources.append(p)
        for e in item.get("excludes") or []:
            excludes.append(os.path.normpath(os.path.join(p, e)))
    m["sources"] = sources or ["."]
    m["resources"] = resources
    m["excludes"] = excludes
    m["sourceResources"] = True

    # libraries and frameworks
    libs, fws, libdirs = [], [], []
    for d in target.get("dependencies") or []:
        if not isinstance(d, dict):
            continue
        if "sdk" in d:
            n = d["sdk"]
            base = os.path.splitext(os.path.basename(n))[0]
            if n.endswith(".framework"):
                fws.append(base)
            else:
                libs.append(base[3:] if base.startswith("lib") else base)
        elif "framework" in d:
            n = expand(d["framework"])
            if n.endswith(".a"):
                base = os.path.splitext(os.path.basename(n))[0]
                libs.append(base[3:] if base.startswith("lib") else base)
                libdirs.append(os.path.dirname(n) or ".")
            elif n.endswith(".xcframework"):
                notes.append("xcframework dependencies are not supported yet: " + n)
            else:
                notes.append("framework dependency is not supported yet: " + n)
        elif "package" in d:
            notes.append("Swift package dependencies are not supported yet: " + str(d["package"]))
        elif "target" in d:
            notes.append("extra targets (extensions, frameworks) are not built yet: " + str(d["target"]))
        elif "carthage" in d:
            notes.append("Carthage is not supported: " + str(d["carthage"]))
    for p in _str(s.get("LIBRARY_SEARCH_PATHS")).split():
        p = expand(p)
        if p and "$(" not in p and p != "$(inherited)":
            libdirs.append(p)
    ld = []
    toks = _str(s.get("OTHER_LDFLAGS")).split()
    i = 0
    while i < len(toks):
        t = toks[i]
        if t == "-framework" and i + 1 < len(toks):
            fws.append(toks[i + 1]); i += 2; continue
        if t.startswith("-l") and len(t) > 2:
            libs.append(t[2:])
        elif t not in ("$(inherited)",) and not t.startswith("$("):
            ld.append(t)
        i += 1
    m["libraries"], m["frameworks"], m["libraryDirs"], m["linkerFlags"] = libs, fws, sorted(set(libdirs)), ld
    sf = [t for t in _str(s.get("OTHER_SWIFT_FLAGS")).split() if not t.startswith("$(")]
    if sf:
        m["swiftFlags"] = sf

    scripts = []
    for key, after in (("preBuildScripts", False), ("postCompileScripts", True), ("postBuildScripts", True)):
        for sc in target.get(key) or []:
            if not isinstance(sc, dict):
                continue
            text = sc.get("script")
            if text is None and sc.get("path"):
                text = 'sh "%s"' % sc["path"]
            if text:
                scripts.append({"name": sc.get("name") or key, "script": text, "afterCompile": after})
    m["scripts"] = scripts
    return m, notes


# ---------------------------------------------------------------- GitHub workflows

def _expr(text, ctx):
    """Replace ${{ ... }} with what it would be on a runner, as far as we can know."""
    def sub(mt):
        e = mt.group(1).strip()
        if e.startswith("secrets."):
            return ""
        if e in ("github.workspace",):
            return "$GITHUB_WORKSPACE"
        if e.startswith("env."):
            return "${%s}" % e[4:]
        if e.startswith("runner.temp"):
            return "$RUNNER_TEMP"
        if e.startswith("runner.os"):
            return "macOS"
        if e.startswith("matrix."):
            return str(ctx.get("matrix", {}).get(e[7:], ""))
        if e.startswith("inputs.") or e.startswith("github.event.inputs."):
            return str(ctx.get("inputs", {}).get(e.split(".")[-1], ""))
        if e in ("github.ref_name", "github.head_ref"):
            return "main"
        if e == "github.repository":
            return ctx.get("repo", "")
        if e in ("github.run_number", "github.run_id", "github.run_attempt"):
            return "1"
        if e == "github.sha":
            return "0000000"
        if e.startswith("steps."):
            return ""
        return ""
    return re.sub(r"\$\{\{(.*?)\}\}", sub, text or "")


def _job_score(job_id, job, wf_name):
    runs = job.get("runs-on", "")
    runs = " ".join(runs) if isinstance(runs, list) else str(runs)
    text = json.dumps(job.get("steps") or [])
    score = 0
    if "macos" in runs.lower():
        score += 1
    for word, pts in (("xcodebuild", 4), ("xcodegen", 2), (".ipa", 2), ("Payload", 1), ("archive", 1)):
        if word in text:
            score += pts
    if re.search(r"ios|ipa|build", job_id + " " + wf_name, re.I):
        score += 1
    return score


def workflow_script(repo_dir):
    files = sorted(glob.glob(os.path.join(repo_dir, ".github", "workflows", "*.y*ml")))
    best = None
    for f in files:
        try:
            wf = _load_yaml(f)
        except Exception:
            continue
        if not isinstance(wf, dict):
            continue
        for job_id, job in (wf.get("jobs") or {}).items():
            if not isinstance(job, dict) or not job.get("steps"):
                continue
            sc = _job_score(job_id, job, str(wf.get("name", "")) + os.path.basename(f))
            if sc >= 5 and (best is None or sc > best[0]):
                best = (sc, f, wf, job_id, job)
    if best is None:
        return None
    _, f, wf, job_id, job = best
    ctx = {"matrix": {}, "inputs": {}}
    strat = (job.get("strategy") or {}).get("matrix") or {}
    for k, v in strat.items():
        if isinstance(v, list) and v and not isinstance(v[0], dict):
            ctx["matrix"][k] = v[0]
    on = wf.get("on") or wf.get(True) or {}
    if isinstance(on, dict):
        for k, v in ((on.get("workflow_dispatch") or {}) or {}).get("inputs", {}).items() if isinstance(on.get("workflow_dispatch"), dict) else []:
            if isinstance(v, dict) and "default" in v:
                ctx["inputs"][k] = v["default"]
    lines = ["# from %s, job '%s'" % (os.path.relpath(f, repo_dir), job_id)]
    env = {}
    env.update(wf.get("env") or {})
    env.update(job.get("env") or {})
    for k, v in env.items():
        lines.append("export %s=%s" % (k, _shq(_expr(_str(v), ctx))))
    defaults = ((job.get("defaults") or wf.get("defaults") or {}).get("run") or {})
    step_count = 0
    for st in job.get("steps") or []:
        if not isinstance(st, dict):
            continue
        name = st.get("name") or (st.get("uses") or "step")
        cond = _str(st.get("if"))
        if "failure()" in cond or "cancelled()" in cond:
            continue
        if "uses" in st:
            u = st["uses"]
            if u.startswith("actions/checkout"):
                continue  # the files are already here
            lines.append("echo %s" % _shq("note: skipping '%s' (%s): GitHub actions don't run on iPhone" % (name, u)))
            continue
        run = st.get("run")
        if not run:
            continue
        run = _expr(_str(run), ctx)
        if re.search(r"(^|[\s;&|(])xcodebuild\b", run):
            lines.append("echo %s" % _shq("== '%s' is the Xcode build: iOXcode takes over from here" % name))
            break
        wd = _expr(_str(st.get("working-directory") or defaults.get("working-directory") or "."), ctx)
        shell = _str(st.get("shell") or defaults.get("shell") or "bash")
        if shell.startswith("python"):
            run = "python3 - <<'IOXCODE_PY'\n%s\nIOXCODE_PY\n" % run
        senv = " ".join("%s=%s" % (k, _shq(_expr(_str(v), ctx))) for k, v in (st.get("env") or {}).items())
        b64 = base64.b64encode(run.encode("utf-8")).decode("ascii")
        lines.append("ioxcode-step %s %s %s %s" % (_shq(name), _shq(wd), _shq(senv), b64))
        step_count += 1
    if step_count == 0:
        return None
    return {"name": "GitHub workflow: %s (%s)" % (job.get("name") or job_id, os.path.basename(f)),
            "script": "\n".join(lines) + "\n", "afterCompile": False, "dir": "."}


def _shq(s):
    return "'" + str(s).replace("'", "'\\''") + "'"


# ---------------------------------------------------------------- entry

def generate(project_dir):
    out = {"notes": []}
    spec = find_spec(project_dir)
    if spec:
        try:
            m, notes = manifest_from_spec(spec)
            out["manifest"] = m
            out["root"] = os.path.relpath(os.path.dirname(spec), project_dir)
            out["notes"] += notes
        except Exception as e:
            out["notes"].append("could not read project.yml: %s" % e)
    try:
        wf = workflow_script(project_dir)
        if wf:
            out["scripts"] = [wf]
    except Exception as e:
        out["notes"].append("could not read the GitHub workflows: %s" % e)
    os.makedirs(os.path.join(project_dir, ".ioxcode"), exist_ok=True)
    with open(os.path.join(project_dir, ".ioxcode", "generated.json"), "w") as f:
        json.dump(out, f, indent=1)
    return out


if __name__ == "__main__":
    import sys
    print(json.dumps(generate(sys.argv[1] if len(sys.argv) > 1 else "."), indent=1))
