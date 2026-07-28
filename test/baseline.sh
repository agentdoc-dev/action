#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CASE_DIR="$(mktemp -d)"
trap 'rm -rf "$CASE_DIR"' EXIT
mkdir -p "$CASE_DIR/bin" "$CASE_DIR/private" "$CASE_DIR/retained"

head=3333333333333333333333333333333333333333
cat > "$CASE_DIR/bin/adoc" <<'EOF'
#!/usr/bin/env bash
jq -n --arg head "$ADOC_HEAD" '{
  schema_version:"adoc.repository_baseline.v0",
  readiness:{ready:false,reason:"uncovered_paths"},
  evaluation_date:"2026-07-28",
  snapshot:{requested_ref:$head,resolved_commit:$head,immutable:true},
  knowledge_snapshot:{status:"available",graph_schema_version:"adoc.graph.v5",
    graph_sha256:("sha256:"+("1"*64)),object_set_sha256:("sha256:"+("2"*64)),docs_path:"docs"},
  assessment_config:{policy:{effective_sha256:("sha256:"+("3"*64))}},
  summary:{changed_paths:2,covered:1,provisional:0,uncovered:1,excluded:0,impacted_objects:1},
  validation:{errors_full:0,errors_changed:0,errors_unchanged:0,errors_unattributed:0,warnings:0},
  paths:{status:"available",value:[
    {path:"covered.rs",classification:"covered",matches:[]},
    {path:"uncovered.rs",classification:"uncovered",matches:[]}
  ]},
  objects:{status:"available",value:[]},
  diagnostics:[]
}'
EOF
chmod +x "$CASE_DIR/bin/adoc"

export PATH="$CASE_DIR/bin:$PATH"
export ADOC_RUN_DIR="$CASE_DIR/private" ADOC_RETAINED_DIR="$CASE_DIR/retained"
export ADOC_INVOCATION_ID=inv_baseline ADOC_HEAD="$head"
export ADOC_EVALUATION_DATE=2026-07-28 GITHUB_ENV="$CASE_DIR/github-env"
printf '%s\n' '{"baseline":"pending"}' > "$ADOC_RUN_DIR/stages.json"

"$ROOT/scripts/baseline.sh"
baseline="$(cat "$ADOC_RUN_DIR/baseline-path")"
jq -e '.schema_version == "adoc.repository_baseline.v0"
  and .readiness.ready == false and .summary.uncovered == 1' "$baseline" >/dev/null
test "sha256:$(sha256sum "$baseline" | awk '{print $1}')" \
  = "$(cat "$ADOC_RUN_DIR/baseline-sha256")"
grep -q '^ADOC_BASELINE_VALID=true$' "$GITHUB_ENV"

echo 'repository baseline tests passed'
