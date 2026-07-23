#!/usr/bin/env bash
# V9.3.2 proves canonical patches and renders them for review. Governed Git
# delivery is deliberately activated by V9.3.3, not by the model pipeline.
set -uo pipefail

OUT="${ADOC_RUN_DIR:-${RUNNER_TEMP:?}}"
mode="${PROPOSE_DELIVERY:-comment}"

delivery_status() { # status, reason
  jq -n --arg status "$1" --arg mode "$mode" --arg reason "$2" '{
    status:$status,mode:$mode,reason:$reason,
    delivery_commit:null,url:null
  }' > "$OUT/delivery-status.json"
}

case "$mode" in
  comment)
    delivery_status skipped comment_only
    ;;
  commit | pr)
    if [ ! -s "$OUT/patch-manifest.ndjson" ]; then
      delivery_status skipped no_valid_proposals
    else
      delivery_status skipped governed_delivery_deferred
      echo "::warning::AgentDoc: ${mode} delivery is reserved for the V9.3.3 governed-delivery slice; canonical patches remain in the PR comment"
    fi
    ;;
  *)
    echo "::error::AgentDoc: unsupported propose-delivery '${mode}'"
    exit 1
    ;;
esac

exit 0
