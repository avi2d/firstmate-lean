import re, sys
for p in sys.argv[1:]:
    try:
        lines = open(p).read().split("\n")
    except OSError:
        continue
    if "fm_test_run" in "\n".join(lines):
        continue
    idx = [i for i, l in enumerate(lines) if re.fullmatch(r"test_[A-Za-z0-9_]+", l)]
    if not idx:
        continue
    names = [lines[i] for i in idx]
    first = idx[0]
    out = [l for i, l in enumerate(lines) if i not in set(idx)]
    out.insert(first, "fm_test_run " + " ".join(names))
    open(p, "w").write("\n".join(out))
    print("split", p, len(names))
