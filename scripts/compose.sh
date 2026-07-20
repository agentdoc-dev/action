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
