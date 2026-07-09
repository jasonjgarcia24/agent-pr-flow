#!/usr/bin/env bash
# lint-on-edit.sh — PostToolUse[Edit|Write|MultiEdit] config-driven linter (SAD-176).
#
# Reads ci.lintOnEdit from .claude/workflow.config.json (lands in SAD-181).
# The lint command runs with $FILE set to the edited file's path; a non-zero
# lint exit becomes exit 2 (advisory feedback to the model). A null/absent
# config value — endurance-logger's state: no ktlint config, Gradle lint too
# slow per-edit — is a fast no-op. The hook ships anyway so the settings
# wiring and the portable-bundle shape are final from day one.

set -u

command -v jq >/dev/null 2>&1 || exit 0

cfg="${CLAUDE_PROJECT_DIR:-.}/.claude/workflow.config.json"
[ -f "$cfg" ] || exit 0

lint_cmd="$(jq -r '.ci.lintOnEdit // empty' "$cfg" 2>/dev/null)"
[ -z "$lint_cmd" ] && exit 0

payload="$(cat)"
file="$(jq -r '.tool_input.file_path // empty' <<<"$payload")"
[ -z "$file" ] && exit 0
[ -f "$file" ] || exit 0

if ! out="$(FILE="$file" bash -c "$lint_cmd" 2>&1)"; then
  {
    echo "lint-on-edit: lint failed for $file"
    printf '%s\n' "$out" | head -c 4000
  } >&2
  exit 2
fi

exit 0
