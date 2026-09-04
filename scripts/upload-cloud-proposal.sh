#!/usr/bin/env bash
# Uploads one exact canonical proposal after its assessment is durably accepted.
set -euo pipefail

OUT="${ADOC_RUN_DIR:-$RUNNER_TEMP}"
status_file="$OUT/cloud-proposal-status.json"

finish() { # status disposition code request key path record-id version-id set record-digest remediation
  jq -cn --arg status "$1" --arg disposition "$2" --arg code "$3" \
    --arg request "$4" --arg key "$5" --arg path "$6" --arg record_id "$7" \
    --arg version_id "$8" --arg set "$9" --arg record_digest "${10}" \
    --arg remediation "${11}" '{
    status:$status,
    disposition:(if $disposition == "" then null else $disposition end),
    code:(if $code == "" then null else $code end),
    request_digest:(if $request == "" then null else $request end),
    idempotency_key:(if $key == "" then null else $key end),
    submission_path:(if $path == "" then null else $path end),
    proposal_record_id:(if $record_id == "" then null else $record_id end),
    proposal_version_id:(if $version_id == "" then null else $version_id end),
    proposal_set_digest:(if $set == "" then null else $set end),
    record_digest:(if $record_digest == "" then null else $record_digest end),
    remediation:(if $remediation == "" then null else $remediation end)
  }' > "$status_file.tmp"
  mv "$status_file.tmp" "$status_file"
  if [ -n "${GITHUB_OUTPUT:-}" ]; then
    {
      printf 'status=%s\ndisposition=%s\ncode=%s\nrequest-digest=%s\n' \
        "$1" "$2" "$3" "$4"
      printf 'idempotency-key=%s\nsubmission-path=%s\n' "$5" "$6"
      printf 'proposal-record-id=%s\nproposal-version-id=%s\n' "$7" "$8"
      printf 'proposal-set-digest=%s\nrecord-digest=%s\n' "$9" "${10}"
    } >> "$GITHUB_OUTPUT"
  fi
}

fail_sync() { # remediation, request, key, path, code, disposition, set, record digest
  finish failed "${6:-}" "${5:-action.cloud_sync_failed}" "${2:-}" \
    "${3:-}" "${4:-}" '' '' "${7:-}" "${8:-}" "$1"
  echo "::warning::${5:-action.cloud_sync_failed}: $1" >&2
  exit 0
}

if [ "${ADOC_PROPOSE_ELIGIBLE:-false}" != true ] \
  || [ "${ADOC_ISOLATED_ASSESSMENT:-false}" != true ] \
  || [ "${GITHUB_EVENT_NAME:-}" != workflow_run ]; then
  finish skipped '' '' '' '' '' '' '' '' '' \
    'Use an eligible protected workflow_run assessment for Cloud proposal ingestion.'
  exit 0
fi

assessment_status="$OUT/cloud-assessment-status.json"
jq -e '.status == "completed" and (.disposition | IN("accepted","duplicate"))' \
  "$assessment_status" >/dev/null 2>&1 \
  || fail_sync 'Complete the exact Cloud assessment ingestion before submitting its proposal.'

upload_url="${CLOUD_PROPOSAL_URL:-}"
upload_token="${CLOUD_PROPOSAL_TOKEN:-}"
[[ "$upload_url" =~ ^https://[^[:space:]]+$ ]] && [ "${#upload_url}" -le 2048 ] \
  || fail_sync 'Use the exact HTTPS Workspace proposal-commands endpoint.'
for credential in "${GH_TOKEN:-}" "${ANTHROPIC_API_KEY:-}" \
  "${CLAUDE_CODE_OAUTH_TOKEN:-}" "${CLOUD_UPLOAD_TOKEN:-}" \
  "${CLOUD_ASSESSMENT_TOKEN:-}"; do
  [ -z "$credential" ] || [ "$upload_token" != "$credential" ] \
    || fail_sync 'Use a scoped proposal credential distinct from GitHub, provider, assessment, and external-work credentials.'
done
[[ "$upload_token" =~ ^[A-Za-z0-9._~-]+$ ]] \
  && [ "${#upload_token}" -ge 16 ] && [ "${#upload_token}" -le 512 ] \
  || fail_sync 'Issue a new scoped, expiring Cloud proposal credential.'
curl_bin="${1:-}"
[[ "$curl_bin" = /* && -x "$curl_bin" ]] \
  || fail_sync 'Use the trusted curl executable supplied by the Action.'

proposal="$ADOC_RETAINED_DIR/proposal-record-${ADOC_INVOCATION_ID}.json"
record_digest="$(cat "$OUT/proposal-record-sha256" 2>/dev/null || true)"
actual_record=''
[ ! -f "$proposal" ] \
  || actual_record="sha256:$(sha256sum "$proposal" | awk '{print $1}')"
[[ "$record_digest" =~ ^sha256:[0-9a-f]{64}$ ]] \
  && [ "$record_digest" = "$actual_record" ] \
  || fail_sync 'Stage the exact finalized canonical proposal record before Cloud ingestion.'

assessment_digest="$(cat "$OUT/assessment-sha256" 2>/dev/null || true)"
semantic="$ADOC_RETAINED_DIR/semantic-assessment-${ADOC_INVOCATION_ID}.json"
context="$ADOC_RETAINED_DIR/semantic-context-${ADOC_INVOCATION_ID}.json"
if ! jq -e --arg base "${ADOC_REQUESTED_BASE:-}" --arg head "${ADOC_HEAD:-}" \
  --arg pr "${ADOC_PR_NUMBER:-}" --arg assessment "$assessment_digest" \
  --arg semantic "sha256:$(sha256sum "$semantic" 2>/dev/null | awk '{print $1}')" \
  --slurpfile context "$context" '
    .schema_version == "adoc.proposal.v0"
    and (.proposal_set_digest | test("^sha256:[0-9a-f]{64}$"))
    and .bindings.base_revision == {system:"git",value:$base}
    and .bindings.head_revision == {system:"git",value:$head}
    and .bindings.change_request == {system:"github_pull_request",id:$pr}
    and .bindings.assessment_digest == $assessment
    and .bindings.semantic_context_digest == $context[0].context_digest
    and .bindings.semantic_assessment_digest == $semantic
  ' "$proposal" >/dev/null 2>&1; then
  fail_sync 'Stage a proposal bound to the exact accepted assessment and semantic evidence.' \
    '' '' '' '' '' '' "$record_digest"
fi
proposal_set_digest="$(jq -r .proposal_set_digest "$proposal")"

submission="$ADOC_RETAINED_DIR/proposal-command-${ADOC_INVOCATION_ID}.json"
jq -c '{schema_version:"agentdoc.cloud.proposal_command.v0",payload:.}' \
  "$proposal" > "$submission"
[ "$(wc -c < "$submission" | tr -d ' ')" -le 1048576 ] \
  || fail_sync 'The proposal command exceeds the Cloud 1 MiB request limit.' \
    '' '' "$submission" '' '' "$proposal_set_digest" "$record_digest"
request_digest="sha256:$(sha256sum "$submission" | awk '{print $1}')"
idempotency_key="sha256:$(printf '%s\n%s' "$proposal_set_digest" \
  "$request_digest" | sha256sum | awk '{print $1}')"

config="$OUT/cloud-proposal-curl.conf"
response="$OUT/cloud-proposal-response.json"
printf 'header = "Authorization: Bearer %s"\n' "$upload_token" > "$config"
printf 'header = "Idempotency-Key: %s"\n' "$idempotency_key" >> "$config"
chmod 600 "$config"
set +e
http_code="$("$curl_bin" -q --config "$config" --silent --show-error \
  --connect-timeout 10 --max-time 30 --request POST \
  --header 'Content-Type: application/json' --header 'Accept: application/json' \
  --data-binary "@$submission" --output "$response" --write-out '%{http_code}' \
  "$upload_url")"
curl_code=$?
set -e
rm -f "$config"
if [ "$curl_code" -ne 0 ]; then
  fail_sync 'Retry the exact retained proposal command with a current scoped credential.' \
    "$request_digest" "$idempotency_key" "$submission" '' '' \
    "$proposal_set_digest" "$record_digest"
fi

if { [ "$http_code" = 200 ] || [ "$http_code" = 202 ]; } && jq -e \
  --arg http "$http_code" --arg set "$proposal_set_digest" \
  --arg record "$record_digest" --arg supersedes "$(jq -r '.supersedes // empty' "$proposal")" '
    type == "object" and keys == ["payload","schema_version"]
    and .schema_version == "agentdoc.cloud.ingestion_result.v0"
    and (.payload | keys == ["code","complete","disposition","original_request_id",
      "proposal_record_id","proposal_set_digest","proposal_version_id","record_digest",
      "replayed","request_id","supersedes"])
    and .payload.complete == true
    and .payload.proposal_set_digest == $set
    and .payload.record_digest == $record
    and .payload.supersedes == (if $supersedes == "" then null else $supersedes end)
    and ([.payload.proposal_record_id,.payload.proposal_version_id,
      .payload.original_request_id,.payload.request_id]
      | all(test("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")))
    and (.payload.replayed | type == "boolean")
    and if .payload.disposition == "accepted" then
      $http == "202" and .payload.code == null
    elif .payload.disposition == "duplicate" then
      $http == "200" and .payload.code == "ingest.duplicate_delivery"
    else false end
  ' "$response" >/dev/null 2>&1; then
  disposition="$(jq -r .payload.disposition "$response")"
  code="$(jq -r '.payload.code // empty' "$response")"
  finish completed "$disposition" "$code" "$request_digest" \
    "$idempotency_key" "$submission" \
    "$(jq -r .payload.proposal_record_id "$response")" \
    "$(jq -r .payload.proposal_version_id "$response")" \
    "$proposal_set_digest" "$record_digest" ''
  exit 0
fi

server_code="$(jq -r '.error.code // empty' "$response" 2>/dev/null || true)"
case "$server_code" in
  governance.proposal_invalid | governance.proposal_conflict | \
    api.idempotency_conflict | ingest.envelope_version_unsupported)
    code="$server_code" ;;
  *) code=action.cloud_sync_failed ;;
esac
fail_sync 'Retry the exact retained proposal after correcting the typed Cloud rejection.' \
  "$request_digest" "$idempotency_key" "$submission" "$code" '' \
  "$proposal_set_digest" "$record_digest"
