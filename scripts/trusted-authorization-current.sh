#!/usr/bin/env bash
set -euo pipefail

[ "${ADOC_TRUSTED_PHASE:-false}" = true ] || exit 0

status="${TRUSTED_PHASE_STATUS_PATH:-${ADOC_RUN_DIR:-${RUNNER_TEMP:?}}/trusted-phase-status.json}"
temporary="$status.authorization-current.tmp"
expires_at="${ADOC_TRUSTED_AUTHORIZATION_EXPIRES_AT:-}"
expires_epoch="$(jq -ner --arg value "$expires_at" '
  $value as $timestamp
  | ($timestamp | fromdateiso8601) as $epoch
  | select(($epoch | todateiso8601) == $timestamp)
  | $epoch
' 2>/dev/null || true)"

fail_current() { # state, code, remediation, observed head
  if [ -s "$status" ] && jq --arg state "$1" --arg code "$2" \
    --arg remediation "$3" --arg observed "${4:-}" '
      .state = $state | .reason_code = $code | .remediation = $remediation
      | .context_digest = null | .result_digest = null
      | if $observed == "" then del(.observed_head_revision)
        else .observed_head_revision = $observed end
    ' "$status" > "$temporary" 2>/dev/null; then
    mv "$temporary" "$status"
  else
    rm -f "$temporary"
  fi
  echo "::warning::$2: trusted authorization is no longer current" >&2
  exit 1
}

expiry_current() {
  [[ "$expires_epoch" =~ ^[0-9]+$ ]] \
    && [ "$expires_epoch" -gt "$(date -u +%s)" ]
}

expiry_current || fail_current failed trusted.authorization_expired \
  'Record a fresh authorization for the current head.'

request="${TRUSTED_CHANGE_REQUEST:-${ADOC_TRUSTED_CHANGE_REQUEST_PATH:-}}"
if [ ! -s "$request" ]; then
  fail_current failed trusted.github_identity_invalid \
    'Regenerate and authorize the request for this pull request.'
fi
base_repo="$(jq -er .base_repository "$request" 2>/dev/null)" \
  || fail_current failed trusted.github_identity_invalid \
    'Regenerate and authorize the request for this pull request.'
head_repo="$(jq -er .head_repository "$request" 2>/dev/null)" \
  || fail_current failed trusted.github_identity_invalid \
    'Regenerate and authorize the request for this pull request.'
base_ref="$(jq -er .base_ref "$request" 2>/dev/null)" \
  || fail_current failed trusted.github_identity_invalid \
    'Regenerate and authorize the request for this pull request.'
base_revision="$(jq -er .base_revision "$request" 2>/dev/null)" \
  || fail_current failed trusted.github_identity_invalid \
    'Regenerate and authorize the request for this pull request.'
pr="$(jq -er .pull_request "$request" 2>/dev/null)" \
  || fail_current failed trusted.github_identity_invalid \
    'Regenerate and authorize the request for this pull request.'
expected="$(jq -er .head_revision "$request" 2>/dev/null)" \
  || fail_current failed trusted.github_identity_invalid \
    'Regenerate and authorize the request for this pull request.'

pr_json="$(gh api "repos/${base_repo}/pulls/${pr}" 2>/dev/null)" \
  || fail_current failed trusted.github_identity_unavailable \
    'Retry with a repository-scoped GitHub token.'
if ! jq -e --arg base "$base_repo" --arg head_repo "$head_repo" \
  --arg base_ref "$base_ref" --arg base_revision "$base_revision" '
    .state == "open" and .base.repo.full_name == $base
    and .head.repo.full_name == $head_repo
    and .base.ref == $base_ref and .base.sha == $base_revision
  ' <<< "$pr_json" >/dev/null 2>&1; then
  fail_current failed trusted.github_identity_invalid \
    'Regenerate and authorize the request for this pull request.'
fi
observed="$(jq -r .head.sha <<< "$pr_json")"
[ "$observed" = "$expected" ] || fail_current expired_after_head_change \
  trusted.head_changed 'Authorize and run the new exact pull-request head.' "$observed"
expiry_current || fail_current failed trusted.authorization_expired \
  'Record a fresh authorization for the current head.'
