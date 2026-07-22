#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CASE_DIR="$(mktemp -d)"
trap 'rm -rf "$CASE_DIR"' EXIT
export RUNNER_TEMP="$CASE_DIR" ADOC_RUN_DIR="$CASE_DIR/private" ADOC_RETAINED_DIR="$CASE_DIR/retained"
export ADOC_INVOCATION_ID=inv_1_1_test_0123456789abcdef0123456789abcdef
export ADOC_EVALUATION_DATE=2026-07-22
export ADOC_REQUESTED_BASE=1111111111111111111111111111111111111111
export ADOC_COMPARISON_BASE=2222222222222222222222222222222222222222
export ADOC_HEAD=3333333333333333333333333333333333333333
export ADOC_PR_NUMBER=7 GITHUB_REPOSITORY=agentdoc/test GITHUB_RUN_ID=1
export GITHUB_RUN_ATTEMPT=1 GITHUB_JOB=test GITHUB_ACTOR=test
export GITHUB_ACTION_REF=v1 GITHUB_ACTION_REPOSITORY=agentdoc-dev/action
mkdir -p "$ADOC_RUN_DIR" "$ADOC_RETAINED_DIR"
printf '%s\n' '{"finalize":"pending"}' > "$ADOC_RUN_DIR/stages.json"
jq -n '{requested_version:"v0.3.0",resolved_version:"v0.3.0",binary_sha256:("sha256:"+("a"*64))}' \
  > "$ADOC_RUN_DIR/adoc-toolchain.json"

write_assessment() { # completeness outcome errors_full errors_changed errors_unattributed
  jq -n --arg completeness "$1" --arg outcome "$2" \
    --argjson full "$3" --argjson changed "$4" --argjson unattributed "$5" '{
      schema_version:"adoc.change_assessment.v0",completeness:$completeness,outcome:$outcome,
      knowledge_snapshot:(if $outcome == "invalid" then {status:"unavailable"} else
        {status:"available",graph_schema_version:"adoc.graph.v5",graph_sha256:("sha256:"+("1"*64)),object_set_sha256:("sha256:"+("2"*64))} end),
      validation:{errors_full:$full,errors_changed:$changed,errors_unchanged:0,errors_unattributed:$unattributed,warnings:0}
    }' > "$ADOC_RETAINED_DIR/assessment-$ADOC_INVOCATION_ID.json"
  printf '%s\n' "$ADOC_RETAINED_DIR/assessment-$ADOC_INVOCATION_ID.json" > "$ADOC_RUN_DIR/assessment-path"
  printf 'sha256:%064d\n' 9 > "$ADOC_RUN_DIR/assessment-sha256"
}

reset_case() {
  : > "$CASE_DIR/output"
  export GITHUB_OUTPUT="$CASE_DIR/output"
  rm -f "$ADOC_RUN_DIR/failure.json" "$ADOC_RUN_DIR/path-limit-reason" \
    "$ADOC_RUN_DIR/adoc-propose-code" "$ADOC_RUN_DIR/adoc-final-code"
}

finalize() {
  ENFORCEMENT="$1" SCOPE="$2" PROPOSE=false PROPOSE_ON_ERROR=warn PROPOSE_DELIVERY=comment \
    "$ROOT/scripts/finalize.sh"
}

expect_code() { test "$(cat "$ADOC_RUN_DIR/adoc-final-code")" = "$1"; }
receipt() { printf '%s/receipt-%s.json' "$ADOC_RETAINED_DIR" "$ADOC_INVOCATION_ID"; }

reset_case
write_assessment complete review_required 0 0 0
finalize advisory full
expect_code 0
jq -e '.run_status == "completed" and .conclusion.status == "success"' "$(receipt)" >/dev/null

reset_case
write_assessment error invalid 2 1 0
finalize advisory full
expect_code 0
jq -e '.knowledge_snapshot == null and .conclusion.status == "success"' "$(receipt)" >/dev/null

reset_case
write_assessment error invalid 2 1 0
finalize strict full
expect_code 2
jq -e '.conclusion.reason_codes == ["action.structural_errors_full"]' "$(receipt)" >/dev/null

reset_case
write_assessment error invalid 2 0 0
finalize strict diff
expect_code 0

reset_case
write_assessment error invalid 2 0 1
finalize strict diff
expect_code 2
jq -e '.conclusion.reason_codes == ["action.structural_errors_changed"]' "$(receipt)" >/dev/null

reset_case
write_assessment partial not_evaluated 0 0 0
finalize advisory full
expect_code 2
jq -e '.conclusion.reason_codes == ["action.assessment_partial"]' "$(receipt)" >/dev/null

reset_case
write_assessment error not_evaluated 0 0 0
finalize advisory full
expect_code 2
jq -e '.conclusion.reason_codes == ["action.assessment_not_evaluated"]' "$(receipt)" >/dev/null

reset_case
write_assessment complete uncovered 0 0 0
echo action.path_limit_exceeded > "$ADOC_RUN_DIR/path-limit-reason"
finalize advisory full
expect_code 2
jq -e '.conclusion.reason_codes == ["action.path_limit_exceeded"]' "$(receipt)" >/dev/null

reset_case
write_assessment complete review_required 0 0 0
echo 1 > "$ADOC_RUN_DIR/adoc-propose-code"
ENFORCEMENT=advisory SCOPE=full PROPOSE=true PROPOSE_ON_ERROR=fail PROPOSE_DELIVERY=comment \
  "$ROOT/scripts/finalize.sh"
expect_code 2
jq -e '.conclusion.reason_codes == ["action.proposal_failed"]' "$(receipt)" >/dev/null

reset_case
rm -f "$ADOC_RUN_DIR/assessment-path" "$ADOC_RUN_DIR/assessment-sha256"
jq -n '{stage:"snapshot",code:"action.assessment_ref_failed",severity:"error",message:"Exact commits unavailable.",help:"Fetch full history."}' \
  > "$ADOC_RUN_DIR/failure.json"
finalize advisory full
expect_code 2
jq -e '.run_status == "failed" and .assessment == null and .failure.code == "action.assessment_ref_failed"' \
  "$(receipt)" >/dev/null
test -z "$(sed -n 's/^assessment-path=//p' "$GITHUB_OUTPUT" | tail -n 1)"

echo 'fail-honest receipt tests passed'
