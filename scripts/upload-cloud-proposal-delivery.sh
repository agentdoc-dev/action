#!/usr/bin/env bash
# Reports one finalized Git delivery of an accepted Cloud proposal (E8.2.T2).
# Never changes the Git result: every refusal exits 0 with a typed status.
set -euo pipefail

OUT="${ADOC_RUN_DIR:-$RUNNER_TEMP}"
SELF="$(cd "$(dirname "$0")" && pwd)"
status_file="$OUT/cloud-proposal-delivery-status.json"

finish() { # status reason code disposition request key path delivery-id remediation
  jq -cn --arg status "$1" --arg reason "$2" --arg code "$3" \
    --arg disposition "$4" --arg request "$5" --arg key "$6" --arg path "$7" \
    --arg delivery "$8" --arg remediation "$9" '
    def n: if . == "" then null else . end;
    {status:$status,reason:($reason|n),code:($code|n),
     disposition:($disposition|n),request_digest:($request|n),
     idempotency_key:($key|n),submission_path:($path|n),
     delivery_id:($delivery|n),remediation:($remediation|n)}' \
    > "$status_file.tmp"
  mv "$status_file.tmp" "$status_file"
  attempt_status_written=true
  if [ -n "${GITHUB_OUTPUT:-}" ]; then
    printf 'status=%s\nreason=%s\ncode=%s\ndisposition=%s\n' "$1" "$2" "$3" "$4"
    printf 'request-digest=%s\nidempotency-key=%s\nsubmission-path=%s\n' "$5" "$6" "$7"
    printf 'delivery-id=%s\n' "$8"
  fi >> "${GITHUB_OUTPUT:-/dev/null}"
}
skip() { finish skipped "$1" '' '' '' '' '' '' "$2"; exit 0; }
request_digest='' idempotency_key='' submission=''
fail_sync() { # remediation [code]
  finish failed '' "${2:-action.cloud_sync_failed}" '' "$request_digest" \
    "$idempotency_key" "$submission" '' "$1"
  echo "::warning::${2:-action.cloud_sync_failed}: $1 The Git delivery is unchanged." >&2
  exit 0
}

if [ "${ADOC_PROPOSE_ELIGIBLE:-false}" != true ] \
  || [ "${ADOC_ISOLATED_ASSESSMENT:-false}" != true ] \
  || [ "${GITHUB_EVENT_NAME:-}" != workflow_run ]; then
  skip ineligible 'Use an eligible protected workflow_run assessment for Cloud delivery reports.'
fi
[ -n "${CLOUD_PROPOSAL_URL:-}" ] && [ -n "${CLOUD_PROPOSAL_TOKEN:-}" ] \
  || skip disconnected 'Configure cloud-proposal-url and cloud-proposal-token to report deliveries.'

# Both staged files are re-verified against the digests bound at staging.
verify_staged() { # retained-path digest-file
  local digest actual=''
  digest="$(cat "$OUT/$2" 2>/dev/null || true)"
  [ ! -f "$1" ] || actual="sha256:$(sha256sum "$1" | awk '{print $1}')"
  [[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]] && [ "$digest" = "$actual" ]
}
delivery="$ADOC_RETAINED_DIR/delivery-status-${ADOC_INVOCATION_ID}.json"
references="$ADOC_RETAINED_DIR/proposal-references-${ADOC_INVOCATION_ID}.txt"
[ -f "$OUT/delivery-status-sha256" ] \
  || skip no_delivery 'Stage the finalized delivery status to report a Git delivery.'
verify_staged "$delivery" delivery-status-sha256 \
  || fail_sync 'Stage the exact finalized delivery status before Cloud reporting.' ingest.digest_mismatch
if [ -f "$OUT/proposal-references-sha256" ]; then
  verify_staged "$references" proposal-references-sha256 \
    || fail_sync 'Stage the exact published proposal references block before Cloud reporting.' ingest.digest_mismatch
fi
jq -e '.status == "complete"' "$delivery" >/dev/null 2>&1 \
  || skip delivery_incomplete 'Only a complete Git delivery is reported to Cloud.'
[ -f "$OUT/proposal-record-sha256" ] \
  || skip no_proposal_record 'Deliveries without a canonical proposal record are not reported.'

proposal_status="$OUT/cloud-proposal-status.json"
version_id="${PROPOSAL_VERSION_ID:-}"
jq -e --arg version "$version_id" '.status == "completed"
  and (.disposition | IN("accepted","duplicate"))
  and .proposal_version_id == $version
  and ($version | test("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"))' \
  "$proposal_status" >/dev/null 2>&1 \
  || fail_sync 'Complete the exact Cloud proposal ingestion before reporting its delivery.'
proposal_set_digest="$(jq -r .proposal_set_digest "$proposal_status")"

mode="$(jq -r '.mode // empty' "$delivery")"
commit="$(jq -r '.delivery_commit // empty' "$delivery")"
[[ "$commit" =~ ^[0-9a-f]{40}$ ]] \
  && [ "$(jq -r '.assessed_head // empty' "$delivery")" = "${ADOC_HEAD:-}" ] \
  || fail_sync 'The delivery status is not bound to the assessed head.'
number='' block_digest=''
case "$mode" in
  commit) ;;
  pr)
    url="$(jq -r '.url // empty' "$delivery")"
    number="${url##*/}"
    [[ "$number" =~ ^[1-9][0-9]{0,9}$ ]] && [ "$number" -le 2147483647 ] \
      || fail_sync 'The delivery status has no knowledge pull request number.'
    [ -f "$OUT/proposal-references-sha256" ] \
      || fail_sync 'Stage the published proposal references block for pull-request delivery.'
    [ "$(wc -c < "$references" | tr -d ' ')" -le 65536 ] \
      && iconv -f UTF-8 -t UTF-8 "$references" >/dev/null 2>&1 \
      || fail_sync 'The proposal references block is not bounded UTF-8.'
    block_digest="$(cat "$OUT/proposal-references-sha256")" ;;
  *) fail_sync 'The delivery status has no supported mode.' ;;
esac
prefix="${PROJECT_PREFIX:-}"
[[ "$prefix" =~ ^([A-Za-z0-9._-]+/)*$ ]] && [[ "/$prefix" != */./* ]] \
  && [[ "/$prefix" != */../* ]] \
  || fail_sync 'Use the exact project prefix (`git rev-parse --show-prefix`).'

upload_url="${CLOUD_PROPOSAL_URL%/proposal-commands}/proposal-deliveries"
upload_token="${CLOUD_PROPOSAL_TOKEN:-}"
assessment_url="${CLOUD_ASSESSMENT_URL:-}"
[ "${CLOUD_PROPOSAL_URL:-}" = "${assessment_url%/assessment-submissions}/proposal-commands" ] \
  || fail_sync 'Use the proposal endpoint on the same Cloud origin and Workspace.'
curl_bin="${1:-}"
[[ "$curl_bin" = /* && -x "$curl_bin" ]] \
  || fail_sync 'Use the trusted curl executable supplied by the Action.'
for credential in "${GH_TOKEN:-}" "${ANTHROPIC_API_KEY:-}" \
  "${CLAUDE_CODE_OAUTH_TOKEN:-}" "${CLOUD_UPLOAD_TOKEN:-}" \
  "${CLOUD_ASSESSMENT_TOKEN:-}" "${CLOUD_EGRESS_TOKEN:-}"; do
  [ -z "$credential" ] || [ "$upload_token" != "$credential" ] \
    || fail_sync 'Use a scoped proposal credential distinct from GitHub, provider, assessment, egress, and external-work credentials.'
done
[[ "$upload_token" =~ ^[A-Za-z0-9._~-]+$ ]] \
  && [ "${#upload_token}" -ge 16 ] && [ "${#upload_token}" -le 512 ] \
  || fail_sync 'Issue a new scoped, expiring Cloud credential with operation proposal_delivery.'
receipt="$ADOC_RETAINED_DIR/receipt-${ADOC_INVOCATION_ID}.json"
assessment_submission="$ADOC_RETAINED_DIR/assessment-submission-${ADOC_INVOCATION_ID}.json"
receipt_digest="$(cat "$OUT/receipt-sha256" 2>/dev/null || true)"
[ -f "$receipt" ] && [ -f "$assessment_submission" ] \
  && [ "sha256:$(sha256sum "$receipt" | awk '{print $1}')" = "$receipt_digest" ] \
  || fail_sync 'Use the exact protected receipt of the accepted assessment.'
external_id="$(jq -r .ci.workload_identity.repository_id "$receipt")"
repository_id="$(jq -r .payload.repository_id "$assessment_submission")"
workspace="${assessment_url%/assessment-submissions}"
workspace="${workspace##*/}"

submission="$ADOC_RETAINED_DIR/proposal-delivery-${ADOC_INVOCATION_ID}.json"
jq -cn --arg external "$external_id" --arg pr "$ADOC_PR_NUMBER" \
  --arg version "$version_id" --arg set "$proposal_set_digest" \
  --arg receipt "$receipt_digest" --arg head "$ADOC_HEAD" --arg prefix "$prefix" \
  --arg mode "$mode" --arg commit "$commit" --arg number "$number" \
  --arg digest "$block_digest" --rawfile block "$( [ "$mode" = pr ] && echo "$references" || echo /dev/null)" '{
  schema_version:"agentdoc.cloud.proposal_delivery.v0",
  repository:{provider:"github",external_repository_id:$external},
  change_request:{system:"github_pull_request",id:$pr},
  proposal_version_id:$version,proposal_set_digest:$set,
  assessment_receipt_digest:$receipt,assessed_head_sha:$head,
  project_prefix:$prefix,mode:$mode,delivered_commit_sha:$commit,
  knowledge_pull_request_number:(if $mode == "pr" then ($number|tonumber) else null end),
  references_block:(if $mode == "pr" then $block else null end),
  references_block_digest:(if $mode == "pr" then $digest else null end)}' > "$submission"
request_digest="sha256:$(sha256sum "$submission" | awk '{print $1}')"
idempotency_key="sha256:$(printf '%s\n%s' "$proposal_set_digest" \
  "$request_digest" | sha256sum | awk '{print $1}')"

if ! egress_code="$(python3 -I "$SELF/cloud-egress.py" "$curl_bin" "$upload_url" \
  "$workspace" "$repository_id" "$external_id" raw_source source_excerpts pr_diffs \
  compiled_objects embeddings semantic_assessments audit_metadata 2>/dev/null)"; then
  if [ "$egress_code" = egress.category_disabled ]; then
    finish skipped '' "$egress_code" '' "$request_digest" "$idempotency_key" \
      "$submission" '' 'The current repository policy disables a required category; the delivery report remains local.'
    exit 0
  fi
  case "$egress_code" in
    api.unauthenticated|workspace.cross_tenant_denied) ;;
    *) egress_code=egress.policy_unavailable ;;
  esac
  fail_sync 'Authorize a fresh source-bound egress policy before retrying the retained delivery report.' "$egress_code"
fi
[[ "$egress_code" =~ ^sha256:[0-9a-f]{64}$ ]] \
  || fail_sync 'Could not retain the checked egress policy digest.'

config="$OUT/cloud-proposal-delivery-curl.conf"
response="$OUT/cloud-proposal-delivery-response.json"
# One retained transmission attempt per POST; the 503 retry is a new attempt.
# The final attempt is finished on exit so it records the business outcome.
pending_attempt='' attempt_status_written=false
finish_pending() {
  rm -f "$config"
  [ -n "$pending_attempt" ] || return 0
  local business_status_file=""
  if [ "$attempt_status_written" = true ]; then business_status_file="$status_file"; fi
  python3 -I "$SELF/cloud-egress.py" --finish-attempt "$pending_attempt" \
    "$curl_code" "$http_code" "$business_status_file" >/dev/null 2>&1 || true
  pending_attempt=''
}
trap finish_pending EXIT
post() {
  local attempt_id
  attempt_id="$(python3 -I "$SELF/cloud-egress.py" --prepare-attempt proposal_delivery \
    "$workspace" "$repository_id" "$egress_code" "$submission" 2>/dev/null)" \
    || fail_sync 'Could not retain private transmission metadata.'
  headers="$OUT/cloud-egress-attempts/$attempt_id.headers"
  curl_code=255
  http_code=000
  (umask 077 && printf 'header = "Authorization: Bearer %s"\n' "$upload_token" > "$config")
  printf 'header = "X-Agentdoc-Egress-Policy-Digest: %s"\n' "$egress_code" >> "$config"
  printf 'header = "X-Request-ID: %s"\n' "$attempt_id" >> "$config"
  printf 'header = "Idempotency-Key: %s"\n' "$idempotency_key" >> "$config"
  chmod 600 "$config"
  set +e
  http_code="$("$curl_bin" -q --config "$config" --silent --show-error \
    --connect-timeout 10 --max-time 30 --request POST \
    --header 'Content-Type: application/json' --header 'Accept: application/json' \
    --data-binary "@$submission" --output "$response" --dump-header "$headers" \
    --write-out '%{http_code}' "$upload_url")"
  curl_code=$?
  set -e
  rm -f "$config"
  retry_after="$(awk -F': *' 'tolower($1) == "retry-after" {gsub(/\r/, "", $2); print $2}' "$headers" 2>/dev/null | tail -n 1)"
  pending_attempt="$attempt_id"
}
post
# A 503 is returned before registration, so the identical bytes may be retried
# once; Retry-After is honoured up to 30 s.
if [ "$curl_code" -eq 0 ] && [ "$http_code" = 503 ] \
  && [ "$(jq -r '.error.code // empty' "$response" 2>/dev/null)" = delivery.provider_unavailable ]; then
  wait_s="$retry_after"
  [[ "$wait_s" =~ ^[0-9]+$ ]] && [ "$wait_s" -le 30 ] || wait_s=30
  finish_pending
  sleep "$wait_s"
  post
fi
[ "$curl_code" -eq 0 ] \
  || fail_sync 'Retry the exact retained delivery report with a current scoped credential.'

if { [ "$http_code" = 200 ] || [ "$http_code" = 202 ]; } && jq -e --arg http "$http_code" '
    .schema_version == "agentdoc.cloud.ingestion_result.v0"
    and (.payload.delivery_id | test("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"))
    and ((.payload.status == "accepted" and .payload.code == null and $http == "202")
      or (.payload.status == "duplicate" and .payload.code == "ingest.duplicate_delivery"
        and .payload.original_code == null and $http == "200"))
  ' "$response" >/dev/null 2>&1; then
  finish completed '' "$(jq -r '.payload.code // empty' "$response")" \
    "$(jq -r .payload.status "$response")" "$request_digest" "$idempotency_key" \
    "$submission" "$(jq -r .payload.delivery_id "$response")" ''
  exit 0
fi
# A replay of a refused report carries the original refusal, never success.
server_code="$(jq -r '.error.code // .payload.original_code // empty' "$response" 2>/dev/null || true)"
case "$server_code" in
  delivery.reference_missing | delivery.reference_stale | ingest.digest_mismatch | \
    delivery.provider_unavailable | api.idempotency_conflict | ingest.duplicate_delivery | \
    egress.payload_rejected | ingest.envelope_version_unsupported)
    code="$server_code" ;;
  *) code=action.cloud_sync_failed ;;
esac
fail_sync 'Retry the exact retained delivery report after correcting the typed Cloud refusal.' "$code"
