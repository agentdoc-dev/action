#!/usr/bin/env bash
# Upserts the owned AgentDoc PR report comment series. Never fails the job:
# fork tokens are read-only and the bounded report remains in the job summary.
set -uo pipefail

OUT="${ADOC_RUN_DIR:-$RUNNER_TEMP}"
PARTS="$OUT/comment-parts"
COMMENTS_API="repos/${GITHUB_REPOSITORY}/issues/${PR_NUMBER}/comments"
PART_PREFIX="<!-- adoc:pr-report-part:${GITHUB_REPOSITORY}#${PR_NUMBER}:"

current_head="$(gh api "repos/${GITHUB_REPOSITORY}/pulls/${PR_NUMBER}" --jq .head.sha 2>/dev/null)" || {
  echo '::warning::AgentDoc: could not verify the current pull request head; the report remains in the job summary'
  exit 0
}

owned_delivery_head() {
  local status="$OUT/delivery-status.json"
  local context="$OUT/proposal-context.json"
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

viewer_id="$(gh api user --jq .id 2>/dev/null || true)"
if ! [[ "$viewer_id" =~ ^[0-9]+$ ]] && [ "${GITHUB_ACTIONS:-}" = true ] \
  && [ "${GITHUB_SERVER_URL:-https://github.com}" = https://github.com ]; then
  viewer_id=41898282
fi
if ! [[ "$viewer_id" =~ ^[0-9]+$ ]]; then
  echo '::warning::AgentDoc: could not verify comment ownership; skipped PR comment update'
  exit 0
fi

comments="$OUT/pr-comments.json"
if ! gh api "$COMMENTS_API" --paginate --slurp > "$comments.pages" 2>/dev/null \
  || ! jq -e 'if length == 0 then [] elif (.[0] | type) == "array" then add else . end' \
    "$comments.pages" > "$comments"; then
  echo '::warning::AgentDoc: could not list PR comments; the report remains in the job summary'
  rm -f "$comments.pages" "$comments"
  exit 0
fi
rm -f "$comments.pages"

if [ ! -d "$PARTS" ]; then
  mkdir -m 700 "$PARTS"
  cp "$OUT/report.md" "$PARTS/001.md"
fi

desired="$OUT/desired-comment-markers"
: > "$desired"
success=true
for body in "$PARTS"/*.md; do
  [ -s "$body" ] || continue
  marker="$(sed -n '1p' "$body")"
  printf '%s\n' "$marker" >> "$desired"
  cid="$(jq -r --arg marker "$marker" --argjson viewer "$viewer_id" '
    [.[] | select(.user.id == $viewer and (.body | startswith($marker)))][0].id // empty
  ' "$comments")"
  existing=''
  if [ -n "$cid" ]; then
    existing="$(jq -r --argjson id "$cid" '[.[] | select(.id == $id)][0].body // empty' "$comments")"
  fi
  if [ -n "$cid" ] && [ "$existing" = "$(cat "$body")" ]; then
    continue
  elif [ -n "$cid" ]; then
    gh api -X PATCH "repos/${GITHUB_REPOSITORY}/issues/comments/${cid}" \
      -F body=@"$body" --silent || success=false
  else
    gh api -X POST "$COMMENTS_API" -F body=@"$body" --silent || success=false
  fi
done

if [ "$success" = true ]; then
  jq -r --arg prefix "$PART_PREFIX" --argjson viewer "$viewer_id" '
    .[] | select(.user.id == $viewer and (.body | startswith($prefix)))
    | [.id, (.body | split("\n")[0])] | @tsv
  ' "$comments" | while IFS=$'\t' read -r cid marker; do
    grep -Fqx "$marker" "$desired" && continue
    gh api -X DELETE "repos/${GITHUB_REPOSITORY}/issues/comments/${cid}" --silent \
      || echo "::warning::AgentDoc: could not remove stale report part ${cid}"
  done
else
  echo '::warning::AgentDoc: could not post the complete PR comment series; stale parts were preserved and the report remains in the job summary'
fi

rm -f "$comments" "$desired"
exit 0
