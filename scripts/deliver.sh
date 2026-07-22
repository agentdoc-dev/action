#!/usr/bin/env bash
# Delivers validated Knowledge Object drafts beyond the sticky comment:
# `commit` pushes them onto the PR branch, `pr` maintains an idempotent
# follow-up pull request against it. Never fails the job: forks, missing
# permissions, and push rejections degrade to comment-only with a warning —
# the drafts are already in the PR report either way. Runs before the
# comment step so the delivery link lands in the report body.
set -uo pipefail

OUT="${ADOC_RUN_DIR:-$RUNNER_TEMP}"
SELF="$(cd "$(dirname "$0")" && pwd)"

delivery_status() { # status, reason, commit, url
  jq -n --arg status "$1" --arg mode "${PROPOSE_DELIVERY:-comment}" --arg reason "$2" \
    --arg commit "${3:-}" --arg url "${4:-}" \
    '{status:$status,mode:$mode,reason:(if $reason == "" then null else $reason end),
      delivery_commit:(if $commit == "" then null else $commit end),
      url:(if $url == "" then null else $url end)}' > "$OUT/delivery-status.json"
}

fallback() { # machine reason, safe display reason
  delivery_status error "$1" '' ''
  echo "::warning::AgentDoc: could not deliver drafts via ${PROPOSE_DELIVERY} ($2) — they remain in the PR comment"
  exit 0
}

note() { printf '%s\n' "$1" >> "$OUT/delivery.md"; }

case "${PROPOSE_DELIVERY:-comment}" in
  comment) delivery_status skipped comment_only '' ''; exit 0 ;;
  commit | pr) ;;
  *)
    echo "::error::AgentDoc: unsupported propose-delivery '${PROPOSE_DELIVERY}'"
    exit 1
    ;;
esac
if [ "${ADOC_PROPOSE_ELIGIBLE:-true}" != true ]; then
  delivery_status skipped untrusted_pr '' ''
  echo "::warning::AgentDoc: could not deliver drafts via ${PROPOSE_DELIVERY} (fork or Dependabot pull request) — they remain in the PR comment"
  exit 0
fi
[ -s "$OUT/valid.ndjson" ] || { delivery_status skipped no_valid_proposals '' ''; exit 0; }

is_fork="$(gh pr view "$PR_NUMBER" --json isCrossRepository --jq .isCrossRepository)" \
  || fallback pr_query_failed 'could not query the pull request'
[ "$is_fork" = "false" ] || fallback fork_pr 'fork pull request'
git fetch -q origin "$HEAD_REF" || fallback head_fetch_failed "could not fetch ${HEAD_REF}"
# Anti-loop: if the branch tip is already a delivery commit, don't stack
# another one (relevant when a custom github-token retriggers workflows).
if git log -1 --format=%B FETCH_HEAD | grep -qF '[skip-adoc-propose]'; then
  delivery_status skipped already_delivered '' ''
  echo "::notice::AgentDoc: ${HEAD_REF} tip is already a proposal delivery; skipping"
  exit 0
fi
# The job checked out the PR merge commit; deliver on the branch tip.
git checkout -q FETCH_HEAD || fallback head_checkout_failed "could not check out ${HEAD_REF}"
"$SELF/apply-drafts.sh" . || fallback proposal_apply_failed 'validated drafts no longer match a safe branch target'
jq -r '.file' "$OUT/valid.ndjson" | sort -u | tr '\n' '\0' | xargs -0 git add -- \
  || fallback git_add_failed 'git add failed'
git -c user.name='github-actions[bot]' \
    -c user.email='41898282+github-actions[bot]@users.noreply.github.com' \
  commit -qm 'docs(adoc): proposed Knowledge Objects [skip-adoc-propose]' \
  || fallback nothing_to_commit 'nothing to commit'
delivery_commit="$(git rev-parse HEAD)"

case "$PROPOSE_DELIVERY" in
  commit)
    git push -q origin "HEAD:refs/heads/${HEAD_REF}" \
      || fallback push_rejected 'push rejected — commit delivery needs `contents: write`'
    echo "::notice::AgentDoc: pushed proposed Knowledge Objects to ${HEAD_REF}"
    note "_These drafts were pushed to \`${HEAD_REF}\` by the action._"
    delivery_status complete '' "$delivery_commit" ''
    ;;
  pr)
    branch="adoc/proposals/pr-${PR_NUMBER}"
    git push -qf origin "HEAD:refs/heads/${branch}" \
      || fallback push_rejected 'push rejected — pr delivery needs `contents: write`'
    url="$(gh pr list --head "$branch" --json url --jq '.[0].url // empty')"
    if [ -z "$url" ]; then
      url="$(gh pr create --head "$branch" --base "$HEAD_REF" \
        --title "AgentDoc: proposed Knowledge Objects for #${PR_NUMBER}" \
        --body "Knowledge Object drafts for #${PR_NUMBER}, validated with \`adoc check\`. Review and merge into \`${HEAD_REF}\`.")" \
        || fallback pr_create_failed 'could not open the follow-up PR — needs `pull-requests: write`'
    fi
    echo "::notice::AgentDoc: proposal drafts delivered in ${url}"
    note "_These drafts were also delivered as a follow-up pull request: ${url}_"
    delivery_status complete '' "$delivery_commit" "$url"
    ;;
esac
exit 0
