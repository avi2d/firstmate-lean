#!/usr/bin/env bash
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=bin/fm-quota-axi-lib.sh
. "$SCRIPT_DIR/fm-quota-axi-lib.sh"
# shellcheck source=bin/fm-subquo-lib.sh
. "$SCRIPT_DIR/fm-subquo-lib.sh"
# shellcheck source=bin/fm-quota-assessment-lib.sh
. "$SCRIPT_DIR/fm-quota-assessment-lib.sh"
# shellcheck source=bin/fm-control-lib.sh
. "$SCRIPT_DIR/fm-control-lib.sh"

die() { printf 'error: %s\n' "$1" >&2; exit 2; }
usage() {
  cat <<'USAGE'
Usage: fm-quota-choose.sh [--snapshot <path>] [--provider <family>] [--candidate <harness:model>]...

Reads a captured subquo.v1 JSON snapshot or quota-axi TOON or JSON.
Reads stdin by default. Pass --provider for subquo input.
With --provider, every candidate must use that provider.
Without --provider, each candidate must use its harness's primary family.
Prints the first viable "<harness> <model>", or "none" and exits 1.
USAGE
  exit 2
}

CANDIDATES=()
SNAPSHOT_SOURCE=
PROVIDER=
SUBQUO=false

while [ "$#" -gt 0 ]; do
  case "$1" in
    --snapshot)
      [ -n "${2-}" ] || die "--snapshot needs a path"
      SNAPSHOT_SOURCE=$2
      shift 2
      ;;
    --provider)
      [[ "${2:-}" =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]] || die "--provider needs a provider family"
      PROVIDER=$2
      shift 2
      ;;
    --candidate)
      [ -n "${2-}" ] || die "--candidate needs a value"
      CANDIDATES+=("$2")
      shift 2
      ;;
    -h|--help|help) usage ;;
    --) shift; break ;;
    -*) die "unknown option: $1" ;;
    *) CANDIDATES+=("$1") ; shift ;;
  esac
done

# Positional args after an explicit -- are also candidates.
while [ "$#" -gt 0 ]; do
  CANDIDATES+=("$1"); shift
done

[ "${#CANDIDATES[@]}" -gt 0 ] || die "no candidates supplied"

# A candidate is <harness>:<model>. A bare harness with no colon means the
# default model. Reject empty harnesses and characters that cannot form a safe
# token. A colon-separated model is legal (e.g. model:codex_bengalfox).
for c in "${CANDIDATES[@]}"; do
  case "$c" in
    ''|:*|*[!A-Za-z0-9._/:-]*) die "invalid candidate: $c" ;;
  esac
done

if [ -n "$SNAPSHOT_SOURCE" ]; then
  [ -f "$SNAPSHOT_SOURCE" ] && [ ! -L "$SNAPSHOT_SOURCE" ] || die "snapshot is not a regular file: $SNAPSHOT_SOURCE"
  QUOTA_SNAPSHOT=$(cat -- "$SNAPSHOT_SOURCE") || die "cannot read snapshot: $SNAPSHOT_SOURCE"
else
  [ ! -t 0 ] || die "quota snapshot is required on stdin or with --snapshot"
  QUOTA_SNAPSHOT=$(cat) || die "cannot read quota snapshot from stdin"
fi
[ -n "$QUOTA_SNAPSHOT" ] || die "empty quota snapshot"

if printf '%s\n' "$QUOTA_SNAPSHOT" | jq -e 'type == "object"' >/dev/null 2>&1; then
  QUOTA_JSON=$QUOTA_SNAPSHOT
  schema=$(printf '%s\n' "$QUOTA_JSON" | jq -r '.schemaVersion // empty' 2>/dev/null) || schema=
  case "$schema" in
    5|6) ;;
    '')
      if jq -e 'has("version")' <<< "$QUOTA_JSON" >/dev/null; then
        QUOTA_JSON=$(fm_subquo_decode <<< "$QUOTA_SNAPSHOT") || die "invalid subquo.v1 snapshot"
        SUBQUO=true
        [ -n "$PROVIDER" ] || die "subquo input needs the candidates' common --provider"
      else
        die "quota-axi json missing schemaVersion"
      fi
      ;;
    *) die "unsupported quota-axi schema version: $schema" ;;
  esac
else
  QUOTA_JSON=$(printf '%s\n' "$QUOTA_SNAPSHOT" | jq -Rse '
    def valid_preamble:
      ((length == 2) and
       (.[0] | test("^bin: (quota-axi|.*/quota-axi)$")) and
       (.[1] | test("^generatedAt: .+$"))) or
      ((length == 3) and
       (.[0] | test("^bin: (quota-axi|.*/quota-axi)$")) and
       (.[1] | test("^description: .+$")) and
       (.[2] | test("^generatedAt: .+$")));
    def valid_zero_head:
      (length == 0) or valid_preamble;
    def valid_help_tail:
      if length == 0 then true
      else
        (.[0] | capture("^help\\[(?<count>[0-9]+)\\]:$").count | tonumber) as $count |
        (.[1:] | length) == $count and all(.[1:][]; startswith("  "))
      end;
    def decoded_fields:
      def parse($remaining; $fields):
        if $remaining == "" then $fields
        elif ($remaining | startswith("\"")) then
          ($remaining | capture("^(?<field>\"(?:\\\\.|[^\"])*\")(?<rest>,.*|)$")) as $match |
          ($match.field | fromjson) as $field |
          if $match.rest == "," then $fields + [$field, ""]
          else parse(($match.rest | sub("^,"; "")); $fields + [$field])
          end
        else
          ($remaining | capture("^(?<field>[^,\"]*)(?<rest>,.*|)$")) as $match |
          if $match.rest == "," then $fields + [$match.field, ""]
          else parse(($match.rest | sub("^,"; "")); $fields + [$match.field])
          end
        end;
      parse(.; []);
    def decoded_row:
      sub("^  "; "") | decoded_fields;
    def valid_rows($field_count):
      all(.[];
        startswith("  ") and
        ((decoded_row | length) == $field_count) and
        all(decoded_row[]; length > 0)
      );
    # Schema 6 TOON adds accountKey right after provider in every block; $k is
    # that column offset (0 or 1) and keyed_row folds it into the record.
    def key_col($k): if $k == 1 then "accountKey," else "" end;
    def keyed_row($k): if $k == 1 then {provider: .[0], accountKey: .[1]} else {provider: .[0]} end;
    def account_of: if has("accountKey") then {accountKey} else {} end;
    def schema_of($k): if $k == 1 then 6 else 5 end;
    def valid_attention_entries:
      type == "array" and
      all(.[];
        type == "object" and
        (.provider | type) == "string" and
        (.provider | test("^[a-z0-9]+(-[a-z0-9]+)*$")) and
        ((has("accountKey") | not) or
         ((.accountKey | type) == "string" and (.accountKey | length) > 0 and ((.accountKey | test("\\s")) | not))) and
        (.scope | type) == "string" and
        (.scope | length) > 0 and
        ((.scope | test("^\\s|\\s$")) | not) and
        (.kind | type) == "string" and (.kind | length) > 0 and
        (.detail | type) == "string" and (.detail | length) > 0 and
        (.remedy | type) == "string" and (.remedy | length) > 0
      );
    def attention_availability:
      if .kind == "headroom_unknown" and (.detail | contains("exhausted_now")) then
        if (.detail | test("(^| · )exhausted_now limited by .+$")) then
          {scope: .scope, status: "unknown", runway: {status: "exhausted_now"}}
        else error("invalid exhausted headroom attention")
        end
      else empty
      end;
    def unknown_providers($entries):
      $entries |
      group_by([.provider, .accountKey]) |
      map((.[0] | {provider} + account_of) + {
        quotaSemantics: {
          status: "unknown",
          effectiveAvailability: [.[] | attention_availability]
        }
      });
    def unknown_snapshot($entries):
      {schemaVersion: (if any($entries[]; has("accountKey")) then 6 else 5 end), providers: unknown_providers($entries)};
    def exhaustion_count($k):
      if . == "exhaustion[0]:" or . == "exhaustion: []" then 0
      else
        capture("^exhaustion\\[(?<count>[1-9][0-9]*)\\]\\{provider," + key_col($k) + "scope,usableRunwaySeconds,projectedExhaustedAt,limitingWindowId\\}:$").count |
        tonumber
      end;
    def attention_count($k):
      if . == "attention[0]:" or . == "attention: []" then 0
      else
        capture("^attention\\[(?<count>[1-9][0-9]*)\\]\\{provider," + key_col($k) + "scope,kind,detail,remedy\\}:$").count |
        tonumber
      end;
    def attention_entries($k):
      map(decoded_row | keyed_row($k) + {
        scope: .[1 + $k], kind: .[2 + $k], detail: .[3 + $k], remedy: .[4 + $k]
      });
    (split("\n") | map(select(length > 0))) as $lines |
    ($lines | map(. == "quota[0]:" or . == "quota: []") | index(true)) as $zero_index |
    if $zero_index != null then
      ($lines[:$zero_index]) as $head |
      if ($head | valid_zero_head) then
        ($lines[($zero_index + 1):]) as $tail |
        if ($tail | length) >= 2 and
             ($tail[0] == "exhaustion[0]:" or $tail[0] == "exhaustion: []") then
          if ($tail[1] == "attention[0]:" or $tail[1] == "attention: []") and
             ($tail[2:] | valid_help_tail) then
            {schemaVersion: 5, providers: []}
          elif ($tail[1] | test("^attention\\[[1-9][0-9]*\\]\\{provider,(accountKey,)?scope,kind,detail,remedy\\}:$")) then
            (if ($tail[1] | contains("{provider,accountKey,")) then 1 else 0 end) as $k |
            ($tail[1] | attention_count($k)) as $attention_count |
            ($tail[2:(2 + $attention_count)]) as $attention_rows |
            if ($attention_rows | length) == $attention_count and
               ($attention_rows | valid_rows(5 + $k)) and
               ($tail[(2 + $attention_count):] | valid_help_tail) then
              ($attention_rows | attention_entries($k)) as $entries |
              if ($entries | valid_attention_entries) then
                unknown_snapshot($entries)
              else error("invalid zero-row attention identities")
              end
            else error("invalid zero-row attention section")
            end
          elif ($tail[1] | startswith("attention: ")) then
            ($tail[1] | sub("^attention: "; "") | fromjson) as $entries |
            if ($entries | valid_attention_entries) and
               ($tail[2:] | valid_help_tail) then
              unknown_snapshot($entries)
            else error("invalid zero-row attention array")
            end
          else error("invalid zero-row attention section")
          end
        else error("invalid zero-row quota sections")
        end
      else error("invalid zero-row quota header")
      end
    else
      ($lines | map(test("^quota\\[[1-9][0-9]*\\]\\{provider,(accountKey,)?scope,effectivePercentRemaining,spendPriority,runway,confidence,limitedBy,resetsAt\\}:$")) | index(true)) as $quota_index |
      if $quota_index == null then error("missing quota section")
      else
        (if ($lines[$quota_index] | contains("{provider,accountKey,")) then 1 else 0 end) as $k |
        ($lines[:$quota_index]) as $head |
        ($lines[$quota_index] | capture("^quota\\[(?<count>[1-9][0-9]*)\\]").count | tonumber) as $quota_count |
        ($lines[($quota_index + 1):($quota_index + 1 + $quota_count)]) as $quota_lines |
        ($quota_index + 1 + $quota_count) as $exhaustion_index |
        ($lines[$exhaustion_index] | exhaustion_count($k)) as $exhaustion_count |
        ($lines[($exhaustion_index + 1):($exhaustion_index + 1 + $exhaustion_count)]) as $exhaustion_rows |
        ($exhaustion_index + 1 + $exhaustion_count) as $attention_index |
        ($lines[$attention_index] | attention_count($k)) as $attention_count |
        ($lines[($attention_index + 1):($attention_index + 1 + $attention_count)]) as $attention_rows |
        ($lines[($attention_index + 1 + $attention_count):]) as $tail |
        if (($head | valid_preamble) | not) or
           ($quota_lines | length) != $quota_count or
           (($quota_lines | valid_rows(8 + $k)) | not) or
           ($exhaustion_rows | length) != $exhaustion_count or
           (($exhaustion_rows | valid_rows(5 + $k)) | not) or
           ($attention_rows | length) != $attention_count or
           (($attention_rows | valid_rows(5 + $k)) | not) or
           (($tail | valid_help_tail) | not) then
          error("invalid quota-axi TOON envelope")
        else
          ($quota_lines | map(decoded_row)) as $rows |
          ($attention_rows | attention_entries($k)) as $attention_entries |
          if (($attention_entries | valid_attention_entries) | not) then error("invalid attention identities")
          elif any($rows[]; length != 8 + $k) then error("invalid quota rows")
          else
            {
              schemaVersion: schema_of($k),
              providers: (($rows |
                map(keyed_row($k) + {
                  availability: {
                    scope: .[1 + $k],
                    status: "known",
                    effectivePercentRemaining: (.[2 + $k] | tonumber),
                    runway: {status: .[4 + $k]}
                  }
                })) +
                ($attention_entries | map(. as $entry | ($entry | {provider} + account_of) + {
                  availability: ([$entry | attention_availability] | first // null)
                })) |
                group_by([.provider, .accountKey]) |
                map((.[0] | {provider} + account_of) + {
                  quotaSemantics: {
                    status: (if any(.[]; .availability.status == "known") then "known" else "unknown" end),
                    effectiveAvailability: [.[].availability | select(. != null)]
                  }
                })
              )
            }
          end
        end
      end
    end
  ' 2>/dev/null) || die "invalid quota-axi snapshot"
fi

if [ "$SUBQUO" = false ]; then
  printf '%s\n' "$QUOTA_JSON" | fm_quota_json_valid || die "invalid quota-axi provider data"
fi

# provider_for_harness <harness> [<model>]
# The harness -> primary provider family table is owned by
# fm_quota_provider_for_harness in bin/fm-quota-axi-lib.sh; see the header
# limitation note for why one family per harness is all this helper checks.
provider_for_harness() {
  fm_quota_provider_for_harness "$@"
}

# effective_for_provider_model <provider> <model> <lane>
# Print the most constraining applicable quota evidence for the provider/model
# tuple, including provider-wide and exact model or product scopes. The row is
# bound through quota_row from bin/fm-quota-axi-lib.sh, so <lane> matters only
# on a schema 6 snapshot.
effective_for_provider_model() {
  local provider=$1 model=${2:-default} lane=${3:-}
  if [ "$SUBQUO" = true ]; then
    local row
    row=$(fm_subquo_row "$QUOTA_JSON" "$provider" "$lane") || return 1
    jq -c --arg model "$model" "$(fm_quota_assessment_jq)"'
      quota_applicable_rows(.; $model) |
      if any(.[]; .runway.status == "exhausted_now") then {runway: {status: "exhausted_now"}}
      elif length == 0 or any(.[]; .status != "known") then {status: "unknown"}
      else min_by(.effectivePercentRemaining) end
    ' <<< "$row"
    return
  fi
  printf '%s\n' "$QUOTA_JSON" | jq -c --arg provider "$provider" --arg model "$model" --arg lane "$lane" "$FM_QUOTA_ROW_JQ"'
    ($model | sub("^model:"; "")) as $model_token |
    quota_row(.; $provider; $lane) as $p |
    if ($p // null) == null then {status: "unknown"}
    else ($p.quotaSemantics.effectiveAvailability // []) |
    map(select(.scope as $scope |
      $scope == "all_models" or $scope == "all_products" or
      ($model_token != "" and $model_token != "default" and
       (($scope | startswith("model:")) or ($scope | startswith("product:"))) and
       ($model_token == ($scope | sub("^(model|product):"; ""))))
    )) as $applicable |
    ($applicable | map(select(.status == "known"))) as $known |
    if ($applicable | length) == 0 then {status: "unknown"}
    elif any($applicable[]; (.runway.status // "") == "exhausted_now") then
      ($applicable | map(select((.runway.status // "") == "exhausted_now")) | first)
    elif ($known | length) == 0 then {status: "unknown"}
    elif any($known[]; .effectivePercentRemaining == 0) then
      ($known | map(select(.effectivePercentRemaining == 0)) | first)
    else ($known | min_by(.effectivePercentRemaining))
    end
    end
  ' 2>/dev/null
}

for c in "${CANDIDATES[@]}"; do
  harness=${c%%:*}
  model=${c#*:}
  [ "$model" = "$c" ] && model="default"
  [ -n "$model" ] || die "invalid candidate: $c"
  fm_control_harness_supported "$harness" || die "unknown harness: $harness"

done

chosen="none"
for c in "${CANDIDATES[@]}"; do
  harness=${c%%:*}
  model=${c#*:}
  [ "$model" = "$c" ] && model="default"
  provider=${PROVIDER:-$(provider_for_harness "$harness" "$model")}
  lane=$(jq -rn --arg h "$harness" --arg m "$model" "$FM_QUOTA_ROW_JQ"'quota_lane($h; $m)')
  effective=$(effective_for_provider_model "$provider" "$model" "$lane")
  if [ -z "$effective" ] || [ "$effective" = "null" ]; then
    continue
  fi
  if printf '%s\n' "$effective" | jq -e '
    if (.runway.status // "") == "exhausted_now" then false
    elif .status == "unknown" then false
    else
      .effectivePercentRemaining as $remaining |
      (($remaining | type) == "number") and
      ($remaining > 0) and
      ((.runway.status // "") != "exhausted_now")
    end
  ' >/dev/null 2>&1; then
    chosen="$harness $model"
    break
  fi
done

printf '%s\n' "$chosen"
[ "$chosen" != "none" ]
