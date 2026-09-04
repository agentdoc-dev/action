#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CASE_DIR="$(mktemp -d)"
trap 'rm -rf "$CASE_DIR"' EXIT
mkdir -p "$CASE_DIR/bin" "$CASE_DIR/outputs" "$CASE_DIR/trusted"

export PATH="$CASE_DIR/bin:$PATH"
export ADOC_INVOCATION_ID=inv_801_2_agentdoc_0123456789abcdef0123456789abcdef
export ADOC_REQUESTED_BASE=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
export ADOC_HEAD=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
export ADOC_PR_NUMBER=801 ADOC_PROPOSE_ELIGIBLE=true
export CLOUD_ASSESSMENT_URL=https://cloud.test/api/v1/workspaces/10000000-0000-0000-0000-000000000801/assessment-submissions
export CLOUD_ASSESSMENT_REPOSITORY_ID=60000000-0000-0000-0000-000000000801
export CLOUD_ASSESSMENT_TOKEN=assessment-upload-token-801
export GH_TOKEN=github-token ANTHROPIC_API_KEY=provider-token
export CLAUDE_CODE_OAUTH_TOKEN='' CLOUD_UPLOAD_TOKEN=external-work-token-801
export GITHUB_OUTPUT="$CASE_DIR/github-output"
export MOCK_CURL_BODY="$CASE_DIR/request.json" MOCK_CURL_CALLED="$CASE_DIR/curl-called"
export MOCK_CURL_CONFIG="$CASE_DIR/curl.conf"
export POISONED_CURL_CALLED="$CASE_DIR/poisoned-curl-called"
export POISONED_CAT_CALLED="$CASE_DIR/poisoned-cat-called"
export GITHUB_REPOSITORY=agentdoc/test GITHUB_REPOSITORY_ID=99
export GITHUB_RUN_ID=202 GITHUB_RUN_ATTEMPT=3 GITHUB_JOB=cloud_ingest
export GITHUB_ACTOR=alice GITHUB_ACTOR_ID=42 GITHUB_TRIGGERING_ACTOR=alice
export GITHUB_WORKFLOW_REF=agentdoc/test/.github/workflows/cloud-ingestion.yml@refs/heads/main
export GITHUB_WORKFLOW_SHA=7777777777777777777777777777777777777777
export EXPECTED_ACTION_REF=8888888888888888888888888888888888888888

assessment="$CASE_DIR/outputs/assessment-$ADOC_INVOCATION_ID.json"
receipt="$CASE_DIR/outputs/receipt-$ADOC_INVOCATION_ID.json"
graph="$CASE_DIR/outputs/knowledge-graph-$ADOC_INVOCATION_ID.json"
semantic_context="$CASE_DIR/outputs/semantic-context-$ADOC_INVOCATION_ID.json"
semantic_assessment="$CASE_DIR/outputs/semantic-assessment-$ADOC_INVOCATION_ID.json"
semantic_executor="$CASE_DIR/outputs/semantic-executor-$ADOC_INVOCATION_ID.json"
semantic_executor_request="$CASE_DIR/outputs/semantic-executor-request-$ADOC_INVOCATION_ID.json"
jq -n '{schema_version:"adoc.graph.v6",nodes:[],edges:[],diagnostics:[]}' > "$graph"
graph_digest="sha256:$(sha256sum "$graph" | awk '{print $1}')"
jq -cn --arg base "$ADOC_REQUESTED_BASE" --arg head "$ADOC_HEAD" \
  --arg graph "$graph_digest" '{
  schema_version:"adoc.change_assessment.v0",completeness:"complete",outcome:"pass",
  snapshots:{requested_base:{resolved_commit:$base},head:{resolved_commit:$head}},
  knowledge_snapshot:{status:"available",graph_schema_version:"adoc.graph.v6",
    graph_sha256:$graph,object_set_sha256:("sha256:" + ("1" * 64))}
}' > "$assessment"
assessment_digest="sha256:$(sha256sum "$assessment" | awk '{print $1}')"
context_digest="sha256:$(printf semantic-context | sha256sum | awk '{print $1}')"
jq -n --arg context "$context_digest" --arg assessment "$assessment_digest" \
  --arg graph "$graph_digest" --arg head "$ADOC_HEAD" '{
    schema_version:"adoc.semantic_context.v0",context_digest:$context,
    subject_revision:{system:"git",value:$head},
    basis:{assessment_digest:$assessment,
      knowledge_basis:{kind:"graph_artifact",digest:$graph}},
    items:[{handle_id:"hunk-1",handle:{kind:"diff_hunk"}}]
  }' > "$semantic_context"
jq -n --arg context "$context_digest" --arg base "$ADOC_REQUESTED_BASE" \
  --arg head "$ADOC_HEAD" '{
    schema_version:"adoc.semantic_assessment.v0",context_digest:$context,
    base_revision:{system:"git",value:$base},
    head_revision:{system:"git",value:$head},
    identity:{provider:"test",model:"test-v1"},
    materiality_policy_version:"adoc.materiality.v0",
    scope:{handle_ids:["hunk-1"]},findings:[{
      finding_id:"finding-001",classification:"extends_existing_knowledge",
      affected_objects:[],citations:["hunk-1"],materiality:"material",
      proposed_disposition:"create_knowledge",candidate_updates:[],
      unresolved_questions:[],explanation:"A synthetic knowledge change is required."
    }]
  }' > "$semantic_assessment"
semantic_assessment_digest="sha256:$(sha256sum "$semantic_assessment" | awk '{print $1}')"
executor_config_digest="sha256:$(printf executor-config | sha256sum | awk '{print $1}')"
executor_prompt_digest="sha256:$(jq -cjn \
  '{contract_version:"test-v1",instructions:"Assess the exact context."}' \
  | sha256sum | awk '{print $1}')"
jq -cjn --arg config "$executor_config_digest" --arg prompt "$executor_prompt_digest" \
  --slurpfile context "$semantic_context" '{
    schema_version:"adoc.semantic_executor_request.v0",request_id:"primary",
    capability:"code_change_assessment",
    adapter:{kind:"generic",provider:"test",model:"test-v1",
      endpoint_class:"local",endpoint_id:"test",
      executor_digest:("sha256:" + ("5" * 64)),
      model_digest:("sha256:" + ("6" * 64)),config_digest:$config},
    task_digest:("sha256:" + ("3" * 64)),
    prompt:{contract_version:"test-v1",digest:$prompt,
      instructions:"Assess the exact context."},
    timeout_seconds:60,context:$context[0]
  }' > "$semantic_executor_request"
executor_request_digest="sha256:$(sha256sum "$semantic_executor_request" | awk '{print $1}')"
jq -n --arg context "$context_digest" --arg digest "$semantic_assessment_digest" \
  --arg request "$executor_request_digest" --slurpfile selected "$semantic_executor_request" '{
    schema_version:"adoc.semantic_executor_receipt.v0",request_id:"primary",
    request_digest:$request,capability:"code_change_assessment",
    outcome:"completed",assessment_digest:$digest,context_digest:$context,
    task_digest:$selected[0].task_digest,prompt_digest:$selected[0].prompt.digest,
    adapter:$selected[0].adapter
  }' > "$semantic_executor"
semantic_executor_digest="sha256:$(sha256sum "$semantic_executor" | awk '{print $1}')"
semantic_executor_request_digest="sha256:$(sha256sum "$semantic_executor_request" | awk '{print $1}')"
jq -cn --arg base "$ADOC_REQUESTED_BASE" --arg head "$ADOC_HEAD" \
  --arg digest "$assessment_digest" --arg semantic "$semantic_assessment_digest" \
  --arg graph "$graph_digest" --arg config "$executor_config_digest" '{
  schema_version:"adoc.pr_assessment_receipt.v4",run_status:"completed",
  action:{repository:"agentdoc-dev/action",requested_ref:("8" * 40),
    resolved_commit:("8" * 40),provenance:"full_sha"},
  revisions:{requested_base:$base,comparison_base:$base,head:$head},
  assessment:{schema_version:"adoc.change_assessment.v0",sha256:$digest,
    completeness:"complete",outcome:"pass"},
  knowledge_snapshot:{graph_schema_version:"adoc.graph.v6",graph_sha256:$graph,
    object_set_sha256:("sha256:" + ("1" * 64))},
  semantic_assessment:{status:"completed",failure_code:null,
    assessment_sha256:$semantic,
    primary:{request_id:"primary",provider:"test",model:"test-v1",
      outcome:"completed",failure_code:null},fallback:null},
  trusted_phase:{executor:{qualification_id:"internal-synthetic-qualified-test-v1",
    provider:"test",model:"test-v1",config_digest:$config}},
  ci:{provider:"github",repository:"agentdoc/test",pull_request:801,
    run_id:"202",run_attempt:3,job:"cloud_ingest",
    invocation_id:"inv_801_2_agentdoc_0123456789abcdef0123456789abcdef",
    actor:"alice",workload_identity:{provider:"github_actions",
    repository_id:"99",actor_id:"42",triggering_actor:"alice",
    workflow_ref:"agentdoc/test/.github/workflows/cloud-ingestion.yml@refs/heads/main",
    workflow_sha:("7" * 40)}}
}' > "$receipt"
receipt_digest="sha256:$(sha256sum "$receipt" | awk '{print $1}')"
proposal="$CASE_DIR/outputs/proposal-record-$ADOC_INVOCATION_ID.json"
patch="$CASE_DIR/proposal-patch.json"
jq -cS --arg assessment "$assessment_digest" '{
  schema_version:"adoc.patch.v0",op:"create_object",
  target:"internal.synthetic.claim",
  changes:{body:"Synthetic internal tracer proposal.",kind:"claim",
    placement:{page_id:"internal.synthetic"},status:"draft"},
  reason:("AgentDoc assessment " + $assessment + " finding finding-001."),
  proposer:{type:"agent",id:"agentdoc-action/internal-synthetic@qualified-test-v1"}
}' > "$patch"
patch_digest="sha256:$(sha256sum "$patch" | awk '{print $1}')"
proposal_set_digest="sha256:$(printf '[\"%s\"]\n' "$patch_digest" | sha256sum | awk '{print $1}')"
jq -n --arg set "$proposal_set_digest" --arg base "$ADOC_REQUESTED_BASE" \
  --arg head "$ADOC_HEAD" --arg assessment "$assessment_digest" \
  --arg context "$context_digest" --arg semantic "$semantic_assessment_digest" \
  --arg patch_digest "$patch_digest" --slurpfile patch "$patch" '{
  schema_version:"adoc.proposal.v0",proposal_set_digest:$set,supersedes:null,
  bindings:{base_revision:{system:"git",value:$base},
    head_revision:{system:"git",value:$head},
    change_request:{system:"github_pull_request",id:"801"},
    assessment_digest:$assessment,semantic_context_digest:$context,
    semantic_assessment_digest:$semantic},
  content_bindings:[],patches:[{finding_id:"finding-001",
    placement_path:"docs/internal.adoc",page_id:"internal.synthetic",
    target:"internal.synthetic.claim",operation:"create_object",
    patch_digest:$patch_digest,patch:$patch[0]}]
}' > "$proposal"
proposal_digest="sha256:$(sha256sum "$proposal" | awk '{print $1}')"
jq --arg set "$proposal_set_digest" \
  '.proposals = {status:"complete",count:1,sha256:$set,reason:"validated"}' \
  "$receipt" > "$receipt.tmp"
mv "$receipt.tmp" "$receipt"
receipt_digest="sha256:$(sha256sum "$receipt" | awk '{print $1}')"
jq -cn --arg base "$ADOC_REQUESTED_BASE" --arg head "$ADOC_HEAD" '{
  action:"completed",repository:{id:99,full_name:"agentdoc/test"},
  workflow_run:{id:101,run_attempt:2,event:"pull_request",status:"completed",pull_requests:[{
    number:801,base:{sha:$base},head:{sha:$head}}]}
}' > "$CASE_DIR/workflow-run.json"
jq '.workflow_run.pull_requests[0].head.sha = ("c" * 40)' \
  "$CASE_DIR/workflow-run.json" > "$CASE_DIR/wrong-run.json"
if ASSESSMENT_PATH="$assessment" ASSESSMENT_RECEIPT_PATH="$receipt" \
  GITHUB_EVENT_NAME=workflow_run GITHUB_EVENT_PATH="$CASE_DIR/wrong-run.json" \
  GITHUB_ENV="$CASE_DIR/staged-env" RUNNER_ENVIRONMENT=github-hosted \
  RUNNER_TEMP="$CASE_DIR" \
  PATH=/usr/bin:/bin:/usr/sbin:/sbin "$ROOT/scripts/stage-cloud-assessment.sh" \
  2> "$CASE_DIR/stage-error"; then
  echo 'mismatched workflow-run artifact unexpectedly staged' >&2
  exit 1
fi
grep -q 'action.cloud_sync_failed' "$CASE_DIR/stage-error"
mkdir "$CASE_DIR/wrong-output"
jq '.ci.run_id = "999"' "$receipt" \
  > "$CASE_DIR/wrong-output/receipt-$ADOC_INVOCATION_ID.json"
if ASSESSMENT_PATH="$assessment" \
  ASSESSMENT_RECEIPT_PATH="$CASE_DIR/wrong-output/receipt-$ADOC_INVOCATION_ID.json" \
  GITHUB_EVENT_NAME=workflow_run GITHUB_EVENT_PATH="$CASE_DIR/workflow-run.json" \
  GITHUB_ENV="$CASE_DIR/staged-env" RUNNER_ENVIRONMENT=github-hosted \
  RUNNER_TEMP="$CASE_DIR" PATH=/usr/bin:/bin:/usr/sbin:/sbin \
  "$ROOT/scripts/stage-cloud-assessment.sh" 2> "$CASE_DIR/job-error"; then
  echo 'receipt from another job unexpectedly accepted' >&2
  exit 1
fi
grep -q 'not produced by this protected workflow-run job' "$CASE_DIR/job-error"
if ASSESSMENT_PATH="$assessment" ASSESSMENT_RECEIPT_PATH="$receipt" \
  GITHUB_EVENT_NAME=workflow_run GITHUB_EVENT_PATH="$CASE_DIR/workflow-run.json" \
  GITHUB_ENV="$CASE_DIR/staged-env" RUNNER_ENVIRONMENT=self-hosted \
  RUNNER_TEMP="$CASE_DIR" PATH=/usr/bin:/bin:/usr/sbin:/sbin \
  "$ROOT/scripts/stage-cloud-assessment.sh" 2> "$CASE_DIR/runner-error"; then
  echo 'self-hosted runner unexpectedly accepted assessment credentials' >&2
  exit 1
fi
grep -q 'fresh GitHub-hosted runner' "$CASE_DIR/runner-error"
export GITHUB_EVENT_NAME=workflow_run GITHUB_EVENT_PATH="$CASE_DIR/workflow-run.json"
export GITHUB_REPOSITORY_ID=99 GITHUB_ENV="$CASE_DIR/staged-env"
export RUNNER_ENVIRONMENT=github-hosted RUNNER_TEMP="$CASE_DIR"
if ASSESSMENT_PATH="$assessment" ASSESSMENT_RECEIPT_PATH="$receipt" \
  KNOWLEDGE_GRAPH_PATH="$graph" PATH=/usr/bin:/bin:/usr/sbin:/sbin \
  "$ROOT/scripts/stage-cloud-assessment.sh" 2> "$CASE_DIR/evidence-error"; then
  echo 'partial semantic evidence unexpectedly staged' >&2
  exit 1
fi
grep -q 'must be supplied together' "$CASE_DIR/evidence-error"
export SEMANTIC_EXECUTOR_REQUEST_PATH="$semantic_executor_request"
export SEMANTIC_EXECUTOR_REQUEST_DIGEST="$semantic_executor_request_digest"
if SEMANTIC_EXECUTOR_REQUEST_PATH='' SEMANTIC_EXECUTOR_REQUEST_DIGEST='' \
  ASSESSMENT_PATH="$assessment" ASSESSMENT_RECEIPT_PATH="$receipt" \
  KNOWLEDGE_GRAPH_PATH="$graph" SEMANTIC_CONTEXT_PATH="$semantic_context" \
  SEMANTIC_ASSESSMENT_PATH="$semantic_assessment" \
  SEMANTIC_EXECUTOR_RECEIPT_PATH="$semantic_executor" \
  SEMANTIC_EXECUTOR_RECEIPT_SHA256="$semantic_executor_digest" \
  PATH=/usr/bin:/bin:/usr/sbin:/sbin \
  "$ROOT/scripts/stage-cloud-assessment.sh" 2> "$CASE_DIR/evidence-error"; then
  echo 'semantic evidence without its executor request unexpectedly staged' >&2
  exit 1
fi
grep -q 'must be supplied together' "$CASE_DIR/evidence-error"
cp "$semantic_assessment" "$CASE_DIR/semantic-assessment.valid.json"
cp "$receipt" "$CASE_DIR/receipt.valid.json"
for mutation in \
  '.head_revision.value = ("c" * 40)' \
  '.unexpected = true' \
  '.findings[0].citations = []'; do
  jq "$mutation" "$CASE_DIR/semantic-assessment.valid.json" \
    > "$semantic_assessment"
  wrong_semantic_digest="sha256:$(sha256sum "$semantic_assessment" | awk '{print $1}')"
  jq --arg digest "$wrong_semantic_digest" \
    '.semantic_assessment.assessment_sha256 = $digest' \
    "$CASE_DIR/receipt.valid.json" > "$receipt"
  if ASSESSMENT_PATH="$assessment" ASSESSMENT_RECEIPT_PATH="$receipt" \
    KNOWLEDGE_GRAPH_PATH="$graph" SEMANTIC_CONTEXT_PATH="$semantic_context" \
    SEMANTIC_ASSESSMENT_PATH="$semantic_assessment" \
    SEMANTIC_EXECUTOR_RECEIPT_PATH="$semantic_executor" \
    SEMANTIC_EXECUTOR_RECEIPT_SHA256="$semantic_executor_digest" \
    PATH=/usr/bin:/bin:/usr/sbin:/sbin \
    "$ROOT/scripts/stage-cloud-assessment.sh" 2> "$CASE_DIR/evidence-error"; then
    echo 'invalid semantic assessment unexpectedly staged' >&2
    exit 1
  fi
  grep -q 'not bound to the receipted assessment' "$CASE_DIR/evidence-error"
done
mv "$CASE_DIR/semantic-assessment.valid.json" "$semantic_assessment"
mv "$CASE_DIR/receipt.valid.json" "$receipt"
cp "$semantic_executor" "$CASE_DIR/semantic-executor.valid.json"
for mutation in \
  '.unexpected = true' \
  '.outcome = "failed"' \
  '.request_id = "wrong-request"' \
  '.adapter.provider = "wrong-provider"' \
  '.adapter.model = "wrong-model"' \
  '.context_digest = ("sha256:" + ("e" * 64))' \
  '.assessment_digest = ("sha256:" + ("e" * 64))' \
  '.adapter.config_digest = ("sha256:" + ("e" * 64))'; do
  jq "$mutation" "$CASE_DIR/semantic-executor.valid.json" > "$semantic_executor"
  mutated_executor_digest="sha256:$(sha256sum "$semantic_executor" | awk '{print $1}')"
  if ASSESSMENT_PATH="$assessment" ASSESSMENT_RECEIPT_PATH="$receipt" \
    KNOWLEDGE_GRAPH_PATH="$graph" SEMANTIC_CONTEXT_PATH="$semantic_context" \
    SEMANTIC_ASSESSMENT_PATH="$semantic_assessment" \
    SEMANTIC_EXECUTOR_RECEIPT_PATH="$semantic_executor" \
    SEMANTIC_EXECUTOR_RECEIPT_SHA256="$mutated_executor_digest" \
    PATH=/usr/bin:/bin:/usr/sbin:/sbin \
    "$ROOT/scripts/stage-cloud-assessment.sh" 2> "$CASE_DIR/evidence-error"; then
    echo 'misbound semantic executor receipt unexpectedly staged' >&2
    exit 1
  fi
  grep -q 'not bound to the receipted assessment' "$CASE_DIR/evidence-error"
done
mv "$CASE_DIR/semantic-executor.valid.json" "$semantic_executor"
cp "$semantic_executor_request" "$CASE_DIR/semantic-executor-request.valid.json"
jq '.task_digest = ("sha256:" + ("e" * 64))' \
  "$CASE_DIR/semantic-executor-request.valid.json" > "$semantic_executor_request"
mutated_request_digest="sha256:$(sha256sum "$semantic_executor_request" | awk '{print $1}')"
if SEMANTIC_EXECUTOR_REQUEST_DIGEST="$mutated_request_digest" \
  ASSESSMENT_PATH="$assessment" ASSESSMENT_RECEIPT_PATH="$receipt" \
  KNOWLEDGE_GRAPH_PATH="$graph" SEMANTIC_CONTEXT_PATH="$semantic_context" \
  SEMANTIC_ASSESSMENT_PATH="$semantic_assessment" \
  SEMANTIC_EXECUTOR_RECEIPT_PATH="$semantic_executor" \
  SEMANTIC_EXECUTOR_RECEIPT_SHA256="$semantic_executor_digest" \
  PATH=/usr/bin:/bin:/usr/sbin:/sbin \
  "$ROOT/scripts/stage-cloud-assessment.sh" 2> "$CASE_DIR/evidence-error"; then
  echo 'executor request not bound to its receipt unexpectedly staged' >&2
  exit 1
fi
grep -q 'not bound to the receipted assessment' "$CASE_DIR/evidence-error"
mv "$CASE_DIR/semantic-executor-request.valid.json" "$semantic_executor_request"
cp "$semantic_executor" "$CASE_DIR/semantic-executor.finalized.json"
printf '\n' >> "$semantic_executor"
if ASSESSMENT_PATH="$assessment" ASSESSMENT_RECEIPT_PATH="$receipt" \
  KNOWLEDGE_GRAPH_PATH="$graph" SEMANTIC_CONTEXT_PATH="$semantic_context" \
  SEMANTIC_ASSESSMENT_PATH="$semantic_assessment" \
  SEMANTIC_EXECUTOR_RECEIPT_PATH="$semantic_executor" \
  SEMANTIC_EXECUTOR_RECEIPT_SHA256="$semantic_executor_digest" \
  PATH=/usr/bin:/bin:/usr/sbin:/sbin \
  "$ROOT/scripts/stage-cloud-assessment.sh" 2> "$CASE_DIR/evidence-error"; then
  echo 'executor receipt changed after finalization unexpectedly staged' >&2
  exit 1
fi
grep -q 'not bound to the finalized Action output' "$CASE_DIR/evidence-error"
mv "$CASE_DIR/semantic-executor.finalized.json" "$semantic_executor"
ASSESSMENT_PATH="$assessment" ASSESSMENT_RECEIPT_PATH="$receipt" \
  KNOWLEDGE_GRAPH_PATH="$graph" SEMANTIC_CONTEXT_PATH="$semantic_context" \
  SEMANTIC_ASSESSMENT_PATH="$semantic_assessment" \
  SEMANTIC_EXECUTOR_RECEIPT_PATH="$semantic_executor" \
  SEMANTIC_EXECUTOR_RECEIPT_SHA256="$semantic_executor_digest" \
  PROPOSAL_RECORD_PATH="$proposal" PROPOSAL_RECORD_SHA256="$proposal_digest" \
  PATH=/usr/bin:/bin:/usr/sbin:/sbin \
  "$ROOT/scripts/stage-cloud-assessment.sh"
staged=0
while IFS='=' read -r name value; do
  case "$name" in
    ADOC_RUN_DIR | ADOC_RETAINED_DIR | ADOC_INVOCATION_ID | \
      ADOC_REQUESTED_BASE | ADOC_HEAD | ADOC_PR_NUMBER)
      export "$name=$value"
      staged=$((staged + 1)) ;;
    *) exit 1 ;;
  esac
done < "$GITHUB_ENV"
[ "$staged" -eq 6 ]
assessment="$(cat "$ADOC_RUN_DIR/assessment-path")"
receipt="$ADOC_RETAINED_DIR/receipt-$ADOC_INVOCATION_ID.json"
graph="$ADOC_RETAINED_DIR/knowledge-graph-$ADOC_INVOCATION_ID.json"
semantic_context="$ADOC_RETAINED_DIR/semantic-context-$ADOC_INVOCATION_ID.json"
semantic_assessment="$ADOC_RETAINED_DIR/semantic-assessment-$ADOC_INVOCATION_ID.json"
semantic_executor="$ADOC_RETAINED_DIR/semantic-executor-$ADOC_INVOCATION_ID.json"
semantic_executor_request="$ADOC_RETAINED_DIR/semantic-executor-request-$ADOC_INVOCATION_ID.json"
proposal="$ADOC_RETAINED_DIR/proposal-record-$ADOC_INVOCATION_ID.json"
test -f "$graph" && test -f "$semantic_context" && test -f "$semantic_assessment" \
  && test -f "$semantic_executor" && test -f "$semantic_executor_request" \
  && test -f "$proposal"
test "sha256:$(sha256sum "$semantic_executor" | awk '{print $1}')" = "$semantic_executor_digest"
test "sha256:$(sha256sum "$proposal" | awk '{print $1}')" = "$proposal_digest"
test "$(cat "$ADOC_RUN_DIR/proposal-record-sha256")" = "$proposal_digest"
export GITHUB_EVENT_NAME=pull_request

cat > "$CASE_DIR/trusted/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[ "${1:-}" = -q ] || exit 96
touch "$MOCK_CURL_CALLED"
output=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    --config) cp "$2" "$MOCK_CURL_CONFIG"; shift 2 ;;
    --output) output="$2"; shift 2 ;;
    --data-binary) cp "${2#@}" "$MOCK_CURL_BODY"; shift 2 ;;
    *) shift ;;
  esac
done
[ "${MOCK_CURL_FAIL:-false}" != true ] || exit 22
disposition="${MOCK_DISPOSITION:-accepted}"
case "$disposition" in
  accepted) http=202; code=null; complete=true; replayed=false ;;
  duplicate) http=200; code='"ingest.duplicate_delivery"'; complete=true; replayed=true ;;
  stale) http=202; code='"ingest.stale_run"'; complete=true; replayed=false ;;
  partial) http=202; code='"api.internal_error"'; complete=false; replayed=false ;;
esac
jq -cn --arg disposition "$disposition" --argjson code "$code" \
  --argjson complete "$complete" --argjson replayed "$replayed" \
  --arg assessment "$(jq -r .payload.assessment.digest "$MOCK_CURL_BODY")" \
  --arg receipt "$(jq -r .payload.receipt.digest "$MOCK_CURL_BODY")" '{
  schema_version:"agentdoc.cloud.ingestion_result.v0",payload:{
    ingestion_id:"70000000-0000-0000-0000-000000000801",
    disposition:$disposition,code:$code,complete:$complete,
    assessment_digest:$assessment,receipt_digest:$receipt,replayed:$replayed,
    original_request_id:"40000000-0000-0000-0000-000000000801",
    request_id:"40000000-0000-0000-0000-000000000802"}}
' > "$output"
printf %s "$http"
EOF
chmod +x "$CASE_DIR/trusted/curl"
cat > "$CASE_DIR/bin/curl" <<'EOF'
#!/usr/bin/env bash
touch "$POISONED_CURL_CALLED"
exit 97
EOF
chmod +x "$CASE_DIR/bin/curl"
cat > "$CASE_DIR/bin/cat" <<'EOF'
#!/usr/bin/env bash
touch "$POISONED_CAT_CALLED"
exec /bin/cat "$@"
EOF
chmod +x "$CASE_DIR/bin/cat"

reset_case() {
  rm -f "$ADOC_RUN_DIR/cloud-assessment-status.json" "$MOCK_CURL_BODY" \
    "$MOCK_CURL_CALLED" "$MOCK_CURL_CONFIG" "$POISONED_CURL_CALLED" \
    "$POISONED_CAT_CALLED" "$GITHUB_OUTPUT"
  unset MOCK_CURL_FAIL MOCK_DISPOSITION
  export ADOC_PROPOSE_ELIGIBLE=true GITHUB_EVENT_NAME=pull_request
  export CLOUD_ASSESSMENT_TOKEN=assessment-upload-token-801
}

assessment_before="$(sha256sum "$assessment")"
receipt_before="$(sha256sum "$receipt")"
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
test "$(cat "$ADOC_RUN_DIR/semantic-executor-receipt-sha256")" \
  = "$semantic_executor_digest"
cp "$semantic_executor_request" "$CASE_DIR/semantic-executor-request.staged.json"
printf '\n' >> "$semantic_executor_request"
reset_case
"$ROOT/scripts/upload-cloud-assessment.sh" "$CASE_DIR/trusted/curl"
test ! -e "$MOCK_CURL_CALLED"
jq -e '.status == "failed" and .code == "action.cloud_sync_failed"' \
  "$ADOC_RUN_DIR/cloud-assessment-status.json" >/dev/null
mv "$CASE_DIR/semantic-executor-request.staged.json" "$semantic_executor_request"
cp "$semantic_executor" "$CASE_DIR/semantic-executor.staged.json"
printf '\n' >> "$semantic_executor"
reset_case
"$ROOT/scripts/upload-cloud-assessment.sh" "$CASE_DIR/trusted/curl"
test ! -e "$MOCK_CURL_CALLED"
jq -e '.status == "failed" and .code == "action.cloud_sync_failed"' \
  "$ADOC_RUN_DIR/cloud-assessment-status.json" >/dev/null
mv "$CASE_DIR/semantic-executor.staged.json" "$semantic_executor"
reset_case
"$ROOT/scripts/upload-cloud-assessment.sh" "$CASE_DIR/trusted/curl"
test ! -e "$POISONED_CURL_CALLED"
test ! -e "$POISONED_CAT_CALLED"
test "$(sha256sum "$assessment")" = "$assessment_before"
test "$(sha256sum "$receipt")" = "$receipt_before"
jq -e '.status == "completed" and .disposition == "accepted" and .code == null
  and (.request_digest | test("^sha256:[0-9a-f]{64}$"))
  and (.idempotency_key | test("^sha256:[0-9a-f]{64}$"))' \
  "$ADOC_RUN_DIR/cloud-assessment-status.json" >/dev/null
jq -e --arg repository "$CLOUD_ASSESSMENT_REPOSITORY_ID" \
  --arg delivery "$ADOC_INVOCATION_ID" --arg base "$ADOC_REQUESTED_BASE" \
  --arg head "$ADOC_HEAD" --arg assessment "$assessment_digest" \
  --arg receipt "$receipt_digest" --arg executor "$semantic_executor_digest" \
  --arg request "$semantic_executor_request_digest" '
  keys == ["payload","schema_version"]
  and .schema_version == "agentdoc.cloud.assessment_submission.v0"
  and .payload.delivery_id == $delivery and .payload.repository_id == $repository
  and .payload.change_request == {system:"github_pull_request",id:"801"}
  and .payload.revision == {system:"git",base:$base,head:$head,lineage:[$head]}
  and .payload.assessment.schema_version == "adoc.change_assessment.v0"
  and .payload.assessment.digest == $assessment
  and .payload.receipt.schema_version == "adoc.pr_assessment_receipt.v4"
  and .payload.receipt.digest == $receipt
  and (.payload.evidence | keys == ["graph","semantic_assessment",
    "semantic_context","semantic_executor_receipt","semantic_executor_request"])
  and .payload.evidence.graph.schema_version == "adoc.graph.v6"
  and (.payload.evidence.graph | keys == ["bytes_base64","digest","schema_version"])
  and .payload.evidence.semantic_context.schema_version == "adoc.semantic_context.v0"
  and (.payload.evidence.semantic_context | keys == ["bytes_base64","digest","schema_version"])
  and .payload.evidence.semantic_assessment.schema_version == "adoc.semantic_assessment.v0"
  and (.payload.evidence.semantic_assessment | keys == ["bytes_base64","digest","schema_version"])
  and .payload.evidence.semantic_executor_receipt.schema_version == "adoc.semantic_executor_receipt.v0"
  and .payload.evidence.semantic_executor_receipt.digest == $executor
  and (.payload.evidence.semantic_executor_receipt | keys == ["bytes_base64","digest","schema_version"])
  and .payload.evidence.semantic_executor_request.schema_version == "adoc.semantic_executor_request.v0"
  and .payload.evidence.semantic_executor_request.digest == $request
  and (.payload.evidence.semantic_executor_request | keys == ["bytes_base64","digest","schema_version"])
' "$MOCK_CURL_BODY" >/dev/null
cmp "$assessment" <(jq -r .payload.assessment.bytes_base64 "$MOCK_CURL_BODY" | base64 --decode)
cmp "$receipt" <(jq -r .payload.receipt.bytes_base64 "$MOCK_CURL_BODY" | base64 --decode)
cmp "$graph" <(jq -r .payload.evidence.graph.bytes_base64 "$MOCK_CURL_BODY" | base64 --decode)
cmp "$semantic_context" <(jq -r .payload.evidence.semantic_context.bytes_base64 "$MOCK_CURL_BODY" | base64 --decode)
cmp "$semantic_assessment" <(jq -r .payload.evidence.semantic_assessment.bytes_base64 "$MOCK_CURL_BODY" | base64 --decode)
cmp "$semantic_executor" <(jq -r .payload.evidence.semantic_executor_receipt.bytes_base64 "$MOCK_CURL_BODY" | base64 --decode)
cmp "$semantic_executor_request" <(jq -r .payload.evidence.semantic_executor_request.bytes_base64 "$MOCK_CURL_BODY" | base64 --decode)
test "$(jq -r .payload.evidence.semantic_executor_request.digest "$MOCK_CURL_BODY")" \
  = "$(jq -r .request_digest "$semantic_executor")"
request_digest="sha256:$(sha256sum "$MOCK_CURL_BODY" | awk '{print $1}')"
test "$(jq -r .request_digest "$ADOC_RUN_DIR/cloud-assessment-status.json")" = "$request_digest"
expected_key="sha256:$(printf '%s\n%s\n%s\n%s' "$ADOC_INVOCATION_ID" \
  "$CLOUD_ASSESSMENT_REPOSITORY_ID" "$ADOC_HEAD" "$request_digest" | sha256sum | awk '{print $1}')"
test "$(jq -r .idempotency_key "$ADOC_RUN_DIR/cloud-assessment-status.json")" = "$expected_key"
grep -Fqx "header = \"Authorization: Bearer $CLOUD_ASSESSMENT_TOKEN\"" \
  "$MOCK_CURL_CONFIG"
grep -Fqx "header = \"Idempotency-Key: $expected_key\"" "$MOCK_CURL_CONFIG"
grep -Fxq 'status=completed' "$GITHUB_OUTPUT"
grep -Fxq 'disposition=accepted' "$GITHUB_OUTPUT"
grep -Fxq "request-digest=$request_digest" "$GITHUB_OUTPUT"

# E5.5.T1 internal/synthetic tracer segment: the same exact deterministic and
# qualified-semantic evidence continues into one canonical proposal command.
export CLOUD_PROPOSAL_URL=https://cloud.test/api/v1/workspaces/10000000-0000-0000-0000-000000000801/proposal-commands
export CLOUD_PROPOSAL_TOKEN=proposal-upload-token-801
export GITHUB_EVENT_NAME=workflow_run ADOC_ISOLATED_ASSESSMENT=true
export MOCK_PROPOSAL_BODY="$CASE_DIR/proposal-request.json"
export MOCK_PROPOSAL_CONFIG="$CASE_DIR/proposal-curl.conf"
export MOCK_PROPOSAL_RECORD_DIGEST="$proposal_digest"
cat > "$CASE_DIR/trusted/proposal-curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[ "${1:-}" = -q ] || exit 96
output=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    --config) cp "$2" "$MOCK_PROPOSAL_CONFIG"; shift 2 ;;
    --output) output="$2"; shift 2 ;;
    --data-binary) cp "${2#@}" "$MOCK_PROPOSAL_BODY"; shift 2 ;;
    *) shift ;;
  esac
done
set_digest="$(jq -r .payload.proposal_set_digest "$MOCK_PROPOSAL_BODY")"
if [ -n "${MOCK_PROPOSAL_ERROR_CODE:-}" ]; then
  jq -cn --arg code "$MOCK_PROPOSAL_ERROR_CODE" '{error:{code:$code}}' > "$output"
  printf 409
  exit 0
fi
disposition="${MOCK_PROPOSAL_DISPOSITION:-accepted}"
case "$disposition" in
  accepted) http=202; code=null; replayed=false ;;
  duplicate) http=200; code='"ingest.duplicate_delivery"'; replayed=true ;;
esac
replayed="${MOCK_PROPOSAL_REPLAYED:-$replayed}"
jq -cn --arg disposition "$disposition" --argjson code "$code" \
  --argjson replayed "$replayed" --arg set "$set_digest" \
  --arg record "$MOCK_PROPOSAL_RECORD_DIGEST" '{
  schema_version:"agentdoc.cloud.ingestion_result.v0",payload:{
    disposition:$disposition,code:$code,complete:true,
    proposal_record_id:"70000000-0000-0000-0000-000000000801",
    proposal_version_id:"71000000-0000-0000-0000-000000000801",
    proposal_set_digest:$set,record_digest:$record,supersedes:null,
    original_request_id:"40000000-0000-0000-0000-000000000801",
    replayed:$replayed,request_id:"40000000-0000-0000-0000-000000000802"}}
' > "$output"
printf %s "$http"
EOF
chmod +x "$CASE_DIR/trusted/proposal-curl"
: > "$GITHUB_OUTPUT"
"$ROOT/scripts/upload-cloud-proposal.sh" "$CASE_DIR/trusted/proposal-curl"
proposal_status="$ADOC_RUN_DIR/cloud-proposal-status.json"
jq -e --arg set "$proposal_set_digest" --arg record "$proposal_digest" '
  .status == "completed" and .disposition == "accepted" and .code == null
  and .proposal_set_digest == $set and .record_digest == $record
  and (.request_digest | test("^sha256:[0-9a-f]{64}$"))
  and (.idempotency_key | test("^sha256:[0-9a-f]{64}$"))
  and (.proposal_record_id | test("^[0-9a-f-]{36}$"))
  and (.proposal_version_id | test("^[0-9a-f-]{36}$"))
' "$proposal_status" >/dev/null
jq -e --arg set "$proposal_set_digest" '
  .schema_version == "agentdoc.cloud.proposal_command.v0"
  and .payload.schema_version == "adoc.proposal.v0"
  and .payload.proposal_set_digest == $set
' "$MOCK_PROPOSAL_BODY" >/dev/null
proposal_request_digest="sha256:$(sha256sum "$MOCK_PROPOSAL_BODY" | awk '{print $1}')"
proposal_idempotency_key="sha256:$(printf '%s\n%s' "$proposal_set_digest" \
  "$proposal_request_digest" | sha256sum | awk '{print $1}')"
test "$(jq -r .request_digest "$proposal_status")" = "$proposal_request_digest"
test "$(jq -r .idempotency_key "$proposal_status")" = "$proposal_idempotency_key"
grep -Fqx "header = \"Authorization: Bearer $CLOUD_PROPOSAL_TOKEN\"" \
  "$MOCK_PROPOSAL_CONFIG"
grep -Fqx "header = \"Idempotency-Key: $proposal_idempotency_key\"" \
  "$MOCK_PROPOSAL_CONFIG"
cp "$MOCK_PROPOSAL_BODY" "$CASE_DIR/proposal-request.first.json"
export MOCK_PROPOSAL_DISPOSITION=duplicate
"$ROOT/scripts/upload-cloud-proposal.sh" "$CASE_DIR/trusted/proposal-curl"
cmp "$CASE_DIR/proposal-request.first.json" "$MOCK_PROPOSAL_BODY"
jq -e --arg request "$proposal_request_digest" \
  --arg key "$proposal_idempotency_key" '
  .status == "completed" and .disposition == "duplicate"
  and .code == "ingest.duplicate_delivery"
  and .request_digest == $request and .idempotency_key == $key
' "$proposal_status" >/dev/null
export MOCK_PROPOSAL_REPLAYED=false
"$ROOT/scripts/upload-cloud-proposal.sh" "$CASE_DIR/trusted/proposal-curl"
jq -e '.status == "failed" and .disposition == null
  and .code == "action.cloud_sync_failed" and .remediation != null' \
  "$proposal_status" >/dev/null
unset MOCK_PROPOSAL_REPLAYED
reset_case
export MOCK_DISPOSITION=stale
"$ROOT/scripts/upload-cloud-assessment.sh" "$CASE_DIR/trusted/curl"
jq -e '.status == "completed" and .disposition == "stale"
  and .code == "ingest.stale_run"' \
  "$ADOC_RUN_DIR/cloud-assessment-status.json" >/dev/null
rm -f "$MOCK_PROPOSAL_BODY" "$MOCK_PROPOSAL_CONFIG"
export GITHUB_EVENT_NAME=workflow_run
"$ROOT/scripts/upload-cloud-proposal.sh" "$CASE_DIR/trusted/proposal-curl"
test ! -e "$MOCK_PROPOSAL_BODY"
jq -e '.status == "failed" and .disposition == null
  and .code == "action.cloud_sync_failed"
  and .remediation == "Complete the exact Cloud assessment ingestion before submitting its proposal."' \
  "$proposal_status" >/dev/null
reset_case
"$ROOT/scripts/upload-cloud-assessment.sh" "$CASE_DIR/trusted/curl"
export GITHUB_EVENT_NAME=workflow_run
rm -f "$MOCK_PROPOSAL_BODY" "$MOCK_PROPOSAL_CONFIG"
unset MOCK_PROPOSAL_DISPOSITION
export MOCK_PROPOSAL_ERROR_CODE=governance.proposal_conflict
"$ROOT/scripts/upload-cloud-proposal.sh" "$CASE_DIR/trusted/proposal-curl"
test -e "$MOCK_PROPOSAL_BODY"
jq -e '.status == "failed" and .disposition == null
  and .code == "governance.proposal_conflict" and .remediation != null' \
  "$proposal_status" >/dev/null
unset MOCK_PROPOSAL_ERROR_CODE
jq -n --arg classification internal_synthetic --arg head "$ADOC_HEAD" \
  --arg deterministic "$assessment_digest" --arg semantic "$semantic_assessment_digest" \
  --arg executor "$semantic_executor_digest" --arg proposal "$proposal_set_digest" \
  --arg request "$proposal_request_digest" '{
  classification:$classification,source:{provider:"github",head_sha:$head},
  digests:{deterministic_assessment:$deterministic,semantic_assessment:$semantic,
    semantic_executor_receipt:$executor,proposal_set:$proposal,
    proposal_command:$request}
}' > "$CASE_DIR/internal-tracer-segment.json"
jq -e '
  .classification == "internal_synthetic"
  and .source.provider == "github"
  and ([.digests[]] | all(test("^sha256:[0-9a-f]{64}$")))
' "$CASE_DIR/internal-tracer-segment.json" >/dev/null
cp "$proposal" "$CASE_DIR/proposal-record.valid.json"
printf '\n' >> "$proposal"
rm -f "$MOCK_PROPOSAL_BODY" "$MOCK_PROPOSAL_CONFIG"
"$ROOT/scripts/upload-cloud-proposal.sh" "$CASE_DIR/trusted/proposal-curl"
test ! -e "$MOCK_PROPOSAL_BODY"
jq -e '.status == "failed" and .code == "action.cloud_sync_failed"' \
  "$proposal_status" >/dev/null
mv "$CASE_DIR/proposal-record.valid.json" "$proposal"

rm -f "$MOCK_PROPOSAL_BODY" "$MOCK_PROPOSAL_CONFIG"
ADOC_PROPOSE_ELIGIBLE=false \
  "$ROOT/scripts/upload-cloud-proposal.sh" "$CASE_DIR/trusted/proposal-curl"
test ! -e "$MOCK_PROPOSAL_BODY"
jq -e '.status == "skipped" and .code == null' "$proposal_status" >/dev/null

# Evidence below the 1 MiB request limit must not depend on Linux accepting a
# single command-line argument larger than MAX_ARG_STRLEN.
head -c 120000 /dev/zero | tr '\0' ' ' >> "$graph"
graph_digest="sha256:$(sha256sum "$graph" | awk '{print $1}')"
jq --arg graph "$graph_digest" '.knowledge_snapshot.graph_sha256 = $graph' \
  "$assessment" > "$assessment.tmp"
mv "$assessment.tmp" "$assessment"
assessment_digest="sha256:$(sha256sum "$assessment" | awk '{print $1}')"
jq --arg graph "$graph_digest" --arg assessment "$assessment_digest" \
  '.basis.knowledge_basis.digest = $graph | .basis.assessment_digest = $assessment' \
  "$semantic_context" > "$semantic_context.tmp"
mv "$semantic_context.tmp" "$semantic_context"
jq -cj --slurpfile context "$semantic_context" '.context = $context[0]' \
  "$semantic_executor_request" > "$semantic_executor_request.tmp"
mv "$semantic_executor_request.tmp" "$semantic_executor_request"
semantic_executor_request_digest="sha256:$(sha256sum "$semantic_executor_request" | awk '{print $1}')"
jq --arg request "$semantic_executor_request_digest" '.request_digest = $request' \
  "$semantic_executor" > "$semantic_executor.tmp"
mv "$semantic_executor.tmp" "$semantic_executor"
semantic_executor_digest="sha256:$(sha256sum "$semantic_executor" | awk '{print $1}')"
jq --arg graph "$graph_digest" --arg assessment "$assessment_digest" \
  '.knowledge_snapshot.graph_sha256 = $graph | .assessment.sha256 = $assessment' \
  "$receipt" > "$receipt.tmp"
mv "$receipt.tmp" "$receipt"
receipt_digest="sha256:$(sha256sum "$receipt" | awk '{print $1}')"
printf '%s\n' "$assessment_digest" > "$ADOC_RUN_DIR/assessment-sha256"
printf '%s\n' "$receipt_digest" > "$ADOC_RUN_DIR/receipt-sha256"
printf '%s\n' "$semantic_executor_digest" \
  > "$ADOC_RUN_DIR/semantic-executor-receipt-sha256"
printf '%s\n' "$semantic_executor_request_digest" \
  > "$ADOC_RUN_DIR/semantic-executor-request-digest"
REAL_JQ="$(command -v jq)"
export REAL_JQ
cat > "$CASE_DIR/trusted/jq" <<'EOF'
#!/usr/bin/env bash
for argument in "$@"; do
  [ "${#argument}" -le 131071 ] || exit 126
done
exec "$REAL_JQ" "$@"
EOF
chmod +x "$CASE_DIR/trusted/jq"
export PATH="$CASE_DIR/trusted:/usr/bin:/bin:/usr/sbin:/sbin"
reset_case
if ! "$ROOT/scripts/upload-cloud-assessment.sh" "$CASE_DIR/trusted/curl"; then
  echo 'valid sub-1 MiB evidence exceeded a command-line argument limit' >&2
  exit 1
fi
request_bytes="$(wc -c < "$MOCK_CURL_BODY" | tr -d ' ')"
evidence_bytes="$(jq -c '.payload.evidence' "$MOCK_CURL_BODY" | wc -c | tr -d ' ')"
test "$evidence_bytes" -gt 131071 && test "$request_bytes" -le 1048576
jq -e '.status == "completed" and .disposition == "accepted"' \
  "$ADOC_RUN_DIR/cloud-assessment-status.json" >/dev/null

# Digest sidecars prove semantic evidence was produced, so missing artifacts
# must fail closed instead of silently degrading to a legacy upload.
rm "$graph" "$semantic_context" "$semantic_assessment" "$semantic_executor" \
  "$semantic_executor_request"
reset_case
"$ROOT/scripts/upload-cloud-assessment.sh" "$CASE_DIR/trusted/curl"
test ! -e "$MOCK_CURL_CALLED"
jq -e '.status == "failed" and .code == "action.cloud_sync_failed"' \
  "$ADOC_RUN_DIR/cloud-assessment-status.json" >/dev/null

# The additive evidence member remains optional for genuine legacy uploads.
rm "$ADOC_RUN_DIR/semantic-executor-receipt-sha256" \
  "$ADOC_RUN_DIR/semantic-executor-request-digest"
reset_case
"$ROOT/scripts/upload-cloud-assessment.sh" "$CASE_DIR/trusted/curl"
jq -e '.payload | has("evidence") | not' "$MOCK_CURL_BODY" >/dev/null

reset_case
export MOCK_DISPOSITION=duplicate
"$ROOT/scripts/upload-cloud-assessment.sh" "$CASE_DIR/trusted/curl"
jq -e '.status == "completed" and .disposition == "duplicate"
  and .code == "ingest.duplicate_delivery"' \
  "$ADOC_RUN_DIR/cloud-assessment-status.json" >/dev/null

reset_case
export MOCK_DISPOSITION=partial
"$ROOT/scripts/upload-cloud-assessment.sh" "$CASE_DIR/trusted/curl"
jq -e '.status == "failed" and .disposition == "partial"
  and .code == "api.internal_error" and .remediation != null' \
  "$ADOC_RUN_DIR/cloud-assessment-status.json" >/dev/null

reset_case
export MOCK_CURL_FAIL=true
"$ROOT/scripts/upload-cloud-assessment.sh" "$CASE_DIR/trusted/curl"
jq -e '.status == "failed" and .disposition == null
  and .code == "action.cloud_sync_failed"' \
  "$ADOC_RUN_DIR/cloud-assessment-status.json" >/dev/null

reset_case
export CLOUD_ASSESSMENT_TOKEN="$GH_TOKEN"
"$ROOT/scripts/upload-cloud-assessment.sh" "$CASE_DIR/trusted/curl"
test ! -e "$MOCK_CURL_CALLED"
jq -e '.status == "failed" and .code == "action.cloud_sync_failed"' \
  "$ADOC_RUN_DIR/cloud-assessment-status.json" >/dev/null

reset_case
export ADOC_PROPOSE_ELIGIBLE=false
export CLOUD_ASSESSMENT_TOKEN=''
"$ROOT/scripts/upload-cloud-assessment.sh" "$CASE_DIR/trusted/curl"
test ! -e "$MOCK_CURL_CALLED"
jq -e '.status == "skipped" and .code == null' \
  "$ADOC_RUN_DIR/cloud-assessment-status.json" >/dev/null

reset_case
printf '%s\n' "$CASE_DIR/missing-assessment.json" > "$ADOC_RUN_DIR/assessment-path"
"$ROOT/scripts/upload-cloud-assessment.sh" "$CASE_DIR/trusted/curl"
test ! -e "$MOCK_CURL_CALLED"
jq -e '.status == "failed" and .code == "action.cloud_sync_failed"' \
  "$ADOC_RUN_DIR/cloud-assessment-status.json" >/dev/null
printf '%s\n' "$assessment" > "$ADOC_RUN_DIR/assessment-path"

grep -Fq 'cloud-assessment-token:' "$ROOT/cloud-assessment/action.yml"
grep -Fq 'github-token:' "$ROOT/cloud-assessment/action.yml"
grep -Fq "GH_TOKEN=\"\$GH_TOKEN\"" "$ROOT/cloud-assessment/action.yml"
grep -Fq 'ASSESSMENT_PATH:' "$ROOT/cloud-assessment/action.yml"
grep -Fq 'KNOWLEDGE_GRAPH_PATH:' "$ROOT/cloud-assessment/action.yml"
grep -Fq 'SEMANTIC_CONTEXT_PATH:' "$ROOT/cloud-assessment/action.yml"
grep -Fq 'SEMANTIC_ASSESSMENT_PATH:' "$ROOT/cloud-assessment/action.yml"
grep -Fq 'SEMANTIC_EXECUTOR_RECEIPT_PATH:' "$ROOT/cloud-assessment/action.yml"
grep -Fq 'SEMANTIC_EXECUTOR_RECEIPT_SHA256:' "$ROOT/cloud-assessment/action.yml"
grep -Fq 'SEMANTIC_EXECUTOR_REQUEST_PATH:' "$ROOT/cloud-assessment/action.yml"
grep -Fq 'SEMANTIC_EXECUTOR_REQUEST_DIGEST:' "$ROOT/cloud-assessment/action.yml"
grep -Fq 'proposal-record-path:' "$ROOT/cloud-assessment/action.yml"
grep -Fq 'proposal-record-sha256:' "$ROOT/cloud-assessment/action.yml"
grep -Fq 'cloud-proposal-url:' "$ROOT/cloud-assessment/action.yml"
grep -Fq 'cloud-proposal-token:' "$ROOT/cloud-assessment/action.yml"
grep -Fq 'PROPOSAL_RECORD_PATH:' "$ROOT/cloud-assessment/action.yml"
grep -Fq 'PROPOSAL_RECORD_SHA256:' "$ROOT/cloud-assessment/action.yml"
grep -Fq 'upload-cloud-assessment.sh" /usr/bin/curl' \
  "$ROOT/cloud-assessment/action.yml"
grep -Fq 'upload-cloud-proposal.sh" /usr/bin/curl' \
  "$ROOT/cloud-assessment/action.yml"
proposal_step="$(sed -n '/- name: Submit exact proposal to Cloud/,/upload-cloud-proposal.sh/p' \
  "$ROOT/cloud-assessment/action.yml")"
# shellcheck disable=SC2016 # Match literal shell forwarding in action.yml.
grep -Fq 'ADOC_PROPOSE_ELIGIBLE="$ADOC_PROPOSE_ELIGIBLE"' <<< "$proposal_step"
# shellcheck disable=SC2016 # Match literal shell forwarding in action.yml.
grep -Fq 'ADOC_ISOLATED_ASSESSMENT="$ADOC_ISOLATED_ASSESSMENT"' <<< "$proposal_step"
# shellcheck disable=SC2016 # Match literal shell forwarding in action.yml.
grep -Fq 'GITHUB_EVENT_NAME="$GITHUB_EVENT_NAME"' <<< "$proposal_step"
if grep -Fq 'ADOC_PROPOSE_ELIGIBLE=true' <<< "$proposal_step" \
  || grep -Fq 'GITHUB_EVENT_NAME=pull_request' <<< "$proposal_step"; then
  echo 'proposal ingestion bypasses preflight eligibility' >&2
  exit 1
fi
grep -Fq '/usr/bin/env -i' "$ROOT/cloud-assessment/action.yml"
grep -Fq 'Cloud assessment submission remains capped at 1 MiB after base64 encoding' \
  "$ROOT/README.md"
grep -Fq 'GITHUB_EVENT_NAME=pull_request' "$ROOT/cloud-assessment/action.yml"
grep -Fq 'GITHUB_EVENT_NAME:-}" = workflow_run' \
  "$ROOT/scripts/stage-cloud-assessment.sh"
grep -Fq 'RUNNER_ENVIRONMENT:-}" = github-hosted' \
  "$ROOT/scripts/stage-cloud-assessment.sh"
if grep -Fq 'cloud-assessment-token:' "$ROOT/action.yml"; then
  echo 'raw assessment token is exposed to the pull-request Action' >&2
  exit 1
fi

echo 'Cloud assessment ingestion tests passed'
