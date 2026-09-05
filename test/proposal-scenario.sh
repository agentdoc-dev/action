#!/usr/bin/env bash
# Shared canonical-proposal scenario: exact-head fixture build, proposal
# context, candidates, and the propose.sh runner. Sourced by test scripts.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if [ -z "${ADOC_BIN:-}" ]; then
  ADOC_BIN="$(cd "$ROOT/../adoc" && pwd)/target/debug/adoc"
fi
CASE_DIR="$(mktemp -d)"
if [ "${KEEP_CASE:-false}" = true ]; then
  trap 'printf "case retained: %s\ncloud bundle retained: %s/cloud-bundle\n" "$CASE_DIR" "$CASE_DIR"' EXIT
else
  trap 'rm -rf "$CASE_DIR"' EXIT
fi
mkdir -p "$CASE_DIR/bin" "$CASE_DIR/out" "$CASE_DIR/initial"
ln -s "$ADOC_BIN" "$CASE_DIR/bin/adoc"

fixture="$ROOT/test/fixture-clean"
head="$(git -C "$ROOT" rev-parse HEAD)"
comparison_base="$(git -C "$ROOT" rev-parse HEAD^)"
date=2026-07-23
(cd "$fixture" && "$CASE_DIR/bin/adoc" build --as-of "$date" \
  --no-embeddings --out "$CASE_DIR/initial" >/dev/null)
graph="$CASE_DIR/initial/docs.graph.json"
graph_sha="sha256:$(sha256sum "$graph" | awk '{print $1}')"
jq -c '[.nodes[] | select(.type == "knowledge_object") | {id,content_hash}] | sort_by(.id)' \
  "$graph" | tr -d '\n' > "$CASE_DIR/object-set.json"
object_sha="sha256:$(sha256sum "$CASE_DIR/object-set.json" | awk '{print $1}')"
assessment="$CASE_DIR/initial/assessment.json"
semantic_context_source="$CASE_DIR/initial/semantic-context.json"
assessment_sha="sha256:$(printf 'a%.0s' {1..64})"
# shellcheck disable=SC2034 # consumed by scripts sourcing this scenario
context_digest="sha256:$(printf 'c%.0s' {1..64})"
if [ "${TEST_CLOUD_EVIDENCE:-false}" = true ]; then
  (cd "$fixture" && "$CASE_DIR/bin/adoc" assess-changes \
    --base "$comparison_base" --head "$head" --as-of "$date" --format json \
    > "$assessment")
  assessment_sha="sha256:$(sha256sum "$assessment" | awk '{print $1}')"
  jq -e --arg base "$comparison_base" --arg head "$head" --arg graph "$graph_sha" '
    .schema_version == "adoc.change_assessment.v0"
    and .completeness == "complete"
    and .snapshots.comparison_base.resolved_commit == $base
    and .snapshots.head.resolved_commit == $head
    and .knowledge_snapshot.graph_schema_version == "adoc.graph.v6"
    and .knowledge_snapshot.graph_sha256 == $graph
  ' "$assessment" >/dev/null
  jq -n --arg date "$date" --arg base "$comparison_base" --arg head "$head" \
    --arg assessment "$assessment_sha" --arg graph "$graph_sha" \
    --arg scope "repo:agentdoc-dev/action" --argjson knowledge "$(jq -c '[
      .nodes[] | select(.id == "fixture.ci.green" or .id == "fixture.ci.conflict")
    ]' "$graph")" '{
      schema_version:"adoc.semantic_context_input.v0",evaluation_date:$date,
      subject_revision:{system:"git",value:$head},
      source_revision:{system:"git",value:$head},
      base_revision:{system:"git",value:$base},
      head_revision:{system:"git",value:$head},
      basis:{assessment_digest:$assessment,
        knowledge_basis:{kind:"graph_artifact",digest:$graph}},
      selection:{algorithm:"action-proposal-fixture",version:"1",
        authorized_scope:[$scope]},
      capability_policy:{version:"semantic-context-policy-v1",rules:[
        {reason:"permission",outcome:"insufficient"},
        {reason:"retention",outcome:"insufficient"},
        {reason:"source_outage",outcome:"failed"},
        {reason:"truncation",outcome:"insufficient"},
        {reason:"resource_limit",outcome:"insufficient"}
      ]},
      context_classes:[{class_id:"changed_knowledge",requirement:"required",
        byte_budget:1048576}],
      items:[$knowledge[] | {
        handle_id:.id,class_id:"changed_knowledge",scope_ref:$scope,
        handle:{kind:"knowledge_object",object_id:.id,semantic_hash:.content_hash},
        content:{body,fields,status,effective_status,source_span},truncated:false
      }],
      unavailability:[]
    }' > "$CASE_DIR/initial/semantic-context-input.json"
  "$CASE_DIR/bin/adoc" semantic-context \
    --input "$CASE_DIR/initial/semantic-context-input.json" \
    --out "$semantic_context_source" >/dev/null
  # shellcheck disable=SC2034 # consumed by scripts sourcing this scenario
  context_digest="$(jq -r .context_digest "$semantic_context_source")"
fi

jq -n --arg base "$comparison_base" --arg head "$head" \
  --arg assessment "$assessment_sha" --arg graph "$graph_sha" --arg objects "$object_sha" \
  --arg date "$date" --argjson knowledge "$(jq -c '[
    .nodes[] | select(.id == "fixture.ci.green" or .id == "fixture.ci.conflict") | {
      id,kind,content_hash,status,effective_status,body,fields,
      impacts:(.impacts // []),relations,page_id,
      source_span,contradiction_claims:(.contradiction_claims // [])
    }]' "$graph")" '{
    assessment_sha256:$assessment,
    revisions:{comparison_base:$base,head:$head},
    evaluation_date:$date,
    graph_sha256:$graph,
    object_set_sha256:$objects,
    placement_allowlist:[{
      page_id:"fixture.kb",
      path:"index.adoc",
      anchors:["fixture.ci.green"]
    }],
    policies:{authority:"downgrade",contradictions:"suggest",delivery:"partial"},
    bootstrap:{enabled:false,selected_paths:[]},
    knowledge_objects:$knowledge,
    provider:{
      name:"claude-code",
      model:"claude-sonnet-5",
      provider_version:"2.1.215",
      package_integrity:("sha512:" + ("b" * 128))
    },
    action_ref:"v2.0.0-alpha.2"
  }' > "$CASE_DIR/out/proposal-context.json"

write_candidates() {
  jq -n --arg existing_hash "$(jq -r '
    .nodes[] | select(.id == "fixture.ci.green") | .content_hash
  ' "$graph")" --arg contradiction_hash "$(jq -r '
    .nodes[] | select(.id == "fixture.ci.conflict") | .content_hash
  ' "$graph")" '[
    {
      finding_id:"finding-001",classification:"extends_existing_knowledge",
      proposal_expected:true,rejection_reason:null,kind:"claim",
      target:"fixture.proposed.claim",status:"draft",
      body:"A canonical & safe claim draft.",fields:{impacts:"[src/new.rs]"},
      placement:{page_id:"fixture.kb",after:"fixture.ci.green"}
    },
    {
      finding_id:"finding-001",classification:"extends_existing_knowledge",
      proposal_expected:true,rejection_reason:null,kind:"decision",
      target:"fixture.proposed.decision",status:"proposed",
      body:"A decision remains proposed until human acceptance.",fields:{},
      placement:{page_id:"fixture.kb"}
    },
    {
      finding_id:"finding-001",classification:"extends_existing_knowledge",
      proposal_expected:true,rejection_reason:null,kind:"api",
      target:"fixture.proposed.api",status:"draft",
      body:"The fixture exposes a health endpoint.",
      fields:{method:"GET",path:"/health"},
      placement:{page_id:"fixture.kb"}
    },
    {
      finding_id:"finding-001",classification:"extends_existing_knowledge",
      proposal_expected:true,rejection_reason:null,kind:"task",
      target:"fixture.proposed.task",status:"open",
      body:"Document the new fixture behavior.",fields:{owner:"docs"},
      placement:{page_id:"fixture.kb"}
    },
    {
      finding_id:"finding-002",classification:"extends_existing_knowledge",
      proposal_expected:true,rejection_reason:null,kind:"claim",
      target:"fixture.rejected.authority",status:"verified",
      body:"Must not become authoritative.",fields:{},
      placement:{page_id:"fixture.kb"}
    },
    {
      finding_id:"finding-003",classification:"extends_existing_knowledge",
      proposal_expected:true,rejection_reason:null,kind:"claim",
      target:"fixture.rejected.field",status:"draft",
      body:"Must not carry review authority.",fields:{reviewed_by:"model"},
      placement:{page_id:"fixture.kb"}
    },
    {
      finding_id:"finding-004",classification:"extends_existing_knowledge",
      proposal_expected:true,rejection_reason:null,kind:"claim",
      target:"fixture.rejected.placement",status:"draft",
      body:"Must not invent placement.",fields:{},
      placement:{page_id:"invented.page"}
    },
    {
      finding_id:"finding-005",classification:"contradicts_existing_knowledge",
      proposal_expected:true,rejection_reason:null,kind:"claim",
      target:"fixture.rejected.classification",status:"draft",
      body:"Contradictions are suggestions only.",fields:{},
      placement:{page_id:"fixture.kb"}
    },
    {
      finding_id:"finding-006",classification:"extends_existing_knowledge",
      proposal_expected:true,rejection_reason:null,kind:"claim",
      target:"fixture.rejected.duplicate",status:"draft",
      body:"First duplicate.",fields:{},
      placement:{page_id:"fixture.kb"}
    },
    {
      finding_id:"finding-007",classification:"extends_existing_knowledge",
      proposal_expected:true,rejection_reason:null,kind:"claim",
      target:"fixture.rejected.duplicate",status:"draft",
      body:"Second duplicate.",fields:{},
      placement:{page_id:"fixture.kb"}
    },
    {
      finding_id:"finding-008",classification:"extends_existing_knowledge",
      proposal_expected:true,rejection_reason:null,
      operation:"update",target:"fixture.ci.green",
      body:"The updated fixture knowledge requires human review.",
      fields:{owner:"docs"},desired_status:"draft",
      knowledge_evidence:[{id:"fixture.ci.green",content_hash:$existing_hash}]
    },
    {
      finding_id:"finding-009",classification:"contradicts_existing_knowledge",
      proposal_expected:true,rejection_reason:null,
      operation:"update",target:"fixture.ci.conflict",
      fields:{},desired_status:"dismissed",
      knowledge_evidence:[{id:"fixture.ci.conflict",content_hash:$contradiction_hash}]
    }
  ]
  | map(
      if has("operation") then .
      else . + {operation:"create",knowledge_evidence:[]} end
    )' > "$CASE_DIR/out/proposal-candidates.json"
}

run_proposals() {
  (cd "$fixture" && env \
    ADOC_RUN_DIR="$CASE_DIR/out" \
    ADOC_PROPOSE_ELIGIBLE="${TEST_PROPOSE_ELIGIBLE:-true}" \
    ADOC_HEAD="$head" PATH="$CASE_DIR/bin:$PATH" \
    PROPOSE_DELIVERY_POLICY="${TEST_DELIVERY_POLICY:-partial}" \
    PROPOSE_AUTHORITY="${TEST_AUTHORITY:-downgrade}" \
    PROPOSE_CONTRADICTIONS="${TEST_CONTRADICTIONS:-suggest}" \
    "$ROOT/scripts/propose.sh")
}
