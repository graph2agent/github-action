#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

ruby --disable-gems - "$repo_root/action.yml" <<'RUBY'
require "yaml"

path = ARGV.fetch(0)
document = YAML.safe_load(File.read(path), [], [], false)
abort "action.yml must be a mapping" unless document.is_a?(Hash)
abort "composite action missing runs.using" unless document.dig("runs", "using") == "composite"
%w[token version operation path profile go-version].each do |name|
  abort "missing action input #{name}" unless document.fetch("inputs", {}).key?(name)
end
abort "unsafe default operation" unless document.dig("inputs", "operation", "default") == "check"
abort "wrong default profile" unless document.dig("inputs", "profile", "default") == "interpreted-v3"
abort "wrong default core tag" unless document.dig("inputs", "version", "default") == "v0.1.0"
abort "wrong default Go toolchain" unless document.dig("inputs", "go-version", "default") == "1.25.x"
abort "token must be required" unless document.dig("inputs", "token", "required") == true
RUBY

while IFS= read -r use; do
  reference=${use##*@}
  [[ $reference =~ ^[0-9a-f]{40}$ ]] || {
    printf 'external action is not SHA-pinned: %s\n' "$use" >&2
    exit 1
  }
done < <(sed -nE 's/^[[:space:]]*uses:[[:space:]]*(actions\/[A-Za-z0-9_.-]+@[A-Za-z0-9_.-]+).*/\1/p' \
  "$repo_root/action.yml" "$repo_root"/.github/workflows/*.yml)

if grep -ERn 'contents:[[:space:]]*write|pull-requests:[[:space:]]*write|git[[:space:]]+push|gh[[:space:]]+pr' \
  "$repo_root/.github" "$repo_root/scripts" "$repo_root/action.yml"; then
  printf 'automation repository crossed its read-only publication boundary\n' >&2
  exit 1
fi

printf 'metadata tests passed\n'
