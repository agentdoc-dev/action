#!/usr/bin/env bash
# Installs and records the exact AgentDoc binary used by this invocation.
set -uo pipefail

ADOC_REPO="${ADOC_REPO:-agentdoc-dev/adoc}"
SELF="$(cd "$(dirname "$0")" && pwd)"
export ADOC_RUN_DIR="${ADOC_RUN_DIR:-${RUNNER_TEMP:?}}"
mkdir -p "$ADOC_RUN_DIR"
[ -f "$ADOC_RUN_DIR/stages.json" ] \
  || printf '%s\n' '{"install":"pending"}' > "$ADOC_RUN_DIR/stages.json"
source "$SELF/state.sh"

fail_install() {
  adoc_fail install action.install_failed "$1" 'Use AgentDoc v0.3.1 or newer with a published binary and checksum.'
  printf 'ADOC_PIPELINE_READY=false\n' >> "$GITHUB_ENV"
  exit 0
}

[ "$(uname -s)" = Linux ] || fail_install "agentdoc-dev/action supports Linux runners only (got $(uname -s))"
case "$(uname -m)" in
  x86_64) target=x86_64-unknown-linux-gnu ;;
  aarch64 | arm64) target=aarch64-unknown-linux-gnu ;;
  *) fail_install "unsupported architecture $(uname -m); supported: x86_64, aarch64" ;;
esac

bin_dir="$ADOC_RUN_DIR/adoc-bin"
mkdir -p "$bin_dir"
cd "$bin_dir" || fail_install 'could not enter the private binary directory'
tag_args=()
[ "$ADOC_VERSION" != latest ] && tag_args=("$ADOC_VERSION")
gh release download ${tag_args[@]+"${tag_args[@]}"} --repo "$ADOC_REPO" \
  --pattern "adoc-*-${target}.tar.gz" --pattern "adoc-*-${target}.tar.gz.sha256" \
  || fail_install "could not download AgentDoc ${ADOC_VERSION} for ${target}"
sha256sum -c ./*.sha256 || fail_install 'the downloaded AgentDoc archive checksum did not match'
tar -xzf ./adoc-*-${target}.tar.gz || fail_install 'the AgentDoc archive could not be extracted'
chmod +x adoc

version_output="$(./adoc --version 2>/dev/null)" || fail_install 'the installed AgentDoc binary did not report a version'
resolved="${version_output#adoc }"
[[ "$version_output" =~ ^adoc\ [0-9]+\.[0-9]+\.[0-9]+([+-][A-Za-z0-9.-]+)?$ ]] \
  || fail_install 'the installed AgentDoc binary reported an invalid version'
lowest="$(printf '0.3.1\n%s\n' "$resolved" | sort -V | head -n 1)"
[ "$lowest" = 0.3.1 ] || fail_install "AgentDoc ${resolved} is older than the required v0.3.1"
binary_sha="sha256:$(sha256sum adoc | awk '{print $1}')"
jq -n --arg requested "$ADOC_VERSION" --arg resolved "v$resolved" --arg sha "$binary_sha" \
  '{requested_version:$requested,resolved_version:$resolved,binary_sha256:$sha}' \
  > "$ADOC_RUN_DIR/adoc-toolchain.json"
adoc_set_stage install complete
printf '%s\n' "$bin_dir" >> "$GITHUB_PATH"
echo "installed AgentDoc v${resolved} for ${target}"
exit 0
