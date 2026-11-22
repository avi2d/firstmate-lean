#!/usr/bin/env bash
# Allocation and publication hold the same lock across pending and handled records.
# Only the worker's move into handled/ acknowledges delivery.

_FM_TASK_INBOX_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Both dependencies are canonical lint roots in their own right. Keep them as
# analysis boundaries here so ShellCheck's external-source traversal does not
# recursively duplicate the full backend graph for every inbox consumer.
# shellcheck source=/dev/null
. "$_FM_TASK_INBOX_LIB_DIR/fm-wake-lib.sh"
# shellcheck source=/dev/null
. "$_FM_TASK_INBOX_LIB_DIR/fm-backend.sh"

FM_TASK_INBOX_SCHEMA='fm-task-inbox.v1'
FM_TASK_INBOX_GRACE_DEFAULT=90
FM_TASK_INBOX_RING_MAX_DEFAULT=3
FM_TASK_INBOX_BUSY_MAX_DEFAULT=2
FM_TASK_INBOX_LOCK_WAIT_DEFAULT=5

fm_task_inbox_grace_secs() {
  local g=${FM_TASK_INBOX_GRACE_SECS:-$FM_TASK_INBOX_GRACE_DEFAULT}
  case "$g" in ''|*[!0-9]*) g=$FM_TASK_INBOX_GRACE_DEFAULT ;; esac
  printf '%s' "$g"
}

fm_task_inbox_ring_max() {
  local m=${FM_TASK_INBOX_RING_MAX:-$FM_TASK_INBOX_RING_MAX_DEFAULT}
  case "$m" in ''|*[!0-9]*) m=$FM_TASK_INBOX_RING_MAX_DEFAULT ;; esac
  printf '%s' "$m"
}

fm_task_inbox_busy_max() {
  local m=${FM_TASK_INBOX_BUSY_MAX:-$FM_TASK_INBOX_BUSY_MAX_DEFAULT}
  case "$m" in ''|*[!0-9]*) m=$FM_TASK_INBOX_BUSY_MAX_DEFAULT ;; esac
  # Check the length before numeric comparison so oversized input cannot overflow.
  if [ "${#m}" -gt 9 ] || [ "$m" -eq 0 ]; then
    m=$FM_TASK_INBOX_BUSY_MAX_DEFAULT
  fi
  printf '%s' "$m"
}

# Persist before returning the new count, so a fresh watcher continues the same
# bounded wait. A removed or acknowledged record is a quiet no-op.
fm_task_inbox_record_busy() {  # <state-dir> <task-id> <record-path>
  local dir base previous count
  dir=$(fm_task_inbox_dir "$1" "$2")
  base=${3##*/}
  { IFS=$(printf '\t') read -r previous count < "$dir/.busy-state"; } 2>/dev/null || true
  [ "${previous:-}" = "$base" ] || count=0
  case "${count:-}" in ''|*[!0-9]*) count=0 ;; esac
  [ -f "$3" ] || { printf '0'; return 0; }
  count=$((count + 1))
  if ! { printf '%s\t%s\n' "$base" "$count" > "$dir/.busy-state"; } 2>/dev/null; then
    [ -f "$3" ] || { printf '0'; return 0; }
    return 1
  fi
  printf '%s' "$count"
}

fm_task_inbox_clear_busy() {  # <state-dir> <task-id>
  local dir
  dir=$(fm_task_inbox_dir "$1" "$2")
  rm -f "$dir/.busy-state" 2>/dev/null
}

fm_task_inbox_dir() {  # <state-dir> <task-id>
  printf '%s/%s.inbox' "$1" "$2"
}

fm_task_inbox_handled_dir() {  # <state-dir> <task-id>
  printf '%s/%s.inbox/handled' "$1" "$2"
}

# Numeric sequence of one record basename, or fail for a non-record name.
fm_task_inbox_seq_of() {  # <basename>
  local n=${1%.msg}
  [ "$n" != "$1" ] || return 1
  case "$n" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s' "$((10#$n))"
}

# Next unused sequence, scanning the inbox root AND handled/ so an
# acknowledged sequence is never reissued. Caller must hold .seq.lock.
fm_task_inbox_next_seq() {  # <inbox-dir>
  local dir=$1 max=0 d f n
  for d in "$dir" "$dir/handled"; do
    for f in "$d"/*.msg; do
      [ -e "$f" ] || continue
      n=$(fm_task_inbox_seq_of "${f##*/}") || continue
      [ "$n" -le "$max" ] || max=$n
    done
  done
  printf '%03d' "$((max + 1))"
}

fm_task_inbox_lock_acquire() {  # <lock-path>
  local lock=$1 wait=${FM_TASK_INBOX_LOCK_WAIT_SECS:-$FM_TASK_INBOX_LOCK_WAIT_DEFAULT}
  local deadline probe
  case "$wait" in ''|*[!0-9]*) wait=$FM_TASK_INBOX_LOCK_WAIT_DEFAULT ;; esac
  probe=$(mktemp "${lock%/*}/.lock-probe.XXXXXX") || return 1
  rm -f "$probe" || return 1
  if [ ! -e "$lock" ] && [ ! -L "$lock" ]; then
    fm_lock_try_create "$lock" && return 0
  fi
  deadline=$(( $(date +%s) + wait ))
  while ! fm_lock_try_acquire "$lock"; do
    [ "$(date +%s)" -lt "$deadline" ] || return 1
    sleep 0.1
  done
}

# Write one record into the next sequence slot: temp-write, then atomic
# rename. Prints the record path. Caller must hold .seq.lock.
_fm_task_inbox_write_record_locked() {  # <inbox-dir> <text> [delivery-mode]
  local dir=$1 text=$2 delivery_mode=${3:-} seq tmp rec status=0
  seq=$(fm_task_inbox_next_seq "$dir")
  rec="$dir/$seq.msg"
  tmp=$(mktemp "$dir/.staging.XXXXXX") || return 1
  {
    printf 'schema=%s\n' "$FM_TASK_INBOX_SCHEMA"
    printf 'at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    case "$text" in
      *$'\n') : ;;
      *) printf 'body-terminator=1\n' ;;
    esac
    [ -z "$delivery_mode" ] || printf 'delivery=%s\n' "$delivery_mode"
    printf -- '--\n'
    case "$text" in
      *$'\n') printf '%s' "$text" ;;
      *) printf '%s\n' "$text" ;;
    esac
  } > "$tmp" && mv "$tmp" "$rec" || status=1
  [ "$status" -eq 0 ] || { rm -f "$tmp"; return 1; }
  printf '%s' "$rec"
}

# Durably enqueue one steer: temp-write, then atomic rename into the next
# sequence slot. Prints the record path. Fails without a partial record.
fm_task_inbox_write() {  # <state-dir> <task-id> <text> [delivery-mode]
  local state=$1 task=$2 text=$3 delivery_mode=${4:-} dir lock rec status=0
  dir=$(fm_task_inbox_dir "$state" "$task")
  mkdir -p "$dir/handled" || return 1
  lock="$dir/.seq.lock"
  fm_task_inbox_lock_acquire "$lock" || return 1
  rec=$(_fm_task_inbox_write_record_locked "$dir" "$text" "$delivery_mode") || status=1
  fm_lock_release "$lock"
  [ "$status" -eq 0 ] || return 1
  printf '%s' "$rec"
}

# Durably enqueue one steer at most once: when a record with the exact same
# body and delivery mode already exists, unhandled or acknowledged in handled/,
# no new record is written and the existing record's path is printed instead.
# This is the enqueue primitive for a transport that can fail with completion
# unknown (the remote steer leg over ssh): the caller's safe recovery is to run
# the same enqueue again, and this dedup is what makes the re-run land on the
# same record instead of a duplicate the worker would act on twice. Two
# distinct logical requests never collapse in practice because a marked
# secondmate request embeds a per-request correlation token in its body. The
# local plane keeps plain fm_task_inbox_write: its outcome is synchronous, so
# a repeated identical local steer is a deliberate new instruction.
fm_task_inbox_write_idempotent() {  # <state-dir> <task-id> <text> [delivery-mode]
  local state=$1 task=$2 text=$3 delivery_mode=${4:-} dir lock want have f rec='' status=0
  local first_line=${3%%$'\n'*} scan_dir
  dir=$(fm_task_inbox_dir "$state" "$task")
  mkdir -p "$dir/handled" || return 1
  lock="$dir/.seq.lock"
  fm_task_inbox_lock_acquire "$lock" || return 1
  if want=$(mktemp "$dir/.dedup.XXXXXX") && have=$(mktemp "$dir/.dedup.XXXXXX"); then
    if printf '%s' "$text" > "$want"; then
      # One grep per directory replaces per-record parsing of unrelated history.
      # Header/other-line hits are harmless: mode and exact body still decide.
      # Empty bodies also match the separator, including empty legacy records.
      [ -n "$text" ] || first_line=--
      while IFS= read -r -d '' f; do
        if [ ! -e "$f" ]; then
          case "$f" in
            "$dir"/*.msg)
              f="$dir/handled/${f##*/}"
              [ -e "$f" ] || continue
              ;;
            *) continue ;;
          esac
        fi
        [ "$(fm_task_inbox_delivery_mode "$f")" = "$delivery_mode" ] || continue
        if ! fm_task_inbox_body "$f" > "$have" 2>/dev/null; then
          case "$f" in
            "$dir"/*.msg)
              f="$dir/handled/${f##*/}"
              fm_task_inbox_body "$f" > "$have" 2>/dev/null || continue
              ;;
            *) continue ;;
          esac
        fi
        cmp -s "$want" "$have" || continue
        [ ! -e "$dir/handled/${f##*/}" ] || f="$dir/handled/${f##*/}"
        rec=$f
        break
      done < <(
        # Expand handled/ only AFTER scanning pending records: an acknowledgement
        # racing grep must remain visible even if its original path disappeared.
        for scan_dir in "$dir" "$dir/handled"; do
          # A read/argument-limit error must not turn an exact retry into a new
          # request. Fall back to the original scan only on error, not no-match.
          LC_ALL=C grep -lFx --null -- "$first_line" "$scan_dir"/*.msg 2>/dev/null || {
            [ "$?" -eq 1 ] || printf '%s\0' "$scan_dir"/*.msg
          }
        done
      )
    else
      status=1
    fi
    rm -f "$want" "$have"
  else
    rm -f "${want:-}" 2>/dev/null || true
    status=1
  fi
  if [ "$status" -eq 0 ] && [ -z "$rec" ]; then
    rec=$(_fm_task_inbox_write_record_locked "$dir" "$text" "$delivery_mode") || status=1
  fi
  fm_lock_release "$lock"
  [ "$status" -eq 0 ] || return 1
  printf '%s' "$rec"
}

# The exact enqueued text back out of a record.
fm_task_inbox_body() {  # <record-path>
  local meta body_offset synthetic total count
  [ -f "$1" ] || return 1
  meta=$(LC_ALL=C awk '
    $0 == "body-terminator=1" { synthetic=1 }
    { bytes += length($0) + 1 }
    $0 == "--" { printf "%d\t%d\n", bytes, synthetic; exit }
  ' "$1") || return 1
  IFS=$(printf '\t') read -r body_offset synthetic <<EOF
$meta
EOF
  case "$body_offset" in ''|*[!0-9]*) return 1 ;; esac
  total=$(wc -c < "$1") || return 1
  count=$((total - body_offset))
  if [ "$synthetic" = 1 ]; then
    [ "$count" -gt 0 ] || return 1
    count=$((count - 1))
  fi
  dd if="$1" bs=1 skip="$body_offset" count="$count" 2>/dev/null
}

# The constant self-describing doorbell line for an inbox, named directly or
# by a record the inbox contains. The line that reaches the worker is identical
# either way. It names the inbox by the literal "$FM_TASK_INBOX", which bin/fm-spawn.sh
# exports into every launch as the inbox's absolute path, so the worker can
# resolve it from its own environment even after losing its brief context.
# The short `<task>.inbox` name follows as the fallback for a worker launched
# before that export, whose brief carries the full path (bin/fm-dod-lib.sh
# role contract, bin/fm-brief.sh inbox section). No absolute path is printed,
# so the line's length never grows with the home's depth: a long line wraps
# past what a harness composer read can prove, and a Herdr submit then reports
# it did not reach the pane on every re-ring. The leading `: ` is the POSIX
# shell no-op, so the same line typed into a pane whose agent has exited (a
# bare shell) runs nothing; see the dead-pane note in the header. A
# non-printable inbox name fails without output so terminal controls never
# reach the pane's line discipline.
fm_task_inbox_doorbell_for() {  # <inbox-name>
  local name=${1-} quoted LC_ALL=C
  case "$name" in
    ''|*[![:print:]]*) return 1 ;;
  esac
  quoted=$(printf '%s' "$name" | sed "s/'/'\\\\''/g")
  printf ": Firstmate instruction waiting: list \"\$FM_TASK_INBOX\"/*.msg in your '%s' steering inbox, read and act on each in numeric order, then mv each into its handled/." \
    "$quoted"
}

fm_task_inbox_doorbell_line() {  # <record-path>
  local dir=${1%/*} abs name
  abs=$(cd "$dir" 2>/dev/null && pwd) || abs=$dir
  abs=${abs%/handled}
  name=${abs##*/}
  fm_task_inbox_doorbell_for "$name"
}

fm_task_inbox_ring() {  # <backend> <target> <record-path> [expected-label] [retry-pending]
  # 0 rang, 1 deferred, 2 failed, 3 endpoint dead or missing.
  local backend=$1 target=$2 rec=$3 label=${4:-} retry_pending=${5:-0} line
  case "$(fm_backend_agent_state "$backend" "$target" 2>/dev/null || true)" in
    dead|missing) return 3 ;;
  esac
  if ! line=$(fm_task_inbox_doorbell_line "$rec"); then
    return 2
  fi
  fm_task_inbox_ring_line "$backend" "$target" "$line" "$label" "$retry_pending"
}

fm_task_inbox_ring_line() {  # <backend> <target> <line> [expected-label] [retry-pending]
  local backend=$1 target=$2 line=$3 label=${4:-} retry_pending=${5:-0} cstate verdict
  case "$(fm_backend_agent_state "$backend" "$target" 2>/dev/null || true)" in
    dead|missing) return 3 ;;
  esac
  cstate=$(fm_backend_composer_state "$backend" "$target" "$label" 2>/dev/null) || cstate=unknown
  case "$cstate" in
    pending)
      fm_task_inbox_composer_holds "$backend" "$target" "$line" "$label" \
        && [ "$(fm_backend_busy_state "$backend" "$target" 2>/dev/null)" != busy ] \
        || return 1
      fm_backend_send_key "$backend" "$target" Enter "$label" >/dev/null 2>&1 || return 2
      sleep 0.3
      fm_task_inbox_composer_holds "$backend" "$target" "$line" "$label" || return 0
      fm_backend_send_key "$backend" "$target" Enter "$label" >/dev/null 2>&1 || return 2
      if [ "$retry_pending" -eq 1 ]; then
        sleep 0.3
        ! fm_task_inbox_composer_holds "$backend" "$target" "$line" "$label" || return 1
      fi
      return 0
      ;;
  esac
  # Accepted residual race: terminal input and Enter are separate delivery
  # steps, so an agent exiting after the liveness check could leave a bare
  # shell only a suffix; the `: ` prefix protects complete lines only. Do not
  # add process-bound atomic delivery here unless an incident reopens this.
  if ! verdict=$(fm_backend_send_text_submit "$backend" "$target" "$line" 2 0.4 0.3 "$label" 2>/dev/null); then
    return 2
  fi
  [ "$verdict" != send-failed ] || return 2
  [ "$retry_pending" -ne 1 ] || [ "$verdict" != pending ] || return 1
  return 0
}

# Whether the composer's content, ignoring line wrapping, is exactly <line>.
fm_task_inbox_composer_holds() {  # <backend> <target> <line> [expected-label]
  local cap held
  fm_backend_source "$1" || return 1
  cap=$(fm_backend_capture "$1" "$2" "$FM_COMPOSER_CAPTURE_LINES" "${4:-}" 2>/dev/null) || return 1
  held=$(fm_composer_extract_selected_content styled=0 "$cap") || return 1
  [ -n "$held" ] && [ "$(printf '%s' "$held" | tr -d '[:space:]')" = "$(printf '%s' "$3" | tr -d '[:space:]')" ]
}

fm_task_inbox_delivery_mode() {
  local rec=$1
  if [ ! -f "$rec" ]; then
    rec="${rec%/*}/handled/${rec##*/}"
    [ -f "$rec" ] || return 1
  fi
  awk '/^--$/ { exit } /^delivery=/ { print substr($0, 10); exit }' "$rec"
}

fm_task_inbox_rung_marker() {
  local base=${1##*/}
  printf '%s/.rung-%s' "${1%/*}" "${base%.msg}"
}

fm_task_inbox_ring_until_rung() {
  local backend=$1 target=$2 rec=$3 label=$4 marker rc=0
  marker=$(fm_task_inbox_rung_marker "$rec")
  [ -f "$rec" ] && [ ! -f "$marker" ] || return 0
  fm_task_inbox_ring "$backend" "$target" "$rec" "$label" 1 || rc=$?
  [ -f "$rec" ] || return 0
  [ "$rc" -eq 0 ] || return "$rc"
  : > "$marker" || return 2
}

fm_task_inbox_oldest_unhandled() {  # <state-dir> <task-id> [ordinary]
  fm_task_inbox_unhandled "$1" "$2" "${3:-}"
}

fm_task_inbox_latest_until_rung() {  # <state-dir> <task-id>
  fm_task_inbox_unhandled "$1" "$2" until-rung
}

fm_task_inbox_unhandled() {
  local dir best='' best_n=0 f n mode filter=$3
  dir=$(fm_task_inbox_dir "$1" "$2")
  for f in "$dir"/*.msg; do
    [ -e "$f" ] || continue
    mode=$(fm_task_inbox_delivery_mode "$f") || continue
    case "$mode" in
      fire-and-forget) continue ;;
      until-rung)
        [ "$filter" != ordinary ] && [ ! -f "$(fm_task_inbox_rung_marker "$f")" ] || continue ;;
      *) [ "$filter" != until-rung ] || continue ;;
    esac
    n=$(fm_task_inbox_seq_of "${f##*/}") || continue
    if [ -z "$best" ] || { [ "$filter" = until-rung ] && [ "$n" -gt "$best_n" ]; } \
      || { [ "$filter" != until-rung ] && [ "$n" -lt "$best_n" ]; }; then
      best=$f
      best_n=$n
    fi
  done
  [ -n "$best" ] || return 1
  printf '%s' "$best"
}

# Owe a fire-and-forget record its one retry ring (see the header). A newer
# mark replaces an older one: a ring names the whole inbox, not one record.
fm_task_inbox_mark_retry() {  # <state-dir> <task-id> <record-path>
  local dir
  dir=$(fm_task_inbox_dir "$1" "$2")
  { printf '%s\n' "${3##*/}" > "$dir/.retry-ring"; } 2>/dev/null
}

# Spend the retry mark after its ring, only while it still names that record:
# a newer mark written meanwhile is owed its own retry and survives. Fails only
# when the processed record's mark stays behind.
fm_task_inbox_clear_retry() {  # <state-dir> <task-id> <record-path>
  local dir
  dir=$(fm_task_inbox_dir "$1" "$2")
  [ "$(cat "$dir/.retry-ring" 2>/dev/null)" = "${3##*/}" ] || return 0
  rm -f "$dir/.retry-ring" 2>/dev/null
}

# The re-ring ladder decision for one task. Prints exactly one of:
#   quiet                     nothing due (healthy, within grace or spacing,
#                             or already escalated for the current oldest)
#   ring <record-path>        one doorbell re-ring is due
#   escalate <record-path> <count>   attempt budget spent; surface as stale
#   retry <record-path>       a fire-and-forget record's one retry ring is due
# An empty inbox also resets the ladder bookkeeping so the next message starts
# a fresh ladder.
fm_task_inbox_due_action() {  # <state-dir> <task-id>
  local dir oldest base now grace max ladder rec_base count last
  dir=$(fm_task_inbox_dir "$1" "$2")
  if ! oldest=$(fm_task_inbox_oldest_unhandled "$1" "$2"); then
    rm -f "$dir/.ring-state" "$dir/.escalated" "$dir/.busy-state" 2>/dev/null || true
    # The one retry ring exists only while config/wait-no-turns is present.
    # Absent, a mark is left untouched and the inbox stays quiet, as before.
    if [ -e "${FM_CONFIG_OVERRIDE:-${FM_HOME:-}/config}/wait-no-turns" ]; then
      base=$(cat "$dir/.retry-ring" 2>/dev/null || true)
      if ! fm_task_inbox_seq_of "$base" >/dev/null || [ ! -f "$dir/$base" ]; then
        rm -f "$dir/.retry-ring" 2>/dev/null || true
      elif [ "$(fm_path_age "$dir/.retry-ring")" -ge "$(fm_task_inbox_grace_secs)" ]; then
        printf 'retry %s' "$dir/$base"
        return 0
      fi
    fi
    printf 'quiet'
    return 0
  fi
  base=${oldest##*/}
  grace=$(fm_task_inbox_grace_secs)
  if [ "$(fm_path_age "$oldest")" -lt "$grace" ]; then
    printf 'quiet'
    return 0
  fi
  count=0
  last=0
  ladder=$(cat "$dir/.ring-state" 2>/dev/null || true)
  IFS=$(printf '\t') read -r rec_base count last <<EOF
$ladder
EOF
  if [ -n "$rec_base" ] && [ "$rec_base" != "$base" ]; then
    count=0
    last=0
  fi
  case "$count" in ''|*[!0-9]*) count=0 ;; esac
  case "$last" in ''|*[!0-9]*) last=0 ;; esac
  if [ "$(cat "$dir/.escalated" 2>/dev/null || true)" = "$base" ]; then
    printf 'quiet'
    return 0
  fi
  max=$(fm_task_inbox_ring_max)
  if [ "$count" -ge "$max" ]; then
    printf 'escalate %s %s' "$oldest" "$count"
    return 0
  fi
  now=$(date +%s)
  if [ "$((now - last))" -lt "$grace" ]; then
    printf 'quiet'
    return 0
  fi
  printf 'ring %s' "$oldest"
}

# Advance the ladder after a delivery attempt. A failed ring or a composer-
# protected skip still consumes budget so neither an unreadable pane nor a
# permanently blocked composer can retry silently forever. A positively dead or
# missing endpoint never enters the ladder: the watcher escalates it directly.
# A concurrently removed inbox is a successful no-op; otherwise failure means
# the caller must surface the unwritable ladder while the record remains
# unhandled.
fm_task_inbox_record_ring() {  # <state-dir> <task-id> <record-path>
  local dir base ladder rec_base count last
  dir=$(fm_task_inbox_dir "$1" "$2")
  base=${3##*/}
  count=0
  ladder=$(cat "$dir/.ring-state" 2>/dev/null || true)
  IFS=$(printf '\t') read -r rec_base count last <<EOF
$ladder
EOF
  [ "$rec_base" = "$base" ] || count=0
  case "$count" in ''|*[!0-9]*) count=0 ;; esac
  [ -d "$dir" ] || return 0
  if ! { printf '%s\t%s\t%s\n' "$base" "$((count + 1))" "$(date +%s)" > "$dir/.ring-state"; } 2>/dev/null; then
    [ -d "$dir" ] || return 0
    return 1
  fi
}

# Mark the current oldest as escalated after its stale wake is durably queued,
# suppressing another wake on later polls. Wake-before-marker ordering favors
# at-least-once recovery: a crash or marker failure can cause a rare duplicate;
# stuck-crewmate-recovery owns the message from here.
fm_task_inbox_record_escalated() {  # <state-dir> <task-id> <record-path>
  local dir
  dir=$(fm_task_inbox_dir "$1" "$2")
  [ -d "$dir" ] || return 0
  if ! { printf '%s\n' "${3##*/}" > "$dir/.escalated"; } 2>/dev/null; then
    [ -d "$dir" ] || return 0
    return 1
  fi
}
