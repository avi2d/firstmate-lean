# Calm mode

Calm is Firstmate's conversation-only transcript presentation toggle.
This page is for operators who turn Calm on and need to know what it hides and keeps visible on Pi and on Claude Code, and which file owns each part of that behavior.

## Harness support and default

Calm is off by default.
The last `/calm` choice persists for the effective Firstmate home across session starts and resumes in Pi.
The choice is stored in the preference file that [`configuration.md`](configuration.md#calm-preference-configcalm) owns.

## Shared preservation rule for assistant text

Calm evaluates each settled assistant text block from a model step that stopped to call tools, or that exhausted its token limit while carrying tool calls.
Calm hides such a block only in the first case below:

| Settled block | Result |
| --- | --- |
| Raw text contains no newline, and trimmed length is below `CALM_PRESERVE_MIN_CHARS` (240) | Hidden. |
| Raw text contains a newline, or trimmed length is at least 240 | Preserved as substantive captain-facing content. |

Streaming text and the genuine reply that ends a response remain visible.

## Pi

### Collapsed Firstmate rows

Firstmate's own input rows render as one line each in every Pi primary, secondmate, and worker session, whether Calm is on or off.
The line names the row's kind and a short identity, such as `[firstmate] watcher wake · FIRSTMATE WATCHER WAKE: signal: ...` or `[firstmate] launch brief · <task>`.
The tools-expand key (`Ctrl+O` by default) expands every such row to its complete stock text, and a click on one row in fullscreen mode toggles that row alone.

A row collapses only when it is a text-only user message that `bin/fm-operational-input.sh` classifies as current operational input, the bare-marker legacy away escalation, or exactly this session's own steering doorbell line from `bin/fm-task-inbox-lib.sh`.
Anything else a person types, including text that quotes or resembles those forms, renders as an ordinary row.
Tool calls and their failures, pending actions, assistant prose, and working, retry, and compaction state are never collapsed.

The collapse changes presentation only.
The message, model context, saved session, and exports keep the full text.
Workers get the same rows from the per-task extension `bin/fm-spawn.sh` writes for every Pi worker.
A secondmate gets them from its home's own Calm extension, which Pi loads with that home's other project extensions.

### Working boat

While Calm is active and an agent run is under way, Calm hides Pi's built-in `Working...` row and shows a small two-row animated boat in its place.
No separate Calm status row is added.
The boat claims the same Pi working-row widget slot as the standalone Pi Calm extension, so a session that loads both Calms shows one boat rather than two, and turning Firstmate Calm off does not clear the standalone boat.
While Calm is off, Pi's stock working row is left exactly as Pi renders it.

The boat looks like this:

- The water fills the usable width with low one-cell Unicode bars, all in standard ANSI blue, so the swell shows through bar height alone.
- The asymmetric three-cell `◿│◣` sail is centered over the five-cell `╲▁▁▁╱` hull.
- The whole boat is one standard ANSI yellow, including both sail halves, the mast, and the hull.
- The hull's zero-height interior keeps the swell continuous beneath the boat.
- Very narrow terminals fall back to a smaller deterministic sprite.

### Boat motion

The boat is deliberately calm.
It moves one column every 880ms.
The long smooth wave advances one quarter-cell every 220ms, so the surface stays alive between boat steps.
Deterministically varied half-waves stay between nine and thirteen cells.
The boat remains phase-locked inside a broad zero-height trough through movement and edge reversals.
Every resize reflows the sprite without wrapping.
The boat disappears when the run settles, aborts, or fails.

### Boat position between working periods

Within one Pi session and Calm extension lifetime, the next working period resumes the boat from its last rendered column and travel direction rather than restarting at the left edge.
Hidden elapsed time does not advance the animation.
A resize while hidden clamps the frozen boat to the new width without changing its valid travel direction.
A fresh Pi session or new Calm extension lifetime starts at the normal initial position.

### What Calm hides on Pi

Calm hides these rows:

- Collapsed thinking labels.
- The mid-turn assistant working-note blocks governed by the [shared preservation rule](#shared-preservation-rule-for-assistant-text) above.
- The shells for the Pi built-in tool names Calm owns.
- Firstmate-owned tool shells listed in the [Pi tool audit](calm-mode-feasibility.md#firstmate-pi-tool-audit).
- Canonically classified Firstmate operational user rows.

Pi applies the preservation rule independently to each text block.
A short working note can therefore hide beside preserved substantive content in the same message.
A working note is briefly visible while it streams, before its settled row collapses.

The narration is hidden only from the live transcript presentation.
It remains in the message, model context, session storage, and `/export` artifacts.

The operational inputs Calm classifies remain ordinary user-role messages.
Pi's transcript layout renders their complete rows at zero height.
The steering doorbell is plain text a person could also type, so Calm leaves it at its [collapsed](#collapsed-firstmate-rows) line rather than hiding it.
The session-start nudge remains on its existing non-displayed custom-message path.

### Queued Firstmate inputs on Pi

While a turn runs, Calm also keeps those Firstmate inputs out of Pi's queued-message listing.
The captain's own queued messages stay listed.
Escape and the dequeue key return only the captain's queued messages to the editor.
Hidden Firstmate inputs stay queued in their original order and are never shown as raw text or dropped.
When Escape, or navigating the session tree, stops a run with Firstmate inputs still queued, Pi either drains them itself or Calm starts one new turn to deliver them.
When Calm starts that turn, it shows the one-line notice `Firstmate supervision continues in a new turn.`
Inputs held behind a running compaction stay there until Pi sends them after compaction, so they start and announce no turn of their own.

### What stays unchanged on Pi

Outside Pi's same-name built-in override collision described in [Pi compatibility](#pi-compatibility) below, Calm changes presentation only.
Calm's built-in wrappers preserve Pi's execution behavior.
Input delivery, ordering, model context, session storage, diagnostics, and `/export` and `/share` operation remain unchanged.
Every hidden Firstmate input remains available to the model and in serialized session data and exported artifacts.
Legacy operational custom messages remain in session data and Pi's sidebar tree; depending on the Pi version, the main HTML transcript either omits them or includes them as rows hidden by default.
Toggling Calm off restores ordinary rendering with Firstmate's own rows [collapsed](#collapsed-firstmate-rows), and `Ctrl+O` expansion state is preserved.

### What stays visible on Pi

Pi's supported presentation API does not expose a global transcript filter.
These rows remain visible:

- Expanded reasoning and its reserved spacing.
- Built-in tool images.
- User-bash rows.
- Skill and summary rows.
- Generic status notices.
- Other arbitrary custom-tool or extension rows.

These are supported-API boundaries rather than hidden-content failures.

## Pi compatibility

### Pi versions and missing API seams

Calm has no numeric Pi version minimum or maximum.
It never refuses Pi solely because its version is newer than a previously verified version.

When Calm loads, the collapsed-thinking, operational-user-row, and queued-operational-row presentation adapters probe the exact Pi API seam they patch.
If Pi removes one of those seams, Calm logs a diagnostic naming the unavailable adapter and skips only that adapter.
`/calm`, the other adapters, and unrelated Pi extensions remain available.

### Session check for queued inputs

Keeping hidden queued inputs across Escape also needs members of Pi's live session, which exist only once a session runs.
Calm checks them for each session on its first queued-listing draw, before hiding anything.
A session missing any of them keeps its queued rows and Escape exactly as stock, and shows one warning.
In that case `tests/fm-calm-pi-queue-retention-live-e2e.test.sh` fails naming the installed Pi version.

### Built-in tool override collisions

Calm's built-in tool presentation (`bash`, `read`, `edit`, `write`, `grep`, `find`, `ls`) shares Pi's single, unmerged override slot per name with any other extension that overrides the same tool.
How Calm handles that shared slot depends on whether Calm was already on when the session started or reloaded.

**Session started with Calm off**

- While the persisted Calm preference is off, Calm registers none of those overrides and therefore contests no built-in tool name.
- The first time Calm turns on in a session that started off, it claims every built-in name no other extension already owns.
- It leaves every contested tool intact and callable, and displays a prominent warning naming the tools it skipped.
- Tool-call rows already on screen before that first toggle do not retroactively collapse.
- Later rows for the names Calm claimed use Calm presentation.

**Session started or reloaded with Calm already on**

- Calm must instead register all seven overrides synchronously so Pi can render restored rows with them.
- Pi provides no ownership check early enough for that load-time path, and the first registrant wins the complete tool definition.
- If the other extension wins, a session-start console diagnostic names the tool and winning extension.
- If Calm wins, Pi does not expose the losing registration, so the other extension's override is unavailable and cannot be named.

### Owning docs and files

- [`calm-mode-feasibility.md`](calm-mode-feasibility.md) owns the version-scoped renderer taxonomy, built-in override constraints, and empirical evidence.
- [`configuration.md`](configuration.md#calm-preference-configcalm) owns the persisted preference file and resolution rules.
- `.pi/extensions/lib/fm-calm-visibility.ts` owns the visibility policy.
- `.claude/mods/firstmate-calm/lib/fm-calm-preservation.ts` owns the shared substantive mid-turn text rule, which Pi imports through its tracked symlink.
- `.pi/extensions/lib/fm-calm-operational-user-layout.ts` owns the operational-user row adapter, its collapsed line, and its zero height under Calm.
- `.pi/extensions/lib/fm-calm-pending-operational-layout.ts` owns the queued-row adapter and its session capability check.
- `.pi/extensions/lib/fm-calm-working-ship.ts` owns Pi's animated working presentation over the sprite geometry both harnesses share in `.claude/mods/firstmate-calm/lib/fm-calm-working-ship-sprite.ts`.

### Pi regression entry points

```sh
tests/fm-calm-pi-extension.test.sh
tests/fm-pi-operational-row-collapse.test.sh
tests/fm-pi-branch-extension.test.sh
tests/fm-pi-primary-types.test.sh
tests/fm-calm-pi-queue-retention-live-e2e.test.sh
FM_PI_LIVE_E2E=1 tests/fm-pi-primary-live-e2e.test.sh
```
