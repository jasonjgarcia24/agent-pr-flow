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
#                     artifact (the PEM's hyphen armour; the JSON key's colon and
#                     value) — and it is not scanned inside a quoted operand of
#                     the command's own grep/rg SEGMENT, because a hook that
#                     fires on the phrase you searched for is reporting itself.
#
# ⚠ The masking is only safe because of `private-key-material` below. Marker
# masking is coarse — it blanks EVERY quoted operand of a search-tool segment,
# not just the pattern — so on its own it would launder a real key behind
# `grep -q zzz '<key>'`. The VALUE class is never masked, and it now includes
# armour-plus-body, so key MATERIAL is caught wherever it sits while the bare
# marker (a phrase, a regex definition, prose) is not. Do not remove that
# pattern while the masking is in place; they are one mechanism.
#
# Both changes narrow what MATCHES; neither narrows what is LOOKED AT for real
# key material. See docs/decisions/ and SAD-552 for the false-positive tally
# that motivated it (9 observed, 0 credentials).

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

hits=""
# `--` guards a pattern that legitimately starts with `-` (the PEM armour below)
# from being parsed as a grep option.
scan() { # $1 = pattern name, $2 = ERE — VALUE class, scans everything
  if grep -qE -- "$2" <<<"$text"; then
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

# VALUE class — armour PLUS an actual key body on the same line. This is the
# single-line form a PEM takes when it is pasted into a command or embedded in
# JSON (where "\n" has already been stripped to "n" above). It exists because
# the first cut of SAD-552 CLAIMED the generic ≥12-char pattern was the backstop
# for a masked PEM and that was simply FALSE — `private[_-]?key` cannot match
# "PRIVATE KEY" (space, not underscore) and the longest run of allowed chars at
# the head of a PEM is "-----BEGIN", ten characters, under the twelve-char floor.
# Barb and Watson each proved a full private key transiting a grep operand with
# no tripwire. Armour + ≥40 chars of DENSE base64 is key MATERIAL and is never
# masked; armour ALONE is a marker (below) and may be. That split is the design.
#
# ⚠ The body class is base64 ONLY — deliberately NO [[:space:]] inside the run.
# The first attempt allowed whitespace there and immediately false-positived on
# PROSE ("-----BEGIN RSA PRIVATE KEY----- is the header of a PEM file and marks
# where the key material begins"), i.e. it reintroduced the exact bug this issue
# exists to fix. A real single-line body — a pasted key, or JSON where \n has
# already been stripped to n above — is one unbroken base64 run; prose is not.
# 40 rather than 100 so a short EC key still trips. A genuine MULTI-line PEM in
# output puts its body on its own lines, where the armour line alone still
# matches the MARKER pattern; output is never masked, so nothing there depends
# on this one.
scan "private-key-material" '[-]{4,}[[:space:]]?BEGIN [A-Z0-9 ]*PRIVATE KEY[-]{4,}[[:space:]]*[A-Za-z0-9+/=]{40,}'

# MARKER class. Each is anchored to the real artifact, not to its name:
#   private-key-block   — RFC 7468 armour is a hyphen RUN; prose and regex
#                         definitions ("BEGIN [A-Z ]*PRIVATE KEY") have none.
#                         {4,} not {5}: Watson found that the exact-five form
#                         narrowed detection past the old pattern, dropping
#                         "---- BEGIN ENCRYPTED PRIVATE KEY ----" which used to
#                         trip. [A-Z0-9 ] also picks up SSH2-style labels with a
#                         digit, which NEITHER version matched.
#   gcp-service-account — a service-account JSON is "private_key": "<~1700 chars>";
#                         the bare token "private_key" is a field NAME, not a value.
# What this lets through: text naming a private key without carrying one.
scan        "private-key-block"   '[-]{4,}[[:space:]]?BEGIN [A-Z0-9 ]*PRIVATE KEY[[:space:]]?[-]{4,}'
scan        "gcp-service-account" '"private_key"[[:space:]]*:[[:space:]]*"[^"]{20,}'

# Generic credential assignment (folded from Jason's local hook, widened per Watson
# review): secret-suggesting key = / : value, optionally quoted (covers JSON), plus
# HTTP "Bearer <token>" as its own alternative. Case-insensitive. VALUE class — the
# ≥12-char value requirement is what makes it a value pattern. It covers credential
# ASSIGNMENTS only; the backstop for a PEM is `private-key-material` above, NOT this
# (this pattern cannot match "PRIVATE KEY" at all — space, not underscore).
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
