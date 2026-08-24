#!/usr/bin/env bash
# Builds one source_ci work result and uploads it without changing local gate state.
set -euo pipefail

OUT="${ADOC_RUN_DIR:-$RUNNER_TEMP}"
status_file="$OUT/cloud-sync-status.json"
result_file="$ADOC_RETAINED_DIR/external-work-result-${ADOC_INVOCATION_ID}.json"

write_status() { # status, reason, reason code, result digest, remediation
  jq -cn --arg status "$1" --arg reason "$2" --arg code "$3" \
    --arg digest "$4" --arg remediation "$5" '{
      status:$status,reason:$reason,
      reason_code:(if $code == "" then null else $code end),
      result_digest:(if $digest == "" then null else $digest end),
      remediation:(if $remediation == "" then null else $remediation end)
    }' > "$status_file.tmp"
  mv "$status_file.tmp" "$status_file"
}
fail_sync() {
  write_status failed "$1" action.cloud_sync_failed "${2:-}" "$3"
  echo "::warning::action.cloud_sync_failed: $3" >&2
  exit 0
}

if [ "${ADOC_PROPOSE_ELIGIBLE:-false}" != true ]; then
  write_status skipped untrusted_change '' '' \
    'Use the protected-base trusted workflow for fork or Dependabot results.'
  exit 0
fi

request_file="${CLOUD_WORK_REQUEST:-}"
upload_url="${CLOUD_UPLOAD_URL:-}"
upload_token="${CLOUD_UPLOAD_TOKEN:-}"
[ -f "$request_file" ] \
  || fail_sync request_unavailable '' 'Provide a readable adoc.work_request.v0 file.'
[[ "$upload_url" =~ ^https://[^[:space:]]+$ ]] \
  || fail_sync invalid_upload_url '' 'Use the exact HTTPS Workspace result endpoint.'
for credential in "${GH_TOKEN:-}" "${ANTHROPIC_API_KEY:-}" "${CLAUDE_CODE_OAUTH_TOKEN:-}"; do
  [ -z "$credential" ] || [ "$upload_token" != "$credential" ] \
    || fail_sync credential_reuse '' 'Use a Workspace upload credential distinct from GitHub and provider credentials.'
done
[[ "$upload_token" =~ ^[A-Za-z0-9._~-]+$ ]] \
  && [ "${#upload_token}" -ge 16 ] && [ "${#upload_token}" -le 512 ] \
  || fail_sync invalid_upload_credential '' 'Issue a new scoped, expiring Workspace upload credential.'

version="$(jq -r '.schema_version // empty' "$request_file" 2>/dev/null || true)"
[ "$version" = adoc.work_request.v0 ] \
  || fail_sync unsupported_version '' 'Use adoc.work_request.v0 and regenerate the request.'

if ! jq -e '
  def text: type == "string" and test("^\\S(?:.*\\S)?$");
  type == "object"
  and keys == ["capabilities","change_request","contracts","expires_at","nonce",
    "repository_id","request_digest","request_id","revision","schema_version",
    "source","workload","workspace_id"]
  and ([.request_id,.nonce,.workspace_id,.repository_id,.expires_at,
    .source.provider,.source.external_repository_id,.revision.system,.revision.value,
    .change_request.system,.change_request.id,.workload.principal_id,
    .workload.subject,.workload.audience] | all(text))
  and (.source | keys == ["external_repository_id","provider"])
  and (.revision | keys == ["system","value"])
  and (.change_request | keys == ["id","system"])
  and (.workload | keys == ["audience","principal_id","subject"])
  and (.contracts | type == "array" and length > 0
    and all(.[]; type == "object" and keys == ["schema_version"]
      and (.schema_version | text)))
  and (.capabilities | type == "array" and length > 0
    and all(.[]; type == "object" and keys == ["name","version"]
      and (.name | text) and (.version | text)))
  and ([.contracts[].schema_version] | unique | length) == (.contracts | length)
  and ([.capabilities[] | [.name,.version]] | unique | length) == (.capabilities | length)
  and (.expires_at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")
    and fromdateiso8601 > now)
  and (.request_digest | test("^sha256:[0-9a-f]{64}$"))
' "$request_file" >/dev/null 2>&1; then
  fail_sync invalid_request '' 'Regenerate a complete, unexpired adoc.work_request.v0 envelope.'
fi

canonical_request="$(jq -c '{
  schema_version,request_id,nonce,workspace_id,repository_id,source,revision,
  change_request,contracts:(.contracts|sort_by(.schema_version)),
  capabilities:(.capabilities|sort_by(.name,.version)),expires_at,workload
}' "$request_file")"
claimed_request_digest="$(jq -r .request_digest "$request_file")"
actual_request_digest="sha256:$(printf %s "$canonical_request" | sha256sum | awk '{print $1}')"
[ "$claimed_request_digest" = "$actual_request_digest" ] \
  || fail_sync request_digest_mismatch '' 'Regenerate the request digest from the canonical adoc.work_request.v0 content.'

if ! jq -e --arg head "${ADOC_HEAD:-}" --arg pr "${ADOC_PR_NUMBER:-}" \
  --arg repository_id "${GITHUB_REPOSITORY_ID:-}" '
    .source == {provider:"github",external_repository_id:$repository_id}
    and .revision == {system:"git",value:$head}
    and .change_request == {system:"github_pull_request",id:$pr}
    and any(.contracts[]; .schema_version == "adoc.work_result.v0")
  ' "$request_file" >/dev/null; then
  fail_sync request_binding_mismatch '' \
    'Issue the request for this authenticated repository ID, pull request, and exact head revision.'
fi
[ "$(jq -r .nonce "$request_file")" != "$ADOC_INVOCATION_ID" ] \
  || fail_sync completion_nonce_reused '' 'Issue a request nonce distinct from this Action invocation.'

assessment_path="$(cat "$OUT/assessment-path" 2>/dev/null || true)"
assessment_digest="$(cat "$OUT/assessment-sha256" 2>/dev/null || true)"
actual_assessment_digest="sha256:$(sha256sum "$assessment_path" 2>/dev/null | awk '{print $1}')"
[ -f "$assessment_path" ] && [ "$assessment_digest" = "$actual_assessment_digest" ] \
  || fail_sync local_output_mismatch '' 'Rerun the local assessment before Cloud hand-off.'

result_without_digest="$(jq -cn --arg request_id "$(jq -r .request_id "$request_file")" \
  --arg request_digest "$claimed_request_digest" \
  --arg workspace_id "$(jq -r .workspace_id "$request_file")" \
  --arg repository_id "$(jq -r .repository_id "$request_file")" \
  --argjson revision "$(jq -c .revision "$request_file")" \
  --arg completion_nonce "$ADOC_INVOCATION_ID" \
  --argjson worker "$(jq -c .workload "$request_file")" \
  --arg runtime_version "${ADOC_ACTION_REF:-local}" \
  --arg assessment_digest "$assessment_digest" '{
    schema_version:"adoc.work_result.v0",request_id:$request_id,
    request_digest:$request_digest,workspace_id:$workspace_id,
    repository_id:$repository_id,revision:$revision,completion_nonce:$completion_nonce,
    worker:$worker,runtime:{name:"agentdoc-dev/action",version:$runtime_version},
    output_digests:{change_assessment:$assessment_digest}
  }')"
result_digest="sha256:$(printf %s "$result_without_digest" | sha256sum | awk '{print $1}')"
result="$(jq -cn --argjson result "$result_without_digest" --arg digest "$result_digest" \
  '$result + {result_digest:$digest}')"
printf '%s\n' "$result" > "$result_file"
request="$(jq -cn --argjson request "$canonical_request" --arg digest "$claimed_request_digest" \
  '$request + {request_digest:$digest}')"
body_file="$OUT/cloud-upload-body.json"
jq -cn --argjson request "$request" --argjson result "$result" \
  '{mode:"source_ci",key_id:null,request:$request,result:$result,signature:null}' > "$body_file"

config="$OUT/cloud-upload-curl.conf"
printf 'header = "Authorization: Bearer %s"\n' "$upload_token" > "$config"
chmod 600 "$config"
response="$OUT/cloud-upload-response.json"
set +e
http_code="$(curl --config "$config" --silent --show-error --connect-timeout 10 \
  --max-time 30 --request POST --header 'Content-Type: application/json' \
  --data-binary "@$body_file" --output "$response" --write-out '%{http_code}' \
  "$upload_url")"
curl_code=$?
set -e
rm -f "$config" "$body_file"

if [ "$curl_code" -ne 0 ] || [ "$http_code" != 201 ] \
  || ! jq -e --arg digest "$result_digest" '
    type == "object" and keys == ["recorded","result_digest"]
    and .recorded == true and .result_digest == $digest
  ' "$response" >/dev/null 2>&1; then
  fail_sync upload_failed "$result_digest" \
    'Retry with a current request and scoped Workspace upload credential; the local assessment remains valid.'
fi

write_status completed uploaded '' "$result_digest" ''
