# agent-pr-flow

Portable ops bundle for an autonomous-agent PR workflow: the **$0 four-mechanism enforcement
stack** (no paid branch protection required), the **Radar** PM agent, the slash commands, and the
canonical workflow references — extracted from `endurance-logger` (bundle instance #1). Decision
lineage: ADR-0023 (trimmed GitHub Flow), ADR-0024 (parallel agent orchestration), ADR-0025
(mechanical gates + portable workflow); built as Slice 5 of the PM & Ops Cleanup plan (SAD-180).

The premise: `main` is PR-only and always deployable, every merge goes through one gated funnel,
and every gate that *can* be mechanical *is* — on a free-tier private repo where GitHub branch
protection isn't available.

## The four mechanisms

| # | Layer | Binds | File |
|---|---|---|---|
| 1 | Claude Code hooks | every agent Bash call, all sessions/worktrees (settings are committed, so worktrees inherit them) | `hooks/pre-bash-safety.sh` (D-rows: destructive-op guards; F-rows: branch-flow guards), `hooks/post-bash-secret-scan.sh` (advisory secret tripwire), `hooks/lint-on-edit.sh` (config-driven lint) |
| 2 | git pre-push hook | any local push, any terminal | `githooks/pre-push` (rejects updates to `refs/heads/main`) |
| 3 | The merge funnel | the merge itself | `scripts/land-pr.sh` (gates G0–G8: CI check, review tier, SHA-pinned verdict markers, deterministic `(#NN)` squash subject) |
| 4 | Server-side detector | after the fact, on every push to main | `ci/main-guard.yml` (every commit on main must be the squash commit of a merged PR — red run = a bypass happened) |

Plus the PM layer: `agents/radar.md` (background project-manager agent), `commands/`
(`/land`, `/issue`, `/linear-triage`), and `references/` (the canonical workflow +
Linear platform reference).

## Bundle contents → install destinations

```
install.sh                                  (stays in the bundle)
README.md                                   (stays in the bundle)
settings.fragment.json                      → merged into <repo>/.claude/settings.json
templates/workflow.config.example.json      → seeds <repo>/.claude/workflow.config.json (if absent)
hooks/pre-bash-safety.sh                    → .claude/hooks/pre-bash-safety.sh
hooks/post-bash-secret-scan.sh              → .claude/hooks/post-bash-secret-scan.sh
hooks/lint-on-edit.sh                       → .claude/hooks/lint-on-edit.sh
commands/land.md · issue.md ·
  linear-triage.md                          → .claude/commands/
agents/radar.md                             → .claude/agents/radar.md         (rendered)
references/workflow.md.tmpl                 → .claude/references/pm/workflow.md (rendered)
references/pm/linear.md.tmpl                → .claude/references/pm/linear.md   (rendered)
scripts/land-pr.sh · setup-repo.sh ·
  test-hooks.sh · test-land-pr.sh           → tools/dev/
githooks/pre-push                           → .githooks/pre-push
ci/main-guard.yml                           → .github/workflows/main-guard.yml
```

Artifacts are **copied, not symlinked** — they must be committed into the target so they
materialize in worktrees and clones (symlinks don't survive either).

## Install

Requirements: `bash`, `jq`, `git`, `gh` (authenticated, for the funnel + repo-settings checks).

```
bash install.sh --target <repo> [--config <workflow.config.json>] [--force]
```

1. **Copies** every bundle file to its destination (table above), creating directories as needed.
2. **Renders** `{{VAR}}` placeholders from the config in the files that carry them (`.tmpl` files
   lose the suffix; `agents/radar.md` is rendered in place). Variables:
   `{{TEAM}}` `{{PROJECT}}` `{{ISSUE_KEY}}` `{{MCP_PREFIX}}` `{{DEFAULT_BRANCH}}`
   `{{REQUIRED_CHECK}}`. **Every** missing config key is collected and the run fails listing them
   all — nothing is written on a render failure. With no `--config`, an existing
   `<repo>/.claude/workflow.config.json` is used.
3. **Merges** `settings.fragment.json` into the target's `.claude/settings.json` with
   `jq -s '.[0] * .[1]'` — the fragment's hook wiring wins on conflicts, every other user key is
   preserved. `settings.local.json` is **never** touched.
4. **Seeds** `.claude/workflow.config.json` from `--config` **only if absent** — an existing one
   is never overwritten, not even with `--force`.
5. **chmod +x** on hooks / githooks / scripts, then runs the target's `tools/dev/setup-repo.sh`
   (the idempotent repo doctor: wires `core.hooksPath`, verifies gh/jq, checks the GitHub merge
   settings, asserts the hook wiring) and propagates its exit status.

**Idempotency:** re-running is safe. Byte-identical targets report `skip (unchanged)`; a target
that differs from the bundle gets a unified **diff printed and is KEPT** (exit 1) — pass
`--force` to overwrite. After installing, **commit the installed files** in the target repo
(the enforcement only reaches worktrees/CI once committed).

Post-install, once per repo (GitHub console ops, not scriptable into the bundle):

```
gh repo edit --delete-branch-on-merge --enable-merge-commit=false --enable-rebase-merge=false
gh api -X PATCH "repos/{owner}/{repo}" -f squash_merge_commit_title=PR_TITLE -f squash_merge_commit_message=PR_BODY
```

`setup-repo.sh` verifies these and FAILs until they're set (WARN-only when the repo has no
origin remote yet).

## The config schema (`workflow.config.json`)

One JSON file per instance; `templates/workflow.config.example.json` is instance #1's
(endurance-logger's) real config. Key by key:

| Key | Feeds | Meaning |
|---|---|---|
| `tracker.platform` | docs | issue-tracker platform id (`linear`) |
| `tracker.mcpPrefix` | `{{MCP_PREFIX}}` | MCP tool-name prefix for the tracker (e.g. `mcp__claude_ai_Linear__`) |
| `tracker.team` | `{{TEAM}}` | tracker team name |
| `tracker.project` | `{{PROJECT}}` | tracker project name |
| `tracker.issueKey` | `{{ISSUE_KEY}}` | issue-key prefix (`SAD` → `SAD-123`) |
| `git.defaultBranch` | `{{DEFAULT_BRANCH}}` | the protected trunk (`main`) |
| `git.mergeMethod` | runtime | merge method for the funnel (`squash`) |
| `git.worktreeRoot` | docs | where per-issue worktrees live |
| `git.copyIntoWorktree` | docs | gitignored per-machine files each worktree needs copied in |
| `ci.requiredCheck` | `{{REQUIRED_CHECK}}` | exact check name land-pr.sh gate G2 requires `SUCCESS` on |
| `ci.localGate` | docs | the command an agent runs locally before pushing |
| `ci.lintOnEdit` | **runtime** — read by `lint-on-edit.sh` | lint command run on every Edit/Write (`$FILE` = edited file); `null` = fast no-op |
| `review.docsTierPatterns` | runtime | globs; a PR is docs-tier only if ALL files match → CI-alone gate |
| `review.securityTierPatterns` | runtime | globs; ANY match → security tier → CI + Watson + Barb (includes the self-protection set: settings, hooks, commands, githooks, the funnel scripts, `.mcp.json`, and the workflow config itself — `.claude/workflow.config.**`) |
| `review.verdicts.reviewer` | runtime | reviewer marker + passing verdict (`watson-verdict` / `APPROVE`) |
| `review.verdicts.security` | runtime | security marker + passing verdict (`barb-verdict` / `CLEARED`) |
| `agents.*` | docs / runtime | station → agent name; a `null` value disables that station's gate with a **loud WARN** in land-pr.sh |
| `verification.tiers` | docs | the two-tier verification model (parallel functional surface, serialized fidelity surface) |
| `docs.todoSnapshot` | docs | the ≤30-line status snapshot file |
| `docs.workflowRef` | docs | where the canonical workflow reference installs |
| `docs.historyDir` | docs | where retired long-form docs are archived |

**Tier precedence:** ANY security match → security; else ALL docs → docs; else code.
**Gate per tier:** docs = CI alone · code = CI + Watson · security = CI + Watson + Barb.

### Known limitation

As of Slice 6 (SAD-181), `land-pr.sh`, `pre-bash-safety.sh`, and `lint-on-edit.sh` read
`workflow.config.json` at runtime, so the scripts are copied into this bundle **verbatim** and are
generic for any instance that supplies its own config. They fall back to **hardcoded instance-#1
literals + a WARN** only when a key is absent — the fallbacks carry endurance-logger values (check
name "Build & unit test", the tier pattern lists incl. Android paths, trunk `main`). Per SAD-181
the config **overrides** every fallback, so a correctly-configured instance never hits one; the
fallbacks only surface if an instance ships no `workflow.config.json` at all (then the bundle is
turnkey for repos that share endurance-logger's conventions and mis-gates otherwise). The
`.md`/`.tmpl` surfaces are fully rendered from config at install time.

### Known limitation — F1 `gh pr merge` arg-grammar mirror

- `pre-bash-safety.sh`'s F1 guard walks the `gh pr merge` tokens and skips each value-taking flag's
  value so a PR URL sitting in a `--body` (etc.) isn't mistaken for the merge target. That
  value-taking-flag list
  (`-b|--body|-t|--subject|-F|--body-file|--match-head-commit|-R|--repo|--author-email`) is a
  **static mirror** of `gh pr merge`'s grammar and must be updated if a future `gh` adds a
  value-taking merge flag — otherwise the un-listed flag's value is read as a positional and can
  over-block (fail-safe: it errs toward blocking a merge, never toward letting a raw one through).
  Raised as a non-blocking FYI by Watson and Barb in the SAD-257 review; the bundle scripts are kept
  **byte-identical** to the endurance-logger source, so this lives here rather than as an inline
  code comment.

## What is mechanical vs what stays convention

**Mechanical (a bypass is blocked or detected):**
- Agent Bash: destructive ops (D-rows), inline escape-hatch assignments (D0), hook-evasion
  signals (F6), raw `gh pr merge` (F1), any push/commit path that moves the trunk (F2–F5).
- Any local terminal: `.githooks/pre-push` rejects trunk pushes (`--no-verify` skips it — a git
  invariant — but F6 blocks agents from using that flag, and mechanism 4 catches the rest).
- The merge: `land-pr.sh` runs all gates before its internal merge (the "funnel trick": hooks see
  only top-level Bash commands, so the script's internal `gh pr merge` is invisible — deny-rules
  need no allowlist).
- After the fact: `main-guard.yml` goes red on any commit that didn't land as a merged PR's
  squash commit.

**Convention (not enforced by machinery):**
- Verdict comments are agent-authored and spoofable in principle — the G8 audit-trail URLs are
  the $0 mitigation.
- A human running `gh pr merge` in their own terminal is ungated (the hooks bind agent Bash, not
  human shells).
- Review quality itself: the gate checks that a SHA-pinned verdict exists, not that it's right.

## Escape hatches — Jason-only (repo-owner-only)

`SKIP_BASH_SAFETY=1` (bypass the whole Bash gate) · `ALLOW_DESTRUCTIVE=1` (D1/D2/D6) ·
`ALLOW_MAIN_PUSH=1` (F2/F3/F4 + pre-push) · `ADB_NO_SERIAL_OK=1` (D5). They work **only as
ambient env in the shell that launched the session** — the hooks read their own environment, so
an inline `VAR=1 cmd` never reaches them and is itself blocked outright (D0). F1 (raw
`gh pr merge`) and F5 (trunk deletion) have **no** escape hatch. Agents never set these;
false positives are remediated by authoring content with Write/Edit tools instead of Bash
heredocs (see `references/workflow.md.tmpl` §6).

## Verifying the hooks

`scripts/test-hooks.sh` (installs to `tools/dev/test-hooks.sh`) is the committed regression
table: it feeds synthetic hook payloads to the scripts and asserts exit codes — ~120 cases
covering the D/F/W rules, quoting/prefix normalization bypasses, refspec spellings, and the
secret-scan patterns. Run it after ANY hook edit; no command in its table is ever executed.

`scripts/test-land-pr.sh` (installs to `tools/dev/test-land-pr.sh`) is the companion
tier-classification regression (SAD-181): it drives `land-pr.sh`'s hidden self-test mode over
every tracked path plus an adversarial near-miss set and asserts the **config-driven** and
**hardcoded-fallback** classifiers agree exactly, and that the self-protection paths
(`.claude/workflow.config.json`, `tools/dev/land-pr.sh`) resolve to the **security** tier. Run it
after ANY change to the tier patterns or `land-pr.sh`'s tier logic.

## Uninstall

No uninstaller ships; removal is the mirror image of install:

1. Delete the installed files: `.claude/hooks/{pre-bash-safety,post-bash-secret-scan,lint-on-edit}.sh`,
   `.claude/commands/{land,issue,linear-triage}.md`, `.claude/agents/radar.md`,
   `.claude/references/pm/{workflow,linear}.md`, `tools/dev/{land-pr,setup-repo,test-hooks}.sh`,
   `.githooks/pre-push`, `.github/workflows/main-guard.yml`, `.claude/workflow.config.json`.
2. Remove the bundle's keys from `.claude/settings.json`: the three hook entries under
   `hooks.PreToolUse` / `hooks.PostToolUse` (delete the whole `hooks` key if the bundle added it)
   and `enabledMcpjsonServers` if the fragment introduced it. Leave every other key alone;
   `settings.local.json` was never touched.
3. `git config --unset core.hooksPath` and (optionally) `git config --unset fetch.prune`.
4. Revert the GitHub console ops only if you want the old merge behavior back
   (`gh repo edit --enable-merge-commit` etc.).
5. Commit the removals in the target repo.
