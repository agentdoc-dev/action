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
    "$ADOC_RUN_DIR/delivery-status.json" "$ADOC_RUN_DIR/adoc-final-code" \
    "$ADOC_RUN_DIR/semantic-execution-status.json" \
    "$ADOC_RUN_DIR/trusted-phase-status.json" \
    "$ADOC_RUN_DIR/trusted-semantic-no-op"
  rm -f "$ADOC_RUN_DIR/cloud-sync-status.json"
  rm -f "$ADOC_RETAINED_DIR/semantic-assessment-$ADOC_INVOCATION_ID.json" \
    "$ADOC_RETAINED_DIR/semantic-executor-$ADOC_INVOCATION_ID.json"
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
    reason_code:null,remediation:null,
    assessed_head:$head,delivery_commit:null,branch:null,url:null
  }
' "$(receipt)" >/dev/null

reset_case
write_assessment complete review_required 0 0 0
jq -n '{status:"failed",reason:"upload_failed",
  reason_code:"action.cloud_sync_failed",result_digest:("sha256:"+("c"*64)),
  remediation:"Retry the scoped Workspace upload."}' \
  > "$ADOC_RUN_DIR/cloud-sync-status.json"
finalize advisory full
expect_code 0
jq -e '.conclusion == {status:"success",reason_codes:[]}
  and .assessment.outcome == "review_required"
  and .cloud_sync.status == "failed"
  and .cloud_sync.reason_code == "action.cloud_sync_failed"' "$(receipt)" >/dev/null

reset_case
write_assessment complete review_required 0 0 0
jq -n '{status:"failed",reason:"stale_head",
  reason_code:"action.cloud_sync_failed",result_digest:("sha256:"+("d"*64)),
  remediation:"Authorize and upload the current exact head."}' \
  > "$ADOC_RUN_DIR/cloud-sync-status.json"
finalize advisory full
expect_code 0
jq -e '.cloud_sync.status == "failed" and .cloud_sync.reason == "stale_head"
  and .cloud_sync.result_digest == ("sha256:" + ("d" * 64))' \
  "$(receipt)" >/dev/null

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
  status:"complete",mode:"commit",reason:null,reason_code:null,remediation:null,
  assessed_head:$assessed,
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
jq -n --arg assessed "$ADOC_HEAD" '{
  status:"error",mode:"commit",reason:"proposal_record_failed",
  reason_code:null,remediation:null,assessed_head:$assessed,
  delivery_commit:null,branch:null,url:null
}' > "$ADOC_RUN_DIR/delivery-status.json"
ENFORCEMENT=advisory SCOPE=full PROPOSE=true PROPOSE_ON_ERROR=warn \
  PROPOSE_DELIVERY=commit "$ROOT/scripts/finalize.sh"
jq -e '.delivery.status == "error" and .delivery.mode == "commit"
  and .delivery.reason == "proposal_record_failed"' "$(receipt)" >/dev/null

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
  status:"complete",mode:"pr",reason:null,reason_code:null,remediation:null,
  assessed_head:$assessed,
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
write_assessment complete review_required 0 0 0
printf '%s\n' '{}' \
  > "$ADOC_RETAINED_DIR/semantic-assessment-$ADOC_INVOCATION_ID.json"
trusted_result="sha256:$(sha256sum \
  "$ADOC_RETAINED_DIR/semantic-assessment-$ADOC_INVOCATION_ID.json" | awk '{print $1}')"
jq -n --arg result "$trusted_result" '{
  status:"completed",failure_code:null,assessment_sha256:$result,
  primary:{request_id:"trusted",provider:"codex",model:"gpt-5.6-codex",
    outcome:"completed",failure_code:null},fallback:null
}' > "$ADOC_RUN_DIR/semantic-execution-status.json"
jq -n --arg result "$trusted_result" '{
  schema_version:"adoc.semantic_executor_receipt.v0",outcome:"completed",
  request_id:"trusted",assessment_digest:$result,
  adapter:{provider:"codex",model:"gpt-5.6-codex",
    config_digest:("sha256:" + ("6" * 64))},
  context_digest:("sha256:" + ("7" * 64))
}' > "$ADOC_RETAINED_DIR/semantic-executor-$ADOC_INVOCATION_ID.json"
jq -n --arg head "$ADOC_HEAD" '{
  state:"running",reason_code:null,remediation:null,head_revision:$head,
  observed_head_revision:$head,request_digest:("sha256:" + ("3" * 64)),
  authorizer:{principal_id:"20000000-0000-0000-0000-000000000408",
    authorization_decision_id:"70000000-0000-0000-0000-000000000408"},
  policy:{version:"trusted-change-v1",digest:("sha256:" + ("5" * 64))},
  workload:{principal_id:"21000000-0000-0000-0000-000000000408",
    session_id:"40000000-0000-0000-0000-000000000408"},
  executor:{qualification_id:"50000000-0000-0000-0000-000000000408",
    provider:"codex",model:"gpt-5.6-codex",
    config_digest:("sha256:" + ("6" * 64))},
  context_request_digest:("sha256:" + ("4" * 64)),
  context_digest:null,result_digest:null,
  workflow:{ref:"agentdoc/test/.github/workflows/trusted.yml@refs/heads/main",
    sha:("4" * 40)}
}' > "$ADOC_RUN_DIR/trusted-phase-status.json"
cp "$ADOC_RUN_DIR/trusted-phase-status.json" "$CASE_DIR/trusted-running.json"
ADOC_UNTRUSTED_CHANGE=true ADOC_TRUSTED_PHASE=true \
  ENFORCEMENT=advisory SCOPE=full SEMANTIC_REVIEW=false PROPOSE=true \
  PROPOSE_ON_ERROR=fail PROPOSE_DELIVERY=comment \
  "$ROOT/scripts/finalize.sh"
expect_code 0
jq -e --arg result "$trusted_result" '
  .trusted_phase.state == "completed"
  and .trusted_phase.authorizer.authorization_decision_id
    == "70000000-0000-0000-0000-000000000408"
  and .trusted_phase.policy.version == "trusted-change-v1"
  and .trusted_phase.workload.session_id
    == "40000000-0000-0000-0000-000000000408"
  and .trusted_phase.executor.qualification_id
    == "50000000-0000-0000-0000-000000000408"
  and .trusted_phase.context_digest == ("sha256:" + ("7" * 64))
  and .trusted_phase.result_digest == $result
' "$(receipt)" >/dev/null

reset_case
write_assessment complete review_required 0 0 0
cp "$CASE_DIR/trusted-running.json" "$ADOC_RUN_DIR/trusted-phase-status.json"
jq -n '{status:"completed",reason:"uploaded",reason_code:null,
  result_digest:("sha256:" + ("8" * 64)),remediation:null}' \
  > "$ADOC_RUN_DIR/cloud-sync-status.json"
ADOC_UNTRUSTED_CHANGE=true ADOC_TRUSTED_PHASE=true CLOUD_SYNC_REQUESTED=true \
  ENFORCEMENT=advisory SCOPE=full SEMANTIC_REVIEW=false PROPOSE=false \
  PROPOSE_ON_ERROR=fail PROPOSE_DELIVERY=comment \
  "$ROOT/scripts/finalize.sh"
expect_code 0
jq -e '.semantic_review.status == "disabled"
  and .semantic_assessment.status == "skipped"
  and .cloud_sync.status == "completed"
  and .trusted_phase.state == "completed"
  and .trusted_phase.context_digest == null
  and .trusted_phase.result_digest == null
  and .conclusion == {status:"success",reason_codes:[]}' \
  "$(receipt)" >/dev/null

reset_case
write_assessment complete review_required 0 0 0
cp "$CASE_DIR/trusted-running.json" "$ADOC_RUN_DIR/trusted-phase-status.json"
jq -n '{status:"skipped",reason:"no_candidate_scope",
  schema_version:null,path:null,sha256:null}' \
  > "$ADOC_RUN_DIR/semantic-status.json"
jq -n '{status:"skipped",failure_code:null,assessment_sha256:null,
  primary:null,fallback:null}' > "$ADOC_RUN_DIR/semantic-execution-status.json"
ADOC_UNTRUSTED_CHANGE=true ADOC_TRUSTED_PHASE=true \
  ENFORCEMENT=advisory SCOPE=full SEMANTIC_REVIEW=true PROPOSE=false \
  PROPOSE_ON_ERROR=fail PROPOSE_DELIVERY=comment \
  "$ROOT/scripts/finalize.sh"
expect_code 2
jq -e '.trusted_phase.state == "failed"
  and .trusted_phase.reason_code == "trusted.semantic_result_invalid"' \
  "$(receipt)" >/dev/null
printf '%s\n' no_candidate_scope > "$ADOC_RUN_DIR/trusted-semantic-no-op"
ADOC_UNTRUSTED_CHANGE=true ADOC_TRUSTED_PHASE=true \
  ENFORCEMENT=advisory SCOPE=full SEMANTIC_REVIEW=true PROPOSE=false \
  PROPOSE_ON_ERROR=fail PROPOSE_DELIVERY=comment \
  "$ROOT/scripts/finalize.sh"
expect_code 0
jq -e '.semantic_review.status == "skipped"
  and .semantic_assessment.status == "skipped"
  and .trusted_phase.state == "completed"
  and .trusted_phase.context_digest == null
  and .trusted_phase.result_digest == null
  and .conclusion == {status:"success",reason_codes:[]}' \
  "$(receipt)" >/dev/null

jq '.reason = "no_textual_hunks"' "$ADOC_RUN_DIR/semantic-status.json" \
  > "$ADOC_RUN_DIR/semantic-status.next"
mv "$ADOC_RUN_DIR/semantic-status.next" "$ADOC_RUN_DIR/semantic-status.json"
printf '%s\n' no_textual_hunks > "$ADOC_RUN_DIR/trusted-semantic-no-op"
write_baseline true
ADOC_UNTRUSTED_CHANGE=true ADOC_TRUSTED_PHASE=true SYNC_POLICY=required \
  ENFORCEMENT=advisory SCOPE=full SEMANTIC_REVIEW=true PROPOSE=false \
  PROPOSE_ON_ERROR=fail PROPOSE_DELIVERY=comment \
  "$ROOT/scripts/finalize.sh"
expect_code 0
jq -e '.trusted_phase.state == "completed"
  and .conclusion == {status:"success",reason_codes:[]}' "$(receipt)" >/dev/null

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
