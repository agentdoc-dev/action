#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CASE_DIR="$(mktemp -d)"
trap 'rm -rf "$CASE_DIR"' EXIT
mkdir -p "$CASE_DIR/bin" "$CASE_DIR/out"

cat > "$CASE_DIR/bin/adoc" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  check)
    echo '**validation result**'
    if [ "${MOCK_CHECK_CODE:-0}" = 1 ]; then
      printf '%s\n' "${MOCK_CHECK_DIAG:-index.adoc:1:1: error[ref.broken] broken reference}" >&2
    fi
    exit "${MOCK_CHECK_CODE:-0}"
    ;;
  impacted-by)
    if [[ " $* " == *" --format json "* ]]; then
      case "${MOCK_IMPACT:-covered}" in
        mixed)
          echo '{"schema_version":"adoc.impacted.v0","changed_paths":["src/a.rs","src/b.rs"],"impacted":[{"id":"fixture.claim","reasons":[{"matched_path":"src/a.rs"}]}],"proof_obligations":[],"diagnostics":[]}'
          ;;
        empty)
          echo '{"schema_version":"adoc.impacted.v0","changed_paths":["src/a.rs"],"impacted":[],"proof_obligations":[],"diagnostics":[]}'
          ;;
        covered)
          echo '{"schema_version":"adoc.impacted.v0","changed_paths":["src/a.rs"],"impacted":[{"id":"fixture.claim","reasons":[{"matched_path":"src/a.rs"}]}],"proof_obligations":[],"diagnostics":[]}'
          ;;
        no-changes)
          echo '{"schema_version":"adoc.impacted.v0","changed_paths":["docs/a.adoc","agentdoc.config.yaml"],"impacted":[],"proof_obligations":[],"diagnostics":[]}'
          ;;
        missing-graph)
          echo '{"schema_version":"adoc.impacted.v0","changed_paths":["src/a.rs"],"impacted":[],"proof_obligations":[],"diagnostics":[{"severity":"error","code":"io.artifact_missing","message":"graph missing"}]}'
          exit 2
          ;;
        unavailable)
          echo '{"schema_version":"adoc.impacted.v0","changed_paths":[],"impacted":[],"proof_obligations":[],"diagnostics":[{"severity":"error","code":"impacted.ref_unresolvable","message":"base unavailable"}]}'
          exit 1
          ;;
        malformed) echo '{not-json' ;;
        wrong-schema)
          echo '{"schema_version":"future","changed_paths":[],"impacted":[],"proof_obligations":[],"diagnostics":[]}'
          ;;
        derive-error)
          echo '{"schema_version":"adoc.impacted.v0","changed_paths":[7],"impacted":[],"proof_obligations":[],"diagnostics":[]}'
          ;;
      esac
    else
      echo '**impact result**'
      exit "${MOCK_MARKDOWN_CODE:-0}"
    fi
    ;;
  review)
    echo '{"diff":{"changed":[],"created":[]}}'
    ;;
  contradictions)
    echo '{"contradictions":[]}'
    ;;
esac
EOF
chmod +x "$CASE_DIR/bin/adoc"

git -C "$CASE_DIR" init -q
git -C "$CASE_DIR" config user.name test
git -C "$CASE_DIR" config user.email test@example.com
echo base > "$CASE_DIR/file"
mkdir -p "$CASE_DIR/nested"
echo source > "$CASE_DIR/nested/index.adoc"
git -C "$CASE_DIR" add file nested/index.adoc
git -C "$CASE_DIR" commit -qm base
git -C "$CASE_DIR" update-ref refs/remotes/origin/base HEAD
echo head > "$CASE_DIR/file"
git -C "$CASE_DIR" add file
git -C "$CASE_DIR" commit -qm head

export PATH="$CASE_DIR/bin:$PATH"
export RUNNER_TEMP="$CASE_DIR/out"
export GITHUB_STEP_SUMMARY="$CASE_DIR/summary.md"
export GITHUB_BASE_REF=base

reset_case() {
  find "$RUNNER_TEMP" -mindepth 1 -delete
  export MOCK_IMPACT="$1" MOCK_CHECK_CODE="${2:-0}" MOCK_CHECK_DIAG="${3:-}"
  echo "${4:-0}" > "$RUNNER_TEMP/adoc-build-code"
}

run_report() { (cd "$CASE_DIR" && "$ROOT/scripts/report.sh"); }
status_is() { jq -e --arg value "$1" '.status == $value' "$RUNNER_TEMP/adoc-impact-status.json" >/dev/null; }
report_has_no_coverage_claim() { ! grep -qi 'all .*paths are covered' "$RUNNER_TEMP/report.md"; }

expect_enforce() {
  local expected="$1" enforcement="$2" actual
  set +e
  ENFORCEMENT="$enforcement" "$ROOT/scripts/enforce.sh" >/dev/null 2>&1
  actual=$?
  set -e
  [ "$actual" = "$expected" ] || {
    echo "expected enforce exit $expected, got $actual ($MOCK_IMPACT, $enforcement)" >&2
    exit 1
  }
}

reset_case mixed
run_report
status_is complete
grep -qx 'src/b.rs' "$RUNNER_TEMP/uncovered-paths"

reset_case empty
run_report
status_is complete
grep -qx 'src/a.rs' "$RUNNER_TEMP/uncovered-paths"
"$ROOT/scripts/compose.sh"
report_has_no_coverage_claim

reset_case covered
run_report
status_is complete
"$ROOT/scripts/compose.sh"
grep -q 'all assessed paths are covered' "$RUNNER_TEMP/report.md"

reset_case no-changes
run_report
status_is no_changes
"$ROOT/scripts/compose.sh"
grep -q 'No changed assessable paths' "$RUNNER_TEMP/report.md"
echo 'validated stale-object draft' > "$RUNNER_TEMP/proposed-drafts.md"
"$ROOT/scripts/compose.sh"
grep -q 'validated stale-object draft' "$RUNNER_TEMP/report.md"

reset_case covered
unset GITHUB_BASE_REF
run_report
status_is unavailable
jq -e '.reason == "missing-base"' "$RUNNER_TEMP/adoc-impact-status.json" >/dev/null
"$ROOT/scripts/compose.sh"
grep -q 'Assessment unavailable' "$RUNNER_TEMP/report.md"
report_has_no_coverage_claim
export GITHUB_BASE_REF=base

reset_case covered
export GITHUB_BASE_REF=missing
run_report
status_is unavailable
jq -e '.reason == "unresolvable-base"' "$RUNNER_TEMP/adoc-impact-status.json" >/dev/null
export GITHUB_BASE_REF=base

reset_case unavailable
run_report
status_is unavailable
expect_enforce 2 advisory

reset_case missing-graph
run_report
status_is unavailable
jq -e '.reason == "command-failed"' "$RUNNER_TEMP/adoc-impact-status.json" >/dev/null
"$ROOT/scripts/compose.sh"
report_has_no_coverage_claim
expect_enforce 2 advisory

reset_case missing-graph 1 'error[ref.broken] broken reference' 1
run_report
jq -e '.status == "unavailable" and .reason == "head-invalid"' \
  "$RUNNER_TEMP/adoc-impact-status.json" >/dev/null
"$ROOT/scripts/compose.sh"
report_has_no_coverage_claim
expect_enforce 0 advisory
expect_enforce 1 strict

for mode in malformed wrong-schema derive-error; do
  reset_case "$mode"
  run_report
  status_is error
  "$ROOT/scripts/compose.sh"
  grep -q 'internal result error' "$RUNNER_TEMP/report.md"
  report_has_no_coverage_claim
  expect_enforce 2 advisory
done

export SCOPE=diff
reset_case covered 1 'outside.adoc:1:1: error[schema.outside] outside the diff'
run_report
grep -qx 0 "$RUNNER_TEMP/adoc-gate-code"

reset_case covered 1 $'outside.adoc:1:1: error[schema.outside] outside the diff\nerror[config-missing] no source span'
run_report
grep -qx 1 "$RUNNER_TEMP/adoc-gate-code"

reset_case covered 1 'file:1:1: error[schema.changed] changed file'
run_report
grep -qx 1 "$RUNNER_TEMP/adoc-gate-code"

reset_case covered 1 'index.adoc:4:2: error[schema.bad-code] nested path'
(cd "$CASE_DIR/nested" && "$ROOT/scripts/report.sh") 2> "$RUNNER_TEMP/nested.diag"
grep -q '^nested/index.adoc:4:2: error\[schema.bad-code\]' "$RUNNER_TEMP/nested.diag"

node - "$ROOT/problem-matcher.json" <<'EOF'
const matcher = require(process.argv[2]).problemMatcher[0].pattern[0];
const match = new RegExp(matcher.regexp).exec('src/nested/file.adoc:12:3: error[schema.bad-code] bad');
if (!match || match[1] !== 'src/nested/file.adoc' || match[5] !== 'schema.bad-code') process.exit(1);
EOF
register_line="$(grep -n 'Register problem matcher' "$ROOT/action.yml" | cut -d: -f1)"
remove_line="$(grep -n 'Remove problem matcher' "$ROOT/action.yml" | cut -d: -f1)"
propose_line="$(grep -n 'Propose Knowledge Objects' "$ROOT/action.yml" | cut -d: -f1)"
[ "$register_line" -lt "$remove_line" ] && [ "$remove_line" -lt "$propose_line" ]
unset SCOPE

reset_case covered
echo validation > "$RUNNER_TEMP/check.md"
echo contradictions > "$RUNNER_TEMP/contradictions.md"
"$ROOT/scripts/compose.sh"
jq -e '.status == "error" and .reason == "invalid-status"' \
  "$RUNNER_TEMP/adoc-impact-status.json" >/dev/null
report_has_no_coverage_claim
expect_enforce 2 advisory

reset_case covered
run_report
: > "$GITHUB_STEP_SUMMARY"
"$ROOT/scripts/compose.sh"
echo '_Delivered in https://example.test/pr/99_' >> "$RUNNER_TEMP/report.md"
cat "$RUNNER_TEMP/report.md" >> "$GITHUB_STEP_SUMMARY"
cmp "$RUNNER_TEMP/report.md" "$GITHUB_STEP_SUMMARY"
cat > "$CASE_DIR/bin/gh" <<'EOF'
#!/usr/bin/env bash
for arg in "$@"; do
  case "$arg" in
    body=@*) cp "${arg#body=@}" "$RUNNER_TEMP/comment-body.md" ;;
  esac
done
EOF
chmod +x "$CASE_DIR/bin/gh"
export GITHUB_REPOSITORY=agentdoc/test PR_NUMBER=1
"$ROOT/scripts/comment.sh"
cmp "$RUNNER_TEMP/report.md" "$RUNNER_TEMP/comment-body.md"

compose_line="$(grep -n -- '- name: Compose report' "$ROOT/action.yml" | cut -d: -f1)"
deliver_line="$(grep -n -- '- name: Deliver drafts' "$ROOT/action.yml" | cut -d: -f1)"
summary_line="$(grep -n -- '- name: Write job summary' "$ROOT/action.yml" | cut -d: -f1)"
comment_line="$(grep -n -- '- name: Upsert pull request comment' "$ROOT/action.yml" | cut -d: -f1)"
finalize_line="$(grep -n -- '- name: Finalize bounded report' "$ROOT/action.yml" | cut -d: -f1)"
[ "$compose_line" -lt "$deliver_line" ] \
  && [ "$deliver_line" -lt "$finalize_line" ] \
  && [ "$finalize_line" -lt "$summary_line" ] \
  && [ "$summary_line" -lt "$comment_line" ]

echo 'fail-honest report tests passed'
