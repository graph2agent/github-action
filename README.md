# graph2agent GitHub automation

This private repository provides a composite GitHub Action for checking or
updating deterministic graph2agent annotations in Markdown. It installs one
exact private core tag, runs the requested operation, and stops. The composite
action never commits, pushes, opens a pull request, or changes Git credentials
on disk.

## Composite action

```yaml
permissions:
  contents: read

steps:
  - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1
    with:
      persist-credentials: false
  - uses: graph2agent/github-action@<audited-40-character-commit-sha>
    with:
      token: ${{ secrets.GRAPH2AGENT_READ_TOKEN }}
      version: v0.1.0
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
| `token` | required | Read-only access to the private core repository. |
| `version` | `v0.1.0` | Exact SemVer tag; branches, ranges, and `latest` are rejected. |
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

The repository intentionally does not currently include automation that
commits, pushes bot branches, or opens pull requests. Consumers needing an
update can run the composite action with `operation: update`, inspect the diff,
and publish it through a separately reviewed workflow.

## Private-organization access

Create `GRAPH2AGENT_READ_TOKEN` as a fine-grained personal access token or
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

Private Actions sharing must also be enabled for this repository in the
organization settings. Pin this action or reusable workflow to a reviewed full
commit SHA even when the repository is private.

## Examples

- [`action-check.yml`](examples/action-check.yml): direct read-only check.
- [`action-update-for-review.yml`](examples/action-update-for-review.yml):
  manual working-tree update that prints/fails on the resulting diff and does
  not publish it.
- [`reusable-check.yml`](examples/reusable-check.yml): reusable read-only check.

The all-zero references in examples are deliberate invalid placeholders. A
consumer must replace each with an audited commit SHA.

## Development

```sh
make check
```

The test suite uses fake `go` and `graph2agent` executables. It verifies exact
arguments, rejects unsafe input, checks that credentials are environment-only,
and confirms that captured output contains no test token. CI pins external
Actions by full SHA and installs an exact actionlint release.
