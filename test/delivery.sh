#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ADOC_BIN="${ADOC_BIN:-$ROOT/../adoc/target/debug/adoc}"
CASE_DIR="$(mktemp -d)"
trap 'rm -rf "$CASE_DIR"' EXIT
mkdir -p "$CASE_DIR/bin" "$CASE_DIR/out/patches" "$CASE_DIR/repo"

cp -R "$ROOT/test/fixture-clean/." "$CASE_DIR/repo"
git -C "$CASE_DIR/repo" init -q -b feature
git -C "$CASE_DIR/repo" config user.name author
git -C "$CASE_DIR/repo" config user.email author@example.com
git -C "$CASE_DIR/repo" add -A
git -C "$CASE_DIR/repo" commit -qm base
printf 'source change\n' > "$CASE_DIR/repo/app.txt"
git -C "$CASE_DIR/repo" add app.txt
git -C "$CASE_DIR/repo" commit -qm feature
assessed_head="$(git -C "$CASE_DIR/repo" rev-parse HEAD)"
git clone -q --bare "$CASE_DIR/repo" "$CASE_DIR/remote.git"
git -C "$CASE_DIR/repo" remote add origin "$CASE_DIR/remote.git"

ln -s "$ADOC_BIN" "$CASE_DIR/bin/adoc"
date=2026-07-23
(cd "$CASE_DIR/repo" && "$ADOC_BIN" build --as-of "$date" --no-embeddings \
  --out "$CASE_DIR/initial" >/dev/null)
graph="$CASE_DIR/initial/docs.graph.json"
graph_sha="sha256:$(sha256sum "$graph" | awk '{print $1}')"
jq -c '[.nodes[] | select(.type == "knowledge_object") | {id,content_hash}] | sort_by(.id)' \
  "$graph" | tr -d '\n' > "$CASE_DIR/object-set.json"
object_sha="sha256:$(sha256sum "$CASE_DIR/object-set.json" | awk '{print $1}')"

jq -n '{
  schema_version:"adoc.patch.v0",op:"create_object",
  target:"fixture.delivered.claim",
  changes:{
    kind:"claim",status:"draft",body:"A human-governed draft.",
    fields:{owner:"docs"},
    placement:{page_id:"fixture.kb",after:"fixture.ci.green"}
  },
  reason:("AgentDoc assessment sha256:" + ("a" * 64) + " finding finding-001."),
  proposer:{type:"agent",id:"agentdoc-action/claude-code@2.1.215/claude-sonnet-5"}
}' > "$CASE_DIR/out/patches/patch.json"
patch_sha="sha256:$(sha256sum "$CASE_DIR/out/patches/patch.json" | awk '{print $1}')"
"$ADOC_BIN" patch --check "$CASE_DIR/out/patches/patch.json" \
  --artifact "$graph" --as-of "$date" --format json \
  > "$CASE_DIR/out/patch-check.json"
jq -cn --arg path "$CASE_DIR/out/patches/patch.json" --arg sha "$patch_sha" '{
  schema_version:"adoc.patch.v0",operation:"create_object",
  target:"fixture.delivered.claim",kind:"claim",status:"draft",
  finding_id:"finding-001",placement_path:"index.adoc",page_id:"fixture.kb",
  path:$path,sha256:$sha,
  check_path:"placeholder",check_sha256:("sha256:" + ("1" * 64))
}' > "$CASE_DIR/out/patch-manifest.ndjson"
set_sha="sha256:$(jq -sc 'map(.sha256)' "$CASE_DIR/out/patch-manifest.ndjson" \
  | sha256sum | awk '{print $1}')"
jq -n --arg sha "$set_sha" \
  '{status:"complete",count:1,sha256:$sha,reason:"validated"}' \
  > "$CASE_DIR/out/proposal-status.json"
jq -n --arg head "$assessed_head" --arg date "$date" \
  --arg graph "$graph_sha" --arg objects "$object_sha" '{
  assessment_sha256:("sha256:" + ("a" * 64)),
  revisions:{comparison_base:$head,head:$head},evaluation_date:$date,
  graph_sha256:$graph,object_set_sha256:$objects
}' > "$CASE_DIR/out/proposal-context.json"

refresh_patch_assessment() {
  local assessment="$1" sha set
  jq --arg reason "AgentDoc assessment $assessment finding finding-001." \
    '.reason = $reason' "$CASE_DIR/out/patches/patch.json" \
    > "$CASE_DIR/patch.next"
  mv "$CASE_DIR/patch.next" "$CASE_DIR/out/patches/patch.json"
  sha="sha256:$(sha256sum "$CASE_DIR/out/patches/patch.json" | awk '{print $1}')"
  jq -c --arg sha "$sha" '.sha256 = $sha' "$CASE_DIR/out/patch-manifest.ndjson" \
    > "$CASE_DIR/manifest.next"
  mv "$CASE_DIR/manifest.next" "$CASE_DIR/out/patch-manifest.ndjson"
  set="sha256:$(jq -sc 'map(.sha256)' "$CASE_DIR/out/patch-manifest.ndjson" \
    | sha256sum | awk '{print $1}')"
  jq --arg sha "$set" '.sha256 = $sha' "$CASE_DIR/out/proposal-status.json" \
    > "$CASE_DIR/proposal.next"
  mv "$CASE_DIR/proposal.next" "$CASE_DIR/out/proposal-status.json"
}

cat > "$CASE_DIR/bin/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CASE_DIR/gh.log"
if [ "${1:-}" = pr ] && [ "${2:-}" = list ]; then
  if [ -f "$CASE_DIR/pr-state.json" ]; then
    cat "$CASE_DIR/pr-state.json"
  else
    printf '%s\n' '[]'
  fi
  exit 0
fi
if [ "${1:-}" = pr ] && [ "${2:-}" = create ]; then
  [ ! -f "$CASE_DIR/pr-create-fail" ] || exit 1
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --body-file) cp "$2" "$CASE_DIR/pr-body.md"; shift 2 ;;
      *) shift ;;
    esac
  done
  sha="$(git --git-dir="$CASE_DIR/remote.git" rev-parse refs/heads/adoc/proposals/pr-7)"
  body="$(cat "$CASE_DIR/pr-body.md")"
  jq -n --arg sha "$sha" --arg body "$body" '[{
    number:8,state:"OPEN",url:"https://github.com/agentdoc/test/pull/8",
    headRefName:"adoc/proposals/pr-7",headRefOid:$sha,
    baseRefName:"feature",body:$body
  }]' > "$CASE_DIR/pr-state.json"
  printf '%s\n' 'https://github.com/agentdoc/test/pull/8'
  exit 0
fi
if [ "${1:-}" = pr ] && [ "${2:-}" = edit ]; then
  if [ -f "$CASE_DIR/pr-edit-race" ]; then
    git --git-dir="$CASE_DIR/remote.git" update-ref \
      refs/heads/adoc/proposals/pr-7 refs/heads/feature
    exit 1
  fi
  [ ! -f "$CASE_DIR/pr-edit-fail" ] || exit 1
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --body-file) cp "$2" "$CASE_DIR/pr-body.md"; shift 2 ;;
      *) shift ;;
    esac
  done
  sha="$(git --git-dir="$CASE_DIR/remote.git" rev-parse refs/heads/adoc/proposals/pr-7)"
  body="$(cat "$CASE_DIR/pr-body.md")"
  jq -n --arg sha "$sha" --arg body "$body" '[{
    number:8,state:"OPEN",url:"https://github.com/agentdoc/test/pull/8",
    headRefName:"adoc/proposals/pr-7",headRefOid:$sha,
    baseRefName:"feature",body:$body
  }]' > "$CASE_DIR/pr-state.json"
  exit 0
fi
for arg in "$@"; do
  [ "$arg" = repos/agentdoc/test/issues/7/comments ] || continue
  for field in "$@"; do
    case "$field" in body=@*) cp "${field#body=@}" "$CASE_DIR/comment.md" ;; esac
  done
  exit 0
done
case "${1:-} ${2:-}" in
  "api repos/agentdoc/test/pulls/7")
    sha="$(git --git-dir="$CASE_DIR/remote.git" rev-parse refs/heads/feature)"
    if [ "${3:-}" = --jq ]; then
      printf '%s\n' "$sha"
      exit 0
    fi
    jq -n --arg sha "$sha" '{
      state:"open",html_url:"https://github.com/agentdoc/test/pull/7",
      head:{sha:$sha,ref:"feature",repo:{full_name:"agentdoc/test"}}
    }'
    ;;
  "api repos/agentdoc/test/git/commits/"*)
    sha="${2##*/}"
    parent="$(git --git-dir="$CASE_DIR/remote.git" rev-parse "$sha^")"
    message="$(git --git-dir="$CASE_DIR/remote.git" show -s --format=%B "$sha")"
    jq -n --arg sha "$sha" --arg parent "$parent" --arg message "$message" \
      '{sha:$sha,parents:[{sha:$parent}],message:$message}'
    ;;
  *) exit 9 ;;
esac
EOF
chmod +x "$CASE_DIR/bin/gh"

run_delivery() {
  (
    cd "$CASE_DIR/repo"
    env PATH="$CASE_DIR/bin:$PATH" CASE_DIR="$CASE_DIR" \
    ADOC_RUN_DIR="$CASE_DIR/out" ADOC_PROPOSE_ELIGIBLE=true \
    ADOC_HEAD="${TEST_HEAD:-$assessed_head}" ADOC_EVALUATION_DATE="$date" \
    GITHUB_REPOSITORY=agentdoc/test GITHUB_SERVER_URL=https://github.com \
    PR_NUMBER=7 HEAD_REF=feature PROPOSE_DELIVERY="${TEST_MODE:-commit}" GH_TOKEN=test-token \
    "$ROOT/scripts/deliver.sh"
  )
}

run_delivery

delivered_head="$(git --git-dir="$CASE_DIR/remote.git" rev-parse refs/heads/feature)"
test "$delivered_head" != "$assessed_head"
test "$(git --git-dir="$CASE_DIR/remote.git" rev-parse "$delivered_head^")" = "$assessed_head"
git --git-dir="$CASE_DIR/remote.git" show "$delivered_head:index.adoc" \
  | grep -Fq '::claim fixture.delivered.claim'
test "$(git --git-dir="$CASE_DIR/remote.git" diff-tree --no-commit-id --name-only -r "$delivered_head")" = index.adoc
git --git-dir="$CASE_DIR/remote.git" show -s --format=%B "$delivered_head" \
  | grep -Fq 'AgentDoc-Proposal-Owner: agentdoc/test#7'
jq -e --arg assessed "$assessed_head" --arg delivered "$delivered_head" '
  .status == "complete" and .mode == "commit" and .reason == null
  and .assessed_head == $assessed and .delivery_commit == $delivered
  and .branch == "feature" and .url == null
' "$CASE_DIR/out/delivery-status.json" >/dev/null

printf '%s\n' '<!-- adoc:pr-report -->' 'owned delivery report' \
  > "$CASE_DIR/out/report.md"
(
  cd "$CASE_DIR/repo"
  env PATH="$CASE_DIR/bin:$PATH" CASE_DIR="$CASE_DIR" \
    ADOC_RUN_DIR="$CASE_DIR/out" ADOC_HEAD="$assessed_head" \
    GITHUB_REPOSITORY=agentdoc/test PR_NUMBER=7 GH_TOKEN=test-token \
    "$ROOT/scripts/comment.sh"
)
cmp "$CASE_DIR/out/report.md" "$CASE_DIR/comment.md"

# An older run cannot push or overwrite the report after the source head moves.
run_delivery
jq -e '.status == "error" and .reason == "stale_head"' \
  "$CASE_DIR/out/delivery-status.json" >/dev/null

# The bot-owned synchronize event does not stack another delivery commit.
jq --arg head "$delivered_head" '.revisions.head = $head' \
  "$CASE_DIR/out/proposal-context.json" > "$CASE_DIR/context.next"
mv "$CASE_DIR/context.next" "$CASE_DIR/out/proposal-context.json"
TEST_HEAD="$delivered_head" run_delivery
jq -e '.status == "skipped" and .reason == "already_delivered"' \
  "$CASE_DIR/out/delivery-status.json" >/dev/null

# Persisted checkout credentials are rejected before any patch is replayed.
git --git-dir="$CASE_DIR/remote.git" update-ref refs/heads/feature "$assessed_head"
jq --arg head "$assessed_head" '.revisions.head = $head' \
  "$CASE_DIR/out/proposal-context.json" > "$CASE_DIR/context.next"
mv "$CASE_DIR/context.next" "$CASE_DIR/out/proposal-context.json"
git -C "$CASE_DIR/repo" config --local \
  http.https://github.com/.extraheader 'AUTHORIZATION: basic secret'
run_delivery
jq -e '.status == "error" and .reason == "persisted_checkout_credentials"' \
  "$CASE_DIR/out/delivery-status.json" >/dev/null
test "$(git --git-dir="$CASE_DIR/remote.git" rev-parse refs/heads/feature)" = "$assessed_head"
git -C "$CASE_DIR/repo" config --local --unset-all \
  http.https://github.com/.extraheader

cp "$CASE_DIR/out/patches/patch.json" "$CASE_DIR/patch.backup"
jq '.changes.body = "tampered after validation"' \
  "$CASE_DIR/patch.backup" > "$CASE_DIR/out/patches/patch.json"
run_delivery
jq -e '.status == "error" and .reason == "manifest_contract_failed"' \
  "$CASE_DIR/out/delivery-status.json" >/dev/null
test "$(git --git-dir="$CASE_DIR/remote.git" rev-parse refs/heads/feature)" = "$assessed_head"
cp "$CASE_DIR/patch.backup" "$CASE_DIR/out/patches/patch.json"

# Follow-up delivery creates one owned branch and one stacked proposal PR.
export TEST_MODE=pr
run_delivery
unset TEST_MODE
proposal_head="$(git --git-dir="$CASE_DIR/remote.git" \
  rev-parse refs/heads/adoc/proposals/pr-7)"
git --git-dir="$CASE_DIR/remote.git" show "$proposal_head:index.adoc" \
  | grep -Fq '::claim fixture.delivered.claim'
jq -e --arg assessed "$assessed_head" --arg delivered "$proposal_head" '
  .status == "complete" and .mode == "pr" and .reason == null
  and .assessed_head == $assessed and .delivery_commit == $delivered
  and .branch == "adoc/proposals/pr-7"
  and .url == "https://github.com/agentdoc/test/pull/8"
' "$CASE_DIR/out/delivery-status.json" >/dev/null
grep -Fq '<!-- AgentDoc-Proposal-Owner: agentdoc/test#7 -->' \
  "$CASE_DIR/pr-body.md"
grep -Fq "<!-- AgentDoc-Assessed-Head: $assessed_head -->" \
  "$CASE_DIR/pr-body.md"

export TEST_MODE=pr
run_delivery
unset TEST_MODE
jq -e '.status == "complete" and .mode == "pr"
  and .url == "https://github.com/agentdoc/test/pull/8"' \
  "$CASE_DIR/out/delivery-status.json" >/dev/null
test "$(grep -c '^pr create ' "$CASE_DIR/gh.log")" = 1
test "$(grep -c '^pr edit ' "$CASE_DIR/gh.log")" = 1

owned_proposal_head="$(git --git-dir="$CASE_DIR/remote.git" \
  rev-parse refs/heads/adoc/proposals/pr-7)"
git clone -q --branch adoc/proposals/pr-7 "$CASE_DIR/remote.git" \
  "$CASE_DIR/human"
git -C "$CASE_DIR/human" config user.name human
git -C "$CASE_DIR/human" config user.email human@example.com
printf '\nHuman edit.\n' >> "$CASE_DIR/human/index.adoc"
git -C "$CASE_DIR/human" commit -qam 'docs: human proposal edit'
git -C "$CASE_DIR/human" push -q origin adoc/proposals/pr-7
human_head="$(git -C "$CASE_DIR/human" rev-parse HEAD)"
jq --arg head "$human_head" '.[0].headRefOid = $head' \
  "$CASE_DIR/pr-state.json" > "$CASE_DIR/pr-state.next"
mv "$CASE_DIR/pr-state.next" "$CASE_DIR/pr-state.json"
export TEST_MODE=pr
run_delivery
unset TEST_MODE
jq -e '.status == "error" and .reason == "proposal_branch_diverged"' \
  "$CASE_DIR/out/delivery-status.json" >/dev/null
test "$(git --git-dir="$CASE_DIR/remote.git" \
  rev-parse refs/heads/adoc/proposals/pr-7)" = "$human_head"

git --git-dir="$CASE_DIR/remote.git" update-ref \
  refs/heads/adoc/proposals/pr-7 "$owned_proposal_head"
jq --arg head "$owned_proposal_head" \
  '.[0].headRefOid = $head | .[0].state = "CLOSED"' \
  "$CASE_DIR/pr-state.json" > "$CASE_DIR/pr-state.next"
mv "$CASE_DIR/pr-state.next" "$CASE_DIR/pr-state.json"
export TEST_MODE=pr
run_delivery
unset TEST_MODE
jq -e '.status == "error" and .reason == "proposal_pr_closed"' \
  "$CASE_DIR/out/delivery-status.json" >/dev/null

rm "$CASE_DIR/pr-state.json"
export TEST_MODE=pr
run_delivery
unset TEST_MODE
jq -e '.status == "error" and .reason == "proposal_branch_unowned"' \
  "$CASE_DIR/out/delivery-status.json" >/dev/null

git --git-dir="$CASE_DIR/remote.git" update-ref -d \
  refs/heads/adoc/proposals/pr-7
touch "$CASE_DIR/pr-create-fail"
export TEST_MODE=pr
run_delivery
unset TEST_MODE
jq -e '.status == "error" and .reason == "pr_creation_not_permitted"' \
  "$CASE_DIR/out/delivery-status.json" >/dev/null
if git --git-dir="$CASE_DIR/remote.git" show-ref --verify --quiet \
  refs/heads/adoc/proposals/pr-7; then
  echo 'failed PR creation left its proposal branch behind' >&2
  exit 1
fi

rm "$CASE_DIR/pr-create-fail"
export TEST_MODE=pr
run_delivery
unset TEST_MODE
prior_proposal_head="$(git --git-dir="$CASE_DIR/remote.git" \
  rev-parse refs/heads/adoc/proposals/pr-7)"
printf 'new source change\n' >> "$CASE_DIR/repo/app.txt"
git -C "$CASE_DIR/repo" commit -qam 'feat: advance source'
next_head="$(git -C "$CASE_DIR/repo" rev-parse HEAD)"
git -C "$CASE_DIR/repo" push -q origin feature
next_assessment="sha256:$(printf 'b%.0s' {1..64})"
jq --arg head "$next_head" --arg assessment "$next_assessment" '
  .revisions.head = $head | .assessment_sha256 = $assessment
' "$CASE_DIR/out/proposal-context.json" > "$CASE_DIR/context.next"
mv "$CASE_DIR/context.next" "$CASE_DIR/out/proposal-context.json"
refresh_patch_assessment "$next_assessment"

touch "$CASE_DIR/pr-edit-fail"
export TEST_MODE=pr TEST_HEAD="$next_head"
run_delivery
unset TEST_MODE TEST_HEAD
jq -e '.status == "error" and .reason == "pr_update_failed"' \
  "$CASE_DIR/out/delivery-status.json" >/dev/null
test "$(git --git-dir="$CASE_DIR/remote.git" \
  rev-parse refs/heads/adoc/proposals/pr-7)" = "$prior_proposal_head"

rm "$CASE_DIR/pr-edit-fail"
export TEST_MODE=pr TEST_HEAD="$next_head"
run_delivery
unset TEST_MODE TEST_HEAD
jq -e '.status == "complete" and .mode == "pr"' \
  "$CASE_DIR/out/delivery-status.json" >/dev/null

printf 'race source change\n' >> "$CASE_DIR/repo/app.txt"
git -C "$CASE_DIR/repo" commit -qam 'feat: advance source again'
race_source_head="$(git -C "$CASE_DIR/repo" rev-parse HEAD)"
git -C "$CASE_DIR/repo" push -q origin feature
jq --arg head "$race_source_head" '.revisions.head = $head' \
  "$CASE_DIR/out/proposal-context.json" > "$CASE_DIR/context.next"
mv "$CASE_DIR/context.next" "$CASE_DIR/out/proposal-context.json"
touch "$CASE_DIR/pr-edit-race"
export TEST_MODE=pr TEST_HEAD="$race_source_head"
run_delivery
unset TEST_MODE TEST_HEAD
jq -e '.status == "error"
  and .reason == "proposal_branch_recovery_failed"' \
  "$CASE_DIR/out/delivery-status.json" >/dev/null

if grep -Eq 'approve|merge|dismiss' "$CASE_DIR/gh.log"; then
  echo 'delivery attempted a forbidden GitHub operation' >&2
  exit 1
fi

echo 'governed delivery tests passed'
