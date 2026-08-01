#!/usr/bin/env bash
# shellcheck disable=SC2015  # A && pass || fail assertion rows: the pass-echo cannot fail
# tools/dev/test-land-pr.sh — tier-classification regression (Watson, PR #162).
# The config-driven and hardcoded-fallback patterns must classify IDENTICALLY:
# the PR-#162 collating-symbol bug shipped with a green 140-case hook harness
# while every land-pr tier was silently wrong — this closes that blind spot.
# Uses land-pr.sh's hidden LAND_PR_SELFTEST mode (no PR is read or touched).

set -u

# Resolve the repo from THIS SCRIPT's own location, not the caller's CWD (Barb
# LOW-2, SAD-546). `git rev-parse --show-toplevel` alone reads the CWD, so
# `bash /path/to/some-worktree/tools/dev/test-land-pr.sh` silently tested
# whichever checkout the caller happened to be standing in — it cd'd there and
# ran THAT tree's land-pr.sh against THAT tree's config. Found live while
# verifying SAD-546: a run launched by absolute path from the primary checkout
# reported the pre-fix tiers and looked like the fix had not worked. The
# wrong-tree PASS is the dangerous direction — it green-lights a gate change
# that was never actually exercised.
ROOT="$(git -C "$(dirname -- "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)" || exit 1
cd "$ROOT" || exit 1

LIST="$(mktemp)"; CFG_OUT="$(mktemp)"; FB_OUT="$(mktemp)"
trap 'rm -f "$LIST" "$CFG_OUT" "$FB_OUT"' EXIT

# Every tracked file + a fixed adversarial set (near-miss names, nested files).
{
  git ls-files
  printf '%s\n' app/.gitignore XAndroidManifest.xml .claude/hooksx/evil.sh \
    docsx/a.txt tools/dev/land-pr.sh.orig server/.gitignore \
    server/app/routers/feedback.py xserver/notbackend.py \
    sub/dir/gradle.properties .claude/workflow.config.json \
    .claude/workflow.config.d/nested.json .claude/workflow.config.yaml
} | sort -u > "$LIST"

LAND_PR_TEST=1 LAND_PR_SELFTEST=1 tools/dev/land-pr.sh 0 < "$LIST" > "$CFG_OUT" \
  || { echo "FAIL  selftest run (config-driven)"; exit 1; }
LAND_PR_TEST=1 LAND_PR_SELFTEST=1 LAND_PR_CFG_OVERRIDE=/nonexistent tools/dev/land-pr.sh 0 < "$LIST" > "$FB_OUT" 2>/dev/null \
  || { echo "FAIL  selftest run (fallback)"; exit 1; }

fail=0
if diff -u "$CFG_OUT" "$FB_OUT" > /dev/null; then
  echo "PASS  config-vs-fallback tier identity over $(wc -l < "$LIST") paths"
else
  echo "FAIL  config vs fallback tier divergence:"
  diff "$CFG_OUT" "$FB_OUT" | head -20
  fail=1
fi
grep -q "^security .claude/workflow.config.json$" "$CFG_OUT" \
  && echo "PASS  gate config classifies as security (self-protection)" \
  || { echo "FAIL  gate config must classify security"; fail=1; }
grep -q "^security .claude/workflow.config.d/nested.json$" "$CFG_OUT" \
  && echo "PASS  nested gate-config dir classifies as security (SAD-257 d)" \
  || { echo "FAIL  nested gate-config dir must classify security"; fail=1; }
grep -q "^security tools/dev/land-pr.sh$" "$CFG_OUT" \
  && echo "PASS  the funnel classifies as security" \
  || { echo "FAIL  land-pr.sh must classify security"; fail=1; }
grep -q "^docs docs/requirements.md$" "$CFG_OUT" \
  && echo "PASS  a docs path classifies as docs" \
  || { echo "FAIL  docs path must classify docs"; fail=1; }

grep -q "^security server/app/routers/feedback.py$" "$CFG_OUT" \
  && echo "PASS  a server/ backend path classifies as security (SAD-285)" \
  || { echo "FAIL  server/ backend path must classify security"; fail=1; }
grep -q "^code xserver/notbackend.py$" "$CFG_OUT" \
  && echo "PASS  xserver/ near-miss stays code — the ^server/ anchor holds (SAD-285)" \
  || { echo "FAIL  xserver/ near-miss must NOT classify security"; fail=1; }

# ---------- .claude/commands/ is a FOUR-path security set (SAD-546) ----------
# The rule: "commands that can destroy data or drive the gate". Everything else
# under .claude/commands/ stays docs-tier under the standing "Claude infra lands
# docs-tier" convention, so it remains cheap to edit.
#
# Why this is pinned per-path in BOTH outputs rather than left to the identity
# assertion above: identity only proves config and fallback AGREE. It stays
# green if both regress together — e.g. if someone "simplifies" the four back
# to a whole-directory ^\.claude/commands/ on one side and mirrors it on the
# other, or drops the four from both. Only an absolute per-path expectation
# catches a re-merge in either direction.
#
# The exposure this closes (Barb, PR #425 audit): a PR touching only
# .claude/commands/restore-synthetic.md — deleting its "never push to a physical
# device that still holds real training data" guard — classified `docs`, so G4
# printed "SKIP  docs tier — CI-alone policy" and it merged with ZERO reviewer
# or security verdict. .claude/commands/** is NOT in the ADR-0033
# self-modification carve-out, so an agent can land that autonomously; the next
# /restore-synthetic then wipes real training data. prune-worktrees.md (worktree
# deletion) is the same shape.
#
# Instance-#1-shaped by design, like the fallback patterns and the
# docs/requirements.md + server/ assertions above.
CMD_TIERS="
docs      .claude/commands/away.md
security  .claude/commands/issue.md
security  .claude/commands/land.md
docs      .claude/commands/linear-triage.md
security  .claude/commands/prune-worktrees.md
security  .claude/commands/restore-synthetic.md
"
cmd_tier_case() { # $1 = expected tier, $2 = repo-relative path
  local src f got
  for src in config fallback; do
    if [ "$src" = "config" ]; then f="$CFG_OUT"; else f="$FB_OUT"; fi
    got="$(awk -v p="$2" '$2==p{print $1}' "$f")"
    [ "$got" = "$1" ] \
      && echo "PASS  $2 is $1 tier ($src)" \
      || { echo "FAIL  $2 must be $1 tier under $src — got '${got:-<unclassified>}'"; fail=1; }
  done
}
while read -r _want _path; do
  [ -n "${_want:-}" ] || continue
  cmd_tier_case "$_want" "$_path"
done <<<"$CMD_TIERS"

# Completeness: the table must name EVERY tracked file under .claude/commands/.
# Without this, a NEW command file silently inherits docs tier from the `*.md`
# glob (or `code` if it is not markdown) and nobody makes a tier decision —
# which is exactly how restore-synthetic.md sat at docs. Adding a command now
# forces an explicit row here. Covers non-.md paths too, so narrowing the
# fallback from the whole directory to four files cannot quietly downgrade one.
_declared="$(awk 'NF{print $2}' <<<"$CMD_TIERS" | sort -u)"
_tracked="$(git ls-files '.claude/commands/' | sort -u)"
if [ "$_declared" = "$_tracked" ]; then
  echo "PASS  every tracked .claude/commands/ path has a declared tier (SAD-546)"
else
  echo "FAIL  the .claude/commands/ tier table is out of sync with the tree"
  echo "      (< declared-but-absent / > tracked-but-undeclared):"
  diff <(printf '%s\n' "$_declared") <(printf '%s\n' "$_tracked") | sed 's/^/      /' | head -10
  fail=1
fi

# ---------- G8 close-out SAD resolution (SAD-538) ----------
# The close-out must name the issue(s) a PR CLOSES — the `Fixes SAD-N` anchor —
# not the first SAD-N anywhere in the title/body. First-match named the wrong
# issue on 4/4 landings in one session (PRs #384/#388/#390/#392), once pointing
# at work that was actively In Progress. Uses land-pr.sh's hidden LAND_PR_SADTEST
# mode: stdin line 1 = PR title, remaining lines = body -> "<provenance> <SAD-N…>".
sad_case() { # $1 = label, $2 = expected, $3 = title, $4 = body
  local got
  got="$(LAND_PR_TEST=1 LAND_PR_SADTEST=1 tools/dev/land-pr.sh 0 <<<"$3
$4")"
  [ "$got" = "$2" ] \
    && echo "PASS  $1" \
    || { echo "FAIL  $1 — expected '$2', got '$got'"; fail=1; }
}

# The exact shape that misfired: related issues cited as background ABOVE the
# closing line, which by convention sits at the bottom (PR #392 -> SAD-519,
# mis-detected as the then-In-Progress SAD-488).
sad_case "anchor beats background citations cited first (PR #392 shape)" "anchor SAD-519" \
  "feat(plan): a double day imports as two workouts" \
  "$(printf 'Same defect class as SAD-488; supersedes the first bullet of SAD-509.\n\nFixes SAD-519\n')"
sad_case "anchor when it is the ONLY mention" "anchor SAD-510" "fix: bundle write" "Fixes SAD-510"
sad_case "Closes is a closing keyword" "anchor SAD-42" "t" "$(printf 'background SAD-7\n\nCloses SAD-42\n')"
sad_case "Resolves is a closing keyword" "anchor SAD-42" "t" "$(printf 'background SAD-7\n\nResolves SAD-42\n')"
sad_case "past-tense Fixed is a closing keyword" "anchor SAD-42" "t" "$(printf 'background SAD-7\n\nFixed SAD-42\n')"
sad_case "lowercase + colon form (fixes: SAD-N)" "anchor SAD-42" "t" "$(printf 'see SAD-7\n\nfixes: SAD-42\n')"
sad_case "id is canonicalized to upper case" "anchor SAD-42" "t" "fixes sad-42"
# Multi-anchor: 2 of the last 60 PRs closed two issues (#368, #360). Naming only
# the first silently skips the other's close-out (Watson Important, PR #399).
sad_case "EVERY anchor is named, in order" "anchor SAD-480 SAD-481" "t" \
  "$(printf 'Fixes SAD-480\nFixes SAD-481\n')"
sad_case "repeated anchors de-duplicate" "anchor SAD-480" "t" \
  "$(printf 'Fixes SAD-480\n\n...\n\nFixes SAD-480\n')"
# Title/body are scanned SEPARATELY — a keyword-shaped title must not outrank a
# real body anchor, and joining the fields must not manufacture an anchor across
# the boundary (Watson Important / Barb LOW, PR #399).
sad_case "a real BODY anchor outranks a keyword-shaped title" "anchor SAD-200" \
  "fix: SAD-100 regresses the node ring" "Fixes SAD-200"
sad_case "title+body join does NOT manufacture an anchor across the boundary" "fallback SAD-367" \
  "fix(thread): colour the node ring — quick fix" \
  "$(printf 'SAD-367 describes the ring.\n\nRelates to SAD-520\n')"
sad_case "title anchor is used when the body has none" "anchor SAD-9" "fixes SAD-9" "no anchor here"
# \b guard: a word merely ENDING in a keyword is not a closing anchor.
sad_case "'prefixes SAD-N' is NOT an anchor — falls back" "fallback SAD-7" "t" "prefixes SAD-7"
sad_case "no anchor at all -> first-match fallback, flagged as such" "fallback SAD-7" "t" \
  "relates to SAD-7 and SAD-9"
sad_case "no SAD-N at all -> none" "none" "docs: tidy the README" "nothing to see"

# ---------- locale independence of the id shape (SAD-551) ----------
# The SAD-id classes are ENUMERATED ([0123456789]) because GNU grep 3.11 under
# this box's en_US.UTF-8 overruns the reported MATCH EXTENT of a RANGE bracket
# expression when a non-ASCII decimal digit follows an ASCII one — so `grep -o`
# emits the trailing garbage and the EXTRACTED id is corrupted. See the block
# above _sad_anchor_ids in land-pr.sh.
#
# THE case that discriminates the enumerated class from the range: it goes RED
# against [0-9] (resolves to the malformed id `SAD-538<d9 a5>`). Anyone
# "simplifying" the class back to [0-9] trips this. The non-leading position is
# load-bearing — in a LEADING position the range never matches at all, so a
# leading-only test passes against BOTH forms and pins nothing.
sad_case "non-ASCII digit in a NON-leading position truncates cleanly" "anchor SAD-538" "t" \
  "$(printf 'Fixes SAD-538\xd9\xa5\n')"
# Characterization only — these two pass against both forms (a leading non-ASCII
# digit means the `+` has nothing to anchor on). Kept for the shape, NOT relied
# on as pins; the non-leading case above is the one that discriminates.
sad_case "non-ASCII digits are not a SAD id (Arabic-Indic)" "none" "t" \
  "$(printf 'Fixes SAD-\xd9\xa5\xd9\xa3\xd9\xa8\n')"
sad_case "non-ASCII digits are not a SAD id (fullwidth)" "none" "t" \
  "$(printf 'Fixes SAD-\xef\xbc\x95\xef\xbc\x93\xef\xbc\x98\n')"
# Guards the OTHER direction: goes RED the moment anyone pins the ranges with
# LC_ALL=C instead, because that changes LC_CTYPE too and "präfixes" would then
# read as a closing anchor — reopening the exact wrong-issue write \b closes.
#
# Run with a HOSTILE locale on purpose. Asserting this under the developer's
# ambient en_US.UTF-8 only proves the property in a friendly environment: before
# land-pr.sh pinned LC_CTYPE, this exact case failed on UNCHANGED code under
# LC_ALL=C / LANG=C / LC_CTYPE=C — a false RED for anyone running the harness
# from a bare container or stripped CI shell, and a live false anchor in
# production for the same callers. LC_ALL=C is the strongest form: it outranks
# LC_CTYPE, so it also proves the pin's `unset LC_ALL` is doing its job.
# Watson Important, PR #399 / SAD-551.
sad_case_hostile() { # $1 = label, $2 = expected, $3 = title, $4 = body
  local got
  got="$(LC_ALL=C LAND_PR_TEST=1 LAND_PR_SADTEST=1 tools/dev/land-pr.sh 0 <<<"$3
$4")"
  [ "$got" = "$2" ] \
    && echo "PASS  $1" \
    || { echo "FAIL  $1 — expected '$2', got '$got'"; fail=1; }
}
sad_case_hostile "'präfixes SAD-N' is NOT an anchor even under LC_ALL=C" "fallback SAD-7" "t" \
  "$(printf 'pr\xc3\xa4fixes SAD-7\n')"

# ---------- picker seam: unterminated stdin (SAD-551) ----------
# `read` assigns the partial line and THEN returns non-zero at EOF, so the old
# `|| _sad_t=""` threw away a title that arrived without a trailing newline.
# Only the SEAM is affected — the real G8 passes title/body as ARGUMENTS — but
# the seam is what every case above trusts, so it has to resolve the same text
# production does. Watson, PR #399.
sad_raw_case() { # $1 = label, $2 = expected, $3 = exact stdin (printf %b escapes)
  local got
  got="$(printf '%b' "$3" | LAND_PR_TEST=1 LAND_PR_SADTEST=1 tools/dev/land-pr.sh 0)"
  [ "$got" = "$2" ] \
    && echo "PASS  $1" \
    || { echo "FAIL  $1 — expected '$2', got '$got'"; fail=1; }
}
sad_raw_case "unterminated title (no trailing newline) survives" "anchor SAD-9" 'fixes SAD-9'
sad_raw_case "unterminated body still resolves its anchor" "anchor SAD-200" \
  'fix: SAD-100 regresses the node ring\nFixes SAD-200'
sad_raw_case "empty stdin -> none (set -u stays satisfied)" "none" ''
# CLOSED fd 0, not merely empty: `read` errors WITHOUT assigning, which `set -u`
# turns into "_sad_t: unbound variable" unless the variable is pre-seeded. The
# old `|| _sad_t=""` covered this incidentally; `|| :` alone does not.
#
# Pinned on the IDIOM rather than by driving land-pr.sh with `<&-`: the seam's
# next statement is `_sad_b="$(cat)"`, and `cat` on a closed fd 0 blocks, so the
# whole-script route hangs the suite instead of asserting. Keep it this shape.
# Barb LOW-1, PR #399 / SAD-551.
_seam_idiom='set -u; _sad_t=""; IFS= read -r _sad_t || :; printf "[%s]" "$_sad_t"'
got="$(timeout 10 bash -c "$_seam_idiom" <&- 2>/dev/null)"
[ "$got" = "[]" ] \
  && echo "PASS  closed fd 0 -> empty (pre-seed keeps set -u satisfied)" \
  || { echo "FAIL  closed fd 0 -> empty — expected '[]', got '$got'"; fail=1; }
got="$(printf 'abc' | timeout 10 bash -c "$_seam_idiom" 2>/dev/null)"
[ "$got" = "[abc]" ] \
  && echo "PASS  the same idiom still keeps an unterminated line" \
  || { echo "FAIL  idiom lost the unterminated line — expected '[abc]', got '$got'"; fail=1; }

# The seam itself must be refused without LAND_PR_TEST=1 — it skips every gate,
# so --dry-run is NOT sufficient authorization (Barb MEDIUM, PR #399).
if LAND_PR_SADTEST=1 tools/dev/land-pr.sh 0 --dry-run </dev/null >/dev/null 2>&1; then
  echo "FAIL  LAND_PR_SADTEST must be refused without LAND_PR_TEST=1 (even with --dry-run)"; fail=1
else
  echo "PASS  LAND_PR_SADTEST refused without LAND_PR_TEST=1 (--dry-run is not authorization)"
fi

echo "RESULT: $([ "$fail" = "0" ] && echo "tier classification + SAD resolution OK" || echo "LAND-PR SELFTESTS BROKEN")"
exit "$fail"
