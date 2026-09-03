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
      finding_id:"finding-001",classification:"consistent",
      affected_objects:[],citations:["hunk-1"],materiality:"immaterial",
      proposed_disposition:"no_change_required",candidate_updates:[],
      unresolved_questions:[],explanation:"No durable knowledge change."
    }]
  }' > "$semantic_assessment"
semantic_assessment_digest="sha256:$(sha256sum "$semantic_assessment" | awk '{print $1}')"
jq -cn --arg base "$ADOC_REQUESTED_BASE" --arg head "$ADOC_HEAD" \
  --arg digest "$assessment_digest" --arg semantic "$semantic_assessment_digest" \
  --arg graph "$graph_digest" '{
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
  ci:{provider:"github",repository:"agentdoc/test",pull_request:801,
    run_id:"202",run_attempt:3,job:"cloud_ingest",
    invocation_id:"inv_801_2_agentdoc_0123456789abcdef0123456789abcdef",
    actor:"alice",workload_identity:{provider:"github_actions",
    repository_id:"99",actor_id:"42",triggering_actor:"alice",
    workflow_ref:"agentdoc/test/.github/workflows/cloud-ingestion.yml@refs/heads/main",
    workflow_sha:("7" * 40)}}
}' > "$receipt"
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
    PATH=/usr/bin:/bin:/usr/sbin:/sbin \
    "$ROOT/scripts/stage-cloud-assessment.sh" 2> "$CASE_DIR/evidence-error"; then
    echo 'invalid semantic assessment unexpectedly staged' >&2
    exit 1
  fi
  grep -q 'not bound to the receipted assessment' "$CASE_DIR/evidence-error"
done
mv "$CASE_DIR/semantic-assessment.valid.json" "$semantic_assessment"
mv "$CASE_DIR/receipt.valid.json" "$receipt"
ASSESSMENT_PATH="$assessment" ASSESSMENT_RECEIPT_PATH="$receipt" \
  KNOWLEDGE_GRAPH_PATH="$graph" SEMANTIC_CONTEXT_PATH="$semantic_context" \
  SEMANTIC_ASSESSMENT_PATH="$semantic_assessment" \
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
test -f "$graph" && test -f "$semantic_context" && test -f "$semantic_assessment"
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
  --arg receipt "$receipt_digest" '
  keys == ["payload","schema_version"]
  and .schema_version == "agentdoc.cloud.assessment_submission.v0"
  and .payload.delivery_id == $delivery and .payload.repository_id == $repository
  and .payload.change_request == {system:"github_pull_request",id:"801"}
  and .payload.revision == {system:"git",base:$base,head:$head,lineage:[$head]}
  and .payload.assessment.schema_version == "adoc.change_assessment.v0"
  and .payload.assessment.digest == $assessment
  and .payload.receipt.schema_version == "adoc.pr_assessment_receipt.v4"
  and .payload.receipt.digest == $receipt
  and (.payload.evidence | keys == ["graph","semantic_assessment","semantic_context"])
  and .payload.evidence.graph.schema_version == "adoc.graph.v6"
  and (.payload.evidence.graph | keys == ["bytes_base64","digest","schema_version"])
  and .payload.evidence.semantic_context.schema_version == "adoc.semantic_context.v0"
  and (.payload.evidence.semantic_context | keys == ["bytes_base64","digest","schema_version"])
  and .payload.evidence.semantic_assessment.schema_version == "adoc.semantic_assessment.v0"
  and (.payload.evidence.semantic_assessment | keys == ["bytes_base64","digest","schema_version"])
' "$MOCK_CURL_BODY" >/dev/null
cmp "$assessment" <(jq -r .payload.assessment.bytes_base64 "$MOCK_CURL_BODY" | base64 --decode)
cmp "$receipt" <(jq -r .payload.receipt.bytes_base64 "$MOCK_CURL_BODY" | base64 --decode)
cmp "$graph" <(jq -r .payload.evidence.graph.bytes_base64 "$MOCK_CURL_BODY" | base64 --decode)
cmp "$semantic_context" <(jq -r .payload.evidence.semantic_context.bytes_base64 "$MOCK_CURL_BODY" | base64 --decode)
cmp "$semantic_assessment" <(jq -r .payload.evidence.semantic_assessment.bytes_base64 "$MOCK_CURL_BODY" | base64 --decode)
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

# The additive evidence member remains optional for legacy assessment uploads.
rm "$graph" "$semantic_context" "$semantic_assessment"
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
grep -Fq 'upload-cloud-assessment.sh" /usr/bin/curl' \
  "$ROOT/cloud-assessment/action.yml"
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
