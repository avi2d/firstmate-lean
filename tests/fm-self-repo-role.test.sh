#!/usr/bin/env bash
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-role-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-config-inherit-lib.sh"

ROLE="$ROOT/bin/fm-role.sh"
BRIEF="$ROOT/bin/fm-brief.sh"
SPAWN="$ROOT/bin/fm-spawn.sh"
PROMOTE="$ROOT/bin/fm-promote.sh"
TMP_ROOT=$(fm_test_tmproot fm-self-repo-role)
export FM_BACKEND=herdr

# The code root under test is this checkout, so self-repo detection reaches it
# through the shared git common dir. Its publication target is derived, never
# assumed: a checkout with neither a gh-resolved=base remote nor an
# upstream/github/origin remote resolves to the undeterminable path and the
# scope-bound cases adapt.
PUB_TARGET=$(fm_role_publication_target "$ROOT")
ORIGIN_URL=$(git -C "$ROOT" remote get-url upstream 2>/dev/null) \
  || ORIGIN_URL=$(git -C "$ROOT" remote get-url github 2>/dev/null) \
  || ORIGIN_URL=$(git -C "$ROOT" remote get-url origin 2>/dev/null) \
  || ORIGIN_URL=

# make_role_home <name> [<role-file-content>]: a bare home whose only contents
# are config/ (optionally holding firstmate-role) plus the state/ and data/
# dirs the other consumers expect. Echoes the home path.
make_role_home() {
  local name=$1 content=${2-} home
  home="$TMP_ROOT/$name"
  mkdir -p "$home/config" "$home/state" "$home/data"
  if [ $# -ge 2 ]; then
    printf '%s\n' "$content" > "$home/config/firstmate-role"
  fi
  printf '%s\n' "$home"
}

# git_commit <repo> <msg> - an empty commit with a fixed fixture identity.
git_commit() {
  git -C "$1" -c user.name=fixture -c user.email=fixture@example.invalid \
    commit -q --allow-empty -m "$2" || fail "could not commit in $1"
}

# make_lineage_root <name> <origin-url> - a fixture firstmate code root with
# two commits and the given origin. Echoes its path.
make_lineage_root() {
  local root="$TMP_ROOT/$1"
  git init -q "$root" || fail "could not initialize $1 fixture"
  git_commit "$root" root
  git_commit "$root" second
  git -C "$root" remote add origin "$2"
  printf '%s\n' "$root"
}

# clone_with_origin <src> <name> <origin-url> - a separate clone of <src>
# (its own git dir, full history) whose origin is rewritten. Echoes its path.
clone_with_origin() {
  local clone="$TMP_ROOT/$2"
  git clone -q --shared --no-checkout "$1" "$clone" || fail "could not clone $1"
  git -C "$clone" remote set-url origin "$3"
  printf '%s\n' "$clone"
}

# check_as <code-root> <home> <args...> - fm-role.sh check against a fixture
# code root.
check_as() {
  local root=$1 home=$2
  shift 2
  FM_ROOT_OVERRIDE="$root" FM_HOME="$home" FM_CONFIG_OVERRIDE="$home/config" \
    "$ROLE" check "$@" 2>&1
}

# run_role <home> <args...> - fm-role.sh pinned to a fixture home. FM_ROOT stays
# this checkout: the check command exists to compare a task's project against
# the running code root.
run_role() {
  local home=$1
  shift
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_CONFIG_OVERRIDE="$home/config" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$home/data" \
    "$ROLE" "$@" 2>&1
}

# --- report -----------------------------------------------------------------

test_report_default_and_local_grants() {
  local home out
  home=$(make_role_home report-default)
  out=$(run_role "$home" report)
  assert_equals "fm-role: user (default)" "$out" "an unconfigured home must report the user default"

  home=$(make_role_home report-user 'user')
  out=$(run_role "$home" report)
  assert_equals "fm-role: user (local)" "$out" "an explicit user directive must report user from the local file"

  home=$(make_role_home report-maint 'maintainer GitHub.COM/Org/Repo')
  out=$(run_role "$home" report)
  assert_equals "fm-role: maintainer github.com/org/repo (local)" "$out" \
    "a maintainer directive must report normalized scopes from the local file"
  pass "fm-role.sh report: default, user, and maintainer directives resolve"
}

test_report_fails_closed_on_unsafe_input() {
  local home out
  home=$(make_role_home report-bad1 'maintainer')
  out=$(run_role "$home" report)
  assert_contains "$out" "fm-role: user" "a scope-less maintainer directive must resolve to user"
  assert_contains "$out" "malformed role file" "a scope-less maintainer directive must report the narrow problem"

  home=$(make_role_home report-bad2 'admin github.com/a/b')
  out=$(run_role "$home" report)
  assert_contains "$out" "fm-role: user" "an unknown role must resolve to user"
  assert_contains "$out" "unknown role 'admin'" "an unknown role must name itself in the reason"

  home=$(make_role_home report-bad3 'maintainer ../escape')
  out=$(run_role "$home" report)
  assert_contains "$out" "fm-role: user" "an invalid scope must resolve to user"
  assert_contains "$out" "invalid repository scope" "an invalid scope must name the narrow problem"

  home=$(make_role_home report-symlink)
  printf 'maintainer github.com/a/b\n' > "$TMP_ROOT/report-symlink-target"
  ln -s "$TMP_ROOT/report-symlink-target" "$home/config/firstmate-role"
  out=$(run_role "$home" report)
  assert_contains "$out" "fm-role: user" "a symlinked role file must resolve to user"
  assert_contains "$out" "must not be a symlink" "a symlinked role file must report the narrow problem"

  home=$(make_role_home report-two-directives "$(printf 'maintainer github.com/kunchenguid/firstmate\n# trailing\nuser')")
  out=$(run_role "$home" report)
  assert_contains "$out" "fm-role: user" "a later directive must make the whole file malformed, not be ignored"
  assert_contains "$out" "exactly one directive line" "a second directive must name the narrow problem"

  home=$(make_role_home report-two-scopes 'maintainer github.com/kunchenguid/firstmate github.com/other/firstmate')
  out=$(run_role "$home" report)
  assert_contains "$out" "fm-role: user" "a maintainer directive naming two scopes must resolve to user"
  assert_contains "$out" "exactly one repository scope" "a multi-scope directive must name the narrow problem"
  pass "fm-role.sh report: malformed, unknown, and unsafe input fails closed"
}

# --- check: the self-repository publication gate ----------------------------

test_check_user_home_refused_on_self_repo() {
  local home out rc
  home=$(make_role_home check-user)
  out=$(run_role "$home" check "$ROOT"); rc=$?
  expect_code 1 "$rc" "a user/operator home must be refused a publishing contract on firstmate itself"
  assert_contains "$out" "user/operator" "the refusal must name the role"
  assert_contains "$out" "no publication authority" "the refusal must name the missing grant"
  pass "fm-role.sh check: the default user/operator home cannot publish to firstmate upstream"
}

test_check_foreign_project_passes_through() {
  local home proj out rc
  home=$(make_role_home check-foreign)
  proj="$TMP_ROOT/foreign-proj"
  git init -q "$proj" || fail "could not initialize foreign project fixture"
  git -C "$proj" remote add origin https://github.com/someone/elseware.git
  out=$(run_role "$home" check "$proj"); rc=$?
  expect_code 2 "$rc" "an ordinary project must not be gated at all"
  assert_contains "$out" "not a self-repository task" "an ordinary project must be reported as outside the boundary"
  pass "fm-role.sh check: a task on an ordinary project is untouched by the boundary"
}

test_check_maintainer_scope_authorizes() {
  local home out rc
  [ -n "$PUB_TARGET" ] || {
    printf '# skip - checkout has no upstream/github/origin remote to scope\n'
    return
  }
  home=$(make_role_home check-maint "maintainer $PUB_TARGET")
  out=$(run_role "$home" check "$ROOT"); rc=$?
  expect_code 0 "$rc" "a matching maintainer scope must authorize (got: $out)"
  assert_contains "$out" "authorized: maintainer scope $PUB_TARGET" "the authority must name the matched scope"

  home=$(make_role_home check-maint-case "maintainer $(printf '%s' "$PUB_TARGET" | tr '[:lower:]' '[:upper:]')")
  out=$(run_role "$home" check "$ROOT"); rc=$?
  expect_code 0 "$rc" "scope comparison must be case-insensitive (got: $out)"
  pass "fm-role.sh check: a matching maintainer scope authorizes the self-repository publication"
}

test_check_wrong_scope_and_remote_presence_do_not_authorize() {
  local home clone out rc
  [ -n "$PUB_TARGET" ] || {
    printf '# skip - checkout has no upstream/github/origin remote to scope\n'
    return
  }
  # A maintainer grant for a different repository is no authority here, even
  # though the project's own remote IS the real upstream: role is never
  # inferred from the remote itself.
  home=$(make_role_home check-other 'maintainer github.com/other/firstmate')
  out=$(run_role "$home" check "$ROOT"); rc=$?
  expect_code 1 "$rc" "a non-matching maintainer scope must be refused"
  assert_contains "$out" "no publication authority for $PUB_TARGET" \
    "the refusal must name the target the grant did not cover"

  # A second clone of the same upstream (shared history, different git dir)
  # is still firstmate's repository: the boundary follows lineage, not the
  # checkout path.
  home=$(make_role_home check-clone)
  clone=$(clone_with_origin "$ROOT" second-clone "$ORIGIN_URL")
  out=$(run_role "$home" check "$clone"); rc=$?
  expect_code 1 "$rc" "a second clone of the same upstream must still be gated"
  assert_contains "$out" "user/operator" "a second clone must be treated as firstmate's own repository"
  pass "fm-role.sh check: scope mismatch and mere upstream remote presence never authorize"
}

# Equivalent remote spellings of one upstream (trailing slash, .git suffix,
# scp form) must normalize to one publication target, so the maintainer scope
# matches every clone. The code root is a fixture, independent of this
# checkout's own remotes.
test_check_equivalent_remote_spellings_are_one_repo() {
  local root clone url user_home maint_home out rc n=0
  root=$(make_lineage_root spelling-root https://github.com/kunchenguid/firstmate)
  user_home=$(make_role_home spelling-user)
  maint_home=$(make_role_home spelling-maint 'maintainer github.com/kunchenguid/firstmate')
  for url in https://github.com/kunchenguid/firstmate.git/ \
    https://github.com/kunchenguid/firstmate/ \
    git@github.com:kunchenguid/firstmate.git/; do
    n=$((n + 1))
    clone=$(clone_with_origin "$root" "spelling-clone-$n" "$url")
    out=$(check_as "$root" "$user_home" "$clone"); rc=$?
    expect_code 1 "$rc" "a clone of $url must be gated as firstmate (got: $out)"
    out=$(check_as "$root" "$maint_home" "$clone"); rc=$?
    expect_code 0 "$rc" "the maintainer scope must cover a clone of $url (got: $out)"
  done
  pass "fm-role.sh check: equivalent remote spellings resolve to one publication target"
}

# Firstmate run from a fork, dispatching to a separate clone of the parent:
# their origins and git dirs differ, but they share firstmate's root commit,
# so the task still meets the role/consent gate. A fork's maintainer scope
# does not cover the parent; one-task consent for the parent does.
test_check_fork_lineage_reaches_the_gate() {
  local fork parent user_home fork_home out rc
  fork=$(make_lineage_root fork-root https://github.com/someone/firstmate-fork)
  parent=$(clone_with_origin "$fork" parent-clone https://github.com/kunchenguid/firstmate)
  user_home=$(make_role_home fork-user)
  out=$(check_as "$fork" "$user_home" "$parent"); rc=$?
  expect_code 1 "$rc" "a parent clone dispatched from a fork code root must be gated (got: $out)"
  assert_contains "$out" "no publication authority for github.com/kunchenguid/firstmate" \
    "the refusal must name the parent publication target"

  fork_home=$(make_role_home fork-maint 'maintainer github.com/someone/firstmate-fork')
  out=$(check_as "$fork" "$fork_home" "$parent"); rc=$?
  expect_code 1 "$rc" "a fork maintainer scope must not cover the parent (got: $out)"

  out=$(check_as "$fork" "$user_home" "$parent" upstream-consent github.com/kunchenguid/firstmate); rc=$?
  expect_code 0 "$rc" "one-task consent for the parent must authorize (got: $out)"

  git init -q "$TMP_ROOT/fork-unrelated" || fail "could not initialize unrelated fixture"
  git_commit "$TMP_ROOT/fork-unrelated" unrelated
  git -C "$TMP_ROOT/fork-unrelated" remote add origin https://github.com/kunchenguid/firstmate
  out=$(check_as "$fork" "$user_home" "$TMP_ROOT/fork-unrelated"); rc=$?
  expect_code 2 "$rc" "an unrelated history is not firstmate even with a firstmate remote (got: $out)"
  pass "fm-role.sh check: repository lineage, not remotes, identifies firstmate across forks"
}

# gh repo set-default outranks the upstream remote, as it does for gh itself,
# in both recorded forms: base, and an explicit owner/repo.
test_check_gh_default_outranks_upstream() {
  local root proj user_home fork_home out rc
  root=$(make_lineage_root ghdef-root https://github.com/someone/firstmate-fork)
  proj=$(clone_with_origin "$root" ghdef-clone https://github.com/someone/firstmate-fork)
  git -C "$proj" remote add upstream https://github.com/kunchenguid/firstmate
  user_home=$(make_role_home ghdef-user)
  fork_home=$(make_role_home ghdef-maint 'maintainer github.com/someone/firstmate-fork')

  out=$(check_as "$root" "$fork_home" "$proj"); rc=$?
  expect_code 1 "$rc" "with no recorded default the upstream remote must be the target (got: $out)"
  assert_contains "$out" "no publication authority for github.com/kunchenguid/firstmate" \
    "with no recorded default the refusal must name the upstream target"

  git -C "$proj" config remote.origin.gh-resolved base
  out=$(check_as "$root" "$user_home" "$proj"); rc=$?
  expect_code 1 "$rc" "a recorded default must not authorize a user home (got: $out)"
  assert_contains "$out" "no publication authority for github.com/someone/firstmate-fork" \
    "a base default must make the fork the target"
  out=$(check_as "$root" "$fork_home" "$proj"); rc=$?
  expect_code 0 "$rc" "the fork maintainer scope must cover a fork chosen as gh default (got: $out)"

  git -C "$proj" config remote.origin.gh-resolved kunchenguid/firstmate
  out=$(check_as "$root" "$fork_home" "$proj"); rc=$?
  expect_code 1 "$rc" "an owner/repo default naming the parent must not be covered by the fork scope (got: $out)"
  assert_contains "$out" "no publication authority for github.com/kunchenguid/firstmate" \
    "an owner/repo default must name that repository as the target"
  pass "fm-role.sh check: the gh repo set-default choice is the publication target"
}

# A fetch-only parent remote must not override gh's explicitly selected fork.
# Without the selection marker the existing upstream/github/origin order holds.
test_check_gh_resolved_base_selects_fork() {
  local fork user_home fork_home out rc
  fork=$(make_lineage_root resolved-fork https://github.com/someone/firstmate-fork)
  git -C "$fork" remote add upstream https://github.com/kunchenguid/firstmate
  user_home=$(make_role_home resolved-user)
  fork_home=$(make_role_home resolved-maint 'maintainer github.com/someone/firstmate-fork')

  out=$(check_as "$fork" "$fork_home" "$fork"); rc=$?
  expect_code 1 "$rc" "without a marker the fork scope must not cover upstream (got: $out)"
  assert_contains "$out" "no publication authority for github.com/kunchenguid/firstmate" \
    "without a marker upstream must remain the publication target"
  out=$(check_as "$fork" "$user_home" "$fork" upstream-consent github.com/kunchenguid/firstmate); rc=$?
  expect_code 0 "$rc" "without a marker consent for upstream must authorize (got: $out)"

  git -C "$fork" config remote.origin.gh-resolved base
  out=$(check_as "$fork" "$fork_home" "$fork"); rc=$?
  expect_code 0 "$rc" "the selected fork maintainer scope must authorize (got: $out)"
  out=$(check_as "$fork" "$user_home" "$fork" upstream-consent github.com/someone/firstmate-fork); rc=$?
  expect_code 0 "$rc" "consent for the selected fork must authorize (got: $out)"
  out=$(check_as "$fork" "$user_home" "$fork" upstream-consent github.com/kunchenguid/firstmate); rc=$?
  expect_code 1 "$rc" "parent consent must not cover the selected fork (got: $out)"

  git -C "$fork" remote rename origin publishing
  out=$(check_as "$fork" "$fork_home" "$fork"); rc=$?
  expect_code 0 "$rc" "the base marker must work on a custom remote name (got: $out)"
  git -C "$fork" config remote.publishing.gh-resolved head
  out=$(check_as "$fork" "$fork_home" "$fork"); rc=$?
  expect_code 1 "$rc" "a non-base marker must not select the fork (got: $out)"
  assert_contains "$out" "no publication authority for github.com/kunchenguid/firstmate" \
    "a non-base marker must preserve upstream precedence"

  git -C "$fork" config remote.publishing.gh-resolved base
  git -C "$fork" remote set-url publishing "$TMP_ROOT/unreadable-target"
  out=$(check_as "$fork" "$user_home" "$fork" upstream-consent github.com/kunchenguid/firstmate); rc=$?
  expect_code 1 "$rc" "an unreadable selected target must not fall back to authorized upstream (got: $out)"
  git -C "$fork" config --unset remote.publishing.url
  out=$(check_as "$fork" "$user_home" "$fork" upstream-consent github.com/kunchenguid/firstmate); rc=$?
  expect_code 1 "$rc" "a selected remote without a URL must not fall back to authorized upstream (got: $out)"
  pass "fm-role.sh check: gh-resolved base selects the exact fork target, otherwise legacy precedence holds"
}

# Lineage that cannot be determined refuses, and a firstmate-lineage project
# with no determinable publication target is refused even under consent.
test_check_undeterminable_lineage_and_target_refuse() {
  local root shallow bare home out rc
  root=$(make_lineage_root undet-root https://github.com/kunchenguid/firstmate)
  home=$(make_role_home undet-user)
  shallow="$TMP_ROOT/undet-shallow"
  git clone -q --depth 1 "file://$root" "$shallow" || fail "could not make a shallow clone"
  git -C "$shallow" remote set-url origin https://github.com/kunchenguid/firstmate
  out=$(check_as "$root" "$home" "$shallow" upstream-consent github.com/kunchenguid/firstmate); rc=$?
  expect_code 1 "$rc" "a shallow clone sharing no root commit must be refused (got: $out)"
  assert_contains "$out" "cannot determine whether" "the refusal must name undeterminable lineage"

  bare=$(clone_with_origin "$root" undet-no-remote https://github.com/kunchenguid/firstmate)
  git -C "$bare" remote remove origin
  out=$(check_as "$root" "$home" "$bare" upstream-consent github.com/kunchenguid/firstmate); rc=$?
  expect_code 1 "$rc" "consent must not authorize an undeterminable publication target (got: $out)"
  assert_contains "$out" "no publication target can be determined" "the refusal must name the missing target"
  pass "fm-role.sh check: undeterminable lineage or publication target refuses"
}

test_check_task_consent_authorizes_one_task() {
  local home out rc
  [ -n "$PUB_TARGET" ] || {
    printf '# skip - checkout has no upstream/github/origin remote to scope\n'
    return
  }
  home=$(make_role_home check-consent)
  out=$(run_role "$home" check "$ROOT" upstream-consent "$PUB_TARGET"); rc=$?
  expect_code 0 "$rc" "a matching one-task consent must authorize a user home (got: $out)"
  assert_contains "$out" "authorized: task consent for $PUB_TARGET" "the authority must be recorded as task consent"

  out=$(run_role "$home" check "$ROOT" upstream-consent github.com/other/repo); rc=$?
  expect_code 1 "$rc" "a consent naming a different repository must be refused"
  assert_contains "$out" "no publication authority for $PUB_TARGET" \
    "a mismatched consent must not widen into a grant"
  pass "fm-role.sh check: recorded one-task consent authorizes its named repository only"
}

# --- delivery contract rendering --------------------------------------------

test_dod_block_renders_and_bounds_consent() {
  local out rc
  # shellcheck source=/dev/null
  . "$ROOT/bin/fm-dod-lib.sh"
  out=$(fm_dod_block direct-PR consent-id fm/consent-id none '' github.com/kunchenguid/firstmate)
  assert_contains "$out" "Delivery contract: mode=direct-PR upstream-consent=github.com/kunchenguid/firstmate" \
    "a publishing contract must render the recorded consent token"
  out=$(fm_dod_block direct-PR noconsent-id fm/noconsent-id)
  assert_not_contains "$out" "upstream-consent" "a contract without consent must not render the token"
  out=$(fm_dod_block local-only local-id fm/local-id none '' github.com/a/b 2>&1); rc=$?
  expect_code 1 "$rc" "local-only must refuse a consent token it can never spend"
  pass "fm_dod_block: upstream consent renders on publishing contracts and is refused on local-only"
}

# --- fm-brief.sh ------------------------------------------------------------

test_brief_consent_flag_bounds() {
  local home out rc brief
  home=$(make_role_home brief-user)
  brief="$home/data/brief-consent-ok/brief.md"

  out=$(FM_HOME="$home" FM_CONFIG_OVERRIDE="$home/config" FM_DATA_OVERRIDE="$home/data" \
    "$BRIEF" brief-consent-bad some-proj --mode direct-PR --upstream-consent 'not a scope' 2>&1); rc=$?
  expect_code 1 "$rc" "an invalid consent scope must be refused"
  assert_contains "$out" "must be <host>/<owner>/<repo>" "an invalid consent scope must name the schema"

  out=$(FM_HOME="$home" FM_CONFIG_OVERRIDE="$home/config" FM_DATA_OVERRIDE="$home/data" \
    "$BRIEF" brief-consent-scout some-proj --scout --upstream-consent github.com/a/b 2>&1); rc=$?
  expect_code 1 "$rc" "a scout must refuse a consent it can never spend"
  assert_contains "$out" "applies only to ship briefs" "a scout consent refusal must name the boundary"

  out=$(FM_HOME="$home" FM_CONFIG_OVERRIDE="$home/config" FM_DATA_OVERRIDE="$home/data" \
    "$BRIEF" brief-consent-local some-proj --mode local-only --upstream-consent github.com/a/b 2>&1); rc=$?
  expect_code 1 "$rc" "local-only must refuse a consent it publishes nothing with"
  assert_contains "$out" "local-only" "a local-only consent refusal must name the mode"

  out=$(FM_HOME="$home" FM_CONFIG_OVERRIDE="$home/config" FM_DATA_OVERRIDE="$home/data" \
    "$BRIEF" brief-consent-ok some-proj --mode direct-PR --upstream-consent GitHub.COM/KunChenGuid/FirstMate 2>&1); rc=$?
  expect_code 0 "$rc" "a valid consent must scaffold (got: $out)"
  assert_grep "upstream-consent=github.com/kunchenguid/firstmate" "$brief" \
    "the scaffolded brief must carry the normalized consent token"
  pass "fm-brief.sh: --upstream-consent validates, scopes to ship tasks, and renders normalized"
}

test_brief_self_repo_pre_gate() {
  local home out rc
  home=$(make_role_home brief-selfrepo)
  out=$(FM_HOME="$home" FM_CONFIG_OVERRIDE="$home/config" FM_DATA_OVERRIDE="$home/data" \
    "$BRIEF" brief-selfrefuse some-proj --mode direct-PR --project "$ROOT" 2>&1); rc=$?
  expect_code 1 "$rc" "a user home must be refused a publishing brief for firstmate itself"
  assert_contains "$out" "user/operator" "the refusal must name the role"
  assert_contains "$out" "no publication authority" "the refusal must name the missing grant"

  if [ -n "$PUB_TARGET" ]; then
    out=$(FM_HOME="$home" FM_CONFIG_OVERRIDE="$home/config" FM_DATA_OVERRIDE="$home/data" \
      "$BRIEF" brief-selfconsent some-proj --mode direct-PR --project "$ROOT" \
      --upstream-consent "$PUB_TARGET" 2>&1); rc=$?
    expect_code 0 "$rc" "recorded consent must let the same scaffold through (got: $out)"
    assert_grep "upstream-consent=$PUB_TARGET" "$home/data/brief-selfconsent/brief.md" \
      "the consented scaffold must record the consent"
  fi

  home=$(make_role_home brief-maint "maintainer ${PUB_TARGET:-github.com/x/y}")
  if [ -n "$PUB_TARGET" ]; then
    out=$(FM_HOME="$home" FM_CONFIG_OVERRIDE="$home/config" FM_DATA_OVERRIDE="$home/data" \
      "$BRIEF" brief-selfmaint some-proj --mode direct-PR --project "$ROOT" 2>&1); rc=$?
    expect_code 0 "$rc" "a matching maintainer home must scaffold a self-repo publishing brief (got: $out)"
  fi
  pass "fm-brief.sh: --project applies the self-repository gate at scaffold time"
}

# --- fm-spawn.sh ------------------------------------------------------------

# A thin spawn fixture: home, a project arg resolved to the code root itself,
# and a brief whose delivery contract the spawn must agree with. The fake Herdr
# exits 1 so an authorized spawn stops at launch rather than a worktree.
SPAWN_FAKEBIN="$TMP_ROOT/spawn-fakebin"
mkdir -p "$SPAWN_FAKEBIN"
printf '#!/bin/sh\nexit 1\n' > "$SPAWN_FAKEBIN/herdr"
chmod +x "$SPAWN_FAKEBIN/herdr"
fm_fake_exit0 "$SPAWN_FAKEBIN" pi

write_ship_brief() {  # <home> <id> [<contract-extras>]
  local home=$1 id=$2 extras=${3:-}
  mkdir -p "$home/data/$id"
  {
    printf 'You are a crewmate.\n\n# Task\n## Captain'\''s intent\nExercise the role gate.\n\n## Firstmate spec\nVerify the boundary.\n\n# Definition of done\n'
    printf 'Delivery contract: mode=no-mistakes%s\nShip branch: fm/%s\n' "$extras" "$id"
  } > "$home/data/$id/brief.md"
}

run_spawn() {  # <home> <spawn-args...>
  local home=$1
  shift
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$TMP_ROOT/projects-unused" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_BACKEND=herdr PATH="$SPAWN_FAKEBIN:$BASE_PATH" \
    "$SPAWN" "$@" 2>&1
}
BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}

test_spawn_gate_on_self_repo() {
  local home out rc
  home=$(make_role_home spawn-user)
  write_ship_brief "$home" spawn-self-a1
  out=$(run_spawn "$home" spawn-self-a1 "$ROOT" pi --mode no-mistakes --yolo off); rc=$?
  [ "$rc" -ne 0 ] || fail "a user home must not launch a publishing task on firstmate itself"
  assert_contains "$out" "spawn refused for spawn-self-a1" "the refusal must name the task"
  assert_contains "$out" "user/operator" "the refusal must name the role"
  assert_absent "$home/state/spawn-self-a1.meta" "a refused spawn must write no task metadata"

  if [ -n "$PUB_TARGET" ]; then
    home=$(make_role_home spawn-maint "maintainer $PUB_TARGET")
    write_ship_brief "$home" spawn-self-a2
    out=$(run_spawn "$home" spawn-self-a2 "$ROOT" pi --mode no-mistakes --yolo off)
    assert_not_contains "$out" "spawn refused" "a matching maintainer home must pass the gate"
    assert_not_contains "$out" "user/operator" "a matching maintainer home must not be told it lacks authority"
  fi
  pass "fm-spawn.sh: the launch gate refuses a user/operator home and passes a matching maintainer"
}

test_spawn_consent_agreement() {
  local home out rc
  [ -n "$PUB_TARGET" ] || {
    printf '# skip - checkout has no upstream/github/origin remote to scope\n'
    return
  }
  home=$(make_role_home spawn-consent)

  # Consent on the flag but not the brief: the two sides of the record must
  # agree, or the worker's contract and the task's authority diverge.
  write_ship_brief "$home" spawn-consent-b1
  rc=0
  out=$(run_spawn "$home" spawn-consent-b1 "$ROOT" pi --mode no-mistakes --yolo off \
    --upstream-consent "$PUB_TARGET") || rc=$?
  [ "$rc" -ne 0 ] || fail "a flag-without-brief consent must refuse"
  assert_contains "$out" "upstream-consent mismatch for spawn-consent-b1" \
    "a flag without a matching brief token must refuse"
  assert_absent "$home/state/spawn-consent-b1.meta" "a mismatched spawn must write no metadata"

  # Consent on the brief but not the flag: same divergence, other direction.
  write_ship_brief "$home" spawn-consent-b2 " upstream-consent=$PUB_TARGET"
  rc=0
  out=$(run_spawn "$home" spawn-consent-b2 "$ROOT" pi --mode no-mistakes --yolo off) || rc=$?
  [ "$rc" -ne 0 ] || fail "a brief-without-flag consent must refuse"
  assert_contains "$out" "upstream-consent mismatch for spawn-consent-b2" \
    "a brief token without the flag must refuse"

  # Both sides agree: the consent carries the task through the gate on a
  # user/operator home.
  write_ship_brief "$home" spawn-consent-b3 " upstream-consent=$PUB_TARGET"
  out=$(run_spawn "$home" spawn-consent-b3 "$ROOT" pi --mode no-mistakes --yolo off \
    --upstream-consent "$PUB_TARGET")
  assert_not_contains "$out" "spawn refused" "matching consent must pass the gate"
  assert_not_contains "$out" "upstream-consent mismatch" "agreeing sides must not be reported as a mismatch"

  # Consent on a foreign project is harmless: the boundary does not apply and
  # the spawn passes the gate to whatever fails after.
  local proj="$TMP_ROOT/consent-foreign"
  git init -q "$proj" || fail "could not initialize foreign fixture"
  git_commit "$proj" init
  git -C "$proj" remote add origin https://github.com/someone/elseware.git
  write_ship_brief "$home" spawn-consent-b4 " upstream-consent=$PUB_TARGET"
  out=$(run_spawn "$home" spawn-consent-b4 "$proj" pi --mode no-mistakes --yolo off \
    --upstream-consent "$PUB_TARGET")
  assert_not_contains "$out" "spawn refused" "consent on an ordinary project must not be gated"

  # Consent on local-only is refused before any gate: it names a publication
  # local-only never performs.
  write_ship_brief "$home" spawn-consent-b5
  rc=0
  out=$(run_spawn "$home" spawn-consent-b5 "$ROOT" pi --mode local-only --yolo off \
    --upstream-consent "$PUB_TARGET") || rc=$?
  [ "$rc" -ne 0 ] || fail "local-only must refuse a consent flag"
  assert_contains "$out" "meaningless on local-only" "local-only must refuse a consent flag"
  pass "fm-spawn.sh: consent must agree between flag and brief, and is refused on local-only"
}

# --- fm-promote.sh ----------------------------------------------------------

test_promote_gate_on_self_repo() {
  local home meta out rc
  home=$(make_role_home promote-user)
  meta="$home/state/promote-r1.meta"
  printf 'window=fm-promote-r1\nkind=scout\nproject=%s\nworktree=/tmp/wt\n' "$ROOT" > "$meta"
  mkdir -p "$home/data/promote-r1"
  printf 'You are a crewmate.\n\n# Task\n## Captain'\''s intent\nInvestigate a firstmate bug.\n\n## Firstmate spec\nReport findings.\n' \
    > "$home/data/promote-r1/brief.md"

  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" \
    "$PROMOTE" promote-r1 --mode direct-PR --yolo off 2>&1); rc=$?
  expect_code 1 "$rc" "a user home must not promote a self-repo scout into a publishing ship"
  assert_contains "$out" "promotion refused for promote-r1" "the refusal must name the task"
  assert_contains "$out" "user/operator" "the refusal must name the role"
  assert_grep 'kind=scout' "$meta" "a refused promotion must leave the scout kind untouched"
  assert_absent "$home/data/promote-r1/ship-instructions.md" "a refused promotion must publish no instructions"

  if [ -n "$PUB_TARGET" ]; then
    out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
      FM_CONFIG_OVERRIDE="$home/config" \
      "$PROMOTE" promote-r1 --mode direct-PR --yolo off --upstream-consent "$PUB_TARGET" 2>&1); rc=$?
    expect_code 0 "$rc" "recorded consent must let the same promotion through (got: $out)"
    assert_grep 'upstream_consent=' "$meta" "the promoted task record must carry the consent"
    assert_grep "upstream-consent=$PUB_TARGET" "$home/data/promote-r1/ship-instructions.md" \
      "the promoted ship instructions must render the consent token"
  fi
  pass "fm-promote.sh: the self-repository gate governs promotion identically to spawn"
}

# --- run --------------------------------------------------------------------

test_report_default_and_local_grants
test_report_fails_closed_on_unsafe_input
test_check_user_home_refused_on_self_repo
test_check_foreign_project_passes_through
test_check_maintainer_scope_authorizes
test_check_wrong_scope_and_remote_presence_do_not_authorize
test_check_equivalent_remote_spellings_are_one_repo
test_check_fork_lineage_reaches_the_gate
test_check_gh_default_outranks_upstream
test_check_gh_resolved_base_selects_fork
test_check_undeterminable_lineage_and_target_refuse
test_check_task_consent_authorizes_one_task
test_dod_block_renders_and_bounds_consent
test_brief_consent_flag_bounds
test_brief_self_repo_pre_gate
test_spawn_gate_on_self_repo
test_spawn_consent_agreement
test_promote_gate_on_self_repo

echo "# all fm-self-repo-role tests passed"
