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
export CLOUD_EGRESS_TOKEN=egress-policy-read-token-801
export MOCK_EGRESS_CURL="$CASE_DIR/trusted/egress-curl"
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

. "$ROOT/test/assessment-fixture.sh"
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
# E8.2.T2: the finalized delivery status and T1 block are staged digest-bound.
mkdir -p "$CASE_DIR/out"
delivered_commit=dddddddddddddddddddddddddddddddddddddddd
jq -n --arg head "$ADOC_HEAD" --arg commit "$delivered_commit" '{status:"complete",
  mode:"pr",reason:null,reason_code:null,remediation:null,assessed_head:$head,
  delivery_commit:$commit,branch:"adoc/proposals-801",
  url:"https://github.com/agentdoc/test/pull/802"}' > "$CASE_DIR/out/delivery-status.json"
# Finalize embeds the delivery status in the receipt; staging binds the two.
jq --slurpfile status "$CASE_DIR/out/delivery-status.json" '.delivery = $status[0]' \
  "$receipt" > "$CASE_DIR/receipt.delivery.json"
mv "$CASE_DIR/receipt.delivery.json" "$receipt"
receipt_digest="sha256:$(sha256sum "$receipt" | awk '{print $1}')"
cp "$ROOT/test/fixtures-proposal-references/v0.block.txt" \
  "$CASE_DIR/out/proposal-references-$ADOC_INVOCATION_ID.txt"
delivery_status_digest="sha256:$(sha256sum "$CASE_DIR/out/delivery-status.json" | awk '{print $1}')"
references_digest="sha256:$(sha256sum "$CASE_DIR/out/proposal-references-$ADOC_INVOCATION_ID.txt" | awk '{print $1}')"
stage_delivery() { # delivery-sha references-sha
  ASSESSMENT_PATH="$assessment" ASSESSMENT_RECEIPT_PATH="$receipt" \
    KNOWLEDGE_GRAPH_PATH="$graph" SEMANTIC_CONTEXT_PATH="$semantic_context" \
    SEMANTIC_ASSESSMENT_PATH="$semantic_assessment" \
    SEMANTIC_EXECUTOR_RECEIPT_PATH="$semantic_executor" \
    SEMANTIC_EXECUTOR_RECEIPT_SHA256="$semantic_executor_digest" \
    PROPOSAL_RECORD_PATH="$proposal" PROPOSAL_RECORD_SHA256="$proposal_digest" \
    DELIVERY_STATUS_PATH="$CASE_DIR/out/delivery-status.json" \
    DELIVERY_STATUS_SHA256="$1" \
    PROPOSAL_REFERENCES_PATH="$CASE_DIR/out/proposal-references-$ADOC_INVOCATION_ID.txt" \
    PROPOSAL_REFERENCES_SHA256="$2" PATH=/usr/bin:/bin:/usr/sbin:/sbin \
    "$ROOT/scripts/stage-cloud-assessment.sh"
}
for pair in "$references_digest $references_digest" "$delivery_status_digest $delivery_status_digest"; do
  : > "$GITHUB_ENV"
  # shellcheck disable=SC2086 # Two digests per pair.
  if stage_delivery $pair 2> "$CASE_DIR/evidence-error"; then
    echo 'delivery evidence with a foreign digest unexpectedly staged' >&2
    exit 1
  fi
  grep -q 'Delivery evidence is not bound to the finalized Action output' "$CASE_DIR/evidence-error"
  test ! -s "$GITHUB_ENV"
done
if DELIVERY_STATUS_PATH="$CASE_DIR/out/delivery-status.json" \
  ASSESSMENT_PATH="$assessment" ASSESSMENT_RECEIPT_PATH="$receipt" \
  PATH=/usr/bin:/bin:/usr/sbin:/sbin \
  "$ROOT/scripts/stage-cloud-assessment.sh" 2> "$CASE_DIR/evidence-error"; then
  echo 'delivery status without its digest unexpectedly staged' >&2
  exit 1
fi
grep -q 'delivery status path and SHA-256 must be supplied together' "$CASE_DIR/evidence-error"
# A delivery status rewritten after finalize is refused even with its own digest.
cp "$CASE_DIR/out/delivery-status.json" "$CASE_DIR/delivery-status.valid.json"
jq -c '.delivery_commit = "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"' \
  "$CASE_DIR/delivery-status.valid.json" > "$CASE_DIR/out/delivery-status.json"
: > "$GITHUB_ENV"
if stage_delivery "sha256:$(sha256sum "$CASE_DIR/out/delivery-status.json" | awk '{print $1}')" \
  "$references_digest" 2> "$CASE_DIR/evidence-error"; then
  echo 'delivery status diverging from the receipt unexpectedly staged' >&2
  exit 1
fi
grep -q 'does not match the delivery recorded in the receipt' "$CASE_DIR/evidence-error"
test ! -s "$GITHUB_ENV"
mv "$CASE_DIR/delivery-status.valid.json" "$CASE_DIR/out/delivery-status.json"
: > "$GITHUB_ENV"
stage_delivery "$delivery_status_digest" "$references_digest"
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

cat > "$MOCK_EGRESS_CURL" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[ "$1" = -q ]
output='' headers='' method='' config='' url=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    --output) output="$2"; shift 2 ;;
    --dump-header) headers="$2"; shift 2 ;;
    --request) method="$2"; shift 2 ;;
    --config) config="$2"; shift 2 ;;
    https://*) url="$1"; shift ;;
    *) shift ;;
  esac
done
[ "$method" = GET ] && [ "$config" = - ]
[ "$url" = 'https://cloud.test/api/v1/workspaces/10000000-0000-0000-0000-000000000801/egress-policies?repository_id=60000000-0000-0000-0000-000000000801&source_provider=github&external_repository_id=99' ]
[ "$(cat)" = "header = \"Authorization: Bearer $CLOUD_EGRESS_TOKEN\"" ]
jq -cn '{schema_version:"agentdoc.cloud.egress_policy.v0",payload:{
  scope:{workspace_id:"10000000-0000-0000-0000-000000000801",
    resource:{kind:"repository",id:"60000000-0000-0000-0000-000000000801"}},
  categories:{raw_source:true,source_excerpts:true,pr_diffs:true,compiled_objects:true,
    embeddings:true,semantic_assessments:true,audit_metadata:true}}}
  | if env.MOCK_EGRESS_DISABLED then .payload.categories[env.MOCK_EGRESS_DISABLED] = false else . end' > "$output"
printf 'HTTP/1.1 200 OK\r\nx-agentdoc-egress-policy-digest: sha256:%s\r\n\r\n' \
  "$(sha256sum "$output" | awk '{print $1}')" > "$headers"
printf 200
EOF
chmod +x "$MOCK_EGRESS_CURL"

cat > "$CASE_DIR/trusted/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[ "${1:-}" = -q ] || exit 96
if [[ " $* " == *" --request GET "* ]]; then
  exec "$MOCK_EGRESS_CURL" "$@"
fi
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
  export CLOUD_EGRESS_TOKEN=egress-policy-read-token-801
  export MOCK_EGRESS_CURL="$CASE_DIR/trusted/egress-curl"
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
if [[ " $* " == *" --request GET "* ]]; then
  exec "$MOCK_EGRESS_CURL" "$@"
fi
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

# E8.2.T2 Task D: the finalized delivery is reported to a mocked
# proposal-deliveries endpoint with exact bytes and key; Cloud never alters Git.
test "$(cat "$ADOC_RUN_DIR/delivery-status-sha256")" = "$delivery_status_digest"
test "$(cat "$ADOC_RUN_DIR/proposal-references-sha256")" = "$references_digest"
retained_delivery="$ADOC_RETAINED_DIR/delivery-status-$ADOC_INVOCATION_ID.json"
retained_references="$ADOC_RETAINED_DIR/proposal-references-$ADOC_INVOCATION_ID.txt"
cmp "$retained_references" "$ROOT/test/fixtures-proposal-references/v0.block.txt"
reset_case
"$ROOT/scripts/upload-cloud-assessment.sh" "$CASE_DIR/trusted/curl"
export GITHUB_EVENT_NAME=workflow_run
unset MOCK_PROPOSAL_DISPOSITION MOCK_PROPOSAL_ERROR_CODE MOCK_PROPOSAL_REPLAYED
"$ROOT/scripts/upload-cloud-proposal.sh" "$CASE_DIR/trusted/proposal-curl"
jq -e '.status == "completed"' "$proposal_status" >/dev/null
export PROPOSAL_VERSION_ID=71000000-0000-0000-0000-000000000801 PROJECT_PREFIX=docs/
export MOCK_DELIVERY_DIR="$CASE_DIR/delivery-calls"
cat > "$CASE_DIR/trusted/delivery-curl" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
[ "${1:-}" = -q ] || exit 96
if [[ " $* " == *" --request GET "* ]]; then
  exec "$MOCK_EGRESS_CURL" "$@"
fi
mkdir -p "$MOCK_DELIVERY_DIR"
n=$(( $(find "$MOCK_DELIVERY_DIR" -name 'body.*' | wc -l) + 1 ))
output='' headers='' url=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    --config) cp "$2" "$MOCK_DELIVERY_DIR/config.$n"; shift 2 ;;
    --output) output="$2"; shift 2 ;;
    --dump-header) headers="$2"; shift 2 ;;
    --data-binary) cp "${2#@}" "$MOCK_DELIVERY_DIR/body.$n"; shift 2 ;;
    https://*) url="$1"; shift ;;
    *) shift ;;
  esac
done
[ "$url" = https://cloud.test/api/v1/workspaces/10000000-0000-0000-0000-000000000801/proposal-deliveries ] || exit 95
mode="${MOCK_DELIVERY_MODE:-accepted}"
if [ "$mode" = unavailable_once ]; then
  if [ "$n" -eq 1 ]; then mode=unavailable; else mode=accepted; fi
fi
if [ "$mode" = unavailable_slow_once ]; then
  if [ "$n" -eq 1 ]; then mode=unavailable_slow; else mode=accepted; fi
fi
case "$mode" in
  unavailable)
    printf 'HTTP/1.1 503 Service Unavailable\r\nretry-after: 0\r\n\r\n' > "$headers"
    printf '{"error":{"code":"delivery.provider_unavailable"}}' > "$output"
    printf 503 ;;
  unavailable_slow)
    printf 'HTTP/1.1 503 Service Unavailable\r\nretry-after: 99\r\n\r\n' > "$headers"
    printf '{"error":{"code":"delivery.provider_unavailable"}}' > "$output"
    printf 503 ;;
  unavailable_other)
    printf 'HTTP/1.1 503 Service Unavailable\r\nretry-after: 0\r\n\r\n' > "$headers"
    printf '{"error":{"code":"api.unavailable"}}' > "$output"
    printf 503 ;;
  duplicate_refused)
    printf 'HTTP/1.1 200 OK\r\n\r\n' > "$headers"
    printf '{"schema_version":"agentdoc.cloud.ingestion_result.v0","payload":{"status":"duplicate","code":"ingest.duplicate_delivery","delivery_id":"72000000-0000-0000-0000-000000000801","original_code":"delivery.reference_stale","request_id":"40000000-0000-0000-0000-000000000803"}}' > "$output"
    printf 200 ;;
  duplicate_rejected)
    printf 'HTTP/1.1 422 Unprocessable\r\n\r\n' > "$headers"
    printf '{"error":{"code":"ingest.duplicate_delivery"}}' > "$output"
    printf 422 ;;
  stale)
    printf 'HTTP/1.1 422 Unprocessable\r\n\r\n' > "$headers"
    printf '{"error":{"code":"delivery.reference_stale"}}' > "$output"
    printf 422 ;;
  duplicate)
    printf 'HTTP/1.1 200 OK\r\n\r\n' > "$headers"
    printf '{"schema_version":"agentdoc.cloud.ingestion_result.v0","payload":{"status":"duplicate","code":"ingest.duplicate_delivery","delivery_id":"72000000-0000-0000-0000-000000000801","original_code":null,"request_id":"40000000-0000-0000-0000-000000000803"}}' > "$output"
    printf 200 ;;
  accepted_200)
    printf 'HTTP/1.1 200 OK\r\n\r\n' > "$headers"
    printf '{"schema_version":"agentdoc.cloud.ingestion_result.v0","payload":{"status":"accepted","code":null,"delivery_id":"72000000-0000-0000-0000-000000000801","original_code":null,"request_id":"40000000-0000-0000-0000-000000000803"}}' > "$output"
    printf 200 ;;
  accepted)
    printf 'HTTP/1.1 202 Accepted\r\n\r\n' > "$headers"
    printf '{"schema_version":"agentdoc.cloud.ingestion_result.v0","payload":{"status":"accepted","code":null,"delivery_id":"72000000-0000-0000-0000-000000000801","original_code":null,"request_id":"40000000-0000-0000-0000-000000000803"}}' > "$output"
    printf 202 ;;
esac
MOCK
chmod +x "$CASE_DIR/trusted/delivery-curl"
delivery_state="$ADOC_RUN_DIR/cloud-proposal-delivery-status.json"
run_delivery() {
  rm -rf "$MOCK_DELIVERY_DIR"
  : > "$GITHUB_OUTPUT"
  "$ROOT/scripts/upload-cloud-proposal-delivery.sh" "$CASE_DIR/trusted/delivery-curl" \
    2> "$CASE_DIR/delivery-stderr"
}
calls() { find "$MOCK_DELIVERY_DIR" -name 'body.*' 2>/dev/null | wc -l | tr -d ' '; }
receipt_sha="$(cat "$ADOC_RUN_DIR/receipt-sha256")"
expected_delivery() { # mode number block-file digest
  jq -cn --arg pr "$ADOC_PR_NUMBER" --arg set "$proposal_set_digest" \
    --arg receipt "$receipt_sha" --arg head "$ADOC_HEAD" --arg mode "$1" \
    --arg commit "$delivered_commit" --argjson number "$2" --rawfile block "$3" \
    --arg digest "$4" '{schema_version:"agentdoc.cloud.proposal_delivery.v0",
    repository:{provider:"github",external_repository_id:"99"},
    change_request:{system:"github_pull_request",id:$pr},
    proposal_version_id:"71000000-0000-0000-0000-000000000801",
    proposal_set_digest:$set,assessment_receipt_digest:$receipt,
    assessed_head_sha:$head,project_prefix:"docs/",mode:$mode,
    delivered_commit_sha:$commit,knowledge_pull_request_number:$number,
    references_block:(if $mode == "pr" then $block else null end),
    references_block_digest:(if $mode == "pr" then $digest else null end)}'
}
expected_key() { # body file; Cloud route formula
  printf 'sha256:%s' "$(printf '%s\nsha256:%s' "$proposal_set_digest" \
    "$(sha256sum "$1" | awk '{print $1}')" | sha256sum | awk '{print $1}')"
}
# pr mode: exact bytes, exact key, token only in the removed curl config.
run_delivery
test "$(calls)" -eq 1
expected_delivery pr 802 "$retained_references" "$references_digest" \
  > "$CASE_DIR/delivery-expected.json"
cmp "$CASE_DIR/delivery-expected.json" "$MOCK_DELIVERY_DIR/body.1"
jq -e --rawfile block "$ROOT/test/fixtures-proposal-references/v0.block.txt" \
  '.references_block == $block' "$MOCK_DELIVERY_DIR/body.1" >/dev/null
delivery_key="$(expected_key "$MOCK_DELIVERY_DIR/body.1")"
grep -Fqx "header = \"Idempotency-Key: $delivery_key\"" "$MOCK_DELIVERY_DIR/config.1"
grep -Fqx "header = \"Authorization: Bearer $CLOUD_PROPOSAL_TOKEN\"" \
  "$MOCK_DELIVERY_DIR/config.1"
grep -Eqx 'header = "X-Agentdoc-Egress-Policy-Digest: sha256:[0-9a-f]{64}"' \
  "$MOCK_DELIVERY_DIR/config.1"
jq -e --arg key "$delivery_key" '.status == "completed" and .disposition == "accepted"
  and .code == null and .idempotency_key == $key
  and .delivery_id == "72000000-0000-0000-0000-000000000801"' "$delivery_state" >/dev/null
test ! -e "$ADOC_RUN_DIR/cloud-proposal-delivery-curl.conf"
if grep -rFq "$CLOUD_PROPOSAL_TOKEN" "$ADOC_RUN_DIR" "$ADOC_RETAINED_DIR" \
  "$GITHUB_OUTPUT" "$CASE_DIR/delivery-stderr"; then
  echo 'proposal delivery token leaked outside the curl config' >&2
  exit 1
fi
# 503 before registration: one bounded retry of the identical bytes and key.
MOCK_DELIVERY_MODE=unavailable_once run_delivery
test "$(calls)" -eq 2
cmp "$MOCK_DELIVERY_DIR/body.1" "$MOCK_DELIVERY_DIR/body.2"
# The retry is the identical request under a new transmission attempt id.
cmp <(grep -v '^header = "X-Request-ID: ' "$MOCK_DELIVERY_DIR/config.1") \
  <(grep -v '^header = "X-Request-ID: ' "$MOCK_DELIVERY_DIR/config.2")
if cmp -s "$MOCK_DELIVERY_DIR/config.1" "$MOCK_DELIVERY_DIR/config.2"; then exit 1; fi
test "$(find "$ADOC_RUN_DIR/cloud-egress-attempts" -name '*.json' -exec jq -r .operation {} + | grep -c '^proposal_delivery$')" -ge 2
cmp "$CASE_DIR/delivery-expected.json" "$MOCK_DELIVERY_DIR/body.1"
jq -e '.status == "completed" and .disposition == "accepted"' "$delivery_state" >/dev/null
# Only the final attempt carries the business outcome; the retried 503 does not.
jq -s -e '[.[] | select(.operation == "proposal_delivery")]
  | (map(select(.http_status == 503)) | length == 1 and all(.business_status == null))
  and (map(select(.http_status == 202)) | length >= 1
    and all(.business_status == "completed" and .business_disposition == "accepted"))' \
  "$ADOC_RUN_DIR"/cloud-egress-attempts/*.json >/dev/null
MOCK_DELIVERY_MODE=unavailable run_delivery
test "$(calls)" -eq 2
jq -e --arg key "$delivery_key" '.status == "failed"
  and .code == "delivery.provider_unavailable" and .idempotency_key == $key
  and .remediation != null' "$delivery_state" >/dev/null
grep -Fq 'The Git delivery is unchanged' "$CASE_DIR/delivery-stderr"
MOCK_DELIVERY_MODE=stale run_delivery
jq -e '.status == "failed" and .code == "delivery.reference_stale"' "$delivery_state" >/dev/null
# Only 202 accepted or 200 duplicate is success; any other pairing is a sync failure.
MOCK_DELIVERY_MODE=duplicate run_delivery
jq -e '.status == "completed" and .code == "ingest.duplicate_delivery"' "$delivery_state" >/dev/null
MOCK_DELIVERY_MODE=accepted_200 run_delivery
jq -e '.status == "failed" and .code == "action.cloud_sync_failed"' "$delivery_state" >/dev/null
# Cloud checks all seven categories for every operation; any disabled one keeps the report local.
MOCK_EGRESS_DISABLED=embeddings MOCK_DELIVERY_MODE=accepted run_delivery
test "$(calls)" -eq 0
jq -e '.status == "skipped" and .code == "egress.category_disabled"' "$delivery_state" >/dev/null
MOCK_DELIVERY_MODE=duplicate_rejected run_delivery
jq -e '.status == "failed" and .code == "ingest.duplicate_delivery"' "$delivery_state" >/dev/null
# A replayed refusal reports the original code, never completion.
MOCK_DELIVERY_MODE=duplicate_refused run_delivery
jq -e '.status == "failed" and .code == "delivery.reference_stale"' "$delivery_state" >/dev/null
# Only delivery.provider_unavailable is retried.
MOCK_DELIVERY_MODE=unavailable_other run_delivery
test "$(calls)" -eq 1
jq -e '.status == "failed" and .code == "action.cloud_sync_failed"' "$delivery_state" >/dev/null
# Retry-After is capped at 30 s.
mkdir -p "$CASE_DIR/fake-sleep"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$1" >> "%s"\n' "$CASE_DIR/sleep-args" \
  > "$CASE_DIR/fake-sleep/sleep"
chmod +x "$CASE_DIR/fake-sleep/sleep"
PATH="$CASE_DIR/fake-sleep:$PATH" MOCK_DELIVERY_MODE=unavailable_slow_once run_delivery
test "$(calls)" -eq 2
test "$(cat "$CASE_DIR/sleep-args")" = 30
jq -e '.status == "completed"' "$delivery_state" >/dev/null
# A digest mismatch on either staged file refuses before any request.
for staged in "$retained_delivery" "$retained_references"; do
  cp "$staged" "$CASE_DIR/staged.valid"
  printf '\n' >> "$staged"
  run_delivery
  test "$(calls)" -eq 0
  jq -e '.status == "failed" and .code == "ingest.digest_mismatch"' "$delivery_state" >/dev/null
  mv "$CASE_DIR/staged.valid" "$staged"
done
# Ineligible or disconnected runs make zero requests.
for case_env in ADOC_PROPOSE_ELIGIBLE=false ADOC_ISOLATED_ASSESSMENT=false \
  GITHUB_EVENT_NAME=pull_request CLOUD_PROPOSAL_URL= CLOUD_PROPOSAL_TOKEN=; do
  rm -rf "$MOCK_DELIVERY_DIR"
  env "$case_env" "$ROOT/scripts/upload-cloud-proposal-delivery.sh" \
    "$CASE_DIR/trusted/delivery-curl" 2>/dev/null
  test "$(calls)" -eq 0
  jq -e '.status == "skipped" and (.reason | IN("ineligible","disconnected"))' \
    "$delivery_state" >/dev/null
done
# Incomplete delivery or no proposal record: typed skip, zero requests.
set_delivery() { # jq filter over the finalized delivery status
  jq -c "$1" "$CASE_DIR/out/delivery-status.json" > "$retained_delivery"
  printf 'sha256:%s\n' "$(sha256sum "$retained_delivery" | awk '{print $1}')" \
    > "$ADOC_RUN_DIR/delivery-status-sha256"
}
set_delivery '.status = "skipped" | .delivery_commit = null'
run_delivery
test "$(calls)" -eq 0
jq -e '.status == "skipped" and .reason == "delivery_incomplete"' "$delivery_state" >/dev/null
set_delivery '.'
mv "$ADOC_RUN_DIR/proposal-record-sha256" "$CASE_DIR/proposal-record-sha256.valid"
run_delivery
test "$(calls)" -eq 0
jq -e '.status == "skipped" and .reason == "no_proposal_record"' "$delivery_state" >/dev/null
mv "$CASE_DIR/proposal-record-sha256.valid" "$ADOC_RUN_DIR/proposal-record-sha256"
# commit mode: no knowledge PR and no block.
set_delivery '.mode = "commit" | .url = null | .branch = "feature"'
run_delivery
test "$(calls)" -eq 1
expected_delivery commit null /dev/null '' > "$CASE_DIR/delivery-expected.json"
cmp "$CASE_DIR/delivery-expected.json" "$MOCK_DELIVERY_DIR/body.1"
grep -Fqx "header = \"Idempotency-Key: $(expected_key "$MOCK_DELIVERY_DIR/body.1")\"" \
  "$MOCK_DELIVERY_DIR/config.1"
jq -e '.status == "completed" and .disposition == "accepted"' "$delivery_state" >/dev/null
# pr mode without a staged block refuses before any request.
set_delivery '.'
mv "$ADOC_RUN_DIR/proposal-references-sha256" "$CASE_DIR/references-sha256.valid"
run_delivery
test "$(calls)" -eq 0
jq -e '.status == "failed"' "$delivery_state" >/dev/null
mv "$CASE_DIR/references-sha256.valid" "$ADOC_RUN_DIR/proposal-references-sha256"
# E8.2.T5 connected end-to-end: deliver.sh + publish (T1 producer, from
# delivery.sh's fixture) -> mocked T2 endpoint. The commit trailer and PR body
# carry the D6 resolver URL for the exact digest Cloud was sent.
e2e="$CASE_DIR/e2e"
mkdir -p "$e2e"
e2e_resolver=https://cloud.test/workspaces/10000000-0000-0000-0000-000000000801
DELIVERY_EXPORT="$e2e" DELIVERY_EXPORT_RESOLVER="$e2e_resolver" \
  bash "$ROOT/test/delivery.sh"
cp "$e2e/delivery-status.json" "$retained_delivery"
cp "$e2e"/proposal-references-*.txt "$retained_references"
for pair in "$retained_delivery delivery-status-sha256" \
  "$retained_references proposal-references-sha256"; do
  set -- $pair
  printf 'sha256:%s\n' "$(sha256sum "$1" | awk '{print $1}')" > "$ADOC_RUN_DIR/$2"
done
# The mocked Cloud proposal ingestion returns the Action-computed set digest.
jq --arg set "$(jq -r .sha256 "$e2e/proposal-status.json")" \
  '.proposal_set_digest = $set' "$ADOC_RUN_DIR/cloud-proposal-status.json" > "$e2e/p"
mv "$e2e/p" "$ADOC_RUN_DIR/cloud-proposal-status.json"
unset MOCK_DELIVERY_MODE
ADOC_HEAD="$(jq -r .assessed_head "$retained_delivery")" run_delivery
jq -e '.status == "completed" and .disposition == "accepted"' "$delivery_state" >/dev/null
e2e_url="$e2e_resolver/proposals/$(jq -r '.proposal_set_digest | ltrimstr("sha256:")' \
  "$MOCK_DELIVERY_DIR/body.1")"
[[ "$e2e_url" =~ /proposals/[0-9a-f]{64}$ ]]
grep -Fqx "AgentDoc-Cloud-Proposal: $e2e_url" "$e2e/commit-message"
grep -Fqx -- "- [Cloud proposal]($e2e_url)" "$e2e/delivery-pr-body"
# The report links the same URL, only for a complete connected delivery.
e2e_report() { # resolver delivery-status-filter
  local out="$e2e/compose"
  rm -rf "$out" && mkdir -p "$out/out" "$out/retained"
  cp "$ROOT/test/fixture-assessment.json" "$out/retained/assessment.json"
  printf '%s\n' "$out/retained/assessment.json" > "$out/out/assessment-path"
  printf 'sha256:%064d\n' 9 > "$out/out/receipt-sha256"
  cp "$e2e/proposal-status.json" "$out/out/proposal-status.json"
  jq "$2" "$e2e/delivery-status.json" > "$out/out/delivery-status.json"
  env ADOC_RUN_DIR="$out/out" ADOC_RETAINED_DIR="$out/retained" \
    ADOC_INVOCATION_ID=e2e ADOC_HEAD="$(jq -r .assessed_head "$e2e/delivery-status.json")" \
    GITHUB_SERVER_URL=https://github.com GITHUB_REPOSITORY=agentdoc/test \
    GITHUB_RUN_ID=1 ADOC_ACTION_REF=e2e PROPOSE=true PROPOSE_DELIVERY=pr \
    REPORT_STYLE=compact ENFORCEMENT=advisory SCOPE=full ADOC_VERSION=v0.3.4 \
    CLOUD_PROPOSAL_RESOLVER="$1" "$ROOT/scripts/compose.sh" > /dev/null
  cat "$out/out/report.md"
}
report="$(e2e_report "$e2e_resolver" .)"
grep -Fq "[Cloud proposal]($e2e_url)" <<< "$report"
for filter in '.status = "error"' '.status = "partial"'; do
  report="$(e2e_report "$e2e_resolver" "$filter")"
  [[ "$report" == *"Knowledge proposal"* && "$report" != *"Cloud proposal"* ]]
done
report="$(e2e_report '' .)"
[[ "$report" == *"Follow-up pull request created"* && "$report" != *"Cloud proposal"* ]]
unset PROPOSAL_VERSION_ID PROJECT_PREFIX
delivery_step="$(sed -n '/- name: Report exact proposal delivery to Cloud/,/upload-cloud-proposal-delivery.sh/p' \
  "$ROOT/cloud-assessment/action.yml")"
# shellcheck disable=SC2016 # Match literal expressions in action.yml.
grep -Fq 'PROPOSAL_VERSION_ID: ${{ steps.proposal.outputs.proposal-version-id }}' <<< "$delivery_step"
grep -Fq '/usr/bin/env -i' <<< "$delivery_step"
# shellcheck disable=SC2016 # Match literal shell forwarding in action.yml.
grep -Fq 'ADOC_PROPOSE_ELIGIBLE="$ADOC_PROPOSE_ELIGIBLE"' <<< "$delivery_step"
if grep -Fq 'ADOC_PROPOSE_ELIGIBLE=true' <<< "$delivery_step"; then
  echo 'delivery report bypasses preflight eligibility' >&2
  exit 1
fi
# The delivery step runs after the proposal step.
test "$(grep -n 'id: proposal$' "$ROOT/cloud-assessment/action.yml" | cut -d: -f1)" \
  -lt "$(grep -n 'id: proposal-delivery$' "$ROOT/cloud-assessment/action.yml" | cut -d: -f1)"
grep -Fq 'DELIVERY_STATUS_SHA256:' "$ROOT/cloud-assessment/action.yml"
grep -Fq 'PROPOSAL_REFERENCES_SHA256:' "$ROOT/cloud-assessment/action.yml"

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
