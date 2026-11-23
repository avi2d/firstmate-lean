---
name: quota-array-dispatch
description: >-
  Load when a crew-dispatch rule or default resolves to more than one profile candidate.
user-invocable: false
metadata:
  internal: true
---

# quota-array-dispatch

This skill is the single owner of the completion-aware profile-array selection procedure.
`AGENTS.md` section 4 owns the always-loaded intake boundary, load trigger, malformed-config refusal, every-candidate accounting, and strongest-reasoning/tie safety rules.
`harness-adapters` owns harness verification, model/provider discovery, and effort fallback.
`quota-axi` remains data-only: it publishes `spendPriority` as a comparable scalar and never recommends, selects, ranks, or infers a route.
Do not add a daemon, opaque composite score, routing wrapper, hard-coded model-specific policy, or producer-side route recommendation.
The [worker helper](../../../bin/fm-quota-choose.sh) and [typed resolver](../../../docs/configuration.md#typed-dispatch-resolution-env-fm_dispatch_provider-fm_dispatch_model) own their deterministic mapping boundaries.

## Shared-quota opt-out

When the home's `config/crew-dispatch.json` declares a top-level `"shared_quota": true`, this home draws every provider's usage from one single shared budget, so per-provider quota rows do not describe what is left, and this skill's quota snapshot, the quota parts of the eligibility and runway gates, and `spendPriority` ranking are off by home declaration.
Make no quota read, apply no quota row, quota floor, runway gate, or `spendPriority` rank, and choose the matched rule's first declared profile that its authoritative catalog supports and that meets the required reasoning class; catalog eligibility and reasoning-class fit still apply.
`preferred_provider` is not a quota signal, so it still applies: `preferred_provider` still narrows the pool; declared order then picks within it.
Account for every candidate as always, stating in place of quota evidence that quota ranking is off by home declaration.
The declared value must be a boolean; anything else is an actionable configuration error.

## Worker-side quota helper

The canonical shell helper for a worker that has already performed its model-selection reasoning and now needs to pick the first viable candidate is `bin/fm-quota-choose.sh`.
Pass it the captured subquo JSON or the legacy TOON or JSON through stdin or `--snapshot`.
It never takes another quota snapshot.
With subquo JSON, pass `--provider` and make sure every candidate uses that provider.
Pass each candidate as `harness:model`, with earlier candidates preferred.
An `exhausted_now` runway vetoes the candidate.
The helper selects a candidate only when its applicable quota has a known `effectivePercentRemaining` greater than zero.
With legacy input and no explicit provider, the helper checks the harness's primary family, which can differ from the candidate's provider.
Authoritative multi-provider routing - including provider discovery from the harness catalog and quota matching by that explicit provider - stays owned by this skill's intake procedure above and AGENTS.md section 4, not by the helper.
Use it only when the brief already fixed the candidate order and the supplied or default provider matches every candidate.
It does not replace the reasoning-class, runway-feasibility, or authentication gates above.
Firstmate can optionally arm `bin/fm-procevent-quota.sh` for a recurring mid-task check that wakes when the tracked provider drops below its configured threshold or its runway becomes `exhausted_now`.
The opt-in [typed resolver](../../../docs/configuration.md#typed-dispatch-resolution-env-fm_dispatch_provider-fm_dispatch_model) has its own documented gates.
It never removes this skill's authority, and its `ambiguous`, `escalate`, and `error` outcomes return here.

## Read the quota snapshot

When the home declares the [shared-quota opt-out](#shared-quota-opt-out), skip this section's quota reading and every quota-derived check built on it (quota rows, floors, runway, and `spendPriority`); catalog eligibility and reasoning-class fit still apply.
Start with the typed resolver's evidence from this intake.
If it did not read quota, run `bin/fm-quota-read.sh` once to decode the local subquo snapshot and reuse it across candidates.
Use the [account labels and fallback rules](../../../docs/configuration.md#quota-snapshot).
When a provider needs the fallback, or a decision needs `spendPriority` or a runway projection, run `quota-axi` once without `--json` and reuse the TOON.
Use fresh subquo windows for headroom and exact resets, and state when you use legacy evidence.
Post-consolidation quota-axi (the floor owned by `bin/fm-quota-axi-lib.sh`) puts `spendPriority` in the default `quota[]` block beside `effectivePercentRemaining`, `runway`, `confidence`, `limitedBy`, and `resetsAt`.
Sparse `exhaustion[]` carries finite-runway seconds only for `projected_exhaustion` and `exhausted_now`.
Sparse `attention[]` names auth, stale, and unmeasurable facts.
`spendPriority` is THE quota-perspective ranker.
It already computes the economics that older instructions reconstructed by hand from headroom, pace, reserve, and window-id lists; do not recompute those.
Do not read `--json` on the normal path, and do not reach for `--full` to rebuild that economics.

After reading the TOON, fall back to one `quota-axi --json` call only when that TOON is genuinely ambiguous for the decision, or when the installed quota-axi is somehow below the floor so its TOON lacks `spendPriority`.
Ambiguous means a candidate's `spendPriority` is the literal `unknown` or unmeasurable, a real tie still needs extra evidence, or a candidate's eligibility is unclear from `quota[]` plus `attention[]`.
The fallback therefore has an explicit TOON-then-JSON call sequence; reuse its JSON result and do not take any further quota snapshots.
Below-floor is rare: bootstrap enforces `FM_QUOTA_AXI_MIN` and normally reports `OUTDATED` before dispatch; if an intake somehow reaches an older build whose TOON lacks `spendPriority`, use the defensive `--json` fallback rather than treating the missing scalar as healthy.
`--json` is a defensive belt, not a habit; never reach for it because it feels more complete.
Read `quota-axi auth --json` only when a candidate's credential surface is in question.

For each candidate, preserve explicit `harness`, `model`, and `provider`; `harness-adapters` owns identity, and model/provider never infer harness.

## Three gates, then provider preference and spendPriority

Apply the three cheap orthogonal gates first.
`spendPriority` ranks only among candidates that pass all three.
It cannot override a hard-gate failure, and it is never hidden inside a new composite score.
When `config/crew-dispatch.json` declares `"array_order": "preference"`, [ordered preference](#ordered-preference) replaces the ranking step for every array, and the gates stay exactly as written.

### 1. Eligibility

Outside those documented mappings, deterministic shell must not infer a provider family or credential store from a harness, model, or source name.
You establish the remaining relations yourself, in the open, from the candidate's own authoritative catalog (`harness-adapters` owns the per-harness discovery surface) plus the one intake snapshot.

Confirm the catalog lists the candidate's model and record the provider family it reports.
A model the catalog does not list is concrete contradictory evidence: block that candidate and quote the catalog result.
Apply quota at the granularity the vendor actually supplies.
A provider-level or `all_models`/`all_products` scope bounds every model you established in that family within the candidate's matched account, including one with no window of its own.
A named-model or named-product scope is an additional bound for that model alone.
A scope the vendor reports outside those names, such as an Antigravity tier, bounds a candidate only when its profile declares that exact scope as `quota_scope`; never infer the tier from the model name.
For a candidate with `claude_account`, match its exact account label in subquo.
If the reading is missing or not current, use that profile's `clauth status --json` windows, not an ambient quota-axi row.
Keep the [Claude login checks](../../../docs/configuration.md#claude-accounts-configclaude-accounts), and pass the chosen account to `fm-spawn` as `--claude-account`.
On the quota-axi fallback, match any other candidate to its `quota[]` row by that established provider, its `accountKey` when the snapshot is schema 6 (a Pi lane's auth provider id such as `openai-codex-work`, or `codex-home` for native Codex including Pi's `codex-native/` adapter, then the `default` row, else unmeasured; never a row picked by position, never rows summed across accounts), and scope; a stale, auth-required, or unmeasurable scope is named in `attention[]` instead of a fabricated number.

A candidate authenticates through its own tuple's surface; another harness's CLI can never gate it, and `harness=pi` with `model=xai/grok-*` is Pi using xAI rather than the standalone Grok CLI.
`quota-axi auth --json` lists each provider's credential sources independently, so read the one source the candidate actually uses rather than collapsing a provider to a single status.
A provider can carry a healthy source beside a missing or expired one; the unused source's state is not the candidate's state.
A Pi-hosted family may authenticate through the vendor's own store with no `pi:`-prefixed source at all, which is normal and never evidence against the candidate.

Uncertainty and ineligibility are different findings:

- No model-level window, no matching auth source, an unmeasurable or `unknown` scope, or a surface quota-axi does not model at all is disclosed uncertainty.
  Keep the candidate eligible, state the unknown, and prefer known viable evidence when otherwise comparable.
- An expired credential is a short-lived session token the owning vendor renews on next use, not a sign-out.
- Only concrete contradictory evidence blocks: an authoritative catalog proving the model unsupported, or proof that the credential the candidate actually selects is unusable.
- Reserve login wording for that proven-unusable case, and name the harness, model, surface, and evidence.

If the candidate's credential is uncertain, report the uncertainty and name the evidence needed to resolve it.
Use only the candidate's Pi provider and account evidence.
Never launch a standalone vendor CLI or read credential files for a dispatch check.
Grok prepaid `credits` are unrelated to paid-window headroom; never read them as exhaustion.

Malformed configuration is an actionable error, not a candidate to rank around.

### 2. Reasoning-class fit

Keep only candidates that meet the required reasoning class for this task (a simple bug fix versus very-difficult design).
Never use `spendPriority` or remaining quota to silently replace that class.
When every remaining candidate is tight, dispatch inside the strongest-reasoning class if one of those candidates can proceed, or stop and report that the strongest-class choice cannot proceed rather than downgrading it to spend or conserve quota.

### 3. Runway feasibility floor

Known runway that will not last until the inspectable likely-completion horizon fails this gate, even when that candidate has the highest `spendPriority`.
Read `runway` from the `quota[]` row: `through_reset` passes this generic feasibility floor because the window reaches its refill without exhausting; never compare its `resetsAt` with the completion horizon as though reset were an exhaustion deadline.
`exhausted_now` is zero, and `projected_exhaustion` uses the matching `exhaustion[]` row's `usableRunwaySeconds`.
A high `spendPriority` on a nearly empty window that will exhaust soon must not route into a mid-task stall.
Unknown or unmeasurable runway stays eligible with disclosed uncertainty and is never assumed to pass.
Do not invent a generic percentage floor, and honor an explicit user floor for a candidate when one exists.

## Rank by spendPriority

Among candidates that pass all three gates, first apply the optional top-level `preferred_provider` from `config/crew-dispatch.json`.
Its schema is owned by [Crew dispatch profiles](../../../docs/configuration.md#crew-dispatch-profiles-configcrew-dispatchjson).
Within the already matched rule or default, restrict ranking to eligible candidates of that family when any remain.
Do not introduce other profiles, change a Claude-only rule, or override an explicit user choice or approval requirement.
Only concrete evidence that every matched preferred candidate is ineligible authorizes fallback to other families.
Unknown quota, missing account evidence, and unrankable scalars do not establish ineligibility.
If preferred candidates remain eligible but none can be ranked, escalate with that uncertainty instead of switching families.
When no matched profile belongs to the preferred family, preserve the rule's candidate set.
With the field absent, keep the existing candidate set unchanged.
Print the preferred-family decision, including the reason for any fallback.

Within the resulting candidate set, pick the highest known `spendPriority`.
A higher known scalar is better: positive means paid allowance is on track to reach reset unused, `0` is exact utilization, and negative means overdrawn against the reset clock.
Rank only from comparable known scalars.
Never treat absent, `unknown`, or unmeasurable `spendPriority` as zero or as healthy; `0` means exact utilization, a different claim from unknown.
An unknown `spendPriority` keeps the candidate eligible with disclosed uncertainty.
Prefer known viable evidence when otherwise comparable.
After the permitted TOON-to-JSON fallback, escalate to Firstmate instead of routing if no candidate can be ranked or runway uncertainty prevents proving the feasibility floor for any candidate that could be selected.
Never resolve that terminal uncertainty by treating unknown as healthy or by choosing arbitrarily.
Show the scalar or the literal `unknown` in the rationale; do not hide it in a score.

Do not compare headroom against runway by hand.
Do not use pace or signed reserve as a later tie-break layer.
Do not read `aheadWindowIds`, `behindWindowIds`, `onPaceWindowIds`, `limitingWindowIds`, or other window-id lists to reconstruct what `spendPriority` already computed.

Genuine ties: stop and report every tied candidate for user choice.
Do not select by array order, harness name, or another arbitrary identity ordering.
Report duplicate concrete profiles as a configuration error.

## Ordered preference

This branch applies only when `config/crew-dispatch.json` declares `"array_order": "preference"`.
[`docs/configuration.md`](../../../docs/configuration.md#crew-dispatch-profiles-configcrew-dispatchjson) owns that field.
It covers every profile array, in rules and in `default`, and the `spendPriority` ranking above does not apply.
An optional `preferred_provider` still applies first: walk only that family's eligible candidates when any remain, under the fallback rules above.

Walk the candidates in array order through the three gates against the one intake snapshot, and choose the first that passes.
`spendPriority` is still read and shown as evidence, but it neither ranks the array nor overrides the order.
A candidate that fails a gate, such as an `exhausted_now` runway, a catalog that does not list the model, a proven-unusable credential, the wrong reasoning class, or known runway short of the completion horizon, is skipped to the next one with its reason recorded.
Unknown quota, an unknown `spendPriority`, or unmeasurable runway keeps the candidate eligible, so it is chosen with that uncertainty stated rather than skipped.
An explicit user floor that cannot be verified for the first passing candidate is the one unknown that stops the walk: report it rather than choosing that candidate or skipping past it.
Order settles every comparison, so there are no ties in this branch.
If no candidate passes, stop and report every candidate with its failing gate.
The duty to account for every candidate, including those after the chosen one, is unchanged.

Account for every candidate visibly before selecting or escalating, naming its catalog evidence, provider relation, applicable quota and authentication facts, remaining uncertainty, fit and reasoning class, `spendPriority`, and runway-versus-horizon result.
A blocked credential report must name `harness`, `model`, authentication surface, and concrete failure evidence; never emit a provider name without the account and failure evidence.
Never conclude with an unexplained "best quota" label.
Save that accounting as the task selection record at `data/<id>/dispatch-selection.md` when it drives the launch, because `fm-spawn.sh` refuses a launch its proof does not cover.
The record names the matched rule by index such as `rule_1` or `default` for the default array, carries exactly one `candidate:` line per entry of that rule's `use` array, and ends with the `chosen:` profile.
Each candidate line names its entry's harness and model with the quota reading, for example `candidate: pi:openrouter/anthropic/claude-sonnet-4.6 provider=openrouter remaining=50% spendPriority=10 runway=through_reset -> eligible`.
The chosen profile must be one of those candidates and equal the launch, and a stated `override:` reason line is the only way to launch a profile outside the listed candidates.
[`docs/configuration.md`](../../../docs/configuration.md#crew-dispatch-profiles-configcrew-dispatchjson) owns the proof contract.
