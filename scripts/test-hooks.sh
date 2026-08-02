#!/usr/bin/env bash
# shellcheck disable=SC2016  # single-quoted $HOME fixtures are literal test payloads by design
# tools/dev/test-hooks.sh — regression table for the Claude Code safety hooks
# (SAD-176). Feeds synthetic hook payloads to the scripts and asserts exit
# codes; no command in the table is ever executed. Run after ANY hook edit.
#
# NOTE: the "secret" strings below are obviously-fake fixtures (x-padded),
# present only to exercise the detector patterns.

set -u

ROOT="$(git rev-parse --show-toplevel)" || exit 1
H="$ROOT/.claude/hooks"
pass=0; fail=0

mk() { # $1 = command, $2 = cwd (default repo root)
  jq -n --arg c "$1" --arg d "${2:-$ROOT}" '{tool_input:{command:$c}, cwd:$d}'
}

t() { # $1=name $2=expected rc $3=command [$4=extra env] [$5=cwd] [$6=expected rule id]
  # extra comes AFTER the default CLAUDE_PROJECT_DIR so tests can override the
  # project scope (SAD-181 repo-scoped F-rows); deliberate word-split.
  # $6 (optional): assert WHICH rule blocked. Without it an expected-2 case
  # passes if ANY rule fires, so a test can go green for the wrong reason
  # (Watson, SAD-552). Pass it on adversarial rows where the rule is the point.
  local name="$1" expect="$2" cmd="$3" extra="${4:-}" cwd="${5:-$ROOT}" rule="${6:-}"
  local rc out got
  if [ -n "$extra" ]; then
    # shellcheck disable=SC2086 # word-splitting multiple K=V assignments is the point
    out=$(mk "$cmd" "$cwd" | env CLAUDE_PROJECT_DIR="$ROOT" $extra bash "$H/pre-bash-safety.sh" 2>&1); rc=$?
  else
    out=$(mk "$cmd" "$cwd" | env CLAUDE_PROJECT_DIR="$ROOT" bash "$H/pre-bash-safety.sh" 2>&1); rc=$?
  fi
  if [ "$rc" != "$expect" ]; then
    echo "FAIL  $name (rc=$rc expected=$expect) :: $out"; fail=$((fail+1)); return
  fi
  if [ -n "$rule" ]; then
    got=$(sed -n 's/^pre-bash-safety \[\([A-Z0-9]*\)\].*/\1/p' <<<"$out" | head -1)
    if [ "$got" != "$rule" ]; then
      echo "FAIL  $name (rule=$got expected=$rule) :: $out"; fail=$((fail+1)); return
    fi
  fi
  echo "PASS  $name (rc=$rc${rule:+ rule=$rule})"; pass=$((pass+1))
}

t_delta() { # $1=name $2=baseline-rc $3=head-rc $4=command [$5=cwd]
  # DIFFERENTIAL row (SAD-552). Every finding in that review surfaced from
  # running one payload against the PRE-change hook and the HEAD hook and
  # diffing the verdicts — so an INTENDED change of verdict is asserted here
  # explicitly, and an UNINTENDED one fails. Baseline = the hook as of the
  # merge-base with the default branch; skipped (not failed) when there is no
  # baseline to diff against — see BASELINE_HOOK below for the two ways that
  # happens. A differential row is a PRE-MERGE review aid by construction; the
  # landed behaviour it describes is pinned separately by absolute `t` rows,
  # which keep asserting after the change lands (SAD-635).
  local name="$1" want_base="$2" want_head="$3" cmd="$4" cwd="${5:-$ROOT}"
  local base_hook rc_b rc_h
  base_hook="$BASELINE_HOOK"
  if [ -z "$base_hook" ] || [ ! -s "$base_hook" ]; then
    echo "SKIP  $name ($BASELINE_SKIP_WHY)"; return
  fi
  mk "$cmd" "$cwd" | env CLAUDE_PROJECT_DIR="$ROOT" bash "$base_hook" >/dev/null 2>&1; rc_b=$?
  mk "$cmd" "$cwd" | env CLAUDE_PROJECT_DIR="$ROOT" bash "$H/pre-bash-safety.sh" >/dev/null 2>&1; rc_h=$?
  if [ "$rc_b" = "$want_base" ] && [ "$rc_h" = "$want_head" ]; then
    echo "PASS  $name (base=$rc_b head=$rc_h)"; pass=$((pass+1))
  else
    echo "FAIL  $name (base=$rc_b/$want_base head=$rc_h/$want_head)"; fail=$((fail+1))
  fi
}

# Baseline hook for t_delta: the pre-change revision from the default branch.
# Two ways there is nothing to diff, and both SKIP rather than fail:
#   1. the revision is unavailable (shallow / exported tree, no origin/main);
#   2. it is byte-identical to the working copy (SAD-635) — which is what every
#      tree looks like once the change under test lands on the default branch,
#      because merge-base then resolves to that very change. Without this guard
#      the "verdict CHANGED" rows compare head against itself and fail forever,
#      while the "verdict UNCHANGED" rows pass vacuously.
BASELINE_HOOK=""
BASELINE_SKIP_WHY="no baseline hook revision available"
_bl="$(mktemp)"
_base_ref="$(git merge-base HEAD origin/main 2>/dev/null || git rev-parse origin/main 2>/dev/null || true)"
if [ -n "$_base_ref" ] && git show "$_base_ref:.claude/hooks/pre-bash-safety.sh" > "$_bl" 2>/dev/null && [ -s "$_bl" ]; then
  if cmp -s "$_bl" "$H/pre-bash-safety.sh"; then
    BASELINE_SKIP_WHY="baseline is identical to head — the change under test has landed"
  else
    BASELINE_HOOK="$_bl"
  fi
fi

echo "== pre-bash-safety.sh: D-rows =="
t "D1 reset --hard blocked"          2 'git reset --hard HEAD~1'
t "D1 escape hatch"                  0 'git reset --hard HEAD~1' 'ALLOW_DESTRUCTIVE=1'
t "D1 -C form blocked"               2 'git -C /some/repo reset --hard origin/main'
t "reset --soft allowed"             0 'git reset --soft HEAD~1'
t "D2 clean -fd blocked"             2 'git clean -fd'
t "D2 dry-run allowed"               0 'git clean -nfd'
t "D2 escape hatch"                  0 'git clean -fd' 'ALLOW_DESTRUCTIVE=1'
t "D3 rm -rf / blocked"              2 'rm -rf /'
t "D3 rm -rf ~ blocked"              2 'rm -rf ~'
t "D3 rm -rf \$HOME blocked"         2 'rm -rf $HOME'
t "D3 rm -rf repo root blocked"      2 "rm -rf $ROOT"
t "rm -rf build/ allowed"            0 'rm -rf build/'
t "D4 kill-server blocked"           2 'adb kill-server'
t "D4 kill-server w/ serial blocked" 2 'adb -s emulator-5554 kill-server'
t "D5 serial-less shell blocked"     2 'adb shell ls /sdcard'
t "D5 serial-less install blocked"   2 'adb install app.apk'
t "D5 pinned serial allowed"         0 'adb -s emulator-5554 shell ls /sdcard'
t "D5 escape hatch"                  0 'adb shell ls' 'ADB_NO_SERIAL_OK=1'
t "adb devices allowed"              0 'adb devices'
t "compound: 2nd segment caught"     2 'git status && adb shell ls'
t "benign compound allowed"          0 'echo hi && git status | head -3'
t "SKIP full bypass"                 0 'git reset --hard && rm -rf /' 'SKIP_BASH_SAFETY=1'
t "empty command allowed"            0 ''

echo "== folded local-hook rules =="
t "D3 rm -rf ../ blocked"            2 'rm -rf ../other-project'
t "D3 rm -rf .. blocked"             2 'rm -rf ..'
t "D6 force push blocked"            2 'git push --force origin main'
t "D6 -f push blocked"               2 'git push -f'
t "D6 force-with-lease blocked"      2 'git push --force-with-lease origin feature'
t "plain push allowed"               0 'git push origin jasongarcia/sad-176-test'
t "D7 add local.properties blocked"  2 'git add local.properties'
t "D7 add google-services blocked"   2 'git add app/google-services.json'
t "D7 add credentials.json blocked"  2 'git add credentials.json'
t "normal git add allowed"           0 'git add app/src/main/java/Foo.kt'
out=$(mk 'bash -x tools/dev/seed-demo-data.sh' | env CLAUDE_PROJECT_DIR="$ROOT" bash "$H/pre-bash-safety.sh" 2>/dev/null); rc=$?
if [ "$rc" = "0" ] && grep -q "systemMessage" <<<"$out"; then echo "PASS  W1 bash -x warns without blocking"; pass=$((pass+1)); else echo "FAIL  W1 (rc=$rc out=$out)"; fail=$((fail+1)); fi

echo "== quoting bypass (Barb audit) =="
t "D3 quoted root blocked"           2 'rm -rf "/"'
t "D3 single-quoted ~ blocked"       2 "rm -rf '~'"
t "D3 quoted \$HOME blocked"         2 'rm -rf "$HOME"'
t "D3 quoted parent blocked"         2 'rm -rf "../sibling"'
t "quoted safe path allowed"         0 'rm -rf "build/tmp dir"'

echo "== Watson review probes =="
t "D3 rm -rf . at repo root blocked" 2 'rm -rf .'
t "D3 rm -rf * at repo root blocked" 2 'rm -rf *'
t "D3 rm -rf ./ at repo root blocked" 2 'rm -rf ./'
t "rm -rf . in subdir allowed"       0 'rm -rf .' '' "$ROOT/app/build"
t "D7 release.keystore blocked"      2 'git add release.keystore'
t "D7 debug.keystore blocked"        2 'git add app/debug.keystore'
t "D1 subshell form blocked"         2 '(git reset --hard)'
t "D1 env-prefix form blocked"       2 'GIT_DIR=x git reset --hard'
t "D1 after single & blocked"        2 'sleep 1 & git reset --hard'
t "D6 combined -uf blocked"          2 'git push -uf origin feature'
t "D5 path-prefixed adb blocked"     2 '/usr/bin/adb shell ls'
t "D4 path-prefixed adb blocked"     2 '/usr/local/bin/adb kill-server'
t "push --follow-tags allowed"       0 'git push --follow-tags origin feature'
out=$(mk 'sh -x tools/dev/setup-repo.sh' | env CLAUDE_PROJECT_DIR="$ROOT" bash "$H/pre-bash-safety.sh" 2>/dev/null); rc=$?
if [ "$rc" = "0" ] && grep -q "systemMessage" <<<"$out"; then echo "PASS  W1 sh -x warns too"; pass=$((pass+1)); else echo "FAIL  W1 sh -x (rc=$rc)"; fail=$((fail+1)); fi

echo "== Barb audit probes (quote/prefix normalization, D0, D5 grammar) =="
t "D1 quoted --hard blocked"         2 'git reset "--hard" HEAD~3'
t "D2 quoted -fd blocked"            2 'git clean "-fd"'
t "D6 quoted --force blocked"        2 'git push "--force" origin main'
t "D1 sudo prefix blocked"           2 'sudo git reset --hard'
t "D1 env prefix blocked"            2 'env git reset --hard HEAD~1'
t "D7 path-prefixed git blocked"     2 '/usr/bin/git add credentials.json'
t "D0 inline hatch blocked"          2 'SKIP_BASH_SAFETY=1 rm -rf /tmp/x'
t "D0 inline ALLOW_DESTRUCTIVE blocked" 2 'ALLOW_DESTRUCTIVE=1 git reset --hard'
t "D0 inline LAND_PR_TEST blocked"   2 'LAND_PR_TEST=1 LAND_PR_CFG_OVERRIDE=/tmp/w.json tools/dev/land-pr.sh 5'
t "D0 inline LAND_PR_SELFTEST blocked" 2 'LAND_PR_SELFTEST=1 tools/dev/land-pr.sh 5'
t "D0 inline ALLOW_DISABLED_STATION blocked" 2 'ALLOW_DISABLED_STATION=1 tools/dev/land-pr.sh 5'
t "D5 subcommand -s not a serial"    2 'adb shell ls -s /sdcard'
t "D5 install -s not a serial"       2 'adb install -s app.apk'
t "D5 pinned + subcommand flag ok"   0 'adb -s emulator-5554 install -r app.apk'

echo "== F-rows: branch-flow guards (SAD-177) =="
TMPMAIN="$(mktemp -d)"; git -C "$TMPMAIN" init -q -b main; git -C "$TMPMAIN" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
TMPFEAT="$(mktemp -d)"; git -C "$TMPFEAT" init -q -b feature/x; git -C "$TMPFEAT" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
trap 'rm -rf "$TMPMAIN" "$TMPFEAT"' EXIT
t "F1 gh pr merge blocked"           2 'gh pr merge 42 --squash'
t "gh pr view allowed"               0 'gh pr view 42 --json state'
t "F2 push origin main blocked"      2 'git push origin main'
t "F2 push HEAD:main blocked"        2 'git push origin HEAD:main'
t "F2 push feature:main blocked"     2 'git push -u origin feature:main'
t "F2 refs/heads/main blocked"       2 'git push origin refs/heads/main'
t "F2 escape hatch (ambient env)"    0 'git push origin main' 'ALLOW_MAIN_PUSH=1'
t "F2 token-wise: sad-999-main-screen passes" 0 'git push origin jasongarcia/sad-999-main-screen-test'
t "F2 main as SOURCE passes"         0 'git push origin main:feature-backup'
t "F3 bare push on main blocked"     2 'git push' "CLAUDE_PROJECT_DIR=$TMPMAIN" "$TMPMAIN"
t "F3 push origin on main blocked"   2 'git push origin' "CLAUDE_PROJECT_DIR=$TMPMAIN" "$TMPMAIN"
t "F3 bare push on feature allowed"  0 'git push' "CLAUDE_PROJECT_DIR=$TMPFEAT" "$TMPFEAT"
t "F3 escape hatch"                  0 'git push' "ALLOW_MAIN_PUSH=1 CLAUDE_PROJECT_DIR=$TMPMAIN" "$TMPMAIN"
t "F4 commit on main blocked"        2 'git commit -m wip' "CLAUDE_PROJECT_DIR=$TMPMAIN" "$TMPMAIN"
t "F4 merge on main blocked"         2 'git merge --ff-only origin/main' "CLAUDE_PROJECT_DIR=$TMPMAIN" "$TMPMAIN"
t "F4 commit on feature allowed"     0 'git commit -m wip' "CLAUDE_PROJECT_DIR=$TMPFEAT" "$TMPFEAT"
t "F4 -C override detected"          2 "git -C $TMPMAIN commit -m wip" "CLAUDE_PROJECT_DIR=$TMPMAIN" "$TMPFEAT"
t "F4 pull --ff-only on main allowed" 0 'git pull --ff-only' "CLAUDE_PROJECT_DIR=$TMPMAIN" "$TMPMAIN"
t "F5 push --delete main blocked"    2 'git push origin --delete main'
t "F5 no escape hatch"               2 'git push origin --delete main' 'ALLOW_MAIN_PUSH=1'
t "F5 :main deletion blocked"        2 'git push origin :main'
t "F5 branch -D main blocked"        2 'git branch -D main'
t "branch -D feature allowed"        0 'git branch -D feature/x-old'
t "push --delete feature allowed"    0 'git push origin --delete jasongarcia/sad-1-old'
t "D0 inline ALLOW_MAIN_PUSH blocked" 2 'ALLOW_MAIN_PUSH=1 git push origin main'
t "wrapper-flag env -i blocked"      2 'env -i git reset --hard'
t "wrapper-flag sudo -u blocked"     2 'sudo -u jason git reset --hard'

echo "== round-3 refspec + evasion probes (Watson/Barb, PR #159) =="
t "F1 path-prefixed gh blocked"      2 '/usr/bin/gh pr merge 42 --squash'
t "F1 wrapper gh recovery"           2 'sudo -u jason gh pr merge 42'
t "F2 heads/main blocked"            2 'git push origin heads/main'
t "F2 HEAD:refs/heads/main blocked"  2 'git push origin HEAD:refs/heads/main'
t "F2 feature:refs/heads/main blocked" 2 'git push origin feature/x:refs/heads/main'
t "F2 +main force refspec blocked"   2 'git push origin +main'
t "F2 +refs/heads/main blocked"      2 'git push origin +refs/heads/main'
t "F5 :refs/heads/main blocked"      2 'git push origin :refs/heads/main'
t "F5 --delete heads/main blocked"   2 'git push origin --delete heads/main'
t "F2 HEAD push on main blocked"     2 'git push origin HEAD' "CLAUDE_PROJECT_DIR=$TMPMAIN" "$TMPMAIN"
t "HEAD push on feature allowed"     0 'git push origin HEAD' "CLAUDE_PROJECT_DIR=$TMPFEAT" "$TMPFEAT"
t "F2 --all blocked"                 2 'git push --all origin'
t "F2 --mirror blocked"              2 'git push --mirror origin'
t "tags-only push on main allowed"   0 'git push origin --tags' "CLAUDE_PROJECT_DIR=$TMPMAIN" "$TMPMAIN"
t "F6 no-verify push blocked"        2 'git push --no-verify origin feature'
t "F6 inline hooksPath blocked"      2 'git -c core.hooksPath=/dev/null push origin feature'
t "F6 config hooksPath away blocked" 2 'git config core.hooksPath /tmp/hooks'
t "config hooksPath .githooks allowed" 0 'git config core.hooksPath .githooks'

echo "== SAD-181: repo-scoped F-rows + config-driven default branch =="
t "F4 scoped: other-repo main commit allowed"   0 'git commit -m wip' '' "$TMPMAIN"
t "F2 scoped: other-repo main push allowed"     0 'git push origin main' '' "$TMPMAIN"
t "F1 scoped: gh pr merge elsewhere allowed"    0 'gh pr merge 42 --squash' '' "$TMPMAIN"
t "F1 --repo from elsewhere still blocked"      2 'gh pr merge 42 --repo o/endurance-logger' '' "$TMPMAIN"
t "F1 -R from elsewhere still blocked"          2 'gh pr merge 42 -R o/r' '' "$TMPMAIN"
t "F1 GH_REPO env from elsewhere blocked"       2 'GH_REPO=o/endurance-logger gh pr merge 5 --squash' '' "$TMPMAIN"
t "F1 PR-URL arg from elsewhere blocked"        2 'gh pr merge https://github.com/o/endurance-logger/pull/5 --squash' '' "$TMPMAIN"
t "gh pr view URL from elsewhere allowed"       0 'gh pr view https://github.com/o/r/pull/5' '' "$TMPMAIN"
t "F1 multi-segment GH_REPO redirect blocked"   2 'export GH_REPO=o/r && gh pr merge 5 --squash' '' "$TMPMAIN"
t "F1 gh repo set-default sibling blocked"      2 'gh repo set-default o/r && gh pr merge 5 --squash' '' "$TMPMAIN"
t "F1 URL only in --body allowed (not target)"  0 'gh pr merge 5 --squash --body see-https://github.com/o/r/pull/9' '' "$TMPMAIN"
# Watson/Barb HIGH regression probes: gh arg-grammar-aware merge-target detection
t "F1 URL target after --body decoy blocked"    2 'gh pr merge --body x https://github.com/o/endurance-logger/pull/5 --squash' '' "$TMPMAIN"
t "F1 URL target after -b decoy blocked"        2 'gh pr merge -b x https://github.com/o/endurance-logger/pull/5' '' "$TMPMAIN"
t "F1 URL target after --match-head decoy blk"  2 'gh pr merge --match-head-commit abc https://github.com/o/endurance-logger/pull/5' '' "$TMPMAIN"
t "F1 URL target + trailing merge word blocked" 2 'gh pr merge https://github.com/o/endurance-logger/pull/5 --subject auto merge now' '' "$TMPMAIN"
t "F1 URL in body w/ merge word allowed"        0 'gh pr merge 5 --squash --body see the merge https://github.com/o/r/pull/9' '' "$TMPMAIN"
t "F1 glued -Ro/repo blocked"                   2 'gh pr merge -Ro/endurance-logger 5 --squash' '' "$TMPMAIN"
t "F1 quoted GH_REPO sibling blocked"           2 'GH_"R"EPO=o/r gh pr view 1 && gh pr merge 5' '' "$TMPMAIN"
t "F6 scoped: no-verify elsewhere allowed"      0 'git push --no-verify origin feature' '' "$TMPMAIN"
t "F5 scoped: branch -D main elsewhere allowed" 0 'git branch -D main' '' "$TMPMAIN"
t "D1 unscoped: reset --hard elsewhere blocked" 2 'git reset --hard' '' "$TMPMAIN"
t "D3 unscoped: rm -rf / elsewhere blocked"     2 'rm -rf /' '' "$TMPMAIN"
TMPWT="$TMPMAIN-wt"
git -C "$TMPMAIN" worktree add -q -b tfeat "$TMPWT" 2>/dev/null
t "F2 fires from a linked worktree (shared common dir)" 2 'git push origin main' "CLAUDE_PROJECT_DIR=$TMPMAIN" "$TMPWT"
git -C "$TMPMAIN" worktree remove --force "$TMPWT" 2>/dev/null
t "F6 --no-ver abbreviation blocked" 2 'git push --no-ver origin feature'
t "F6 --get read exempt"             0 'git config --get core.hooksPath'
t "F6 case-insensitive hookspath"    2 'git config core.hookspath /tmp/x'
rm -rf "$TMPMAIN" "$TMPFEAT"

echo "== SAD-258: shell field-separator (\$IFS) obfuscation normalized before rules =="
# Assemble the $IFS token forms at runtime (single-quoted = literal expansion
# text) so these obfuscated payloads never appear verbatim in this source file.
# The hook must collapse each to a single space before the D/F rules run, so the
# command anchors match despite the missing literal whitespace between tokens.
ifsB='${IFS}'; ifsU='$IFS'; ifsS='${IFS%??}'; nonIfs='${IF}'
t "D1 IFS-braced reset --hard blocked"          2 "git${ifsB}reset --hard"
t "D1 IFS-unbraced reset --hard blocked"        2 "git${ifsU} reset --hard"
t "D1 IFS-suffix reset --hard blocked"          2 "git${ifsS}reset --hard"
t "D1 leading-IFS reset --hard blocked"         2 "${ifsB}git reset --hard"
t "D1 IFS-obfuscated sudo wrapper blocked"      2 "sudo${ifsB}git${ifsB}reset --hard"
t "D5 IFS-obfuscated serial-less adb blocked"   2 "adb${ifsB}shell ls /sdcard"
t "F1 IFS-obfuscated gh pr merge blocked"       2 "gh${ifsB}pr${ifsB}merge 5 --squash"
t "F2 IFS-obfuscated push origin main blocked"  2 "git${ifsB}push origin main"
# Specificity: a non-IFS \${IF} brace and an identifier-extended \$IFSTOP are NOT
# field separators; leaving them intact must not turn a benign line into a match.
t "non-IFS \${IF} brace NOT a separator (allowed)"        0 "gitx${nonIfs}status"
t "identifier-extended \$IFSTOP NOT a separator (allowed)" 0 "echo ${ifsU}TOP"

echo "== SAD-357: empty-expansion glue (\$1-\$9/\$@/\$*, IFS-reglue) normalized =="
# Empty-positional params (\$1-\$9/\$@/\$*) expand to nothing at the top level and
# are used purely to glue a keyword to an adjacent token; the hook space-pads them
# AND reorders the IFS collapse BEFORE the dequote so the D/F anchors still match
# (Barb audit, PR #263 / SAD-258). Payloads assembled at runtime as above.
p9='$9'; pAt='$@'; p9b='${9}'; d0='$0'; ifsSub='${IFS:0:1}'
t "D1 IFS+\$9 glue reset --hard blocked"     2 "git${ifsU}${p9}reset --hard"
t "D1 braced-IFS+\$9 glue blocked"           2 "git${ifsB}${p9}reset --hard"
t "D1 IFS + empty-quote reglue blocked"      2 "git${ifsU}\"\"reset --hard"
t "D1 bare \$9 positional glue blocked"      2 "git ${p9}reset --hard"
t "D1 \$@ positional glue blocked"           2 "git ${pAt}reset --hard"
t "D1 braced \${9} glue blocked"             2 "git ${p9b}reset --hard"
t "D1 IFS substring :0:1 form blocked"       2 "git${ifsSub}reset --hard"
t "F1 IFS+\$9 gh pr merge glue blocked"      2 "gh${ifsU}${p9}pr${ifsU}${p9}merge 5 --squash"
# Specificity / no-false-positive: \$0 is the shell name (non-empty) so NOT glue,
# and a benign command carrying \$@ must still pass.
t "\$0 (non-empty) not treated as glue"      0 "echo ${d0}x"
t "benign \$@ forward not blocked"           0 "bash script.sh ${pAt}"
# Watson (SAD-357): a leading QUOTED empty-expansion collapses to a leading space
# only AFTER dequote, so the trim runs post-dequote or the ^...git/^...gh anchor is
# defeated. Plus explicit coverage for \$*, braced \${@}, and low-boundary \$1.
qAt='"$@"'; q9='"$9"'; pStar='$*'; pAtB='${@}'; p1='$1'
t "D1 leading quoted \$@ glue blocked"        2 "${qAt}git reset --hard"
t "D1 leading quoted \$9 glue blocked"        2 "${q9}git reset --hard"
t "F1 leading quoted \$@ gh pr merge blocked" 2 "${qAt}gh pr merge 5 --squash"
t "D1 \$* positional glue blocked"            2 "git ${pStar}reset --hard"
t "D1 braced \${@} glue blocked"              2 "git ${pAtB}reset --hard"
t "D1 \$1 low-boundary glue blocked"          2 "git ${p1}reset --hard"

echo "== SAD-552: D0 — no prose carve-out; boundary tightening + glue normalization =="
# The reported D0 false positive (a commit message that DOCUMENTS a seam) is NOT
# fixed by a hook change: two independent reviewers broke the masking that tried
# to (see the hook header). It is remediated by authoring the message with
# Write/Edit and passing a PATH -- git commit -F <file> -- which never puts the
# prose on a Bash command line. These rows pin that D0 stays broad.
TMPD0="$(mktemp -d)"; git -C "$TMPD0" init -q -b feature/d0
git -C "$TMPD0" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
d0env="CLAUDE_PROJECT_DIR=$TMPD0"
# -- Barb PoC #1: the heredoc is co-located with `git` but OWNED by `bash`.
hd_barb="$(printf "git log -F - ; bash <<'MSG'\nLAND_PR_TEST=1 tools/dev/land-pr.sh 5\nMSG")"
t "D0 PoC(Barb): heredoc owned by bash on a git-led line" 2 "$hd_barb" "$d0env" "$TMPD0" D0
hd_barb2="$(printf 'gh pr view 1 --body-file - ; bash <<"MSG"\nLAND_PR_TEST=1 tools/dev/land-pr.sh 5\nMSG')"
t "D0 PoC(Barb): same shape, gh + double-quoted delimiter" 2 "$hd_barb2" "$d0env" "$TMPD0" D0
# -- Watson PoC: a decoy message flag INSIDE a quoted string skews quote pairing.
t "D0 PoC(Watson): quoted decoy -m skews quote pairing"   2 "git status && echo 'a -m ' && LAND_PR_TEST=1 tools/dev/land-pr.sh 434 && echo 'z'" "$d0env" "$TMPD0" D0
t "D0 PoC(Watson): same with a --body decoy"              2 "git status && echo 'a --body ' && LAND_PR_TEST=1 tools/dev/land-pr.sh 434 && echo 'z'" "$d0env" "$TMPD0" D0
# -- a message body that NAMES a marker is still blocked, deliberately. The
#    remedy is `git commit -F <path>`, not a hook carve-out and not a reword.
hd_prose="$(printf "git commit -F - <<'MSG'\nfix(land): document the LAND_PR_TEST=1 seam\nMSG")"
t "D0 prose-in-heredoc still blocked (remedy: -F <path>)" 2 "$hd_prose" "$d0env" "$TMPD0"
t "D0 prose in -m still blocked (remedy: -F <path>)"      2 "git commit -m 'docs: describe the LAND_PR_TEST=1 seam'" "$d0env" "$TMPD0"
t "D0 -F <path> is the sanctioned form"                   0 'git commit -F /tmp/msg.txt' "$d0env" "$TMPD0"
# -- the [^A-Za-z0-9_] boundary: assignments hiding immediately after a quote.
t "D0 ADV: bash -c wrapper blocked"          2 "bash -c 'LAND_PR_TEST=1 tools/dev/land-pr.sh 5'" "$d0env" "$TMPD0"
t "D0 ADV: eval wrapper blocked"             2 'eval "LAND_PR_TEST=1 tools/dev/land-pr.sh 5"' "$d0env" "$TMPD0"
t "D0 ADV: printf-built script file blocked" 2 "printf 'LAND_PR_TEST=1 tools/dev/land-pr.sh 5' > /tmp/run.sh" "$d0env" "$TMPD0"
t "D0 ADV: ssh -t value blocked"             2 "ssh host -t 'LAND_PR_TEST=1 tools/dev/land-pr.sh 5'" "$d0env" "$TMPD0"
t "D0 ADV: gh alias set (executes its arg) blocked"     2 "gh alias set z '!LAND_PR_TEST=1 tools/dev/land-pr.sh 5'" "$d0env" "$TMPD0"
t "D0 ADV: git config alias (executes its arg) blocked" 2 "git config alias.z '!LAND_PR_TEST=1 tools/dev/land-pr.sh 5'" "$d0env" "$TMPD0"
t "D0 ADV: \$( ) inside a -m value blocked"  2 'git commit -m "note $(LAND_PR_TEST=1 x)"' "$d0env" "$TMPD0"
t "D0 ADV: subshell paren boundary blocked"  2 '(LAND_PR_TEST=1 tools/dev/land-pr.sh 5)' "$d0env" "$TMPD0"
# -- runtime-vanishing glue: the $1-$9 form leaves a DIGIT, which the identifier
#    boundary alone does not open, so D0 runs the SAD-258/357 normalization too.
t "D0 ADV: bare \$9 glue blocked"            2 "${p9}LAND_PR_TEST=1 tools/dev/land-pr.sh 5" "$d0env" "$TMPD0"
t "D0 ADV: braced \${9} glue blocked"        2 "${p9b}LAND_PR_TEST=1 tools/dev/land-pr.sh 5" "$d0env" "$TMPD0"
t "D0 ADV: \$@ glue blocked"                 2 "${pAt}LAND_PR_TEST=1 tools/dev/land-pr.sh 5" "$d0env" "$TMPD0"
t "D0 ADV: \${IFS} glue blocked"             2 "${ifsB}LAND_PR_TEST=1 tools/dev/land-pr.sh 5" "$d0env" "$TMPD0"
t "D0 ADV: mid-command \$9 glue blocked"     2 "echo hi && x${p9}LAND_PR_TEST=1 tools/dev/land-pr.sh 5" "$d0env" "$TMPD0"
# -- specificity: an identifier char before the name is a DIFFERENT variable.
t "D0 identifier-prefixed name is NOT the marker" 0 'echo MY_LAND_PR_TEST=1' "$d0env" "$TMPD0"
# Unbraced $IFS followed by an identifier char is not a separator (SAD-258, same
# rule as $IFSTOP): $IFSLAND_PR_TEST names another variable and bash ends up running
# `=1 ...`, not an assignment.
t "D0 \$IFS-extended name is a different variable, not glue" 0 "${ifsU}LAND_PR_TEST=1 tools/dev/land-pr.sh 5" "$d0env" "$TMPD0"
# -- ACCEPTED COST of the widened boundary: a Bash command that SEARCHES for a
#    marker now blocks too. Sanctioned remedy is the Grep tool, not a reword.
t "D0 known FP: a Bash grep for the marker blocks (use the Grep tool)" 2 "grep -rn 'LAND_PR_TEST=1' tools/dev/" "$d0env" "$TMPD0"
# -- the D/F rules still scan embedded text; nothing was carved out for anyone.
hd_rm="$(printf "git commit -F - <<'MSG'\nfix: stop the rm -rf / footgun\nMSG")"
t "D3 still scans a heredoc body" 2 "$hd_rm" "$d0env" "$TMPD0" D3
rm -rf "$TMPD0"

echo "== SAD-552: DIFFERENTIAL rows — every verdict this change moves, asserted =="
# base = the hook on the default branch, head = this tree. An unintended verdict
# flip in EITHER direction fails here even if the absolute-rc rows still pass.
# INTENDED relaxations (the false positives this issue is about):
t_delta "delta: bare core.hooksPath read now allowed"      2 0 'git config core.hooksPath'
t_delta "delta: --get-all read now allowed"                2 0 'git config --get-all core.hooksPath'
t_delta "delta: --get-regexp read now allowed"             2 0 'git config --get-regexp core.hooksPath'
t_delta "delta: modern config-get read now allowed"        2 0 'git config get core.hooksPath'
# INTENDED tightenings (pre-existing holes closed by the boundary widening):
t_delta "delta: bash -c wrapper now blocked"               0 2 "bash -c 'LAND_PR_TEST=1 tools/dev/land-pr.sh 5'"
t_delta "delta: eval wrapper now blocked"                  0 2 'eval "LAND_PR_TEST=1 tools/dev/land-pr.sh 5"'
t_delta "delta: printf-to-file now blocked"                0 2 "printf 'LAND_PR_TEST=1 tools/dev/land-pr.sh 5' > /tmp/run.sh"
t_delta "delta: bare \$9 glue now blocked"                 0 2 "${p9}LAND_PR_TEST=1 tools/dev/land-pr.sh 5"
t_delta "delta: .githooks trailing-comment decoy now blocked" 0 2 'git config core.hooksPath /tmp/evilhooks # core.hooksPath .githooks'
# ACCEPTED COST of the widening — asserted so it stays a decision, not a surprise:
t_delta "delta: a Bash grep for the marker now blocks"     0 2 "grep -rn 'LAND_PR_TEST=1' tools/dev/"
# MUST NOT MOVE — the controls this issue must not weaken:
t_delta "delta: inline assignment stays blocked"           2 2 'LAND_PR_TEST=1 tools/dev/land-pr.sh 5'
t_delta "delta: hooksPath set stays blocked"               2 2 'git config core.hooksPath /tmp/hooks'
t_delta "delta: hooksPath empty-value set stays blocked"   2 2 "git config core.hooksPath ''"
t_delta "delta: --unset stays blocked"                     2 2 'git config --unset core.hooksPath'
t_delta "delta: .githooks doctor set stays allowed"        0 0 'git config core.hooksPath .githooks'
# Round-5 findings — the payloads that discriminate. All were ALLOWED by main.
t_delta "delta: option-as-value stays blocked"             2 2 'git config core.hooksPath --local'
t_delta "delta: whitespace-only value stays blocked"       2 2 "git config core.hooksPath ' '"
t_delta "delta: --unset-all + .githooks now blocked"       0 2 'git config --unset-all core.hooksPath .githooks'
t_delta "delta: .githooks trailing-comment decoy blocked"  0 2 'git config core.hooksPath /tmp/evilhooks # core.hooksPath .githooks'
t_delta "delta: --path --get read stays allowed"           0 0 'git config --path --get core.hooksPath'
t_delta "delta: prose-in-heredoc stays blocked"            2 2 "$hd_prose"
t_delta "delta: -F <path> stays allowed"                   0 0 'git commit -F /tmp/msg.txt'

echo "== SAD-552: F6 separates READING core.hooksPath from WRITING it =="
t "F6 FP: bare read allowed"                    0 'git config core.hooksPath'
t "F6 FP: --get-all read allowed"               0 'git config --get-all core.hooksPath'
t "F6 FP: --get-regexp read allowed"            0 'git config --get-regexp core.hooksPath'
t 'F6 FP: modern config-get read allowed'       0 'git config get core.hooksPath'
t "F6 ADV: deprecated set still blocked"        2 'git config core.hooksPath /tmp/hooks'
t "F6 ADV: --unset still blocked"               2 'git config --unset core.hooksPath'
t "F6 ADV: --add still blocked"                 2 'git config --add core.hooksPath /tmp/h'
t "F6 ADV: --replace-all still blocked"         2 'git config --replace-all core.hooksPath /tmp/h'
t 'F6 ADV: modern config-set still blocked'     2 'git config set core.hooksPath /tmp/h'
t 'F6 ADV: modern config-unset still blocked'   2 'git config unset core.hooksPath'
t "F6 ADV: --type decoy before the value still blocked" 2 'git config --type path core.hooksPath /tmp/h'
t "F6 ADV: -f <file> location flag still blocked" 2 'git config -f .git/config core.hooksPath /tmp/h'
t "F6 ADV: --global set still blocked"          2 'git config --global core.hooksPath /tmp/h'
t "F6 ADV: unknown value-flag over-counts -> still blocked" 2 'git config --comment note core.hooksPath /tmp/h'
t "F6 set to .githooks still allowed"           0 'git config core.hooksPath .githooks'
# Barb/Watson: git's parse-options accepts any UNAMBIGUOUS PREFIX, so an
# enumerate-the-writes classifier fails open on every spelling it lacks. The
# classifier is affirmative-read / fail-closed, so an abbreviation is a write.
t 'F6 ADV: --unset- abbreviation blocked'        2 'git config --unset- core.hooksPath'
t 'F6 ADV: --unset-a abbreviation blocked'       2 'git config --unset-a core.hooksPath'
t 'F6 ADV: --unset-al abbreviation blocked'      2 'git config --unset-al core.hooksPath'
t 'F6 ADV: --unse abbreviation blocked'          2 'git config --unse core.hooksPath'
t 'F6 ADV: abbreviation behind a location flag blocked' 2 'git config --file .git/config --unset-a core.hooksPath'
t 'F6 ADV: unknown long option is a write'       2 'git config --xyzzy core.hooksPath'
# The .githooks exemption is bound to the VALUE BEING SET, not to the text
# appearing anywhere in the segment (Barb: a trailing shell comment, or
# --comment's own value, satisfied the old free-text grep while a different
# path was written).
t 'F6 ADV: .githooks in a trailing comment does not exempt' 2 'git config core.hooksPath /tmp/evilhooks # core.hooksPath .githooks'
t 'F6 ADV: .githooks as --comment value does not exempt'    2 "git config --comment 'core.hooksPath .githooks' core.hooksPath /tmp/evilhooks"
t 'F6 modern set to .githooks still allowed'     0 'git config set core.hooksPath .githooks'
# Barb HIGH-A: git has already consumed the NAME, so the next token is the VALUE
# however option-shaped it looks. A shape-based walk called these live writes
# "reads" — the exact-form matcher cannot, because the name must be LAST.
t 'F6 ADV: --local as the VALUE blocked'        2 'git config core.hooksPath --local' '' "$ROOT" F6
t 'F6 ADV: -z as the VALUE blocked'             2 'git config core.hooksPath -z'      '' "$ROOT" F6
t 'F6 ADV: --all as the VALUE blocked'          2 'git config core.hooksPath --all'   '' "$ROOT" F6
t 'F6 ADV: --fixed-value as the VALUE blocked'  2 'git config core.hooksPath --fixed-value' '' "$ROOT" F6
t 'F6 ADV: scope flag then option-as-value blocked' 2 'git config --global core.hooksPath --local' '' "$ROOT" F6
# Barb HIGH-B: the dequote DELETES quote chars, so a blank or quote-only value
# vanished and deflated the count. Quoted regions now collapse to one token.
t 'F6 ADV: empty value blocked'                 2 "git config core.hooksPath ''"   '' "$ROOT" F6
t 'F6 ADV: whitespace-only value blocked'       2 "git config core.hooksPath ' '"  '' "$ROOT" F6
t 'F6 ADV: multi-space value blocked'           2 "git config core.hooksPath '  '" '' "$ROOT" F6
t 'F6 ADV: quote-only value blocked'            2 "git config core.hooksPath \"''\"" '' "$ROOT" F6
t 'F6 ADV: single-quote value blocked'          2 "git config core.hooksPath \"'\""  '' "$ROOT" F6
# Watson C1: for the unset family a trailing positional is a VALUE-PATTERN, not
# the value being set, so no exemption may be derived from its position.
t 'F6 ADV: --unset-all + .githooks pattern blocked' 2 'git config --unset-all core.hooksPath .githooks' '' "$ROOT" F6
t 'F6 ADV: --unset + .githooks pattern blocked'     2 'git config --unset core.hooksPath .githooks'     '' "$ROOT" F6
t 'F6 ADV: --unset-a abbrev + .githooks blocked'    2 'git config --unset-a core.hooksPath .githooks'   '' "$ROOT" F6
t 'F6 ADV: --replace-all + empty + .githooks blocked' 2 "git config --replace-all core.hooksPath '' .githooks" '' "$ROOT" F6
t 'F6 ADV: -f file --unset-all + .githooks blocked' 2 'git config -f .git/config --unset-all core.hooksPath .githooks' '' "$ROOT" F6
t 'F6 ADV: empty value + .githooks decoy blocked'   2 "git config core.hooksPath '' .githooks" '' "$ROOT" F6
# Reads the exact-form matcher must keep allowing.
t 'F6 --path --get read allowed'   0 'git config --path --get core.hooksPath'
t 'F6 --local bare read allowed'   0 'git config --local core.hooksPath'
t 'F6 quoted-name read allowed'    0 "git config --get 'core.hooksPath'"
t 'F6 read with a scope flag allowed'            0 'git config --global --get core.hooksPath'

echo "== jq fail-closed =="
out=$(mk 'echo hi' | env PATH=/nonexistent /bin/bash "$H/pre-bash-safety.sh" 2>&1); rc=$?
if [ "$rc" = "2" ]; then echo "PASS  jq missing fails closed (rc=2)"; pass=$((pass+1)); else echo "FAIL  jq missing (rc=$rc) :: $out"; fail=$((fail+1)); fi

echo "== post-bash-secret-scan.sh =="
FAKE_G="AIzaxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
mkpost() { jq -n --arg c "$1" --arg o "$2" '{tool_input:{command:$c}, tool_response:{stdout:$o, stderr:""}}'; }
p() { # $1=case name  $2=expected rc  $3=command  $4=output
  local out rc
  out=$(mkpost "$3" "$4" | bash "$H/post-bash-secret-scan.sh" 2>&1); rc=$?
  if [ "$rc" = "$2" ]; then echo "PASS  $1 (rc=$rc)"; pass=$((pass+1)); else echo "FAIL  $1 (rc=$rc expected=$2) :: $out"; fail=$((fail+1)); fi
}
out=$(mkpost 'env' "SOME_KEY=$FAKE_G" | bash "$H/post-bash-secret-scan.sh" 2>&1); rc=$?
if [ "$rc" = "2" ] && ! grep -q "$FAKE_G" <<<"$out"; then echo "PASS  fake google key tripped, value not echoed"; pass=$((pass+1)); else echo "FAIL  google key case (rc=$rc) :: $out"; fail=$((fail+1)); fi
p "private key block tripped"        2 'cat cert.pem' '-----BEGIN RSA PRIVATE KEY-----'
p "benign output clean"              0 'ls -la' 'total 48 drwxr-xr-x'
p "generic key=value tripped"        2 'env' 'API_KEY=abcdefgh1234567890xyz'
p "PASSWORD env var tripped"         2 'env' 'SMTP_PASSWORD=re_xxxxxxxxxxxxxxxxxxxx'
p "JSON-quoted api_key tripped"      2 'cat cfg.json' '"api_key": "abcdefgh1234567890"'
p "Bearer header tripped"            2 'curl -v api' 'Authorization: Bearer abcdef1234567890abcdef'
p "npm integrity hash clean"         0 'cat package-lock.json' '"integrity": "sha512-AbCdEfGh1234567890xxxxxxxxxxxxxxxx=="'
p "anthropic key shape tripped"      2 'env' 'KEY=sk-ant-xxxxxxxxxxxxxxxxxxxxxxxx'
p "stripe live key shape tripped"    2 'env' 'K=sk_live_xxxxxxxxxxxxxxxx'
p "resend key shape tripped"         2 'cat .env' 'RESEND=re_xxxxxxxxxxxxxxxxxx'
p "prose re_ boundary clean"         0 'echo x' 'genre_classification_results_ready_now'
p "prose sk- boundary clean"         0 'echo x' 'task-sk-quarterly-report-generation-notes'
p "test-harness PASS lines clean"    0 'bash tools/dev/test-hooks.sh' 'PASS  D1 reset --hard blocked (rc=2)'

echo "== SAD-552: the scanner reports key MATERIAL, not the WORD for it =="
PEM_HDR='-----BEGIN RSA PRIVATE KEY-----'
SA_JSON='  "private_key": "-----BEGIN PRIVATE KEY-----xxxxxxxxxxxxxxxxxxxxxxxxxx\n",'
# -- the observed false positives (SAD-552): a marker in the command's own
#    search-pattern operand, and a marker in a pattern DEFINITION that was read.
p "FP: grep for the PEM header PHRASE (no armour)" 0 "grep -rn 'BEGIN PRIVATE KEY' ." ''
# ACCEPTED RESIDUAL (SAD-552): grepping for the FULL armour string still trips.
# The operand masking that made it clean was removed — Barb showed a `|` inside
# a quoted string manufactures a fake grep segment, so `echo "x | grep '<key>'"
# >> notes.md` wrote a real key to disk and was masked. Same root cause as the
# reverted D0 carve-out. The remedy is the Grep tool, not a masked scanner.
p "ACCEPTED: full armour in a grep operand still trips" 2 "grep -rn -- '$PEM_HDR' /home/x/.ssh" ''
p "Barb: key laundered past a fake grep segment still trips" 2 "echo \"x | grep '$PEM_HDR'\" >> notes.md" ''
p "Barb: key written by echo still trips"          2 "echo '$PEM_HDR' >> notes.md" ''
p "FP: grep for the JSON key NAME"    0 'grep -rni "\"private_key\"" .claude/hooks' ''
# Watson #10: this row USED to feed one hand-written line quoting `scan_marker`
# -- a function that no longer exists -- so it passed while reading the actual
# file failed. Feed the REAL files instead. This is the regression pin for the
# hook's own source tripping its own tripwire: a comment quoting live PEM armour
# took reading post-bash-secret-scan.sh from rc=0 at the merge base to rc=2, and
# the hand-written payload could not see it. Write about armour with the
# ellipsis form (`-----BEGIN <ellipsis> PRIVATE KEY-----`) and this stays green.
p "FP: the scanner's OWN source is clean"   0 'cat .claude/hooks/post-bash-secret-scan.sh' "$(cat "$H/post-bash-secret-scan.sh")"
p "FP: pre-bash-safety's source is clean"   0 'cat .claude/hooks/pre-bash-safety.sh'       "$(cat "$H/pre-bash-safety.sh")"
p "FP: prose naming a private key"    0 'cat docs/setup.md' 'Download the JSON; it carries a private_key field.'
# The MARKER now requires the CLOSING armour too — that, not masking, is what
# keeps a search for the header PHRASE clean while a real block still trips.
p "FP: opening armour only, no closing"  0 'cat notes.md' 'the block starts -----BEGIN RSA PRIVATE KEY'
p "ADV: full armour pair tripped"        2 'cat notes.md' 'x -----BEGIN RSA PRIVATE KEY----- y'
p "FP: empty JSON key in a schema"    0 'cat schema.json' '{"private_key": ""}'
# -- adversarial: real key material must still trip --
p "ADV: PEM armour in output still tripped" 2 'cat id_rsa' "$PEM_HDR"
p "ADV: PEM armour in a grep's OUTPUT still tripped" 2 "grep -rn 'PRIVATE' ." "certs/id.pem:1:$PEM_HDR"
p "ADV: service-account JSON value still tripped" 2 'cat sa.json' "$SA_JSON"
p "ADV: real key in a grep OPERAND still tripped (value class)" 2 "grep -rn '$FAKE_G' ." ''
p "ADV: real PEM body in a grep operand caught by the generic pattern" 2 \
  "grep -rn 'private_key\": \"MIIEvQIBADANBgkqhkiG9w0BA' sa.json" ''
p "ADV: sibling non-grep segment still scanned" 2 "grep -rn x . && echo '$PEM_HDR' > k.pem" ''
p "ADV: marker in output beside a masked grep operand still tripped" 2 \
  "grep -rn 'BEGIN PRIVATE KEY' ." "id_rsa:1:$PEM_HDR"
# Barb HIGH / Watson I3: the first cut claimed the generic 12+-char pattern was
# the backstop for a masked PEM. It is not -- private[_-]?key cannot match
# "PRIVATE KEY" and "-----BEGIN" is 10 chars. A full key transited a grep operand
# with NO tripwire. The VALUE-class private-key-material pattern (armour + body,
# never masked) is what makes the coarse marker masking safe.
PEM_BODY="xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
p "ADV: full PEM in a grep operand tripped (VALUE class)" 2 "grep -rn -- '$PEM_HDR$PEM_BODY' /home/x/.ssh" ''
p "ADV: full PEM laundered behind a decoy pattern tripped" 2 "grep -q zzz '$PEM_HDR$PEM_BODY'" ''
p "ADV: rg operand with a full PEM tripped"               2 "rg -e '$PEM_HDR$PEM_BODY' ." ''
p "ADV: service-account JSON in a grep operand tripped"   2 "grep -rn '{\"private_key\":\"$PEM_HDR$PEM_BODY\"}' ." ''
# Watson I4: pinning exactly five hyphens narrowed detection past the OLD
# pattern. RFC 7468 armour is a hyphen run; these used to trip and must again.
p "ADV: four-hyphen armour tripped"       2 'cat k.pem' '---- BEGIN ENCRYPTED PRIVATE KEY ----'
p "ADV: four-hyphen tight armour tripped" 2 'cat k.pem' '----BEGIN PRIVATE KEY----'
p "ADV: six-hyphen armour tripped"        2 'cat k.pem' '------BEGIN PRIVATE KEY------'
p "ADV: SSH2-style digit label tripped"   2 'cat k.pem' '-----BEGIN SSH2 PRIVATE KEY-----'

echo "== .githooks/pre-push (SAD-177) =="
PP="$ROOT/.githooks/pre-push"
if [ -f "$PP" ]; then
  echo "refs/heads/f abc refs/heads/main def" | bash "$PP" >/dev/null 2>&1; rc=$?
  if [ "$rc" = "1" ]; then echo "PASS  pre-push blocks main update"; pass=$((pass+1)); else echo "FAIL  pre-push main (rc=$rc)"; fail=$((fail+1)); fi
  echo "(delete) 0000 refs/heads/main def" | bash "$PP" >/dev/null 2>&1; rc=$?
  if [ "$rc" = "1" ]; then echo "PASS  pre-push blocks main deletion"; pass=$((pass+1)); else echo "FAIL  pre-push delete (rc=$rc)"; fail=$((fail+1)); fi
  echo "refs/heads/f abc refs/heads/jasongarcia/sad-999-main-screen def" | bash "$PP" >/dev/null 2>&1; rc=$?
  if [ "$rc" = "0" ]; then echo "PASS  pre-push allows feature branch (token-wise)"; pass=$((pass+1)); else echo "FAIL  pre-push feature (rc=$rc)"; fail=$((fail+1)); fi
  rc=$(export ALLOW_MAIN_PUSH=1; echo "refs/heads/f abc refs/heads/main def" | bash "$PP" >/dev/null 2>&1; echo $?)
  if [ "$rc" = "0" ]; then echo "PASS  pre-push hatch (ambient env) passes"; pass=$((pass+1)); else echo "FAIL  pre-push hatch (rc=$rc)"; fail=$((fail+1)); fi
  printf 'refs/heads/f abc refs/heads/f2 def\nrefs/heads/f abc refs/heads/main def\n' | bash "$PP" >/dev/null 2>&1; rc=$?
  if [ "$rc" = "1" ]; then echo "PASS  pre-push multi-ref push: main line caught"; pass=$((pass+1)); else echo "FAIL  pre-push multi-ref (rc=$rc)"; fail=$((fail+1)); fi
else
  echo "SKIP  .githooks/pre-push not present"
fi

echo "== lint-on-edit.sh =="
out=$(jq -n '{tool_input:{file_path:"/tmp/x.kt"}}' | env CLAUDE_PROJECT_DIR="$ROOT" bash "$H/lint-on-edit.sh" 2>&1); rc=$?
if [ "$rc" = "0" ]; then echo "PASS  no config -> fast no-op"; pass=$((pass+1)); else echo "FAIL  no-config (rc=$rc) :: $out"; fail=$((fail+1)); fi

echo ""
echo "RESULT: $pass passed, $fail failed"
[ "$fail" = "0" ]
