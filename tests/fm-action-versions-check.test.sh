#!/usr/bin/env bash
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-action-versions-check-tests)
CHECK="$ROOT/bin/fm-action-versions-check.sh"
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
SHA=0123456789abcdef0123456789abcdef01234567

cat >"$FAKEBIN/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$FAKE_GH_LOG"
[ "$1" = api ] || exit 64
repo=${2#repos/}
repo=${repo%/releases/latest}
answer=$(awk -v repo="$repo" '$1 == repo { $1 = ""; sub(/^ /, ""); print; exit }' "$FAKE_GH_RELEASES")
case "$answer" in
  '')
    printf 'HTTP 404: Not Found (https://api.github.com/repos/%s/releases/latest)\n' "$repo" >&2
    exit 1
    ;;
  error:*)
    printf '%s\n' "${answer#error:}" >&2
    exit 1
    ;;
  *) printf '%s\n' "$answer" ;;
esac
SH
chmod +x "$FAKEBIN/gh"

new_repo() {
  local name=$1 dir="$TMP_ROOT/$1"
  mkdir -p "$dir/.github/workflows"
  : >"$dir/releases"
  : >"$dir/gh.log"
  printf '%s\n' "$dir"
}

OUT=
CODE=0
run_check() {
  local repo=$1
  shift
  CODE=0
  OUT=$(env "$@" PATH="$FAKEBIN:$PATH" FAKE_GH_LOG="$repo/gh.log" FAKE_GH_RELEASES="$repo/releases" \
    "$CHECK" --root "$repo" 2>&1) || CODE=$?
}

test_major_behind_fails_naming_file_line_and_version_rather_than_passing() {
  local repo
  repo=$(new_repo behind)
  cat >"$repo/.github/workflows/ci.yml" <<'YAML'
jobs:
  build:
    steps:
      - uses: actions/checkout@v4
      - uses: actions/cache@v6.0.0
      - name: Node
        uses: "actions/setup-node@v6"
YAML
  printf '%s\n' 'actions/checkout v6.0.2' 'actions/cache v6.1.0' 'actions/setup-node v6.0.0' >"$repo/releases"
  run_check "$repo" GITHUB_ACTIONS=
  expect_code 1 "$CODE" "an action two majors behind"
  assert_contains "$OUT" ".github/workflows/ci.yml:4: actions/checkout@v4 is behind the latest major version; use actions/checkout@v6 (latest release v6.0.2)" "the finding names the file, line, and version to use"
  assert_not_contains "$OUT" "ci.yml:5:" "a ref on the latest major is not a finding"
  assert_not_contains "$OUT" "ci.yml:7:" "a quoted ref on the latest major is not a finding"
  pass "an action behind its latest major fails, naming file, line, and the version to use"
}

test_older_minor_on_the_latest_major_passes_rather_than_failing() {
  local repo
  repo=$(new_repo current)
  cat >"$repo/.github/workflows/ci.yml" <<'YAML'
jobs:
  build:
    steps:
      - uses: actions/checkout@v6
      - uses: actions/cache@v6.0.0
YAML
  printf '%s\n' 'actions/checkout v6.0.2' 'actions/cache v6.1.0' >"$repo/releases"
  run_check "$repo" GITHUB_ACTIONS=
  expect_code 0 "$CODE" "every action on its latest major: $OUT"
  assert_contains "$OUT" "all 2 action references are on their latest major version" "success names how many refs it checked"
  pass "an older minor or patch on the latest major passes"
}

test_sha_pin_is_judged_by_its_version_comment_not_skipped() {
  local repo
  repo=$(new_repo sha)
  cat >"$repo/.github/workflows/ci.yml" <<YAML
jobs:
  build:
    steps:
      - uses: actions/checkout@$SHA # v4.2.2
      - uses: actions/cache@$SHA # v6.1.0
      - uses: actions/setup-node@$SHA
YAML
  printf '%s\n' 'actions/checkout v6.0.2' 'actions/cache v6.1.0' 'actions/setup-node v6.0.0' >"$repo/releases"
  run_check "$repo" GITHUB_ACTIONS=
  expect_code 1 "$CODE" "a commit pin behind its latest major"
  assert_contains "$OUT" "ci.yml:4: actions/checkout@$SHA pins v4.2.2, behind the latest major version; pin the commit of v6.0.2 and comment it '# v6.0.2'" "a commit pin is judged by its comment"
  assert_not_contains "$OUT" "ci.yml:5:" "a commit pin whose comment is on the latest major is not a finding"
  assert_contains "$OUT" "ci.yml:6: actions/setup-node@$SHA is a commit pin with no trailing '# vX.Y.Z' comment" "a commit pin with no comment fails"
  pass "a commit pin is judged by its trailing version comment, and one without a comment fails"
}

test_local_and_docker_refs_are_skipped_without_a_lookup() {
  local repo
  repo=$(new_repo local)
  cat >"$repo/.github/workflows/ci.yml" <<'YAML'
jobs:
  build:
    steps:
      - uses: ./.github/actions/setup
      - uses: docker://alpine:3.20
YAML
  run_check "$repo" GITHUB_ACTIONS=
  expect_code 0 "$CODE" "only local and docker refs: $OUT"
  [ ! -s "$repo/gh.log" ] || fail "a local or docker ref was looked up: $(cat "$repo/gh.log")"
  pass "local and docker refs are skipped without an API lookup"
}

test_lookup_failure_fails_with_its_reason_rather_than_passing() {
  local repo
  repo=$(new_repo lookup)
  cat >"$repo/.github/workflows/ci.yml" <<'YAML'
jobs:
  build:
    steps:
      - uses: example/flaky@v1
      - uses: example/norelease@v1
YAML
  printf '%s\n' 'example/flaky error:HTTP 403: API rate limit exceeded' >"$repo/releases"
  run_check "$repo" GITHUB_ACTIONS=
  expect_code 1 "$CODE" "a failed release lookup"
  assert_contains "$OUT" "ci.yml:4: could not look up the latest release of example/flaky: HTTP 403: API rate limit exceeded" "the lookup failure names its reason"
  assert_contains "$OUT" "ci.yml:5: could not look up the latest release of example/norelease: HTTP 404: Not Found" "an action with no release fails with the reason"
  pass "a failed lookup fails the check with its reason"
}

test_branch_ref_fails_rather_than_passing_unchecked() {
  local repo
  repo=$(new_repo branch)
  cat >"$repo/.github/workflows/ci.yml" <<'YAML'
jobs:
  build:
    steps:
      - uses: example/tool@main
YAML
  printf '%s\n' 'example/tool v2.0.0' >"$repo/releases"
  run_check "$repo" GITHUB_ACTIONS=
  expect_code 1 "$CODE" "a branch ref"
  assert_contains "$OUT" "ci.yml:4: example/tool@main is not a release version" "a branch ref names why it fails"
  pass "a ref with no version fails rather than passing unchecked"
}

test_action_in_a_subdirectory_is_looked_up_by_its_repository() {
  local repo
  repo=$(new_repo subdir)
  cat >"$repo/.github/workflows/scan.yaml" <<'YAML'
jobs:
  scan:
    steps:
      - uses: github/codeql-action/init@v3
      - uses: github/codeql-action/analyze@v3
YAML
  printf '%s\n' 'github/codeql-action v4.1.0' >"$repo/releases"
  run_check "$repo" GITHUB_ACTIONS=
  expect_code 1 "$CODE" "a subdirectory action behind"
  assert_contains "$OUT" ".github/workflows/scan.yaml:4: github/codeql-action/init@v3 is behind the latest major version; use github/codeql-action/init@v4" "a .yaml workflow and a subdirectory action are checked"
  assert_equals 1 "$(grep -c 'repos/github/codeql-action/releases/latest' "$repo/gh.log")" "the repository is looked up once for both lines"
  pass "an action in a subdirectory is looked up once by its repository"
}

test_github_actions_run_annotates_the_line_rather_than_only_logging() {
  local repo
  repo=$(new_repo annotate)
  cat >"$repo/.github/workflows/ci.yml" <<'YAML'
jobs:
  build:
    steps:
      - uses: actions/checkout@v4
YAML
  printf '%s\n' 'actions/checkout v6.0.2' >"$repo/releases"
  run_check "$repo" GITHUB_ACTIONS=true
  expect_code 1 "$CODE" "an action behind inside GitHub Actions"
  assert_contains "$OUT" "::error file=.github/workflows/ci.yml,line=4::.github/workflows/ci.yml:4: actions/checkout@v4 is behind" "the finding is an annotation on its line"
  pass "inside GitHub Actions a finding is an error annotation on its file and line"
}

test_no_workflow_files_fails_rather_than_passing_empty() {
  local repo
  repo=$(new_repo empty)
  run_check "$repo" GITHUB_ACTIONS=
  expect_code 1 "$CODE" "a root with no workflow files"
  assert_contains "$OUT" "no workflow files under" "the failure names the missing workflows"
  pass "a root with no workflow files fails rather than passing with nothing checked"
}

fm_test_run \
  test_major_behind_fails_naming_file_line_and_version_rather_than_passing \
  test_older_minor_on_the_latest_major_passes_rather_than_failing \
  test_sha_pin_is_judged_by_its_version_comment_not_skipped \
  test_local_and_docker_refs_are_skipped_without_a_lookup \
  test_lookup_failure_fails_with_its_reason_rather_than_passing \
  test_branch_ref_fails_rather_than_passing_unchecked \
  test_action_in_a_subdirectory_is_looked_up_by_its_repository \
  test_github_actions_run_annotates_the_line_rather_than_only_logging \
  test_no_workflow_files_fails_rather_than_passing_empty
