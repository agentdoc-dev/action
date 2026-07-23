#!/usr/bin/env bash
# Same-repository CI smoke for the pinned real provider. The token is passed
# only to semantic-review.sh, which launches the provider under env -i.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ADOC_BIN="${ADOC_BIN:?installed AgentDoc binary is required}"
CASE_DIR="$(mktemp -d)"
trap 'rm -rf "$CASE_DIR"' EXIT
mkdir -p "$CASE_DIR/bin" "$CASE_DIR/repo/docs" "$CASE_DIR/repo/src" \
  "$CASE_DIR/runner" "$CASE_DIR/retained"
ln -s "$ADOC_BIN" "$CASE_DIR/bin/adoc"

git -C "$CASE_DIR/repo" init -q -b main
git -C "$CASE_DIR/repo" config user.name test
git -C "$CASE_DIR/repo" config user.email test@example.com
cat > "$CASE_DIR/repo/agentdoc.config.yaml" <<'EOF'
version: 1
mode: strict
docs_path: docs
outputs:
  dir: dist
embeddings:
  provider: none
EOF
cat > "$CASE_DIR/repo/docs/index.adoc" <<'EOF'
# Billing @doc(billing.knowledge)

::claim billing.refunds
status: draft
impacts: [src/refunds.rs]
--
Refund processing records its durable outcome.
::
EOF
printf 'fn refund() {}\n' > "$CASE_DIR/repo/src/refunds.rs"
git -C "$CASE_DIR/repo" add -A
git -C "$CASE_DIR/repo" commit -qm base
base="$(git -C "$CASE_DIR/repo" rev-parse HEAD)"
printf 'fn refund() { persist(); }\n' > "$CASE_DIR/repo/src/refunds.rs"
printf 'fn reconcile() {}\n' > "$CASE_DIR/repo/src/reconcile.rs"
git -C "$CASE_DIR/repo" add -A
git -C "$CASE_DIR/repo" commit -qm head
head="$(git -C "$CASE_DIR/repo" rev-parse HEAD)"

jq -n --arg base "$base" --arg head "$head" '{
  action:"synchronize",
  repository:{full_name:"agentdoc/test"},
  sender:{login:"author"},
  pull_request:{
    number:1,user:{login:"author"},
    base:{sha:$base},
    head:{sha:$head,repo:{full_name:"agentdoc/test"}}
  }
}' > "$CASE_DIR/event.json"

export PATH="$CASE_DIR/bin:$PATH"
export GITHUB_EVENT_NAME=pull_request GITHUB_EVENT_PATH="$CASE_DIR/event.json"
export GITHUB_WORKSPACE="$CASE_DIR/repo" RUNNER_TEMP="$CASE_DIR/runner"
export GITHUB_ENV="$CASE_DIR/github-env" GITHUB_OUTPUT="$CASE_DIR/github-output"
export GITHUB_RUN_ID="${GITHUB_RUN_ID:-1}" GITHUB_RUN_ATTEMPT="${GITHUB_RUN_ATTEMPT:-1}"
export GITHUB_JOB="${GITHUB_JOB:-provider-smoke}" GITHUB_ACTOR=author
export GITHUB_REPOSITORY=agentdoc/test
export INPUT_ENFORCEMENT=advisory INPUT_SCOPE=full INPUT_REPORT_STYLE=compact
export INPUT_ADOC_VERSION=v0.3.3 INPUT_WORKING_DIRECTORY=.
export INPUT_COMMENT=false INPUT_SEMANTIC_REVIEW=true INPUT_PROPOSE=true
export INPUT_PROPOSE_PROVIDER=claude-code INPUT_PROPOSE_DELIVERY=comment
export INPUT_PROPOSE_ON_ERROR=fail INPUT_PROPOSE_MAX_PATHS=10
export INPUT_MODEL=claude-sonnet-5 INPUT_CLAUDE_CODE_VERSION=2.1.215

"$ROOT/scripts/preflight.sh"
set -a
source "$GITHUB_ENV"
set +a
export ADOC_RETAINED_DIR="$CASE_DIR/retained"

version="$(adoc --version | awk '{print $2}')"
binary_sha="sha256:$(sha256sum "$ADOC_BIN" | awk '{print $1}')"
jq -n --arg version "v$version" --arg sha "$binary_sha" '{
  requested_version:"v0.3.3",resolved_version:$version,binary_sha256:$sha
}' > "$ADOC_RUN_DIR/adoc-toolchain.json"

(cd "$ADOC_WORKING_DIRECTORY" && "$ROOT/scripts/report.sh")
"$ROOT/scripts/install-provider.sh" 2.1.215 "$ADOC_RUN_DIR/provider"

(cd "$ADOC_WORKING_DIRECTORY" && env \
  ADOC_RUN_DIR="$ADOC_RUN_DIR" ADOC_RETAINED_DIR="$ADOC_RETAINED_DIR" \
  ADOC_INVOCATION_ID="$ADOC_INVOCATION_ID" ADOC_EVALUATION_DATE="$ADOC_EVALUATION_DATE" \
  ADOC_REQUESTED_BASE="$ADOC_REQUESTED_BASE" ADOC_COMPARISON_BASE="$ADOC_COMPARISON_BASE" \
  ADOC_HEAD="$ADOC_HEAD" ADOC_PROPOSE_ELIGIBLE=true \
  ADOC_PROVIDER_CONTRACT_DIAGNOSTICS=true \
  SEMANTIC_REVIEW=true PROPOSE=true PROPOSE_ON_ERROR=fail PROPOSE_MAX_PATHS=10 \
  MODEL=claude-sonnet-5 INPUT_CLAUDE_CODE_OAUTH_TOKEN="${CLAUDE_CODE_OAUTH_TOKEN:?}" \
  PATH="$PATH" "$ROOT/scripts/semantic-review.sh")

jq -e '.status == "complete" and .schema_version == "adoc.semantic_review.v0"' \
  "$ADOC_RUN_DIR/semantic-status.json" >/dev/null
test "$(cat "$ADOC_RUN_DIR/adoc-semantic-code")" = 0
test -f "$ADOC_RETAINED_DIR/semantic-$ADOC_INVOCATION_ID.json"

(cd "$ADOC_WORKING_DIRECTORY" && env \
  ADOC_RUN_DIR="$ADOC_RUN_DIR" ADOC_PROPOSE_ELIGIBLE=true \
  PROPOSE_ON_ERROR=fail PATH="$PATH" "$ROOT/scripts/propose.sh")
jq -e '.status != "error"' "$ADOC_RUN_DIR/proposal-status.json" >/dev/null

echo 'real provider smoke passed'
