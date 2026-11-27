#!/usr/bin/env bash
# fm-project-owner-lib.sh - which Firstmate home owns each project on this machine,
# per docs/configuration.md "Project ownership". No side effects on source.

fm_project_owners_path() {
  if [ -n "${FM_PROJECT_OWNERS_FILE:-}" ]; then
    printf '%s\n' "$FM_PROJECT_OWNERS_FILE"
  else
    printf '%s/firstmate/project-owners\n' "${XDG_CONFIG_HOME:-${HOME:-}/.config}"
  fi
}

# A home's identity is its physical path, so a symlinked spelling of the same
# home is never mistaken for another home.
fm_project_owner_home_identity() {  # <home-path>
  local path=${1%/}
  [ -n "$path" ] || path=/
  (CDPATH='' cd -P -- "$path" 2>/dev/null && pwd -P) || printf '%s\n' "$path"
}

# A ready row may name a repo path such as owner/name; the record keys on the
# clone directory name.
fm_project_owner_key() {  # <project>
  local name=${1%/}
  printf '%s\n' "${name##*/}"
}

fm_project_owners_refuse() {  # <problem>
  FM_PROJECT_OWNERS=
  FM_PROJECT_OWNERS_ERROR=$1
  return 1
}

# Sets FM_PROJECT_OWNERS_FILE, and FM_PROJECT_OWNERS to one <name>\034<home>
# entry per line, empty when the record is absent.
# Returns 1 with FM_PROJECT_OWNERS_ERROR set when the record cannot be read or
# a line is malformed, because a skipped line would let a home take a project
# another home owns.
fm_project_owners_read() {
  local line lineno=0 name home seen=$'\n'
  FM_PROJECT_OWNERS_FILE=$(fm_project_owners_path)
  FM_PROJECT_OWNERS=
  FM_PROJECT_OWNERS_ERROR=
  if [ ! -e "$FM_PROJECT_OWNERS_FILE" ] && [ ! -L "$FM_PROJECT_OWNERS_FILE" ]; then
    return 0
  fi
  if [ ! -f "$FM_PROJECT_OWNERS_FILE" ] || [ ! -r "$FM_PROJECT_OWNERS_FILE" ]; then
    fm_project_owners_refuse "$FM_PROJECT_OWNERS_FILE is not a readable regular file"
    return 1
  fi
  while IFS= read -r line || [ -n "$line" ]; do
    lineno=$((lineno + 1))
    line=${line%$'\r'}
    line=${line#"${line%%[![:space:]]*}"}
    line=${line%"${line##*[![:space:]]}"}
    case "$line" in
      '' | '#'*) continue ;;
      *' /'*) ;;
      *)
        fm_project_owners_refuse "$FM_PROJECT_OWNERS_FILE line $lineno is not '<project-name> <absolute-home-path>'"
        return 1
        ;;
    esac
    # A project name is a directory name and holds no "/", so the first "/"
    # starts the home path, and either side may hold spaces.
    name=${line%%/*}
    home=/${line#*/}
    name=${name%"${name##*[![:space:]]}"}
    if [ -z "$name" ]; then
      fm_project_owners_refuse "$FM_PROJECT_OWNERS_FILE line $lineno names no project before $home"
      return 1
    fi
    case "$seen" in
      *$'\n'"$name"$'\n'*)
        fm_project_owners_refuse "$FM_PROJECT_OWNERS_FILE line $lineno names $name a second time"
        return 1
        ;;
    esac
    seen="$seen$name"$'\n'
    FM_PROJECT_OWNERS="$FM_PROJECT_OWNERS$name"$'\034'"$home"$'\n'
  done < "$FM_PROJECT_OWNERS_FILE"
  return 0
}

# Sets FM_PROJECT_OWNERS_FOREIGN to the <name>\034<home> entries whose home is
# not <self-home>.
# Precondition: fm_project_owners_read succeeded in this shell.
fm_project_owners_foreign() {  # <self-home>
  local self entry home
  self=$(fm_project_owner_home_identity "$1")
  FM_PROJECT_OWNERS_FOREIGN=
  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    home=${entry#*$'\034'}
    [ "$(fm_project_owner_home_identity "$home")" = "$self" ] && continue
    FM_PROJECT_OWNERS_FOREIGN="$FM_PROJECT_OWNERS_FOREIGN$entry"$'\n'
  done <<EOF
$FM_PROJECT_OWNERS
EOF
}

# Sets FM_PROJECT_OWNER_HOME to the home that owns <project> when that home is
# not <self-home>, and returns 0; returns 1 when this home may take the project.
# Precondition: fm_project_owners_read succeeded in this shell.
fm_project_owner_foreign() {  # <project> <self-home>
  local key entry
  key=$(fm_project_owner_key "$1")
  FM_PROJECT_OWNER_HOME=
  fm_project_owners_foreign "$2"
  while IFS= read -r entry; do
    [ "${entry%%$'\034'*}" = "$key" ] || continue
    FM_PROJECT_OWNER_HOME=${entry#*$'\034'}
    return 0
  done <<EOF
$FM_PROJECT_OWNERS_FOREIGN
EOF
  return 1
}

# Returns 0 when <self-home> may <action> <project>. Otherwise prints one
# refusal on stderr naming the owning home and the handoff command, and returns 1.
# An unreadable record refuses too, rather than guessing who owns the project.
fm_project_owner_check() {  # <action> <project> <self-home>
  local action=$1 project=$2 self=$3 key
  if ! fm_project_owners_read; then
    printf 'error: %s refused: the project ownership record is unreadable (%s); fix it so every home knows which projects it owns (docs/configuration.md "Project ownership")\n' \
      "$action" "$FM_PROJECT_OWNERS_ERROR" >&2
    return 1
  fi
  [ -n "$FM_PROJECT_OWNERS" ] || return 0
  fm_project_owner_foreign "$project" "$self" || return 0
  key=$(fm_project_owner_key "$project")
  printf "error: %s refused: project %s is owned by the Firstmate home at %s (%s); hand the task to that home with: bin/fm-handoff.sh '%s' '<title>' --body-file <file>\n" \
    "$action" "$key" "$FM_PROJECT_OWNER_HOME" "$FM_PROJECT_OWNERS_FILE" "$key" >&2
  return 1
}

# Filters a ready listing on stdin: rows under a ready[N]{...} header whose repo,
# or for a row with no repo the project part of its <project>-<number> ID,
# another home owns move out of the table into a refused_other_home table after
# it, and the table's count and the count: line before it are recomputed.
# Every other line passes through in place.
# Precondition: fm_project_owners_foreign succeeded in this shell.
fm_project_owners_filter_ready() {
  FM_PROJECT_OWNERS_AWK=$FM_PROJECT_OWNERS_FOREIGN awk '
    BEGIN {
      n = split(ENVIRON["FM_PROJECT_OWNERS_AWK"], entries, "\n")
      for (i = 1; i <= n; i++) {
        if (split(entries[i], kv, "\034") == 2) owner_of[kv[1]] = kv[2]
      }
    }
    function field(row, want,    i, c, len, k, value, quoted) {
      k = 1; value = ""; quoted = 0
      len = length(row)
      for (i = 1; i <= len; i++) {
        c = substr(row, i, 1)
        if (quoted) {
          if (c == "\\" && i < len) { i++; value = value substr(row, i, 1); continue }
          if (c == "\"") { quoted = 0; continue }
          value = value c
          continue
        }
        if (c == "\"") { quoted = 1; continue }
        if (c == ",") {
          if (k == want) return value
          k++; value = ""
          continue
        }
        value = value c
      }
      return k == want ? value : ""
    }
    function flush(    i) {
      if (count_line) print "count: " kept
      if (kept) {
        print "ready[" kept "]{" columns "}:"
        for (i = 1; i <= kept; i++) print keep[i]
      } else {
        print "ready: 0 unblocked queued tasks this home owns"
      }
      if (refused) {
        print "refused_other_home[" refused "]{id,repo,owner_home}: owned by another Firstmate home - hand each to its owner with bin/fm-handoff.sh, never dispatch it here"
        for (i = 1; i <= refused; i++) print refuse[i]
      }
      rows = 0; kept = 0; refused = 0; count_line = 0
    }
    /^count: [0-9]+$/ && !rows { pending_count = $0; next }
    /^ready\[[0-9]+\]\{.*\}:[[:space:]]*$/ {
      if (rows) flush()
      count_line = (pending_count != "")
      pending_count = ""
      columns = $0
      sub(/^ready\[[0-9]+\]\{/, "", columns)
      sub(/\}:[[:space:]]*$/, "", columns)
      repo_col = 0; id_col = 0
      ncols = split(columns, cols, ",")
      for (i = 1; i <= ncols; i++) {
        if (cols[i] == "repo") repo_col = i
        if (cols[i] == "id") id_col = i
      }
      rows = 1
      next
    }
    rows && /^[[:space:]]/ {
      row = $0
      sub(/^[[:space:]]+/, "", row)
      repo = repo_col ? field(row, repo_col) : ""
      if (repo == "" || repo == "-") {
        repo = id_col ? field(row, id_col) : ""
        if (!sub(/-[0-9]+$/, "", repo)) repo = ""
      }
      sub(/\/+$/, "", repo)
      sub(/.*\//, "", repo)
      if (repo != "" && (repo in owner_of)) {
        refuse[++refused] = "  " field(row, id_col) "," repo "," owner_of[repo]
      } else {
        keep[++kept] = $0
      }
      next
    }
    rows { flush() }
    {
      if (pending_count != "") { print pending_count; pending_count = "" }
      print
    }
    END {
      if (rows) flush()
      if (pending_count != "") print pending_count
    }
  '
}
