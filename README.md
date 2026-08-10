<p align="center">
  <img src="https://raw.githubusercontent.com/graph2agent/graph2agent/main/.github/assets/favicon.svg" alt="graph2agent logo" width="96" height="96">
</p>

# Never merge stale graph context. Let a bot keep it fresh.

graph2agent's GitHub automation makes generated Mermaid context enforceable in
two places: a read-only pull-request gate rejects stale annotations before
merge, and a trusted daily job opens a focused Markdown-only refresh PR when
the default branch drifts.

> **Measured: 50.41% fewer exact-comprehension failures.** On one frozen,
> paired benchmark of 330 private contracts, Mermaid plus graph2agent's
> `standard` digest scored 270/330 exact versus 209/330 with Mermaid alone
> (+18.48 percentage points; 61 digest-only wins and 0 Mermaid-only wins).
> [Evidence and limitations](https://graph2agent.github.io/#evidence)

The measured result used the frozen `standard` digest in one requested Codex
configuration. These workflows default to the newer `interpreted-v3` Markdown
profile; the benchmark does not establish the same effect for that profile or
for every model, task, or Mermaid construct.

## 1. Block a merge when local generation is stale

```yaml
name: Generated context

on:
  pull_request:

permissions:
  contents: read

jobs:
  graph2agent:
    uses: graph2agent/github-action/.github/workflows/check-markdown.yml@b467d92b8c14a87fe977bc6a12a0f9fc685ab047
    with:
      graph2agent-version: v0.2.0
```

Make this job a required status check. It runs `graph2agent check .` and never
writes, commits, pushes, or receives write permission.

## 2. Let a daily bot open the refresh PR

```yaml
name: Keep Mermaid context current

on:
  schedule:
    - cron: '17 3 * * *'
  workflow_dispatch:

permissions:
  contents: write
  pull-requests: write

jobs:
  graph2agent:
    uses: graph2agent/github-action/.github/workflows/maintain-markdown.yml@b467d92b8c14a87fe977bc6a12a0f9fc685ab047
    with:
      graph2agent-version: v0.2.0
```

The scheduled run does nothing when annotations are current. When they are
stale, a read-only generation job emits a checksummed Markdown-only patch. A
fresh publisher verifies it, pushes a non-force maintenance branch, and opens a
PR. If one graph2agent maintenance PR is already open against that base branch,
later daily runs reuse it instead of creating duplicates.

Both examples pin the reviewed Apache-2.0 launch implementation by its full
commit SHA. The no-secret public setup is active with the `v0.2.0` core release.

## Composite action

The lower-level composite action installs one exact core tag, runs `check` or
`update`, and stops. It never publishes Git changes or changes Git credentials
on disk.

```yaml
permissions:
  contents: read

steps:
  - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1
    with:
      persist-credentials: false
  - uses: graph2agent/github-action@b467d92b8c14a87fe977bc6a12a0f9fc685ab047
    with:
      version: v0.2.0
      operation: check
      path: .
      profile: interpreted-v3
```

For a controlled working-tree update, set `operation: update`. The caller then
decides how to inspect or publish the diff. This action deliberately performs
no Git publication step.

### Inputs

| Input | Default | Contract |
| --- | --- | --- |
| `token` | empty | Optional read-only GitHub access for private-fork compatibility; public releases need none. |
| `version` | `v0.2.0` | Exact SemVer tag; branches, ranges, and `latest` are rejected. |
| `operation` | `check` | Exactly `check` or `update`. |
| `path` | `.` | One repository-relative file or directory; traversal, symlink targets, leading hyphens, and line breaks are rejected. |
| `profile` | `interpreted-v3` | One supported deterministic narrative profile. |
| `go-version` | `1.25.x` | Toolchain used only for installation. |

Outputs are the ephemeral binary path, exact installed version, and validated
operation. The binary lives under `RUNNER_TEMP` and should not be cached or
published.

## Read-only reusable workflow

[`check-markdown.yml`](.github/workflows/check-markdown.yml) is callable by
other repositories and has only `contents: read`. A successful call exports
`checked=true` and the exact core version. See
[`examples/reusable-check.yml`](examples/reusable-check.yml).

## Scheduled pull-request workflow

[`maintain-markdown.yml`](.github/workflows/maintain-markdown.yml) is the
recommended write-capable automation. Call it only from `schedule` or
`workflow_dispatch`. Generation runs with `contents: read`; only a fresh
publisher gets `contents: write` and `pull-requests: write`. The publisher gets
the validated patch, never the optional core read credential or core code. See
[`examples/reusable-maintain.yml`](examples/reusable-maintain.yml).

## Direct-branch workflow (advanced)

[`update-markdown.yml`](.github/workflows/update-markdown.yml) updates every
selected `.md` file, verifies the generated annotations, commits the resulting
Markdown-only diff, and performs a normal non-force push. Its default `path: .`
selects the caller repository recursively; its default empty `branch` selects
the caller repository's default branch.

The caller must deliberately grant `contents: write` and pass its unique
read-only core deploy key as `GRAPH2AGENT_DEPLOY_KEY`. Reusable workflows cannot
elevate a caller token. The workflow separates generation from publication:

1. `prepare` has only `contents: read`. It checks out the exact private core
   tag with the deploy key, builds and runs it, verifies the result, and uploads
   a checksummed binary patch containing only modifications to tracked regular
   `.md` files.
2. `publish` starts on a fresh runner with `contents: write`. It receives no
   core credential and runs no core code. A separately SHA-pinned publisher
   verifies and reapplies the patch against its exact base, independently
   repeats the Markdown-only checks, commits with hooks disabled, and performs
   one normal push with the short-lived caller `GITHUB_TOKEN`.

Every checkout disables persisted credentials. Staged, untracked, renamed,
added, deleted, mode-changing, symlink, and non-`.md` changes are rejected. An
ephemeral masked authorization header is passed only to `git push`. A concurrent
update or repository rule therefore fails the push instead of being bypassed.
The workflow never force-pushes, changes branch protection, or opens a pull
request. Prefer the scheduled pull-request workflow for unattended maintenance.

Call the workflow only from a trusted event such as `workflow_dispatch`,
`schedule`, or a protected-branch push. Do not invoke a write-capable workflow
with untrusted pull-request code. Pin the reusable workflow to an audited full
commit SHA. See [`examples/reusable-update.yml`](examples/reusable-update.yml).

### Update inputs and outputs

| Input | Default | Contract |
| --- | --- | --- |
| `path` | `.` | Existing repository-relative Markdown file or directory. |
| `profile` | `interpreted-v3` | One supported deterministic narrative profile. |
| `graph2agent-version` | `v0.1.0` | Exact private-preview core SemVer tag. |
| `branch` | empty | Existing short branch name; empty selects the caller default branch. |
| `commit-message` | `docs: refresh graph2agent annotations` | Non-empty, single-line message of at most 200 characters. |

The workflow returns `updated`, `files-changed`, `commit-sha`, and `branch`.
`commit-sha` is empty when all selected annotations were already current.

## Private-preview compatibility

Public `v0.2.0` use needs no core credential. While the core remains private,
the composite action and reusable check can use `GRAPH2AGENT_READ_TOKEN`.
Create it as a fine-grained personal access token or
GitHub App installation token with:

- access only to `graph2agent/graph2agent`;
- repository permission `Contents: read` and no write permissions;
- an expiration and an owner responsible for rotation.

Store it as an organization or repository Actions secret. The caller
repository's `GITHUB_TOKEN` does not normally grant access to a different
private repository.

The installer removes the raw token from its environment, derives a Basic
authorization header in memory, and supplies that header only through
`GIT_CONFIG_COUNT`/`GIT_CONFIG_KEY_0`/`GIT_CONFIG_VALUE_0` for the single
`go install` process. It does not run `git config`, add credentials to a remote
URL, use a credential helper, print the token, or persist it in a file.

The write-capable reusable workflow does not accept that token. Give each
caller repository a distinct read-only deploy key for
`graph2agent/graph2agent`, store the private half only as the repository secret
`GRAPH2AGENT_DEPLOY_KEY`, and keep the public half registered on the core
repository with write access disabled. The key is available only in `prepare`;
it is not uploaded with the patch or passed to `publish`.

Private Actions sharing must also be enabled for this repository in the
organization settings. Pin this action or reusable workflow to a reviewed full
commit SHA even when the repository is private.

## Examples

- [`action-check.yml`](examples/action-check.yml): direct read-only check.
- [`action-update-for-review.yml`](examples/action-update-for-review.yml):
  manual working-tree update that prints/fails on the resulting diff and does
  not publish it.
- [`reusable-check.yml`](examples/reusable-check.yml): reusable read-only check.
- [`reusable-update.yml`](examples/reusable-update.yml): trusted-event,
  Markdown-only commit and non-force push.
- [`reusable-maintain.yml`](examples/reusable-maintain.yml): daily or manual,
  deduplicated Markdown-only pull request.

The public check and maintenance examples pin the reviewed launch
implementation by full commit SHA. Review and update that pin deliberately
when adopting a newer release.

## Development

```sh
make check
```

The test suite uses fake `go` and `graph2agent` executables. It verifies exact
arguments, rejects unsafe input, checks that credentials are environment-only,
tests the reusable update workflow's request/diff/commit/push boundaries, and
confirms that captured output contains no test token. CI pins external Actions
by full SHA and installs an exact actionlint release.

## License

Apache-2.0. See [LICENSE](LICENSE).
