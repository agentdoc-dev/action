#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CASE_DIR="$(mktemp -d)"
trap 'rm -rf "$CASE_DIR"' EXIT
mkdir -p "$CASE_DIR/workspace/docs" "$CASE_DIR/runner"

cat > "$CASE_DIR/event.json" <<'EOF'
{
  "action": "opened",
  "repository": {"full_name": "agentdoc/test"},
  "pull_request": {
    "head": {"repo": {"full_name": "agentdoc/test"}},
    "user": {"login": "alice"}
  },
  "sender": {"login": "alice"}
}
EOF

preflight() {
  local env_file="$CASE_DIR/github-env"
  : > "$env_file"
  env \
    GITHUB_ENV="$env_file" \
    GITHUB_EVENT_NAME="${GITHUB_EVENT_NAME:-pull_request}" \
    GITHUB_EVENT_PATH="$CASE_DIR/event.json" \
    GITHUB_WORKSPACE="$CASE_DIR/workspace" \
    RUNNER_TEMP="$CASE_DIR/runner" \
    INPUT_ENFORCEMENT="${INPUT_ENFORCEMENT:-advisory}" \
    INPUT_SCOPE="${INPUT_SCOPE:-full}" \
    INPUT_REPORT_STYLE="${INPUT_REPORT_STYLE:-compact}" \
    INPUT_ADOC_VERSION="${INPUT_ADOC_VERSION:-v0.2.0}" \
    INPUT_WORKING_DIRECTORY="${INPUT_WORKING_DIRECTORY:-docs}" \
    INPUT_COMMENT="${INPUT_COMMENT:-true}" \
    INPUT_PROPOSE="${INPUT_PROPOSE:-true}" \
    INPUT_PROPOSE_PROVIDER="${INPUT_PROPOSE_PROVIDER:-claude-code}" \
    INPUT_PROPOSE_DELIVERY="${INPUT_PROPOSE_DELIVERY:-comment}" \
    INPUT_PROPOSE_ON_ERROR="${INPUT_PROPOSE_ON_ERROR:-warn}" \
    INPUT_PROPOSE_MAX_PATHS="${INPUT_PROPOSE_MAX_PATHS:-10}" \
    INPUT_MODEL="${INPUT_MODEL:-claude-sonnet-5}" \
    INPUT_CLAUDE_CODE_VERSION="${INPUT_CLAUDE_CODE_VERSION:-2.1.215}" \
    "$ROOT/scripts/preflight.sh" || return
  cp "$env_file" "$CASE_DIR/github-env.last"
}

preflight
grep -q '^ADOC_WORKING_DIRECTORY=.*/workspace/docs$' "$CASE_DIR/github-env.last"
grep -q '^ADOC_PROPOSE_ELIGIBLE=true$' "$CASE_DIR/github-env.last"
run_one="$(sed -n 's/^ADOC_RUN_DIR=//p' "$CASE_DIR/github-env.last")"
test -d "$run_one"

preflight
run_two="$(sed -n 's/^ADOC_RUN_DIR=//p' "$CASE_DIR/github-env.last")"
test "$run_one" != "$run_two"

for action in opened synchronize reopened ready_for_review; do
  jq --arg action "$action" '.action = $action' "$CASE_DIR/event.json" > "$CASE_DIR/next.json"
  mv "$CASE_DIR/next.json" "$CASE_DIR/event.json"
  preflight
done

jq '.action = "closed"' "$CASE_DIR/event.json" > "$CASE_DIR/next.json"
mv "$CASE_DIR/next.json" "$CASE_DIR/event.json"
if preflight 2> "$CASE_DIR/error"; then
  echo 'closed PR activity unexpectedly passed preflight' >&2
  exit 1
fi
grep -q 'action.unsupported_event' "$CASE_DIR/error"

jq '.action = "opened" | .pull_request.head.repo.full_name = "fork/test"' \
  "$CASE_DIR/event.json" > "$CASE_DIR/next.json"
mv "$CASE_DIR/next.json" "$CASE_DIR/event.json"
preflight
grep -q '^ADOC_PROPOSE_ELIGIBLE=false$' "$CASE_DIR/github-env.last"

jq '.pull_request.head.repo.full_name = "agentdoc/test" | .sender.login = "dependabot[bot]"' \
  "$CASE_DIR/event.json" > "$CASE_DIR/next.json"
mv "$CASE_DIR/next.json" "$CASE_DIR/event.json"
preflight
grep -q '^ADOC_PROPOSE_ELIGIBLE=false$' "$CASE_DIR/github-env.last"

expect_reject() {
  local name="$1" value="$2"
  if (export "$name=$value"; preflight) 2> "$CASE_DIR/error"; then
    echo "$name=$value unexpectedly passed preflight" >&2
    exit 1
  fi
  grep -Eq 'action\.(invalid_input|unsupported_event)' "$CASE_DIR/error"
}

expect_reject GITHUB_EVENT_NAME push
expect_reject INPUT_ENFORCEMENT maybe
expect_reject INPUT_COMMENT TRUE
expect_reject INPUT_PROPOSE_MAX_PATHS 0
expect_reject INPUT_PROPOSE_MAX_PATHS 51
expect_reject INPUT_MODEL 'bad model'
expect_reject INPUT_CLAUDE_CODE_VERSION latest
expect_reject INPUT_WORKING_DIRECTORY ../outside

echo 'proposal security tests passed'
