#!/usr/bin/env bash
set -euo pipefail

request="${1:?semantic executor request is required}"
out="${ADOC_RUN_DIR:-${RUNNER_TEMP:?}}"
assessment="$(cat "$out/assessment-path" 2>/dev/null)"
expected="${ADOC_TRUSTED_ASSESSMENT_DIGEST:?}"
authorized="${ADOC_TRUSTED_AUTHORIZED_PATHS_PATH:?}"
graph="${ADOC_TRUSTED_GRAPH_PATH:-$out/trusted-context-graph.json}"
diffs="${ADOC_TRUSTED_DIFF_DIGESTS_PATH:-$out/trusted-diff-digests.ndjson}"
working="${ADOC_WORKING_DIRECTORY:-$(pwd)}"
prefix="$(git -C "$working" rev-parse --show-prefix 2>/dev/null)"

"$(cd "$(dirname "$0")" && pwd)/trusted-authorization-current.sh"

[ -s "$request" ] && [ -s "$assessment" ] && [ -s "$authorized" ] \
  && [ -s "$graph" ] && [ -f "$diffs" ]
[ "sha256:$(sha256sum "$assessment" | awk '{print $1}')" = "$expected" ]

diff_count="$(jq '[.context.items[] | select(.handle.kind == "diff_hunk")] | length' \
  "$request")"
for ((index = 0; index < diff_count; index++)); do
  jq -e --argjson index "$index" '
    [.context.items[] | select(.handle.kind == "diff_hunk")][$index]
    | .content | type == "object" and keys == ["diff"]
    and (.diff | type == "string")
  ' "$request" >/dev/null
  claimed="$(jq -r --argjson index "$index" '
    [.context.items[] | select(.handle.kind == "diff_hunk")][$index].handle.hunk_digest
  ' "$request")"
  actual="sha256:$(jq -j --argjson index "$index" '
    [.context.items[] | select(.handle.kind == "diff_hunk")][$index].content.diff
  ' "$request" | sha256sum | awk '{print $1}')"
  [ "$claimed" = "$actual" ]
done

graph_digest="sha256:$(sha256sum "$graph" | awk '{print $1}')"
jq -e --arg digest "$expected" --arg graph_digest "$graph_digest" \
  --arg prefix "$prefix" \
  --slurpfile assessment "$assessment" --slurpfile graph "$graph" \
  --slurpfile authorized "$authorized" --slurpfile diffs "$diffs" '
  def authorized_path($path):
    ($path | type == "string") and (($authorized[0] | index($path)) != null);
  def authorized_graph_path($path):
    ($path | type == "string") and authorized_path($prefix + $path);
  def bound_object($handle; $bind_hash):
    first(
      $graph[0].nodes[]?
      | select(.type == "knowledge_object" and .id == $handle.object_id)
      | select(authorized_graph_path(.source_span.path))
      | select(($bind_hash | not) or (.content_hash == $handle.semantic_hash))
      | {graph:.});
  .context.basis.assessment_digest == $digest
  and $assessment[0].knowledge_snapshot.graph_sha256 == $graph_digest
  and .context.basis.knowledge_basis == {kind:"graph_artifact",digest:$graph_digest}
  and (.context.items | type == "array")
  and all(.context.items[];
    .handle as $handle
    | if $handle.kind == "diff_hunk" then
        authorized_path($handle.changed_source_id)
        and any($diffs[];
          .path == $handle.changed_source_id and .sha256 == $handle.hunk_digest)
      elif $handle.kind == "knowledge_object" then
        (bound_object($handle; true) // null) as $bound
        | $bound != null and .content == {body:$bound.graph.body}
      elif $handle.kind == "source_binding" then
        (bound_object($handle; false) // null) as $bound
        | $bound != null and ($bound.graph.source_binding | type == "object")
          and .content == $bound.graph.source_binding
      elif $handle.kind == "evidence" then
        (bound_object($handle; false) // null) as $bound
        | $bound != null and ($bound.graph.evidence | type == "array")
          and ($handle.evidence_index | type == "number" and floor == . and . >= 0)
          and .content == $bound.graph.evidence[$handle.evidence_index]
      else false end)
' "$request" >/dev/null
