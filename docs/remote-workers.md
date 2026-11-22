# Remote workers

A remote worker is an individual ship or scout worker that runs on another host while this home keeps supervising it.
Operators who place projects on an execution home use this reference, and so does anyone checking the remote worker lifecycle.

An execution home is an agentless Firstmate home on an SSH-reachable host.
It holds project clones, worker worktrees, and the Herdr panes the workers run in.
This home keeps the backlog, the task records, the status stream, and every decision for the user.

## Set up an execution home

1. Configure an SSH alias with public-key authentication and strict host-key verification.
   Do not enable agent forwarding.
2. Clone Firstmate on the execution host.
   Use the clone's canonical absolute path as the route's code root.
   `fm-on.sh` invokes `bin/fm-remote-entrypoint.sh` in that clone without relying on the account's SSH `PATH`.
   The entrypoint accepts encoded arguments for tracked Firstmate commands, not shell command strings.
   The host needs Herdr, the selected worker tool, and access to the project origins.
3. Seed the route with `bin/fm-remote-home-seed.sh --exec`.
   [Execution home routes](configuration.md#execution-home-routes) describes the record and its markers.
4. Annotate each placed project with `host=<route>` in `data/projects.md`.
   `fm-project-mode.sh --placement <project>` reads that annotation.

## Share an execution account

Each code root has its own remote job queue, worker lock, and log.
Linux runs a detached supervisor per root, and macOS loads a separate Aqua LaunchAgent per root.
A different route that uses the same code root uses the same runner.

Run `bin/fm-on.sh <route> fm-remote-doctor.sh --fix` to check the runner and install the root's `~/.local/bin/fm-remote-entrypoint-<key>.sh` link.
The key is the SHA-256 digest of the canonical code root.
Doctor does not replace an existing entrypoint link or modify the shared `~/.local/bin/fm-remote-entrypoint.sh` link that older callers use.

If the shared runner belongs to the same root, Firstmate retires it once the new runner is ready and the shared queue is idle.
Later calls retry retirement if the queue was busy.
Firstmate leaves a shared runner owned by a different root alone.

## Lifecycle

| Step | Command | What happens on the host |
| --- | --- | --- |
| Launch | `fm-spawn.sh` for a placed project | The host admits the task, creates its worktree, and opens one pane in the execution home's Herdr session |
| Status | Automatic | One feed per execution home mirrors every task's status lines into this home's `state/<task>.status`, and copies the reports and review-question files those lines name into this home's `data/<task>/` |
| Steer | `fm-send.sh <task> ...`, with `--resolve-key` when it answers a decision | The steer lands in the task's durable inbox on the host and rings the pane. An answered key closes in the host's status stream as well as this home's |
| Lifecycle | `fm-control.sh <task> interrupt\|exit\|relaunch` | The host acts on its own pane and reports the endpoint back |
| Current state | `fm-crew-state.sh <task>` | The host classifies its own pane |
| PR ready | The worker's `done:` line | The host runs the done gate against its own worktree |
| Cleanup | `fm-teardown.sh <task>` | The host runs the landed-work test, returns the worktree slot, and closes only that pane |
| Post-merge sync | `fm-fleet-sync.sh --remote <route> <project>` | The host fast-forwards its own clone of the project |

When a remote worker pauses and names its GitHub Actions run, Firstmate checks that run against the project origin on the execution home.
For example, a worker can report `paused: CI run 123456 | owner=GitHub CI | recheck=2030-01-01`.
Firstmate puts the result in the worker's inbox when the run finishes.
If the doorbell is deferred or fails, the watcher retries it and names the task in a wake if the retries run out.
Update both homes to use this notification.

A host at capacity answers a launch with exit 75.
The item then stays queued and is dispatched again at the next queue review.

## Cleanup

`fm-teardown.sh <task>` on a remote worker first asks the execution home to clean up its side.
That host-side teardown applies the ordinary landed-work test, so unlanded work is refused there exactly as it is for a local worker.
Only after the host confirms does this home archive the status stream, clear its task records, retire the task's feed cursor, and move the backlog item to Done with its PR link or scout report.
A scout's report must already have reached this home through the status feed, and this home's waiting-on-you gate, `fm-captain-hold.sh verify`, must pass before the host is asked to do anything.
The execution home holds no backlog or decision inventory, so it skips that gate and relies on this home's verdict.

An SSH exit 255 or a budget timeout means the host's completion is unknown.
Every local record then stays as it was, and running the same teardown again reconciles it.
A host whose record is already gone answers `teardown=absent`, so the rerun finishes the local side.
A host refusal is relayed with its reason, and nothing local changes.

## Exit codes across the transport

| Exit | Meaning | What to do |
| --- | --- | --- |
| 0 | The host finished the command | Nothing |
| 75 | The host deferred the launch because it is at capacity, and nothing was published on either side | Leave the item queued |
| 124 | The local budget expired, so the host's completion is unknown | Rerun the same command to reconcile |
| 255 | The transport was unavailable, so the host's completion is unknown | Rerun the same command to reconcile, never a different one |

## Verification

The local-transport end-to-end test drives the whole lifecycle through the real entrypoint without a second host:

```sh
bin/fm-test-run.sh tests/fm-remote-worker-local-e2e.test.sh
```

Cleanup and post-merge sync have their own test:

```sh
bin/fm-test-run.sh tests/fm-remote-worker-teardown.test.sh
```

A real-host proof runs its panes in a named `fm-lab-` Herdr session that only the host's own `bin/fm-herdr-lab.sh` creates and removes, so the execution home's fleet session is never touched.
