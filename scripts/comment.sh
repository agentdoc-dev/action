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
if [ -z "${ADOC_HEAD:-}" ] || [ "$current_head" != "$ADOC_HEAD" ]; then
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
