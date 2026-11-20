# Dispatch and start

Load this with the selected tool reference for dispatch, start, or adapter verification; add `references/common/model-and-effort.md` for either profile axis.

## Resolution

Use the router to identify the worker tool.
`config/crew-dispatch.json` can select a Pi variant, model, and effort for each task.
If a rule offers several profiles, load `quota-array-dispatch`.
When enabled, `../../../bin/fm-dispatch-resolve.sh` records the concrete profile.
See `../../../docs/configuration.md` under "Typed dispatch resolution".

## Owners

`../../../bin/fm-spawn.sh` owns launch, autonomy, concrete flags, task-kind compatibility, and worker turn-end wiring.
Natural-language rules stay with firstmate, while scripts receive concrete axes.

`../../../bin/fm-busy-lib.sh` owns semantic busy trust.
Composer shapes, glyphs, placeholders, popups, rendered delivery signals, and the `empty` / `pending` / `pending-unproven` / `unknown` decision belong only to `../../../bin/fm-composer-lib.sh`.
Tool references record empirical knowledge for those executable owners.

## Adapter verification

Verify detection in `../../../bin/fm-harness.sh`, launch in `../../../bin/fm-spawn.sh`, and lifecycle in `../../../bin/fm-control-lib.sh`.
`../firstmate-coding-guidelines/SKILL.md` owns checks that depend on Pi or Herdr.
