# AgentDoc Action

Validates your [AgentDoc](https://github.com/alex-bako/adoc) Knowledge Objects
in Strict Mode on every pull request and posts a single, in-place-updated
**Review Report** comment: validation diagnostics, impacted knowledge, and
proposed new Knowledge Objects.

## Usage

```yaml
name: AgentDoc PR Report
on: pull_request
permissions:
  contents: read
  pull-requests: write   # sticky comment; omit → job-summary-only mode
jobs:
  report:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v7
        with:
          fetch-depth: 0   # required for the Impacted Query (--ref)
      - uses: agentdoc-dev/action@v1
```

Start in the default `advisory` mode; flip to `enforcement: strict` after a
clean week.

## Inputs

| Input | Default | Description |
|---|---|---|
| `enforcement` | `advisory` | `advisory` posts the Review Report without failing the job; `strict` fails the job when `adoc check` finds errors. |
| `scope` | `full` | `full` gates on every error in the knowledge base; `diff` gates only on errors in files changed by the pull request. The full report is always posted. |
| `adoc-version` | pinned tag | adoc release to install — each action release is tested against exactly its pinned default. `latest` is accepted but not recommended for pinning. |
| `working-directory` | `.` | Directory from which `agentdoc.config.yaml` discovery starts. |
| `github-token` | `${{ github.token }}` | Token used to upsert the sticky pull request comment. |

## What it does

1. Installs the pinned `adoc` binary from GitHub Releases (sha256-verified).
2. Builds the Graph Artifact (`adoc build --no-embeddings`).
3. Runs `adoc check` (Strict Mode validation) — diagnostics become file/line
   annotations via a problem matcher, no API calls involved.
4. Runs the Impacted Query (`adoc impacted-by --ref`) against the PR base and
   derives **Proposed Knowledge Objects**: changed source paths no Knowledge
   Object claims impact over.
5. Upserts one sticky PR comment (marker `<!-- adoc:pr-report -->`) and writes
   the same report to the job summary.
6. In `strict` mode only, fails the job if validation found errors — after the
   comment is posted.

## Fork pull requests

On PRs from forks `GITHUB_TOKEN` is read-only, so the comment cannot be
posted. The action degrades gracefully: annotations and the job summary still
work, and a workflow warning notes why the comment is missing.

## Supported runners

Linux x86_64 and arm64 (`ubuntu-latest`, `ubuntu-24.04-arm`). Other platforms
fail with a clear error.

## Security

- The `adoc` binary is downloaded only from the adoc repository's GitHub
  Releases and verified against its published sha256 checksum.
- No third-party actions are used inside this action.
- The token is used for exactly one thing: the PR comment API call.
- Pin the full commit SHA instead of `@v1` in security-sensitive repositories.

## Releasing (maintainers)

Tag semver releases and move the floating major tag:

```sh
git tag v1.x.y && git push origin v1.x.y
git tag -f v1 && git push -f origin v1
```

Publish a GitHub Release from the tag (required for the Marketplace listing).
Bump the `adoc-version` default in `action.yml` when a new adoc release is
validated.

## License

MIT
