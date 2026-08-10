#!/usr/bin/env bash
set -euo pipefail

fail() {
  printf 'graph2agent publish: %s\n' "$1" >&2
  exit 2
}

workspace_input=${GRAPH2AGENT_PUBLISH_WORKSPACE:-}
artifact_input=${GRAPH2AGENT_PUBLISH_ARTIFACT_DIRECTORY:-}
expected_digest=${GRAPH2AGENT_PUBLISH_PATCH_SHA256:-}
expected_files=${GRAPH2AGENT_PUBLISH_FILES:-}
base_sha=${GRAPH2AGENT_PUBLISH_BASE_SHA:-}
branch=${GRAPH2AGENT_PUBLISH_BRANCH:-}
commit_message=${GRAPH2AGENT_PUBLISH_COMMIT_MESSAGE:-}
repository=${GRAPH2AGENT_PUBLISH_REPOSITORY:-}
server_url=${GRAPH2AGENT_PUBLISH_SERVER_URL:-}
event_name=${GRAPH2AGENT_PUBLISH_EVENT_NAME:-}
token=${GRAPH2AGENT_PUBLISH_TOKEN:-}
test_mode=${GRAPH2AGENT_TEST_MODE:-0}
test_remote_url=${GRAPH2AGENT_TEST_REMOTE_URL:-}
runner_temp_input=${RUNNER_TEMP:-}
github_workspace_input=${GITHUB_WORKSPACE:-}
github_output=${GITHUB_OUTPUT:-}
unset GRAPH2AGENT_PUBLISH_TOKEN
unset GRAPH2AGENT_TEST_MODE GRAPH2AGENT_TEST_REMOTE_URL

case "$event_name" in
  pull_request | pull_request_target) fail "pull request events are not allowed to publish" ;;
esac
[[ -n "$event_name" && "$event_name" != *$'\n'* && "$event_name" != *$'\r'* ]] ||
  fail "event name is invalid"
[[ -n "$workspace_input" && -d "$workspace_input" && ! -L "$workspace_input" ]] ||
  fail "workspace must be an existing, non-symlink directory"
[[ -n "$github_workspace_input" && -d "$github_workspace_input" ]] ||
  fail "GITHUB_WORKSPACE must be an existing directory"
[[ -n "$runner_temp_input" && -d "$runner_temp_input" ]] ||
  fail "RUNNER_TEMP must be an existing directory"
[[ -n "$github_output" ]] || fail "GITHUB_OUTPUT is required"

github_workspace=$(cd "$github_workspace_input" && pwd -P)
workspace=$(cd "$workspace_input" && pwd -P)
runner_temp=$(cd "$runner_temp_input" && pwd -P)
case "$workspace" in
  "$github_workspace" | "$github_workspace"/*) ;;
  *) fail "workspace must stay within GITHUB_WORKSPACE" ;;
esac

[[ -n "$artifact_input" && -d "$artifact_input" && ! -L "$artifact_input" ]] ||
  fail "artifact directory must be an existing, non-symlink directory"
artifact_directory=$(cd "$artifact_input" && pwd -P)
case "$artifact_directory" in
  "$runner_temp"/*) ;;
  *) fail "artifact directory must stay within RUNNER_TEMP" ;;
esac
patch_path=${artifact_directory}/update.patch
checksum_path=${artifact_directory}/update.patch.sha256
[[ -s "$patch_path" && -f "$patch_path" && ! -L "$patch_path" ]] || fail "patch artifact is invalid"
[[ -s "$checksum_path" && -f "$checksum_path" && ! -L "$checksum_path" ]] ||
  fail "checksum artifact is invalid"
artifact_entries=0
while IFS= read -r -d '' entry; do
  [[ -f "$entry" && ! -L "$entry" ]] || fail "artifact contains a non-regular entry"
  ((artifact_entries += 1))
done < <(find "$artifact_directory" -mindepth 1 -maxdepth 1 -print0)
((artifact_entries == 2)) || fail "artifact directory must contain exactly two files"

[[ "$expected_digest" =~ ^[0-9a-f]{64}$ ]] || fail "expected patch digest is invalid"
[[ "$expected_files" =~ ^[1-9][0-9]*$ ]] || fail "expected file count is invalid"
[[ "$base_sha" =~ ^[0-9a-f]{40}$ ]] || fail "base SHA is invalid"
[[ -n "$branch" && "$branch" != *$'\n'* && "$branch" != *$'\r'* ]] || fail "branch is invalid"
case "$branch" in
  refs/* | -* | HEAD | @) fail "branch must be a short branch name" ;;
esac
git check-ref-format --branch "$branch" >/dev/null 2>&1 || fail "branch is invalid"
[[ -n "$commit_message" && ${#commit_message} -le 200 ]] || fail "commit message is invalid"
[[ "$commit_message" != *$'\n'* && "$commit_message" != *$'\r'* ]] ||
  fail "commit message must be one line"
[[ ! "$commit_message" =~ [[:cntrl:]] ]] || fail "commit message contains a control character"
case "$test_mode" in
  0)
    [[ -z "$test_remote_url" ]] || fail "test remote is forbidden in production mode"
    [[ ${GITHUB_ACTIONS:-} == true ]] || fail "production publication requires GitHub Actions"
    [[ "$repository" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || fail "repository identity is invalid"
    [[ "$server_url" == https://* ]] || fail "GitHub server URL must use HTTPS"
    [[ "$server_url" != *$'\n'* && "$server_url" != *$'\r'* ]] ||
      fail "GitHub server URL contains a line break"
    [[ -n "$token" && "$token" != *$'\n'* && "$token" != *$'\r'* ]] ||
      fail "write token is invalid"
    ;;
  1)
    [[ ${GITHUB_ACTIONS:-} != true ]] || fail "test mode is forbidden on GitHub Actions"
    [[ "$test_remote_url" == /* && -d "$test_remote_url" && ! -L "$test_remote_url" ]] ||
      fail "test remote must be an absolute, existing, non-symlink directory"
    [[ $(git --git-dir="$test_remote_url" rev-parse --is-bare-repository 2>/dev/null) == true ]] ||
      fail "test remote must be a bare Git repository"
    ;;
  *) fail "test mode is invalid" ;;
esac

expected_checksum_line="${expected_digest}  update.patch"
[[ $(<"$checksum_path") == "$expected_checksum_line" ]] || fail "checksum manifest does not match job output"
(
  cd "$artifact_directory"
  sha256sum --check --strict update.patch.sha256 >/dev/null
) || fail "patch checksum verification failed"
actual_digest=$(sha256sum "$patch_path")
actual_digest=${actual_digest%% *}
[[ "$actual_digest" == "$expected_digest" ]] || fail "patch digest does not match job output"

for variable in \
  GIT_ALTERNATE_OBJECT_DIRECTORIES \
  GIT_CONFIG_COUNT \
  GIT_CONFIG_PARAMETERS \
  GIT_CONFIG_SYSTEM \
  GIT_CONFIG_GLOBAL \
  GIT_CONFIG_KEY_0 \
  GIT_CONFIG_VALUE_0 \
  GIT_DIR \
  GIT_EXEC_PATH \
  GIT_INDEX_FILE \
  GIT_OBJECT_DIRECTORY \
  GIT_TEMPLATE_DIR \
  GIT_WORK_TREE \
  GIT_ASKPASS \
  GIT_SSH_COMMAND; do
  [[ -z ${!variable+x} ]] || fail "unsafe Git environment is present"
done

cd "$workspace"
[[ $(git rev-parse --show-toplevel) == "$workspace" ]] || fail "workspace is not a Git worktree root"
[[ $(git rev-parse HEAD) == "$base_sha" ]] || fail "checkout does not match the exact patch base"
[[ -z $(git symbolic-ref --quiet --short HEAD || true) ]] || fail "publication checkout must be detached"
[[ -z $(git status --porcelain=v1 --untracked-files=all) ]] || fail "publication checkout is not clean"
for scope in --local --global; do
  if git config "$scope" --name-only --get-regexp \
    '^(credential\.|http\..*\.extraheader$|core\.hooksPath$|core\.fsmonitor$|diff\.external$|filter\.)' \
    >/dev/null 2>&1; then
    fail "unsafe Git configuration is present"
  fi
done

git apply --check --index --binary --whitespace=error-all "$patch_path" ||
  fail "patch does not apply to the exact base"
git apply --index --binary --whitespace=error-all "$patch_path"
git diff --quiet -- || fail "patch left an unstaged working-tree difference"
git --no-pager diff --cached --no-ext-diff --no-textconv --check
if IFS= read -r -d '' _untracked < <(git ls-files --others --exclude-standard -z); then
  fail "patch created an untracked file"
fi
[[ -z $(git --no-pager diff --cached --no-ext-diff --no-textconv --summary --no-renames) ]] ||
  fail "patch changed a file mode or file identity"

files=0
while IFS= read -r -d '' status && IFS= read -r -d '' path; do
  [[ "$status" == M ]] || fail "patch is not a tracked-file modification"
  case "$path" in
    *.md) ;;
    *) fail "patch changed a non-Markdown file" ;;
  esac
  [[ -f "$path" && ! -L "$path" ]] || fail "patched Markdown path is not a regular file"
  ((files += 1))
done < <(git --no-pager diff --cached --no-ext-diff --no-textconv --name-status -z --no-renames)
((files == expected_files)) || fail "patched file count does not match the prepare job"

reproduced_patch=$(mktemp "${runner_temp%/}/graph2agent-reproduced.XXXXXX")
trap 'rm -f "$reproduced_patch"' EXIT
git --no-pager diff --cached --binary --full-index --no-ext-diff --no-textconv --no-renames -- . >"$reproduced_patch"
cmp -s "$patch_path" "$reproduced_patch" || fail "applied diff does not reproduce the checksummed patch"

git -c core.hooksPath=/dev/null \
  -c user.name='github-actions[bot]' \
  -c user.email='41898282+github-actions[bot]@users.noreply.github.com' \
  commit --no-gpg-sign -m "$commit_message"
commit_sha=$(git rev-parse HEAD)
[[ $(git rev-parse HEAD^) == "$base_sha" ]] || fail "generated commit has an unexpected parent"
[[ -z $(git status --porcelain=v1 --untracked-files=all) ]] || fail "working tree is not clean after commit"

if [[ "$test_mode" == 1 ]]; then
  unset token
  remote_url=$test_remote_url
  if ! GIT_TERMINAL_PROMPT=0 \
    git -c core.hooksPath=/dev/null push --no-verify --porcelain \
      "$remote_url" "HEAD:refs/heads/${branch}"; then
    fail "non-force push failed; the branch may have advanced or repository rules may block it"
  fi
else
  server_url=${server_url%/}
  remote_url=${server_url}/${repository}.git
  basic_auth=$(printf 'x-access-token:%s' "$token" | base64 | tr -d '\r\n')
  unset token
  printf '::add-mask::%s\n' "$basic_auth"

  if ! GIT_TERMINAL_PROMPT=0 \
    GIT_CONFIG_COUNT=1 \
    GIT_CONFIG_KEY_0="http.${server_url}/.extraheader" \
    GIT_CONFIG_VALUE_0="AUTHORIZATION: basic ${basic_auth}" \
      git -c core.hooksPath=/dev/null push --no-verify --porcelain \
        "$remote_url" "HEAD:refs/heads/${branch}"; then
    unset basic_auth
    fail "non-force push failed; the branch may have advanced or repository rules may block it"
  fi
  unset basic_auth
fi

for scope in --local --global; do
  if git config "$scope" --name-only --get-regexp '^(credential\.|http\..*\.extraheader$)' >/dev/null 2>&1; then
    fail "Git credentials persisted after push"
  fi
done
printf 'commit=%s\n' "$commit_sha" >>"$github_output"
printf 'Published %d validated Markdown file(s) to %s.\n' "$files" "$branch"
