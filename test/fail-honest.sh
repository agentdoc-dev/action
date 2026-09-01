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
export GITHUB_ACTOR_ID=42 GITHUB_TRIGGERING_ACTOR=test GITHUB_REPOSITORY_ID=99
export GITHUB_WORKFLOW_REF=agentdoc/test/.github/workflows/test.yml@refs/heads/main
export GITHUB_WORKFLOW_SHA=4444444444444444444444444444444444444444
export GITHUB_ACTION_REF=v1 GITHUB_ACTION_REPOSITORY=agentdoc-dev/action
mkdir -p "$ADOC_RUN_DIR" "$ADOC_RETAINED_DIR"
printf '%s\n' '{"finalize":"pending"}' > "$ADOC_RUN_DIR/stages.json"
jq -n '{requested_version:"v0.3.4",resolved_version:"v0.3.4",binary_sha256:("sha256:"+("a"*64))}' \
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
    "$ADOC_RUN_DIR/adoc-propose-code" "$ADOC_RUN_DIR/adoc-semantic-code" \
    "$ADOC_RUN_DIR/semantic-status.json" "$ADOC_RUN_DIR/proposal-status.json" \
    "$ADOC_RUN_DIR/delivery-status.json" "$ADOC_RUN_DIR/adoc-final-code"
}

write_baseline() {
  jq -n --argjson ready "$1" '{
    schema_version:"adoc.repository_baseline.v0",
    readiness:{ready:$ready,reason:(if $ready then "ready" else "uncovered_paths" end)}
  }' > "$ADOC_RETAINED_DIR/baseline-$ADOC_INVOCATION_ID.json"
  printf '%s\n' "$ADOC_RETAINED_DIR/baseline-$ADOC_INVOCATION_ID.json" \
    > "$ADOC_RUN_DIR/baseline-path"
  printf 'sha256:%s\n' "$(sha256sum "$ADOC_RETAINED_DIR/baseline-$ADOC_INVOCATION_ID.json" \
    | awk '{print $1}')" > "$ADOC_RUN_DIR/baseline-sha256"
}

finalize() {
  ENFORCEMENT="$1" SCOPE="$2" SYNC_POLICY=advisory PROPOSE=false \
    PROPOSE_ON_ERROR=warn PROPOSE_DELIVERY=comment \
    "$ROOT/scripts/finalize.sh"
}

expect_code() { test "$(cat "$ADOC_RUN_DIR/adoc-final-code")" = "$1"; }
receipt() { printf '%s/receipt-%s.json' "$ADOC_RETAINED_DIR" "$ADOC_INVOCATION_ID"; }

reset_case
write_assessment complete review_required 0 0 0
finalize advisory full
expect_code 0
jq -e --arg head "$ADOC_HEAD" '
  .run_status == "completed" and .conclusion.status == "success"
  and .delivery == {
    status:"skipped",mode:"comment",reason:"comment_only",
    assessed_head:$head,delivery_commit:null,branch:null,url:null
  }
' "$(receipt)" >/dev/null

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
write_assessment complete review_required 0 0 0
jq -n '{status:"complete",count:2,sha256:("sha256:"+("b"*64)),reason:"validated"}' \
  > "$ADOC_RUN_DIR/proposal-status.json"
ENFORCEMENT=advisory SCOPE=full PROPOSE=true PROPOSE_ON_ERROR=warn \
  PROPOSE_DELIVERY=comment "$ROOT/scripts/finalize.sh"
expect_code 0
jq -e '.proposals.status == "complete"
  and .proposals.count == 2
  and .proposals.sha256 == ("sha256:" + ("b" * 64))' "$(receipt)" >/dev/null

reset_case
write_assessment complete review_required 0 0 0
jq -n --arg assessed "$ADOC_HEAD" '{
  status:"complete",mode:"commit",reason:null,assessed_head:$assessed,
  delivery_commit:("4" * 40),branch:"feature",url:null
}' > "$ADOC_RUN_DIR/delivery-status.json"
ENFORCEMENT=advisory SCOPE=full PROPOSE=true PROPOSE_ON_ERROR=warn \
  PROPOSE_DELIVERY=commit "$ROOT/scripts/finalize.sh"
jq -e --arg assessed "$ADOC_HEAD" '
  .delivery.status == "complete" and .delivery.mode == "commit"
  and .delivery.assessed_head == $assessed
  and .delivery.delivery_commit == ("4" * 40)
  and .delivery.branch == "feature" and .delivery.url == null
' "$(receipt)" >/dev/null

reset_case
write_assessment complete review_required 0 0 0
printf '%s\n' '{"status":"complete","mode":"commit","reason":null}' \
  > "$ADOC_RUN_DIR/delivery-status.json"
ENFORCEMENT=advisory SCOPE=full PROPOSE=true PROPOSE_ON_ERROR=warn \
  PROPOSE_DELIVERY=commit "$ROOT/scripts/finalize.sh"
jq -e '.delivery.status == "error"
  and .delivery.reason == "delivery_contract_failed"' "$(receipt)" >/dev/null

reset_case
write_assessment complete review_required 0 0 0
echo 1 > "$ADOC_RUN_DIR/adoc-semantic-code"
printf '%s\n' '{"status":"error","schema_version":null,"sha256":null}' \
  > "$ADOC_RUN_DIR/semantic-status.json"
ENFORCEMENT=advisory SCOPE=full SEMANTIC_REVIEW=true PROPOSE=false \
  PROPOSE_ON_ERROR=fail PROPOSE_DELIVERY=comment "$ROOT/scripts/finalize.sh"
expect_code 2
jq -e '.conclusion.reason_codes == ["action.semantic_review_failed"]
  and .semantic_review.status == "error"' "$(receipt)" >/dev/null

reset_case
write_assessment complete review_required 0 0 0
write_baseline false
ENFORCEMENT=advisory SCOPE=full SYNC_POLICY=required PROPOSE=true \
  PROPOSE_ON_ERROR=fail PROPOSE_DELIVERY=pr "$ROOT/scripts/finalize.sh"
expect_code 2
jq -e '.conclusion.reason_codes == [
  "action.baseline_not_ready","action.knowledge_review_incomplete"
] and .policy.knowledge_enforcement == "required"
  and .knowledge_gate == {
    status:"evaluated",mode:"required",policy_revision:"adoc-action-sync.v0",
    conclusion:"failure",
    reason_codes:["action.baseline_not_ready","action.knowledge_review_incomplete"]
  }' "$(receipt)" >/dev/null

reset_case
write_assessment complete review_required 0 0 0
write_baseline true
printf '%s\n' '{}' > "$ADOC_RETAINED_DIR/semantic-$ADOC_INVOCATION_ID.json"
semantic_sha="sha256:$(sha256sum "$ADOC_RETAINED_DIR/semantic-$ADOC_INVOCATION_ID.json" \
  | awk '{print $1}')"
jq -n --arg path "$ADOC_RETAINED_DIR/semantic-$ADOC_INVOCATION_ID.json" \
  --arg sha "$semantic_sha" '{
    status:"complete",reason:"complete",schema_version:"adoc.semantic_review.v0",
    path:$path,sha256:$sha
  }' > "$ADOC_RUN_DIR/semantic-status.json"
jq -n '{status:"complete",count:1,sha256:("sha256:"+("b"*64)),reason:"validated"}' \
  > "$ADOC_RUN_DIR/proposal-status.json"
jq -n --arg assessed "$ADOC_HEAD" '{
  status:"complete",mode:"pr",reason:null,assessed_head:$assessed,
  delivery_commit:("4"*40),branch:"adoc/proposals/pr-7",url:"https://example.test/pr/8"
}' > "$ADOC_RUN_DIR/delivery-status.json"
ENFORCEMENT=advisory SCOPE=full SYNC_POLICY=required SEMANTIC_REVIEW=true \
  PROPOSE=true PROPOSE_ON_ERROR=fail PROPOSE_DELIVERY=pr "$ROOT/scripts/finalize.sh"
expect_code 2
jq -e '.conclusion.reason_codes == [
    "action.knowledge_sync_pending","action.semantic_review_failed"
  ]
  and .repository_baseline.status == "ready"
  and .knowledge_gate.conclusion == "failure"
  and .knowledge_gate.reason_codes == ["action.knowledge_sync_pending"]' "$(receipt)" >/dev/null

reset_case
rm -f "$ADOC_RUN_DIR/assessment-path" "$ADOC_RUN_DIR/assessment-sha256"
jq -n '{stage:"snapshot",code:"action.assessment_ref_failed",severity:"error",message:"Exact commits unavailable.",help:"Fetch full history."}' \
  > "$ADOC_RUN_DIR/failure.json"
finalize advisory full
expect_code 2
jq -e '.run_status == "failed" and .assessment == null
  and .failure.code == "action.assessment_ref_failed"
  and .ci.workload_identity.actor_id == "42"
  and .ci.workload_identity.workflow_sha == ("4" * 40)' \
  "$(receipt)" >/dev/null
test -z "$(sed -n 's/^assessment-path=//p' "$GITHUB_OUTPUT" | tail -n 1)"
test "$(sed -n 's/^semantic-assessment-status=//p' "$GITHUB_OUTPUT" | tail -n 1)" = skipped

reset_case
rm -f "$ADOC_RUN_DIR/assessment-path" "$ADOC_RUN_DIR/assessment-sha256"
jq -n '{stage:"preflight",code:"action.invalid_input",severity:"error",message:"Invalid identity.",help:"Rerun in GitHub Actions."}' \
  > "$ADOC_RUN_DIR/failure.json"
unset GITHUB_SERVER_URL
export GITHUB_REPOSITORY_ID=invalid
export GITHUB_RUN_ID=invalid GITHUB_RUN_ATTEMPT=invalid GITHUB_JOB=
export GITHUB_ACTOR_ID=invalid GITHUB_TRIGGERING_ACTOR=
export GITHUB_WORKFLOW_REF='' GITHUB_WORKFLOW_SHA=invalid
finalize advisory full
expect_code 2
jq -e '.run_status == "failed"
  and .ci.run_id == null and .ci.run_attempt == null and .ci.job == null
  and .ci.workload_identity == {
    provider:"github_actions",server_url:null,repository_id:null,
    workflow_ref:null,workflow_sha:null,actor_id:null,triggering_actor:null
  }' "$(receipt)" >/dev/null

echo 'fail-honest receipt tests passed'
