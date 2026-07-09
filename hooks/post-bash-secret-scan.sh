#!/usr/bin/env bash
# post-bash-secret-scan.sh — PostToolUse[Bash] advisory secret tripwire (SAD-176).
#
# Scans the executed command plus its output (truncated to 200 KB) for
# secret-shaped strings. The command has already run, so this is a tripwire,
# not a gate: exit 2 feeds the warning back to the model. The matched value
# itself is NEVER printed — only the pattern name.

set -u

# Advisory hook: fail OPEN without jq (pre-bash-safety already fails closed).
command -v jq >/dev/null 2>&1 || exit 0

payload="$(cat)"
text="$(jq -r '((.tool_input.command // "") + "\n" + ((.tool_response // {}) | tostring))' <<<"$payload" 2>/dev/null | head -c 200000)"
[ -z "$text" ] && exit 0
# tool_response arrives as re-encoded JSON, so embedded quotes are escaped
# (\"api_key\": \"...\") — strip the backslashes so quoted values still match.
text="${text//\\/}"

hits=""
scan() { # $1 = pattern name, $2 = ERE
  if grep -qE "$2" <<<"$text"; then
    hits="${hits}${hits:+, }$1"
  fi
}

scan "google-api-key"      'AIza[0-9A-Za-z_-]{30,}'
scan "github-token"        'ghp_[0-9A-Za-z]{30,}'
scan "github-pat"          'github_pat_[0-9A-Za-z_]{30,}'
scan "aws-access-key"      'AKIA[0-9A-Z]{16}'
scan "slack-token"         'xox[baprs]-[0-9A-Za-z-]{10,}'
scan "private-key-block"   'BEGIN [A-Z ]*PRIVATE KEY'
scan "gcp-service-account" '"private_key"'
scan "anthropic-key"       '(^|[^A-Za-z0-9-])sk-ant-[A-Za-z0-9_-]{20,}'
scan "openai-key"          '(^|[^A-Za-z0-9-])sk-(proj-)?[A-Za-z0-9_-]{20,}'
scan "stripe-key"          '[sr]k_live_[A-Za-z0-9]{16,}'
scan "resend-key"          '(^|[^A-Za-z0-9_])re_[A-Za-z0-9_]{16,}'

# Generic credential assignment (folded from Jason's local hook, widened per Watson
# review): secret-suggesting key = / : value, optionally quoted (covers JSON), plus
# HTTP "Bearer <token>" as its own alternative. Case-insensitive.
generic_pat="(^|[^A-Za-z])(api[_-]?key|access[_-]?token|client[_-]?secret|private[_-]?key|pass(word|wd)?|secret)[\"']?[[:space:]]*[=:][[:space:]]*[\"']?[A-Za-z0-9+/._-]{12,}|(^|[^A-Za-z])bearer[[:space:]]+[A-Za-z0-9+/._=-]{12,}"
if grep -qiE "$generic_pat" <<<"$text"; then
  hits="${hits}${hits:+, }generic-credential-assignment"
fi

if [ -n "$hits" ]; then
  {
    echo "post-bash-secret-scan: secret-shaped string detected ($hits)."
    echo "Do NOT commit it. Scrub it from anything you control. If it is a real credential, tell Jason immediately and recommend ROTATION — it has hit the transcript and must be treated as compromised."
  } >&2
  exit 2
fi

exit 0
