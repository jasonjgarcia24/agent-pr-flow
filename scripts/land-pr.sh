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

# ---------- locale: pin the CTYPE, deliberately not the collation ----------
# `\b` is an LC_CTYPE predicate, and this script inherits the caller's locale.
# Under a C ctype a non-ASCII byte stops counting as a word character, so the
# G8 anchor guard's word boundary fires MID-WORD and "präfixes SAD-7" resolves
# as a closing anchor — a wrong-issue write, live in production for any caller
# with a stripped environment (bare container, systemd unit, CI shell with no
# LANG). Verified on glibc 2.39: LC_ALL=C, LANG=C and LC_CTYPE=C all reproduce.
#
# C.UTF-8, NEVER C — C.UTF-8 keeps a UTF-8 ctype; C is what widens \b.
#
# The `unset LC_ALL` is load-bearing and NOT optional: LC_ALL OUTRANKS LC_CTYPE,
# so `export LC_CTYPE=C.UTF-8` alone is silently defeated by an inherited
# LC_ALL=C — which is the most likely hostile case, since LC_ALL=C is the
# canonical way a script or CI job strips locale. Verified: with LC_ALL=C in the
# environment, the ctype-only form still yields the false anchor.
#
# LC_COLLATE is left to the caller ON PURPOSE. Pinning it too (LC_ALL=C.UTF-8)
# would also mask the `grep -o` range-extent defect, which would make the
# enumerated digit classes below look redundant and invite their removal — the
# enumeration is the load-bearing fix for that half and must stay so.
# ⚠ THREE collation-dependent ORDERING operations (`sort` / `uniq` / `[[ < ]]`),
# each pinned `LC_ALL=C` AT ITS OWN CALL SITE rather than here, so the pin covers
# `sort` alone and leaves this preamble's LC_CTYPE reasoning intact:
#   1. the G3 `sort -u` deriving the classified path list;
#   2. `_marker_prime`'s `sort -u` over marker-author logins — a locale that
#      collates two distinct logins equal would drop one permission lookup;
#   3. `untrusted_marker_authors`' `sort -u` over the reported-author list.
# Any new ordering operation pins its own call site AND is named here. This
# enumeration has already been wrong once: (2) and (3) were added unpinned and
# the claim above still said "exactly one" (Barb LOW-3, PR #547).
#
# ⚠⚠ RANGE EXPRESSIONS ELSEWHERE ARE ALSO COLLATION-ORDERED, and they are
# deliberately left unpinned — which is exactly WHY the digit classes in this file
# are ENUMERATED rather than ranged (SAD-551). Live ones today: `*[!A-Za-z0-9_/-]*`
# (branch-name check), `*[!a-z-]*` (marker-name check), and the `[A-Z_]+` /
# `[0-9a-f]{40}` / `(^|[^A-Za-z0-9])` classes in the marker and SAD-id greps. Do
# NOT read this block as saying ranges are locale-safe here, and do NOT "simplify"
# `SAD-[0123456789]+` back to `[0-9]` — that re-introduces the very defect this
# preamble exists to prevent.
#   Provenance, because an earlier round had this RIGHT and a later one broke it:
#   round 6 said "no collation-dependent operations (no sort/uniq/[[ < ]])" — TRUE,
#   because the parenthetical scoped it to ordering. Round 7 rewrote it as "exactly
#   ONE collation-dependent operation", dropping the scoping from the CLAIM while
#   keeping it only in the forward-looking instruction: a wider assertion over a
#   narrower enumeration, with the counter-examples above sitting in the same file.
#   Watson Important, PR #399 / SAD-551 and PR #458 delta.
#
# ⚠ TEST SEAM, and it exists because the obvious way to test the other branch
# does not work. `_sad_visible` has two arms and the `else` one runs only where
# this probe FAILS — i.e. on a box with no C.UTF-8. Running the suite under
# `LC_ALL=C` does NOT reach it: the probe still succeeds here, the pin still
# applies, and the UTF-8 arm still runs. Measured — reverting the `else` arm to a
# bare `_sad_strip_comments` (deleting half the SAD-655 filter) leaves every
# `LC_ALL=C` row GREEN, which is why that arm carried one assertion for months
# and why "add hostile-locale rows" was not by itself the fix.
# `LAND_PR_NO_UTF8_CTYPE=1` simulates the absent locale FAITHFULLY: the probe is
# skipped entirely, so the caller's `LC_ALL=C` survives and LC_CTYPE is never
# pinned, exactly as on a box without C.UTF-8.
# Gated behind LAND_PR_TEST=1 like the other two seams — and, unlike them, it
# needs no `die`: without that gate the flag is simply ignored and the STRONG
# path runs, so the failure mode of forgetting it is fail-safe by construction.
SAD_UTF8_CTYPE=0
if [ "${LAND_PR_NO_UTF8_CTYPE:-0}" = "1" ] && [ "${LAND_PR_TEST:-0}" = "1" ]; then
  : # leave SAD_UTF8_CTYPE=0 and the caller's locale exactly as inherited
elif [ "$(LC_ALL=C.UTF-8 locale charmap 2>/dev/null)" = "UTF-8" ]; then
  unset LC_ALL
  export LC_CTYPE=C.UTF-8
  SAD_UTF8_CTYPE=1
fi

# ---------- G0: prereqs ----------
die() { echo "land-pr [G$1]: FAIL — $2" >&2; exit 1; }

# ⚠ SELF-CHECK, BEFORE ANY GATE — the one control that travels with an
# UNCOMMITTED edit (Barb, PR #582 HIGH-2). Every other pin on the dry-run
# terminator lives in tools/dev/test-land-pr.sh, which CI runs on COMMITTED
# content — and the 2026-08-12 incident was an edit that was never committed:
# `main` never carried the broken line, CI never saw it, and the funnel merged a
# security-tier PR with both marker gates showing FAIL in its own table. A suite
# that is not in the execution path cannot cover the execution path.
#
# So this greps its own source for the dry-run terminator and refuses to run
# without it. It is deliberately dumb and deliberately here, above everything:
# by the time any gate has an opinion, the fall-through has already been armed.
_self="${BASH_SOURCE[0]}"
# ⚠ `exit` FOLLOWED BY ANYTHING, not a numeric literal (Watson, PR #582). The
# first cut demanded `exit <digits>` while tools/dev/test-land-pr.sh's structural
# pin accepts any `exit `, so the two disagreed about what a valid terminator is
# — and `exit $(( landing_blocked != 0 || landing_advisory != 0 ))`, the form
# THIS SCRIPT SHIPPED one commit earlier, passed the suite and bricked the
# script. The numeric requirement bought no incident coverage: the edit that
# merged PR #570 had no exit at all.
if [ -r "$_self" ] && ! grep -qE '^[[:space:]]*exit([[:space:]]|$)' <<<"$(sed -n '/^# ---------- dry-run stop ----------$/,/^fi$/p' "$_self")"; then
  echo "land-pr [G0]: FAIL — this script's dry-run stop has no exit statement, so --dry-run would FALL THROUGH TO THE MERGE. That is the 2026-08-12 incident (SAD-740); refusing to run. Restore it with: git -C \"\$(git rev-parse --show-toplevel)\" checkout -- tools/dev/land-pr.sh" >&2
  exit 1
fi

pr="${1:-}"
watch=0
dry_run=0
# `_DRY_RUN_PARSED` is set once from the parsed flag and never written again, so
# G6's guard reads a value the dry-run block cannot reach (Barb, PR #582). Both
# guards previously read the mutable `dry_run`, so one line inside the block
# (`dry_run=0`) defeated both at once — two checks of one variable is not two
# controls. Assigned after the arg loop below.
shift 2>/dev/null || true
for arg in "$@"; do
  case "$arg" in
    --watch) watch=1 ;;
    --dry-run) dry_run=1 ;;
    *) die 0 "unknown argument: $arg (usage: land-pr.sh <PR#> [--watch] [--dry-run])" ;;
  esac
done
readonly _DRY_RUN_PARSED="$dry_run"

# SAD-id digit classes are ENUMERATED ([0123456789]), never the range [0-9].
# This is a live bug fix in THIS box's locale, not a portability nicety — do not
# "simplify" it back to [0-9]. GNU grep 3.11 under en_US.UTF-8 overruns the
# reported MATCH EXTENT of a range bracket expression when a non-ASCII decimal
# digit follows an ASCII one, so `grep -o` EMITS the trailing garbage:
#
#   printf 'Fixes SAD-538\xd9\xa5'  (U+0665 ARABIC-INDIC DIGIT FIVE)
#     grep -oE 'SAD-[0-9]+'         -> SAD-538<d9 a5>   (malformed id)
#     grep -oE 'SAD-[0123456789]+'  -> SAD-538          (clean truncation)
#
# It is NOT class membership — `grep -qE 'SAD-0[0-9] '` correctly does NOT match
# the same bytes. That distinction matters here because _sad_anchor_ids is built
# entirely on `grep -o`, so the EXTRACTED ID is what gets corrupted. 513 of the
# 670 non-ASCII Unicode Nd codepoints leak through the range in a NON-LEADING
# position (0 in a leading one, which is why a leading-only sweep misses it);
# 0 leak through the enumerated class. Same 513 under en_GB.utf8; 0 under C.
#
# `LC_ALL=C` also stops the leak, but it is the WRONG tool: it changes LC_CTYPE
# too, which widens `\b` — under LC_ALL=C "präfixes SAD-7" IS read as a closing
# anchor (the non-ASCII byte stops counting as a word character), reopening the
# exact wrong-issue write the \b guard below closes. Enumerating fixes the
# extent bug without touching LC_CTYPE. Both properties are pinned in
# tools/dev/test-land-pr.sh. Barb, PR #399 / SAD-551.
#
# Scope: this rule covers the SAD-id classes and the PR-number gate. The marker
# and config validators below deliberately keep ranges ([A-Z_]+ sha=[0-9a-f]{40}
# at the verdict reader, *[!A-Za-z0-9_/-]* on git.defaultBranch, *[!a-z-]* on
# marker names). Those are safe for a different reason: each is a fixed-width or
# NEGATED validator that FAILS CLOSED — a widened extent there yields a
# non-matching marker or a rejected config value, never a forged pass.
grep -qE '^[0123456789]+$' <<<"$pr" || die 0 "PR number required (got: '${pr}')"
command -v jq >/dev/null 2>&1 || die 0 "jq missing"
# awk is a hard prereq of the G8 anchor picker (de-duplication). Without it the
# picker silently yields nothing and the close-out degrades to `fallback` —
# naming a RELATED issue as the closed one, which is the failure SAD-538 fixed.
# Fail loud instead of fail-quiet. Barb Info, PR #399 / SAD-551.
command -v awk >/dev/null 2>&1 || die 0 "awk missing (the G8 SAD-anchor picker de-duplicates through it)"
# The LAND_PR_SELFTEST classifier and the LAND_PR_SADTEST picker
# (tools/dev/test-land-pr.sh) need only jq + the config; skip the gh-dependent
# checks so they run OFFLINE in CI (SAD-257 (c), SAD-538).
if [ "${LAND_PR_SELFTEST:-0}" != "1" ] && [ "${LAND_PR_SADTEST:-0}" != "1" ]; then
  command -v gh >/dev/null 2>&1 || die 0 "gh missing"
  gh auth status >/dev/null 2>&1 || die 0 "gh not authenticated"
  REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner)" || die 0 "cannot resolve repo (no origin remote?)"
fi

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
# LAND_PR_SADTEST is held to a STRICTER bar than its sibling seams: it
# short-circuits to a pure-function probe and exits 0 without evaluating a single
# gate, so --dry-run is NOT acceptable authorization for it. A dry run is an
# ATTESTATION surface — `LAND_PR_SADTEST=1 land-pr.sh <N> --dry-run` would report
# success where the genuine dry run reports BLOCKED. Requiring LAND_PR_TEST=1
# (which pre-bash-safety.sh D0 refuses inline) keeps the seam unreachable without
# tripping the hook. Barb MEDIUM / Watson Important, PR #399.
if [ "${LAND_PR_SADTEST:-0}" = "1" ] && [ "${LAND_PR_TEST:-0}" != "1" ]; then
  die 0 "LAND_PR_SADTEST is test-only and skips every gate — a real run refuses it (set LAND_PR_TEST=1 for tests)"
fi

# ---------- SAD issue resolution (SAD-538) ----------
# G8's close-out names the issue(s) a PR CLOSES, so it must read the `Fixes
# SAD-N` anchor — NOT the first SAD-N appearing anywhere in the title/body.
# The project's PR convention cites related issues as background ABOVE the
# closing line (R-ID lineage, "same defect class as SAD-N", "supersedes the
# first bullet of SAD-N"), while `Fixes SAD-N` sits at the very bottom — so
# first-match systematically named a RELATED issue instead of the closed one.
# It fired on 4/4 landings in a single session (2026-07-30, PRs
# #384/#388/#390/#392); three named already-Done issues (silent no-op), the
# fourth named SAD-488, which was actively In Progress. Nothing automated acts
# on the hint today, but it instructs a human or an agent to mark the wrong
# issue complete — a wrong-issue state write.
#
# Keywords mirror GitHub's closing set (close/closes/closed, fix/fixes/fixed,
# resolve/resolves/resolved), optional colon, case-insensitive, `\b`-anchored so
# "prefixes SAD-1" is not read as a closing anchor.

# ---- reviewer-visible text (SAD-589) ----
# The PR body is UNTRUSTED INPUT to the merge funnel — anyone who can open a PR
# controls it — so it is validated at the boundary rather than matched raw.
# Matching raw bytes honoured text that is INVISIBLE in GitHub's rendered view,
# which let an author steer which issue the close-out names, with `anchor`
# provenance (the high-confidence label that prints WITHOUT the VERIFY warning):
#
#   "<!-- Fixes SAD-666 -->\nBackground: …\n\nFixes SAD-538"
#     -> SAD-666 named FIRST; the comment renders as nothing
#   "Fixes SAD-5<U+200B>38"          -> SAD-5      (a human reads SAD-538)
#   "…relates to SAD-999.\n\nFixes SAD-<U+200B>538"
#     -> fallback SAD-999; the real anchor is destroyed and a decoy wins
#
# That is the wrong-issue state write SAD-538 exists to prevent, reached through
# input its fix did not consider. Two filters, in order:
#   1. HTML comments — removed across LINE BOUNDARIES (an anchor can be split
#      over several lines inside one comment). Done in awk, which is already a
#      hard prereq (G0), accumulating the whole text rather than using a
#      non-portable RS.
#   2. Unicode format characters (Cf) — zero-width space/joiners, bidi controls,
#      word joiner, BOM, soft hyphen. These are invisible to a reviewer, so they
#      must not be able to split an id or a keyword.
# LC_CTYPE is pinned to C.UTF-8 at the top of this script, which is what makes
# the multibyte bracket expression below match whole characters rather than bytes.
#
# \u26a0 THE SETS ARE HEX CODEPOINT LISTS, and everything downstream is DERIVED from
# them. Never literal characters \u2014 invisible codepoints in the source of the
# script that gates every merge are unreviewable by eye and undiffable (Watson) \u2014
# and no longer even `$'\uXXXX'` string literals, because each set now has to
# produce TWO artifacts that must never drift apart:
#   * the sed bracket expression that classifies the literal character, and
#   * the ERE alternation of that codepoint's HTML numeric-reference spellings
#     (`&#8203;`, `&#x200B;`, leading zeros, either hex case).
# The first cut hand-wrote the entity list, so 12 of the 16 `_SAD_ZS` codepoints
# had no entity spelling at all and NONE of the `_SAD_CF` ones did \u2014 `Fixes
# SAD-5&#8203;38` renders as `SAD-538` to a reviewer and resolved `anchor SAD-5`
# with no flag, the SAD-589 silent wrong-issue write reopened one encoding layer
# up (Watson CRITICAL, PR #547). Generating both artifacts from one list is what
# makes "add a codepoint, get its escapes for free" structural instead of a thing
# someone has to remember.
# U+000C FORM FEED is Cc, not Cf, and sits here as a DELIBERATE JUDGEMENT CALL
# rather than because it renders as nothing — an earlier comment claimed it
# renders GLUED and that was wrong, read off a terminal that swallowed the byte.
# `POST /markdown` emits `<p>Fixes\x0cSAD-538</p>`, FF intact; the BROWSER then
# decides, and CSS Text does not collapse form feed, so Chrome 151 draws a
# visible control glyph (~5.3px). Neither classification is "what renders":
# delete yields `fallback … hidden`, space yields `anchor … hidden`, and BOTH
# are loud. Delete is the conservative one — it declines to treat an exotic,
# font-dependent glyph as a word separator, so the close-out names nothing on its
# own authority. Pinned by behaviour in tools/dev/test-land-pr.sh, never by this
# prose (Barb LOW, PR #547).
_SAD_CF_CP='200b 200c 200d 200e 200f 2060 2061 2062 2063 2064 2066 2067 2068 2069
            feff 00ad 061c 180e 202a 202b 202c 202d 202e 034f 115f 1160 3164 ffa0
            2800 fe0f 206f fff9 fffa fffb 000c'
# Unicode space separators are NORMALIZED to an ASCII space rather than deleted:
# the anchor regex uses [[:space:]], which does not include NBSP under C.UTF-8,
# so `Fixes<NBSP>SAD-538` silently fell through to `fallback` and an author-chosen
# decoy won. Normalizing is the fix; widening the class is not (it would also
# widen every other [[:space:]] use in the anchor).
_SAD_ZS_CP='00a0 2000 2001 2002 2003 2004 2005 2006 2007 2008 2009 200a 202f 205f
            3000 1680'
# ---- ASCII whitespace, ENTITY SPELLINGS ONLY (Barb HIGH-2, PR #547) ----
# These four are already `[[:space:]]`, so a LITERAL one needs no normalization
# and none of them belongs in the bracket expression above. Their REFERENCES do:
# `&#10;` was the hole. It decodes to a real LF, which SPLITS THE RECORD — and
# `_sad_ids_of` is line-oriented `grep` — so neither the visible text nor `_raw`
# carried an anchor, every `sad_hidden` clause saw agreement, and a decoy won in
# SILENCE. Measured: GitHub renders `Fixes&#10;SAD-538` as `<p>Fixes\nSAD-538</p>`,
# which a reviewer reads as `Fixes SAD-538`. Same for `&#010;`, `&#x0A;`, `&#13;`.
#
# ⚠ KEPT OUT OF `_SAD_ZS_CP` DELIBERATELY, and not as a style choice: `_SAD_ZS` is
# interpolated into `sed "s/[$_SAD_ZS]/ /g"`, so a codepoint that is a RECORD
# TERMINATOR would put a literal newline inside the sed program and break the
# script outright. Splitting the list is what keeps the generated bracket safe
# while still generating every entity spelling.
_SAD_WS_CP='0009 000a 000d 0020'

# \u26a0 Both derivations write through `printf -v <name>` rather than returning on
# stdout, and are called once at load. `$( )` would fork this whole script four
# times on EVERY invocation \u2014 including a real landing, which does not resolve a
# SAD id until G8 \u2014 and the regression suite spawns land-pr.sh once per
# assertion, so four gratuitous forks per row is the difference between a 2- and
# a 4-minute CI step. Same reason `printf -v hex` replaces `$(printf '%x')`.
_sad_chars() { # $1 = target var name, $2 = hex codepoints -> literal chars
  local cp fmt=""
  for cp in $2; do fmt="$fmt\\u$cp"; done
  printf -v "$1" "$fmt"
}
# Every numeric-character-reference spelling GFM accepts for one codepoint:
# decimal and hex, leading zeros allowed, `x` and the hex digits in either case.
# Semicolon required (added by the caller) \u2014 GFM does not accept the bare form.
_sad_entity_alt() { # $1 = target var name, $2 = hex codepoints -> `#0*NNN|#[Xx]0*HH|\u2026`
  local cp dec hex hpat i c out=""
  for cp in $2; do
    dec=$((16#$cp))
    printf -v hex '%x' "$dec"
    hpat=""
    for ((i = 0; i < ${#hex}; i++)); do
      c="${hex:i:1}"
      case "$c" in
        [a-f]) hpat="${hpat}[${c^}$c]" ;;   # braces: `$hpat[` reads as an array index
        *)     hpat="$hpat$c" ;;
      esac
    done
    out="$out|#0*$dec|#[Xx]0*$hpat"
  done
  printf -v "$1" '%s' "${out#|}"
}
_sad_chars      _SAD_CF     "$_SAD_CF_CP"
_sad_chars      _SAD_ZS     "$_SAD_ZS_CP"
_sad_entity_alt _SAD_CF_ENT "$_SAD_CF_CP"
# The ZS alternation spans BOTH lists — the Unicode separators, whose literal
# form the bracket above also handles, and the ASCII whitespace whose literal
# form needs no handling at all. Only the entity side is shared.
_sad_entity_alt _SAD_ZS_ENT "$_SAD_ZS_CP $_SAD_WS_CP"
# NAMED references cannot be generated from a codepoint, so they stay explicit
# and stay SHORT. Only spellings the WHATWG table actually defines, semicolon
# required, and only codepoints already in the set above \u2014 a name that resolves
# to something the sets do not classify would be decoded into a character nothing
# then handles, which is worse than leaving it alone. Case-SENSITIVE per the
# table. Residual: the full named table is ~2100 entries and this is not it; the
# numeric halves above are total, which is the half an attacker reaches for.
_SAD_ZS_NAMED='nbsp|NonBreakingSpace|ensp|emsp|emsp13|emsp14|numsp|puncsp|thinsp|ThinSpace|hairsp|VeryThinSpace|MediumSpace'
_SAD_CF_NAMED='ZeroWidthSpace|NegativeVeryThinSpace|zwnj|zwj|lrm|rlm|shy|NoBreak'

# HTML-comment removal, implementing CommonMark's ACTUAL rule with index()
# rather than a regex. The regex form could not match a comment closed with
# `--->` (three or more dashes), and `markdown-it` in commonmark mode passes
# `<!-- x --->` through as raw HTML, so the browser ends the comment at the
# first `-->` and the text is invisible in the rendered PR — the SAD-589
# steering vector again, with `anchor` provenance and the VERIFY warning
# suppressed. index() has no alternation subtleties (Watson).
#
# Three cases, all measured against the resolver:
#   paired `-->`   remove the comment
#   `--!>`         HTML5 treats this as a comment end too, and the text after it
#                  RENDERS — so it terminates here as well, or a visible anchor
#                  would be swallowed (a false negative, the dangerous direction)
#   `<!-->`        per CommonMark 0.30+ (and HTML5) this is a COMPLETE, empty
#   `<!--->`       comment: the `>` / `->` immediately after the opener closes it,
#                  so everything AFTER it RENDERS. Neither contains `-->` or
#                  `--!>`, so the loop below used to read them as UNTERMINATED and
#                  strip to EOF — swallowing a reviewer-visible anchor. That is
#                  the false-negative direction the `--!>` case above exists to
#                  rule out, reached through a shape nobody enumerated. It never
#                  went SILENT (the anchor-set diff still raised HIDDEN), but a
#                  loud wrong answer is still a wrong answer. (SAD-655 item 4)
#   UNTERMINATED   per CommonMark, an unclosed `<!--` makes everything to EOF raw
#                  HTML — invisible. So it is stripped to EOF, which is what a
#                  reviewer actually sees. This shape needs no exotic codepoints
#                  at all: a missing `-->` reads as a typo (Barb).
_sad_strip_comments() {
  awk '
    { buf = buf $0 "\n" }
    END {
      out = ""
      while ((s = index(buf, "<!--")) > 0) {
        out = out substr(buf, 1, s - 1)
        rest = substr(buf, s + 4)
        # The two zero-length forms, tested BEFORE the paired-terminator search:
        # `<!-->` closes on the bare `>`, `<!--->` on the `->`. Checked in this
        # order because `->` is a prefix-extension of neither and `>` would
        # otherwise never be reached for `<!--->`. (SAD-655 item 4)
        if (substr(rest, 1, 1) == ">")  { buf = substr(rest, 2); continue }
        if (substr(rest, 1, 2) == "->") { buf = substr(rest, 3); continue }
        e  = index(rest, "-->")
        e2 = index(rest, "--!>")
        if (e2 > 0 && (e == 0 || e2 < e)) { buf = substr(rest, e2 + 4); continue }
        if (e == 0) { buf = ""; break }
        buf = substr(rest, e + 3)
      }
      printf "%s", out buf
    }'
}

# ---- markdown LINK-REFERENCE DEFINITIONS (SAD-655 item 2) ----
# `[//]: # (Closes SAD-999)` is the canonical "markdown comment" idiom. It is a
# link-reference definition: it defines a label, emits NOTHING into the rendered
# document, and — unlike an HTML comment — contains no `<!--`, so the stripper
# above never saw it. Its raw text is therefore IDENTICAL to its filtered text,
# which means the anchor-set trigger cannot fire either, and it carries no
# non-ASCII byte for the positional trigger. Combined with a whitespace HTML
# ENTITY destroying the *visible* anchor (below), a PR resolved to an issue the
# reviewer never saw, with `anchor` provenance and the VERIFY warning suppressed.
# Barb verified the rendering against GitHub's own `POST /markdown`.
#
# Line-oriented on purpose: a link-reference definition is a leaf block, so it
# occupies whole lines.
#
# ⚠ THE STRIP IS A DELETION, so getting it WRONG DELETES TEXT GITHUB RENDERS —
# a false negative that hides a reviewer-visible anchor, the exact direction the
# `--!>` case in the comment stripper exists to rule out. The first cut of this
# filter was a one-line `grep -vE '^[[:space:]]{0,3}\[[^]]*\][[:space:]]*:'` and
# it was wrong in THREE measured ways (Barb, PR #547 pre-landing audit). All
# three rendered `<p>…[ref]: Fixes SAD-538…</p>` or `<pre><code>…</code></pre>`
# through GitHub's own `POST /markdown`, i.e. the reviewer sees them:
#
#   \t[ref]: Fixes SAD-538       `[[:space:]]{0,3}` accepts ONE TAB, but a tab is
#                                FOUR columns — an indented CODE BLOCK. Only
#                                literal SPACES count toward the 0–3 bound, hence
#                                `ind` below counts spaces and nothing else.
#   Note:                        CommonMark: a link reference definition CANNOT
#   [ref]: Fixes SAD-538         INTERRUPT A PARAGRAPH. After paragraph text this
#                                is ordinary continuation text.
#   ```                          Inside a FENCED code block nothing is a leaf
#   [ref]: Fixes SAD-538         block — the fence's content renders verbatim.
#   ```
#
# So this is a small block-context state machine rather than a per-line regex.
# `can_def` is "a leaf block may START on this line", which is true at the start
# of the document, after a blank line, after an ATX heading or thematic break,
# after a fenced block closes, inside/after an indented code block, and — per
# CommonMark — after ANOTHER link reference definition, since consecutive
# definitions are all definitions.
#
# Written without regex interval expressions (`{0,3}`, `#{1,6}`) on purpose: awk
# here is mawk, whose interval support is version-dependent, and a silently
# non-matching interval would turn the strip into a no-op — a vacuous filter that
# still reports success. Leading-space counting and run lengths are explicit.
#
# DIRECTIONS, so a future narrowing is judged against the right hazard:
#   over-strip  (deleting rendered text) -> hides a VISIBLE anchor -> the decoy
#               wins by `fallback`. This is what the three rows above were.
#   under-strip (keeping an invisible definition) -> its anchor counts, matches
#               the raw text, so no `hidden` flag fires -> the SILENT wrong-issue
#               write SAD-655 is about.
# Both are live defects; neither is "the safe side" — but they are not symmetric,
# and the asymmetry decides every ambiguous case here: an over-strip is LOUD (the
# anchor set changes, so `hidden` fires and provenance degrades to `fallback`),
# an under-strip is SILENT. So when this filter cannot tell, it DROPS.
#
# Known under-strip residuals, all tracked on SAD-705 and all identical on
# origin/main: a definition inside a blockquote or a list item; a multi-line
# definition whose destination/title wrap onto following lines; a definition
# directly under a setext `===` underline; the `<!` / `<?` / `<![CDATA[`
# productions; and a fully bidi-reversed id. The durable fix is not a further
# rule here — it is to resolve against a real CommonMark render (SAD-705).
#
# Runs AFTER the comment strip, not before: the comment strip implements the
# raw-HTML-to-EOF rule, and a line dropped ahead of it could have carried the
# `<!--` that hides the remainder. It also means a definition revealed by a
# comment removal (text glued across the boundary) is still seen.
#
# No `|| true`: unlike the `grep -v` this replaced (which exits 1 when it emits
# nothing), awk exits 0 on an all-definitions body — a legitimate empty result.
_sad_strip_linkrefs() {
  LC_ALL=C awk '
    # leading SPACES only — a tab is 4 columns, never part of the 0-3 bound
    function indent_of(s,   n) { n = 0; while (substr(s, n + 1, 1) == " ") n++; return n }
    function runlen(s, c,   n) { n = 0; while (substr(s, n + 1, 1) == c) n++; return n }
    # 3+ of the SAME  - * _  , spaces/tabs allowed between them, nothing else
    function thematic(s,   t, c, i) {
      t = s; gsub(/[ \t]/, "", t)
      if (length(t) < 3) return 0
      c = substr(t, 1, 1)
      if (c != "-" && c != "*" && c != "_") return 0
      for (i = 1; i <= length(t); i++) if (substr(t, i, 1) != c) return 0
      return 1
    }
    # Inline code spans removed, so a footnote reference that only ever appears
    # inside one does not count as live. Verified against POST /markdown: a
    # reference in a code span does NOT cause the definition to render.
    function strip_spans(s,   out, n, e) {
      out = ""
      while ((n = index(s, "`")) > 0) {
        out = out substr(s, 1, n - 1)
        s = substr(s, n + 1)
        e = index(s, "`")
        if (e == 0) { s = ""; break }
        s = substr(s, e + 1)
      }
      return out s
    }
    # ⚠ CommonMark: after the destination, NO further character may appear unless
    # it is a valid title. `[ref]: Fixes SAD-538` therefore has destination
    # `Fixes` and an unquoted trailer — it is NOT a definition and it RENDERS.
    # Verified against POST /markdown: `<p>[ref]: Fixes SAD-538</p>`. Dropping it
    # deleted a reviewer-visible anchor and named the wrong issue (Watson, #547).
    function valid_linkref(s,   t, n, c, d) {
      t = substr(s, index(s, "]") + 1)
      sub(/^[ \t]*:/, "", t)
      sub(/^[ \t]+/, "", t)
      if (t == "") return 1                    # destination on a later line
      if (substr(t, 1, 1) == "<") {
        n = index(t, ">"); if (n == 0) return 0
        t = substr(t, n + 1)
      } else {
        n = 0
        while (n < length(t) && substr(t, n + 1, 1) != " " && substr(t, n + 1, 1) != "\t") n++
        t = substr(t, n + 1)
      }
      sub(/^[ \t]+/, "", t)
      if (t == "") return 1                    # destination only
      c = substr(t, 1, 1)
      if (c == "\"") d = "\""
      else if (c == "\047") d = "\047"
      else if (c == "(") d = ")"
      else return 0                            # a trailer that is not a title
      n = index(substr(t, 2), d); if (n == 0) return 0
      return (substr(t, n + 2) ~ /^[ \t]*$/)
    }
    { line[NR] = $0 }
    END {
      # ---- PASS 1: which footnote labels are actually REFERENCED ----
      # ⚠ A GFM footnote definition renders ONLY when a matching `[^label]`
      # reference exists somewhere in the same document; GitHub drops an ORPHAN
      # entirely. Keeping orphans unconditionally made their `SAD-N` a live
      # anchor in the visible text while the reviewer saw nothing — pure ASCII,
      # identical in `_raw`, so all four `sad_hidden` clauses stayed silent
      # (Barb HIGH-1). A reference before OR after the definition counts; one
      # inside a code span or a fenced block does not.
      f = ""; fl = 0
      for (i = 1; i <= NR; i++) {
        s = line[i]; ind = indent_of(s); rest = substr(s, ind + 1)
        if (f != "") {
          if (ind <= 3 && substr(rest, 1, 1) == f && runlen(rest, f) >= fl \
              && substr(rest, runlen(rest, f) + 1) ~ /^[ \t]*$/) f = ""
          continue
        }
        if (ind <= 3 && (substr(rest, 1, 3) == "```" || substr(rest, 1, 3) == "~~~")) {
          f = substr(rest, 1, 1); fl = runlen(rest, f); continue
        }
        t = strip_spans(s)
        while ((n = index(t, "[^")) > 0) {
          t = substr(t, n + 2)
          e = index(t, "]")
          if (e == 0) break
          # A `]` followed by `:` is the DEFINITION itself, not a reference to it.
          if (substr(t, e + 1, 1) != ":") ref[substr(t, 1, e - 1)] = 1
          t = substr(t, e + 1)
        }
      }
      # ---- PASS 2: the strip ----
      fence = ""; flen = 0; can_def = 1
      for (i = 1; i <= NR; i++) {
        s = line[i]
        ind  = indent_of(s)
        rest = substr(s, ind + 1)
        # (1) inside a fenced block: verbatim, and only a matching closer ends it
        if (fence != "") {
          if (ind <= 3 && substr(rest, 1, 1) == fence && runlen(rest, fence) >= flen \
              && substr(rest, runlen(rest, fence) + 1) ~ /^[ \t]*$/) { fence = ""; can_def = 1 }
          print s; continue
        }
        # (2) blank line — the canonical block boundary
        if (s ~ /^[ \t]*$/) { can_def = 1; print s; continue }
        # (3) fence OPEN. Deliberately not guarded by can_def: fenced code is one
        #     of the constructs that CAN interrupt a paragraph.
        if (ind <= 3 && (substr(rest, 1, 3) == "```" || substr(rest, 1, 3) == "~~~")) {
          fence = substr(rest, 1, 1); flen = runlen(rest, fence); can_def = 0
          print s; continue
        }
        # (4) THE DROP. can_def is what implements "cannot interrupt a paragraph";
        #     it is left ALONE on a drop so a run of consecutive definitions all go.
        if (can_def && ind <= 3 && rest ~ /^\[[^]]*\][ \t]*:/) {
          if (rest ~ /^\[\^/) {
            # GFM footnote definition: renders only if its label is referenced.
            e = index(rest, "]")
            if (substr(rest, 3, e - 3) in ref) { can_def = 1; print s; continue }
            continue                           # orphan — GitHub drops it, so do we
          }
          if (valid_linkref(rest)) continue     # a real definition renders nothing
          print s; can_def = 0; continue        # invalid — it renders as paragraph text
        }
        # (5) ATX heading (1-6 #, then space/tab/EOL) — also interrupts a paragraph
        hn = runlen(rest, "#")
        if (ind <= 3 && hn >= 1 && hn <= 6 && substr(rest, hn + 1) ~ /^([ \t].*)?$/) {
          can_def = 1; print s; continue
        }
        # (6) thematic break / setext `---` underline. `===` is NOT handled — a
        #     definition directly under one stays, silently (SAD-705).
        if (ind <= 3 && thematic(rest)) { can_def = 1; print s; continue }
        # (7) indented code block: 4+ spaces, or a leading TAB, where a block may
        #     start. A definition can still open on the line that ENDS it, so
        #     can_def is carried through unchanged.
        if (can_def && (ind >= 4 || substr(s, 1, 1) == "\t")) { print s; continue }
        # (8) paragraph text — nothing may be a definition until the next boundary
        print s; can_def = 0
      }
    }'
}

# ---- HTML CHARACTER REFERENCES (SAD-655 item 2; Watson CRITICAL, PR #547) ----
# `Fixes&nbsp;SAD-538` RENDERS as `Fixes SAD-538`, but `&nbsp;` is literal ASCII
# text to `[[:space:]]`, so the anchor was dropped and an author-chosen decoy won
# via `fallback` — the same defect as the raw NBSP that `_SAD_ZS` normalizes, one
# encoding layer up.
#
# ⚠ THE FIRST CUT DECLARED A DIVISION OF LABOUR THAT DID NOT EXIST. Its comment
# said `&#8203;` "and friends render as nothing and belong to the `_SAD_CF` half"
# — but NOTHING decoded entities into `_SAD_CF`, so no half handled them, and the
# unhandled side was the SILENT one. Measured against GitHub's `POST /markdown`:
# `Fixes SAD-5&#8203;38` renders `SAD-5<ZWSP>38`, the reviewer reads SAD-538, and
# the resolver returned `anchor SAD-5` with NO flag. Same for `&#x200B;`,
# `&#65279;` (BOM), and `&#10240;` / `&#12288;` between keyword and id. Twelve of
# the sixteen `_SAD_ZS` codepoints had no entity spelling either.
#
# TWO DECODERS, because the two consumers want different things:
#
#  (1) _sad_decode_entities — for the VISIBLE text. Decodes straight to the
#      CLASSIFICATION: a `_SAD_ZS` spelling becomes an ASCII space, a `_SAD_CF`
#      spelling becomes nothing. Pure ASCII in, pure ASCII out, which is why it
#      can run in BOTH `_sad_visible` arms — decoding to the literal codepoint
#      instead would leave a multibyte character the C-locale arm cannot classify,
#      i.e. it would REGRESS `&nbsp;` on exactly the stripped-shell caller the
#      locale preamble is about. The ALLOWLIST discipline still governs here and
#      the sets are the allowlist: over-decoding MANUFACTURES an anchor the
#      reviewer cannot see, which is the write this filter exists to prevent.
#
#  (2) _sad_entities_to_codepoints — for the HIDDEN-STEERING comparison only.
#      Decodes EVERY numeric reference to its actual UTF-8 bytes, allowlist or
#      not. That is deliberate and is the opposite discipline, because it feeds
#      the clauses whose whole design is to be codepoint-agnostic: `_del`
#      ("delete every non-ASCII byte") and the positional "a non-ASCII byte next
#      to a SAD token" checks. Without it those clauses are blind to an
#      entity-spelled invisible — the text is pure ASCII — so `Fixes&#10240;SAD-538`
#      resolved a decoy SILENTLY where the literal `Fixes⠀SAD-538` is flagged.
#      It never feeds resolution, so it cannot manufacture an anchor; the worst it
#      can do is raise the VERIFY warning, which is the fail-safe direction.
#      Written in awk (a hard G0 prereq) under LC_ALL=C so `%c` emits single
#      BYTES and the UTF-8 encoding below is exact rather than locale-dependent.
_sad_decode_entities() {
  LC_ALL=C sed -E "s/&($_SAD_ZS_NAMED|$_SAD_ZS_ENT);/ /g; s/&($_SAD_CF_NAMED|$_SAD_CF_ENT);//g"
}
_sad_entities_to_codepoints() {
  LC_ALL=C awk '
    function utf8(cp,   b) {
      if (cp < 0)       return ""
      if (cp < 128)     return sprintf("%c", cp)
      if (cp < 2048)    return sprintf("%c%c", 192 + int(cp / 64), 128 + cp % 64)
      if (cp < 65536)   return sprintf("%c%c%c", 224 + int(cp / 4096), \
                                       128 + int(cp / 64) % 64, 128 + cp % 64)
      if (cp < 1114112) return sprintf("%c%c%c%c", 240 + int(cp / 262144), \
                                       128 + int(cp / 4096) % 64, \
                                       128 + int(cp / 64) % 64, 128 + cp % 64)
      return ""
    }
    function hex2dec(s,   i, n, c, d) {
      n = 0
      for (i = 1; i <= length(s); i++) {
        c = tolower(substr(s, i, 1))
        d = index("0123456789abcdef", c) - 1
        if (d < 0) return -1
        n = n * 16 + d
      }
      return n
    }
    {
      out = ""; rest = $0
      while (match(rest, /&#[Xx]?[0-9A-Fa-f]+;/)) {
        out = out substr(rest, 1, RSTART - 1)
        tok = substr(rest, RSTART + 2, RLENGTH - 3)     # strip "&#" and ";"
        rest = substr(rest, RSTART + RLENGTH)
        if (tok ~ /^[Xx]/) cp = hex2dec(substr(tok, 2))
        else if (tok ~ /^[0-9]+$/) cp = tok + 0
        else cp = -1
        # ⚠ A RECORD TERMINATOR IS FOLDED TO A SPACE, never emitted literally.
        # This text feeds the byte-level `sad_hidden` clauses, and every one of
        # them is line-oriented `grep` — so a decoded LF would SPLIT the record
        # and destroy the very anchor they exist to compare, making the clauses
        # agree by construction and the steer silent. That is exactly how
        # `Fixes&#10;SAD-538` resolved a decoy with no flag (Barb HIGH-2). This
        # half is INDEPENDENT of adding the codepoints to the ZS allowlist: that
        # fixes the visible text, this makes the comparison newline-blind so the
        # next record-breaking codepoint cannot reopen the same hole.
        if (cp == 10 || cp == 13) out = out " "
        # A malformed or out-of-range reference is left VERBATIM: it is not a
        # character reference, so pretending it is one would be a decode the
        # renderer does not perform.
        else if (cp >= 0 && cp < 1114112) out = out utf8(cp)
        else out = out "&#" tok ";"
      }
      print out rest
    }'
}
# ⚠ The multibyte sed runs ONLY when the UTF-8 ctype pin actually applied. Where
# C.UTF-8 does not exist and the caller is LC_ALL=C, a multibyte bracket
# expression degrades to a BYTE class: an em-dash (E2 80 94) loses its trailing
# byte and every ordinary body would be mangled — and, since the anchors would
# then differ, `sad_hidden` would fire on essentially every PR (Watson). Skipping
# the sed there is fail-safe: comment stripping still runs, and the positional
# non-ASCII check below still flags an id with a non-ASCII neighbour, so the
# VERIFY warning is if anything MORE likely, never less.
#
# The link-ref and entity stages run in BOTH branches: both are pure-ASCII
# transforms, so neither has the multibyte hazard that scopes the sed below.
_sad_visible() {
  if [ "$SAD_UTF8_CTYPE" = "1" ]; then
    _sad_strip_comments | _sad_strip_linkrefs | _sad_decode_entities \
      | sed "s/[$_SAD_CF]//g; s/[$_SAD_ZS]/ /g"
  else
    _sad_strip_comments | _sad_strip_linkrefs | _sad_decode_entities
  fi
}

# Anchor extraction over ALREADY-FILTERED text. Split out from _sad_anchor_ids so
# the provenance check below can compare the anchors of raw vs visible text
# without filtering twice.
_sad_ids_of() {
  grep -oiE '\b(close[sd]?|fix(e[sd])?|resolve[sd]?)[[:space:]]*:?[[:space:]]+SAD-[0123456789]+' \
    | grep -oiE 'SAD-[0123456789]+' \
    | tr '[:lower:]' '[:upper:]' \
    | awk '!seen[$0]++'
}

# Canonical, de-duplicated, order-preserving SAD-N anchors from stdin.
_sad_anchor_ids() { _sad_visible | _sad_ids_of; }

sad_pick=""      # space-separated SAD-N list (empty when the text carries none)
sad_how=""       # anchor | fallback | none — provenance, printed at G8
sad_hidden=""    # non-empty when the title/body carried invisible steering (SAD-589)
resolve_sad() {  # $1 = PR title, $2 = PR body; sets sad_pick / sad_how / sad_hidden
  local ids id
  # PROVENANCE DOWNGRADE (SAD-589). Resolution runs on reviewer-visible text,
  # which is correct — but the mere PRESENCE of hidden steering is the signal
  # worth surfacing, because it means the rendered PR and the raw bytes disagree
  # about what this PR closes. When they do, G8 prints the VERIFY warning even
  # though the anchor resolved cleanly: `anchor` provenance is the label that
  # normally SUPPRESSES that warning, and suppressing it is what made this
  # steerable.
  #
  # ⚠ The trigger is a CHANGED ANCHOR SET, not "the filter removed something".
  # The first cut compared raw vs filtered TEXT, which fires on the repo's own
  # PR template (it ships three `<!-- … -->` blocks) — so the warning became
  # constant background text and a genuinely steered PR would be visually
  # indistinguishable from every ordinary one. Alarm fatigue on the exact signal
  # this adds (Barb). Comparing ANCHORS fires only when the hidden text actually
  # changes which issue is named.
  #
  # The second clause is a POSITIONAL check, not another enumeration: any
  # non-ASCII byte adjacent to a SAD-N token is suspicious whatever codepoint it
  # is. _SAD_CF is necessarily an allowlist and allowlists lose to the entry
  # nobody wrote — fourteen invisible codepoints outside it were shown to steer
  # with the warning suppressed (Watson + Barb). LC_ALL=C makes [^ -~] a BYTE
  # class, which is what makes this codepoint-agnostic.
  #
  # ---- SAD-655 items 1 + 3: two more shapes reached the SILENT state ----
  # (1) GLUING. Five _SAD_CF entries — U+2800 BRAILLE PATTERN BLANK, U+3164
  #     HANGUL FILLER, U+FFA0, U+115F, U+1160 — all RENDER AS A BLANK, yet are
  #     DELETED. Placed between keyword and id, deletion GLUES them
  #     (`Fixes⠀SAD-538` -> `FixesSAD-538`), so the FILTER ITSELF destroys the
  #     anchor: the anchor-set diff sees none either side, and the positional
  #     check only scanned RIGHT of `SAD-`. Measured `fallback SAD-999`, no flag,
  #     while the reviewer reads `Fixes SAD-538`.
  #     ⚠ The fix is NOT to move them to _SAD_ZS. Normalizing them to a space
  #     regresses the in-id case (`Fixes SAD-5⠀38` -> `anchor SAD-5`), which is
  #     the same silent wrong-issue write from the other end and is pinned by the
  #     U+3164 row in tools/dev/test-land-pr.sh.
  # (2) KEYWORD-INTERNAL. `Fi<U+FE00>xes SAD-538` — U+FE00 is outside _SAD_CF, so
  #     it is neither stripped nor adjacent to `SAD-`; the anchor never forms and
  #     a decoy wins by `fallback`, silently.
  #
  # Hence FOUR clauses, each catching something the others do not:
  #   (a) the allowlist strip changed the anchor set                 [original]
  #   (b) deleting EVERY non-ASCII byte changes the anchor set — the same
  #       comparison as (a) with the allowlist replaced by "all of it", which is
  #       what makes it codepoint-agnostic and what catches (2). It cannot catch
  #       (1), because there deletion is what destroys the anchor in both texts.
  #   (c) the positional check, now SYMMETRIC — a non-ASCII byte immediately LEFT
  #       of `SAD-` as well as right of it. This is what catches (1).
  #   (d) Watson's keyword-shaped clause for (1). ⚠ Every string it matches is
  #       also matched by (c) — it is deliberately NOT independent. It is kept as
  #       a shape-specific backstop for the one vector the issue documents,
  #       because (c) is the broad clause an alarm-fatigue argument would narrow
  #       back to one-sided; the same paired-pin reasoning tools/dev/test-land-pr.sh
  #       applies to its G3 guards. Deleting (d) is safe ONLY while (c) stays
  #       symmetric.
  # ⚠ BLANK LINE between title and body, not a bare newline. GitHub renders the
  # two as SEPARATE documents; this join exists only so the hidden-steering
  # comparisons below see one text. With a bare `\n` the title becomes the
  # paragraph the body's first line continues — so a body OPENING with
  # `[//]: # (Closes SAD-999)`, which GitHub hides because it is at the start of
  # its own document, would read as paragraph continuation here and be KEPT.
  # The two texts would then agree and `sad_hidden` would not fire: the exact
  # suppression SAD-655 is about, reintroduced by the join rather than the
  # filter. The blank line is inert everywhere else — every extractor below is
  # `grep`, which is line-oriented and never matched across the seam anyway
  # (that separation is asserted by the "title+body join does NOT manufacture an
  # anchor" row in tools/dev/test-land-pr.sh).
  # ⚠ `_raw` IS ENTITY-DECODED, `_vis` IS NOT — that asymmetry is the fix, not a
  # bug. Clauses (b)/(c)/(d) below are byte-level and codepoint-agnostic BY
  # DESIGN, and an entity-spelled invisible is pure ASCII, so on the undecoded
  # text all three are blind to it: `Fixes&#10240;SAD-538` resolved a decoy in
  # silence where the literal `Fixes⠀SAD-538` is flagged. Resolving numeric
  # references into `_raw` makes the two spellings the same input to those
  # clauses. `_vis` keeps the ORIGINAL text because its own decoder maps
  # allowlisted spellings straight to their classification, which is what lets it
  # work in the C-locale arm too (see _sad_decode_entities).
  local _raw _vis _del _src
  _src="$(printf '%s\n\n%s\n' "$1" "$2")"
  _raw="$(_sad_entities_to_codepoints <<<"$_src")"
  _vis="$(_sad_visible <<<"$_src")"
  # Comments/link-refs are stripped first so this compares the SAME document (a)
  # and (c) do — otherwise a hidden-but-inert comment would flag every PR.
  _del="$(_sad_strip_comments <<<"$_raw" | _sad_strip_linkrefs | LC_ALL=C sed 's/[^ -~]//g')"
  sad_hidden=""
  if [ "$(_sad_ids_of <<<"$_raw")" != "$(_sad_ids_of <<<"$_vis")" ]; then
    sad_hidden="1"
  elif [ "$(_sad_ids_of <<<"$_del")" != "$(_sad_ids_of <<<"$_vis")" ]; then
    sad_hidden="1"
  elif LC_ALL=C grep -qE 'SAD-[0123456789]*[^ -~[:space:]]|[^ -~[:space:]]SAD-' <<<"$_raw"; then
    sad_hidden="1"
  elif LC_ALL=C grep -qiE '(close[sd]?|fix(e[sd])?|resolve[sd]?)[^ -~[:space:]]+SAD-' <<<"$_raw"; then
    sad_hidden="1"
  fi
  # BODY FIRST, title only as a second pass. GitHub and Linear scan the two
  # fields SEPARATELY and the closing convention puts `Fixes SAD-N` at the body's
  # tail, so a keyword-shaped TITLE ("fix: SAD-100 regresses the ring") must not
  # outrank a real body anchor. Joining the two would also manufacture a spurious
  # anchor across the boundary — "…quick fix" + a body opening "SAD-367 …" reads
  # as "fix SAD-367". Watson Important / Barb LOW, PR #399.
  ids="$(_sad_anchor_ids <<<"$2")"
  [ -n "$ids" ] || ids="$(_sad_anchor_ids <<<"$1")"
  sad_pick=""
  if [ -n "$ids" ]; then
    # ALL anchors, not just the first: 2 of the last 60 PRs closed two issues
    # (#368 → SAD-480/481, #360 → SAD-473/476), and naming only the first
    # silently skips the other's close-out. Watson Important, PR #399.
    while IFS= read -r id; do
      [ -n "$id" ] && sad_pick="${sad_pick:+$sad_pick }$id"
    done <<<"$ids"
    sad_how="anchor"
    return 0
  fi
  # No anchor anywhere → first-match over both fields, so anchorless and legacy
  # PRs still resolve. Newline-joined, never space-joined (see above).
  # Reviewer-visible text here too (SAD-589): the fallback is the path an author
  # reaches by DESTROYING the real anchor with a zero-width char, so it must not
  # be the one path that still reads raw bytes. Blank-line joined for the same
  # reason as `_raw` above — this join is filtered, so a bare `\n` would leave a
  # leading body definition standing and hand the fallback the decoy it defines.
  sad_pick="$(printf '%s\n\n%s\n' "$1" "$2" | _sad_visible \
    | grep -oiE '\bSAD-[0123456789]+' | tr '[:lower:]' '[:upper:]' | head -1)"
  if [ -n "$sad_pick" ]; then sad_how="fallback"; else sad_how="none"; fi
}

# Hidden picker self-test (tools/dev/test-land-pr.sh): stdin line 1 is the PR
# title and the remaining lines are the body — mirroring the two separate fields
# the real G8 call passes. Resolves and exits; no PR is read or touched, and no
# config is needed, so it runs offline.
if [ "${LAND_PR_SADTEST:-0}" = "1" ]; then
  # Pre-seed, then `|| :` — NOT `|| _sad_t=""`. At EOF `read` ASSIGNS the partial
  # line and THEN returns non-zero, so the assignment form threw away a title
  # that arrived without a trailing newline. `|| :` keeps it. The pre-seed covers
  # what `|| _sad_t=""` was incidentally guaranteeing: `read` assigns empty on
  # genuinely EMPTY stdin, but on a CLOSED fd 0 it errors without assigning at
  # all, which `set -u` turns into "_sad_t: unbound variable". All three shapes
  # now hold — empty -> "", closed -> "", unterminated -> partial line kept.
  # The real G8 passes title/body as ARGUMENTS, so only this seam was affected —
  # but the seam is what tools/dev/test-land-pr.sh trusts, which made the tests
  # validate slightly different input than production resolves.
  # Watson + Barb LOW-1, PR #399 / SAD-551.
  _sad_t=""; IFS= read -r _sad_t || :
  _sad_b="$(cat)"
  resolve_sad "$_sad_t" "$_sad_b"
  # `hidden` suffix (SAD-589): the provenance DOWNGRADE is the load-bearing half
  # of that fix — resolving correctly while suppressing the VERIFY warning is
  # exactly the steerable state — so the seam has to expose it or the suite can
  # only assert half the behaviour.
  echo "${sad_how}${sad_pick:+ $sad_pick}${sad_hidden:+ hidden}"
  exit 0
fi

repo_top="$(git rev-parse --show-toplevel 2>/dev/null || echo .)"
CFG="$repo_top/.claude/workflow.config.json"
# The trusted ref, resolved DETERMINISTICALLY and in ONE place: origin/HEAD if its
# symbolic ref is set, else the literal origin/main (the tracking ref exists even
# when the symbolic one is absent — Barb: don't depend on the non-guaranteed
# origin/HEAD). `symbolic-ref` returns EMPTY when origin/HEAD is unset, whereas
# `rev-parse --abbrev-ref` echoes the literal string "origin/HEAD" and would
# defeat the fallback (Watson). Both the config read below and the script-
# integrity gate (SAD-358) call this — a second copy is how the two would drift.
trusted_ref_of() { # $1 = repo dir
  local r
  r="$(git -C "$1" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null)"
  [ -n "$r" ] || r="origin/main"
  printf '%s\n' "$r"
}

# ---- executed-gate-logic provenance (SAD-358 residual 1) ----
# The CONFIG that decides the gates is read from the trusted ref (above), but the
# SCRIPT that runs them is read off the local disk — a config-vs-script asymmetry
# Barb accepted as a MEDIUM residual on PR #264. A one-line working-tree edit to
# this file can delete a gate, and nothing anywhere records that it happened.
#
# The fix is a PROVENANCE check, not the re-exec the issue also lists. Re-execing
# `git show <trusted>:tools/dev/land-pr.sh` would mean a PR that legitimately
# CHANGES the funnel can never be exercised through the funnel — including with
# `--dry-run`, which is how every such change is validated here. The property
# that actually closes the residual is weaker and sufficient: whatever gate logic
# runs must EXIST ON THE REMOTE, i.e. have a review trail.
#
# Two acceptable provenances, both reviewable:
#   • the trusted ref            — the reviewed, landed funnel
#   • the branch's UPSTREAM ref  — a pushed commit: it is what CI ran and what a
#                                  reviewer reads, and it is security tier by
#                                  `tools/**`, so landing it needs Watson + Barb
# Anything else — an uncommitted edit, or a commit that was never pushed — has no
# review trail at all, and that is exactly the residual.
#
# ⚠ PRECISE CLAIM, because the overclaim is the tempting half: this does NOT make
# the funnel tamper-proof. A hostile PUSHED branch still runs its own gates, and
# a script that skips G4 can skip G4 on itself. What it removes is the silent,
# trailless case: after this, altering the gate logic requires putting the
# alteration on the remote, where the tier gate, CI and the diff can see it.
# The full re-exec pin remains open on SAD-358 with the testability cost above.
#
# Compares BLOB SHAs, not text: `git hash-object` on the file vs `rev-parse
# <ref>:<path>`. That is byte-exact, needs no temp files, and is indifferent to
# line endings and to the file's mode.
#
# Resolves the repo from THIS SCRIPT's own realpath, never the caller's CWD —
# SAD-546/SAD-629's lesson from the sibling suite: invoking a script by absolute
# path or through a symlink otherwise verifies whichever checkout the caller
# happened to be standing in, and a wrong-tree PASS is the dangerous direction.
#
# Prints exactly one of: `ok <ref>` | `mismatch <local-blob>` | `unverifiable <why>`
gate_script_provenance() { # $1 = path to the executing script
  local p repo rel local_blob ref u t b seen=0
  p="$(readlink -f -- "$1" 2>/dev/null || realpath -- "$1" 2>/dev/null || printf '%s' "$1")"
  repo="$(git -C "$(dirname -- "$p")" rev-parse --show-toplevel 2>/dev/null)" \
    || { printf 'unverifiable not-a-git-repo\n'; return; }
  case "$p" in
    "$repo"/*) rel="${p#"$repo"/}" ;;
    *) printf 'unverifiable outside-worktree\n'; return ;;
  esac
  local_blob="$(git -C "$repo" hash-object -- "$p" 2>/dev/null)" \
    || { printf 'unverifiable hash-object-failed\n'; return; }
  [ -n "$local_blob" ] || { printf 'unverifiable hash-object-empty\n'; return; }
  ref="$(trusted_ref_of "$repo")"
  # ---- `@{upstream}`: RESOLVE IT, AND REQUIRE IT TO BE REMOTE-TRACKING ----
  # ⚠ `@{upstream}` is whatever `branch.<name>.remote` + `.merge` point at, and
  # `git branch --set-upstream-to=<a local branch>` sets `branch.<name>.remote=.`
  # — an upstream that never leaves this machine. Accepting the literal
  # `@{upstream}` therefore turned the row commented "THE ROW THAT MAKES THIS A
  # GATE RATHER THAN A DIRTY-TREE CHECK" into a green `G0 PASS` after one
  # non-adversarial command, and the printed `ok @{upstream}` never revealed that
  # the ref was local (proved in a throwaway repo — Watson, PR #547). Only
  # `refs/remotes/*` is a review trail, so the symbolic name is resolved first
  # and anything else is discarded.
  #
  # ⚠ AND THE GUARANTEE IS BOUNDED. An earlier comment here claimed a
  # remote-tracking ref is "a LOCAL ref that only ever advances from a fetch", so
  # "a stale upstream can only make this check STRICTER … never looser". That is
  # not a property git provides: `refs/remotes/*` are ordinary locally-WRITABLE
  # refs, and `git update-ref refs/remotes/origin/trunk HEAD` makes this print
  # `ok origin/trunk` for an unpushed blob (Watson, verified). So this control
  # rests on the SAME local-write boundary the block above already concedes — it
  # is tamper-EVIDENCE against accident and drift, not an authorization boundary
  # against someone who already runs commands in this checkout.
  u="$(git -C "$repo" rev-parse --symbolic-full-name '@{upstream}' 2>/dev/null)" || u=""
  case "$u" in
    refs/remotes/*) ;;
    *) u="" ;;
  esac
  for t in "$ref" ${u:+"$u"}; do
    b="$(git -C "$repo" rev-parse --verify --quiet "$t:$rel" 2>/dev/null)" || continue
    [ -n "$b" ] || continue
    seen=1
    # The RESOLVED ref, never the symbolic `@{upstream}` — the operator has to be
    # able to see WHICH ref vouched for the blob.
    [ "$b" = "$local_blob" ] && { printf 'ok %s\n' "$t"; return; }
  done
  # NEITHER ref resolved -> there is nothing to compare against (no remote, a
  # fresh clone-less repo, the path absent upstream). Unverifiable is a WARN, not
  # a block: failing closed here would brick the funnel on any adopter without an
  # `origin`, and this gate is a tamper-EVIDENCE control, not an auth boundary.
  [ "$seen" = "1" ] || { printf 'unverifiable no-remote-copy\n'; return; }
  printf 'mismatch %s\n' "$local_blob"
}
# --dry-run AND the tier self-test read the WORKING-TREE config so a branch's
# own config changes are exercised before commit; only a real landing reads the
# trusted ref (SAD-257 (c): the self-test must validate the current tree, not
# origin/main's stale config).
#
# ⚠ THE TEMP FILE BELOW NEEDS AN EXPLICIT TEMPLATE (SAD-692). BSD/macOS `mktemp`
# REQUIRES a template (or `-t`) and exits with a usage error without one; GNU's
# does not, which is the entire reason this was invisible here. Traced on macOS:
# bare `mktemp` fails -> `CFG` is empty -> the `git show > "$CFG"` redirect fails
# -> the `[ ! -f "$CFG" ]` test below routes to the config-missing branch -> the
# landing proceeds against the HARDCODED instance-#1 `securityTierPatterns` /
# `docsTierPatterns` baked into this script rather than the adopter's own. That
# is a WARN, not a `die`, in a long gate table — so on an adopter's Mac a path
# they consider security tier can classify as code or docs and skip the
# Watson/Barb requirement, with nothing louder than one line of warning.
# `agent-pr-flow` ships this script to other repos (ADR-0031), so the blast
# radius is every macOS adopter. Same root cause as the `_dtmp`/`_ctmp` G7
# pre-flight sites fixed in PR #529, at a higher-stakes call site.
#
# ⚠ AND A MATERIALIZATION FAILURE IS FATAL, NOT A FALLBACK. "There is no config"
# and "there is a config and I could not read it" are different conditions, and
# only the first is a legitimate fallback — the `cat-file -e` guarding each
# branch has already PROVED the blob exists on that ref. Failing closed here
# cannot brick an adopter who simply has no config: that operator never reaches
# this branch. It only stops the case where the tier rules the gates will apply
# are not the ones the repo committed.
_cfg_tmp() { # sets $CFG to a fresh temp file or dies. NEVER call in $( ) — see
             # the `station()` note below: a die inside a subshell exits only it.
  CFG="$(mktemp "${TMPDIR:-/tmp}/land-pr-config.XXXXXXXXXX" 2>/dev/null)" || CFG=""
  [ -n "$CFG" ] && [ -f "$CFG" ] \
    || die 0 "could not create a temp file for the workflow config (mktemp failed; TMPDIR=${TMPDIR:-/tmp}) — refusing to fall back to the hardcoded tier patterns while a committed config exists, because that would gate this landing on another repo's idea of which paths are security tier (SAD-692)"
}
if [ -n "${LAND_PR_CFG_OVERRIDE:-}" ]; then
  CFG="$LAND_PR_CFG_OVERRIDE"
elif [ "$dry_run" != "1" ] && [ "${LAND_PR_SELFTEST:-0}" != "1" ]; then
  trusted_ref="$(trusted_ref_of "$repo_top")"
  if git -C "$repo_top" cat-file -e "$trusted_ref:.claude/workflow.config.json" 2>/dev/null; then
    _cfg_tmp
    trap 'rm -f "$CFG"' EXIT
    git -C "$repo_top" show "$trusted_ref:.claude/workflow.config.json" > "$CFG" \
      || die 0 "could not read .claude/workflow.config.json from the trusted ref ($trusted_ref) — it EXISTS on that ref, so this is an unreadable config, not a missing one; refusing to fall back to the hardcoded tier patterns (SAD-692)"
  elif git -C "$repo_top" cat-file -e "HEAD:.claude/workflow.config.json" 2>/dev/null; then
    echo "land-pr: WARN — config absent on the trusted ref ($trusted_ref); using this branch's committed copy" >&2
    _cfg_tmp
    trap 'rm -f "$CFG"' EXIT
    git -C "$repo_top" show "HEAD:.claude/workflow.config.json" > "$CFG" \
      || die 0 "could not read .claude/workflow.config.json from HEAD — it EXISTS on that ref, so this is an unreadable config, not a missing one; refusing to fall back to the hardcoded tier patterns (SAD-692)"
  elif [ -f "$CFG" ]; then
    echo "land-pr: WARN — config not committed anywhere; using the working-tree copy" >&2
  fi
fi
CFG_MISSING=0
if [ ! -f "$CFG" ]; then
  # ⚠ RECORDED, not merely warned — ported DOWN from agent-pr-flow PR #9 as part
  # of the SAD-682 reconciliation, because it is the other half of SAD-692. This
  # used to be a lone stderr line, so stdout — the artifact agents paste and
  # humans read — printed a fully authoritative gate table with no indication
  # that every tier pattern came from ANOTHER repo's hardcoded map. In
  # agent-pr-flow the fallback happened to yield tier=security by luck
  # (`.github/workflows/` matched its ci.yml); in a repo where none of the
  # instance-#1 anchors match, the tier silently drops to code or docs and a real
  # landing proceeds ungated. The row is emitted beside the gates below and a
  # real landing refuses; --dry-run still reports the whole table so a
  # bootstrapping adopter can see it.
  #
  # Inert in THIS repo — the config is committed — which is exactly why it has to
  # come down with the back-port rather than be judged unnecessary here.
  CFG_MISSING=1
  echo "land-pr: WARN — workflow.config.json missing; using hardcoded instance-#1 fallbacks" >&2
elif ! jq -e . "$CFG" >/dev/null 2>&1; then
  # A file that is not valid JSON makes EVERY `jq` read below fail, so every key
  # silently takes its fallback — indistinguishable from "key absent" (Barb,
  # PR #458). Fail-SAFE (the fallback is byte-identical in effect to the config,
  # verified across all tracked files) but silent, and silence is how a config
  # regression survives. Not fatal: the fallback is the trustworthy path by
  # construction, so a WARN is the right severity.
  echo "land-pr: WARN — $CFG is not valid JSON; ALL config keys fall back to the hardcoded instance-#1 values" >&2
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
  # SAD-618 — TYPE-ASSERT before iterating. `jq -e` is a TRUTHINESS test, and
  # both {} and [123] are truthy, so a parseable-but-wrong-shaped value took the
  # config branch; `jq -r '<path>[]'` then iterated an object's VALUES (or bare
  # numbers) as if they were globs. The resulting $pats was non-empty, so the
  # fail-closed emptiness guard below never fired — it checks emptiness, never
  # SHAPE. Proven by execution: with securityTierPatterns set to {"a":"b"} or
  # [123], .claude/hooks/pre-bash-safety.sh reclassified `code` and
  # .claude/commands/restore-synthetic.md `docs`, exit 0, no warning — the whole
  # security tier collapsing silently, which is the entire blast radius.
  #
  # Absent/null still falls back to the hardcoded pattern (fail-SAFE, unchanged).
  # PRESENT-but-wrong-shaped now DIES (fail-CLOSED): a config that says something
  # unintelligible is an error, not an absence, and must not be papered over.
  if [ -f "$CFG" ] && jq -e "$1 != null" "$CFG" >/dev/null 2>&1; then
    jq -e "($1 | type) == \"array\"" "$CFG" >/dev/null 2>&1 \
      || die 0 "$1 in config has type $(jq -r "$1 | type" "$CFG" 2>/dev/null) — it must be an ARRAY of glob strings (fail-closed)"
    jq -e "$1 | map(type == \"string\") | all" "$CFG" >/dev/null 2>&1 \
      || die 0 "$1 in config contains a non-string element — it must be an array of glob STRINGS (fail-closed)"
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
# codeTierPolicy: what the residual `code` tier requires beyond CI.
#   reviewer (default) — reviewer verdict marker required (historical behavior)
#   ci-only            — CI alone; reviews happen at the owning agent's judgment
# Scoped STRICTLY to tier=code: docs stays CI-alone, security ALWAYS requires
# reviewer + security markers regardless of this knob. Fail-closed: absent
# config -> 'reviewer'; any value outside the enum aborts the landing.
CODE_TIER_POLICY="$(cfg '.review.codeTierPolicy' 'reviewer')"
case "$CODE_TIER_POLICY" in
  reviewer|ci-only) : ;;
  *) die 0 "invalid review.codeTierPolicy '$CODE_TIER_POLICY' in config (allowed: reviewer | ci-only)" ;;
esac
REVIEWER_AGENT="$(station reviewer watson)"
SECURITY_AGENT="$(station security barb)"
[ -n "$REVIEWER_AGENT" ] || die 0 "invalid agents.reviewer in config — only an explicit null disables a station"
[ -n "$SECURITY_AGENT" ] || die 0 "invalid agents.security in config — only an explicit null disables a station"

# Tier patterns (globs from config → ERE; hardcoded instance-#1 fallbacks).
# Fallback slash-less entries use (^|/) to match the documented any-depth glob
# semantics (Watson PR #162: nested .gitignore divergence was gate-weakening).
#
# .claude/commands/ and .claude/agents/ are gated as WHOLE DIRECTORIES (SAD-546).
# An earlier revision of this change tried an allowlist of the four commands that
# can destroy data or drive the gate (land, issue, restore-synthetic,
# prune-worktrees). That form is defeated four ways, because the directory's
# residual tier is docs (everything in it matches the `*.md` docs glob):
#   - RENAME       restore-synthetic.md -> restore-synth.md (G3 READ only
#                  .filename until SAD-604 unioned .previous_filename in; the
#                  whole-directory glob closes it independently of that fix)
#   - SIBLING      add restore-synthetic-v2.md next to it
#   - NAMESPACE    add dev/restore-synthetic.md
#   - NEW COMMAND  add wipe-device.md, destructive from birth and on no list
# Whole-directory closes all four at once and is fail-safe by default, which is
# the property a FALLBACK must have: it exists for when the config cannot be
# trusted, so it must never be NARROWER than the config it stands in for.
#
# .claude/agents/ is here for the same reason issue.md is: /issue's entire
# safety argument is that it only ever spawns the tool-contained radar, and that
# containment is one frontmatter `tools:` line in .claude/agents/radar.md.
# Gating the caller but not the containment is a half-measure — a PR adding
# Bash/Edit/Write to that line would defeat the property issue.md was gated for.
# Every agent charter is a tool-boundary declaration, so the glob is the right
# shape.
#
# Cost accepted: away.md and linear-triage.md edits pay one Barb pass.
# SAD-285 lockstep — see the block above the `tier_pat` call below for the
# precise split between what test-land-pr.sh CAN assert and what it cannot.
#
# ---- RECALIBRATED for the ci-only era (SAD-647 / SAD-630 / SAD-619) ----
# This list was calibrated when `code` tier still had a MANDATORY reviewer
# backstop. ADR-0050 / review.codeTierPolicy=ci-only removed it: a code-tier PR
# now lands on green CI with ZERO human or AI review. Three categories were
# sitting on the wrong side of that removed backstop:
#
#   tools/**                The three shell suites became load-bearing merge
#                           gates when SAD-547 wired them into the required
#                           check — so a code-tier PR could hollow out the very
#                           assertions meant to catch a gate narrowing. Barb
#                           proved this VACUOUS-GREEN on PR #451. Also covers
#                           prune-worktrees.sh and golden-synth/** (irreversible
#                           worktree/data operations). Supersedes the two
#                           exact-path entries — a DIRECTORY, never a filename
#                           allowlist, because SAD-546 is precisely the lesson
#                           that an allowlist loses to a rename, a sibling or a
#                           namespaced path. (SAD-630)
#                           ⚠ tools/**, NOT tools/dev/** — the narrower form left
#                           tools/ci/firebase/package{,-lock}.json at code tier,
#                           and those are the ONLY pin on the binary distribute.yml
#                           runs with the Firebase service-account key. A one-line
#                           `"firebase-tools": "npm:<attacker-pkg>@1.0.0"` plus a
#                           regenerated lockfile lands with zero review, and
#                           --ignore-scripts does not help: it blocks install-time
#                           code, not the `bin` entry the workflow then executes.
#                           Integrity hashes do not help either — the attacker
#                           authored the lockfile they are checked against.
#   .claude/**              WHOLESALE, not the six-entry allowlist it started as.
#                           `workflow.md` is the operating manual every agent reads
#                           before any git/PR work — it DEFINES §5's tier semantics
#                           and the landing rules, so the document deciding what
#                           needs review must not be the one thing needing none
#                           (SAD-619). But enumerating six entries reproduced the
#                           SAD-546 shape one level up: `.claude/skills/**` (agent
#                           instructions) and `.claude/statusline.sh` (a script
#                           Claude Code EXECUTES) both classified docs/code.
#                           ⚠ The widening is NOT free, and an earlier draft of
#                           this comment wrongly said "every tracked .claude path
#                           already classified security, so the widening costs
#                           nothing". Measured: of 18 tracked .claude paths, 12
#                           were already security and 6 were NOT — all six being
#                           .claude/references/**, which this pulls from docs into
#                           security. That is SAD-619's stated intent, so the cost
#                           is intended rather than incidental; the false part was
#                           "costs nothing", which understated the change and is
#                           the flattering direction to be wrong in. The
#                           newly-added-file case is closed by construction.
#   gradlew / gradlew.bat   The build LAUNCHER. gradle/wrapper/** was security
#                           tier but the scripts that invoke it were not, and
#                           distribute.yml runs `./gradlew :app:assembleDebug` on
#                           the self-hosted runner in a workspace holding
#                           local.properties (Gemini key), the debug keystore and
#                           the real google-services.json. One appended line
#                           before its `exec`, with the build left working so CI
#                           stays green, reads all three. (Barb, PR #458)
#   app/{nano,voice,map}/** Gemini API-key egress, the R-PRIV-004 on-device vs
#   ui/summary/CourseMapWeb.kt  cloud privacy boundary, the sha256 install-trust
#                           gate, and an embedded WebView — security-sensitive
#                           app code outside the existing network/ + feedback/
#                           coverage. (SAD-647)
#
# ---- SECOND RECALIBRATION: what EXECUTES on the runner (SAD-667) ----
# The pass above asked "what decides the gate". This one asks the adjacent
# question Barb raised across PR #458's rounds 8-10: what RUNS on endurance-local
# during the required check. That box is a daily driver, not a disposable VM — it
# concurrently holds the Firebase service-account key, ~/actions-runner/.env and
# .path, and the home directory.
#
#   .github/**              WIDENED from .github/workflows/**. The narrower form
#                           is the SAD-546 allowlist shape one more level up:
#                           .github/actions/** would be a COMPOSITE ACTION —
#                           executable, and classified `code` until the day
#                           someone adds one. Also pulls in dependabot.yml and
#                           any future CODEOWNERS, which is the correct
#                           direction: both steer what lands.
#                           ⚠ It also pulls in .github/pull_request_template.md.
#                           The promotion is a CONSEQUENCE of the whole-directory
#                           shape (SAD-546), not an independent exploit story —
#                           an earlier draft of this comment claimed the latter
#                           and overstated it twice (Barb L-3): G8 is a
#                           POST-MERGE close-out printer, not a gate, so a
#                           poisoned template cannot allow or block a merge; and
#                           the payload class it named (invisible fillers,
#                           `[//]: # (Closes SAD-999)`) is what `sad_hidden`
#                           already detects. The real residual is narrower and
#                           still worth having: the template seeds every PR body,
#                           the body becomes the squash commit body, and G8 reads
#                           it — so a poisoned template degrades PM attribution
#                           across every future PR, bounded by that detection.
#                           This change also drops the file from docsTierPatterns
#                           as dead config. Note the entry was ALREADY redundant
#                           before `.github/**` existed — plain `*.md` matched it
#                           — and that is the reason that survives a future
#                           re-narrowing of `.github/**`, where "security is
#                           tested first" would not.
#   buildSrc/**             Gradle build logic — compiled and executed by every
#                           `./gradlew` invocation, including the required check
#                           and distribute.yml's keystore-bearing run. Latent
#                           (no buildSrc/ today), which is precisely why it must
#                           be gated BEFORE one exists: the two-step shape is PR
#                           #1 (code tier, no review) planting the definition and
#                           PR #2 (security tier) adding the one-line wiring a
#                           reviewer waves through as trivial.
#   **/*.gradle             An applied script. SAD-667 named `gradle/*.gradle`;
#                           that is the SAD-546 allowlist shape a FIFTH time.
#                           Measured, not reasoned — under the directory-scoped
#                           glob, `gradle/sub/nested.gradle`, `custom.gradle`,
#                           `app/foo.gradle` and `settings.gradle` ALL escape to
#                           code tier. `settings.gradle` is the sharpest of the
#                           four (Barb): Gradle applies it automatically, with no
#                           `apply from:` line needed anywhere. Widened to the
#                           extension because a `.gradle` file IS an executable
#                           Groovy build script by definition, and this project
#                           is entirely `.gradle.kts`, so it costs nothing today
#                           and closes the sibling/namespace holes permanently.
#   gradle/**               The build's TRUST ANCHOR directory. This replaces the
#                           two narrower entries rather than adding to them, and
#                           it SUBSUMES their reasons — which are recorded here
#                           because the argument below is about verification
#                           metadata, and a future reviewer re-narrowing on that
#                           argument alone would drop them: libs.versions.toml
#                           carries every dependency VERSION PIN (the thing that
#                           makes SAD-294's "no passive latest-pull" claim true),
#                           and wrapper/** carries the distribution URL and the
#                           gradle-wrapper.jar the build launcher executes.
#                           ⚠ An earlier cut of this change did the opposite — it
#                           positively pinned gradle/verification-metadata.xml as
#                           `code` on the grounds that inert checksums are not an
#                           executed script. Both reviewers rejected that, and
#                           they were right: it is literally true and misses the
#                           argument this very file makes 80 lines up for
#                           tools/ci/firebase/package-lock.json — an integrity
#                           file is the ONLY pin on what the build downloads and
#                           executes, and "the attacker authored the lockfile they
#                           are checked against". A future PR adding that file, or
#                           later setting <verify-metadata>false</verify-metadata>,
#                           would have landed at code tier with zero review. An
#                           exact-path entry was considered and rejected in turn:
#                           it leaves the sibling verification-keyring.keys/.gpg
#                           open, which is the allowlist hole reappearing inside
#                           the fix for the allowlist hole. Whole directory.
#
# ⚠ app/src/test/** is NOT gated, and that is a DECISION, not an oversight.
# The required check runs `./gradlew … testDebugUnitTest`, so unit-test sources
# execute arbitrary Kotlin on the runner as the runner user, at `code` tier,
# under ci-only — i.e. with zero review. (So does any app/src/main/** class
# INITIALIZER those tests load — `init` blocks, `companion object` and top-level
# property initializers outside the gated network/feedback/nano/voice/map
# subtrees. Barb L-1: gating app/src/test/** alone would not close the surface,
# which is another argument for the runner-side fix below.
# app/src/androidTest/** is COMPILED but not executed, so it stays code.)
# Gating it was considered and rejected: 217 tracked files, touched by most PRs,
# so it would make nearly every PR security tier and tax the writing of tests —
# a control that discourages tests buys less security than it spends.
#
# ⚠⚠ THE BOUND, CORRECTED. An earlier draft of this comment bounded the residual
# with "the repo is private + non-fork, and ci.yml references NO secrets". The
# second clause is TRUE OF ci.yml AND IRRELEVANT — Barb falsified it by
# measurement on the box (M-1). The runner is NOT ephemeral (no `ephemeral` key
# in ~/actions-runner/.runner) and ~/.gradle/init.d/ is populated; Gradle applies
# every init script there to EVERY build, including distribute.yml's
# `:app:assembleDebug`, which fires on `push: [main]` the moment a PR lands.
# ⚠ Stated as REACHABILITY, not carriage — a first draft of this correction said
# that step "carries FIREBASE_SERVICE_ACCOUNT", and it does not: its env is
# DEBUG_KEYSTORE_PATH alone. What is on disk beside it is the debug keystore,
# local.properties (Gemini key) and google-services.json; the SA key is written
# to $RUNNER_TEMP/firebase-sa.json by a LATER step in the SAME job and scrubbed
# at the end. Reachable to the same UID either way on a non-ephemeral runner —
# but the precise form is what survives the next reader grepping that step's
# env: block, and the imprecise one hands them a reason to discount the whole
# paragraph. Which is this correction repeating, one scope smaller, the error it
# was written to fix.
# The runner UID also owns ~/.config/gh/hosts.yml, ~/.claude/.credentials.json
# and ~/.ssh/. So what is bounded is the ACTOR — an authenticated collaborator
# on a private, non-fork repo — NOT the impact.
#
# The old tripwire ("re-evaluate if ci.yml gains a secret") could never fire,
# because the reachable secrets are not in ci.yml. The correct trigger is: the
# repo gains contributors, or goes public. The exposure is ALREADY at its stated
# ceiling. The durable fix is runner-side and cannot be reached by any tier
# pattern — the .gradle scripts that execute beside the secrets live in
# ~/.gradle/init.d/, outside the repo — so it is tracked as SAD-683 (split the
# secret-bearing workflows onto a runner that never executes PR code, or
# containerize the Gradle step; --ephemeral alone is necessary but NOT
# sufficient). (SAD-667, SAD-683, R-INFRA-012)
#
# A SECOND trusted-ref gap, same class, already tracked: this script reads its
# config from origin/main so a branch cannot self-classify, but the SCRIPT ITSELF
# executes from the working tree with no integrity check — so code running as the
# runner user can hollow out `tier_of` in place and every later landing skips both
# reviewers with a clean-looking gate table (Barb M-2). That is SAD-358.
#
# ⚠ SAD-285 LOCKSTEP, stated as three GATES and one INSTRUCTION (SAD-655 item 5).
# The wording this replaced said all four surfaces "must ALL move together" and
# that test-land-pr.sh asserts it — an instruction dressed as a gate, since one of
# the four is in another repository. What is actually asserted, here in this repo:
#   • this fallback <-> .claude/workflow.config.json — the config-vs-fallback tier
#     IDENTITY over every tracked path, plus the per-path tier pins.
#   • the §5 tier paragraph in .claude/references/pm/workflow.md — every entry of
#     review.securityTierPatterns must be named VERBATIM there.
#     ⚠ That row used to filter to `.claude/`-prefixed entries, so `tools/**`,
#     `gradlew`, `gradlew.bat`, `server/**` and the app surfaces were UNASSERTED
#     prose, free to drift from the gate they describe — the same failure the row
#     exists to catch, one pattern-class over. SAD-655 dropped the filter and gave
#     §5 a verbatim pattern list, so the assertion is now total. It is TWO rows:
#     the `.claude/` half keeps SAD-546's provenance, the residual half is the new
#     coverage, and splitting them means deleting the new half moves the count.
#   • the upstream templates/workflow.config.example.json — NOT a gate, see below.
#
# ⚠ WHAT IS AND IS NOT ENFORCED HERE, stated because a lockstep claim reads as
# a guarantee and only three of the four surfaces are local. NOTHING in this
# repository can assert another repository. The upstream template is
# DELIBERATELY NOT synced by SAD-667, and it still ships the narrow
# pre-SAD-619/630/647 set; porting it is tracked in SAD-655. Say it here
# rather than only in a PR body: an unstated deferral is indistinguishable from
# an oversight, and this comment is what the next author reconciles against.
#
# ⚠ AND SAY THE RIGHT REASON. Rounds 1-2 of this change, PR #518, and SAD-655
# itself all give the reason as "SAD-548 / agent-pr-flow#8 is still open, so
# install.sh would revert landed work". THAT IS NO LONGER TRUE — #8 merged
# 2026-08-05 (896e288). Verified on the artifact rather than the PR title:
# `git show origin/main:install.sh` in ~/Documents/agent-pr-flow carries the
# ahead-refusal guard. The claim survived three PRs because the LOCAL checkout of
# that repo is parked on a branch predating the merge, so anyone grepping the
# working tree still sees the old file — the working-tree-is-not-the-ref trap
# this very script exists to close on the config side.
# The port is therefore UNBLOCKED, and it is deferred here only to keep this
# change scoped — which raises SAD-655's priority rather than lowering it.
#
# ⚠ HARD COUPLING, do not break it: the `.github/workflows/_selftest.yml` probe
# below is narrow SPECIFICALLY so the current upstream template still lands. If
# the template is ported to `.github/**`, widen the probe and the `a valid minimal array
# still works` row in test-land-pr.sh — MORE surfaces than the two that look
# coupled; they all move together: template, probe, row, the narrower assertion
# in the harness, and ci.yml's floor. Deliberately NOT numbered — this clause carried a
# count that went stale twice in two rounds, which is the change's own lesson.
# Widening the
# probe alone reddens that row, and the obvious way to green it is to revert the
# row to `.github/**`, which re-creates the round-3 defect this closed. THE
# RESOLUTION, since after a port there is nothing else to widen the row to:
# track the template with the row AND add a separate assertion pinned one level
# NARROWER than it — and RAISE ci.yml's `test-land-pr.sh:` floor in the same
# PR (SAD-646), or the new assertion is unenforced;
# until then it must stay narrow. Measured: the broad probe killed every landing
# under the shipped template at G0.
tier_pat '.review.securityTierPatterns' '^\.github/|^buildSrc/|\.gradle$|\.gradle\.kts$|^gradle/|(^|/)gradle\.properties$|(^|/)gradlew$|(^|/)gradlew\.bat$|(^|/)AndroidManifest\.xml$|^app/src/main/java/com/enduranceloggr/app/network/|^app/src/main/java/com/enduranceloggr/app/feedback/|^app/src/main/java/com/enduranceloggr/app/nano/|^app/src/main/java/com/enduranceloggr/app/voice/|^app/src/main/java/com/enduranceloggr/app/map/|^app/src/main/java/com/enduranceloggr/app/ui/summary/CourseMapWeb\.kt$|^\.claude/|^\.githooks/|^tools/|(^|/)\.mcp\.json$|^server/|(^|/)local\.properties$|(^|/)google-services\.json$'
security_pat="$TIER_PAT"
tier_pat '.review.docsTierPatterns' '\.md$|^docs/|^design/|^tasks/|(^|/)\.gitignore$|^acceptance-evidence/'
docs_pat="$TIER_PAT"

# Fail-closed self-tests (Barb audit, PR #162): the loaded security pattern
# must catch a canonical security path — INCLUDING the gate config itself
# (self-protection: the file that configures the gates needs the strictest
# gate) — and the docs pattern a canonical doc. A converter/config regression
# aborts the landing instead of silently downgrading the tier.
# SAD-628 — the SECURITY pattern matches CASE-INSENSITIVELY; the docs pattern
# does NOT. Both directions are the fail-safe one:
#   • On a case-insensitive filesystem (macOS APFS default, Windows), the harness
#     loads `.claude/COMMANDS/wipe-device.md` as a live slash command, but a
#     case-sensitive `^\.claude/commands/` did not match it — so it classified
#     `docs`, hit `G4 SKIP  docs tier — CI-alone policy`, and landed with zero
#     verdicts. Same shape as the SAD-546 rename/sibling bypass, via casing.
#     Widening SECURITY can only ever pull a file INTO the strictest gate.
#   • Widening DOCS would do the opposite — more paths counting as docs can turn
#     a `code` PR into a `docs` one, which is a weakening — so docs stays exact.
# Inert on this instance (Linux ext4, case-sensitive, both dev box and runner);
# the exposure is for agent-pr-flow adopters, since the bundle ships this
# fallback. Barb's caveat is carried forward: the filesystem-collapse behaviour
# was reasoned, not tested on a case-insensitive volume.
grep -qiE "$security_pat" <<<".claude/hooks/_selftest" \
  || die 0 "security tier pattern fails its self-test — refusing to land (fail-closed)"
grep -qiE "$security_pat" <<<".claude/workflow.config.json" \
  || die 0 "the gate config is not covered by its own security tier — refusing to land (self-protection)"
grep -qiE "$security_pat" <<<".claude/COMMANDS/wipe-device.md" \
  || die 0 "security tier pattern is case-SENSITIVE — a case-variant of a gated directory would classify docs (fail-closed, SAD-628)"
# SAD-667 (Barb L-4) — the CI-definition surface needs its own self-test. The
# three probes above all live under .claude/, so dropping `.github/**` from both
# the config and this fallback left every one of them green and let land-pr.sh
# land silently; the only thing catching it was test-land-pr.sh's tier_pin rows
# inside CI. `.github/` is the right scope for a check in THIS file because the
# funnel is GitHub-only by construction — it shells out to `gh` and reads
# GitHub Actions check runs — so every adopter of the bundle has one.
#
# ⚠ Deliberately NOT extended to buildSrc/ , **/*.gradle or gradle/ , which Barb
# also named. This script is BUNDLE-MANAGED (ADR-0031) and ships to repos that
# are not Gradle projects at all; demanding those patterns would abort the
# landing for every such adopter. The first cut did exactly that and turned the
# "a valid minimal array still works" row red — a portable script cannot carry an
# instance's build system in a fail-closed assertion. Those three surfaces are
# pinned where instance-specific expectations belong: test-land-pr.sh's tier_pin
# rows, which run inside the required check.
# ⚠ The probe path is `.github/workflows/`, NOT bare `.github/`, and the
# difference is not cosmetic (Watson, PR #524 round 2). The first cut probed
# `.github/_selftest.yml`, which the bundle's OWN shipped
# templates/workflow.config.example.json does not match — it still carries
# `.github/workflows/**`. Measured: every landing under the upstream template
# died at G0. That is the same portability error as demanding buildSrc/ , made
# one notch subtler: the floor was set above what the template configures, on a
# script that ships to adopters using it. Probing the narrower path keeps the
# fail-closed regression this exists for (dropping `.github` coverage entirely
# still dies) while letting a stock adopter land; a RE-NARROWING of `.github/**`
# back to `.github/workflows/**` is caught instance-side by the tier_pin rows on
# dependabot.yml / CODEOWNERS / pull_request_template.md / actions/, which is
# the right split — and the distinction that carries it is CONSEQUENCE, not
# ownership (test-land-pr.sh is bundle-managed too): a failing pin reddens a
# check, a failing probe ABORTS EVERY ADOPTER'S LANDING.
grep -qiE "$security_pat" <<<".github/workflows/_selftest.yml" \
  || die 0 "security tier pattern no longer covers .github/workflows/ — the CI definitions that gate this repo would land unreviewed (fail-closed, SAD-667)"
grep -qE "$docs_pat" <<<"docs/_selftest.md" \
  || die 0 "docs tier pattern fails its self-test — refusing to land (fail-closed)"
# The NEGATIVE half. Proving a doc MATCHES says nothing about over-breadth, and
# over-broad docs is the weakening direction: `docsTierPatterns: ["**"]` would
# silently make every non-security PR docs-tier — CI-alone, zero verdicts —
# while the positive self-test above stayed green (Watson, PR #458).
grep -qvE "$docs_pat" <<<"app/src/main/java/_selftest.kt" \
  || die 0 "docs tier pattern also matches a CODE path — it is over-broad, which silently downgrades every code PR to CI-alone (fail-closed)"

# THE classifier — ONE definition, called by both the self-test seam below and
# the real G3. It used to exist twice, and the copies were not equivalent under
# test: every suite assertion exited through the self-test seam, so G3's own
# `grep` line was reached by ZERO assertions and dropping `-i` from it alone —
# the precise SAD-628 regression — left the whole suite green (Watson, PR #458).
# A pin that exercises a copy of the code it pins is a vacuous pin.
tier_of() { # $1 = newline-separated path list -> prints security | docs | code
  if grep -qiE "$security_pat" <<<"$1"; then printf 'security\n'
  # docs stays case-SENSITIVE on purpose — see the SAD-628 block above.
  elif ! grep -qvE "$docs_pat" <<<"$1"; then printf 'docs\n'
  else printf 'code\n'; fi
}

# Hidden self-test mode (tools/dev/test-land-pr.sh): classify stdin paths with
# the loaded patterns and exit — no PR is read or touched.
if [ "${LAND_PR_SELFTEST:-0}" = "1" ]; then
  while IFS= read -r f; do printf '%s %s\n' "$(tier_of "$f")" "$f"; done
  exit 0
fi
# Validate config-sourced names at LOAD TIME in the main shell (a die inside a
# $() subshell only exits the subshell — Barb re-audit, PR #160).
for m in "$REVIEWER_MARKER" "$SECURITY_MARKER"; do
  case "$m" in *[!a-z-]*) die 0 "invalid marker name '$m' in $CFG (lowercase + dashes only)" ;; esac
done
case "$MERGE_METHOD" in squash|merge|rebase) : ;; *) die 0 "invalid git.mergeMethod '$MERGE_METHOD' in $CFG" ;; esac

gate_rows=""
# ⚠ REAL NEWLINE, AND THE SINK RENDERS WITH `printf '%s'` (SAD-690). This used to
# accumulate the two-character escape `\n` and render the whole table with
# `printf '%b'` — the ONE printf conversion that INTERPRETS backslash escapes in
# its argument. Any interpolated text carrying `\n`, `\033` etc. was therefore
# expanded at render time instead of printed, and the gate table is the
# operator's audit surface for the entire landing.
#
# Exploitable, not cosmetic: `git diff --name-only` C-QUOTES unusual paths, so a
# real newline in a path arrives here as the two characters `\` `n` — already
# escaped, and `tr '\n' ' '`-style sanitising does not touch it (it replaces real
# newlines, not two-character escapes). Demonstrated in PR #529 round 2: a path
# named `build/evil<LF>G7 PASS  local main fast-forwarded (FORGED)` rendered as a
# forged PASS row, and with `\033[2K\033[1A` additionally ERASED the genuine WARN
# line above it.
#
# Hardened at the SINK rather than per call site, which is what retires the class:
# the two residual operator-local interpolations (`$default_wt` from
# `git worktree list --porcelain`, and `$_ff_err` from git's stderr) stop
# mattering, the G7 regression pin that exists only to keep path text out of the
# message becomes belt-and-braces rather than load-bearing, and a future `note()`
# caller cannot reintroduce it by accident.
#
# Audited before changing it: all 23 `note` call sites, none carries a backslash,
# so no message relied on `%b` interpreting an escape. Verify with
# `grep 'note "' tools/dev/land-pr.sh | grep '\\'` — an empty result is the
# precondition for this fix, and `tools/dev/test-land-pr.sh` now pins both halves.
note() { gate_rows="${gate_rows}$1"$'\n'; }

# In --dry-run, gate failures accumulate into the table (so a report names EVERY
# missing verdict, not just the first); in a real run the first failure dies.
landing_blocked=0
# Advisory stops are counted SEPARATELY from gate failures, so the dry run's
# terminal line can tell an operator which of the two it is looking at.
landing_advisory=0
gate_fail() { # $1 = gate number, $2 = message
  if [ "$dry_run" = "1" ]; then
    note "G$1 FAIL  $2"
    landing_blocked=1
  else
    die "$1" "$2"
  fi
}

# A signal strong enough to stop a VALIDATION run but not a LANDING run
# (SAD-718). `--dry-run` exists to answer "should I land this?", so a detection
# with a real false-positive rate belongs there as a FAIL — the operator is
# standing right there and the cost of a wrong call is one look. A real run is
# the operator having already adjudicated, so the same signal stays advisory
# rather than becoming a hard block the funnel has no override for.
#
# ⚠ THE ASYMMETRY IS THE DESIGN, NOT AN INCONSISTENCY. It will read as one, so:
# do NOT "fix" it by downgrading the dry-run row to a WARN — that restores
# exactly the state SAD-718 was filed about, where the strongest outcome the
# whole hidden-steering surface could produce was a note arriving after
# `PR #N LANDED`. If a future signal genuinely warrants blocking a real landing,
# it needs an explicit operator override flag first; do not reach that state by
# promoting this helper in place.
gate_advise() { # $1 = gate number, $2 = message
  if [ "$dry_run" = "1" ]; then
    # `STOP`, not `FAIL`. A dry run whose only complaint is an advisory must not
    # claim the landing is BLOCKED — a real run WOULD merge, and the dry run's
    # whole contract is prediction. Reporting FAIL here over-reports by exactly
    # as much as SAD-718's original bug under-reported (Watson, PR #570).
    note "G$1 STOP  $2"
    landing_advisory=1
  else
    note "G$1 WARN  $2"
  fi
}

# The tier map IS the gate. Every other pattern path in this script is
# fail-closed (`tier_pat` dies on an empty or invalid pattern); a MISSING config
# was the one place that fell back to another repo's patterns and carried on.
# --dry-run still reports the whole table, so a bootstrapping adopter can see it;
# a real landing refuses. Ported down from agent-pr-flow PR #9 (SAD-682
# reconciliation) — inert here, load-bearing for every adopter.
if [ "$CFG_MISSING" = "1" ]; then
  gate_fail 0 "no .claude/workflow.config.json — the tier map and the required check name would come from instance-#1 fallbacks, not this repo"
fi

# ---------- G0 (cont.): the executing gate logic must have a review trail ----------
# SAD-358 residual 1. Runs here rather than with the other G0 prereqs so a
# failure can use gate_fail — i.e. it becomes a FAIL ROW in --dry-run's table
# instead of an early exit, and --dry-run is precisely the surface an author uses
# while changing this file. See gate_script_provenance above for the full claim.
# The self-test seams are exempt: they evaluate no gate and merge nothing, and
# every one of them runs from a worktree whose copy of this file is under edit.
if [ "${LAND_PR_SELFTEST:-0}" != "1" ]; then
  _prov="$(gate_script_provenance "${BASH_SOURCE[0]}")"
  case "$_prov" in
    ok\ *)
      note "G0 PASS  gate logic matches ${_prov#ok } (executed script has a review trail)" ;;
    unverifiable\ *)
      note "G0 WARN  gate-logic provenance unverifiable (${_prov#unverifiable }) — landing UNCHECKED"
      echo "land-pr [G0]: WARN — cannot verify that this script matches a remote copy (${_prov#unverifiable }); a local edit to the gates would not be detected" >&2 ;;
    *)
      gate_fail 0 "this script differs from BOTH the trusted ref and the branch's upstream — a local edit to the gate logic has no review trail. Commit and push it (it is security tier: Watson + Barb), or restore it with: git -C \"\$(git rev-parse --show-toplevel)\" checkout -- tools/dev/land-pr.sh" ;;
  esac
fi

# ---------- G1: PR state ----------
pr_json="$(gh pr view "$pr" --json state,isDraft,headRefOid,title,body,headRefName,baseRefName,changedFiles,author 2>/dev/null)" || die 1 "PR #$pr not found"
state="$(jq -r '.state' <<<"$pr_json")"
is_draft="$(jq -r '.isDraft' <<<"$pr_json")"
head="$(jq -r '.headRefOid' <<<"$pr_json")"
title="$(jq -r '.title' <<<"$pr_json")"
body="$(jq -r '.body' <<<"$pr_json")"
head_branch="$(jq -r '.headRefName' <<<"$pr_json")"
# The PR's OWN base, not $DEFAULT_BRANCH: G2's behind-check below must measure
# against the branch this PR actually merges into, or a stacked PR is compared
# with the wrong ref and reports a nonsense distance. Empty is fatal rather than
# defaulted — the compare call would silently degrade to `repos/…/compare/...sha`.
base_branch="$(jq -r '.baseRefName // empty' <<<"$pr_json")"
[ -n "$base_branch" ] || die 1 "PR #$pr reports no base branch — cannot evaluate G2's behind-base check"
# G4 compares the marker author against this to disclose a self-review (ADR-0033).
# The sentinel is deliberately NOT `?` — that is `_marker_rows`'s own fallback
# for a missing `.user.login`, and two unknowns comparing equal would print
# `(SELF-REVIEW)` on a PR whose author the payload simply did not carry.
pr_author="$(jq -r '.author.login // "<no-author>"' <<<"$pr_json")"
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

# ---- G2 (cont.): the branch must not be BEHIND its base (SAD-694 surface 2) ----
# A green check above says CI passed on THIS BRANCH'S HEAD. It says nothing about
# the tree that will exist after the merge. Every gate in this script pins its
# verdict markers to the branch head — correctly, since a push voids them — but
# nothing forced reconciliation with a base that moved underneath, and a PR
# sitting behind its base with NO TEXTUAL CONFLICT lands silently. That is how
# PR #524 nearly shipped seven unfloored assertions: MERGEABLE, CI green on its
# own head, both markers valid, and only a reviewer noticing the stale merge base
# caught it. Had an earlier CONFLICTING state not forced a merge, nothing
# mechanical would have.
#
# ⚠ `mergeStateStatus == BEHIND` DOES NOT WORK HERE AND MUST NOT BE USED — the
# obvious fix, and it is measured wrong. GitHub only reports `BEHIND` when branch
# protection requires branches to be up to date before merging, and this account
# CANNOT enable branch protection (`GET /branches/main/protection` -> 403
# "Upgrade to GitHub Pro or make this repository public", recorded in
# R-INFRA-010). Measured on PR #567, whose head was genuinely one commit behind
# `main`: `mergeStateStatus=UNSTABLE`, `mergeable=MERGEABLE`, and
# `.base.sha` reporting the CURRENT tip of main rather than the merge base — so
# all three of the fields one would reach for report "fine". The compare endpoint
# is the direct measurement instead: `behind_by` counts commits the base has that
# the head does not, computed server-side from the real merge base.
#
# Fail-CLOSED on an unreadable answer, matching the G7 pre-flight: a gate that
# cannot be evaluated must not report the same thing as a gate that passed.
#
# A FUNCTION, not an inline case, so tools/dev/test-land-pr.sh can extract and
# DRIVE it — the three branches below are the whole control, and a structural
# grep for "the compare call is present" would pass on a case that classified
# every answer as clean.
behind_gate() { # $1 = the compare API's .behind_by, raw (may be empty/garbage)
  case "$1" in
    ''|*[!0123456789]*)
      gate_fail 2 "cannot determine whether PR #$pr is behind '$base_branch' (compare API returned '${1:-<nothing>}') — refusing to land on a gate that could not be evaluated. Re-run, or merge '$base_branch' into the branch and push if you already know it is stale" ;;
    0)
      note "G2 PASS  branch is not behind '$base_branch' (its merge base IS that tip)" ;;
    *)
      gate_fail 2 "PR #$pr is $1 commit(s) BEHIND '$base_branch', so the required check above certified a tree that is NOT the tree this merge produces. A non-conflicting change on '$base_branch' can be silently defeated by this branch's copy of the same file — SAD-694's second surface. Fix: git fetch origin && git merge origin/$base_branch && git push (CI re-runs on the reconciled head; that push voids the verdict markers and they must be re-obtained, which is the point)" ;;
  esac
}
behind_by="$(gh api "repos/$REPO/compare/${base_branch}...${head}" --jq '.behind_by' 2>/dev/null)" || behind_by=""
behind_gate "$behind_by"

# ---------- G3: tier ----------
# Paginated REST listing — `gh pr view --json files` truncates at 100 files,
# which would let a security-pattern file at position 101+ dodge the Barb
# gate (Watson review, PR #160).
# SAD-604 — the PREVIOUS path is unioned in, not just the new one. GitHub
# reports a rename as ONE row whose `filename` is the NEW path and whose
# `previous_filename` is the OLD one, and reading only `filename` made every
# EXACT-PATH security entry rename-blind: `tools/dev/land-pr.sh`,
# `tools/dev/setup-repo.sh`, `.claude/settings.json`. A PR renaming the funnel
# itself out of its own pattern classifies `code`, and the file it renamed is
# still the file that lands every PR. Unioning the old path means a rename is
# judged at the STRICTER of the two names, which is the only safe reading —
# a rename out of a gated path is exactly the move worth gating.
# (The `.claude/commands/**` and `.claude/agents/**` half of SAD-604 is already
# closed by SAD-546's whole-directory globs; this closes the exact-path half,
# which that change explicitly left open.)
# ONE fetch, both derivations. The reconciliation below has to prove that the
# list actually handed to `tier_of` is complete — so it must count THAT fetch.
# A first cut issued a SECOND independent `--paginate` request and counted it,
# which is a fail-OPEN in the guard's own direction: if call #1 truncates and
# call #2 is complete, the guard passes while the classified list is short
# (Watson, PR #458 round 3). It also doubled the traffic that could trigger the
# very failure it reports.
#
# `@json` gives ONE JSON-escaped line per API row. Counting `.filename` lines
# instead would count NEWLINES: git permits them in paths and the API returns
# them raw, so `[{"filename":"a\nb"},{"filename":"c"}]` is 2 rows but 3 lines —
# the same inflation defect as the unioned list, at a lower rate.
# PROJECTED in the --jq: the full row carries `patch`, `blob_url`, `raw_url` and
# `contents_url` — measured 10.5 KB/row where 67 bytes suffice. On the 3000-row
# PR this guard exists for that is ~31 MB through the pipeline (4.7 s, 216 MB
# RSS), 99.7% of it waste, and it is what makes an OOM mid-pipe plausible — i.e.
# the mechanism behind the empty-list failure the assertion below now catches.
# The DERIVED `files` list and `api_rows` count are byte-identical to the
# unprojected form (Watson verified across modified / added / removed / renamed
# rows and paths containing newlines, tabs, quotes, backslashes and multi-byte
# UTF-8). `_rows` itself is NOT identical — it is ~40% smaller, which is the
# whole point; a reader who checks the literal claim against `_rows` would find
# it false and might revert the projection.
_rows="$(gh api "repos/$REPO/pulls/$pr/files" --paginate --jq '.[] | {filename, previous_filename} | @json')" \
  || die 3 "could not enumerate PR #$pr's changed files (API error) — refusing to classify from a partial list"
[ -n "$_rows" ] || die 3 "PR #$pr has no changed files?"
# Counted with a bash-native `while read` loop, NOT `wc -l`. Two failure modes disappear
# rather than being guarded against (Barb, PR #458 delta):
#   • `wc` DYING left api_rows empty, and `[ "" -lt "$changed_files" ]` returns 2
#     (a usage error), not 0 — so the truncation reconciliation below was skipped
#     SILENTLY. A fail-OPEN nested inside a fail-closed guard. No external process
#     means nothing to die.
#   • BSD/macOS `wc` RIGHT-JUSTIFIES into a padded field ("      12") where GNU
#     does not, and `$( )` strips trailing newlines but not leading blanks. A
#     numeric type-assert on that raw value would have hard-failed EVERY macOS
#     landing — this script ships to agent-pr-flow adopters, which is why
#     test-land-pr.sh already writes `[[:space:]]` rather than `\s` for BSD grep.
#     The arithmetic assignment `api_rows=$((api_rows+1))` yields an integer by
#     construction: no padding, no locale, and no type-assert needed at all.
#     ⚠ An earlier revision used `mapfile` + `${#array[@]}` here. There is no
#     array any more — do NOT restore one from this justification; `mapfile` is
#     bash 4+ and stock macOS /bin/bash is 3.2.57, which is the defect this
#     replaced (Watson, PR #458 delta).
# ⚠ A `while read` COUNTER, NOT `mapfile`. `mapfile` is bash 4+, and stock macOS
# `/bin/bash` is 3.2.57 — so the round-7 "macOS portability fix" was written with
# a builtin macOS's own shell lacks. Under `set -u` that is fatal on every macOS
# landing (`mapfile: command not found`, then `_rowarr: unbound variable`), with
# no `die()` message and no gate number to diagnose it by: the identical defect
# class the round-7 commit claimed to remove, now failing less legibly.
# (De-facto mitigated — `.claude/hooks/pre-bash-safety.sh` already uses `mapfile`,
# so bash 4 is effectively a bundle requirement — but nothing DOCUMENTS that, and
# the comment above built a BSD/macOS argument and then landed on a bash-4-only
# construct. Watson, PR #458 delta.)
# `$_rows` is asserted non-empty directly above, so the here-string cannot yield a
# spurious single empty element.
api_rows=0; while IFS= read -r _; do api_rows=$((api_rows+1)); done <<<"$_rows"

# SAD-604 — the PREVIOUS path is unioned in, not just the new one. GitHub
# reports a rename as ONE row whose `filename` is the NEW path and whose
# `previous_filename` is the OLD one, and reading only `filename` made every
# EXACT-PATH security entry rename-blind: `tools/dev/land-pr.sh`,
# `tools/dev/setup-repo.sh`, `.claude/settings.json`. A PR renaming the funnel
# itself out of its own pattern classifies `code`, and the file it renamed is
# still the file that lands every PR. Unioning the old path means a rename is
# judged at the STRICTER of the two names, which is the only safe reading.
# ⚠ ASSERT THE LIST THAT GETS CLASSIFIED, not just the fetch. The `[ -n "$_rows" ]`
# die above covers the API response; this derivation is a SEPARATE stage, and a jq
# death partway through leaves the list SHORT rather than empty. If the dropped
# line is the only security-matching path, a security PR classifies `code` — which
# under review.codeTierPolicy=ci-only lands on green CI with ZERO review. So the
# failure direction of this stage is "a security PR lands unreviewed", inside a
# block whose own comment says it refuses to classify from a partial list.
#
# THE PIPE STATUS IS CHECKED DIRECTLY, via a SUBSHELL-LOCAL `pipefail`. An earlier
# cut inferred truncation from a LINE COUNT instead. Both reviewers independently
# proved that heuristic unsound, by execution, in both directions:
#
#   • IT MISSES REAL TRUNCATION. Its slack equals the rename count, because a
#     rename row contributes two paths — so a PR with R renames can lose R paths
#     and still satisfy `derived >= api_rows`. Barb's PoC: 5 rows, 3 renames, one
#     security path; jq SIGKILLed mid-stream; guard PASSES and the truncated list
#     classifies NOT security. ⚠ Aggravating and verified live: `gh api
#     .../pulls/{n}/files` returns PATH-SORTED rows, so a mid-pipe death drops the
#     ALPHABETICAL TAIL — precisely where `tools/**` and `server/**` sit, the two
#     directories this PR just promoted to security tier.
#   • IT FALSE-TRIPS A COMPLETE DERIVATION. A path containing a literal newline
#     (git permits it; the API returns it JSON-escaped) splits into fragments that
#     collide with other rows under `sort -u`, netting DOWN. Barb's PoC: 3 rows
#     including `a<LF>b` derives 2 lines against api_rows 3 and dies claiming a
#     truncation that never happened. My comment had asserted the exact opposite —
#     that newlines "push the count UP, so the comparison errs toward passing".
#
# `set -o pipefail` inside `$( )` is local to that subshell — it does not change
# the script's global behaviour — and it observes the thing actually cared about:
# it returns 137 on a SIGNAL death (the SIGKILL case the counter misses), 5 on a
# FATAL PARSE error, and 0 on the newline case where the counter false-trips.
# ⚠ Scope it exactly: a jq PER-INPUT RUNTIME error on a NON-FINAL row drops
# that row and exits 0 — jq's status reflects only the last input's outcome
# (Barb measured: bad-first and bad-middle both exit 0 with the row silently
# dropped). So `pipefail` does not cover that shape. What actually rules it
# out today is the ROW-SHAPE INVARIANT from gh's `{filename, previous_filename}
# | @json` projection: every line is an object literal and `.filename` on an
# object cannot throw. That invariant is unasserted, so do not weaken the
# projection without adding one — an earlier draft of this comment claimed
# pipefail covered mid-stream errors outright, which is how the next round
# removes the thing that is actually holding. No premise about GitHub's filename uniqueness, `sort`'s collation,
# or rename counts. The counter is NOT kept alongside it: belt-and-braces here
# would mean re-importing the newline false-trip for no added coverage
# (Watson S-1 + Barb MEDIUM, PR #458 delta — converged independently).
#
# LC_ALL=C on `sort` specifically: the locale preamble at the top of this file
# declines to pin LC_COLLATE, and its stated justification WAS that there were no
# collation-dependent ORDERING operations here (`sort` / `uniq` / `[[ < ]]`).
# Range expressions elsewhere ARE collation-ordered and are deliberately left
# unpinned — which is why this file's SAD-id digit classes are ENUMERATED rather
# than ranged. Ranges are deliberately KEPT elsewhere (the marker and config
# validators); read the preamble itself, not this pointer, for the list.
# `sort -u` broke the ORDERING invariant when it was added in this PR, which is
# why the preamble now names it. Pinning it as a COMMAND PREFIX affects only
# `sort`, so the LC_CTYPE reasoning the preamble protects is untouched, and it
# removes the dependency on GNU sort's memcmp tiebreak being present in the
# caller's locale. It also closes a sharper case: under a UTF-8 collation
# `sort -u` can treat two DISTINCT byte sequences as equal and drop one — losing
# a path from the classified list outright. Byte comparison eliminates that.
files="$(set -o pipefail; printf '%s\n' "$_rows" \
  | jq -r '.filename, (.previous_filename // empty)' | LC_ALL=C sort -u)" \
  || die 3 "PR #$pr: the path derivation failed mid-pipe — refusing to classify from a partial list (fail-closed)"
[ -n "$files" ] || die 3 "PR #$pr: derived no paths from $api_rows API rows — refusing to classify from an empty list (fail-closed)"

# TRUNCATION RECONCILIATION (Barb, PR #458). `--paginate` fixed the PR-#160
# defect where `gh pr view --json files` capped at 100 and a security file at
# position 101+ dodged the gate. But GitHub caps `/pulls/{n}/files` at 3000 rows
# TOTAL regardless of pagination, so the identical defect returns at a higher
# threshold — and under codeTierPolicy=ci-only a truncated tier lands with zero
# review. Compared against API ROWS, never the unioned list: the union adds a row
# per rename, so it inflates independently of truncation and a rename-heavy PR
# would satisfy the guard while still being truncated.
#
# Not executed against a 3001-file PR — the cap is GitHub-documented and building
# one against the live repo is not worth it. What IS executed is the absence of
# any reconciliation before this change.
changed_files="$(jq -r '.changedFiles // empty' <<<"$pr_json")"
if [ -n "$changed_files" ] && [ "$api_rows" -lt "$changed_files" ]; then
  die 3 "PR #$pr reports $changed_files changed files but the API returned only $api_rows rows — the 3000-file cap truncated the tier input, so the tier would be computed from a PARTIAL diff (fail-closed)"
fi

# Tier patterns come from workflow.config.json (globs, converted to ERE);
# the literals below are the instance-#1 fallbacks when the config is absent.
# The self-protection set covers .claude/commands/ and .claude/agents/ as WHOLE
# directories — see the rationale block above the securityTierPatterns fallback
# (SAD-546). Do NOT narrow either to an allowlist of filenames: the directories'
# residual tier is docs, so an allowlist is defeated by a rename, a sibling, a
# namespaced path, or a newly added destructive command.

tier="$(tier_of "$files")"
# "paths, incl. pre-rename" — the SAD-604 union means a renamed file contributes
# TWO rows, so this count is paths considered, not files changed (Watson).
note "G3 PASS  tier=$tier ($(wc -l <<<"$files") paths, incl. pre-rename)"

# ---------- G4: verdict markers ----------
# Trust only the LAST marker per agent, pinned to the exact current head SHA
# AND posted by an author with write access to this repo (SAD-358 residual 2).
#
# ---- AUTHORSHIP (SAD-358 residual 2, the free half) ----
# A verdict marker is an ORDINARY PR COMMENT. G4 verified the SHA pin but never
# WHO posted it, so on a repo with any commenter at all — an outside contributor,
# a compromised integration, a drive-by on a public fork — anyone could post
# `<!-- barb-verdict: CLEARED sha=<head> -->` and clear the security gate.
#
# `author_association` is GitHub's own answer and costs nothing: it is computed
# server-side from the commenter's relationship to the REPOSITORY, is not
# settable by the commenter, and rides along on the comments payload already
# being fetched.
#
# ⚠ BUT IT IS NOT A PERMISSION. This block used to call
# `OWNER / MEMBER / COLLABORATOR` "the write-access set". That is false, and the
# comment was itself the defect (Barb, PR #547 pre-landing audit):
#   COLLABORATOR  is returned for ANY invited collaborator, including one whose
#                 permission is read-only `pull`.
#   MEMBER        is returned for ANY member of the owning ORG, whatever that
#                 org's default base permission is — and the common default is
#                 `read`. On an org adopter, every org member could post
#                 `CLEARED` and the funnel would take it.
# Inert on THIS repo (private, single owner, no org) but this script is vendored
# to agent-pr-flow and adopted by orgs, and `.claude/references/pm/workflow.md`
# is explicit that a control asserted at a tool boundary must not claim a
# guarantee its mechanism does not provide. So the association is kept only as a
# free PRE-FILTER — it drops NONE / CONTRIBUTOR / FIRST_TIME_CONTRIBUTOR /
# MANNEQUIN without an API call — and the ANSWER now comes from the permission
# endpoint, which is the thing actually being claimed.
#
# Fail-closed by construction: an unreachable / rate-limited / 403'd lookup
# yields `unknown`, which is not in MARKER_WRITE_PERM, so the marker is dropped
# and reported by name rather than silently trusted.
#
# ⚠ PRECISE CLAIM. This closes "any COMMENTER can forge a verdict". It does NOT
# close "the PR author can forge a verdict": here the review agents post under
# Jason's own identity, so a marker from Watson and a marker typed by hand are
# indistinguishable at the API. Separating those needs the review stations to get
# their own unforgeable identity — a GitHub App or a bot PAT whose login G4 then
# pins — which is an account-level setup Jason has to perform, not something this
# script can bootstrap. That half stays open on SAD-358; ADR-0033 already
# sanctions self-review, so the residual it leaves is DISCLOSURE, not privilege —
# and G4 now discharges that disclosure explicitly (see the PASS row below).
#
# ⚠ TRAP FOR WHOEVER IMPLEMENTS THAT BOT IDENTITY. A GitHub App's comments come
# back with `author_association: NONE` — `linear-code[bot]` on this repo is the
# live example — so the pre-filter below would REJECT the very identity SAD-358
# plans to introduce, and it would reject it as a forgery attempt. Whoever wires
# the stations to an App has to allow that login explicitly (by login, resolved
# via `installation`/app id, not by association) rather than widening this set.
MARKER_TRUSTED_ASSOC=" OWNER MEMBER COLLABORATOR "
MARKER_WRITE_PERM=" admin maintain write "

# Permission lookups, cached by login. `repos/{o}/{r}/collaborators/{u}/permission`
# answers `admin|maintain|write|triage|read|none` for ANY login (verified live:
# `none`, exit 0, for a non-collaborator — not a 404), and requires push access
# to call, which the operator running the funnel necessarily has.
# ⚠ EVERY `case` PATTERN THAT CARRIES A LOGIN QUOTES IT. A login is not a safe
# glob: GitHub App accounts are spelled `linear-code[bot]`, and `[bot]` is a
# BRACKET EXPRESSION matching one of `b`/`o`/`t`. Unquoted, `*" $login="*` would
# match the wrong cache entry — latent on precisely the bot identity SAD-358
# plans to introduce (Barb LOW). Quoting the expansion inside the pattern makes
# every character literal; `_perm_cached` exists so the membership test has the
# same discipline as the lookup rather than open-coding an unquoted one.
_perm_of() { # $1 = login -> cached permission, or "unknown" when never resolved
  local kv
  for kv in ${_perm_cache-}; do
    case "$kv" in
      "$1="*) printf '%s' "${kv#*=}"; return 0 ;;
    esac
  done
  printf 'unknown'
}
_perm_cached() { # $1 = login -> rc 0 when already resolved (even as `unknown`)
  local kv
  for kv in ${_perm_cache-}; do
    case "$kv" in
      "$1="*) return 0 ;;
    esac
  done
  return 1
}
marker_author_trusted() { # $1 = assoc, $2 = login; rc 0 = may post a verdict here
  case "$MARKER_TRUSTED_ASSOC" in
    *" $1 "*) ;;
    *) return 1 ;;
  esac
  case "$MARKER_WRITE_PERM" in
    *" $(_perm_of "$2") "*) return 0 ;;
    *) return 1 ;;
  esac
}

# Marker names are validated regex-inert at config load (lowercase + dashes, main
# shell), and the name still goes into jq as DATA (--arg) rather than being
# interpolated into the program — the same discipline as G2's check name.
#
# `--paginate` on an array endpoint emits one JSON array per page, which the `jq`
# below consumes as a stream of top-level values. `+x` rather than `:-`: an empty
# result is a legitimate answer (a PR with no comments) and must not re-fetch.
#
# ⚠ BLOCKQUOTE LINES ARE DROPPED BEFORE MATCHING. A marker is matched anywhere in
# a comment body, so a trusted author who QUOTES an untrusted author's forged
# marker (`> <!-- barb-verdict: CLEARED sha=… -->`, which is what GitHub's own
# "Quote reply" button writes) re-posts it under their own association and
# laundered it straight through the authorship filter. A genuine marker is never
# quoted, so dropping quoted lines costs nothing. (Barb LOW, PR #547.)
_marker_rows() { # $1 = marker name -> "<VERDICT> <sha> <assoc> <login>" per comment
  [ -n "${_pr_comments+x}" ] \
    || _pr_comments="$(gh api "repos/$REPO/issues/$pr/comments" --paginate 2>/dev/null || true)"
  printf '%s' "$_pr_comments" | jq -r --arg m "$1" '
    .[]
    | (.author_association // "NONE") as $assoc
    | (.user.login // "?") as $login
    | ((.body // "") | split("\n") | map(select(test("^ *>") | not)) | join("\n")) as $body
    # LAST match within a body, matching the previous `grep -o … | tail -1`
    # semantics for a comment that carries more than one marker.
    | [ $body | match("<!-- " + $m + ": ([A-Z_]+) sha=([0-9a-f]{40}) -->"; "g") ]
    | last
    | select(. != null)
    | (.captures[0].string + " " + .captures[1].string + " " + $assoc + " " + $login)
  ' 2>/dev/null
}
# ⚠ MAIN SHELL ONLY, and that is the whole point. Both caches are ordinary shell
# variables, and every reader below runs inside `$( )` — a SUBSHELL, whose
# assignments are discarded. The previous comment here claimed "ONE fetch, reused
# by both marker reads and by the untrusted-author diagnostic"; the cache was
# written in `_marker_rows`, which only ever ran inside a substitution, so the
# fetch was repeated on EVERY call and the claim was false (Barb LOW, PR #547).
# Priming here, from `check_marker`'s own frame, is what makes it true — one
# comments fetch plus one permission lookup per distinct MARKER author, no matter
# how many stations or diagnostics read them. Still lazy: G4 is skipped entirely
# on a docs-tier landing, so nothing here is paid for.
#
# ⚠ THE LOOKUP IS SANITIZED, NOT TRUSTED, and the comment used to be wrong about
# why. It claimed an unreachable / rate-limited / 403'd lookup "yields `unknown`"
# via `${perm:-unknown}`. It does not: `gh api --jq` prints the ERROR BODY to
# STDOUT on a 4xx, so `perm` becomes a JSON blob and the `:-` default never
# fires. It was fail-closed only by accident — a multi-word blob happens not to
# match any `MARKER_WRITE_PERM` entry. So the status is now taken from `gh`'s
# EXIT CODE, and anything that is not a bare lowercase word is forced to
# `unknown` before it can be cached (Barb LOW-1).
#
# `LC_ALL=C sort -u` per the locale preamble's rule that every ordering operation
# pins its own call site: this one is a set-dedup of logins, and a locale that
# collates two distinct logins equal would silently drop one lookup.
_marker_prime() { # $1 = marker name
  local login perm
  [ -n "${_pr_comments+x}" ] \
    || _pr_comments="$(gh api "repos/$REPO/issues/$pr/comments" --paginate 2>/dev/null || true)"
  for login in $(_marker_rows "$1" | awk '{ print $4 }' | LC_ALL=C sort -u); do
    _perm_cached "$login" && continue
    perm="$(gh api "repos/$REPO/collaborators/$login/permission" --jq '.permission' 2>/dev/null)" \
      || perm=""
    # ENUMERATED, not `[a-z]`: the locale preamble's standing rule is that a
    # RANGE is collation-ordered and this file spells its classes out (the same
    # discipline as `SAD-[0123456789]+`). Fail-closed either way, but a range here
    # would be the same doc-drift the preamble's own enumeration just corrected.
    case "$perm" in
      *[!abcdefghijklmnopqrstuvwxyz]* | "") perm="unknown" ;;
    esac
    _perm_cache="${_perm_cache-} $login=$perm"
  done
}
# ⚠ The filter runs BEFORE the tail, not after: a forger posts AFTER the real
# reviewer, so filtering an already-tailed row would drop the genuine verdict and
# accept nothing. The login rides along because G4 discloses it (ADR-0033).
last_marker() { # $1 = marker name -> last write-access "<VERDICT> <sha> <login>"
  local verdict sha assoc login out=""
  while read -r verdict sha assoc login; do
    [ -n "${verdict:-}" ] || continue
    marker_author_trusted "$assoc" "$login" || continue
    out="$verdict $sha $login"
  done < <(_marker_rows "$1")
  printf '%s' "$out"
}
# Diagnostic only. A marker dropped for authorship must not present as "no marker
# was ever posted" — that message would send the operator to request a review
# that already exists, instead of showing them the forgery attempt. The resolved
# PERMISSION is printed beside the association because that is now the deciding
# field: `mate(COLLABORATOR/read)` says what `mate(COLLABORATOR)` could not.
untrusted_marker_authors() { # $1 = marker name -> "login(ASSOC/perm), …"
  local verdict sha assoc login out=""
  while read -r verdict sha assoc login; do
    [ -n "${verdict:-}" ] || continue
    marker_author_trusted "$assoc" "$login" && continue
    out="$out$login($assoc/$(_perm_of "$login"))
"
  done < <(_marker_rows "$1")
  printf '%s' "$out" | LC_ALL=C sort -u | tr '\n' ',' | sed 's/,$//; s/,/, /g'
}
check_marker() { # $1 = marker name, $2 = required verdict, $3 = agent label
  local m verdict sha login spoof tag
  _marker_prime "$1"
  m="$(last_marker "$1")"
  # ⚠ SURFACED UNCONDITIONALLY, not only when nothing else was found. The first
  # cut consulted this inside the `-z "$m"` branch, so a forgery attempted
  # ALONGSIDE a genuine marker — the shape where someone is actively trying to
  # clear the gate — was the one case that printed nothing at all (Watson,
  # PR #547). It is a note, not a gate: an attempt does not block a landing that
  # otherwise has a real verdict, but it must never be invisible.
  #
  # ⚠ WHAT THIS INTERPOLATES INTO THE GATE TABLE. NOT a new sink class:
  # `gate_fail 4` below already puts the same string there under --dry-run
  # (gate_fail routes through note()), so this only makes an existing
  # interpolation unconditional. The three fields:
  #   login  PR-author reachable — anyone who can comment picks it. This is the
  #          one value here an author influences.
  #   assoc  a fixed GitHub enum, or the literal `NONE` fallback.
  #   perm   a fixed GitHub enum, or the literal `unknown` fail-closed fallback.
  # ✅ The escape-interpretation half of this analysis is CLOSED as of SAD-690:
  # note() accumulates real newlines and the table renders with printf '%s', so
  # no interpolated text is escape-expanded at render time. The reasoning above
  # is kept because it still describes WHO controls each field — which matters
  # for the row's credibility — but it is no longer the thing holding the sink
  # shut. The earlier note here said all three "close if note() is ever hardened
  # to printf '%s' (filed separately)"; that is this change.
  spoof="$(untrusted_marker_authors "$1")"
  [ -z "$spoof" ] || note "G4 NOTE  $1 marker(s) IGNORED for lack of write access: $spoof"
  if [ -z "$m" ]; then
    if [ -n "$spoof" ]; then
      gate_fail 4 "the only $1 marker(s) on PR #$pr were posted by author(s) WITHOUT write access — $spoof — and are ignored. A verdict marker is an ordinary comment; G4 requires the poster's resolved repo permission to be admin/maintain/write (SAD-358). Request a real $3 review."
    else
      gate_fail 4 "no $1 marker comment on PR #$pr — request a $3 review"
    fi
    return
  fi
  read -r verdict sha login <<<"$m"
  if [ "$sha" != "$head" ]; then
    gate_fail 4 "$1 is for stale sha ${sha:0:9} (head is ${head:0:9}) — pushes void verdicts; get a fresh/delta review"
  elif [ "$verdict" != "$2" ]; then
    gate_fail 4 "$1 verdict is $verdict, not $2"
  else
    # ⚠ THE ROW STATES ITS BOUNDED CLAIM UNCONDITIONALLY, not just on self-review.
    # `G4 PASS  barb-verdict CLEARED @ head` reads as "a reviewer cleared this"
    # when all G4 actually knows is "a comment carrying this marker and this head
    # SHA exists, from a login with write access". It cannot know a review was
    # PERFORMED, and on this repo Watson, Barb and the author are ONE GitHub
    # identity, so a self-posted marker is byte-identical to a genuine one.
    #
    # The first cut disclosed that only via a `(SELF-REVIEW)` tag. Two problems,
    # both real: the NON-self case still read as "a reviewer cleared this", which
    # is the overclaim; and on this repo the tag fires on essentially every gated
    # PR, so it becomes constant background text — the same alarm-fatigue
    # argument this file already applies to `sad_hidden`, which is why the flag
    # there compares ANCHOR SETS rather than "something was filtered". A caveat
    # that fires every time conveys nothing on the occasion it matters. So the
    # bounded claim is stated on every PASS and the tag is kept as the EXTRA bit
    # of information it actually is. (Barb, PR #547 delta.)
    tag=""
    [ "$login" = "$pr_author" ] && tag="; SELF-REVIEW (ADR-0033)"
    note "G4 PASS  $1 $2 @ head — marker by @$login; G4 attests SHA pinning + write access, not that a review was performed$tag"
  fi
}
if [ "$tier" = "docs" ]; then
  note "G4 SKIP  docs tier — CI-alone policy"
elif [ "$tier" = "code" ] && [ "$CODE_TIER_POLICY" = "ci-only" ]; then
  # Explicit instance opt-in (review.codeTierPolicy) — NOT a disabled station:
  # security tier still runs both check_marker calls below unconditionally.
  note "G4 SKIP  code tier — ci-only policy (review.codeTierPolicy; reviews at the owning agent's judgment)"
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
if grep -qE 'SAD-[0123456789]+' <<<"$title$body"; then
  note "G5 PASS  SAD linkage present"
else
  note "G5 WARN  no SAD-N in title/body — Linear won't auto-transition"
  echo "land-pr [G5]: WARN — no SAD-N in title/body; Linear won't auto-transition" >&2
fi

# ---- branch-vs-trailer mismatch (SAD-599; ADVISORY, never a gate) ----
# Linear drives issue transitions off the BRANCH/PR LINK, not off the closing
# keyword (references/pm/linear.md §"branch name is a closing channel"). So when
# a PR is re-scoped mid-review and its trailer is corrected to a different issue,
# merging still transitions the issue named by the BRANCH — silently, and against
# intent. On PR #428 that would have marked a live production bug Done while the
# bug was still open and docs/requirements.md still recorded it unfixed.
#
# ⚠ COMPUTED HERE — BEFORE G6 AND BEFORE THE DRY-RUN STOP — not at G8 (Watson,
# PR #458). The stated purpose is that the restore be "a managed consequence
# decided BEFORE landing rather than a discovery after it", and a first cut that
# printed only in the close-out delivered exactly the opposite: `--dry-run`
# returned first so it never showed, and by the time it printed the branch link
# had already fired. The detailed restore instructions still print at G8; this is
# the part that has to be visible while the landing can still be reconsidered.
#
# Deliberately ADVISORY: a mismatch is legitimate whenever a scope split has
# happened, which is a pattern worth keeping rather than forbidding.
resolve_sad "$title" "$body"
branch_sad="$(printf '%s' "$head_branch" | grep -oiE '(^|[^A-Za-z0-9])SAD-[0123456789]+' \
  | grep -oiE 'SAD-[0123456789]+' | tr '[:lower:]' '[:upper:]' | head -1)"
branch_mismatch=""
if [ -n "$branch_sad" ]; then
  case " $sad_pick " in
    *" $branch_sad "*) ;;
    # Also warns when the trailer resolves NOTHING — the branch still drives
    # Linear, so "no trailer" is the case where the mismatch is least visible.
    *) branch_mismatch="$branch_sad" ;;
  esac
fi
if [ -n "$branch_mismatch" ]; then
  note "G5 WARN  branch names $branch_mismatch, trailer names ${sad_pick:-<none>} — the branch link ALSO transitions $branch_mismatch"
  echo "land-pr [G5]: WARN — branch/trailer mismatch. The head branch names $branch_mismatch; the closing trailer names ${sad_pick:-<none>}. Linear transitions off the BRANCH LINK, so merging drives $branch_mismatch toward Done as well. Decide now whether that is intended — the close-out prints the restore steps." >&2
fi
# ⚠ gate_advise, NOT note (SAD-718). Every fix in PR #547 converged on this flag
# — the whole point of that round was to turn SILENT wrong-issue writes into
# flagged ones — and the flag was then surfaced only as advisory text. Under
# `--dry-run` the run still printed "all gates green — a real run would merge"
# and exited 0 with the steering signal set, so the strongest outcome the entire
# hidden-steering surface could produce was a note the operator had no reason to
# weigh. `gate_advise` makes it a FAIL row that blocks the DRY RUN and leaves a
# real landing advisory, which is the "an operator validating a PR sees it before
# committing to the merge" ask, without hard-blocking a detection whose
# positional clause has a genuine false-positive rate (an em dash written flush
# against a SAD-N token trips clause (c) — see resolve_sad).
#
# The stderr line below and the G8 close-out both stay, because the issue's other
# requirement is that the gate table must not be the ONLY place this appears when
# the landing is real.
if [ -n "$sad_hidden" ]; then
  gate_advise 5 "hidden characters in the title/body CHANGE which issue resolves — the rendered PR and its raw bytes disagree (SAD-589). Remove the hidden SAD-N from the title/body and re-run. A REAL run proceeds with only a WARN, so do NOT clear this by dropping --dry-run"
  echo "land-pr [G5]: WARN — the title/body carry HTML comments or invisible characters that CHANGE the resolved issue, so the rendered PR and its raw bytes disagree. Resolution used the reviewer-visible text; verify before landing." >&2
fi

# ---------- dry-run stop ----------
if [ "$dry_run" = "1" ]; then
  echo "land-pr: DRY RUN — PR #$pr tier=$tier"
  printf '%s' "$gate_rows"
  if [ "$landing_blocked" != "0" ]; then
    echo "DRY RUN: landing BLOCKED by the gates above."
  elif [ "$landing_advisory" != "0" ]; then
    # Non-zero, deliberately — this is the adjudication surface and it must stop
    # a driving agent — but it says what it is. ⚠ The only way past it today is
    # to omit --dry-run, which is an undocumented, unlogged, all-or-nothing
    # bypass. That is a worse override than an explicit flag and is exactly why
    # the STOP row carries its own remediation text; see SAD-718.
    echo "DRY RUN: STOPPED for adjudication — no hard gate failed, and a real run WOULD merge with a WARN on the STOP row(s) above. Resolve the cause, do not clear it by dropping --dry-run."
  else
    echo "DRY RUN: all gates green — a real run would merge."
  fi
  # ⚠⚠ THE `exit` IS THE DRY RUN. Without it the run FALLS THROUGH TO G6 AND
  # MERGES — and in --dry-run mode `gate_fail` only records rows, so every gate
  # failure above becomes decoration and the merge happens anyway.
  #
  # This is not hypothetical and it is not a hazard someone reasoned about: it
  # HAPPENED, on 2026-08-12, while this very block was being edited. The
  # replacement for `exit "$landing_blocked"` was written as a bare
  # `[ ... ] && [ ... ]` — correct exit STATUS, no exit — and the next
  # `land-pr.sh 570 --dry-run` merged PR #570 with both verdict-marker gates
  # sitting in the table as FAIL rows. `tools/dev/test-land-pr.sh` now pins the
  # `exit` itself, because the thing that failed was an edit to this line.
  # 0 = clean · 1 = a hard gate blocked · 2 = an advisory stopped. Any non-zero
  # still means "do not proceed", so a driving agent needs no change — but the
  # distinction the twelve lines above spend so much care making is now readable
  # by a machine, not only by a human reading the prose (Watson, PR #582).
  # One `exit` per line, deliberately: the structural pin greps for an `exit`
  # statement at the start of a line, and a `then exit 1` on the same line as its
  # `if` slips past it. Keeping the pin strict is worth more than the two lines.
  if [ "$landing_blocked" != "0" ]; then
    exit 1
  elif [ "$landing_advisory" != "0" ]; then
    exit 2
  fi
  exit 0
fi

# ---------- G6: merge ----------
# ⚠ THE SINK'S OWN GUARD, independent of the dry-run stop above (Barb, PR #582
# HIGH-1). Pinning the terminator defends ONE statement; a predicate inside that
# block which the probe's fixture cannot reproduce — `[ "$tier" = "security" ]`,
# or any env var — satisfies every pin and falls straight through to here.
# Measured at 292/0 with exactly that shape, aimed at the tier that requires two
# reviewers. Reaching this line with dry_run=1 is not a state to recover from,
# it is proof the stop above was defeated, so it dies rather than returning 0.
[ "$_DRY_RUN_PARSED" != "1" ] || die 6 "reached the merge with --dry-run set — the dry-run stop was bypassed. Do NOT re-run without --dry-run; the funnel is broken and this is how SAD-740 happened"
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
# Sync the LOCAL default branch after the merge. It may live in a DIFFERENT
# worktree than the one we're landing from (the common case once work happens
# per-issue in worktrees), so resolve the worktree that actually holds
# $DEFAULT_BRANCH instead of assuming it is the cwd. Fail-safe: fast-forward
# ONLY, only when that worktree is CLEAN, and never touch any other branch — a
# shared checkout may hold another session's uncommitted work.
default_wt=""; _wt=""
while IFS= read -r _line; do
  case "$_line" in
    "worktree "*) _wt="${_line#worktree }" ;;
    "branch refs/heads/$DEFAULT_BRANCH") default_wt="$_wt"; break ;;
  esac
done < <(git worktree list --porcelain 2>/dev/null)

# ---- SAD-681 ignored-collision pre-flight (computed BEFORE the chain) ----
# `status --porcelain` never listed IGNORED files in either version, so an
# incoming commit landing a tracked file at a path the checkout holds as an
# ignored file overwrites it with NO warning and exit 0 — git's loud refusal
# covers untracked, not ignored. The hole predates SAD-681, but the old
# untracked check was INCIDENTALLY shielding it (the primary almost always has
# untracked dirt — the whole premise of SAD-681), so removing that shield
# without closing the hole would be a net regression. Highest-value targets are
# this repo's own git.copyIntoWorktree entries, local.properties and
# google-services.json. BOTH ARE SECURITY TIER as of SAD-686, so the anomalous
# commit that would reach this block now needs Watson + Barb to land — this
# pre-flight is the second control, no longer the only one. ⚠ It is still needed:
# the tier gate stops an UNREVIEWED clobber, not a reviewed-and-wrong one, and
# the silent-overwrite mechanic it guards is unchanged.
# ⚠ `google-services.json` is matched SLASH-LESS, at any depth. The Google
# Services plugin resolves a SET of per-variant candidates and takes the deepest,
# so `app/src/debug/google-services.json` outranks the module-root copy — an
# anchored `app/…` pattern left the higher-priority paths ungated (Watson + Barb,
# PR #571).
#
# Four properties this block must have, each of which was a review finding:
#  1. --no-renames. Rename detection is ON by default, so an incoming
#     `git mv other/f local.properties` classifies R, --diff-filter=A misses it,
#     and the clobber is reachable again. (Watson Suggestion + Barb M-1, both
#     with a working PoC.)
#  2. PRESENCE-gated. `check-ignore` answers "does a RULE match", not "is there
#     a file to lose". Without the `-e` test this warns — and refuses to sync —
#     for any incoming path merely matching an ignore rule. Not hypothetical:
#     .gitignore ignores docs/dogfood/**/*.wav and **/*.db while the repo
#     force-adds exactly those as evidence, so the next dogfood PR would block
#     every operator's sync, re-creating the symptom SAD-681 exists to remove.
#     (Barb L-2.)
#  3. Fail CLOSED on an unknown. Statuses are checked per-stage, NOT via a
#     pipeline status: `set -o pipefail` returns the RIGHTMOST non-zero, so a
#     diff OOM-killed to 137 alongside check-ignore's ordinary 1 would report 1
#     and look like "no collision". This runner is a documented OOM repeat
#     offender (SAD-465), so that is a live fail-open, not a theoretical one.
#     (Barb L-1.)
#  4. NUL-delimited, and NO path text in the message. `--name-only` C-QUOTES
#     unusual paths: a real newline becomes the two characters `\` `n`, which
#     `tr '\n' ' '` does not touch, and note()'s output USED TO BE rendered by
#     `printf '%b'` — which INTERPRETS backslash escapes. A landed path could
#     therefore forge a `G7 PASS` row and, with `\033[2K\033[1A`, erase the real
#     warning above it. `-z` emits raw bytes with no quoting, and the message
#     carries a COUNT plus — when the list file could be created — a POINTER TO
#     A TEMP FILE holding the list, rather than the paths; the sink is removed
#     instead of escaped. (Barb M-2.) The pointer is conditional: on a mktemp
#     failure the message degrades to the count alone.
#     ⚠ THE SINK ITSELF IS NOW HARDENED (SAD-690) — note() accumulates real
#     newlines and the table renders with `printf '%s'`. This property is
#     therefore belt-and-braces rather than the thing standing between a landed
#     path and a forged row. KEEP IT ANYWAY, and keep its regression pin: two
#     independent controls over the highest-value forgery target in the funnel is
#     the intended posture, and "the sink is safe now" is exactly the reasoning
#     that would let path text back into a message and leave the next person
#     depending on a single control they did not know was single.
#     ⚠ It briefly carried a reproduction COMMAND instead; that was deleted
#     because the command's own `tr '\0' '\n'` was itself mangled by this very
#     sink. Do not reintroduce one. (Watson Important, PR #529 round 4.)
#     Command substitution DROPS NUL bytes, so the list goes through temp files
#     rather than a variable.
_collide_n=0; _collide_err=0; _collide_list=""
if [ -n "$default_wt" ]; then
  # Explicit templates, not bare `mktemp`: BSD/macOS `mktemp` REQUIRES a template
  # or -t and fails outright without one. Bare calls here would set
  # _collide_err=1 on every macOS run — fail-closed, so safe, but it would
  # silently disable the pre-flight AND permanently re-break SAD-681 (the sync
  # would never happen) for every agent-pr-flow adopter on a Mac. (Barb, PR #529.)
  _dtmp="$(mktemp "${TMPDIR:-/tmp}/land-pr-g7-diff.XXXXXXXXXX" 2>/dev/null)"
  _ctmp="$(mktemp "${TMPDIR:-/tmp}/land-pr-g7-ignored.XXXXXXXXXX" 2>/dev/null)"
  if [ -z "$_dtmp" ] || [ -z "$_ctmp" ]; then
    _collide_err=1
  else
    if git -C "$default_wt" diff -z --no-renames --name-only --diff-filter=A \
         "HEAD..origin/$DEFAULT_BRANCH" >"$_dtmp" 2>/dev/null; then
      git -C "$default_wt" check-ignore -z --stdin <"$_dtmp" >"$_ctmp" 2>/dev/null
      # 0 = some path is ignored, 1 = none are. Anything else is an UNKNOWN.
      case "$?" in
        0|1) # Explicit template, not bare `mktemp`: this file SURVIVES the run,
             # so a `tmp.Ds3aBo53pc` blob is undecipherable to an operator who
             # lost the scrollback, and stale ones cannot be reaped by glob. The
             # template form (not `-t`) is the BSD/macOS-portable spelling this
             # script's portability doctrine calls for. (Watson, PR #529.)
             _ftmp="$(mktemp "${TMPDIR:-/tmp}/land-pr-g7-collisions.XXXXXXXXXX" 2>/dev/null)"
             while IFS= read -r -d '' _p; do
               [ -n "$_p" ] || continue
               # -L as well as -e: -e follows symlinks, so a DANGLING ignored
               # symlink would go uncounted and be replaced by a regular file.
               { [ -e "$default_wt/$_p" ] || [ -L "$default_wt/$_p" ]; } || continue
               _collide_n=$((_collide_n + 1))
               # The PRESENCE-FILTERED list is written out so the WARN can point
               # at it. Writing the list to a file rather than into the message
               # is what keeps property 4 true: no path text ever reaches note().
               [ -n "$_ftmp" ] && printf '%s\0' "$_p" >>"$_ftmp"
             done <"$_ctmp"
             if [ "$_collide_n" -gt 0 ] && [ -n "$_ftmp" ]; then
               _collide_list="$_ftmp"   # deliberately NOT removed — it is the diagnostic
             else
               rm -f "$_ftmp"
             fi ;;
        *) _collide_err=1 ;;
      esac
    else
      _collide_err=1
    fi
  fi
  rm -f "$_dtmp" "$_ctmp"
fi
if [ -z "$default_wt" ]; then
  note "G7 WARN  no worktree on $DEFAULT_BRANCH — local $DEFAULT_BRANCH NOT synced (run: git -C <checkout> merge --ff-only origin/$DEFAULT_BRANCH)"
# SAD-681: `--untracked-files=no` is load-bearing, not a tidy-up. The check used
# to be a bare `status --porcelain`, which reports UNTRACKED files (`??`) as
# dirt. The practical result was that a primary checkout holding any stray
# scratch file — a note, an evidence dump, an editor workspace — silently
# stopped syncing, and the just-landed work stayed invisible in the working copy
# until someone pulled by hand. Observed on this repo's own landings: PR #522
# and PR #526 both closed with "worktree is dirty — NOT synced" while the ONLY
# dirt was untracked docs/plans/*.md scratch files.
#
# ⚠ Untracked files CAN block a fast-forward — do not restate this as "they
# cannot conflict". A fast-forward DOES rewrite the working tree (it checks out
# the new tree), and an incoming commit that adds a path currently present as
# untracked makes git refuse: "The following untracked working tree files would
# be overwritten by merge". What is actually true, and what makes skipping the
# check safe, is narrower: that refusal is ATOMIC and LOUD — the ref does not
# move and the file's content is preserved byte-for-byte. So untracked dirt can
# never cause SILENT damage, which is why it is not a reason to pre-emptively
# skip the attempt. It lands in the else branch below. (An earlier revision of
# this comment asserted the wrong mechanism AND contradicted the else branch
# twenty lines later — Watson Important, PR #529.)
#
# MODIFIED/STAGED tracked files still block, and must. Note the reason is ONLY
# the shared-checkout hazard — attempting a sync over another session's
# in-progress edits. It is NOT that `--ff-only` would refuse them anyway: git
# refuses only when the incoming commits touch the dirty paths, so an unrelated
# modified file fast-forwards cleanly and carries the modification forward
# (proven by execution, Watson Important, PR #529). Deleting this guard on the
# strength of that false half would be a real regression.
#
# The flag also makes the predicate CONFIG-DETERMINISTIC, which the bare
# `--porcelain` was not: `status.showUntrackedFiles=no` silently hid `??`
# entries from the old check, so its behaviour depended on repo/global config.
# An explicit `--untracked-files=no` outranks that knob. (Tracked dirt cannot be
# masked by any ignore mechanism — verified against status.showUntrackedFiles,
# core.excludesFile and .git/info/exclude — Barb, PR #529.)
#
# Branch identity is still guaranteed by construction — `$default_wt` is
# resolved above by matching `branch refs/heads/$DEFAULT_BRANCH` in
# `git worktree list --porcelain`, and $DEFAULT_BRANCH is validated glob-inert
# at config load, so this can only ever act on a worktree that IS on the default
# branch. Nothing here relaxes that.
elif [ -n "$(git -C "$default_wt" status --porcelain --untracked-files=no 2>/dev/null)" ]; then
  note "G7 WARN  $DEFAULT_BRANCH worktree has uncommitted TRACKED changes — NOT synced ($default_wt); fast-forward it manually when clean"
# The pre-flight verdict, computed above. Both branches WARN and skip — this
# never acts on its own.
#
# ⚠ PRECISE CLAIM, because an earlier revision over-claimed here — TWICE, and the
# second time was in this very block. Neither message interpolates a path FROM
# THE INCOMING DIFF. That is the property that matters for the M-2 class, because
# it is the only one a PR author can influence.
#
# EXHAUSTIVE list of what they DO interpolate — keep it exhaustive, since the
# first revision of this block enumerated two and a later commit silently added a
# third (Watson Important + Barb LOW, PR #529 round 4):
#   $DEFAULT_BRANCH validated at config load against [A-Za-z0-9_/-], which is
#                   escape-inert as well as glob-inert.
#   $default_wt     operator-local, straight from `git worktree list --porcelain`,
#                   NOT validated — a hostile checkout DIRECTORY NAME forges a row.
#   $_collide_n     arithmetic-only. Initialised to 0, mutated solely via
#                   $((_collide_n + 1)), and guarded by [ -gt 0 ] — it can only
#                   ever be a decimal integer, so it is escape-inert BY
#                   CONSTRUCTION rather than by validation.
#   $_collide_list  mktemp-derived. Its SUFFIX is [A-Za-z0-9] and cannot carry
#                   attacker bytes, but its PREFIX is $TMPDIR, which is
#                   unvalidated — same operator-local class as $default_wt, and
#                   marginally easier to reach (an inherited env var rather than
#                   a created directory). Barb PoC'd a forged row through it.
# None of the four is PR-author reachable. All four close at once if note() is
# ever hardened to printf '%s' (filed separately) — until then, do not add a
# fifth without re-checking this list.
#
# FYI, explicitly OUT of the list above because it is not a pre-flight message:
# the `else` row after the merge attempt interpolates $_ff_first — git's stderr,
# first line only. Safe because git puts a header line first and any hostile path
# lands on line 2+, a convention this script does NOT enforce. It was briefly
# listed above, which made the count of four look right while the MEMBERSHIP was
# wrong — it displaced $_collide_n, the entry that actually belonged. Third
# revision of this paragraph to mis-enumerate; extract the set mechanically
# before editing it. (Watson Important + Barb LOW, PR #529 round 5.)
#
# To read the list file, `cat -v` renders NUL as ^@ and contains no backslashes,
# so it is safe to run — deliberately NOT put in the message itself, which must
# stay escape-free.
#
# An earlier revision also embedded a `... | tr '\0' '\n'` reproduction command
# here. That was mangled by the very `printf '%b'` sink property 4 documents —
# bash collapsed the escapes, %b then INTERPRETED them, and the operator saw
# `tr '<NUL>' '<LF>'`, which silently exits 0 and passes its input through
# unchanged: a failure that looks like success. The list is written to a file
# instead, so the message needs no escapes at all. That file is the
# PRESENCE-FILTERED set, not check-ignore's raw output, so its contents agree
# with the count beside it (an unfiltered repro printed a superset — Watson
# Important, PR #529).
elif [ "$_collide_err" = "1" ]; then
  note "G7 WARN  local $DEFAULT_BRANCH NOT synced ($default_wt) — the ignored-collision pre-flight could not be evaluated; refusing to fast-forward (fail-closed), sync manually"
elif [ "$_collide_n" -gt 0 ]; then
  note "G7 WARN  local $DEFAULT_BRANCH NOT synced ($default_wt) — $_collide_n incoming path(s) would silently overwrite present-but-ignored file(s)${_collide_list:+; the exact NUL-delimited list was left in $_collide_list}"
# stderr is captured, not discarded: the else branch below names two causes and
# the operator needs the discriminator to tell them apart (Barb LOW, PR #529).
elif _ff_err="$(git -C "$default_wt" merge --ff-only "origin/$DEFAULT_BRANCH" 2>&1 >/dev/null)"; then
  note "G7 PASS  local $DEFAULT_BRANCH fast-forwarded ($default_wt)"
else
  # At least two causes reach here, most commonly: a genuine divergence, or an
  # incoming commit that would overwrite a file currently present but untracked
  # (git refuses that, atomically). Others exist — a stale MERGE_HEAD, an
  # index.lock, an unreadable worktree — so the message must not assert a closed
  # set. The previous wording named divergence ALONE, which would have
  # misdiagnosed the untracked-collision case the moment this change made it
  # reachable.
  # First line only, and a placeholder when git said nothing — otherwise the
  # message ends in a dangling "git said: " (Watson Nit, PR #529).
  _ff_first="${_ff_err%%$'\n'*}"
  note "G7 WARN  local $DEFAULT_BRANCH NOT fast-forwarded ($default_wt) — diverged, or an incoming file collides with an untracked one, or the tree is mid-operation; sync manually — git said: ${_ff_first:-(no stderr)}"
fi

# ---------- G8: close-out ----------
# Title and body stay SEPARATE arguments — see resolve_sad's contract.
resolve_sad "$title" "$body"
case "$sad_how" in
  anchor)   sad_note="(from the Fixes/Closes anchor)" ;;
  fallback) sad_note="(NO Fixes/Closes anchor in the title/body — first SAD-N match; VERIFY this is the issue the PR closes)" ;;
  *)        sad_note="(no SAD-N in the title/body — resolve it by hand)" ;;
esac
case "$sad_pick" in *\ *) sad_note="$sad_note — this PR closes SEVERAL issues; verify EACH" ;; esac
[ -n "$sad_hidden" ] && sad_note="$sad_note — ⚠ the title/body carried HTML comments or invisible (zero-width / bidi) characters that CHANGED which issue resolves, so the RENDERED PR and its raw bytes disagree; resolution used the reviewer-visible text — VERIFY this is the issue the PR closes (SAD-589)"
echo ""
echo "land-pr: PR #$pr LANDED — merge commit ${merge_sha:0:9}"
printf '%s' "$gate_rows"
echo ""
echo "CLOSE-OUT (3 surfaces — see .claude/references/pm/workflow.md §7):"
echo "  1. Linear: fire Radar to verify ${sad_pick:-<SAD-N>} -> Done (idempotent; integration usually does it)"
echo "     ^ $sad_note"
if [ -n "$branch_mismatch" ]; then
  echo "     ⚠ BRANCH/TRAILER MISMATCH (SAD-599) — the head branch names $branch_mismatch,"
  echo "       but the closing trailer names ${sad_pick}. Linear transitions off the BRANCH LINK,"
  echo "       not the trailer, so $branch_mismatch was ALSO driven toward Done by this merge."
  echo "       Verify $branch_mismatch and, if it is not actually complete, restore it to the state"
  echo "       it held BEFORE the branch link touched it — usually Todo, NOT In Review (In Review"
  echo "       asserts 'implementation complete', a quieter falsehood than Done). Record the full"
  echo "       spurious chain in a comment, attributed to the branch-link automation."
fi
echo "  2. R-ID: update docs/requirements.md IFF this change moved a quality bar"
echo "  3. ADR/spec-row: IFF architectural (docs/decisions/ + spec amendments table)"
echo "  Worktree: git worktree remove <path> once done with the branch"
echo "  Audit trail (verdict comments): https://github.com/$REPO/pull/$pr"
exit 0
