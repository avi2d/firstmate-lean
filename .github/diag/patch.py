import sys
p = sys.argv[1]
s = open(p).read()
old = '    "$name"\n'
new = '    ( "$name" ) || printf "DIAGFAIL %s\\n" "$name" >&2\n'
assert s.count(old) == 1
open(p, "w").write(s.replace(old, new))
