#!/usr/bin/env bash
# Records the shared authenticated freshness check for downstream stages.
set -euo pipefail

SELF="$(cd "$(dirname "$0")" && pwd)"
request="${TRUSTED_CHANGE_REQUEST:?}"
status="${TRUSTED_PHASE_STATUS_PATH:?}"
expected="$(jq -r .head_revision "$request")"
temporary="$status.tmp"

disable() {
  printf 'ADOC_PROPOSE_ELIGIBLE=false\nADOC_TRUSTED_HEAD_CURRENT=false\n' \
    >> "$GITHUB_ENV"
}

if ! ADOC_TRUSTED_PHASE=true TRUSTED_CHANGE_REQUEST="$request" \
  TRUSTED_PHASE_STATUS_PATH="$status" \
  "$SELF/trusted-authorization-current.sh"; then
  disable
  exit 0
fi
jq --arg observed "$expected" '
  .state = "running" | .observed_head_revision = $observed
' "$status" > "$temporary"
mv "$temporary" "$status"
printf 'ADOC_TRUSTED_HEAD_CURRENT=true\n' >> "$GITHUB_ENV"
