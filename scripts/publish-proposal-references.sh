#!/usr/bin/env bash
# Renders the connected-delivery reference block from the finalized receipt
# and retained delivery evidence, then (pr mode) attaches it to the owned
# proposal PR body. Never rewrites the receipt or delivery status; a failed
# publication exits 0 with status "failed".
set -uo pipefail
umask 077

OUT="${ADOC_RUN_DIR:?}"
SELF="$(cd "$(dirname "$0")" && pwd)"
status_file="$OUT/proposal-references-status.json"
block_path=''
block_sha=''
askpass="$OUT/proposal-references-askpass"
body_file="$OUT/proposal-references-body"
next_file="$OUT/proposal-references-next"
trap 'rm -f -- "$askpass" "$body_file" "$body_file.now" "$next_file"' EXIT

emit_output() { printf '%s=%s\n' "$1" "$2" >> "${GITHUB_OUTPUT:-/dev/null}"; }

finish() { # status, reason
  jq -n --arg status "$1" --arg reason "${2:-}" --arg path "$block_path" \
    --arg sha "$block_sha" '{status:$status,
      reason:(if $reason == "" then null else $reason end),
      path:(if $path == "" then null else $path end),
      sha256:(if $sha == "" then null else $sha end)}' > "$status_file"
  emit_output proposal-references-status "$1"
  emit_output proposal-references-reason "${2:-}"
  emit_output proposal-references-path "$block_path"
  emit_output proposal-references-sha256 "$block_sha"
  [ "$1" != failed ] || echo "::warning::AgentDoc: proposal references were not published ($2); the delivery itself is unchanged"
  exit 0
}

[ -n "${CLOUD_PROPOSAL_RESOLVER:-}" ] || finish skipped disconnected
uuid='[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'
[[ "$CLOUD_PROPOSAL_RESOLVER" =~ ^https://[A-Za-z0-9.-]+(:[0-9]{1,5})?/workspaces/${uuid}$ ]] \
  || finish failed cloud_proposal_resolver_invalid
delivery="$OUT/delivery-status.json"
jq -e '.status == "complete"' "$delivery" >/dev/null 2>&1 \
  || finish skipped delivery_incomplete
set_sha="$(jq -r '.sha256 // empty' "$OUT/proposal-status.json" 2>/dev/null)"
[ -n "$set_sha" ] || finish skipped no_proposal_record
if [ "${BOOTSTRAP:-false}" = true ] || [ -z "${PR_NUMBER:-}" ]; then
  finish skipped no_source_pr
fi
[[ "${GITHUB_REPOSITORY_ID:-}" =~ ^[1-9][0-9]*$ ]] \
  || finish failed repository_id_unavailable
[ -n "${ADOC_RETAINED_DIR:-}" ] && [ -n "${ADOC_INVOCATION_ID:-}" ] \
  || finish failed retained_evidence_missing

# The block binds the exact finalized receipt bytes, not the assessment.
receipt="$ADOC_RETAINED_DIR/receipt-${ADOC_INVOCATION_ID}.json"
receipt_sha="$(cat "$OUT/receipt-sha256" 2>/dev/null)"
[ -f "$receipt" ] && [ -n "$receipt_sha" ] \
  && [ "sha256:$(sha256sum "$receipt" | awk '{print $1}')" = "$receipt_sha" ] \
  || finish failed receipt_digest_mismatch

affected="$ADOC_RETAINED_DIR/delivery-affected-objects-${ADOC_INVOCATION_ID}.json"
commit="$(jq -r '.delivery_commit // empty' "$delivery")"
mode="$(jq -r '.mode // empty' "$delivery")"
path="$ADOC_RETAINED_DIR/proposal-references-${ADOC_INVOCATION_ID}.txt"
rm -f -- "$path"
python3 -B "$SELF/proposal-references.py" render \
  --source-pr-repository-id "$GITHUB_REPOSITORY_ID" \
  --source-pr-number "$PR_NUMBER" \
  --source-head "${ADOC_HEAD:-}" \
  --receipt-sha256 "$receipt_sha" \
  --affected-objects "$affected" \
  --proposal-set-sha256 "$set_sha" > "$path.tmp" \
  || { rm -f -- "$path.tmp"; finish failed render_failed; }
mv "$path.tmp" "$path"
block_path="$path"
block_sha="sha256:$(sha256sum "$path" | awk '{print $1}')"

# ponytail: commit mode has no Action-owned body; the retained block is the
# evidence the Cloud delivery report (E8.2.T2) carries.
[ "$mode" = pr ] || finish retained ''

url="$(jq -r '.url // empty' "$delivery")"
number="${url##*/}"
[[ "$number" =~ ^[1-9][0-9]*$ ]] || finish failed pr_query_failed
fetch_body() { # file; exact body bytes, CRLF normalized like the parser
  gh api "repos/${GITHUB_REPOSITORY}/pulls/${number}" 2>/dev/null \
    | jq -j '(.body // "") | gsub("\r\n"; "\n")' > "$1"
}
owner_line="<!-- AgentDoc-Proposal-Owner: ${GITHUB_REPOSITORY}#${PR_NUMBER} -->"
assessed_line="<!-- AgentDoc-Assessed-Head: ${ADOC_HEAD:-} -->"
fetch_body "$body_file" || finish failed pr_query_failed
grep -Fqx -- "$owner_line" "$body_file" || finish failed proposal_branch_unowned
# D must still be the proposal branch head (deliver.sh query_proposal_branch).
branch="$(jq -r '.branch // empty' "$delivery")"
[ -n "$branch" ] && [ -n "${GH_TOKEN:-}" ] || finish failed pr_query_failed
cat > "$askpass" <<'ASKPASS'
#!/usr/bin/env bash
case "$1" in
  *Username*) printf '%s\n' x-access-token ;;
  *Password*) printf '%s\n' "$GH_TOKEN" ;;
  *) exit 1 ;;
esac
ASKPASS
chmod 700 "$askpass"
branch_line="$(GIT_ASKPASS="$askpass" GIT_TERMINAL_PROMPT=0 \
  git -c credential.helper= ls-remote --refs \
  "${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY}.git" \
  "refs/heads/$branch")" || finish failed pr_query_failed
[ "$(awk -v ref="refs/heads/$branch" '$2 == ref {print $1}' <<< "$branch_line")" \
  = "$commit" ] || finish failed proposal_branch_diverged
python3 -B "$SELF/proposal-references.py" attach "$path" "$body_file" \
  > "$next_file" || finish failed pr_body_markers_invalid
# ponytail: GitHub has no If-Match on PR bodies; this re-read narrows but
# cannot close the TOCTOU window. A per-PR workflow concurrency group closes it.
fetch_body "$body_file.now" || finish failed pr_query_failed
if ! { cmp -s "$body_file" "$body_file.now" \
  && grep -Fqx -- "$owner_line" "$body_file.now" \
  && grep -Fqx -- "$assessed_line" "$body_file.now"; }; then
  finish failed proposal_body_changed
fi
gh api -X PATCH "repos/${GITHUB_REPOSITORY}/pulls/${number}" \
  -F "body=@$next_file" >/dev/null 2>&1 \
  || finish failed pr_update_failed
finish published ''
