#!/usr/bin/env bash
# Installs the adoc binary from the adoc repository's GitHub Releases.
set -euo pipefail

ADOC_REPO="${ADOC_REPO:-agentdoc-dev/adoc}"

if [ "$(uname -s)" != "Linux" ]; then
  echo "::error::agentdoc-dev/action supports Linux runners only (got $(uname -s))"
  exit 1
fi

case "$(uname -m)" in
  x86_64) TARGET="x86_64-unknown-linux-gnu" ;;
  aarch64 | arm64) TARGET="aarch64-unknown-linux-gnu" ;;
  *)
    echo "::error::unsupported architecture $(uname -m); supported: x86_64, aarch64"
    exit 1
    ;;
esac

BIN_DIR="$RUNNER_TEMP/adoc-bin"
mkdir -p "$BIN_DIR"
cd "$BIN_DIR"

# gh authenticates with GH_TOKEN — no unauthenticated api.github.com rate
# limits, and an omitted tag resolves to the latest release natively.
TAG_ARGS=()
[ "$ADOC_VERSION" != "latest" ] && TAG_ARGS=("$ADOC_VERSION")
if ! gh release download ${TAG_ARGS[@]+"${TAG_ARGS[@]}"} --repo "$ADOC_REPO" \
  --pattern "adoc-*-${TARGET}.tar.gz" --pattern "adoc-*-${TARGET}.tar.gz.sha256"; then
  echo "::error::could not download adoc ${ADOC_VERSION} (${TARGET}) from ${ADOC_REPO} releases"
  exit 1
fi

sha256sum -c ./*.sha256
tar -xzf ./adoc-*-"${TARGET}".tar.gz
chmod +x adoc

echo "$BIN_DIR" >> "$GITHUB_PATH"
echo "installed $(ls adoc-*-"${TARGET}".tar.gz) from $ADOC_REPO"
