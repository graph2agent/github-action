#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

ruby --disable-gems - \
  "$repo_root/action.yml" \
  "$repo_root/.github/workflows/update-markdown.yml" \
  "$repo_root/prepare/action.yml" \
  "$repo_root/publish/action.yml" \
  "$repo_root/.github/workflows/maintain-markdown.yml" <<'RUBY'
require "yaml"

def load_yaml(path)
  source = File.read(path)
  begin
    YAML.safe_load(source, permitted_classes: [], permitted_symbols: [], aliases: false)
  rescue ArgumentError
    # Psych 3 (still shipped by some macOS Ruby installations) exposes these
    # controls as positional arguments; Psych 4+ uses keywords.
    YAML.safe_load(source, [], [], false)
  end
end

document = load_yaml(ARGV.fetch(0))
abort "action.yml must be a mapping" unless document.is_a?(Hash)
abort "composite action missing runs.using" unless document.dig("runs", "using") == "composite"
%w[token version operation path profile go-version].each do |name|
  abort "missing action input #{name}" unless document.fetch("inputs", {}).key?(name)
end
abort "unsafe default operation" unless document.dig("inputs", "operation", "default") == "check"
abort "wrong default profile" unless document.dig("inputs", "profile", "default") == "interpreted-v3"
abort "wrong default core tag" unless document.dig("inputs", "version", "default") == "v0.4.0"
abort "wrong default Go toolchain" unless document.dig("inputs", "go-version", "default") == "1.25.x"
abort "token must be optional" unless document.dig("inputs", "token", "required") == false
abort "optional token must default empty" unless document.dig("inputs", "token", "default") == ""

prepare_action = load_yaml(ARGV.fetch(2))
publish_action = load_yaml(ARGV.fetch(3))
{
  "prepare" => prepare_action,
  "publish" => publish_action
}.each do |name, action|
  abort "#{name} action must be composite" unless action.dig("runs", "using") == "composite"
  steps = action.dig("runs", "steps")
  abort "#{name} action must contain exactly one trusted shell step" unless steps.is_a?(Array) && steps.length == 1
  abort "#{name} action shell must be bash" unless steps.first["shell"] == "bash"
  abort "#{name} action must execute only its colocated runner" unless steps.first["run"] == '"$GITHUB_ACTION_PATH/run.sh"'
end
abort "publisher must require the caller token" unless publish_action.dig("inputs", "token", "required") == true

workflow = load_yaml(ARGV.fetch(1))
abort "update workflow must be a mapping" unless workflow.is_a?(Hash)
trigger = workflow["on"] || workflow[true]
call = trigger.fetch("workflow_call", {})
inputs = call.fetch("inputs", {})
%w[path profile graph2agent-version branch commit-message].each do |name|
  abort "missing update workflow input #{name}" unless inputs.key?(name)
end
abort "update path must default to repository root" unless inputs.dig("path", "default") == "."
abort "update branch must default to caller default selection" unless inputs.dig("branch", "default") == ""
abort "wrong update profile" unless inputs.dig("profile", "default") == "interpreted-v3"
abort "wrong update core tag" unless inputs.dig("graph2agent-version", "default") == "v0.4.0"
abort "deploy key must be required" unless call.dig("secrets", "GRAPH2AGENT_DEPLOY_KEY", "required") == true
abort "unexpected reusable workflow secret" unless call.fetch("secrets", {}).keys == ["GRAPH2AGENT_DEPLOY_KEY"]
abort "top-level permissions must be empty" unless workflow["permissions"] == {}
abort "concurrent updates must not be cancelled" unless workflow.dig("concurrency", "cancel-in-progress") == false

jobs = workflow.fetch("jobs", {})
abort "update workflow must have only prepare and publish jobs" unless jobs.keys == %w[prepare publish]
prepare = jobs.fetch("prepare")
publish = jobs.fetch("publish")
abort "prepare must have only contents read" unless prepare["permissions"] == {"contents" => "read"}
abort "publish must have only contents write" unless publish["permissions"] == {"contents" => "write"}
abort "publisher must depend on prepare" unless publish["needs"] == "prepare"
abort "publisher must run only for a prepared update" unless publish["if"] == "needs.prepare.outputs.updated == 'true'"

prepare_steps = prepare.fetch("steps", [])
publish_steps = publish.fetch("steps", [])
prepare_names = prepare_steps.map { |step| step["name"] }
[
  "Validate update request",
  "Check out caller branch",
  "Check out exact core tag",
  "Assert checkout credentials are absent",
  "Build exact checked-out core",
  "Prepare checksummed Markdown-only patch",
  "Upload validated patch"
].each do |name|
  abort "missing prepare safety step #{name}" unless prepare_names.include?(name)
end

core_checkout = prepare_steps.find { |step| step["name"] == "Check out exact core tag" }
abort "core checkout repository is wrong" unless core_checkout.dig("with", "repository") == "graph2agent/graph2agent"
abort "core checkout must use the exact requested tag" unless core_checkout.dig("with", "ref") == "${{ inputs.graph2agent-version }}"
abort "core checkout must receive the deploy key" unless core_checkout.dig("with", "ssh-key") == "${{ secrets.GRAPH2AGENT_DEPLOY_KEY }}"
abort "core checkout must use strict SSH" unless core_checkout.dig("with", "ssh-strict") == true
abort "core checkout persisted credentials" unless core_checkout.dig("with", "persist-credentials") == false

prepare_use = prepare_steps.find { |step| step["name"] == "Prepare checksummed Markdown-only patch" }.fetch("uses")
publisher = publish_steps.find { |step| step["name"] == "Verify, commit, and push Markdown-only update" }
publish_use = publisher.fetch("uses")
prepare_sha = prepare_use.split("@", 2).last
publish_sha = publish_use.split("@", 2).last
abort "trusted prepare action is not SHA-pinned" unless prepare_sha.match?(/\A[0-9a-f]{40}\z/)
abort "trusted publisher action is not SHA-pinned" unless publish_sha.match?(/\A[0-9a-f]{40}\z/)
abort "trusted actions must use the same reviewed commit" unless prepare_sha == publish_sha
abort "trusted actions may not use the placeholder SHA" if prepare_sha == "0" * 40
abort "publisher must use caller github.token" unless publisher.dig("with", "token") == "${{ github.token }}"
abort "publisher must receive the original event name" unless publisher.dig("with", "event-name") == "${{ github.event_name }}"
abort "publisher job may contain only pinned actions" unless publish_steps.all? { |step| step.key?("uses") && !step.key?("run") }
publish_source = YAML.dump(publish)
abort "publisher received the core deploy key" if publish_source.include?("GRAPH2AGENT_DEPLOY_KEY")
abort "publisher received or ran graph2agent core" if publish_source.include?("graph2agent-version") || publish_source.include?("/core")

maintain = load_yaml(ARGV.fetch(4))
abort "maintain workflow must be a mapping" unless maintain.is_a?(Hash)
maintain_trigger = maintain["on"] || maintain[true]
maintain_call = maintain_trigger.fetch("workflow_call", {})
maintain_inputs = maintain_call.fetch("inputs", {})
%w[path profile graph2agent-version base-branch commit-message pull-request-title].each do |name|
  abort "missing maintain workflow input #{name}" unless maintain_inputs.key?(name)
end
abort "wrong maintain core tag" unless maintain_inputs.dig("graph2agent-version", "default") == "v0.4.0"
abort "wrong maintain profile" unless maintain_inputs.dig("profile", "default") == "interpreted-v3"
abort "maintain read token must be optional" unless maintain_call.dig("secrets", "GRAPH2AGENT_READ_TOKEN", "required") == false
abort "maintain must accept exactly one optional secret" unless maintain_call.fetch("secrets", {}).keys == ["GRAPH2AGENT_READ_TOKEN"]
abort "maintain top-level permissions must be empty" unless maintain["permissions"] == {}
abort "concurrent maintenance runs must not be cancelled" unless maintain.dig("concurrency", "cancel-in-progress") == false
maintain_jobs = maintain.fetch("jobs", {})
abort "maintain workflow must have only prepare and publish jobs" unless maintain_jobs.keys == %w[prepare publish]
maintain_prepare = maintain_jobs.fetch("prepare")
maintain_publish = maintain_jobs.fetch("publish")
abort "maintain prepare must have only contents read" unless maintain_prepare["permissions"] == {"contents" => "read"}
abort "maintain publisher permissions are wrong" unless maintain_publish["permissions"] == {"contents" => "write", "pull-requests" => "write"}
abort "maintain publisher must depend on prepare" unless maintain_publish["needs"] == "prepare"
abort "maintain publisher must run only for a prepared update" unless maintain_publish["if"] == "needs.prepare.outputs.updated == 'true'"
maintain_prepare_source = YAML.dump(maintain_prepare)
maintain_publish_source = YAML.dump(maintain_publish)
abort "maintain prepare received write authority" if maintain_prepare_source.include?("contents: write") || maintain_prepare_source.include?("pull-requests: write")
abort "maintain publisher received the core read token" if maintain_publish_source.include?("GRAPH2AGENT_READ_TOKEN")
abort "maintain publisher ran graph2agent core" if maintain_publish_source.include?("go install")
abort "maintain publisher must use the audited patch publisher" unless maintain_publish_source.include?("graph2agent/github-action/publish@f39b93a81f885026b39945e8413992690826b9c0")
abort "maintain prepare must use the audited patch preparer" unless maintain_prepare_source.include?("graph2agent/github-action/prepare@f39b93a81f885026b39945e8413992690826b9c0")
abort "maintain workflow must open the pull request through the GitHub API" unless maintain_publish_source.include?("gh api --method POST")
abort "maintain workflow must reuse one open bot pull request" unless maintain_publish_source.include?("starts_with") || maintain_publish_source.include?("startswith")
abort "maintain workflow may not force-push" if maintain_publish_source.match?(/--force(?:\s|$)|--force-with-lease/)
RUBY

while IFS= read -r use; do
  reference=${use##*@}
  [[ $reference =~ ^[0-9a-f]{40}$ ]] || {
    printf 'external action is not SHA-pinned: %s\n' "$use" >&2
    exit 1
  }
done < <(sed -nE 's/^[[:space:]]*uses:[[:space:]]*([^ #]+@[^ #]+).*/\1/p' \
  "$repo_root/action.yml" \
  "$repo_root/prepare/action.yml" \
  "$repo_root/publish/action.yml" \
  "$repo_root"/.github/workflows/*.yml)

if grep -En 'contents:[[:space:]]*write|pull-requests:[[:space:]]*write|git[[:space:]]+push|gh[[:space:]]+pr' \
  "$repo_root/.github/workflows/check-markdown.yml" \
  "$repo_root/.github/workflows/ci.yml" \
  "$repo_root/prepare/action.yml" \
  "$repo_root/prepare/run.sh" \
  "$repo_root"/scripts/*.sh \
  "$repo_root/action.yml"; then
  printf 'read-only automation crossed its publication boundary\n' >&2
  exit 1
fi

update_workflow="$repo_root/.github/workflows/update-markdown.yml"
[[ $(grep -Ec '^[[:space:]]+contents:[[:space:]]+write$' "$update_workflow") -eq 1 ]] || {
  printf 'update workflow must contain exactly one contents-write grant\n' >&2
  exit 1
}
grep -F 'permissions: {}' "$update_workflow" >/dev/null
grep -F 'ssh-key: ${{ secrets.GRAPH2AGENT_DEPLOY_KEY }}' \
  "$update_workflow" >/dev/null
grep -F 'token: ${{ github.token }}' "$update_workflow" >/dev/null
grep -F 'git -c core.hooksPath=/dev/null push --no-verify --porcelain' \
  "$repo_root/publish/run.sh" >/dev/null
grep -F '"$remote_url" "HEAD:refs/heads/${branch}"' "$repo_root/publish/run.sh" >/dev/null
grep -F "printf '::add-mask::%s\\n' \"\$basic_auth\"" "$repo_root/publish/run.sh" >/dev/null
if grep -En -- '--force([^A-Za-z]|$)|--force-with-lease|pull-requests:[[:space:]]*write|gh[[:space:]]+pr|secrets\.[A-Za-z0-9_]*WRITE' \
  "$update_workflow" "$repo_root/publish/run.sh"; then
  printf 'update workflow contains a prohibited publication mechanism\n' >&2
  exit 1
fi

maintain_workflow="$repo_root/.github/workflows/maintain-markdown.yml"
[[ $(grep -Ec '^[[:space:]]+contents:[[:space:]]+write$' "$maintain_workflow") -eq 1 ]] || {
  printf 'maintain workflow must contain exactly one contents-write grant\n' >&2
  exit 1
}
[[ $(grep -Ec '^[[:space:]]+pull-requests:[[:space:]]+write$' "$maintain_workflow") -eq 1 ]] || {
  printf 'maintain workflow must contain exactly one pull-requests-write grant\n' >&2
  exit 1
}
grep -F 'permissions: {}' "$maintain_workflow" >/dev/null
grep -F 'if: needs.prepare.outputs.updated == '\''true'\''' "$maintain_workflow" >/dev/null
grep -F 'token: ${{ github.token }}' "$maintain_workflow" >/dev/null
if grep -En -- '--force([^A-Za-z]|$)|--force-with-lease' "$maintain_workflow"; then
  printf 'maintain workflow contains a prohibited push mode\n' >&2
  exit 1
fi

printf 'metadata tests passed\n'
