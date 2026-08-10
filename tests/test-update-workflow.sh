#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
temporary=$(mktemp -d "${TMPDIR:-/tmp}/graph2agent-update-workflow-test.XXXXXX")
trap 'rm -rf "$temporary"' EXIT

export LC_ALL=C

real_git=$(command -v git)
test_token='write-test-token-never-print'
test_header=$(printf 'x-access-token:%s' "$test_token" | base64 | tr -d '\r\n')
test_header="AUTHORIZATION: basic ${test_header}"
test_header_digest=$(printf '%s' "$test_header" | sha256sum)
test_header_digest=${test_header_digest%% *}

fail_test() {
  printf 'update workflow test: %s\n' "$1" >&2
  exit 1
}

git_in() {
  local worktree=$1
  shift
  "$real_git" -C "$worktree" "$@"
}

commit_all() {
  local worktree=$1
  local message=$2
  git_in "$worktree" add -A
  git_in "$worktree" \
    -c user.name='Workflow Test' \
    -c user.email='workflow-test@example.invalid' \
    commit -q -m "$message"
}

create_repo() {
  local worktree=$1
  local include_weird=${2:-false}
  mkdir -p "$worktree/docs"
  "$real_git" init -q -b main "$worktree"
  printf '# Diagram\n\n```mermaid\ngraph TD\n  A --> B\n```\n' >"$worktree/README.md"
  printf 'setting=true\n' >"$worktree/config.txt"
  if [[ "$include_weird" == true ]]; then
    local weird_path=$'docs/line\n$(touch nope); [*] `cmd`.md'
    printf '# Unusual path\n' >"$worktree/$weird_path"
  fi
  commit_all "$worktree" 'initial fixture'
}

fake_graph2agent=${temporary}/fake-graph2agent
{
  printf '%s\n' '#!/usr/bin/env bash'
  printf '%s\n' 'set -euo pipefail'
  printf '%s\n' 'operation=${1:-}'
  printf '%s\n' 'if [[ "$operation" == check ]]; then exit 0; fi'
  printf '%s\n' '[[ "$operation" == update ]] || exit 2'
  printf '%s\n' 'case "${FAKE_UPDATE_MODE:-noop}" in'
  printf '%s\n' '  noop) ;;'
  printf '%s\n' "  md) printf '\\n<!-- graph2agent -->\\n' >>README.md ;;"
  printf '%s\n' "  md-pair) printf '\\n<!-- graph2agent -->\\n' >>README.md; printf '\\nagent text\\n' >>\"\${FAKE_TARGET_FILE:?}\" ;;"
  printf '%s\n' "  non-md) printf '\\nchanged=true\\n' >>config.txt ;;"
  printf '%s\n' "  untracked) printf '# generated\\n' >generated.md ;;"
  printf '%s\n' "  add) printf '# added\\n' >added.md; git add -- added.md ;;"
  printf '%s\n' '  delete) rm -- README.md ;;'
  printf '%s\n' '  rename) git mv -- README.md renamed.md ;;'
  printf '%s\n' '  mode) chmod +x README.md ;;'
  printf '%s\n' '  symlink) rm -- README.md; ln -s config.txt README.md ;;'
  printf '%s\n' '  *) exit 3 ;;'
  printf '%s\n' 'esac'
} >"$fake_graph2agent"
chmod +x "$fake_graph2agent"

git_wrapper_dir=${temporary}/git-wrapper
mkdir -p "$git_wrapper_dir"
{
  printf '%s\n' '#!/usr/bin/env bash'
  printf '%s\n' 'set -euo pipefail'
  printf '%s\n' 'args=("$@")'
  printf '%s\n' 'if [[ ${args[0]:-} == config && ${args[1]:-} == --global && ${args[2]:-} == --name-only ]]; then'
  printf '%s\n' '  exit 1'
  printf '%s\n' 'fi'
  printf '%s\n' 'push_index=-1'
  printf '%s\n' 'for index in "${!args[@]}"; do'
  printf '%s\n' '  if [[ ${args[$index]} == push ]]; then push_index=$index; break; fi'
  printf '%s\n' 'done'
  printf '%s\n' 'if ((push_index >= 0)); then'
  printf '%s\n' '  : "${TEST_BARE_REMOTE:?}" "${TEST_PUSH_LOG:?}" "${EXPECTED_AUTH_DIGEST:?}"'
  printf '%s\n' '  printf "%s\\0" "${args[@]}" >"$TEST_PUSH_LOG"'
  printf '%s\n' '  for argument in "${args[@]}"; do'
  printf '%s\n' '    case "$argument" in --force | --force=* | --force-with-lease*) exit 91 ;; esac'
  printf '%s\n' '  done'
  printf '%s\n' '  if [[ -n ${GIT_CONFIG_COUNT:-} ]]; then'
  printf '%s\n' '    [[ $GIT_CONFIG_COUNT == 1 ]] || exit 92'
  printf '%s\n' '    [[ ${GIT_CONFIG_KEY_0:-} == http.https://github.example.invalid/.extraheader ]] || exit 93'
  printf '%s\n' '    actual_digest=$(printf "%s" "${GIT_CONFIG_VALUE_0:-}" | sha256sum)'
  printf '%s\n' '    actual_digest=${actual_digest%% *}'
  printf '%s\n' '    [[ $actual_digest == "$EXPECTED_AUTH_DIGEST" ]] || exit 94'
  printf '%s\n' '  fi'
  printf '%s\n' '  refspec=${args[${#args[@]}-1]}'
  printf '%s\n' '  exec "$REAL_GIT" -c core.hooksPath=/dev/null push --no-verify --porcelain "$TEST_BARE_REMOTE" "$refspec"'
  printf '%s\n' 'fi'
  printf '%s\n' 'exec "$REAL_GIT" "$@"'
} >"$git_wrapper_dir/git"
chmod +x "$git_wrapper_dir/git"

output_value() {
  local name=$1
  local output_file=$2
  sed -n "s/^${name}=//p" "$output_file"
}

run_prepare() {
  local case_root=$1
  local workspace=$2
  local artifact=$3
  local output=$4
  local mode=$5
  local target_file=${6:-}
  mkdir -p "$case_root/runner"
  : >"$output"
  PATH="$git_wrapper_dir:$PATH" \
  REAL_GIT="$real_git" \
  FAKE_UPDATE_MODE="$mode" \
  FAKE_TARGET_FILE="$target_file" \
  GRAPH2AGENT_PREPARE_BINARY="$fake_graph2agent" \
  GRAPH2AGENT_PREPARE_WORKSPACE="$workspace" \
  GRAPH2AGENT_PREPARE_PATH=. \
  GRAPH2AGENT_PREPARE_PROFILE=interpreted-v3 \
  GRAPH2AGENT_PREPARE_BRANCH=main \
  GRAPH2AGENT_PREPARE_ARTIFACT_DIRECTORY="$artifact" \
  RUNNER_TEMP="$case_root/runner" \
  GITHUB_WORKSPACE="$case_root" \
  GITHUB_OUTPUT="$output" \
    bash "$repo_root/prepare/run.sh"
}

run_publish() {
  local case_root=$1
  local workspace=$2
  local artifact=$3
  local output=$4
  local digest=$5
  local files=$6
  local base_sha=$7
  local bare_remote=$8
  local push_log=$9
  local event_name=${10:-workflow_dispatch}
  : >"$output"
  PATH="$git_wrapper_dir:$PATH" \
  REAL_GIT="$real_git" \
  TEST_BARE_REMOTE="$bare_remote" \
  TEST_PUSH_LOG="$push_log" \
  EXPECTED_AUTH_DIGEST="$test_header_digest" \
  GRAPH2AGENT_PUBLISH_WORKSPACE="$workspace" \
  GRAPH2AGENT_PUBLISH_ARTIFACT_DIRECTORY="$artifact" \
  GRAPH2AGENT_PUBLISH_PATCH_SHA256="$digest" \
  GRAPH2AGENT_PUBLISH_FILES="$files" \
  GRAPH2AGENT_PUBLISH_BASE_SHA="$base_sha" \
  GRAPH2AGENT_PUBLISH_BRANCH=main \
  GRAPH2AGENT_PUBLISH_COMMIT_MESSAGE='docs: refresh graph2agent annotations' \
  GRAPH2AGENT_PUBLISH_REPOSITORY=acme/demo \
  GRAPH2AGENT_PUBLISH_SERVER_URL=https://github.example.invalid \
  GRAPH2AGENT_PUBLISH_EVENT_NAME="$event_name" \
  GRAPH2AGENT_PUBLISH_TOKEN="$test_token" \
  GRAPH2AGENT_TEST_MODE=1 \
  GRAPH2AGENT_TEST_REMOTE_URL="$bare_remote" \
  RUNNER_TEMP="$case_root/runner" \
  GITHUB_WORKSPACE="$case_root" \
  GITHUB_OUTPUT="$output" \
    bash "$repo_root/publish/run.sh"
}

make_bare_remote() {
  local source=$1
  local bare=$2
  "$real_git" init -q --bare "$bare"
  "$real_git" --git-dir="$bare" symbolic-ref HEAD refs/heads/main
  git_in "$source" remote add origin "$bare"
  git_in "$source" push -q -u origin main
}

clone_detached() {
  local bare=$1
  local destination=$2
  local base_sha=$3
  "$real_git" clone -q "$bare" "$destination"
  git_in "$destination" checkout -q --detach "$base_sha"
}

assert_prepare_rejected() {
  local mode=$1
  local expected=$2
  local case_root=${temporary}/prepare-reject-${mode}
  local workspace=${case_root}/workspace
  local artifact=${case_root}/runner/artifact
  local output=${case_root}/output
  create_repo "$workspace"
  local captured
  if captured=$(run_prepare "$case_root" "$workspace" "$artifact" "$output" "$mode" 2>&1); then
    fail_test "prepare accepted ${mode} mutation"
  fi
  [[ "$captured" == *"$expected"* ]] ||
    fail_test "prepare ${mode} rejection did not contain expected diagnostic"
}

# No-op generation must not create an artifact or claim an update.
noop_root=${temporary}/noop
noop_workspace=${noop_root}/workspace
noop_artifact=${noop_root}/runner/artifact
noop_output=${noop_root}/output
create_repo "$noop_workspace"
run_prepare "$noop_root" "$noop_workspace" "$noop_artifact" "$noop_output" noop >/dev/null
[[ $(output_value updated "$noop_output") == false ]] || fail_test 'no-op was reported as updated'
[[ $(output_value files "$noop_output") == 0 ]] || fail_test 'no-op file count is not zero'
[[ -z $(output_value patch-sha256 "$noop_output") ]] || fail_test 'no-op emitted a patch digest'
[[ ! -e "$noop_artifact" ]] || fail_test 'no-op created an artifact directory'

# The read-only prepare boundary must reject every non-modification outcome.
assert_prepare_rejected non-md 'non-Markdown file'
assert_prepare_rejected untracked 'untracked file'
assert_prepare_rejected add 'staged a change'
assert_prepare_rejected delete 'file mode or file identity'
assert_prepare_rejected rename 'staged a change'
assert_prepare_rejected mode 'file mode or file identity'
assert_prepare_rejected symlink 'file mode or file identity'

# Prepare a legitimate two-file patch, including a newline and shell metacharacters
# in one tracked Markdown filename.
valid_root=${temporary}/valid
valid_workspace=${valid_root}/prepare-workspace
valid_bare=${valid_root}/remote.git
valid_artifact=${valid_root}/runner/artifact
valid_prepare_output=${valid_root}/prepare-output
valid_publish_output=${valid_root}/publish-output
valid_push_log=${valid_root}/push-arguments.bin
weird_path=$'docs/line\n$(touch nope); [*] `cmd`.md'
create_repo "$valid_workspace" true
make_bare_remote "$valid_workspace" "$valid_bare"
valid_base=$(git_in "$valid_workspace" rev-parse HEAD)
run_prepare "$valid_root" "$valid_workspace" "$valid_artifact" "$valid_prepare_output" md-pair "$weird_path" >/dev/null
valid_digest=$(output_value patch-sha256 "$valid_prepare_output")
[[ $(output_value updated "$valid_prepare_output") == true ]] || fail_test 'valid patch was not reported'
[[ $(output_value files "$valid_prepare_output") == 2 ]] || fail_test 'valid patch file count is not two'
[[ "$valid_digest" =~ ^[0-9a-f]{64}$ ]] || fail_test 'valid patch digest is malformed'
[[ -s "$valid_artifact/update.patch" && -s "$valid_artifact/update.patch.sha256" ]] ||
  fail_test 'valid patch artifact is incomplete'

valid_publish_workspace=${valid_root}/publish-workspace
clone_detached "$valid_bare" "$valid_publish_workspace" "$valid_base"
hook_marker=${valid_root}/hook-ran
for hook in pre-commit commit-msg pre-push; do
  {
    printf '%s\n' '#!/usr/bin/env bash'
    printf '%s\n' ': "${TEST_HOOK_MARKER:?}"'
    printf '%s\n' 'printf "hook executed\\n" >"$TEST_HOOK_MARKER"'
    printf '%s\n' 'exit 97'
  } >"$valid_publish_workspace/.git/hooks/$hook"
  chmod +x "$valid_publish_workspace/.git/hooks/$hook"
done

captured=$(TEST_HOOK_MARKER="$hook_marker" run_publish \
  "$valid_root" "$valid_publish_workspace" "$valid_artifact" "$valid_publish_output" \
  "$valid_digest" 2 "$valid_base" "$valid_bare" "$valid_push_log" 2>&1)
valid_commit=$(output_value commit "$valid_publish_output")
[[ "$valid_commit" =~ ^[0-9a-f]{40}$ ]] || fail_test 'publish did not emit a commit SHA'
[[ $("$real_git" --git-dir="$valid_bare" rev-parse refs/heads/main) == "$valid_commit" ]] ||
  fail_test 'valid commit was not pushed to main'
[[ ! -e "$hook_marker" ]] || fail_test 'a caller Git hook executed'
[[ ! -e "$valid_root/nope" && ! -e "$valid_publish_workspace/nope" ]] ||
  fail_test 'metacharacters in a filename were executed'
[[ "$captured" != *"$test_token"* && "$captured" != *"$test_header"* ]] ||
  fail_test 'credential material appeared in publish output'
[[ $(git_in "$valid_publish_workspace" remote get-url origin) == "$valid_bare" ]] ||
  fail_test 'publish changed the persisted remote URL'
if git_in "$valid_publish_workspace" config --local --name-only --get-regexp \
  '^(credential\.|http\..*\.extraheader$)' >/dev/null 2>&1; then
  fail_test 'publish persisted Git credentials'
fi
if tr '\0' '\n' <"$valid_push_log" | grep -E -- '--force($|=)|--force-with-lease' >/dev/null; then
  fail_test 'publish attempted a force push'
fi
git_in "$valid_publish_workspace" show "HEAD:$weird_path" | grep -F 'agent text' >/dev/null ||
  fail_test 'newline/metacharacter Markdown path was not committed safely'

make_patch_case() {
  local case_name=$1
  local mutation=$2
  local case_root=${temporary}/publish-reject-${case_name}
  local source=${case_root}/source
  local bare=${case_root}/remote.git
  local staging=${case_root}/staging
  local workspace=${case_root}/workspace
  local artifact=${case_root}/runner/artifact
  mkdir -p "$case_root/runner" "$artifact"
  create_repo "$source"
  make_bare_remote "$source" "$bare"
  local base_sha
  base_sha=$(git_in "$source" rev-parse HEAD)
  "$real_git" clone -q "$bare" "$staging"
  case "$mutation" in
    non-md) printf '\nchanged=true\n' >>"$staging/config.txt" ;;
    add) printf '# added\n' >"$staging/added.md" ;;
    delete) rm -- "$staging/README.md" ;;
    rename) git_in "$staging" mv -- README.md renamed.md ;;
    mode) chmod +x "$staging/README.md" ;;
    symlink) rm -- "$staging/README.md"; ln -s config.txt "$staging/README.md" ;;
    md) printf '\n<!-- graph2agent -->\n' >>"$staging/README.md" ;;
    *) fail_test "unknown patch mutation ${mutation}" ;;
  esac
  git_in "$staging" add -A
  git_in "$staging" --no-pager diff --cached --binary --full-index --no-ext-diff --no-textconv \
    >"$artifact/update.patch"
  local digest
  digest=$(sha256sum "$artifact/update.patch")
  digest=${digest%% *}
  printf '%s  update.patch\n' "$digest" >"$artifact/update.patch.sha256"
  clone_detached "$bare" "$workspace" "$base_sha"
  printf '%s\n' "$case_root" "$workspace" "$artifact" "$bare" "$base_sha" "$digest"
}

assert_publish_rejected_patch() {
  local case_name=$1
  local mutation=$2
  local expected=$3
  local metadata
  metadata=$(make_patch_case "$case_name" "$mutation")
  local case_root workspace artifact bare base_sha digest
  case_root=$(printf '%s\n' "$metadata" | sed -n '1p')
  workspace=$(printf '%s\n' "$metadata" | sed -n '2p')
  artifact=$(printf '%s\n' "$metadata" | sed -n '3p')
  bare=$(printf '%s\n' "$metadata" | sed -n '4p')
  base_sha=$(printf '%s\n' "$metadata" | sed -n '5p')
  digest=$(printf '%s\n' "$metadata" | sed -n '6p')
  local output=${case_root}/output
  local push_log=${case_root}/push.bin
  local captured
  if captured=$(run_publish "$case_root" "$workspace" "$artifact" "$output" \
    "$digest" 1 "$base_sha" "$bare" "$push_log" 2>&1); then
    fail_test "publish accepted ${case_name} patch"
  fi
  if [[ "$captured" != *"$expected"* ]]; then
    printf '%s\n' "$captured" >&2
    fail_test "publish ${case_name} rejection did not contain expected diagnostic"
  fi
  [[ ! -e "$push_log" || ! -s "$push_log" ]] || fail_test "publish pushed rejected ${case_name} patch"
}

# The write-authorized job revalidates the artifact independently.
assert_publish_rejected_patch non-md non-md 'non-Markdown file'
assert_publish_rejected_patch add add 'file mode or file identity'
assert_publish_rejected_patch delete delete 'file mode or file identity'
assert_publish_rejected_patch rename rename 'file mode or file identity'
assert_publish_rejected_patch mode mode 'file mode or file identity'
assert_publish_rejected_patch symlink symlink 'file mode or file identity'

# An otherwise valid patch must not be applied to a dirty publication checkout.
dirty_metadata=$(make_patch_case untracked md)
dirty_root=$(printf '%s\n' "$dirty_metadata" | sed -n '1p')
dirty_workspace=$(printf '%s\n' "$dirty_metadata" | sed -n '2p')
dirty_artifact=$(printf '%s\n' "$dirty_metadata" | sed -n '3p')
dirty_bare=$(printf '%s\n' "$dirty_metadata" | sed -n '4p')
dirty_base=$(printf '%s\n' "$dirty_metadata" | sed -n '5p')
dirty_digest=$(printf '%s\n' "$dirty_metadata" | sed -n '6p')
printf '# unexpected\n' >"$dirty_workspace/untracked.md"
if dirty_captured=$(run_publish "$dirty_root" "$dirty_workspace" "$dirty_artifact" \
  "$dirty_root/output" "$dirty_digest" 1 "$dirty_base" "$dirty_bare" "$dirty_root/push.bin" 2>&1); then
  fail_test 'publish accepted an untracked working-tree file'
fi
[[ "$dirty_captured" == *'publication checkout is not clean'* ]] ||
  fail_test 'untracked publication rejection diagnostic is missing'

# Pull-request contexts are rejected at runtime, even with a valid artifact.
event_metadata=$(make_patch_case pull-request md)
event_root=$(printf '%s\n' "$event_metadata" | sed -n '1p')
event_workspace=$(printf '%s\n' "$event_metadata" | sed -n '2p')
event_artifact=$(printf '%s\n' "$event_metadata" | sed -n '3p')
event_bare=$(printf '%s\n' "$event_metadata" | sed -n '4p')
event_base=$(printf '%s\n' "$event_metadata" | sed -n '5p')
event_digest=$(printf '%s\n' "$event_metadata" | sed -n '6p')
if event_captured=$(run_publish "$event_root" "$event_workspace" "$event_artifact" \
  "$event_root/output" "$event_digest" 1 "$event_base" "$event_bare" "$event_root/push.bin" \
  pull_request_target 2>&1); then
  fail_test 'publish accepted pull_request_target'
fi
[[ "$event_captured" == *'pull request events are not allowed'* ]] ||
  fail_test 'pull-request event rejection diagnostic is missing'

# A concurrent remote update must produce a non-fast-forward failure; the
# workflow must never overwrite it.
race_metadata=$(make_patch_case race md)
race_root=$(printf '%s\n' "$race_metadata" | sed -n '1p')
race_workspace=$(printf '%s\n' "$race_metadata" | sed -n '2p')
race_artifact=$(printf '%s\n' "$race_metadata" | sed -n '3p')
race_bare=$(printf '%s\n' "$race_metadata" | sed -n '4p')
race_base=$(printf '%s\n' "$race_metadata" | sed -n '5p')
race_digest=$(printf '%s\n' "$race_metadata" | sed -n '6p')
race_advancer=${race_root}/advancer
"$real_git" clone -q "$race_bare" "$race_advancer"
printf '\nremote advanced\n' >>"$race_advancer/config.txt"
commit_all "$race_advancer" 'concurrent remote update'
git_in "$race_advancer" push -q origin main
advanced_sha=$("$real_git" --git-dir="$race_bare" rev-parse refs/heads/main)
if race_captured=$(run_publish "$race_root" "$race_workspace" "$race_artifact" \
  "$race_root/output" "$race_digest" 1 "$race_base" "$race_bare" "$race_root/push.bin" 2>&1); then
  fail_test 'publish overwrote a concurrently advanced branch'
fi
[[ "$race_captured" == *'non-force push failed'* ]] || fail_test 'race rejection diagnostic is missing'
[[ $("$real_git" --git-dir="$race_bare" rev-parse refs/heads/main) == "$advanced_sha" ]] ||
  fail_test 'remote advancement was overwritten'
if tr '\0' '\n' <"$race_root/push.bin" | grep -E -- '--force($|=)|--force-with-lease' >/dev/null; then
  fail_test 'race path attempted a force push'
fi

printf 'update workflow behavioral tests passed\n'
