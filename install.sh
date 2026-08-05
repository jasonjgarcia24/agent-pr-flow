#!/usr/bin/env bash
# install.sh — install the agent-pr-flow ops bundle into a target repo (SAD-180).
#
# Usage: install.sh --target <repo> [--config <workflow.config.json>] [--force]
#
# What it does:
#   1. Copies bundle files to their target paths:
#        hooks/*                       -> .claude/hooks/
#        commands/*                    -> .claude/commands/
#        agents/*                      -> .claude/agents/
#        scripts/*                     -> tools/dev/
#        githooks/pre-push             -> .githooks/pre-push
#        ci/main-guard.yml             -> .github/workflows/main-guard.yml
#        references/workflow.md.tmpl   -> .claude/references/pm/workflow.md
#        references/pm/linear.md.tmpl  -> .claude/references/pm/linear.md
#   2. Renders {{VAR}} placeholders from the --config JSON in any file that
#      carries them (.tmpl files lose the suffix on install). Every missing
#      config key is collected and FAILS the run, listing them all — nothing
#      is written on a render failure.
#   3. Merges settings.fragment.json into <target>/.claude/settings.json via
#      jq -s '.[0] * .[1]' (fragment wins on conflicts; user keys preserved;
#      settings.local.json is NEVER touched).
#   4. Seeds <target>/.claude/workflow.config.json from --config if absent
#      (NEVER overwrites an existing one — not even with --force).
#   5. chmod +x on hooks / githooks / scripts, then runs the target's
#      tools/dev/setup-repo.sh and propagates its exit status.
#
# Idempotent: a byte-identical target file -> "skip (unchanged)"; a differing
# target file -> prints a unified diff and is KEPT (exit 1) unless --force.
#
# --force is NOT a blind overwrite (SAD-548). Before replacing a differing file it
# asks the TARGET repo's git history which direction the drift runs, and refuses to
# install a file the target is already ahead of — that is a revert wearing an
# update's clothing. See classify_drift() for the four classes and the rationale.
#
# CARVE-OUT: .claude/settings.json is a jq MERGE, not a copy, and is deliberately NOT
# drift-classified. The merge preserves every target-only key by construction, so the
# revert risk is confined to keys the fragment itself defines — a far narrower blast
# radius than a whole-file overwrite.

set -u

usage() {
  cat <<'EOF'
Usage: install.sh --target <repo> [--config <workflow.config.json>] [--force]
                  [--clobber-local]

  --target <repo>   destination repository root (required)
  --config <json>   workflow config used to render {{VAR}} placeholders and to
                    seed <repo>/.claude/workflow.config.json. If omitted, an
                    existing <repo>/.claude/workflow.config.json is used.
  --force           overwrite target files that differ (default: print a diff
                    and keep the target). --force will still REFUSE to overwrite
                    a file the target is AHEAD on, or one with uncommitted
                    changes — see below.
  --clobber-local   with --force, also overwrite AHEAD/DIRTY files, DISCARDING
                    the target's version. Last resort; port the target's work up
                    to the bundle instead.

Drift classes (--force only), decided from the two repos' own git histories:
  forward   bundle moved on from what the     -> overwritten
            target holds (confirmed)
  ahead     bundle content is already in the  -> REFUSED (installing it would
            target's history for this path       revert work the target moved past)
  diverged  neither side's content is in the  -> REFUSED (not a fast-forward)
            other's history
  dirty     target file has uncommitted work  -> REFUSED
  unknown   no target git repo / path never   -> overwritten with a loud WARN
            committed
EOF
}

TARGET=""
CONFIG=""
FORCE=0
CLOBBER=0
while [ $# -gt 0 ]; do
  case "$1" in
    --clobber-local)
      CLOBBER=1; shift ;;
    --target)
      [ -n "${2:-}" ] || { echo "install.sh: --target needs a value" >&2; exit 1; }
      TARGET="$2"; shift 2 ;;
    --config)
      [ -n "${2:-}" ] || { echo "install.sh: --config needs a value" >&2; exit 1; }
      CONFIG="$2"; shift 2 ;;
    --force)
      FORCE=1; shift ;;
    -h|--help)
      usage; exit 0 ;;
    *)
      echo "install.sh: unknown argument '$1'" >&2; usage >&2; exit 1 ;;
  esac
done

[ -n "$TARGET" ] || { echo "install.sh: --target is required" >&2; usage >&2; exit 1; }
[ -d "$TARGET" ] || { echo "install.sh: target '$TARGET' is not a directory" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "install.sh: jq is required" >&2; exit 1; }

BUNDLE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET="$(cd "$TARGET" && pwd)"

# ---------- config resolution ----------
if [ -z "$CONFIG" ] && [ -f "$TARGET/.claude/workflow.config.json" ]; then
  CONFIG="$TARGET/.claude/workflow.config.json"
  echo "install.sh: no --config given — using existing $CONFIG"
fi
if [ -n "$CONFIG" ]; then
  [ -f "$CONFIG" ] || { echo "install.sh: config '$CONFIG' not found" >&2; exit 1; }
  jq empty "$CONFIG" 2>/dev/null || { echo "install.sh: config '$CONFIG' is not valid JSON" >&2; exit 1; }
fi

# Template variables and the config keys they come from.
VAR_NAMES=(TEAM PROJECT ISSUE_KEY MCP_PREFIX DEFAULT_BRANCH REQUIRED_CHECK)
declare -A JQ_PATH=(
  [TEAM]='.tracker.team'
  [PROJECT]='.tracker.project'
  [ISSUE_KEY]='.tracker.issueKey'
  [MCP_PREFIX]='.tracker.mcpPrefix'
  [DEFAULT_BRANCH]='.git.defaultBranch'
  [REQUIRED_CHECK]='.ci.requiredCheck'
)
declare -A VAL HAVE
for v in "${VAR_NAMES[@]}"; do
  HAVE[$v]=0
  VAL[$v]=""
  if [ -n "$CONFIG" ]; then
    val="$(jq -r "${JQ_PATH[$v]} // empty" "$CONFIG")"
    if [ -n "$val" ]; then
      VAL[$v]="$val"
      HAVE[$v]=1
    fi
  fi
done

# ---------- manifest: bundle-relative src | target-relative dst | mode ----------
MANIFEST=(
  "hooks/pre-bash-safety.sh|.claude/hooks/pre-bash-safety.sh|x"
  "hooks/post-bash-secret-scan.sh|.claude/hooks/post-bash-secret-scan.sh|x"
  "hooks/lint-on-edit.sh|.claude/hooks/lint-on-edit.sh|x"
  "commands/land.md|.claude/commands/land.md|-"
  "commands/issue.md|.claude/commands/issue.md|-"
  "commands/linear-triage.md|.claude/commands/linear-triage.md|-"
  "agents/radar.md|.claude/agents/radar.md|-"
  "references/workflow.md.tmpl|.claude/references/pm/workflow.md|-"
  "references/pm/linear.md.tmpl|.claude/references/pm/linear.md|-"
  "scripts/land-pr.sh|tools/dev/land-pr.sh|x"
  "scripts/setup-repo.sh|tools/dev/setup-repo.sh|x"
  "scripts/test-hooks.sh|tools/dev/test-hooks.sh|x"
  "scripts/test-land-pr.sh|tools/dev/test-land-pr.sh|x"
  "githooks/pre-push|.githooks/pre-push|x"
  "ci/main-guard.yml|.github/workflows/main-guard.yml|-"
)

# ---------- phase 1: stage + render (nothing written to the target yet) ----------
STAGE="$(mktemp -d)" || exit 1
trap 'rm -rf "$STAGE"' EXIT

missing=""
i=0
for entry in "${MANIFEST[@]}"; do
  IFS='|' read -r src dst _mode <<<"$entry"
  abs_src="$BUNDLE/$src"
  [ -f "$abs_src" ] || { echo "install.sh: bundle file missing: $src" >&2; exit 1; }
  staged="$STAGE/$i"
  i=$((i + 1))

  # Placeholder-shaped tokens are {{UPPER_SNAKE}} only — GitHub Actions'
  # ${{ github.* }} expressions in ci/main-guard.yml do not match and the file
  # is copied byte-identical.
  if grep -qE '\{\{[A-Z_]+\}\}' "$abs_src"; then
    content="$(cat "$abs_src")"
    for v in "${VAR_NAMES[@]}"; do
      [ "${HAVE[$v]}" = "1" ] || continue
      pat="{{${v}}}"
      # Replacement is quoted: bash 5.2+ patsub_replacement would otherwise
      # expand an unquoted '&' in the value (e.g. "Build & unit test") to the
      # matched pattern.
      content="${content//"$pat"/"${VAL[$v]}"}"
    done
    printf '%s\n' "$content" > "$staged"
    leftovers="$(grep -oE '\{\{[A-Z_]+\}\}' "$staged" | sort -u)" || leftovers=""
    while IFS= read -r tok; do
      [ -n "$tok" ] || continue
      name="${tok#'{{'}"
      name="${name%'}}'}"
      if [ -n "${JQ_PATH[$name]:-}" ]; then
        missing="${missing}  $src: $tok — config key ${JQ_PATH[$name]} missing or null\n"
      else
        missing="${missing}  $src: $tok — unknown template variable (no config mapping)\n"
      fi
    done <<<"$leftovers"
  else
    cp "$abs_src" "$staged"
  fi
done

if [ -n "$missing" ]; then
  {
    echo "install.sh: FAIL — unresolved template placeholders; nothing was installed."
    printf '%b' "$missing"
    if [ -z "$CONFIG" ]; then
      echo "  (no --config given and no $TARGET/.claude/workflow.config.json found)"
    else
      echo "  (config: $CONFIG)"
    fi
  } >&2
  exit 1
fi

# ---------- phase 2: install ----------
blocked=0
ahead=0

# ---------- drift classification (SAD-548) ----------
# `--force` used to overwrite ANY differing target file. That silently reverted work
# which had been done in the target and never ported up to the bundle: the bundle copy
# was OLDER, `--force` restored it, and the run still printed a clean summary. It happened
# for real on 2026-07-30 across five files, and was caught only because a human read
# `git status` before committing.
#
# The fix is to tell the two directions apart before overwriting:
#
#   forward — the bundle content is genuinely NEW. Overwriting is a fast-forward.
#   ahead   — the bundle content is something the TARGET has already moved past. The
#             target's own git history contains this exact content for this exact path,
#             so installing it is a REVERT, not an update.
#   dirty   — the target file has uncommitted changes. Overwriting destroys work that
#             exists nowhere else.
#   unknown — no target git repo, or the path was never committed. Can't tell.
#
# The signal is the target repo's own history, so this needs no state file, no receipt,
# and no bootstrap step — it works in a fresh clone or worktree on the first run.
#
# NOTE: this is deliberately checked against the STAGED (rendered) content, not the raw
# bundle file, because rendered content is what was installed and therefore what the
# target's history recorded.
HAVE_BUNDLE_GIT=0
git -C "$BUNDLE" rev-parse --git-dir >/dev/null 2>&1 && HAVE_BUNDLE_GIT=1

DRIFT_CLASS=""
classify_drift() { # $1 = staged abs, $2 = target-relative, $3 = bundle-relative src -> $DRIFT_CLASS
  local staged="$1" rel="$2" src="$3" want st have
  DRIFT_CLASS="unknown"
  git -C "$TARGET" rev-parse --git-dir >/dev/null 2>&1 || return 0

  # Uncommitted local work outranks everything: it is not recoverable from history.
  st="$(git -C "$TARGET" status --porcelain -- "$rel" 2>/dev/null)"
  case "$st" in
    '??'*) DRIFT_CLASS="unknown"; return 0 ;;   # untracked — nothing to compare against
    ?*)    DRIFT_CLASS="dirty";   return 0 ;;
  esac

  # --path applies the target's .gitattributes filters, so the OID is computed the same
  # way git would have computed it when the content was committed.
  want="$(git -C "$TARGET" hash-object --path "$rel" -- "$staged" 2>/dev/null)" || return 0
  [ -n "$want" ] || return 0

  # Every commit that touched this path, newest first; --max-count bounds a pathological
  # history. If the staged blob appears at ANY of them, the bundle is behind the target.
  if git -C "$TARGET" rev-list --max-count=1000 --all -- "$rel" 2>/dev/null \
       | sed "s|\$|:$rel|" \
       | git -C "$TARGET" cat-file --batch-check='%(objectname)' 2>/dev/null \
       | grep -qxF "$want"; then
    DRIFT_CLASS="ahead"
    return 0
  fi

  # The staged blob is not in the target's history. That alone does NOT prove the bundle
  # is newer — both sides may carry unique work, in which case overwriting still drops
  # whatever the target had. Confirm a fast-forward POSITIVELY: does the target's current
  # content appear in the BUNDLE's history for the source path?
  #
  #   yes -> the bundle has genuinely moved on from what the target holds. Fast-forward.
  #   no  -> neither side's content is in the other's history. DIVERGED, not an update.
  #
  # This is not hypothetical: caught in the reference instance on tools/dev/land-pr.sh,
  # where target and bundle each carried fixes the other had never seen, and the
  # one-directional check above happily called it `forward`.
  #
  # LIMITATION, deliberate: only decidable for sources the renderer does not touch. A
  # templated source stores {{VAR}} in bundle history while the target stores rendered
  # bytes, so the two can never match and the question is unanswerable — templated files
  # fall through to `forward` rather than crying wolf on every legitimate bundle edit.
  # The `ahead` check above still covers them, and it is the one that catches a revert.
  if [ -n "$(git -C "$TARGET" rev-list --max-count=1 --all -- "$rel" 2>/dev/null)" ]; then
    DRIFT_CLASS="forward"
    if [ "$HAVE_BUNDLE_GIT" = "1" ] && ! grep -qE '\{\{[A-Z_]+\}\}' "$BUNDLE/$src" 2>/dev/null; then
      have="$(git -C "$BUNDLE" hash-object --path "$src" -- "$TARGET/$rel" 2>/dev/null)" || have=""
      if [ -n "$have" ] \
         && ! git -C "$BUNDLE" rev-list --max-count=1000 --all -- "$src" 2>/dev/null \
              | sed "s|\$|:$src|" \
              | git -C "$BUNDLE" cat-file --batch-check='%(objectname)' 2>/dev/null \
              | grep -qxF "$have"; then
        DRIFT_CLASS="diverged"
      fi
    fi
  fi
  return 0
}
install_file() { # $1 = staged abs path, $2 = target-relative dst, $3 = mode (x|-), $4 = bundle src
  local staged="$1" rel="$2" mode="$3" src="$4"
  local dst="$TARGET/$rel"
  mkdir -p "$(dirname "$dst")"
  if [ ! -f "$dst" ]; then
    cp "$staged" "$dst"
    if [ "$mode" = "x" ]; then chmod +x "$dst"; fi
    echo "install             $rel"
  elif cmp -s "$staged" "$dst"; then
    if [ "$mode" = "x" ]; then chmod +x "$dst"; fi
    echo "skip (unchanged)    $rel"
  elif [ "$FORCE" = "1" ]; then
    classify_drift "$staged" "$rel" "$src"
    case "$DRIFT_CLASS" in
      ahead|dirty|diverged)
        if [ "$CLOBBER" = "1" ]; then
          cp "$staged" "$dst"
          if [ "$mode" = "x" ]; then chmod +x "$dst"; fi
          echo "CLOBBER (--clobber-local) $rel — target was $DRIFT_CLASS; local content DISCARDED"
        else
          if [ "$DRIFT_CLASS" = "ahead" ]; then
            echo "AHEAD               $rel — target is AHEAD of the bundle; REFUSING to overwrite even with --force:"
            echo "    the bundle's content for this file already exists in the target's git history —"
            echo "    installing it would REVERT work the target has since moved past."
            echo "    Fix: port the target's version UP to the bundle, then re-install (ADR-0031)."
          elif [ "$DRIFT_CLASS" = "diverged" ]; then
            echo "DIVERGED            $rel — target and bundle have each moved on; REFUSING to overwrite even with --force:"
            echo "    neither side's content appears in the other's history, so this is not a"
            echo "    fast-forward — the target carries work the bundle has never seen."
            echo "    Fix: reconcile the two (port the target's changes up), then re-install."
          else
            echo "DIRTY               $rel — target has UNCOMMITTED changes; REFUSING to overwrite even with --force:"
            echo "    that work exists nowhere else. Commit or stash it first."
          fi
          echo "    Override (DISCARDS the target's version): --force --clobber-local"
          diff -u --label "$rel (target)" --label "$rel (bundle)" "$dst" "$staged" | sed 's/^/    /'
          ahead=$((ahead + 1))
        fi
        ;;
      unknown)
        cp "$staged" "$dst"
        if [ "$mode" = "x" ]; then chmod +x "$dst"; fi
        echo "overwrite (--force) $rel  ** WARN: unverifiable — no target git history for this path;"
        echo "    could not prove the bundle is not older than the target. Commit the target's files"
        echo "    so a future install can tell a fast-forward from a revert."
        ;;
      *)
        cp "$staged" "$dst"
        if [ "$mode" = "x" ]; then chmod +x "$dst"; fi
        echo "overwrite (--force) $rel"
        ;;
    esac
  else
    echo "DIFFERS             $rel — target KEPT (re-run with --force to overwrite):"
    diff -u --label "$rel (target)" --label "$rel (bundle)" "$dst" "$staged" | sed 's/^/    /'
    blocked=$((blocked + 1))
  fi
}

echo "== installing into $TARGET =="
i=0
for entry in "${MANIFEST[@]}"; do
  IFS='|' read -r src dst mode <<<"$entry"
  install_file "$STAGE/$i" "$dst" "$mode" "$src"
  i=$((i + 1))
done

# ---------- settings.fragment.json -> .claude/settings.json (jq merge) ----------
frag="$BUNDLE/settings.fragment.json"
settings="$TARGET/.claude/settings.json"
mkdir -p "$TARGET/.claude"
if [ -f "$settings" ]; then
  merged="$(jq -s '.[0] * .[1]' "$settings" "$frag")" \
    || { echo "install.sh: FAIL — could not merge settings.fragment.json into $settings" >&2; exit 1; }
else
  merged="$(jq . "$frag")" \
    || { echo "install.sh: FAIL — settings.fragment.json is not valid JSON" >&2; exit 1; }
fi
if [ -f "$settings" ] && [ "$merged" = "$(cat "$settings")" ]; then
  echo "skip (unchanged)    .claude/settings.json"
elif [ ! -f "$settings" ]; then
  printf '%s\n' "$merged" > "$settings"
  echo "install             .claude/settings.json (from settings.fragment.json)"
elif [ "$FORCE" = "1" ]; then
  printf '%s\n' "$merged" > "$settings"
  echo "merge (--force)     .claude/settings.json (jq -s '.[0] * .[1]' — fragment wins)"
else
  echo "DIFFERS             .claude/settings.json — merged result differs; target KEPT (re-run with --force to apply the merge):"
  diff -u --label ".claude/settings.json (target)" --label ".claude/settings.json (merged)" \
    "$settings" <(printf '%s\n' "$merged") | sed 's/^/    /'
  blocked=$((blocked + 1))
fi

# ---------- seed .claude/workflow.config.json (never overwrite) ----------
wcfg="$TARGET/.claude/workflow.config.json"
if [ -n "$CONFIG" ]; then
  if [ -f "$wcfg" ]; then
    if cmp -s "$CONFIG" "$wcfg"; then
      echo "skip (unchanged)    .claude/workflow.config.json"
    else
      echo "skip (exists)       .claude/workflow.config.json — NEVER overwritten; edit it in place"
    fi
  else
    cp "$CONFIG" "$wcfg"
    echo "install             .claude/workflow.config.json (from $CONFIG)"
  fi
else
  echo "note:               no config available — .claude/workflow.config.json not seeded"
fi

# ---------- run the repo doctor ----------
setup_rc=0
echo ""
echo "== tools/dev/setup-repo.sh ($TARGET) =="
if [ -f "$TARGET/tools/dev/setup-repo.sh" ]; then
  (cd "$TARGET" && bash tools/dev/setup-repo.sh) || setup_rc=$?
else
  echo "install.sh: WARN — $TARGET/tools/dev/setup-repo.sh missing; doctor skipped" >&2
fi

echo ""
if [ "$ahead" -gt 0 ]; then
  {
    echo "install.sh: REFUSED — $ahead file(s) are AHEAD of, or DIVERGED from, the bundle (or carry"
    echo "  uncommitted changes). Overwriting them would drop work that is not in the bundle, so"
    echo "  nothing about those files was changed. The fix is to port the target's version UP to"
    echo "  the bundle (ADR-0031) and re-install; --force --clobber-local overrides only if you"
    echo "  intend to DISCARD it."
  } >&2
  exit 1
fi
if [ "$blocked" -gt 0 ]; then
  echo "install.sh: $blocked file(s) differ from the bundle and were KEPT — re-run with --force to overwrite" >&2
  exit 1
fi
if [ "$setup_rc" -ne 0 ]; then
  echo "install.sh: files installed, but setup-repo.sh reported FAILs (exit $setup_rc) — fix and re-run it" >&2
  exit "$setup_rc"
fi
echo "install.sh: done"
exit 0
