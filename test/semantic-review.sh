#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CASE_DIR="$(mktemp -d)"
trap 'rm -rf "$CASE_DIR"' EXIT
mkdir -p "$CASE_DIR/repo/docs" "$CASE_DIR/bin" "$CASE_DIR/private" "$CASE_DIR/retained"

git -C "$CASE_DIR/repo" init -q -b main
git -C "$CASE_DIR/repo" config user.name test
git -C "$CASE_DIR/repo" config user.email test@example.com
printf 'version: 1\nmode: strict\ndocs_path: docs\noutputs:\n  dir: dist\n' \
  > "$CASE_DIR/repo/agentdoc.config.yaml"
cat > "$CASE_DIR/repo/docs/index.adoc" <<'EOF'
# Billing

::claim billing.refunds
status: open
impacts: [src/refunds.rs]
--
Refunds are recorded before settlement.
::
EOF
mkdir -p "$CASE_DIR/repo/src"
printf 'fn refund() {}\n' > "$CASE_DIR/repo/src/refunds.rs"
git -C "$CASE_DIR/repo" add -A
git -C "$CASE_DIR/repo" commit -qm base
base="$(git -C "$CASE_DIR/repo" rev-parse HEAD)"
printf 'fn refund() { persist(); }\n' > "$CASE_DIR/repo/src/refunds.rs"
printf 'fn reconcile() {}\n' > "$CASE_DIR/repo/src/reconcile.rs"
git -C "$CASE_DIR/repo" commit -qam head
git -C "$CASE_DIR/repo" add src/reconcile.rs
git -C "$CASE_DIR/repo" commit --amend -qm head
head="$(git -C "$CASE_DIR/repo" rev-parse HEAD)"

content_hash="sha256:$(printf billing.refunds | sha256sum | awk '{print $1}')"
jq -n --arg hash "$content_hash" '{
  schema_version:"adoc.graph.v5",
  repository_identity:{kind:"local_project",config_path:"agentdoc.config.yaml"},
  nodes:[{
    type:"knowledge_object",id:"billing.refunds",kind:"claim",
    content_hash:$hash,status:"open",body:"Refunds are recorded before settlement.",
    page_id:"billing.index",source_span:{path:"docs/index.adoc",line:3,column:1},
    fields:{},relations:{depends_on:[],supersedes:[],related_to:[]},
    impacts:["src/refunds.rs"]
  }],
  edges:[],diagnostics:[]
}' > "$CASE_DIR/graph.json"
graph_sha="sha256:$(sha256sum "$CASE_DIR/graph.json" | awk '{print $1}')"
jq -c '[.nodes[] | select(.type == "knowledge_object") | {id,content_hash}] | sort_by(.id)' \
  "$CASE_DIR/graph.json" | tr -d '\n' > "$CASE_DIR/object-set.json"
object_sha="sha256:$(sha256sum "$CASE_DIR/object-set.json" | awk '{print $1}')"

jq -n --arg base "$base" --arg head "$head" --arg graph "$graph_sha" \
  --arg objects "$object_sha" --arg hash "$content_hash" '{
  schema_version:"adoc.change_assessment.v0",completeness:"complete",
  outcome:"review_required",evaluation_date:"2026-07-23",
  snapshots:{
    requested_base:{requested_ref:$base,resolved_commit:$base,immutable:true},
    comparison_base:{resolved_commit:$base,immutable:true,strategy:"merge_base"},
    head:{requested_ref:$head,resolved_commit:$head,immutable:true}
  },
  knowledge_snapshot:{
    status:"available",graph_schema_version:"adoc.graph.v5",
    graph_sha256:$graph,object_set_sha256:$objects,docs_path:"docs"
  },
  paths:{status:"available",value:[
    {path:"src/refunds.rs",classification:"covered",
      matches:[{object_id:"billing.refunds",reason:"impacts_path"}]},
    {path:"src/reconcile.rs",classification:"uncovered",matches:[]}
  ]},
  objects:{status:"available",value:[{
    id:"billing.refunds",kind:"claim",content_hash:$hash,
    authority:"advisory",changed_in_pr:"no",reviewers:[],
    source:{path:"docs/index.adoc",line:3,column:1},
    reasons:[{path:"src/refunds.rs",reason:"impacts_path"}]
  }]}
}' > "$CASE_DIR/assessment.json"
assessment_sha="sha256:$(sha256sum "$CASE_DIR/assessment.json" | awk '{print $1}')"

cat > "$CASE_DIR/bin/adoc" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "$1" in
  build)
    printf '%s\n' "$PWD" > "$CAPTURE/build-pwd"
    printf '%s\n' "$(git rev-parse HEAD)" > "$CAPTURE/build-head"
    while [ "$#" -gt 0 ]; do
      if [ "$1" = --out ]; then out="$2"; shift 2; else shift; fi
    done
    mkdir -p "$out"
    cp "$MOCK_GRAPH" "$out/docs.graph.json"
    ;;
  search)
    printf '%s\n' "$2" > "$CAPTURE/search-query"
    jq -n --arg hash "$CONTENT_HASH" '{
      schema_version:"adoc.retrieval.v1",
      records:[{record_type:"knowledge_object",id:"billing.refunds",content_hash:$hash}],
      diagnostics:[]
    }'
    ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$CASE_DIR/bin/adoc" "$ROOT/test/mock-claude-semantic.sh"

export ADOC_RUN_DIR="$CASE_DIR/private" ADOC_RETAINED_DIR="$CASE_DIR/retained"
export ADOC_INVOCATION_ID=inv_1_1_semantic_0123456789abcdef0123456789abcdef
export ADOC_EVALUATION_DATE=2026-07-23 ADOC_REQUESTED_BASE="$base"
export ADOC_COMPARISON_BASE="$base" ADOC_HEAD="$head"
export ADOC_PROPOSE_ELIGIBLE=true SEMANTIC_REVIEW=true PROPOSE_MAX_PATHS=10
export MODEL=claude-sonnet-5 CAPTURE="$CASE_DIR" MOCK_GRAPH="$CASE_DIR/graph.json"
export CONTENT_HASH="$content_hash" RUNNER_TEMP="$CASE_DIR/private"
export PATH="$CASE_DIR/bin:$PATH"
printf '%s\n' "$CASE_DIR/assessment.json" > "$ADOC_RUN_DIR/assessment-path"
printf '%s\n' "$assessment_sha" > "$ADOC_RUN_DIR/assessment-sha256"
jq -n '{requested_version:"v0.3.2",resolved_version:"v0.3.2",
  binary_sha256:("sha256:"+("a"*64))}' > "$ADOC_RUN_DIR/adoc-toolchain.json"
jq -n '{provider:"claude-code",package:"fixture",version:"2.1.215",
  sha512:("b"*128)}' > "$ADOC_RUN_DIR/provider-provenance.json"
printf '%s\n' '{"semantic_review":"pending"}' > "$ADOC_RUN_DIR/stages.json"

(cd "$CASE_DIR/repo" && "$ROOT/scripts/semantic-review.sh" "$ROOT/test/mock-claude-semantic.sh")

jq -e --arg base "$base" --arg head "$head" --arg assessment "$assessment_sha" '
  .schema_version == "adoc.semantic_review.v0"
  and .status == "complete"
  and .assessment_sha256 == $assessment
  and .revisions == {comparison_base:$base,head:$head}
  and .findings[0].finding_id == "finding-001"
  and .findings[0].classification == "extends_existing_knowledge"
  and .findings[0].code_evidence[0].hunk_id == "hunk-001"
  and .findings[0].knowledge_evidence[0].id == "billing.refunds"
  and .provider.name == "claude-code"
  and .input_context.knowledge_objects[0].id == "billing.refunds"
  and (.input_context.lexical_projection.queries | length) == 1
  and .input_context.lexical_projection.queries[0].path == "src/reconcile.rs"
' "$ADOC_RETAINED_DIR/semantic-$ADOC_INVOCATION_ID.json" >/dev/null
jq -e '.status == "complete" and (.sha256 | startswith("sha256:"))' \
  "$ADOC_RUN_DIR/semantic-status.json" >/dev/null
grep -q 'Model-assisted, advisory' "$ADOC_RUN_DIR/semantic-review.md"
test "$(cat "$CASE_DIR/build-head")" = "$head"
test "$(cat "$CASE_DIR/build-pwd")" != "$CASE_DIR/repo"
grep -q 'src/reconcile.rs' "$CASE_DIR/search-query"
test "$(cat "$ADOC_RUN_DIR/adoc-semantic-code")" = 0

for sensitive in semantic-system.md semantic-prompt.md semantic-raw.json \
  semantic-stderr.log input-manifest.json bounded.diff head-worktree semantic-build; do
  test ! -e "$ADOC_RUN_DIR/$sensitive"
done

export GITHUB_OUTPUT="$CASE_DIR/github-output" GITHUB_REPOSITORY=agentdoc/test
export GITHUB_RUN_ID=1 GITHUB_RUN_ATTEMPT=1 GITHUB_JOB=semantic
export GITHUB_ACTOR=test GITHUB_ACTION_REF=v2.0.0-alpha.1
export GITHUB_ACTION_REPOSITORY=agentdoc-dev/action ADOC_PR_NUMBER=1
ENFORCEMENT=advisory SCOPE=full SEMANTIC_REVIEW=true PROPOSE=false \
  PROPOSE_ON_ERROR=warn PROPOSE_DELIVERY=comment "$ROOT/scripts/finalize.sh"
semantic_path="$(sed -n 's/^semantic-review-path=//p' "$GITHUB_OUTPUT" | tail -n 1)"
semantic_sha="$(sed -n 's/^semantic-review-sha256=//p' "$GITHUB_OUTPUT" | tail -n 1)"
test "$semantic_path" = "$ADOC_RETAINED_DIR/semantic-$ADOC_INVOCATION_ID.json"
test "$semantic_sha" = "sha256:$(sha256sum "$semantic_path" | awk '{print $1}')"
jq -e '
  .policy.semantic_review == true
  and .semantic_review.status == "complete"
  and .semantic_review.schema_version == "adoc.semantic_review.v0"
  and (.semantic_review.sha256 | startswith("sha256:"))
' "$ADOC_RETAINED_DIR/receipt-$ADOC_INVOCATION_ID.json" >/dev/null
REPORT_STYLE=compact ENFORCEMENT=advisory SCOPE=full ADOC_VERSION=v0.3.2 \
  "$ROOT/scripts/compose.sh"
grep -q '### Semantic Review' "$ADOC_RUN_DIR/report.md"
grep -q 'Model-assisted, advisory' "$ADOC_RUN_DIR/report.md"
grep -q 'finding-001' "$ADOC_RUN_DIR/report.md" || {
  cat "$ADOC_RUN_DIR/report.md" >&2
  exit 1
}
grep -A8 '^  semantic-review:' "$ROOT/action.yml" | grep -q 'default: "false"'

invalid_case() {
  local mode="$1" private
  private="$CASE_DIR/private-$mode"
  mkdir "$private"
  export ADOC_RUN_DIR="$private"
  export ADOC_INVOCATION_ID="inv_1_1_${mode//-/_}_0123456789abcdef0123456789abcdef"
  printf '%s\n' "$CASE_DIR/assessment.json" > "$private/assessment-path"
  printf '%s\n' "$assessment_sha" > "$private/assessment-sha256"
  cp "$CASE_DIR/private/adoc-toolchain.json" "$private/adoc-toolchain.json"
  cp "$CASE_DIR/private/provider-provenance.json" "$private/provider-provenance.json"
  printf '%s\n' '{"semantic_review":"pending"}' > "$private/stages.json"
  printf '%s\n' "$mode" > "$private/mock-mode"
  (cd "$CASE_DIR/repo" && "$ROOT/scripts/semantic-review.sh" "$ROOT/test/mock-claude-semantic.sh")
  jq -e '.status == "error" and .reason == "provider_contract_failed"' \
    "$private/semantic-status.json" >/dev/null
  test "$(cat "$private/adoc-semantic-code")" = 1
  test ! -e "$ADOC_RETAINED_DIR/semantic-$ADOC_INVOCATION_ID.json"
}

invalid_case hallucinated-path
invalid_case unknown-classification

echo 'cited semantic review tests passed'
