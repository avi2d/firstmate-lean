/^(not ok|error|.*No such file|.*command not found|.*unbound variable|.*syntax error)/ {
  if (n < 4) { kept[n++] = substr($0, 1, 400) }
}
/^DIAGFAIL / {
  for (i = 0; i < n; i++) print "  | " kept[i]
  print "  | " $0
  n = 0
}
/^ok / { n = 0 }
