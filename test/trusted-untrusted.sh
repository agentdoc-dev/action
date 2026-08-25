#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REAL_GIT_BIN="$(command -v git)"
CASE_DIR="$(mktemp -d)"
trap 'rm -rf "$CASE_DIR"' EXIT
mkdir -p "$CASE_DIR/repo" "$CASE_DIR/out"
git -C "$CASE_DIR/repo" init -q -b main
git -C "$CASE_DIR/repo" config user.name test
git -C "$CASE_DIR/repo" config user.email test@example.com
printf '# base\n' > "$CASE_DIR/repo/index.adoc"
git -C "$CASE_DIR/repo" add -A
git -C "$CASE_DIR/repo" commit -qm base
base="$(git -C "$CASE_DIR/repo" rev-parse HEAD)"
mkdir -p "$CASE_DIR/repo/service/scripts"
cat > "$CASE_DIR/repo/service/package.json" <<JSON
{"scripts":{"postinstall":"touch $CASE_DIR/contributor-code-ran"}}
JSON
printf '#!/bin/sh\ntouch %s\n' "$CASE_DIR/contributor-code-ran" \
  > "$CASE_DIR/repo/service/scripts/postinstall.sh"
chmod +x "$CASE_DIR/repo/service/scripts/postinstall.sh"
git -C "$CASE_DIR/repo" add -A
git -C "$CASE_DIR/repo" commit -qm head
head="$(git -C "$CASE_DIR/repo" rev-parse HEAD)"
git -C "$CASE_DIR/repo" branch feature "$head"
export GITHUB_SERVER_URL=https://ghe.example GITHUB_REPOSITORY=agentdoc/base
export GITHUB_REPOSITORY_ID=408 GITHUB_RUN_ID=101 GITHUB_RUN_ATTEMPT=1
export GITHUB_JOB=trusted-review GITHUB_ACTOR_ID=42 GITHUB_TRIGGERING_ACTOR=authorizer
export GITHUB_REF=refs/heads/main
export GITHUB_WORKFLOW_REF='agentdoc/base/.github/workflows/trusted.yml@refs/heads/main'
export GITHUB_SHA="$base"
export INPUT_SEMANTIC_REVIEW=true INPUT_PROPOSE=true
export INPUT_TRUSTED_EXECUTOR_QUALIFICATION_ID=50000000-0000-0000-0000-000000000408

jq -n --arg base "$base" --arg head "$head" '{
  schema_version:"adoc.change_assessment.v0",evaluation_date:"2026-08-25",
  snapshots:{requested_base:{resolved_commit:$base},head:{resolved_commit:$head}},
  paths:{status:"available",value:[
    {path:"package.json"},{path:"scripts/postinstall.sh"}
  ]}
}' > "$CASE_DIR/assessment.json"

build_request() {
  ADOC_ASSESSMENT_PATH="$CASE_DIR/assessment.json" \
  ADOC_TRUSTED_REQUEST_PATH="$1" \
  ADOC_WORKING_DIRECTORY="$CASE_DIR/repo/service" \
  GITHUB_REPOSITORY=agentdoc/base \
  ADOC_HEAD_REPOSITORY=contributor/fork \
  ADOC_UNTRUSTED_SOURCE=fork \
  ADOC_PR_NUMBER=17 ADOC_BASE_REF=main \
  ADOC_REQUESTED_BASE="$base" ADOC_HEAD="$head" \
    "$ROOT/scripts/build-trusted-change-request.sh"
}

build_request "$CASE_DIR/request-a.json"
build_request "$CASE_DIR/request-b.json"
cmp "$CASE_DIR/request-a.json" "$CASE_DIR/request-b.json"
test ! -e "$CASE_DIR/contributor-code-ran"
jq -e --arg base "$base" --arg head "$head" '
  .version == 1 and .base_repository == "agentdoc/base"
  and .head_repository == "contributor/fork" and .pull_request == 17
  and .untrusted_source == "fork"
  and .base_ref == "main" and .base_revision == $base
  and .head_revision == $head
  and (.assessment_digest | test("^sha256:[0-9a-f]{64}$"))
  and (.context_request_digest | test("^sha256:[0-9a-f]{64}$"))
  and (.request_digest | test("^sha256:[0-9a-f]{64}$"))
  and .context_request == [
    {repository:"agentdoc/base",path:"service/package.json"},
    {repository:"agentdoc/base",path:"service/scripts/postinstall.sh"}
  ]
' "$CASE_DIR/request-a.json" >/dev/null

if CLOUD_UPLOAD_TOKEN=forbidden build_request "$CASE_DIR/secret.json" \
  2> "$CASE_DIR/secret.stderr"; then
  echo 'untrusted request accepted a Cloud write credential' >&2
  exit 1
fi
grep -q 'trusted.untrusted_secret_present' "$CASE_DIR/secret.stderr"
test ! -e "$CASE_DIR/secret.json"

request_digest="$(jq -r .request_digest "$CASE_DIR/request-a.json")"
bindings="$("$ROOT/scripts/trusted-run-bindings.sh")"
jq -n '{request_digest:("sha256:" + ("c" * 64))}' \
  > "$CASE_DIR/cloud-request.json"
cloud_policy() { # request, destination, credential
  INPUT_CLOUD_WORK_REQUEST="$1" INPUT_CLOUD_UPLOAD_URL="$2" \
    INPUT_CLOUD_UPLOAD_TOKEN="$3" "$ROOT/scripts/trusted-run-bindings.sh" \
    | jq -r .policy.digest
}
cloud_binding="$(cloud_policy "$CASE_DIR/cloud-request.json" \
  https://cloud.test/work-results workspace-token-a)"
jq '.request_digest = ("sha256:" + ("d" * 64))' \
  "$CASE_DIR/cloud-request.json" > "$CASE_DIR/cloud-request-b.json"
test "$cloud_binding" != "$(jq -r .policy.digest <<< "$bindings")"
test "$cloud_binding" != "$(cloud_policy "$CASE_DIR/cloud-request.json" \
  https://other.test/work-results workspace-token-a)"
test "$cloud_binding" != "$(cloud_policy "$CASE_DIR/cloud-request-b.json" \
  https://cloud.test/work-results workspace-token-a)"
test "$cloud_binding" = "$(cloud_policy "$CASE_DIR/cloud-request.json" \
  https://cloud.test/work-results workspace-token-b)"
jq -n --arg request "$request_digest" --arg head "$head" \
  --argjson bindings "$bindings" '{
  version:1,request_digest:$request,head_revision:$head,decision:"authorized",
  expires_at:"2099-08-26T12:00:00Z",
  authorizer:{
    principal_id:"20000000-0000-0000-0000-000000000408",
    authorization_decision_id:"70000000-0000-0000-0000-000000000408"
  },
  policy:$bindings.policy,workload:$bindings.workload,
  executor:{
    qualification_id:"50000000-0000-0000-0000-000000000408",
    provider:"codex",model:"gpt-5.6-codex",
    config_digest:("sha256:" + ("2" * 64))
  },
  authorized_paths:["service/package.json","service/scripts/postinstall.sh"]
}' > "$CASE_DIR/authorization.json"

mkdir -p "$CASE_DIR/bin"
cat > "$CASE_DIR/bin/gh" <<'SH'
#!/usr/bin/env bash
cat "$FAKE_PR_RESPONSE"
SH
chmod +x "$CASE_DIR/bin/gh"
cat > "$CASE_DIR/bin/git" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
args=()
for arg in "$@"; do
  case "$arg" in
    https://*/contributor/fork.git)
      if [ "${EXPECT_GIT_AUTH:-false}" = true ]; then
        [ "${ADOC_GIT_ASKPASS:-false}" = true ]
        [ -n "${ADOC_GIT_PASSWORD:-}" ]
        [ -n "${GIT_ASKPASS:-}" ]
        [ -z "${GIT_AUTH_CAPTURE:-}" ] || printf '%s\n' authenticated > "$GIT_AUTH_CAPTURE"
      else
        [ -z "${GH_TOKEN:-}${GITHUB_TOKEN:-}${ADOC_GIT_PASSWORD:-}" ]
        [ "${ADOC_GIT_ASKPASS:-false}" = false ]
      fi
      [ -z "${GIT_REMOTE_CAPTURE:-}" ] || printf '%s\n' "$arg" > "$GIT_REMOTE_CAPTURE"
      args+=("$FAKE_GIT_REMOTE") ;;
    https://*/agentdoc/base.git)
      [ "${ADOC_GIT_ASKPASS:-false}" = true ]
      [ -n "${ADOC_GIT_PASSWORD:-}" ]
      [ -n "${GIT_ASKPASS:-}" ]
      [ -z "${GIT_AUTH_CAPTURE:-}" ] || printf '%s\n' authenticated > "$GIT_AUTH_CAPTURE"
      args+=("$FAKE_GIT_REMOTE") ;;
    *) args+=("$arg") ;;
  esac
done
exec "$REAL_GIT" "${args[@]}"
SH
chmod +x "$CASE_DIR/bin/git"
git clone -q "$CASE_DIR/repo" "$CASE_DIR/trusted"
git -C "$CASE_DIR/trusted" checkout -q --detach "$base"
jq -n --arg base "$base" --arg head "$head" '{
  state:"open",base:{sha:$base,ref:"main",repo:{full_name:"agentdoc/base"}},
  head:{sha:$head,ref:"feature",repo:{full_name:"contributor/fork"}}
}' > "$CASE_DIR/pr.json"

PATH="$CASE_DIR/bin:$PATH" FAKE_PR_RESPONSE="$CASE_DIR/pr.json" \
  REAL_GIT="$REAL_GIT_BIN" FAKE_GIT_REMOTE="$CASE_DIR/repo" \
  GIT_REMOTE_CAPTURE="$CASE_DIR/git-remote" \
  TRUSTED_CHANGE_REQUEST="$CASE_DIR/request-a.json" \
  TRUSTED_CHANGE_AUTHORIZATION="$CASE_DIR/authorization.json" \
  TRUSTED_PREPARED_ENV="$CASE_DIR/prepared.env" \
  TRUSTED_PHASE_STATUS_PATH="$CASE_DIR/trusted-status.json" \
  GITHUB_EVENT_NAME=workflow_dispatch GITHUB_REPOSITORY=agentdoc/base \
  GITHUB_SERVER_URL=https://ghe.example \
  GITHUB_REF=refs/heads/main \
  GITHUB_WORKFLOW_REF='agentdoc/base/.github/workflows/trusted.yml@refs/heads/main' \
  GITHUB_SHA="$base" GITHUB_WORKSPACE="$CASE_DIR/trusted" GH_TOKEN=read-token \
    "$ROOT/scripts/prepare-trusted-change.sh"
jq -e --arg head "$head" --arg request "$request_digest" \
  --argjson bindings "$bindings" '
  .state == "authorized" and .head_revision == $head
  and .request_digest == $request
  and .authorizer.principal_id == "20000000-0000-0000-0000-000000000408"
  and .policy == $bindings.policy and .workload == $bindings.workload
  and .executor.qualification_id == "50000000-0000-0000-0000-000000000408"
' "$CASE_DIR/trusted-status.json" >/dev/null
grep -q '^TRUSTED_HEAD_REPOSITORY=contributor/fork$' "$CASE_DIR/prepared.env"
grep -q '^TRUSTED_BASE_REF=main$' "$CASE_DIR/prepared.env"
grep -q "^TRUSTED_ASSESSMENT_DIGEST=$(jq -r .assessment_digest "$CASE_DIR/request-a.json")$" \
  "$CASE_DIR/prepared.env"
grep -q '^TRUSTED_AUTHORIZATION_EXPIRES_AT=2099-08-26T12:00:00Z$' \
  "$CASE_DIR/prepared.env"
grep -qx 'https://ghe.example/contributor/fork.git' "$CASE_DIR/git-remote"
test ! -e "$CASE_DIR/contributor-code-ran"

jq '.expires_at = "2099-02-30T12:00:00Z"' "$CASE_DIR/authorization.json" \
  > "$CASE_DIR/impossible-expiry.json"
if PATH="$CASE_DIR/bin:$PATH" FAKE_PR_RESPONSE="$CASE_DIR/pr.json" \
  REAL_GIT="$REAL_GIT_BIN" FAKE_GIT_REMOTE="$CASE_DIR/repo" \
  TRUSTED_CHANGE_REQUEST="$CASE_DIR/request-a.json" \
  TRUSTED_CHANGE_AUTHORIZATION="$CASE_DIR/impossible-expiry.json" \
  TRUSTED_PREPARED_ENV="$CASE_DIR/impossible-expiry.env" \
  TRUSTED_PHASE_STATUS_PATH="$CASE_DIR/impossible-expiry-status.json" \
  GITHUB_EVENT_NAME=workflow_dispatch GITHUB_REPOSITORY=agentdoc/base \
  GITHUB_SERVER_URL=https://ghe.example GITHUB_REF=refs/heads/main \
  GITHUB_WORKFLOW_REF='agentdoc/base/.github/workflows/trusted.yml@refs/heads/main' \
  GITHUB_SHA="$base" GITHUB_WORKSPACE="$CASE_DIR/trusted" GH_TOKEN=read-token \
    "$ROOT/scripts/prepare-trusted-change.sh" 2> "$CASE_DIR/impossible-expiry.stderr"; then
  echo 'trusted phase accepted an impossible authorization expiry' >&2
  exit 1
fi
grep -q 'trusted.authorization_invalid' "$CASE_DIR/impossible-expiry.stderr"

if PATH="$CASE_DIR/bin:$PATH" FAKE_PR_RESPONSE="$CASE_DIR/pr.json" \
  REAL_GIT="$REAL_GIT_BIN" FAKE_GIT_REMOTE="$CASE_DIR/repo" \
  INPUT_PROPOSE_DELIVERY=pr \
  TRUSTED_CHANGE_REQUEST="$CASE_DIR/request-a.json" \
  TRUSTED_CHANGE_AUTHORIZATION="$CASE_DIR/authorization.json" \
  TRUSTED_PREPARED_ENV="$CASE_DIR/policy-replay.env" \
  TRUSTED_PHASE_STATUS_PATH="$CASE_DIR/policy-replay-status.json" \
  GITHUB_EVENT_NAME=workflow_dispatch GITHUB_SHA="$base" GITHUB_WORKSPACE="$CASE_DIR/trusted" \
  GH_TOKEN=read-token "$ROOT/scripts/prepare-trusted-change.sh" \
    2> "$CASE_DIR/policy-replay.stderr"; then
  echo 'trusted phase reused authorization with broader delivery settings' >&2
  exit 1
fi
grep -q 'trusted.authorization_invalid' "$CASE_DIR/policy-replay.stderr"

if PATH="$CASE_DIR/bin:$PATH" FAKE_PR_RESPONSE="$CASE_DIR/pr.json" \
  REAL_GIT="$REAL_GIT_BIN" FAKE_GIT_REMOTE="$CASE_DIR/repo" \
  INPUT_CLOUD_WORK_REQUEST="$CASE_DIR/cloud-request.json" \
  INPUT_CLOUD_UPLOAD_URL=https://cloud.test/work-results \
  INPUT_CLOUD_UPLOAD_TOKEN=workspace-token-a \
  TRUSTED_CHANGE_REQUEST="$CASE_DIR/request-a.json" \
  TRUSTED_CHANGE_AUTHORIZATION="$CASE_DIR/authorization.json" \
  TRUSTED_PREPARED_ENV="$CASE_DIR/cloud-replay.env" \
  TRUSTED_PHASE_STATUS_PATH="$CASE_DIR/cloud-replay-status.json" \
  GITHUB_EVENT_NAME=workflow_dispatch GITHUB_SHA="$base" \
  GITHUB_WORKSPACE="$CASE_DIR/trusted" GH_TOKEN=read-token \
    "$ROOT/scripts/prepare-trusted-change.sh" 2> "$CASE_DIR/cloud-replay.stderr"; then
  echo 'trusted phase enabled an unauthorized Cloud hand-off' >&2
  exit 1
fi
grep -q 'trusted.authorization_invalid' "$CASE_DIR/cloud-replay.stderr"

if PATH="$CASE_DIR/bin:$PATH" FAKE_PR_RESPONSE="$CASE_DIR/pr.json" \
  REAL_GIT="$REAL_GIT_BIN" FAKE_GIT_REMOTE="$CASE_DIR/repo" \
  GITHUB_RUN_ID=102 TRUSTED_CHANGE_REQUEST="$CASE_DIR/request-a.json" \
  TRUSTED_CHANGE_AUTHORIZATION="$CASE_DIR/authorization.json" \
  TRUSTED_PREPARED_ENV="$CASE_DIR/session-replay.env" \
  TRUSTED_PHASE_STATUS_PATH="$CASE_DIR/session-replay-status.json" \
  GITHUB_EVENT_NAME=workflow_dispatch GITHUB_SHA="$base" GITHUB_WORKSPACE="$CASE_DIR/trusted" \
  GH_TOKEN=read-token "$ROOT/scripts/prepare-trusted-change.sh" \
    2> "$CASE_DIR/session-replay.stderr"; then
  echo 'trusted phase reused authorization from another workflow session' >&2
  exit 1
fi
grep -q 'trusted.authorization_invalid' "$CASE_DIR/session-replay.stderr"

jq '.head.repo.private = true' "$CASE_DIR/pr.json" > "$CASE_DIR/private-pr.json"
PATH="$CASE_DIR/bin:$PATH" FAKE_PR_RESPONSE="$CASE_DIR/private-pr.json" \
  REAL_GIT="$REAL_GIT_BIN" FAKE_GIT_REMOTE="$CASE_DIR/repo" \
  EXPECT_GIT_AUTH=true GIT_AUTH_CAPTURE="$CASE_DIR/private-git-auth" \
  TRUSTED_CHANGE_REQUEST="$CASE_DIR/request-a.json" \
  TRUSTED_CHANGE_AUTHORIZATION="$CASE_DIR/authorization.json" \
  TRUSTED_PREPARED_ENV="$CASE_DIR/private.env" \
  TRUSTED_PHASE_STATUS_PATH="$CASE_DIR/private-status.json" \
  GITHUB_EVENT_NAME=workflow_dispatch GITHUB_SHA="$base" GITHUB_WORKSPACE="$CASE_DIR/trusted" \
  GH_TOKEN=read-token "$ROOT/scripts/prepare-trusted-change.sh"
grep -qx authenticated "$CASE_DIR/private-git-auth"

jq '.base.ref = "release"' "$CASE_DIR/pr.json" > "$CASE_DIR/retargeted-pr.json"
retargeted_bindings="$(GITHUB_REF=refs/heads/release \
  GITHUB_WORKFLOW_REF='agentdoc/base/.github/workflows/trusted.yml@refs/heads/release' \
  "$ROOT/scripts/trusted-run-bindings.sh")"
jq --argjson bindings "$retargeted_bindings" '
  .policy = $bindings.policy | .workload = $bindings.workload
' "$CASE_DIR/authorization.json" > "$CASE_DIR/retargeted-authorization.json"
if PATH="$CASE_DIR/bin:$PATH" FAKE_PR_RESPONSE="$CASE_DIR/retargeted-pr.json" \
  REAL_GIT="$REAL_GIT_BIN" FAKE_GIT_REMOTE="$CASE_DIR/repo" \
  TRUSTED_CHANGE_REQUEST="$CASE_DIR/request-a.json" \
  TRUSTED_CHANGE_AUTHORIZATION="$CASE_DIR/retargeted-authorization.json" \
  TRUSTED_PREPARED_ENV="$CASE_DIR/retargeted.env" \
  TRUSTED_PHASE_STATUS_PATH="$CASE_DIR/retargeted-status.json" \
  GITHUB_EVENT_NAME=workflow_dispatch GITHUB_REPOSITORY=agentdoc/base \
  GITHUB_REF=refs/heads/release \
  GITHUB_WORKFLOW_REF='agentdoc/base/.github/workflows/trusted.yml@refs/heads/release' \
  GITHUB_SHA="$base" GITHUB_WORKSPACE="$CASE_DIR/trusted" GH_TOKEN=read-token \
    "$ROOT/scripts/prepare-trusted-change.sh" 2> "$CASE_DIR/retargeted.stderr"; then
  echo 'trusted phase accepted a pull request retargeted after assessment' >&2
  exit 1
fi
grep -q 'trusted.github_identity_invalid' "$CASE_DIR/retargeted.stderr"

git -C "$CASE_DIR/trusted" checkout -q --detach "$head"
if PATH="$CASE_DIR/bin:$PATH" FAKE_PR_RESPONSE="$CASE_DIR/pr.json" \
  REAL_GIT="$REAL_GIT_BIN" FAKE_GIT_REMOTE="$CASE_DIR/repo" \
  TRUSTED_CHANGE_REQUEST="$CASE_DIR/request-a.json" \
  TRUSTED_CHANGE_AUTHORIZATION="$CASE_DIR/authorization.json" \
  TRUSTED_PREPARED_ENV="$CASE_DIR/wrong-base.env" \
  TRUSTED_PHASE_STATUS_PATH="$CASE_DIR/wrong-base-status.json" \
  GITHUB_EVENT_NAME=workflow_dispatch GITHUB_REPOSITORY=agentdoc/base \
  GITHUB_REF=refs/heads/feature \
  GITHUB_WORKFLOW_REF='agentdoc/base/.github/workflows/trusted.yml@refs/heads/feature' \
  GITHUB_SHA="$head" GITHUB_WORKSPACE="$CASE_DIR/trusted" GH_TOKEN=read-token \
    "$ROOT/scripts/prepare-trusted-change.sh" 2> "$CASE_DIR/wrong-base.stderr"; then
  echo 'trusted phase accepted a workflow from outside the authenticated PR base' >&2
  exit 1
fi
grep -q 'trusted.base_workflow_required' "$CASE_DIR/wrong-base.stderr"
git -C "$CASE_DIR/trusted" checkout -q --detach "$base"

jq '.head_repository = "agentdoc/base" | .untrusted_source = "dependabot"' \
  "$CASE_DIR/request-a.json" > "$CASE_DIR/dependabot-request.json"
dependabot_request="sha256:$(jq -cS 'del(.request_digest)' \
  "$CASE_DIR/dependabot-request.json" | sha256sum | awk '{print $1}')"
jq --arg digest "$dependabot_request" '.request_digest = $digest' \
  "$CASE_DIR/dependabot-request.json" > "$CASE_DIR/dependabot-request.next"
mv "$CASE_DIR/dependabot-request.next" "$CASE_DIR/dependabot-request.json"
jq --arg digest "$dependabot_request" '.request_digest = $digest' \
  "$CASE_DIR/authorization.json" > "$CASE_DIR/dependabot-authorization.json"
jq '.head.repo.full_name = "agentdoc/base"
  | .user = {login:"dependabot[bot]"}' "$CASE_DIR/pr.json" \
  > "$CASE_DIR/dependabot-pr.json"
PATH="$CASE_DIR/bin:$PATH" FAKE_PR_RESPONSE="$CASE_DIR/dependabot-pr.json" \
  REAL_GIT="$REAL_GIT_BIN" FAKE_GIT_REMOTE="$CASE_DIR/repo" \
  GIT_AUTH_CAPTURE="$CASE_DIR/git-auth" \
  TRUSTED_CHANGE_REQUEST="$CASE_DIR/dependabot-request.json" \
  TRUSTED_CHANGE_AUTHORIZATION="$CASE_DIR/dependabot-authorization.json" \
  TRUSTED_PREPARED_ENV="$CASE_DIR/dependabot.env" \
  TRUSTED_PHASE_STATUS_PATH="$CASE_DIR/dependabot-status.json" \
  GITHUB_EVENT_NAME=workflow_dispatch GITHUB_REPOSITORY=agentdoc/base \
  GITHUB_SERVER_URL=https://ghe.example GITHUB_REF=refs/heads/main \
  GITHUB_WORKFLOW_REF='agentdoc/base/.github/workflows/trusted.yml@refs/heads/main' \
  GITHUB_SHA="$base" GITHUB_WORKSPACE="$CASE_DIR/trusted" GH_TOKEN=read-token \
    "$ROOT/scripts/prepare-trusted-change.sh"
grep -qx authenticated "$CASE_DIR/git-auth"

jq '.authorizer.principal_id = "caller-claimed"' "$CASE_DIR/authorization.json" \
  > "$CASE_DIR/unattributed.json"
if PATH="$CASE_DIR/bin:$PATH" FAKE_PR_RESPONSE="$CASE_DIR/pr.json" \
  REAL_GIT="$REAL_GIT_BIN" FAKE_GIT_REMOTE="$CASE_DIR/repo" \
  TRUSTED_CHANGE_REQUEST="$CASE_DIR/request-a.json" \
  TRUSTED_CHANGE_AUTHORIZATION="$CASE_DIR/unattributed.json" \
  TRUSTED_PREPARED_ENV="$CASE_DIR/unattributed.env" \
  TRUSTED_PHASE_STATUS_PATH="$CASE_DIR/unattributed-status.json" \
  GITHUB_EVENT_NAME=workflow_dispatch GITHUB_REPOSITORY=agentdoc/base \
  GITHUB_REF=refs/heads/main \
  GITHUB_WORKFLOW_REF='agentdoc/base/.github/workflows/trusted.yml@refs/heads/main' \
  GITHUB_SHA="$base" GITHUB_WORKSPACE="$CASE_DIR/trusted" GH_TOKEN=read-token \
    "$ROOT/scripts/prepare-trusted-change.sh" 2> "$CASE_DIR/unattributed.stderr"; then
  echo 'trusted phase accepted caller-claimed identity text' >&2
  exit 1
fi
grep -q 'trusted.authorization_invalid' "$CASE_DIR/unattributed.stderr"

jq '.context_request[0].repository = "other/repo"
  | .context_request |= sort_by(.repository,.path)' \
  "$CASE_DIR/request-a.json" > "$CASE_DIR/other-repo.json"
other_context="sha256:$(jq -cS '.context_request' "$CASE_DIR/other-repo.json" \
  | sha256sum | awk '{print $1}')"
jq --arg digest "$other_context" '.context_request_digest = $digest' \
  "$CASE_DIR/other-repo.json" > "$CASE_DIR/other-repo.next"
mv "$CASE_DIR/other-repo.next" "$CASE_DIR/other-repo.json"
other_request="sha256:$(jq -cS 'del(.request_digest)' "$CASE_DIR/other-repo.json" \
  | sha256sum | awk '{print $1}')"
jq --arg digest "$other_request" '.request_digest = $digest' \
  "$CASE_DIR/other-repo.json" > "$CASE_DIR/other-repo.next"
mv "$CASE_DIR/other-repo.next" "$CASE_DIR/other-repo.json"
jq --arg digest "$other_request" '.request_digest = $digest' \
  "$CASE_DIR/authorization.json" > "$CASE_DIR/other-repo-auth.json"
if PATH="$CASE_DIR/bin:$PATH" FAKE_PR_RESPONSE="$CASE_DIR/pr.json" \
  REAL_GIT="$REAL_GIT_BIN" FAKE_GIT_REMOTE="$CASE_DIR/repo" \
  TRUSTED_CHANGE_REQUEST="$CASE_DIR/other-repo.json" \
  TRUSTED_CHANGE_AUTHORIZATION="$CASE_DIR/other-repo-auth.json" \
  TRUSTED_PREPARED_ENV="$CASE_DIR/other-repo.env" \
  TRUSTED_PHASE_STATUS_PATH="$CASE_DIR/other-repo-status.json" \
  GITHUB_EVENT_NAME=workflow_dispatch GITHUB_REPOSITORY=agentdoc/base \
  GITHUB_REF=refs/heads/main \
  GITHUB_WORKFLOW_REF='agentdoc/base/.github/workflows/trusted.yml@refs/heads/main' \
  GITHUB_SHA="$base" GITHUB_WORKSPACE="$CASE_DIR/trusted" GH_TOKEN=read-token \
    "$ROOT/scripts/prepare-trusted-change.sh" 2> "$CASE_DIR/other-repo.stderr"; then
  echo 'trusted phase accepted cross-repository context' >&2
  exit 1
fi
grep -q 'trusted.context_unauthorized' "$CASE_DIR/other-repo.stderr"

jq '.context_request[0].path = "../secret"' \
  "$CASE_DIR/request-a.json" > "$CASE_DIR/path-escape.json"
if PATH="$CASE_DIR/bin:$PATH" FAKE_PR_RESPONSE="$CASE_DIR/pr.json" \
  REAL_GIT="$REAL_GIT_BIN" FAKE_GIT_REMOTE="$CASE_DIR/repo" \
  TRUSTED_CHANGE_REQUEST="$CASE_DIR/path-escape.json" \
  TRUSTED_CHANGE_AUTHORIZATION="$CASE_DIR/authorization.json" \
  TRUSTED_PREPARED_ENV="$CASE_DIR/path-escape.env" \
  TRUSTED_PHASE_STATUS_PATH="$CASE_DIR/path-escape-status.json" \
  GITHUB_EVENT_NAME=workflow_dispatch GITHUB_REPOSITORY=agentdoc/base \
  GITHUB_REF=refs/heads/main \
  GITHUB_WORKFLOW_REF='agentdoc/base/.github/workflows/trusted.yml@refs/heads/main' \
  GITHUB_SHA="$base" GITHUB_WORKSPACE="$CASE_DIR/trusted" GH_TOKEN=read-token \
    "$ROOT/scripts/prepare-trusted-change.sh" 2> "$CASE_DIR/path-escape.stderr"; then
  echo 'trusted phase accepted a context path escape' >&2
  exit 1
fi
grep -q 'trusted.request_invalid' "$CASE_DIR/path-escape.stderr"

jq '.authorized_paths = ["service/package.json"]' "$CASE_DIR/authorization.json" \
  > "$CASE_DIR/restricted.json"
if PATH="$CASE_DIR/bin:$PATH" FAKE_PR_RESPONSE="$CASE_DIR/pr.json" \
  REAL_GIT="$REAL_GIT_BIN" FAKE_GIT_REMOTE="$CASE_DIR/repo" \
  TRUSTED_CHANGE_REQUEST="$CASE_DIR/request-a.json" \
  TRUSTED_CHANGE_AUTHORIZATION="$CASE_DIR/restricted.json" \
  TRUSTED_PREPARED_ENV="$CASE_DIR/restricted.env" \
  TRUSTED_PHASE_STATUS_PATH="$CASE_DIR/restricted-status.json" \
  GITHUB_EVENT_NAME=workflow_dispatch GITHUB_REPOSITORY=agentdoc/base \
  GITHUB_REF=refs/heads/main \
  GITHUB_WORKFLOW_REF='agentdoc/base/.github/workflows/trusted.yml@refs/heads/main' \
  GITHUB_SHA="$base" GITHUB_WORKSPACE="$CASE_DIR/trusted" GH_TOKEN=read-token \
    "$ROOT/scripts/prepare-trusted-change.sh" 2> "$CASE_DIR/restricted.stderr"; then
  echo 'trusted phase accepted a path outside authorization' >&2
  exit 1
fi
grep -q 'trusted.context_unauthorized' "$CASE_DIR/restricted.stderr"

: > "$CASE_DIR/assert.env"
PATH="$CASE_DIR/bin:$PATH" FAKE_PR_RESPONSE="$CASE_DIR/pr.json" \
  TRUSTED_CHANGE_REQUEST="$CASE_DIR/request-a.json" \
  TRUSTED_PHASE_STATUS_PATH="$CASE_DIR/trusted-status.json" \
  ADOC_TRUSTED_AUTHORIZATION_EXPIRES_AT=2099-08-26T12:00:00Z \
  GITHUB_ENV="$CASE_DIR/assert.env" GH_TOKEN=read-token \
    "$ROOT/scripts/assert-trusted-head.sh"
grep -q '^ADOC_TRUSTED_HEAD_CURRENT=true$' "$CASE_DIR/assert.env"

: > "$CASE_DIR/assert.env"
PATH="$CASE_DIR/bin:$PATH" FAKE_PR_RESPONSE="$CASE_DIR/retargeted-pr.json" \
  TRUSTED_CHANGE_REQUEST="$CASE_DIR/request-a.json" \
  TRUSTED_PHASE_STATUS_PATH="$CASE_DIR/trusted-status.json" \
  ADOC_TRUSTED_AUTHORIZATION_EXPIRES_AT=2099-08-26T12:00:00Z \
  GITHUB_ENV="$CASE_DIR/assert.env" GH_TOKEN=read-token \
    "$ROOT/scripts/assert-trusted-head.sh"
jq -e '.state == "failed"
  and .reason_code == "trusted.github_identity_invalid"
  and .result_digest == null' "$CASE_DIR/trusted-status.json" >/dev/null
grep -q '^ADOC_PROPOSE_ELIGIBLE=false$' "$CASE_DIR/assert.env"
grep -q '^ADOC_TRUSTED_HEAD_CURRENT=false$' "$CASE_DIR/assert.env"

jq --arg head "$(printf 'f%.0s' {1..40})" '.head.sha = $head' \
  "$CASE_DIR/pr.json" > "$CASE_DIR/force-pushed.json"
: > "$CASE_DIR/assert.env"
PATH="$CASE_DIR/bin:$PATH" FAKE_PR_RESPONSE="$CASE_DIR/force-pushed.json" \
  TRUSTED_CHANGE_REQUEST="$CASE_DIR/request-a.json" \
  TRUSTED_PHASE_STATUS_PATH="$CASE_DIR/trusted-status.json" \
  ADOC_TRUSTED_AUTHORIZATION_EXPIRES_AT=2099-08-26T12:00:00Z \
  GITHUB_ENV="$CASE_DIR/assert.env" GH_TOKEN=read-token \
    "$ROOT/scripts/assert-trusted-head.sh"
jq -e '.state == "expired_after_head_change"
  and .reason_code == "trusted.head_changed"
  and (.remediation | length > 0)
  and .result_digest == null' "$CASE_DIR/trusted-status.json" >/dev/null
grep -q '^ADOC_PROPOSE_ELIGIBLE=false$' "$CASE_DIR/assert.env"
grep -q '^ADOC_TRUSTED_HEAD_CURRENT=false$' "$CASE_DIR/assert.env"

mkdir -p "$CASE_DIR/delivery"
if PATH="$CASE_DIR/bin:$PATH" FAKE_PR_RESPONSE="$CASE_DIR/pr.json" \
  REAL_GIT="$REAL_GIT_BIN" \
  ADOC_RUN_DIR="$CASE_DIR/delivery" PROPOSE_DELIVERY=commit \
  GITHUB_REPOSITORY=agentdoc/base ADOC_HEAD_REPOSITORY=contributor/fork \
  HEAD_REF=feature ADOC_HEAD="$head" ADOC_EVALUATION_DATE=2026-08-25 \
  PR_NUMBER=17 ADOC_PROPOSE_ELIGIBLE=true \
    "$ROOT/scripts/deliver.sh"; then
  :
fi
jq -e '.status == "skipped"
  and .reason_code == "delivery.fork_branch_read_only"
  and (.remediation | length > 0)' "$CASE_DIR/delivery/delivery-status.json" >/dev/null

if PATH="$CASE_DIR/bin:$PATH" FAKE_PR_RESPONSE="$CASE_DIR/dependabot-pr.json" \
  REAL_GIT="$REAL_GIT_BIN" \
  ADOC_RUN_DIR="$CASE_DIR/delivery" PROPOSE_DELIVERY=commit \
  GITHUB_REPOSITORY=agentdoc/base ADOC_HEAD_REPOSITORY=agentdoc/base \
  ADOC_UNTRUSTED_SOURCE=dependabot ADOC_TRUSTED_PHASE=true \
  HEAD_REF=feature ADOC_HEAD="$head" ADOC_EVALUATION_DATE=2026-08-25 \
  PR_NUMBER=17 ADOC_PROPOSE_ELIGIBLE=true \
    "$ROOT/scripts/deliver.sh"; then
  :
fi
jq -e '.status == "skipped"
  and .reason_code == "delivery.fork_branch_read_only"' \
  "$CASE_DIR/delivery/delivery-status.json" >/dev/null

ln -s /etc/passwd "$CASE_DIR/repo/service/leak"
git -C "$CASE_DIR/repo" add service/leak
git -C "$CASE_DIR/repo" commit -qm symlink
symlink_head="$(git -C "$CASE_DIR/repo" rev-parse HEAD)"
git -C "$CASE_DIR/repo" branch -f feature "$symlink_head"
jq -n --arg base "$base" --arg head "$symlink_head" '{
  schema_version:"adoc.change_assessment.v0",evaluation_date:"2026-08-25",
  snapshots:{requested_base:{resolved_commit:$base},head:{resolved_commit:$head}},
  paths:{status:"available",value:[
    {path:"leak"},{path:"package.json"},{path:"scripts/postinstall.sh"}
  ]}
}' > "$CASE_DIR/symlink-assessment.json"
ADOC_ASSESSMENT_PATH="$CASE_DIR/symlink-assessment.json" \
ADOC_TRUSTED_REQUEST_PATH="$CASE_DIR/symlink-request.json" \
ADOC_WORKING_DIRECTORY="$CASE_DIR/repo/service" \
GITHUB_REPOSITORY=agentdoc/base ADOC_HEAD_REPOSITORY=contributor/fork \
ADOC_UNTRUSTED_SOURCE=fork ADOC_PR_NUMBER=17 ADOC_REQUESTED_BASE="$base" \
ADOC_BASE_REF=main ADOC_HEAD="$symlink_head" \
  "$ROOT/scripts/build-trusted-change-request.sh"
symlink_request="$(jq -r .request_digest "$CASE_DIR/symlink-request.json")"
jq --arg head "$symlink_head" --arg request "$symlink_request" '
  .head_revision = $head | .request_digest = $request
  | .authorized_paths = ["service/leak","service/package.json",
      "service/scripts/postinstall.sh"]
' "$CASE_DIR/authorization.json" > "$CASE_DIR/symlink-auth.json"
jq --arg head "$symlink_head" '.head.sha = $head' \
  "$CASE_DIR/pr.json" > "$CASE_DIR/symlink-pr.json"
if PATH="$CASE_DIR/bin:$PATH" FAKE_PR_RESPONSE="$CASE_DIR/symlink-pr.json" \
  REAL_GIT="$REAL_GIT_BIN" FAKE_GIT_REMOTE="$CASE_DIR/repo" \
  TRUSTED_CHANGE_REQUEST="$CASE_DIR/symlink-request.json" \
  TRUSTED_CHANGE_AUTHORIZATION="$CASE_DIR/symlink-auth.json" \
  TRUSTED_PREPARED_ENV="$CASE_DIR/symlink.env" \
  TRUSTED_PHASE_STATUS_PATH="$CASE_DIR/symlink-status.json" \
  GITHUB_EVENT_NAME=workflow_dispatch GITHUB_REPOSITORY=agentdoc/base \
  GITHUB_REF=refs/heads/main \
  GITHUB_WORKFLOW_REF='agentdoc/base/.github/workflows/trusted.yml@refs/heads/main' \
  GITHUB_SHA="$base" GITHUB_WORKSPACE="$CASE_DIR/trusted" GH_TOKEN=read-token \
    "$ROOT/scripts/prepare-trusted-change.sh" 2> "$CASE_DIR/symlink.stderr"; then
  echo 'trusted phase accepted symlink context' >&2
  exit 1
fi
grep -q 'trusted.context_unauthorized' "$CASE_DIR/symlink.stderr"
grep -Fq 'PR_NUMBER: ${{ env.ADOC_PR_NUMBER }}' "$ROOT/action.yml"
grep -Fq 'BASE_REF: ${{ env.ADOC_BASE_REF }}' "$ROOT/action.yml"
grep -Fq "env.ADOC_TRUSTED_REQUEST_ELIGIBLE == 'true'" "$ROOT/action.yml"

echo 'trusted/untrusted phase tests passed'
