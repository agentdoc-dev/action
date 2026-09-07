#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
exec python3 -B "$ROOT/test/test_writeback_git.py" "$@"
