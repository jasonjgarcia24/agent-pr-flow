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

t() { # $1=case name  $2=expected rc  $3=command  [$4=extra env "K=V [K=V...]"]  [$5=cwd]
  # extra comes AFTER the default CLAUDE_PROJECT_DIR so tests can override the
  # project scope (SAD-181 repo-scoped F-rows); deliberate word-split.
  local name="$1" expect="$2" cmd="$3" extra="${4:-}" cwd="${5:-$ROOT}"
  local rc out
  if [ -n "$extra" ]; then
    # shellcheck disable=SC2086 # word-splitting multiple K=V assignments is the point
    out=$(mk "$cmd" "$cwd" | env CLAUDE_PROJECT_DIR="$ROOT" $extra bash "$H/pre-bash-safety.sh" 2>&1); rc=$?
  else
    out=$(mk "$cmd" "$cwd" | env CLAUDE_PROJECT_DIR="$ROOT" bash "$H/pre-bash-safety.sh" 2>&1); rc=$?
  fi
  if [ "$rc" = "$expect" ]; then
    echo "PASS  $name (rc=$rc)"; pass=$((pass+1))
  else
    echo "FAIL  $name (rc=$rc expected=$expect) :: $out"; fail=$((fail+1))
  fi
}

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
[ "$fail" = "0" ]
