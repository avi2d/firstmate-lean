# Local Claude usage threshold warner

`bin/fm-usage-warner.sh` is an opt-in, macOS-only threshold warner for Claude usage windows.
It is a warner, not a viewer: it never renders a live usage report, and it speaks only once when a configured window reaches a configured percentage of itself consumed.

The warner reads the default Claude account from the [local subquo snapshot](configuration.md#quota-snapshot).
If the snapshot has no usable reading for that account, it falls back to quota-axi with `--no-credential-refresh`.
It never requests a credential refresh or a Keychain prompt.

## Opt-in is load-bearing

An unconfigured home sees no behaviour change: `check` stays completely silent, and `arm` refuses outright rather than registering a check that would never have anything to warn about.

## Configuring thresholds (config/usage-warner)

Thresholds live in `config/usage-warner`, local and gitignored; its `<window-id>:<percent>` schema is owned by [`configuration.md`](configuration.md#local-claude-usage-warner-configusage-warner).
`<window-id>` keeps its quota-axi spelling.
On a subquo read, `five_hour` matches `five-hour`, `seven_day` matches `weekly`, `seven_day_opus` matches `opus-weekly`, and `model:fable` matches `fable-weekly`.
A configured window id the account does not return is silently never compared: this is a local convenience feature, not a critical monitor, so a stale or unavailable id is not treated as a misconfiguration to flag.

Use the account-wide `five_hour` and `seven_day` thresholds when you do not need per-model warnings.
See [`docs/examples/usage-warner`](examples/usage-warner) for a starting point to copy into a local `config/usage-warner`.

## Behaviour: one read, two callers, edge-triggered

`check` is the one read with two callers - a human or another script running `fm-usage-warner.sh check` directly (on demand), and the watcher polling the registered shim on its normal `FM_CHECK_INTERVAL` cadence once armed (periodic).
Both hit the identical function, so this is one program with two callers, not two programs, and there is no daemon and no schedule of its own.
When the two overlap, they are serialized on `state/.usage-warner.lock`, and a check that finds that lock held exits quietly, so one crossing still warns once.

A window that crosses a configured threshold notifies once, stays quiet while it remains at or above that threshold, and re-arms the moment it next reads back below threshold (an account-level window's own reset does exactly this).
Each directive is tracked on its own, so tiered thresholds on one window such as `five_hour:80` and `five_hour:95` each warn on their own crossing.
Multiple windows crossing in the same read are batched into one notification rather than one per window.
A window missing from an otherwise valid read does not clear its threshold record.
The record keys each entry by window ID and percentage.
A version 1 record keyed by window ID remains valid for every threshold on that window, so an upgrade does not repeat a warning.
The quota read is timed and validates the snapshot and each window's required field types.
A read with no usable window is reported as a failure.
A standing read failure is reported once until it changes, as in `bin/fm-tool-update-check.sh`.
The failure may be a missing `quota-axi` or `jq`, a malformed response, or a read that exceeds its bound.
The read bound is 10 seconds, or `FM_CHECK_TIMEOUT` minus 3 seconds when that is lower, so the watcher never kills the check first; when that leaves under 1 second the read is skipped and reported as not measured.

## Notification path

Warnings reach macOS through Notification Center using `osascript display notification`.
Notification Center is macOS-only, so `arm` refuses on any other platform.

## Relationship to the quota process-event source

[`bin/fm-procevent-quota.sh`](../bin/fm-procevent-quota.sh) reads the same snapshot but checks account and model headroom against a remaining-quota threshold.
It sends one wake, then you must re-arm it to keep monitoring.
This warner is the standing half of that problem: it compares each named window separately and re-arms itself every time a window reads back below its threshold.
A crossing raises a macOS notification and, once armed, also reaches firstmate as one `check:` wake per crossing, because the armed shim's report line is what the watcher turns into that wake.
Naming the window is the point, because the session and weekly windows exhaust at very different times, so an aggregate figure does not say which one is about to run out.
Neither replaces the other, and arming both is reasonable: this one warns per window on every crossing while a window is still closing, and the other fires once on a provider-wide aggregate until it is re-armed by hand.

## Arming

Arm once per home with `bin/fm-usage-warner.sh arm` and remove it with `bin/fm-usage-warner.sh disarm`.
The shim writer refuses a symlink at its destination and renames a completed file into place.
[`configuration.md`](configuration.md#local-claude-usage-warner-configusage-warner) describes what each command writes or removes and when `arm` refuses.

## What this never does

The warner does not install, refresh, or write credentials or display a usage report.
Account or seat switching is explicitly out of scope: only the default account lane is ever read.

It also does not stop or pace anything: crossing a threshold posts a warning and nothing else, so dispatch, running work, and merge behaviour are all unchanged.
The warner cannot detect a cap that the quota reading does not report.
Silence means no measured window crossed a configured threshold, not that every cap has room.
