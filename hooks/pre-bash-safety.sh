#!/usr/bin/env bash
# pre-bash-safety.sh — PreToolUse[Bash] safety gate (SAD-176).
#
# Contract (Claude Code hooks):
#   stdin:  hook payload JSON — { tool_input: { command }, cwd, ... }
#   exit 0: allow the command
#   exit 2: BLOCK the command; stderr is fed back to the model
#
# The compound command is split into segments on && || ; | & and each segment
# is run through the decision table below (D-rows: destructive-op guards,
# active EVERYWHERE; F-rows: branch-flow guards, SAD-177 — the default branch
# is PR-only per ADR-0023, and the ONLY merge path is tools/dev/land-pr.sh,
# whose internal gh pr merge runs inside its process, invisible to this hook).
# F-rows are SCOPED TO THIS PROJECT'S REPO (SAD-181): the command's repo is
# compared to CLAUDE_PROJECT_DIR's via git-common-dir (worktrees share it) —
# other repos on the machine (e.g. the agent-pr-flow bundle repo) manage their
# own branches. The default branch name loads from workflow.config.json
# (.git.defaultBranch; fallback "main"). Every rule matches against a
# NORMALIZED copy of the segment (quotes stripped, sudo/env/command/nohup/time
# wrappers and leading VAR=val assignments removed) so quoting or prefixing a
# command can't dodge a rule (Barb audit, PR #158). The splitter is
# deliberately naive: heredoc and quoted-string bodies are scanned as segments
# too — catching embedded destructive text is worth the false positives, which
# are remediated by authoring file content with the Write/Edit tools instead
# of Bash heredocs. Known limit: $(...) / backtick bodies are not recursed.
#
# Escape hatches are JASON-ONLY, and only as AMBIENT env in the shell that
# launched Claude Code (the hook reads its own environment — an inline
# `VAR=1 cmd` never reaches it, and D0 blocks the attempt outright):
#   SKIP_BASH_SAFETY=1   bypass this gate entirely
#   ALLOW_DESTRUCTIVE=1  permit D1/D2/D6
#   ADB_NO_SERIAL_OK=1   permit serial-less adb (D5)
#   ALLOW_MAIN_PUSH=1    permit F2/F3/F4 (F1/F5 have NO escape)

set -uf

[ "${SKIP_BASH_SAFETY:-0}" = "1" ] && exit 0

# Fail CLOSED without jq: the payload cannot be parsed, so nothing may run.
if ! command -v jq >/dev/null 2>&1; then
  echo "pre-bash-safety: jq missing — failing CLOSED (every Bash call is blocked). Install jq (see tools/dev/setup-repo.sh)." >&2
  exit 2
fi

payload="$(cat)"
cmd="$(jq -r '.tool_input.command // empty' <<<"$payload")"
cwd="$(jq -r '.cwd // empty' <<<"$payload")"
[ -z "$cmd" ] && exit 0

# Config (SAD-181): default branch from workflow.config.json (fallback main),
# validated regex-inert since it is interpolated into an ERE below.
DEFAULT_BRANCH="main"
CFG="${CLAUDE_PROJECT_DIR:-.}/.claude/workflow.config.json"
if [ -f "$CFG" ]; then
  v="$(jq -r '.git.defaultBranch // empty' "$CFG" 2>/dev/null)"
  [ -n "$v" ] && DEFAULT_BRANCH="$v"
fi
case "$DEFAULT_BRANCH" in *[!A-Za-z0-9_/-]*) DEFAULT_BRANCH="main" ;; esac

# Repo scoping for the F-rows: resolve the absolute git-common-dir (shared by
# all worktrees of one repo) for the project and for a command's directory.
common_of() { # $1 = dir -> absolute git-common-dir, or empty if not a repo
  local d
  d="$(git -C "$1" rev-parse --git-common-dir 2>/dev/null)" || { echo ""; return 0; }
  case "$d" in
    /*) realpath -m "$d" 2>/dev/null ;;
    *)  realpath -m "$1/$d" 2>/dev/null ;;
  esac
}
proj_common=""
[ -n "${CLAUDE_PROJECT_DIR:-}" ] && proj_common="$(common_of "$CLAUDE_PROJECT_DIR")"
# cwd-level scoping (used by F1, whose gh command has no git -C to inspect).
# Unknown project or unknown cwd repo -> stay in scope (conservative).
cwd_in_project=true
if [ -n "$proj_common" ] && [ -n "$cwd" ]; then
  c="$(common_of "$cwd")"
  [ -n "$c" ] && [ "$c" != "$proj_common" ] && cwd_in_project=false
fi

seg=""
block() { # $1 = rule id, $2 = message
  {
    echo "pre-bash-safety [$1]: BLOCKED — $2"
    echo "  offending segment: $seg"
  } >&2
  exit 2
}

# Split on && || ; | and single & (POSIX leftmost-longest keeps && winning);
# `2>&1` noise segments are harmless.
mapfile -t segments < <(sed -E 's/&&|\|\||;|\||&/\n/g' <<<"$cmd")

warned_x=false
for seg in "${segments[@]}"; do
  # Trim whitespace + subshell parens.
  seg="$(sed -E 's/^[[:space:](]+//; s/[)[:space:]]+$//' <<<"$seg")"
  [ -z "$seg" ] && continue

  # D0 — inline escape-hatch assignment (checked on the RAW segment, before
  # normalization strips assignments). It would not work anyway — the hook
  # reads ambient env — so an attempt only signals evasion; block it loudly.
  if grep -qE '(^|[[:space:]])(SKIP_BASH_SAFETY|ALLOW_DESTRUCTIVE|ALLOW_MAIN_PUSH|ALLOW_DISABLED_STATION|ADB_NO_SERIAL_OK|LAND_PR_CFG_OVERRIDE|LAND_PR_SELFTEST|LAND_PR_TEST)=' <<<"$seg"; then
    block D0 "inline escape-hatch / test-seam assignment — these are Jason-only AMBIENT env (set in the shell that launched Claude), never in a command"
  fi

  # Normalized match-copy: normalize runtime-vanishing obfuscation, THEN dequote,
  # then strip wrapper prefixes and leading VAR=val assignments. All rules below
  # match against $mseg; $seg is only for display.
  #
  # SAD-258/357 — normalize obfuscation that vanishes at runtime BEFORE the
  # dequote + strip, so a keyword can't hide behind a non-space boundary the D/F
  # [[:space:]] anchors miss. Runs on the raw segment (pre-dequote) so an $IFS
  # re-glued via an adjacent empty quote still collapses (SAD-357).
  #   1. $IFS field-separator forms -> one space: braced ${IFS} incl. any suffix
  #      (${IFS%??}, ${IFS:0:1}), and unbraced $IFS when NOT followed by an
  #      identifier char (so a real var like $IFSTOP is spared; the *braced* form
  #      always collapses). Assumes runtime IFS is default whitespace — a
  #      redefined IFS diverges (the same stateless-hook limit accepted for F1).
  #   2. Empty-positional glue ($1-$9, $@, $*, and braced ${1}-${9}/${@}/${*})
  #      -> one space: these expand to nothing at the top level and are used
  #      purely to glue a keyword to an adjacent token (SAD-357). NOT $0/$#/$$
  #      (non-empty), and NOT ${IFS}/${HOME}-style named expansions (handled or
  #      needed elsewhere — e.g. D3's $HOME targets).
  # Fail-safe: only ever INSERTS boundaries -> can expose a hidden keyword, never
  # hide one; over-blocks only when the surrounding tokens already spell a blocked
  # command. Obfuscation beyond these forms stays the accepted boundary
  # (ADR-0025 Risk 3; main-guard backstops the F-rows server-side).
  mseg="$(sed -E 's/\$\{IFS[^}]*\}/ /g; s/\$IFS([^A-Za-z0-9_]|$)/ \1/g; s/\$\{[1-9@*]\}/ /g; s/\$[1-9@*]/ /g' <<<"$seg")"
  mseg="${mseg//\"/}"
  mseg="${mseg//\'/}"
  # Trim leading whitespace AFTER the dequote, not before: a leading QUOTED empty
  # expansion ("$@"git ...) collapses to quote+space that becomes a bare leading
  # space only once the quotes are stripped — trimming pre-dequote left that space
  # to defeat the ^...git / ^...gh anchors (Watson, SAD-357).
  mseg="$(sed -E 's/^[[:space:]]+//' <<<"$mseg")"
  # Wrapper flags with values (sudo -u jason git ...) defeat the prefix strip —
  # recover the git command from the last standalone `git` token (Watson probe).
  # Runs BEFORE the strip so the wrapper word is still present to anchor on.
  if [[ "$mseg" =~ ^([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+)*(sudo|command|env|nohup|time)[[:space:]].*[[:space:]]((git|gh)[[:space:]].*)$ ]]; then
    mseg="${BASH_REMATCH[3]}"
  fi

  mseg="$(sed -E 's/^([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+|(sudo|command|env|nohup|time)([[:space:]]+-[^[:space:]]+)*[[:space:]]+)*//' <<<"$mseg")"
  [ -z "$mseg" ] && continue

  is_git=false
  if grep -qE '^([^[:space:]]*/)?git([[:space:]]|$)' <<<"$mseg"; then is_git=true; fi

  # Branch context for the F-rows: honor `git -C <path>`, else the payload cwd.
  # Empty branch (not a repo / lookup failure) skips the flow rules.
  # in_project: does the command's repo share this project's git-common-dir?
  # Other repos are out of F-row scope (their default branch is their business).
  branch=""
  in_project=true
  if $is_git; then
    gitdir="$cwd"
    if [[ "$mseg" =~ (^|[[:space:]])git[[:space:]]+-C[[:space:]]+([^[:space:]]+) ]]; then
      gitdir="${BASH_REMATCH[2]}"
      # A relative -C path resolves against the PAYLOAD cwd, not the hook's (Watson PR #162)
      case "$gitdir" in /*) ;; *) [ -n "$cwd" ] && gitdir="$cwd/$gitdir" ;; esac
    fi
    [ -n "$gitdir" ] && branch="$(git -C "$gitdir" rev-parse --abbrev-ref HEAD 2>/dev/null)"
    if [ -n "$proj_common" ] && [ -n "$gitdir" ]; then
      cmd_common="$(common_of "$gitdir")"
      [ -n "$cmd_common" ] && [ "$cmd_common" != "$proj_common" ] && in_project=false
    fi
  fi

  # D1 — git reset --hard
  if $is_git \
     && grep -qE '(^|[[:space:]])reset([[:space:]]|$)' <<<"$mseg" \
     && grep -qE '(^|[[:space:]])--hard([[:space:]]|=|$)' <<<"$mseg" \
     && [ "${ALLOW_DESTRUCTIVE:-0}" != "1" ]; then
    block D1 "git reset --hard needs explicit authorization (ALLOW_DESTRUCTIVE=1, Jason-only)"
  fi

  # D2 — git clean with force and no dry-run
  if $is_git \
     && grep -qE '(^|[[:space:]])clean([[:space:]]|$)' <<<"$mseg" \
     && grep -qE '(^|[[:space:]])(-[a-zA-Z]*f[a-zA-Z]*|--force)([[:space:]]|$)' <<<"$mseg" \
     && ! grep -qE '(^|[[:space:]])(-[a-zA-Z]*n[a-zA-Z]*|--dry-run)([[:space:]]|$)' <<<"$mseg" \
     && [ "${ALLOW_DESTRUCTIVE:-0}" != "1" ]; then
    block D2 "git clean -f without -n/--dry-run needs explicit authorization (ALLOW_DESTRUCTIVE=1, Jason-only)"
  fi

  # D3 — rm -rf pointed at a protected root (always blocked, no escape hatch)
  if grep -qE '(^|[[:space:]])rm([[:space:]]|$)' <<<"$mseg" \
     && grep -qE '(^|[[:space:]])(-[a-zA-Z]*r|--recursive)' <<<"$mseg" \
     && grep -qE '(^|[[:space:]])(-[a-zA-Z]*f|--force)' <<<"$mseg"; then
    repo_root="${CLAUDE_PROJECT_DIR:-}"
    at_root=false
    if [ -n "$repo_root" ] && [ -n "$cwd" ] \
       && [ "$(realpath -m "$cwd" 2>/dev/null)" = "$(realpath -m "$repo_root" 2>/dev/null)" ]; then
      at_root=true
    fi
    # shellcheck disable=SC2086 # word-splitting the match-copy into tokens is the point (set -f is on)
    for tok in $mseg; do
      # shellcheck disable=SC2088,SC2016 # literal '~' / '$HOME' TOKENS in scanned command text are exactly what D3 matches
      case "$tok" in
        /|/.|'/*'|'~'|'~/'|'$HOME'|'$HOME/'|'${HOME}'|'${HOME}/'|"$HOME"|"$HOME/")
          block D3 "rm -rf targeting a protected root ('$tok')" ;;
        ..|../*)
          block D3 "rm -rf targeting a parent directory ('$tok') — use a specific path inside the workspace" ;;
      esac
      if [ -n "$repo_root" ] && { [ "$tok" = "$repo_root" ] || [ "$tok" = "$repo_root/" ]; }; then
        block D3 "rm -rf targeting the repo root ($repo_root)"
      fi
      # Relative forms AT the repo root: rm -rf . / ./ / * / ./* (Watson review)
      if $at_root; then
        case "$tok" in
          .|./|'*'|'./*')
            block D3 "rm -rf on the repo root via relative path ('$tok')" ;;
        esac
      fi
    done
  fi

  # D4 — adb kill-server / start-server (always blocked; path-prefixed adb too)
  if grep -qE '(^|[[:space:]])([^[:space:]]*/)?adb([[:space:]]+[^[:space:]]+)*[[:space:]]+(kill-server|start-server)([[:space:]]|$)' <<<"$mseg"; then
    block D4 "adb kill-server/start-server — one shared adb daemon serves the emulator pool (ADR-0024 rule 3)"
  fi

  # D5 — device-touching adb without a serial pinned BEFORE the subcommand
  # (a subcommand's own -s flag, e.g. `adb install -s`, does not count — Barb audit)
  adb_dev_pat='(^|[[:space:]])([^[:space:]]*/)?adb[[:space:]]+([^[:space:]]+[[:space:]]+)*(shell|install|uninstall|push|pull|exec-out|logcat)([[:space:]]|$)'
  adb_pinned_pat='(^|[[:space:]])([^[:space:]]*/)?adb[[:space:]]+([^[:space:]]+[[:space:]]+)*-s[[:space:]]+[^[:space:]]+[[:space:]]+([^[:space:]]+[[:space:]]+)*(shell|install|uninstall|push|pull|exec-out|logcat)([[:space:]]|$)'
  if grep -qE "$adb_dev_pat" <<<"$mseg" \
     && ! grep -qE "$adb_pinned_pat" <<<"$mseg" \
     && [ "${ADB_NO_SERIAL_OK:-0}" != "1" ]; then
    block D5 "adb without -s <serial> before the subcommand — pin the device (ADR-0024 rule 1; ADB_NO_SERIAL_OK=1 is Jason-only)"
  fi

  # D6 — force push (folded from Jason's local hook; per-action authorization required)
  if $is_git \
     && grep -qE '(^|[[:space:]])push([[:space:]]|$)' <<<"$mseg" \
     && grep -qE '(^|[[:space:]])(--force(-with-lease)?(=[^[:space:]]*)?|-[a-zA-Z]*f[a-zA-Z]*)([[:space:]]|$)' <<<"$mseg" \
     && [ "${ALLOW_DESTRUCTIVE:-0}" != "1" ]; then
    block D6 "force push requires explicit per-action authorization (CLAUDE.md; ALLOW_DESTRUCTIVE=1, Jason-only)"
  fi

  # D7 — staging files that must never be committed (folded from Jason's local hook)
  if $is_git \
     && grep -qE '(^|[[:space:]])add([[:space:]]|$)' <<<"$mseg" \
     && grep -qE 'local\.properties|\.env([^a-zA-Z]|$)|google-services\.json|\.jks|keystore\.|\.keystore([^a-zA-Z]|$)|credentials\.json' <<<"$mseg"; then
    block D7 "staging a sensitive file (local.properties / .env / keystore / google-services.json / credentials.json) — these never enter git"
  fi

  # ---- F-rows: branch-flow guards (SAD-177; default branch is PR-only,
  # ADR-0023; scoped to THIS project's repo, SAD-181) ----

  # F1 — gh pr merge is never the path (no escape hatch); the funnel is
  # land-pr.sh. ANY explicit repo selector keeps F1 active even from another
  # repo's cwd — gh acts on the TARGET repo, not the cwd (Barb audit): -R/--repo
  # flag, a GH_REPO/GH_HOST env assignment or a `gh repo set-default` — the last
  # two scanned on the WHOLE raw command ($cmd), not just this segment, so a
  # redirect placed in a sibling segment still counts (SAD-257 (a); the split-
  # across-two-Bash-calls case is the irreducible stateless-hook limit) — or a
  # PR URL in the merge-target ARGUMENT position (not merely mentioned in a
  # --body, SAD-257 (b)). Deliberately over-blocks cross-repo gh-pr-merge from
  # an EL session — the funnel discipline is the point.
  if grep -qE '^([^[:space:]]*/)?gh[[:space:]]+pr[[:space:]]+merge([[:space:]]|$)' <<<"$mseg"; then
    gh_repo_selector=false
    # -R/--repo in any form, incl. gh's glued short flag -Ro/repo.
    grep -qE '(^|[[:space:]])(-R|--repo([[:space:]=]|$))' <<<"$mseg" && gh_repo_selector=true
    # Sibling-segment redirect via env or `gh repo set-default` — scan the whole
    # command, DEQUOTED (so GH_"R"EPO=… can't hide it — Barb audit).
    ncmd="${cmd//\"/}"; ncmd="${ncmd//\'/}"
    grep -qE '(^|[[:space:]])(GH_REPO|GH_HOST)=' <<<"$ncmd" && gh_repo_selector=true
    grep -qE '(^|[[:space:]])([^[:space:]]*/)?gh[[:space:]]+repo[[:space:]]+set-default([[:space:]]|$)' <<<"$ncmd" && gh_repo_selector=true
    # PR URL as the merge TARGET — model gh's parser (Watson/Barb: a naive
    # position heuristic is defeated by a value-flag decoy or a recurring
    # `merge` word). `gh pr merge` takes exactly ONE positional: the PR
    # selector. Walk tokens after `merge`, skip each value-taking flag's VALUE
    # token, and test the FIRST positional only, then stop — a URL that is a
    # --body value is skipped (preserving the (b) false-positive fix), while a
    # URL target after any decoy flag is still caught.
    seen_merge=false; expect_val=false
    # shellcheck disable=SC2086 # word-splitting the match-copy into tokens is the point (set -f is on)
    for tok in $mseg; do
      if ! $seen_merge; then [ "$tok" = "merge" ] && seen_merge=true; continue; fi
      if $expect_val; then expect_val=false; continue; fi
      # SAD-258 — this value-taking-flag list is a STATIC MIRROR of gh pr merge's
      # grammar; a future gh that adds a value-taking merge flag must be added
      # here, or F1 over-blocks a URL that follows it (fail-safe — never toward
      # letting a raw merge through). Recheck against `gh pr merge --help` on gh
      # version bumps.
      case "$tok" in
        -b|--body|-t|--subject|-F|--body-file|--match-head-commit|-R|--repo|--author-email)
          expect_val=true; continue ;;   # value is the NEXT token
        --*=*|-*) continue ;;            # inline-value or valueless flag
      esac
      grep -qiE '^https?://[^[:space:]]+/pull/[0-9]+' <<<"$tok" && gh_repo_selector=true
      break                              # only the sole PR-selector arg matters
    done
    if $cwd_in_project || $gh_repo_selector; then
      block F1 "not the funnel — run tools/dev/land-pr.sh <PR#> (/land); raw gh pr merge skips the gates"
    fi
  fi

  # F6 — hook-evasion signals (D0 spirit; Barb audit: --no-verify DOES skip
  # pre-push — a git invariant; --no-ver[a-z]* covers git's prefix
  # abbreviations). Case-insensitive on hooksPath (git config keys are);
  # a pure read (--get) is exempt (Watson nit — the doctor reads it).
  if $is_git && $in_project && grep -qE '(^|[[:space:]])--no-ver[a-z-]*([[:space:]]|$)' <<<"$mseg"; then
    block F6 "--no-verify skips git hooks — evasion signal; never use it"
  fi
  if $is_git && $in_project && grep -qiE 'core\.hooksPath=' <<<"$mseg"; then
    block F6 "inline core.hooksPath override — evasion signal"
  fi
  if $is_git && $in_project \
     && grep -qE '(^|[[:space:]])config([[:space:]]|$)' <<<"$mseg" \
     && grep -qiE 'core\.hooksPath' <<<"$mseg" \
     && ! grep -qE '(^|[[:space:]])--get([[:space:]]|$)' <<<"$mseg" \
     && ! grep -qiE 'core\.hooksPath[[:space:]]+\.githooks([[:space:]]|$)' <<<"$mseg"; then
    block F6 "pointing core.hooksPath away from .githooks — evasion signal"
  fi

  if $is_git && $in_project && grep -qE '(^|[[:space:]])push([[:space:]]|$)' <<<"$mseg"; then
    # Token-wise refspec analysis — NOT substring: jasongarcia/sad-N-main-screen must pass.
    # Canonical (refs/heads/main), force (+main), HEAD-on-main, and --all/--mirror forms
    # are covered per the Watson round-3 probes.
    after_push=false; has_delete=false; tags_flag=false; nonflag_after_push=0
    targets_main=false; deletes_main=false
    # shellcheck disable=SC2086 # word-splitting the match-copy is the point (set -f is on)
    for tok in $mseg; do
      if ! $after_push; then [ "$tok" = "push" ] && after_push=true; continue; fi
      tok="${tok#+}"   # force-refspec syntax (+main, +HEAD:main) — strip for analysis
      case "$tok" in
        --delete|-d)    has_delete=true; continue ;;
        --all|--mirror) targets_main=true; continue ;;
        --tags)         tags_flag=true; continue ;;
        -*) continue ;;
      esac
      nonflag_after_push=$((nonflag_after_push + 1))
      # Canonicalize the destination: dst side of src:dst, then strip the
      # refs/heads/ or heads/ qualifier — parse the ref, don't pattern-spot it
      # (Barb audit: heads/main, HEAD:refs/heads/main, :refs/heads/main forms).
      dst="${tok##*:}"
      dst="${dst#refs/heads/}"; dst="${dst#heads/}"
      if [ "$dst" = "HEAD" ] || [ "$dst" = "@" ]; then
        [ "$branch" = "$DEFAULT_BRANCH" ] && targets_main=true
      elif [ "$dst" = "$DEFAULT_BRANCH" ]; then
        case "$tok" in
          :*) deletes_main=true ;;   # empty src side = deletion refspec
          *)  targets_main=true ;;
        esac
      fi
    done
    # F5 — deleting the default branch is never allowed (no escape hatch)
    if $deletes_main || { $has_delete && $targets_main; }; then
      block F5 "push deleting $DEFAULT_BRANCH — never allowed"
    fi
    # F2 — pushing to the default branch bypasses the PR funnel
    if $targets_main && [ "${ALLOW_MAIN_PUSH:-0}" != "1" ]; then
      block F2 "$DEFAULT_BRANCH is PR-only (ADR-0023) — land via tools/dev/land-pr.sh (/land); ALLOW_MAIN_PUSH=1 is Jason-only"
    fi
    # F3 — bare push (no refspec tokens) while ON the default branch pushes it
    # implicitly; a --tags-only push moves no branch, so it is exempt
    if [ "$nonflag_after_push" -le 1 ] && [ "$tags_flag" != "true" ] \
       && [ "$branch" = "$DEFAULT_BRANCH" ] && [ "${ALLOW_MAIN_PUSH:-0}" != "1" ]; then
      block F3 "bare git push while on $DEFAULT_BRANCH — PR-only (ADR-0023)"
    fi
  fi

  # F4 — history-writing git on the default branch; git pull --ff-only is the
  # ONLY way it moves locally
  if $is_git && $in_project && [ "$branch" = "$DEFAULT_BRANCH" ] \
     && grep -qE '(^|[[:space:]])(commit|merge|rebase|cherry-pick|revert)([[:space:]]|$)' <<<"$mseg" \
     && [ "${ALLOW_MAIN_PUSH:-0}" != "1" ]; then
    block F4 "on $DEFAULT_BRANCH — cut a branch first; git pull --ff-only is the only way $DEFAULT_BRANCH moves locally (ADR-0023)"
  fi

  # F5 — deleting the local default branch (no escape hatch)
  if $is_git && $in_project \
     && grep -qE '(^|[[:space:]])branch([[:space:]]|$)' <<<"$mseg" \
     && grep -qE '(^|[[:space:]])(-d|-D|--delete)([[:space:]]|$)' <<<"$mseg" \
     && grep -qE "(^|[[:space:]])($DEFAULT_BRANCH|refs/heads/$DEFAULT_BRANCH)([[:space:]]|\$)" <<<"$mseg"; then
    block F5 "deleting the local $DEFAULT_BRANCH branch — never allowed"
  fi

  # W1 — bash/sh -x may trace secrets (folded from Jason's local hook; warn, don't block)
  if ! $warned_x && grep -qE '(^|[[:space:]])(bash|sh)[[:space:]]+-[a-zA-Z]*x' <<<"$mseg"; then
    printf '{"systemMessage": "[pre-bash-safety W1] bash -x traces every variable assignment and can leak secret values if the script reads credentials (memory: bash-x-on-secret-reading-scripts-leaks-values). Bracket secret reads with set +x/set -x or drop -x."}\n'
    warned_x=true
  fi
done

exit 0
