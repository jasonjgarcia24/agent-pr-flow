#!/usr/bin/env bash
# tools/dev/land-pr.sh — THE merge funnel (SAD-178). Every PR lands through
# this script; raw `gh pr merge` is hook-blocked (pre-bash-safety F1).
#
# Usage: tools/dev/land-pr.sh <PR#> [--watch] [--dry-run]
#   --watch    if CI is still PENDING, wait for it (gh pr checks --watch) then re-read
#   --dry-run  stop after the gates with a tier + per-gate PASS/FAIL table
#
# Gates:
#   G0 prereqs   gh authed, jq present, integer PR arg
#   G1 PR state  OPEN, not draft; capture head SHA / title / body
#   G2 CI        required check "Build & unit test" == SUCCESS (missing = loud fail)
#   G3 tier      changed files -> docs | code | security (ANY security -> security;
#                else ALL docs -> docs; else code)
#   G4 verdicts  code/security: last watson-verdict marker == APPROVE sha=<head>;
#                security also: last barb-verdict marker == CLEARED sha=<head>
#   G5 linkage   SAD-N in title+body (WARN only)
#   G6 merge     squash with explicit "--subject <title> (#N)" (deterministic (#NN))
#   G7 verify    merge_commit_sha subject ends (#N) via the API (race-safe); sync local
#   G8 close-out print the close-out checklist + audit URLs
#
# CONFIG (SAD-181): knobs load from .claude/workflow.config.json — required
# check, merge method, default branch, tier patterns, verdict markers, station
# agents. Missing file or key => hardcoded instance-#1 fallbacks + a loud WARN
# (never silently fail-open/closed). A null .agents.<station> disables that
# verdict gate with a loud WARN.

set -u

# ---------- G0: prereqs ----------
die() { echo "land-pr [G$1]: FAIL — $2" >&2; exit 1; }

pr="${1:-}"
watch=0
dry_run=0
shift 2>/dev/null || true
for arg in "$@"; do
  case "$arg" in
    --watch) watch=1 ;;
    --dry-run) dry_run=1 ;;
    *) die 0 "unknown argument: $arg (usage: land-pr.sh <PR#> [--watch] [--dry-run])" ;;
  esac
done

grep -qE '^[0-9]+$' <<<"$pr" || die 0 "PR number required (got: '${pr}')"
command -v jq >/dev/null 2>&1 || die 0 "jq missing"
command -v gh >/dev/null 2>&1 || die 0 "gh missing"
gh auth status >/dev/null 2>&1 || die 0 "gh not authenticated"
REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner)" || die 0 "cannot resolve repo (no origin remote?)"

# ---------- config load (SAD-181) ----------
# Real runs read the config from the TRUSTED REF — the remote default branch —
# so neither a dirty working tree NOR the PR branch's own edits can weaken the
# gates that judge it (Barb + Watson, PR #162). The ref is resolved
# DETERMINISTICALLY: origin/HEAD if its symbolic ref is set, else the literal
# origin/main (the tracking ref exists even when the symbolic one is absent —
# Barb: don't depend on the non-guaranteed origin/HEAD). Falls back to the
# local HEAD commit, then the working tree, each with a WARN. --dry-run reads
# the working tree so config changes can be exercised before commit.
# LAND_PR_CFG_OVERRIDE / LAND_PR_SELFTEST are test seams — refuse them on a
# real landing unless LAND_PR_TEST=1 (Barb Info: ungated seams neutralize the
# trusted-ref read if ever exported in a landing shell).
if { [ -n "${LAND_PR_CFG_OVERRIDE:-}" ] || [ "${LAND_PR_SELFTEST:-0}" = "1" ]; } \
   && [ "$dry_run" != "1" ] && [ "${LAND_PR_TEST:-0}" != "1" ]; then
  die 0 "LAND_PR_CFG_OVERRIDE/LAND_PR_SELFTEST are test-only — a real landing refuses them (set LAND_PR_TEST=1 for tests)"
fi
repo_top="$(git rev-parse --show-toplevel 2>/dev/null || echo .)"
CFG="$repo_top/.claude/workflow.config.json"
if [ -n "${LAND_PR_CFG_OVERRIDE:-}" ]; then
  CFG="$LAND_PR_CFG_OVERRIDE"
elif [ "$dry_run" != "1" ]; then
  # symbolic-ref returns EMPTY when origin/HEAD is unset; rev-parse --abbrev-ref
  # echoes the literal "origin/HEAD" instead, defeating the fallback (Watson).
  trusted_ref="$(git -C "$repo_top" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null)"
  [ -n "$trusted_ref" ] || trusted_ref="origin/main"
  if git -C "$repo_top" cat-file -e "$trusted_ref:.claude/workflow.config.json" 2>/dev/null; then
    CFG="$(mktemp)"
    trap 'rm -f "$CFG"' EXIT
    git -C "$repo_top" show "$trusted_ref:.claude/workflow.config.json" > "$CFG"
  elif git -C "$repo_top" cat-file -e "HEAD:.claude/workflow.config.json" 2>/dev/null; then
    echo "land-pr: WARN — config absent on the trusted ref ($trusted_ref); using this branch's committed copy" >&2
    CFG="$(mktemp)"
    trap 'rm -f "$CFG"' EXIT
    git -C "$repo_top" show "HEAD:.claude/workflow.config.json" > "$CFG"
  elif [ -f "$CFG" ]; then
    echo "land-pr: WARN — config not committed anywhere; using the working-tree copy" >&2
  fi
fi
if [ ! -f "$CFG" ]; then
  echo "land-pr: WARN — workflow.config.json missing; using hardcoded instance-#1 fallbacks" >&2
fi
cfg() { # $1 = jq path, $2 = fallback; empty/missing/null -> fallback
  local v=""
  [ -f "$CFG" ] && v="$(jq -r "$1 // empty" "$CFG" 2>/dev/null)"
  if [ -n "$v" ]; then printf '%s\n' "$v"; else printf '%s\n' "$2"; fi
}
# NOTE: called via $( ) — a die here would only exit the subshell, so invalid
# values print EMPTY and the main-shell caller dies on the empty result.
station() { # $1 = station key, $2 = fallback agent; ONLY explicit null -> DISABLED
  local v
  if [ -f "$CFG" ] && jq -e ".agents | has(\"$1\")" "$CFG" >/dev/null 2>&1; then
    v="$(jq -r ".agents.$1" "$CFG")"
    case "$v" in
      null)              printf 'DISABLED\n' ;;
      ""|false|DISABLED) printf '' ;;   # invalid — only explicit null disables
      *)                 printf '%s\n' "$v" ;;
    esac
  else
    printf '%s\n' "$2"
  fi
}
glob_to_ere() { # gitignore-ish glob -> anchored ERE (config tier patterns)
  # Bracket-class order matters: `[` must not precede `.` or POSIX reads a
  # collating symbol `[. .]` and the expression never terminates (found live
  # by the SAD-181 acceptance diff). Fail-closed: sentinel bytes in input and
  # `?` are handled explicitly (Barb audit).
  local g="$1" e
  case "$g" in
    *®*)   die 0 "glob '$g' contains the reserved sentinel byte ®" ;;
    /*)    die 0 "glob '$g': leading-/ root anchors are not supported (paths are repo-relative)" ;;
    *\[*)  die 0 "glob '$g': [...] classes are not supported (supported: * ** ?)" ;;
  esac
  e="$(sed -E 's/[].^$+(){}|\\[]/\\&/g' <<<"$g")"
  e="${e//\*\*\//®D}"; e="${e//\*\*/®A}"; e="${e//\*/[^\/]*}"; e="${e//\?/[^\/]}"
  e="${e//®D/(.*\/)?}"; e="${e//®A/.*}"
  case "$g" in
    */*) printf '^%s$\n' "$e" ;;
    *)   printf '(^|/)%s$\n' "$e" ;;   # slash-less pattern matches at any depth
  esac
}
tier_pat() { # $1 = jq array path, $2 = fallback ERE — fails CLOSED (Barb audit):
  # an empty/invalid converted pattern aborts the landing instead of silently
  # downgrading the tier. Runs in the MAIN shell (result via $TIER_PAT, not a
  # subshell) so the die actually halts — the PR-#160 subshell-die lesson.
  local pats="" g e
  if [ -f "$CFG" ] && jq -e "$1" "$CFG" >/dev/null 2>&1; then
    while IFS= read -r g; do
      e="$(glob_to_ere "$g")"
      [ -n "$e" ] || die 0 "glob '$g' converted to an empty pattern — refusing to land (fail-closed)"
      pats="${pats}${pats:+|}$e"
    done < <(jq -r "$1[]" "$CFG")
    [ -n "$pats" ] || die 0 "empty $1 in config — refusing to land (fail-closed; Watson PR #162)"
  else
    pats="$2"
  fi
  printf '' | grep -qE "$pats" 2>/dev/null
  [ $? -le 1 ] || die 0 "assembled tier pattern from $1 is not a valid ERE — refusing to land (fail-closed)"
  TIER_PAT="$pats"
}

REQUIRED_CHECK="$(cfg '.ci.requiredCheck' 'Build & unit test')"
MERGE_METHOD="$(cfg '.git.mergeMethod' 'squash')"
DEFAULT_BRANCH="$(cfg '.git.defaultBranch' 'main')"
case "$DEFAULT_BRANCH" in *[!A-Za-z0-9_/-]*) die 0 "invalid git.defaultBranch '$DEFAULT_BRANCH' in config" ;; esac
REVIEWER_MARKER="$(cfg '.review.verdicts.reviewer.marker' 'watson-verdict')"
REVIEWER_PASS="$(cfg '.review.verdicts.reviewer.pass' 'APPROVE')"
SECURITY_MARKER="$(cfg '.review.verdicts.security.marker' 'barb-verdict')"
SECURITY_PASS="$(cfg '.review.verdicts.security.pass' 'CLEARED')"
REVIEWER_AGENT="$(station reviewer watson)"
SECURITY_AGENT="$(station security barb)"
[ -n "$REVIEWER_AGENT" ] || die 0 "invalid agents.reviewer in config — only an explicit null disables a station"
[ -n "$SECURITY_AGENT" ] || die 0 "invalid agents.security in config — only an explicit null disables a station"

# Tier patterns (globs from config → ERE; hardcoded instance-#1 fallbacks).
# Fallback slash-less entries use (^|/) to match the documented any-depth glob
# semantics (Watson PR #162: nested .gitignore divergence was gate-weakening).
tier_pat '.review.securityTierPatterns' '^\.github/workflows/|\.gradle\.kts$|^gradle/libs\.versions\.toml$|^gradle/wrapper/|(^|/)gradle\.properties$|(^|/)AndroidManifest\.xml$|^app/src/main/java/com/enduranceloggr/app/network/|^app/src/main/java/com/enduranceloggr/app/feedback/|^\.claude/settings\.json$|^\.claude/hooks/|^\.claude/commands/|^\.claude/workflow\.config\.|^\.githooks/|^tools/dev/land-pr\.sh$|^tools/dev/setup-repo\.sh$|(^|/)\.mcp\.json$'
security_pat="$TIER_PAT"
tier_pat '.review.docsTierPatterns' '\.md$|^docs/|^design/|^tasks/|(^|/)\.gitignore$|^\.github/pull_request_template\.md$|^acceptance-evidence/'
docs_pat="$TIER_PAT"

# Fail-closed self-tests (Barb audit, PR #162): the loaded security pattern
# must catch a canonical security path — INCLUDING the gate config itself
# (self-protection: the file that configures the gates needs the strictest
# gate) — and the docs pattern a canonical doc. A converter/config regression
# aborts the landing instead of silently downgrading the tier.
grep -qE "$security_pat" <<<".claude/hooks/_selftest" \
  || die 0 "security tier pattern fails its self-test — refusing to land (fail-closed)"
grep -qE "$security_pat" <<<".claude/workflow.config.json" \
  || die 0 "the gate config is not covered by its own security tier — refusing to land (self-protection)"
grep -qE "$docs_pat" <<<"docs/_selftest.md" \
  || die 0 "docs tier pattern fails its self-test — refusing to land (fail-closed)"

# Hidden self-test mode (tools/dev/test-land-pr.sh): classify stdin paths with
# the loaded patterns and exit — no PR is read or touched.
if [ "${LAND_PR_SELFTEST:-0}" = "1" ]; then
  while IFS= read -r f; do
    if grep -qE "$security_pat" <<<"$f"; then echo "security $f"
    elif ! grep -qvE "$docs_pat" <<<"$f"; then echo "docs $f"
    else echo "code $f"; fi
  done
  exit 0
fi
# Validate config-sourced names at LOAD TIME in the main shell (a die inside a
# $() subshell only exits the subshell — Barb re-audit, PR #160).
for m in "$REVIEWER_MARKER" "$SECURITY_MARKER"; do
  case "$m" in *[!a-z-]*) die 0 "invalid marker name '$m' in $CFG (lowercase + dashes only)" ;; esac
done
case "$MERGE_METHOD" in squash|merge|rebase) : ;; *) die 0 "invalid git.mergeMethod '$MERGE_METHOD' in $CFG" ;; esac

gate_rows=""
note() { gate_rows="${gate_rows}$1\n"; }

# In --dry-run, gate failures accumulate into the table (so a report names EVERY
# missing verdict, not just the first); in a real run the first failure dies.
landing_blocked=0
gate_fail() { # $1 = gate number, $2 = message
  if [ "$dry_run" = "1" ]; then
    note "G$1 FAIL  $2"
    landing_blocked=1
  else
    die "$1" "$2"
  fi
}

# ---------- G1: PR state ----------
pr_json="$(gh pr view "$pr" --json state,isDraft,headRefOid,title,body,headRefName 2>/dev/null)" || die 1 "PR #$pr not found"
state="$(jq -r '.state' <<<"$pr_json")"
is_draft="$(jq -r '.isDraft' <<<"$pr_json")"
head="$(jq -r '.headRefOid' <<<"$pr_json")"
title="$(jq -r '.title' <<<"$pr_json")"
body="$(jq -r '.body' <<<"$pr_json")"
head_branch="$(jq -r '.headRefName' <<<"$pr_json")"
[ "$state" = "OPEN" ] || die 1 "PR #$pr is $state, not OPEN"
[ "$is_draft" = "false" ] || die 1 "PR #$pr is a draft — mark it ready first"
note "G1 PASS  PR #$pr OPEN, head=${head:0:9} ($head_branch)"

# ---------- G2: CI ----------
# gh 2.45 has no `gh pr checks --json` — read the check-runs REST API instead.
# filter=latest returns only the newest run per check name (re-runs create
# same-name siblings whose API order is not chronological — Barb audit); the
# check name goes in as jq DATA (--arg), never interpolated into the program
# (pre-empts the SAD-181 config-sourced-name injection surface).
read_check() { # prints SUCCESS / FAILURE:<conclusion> / PENDING / "" (missing)
  local row
  row="$(gh api "repos/$REPO/commits/$head/check-runs?filter=latest" --paginate 2>/dev/null \
    | jq -r --arg name "$REQUIRED_CHECK" \
        '.check_runs[] | select(.name == $name) | .status + "/" + (.conclusion // "")' \
    | tail -1)"
  case "$row" in
    "")                  echo "" ;;
    completed/success)   echo "SUCCESS" ;;
    completed/*)         echo "FAILURE:${row#completed/}" ;;
    *)                   echo "PENDING" ;;
  esac
}
check_state="$(read_check)"
if [ "$check_state" = "PENDING" ] && [ "$watch" = "1" ]; then
  echo "land-pr [G2]: CI pending — watching..." >&2
  gh pr checks "$pr" --watch --fail-fast >/dev/null 2>&1 || true
  check_state="$(read_check)"
fi
if [ -z "$check_state" ]; then
  gate_fail 2 "required check '$REQUIRED_CHECK' not found on PR #$pr head — has ci.yml's job been renamed? (loud fail by design)"
elif [ "$check_state" != "SUCCESS" ]; then
  gate_fail 2 "required check '$REQUIRED_CHECK' state=$check_state (need SUCCESS)"
else
  note "G2 PASS  CI '$REQUIRED_CHECK' SUCCESS"
fi

# ---------- G3: tier ----------
# Paginated REST listing — `gh pr view --json files` truncates at 100 files,
# which would let a security-pattern file at position 101+ dodge the Barb
# gate (Watson review, PR #160).
files="$(gh api "repos/$REPO/pulls/$pr/files" --paginate --jq '.[].filename')"
[ -n "$files" ] || die 3 "PR #$pr has no changed files?"

# Tier patterns come from workflow.config.json (globs, converted to ERE);
# the literals below are the instance-#1 fallbacks when the config is absent.
# Self-protection set includes .claude/commands/ (deliberate extension of the
# Correction-7 list, Watson review: /land's instructions are part of the gate).

tier="code"
if grep -qE "$security_pat" <<<"$files"; then
  tier="security"
elif ! grep -qvE "$docs_pat" <<<"$files"; then
  tier="docs"
fi
note "G3 PASS  tier=$tier ($(wc -l <<<"$files") files)"

# ---------- G4: verdict markers ----------
# Trust only the LAST marker per agent, pinned to the exact current head SHA.
last_marker() { # $1 = marker name -> prints last "<VERDICT> sha=<sha>" for that marker
  # Marker names are validated regex-inert at config load (main shell).
  gh api "repos/$REPO/issues/$pr/comments" --paginate --jq '.[].body' \
    | grep -oE "<!-- $1: [A-Z_]+ sha=[0-9a-f]{40} -->" \
    | tail -1 \
    | sed -E "s/<!-- $1: ([A-Z_]+) sha=([0-9a-f]{40}) -->/\1 \2/"
}
check_marker() { # $1 = marker name, $2 = required verdict, $3 = agent label
  local m verdict sha
  m="$(last_marker "$1")"
  if [ -z "$m" ]; then
    gate_fail 4 "no $1 marker comment on PR #$pr — request a $3 review"
    return
  fi
  verdict="${m%% *}"; sha="${m##* }"
  if [ "$sha" != "$head" ]; then
    gate_fail 4 "$1 is for stale sha ${sha:0:9} (head is ${head:0:9}) — pushes void verdicts; get a fresh/delta review"
  elif [ "$verdict" != "$2" ]; then
    gate_fail 4 "$1 verdict is $verdict, not $2"
  else
    note "G4 PASS  $1 $2 @ head"
  fi
}
if [ "$tier" = "docs" ]; then
  note "G4 SKIP  docs tier — CI-alone policy"
else
  # A DISABLED station only lands under the explicit Jason-only ambient hatch
  # ALLOW_DISABLED_STATION=1 — never silently on a WARN (Barb audit, PR #162).
  disabled_station() { # $1 = station label
    if [ "${ALLOW_DISABLED_STATION:-0}" = "1" ]; then
      note "G4 WARN  $1 station DISABLED (agents.$1=null) — landing under ALLOW_DISABLED_STATION=1"
      echo "land-pr [G4]: WARN — $1 station disabled; landing under the explicit ALLOW_DISABLED_STATION hatch" >&2
    else
      gate_fail 4 "$1 station is DISABLED (agents.$1=null) — landing requires ALLOW_DISABLED_STATION=1 (Jason-only ambient)"
    fi
  }
  if [ "$REVIEWER_AGENT" = "DISABLED" ]; then
    disabled_station reviewer
  else
    check_marker "$REVIEWER_MARKER" "$REVIEWER_PASS" "$REVIEWER_AGENT"
  fi
  if [ "$tier" = "security" ]; then
    if [ "$SECURITY_AGENT" = "DISABLED" ]; then
      disabled_station security
    else
      check_marker "$SECURITY_MARKER" "$SECURITY_PASS" "$SECURITY_AGENT"
    fi
  fi
fi

# ---------- G5: SAD linkage (WARN only) ----------
if grep -qE 'SAD-[0-9]+' <<<"$title$body"; then
  note "G5 PASS  SAD linkage present"
else
  note "G5 WARN  no SAD-N in title/body — Linear won't auto-transition"
  echo "land-pr [G5]: WARN — no SAD-N in title/body; Linear won't auto-transition" >&2
fi

# ---------- dry-run stop ----------
if [ "$dry_run" = "1" ]; then
  echo "land-pr: DRY RUN — PR #$pr tier=$tier"
  printf '%b' "$gate_rows"
  [ "$landing_blocked" = "0" ] && echo "DRY RUN: all gates green — a real run would merge." \
                               || echo "DRY RUN: landing BLOCKED by the gates above."
  exit "$landing_blocked"
fi

# ---------- G6: merge ----------
# Explicit subject => deterministic "(#NN)" traceability regardless of repo
# settings. --match-head-commit pins the merge to the EXACT sha the gates
# verified — a push racing this run makes GitHub refuse the merge instead of
# landing an unreviewed head (Barb audit, TOCTOU). No --delete-branch: it
# fails when the branch is checked out in a worktree; delete_branch_on_merge
# + fetch --prune cover it.
gh pr merge "$pr" "--$MERGE_METHOD" --match-head-commit "$head" \
  --subject "$title (#$pr)" --body "$body" \
  || die 6 "merge failed (head moved since the gates ran? re-run /land so the gates cover the new head)"
note "G6 PASS  ${MERGE_METHOD}-merged @ ${head:0:9} (head-pinned)"

# ---------- G7: verify + sync ----------
merge_sha="$(gh api "repos/$REPO/pulls/$pr" --jq '.merge_commit_sha')"
merged_subject="$(gh api "repos/$REPO/commits/$merge_sha" --jq '.commit.message' | head -1)"
if ! grep -qE "\(#$pr\)\$" <<<"$merged_subject"; then
  die 7 "landed subject lacks (#$pr): '$merged_subject' — investigate before the next landing"
fi
note "G7 PASS  merge commit ${merge_sha:0:9} subject ends (#$pr)"
git fetch --prune origin >/dev/null 2>&1 || true
if [ "$(git rev-parse --abbrev-ref HEAD 2>/dev/null)" = "$DEFAULT_BRANCH" ]; then
  if git merge --ff-only "origin/$DEFAULT_BRANCH" >/dev/null 2>&1; then
    note "G7 PASS  local $DEFAULT_BRANCH fast-forwarded"
  else
    note "G7 WARN  local $DEFAULT_BRANCH not fast-forwarded (dirty tree?)"
  fi
fi

# ---------- G8: close-out ----------
sad="$(grep -oE 'SAD-[0-9]+' <<<"$title $body" | head -1)"
echo ""
echo "land-pr: PR #$pr LANDED — merge commit ${merge_sha:0:9}"
printf '%b' "$gate_rows"
echo ""
echo "CLOSE-OUT (4 surfaces — see .claude/references/pm/workflow.md §7):"
echo "  1. Linear: fire Radar to verify ${sad:-<SAD-N>} -> Done (idempotent; integration usually does it)"
echo "  2. R-ID: update docs/requirements.md IFF this change moved a quality bar"
echo "  3. Todo: refresh the tasks/todo.md snapshot line (date: $(date +%F))"
echo "  4. ADR/spec-row: IFF architectural (docs/decisions/ + spec amendments table)"
echo "  Worktree: git worktree remove <path> once done with the branch"
echo "  Audit trail (verdict comments): https://github.com/$REPO/pull/$pr"
exit 0
