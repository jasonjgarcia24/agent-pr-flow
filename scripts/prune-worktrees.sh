#!/usr/bin/env bash
# tools/dev/prune-worktrees.sh — worktree cleanup detection + execution ({{ISSUE_KEY}}-418).
#
# Usage:
#   tools/dev/prune-worktrees.sh [detect]     read-only: categorize every non-primary worktree
#   tools/dev/prune-worktrees.sh remove <path> execute removal for ONE worktree (re-validates first)
#
# This script never talks to the issue tracker — it only knows git + GitHub PR state. The
# Radar-confirms-tracker-Done / Hubert-executes split ({{ISSUE_KEY}}-418) lives one layer up, in
# the callers (.claude/commands/prune-worktrees.md, .claude/commands/land.md): they run
# `detect`, have Radar confirm each {{ISSUE_KEY}}-N candidate reached Done, then call `remove <path>`
# per Radar-confirmed candidate. `remove` re-checks merged+exact-head+clean itself — it
# never trusts a caller's say-so blindly.
#
# detect output — one line per worktree, space-separated fields:
#   SAFE     <path> <branch> <issue-id-or-dash> <pr-number>
#   DIRTY    <path> <branch> <issue-id-or-dash> <pr-number>   # merged PR, uncommitted changes — never auto-removed
#   ACTIVE   <path> <branch> <issue-id-or-dash> <pr-number> <pr-state>  # PR open — never touch
#   ORPHAN   <path> <branch> <issue-id-or-dash>               # PR closed-unmerged or not found — needs a human call
#   LOCKED   <path> <branch> <issue-id-or-dash>               # an active session holds this worktree — never touch
#   DETACHED <path>                                           # no branch checked out — needs a human call
#   UNKNOWN  <path> <branch> <issue-id-or-dash>               # couldn't read worktree status — needs a human call
#
# `remove` refuses (exit 1, message on stderr) unless ALL of: PR is MERGED, the worktree's
# HEAD is EXACTLY the PR's merged commit (not just "clean" — a clean-but-unpushed local
# commit on a "merged" branch must not be force-deleted), the worktree isn't locked, and
# the caller isn't running from inside the path it's asking to remove (self-removal leaves
# the process's cwd unresolvable and the subsequent branch delete fails in a confusing way).

set -u

REPO_ROOT="$(git rev-parse --show-toplevel)"
cd "$REPO_ROOT" || exit 1

issue_id_for() {
  local branch="$1" id
  # The digit class is ENUMERATED ([0123456789]), never the range [0-9] — the
  # same live defect fixed in land-pr.sh, on the same id shape. GNU grep
  # 3.11 under an en_US.UTF-8 locale overruns the reported MATCH EXTENT of a
  # range bracket expression when a non-ASCII decimal digit follows an ASCII
  # one, so `grep -o` EMITS the trailing garbage:
  #
  #   printf 'xx-538\xd9\xa5' | grep -ioE 'xx-[0-9]+'        -> xx-538<d9 a5>
  #   printf 'xx-538\xd9\xa5' | grep -ioE 'xx-[0123456789]+' -> xx-538
  #
  # It is NOT class membership — the defect is in `-o` match EXTENT, which is why
  # it matters wherever an id is EXTRACTED rather than merely tested. 513 of the
  # 670 non-ASCII Unicode Nd codepoints leak through the range in a non-leading
  # position; 0 through the enumerated class. Impact here is lower than in
  # land-pr.sh — a corrupted id fails the tracker lookup, so a worktree is NOT
  # removed (fail-closed) — but the two scripts must not drift on the same fix.
  #
  # `grep -i` makes the rendered {{ISSUE_KEY}} match either case in a branch name,
  # and `-o` echoes the branch's own spelling, which `tr` then normalizes up.
  # ⚠ READ AT RUNTIME, NEVER RENDERED. This line used to carry a literal
  # {{ISSUE_KEY}} placeholder, which install.sh substituted raw into the middle
  # of a single-quoted grep ERE. An issueKey containing a single quote closed the
  # string literal and the remainder executed as shell — proven end-to-end against
  # the real installer (Barb, PR #9): `SAD'; id > /tmp/x; :'` yielded arbitrary
  # command execution in every adopter, on the routine /land close-out step, in a
  # generated file reviewers skim as boilerplate. install.sh validates exactly one
  # config value (CODE_TIER_POLICY); the other six substitute raw.
  #
  # Every sibling script — land-pr.sh, all three hooks, githooks/pre-push,
  # setup-repo.sh — is placeholder-free and reads config through jq at runtime.
  # land-pr.sh even passes the check name to jq as --arg DATA for exactly this
  # reason. This script was the bundle's only config-into-executable
  # interpolation; it now follows the same convention.
  #
  # The key is used as grep DATA via -e, never as pattern source, so no value can
  # reach the shell as code. Anchoring is preserved by building the ERE from the
  # quoted key at runtime rather than by substitution at install time.
  local key
  key="$(jq -r '.tracker.issueKey // empty' "$REPO_ROOT/.claude/workflow.config.json" 2>/dev/null)"
  # Fail CLOSED on a missing//malformed key: an empty or non-alphanumeric key
  # would otherwise build an ERE matching every branch. Allowlist the charset —
  # do not enumerate metacharacters to reject (SAD-546's lesson).
  case "$key" in
    ""|*[!A-Za-z0-9_]*)
      echo "prune-worktrees: FAIL — tracker.issueKey missing or invalid (allowed: A-Z a-z 0-9 _)" >&2
      echo "-"; return 1 ;;
  esac
  id=$(grep -ioE -e "$key-[0123456789]+" <<<"$branch" | head -1 | tr '[:lower:]' '[:upper:]')
  echo "${id:--}"
}

# prints "<state> <number> <headRefOid-or-dash>" — state is MERGED/OPEN/CLOSED/NONE.
# Picks the highest PR number (most recent) if a branch somehow has more than one PR.
pr_info_for() {
  local branch="$1"
  gh pr list --head "$branch" --state all --json number,state,headRefOid \
    --jq 'sort_by(.number) | reverse | if length>0 then "\(.[0].state) \(.[0].number) \(.[0].headRefOid)" else "NONE - -" end' \
    2>/dev/null || echo "NONE - -"
}

# Iterates `git worktree list --porcelain` worktrees (skipping entry 0, the main worktree
# — porcelain always lists it first, regardless of which worktree this script runs from),
# calling: callback <path> <branch-or-empty-if-detached> <locked:0|1>
each_worktree() {
  local cb="$1"
  local wt_path="" branch="" locked=0 index=-1

  flush() {
    [ "$index" -gt 0 ] && [ -n "$wt_path" ] && "$cb" "$wt_path" "$branch" "$locked"
  }

  while IFS= read -r line; do
    case "$line" in
      "worktree "*)
        flush
        wt_path="${line#worktree }"; branch=""; locked=0; index=$((index + 1))
        ;;
      "branch refs/heads/"*) branch="${line#branch refs/heads/}" ;;
      "locked"*) locked=1 ;;
    esac
  done < <(git worktree list --porcelain)
  flush
}

detect_one() {
  local path="$1" branch="$2" locked="$3"

  if [ -z "$branch" ]; then
    echo "DETACHED $path"
    return
  fi

  local issue; issue=$(issue_id_for "$branch")

  if [ "$locked" = "1" ]; then
    echo "LOCKED $path $branch $issue"
    return
  fi

  local status_out status_rc
  status_out=$(git -C "$path" status --porcelain 2>/dev/null); status_rc=$?

  local info; info=$(pr_info_for "$branch")
  local state num
  state=$(awk '{print $1}' <<<"$info")
  num=$(awk '{print $2}' <<<"$info")

  if [ "$status_rc" -ne 0 ]; then
    echo "UNKNOWN $path $branch $issue"
    return
  fi

  case "$state" in
    MERGED)
      if [ -z "$status_out" ]; then
        echo "SAFE $path $branch $issue $num"
      else
        echo "DIRTY $path $branch $issue $num"
      fi
      ;;
    OPEN)
      echo "ACTIVE $path $branch $issue $num $state"
      ;;
    *)
      echo "ORPHAN $path $branch $issue"
      ;;
  esac
}

cmd_detect() {
  # `return 0` is load-bearing: with no non-primary worktrees, each_worktree's final
  # `flush` short-circuits on `[ $index -gt 0 ]` and returns 1, so "nothing to prune" —
  # the ordinary steady state — would exit non-zero and read to the caller as a failed
  # detect. The command's whole contract is that it is a read-only report.
  each_worktree detect_one
  return 0
}

# true (rc 0) if `path` is registered as a locked worktree in `git worktree list --porcelain`
is_locked() {
  local target="$1" wt_path="" locked=0
  while IFS= read -r line; do
    case "$line" in
      "worktree "*) wt_path="${line#worktree }"; locked=0 ;;
      "locked"*) locked=1 ;;
    esac
    if [ "$wt_path" = "$target" ] && [ "$locked" = "1" ]; then
      return 0
    fi
  done < <(git worktree list --porcelain)
  return 1
}

cmd_remove() {
  local path="${1:-}"
  [ -n "$path" ] || { echo "usage: $0 remove <path>" >&2; exit 1; }
  [ -d "$path" ] || { echo "REFUSE: no such worktree path: $path" >&2; exit 1; }

  # Self-removal guard: if this script's own cwd (REPO_ROOT, resolved at startup from
  # wherever it was invoked) is on or under the target path, `git worktree remove` still
  # "succeeds" but leaves the process's cwd unresolvable, and the branch delete that
  # follows fails in a way that reads like an unrelated problem. Refuse clearly instead.
  local repo_real target_real
  repo_real=$(cd -- "$REPO_ROOT" && pwd -P)
  target_real=$(cd -- "$path" && pwd -P) || { echo "REFUSE: cannot resolve $path" >&2; exit 1; }
  case "$repo_real" in
    "$target_real"|"$target_real"/*)
      echo "REFUSE: currently running from inside $path — cd to a different checkout first" >&2
      exit 1
      ;;
  esac

  if is_locked "$path"; then
    echo "REFUSE: $path is locked (an active session likely holds it) — not removing" >&2
    exit 1
  fi

  local branch; branch=$(git -C "$path" rev-parse --abbrev-ref HEAD 2>/dev/null) || {
    echo "REFUSE: $path is not a git worktree" >&2; exit 1;
  }
  [ "$branch" != "HEAD" ] || { echo "REFUSE: $path is in detached HEAD state" >&2; exit 1; }

  local info; info=$(pr_info_for "$branch")
  local state merged_sha
  state=$(awk '{print $1}' <<<"$info")
  merged_sha=$(awk '{print $3}' <<<"$info")
  if [ "$state" != "MERGED" ]; then
    echo "REFUSE: $branch PR state is '$state', not MERGED — not removing" >&2
    exit 1
  fi

  local local_sha; local_sha=$(git -C "$path" rev-parse HEAD 2>/dev/null)
  if [ -z "$merged_sha" ] || [ "$local_sha" != "$merged_sha" ]; then
    echo "REFUSE: $path HEAD ($local_sha) doesn't match the PR's merged head ($merged_sha) — local commits beyond what merged?" >&2
    exit 1
  fi

  if [ -n "$(git -C "$path" status --porcelain 2>/dev/null)" ]; then
    echo "REFUSE: $path has uncommitted changes — not removing" >&2
    exit 1
  fi

  git worktree remove "$path" || { echo "FAIL: git worktree remove $path" >&2; exit 1; }
  git branch -D "$branch" || { echo "FAIL: git branch -D $branch (worktree already removed)" >&2; exit 1; }
  echo "REMOVED $path $branch"
}

case "${1:-detect}" in
  detect) cmd_detect ;;
  remove) shift; cmd_remove "${1:-}" ;;
  *) echo "usage: $0 [detect|remove <path>]" >&2; exit 1 ;;
esac
