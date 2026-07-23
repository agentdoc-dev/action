#!/usr/bin/env bash
set -euo pipefail

env | sort > "$RUNNER_TEMP/provider-env"
printf '%s\n' "$@" > "$RUNNER_TEMP/provider-args"
printf '%s\n' "$PWD" > "$RUNNER_TEMP/provider-cwd-capture"
printf 'x\n' >> "$RUNNER_TEMP/provider-calls"
cat >/dev/null
mode="$(cat "$RUNNER_TEMP/mock-mode" 2>/dev/null || echo valid)"
jq -nc --arg mode "$mode" --slurpfile manifest "$RUNNER_TEMP/input-manifest.json" '{
  findings: [{
    provider_ref: "local-1",
    classification:(if $mode == "unknown-classification" then "probably_consistent"
      else "extends_existing_knowledge" end),
    code_evidence: [($manifest[0].code_hunks[0] | {
      path:(if $mode == "hallucinated-path" then "src/not-supplied.rs" else .path end),
      hunk_id: .id, old_range, new_range, hunk_sha256: .sha256
    })],
    knowledge_evidence: [($manifest[0].knowledge_objects[0] | {id, content_hash})],
    rationale: "The changed behavior extends the cited claim.",
    proposal_expected: true
  }],
  patch_candidates:(if $mode == "semantic-only" then [] else [{
      finding_ref: "local-1",
      kind: "claim",
      target: "billing.refund-persistence",
      status: "draft",
      body: "Refund persistence failures require durable reconciliation.",
      fields: {impacts:"[src/reconcile.rs]"},
      placement: {page_id:"billing.index",after:"billing.refunds"}
    }] end)
}' | jq -Rs '{type:"result",result:.}'
