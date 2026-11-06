"""Emulated Swift macros.

iPhones cannot run macro plugins that are built on the device (unsigned code will not load), so packages that
define their own macros (a `.macro` target) would never compile. For well-known macros we expand the source
text ourselves, writing the same declarations the real macro produces.
Each emulator takes the macro call's arguments (source text) and returns Swift source.
"""
import os, re


def _find_close(src, i):
    """src[i] == '(' -> index of the matching ')', skipping strings and comments."""
    depth = 0
    n = len(src)
    while i < n:
        c = src[i]
        if c == '"':
            if src.startswith('"""', i):
                j = src.find('"""', i + 3)
                i = n if j < 0 else j + 3
                continue
            i += 1
            while i < n and src[i] != '"':
                i += 2 if src[i] == '\\' else 1
        elif src.startswith("//", i):
            j = src.find("\n", i)
            i = n if j < 0 else j
        elif src.startswith("/*", i):
            j = src.find("*/", i + 2)
            i = n if j < 0 else j + 1
        elif c == '(':
            depth += 1
        elif c == ')':
            depth -= 1
            if depth == 0:
                return i
        i += 1
    return -1


_STR = r'"((?:\\.|[^"\\])*)"'


def atunion_builder(args):
    m = re.search(r'named\s*:\s*' + _STR, args)
    if not m:
        return None
    name = m.group(1)
    rest = args[m.end():]
    pairs = re.findall(_STR + r'\s*:\s*' + _STR, rest)
    if not pairs:
        return None
    out = ["public enum %s: Codable, Sendable {" % name]
    for k, v in pairs:
        out.append("    case %s(%s)" % (k, v))
    out.append("    public init(from decoder: Decoder) throws {")
    out.append("        let container = try decoder.singleValueContainer()")
    for idx, (k, v) in enumerate(pairs):
        out.append("        %sif let value = try? container.decode(%s.self) {" % ("" if idx == 0 else "} else ", v))
        out.append("            self = .%s(value)" % k)
    out.append("        } else {")
    out.append('            throw DecodingError.typeMismatch(%s.self, DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Unknown %s type"))' % (name, name))
    out.append("        }")
    out.append("    }")
    out.append("    public func encode(to encoder: Encoder) throws {")
    out.append("        var container = encoder.singleValueContainer()")
    out.append("        switch self {")
    for k, _ in pairs:
        out.append("        case .%s(let unionValue):" % k)
        out.append("            try container.encode(unionValue)")
    out.append("        }")
    out.append("    }")
    out.append("}")
    return "\n".join(out)


FREESTANDING = {"ATUnionBuilder": atunion_builder}


def expand_source(src):
    """Returns the source with emulated freestanding macros expanded, or None when nothing changed."""
    if "#" not in src:
        return None
    changed = False
    for name, fn in FREESTANDING.items():
        pat = re.compile(r'(?<![A-Za-z0-9_])#' + name + r'\s*\(')
        pos = 0
        while True:
            m = pat.search(src, pos)
            if not m:
                break
            open_i = m.end() - 1
            close_i = _find_close(src, open_i)
            if close_i < 0:
                break
            body = fn(src[open_i + 1:close_i])
            if body is None:
                pos = close_i
                continue
            src = src[:m.start()] + body + src[close_i + 1:]
            pos = m.start() + len(body)
            changed = True
    return src if changed else None


def expand_files(files, out_dir):
    """Expand macros in the given files. Returns the new file list (changed files are copies under out_dir)."""
    result = []
    for path in files:
        try:
            with open(path, encoding="utf-8", errors="replace") as f:
                src = f.read()
        except OSError:
            result.append(path)
            continue
        new = expand_source(src)
        if new is None:
            result.append(path)
            continue
        dest = os.path.join(out_dir, "%08x_%s" % (abs(hash(path)) & 0xffffffff, os.path.basename(path)))
        os.makedirs(out_dir, exist_ok=True)
        with open(dest, "w", encoding="utf-8") as f:
            f.write(new)
        result.append(dest)
    return result
