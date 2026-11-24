# Runtime backend verification

Audience: maintainer verification.

This record contains reusable version-scoped evidence for active runtime guarantees.
The backend guides own current setup, safety boundaries, and limitations.
Exact task chronology, branch names, temporary homes, local paths, process ids, thread ids, and delivery transcripts remain in private reports or PR evidence.
In the output below, `<user>` replaces a local account name.

## Pi project trust

[`fm-spawn.sh --help`](../../bin/fm-spawn.sh) owns the project-trust approval contract and compatibility fallback.
The historical run below isolated Pi project trust across seeded homes and ordinary task copies.
Portable launch-command coverage separately verifies that spawn selects the flag for the intended launches.

Verified 2026-10-02 on Pi 0.82.0 with a disposable `PI_CODING_AGENT_DIR` and `HOME`.
The live script has since been removed.

```
# live pi version: 0.82.0
ok - fresh seeded Pi secondmate-shaped home stalls on Trust project folder? without --approve
ok - seeded home with --approve starts past the trust dialog without rewriting trust.json
ok - unseeded path without --approve still prompts on Trust project folder?
# all fm-pi-seeded-home-trust-live-e2e checks passed (3)
```

Portable launch-command coverage lives in `tests/fm-spawn-dispatch-profile.test.sh`.
The covering tests are `test_pi_seeded_secondmate_preapproves_project_trust`, `test_pi_worker_launch_preapproves_project_trust`, and `test_pi_approve_probe_omits_unsupported_flag`.

## Launch-prompt backstop signatures

`bin/fm-busy-lib.sh`'s launch-prompt backstop (`fm_busy_launch_prompt_parked`) reclassifies a launch whose busy record is still pinned at the fm-spawn seed as `unknown launch-prompt`, rather than `busy fm-spawn`, when the captured pane matches that harness's own recognized trust, sign-in, or first-run dialog.
Each signature below was live-verified against the real installed binary; the live driver for that run is no longer shipped.

An initial Pi signature sourced only from the installed binary's own UI strings ("Project trust", the internal panel-title component, never the dialog's own rendered heading) was wrong and never matched the real screen.
This guard's first live run caught that before it shipped, which is the evidence for why this class of check must be driven end to end rather than read off strings or a component name.

The Pi 0.86.1 run on 2026-09-22 produced this prompt.

Pi, launched into a fresh worktree carrying a project-local `.pi/extensions/` file (the trust-requiring resource that actually gates the dialog) under an isolated `HOME`:

```
 Trust project folder?
 /tmp/fm-launch-prompt-pi.XXXXXX/wt

 This allows pi to load .pi settings and resources, install missing project packages, and execute project extensions.

 → Trust
   Trust parent folder (/tmp/fm-launch-prompt-pi.XXXXXX)
   Trust (this session only)
   Do not trust
   Do not trust (this session only)

 ↑↓ navigate  enter select  escape/ctrl+c cancel
```

## Worker account pin sign-in check

`bin/fm-worker-account-lib.sh` decides whether a pinned account is signed in from vendor output: the exit status of `claude auth status`, the JSON of `pi auth check`, and the provider column of `pi --list-models`.
`tests/fm-worker-account-live-e2e.test.sh` asks the real installed runners about synthetic roots that need no login and no network, under a throwaway `HOME`.
A Claude root whose `settings.json` names an `apiKeyHelper` reports `loggedIn: true`, a Pi root holding a stored API key reports `ready`, and a provider registered by an extension in the Pi root's `extensions/` answers `pi auth check` with `not_ready`/`provider_not_found` while `pi --list-models` lists it.
Each refusal is paired with the divergence it depends on: the same runner, given `ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, or the extension's key variable, answers signed in for the empty root, so the refusal proves the check's cleared environment.
Replacing `env -i` with `env` in the check makes the guard fail on the Claude refusal.

Verified 2026-09-22 on Claude Code 2.1.278 and pi 0.86.1 on Linux; pi-signed was not installed.

```sh
bash tests/fm-worker-account-live-e2e.test.sh
```

```
ok - claude 2.1.278 (Claude Code): the pin check accepts a signed-in root and refuses an empty one despite an ambient API key
ok - pi 0.86.1: the pin check reads auth check and the model listing, and refuses what only an ambient credential signs in
skip-runner: pi-signed is not installed, so its pin check was not exercised
# worker account live guard checked: claude pi
```

The guard submits no prompt and spends no tokens, so it runs by default wherever a runner is installed; rerun it after every Claude or Pi upgrade.

## Steering-inbox doorbell

A real Pi 0.84.1 worker on 2026-08-23 read its durable inbox and acknowledged the record by moving it into `handled/`.
The current [inbox protocol](../inbox.md) explains the worker path and pending-input checks.
`tests/fm-task-inbox.test.sh` and `tests/fm-send-inbox.test.sh` cover record delivery and the re-ring path.

## Waiting-worker command ceilings

The `# Waiting` section of the ship and scout briefs (`bin/fm-brief.sh`) has a worker hold every external wait inside one blocking shell command, bounded by what its harness lets one command run.
That section is generated only when `config/wait-no-turns` is present.
Those bounds were read from the installed vendor code on 2026-09-11, macOS arm64, with Pi 0.85.1, codex-cli 0.154.0, and Claude Code 2.1.268.

```sh
grep -n "Timeout in seconds" "$(npm root -g)/@earendil-works/pi-coding-agent/dist/core/tools/bash.js"
strings -n 20 "$(readlink -f "$(command -v codex)")" | grep -o "Non-empty writes default to [^.]*; empty polls wait [^.]*\."
strings -n 8 "$(readlink -f "$(command -v claude)")" | grep -oE '=120000,[A-Za-z0-9_$]+=600000;' | head -1
```

Observed output:

```text
28:    timeout: Type.Optional(Type.Number({ description: "Timeout in seconds (optional, no default timeout)" })),
Non-empty writes default to 250 ms and cap at 30000 ms; empty polls wait 5000-300000 ms by default.
=120000,ARo=600000;
```

Pi's bash tool runs a command with no time limit unless the call passes `timeout`, so the brief asks for at most 2700 seconds, which stays under the watcher's 3600-second busy-turn bound.
Codex yields a still-running command back to the model, and one empty `write_stdin` poll then waits up to 300000 ms.
Claude Code's Bash tool defaults to 120000 ms and accepts at most 600000 ms; `BASH_DEFAULT_TIMEOUT_MS` and `BASH_MAX_TIMEOUT_MS` override those two values.

Claude Code also constrains the shape of a wait, not only its length, so the brief has to name the shape that is allowed rather than only forbid the ones that are not.
Run as separate Bash tool calls on 2026-09-14 with Claude Code 2.1.268:

```sh
until [ -e /tmp/fm-wait-probe ]; do sleep 30; done   # ran to completion, rc=0
sleep 61; echo "rc=$?"                               # rc=0
sleep 40; echo "checked at $(date +%s)"              # rc=0
```

An earlier `sleep 60` chained ahead of a status check was refused before execution, with a message pointing at `Monitor` with an until-loop and at `run_in_background: true`, and adding "Do not chain shorter sleeps to work around this block".
The blocking foreground `until` loop is therefore the wait a Claude Code worker may use, and it is what the brief names, because the refusal's own `run_in_background` suggestion is the one shape a waiting worker must not take: a backgrounded call returns at once and so does not wait at all.
The brief's portable regression is `tests/fm-brief.test.sh`; rerun these commands after upgrading any of the three harnesses and update the numbers in the brief when they move.

## Herdr

The compatibility floor is protocol 14.
The whole real-Herdr lane's latest active verification uses both Herdr 0.7.4 protocol 16 and Herdr 0.8.0 protocol 19 on macOS aarch64, while focused Herdr 0.7.5 protocol 17, earlier protocol-16, protocol-14, and 0.7.3 evidence is retained where it defines current behavior or fallbacks.
Protocol 17 keeps every protocol-16 feature gate satisfied; the event and workspace-move floors remain 16.
Default-on presentation projection has its own floor at Herdr 0.8.0, protocol 19, verified below.

Projected worktree entry was verified on 2026-11-03 with Herdr 0.9.5 on macOS arm64:

```sh
bash bin/fm-test-run.sh tests/fm-herdr-projected-cd-live-e2e.test.sh
```

```text
ok - Herdr 0.9.5 projected spawn enters its recorded copy (delayed=0)
ok - Herdr 0.9.5 projected spawn enters its recorded copy (delayed=1)
```

This token-free guard provisions only a named non-default Herdr lab session, drives the real projected spawn, cd, and cwd assertion, and verifies the exact foreground cwd against the recorded copy.
On a supported Herdr below the presentation floor, where `fm_backend_herdr_presentation_release_supported` keeps spawns flat, it prints a skip naming the release and exits 0 instead of running the projected cases.
Its delayed case holds the first real cd behind a 15-second shell command and verifies exactly one resend; its ordinary case verifies no redundant cd.
The lease fixture returns a disposable clone without accessing a shared Treehouse pool.
The portable delayed, dropped, and never-moving entry regressions are in `tests/fm-spawn-herdr-lease.test.sh`.

Core read-only probes:

```sh
herdr --version
herdr status --json | jq -c '{client:.client.protocol,server:.server.protocol}'
herdr api schema --json | jq -c '.schemas.subscription_event["$defs"].SubscriptionEventKind.enum'
```

Observed protocol-16 compatibility shapes:

```text
herdr 0.7.5
{"client":17,"server":17}
["pane.output_matched","pane.agent_status_changed","pane.scroll_changed"]
```

The CLI matrix was checked directly:

| Guarantee | Command shape | Result |
| --- | --- | --- |
| Explicit session routing | `herdr <verb> ... --session <name>` | Reached the named session even while another server was running. |
| Literal send | `herdr pane send-text <pane> <text> --session <name>` | Left text unsubmitted until Enter. |
| Keys | `herdr pane send-keys <pane> enter|escape|ctrl+c --session <name>` | Enter and Escape worked; Ctrl-C interrupted foreground work. |
| Scrollback capture | `herdr pane read <pane> --source recent --lines N` | Small N could return empty below viewport height, and a 200-line request plus local trim was stable. Only `fm_backend_herdr_scrollback_capture` issues it, as "Recent reads wheel-scroll an idle fullscreen agent" below records. |
| Viewport capture | `herdr pane read <pane> --source visible` | Verified on 2026-09-17 against Herdr 0.8.0 (protocol 19): `herdr pane read --help` documents `--source <SOURCE>` with `[possible values: visible, recent, recent-unwrapped, detection]`; `--source visible` exited 0 and returned 51 lines (the viewport) while `--source recent --lines 200` returned 200. This is the viewport-only read behind `fm_backend_herdr_visible_capture`, which Kimi's trust-dialog gate requires. |
| Styled viewport capture | `herdr pane read <pane> --source visible --format ansi` | Verified on 2026-09-26 against Herdr 0.9.0 with Claude Code 2.1.283: the flag pair exited 0 and returned the viewport with SGR attributes intact, which is the styled read behind `fm_backend_herdr_visible_capture_ansi` that ghost/placeholder stripping needs (see "Claude exit behind the slash-command popup" below). |
| Native state | `herdr agent get <pane>` | Working and done transitions were visible on some harnesses; live Claude Code 2.1.236 on Herdr 0.8.0 kept `agent_status=idle` for an entire landed turn, including a multi-second tool call, so submit confirmation falls through to the shared composer verdict. Native `busy` remains positive activity evidence, while native `idle` cannot close a turn and the adapter's semantic lifecycle decides worker state. |
| Restart | guarded named-session stop then start | Workspace, tab, pane, and labels persisted; the agent process and registration did not. |
| Close | `herdr pane close <pane> --session <name>` | The exact one-pane task tab closed; closing a final tab could remove the workspace. |

All destructive verification used `bin/fm-herdr-lab.sh` with a non-default `fm-lab-` name and a byte-identical default-session tripwire.
No ambient `herdr server stop` command is a supported test operation.

### fm-remote server birth and login-keychain access

Measured 2026-09-09 on macOS 26 (Darwin 25.6.0) aarch64 with Claude Code 2.1.266 and Herdr 0.9.0, the guarantee behind `bin/fm-remote-herdr-guard.sh` and the doctor's `herdr-server` check: login-keychain access follows the audit session a process was born into, never the launch shape or the shell.

Same user, same `HOME`, same login keychain item, three births, probed with `launchctl managername`, `getaudit_addr` (a compiled probe), `security find-generic-password -a "$USER" -w -s "Claude Code-credentials"` (output withheld), and `claude auth status`:

| Birth | `managername` | audit session | `security ... -w` | `claude auth status` |
| --- | --- | --- | --- | --- |
| `gui/501` LaunchAgent, bare `ProgramArguments`, `launchctl bootstrap` + `kickstart -k` mid-session | Aqua | asid 100038 (the `gui/501` asid), `HAS_GRAPHIC_ACCESS HAS_TTY HAS_CONSOLE_ACCESS HAS_AUTHENTICATED` | exit 0 | `loggedIn: true` |
| `gui/501` LaunchAgent, `zsh -l -c 'exec ...'`, same reload | Aqua | asid 100038, same flags | exit 0 | `loggedIn: true` |
| `user/501` LaunchAgent (`LimitLoadToSessionType=Background`), same reload | Background | asid 100056, flags `0x0` | exit 36 `User interaction is not allowed.`, item metadata still readable | `loggedIn: false`, `authMethod: none` |

Claude Code 2.1.266 maps that exit 36 (and 44) to "no keychain data" and reads `~/.claude/.credentials.json` instead; with a stale file it prints `Failed to authenticate: OAuth session expired and could not be refreshed` (interactive: `Login expired · Please run /login`).

Candidate birth markers were read with `ps -Eww -o command= -p <pid>` for own-uid processes, noting that macOS hides the environment of Apple platform binaries such as `/bin/sleep` and that a herdr server is never one.

```text
launchd-born herdr server (child of launchd, gui/501):  XPC_SERVICE_NAME=org.nix-community.home.herdr-server  no SSH_*
SSH-born herdr server (child of `herdr --session fm-remote remote-client-bridge` under `sshd-session: user@notty`):  SSH_CLIENT=... SSH_CONNECTION=...  no XPC_SERVICE_NAME
```

`XPC_SERVICE_NAME` identifies a launchd label but does not identify its domain, because the Background `user/501` job also carried that variable while lacking keychain access.
The owner classifier therefore accepts that label only when `launchctl print gui/<uid>/<label>` identifies the owner pid or the label is loaded in `gui/<uid>` but not `user/<uid>`.
`XPC_SERVICE_NAME=0`, including a value inherited by a herdr live-handoff child, remains unknown.
`FM_REMOTE_JOB_ACTIVE=1` proves the Aqua worker only when `dev.firstmate.remote-job` is loaded in `gui/<uid>` but not `user/<uid>`.

The SSH-born row was read on the remote host whose `dev.firstmate.herdr.fm-remote` job showed `state = spawn scheduled`, `runs = 239`, `last exit code = 1` and a log repeating `error: herdr server is already running`: herdr's remote attach had started the session's server as its own child before the login session existed, and launchd's copy lost the socket on every retry.
`pgrep -f` did not list the herdr server's argv on macOS; `lsof -U -a -c herdr -F pn` named the socket owner.

A separate foreground-supervision check ran on 2026-09-09 on macOS 26 (Darwin 25.6.0) with Herdr 0.9.0 using the throwaway Aqua launch agent `dev.fm-rca.herdr-fg`.
Its `ProgramArguments` ran `/run/current-system/sw/bin/zsh -l -c "exec /etc/profiles/per-user/kunchen/bin/herdr server --session fm-lab-fg-90381-18985"`, with `KeepAlive={SuccessfulExit=false}` and `ThrottleInterval=10`, after `launchctl bootstrap gui/501 <plist>` and `launchctl kickstart -k gui/501/dev.fm-rca.herdr-fg`.
`launchctl print gui/501/dev.fm-rca.herdr-fg` reported `state = running` and `pid = 4806`.
`lsof -U -a -c herdr -F pn` named pid 4806 as the owner of `$HOME/.config/herdr/sessions/fm-lab-fg-90381-18985/herdr.sock`.
`ps -o pid,ppid,command -p 4806` reported `4806 1 /etc/profiles/per-user/kunchen/bin/herdr server --session fm-lab-fg-90381-18985`, and its environment carried `XPC_SERVICE_NAME=dev.fm-rca.herdr-fg`.
No other herdr process existed for that session, and after 15 seconds the job remained running with pid 4806.
After a guarded `herdr session stop`, the job reported `state = not running` and `last exit code = 0`, and it stayed at rest through the throttle interval.
A second `launchctl kickstart -k gui/501/dev.fm-rca.herdr-fg` started pid 45574, which was also the new socket owner.
This proves that `herdr server` remains in the foreground as the launchd job, so the guard's final `exec` supplies the intended supervision and the earlier server that survived `launchctl bootout` was the unrelated SSH-bridge-born process.

`bin/fm-test-run.sh tests/fm-remote-herdr-guard.test.sh` pins the resulting decision table against real marker-carrying processes, and `tests/fm-remote-doctor.test.sh` pins the doctor's verdicts on the same markers.

### Client selection

Measured 2026-09-08 on a macOS aarch64 host running a Herdr 0.9.0 server (protocol 22) for the `fm-remote` session while `~/.local/bin/herdr` still held the self-updated 0.8.2 client (protocol 20) ahead of the Nix-managed 0.9.0 client on the remote-job `PATH`.

```sh
~/.local/bin/herdr --version
~/.local/bin/herdr pane get wCY:p2 --session fm-remote; echo "rc=$?"
~/.local/bin/herdr status --json --session fm-remote | jq -c '{c:.client.protocol,s:{running:.server.running,protocol:.server.protocol,compatible:.server.compatible}}'
herdr status --json --session fm-remote | jq -c '{c:.client.protocol,s:{running:.server.running,protocol:.server.protocol,compatible:.server.compatible}}'
```

```text
herdr 0.8.2
{"id":"cli:pane:get","error":{"code":"protocol_mismatch","message":"client protocol 20 is older than server protocol 22; upgrade the Herdr client before using this command"}}
rc=1
{"c":20,"s":{"running":true,"protocol":22,"compatible":false}}
{"c":22,"s":{"running":true,"protocol":22,"compatible":true}}
```

The refusal is a JSON error on stderr with exit 1 and empty stdout, and both client generations report `.server.compatible` and `.server.protocol` per named session, which is what the selection in `bin/backends/herdr.sh` reads.
`tests/fm-backend-herdr.test.sh` pins the bypass, same-process same-session caching, cross-session isolation, forced reselection, and both status shapes against fakes; `tests/fm-backend-herdr-smoke.test.sh` refreshes the real status normalization against the installed binary's running lab server.

### Session directory

Measured 2026-10-15 on Linux x86_64 with Herdr 0.9.5, reading only `status`: the default and an empty `sessions/probe` session under a fresh `XDG_CONFIG_HOME` with no server, then the host's running `firstmate` session.

```sh
herdr --version
d=$(mktemp -d /tmp/hx.XXXXXX); mkdir -p "$d/herdr/sessions/probe"
for s in default probe; do XDG_CONFIG_HOME="$d" herdr --session "$s" status --json | jq -c --arg d "$d" '{session: .server.session, running: .server.running, socket: (.server.socket | sub("^" + $d; "$XDG_CONFIG_HOME"))}'; done
herdr --session firstmate status --json | jq -c --arg h "$HOME" '{session: .server.session, running: .server.running, socket: (.server.socket | sub("^" + $h; "~"))}'
HERDR_SOCKET_PATH=/tmp/xx/zz.sock herdr --session default status --json | jq -c '.server.socket | sub("^" + env.HOME; "~")'
```

```text
herdr 0.9.5
{"session":null,"running":false,"socket":"$XDG_CONFIG_HOME/herdr/herdr.sock"}
{"session":"probe","running":false,"socket":"$XDG_CONFIG_HOME/herdr/sessions/probe/herdr.sock"}
{"session":"firstmate","running":true,"socket":"~/.config/herdr/sessions/firstmate/herdr.sock"}
"~/.config/herdr/herdr.sock"
```

A session whose server is stopped still reports its socket, the socket's directory is the session directory `herdr session list --json` reports as `session_dir`, it follows `XDG_CONFIG_HOME`, and an inherited `HERDR_SOCKET_PATH` does not move it under `--session`, so the [externally managed server](../herdr-backend.md#externally-managed-servers) markers stay readable through a restart without an extra Herdr call.
The `status` read created nothing under the fresh config directory.
`tests/fm-backend-herdr.test.sh` pins the marker behavior against fakes.

### Submit confirmation

Measured 2026-08-19 against Herdr 0.8.0 and Claude Code 2.1.236 in an isolated `fm-lab-` session.

`herdr agent get` reported `agent_status=idle` on every sample across a landed one-word turn and an 8-second `sleep` tool call, while the pane rendered `Pontificating…` then `Sock-hopping… (11s · ↓ 234 tokens)`.
`fm_backend_herdr_send_text_submit` therefore cannot treat native idle as proof of a swallow.
The portable regressions in `tests/fm-backend-herdr.test.sh` and `tests/fm-composer-lib.test.sh` pin the verdicts: native idle plus a cleared composer is delivery, proven pending plus idle is a swallow, and proven pending plus a generating busy signal is a queued Enter.
Refresh the live Claude proof with:

```sh
FM_HERDR_SUBMIT_CONFIRM_LIVE=1 tests/fm-herdr-submit-confirm-live-e2e.test.sh
```

Observed 2026-08-19:

```text
ok - live Herdr submit confirm: Claude Code (2.1.236 (Claude Code)) on herdr 0.8.0 reports empty for a landed idle steer
```

### Prune and respawn

The real label-collision reproduction is owned by:

```sh
HERDR_LAB_HELPER=bin/fm-herdr-lab.sh \
  tests/fm-backend-herdr-prune-safety-e2e.test.sh
```

Observed guarantee: a pre-existing captain-owned workspace with a seed-shaped tab was adopted for routing but its tab was never eligible for prune because the current create call did not return that seed id.

Restart-husk replacement is owned by:

```sh
HERDR_LAB_HELPER=bin/fm-herdr-lab.sh \
  tests/fm-backend-herdr-respawn-idem-e2e.test.sh
```

Observed guarantee: a restored no-agent tab was replaced create-before-close, while a registered live agent caused refusal.

### Launcher workspace placement

Herdr exports its pane identity into every process it manages, checked on 2026-07-30 against Herdr 0.7.5 protocol 17 inside a guarded lab pane:

```sh
HERDR_LAB_HELPER=bin/fm-herdr-lab.sh
"$HERDR_LAB_HELPER" run "$LAB" pane run "$PANE" "sh -c 'env | grep ^HERDR | sort > /tmp/env.txt'"
```

```text
HERDR_ENV=1
HERDR_PANE_ID=w1:p1
HERDR_SESSION=fm-lab-fm-herdr-env-pro-65961-25535
HERDR_SOCKET_PATH=/Users/<user>/.config/herdr/sessions/fm-lab-fm-herdr-env-pro-65961-25535/herdr.sock
HERDR_TAB_ID=w1:t1
HERDR_WORKSPACE_ID=w1
```

This complete injection shape is verified only for Herdr 0.7.5.
Firstmate requires both `HERDR_PANE_ID` and `HERDR_SOCKET_PATH` before accepting claimed launcher ancestry.

`pane get` reports the pane's current owning tab and workspace, which is what placement resolves from; the injected `HERDR_TAB_ID` and `HERDR_WORKSPACE_ID` are creation-time snapshots and are not read as current identity:

```sh
"$HERDR_LAB_HELPER" run "$LAB" pane get w1:p1 | jq -c '.result.pane | {pane_id,tab_id,workspace_id}'
```

```text
{"pane_id":"w1:p1","tab_id":"w1:t1","workspace_id":"w1"}
```

Placement is owned by:

```sh
HERDR_LAB_HELPER=bin/fm-herdr-lab.sh \
  tests/fm-backend-herdr-launcher-workspace-e2e.test.sh
```

Observed guarantees on 2026-07-30 against Herdr 0.7.5 protocol 17:

```text
ok - real herdr E2E: with one 'firstmate' workspace and no herdr parent, a crewmate still lands in this home's own workspace without stealing focus
ok - real herdr E2E: the normal unique-label path is unchanged when the launcher's own pane identifies the workspace
ok - real herdr E2E: presentation spaces still create the isolated child workspace and bind it under the launcher's exact parent, without stealing focus
ok - real herdr E2E: with two 'firstmate' workspaces, a worker spawned from inside the second one lands in that exact workspace
ok - real herdr E2E: the duplicate-labeled sibling workspace is left entirely untouched and focus is preserved
ok - real herdr E2E: with a duplicated home label, a projected worker still hangs off the launcher's exact workspace and the sibling stays untouched
ok - real herdr E2E: an ambiguous home label with no launcher identity refuses before any worker endpoint exists
ok - real herdr E2E: a launcher pane that no longer exists refuses before any worker endpoint exists
ok - real herdr E2E: a secondmate launching its own worker gets the same exact-workspace guarantee, and its same-labeled sibling is untouched
ok - real herdr E2E: a --secondmate launch still stands up that secondmate's own workspace instead of inheriting the launcher's
ok - real herdr E2E: teardown closes only the worker's own pane and leaves the launcher, its workspace, and the same-labeled sibling intact
```

That suite's headline case runs `bin/fm-spawn.sh` inside a real Herdr pane, so the parent identity comes from Herdr's own injection rather than a composed environment.
Cross-session and contradictory bindings are covered deterministically in `tests/fm-backend-herdr.test.sh`, which can script a second server's socket without provisioning one.

### Per-home and presentation topology

The per-home lab driver for this run is no longer shipped.

Observed guarantee: the primary and secondmate used distinct home workspaces, a child launched by the secondmate stayed in that secondmate workspace, list-live remained home-scoped, and exact cleanup did not affect sibling homes.

The complete projection suite ran on 2026-07-21 against Herdr 0.7.4 protocol 16:

```sh
HERDR_LAB_HELPER=bin/fm-herdr-lab.sh \
  tests/fm-backend-herdr-presentation-e2e.test.sh
```

Observed guarantees included:

```text
ok - real Herdr lab: primary and two secondmate homes each own a top-level contiguous child block
ok - real Herdr lab: concurrent primary/A/B spawns stay session-locked with zero focus drift
ok - real Herdr lab: session lock contention from a secondmate home falls back flat with no journal
ok - real Herdr lab: legacy projection labels and flat secondmate tabs are left unmigrated
ok - real Herdr lab: multi-home exact-pane teardowns restore captain focus without workspace close authority
ok - real Herdr lab validation completed on Herdr 0.7.4 with the default-session tripwire intact
```

The suite also covers lost or failed move responses, restart husks, missing and duplicate tokens, manual renames, concurrent cleanup, and exact focus restoration.

The mandatory projection suite ran again on 2026-07-24 against Herdr 0.7.5 protocol 16:

```sh
HERDR_LAB_HELPER=bin/fm-herdr-lab.sh \
  tests/fm-backend-herdr-presentation-e2e.test.sh
```

Observed restart-reclaim guarantees:

```text
ok - real Herdr lab: Hi Bit and Wheelhouse-style same-identity restarts reclaim one nested space with exact focus and idempotence
ok - real Herdr lab: secondmate restart binding and reclaim stay isolated to the exact child home and parent
ok - real Herdr lab: concurrent cross-home recoveries replace exact husks under one session lock with no focus drift
ok - real Herdr lab: missing, renamed, and duplicate tokens trigger zero destructive or adoptive calls, and live duplicate risk refuses launch
ok - real Herdr lab validation completed on Herdr 0.7.5 with the default-session tripwire intact
```

The projection suite ran again on 2026-08-04 against Herdr 0.8.0 protocol 19 for the default-on flip, where an absent `config/herdr-presentation-spaces` enables the projection and the value `off` opts out; since 2026-08-05 an absent file enables the projection only at or above the 0.8.0 floor recorded under "Presentation version floor" below, and `on` is the explicit opt-in that survives the floor:

```sh
HERDR_LAB_HELPER=bin/fm-herdr-lab.sh \
  tests/fm-backend-herdr-presentation-e2e.test.sh
```

Observed default and opt-out guarantees:

```text
ok - real Herdr lab: an opted-out spawn retains the Stage 1 Herdr command sequence with zero ordering calls
ok - real Herdr lab: a home that configured nothing is projected by default
ok - real Herdr lab: the primary presentation setting inherits into real secondmate homes
ok - real Herdr lab validation completed on Herdr 0.8.0 with the default-session tripwire intact
```

The projected spawn in that run used the historical empty opt-in file, so a home that had already enabled the projection keeps it without any migration step.
One concurrent cross-home recovery case refused under contention on a loaded machine and passed on an immediate rerun; recovery-path presentation lock contention remains a deliberate hard refusal by default rather than a flat fallback, which default-on makes reachable from any Herdr home.
Callers that need concurrent recoveries to serialize can pass `fm-spawn.sh --herdr-resume-lock-wait`.
The flag applies to a fresh ship or scout spawn, and the multi-task path forwards it to each per-pair spawn.
It has no effect on `--relaunch` and `--secondmate`, because those paths take no exact-resume presentation-order lock.
That run measured the default-on projection on Herdr 0.8.0 only, while the focus-flash regression below was last run on 0.7.5 before the flip, so neither run covered a defective release under default-on projection; the version floor and the focus-flash suite's Part C close that gap.

The restored-shell session-start cleanup ran on 2026-07-24 against Herdr 0.7.5 protocol 17:

```sh
HERDR_LAB_HELPER=bin/fm-herdr-lab.sh \
  tests/fm-herdr-session-cleanup-e2e.test.sh
```

Observed guarantee: one exact home-local, journal-correlated, one-tab and one-pane childless idle shell was closed after restoration while the exact non-target focus and default fleet session remained unchanged, and a repeat run was a no-op.

### Workspace-removal focus safety

The focus-flash regression ran on 2026-08-05 against both Herdr 0.7.5 protocol 17 and Herdr 0.8.0 protocol 19 on macOS aarch64, with the 0.7.5 run using the pinned upstream release binary first on `PATH`:

```sh
HERDR_LAB_HELPER=bin/fm-herdr-lab.sh \
  tests/fm-backend-herdr-focus-flash-e2e.test.sh
```

Observed output on Herdr 0.7.5:

```text
ok - old path: the explicit last-pane close of a non-focused workspace stole focus (w3	w3:t1 -> w2	w2:t1)
ok - mitigation: every in-operation sample preserved exact focus while the doomed workspace was removed
ok - mitigation: no explicit close and no corrective focus were needed on the defective release
ok - fallback: a doomed pane holding a persistent child exhausts the proof and takes the plain explicit close
ok - fallback on a defective release: a bounded wrong-focus window of 4 samples was fully restored to the anchor
ok - version floor: herdr 0.7.5 protocol 17 remains conservatively below the floor with steal_live=1
ok - version floor: an unconfigured home falls back flat on herdr 0.7.5 and the explicit opt-in still projects
evidence: herdr=0.7.5 protocol=17 steal_live=1 floor_verdict=1 default-session-tripwire=armed
```

Observed output on Herdr 0.8.0:

```text
ok - old path note: this Herdr release preserves focus across the explicit close; continuing with outcome-only assertions
ok - mitigation: every in-operation sample preserved exact focus while the doomed workspace was removed
ok - fallback: a doomed pane holding a persistent child exhausts the proof and takes the plain explicit close
ok - fallback on a focus-preserving release: the plain explicit close preserved exact focus throughout
ok - version floor: herdr 0.8.0 protocol 19 is at or above the floor and preserves focus
ok - version floor: an unconfigured home stays projected on herdr 0.8.0 and the explicit opt-in agrees
evidence: herdr=0.8.0 protocol=19 steal_live=0 floor_verdict=0 default-session-tripwire=armed
```

The same guarded named-lab command passed on 2026-09-03 against Herdr 0.8.2 after this regression joined the required `real-herdr-gated` lane.
It reported `steal_live=0 floor_verdict=0 default-session-tripwire=armed`, with the fleet's default session unchanged before and after.

Part C is the case the suite could not reach before: a doomed pane whose shell holds a persistent background child fails the lone-idle-shell proof on every sample, so the plan takes the plain explicit close, in the geometry where the closing workspace's right neighbour is a spacer rather than the focused anchor.
On 0.7.5 that fallback exposed a bounded four-sample wrong-focus window and restored the anchor exactly; on 0.8.0 the same fallback exposed none, which is why default-on projection is floored at 0.8.0 rather than mitigated further below it.
The suite also cross-checks its own Part A measurement against the floor classifier on whatever release it runs, so a drifted protocol-to-release mapping fails there rather than silently gating on the wrong thing.

### Attached foreground viewer

A pseudo-terminal registers as a Herdr foreground client only when its window grid is non-zero.
`script` and a bare `pty.fork()` from a non-tty parent both start at 0x0, which is why PR #4131 could validate only the detached half of the teardown focus guard and left its four attached-client scenarios untested.
The guarded `viewer start` path fixes the pty at the proven 40-row by 120-column grid, sets that size on the master fd before the fork, and scrubs inherited `HERDR_*` variables, which makes the attached scenarios reachable from a headless runner.

Measured on 2026-09-11 against Herdr 0.9.0 protocol 22 on macOS 26.5.2 aarch64 with Python 3.14.6:

```sh
HERDR_LAB_HELPER=bin/fm-herdr-lab.sh \
  tests/fm-herdr-attached-viewer-live-e2e.test.sh
```

```text
ok - attached viewer: a pty sized before the fork registers as a real Herdr foreground client
ok - attached viewer: a live client on the target tab refuses the close and keeps the pane
ok - attached viewer: focus moving onto the target between planning and mutation still blocks the close
ok - attached viewer: a close preserves the fresh non-target focus the viewer moved to
ok - attached viewer: the projection seeded-tab prune refuses while a live client watches it
ok - attached viewer: detaching releases the refusal, so the guard tracks the client and not the pointer
```

Both halves of the recipe are load-bearing, and each was measured by removing it from the helper and re-running the guard on the same host and release.
Dropping the `TIOCSWINSZ` call and dropping the environment scrub each left startup reporting `no_foreground_client`, followed by the guard failure:

```text
not ok - could not attach a real foreground Herdr viewer over a sized pty
```

Re-run this guard after every Herdr upgrade.
A release that changed the foreground-client contract, the window-grid requirement, or the nested-viewer refusal would fail here first, and the detached regressions would keep passing while saying nothing about it.

### Presentation version floor

Default-on presentation projection is floored at Herdr 0.8.0.
The floor's structural signal is the selected running server's protocol number, falling back to the client protocol only when that selected session positively reports no running server, and the release mapping was measured on 2026-08-05 by running each pinned upstream macOS aarch64 release asset's own `status --json` through the guarded lab helper:

| Release | Reported version | Protocol | Carries both upstream focus fixes | Floor verdict |
|---|---|---|---|---|
| v0.7.3 | 0.7.3 | 16 | no | below |
| v0.7.4 | 0.7.4 | 16 | no | below |
| v0.7.5 | 0.7.5 | 17 | no | below |
| preview-2026-07-21-0f10e1453a7f | 0.7.5-preview.2026-07-21-0f10e1453a7f | 17 | no | below |
| preview-2026-07-29-44b3adb12552 | 0.7.5-preview.2026-07-29-44b3adb12552 | 18 | yes | below |
| preview-2026-08-04-d78e3d3b5126 | 0.8.0-preview.2026-08-04-d78e3d3b5126 | 19 | yes | above |
| v0.8.0 | 0.8.0 | 19 | yes | above |

No build lacking both fixes reaches protocol 19, and every pre-fix build tops out at 17, so protocol 19 is a safe structural expression of the 0.8.0 floor.
The one post-fix build below it is a preview that still reports a 0.7.5 version, so it is conservatively treated as below the floor, which costs a preview build its projection and never lets an unfixed build through.
The 2026-08-05 named-lab cross-version probe started a server from Herdr 0.7.5 and queried it with the installed 0.8.0 client; status reported client version 0.8.0 protocol 19, server version 0.7.5 protocol 17, server running true, and server compatible false.
That ordinary post-upgrade shape proves the running server owns the focus behavior, so the unconfigured default composes client and selected-server verdicts conservatively and rechecks after server ensure before publishing a journal or creating a workspace.

Refresh this table with the opt-in guard, which re-downloads the pinned assets, verifies their digests, and fails naming any release whose reported version, protocol, or verdict has moved:

```sh
FM_HERDR_VERSION_FLOOR_LIVE_E2E=1 tests/fm-herdr-version-floor-live-e2e.test.sh
```

The classifier itself, the config preference it composes with, and the one-warning-per-release behavior are pinned portably with no Herdr installed:

```sh
tests/fm-backend-herdr.test.sh
```

Observed guarantees: every measured release classifies as the table records; either the protocol or the version signal alone carries an at-or-above verdict, and each divergent pair flips once the carrying signal is removed; client and running selected-session server verdicts compose conservatively, an unreadable server-running state and losing both release signals report indeterminate and fall back flat, the default is rechecked after server ensure before projection publication, an unconfigured home is projected only at or above the floor, an explicit `on`, including the historical empty opt-in file, is honored below it, and the below-floor warning is emitted once per home per detected release rather than once per spawn.

The whole real-Herdr lane was run on 2026-08-05 against both the CI-pinned Herdr 0.7.4 protocol 16, which is below the floor, and Herdr 0.8.0 protocol 19, which is at it:

```sh
HERDR_LAB_HELPER=bin/fm-herdr-lab.sh bin/fm-test-run.sh --lane real-herdr-gated
```

Both runs reported `family=real-herdr-gated count=11 failed=0`.
The projection suite's unconfigured-home case is release-aware rather than pinned to one outcome, so it proves the projected default on 0.8.0 and the flat fallback with its naming warning on 0.7.4:

```text
ok - real Herdr lab: a home that configured nothing is projected by default on herdr 0.8.0
ok - real Herdr lab: a home that configured nothing falls back flat on below-floor herdr 0.7.4 with one naming warning
```

Every other case in that suite uses an explicit opt-in or opt-out, so the floor leaves them unchanged on both releases.

Direct lab probes on 2026-07-28 established the removal rules the emptying-close plan relies on, each verified with `workspace list` focus reads around one mutation in a guarded `fm-lab-` session:

- An explicit `pane close` that emptied a non-focused workspace moved focus off the focused workspace in both before-focus and after-focus geometries.
- Ending a workspace's lone shell preserved the focused workspace exactly when the dying workspace sat behind it or the focused workspace was last, and moved focus to the focused workspace's right neighbor otherwise.
- The production focus-preserving close in the dangerous geometry repositioned the doomed workspace, ended its proved shell, and left every concurrent focus sample on the exact anchor with no corrective `tab focus` issued.

Two real-hardware conditions were required for the pane-death path to engage and are now encoded in the adapter and its unit fixtures: BSD `ps` reports a login shell's `comm` as `-zsh`, and an idle shell transiently hosts a prompt helper (starship) as a second foreground process immediately after a `workspace.move` relayout, which the bounded settle window absorbs.

The rules match the v0.7.5 tag source (`close_selected_workspace` reassigns focus from the closing workspace's index; `handle_pane_died` only clamps the stale focused index), and the upstream default branch resolves both paths by workspace id (PR #1877, commit `165dca45`, for the explicit close; PR #1912, commit `a979916`, for pane death), so the plan degrades to a harmless reorder-then-remove once a release carries them.

The full projection and restored-shell suites were re-run on 2026-07-28 on Herdr 0.7.5 with the updated close path; the presentation suite completed with `real Herdr lab validation completed on Herdr 0.7.5 with the default-session tripwire intact`, and the restored-shell cleanup guarantee above was unchanged.

The teardown-level record-retention gate was verified on 2026-07-28 with metadata fixtures and a live contending lock holder:

```sh
tests/fm-teardown.test.sh
tests/fm-backend-herdr.test.sh
```

Observed guarantees: a contended presentation lock refused the teardown before the isolated copy was returned, with the task branch, every durable record, and the endpoint intact and no pane close attempted; the retry after the contention cleared returned the copy, closed the pane under the lock, and removed the records; an unknown structured-presence result after an attempted projected close retained the journal and every record with a nonzero exit; and every presence-gate mode accepted only a structured not-found as gone.

The same fixtures verified three further boundaries on 2026-07-29: missing or malformed endpoint identity and an unparseable pane presence refused record removal with everything retained; the SIGKILL escalation re-read the exact pane's process information and refused to signal when a different shell pid owned the pane, falling back to the plain close with the original process untouched; and a reposition whose removal then failed on every path restored the exact original workspace order through a second verified move and reported the close as failed.

The teardown fixture was re-run on 2026-07-31 after extending the same fail-closed boundary through forced secondmate cleanup, including recursive cleanup of a nested secondmate whose Herdr grandchild close remains unconfirmed.

Observed output:

```text
ok - forced secondmate teardown preflights every Herdr child before cleanup mutation
ok - forced secondmate teardown retains Herdr child identity until exact pane disappearance
ok - forced teardown retains a nested secondmate home and its grandchild's Herdr identity when the grandchild close is unconfirmed
```

### Composer and operational input

Real captures verified these active distinctions:

- Claude and Codex use bare `❯` and `›` agent composers.
- Pi uses content between complete separator rows and requires exact native Pi identity.
- Dim or faint suggestion text is ghost content, while normally styled text is pending input.
- Grok dark truecolor placeholders are ghost content, while bright truecolor typed input remains pending.
- On a kiro pane only, a near-achromatic truecolor run up to `FM_COMPOSER_GHOST_GRAY_LUMA_MAX` is ghost content, while a chromatic glyph at similar luminance stays real; every other harness keeps the shared ceiling, so Claude's grey slash-command input stays typed input.
- On a kiro pane only, a 256-colour index is luminance-tested as ghost content inside the 232-255 greyscale ramp, whose RGB is fixed by definition; every other index, and every index on another harness, is not tested at all.
- A bare shell prompt has no safe agent-composer container and is unknown.

The U+2063 operational and routed-request separators were exercised through a real Pi-on-Herdr path; that live regression is no longer shipped.

### Native blocked event

The protocol-16 event path was measured on 2026-07-11 with Herdr 0.7.3 and Python 3.13:

```sh
HERDR_LAB_HELPER=bin/fm-herdr-lab.sh \
  tests/fm-backend-herdr-eventwait-smoke.test.sh
```

Observed output:

```text
ok - real herdr: events.subscribe capability gate passes
ok - real herdr: a driven idle->blocked transition returns the blocked record in 0.129s
ok - real herdr: the watcher fast-path enqueues a stale wake naming the task window
```

Polling remained active and is covered as the fallback for capability, connect, subscribe, and repeated reader failure.

### Agent lifecycle control

Herdr is one of the two backends whose recovery-grade agent-state classifier the control plane may trust ([agent-control.md](../agent-control.md)), so its lifecycle gating is measured against the real binary; reverified 2026-08-08 on Herdr 0.8.0, and first measured 2026-08-02 on Herdr 0.7.5 with identical results:

```sh
tests/fm-control-herdr-smoke.test.sh
```

Observed output, refreshed 2026-09-10 on Herdr 0.9.0 after the stale-registration fix (the two stale-registration lines are recorded under "Stale agent registration" below):

```text
ok - real herdr: exit on a pane with no registered agent is idempotent success
ok - real herdr 0.9.0: a gone session reads recoverable while a live pane and a malformed target do not
ok - real herdr: a drifted agent-free shell returns to its worktree and reuses the same endpoint
ok - real herdr: interrupt refuses when herdr's own agent registry reports no agent
ok - real herdr: interrupt delivers the harness's key and proves the agent survived it
ok - real herdr: no control verb removed the endpoint or the task's local copy
ok - real herdr 0.9.0: a registration Herdr keeps after its agent exits reads stale-agent and recovers as dead
ok - real herdr: exit on a pane with a stale registration is idempotent success
ok - real herdr: a stale registration no longer blocks relaunch, and the endpoint and local copy survive
ok - real herdr: an agent that does not stop fails closed instead of being reported as stopped
```

The registry read through `herdr pane report-agent` is the same source `fm_backend_herdr_agent_state` classifies, and since 2026-09-10 that registration counts as an agent only while `pane process-info` shows a harness process behind it, so the guard backs the registration with a real process named like a harness (using `fm_agent_standin` from [`tests/lib.sh`](../../tests/lib.sh)) and then stops that process, with no real harness launched.
That command is the guard that refreshes this record; run it after every Herdr upgrade rather than trusting the version above.

For Pi on Herdr 0.9.0, `herdr agent get` reflects whether the agent process remains live; its registration does not persist merely because the pane and parent shell do.
A Pi launched as a child of the pane shell (not via `exec`) that then `/quit`s or is SIGKILL'd leaves the pane and shell in place, and `agent get` returns `agent_not_found`.
A sibling live idle Pi stays `agent=pi` with `agent_status=idle`.
`fm_backend_herdr_pane_agent_state` maps that `agent_not_found` leftover shell to `no-agent` once `pane process-info` shows nothing but shells with no harness below them, and `fm_backend_herdr_agent_state` maps it to `dead`, which allows a relaunch, while the live idle pane stays `alive`.
`herdr pane get` `.agent_status` can still read `idle` after the occupant is gone; liveness is `agent get`, never that pane field.

```sh
tests/fm-backend-herdr-agent-exit-shell-e2e.test.sh
```

Refresh that live pair after every Herdr upgrade. Observed 2026-09-10 on Herdr 0.9.0 / protocol 22 with Pi 0.82.0 in an isolated `fm-lab-` session:

```text
ok - agent get distinguishes leftover-shell (dead/no-agent) from live idle Pi
ok - pane get agent_status lag cannot keep an exited occupant classified alive
```

### Endpoint recovery classification

Measured 2026-09-10 on macOS aarch64 against Herdr 0.9.0 (protocol 22) in an isolated `fm-lab-` session.

An endpoint recorded in a session whose server is not running cannot be read by any operational call, and `status` is the one command that answers with a body instead of refusing:

```sh
herdr pane get w1:p2 --session fm-lab-never-started
herdr status --json --session fm-lab-never-started | jq -c "{running: .server.running, status: .server.status}"
```

```text
{"id":"cli:pane:get","error":{"code":"server_not_running","message":"no herdr server is running at /Users/<user>/.config/herdr/sessions/fm-lab-never-started/herdr.sock; run `herdr session attach fm-lab-never-started` to start or attach it"}}
{"running":false,"status":"not_running"}
```

`fm_backend_herdr_agent_state` therefore settles an uninterpretable pane read with `.server.running` rather than with the `server_not_running` error code, which keeps the verdict working across the supported range: the field is present on 0.8.2 protocol 20 and 0.9.0 protocol 22 alike (measured in "Client selection" above), while the code is not.
Only that recovery-grade read is widened; the husk classifier under it stays strict, because it licenses closing panes.
Observed in the lab, in one run:

```text
live agent-free pane                 dead
endpoint in a session with no server missing
malformed target                     unreadable
```

The same run drove `bin/fm-spawn.sh --relaunch` against a real Herdr pane whose shell had been moved outside its recorded worktree: the shell was told once to return, ended in the recorded worktree, and the replacement was launched into the SAME pane, leaving one task tab.

Herdr 0.8.x is not installed on this host, so protocol-20 coverage is structural plus the adapter fixture exercising both response shapes; it is not a live result.
Refresh the live half, which fails naming the installed version, with:

```sh
tests/fm-control-herdr-smoke.test.sh
```

Observed 2026-09-10:

```text
ok - real herdr 0.9.0: a gone session reads recoverable while a live pane and a malformed target do not
ok - real herdr: a drifted agent-free shell returns to its worktree and reuses the same endpoint
```

`tests/fm-backend-herdr.test.sh` pins the logic portably by driving the two signals apart - the same failed pane read yields `missing` under a stopped server and `unreadable` under a running one - and asserts that the husk classifier still refuses on that identical read.
`tests/fm-control-herdr-smoke.test.sh` proves the Herdr-only drift recovery against a real binary in an isolated lab session.
`tests/fm-control-relaunch.test.sh` drives a tmux stub and proves that tmux retains its prior refusal without sending `cd` or any other input to the pane.
The Herdr refusal when a shell accepts the command but does not move is not exercised in this change.

### Stale agent registration

Measured 2026-09-10 on macOS aarch64 against Herdr 0.9.0 (protocol 22) and Pi 0.85.1 in an isolated `fm-lab-` session (upstream issue #4115, duplicates #3639, #3487, #2908, #3545).

Herdr keeps a Pi registration after the Pi process has exited to a shell when a nested interactive shell sits under the pane's top shell, which is the crew shape `treehouse get` leaves behind; a plain `/quit` directly under the top shell, and a `kill -9` of Pi, both released it on this version.
Reproduced in the lab with a nested `zsh` under the pane shell, then `pi` with no prompt, then `/quit`:

```sh
herdr pane run w1:p1 zsh --session "$LAB"; herdr pane run w1:p1 pi --session "$LAB"
herdr agent get w1:p1 --session "$LAB" | jq -c '.result.agent | {agent, agent_status}'
herdr pane process-info --pane w1:p1 --session "$LAB" | jq -c '.result.process_info | {shell_pid, fg: .foreground_process_group_id, procs: [.foreground_processes[] | {pid, name, argv0}]}'
herdr pane send-text w1:p1 '/quit' --session "$LAB"; herdr pane send-keys w1:p1 Enter --session "$LAB"
herdr agent get w1:p1 --session "$LAB" | jq -c '.result.agent | {agent, agent_status}'
herdr pane process-info --pane w1:p1 --session "$LAB" | jq -c '.result.process_info | {shell_pid, fg: .foreground_process_group_id, procs: [.foreground_processes[] | {pid, name, argv0}]}'
```

```text
{"agent":"pi","agent_status":"idle"}
{"shell_pid":87754,"fg":35952,"procs":[{"pid":35952,"name":"node","argv0":"pi"}]}
{"agent":"pi","agent_status":"idle"}
{"shell_pid":87754,"fg":35834,"procs":[{"pid":35834,"name":"zsh","argv0":"zsh"}]}
```

Before the fix `fm_backend_agent_state herdr` read that second state as `alive`, so `bin/fm-control.sh <id> relaunch` and `bin/fm-spawn.sh --relaunch` were refused for as long as the registration lived, which is hours.
The registration is still present after the wait, and Herdr's own `pane report-agent` leaves the same shape behind on any pane, which is what the lifecycle-control guard uses.

Two vendor facts the fix rests on, both read from the outputs above and from `fm_backend_herdr_pane_process_state`'s `pane process-info` parse:

- Pi's process presents with kernel name `node` and argv0 `pi` (its foreground group also carries Pi's child `node` helpers with argv0 such as `npm view ... version`), so a running Pi is attributed by argv[0] exactly as the tmux probe attributes it; a symlink named `claude` to `sleep` presents as name `sleep`, argv0 `claude`.
- Herdr creates the record with its own placeholder `agent_status` of `unknown` the moment it notices Pi, before Pi's extension reports `idle`; that transient reads `unknown` in the pane classifier as it always did, and only a lifecycle status is subject to the process-level proof.

Subcommand presence below the 0.9.0 measurement, checked 2026-09-10 on macOS aarch64 against the pinned upstream release clients fetched from `https://github.com/ogulcancelik/herdr/releases/download/v<version>/herdr-macos-aarch64` (now redirected to `herdrdev/herdr`):

| Release | sha256 |
|---------|--------|
| 0.7.1 | `16f4653f0491ea1e7d2b46b5b02542f18e1b82e88daaf9e2900572e5bb634df8` |
| 0.7.3 | `b31345392d004ec1f1b2c821e1ad601019fa8385fe1e4c6931321eb58a920773` |
| 0.7.4 | `24992e1625dbdcb18354a59e299e4b263c312400b31396cdc07cd46ed57f24a7` |
| 0.7.5 | `37350546b0012555943b92eaf962665de4e264395baeb44227b8015e8ff5b0d6` |

The command run against each client was `<client> pane --help`, which is client-side, session-independent, and opens no socket, and each printed the line:

```text
process-info  Show pane process information
```

This proves subcommand presence in the client only, not the server response shape, which is measured only on 0.9.0 above.

The live guard that refreshes this record runs by default wherever Herdr and Pi are installed, spends no model token, and fails naming both versions:

```sh
tests/fm-herdr-pi-stale-registration-live-e2e.test.sh
```

Observed 2026-09-10:

```text
# pi 0.85.1 under herdr 0.9.0: registered idle, foreground [{"name":"node","argv0":"node"},{"name":"node","argv0":"node"},{"name":"node","argv0":"rpiv-ask-user-question version"},{"name":"node","argv0":"npm view gentle-engram version"},{"name":"node","argv0":"pi"}]
ok - real herdr 0.9.0 + pi 0.85.1: a running registered pi classifies alive at process level
# herdr 0.9.0 kept the pi registration (idle) after /quit under a nested shell: the stale-registration branch is exercised
ok - real herdr 0.9.0 + pi 0.85.1: the registration left behind by a quit pi reads stale-agent and recovers as dead
```

`tests/fm-control-herdr-smoke.test.sh` proves the same shape through the control plane with no harness launched (the two `stale` lines under "Agent lifecycle control" above): a registration over a real agent-named process reads `alive`, stopping that process makes the pane read `stale-agent` and recover as `dead` while `agent get` still reports the record, `exit` then reports `already-stopped`, and `--relaunch` reuses the same endpoint with the local copy intact.
`tests/fm-backend-herdr.test.sh` pins the logic portably with canned `process-info` bodies over real processes, driving the signals apart: the identical shell-only foreground reads `stale-agent` for a childless shell and `live` when an agent-named process is still a descendant of that shell, a `working`, `done`, or `blocked` record over a shell-only pane reads the same as `idle`, an unreadable process view reads `unknown` and refuses husk closing, a transient prompt helper beside the shell settles into `stale-agent` on the next shell-only sample while a foreground that never settles within the bound still reads `live`, and `busy_state` verifies a `working` record before reporting busy.
`tests/fm-crew-state.test.sh` pins the recovery classifier: a stale registration over a shell-only pane reports agent gone rather than alive or unreachable, and a stale `working` record never reports the pane working.
A stale-registration pane is never a husk: create, reclaim, presentation recovery, and session cleanup keep refusing it, and only recovery reuses it.

### Agents the nono sandbox runs

Measured 2026-10-17 on macOS aarch64 against Herdr 0.9.5, nono 0.80.0, and Pi 1.2.0 in an isolated `fm-lab-` session.
One Pi worker was launched in a pane with the wrapper `bin/fm-spawn.sh` builds when `config/agent-sandbox` is set, and the same live pane was read through the adapter before and after this change.

`agent get` answered `agent_not_found`, and the process view under the pane shell was:

```text
{"shell_pid":89133,"foreground_process_group_id":89730,"foreground":[{"pid":89856,"name":"log"},{"pid":89730,"name":"nono"}]}
89133 88848 89133 89730 ttys010  Ss   -zsh
89730 89133 89730 89730 ttys010  S+   nono
89855 89730 89855 89855 ttys012  Ss+  pi
89856 89730 89730 89730 ttys010  S+   /usr/bin/log
```

Pi is a child of `nono` but leads a session of its own on another terminal, so neither the pane's foreground group nor its tty contains it.
Herdr kept answering `agent_not_found` through a whole turn in that run.
An earlier run showed a short-lived placeholder record during a turn, `agent=pi` with `agent_status=unknown` and then `working`, which went back to `agent_not_found` once the turn ended.
Pi 1.2.0 draws its busy indicator into the editor's top border as `── ⠸ Working ───`, a shape the Pi busy pattern did not match before this change.

Before the change, every reader took the live worker for an exited one.
The doorbell was withheld, an explicit send was refused, and `fm-spawn --relaunch` typed its launch line into the live Pi, which queued it as a steering message:

```text
agent_state=dead agent_alive=dead composer=unknown busy=unknown
fm-send: doorbell not typed because the agent in fm-lab-sandbox-liveness-88824-28407:w1:p1 has exited; the steer is durably recorded at /tmp/fm-sandbox-liveness-misread/proof.qQP2sT/home-BASE/state/sbx1.inbox/001.msg for recovery (stuck-crewmate-recovery), and the watcher will not re-ring a dead pane
error: text not submitted to fm-lab-sandbox-liveness-88824-28407:w1:p1 (delivery unconfirmed; verdict=unknown; tried explicit target 'fm-lab-sandbox-liveness-88824-28407:w1:p1' matched /tmp/fm-sandbox-liveness-misread/proof.qQP2sT/home-BASE/state/sbx1.meta; backend=herdr)
spawned sbx1 harness=pi kind=ship mode=no-mistakes yolo=off window=fm-lab-sandbox-liveness-88824-28407:w1:p1 worktree=/tmp/fm-sandbox-liveness-misread/proof.qQP2sT/wt
 Steering: . '/tmp/fm-sbx1+f07c64f3aa0ffbdf483f2ec2d9e74d011ac4d2a8e991502e296b9f77e5c24109/launch.s1792235365.97923...
```

After it, both sends returned 0, Pi answered the explicit one, the relaunch refused, and the pane read `dead` and admitted a launch only once Pi had quit:

```text
agent_state=alive agent_alive=alive composer=empty busy=idle launch_pane=occupied
error: task sbx1's endpoint reads 'alive'; a relaunch requires a positively agent-free endpoint (stop the agent first with bin/fm-control.sh sbx1 exit)
agent_state=dead agent_alive=dead composer=empty busy=unknown launch_pane=shell
```

The native busy verdict stays `unknown` for such a pane, because only a registration carries it.
The live guard that refreshes this record spends no model token:

```sh
tests/fm-herdr-pi-sandbox-live-e2e.test.sh
```

```text
# sandboxed pi: foreground ["log","nono"], herdr registration 'agent_not_found'
ok - real herdr 0.9.5 + nono 0.80.0 + pi 1.2.0: a sandboxed pi reads alive, refuses a launch, and has a provably empty composer
ok - real herdr 0.9.5 + nono 0.80.0 + pi 1.2.0: a quit sandboxed pi reads dead and admits a launch
```

`tests/fm-backend-herdr.test.sh` pins the same process layout portably.
`tests/fm-control-relaunch.test.sh` pins the launch check on its own: a `dead` reading over a pane still running a harness refuses in both `fm-control relaunch` and `fm-spawn --relaunch` before anything is typed.
`tests/fm-herdr-session-cleanup.test.sh` proves session cleanup leaves such a pane alone, and `tests/fm-composer-lib.test.sh` pins the Pi busy indicator from the captured row.

### Agents resumed by a restart

Measured 2026-10-06 on macOS aarch64 against Herdr 0.9.3 and Pi 1.0.3 in an isolated `fm-lab-` session, with `session.resume_agents_on_restore` at its default.
A pane created in `primary/` ran a nested `bash --norc`, which entered `wt/`, exported `FM_TASK_ID`, and started `pi --session wt/session.jsonl`; the lab server was then stopped and provisioned again:

```sh
herdr pane get "$PANE" --session "$LAB" | jq -c '.result.pane | {cwd, foreground_cwd, agent_session}'
herdr pane process-info --pane "$PANE" --session "$LAB" | jq -c '.result.process_info | {shell_pid, fg: [.foreground_processes[] | {pid, name, argv0}]}'
lsof -a -p "$PI_PID" -d cwd -Fn
```

```text
before: {"cwd":".../primary","foreground_cwd":".../wt","agent_session":{"agent":"pi","kind":"path","source":"herdr:pi","value":".../wt/session.jsonl"}}
before: {"shell_pid":31016,"fg":[{"pid":32223,"name":"node","argv0":"pi"}]} cwd .../wt
after:  {"cwd":".../primary","foreground_cwd":".../primary","agent_session":{"agent":"pi","kind":"path","source":"herdr:pi","value":".../wt/session.jsonl"}}
after:  {"shell_pid":33573,"fg":[{"pid":33822,"name":"node","argv0":"pi"}]} cwd .../primary
```

Herdr resumed Pi on its recorded session, directly under a fresh pane shell in the top shell's directory, and the pane's terminal id changed.
In the same lab, an OSC 7 report printed from the nested shell left `.result.pane.cwd` unchanged, and a variable set with `tab create --env` was unset in the restored shell.
A `cd` in the pane's top shell does move `.result.pane.cwd`, and the restored shell starts there.
`ps -E` printed no environment for the Pi process, because Node overwrites the argument block macOS keeps the environment in.

The live guard that refreshes this record runs by default wherever Herdr and Pi are installed, spends no model token, and fails naming both versions:

```sh
tests/fm-herdr-restore-isolation-live-e2e.test.sh
```

Observed 2026-10-06:

```text
ok - real herdr 0.9.3 + pi 1.0.3: a launched worker in its worktree is not flagged
# herdr resumed pi with launch-isolation verdict: outside /private/var/folders/.../fm-herdr-restore-isolation.yJeEMd/primary
ok - real herdr 0.9.3 + pi 1.0.3: a worker resumed by a server restart reads as an unsafe blocked worker
```

`tests/fm-backend-herdr.test.sh` pins the verdict over real processes with canned `process-info` bodies, and `tests/fm-crew-state.test.sh` pins the blocked state, the task-marker read through a `/proc` fixture, and the secondmate exemption.

### Fullscreen Pi scrollbar and the stale hash

[`bin/fm-pane-hash-lib.sh`](../../bin/fm-pane-hash-lib.sh) owns the hash the watcher compares between polls, and [`tests/captures/pi-1.0.2-herdr-0.9.3/README.md`](../../tests/captures/pi-1.0.2-herdr-0.9.3/README.md) holds the replay captures behind its portable test.
Measured 2026-10-05 on Darwin arm64 against Herdr 0.9.3 and Pi 1.0.2, in isolated `fm-lab-` sessions (`bin/fm-herdr-lab.sh`).

A Herdr `pane read --source recent` longer than the viewport, which `fm_backend_herdr_scrollback_capture` issues, makes fullscreen Pi draw its scrollbar in the pane's last column for about one second once the transcript exceeds the viewport.
The same read returns a varying number of rows from above the viewport.
A `--source visible` read never triggers the scrollbar but shows one that another reader triggered.
Regular mode never draws it.
So the hash reads a Herdr Pi pane's viewport and strips the scrollbar column, and both halves are needed: a stripped 40-line tail still changed about one poll in ten on an unchanged pane, and an unstripped viewport changed whenever another reader had read the pane within the last second.
The stripped viewport kept one digest across 120 one-second polls of an idle fullscreen pane, 59 of them mid-flash, with a 200-line `--source recent` read every third poll and another reader every 4 s.

The real `bin/fm-watch.sh`, with `FM_POLL=3` and `FM_STALE_ESCALATE_SECS=30`, watched an idle regular-mode worker and an idle fullscreen worker, both spawned by `bin/fm-spawn.sh` with a transcript longer than the viewport, while `bin/fm-peek.sh`, which then issued that `--source recent` read, read both panes every 4 s:

```text
t+33s signal: fs4.turn-ended reg4.turn-ended
t+48s stale: FULLSCREEN
t+52s stale: REGULAR
t+84s stale: FULLSCREEN (idle 32s, possible wedge, escalation 1)
t+88s stale: REGULAR (idle 31s, possible wedge, escalation 1)
t+120s stale: FULLSCREEN (idle 32s, possible wedge, escalation 2)
t+124s stale: REGULAR (idle 33s, possible wedge, escalation 2)
```

The same probe with no concurrent reader:

```text
t+35s signal: fs5.turn-ended reg5.turn-ended
t+51s stale: FULLSCREEN
t+55s stale: REGULAR
t+88s stale: FULLSCREEN (idle 33s, possible wedge, escalation 1)
t+93s stale: REGULAR (idle 34s, possible wedge, escalation 1)
t+126s stale: FULLSCREEN (idle 33s, possible wedge, escalation 2)
t+130s stale: REGULAR (idle 33s, possible wedge, escalation 2)
```

The live guard that refreshes this record runs by default wherever Herdr, Pi, jq, and Perl are installed, spends no model token, and fails naming both versions:

```sh
tests/fm-herdr-pi-fullscreen-scrollbar-live-e2e.test.sh
```

Observed 2026-11-11 on Linux x86_64 against Herdr 0.9.5 and Pi 1.5.1:

```text
# fullscreen pi 1.5.1 under herdr 0.9.5: scrollbar rows quiet 0, flash 34
ok - real herdr 0.9.5 + pi 1.5.1: a fullscreen pane hashes the same with and without its transient scrollbar
ok - real herdr 0.9.5 + pi 1.5.1: a regular-mode pane draws no scrollbar and hashes its viewport as the plain digest
```

### Recent reads wheel-scroll an idle fullscreen agent

Measured 2026-11-11 on Linux x86_64 against Herdr 0.9.5 and Pi 1.5.1, in isolated `fm-lab-` sessions from `bin/fm-herdr-lab.sh`, with a Pi extension appending every stdin chunk to a file.
The pane held an idle fullscreen Pi whose transcript was longer than its 40-row viewport.

| Read | Bytes written to Pi's stdin | Wheel-up reports | Wheel-down reports | Frames Pi drew |
| --- | --- | --- | --- | --- |
| None, for 3 s | 0 | 0 | 0 | 0 |
| `herdr pane read <pane> --source visible` | 0 | 0 | 0 | 0 |
| `herdr pane read <pane> --source recent --lines 200` | 564 | 12 | 35 | 8 |

Herdr harvests the rows above an alternate-screen viewport by scrolling the agent itself, so every such read costs the agent a burst of redraws.
The same `--source recent --lines 200` read against a raw-mode process that logs its stdin, started after 300 printed lines, shows which panes Herdr scrolls:

| Pane | Bytes written to the process's stdin | Wheel-up reports | Wheel-down reports |
| --- | --- | --- | --- |
| Main screen, no reported agent | 0 | 0 | 0 |
| Main screen, agent reported as `claude` | 0 | 0 | 0 |
| Alternate screen with mouse reporting, no reported agent | 0 | 0 | 0 |
| Alternate screen with mouse reporting, agent reported as `claude` | 108 | 3 | 6 |
| Alternate screen with mouse reporting, agent reported as `codex` | 108 | 3 | 6 |
| Alternate screen with mouse reporting, agent reported as `pi` | 108 | 3 | 6 |

The agent was reported with `herdr pane report-agent <pane> --source lab-probe --agent <name> --state idle`.
So the scroll does not depend on Pi: Herdr wheel-scrolls any alternate-screen pane whose agent it knows.
On every alternate-screen pane `--source recent --lines 5` returned nothing, and on the main-screen panes it returned the pane's last rows.

`fm_backend_herdr_capture` therefore reads the viewport, and `fm_backend_herdr_scrollback_capture`, reached only through `bin/fm-peek.sh --scrollback`, is the one `--source recent` read.

The live guard that refreshes this record runs by default wherever Herdr, Pi, jq, and Perl are installed, spends no model token, and fails naming both versions:

```sh
tests/fm-herdr-timer-read-no-input-live-e2e.test.sh
```

Observed 2026-11-11:

```text
ok - real herdr 0.9.5 + pi 1.5.1: bounded captures, fm-peek, fm-crew-state, and the watcher's polling write nothing to an idle fullscreen pane
# herdr 0.9.5: the scrollback read returned 55 rows past a 40-row viewport and wrote 564 bytes to pi's stdin
ok - real herdr 0.9.5 + pi 1.5.1: fm-peek --scrollback reads above the viewport
```

### Fullscreen Pi workers and second mates

Pi workers and second mates launch in Pi's default fullscreen TUI ([`fm-spawn.sh --help`](../../bin/fm-spawn.sh) owns the launch).
Measured 2026-10-05 on Darwin arm64 against Herdr 0.9.3 and Pi 1.0.2, in an isolated `fm-lab-` session with a lab home.
A fullscreen scout and a fullscreen seeded second mate, each spawned by `bin/fm-spawn.sh`, ran beside a control of the same kind launched with `--tui-mode regular`, with turns from a scripted faux provider extension so no model token was spent.
Every check below gave the same answer in both modes, for the scout and for the second mate:

- `bin/fm-crew-state.sh` while idle, mid-turn, after a finished turn, and after exit.
- Busy classification while idle, mid-turn, and stalled mid-turn, from the Pi extension for the scout and from Herdr's native state for the second mate.
- Composer state while empty, while holding typed text, after clearing, and after relaunch.
- A `bin/fm-send.sh` steer read and moved to `handled/` when sent mid-turn, when idle, and after relaunch, and the doorbell skipped over a typed draft without touching it.
- `bin/fm-control.sh` interrupt (`cancel=unconfirmed` in both), relaunch, and exit.
- `bin/fm-peek.sh` showing the newest transcript row and the composer, and a 200-line `--source recent` read reaching the first transcript line.

The fullscreen worker drew 33 scrollbar rows after a long read, before and after relaunch, and the control drew none, so relaunch keeps the TUI mode.
The stale and wedge hash is the one supervision read that needed a change, recorded under "Fullscreen Pi scrollbar and the stale hash" above.

### Pane status authority across a relaunch

Measured 2026-09-21 on Linux x86_64 against Herdr 0.9.1 (client protocol 22) and Pi 0.86.1, in an isolated `fm-lab-` session (`bin/fm-herdr-lab.sh`), after the same freeze was observed live on a relaunched Pi crewmate whose pane read `idle` while its validation pipeline ran.

The stale registration above is not only a recovery-classification problem, because it is the pane's status AUTHORITY and it is bound to one agent session identity.
Herdr applies a lifecycle or session report only when it matches what it bound, so an agent started FRESH in that pane reports a new session into a pane that ignores it.
That is the shape `bin/fm-control.sh <id> relaunch` produced before #5161.
The pane then stays at whatever the previous agent last reported, so working reads idle indefinitely because the registration outlives its process.

Reproduced with a real Pi under a nested shell, `/quit`, and a second fresh Pi in the same pane:

```sh
# nested shell, then a real pi (a prompt is what makes the extension report;
# session_start alone did not register on this version)
herdr pane send-text w1:p1 'zsh' --session "$LAB"; herdr pane send-keys w1:p1 Enter --session "$LAB"
herdr pane send-text w1:p1 "$PI --tui-mode regular 'say ready'" --session "$LAB"; herdr pane send-keys w1:p1 Enter --session "$LAB"
herdr agent get w1:p1 --session "$LAB" | jq -c '.result.agent | {agent_status, session: .agent_session.value}'
herdr pane send-text w1:p1 '/quit' --session "$LAB"; herdr pane send-keys w1:p1 Enter --session "$LAB"
# then start a SECOND fresh pi in the same pane and re-read
```

```text
{"agent_status":"idle","session":"/home/u/.pi/agent/sessions/--wt--/2026-09-21T14-10-08-776Z_01a0c44d.jsonl"}
# after /quit: the registration and its session are still there, process gone
{"agent_status":"idle","session":"/home/u/.pi/agent/sessions/--wt--/2026-09-21T14-10-08-776Z_01a0c44d.jsonl"}
# after a FRESH second pi started working in that pane: unchanged
{"agent_status":"idle","session":"/home/u/.pi/agent/sessions/--wt--/2026-09-21T14-10-08-776Z_01a0c44d.jsonl"}
```

On Herdr 0.9.1 two repair paths were measured and did not work, so #5161 resumed the bound session instead:

- `herdr pane report-agent-session` and `report-agent` from another process were accepted with rc=0 and never applied for `--source herdr:pi`.
- `herdr pane release-agent --source herdr:pi --agent pi` on that stale registration was accepted with rc=0 and changed nothing, matching its documented guard that it only ends authority when the agent process exits.

Resuming handed the replacement its predecessor's whole conversation, so a relaunch no longer does it.

Measured 2026-11-03 on Linux x86_64 against Herdr 0.9.5 and Pi 1.4.0 with Herdr's Pi integration version 9, in an isolated `fm-lab-` session, with the crew shape above.
A sessionless `pane report-agent --source herdr:pi --agent pi --state idle --seq <microseconds>` sent after the quit does clear the binding.
The fresh Pi then binds its own new session file and its reports apply:

```text
# no clearing report: the fresh pi runs `sleep 15` but the pane reads idle on the old session for all 30 polls
     30 C: {"agent":"pi","agent_status":"idle","s":"1-9ec208f811d6.jsonl","src":"herdr:pi"}
# one sessionless report first: the binding clears, then the fresh session binds and reads working
B2 after idle: {"agent":"pi","agent_status":"idle","s":"","src":""}
      1 C 3: {"agent":"pi","agent_status":"idle","s":"e-db3a5b04655c.jsonl","src":"herdr:pi"}
     19 C 4-22: {"agent":"pi","agent_status":"working","s":"e-db3a5b04655c.jsonl","src":"herdr:pi"}
```

The same lab ran the real entry point end to end.
A Pi worker took one turn, then `bin/fm-control.sh <id> relaunch --note ...` replaced it in the same pane, and each turn was counted as user messages in the session file:

```text
# before this fix: the replacement resumed the first session file
A session: ...13-06-08-619Z_01a1a184-...4ac4.jsonl turns=1
B session: ...13-06-08-619Z_01a1a184-...4ac4.jsonl turns=2
# after this fix: a new session file, its turn count restarted, and status followed it
A session: ...13-03-46-280Z_01a1a182-...7b.jsonl turns=1
      5 B idle -
     21 B working ...13-04-53-454Z_01a1a183-...121a.jsonl
B session: ...13-04-53-454Z_01a1a183-...121a.jsonl turns=1
A session after relaunch: turns=1
```

`bin/backends/herdr.sh`'s `fm_backend_herdr_pane_session_binding_clear` sends the clearing report, and `docs/herdr-backend.md` "Agent status authority and relaunch" owns the contract.

## Pi supervision branch

The supervision-branch extension (`.pi/extensions/fm-branch-supervision.ts`, [docs/pi-supervision-branch.md](../pi-supervision-branch.md)) builds its second session through the Pi SDK surface: `createAgentSession` (including its `model`, `modelRuntime`, and `thinkingLevel` options), `DefaultResourceLoader` with `extensionFactories`, `SessionManager`, `createBashToolDefinition` with a `spawnHook`, `sendCustomMessage` for routine notes, `appendEntry` and `registerEntryRenderer` for captain outcomes, the `before_provider_request` hook, the command context's model registry for picker candidates, a fresh `ModelRuntime` for isolated-branch resolution, and Pi's own `getSupportedThinkingLevels`/`clampThinkingLevel` plus its `getThinkingLevel` and `thinking_level_select` extension surface for effort.
In TUI mode, its `/supervision-model` model list is drawn with Pi's own `SelectList`, `Input`, `fuzzyFilter`, and `DynamicBorder` through the extension context's `ui.custom` surface, which is what bounds and searches a long catalog.

Processing-retry visibility was verified on 2026-09-27 against Pi 0.87.1 with a local intercepted provider stream, without credentials or an external provider request:

```sh
bin/fm-test-run.sh tests/fm-pi-branch-extension.test.sh
FM_PI_BRANCH_LIVE_E2E=1 npm exec --yes --package=typescript@5.9.3 -- bin/fm-test-run.sh tests/fm-pi-branch-live-e2e.test.sh tests/fm-pi-primary-types.test.sh
```

```text
ok - real Pi SDK 0.87.1 suppresses only empty or exact-repeat retry finals, retains first and differing replies after reopen, buffers retry streaming, and keeps outcomes retryable
ok - tracked Pi extensions pass strict no-emit typecheck against Pi 0.87.1
```

The guard runs the extension through Pi's actual message event runner, renders its streamed replies with the stock assistant component, and checks both live agent state and a reopened session file.
The portable processing-turn case additionally covers whitespace-only replies, a one-character difference, prose alongside acknowledgment calls, signed reasoning and tool-call preservation, rejected and partial acknowledgements, busy follow-ups, user steering, and both orderings of a user message batched with a processing request.
Other primary harnesses do not load this Pi extension, and these event and persistence boundaries are independent of the runtime session backend.

Evidence produced 2026-08-25 on macOS 26.5.2 arm64, Node v24.13.1:

- Historical real-SDK guard: `FM_PI_BRANCH_LIVE_E2E=1 bin/fm-test-run.sh tests/fm-pi-branch-live-e2e.test.sh` against the globally installed `@earendil-works/pi-coding-agent` 0.81.1 printed `ok - real Pi SDK 0.81.1 accepts the branch session construction and preserves an unpromptable wake`.
  The guard read no credentials and made no provider call: an isolated empty `PI_CODING_AGENT_DIR` left model resolution empty, so the branch's first prompt failed fast and exercised the former direct-branch fallback.
  That fallback probe predates watcher-owned settlement and is not current evidence for the replacement-safe delivery boundary.
  The same run confirms that a real `ModelRegistry` over that empty agent dir still exposes the picker-facing availability surface, then pins `openai/no-such-live-model` and proves that the branch's own `ModelRuntime` refuses the unresolvable pin instead of silently running supervision on main's model.
- Model-pin precedence: the same guard run printed `ok - real Pi SDK 0.81.1 applies an explicit branch model on create and over a reopened session's recorded model`.
  It declares a local `fm-live-fake` provider in an isolated `models.json`, never contacts it, and proves through `session.model` that an explicit model is applied on create, still wins over the model a reopened session recorded, and is absent-pin-restorable - the SDK behavior needed when a model or effort change reopens the current main session's branch conversation.
- Effort-pin vendor contract: the same guard run printed `ok - real Pi SDK 0.81.1 reports its own supported effort levels and applies an explicit branch effort over a reopened session's recorded level`.
  Over its own local never-contacted provider it confirms that `getSupportedThinkingLevels` still returns `["off","minimal","low","medium","high","xhigh","max"]` for a model mapping every extended level, narrows to `["off","minimal","low","medium","high"]` for a reasoning model mapping none, returns `["off"]` for a non-reasoning model, and that `clampThinkingLevel` lowers `max` to `high` on the narrow model while collapsing an unrecognized token to `off` - which is why the extension rejects an unrecognized pin before that clamp can see it.
  It then proves through `session.thinkingLevel` that an explicit effort is applied on create, that a reopened session with no override restores its own recorded level, that an explicit effort beats that recorded level, and that an over-ceiling effort is clamped rather than refused.
  The recorded-level cases need a session file Pi will actually restore from, and Pi flushes one only once an assistant message exists, so the guard appends the level change and that message through the real `SessionManager` rather than hand-writing the format.
- Picker primitives: on 2026-08-26, after the final portable-shell and sentinel fixes, `bin/fm-test-run.sh tests/fm-pi-branch-extension.test.sh` again printed `ok - the installed Pi still bounds the picker's list and ranks its search` against the same installed 0.81.1 package.
  That case imports the real `SelectList`, `Input`, `fuzzyFilter`, and `DynamicBorder`, renders a 42-row catalog through the real `SelectList` at the visible bound the extension asks for, and fails naming the installed version if Pi stops exporting a primitive or stops bounding what it renders; it skips when no npm package is installed, and the portable stubbed cases in the same file hold the ordering, search, and branch-only-pin behavior everywhere.
- Strict typecheck: `tests/fm-pi-primary-types.test.sh` printed `ok - tracked Pi extensions pass strict no-emit typecheck against Pi 0.81.1` with the branch extension and its imported libraries included.
  [The extension's effort-vocabulary assertion](../../.pi/extensions/fm-branch-supervision.ts) owns that invariant; the [typecheck](../../tests/fm-pi-primary-types.test.sh) owns the checked SDK matrix.
- Historical custom-message provider conversion: on 2026-08-26, `FM_PI_BRANCH_LIVE_E2E=1 bin/fm-test-run.sh tests/fm-pi-branch-live-e2e.test.sh` against installed `@earendil-works/pi-coding-agent` 0.84.1 printed `ok - real Pi SDK 0.84.1 delivers a custom message to the provider as user text carrying only content, so the captain outcome's typed envelope is what reaches the model`.
  The guard passes a typed captain outcome and a plain rendered routine note through Pi's exported `convertToLlm`, proves that `customType` and `display` are not model-visible identity, and classifies the resulting provider text with `bin/fm-operational-input.sh`.
  This evidence explains the superseded model-relay path but is no longer the captain-delivery contract.

### 2026-08-28 Pi 0.84.4 SDK compatibility refresh

The credential-free live guard and strict typecheck were rerun against the installed `@earendil-works/pi-coding-agent` 0.84.4 package after the Pi primary compatibility repair.
The live guard used an isolated empty `PI_CODING_AGENT_DIR`, inspected no credentials, and made no provider call.

```sh
npm exec --yes --package=typescript@5.9.3 -- bash tests/fm-pi-primary-types.test.sh
FM_PI_BRANCH_LIVE_E2E=1 bin/fm-test-run.sh tests/fm-pi-branch-live-e2e.test.sh
```

```text
ok - tracked Pi extensions pass strict no-emit typecheck against Pi 0.84.4
ok - real Pi SDK 0.84.4 accepts the branch session construction and preserves an unpromptable wake
ok - real Pi SDK 0.84.4 applies an explicit branch model on create and over a reopened session's recorded model
ok - real Pi SDK 0.84.4 reports its own supported effort levels and applies an explicit branch effort over a reopened session's recorded level
ok - real Pi SDK 0.84.4 delivers a custom message to the provider as user text carrying only content, so the captain outcome's typed envelope is what reaches the model
FM_TEST_END 2026-08-29T01:01:01Z tests/fm-pi-branch-live-e2e.test.sh exit=0 duration_ms=2520 gate_skip=false
```

The focused extension suite also exercised the installed Pi 0.84.4 picker and outcome-renderer consumers; [`calm-mode-feasibility.md`](../calm-mode-feasibility.md#2026-08-28-pi-0844-outcome-renderer-compatibility-verification) owns the version-scoped renderer evidence.

### 2026-08-29 deterministic captain-outcome delivery

The credential-free live guard, focused extension suite, store suite, and strict typecheck were run against the locally installed `@earendil-works/pi-coding-agent` 0.84.3 package.
No model was selected or prompted, no provider call was made, and the active Pi session was not changed.

```sh
bin/fm-test-run.sh tests/fm-pi-branch-extension.test.sh
bin/fm-test-run.sh tests/fm-branch-supervision.test.sh
npm exec --yes --package=typescript@5.9.3 -- bash tests/fm-pi-primary-types.test.sh
FM_PI_BRANCH_LIVE_E2E=1 bin/fm-test-run.sh tests/fm-pi-branch-live-e2e.test.sh
```

```text
ok - captain outcomes are exact and exactly once across crash, reload, busy main, compaction, and an unrelated assistant response
ok - startup replay cannot advance the cursor across an unrendered captain outcome
ok - tracked Pi extensions pass strict no-emit typecheck against Pi 0.84.3
ok - real Pi SDK 0.84.3 immediately renders appendEntry in the active transcript, persists it across reopen, and excludes it from model context
```

The live probe loads the extension through Pi's real resource loader and AgentSession, subscribes a stock InteractiveMode, verifies `ExtensionAPI.appendEntry` synchronously inserts the exact registered custom row into its active chat once, reopens the resulting session file to verify exact structured data, and verifies the entry is absent from `buildSessionContext().messages`.
The focused regression recreates the incident topology with stale compaction framing and an immediately preceding unrelated assistant response, then covers idle and busy delivery, cold startup with late fleet-lock acquisition, the crash boundary after entry persistence but before cursor advancement, and repeated reload without duplication.

### 2026-09-01 sequence-keyed captain-outcome processing

The focused extension suite, store suite, strict typecheck, and credential-free live guard were run against a locally installed `@earendil-works/pi-coding-agent` 0.84.4 package selected with `FM_PI_PACKAGE_DIR`, on macOS 26.5.0 arm64, Node v24.13.1.
No model was selected or prompted, no provider call was made, and the active Pi session was not changed.

```sh
FM_PI_PACKAGE_DIR=<pi-0.84.4 package> bin/fm-test-run.sh tests/fm-pi-branch-extension.test.sh
bin/fm-test-run.sh tests/fm-branch-supervision.test.sh
FM_PI_PACKAGE_DIR=<pi-0.84.4 package> npm exec --yes --package=typescript@5.9.3 -- bash tests/fm-pi-primary-types.test.sh
FM_PI_BRANCH_LIVE_E2E=1 FM_PI_PACKAGE_DIR=<pi-0.84.4 package> bin/fm-test-run.sh tests/fm-pi-branch-live-e2e.test.sh
```

```text
ok - a captain outcome reaches main's model as one typed, sequence-keyed processing request while routine notes stay plain
ok - a captain outcome opens one sequence-keyed processing turn, survives empty and unrelated answers, is re-presented at run end and session start, and closes only on its acknowledgement
ok - the processed marker is sequence-bound, never ahead of the read cursor, never backwards, and migrates delivered history once
ok - tracked Pi extensions pass strict no-emit typecheck against Pi 0.84.4
ok - real Pi SDK 0.84.4 immediately renders appendEntry in the active transcript, persists it across reopen, and excludes it from model context
```

The focused regression recreated the two 2026-08-31 incident shapes against the real store scripts: a delivered decision outcome whose processing turn returned an empty assistant message, and one whose turn repeated an unrelated prior answer.
In both, the processed marker held, the same sequence was presented again at the run boundary and after a session replacement, the triggered-turn budget gave way to a next-prompt copy without duplicates, and only `fm_branch_processed` with the presented sequence closed the outcome; a routine outcome never entered the path.
The migration result in the historical output above is superseded: the current absent-marker rule is owned by `bin/fm-branch-outcome.sh`, and `tests/fm-branch-supervision.test.sh` covers it.
On this machine the globally installed npm package is 0.81.1, whose stock `ToolExecutionComponent` rendering differs from the 0.84 line and fails the suite's first rendering-consumer case before any delivery case runs, which is why `FM_PI_PACKAGE_DIR` points at the 0.84.4 install above.

### 2026-09-02 historical post-construction provider-error fallback

The focused extension suite, strict typecheck, and real-SDK guard were run against the npm `@earendil-works/pi-coding-agent` 0.84.4 package on macOS 26.5.0 arm64, Node v24.13.1, before fallback ownership moved from the branch extension to the watcher.
The real-SDK case configured an isolated local OpenAI-compatible model, intercepted its only `fetch` in-process with the incident's non-retryable 429 `Monthly usage limit reached` response, read no user credential, and allowed no external provider request.
It proved that Pi persisted an assistant message with `stopReason: "error"` and resolved the constructed branch prompt normally, after which the extension released the claimed-row grant, retained the durable queue row, and returned the exact wake to main as a follow-up.

```sh
FM_PI_PACKAGE_DIR="$HOME/.npm/_npx/1f276a68aabfc75c/node_modules/@earendil-works/pi-coding-agent" bash tests/fm-pi-branch-extension.test.sh
FM_PI_PACKAGE_DIR="$HOME/.npm/_npx/1f276a68aabfc75c/node_modules/@earendil-works/pi-coding-agent" bash tests/fm-pi-primary-types.test.sh
FM_PI_BRANCH_LIVE_E2E=1 FM_PI_PACKAGE_DIR="$HOME/.npm/_npx/1f276a68aabfc75c/node_modules/@earendil-works/pi-coding-agent" bash tests/fm-pi-branch-live-e2e.test.sh
```

```text
ok - a settled branch turn without a durable outcome falls back and releases its grant for main replay
ok - post-construction provider errors fall back immediately and repeated failures defer later wakes directly to main
ok - tracked Pi extensions pass strict no-emit typecheck against Pi 0.84.4
ok - real Pi SDK 0.84.4 returns a post-construction 429 wake to main without losing its durable row
```

The current portable regression proves that only consecutive provider errors count toward the two-error broken-branch latch: a durable report between errors resets the streak, the error that reaches the threshold rejects to watcher-owned fallback, and the next wake remains on main without another branch prompt.
`tests/fm-pi-watch-extension.test.sh` owns the provider-free integration evidence that watcher fallback remains pending until Pi accepts the main follow-up or the branch settles successfully, and that a follow-up accepted while main is streaming neither stalls the successor chain nor escapes replacement replay until Pi consumes it.
[`pi-supervision-branch.md`](../pi-supervision-branch.md) owns the current cooldown, recovery, and re-latch contract and points to the regression that now covers it.

Scope of the earlier evidence: the installed signed `pi` CLI (0.82.0 at verification time) is a compiled binary whose bundled SDK is not importable from Node, so the importable npm package is the only surface the guard and the typecheck can pin.
The extension executes inside the signed CLI's own runtime, so a CLI upgrade can drift ahead of the npm surface; refresh the SDK construction, picker, and renderer evidence after every Pi upgrade by rerunning the applicable live guard probes and picker regression with `FM_PI_PACKAGE_DIR` pointing at a matching npm install when one exists.
The [strict production-consumer typecheck](../../tests/fm-pi-primary-types.test.sh) owns its dependency contract; historical typecheck commands and outputs here do not describe its current SDK selection.
The [live-guard contract](../pi-supervision-branch.md#live-guards) owns the current fallback observations and fixture limits; rerun it against the matching importable Pi package to refresh SDK fallback evidence.

### 2026-09-02 streaming-time watcher delivery

The focused watcher suite, strict typecheck, and credential-free live guard were run against the npm `@earendil-works/pi-coding-agent` 0.84.4 package selected with `FM_PI_PACKAGE_DIR`, on macOS 26.6.2 arm64, Node v24.14.1, after the watcher extension stopped waiting for `before_agent_start` before settling a main delivery.
No credential was read, no request left the machine, and the active Pi session was not changed.

```sh
bin/fm-test-run.sh tests/fm-pi-watch-extension.test.sh
FM_PI_PACKAGE_DIR=<pi-0.84.4 package> npm exec --yes --package=typescript@5.9.3 -- bash tests/fm-pi-primary-types.test.sh
FM_PI_BRANCH_LIVE_E2E=1 FM_PI_PACKAGE_DIR=<pi-0.84.4 package> bin/fm-test-run.sh tests/fm-pi-branch-live-e2e.test.sh
```

```text
ok - Pi hung successor falls back to one typed actionable wake
ok - Pi streaming-time wake delivery keeps the successor chain and replays only unconsumed wakes
ok - Pi retries a verified successor that failed during wake delivery once that delivery settles
ok - tracked Pi extensions pass strict no-emit typecheck against Pi 0.84.4
ok - real Pi SDK 0.84.4 queues a streaming-time watcher wake without before_agent_start, keeps the successor chain, and surfaces consumption of both follow-ups
```

The live probe loads the tracked watcher extension through Pi's real resource loader into a real AgentSession whose only provider is a local fake with its fetch intercepted in-process and held open mid-stream.
It proved that a follow-up the extension sends while main is streaming raises no `before_agent_start` at queue time or when the run reaches it, joins the run as a user `message_start` carrying the exact wake text in its own model turn, and is followed by a verified successor and delivery of the next close; a follow-up sent to the idle main raises `before_agent_start` with the exact text before its user `message_start`.
The portable regression drives the same shape with a fake main that never raises `before_agent_start` while streaming, then proves a replacement replays only the follow-up Pi had not consumed and that an exhausted restoration delivers its typed failure without launching a further arm.
A second regression holds a branch settlement open while the verified successor exits with a failure, and proves that failure takes the ordinary bounded retry once the delivery settles rather than leaving the generation with no watcher and no retry.

### 2026-09-04 off-thread supervision outcome delivery

The real-TUI responsiveness guard, focused extension suite, store suite, and strict typecheck were run on macOS 26.5.0 arm64, Node v24.13.1, tmux 3.6a, against the signed Pi launcher 0.82.0 for the TUI arms and the npm `@earendil-works/pi-coding-agent` 0.81.1 package for the typecheck.
The lab used a scratch `FM_HOME`, a scratch project holding a copy of the tracked extension, a private tmux socket, a scratch session directory, and `--offline`; only `/new` was ever sent, so no model turn ran and no request left the machine, and the captain's own Pi session was not touched.

```sh
FM_PI_BRANCH_RESPONSIVENESS_E2E=1 bash tests/fm-pi-branch-responsiveness-live-e2e.test.sh
bin/fm-test-run.sh tests/fm-pi-branch-extension.test.sh
bin/fm-test-run.sh tests/fm-branch-supervision.test.sh
npm exec --yes --package=typescript@5.9.3 -- bash tests/fm-pi-primary-types.test.sh
```

```text
pi 0.82.0 keystroke echo, worst observed: floor 22.6 ms, extension idle 35.6 ms, extension delivering 36.8 ms
ok - supervision outcome delivery keeps the real Pi 0.82.0 TUI echoing keystrokes at its unloaded floor
ok - outcome delivery keeps the event loop running and interleaved reports stay ordered and exactly once
ok - a session replaced mid-delivery cancels cleanly and the stored outcome still arrives exactly once
ok - a failing store script surfaces to the branch and its outcome is neither lost nor delivered twice
ok - a failed cursor write re-delivers a routine note exactly once more while a captain outcome stays deduplicated
skip: installed Pi 0.81.1 predates the stock renderer contract 0.84.4 this case compares against
ok - tracked Pi extensions pass strict no-emit typecheck against Pi 0.81.1
```

That skip is the renderer case declining to render a verdict on a Pi older than the contract it compares against: since 0.84.4 the stock renderer no longer supplies an implicit reset at multiline boundaries and the extension emits that reset itself, so an older installed Pi differs legitimately.
It names the installed version and the floor rather than degrading quietly, and a package whose version cannot be read at all is still a failure.

The same guard against the pre-change extension in the same lab measured a 676.9 ms worst keystroke echo while delivering two outcomes and a 295.3 ms worst echo with nothing to deliver, against a 49.2 ms extension-free floor, and failed as designed.
Measured through the same real `fm_branch_report` tool and real `bin/` scripts with a 1 ms interval timer, the largest single block of the JavaScript thread fell from 273 ms to 2.0 ms for a routine outcome, from 286 ms to 2.0 ms for a captain outcome, and from 134 ms to 1.9 ms for main's acknowledgement, against a 1.3-2.2 ms idle-loop floor.
Those absolute figures are specific to this host and Pi version; the guards assert the relationship (delivery must stay in the class of the same machine's own floor) rather than a remembered millisecond number.

## Pi worker model-stream observation

Verified on 2026-10-13 with the installed Pi 1.2.0 SDK and Node v24.13.0.
On an unverified Pi version, the guard exercises the spawn-time inert path with its exact warning, no stream handlers, and ordinary busy/idle classification; stream observation stays off until the version is verified.
Refresh this token-free guard after a Pi upgrade:

```sh
bash bin/fm-test-run.sh tests/fm-pi-worker-stream-live-e2e.test.sh
```

Observed output:

```text
ok - real Pi 1.2.0 stream, tool, completion, and background request phases
ok - real Pi 1.2.0 default-off worker
Firstmate model-stream observation write failed; inspect worker instrumentation.
ok - real Pi 1.2.0 instrumentation deadline terminated writer and output-holding descendant
ok - real Pi 1.2.0 stream, tool, completion, and background request phases
# pi-signed unavailable: signed executable not exercised
ok - real Pi 1.2.0 worker stream lifecycle, background exclusion, and default-off behavior
```

The guard runs the generated worker extension through Pi's real resource loader, model runtime, agent loop, and custom tool execution in isolated directories.
Synthetic transport holds an accepted response, supplies substantive and empty events, enters a tool phase, and completes a subsequent request.
The real provider callback is also exercised outside the foreground agent loop to disconfirm background-request tracking.
An isolated copy of the toolkit injects one stalled writer command and a descendant that retains output, proving the real extension's deadline ends both processes and Pi continues through its remaining phases.
No external provider, credentials, primary extension, or live fleet is used.
The signed executable was absent and is not credited as live-verified on this version.
The portable busy-state, adapter-wiring, and watcher-triage suites own generation/request rejection and inspection notification behavior.

The unverified-version fallback was checked on 2026-10-31 with installed Pi 1.4.0 and Node v24.22.1 using the same command above.
The guard asserted the exact spawn warning and absence of stream handlers, then exercised ordinary busy/idle behavior through the real SDK.
Observed output:

```text
ok - real Pi 1.4.0 default-off worker
# pi-signed unavailable: signed executable not exercised
ok - real Pi 1.4.0 unverified-version warning, inert stream observation, and existing busy/idle behavior
```

## Native Codex through Pi

Verified on 2026-09-08 with Pi 0.85.1 and the installed `pi-codex-native` 0.2.1 adapter.
Run this token-free guard after updating Pi, Codex, or the adapter:

```sh
FM_PI_CODEX_NATIVE_LIVE=1 bash tests/fm-pi-codex-native.test.sh
```

Observed result: `"result": "PASS"`.
The guard runs the real Pi runtime, native adapter, three FirstMate primary extensions, native MCP transport, and FirstMate's durable outcome scripts in an isolated home.
It verifies native `ultra` on initial and operational turns and after restart, startup operational input, watcher arming, a notification while main is idle, outcome read and one acknowledgement, refusal of a duplicate acknowledgement, and no reprocessing after restart.
Its native App Server peer and watcher-close process are deterministic fixtures; it does not claim a real backend or a live model was tested by that command.
`tests/fm-busy-state.test.sh`, `tests/fm-busy-adapter-wiring.test.sh`, and `tests/fm-watch-triage.test.sh` cover separate progress notification, unchanged semantic busy state, rejection of a superseded worker's events, and progress refreshing the busy-age bound without fabricating a completed turn.

## Busy inbox escalation

Verified at `2026-10-03T19:20:07Z` on commit `23b0232908a5adc7fbf7339ef48c34a091a7a799` with Claude Code `2.1.288 (Claude Code)` on Herdr `0.9.1`, protocol `22`, in a named isolated lab session through `bin/fm-herdr-lab.sh`.
`bin/fm-task-inbox-lib.sh` owns the durable busy-deferral budget.

A real Claude worker opened an `AskUserQuestion` panel, and Firstmate's `UserPromptSubmit` hook reported busy.
Four due inbox checks using the original `origin/main` watcher at `1f3e769616fdf9f31f85f4c3e6a9f71606634238` against that live pane each read `busy=yes` and added zero wakes.
With `FM_TASK_INBOX_GRACE_SECS=0 FM_TASK_INBOX_BUSY_MAX=2`, two distinct processes sourcing the fixed watcher and calling `inbox_steer_check` against the same pane produced one wake containing `stuck-busy after 2 consecutive busy-deferred due doorbells`.
A third check left exactly one wake total; the question panel remained open and the instruction remained unhandled.
Lab teardown completed with exit `0`, including the default-session tripwire.
The zero grace accelerates only the experiment; the normal grace remains unchanged.
Without Firstmate's hooks, Herdr reported the question panel as `blocked`, which did not classify as busy; that is a different path and does not establish this regression.

This live proof covers the watcher and queue boundary.
Repeat the hooked-worker check above before publication if watcher or task-inbox busy code changes; `bin/fm-test-run.sh tests/fm-task-inbox.test.sh` refreshes the portable ladder regressions.

## Pi repeated-read containment

Verified on 2026-11-08 UTC on Linux x86_64 with Node 24.22.1 and npm 11.19.1.
The operator contract, opt-in default and migration procedure are owned by [configuration](../configuration.md#pi-repeated-read-containment).
The supported SDK matrix is Pi 1.1.0, 1.2.0 and 1.5.0, with each release's sibling packages pinned to the same version rather than resolving newer 1.x packages through public dependency ranges.
TypeScript 5.9.3 checked all tracked Pi consumers with strict no-emit settings for every version.
The real SDK fixture uses synthetic provider responses, intercepted fetches and fake Bash operations; it never sends a request to an inference endpoint.

```sh
bash tests/fm-pi-primary-types.test.sh
ok - tracked Pi extensions pass strict no-emit typecheck against Pi 1.1.0
ok - read guard real SDK events/abort against Pi 1.1.0
ok - tracked Pi extensions pass strict no-emit typecheck against Pi 1.2.0
ok - read guard real SDK events/abort against Pi 1.2.0
ok - tracked Pi extensions pass strict no-emit typecheck against Pi 1.5.0
ok - read guard real SDK events/abort against Pi 1.5.0
```

Each SDK passed alternating synthetic 85/65-pair histories, SSH-shaped reads, `cut`, outer groups, multiline `nl`/`wc`/`head`/`tail`/`od` pipelines, escaped-newline continuations, duplicate batches and truncated results with compaction.
Changing output, failed results, foreign ownership, absent opt-in, unknown grouped stages and grouped mutators remained allowed; unrecognized commands are outside the detector rather than denied execution.
The resumed SDK session retained the stop across marked operational input, extension input and a journal reopen, then accepted deliberate RPC user input.
No provider fetch occurred after a stop notice, including the small-context compaction case.

Installed Pi 1.4.0 separately passed the token-free RPC guard below, using a synthetic in-process provider, a fake Bash tool and private home/session directories.
It executed the known multiline grouped read three times, aborted before a fourth execution, refused an operational reset, accepted a fresh RPC user reset and persisted one stop notice plus a proven-owner activation receipt.
The guard verifies that its Pi process group exits during cleanup.

```sh
bash bin/fm-test-run.sh tests/fm-read-repetition-live.test.sh
ok - Pi 1.4.0 installed RPC read guard: veto, abort, durable latch, operational denial and user reset
```

`tests/fm-read-repetition.test.sh` independently exercises ownership denials and regain, configuration bounds, default-off registration, reset provenance, bounded history, group-recognition controls and preservation of the ignored legacy guard/helper/configuration through a real pre-feature Git fast-forward.
No macOS or Windows ancestry, native-adapter interception, separate native-tool execution, terminal screenshot/display, worker or fleet-wide protection is claimed.
The runtime fixture does not reproduce spontaneous model-loop onset or establish a model/serving root cause.

## Pi tool-time cap

Verified on 2026-11-24 UTC on Linux x86_64 with installed Pi 1.6.0 and Node 24.22.1.
The operator contract is owned by [configuration](../configuration.md#pi-tool-time-cap).
Each run was a real `pi --print` session with a live model, started in the code root with no worker variables, loading only this extension and, for the codemode run, the built-in codemode extension.
The prompts asked for the exact call shown, and each run's wall time includes the model turns around the call.

```sh
pi --print -ne -e .pi/extensions/fm-primary-tool-time-cap.ts --tools bash --no-mcp --no-skills -nc "<call bash: sleep 200; echo finished, no timeout>"
Command timed out after 90 seconds
[Pi tool-time cap: this bash call asked for no time limit and was limited to 90 s. Do not wait inside a tool call; end the turn and let the next wake resume the work.]
exit=0 wall=97s

pi --print -ne -e .pi/extensions/fm-primary-tool-time-cap.ts --tools bash --no-mcp --no-skills -nc "<call bash: sleep 200; echo finished, timeout 300>"
Command timed out after 90 seconds
[Pi tool-time cap: this bash call asked for 300 s and was limited to 90 s. Do not wait inside a tool call; end the turn and let the next wake resume the work.]
exit=0 wall=96s

pi --print -ne -e builtin:codemode -e .pi/extensions/fm-primary-tool-time-cap.ts --tools +codemode --no-mcp --no-skills -nc "<call codemode, no options line: await tools.bash({command: 'sleep 200; echo finished'})>"
Script failed
Wall time 90.1 seconds
Script error:
Script timed out: Execution timed out after 90000 ms
Tool calls made before the failure (they are not undone): bash (cancelled)
[Pi tool-time cap: this codemode call asked for no time limit and was limited to 90 s. Do not wait inside a tool call; end the turn and let the next wake resume the work.]
[Pi tool-time cap: a nested bash call asked for no time limit and was limited to 90 s. Do not wait inside a tool call; end the turn and let the next wake resume the work.]
exit=0 wall=101s

FM_CONFIG_OVERRIDE=<dir holding tool-time-cap = 5> pi --print ... "<call bash: sleep 30; echo finished, no timeout>"
Command timed out after 5 seconds
exit=0 wall=13s

FM_TASK_ID=proof-worker pi --print ... "<call bash: sleep 100; echo finished, no timeout>"
finished
exit=0 wall=107s
```

No `sleep 200` process remained after the capped runs.
`tests/fm-tool-time-cap.test.sh` pins the clamp, config and note rules without a model, and `tests/fm-pi-primary-types.test.sh` typechecks the extension against the SDK matrix.
