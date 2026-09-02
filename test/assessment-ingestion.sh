#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CASE_DIR="$(mktemp -d)"
trap 'rm -rf "$CASE_DIR"' EXIT
mkdir -p "$CASE_DIR/bin" "$CASE_DIR/private" "$CASE_DIR/retained" \
  "$CASE_DIR/trusted"

export PATH="$CASE_DIR/bin:$PATH"
export ADOC_RUN_DIR="$CASE_DIR/private" ADOC_RETAINED_DIR="$CASE_DIR/retained"
export ADOC_INVOCATION_ID=inv_801_2_agentdoc_0123456789abcdef0123456789abcdef
export ADOC_REQUESTED_BASE=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
export ADOC_HEAD=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
export ADOC_PR_NUMBER=801 ADOC_PROPOSE_ELIGIBLE=true GITHUB_EVENT_NAME=pull_request
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

assessment="$ADOC_RETAINED_DIR/assessment-$ADOC_INVOCATION_ID.json"
receipt="$ADOC_RETAINED_DIR/receipt-$ADOC_INVOCATION_ID.json"
jq -cn --arg base "$ADOC_REQUESTED_BASE" --arg head "$ADOC_HEAD" '{
  schema_version:"adoc.change_assessment.v0",completeness:"complete",outcome:"pass",
  snapshots:{requested_base:{resolved_commit:$base},head:{resolved_commit:$head}}
}' > "$assessment"
assessment_digest="sha256:$(sha256sum "$assessment" | awk '{print $1}')"
jq -cn --arg base "$ADOC_REQUESTED_BASE" --arg head "$ADOC_HEAD" \
  --arg digest "$assessment_digest" '{
  schema_version:"adoc.pr_assessment_receipt.v4",run_status:"completed",
  revisions:{requested_base:$base,comparison_base:$base,head:$head},
  assessment:{schema_version:"adoc.change_assessment.v0",sha256:$digest,
    completeness:"complete",outcome:"pass"},
  ci:{run_id:"101",run_attempt:2,job:"agentdoc",workload_identity:{
    workflow_ref:"agentdoc-dev/adoc/.github/workflows/assessment.yml@refs/pull/801/merge",
    workflow_sha:("7" * 40)}}
}' > "$receipt"
receipt_digest="sha256:$(sha256sum "$receipt" | awk '{print $1}')"
printf '%s\n' "$assessment" > "$ADOC_RUN_DIR/assessment-path"
printf '%s\n' "$assessment_digest" > "$ADOC_RUN_DIR/assessment-sha256"
printf '%s\n' "$receipt_digest" > "$ADOC_RUN_DIR/receipt-sha256"

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
' "$MOCK_CURL_BODY" >/dev/null
cmp "$assessment" <(jq -r .payload.assessment.bytes_base64 "$MOCK_CURL_BODY" | base64 --decode)
cmp "$receipt" <(jq -r .payload.receipt.bytes_base64 "$MOCK_CURL_BODY" | base64 --decode)
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

finalize_line="$(grep -n -- '- name: Finalize assessment receipt' "$ROOT/action.yml" | cut -d: -f1)"
submit_line="$(grep -n -- '- name: Submit finalized assessment and receipt to Cloud' \
  "$ROOT/action.yml" | cut -d: -f1)"
test "$finalize_line" -lt "$submit_line"
if sed -n "${submit_line},$((submit_line + 8))p" "$ROOT/action.yml" \
  | grep -Fq 'ADOC_ASSESSMENT_VALID'; then
  echo 'configured Cloud ingestion is still skipped before fail-honest status emission' >&2
  exit 1
fi
grep -Fq 'cloud-assessment-url:' "$ROOT/action.yml"
grep -Fq 'cloud-assessment-submission-path:' "$ROOT/action.yml"
grep -Fq 'upload-cloud-assessment.sh" /usr/bin/curl' "$ROOT/action.yml"
test "$(grep -Fc 'PATH: /usr/bin:/bin:/usr/sbin:/sbin' "$ROOT/action.yml")" -eq 2

echo 'Cloud assessment ingestion tests passed'
