#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ADOC_REPO="${ADOC_REPO:-$(cd "$ROOT/../adoc" && pwd)}"
ADOC_BIN="${ADOC_BIN:-$ADOC_REPO/target/debug/adoc}"
CASE_DIR="$(mktemp -d)"
if [ "${KEEP_CASE:-false}" = true ]; then
  trap 'printf "case retained: %s\n" "$CASE_DIR"' EXIT
else
  trap 'rm -rf "$CASE_DIR"' EXIT
fi
mkdir -p "$CASE_DIR/bin" "$CASE_DIR/out" "$CASE_DIR/initial"
ln -s "$ADOC_BIN" "$CASE_DIR/bin/adoc"

fixture="$ROOT/test/fixture-clean"
head="$(git -C "$ROOT" rev-parse HEAD)"
date=2026-07-23
(cd "$fixture" && "$CASE_DIR/bin/adoc" build --as-of "$date" \
  --no-embeddings --out "$CASE_DIR/initial" >/dev/null)
graph="$CASE_DIR/initial/docs.graph.json"
graph_sha="sha256:$(sha256sum "$graph" | awk '{print $1}')"
jq -c '[.nodes[] | select(.type == "knowledge_object") | {id,content_hash}] | sort_by(.id)' \
  "$graph" | tr -d '\n' > "$CASE_DIR/object-set.json"
object_sha="sha256:$(sha256sum "$CASE_DIR/object-set.json" | awk '{print $1}')"

jq -n --arg head "$head" --arg graph "$graph_sha" --arg objects "$object_sha" \
  --arg date "$date" '{
    assessment_sha256:("sha256:" + ("a" * 64)),
    revisions:{comparison_base:$head,head:$head},
    evaluation_date:$date,
    graph_sha256:$graph,
    object_set_sha256:$objects,
    placement_allowlist:[{
      page_id:"fixture.kb",
      path:"index.adoc",
      anchors:["fixture.ci.green"]
    }],
    provider:{
      name:"claude-code",
      model:"claude-sonnet-5",
      provider_version:"2.1.215",
      package_integrity:("sha512:" + ("b" * 128))
    },
    action_ref:"v2.0.0-alpha.2"
  }' > "$CASE_DIR/out/proposal-context.json"

write_candidates() {
  jq -n '[
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
    }
  ]' > "$CASE_DIR/out/proposal-candidates.json"
}

run_proposals() {
  (cd "$fixture" && env \
    ADOC_RUN_DIR="$CASE_DIR/out" ADOC_PROPOSE_ELIGIBLE=true \
    ADOC_HEAD="$head" PATH="$CASE_DIR/bin:$PATH" \
    "$ROOT/scripts/propose.sh")
}

write_candidates
before="$(git -C "$ROOT" diff -- test/fixture-clean)"
run_proposals
after="$(git -C "$ROOT" diff -- test/fixture-clean)"
test "$before" = "$after"

jq -e '
  .status == "partial"
  and .count == 4
  and (.sha256 | test("^sha256:[0-9a-f]{64}$"))
  and .reason == "some_candidates_rejected"
' "$CASE_DIR/out/proposal-status.json" >/dev/null
test "$(wc -l < "$CASE_DIR/out/patch-manifest.ndjson" | tr -d ' ')" = 4
jq -se '
  map(.target) == [
    "fixture.proposed.api",
    "fixture.proposed.claim",
    "fixture.proposed.decision",
    "fixture.proposed.task"
  ]
  and all(.[];
    .schema_version == "adoc.patch.v0"
    and .operation == "create_object"
    and (.sha256 | test("^sha256:[0-9a-f]{64}$"))
    and (.check_sha256 | test("^sha256:[0-9a-f]{64}$")))
' "$CASE_DIR/out/patch-manifest.ndjson" >/dev/null

while IFS= read -r patch; do
  jq -e '
    .schema_version == "adoc.patch.v0"
    and .op == "create_object"
    and (.base_hash | not)
    and (.reason | test("^AgentDoc assessment sha256:[0-9a-f]{64} finding finding-[0-9]{3}\\.$"))
    and .proposer == {
      type:"agent",
      id:"agentdoc-action/claude-code@2.1.215/claude-sonnet-5"
    }
  ' "$patch" >/dev/null
  test "$(tail -c 1 "$patch" | od -An -tuC | tr -d ' ')" = 10
done < <(jq -r .path "$CASE_DIR/out/patch-manifest.ndjson")

grep -q 'Canonical AgentDoc patches' "$CASE_DIR/out/proposed-drafts.md"
grep -q 'canonical &amp; safe' "$CASE_DIR/out/proposed-drafts.md"
grep -q 'Proof obligations' "$CASE_DIR/out/proposed-drafts.md"
grep -q '6 rejected' "$CASE_DIR/out/proposed-drafts.md"
! grep -q 'canonical & safe' "$CASE_DIR/out/proposed-drafts.md"
first_digest="$(jq -r .sha256 "$CASE_DIR/out/proposal-status.json")"
first_order="$(jq -r .sha256 "$CASE_DIR/out/patch-manifest.ndjson")"

jq 'reverse' "$CASE_DIR/out/proposal-candidates.json" > "$CASE_DIR/reversed.json"
mv "$CASE_DIR/reversed.json" "$CASE_DIR/out/proposal-candidates.json"
run_proposals
test "$(jq -r .sha256 "$CASE_DIR/out/proposal-status.json")" = "$first_digest"
test "$(jq -r .sha256 "$CASE_DIR/out/patch-manifest.ndjson")" = "$first_order"

echo 'canonical proposal tests passed'
