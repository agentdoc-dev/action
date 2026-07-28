#!/usr/bin/env bash
set -euo pipefail

[ ! -f agentdoc.config.yaml ] || exit 0

repo="$(git rev-parse --show-toplevel)"
[ -z "$(git -C "$repo" status --porcelain --untracked-files=all)" ] || {
  echo '::error::action.bootstrap_dirty: bootstrap requires a clean checkout'
  exit 1
}

adoc init >/dev/null
git add -- agentdoc.config.yaml docs/index.adoc
git -c user.name='github-actions[bot]' \
  -c user.email='41898282+github-actions[bot]@users.noreply.github.com' \
  -c commit.gpgsign=false commit -q -m 'docs(adoc): initialize repository knowledge'
head="$(git rev-parse HEAD)"
printf 'ADOC_HEAD=%s\n' "$head" >> "$GITHUB_ENV"
