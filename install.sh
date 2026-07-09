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

set -u

usage() {
  cat <<'EOF'
Usage: install.sh --target <repo> [--config <workflow.config.json>] [--force]

  --target <repo>   destination repository root (required)
  --config <json>   workflow config used to render {{VAR}} placeholders and to
                    seed <repo>/.claude/workflow.config.json. If omitted, an
                    existing <repo>/.claude/workflow.config.json is used.
  --force           overwrite target files that differ (default: print a diff
                    and keep the target)
EOF
}

TARGET=""
CONFIG=""
FORCE=0
while [ $# -gt 0 ]; do
  case "$1" in
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
install_file() { # $1 = staged abs path, $2 = target-relative dst, $3 = mode (x|-)
  local staged="$1" rel="$2" mode="$3"
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
    cp "$staged" "$dst"
    if [ "$mode" = "x" ]; then chmod +x "$dst"; fi
    echo "overwrite (--force) $rel"
  else
    echo "DIFFERS             $rel — target KEPT (re-run with --force to overwrite):"
    diff -u --label "$rel (target)" --label "$rel (bundle)" "$dst" "$staged" | sed 's/^/    /'
    blocked=$((blocked + 1))
  fi
}

echo "== installing into $TARGET =="
i=0
for entry in "${MANIFEST[@]}"; do
  IFS='|' read -r _src dst mode <<<"$entry"
  install_file "$STAGE/$i" "$dst" "$mode"
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
