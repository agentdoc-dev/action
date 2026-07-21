#!/usr/bin/env bash
set -euo pipefail

case "${ADOC_RUN_DIR:-}" in
  "${RUNNER_TEMP:?}"/agentdoc.*) rm -rf -- "$ADOC_RUN_DIR" ;;
esac
