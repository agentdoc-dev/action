#!/usr/bin/env bash
set -euo pipefail

cat >/dev/null
mode="$(cat "$RUNNER_TEMP/mock-mode" 2>/dev/null || echo valid)"
jq -nc --arg mode "$mode" --slurpfile manifest "$RUNNER_TEMP/input-manifest.json" '{
  findings: [{
    classification:(if $mode == "unknown-classification" then "probably_consistent"
      else "extends_existing_knowledge" end),
    code_evidence: [($manifest[0].code_hunks[0] | {
      path:(if $mode == "hallucinated-path" then "src/not-supplied.rs" else .path end),
      hunk_id: .id, old_range, new_range, hunk_sha256: .sha256
    })],
    knowledge_evidence: [($manifest[0].knowledge_objects[0] | {id, content_hash})],
    rationale: "The changed behavior extends the cited claim.",
    proposal_expected: true
  }]
}' | jq -Rs '{type:"result",result:.}'
