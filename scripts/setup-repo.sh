#!/usr/bin/env bash
# shellcheck disable=SC2015  # A && pass || fail rows: pass() prints and cannot fail — deliberate table idiom
# tools/dev/setup-repo.sh — idempotent repo doctor (SAD-177).
#
# Run once per clone/machine (and re-run any time; byte-identical output when
# healthy). Wires local enforcement, then verifies the whole ops layer:
#   1. git config: core.hooksPath .githooks, fetch.prune true; chmod +x scripts
#   2. binaries: gh (authed) + jq present
#   3. GitHub repo settings match the ADR-0023 merge policy (WARN if no remote)
#   4. .claude/settings.json wires all three Claude hooks
#   5. WARN if .claude/settings.local.json still carries a hooks key (double-firing)
# Exits non-zero on any FAIL. WARNs don't fail (scratch/offline repos stay usable).
#
# TRUST NOTE (Barb audit, PR #159): pointing core.hooksPath at the in-tree
# .githooks/ means any checked-out branch's hooks run on plain git verbs.
# Fine while every branch is Jason-authored; if untrusted branches ever enter
# the workflow, review .githooks/ before checkout.

set -u

fails=0
warns=0
pass() { printf 'PASS  %s\n' "$1"; }
fail() { printf 'FAIL  %s\n' "$1"; fails=$((fails + 1)); }
warn() { printf 'WARN  %s\n' "$1"; warns=$((warns + 1)); }

repo_root="$(git rev-parse --show-toplevel 2>/dev/null)" || {
  echo "FAIL  not inside a git repository" >&2
  exit 1
}
cd "$repo_root" || exit 1

echo "== 1. local git wiring =="
git config core.hooksPath .githooks && pass "core.hooksPath = .githooks" || fail "could not set core.hooksPath"
git config fetch.prune true && pass "fetch.prune = true" || fail "could not set fetch.prune"
# origin/HEAD makes land-pr.sh's trusted-ref config read deterministic
# (Watson/Barb PR #162); git clone sets it, a bare fetch does not.
if git remote get-url origin >/dev/null 2>&1; then
  git remote set-head origin -a >/dev/null 2>&1 \
    && pass "origin/HEAD = $(git symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null)" \
    || warn "could not set origin/HEAD (land-pr.sh then falls back to the literal origin/main tracking ref)"
fi

for f in .githooks/* .claude/hooks/*.sh tools/dev/*.sh; do
  [ -f "$f" ] || continue
  chmod +x "$f" 2>/dev/null || warn "could not chmod +x $f"
done
pass "executable bits refreshed (.githooks/, .claude/hooks/, tools/dev/)"

echo "== 2. required binaries =="
if command -v jq >/dev/null 2>&1; then
  pass "jq present ($(jq --version 2>/dev/null))"
else
  fail "jq missing — pre-bash-safety fails CLOSED without it (sudo apt install jq)"
fi
if command -v gh >/dev/null 2>&1; then
  if gh auth status >/dev/null 2>&1; then
    pass "gh present and authenticated"
  elif git remote get-url origin >/dev/null 2>&1; then
    fail "gh present but NOT authenticated — the land-pr.sh funnel is inoperable (gh auth login)"
  else
    warn "gh present but not authenticated (no origin remote — scratch repo?)"
  fi
else
  fail "gh missing — land-pr.sh and repo-settings checks need it"
fi
pd="$(git config push.default 2>/dev/null || true)"
case "${pd:-simple}" in
  simple|current) pass "push.default = ${pd:-simple (git default)}" ;;
  *) warn "push.default = $pd — 'matching'/'upstream' can push main on a bare push; set simple or current" ;;
esac

echo "== 3. GitHub repo settings (ADR-0023 merge policy) =="
if git remote get-url origin >/dev/null 2>&1 && command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
  settings="$(gh api "repos/{owner}/{repo}" --jq '{dbm: .delete_branch_on_merge, mc: .allow_merge_commit, rb: .allow_rebase_merge, sq: .allow_squash_merge, title: .squash_merge_commit_title, body: .squash_merge_commit_message}' 2>/dev/null)" || settings=""
  if [ -z "$settings" ]; then
    warn "could not read repo settings from the GitHub API"
  else
    check_setting() { # $1 = jq path, $2 = expected, $3 = label
      actual="$(jq -r "$1" <<<"$settings")"
      if [ "$actual" = "$2" ]; then pass "$3 = $2"; else fail "$3 = $actual (expected $2) — run the Slice-1 console ops (gh repo edit / PATCH)"; fi
    }
    check_setting '.dbm'   'true'     'delete_branch_on_merge'
    check_setting '.mc'    'false'    'allow_merge_commit'
    check_setting '.rb'    'false'    'allow_rebase_merge'
    check_setting '.sq'    'true'     'allow_squash_merge'
    check_setting '.title' 'PR_TITLE' 'squash_merge_commit_title'
    check_setting '.body'  'PR_BODY'  'squash_merge_commit_message'
  fi
else
  warn "no origin remote (or gh unauthenticated) — skipping repo-settings verification"
fi

echo "== 4. Claude hook wiring (.claude/settings.json) =="
if [ -f .claude/settings.json ] && command -v jq >/dev/null 2>&1; then
  hook_wired() { # $1 = event, $2 = script name, $3 = matcher
    jq -e --arg m "$3" ".hooks.$1[] | select(.matcher == \$m) | .hooks[].command | select(contains(\"$2\"))" .claude/settings.json >/dev/null 2>&1
  }
  hook_wired PreToolUse  pre-bash-safety.sh      'Bash' && pass "PreToolUse[Bash] → pre-bash-safety.sh"      || fail "PreToolUse[Bash] missing pre-bash-safety.sh"
  hook_wired PostToolUse post-bash-secret-scan.sh 'Bash' && pass "PostToolUse[Bash] → post-bash-secret-scan.sh" || fail "PostToolUse[Bash] missing post-bash-secret-scan.sh"
  hook_wired PostToolUse lint-on-edit.sh 'Edit|Write|MultiEdit' && pass "PostToolUse[Edit|Write|MultiEdit] → lint-on-edit.sh" || fail "PostToolUse edit-matcher missing lint-on-edit.sh"
else
  fail ".claude/settings.json missing (or jq unavailable) — the committed hook layer is not wired"
fi

echo "== 5. double-firing check (.claude/settings.local.json) =="
if [ -f .claude/settings.local.json ] && command -v jq >/dev/null 2>&1 && jq -e '.hooks' .claude/settings.local.json >/dev/null 2>&1; then
  warn "settings.local.json still has a hooks key — hooks will fire twice; delete the key (Slice-1 local-only step)"
else
  pass "no hooks key in settings.local.json"
fi

echo ""
echo "RESULT: ${fails} failed, ${warns} warned"
[ "$fails" -eq 0 ]
