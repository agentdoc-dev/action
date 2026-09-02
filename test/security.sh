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
git -C "$CASE_DIR/workspace" update-ref refs/remotes/origin/main "$event_head"
jq -n --arg base "$event_base" --arg head "$event_head" '{
  action:"opened",repository:{full_name:"agentdoc/test",default_branch:"main"},sender:{login:"alice"},
  pull_request:{
    number:1,base:{sha:$base,ref:"main"},
    head:{sha:$head,ref:"feature",repo:{full_name:"agentdoc/test"}},
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
    GITHUB_REPOSITORY=agentdoc/test \
    GITHUB_REPOSITORY_ID="${GITHUB_REPOSITORY_ID-99}" \
    GITHUB_SERVER_URL="${GITHUB_SERVER_URL-https://github.com}" \
    GITHUB_RUN_ID="${GITHUB_RUN_ID-1}" \
    GITHUB_RUN_ATTEMPT="${GITHUB_RUN_ATTEMPT-1}" \
    GITHUB_JOB="${GITHUB_JOB-test}" \
    GITHUB_ACTOR="${GITHUB_ACTOR-alice}" \
    GITHUB_ACTOR_ID="${GITHUB_ACTOR_ID-42}" \
    GITHUB_TRIGGERING_ACTOR="${GITHUB_TRIGGERING_ACTOR-alice}" \
    GITHUB_WORKFLOW_REF="${GITHUB_WORKFLOW_REF-agentdoc/test/.github/workflows/test.yml@refs/heads/main}" \
    GITHUB_WORKFLOW_SHA="${GITHUB_WORKFLOW_SHA-4444444444444444444444444444444444444444}" \
    RUNNER_TEMP="$CASE_DIR/runner" \
    INPUT_ENFORCEMENT="${INPUT_ENFORCEMENT:-advisory}" \
    INPUT_SCOPE="${INPUT_SCOPE:-full}" \
    INPUT_REPORT_STYLE="${INPUT_REPORT_STYLE:-compact}" \
    INPUT_ADOC_VERSION="${INPUT_ADOC_VERSION:-v0.3.4}" \
    INPUT_SYNC_POLICY="${INPUT_SYNC_POLICY:-advisory}" \
    INPUT_BOOTSTRAP="${INPUT_BOOTSTRAP:-false}" \
    INPUT_WORKING_DIRECTORY="${INPUT_WORKING_DIRECTORY:-docs}" \
    INPUT_COMMENT="${INPUT_COMMENT:-true}" \
    INPUT_COMMENT_MAX_COMMENTS="${INPUT_COMMENT_MAX_COMMENTS:-5}" \
    INPUT_SEMANTIC_REVIEW="${INPUT_SEMANTIC_REVIEW:-false}" \
    INPUT_SEMANTIC_FALLBACK_POLICY="${INPUT_SEMANTIC_FALLBACK_POLICY:-}" \
    INPUT_SEMANTIC_PRIMARY_REQUEST="${INPUT_SEMANTIC_PRIMARY_REQUEST:-}" \
    INPUT_SEMANTIC_FALLBACK_REQUEST="${INPUT_SEMANTIC_FALLBACK_REQUEST--}" \
    INPUT_PROPOSE="${INPUT_PROPOSE:-true}" \
    INPUT_PROPOSE_PROVIDER="${INPUT_PROPOSE_PROVIDER:-claude-code}" \
    INPUT_PROPOSE_DELIVERY="${INPUT_PROPOSE_DELIVERY:-comment}" \
    INPUT_PROPOSE_ON_ERROR="${INPUT_PROPOSE_ON_ERROR:-warn}" \
    INPUT_PROPOSE_MAX_PATHS="${INPUT_PROPOSE_MAX_PATHS:-10}" \
    INPUT_PROPOSE_COVERAGE="${INPUT_PROPOSE_COVERAGE:-bounded}" \
    INPUT_PROPOSE_AUTHORITY="${INPUT_PROPOSE_AUTHORITY:-downgrade}" \
    INPUT_PROPOSE_CONTRADICTIONS="${INPUT_PROPOSE_CONTRADICTIONS:-suggest}" \
    INPUT_PROPOSE_DELIVERY_POLICY="${INPUT_PROPOSE_DELIVERY_POLICY:-atomic}" \
    INPUT_PROVIDER_TIMEOUT_SECONDS="${INPUT_PROVIDER_TIMEOUT_SECONDS-600}" \
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
grep -q '^ADOC_UNTRUSTED_CHANGE=true$' "$CASE_DIR/github-env.last"
grep -q '^ADOC_HEAD_REPOSITORY=fork/test$' "$CASE_DIR/github-env.last"
TEST_EVENT_NAME=workflow_dispatch INPUT_BOOTSTRAP=true INPUT_SYNC_POLICY=required \
  INPUT_PROPOSE=true INPUT_PROPOSE_DELIVERY=pr INPUT_PROPOSE_ON_ERROR=fail \
  INPUT_PROPOSE_COVERAGE=full preflight
grep -q '^ADOC_BOOTSTRAP=true$' "$CASE_DIR/github-env.last"
grep -q '^ADOC_DIFF_BASE=4b825dc642cb6eb9a060e54bf8d69288fbee4904$' \
  "$CASE_DIR/github-env.last"
grep -q "^ADOC_HEAD=$event_head$" "$CASE_DIR/github-env.last"
grep -q '^ADOC_HEAD_REF=main$' "$CASE_DIR/github-env.last"
grep -q '^ADOC_BASE_REF=main$' "$CASE_DIR/github-env.last"

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
expect_reject GITHUB_REPOSITORY_ID ''
expect_reject INPUT_ENFORCEMENT maybe
expect_reject INPUT_COMMENT TRUE
expect_reject INPUT_COMMENT_MAX_COMMENTS 0
expect_reject INPUT_COMMENT_MAX_COMMENTS none
expect_reject INPUT_SEMANTIC_REVIEW TRUE
expect_reject INPUT_PROPOSE_MAX_PATHS 0
expect_reject INPUT_PROPOSE_MAX_PATHS 51
expect_reject INPUT_PROPOSE_COVERAGE everything
expect_reject INPUT_PROPOSE_AUTHORITY elevate
expect_reject INPUT_PROPOSE_CONTRADICTIONS resolve
expect_reject INPUT_PROPOSE_DELIVERY_POLICY best-effort
expect_reject INPUT_PROVIDER_TIMEOUT_SECONDS ''
expect_reject INPUT_PROVIDER_TIMEOUT_SECONDS 59
expect_reject INPUT_PROVIDER_TIMEOUT_SECONDS 3601
expect_reject INPUT_PROVIDER_TIMEOUT_SECONDS ten
expect_reject INPUT_MODEL 'bad model'
expect_reject INPUT_CLAUDE_CODE_VERSION latest
expect_reject INPUT_WORKING_DIRECTORY ../outside
expect_reject INPUT_CLOUD_UPLOAD_TOKEN_PRESENT maybe

printf '{}\n' > "$CASE_DIR/runner/fallback-policy.json"
printf '{}\n' > "$CASE_DIR/runner/primary-request.json"
INPUT_SEMANTIC_REVIEW=true INPUT_PROPOSE=false \
  INPUT_SEMANTIC_FALLBACK_POLICY="$CASE_DIR/runner/fallback-policy.json" \
  INPUT_SEMANTIC_PRIMARY_REQUEST="$CASE_DIR/runner/primary-request.json" \
  INPUT_SEMANTIC_FALLBACK_REQUEST=- preflight
grep -q '^ADOC_SEMANTIC_FALLBACK_CONFIGURED=true$' "$CASE_DIR/github-env.last"
fallback_run="$(sed -n 's/^ADOC_RUN_DIR=//p' "$CASE_DIR/github-env.last")"
cmp "$CASE_DIR/runner/fallback-policy.json" "$fallback_run/semantic-fallback-policy.json"
cmp "$CASE_DIR/runner/primary-request.json" "$fallback_run/semantic-primary-request.json"
(INPUT_SEMANTIC_REVIEW=true INPUT_PROPOSE=false \
  INPUT_SEMANTIC_FALLBACK_POLICY="$CASE_DIR/workspace/docs/index.adoc" \
  INPUT_SEMANTIC_PRIMARY_REQUEST="$CASE_DIR/runner/primary-request.json" \
  INPUT_SEMANTIC_FALLBACK_REQUEST=- preflight) 2> "$CASE_DIR/error"
grep -q 'semantic-fallback-policy must be a regular file beneath RUNNER_TEMP' "$CASE_DIR/error"
grep -q '^ADOC_PIPELINE_READY=false$' "$CASE_DIR/github-env.last"

INPUT_COMMENT_MAX_COMMENTS=unlimited preflight
grep -q '^ADOC_PIPELINE_READY=true$' "$CASE_DIR/github-env.last"
INPUT_PROVIDER_TIMEOUT_SECONDS=600 preflight
grep -q '^ADOC_PIPELINE_READY=true$' "$CASE_DIR/github-env.last"

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

mkdir -p "$CASE_DIR/codex-package/package/vendor/x86_64-unknown-linux-musl/bin"
printf '#!/bin/sh\nexit 0\n' \
  > "$CASE_DIR/codex-package/package/vendor/x86_64-unknown-linux-musl/bin/codex"
chmod +x "$CASE_DIR/codex-package/package/vendor/x86_64-unknown-linux-musl/bin/codex"
mkdir -p "$CASE_DIR/codex-package/package/vendor/aarch64-unknown-linux-musl/bin"
cp "$CASE_DIR/codex-package/package/vendor/x86_64-unknown-linux-musl/bin/codex" \
  "$CASE_DIR/codex-package/package/vendor/aarch64-unknown-linux-musl/bin/codex"
tar -czf "$CASE_DIR/codex.tgz" -C "$CASE_DIR/codex-package" package
codex_digest="$(sha512sum "$CASE_DIR/codex.tgz" | awk '{print $1}')"
env -i PATH="/usr/bin:/bin:/sbin" LANG=C LC_ALL=C \
  "$ROOT/scripts/install-codex.sh" 0.149.1 "$CASE_DIR/codex-provider" \
  "$CASE_DIR/codex.tgz" "$codex_digest"
test -x "$CASE_DIR/codex-provider/codex"
jq -e --arg digest "$codex_digest" \
  '.provider == "codex" and .version == "0.149.1" and .sha512 == $digest' \
  "$CASE_DIR/codex-provenance.json" >/dev/null

cp "$CASE_DIR/codex.tgz" "$CASE_DIR/codex-tampered.tgz"
printf x >> "$CASE_DIR/codex-tampered.tgz"
if env -i PATH="/usr/bin:/bin:/sbin" LANG=C LC_ALL=C \
  "$ROOT/scripts/install-codex.sh" 0.149.1 "$CASE_DIR/codex-tampered" \
  "$CASE_DIR/codex-tampered.tgz" "$codex_digest" 2> "$CASE_DIR/error"; then
  echo 'tampered Codex archive unexpectedly installed' >&2
  exit 1
fi
grep -q 'action.provider_integrity_failed' "$CASE_DIR/error"

mkdir -p "$CASE_DIR/proposal-skip"
ADOC_RUN_DIR="$CASE_DIR/proposal-skip" ADOC_PROPOSE_ELIGIBLE=false \
  "$ROOT/scripts/propose.sh"
jq -e '.status == "skipped" and .reason == "untrusted_pr"' \
  "$CASE_DIR/proposal-skip/proposal-status.json" >/dev/null

echo 'proposal security tests passed'
