#!/usr/bin/env bash
# post-bash-secret-scan.sh — PostToolUse[Bash] advisory secret tripwire (SAD-176).
#
# Scans the executed command plus its output (truncated to 200 KB) for
# secret-shaped strings. The command has already run, so this is a tripwire,
# not a gate: exit 2 feeds the warning back to the model. The matched value
# itself is NEVER printed — only the pattern name.
#
# SAD-552 — the patterns fall into two classes, and they are scanned over
# different text:
#
#   VALUE patterns  — high-entropy key material (AIza…, ghp_…, sk-ant-…, a
#                     ≥12-char credential assignment). Text containing one of
#                     these essentially IS the secret, wherever it appears.
#                     Scanned over the WHOLE text, command included. UNCHANGED.
#
#   MARKER patterns — zero-entropy structure that only NAMES key material
#                     ("BEGIN … PRIVATE KEY", "private_key"). A marker is
#                     evidence only when it appears attached to the real
#                     artifact, so each marker is anchored to the shape of that
#                     artifact (the PEM's ----- armour; the JSON key's colon and
#                     value) — and it is not scanned inside the SEARCH-PATTERN
#                     operand of the command's own grep/rg, because a hook that
#                     fires on the phrase you searched for is reporting itself.
#                     A real key pasted into a grep pattern is still caught: the
#                     VALUE patterns scan that operand unmasked.
#
# Both changes narrow what MATCHES; neither narrows what is LOOKED AT for real
# key material. See docs/decisions/ and SAD-552 for the false-positive tally
# that motivated it (6 observed, 0 credentials).

set -u

# Advisory hook: fail OPEN without jq (pre-bash-safety already fails closed).
command -v jq >/dev/null 2>&1 || exit 0

payload="$(cat)"
command_text="$(jq -r '.tool_input.command // ""' <<<"$payload" 2>/dev/null)"
response_text="$(jq -r '(.tool_response // {}) | tostring' <<<"$payload" 2>/dev/null)"
text="$(printf '%s\n%s' "$command_text" "$response_text" | head -c 200000)"
[ -z "$text" ] && exit 0
# tool_response arrives as re-encoded JSON, so embedded quotes are escaped
# (\"api_key\": \"...\") — strip the backslashes so quoted values still match.
text="${text//\\/}"

# Marker-scan text: same thing, but with the quoted operands of the command's
# own search tools blanked. Split on the shell's segment separators so ONLY a
# search-tool segment is masked (`grep 'x' f && echo '-----BEGIN…' > k.pem`
# keeps its second segment intact), and mask nothing at all in the OUTPUT.
masked_cmd=""
while IFS= read -r s; do
  if grep -qE '^([^[:space:]]*/)?(grep|egrep|fgrep|rg|ripgrep|ag|ack|pcregrep|ugrep)([[:space:]]|$)' \
       <<<"$(sed -E 's/^[[:space:](]+//' <<<"$s")"; then
    s="$(sed -E "s/'[^']*'/''/g; s/\"[^\"]*\"/\"\"/g" <<<"$s")"
  fi
  masked_cmd="${masked_cmd}${s}"$'\n'
done < <(sed -E 's/&&|\|\||;|\||&/\n/g' <<<"$command_text")
marker_text="$(printf '%s\n%s' "$masked_cmd" "$response_text" | head -c 200000)"
marker_text="${marker_text//\\/}"

hits=""
# `--` guards a pattern that legitimately starts with `-` (the PEM armour below)
# from being parsed as a grep option.
scan() { # $1 = pattern name, $2 = ERE — VALUE class, scans everything
  if grep -qE -- "$2" <<<"$text"; then
    hits="${hits}${hits:+, }$1"
  fi
}
scan_marker() { # $1 = pattern name, $2 = ERE — MARKER class, search operands masked
  if grep -qE -- "$2" <<<"$marker_text"; then
    hits="${hits}${hits:+, }$1"
  fi
}

scan "google-api-key"      'AIza[0-9A-Za-z_-]{30,}'
scan "github-token"        'ghp_[0-9A-Za-z]{30,}'
scan "github-pat"          'github_pat_[0-9A-Za-z_]{30,}'
scan "aws-access-key"      'AKIA[0-9A-Z]{16}'
scan "slack-token"         'xox[baprs]-[0-9A-Za-z-]{10,}'
scan "anthropic-key"       '(^|[^A-Za-z0-9-])sk-ant-[A-Za-z0-9_-]{20,}'
scan "openai-key"          '(^|[^A-Za-z0-9-])sk-(proj-)?[A-Za-z0-9_-]{20,}'
scan "stripe-key"          '[sr]k_live_[A-Za-z0-9]{16,}'
scan "resend-key"          '(^|[^A-Za-z0-9_])re_[A-Za-z0-9_]{16,}'

# MARKER class. Each is anchored to the real artifact, not to its name:
#   private-key-block   — RFC 7468 armour is exactly five hyphens; prose and
#                         regex definitions ("BEGIN [A-Z ]*PRIVATE KEY") have none.
#   gcp-service-account — a service-account JSON is "private_key": "<~1700 chars>";
#                         the bare token "private_key" is a field NAME, not a value.
# What this lets through: text naming a private key without carrying one.
scan_marker "private-key-block"   '[-]{5}BEGIN [A-Z ]*PRIVATE KEY'
scan_marker "gcp-service-account" '"private_key"[[:space:]]*:[[:space:]]*"[^"]{20,}'

# Generic credential assignment (folded from Jason's local hook, widened per Watson
# review): secret-suggesting key = / : value, optionally quoted (covers JSON), plus
# HTTP "Bearer <token>" as its own alternative. Case-insensitive. VALUE class — the
# ≥12-char value requirement is what makes it a value pattern, and it is the
# backstop that still catches a real private key pasted into a grep operand.
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
