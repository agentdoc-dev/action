# Plan: PR response UX (GitHub Action report surfaces)

Slice: `pr-response-ux` · branch `feat/pr-response-ux` · worktree `.worktrees/action-pr-ux` · base `31baf6f`.
Design source: Claude Design project `019df5e7-43dd-7359-aeb0-4992a112e416`, screen
`GitHub Action - PR responses.html` (scenarios s1–s9 in `gha-scenarios.js`) plus the
`UX Review - GitHub Action PR responses.html` findings. Local copy of every template:
scratchpad `design/md/*.md` (session-only; the plan quotes what matters).

Status: plan only. Planning does not authorize implementation.

## 1. Objective

Replace the current glyph-first, section-per-record PR report with the designed
"verdict first, addressed actions second, facts third, integrity last" layout across
every surface the action writes: sticky PR comment (and overflow parts), job summary,
step-level annotations, follow-up PR body, delivery commit message, bootstrap PR body.
Seven verdicts; one assessed-head stamp on line one; no @-mentions; words not glyphs;
one `<details>` level; real table headers; proposal cards with "would move" tense
before delivery and past tense after; fork summary addressed to maintainers.

### Exclusions (recorded, not silently dropped)

- **"Since `<sha>`" delta line.** Needs the previous receipt; the action does not read
  it today. UX review item 6, explicitly deferred to a decision. Not in this slice.
- **Job rename** ("AgentDoc knowledge sync / sync" in s4). The job name belongs to the
  consumer workflow. We only ship the titled step-level `::error`, and document the
  naming recommendation in README.
- **`adoc patch --apply-record`** (s3 "Apply locally"). Not an adoc command. The card
  uses the existing loop `adoc patch --apply <record> --artifact <graph>` exactly as
  `scripts/propose.sh:445` runs it. The scenario note itself calls `--apply-record` a
  proposed convenience; file it against adoc, not here.
- **`structural_gate_failed` step code** (s9 step). Not a registered reason code. The titled error
  uses the existing `action.structural_errors_changed` / `action.structural_errors_full`.
- **Badge SVG hosting.** `https://agentdoc.dev/badge/pr/*.svg` is outside this repo.
  This slice ships the `<picture>` markup behind an input (see D1) and the SVGs as
  repo files under `assets/badge/pr/` for the site to publish; it does not deploy them.
- **CODEOWNERS-derived suggestions** in the bootstrap body. UX review already removed it.
- **Check-run API (`checks: write`).** Documented trade-off in the design; no change.

## 2. Verified state and seams

All line numbers at `31baf6f`.

| Seam | File | Facts verified |
|---|---|---|
| Report renderer | `scripts/render-assessment.jq` | `block($kind;$body)` (l.9), `details($open;$summary;$body)` (l.10), `report_brief` (l.70–110) emits `block("summary"; "<!-- adoc:pr-report -->\n## AgentDoc PR Report…")` with a 3-column glyph table; `knowledge_update_result` (l.49) picks delivery/proposal state; sections `validation`, `assessment`, `changed_paths`, `owners_and_obligations` (l.193), `semantic_review`, `proposal`, `semantic_coverage`, `affected_knowledge` (l.307), `knowledge_signals` (l.335), `receipt` (l.394, kind `audit`, contains `<sub>` footer). Final concat l.404. `disposition` (l.180) wording "human disposition required". `evidence_link` (l.219) already builds permalinks at `$head`/`$comparison_base`. |
| Composer | `scripts/compose.sh` | jq args l.13–31 (no `sync_policy`, no receipt timestamp, no delivery url). Appends `semantic-assessment`, `negative-verdict` (acceptance sentence l.88), `cloud-sync`, `baseline` blocks. Failure path l.128–145 writes `> ❌ **Assessment unavailable.**`. |
| Proposal drafts | `scripts/propose.sh` | `skip()` l.20–31 writes `proposed-drafts.md`; final writer l.700–755 emits `<!-- adoc:block:proposal -->` + `<details><summary>➕/✏️ …</summary><pre><code>json` + proof obligations + `<sub>canonical patches by claude-code · model …</sub>`. Manifest `$OUT/patch-manifest.ndjson` fields `.path .check_path .operation .target .placement_path`. Existing apply loop l.445. |
| Delivery | `scripts/deliver.sh` | commit message l.406–418 (`docs(adoc): propose Knowledge Objects [skip-adoc-propose]`, trailers `AgentDoc-Proposal-Owner/Assessed-Head/Assessment-SHA256`); `write_pr_body` l.440–473 with HTML-comment markers l.442–443; closed/prior-PR detection greps those exact markers l.507–509, 555–557, 571–572; `delivery.md` text; `fallback()` `::warning::`. |
| Bounding | `scripts/finalize-report.sh` | comment_limit 52000 (l.10), summary_limit 950000 (l.11), part header `## AgentDoc PR Report — Details %d of %d` (l.128), omission notes l.70/95/152, priority by block kind. |
| Gate | `scripts/enforce.sh` | single untitled `::error::<reason>: AgentDoc concluded non-green…` from `.conclusion.reason_codes[0] // .failure.code`. Reason set in `scripts/finalize.sh:560–586` (`action.knowledge_sync_pending` when proposal complete + delivery complete under required sync). |
| Fork notice | `scripts/preflight.sh:361` | `::notice::AgentDoc: model provider and delivery disabled for fork or Dependabot pull request`. `ADOC_UNTRUSTED_CHANGE` env is available to later steps (`action.yml:365`). |
| Receipt | `scripts/finalize.sh` | `created_at` ISO UTC (l.69) stored as `.created_at` (l.605/640) → source of the stamp time. |
| Comment | `scripts/comment.sh` | keyed by first-line `<!-- adoc:pr-report -->` and `<!-- adoc:pr-report-part:REPO#PR:NNN -->`; stale-head skip. Unchanged. |
| Job summary | `action.yml:575–578` | `cat job-summary.md >> $GITHUB_STEP_SUMMARY`. |
| Matcher | `problem-matcher.json` | `^(.+):(\d+):(\d+): (error|warning)\[([\w.-]+)\] (.+)$`. Unchanged. |
| Tests | `test/report.sh` (golden `test/golden-report-compact.md`, heading/marker greps, XSS escapes, negative-verdict block, oversize bounding, part markers), `test/comment.sh`, `test/delivery.sh` (marker greps l.361/430/698), `test/fail-honest.sh`, `test/proposal-scenario.sh`, `test/bootstrap.sh`. CI jobs in `.github/workflows/ci.yml`: `report`, `security`, `fail-honest`, `receipt`, `semantic`. |
| Docs | `README.md` "Reading the report" l.342–371, "Fork pull requests" l.389+. |

Inputs available to the renderer that the design needs and today are not passed:
`SYNC_POLICY`, receipt `created_at`, delivery `url`/`commit`/`branch`, proposal set
digest, semantic executor identity (`semantic-status.json` `.primary/.fallback`).

## 3. Acceptance mapping (design scenario → code)

| Scenario | Verdict / alert | Where it is produced | Tracer |
|---|---|---|---|
| s1 Consistent | `[!TIP]` **Consistent with knowledge.** | `report_brief` verdict fn; acceptance sentence moves from `compose.sh` negative-verdict block into Run details | T1 |
| s2 Review needed | `[!WARNING]` **Knowledge review needed.** + "What to do" per principal | `report_brief` + new `what_to_do` def (owners from `.required_reviewers`, obligations, uncovered paths) | T1, T2 |
| s3 Update proposed | `[!IMPORTANT]` **N knowledge updates proposed.** + cards + canonical JSON collapsed | `report_brief` (proposal complete, delivery comment) + `propose.sh` drafts writer | T1, T3 |
| s4 Sync pending | `[!WARNING]` **Knowledge sync pending.** + "Delivered to #N" table; red via `action.knowledge_sync_pending` | `report_brief` (needs `$sync_policy` + delivery state) + `deliver.sh` delivery.md | T1, T4 |
| s4-pr follow-up body | ownership marker, WARNING, objects table, Why, Bindings, `<sub>` | `deliver.sh write_pr_body` | T4 |
| s4-step | `::error title=AgentDoc knowledge sync::action.knowledge_sync_pending: …` | `enforce.sh` reason→title/message map | T4 |
| s5 Update delivered (commit) | `[!TIP]` **Knowledge update committed.** + bold "pull before pushing again" | `report_brief` + `deliver.sh` delivery.md | T1, T4 |
| s5-commit | `docs(adoc): update N Knowledge Objects for #PR` + trailers | `deliver.sh` commit message (keep all existing trailers) | T4 |
| s6 Fork job summary | leading `[!NOTE]` **Fork pull request #N.** + maintainers' What to do + Trusted change request table | `compose.sh` (untrusted preamble) + `finalize-report.sh` (summary-only) | T5 |
| s6-notice | `::notice title=AgentDoc::Fork PR #N: …` | `preflight.sh:361` | T5 |
| s7 Unavailable | `[!CAUTION]` **Assessment unavailable.** + Failure/Detail/Assessment/Receipt table | `compose.sh` failure path | T5 |
| s7-step | `::error title=AgentDoc assessment::<code>: <message>` | `enforce.sh` reads `failure.json` `.message/.help` | T5 |
| s8-pr Bootstrap body | `<!-- adoc:bootstrap-owner… -->` + round/coverage table | `deliver.sh write_pr_body` bootstrap branch | T4 |
| s9 Blocked | `[!CAUTION]` **Blocked by structural errors.** + Diagnostics open | `report_brief` (`$enforcement`, `$scope`, `.validation`) + `validation` def → Diagnostics | T1, T2 |
| s9-step | `::error title=AgentDoc structure::` + `action.structural_errors_full` or `action.structural_errors_changed` + `: …` | `enforce.sh` | T5 |
| Anatomy: overflow parts | `## AgentDoc PR Report · Details n of m` + one-line pointer to verdict | `finalize-report.sh:128` | T6 |
| Anatomy: badge | `<picture>` + stamp, off by default (D1) | `report_brief`, new input `comment-badge` | T6 |
| README | "Reading the report" rewritten to the new anatomy | T6 |

Verdict decision function (single source of truth, jq, illustrative):

```jq
# illustrative — lands in render-assessment.jq next to report_brief
def verdict:
  (semantic_findings | map(select(.classification != "consistent")) | length) as $actionable
  | (proposal_state) as $p | (delivery_state) as $d
  | if .validation.errors_full > 0 and $enforcement == "strict"
        and ((.validation.errors_changed // 0) + (.validation.errors_unattributed // 0) > 0 or $scope == "full")
      then {name:"Blocked", alert:"CAUTION"}
    elif $d.status == "complete" and $d.mode == "pr" and $sync_policy == "required"
      then {name:"Sync pending", alert:"WARNING"}
    elif $d.status == "complete" then {name:"Update delivered", alert:"TIP"}
    elif $p.status == "complete" or $p.status == "partial" then {name:"Update proposed", alert:"IMPORTANT"}
    elif ((.summary.uncovered // 0) + (.summary.provisional // 0)
          + (.proof_obligations // [] | length) + $actionable) > 0
      then {name:"Review needed", alert:"WARNING"}
    else {name:"Consistent", alert:"TIP"} end;
```

"Unavailable" is the `compose.sh` failure path (no assessment), never this function.
Builder must verify the exact `.validation.*` field names in `test/fixture-assessment.json`
before relying on `errors_changed`/`errors_unattributed` (the brief today uses only
`errors_full`; the strict/diff gate logic lives in `finalize.sh`, reuse its reasoning).

## 4. Affected files and interfaces

- `scripts/render-assessment.jq` — `verdict`, `stamp`, `what_to_do`, new `report_brief`
  (verdict alert + 5-row `| Area | Result |` table), `coverage` (replaces `changed_paths`,
  gains Disposition column from `path_dispositions`), `affected_knowledge` (Decision column
  first; folds `knowledge_signals` evidence/contradiction facts in), `diagnostics`
  (replaces `validation`), `receipt` → Run details `| Field | Value |` table + footer
  `<sub>`. Block kinds kept where `finalize-report.sh` priorities depend on them
  (`summary`, `owner`, `proof-obligation`, `semantic-*`, `proposal*`, `knowledge-*`,
  `signal-*`, `audit`); new kinds `what-to-do`, `coverage`, `diagnostics` added to the
  priority list in `finalize-report.sh`.
- `scripts/compose.sh` — pass `--arg sync_policy`, `--arg created_at` (from receipt),
  `--slurpfile semantic_status`, delivery fields; drop the standalone
  `semantic-assessment`/`negative-verdict`/`cloud-sync`/`baseline` sections in favour of
  Run-details rows (the negative-verdict *gate conditions* stay: they decide whether the
  acceptance sentence is emitted). Failure path → s7 layout.
- `scripts/propose.sh` — drafts writer → s3 cards; `skip()` text → "none proposed ·
  no follow-up PR expected"; canonical JSON collapsed after cards; no nested details.
- `scripts/deliver.sh` — `delivery.md` → "Delivered to #N" / "Committed in `sha`" table;
  `write_pr_body` → s4-pr/s8-pr content **below the existing three HTML-comment markers**
  (markers unchanged: closed-PR detection and `test/delivery.sh` depend on them; the
  design's `<!-- adoc:proposal-owner:… -->` is not adopted); commit subject/body → s5-commit
  keeping every existing trailer and `[skip-adoc-propose]`.
- `scripts/enforce.sh` — reason → `title` + human message table; fallbacks unchanged.
- `scripts/preflight.sh` — fork notice text (s6-notice).
- `scripts/finalize-report.sh` — part title, pointer line, new block kinds, fork preamble
  written to job summary only.
- `action.yml` — input `comment-badge` (default `false`), env plumbed to compose.
- `assets/badge/pr/*.svg` — 14 badge SVGs + 2 avatars from the design project (only 5
  fetched so far; builder fetches the rest or the coordinator supplies them).
- Tests: `test/report.sh` + golden, `test/comment.sh` (unchanged unless first-line
  contract changes — it must not), `test/delivery.sh`, `test/fail-honest.sh`,
  `test/proposal-scenario.sh`, `test/bootstrap.sh`.
- `README.md` — "Reading the report" rewrite; fork section mentions the summary preamble;
  input table gains `comment-badge`.

Invariants that must survive (tests assert them):
1. First line of the primary comment is exactly `<!-- adoc:pr-report -->`; part
   comments start with `<!-- adoc:pr-report-part:REPO#PR:NNN -->`. The stamp/badge is
   line 2+.
2. No `<!-- adoc:block:` marker reaches a comment or summary.
3. All owner/object/path strings pass `escaped`/`code`; the XSS fixture owner
   `<img src=x onerror=alert(1)>` renders as `&lt;img …&gt;`.
4. Follow-up PR body lines 1–3 remain the three `AgentDoc-*` HTML comments; commit
   message keeps the three trailers and `[skip-adoc-propose]`.
5. Report is byte-identical for order-permuted assessment input.

## 5. Implementation order (one commit per tracer)

- **T1 Verdict, stamp, result table, Run details, footer.** `render-assessment.jq`
  `verdict`/`stamp`/`report_brief`/`receipt`; `compose.sh` args and folded blocks; golden
  regenerated; `test/report.sh` greps updated. Everything else still renders old
  sections beneath (temporary mixed state is acceptable inside the branch, not at PR).
- **T2 What to do, Coverage, Affected knowledge, Diagnostics.** Replaces
  `changed_paths`, `owners_and_obligations`, `affected_knowledge`, `knowledge_signals`,
  `validation`. Tests for owner bullets (permalink at head, exact edit text), uncovered
  Author bullet, Diagnostics open when errors > 0, Blocked verdict under strict.
- **T3 Proposal cards.** `propose.sh` writer + `skip()`; `report.sh` proposal
  assertions; `test/proposal-scenario.sh`.
- **T4 Delivery surfaces.** `deliver.sh` delivery.md, PR body, commit message; sync
  pending verdict; `enforce.sh` titled errors for sync pending; `test/delivery.sh`.
- **T5 Failure and fork.** `compose.sh` failure path; `enforce.sh` titles for
  assessment/structure failures; `preflight.sh` notice; fork summary preamble;
  `test/fail-honest.sh`.
- **T6 Overflow parts, badge input, assets, README.**

T1 → T2 → T3 are sequential on `render-assessment.jq`/golden (one owner). T4 and T5
touch disjoint files from T3 and can run in parallel with it after T1 lands.

## 6. Failure and security behaviour

- Every model-authored string (`headline`, `rationale`) renders italic after
  `_Model:_`; classification labels are plain text from a fixed map, never the model's
  words. All strings go through `escaped(n)`/`code(n)` with the existing clip limits.
- No `@` is ever emitted before a reviewer name; reviewer of record renders as
  `` `alice` `` in code. Owner group also in code.
- Permalinks use `$server_url/$repository/blob/$head/<url_path>#L<n>` exactly as
  `evidence_link` does; never a user-supplied URL.
- "Apply locally" command interpolates only the run id, artifact name and record
  basename, each already validated upstream.
- Badge: absent unless `comment-badge: true`; absent on GHES regardless
  (`GITHUB_SERVER_URL != https://github.com`). Static URLs, no query string.
- Failure path never claims coverage facts; the s7 table shows only failure code,
  detail, receipt status. Reason codes stay machine-stable; only titles/messages change.
- Stale-head behaviour in `comment.sh` unchanged; the stamp is what makes a skipped
  update legible.

## 7. Tests

- `test/report.sh`: regenerate golden from the fixture; replace heading greps with the
  new anatomy (`> [!WARNING]`, `**Knowledge review needed.**`, `### What to do`,
  `| Area | Result |`, `Coverage · 4 changed paths`, `Affected knowledge · 3 objects`,
  `Run details and integrity`, footer `<sub>adoc … · action … · enforcement advisory ·
  scope full`), keep XSS/marker/order/oversize/part-marker assertions verbatim, add:
  consistent fixture → `[!TIP]` + acceptance sentence inside Run details and nowhere
  else; strict+errors fixture → `[!CAUTION]` **Blocked**; propose complete + delivery
  comment → `[!IMPORTANT]` and a `would move` card title; delivery pr + sync required →
  `[!WARNING]` **Knowledge sync pending**; delivery commit → **pull before pushing again**.
- `test/delivery.sh`: existing marker greps unchanged; add subject line
  `docs(adoc): update`, `### Why`, `### Bindings`, `<sub>Owned by AgentDoc`.
- `test/fail-honest.sh`: `[!CAUTION]` + `| Failure |` row + `::error title=AgentDoc
  assessment::`.
- `test/comment.sh`: unchanged and must stay green (first-line contract).
- One shell check per tracer, no new frameworks.

Required checks before PR: `test/report.sh`, `test/comment.sh`, `test/delivery.sh`,
`test/fail-honest.sh`, `test/proposal-scenario.sh`, `test/bootstrap.sh`,
`test/receipt.sh`, then full CI (`report`, `security`, `fail-honest`, `receipt`,
`semantic`, `strict-clean`, `strict-broken`).

## 8. Risks and unresolved decisions

- **D1 (decided 2026-09-20 by user): badge default.** Design: on, off for GHES.
  Reality: nothing serves `agentdoc.dev/badge/pr/*.svg` yet. Decision: input
  `comment-badge` exists, default `false`; stamp line always present; SVGs shipped under
  `assets/badge/pr/`; README says "enable once the badge host is live". Flip the default
  in a follow-up when hosting exists.
- **D2: proposal card diff body.** The patch manifest carries the new body only. Builder
  renders a unified diff when the retained proposal record includes the prior body;
  otherwise a fenced new-body block with a `ponytail:` note. Verify against
  `test/proposal-record.sh` fixtures before choosing.
- **D3: Human review counts.** Design says `required · 1 owner · 1 proof obligation`;
  the fixture has one reviewer group and one obligation, so counts come from
  `.required_reviewers|length` and `.proof_obligations|length` as today.
- **Risk: golden churn.** Every report test string changes; keep the golden regeneration
  in the same commit as the renderer change and review the diff by eye.
- **Risk: block priority.** Renaming/removing block kinds changes which detail is
  dropped at the 52,000 limit. `finalize-report.sh` priority list is updated in T1 and
  covered by the existing oversize test.
- **Risk: bootstrap body.** `deliver.sh` shares `write_pr_body` for bootstrap; the s8
  template needs round/coverage numbers from the baseline file (`$OUT/baseline-path`).
  If unavailable in bootstrap mode, the body falls back to the s4-pr shape with
  `source_label` "bootstrap workflow".

## 9. Delegation and review policy

Policy per `references/subagents.md`; user standing preference (memory
`always-use-fable-model`) overrides model choice to `claude-fable-5-1` for every
subagent; effort as listed.

| Task | Role | Model (policy → used) | Effort | Budget | Scope |
|---|---|---|---|---|---|
| T1–T3 | aw-builder | sonnet → fable-5-1 | medium | 24 turns each | `scripts/render-assessment.jq`, `scripts/compose.sh`, `scripts/propose.sh`, `scripts/finalize-report.sh`, `test/report.sh`, golden |
| T4 | aw-builder | sonnet → fable-5-1 | medium | 24 | `scripts/deliver.sh`, `scripts/enforce.sh`, `test/delivery.sh` |
| T5 | aw-builder | sonnet → fable-5-1 | medium | 24 | `scripts/compose.sh` failure path, `scripts/preflight.sh`, `scripts/enforce.sh`, `test/fail-honest.sh` |
| T6 | coordinator | — | — | — | `action.yml`, README, assets, part title |
| Review A: report contract | aw-refuter | opus → fable-5-1 | high | 16 | markers, escaping, order independence, bounding; runs `test/report.sh`, `test/comment.sh` |
| Review B: delivery trust boundary | aw-refuter | opus → fable-5-1 | high | 16 | PR body/commit markers, force-with-lease ownership, `test/delivery.sh`, `test/security.sh` |
| Review C: design fidelity | coordinator + user | — | — | — | side-by-side of rendered fixtures vs `gha-scenarios.js` s1–s9 |

Never the builder as its own refuter. Coordinator owns git; one commit per tracer;
PR gate: all reviews and CI green.

## 10. Memory note

`references/memory.md` says Mem0-only; the user's global CLAUDE.md asks for Obsidian
vault logging. Conflict recorded here; the coordinator writes the session log to the
vault per the global instruction and a Mem0 packet per the workflow, without duplicating
content.
