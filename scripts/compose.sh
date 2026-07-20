#!/usr/bin/env bash
# Assembles the PR report body from the artifacts left by report.sh and
# propose.sh, and appends it to the job summary. Pure composition — when no
# LLM drafts exist the Proposed section falls back to the mechanical
# uncovered-path list, byte-for-byte as before the propose step existed.
set -uo pipefail

OUT="$RUNNER_TEMP"

{
  echo '<!-- adoc:pr-report -->'
  echo '## AgentDoc PR Report'
  echo
  echo '### Validation'
  echo
  cat "$OUT/check.md"
  echo
  echo '### Impacted Knowledge'
  echo
  cat "$OUT/impacted.md"
  echo
  # Drift suspicion: verified Knowledge Objects citing paths this PR changes,
  # badged with whether the PR also touched the object itself. Deterministic
  # and report-only — the semantic judgment stays with the reviewer.
  if jq -e '(.impacted // []) | length > 0' "$OUT/impacted.json" > /dev/null 2>&1; then
    touched="$(jq -c '[.diff.changed[].id, .diff.created[].id]' "$OUT/review.json" 2> /dev/null || echo '')"
    jq -r --arg touched "$touched" '
      (if $touched == "" then null else ($touched | fromjson) end) as $t
      | "**Drift suspicion** — \(.impacted | length) verified Knowledge Object(s) cite paths this PR changes; re-verify or update them:",
        "",
        (.impacted[]
         | .id as $id
         | (if $t == null then ""
            elif ($t | index($id)) then " — ✏️ updated in this PR"
            else " — ⚠️ unreviewed in this PR" end) as $badge
         | "- `\(.id)`\(if .owner then " (owner: \(.owner))" else "" end)\($badge) — cites \([.reasons[].matched_path] | unique | map("`" + . + "`") | join(", "))")
    ' "$OUT/impacted.json"
    echo
  fi
  if [ -s "$OUT/contradictions.md" ]; then
    echo '### Contradictions'
    echo
    cat "$OUT/contradictions.md"
    echo
  fi
  echo '### Proposed Knowledge Objects'
  echo
  if [ -s "$OUT/proposed-drafts.md" ]; then
    cat "$OUT/proposed-drafts.md"
  elif [ -s "$OUT/uncovered-paths" ]; then
    echo 'This PR touches source paths no Knowledge Object claims impact over:'
    echo
    sed 's/^/- `/;s/$/`/' "$OUT/uncovered-paths"
    echo
    echo 'Consider authoring a Knowledge Object with an `impacts:` field for each.'
  else
    echo '_None — all changed paths are covered._'
  fi
  echo
  echo "<sub>adoc ${ADOC_VERSION:-?} · enforcement: ${ENFORCEMENT:-advisory} · scope: ${SCOPE:-full}</sub>"
} > "$OUT/report.md"

cat "$OUT/report.md" >> "$GITHUB_STEP_SUMMARY"
exit 0
