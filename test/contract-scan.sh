#!/usr/bin/env bash
# Contract-registry completeness scan (E0.3.T5): every wire code this Action
# emits — action.* / attestation.* reason codes and adoc.*.vN envelope ids —
# must have a row in the canonical registry owned by agentdoc-dev/adoc
# (docs/roadmap/v10/CONTRACT-REGISTRY.md). Fails on any unregistered code.
set -euo pipefail
export LC_ALL=C # comm/sort agree on one collation everywhere

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

registry_ref="${ADOC_REGISTRY_REF:-main}"
[[ "$registry_ref" =~ ^[A-Za-z0-9._-]+$ ]] || {
  echo '::error::contract-scan: invalid AgentDoc registry ref' >&2
  exit 1
}
REGISTRY_URL="https://raw.githubusercontent.com/agentdoc-dev/adoc/$registry_ref/docs/roadmap/v10/CONTRACT-REGISTRY.md"
registry="${ADOC_REGISTRY:-}"
if [ -z "$registry" ]; then
  registry="$WORK_DIR/CONTRACT-REGISTRY.md"
  curl -fsSL "$REGISTRY_URL" -o "$registry" || {
    echo "::error::contract-scan: could not fetch the contract registry from $REGISTRY_URL" >&2
    exit 1
  }
fi

# Registered ids: backticked first cells of table rows INSIDE the registry's
# anchored blocks only — a prose line shaped like a row cannot widen the
# allowlist, and the dispositions block (removed codes) never registers.
registered_ids() {
  awk '
    /<!-- registry:dispositions -->/ { skip = 1 }
    /<!-- \/registry:dispositions -->/ { skip = 0; next }
    /<!-- registry:/ { in_block = 1; next }
    /<!-- \/registry:/ { in_block = 0; next }
    in_block && !skip && /^\| `/ { sub(/^\| `/, ""); sub(/`.*/, ""); print }
  ' "$registry" | sort -u
}

# Codes emitted anywhere in the tree under $1 except test/ — a new emitting
# surface (a helper dir, a root script) is scanned the day it appears. The
# charset is deliberately wide: a malformed code (uppercase, digits) scans
# and then fails as unregistered instead of slipping the net.
emitted_codes() {
  local dir="$1"
  grep -rhoE '\b(action|attestation)\.[A-Za-z0-9_]+\b|\badoc\.[a-z_.]+\.v[0-9]+\b' \
    "$dir" --exclude-dir=.git --exclude-dir=test 2>/dev/null |
    grep -vx 'action\.yml' | # the manifest file name, not a wire code
    sort -u
}

scan() {
  local dir="$1"
  # Variable-built codes ("action.${reason}") can carry anything past a
  # textual scan — refuse the pattern outright; emit whole literals.
  if grep -rnE '(action|attestation)\.\$' "$dir" --exclude-dir=.git --exclude-dir=test 2>/dev/null; then
    echo '::error::contract-scan: variable-built wire code — emit registered literals instead' >&2
    return 1
  fi
  local unregistered
  unregistered="$(comm -23 <(emitted_codes "$dir") <(registered_ids))"
  if [ -n "$unregistered" ]; then
    echo "::error::contract-scan: wire codes emitted without a registry row:" >&2
    printf '%s\n' "$unregistered" >&2
    return 1
  fi
}

# Self-checks first (red fixtures): a scan that cannot fail proves nothing.
mkdir -p "$WORK_DIR/fixture/scripts"
printf 'echo "::error::action.fixture_unregistered_code: boom"\n' \
  > "$WORK_DIR/fixture/scripts/rogue.sh"
if scan "$WORK_DIR/fixture" >/dev/null 2>&1; then
  echo '::error::contract-scan: the unregistered-code fixture passed — the scan is broken' >&2
  exit 1
fi
mkdir -p "$WORK_DIR/variable/scripts"
printf 'echo "::error::action.${reason}: boom"\n' > "$WORK_DIR/variable/scripts/rogue.sh"
if scan "$WORK_DIR/variable" >/dev/null 2>&1; then
  echo '::error::contract-scan: the variable-built-code fixture passed — the tripwire is broken' >&2
  exit 1
fi

scan "$ROOT"
echo 'contract-scan: every emitted wire code is registered'
