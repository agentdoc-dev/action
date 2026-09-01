#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CASE_DIR="$(mktemp -d)"
trap 'rm -rf "$CASE_DIR"' EXIT
mkdir -p "$CASE_DIR/bin" "$CASE_DIR/private" "$CASE_DIR/retained"

export PATH="$CASE_DIR/bin:$PATH"
export ADOC_RUN_DIR="$CASE_DIR/private" ADOC_RETAINED_DIR="$CASE_DIR/retained"
export ADOC_INVOCATION_ID=inv_401_1_external_0123456789abcdef0123456789abcdef
export ADOC_HEAD=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa ADOC_PR_NUMBER=165
export GITHUB_REPOSITORY_ID=42 ADOC_PROPOSE_ELIGIBLE=true
export CLOUD_UPLOAD_URL=https://cloud.test/api/workspaces/10000000-0000-0000-0000-000000000401/external-work-results
export CLOUD_UPLOAD_TOKEN=workspace-upload-token-401
export GH_TOKEN=github-token ANTHROPIC_API_KEY=provider-token CLAUDE_CODE_OAUTH_TOKEN=''
export CLOUD_WORK_REQUEST="$CASE_DIR/work-request.json"
export MOCK_CURL_BODY="$CASE_DIR/upload-body.json" MOCK_CURL_CALLED="$CASE_DIR/curl-called"

assessment="$ADOC_RETAINED_DIR/assessment-$ADOC_INVOCATION_ID.json"
printf '%s\n' '{"schema_version":"adoc.change_assessment.v0","outcome":"review_required"}' > "$assessment"
printf '%s\n' "$assessment" > "$ADOC_RUN_DIR/assessment-path"
printf 'sha256:%s\n' "$(sha256sum "$assessment" | awk '{print $1}')" > "$ADOC_RUN_DIR/assessment-sha256"

write_request() {
  local version="${1:-adoc.work_request.v0}"
  jq -cnS --arg version "$version" --arg head "$ADOC_HEAD" '{
    schema_version:$version,request_id:"request-001",nonce:"request-nonce-001",
    workspace_id:"10000000-0000-0000-0000-000000000401",
    repository_id:"30000000-0000-0000-0000-000000000401",
    source:{provider:"github",external_repository_id:"42"},
    revision:{system:"git",value:$head},
    change_request:{system:"github_pull_request",id:"165"},
    contracts:[{schema_version:"adoc.semantic_assessment.v0"},{schema_version:"adoc.work_result.v0"}],
    capabilities:[{name:"code_change_assessment",version:"1"}],
    expires_at:"2099-08-26T12:00:00Z",
    workload:{principal_id:"20000000-0000-0000-0000-000000000401",
      subject:"repo:agentdoc-dev/adoc:environment:production",
      audience:"https://cloud.agentdoc.dev/work-results"}
  }' > "$CASE_DIR/request-without-digest.json"
  local canonical digest
  canonical="$(jq -cS . "$CASE_DIR/request-without-digest.json")"
  digest="sha256:$(printf %s "$canonical" | sha256sum | awk '{print $1}')"
  jq -cS --arg digest "$digest" '. + {request_digest:$digest}' \
    "$CASE_DIR/request-without-digest.json" > "$CLOUD_WORK_REQUEST"
}

cat > "$CASE_DIR/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[ "$1" = -q ]
touch "$MOCK_CURL_CALLED"
output=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    --output) output="$2"; shift 2 ;;
    --data-binary) cp "${2#@}" "$MOCK_CURL_BODY"; shift 2 ;;
    *) shift ;;
  esac
done
[ "${MOCK_CURL_FAIL:-false}" != true ] || exit 22
digest="$(jq -r .result.result_digest "$MOCK_CURL_BODY")"
jq -cn --arg digest "$digest" '{recorded:true,result_digest:$digest}' > "$output"
printf 201
EOF
chmod +x "$CASE_DIR/bin/curl"

status() { jq -c . "$ADOC_RUN_DIR/cloud-sync-status.json"; }
reset_case() {
  rm -f "$ADOC_RUN_DIR/cloud-sync-status.json" "$MOCK_CURL_BODY" "$MOCK_CURL_CALLED"
  unset MOCK_CURL_FAIL
  export CLOUD_UPLOAD_TOKEN=workspace-upload-token-401
}

write_request
assessment_before="$(sha256sum "$assessment")"
"$ROOT/scripts/upload-cloud-result.sh"
test "$(sha256sum "$assessment")" = "$assessment_before"
jq -e '
  .status == "completed" and .reason == "uploaded" and .reason_code == null
  and (.result_digest | test("^sha256:[0-9a-f]{64}$"))
' "$ADOC_RUN_DIR/cloud-sync-status.json" >/dev/null
jq -e --arg head "$ADOC_HEAD" --arg nonce "$ADOC_INVOCATION_ID" '
  .mode == "source_ci" and .key_id == null and .signature == null
  and .request.schema_version == "adoc.work_request.v0"
  and .result.schema_version == "adoc.work_result.v0"
  and .result.revision == {system:"git",value:$head}
  and .result.completion_nonce == $nonce
' "$MOCK_CURL_BODY" >/dev/null
result="$(jq -c .result "$MOCK_CURL_BODY")"
claimed="$(jq -r .result_digest <<< "$result")"
canonical="$(jq -cS 'del(.result_digest)' <<< "$result")"
test "$claimed" = "sha256:$(printf %s "$canonical" | sha256sum | awk '{print $1}')"
test "$(jq -r .result.output_digests.change_assessment "$MOCK_CURL_BODY")" \
  = "$(cat "$ADOC_RUN_DIR/assessment-sha256")"

reset_case
export MOCK_CURL_FAIL=true
"$ROOT/scripts/upload-cloud-result.sh"
test "$(sha256sum "$assessment")" = "$assessment_before"
jq -e '.status == "failed" and .reason == "upload_failed"
  and .reason_code == "action.cloud_sync_failed"
  and (.result_digest | test("^sha256:[0-9a-f]{64}$"))' \
  "$ADOC_RUN_DIR/cloud-sync-status.json" >/dev/null

reset_case
export CLOUD_UPLOAD_TOKEN="$GH_TOKEN"
"$ROOT/scripts/upload-cloud-result.sh"
test ! -e "$MOCK_CURL_CALLED"
jq -e '.status == "failed" and .reason == "credential_reuse"
  and .reason_code == "action.cloud_sync_failed"' \
  "$ADOC_RUN_DIR/cloud-sync-status.json" >/dev/null

reset_case
write_request
jq '.contracts |= reverse' "$CLOUD_WORK_REQUEST" \
  > "$CLOUD_WORK_REQUEST.tmp" && mv "$CLOUD_WORK_REQUEST.tmp" "$CLOUD_WORK_REQUEST"
"$ROOT/scripts/upload-cloud-result.sh"
test ! -e "$MOCK_CURL_CALLED"
jq -e '.status == "failed" and .reason == "invalid_request"' \
  "$ADOC_RUN_DIR/cloud-sync-status.json" >/dev/null

reset_case
write_request
jq '.request_digest = ("sha256:" + ("f" * 64))' "$CLOUD_WORK_REQUEST" \
  > "$CLOUD_WORK_REQUEST.tmp" && mv "$CLOUD_WORK_REQUEST.tmp" "$CLOUD_WORK_REQUEST"
"$ROOT/scripts/upload-cloud-result.sh"
test ! -e "$MOCK_CURL_CALLED"
jq -e '.status == "failed" and .reason == "request_digest_mismatch"
  and (.remediation | contains("Regenerate"))' \
  "$ADOC_RUN_DIR/cloud-sync-status.json" >/dev/null

reset_case
write_request adoc.work_request.v99
"$ROOT/scripts/upload-cloud-result.sh"
test ! -e "$MOCK_CURL_CALLED"
jq -e '.status == "failed" and .reason == "unsupported_version"
  and (.remediation | contains("adoc.work_request.v0"))' \
  "$ADOC_RUN_DIR/cloud-sync-status.json" >/dev/null

reset_case
write_request
rm "$assessment"
"$ROOT/scripts/upload-cloud-result.sh"
test ! -e "$MOCK_CURL_CALLED"
jq -e '.status == "failed" and .reason == "local_output_mismatch"
  and .reason_code == "action.cloud_sync_failed"' \
  "$ADOC_RUN_DIR/cloud-sync-status.json" >/dev/null

echo 'Cloud hand-off authenticity tests passed'
