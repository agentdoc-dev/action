#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CASE_DIR="$(mktemp -d)"
trap 'rm -rf "$CASE_DIR"' EXIT
mkdir -p "$CASE_DIR/repo" "$CASE_DIR/out"
REAL_GIT_BIN="$(command -v git)"
git -C "$CASE_DIR/repo" init -q -b main
git -C "$CASE_DIR/repo" config user.name test
git -C "$CASE_DIR/repo" config user.email test@example.com
printf '# base\n' > "$CASE_DIR/repo/index.adoc"
git -C "$CASE_DIR/repo" add -A
git -C "$CASE_DIR/repo" commit -qm base
base="$(git -C "$CASE_DIR/repo" rev-parse HEAD)"
mkdir -p "$CASE_DIR/repo/scripts"
cat > "$CASE_DIR/repo/package.json" <<JSON
{"scripts":{"postinstall":"touch $CASE_DIR/contributor-code-ran"}}
JSON
printf '#!/bin/sh\ntouch %s\n' "$CASE_DIR/contributor-code-ran" \
  > "$CASE_DIR/repo/scripts/postinstall.sh"
chmod +x "$CASE_DIR/repo/scripts/postinstall.sh"
git -C "$CASE_DIR/repo" add -A
git -C "$CASE_DIR/repo" commit -qm head
head="$(git -C "$CASE_DIR/repo" rev-parse HEAD)"
git -C "$CASE_DIR/repo" branch feature "$head"

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
  GITHUB_REPOSITORY=agentdoc/base \
  ADOC_HEAD_REPOSITORY=contributor/fork \
  ADOC_UNTRUSTED_SOURCE=fork \
  ADOC_PR_NUMBER=17 ADOC_REQUESTED_BASE="$base" ADOC_HEAD="$head" \
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
  and .base_revision == $base and .head_revision == $head
  and (.assessment_digest | test("^sha256:[0-9a-f]{64}$"))
  and (.context_request_digest | test("^sha256:[0-9a-f]{64}$"))
  and (.request_digest | test("^sha256:[0-9a-f]{64}$"))
  and .context_request == [
    {repository:"agentdoc/base",path:"package.json"},
    {repository:"agentdoc/base",path:"scripts/postinstall.sh"}
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
jq -n --arg request "$request_digest" --arg head "$head" '{
  version:1,request_digest:$request,head_revision:$head,decision:"authorized",
  expires_at:"2099-08-26T12:00:00Z",
  authorizer:{
    principal_id:"20000000-0000-0000-0000-000000000408",
    authorization_decision_id:"70000000-0000-0000-0000-000000000408"
  },
  policy:{version:"trusted-change-v1",digest:("sha256:" + ("1" * 64))},
  workload:{
    principal_id:"21000000-0000-0000-0000-000000000408",
    session_id:"40000000-0000-0000-0000-000000000408"
  },
  executor:{
    qualification_id:"50000000-0000-0000-0000-000000000408",
    provider:"codex",model:"gpt-5.6-codex",
    config_digest:("sha256:" + ("2" * 64))
  },
  authorized_paths:["package.json","scripts/postinstall.sh"]
}' > "$CASE_DIR/authorization.json"

mkdir -p "$CASE_DIR/bin"
cat > "$CASE_DIR/bin/gh" <<'SH'
#!/usr/bin/env bash
cat "$FAKE_PR_RESPONSE"
SH
chmod +x "$CASE_DIR/bin/gh"
cat > "$CASE_DIR/bin/git" <<'SH'
#!/usr/bin/env bash
[ "$REAL_GIT" != "$0" ] || exit 127
args=()
for arg in "$@"; do
  if [ "$arg" = 'https://github.com/contributor/fork.git' ]; then
    args+=("$FAKE_GIT_REMOTE")
  else
    args+=("$arg")
  fi
done
exec "$REAL_GIT" "${args[@]}"
SH
chmod +x "$CASE_DIR/bin/git"
git clone -q "$CASE_DIR/repo" "$CASE_DIR/trusted"
git -C "$CASE_DIR/trusted" checkout -q --detach "$base"
jq -n --arg base "$base" --arg head "$head" '{
  state:"open",base:{sha:$base,repo:{full_name:"agentdoc/base"}},
  head:{sha:$head,ref:"feature",repo:{full_name:"contributor/fork"}}
}' > "$CASE_DIR/pr.json"

PATH="$CASE_DIR/bin:$PATH" FAKE_PR_RESPONSE="$CASE_DIR/pr.json" \
  REAL_GIT="$REAL_GIT_BIN" FAKE_GIT_REMOTE="$CASE_DIR/repo" \
  TRUSTED_CHANGE_REQUEST="$CASE_DIR/request-a.json" \
  TRUSTED_CHANGE_AUTHORIZATION="$CASE_DIR/authorization.json" \
  TRUSTED_PREPARED_ENV="$CASE_DIR/prepared.env" \
  TRUSTED_PHASE_STATUS_PATH="$CASE_DIR/trusted-status.json" \
  GITHUB_EVENT_NAME=workflow_dispatch GITHUB_REPOSITORY=agentdoc/base \
  GITHUB_REF=refs/heads/main \
  GITHUB_WORKFLOW_REF='agentdoc/base/.github/workflows/trusted.yml@refs/heads/main' \
  GITHUB_SHA="$base" GITHUB_WORKSPACE="$CASE_DIR/trusted" GH_TOKEN=read-token \
    "$ROOT/scripts/prepare-trusted-change.sh"
jq -e --arg head "$head" --arg request "$request_digest" '
  .state == "authorized" and .head_revision == $head
  and .request_digest == $request
  and .authorizer.principal_id == "20000000-0000-0000-0000-000000000408"
  and .workload.session_id == "40000000-0000-0000-0000-000000000408"
  and .executor.qualification_id == "50000000-0000-0000-0000-000000000408"
' "$CASE_DIR/trusted-status.json" >/dev/null
grep -q '^TRUSTED_HEAD_REPOSITORY=contributor/fork$' "$CASE_DIR/prepared.env"
test ! -e "$CASE_DIR/contributor-code-ran"

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

jq '.authorized_paths = ["package.json"]' "$CASE_DIR/authorization.json" \
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
  GITHUB_ENV="$CASE_DIR/assert.env" GH_TOKEN=read-token \
    "$ROOT/scripts/assert-trusted-head.sh"
grep -q '^ADOC_TRUSTED_HEAD_CURRENT=true$' "$CASE_DIR/assert.env"

jq --arg head "$(printf 'f%.0s' {1..40})" '.head.sha = $head' \
  "$CASE_DIR/pr.json" > "$CASE_DIR/force-pushed.json"
: > "$CASE_DIR/assert.env"
PATH="$CASE_DIR/bin:$PATH" FAKE_PR_RESPONSE="$CASE_DIR/force-pushed.json" \
  TRUSTED_CHANGE_REQUEST="$CASE_DIR/request-a.json" \
  TRUSTED_PHASE_STATUS_PATH="$CASE_DIR/trusted-status.json" \
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

ln -s /etc/passwd "$CASE_DIR/repo/leak"
git -C "$CASE_DIR/repo" add leak
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
GITHUB_REPOSITORY=agentdoc/base ADOC_HEAD_REPOSITORY=contributor/fork \
ADOC_UNTRUSTED_SOURCE=fork ADOC_PR_NUMBER=17 ADOC_REQUESTED_BASE="$base" \
ADOC_HEAD="$symlink_head" "$ROOT/scripts/build-trusted-change-request.sh"
symlink_request="$(jq -r .request_digest "$CASE_DIR/symlink-request.json")"
jq --arg head "$symlink_head" --arg request "$symlink_request" '
  .head_revision = $head | .request_digest = $request
  | .authorized_paths = ["leak","package.json","scripts/postinstall.sh"]
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
grep -q 'fetch .*--no-auto-maintenance' "$ROOT/scripts/prepare-trusted-change.sh"

echo 'trusted/untrusted phase tests passed'
