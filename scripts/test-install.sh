#!/usr/bin/env bash
# test-install.sh — regression suite for install.sh's drift classification (SAD-548).
#
# The defect under test: `install.sh --target <repo> --force` used to overwrite ANY
# differing target file. When the target had moved AHEAD of the bundle — work done in the
# target and never ported up — the "update" was actually a REVERT, and it was silent: the
# run printed `RESULT: 0 failed, 0 warned` and left the reverted content staged in a tree
# somebody was about to commit from.
#
# Each case builds a throwaway git repo as the target and asserts on install.sh's own
# output + exit status. No network, no external state.
#
# usage: bash scripts/test-install.sh [-v]

set -u

VERBOSE=0
[ "${1:-}" = "-v" ] && VERBOSE=1

ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
INSTALL="$ROOT/install.sh"
[ -f "$INSTALL" ] || { echo "test-install.sh: cannot find install.sh at $INSTALL" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "test-install.sh: jq is required" >&2; exit 1; }

pass=0; fail=0
TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

# The manifest entry every case drives. commands/linear-triage.md is chosen because it
# carries NO {{VAR}} placeholders, so bundle bytes == installed bytes and the assertions
# do not depend on the renderer.
BUNDLE_SRC="commands/linear-triage.md"
TARGET_REL=".claude/commands/linear-triage.md"
# install.sh prints the TARGET-relative path in every message, so assertions match on that.
REL="$TARGET_REL"
REL_RE="$(printf '%s' "$REL" | sed 's/[].[^$*\\]/\\&/g')"

ok()   { pass=$((pass+1)); printf '  PASS  %s\n' "$1"; }
bad()  { fail=$((fail+1)); printf '  FAIL  %s\n' "$1"; [ -n "${2:-}" ] && printf '        %s\n' "$2"; }

# new_target <dir> — a git repo with a valid workflow.config.json, ready to install into.
new_target() {
  local d="$1"
  mkdir -p "$d/.claude"
  git -C "$d" init -q
  git -C "$d" config user.email t@t.t
  git -C "$d" config user.name t
  jq -n '{tracker:{platform:"linear",mcpPrefix:"mcp__x__",team:"T",project:"P",issueKey:"XX"},
          git:{defaultBranch:"main"},ci:{requiredCheck:"C"}}' > "$d/.claude/workflow.config.json"
  git -C "$d" add -A && git -C "$d" commit -qm init
}

run_install() { # <target> [extra args...] -> stdout+stderr in $OUT, status in $RC
  local t="$1"; shift
  OUT="$(bash "$INSTALL" --target "$t" "$@" 2>&1)"; RC=$?
  [ "$VERBOSE" = "1" ] && printf '%s\n' "$OUT" | sed 's/^/      | /'
  return 0
}

# ---------------------------------------------------------------- case 1: the SAD-548 bug
# Target has the bundle's OLD content in its history, then moved ahead. --force must refuse.
t="$TMPROOT/ahead"; new_target "$t"
AHEAD_T="$t"        # pinned: case 2 asserts against THIS target, not "whatever $t is"
mkdir -p "$t/.claude/commands"
cp "$ROOT/$BUNDLE_SRC" "$t/$TARGET_REL"                 # the bundle's current content...
git -C "$t" add -A && git -C "$t" commit -qm "install bundle version"
printf '\nlocal work done in the target, never ported up\n' >> "$t/$TARGET_REL"
git -C "$t" add -A && git -C "$t" commit -qm "target moves ahead"
run_install "$t" --force
if grep -q "^AHEAD .*$REL" <<<"$OUT" && [ "$RC" -ne 0 ]; then
  ok "ahead: --force REFUSES to revert a target that moved ahead (exit $RC)"
else
  bad "ahead: --force should refuse and exit non-zero" "rc=$RC"
fi
if grep -q "local work done in the target" "$t/$TARGET_REL"; then
  ok "ahead: the target's file was left untouched on disk"
else
  bad "ahead: the target file was overwritten — the SAD-548 defect is BACK"
fi

# ------------------------------------------------------- case 2: --clobber-local override
run_install "$AHEAD_T" --force --clobber-local
if grep -qE "^CLOBBER .*$REL_RE" <<<"$OUT" \
   && ! grep -q "local work done in the target" "$AHEAD_T/$TARGET_REL"; then
  ok "ahead: --clobber-local overrides the refusal and discards local content"
else
  bad "ahead: --clobber-local should overwrite" "rc=$RC"
fi

# ------------------------------------------------------------------- case 3: fast-forward
# A GENUINE fast-forward, built rather than faked: clone the bundle, advance the file
# there, and give the target the pre-advance content. The target's content is then really
# in the bundle's history, which is what distinguishes a fast-forward from divergence —
# so this case also guards against the divergence check over-firing and blocking the
# normal edit-upstream-then-reinstall workflow.
FWD_BUNDLE="$TMPROOT/bundle-fwd"
git clone -q "$ROOT" "$FWD_BUNDLE"
# A clone resolves to HEAD, so without this the case would exercise the last COMMITTED
# installer and never the working-tree one under test — and ADR-0031's edit-here-then-
# reinstall flow means the tree is dirty exactly when this guard matters. The bundle
# CONTENT must still come from history (that is what makes the fast-forward genuine);
# only the installer is overridden.
cp "$ROOT/install.sh" "$FWD_BUNDLE/install.sh"
# A clone carries HEAD, so a manifest entry whose SOURCE FILE is still uncommitted in the
# working tree makes the cloned bundle fail phase 1 ("bundle file missing") and this case
# reports a fast-forward regression that isn't one. Backfill any manifest source the clone
# lacks — every file EXCEPT the one under test, whose content must keep coming from history
# (that is what makes the fast-forward genuine).
while IFS= read -r rel; do
  [ "$rel" = "$BUNDLE_SRC" ] && continue
  [ -f "$FWD_BUNDLE/$rel" ] && continue
  [ -f "$ROOT/$rel" ] || continue
  mkdir -p "$FWD_BUNDLE/$(dirname "$rel")"
  cp "$ROOT/$rel" "$FWD_BUNDLE/$rel"
done < <(sed -n 's/^  "\([^|]*\)|.*/\1/p' "$ROOT/install.sh")
git -C "$FWD_BUNDLE" config user.email t@t.t
git -C "$FWD_BUNDLE" config user.name t
t="$TMPROOT/forward"; new_target "$t"
mkdir -p "$t/.claude/commands"
cp "$FWD_BUNDLE/$BUNDLE_SRC" "$t/$TARGET_REL"        # target holds the CURRENT content...
git -C "$t" add -A && git -C "$t" commit -qm "installed bundle version"
printf '\nnew work done upstream in the bundle\n' >> "$FWD_BUNDLE/$BUNDLE_SRC"
git -C "$FWD_BUNDLE" add -A && git -C "$FWD_BUNDLE" commit -qm "bundle moves ahead"
OUT="$(bash "$FWD_BUNDLE/install.sh" --target "$t" --force 2>&1)"; RC=$?
[ "$VERBOSE" = "1" ] && printf '%s\n' "$OUT" | sed 's/^/      | /'
if grep -qE "^overwrite \(--force\) +$REL_RE\$" <<<"$OUT" \
   && grep -q "new work done upstream in the bundle" "$t/$TARGET_REL"; then
  ok "forward: --force fast-forwards a target whose content IS in the bundle's history"
else
  bad "forward: a real fast-forward must not be blocked" "rc=$RC"
fi

# -------------------------------------------------------------------------- case 4: dirty
# Uncommitted local edits are unrecoverable, so they outrank everything.
t="$TMPROOT/dirty"; new_target "$t"
mkdir -p "$t/.claude/commands"
cp "$ROOT/$BUNDLE_SRC" "$t/$TARGET_REL"
git -C "$t" add -A && git -C "$t" commit -qm "install bundle version"
printf 'uncommitted edit\n' >> "$t/$TARGET_REL"          # dirty, NOT committed
run_install "$t" --force
if grep -q "^DIRTY .*$REL" <<<"$OUT" && [ "$RC" -ne 0 ] && grep -q "uncommitted edit" "$t/$TARGET_REL"; then
  ok "dirty: --force REFUSES to destroy uncommitted target work"
else
  bad "dirty: --force should refuse on an uncommitted target file" "rc=$RC"
fi

# ------------------------------------------------------------------------ case 5: unknown
# Never-committed target file: direction is unprovable, so overwrite but WARN loudly.
t="$TMPROOT/unknown"; new_target "$t"
mkdir -p "$t/.claude/commands"
printf 'untracked content\n' > "$t/$TARGET_REL"          # never committed
run_install "$t" --force
if grep -qi "WARN: UNVERIFIABLE" <<<"$OUT" && cmp -s "$ROOT/$BUNDLE_SRC" "$t/$TARGET_REL"; then
  ok "unknown: untracked target file is overwritten but WARNs that it is unverifiable"
else
  bad "unknown: expected an unverifiable WARN and an overwrite" "rc=$RC"
fi

# ----------------------------------------------------------------------- case 5b: diverged
# Both sides carry unique work: the target's content is not in the bundle's history AND
# the bundle's content is not in the target's. Overwriting drops the target's half, so
# this is not a fast-forward and must be refused. Caught for real on tools/dev/land-pr.sh.
t="$TMPROOT/diverged"; new_target "$t"
mkdir -p "$t/.claude/commands"
{ cat "$ROOT/$BUNDLE_SRC"; printf '\nwork only the TARGET has\n'; } > "$t/$TARGET_REL"
git -C "$t" add -A && git -C "$t" commit -qm "target-only work, never ported up"
run_install "$t" --force
if grep -q "^DIVERGED .*$REL" <<<"$OUT" && [ "$RC" -ne 0 ] && grep -q "work only the TARGET has" "$t/$TARGET_REL"; then
  ok "diverged: --force REFUSES when neither side's content is in the other's history"
else
  bad "diverged: --force must refuse a non-fast-forward" "rc=$RC"
fi

# --------------------------------------------------- case 5c: TEMPLATED source, diverged
# Regression for a reproduced FAIL OPEN. Templated sources store {{VAR}} in bundle history
# while the target stores RENDERED bytes, so blob OIDs can never match. An earlier cut
# skipped the fast-forward confirmation for them entirely and let `forward` stand —
# clobbering local work with exit 0 and an indistinguishable-from-clean `overwrite` line.
#
# The `ahead` check does NOT cover this: it needs today's render to exist verbatim as a
# past commit, which a squash-merge repo (install + local edit in ONE commit) defeats, as
# does any config change. This is the exact shape of two of the five files in the original
# incident, so it gets its own case.
TPL_SRC="references/workflow.md.tmpl"
TPL_REL=".claude/references/pm/workflow.md"
TPL_RE="$(printf '%s' "$TPL_REL" | sed 's/[].[^$*\\]/\\&/g')"
t="$TMPROOT/templated"; new_target "$t"
TPL_T="$t"          # pinned: case 5d asserts against THIS target, not "whatever $t is"
mkdir -p "$t/.claude/references/pm"
# Render the bundle's template the way install.sh would, then append local work — and
# commit BOTH in one commit, so the pristine render is nowhere in history.
ISSUE_KEY=$(jq -r '.tracker.issueKey' "$t/.claude/workflow.config.json")
DEFAULT_BRANCH=$(jq -r '.git.defaultBranch' "$t/.claude/workflow.config.json")
sed -e "s/{{ISSUE_KEY}}/$ISSUE_KEY/g" -e "s/{{DEFAULT_BRANCH}}/$DEFAULT_BRANCH/g" \
    -e "s/{{TEAM}}/T/g" -e "s/{{PROJECT}}/P/g" -e "s/{{MCP_PREFIX}}/mcp__x__/g" \
    -e "s/{{REQUIRED_CHECK}}/C/g" "$ROOT/$TPL_SRC" > "$t/$TPL_REL"
printf '\nlocal section added in the target, never ported up\n' >> "$t/$TPL_REL"
git -C "$t" add -A && git -C "$t" commit -qm "install + local edit in one squash commit"
run_install "$t" --force
if grep -qE "^(DIVERGED|AHEAD|DIRTY) +$TPL_RE" <<<"$OUT" && [ "$RC" -ne 0 ] \
   && grep -q "local section added in the target" "$t/$TPL_REL"; then
  ok "templated: a TEMPLATED source is drift-checked too (post-render), not waved through"
else
  bad "templated: FAIL OPEN — templated source clobbered local work" "rc=$RC"
fi

# ------------------------------------------- case 5e: a CONFIG FLIP must not read as drift
# Flipping a documented config knob re-renders every templated file. Comparing only against
# TODAY's values makes all of them stop matching at once, so a supported one-line config
# change would report `diverged` for every templated file and — because refusals are atomic
# — block the whole install, with a remedy ("port the target's changes up") that cannot be
# acted on because there is nothing to port. Historical target configs are used for exactly
# this. Regression for a defect the fix for case 5c introduced.
t="$TMPROOT/cfgflip"; new_target "$t"
mkdir -p "$t/.claude/references/pm"
# Install cleanly under the ORIGINAL config, and commit what was installed.
bash "$INSTALL" --target "$t" >/dev/null 2>&1
git -C "$t" add -A && git -C "$t" commit -qm "adopt the bundle"
# Now flip a supported knob and commit it, exactly as an operator would.
jq '.review.codeTierPolicy = "ci-only"' "$t/.claude/workflow.config.json" > "$t/.cfg.tmp" \
  && mv "$t/.cfg.tmp" "$t/.claude/workflow.config.json"
git -C "$t" add -A && git -C "$t" commit -qm "flip review.codeTierPolicy to ci-only"
run_install "$t" --force
# Positive assertions as well as the negative one: a `! grep DIVERGED` alone is satisfied
# by an installer that prints nothing at all, so require a clean exit AND evidence the
# re-render actually happened.
if ! grep -q "^DIVERGED" <<<"$OUT" && [ "$RC" -eq 0 ] \
   && grep -q 'ci-only' "$t/.claude/references/pm/workflow.md"; then
  ok "config-flip: changing a config value re-renders cleanly instead of reading as drift"
else
  bad "config-flip: a supported config change must re-render, not report drift" "rc=$RC"
fi

# ---------------------------------------------------------- case 5d: refusal is ATOMIC
# A refused run must leave the target completely untouched — not "all the files except the
# refused ones". The docs claim "a refusal exits non-zero and changes nothing", and a
# partially-updated target after a failed run is its own trap.
before="$(git -C "$TPL_T" status --porcelain | sort)"
run_install "$TPL_T" --force
after="$(git -C "$TPL_T" status --porcelain | sort)"
if [ "$before" = "$after" ] && [ "$RC" -ne 0 ] && grep -q "nothing was installed" <<<"$OUT"; then
  ok "atomic: a refused run writes NOTHING — not even the files that would have been fine"
else
  bad "atomic: refused run modified the target" "rc=$RC"
fi

# ------------------------------------------------- case 6: no --force is still non-destructive
t="$TMPROOT/noforce"; new_target "$t"
mkdir -p "$t/.claude/commands"
printf 'target content\n' > "$t/$TARGET_REL"
git -C "$t" add -A && git -C "$t" commit -qm c
run_install "$t"
if grep -q "^DIFFERS .*$REL" <<<"$OUT" && [ "$RC" -ne 0 ] && grep -q "target content" "$t/$TARGET_REL"; then
  ok "no --force: unchanged behaviour — DIFFERS, target kept, exit non-zero"
else
  bad "no --force: should print DIFFERS and keep the target" "rc=$RC"
fi

# --------------------------------------------- case 7: identical target is a clean no-op
t="$TMPROOT/same"; new_target "$t"
mkdir -p "$t/.claude/commands"
cp "$ROOT/$BUNDLE_SRC" "$t/$TARGET_REL"
git -C "$t" add -A && git -C "$t" commit -qm c
run_install "$t" --force
if grep -qE "^skip \(unchanged\) +$REL_RE\$" <<<"$OUT" && ! grep -q "^AHEAD" <<<"$OUT"; then
  ok "identical: byte-identical target skips without tripping the drift guard"
else
  bad "identical: an unchanged file must not be classified as drift" "rc=$RC"
fi

# ------------------------------------------- case 8: non-git target degrades, not crashes
t="$TMPROOT/nogit"; mkdir -p "$t/.claude/commands"
jq -n '{tracker:{platform:"linear",mcpPrefix:"mcp__x__",team:"T",project:"P",issueKey:"XX"},
        git:{defaultBranch:"main"},ci:{requiredCheck:"C"}}' > "$t/.claude/workflow.config.json"
printf 'content in a non-git target\n' > "$t/$TARGET_REL"
run_install "$t" --force
if grep -qi "WARN: UNVERIFIABLE" <<<"$OUT"; then
  ok "non-git target: classification degrades to a WARN instead of failing"
else
  bad "non-git target: expected an unverifiable WARN" "rc=$RC"
fi

# ------------------------------------------------ case 9: --dry-run writes NOTHING
# The whole value of a --check is that it is inert. If it can write, it is just an install.
t="$TMPROOT/dryrun"; new_target "$t"
mkdir -p "$t/.claude/commands"
printf 'target content\n' > "$t/$TARGET_REL"
git -C "$t" add -A && git -C "$t" commit -qm c
before="$(git -C "$t" status --porcelain | sort)$(find "$t" -type f | sort)"
run_install "$t" --dry-run
after="$(git -C "$t" status --porcelain | sort)$(find "$t" -type f | sort)"
if [ "$before" = "$after" ] && grep -q "DRY RUN" <<<"$OUT" && grep -q "NOTHING was written" <<<"$OUT"; then
  ok "dry-run: classifies without writing a single byte to the target"
else
  bad "dry-run: the target changed during a --dry-run" "rc=$RC"
fi
# It must still report the work it would do, and exit non-zero when something is kept.
if grep -qE "^would install +\.claude/hooks/" <<<"$OUT" && [ "$RC" -ne 0 ]; then
  ok "dry-run: reports the planned actions and exits non-zero when files would be kept"
else
  bad "dry-run: expected a plan listing and a non-zero exit" "rc=$RC"
fi

# --------------------------------- case 9b: --check is an alias, and classifies drift
# Without --force a plain run never classifies — it just says DIFFERS. The point of the
# check is to learn that a differing file is AHEAD (a refusal that would abort everything)
# BEFORE running the install that gets blocked by it.
#
# Builds its OWN ahead target: case 2's --clobber-local already overwrote $AHEAD_T's file
# with the bundle's content, so reusing it here would assert against an unchanged file.
t="$TMPROOT/ahead-check"; new_target "$t"
mkdir -p "$t/.claude/commands"
cp "$ROOT/$BUNDLE_SRC" "$t/$TARGET_REL"
git -C "$t" add -A && git -C "$t" commit -qm "install bundle version"
printf '\nlocal work done in the target, never ported up\n' >> "$t/$TARGET_REL"
git -C "$t" add -A && git -C "$t" commit -qm "target moves ahead"
run_install "$t" --check
if grep -qE "^would KEEP target +$REL_RE +\[ahead\]" <<<"$OUT" && grep -q "REFUSE" <<<"$OUT"; then
  ok "check: --check classifies drift without --force and names the coming refusal"
else
  bad "check: expected an [ahead] classification naming the refusal" "rc=$RC"
fi

# ----------------------------- case 10: an out-of-set review.codeTierPolicy is rejected
# land-pr.sh aborts a landing on a value outside the enum; install.sh used to render that
# same value into workflow.md as though it were policy. Both must reject it.
t="$TMPROOT/badpolicy"; new_target "$t"
jq '.review.codeTierPolicy = "banana"' "$t/.claude/workflow.config.json" > "$t/.cfg.tmp" \
  && mv "$t/.cfg.tmp" "$t/.claude/workflow.config.json"
run_install "$t" --force
if grep -q "invalid review.codeTierPolicy" <<<"$OUT" && [ "$RC" -ne 0 ] \
   && [ ! -f "$t/.claude/references/pm/workflow.md" ]; then
  ok "codeTierPolicy: an out-of-set value FAILS the install instead of rendering a lie"
else
  bad "codeTierPolicy: 'banana' must abort before anything is written" "rc=$RC"
fi
# ...and the two in-set values must both still install cleanly (guards an over-tight check).
for pol in reviewer ci-only; do
  t="$TMPROOT/pol-$pol"; new_target "$t"
  jq --arg p "$pol" '.review.codeTierPolicy = $p' "$t/.claude/workflow.config.json" > "$t/.cfg.tmp" \
    && mv "$t/.cfg.tmp" "$t/.claude/workflow.config.json"
  run_install "$t"
  if [ "$RC" -eq 0 ] && grep -q "$pol" "$t/.claude/references/pm/workflow.md"; then
    ok "codeTierPolicy: '$pol' is accepted and rendered"
  else
    bad "codeTierPolicy: '$pol' is valid and must install" "rc=$RC"
  fi
done

# -------------------------- case 11: the close-out's artifacts are actually in the bundle
# SAD-652: commands/land.md tells the agent to run tools/dev/prune-worktrees.sh and NOT to
# hand-run `git worktree remove` instead. If the manifest does not install that script, the
# close-out step becomes a silent no-op on a fresh adopter — the exact failure SAD-418 was
# filed about. Same for the /laymans rules commands/issue.md requires every filed issue to
# follow. This asserts the referenced artifacts land on disk.
t="$TMPROOT/closeout"; new_target "$t"
run_install "$t"
missing_artifacts=""
for f in tools/dev/prune-worktrees.sh .claude/commands/prune-worktrees.md .claude/commands/laymans.md; do
  [ -f "$t/$f" ] || missing_artifacts="$missing_artifacts $f"
done
if [ -z "$missing_artifacts" ] && [ -x "$t/tools/dev/prune-worktrees.sh" ]; then
  ok "close-out: every artifact land.md/issue.md reference is installed (and the script is +x)"
else
  bad "close-out: referenced artifacts missing from the install:$missing_artifacts" "rc=$RC"
fi
# The references themselves must resolve — a dangling path in the INSTALLED command file is
# the defect, so assert against what landed in the target, not against the bundle source.
dangling=""
while IFS= read -r ref; do
  case "$ref" in
    tools/dev/*) [ -f "$t/$ref" ] || dangling="$dangling $ref" ;;
    .claude/*)   [ -f "$t/$ref" ] || dangling="$dangling $ref" ;;
  esac
done < <(grep -ohE '(tools/dev/[a-z-]+\.sh|\.claude/commands/[a-z-]+\.md)' \
           "$t/.claude/commands/land.md" "$t/.claude/commands/issue.md" | sort -u)
if [ -z "$dangling" ]; then
  ok "close-out: land.md + issue.md reference no artifact the install failed to provide"
else
  bad "close-out: installed command files point at missing artifacts:$dangling"
fi

echo ""
echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
