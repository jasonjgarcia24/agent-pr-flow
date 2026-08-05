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
# update's clothing. See classify_drift() for the five classes and the rationale.
# A refusal is ATOMIC: nothing at all is installed, not even the unaffected files.
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
  --clobber-local   with --force, also overwrite AHEAD / DIVERGED / DIRTY files,
                    DISCARDING the target's version. Whole-manifest and a last
                    resort; port the target's work up to the bundle instead.

Drift classes (--force only), decided from the two repos' own git histories:
  forward   bundle moved on from what the     -> overwritten
            target holds (confirmed)
  ahead     bundle content is already in the  -> REFUSED (installing it would
            target's history for this path       revert work the target moved past)
  diverged  neither side's content is in the  -> REFUSED (not a fast-forward)
            other's history
  dirty     target file has uncommitted work  -> REFUSED
  unknown   no target git repo / no bundle    -> overwritten, counted, and
            git / path never committed           reported in the final summary
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
# --clobber-local only has meaning against a refusal, and refusals only happen under
# --force. Silently inert flags are how people believe they overrode something.
if [ "$CLOBBER" = "1" ] && [ "$FORCE" != "1" ]; then
  echo "install.sh: WARN — --clobber-local does nothing without --force (differing files are kept regardless)" >&2
fi
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
VAR_NAMES=(TEAM PROJECT ISSUE_KEY MCP_PREFIX DEFAULT_BRANCH REQUIRED_CHECK CODE_TIER_POLICY)
declare -A JQ_PATH=(
  [TEAM]='.tracker.team'
  [PROJECT]='.tracker.project'
  [ISSUE_KEY]='.tracker.issueKey'
  [MCP_PREFIX]='.tracker.mcpPrefix'
  [DEFAULT_BRANCH]='.git.defaultBranch'
  [REQUIRED_CHECK]='.ci.requiredCheck'
  [CODE_TIER_POLICY]='.review.codeTierPolicy'
)
# Variables whose config key is OPTIONAL, with the same default the consuming code applies.
# Without this, adding a template variable is a breaking change for every existing instance
# whose config predates the key: the render fails and nothing installs. Anything listed here
# MUST match the runtime default in the code that reads it, or the docs render a lie —
# CODE_TIER_POLICY mirrors land-pr.sh's fail-closed `absent -> reviewer`.
declare -A DEFAULTS=(
  [CODE_TIER_POLICY]='reviewer'
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
  if [ "${HAVE[$v]}" = "0" ] && [ -n "${DEFAULTS[$v]+set}" ]; then
    VAL[$v]="${DEFAULTS[$v]}"
    HAVE[$v]=1
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

# ---------- phase 2: classify, then install ----------
blocked=0        # differ, no --force  (target KEPT, legacy behaviour)
refused=0        # ahead | diverged | dirty  (REFUSED even under --force)
unverifiable=0   # overwritten but the direction could not be proven

# `--force` used to overwrite ANY differing target file. That silently reverted work
# which had been done in the target and never ported up to the bundle: the bundle copy
# was OLDER, `--force` restored it, and the run still printed a clean summary. It happened
# for real on 2026-07-30 across five files, and was caught only because a human read
# `git status` before committing.
#
# So the DIRECTION of the drift is decided before anything is overwritten:
#
#   forward     the TARGET's content is in the BUNDLE's history -> the bundle really did
#               move on from it. A fast-forward. Overwrite.
#   ahead       the bundle's content is already in the TARGET's history for that path ->
#               installing it is a REVERT, not an update. REFUSED.
#   diverged    neither side's content is in the other's history -> both moved on
#               independently, so overwriting drops the target's half. REFUSED.
#   dirty       the target file has uncommitted changes -> that work exists nowhere
#               else. REFUSED.
#   unknown     no target git repo, or the path was never committed -> undecidable.
#               Overwritten, but counted and reported.
#
# Note both directions are checked. "The bundle's content is not in the target's history"
# alone proves nothing: that is equally true of a fast-forward and of a divergence, and an
# earlier cut of this guard inferred `forward` from it and clobbered a genuinely diverged
# tools/dev/land-pr.sh.
#
# The signal is the two repos' own histories, so this needs no state file, no receipt and
# no bootstrap step -- it works on the first run in a fresh clone or worktree.

HAVE_BUNDLE_GIT=0
git -C "$BUNDLE" rev-parse --git-dir >/dev/null 2>&1 && HAVE_BUNDLE_GIT=1

# Apply the config substitution to stdin, byte-for-byte the way phase 1 renders a staged
# file (including the trailing-newline normalisation of $(cat) + printf '%s\n'). Historical
# bundle blobs MUST go through this before being compared with target bytes: bundle history
# stores {{VAR}}, the target stores rendered values, so raw blobs can never match.
render_stream() { # $1 = config-set index
  local k="$1" content v pat val
  content="$(cat)"
  for v in "${VAR_NAMES[@]}"; do
    val="${CFGVAL[$k,$v]:-}"
    [ -n "$val" ] || continue
    pat="{{${v}}}"
    content="${content//"$pat"/"$val"}"
  done
  printf '%s\n' "$content"
}

# Every commit that touched a path, on all refs. --full-history so merge simplification
# cannot prune a commit whose blob is the one that would have proven the direction.
# --literal-pathspecs so a path containing glob metacharacters is matched as a path.
path_commits() { # $1 = repo, $2 = path
  git -C "$1" --literal-pathspecs rev-list --full-history --max-count=1000 --all -- "$2" 2>/dev/null
}

# ---------- config sets used to render historical bundle blobs ----------
# Set 0 is the CURRENT config. Sets 1..N are the target's own HISTORICAL
# workflow.config.json versions.
#
# Why history matters here: a templated target file holds bytes rendered from whatever the
# config said AT INSTALL TIME. Comparing only against today's values means that the moment
# anyone flips a documented knob — `review.codeTierPolicy` being the obvious one, since
# {{CODE_TIER_POLICY}} renders straight into workflow.md — EVERY templated file stops
# matching at once and reports `diverged`. That is a false positive with a actively
# misleading remedy ("port the target's changes up" — there is nothing to port), and
# because refusals are atomic it would block the entire install with the only override
# being a whole-manifest --clobber-local.
#
# The target's own history carries the configs it was rendered under, so use them.
declare -A CFGVAL
CFG_COUNT=0
add_config_set() { # $1 = path to a config json ("" = use the resolved VAL/HAVE)
  local cfg="$1" v val
  for v in "${VAR_NAMES[@]}"; do
    if [ -z "$cfg" ]; then
      val=""; [ "${HAVE[$v]}" = "1" ] && val="${VAL[$v]}"
    else
      val="$(jq -r "${JQ_PATH[$v]} // empty" "$cfg" 2>/dev/null)" || val=""
      [ -n "$val" ] || { [ -n "${DEFAULTS[$v]+set}" ] && val="${DEFAULTS[$v]}"; }
    fi
    CFGVAL[$CFG_COUNT,$v]="$val"
  done
  CFG_COUNT=$((CFG_COUNT + 1))
}
add_config_set ""                       # set 0 = current
collect_target_config_history() {
  local cfgrel=".claude/workflow.config.json" c oid tmpf seen=""
  git -C "$TARGET" rev-parse --git-dir >/dev/null 2>&1 || return 0
  while IFS= read -r c; do
    [ -n "$c" ] || continue
    [ "$CFG_COUNT" -lt 50 ] || break     # bound the fan-out
    oid="$(git -C "$TARGET" rev-parse -q --verify "$c:$cfgrel" 2>/dev/null)" || continue
    [ -n "$oid" ] || continue
    case "$seen" in *"$oid"*) continue ;; esac
    seen="$seen $oid"
    tmpf="$STAGE/.cfg.$CFG_COUNT"
    git -C "$TARGET" cat-file blob "$oid" > "$tmpf" 2>/dev/null || continue
    jq empty "$tmpf" 2>/dev/null || continue
    add_config_set "$tmpf"
  done < <(path_commits "$TARGET" "$cfgrel")
}
collect_target_config_history

DRIFT_CLASS=""
classify_drift() { # $1 = staged abs, $2 = target-relative, $3 = bundle-relative src
  local staged="$1" rel="$2" src="$3" want st have c tmp raw k templated=0
  DRIFT_CLASS="unknown"
  git -C "$TARGET" rev-parse --git-dir >/dev/null 2>&1 || return 0

  # Uncommitted local work outranks everything: it is recoverable from nothing.
  # --literal-pathspecs is a MAIN-command option and must precede the subcommand; placing
  # it after `status` makes git reject it, and with stderr discarded the check silently
  # returns empty — i.e. every dirty file would be misclassified. It is here so a manifest
  # path containing glob metacharacters is matched literally rather than as a pathspec.
  st="$(git -C "$TARGET" --literal-pathspecs status --porcelain -- "$rel" 2>/dev/null)"
  case "$st" in
    '??'*) DRIFT_CLASS="unknown"; return 0 ;;   # untracked -- nothing to compare against
    ?*)    DRIFT_CLASS="dirty";   return 0 ;;
  esac

  # --- AHEAD: is the content we are about to install already in the target's past? ---
  # --path applies the target's .gitattributes, so the OID is computed the way git would
  # have computed it when that content was committed.
  want="$(git -C "$TARGET" hash-object --path "$rel" -- "$staged" 2>/dev/null)" || want=""
  if [ -n "$want" ] && path_commits "$TARGET" "$rel" \
       | sed "s|\$|:$rel|" \
       | git -C "$TARGET" cat-file --batch-check='%(objectname)' 2>/dev/null \
       | grep -qxF "$want"; then
    DRIFT_CLASS="ahead"
    return 0
  fi

  # No target history for this path at all -> undecidable, not a fast-forward.
  [ -n "$(path_commits "$TARGET" "$rel" | head -1)" ] || return 0

  # --- FORWARD vs DIVERGED: confirm the fast-forward POSITIVELY, from bundle history. ---
  if [ "$HAVE_BUNDLE_GIT" != "1" ]; then
    DRIFT_CLASS="unknown"            # cannot prove it; do not claim `forward`
    return 0
  fi
  grep -qE '\{\{[A-Z_]+\}\}' "$BUNDLE/$src" 2>/dev/null && templated=1

  if [ "$templated" = "0" ]; then
    have="$(git -C "$BUNDLE" hash-object --path "$src" -- "$TARGET/$rel" 2>/dev/null)" || have=""
    if [ -n "$have" ] && path_commits "$BUNDLE" "$src" \
         | sed "s|\$|:$src|" \
         | git -C "$BUNDLE" cat-file --batch-check='%(objectname)' 2>/dev/null \
         | grep -qxF "$have"; then
      DRIFT_CLASS="forward"
    else
      DRIFT_CLASS="diverged"
    fi
    return 0
  fi

  # Templated source: bundle history holds {{VAR}} while the target holds rendered bytes,
  # so blob OIDs can never match. RENDER each historical version through the same
  # substitution and compare the result. Skipping this check instead (an earlier cut did)
  # is a fail-open on exactly the reference-instance files that drifted in the original
  # incident -- and the `ahead` check does NOT cover them, because it needs today's render
  # to exist verbatim as a past commit, which a squash-merge repo or any config change
  # defeats.
  # Each historical bundle version is rendered under EVERY config set the target has used
  # (current + its own history), because the target's bytes were rendered under whichever
  # config was live at install time. Without that, flipping any config value makes every
  # templated file read `diverged` at once.
  tmp="$STAGE/.render.$$"
  raw="$STAGE/.raw.$$"
  DRIFT_CLASS="diverged"
  while IFS= read -r c; do
    [ -n "$c" ] || continue
    git -C "$BUNDLE" cat-file blob "$c:$src" > "$raw" 2>/dev/null || continue
    k=0
    while [ "$k" -lt "$CFG_COUNT" ]; do
      render_stream "$k" < "$raw" > "$tmp"
      if cmp -s "$tmp" "$TARGET/$rel"; then DRIFT_CLASS="forward"; break; fi
      k=$((k + 1))
    done
    [ "$DRIFT_CLASS" = "forward" ] && break
  done < <(path_commits "$BUNDLE" "$src")
  rm -f "$tmp" "$raw"
  return 0
}

# ---------- pass 1: classify everything, write nothing ----------
declare -a ACTION DSTS MODES
i=0
for entry in "${MANIFEST[@]}"; do
  IFS='|' read -r src dst mode <<<"$entry"
  staged="$STAGE/$i"
  target_file="$TARGET/$dst"
  DSTS[$i]="$dst"; MODES[$i]="$mode"
  if [ ! -f "$target_file" ]; then
    ACTION[$i]="install"
  elif cmp -s "$staged" "$target_file"; then
    ACTION[$i]="skip"
  elif [ "$FORCE" != "1" ]; then
    ACTION[$i]="differs"; blocked=$((blocked + 1))
  else
    classify_drift "$staged" "$dst" "$src"
    case "$DRIFT_CLASS" in
      ahead|diverged|dirty)
        if [ "$CLOBBER" = "1" ]; then ACTION[$i]="clobber:$DRIFT_CLASS"
        else ACTION[$i]="refuse:$DRIFT_CLASS"; refused=$((refused + 1)); fi ;;
      unknown) ACTION[$i]="unverifiable"; unverifiable=$((unverifiable + 1)) ;;
      *)       ACTION[$i]="overwrite" ;;
    esac
  fi
  i=$((i + 1))
done

# A refusal is ATOMIC: report every one of them and write NOTHING, so a blocked run can
# never leave the target half-updated. Mirrors the "nothing is written on a render
# failure" rule in phase 1.
if [ "$refused" -gt 0 ]; then
  echo "== REFUSED — nothing was installed into $TARGET =="
  i=0
  for entry in "${MANIFEST[@]}"; do
    case "${ACTION[$i]}" in
      refuse:ahead)
        echo "AHEAD               ${DSTS[$i]} — target is AHEAD of the bundle:"
        echo "    the bundle's content for this file already exists in the target's git history —"
        echo "    installing it would REVERT work the target has since moved past."
        echo "    Fix: port the target's version UP to the bundle, then re-install (ADR-0031)." ;;
      refuse:diverged)
        echo "DIVERGED            ${DSTS[$i]} — target and bundle have each moved on:"
        echo "    neither side's content appears in the other's history, so this is not a"
        echo "    fast-forward — the target carries work the bundle has never seen."
        echo "    Fix: reconcile the two (port the target's changes up), then re-install." ;;
      refuse:dirty)
        echo "DIRTY               ${DSTS[$i]} — target has UNCOMMITTED changes:"
        echo "    that work exists nowhere else. Commit or stash it first." ;;
      *) i=$((i + 1)); continue ;;
    esac
    diff -u --label "${DSTS[$i]} (target)" --label "${DSTS[$i]} (bundle)" \
      "$TARGET/${DSTS[$i]}" "$STAGE/$i" | sed 's/^/    /'
    i=$((i + 1))
  done
  {
    echo ""
    echo "install.sh: REFUSED — $refused file(s) are AHEAD of, or DIVERGED from, the bundle"
    echo "  (or carry uncommitted changes). Overwriting them would drop work that is not in"
    echo "  the bundle, so NOTHING was installed — not even the files that would have been"
    echo "  fine. Port the target's version UP to the bundle (ADR-0031) and re-install;"
    echo "  --force --clobber-local overrides only if you intend to DISCARD it."
  } >&2
  exit 1
fi

# ---------- pass 2: write ----------
echo "== installing into $TARGET =="
apply_file() { # $1 = index
  local i="$1" rel="${DSTS[$1]}" mode="${MODES[$1]}" staged="$STAGE/$1"
  local dst="$TARGET/$rel"
  mkdir -p "$(dirname "$dst")"
  case "${ACTION[$i]}" in
    install)
      cp "$staged" "$dst"; [ "$mode" = "x" ] && chmod +x "$dst"
      echo "install             $rel" ;;
    skip)
      [ "$mode" = "x" ] && chmod +x "$dst"
      echo "skip (unchanged)    $rel" ;;
    overwrite)
      cp "$staged" "$dst"; [ "$mode" = "x" ] && chmod +x "$dst"
      echo "overwrite (--force) $rel" ;;
    unverifiable)
      cp "$staged" "$dst"; [ "$mode" = "x" ] && chmod +x "$dst"
      echo "overwrite (--force) $rel  ** WARN: UNVERIFIABLE — could not prove the bundle is"
      echo "    not older than the target (no target history for this path, or no bundle git)."
      echo "    Commit the target's files so a future install can tell an update from a revert." ;;
    clobber:*)
      cp "$staged" "$dst"; [ "$mode" = "x" ] && chmod +x "$dst"
      echo "CLOBBER (--clobber-local) $rel — target was ${ACTION[$i]#clobber:}; local content DISCARDED" ;;
    differs)
      echo "DIFFERS             $rel — target KEPT (re-run with --force to overwrite):"
      diff -u --label "$rel (target)" --label "$rel (bundle)" "$dst" "$staged" | sed 's/^/    /' ;;
  esac
  return 0
}
i=0
for entry in "${MANIFEST[@]}"; do
  apply_file "$i"
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
# An inline WARN scrolls off in a 15-file run, and "it printed a clean summary" is the
# whole SAD-548 story — so anything unproven has to survive to the summary.
if [ "$unverifiable" -gt 0 ]; then
  {
    echo "install.sh: WARN — $unverifiable file(s) were overwritten WITHOUT being able to prove the"
    echo "  bundle is newer than the target (no target git history for the path, or the bundle is"
    echo "  not a git checkout). If any of them carried local work, it is now only in your"
    echo "  reflog/backups. Commit the target's files so the next install can tell an update"
    echo "  from a revert."
  } >&2
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
