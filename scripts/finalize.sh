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

created_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
receipt="$ADOC_RETAINED_DIR/receipt-${ADOC_INVOCATION_ID}.json"
assessment_path="$(cat "$OUT/assessment-path" 2>/dev/null || true)"
assessment_sha="$(cat "$OUT/assessment-sha256" 2>/dev/null || true)"

action_ref="${GITHUB_ACTION_REF:-}"
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

ci_json="$(jq -cn \
  --arg repository "${GITHUB_REPOSITORY:-}" --arg pr "${ADOC_PR_NUMBER:-}" \
  --arg run_id "${GITHUB_RUN_ID:-}" --arg attempt "${GITHUB_RUN_ATTEMPT:-1}" \
  --arg job "${GITHUB_JOB:-}" --arg invocation "$ADOC_INVOCATION_ID" \
  --arg actor "${GITHUB_ACTOR:-}" '
  {provider:"github",repository:(if $repository == "" then null else $repository end),
   pull_request:(if ($pr|test("^[0-9]+$")) then ($pr|tonumber) else null end),
   run_id:$run_id,run_attempt:($attempt|tonumber),job:$job,invocation_id:$invocation,
   actor:(if $actor == "" then null else $actor end)}')"

revision_json="$(jq -cn --arg base "${ADOC_REQUESTED_BASE:-}" \
  --arg comparison "${ADOC_COMPARISON_BASE:-}" --arg head "${ADOC_HEAD:-}" '
  {requested_base:(if $base == "" then null else $base end),
   comparison_base:(if $comparison == "" then null else $comparison end),
   head:(if $head == "" then null else $head end)}')"

proposal_json="$(jq -cn --arg enabled "${PROPOSE:-false}" '
  if $enabled == "true" then {status:"skipped",count:0,sha256:null,reason:"no_candidate_scope"}
  else {status:"disabled",count:0,sha256:null,reason:"input_disabled"} end')"
if [ -s "$OUT/proposal-status.json" ]; then proposal_json="$(cat "$OUT/proposal-status.json")"; fi
delivery_json='{"status":"skipped","mode":"comment","reason":"comment_only","delivery_commit":null,"url":null}'
if [ -s "$OUT/delivery-status.json" ]; then delivery_json="$(cat "$OUT/delivery-status.json")"; fi

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

  toolchain="$(cat "$OUT/adoc-toolchain.json")"
  knowledge_snapshot="$(jq 'if .knowledge_snapshot.status == "available" then
      .knowledge_snapshot | {graph_schema_version,graph_sha256,object_set_sha256}
    else null end' "$assessment_path")"
  jq -n \
    --arg created "$created_at" --arg date "$ADOC_EVALUATION_DATE" \
    --arg assessment_sha "$assessment_sha" --arg completeness "$completeness" --arg outcome "$outcome" \
    --arg status "$final_status" --arg enforcement "${ENFORCEMENT:-advisory}" \
    --arg scope "${SCOPE:-full}" --arg propose "${PROPOSE:-false}" \
    --arg propose_on_error "${PROPOSE_ON_ERROR:-warn}" --arg propose_delivery "${PROPOSE_DELIVERY:-comment}" \
    --argjson ci "$ci_json" --argjson revisions "$revision_json" --argjson action "$action_json" \
    --argjson adoc "$toolchain" --argjson snapshot "$knowledge_snapshot" \
    --argjson reasons "$reasons" --argjson proposal "$proposal_json" --argjson delivery "$delivery_json" '
    {schema_version:"adoc.pr_assessment_receipt.v0",run_status:"completed",created_at:$created,
     ci:$ci,revisions:$revisions,evaluation_date:$date,toolchain:{action:$action,adoc:$adoc},
     assessment:{schema_version:"adoc.change_assessment.v0",sha256:$assessment_sha,
       completeness:$completeness,outcome:$outcome},knowledge_snapshot:$snapshot,
     policy:{structural_policy_revision:"adoc-action-structural.v0",knowledge_policy_revision:null,
       enforcement:$enforcement,scope:$scope,knowledge_enforcement:"advisory",semantic_review:false,
       propose:($propose == "true"),propose_on_error:$propose_on_error,propose_delivery:$propose_delivery},
     conclusion:{status:$status,reason_codes:$reasons},
     knowledge_gate:{status:"not_applicable",mode:"advisory",policy_revision:null,conclusion:"advisory",reason_codes:[]},
     semantic_review:{status:"disabled",schema_version:null,sha256:null},
     proposals:$proposal,delivery:$delivery}' > "$receipt.tmp"
  final_code=0
  [ "$final_status" = success ] || final_code=2
else
  if [ ! -s "$OUT/failure.json" ]; then
    adoc_fail finalize action.receipt_failed 'No valid assessment state was available for receipt finalization.' \
      'Rerun the workflow and inspect the first failing AgentDoc stage.'
  fi
  failure="$(cat "$OUT/failure.json")"
  jq -n --arg created "$created_at" --argjson ci "$ci_json" --argjson revisions "$revision_json" \
    --argjson failure "$failure" '
    {schema_version:"adoc.pr_assessment_receipt.v0",run_status:"failed",created_at:$created,
     ci:$ci,revisions:$revisions,toolchain:{},assessment:null,knowledge_snapshot:null,failure:$failure,
     knowledge_gate:{status:"skipped"},semantic_review:{status:"skipped"},
     proposals:{status:"skipped"},delivery:{status:"skipped"}}' > "$receipt.tmp"
  completeness=error outcome=not_evaluated final_code=2
fi

jq -e '
  .schema_version == "adoc.pr_assessment_receipt.v0"
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
if [ -f "$assessment_path" ]; then
  emit_output assessment-path "$assessment_path"
  emit_output assessment-sha256 "$assessment_sha"
fi
emit_output assessment-receipt-path "$receipt"
emit_output assessment-receipt-sha256 "$receipt_sha"
exit 0
