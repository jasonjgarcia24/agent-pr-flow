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
    sub/dir/gradle.properties .claude/workflow.config.json
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
grep -q "^security tools/dev/land-pr.sh$" "$CFG_OUT" \
  && echo "PASS  the funnel classifies as security" \
  || { echo "FAIL  land-pr.sh must classify security"; fail=1; }
grep -q "^docs docs/plans/SAD-175-pm-ops-cleanup.md$" "$CFG_OUT" \
  && echo "PASS  a docs path classifies as docs" \
  || { echo "FAIL  docs path must classify docs"; fail=1; }

echo "RESULT: $([ "$fail" = "0" ] && echo "tier classification OK" || echo "TIER CLASSIFICATION BROKEN")"
exit "$fail"
