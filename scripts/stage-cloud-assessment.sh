#!/usr/bin/env bash
# Stages same-job assessment outputs for isolated Cloud submission.
set -euo pipefail

fail() {
  echo "::error::action.cloud_sync_failed: $1" >&2
  exit 1
}

[ "${GITHUB_EVENT_NAME:-}" = workflow_run ] \
  || fail 'Use the protected default-branch workflow_run ingestion workflow.'
[ "${RUNNER_ENVIRONMENT:-}" = github-hosted ] \
  || fail 'Use a fresh GitHub-hosted runner for Cloud assessment ingestion.'
[ -f "${GITHUB_EVENT_PATH:-}" ] \
  && [[ "${GITHUB_REPOSITORY_ID:-}" =~ ^[1-9][0-9]*$ ]] \
  && [[ "${GITHUB_RUN_ID:-}" =~ ^[1-9][0-9]*$ ]] \
  && [[ "${GITHUB_RUN_ATTEMPT:-}" =~ ^[1-9][0-9]*$ ]] \
  && [[ "${EXPECTED_ACTION_REF:-}" =~ ^[0-9a-f]{40}$ ]] \
  || fail 'GitHub workflow-run identity is unavailable.'

runner_root="$(realpath "${RUNNER_TEMP:?}" 2>/dev/null)" \
  || fail 'Runner temporary storage is unavailable.'
assessment="$(realpath "${ASSESSMENT_PATH:?}" 2>/dev/null)" \
  || fail 'The same-job assessment output is unavailable.'
receipt="$(realpath "${ASSESSMENT_RECEIPT_PATH:?}" 2>/dev/null)" \
  || fail 'The same-job assessment receipt is unavailable.'
evidence_count=0
for path in "${KNOWLEDGE_GRAPH_PATH:-}" "${SEMANTIC_CONTEXT_PATH:-}" \
  "${SEMANTIC_ASSESSMENT_PATH:-}" "${SEMANTIC_EXECUTOR_RECEIPT_PATH:-}" \
  "${SEMANTIC_EXECUTOR_REQUEST_PATH:-}"; do
  [ -z "$path" ] || evidence_count=$((evidence_count + 1))
done
[ "$evidence_count" -eq 0 ] || [ "$evidence_count" -eq 5 ] \
  || fail 'Graph, semantic context, semantic assessment, executor request, and executor receipt must be supplied together.'
graph='' context='' semantic='' executor='' executor_request=''
if [ "$evidence_count" -eq 5 ]; then
  graph="$(realpath "$KNOWLEDGE_GRAPH_PATH" 2>/dev/null)" \
    || fail 'The same-job knowledge graph is unavailable.'
  context="$(realpath "$SEMANTIC_CONTEXT_PATH" 2>/dev/null)" \
    || fail 'The same-job semantic context is unavailable.'
  semantic="$(realpath "$SEMANTIC_ASSESSMENT_PATH" 2>/dev/null)" \
    || fail 'The same-job semantic assessment is unavailable.'
  executor="$(realpath "$SEMANTIC_EXECUTOR_RECEIPT_PATH" 2>/dev/null)" \
    || fail 'The same-job semantic executor receipt is unavailable.'
  executor_request="$(realpath "$SEMANTIC_EXECUTOR_REQUEST_PATH" 2>/dev/null)" \
    || fail 'The same-job semantic executor request is unavailable.'
  [[ "${SEMANTIC_EXECUTOR_RECEIPT_SHA256:-}" =~ ^sha256:[0-9a-f]{64}$ ]] \
    && [ "sha256:$(sha256sum "$executor" | awk '{print $1}')" \
      = "$SEMANTIC_EXECUTOR_RECEIPT_SHA256" ] \
    || fail 'The semantic executor receipt is not bound to the finalized Action output.'
  [[ "${SEMANTIC_EXECUTOR_REQUEST_DIGEST:-}" =~ ^sha256:[0-9a-f]{64}$ ]] \
    && [ "sha256:$(sha256sum "$executor_request" | awk '{print $1}')" \
      = "$SEMANTIC_EXECUTOR_REQUEST_DIGEST" ] \
    || fail 'The semantic executor request is not bound to the finalized Action output.'
elif [ -n "${SEMANTIC_EXECUTOR_RECEIPT_SHA256:-}" ]; then
  fail 'Semantic executor receipt path and digest must be supplied together.'
elif [ -n "${SEMANTIC_EXECUTOR_REQUEST_DIGEST:-}" ]; then
  fail 'Semantic executor request path and digest must be supplied together.'
fi
paths=("$assessment" "$receipt")
[ "$evidence_count" -ne 5 ] || paths+=("$graph" "$context" "$semantic" "$executor" "$executor_request")
for path in "${paths[@]}"; do
  case "$path" in
    "$runner_root"/*) ;;
    *) fail 'Assessment outputs must remain beneath RUNNER_TEMP.' ;;
  esac
done
[ "$assessment" != "$receipt" ] \
  && [ -f "$assessment" ] && [ ! -L "$ASSESSMENT_PATH" ] \
  && [ -f "$receipt" ] && [ ! -L "$ASSESSMENT_RECEIPT_PATH" ] \
  || fail 'Assessment outputs must be distinct regular files.'
if [ "$evidence_count" -eq 5 ]; then
  [ "$graph" != "$assessment" ] && [ "$graph" != "$receipt" ] \
    && [ "$context" != "$assessment" ] && [ "$context" != "$receipt" ] \
    && [ "$semantic" != "$assessment" ] && [ "$semantic" != "$receipt" ] \
    && [ "$graph" != "$context" ] && [ "$graph" != "$semantic" ] \
    && [ "$context" != "$semantic" ] && [ "$executor" != "$assessment" ] \
    && [ "$executor" != "$receipt" ] && [ "$executor" != "$graph" ] \
    && [ "$executor" != "$context" ] && [ "$executor" != "$semantic" ] \
    && [ "$executor_request" != "$assessment" ] \
    && [ "$executor_request" != "$receipt" ] \
    && [ "$executor_request" != "$graph" ] \
    && [ "$executor_request" != "$context" ] \
    && [ "$executor_request" != "$semantic" ] \
    && [ "$executor_request" != "$executor" ] \
    && [ -f "$graph" ] && [ ! -L "$KNOWLEDGE_GRAPH_PATH" ] \
    && [ -f "$context" ] && [ ! -L "$SEMANTIC_CONTEXT_PATH" ] \
    && [ -f "$semantic" ] && [ ! -L "$SEMANTIC_ASSESSMENT_PATH" ] \
    && [ -f "$executor" ] && [ ! -L "$SEMANTIC_EXECUTOR_RECEIPT_PATH" ] \
    && [ -f "$executor_request" ] && [ ! -L "$SEMANTIC_EXECUTOR_REQUEST_PATH" ] \
    || fail 'Semantic evidence must be distinct regular files.'
fi

if ! jq -e --arg action_ref "$EXPECTED_ACTION_REF" '
  .schema_version == "adoc.pr_assessment_receipt.v4"
  and .run_status == "completed"
  and .action == {repository:"agentdoc-dev/action",requested_ref:$action_ref,
    resolved_commit:$action_ref,provenance:"full_sha"}
  and (.ci.pull_request | type == "number" and floor == . and . > 0)
  and (.ci.run_id | type == "string" and test("^[1-9][0-9]*$"))
  and (.ci.run_attempt | type == "number" and floor == . and . > 0)
  and (.ci.job | type == "string" and test("^[A-Za-z_][A-Za-z0-9_-]{0,99}$"))
  and (.ci.invocation_id | type == "string"
    and test("^inv_[A-Za-z0-9_.-]+_[0-9a-f]{32}$"))
  and (.ci.workload_identity.repository_id | type == "string"
    and test("^[1-9][0-9]*$"))
  and (.revisions.requested_base | test("^[0-9a-f]{40}$"))
  and (.revisions.head | test("^[0-9a-f]{40}$"))
  and .assessment.schema_version == "adoc.change_assessment.v0"
  and (.assessment.sha256 | test("^sha256:[0-9a-f]{64}$"))
' "$receipt" >/dev/null; then
  fail 'The receipt is not a complete pinned-Action v4 assessment receipt.'
fi

if ! jq -e --slurpfile receipt "$receipt" \
  --arg repository "${GITHUB_REPOSITORY:-}" \
  --arg repository_id "$GITHUB_REPOSITORY_ID" \
  --arg run_id "$GITHUB_RUN_ID" \
  --argjson run_attempt "$GITHUB_RUN_ATTEMPT" \
  --arg job "${GITHUB_JOB:-}" --arg actor "${GITHUB_ACTOR:-}" \
  --arg actor_id "${GITHUB_ACTOR_ID:-}" \
  --arg triggering_actor "${GITHUB_TRIGGERING_ACTOR:-}" \
  --arg workflow_ref "${GITHUB_WORKFLOW_REF:-}" \
  --arg workflow_sha "${GITHUB_WORKFLOW_SHA:-}" '
  $receipt[0] as $r
  | .action == "completed"
  and .workflow_run.event == "pull_request"
  and .workflow_run.status == "completed"
  and (.repository.id | tostring) == $repository_id
  and .repository.full_name == $repository
  and $r.ci.repository == $repository
  and $r.ci.run_id == $run_id
  and $r.ci.run_attempt == $run_attempt
  and $r.ci.job == $job
  and $r.ci.actor == $actor
  and $r.ci.workload_identity.repository_id == $repository_id
  and $r.ci.workload_identity.actor_id == $actor_id
  and $r.ci.workload_identity.triggering_actor == $triggering_actor
  and $r.ci.workload_identity.workflow_ref == $workflow_ref
  and $r.ci.workload_identity.workflow_sha == $workflow_sha
  and any(.workflow_run.pull_requests[]?;
    .number == $r.ci.pull_request
    and .base.sha == $r.revisions.requested_base
    and .head.sha == $r.revisions.head)
' "$GITHUB_EVENT_PATH" >/dev/null; then
  fail 'The receipt was not produced by this protected workflow-run job.'
fi

invocation_id="$(jq -r .ci.invocation_id "$receipt")"
requested_base="$(jq -r .revisions.requested_base "$receipt")"
head="$(jq -r .revisions.head "$receipt")"
pr_number="$(jq -r .ci.pull_request "$receipt")"
[ "$(basename "$assessment")" = "assessment-$invocation_id.json" ] \
  && [ "$(basename "$receipt")" = "receipt-$invocation_id.json" ] \
  || fail 'Output filenames do not match the receipted invocation.'
if [ "$evidence_count" -eq 5 ]; then
  [ "$(basename "$graph")" = "knowledge-graph-$invocation_id.json" ] \
    && [ "$(basename "$context")" = "semantic-context-$invocation_id.json" ] \
    && [ "$(basename "$semantic")" = "semantic-assessment-$invocation_id.json" ] \
    && [ "$(basename "$executor")" = "semantic-executor-$invocation_id.json" ] \
    && [ "$(basename "$executor_request")" = "semantic-executor-request-$invocation_id.json" ] \
    || fail 'Semantic evidence filenames do not match the receipted invocation.'
  "$(cd "$(dirname "$0")" && pwd)/validate-semantic-evidence.sh" \
    "$assessment" "$receipt" "$graph" "$context" "$semantic" "$executor" \
    "$executor_request" \
    || fail 'Semantic evidence is not bound to the receipted assessment.'
fi

assessment_digest="sha256:$(sha256sum "$assessment" | awk '{print $1}')"
[ "$assessment_digest" = "$(jq -r .assessment.sha256 "$receipt")" ] \
  || fail 'The assessment bytes do not match the receipt.'
if ! jq -e --arg base "$requested_base" --arg head "$head" '
  .schema_version == "adoc.change_assessment.v0"
  and .snapshots.requested_base.resolved_commit == $base
  and .snapshots.head.resolved_commit == $head
' "$assessment" >/dev/null; then
  fail 'The assessment is not bound to the receipted revisions.'
fi
receipt_digest="sha256:$(sha256sum "$receipt" | awk '{print $1}')"

private_root="$(mktemp -d "$runner_root/agentdoc-cloud-assessment.XXXXXX")"
run_dir="$private_root/private"
retained_dir="$private_root/retained"
mkdir -m 700 "$run_dir" "$retained_dir"
install -m 600 "$assessment" "$retained_dir/assessment-$invocation_id.json"
install -m 600 "$receipt" "$retained_dir/receipt-$invocation_id.json"
if [ "$evidence_count" -eq 5 ]; then
  install -m 600 "$graph" "$retained_dir/knowledge-graph-$invocation_id.json"
  install -m 600 "$context" "$retained_dir/semantic-context-$invocation_id.json"
  install -m 600 "$semantic" "$retained_dir/semantic-assessment-$invocation_id.json"
  install -m 600 "$executor" "$retained_dir/semantic-executor-$invocation_id.json"
  install -m 600 "$executor_request" \
    "$retained_dir/semantic-executor-request-$invocation_id.json"
  printf '%s\n' "$SEMANTIC_EXECUTOR_RECEIPT_SHA256" \
    > "$run_dir/semantic-executor-receipt-sha256"
  printf '%s\n' "$SEMANTIC_EXECUTOR_REQUEST_DIGEST" \
    > "$run_dir/semantic-executor-request-digest"
fi
printf '%s\n' "$retained_dir/assessment-$invocation_id.json" > "$run_dir/assessment-path"
printf '%s\n' "$assessment_digest" > "$run_dir/assessment-sha256"
printf '%s\n' "$receipt_digest" > "$run_dir/receipt-sha256"

{
  printf 'ADOC_RUN_DIR=%s\n' "$run_dir"
  printf 'ADOC_RETAINED_DIR=%s\n' "$retained_dir"
  printf 'ADOC_INVOCATION_ID=%s\n' "$invocation_id"
  printf 'ADOC_REQUESTED_BASE=%s\n' "$requested_base"
  printf 'ADOC_HEAD=%s\n' "$head"
  printf 'ADOC_PR_NUMBER=%s\n' "$pr_number"
} >> "${GITHUB_ENV:?}"
