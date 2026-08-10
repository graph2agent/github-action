# Contributing

Keep changes small, deterministic, and reviewable.

1. Create a branch from `main`.
2. Run `make check`.
3. Add or update fake-runner tests for every shell behavior change.
4. Pin every external GitHub Action by a full 40-character commit SHA.
5. Keep the core dependency on one exact SemVer tag.
6. Never add shell tracing, `eval`, persistent credentials, force-pushes,
   token-bearing URLs, branch-protection bypasses, or pull-request automation.

Changes to supported operations, credential handling, permissions, or
publication behavior require a security review. Write permission must remain
isolated to the fresh `publish` job in `update-markdown.yml`, must come from the
caller's short-lived `GITHUB_TOKEN`, and may publish only a checksummed patch of
validated modifications to tracked `.md` files. Core execution and its deploy
key must remain in the read-only `prepare` job. Pin both publisher actions to a
separate immutable commit. Release commits should update the README examples
and default core tag together.
