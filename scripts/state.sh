#!/usr/bin/env bash

adoc_set_stage() { # stage, status
  local stage="$1" status="$2" ledger="$ADOC_RUN_DIR/stages.json"
  jq --arg stage "$stage" --arg status "$status" \
    '.[$stage] = $status' "$ledger" > "$ledger.tmp" && mv "$ledger.tmp" "$ledger"
}

adoc_fail() { # stage, code, safe message, safe help
  local stage="$1" code="$2" message="$3" help="$4"
  [ -s "$ADOC_RUN_DIR/failure.json" ] && return 0
  jq -n --arg stage "$stage" --arg code "$code" --arg message "$message" --arg help "$help" \
    '{stage:$stage,code:$code,severity:"error",message:$message,help:$help}' \
    > "$ADOC_RUN_DIR/failure.json.tmp"
  mv "$ADOC_RUN_DIR/failure.json.tmp" "$ADOC_RUN_DIR/failure.json"
  adoc_set_stage "$stage" error
  echo "::error::${code}: ${message}" >&2
}
