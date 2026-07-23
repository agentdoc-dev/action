#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CASE_DIR="$(mktemp -d)"
trap 'rm -rf "$CASE_DIR"' EXIT
mkdir -p "$CASE_DIR/workspace/docs" "$CASE_DIR/runner"
git -C "$CASE_DIR/workspace" init -q -b main
git -C "$CASE_DIR/workspace" config user.name test
git -C "$CASE_DIR/workspace" config user.email test@example.com
printf '# docs\n' > "$CASE_DIR/workspace/docs/index.adoc"
git -C "$CASE_DIR/workspace" add -A
git -C "$CASE_DIR/workspace" commit -qm base
event_base="$(git -C "$CASE_DIR/workspace" rev-parse HEAD)"
printf 'head\n' > "$CASE_DIR/workspace/head.txt"
git -C "$CASE_DIR/workspace" add head.txt
git -C "$CASE_DIR/workspace" commit -qm head
event_head="$(git -C "$CASE_DIR/workspace" rev-parse HEAD)"
jq -n --arg base "$event_base" --arg head "$event_head" '{
  action:"opened",repository:{full_name:"agentdoc/test"},sender:{login:"alice"},
  pull_request:{
    number:1,base:{sha:$base},
    head:{sha:$head,repo:{full_name:"agentdoc/test"}},
    user:{login:"alice"}
  }
}' > "$CASE_DIR/event.json"

preflight() {
  local env_file="$CASE_DIR/github-env"
  : > "$env_file"
  env \
    GITHUB_ENV="$env_file" \
    GITHUB_EVENT_NAME="${TEST_EVENT_NAME:-pull_request}" \
    GITHUB_EVENT_PATH="$CASE_DIR/event.json" \
    GITHUB_WORKSPACE="$CASE_DIR/workspace" \
    RUNNER_TEMP="$CASE_DIR/runner" \
    INPUT_ENFORCEMENT="${INPUT_ENFORCEMENT:-advisory}" \
    INPUT_SCOPE="${INPUT_SCOPE:-full}" \
    INPUT_REPORT_STYLE="${INPUT_REPORT_STYLE:-compact}" \
    INPUT_ADOC_VERSION="${INPUT_ADOC_VERSION:-v0.3.3}" \
    INPUT_WORKING_DIRECTORY="${INPUT_WORKING_DIRECTORY:-docs}" \
    INPUT_COMMENT="${INPUT_COMMENT:-true}" \
    INPUT_SEMANTIC_REVIEW="${INPUT_SEMANTIC_REVIEW:-false}" \
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
preflight
run_two="$(sed -n 's/^ADOC_RUN_DIR=//p' "$CASE_DIR/github-env.last")"
test "$run_one" != "$run_two"

for action in opened synchronize reopened ready_for_review; do
  jq --arg action "$action" '.action = $action' "$CASE_DIR/event.json" \
    > "$CASE_DIR/next.json"
  mv "$CASE_DIR/next.json" "$CASE_DIR/event.json"
  preflight
done

jq '.action = "closed"' "$CASE_DIR/event.json" > "$CASE_DIR/next.json"
mv "$CASE_DIR/next.json" "$CASE_DIR/event.json"
preflight 2> "$CASE_DIR/error"
grep -q 'action.unsupported_event' "$CASE_DIR/error"
grep -q '^ADOC_PIPELINE_READY=false$' "$CASE_DIR/github-env.last"

jq '.action = "opened" | .pull_request.head.repo.full_name = "fork/test"' \
  "$CASE_DIR/event.json" > "$CASE_DIR/next.json"
mv "$CASE_DIR/next.json" "$CASE_DIR/event.json"
preflight
grep -q '^ADOC_PROPOSE_ELIGIBLE=false$' "$CASE_DIR/github-env.last"

jq '.pull_request.head.repo.full_name = "agentdoc/test"
  | .pull_request.user.login = "dependabot[bot]"' \
  "$CASE_DIR/event.json" > "$CASE_DIR/next.json"
mv "$CASE_DIR/next.json" "$CASE_DIR/event.json"
preflight
grep -q '^ADOC_PROPOSE_ELIGIBLE=false$' "$CASE_DIR/github-env.last"

jq '.pull_request.user.login = "alice" | .sender.login = "dependabot[bot]"' \
  "$CASE_DIR/event.json" > "$CASE_DIR/next.json"
mv "$CASE_DIR/next.json" "$CASE_DIR/event.json"
preflight
grep -q '^ADOC_PROPOSE_ELIGIBLE=false$' "$CASE_DIR/github-env.last"

expect_reject() {
  local name="$1" value="$2"
  (export "$name=$value"; preflight) 2> "$CASE_DIR/error"
  grep -Eq 'action\.(invalid_input|unsupported_event)' "$CASE_DIR/error"
  grep -q '^ADOC_PIPELINE_READY=false$' "$CASE_DIR/github-env.last"
}

expect_reject TEST_EVENT_NAME push
expect_reject TEST_EVENT_NAME pull_request_target
expect_reject INPUT_ENFORCEMENT maybe
expect_reject INPUT_COMMENT TRUE
expect_reject INPUT_SEMANTIC_REVIEW TRUE
expect_reject INPUT_PROPOSE_MAX_PATHS 0
expect_reject INPUT_PROPOSE_MAX_PATHS 51
expect_reject INPUT_MODEL 'bad model'
expect_reject INPUT_CLAUDE_CODE_VERSION latest
expect_reject INPUT_WORKING_DIRECTORY ../outside

mkdir -p "$CASE_DIR/package"
printf '#!/bin/sh\nexit 0\n' > "$CASE_DIR/package/claude"
chmod +x "$CASE_DIR/package/claude"
tar -czf "$CASE_DIR/provider.tgz" -C "$CASE_DIR" package/claude
provider_digest="$(sha512sum "$CASE_DIR/provider.tgz" | awk '{print $1}')"
env -i PATH="/usr/bin:/bin:/sbin" LANG=C LC_ALL=C \
  "$ROOT/scripts/install-provider.sh" 2.1.215 "$CASE_DIR/provider" \
  "$CASE_DIR/provider.tgz" "$provider_digest"
test -x "$CASE_DIR/provider/claude"
jq -e --arg digest "$provider_digest" \
  '.version == "2.1.215" and .sha512 == $digest' \
  "$CASE_DIR/provider-provenance.json" >/dev/null

cp "$CASE_DIR/provider.tgz" "$CASE_DIR/provider-tampered.tgz"
printf x >> "$CASE_DIR/provider-tampered.tgz"
if env -i PATH="/usr/bin:/bin:/sbin" LANG=C LC_ALL=C \
  "$ROOT/scripts/install-provider.sh" 2.1.215 "$CASE_DIR/tampered" \
  "$CASE_DIR/provider-tampered.tgz" "$provider_digest" 2> "$CASE_DIR/error"; then
  echo 'tampered provider archive unexpectedly installed' >&2
  exit 1
fi
grep -q 'action.provider_integrity_failed' "$CASE_DIR/error"

mkdir -p "$CASE_DIR/proposal-skip"
ADOC_RUN_DIR="$CASE_DIR/proposal-skip" ADOC_PROPOSE_ELIGIBLE=false \
  "$ROOT/scripts/propose.sh"
jq -e '.status == "skipped" and .reason == "untrusted_pr"' \
  "$CASE_DIR/proposal-skip/proposal-status.json" >/dev/null

echo 'proposal security tests passed'
