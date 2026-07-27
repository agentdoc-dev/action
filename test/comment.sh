#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CASE_DIR="$(mktemp -d)"
status=0
trap 'status=$?; rm -rf "$CASE_DIR"; exit $status' EXIT
mkdir -p "$CASE_DIR/bin" "$CASE_DIR/out/comment-parts"
printf '[]\n' > "$CASE_DIR/comments.json"
: > "$CASE_DIR/mutations"

cat > "$CASE_DIR/bin/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [ "${1:-}" = api ] && [ "${2:-}" = repos/agentdoc/test/pulls/7 ]; then
  printf '%s\n' "$ADOC_HEAD"
  exit 0
fi
if [ "${1:-}" = api ] && [ "${2:-}" = user ]; then
  [ ! -f "$CASE_DIR/no-viewer" ] || exit 1
  if [ -f "$CASE_DIR/null-viewer" ]; then
    printf 'null\n'
    exit 0
  fi
  printf '42\n'
  exit 0
fi
if [ "${1:-}" = api ] && [ "${2:-}" = repos/agentdoc/test/issues/7/comments ]; then
  jq -s '.' "$CASE_DIR/comments.json"
  exit 0
fi
if [ "${1:-}" = api ] && [ "${2:-}" = -X ]; then
  method="$3"
  endpoint="$4"
  case "$method" in
    POST)
      for arg in "$@"; do case "$arg" in body=@*) body="${arg#body=@}" ;; esac; done
      next="$(jq '([.[].id] | max // 0) + 1' "$CASE_DIR/comments.json")"
      jq --argjson id "$next" --rawfile body "$body" \
        '. + [{id:$id,user:{id:42},body:$body}]' "$CASE_DIR/comments.json" \
        > "$CASE_DIR/comments.next"
      ;;
    PATCH)
      id="${endpoint##*/}"
      for arg in "$@"; do case "$arg" in body=@*) body="${arg#body=@}" ;; esac; done
      jq --argjson id "$id" --rawfile body "$body" \
        'map(if .id == $id then .body = $body else . end)' "$CASE_DIR/comments.json" \
        > "$CASE_DIR/comments.next"
      ;;
    DELETE)
      id="${endpoint##*/}"
      jq --argjson id "$id" 'map(select(.id != $id))' "$CASE_DIR/comments.json" \
        > "$CASE_DIR/comments.next"
      ;;
    *) exit 2 ;;
  esac
  mv "$CASE_DIR/comments.next" "$CASE_DIR/comments.json"
  printf '%s %s\n' "$method" "$endpoint" >> "$CASE_DIR/mutations"
  exit 0
fi
exit 3
EOF
chmod +x "$CASE_DIR/bin/gh"

printf '%s\n' '<!-- adoc:pr-report -->' 'main report' \
  > "$CASE_DIR/out/comment-parts/001.md"
printf '%s\n' '<!-- adoc:pr-report-part:agentdoc/test#7:002 -->' 'part two' \
  > "$CASE_DIR/out/comment-parts/002.md"
printf '%s\n' '<!-- adoc:pr-report-part:agentdoc/test#7:003 -->' 'part three' \
  > "$CASE_DIR/out/comment-parts/003.md"

export CASE_DIR ADOC_RUN_DIR="$CASE_DIR/out"
export ADOC_HEAD=1111111111111111111111111111111111111111
export GITHUB_REPOSITORY=agentdoc/test GITHUB_SERVER_URL=https://github.com
export PR_NUMBER=7 PATH="$CASE_DIR/bin:$PATH"

"$ROOT/scripts/comment.sh"
jq -e 'length == 3' "$CASE_DIR/comments.json" >/dev/null
test "$(wc -l < "$CASE_DIR/mutations" | tr -d ' ')" = 3

"$ROOT/scripts/comment.sh"
test "$(wc -l < "$CASE_DIR/mutations" | tr -d ' ')" = 3

rm "$CASE_DIR/out/comment-parts/002.md" "$CASE_DIR/out/comment-parts/003.md"
"$ROOT/scripts/comment.sh"
jq -e 'length == 1 and .[0].body == "<!-- adoc:pr-report -->\nmain report\n"' \
  "$CASE_DIR/comments.json" >/dev/null
test "$(grep -c '^DELETE ' "$CASE_DIR/mutations")" = 2

jq '. + [{id:99,user:{id:99},body:"<!-- adoc:pr-report-part:agentdoc/test#7:009 -->\nspoof"}]' \
  "$CASE_DIR/comments.json" > "$CASE_DIR/comments.next"
mv "$CASE_DIR/comments.next" "$CASE_DIR/comments.json"
"$ROOT/scripts/comment.sh"
jq -e 'any(.[]; .id == 99)' "$CASE_DIR/comments.json" >/dev/null

touch "$CASE_DIR/no-viewer"
PATH="$CASE_DIR/bin:$PATH" GITHUB_ACTIONS=false "$ROOT/scripts/comment.sh"
jq -e 'any(.[]; .id == 99)' "$CASE_DIR/comments.json" >/dev/null

rm "$CASE_DIR/no-viewer"
touch "$CASE_DIR/null-viewer"
printf '%s\n' '[{"id":100,"user":{"id":41898282},"body":"<!-- adoc:pr-report -->\nstale\n"}]' \
  > "$CASE_DIR/comments.json"
printf '%s\n' '<!-- adoc:pr-report -->' 'updated through bot fallback' \
  > "$CASE_DIR/out/comment-parts/001.md"
PATH="$CASE_DIR/bin:$PATH" GITHUB_ACTIONS=true "$ROOT/scripts/comment.sh"
jq -e '.[0].body == "<!-- adoc:pr-report -->\nupdated through bot fallback\n"' \
  "$CASE_DIR/comments.json" >/dev/null

echo 'multi-comment lifecycle tests passed'
