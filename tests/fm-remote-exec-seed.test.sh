#!/usr/bin/env bash
# End-to-end seed of a headless execution home over the deterministic generic
# SSH boundary: the seed records the route, gates on the readiness probe, and
# provisions a home with no charter, no board, and a per-route Herdr session.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
TMP_ROOT=$(fm_test_tmproot fm-remote-exec-seed)
mkdir -p "$TMP_ROOT"
TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)
PARENT="$TMP_ROOT/parent"
REMOTE_ROOT="$TMP_ROOT/remote-root"
REMOTE_HOME="$TMP_ROOT/remote-home"
FAKEBIN=$(fm_fakebin "$TMP_ROOT/fakebin")
SSH_COUNT="$TMP_ROOT/ssh.count"
ORIGIN="$TMP_ROOT/alpha.git"
SEED_DATE=$(date +%F)
mkdir -p "$PARENT/data" "$PARENT/state" "$PARENT/config" "$PARENT/projects" "$REMOTE_ROOT"
cleanup() {
  local pid
  if [ -f "$TMP_ROOT/remote-jobs/worker.pid" ]; then
    pid=$(cat "$TMP_ROOT/remote-jobs/worker.pid")
    # shellcheck source=bin/fm-remote-job-lib.sh
    . "$ROOT/bin/fm-remote-job-lib.sh"
    FM_REMOTE_JOB_STATE="$TMP_ROOT/remote-jobs"
    fm_remote_job_stop_worker_tree "$pid" 2>/dev/null || true
  fi
  rm -rf -- "$TMP_ROOT"
}
trap cleanup EXIT

(
  cd "$ROOT" || exit
  tar --exclude=.git --exclude=.no-mistakes --exclude=data --exclude=state --exclude=config -cf - .
) | (cd "$REMOTE_ROOT" && tar -xf -)
git -C "$REMOTE_ROOT" init -q -b main
git -C "$REMOTE_ROOT" config user.email test@example.com
git -C "$REMOTE_ROOT" config user.name Test
git -C "$REMOTE_ROOT" add .
git -C "$REMOTE_ROOT" commit -qm 'tracked remote fixture'

git init -q --bare "$ORIGIN"
git -C "$PARENT/projects" init -q -b main scratch
git -C "$PARENT/projects/scratch" config user.email test@example.com
git -C "$PARENT/projects/scratch" config user.name Test
printf 'scratch\n' > "$PARENT/projects/scratch/README.md"
git -C "$PARENT/projects/scratch" add README.md
git -C "$PARENT/projects/scratch" commit -qm init
git -C "$PARENT/projects/scratch" remote add origin "file://$ORIGIN"
git -C "$PARENT/projects/scratch" push -q -u origin main
git --git-dir="$ORIGIN" symbolic-ref HEAD refs/heads/main
cat > "$PARENT/data/projects.md" <<EOF
- scratch [direct-PR] - a fixture scratch project (added $SEED_DATE)
EOF

cat > "$FAKEBIN/fake-ssh" <<'SH'
#!/usr/bin/env bash
count=$(cat "$FM_FAKE_SSH_COUNT" 2>/dev/null || echo 0)
printf '%s\n' "$((count + 1))" > "$FM_FAKE_SSH_COUNT"
while [ "$#" -gt 0 ]; do
  case "$1" in -o) shift 2 ;; --) shift; break ;; *) exit 90 ;; esac
done
host=$1
entry=$2
shift 2
[ "$host" = exec-alias ] || exit 91
case "$entry" in \'/*/bin/fm-remote-entrypoint.sh\') ;; *) exit 92 ;; esac
argv_b64=$4
command_name=$(perl -MMIME::Base64=decode_base64 -e 'print((split(/\0/, decode_base64($ARGV[0])))[0])' "$argv_b64")
# The readiness gate is answered here rather than by the real doctor, which
# would inspect and repair the RUNNER's own account. The real doctor's
# execution-home wording is asserted below against the real binary; this
# boundary owns only what the seed does with a ready verdict.
if [ "$command_name" = fm-remote-doctor.sh ]; then
  perl -MMIME::Base64=decode_base64 -e 'print join(" ", split(/\0/, decode_base64($ARGV[0]))), "\n"' "$argv_b64" \
    >> "$FM_FAKE_DOCTOR_ARGV"
  printf 'ok: remote execution-home readiness confirmed on this host\n'
  exit 0
fi
cd "$FM_FAKE_REMOTE_CWD" || exit 93
exec "$FM_FAKE_REMOTE_ENTRYPOINT" "$@"
SH
chmod +x "$FAKEBIN/fake-ssh"

export FM_HOME="$PARENT"
export FM_ROOT_OVERRIDE="$REMOTE_ROOT"
export FM_SSH_BIN="$FAKEBIN/fake-ssh"
export FM_FAKE_SSH_COUNT="$SSH_COUNT"
export FM_FAKE_DOCTOR_ARGV="$TMP_ROOT/doctor.argv"
export FM_FAKE_REMOTE_CWD="$REMOTE_ROOT/bin"
export FM_FAKE_REMOTE_ENTRYPOINT="$REMOTE_ROOT/bin/fm-remote-entrypoint.sh"
export FM_REMOTE_JOB_STATE_ROOT="$TMP_ROOT/remote-jobs"
export FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux

seed() { "$REMOTE_ROOT/bin/fm-remote-home-seed.sh" "$@" 2>"$TMP_ROOT/seed.err"; }
ssh_count() { cat "$SSH_COUNT" 2>/dev/null || echo 0; }

seed --exec --session lab-x execone exec-alias "$REMOTE_ROOT" "$REMOTE_HOME" scratch > "$TMP_ROOT/seed.out" \
  || fail "the execution-home seed failed: $(cat "$TMP_ROOT/seed.err")"
assert_contains "$(cat "$TMP_ROOT/seed.out")" "provisioned: $REMOTE_HOME projects=1" \
  "the seed did not report the provisioned execution home"
pass "fm-remote-exec-seed: --exec seeds the route and reports the provisioned home"

[ -s "$FM_FAKE_DOCTOR_ARGV" ] || fail "the seed ran no readiness doctor"
if grep -v -e '--session lab-x' "$FM_FAKE_DOCTOR_ARGV" >/dev/null; then
  fail "a readiness doctor run did not ask about session lab-x: $(cat "$FM_FAKE_DOCTOR_ARGV")"
fi
pass "fm-remote-exec-seed: the readiness doctor checks the seeded session, not the default one"

REG="$PARENT/data/remote-homes.md"
[ -f "$REG" ] || fail "the seed wrote no execution-home registry"
[ "$(grep -c '^- execone ' "$REG")" = 1 ] || fail "the registry holds no single execone record: $(cat "$REG")"
# shellcheck source=bin/fm-remote-registry-lib.sh
. "$ROOT/bin/fm-remote-registry-lib.sh"
[ "$(fm_remote_registry_field "$REG" execone host)" = exec-alias ] || fail "the registry host misrecorded"
[ "$(fm_remote_registry_field "$REG" execone root)" = "$REMOTE_ROOT" ] || fail "the registry root misrecorded"
[ "$(fm_remote_registry_field "$REG" execone home)" = "$REMOTE_HOME" ] || fail "the registry home misrecorded"
[ "$(fm_remote_registry_field "$REG" execone session)" = lab-x ] || fail "the registry session misrecorded"
[ "$(fm_remote_registry_field "$REG" execone projects)" = scratch ] || fail "the registry projects misrecorded"
pass "fm-remote-exec-seed: the registry records the route with its per-route session"

[ "$(cat "$REMOTE_HOME/.fm-exec-home")" = execone ] || fail "the execution marker misrecorded"
[ "$(cat "$REMOTE_HOME/config/backlog-backend")" = manual ] || fail "the execution home did not opt out of the task board"
[ "$(cat "$REMOTE_HOME/config/herdr-session")" = lab-x ] || fail "the execution home did not record its Herdr session"
[ -d "$REMOTE_HOME/projects/scratch/.git" ] || fail "the execution home did not clone its project"
[ -d "$REMOTE_HOME/.git" ] || fail "the execution home is not a Firstmate checkout"
[ -e "$REMOTE_HOME/data/charter.md" ] && fail "the execution home scaffolded a charter it never reads"
grep -q '^- scratch ' "$REMOTE_HOME/data/projects.md" || fail "the execution home lost its project record"
[ -e "$REMOTE_HOME/config/lavish-axi-supervisor-address" ] \
  && fail "a seed without --lavish-address wrote a supervisor Lavish address"
pass "fm-remote-exec-seed: the provisioned home is headless, boardless, and bound to its session"

out=$(FM_HOME="$PARENT" "$REMOTE_ROOT/bin/fm-on.sh" execone fm-remote-doctor.sh 2>"$TMP_ROOT/seed.err") \
  || fail "the seeded route did not carry the readiness probe: $(cat "$TMP_ROOT/seed.err")"
assert_contains "$out" "ok: remote execution-home readiness confirmed on this host" \
  "the readiness probe did not travel the seeded route"
pass "fm-remote-exec-seed: the seeded route carries the readiness probe"

out=$(FM_HOME="$PARENT" "$REMOTE_ROOT/bin/fm-on.sh" execone fm-remote-file.sh get config/backlog-backend 2>"$TMP_ROOT/seed.err") \
  || fail "the seeded route did not carry the file read: $(cat "$TMP_ROOT/seed.err")"
[ "$out" = manual ] || fail "the remote file read returned '$out' instead of manual"
pass "fm-remote-exec-seed: the seeded route reads the remote backlog backend as manual"

before=$(ssh_count)
seed --exec execone exec-alias "$REMOTE_ROOT" "$TMP_ROOT/remote-other" scratch > "$TMP_ROOT/seed.out" 2>"$TMP_ROOT/seed.err" \
  && fail "an id already bound to a different home reseeded instead of being refused"
assert_contains "$(cat "$TMP_ROOT/seed.err")" "already registered to a different" "the duplicate refusal did not name the binding"
[ "$(ssh_count)" = "$before" ] || fail "a refused duplicate id dialed the host"
[ "$(grep -c '^- execone ' "$REG")" = 1 ] || fail "a refused duplicate rewrote the registry"
pass "fm-remote-exec-seed: an id bound to a different home is refused without dialing"

before=$(ssh_count)
seed --exec --session 'bad name' badid exec-alias "$REMOTE_ROOT" "$TMP_ROOT/remote-bad" scratch > "$TMP_ROOT/seed.out" 2>"$TMP_ROOT/seed.err" \
  && fail "an unsafe session seeded instead of being refused"
[ "$(ssh_count)" = "$before" ] || fail "a refused session dialed the host"
[ -f "$PARENT/data/remote-homes.md" ] && grep -q '^- badid ' "$REG" && fail "a refused session wrote a registry record"
pass "fm-remote-exec-seed: an unsafe session is refused before anything is written or dialed"

seed --exec --session lab-x execone exec-alias "$REMOTE_ROOT" "$REMOTE_HOME" scratch > "$TMP_ROOT/seed.out" 2>"$TMP_ROOT/seed.err" \
  || fail "a same-route rerun stopped converging: $(cat "$TMP_ROOT/seed.err")"
[ "$(grep -c '^- execone ' "$REG")" = 1 ] || fail "a same-route rerun duplicated the registry record"
pass "fm-remote-exec-seed: a same-route rerun converges with a single registry record"

SUPERVISOR_LAVISH=127.0.0.1:24387
seed --exec --session lab-x --lavish-address "$SUPERVISOR_LAVISH" execone exec-alias "$REMOTE_ROOT" "$REMOTE_HOME" scratch \
  > "$TMP_ROOT/seed.out" 2>"$TMP_ROOT/seed.err" \
  || fail "a rerun with --lavish-address failed: $(cat "$TMP_ROOT/seed.err")"
[ "$(cat "$REMOTE_HOME/config/lavish-axi-supervisor-address")" = "$SUPERVISOR_LAVISH" ] \
  || fail "the execution home did not record the supervisor Lavish address"
assert_contains "$(cat "$TMP_ROOT/seed.out")" "lavish-address: $SUPERVISOR_LAVISH" \
  "the seed did not report the recorded supervisor Lavish address"
seed --exec --session lab-x execone exec-alias "$REMOTE_ROOT" "$REMOTE_HOME" scratch > "$TMP_ROOT/seed.out" 2>"$TMP_ROOT/seed.err" \
  || fail "a rerun without --lavish-address failed: $(cat "$TMP_ROOT/seed.err")"
[ "$(cat "$REMOTE_HOME/config/lavish-axi-supervisor-address")" = "$SUPERVISOR_LAVISH" ] \
  || fail "a rerun without --lavish-address dropped the recorded supervisor Lavish address"
pass "fm-remote-exec-seed: --lavish-address records the supervisor address and a later rerun keeps it, not drops it"

before=$(ssh_count)
seed --exec --lavish-address 'not-a-port' execone exec-alias "$REMOTE_ROOT" "$REMOTE_HOME" scratch > "$TMP_ROOT/seed.out" 2>"$TMP_ROOT/seed.err" \
  && fail "a malformed --lavish-address seeded instead of being refused"
[ "$(ssh_count)" = "$before" ] || fail "a malformed --lavish-address dialed the host"
pass "fm-remote-exec-seed: a malformed --lavish-address is refused before dialing"

OTHER_HOME="$TMP_ROOT/other-home"
mkdir -p "$OTHER_HOME/bin" "$OTHER_HOME/data" "$REMOTE_ROOT/data"
cp "$REMOTE_ROOT/bin/fm-remote-home-seed.sh" "$OTHER_HOME/bin/"
before=$(ssh_count)
FM_HOME="$OTHER_HOME" seed --exec otherid exec-alias "$REMOTE_ROOT" "$TMP_ROOT/remote-other-home" --no-projects \
  > "$TMP_ROOT/seed.out" 2>"$TMP_ROOT/seed.err" \
  && fail "a seed from a home checkout registered the route in the home FM_HOME names instead of being refused"
assert_contains "$(cat "$TMP_ROOT/seed.err")" "FM_HOME is another home's checkout" "the refusal did not name the conflicting homes"
[ -e "$OTHER_HOME/data/remote-homes.md" ] && fail "the refused seed wrote the other home's registry"
[ -e "$REMOTE_ROOT/data/remote-homes.md" ] && fail "the refused seed wrote its own checkout's registry"
[ "$(ssh_count)" = "$before" ] || fail "a seed refused for its home dialed the host"
pass "fm-remote-exec-seed: FM_HOME naming another home's checkout is refused before anything is written or dialed"

seed --exec --session lab-x execone exec-alias "$REMOTE_ROOT" "$REMOTE_HOME" scratch > "$TMP_ROOT/seed.out" 2>"$TMP_ROOT/seed.err" \
  || fail "a home directory that is not a checkout was refused: $(cat "$TMP_ROOT/seed.err")"
[ "$(grep -c '^- execone ' "$REG")" = 1 ] || fail "the seed into a plain home directory lost its single registry record"
rmdir "$REMOTE_ROOT/data"
pass "fm-remote-exec-seed: FM_HOME naming a plain home directory still seeds from a home checkout"

KINDHOME="$TMP_ROOT/doctor-kind"
mkdir -p "$KINDHOME"
printf 'execone\n' > "$KINDHOME/.fm-exec-home"
exec_out=$(FM_HOME="$KINDHOME" "$ROOT/bin/fm-remote-doctor.sh" 2>&1) || true
assert_contains "$exec_out" "execution home" "the readiness report did not name the execution home kind"
pass "fm-remote-exec-seed: the real readiness report names the home kind it inspected"

echo "# fm-remote-exec-seed.test.sh: all assertions passed"
