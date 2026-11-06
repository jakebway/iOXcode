import json, sys, collections
v = sys.argv[1]
try:
    d = json.load(open("work/v-%s.json" % v))
except Exception:
    d = []
errs = sum(1 for _ in open("work/v-%s.err" % v))
print(v, "entries", len(d), dict(collections.Counter(x.get("AssetType") for x in d if isinstance(x, dict))), "stderr lines", errs)
