---
name: projectstatus
description: Report project work in the captain's priority order, including the orc backlog. Use when the captain invokes /projectstatus or asks for project work status in priority order.
user-invocable: true
metadata:
  internal: true
---

# Project status

Report the current work without changing task, worker, or project state.
Use the active Firstmate home and its installed code, not the skill's installation directory.
Honor its home and directory overrides as described in the Firstmate configuration.

1. Read the active home's `data/captain.md` for the captain's project priority order.
   Use the order recorded there, not backlog priority, registry order, or a remembered order.
   If the file or order is missing or ambiguous, say so and ask the captain to supply it.
   Do not guess a ranking.
2. Read the project registry and the home backlog.
   Use `bin/fm-tasks-axi.sh list` with the fields needed for project, state, dependencies, hold reasons and links, and `bin/fm-tasks-axi.sh ready` for dispatchable work.
   Consult each command's help for supported fields and flags.
   For each in-flight task, use `bin/fm-crew-state.sh <task-id>` to reconcile its current state with the backlog.
   Read the task's existing status and decision records when needed to identify what is waiting and the full PR URL.
   A status log entry alone is not current-state proof.
   Use only read operations.
   If the configured backlog backend would acquire or create a lock for these commands, do not run them; report that the backlog could not be read without a state change.
3. Locate the orc clone through the active home's project registry and project directory, including configured overrides.
   From that clone, run `orc backlog --json` without a subcommand.
   Treat this as a separate backlog, not as the Firstmate backlog.
   Group its tasks by their actual status and include any review questions waiting for the captain.
   If the clone, command, or backlog is unavailable, report the missing source and do not call it empty.
4. Present one section per project in the captain's order.
   For each, show work in flight, work waiting on the captain, ready-to-start work, and blocked work.
   Name the decision or review needed and include the full HTTPS PR URL when one exists.
   Include the orc backlog in the orc section, separately from its Firstmate tasks.
   If orc is absent from the recorded order, add its section after the ordered projects and say its priority is not recorded.
   Mention any other work whose project is not in the recorded order separately, without assigning it a priority.
   Distinguish an empty category from an unavailable or uncertain source.
   Use plain words and omit internal task identifiers and pipeline details.

Do not dispatch, acknowledge, update, merge, or otherwise change anything while producing this report.
