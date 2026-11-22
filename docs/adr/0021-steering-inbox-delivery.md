# 0021: Steering inbox delivery

Date: 2026-11-22.
Status: accepted.

## Context

A worker waits without polling its inbox.
Terminal input can fail or lose Enter, and a lost SSH response does not prove the remote command failed.
Directly sending the instruction again could duplicate work or overwrite an unrelated draft.

## Decision

Write the whole instruction to a durable task inbox and type only a constant doorbell.
A worker acknowledges an instruction by moving its record to `handled/`.
The doorbell names the worker's own `FM_TASK_INBOX` and its short inbox name, so it stays the same size regardless of the path.
It starts with the shell no-op `: ` to protect a bare shell against a complete line.
Reject a doorbell name with bytes outside printable ASCII rather than passing those bytes to the terminal.
Skip proven pending text because Enter would submit someone else's draft.
An exact copy of the doorbell is the exception: submit it on a worker not known to be busy, so a lost Enter does not block every future attempt.
Retry Enter once if the composer still holds the doorbell.
An unproven composer state alone does not stop the ring, because some harnesses offer no positive proof of an empty composer.

Allocate each record's sequence number under `.seq.lock`.
Include both pending and handled records when assigning numbers, so moving an instruction never makes its number available again.
An idempotent enqueue matches both the exact body and the delivery mode in both places.
That lets a lost remote response be retried without creating another instruction.
The record may mark a synthetic final newline, so the reader can reproduce the original message exactly.

Keep attempt count, busy deferrals, and escalation in the inbox for the local ladder.
Allow one attempt per grace period, including attempts deferred to protect another draft.
A separate consecutive-busy count bounds deferrals without typing.
An unavailable agent or endpoint goes directly to recovery.
Surface bookkeeping failures if the record still exists.
Queue an escalation before saving its deduplication marker, so a crash can repeat a wake but cannot lose it.

Fire-and-forget records stay out of the escalation ladder.
With `config/wait-no-turns` present, the local watcher spends at most one marked retry after a failed or deferred initial ring and after any older ordinary record.
It defers that retry while the worker owes an open decision.
An acknowledged record drops its retry marker.

The parent watcher uses the existing remote worker ladder with a separate count for remote CI completions, so an unread ordinary steer cannot block them.
It checks the latest CI result first, so an older exhausted result cannot block a newer run.
An `until-rung` record remains eligible until the worker acknowledges it or the execution home records a successful doorbell.
A remote retry names the record so a stale fleet read cannot re-ring an acknowledged or already rung record.
A doorbell with confirmed pending text has not finished and remains eligible.
Keep the durable message in the inbox regardless of the doorbell result.

## Consequences

Only moving a record into `handled/` proves that the worker handled it.
A successfully rung doorbell is enough to end CI notification retries, but it does not prove the worker handled the result.
When all retries fail, the parent wakes the supervisor and names the task.
