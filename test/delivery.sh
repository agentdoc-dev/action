#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ADOC_BIN="${ADOC_BIN:-$ROOT/../adoc/target/debug/adoc}"
REAL_GIT="$(command -v git)"
CASE_DIR="$(mktemp -d)"
trap 'rm -rf "$CASE_DIR"' EXIT
mkdir -p "$CASE_DIR/bin" "$CASE_DIR/out/patches" "$CASE_DIR/repo" \
  "$CASE_DIR/retained"
invocation_id=delivery-test
record_path="$CASE_DIR/retained/proposal-record-${invocation_id}.json"
printf '%s\n' '{"schema_version":"adoc.proposal.v0"}' > "$record_path"
record_sha="sha256:$(sha256sum "$record_path" | awk '{print $1}')"

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
git -C "$CASE_DIR/repo" config \
  "url.$CASE_DIR/remote.git.insteadOf" https://github.com/agentdoc/test.git
jq -n --arg head "$assessed_head" '{
  version:"trusted.change_request.v1",base_repository:"agentdoc/test",
  head_repository:"agentdoc/test",pull_request:7,
  base_ref:"main",base_revision:$head,head_revision:$head,
  evaluation_date:"2026-07-23"
}' > "$CASE_DIR/trusted-request.json"
printf '%s\n' '{"state":"authorized"}' > "$CASE_DIR/out/trusted-phase-status.json"
printf '%s\n' '["index.adoc"]' > "$CASE_DIR/trusted-authorized-paths.json"
: > "$CASE_DIR/github-env"

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
  path:$path,sha256:$sha,logical_candidate:1,sequence:1,
  check_path:"placeholder",check_sha256:("sha256:" + ("1" * 64))
}' > "$CASE_DIR/out/patch-manifest.ndjson"
existing_hash="$(jq -r '
  .nodes[] | select(.id == "fixture.ci.green") | .content_hash
' "$graph")"
jq -n --arg base "$existing_hash" '{
  schema_version:"adoc.patch.v0",op:"update_fields",target:"fixture.ci.green",
  base_hash:$base,changes:{fields:{status:"draft"}},
  reason:("AgentDoc assessment sha256:" + ("a" * 64) + " finding finding-002."),
  proposer:{type:"agent",id:"agentdoc-action/claude-code@2.1.215/claude-sonnet-5"}
}' > "$CASE_DIR/out/patches/update.json"
update_sha="sha256:$(sha256sum "$CASE_DIR/out/patches/update.json" | awk '{print $1}')"
jq -cn --arg path "$CASE_DIR/out/patches/update.json" --arg sha "$update_sha" '{
  schema_version:"adoc.patch.v0",operation:"update_fields",
  target:"fixture.ci.green",kind:"claim",status:"draft",
  finding_id:"finding-002",placement_path:"index.adoc",page_id:"fixture.kb",
  path:$path,sha256:$sha,logical_candidate:2,sequence:1,
  check_path:"placeholder",check_sha256:("sha256:" + ("2" * 64))
}' >> "$CASE_DIR/out/patch-manifest.ndjson"
jq -sc 'sort_by(.sha256) | reverse[]' "$CASE_DIR/out/patch-manifest.ndjson" \
  > "$CASE_DIR/manifest.next"
mv "$CASE_DIR/manifest.next" "$CASE_DIR/out/patch-manifest.ndjson"
set_sha="sha256:$(jq -sc 'map(.sha256)' "$CASE_DIR/out/patch-manifest.ndjson" \
  | sha256sum | awk '{print $1}')"
canonical_set_sha="sha256:$(jq -sc 'map(.sha256) | sort' \
  "$CASE_DIR/out/patch-manifest.ndjson" | sha256sum | awk '{print $1}')"
test "$canonical_set_sha" != "$set_sha"
jq -n --arg sha "$canonical_set_sha" \
  '{status:"complete",count:2,sha256:$sha,reason:"validated"}' \
  > "$CASE_DIR/out/proposal-status.json"
jq -n --arg path "$record_path" --arg sha "$record_sha" \
  '{status:"complete",reason:"validated",path:$path,sha256:$sha}' \
  > "$CASE_DIR/out/proposal-record-status.json"
jq -n --arg head "$assessed_head" --arg date "$date" \
  --arg graph "$graph_sha" --arg objects "$object_sha" '{
  assessment_sha256:("sha256:" + ("a" * 64)),
  revisions:{comparison_base:$head,head:$head},evaluation_date:$date,
  graph_sha256:$graph,object_set_sha256:$objects
}' > "$CASE_DIR/out/proposal-context.json"

refresh_patch_assessment() {
  local assessment="$1" create_sha update_sha set
  jq --arg reason "AgentDoc assessment $assessment finding finding-001." \
    '.reason = $reason' "$CASE_DIR/out/patches/patch.json" \
    > "$CASE_DIR/patch.next"
  mv "$CASE_DIR/patch.next" "$CASE_DIR/out/patches/patch.json"
  jq --arg reason "AgentDoc assessment $assessment finding finding-002." \
    '.reason = $reason' "$CASE_DIR/out/patches/update.json" \
    > "$CASE_DIR/patch.next"
  mv "$CASE_DIR/patch.next" "$CASE_DIR/out/patches/update.json"
  create_sha="sha256:$(sha256sum "$CASE_DIR/out/patches/patch.json" | awk '{print $1}')"
  update_sha="sha256:$(sha256sum "$CASE_DIR/out/patches/update.json" | awk '{print $1}')"
  jq -c --arg create "$create_sha" --arg update "$update_sha" '
    .sha256 = if .operation == "create_object" then $create else $update end
  ' "$CASE_DIR/out/patch-manifest.ndjson" \
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
    head=''
    while [ "$#" -gt 0 ]; do
      if [ "$1" = --head ]; then head="$2"; break; fi
      shift
    done
    jq --arg head "$head" '[.[] | select(.headRefName == $head)]' \
      "$CASE_DIR/pr-state.json"
  else
    printf '%s\n' '[]'
  fi
  exit 0
fi
if [ "${1:-}" = pr ] && [ "${2:-}" = create ]; then
  [ ! -f "$CASE_DIR/pr-create-fail" ] || exit 1
  head='' base=''
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --body-file) cp "$2" "$CASE_DIR/pr-body.md"; shift 2 ;;
      --head) head="$2"; shift 2 ;;
      --base) base="$2"; shift 2 ;;
      *) shift ;;
    esac
  done
  sha="$(git --git-dir="$CASE_DIR/remote.git" rev-parse "refs/heads/$head")"
  body="$(cat "$CASE_DIR/pr-body.md")"
  jq -n --arg sha "$sha" --arg body "$body" --arg head "$head" --arg base "$base" '[{
    number:8,state:"OPEN",url:"https://github.com/agentdoc/test/pull/8",
    headRefName:$head,headRefOid:$sha,
    baseRefName:$base,body:$body,isDraft:true
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
  branch="$(jq -r '.[0].headRefName' "$CASE_DIR/pr-state.json")"
  sha="$(git --git-dir="$CASE_DIR/remote.git" rev-parse "refs/heads/$branch")"
  body="$(cat "$CASE_DIR/pr-body.md")"
  jq --arg sha "$sha" --arg body "$body" \
    '.[0].headRefOid = $sha | .[0].body = $body' \
    "$CASE_DIR/pr-state.json" > "$CASE_DIR/pr-state.next"
  mv "$CASE_DIR/pr-state.next" "$CASE_DIR/pr-state.json"
  exit 0
fi
if [ "${1:-}" = pr ] && [ "${2:-}" = ready ]; then
  draft=false
  for arg in "$@"; do
    [ "$arg" != --undo ] || draft=true
  done
  jq --argjson draft "$draft" '.[0].isDraft = $draft' \
    "$CASE_DIR/pr-state.json" > "$CASE_DIR/pr-state.next"
  mv "$CASE_DIR/pr-state.next" "$CASE_DIR/pr-state.json"
  exit 0
fi
if [ "${1:-}" = api ] && [ "${2:-}" = user ]; then
  echo 41898282
  exit 0
fi
if [ "${1:-}" = api ] \
  && [ "${2:-}" = repos/agentdoc/test/issues/7/comments ]; then
  echo '[]'
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
  "api repos/agentdoc/test/git/ref/heads/feature")
    git --git-dir="$CASE_DIR/remote.git" rev-parse refs/heads/feature
    ;;
  "api repos/agentdoc/test/pulls/7")
    sha="$(git --git-dir="$CASE_DIR/remote.git" rev-parse refs/heads/feature)"
    base="$(jq -r .base_revision "$CASE_DIR/trusted-request.json")"
    base_ref="$(jq -r .base_ref "$CASE_DIR/trusted-request.json")"
    if [ -f "$CASE_DIR/stale-trusted-head" ]; then
      count="$(cat "$CASE_DIR/trusted-head-calls" 2>/dev/null || echo 0)"
      count=$((count + 1))
      printf '%s\n' "$count" > "$CASE_DIR/trusted-head-calls"
      current_calls=1
      [ ! -f "$CASE_DIR/stale-trusted-after-push" ] || current_calls=2
      [ "$count" -le "$current_calls" ] \
        || sha=ffffffffffffffffffffffffffffffffffffffff
    fi
    if [ "${3:-}" = --jq ]; then
      printf '%s\n' "$sha"
      exit 0
    fi
    jq -n --arg base "$base" --arg base_ref "$base_ref" \
      --arg sha "$sha" --arg repo "${MOCK_HEAD_REPOSITORY:-agentdoc/test}" '{
      state:"open",html_url:"https://github.com/agentdoc/test/pull/7",
      base:{sha:$base,ref:$base_ref,repo:{full_name:"agentdoc/test"}},
      head:{sha:$sha,ref:"feature",repo:{full_name:$repo}}
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

cat > "$CASE_DIR/bin/git" <<'EOF'
#!/usr/bin/env bash
for arg in "$@"; do
  [ "$arg" != credential.interactive=never ] || {
    echo 'delivery disabled its own askpass credential prompt' >&2
    exit 1
  }
done
exec "$REAL_GIT" "$@"
EOF
chmod +x "$CASE_DIR/bin/git"

run_delivery() {
  local pr_number=7
  [ "${TEST_BOOTSTRAP:-false}" != true ] || pr_number=''
  (
    cd "$CASE_DIR/repo"
    env PATH="$CASE_DIR/bin:$PATH" CASE_DIR="$CASE_DIR" REAL_GIT="$REAL_GIT" \
    ADOC_RUN_DIR="$CASE_DIR/out" ADOC_PROPOSE_ELIGIBLE=true \
    ADOC_RETAINED_DIR="$CASE_DIR/retained" ADOC_INVOCATION_ID="$invocation_id" \
    ADOC_HEAD="${TEST_HEAD:-$assessed_head}" ADOC_EVALUATION_DATE="$date" \
    ADOC_HEAD_REPOSITORY="${TEST_HEAD_REPOSITORY:-agentdoc/test}" \
    MOCK_HEAD_REPOSITORY="${TEST_HEAD_REPOSITORY:-agentdoc/test}" \
    GITHUB_REPOSITORY=agentdoc/test GITHUB_SERVER_URL=https://github.com \
    GITHUB_RUN_ID=1 \
    PR_NUMBER="$pr_number" BASE_REF=main HEAD_REF=feature \
    BOOTSTRAP="${TEST_BOOTSTRAP:-false}" \
    ADOC_TRUSTED_PHASE="${TEST_TRUSTED:-false}" \
    ADOC_TRUSTED_CHANGE_REQUEST_PATH="$CASE_DIR/trusted-request.json" \
    ADOC_TRUSTED_AUTHORIZED_PATHS_PATH="$CASE_DIR/trusted-authorized-paths.json" \
    ADOC_TRUSTED_AUTHORIZATION_EXPIRES_AT="${TEST_TRUSTED_EXPIRES_AT:-2099-08-26T12:00:00Z}" \
    GITHUB_ENV="$CASE_DIR/github-env" \
    PROPOSE_DELIVERY="${TEST_MODE:-commit}" GH_TOKEN=test-token \
    "$ROOT/scripts/deliver.sh"
  )
}

# An explicit canonical-record failure blocks repository-changing delivery;
# only an unavailable/skipped record may use the released-adoc legacy digest.
jq '.status = "error" | .reason = "proposal_record_failed"
  | .path = null | .sha256 = null' \
  "$CASE_DIR/out/proposal-record-status.json" > "$CASE_DIR/record-status.next"
mv "$CASE_DIR/record-status.next" "$CASE_DIR/out/proposal-record-status.json"
jq --arg sha "$set_sha" '.sha256 = $sha' \
  "$CASE_DIR/out/proposal-status.json" > "$CASE_DIR/proposal.next"
mv "$CASE_DIR/proposal.next" "$CASE_DIR/out/proposal-status.json"
run_delivery
test "$(git --git-dir="$CASE_DIR/remote.git" rev-parse refs/heads/feature)" \
  = "$assessed_head"
jq -e '.status == "error" and .reason == "proposal_record_failed"' \
  "$CASE_DIR/out/delivery-status.json" >/dev/null
jq -n --arg path "$record_path" --arg sha "$record_sha" \
  '{status:"complete",reason:"validated",path:$path,sha256:$sha}' \
  > "$CASE_DIR/out/proposal-record-status.json"
jq --arg sha "$canonical_set_sha" '.sha256 = $sha' \
  "$CASE_DIR/out/proposal-status.json" > "$CASE_DIR/proposal.next"
mv "$CASE_DIR/proposal.next" "$CASE_DIR/out/proposal-status.json"

# A complete status is not delivery authority when its retained evidence was
# deleted or changed after proposal generation.
mv "$record_path" "$CASE_DIR/record.saved"
run_delivery
test "$(git --git-dir="$CASE_DIR/remote.git" rev-parse refs/heads/feature)" \
  = "$assessed_head"
jq -e '.status == "error" and .reason == "proposal_record_failed"' \
  "$CASE_DIR/out/delivery-status.json" >/dev/null
mv "$CASE_DIR/record.saved" "$record_path"
printf '%s\n' tampered >> "$record_path"
run_delivery
test "$(git --git-dir="$CASE_DIR/remote.git" rev-parse refs/heads/feature)" \
  = "$assessed_head"
jq -e '.status == "error" and .reason == "proposal_record_failed"' \
  "$CASE_DIR/out/delivery-status.json" >/dev/null
sed -i.bak '$d' "$record_path"
rm "$record_path.bak"

run_delivery

# The record-backed path above uses the canonical, digest-sorted proposal
# identity. Remaining cases exercise the released-adoc legacy identity.
rm "$CASE_DIR/out/proposal-record-status.json"
jq --arg sha "$set_sha" '.sha256 = $sha' \
  "$CASE_DIR/out/proposal-status.json" > "$CASE_DIR/proposal.next"
mv "$CASE_DIR/proposal.next" "$CASE_DIR/out/proposal-status.json"

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
  env PATH="$CASE_DIR/bin:$PATH" CASE_DIR="$CASE_DIR" REAL_GIT="$REAL_GIT" \
    ADOC_RUN_DIR="$CASE_DIR/out" ADOC_HEAD="$assessed_head" \
    GITHUB_REPOSITORY=agentdoc/test PR_NUMBER=7 GH_TOKEN=test-token \
    GITHUB_ACTIONS=true \
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
grep -Fq 'pr create --repo agentdoc/test --head adoc/proposals/pr-7 --base feature --draft' \
  "$CASE_DIR/gh.log"

# Trusted delivery cannot write outside the authorization or mutate GitHub
# after the pull-request head changes.
trusted_proposal_head="$proposal_head"
printf '%s\n' '[]' > "$CASE_DIR/trusted-authorized-paths.json"
export TEST_MODE=pr TEST_TRUSTED=true
run_delivery
unset TEST_MODE TEST_TRUSTED
jq -e '.status == "error" and .reason == "manifest_contract_failed"' \
  "$CASE_DIR/out/delivery-status.json" >/dev/null
test "$(git --git-dir="$CASE_DIR/remote.git" \
  rev-parse refs/heads/adoc/proposals/pr-7)" = "$trusted_proposal_head"

printf '%s\n' '["index.adoc"]' > "$CASE_DIR/trusted-authorized-paths.json"
printf '%s\n' '{"state":"authorized"}' > "$CASE_DIR/out/trusted-phase-status.json"
export TEST_MODE=pr TEST_TRUSTED=true TEST_TRUSTED_EXPIRES_AT=2000-01-01T00:00:00Z
run_delivery
unset TEST_MODE TEST_TRUSTED TEST_TRUSTED_EXPIRES_AT
jq -e '.status == "error" and .reason == "stale_head"' \
  "$CASE_DIR/out/delivery-status.json" >/dev/null
jq -e '.state == "failed" and .reason_code == "trusted.authorization_expired"' \
  "$CASE_DIR/out/trusted-phase-status.json" >/dev/null
test "$(git --git-dir="$CASE_DIR/remote.git" \
  rev-parse refs/heads/adoc/proposals/pr-7)" = "$trusted_proposal_head"

printf '%s\n' '{"state":"authorized"}' > "$CASE_DIR/out/trusted-phase-status.json"
: > "$CASE_DIR/trusted-head-calls"
touch "$CASE_DIR/stale-trusted-head"
touch "$CASE_DIR/stale-trusted-after-push"
export TEST_MODE=pr TEST_TRUSTED=true
run_delivery
unset TEST_MODE TEST_TRUSTED
rm "$CASE_DIR/stale-trusted-head" "$CASE_DIR/stale-trusted-after-push"
jq -e '.status == "error" and .reason == "stale_head"' \
  "$CASE_DIR/out/delivery-status.json" >/dev/null
jq -e '.state == "expired_after_head_change"' \
  "$CASE_DIR/out/trusted-phase-status.json" >/dev/null
test "$(git --git-dir="$CASE_DIR/remote.git" \
  rev-parse refs/heads/adoc/proposals/pr-7)" = "$trusted_proposal_head"

jq '.[0].baseRefName = "main"' "$CASE_DIR/pr-state.json" \
  > "$CASE_DIR/pr-state.next"
mv "$CASE_DIR/pr-state.next" "$CASE_DIR/pr-state.json"
export TEST_MODE=pr TEST_HEAD_REPOSITORY=contributor/fork
run_delivery
unset TEST_MODE TEST_HEAD_REPOSITORY
jq -e '.status == "complete" and .mode == "pr"
  and .url == "https://github.com/agentdoc/test/pull/8"' \
  "$CASE_DIR/out/delivery-status.json" >/dev/null
grep -Fq 'pr edit 8 --repo agentdoc/test' "$CASE_DIR/gh.log"
jq '.[0].baseRefName = "feature"' "$CASE_DIR/pr-state.json" \
  > "$CASE_DIR/pr-state.next"
mv "$CASE_DIR/pr-state.next" "$CASE_DIR/pr-state.json"

ready_proposal_head="$(git --git-dir="$CASE_DIR/remote.git" \
  rev-parse refs/heads/adoc/proposals/pr-7)"
jq '.[0].isDraft = false' "$CASE_DIR/pr-state.json" > "$CASE_DIR/pr-state.next"
mv "$CASE_DIR/pr-state.next" "$CASE_DIR/pr-state.json"
printf '%s\n' '{"state":"authorized"}' > "$CASE_DIR/out/trusted-phase-status.json"
: > "$CASE_DIR/trusted-head-calls"
touch "$CASE_DIR/stale-trusted-head"
touch "$CASE_DIR/stale-trusted-after-push"
export TEST_MODE=pr TEST_TRUSTED=true
run_delivery
unset TEST_MODE TEST_TRUSTED
rm "$CASE_DIR/stale-trusted-head" "$CASE_DIR/stale-trusted-after-push"
jq -e '.status == "error" and .reason == "stale_head"' \
  "$CASE_DIR/out/delivery-status.json" >/dev/null
jq -e '.[0].isDraft == false' "$CASE_DIR/pr-state.json" >/dev/null
test "$(git --git-dir="$CASE_DIR/remote.git" \
  rev-parse refs/heads/adoc/proposals/pr-7)" = "$ready_proposal_head"

export TEST_MODE=pr
run_delivery
unset TEST_MODE
jq -e '.status == "complete" and .mode == "pr"
  and .url == "https://github.com/agentdoc/test/pull/8"' \
  "$CASE_DIR/out/delivery-status.json" >/dev/null
test "$(grep -c '^pr create ' "$CASE_DIR/gh.log")" = 1
test "$(grep -c '^pr edit ' "$CASE_DIR/gh.log")" = 2
test "$(grep -c '^pr ready ' "$CASE_DIR/gh.log")" = 3
jq -e '.[0].isDraft == true' "$CASE_DIR/pr-state.json" >/dev/null

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

cp "$CASE_DIR/pr-state.json" "$CASE_DIR/primary-closed.json"
printf 'new source after closed proposal\n' >> "$CASE_DIR/repo/app.txt"
git -C "$CASE_DIR/repo" commit -qam 'feat: advance closed proposal source'
closed_next_head="$(git -C "$CASE_DIR/repo" rev-parse HEAD)"
git -C "$CASE_DIR/repo" push -q origin feature
closed_next_assessment="sha256:$(printf 'c%.0s' {1..64})"
jq --arg head "$closed_next_head" --arg assessment "$closed_next_assessment" '
  .revisions.head = $head | .assessment_sha256 = $assessment
' "$CASE_DIR/out/proposal-context.json" > "$CASE_DIR/context.next"
mv "$CASE_DIR/context.next" "$CASE_DIR/out/proposal-context.json"
refresh_patch_assessment "$closed_next_assessment"
export TEST_MODE=pr TEST_HEAD="$closed_next_head"
run_delivery
unset TEST_MODE TEST_HEAD
closed_next_branch="adoc/proposals/pr-7-$closed_next_head"
jq -e --arg branch "$closed_next_branch" '
  .status == "complete" and .mode == "pr" and .branch == $branch
' "$CASE_DIR/out/delivery-status.json" >/dev/null
git --git-dir="$CASE_DIR/remote.git" show-ref --verify --quiet \
  "refs/heads/$closed_next_branch"
cp "$CASE_DIR/pr-state.json" "$CASE_DIR/fallback-closed.json"
jq '.[0].state = "CLOSED"' "$CASE_DIR/fallback-closed.json" \
  > "$CASE_DIR/fallback-closed.next"
mv "$CASE_DIR/fallback-closed.next" "$CASE_DIR/fallback-closed.json"
jq -s 'add' "$CASE_DIR/primary-closed.json" "$CASE_DIR/fallback-closed.json" \
  > "$CASE_DIR/pr-state.json"
export TEST_MODE=pr TEST_HEAD="$closed_next_head"
run_delivery
unset TEST_MODE TEST_HEAD
jq -e '.status == "error" and .reason == "proposal_pr_closed"' \
  "$CASE_DIR/out/delivery-status.json" >/dev/null

git --git-dir="$CASE_DIR/remote.git" update-ref -d \
  "refs/heads/$closed_next_branch"
git -C "$CASE_DIR/repo" reset -q --hard "$assessed_head"
git --git-dir="$CASE_DIR/remote.git" update-ref refs/heads/feature "$assessed_head"
original_assessment="sha256:$(printf 'a%.0s' {1..64})"
jq --arg head "$assessed_head" --arg assessment "$original_assessment" '
  .revisions.head = $head | .assessment_sha256 = $assessment
' "$CASE_DIR/out/proposal-context.json" > "$CASE_DIR/context.next"
mv "$CASE_DIR/context.next" "$CASE_DIR/out/proposal-context.json"
refresh_patch_assessment "$original_assessment"
cp "$CASE_DIR/primary-closed.json" "$CASE_DIR/pr-state.json"

rm "$CASE_DIR/pr-state.json"
export TEST_MODE=pr
run_delivery
unset TEST_MODE
jq -e '.status == "error" and .reason == "proposal_branch_unowned"' \
  "$CASE_DIR/out/delivery-status.json" >/dev/null

git --git-dir="$CASE_DIR/remote.git" update-ref -d \
  refs/heads/adoc/proposals/pr-7
printf '%s\n' '{"state":"authorized"}' > "$CASE_DIR/out/trusted-phase-status.json"
: > "$CASE_DIR/trusted-head-calls"
touch "$CASE_DIR/stale-trusted-head"
export TEST_MODE=pr TEST_TRUSTED=true
run_delivery
unset TEST_MODE TEST_TRUSTED
rm "$CASE_DIR/stale-trusted-head"
jq -e '.status == "error" and .reason == "stale_head"' \
  "$CASE_DIR/out/delivery-status.json" >/dev/null
jq -e '.state == "expired_after_head_change"' \
  "$CASE_DIR/out/trusted-phase-status.json" >/dev/null
if git --git-dir="$CASE_DIR/remote.git" show-ref --verify --quiet \
  refs/heads/adoc/proposals/pr-7; then
  echo 'stale trusted run left its new proposal branch behind' >&2
  exit 1
fi

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
rm "$CASE_DIR/pr-edit-race"

if grep -Eq 'approve|merge|dismiss' "$CASE_DIR/gh.log"; then
  echo 'delivery attempted a forbidden GitHub operation' >&2
  exit 1
fi

# A workflow_dispatch bootstrap verifies the default branch rather than
# querying a nonexistent source pull request.
rm -f "$CASE_DIR/pr-state.json"
export TEST_MODE=pr TEST_BOOTSTRAP=true TEST_HEAD="$race_source_head"
run_delivery
unset TEST_MODE TEST_BOOTSTRAP TEST_HEAD
jq -e --arg head "$race_source_head" '.status == "complete" and .mode == "pr"
  and .branch == ("adoc/bootstrap/" + $head)
  and .url == "https://github.com/agentdoc/test/pull/8"' \
  "$CASE_DIR/out/delivery-status.json" >/dev/null
grep -Fq '<!-- AgentDoc-Proposal-Owner: agentdoc/test#bootstrap -->' \
  "$CASE_DIR/pr-body.md"
grep -Fq "pr create --repo agentdoc/test --head adoc/bootstrap/$race_source_head --base main --draft" \
  "$CASE_DIR/gh.log"

# The same assessed default-branch revision updates its existing bootstrap PR.
export TEST_MODE=pr TEST_BOOTSTRAP=true TEST_HEAD="$race_source_head"
run_delivery
unset TEST_MODE TEST_BOOTSTRAP TEST_HEAD
jq -e '.status == "complete" and .mode == "pr"' \
  "$CASE_DIR/out/delivery-status.json" >/dev/null
test "$(grep -Fc "pr create --repo agentdoc/test --head adoc/bootstrap/$race_source_head " \
  "$CASE_DIR/gh.log")" = 1

# A later default-branch revision gets a fresh PR even after the prior one closes.
jq '.[0].state = "CLOSED"' "$CASE_DIR/pr-state.json" > "$CASE_DIR/pr-state.next"
mv "$CASE_DIR/pr-state.next" "$CASE_DIR/pr-state.json"
printf 'next bootstrap source change\n' >> "$CASE_DIR/repo/app.txt"
git -C "$CASE_DIR/repo" commit -qam 'feat: advance bootstrap source'
next_bootstrap_head="$(git -C "$CASE_DIR/repo" rev-parse HEAD)"
git -C "$CASE_DIR/repo" push -q origin feature
jq --arg head "$next_bootstrap_head" '.revisions.head = $head' \
  "$CASE_DIR/out/proposal-context.json" > "$CASE_DIR/context.next"
mv "$CASE_DIR/context.next" "$CASE_DIR/out/proposal-context.json"
export TEST_MODE=pr TEST_BOOTSTRAP=true TEST_HEAD="$next_bootstrap_head"
run_delivery
unset TEST_MODE TEST_BOOTSTRAP TEST_HEAD
jq -e --arg head "$next_bootstrap_head" '
  .status == "complete" and .branch == ("adoc/bootstrap/" + $head)
' "$CASE_DIR/out/delivery-status.json" >/dev/null
grep -Fq "pr create --repo agentdoc/test --head adoc/bootstrap/$next_bootstrap_head --base main --draft" \
  "$CASE_DIR/gh.log"

echo 'governed delivery tests passed'
