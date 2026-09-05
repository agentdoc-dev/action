#!/usr/bin/env bash
# Finalizes the Action-owned receipt and composite outputs. This is the only
# place that decides the final gate conclusion.
set -euo pipefail

OUT="${ADOC_RUN_DIR:-$RUNNER_TEMP}"
SELF="$(cd "$(dirname "$0")" && pwd)"
source "$SELF/state.sh"

emit_output() { printf '%s=%s\n' "$1" "$2" >> "$GITHUB_OUTPUT"; }
emit_output assessment-outcome not_evaluated
emit_output assessment-completeness error
emit_output assessment-invocation-id "$ADOC_INVOCATION_ID"
emit_output assessment-path ''
emit_output assessment-sha256 ''
emit_output assessment-receipt-path ''
emit_output assessment-receipt-sha256 ''
emit_output semantic-review-path ''
emit_output semantic-review-sha256 ''
emit_output semantic-assessment-status skipped
emit_output semantic-assessment-path ''
emit_output semantic-assessment-sha256 ''
emit_output semantic-context-path ''
emit_output semantic-context-sha256 ''
emit_output knowledge-graph-path ''
emit_output knowledge-graph-sha256 ''
emit_output baseline-status unavailable
emit_output baseline-path ''
emit_output baseline-sha256 ''
emit_output proposal-record-status skipped
emit_output proposal-record-path ''
emit_output proposal-record-sha256 ''

created_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
receipt="$ADOC_RETAINED_DIR/receipt-${ADOC_INVOCATION_ID}.json"
assessment_path="$(cat "$OUT/assessment-path" 2>/dev/null || true)"
assessment_sha="$(cat "$OUT/assessment-sha256" 2>/dev/null || true)"
baseline_path="$(cat "$OUT/baseline-path" 2>/dev/null || true)"
baseline_sha="$(cat "$OUT/baseline-sha256" 2>/dev/null || true)"
baseline_status=unavailable
if [ -f "$baseline_path" ] && [[ "$baseline_sha" =~ ^sha256:[0-9a-f]{64}$ ]] \
  && [ "sha256:$(sha256sum "$baseline_path" | awk '{print $1}')" = "$baseline_sha" ]; then
  if [ "$(jq -r '.readiness.ready' "$baseline_path")" = true ]; then
    baseline_status=ready
  else
    baseline_status=not_ready
  fi
fi

action_ref="${ADOC_ACTION_REF:-${GITHUB_ACTION_REF:-}}"
action_repository="${GITHUB_ACTION_REPOSITORY:-agentdoc-dev/action}"
if [[ "$action_ref" =~ ^[0-9a-f]{40}$ ]]; then
  action_requested_ref="$action_ref" action_resolved="$action_ref" action_provenance=full_sha
elif [ -n "$action_ref" ]; then
  action_requested_ref="$action_ref" action_resolved='' action_provenance=mutable_ref
else
  action_requested_ref='./' action_resolved='' action_provenance=local
fi
action_json="$(jq -cn --arg repository "$action_repository" --arg requested "$action_requested_ref" \
  --arg resolved "$action_resolved" --arg provenance "$action_provenance" \
  '{repository:$repository,requested_ref:$requested,resolved_commit:(if $resolved == "" then null else $resolved end),provenance:$provenance}')"

workload_identity_json="$(jq -cn \
  --arg server_url "${GITHUB_SERVER_URL:-}" \
  --arg repository_id "${GITHUB_REPOSITORY_ID:-}" \
  --arg workflow_ref "${GITHUB_WORKFLOW_REF:-}" \
  --arg workflow_sha "${GITHUB_WORKFLOW_SHA:-}" \
  --arg actor_id "${GITHUB_ACTOR_ID:-}" \
  --arg triggering_actor "${GITHUB_TRIGGERING_ACTOR:-}" '
  {provider:"github_actions",
   server_url:(if ($server_url | test("^https://\\S+$")) then $server_url else null end),
   repository_id:(if ($repository_id | test("^[1-9][0-9]*$")) then $repository_id else null end),
   workflow_ref:(if $workflow_ref == "" then null else $workflow_ref end),
   workflow_sha:(if ($workflow_sha | test("^[0-9a-f]{40}$")) then $workflow_sha else null end),
   actor_id:(if ($actor_id | test("^[1-9][0-9]*$")) then $actor_id else null end),
   triggering_actor:(if $triggering_actor == "" then null else $triggering_actor end)}')"

ci_json="$(jq -cn \
  --arg repository "${GITHUB_REPOSITORY:-}" --arg pr "${ADOC_PR_NUMBER:-}" \
  --arg run_id "${GITHUB_RUN_ID:-}" --arg attempt "${GITHUB_RUN_ATTEMPT:-1}" \
  --arg job "${GITHUB_JOB:-}" --arg invocation "$ADOC_INVOCATION_ID" \
  --arg actor "${GITHUB_ACTOR:-}" --argjson workload_identity "$workload_identity_json" '
  {provider:"github",repository:(if ($repository | test("^[^/\\s]+/[^/\\s]+$")) then $repository else null end),
   pull_request:(if ($pr|test("^[0-9]+$")) then ($pr|tonumber) else null end),
   run_id:(if ($run_id | test("^[1-9][0-9]*$")) then $run_id else null end),
   run_attempt:(if ($attempt | test("^[1-9][0-9]*$")) then ($attempt|tonumber) else null end),
   job:(if $job == "" then null else $job end),invocation_id:$invocation,
   actor:(if $actor == "" then null else $actor end),workload_identity:$workload_identity}')"

revision_json="$(jq -cn --arg base "${ADOC_REQUESTED_BASE:-}" \
  --arg comparison "${ADOC_COMPARISON_BASE:-}" --arg head "${ADOC_HEAD:-}" '
  {requested_base:(if $base == "" then null else $base end),
   comparison_base:(if $comparison == "" then null else $comparison end),
   head:(if $head == "" then null else $head end)}')"

proposal_json="$(jq -cn --arg enabled "${PROPOSE:-false}" '
  if $enabled == "true" then {status:"skipped",count:0,sha256:null,reason:"no_candidate_scope"}
  else {status:"disabled",count:0,sha256:null,reason:"input_disabled"} end')"
if [ -s "$OUT/proposal-status.json" ]; then
  if jq -e '
    type == "object"
    and keys == ["count","reason","sha256","status"]
    and (.status | IN("disabled","skipped","partial","complete","error"))
    and (.count | type == "number" and floor == . and . >= 0)
    and (.reason | type == "string" and length > 0)
    and (if .status == "complete" then
      .count > 0 and (.sha256 | test("^sha256:[0-9a-f]{64}$"))
    elif .status == "partial" then
      .sha256 == null or (.sha256 | test("^sha256:[0-9a-f]{64}$"))
    else .sha256 == null end)
  ' "$OUT/proposal-status.json" >/dev/null 2>&1; then
    proposal_json="$(cat "$OUT/proposal-status.json")"
  else
    proposal_json='{"status":"error","count":0,"sha256":null,"reason":"proposal_contract_failed"}'
    echo 1 > "$OUT/adoc-propose-code"
  fi
fi
record_status=skipped record_path='' record_sha=''
if [ -s "$OUT/proposal-record-status.json" ]; then
  expected_record="$ADOC_RETAINED_DIR/proposal-record-${ADOC_INVOCATION_ID}.json"
  if jq -e --arg path "$expected_record" '
    type == "object"
    and keys == ["path","reason","sha256","status"]
    and (.status | IN("skipped","complete","error"))
    and (.reason | type == "string" and length > 0)
    and (if .status == "complete" then
      .reason == "validated" and .path == $path
      and (.sha256 | test("^sha256:[0-9a-f]{64}$"))
    else
      .path == null and .sha256 == null
      and (.status == "error" or (.reason | IN(
        "no_valid_proposals","adoc_command_unavailable",
        "semantic_receipt_unavailable","change_request_unavailable",
        "non_reviewable_status","untrusted_pr","no_textual_hunks",
        "credentials_unavailable","no_candidate_scope")))
    end)
  ' "$OUT/proposal-record-status.json" >/dev/null 2>&1; then
    record_status="$(jq -r .status "$OUT/proposal-record-status.json")"
    if [ "$record_status" = complete ]; then
      record_path="$expected_record"
      record_sha="$(jq -r .sha256 "$OUT/proposal-record-status.json")"
      if [ ! -f "$record_path" ] || [ "sha256:$(sha256sum "$record_path" \
        | awk '{print $1}')" != "$record_sha" ]; then
        record_status=error record_path='' record_sha=''
      fi
    fi
  else
    record_status=error
  fi
  [ "$record_status" != error ] || echo 1 > "$OUT/adoc-propose-code"
fi
semantic_json="$(jq -cn --arg enabled "${SEMANTIC_REVIEW:-false}" '
  if $enabled == "true" then {status:"skipped",schema_version:null,sha256:null}
  else {status:"disabled",schema_version:null,sha256:null} end')"
semantic_path=''
semantic_sha=''
if [ -s "$OUT/semantic-status.json" ] && jq -e '
  type == "object"
  and (.status | IN("disabled","skipped","partial","complete","error"))
  and (if .status == "complete" then
    .schema_version == "adoc.semantic_review.v0"
    and (.path | type == "string")
    and (.sha256 | test("^sha256:[0-9a-f]{64}$"))
  else .schema_version == null and .sha256 == null end)
' "$OUT/semantic-status.json" >/dev/null 2>&1; then
  semantic_status="$(jq -r .status "$OUT/semantic-status.json")"
  if [ "$semantic_status" = complete ]; then
    semantic_path="$(jq -r .path "$OUT/semantic-status.json")"
    semantic_sha="$(jq -r .sha256 "$OUT/semantic-status.json")"
    expected_semantic="$ADOC_RETAINED_DIR/semantic-${ADOC_INVOCATION_ID}.json"
    actual_semantic="sha256:$(sha256sum "$semantic_path" 2>/dev/null | awk '{print $1}')"
    if [ "$semantic_path" = "$expected_semantic" ] && [ -f "$semantic_path" ] \
      && [ "$actual_semantic" = "$semantic_sha" ]; then
      semantic_json="$(jq -cn --arg sha "$semantic_sha" \
        '{status:"complete",schema_version:"adoc.semantic_review.v0",sha256:$sha}')"
    else
      semantic_path='' semantic_sha=''
      semantic_json='{"status":"error","schema_version":null,"sha256":null}'
      echo 1 > "$OUT/adoc-semantic-code"
    fi
  else
    semantic_json="$(jq -cn --arg status "$semantic_status" \
      '{status:$status,schema_version:null,sha256:null}')"
  fi
elif [ -s "$OUT/semantic-status.json" ]; then
  semantic_json='{"status":"error","schema_version":null,"sha256":null}'
  echo 1 > "$OUT/adoc-semantic-code"
fi
semantic_assessment_json="$(jq -cn --arg requested \
  "$([ "${SEMANTIC_REVIEW:-false}" = true ] && echo true || echo false)" '
  if $requested == "true" then {
    status:"failed",failure_code:"action.semantic_review_failed",
    assessment_sha256:null,primary:null,fallback:null
  } else {
    status:"skipped",failure_code:null,
    assessment_sha256:null,primary:null,fallback:null
  } end')"
semantic_assessment_path='' semantic_assessment_sha=''
semantic_context_path='' semantic_context_sha=''
knowledge_graph_path='' knowledge_graph_sha=''
execution_status="$OUT/semantic-execution-status.json"
if [ -s "$execution_status" ] \
  && jq -e -f "$SELF/semantic-status.jq" "$execution_status" >/dev/null 2>&1; then
  semantic_assessment_json="$(cat "$execution_status")"
  semantic_outcome="$(jq -r .status "$execution_status")"
  if [ "$semantic_outcome" = completed ] || [ "$semantic_outcome" = fell_back ]; then
    semantic_assessment_path="$ADOC_RETAINED_DIR/semantic-assessment-${ADOC_INVOCATION_ID}.json"
    semantic_executor_path="$ADOC_RETAINED_DIR/semantic-executor-${ADOC_INVOCATION_ID}.json"
    semantic_context_path="$ADOC_RETAINED_DIR/semantic-context-${ADOC_INVOCATION_ID}.json"
    knowledge_graph_path="$ADOC_RETAINED_DIR/knowledge-graph-${ADOC_INVOCATION_ID}.json"
    semantic_assessment_sha="$(jq -r .assessment_sha256 "$execution_status")"
    winning_identity="$(jq -c \
      'if .status == "fell_back" then .fallback else .primary end' \
      "$execution_status")"
    actual_assessment_sha=''
    semantic_context_digest=''
    if [ -f "$semantic_assessment_path" ]; then
      actual_assessment_sha="sha256:$(sha256sum "$semantic_assessment_path" \
        | awk '{print $1}')"
    fi
    if [ -f "$semantic_context_path" ]; then
      semantic_context_sha="sha256:$(sha256sum "$semantic_context_path" | awk '{print $1}')"
      semantic_context_digest="$(jq -r '.context_digest // empty' \
        "$semantic_context_path" 2>/dev/null || true)"
    fi
    if [ -f "$knowledge_graph_path" ]; then
      knowledge_graph_sha="sha256:$(sha256sum "$knowledge_graph_path" | awk '{print $1}')"
    fi
    semantic_binding_invalid=false
    if [ ! -f "$semantic_assessment_path" ] \
      || [ "$actual_assessment_sha" != "$semantic_assessment_sha" ] \
      || [ ! -f "$semantic_context_path" ] \
      || ! jq -e --arg digest "$semantic_context_digest" '
        .schema_version == "adoc.semantic_assessment.v0"
        and .context_digest == $digest
      ' "$semantic_assessment_path" >/dev/null 2>&1 \
      || ! jq -e --arg digest "$semantic_context_digest" \
        --arg assessment "$assessment_sha" \
        --arg head "${ADOC_HEAD:-}" '
        .schema_version == "adoc.semantic_context.v0"
        and .context_digest == $digest
        and .subject_revision == {system:"git",value:$head}
        and .basis.assessment_digest == $assessment
      ' "$semantic_context_path" >/dev/null 2>&1 \
      || ! jq -e --arg digest "$semantic_assessment_sha" \
        --arg context "$semantic_context_digest" --argjson winner "$winning_identity" '
          .schema_version == "adoc.semantic_executor_receipt.v0"
          and .outcome == "completed" and .assessment_digest == $digest
          and .context_digest == $context
          and .request_id == $winner.request_id
          and .adapter.provider == $winner.provider
          and .adapter.model == $winner.model
        ' "$semantic_executor_path" >/dev/null 2>&1; then
      semantic_binding_invalid=true
    elif [ ! -f "$knowledge_graph_path" ]; then
      semantic_assessment_path='' semantic_assessment_sha=''
      semantic_context_path='' semantic_context_sha=''
      knowledge_graph_path='' knowledge_graph_sha=''
    else
      knowledge_graph_version="$(jq -r \
        '.knowledge_snapshot.graph_schema_version // empty' \
        "$assessment_path" 2>/dev/null)"
      if ! jq -e --arg version "$knowledge_graph_version" '
          .schema_version == $version
          and ($version == "adoc.graph.v5" or $version == "adoc.graph.v6")
        ' "$knowledge_graph_path" >/dev/null 2>&1 \
        || [ "$knowledge_graph_sha" != "$(jq -r '.knowledge_snapshot.graph_sha256 // empty' "$assessment_path" 2>/dev/null)" ] \
        || ! jq -e --arg graph "$knowledge_graph_sha" '
          .basis.knowledge_basis == {kind:"graph_artifact",digest:$graph}
        ' "$semantic_context_path" >/dev/null 2>&1; then
        semantic_binding_invalid=true
      elif [ "$knowledge_graph_version" != adoc.graph.v6 ]; then
        semantic_assessment_path='' semantic_assessment_sha=''
        semantic_context_path='' semantic_context_sha=''
        knowledge_graph_path='' knowledge_graph_sha=''
      fi
    fi
    if [ "$semantic_binding_invalid" = true ]; then
      semantic_assessment_json='{"status":"failed","failure_code":"action.semantic_review_failed","assessment_sha256":null,"primary":null,"fallback":null}'
      semantic_assessment_path='' semantic_assessment_sha=''
      semantic_context_path='' semantic_context_sha=''
      knowledge_graph_path='' knowledge_graph_sha=''
      echo 1 > "$OUT/adoc-semantic-code"
    fi
  elif [ "$semantic_outcome" = failed ]; then
    echo 1 > "$OUT/adoc-semantic-code"
  fi
elif [ -s "$execution_status" ]; then
  semantic_assessment_json='{"status":"failed","failure_code":"action.semantic_review_failed","assessment_sha256":null,"primary":null,"fallback":null}'
  echo 1 > "$OUT/adoc-semantic-code"
elif [ "${SEMANTIC_REVIEW:-false}" = true ]; then
  echo 1 > "$OUT/adoc-semantic-code"
fi
delivery_json="$(jq -cn --arg assessed "${ADOC_HEAD:-}" '{
  status:"skipped",mode:"comment",reason:"comment_only",
  reason_code:null,remediation:null,
  assessed_head:(if $assessed == "" then null else $assessed end),
  delivery_commit:null,branch:null,url:null
}')"
if [ -s "$OUT/delivery-status.json" ]; then
  if jq -e '
    type == "object"
    and keys == ["assessed_head","branch","delivery_commit","mode","reason","reason_code","remediation","status","url"]
    and (.status | IN("skipped","complete","error"))
    and (.mode | IN("comment","commit","pr"))
    and (.assessed_head | test("^[0-9a-f]{40}$"))
    and (.delivery_commit == null or (.delivery_commit | test("^[0-9a-f]{40}$")))
    and (.branch == null or (.branch | type == "string" and length > 0))
    and (.url == null or (.url | type == "string" and startswith("https://")))
    and (.remediation == null or (.remediation | type == "string" and length > 0))
    and if .status == "complete" then
      .reason == null and .reason_code == null and .remediation == null
      and .delivery_commit != null and .branch != null
      and if .mode == "commit" then .url == null
          elif .mode == "pr" then .url != null
          else false end
    else
      (.reason | IN(
        "comment_only","no_valid_proposals","untrusted_pr","already_delivered",
        "pr_query_failed","stale_head","persisted_checkout_credentials",
        "manifest_contract_failed","patch_revalidation_failed",
        "delivery_check_failed","delivery_build_failed",
        "unexpected_source_changes","commit_failed","push_rejected",
        "proposal_record_failed",
        "proposal_branch_unowned","proposal_branch_diverged",
        "proposal_pr_closed","lease_rejected","pr_creation_not_permitted",
        "pr_update_failed","proposal_branch_recovery_failed",
        "delivery_contract_failed","fork_branch_read_only"))
      and if .reason == "fork_branch_read_only" then
        .status == "skipped" and .mode == "commit"
        and .reason_code == "delivery.fork_branch_read_only"
        and .remediation != null
      else .reason_code == null and .remediation == null end
    end
  ' "$OUT/delivery-status.json" >/dev/null 2>&1; then
    delivery_json="$(cat "$OUT/delivery-status.json")"
  else
    delivery_json="$(jq -cn --arg assessed "${ADOC_HEAD:-}" '{
      status:"error",mode:"comment",reason:"delivery_contract_failed",
      reason_code:null,remediation:null,
      assessed_head:(if $assessed == "" then null else $assessed end),
      delivery_commit:null,branch:null,url:null
    }')"
  fi
fi
if [ "${CLOUD_SYNC_REQUESTED:-false}" = true ] && [ -f "$assessment_path" ]; then
  cloud_sync_json='{"status":"failed","reason":"status_contract_failed","reason_code":"action.cloud_sync_failed","result_digest":null,"remediation":"Rerun the Cloud hand-off with a current work request."}'
elif [ "${CLOUD_SYNC_REQUESTED:-false}" = true ]; then
  cloud_sync_json='{"status":"skipped","reason":"local_assessment_unavailable","reason_code":null,"result_digest":null,"remediation":"Establish a valid local assessment before Cloud hand-off."}'
else
  cloud_sync_json='{"status":"skipped","reason":"not_requested","reason_code":null,"result_digest":null,"remediation":null}'
fi
if [ -s "$OUT/cloud-sync-status.json" ] && jq -e '
  type == "object"
  and keys == ["reason","reason_code","remediation","result_digest","status"]
  and (.status | IN("skipped","completed","failed"))
  and (.reason | IN(
    "not_requested","untrusted_change","local_assessment_unavailable","uploaded",
    "request_unavailable","invalid_upload_url","invalid_upload_credential",
    "credential_reuse","unsupported_version","invalid_request",
    "request_digest_mismatch","request_binding_mismatch","completion_nonce_reused",
    "local_output_mismatch","upload_failed","stale_head","status_contract_failed"))
  and (.remediation == null or (.remediation | type == "string" and length > 0))
  and (.result_digest == null or (.result_digest | test("^sha256:[0-9a-f]{64}$")))
  and if .status == "completed" then
    .reason == "uploaded" and .reason_code == null and .result_digest != null
    and .remediation == null
  elif .status == "failed" then .reason_code == "action.cloud_sync_failed"
  else .reason_code == null and .result_digest == null end
' "$OUT/cloud-sync-status.json" >/dev/null 2>&1; then
  cloud_sync_json="$(cat "$OUT/cloud-sync-status.json")"
fi
trusted_phase_json='{"state":"not_required","reason_code":null,"remediation":null,"head_revision":null,"request_digest":null,"authorizer":null,"policy":null,"workload":null,"executor":null,"context_request_digest":null,"context_digest":null,"result_digest":null,"workflow":null}'
if [ "${ADOC_UNTRUSTED_CHANGE:-false}" = true ]; then
  trusted_status="$OUT/trusted-phase-status.json"
  if [ -s "$trusted_status" ] && jq -e '
    type == "object"
    and (.state | IN("awaiting_authorization","authorized","running","completed","denied","failed","expired_after_head_change"))
    and (.reason_code == null or (.reason_code | type == "string" and length > 0))
    and (.remediation == null or (.remediation | type == "string" and length > 0))
    and (.head_revision == null or (.head_revision | test("^[0-9a-f]{40}$")))
    and (.request_digest == null or (.request_digest | test("^sha256:[0-9a-f]{64}$")))
    and (.context_request_digest == null or (.context_request_digest | test("^sha256:[0-9a-f]{64}$")))
    and (.context_digest == null or (.context_digest | test("^sha256:[0-9a-f]{64}$")))
    and (.result_digest == null or (.result_digest | test("^sha256:[0-9a-f]{64}$")))
  ' "$trusted_status" >/dev/null 2>&1; then
    trusted_phase_json="$(cat "$trusted_status")"
  else
    trusted_phase_json='{"state":"failed","reason_code":"trusted.status_invalid","remediation":"Rerun the protected trusted workflow.","head_revision":null,"request_digest":null,"authorizer":null,"policy":null,"workload":null,"executor":null,"context_request_digest":null,"context_digest":null,"result_digest":null,"workflow":null}'
  fi
fi
if [ "${ADOC_TRUSTED_PHASE:-false}" = true ] \
  && [ "$(jq -r .state <<< "$trusted_phase_json")" = running ]; then
  trusted_executor_receipt="$ADOC_RETAINED_DIR/semantic-executor-${ADOC_INVOCATION_ID}.json"
  semantic_reason="$(jq -r '.reason // empty' "$OUT/semantic-status.json" 2>/dev/null || true)"
  semantic_no_op="$(cat "$OUT/trusted-semantic-no-op" 2>/dev/null || true)"
  if [ "${SEMANTIC_REVIEW:-false}" != true ] && [ "${PROPOSE:-false}" != true ] \
    && [ "$(jq -r .status <<< "$semantic_json")" = disabled ] \
    && [ "$(jq -r .status <<< "$semantic_assessment_json")" = skipped ] \
    && [ "$(jq -r .status <<< "$proposal_json")" = disabled ]; then
    trusted_phase_json="$(jq '
      .state = "completed" | .reason_code = null | .remediation = null
      | .context_digest = null | .result_digest = null
    ' <<< "$trusted_phase_json")"
  elif [ "$(jq -r .status <<< "$semantic_json")" = skipped ] \
    && [ "$(jq -r .status <<< "$semantic_assessment_json")" = skipped ] \
    && [ "$semantic_no_op" = "$semantic_reason" ] \
    && { [ "$semantic_reason" = no_candidate_scope ] \
      || [ "$semantic_reason" = no_textual_hunks ]; }; then
    trusted_phase_json="$(jq '
      .state = "completed" | .reason_code = null | .remediation = null
      | .context_digest = null | .result_digest = null
    ' <<< "$trusted_phase_json")"
  elif { [ "$(jq -r .status <<< "$semantic_assessment_json")" = completed ] \
      || [ "$(jq -r .status <<< "$semantic_assessment_json")" = fell_back ]; } \
    && jq -e --argjson authorized "$(jq -c .executor <<< "$trusted_phase_json")" '
      .outcome == "completed"
      and .adapter.provider == $authorized.provider
      and .adapter.model == $authorized.model
      and .adapter.config_digest == $authorized.config_digest
      and (.context_digest | test("^sha256:[0-9a-f]{64}$"))
    ' "$trusted_executor_receipt" >/dev/null 2>&1; then
    trusted_phase_json="$(jq \
      --arg context "$(jq -r .context_digest "$trusted_executor_receipt")" \
      --arg result "$(jq -r .assessment_sha256 <<< "$semantic_assessment_json")" '
        .state = "completed" | .reason_code = null | .remediation = null
        | .context_digest = $context | .result_digest = $result
      ' <<< "$trusted_phase_json")"
  else
    trusted_phase_json="$(jq '
      .state = "failed" | .reason_code = "trusted.semantic_result_invalid"
      | .remediation = "Re-authorize an eligible executor and rerun the current head."
      | .context_digest = null | .result_digest = null
    ' <<< "$trusted_phase_json")"
  fi
fi
case "$(jq -r .status <<< "$proposal_json")" in
  error) adoc_set_stage proposal error ;;
  disabled | skipped) adoc_set_stage proposal skipped ;;
  *) adoc_set_stage proposal complete ;;
esac
case "$(jq -r .status <<< "$semantic_json")" in
  error) adoc_set_stage semantic_review error ;;
  complete) adoc_set_stage semantic_review complete ;;
  *) adoc_set_stage semantic_review skipped ;;
esac
case "$(jq -r .status <<< "$delivery_json")" in
  error) adoc_set_stage delivery error ;;
  complete) adoc_set_stage delivery complete ;;
  *) adoc_set_stage delivery skipped ;;
esac
case "$(jq -r .status <<< "$cloud_sync_json")" in
  failed) adoc_set_stage cloud_sync error ;;
  completed) adoc_set_stage cloud_sync complete ;;
  *) adoc_set_stage cloud_sync skipped ;;
esac

if [ -f "$assessment_path" ] && [ -n "$assessment_sha" ]; then
  completeness="$(jq -r .completeness "$assessment_path")"
  outcome="$(jq -r .outcome "$assessment_path")"
  final_status=success
  reasons='[]'
  add_reason() {
    final_status=failure
    reasons="$(jq -cn --argjson values "$reasons" --arg value "$1" '$values + [$value] | unique')"
  }
  case "$completeness/$outcome" in
    partial/not_evaluated) add_reason action.assessment_partial ;;
    error/not_evaluated) add_reason action.assessment_not_evaluated ;;
    error/invalid)
      if [ "${ENFORCEMENT:-advisory}" = strict ]; then
        if [ "${SCOPE:-full}" = full ] && [ "$(jq -r '.validation.errors_full' "$assessment_path")" -gt 0 ]; then
          add_reason action.structural_errors_full
        elif [ "${SCOPE:-full}" = diff ] \
          && [ "$(jq '[.validation.errors_changed,.validation.errors_unattributed] | add' "$assessment_path")" -gt 0 ]; then
          add_reason action.structural_errors_changed
        fi
      fi
      ;;
  esac
  [ ! -s "$OUT/path-limit-reason" ] || add_reason action.path_limit_exceeded
  propose_code="$(cat "$OUT/adoc-propose-code" 2>/dev/null || echo 0)"
  if [ "${PROPOSE_ON_ERROR:-warn}" = fail ] && [ "$propose_code" != 0 ]; then
    add_reason action.proposal_failed
  fi
  semantic_code="$(cat "$OUT/adoc-semantic-code" 2>/dev/null || echo 0)"
  if [ "${PROPOSE_ON_ERROR:-warn}" = fail ] && [ "$semantic_code" != 0 ]; then
    add_reason action.semantic_review_failed
  fi
  if [ "${SYNC_POLICY:-advisory}" = required ]; then
    case "$baseline_status" in
      unavailable) add_reason action.baseline_unavailable ;;
      not_ready) add_reason action.baseline_not_ready ;;
    esac
    semantic_status="$(jq -r '.status' <<< "$semantic_json")"
    semantic_reason="$(jq -r '.reason // empty' "$OUT/semantic-status.json" 2>/dev/null || true)"
    proposal_status="$(jq -r '.status' <<< "$proposal_json")"
    delivery_status="$(jq -r '.status' <<< "$delivery_json")"
    [ "$semantic_status" = complete ] \
      || { [ "$semantic_status" = skipped ] \
        && { [ "$semantic_reason" = no_candidate_scope ] \
          || [ "$semantic_reason" = no_textual_hunks ]; }; } \
      || add_reason action.knowledge_review_incomplete
    case "$proposal_status" in
      error | partial) add_reason action.knowledge_proposal_incomplete ;;
      complete)
        if [ "$delivery_status" = complete ]; then
          add_reason action.knowledge_sync_pending
        else
          add_reason action.knowledge_delivery_failed
        fi
        ;;
    esac
  fi
  if [ "${ADOC_TRUSTED_PHASE:-false}" = true ] \
    && [ "$(jq -r .state <<< "$trusted_phase_json")" != completed ]; then
    add_reason action.semantic_review_failed
  fi

  toolchain="$(cat "$OUT/adoc-toolchain.json")"
  knowledge_snapshot="$(jq 'if .knowledge_snapshot.status == "available" then
      .knowledge_snapshot | {graph_schema_version,graph_sha256,object_set_sha256}
    else null end' "$assessment_path")"
  jq -n \
    --arg created "$created_at" --arg date "$ADOC_EVALUATION_DATE" \
    --arg assessment_sha "$assessment_sha" --arg completeness "$completeness" --arg outcome "$outcome" \
    --arg status "$final_status" --arg enforcement "${ENFORCEMENT:-advisory}" \
    --arg scope "${SCOPE:-full}" --arg semantic_review "${SEMANTIC_REVIEW:-false}" \
    --arg sync_policy "${SYNC_POLICY:-advisory}" \
    --arg propose "${PROPOSE:-false}" \
    --arg propose_on_error "${PROPOSE_ON_ERROR:-warn}" --arg propose_delivery "${PROPOSE_DELIVERY:-comment}" \
    --argjson ci "$ci_json" --argjson revisions "$revision_json" --argjson action "$action_json" \
    --argjson adoc "$toolchain" --argjson snapshot "$knowledge_snapshot" \
    --arg baseline_status "$baseline_status" --arg baseline_sha "$baseline_sha" \
    --argjson reasons "$reasons" --argjson semantic "$semantic_json" \
    --argjson semantic_assessment "$semantic_assessment_json" \
    --argjson proposal "$proposal_json" --argjson delivery "$delivery_json" \
    --argjson cloud_sync "$cloud_sync_json" --argjson trusted_phase "$trusted_phase_json" '
    {schema_version:"adoc.pr_assessment_receipt.v4",run_status:"completed",created_at:$created,
     ci:$ci,revisions:$revisions,evaluation_date:$date,toolchain:{action:$action,adoc:$adoc},
     assessment:{schema_version:"adoc.change_assessment.v0",sha256:$assessment_sha,
       completeness:$completeness,outcome:$outcome},knowledge_snapshot:$snapshot,
     repository_baseline:{status:$baseline_status,
       schema_version:(if $baseline_status == "unavailable" then null else "adoc.repository_baseline.v0" end),
       sha256:(if $baseline_status == "unavailable" then null else $baseline_sha end)},
     policy:{structural_policy_revision:"adoc-action-structural.v0",
       knowledge_policy_revision:(if $sync_policy == "required" then "adoc-action-sync.v0" else null end),
       enforcement:$enforcement,scope:$scope,knowledge_enforcement:$sync_policy,
       semantic_review:($semantic_review == "true"),
       propose:($propose == "true"),propose_on_error:$propose_on_error,propose_delivery:$propose_delivery},
     conclusion:{status:$status,reason_codes:$reasons},
     knowledge_gate:{
       status:(if $sync_policy == "required" then "evaluated" else "not_applicable" end),
       mode:$sync_policy,
       policy_revision:(if $sync_policy == "required" then "adoc-action-sync.v0" else null end),
       conclusion:(if $sync_policy == "required" then
         if any($reasons[]; test("^action\\.(baseline|knowledge)_")) then "failure" else "success" end
       else "advisory" end),
       reason_codes:[$reasons[] | select(test("^action\\.(baseline|knowledge)_"))]},
     semantic_review:$semantic,semantic_assessment:$semantic_assessment,
     proposals:$proposal,delivery:$delivery,cloud_sync:$cloud_sync,
     trusted_phase:$trusted_phase}' > "$receipt.tmp"
  final_code=0
  [ "$final_status" = success ] || final_code=2
else
  if [ ! -s "$OUT/failure.json" ]; then
    adoc_fail finalize action.receipt_failed 'No valid assessment state was available for receipt finalization.' \
      'Rerun the workflow and inspect the first failing AgentDoc stage.'
  fi
  failure="$(cat "$OUT/failure.json")"
  jq -n --arg created "$created_at" --argjson ci "$ci_json" --argjson revisions "$revision_json" \
    --argjson failure "$failure" --argjson cloud_sync "$cloud_sync_json" \
    --argjson trusted_phase "$trusted_phase_json" '
    {schema_version:"adoc.pr_assessment_receipt.v4",run_status:"failed",created_at:$created,
     ci:$ci,revisions:$revisions,toolchain:{},assessment:null,knowledge_snapshot:null,failure:$failure,
     knowledge_gate:{status:"skipped"},semantic_review:{status:"skipped"},
     semantic_assessment:{status:"skipped",failure_code:null,assessment_sha256:null,primary:null,fallback:null},
     proposals:{status:"skipped"},delivery:{status:"skipped"},cloud_sync:$cloud_sync,
     trusted_phase:$trusted_phase}' > "$receipt.tmp"
  completeness=error outcome=not_evaluated final_code=2
fi

jq -e '
  .schema_version == "adoc.pr_assessment_receipt.v4"
  and (.run_status | IN("completed","failed"))
  and (if .run_status == "completed" then
    .assessment.schema_version == "adoc.change_assessment.v0" and (.failure | not)
  else .assessment == null and .knowledge_snapshot == null and (.failure.code | type == "string") end)' \
  "$receipt.tmp" >/dev/null
mv "$receipt.tmp" "$receipt"
receipt_sha="sha256:$(sha256sum "$receipt" | awk '{print $1}')"
printf '%s\n' "$receipt_sha" > "$OUT/receipt-sha256"
printf '%s\n' "$final_code" > "$OUT/adoc-final-code"
adoc_set_stage finalize complete

emit_output assessment-outcome "$outcome"
emit_output assessment-completeness "$completeness"
emit_output semantic-assessment-status "$(jq -r .semantic_assessment.status "$receipt")"
if [ -n "$semantic_assessment_path" ] && [ -n "$semantic_context_path" ] \
  && [ -n "$knowledge_graph_path" ]; then
  emit_output semantic-assessment-path "$semantic_assessment_path"
  emit_output semantic-assessment-sha256 "$semantic_assessment_sha"
  emit_output semantic-context-path "$semantic_context_path"
  emit_output semantic-context-sha256 "$semantic_context_sha"
  emit_output knowledge-graph-path "$knowledge_graph_path"
  emit_output knowledge-graph-sha256 "$knowledge_graph_sha"
fi
if [ -f "$assessment_path" ]; then
  emit_output assessment-path "$assessment_path"
  emit_output assessment-sha256 "$assessment_sha"
fi
if [ -n "$semantic_path" ] && [ -n "$semantic_sha" ]; then
  emit_output semantic-review-path "$semantic_path"
  emit_output semantic-review-sha256 "$semantic_sha"
fi
emit_output baseline-status "$baseline_status"
if [ "$baseline_status" != unavailable ]; then
  emit_output baseline-path "$baseline_path"
  emit_output baseline-sha256 "$baseline_sha"
fi
emit_output proposal-record-status "$record_status"
if [ "$record_status" = complete ]; then
  emit_output proposal-record-path "$record_path"
  emit_output proposal-record-sha256 "$record_sha"
fi
emit_output assessment-receipt-path "$receipt"
emit_output assessment-receipt-sha256 "$receipt_sha"
exit 0
