#!/usr/bin/env bash
# Delivers validated Knowledge Object drafts beyond the sticky comment:
# `commit` pushes them onto the PR branch, `pr` maintains an idempotent
# follow-up pull request against it. Never fails the job: forks, missing
# permissions, and push rejections degrade to comment-only with a warning —
# the drafts are already in the PR report either way. Runs before the
# comment step so the delivery link lands in the report body.
set -uo pipefail

OUT="$RUNNER_TEMP"
SELF="$(cd "$(dirname "$0")" && pwd)"

fallback() {
  echo "::warning::AgentDoc: could not deliver drafts via ${PROPOSE_DELIVERY} ($1) — they remain in the PR comment"
  exit 0
}

note() { printf '\n%s\n' "$1" >> "$OUT/report.md"; }

case "${PROPOSE_DELIVERY:-comment}" in
  comment) exit 0 ;;
  commit | pr) ;;
  *)
    echo "::error::AgentDoc: unsupported propose-delivery '${PROPOSE_DELIVERY}'"
    exit 1
    ;;
esac
[ -s "$OUT/valid.ndjson" ] || exit 0

is_fork="$(gh pr view "$PR_NUMBER" --json isCrossRepository --jq .isCrossRepository)" \
  || fallback "could not query the pull request"
[ "$is_fork" = "false" ] || fallback "fork pull request"
git fetch -q origin "$HEAD_REF" || fallback "could not fetch ${HEAD_REF}"
# Anti-loop: if the branch tip is already a delivery commit, don't stack
# another one (relevant when a custom github-token retriggers workflows).
if git log -1 --format=%B FETCH_HEAD | grep -qF '[skip-adoc-propose]'; then
  echo "::notice::AgentDoc: ${HEAD_REF} tip is already a proposal delivery; skipping"
  exit 0
fi
# The job checked out the PR merge commit; deliver on the branch tip.
git checkout -q FETCH_HEAD || fallback "could not check out ${HEAD_REF}"
"$SELF/apply-drafts.sh" .
jq -r '.file' "$OUT/valid.ndjson" | sort -u | tr '\n' '\0' | xargs -0 git add -- \
  || fallback "git add failed"
git -c user.name='github-actions[bot]' \
    -c user.email='41898282+github-actions[bot]@users.noreply.github.com' \
  commit -qm 'docs(adoc): proposed Knowledge Objects [skip-adoc-propose]' \
  || fallback "nothing to commit"

case "$PROPOSE_DELIVERY" in
  commit)
    git push -q origin "HEAD:refs/heads/${HEAD_REF}" \
      || fallback "push rejected — commit delivery needs \`contents: write\`"
    echo "::notice::AgentDoc: pushed proposed Knowledge Objects to ${HEAD_REF}"
    note "_These drafts were pushed to \`${HEAD_REF}\` by the action._"
    ;;
  pr)
    branch="adoc/proposals/pr-${PR_NUMBER}"
    git push -qf origin "HEAD:refs/heads/${branch}" \
      || fallback "push rejected — pr delivery needs \`contents: write\`"
    url="$(gh pr list --head "$branch" --json url --jq '.[0].url // empty')"
    if [ -z "$url" ]; then
      url="$(gh pr create --head "$branch" --base "$HEAD_REF" \
        --title "AgentDoc: proposed Knowledge Objects for #${PR_NUMBER}" \
        --body "Knowledge Object drafts for #${PR_NUMBER}, validated with \`adoc check\`. Review and merge into \`${HEAD_REF}\`.")" \
        || fallback "could not open the follow-up PR — needs \`pull-requests: write\`"
    fi
    echo "::notice::AgentDoc: proposal drafts delivered in ${url}"
    note "_These drafts were also delivered as a follow-up pull request: ${url}_"
    ;;
esac
exit 0
