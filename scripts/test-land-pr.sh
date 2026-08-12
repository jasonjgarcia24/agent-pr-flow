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
# SAD-629 — RESOLVE the script path before taking its dirname. BASH_SOURCE[0] is
# the path AS INVOKED, not the real path, so reaching this script through a
# SYMLINK resolved `dirname` to the symlink's directory — i.e. some OTHER
# checkout — and the suite then exercised that tree's classifier. Watson proved
# it: a symlinked run exercised a PRE-FIX classifier and failed loud only because
# the new SAD-546 tier pins happened to be present. Before those pins existed the
# same run would have printed a wrong-tree PASS, which is the dangerous direction
# — it green-lights a gate change that was never exercised. That is exactly the
# failure the BASH_SOURCE change was landed to close, left half-open.
_SELF="$(readlink -f -- "${BASH_SOURCE[0]}" 2>/dev/null || realpath -- "${BASH_SOURCE[0]}" 2>/dev/null || printf '%s' "${BASH_SOURCE[0]}")"
ROOT="$(git -C "$(dirname -- "$_SELF")" rev-parse --show-toplevel)" || exit 1
cd "$ROOT" || exit 1

LIST="$(mktemp)"; CFG_OUT="$(mktemp)"; FB_OUT="$(mktemp)"
trap 'rm -f "$LIST" "$CFG_OUT" "$FB_OUT" "${_g3_marker:-}"' EXIT

# ---------- the gated-infra sensitivity record (SAD-546 / SAD-682) ----------
# Resolved HERE, before the classifier input is built, because every declared
# path has to be fed in — a path this tree does not track still has a tier, and
# the rows below assert the PATTERN, not the file's existence. See the block at
# the GATED_INFRA assertions for why the record lives in an instance-owned file.
_GI_FILE="$ROOT/tools/dev/gated-infra.txt"
if [ -f "$_GI_FILE" ]; then
  GATED_INFRA="$(grep -vE '^[[:space:]]*(#|$)' "$_GI_FILE")"
  _gi_owned=1
else
  GATED_INFRA="$(git ls-files '.claude/commands/' '.claude/agents/' | sed 's/^/derived      /')"
  _gi_owned=0
fi

# Every tracked file + a fixed adversarial set (near-miss names, nested files).
#
# ⚠ THE FIXED SET CARRIES EVERY PATH AN ASSERTION BELOW NAMES, including ones the
# reference instance happens to track (`tools/dev/land-pr.sh`,
# `docs/requirements.md`) and every gated-infra path. Leaning on `git ls-files`
# for those made the suite instance-coupled: in a scratch install target — or any
# repo that has not committed the installed files yet — the paths are absent, the
# assertions fail, and the failure reads "the funnel does not classify as
# security" when the truth is "that path was never fed in". These assertions are
# about the PATTERNS, so the input must not depend on what a given repo tracks.
# `sort -u` dedupes against `git ls-files` where the paths really are tracked.
# (Ported from agent-pr-flow PR #9 and extended during the SAD-682 back-port,
# where a clean scratch install measured 40 failures, all of this shape.)
{
  git ls-files
  awk 'NF{print $2}' <<<"$GATED_INFRA"
  printf '%s\n' app/.gitignore XAndroidManifest.xml .claude/hooksx/evil.sh \
    docsx/a.txt tools/dev/land-pr.sh.orig server/.gitignore \
    server/app/routers/feedback.py xserver/notbackend.py \
    sub/dir/gradle.properties .claude/workflow.config.json \
    .claude/workflow.config.d/nested.json .claude/workflow.config.yaml \
    tools/dev/land-pr.sh docs/requirements.md \
    local.properties app/google-services.json \
    nested/dir/local.properties app/google-services.json.bak \
    xlocal.properties app/xgoogle-services.json \
    app/src/debug/google-services.json google-services.json
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

# ---------- the gitignored copyIntoWorktree build inputs (SAD-686) ----------
# ⚠ THESE FIXTURES ARE LOAD-BEARING, and their absence was a measured hole.
# `local.properties` and `app/google-services.json` are GITIGNORED, so they never
# appear in `git ls-files` and therefore never entered the identity comparison
# above. Measured while landing SAD-686: reverting the two patterns from
# land-pr.sh's hardcoded FALLBACK ERE — a textbook half-move of the SAD-285
# lockstep — left the whole suite GREEN (0 FAIL), because config and fallback
# agreed on every path the list happened to contain. The same revert applied to
# the config or to workflow.md's fenced record each reddened one row.
# So the very property that makes these two patterns zero-false-positive (nothing
# tracked matches them) is the property that hid them from the assertion meant to
# keep the four surfaces in step. They are synthetic entries in the adversarial
# set above for exactly that reason.
#
# Pinned in BOTH outputs, per the reasoning recorded below for GATED_INFRA:
# identity only proves config and fallback AGREE, and stays green if both regress
# together. Only an absolute per-path expectation catches that.
copy_input_case() { # $1 = expected tier, $2 = path, $3 = why
  local src f got
  for src in config fallback; do
    if [ "$src" = "config" ]; then f="$CFG_OUT"; else f="$FB_OUT"; fi
    got="$(awk -v p="$2" '$2==p{print $1}' "$f")"
    [ "$got" = "$1" ] \
      && echo "PASS  $2 is $1 tier ($src) [$3]" \
      || { echo "FAIL  $2 must be $1 tier under $src — got '${got:-<unclassified>}' [$3]"; fail=1; }
  done
}
# A PR that TRACKS either of these is anomalous by construction — both are
# gitignored and required in every checkout — and under codeTierPolicy: ci-only
# a `code` classification lands it with zero review, repointing the app's backend
# on the next build.
copy_input_case security local.properties               "gitignored build input"
copy_input_case security app/google-services.json       "real Firebase client config"
copy_input_case security nested/dir/local.properties    "slash-less glob matches at any depth"
# ⚠ THE TWO ROWS BELOW ARE THE POINT, not extra coverage. The first cut anchored
# this entry as `app/google-services.json`, reasoning that a renamed copy is inert
# because the Firebase plugin reads it by path. That reasoning was WRONG, and the
# refutation is mechanical: the Google Services plugin builds a SET of candidate
# paths (`src/$location/google-services.json`) and sorts them by slash count
# DESCENDING — deeper wins. So a tracked `app/src/debug/google-services.json` does
# not merely also work, it BEATS `app/google-services.json` on the next build, and
# under the path-anchored pattern it classified `code` and landed unreviewed.
# The repo's own .gitignore recorded this exact near-miss days earlier. The entry is
# therefore slash-less, like `local.properties` — SAD-546's lesson holds after all,
# and the "a filename is complete here" carve-out only ever applied to the one file
# that really is read by a single name (Watson, PR #571).
copy_input_case security app/src/debug/google-services.json "deeper path WINS in the plugin's own ordering"
copy_input_case security google-services.json           "repo-root copy is a candidate too"
# Near-misses: the anchors must hold, or the two entries above become a prefix
# sweep over neighbouring names rather than the two exact build inputs.
copy_input_case code     app/google-services.json.bak   "trailing-suffix near-miss stays code"
copy_input_case code     xlocal.properties              "leading-prefix near-miss stays code"
copy_input_case code     app/xgoogle-services.json      "leading-prefix near-miss stays code"

# ---------- .claude/commands/ + .claude/agents/ are WHOLE-DIRECTORY security (SAD-546) ----------
# EVERY tracked path in both directories must classify `security` under BOTH the
# config and the fallback. The sensitivity column is the written record of WHY
# the directories are gated — it is documentation, NOT a per-file tier
# expectation. Do not reintroduce a docs-tier row: that is the allowlist shape
# this change deliberately abandoned.
#
# History, so nobody re-derives the abandoned form: this started as an allowlist
# of the four commands that can destroy data or drive the gate. Because the
# residual tier of both directories is `docs` (everything matches the `*.md`
# docs glob), an allowlist is defeated four ways — RENAME (G3 READ only
# .filename until SAD-604 unioned .previous_filename in), SIBLING (restore-synthetic-v2.md),
# NAMESPACE (dev/restore-synthetic.md), and NEW COMMAND (wipe-device.md, born
# destructive and on no list). Whole-directory closes all four at once and keeps
# the FALLBACK fail-safe, which is the property it must have: it stands in for a
# config that cannot be trusted, so it must never be narrower than that config.
#
# The exposure this closes (Barb, PR #425 audit): a PR touching only
# .claude/commands/restore-synthetic.md — deleting its "never push to a physical
# device that still holds real training data" guard — classified `docs`, so G4
# printed "SKIP  docs tier — CI-alone policy" and it merged with ZERO reviewer
# or security verdict. .claude/commands/** is NOT in the ADR-0033
# self-modification carve-out, so an agent can land that autonomously; the next
# /restore-synthetic then wipes real training data.
#
# Why pinned per-path in BOTH outputs rather than left to the identity assertion
# above: identity only proves config and fallback AGREE. It stays green if both
# regress together. Only an absolute per-path expectation catches that.
#
# ⚠ THE RECORD MOVED OUT OF THIS FILE (SAD-682). It used to be a heredoc table
# right here, which made a bundle-managed suite carry one instance's inventory:
# in an adopter's tree the commands are different, so the completeness check
# below went red on a perfectly healthy install for reasons that had nothing to
# do with the gate. Measured during the SAD-682 back-port trial — a clean
# scratch install failed it, along with two tier rows for paths that tree simply
# does not have.
#
# `tools/dev/gated-infra.txt` is INSTANCE-OWNED (and `tools/**` security tier, so
# editing the record still draws Barb). When it is absent the set is derived from
# the tree instead: the tier rows still run — they are about the PATTERNS and
# hold for any path, tracked or not — and the completeness row says out loud that
# the record half was not checked, rather than passing quietly.
# (GATED_INFRA and _gi_owned are resolved near the top of this file — the
# classifier input list has to carry every declared path, so the read happens
# before the list is built.)
infra_tier_case() { # $1 = sensitivity (documentation only), $2 = repo-relative path
  local src f got
  for src in config fallback; do
    if [ "$src" = "config" ]; then f="$CFG_OUT"; else f="$FB_OUT"; fi
    got="$(awk -v p="$2" '$2==p{print $1}' "$f")"
    [ "$got" = "security" ] \
      && echo "PASS  $2 is security tier ($src) [$1]" \
      || { echo "FAIL  $2 must be security tier under $src — got '${got:-<unclassified>}'"; fail=1; }
  done
}
while read -r _sens _path; do
  [ -n "${_sens:-}" ] || continue
  infra_tier_case "$_sens" "$_path"
done <<<"$GATED_INFRA"

# Completeness: the table must name EVERY tracked file under BOTH directories.
# Whole-directory patterns already gate a new file, so this no longer guards the
# TIER — it guards the RECORD: adding a command or an agent charter forces an
# explicit sensitivity row, which is what makes the gating rationale reviewable
# instead of folklore. It also catches the reverse (a row for a deleted file).
_declared="$(awk 'NF{print $2}' <<<"$GATED_INFRA" | sort -u)"
_tracked="$(git ls-files '.claude/commands/' '.claude/agents/' | sort -u)"
if [ "$_gi_owned" != "1" ]; then
  # No instance record in this tree. The tier rows above still ran — derived from
  # the tree, so they cover exactly what is there. Say what was NOT checked.
  echo "PASS  gated-infra tiers verified from the tree; the sensitivity RECORD is instance-owned and tools/dev/gated-infra.txt is absent here, so its completeness is not asserted (SAD-682)"
elif [ "$_declared" = "$_tracked" ]; then
  # ⚠ AN EXTRA ROW ON THE PRESENT PATH, so the CI floor can see the one downgrade
  # this refactor introduces (Watson, PR #570). Removing a LINE from the record
  # is caught twice — set equality reddens and the count drops below the floor.
  # Deleting the FILE was caught by neither: `_gi_owned=0` emits its own PASS,
  # the derived set reproduces the same paths, and the total was unchanged. One
  # row makes present and absent differ by one, so the zero-headroom floor
  # reddens on a `git rm` of the record. Adopters carry their own floor, so this
  # stays correct for them too.
  echo "PASS  tools/dev/gated-infra.txt is present — the sensitivity record is asserted, not derived (SAD-682)"
  echo "PASS  every tracked .claude/commands/ + .claude/agents/ path is declared (SAD-546)"
else
  echo "FAIL  tools/dev/gated-infra.txt is out of sync with the tree"
  echo "      (< declared-but-absent / > tracked-but-undeclared):"
  diff <(printf '%s\n' "$_declared") <(printf '%s\n' "$_tracked") | sed 's/^/      /' | head -10
  fail=1
fi

# ---------- the PROSE surface must match the config (Barb MED-3 / LOW-3) ----------
# Six surfaces state this tier rule: the config, the land-pr.sh fallback, the
# bundle's config template, the §5 tier paragraph in the workflow reference, and
# the two script comment blocks. One of them (the workflow paragraph) drifted
# INSIDE the PR that introduced this test — it still described the abandoned
# allowlist. Prose that contradicts the gate is how the next author "simplifies"
# the gate back to a weaker shape, so the doc is asserted, not trusted.
#
# TWO DIRECTIONS, and until PR #547 only one of them existed.
#   config -> prose  every entry in securityTierPatterns must appear in the RECORD
#                    list. Catches the doc UNDER-describing what is gated — the
#                    drift that actually happened.
#   prose -> config  every entry in the RECORD list must BE a config pattern.
#                    ⚠ This half was claimed and absent: the comment here said a
#                    backticked path in the prose that is not gated "is caught by
#                    the same comparison from the other side", and there was no
#                    other side. Verified: adding `totally/not/gated/**` to the §5
#                    list left the suite 174/174 green (Watson, PR #547). The harm
#                    direction is the worse one — §5 can claim a path is
#                    security-tier when it is not, a reviewer trusts the doc, and
#                    a PR touching that path lands on green CI with zero reviews.
#
# ⚠ BOTH DIRECTIONS READ THE SAME REGION, and the first cut of the pair did not —
# which made each half independently falsifiable (Watson delta, PR #547):
#   * config -> prose grepped the whole §5 WINDOW, so a pattern deleted from the
#     record list still matched its own mention in the rationale prose above.
#     Measured: deleting `tools/**` and `.mcp.json` from the record left BOTH
#     config->prose rows green. 10 of the 20 patterns appear twice in that
#     window, i.e. half the list was deletable with nothing going red.
#   * prose -> config read an awk range anchored on the list's first and last
#     ENTRIES, so a fictional pattern one line above `.github/**` or one line
#     below `server/**` — visually inside the list — fell outside the range.
#     Both measured GREEN.
# The record is now a FENCED BLOCK, extracted ONCE into `$_record` and used by
# every row. Fence delimiters do not depend on the content they wrap, so neither
# leak is reachable, and one entry per line removes the `·`-separator ambiguity.
#
# ⚠ SAD-655 item 5 — THE `startswith(".claude/")` FILTER IS GONE. It was added
# when the only patterns the paragraph enumerated were the `.claude/` ones, and
# it silently stopped growing with the config: SAD-630/647 added `tools/**`,
# `gradlew`, `gradlew.bat` and four app surfaces, and every one of them landed as
# UNASSERTED PROSE — free to drift from the gate it describes, which is the exact
# failure this test exists to catch, one pattern-class over. The paragraph now
# carries a verbatim "exact patterns" list so the assertion can be total.
#
# Split into TWO rows on purpose. The `.claude/` half is the original SAD-546
# assertion and keeps its own provenance; the residual half is the new coverage,
# and a single merged row would let the new half be deleted without the count
# moving.
WF_REF=".claude/references/pm/workflow.md"
WF_CFG=".claude/workflow.config.json"
# $3 is the RECORD list, PASSED IN. It used to read an implicit `$_para` global
# assigned below this definition — which works only because the calls are also
# below, and reads as a free variable to anyone editing either half (Watson).
# Matching is now whole-line against the record, not a substring grep over a
# 151-line window: `grep -qF "\`$e\`"` matched the rationale prose too, which is
# what let half the record list be deleted with every row still green.
prose_case() { # $1 = label, $2 = jq select expression over the pattern string, $3 = record list
  local pats missing="" e
  pats="$(jq -r ".review.securityTierPatterns[]? | select($2)" "$WF_CFG" | LC_ALL=C sort -u)"
  # An empty pattern set would make this vacuously green — the SAD-547 lesson.
  if [ -z "$pats" ]; then
    echo "FAIL  $1 — the pattern selection matched NOTHING, so the row asserts nothing"; fail=1; return
  fi
  while IFS= read -r e; do
    [ -n "$e" ] || continue
    grep -qxF -- "$e" <<<"$3" || missing="${missing}${missing:+, }$e"
  done <<<"$pats"
  if [ -z "$missing" ]; then
    echo "PASS  $1"
  else
    echo "FAIL  $WF_REF §5's record list does not name: $missing"
    echo "      SAD-285 lockstep — the config, the land-pr.sh fallback and this"
    echo "      paragraph move together (the upstream bundle template is an"
    echo "      instruction, not a gate — it is in another repo; SAD-655)."
    fail=1
  fi
}
if [ -f "$WF_CFG" ] && [ -f "$WF_REF" ]; then
  # THE ONE EXTRACTION both directions read: the lines between the first and
  # second fence following the "exact patterns, verbatim" marker. Anchored on the
  # marker and on fence delimiters, never on entry CONTENT — that is what closes
  # the append-above/append-below leak.
  _record="$(awk '
      /\*\*The exact patterns, verbatim\*\*/ { seen = 1 }
      seen && /^[[:space:]]*```/ { fence++; next }
      fence >= 2 { exit }
      seen && fence == 1 { print }
    ' "$WF_REF" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | grep -v '^$')"
  _pcfg="$(jq -r '.review.securityTierPatterns[]?' "$WF_CFG" | LC_ALL=C sort -u)"
  # An empty extraction on EITHER side would make all three rows vacuous.
  if [ -z "$_record" ] || [ -z "$_pcfg" ]; then
    echo "FAIL  $WF_REF §5's fenced record list extracted NOTHING (or the config has no patterns) — all three prose/config rows would assert nothing; the awk anchors on the 'exact patterns, verbatim' marker and the fence that follows it"; fail=1
    echo "FAIL  …so the .claude/ half asserts nothing either"; fail=1
    echo "FAIL  …and neither does the prose->config half"; fail=1
  else
    prose_case "$WF_REF §5's record list names every .claude/ security pattern (SAD-546)" \
      'startswith(".claude/")' "$_record"
    prose_case "$WF_REF §5's record list names every NON-.claude/ security pattern too (SAD-655)" \
      'startswith(".claude/") | not' "$_record"
    # THE OTHER SIDE — every record entry must be a real config pattern.
    #
    # ⚠ NOT `comm`, and the first cut used it. `comm` requires BOTH inputs sorted
    # in the collation IT uses, and there are TWO independent ways to violate that
    # here — which is the point: an ordering-sensitive comparison has more than one
    # way to go wrong, and only one of them is loud.
    #
    #   (a) COLLATION MISMATCH. Feed it `LC_ALL=C sort -u` output while `comm`
    #       itself runs under this box's en_US.UTF-8 and it disagrees with the
    #       ordering it was just handed. Measured on the real 20-pattern config
    #       with two entries removed from the record: `comm: file 1 is not in
    #       sorted order` plus ELEVEN GATED paths emitted as if ungated. The
    #       discriminator: the byte-identical inputs under `LC_ALL=C comm` are
    #       clean and silent. This is the one the committed code actually hit.
    #   (b) UNSORTED INPUT. `$_record` is extracted in DOCUMENT order; if it is
    #       not sorted at all the same failure occurs regardless of collation
    #       (measured separately, ~15 paths).
    #
    # ⚠ Note (a) is invisible to the obvious experiment: comparing two IDENTICAL
    # C-sorted lists passes cleanly under either locale, because `comm` consumes
    # them in lockstep and never reaches a comparison that exposes the disorder.
    # The bug only appears once the sets DIFFER — i.e. exactly when this row has
    # something to report. Do not conclude from a clean equal-sets run that
    # pinning `LC_ALL=C` on the two `sort`s would have been sufficient; it was not
    # (that IS case (a)), and pinning `comm` too would only have closed (a).
    #
    # A warning on stderr and garbage on stdout is the loud half. The quiet half
    # is NOT truncation — an earlier revision of this comment said `comm` "stops
    # early on unsorted input, which can empty the diff", and that does not
    # reproduce: on GNU coreutils 9.4 (this box and the runner) the DEFAULT
    # invocation warns and COMPLETES, printing the wrong diff and exiting 1. Only
    # `comm --check-order`, a flag this code never passed, aborts mid-stream and
    # empties stdout. The real quiet half is that `| tr` DISCARDS comm's exit
    # status — measured, comm rc 1 becomes pipeline rc 0 — so a wrong answer is
    # reported as an ordinary row rather than as a tooling failure.
    # `grep -vxF -f` is a set-membership test with no ordering semantics at all,
    # so neither (a) nor (b) can apply — the failure mode is removed rather than
    # configured away.
    # `|| true` because grep exits 1 when nothing is left over, which is the
    # PASSING case here.
    _extra="$(printf '%s\n' "$_record" \
                | grep -vxF -f <(printf '%s\n' "$_pcfg") | tr '\n' ' ' || true)"
    if [ -z "${_extra// /}" ]; then
      echo "PASS  $WF_REF §5's record list names NOTHING that is not actually gated (SAD-655)"
    else
      echo "FAIL  $WF_REF §5's record list claims security tier for path(s) the config does NOT gate: ${_extra% }"
      echo "      This is the dangerous direction: a reviewer trusts the doc, and a"
      echo "      PR touching that path lands on green CI with zero verdicts."
      fail=1
    fi
  fi
else
  echo "PASS  prose/config agreement skipped (no config or no $WF_REF)"
  echo "PASS  prose/config agreement (residual patterns) skipped for the same reason"
  echo "PASS  prose->config agreement skipped for the same reason"
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
sad_case "non-ASCII digit in a NON-leading position truncates cleanly" "anchor SAD-538 hidden" "t" \
  "$(printf 'Fixes SAD-538\xd9\xa5\n')"
# Characterization only — these two pass against both forms (a leading non-ASCII
# digit means the `+` has nothing to anchor on). Kept for the shape, NOT relied
# on as pins; the non-leading case above is the one that discriminates.
sad_case "non-ASCII digits are not a SAD id (Arabic-Indic)" "none hidden" "t" \
  "$(printf 'Fixes SAD-\xd9\xa5\xd9\xa3\xd9\xa8\n')"
sad_case "non-ASCII digits are not a SAD id (fullwidth)" "none hidden" "t" \
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

# ---------- the OTHER arm of _sad_visible (SAD-655 / Barb MED-3, PR #547) ----------
# ⚠ `LC_ALL=C` DOES NOT REACH IT, and believing otherwise is what left this arm
# with one assertion. `_sad_visible` branches on `SAD_UTF8_CTYPE`, which is set by
# probing for C.UTF-8 — and that probe SUCCEEDS on any box that has C.UTF-8,
# whatever the caller's locale, because the pin then unsets LC_ALL. So every
# `sad_case_hostile` row above runs the UTF-8 arm too. Measured: reverting the
# `else` arm to a bare `_sad_strip_comments` — deleting the link-ref strip AND the
# entity decoder, i.e. half the SAD-655 fix — leaves all of them GREEN.
#
# The arm that goes unexercised is the one the locale preamble calls the most
# likely hostile case: a bare container / systemd unit / stripped CI shell with no
# C.UTF-8 at all. `LAND_PR_NO_UTF8_CTYPE=1` simulates exactly that by skipping the
# probe, so LC_ALL=C survives and the `else` arm runs for real.
#
# ⚠ NO NON-ASCII IN THESE PAYLOADS. Under a genuine C ctype `\b` widens and
# `präfixes SAD-7` really does read as a closing anchor — that is the documented
# residual on such a box, not something these rows should accidentally re-assert.
# What they pin is that the pure-ASCII filters (link-ref strip, entity decode)
# still run there, which is the half that was silently deletable.
sad_case_c_arm() { # $1 = label, $2 = expected, $3 = title, $4 = body
  local got
  got="$(LC_ALL=C LAND_PR_TEST=1 LAND_PR_NO_UTF8_CTYPE=1 LAND_PR_SADTEST=1 \
         tools/dev/land-pr.sh 0 <<<"$3
$4")"
  [ "$got" = "$2" ] \
    && echo "PASS  $1" \
    || { echo "FAIL  $1 — expected '$2', got '$got'"; fail=1; }
}
# The seam has to actually change the branch, or every row below is vacuous. This
# payload answers DIFFERENTLY per arm: a literal NBSP is normalized to a space by
# the multibyte sed (UTF-8 arm -> `anchor`) and is left alone without it (C arm ->
# no anchor -> `fallback`). Asserting the C-arm answer here is the discriminator.
# (The `hidden` half is the same on both arms — a literal NBSP is a non-ASCII
# byte adjacent to the id, so the positional clause fires either way. The
# PROVENANCE is what differs, and that is the discriminator.)
sad_case_c_arm "the seam really selects the C arm (a literal NBSP is NOT normalized there)" \
  "fallback SAD-999 hidden" "t" "$(printf 'Background: relates to SAD-999.\n\nFixes\xc2\xa0SAD-538\n')"
# …and the seam must be INERT on a real run: without LAND_PR_TEST=1 the flag is
# ignored and the strong path runs, so forgetting the gate cannot weaken a landing.
_carm_inert="$(LC_ALL=C LAND_PR_TEST=1 LAND_PR_SADTEST=1 tools/dev/land-pr.sh 0 <<<"t
$(printf 'Background: relates to SAD-999.\n\nFixes\xc2\xa0SAD-538\n')")"
if [ "$_carm_inert" = "anchor SAD-538 hidden" ]; then
  echo "PASS  LAND_PR_NO_UTF8_CTYPE is ignored when it is not set — the strong arm still runs"
else
  echo "FAIL  the UTF-8 arm no longer normalizes a literal NBSP (got '$_carm_inert') — either the pin regressed or the C-arm seam is leaking into ordinary runs"; fail=1
fi
# THE ROWS BARB'S MUTATION MUST BREAK. Without `_sad_decode_entities` the first
# resolves `fallback SAD-999`; without `_sad_strip_linkrefs` the second resolves
# `anchor SAD-999 SAD-538`. Both verified RED against that exact mutation.
sad_case_c_arm "&nbsp; is decoded on a box with no C.UTF-8 at all" \
  "anchor SAD-538 hidden" "t" \
  "$(printf 'Background: relates to SAD-999.\n\nFixes&nbsp;SAD-538\n')"
sad_case_c_arm "a link-ref definition is stripped there too" \
  "anchor SAD-538 hidden" "t" \
  "$(printf '[//]: # (Closes SAD-999)\nFixes SAD-538\n')"
sad_case_c_arm "…and a ZWSP character reference is deleted there too" \
  "anchor SAD-538 hidden" "t" "$(printf 'Fixes SAD-5&#8203;38\n')"
sad_case_c_arm "…and a U+3000 reference becomes a space there too" \
  "anchor SAD-538 hidden" "t" \
  "$(printf 'Background: relates to SAD-999.\n\nFixes&#12288;SAD-538\n')"

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

# ---------- SAD-589: the PR body is UNTRUSTED input to the funnel ----------
# Anyone who can open a PR controls the title/body, and the raw bytes carry text
# that is INVISIBLE in GitHub's rendered view. Each case below steered the
# close-out to the WRONG issue with `anchor` provenance — the high-confidence
# label that prints WITHOUT the VERIFY warning.
# NOTE the leading `t\n`: line 1 of this seam's stdin is the TITLE and
# resolve_sad reads the BODY FIRST, so a fixture that puts the payload on line 1
# never reaches the code path under test. Both rows below caught that mistake by
# passing against origin/main until the title was separated out.
sad_raw_case "HTML-comment anchor does not outrank the visible one" "anchor SAD-538 hidden" \
  't\n<!-- Fixes SAD-666 -->\nBackground: relates to SAD-500.\n\nFixes SAD-538'
sad_raw_case "an HTML-comment anchor alone resolves to none, not to itself" "none hidden" \
  't\n<!-- Fixes SAD-666 -->\nno visible anchor here'
# A comment spanning LINES: grep is line-oriented, so `Fixes\nSAD-666` never
# matched as an anchor even before this change — the row pins that the
# whole-text comment strip did not CREATE a match by joining the two halves.
sad_raw_case "HTML comment spanning LINES is still removed" "anchor SAD-538" \
  't\n<!-- Fixes\nSAD-666\n-->\nFixes SAD-538'
# A zero-width space inside the id used to truncate it to SAD-5.
sad_raw_case "zero-width space inside the id does not split it" "anchor SAD-538 hidden" \
  't\nFixes SAD-5\xe2\x80\x8b38'
# ...and one placed so it DESTROYS the anchor handed the win to a decoy.
sad_raw_case "zero-width space cannot destroy the anchor for a decoy" "anchor SAD-538 hidden" \
  't\nBackground: relates to SAD-999.\n\nFixes SAD-\xe2\x80\x8b538'
sad_raw_case "bidi override in the id is stripped" "anchor SAD-538 hidden" \
  't\nFixes SAD-5\xe2\x80\xae38'
sad_raw_case "word joiner in the keyword is stripped" "anchor SAD-538 hidden" \
  't\nFi\xe2\x81\xa0xes SAD-538'
# Specificity: ordinary text with no hidden characters must be untouched.
sad_raw_case "a plain body is unchanged by the filter" "anchor SAD-538" \
  'fix: something\nBackground: relates to SAD-500.\n\nFixes SAD-538'
sad_raw_case "a lone < or --> in prose is not a comment" "anchor SAD-538" \
  't\nuse a --> arrow and x < y here\nFixes SAD-538'

# ---------- SAD-589 round 2: the review found the first cut was an ALLOWLIST ----------
# Every row below resolved to the WRONG issue with `anchor` provenance and NO
# hidden flag against the first cut — i.e. the VERIFY warning suppressed, which
# is precisely the steerable state.
#
# `--->` (three dashes): the old regex could not match it, but markdown-it in
# commonmark mode emits it as raw HTML so the browser ends the comment at the
# first `-->` and the text is invisible in the rendered PR (Watson).
sad_raw_case "comment closed with ---> is still removed" "anchor SAD-538 hidden" \
  't\n<!-- Fixes SAD-666 --->\nFixes SAD-538'
sad_raw_case "comment closed with -----> is still removed" "anchor SAD-538 hidden" \
  't\n<!-- Fixes SAD-666 ----->\nFixes SAD-538'
# UNTERMINATED `<!--`: per CommonMark everything to EOF is raw HTML, so it is
# invisible. Needs no exotic codepoints — a missing `-->` reads as a typo (Barb).
sad_raw_case "unterminated comment hides everything after it" "none hidden" \
  't\nReal summary the reviewer reads.\n\n<!--\nFixes SAD-666\n'
# `--!>` is an HTML5 comment end, so text AFTER it renders and must be KEPT —
# swallowing it would drop a visible anchor, the dangerous direction (Barb).
sad_raw_case "--!> terminates the comment; text after it is kept" "anchor SAD-999" \
  't\n<!-- decoy --!> Fixes SAD-999\n'
# Codepoints OUTSIDE the original 19-entry list — the allowlist shape the commit
# message itself calls wrong. The positional non-ASCII check is what catches them.
sad_raw_case "U+2062 INVISIBLE TIMES in the id is stripped AND flagged" "anchor SAD-538 hidden" \
  't\nFixes SAD-5\xe2\x81\xa238'
sad_raw_case "U+3164 HANGUL FILLER in the id is stripped AND flagged" "anchor SAD-538 hidden" \
  't\nFixes SAD-5\xe3\x85\xa438'
sad_raw_case "U+034F COMBINING GRAPHEME JOINER in the id is stripped AND flagged" "anchor SAD-538 hidden" \
  't\nFixes SAD-5\xcd\x8f38'
# NBSP between keyword and id: [[:space:]] does not include it under C.UTF-8, so
# the anchor was dropped and an author-chosen decoy won via `fallback`.
sad_raw_case "NBSP between keyword and id still resolves the anchor" "anchor SAD-538 hidden" \
  't\nBackground: relates to SAD-999.\n\nFixes\xc2\xa0SAD-538'
sad_raw_case "narrow NBSP between keyword and id still resolves" "anchor SAD-538 hidden" \
  't\nBackground: relates to SAD-999.\n\nFixes\xe2\x80\xafSAD-538'
# ALARM FATIGUE (Barb): the repo's own PR template ships three comment blocks, so
# a raw-vs-filtered TEXT comparison flagged every ordinary PR — making a genuinely
# steered one indistinguishable. The trigger is a CHANGED ANCHOR SET, not "the
# filter removed something".
sad_raw_case "inert comments do NOT raise the hidden flag" "anchor SAD-538" \
  't\n<!-- Describe your change -->\nSome prose.\n<!-- checklist -->\n\nFixes SAD-538'
sad_raw_case "a comment naming the SAME issue does not flag" "anchor SAD-538" \
  't\n<!-- Fixes SAD-538 -->\nFixes SAD-538'
# The non-ASCII check is POSITIONAL — adjacent to a SAD-N token — so ordinary
# non-ASCII prose (em-dashes, accents, the ⚠ this repo's bodies are full of)
# must not flag. Without the positional scoping this would fire on nearly every
# PR body here, which is the alarm-fatigue failure again.
sad_raw_case "non-ASCII PROSE elsewhere does not flag" "anchor SAD-538" \
  'fix: pr\xc3\xa4fixes and \xe2\x80\x94 dashes\n\xe2\x9a\xa0 a warning sign\n\nFixes SAD-538'
# ⚠ These two PIN the `[:space:]` in the positional class. Without them
# `[^ -~[:space:]]` could be narrowed back to `[^ -~]` tomorrow and all 110
# assertions would stay green — and that narrowing flags EVERY web-authored PR,
# because GitHub returns those bodies as CRLF so a \r sits adjacent to the
# anchor. Verified discriminating: RED on df8e0afe, GREEN here (Watson).
sad_raw_case "a CRLF body does not raise the hidden flag" "anchor SAD-538" \
  't\nBackground.\r\n\r\nFixes SAD-538\r'
sad_raw_case "a TAB after the id does not raise the hidden flag" "anchor SAD-538" \
  't\nFixes SAD-538\t'

# ---------- SAD-655: four more shapes that reached the SILENT wrong-issue state ----------
# Every row in this block resolved to an author-chosen decoy — or dropped a
# reviewer-visible anchor — against origin/main (11a80e2c), and did it WITHOUT
# the hidden flag, i.e. with the VERIFY warning suppressed. Measured old->new is
# recorded per row so a future narrowing cannot be mistaken for a no-op.
#
# ITEM 1 — the FILTER destroys the anchor. U+2800 BRAILLE PATTERN BLANK, U+115F,
# U+1160, U+3164 and U+FFA0 all RENDER AS A BLANK but sit in _SAD_CF, which
# DELETES: between keyword and id the deletion GLUES them (`Fixes⠀SAD-538` ->
# `FixesSAD-538`), so the anchor never forms in EITHER text and the anchor-set
# diff sees nothing to compare. The positional check missed it because it only
# scanned RIGHT of `SAD-`. (old: `fallback SAD-999`, no flag)
sad_raw_case "a blank-rendering filler between keyword and id is FLAGGED (U+2800)" \
  "fallback SAD-999 hidden" \
  't\nBackground: relates to SAD-999.\n\nFixes\xe2\xa0\x80SAD-538'
sad_raw_case "…and U+115F HANGUL CHOSEONG FILLER, the same shape" \
  "fallback SAD-999 hidden" \
  't\nBackground: relates to SAD-999.\n\nFixes\xe1\x85\x9fSAD-538'
# ⚠ THE ROW THAT FORBIDS THE OBVIOUS-BUT-WRONG FIX. Moving those five codepoints
# to _SAD_ZS (normalize to a space) fixes the two rows above and REGRESSES this
# one to `anchor SAD-5` — the same silent wrong-issue write from the other end.
# Keep both directions pinned or the next author trades one for the other.
sad_raw_case "the same filler INSIDE the id must still be DELETED, not spaced" \
  "anchor SAD-538 hidden" 't\nFixes SAD-5\xe2\xa0\x8038'

# ITEM 2 — markdown LINK-REFERENCE DEFINITIONS. `[//]: # (…)` is the canonical
# markdown-comment idiom: it renders NOTHING, contains no `<!--`, and carries no
# non-ASCII byte, so all three of the original triggers were blind to it and the
# decoy won with `anchor` provenance. Barb verified the rendering against
# GitHub's own POST /markdown. (old: `anchor SAD-999 SAD-538` / `anchor SAD-999`)
sad_raw_case "a link-reference definition is not a visible anchor" "anchor SAD-538 hidden" \
  't\n[//]: # (Closes SAD-999)\nFixes SAD-538'
sad_raw_case "a link-ref definition ALONE resolves to none, not to itself" "none hidden" \
  't\n[//]: # (Closes SAD-999)\nno visible anchor here'
# The other half of the same steer: a whitespace HTML ENTITY is literal text to
# `[[:space:]]` but renders as a space, so it destroys the VISIBLE anchor and
# hands the win to `fallback`. (old: `fallback SAD-999`)
sad_raw_case "&nbsp; between keyword and id still resolves the anchor" "anchor SAD-538 hidden" \
  't\nBackground: relates to SAD-999.\n\nFixes&nbsp;SAD-538'
sad_raw_case "…and its numeric-hex spelling &#xA0;" "anchor SAD-538 hidden" \
  't\nBackground: relates to SAD-999.\n\nFixes&#xA0;SAD-538'
# ⚠ THE SAME TWO PAYLOADS UNDER AN INHERITED LC_ALL=C. What these pin is that the
# LC_CTYPE pin holds for the SAD-655 filters too — the same property the
# `präfixes` row pins for `\b`. They do NOT reach `_sad_visible`'s `else` arm:
# on a box that HAS C.UTF-8 the pin applies and the UTF-8 arm runs regardless of
# the caller's locale. That arm needs the LAND_PR_NO_UTF8_CTYPE seam and has its
# own block above; the distinction is load-bearing and cost this suite a round.
sad_case_hostile "&nbsp; is decoded under an inherited LC_ALL=C" \
  "anchor SAD-538 hidden" "t" \
  "$(printf 'Background: relates to SAD-999.\n\nFixes&nbsp;SAD-538\n')"
sad_case_hostile "a link-ref definition is stripped under an inherited LC_ALL=C" \
  "anchor SAD-538 hidden" "t" \
  "$(printf '[//]: # (Closes SAD-999)\nFixes SAD-538\n')"

# ---------- SAD-655 item 2b: NUMERIC character references (Watson CRITICAL) ----------
# The entity list above was HAND-WRITTEN, so it covered four `_SAD_ZS` codepoints
# and ZERO `_SAD_CF` ones — and the comment beside it asserted that `&#8203;` and
# friends "belong to the `_SAD_CF` half" when no half decoded them at all. Every
# row here was measured against GitHub's own `POST /markdown`: the reviewer reads
# `SAD-538` / `Fixes SAD-538`, and the resolver named a decoy or truncated the id
# with NO flag. Both spellings, decimal and hex, because an attacker picks.
# The numeric alternations are now GENERATED from `_SAD_CF_CP` / `_SAD_ZS_CP`, so
# these rows are also the pin on that generation: hand-listing cannot pass them
# all without reproducing it.
#
# ⚠ THE TWO SETS ANSWER DIFFERENTLY, and that is the point of pinning both. A
# `_SAD_CF` spelling is DELETED — inside an id that re-forms it (`SAD-5<ZWSP>38`
# -> `SAD-538`), between keyword and id it GLUES them (no anchor at all, which is
# SAD-655 item 1 reached through an entity). A `_SAD_ZS` spelling becomes a
# SPACE, which is what makes `Fixes&#12288;SAD-538` an anchor. Swapping a
# codepoint between the two lists changes these answers in opposite directions.
sad_raw_case "a decimal ZWSP reference inside an id is deleted, not kept" \
  "anchor SAD-538 hidden" 't\nFixes SAD-5&#8203;38'
sad_raw_case "…and its hex spelling &#x200B;" \
  "anchor SAD-538 hidden" 't\nFixes SAD-5&#x200B;38'
sad_raw_case "…and a BOM reference &#65279;, which no hand-written list had" \
  "anchor SAD-538 hidden" 't\nFixes SAD-5&#65279;38'
sad_raw_case "a named ZeroWidthSpace reference is decoded too" \
  "anchor SAD-538 hidden" 't\nFixes SAD-5&ZeroWidthSpace;38'
# _SAD_CF between keyword and id: deletion GLUES, so there is no anchor — the
# answer is `fallback`, and what this row pins is that it is FLAGGED. Identical
# to the literal `Fixes⠀SAD-538` row above, which is the property that matters:
# an entity spelling must not be quieter than the character it spells.
sad_raw_case "a U+2800 reference glues keyword to id — and is FLAGGED" \
  "fallback SAD-999 hidden" 't\nBackground: relates to SAD-999.\n\nFixes&#10240;SAD-538'
# _SAD_ZS between keyword and id: renders as a space, so the anchor stands.
# Twelve of the sixteen _SAD_ZS codepoints had no entity spelling; these four
# were all in that gap.
sad_raw_case "a U+3000 reference renders as a space, so the anchor resolves" \
  "anchor SAD-538 hidden" 't\nBackground: relates to SAD-999.\n\nFixes&#12288;SAD-538'
sad_raw_case "…U+205F, in hex" \
  "anchor SAD-538 hidden" 't\nBackground: relates to SAD-999.\n\nFixes&#x205F;SAD-538'
sad_raw_case "…U+1680 OGHAM SPACE MARK" \
  "anchor SAD-538 hidden" 't\nBackground: relates to SAD-999.\n\nFixes&#5760;SAD-538'
# ⚠ THE OVER-DECODE CONTROLS, and they are the reason the VISIBLE decoder stays
# an allowlist while the hidden-comparison decoder does not. Decoding a reference
# GitHub does not render as blank or space would MANUFACTURE an anchor the
# reviewer cannot see — the write this whole filter exists to prevent. These stay
# literal text, and the em-dash row also proves the codepoint-decoding used for
# the `hidden` comparison does not turn ordinary prose into an alarm.
sad_raw_case "an em-dash reference is NOT whitespace and does not flag" \
  "anchor SAD-538" 't\nSee &#8212; the notes.\n\nFixes SAD-538'
sad_raw_case "a printable-ASCII reference is not decoded into an id" \
  "anchor SAD-538" 't\nFixes SAD-538 &#65;'
sad_raw_case "a malformed reference is left verbatim, not guessed at" \
  "anchor SAD-5" 't\nFixes SAD-5&#;38'

# ---- ASCII WHITESPACE references: `&#10;` split the record (Barb HIGH-2) ----
# ⚠ THE SETS COVERED UNICODE ONLY, so ASCII whitespace references fell outside
# both. `&#32;`, `&#9;` and `&#13;` were caught anyway — they decode into `_raw`
# and read as `[[:space:]]` there — but `&#10;` decodes to a real LF, which
# SPLITS THE RECORD, and every `sad_hidden` clause is line-oriented `grep`. So
# neither text carried an anchor, all four clauses saw agreement, and a decoy won
# in SILENCE. GitHub renders `Fixes&#10;SAD-538` as `<p>Fixes\nSAD-538</p>` —
# the reviewer reads `Fixes SAD-538`. Verified against POST /markdown.
#
# TWO INDEPENDENT HALVES, and each is RED-checkable on its own: the codepoints
# are in the entity allowlist (fixes the VISIBLE text), and the codepoint decoder
# folds a decoded CR/LF to a space (makes the HIDDEN comparison newline-blind, so
# the next record-breaking codepoint cannot reopen the same hole).
sad_raw_case "a decimal LF reference does not split the record" \
  "anchor SAD-538" 't\nBackground: relates to SAD-999.\n\nFixes&#10;SAD-538'
sad_raw_case "…zero-padded" \
  "anchor SAD-538" 't\nBackground: relates to SAD-999.\n\nFixes&#010;SAD-538'
sad_raw_case "…in hex" \
  "anchor SAD-538" 't\nBackground: relates to SAD-999.\n\nFixes&#x0A;SAD-538'
sad_raw_case "…in upper-case hex" \
  "anchor SAD-538" 't\nBackground: relates to SAD-999.\n\nFixes&#XA;SAD-538'
sad_raw_case "…and a CR reference, the other record terminator" \
  "anchor SAD-538" 't\nBackground: relates to SAD-999.\n\nFixes&#13;SAD-538'
sad_raw_case "a plain-space reference resolves with no flag — nothing is hidden" \
  "anchor SAD-538" 't\nBackground: relates to SAD-999.\n\nFixes&#32;SAD-538'
# A TAB reference resolves correctly but IS flagged: `_del` strips a tab along
# with every other non-`[ -~]` byte, so the anchor sets disagree. Loud and
# correct — recorded so the asymmetry with the space row is not read as a bug.
sad_raw_case "…and a tab reference resolves, flagged by the non-ASCII strip" \
  "anchor SAD-538 hidden" 't\nBackground: relates to SAD-999.\n\nFixes&#9;SAD-538'
# ⚠ U+000C IS CLASSIFIED AS DELETE, AND THE REASON IS CONSERVATISM — NOT GLUING.
# An earlier revision of this comment claimed GitHub renders `Fixes&#12;SAD-538`
# as `FixesSAD-538`, glued. That was a MISREADING OF A TERMINAL: `POST /markdown`
# emits `<p>Fixes\x0cSAD-538</p>` — the FF byte is present, exactly as the space
# and tab cases emit 0x20 and 0x09 — and the terminal swallowed it on display.
# What a reviewer sees is decided by the BROWSER, not the markdown renderer, and
# CSS Text does not treat form feed as collapsible white space: Chrome 151
# measures the run at 101.33px against 96.02px glued and 100.02px for a real
# space, i.e. a VISIBLE control glyph ~5.3px wide (Barb LOW, PR #547).
#
# So neither classification is "what renders" — it is a judgement call between
# two LOUD outcomes, and both raise `sad_hidden`:
#   delete (this) -> `fallback SAD-999 hidden` — refuses to read an exotic glyph
#                    as a word separator, so the close-out names nothing on its
#                    own authority and the operator is told to verify.
#   space         -> `anchor SAD-538 hidden`  — names the visible id.
# Delete is kept as the conservative direction. The glyph is font-dependent and
# was cross-checked in one browser only, so this row pins the BEHAVIOUR
# (`fallback SAD-999 hidden`), never the prose above it: re-measuring the glyph
# cannot make the row pass while the classification silently changes.
sad_raw_case "a FORM FEED reference is not read as a separator — and is flagged" \
  "fallback SAD-999 hidden" 't\nBackground: relates to SAD-999.\n\nFixes&#12;SAD-538'
sad_case_c_arm "an LF reference is decoded on a box with no C.UTF-8 either" \
  "anchor SAD-538" "t" \
  "$(printf 'Background: relates to SAD-999.\n\nFixes&#10;SAD-538\n')"
# Both halves under an inherited LC_ALL=C. The `else`-arm versions of these live
# in the `sad_case_c_arm` block above — see the ⚠ there for why the two are not
# the same test.
sad_case_hostile "a ZWSP reference is deleted under an inherited LC_ALL=C" \
  "anchor SAD-538 hidden" "t" "$(printf 'Fixes SAD-5&#8203;38\n')"
sad_case_hostile "a U+3000 reference becomes a space under an inherited LC_ALL=C" \
  "anchor SAD-538 hidden" "t" \
  "$(printf 'Background: relates to SAD-999.\n\nFixes&#12288;SAD-538\n')"
# ⚠ SPECIFICITY, and the reason the strip is bounded at THREE leading spaces:
# four or more make it an indented CODE BLOCK, which RENDERS — stripping it would
# hide text the reviewer can see, the false-negative direction. Characterization
# against origin/main (both forms agree today).
#
# ⚠ THIS ROW ALONE DOES NOT PIN THE PROPERTY ITS LABEL CLAIMS. It passed against
# the first cut of the strip — `grep -vE '^[[:space:]]{0,3}\[[^]]*\][[:space:]]*:'`
# — because four SPACES exceed the bound. `[[:space:]]` also accepts ONE TAB,
# which is four COLUMNS and therefore the same code block, and the row below is
# the one that says so. Barb, PR #547. The three rows that follow are the
# measured over-strips: each rendered `[ref]: Fixes SAD-538` VISIBLY through
# GitHub's `POST /markdown`, and each resolved `fallback SAD-999 hidden` against
# the first cut — the reviewer-visible anchor deleted and an author-chosen decoy
# in its place. RED-checked individually against that pattern.
sad_raw_case "a 4-space-indented definition is a CODE BLOCK and is kept" \
  "anchor SAD-999 SAD-538" 't\n    [//]: # (Closes SAD-999)\nFixes SAD-538'
# (old: `fallback SAD-999 hidden`) A TAB is four columns — the SAME code block —
# so only literal SPACES may count toward the 0-3 bound.
sad_raw_case "a TAB-indented definition is a CODE BLOCK too, and is kept" \
  "anchor SAD-538" 't\nBackground: relates to SAD-999.\n\n\t[ref]: Fixes SAD-538'
# (old: `fallback SAD-999 hidden`) CommonMark: a link reference definition cannot
# INTERRUPT A PARAGRAPH. After paragraph text this is continuation text and
# renders inside the <p>.
sad_raw_case "a definition shape cannot interrupt a paragraph — it is kept" \
  "anchor SAD-538" 't\nBackground: relates to SAD-999.\n\nNote:\n[ref]: Fixes SAD-538'
# (old: `fallback SAD-999 hidden`) Inside a fence nothing is a leaf block; the
# content renders verbatim in a <pre><code>.
sad_raw_case "a definition shape inside a FENCED block is kept" \
  "anchor SAD-538" 't\nBackground: relates to SAD-999.\n\n```\n[ref]: Fixes SAD-538\n```'
# ⚠ THE TILDE ROW HAS TO CARRY THE BLANK LINE TOO. Labelled "which the backtick
# check alone misses", the plain version does not: removing the `~~~` arm of the
# fence-open test leaves it GREEN, because the tilde line then reads as paragraph
# text and sets the same `can_def = 0`. Only the blank-line-inside form
# discriminates — same lesson as the backtick row above, one delimiter over.
# (Watson delta, PR #547; measured RED against that mutation.)
sad_raw_case "…and a blank line inside a TILDE fence, which the backtick check alone misses" \
  "anchor SAD-999 SAD-538" 't\nIntro\n\n~~~\nlisting\n\n[//]: # (Closes SAD-999)\n~~~\n\nFixes SAD-538'
# ⚠ THE ROW THAT ACTUALLY PINS FENCE TRACKING, and the two above do not. Deleting
# the fence branch entirely leaves both of them GREEN — the fence line then reads
# as paragraph text, which sets the same `can_def = 0` and keeps the next line for
# the wrong reason. A BLANK LINE INSIDE the fence is what separates the two
# models: to the paragraph rule it re-opens a block boundary, to a fence tracker
# it is ordinary fenced content.
#
# ⚠⚠ AND THE FENCED CONTENT MUST BE A **VALID** DEFINITION. An earlier revision of
# this row used `[ref]: Fixes SAD-538`, which the tail check now keeps ANYWAY as
# an invalid definition — so the row went green against the fence deletion it
# exists to catch. A fix in one rule silently hollowed out the pin on another;
# only re-running the mutation caught it. `[//]: # (…)` is a real definition, so
# nothing but fence tracking can keep it.
sad_raw_case "a blank line INSIDE a fence does not re-open a definition boundary" \
  "anchor SAD-999 SAD-538" 't\nIntro\n\n```\nlisting\n\n[//]: # (Closes SAD-999)\n```\n\nFixes SAD-538'
# ---- GFM FOOTNOTES: renders only when the label is actually REFERENCED ----
# ⚠ THE CARET EXCLUSION WAS A ONE-LINE FIX THAT OPENED A SILENT HOLE, and this
# block is both halves of the correction. "A footnote renders" holds ONLY when a
# matching `[^label]` reference exists somewhere in the document; GitHub drops an
# ORPHAN definition entirely. Keeping orphans made their `SAD-N` a live anchor in
# the visible text while the reviewer saw nothing — pure ASCII, identical in
# `_raw`, so all four `sad_hidden` clauses stayed silent. That is the SILENT
# wrong-issue write, reintroduced by the fix for the loud one (Barb HIGH-1).
# Every expectation below verified against GitHub's `POST /markdown`.
sad_raw_case "a REFERENCED footnote definition renders, so it is kept" \
  "anchor SAD-538 SAD-999" 't\nFixes SAD-538 [^1]\n\n[^1]: Closes SAD-999'
sad_raw_case "…and the reference may come AFTER the definition" \
  "anchor SAD-999 SAD-538" 't\n[^1]: Closes SAD-999\n\nFixes SAD-538 [^1]'
sad_raw_case "…and the label need not be numeric" \
  "anchor SAD-538 SAD-999" 't\nFixes SAD-538 [^note]\n\n[^note]: Closes SAD-999'
# THE ORPHANS. GitHub renders neither; keeping them is the silent direction.
sad_raw_case "an ORPHAN footnote definition is dropped, like GitHub drops it" \
  "anchor SAD-538 hidden" 't\nFixes SAD-538\n\n[^1]: Closes SAD-999'
sad_raw_case "…and an orphan that is the ONLY anchor resolves to none, not to itself" \
  "none hidden" 't\nSome description.\n\n[^1]: Closes SAD-999'
# ⚠ A reference inside a CODE SPAN does not make the definition render — verified
# against POST /markdown. This is also the row that pins the ambiguity rule: when
# the filter cannot be sure a reference is live it DROPS, because an over-strip is
# loud (`fallback` + `hidden`) and an under-strip is silent.
sad_raw_case "a reference that exists only inside a code span does not revive it" \
  "anchor SAD-538 hidden" 't\nFixes SAD-538 `[^1]`\n\n[^1]: Closes SAD-999'
# The OTHER direction, so the paragraph rule cannot be over-applied into a
# blanket "only after a blank line": both of these ARE hidden definitions and
# must still drop. Consecutive definitions are all definitions (CommonMark), and
# an ATX heading is a leaf block a definition may follow with no blank line — the
# cheapest way to smuggle one past a naive blank-line-only rule.
sad_raw_case "a definition still drops directly after an ATX heading" \
  "anchor SAD-538 hidden" 't\n# Heading\n[//]: # (Closes SAD-999)\n\nFixes SAD-538'
sad_raw_case "consecutive definitions all drop, not just the first" \
  "anchor SAD-538 hidden" 't\n\n[a]: /u\n[//]: # (Closes SAD-999)\n\nFixes SAD-538'
sad_raw_case "…and directly after a thematic break" \
  "anchor SAD-538 hidden" 't\n\n---\n[//]: # (Closes SAD-999)\n\nFixes SAD-538'
# An indented code block ENDS at the first non-indented line, and that line may be
# a definition — so `can_def` has to survive the code block rather than being
# cleared by it like paragraph text.
sad_raw_case "…and on the line that ENDS an indented code block" \
  "anchor SAD-538 hidden" 't\n\n    listing\n[//]: # (Closes SAD-999)\n\nFixes SAD-538'
sad_raw_case "an ordinary inline markdown link is NOT a link-ref definition" \
  "anchor SAD-538" 't\n[see the docs](https://example.invalid/a)\nFixes SAD-538'
# ---- the TAIL must be a valid destination (+ optional title), or it RENDERS ----
# ⚠ CommonMark: after the destination NO further character may appear unless it
# is a valid title. `[ref]: Fixes SAD-538` therefore has destination `Fixes` and
# an unquoted trailer — not a definition, and GitHub renders it as
# `<p>[ref]: Fixes SAD-538</p>`. Dropping the whole `[label]:` SHAPE deleted a
# reviewer-visible anchor and named the decoy instead (Watson delta, PR #547;
# measured `fallback SAD-999 hidden` against the previous head, `anchor SAD-538`
# on origin/main — so this was a regression THIS PR introduced, not inherited).
sad_raw_case "an invalid definition renders, so it is kept" \
  "anchor SAD-538" 't\nBackground: relates to SAD-999.\n\n[ref]: Fixes SAD-538'
# ⚠ THE TRAILER CARRIES A CLOSING KEYWORD ON PURPOSE. With inert junk
# (`[ref]: /url junk here`) this row does NOT discriminate: dropping the line
# removes no anchor, so it stays green against the very mutation it is here to
# catch. The trailer has to contain something the anchor set would lose.
sad_raw_case "…a destination followed by unquoted junk is invalid too" \
  "anchor SAD-777 SAD-538" 't\nBackground.\n\n[ref]: /url Closes SAD-777\n\nFixes SAD-538'
# The four VALID shapes must still drop, or the fix above becomes a blanket keep.
sad_raw_case "a bare destination is still a definition" \
  "anchor SAD-538" 't\nBackground.\n\n[a]: /u\n\nFixes SAD-538'
sad_raw_case "…a destination with a double-quoted title is too" \
  "anchor SAD-538 hidden" 't\nBackground: relates to SAD-999.\n\n[a]: /u "Closes SAD-777"\n\nFixes SAD-538'
sad_raw_case "…a single-quoted title" \
  "anchor SAD-538 hidden" "t\nBackground: relates to SAD-999.\n\n[a]: /u 'Closes SAD-777'\n\nFixes SAD-538"
sad_raw_case "…and an angle-bracketed destination with a paren title" \
  "anchor SAD-538 hidden" 't\nBackground: relates to SAD-999.\n\n[a]: <http://x/> (Closes SAD-777)\n\nFixes SAD-538'

# ITEM 3 — the positional check was ONE-SIDED. `SAD-[0123456789]*[^ -~[:space:]]`
# anchors on `SAD-` and scans forward only, so an invisible codepoint in the
# KEYWORD is neither stripped (U+FE00 is outside _SAD_CF) nor flagged.
# (old: `fallback SAD-999`, no flag)
sad_raw_case "an invisible codepoint INSIDE the keyword is flagged (U+FE00)" \
  "fallback SAD-999 hidden" \
  't\nBackground: relates to SAD-999.\n\nFi\xef\xb8\x80xes SAD-538'
# The symmetric half: a non-ASCII byte immediately LEFT of a SAD token.
# (old: `anchor SAD-538`, no flag)
sad_raw_case "a non-ASCII byte immediately LEFT of an id is flagged (symmetric)" \
  "anchor SAD-538 hidden" 't\nsee \xe2\x80\x8bSAD-999\n\nFixes SAD-538'

# ITEM 4 — `<!-->` and `<!--->` are COMPLETE comments per CommonMark 0.30+, but
# neither contains `-->` or `--!>`, so the awk read them as UNTERMINATED and
# stripped to EOF — swallowing a reviewer-visible anchor. Loud (the anchor-set
# diff still fired) but wrong, and wrong in the direction the `--!>` case exists
# to rule out. (old: `none hidden` / `none hidden` / `anchor SAD-538 hidden`)
sad_raw_case "<!--> is a complete comment; text after it is KEPT" "anchor SAD-538" \
  't\n<!-->\nFixes SAD-538'
sad_raw_case "<!---> is a complete comment; text after it is KEPT" "anchor SAD-538" \
  't\n<!--->\nFixes SAD-538'
sad_raw_case "text following <!--> renders, so its anchor counts" "anchor SAD-666 SAD-538" \
  't\n<!--> Fixes SAD-666 -->\nFixes SAD-538'
# Specificity: the four-dash empty comment is an ORDINARY paired comment and must
# keep being removed — characterization, green both sides.
sad_raw_case "<!----> is still an ordinary paired comment" "anchor SAD-538" \
  't\n<!---->\nFixes SAD-538'

# ---------- SAD-604 / SAD-628 / SAD-618 / SAD-630 / SAD-619 / SAD-647 ----------
# Tier pins for the paths that moved. Each is asserted under BOTH the config and
# the fallback, because the identity assertion above only proves they AGREE — it
# stays green if both regress together.
tier_pin() { # $1 = path, $2 = expected tier, $3 = why
  local got_c got_f
  got_c="$(printf '%s\n' "$1" | LAND_PR_TEST=1 LAND_PR_SELFTEST=1 tools/dev/land-pr.sh 0 | awk '{print $1}')"
  got_f="$(printf '%s\n' "$1" | LAND_PR_TEST=1 LAND_PR_SELFTEST=1 LAND_PR_CFG_OVERRIDE=/nonexistent tools/dev/land-pr.sh 0 2>/dev/null | awk '{print $1}')"
  if [ "$got_c" = "$2" ] && [ "$got_f" = "$2" ]; then
    echo "PASS  $1 -> $2 (config+fallback) — $3"
  else
    echo "FAIL  $1 expected $2, got config=$got_c fallback=$got_f — $3"; fail=1
  fi
}
tier_pin "tools/dev/test-land-pr.sh"      security "SAD-630: the suites are load-bearing merge gates"
tier_pin "tools/dev/test-hooks.sh"        security "SAD-630: the suites are load-bearing merge gates"
tier_pin "tools/dev/prune-worktrees.sh"   security "SAD-630: irreversible worktree removal"
tier_pin "tools/dev/golden-synth/restore-synth-golden.sh" security "SAD-630: destructive local tooling"
tier_pin "tools/dev/land-pr.sh"           security "the funnel itself (was an exact path, now the directory)"
# tools/** not tools/dev/** — these are the only pin on the binary distribute.yml
# runs with the Firebase service-account key (Barb, PR #458).
tier_pin "tools/ci/firebase/package.json"      security "SAD-647: pins the CLI run with the Firebase SA key"
tier_pin "tools/ci/firebase/package-lock.json" security "SAD-647: the integrity pin itself"
# gradlew is the LAUNCHER distribute.yml runs beside three live secrets.
tier_pin "gradlew"                        security "SAD-647: the build launcher, run with live secrets"
tier_pin "gradlew.bat"                    security "SAD-647: the build launcher, run with live secrets"
tier_pin ".claude/references/pm/workflow.md" security "SAD-619: it DEFINES the tier semantics"
tier_pin ".claude/references/pm/linear.md"   security "SAD-619: the PM operating manual"
# .claude/** wholesale — the six-entry allowlist reproduced SAD-546 one level up.
tier_pin ".claude/skills/foo/SKILL.md"    security "SAD-619: agent instructions, was docs"
tier_pin ".claude/statusline.sh"          security "SAD-619: a script Claude Code EXECUTES, was code"
tier_pin ".claude/output-styles/x.md"     security "SAD-619: a live load path, was docs"
tier_pin "app/src/main/java/com/enduranceloggr/app/nano/NanoStructurer.kt" security "SAD-647: Gemini key egress"
tier_pin "app/src/main/java/com/enduranceloggr/app/voice/Rec.kt"           security "SAD-647: R-PRIV-004 boundary"
tier_pin "app/src/main/java/com/enduranceloggr/app/map/MapPack.kt"         security "SAD-647: sha256 install trust"
tier_pin "app/src/main/java/com/enduranceloggr/app/ui/summary/CourseMapWeb.kt" security "SAD-647: embedded WebView"
# SAD-628 — a case variant of a gated directory must NOT launder into docs.
# ⚠ The case must vary in the FIRST path segment. Fixtures that varied only a
# SUB-directory (.claude/COMMANDS/, .claude/Hooks/) stopped discriminating once
# `.claude/**` widened the pattern to `^\.claude/` — that prefix matches them
# case-SENSITIVELY, so dropping `-i` from tier_of left the whole suite green and
# the pin proved nothing (Watson, PR #458 round 2). Verified: both rows below
# FAIL with `-i` dropped and PASS with it restored.
tier_pin ".Claude/COMMANDS/wipe-device.md" security "SAD-628: case-insensitive security matching"
tier_pin "Tools/dev/land-pr.sh"            security "SAD-628: case-insensitive security matching"
# NOT a case-insensitivity pin — `^\.claude/` matches this prefix case-SENSITIVELY.
# What it proves is that `.claude/**` covers subdirectories at all.
tier_pin ".claude/COMMANDS/wipe-device.md" security ".claude/** covers subdirectories"
# LOW-2: the fallback was root-anchored (^gradlew$) while the config glob is
# slash-less and therefore depth-agnostic — they diverged on a nested gradlew,
# undercutting the "byte-identical in effect" claim the malformed-JSON WARN rests on.
tier_pin "sub/gradlew"                     security "gradlew at depth — config/fallback must agree"
# Specificity — near-misses must NOT be pulled in by the widened patterns.
tier_pin "toolsx/dev/thing.sh"    code "the ^tools/ anchor still holds"
tier_pin ".claudex/references/a.md" docs "the ^.claude/ anchor still holds"
tier_pin "xgradlew"               code "the (^|/)gradlew$ anchor still holds"
tier_pin "app/src/main/java/com/enduranceloggr/app/nanox/Other.kt" code "the nano/ anchor still holds"
tier_pin "docs/requirements.md"   docs "an ordinary doc is still docs (docs stays case-SENSITIVE)"

# ---------- SAD-667: what EXECUTES on the self-hosted runner ----------
# .github/** widened from .github/workflows/**. The three rows below were `code`,
# `docs` and `code` respectively before this change.
tier_pin ".github/workflows/ci.yml"          security "the gated job itself (unchanged, pinned)"
tier_pin ".github/dependabot.yml"            security "SAD-667: steers what lands; was code"
tier_pin ".github/CODEOWNERS"                security "SAD-667: steers who must approve; latent"
# The template SEEDS EVERY PR BODY, and the body is what G8 parses for the
# `Fixes SAD-N` anchor — a hidden-steering payload here is SAD-589/SAD-655
# pre-seeded into every future PR. Left docsTierPatterns in the same change.
tier_pin ".github/pull_request_template.md"  security "SAD-667: seeds the body G8 parses; was docs"
# Latent, and gated BEFORE one exists — the two-step shape is PR #1 (code tier,
# no review) planting the definition, PR #2 (security) adding the one-line wiring.
tier_pin ".github/actions/setup/action.yml"  security "SAD-667: composite action, executes on the runner"
tier_pin "buildSrc/src/main/kotlin/Conv.kt"  security "SAD-667: build logic every ./gradlew runs"
# NOT a buildSrc/** pin — this is security via the pre-existing `**/*.gradle.kts`
# entry and stays green if buildSrc/** is reverted (Watson). Kept as defence in
# depth; the DISCRIMINATING buildSrc row is the .kt one above.
tier_pin "buildSrc/build.gradle.kts"         security "security via its own .gradle.kts entry, not buildSrc/**"
# ⚠ These two are NO LONGER discriminating for `**/*.gradle` (Watson, round 2).
# Once `gradle/**` landed they match `^gradle/` and stay green if the extension
# glob is reverted. Kept as defence in depth and disclosed rather than deleted,
# the same way buildSrc/build.gradle.kts is — a reason string that reads like a
# pin, on a row that is green by construction, is how the next reader miscounts
# the evidence. The rows that still discriminate `**/*.gradle` are the three
# below them.
tier_pin "gradle/custom.gradle"              security "green via gradle/**, not **/*.gradle — defence in depth"
tier_pin "gradle/sub/nested.gradle"          security "green via gradle/**, not **/*.gradle — defence in depth"
# ⚠ SAD-667 named `gradle/*.gradle`; THESE THREE are why it shipped as
# `**/*.gradle` — each escapes to code tier under the directory-scoped glob,
# which is the SAD-546 allowlist shape a fifth time.
tier_pin "custom.gradle"                     security "SAD-667: .gradle at the root too"
tier_pin "app/foo.gradle"                    security "SAD-667: .gradle anywhere, not just gradle/"
# The sharpest of the four (Barb): Gradle applies settings.gradle AUTOMATICALLY —
# no `apply from:` line has to exist anywhere for this one to execute.
tier_pin "settings.gradle"                   security "SAD-667: auto-applied by Gradle, no apply-from needed"
# Specificity — the widened anchors must not over-reach.
tier_pin ".githubx/thing.yml"     code "the ^.github/ anchor still holds"
tier_pin "buildSrcx/Conv.kt"      code "the ^buildSrc/ anchor still holds"
tier_pin "gradlex/thing.txt"      code "the ^gradle/ anchor still holds"
tier_pin "app/build.gradle.kts"   security "a .gradle.kts is security via its OWN entry, not \\.gradle$"
# ⚠ An earlier cut of this change pinned verification-metadata.xml as `code`
# ("inert checksums are not an executed script") and BOTH reviewers rejected it.
# It is Gradle's dependency-verification TRUST ANCHOR — the only pin on every
# plugin and annotation processor the build downloads and executes — i.e. exactly
# the argument land-pr.sh already makes for tools/ci/firebase/package-lock.json.
# An exact-path entry was rejected in turn because it leaves the sibling keyring
# open; hence `gradle/**`. Both files are latent, which is why they are gated now.
tier_pin "gradle/verification-metadata.xml"  security "SAD-667: the dependency-verification trust anchor"
tier_pin "gradle/verification-keyring.keys"  security "SAD-667: the sibling an exact-path entry would miss"

# SAD-618 — a parseable-but-wrong-SHAPED securityTierPatterns must FAIL CLOSED,
# not silently collapse the security tier. `jq -e` treats {} and [123] as truthy,
# so both took the config branch and produced valid-but-nonsense patterns.
shape_case() { # $1 = label, $2 = jq value for securityTierPatterns, $3 = expect die|fallback
  local cfgf out rc
  cfgf="$(mktemp)"
  jq --argjson v "$2" '.review.securityTierPatterns = $v' "$ROOT/.claude/workflow.config.json" > "$cfgf"
  out="$(printf '.claude/hooks/pre-bash-safety.sh\n' \
    | LAND_PR_TEST=1 LAND_PR_SELFTEST=1 LAND_PR_CFG_OVERRIDE="$cfgf" tools/dev/land-pr.sh 0 2>&1)"; rc=$?
  rm -f "$cfgf"
  if [ "$3" = "die" ]; then
    { [ "$rc" != "0" ] && ! grep -q '^code' <<<"$out"; } \
      && echo "PASS  $1 fails closed (rc=$rc)" \
      || { echo "FAIL  $1 must fail closed — rc=$rc out=$out"; fail=1; }
  else
    grep -q '^security' <<<"$out" \
      && echo "PASS  $1 still classifies security" \
      || { echo "FAIL  $1 — out=$out"; fail=1; }
  fi
}
shape_case "securityTierPatterns as an OBJECT"        '{"a":"b"}' die
shape_case "securityTierPatterns as numbers"          '[123]'     die
shape_case "securityTierPatterns with a non-string"   '[".claude/hooks/**", 7]' die
shape_case "securityTierPatterns as a bare string"    '"x"'       die
shape_case "securityTierPatterns absent (null)"       'null'      fallback
# ⚠ THE PROBE ITSELF MUST BE PINNED (Watson, PR #524 round 2). Deleting the two
# lines of the load-time `.github` probe (then bare `.github/`) from land-pr.sh left the
# suite at 135 PASS / 0 FAIL, exit 0 — nothing went red. The tier_pin rows pin
# the CLASSIFICATION, not the probe, and the minimal-array row below only asserts
# the config branch is reached, so removing a `die` can only make it greener.
# That is the "a new pin passes vacuously" hazard this file documents three times
# over, committed by the commit that added the pin. Verified discriminating: RED
# with the probe deleted, green with it restored.
shape_case "a valid array WITHOUT .github/ coverage still fails closed (the SAD-667 probe)" \
  '[".claude/hooks/**", ".claude/workflow.config.**", ".claude/commands/**"]' die
# A minimal-but-VALID array must still work. It has to carry the four entries
# land-pr's own load-time self-tests demand — the hooks dir, the gate config
# (self-protection), the commands dir (the SAD-628 case-fold probe) and, since
# SAD-667, `.github/` (the CI definitions that gate the repo) — otherwise it dies
# for a reason unrelated to shape, which is what this row would otherwise
# mis-attribute.
# ⚠ The `.github/workflows/**` entry is the NARROW form on purpose — it is what the
# upstream template ships, so this row pins the real contract (a stock adopter
# lands) instead of a shape no adopter has. It also pins the probe's PATH: with
# `.github/**` here, re-widening the probe back to the adopter-breaking bare
# `.github/` left the suite at 137/0 — the round-3 fix unpinned, one item over
# from the round-2 finding it closed (Watson). Now that re-widening reddens here.
# ⚠ This row is also the guard that keeps the load-time self-tests PORTABLE. The
# first cut of SAD-667's self-test also demanded buildSrc/ , **/*.gradle and
# gradle/ , and this row went red — correctly: land-pr.sh is bundle-managed and
# ships to repos that are not Gradle projects, so a fail-closed assertion about
# someone else's build system aborts their landings. Those three are pinned in
# the instance-specific tier_pin rows above instead. Keep this row minimal; if a
# future entry has to be added here, ask first whether the assertion demanding it
# belongs in a portable script at all.
shape_case "a valid minimal array still works" \
  '[".claude/hooks/**", ".claude/workflow.config.**", ".claude/commands/**", ".github/workflows/**"]' fallback

# ---------- SAD-646: codeTierPolicy gate semantics ----------
# The knob landed with NO committed assertions, so three regressions would have
# shipped green: a bogus value silently accepted, the absent-key default drifting
# off `reviewer`, and — the serious one — dropping the `tier == code` guard from
# the G4 elif, which would let a SECURITY-tier PR skip BOTH markers.
policy_case() { # $1 = label, $2 = jq value (or __ABSENT__), $3 = expect ok|die
  local cfgf rc
  cfgf="$(mktemp)"
  if [ "$2" = "__ABSENT__" ]; then
    jq 'del(.review.codeTierPolicy)' "$ROOT/.claude/workflow.config.json" > "$cfgf"
  else
    jq --argjson v "$2" '.review.codeTierPolicy = $v' "$ROOT/.claude/workflow.config.json" > "$cfgf"
  fi
  printf 'docs/x.md\n' | LAND_PR_TEST=1 LAND_PR_SELFTEST=1 LAND_PR_CFG_OVERRIDE="$cfgf" \
    tools/dev/land-pr.sh 0 >/dev/null 2>&1; rc=$?
  rm -f "$cfgf"
  if [ "$3" = "die" ]; then
    [ "$rc" != "0" ] && echo "PASS  $1 is refused (rc=$rc)" \
      || { echo "FAIL  $1 must be refused, got rc=$rc"; fail=1; }
  else
    [ "$rc" = "0" ] && echo "PASS  $1 accepted" \
      || { echo "FAIL  $1 must be accepted, got rc=$rc"; fail=1; }
  fi
}
policy_case "codeTierPolicy=ci-only"        '"ci-only"'   ok
policy_case "codeTierPolicy=reviewer"       '"reviewer"'  ok
policy_case "codeTierPolicy absent"         '__ABSENT__'  ok
policy_case "codeTierPolicy=bogus"          '"yolo"'      die
policy_case "codeTierPolicy=true (non-str)" 'true'        die
# The absent-key DEFAULT must be the fail-safe `reviewer`, not `ci-only`.
grep -qE "CODE_TIER_POLICY=\"\\\$\(cfg '\.review\.codeTierPolicy' 'reviewer'\)\"" "$ROOT/tools/dev/land-pr.sh" \
  && echo "PASS  the absent-key codeTierPolicy default is 'reviewer' (fail-safe)" \
  || { echo "FAIL  codeTierPolicy's absent-key default must be 'reviewer'"; fail=1; }
# STRUCTURAL pins for the G3 derivation. These guards live past the
# LAND_PR_SELFTEST exit, so no behavioural test can reach them — the same
# situation the G4 pins below address, and the reason they are grep-shaped.
# `[[:space:]]`, never `\s`, for BSD grep (macOS adopters).
#
# ⚠ THE THREE G3 PINS MATCH AGAINST AN EXTRACTED STATEMENT, not the whole file
# (the two `api_rows` pins below deliberately do not — they assert file-level
# facts, not a property of one statement)
# and not against a positional `grep -A` window. Two earlier pin sets failed here:
#   • matching the whole file let a COMMENT satisfy the pin. Proven: delete the
#     guard and replace it with `# The guard below used to read \`|| die 3 ...\`;
#     superseded by X` — this codebase's own idiom — and every pin stayed GREEN
#     with the derivation completely unguarded.
#   • `grep -A2` had zero headroom, so splitting the pipeline across one more
#     line (a normal reformat) went RED with a message claiming the guard was
#     gone while it sat one line below the window.
# ONE extraction feeds all three G3 pins. An earlier revision left TWO awks with
# divergent continuation rules — and the "validated against seven trees" prose
# stayed above the OLD one, where every RED claim in it was false: that pin is
# GREEN on `|| true`, on guard-removed-behind-a-comment, and on
# comment-in-continuation, because it only asserts the statement's OPENING line.
# Exactly the stale-prose hazard this file warns about (Watson, PR #458 final).
# The awk walks the statement's continuations (`\`, `|`, `||`, `&&`).
_g3_stmt="$(awk '
  /^files="\$\(set -o pipefail;/ {inblk=1; start=NR}
  inblk {print; s=$0; sub(/[[:space:]]+$/,"",s)
         if (s !~ /(\\|\|\||\||&&)$/) exit
         if (NR - start > 12) exit }
' "$ROOT/tools/dev/land-pr.sh")"
# ⚠ Distinguish "the extractor truncated" from "the guard is gone". Six of the
# seven legitimate continuation forms the awk does not cover (blank line after
# `||`, comment after `||`, die message wrapped inside its quotes, jq filter
# split, `|| { die ...; }`, `|&`) yield a statement that does not PARSE — so a
# syntax error means the awk rule needs updating, NOT that the guard vanished.
# Reporting those as "the guard is gone" is what got answered by narrowing a
# regex twice, which minted the next hole each time.
bash -n <<<"$_g3_stmt" 2>/dev/null \
  || { echo "FAIL  the G3 extractor truncated the statement — the awk continuation rule needs updating; the guard itself may be intact"; fail=1; }
grep -qE '^files="\$\(set -o pipefail;' <<<"$_g3_stmt" \
  && echo "PASS  G3 derives the path list under a subshell-local pipefail" \
  || { echo "FAIL  the G3 derivation lost its pipefail guard — a jq/sort death mid-pipe would leave a SHORT list, and a security PR whose only matching path was dropped classifies 'code' and lands with ZERO verdicts"; fail=1; }
# ⚠ THE PIN ABOVE IS THE DECORATIVE HALF. There is no `set -e` in land-pr.sh, so
# `pipefail` ALONE IS A NO-OP — it sets a status nobody reads. The load-bearing
# half is the `|| die` that ACTS on it. Asserts the guard EXISTS, deliberately not
# its message text: pinning the prose made a reworded die message read as a
# missing guard.
# ⚠ THIS PIN EXECUTES THE STATEMENT. It does not match text, and that is the
# whole point: FOUR successive text-matching versions of this one assertion each
# had a hole, every one produced by narrowing the previous regex.
#   r6  guard added, no pin at all
#   r7  pinned `pipefail` — a no-op without `set -e`
#   r8  pinned `|| die` via `grep -A2` — a COMMENT in the window satisfied it
#   r9  pinned `|| die` in a flattened extract — a SAME-LINE comment satisfied it,
#       and so did an adjacent statement supplying its own `)"`, and so did
#       `|| true` followed by a supersession comment quoting the old guard
# The guard lives past the LAND_PR_SELFTEST exit, which is why every attempt was
# structural. But the STATEMENT can be extracted and RUN with `jq`, `sort` and
# `die` stubbed — which tests the property that actually matters (does a mid-pipe
# failure reach `die`?) instead of a proxy for it.
#
# `die` must fire AND the statement must not survive: a `die` relocated inside the
# `$( )` prints the same text but exits only the subshell, so the marker alone is
# not sufficient — `_g3_res` must be empty too. That distinction is the PR-#160
# defect class, and it is why this checks both.
#
# Validated at this head across ELEVEN shapes. RED on: `|| true`; guard deleted;
# deleted + next-line comment; deleted + same-line comment; die moved inside the
# substitution; an adjacent statement supplying `)"`; `|| true` + a supersession
# comment. GREEN on: control; pipeline split across lines; collapsed to one line;
# trailing-OPERATOR style (which the previous pin false-REDDENED); reworded die
# message (deliberately not pinned — pinning prose is how these go false-RED).
#
# ⚠ It `eval`s a fragment of `land-pr.sh` inside the test process. That adds no
# trust boundary: this suite already EXECUTES `land-pr.sh` directly via
# LAND_PR_SELFTEST, so anyone who can edit the funnel has already won.
_g3_marker="$(mktemp)"
# ⚠ THE STUB EMITS A PARTIAL LIST BEFORE FAILING. `jq(){ return 137; }` failed
# SILENTLY, so `files` was always EMPTY when the pipe died — and the pin then
# could not tell "the status was checked" from "the result was empty", which is
# the exact distinction its own FAIL message is about. Five refactors that fold
# the emptiness backstop into this statement and drop the status guard were
# GREEN while UNGUARDED at runtime; two of them are simply "consolidate these
# two adjacent guards", which the backstop pin below invites (Watson, PR #458
# final). A real SIGKILLed jq emits what it had and then dies — model that.
_g3_res="$( jq(){ printf 'app/a.kt\n'; return 137; }; sort(){ cat; }; die(){ echo DIED >"$_g3_marker"; exit 9; }
            # `_rows` and `pr` are the eval'd statement's two inputs; the `:` makes
            # that visible to shellcheck, which cannot see through `eval`.
            _rows='{"filename":"a.txt"}'; pr=1; : "$_rows" "$pr"
            eval "$_g3_stmt" >/dev/null 2>&1; echo SURVIVED )"
if [ "$(cat "$_g3_marker")" = DIED ] && [ -z "$_g3_res" ]; then
  echo "PASS  the G3 derivation ACTS on the pipe status (executed: stubbed jq exits 137 -> die fires -> statement aborts)"
else
  echo "FAIL  the G3 derivation did not abort on a mid-pipe failure — died=$(cat "$_g3_marker" 2>/dev/null || echo no) survived=${_g3_res:-no} (or the statement grew a dependency this pin does not stub — it provides only jq/sort/die/_rows/pr). A jq/sort death mid-pipe would classify from a SHORT list: the dropped alphabetical tail is where tools/** and server/** sit, so a security PR classifies 'code' and lands with ZERO verdicts"; fail=1
fi
rm -f "$_g3_marker"
# ⚠ A TEXT PIN IS KEPT ALONGSIDE THE EXECUTED ONE, DELIBERATELY. They fail in
# OPPOSITE directions, and four rounds were spent replacing one with the other
# instead of composing them (Barb, PR #458 final):
#   a TEXT pin cannot be fooled by runtime behaviour, but can be fooled by a
#     comment (round 8: a same-line supersession comment satisfied it);
#   an EXECUTED pin is the reverse — it cannot be fooled by a comment, but is
#     only as good as its stubs (round 11: a stub that emitted no output could
#     not tell "status checked" from "result empty", so a guard keyed on
#     emptiness passed while the real defect walked through).
# Requiring BOTH is strictly stronger than either, and neither of the two known
# hole-classes survives the pair.
grep -qE '(^[[:space:]]*|\)"[[:space:]]*)\|\| die 3 ' <<<"$_g3_stmt" \
  && echo "PASS  the G3 derivation carries a '|| die' in its source text (text half of the paired pin)" \
  || { echo "FAIL  no '|| die' appears in the G3 derivation's source text — the executed pin may still pass if a guard was substituted, so this half is what catches a removed guard that leaves equivalent runtime behaviour"; fail=1; }
# The empty-list backstop is what makes a two-stage refactor fail CLOSED rather
# than open, and nothing asserted it existed (Barb, PR #458 final).
grep -qE '^\[ -n "\$files" \] \|\| die 3 ' "$ROOT/tools/dev/land-pr.sh" \
  && echo "PASS  the G3 empty-list backstop is present" \
  || { echo "FAIL  the G3 '[ -n \"\$files\" ] || die' backstop is gone — it is the second independent fail-closed layer at this seam"; fail=1; }
# Flattened for THIS pin only — safe here because there is no `)"`-adjacency
# semantics to preserve, which is precisely why flattening was unsafe for the die
# pin. Without it, trailing-operator style (`… |` at end of line) went RED with a
# message claiming LC_ALL was dropped (Watson, PR #458 final).
grep -qE '\|[[:space:]]*LC_ALL=C sort -u' <<<"$(tr '\n' ' ' <<<"$_g3_stmt")" \
  && echo "PASS  G3's sort -u is collation-pinned at its call site" \
  || { echo "FAIL  G3's sort -u lost its LC_ALL=C prefix — LC_COLLATE is deliberately caller-controlled here, so the dedup's behaviour would become locale-dependent, and a UTF-8 collation can treat two DISTINCT byte sequences as equal and silently drop a path from the classified list"; fail=1; }
# TWO independent facts, so a behaviour-identical reformat (splitting `api_rows=0`
# onto its own line) cannot redden it — the previous single line-shaped pin did,
# with a message blaming a `wc` that was not there.
grep -qE '^api_rows=0(;|$)' "$ROOT/tools/dev/land-pr.sh" \
  && grep -qE '^[[:space:]]*(api_rows=0; )?while IFS= read -r .*; do api_rows=\$\(\(api_rows\+1\)\); done <<<"\$_rows"$' "$ROOT/tools/dev/land-pr.sh" \
  && echo "PASS  api_rows is counted natively (no wc: no BSD padding, nothing to die, bash 3.2-safe)" \
  || { echo "FAIL  api_rows is no longer counted with a native while-read loop — a wc-based count pads on BSD/macOS and leaves the value EMPTY if wc dies, which silently SKIPS the 3000-row truncation reconciliation"; fail=1; }
# STRUCTURAL pin: the G4 ci-only branch must still require tier == code. Dropping
# that guard is the regression every other test would stay green through.
# `[[:space:]]`, never `\s` — `\s` is a GNU extension and these pins would go
# false-RED on BSD grep (macOS), i.e. exactly the adopters SAD-628 is written for.
grep -qE '^[[:space:]]*elif \[ "\$tier" = "code" \] && \[ "\$CODE_TIER_POLICY" = "ci-only" \]; then' "$ROOT/tools/dev/land-pr.sh" \
  && echo "PASS  G4's ci-only branch is still guarded by tier == code" \
  || { echo "FAIL  G4's ci-only branch no longer matches its expected form — either it lost the 'tier == code' guard (a SECURITY PR could then skip BOTH markers) or it was refactored; confirm which before editing this pin"; fail=1; }
# ...and security tier must reach BOTH check_marker calls. Asserted INSIDE the
# else-branch region rather than "the line exists somewhere in the file", which
# stays green if the block is moved into a dead branch (Watson, PR #458).
_g4_else="$(awk '/^if \[ "\$tier" = "docs" \]/{inblk=1} inblk{print} inblk && /^fi$/{exit}' "$ROOT/tools/dev/land-pr.sh")"
if grep -q 'check_marker "\$REVIEWER_MARKER"' <<<"$_g4_else" \
   && grep -q 'check_marker "\$SECURITY_MARKER"' <<<"$_g4_else" \
   && grep -qE '^[[:space:]]*if \[ "\$tier" = "security" \]; then' <<<"$_g4_else"; then
  echo "PASS  G4's else-branch still reaches BOTH markers, with security gated on tier"
else
  echo "FAIL  G4's else-branch no longer contains both check_marker calls under the security guard"; fail=1
fi

# ---------- SAD-681: G7's close-out sync predicate ----------
# G7 runs POST-merge, so it cannot be exercised through the LAND_PR_SELFTEST
# seam like the tier pins above — these are structural pins on the source text,
# the same shape this suite already uses for the G3/G4 branches.
#
# ⚠ ANCHORED TO `^elif` ON PURPOSE. A whole-file grep for the flag would be
# VACUOUSLY GREEN: the rationale comment block directly above the statement
# contains both `status --porcelain` and `--untracked-files=no` verbatim, so an
# unanchored pin would pass even if the statement itself were reverted to the
# bare predicate. This suite's own SAD-646 note records the same trap.
# (Watson Important, PR #529.)
if grep -qE '^elif \[ -n "\$\(git -C "\$default_wt" status --porcelain --untracked-files=no 2>/dev/null\)" \]; then$' \
     "$ROOT/tools/dev/land-pr.sh"; then
  echo "PASS  G7's dirty check ignores UNTRACKED files but still blocks on tracked dirt (SAD-681)"
else
  echo "FAIL  G7's dirty check must carry --untracked-files=no on the elif STATEMENT (not just in a comment)"; fail=1
fi

# The ignored-file collision pre-flight (Barb MEDIUM, PR #529). Without it the
# SAD-681 narrowing removes the incidental shield that kept a fast-forward from
# silently overwriting a present-but-ignored local.properties /
# app/google-services.json — neither of which is security tier (SAD-686), so such
# a commit lands ci-only with no reviewer. Pinned so the narrowing cannot outlive
# its guard.
#
# ⚠ ANCHORED, like the pin above. An earlier revision used a bare whole-file
# `grep -q 'check-ignore --stdin'`, which was non-vacuous only by ACCIDENT — the
# string happened to appear exactly once and in no comment. One explanatory
# comment mentioning it would have made it vacuously green. (Barb LOW, PR #529.)
if grep -qE '^ *git -C "\$default_wt" check-ignore -z --stdin <"\$_dtmp" >"\$_ctmp"' \
     "$ROOT/tools/dev/land-pr.sh"; then
  echo "PASS  G7 pre-flights incoming adds against IGNORED paths before fast-forwarding (SAD-681)"
else
  echo "FAIL  G7 lost its ignored-file collision pre-flight — a fast-forward can silently clobber an ignored file"; fail=1
fi

# Each of the four properties below was a review finding on the pre-flight, and
# each is independently revertible, so each gets its own pin (PR #529 round 3).
if grep -qE '^ *(if )?git -C "\$default_wt" diff -z --no-renames --name-only --diff-filter=A' \
     "$ROOT/tools/dev/land-pr.sh"; then
  echo "PASS  G7's collision diff is rename-aware and NUL-delimited (SAD-681)"
else
  echo "FAIL  G7's collision diff must carry --no-renames (a rename onto an ignored path evades --diff-filter=A) and -z (C-quoting forges gate rows)"; fail=1
fi

# ⚠ ANCHORED to the statement, like its siblings. An earlier revision used a bare
# whole-file match, and BOTH reviewers broke it with a parsing mutant: delete the
# gate, then add a comment quoting the expression, and the pin goes green while
# the property is gone. The block's own prose discusses the `-e` test, so that
# comment is a plausible next edit, not a contrived one. (Watson + Barb, PR #529.)
# ⚠ ADJACENCY, not just presence of the statement. Watson built a mutant that
# leaves this gate line BYTE-IDENTICAL and moves the increment one line ABOVE it:
# the statement pin stays green while the count silently reverts to un-gated
# (count 4 against a 3-entry list). Pinning the line proves it EXISTS; pinning
# `-A1` proves it GUARDS the increment. (Watson Suggestion, PR #529 round 4.)
if grep -A1 -E '^ *\{ \[ -e "\$default_wt/\$_p" \] \|\| \[ -L "\$default_wt/\$_p" \]; \} \|\| continue$' \
     "$ROOT/tools/dev/land-pr.sh" | grep -qE '^ *_collide_n=\$\(\(_collide_n \+ 1\)\)$'; then
  echo "PASS  G7's collision check is PRESENCE-gated and guards the increment (SAD-681)"
else
  echo "FAIL  G7 must gate on the ignored file actually EXISTING, with the gate IMMEDIATELY preceding the increment — rule-only matching blocks the sync on any ignored incoming path (e.g. docs/dogfood evidence)"; fail=1
fi

if grep -q '_collide_err=1' "$ROOT/tools/dev/land-pr.sh" \
   && grep -qE '^elif \[ "\$_collide_err" = "1" \]; then$' "$ROOT/tools/dev/land-pr.sh"; then
  echo "PASS  G7's pre-flight fails CLOSED when it cannot be evaluated (SAD-681)"
else
  echo "FAIL  G7's pre-flight must fail closed on an unknown — a partial/killed diff would otherwise read as 'no collision'"; fail=1
fi

# The message must carry a COUNT, never a path: note() output is rendered with
# printf '%b', which interprets backslash escapes, and git C-quotes odd paths —
# so an interpolated path can forge a gate row. (Barb MEDIUM, PR #529.)
#
# ⚠ POSITIVE SHAPE ASSERTION, not a negative match on the old form. The first
# revision's negative half (`! grep 'note "G7 WARN.*$(tr .\n'`) recognised only
# round-2's exact shape: Barb built a mutant that re-introduced raw path
# interpolation in a DIFFERENT shape and passed all six G7 pins while rendering
# two forged `G7 PASS` rows plus an ANSI erase sequence. Enumerating known-bad
# shapes never converges — assert the whole statement instead, so any added
# interpolation breaks the match. (Watson Suggestion + Barb LOW, PR #529.)
if grep -qE '^ *note "G7 WARN  local \$DEFAULT_BRANCH NOT synced \(\$default_wt\) — \$_collide_n incoming path\(s\) would silently overwrite present-but-ignored file\(s\)\$\{_collide_list:\+; the exact NUL-delimited list was left in \$_collide_list\}"$' \
     "$ROOT/tools/dev/land-pr.sh"; then
  echo "PASS  G7's collision WARN reports a count, not interpolated path text (SAD-681)"
else
  echo "FAIL  G7's collision WARN must not interpolate path names — printf '%b' USED TO interpret git's C-quoted escapes (the sink was hardened in SAD-690; this property is kept as the second control) and forge gate rows"; fail=1
fi

# ⚠ CARDINALITY. The positive assertion above freezes ONE statement, but "no path
# text reaches note()" is a WHOLE-FILE property. Both reviewers independently
# built the same bypass: leave the pinned statement byte-identical and ADD a new
# `note "G7 INFO  colliding paths:$_paths"` beneath it — a plausible
# "more detail for the operator" edit. All the shape pins stay green while the
# forge vector is live. Counting the G7 emitters catches ANY added sink
# regardless of how it derives its text, which is the only form of this pin that
# converges — enumerating bad shapes never does.
# Raising this number is a DELIBERATE act: add the emitter, re-audit it against
# the interpolation list in land-pr.sh's "PRECISE CLAIM" block, then bump here.
# Counts every `note` CALL in the G7 SECTION, not those literally spelled
# `note "G7`. Watson's mutant C assembles the sink into a variable first
# (`_g7_extra="G7 INFO …"; note "$_g7_extra"`) and evades a call-spelling match
# while the forge vector is live. Counting calls is indifferent to how the
# ARGUMENT is built — which is what makes the convergence claim above true — but
# it does depend on recognising where a call can START, hence the separator set
# below rather than a line anchor. (Watson Suggestion round 5 + Barb LOW round 6.)
# ⚠ Counts OCCURRENCES of the `note` CALL, not lines beginning with `note`, and
# deliberately does NOT enumerate the separators that can precede one. Two
# successive attempts at an enumeration both shipped incomplete:
#   • `^ *note ` (line-anchored) missed Barb's one-line spelling of mutant C —
#       _g7_extra="G7 INFO …"; note "$_g7_extra"
#     which puts the sink after a `;` on a line that does not START with note.
#   • `[;&|{(]` then missed the RESERVED-WORD command positions, which begin a
#     command exactly as `;` does — Watson's mutants E/F/G:
#       ...; then note "G7 INFO …"; fi
#       ...; else note "G7 INFO …"; fi
#       for _q in 1; do note "G7 INFO …"; done
# So the test is inverted: require only that `note` is not preceded by a WORD
# character. There is no set to keep complete — which is the same convergence
# argument the cardinality pin itself rests on, applied one level down — and
# `denote`/`footnote` stay excluded. `[^[:alnum:]_]` rather than `\b`, because
# BSD grep does not support `\b` (this suite's portability doctrine).
# Whole-line comments are dropped first so a `# … note …` LINE cannot inflate the
# count; a TRAILING comment on a code line still can, which fails LOUD (a
# spurious FAIL, never a spurious PASS) and so is the acceptable direction.
# (Barb LOW round 6 + Watson Suggestion round 7 — expression is Watson's,
# verified 7 on the clean file and 8 against all six known mutants.)
_g7_notes="$(awk '/^# ---------- G7:/{f=1} /^# ---------- G8:/{f=0} f && !/^[[:space:]]*#/' \
               "$ROOT/tools/dev/land-pr.sh" \
               | grep -oE '(^|[^[:alnum:]_])note[[:space:]]' | wc -l | tr -d '[:space:]')"
if [ "$_g7_notes" = "7" ]; then
  echo "PASS  G7 emits exactly 7 note rows — no unaudited gate-table sink added (SAD-681)"
else
  echo "FAIL  G7 note-row count is $_g7_notes, expected 7 — a new gate-table emitter must first be audited against the interpolation list in land-pr.sh's \"PRECISE CLAIM\" block, then this number bumped deliberately"; fail=1
fi

# ---------- SAD-358 residual 1: the EXECUTED gate logic must have a review trail ----------
# land-pr.sh reads its CONFIG from the trusted ref but runs the SCRIPT off local
# disk, so a working-tree edit could delete a gate with no review trail at all
# (Barb MEDIUM, PR #264). `gate_script_provenance` closes the trailless case by
# requiring the running file's blob to exist on the remote — either on the
# trusted ref or on the branch's upstream.
#
# ⚠ EXECUTED, not grepped, for the reason this file already argues at the G3 pin:
# the check lives past the LAND_PR_SELFTEST exit, and four successive text-only
# versions of that pin each had a hole. The two functions are extracted and RUN
# against throwaway repositories, so each row asserts the actual decision.
_prov_src="$(awk '/^trusted_ref_of\(\) \{/,/^\}/' "$ROOT/tools/dev/land-pr.sh")
$(awk '/^gate_script_provenance\(\) \{/,/^\}/' "$ROOT/tools/dev/land-pr.sh")"
if ! bash -n <<<"$_prov_src" 2>/dev/null \
   || ! grep -q '^gate_script_provenance() {' <<<"$_prov_src"; then
  echo "FAIL  could not extract trusted_ref_of + gate_script_provenance from land-pr.sh — the awk range needs updating, or the functions were removed/renamed (SAD-358)"; fail=1
else
  # Scratch repos, built once and reused. `-c` on every invocation rather than a
  # written config: the runner's global config is already replaced by ci.yml and
  # this must not depend on which one wins.
  _gc=(-c user.name=t -c user.email=t@invalid -c commit.gpgsign=false -c init.defaultBranch=main)
  _pv="$(mktemp -d)"
  _pv_run() { bash -c "$_prov_src"'
    gate_script_provenance "$1"' _ "$1" 2>/dev/null; }
  (
    mkdir -p "$_pv/wt/tools/dev" "$_pv/lone/tools/dev"
    printf 'gate v1\n' > "$_pv/wt/tools/dev/land-pr.sh"
    printf 'gate v1\n' > "$_pv/lone/tools/dev/land-pr.sh"
    git "${_gc[@]}" init -q "$_pv/wt"
    git "${_gc[@]}" init -q --bare "$_pv/origin.git"
    git "${_gc[@]}" -C "$_pv/wt" add -A
    git "${_gc[@]}" -C "$_pv/wt" commit -qm init
    git "${_gc[@]}" -C "$_pv/wt" remote add origin "$_pv/origin.git"
    git "${_gc[@]}" -C "$_pv/wt" push -q -u origin HEAD:main
    # A repo with NO remote at all — the unverifiable case.
    git "${_gc[@]}" init -q "$_pv/lone"
    git "${_gc[@]}" -C "$_pv/lone" add -A
    git "${_gc[@]}" -C "$_pv/lone" commit -qm init
  ) >/dev/null 2>&1
  prov_case() { # $1 = label, $2 = expected leading token, $3 = path
    local got
    got="$(_pv_run "$3")"
    [ "${got%% *}" = "$2" ] \
      && echo "PASS  $1" \
      || { echo "FAIL  $1 — expected '$2…', got '${got:-<empty>}'"; fail=1; }
  }
  prov_case "an unmodified script matches the trusted ref (SAD-358)" ok "$_pv/wt/tools/dev/land-pr.sh"
  printf 'gate v1\nrm -f /gates\n' > "$_pv/wt/tools/dev/land-pr.sh"
  prov_case "an UNCOMMITTED working-tree edit is a mismatch (SAD-358)" mismatch "$_pv/wt/tools/dev/land-pr.sh"
  # ⚠ THE ROW THAT MAKES THIS A GATE RATHER THAN A DIRTY-TREE CHECK. Committing
  # the edit gives it a git object but still no REVIEW trail — nobody else can
  # see it. A `git diff`-shaped implementation goes green here; this one must not.
  git "${_gc[@]}" -C "$_pv/wt" commit -qam "local only" >/dev/null 2>&1
  prov_case "a COMMITTED but unpushed edit is still a mismatch (SAD-358)" mismatch "$_pv/wt/tools/dev/land-pr.sh"
  # Pushed on a FEATURE branch: not on the trusted ref, but on the remote and
  # therefore reviewable — and security tier, so landing it needs both markers.
  git "${_gc[@]}" -C "$_pv/wt" checkout -qb feat >/dev/null 2>&1
  git "${_gc[@]}" -C "$_pv/wt" push -q -u origin feat >/dev/null 2>&1
  prov_case "a PUSHED branch edit is accepted (it has a review trail) (SAD-358)" ok "$_pv/wt/tools/dev/land-pr.sh"
  # ⚠ THE SAME ROW, DEFEATED BY ONE ORDINARY COMMAND. `@{upstream}` is whatever
  # `branch.<name>.remote` points at, and `--set-upstream-to=<a local branch>`
  # sets it to `.` — an upstream that never leaves this machine. Accepting the
  # literal `@{upstream}` therefore turned the mismatch above into a green
  # `ok @{upstream}`, with the note naming a ref the operator would read as
  # remote. Not adversarial: retargeting an upstream is a thing people do. So the
  # symbolic name is resolved and only `refs/remotes/*` counts. (Watson, #547.)
  git "${_gc[@]}" -C "$_pv/wt" checkout -qb local-decoy >/dev/null 2>&1
  printf 'gate v1\nrm -f /gates\nrm -rf /\n' > "$_pv/wt/tools/dev/land-pr.sh"
  git "${_gc[@]}" -C "$_pv/wt" commit -qam "local only, again" >/dev/null 2>&1
  git "${_gc[@]}" -C "$_pv/wt" branch -q --set-upstream-to=local-decoy >/dev/null 2>&1
  prov_case "an upstream retargeted to a LOCAL branch is not a review trail (SAD-358)" \
    mismatch "$_pv/wt/tools/dev/land-pr.sh"
  # …and the accepting path must NAME the ref that vouched, never the symbolic
  # `@{upstream}` — an operator cannot audit a decision reported as an alias.
  git "${_gc[@]}" -C "$_pv/wt" push -q -u origin local-decoy >/dev/null 2>&1
  _pv_ok="$(_pv_run "$_pv/wt/tools/dev/land-pr.sh")"
  case "$_pv_ok" in
    "ok refs/remotes/"*) echo "PASS  an accepted upstream is reported as the RESOLVED remote ref (SAD-358)" ;;
    *) echo "FAIL  expected 'ok refs/remotes/…', got '${_pv_ok:-<empty>}' — reporting the symbolic @{upstream} hides whether the vouching ref was even remote (SAD-358)"; fail=1 ;;
  esac
  prov_case "a repo with no remote copy is UNVERIFIABLE, not a block (SAD-358)" \
    unverifiable "$_pv/lone/tools/dev/land-pr.sh"
  prov_case "a path outside any git repo is UNVERIFIABLE, not a block (SAD-358)" \
    unverifiable "$_pv/not-a-repo.sh"
  rm -rf "$_pv"
fi
# The CALL SITE, which the extraction above cannot reach: a function that returns
# `mismatch` into a caller that ignores it is not a gate. Pinned on the `case`
# arm rather than the whole file so a comment quoting it cannot satisfy the pin —
# this suite's standing lesson from the G3/G7 rounds.
if grep -qE '^ *\*\)$' "$ROOT/tools/dev/land-pr.sh" \
   && grep -A1 -E '^ *\*\)$' "$ROOT/tools/dev/land-pr.sh" | grep -q 'gate_fail 0 '; then
  echo "PASS  the provenance verdict reaches gate_fail (dies on a real landing, FAILs the dry-run table) (SAD-358)"
else
  echo "FAIL  gate_script_provenance's default case no longer calls gate_fail — a mismatch would be computed and then ignored"; fail=1
fi

# ---------- SAD-358 residual 2: G4 marker AUTHORSHIP ----------
# A verdict marker is an ordinary PR comment. G4 verified the SHA pin but never
# WHO posted it, so any commenter could post `<!-- barb-verdict: CLEARED sha=… -->`
# and clear the security gate.
#
# ⚠ `author_association` IS NOT A PERMISSION, and the first cut of this block
# said it was ("OWNER / MEMBER / COLLABORATOR are the write-access set"). GitHub
# returns COLLABORATOR for a read-only `pull` collaborator and MEMBER for any org
# member whatever the org's base permission — commonly `read`. So the association
# is only a free pre-filter now and the deciding field is the login's RESOLVED
# repo permission. The `read`/`triage` rows below are what discriminate the two:
# they PASS against an association-only filter. (Barb MEDIUM #4, PR #547.)
#
# ⚠ What this does NOT close, so no reviewer reads more into the rows below than
# they assert: the review agents post under Jason's own OWNER identity here, so a
# genuine Watson marker and a hand-typed one are indistinguishable at the API.
# That half needs the stations to hold their own bot identity and stays open on
# SAD-358 — G4 now DISCLOSES it instead (the `(SELF-REVIEW — ADR-0033)` tag).
#
# Extracted and RUN, like the provenance block: these functions sit past the
# LAND_PR_SELFTEST exit and behind `gh`, so nothing else in this suite reaches them.
_mk_src="$(awk '/^_perm_of\(\) \{/,/^\}/' "$ROOT/tools/dev/land-pr.sh")
$(awk '/^marker_author_trusted\(\) \{/,/^\}/' "$ROOT/tools/dev/land-pr.sh")
$(awk '/^_perm_cached\(\) \{/,/^\}/' "$ROOT/tools/dev/land-pr.sh")
$(awk '/^_marker_rows\(\) \{/,/^\}/' "$ROOT/tools/dev/land-pr.sh")
$(awk '/^_marker_prime\(\) \{/,/^\}/' "$ROOT/tools/dev/land-pr.sh")
$(awk '/^last_marker\(\) \{/,/^\}/' "$ROOT/tools/dev/land-pr.sh")
$(awk '/^untrusted_marker_authors\(\) \{/,/^\}/' "$ROOT/tools/dev/land-pr.sh")"
_mk_assoc="$(grep -E '^MARKER_TRUSTED_ASSOC=|^MARKER_WRITE_PERM=' "$ROOT/tools/dev/land-pr.sh")"
# Fixture builders live OUTSIDE the extraction guard: the ADR-0033 disclosure
# block below reuses them, and it must not become an unbound-variable crash on
# the one path where extraction failed (which already FAILs its own row).
_mk_sha="$(printf '%040d' 7 | tr '0' 'a')"
_mk_stale="$(printf '%040d' 7 | tr '0' 'b')"
mk_comment() { # $1 = association, $2 = login, $3 = body
  jq -nc --arg a "$1" --arg l "$2" --arg b "$3" \
    '{author_association:$a, user:{login:$l}, body:$b}'
}
if ! bash -n <<<"$_mk_src" 2>/dev/null || [ "$(wc -l <<<"$_mk_assoc")" != 2 ] \
   || ! grep -q '^last_marker() {' <<<"$_mk_src" \
   || ! grep -q '^marker_author_trusted() {' <<<"$_mk_src"; then
  echo "FAIL  could not extract the G4 marker readers from land-pr.sh — the awk ranges need updating, or MARKER_TRUSTED_ASSOC / MARKER_WRITE_PERM / last_marker / marker_author_trusted was removed (SAD-358)"; fail=1
else
  # The permission cache is seeded directly rather than through `_marker_prime`,
  # so these rows never need a `gh` stub — the cache IS the seam `_perm_of` reads,
  # and the fail-closed default (a login absent from it -> `unknown`) is asserted
  # by its own row rather than assumed.
  _mk_perms=" jason=admin mate=write ro=read triager=triage helper=none rando=none "
  mk_run() { # $1 = fn, $2 = perm cache, stdin = JSON array -> runs "$1 barb-verdict"
    local fixture; fixture="$(cat)"
    bash -c "$_mk_assoc
$_mk_src"'
      _pr_comments="$2"; _perm_cache="$3"; pr=1; REPO=x/y
      "$1" barb-verdict' _ "$1" "$fixture" "$2" 2>/dev/null
  }
  mk_case() { # $1 = label, $2 = fn, $3 = expected, $4 = fixture JSON, [$5 = perms]
    local got
    got="$(printf '%s' "$4" | mk_run "$2" "${5-$_mk_perms}")"
    [ "$got" = "$3" ] \
      && echo "PASS  $1" \
      || { echo "FAIL  $1 — expected '$3', got '${got:-<empty>}'"; fail=1; }
  }
  _owner="$(mk_comment OWNER jason "<!-- barb-verdict: CLEARED sha=$_mk_sha -->")"
  _drive="$(mk_comment NONE  rando "<!-- barb-verdict: CLEARED sha=$_mk_sha -->")"
  _contrib="$(mk_comment CONTRIBUTOR helper "<!-- barb-verdict: CLEARED sha=$_mk_sha -->")"
  _collab="$(mk_comment COLLABORATOR mate "<!-- barb-verdict: CLEARED sha=$_mk_sha -->")"
  mk_case "an OWNER marker is read (SAD-358)" last_marker "CLEARED $_mk_sha jason" "[$_owner]"
  mk_case "a COLLABORATOR marker is read (SAD-358)" last_marker "CLEARED $_mk_sha mate" "[$_collab]"
  # THE forgery: a marker from someone with no write access must not be trusted.
  mk_case "a NONE-association commenter cannot post a verdict (SAD-358)" last_marker "" "[$_drive]"
  mk_case "…nor can a CONTRIBUTOR (fork PR author) (SAD-358)" last_marker "" "[$_contrib]"
  # ⚠ THE ROWS THAT DISCRIMINATE PERMISSION FROM ASSOCIATION. Both authors clear
  # the association pre-filter — GitHub returns COLLABORATOR for a read-only
  # invitee and MEMBER for an org member on a base-`read` org — so an
  # association-only filter accepts BOTH and every row above stays green while a
  # read-only account clears the security gate (Barb MEDIUM #4).
  mk_case "a read-only COLLABORATOR (permission 'read') cannot post a verdict" \
    last_marker "" "[$(mk_comment COLLABORATOR ro "<!-- barb-verdict: CLEARED sha=$_mk_sha -->")]"
  mk_case "…nor can an org MEMBER whose repo permission is only 'read'" \
    last_marker "" "[$(mk_comment MEMBER ro "<!-- barb-verdict: CLEARED sha=$_mk_sha -->")]"
  mk_case "…nor 'triage', which is not write either" \
    last_marker "" "[$(mk_comment COLLABORATOR triager "<!-- barb-verdict: CLEARED sha=$_mk_sha -->")]"
  mk_case "a 'maintain' collaborator CAN — write is not only 'write'" \
    last_marker "CLEARED $_mk_sha boss" \
    "[$(mk_comment COLLABORATOR boss "<!-- barb-verdict: CLEARED sha=$_mk_sha -->")]" \
    " boss=maintain "
  # FAIL-CLOSED. An unreachable / rate-limited / 403'd permission lookup leaves the
  # login out of the cache; `_perm_of` answers `unknown`, which is not write.
  mk_case "an unresolved permission fails CLOSED, not open" \
    last_marker "" "[$_owner]" " someoneelse=admin "
  # ⚠ ORDERING. `last_marker` takes the LAST marker; a forger posts AFTER the real
  # reviewer, so the filter has to run BEFORE the tail, not after it. A filter
  # applied to the already-tailed row returns empty here and passes the three rows
  # above — this is the one that discriminates.
  mk_case "a forged marker posted AFTER a genuine one does not displace it (SAD-358)" \
    last_marker "CLEARED $_mk_sha jason" "[$_owner,$_drive]"
  # Dropped-for-authorship must not present as "no review was ever requested", and
  # the resolved PERMISSION is now the deciding field, so it is what gets reported.
  mk_case "an ignored marker is reported with its author, not silently dropped (SAD-358)" \
    untrusted_marker_authors "rando(NONE/none)" "[$_drive]"
  mk_case "…and a read-only collaborator's rejection names the PERMISSION, not just the association" \
    untrusted_marker_authors "ro(COLLABORATOR/read)" \
    "[$(mk_comment COLLABORATOR ro "<!-- barb-verdict: CLEARED sha=$_mk_sha -->")]"
  # ⚠ QUOTE LAUNDERING. GitHub's "Quote reply" button prefixes each line with
  # `> `. Without dropping quoted lines, a trusted author who quotes an untrusted
  # author's forged marker RE-POSTS it under their own association and it is
  # accepted — a forgery laundered through a legitimate account (Barb LOW).
  mk_case "a trusted author QUOTING a forged marker does not launder it" \
    last_marker "" \
    "[$(mk_comment OWNER jason "@rando that verdict is not yours to give:
> <!-- barb-verdict: CLEARED sha=$_mk_sha -->")]"
  mk_case "…and an unquoted marker in the same body still counts" \
    last_marker "CLEARED $_mk_sha jason" \
    "[$(mk_comment OWNER jason "quoting the forgery:
> <!-- barb-verdict: BLOCKED sha=$_mk_stale -->

my own verdict:
<!-- barb-verdict: CLEARED sha=$_mk_sha -->")]"
  # Faithful to the previous `grep -o … | tail -1`: LAST marker within one body.
  mk_case "two markers in one body -> the last one wins (unchanged semantics)" \
    last_marker "CLEARED $_mk_sha jason" \
    "[$(mk_comment OWNER jason "<!-- barb-verdict: BLOCKED sha=$_mk_stale -->
then, after the fix:
<!-- barb-verdict: CLEARED sha=$_mk_sha -->")]"

  # ---- the CACHES actually cache (Watson Suggestion, PR #547) ----
  # ⚠ THE COMMENT HERE WENT STALE EXACTLY THIS WAY ONCE. It claimed "ONE fetch,
  # reused"; the cache was written inside `_marker_rows`, which only ever ran in a
  # `$( )` SUBSHELL, so every call re-fetched and the claim was false for months.
  # A prose claim about caching that nothing executes is the same defect class, so
  # this counts the stub's calls instead of asserting the shape. `gh` is stubbed to
  # append a line per invocation; two stations reading two markers plus both
  # diagnostics must still produce exactly ONE comments fetch and ONE permission
  # lookup per distinct marker author.
  _cnt="$(mktemp)"
  # ⚠ The counter path and the fixture are captured into NAMED variables before
  # `gh` is defined: inside a function `$1`/`$2` are the FUNCTION's arguments, not
  # the script's, so reading them there silently counted nothing and the row
  # reported `<empty>` — a stub that measures its own bug rather than the code's.
  bash -c "$_mk_assoc
$_mk_src"'
    _cnt="$1"; _body="$2"
    gh() {
      case "$*" in
        *"/comments"*)   printf "comments\n"   >> "$_cnt"; printf "%s" "$_body" ;;
        *"/permission"*) printf "permission\n" >> "$_cnt"; printf "admin\n" ;;
        *) return 1 ;;
      esac
    }
    pr=1; REPO=x/y
    _marker_prime barb-verdict
    last_marker barb-verdict              >/dev/null
    untrusted_marker_authors barb-verdict >/dev/null
    _marker_prime watson-verdict
    last_marker watson-verdict            >/dev/null
  ' _ "$_cnt" "[$(mk_comment OWNER jason "<!-- barb-verdict: CLEARED sha=$_mk_sha -->")]" >/dev/null 2>&1
  _gh_calls="$(LC_ALL=C sort "$_cnt" | uniq -c | tr -s ' ' | sed 's/^ //' | tr '\n' ';')"
  rm -f "$_cnt"
  if [ "$_gh_calls" = "1 comments;1 permission;" ]; then
    echo "PASS  the comments fetch and the permission lookup each happen exactly ONCE (SAD-358)"
  else
    echo "FAIL  marker caches are not caching — expected '1 comments;1 permission;', got '${_gh_calls:-<empty>}'. The caches are plain shell variables, so priming them anywhere that runs inside \$( ) discards them and every call re-fetches"; fail=1
  fi

  # ---- the permission lookup is SANITIZED, not trusted (Barb LOW-1) ----
  # `gh api --jq '.permission'` prints the ERROR BODY to STDOUT on a 4xx and exits
  # non-zero, so `perm` can be a JSON blob rather than a permission word. Both
  # halves are pinned because they fail through different paths: a non-zero exit
  # is caught by `|| perm=""`, while a zero exit carrying junk is caught ONLY by
  # the sanitizer. Deleting the sanitizer leaves the first returning empty and the
  # second returning the blob — both RED here.
  #
  # ⚠ WHAT THIS DOES NOT PIN, stated so the row is not read as more than it is:
  # it does NOT discriminate the enumerated class from `[a-z]`. Measured under this
  # box's en_US.UTF-8, both classify all five probes identically — `admin`,
  # `ecrire`, `écrire`, `ADMIN` and a JSON body. The enumeration is the file's
  # standing discipline (the locale preamble's rule), not something this row
  # defends; a revert to `[a-z]` would stay green.
  perm_case() { # $1 = label, $2 = expected, $3 = stub exit code, $4 = stub stdout
    local got
    got="$(bash -c "$_mk_assoc
$_mk_src"'
      _body="$1"; _rc="$2"; _out="$3"
      gh() {
        case "$*" in
          *"/comments"*)   printf "%s" "$_body" ;;
          *"/permission"*) printf "%s\n" "$_out"; return "$_rc" ;;
          *) return 1 ;;
        esac
      }
      pr=1; REPO=x/y
      _marker_prime barb-verdict
      _perm_of jason
    ' _ "[$(mk_comment OWNER jason "<!-- barb-verdict: CLEARED sha=$_mk_sha -->")]" \
        "$3" "$4" 2>/dev/null)"
    [ "$got" = "$2" ] \
      && echo "PASS  $1" \
      || { echo "FAIL  $1 — expected '$2', got '${got:-<empty>}'"; fail=1; }
  }
  perm_case "a 4xx error BODY on stdout does not become a permission (exit 1)" \
    unknown 1 '{"message":"Not Found","status":"404"}'
  perm_case "…nor does junk that arrives with a ZERO exit — the sanitizer's own case" \
    unknown 0 '{"message":"Not Found","status":"404"}'
  perm_case "a real permission word still survives the sanitizer" \
    admin 0 'admin'
fi

# ---------- ADR-0033 disclosure: G4 must NAME the marker author ----------
# `G4 PASS  barb-verdict CLEARED @ head` reads as "a reviewer cleared this" when
# all it asserts is "a comment exists". Watson, Barb and the author are ONE
# GitHub identity on this repo, so a self-posted marker is byte-identical to a
# genuine one — ADR-0033 sanctions that, but only as a DISCLOSED self-review, and
# a gate row that omits the author discloses nothing. (Barb closing point, #547.)
#
# BEHAVIOURAL, not a source grep. Three literal-string greps over check_marker
# assert only that the strings are present, not that the row they build is ever
# emitted or that the tag is conditioned correctly (Barb LOW-4). So check_marker
# is EXTRACTED and RUN against a stubbed note/gate_fail, once with the marker
# login equal to the PR author and once with it different, and the rendered row
# is compared. The source pins below are kept as the cheap backstop for the
# shape, but they are no longer the only thing standing behind the claim.
_g4_pass="$(awk '/^check_marker\(\) \{/,/^\}/' "$ROOT/tools/dev/land-pr.sh")"
g4row() { # $1 = marker login, $2 = pr_author -> the emitted G4 row
  bash -c "$_mk_assoc
$_mk_src
$_g4_pass"'
    note() { printf "%s\n" "$1"; }
    gate_fail() { printf "GATE_FAIL %s\n" "$2"; }
    _pr_comments="$3"; _perm_cache=" $1=admin "; pr=1; REPO=x/y
    head="$4"; pr_author="$2"
    _marker_prime() { :; }
    check_marker barb-verdict CLEARED barb' _ "$1" "$2" \
    "[$(mk_comment OWNER "$1" "<!-- barb-verdict: CLEARED sha=$_mk_sha -->")]" "$_mk_sha" 2>/dev/null
}
_g4_self="$(g4row jason jason)"
_g4_other="$(g4row reviewer jason)"
# The bounded claim must be on EVERY pass, not only the self-review one: the
# non-self row otherwise still reads as "a reviewer cleared this", which is the
# overclaim. And a caveat that fires on every gated PR — which the self-review
# tag does on this repo — is background text, the same alarm-fatigue argument
# this suite already applies to sad_hidden. So: claim always, tag as the extra.
if [[ "$_g4_self" == *"@jason"* && "$_g4_self" == *"not that a review was performed"* \
      && "$_g4_self" == *"SELF-REVIEW"* ]]; then
  echo "PASS  G4's PASS row names the author, states its bounded claim, and tags a self-review"
else
  echo "FAIL  G4's self-review row is wrong — got '${_g4_self:-<empty>}'"; fail=1
fi
if [[ "$_g4_other" == *"@reviewer"* && "$_g4_other" == *"not that a review was performed"* \
      && "$_g4_other" != *"SELF-REVIEW"* ]]; then
  echo "PASS  …and a marker from someone OTHER than the author is not tagged, but still bounded"
else
  echo "FAIL  G4's non-self row is wrong (tag leaked, or the bounded claim is only on self-review) — got '${_g4_other:-<empty>}'"; fail=1
fi
if grep -q 'note "G4 PASS .*marker by @\$login;' <<<"$_g4_pass" \
   && grep -q '\[ "\$login" = "\$pr_author" \] && tag=' <<<"$_g4_pass"; then
  echo "PASS  G4's PASS row names the marker author and tags a self-review (ADR-0033)"
else
  echo "FAIL  G4's PASS row no longer discloses the marker author / the self-review tag — 'CLEARED @ head' alone claims a reviewer cleared the PR when it only means a comment exists (ADR-0033)"; fail=1
fi
# ⚠ LINE ORDER, not just presence. The untrusted-author diagnostic must be
# consulted BEFORE the `-z "$m"` branch, or a forgery attempted ALONGSIDE a
# genuine marker — the shape where someone is actively trying to clear the gate —
# prints nothing at all. Moving `spoof=` back inside that branch reproduces the
# defect and left the suite 218 PASS / 0 FAIL (Watson delta, PR #547). Same
# technique as the _g4_else pin above: compare extracted line numbers.
_sp_ln="$(grep -n 'spoof="\$(untrusted_marker_authors' <<<"$_g4_pass" | head -1 | cut -d: -f1)"
_if_ln="$(grep -n 'if \[ -z "\$m" \]; then' <<<"$_g4_pass" | head -1 | cut -d: -f1)"
if [ -n "$_sp_ln" ] && [ -n "$_if_ln" ] && [ "$_sp_ln" -lt "$_if_ln" ]; then
  echo "PASS  G4 consults the untrusted-author diagnostic BEFORE the no-marker branch (SAD-358)"
else
  echo "FAIL  G4's untrusted-marker diagnostic is not evaluated before the 'no marker' branch (spoof line ${_sp_ln:-?}, if line ${_if_ln:-?}) — a forgery posted ALONGSIDE a genuine verdict would be reported nowhere"; fail=1
fi
# The tag is only meaningful if pr_author is actually populated from the PR, and
# its sentinel must not collide with _marker_rows' own `?` fallback for a missing
# login — two unknowns comparing equal would tag an ordinary PR as a self-review.
if grep -q '^pr_json=.*--json .*,author ' "$ROOT/tools/dev/land-pr.sh" \
   && grep -q "^pr_author=.*\.author\.login // \"<no-author>\"" "$ROOT/tools/dev/land-pr.sh"; then
  echo "PASS  pr_author is read from the PR payload, with a sentinel that cannot equal a login"
else
  echo "FAIL  pr_author is not populated from gh pr view --json …,author with a non-colliding sentinel — the self-review tag would never fire, or would fire on every PR (ADR-0033)"; fail=1
fi

# ---------- SAD-690: the gate table is not an escape sink ----------
# `note()` used to accumulate the two-character escape `\n` and the table
# rendered with `printf '%b'` — the one conversion that INTERPRETS backslash
# escapes. `git diff --name-only` C-QUOTES unusual paths, so a landed path
# arrives at that sink pre-loaded with escapes: PR #529 round 2 forged a `G7
# PASS` row from a path name and, with `\033[2K\033[1A`, ERASED the genuine WARN
# above it.
#
# Driven, not read. A structural grep for `printf '%s'` would pass on a `note()`
# that had gone back to appending `\n`, which renders the whole table as one
# line — so the rows below build a table through the REAL extracted `note()` and
# assert on the bytes that come out.
_nt_src="$(awk '/^note\(\) \{/,/^note\(\) \{/{print; exit}' "$ROOT/tools/dev/land-pr.sh")"
if ! grep -q '^note() {' <<<"$_nt_src"; then
  echo "FAIL  could not extract note() from land-pr.sh — the SAD-690 sink rows below are vacuous"; fail=1
else
  # The render line is lifted from the script too, so this cannot pass against a
  # `printf '%b'` that the suite hard-codes as `%s` on its own.
  _nt_render="$(grep -m1 -oE "printf '%[bs]' \"\\\$gate_rows\"" "$ROOT/tools/dev/land-pr.sh")"
  _nt_out="$(bash -c "gate_rows=\"\"
$_nt_src
note 'G7 PASS  real row'
note \"\$1\"
note 'G7 WARN  a real warning'
$_nt_render" _ 'G7 EVIL  build/x\nG7 PASS  local main fast-forwarded (FORGED)\033[2K\033[1A' 2>/dev/null)"
  # `grep -c ''`, not `wc -l`: command substitution strips the trailing newline,
  # so the last row arrives unterminated and `wc -l` under-counts it by one.
  _nt_lines="$(printf '%s' "$_nt_out" | grep -c '')"
  # 3 note() calls -> exactly 3 newline-terminated rows. A `%b` sink turns the
  # middle one into two and the count becomes 4.
  if [ "$_nt_lines" = "3" ]; then
    echo "PASS  the gate table renders one row per note() call — a \\n inside a row cannot forge a second (SAD-690)"
  else
    echo "FAIL  $_nt_lines row(s) rendered from 3 note() calls — the \\n in the interpolated value was EXPANDED, i.e. the table is still an escape sink (SAD-690)"; fail=1
  fi
  case "$_nt_out" in
    *'\n'*) echo "PASS  a backslash-n in a row survives as literal text rather than a line break (SAD-690)" ;;
    *)      echo "FAIL  the literal backslash-n is gone from the rendered table — it was interpreted, not printed (SAD-690)"; fail=1 ;;
  esac
  # ESC (0x1b) is the erase half of the demonstrated attack: `\033[2K\033[1A`
  # clears the line and moves the cursor up, deleting a genuine WARN from the
  # operator's audit surface. Checked separately from the row count because a
  # sink could interpret `\033` while leaving `\n` alone.
  if printf '%s' "$_nt_out" | LC_ALL=C grep -q $'\033'; then
    echo "FAIL  an ESC byte reached the rendered gate table — \\033 was interpreted, so a row can still erase the one above it (SAD-690)"; fail=1
  else
    echo "PASS  no ESC byte reaches the rendered table — a row cannot erase the row above it (SAD-690)"
  fi
  # The two structural halves, so a revert of EITHER is caught on its own rather
  # than only in combination (reverting both is what restores the vulnerability;
  # reverting one is loud but is still the first half of getting there).
  if grep -q "note() { gate_rows=\"\${gate_rows}\$1\"\$'\\\\n'; }" "$ROOT/tools/dev/land-pr.sh"; then
    echo "PASS  note() appends a REAL newline, not the two-character escape (SAD-690)"
  else
    echo "FAIL  note() no longer appends \$'\\n' — if the sink is also on %b, the escape-forgery class is back (SAD-690)"; fail=1
  fi
  _nt_b="$(grep -c "printf '%b' \"\$gate_rows\"" "$ROOT/tools/dev/land-pr.sh")"
  _nt_s="$(grep -c "printf '%s' \"\$gate_rows\"" "$ROOT/tools/dev/land-pr.sh")"
  if [ "$_nt_b" = "0" ] && [ "$_nt_s" = "2" ]; then
    echo "PASS  both gate-table render sites use printf '%s' and none uses '%b' (SAD-690)"
  else
    echo "FAIL  gate_rows render sites: $_nt_b on %b, $_nt_s on %s — expected 0 and 2 (SAD-690)"; fail=1
  fi
fi

# ---------- SAD-692: bare mktemp is a macOS-only silent tier downgrade ----------
# BSD/macOS `mktemp` REQUIRES a template and exits with a usage error without
# one; GNU's does not. At the $CFG call sites that made `CFG` empty, the
# `git show > "$CFG"` redirect fail, and `[ ! -f "$CFG" ]` route the run to the
# config-missing branch — landing an adopter's PR against THIS repo's hardcoded
# tier patterns behind nothing louder than a WARN.
# Matches the INVOCATION form only (`$(mktemp …)`), so prose mentioning mktemp in
# a comment or a die message is not counted as a call site — an over-broad
# `grep mktemp` flagged both and would have taught the next editor to loosen the
# exclusion rather than fix a real bare call.
_mt_bare="$(grep -nE '\$\(mktemp' "$ROOT/tools/dev/land-pr.sh" \
  | grep -vE '\$\(mktemp (-d )?"\$\{TMPDIR:-/tmp\}/[^"]+\.XXXXXXXXXX"')"
if [ -z "$_mt_bare" ]; then
  echo "PASS  every mktemp in land-pr.sh carries an explicit template (SAD-692)"
else
  echo "FAIL  bare/untemplated mktemp call(s) in land-pr.sh — these fail outright on BSD/macOS: $(tr '\n' ' ' <<<"$_mt_bare")"; fail=1
fi
# Driven: the helper must produce a usable path under a BSD-shaped mktemp, and
# must DIE rather than return empty when mktemp genuinely fails. The second row
# is the one that matters — returning empty is what silently reached the
# hardcoded fallbacks.
_ct_src="$(awk '/^_cfg_tmp\(\) \{/,/^\}/' "$ROOT/tools/dev/land-pr.sh")"
if ! grep -q '^_cfg_tmp() {' <<<"$_ct_src"; then
  echo "FAIL  could not extract _cfg_tmp() from land-pr.sh — the SAD-692 behavioural rows are vacuous"; fail=1
else
  _ct_bin="$(mktemp -d "${TMPDIR:-/tmp}/land-pr-mktemp-stub.XXXXXXXXXX")"
  _ct_trap="$(trap -p EXIT)"; trap 'rm -rf "$_ct_bin"' EXIT
  # Resolve the real mktemp BEFORE shadowing PATH, and do not hard-code a path:
  # this suite's whole point (SAD-682) is running in trees it does not control.
  _ct_real="$(command -v mktemp)"
  # A BSD-shaped mktemp: refuses a call with no template, honours one with.
  { echo '#!/usr/bin/env bash'
    echo '[ "$#" -gt 0 ] || { echo "usage: mktemp [-d] template" >&2; exit 1; }'
    echo "exec $_ct_real \"\$@\""
  } > "$_ct_bin/mktemp"; chmod +x "$_ct_bin/mktemp"
  _ct_got="$(PATH="$_ct_bin:$PATH" bash -c "
    die() { echo \"land-pr [G\$1]: FAIL — \$2\" >&2; exit 1; }
    $_ct_src
    _cfg_tmp; [ -f \"\$CFG\" ] && echo USABLE" 2>/dev/null)"
  [ "$_ct_got" = "USABLE" ] \
    && echo "PASS  _cfg_tmp yields a real file under a BSD-shaped mktemp (SAD-692)" \
    || { echo "FAIL  _cfg_tmp gave no usable file under a BSD-shaped mktemp (got '${_ct_got:-<empty>}') — this is the macOS silent-fallback defect"; fail=1; }
  { echo '#!/usr/bin/env bash'; echo 'exit 1'; } > "$_ct_bin/mktemp"; chmod +x "$_ct_bin/mktemp"
  # `if ! …` directly, not `$?` on a preceding line (shellcheck SC2181): nothing
  # sits between the two today, and one inserted line would make the test
  # vacuously green.
  if ! PATH="$_ct_bin:$PATH" bash -c "
    die() { echo \"land-pr [G\$1]: FAIL — \$2\" >&2; exit 1; }
    $_ct_src
    _cfg_tmp; echo REACHED-PAST-THE-DIE" >/dev/null 2>&1; then
    echo "PASS  a failed mktemp DIES instead of leaving CFG empty and falling back (SAD-692)"
  else
    echo "FAIL  _cfg_tmp survived a failing mktemp — an empty CFG then routes the landing to the hardcoded tier patterns (SAD-692)"; fail=1
  fi
  rm -rf "$_ct_bin"; eval "${_ct_trap:-trap - EXIT}"
fi
# "It exists on the ref but could not be read" must not be treated as "there is
# no config". Both materialization sites are guarded.
_ct_show="$(grep -c 'workflow.config.json" > "\$CFG" \\' "$ROOT/tools/dev/land-pr.sh")"
_ct_die="$(grep -c 'unreadable config, not a missing one' "$ROOT/tools/dev/land-pr.sh")"
if [ "$_ct_show" = "2" ] && [ "$_ct_die" = "2" ]; then
  echo "PASS  both config materializations die on failure rather than falling back (SAD-692)"
else
  echo "FAIL  config materialization guards: $_ct_show continued lines, $_ct_die die messages — expected 2 and 2 (SAD-692)"; fail=1
fi

# ---------- SAD-692's adopter half: a MISSING config refuses the landing ----------
# Ported down from agent-pr-flow PR #9 and inert in this repo, which commits its
# config — so a pin is the only thing protecting it. Deleting the whole block
# left the suite green at its floor (Watson, PR #570).
if grep -q '^  CFG_MISSING=1$' "$ROOT/tools/dev/land-pr.sh"; then
  echo "PASS  a missing workflow.config.json is RECORDED, not just warned about (SAD-692)"
else
  echo "FAIL  CFG_MISSING is no longer set on the config-missing path — an adopter would land on another repo's hardcoded tier map behind one stderr line (SAD-692)"; fail=1
fi
if grep -q 'gate_fail 0 "no .claude/workflow.config.json' "$ROOT/tools/dev/land-pr.sh"; then
  echo "PASS  …and it becomes a gate row that refuses a real landing (SAD-692)"
else
  echo "FAIL  the missing-config gate row is gone — the tier map would come from instance-#1 fallbacks with no gate (SAD-692)"; fail=1
fi

# ---------- SAD-718: a steering signal that can stop a validation run ----------
# `sad_hidden` fires when the reviewer-visible text and the raw bytes disagree
# about which issue a PR closes. It was surfaced only as advisory text, so
# `--dry-run` printed "all gates green — a real run would merge" and exited 0
# with the flag set: the strongest outcome the whole hidden-steering surface
# could produce was a note nobody had a reason to weigh.
_ga_src="$(awk '/^note\(\) \{/,/^note\(\) \{/{print; exit}' "$ROOT/tools/dev/land-pr.sh")
$(awk '/^gate_advise\(\) \{/,/^\}/' "$ROOT/tools/dev/land-pr.sh")"
if ! grep -q '^gate_advise() {' <<<"$_ga_src"; then
  echo "FAIL  could not extract gate_advise() from land-pr.sh — the SAD-718 rows below are vacuous"; fail=1
else
  # ⚠ THE TWO COUNTERS ARE REPORTED SEPARATELY, not summed (Watson, PR #582).
  # A sum cannot distinguish the two states the whole STOP/FAIL split exists to
  # separate, and the row that was covering that gap was a literal grep of the
  # source for `landing_blocked=1` — which `landing_blocked="1"` evades. Measured
  # with that one character added: suite 292/0 green, and the dry-run report back
  # to "landing BLOCKED" for a run that would merge, i.e. the exact over-report
  # this PR removed, restored under a green suite.
  _ga_run() { # $1 = dry_run value -> "<row>|<blocked>|<advisory>"
    bash -c "gate_rows=\"\"; landing_blocked=0; landing_advisory=0; dry_run=\"\$1\"
$_ga_src
gate_advise 5 'hidden steering'
printf '%s|%s|%s' \"\$(printf '%s' \"\$gate_rows\" | tr -d '\\n')\" \"\$landing_blocked\" \"\$landing_advisory\"" _ "$1" 2>/dev/null
  }
  case "$(_ga_run 1)" in
    "G5 STOP  hidden steering|0|1")
      echo "PASS  under --dry-run the steering signal is a G5 STOP and halts the run (SAD-718)" ;;
    *) echo "FAIL  --dry-run did not turn the steering signal into a halting G5 STOP — got '$(_ga_run 1)' (SAD-718)"; fail=1 ;;
  esac
  # STOP, not FAIL, and the distinction IS the assertion. A dry run whose only
  # complaint is an advisory must not report the landing as BLOCKED, because a
  # real run WOULD merge; over-reporting is the mirror of the bug SAD-718 fixed.
  case "$_ga_src" in
    *'landing_blocked=1'*) echo "FAIL  gate_advise sets landing_blocked — the dry run would claim a hard gate failed where a real run would merge (SAD-718)"; fail=1 ;;
    *) echo "PASS  gate_advise sets landing_advisory, never landing_blocked (SAD-718)" ;;
  esac
  case "$(_ga_run 0)" in
    "G5 WARN  hidden steering|0|0")
      echo "PASS  a real landing keeps it advisory — the detection has a genuine false-positive rate (SAD-718)" ;;
    *) echo "FAIL  a real run no longer keeps the steering signal advisory — got '$(_ga_run 0)' (SAD-718)"; fail=1 ;;
  esac
fi
# ⚠ And the call site actually uses it. Without this row the two above are true
# of a helper nothing calls, which is how the flag came to be advisory-only in
# the first place.
if grep -q 'STOPPED for adjudication' "$ROOT/tools/dev/land-pr.sh" \
   && grep -q 'landing BLOCKED by the gates above' "$ROOT/tools/dev/land-pr.sh"; then
  echo "PASS  the dry-run report distinguishes a hard-gate BLOCK from an advisory STOP (SAD-718)"
else
  echo "FAIL  the dry-run report no longer distinguishes a blocking failure from an advisory stop — it would claim a real run cannot merge when it can (SAD-718)"; fail=1
fi
# ⚠⚠ THE DRY RUN MUST **exit**. THIS ROW EXISTS BECAUSE THE ABSENCE OF THAT ONE
# WORD MERGED A PR. On 2026-08-12, mid-edit, the dry-run terminator was written
# as a bare `[ ... ] && [ ... ]` — right status, no exit — and the next
# `land-pr.sh 570 --dry-run` fell through to G6 and merged PR #570 with BOTH
# verdict-marker gates showing FAIL in its own table. In --dry-run mode
# `gate_fail` only records rows, so nothing else stops the run: the `exit` is
# the entire difference between a validation and a landing.
#
# Pinned STRUCTURALLY (the statement is an `exit`) and BEHAVIOURALLY (the block
# actually terminates), because a status-only assertion is exactly what the
# broken version would have satisfied.
_dr_block="$(sed -n '/^# ---------- dry-run stop ----------$/,/^fi$/p' "$ROOT/tools/dev/land-pr.sh")"
# ⚠ GUARD THE EXTRACTION — this was the one extraction in this file without one,
# and the omission was not cosmetic (Watson, PR #582). The range ends at the next
# column-0 `fi`; rewrite the block as `case … esac` and the range runs on to the
# NEXT one, which is past `gh pr merge`. Measured: with the terminator changed
# and the `exit` left perfectly correct, both rows below stayed green while
# `_dr_block` had grown to 50 lines containing the merge command — vacuous, and
# silent. Compounded with the incident edit, `_dr_probe` then EXECUTES that
# merge; with a stubbed `gh` on PATH it was observed invoking
# `gh pr merge 0 --match-head-commit …`. Harmless only because `pr=0`.
#
# The `gh pr merge` negative is the load-bearing half: it makes an over-run RED
# and makes it structurally impossible for the probe below to reach the merge.
if ! grep -q '^if \[ "\$dry_run" = "1" \]; then$' <<<"$_dr_block" \
   || grep -q 'gh pr merge' <<<"$_dr_block"; then
  echo "FAIL  could not extract the dry-run stop cleanly — the sed range over-ran into G6, or the block changed shape. The two rows below would be VACUOUS, and the behavioural probe would have EXECUTED the merge"; fail=1
fi
# ⚠ THE SAME PATTERN THE RUNTIME TRIPWIRE USES. They disagreed once — this pin
# accepted any `exit `, the tripwire demanded a numeric literal, and
# `exit $((…))` therefore passed here while bricking the script (Watson,
# PR #582). Lifted from land-pr.sh so they cannot drift apart again.
_tw_re="$(sed -n "s/.*! grep -qE '\(\^\[\[:space:\]\]\*exit[^']*\)'.*/\1/p" "$_lp" | head -1)"
[ -n "$_tw_re" ] || _tw_re='^[[:space:]]*exit([[:space:]]|$)'
if grep -qE "$_tw_re" <<<"$_dr_block"; then
  echo "PASS  the dry-run stop terminates with an exit statement (SAD-718)"
else
  echo "FAIL  the dry-run stop has no exit statement — the run FALLS THROUGH TO G6 AND MERGES, with every gate failure above reduced to a printed row. This exact edit merged PR #570 on 2026-08-12"; fail=1
fi
# ⚠ THE PAYLOAD CARRIES G6's OWN GUARD TOO, so the probe models "the stop, then
# the sink" rather than the stop alone. Barb's HIGH-1 shape — a predicate inside
# the stop keyed on something the fixture cannot reproduce — leaves the stop
# without an exit for that input, and only the sink catches it. `die` is stubbed
# so a catch reports instead of killing the suite.
_dr_g6="$(grep -m1 '^\[ "\$_DRY_RUN_PARSED" != "1" \] || die 6 ' "$ROOT/tools/dev/land-pr.sh")"
[ -n "$_dr_g6" ] || { echo "FAIL  could not lift G6's dry-run guard — the probe below would model the stop without its sink"; fail=1; }
_dr_probe() { # $1 = blocked, $2 = advisory, $3 = tier -> "<rc>|<reached>|<verdict>"
  local out rc
  # `bash -uc`, matching land-pr.sh's own `set -u`, so the probe models the real
  # thing exactly rather than a laxer shell (Watson).
  out="$(dry_run=1 _DRY_RUN_PARSED=1 pr=0 tier="$3" gate_rows="" landing_blocked="$1" landing_advisory="$2" \
    bash -uc "$(printf '%s\n' 'die() { echo "DIED:$1"; exit 6; }' "$_dr_block" "$_dr_g6" 'echo REACHED-G6')" 2>&1)"; rc=$?
  # The printed VERDICT is asserted too: `elif false` in the report chain left
  # rc and reachability correct while the dry run printed "all gates green" for
  # a run with live FAIL rows — and that string is exactly what /land branches
  # on (Barb, PR #582).
  local said=other
  case "$out" in
    *"all gates green"*)          said=green ;;
    *"landing BLOCKED"*)          said=blocked ;;
    *"STOPPED for adjudication"*) said=stopped ;;
  esac
  case "$out" in
    *REACHED-G6*) printf '%s|MERGED|%s'       "$rc" "$said" ;;
    *DIED:6*)     printf '%s|caught-by-G6|%s' "$rc" "$said" ;;
    *)            printf '%s|no|%s'           "$rc" "$said" ;;
  esac
}
# 0 = clean, 1 = a hard gate blocked, 2 = an advisory stopped. Any non-zero still
# means "do not proceed" for a driving agent; the distinction the prose makes is
# now machine-readable as well, which it was not when both collapsed to 1.
# ⚠ DRIVEN AT EVERY REAL TIER, not the synthetic `tier=x` the first cut used: a
# predicate keyed on `tier` is invisible to a fixture that never produces a tier
# the funnel produces. Measured with Barb's shape — the stop falls through for
# `security` and the sink catches it at `6|caught-by-G6|green`, which is not
# `0|no|green`, so this reddens. Before the sink was in the payload it did not.
_dr_all_clean=1
for _tr in docs code security; do
  [ "$(_dr_probe 0 0 "$_tr")" = "0|no|green" ] \
    && [ "$(_dr_probe 1 0 "$_tr")" = "1|no|blocked" ] \
    && [ "$(_dr_probe 0 1 "$_tr")" = "2|no|stopped" ] || _dr_all_clean=0
done
if [ "$_dr_all_clean" = "1" ]; then
  echo "PASS  the dry-run stop never reaches the merge, and its status distinguishes clean / blocked / advisory (SAD-718)"
else
  echo "FAIL  the dry-run stop reached the code past it, or reported the wrong status/verdict. security tier: clean=$(_dr_probe 0 0 security) blocked=$(_dr_probe 1 0 security) advisory=$(_dr_probe 0 1 security) — expected 0|no|green, 1|no|blocked, 2|no|stopped. A 'MERGED' or 'caught-by-G6' reading means the stop was bypassed"; fail=1
fi
if grep -q 'gate_advise 5 "hidden characters in the title/body CHANGE which issue resolves' "$ROOT/tools/dev/land-pr.sh"; then
  echo "PASS  the sad_hidden branch routes through gate_advise, not a bare note (SAD-718)"
else
  echo "FAIL  the sad_hidden branch no longer calls gate_advise — the signal is back to advisory-only in every mode (SAD-718)"; fail=1
fi
# It must still be computed BEFORE the dry-run stop, or the FAIL row above never
# renders. Same line-order technique as the G4 pins.
_lp="$ROOT/tools/dev/land-pr.sh"
_gh_ln="$(grep -n 'gate_advise 5 "hidden characters' "$_lp" | head -1 | cut -d: -f1)"
_dr_ln="$(grep -n 'land-pr: DRY RUN — PR #\$pr tier=' "$_lp" | head -1 | cut -d: -f1)"
if [ -n "$_gh_ln" ] && [ -n "$_dr_ln" ] && [ "$_gh_ln" -lt "$_dr_ln" ]; then
  echo "PASS  the steering signal is evaluated before the dry-run stop prints (SAD-718)"
else
  echo "FAIL  the sad_hidden row is emitted after the dry-run report (row ${_gh_ln:-?}, report ${_dr_ln:-?}) — it would never appear in a validation run (SAD-718)"; fail=1
fi


# ---------- SAD-740: the controls that cover an UNCOMMITTED edit ----------
# Everything else in this file pins the funnel as CI sees it — committed. The
# incident was an edit that was never committed, so CI never saw it. These
# controls live in land-pr.sh itself and travel with the working copy.

# (1) The startup tripwire. DRIVEN, not grepped: copy the script, break it the
# way the incident broke it, and assert the copy refuses to run at all. The
# mutation is a scoped `sed` that neuters every exit INSIDE the dry-run block
# and nothing else — the same shape as the edit that merged PR #570.
_tw_dir="$(mktemp -d "${TMPDIR:-/tmp}/land-pr-tripwire.XXXXXXXXXX")"
_tw_trap="$(trap -p EXIT)"; trap 'rm -rf "$_tw_dir"' EXIT
cp "$_lp" "$_tw_dir/lp.sh"
sed -i '/^# ---------- dry-run stop ----------$/,/^fi$/{ s/^\( *\)exit [0-9]*$/\1:/ }' "$_tw_dir/lp.sh"
if grep -qE '^[[:space:]]*exit [0-9]+$' <<<"$(sed -n '/^# ---------- dry-run stop ----------$/,/^fi$/p' "$_tw_dir/lp.sh")"; then
  echo "FAIL  the tripwire fixture did not actually neuter the exits — the two rows below would be vacuous"; fail=1
else
  _tw_out="$(bash "$_tw_dir/lp.sh" 0 --dry-run 2>&1)"; _tw_rc=$?
  case "${_tw_rc}|${_tw_out}" in
    1\|*"dry-run stop has no exit statement"*)
      echo "PASS  the startup tripwire refuses to run a locally-broken funnel — the SAD-740 vector, which CI cannot see" ;;
    *) echo "FAIL  a copy of land-pr.sh carrying the SAD-740 edit still ran (rc=$_tw_rc) — the only control covering an UNCOMMITTED edit is gone"; fail=1 ;;
  esac
fi
# The inverse, so the row is not simply always-red: an intact copy gets past it.
case "$(bash "$_lp" 2>&1)" in
  *"dry-run stop has no exit statement"*) echo "FAIL  the tripwire fires on an INTACT script — it would refuse every landing"; fail=1 ;;
  *) echo "PASS  …and an intact script gets past the tripwire (it fails later, on usage, not here)" ;;
esac
rm -rf "$_tw_dir"; eval "${_tw_trap:-trap - EXIT}"

# (2) The merge site's own guard. Pinning the dry-run terminator defends ONE
# statement; a predicate inside that block keyed on something this suite's
# fixture cannot reproduce (`tier`, an env var) reaches G6 anyway — measured at
# 292/0 aimed at security tier. This asserts the sink itself refuses.
if grep -q '^\[ "\$_DRY_RUN_PARSED" != "1" \] || die 6 ' "$_lp"; then
  echo "PASS  G6 refuses to merge when dry_run is set, independently of the stop above (SAD-740)"
else
  echo "FAIL  the merge site has no dry-run guard of its own — a predicate inside the dry-run block that this suite cannot reproduce would fall straight through to the merge"; fail=1
fi

# (3) The flag->variable edge. Every probe INJECTS dry_run=1, so nothing covered
# `--dry-run` actually setting it — and with /land now dry-running every
# landing, `--dry-run) dry_run=0` turns step 1 into an unconditional real run.
if grep -q -- '--dry-run) dry_run=1 ;;' "$_lp"; then
  echo "PASS  --dry-run sets dry_run=1 (the edge every probe injects past)"
else
  echo "FAIL  --dry-run no longer sets dry_run=1 — /land's mandatory dry run would become a real landing"; fail=1
fi

# (4) The REAL gate_fail, driven. Every row that appears to exercise it actually
# exercises a test-local stub — _ga_run, _bg_run and _cfg_tmp each define their
# own — so deleting `landing_blocked=1` from the real one measured 292/0 green.
_gf_src="$(awk '/^gate_fail\(\) \{/,/^\}/' "$_lp")"
if ! grep -q '^gate_fail() {' <<<"$_gf_src"; then
  echo "FAIL  could not extract the real gate_fail — the rows below would be vacuous"; fail=1
else
  _gf_run() { # $1 = dry_run -> "<rows>|<blocked>", or DIED:<gate>
    bash -c "gate_rows=\"\"; landing_blocked=0; dry_run=\"\$1\"
note() { gate_rows=\"\${gate_rows}\$1\"; }
die() { echo \"DIED:\$1\"; exit 9; }
$_gf_src
gate_fail 4 'no marker'
printf '%s|%s' \"\$gate_rows\" \"\$landing_blocked\"" _ "$1" 2>&1
  }
  [ "$(_gf_run 1)" = "G4 FAIL  no marker|1" ] \
    && echo "PASS  the real gate_fail records a row AND sets landing_blocked under --dry-run (SAD-740)" \
    || { echo "FAIL  the real gate_fail no longer blocks under --dry-run — got '$(_gf_run 1)'. Every other row exercises a test-local stub, so this is its only coverage"; fail=1; }
  case "$(_gf_run 0)" in
    DIED:4*) echo "PASS  …and dies on a real run rather than recording a row" ;;
    *) echo "FAIL  the real gate_fail no longer dies on a real run — got '$(_gf_run 0)'"; fail=1 ;;
  esac
fi

# ---------- SAD-694 surface 2: a branch BEHIND its base cannot land ----------
# A green required check certifies THIS BRANCH'S HEAD, not the tree the merge
# produces. Every gate here pins its markers to the branch head — correctly —
# but nothing forced reconciliation with a base that moved, and a behind-but-
# clean branch lands silently. That is how PR #524 nearly shipped seven
# unfloored assertions.
#
# ⚠ THE NEGATIVE PIN IS LOAD-BEARING. `mergeStateStatus == BEHIND` is the
# obvious implementation and it does not work on this repo: GitHub only reports
# BEHIND when branch protection requires up-to-date branches, which this account
# cannot enable (R-INFRA-010's documented 403). Measured on PR #567 while its
# head was genuinely one commit behind main: `mergeStateStatus=UNSTABLE`,
# `mergeable=MERGEABLE`. A future "simplification" to that field would look
# tidier and silently restore the gap.
if grep -q 'gh api "repos/\$REPO/compare/\${base_branch}\.\.\.\${head}" --jq .\.behind_by' "$_lp"; then
  echo "PASS  G2 measures behind-ness with the compare API's behind_by (SAD-694)"
else
  echo "FAIL  G2 no longer reads .behind_by from the compare API — the behind-base gate has no input (SAD-694)"; fail=1
fi
if grep -qE '^[^#]*mergeStateStatus' "$_lp"; then
  echo "FAIL  land-pr.sh reads mergeStateStatus in executable code — it reports BEHIND only under branch protection this account cannot enable, so the gate would be vacuous here (SAD-694)"; fail=1
else
  echo "PASS  the gate does not rest on mergeStateStatus, which is vacuous without branch protection (SAD-694)"
fi
_bg_src="$(awk '/^behind_gate\(\) \{/,/^\}/' "$_lp")"
if ! grep -q '^behind_gate() {' <<<"$_bg_src"; then
  echo "FAIL  could not extract behind_gate() from land-pr.sh — the SAD-694 rows below are vacuous"; fail=1
else
  _bg_run() { # $1 = behind_by fixture -> "<row>|<landing_blocked>"
    bash -c "gate_rows=\"\"; landing_blocked=0; dry_run=1; pr=1; base_branch=main
      note() { gate_rows=\"\${gate_rows}\$1\"\$'\n'; }
      gate_fail() { note \"G\$1 FAIL  \$2\"; landing_blocked=1; }
$_bg_src
behind_gate \"\$1\"
printf '%s|%s' \"\$(printf '%s' \"\$gate_rows\" | cut -c1-7)\" \"\$landing_blocked\"" _ "$1" 2>/dev/null
  }
  bg_case() { # $1 = label, $2 = fixture, $3 = expected
    local got; got="$(_bg_run "$2")"
    [ "$got" = "$3" ] && echo "PASS  $1" \
      || { echo "FAIL  $1 — expected '$3', got '${got:-<empty>}'"; fail=1; }
  }
  bg_case "a branch level with its base passes G2 (SAD-694)"            0     "G2 PASS|0"
  bg_case "a branch 1 commit behind its base is REFUSED (SAD-694)"      1     "G2 FAIL|1"
  bg_case "…and so is one 12 behind — not just an off-by-one (SAD-694)" 12    "G2 FAIL|1"
  # Fail-CLOSED. An unreadable answer must not report the same thing as a clean
  # one; the G7 pre-flight makes the same call for the same reason.
  bg_case "an EMPTY compare answer fails CLOSED (SAD-694)"              ""    "G2 FAIL|1"
  bg_case "a non-numeric compare answer fails CLOSED (SAD-694)"         "n/a" "G2 FAIL|1"
  # `0` is the only clean value: a leading-zero or padded spelling is not
  # silently accepted as "level" by a numeric-looking comparison.
  bg_case "'00' is not accepted as level — the pin is exact (SAD-694)"  "00"  "G2 FAIL|1"
fi
# AND THE GATE IS ACTUALLY INVOKED (Watson, PR #570). Deleting
# `behind_gate "$behind_by"` — keeping the function and the API call — left the
# suite green at exactly its floor: the three rows above cover the function's
# branches, the API call's presence and the mergeStateStatus negative, and none
# of them covers anything CALLING it. Same shape as the sad_hidden call-site
# row, and the same reason it exists.
if grep -q '^behind_gate "\$behind_by"$' "$_lp"; then
  echo "PASS  G2 invokes behind_gate on the measured value (SAD-694)"
else
  echo "FAIL  nothing calls behind_gate — the rows above are true of a function that never runs (SAD-694)"; fail=1
fi
_bg_ln="$(grep -n '^behind_gate "\$behind_by"$' "$_lp" | head -1 | cut -d: -f1)"
_dr2_ln="$(grep -n 'land-pr: DRY RUN — PR #\$pr tier=' "$_lp" | head -1 | cut -d: -f1)"
if [ -n "$_bg_ln" ] && [ -n "$_dr2_ln" ] && [ "$_bg_ln" -lt "$_dr2_ln" ]; then
  echo "PASS  the behind-base gate is evaluated before the dry-run stop prints (SAD-694)"
else
  echo "FAIL  behind_gate runs after the dry-run report (call ${_bg_ln:-?}, report ${_dr2_ln:-?}) — a behind branch would never show a row in a validation run (SAD-694)"; fail=1
fi

# The PR's OWN base, not the configured default branch: a stacked PR compared
# against `main` reports a distance that is real but irrelevant, and would block
# forever.
if grep -q 'base_branch="\$(jq -r .\.baseRefName // empty. <<<"\$pr_json")"' "$_lp"; then
  echo "PASS  the behind-check measures against the PR's own base ref (SAD-694)"
else
  echo "FAIL  base_branch is no longer read from the PR's baseRefName — a stacked PR would be compared against the wrong ref (SAD-694)"; fail=1
fi

echo "RESULT: $([ "$fail" = "0" ] && echo "tier classification + SAD resolution OK" || echo "LAND-PR SELFTESTS BROKEN")"
exit "$fail"
