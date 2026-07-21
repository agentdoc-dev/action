#!/usr/bin/env bash
set -euo pipefail

version="${1:?provider version is required}"
dest="${2:?provider destination is required}"
archive="${3:-}"
expected="${4:-}"

[ "$version" = 2.1.215 ] || {
  echo "::error::action.invalid_input: unsupported Claude Code version ${version}" >&2
  exit 1
}

case "$(uname -m)" in
  x86_64)
    package=claude-code-linux-x64
    pinned=cf00de4e2b500f7bf4fc6c57de19753d3639e23ee2177fe103d40614cf79ca29ddf61064bcbcafe9a53d59d1fbd3cf6cdc02027c8ea167be00157b41469e9bcd
    ;;
  aarch64 | arm64)
    package=claude-code-linux-arm64
    pinned=c327e705006466960a5d0dbe486aad251ab319f9b4eb337de09a1eb6ca896bc098bc266f9330297c1460ab3b0b00b181b4b2bb5dfd771dd103f923ddd51dd3f7
    ;;
  *)
    echo "::error::action.invalid_input: unsupported provider architecture $(uname -m)" >&2
    exit 1
    ;;
esac

mkdir -p "$dest"
if [ -z "$archive" ]; then
  archive="$dest/provider.tgz"
  expected="$pinned"
  curl --proto '=https' --tlsv1.2 --fail --silent --show-error --location \
    "https://registry.npmjs.org/@anthropic-ai/${package}/-/${package}-${version}.tgz" \
    --output "$archive"
fi
[ -n "$expected" ] || {
  echo '::error::action.provider_integrity_failed: expected SHA-512 is missing' >&2
  exit 1
}

if command -v sha512sum > /dev/null; then
  actual="$(sha512sum "$archive" | awk '{print $1}')"
else
  actual="$(shasum -a 512 "$archive" | awk '{print $1}')"
fi
[ "$actual" = "$expected" ] || {
  echo '::error::action.provider_integrity_failed: Claude Code archive SHA-512 mismatch' >&2
  exit 1
}

extract="$dest/extract"
mkdir -p "$extract"
tar -xzf "$archive" -C "$extract" package/claude
install -m 755 "$extract/package/claude" "$dest/claude"
rm -rf "$extract"
rm -f "$dest/provider.tgz"
printf '{"provider":"claude-code","package":"@anthropic-ai/%s","version":"%s","sha512":"%s"}\n' \
  "$package" "$version" "$actual" > "$(dirname "$dest")/provider-provenance.json"
