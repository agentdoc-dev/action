#!/usr/bin/env bash
# Upserts the sticky Review Report comment, keyed on the marker in its first
# line. Never fails the job: on fork PRs the token is read-only and the
# Review Report is still available in the job summary.
set -uo pipefail

BODY="$RUNNER_TEMP/report.md"
MARKER='<!-- adoc:pr-report -->'
COMMENTS_API="repos/${GITHUB_REPOSITORY}/issues/${PR_NUMBER}/comments"

upsert() {
  local cid
  cid="$(gh api "$COMMENTS_API" --paginate \
    --jq ".[] | select(.body | startswith(\"$MARKER\")) | .id" | head -n1)" || return 1
  if [ -n "$cid" ]; then
    gh api -X PATCH "repos/${GITHUB_REPOSITORY}/issues/comments/${cid}" \
      -F body=@"$BODY" --silent
  else
    gh api -X POST "$COMMENTS_API" -F body=@"$BODY" --silent
  fi
}

if ! upsert; then
  echo "::warning::AgentDoc: could not post the PR comment (fork PR or missing \`pull-requests: write\`); the Review Report is in the job summary"
fi
exit 0
