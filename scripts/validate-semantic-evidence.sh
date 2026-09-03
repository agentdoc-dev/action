#!/usr/bin/env bash
# Validates the complete graph/context/assessment evidence set for Cloud upload.
set -euo pipefail

assessment="${1:?assessment path is required}"
receipt="${2:?receipt path is required}"
graph="${3:?graph path is required}"
context="${4:?semantic context path is required}"
semantic="${5:?semantic assessment path is required}"
self="$(cd "$(dirname "$0")" && pwd)"

graph_digest="sha256:$(sha256sum "$graph" | awk '{print $1}')"
semantic_digest="sha256:$(sha256sum "$semantic" | awk '{print $1}')"
assessment_digest="sha256:$(sha256sum "$assessment" | awk '{print $1}')"
context_digest="$(jq -er '.context_digest | select(test("^sha256:[0-9a-f]{64}$"))' \
  "$context")"
base="$(jq -er '.revisions.comparison_base | select(test("^[0-9a-f]{40}$"))' \
  "$receipt")"
head="$(jq -er '.revisions.head | select(test("^[0-9a-f]{40}$"))' "$receipt")"
winning_identity="$(jq -ce '
  if .semantic_assessment.status == "fell_back"
  then .semantic_assessment.fallback else .semantic_assessment.primary end
' "$receipt")"

jq -e --arg graph "$graph_digest" '
  .schema_version == "adoc.change_assessment.v0"
  and .knowledge_snapshot.graph_schema_version == "adoc.graph.v6"
  and .knowledge_snapshot.graph_sha256 == $graph
' "$assessment" >/dev/null
jq -e '.schema_version == "adoc.graph.v6"' "$graph" >/dev/null
jq -e --arg context "$context_digest" --arg assessment "$assessment_digest" \
  --arg graph "$graph_digest" --arg head "$head" '
  .schema_version == "adoc.semantic_context.v0"
  and .context_digest == $context
  and .subject_revision == {system:"git",value:$head}
  and .basis.assessment_digest == $assessment
  and .basis.knowledge_basis == {kind:"graph_artifact",digest:$graph}
' "$context" >/dev/null
jq -e --arg base "$base" --arg head "$head" --arg context "$context_digest" \
  --argjson winner "$winning_identity" \
  -f "$self/semantic-assessment-contract.jq" "$semantic" >/dev/null
jq -e --slurpfile request <(jq '{context:.}' "$context") \
  -f "$self/semantic-assessment-scope.jq" "$semantic" >/dev/null
jq -e --arg graph "$graph_digest" --arg semantic "$semantic_digest" '
  .knowledge_snapshot.graph_schema_version == "adoc.graph.v6"
  and .knowledge_snapshot.graph_sha256 == $graph
  and (.semantic_assessment.status == "completed"
    or .semantic_assessment.status == "fell_back")
  and .semantic_assessment.assessment_sha256 == $semantic
' "$receipt" >/dev/null
