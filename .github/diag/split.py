import re, sys, os
src, dst = sys.argv[1], sys.argv[2]
out, names, skip_cont = [], [], False
for line in open(src, errors='replace').read().split('\n'):
    if skip_cont:
        skip_cont = line.rstrip().endswith('\\')
        continue
    m = re.match(r'^(test_\w+)\s*\(\)', line)
    if m:
        names.append(m.group(1))
        out.append(line)
        continue
    if re.match(r'^fm_test_run\b', line):
        skip_cont = line.rstrip().endswith('\\')
        continue
    if re.match(r'^(test_\w+)(\s.*)?$', line) or re.match(r'^exit\b', line):
        continue
    out.append(line)
open(dst, 'w').write('\n'.join(out))
print('\n'.join(names))
