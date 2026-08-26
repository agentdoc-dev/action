#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CASE_DIR="$(mktemp -d)"
trap 'rm -rf "$CASE_DIR"' EXIT

manifest="$ROOT/connector-capabilities.json"
test -f "$manifest"
jq -e '
  keys == ["adapter","capabilities","overall_stage","publisher","schema_version"]
  and .schema_version == "agentdoc.connector_capabilities.v0"
  and .adapter == {name:"github-action",version:"2.0.0-alpha.20"}
  and .publisher == {id:"agentdoc-dev/action",kind:"agentdoc"}
  and .overall_stage == "Beta"
  and (.capabilities | keys) == [
    "change_request.read",
    "change_request.status_publish",
    "change_request.trusted_assessment",
    "proposal.commit_to_source_branch",
    "proposal.followup_change_request",
    "source.read_exact_revision"
  ]
  and all(.capabilities[];
    keys == ["dependencies","deployment_modes","known_limitations","maturity",
      "processing_modes","qualification_evidence_ref","supported_contract_ranges","version"]
    and .version == "1"
    and (.maturity == "beta" or .maturity == "ga")
    and .processing_modes == ["source_ci"]
    and .deployment_modes == ["github_action"]
    and (.qualification_evidence_ref | type == "string" and length > 0)
  )
  and .capabilities["change_request.trusted_assessment"].maturity == "ga"
  and .capabilities["change_request.trusted_assessment"].dependencies == [{
    name:"source.read_exact_revision",version_range:">=1 <2"
  }]
  and .capabilities["source.read_exact_revision"].dependencies == []
' "$manifest" >/dev/null

GITHUB_ACTION_PATH="$ROOT" GITHUB_OUTPUT="$CASE_DIR/output" \
  "$ROOT/scripts/publish-connector-capabilities.sh"
path="$(sed -n 's/^path=//p' "$CASE_DIR/output")"
digest="$(sed -n 's/^sha256=//p' "$CASE_DIR/output")"
test "$path" = "$manifest"
test "$digest" = "sha256:$(sha256sum "$manifest" | awk '{print $1}')"

grep -Fq 'connector-capability-manifest-path:' "$ROOT/action.yml"
grep -Fq 'connector-capability-manifest-sha256:' "$ROOT/action.yml"

echo 'connector capability manifest tests passed'
