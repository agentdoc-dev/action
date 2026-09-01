#!/usr/bin/env bash
set -euo pipefail

digest_file() {
  local path="$1"
  if [ -z "$path" ] || [ "$path" = - ]; then
    return
  fi
  [ -f "$path" ]
  printf 'sha256:%s' "$(sha256sum "$path" | awk '{print $1}')"
}

fallback_policy="$(digest_file "${ADOC_SEMANTIC_FALLBACK_POLICY:-${INPUT_SEMANTIC_FALLBACK_POLICY:-}}")"
primary_request="$(digest_file "${ADOC_SEMANTIC_PRIMARY_REQUEST:-${INPUT_SEMANTIC_PRIMARY_REQUEST:-}}")"
fallback_request="$(digest_file "${ADOC_SEMANTIC_FALLBACK_REQUEST:-${INPUT_SEMANTIC_FALLBACK_REQUEST:--}}")"
cloud_request="${INPUT_CLOUD_WORK_REQUEST:-}"
cloud_url="${INPUT_CLOUD_UPLOAD_URL:-}"
cloud_enabled=false
cloud_request_digest=''
if [ -n "$cloud_request" ] || [ -n "$cloud_url" ]; then
  [ -n "$cloud_request" ] && [[ "$cloud_url" =~ ^https://[^[:space:]]+$ ]]
  cloud_request_digest="$(jq -er '
    .request_digest
    | select(type == "string" and test("^sha256:[0-9a-f]{64}$"))
  ' "$cloud_request")"
  cloud_enabled=true
fi
policy="$(jq -cnS \
  --arg semantic_review "${INPUT_SEMANTIC_REVIEW:-false}" \
  --arg fallback_policy "$fallback_policy" --arg primary_request "$primary_request" \
  --arg fallback_request "$fallback_request" \
  --arg qualification "${INPUT_TRUSTED_EXECUTOR_QUALIFICATION_ID:-}" \
  --arg model "${INPUT_MODEL:-claude-sonnet-5}" \
  --arg provider_timeout "${INPUT_PROVIDER_TIMEOUT_SECONDS:-600}" \
  --arg claude_version "${INPUT_CLAUDE_CODE_VERSION:-2.1.215}" \
  --arg propose "${INPUT_PROPOSE:-true}" \
  --arg propose_provider "${INPUT_PROPOSE_PROVIDER:-claude-code}" \
  --arg propose_delivery "${INPUT_PROPOSE_DELIVERY:-comment}" \
  --arg propose_on_error "${INPUT_PROPOSE_ON_ERROR:-warn}" \
  --arg propose_max_paths "${INPUT_PROPOSE_MAX_PATHS:-10}" \
  --arg propose_coverage "${INPUT_PROPOSE_COVERAGE:-bounded}" \
  --arg propose_authority "${INPUT_PROPOSE_AUTHORITY:-downgrade}" \
  --arg propose_contradictions "${INPUT_PROPOSE_CONTRADICTIONS:-suggest}" \
  --arg propose_delivery_policy "${INPUT_PROPOSE_DELIVERY_POLICY:-atomic}" \
  --arg cloud_enabled "$cloud_enabled" \
  --arg cloud_request_digest "$cloud_request_digest" --arg cloud_url "$cloud_url" '
  def nullable: if . == "" then null else . end;
  {
    schema_version:"agentdoc.trusted_run_policy.v1",
    semantic:{review:($semantic_review == "true"),model:$model,
      provider_timeout_seconds:($provider_timeout | tonumber),
      claude_code_version:$claude_version,
      executor_qualification_id:($qualification | nullable),
      fallback_policy_sha256:($fallback_policy | nullable),
      primary_request_sha256:($primary_request | nullable),
      fallback_request_sha256:($fallback_request | nullable)},
    proposal:{enabled:($propose == "true"),provider:$propose_provider,
      delivery:$propose_delivery,on_error:$propose_on_error,
      max_paths:($propose_max_paths | tonumber),coverage:$propose_coverage,
      authority:$propose_authority,contradictions:$propose_contradictions,
      delivery_policy:$propose_delivery_policy},
    cloud:{enabled:($cloud_enabled == "true"),
      work_request_digest:($cloud_request_digest | nullable),
      upload_url:($cloud_url | nullable)}
  }
')"
policy_digest="sha256:$(printf '%s' "$policy" | sha256sum | awk '{print $1}')"

[[ "${GITHUB_SERVER_URL:-}" =~ ^https://[^[:space:]]+$ \
  && "${GITHUB_REPOSITORY:-}" =~ ^[^/[:space:]]+/[^/[:space:]]+$ \
  && "${GITHUB_REPOSITORY_ID:-}" =~ ^[1-9][0-9]*$ \
  && "${GITHUB_WORKFLOW_REF:-}" == "${GITHUB_REPOSITORY}"/.github/workflows/*@refs/heads/* \
  && "${GITHUB_SHA:-}" =~ ^[0-9a-f]{40}$ \
  && "${GITHUB_ACTOR_ID:-}" =~ ^[1-9][0-9]*$ \
  && -n "${GITHUB_TRIGGERING_ACTOR:-}" \
  && "${GITHUB_RUN_ID:-}" =~ ^[1-9][0-9]*$ \
  && "${GITHUB_RUN_ATTEMPT:-}" =~ ^[1-9][0-9]*$ \
  && -n "${GITHUB_JOB:-}" ]]
principal="$(jq -cnS \
  --arg server_url "$GITHUB_SERVER_URL" --arg repository "$GITHUB_REPOSITORY" \
  --arg repository_id "$GITHUB_REPOSITORY_ID" --arg workflow_ref "$GITHUB_WORKFLOW_REF" \
  --arg workflow_sha "$GITHUB_SHA" --arg actor_id "$GITHUB_ACTOR_ID" \
  --arg triggering_actor "$GITHUB_TRIGGERING_ACTOR" '{
    provider:"github_actions",server_url:$server_url,repository:$repository,
    repository_id:$repository_id,workflow_ref:$workflow_ref,workflow_sha:$workflow_sha,
    actor_id:$actor_id,triggering_actor:$triggering_actor
  }')"
session="$(jq -cnS --arg run_id "$GITHUB_RUN_ID" \
  --arg run_attempt "$GITHUB_RUN_ATTEMPT" --arg job "$GITHUB_JOB" '{
    provider:"github_actions",run_id:$run_id,
    run_attempt:($run_attempt | tonumber),job:$job
  }')"

jq -cnS --arg policy "$policy_digest" \
  --arg principal "sha256:$(printf '%s' "$principal" | sha256sum | awk '{print $1}')" \
  --arg session "sha256:$(printf '%s' "$session" | sha256sum | awk '{print $1}')" '{
    policy:{version:"trusted-change-v1",digest:$policy},
    workload:{principal_id:$principal,session_id:$session}
  }'
