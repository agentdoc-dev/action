#!/usr/bin/env bash
# Upserts the sticky PR report comment, keyed on the marker in its first
# line. Never fails the job: on fork PRs the token is read-only and the
# report is still available in the job summary.
set -uo pipefail

BODY="${ADOC_RUN_DIR:-$RUNNER_TEMP}/report.md"
MARKER='<!-- adoc:pr-report -->'
COMMENTS_API="repos/${GITHUB_REPOSITORY}/issues/${PR_NUMBER}/comments"

current_head="$(gh api "repos/${GITHUB_REPOSITORY}/pulls/${PR_NUMBER}" --jq .head.sha 2>/dev/null)" || {
  echo '::warning::AgentDoc: could not verify the current pull request head; the report remains in the job summary'
  exit 0
}

owned_delivery_head() {
  local status="${ADOC_RUN_DIR:-$RUNNER_TEMP}/delivery-status.json"
  local context="${ADOC_RUN_DIR:-$RUNNER_TEMP}/proposal-context.json"
  local commit owner assessment
  [ -s "$status" ] && [ -s "$context" ] || return 1
  jq -e --arg current "$current_head" --arg assessed "${ADOC_HEAD:-}" '
    .status == "complete" and .mode == "commit"
    and .delivery_commit == $current and .assessed_head == $assessed
  ' "$status" >/dev/null 2>&1 || return 1
  commit="$(gh api "repos/${GITHUB_REPOSITORY}/git/commits/${current_head}" \
    2>/dev/null)" || return 1
  owner="${GITHUB_REPOSITORY}#${PR_NUMBER}"
  assessment="$(jq -r .assessment_sha256 "$context")"
  jq -e --arg parent "${ADOC_HEAD:-}" --arg owner "$owner" \
    --arg assessment "$assessment" '
    (.parents | length) == 1 and .parents[0].sha == $parent
    and (.message | split("\n") | index("AgentDoc-Proposal-Owner: " + $owner) != null)
    and (.message | split("\n") | index("AgentDoc-Assessed-Head: " + $parent) != null)
    and (.message | split("\n") | index("AgentDoc-Assessment-SHA256: " + $assessment) != null)
  ' <<< "$commit" >/dev/null 2>&1
}

if [ -z "${ADOC_HEAD:-}" ] \
  || { [ "$current_head" != "$ADOC_HEAD" ] && ! owned_delivery_head; }; then
  echo '::warning::AgentDoc: pull request head changed after assessment; skipped stale comment update'
  exit 0
fi

upsert() {
  local ids cid
  # Collect fully before taking the first id: a mid-stream `head` would
  # SIGPIPE gh under pipefail once the comment list spans multiple pages.
  ids="$(gh api "$COMMENTS_API" --paginate \
    --jq ".[] | select(.body | startswith(\"$MARKER\")) | .id")" || return 1
  cid="${ids%%$'\n'*}"
  if [ -n "$cid" ]; then
    gh api -X PATCH "repos/${GITHUB_REPOSITORY}/issues/comments/${cid}" \
      -F body=@"$BODY" --silent
  else
    gh api -X POST "$COMMENTS_API" -F body=@"$BODY" --silent
  fi
}

if ! upsert; then
  echo "::warning::AgentDoc: could not post the PR comment (fork PR or missing \`pull-requests: write\`); the report is in the job summary"
fi
exit 0
