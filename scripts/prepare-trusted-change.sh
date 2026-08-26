#!/usr/bin/env bash
# Re-authorizes an untrusted request under protected workflow code, then
# fetches the exact contributor head as inert Git data without credentials.
set -euo pipefail
export LC_ALL=C
umask 077
SELF="$(cd "$(dirname "$0")" && pwd)"

if [ "${ADOC_GIT_ASKPASS:-false}" = true ]; then
  case "${1:-}" in
    *Username*) printf '%s\n' x-access-token ;;
    *) printf '%s\n' "${ADOC_GIT_PASSWORD:?}" ;;
  esac
  exit 0
fi

request="${TRUSTED_CHANGE_REQUEST:?}"
authorization="${TRUSTED_CHANGE_AUTHORIZATION:?}"
prepared="${TRUSTED_PREPARED_ENV:?}"
status="${TRUSTED_PHASE_STATUS_PATH:?}"
workspace="${GITHUB_WORKSPACE:?}"

fail_trusted() { # code, message, remediation
  jq -n --arg code "$1" --arg remediation "$3" '{
    state:"failed",reason_code:$code,remediation:$remediation,
    head_revision:null,request_digest:null,authorizer:null,policy:null,
    workload:null,executor:null,context_request_digest:null,
    context_digest:null,result_digest:null,workflow:null
  }' > "$status"
  echo "::error::$1: $2" >&2
  exit 2
}

expire_head() { # expected, observed
  jq -n --arg expected "$1" --arg observed "$2" \
    --arg request_digest "$(jq -r '.request_digest // empty' "$request")" '{
      state:"expired_after_head_change",reason_code:"trusted.head_changed",
      remediation:"Authorize and run the new exact pull-request head.",
      head_revision:$expected,observed_head_revision:$observed,
      request_digest:$request_digest,authorizer:null,policy:null,
      workload:null,executor:null,context_request_digest:null,
      context_digest:null,result_digest:null,workflow:null
    }' > "$status"
  echo '::warning::trusted.head_changed: pull request head changed after authorization' >&2
  exit 3
}

[ "${GITHUB_EVENT_NAME:-}" = workflow_dispatch ] \
  || fail_trusted trusted.base_workflow_required \
    'trusted execution requires workflow_dispatch from the protected base branch' \
    'Dispatch the protected base-branch trusted workflow.'
[[ "${GITHUB_REPOSITORY:-}" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ \
  && "${GITHUB_REF:-}" == refs/heads/* \
  && "${GITHUB_SHA:-}" =~ ^[0-9a-f]{40}$ ]] \
  || fail_trusted trusted.base_workflow_required \
    'base workflow provenance is incomplete' \
    'Run the workflow from a protected branch in the base repository.'
case "${GITHUB_WORKFLOW_REF:-}" in
  "${GITHUB_REPOSITORY}"/.github/workflows/*@"${GITHUB_REF}") ;;
  *) fail_trusted trusted.base_workflow_required \
    'workflow code is not bound to the protected base branch' \
    'Dispatch the workflow file committed on the protected base branch.' ;;
esac
[ "$(git -C "$workspace" rev-parse --verify 'HEAD^{commit}' 2>/dev/null)" = "$GITHUB_SHA" ] \
  || fail_trusted trusted.base_workflow_required \
    'checked-out workflow revision does not match GitHub provenance' \
    'Check out the protected base revision with persisted credentials disabled.'
if git -C "$workspace" config --show-origin --get-regexp \
  '^http\..*\.extraheader$' >/dev/null 2>&1; then
  fail_trusted trusted.persisted_checkout_credentials \
    'checkout credentials persisted into the repository' \
    'Set actions/checkout persist-credentials to false.'
fi

request_keys='["assessment_digest","base_ref","base_repository","base_revision","context_request","context_request_digest","evaluation_date","head_repository","head_revision","pull_request","request_digest","untrusted_source","version"]'
if ! jq -e --argjson expected "$request_keys" '
  type == "object" and keys == $expected and .version == 1
  and (.base_repository | test("^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$"))
  and (.head_repository | test("^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$"))
  and (.untrusted_source | IN("fork","dependabot"))
  and (.pull_request | type == "number" and floor == . and . > 0)
  and (.base_ref | type == "string" and length > 0)
  and (.base_revision | test("^[0-9a-f]{40}$"))
  and (.head_revision | test("^[0-9a-f]{40}$"))
  and (.evaluation_date | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}$"))
  and (.assessment_digest | test("^sha256:[0-9a-f]{64}$"))
  and (.context_request_digest | test("^sha256:[0-9a-f]{64}$"))
  and (.request_digest | test("^sha256:[0-9a-f]{64}$"))
  and (.context_request | type == "array")
  and all(.context_request[];
    type == "object" and keys == ["path","repository"]
    and (.repository | type == "string")
    and (.path | type == "string" and length > 0)
    and ((.path | startswith("/")) | not)
    and ((.path | test("(^|/)\\.\\.(/|$)")) | not)
    and ((.path | test("[\u0000-\u001f\u007f]")) | not))
  and .context_request == (.context_request | sort_by(.repository,.path))
  and (.context_request | length) == (.context_request | unique_by(.repository,.path) | length)
' "$request" >/dev/null 2>&1; then
  fail_trusted trusted.request_invalid 'trusted request contract is invalid' \
    'Regenerate the request in the secret-free untrusted phase.'
fi
request_digest="sha256:$(jq -cS 'del(.request_digest)' "$request" | sha256sum | awk '{print $1}')"
context_digest="sha256:$(jq -cS '.context_request' "$request" | sha256sum | awk '{print $1}')"
[ "$request_digest" = "$(jq -r .request_digest "$request")" \
  ] && [ "$context_digest" = "$(jq -r .context_request_digest "$request")" ] \
  || fail_trusted trusted.request_digest_invalid 'trusted request digest is invalid' \
    'Regenerate the request from the exact untrusted assessment.'

authorization_keys='["authorized_paths","authorizer","decision","executor","expires_at","head_revision","policy","request_digest","version","workload"]'
if ! jq -e --argjson expected "$authorization_keys" \
  --arg request "$request_digest" --arg head "$(jq -r .head_revision "$request")" '
  type == "object" and keys == $expected and .version == 1
  and .decision == "authorized" and .request_digest == $request
  and .head_revision == $head
  and (.expires_at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"))
  and (.authorizer | type == "object"
    and keys == ["authorization_decision_id","principal_id"]
    and all(.[]; type == "string"
      and test("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")))
  and (.policy | type == "object" and keys == ["digest","version"]
    and (.version | type == "string" and length > 0)
    and (.digest | test("^sha256:[0-9a-f]{64}$")))
  and (.workload | type == "object" and keys == ["principal_id","session_id"]
    and all(.[]; type == "string"
      and test("^sha256:[0-9a-f]{64}$")))
  and (.executor | type == "object"
    and keys == ["config_digest","model","provider","qualification_id"]
    and (.qualification_id | test("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"))
    and (.provider | type == "string" and length > 0)
    and (.model | type == "string" and length > 0)
    and (.config_digest | test("^sha256:[0-9a-f]{64}$")))
  and (.authorized_paths | type == "array"
    and all(.[]; type == "string" and length > 0)
    and . == sort
    and length == (unique | length))
' "$authorization" >/dev/null 2>&1; then
  fail_trusted trusted.authorization_invalid 'trusted authorization is invalid' \
    'Record a fresh explicit authorization for this exact request and head.'
fi
expires_at="$(jq -r .expires_at "$authorization")"
expires_epoch="$(jq -ner --arg value "$expires_at" '
  $value as $timestamp
  | ($timestamp | fromdateiso8601) as $epoch
  | select(($epoch | todateiso8601) == $timestamp)
  | $epoch
')" || fail_trusted trusted.authorization_invalid \
  'trusted authorization expiry is not a real UTC timestamp' \
  'Record a fresh explicit authorization with a valid expiry.'
[ "$expires_epoch" -gt "$(date -u +%s)" ] \
  || fail_trusted trusted.authorization_expired 'trusted authorization expired' \
    'Record a fresh authorization for the current head.'

base_repo="$(jq -r .base_repository "$request")"
head_repo="$(jq -r .head_repository "$request")"
server_url="${GITHUB_SERVER_URL:-https://github.com}"
server_url="${server_url%/}"
base_ref="$(jq -r .base_ref "$request")"
base="$(jq -r .base_revision "$request")"
head="$(jq -r .head_revision "$request")"
pr="$(jq -r .pull_request "$request")"
[ "$base_repo" = "$GITHUB_REPOSITORY" ] \
  || fail_trusted trusted.repository_mismatch 'request names another base repository' \
    'Dispatch the trusted workflow in the request base repository.'
pr_json="$(gh api "repos/${base_repo}/pulls/${pr}" 2>/dev/null)" \
  || fail_trusted trusted.github_identity_unavailable \
    'authenticated pull-request identity read failed' \
    'Retry with a repository-scoped GitHub token.'
untrusted_source="$(jq -r .untrusted_source "$request")"
if ! jq -e --arg base_repo "$base_repo" --arg head_repo "$head_repo" \
  --arg base_ref "$base_ref" --arg base "$base" --arg source "$untrusted_source" '
    .state == "open" and .base.repo.full_name == $base_repo
    and .head.repo.full_name == $head_repo
    and .base.ref == $base_ref and .base.sha == $base
    and (.head.ref | type == "string" and length > 0)
    and (if $source == "dependabot" then
      $head_repo == $base_repo and .user.login == "dependabot[bot]"
    else $head_repo != $base_repo end)
  ' <<< "$pr_json" >/dev/null 2>&1; then
  fail_trusted trusted.github_identity_invalid \
    'authenticated pull-request identity does not match the request' \
    'Regenerate the request from the current pull request.'
fi
observed_head="$(jq -r .head.sha <<< "$pr_json")"
[ "$observed_head" = "$head" ] || expire_head "$head" "$observed_head"
head_ref="$(jq -r .head.ref <<< "$pr_json")"
git check-ref-format "refs/heads/$base_ref" >/dev/null 2>&1 \
  || fail_trusted trusted.github_identity_invalid 'pull-request base ref is invalid' \
    'Regenerate the request from a valid pull request.'
git check-ref-format "refs/heads/$head_ref" >/dev/null 2>&1 \
  || fail_trusted trusted.github_identity_invalid 'pull-request head ref is invalid' \
    'Regenerate the request from a valid pull request.'
[ "$GITHUB_REF" = "refs/heads/$base_ref" ] && [ "$GITHUB_SHA" = "$base" ] \
  || fail_trusted trusted.base_workflow_required \
    'trusted workflow does not run from the authenticated pull-request base revision' \
    'Dispatch the workflow from the exact protected pull-request base revision.'
bindings="$("$SELF/trusted-run-bindings.sh" 2>/dev/null)" \
  || fail_trusted trusted.authorization_invalid \
    'effective trusted policy or workload identity is invalid' \
    'Regenerate authorization in the current protected workflow run.'
if ! jq -e --argjson bindings "$bindings" '
  .policy == $bindings.policy and .workload == $bindings.workload
' "$authorization" >/dev/null 2>&1; then
  fail_trusted trusted.authorization_invalid \
    'authorization does not match the effective policy and workload session' \
    'Authorize the exact settings in the current protected workflow run.'
fi

fetched_ref="refs/agentdoc/untrusted/$head"
fetch=(git -C "$workspace" -c credential.helper= -c credential.interactive=false
  fetch --force --no-tags --no-write-fetch-head --no-auto-maintenance
  "${server_url}/${head_repo}.git"
  "refs/heads/${head_ref}:${fetched_ref}")
fetch_code=0
private_fork="$(jq -r '.head.repo.private == true' <<< "$pr_json")"
if [ "$untrusted_source" = dependabot ] || [ "$private_fork" = true ]; then
  git_token="${GH_TOKEN:-${GITHUB_TOKEN:-}}"
  [ -n "$git_token" ] || fail_trusted trusted.github_identity_unavailable \
    'scoped private-repository fetch credential is unavailable' \
    'Retry with a repository-scoped GitHub token.'
  ADOC_GIT_ASKPASS=true ADOC_GIT_PASSWORD="$git_token" GIT_ASKPASS="$0" \
    GIT_ASKPASS_REQUIRE=force GIT_TERMINAL_PROMPT=0 "${fetch[@]}" >/dev/null \
    || fetch_code=$?
  git_token=''
else
  env -u GH_TOKEN -u GITHUB_TOKEN GIT_TERMINAL_PROMPT=0 "${fetch[@]}" >/dev/null \
    || fetch_code=$?
fi
if [ "${fetch_code:-0}" -ne 0 ]; then
  fail_trusted trusted.head_fetch_failed 'exact untrusted head fetch failed' \
    'Ensure the authorized exact head is readable and retry.'
fi
fetched_head="$(git -C "$workspace" rev-parse --verify "${fetched_ref}^{commit}" 2>/dev/null)"
[ "$fetched_head" = "$head" ] || expire_head "$head" "$fetched_head"
git -C "$workspace" cat-file -e "${base}^{commit}" 2>/dev/null \
  || fail_trusted trusted.base_revision_unavailable 'request base revision is unavailable' \
    'Check out the protected base branch with complete history.'

scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
jq -r --arg repository "$base_repo" '
  .context_request[]
  | select(.repository != $repository) | .repository
' "$request" > "$scratch/foreign"
[ ! -s "$scratch/foreign" ] \
  || fail_trusted trusted.context_unauthorized \
    'semantic context request names another repository' \
    'Authorize only paths from the pull request base repository.'
jq -r '.context_request[].path' "$request" | sort -u > "$scratch/requested"
git -C "$workspace" diff --name-only -z "$base...$fetched_ref" > "$scratch/changed.raw" \
  || fail_trusted trusted.context_invalid 'exact changed paths are unavailable' \
    'Regenerate the request from the exact pull request revisions.'
: > "$scratch/changed"
while IFS= read -r -d '' path; do
  [[ "$path" != /* && "$path" != *$'\n'* && "$path" != *$'\r'* \
    && "$path" != *$'\t'* && "$path" != .. && "$path" != ../* \
    && "$path" != */.. && "$path" != */../* ]] \
    || fail_trusted trusted.context_unauthorized 'unsafe changed path refused' \
      'Remove path escapes or control characters from the change.'
  printf '%s\n' "$path" >> "$scratch/changed"
done < "$scratch/changed.raw"
sort -u "$scratch/changed" -o "$scratch/changed"
cmp -s "$scratch/requested" "$scratch/changed" \
  || fail_trusted trusted.context_invalid \
    'semantic context request does not equal the exact changed path set' \
    'Regenerate the request from the exact pull request head.'
while IFS= read -r path; do
  jq -e --arg path "$path" '.authorized_paths | index($path) != null' \
    "$authorization" >/dev/null 2>&1 \
    || fail_trusted trusted.context_unauthorized \
      "path is outside authorization: $path" \
      'Authorize the exact path or omit it from trusted semantic processing.'
  mode="$(git -C "$workspace" ls-tree "$fetched_ref" -- "$path" | awk '{print $1}')"
  [ "$mode" != 120000 ] \
    || fail_trusted trusted.context_unauthorized \
      "symlink content is outside trusted context: $path" \
      'Replace the symlink with an authorized in-repository file.'
done < "$scratch/requested"

jq -n --arg head "$head" --arg request_digest "$request_digest" \
  --arg context_request_digest "$context_digest" \
  --argjson authorizer "$(jq -c .authorizer "$authorization")" \
  --argjson policy "$(jq -c .policy "$authorization")" \
  --argjson workload "$(jq -c .workload "$authorization")" \
  --argjson executor "$(jq -c .executor "$authorization")" \
  --arg workflow_ref "$GITHUB_WORKFLOW_REF" --arg workflow_sha "$GITHUB_SHA" '{
    state:"authorized",reason_code:null,remediation:null,
    head_revision:$head,request_digest:$request_digest,
    authorizer:$authorizer,policy:$policy,workload:$workload,executor:$executor,
    context_request_digest:$context_request_digest,
    context_digest:null,result_digest:null,
    workflow:{ref:$workflow_ref,sha:$workflow_sha}
  }' > "$status"
{
  printf 'TRUSTED_BASE_REPOSITORY=%s\n' "$base_repo"
  printf 'TRUSTED_HEAD_REPOSITORY=%s\n' "$head_repo"
  printf 'TRUSTED_PULL_REQUEST=%s\n' "$pr"
  printf 'TRUSTED_BASE_REVISION=%s\n' "$base"
  printf 'TRUSTED_HEAD_REVISION=%s\n' "$head"
  printf 'TRUSTED_BASE_REF=%s\n' "$base_ref"
  printf 'TRUSTED_HEAD_REF=%s\n' "$head_ref"
  printf 'TRUSTED_FETCHED_REF=%s\n' "$fetched_ref"
  printf 'TRUSTED_EVALUATION_DATE=%s\n' "$(jq -r .evaluation_date "$request")"
  printf 'TRUSTED_ASSESSMENT_DIGEST=%s\n' "$(jq -r .assessment_digest "$request")"
  printf 'TRUSTED_REQUEST_DIGEST=%s\n' "$request_digest"
  printf 'TRUSTED_AUTHORIZATION_EXPIRES_AT=%s\n' "$(jq -r .expires_at "$authorization")"
} > "$prepared"
