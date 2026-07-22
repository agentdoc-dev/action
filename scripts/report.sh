#!/usr/bin/env bash
# Runs the single deterministic V9.2 Change Assessment. Valid nonzero
# envelopes are retained; every other failure is deferred to finalization.
set -uo pipefail

OUT="${ADOC_RUN_DIR:-$RUNNER_TEMP}"
SELF="$(cd "$(dirname "$0")" && pwd)"
source "$SELF/state.sh"
[ ! -s "$OUT/failure.json" ] || exit 0

assessment_tmp="$OUT/assessment.json.tmp"
if adoc assess-changes \
  --base "$ADOC_REQUESTED_BASE" \
  --head "$ADOC_HEAD" \
  --as-of "$ADOC_EVALUATION_DATE" \
  --format json > "$assessment_tmp" 2> "$OUT/assessment.stderr"; then
  assessment_code=0
else
  assessment_code=$?
fi

valid=false
if jq -e \
  --arg date "$ADOC_EVALUATION_DATE" \
  --arg base "$ADOC_REQUESTED_BASE" \
  --arg comparison "$ADOC_COMPARISON_BASE" \
  --arg head "$ADOC_HEAD" '
    def nonnegative: type == "number" and . >= 0 and floor == .;
    .schema_version == "adoc.change_assessment.v0"
    and ([.completeness,.outcome] | IN(
      ["complete","pass"],
      ["complete","review_required"],
      ["complete","uncovered"],
      ["partial","not_evaluated"],
      ["error","invalid"],
      ["error","not_evaluated"]))
    and .evaluation_date == $date
    and .snapshots.requested_base.requested_ref == $base
    and .snapshots.requested_base.resolved_commit == $base
    and .snapshots.requested_base.immutable == true
    and .snapshots.comparison_base.resolved_commit == $comparison
    and .snapshots.comparison_base.strategy == "merge_base"
    and .snapshots.comparison_base.immutable == true
    and .snapshots.head.requested_ref == $head
    and .snapshots.head.resolved_commit == $head
    and .snapshots.head.immutable == true
    and (.knowledge_snapshot.status | IN("available","unavailable"))
    and (.paths.status | IN("available","unavailable"))
    and (.objects.status | IN("available","unavailable"))
    and (.knowledge_changes.status | IN("available","unavailable"))
    and ([.summary.changed_paths,.summary.covered,.summary.provisional,
          .summary.uncovered,.summary.excluded,.summary.impacted_objects]
         | all(nonnegative))
    and ([.validation.errors_full,.validation.errors_changed,
          .validation.errors_unchanged,.validation.errors_unattributed,
          .validation.warnings] | all(nonnegative))
    and (.required_reviewers | type == "array")
    and (.proof_obligations | type == "array")
    and (.signals | type == "array")
    and (.diagnostics | type == "array")
    and (if .paths.status == "available" then (.paths.value | type == "array") else (.paths | has("value") | not) end)
    and (if .objects.status == "available" then (.objects.value | type == "array") else (.objects | has("value") | not) end)
    and (if .knowledge_changes.status == "available" then (.knowledge_changes.value | type == "object") else (.knowledge_changes | has("value") | not) end)
  ' "$assessment_tmp" >/dev/null 2>&1; then
  tuple="$(jq -r '.completeness + "/" + .outcome' "$assessment_tmp")"
  case "$tuple/$assessment_code" in
    complete/pass/0 | complete/review_required/0 | complete/uncovered/0 \
      | partial/not_evaluated/2 | error/invalid/2 | error/not_evaluated/2) valid=true ;;
  esac
fi

if [ "$valid" != true ]; then
  adoc_fail assessment action.assessment_contract_failed \
    'AgentDoc did not return the supported Change Assessment contract.' \
    'Pin AgentDoc v0.3.0 and rerun; inspect the private workflow log for the failing stage.'
  printf 'ADOC_ASSESSMENT_VALID=false\nADOC_PIPELINE_READY=false\n' >> "$GITHUB_ENV"
  exit 0
fi

assessment_path="$ADOC_RETAINED_DIR/assessment-${ADOC_INVOCATION_ID}.json"
cp "$assessment_tmp" "$assessment_path"
assessment_sha="sha256:$(sha256sum "$assessment_path" | awk '{print $1}')"
printf '%s\n' "$assessment_path" > "$OUT/assessment-path"
printf '%s\n' "$assessment_sha" > "$OUT/assessment-sha256"

changed_paths="$(jq -r '.summary.changed_paths' "$assessment_path")"
if [ "$changed_paths" -gt 5000 ]; then
  printf '%s\n' action.path_limit_exceeded > "$OUT/path-limit-reason"
fi

# Private compatibility projections keep the legacy proposal flow alive
# without recomputing any AgentDoc classification or invoking another query.
jq -r '.paths.value[]? | select(.classification == "uncovered") | .path' \
  "$assessment_path" > "$OUT/uncovered-paths"
jq '{impacted:[.objects.value[]? | {id,owner,reasons}]}' \
  "$assessment_path" > "$OUT/impacted.json"
jq -r '
  def line: gsub("[\\u0000-\\u001f\\u007f]"; " ");
  .diagnostics[]? | select(.source != null)
  | "\(.source.path|line):\(.source.line):\(.source.column): \(.severity|if . == "warning" then "warning" else . end)[\(.code|line)] \(.message|line)"' \
  "$assessment_path" > "$OUT/check.diag"
cat "$OUT/check.diag" >&2

adoc_set_stage assessment complete
printf 'ADOC_ASSESSMENT_VALID=true\n' >> "$GITHUB_ENV"
exit 0
