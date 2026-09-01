#!/usr/bin/env bash
set -euo pipefail

version="${1:?Codex version is required}"
dest="${2:?Codex destination is required}"
archive="${3:-}"
expected="${4:-}"

[ "$version" = 0.149.1 ] || {
  echo "::error::action.invalid_input: unsupported Codex version ${version}" >&2
  exit 1
}

case "$(uname -m)" in
  x86_64)
    variant=linux-x64
    target=x86_64-unknown-linux-musl
    pinned=39fe5f19882beed00cb328fabe15dbe3f44cfd4a00dd9abc04b7a05010c2d3d50dcb55d32c660fff65c3f945fccf7aa1d0d0f0c587428c52167433628ca66081
    ;;
  aarch64 | arm64)
    variant=linux-arm64
    target=aarch64-unknown-linux-musl
    pinned=3aac547d9d5356f1ddd7ccc73ca2bff19465a64f15cb5d6683908c1da2f135695d4dbc152260cab522d64fe9bc9b834ce52cf83db8ed64cad54ff45fa415bf99
    ;;
  *)
    echo "::error::action.invalid_input: unsupported Codex architecture $(uname -m)" >&2
    exit 1
    ;;
esac

mkdir -p "$dest"
if [ -z "$archive" ]; then
  archive="$dest/provider.tgz"
  expected="$pinned"
  curl --proto '=https' --tlsv1.2 --fail --silent --show-error --location \
    "https://registry.npmjs.org/@openai/codex/-/codex-${version}-${variant}.tgz" \
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
  echo '::error::action.provider_integrity_failed: Codex archive SHA-512 mismatch' >&2
  exit 1
}

extract="$dest/extract"
mkdir -p "$extract"
member="package/vendor/$target/bin/codex"
tar -xzf "$archive" -C "$extract" "$member"
install -m 755 "$extract/$member" "$dest/codex"
rm -rf "$extract"
rm -f "$dest/provider.tgz"
printf '{"provider":"codex","package":"@openai/codex","variant":"%s","version":"%s","sha512":"%s"}\n' \
  "$variant" "$version" "$actual" > "$(dirname "$dest")/codex-provenance.json"
