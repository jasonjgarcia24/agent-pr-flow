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
run_install "$t" --force --clobber-local
if grep -q "^CLOBBER" <<<"$OUT" && ! grep -q "local work done in the target" "$t/$TARGET_REL"; then
  ok "ahead: --clobber-local overrides the refusal and discards local content"
else
  bad "ahead: --clobber-local should overwrite" "rc=$RC"
fi

# ------------------------------------------------------------------- case 3: fast-forward
# The bundle carries content the target has never held. --force must overwrite.
t="$TMPROOT/forward"; new_target "$t"
mkdir -p "$t/.claude/commands"
printf 'an older revision the bundle has since replaced\n' > "$t/$TARGET_REL"
git -C "$t" add -A && git -C "$t" commit -qm "old target content"
run_install "$t" --force
if grep -qE "^overwrite \(--force\) +$REL_RE\$" <<<"$OUT" && cmp -s "$ROOT/$BUNDLE_SRC" "$t/$TARGET_REL"; then
  ok "forward: --force still overwrites when the bundle is genuinely newer"
else
  bad "forward: --force must fast-forward a stale target" "rc=$RC"
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
if grep -q "WARN: unverifiable" <<<"$OUT" && cmp -s "$ROOT/$BUNDLE_SRC" "$t/$TARGET_REL"; then
  ok "unknown: untracked target file is overwritten but WARNs that it is unverifiable"
else
  bad "unknown: expected an unverifiable WARN and an overwrite" "rc=$RC"
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
if grep -q "WARN: unverifiable" <<<"$OUT"; then
  ok "non-git target: classification degrades to a WARN instead of failing"
else
  bad "non-git target: expected an unverifiable WARN" "rc=$RC"
fi

echo ""
echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
