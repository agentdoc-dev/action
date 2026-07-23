#!/usr/bin/env bash
# Replays validated canonical patches at the exact assessed head, then
# delivers the resulting draft-only source commit without bypassing GitHub.
set -uo pipefail

OUT="${ADOC_RUN_DIR:-${RUNNER_TEMP:?}}"
mode="${PROPOSE_DELIVERY:-comment}"
repo=''
sandbox=''
askpass=''

delivery_status() { # status, reason, commit, branch, url
  jq -n --arg status "$1" --arg mode "$mode" --arg reason "${2:-}" \
    --arg assessed "${ADOC_HEAD:-}" --arg commit "${3:-}" \
    --arg branch "${4:-}" --arg url "${5:-}" '{
      status:$status,mode:$mode,
      reason:(if $reason == "" then null else $reason end),
      assessed_head:(if $assessed == "" then null else $assessed end),
      delivery_commit:(if $commit == "" then null else $commit end),
      branch:(if $branch == "" then null else $branch end),
      url:(if $url == "" then null else $url end)
    }' > "$OUT/delivery-status.json"
}

# shellcheck disable=SC2329 # invoked by traps
cleanup() {
  if [ -n "$repo" ] && [ -n "$sandbox" ] \
    && git -C "$repo" worktree list --porcelain 2>/dev/null \
      | grep -Fqx "worktree $sandbox"; then
    git -C "$repo" worktree remove --force "$sandbox" >/dev/null 2>&1 || :
  fi
  rm -rf -- "$OUT"/delivery-build-* "$sandbox"
  rm -f -- "$OUT/delivery-written" "$OUT/delivery-expected" \
    "$OUT/delivery-actual" "$OUT/delivery-untracked" \
    "$OUT/delivery-object-set.json" "$OUT/delivery-message" "$askpass"
}
trap cleanup EXIT
trap 'exit 1' INT TERM

fallback() { # safe reason
  delivery_status error "$1" '' '' ''
  echo "::warning::AgentDoc: ${mode} delivery was not completed ($1); canonical drafts remain in the report"
  exit 0
}

skip() { # safe reason
  delivery_status skipped "$1" '' '' ''
  exit 0
}

pull_request() {
  gh api "repos/${GITHUB_REPOSITORY}/pulls/${PR_NUMBER}" 2>/dev/null
}

assert_live_head() {
  local response="$1"
  jq -e --arg repo "$GITHUB_REPOSITORY" --arg ref "$HEAD_REF" \
    --arg head "$ADOC_HEAD" '
      .state == "open" and .head.repo.full_name == $repo
      and .head.ref == $ref and .head.sha == $head
    ' <<< "$response" >/dev/null 2>&1
}

auth_git() {
  GIT_ASKPASS="$askpass" GIT_TERMINAL_PROMPT=0 \
    git -c credential.helper= -c credential.interactive=never "$@"
}

case "$mode" in
  comment) skip comment_only ;;
  commit | pr) ;;
  *) fallback delivery_contract_failed ;;
esac
[ "${ADOC_PROPOSE_ELIGIBLE:-true}" = true ] || skip untrusted_pr
[ -s "$OUT/patch-manifest.ndjson" ] || skip no_valid_proposals

repo="$(git rev-parse --show-toplevel 2>/dev/null)" \
  || fallback manifest_contract_failed
prefix="$(git rev-parse --show-prefix 2>/dev/null)" \
  || fallback manifest_contract_failed
out_physical="$(cd "$OUT" 2>/dev/null && pwd -P)" \
  || fallback manifest_contract_failed
sandbox="$out_physical/delivery-worktree"
manifest="$OUT/patch-manifest.ndjson"
context="$OUT/proposal-context.json"
proposal="$OUT/proposal-status.json"

if ! jq -se '
  length > 0 and length <= 100 and all(.[];
    type == "object"
    and .schema_version == "adoc.patch.v0"
    and .operation == "create_object"
    and (.target | type == "string" and length > 0)
    and (.kind | IN("claim","decision","api","task"))
    and (.status | IN("draft","proposed","open"))
    and (.placement_path | type == "string" and endswith(".adoc"))
    and (.path | type == "string")
    and (.sha256 | test("^sha256:[0-9a-f]{64}$")))
' "$manifest" >/dev/null 2>&1; then
  fallback manifest_contract_failed
fi
if ! jq -e --arg head "$ADOC_HEAD" --arg date "$ADOC_EVALUATION_DATE" '
  type == "object"
  and .revisions.head == $head and .evaluation_date == $date
  and (.assessment_sha256 | test("^sha256:[0-9a-f]{64}$"))
  and (.graph_sha256 | test("^sha256:[0-9a-f]{64}$"))
  and (.object_set_sha256 | test("^sha256:[0-9a-f]{64}$"))
' "$context" >/dev/null 2>&1; then
  fallback manifest_contract_failed
fi
count="$(wc -l < "$manifest" | tr -d ' ')"
set_sha="sha256:$(jq -sc 'map(.sha256)' "$manifest" | sha256sum | awk '{print $1}')"
if ! jq -e --argjson count "$count" --arg sha "$set_sha" '
  (.status | IN("complete","partial"))
  and .count == $count and .sha256 == $sha
' "$proposal" >/dev/null 2>&1; then
  fallback manifest_contract_failed
fi

while IFS= read -r item; do
  patch="$(jq -r .path <<< "$item")"
  patch_physical="$(realpath "$patch" 2>/dev/null)" \
    || fallback manifest_contract_failed
  case "$patch_physical" in
    "$out_physical"/patches/*) ;;
    *) fallback manifest_contract_failed ;;
  esac
  [ -f "$patch_physical" ] && [ ! -L "$patch" ] \
    || fallback manifest_contract_failed
  [ "sha256:$(sha256sum "$patch_physical" | awk '{print $1}')" \
    = "$(jq -r .sha256 <<< "$item")" ] || fallback manifest_contract_failed
  jq -e --arg target "$(jq -r .target <<< "$item")" '
    .schema_version == "adoc.patch.v0" and .op == "create_object"
    and .target == $target and (.base_hash | not)
  ' "$patch_physical" >/dev/null 2>&1 || fallback manifest_contract_failed
  placement="$(jq -r .placement_path <<< "$item")"
  case "$placement" in
    /* | *..* | *$'\n'* | *$'\r'*) fallback manifest_contract_failed ;;
    *.adoc) ;;
    *) fallback manifest_contract_failed ;;
  esac
done < "$manifest"

pr_json="$(pull_request)" || fallback pr_query_failed
assert_live_head "$pr_json" || fallback stale_head
if git -C "$repo" config --local --get-regexp \
  '^http\..*\.extraheader$' >/dev/null 2>&1; then
  fallback persisted_checkout_credentials
fi

owner="${GITHUB_REPOSITORY}#${PR_NUMBER}"
if git -C "$repo" show -s --format=%B "$ADOC_HEAD" 2>/dev/null \
  | grep -Fqx "AgentDoc-Proposal-Owner: $owner"; then
  skip already_delivered
fi
git -C "$repo" cat-file -e "${ADOC_HEAD}^{commit}" 2>/dev/null \
  || fallback stale_head
git -C "$repo" worktree add --detach "$sandbox" "$ADOC_HEAD" >/dev/null 2>&1 \
  || fallback delivery_check_failed
sandbox_workdir="$sandbox/${prefix%/}"
[ -d "$sandbox_workdir" ] || fallback delivery_check_failed

check_and_build() { # label
  local label="$1"
  local build="$OUT/delivery-build-$label"
  (cd "$sandbox_workdir" && adoc check --as-of "$ADOC_EVALUATION_DATE" \
    --format json > "$OUT/delivery-check-$label.json" \
    2>"$OUT/delivery-check-$label.stderr") || return 1
  mkdir -m 700 "$build"
  (cd "$sandbox_workdir" && adoc build --as-of "$ADOC_EVALUATION_DATE" \
    --no-embeddings --out "$build" >/dev/null \
    2>"$OUT/delivery-build-$label.stderr") || return 1
  printf '%s/docs.graph.json\n' "$build"
}

graph="$(check_and_build initial)" || fallback delivery_check_failed
[ "sha256:$(sha256sum "$graph" | awk '{print $1}')" \
  = "$(jq -r .graph_sha256 "$context")" ] || fallback patch_revalidation_failed
jq -c '[.nodes[] | select(.type == "knowledge_object") | {id,content_hash}] | sort_by(.id)' \
  "$graph" | tr -d '\n' > "$OUT/delivery-object-set.json"
[ "sha256:$(sha256sum "$OUT/delivery-object-set.json" | awk '{print $1}')" \
  = "$(jq -r .object_set_sha256 "$context")" ] \
  || fallback patch_revalidation_failed

: > "$OUT/delivery-written"
index=0
while IFS= read -r item; do
  index=$((index + 1))
  ordinal="$(printf '%03d' "$index")"
  patch="$(jq -r .path <<< "$item")"
  target="$(jq -r .target <<< "$item")"
  placement="$(jq -r .placement_path <<< "$item")"
  before="sha256:$(sha256sum "$sandbox_workdir/$placement" 2>/dev/null \
    | awk '{print $1}')"
  (cd "$sandbox_workdir" && adoc patch --check "$patch" --artifact "$graph" \
    --as-of "$ADOC_EVALUATION_DATE" --format json \
    > "$OUT/delivery-patch-check-$ordinal.json" \
    2>"$OUT/delivery-patch-check-$ordinal.stderr") \
    || fallback patch_revalidation_failed
  jq -e --arg target "$target" '
    .schema_version == "adoc.patch.check.v0" and .valid == true
    and .target == $target and .operation == "create_object"
  ' "$OUT/delivery-patch-check-$ordinal.json" >/dev/null 2>&1 \
    || fallback patch_revalidation_failed
  (cd "$sandbox_workdir" && adoc patch --apply "$patch" --artifact "$graph" \
    --as-of "$ADOC_EVALUATION_DATE" --format json \
    > "$OUT/delivery-patch-apply-$ordinal.json" \
    2>"$OUT/delivery-patch-apply-$ordinal.stderr") \
    || fallback patch_revalidation_failed
  jq -e --arg path "$placement" --arg before "$before" '
    .schema_version == "adoc.patch.apply.v0" and .applied == true
    and (.written_files | length) == 1
    and .written_files[0].path == $path
    and .written_files[0].before_file_hash == $before
    and (.written_files[0].after_file_hash | test("^sha256:[0-9a-f]{64}$"))
  ' "$OUT/delivery-patch-apply-$ordinal.json" >/dev/null 2>&1 \
    || fallback patch_revalidation_failed
  after="$(jq -r .written_files[0].after_file_hash \
    "$OUT/delivery-patch-apply-$ordinal.json")"
  [ "sha256:$(sha256sum "$sandbox_workdir/$placement" | awk '{print $1}')" \
    = "$after" ] || fallback patch_revalidation_failed
  printf '%s%s\n' "$prefix" "$placement" >> "$OUT/delivery-written"
  graph="$(check_and_build "$ordinal")" || fallback delivery_build_failed
  jq -e --arg target "$target" '
    any(.nodes[]; .type == "knowledge_object" and .id == $target)
  ' "$graph" >/dev/null 2>&1 || fallback delivery_build_failed
done < "$manifest"
check_and_build final >/dev/null || fallback delivery_build_failed

sort -u "$OUT/delivery-written" > "$OUT/delivery-expected"
git -C "$sandbox" diff --name-only -- | sort > "$OUT/delivery-actual"
git -C "$sandbox" ls-files --others --exclude-standard \
  > "$OUT/delivery-untracked"
[ ! -s "$OUT/delivery-untracked" ] || fallback unexpected_source_changes
cmp -s "$OUT/delivery-expected" "$OUT/delivery-actual" \
  || fallback unexpected_source_changes
while IFS= read -r path; do
  case "$path" in *.adoc) ;; *) fallback unexpected_source_changes ;; esac
  git -C "$sandbox" add -- "$path" || fallback commit_failed
done < "$OUT/delivery-expected"
git -C "$sandbox" diff --quiet -- || fallback unexpected_source_changes
[ ! -s "$OUT/delivery-untracked" ] || fallback unexpected_source_changes

assessment_sha="$(jq -r .assessment_sha256 "$context")"
semantic_sha="$(jq -r '
  if .status == "complete" then .sha256 else "not-published" end
' "$OUT/semantic-status.json" 2>/dev/null || echo not-published)"
targets="$(jq -sr 'map(.target) | join(", ")' "$manifest")"
source_url="${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY}/pull/${PR_NUMBER}"
{
  echo 'docs(adoc): propose Knowledge Objects [skip-adoc-propose]'
  echo
  echo "Source-PR: $source_url"
  echo "Assessment-SHA256: $assessment_sha"
  echo "Semantic-Review-SHA256: $semantic_sha"
  echo "Proposal-Targets: $targets"
  echo 'Governance: Human owners must resolve the report proof obligations before merge.'
  echo
  echo "AgentDoc-Proposal-Owner: $owner"
  echo "AgentDoc-Assessed-Head: $ADOC_HEAD"
  echo "AgentDoc-Assessment-SHA256: $assessment_sha"
} > "$OUT/delivery-message"
git -C "$sandbox" -c user.name='github-actions[bot]' \
  -c user.email='41898282+github-actions[bot]@users.noreply.github.com' \
  -c commit.gpgsign=false commit -q -F "$OUT/delivery-message" \
  || fallback commit_failed
delivery_commit="$(git -C "$sandbox" rev-parse HEAD)"
[ "$(git -C "$sandbox" rev-list --parents -n 1 HEAD | wc -w | tr -d ' ')" = 2 ] \
  && [ "$(git -C "$sandbox" rev-parse HEAD^)" = "$ADOC_HEAD" ] \
  || fallback commit_failed

askpass="$OUT/delivery-askpass"
cat > "$askpass" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  *Username*) printf '%s\n' x-access-token ;;
  *Password*) printf '%s\n' "$GH_TOKEN" ;;
  *) exit 1 ;;
esac
EOF
chmod 700 "$askpass"
[ -n "${GH_TOKEN:-}" ] || fallback push_rejected

case "$mode" in
  commit)
    pr_json="$(pull_request)" || fallback pr_query_failed
    assert_live_head "$pr_json" || fallback stale_head
    auth_git -C "$sandbox" push --quiet origin \
      "${delivery_commit}:refs/heads/${HEAD_REF}" || fallback push_rejected
    printf '%s\n' "_Canonical drafts were pushed to the source PR branch as commit \`$delivery_commit\`. Required owners and proof obligations remain human-governed._" \
      > "$OUT/delivery.md"
    delivery_status complete '' "$delivery_commit" "$HEAD_REF" ''
    ;;
  pr)
    fallback governed_delivery_deferred
    ;;
esac

exit 0
