---
name: harness-adapters
description: >-
  Load before spawning or recovering a worker, handling a trust dialog, sending a harness-specific skill invocation, interrupting or exiting an agent, resuming an exited agent.
user-invocable: false
metadata:
  internal: true
---

# harness-adapters

This is the one skill, trigger, and routing owner for harness-specific Firstmate operations.
Load this router first, then exactly the common reference and one harness reference selected below.
When an action spans rows, load the union once rather than every reference.
Files under `references/` are resources of this skill, not additional catalogued skills.

## Path contract

The skill directory is the directory containing this `SKILL.md`.
Resolve on-demand reference links and relative links to their executable, documentation, or sibling-skill owners against the skill directory, including links named by a nested reference.
Operational paths keep the context named by their owner: `config/` and active-home settings belong to the active Firstmate home, `state/` belongs to that home, and project settings belong to the target project.

## Non-negotiable safety

Dispatch only Pi or Pi-signed.
If the selected tool is unavailable or unverified, report the blocker to the user instead of switching tools.
For recovery and control, use the exact `harness=` in `state/<id>.meta`; never infer it from a model or provider.

Deliver lifecycle actions only through `../../../bin/fm-control.sh <task-id> interrupt|exit|relaunch`.
Never type an interrupt key or exit command through `fm-send`, where routing-marked lifecycle text becomes chat.
Trust handling is complete only when inspection proves the target started processing its instructions; delivery success alone is not proof.
For a remote worker, inspect its pane with `bin/fm-on.sh <route> fm-remote-worker-control.sh capture <task-id>`.

## Detection

`../../../bin/fm-harness.sh` owns detection and prints `pi`, `pi-signed`, or `unknown`.
Pi-signed requires the explicit launch marker.
`../../../bin/fm-harness.sh crew` reads `config/crew-harness`; an absent file or `default` means use the supervisor's tool.
An explicit per-launch argument wins for that dispatch.

## Operation-to-reference matrix

Every emitted plan appends the selected or recorded harness reference after the named common references.
The `harness-adapter-routing-v1` object is the machine-readable and human-visible selection contract: choose the operation, choose the scenario within it, then append the selected harness reference.
`default` is the normal scenario when no narrower scenario applies.
```json harness-adapter-routing-v1
{
  "operations": {
    "start": {
      "default": [
        "references/common/dispatch.md",
        "references/common/model-and-effort.md"
      ],
      "trust-dialog": [
        "references/common/control-and-recovery.md"
      ]
    },
    "trust": {
      "default": [
        "references/common/control-and-recovery.md"
      ]
    },
    "skill": {
      "default": [
        "references/common/control-and-recovery.md"
      ]
    },
    "interrupt": {
      "default": [
        "references/common/control-and-recovery.md"
      ]
    },
    "exit": {
      "default": [
        "references/common/control-and-recovery.md"
      ]
    },
    "resume": {
      "default": [
        "references/common/control-and-recovery.md"
      ]
    },
    "recovery": {
      "default": [
        "references/common/control-and-recovery.md"
      ],
      "replacement-profile": [
        "references/common/control-and-recovery.md",
        "references/common/dispatch.md",
        "references/common/model-and-effort.md"
      ]
    },
    "primary": {
      "default": [
        "references/common/primary-hooks.md"
      ]
    },
    "model-effort": {
      "default": [
        "references/common/model-and-effort.md"
      ],
      "configured-profile": [
        "references/common/model-and-effort.md",
        "references/common/dispatch.md"
      ]
    },
    "verify": {
      "default": [
        "references/common/dispatch.md",
        "references/common/control-and-recovery.md",
        "references/common/primary-hooks.md",
        "references/common/model-and-effort.md"
      ]
    }
  },
  "harnesses": {
    "pi": "references/harness/pi.md",
    "pi-signed": "references/harness/pi.md"
  }
}
```
