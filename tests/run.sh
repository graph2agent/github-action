#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
"${repo_root}/tests/test-install.sh"
"${repo_root}/tests/test-metadata.sh"
"${repo_root}/tests/test-runner.sh"
