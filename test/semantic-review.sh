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
  nodes:[
    {type:"page",id:"billing.index",order:0,title:"Billing",source_path:"docs/index.adoc"},
    {
      type:"knowledge_object",id:"billing.refunds",kind:"claim",
      content_hash:$hash,status:"open",body:"Refunds are recorded before settlement.",
      page_id:"billing.index",source_span:{path:"docs/index.adoc",line:3,column:1},
      fields:{},relations:{depends_on:[],supersedes:[],related_to:[]},
      impacts:["src/refunds.rs"]
    }
  ],
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
export ADOC_PROPOSE_ELIGIBLE=true SEMANTIC_REVIEW=true PROPOSE=true PROPOSE_MAX_PATHS=10
export MODEL=claude-sonnet-5 CAPTURE="$CASE_DIR" MOCK_GRAPH="$CASE_DIR/graph.json"
export CONTENT_HASH="$content_hash" RUNNER_TEMP="$CASE_DIR/private"
export INPUT_ANTHROPIC_API_KEY=api-secret GH_TOKEN=gh-canary
export AWS_SECRET_ACCESS_KEY=aws-canary NPM_TOKEN=npm-canary
export PATH="$CASE_DIR/bin:$PATH"
printf '%s\n' "$CASE_DIR/assessment.json" > "$ADOC_RUN_DIR/assessment-path"
printf '%s\n' "$assessment_sha" > "$ADOC_RUN_DIR/assessment-sha256"
jq -n '{requested_version:"v0.3.4",resolved_version:"v0.3.4",
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
  and (.findings[0] | has("provider_ref") | not)
  and .findings[0].classification == "extends_existing_knowledge"
  and .findings[0].headline == "Refund persistence extends the documented workflow."
  and .findings[0].code_evidence[0].hunk_id == "hunk-001"
  and .findings[0].knowledge_evidence[0].id == "billing.refunds"
  and ([.path_dispositions[].path] | sort)
    == ["src/reconcile.rs","src/refunds.rs"]
  and all(.path_dispositions[]; .disposition == "create_knowledge")
  and .provider.name == "claude-code"
  and .input_context.knowledge_objects[0].id == "billing.refunds"
  and (.input_context.lexical_projection.queries | length) == 1
  and .input_context.lexical_projection.queries[0].path == "src/reconcile.rs"
' "$ADOC_RETAINED_DIR/semantic-$ADOC_INVOCATION_ID.json" >/dev/null
jq -e '.status == "complete" and (.sha256 | startswith("sha256:"))' \
  "$ADOC_RUN_DIR/semantic-status.json" >/dev/null
test "$(cat "$CASE_DIR/build-head")" = "$head"
test "$(cat "$CASE_DIR/build-pwd")" != "$CASE_DIR/repo"
grep -q 'src/reconcile.rs' "$CASE_DIR/search-query"
test "$(cat "$ADOC_RUN_DIR/adoc-semantic-code")" = 0
grep -qx 'ANTHROPIC_API_KEY=api-secret' "$ADOC_RUN_DIR/provider-env"
! grep -Eq '^(GH_TOKEN|AWS_SECRET_ACCESS_KEY|NPM_TOKEN|INPUT_)=' \
  "$ADOC_RUN_DIR/provider-env"
grep -qx -- '--safe-mode' "$ADOC_RUN_DIR/provider-args"
grep -qx -- '--json-schema' "$ADOC_RUN_DIR/provider-args"
grep -qx -- '--strict-mcp-config' "$ADOC_RUN_DIR/provider-args"
grep -qx -- '--disable-slash-commands' "$ADOC_RUN_DIR/provider-args"
grep -qx -- '--no-session-persistence' "$ADOC_RUN_DIR/provider-args"
grep -qx -- '--no-chrome' "$ADOC_RUN_DIR/provider-args"
test "$(cat "$ADOC_RUN_DIR/provider-cwd-capture")" != "$CASE_DIR/repo"
test "$(wc -l < "$ADOC_RUN_DIR/provider-calls" | tr -d ' ')" = 1
jq -e '
  length == 1
  and .[0].finding_id == "finding-001"
  and (.[0] | has("finding_ref") | not)
  and .[0].target == "billing.refund-persistence"
  and .[0].placement == {page_id:"billing.index",after:"billing.refunds"}
' "$ADOC_RUN_DIR/proposal-candidates.json" >/dev/null

for sensitive in semantic-system.md semantic-prompt.md semantic-raw.json \
  semantic-stderr.log input-manifest.json bounded.diff head-worktree semantic-build; do
  test ! -e "$ADOC_RUN_DIR/$sensitive"
done

export GITHUB_OUTPUT="$CASE_DIR/github-output" GITHUB_REPOSITORY=agentdoc/test
export GITHUB_RUN_ID=1 GITHUB_RUN_ATTEMPT=1 GITHUB_JOB=semantic
export GITHUB_ACTOR=test GITHUB_ACTION_REF=v2.0.0-alpha.2
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
REPORT_STYLE=compact ENFORCEMENT=advisory SCOPE=full ADOC_VERSION=v0.3.4 \
  SEMANTIC_REVIEW=true PROPOSE=false PROPOSE_DELIVERY=comment \
  "$ROOT/scripts/compose.sh"
grep -q '### Semantic review' "$ADOC_RUN_DIR/report.md"
grep -q 'Model-assisted, advisory' "$ADOC_RUN_DIR/report.md"
grep -q 'finding-001' "$ADOC_RUN_DIR/report.md" || {
  cat "$ADOC_RUN_DIR/report.md" >&2
  exit 1
}
grep -Fq 'Refund persistence extends the documented workflow.' "$ADOC_RUN_DIR/report.md"
grep -Fq '](https://github.com/agentdoc/test/blob/' "$ADOC_RUN_DIR/report.md"
grep -Fq '<details open><summary>📝 Knowledge should be extended' \
  "$ADOC_RUN_DIR/report.md"
grep -Fq '#### Knowledge sync coverage' "$ADOC_RUN_DIR/report.md"
grep -Fq '<details><summary>Path dispositions</summary>' \
  "$ADOC_RUN_DIR/report.md"
grep -Fq '<details><summary>Audit metadata</summary>' "$ADOC_RUN_DIR/report.md"

# Every classification keeps the same judgment-first structure. Actionable
# findings open by default; consistent findings remain collapsed.
jq '
  .findings[0] as $finding
  | .findings = [
      ($finding | .finding_id = "finding-001" | .classification = "consistent"
        | .headline = "The change matches current knowledge." | .proposal_expected = false),
      ($finding | .finding_id = "finding-002" | .classification = "extends_existing_knowledge"
        | .headline = "The change extends current knowledge."),
      ($finding | .finding_id = "finding-003" | .classification = "contradicts_existing_knowledge"
        | .headline = "The change contradicts current knowledge." | .proposal_expected = false),
      ($finding | .finding_id = "finding-004" | .classification = "insufficient_evidence"
        | .headline = "The supplied evidence is insufficient." | .proposal_expected = false)
    ]
' "$semantic_path" > "$ADOC_RUN_DIR/all-classifications.json"
jq --arg path "$ADOC_RUN_DIR/all-classifications.json" '.path = $path' \
  "$ADOC_RUN_DIR/semantic-status.json" > "$ADOC_RUN_DIR/semantic-status.next"
mv "$ADOC_RUN_DIR/semantic-status.next" "$ADOC_RUN_DIR/semantic-status.json"
REPORT_STYLE=compact ENFORCEMENT=advisory SCOPE=full ADOC_VERSION=v0.3.4 \
  SEMANTIC_REVIEW=true PROPOSE=false PROPOSE_DELIVERY=comment \
  "$ROOT/scripts/compose.sh"
grep -Fq '<details><summary>✅ Consistent with knowledge' "$ADOC_RUN_DIR/report.md"
grep -Fq '<details open><summary>📝 Knowledge should be extended' "$ADOC_RUN_DIR/report.md"
grep -Fq '<details open><summary>⚠️ Contradicts knowledge' "$ADOC_RUN_DIR/report.md"
grep -Fq '<details open><summary>❓ Insufficient evidence' "$ADOC_RUN_DIR/report.md"
grep -A8 '^  semantic-review:' "$ROOT/action.yml" | grep -q 'default: "false"'
grep -A4 '^  provider-timeout-seconds:' "$ROOT/action.yml" \
  | grep -q 'default: "600"'
dollar='$'
grep -Fq "PROVIDER_TIMEOUT_SECONDS: ${dollar}{{ inputs.provider-timeout-seconds }}" \
  "$ROOT/action.yml"
grep -Fq 'Every create candidate target must be a new, globally unique Object ID.' \
  "$ROOT/prompts/semantic-review-v0.md"
grep -Fq '"operation":"update"' "$ROOT/prompts/semantic-review-v0.md"
jq -e '.properties.patch_candidates.items.properties.target.pattern
  == "^[a-z0-9]+(-[a-z0-9]+)*(\\.[a-z0-9]+(-[a-z0-9]+)*)+$"' \
  "$ROOT/prompts/semantic-review-v0.schema.json" >/dev/null

combination_case() {
  local name="$1" semantic="$2" propose="$3" mode="$4" private
  private="$CASE_DIR/private-$name"
  mkdir "$private"
  export ADOC_RUN_DIR="$private"
  export ADOC_INVOCATION_ID="inv_1_1_${name//-/_}_0123456789abcdef0123456789abcdef"
  export SEMANTIC_REVIEW="$semantic" PROPOSE="$propose"
  printf '%s\n' "$CASE_DIR/assessment.json" > "$private/assessment-path"
  printf '%s\n' "$assessment_sha" > "$private/assessment-sha256"
  cp "$CASE_DIR/private/adoc-toolchain.json" "$private/adoc-toolchain.json"
  cp "$CASE_DIR/private/provider-provenance.json" "$private/provider-provenance.json"
  printf '%s\n' '{"semantic_review":"pending"}' > "$private/stages.json"
  printf '%s\n' "$mode" > "$private/mock-mode"
  (cd "$CASE_DIR/repo" && "$ROOT/scripts/semantic-review.sh" \
    "$ROOT/test/mock-claude-semantic.sh")
}

combination_case semantic-only true false semantic-only
jq -e '.status == "complete"' "$ADOC_RUN_DIR/semantic-status.json" >/dev/null
jq -e 'length == 0' "$ADOC_RUN_DIR/proposal-candidates.json" >/dev/null
test -f "$ADOC_RETAINED_DIR/semantic-$ADOC_INVOCATION_ID.json"

combination_case proposal-only false true valid
jq -e '.status == "disabled" and .reason == "input_disabled"' \
  "$ADOC_RUN_DIR/semantic-status.json" >/dev/null
jq -e 'length == 1 and .[0].target == "billing.refund-persistence"' \
  "$ADOC_RUN_DIR/proposal-candidates.json" >/dev/null
test ! -e "$ADOC_RETAINED_DIR/semantic-$ADOC_INVOCATION_ID.json"

combination_case multi-extension true true multi-extension
jq -e '.status == "complete"' "$ADOC_RUN_DIR/semantic-status.json" >/dev/null
jq -e '
  length == 2
  and ([.[].target] | length == (unique | length))
  and all(.[]; .target != "billing.refunds")
' "$ADOC_RUN_DIR/proposal-candidates.json" >/dev/null

export PROPOSE_MAX_PATHS=1 PROPOSE_COVERAGE=full
combination_case full-coverage true true valid
jq -e '.bounded_diff.selected_paths == 2
  and (.path_dispositions | length) == 2' \
  "$ADOC_RETAINED_DIR/semantic-$ADOC_INVOCATION_ID.json" >/dev/null
export BOOTSTRAP=true
combination_case bootstrap-batch true true valid
jq -e '.bounded_diff.selected_paths == 1
  and .bounded_diff.omitted_paths == 0
  and (.path_dispositions | map(.path)) == ["src/reconcile.rs"]' \
  "$ADOC_RETAINED_DIR/semantic-$ADOC_INVOCATION_ID.json" >/dev/null
export BOOTSTRAP=false
export PROPOSE_MAX_PATHS=10 PROPOSE_COVERAGE=bounded

combination_case disabled false false valid
jq -e '.status == "disabled" and .reason == "input_disabled"' \
  "$ADOC_RUN_DIR/semantic-status.json" >/dev/null
test ! -e "$ADOC_RUN_DIR/provider-calls"
test ! -e "$ADOC_RUN_DIR/proposal-candidates.json"

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
  export SEMANTIC_REVIEW=true PROPOSE=true
  (cd "$CASE_DIR/repo" && "$ROOT/scripts/semantic-review.sh" "$ROOT/test/mock-claude-semantic.sh")
  jq -e '.status == "error" and .reason == "provider_contract_failed"' \
    "$private/semantic-status.json" >/dev/null
  test "$(cat "$private/adoc-semantic-code")" = 1
  test ! -e "$ADOC_RETAINED_DIR/semantic-$ADOC_INVOCATION_ID.json"
}

invalid_case hallucinated-path
invalid_case unknown-classification
invalid_case multiline-headline
invalid_case long-headline

combination_case timeout true true timeout
jq -e '.status == "error" and .reason == "provider_timeout"' \
  "$ADOC_RUN_DIR/semantic-status.json" >/dev/null

echo 'cited semantic review tests passed'
