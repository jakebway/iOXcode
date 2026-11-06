import json, sys, collections
def load(p):
    try:
        d = json.load(open(p))
    except Exception as e:
        print("cannot read", p, e); return []
    return d
a, b = load(sys.argv[1]), load(sys.argv[2])
def imgs(d): return [x for x in d if isinstance(x, dict) and x.get("AssetType") == "Image"]
ia, ib = imgs(a), imgs(b)
print("actool entries", len(a), "images", len(ia))
print("assetkit entries", len(b), "images", len(ib))
names_a = {x["Name"] for x in ia}; names_b = {x["Name"] for x in ib}
print("names only in actool:", len(names_a - names_b), sorted(names_a - names_b)[:15])
print("names only in assetkit:", len(names_b - names_a), sorted(names_b - names_a)[:15])
print("keys in actool image entries:", sorted({k for x in ia for k in x})[:60])
print("keys in assetkit image entries:", sorted({k for x in ib for k in x})[:60])
print("scales actool:", collections.Counter(x.get("Scale") for x in ia))
print("scales assetkit:", collections.Counter(x.get("Scale") for x in ib))
print("idioms actool:", collections.Counter(x.get("Idiom") for x in ia))
print("idioms assetkit:", collections.Counter(x.get("Idiom") for x in ib))
for n in ["Phone", "Updates_Store", "Wallpaper_1", "UITableNext", "Camera", "Categories_StoreBKBest"]:
    for label, d in (("actool", ia), ("assetkit", ib)):
        for x in d:
            if x.get("Name") == n: print(label, json.dumps(x, sort_keys=True))
