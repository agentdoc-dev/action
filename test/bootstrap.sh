#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CASE_DIR="$(mktemp -d)"
trap 'rm -rf "$CASE_DIR"' EXIT
mkdir -p "$CASE_DIR/bin" "$CASE_DIR/repo"
git -C "$CASE_DIR/repo" init -q -b main
git -C "$CASE_DIR/repo" config user.name test
git -C "$CASE_DIR/repo" config user.email test@example.com
printf 'code\n' > "$CASE_DIR/repo/app.txt"
git -C "$CASE_DIR/repo" add app.txt
git -C "$CASE_DIR/repo" commit -qm base
base="$(git -C "$CASE_DIR/repo" rev-parse HEAD)"

cat > "$CASE_DIR/bin/adoc" <<'EOF'
#!/usr/bin/env bash
test "$1" = init
mkdir docs
printf 'version: 1\nmode: strict\ndocs_path: docs\noutputs:\n  dir: dist\nembeddings:\n  provider: local\n' > agentdoc.config.yaml
printf '# AgentDoc\n' > docs/index.adoc
EOF
chmod +x "$CASE_DIR/bin/adoc"

(cd "$CASE_DIR/repo" && PATH="$CASE_DIR/bin:$PATH" GITHUB_ENV="$CASE_DIR/env" \
  "$ROOT/scripts/bootstrap.sh")
head="$(git -C "$CASE_DIR/repo" rev-parse HEAD)"
test "$head" != "$base"
test "$(git -C "$CASE_DIR/repo" rev-parse HEAD^)" = "$base"
grep -q "^ADOC_HEAD=$head$" "$CASE_DIR/env"
git -C "$CASE_DIR/repo" diff --quiet

echo 'bootstrap source tests passed'
