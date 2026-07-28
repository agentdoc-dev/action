#!/usr/bin/env bash
set -euo pipefail

env | sort > "$RUNNER_TEMP/provider-env"
printf '%s\n' "$@" > "$RUNNER_TEMP/provider-args"
printf '%s\n' "$PWD" > "$RUNNER_TEMP/provider-cwd-capture"
printf 'x\n' >> "$RUNNER_TEMP/provider-calls"
cp "$RUNNER_TEMP/input-manifest.json" "$RUNNER_TEMP/provider-manifest.json"
cat >/dev/null
mode="$(cat "$RUNNER_TEMP/mock-mode" 2>/dev/null || echo valid)"
[ "$mode" != timeout ] || exit 124
jq -nc --arg mode "$mode" --slurpfile manifest "$RUNNER_TEMP/input-manifest.json" '
  {
  findings: ([{
    provider_ref: "local-1",
    classification:(if $mode == "unknown-classification" then "probably_consistent"
      else "extends_existing_knowledge" end),
    headline:(if $mode == "multiline-headline" then "Invalid\nheadline"
      elif $mode == "long-headline" then ("x" * 121)
      else "Refund persistence extends the documented workflow." end),
    code_evidence: [($manifest[0].code_hunks[0] | {
      path:(if $mode == "hallucinated-path" then "src/not-supplied.rs" else .path end),
      hunk_id: .id, old_range, new_range, hunk_sha256: .sha256
    })],
    knowledge_evidence: [($manifest[0].knowledge_objects[0] | {id, content_hash})],
    rationale: "The changed behavior extends the cited claim.",
    proposal_expected: true
  }] | if $mode == "multi-extension" then
      . + [.[0] + {
        provider_ref:"local-2",
        headline:"Callback isolation extends the documented workflow."
      }]
    else . end),
  path_dispositions:[
    $manifest[0].review_paths[] | {
      path: .,
      disposition:(if $mode == "semantic-only" then "covered_no_change"
        else "create_knowledge" end),
      finding_refs:["local-1"],
      rationale:"The path was reviewed against the supplied knowledge."
    }
  ],
  patch_candidates:(if $mode == "semantic-only" then [] else ([{
      operation: "create",
      finding_ref: "local-1",
      kind: "claim",
      target: "billing.refund-persistence",
      status: "draft",
      body: "Refund persistence failures require durable reconciliation.",
      fields: {impacts:"[src/reconcile.rs]"},
      placement: {page_id:"billing.index",after:"billing.refunds"}
    }] | if $mode == "multi-extension" then
        . + [.[0] + {
          finding_ref:"local-2",
          target:"billing.refund-callback-isolation",
          body:"Refund callbacks cannot interrupt durable reconciliation."
        }]
      else . end)
    end)
  }
' | jq -cs '{type:"result",structured_output:.[0]}'
