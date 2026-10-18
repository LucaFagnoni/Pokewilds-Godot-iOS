# Rewrites every JSON file under the given project dir without whitespace, in place.
# CI-only (the repo keeps readable files); values and key order are unchanged.
import json, os, sys

root = sys.argv[1]
before = after = 0
for d, dirs, files in os.walk(root):
    dirs[:] = [x for x in dirs if x != ".godot"]
    for f in files:
        if not f.endswith(".json"):
            continue
        path = os.path.join(d, f)
        raw = open(path, "rb").read()
        data = json.loads(raw)
        out = json.dumps(data, separators=(",", ":"), ensure_ascii=False).encode()
        assert json.loads(out) == data, path
        open(path, "wb").write(out)
        before += len(raw)
        after += len(out)
print(f"::notice::JSON minified {before / 1e6:.1f} MB -> {after / 1e6:.1f} MB")
