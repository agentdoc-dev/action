#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CASE_DIR="$(mktemp -d)"
trap 'rm -rf "$CASE_DIR"' EXIT
mkdir -p "$CASE_DIR/bin" "$CASE_DIR/repo/docs" "$CASE_DIR/runner"

git -C "$CASE_DIR/repo" init -q -b main
git -C "$CASE_DIR/repo" config user.name test
git -C "$CASE_DIR/repo" config user.email test@example.com
printf 'version: 1\nmode: strict\ndocs_path: docs\noutputs:\n  dir: dist\nembeddings:\n  provider: none\n' \
  > "$CASE_DIR/repo/agentdoc.config.yaml"
printf '# Knowledge\n' > "$CASE_DIR/repo/docs/index.adoc"
printf 'base\n' > "$CASE_DIR/repo/app.txt"
git -C "$CASE_DIR/repo" add -A
git -C "$CASE_DIR/repo" commit -qm base
base="$(git -C "$CASE_DIR/repo" rev-parse HEAD)"
printf 'head\n' > "$CASE_DIR/repo/app.txt"
git -C "$CASE_DIR/repo" commit -qam head
head="$(git -C "$CASE_DIR/repo" rev-parse HEAD)"

# Model the synthetic merge checkout GitHub normally leaves in the workspace.
git -C "$CASE_DIR/repo" checkout -q -b synthetic "$base"
printf 'synthetic\n' > "$CASE_DIR/repo/merge-only.txt"
git -C "$CASE_DIR/repo" add merge-only.txt
git -C "$CASE_DIR/repo" commit -qm synthetic

jq -n \
  --arg base "$base" --arg head "$head" \
  '{action:"synchronize",repository:{full_name:"agentdoc/test"},sender:{login:"author"},pull_request:{number:7,user:{login:"author"},base:{sha:$base},head:{sha:$head,repo:{full_name:"agentdoc/test"}}}}' \
  > "$CASE_DIR/event.json"

cat > "$CASE_DIR/bin/adoc" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = assess-changes ]; then
  printf '%s\n' "$*" >> "$MOCK_INVOCATIONS"
  base=''; head=''; date=''
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --base) base="$2"; shift 2 ;;
      --head) head="$2"; shift 2 ;;
      --as-of) date="$2"; shift 2 ;;
      *) shift ;;
    esac
  done
  jq -n --arg base "$base" --arg comparison "$MOCK_COMPARISON_BASE" \
    --arg head "$head" --arg date "$date" '{
      schema_version:"adoc.change_assessment.v0",
      completeness:"complete",outcome:"review_required",evaluation_date:$date,
      snapshots:{
        requested_base:{requested_ref:$base,resolved_commit:$base,immutable:true},
        comparison_base:{resolved_commit:$comparison,immutable:true,strategy:"merge_base"},
        head:{requested_ref:$head,resolved_commit:$head,immutable:true}
      },
      knowledge_snapshot:{status:"available",graph_schema_version:"adoc.graph.v5",graph_sha256:("sha256:"+("1"*64)),object_set_sha256:("sha256:"+("2"*64)),docs_path:"docs"},
      assessment_config:{comparison_base:{status:"available",source:"file",docs_path:"docs",sha256:("sha256:"+("3"*64))},head:{status:"available",source:"file",docs_path:"docs",sha256:("sha256:"+("3"*64))},policy:{status:"available",effective_source_snapshot:"comparison_base",exclude_paths:[],generated_outputs:[],effective_sha256:("sha256:"+("4"*64)),proposed_head_sha256:("sha256:"+("4"*64))},sha256:("sha256:"+("5"*64))},
      summary:{changed_paths:1,covered:1,provisional:0,uncovered:0,excluded:0,impacted_objects:1},
      validation:{errors_full:0,errors_changed:0,errors_unchanged:0,errors_unattributed:0,warnings:0},
      paths:{status:"available",value:[{path:"app.txt",classification:"covered",matches:[{object_id:"fixture.knowledge",reason:"impacts_path"}]}]},
      objects:{status:"available",value:[{id:"fixture.knowledge",kind:"claim",content_hash:("sha256:"+("6"*64)),owner:"team",reviewers:[],source:{path:"docs/index.adoc",line:1,column:1},authority:"authoritative",changed_in_pr:"no",reasons:[{path:"app.txt",reason:"impacts_path"}]}]},
      knowledge_changes:{status:"available",value:{created:[],changed:[],deleted:[]}},
      policy_changes:{status:"available",changed:false,changed_fields:[]},
      required_reviewers:[],proof_obligations:[],signals:[],diagnostics:[]
    }'
  exit 0
fi
echo "unexpected adoc command: $*" >&2
exit 99
EOF
chmod +x "$CASE_DIR/bin/adoc"

export PATH="$CASE_DIR/bin:$PATH"
export GITHUB_EVENT_NAME=pull_request GITHUB_EVENT_PATH="$CASE_DIR/event.json"
export GITHUB_WORKSPACE="$CASE_DIR/repo" RUNNER_TEMP="$CASE_DIR/runner"
export GITHUB_ENV="$CASE_DIR/github-env" GITHUB_OUTPUT="$CASE_DIR/github-output"
export GITHUB_RUN_ID=101 GITHUB_RUN_ATTEMPT=2 GITHUB_JOB=agentdoc
export GITHUB_ACTOR=author GITHUB_REPOSITORY=agentdoc/test
export MOCK_COMPARISON_BASE="$base" MOCK_INVOCATIONS="$CASE_DIR/invocations"
export INPUT_ENFORCEMENT=advisory INPUT_SCOPE=full INPUT_REPORT_STYLE=compact
export INPUT_ADOC_VERSION=v0.3.2 INPUT_WORKING_DIRECTORY=.
export INPUT_COMMENT=false INPUT_PROPOSE=false INPUT_PROPOSE_PROVIDER=claude-code
export INPUT_PROPOSE_DELIVERY=comment INPUT_PROPOSE_ON_ERROR=warn
export INPUT_PROPOSE_MAX_PATHS=10 INPUT_MODEL=claude-sonnet-5
export INPUT_CLAUDE_CODE_VERSION=2.1.215

"$ROOT/scripts/preflight.sh"
set -a
source "$GITHUB_ENV"
set +a

[ "$ADOC_REQUESTED_BASE" = "$base" ]
[ "$ADOC_HEAD" = "$head" ]
[ "$ADOC_COMPARISON_BASE" = "$base" ]
[[ "$ADOC_INVOCATION_ID" =~ ^inv_101_2_agentdoc_[0-9a-f]{32}$ ]]

jq -n --arg requested v0.3.2 --arg resolved v0.3.2 \
  '{requested_version:$requested,resolved_version:$resolved,binary_sha256:("sha256:"+("a"*64))}' \
  > "$ADOC_RUN_DIR/adoc-toolchain.json"

(cd "$ADOC_WORKING_DIRECTORY" && "$ROOT/scripts/report.sh")
[ "$(wc -l < "$MOCK_INVOCATIONS" | tr -d ' ')" = 1 ]
grep -q -- "--base $base --head $head" "$MOCK_INVOCATIONS"

ENFORCEMENT=advisory SCOPE=full PROPOSE=false PROPOSE_ON_ERROR=warn \
  PROPOSE_DELIVERY=comment ADOC_ACTION_REF=0123456789012345678901234567890123456789 \
  GITHUB_ACTION_REF=v1 \
  GITHUB_ACTION_REPOSITORY=agentdoc-dev/action "$ROOT/scripts/finalize.sh"

assessment_path="$(sed -n 's/^assessment-path=//p' "$GITHUB_OUTPUT" | tail -n 1)"
receipt_path="$(sed -n 's/^assessment-receipt-path=//p' "$GITHUB_OUTPUT" | tail -n 1)"
[ -f "$assessment_path" ]
[ -f "$receipt_path" ]
test "$(sed -n 's/^assessment-outcome=//p' "$GITHUB_OUTPUT" | tail -n 1)" = review_required
test "$(sed -n 's/^assessment-completeness=//p' "$GITHUB_OUTPUT" | tail -n 1)" = complete
jq -e --arg base "$base" --arg head "$head" '
  .schema_version == "adoc.pr_assessment_receipt.v0"
  and .run_status == "completed"
  and .revisions.requested_base == $base
  and .revisions.comparison_base == $base
  and .revisions.head == $head
  and .conclusion.status == "success"
  and .toolchain.action.provenance == "full_sha"
  and .toolchain.adoc.resolved_version == "v0.3.2"' "$receipt_path" >/dev/null

ENFORCEMENT=advisory SCOPE=full ADOC_VERSION=v0.3.2 "$ROOT/scripts/compose.sh"
grep -q "${base:0:12}" "$ADOC_RUN_DIR/report.md"
grep -q "${head:0:12}" "$ADOC_RUN_DIR/report.md"
grep -q 'review_required' "$ADOC_RUN_DIR/report.md"

cat > "$CASE_DIR/bin/gh" <<'EOF'
#!/usr/bin/env bash
if [ "${2:-}" = "repos/agentdoc/test/pulls/7" ]; then
  echo "$MOCK_CURRENT_HEAD"
  exit 0
fi
for arg in "$@"; do
  case "$arg" in body=@*) cp "${arg#body=@}" "$CASE_DIR/comment-body.md" ;; esac
done
exit 0
EOF
chmod +x "$CASE_DIR/bin/gh"
export CASE_DIR PR_NUMBER=7
export MOCK_CURRENT_HEAD=0000000000000000000000000000000000000000
"$ROOT/scripts/comment.sh"
test ! -e "$CASE_DIR/comment-body.md"
export MOCK_CURRENT_HEAD="$head"
"$ROOT/scripts/comment.sh"
cmp "$ADOC_RUN_DIR/report.md" "$CASE_DIR/comment-body.md"

grep -A5 '^  adoc-version:' "$ROOT/action.yml" | grep -q 'default: v0.3.2'
grep -Fq 'ADOC_ACTION_REF: ${{ github.action_ref }}' "$ROOT/action.yml"
grep -q 'ADOC_VERSION: v0.3.2' "$ROOT/.github/workflows/ci.yml"
grep -q 'ADOC_VERSION: v0.3.2' "$ROOT/.github/workflows/smoke.yml"

echo 'exact-SHA receipt tests passed'
