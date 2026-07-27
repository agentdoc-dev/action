#!/usr/bin/env bash
set -euo pipefail

OUT="${ADOC_RUN_DIR:-$RUNNER_TEMP}"
REPORT="$OUT/report.md"
PARTS="$OUT/comment-parts"
WORK="$(mktemp -d "$OUT/report-parts.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

comment_limit=52000
summary_limit=950000
max_comments="${COMMENT_MAX_COMMENTS:-5}"
[ "$max_comments" = unlimited ] && max_comments=0

length() { jq -Rs length "$1"; }
normalize() {
  awk '
    NF {
      if (blank && seen) print ""
      print
      blank = 0
      seen = 1
      next
    }
    { blank = 1 }
  ' "$1" > "$1.normalized"
  mv "$1.normalized" "$1"
}

awk -v dir="$WORK/blocks" '
  BEGIN { system("mkdir -p \"" dir "\"") }
  /^<!-- adoc:block:[a-z0-9-]+ -->$/ {
    if (file != "") close(file)
    kind = $0
    sub(/^<!-- adoc:block:/, "", kind)
    sub(/ -->$/, "", kind)
    count++
    file = sprintf("%s/%04d.%s.md", dir, count, kind)
    next
  }
  {
    if (file == "") {
      count = 1
      kind = "legacy"
      file = sprintf("%s/%04d.%s.md", dir, count, kind)
    }
    print >> file
  }
' "$REPORT"

mkdir -p "$WORK/drafts"
: > "$WORK/omitted-kinds"
part=1
draft="$WORK/drafts/$(printf '%03d' "$part").md"
: > "$draft"

for block in "$WORK"/blocks/*.md; do
  block_size="$(length "$block")"
  if [ "$block_size" -gt "$comment_limit" ]; then
    awk '
      BEGIN { total = 0 }
      {
        bytes = length($0) + 1
        if (bytes <= 4096 && total + bytes <= 50000) {
          print
          total += bytes
        }
      }
    ' "$block" > "$block.bounded"
    printf '\n> ⚠️ Oversized record detail omitted. See the retained assessment artifact.\n' \
      >> "$block.bounded"
    mv "$block.bounded" "$block"
    block_size="$(length "$block")"
  fi

  current_size="$(length "$draft")"
  if [ "$current_size" -gt 0 ] \
    && [ $((current_size + block_size + 2)) -gt "$comment_limit" ]; then
    if [ "$max_comments" -gt 0 ] && [ "$part" -ge "$max_comments" ]; then
      kind="${block##*/}"
      kind="${kind#*.}"
      printf '%s\n' "${kind%.md}" >> "$WORK/omitted-kinds"
      continue
    fi
    part=$((part + 1))
    draft="$WORK/drafts/$(printf '%03d' "$part").md"
    : > "$draft"
  fi
  [ ! -s "$draft" ] || printf '\n\n' >> "$draft"
  cat "$block" >> "$draft"
done

omission_note=''
if [ -s "$WORK/omitted-kinds" ]; then
  omission_note='> ⚠️ **Report detail omitted at the configured comment limit:** '
  while read -r count kind; do
    case "$kind" in
      semantic-consistent) label='consistent semantic finding(s)' ;;
      audit) label='audit section(s)' ;;
      knowledge-object) label='affected-knowledge group(s)' ;;
      knowledge-signal) label='knowledge-signal group(s)' ;;
      changed-path) label='changed-path group(s)' ;;
      *) label="${kind//-/ } block(s)" ;;
    esac
    [ "$omission_note" = '> ⚠️ **Report detail omitted at the configured comment limit:** ' ] \
      || omission_note="${omission_note}; "
    omission_note="${omission_note}${count} ${label}"
  done < <(sort "$WORK/omitted-kinds" | uniq -c)
  omission_note="${omission_note}. Set \`comment-max-comments: unlimited\` to retain every detail."
  printf '\n\n%s\n' "$omission_note" >> "$draft"
fi

rm -rf "$PARTS"
mkdir -m 700 "$PARTS"
total="$(find "$WORK/drafts" -type f -name '*.md' -size +0c | wc -l | tr -d ' ')"
[ "$total" -gt 0 ]
index=0
for source in "$WORK"/drafts/*.md; do
  [ -s "$source" ] || continue
  index=$((index + 1))
  target="$PARTS/$(printf '%03d' "$index").md"
  if [ "$index" -eq 1 ]; then
    cp "$source" "$target"
  else
    {
      printf '<!-- adoc:pr-report-part:%s#%s:%03d -->\n' \
        "${GITHUB_REPOSITORY:-unknown/unknown}" "${ADOC_PR_NUMBER:-${PR_NUMBER:-unknown}}" "$index"
      printf '## AgentDoc PR Report — Details %d of %d\n\n' "$index" "$total"
      cat "$source"
    } > "$target"
  fi
  normalize "$target"
  [ "$(length "$target")" -le 60000 ]
done
cp "$PARTS/001.md" "$REPORT"

: > "$OUT/job-summary.md"
: > "$WORK/summary-omitted"
for block in "$WORK"/blocks/*.md; do
  current_size="$(length "$OUT/job-summary.md")"
  block_size="$(length "$block")"
  if [ $((current_size + block_size + 2)) -le "$summary_limit" ]; then
    [ "$current_size" -eq 0 ] || printf '\n\n' >> "$OUT/job-summary.md"
    cat "$block" >> "$OUT/job-summary.md"
  else
    kind="${block##*/}"
    kind="${kind#*.}"
    printf '%s\n' "${kind%.md}" >> "$WORK/summary-omitted"
  fi
done
if [ -s "$WORK/summary-omitted" ]; then
  printf "\n\n> ⚠️ Job-summary detail omitted at GitHub's 1 MiB limit. The PR comment series contains the bounded report.\n" \
    >> "$OUT/job-summary.md"
fi
normalize "$OUT/job-summary.md"
[ "$(length "$OUT/job-summary.md")" -le 1000000 ]
