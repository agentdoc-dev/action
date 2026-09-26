#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ADOC_BIN="${ADOC_BIN:-$ROOT/../adoc/target/debug/adoc}"
REAL_GIT="$(command -v git)"
CASE_DIR="$(mktemp -d)"
trap 'rm -rf "$CASE_DIR"' EXIT
mkdir -p "$CASE_DIR/bin" "$CASE_DIR/out/patches" "$CASE_DIR/repo" \
  "$CASE_DIR/retained"
mkdir -p "$CASE_DIR/protection"
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
# E8.2.T3 branch-protection provider fixtures (connected commit mode only).
if [ "${1:-}" = api ] && [ -n "${2:-}" ]; then
  p="$CASE_DIR/protection"
  case "$2" in
    repos/agentdoc/test/branches/feature/protection)
      n=$(( $(cat "$p/calls" 2>/dev/null || echo 0) + 1 ))
      printf '%s\n' "$n" > "$p/calls"
      [ ! -f "$p/fail" ] || exit 1
      if [ -f "$p/drift.json" ] && [ "$n" -ge 2 ]; then cat "$p/drift.json"; exit 0; fi
      if [ -f "$p/classic-error.json" ]; then cat "$p/classic-error.json"; exit 1; fi
      if [ -f "$p/classic.json" ]; then cat "$p/classic.json"; exit 0; fi
      echo '{"message":"Branch not protected","status":"404"}'
      exit 1
      ;;
    repos/agentdoc/test/rules/branches/feature \
      | "repos/agentdoc/test/rulesets?includes_parents=true")
      f="$p/rulesets.json"
      [ "$2" = "${2#*/rules/}" ] || f="$p/rules.json"
      [ ! -f "$f.fail" ] || exit 1
      [ -f "$f" ] || { echo '[]'; exit 0; }
      # One JSON page per line; gh concatenates pages only with --paginate.
      if [ "${3:-}" = --paginate ]; then cat "$f"; else head -n 1 "$f"; fi
      exit 0
      ;;
    "repos/agentdoc/test/rulesets/"*)
      id="${2#repos/agentdoc/test/rulesets/}"
      id="${id%%\?*}"
      printf '%s\n' "$(( $(cat "$p/detail-calls" 2>/dev/null || echo 0) + 1 ))" > "$p/detail-calls"
      cat "$p/ruleset-$id.json" 2>/dev/null || exit 1
      exit 0
      ;;
  esac
fi
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
  "api repos/agentdoc/test/pulls/8")
    jq '.[0] | {body, head:{sha:.headRefOid}}' "$CASE_DIR/pr-state.json"
    ;;
  "api -X")
    [ "$3 $4 ${5:-}" = "PATCH repos/agentdoc/test/pulls/8 -F" ] || exit 9
    body="$(cat "${6#body=@}"; printf x)"
    body="${body%x}"
    jq --arg body "$body" '.[0].body = $body' "$CASE_DIR/pr-state.json" \
      > "$CASE_DIR/pr-state.next"
    mv "$CASE_DIR/pr-state.next" "$CASE_DIR/pr-state.json"
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
case " $* " in
  *" push "*--force-with-lease=refs/heads/feature:*)
    printf '%s\n' "$*" >> "$CASE_DIR/git-push.log"
    if [ -f "$CASE_DIR/race-ref" ]; then
      "$REAL_GIT" --git-dir="$CASE_DIR/remote.git" update-ref refs/heads/feature \
        "$(cat "$CASE_DIR/race-ref")"
    fi
    if [ -f "$CASE_DIR/lost-response" ]; then
      "$REAL_GIT" "$@" >/dev/null 2>&1
      exit 1
    fi
    ;;
esac
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
    ADOC_DELIVERY_ELIGIBLE="${TEST_DELIVERY_ELIGIBLE:-true}" \
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

run_publish() {
  local pr_number=7
  [ "${TEST_BOOTSTRAP:-false}" != true ] || pr_number=''
  (
    cd "$CASE_DIR/repo"
    env PATH="$CASE_DIR/bin:$PATH" CASE_DIR="$CASE_DIR" REAL_GIT="$REAL_GIT" \
    GITHUB_SERVER_URL=https://github.com \
    ADOC_RUN_DIR="$CASE_DIR/out" ADOC_RETAINED_DIR="$CASE_DIR/retained" \
    ADOC_INVOCATION_ID="$invocation_id" ADOC_HEAD="$assessed_head" \
    GITHUB_REPOSITORY=agentdoc/test GITHUB_REPOSITORY_ID=987654321 \
    PR_NUMBER="$pr_number" BOOTSTRAP="${TEST_BOOTSTRAP:-false}" \
    CLOUD_PROPOSAL_RESOLVER="$resolver" GH_TOKEN=test-token \
    GITHUB_OUTPUT="$CASE_DIR/publish-output" \
    "$ROOT/scripts/publish-proposal-references.sh"
  )
}
resolver=https://cloud.example.test/workspaces/0f1e2d3c-4b5a-4978-8a6b-5c4d3e2f1a0b
block_open='<!-- AgentDoc-Proposal-References:v0 -->'

# E8.2.T5 hooks: standalone-parity.sh sources the frozen fixture only;
# assessment-ingestion.sh takes one connected pr delivery as T1 producer output.
[ -z "${DELIVERY_FIXTURE_ONLY:-}" ] || return 0
if [ -n "${DELIVERY_EXPORT:-}" ]; then
  resolver="$DELIVERY_EXPORT_RESOLVER"
  CLOUD_PROPOSAL_RESOLVER="$resolver" TEST_MODE=pr run_delivery > /dev/null
  printf '%s\n' '{"schema_version":"adoc.pr_assessment_receipt.v4"}' \
    > "$CASE_DIR/retained/receipt-${invocation_id}.json"
  printf 'sha256:%s\n' "$(sha256sum "$CASE_DIR/retained/receipt-${invocation_id}.json" | awk '{print $1}')" \
    > "$CASE_DIR/out/receipt-sha256"
  run_publish > /dev/null
  cp "$CASE_DIR/pr-body.md" "$DELIVERY_EXPORT/delivery-pr-body"
  cp "$CASE_DIR/out/delivery-status.json" "$CASE_DIR/out/proposal-status.json" \
    "$CASE_DIR/retained/proposal-references-$invocation_id.txt" "$DELIVERY_EXPORT/"
  git --git-dir="$CASE_DIR/remote.git" log -1 --format=%B \
    "refs/heads/$(jq -r .branch "$CASE_DIR/out/delivery-status.json")" \
    > "$DELIVERY_EXPORT/commit-message"
  exit 0
fi

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

# A protected same-repository workflow-run may construct and upload a proposal,
# but its isolated phase can never mutate Git.
TEST_DELIVERY_ELIGIBLE=false run_delivery
test "$(git --git-dir="$CASE_DIR/remote.git" rev-parse refs/heads/feature)" \
  = "$assessed_head"
jq -e '.status == "skipped" and .reason == "delivery_ineligible"' \
  "$CASE_DIR/out/delivery-status.json" >/dev/null

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
git --git-dir="$CASE_DIR/remote.git" show -s --format=%s "$delivered_head" \
  | grep -Fqx 'docs(adoc): update 2 Knowledge Objects for #7 [skip-adoc-propose]'
git --git-dir="$CASE_DIR/remote.git" show -s --format=%B "$delivered_head" \
  | grep -Fqx 'Files: index.adoc'
git --git-dir="$CASE_DIR/remote.git" show -s --format=%B "$delivered_head" \
  | grep -Eq '^AgentDoc-Proposal-Set-SHA256: sha256:[0-9a-f]{64}$'
grep -Fq '### Committed in [`' "$CASE_DIR/out/delivery.md"
grep -Fq '| | Object | Change | Lifecycle |' "$CASE_DIR/out/delivery.md"
grep -Fq '**Pull before pushing again.** The commit is a child of the assessed head and touches only <code>index.adoc</code>.' \
  "$CASE_DIR/out/delivery.md"
jq -e --arg assessed "$assessed_head" --arg delivered "$delivered_head" '
  .status == "complete" and .mode == "commit" and .reason == null
  and .assessed_head == $assessed and .delivery_commit == $delivered
  and .branch == "feature" and .url == null
' "$CASE_DIR/out/delivery-status.json" >/dev/null
# Disconnected delivery (no resolver) carries no Cloud trailer (E8.2 D1).
test "$(git --git-dir="$CASE_DIR/remote.git" show -s --format=%B "$delivered_head" \
  | grep -c 'AgentDoc-Cloud-Proposal')" = 0


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

# Connected commit delivery: resolver trailer, post-patch affected objects
# from the final graph, and a retained reference block bound to the receipt.
connected_set="$(jq -r .sha256 "$CASE_DIR/out/proposal-status.json")"
cloud_url="$resolver/proposals/${connected_set#sha256:}"
receipt_file="$CASE_DIR/retained/receipt-${invocation_id}.json"
printf '%s\n' '{"schema_version":"adoc.pr_assessment_receipt.v4"}' > "$receipt_file"
receipt_sha="sha256:$(sha256sum "$receipt_file" | awk '{print $1}')"
printf '%s\n' "$receipt_sha" > "$CASE_DIR/out/receipt-sha256"
affected_file="$CASE_DIR/retained/delivery-affected-objects-${invocation_id}.json"
# A disconnected rerun runs no connected step and renders no Cloud trailer.
git --git-dir="$CASE_DIR/remote.git" update-ref refs/heads/feature "$assessed_head"
run_delivery
jq -e '.status == "complete"' "$CASE_DIR/out/delivery-status.json" >/dev/null
test ! -e "$affected_file"
disconnected_message="$(git --git-dir="$CASE_DIR/remote.git" show -s --format=%B \
  refs/heads/feature)"
test "$(grep -c 'AgentDoc-Cloud-Proposal' <<< "$disconnected_message")" = 0
git --git-dir="$CASE_DIR/remote.git" update-ref refs/heads/feature "$assessed_head"
uuid=0f1e2d3c-4b5a-4978-8a6b-5c4d3e2f1a0b
for bad in "http://cloud.example.test/workspaces/$uuid" \
  "https://user@cloud.example.test/workspaces/$uuid" \
  "https://cloud.example.test/workspaces/$uuid?x=1" \
  "https://cloud.example.test/workspaces/$uuid#x" \
  "https://cloud.example.test/workspaces/$uuid/" \
  "https://cloud.example.test/api/workspaces/$uuid" \
  "https://cloud.example.test/workspaces/ws-1" \
  "https://cloud.example.test/workspaces/0F1E2D3C-4B5A-4978-8A6B-5C4D3E2F1A0B" \
  "https://cloud.example.test)/workspaces/$uuid" \
  "https://cloud<x/workspaces/$uuid" \
  "https://cloud.example.test/workspaces/$uuid x"; do
  CLOUD_PROPOSAL_RESOLVER="$bad" run_delivery
  jq -e '.status == "error" and .reason == "cloud_proposal_resolver_invalid"' \
    "$CASE_DIR/out/delivery-status.json" >/dev/null
  test "$(git --git-dir="$CASE_DIR/remote.git" rev-parse refs/heads/feature)" = "$assessed_head"
  test ! -e "$affected_file"
done
CLOUD_PROPOSAL_RESOLVER="https://cloud.example.test:8443/workspaces/$uuid" run_delivery
jq -e '.status == "complete"' "$CASE_DIR/out/delivery-status.json" >/dev/null
git --git-dir="$CASE_DIR/remote.git" update-ref refs/heads/feature "$assessed_head"
CLOUD_PROPOSAL_RESOLVER="$resolver" run_delivery
connected_head="$(git --git-dir="$CASE_DIR/remote.git" rev-parse refs/heads/feature)"
jq -e --arg d "$connected_head" '.status == "complete" and .delivery_commit == $d' \
  "$CASE_DIR/out/delivery-status.json" >/dev/null
git --git-dir="$CASE_DIR/remote.git" show -s --format=%B "$connected_head" \
  | grep -Fqx "AgentDoc-Cloud-Proposal: $cloud_url"
test "$(git --git-dir="$CASE_DIR/remote.git" show -s --format=%B "$connected_head" \
  | grep -vFx "AgentDoc-Cloud-Proposal: $cloud_url")" = "$disconnected_message"

# E8.2.T3: connected commit mode observes branch protection twice (D7) and
# pushes only with a lease on exact H. Saved state is restored afterwards.
p="$CASE_DIR/protection"
cp "$CASE_DIR/out/delivery-status.json" "$CASE_DIR/t3-status.saved"
cp "$CASE_DIR/out/delivery.md" "$CASE_DIR/t3-delivery.saved"
cp "$affected_file" "$CASE_DIR/t3-affected.saved"
protection_file="$CASE_DIR/retained/delivery-protection-${invocation_id}.json"
# Proven absence (default fixtures) was observed and retained.
test -s "$p/calls"
jq -e '.classic_protection == false and .ruleset_ids == [] and .branch == "feature"
  and (.settings_sha256 | test("^sha256:[0-9a-f]{64}$"))
  and (.fetched_at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T"))' "$protection_file" >/dev/null
connected_tree="$(git --git-dir="$CASE_DIR/remote.git" rev-parse "$connected_head^{tree}")"
t3_reset() {
  git --git-dir="$CASE_DIR/remote.git" update-ref refs/heads/feature "$assessed_head"
  rm -rf "$p" "$CASE_DIR/race-ref" "$CASE_DIR/lost-response" "$CASE_DIR/git-push.log"
  mkdir "$p"
}
t3_run() { CLOUD_PROPOSAL_RESOLVER="$resolver" run_delivery > "$CASE_DIR/t3.log"; }
t3_refused() { # annotation reason
  jq -e '.status == "error" and .reason == "delivery_check_failed"
    and .reason_code == null and .delivery_commit == null' \
    "$CASE_DIR/out/delivery-status.json" >/dev/null \
    && test "$(git --git-dir="$CASE_DIR/remote.git" for-each-ref)" = "$t3_refs" \
    && grep -Fq "connected commit delivery refused ($1)" "$CASE_DIR/t3.log" \
    && test ! -e "$CASE_DIR/git-push.log"
}
ruleset() { # id enforcement bypass-json-or-omit
  if [ "$3" = omit ]; then
    jq -n --argjson id "$1" --arg e "$2" '{id:$id,enforcement:$e}'
  else
    jq -n --argjson id "$1" --arg e "$2" --argjson b "$3" \
      '{id:$id,enforcement:$e,bypass_actors:$b}'
  fi > "$p/ruleset-$1.json"
}
positive_profile() {
  jq -n '{enforce_admins:{enabled:true},required_pull_request_reviews:{
    bypass_pull_request_allowances:{users:[],teams:[],apps:[]}}}' > "$p/classic.json"
  printf '%s\n%s\n' '[{"id":1}]' '[{"id":2}]' > "$p/rulesets.json"
  printf '%s\n' '[{"type":"deletion","ruleset_id":1,"ruleset_source":"agentdoc/test"}]' \
    > "$p/rules.json"
  ruleset 1 active '[]'
  ruleset 2 disabled '[{"actor_id":5,"actor_type":"Team","bypass_mode":"always"}]'
}
t3_reset
t3_refs="$(git --git-dir="$CASE_DIR/remote.git" for-each-ref)"
# Positive: classic protection plus an applying bypass-free ruleset; ruleset 2
# (disabled, with bypass) does not apply to the branch and is never fetched.
positive_profile
t3_run
t3_head="$(git --git-dir="$CASE_DIR/remote.git" rev-parse refs/heads/feature)"
jq -e --arg d "$t3_head" '.status == "complete" and .delivery_commit == $d
  and keys == ["assessed_head","branch","delivery_commit","mode","reason","reason_code","remediation","status","url"]' \
  "$CASE_DIR/out/delivery-status.json" >/dev/null
test "$(git --git-dir="$CASE_DIR/remote.git" rev-list --parents -n 1 "$t3_head")" \
  = "$t3_head $assessed_head"
test "$(git --git-dir="$CASE_DIR/remote.git" rev-parse "$t3_head^{tree}")" = "$connected_tree"
test "$(cat "$p/calls")" = 2
test "$(wc -l < "$CASE_DIR/git-push.log" | tr -d ' ')" = 1
grep -Fq -- "--force-with-lease=refs/heads/feature:$assessed_head" "$CASE_DIR/git-push.log"
jq -e '.classic_protection == true and .ruleset_ids == [1]' "$protection_file" >/dev/null
test "$(cat "$p/detail-calls")" = 2
test "$(grep -c test-token "$protection_file")" = 0
# Git success is reported independently of a later Cloud publication failure.
cp "$CASE_DIR/out/delivery-status.json" "$CASE_DIR/t3-complete.json"
cp "$CASE_DIR/out/receipt-sha256" "$CASE_DIR/t3-receipt.saved"
printf '%s\n' "sha256:$(printf '0%.0s' {1..64})" > "$CASE_DIR/out/receipt-sha256"
run_publish
jq -e '.status == "failed"' "$CASE_DIR/out/proposal-references-status.json" >/dev/null
cmp "$CASE_DIR/out/delivery-status.json" "$CASE_DIR/t3-complete.json"
mv "$CASE_DIR/t3-receipt.saved" "$CASE_DIR/out/receipt-sha256"
# Rulesets that do not apply to the branch never decide (D9).
for variant in not_protected evaluate_bypass unrelated_active_bypass listing_unavailable; do
  t3_reset
  positive_profile
  case "$variant" in
    not_protected) printf '%s\n' '{"message":"Branch not protected","status":"404"}' > "$p/classic-error.json" ;;
    evaluate_bypass) ruleset 2 evaluate '[{"actor_id":5,"actor_type":"Team","bypass_mode":"always"}]' ;;
    unrelated_active_bypass) ruleset 2 active '[{"actor_id":5,"actor_type":"Team","bypass_mode":"always"}]' ;;
    listing_unavailable) touch "$p/rulesets.json.fail" ;;
  esac
  t3_run
  jq -e '.status == "complete"' "$CASE_DIR/out/delivery-status.json" >/dev/null \
    || { echo "protection variant $variant refused" >&2; exit 1; }
done
# Refusals: every unknown or bypassable profile writes nothing.
for variant in omitted active_bypass admins_off allowances missing_allowances \
  unseen_ruleset provider_error ruleset_error page2_bypass rules_page2_unseen \
  rules_error classic_forbidden not_found not_protected_non404 id_mismatch \
  unknown_enforcement applying_not_active rule_id_string; do
  t3_reset
  positive_profile
  case "$variant" in
    omitted) ruleset 1 active omit ;;
    active_bypass) ruleset 1 active '[{"actor_id":5,"actor_type":"Team","bypass_mode":"always"}]' ;;
    admins_off) jq '.enforce_admins.enabled = false' "$p/classic.json" > "$p/c" && mv "$p/c" "$p/classic.json" ;;
    allowances) jq '.required_pull_request_reviews.bypass_pull_request_allowances.users = [{"login":"x"}]' \
      "$p/classic.json" > "$p/c" && mv "$p/c" "$p/classic.json" ;;
    missing_allowances) jq 'del(.required_pull_request_reviews.bypass_pull_request_allowances)' \
      "$p/classic.json" > "$p/c" && mv "$p/c" "$p/classic.json" ;;
    unseen_ruleset) printf '%s\n' '[{"type":"deletion","ruleset_id":9}]' > "$p/rules.json" ;;
    provider_error) touch "$p/fail" ;;
    ruleset_error) rm "$p/ruleset-1.json" ;;
    page2_bypass) ruleset 2 active '[{"actor_id":5,"actor_type":"Team","bypass_mode":"always"}]'
      printf '%s\n' '[{"type":"deletion","ruleset_id":2,"ruleset_source":"agentdoc/test"}]' >> "$p/rules.json" ;;
    rules_page2_unseen) printf '%s\n' '[{"type":"deletion","ruleset_id":9}]' >> "$p/rules.json" ;;
    rules_error) touch "$p/rules.json.fail" ;;
    classic_forbidden) printf '%s\n' '{"message":"Resource not accessible by integration","status":"403"}' \
      > "$p/classic-error.json" ;;
    id_mismatch) jq '.id = 3' "$p/ruleset-1.json" > "$p/r" && mv "$p/r" "$p/ruleset-1.json" ;;
    not_found) printf '%s\n' '{"message":"Not Found","status":"404"}' > "$p/classic-error.json" ;;
    not_protected_non404) printf '%s\n' '{"message":"Branch not protected","status":"500"}' > "$p/classic-error.json" ;;
    unknown_enforcement) ruleset 1 bogus '[]' ;;
    applying_not_active) ruleset 1 evaluate '[]' ;;
    rule_id_string) printf '%s\n' '[{"type":"deletion","ruleset_id":"1","ruleset_source":"agentdoc/test"}]' \
      > "$p/rules.json" ;;
  esac
  t3_run
  t3_refused protection_unknown || { echo "protection variant $variant wrote" >&2; exit 1; }
  test ! -e "$protection_file"
done
# Drift between the two observations refuses before any push.
t3_reset
positive_profile
jq '.enforce_admins.enabled = true | .required_pull_request_reviews = null' \
  "$p/classic.json" > "$p/drift.json"
t3_run
t3_refused protection_drift
test "$(cat "$p/calls")" = 2
# A concurrent advance or rewind after the live-head check fails the lease.
t3_reset
advanced="$(git -c user.name=racer -c user.email=racer@example.com \
  --git-dir="$CASE_DIR/remote.git" commit-tree \
  "$assessed_head^{tree}" -p "$assessed_head" -m 'concurrent advance')"
for race in "$advanced" "$(git --git-dir="$CASE_DIR/remote.git" rev-parse "$assessed_head^")"; do
  t3_reset
  printf '%s\n' "$race" > "$CASE_DIR/race-ref"
  t3_run
  jq -e '.status == "error" and .reason == "push_rejected"' \
    "$CASE_DIR/out/delivery-status.json" >/dev/null
  test "$(git --git-dir="$CASE_DIR/remote.git" rev-parse refs/heads/feature)" = "$race"
  test "$(wc -l < "$CASE_DIR/git-push.log" | tr -d ' ')" = 1
done
# Disconnected commit mode uses the same lease and makes no provider call.
t3_reset
printf '%s\n' "$(git --git-dir="$CASE_DIR/remote.git" rev-parse "$assessed_head^")" \
  > "$CASE_DIR/race-ref"
run_delivery
jq -e '.status == "error" and .reason == "push_rejected"
  and keys == ["assessed_head","branch","delivery_commit","mode","reason","reason_code","remediation","status","url"]' \
  "$CASE_DIR/out/delivery-status.json" >/dev/null
test ! -e "$p/calls"
# A lost push response is reported as a failure and never re-sent.
t3_reset
touch "$CASE_DIR/lost-response"
t3_run
lost_head="$(git --git-dir="$CASE_DIR/remote.git" rev-parse refs/heads/feature)"
jq -e --arg d "$lost_head" '.status == "complete" and .delivery_commit == $d' \
  "$CASE_DIR/out/delivery-status.json" >/dev/null
test "$(git --git-dir="$CASE_DIR/remote.git" rev-parse "$lost_head^")" = "$assessed_head"
t3_run
jq -e '.status == "error" and .reason == "stale_head"' \
  "$CASE_DIR/out/delivery-status.json" >/dev/null
test "$(wc -l < "$CASE_DIR/git-push.log" | tr -d ' ')" = 1
test "$(git --git-dir="$CASE_DIR/remote.git" rev-parse refs/heads/feature)" = "$lost_head"
# A tampered Source Binding cannot write the original branch.
t3_reset
cp "$CASE_DIR/trusted-request.json" "$CASE_DIR/t3-request.saved"
jq '.head_revision = ("f" * 40)' "$CASE_DIR/t3-request.saved" > "$CASE_DIR/trusted-request.json"
printf '%s\n' '{"state":"authorized"}' > "$CASE_DIR/out/trusted-phase-status.json"
CLOUD_PROPOSAL_RESOLVER="$resolver" TEST_TRUSTED=true run_delivery > "$CASE_DIR/t3.log"
jq -e '.status == "error" and .reason == "stale_head"' \
  "$CASE_DIR/out/delivery-status.json" >/dev/null
test "$(git --git-dir="$CASE_DIR/remote.git" for-each-ref)" = "$t3_refs"
test ! -e "$CASE_DIR/git-push.log"
mv "$CASE_DIR/t3-request.saved" "$CASE_DIR/trusted-request.json"
printf '%s\n' '{"state":"authorized"}' > "$CASE_DIR/out/trusted-phase-status.json"
# Fork-origin commit delivery refuses typed with zero ref changes and no
# provider call; finalize.sh accepts the status.
t3_reset
TEST_HEAD_REPOSITORY=contributor/fork t3_run
test "$(git --git-dir="$CASE_DIR/remote.git" for-each-ref)" = "$t3_refs"
test ! -e "$p/calls"
jq -e '.status == "skipped" and .mode == "commit" and .reason == "fork_branch_read_only"
  and .reason_code == "delivery.fork_branch_read_only"
  and (.remediation | test("pull-request delivery") and test("base repository"))' \
  "$CASE_DIR/out/delivery-status.json" >/dev/null
finalize_filter="$(awk '/-s "\$OUT\/delivery-status.json"/{f=1;next}
  f&&/^  if jq -e .$/{g=1;next} g&&/^  . "\$OUT\/delivery-status.json"/{exit} g{print}' \
  "$ROOT/scripts/finalize.sh")"
test -n "$finalize_filter"
jq -e "$finalize_filter" "$CASE_DIR/out/delivery-status.json" >/dev/null
jq -e "$finalize_filter" "$CASE_DIR/t3-complete.json" >/dev/null
# Restore the connected delivery the following publication tests bind to.
t3_reset
rm -rf "$p" && mkdir "$p"
git --git-dir="$CASE_DIR/remote.git" update-ref refs/heads/feature "$connected_head"
cp "$CASE_DIR/t3-status.saved" "$CASE_DIR/out/delivery-status.json"
cp "$CASE_DIR/t3-delivery.saved" "$CASE_DIR/out/delivery.md"
cp "$CASE_DIR/t3-affected.saved" "$affected_file"
git -C "$CASE_DIR/repo" worktree add -q --detach "$CASE_DIR/connected-tree" "$connected_head"
(cd "$CASE_DIR/connected-tree" && "$ADOC_BIN" build --as-of "$date" \
  --no-embeddings --out "$CASE_DIR/connected-build" >/dev/null)
git -C "$CASE_DIR/repo" worktree remove --force "$CASE_DIR/connected-tree"
jq -c '[.nodes[] | select(.type == "knowledge_object"
    and (.id == "fixture.ci.green" or .id == "fixture.delivered.claim"))
  | {object_id:.id, content_hash}] | sort_by(.object_id)' \
  "$CASE_DIR/connected-build/docs.graph.json" | tr -d '\n' > "$CASE_DIR/affected-expected"
cmp "$CASE_DIR/affected-expected" "$affected_file"
test "$(jq -r '.[] | select(.object_id == "fixture.ci.green") | .content_hash' \
  "$affected_file")" != "$existing_hash"
run_publish
jq -e --arg path "$CASE_DIR/retained/proposal-references-${invocation_id}.txt" '
  .status == "retained" and .reason == null and .path == $path
' "$CASE_DIR/out/proposal-references-status.json" >/dev/null
block_file="$CASE_DIR/retained/proposal-references-${invocation_id}.txt"
test "$(jq -r .sha256 "$CASE_DIR/out/proposal-references-status.json")" \
  = "sha256:$(sha256sum "$block_file" | awk '{print $1}')"
grep -Fqx "proposal-references-status=retained" "$CASE_DIR/publish-output"
python3 -B "$ROOT/scripts/proposal-references.py" parse "$block_file" \
  | jq -e --arg head "$assessed_head" --arg receipt "$receipt_sha" \
    --arg set "$connected_set" --slurpfile objects "$affected_file" '
    .source_pr == {repository_id:"987654321",number:7}
    and .source_head_sha == $head and .assessment_receipt_digest == $receipt
    and .proposal_set_digest == $set and .affected_objects == $objects[0]
  ' >/dev/null
# A receipt mutated after finalization no longer matches its digest.
printf 'x' >> "$receipt_file"
run_publish
jq -e '.status == "failed" and .reason == "receipt_digest_mismatch"' \
  "$CASE_DIR/out/proposal-references-status.json" >/dev/null
printf '%s\n' '{"schema_version":"adoc.pr_assessment_receipt.v4"}' > "$receipt_file"
TEST_BOOTSTRAP=true run_publish
jq -e '.status == "skipped" and .reason == "no_source_pr" and .path == null' \
  "$CASE_DIR/out/proposal-references-status.json" >/dev/null
cp "$CASE_DIR/out/proposal-status.json" "$CASE_DIR/proposal-status.saved"
jq '.sha256 = null' "$CASE_DIR/proposal-status.saved" > "$CASE_DIR/out/proposal-status.json"
run_publish
jq -e '.status == "skipped" and .reason == "no_proposal_record"' \
  "$CASE_DIR/out/proposal-references-status.json" >/dev/null
mv "$CASE_DIR/proposal-status.saved" "$CASE_DIR/out/proposal-status.json"
resolver=https://cloud.example.test/workspaces/ws-1 run_publish
jq -e '.status == "failed" and .reason == "cloud_proposal_resolver_invalid"' \
  "$CASE_DIR/out/proposal-references-status.json" >/dev/null

# A target patched twice carries the final post-patch hash, not the
# intermediate one.
cp "$CASE_DIR/out/patch-manifest.ndjson" "$CASE_DIR/manifest.saved"
cp "$CASE_DIR/out/proposal-status.json" "$CASE_DIR/proposal-status.saved"
git -C "$CASE_DIR/repo" worktree add -q --detach "$CASE_DIR/mid-tree" "$assessed_head"
(cd "$CASE_DIR/mid-tree" && "$ADOC_BIN" patch --apply "$CASE_DIR/out/patches/update.json" \
  --artifact "$graph" --as-of "$date" --format json >/dev/null \
  && "$ADOC_BIN" build --as-of "$date" --no-embeddings --out "$CASE_DIR/mid-build" >/dev/null)
git -C "$CASE_DIR/repo" worktree remove --force "$CASE_DIR/mid-tree"
mid_hash="$(jq -r '.nodes[] | select(.id == "fixture.ci.green") | .content_hash' \
  "$CASE_DIR/mid-build/docs.graph.json")"
jq -n --arg base "$mid_hash" \
  --arg reason "AgentDoc assessment $(jq -r .assessment_sha256 "$CASE_DIR/out/proposal-context.json") finding finding-003." '{
  schema_version:"adoc.patch.v0",op:"update_fields",target:"fixture.ci.green",
  base_hash:$base,changes:{fields:{owner:"platform"}},reason:$reason,
  proposer:{type:"agent",id:"agentdoc-action/claude-code@2.1.215/claude-sonnet-5"}
}' > "$CASE_DIR/out/patches/update2.json"
update2_sha="sha256:$(sha256sum "$CASE_DIR/out/patches/update2.json" | awk '{print $1}')"
{
  jq -c 'select(.operation == "create_object")' "$CASE_DIR/manifest.saved"
  jq -c 'select(.operation == "update_fields")' "$CASE_DIR/manifest.saved"
  jq -cn --arg path "$CASE_DIR/out/patches/update2.json" --arg sha "$update2_sha" '{
    schema_version:"adoc.patch.v0",operation:"update_fields",
    target:"fixture.ci.green",kind:"claim",status:"draft",
    finding_id:"finding-003",placement_path:"index.adoc",page_id:"fixture.kb",
    path:$path,sha256:$sha,logical_candidate:3,sequence:1,
    check_path:"placeholder",check_sha256:("sha256:" + ("3" * 64))}'
} > "$CASE_DIR/out/patch-manifest.ndjson"
multi_set="sha256:$(jq -sc 'map(.sha256)' "$CASE_DIR/out/patch-manifest.ndjson" \
  | sha256sum | awk '{print $1}')"
jq --arg sha "$multi_set" '.count = 3 | .sha256 = $sha' \
  "$CASE_DIR/proposal-status.saved" > "$CASE_DIR/out/proposal-status.json"
git --git-dir="$CASE_DIR/remote.git" update-ref refs/heads/feature "$assessed_head"
CLOUD_PROPOSAL_RESOLVER="$resolver" run_delivery
jq -e '.status == "complete"' "$CASE_DIR/out/delivery-status.json" >/dev/null
multi_head="$(git --git-dir="$CASE_DIR/remote.git" rev-parse refs/heads/feature)"
git -C "$CASE_DIR/repo" worktree add -q --detach "$CASE_DIR/multi-tree" "$multi_head"
(cd "$CASE_DIR/multi-tree" && "$ADOC_BIN" build --as-of "$date" \
  --no-embeddings --out "$CASE_DIR/multi-build" >/dev/null)
git -C "$CASE_DIR/repo" worktree remove --force "$CASE_DIR/multi-tree"
final_hash="$(jq -r '.nodes[] | select(.id == "fixture.ci.green") | .content_hash' \
  "$CASE_DIR/multi-build/docs.graph.json")"
test "$final_hash" != "$mid_hash"
jq -e --arg final "$final_hash" 'length == 2 and ([.[] | select(.object_id ==
  "fixture.ci.green") | .content_hash] == [$final])' "$affected_file" >/dev/null
mv "$CASE_DIR/manifest.saved" "$CASE_DIR/out/patch-manifest.ndjson"
mv "$CASE_DIR/proposal-status.saved" "$CASE_DIR/out/proposal-status.json"
rm -f "$CASE_DIR/out/patches/update2.json"
git --git-dir="$CASE_DIR/remote.git" update-ref refs/heads/feature "$delivered_head"

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
rm -f "$CASE_DIR/protection/calls"
CLOUD_PROPOSAL_RESOLVER="$resolver" TEST_HEAD="$delivered_head" run_delivery
jq -e '.status == "skipped" and .reason == "already_delivered"' \
  "$CASE_DIR/out/delivery-status.json" >/dev/null
test ! -e "$CASE_DIR/protection/calls"

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
test "$(sed -n 1p "$CASE_DIR/pr-body.md")" \
  = '<!-- AgentDoc-Proposal-Owner: agentdoc/test#7 -->'
test "$(sed -n 2p "$CASE_DIR/pr-body.md")" \
  = "<!-- AgentDoc-Assessed-Head: $assessed_head -->"
sed -n 3p "$CASE_DIR/pr-body.md" \
  | grep -Eq '^<!-- AgentDoc-Assessment-SHA256: sha256:[0-9a-f]{64} -->$'
grep -Fq '## Knowledge updates for #7' "$CASE_DIR/pr-body.md"
grep -Fq '| | Object | Change | Lifecycle | Page |' "$CASE_DIR/pr-body.md"
grep -Fq '### Bindings' "$CASE_DIR/pr-body.md"
grep -Fq '<sub>Owned by AgentDoc for #7.' "$CASE_DIR/pr-body.md"
grep -Fq '### Delivered to [#8](https://github.com/agentdoc/test/pull/8)' \
  "$CASE_DIR/out/delivery.md"
grep -Fq 'Diffs, evidence and canonical patches are in #8. Branch <code>adoc/proposals/pr-7</code>' \
  "$CASE_DIR/out/delivery.md"
grep -Fq 'pr create --repo agentdoc/test --head adoc/proposals/pr-7 --base feature --draft' \
  "$CASE_DIR/gh.log"
test "$(grep -c 'Cloud proposal' "$CASE_DIR/pr-body.md")" = 0

# Connected pr delivery links Cloud and publishes exactly one owned block.
# Later cases count cumulative gh calls, so this block's calls are dropped.
disconnected_head="$proposal_head"
sed -e "s/$disconnected_head/<D>/g" -e '/^Assessed `/d' "$CASE_DIR/pr-body.md" \
  > "$CASE_DIR/disconnected-body"
gh_lines="$(wc -l < "$CASE_DIR/gh.log")"
TEST_MODE=pr CLOUD_PROPOSAL_RESOLVER="$resolver" run_delivery
proposal_head="$(git --git-dir="$CASE_DIR/remote.git" \
  rev-parse refs/heads/adoc/proposals/pr-7)"
jq -e --arg d "$proposal_head" '.status == "complete" and .mode == "pr"
  and .delivery_commit == $d' "$CASE_DIR/out/delivery-status.json" >/dev/null
grep -Fqx -- "- [Cloud proposal]($cloud_url)" "$CASE_DIR/pr-body.md"
grep -vFx -- "- [Cloud proposal]($cloud_url)" "$CASE_DIR/pr-body.md" \
  | sed -e "s/$proposal_head/<D>/g" -e '/^Assessed `/d' \
  | cmp - "$CASE_DIR/disconnected-body"
git --git-dir="$CASE_DIR/remote.git" show -s --format=%B "$proposal_head" \
  | grep -Fqx "AgentDoc-Cloud-Proposal: $cloud_url"
for _ in 1 2; do
  run_publish
  jq -e '.status == "published"' \
    "$CASE_DIR/out/proposal-references-status.json" >/dev/null
  jq -j '.[0].body' "$CASE_DIR/pr-state.json" > "$CASE_DIR/published-body"
  test "$(grep -Fxc "$block_open" "$CASE_DIR/published-body")" = 1
  grep -Fq -- "- [Cloud proposal]($cloud_url)" "$CASE_DIR/published-body"
  python3 -B "$ROOT/scripts/proposal-references.py" parse "$CASE_DIR/published-body" \
    | cmp - <(sed -n 2p "$block_file")
done
# Republishing is byte-stable, and a CRLF-rewritten owned body still passes
# ownership and gets its block replaced (the README rerun claim).
cp "$CASE_DIR/published-body" "$CASE_DIR/published-once"
run_publish
jq -j '.[0].body' "$CASE_DIR/pr-state.json" | cmp - "$CASE_DIR/published-once"
jq '.[0].body |= gsub("\n"; "\r\n")' "$CASE_DIR/pr-state.json" > "$CASE_DIR/pr-state.next"
mv "$CASE_DIR/pr-state.next" "$CASE_DIR/pr-state.json"
run_publish
jq -e '.status == "published"' "$CASE_DIR/out/proposal-references-status.json" >/dev/null
jq -j '.[0].body' "$CASE_DIR/pr-state.json" | cmp - "$CASE_DIR/published-once"
cp "$CASE_DIR/pr-state.json" "$CASE_DIR/pr-state.saved"
patches="$(grep -c '^api -X PATCH' "$CASE_DIR/gh.log")"
# A body from another assessed head (a newer run) is never overwritten.
jq --arg h "$assessed_head" '.[0].body |= sub("AgentDoc-Assessed-Head: " + $h; "AgentDoc-Assessed-Head: " + ("e" * 40))' \
  "$CASE_DIR/pr-state.saved" > "$CASE_DIR/pr-state.json"
run_publish
jq -e '.status == "failed" and .reason == "proposal_body_changed"' \
  "$CASE_DIR/out/proposal-references-status.json" >/dev/null
# A decoy ref whose tail matches the branch cannot stand in for its head.
git --git-dir="$CASE_DIR/remote.git" update-ref \
  refs/heads/0/refs/heads/adoc/proposals/pr-7 "$proposal_head"
git --git-dir="$CASE_DIR/remote.git" update-ref refs/heads/adoc/proposals/pr-7 "$assessed_head"
cp "$CASE_DIR/pr-state.saved" "$CASE_DIR/pr-state.json"
run_publish
jq -e '.status == "failed" and .reason == "proposal_branch_diverged"' \
  "$CASE_DIR/out/proposal-references-status.json" >/dev/null
git --git-dir="$CASE_DIR/remote.git" update-ref -d refs/heads/0/refs/heads/adoc/proposals/pr-7
git --git-dir="$CASE_DIR/remote.git" update-ref refs/heads/adoc/proposals/pr-7 "$proposal_head"
test ! -e "$CASE_DIR/out/proposal-references-body"
jq '.[0].body |= sub("agentdoc/test#7 -->"; "agentdoc/test#99 -->")' \
  "$CASE_DIR/pr-state.saved" > "$CASE_DIR/pr-state.json"
run_publish
jq -e '.status == "failed" and .reason == "proposal_branch_unowned"' \
  "$CASE_DIR/out/proposal-references-status.json" >/dev/null
cp "$CASE_DIR/pr-state.saved" "$CASE_DIR/pr-state.json"
git --git-dir="$CASE_DIR/remote.git" update-ref refs/heads/adoc/proposals/pr-7 "$assessed_head"
run_publish
jq -e '.status == "failed" and .reason == "proposal_branch_diverged"' \
  "$CASE_DIR/out/proposal-references-status.json" >/dev/null
git --git-dir="$CASE_DIR/remote.git" update-ref refs/heads/adoc/proposals/pr-7 "$proposal_head"
test "$(grep -c '^api -X PATCH' "$CASE_DIR/gh.log")" = "$patches"
jq -e '.status == "complete"' "$CASE_DIR/out/delivery-status.json" >/dev/null
mv "$CASE_DIR/pr-state.saved" "$CASE_DIR/pr-state.json"
rm -f "$receipt_file" "$CASE_DIR/out/receipt-sha256"
head -n "$gh_lines" "$CASE_DIR/gh.log" > "$CASE_DIR/gh.log.next"
mv "$CASE_DIR/gh.log.next" "$CASE_DIR/gh.log"

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
# Fork pr delivery keeps the source PR binding in the base-repository PR.
grep -Fq '[source PR #7](https://github.com/agentdoc/test/pull/7)' "$CASE_DIR/pr-body.md"
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
