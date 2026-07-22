#!/usr/bin/env bash
set -euo pipefail

case "${ADOC_RUN_DIR:-}" in
  "${RUNNER_TEMP:?}"/agentdoc-private-inv_*) rm -rf -- "$ADOC_RUN_DIR" ;;
esac
