#!/usr/bin/env bash
# Extended-stable migration, shared by laptops and GitHub Actions.
#
#   make migrate-plan      # print the decision; write it in the git directory
#   make migrate-prepare   # fetch the milestone; requires HEAD on the fork
#   make migrate-open      # check the merge, push, open the pull request
#   make migrate-issue     # comment when migrate-stop.txt explains a stop
#
# FORCE=1 skips the open/merged pull-request check. It does not run when
# the fork is already on extended stable, and it does not force-push.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
GATE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/migration_gate.py"
DISCOVER="$REPO/agents/skills/migrate/scripts/discover_stable.py"
GIT_DIR="$(git -C "$REPO" rev-parse --absolute-git-dir)"
PLAN="$GIT_DIR/migrate-plan.json"
CODEX_HOME_DIR="$GIT_DIR/codex-home"
PROMPT_FILE="$GIT_DIR/migrate-prompt.md"

cd "$REPO"

require_stream_repo() {
  local origin
  origin="$(git remote get-url origin)"
  case "$origin" in
    *GetStream/webrtc*) ;;
    *)
      echo "origin is not GetStream/webrtc ($origin)." >&2
      exit 1
      ;;
  esac
}

select_fork() {
  git fetch --no-tags origin "+refs/heads/main:refs/remotes/origin/main"
  # Match refs/heads/develop exactly. A bare pattern also matches backup/develop.
  if git ls-remote --exit-code origin refs/heads/develop >/dev/null; then
    git fetch --no-tags origin "+refs/heads/develop:refs/remotes/origin/develop"
    fork_branch="develop"
    fork_reason="origin/develop exists"
  else
    git remote set-head origin --auto
    fork_branch="$(git symbolic-ref --short refs/remotes/origin/HEAD)"
    fork_branch="${fork_branch#origin/}"
    fork_reason="origin/develop is absent"
  fi
  case "$fork_branch" in
    *[!A-Za-z0-9._/-]*|"")
      echo "Unexpected fork branch ${fork_branch}." >&2
      exit 1
      ;;
  esac
  git fetch --no-tags origin "+refs/heads/${fork_branch}:refs/remotes/origin/${fork_branch}"
  git fetch --no-tags origin "+refs/heads/webrtc/m*:refs/remotes/origin/webrtc/m*"
}

collect_milestone() {
  local fork_ref="$1" ref name number compare_status
  : > "$workdir/ancestors.txt"
  while read -r ref; do
    [ -n "$ref" ] || continue
    name="${ref##*/}"
    case "$name" in
      m[0-9]*) ;;
      *) continue ;;
    esac
    number="${name#m}"
    case "$number" in
      *[!0-9]*) continue ;;
    esac
    if git merge-base --is-ancestor "$ref" "$fork_ref"; then
      echo "$number" >> "$workdir/ancestors.txt"
    else
      compare_status="$?"
      if [ "$compare_status" -ne 1 ]; then
        echo "Could not compare ${ref} with ${fork_ref}." >&2
        exit "$compare_status"
      fi
    fi
  done < <(git for-each-ref --format='%(refname:short)' 'refs/remotes/origin/webrtc/m*')

  {
    git log "$fork_ref" --format='%s' --grep='Upgrade to m'
    git log "$fork_ref" --merges --format='%s' --grep='Merge WebRTC M'
    git log "$fork_ref" --format='%s' --grep='Migrate to version M'
  } > "$workdir/subjects.txt"

  python3 "$GATE" current \
    --ancestors-file "$workdir/ancestors.txt" \
    --subjects-file "$workdir/subjects.txt"
}

read_plan() {
  [ -f "$PLAN" ] || { echo "Run make migrate-plan first." >&2; exit 1; }
  plan_get() {
    python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get(sys.argv[2], ""))' "$PLAN" "$1"
  }
}

cmd_plan() {
  require_stream_repo
  select_fork
  local current fork_ref
  fork_ref="refs/remotes/origin/${fork_branch}"
  current="$(collect_milestone "$fork_ref")"
  echo "Fork milestone is M${current}."
  python3 "$DISCOVER" --current "$current" > "$workdir/discovery.json"

  gh pr list --repo GetStream/webrtc --state open --limit 50 \
    --search "head:merge-webrtc-m" --json headRefName \
    --jq '.[].headRefName' > "$workdir/open-heads.txt"
  gh pr list --repo GetStream/webrtc --state merged --limit 50 \
    --search "head:merge-webrtc-m" --json headRefName \
    --jq '.[].headRefName' > "$workdir/merged-heads.txt"

  set -- python3 "$GATE" decide \
    --discovery "$workdir/discovery.json" \
    --open-heads "$workdir/open-heads.txt" \
    --merged-heads "$workdir/merged-heads.txt"
  if [ -n "${GITHUB_OUTPUT:-}" ]; then
    set -- "$@" --github-output "$GITHUB_OUTPUT"
  fi
  if [ "${FORCE:-}" = "1" ] || [ "${FORCE:-}" = "true" ]; then
    set -- "$@" --force
  fi
  "$@" | tee "$workdir/decision.json"

  FORK_BRANCH="$fork_branch" FORK_REASON="$fork_reason" \
    python3 - "$workdir/decision.json" "$PLAN" <<'PY'
import json
import os
import sys
document = json.load(open(sys.argv[1]))
document["fork_branch"] = os.environ["FORK_BRANCH"]
document["fork_reason"] = os.environ["FORK_REASON"]
with open(sys.argv[2], "w") as handle:
    json.dump(document, handle, indent=2)
    handle.write("\n")
PY
  if [ -n "${GITHUB_OUTPUT:-}" ]; then
    {
      echo "fork_branch=${fork_branch}"
      echo "fork_reason=${fork_reason}"
    } >> "$GITHUB_OUTPUT"
  fi
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    python3 - "$workdir/decision.json" <<'PY' >> "$GITHUB_STEP_SUMMARY"
import json, sys
document = json.load(open(sys.argv[1]))
print("### Extended stable migration")
print()
print("Run Codex." if document["should_run"] else "Skip.")
print(document["reason"])
PY
  fi
}

cmd_prepare() {
  require_stream_repo
  read_plan
  local ref fork_branch fork_sha head_sha
  ref="$(plan_get ref)"
  fork_branch="$(plan_get fork_branch)"
  case "$ref" in
    refs/branch-heads/[0-9]*) ;;
    *) echo "Unexpected official ref ${ref}." >&2; exit 1 ;;
  esac
  case "$fork_branch" in
    *[!A-Za-z0-9._/-]*|"") echo "Unexpected fork branch." >&2; exit 1 ;;
  esac
  git fetch --no-tags origin "+refs/heads/${fork_branch}:refs/remotes/origin/${fork_branch}"
  fork_sha="$(git rev-parse "refs/remotes/origin/${fork_branch}")"
  head_sha="$(git rev-parse HEAD)"
  if [ "$head_sha" != "$fork_sha" ]; then
    echo "Check out ${fork_branch} (${fork_sha}) before prepare. HEAD is ${head_sha}." >&2
    exit 1
  fi
  if ! git remote get-url official >/dev/null 2>&1; then
    git remote add official https://webrtc.googlesource.com/src
  fi
  git fetch --no-tags official "$ref"
  echo "Prefetched ${ref} at $(git rev-parse FETCH_HEAD)."
  if ! git config user.name >/dev/null; then
    git config user.name "github-actions[bot]"
    git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
  fi
  if [ -n "${GITHUB_ACTIONS:-}" ]; then
    git config --local --unset-all "http.https://github.com/.extraheader" || true
    if git config --local --get "http.https://github.com/.extraheader" >/dev/null; then
      echo "Git config still contains an authorization header." >&2
      exit 1
    fi
  fi
  python3 - "$PLAN" "$fork_sha" <<'PY'
import json, sys
document = json.load(open(sys.argv[1]))
document["fork_sha"] = sys.argv[2]
with open(sys.argv[1], "w") as handle:
    json.dump(document, handle, indent=2)
    handle.write("\n")
PY
  mkdir -p "$CODEX_HOME_DIR"
  cat > "$CODEX_HOME_DIR/config.toml" <<'EOF'
approval_policy = "never"

[features]
network_proxy = true

[permissions.migrate]
extends = ":workspace"
description = "Merge extended stable. Git metadata is writable. Network reaches only the milestone feeds."

[permissions.migrate.filesystem.":workspace_roots"]
".git" = "write"

[permissions.migrate.network]
enabled = true

[permissions.migrate.network.domains]
"chromiumdash.appspot.com" = "allow"
"webrtc.googlesource.com" = "allow"
"*.googlesource.com" = "allow"
EOF
  python3 - "$PLAN" "$PROMPT_FILE" <<'PY'
import json, sys
document = json.load(open(sys.argv[1]))
prompt = """Run the migrate skill at agents/skills/migrate/SKILL.md from this git root.

The fork branch is {fork} because {reason}.
The extended stable ref {ref} is already fetched on the official remote.
If a later fetch of that same ref fails, use the tip already fetched. Do not stop for that network failure.

This run is unattended. When the skill says to stop and ask, write the reason to migrate-stop.txt and exit non-zero.
If another upgrade branch is not contained in the fork, stop that way. Do not pick a different fork.

Do not push.
Do not run gh.
Do not run a build.
Do not run gclient.
Do not force-push.
Do not merge the pull request.

Follow discover-stable.md, merge-forward.md, and resolve-conflicts.md.
Write the pull request body to migrate-pr-body.md using the outline in agents/skills/migrate/pull-request.md.
Do not commit migrate-pr-body.md or migrate-stop.txt.

A clean merge still needs migrate-pr-body.md.
The workflow opens the pull request after you exit.
""".format(
    fork=document["fork_branch"],
    reason=document["fork_reason"],
    ref=document["ref"],
)
with open(sys.argv[2], "w") as handle:
    handle.write(prompt)
PY
  if [ -n "${GITHUB_OUTPUT:-}" ]; then
    echo "fork_sha=${fork_sha}" >> "$GITHUB_OUTPUT"
  fi
  echo "Prepared ${fork_branch} at ${fork_sha}."
}

with_origin_auth() {
  if [ -n "${GITHUB_ACTIONS:-}" ]; then
    local token="${GH_TOKEN:-${GITHUB_TOKEN:-}}"
    git -c "http.extraheader=AUTHORIZATION: bearer ${token}" "$@"
  else
    git "$@"
  fi
}

git_push() {
  local hooks="$workdir/no-hooks"
  mkdir -p "$hooks"
  with_origin_auth -c "core.hooksPath=${hooks}" push origin "$1"
}

# Use a value the workflow decided before Codex ran. Codex can write the git
# directory, including the plan file, so a disagreement fails closed.
take_decision() {
  local label="$1" trusted="$2" recorded="$3"
  if [ -n "$trusted" ] && [ "$trusted" != "$recorded" ]; then
    echo "${label} in the plan does not match the decision." >&2
    exit 1
  fi
  printf '%s' "${trusted:-$recorded}"
}

cmd_open() {
  require_stream_repo
  read_plan
  local milestone ref fork_branch upgrade baseline fork_sha official_sha count
  milestone="$(take_decision Milestone "${MILESTONE:-}" "$(plan_get milestone)")"
  ref="$(take_decision "Official ref" "${OFFICIAL_REF:-}" "$(plan_get ref)")"
  fork_branch="$(take_decision "Fork branch" "${FORK_BRANCH:-}" "$(plan_get fork_branch)")"
  upgrade="$(take_decision "Upgrade branch" "${UPGRADE_BRANCH:-}" "$(plan_get upgrade_branch)")"
  baseline="$(take_decision "Baseline branch" "${BASELINE_BRANCH:-}" "$(plan_get baseline_branch)")"
  fork_sha="$(take_decision "Fork tip" "${FORK_SHA:-}" "$(plan_get fork_sha)")"
  case "$milestone" in
    [0-9]*) ;;
    *) echo "Unexpected milestone." >&2; exit 1 ;;
  esac
  case "$upgrade" in
    merge-webrtc-m[0-9]*) ;;
    *) echo "Unexpected upgrade branch." >&2; exit 1 ;;
  esac
  case "$baseline" in
    webrtc/m[0-9]*) ;;
    *) echo "Unexpected baseline branch." >&2; exit 1 ;;
  esac
  case "$ref" in
    refs/branch-heads/[0-9]*) ;;
    *) echo "Unexpected official ref." >&2; exit 1 ;;
  esac
  if [ -s migrate-stop.txt ]; then
    echo "Migration stopped. See migrate-stop.txt." >&2
    exit 1
  fi
  if [ ! -s migrate-pr-body.md ]; then
    echo "migrate-pr-body.md is missing." >&2
    exit 1
  fi
  if grep -E -q '<(full hash|milestone|milestone or same|name|reason|count|path)>' migrate-pr-body.md; then
    echo "The pull request body still has a placeholder." >&2
    exit 1
  fi
  if ! grep -q "M${milestone}" migrate-pr-body.md; then
    echo "The pull request body does not name M${milestone}." >&2
    exit 1
  fi
  cp migrate-pr-body.md "$workdir/pr-body.md"
  if [ -n "${GITHUB_RUN_ID:-}" ]; then
    printf '\nWorkflow run: %s/%s/actions/runs/%s\n' \
      "${GITHUB_SERVER_URL}" "${GITHUB_REPOSITORY}" "${GITHUB_RUN_ID}" \
      >> "$workdir/pr-body.md"
  fi
  if git rev-parse --verify --quiet MERGE_HEAD >/dev/null; then
    echo "A merge is still in progress." >&2
    exit 1
  fi
  if [ -n "$(git diff --name-only --diff-filter=U)" ]; then
    echo "Unmerged files remain." >&2
    exit 1
  fi
  git rev-parse --verify "refs/heads/${upgrade}" >/dev/null
  git rev-parse --verify "refs/heads/${baseline}" >/dev/null
  local path
  for path in migrate-pr-body.md migrate-stop.txt; do
    if git cat-file -e "${upgrade}:${path}" 2>/dev/null; then
      echo "${path} is in the upgrade commit." >&2
      exit 1
    fi
  done
  with_origin_auth fetch --no-tags origin "+refs/heads/${fork_branch}:refs/remotes/origin/${fork_branch}"
  if ! git merge-base --is-ancestor "$fork_sha" "refs/remotes/origin/${fork_branch}"; then
    echo "The fork moved in a way that drops the recorded tip." >&2
    exit 1
  fi
  git fetch --no-tags official "$ref"
  official_sha="$(git rev-parse FETCH_HEAD)"
  if ! printf '%s' "$official_sha" | grep -Eq '^[0-9a-f]{40}$'; then
    echo "Official tip is not a full commit hash." >&2
    exit 1
  fi
  count="$(git rev-list --first-parent --count "${fork_sha}..${upgrade}")"
  set -- python3 "$GATE" check-merge \
    --fork-sha "$fork_sha" \
    --official-sha "$official_sha" \
    --baseline-sha "$(git rev-parse "refs/heads/${baseline}")" \
    --first-parent-count "$count"
  while read -r parent; do
    [ -n "$parent" ] || continue
    set -- "$@" --head-parent "$parent"
    if [ "$count" = "2" ] && [ -z "${first_parent:-}" ]; then
      first_parent="$parent"
    fi
  done < <(git rev-parse "${upgrade}^@")
  if [ "$count" = "2" ]; then
    while read -r parent; do
      [ -n "$parent" ] || continue
      set -- "$@" --repair-parent "$parent"
    done < <(git rev-parse "${first_parent}^@")
  fi
  "$@"
  git_push "refs/heads/${baseline}:refs/heads/${baseline}"
  git_push "refs/heads/${upgrade}:refs/heads/${upgrade}"
  local title url
  title="[Automated]Migrate to version M${milestone} ${official_sha}"
  if ! url="$(gh pr create \
    --repo GetStream/webrtc \
    --base "$fork_branch" \
    --head "$upgrade" \
    --title "$title" \
    --body-file "$workdir/pr-body.md")"; then
    url="$(gh pr list --repo GetStream/webrtc --state open \
      --head "$upgrade" --json url --jq '.[0].url')"
    if [ -z "$url" ]; then
      echo "The pull request was not created." >&2
      exit 1
    fi
  fi
  echo "$url"
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    echo "$url" >> "$GITHUB_STEP_SUMMARY"
  fi
}

cmd_issue() {
  if [ ! -s migrate-stop.txt ]; then
    echo "No stop file."
    exit 0
  fi
  read_plan
  local milestone title number
  milestone="$(take_decision Milestone "${MILESTONE:-}" "$(plan_get milestone)")"
  title="Migration to M${milestone} needs a decision"
  {
    echo "The migration to M${milestone} stopped before it opened a pull request."
    echo
    head -c 6000 migrate-stop.txt
    echo
    echo
    if [ -n "${GITHUB_RUN_ID:-}" ]; then
      printf 'Workflow run: %s/%s/actions/runs/%s\n' \
        "${GITHUB_SERVER_URL}" "${GITHUB_REPOSITORY}" "${GITHUB_RUN_ID}"
    fi
  } > "$workdir/issue.md"
  number="$(gh issue list --repo GetStream/webrtc --state open --limit 20 \
    --search "in:title ${title}" --json number,title \
    --jq ".[] | select(.title == \"${title}\") | .number" | head -n 1)"
  if [ -n "$number" ]; then
    gh issue comment --repo GetStream/webrtc "$number" --body-file "$workdir/issue.md"
  else
    gh issue create --repo GetStream/webrtc --title "$title" --body-file "$workdir/issue.md"
  fi
}

selftest() {
  local result
  result="$(take_decision Milestone 156 156)"
  [ "$result" = "156" ]
  result="$(take_decision Milestone "" 156)"
  [ "$result" = "156" ]
  if ( take_decision Milestone 145 156 >/dev/null 2>&1 ); then
    echo "A mismatched plan must fail." >&2
    exit 1
  fi
  echo "migrate.sh selftest passed"
}

workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT

case "${1:-}" in
  plan) cmd_plan ;;
  prepare) cmd_prepare ;;
  open) cmd_open ;;
  issue) cmd_issue ;;
  selftest) selftest ;;
  *)
    echo "usage: migrate.sh plan|prepare|open|issue" >&2
    exit 2
    ;;
esac
