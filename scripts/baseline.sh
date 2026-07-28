#!/usr/bin/env bash
set -uo pipefail

OUT="${ADOC_RUN_DIR:-${RUNNER_TEMP:?}}"
SELF="$(cd "$(dirname "$0")" && pwd)"
source "$SELF/state.sh"

tmp="$OUT/baseline.json.tmp"
if adoc baseline --ref "$ADOC_HEAD" --as-of "$ADOC_EVALUATION_DATE" \
  --format json > "$tmp" 2> "$OUT/baseline.stderr"; then
  code=0
else
  code=$?
fi

if [ "$code" -ne 0 ] || ! jq -e --arg head "$ADOC_HEAD" '
  def nonnegative: type == "number" and . >= 0 and floor == .;
  .schema_version == "adoc.repository_baseline.v0"
  and (.readiness.ready | type == "boolean")
  and (.readiness.reason | IN("ready","invalid_source","provisional_paths","uncovered_paths"))
  and .snapshot.requested_ref == $head
  and .snapshot.resolved_commit == $head
  and .snapshot.immutable == true
  and .knowledge_snapshot.status == "available"
  and (.knowledge_snapshot.graph_sha256 | test("^sha256:[0-9a-f]{64}$"))
  and (.knowledge_snapshot.object_set_sha256 | test("^sha256:[0-9a-f]{64}$"))
  and (.assessment_config.policy.effective_sha256 | test("^sha256:[0-9a-f]{64}$"))
  and .paths.status == "available"
  and (.paths.value | length) == .summary.changed_paths
  and ([.summary.changed_paths,.summary.covered,.summary.provisional,
        .summary.uncovered,.summary.excluded] | all(nonnegative))
' "$tmp" >/dev/null 2>&1; then
  adoc_fail baseline action.baseline_contract_failed \
    'AgentDoc did not return a valid repository baseline.' \
    'Pin AgentDoc v0.3.4 and rerun.'
  printf 'ADOC_BASELINE_VALID=false\n' >> "$GITHUB_ENV"
  exit 0
fi

path="$ADOC_RETAINED_DIR/baseline-${ADOC_INVOCATION_ID}.json"
cp "$tmp" "$path"
sha="sha256:$(sha256sum "$path" | awk '{print $1}')"
printf '%s\n' "$path" > "$OUT/baseline-path"
printf '%s\n' "$sha" > "$OUT/baseline-sha256"
adoc_set_stage baseline complete
printf 'ADOC_BASELINE_VALID=true\n' >> "$GITHUB_ENV"

if [ "${ADOC_BOOTSTRAP:-false}" = true ]; then
  jq '{
    schema_version:"adoc.change_assessment.v0",
    completeness:"complete",
    knowledge_snapshot,
    paths,
    objects
  }' "$path" > "$OUT/model-assessment.json"
  printf '%s\n' "$OUT/model-assessment.json" > "$OUT/model-assessment-path"
  printf 'sha256:%s\n' "$(sha256sum "$OUT/model-assessment.json" | awk '{print $1}')" \
    > "$OUT/model-assessment-sha256"
fi
