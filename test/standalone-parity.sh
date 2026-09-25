#!/usr/bin/env bash
# E8.2.T5 / D1: a Cloud-disconnected run is byte-identical to the pinned
# v2.0.0-alpha.21 release on both delivery paths. No golden-update path: any
# difference fails.
set -euo pipefail

RELEASE=v2.0.0-alpha.21
export GIT_AUTHOR_DATE='2026-07-23T12:00:00Z' GIT_COMMITTER_DATE='2026-07-23T12:00:00Z'
unset CLOUD_PROPOSAL_RESOLVER
# Reuse delivery.sh's frozen fixture, provider mocks and run_delivery.
DELIVERY_FIXTURE_ONLY=1 . "$(dirname "$0")/delivery.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$CASE_DIR" "$WORK"' EXIT
mkdir -p "$WORK/release"
git -C "$ROOT" archive "$RELEASE" scripts | tar -x -C "$WORK/release"
# Any Cloud request in disconnected mode is a failure.
printf '#!/usr/bin/env bash\necho "$*" >> %q\nexit 97\n' "$CASE_DIR/cloud-request.log" \
  > "$CASE_DIR/bin/curl"
chmod +x "$CASE_DIR/bin/curl"
# Freeze the PR-body stamp (deliver.sh reads receipt created_at, else wall clock).
printf '%s\n' '{"created_at":"2026-07-23T12:00:00Z"}' \
  > "$CASE_DIR/retained/receipt-$invocation_id.json"
cp -a "$CASE_DIR" "$WORK/fixture"

capture() { # tree mode dest
  local dest="$3" branch
  rm -rf "$CASE_DIR"
  cp -a "$WORK/fixture" "$CASE_DIR"
  mkdir -p "$dest"
  ROOT="$1" TEST_MODE="$2" run_delivery > "$dest.log" 2>&1
  test ! -e "$CASE_DIR/cloud-request.log"
  jq -e --arg mode "$2" '.status == "complete" and .mode == $mode' \
    "$CASE_DIR/out/delivery-status.json" > /dev/null
  branch="$(jq -r .branch "$CASE_DIR/out/delivery-status.json")"
  git --git-dir="$CASE_DIR/remote.git" cat-file -p "refs/heads/$branch" > "$dest/commit"
  git --git-dir="$CASE_DIR/remote.git" ls-tree -r "refs/heads/$branch" > "$dest/tree"
  for f in delivery-pr-body delivery-status.json delivery.md; do
    cp "$CASE_DIR/out/$f" "$dest/$f" 2> /dev/null || : > "$dest/$f.absent"
  done
  cp "$CASE_DIR/gh.log" "$dest/gh.log"
  # deliver.sh removes its delivery-pr-body on exit; diff the bytes gh received.
  [ "$2" = commit ] || cp "$CASE_DIR/pr-body.md" "$dest/delivery-pr-body.sent"
  # The PR comment/report composed from the delivered state.
  cp "$ROOT/test/fixture-assessment.json" "$CASE_DIR/retained/assessment.json"
  printf '%s\n' "$CASE_DIR/retained/assessment.json" > "$CASE_DIR/out/assessment-path"
  printf 'sha256:%064d\n' 9 > "$CASE_DIR/out/receipt-sha256"
  env PATH="$CASE_DIR/bin:$PATH" ADOC_RUN_DIR="$CASE_DIR/out" ADOC_RETAINED_DIR="$CASE_DIR/retained" \
    ADOC_INVOCATION_ID="$invocation_id" ADOC_HEAD="$assessed_head" \
    GITHUB_SERVER_URL=https://github.com GITHUB_REPOSITORY=agentdoc/test \
    GITHUB_RUN_ID=1 ADOC_ACTION_REF=parity PROPOSE=true PROPOSE_DELIVERY="$2" \
    REPORT_STYLE=compact ENFORCEMENT=advisory SCOPE=full ADOC_VERSION=v0.3.4 \
    "$1/scripts/compose.sh" >> "$dest.log" 2>&1
  test ! -e "$CASE_DIR/cloud-request.log"
  cp "$CASE_DIR/out/report.md" "$dest/report.md"
}

for mode in commit pr; do
  capture "$WORK/release" "$mode" "$WORK/$mode-release"
  capture "$ROOT" "$mode" "$WORK/$mode-current"
  diff -r "$WORK/$mode-release" "$WORK/$mode-current" || {
    echo "standalone-parity: $mode delivery differs from $RELEASE" >&2
    exit 1
  }
done
echo "standalone-parity: commit and pr outputs equal $RELEASE"
