#!/usr/bin/env bash
# shellcheck disable=SC2016  # single-quoted $HOME fixtures are literal test payloads by design
# tools/dev/test-hooks.sh — regression table for the Claude Code safety hooks
# (SAD-176). Feeds synthetic hook payloads to the scripts and asserts exit
# codes; no command in the table is ever executed. Run after ANY hook edit.
#
# NOTE: the "secret" strings below are obviously-fake fixtures (x-padded),
# present only to exercise the detector patterns.

set -u

# ⚠ ROOT IS DERIVED FROM THIS SCRIPT'S OWN LOCATION, NOT THE CALLER'S CWD
# (SAD-731). A bare `git rev-parse --show-toplevel` resolves against wherever the
# operator happens to be standing, so running this suite from a SIBLING checkout
# silently audits that OTHER tree's hooks with this tree's table — and reports a
# perfectly normal-looking result. That produced two false measurements during one
# review, in different sessions: a plausible `469 PASS / 10 FAIL` taken while the
# mutations under test were no-ops against a different tree's hook, and a separate
# unreproducible single failure. Neither looked like an error; both looked like
# results. For a suite whose entire value is RED-checkability, a false GREEN is the
# worst available failure mode, so the tree under test is pinned to the tree the
# script was loaded from.
ROOT="$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)" || exit 1
H="$ROOT/.claude/hooks"
pass=0; fail=0; retried=0

mk() { # $1 = command, $2 = cwd (default repo root)
  jq -n --arg c "$1" --arg d "${2:-$ROOT}" '{tool_input:{command:$c}, cwd:$d}'
}

# ⚠ ONE invocation path, called twice. The primary call and the deadline retry
# below were character-identical duplicates; a future edit to one — a new env
# var, a changed payload shape — would silently desync the retry from the path it
# is supposed to re-run, with nothing turning red.
# Returns via globals because command substitution can carry only ONE value and
# this helper must return TWO — the captured output AND the exit status. The
# limit is arity, not propagation (`$?` propagates out of a subshell fine).
# It also `return`s the status, so `if _invoke …` or `_invoke … || fail` behave
# rather than always taking the success path.
_INV_OUT=""; _INV_RC=0
_invoke() { # $1=cmd $2=cwd $3=extra-env
  if [ -n "$3" ]; then
    # shellcheck disable=SC2086 # word-splitting multiple K=V assignments is the point
    _INV_OUT=$(mk "$1" "$2" | env CLAUDE_PROJECT_DIR="$ROOT" $3 bash "$H/pre-bash-safety.sh" 2>&1); _INV_RC=$?
  else
    _INV_OUT=$(mk "$1" "$2" | env CLAUDE_PROJECT_DIR="$ROOT" bash "$H/pre-bash-safety.sh" 2>&1); _INV_RC=$?
  fi
  return "$_INV_RC"
}

t() { # $1=name $2=expected rc $3=command [$4=extra env] [$5=cwd] [$6=expected rule id]
  # extra comes AFTER the default CLAUDE_PROJECT_DIR so tests can override the
  # project scope (SAD-181 repo-scoped F-rows); deliberate word-split.
  # $6 (optional): assert WHICH rule blocked. Without it an expected-2 case
  # passes if ANY rule fires, so a test can go green for the wrong reason. Pass
  # it on adversarial rows where the identity of the rule is the point.
  local name="$1" expect="$2" cmd="$3" extra="${4:-}" cwd="${5:-$ROOT}" rule="${6:-}"
  local rc out got
  _invoke "$cmd" "$cwd" "$extra"; out="$_INV_OUT"; rc="$_INV_RC"
  if [ "$rc" != "$expect" ]; then
    echo "FAIL  $name (rc=$rc expected=$expect) :: $out"; fail=$((fail+1)); return
  fi
  if [ -n "$rule" ]; then
    got=$(sed -n 's/^pre-bash-safety \[\([A-Z0-9]*\)\].*/\1/p' <<<"$out" | head -1)
    # ⚠ DEADLINE IS THE ONE NONDETERMINISTIC VERDICT — retry once before failing.
    # Deliberately-expensive adversarial rows cost seconds per hook invocation
    # against HOOK_DEADLINE_S=20, so on a loaded box a row can return DEADLINE
    # where it expects its own rule. Measured on the reference instance
    # (endurance-logger, whose rule set is a superset of this bundle's): 1 run in
    # 4 returning DEADLINE, which under a zero-headroom assertion floor fires
    # TWICE — as a suite failure AND as an under-count against the floor. A pin
    # that reddens a healthy tree is worse than the gap it closes.
    # A single retry preserves the assertion's meaning exactly: the deadline is
    # the only verdict that depends on wall-clock, so a row that genuinely blocks
    # on its own rule cannot be rescued by re-running, and a row whose rule really
    # regressed still fails on the second run. Do NOT lower the deadline instead
    # — that reintroduces the headroom the hardcoded threshold removed.
    if [ "$got" = "DEADLINE" ] && [ "$rule" != "DEADLINE" ]; then
      # ⚠ REPORT THE RETRY. Silently squaring the per-row failure probability
      # buys the green at the cost of the signal: a hook change that makes a rule
      # reachable only SOMETIMES — it still fires, but now races the deadline —
      # would be absorbed instead of surfaced.
      # The line deliberately does NOT start with `PASS`: an assertion-floor
      # check that counts `PASS*` lines must not be inflated by a retry notice.
      echo "RETRY $name (first run returned DEADLINE; re-running once)"; retried=$((retried+1))
      _invoke "$cmd" "$cwd" "$extra"; out="$_INV_OUT"; rc="$_INV_RC"
      if [ "$rc" != "$expect" ]; then
        echo "FAIL  $name (rc=$rc expected=$expect, on deadline retry) :: $out"; fail=$((fail+1)); return
      fi
      got=$(sed -n 's/^pre-bash-safety \[\([A-Z0-9]*\)\].*/\1/p' <<<"$out" | head -1)
    fi
    if [ "$got" != "$rule" ]; then
      echo "FAIL  $name (rule=$got expected=$rule) :: $out"; fail=$((fail+1)); return
    fi
  fi
  echo "PASS  $name (rc=$rc${rule:+ rule=$rule})"; pass=$((pass+1))
}

echo "== pre-bash-safety.sh: D-rows =="
t "D1 reset --hard blocked"          2 'git reset --hard HEAD~1'
t "D1 escape hatch"                  0 'git reset --hard HEAD~1' 'ALLOW_DESTRUCTIVE=1'
t "D1 -C form blocked"               2 'git -C /some/repo reset --hard origin/main' '' '' D1
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
t "D3 rm -rf * at repo root blocked" 2 'rm -rf *' '' '' D3
t "D3 rm -rf ./ at repo root blocked" 2 'rm -rf ./' '' '' D3
t "rm -rf . in subdir allowed"       0 'rm -rf .' '' "$ROOT/app/build"
t "D7 release.keystore blocked"      2 'git add release.keystore' '' '' D7
t "D7 debug.keystore blocked"        2 'git add app/debug.keystore'
t "D1 subshell form blocked"         2 '(git reset --hard)' '' '' D1
t "D1 env-prefix form blocked"       2 'GIT_DIR=x git reset --hard' '' '' D1
t "D1 after single & blocked"        2 'sleep 1 & git reset --hard' '' '' D1
t "D6 combined -uf blocked"          2 'git push -uf origin feature' '' '' D6
t "D5 path-prefixed adb blocked"     2 '/usr/bin/adb shell ls' '' '' D5
t "D4 path-prefixed adb blocked"     2 '/usr/local/bin/adb kill-server' '' '' D4
t "push --follow-tags allowed"       0 'git push --follow-tags origin feature'
out=$(mk 'sh -x tools/dev/setup-repo.sh' | env CLAUDE_PROJECT_DIR="$ROOT" bash "$H/pre-bash-safety.sh" 2>/dev/null); rc=$?
if [ "$rc" = "0" ] && grep -q "systemMessage" <<<"$out"; then echo "PASS  W1 sh -x warns too"; pass=$((pass+1)); else echo "FAIL  W1 sh -x (rc=$rc)"; fail=$((fail+1)); fi

echo "== Barb audit probes (quote/prefix normalization, D0, D5 grammar) =="
t "D1 quoted --hard blocked"         2 'git reset "--hard" HEAD~3' '' '' D1
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

echo "== scan deadline: both operands closed, and the bound reaches its call sites =="
# The deadline exists because past the PreToolUse timeout the gate is KILLED and
# the command runs UNCHECKED — every rule disabled at once. These rows pin the
# three ways that control silently stops working. They are deliberately CHEAP:
# the reference instance carries a much larger timed-probe suite (scaling ratios,
# execution probes, adversarial fixpoint payloads); porting that here would add
# minutes of wall-clock to a bundle suite that has no CI to absorb it. What is
# ported is the part that fails SILENTLY — a timed probe that regresses at least
# goes red on the clock.

# 1. THRESHOLD closed to the environment. An env-overridable HOOK_DEADLINE_S
#    would be a new escape hatch D0 cannot see: D0 blocks INLINE assignments,
#    and ambient env is invisible to it.
if grep -qE '^HOOK_DEADLINE_S=[0-9]+$' "$H/pre-bash-safety.sh"; then
  echo "PASS  deadline: threshold is a hardcoded literal, not \${HOOK_DEADLINE_S:-20}"; pass=$((pass+1))
else
  echo "FAIL  deadline: HOOK_DEADLINE_S is not a hardcoded literal — an ambient HOOK_DEADLINE_S=999 would disable the bound, and D0 cannot see ambient env"; fail=$((fail+1))
fi

# 2. CLOCK closed to the environment — the runtime half, not a grep. `SECONDS`
#    is INHERITED, so hardcoding the threshold closes only ONE operand of the
#    comparison. Probed against a COPY of the real hook with the threshold sed
#    to 0, so the row costs milliseconds instead of needing a payload expensive
#    enough to burn 20 s. The sed touches only the constant; the `SECONDS=0`
#    reset under test is the real line from the real file.
_dl_copy="$(mktemp)"; sed 's/^HOOK_DEADLINE_S=[0-9]*$/HOOK_DEADLINE_S=0/' "$H/pre-bash-safety.sh" > "$_dl_copy"
_dl_out="$(mk 'echo hello' "$ROOT" | env CLAUDE_PROJECT_DIR="$ROOT" SECONDS=-999999999 bash "$_dl_copy" 2>&1)"; _dl_rc=$?
if [ "$_dl_rc" = "2" ] && grep -q '\[DEADLINE\]' <<<"$_dl_out"; then
  echo "PASS  deadline: a poisoned ambient SECONDS does not defeat the bound (clock is reset)"; pass=$((pass+1))
else
  echo "FAIL  deadline: with an ambient SECONDS=-999999999 the zero-threshold hook returned rc=$_dl_rc — '[ \$SECONDS -lt \$HOOK_DEADLINE_S ]' is permanently true, so the deadline is disabled by an env var. Add 'SECONDS=0' before the first _deadline call: $_dl_out"; fail=$((fail+1))
fi
# Non-vacuity of the row above: the same probe against a copy with the reset
# REMOVED must go the other way. Without this, a hook that lost its deadline
# entirely would still satisfy the row if something else happened to block.
_dl_noreset="$(mktemp)"; grep -v '^SECONDS=0$' "$_dl_copy" > "$_dl_noreset"
_dl_n_out="$(mk 'echo hello' "$ROOT" | env CLAUDE_PROJECT_DIR="$ROOT" SECONDS=-999999999 bash "$_dl_noreset" 2>&1)"; _dl_n_rc=$?
if [ "$_dl_n_rc" = "0" ]; then
  echo "PASS  deadline: the reset is load-bearing — removing it reopens the fail-open (rc=0 under poisoned SECONDS)"; pass=$((pass+1))
else
  echo "FAIL  deadline: removing 'SECONDS=0' did NOT reopen the fail-open (rc=$_dl_n_rc) — the row above cannot distinguish a working reset from a hook that blocks for some other reason, so it is vacuous: $_dl_n_out"; fail=$((fail+1))
fi
rm -f "$_dl_copy" "$_dl_noreset"

# 3. CALL SITES. The bound is only as complete as the places that call it: a new
#    loop over segments or tokens added without a `_deadline` is unbounded, and
#    nothing else in this file would notice. Counting the call sites turns that
#    into a deliberate decision (raise the number) instead of a silent gap.
_dl_sites=$(grep -cE '^[[:space:]]+_deadline$' "$H/pre-bash-safety.sh")
_dl_expected=4
if [ "$_dl_sites" -eq "$_dl_expected" ]; then
  echo "PASS  deadline: the hook has exactly $_dl_sites _deadline call sites (1 segment loop + 3 token loops)"; pass=$((pass+1))
else
  echo "FAIL  deadline: _deadline call-site count changed (found $_dl_sites, expected $_dl_expected) — a new loop without a _deadline runs unbounded, and a removed one silently drops the bound on that phase. If the change is legitimate, raise the expected count deliberately"; fail=$((fail+1))
fi

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
# RETRIES is reported beside the result so latency drift is visible without
# reading the body: a suite that is green only because it re-ran rows is a
# different state from one that was green first time, and the difference is
# exactly the early warning that a rule has started racing the deadline.
echo "RETRIES: $retried deadline re-runs"
[ "$fail" = "0" ]
