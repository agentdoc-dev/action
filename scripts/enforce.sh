#!/usr/bin/env bash
set -uo pipefail

OUT="$RUNNER_TEMP"
build_code="$(cat "$OUT/adoc-build-code" 2>/dev/null || echo invalid)"
gate_code="$(cat "$OUT/adoc-gate-code" 2>/dev/null || echo invalid)"
if ! [[ "$build_code" =~ ^[0-9]+$ && "$gate_code" =~ ^[0-9]+$ ]]; then
  echo "::error::AgentDoc internal status is missing or invalid"
  exit 2
fi

impact_status="$(jq -er '.status' "$OUT/adoc-impact-status.json" 2>/dev/null || echo error)"
impact_reason="$(jq -er '.reason // ""' "$OUT/adoc-impact-status.json" 2>/dev/null || true)"
case "$impact_status" in
  complete | no_changes) ;;
  unavailable)
    if [ "$impact_reason" != "head-invalid" ]; then
      echo "::error::AgentDoc change assessment was unavailable — see the report and job log"
      exit 2
    fi
    ;;
  *)
    echo "::error::AgentDoc change assessment returned invalid or malformed state"
    exit 2
    ;;
esac

if [ "$build_code" -ge 2 ]; then
  echo "::error::adoc could not build the project (exit $build_code) — see the job log; this fails even in advisory mode"
  exit "$build_code"
fi
if [ "$gate_code" -ge 2 ]; then
  echo "::error::adoc could not validate the project (exit $gate_code) — see the job log; this fails even in advisory mode"
  exit "$gate_code"
fi
if [ "${ENFORCEMENT:-advisory}" = strict ] && [ "$gate_code" != 0 ]; then
  echo "::error::adoc check found errors and enforcement is strict"
  exit "$gate_code"
fi
propose_code="$(cat "$OUT/adoc-propose-code" 2>/dev/null || echo 0)"
if [ "${PROPOSE_ON_ERROR:-warn}" = fail ] && [ "$propose_code" != 0 ]; then
  echo "::error::proposal generation failed and propose-on-error is fail"
  exit 1
fi
