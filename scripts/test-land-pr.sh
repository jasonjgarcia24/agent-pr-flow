#!/usr/bin/env bash
# shellcheck disable=SC2015  # A && pass || fail assertion rows: the pass-echo cannot fail
# tools/dev/test-land-pr.sh — tier-classification regression (Watson, PR #162).
# The config-driven and hardcoded-fallback patterns must classify IDENTICALLY:
# the PR-#162 collating-symbol bug shipped with a green 140-case hook harness
# while every land-pr tier was silently wrong — this closes that blind spot.
# Uses land-pr.sh's hidden LAND_PR_SELFTEST mode (no PR is read or touched).

set -u

ROOT="$(git rev-parse --show-toplevel)" || exit 1
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
# POSIX leaves a RANGE inside a bracket expression ([0-9]) UNSPECIFIED outside
# the C locale, and this repo already shipped one collating-symbol bug (PR #162),
# so the digit classes are written ENUMERATED. Two properties are pinned
# together because the obvious alternative fix — LC_ALL=C — buys the first at the
# cost of the second (it changes LC_CTYPE too, so a non-ASCII byte stops being a
# word character and `\b` fires mid-word). See land-pr.sh's _sad_anchor_ids.
sad_case "non-ASCII digits are not a SAD id (Arabic-Indic)" "none" "t" \
  "$(printf 'Fixes SAD-\xd9\xa5\xd9\xa3\xd9\xa8\n')"
sad_case "non-ASCII digits are not a SAD id (fullwidth)" "none" "t" \
  "$(printf 'Fixes SAD-\xef\xbc\x95\xef\xbc\x93\xef\xbc\x98\n')"
# The discriminating half: goes RED the moment anyone pins the ranges with
# LC_ALL=C instead, because "präfixes" would then read as a closing anchor —
# reopening the exact wrong-issue write the \b guard closes.
sad_case "'präfixes SAD-N' is NOT an anchor either (\\b needs LC_CTYPE)" "fallback SAD-7" "t" \
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

# The seam itself must be refused without LAND_PR_TEST=1 — it skips every gate,
# so --dry-run is NOT sufficient authorization (Barb MEDIUM, PR #399).
if LAND_PR_SADTEST=1 tools/dev/land-pr.sh 0 --dry-run </dev/null >/dev/null 2>&1; then
  echo "FAIL  LAND_PR_SADTEST must be refused without LAND_PR_TEST=1 (even with --dry-run)"; fail=1
else
  echo "PASS  LAND_PR_SADTEST refused without LAND_PR_TEST=1 (--dry-run is not authorization)"
fi

echo "RESULT: $([ "$fail" = "0" ] && echo "tier classification + SAD resolution OK" || echo "LAND-PR SELFTESTS BROKEN")"
exit "$fail"
