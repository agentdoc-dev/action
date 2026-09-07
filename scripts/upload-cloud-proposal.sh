#!/usr/bin/env bash
# Uploads one exact canonical proposal after its assessment is durably accepted.
set -euo pipefail

OUT="${ADOC_RUN_DIR:-$RUNNER_TEMP}"
SELF="$(cd "$(dirname "$0")" && pwd)"
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
  attempt_status_written=true
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

# Reuse only the exact accepted submission and its protected same-job receipt.
assessment_submission="$ADOC_RETAINED_DIR/assessment-submission-${ADOC_INVOCATION_ID}.json"
receipt_path="$ADOC_RETAINED_DIR/receipt-${ADOC_INVOCATION_ID}.json"
assessment_url="${CLOUD_ASSESSMENT_URL:-}"
if [ "$assessment_url" != "${upload_url%/proposal-commands}/assessment-submissions" ] \
  || [ ! -f "$assessment_submission" ] || [ ! -f "$receipt_path" ] \
  || [ "$(jq -r .submission_path "$assessment_status")" != "$assessment_submission" ] \
  || [ "$(jq -r .request_digest "$assessment_status")" \
    != "sha256:$(sha256sum "$assessment_submission" | awk '{print $1}')" ] \
  || ! jq -e --arg invocation "$ADOC_INVOCATION_ID" --arg pr "$ADOC_PR_NUMBER" \
    --arg base "$ADOC_REQUESTED_BASE" --arg head "$ADOC_HEAD" \
    --arg assessment "$assessment_digest" \
    --arg receipt "sha256:$(sha256sum "$receipt_path" | awk '{print $1}')" \
    --slurpfile protected_receipt "$receipt_path" '
      .schema_version == "agentdoc.cloud.assessment_submission.v0"
      and .payload.delivery_id == $invocation
      and .payload.change_request == {system:"github_pull_request",id:$pr}
      and .payload.revision == {system:"git",base:$base,head:$head,lineage:[$head]}
      and .payload.assessment.digest == $assessment
      and .payload.receipt.digest == $receipt
      and ($protected_receipt[0] | .schema_version == "adoc.pr_assessment_receipt.v4"
        and .run_status == "completed" and .ci.invocation_id == $invocation
        and .ci.pull_request == ($pr | tonumber)
        and .revisions.requested_base == $base and .revisions.head == $head
        and .assessment.sha256 == $assessment
        and (.ci.workload_identity.repository_id | type == "string" and test("^[1-9][0-9]*$")))
    ' "$assessment_submission" >/dev/null 2>&1; then
  fail_sync 'Use the exact accepted assessment and protected receipt on the same Cloud origin and Workspace.' \
    "$request_digest" "$idempotency_key" "$submission" egress.policy_unavailable '' \
    "$proposal_set_digest" "$record_digest"
fi
repository_id="$(jq -r .payload.repository_id "$assessment_submission")"
workspace="${assessment_url%/assessment-submissions}"
workspace="${workspace##*/}"
# ponytail: match Cloud's unknown-origin admission; narrow only with verified producer origin.
if ! egress_code="$(python3 -I "$SELF/cloud-egress.py" "$curl_bin" "$upload_url" \
  "$workspace" "$repository_id" \
  "$(jq -r .ci.workload_identity.repository_id "$receipt_path")" \
  raw_source source_excerpts pr_diffs compiled_objects embeddings semantic_assessments audit_metadata 2>/dev/null)"; then
  case "$egress_code" in
    egress.category_disabled)
      finish skipped '' "$egress_code" "$request_digest" "$idempotency_key" "$submission" \
        '' '' "$proposal_set_digest" "$record_digest" \
        'The current repository policy disables a required category; the proposal remains local.'
      python3 -I "$SELF/cloud-egress.py" --notice "$curl_bin" "$upload_url" \
        "$workspace" "$repository_id" \
        "$(jq -r .ci.workload_identity.repository_id "$receipt_path")" \
        proposal_command >/dev/null 2>&1 || true
      echo "::warning::$egress_code: Cloud transmission skipped; the local assessment remains valid." >&2
      exit 0 ;;
    api.unauthenticated|workspace.cross_tenant_denied) ;;
    *) egress_code=egress.policy_unavailable ;;
  esac
  fail_sync 'Authorize a fresh source-bound egress policy before retrying the retained proposal.' \
    "$request_digest" "$idempotency_key" "$submission" "$egress_code" '' \
    "$proposal_set_digest" "$record_digest"
fi

config="$OUT/cloud-proposal-curl.conf"
response="$OUT/cloud-proposal-response.json"
# The successful check returns the exact verified policy bytes' digest.
[[ "$egress_code" =~ ^sha256:[0-9a-f]{64}$ ]] || fail_sync 'Could not retain private transmission metadata.' "$request_digest" "$idempotency_key" "$submission" '' '' "$proposal_set_digest" "$record_digest"
attempt_id="$(python3 -I "$SELF/cloud-egress.py" --prepare-attempt proposal_command \
  "$workspace" "$repository_id" "$egress_code" "$submission" 2>/dev/null)" \
  || fail_sync 'Could not retain private transmission metadata.' "$request_digest" "$idempotency_key" "$submission" '' '' "$proposal_set_digest" "$record_digest"
attempt_headers="$OUT/cloud-egress-attempts/$attempt_id.headers"
curl_code=255
http_code=000
attempt_status_written=false
finish_attempt() {
  local business_status_file=""
  if [ "$attempt_status_written" = true ]; then business_status_file="$status_file"; fi
  python3 -I "$SELF/cloud-egress.py" --finish-attempt "$attempt_id" \
    "$curl_code" "$http_code" "$business_status_file" >/dev/null 2>&1 || true
}
trap finish_attempt EXIT
printf 'header = "Authorization: Bearer %s"\n' "$upload_token" > "$config"
printf 'header = "X-Agentdoc-Egress-Policy-Digest: %s"\n' "$egress_code" >> "$config"
printf 'header = "X-Request-ID: %s"\n' "$attempt_id" >> "$config"
printf 'header = "Idempotency-Key: %s"\n' "$idempotency_key" >> "$config"
chmod 600 "$config"
set +e
http_code="$("$curl_bin" -q --config "$config" --silent --show-error \
  --connect-timeout 10 --max-time 30 --request POST \
  --header 'Content-Type: application/json' --header 'Accept: application/json' \
  --data-binary "@$submission" --output "$response" --dump-header "$attempt_headers" --write-out '%{http_code}' \
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
      $http == "202" and .payload.code == null and .payload.replayed == false
    elif .payload.disposition == "duplicate" then
      $http == "200" and .payload.code == "ingest.duplicate_delivery"
      and .payload.replayed == true
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
  egress.payload_rejected | governance.proposal_invalid | governance.proposal_conflict | \
    api.idempotency_conflict | ingest.envelope_version_unsupported)
    code="$server_code" ;;
  *) code=action.cloud_sync_failed ;;
esac
fail_sync 'Retry the exact retained proposal after correcting the typed Cloud rejection.' \
  "$request_digest" "$idempotency_key" "$submission" "$code" '' \
  "$proposal_set_digest" "$record_digest"
