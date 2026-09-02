#!/usr/bin/env bash
# Uploads the finalized assessment and receipt without changing the local gate.
set -euo pipefail

OUT="${ADOC_RUN_DIR:-$RUNNER_TEMP}"
status_file="$OUT/cloud-assessment-status.json"

finish() { # status, disposition, code, request digest, idempotency key, path, remediation
  jq -cn --arg status "$1" --arg disposition "$2" --arg code "$3" \
    --arg request_digest "$4" --arg idempotency_key "$5" --arg path "$6" \
    --arg remediation "$7" '{
      status:$status,
      disposition:(if $disposition == "" then null else $disposition end),
      code:(if $code == "" then null else $code end),
      request_digest:(if $request_digest == "" then null else $request_digest end),
      idempotency_key:(if $idempotency_key == "" then null else $idempotency_key end),
      submission_path:(if $path == "" then null else $path end),
      remediation:(if $remediation == "" then null else $remediation end)
    }' > "$status_file.tmp"
  mv "$status_file.tmp" "$status_file"
  if [ -n "${GITHUB_OUTPUT:-}" ]; then
    printf 'status=%s\ndisposition=%s\ncode=%s\nrequest-digest=%s\n' \
      "$1" "$2" "$3" "$4" >> "$GITHUB_OUTPUT"
    printf 'idempotency-key=%s\nsubmission-path=%s\n' "$5" "$6" >> "$GITHUB_OUTPUT"
  fi
}
fail_sync() { # remediation, request digest, idempotency key, path, optional code/disposition
  finish failed "${6:-}" "${5:-action.cloud_sync_failed}" "$2" "$3" "$4" "$1"
  echo "::warning::${5:-action.cloud_sync_failed}: $1" >&2
  exit 0
}

if [ "${ADOC_PROPOSE_ELIGIBLE:-false}" != true ] \
  || [ "${GITHUB_EVENT_NAME:-}" != pull_request ]; then
  finish skipped '' '' '' '' '' \
    'Use a trusted pull_request run for Cloud assessment ingestion.'
  exit 0
fi

upload_url="${CLOUD_ASSESSMENT_URL:-}"
repository_id="${CLOUD_ASSESSMENT_REPOSITORY_ID:-}"
upload_token="${CLOUD_ASSESSMENT_TOKEN:-}"
[[ "$upload_url" =~ ^https://[^[:space:]]+$ ]] && [ "${#upload_url}" -le 2048 ] \
  || fail_sync 'Use the exact HTTPS Workspace assessment-submissions endpoint.' '' '' ''
[[ "$repository_id" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] \
  || fail_sync 'Use the Workspace repository UUID issued by Cloud.' '' '' ''
for credential in "${GH_TOKEN:-}" "${ANTHROPIC_API_KEY:-}" \
  "${CLAUDE_CODE_OAUTH_TOKEN:-}" "${CLOUD_UPLOAD_TOKEN:-}"; do
  [ -z "$credential" ] || [ "$upload_token" != "$credential" ] \
    || fail_sync 'Use a scoped assessment credential distinct from GitHub, provider, and external-work credentials.' '' '' ''
done
[[ "$upload_token" =~ ^[A-Za-z0-9._~-]+$ ]] \
  && [ "${#upload_token}" -ge 16 ] && [ "${#upload_token}" -le 512 ] \
  || fail_sync 'Issue a new scoped, expiring Cloud assessment credential.' '' '' ''

assessment_path="$(cat "$OUT/assessment-path" 2>/dev/null || true)"
assessment_digest="$(cat "$OUT/assessment-sha256" 2>/dev/null || true)"
receipt_path="$ADOC_RETAINED_DIR/receipt-${ADOC_INVOCATION_ID}.json"
receipt_digest="$(cat "$OUT/receipt-sha256" 2>/dev/null || true)"
actual_assessment=''
actual_receipt=''
[ ! -f "$assessment_path" ] \
  || actual_assessment="sha256:$(sha256sum "$assessment_path" | awk '{print $1}')"
[ ! -f "$receipt_path" ] \
  || actual_receipt="sha256:$(sha256sum "$receipt_path" | awk '{print $1}')"
[ -f "$assessment_path" ] && [ "$assessment_digest" = "$actual_assessment" ] \
  && [ -f "$receipt_path" ] && [ "$receipt_digest" = "$actual_receipt" ] \
  || fail_sync 'Rerun the local assessment and receipt finalization before Cloud ingestion.' '' '' ''

if ! [[ "${ADOC_REQUESTED_BASE:-}" =~ ^[0-9a-f]{40}$ \
    && "${ADOC_HEAD:-}" =~ ^[0-9a-f]{40}$ \
    && "${ADOC_PR_NUMBER:-}" =~ ^[1-9][0-9]*$ ]] \
  || ! jq -e --arg base "$ADOC_REQUESTED_BASE" --arg head "$ADOC_HEAD" \
    --arg assessment "$assessment_digest" '
      .schema_version == "adoc.pr_assessment_receipt.v4"
      and .run_status == "completed"
      and .revisions.requested_base == $base and .revisions.head == $head
      and .assessment.schema_version == "adoc.change_assessment.v0"
      and .assessment.sha256 == $assessment
      and (.ci.run_id | type == "string" and test("^[1-9][0-9]*$"))
      and (.ci.run_attempt | type == "number" and floor == . and . > 0)
      and (.ci.job | type == "string" and test("^[A-Za-z_][A-Za-z0-9_-]{0,99}$"))
      and (.ci.workload_identity.workflow_ref | type == "string" and length > 0)
      and (.ci.workload_identity.workflow_sha | type == "string" and test("^[0-9a-f]{40}$"))
    ' "$receipt_path" >/dev/null 2>&1; then
  fail_sync 'Finalize a complete receipt bound to this pull request and exact revision.' '' '' ''
fi

assessment_transport="$OUT/cloud-assessment-envelope.json"
receipt_transport="$OUT/cloud-receipt-envelope.json"
jq -Rs --arg digest "$assessment_digest" '{
  schema_version:"adoc.change_assessment.v0",digest:$digest,bytes_base64:@base64
}' "$assessment_path" > "$assessment_transport"
jq -Rs --arg digest "$receipt_digest" '{
  schema_version:"adoc.pr_assessment_receipt.v4",digest:$digest,bytes_base64:@base64
}' "$receipt_path" > "$receipt_transport"

submission="$ADOC_RETAINED_DIR/assessment-submission-${ADOC_INVOCATION_ID}.json"
jq -cn --arg delivery "$ADOC_INVOCATION_ID" --arg repository "$repository_id" \
  --arg pr "$ADOC_PR_NUMBER" --arg base "$ADOC_REQUESTED_BASE" \
  --arg head "$ADOC_HEAD" --slurpfile assessment "$assessment_transport" \
  --slurpfile receipt "$receipt_transport" '{
    schema_version:"agentdoc.cloud.assessment_submission.v0",
    payload:{delivery_id:$delivery,repository_id:$repository,
      change_request:{system:"github_pull_request",id:$pr},
      revision:{system:"git",base:$base,head:$head,lineage:[$head]},
      assessment:$assessment[0],receipt:$receipt[0]}
  }' > "$submission"
rm -f "$assessment_transport" "$receipt_transport"

request_bytes="$(wc -c < "$submission" | tr -d ' ')"
[ "$request_bytes" -le 1048576 ] \
  || fail_sync 'The assessment submission exceeds the Cloud 1 MiB request limit.' '' '' "$submission"
request_digest="sha256:$(sha256sum "$submission" | awk '{print $1}')"
idempotency_key="sha256:$(printf '%s\n%s\n%s\n%s' "$ADOC_INVOCATION_ID" \
  "$repository_id" "$ADOC_HEAD" "$request_digest" | sha256sum | awk '{print $1}')"

config="$OUT/cloud-assessment-curl.conf"
response="$OUT/cloud-assessment-response.json"
printf 'header = "Authorization: Bearer %s"\n' "$upload_token" > "$config"
printf 'header = "Idempotency-Key: %s"\n' "$idempotency_key" >> "$config"
chmod 600 "$config"
set +e
http_code="$(curl -q --config "$config" --silent --show-error --connect-timeout 10 \
  --max-time 30 --request POST --header 'Content-Type: application/json' \
  --header 'Accept: application/json' --data-binary "@$submission" \
  --output "$response" --write-out '%{http_code}' "$upload_url")"
curl_code=$?
set -e
rm -f "$config"

if [ "$curl_code" -ne 0 ]; then
  fail_sync 'Retry the exact retained submission with a current scoped credential; the local assessment remains valid.' \
    "$request_digest" "$idempotency_key" "$submission"
fi

if { [ "$http_code" = 200 ] || [ "$http_code" = 202 ]; } && jq -e \
  --arg assessment "$assessment_digest" --arg receipt "$receipt_digest" \
  --arg http "$http_code" '
    type == "object" and keys == ["payload","schema_version"]
    and .schema_version == "agentdoc.cloud.ingestion_result.v0"
    and (.payload | type == "object")
    and (.payload | keys == ["assessment_digest","code","complete","disposition",
      "ingestion_id","original_request_id","receipt_digest","replayed","request_id"])
    and .payload.assessment_digest == $assessment
    and .payload.receipt_digest == $receipt
    and (.payload.ingestion_id | test("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"))
    and (.payload.original_request_id | test("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"))
    and (.payload.request_id | test("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"))
    and (.payload.replayed | type == "boolean")
    and if .payload.disposition == "accepted" then
      $http == "202" and .payload.code == null and .payload.complete == true
    elif .payload.disposition == "duplicate" then
      $http == "200" and .payload.code == "ingest.duplicate_delivery"
      and .payload.complete == true and .payload.replayed == true
    elif .payload.disposition == "stale" then
      $http == "202" and .payload.code == "ingest.stale_run" and .payload.complete == true
    elif .payload.disposition == "partial" then
      $http == "202" and .payload.code == "api.internal_error" and .payload.complete == false
    else false end
  ' "$response" >/dev/null 2>&1; then
  disposition="$(jq -r .payload.disposition "$response")"
  code="$(jq -r '.payload.code // empty' "$response")"
  if [ "$disposition" = partial ]; then
    fail_sync 'Retry the exact retained submission to complete receipt persistence.' \
      "$request_digest" "$idempotency_key" "$submission" "$code" "$disposition"
  fi
  finish completed "$disposition" "$code" "$request_digest" \
    "$idempotency_key" "$submission" ''
  exit 0
fi

server_code="$(jq -r '.error.code // empty' "$response" 2>/dev/null || true)"
case "$server_code" in
  ingest.digest_mismatch | connect.permission_exceeds_manifest | \
    api.idempotency_conflict | ingest.envelope_version_unsupported)
    code="$server_code" ;;
  *) code=action.cloud_sync_failed ;;
esac
fail_sync 'Retry the exact retained submission after correcting the typed Cloud rejection; the local assessment remains valid.' \
  "$request_digest" "$idempotency_key" "$submission" "$code"
