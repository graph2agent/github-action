# Contributing

Keep changes small, deterministic, and reviewable.

1. Create a branch from `main`.
2. Run `make check`.
3. Add or update fake-runner tests for every shell behavior change.
4. Pin every external GitHub Action by a full 40-character commit SHA.
5. Keep the core dependency on one exact SemVer tag.
6. Never add shell tracing, `eval`, persistent credentials, force-pushes, or
   token-bearing URLs.

Changes to supported operations, credential handling, permissions, or
publication behavior require a security review. Release commits should update
the README examples and default core tag together.
