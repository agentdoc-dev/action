#!/usr/bin/env bash
# Validates the complete semantic evidence set for Cloud upload.
set -euo pipefail

assessment="${1:?assessment path is required}"
receipt="${2:?receipt path is required}"
graph="${3:?graph path is required}"
context="${4:?semantic context path is required}"
semantic="${5:?semantic assessment path is required}"
executor="${6:?semantic executor receipt path is required}"
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
jq -e --arg context "$context_digest" --arg semantic "$semantic_digest" \
  --argjson winner "$winning_identity" --slurpfile receipt "$receipt" '
  def digest: type == "string" and test("^sha256:[0-9a-f]{64}$");
  def text: type == "string" and test("^\\S(?:.*\\S)?$");
  type == "object"
  and keys == ["adapter","assessment_digest","capability","context_digest",
    "outcome","prompt_digest","request_digest","request_id","schema_version",
    "task_digest"]
  and .schema_version == "adoc.semantic_executor_receipt.v0"
  and .outcome == "completed"
  and (.request_id | text) and (.capability | text)
  and (.request_digest | digest) and (.task_digest | digest)
  and (.prompt_digest | digest) and (.context_digest | digest)
  and (.assessment_digest | digest)
  and (.adapter | type == "object"
    and keys == ["config_digest","endpoint_class","endpoint_id",
      "executor_digest","kind","model","model_digest","provider"]
    and (.kind | IN("claude_code","codex","generic","human"))
    and (.endpoint_class | IN("public_provider","customer_hosted","local","human"))
    and (.provider | text) and (.model | text) and (.endpoint_id | text)
    and (.executor_digest | digest) and (.model_digest | digest)
    and (.config_digest | digest)
    and if .kind == "human" then
      .provider == "human" and .endpoint_class == "human"
    else .provider != "human" and .endpoint_class != "human" end)
  and .assessment_digest == $semantic
  and .context_digest == $context
  and .request_id == $winner.request_id
  and .adapter.provider == $winner.provider
  and .adapter.model == $winner.model
  and ((.adapter.config_digest? // null) as $config
    | ($receipt[0].trusted_phase.executor? // null) as $trusted
    | if $trusted == null then
        $config == null or ($config | test("^sha256:[0-9a-f]{64}$"))
      else
        $trusted.provider == $winner.provider
        and $trusted.model == $winner.model
        and .adapter.config_digest == $trusted.config_digest
      end)
' "$executor" >/dev/null
