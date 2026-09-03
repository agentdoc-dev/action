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
printf 'fn reconcile() {' > "$CASE_DIR/repo/src/reconcile.rs"
head -c 8192 /dev/zero | tr '\0' x >> "$CASE_DIR/repo/src/reconcile.rs"
printf '}\n' >> "$CASE_DIR/repo/src/reconcile.rs"
git -C "$CASE_DIR/repo" commit -qam head
git -C "$CASE_DIR/repo" add src/reconcile.rs
git -C "$CASE_DIR/repo" commit --amend -qm head
head="$(git -C "$CASE_DIR/repo" rev-parse HEAD)"

content_hash="sha256:$(printf billing.refunds | sha256sum | awk '{print $1}')"
lexical_hash="sha256:$(printf billing.lexical | sha256sum | awk '{print $1}')"
jq -n --arg hash "$content_hash" --arg lexical_hash "$lexical_hash" '{
  schema_version:"adoc.graph.v5",
  repository_identity:{kind:"local_project",config_path:"agentdoc.config.yaml"},
  nodes:[
    {type:"page",id:"billing.index",order:0,title:"Billing",source_path:"docs/index.adoc"},
    {type:"page",id:"billing.other",order:1,title:"Other",source_path:"docs/other.adoc"},
    {
      type:"knowledge_object",id:"billing.refunds",kind:"claim",
      content_hash:$hash,status:"open",body:"Refunds are recorded before settlement.",
      page_id:"billing.index",source_span:{path:"docs/index.adoc",line:3,column:1},
      fields:{},relations:{depends_on:[],supersedes:[],related_to:[]},
      impacts:null
    },
    {
      type:"knowledge_object",id:"billing.lexical",kind:"claim",
      content_hash:$lexical_hash,status:"open",body:"Lexically related billing guidance.",
      page_id:"billing.index",source_span:{path:"docs/index.adoc",line:9,column:1},
      fields:{},relations:{depends_on:[],supersedes:[],related_to:[]},
      impacts:null
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
    printf '%s' "$2" > "$CAPTURE/search-query"
    jq -n --arg hash "$LEXICAL_HASH" '{
      schema_version:"adoc.retrieval.v1",
      records:[{record_type:"knowledge_object",id:"billing.lexical",content_hash:$hash}],
      diagnostics:[]
    }'
    ;;
  semantic-context)
    [ "${MOCK_SEMANTIC_RUNTIME:-true}" = true ] || exit 2
    [ "${2:-}" != --help ] || exit 0
    shift
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --input) input="$2"; shift 2 ;;
        --out) out="$2"; shift 2 ;;
        *) shift ;;
      esac
    done
    jq '
      .schema_version = "adoc.semantic_context.v0"
      | .coverage = [{class_id:"changed_knowledge",requirement:"required",
          item_count:(.items|length),included_bytes:1,byte_budget:2097152,
          truncated:false,unavailable_count:0,reasons:[],complete:true}]
      | .outcome = "ready"
      | .context_digest = ("sha256:" + ("c" * 64))
    ' "$input" > "$out"
    cp "$input" "$CAPTURE/semantic-context-input.json"
    cp "$out" "$CAPTURE/semantic-context-output.json"
    cat "$out"
    ;;
  semantic-executor)
    [ "${MOCK_SEMANTIC_RUNTIME:-true}" = true ] || exit 2
    [ "${2:-}" != --help ] || exit 0
    shift
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --request) request="$2"; shift 2 ;;
        --assessment) assessment="$2"; shift 2 ;;
        --receipt) receipt="$2"; shift 2 ;;
        --validated-assessment) validated="$2"; shift 2 ;;
        *) shift ;;
      esac
    done
    prompt_contract="$(jq -cS '.prompt | {contract_version,instructions}' "$request")"
    prompt_digest="sha256:$(printf '%s' "$prompt_contract" | sha256sum | awk '{print $1}')"
    test "$(jq -r '.prompt.digest' "$request")" = "$prompt_digest"
    jq -e --slurpfile request "$request" '
      .schema_version == "adoc.semantic_assessment.v0"
      and .context_digest == $request[0].context.context_digest
      and .identity.provider == $request[0].adapter.provider
      and .identity.model == $request[0].adapter.model
      and all(.findings[]; (.citations | length) > 0)
    ' "$assessment" >/dev/null
    case "${MOCK_VALIDATED_ASSESSMENT:-}" in
      unknown-scope)
        jq '.scope.handle_ids += ["unknown-handle"]' "$assessment" > "$validated"
        ;;
      out-of-scope-citation)
        jq '.findings[0].citations += ["hunk-999"]' "$assessment" > "$validated"
        ;;
      fabricated-affected-object)
        jq '.findings[0].affected_objects += [{
          object_id:"billing.fabricated",
          content_hash:("sha256:" + ("f" * 64))
        }]' "$assessment" > "$validated"
        ;;
      stale-affected-object-hash)
        jq '.findings[0].affected_objects[0].content_hash =
          ("sha256:" + ("f" * 64))' "$assessment" > "$validated"
        ;;
      *) cp "$assessment" "$validated" ;;
    esac
    assessment_digest="sha256:$(sha256sum "$validated" | awk '{print $1}')"
    jq -n --slurpfile request "$request" --arg assessment_digest "$assessment_digest" '{
      schema_version:"adoc.semantic_executor_receipt.v0",
      request_id:$request[0].request_id,
      request_digest:("sha256:" + ("d" * 64)),
      capability:$request[0].capability,adapter:$request[0].adapter,
      task_digest:$request[0].task_digest,prompt_digest:$request[0].prompt.digest,
      context_digest:$request[0].context.context_digest,outcome:"completed",
      assessment_digest:$assessment_digest
    }' > "$receipt"
    touch "$CAPTURE/semantic-runtime-called"
    cat "$receipt"
    ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$CASE_DIR/bin/adoc" "$ROOT/test/mock-claude-semantic.sh"

cat > "$CASE_DIR/bin/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
jq -n --arg base "$ADOC_REQUESTED_BASE" \
  --arg head "${TEST_TRUSTED_OBSERVED_HEAD:-$ADOC_HEAD}" '{
  state:"open",base:{sha:$base,ref:"main",repo:{full_name:"agentdoc/test"}},
  head:{sha:$head,repo:{full_name:"agentdoc/test"}}
}'
EOF
chmod +x "$CASE_DIR/bin/gh"

export ADOC_RUN_DIR="$CASE_DIR/private" ADOC_RETAINED_DIR="$CASE_DIR/retained"
export ADOC_INVOCATION_ID=inv_1_1_semantic_0123456789abcdef0123456789abcdef
export ADOC_EVALUATION_DATE=2026-07-23 ADOC_REQUESTED_BASE="$base"
export ADOC_COMPARISON_BASE="$base" ADOC_HEAD="$head"
export ADOC_PROPOSE_ELIGIBLE=true SEMANTIC_REVIEW=true PROPOSE=true PROPOSE_MAX_PATHS=10
export MODEL=claude-sonnet-5 CAPTURE="$CASE_DIR" MOCK_GRAPH="$CASE_DIR/graph.json"
export CONTENT_HASH="$content_hash" LEXICAL_HASH="$lexical_hash"
export RUNNER_TEMP="$CASE_DIR/private"
export INPUT_ANTHROPIC_API_KEY=api-secret GH_TOKEN=gh-canary
export AWS_SECRET_ACCESS_KEY=aws-canary NPM_TOKEN=npm-canary
export PATH="$CASE_DIR/bin:$PATH"
jq -n --arg base "$base" --arg head "$head" '{
  base_repository:"agentdoc/test",head_repository:"agentdoc/test",
  pull_request:1,base_ref:"main",base_revision:$base,head_revision:$head
}' > "$CASE_DIR/trusted-request.json"
export ADOC_TRUSTED_CHANGE_REQUEST_PATH="$CASE_DIR/trusted-request.json"
printf '%s\n' "$CASE_DIR/assessment.json" > "$ADOC_RUN_DIR/assessment-path"
printf '%s\n' "$assessment_sha" > "$ADOC_RUN_DIR/assessment-sha256"
jq -n '{requested_version:"v0.3.4",resolved_version:"v0.3.4",
  binary_sha256:("sha256:"+("a"*64))}' > "$ADOC_RUN_DIR/adoc-toolchain.json"
jq -n '{provider:"claude-code",package:"fixture",version:"2.1.215",
  sha512:("b"*128)}' > "$ADOC_RUN_DIR/provider-provenance.json"
printf '%s\n' '{"semantic_review":"pending"}' > "$ADOC_RUN_DIR/stages.json"

(cd "$CASE_DIR/repo" && "$ROOT/scripts/semantic-review.sh" "$ROOT/test/mock-claude-semantic.sh") \
  2> "$CASE_DIR/action-stderr"

jq -e '.knowledge_objects[0].impacts == []' \
  "$ADOC_RUN_DIR/proposal-context.json" >/dev/null
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
test "$(wc -c < "$CASE_DIR/search-query" | tr -d ' ')" -le 4096
! grep -q 'Broken pipe' "$CASE_DIR/action-stderr"
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
test -e "$CASE_DIR/semantic-runtime-called"
semantic_assessment="$ADOC_RETAINED_DIR/semantic-assessment-$ADOC_INVOCATION_ID.json"
semantic_receipt="$ADOC_RETAINED_DIR/semantic-executor-$ADOC_INVOCATION_ID.json"
semantic_context_binding="$ADOC_RETAINED_DIR/semantic-context-digest-$ADOC_INVOCATION_ID.txt"
jq -e '
  .schema_version == "adoc.semantic_assessment.v0"
  and .identity == {provider:"claude-code",model:"claude-sonnet-5"}
  and .findings[0].citations == ["billing.refunds","hunk-001"]
  and .findings[0].proposed_disposition == "create_knowledge"
' "$semantic_assessment" >/dev/null
jq -e '
  .schema_version == "adoc.semantic_executor_receipt.v0"
  and .outcome == "completed"
  and .adapter.provider == "claude-code"
  and .adapter.model == "claude-sonnet-5"
' "$semantic_receipt" >/dev/null
test "$(cat "$semantic_context_binding")" \
  = "$(jq -r .context_digest "$semantic_receipt")"
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
  and .semantic_assessment.status == "completed"
  and .semantic_assessment.primary == {
    request_id:"inv_1_1_semantic_0123456789abcdef0123456789abcdef-primary",
    provider:"claude-code",model:"claude-sonnet-5",outcome:"completed",
    failure_code:null
  }
  and .semantic_review.schema_version == "adoc.semantic_review.v0"
  and (.semantic_review.sha256 | startswith("sha256:"))
' "$ADOC_RETAINED_DIR/receipt-$ADOC_INVOCATION_ID.json" >/dev/null
test "$(sed -n 's/^semantic-assessment-status=//p' "$GITHUB_OUTPUT" | tail -n 1)" = completed
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

# The same validated fallback evidence is durable in the receipt and report;
# only the winning provider must match the completed executor receipt.
assessment_digest="sha256:$(sha256sum "$semantic_assessment" | awk '{print $1}')"
jq -n --arg digest "$assessment_digest" '{
  status:"fell_back",
  failure_code:null,
  assessment_sha256:$digest,
  primary:{request_id:"primary-codex",provider:"codex",model:"gpt-5.6-codex",
    outcome:"failed",failure_code:"provider_timeout"},
  fallback:{request_id:"inv_1_1_semantic_0123456789abcdef0123456789abcdef-primary",
    provider:"claude-code",model:"claude-sonnet-5",outcome:"completed",failure_code:null}
}' > "$ADOC_RUN_DIR/semantic-execution-status.json"
jq '.fallback.request_id = "wrong-request"' \
  "$ADOC_RUN_DIR/semantic-execution-status.json" \
  > "$ADOC_RUN_DIR/semantic-execution-status.next"
mv "$ADOC_RUN_DIR/semantic-execution-status.next" \
  "$ADOC_RUN_DIR/semantic-execution-status.json"
ENFORCEMENT=advisory SCOPE=full SEMANTIC_REVIEW=true PROPOSE=false \
  PROPOSE_ON_ERROR=warn PROPOSE_DELIVERY=comment "$ROOT/scripts/finalize.sh"
jq -e '.semantic_assessment.status == "failed"' \
  "$ADOC_RETAINED_DIR/receipt-$ADOC_INVOCATION_ID.json" >/dev/null
jq '.fallback.request_id = "inv_1_1_semantic_0123456789abcdef0123456789abcdef-primary"' \
  "$ADOC_RUN_DIR/semantic-execution-status.json" \
  > "$ADOC_RUN_DIR/semantic-execution-status.next"
mv "$ADOC_RUN_DIR/semantic-execution-status.next" \
  "$ADOC_RUN_DIR/semantic-execution-status.json"
ENFORCEMENT=advisory SCOPE=full SEMANTIC_REVIEW=true PROPOSE=false \
  PROPOSE_ON_ERROR=warn PROPOSE_DELIVERY=comment "$ROOT/scripts/finalize.sh"
jq -e '.semantic_assessment.status == "fell_back"
  and .semantic_assessment.primary.provider == "codex"
  and .semantic_assessment.fallback.provider == "claude-code"' \
  "$ADOC_RETAINED_DIR/receipt-$ADOC_INVOCATION_ID.json" >/dev/null
REPORT_STYLE=compact ENFORCEMENT=advisory SCOPE=full ADOC_VERSION=v0.3.4 \
  SEMANTIC_REVIEW=true PROPOSE=false PROPOSE_DELIVERY=comment \
  "$ROOT/scripts/compose.sh"
grep -Fq 'Completed through the configured fallback' "$ADOC_RUN_DIR/report.md"

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
  local name="$1" semantic="$2" propose="$3" mode="$4" private config_sha
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
  if [ "${ADOC_TRUSTED_PHASE:-false}" = true ]; then
    config_sha="sha256:$(jq -cn --arg timeout "${PROVIDER_TIMEOUT_SECONDS:-600}" \
      '{adapter:"claude_code",endpoint_class:"public_provider",endpoint_id:"anthropic",
        timeout_seconds:($timeout|tonumber),network:true,tools:[]}' \
      | sha256sum | awk '{print $1}')"
    jq -n --arg qualification \
      "${TEST_TRUSTED_AUTHORIZED_QUALIFICATION_ID:-50000000-0000-0000-0000-000000000408}" \
      --arg model "${TEST_TRUSTED_EXECUTOR_MODEL:-claude-sonnet-5}" \
      --arg config "$config_sha" '{
      state:"authorized",executor:{qualification_id:$qualification,
        provider:"claude-code",model:$model,config_digest:$config}
    }' > "$private/trusted-phase-status.json"
    export ADOC_TRUSTED_EXECUTOR_QUALIFICATION_ID="${TEST_TRUSTED_EXECUTOR_QUALIFICATION_ID:-50000000-0000-0000-0000-000000000408}"
    export ADOC_TRUSTED_ASSESSMENT_DIGEST="${TEST_TRUSTED_ASSESSMENT_DIGEST:-$assessment_sha}"
    export ADOC_TRUSTED_AUTHORIZED_PATHS_PATH="$private/trusted-authorized-paths.json"
    export ADOC_TRUSTED_AUTHORIZATION_EXPIRES_AT="${TEST_TRUSTED_EXPIRES_AT:-2099-08-26T12:00:00Z}"
    printf '%s\n' "${TEST_TRUSTED_AUTHORIZED_PATHS:-[\"docs/index.adoc\",\"src/reconcile.rs\",\"src/refunds.rs\"]}" \
      > "$ADOC_TRUSTED_AUTHORIZED_PATHS_PATH"
  fi
  (cd "$CASE_DIR/repo" && "$ROOT/scripts/semantic-review.sh" \
    "$ROOT/test/mock-claude-semantic.sh")
}

rm -f "$RUNNER_TEMP/provider-calls"
export ADOC_TRUSTED_PHASE=true \
  TEST_TRUSTED_AUTHORIZED_QUALIFICATION_ID=50000000-0000-0000-0000-000000000409
combination_case trusted-qualification-mismatch true false semantic-only
jq -e '.status == "error" and .reason == "policy_ineligible"' \
  "$ADOC_RUN_DIR/semantic-status.json" >/dev/null
test ! -e "$ADOC_RUN_DIR/provider-calls"
unset TEST_TRUSTED_AUTHORIZED_QUALIFICATION_ID
export ADOC_TRUSTED_PHASE=true TEST_TRUSTED_EXECUTOR_MODEL=another-model
combination_case trusted-executor-mismatch true false semantic-only
jq -e '.status == "error" and .reason == "policy_ineligible"' \
  "$ADOC_RUN_DIR/semantic-status.json" >/dev/null
test ! -e "$ADOC_RUN_DIR/provider-calls"
unset TEST_TRUSTED_EXECUTOR_MODEL
TEST_TRUSTED_ASSESSMENT_DIGEST="sha256:$(printf 'f%.0s' {1..64})"
export TEST_TRUSTED_ASSESSMENT_DIGEST
combination_case trusted-assessment-mismatch true false semantic-only
jq -e '.status == "error" and .reason == "policy_ineligible"' \
  "$ADOC_RUN_DIR/semantic-status.json" >/dev/null
test ! -e "$ADOC_RUN_DIR/provider-calls"
unset TEST_TRUSTED_ASSESSMENT_DIGEST
export TEST_TRUSTED_AUTHORIZED_PATHS='["src/reconcile.rs","src/refunds.rs"]'
combination_case trusted-context-mismatch true false semantic-only
jq -e '.status == "error" and .reason == "policy_ineligible"' \
  "$ADOC_RUN_DIR/semantic-status.json" >/dev/null
test ! -e "$ADOC_RUN_DIR/provider-calls"
unset TEST_TRUSTED_AUTHORIZED_PATHS
combination_case trusted-authorized true false semantic-only
jq -e '.status == "complete"' "$ADOC_RUN_DIR/semantic-status.json" >/dev/null
jq -e 'any(.items[];
  .handle.kind == "knowledge_object" and .handle.object_id == "billing.lexical")' \
  "$CASE_DIR/semantic-context-input.json" >/dev/null
test -e "$ADOC_RUN_DIR/provider-calls"
rm "$ADOC_RUN_DIR/provider-calls"
TEST_TRUSTED_OBSERVED_HEAD="$(printf 'f%.0s' {1..40})"
export TEST_TRUSTED_OBSERVED_HEAD
combination_case trusted-stale-head true false semantic-only
unset TEST_TRUSTED_OBSERVED_HEAD
jq -e '.status == "error" and .reason == "policy_ineligible"' \
  "$ADOC_RUN_DIR/semantic-status.json" >/dev/null
test ! -e "$ADOC_RUN_DIR/provider-calls"
jq -e '.state == "expired_after_head_change"
  and .reason_code == "trusted.head_changed"' \
  "$ADOC_RUN_DIR/trusted-phase-status.json" >/dev/null
export TEST_TRUSTED_EXPIRES_AT=2000-01-01T00:00:00Z
combination_case trusted-expired true false semantic-only
jq -e '.status == "error" and .reason == "policy_ineligible"' \
  "$ADOC_RUN_DIR/semantic-status.json" >/dev/null
test ! -e "$ADOC_RUN_DIR/provider-calls"
jq -e '.state == "failed" and .reason_code == "trusted.authorization_expired"' \
  "$ADOC_RUN_DIR/trusted-phase-status.json" >/dev/null
unset TEST_TRUSTED_EXPIRES_AT
export TEST_TRUSTED_EXPIRES_AT=2099-02-30T12:00:00Z
combination_case trusted-impossible-expiry true false semantic-only
jq -e '.status == "error" and .reason == "policy_ineligible"' \
  "$ADOC_RUN_DIR/semantic-status.json" >/dev/null
test ! -e "$ADOC_RUN_DIR/provider-calls"
jq -e '.state == "failed" and .reason_code == "trusted.authorization_expired"' \
  "$ADOC_RUN_DIR/trusted-phase-status.json" >/dev/null
unset TEST_TRUSTED_EXPIRES_AT
combination_case trusted-proposal true true valid
jq -e '.status == "complete"' "$ADOC_RUN_DIR/semantic-status.json" >/dev/null
jq -e '(.placement_allowlist | map(.path)) == ["docs/index.adoc"]' \
  "$ADOC_RUN_DIR/provider-manifest.json" >/dev/null
combination_case trusted-unauthorized-placement true true unauthorized-placement
jq -e '.status == "error" and .reason == "provider_contract_failed"' \
  "$ADOC_RUN_DIR/semantic-status.json" >/dev/null
test ! -e "$ADOC_RETAINED_DIR/semantic-$ADOC_INVOCATION_ID.json"
export ADOC_TRUSTED_PHASE=false

combination_case semantic-only true false semantic-only
jq -e '.status == "complete"' "$ADOC_RUN_DIR/semantic-status.json" >/dev/null
jq -e 'length == 0' "$ADOC_RUN_DIR/proposal-candidates.json" >/dev/null
test -f "$ADOC_RETAINED_DIR/semantic-$ADOC_INVOCATION_ID.json"
cmp "$CASE_DIR/graph.json" \
  "$ADOC_RETAINED_DIR/knowledge-graph-$ADOC_INVOCATION_ID.json"
cmp "$CASE_DIR/semantic-context-output.json" \
  "$ADOC_RETAINED_DIR/semantic-context-$ADOC_INVOCATION_ID.json"

export ADOC_PROPOSE_ELIGIBLE=false ADOC_SEMANTIC_ELIGIBLE=true
combination_case isolated-semantic true false semantic-only
jq -e '.status == "complete"' "$ADOC_RUN_DIR/semantic-status.json" >/dev/null
test -f "$ADOC_RETAINED_DIR/knowledge-graph-$ADOC_INVOCATION_ID.json"
test -f "$ADOC_RETAINED_DIR/semantic-context-$ADOC_INVOCATION_ID.json"
test -f "$ADOC_RETAINED_DIR/semantic-assessment-$ADOC_INVOCATION_ID.json"
export ADOC_PROPOSE_ELIGIBLE=true
unset ADOC_SEMANTIC_ELIGIBLE

combination_case no-proposal true true no-proposal
jq -e '.findings[0].proposed_disposition == "needs_human_review"' \
  "$ADOC_RETAINED_DIR/semantic-assessment-$ADOC_INVOCATION_ID.json" >/dev/null
jq -e 'length == 0' "$ADOC_RUN_DIR/proposal-candidates.json" >/dev/null

combination_case multiline-rationale true true multiline-rationale
jq -e '.findings[0].explanation
  == "The changed behavior extends the cited claim."' \
  "$ADOC_RETAINED_DIR/semantic-assessment-$ADOC_INVOCATION_ID.json" >/dev/null

export MOCK_SEMANTIC_RUNTIME=false
combination_case legacy-runtime false true valid
jq -e '.status == "disabled" and .reason == "input_disabled"' \
  "$ADOC_RUN_DIR/semantic-status.json" >/dev/null
jq -e '.status == "skipped"' "$ADOC_RUN_DIR/semantic-execution-status.json" >/dev/null
jq -e 'length == 1' "$ADOC_RUN_DIR/proposal-candidates.json" >/dev/null
test ! -e "$ADOC_RETAINED_DIR/semantic-assessment-$ADOC_INVOCATION_ID.json"
test ! -e "$ADOC_RETAINED_DIR/semantic-executor-$ADOC_INVOCATION_ID.json"
test ! -e "$ADOC_RETAINED_DIR/semantic-context-digest-$ADOC_INVOCATION_ID.txt"
test ! -e "$ADOC_RETAINED_DIR/semantic-context-$ADOC_INVOCATION_ID.json"
test ! -e "$ADOC_RETAINED_DIR/knowledge-graph-$ADOC_INVOCATION_ID.json"

combination_case legacy-semantic-review true false semantic-only
jq -e '.status == "complete"' "$ADOC_RUN_DIR/semantic-status.json" >/dev/null
jq -e '.status == "failed" and .primary == null and .fallback == null' \
  "$ADOC_RUN_DIR/semantic-execution-status.json" >/dev/null
export MOCK_SEMANTIC_RUNTIME=true

for invalid_assessment in unknown-scope out-of-scope-citation \
  fabricated-affected-object stale-affected-object-hash; do
  export MOCK_VALIDATED_ASSESSMENT="$invalid_assessment"
  combination_case "$invalid_assessment" true true valid
  jq -e '.status == "error" and .reason == "provider_contract_failed"' \
    "$ADOC_RUN_DIR/semantic-status.json" >/dev/null
  test "$(cat "$ADOC_RUN_DIR/adoc-semantic-code")" = 1
  test ! -e "$ADOC_RETAINED_DIR/semantic-assessment-$ADOC_INVOCATION_ID.json"
  test ! -e "$ADOC_RETAINED_DIR/semantic-context-digest-$ADOC_INVOCATION_ID.txt"
  test ! -e "$ADOC_RETAINED_DIR/semantic-context-$ADOC_INVOCATION_ID.json"
  test ! -e "$ADOC_RETAINED_DIR/knowledge-graph-$ADOC_INVOCATION_ID.json"
done
unset MOCK_VALIDATED_ASSESSMENT

combination_case proposal-only false true valid
jq -e '.status == "disabled" and .reason == "input_disabled"' \
  "$ADOC_RUN_DIR/semantic-status.json" >/dev/null
jq -e '.status == "completed" and .assessment_sha256 != null' \
  "$ADOC_RUN_DIR/semantic-execution-status.json" >/dev/null
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

export PROPOSE_MAX_PATHS=1 PROPOSE_COVERAGE=bounded
combination_case bounded-truncation true true valid
jq -e '.bounded_diff == {
    sha256:.bounded_diff.sha256,bytes:.bounded_diff.bytes,
    selected_paths:1,omitted_paths:1,selected_hunks:1,omitted_hunks:0,truncated:true
  }' "$ADOC_RUN_DIR/provider-manifest.json" >/dev/null
jq -e '.unavailability == []' "$CASE_DIR/semantic-context-input.json" >/dev/null

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
jq -e '.requested.bootstrap == true
  and .review_paths == ["src/reconcile.rs"]' \
  "$ADOC_RUN_DIR/provider-manifest.json" >/dev/null
export BOOTSTRAP=false
export PROPOSE_MAX_PATHS=10 PROPOSE_COVERAGE=bounded

combination_case disabled false false valid
jq -e '.status == "disabled" and .reason == "input_disabled"' \
  "$ADOC_RUN_DIR/semantic-status.json" >/dev/null
test ! -e "$ADOC_RUN_DIR/provider-calls"
test ! -e "$ADOC_RUN_DIR/proposal-candidates.json"

export ADOC_PROPOSE_ELIGIBLE=false
combination_case untrusted true true valid
jq -e '.status == "skipped" and .reason == "untrusted_pr"' \
  "$ADOC_RUN_DIR/semantic-status.json" >/dev/null
jq -e '.status == "skipped" and .primary == null and .fallback == null' \
  "$ADOC_RUN_DIR/semantic-execution-status.json" >/dev/null
test "$(cat "$ADOC_RUN_DIR/adoc-semantic-code")" = 0
export ADOC_PROPOSE_ELIGIBLE=true

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
invalid_case ineligible-proposal
invalid_case multiline-headline
invalid_case long-headline

combination_case timeout true true timeout
jq -e '.status == "error" and .reason == "provider_timeout"' \
  "$ADOC_RUN_DIR/semantic-status.json" >/dev/null

combination_case proposal-only-timeout false true timeout
jq -e '.status == "disabled" and .reason == "input_disabled"' \
  "$ADOC_RUN_DIR/semantic-status.json" >/dev/null
jq -e '.status == "skipped"' "$ADOC_RUN_DIR/semantic-execution-status.json" >/dev/null
test "$(cat "$ADOC_RUN_DIR/adoc-semantic-code")" = 0

combination_case oversized-output true true oversized-output
jq -e '.status == "error" and .reason == "provider_output_too_large"' \
  "$ADOC_RUN_DIR/semantic-status.json" >/dev/null

echo 'cited semantic review tests passed'
