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
#
# The fixed set carries every path an assertion below names, INCLUDING the ones the
# reference instance happens to track (`tools/dev/land-pr.sh`, `docs/requirements.md`).
# Leaning on `git ls-files` for those made the suite instance-coupled: in a scratch target
# — or any repo that has not committed the installed files yet — the paths are absent, the
# assertions fail, and the failure says "the funnel does not classify as security" when the
# truth is "that path was never fed in". These assertions are about the PATTERNS, so the
# input must not depend on what a given repo happens to track. `sort -u` dedupes against
# `git ls-files` where the paths really are tracked.
{
  git ls-files
  printf '%s\n' app/.gitignore XAndroidManifest.xml .claude/hooksx/evil.sh \
    docsx/a.txt tools/dev/land-pr.sh.orig server/.gitignore \
    server/app/routers/feedback.py xserver/notbackend.py \
    sub/dir/gradle.properties .claude/workflow.config.json \
    .claude/workflow.config.d/nested.json .claude/workflow.config.yaml \
    tools/dev/land-pr.sh docs/requirements.md
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

# The seam itself must be refused without LAND_PR_TEST=1 — it skips every gate,
# so --dry-run is NOT sufficient authorization (Barb MEDIUM, PR #399).
if LAND_PR_SADTEST=1 tools/dev/land-pr.sh 0 --dry-run </dev/null >/dev/null 2>&1; then
  echo "FAIL  LAND_PR_SADTEST must be refused without LAND_PR_TEST=1 (even with --dry-run)"; fail=1
else
  echo "PASS  LAND_PR_SADTEST refused without LAND_PR_TEST=1 (--dry-run is not authorization)"
fi

echo "RESULT: $([ "$fail" = "0" ] && echo "tier classification + SAD resolution OK" || echo "LAND-PR SELFTESTS BROKEN")"
exit "$fail"
