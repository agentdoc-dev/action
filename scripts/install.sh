#!/usr/bin/env bash
# Installs the adoc binary from the adoc repository's GitHub Releases.
set -euo pipefail

ADOC_REPO="${ADOC_REPO:-agentdoc-dev/adoc}"

if [ "$(uname -s)" != "Linux" ]; then
  echo "::error::agentdoc/action supports Linux runners only (got $(uname -s))"
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

VERSION="$ADOC_VERSION"
if [ "$VERSION" = "latest" ]; then
  VERSION="$(curl -fsSL "https://api.github.com/repos/${ADOC_REPO}/releases/latest" | jq -r .tag_name)"
fi

ARCHIVE="adoc-${VERSION}-${TARGET}.tar.gz"
URL="https://github.com/${ADOC_REPO}/releases/download/${VERSION}/${ARCHIVE}"

BIN_DIR="$RUNNER_TEMP/adoc-bin"
mkdir -p "$BIN_DIR"
cd "$BIN_DIR"

curl -fsSL -o "$ARCHIVE" "$URL"
curl -fsSL -o "$ARCHIVE.sha256" "$URL.sha256"
sha256sum -c "$ARCHIVE.sha256"
tar -xzf "$ARCHIVE"
chmod +x adoc

echo "$BIN_DIR" >> "$GITHUB_PATH"
echo "installed adoc $VERSION ($TARGET) from $ADOC_REPO"
