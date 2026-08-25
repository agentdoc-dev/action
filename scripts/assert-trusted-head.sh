#!/usr/bin/env bash
# Rechecks the authenticated PR head after semantic execution. A changed head
# makes the result ineligible for proposal, delivery, or Cloud hand-off.
set -euo pipefail

request="${TRUSTED_CHANGE_REQUEST:?}"
status="${TRUSTED_PHASE_STATUS_PATH:?}"
base_repo="$(jq -r .base_repository "$request")"
head_repo="$(jq -r .head_repository "$request")"
pr="$(jq -r .pull_request "$request")"
expected="$(jq -r .head_revision "$request")"
temporary="$status.tmp"

disable() {
  printf 'ADOC_PROPOSE_ELIGIBLE=false\nADOC_TRUSTED_HEAD_CURRENT=false\n' \
    >> "$GITHUB_ENV"
}

if ! pr_json="$(gh api "repos/${base_repo}/pulls/${pr}" 2>/dev/null)"; then
  jq '.state = "failed"
    | .reason_code = "trusted.github_identity_unavailable"
    | .remediation = "Retry with a repository-scoped GitHub token."
    | .context_digest = null | .result_digest = null' \
    "$status" > "$temporary"
  mv "$temporary" "$status"
  disable
  exit 0
fi
if ! jq -e --arg base "$base_repo" --arg head_repo "$head_repo" '
  .state == "open" and .base.repo.full_name == $base
  and .head.repo.full_name == $head_repo
' <<< "$pr_json" >/dev/null 2>&1; then
  jq '.state = "failed"
    | .reason_code = "trusted.github_identity_invalid"
    | .remediation = "Regenerate and authorize the request for this pull request."
    | .context_digest = null | .result_digest = null' \
    "$status" > "$temporary"
  mv "$temporary" "$status"
  disable
  exit 0
fi
observed="$(jq -r .head.sha <<< "$pr_json")"
if [ "$observed" != "$expected" ]; then
  jq --arg observed "$observed" '
    .state = "expired_after_head_change"
    | .reason_code = "trusted.head_changed"
    | .remediation = "Authorize and run the new exact pull-request head."
    | .observed_head_revision = $observed
    | .context_digest = null | .result_digest = null
  ' "$status" > "$temporary"
  mv "$temporary" "$status"
  disable
  exit 0
fi
jq --arg observed "$observed" '
  .state = "running" | .observed_head_revision = $observed
' "$status" > "$temporary"
mv "$temporary" "$status"
printf 'ADOC_TRUSTED_HEAD_CURRENT=true\n' >> "$GITHUB_ENV"
