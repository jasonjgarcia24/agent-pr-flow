# Adoption guide

How to install agent-pr-flow into your own repo, configure it, verify it, and remove it. If you
want the *why* first, read [architecture.md](architecture.md); for the *process* it enforces, read
[workflow.md](workflow.md).

> **Before you install, know what it does.** This bundle installs hooks that **intercept every
> agent shell command and every file edit** in the target repo, wires a git pre-push hook, merges
> hook config into your Claude settings, and runs a repo-doctor script. That's the whole point — the
> enforcement has to bind those surfaces to work — but it's active machinery, not passive files.
> Read the scripts you're installing (they're short, commented, and shellcheck-clean), then adopt.

## Requirements

`bash`, `jq`, `git`, and an authenticated `gh` CLI (needed by the funnel and the repo-settings
checks). The workflow assumes a GitHub repo with a CI workflow that publishes a named required
check, and a Claude Code environment (the hooks are Claude Code `PreToolUse`/`PostToolUse` hooks).

## Install

```bash
bash install.sh --target /path/to/your-repo --config your-workflow.config.json [--force]
```

`install.sh`:

1. **Copies** every bundle artifact to its destination (table below), creating directories as
   needed. Artifacts are **copied, not symlinked** — they must be committed into the target so they
   materialize in worktrees, clones, and CI (symlinks survive none of those).
2. **Renders** `{{VAR}}` placeholders from the config in the files that carry them. Every missing
   config key is collected and the run **fails listing them all** — nothing is written on a render
   failure. Variables: `{{TEAM}}` `{{PROJECT}}` `{{ISSUE_KEY}}` `{{MCP_PREFIX}}` `{{DEFAULT_BRANCH}}`
   `{{REQUIRED_CHECK}}`.
3. **Merges** `settings.fragment.json` into the target's `.claude/settings.json` (`jq -s '.[0] * .[1]'`
   — the fragment's hook wiring wins on conflicts, every other key is preserved). `settings.local.json`
   is **never** touched.
4. **Seeds** `.claude/workflow.config.json` from `--config` **only if absent** — an existing config
   is never overwritten, not even with `--force`.
5. **chmod +x** on the hooks/githooks/scripts, then runs the target's `tools/dev/setup-repo.sh` and
   propagates its exit status.

**Idempotency:** re-running is safe. Byte-identical targets report `skip (unchanged)`; a target that
differs gets a unified diff printed and is **kept** (exit 1) — pass `--force` to overwrite.

### Where each artifact installs

```
settings.fragment.json                 → merged into <repo>/.claude/settings.json
templates/workflow.config.example.json → seeds <repo>/.claude/workflow.config.json (if absent)
hooks/*.sh                             → .claude/hooks/
commands/*.md                          → .claude/commands/
agents/radar.md                        → .claude/agents/radar.md            (rendered in place)
references/workflow.md.tmpl            → .claude/references/pm/workflow.md   (rendered)
references/pm/linear.md.tmpl           → .claude/references/pm/linear.md     (rendered)
scripts/*.sh                           → tools/dev/
githooks/pre-push                      → .githooks/pre-push
ci/main-guard.yml                      → .github/workflows/main-guard.yml
```

### After installing

Commit the installed files (the enforcement only reaches worktrees and CI once committed), then
apply the one-time repo settings the doctor checks for — GitHub console ops that can't be scripted
into the bundle:

```bash
gh repo edit --delete-branch-on-merge --enable-merge-commit=false --enable-rebase-merge=false
gh api -X PATCH "repos/{owner}/{repo}" -f squash_merge_commit_title=PR_TITLE -f squash_merge_commit_message=PR_BODY
```

`setup-repo.sh` verifies these and fails until they're set (warn-only when the repo has no origin
remote yet). These make squash the only merge method and make the squash subject default to the PR
title — the source of the deterministic `(#NN)` traceability.

## Configure — `workflow.config.json`

One JSON file per instance parameterizes everything. `templates/workflow.config.example.json` is the
reference instance's real config; copy and edit it. Key by key:

| Key | Feeds | Meaning |
|---|---|---|
| `tracker.platform` | docs | issue-tracker platform id (e.g. `linear`) |
| `tracker.mcpPrefix` | `{{MCP_PREFIX}}` | MCP tool-name prefix for the tracker |
| `tracker.team` / `tracker.project` | `{{TEAM}}` / `{{PROJECT}}` | tracker team / project |
| `tracker.issueKey` | `{{ISSUE_KEY}}` | issue-key prefix (`SAD` → `SAD-123`) |
| `git.defaultBranch` | `{{DEFAULT_BRANCH}}` + runtime | the protected trunk |
| `git.mergeMethod` | runtime | funnel merge method (`squash`) |
| `git.worktreeRoot` | docs | where per-issue worktrees live |
| `git.copyIntoWorktree` | docs | gitignored per-machine files each worktree needs |
| `ci.requiredCheck` | `{{REQUIRED_CHECK}}` + runtime | exact check name the funnel's G2 requires `SUCCESS` |
| `ci.localGate` | docs | the command an agent runs locally before pushing |
| `ci.lintOnEdit` | runtime (`lint-on-edit.sh`) | lint command per Edit/Write (`$FILE` = edited file); `null` = no-op |
| `review.docsTierPatterns` | runtime | globs; a PR is docs-tier only if ALL files match |
| `review.securityTierPatterns` | runtime | globs; ANY match → security tier. Include the **self-protection set**: settings, hooks, commands, githooks, the funnel scripts, and the config file itself (`.claude/workflow.config.**`) |
| `review.verdicts.reviewer` | runtime | reviewer marker + passing verdict (e.g. `watson-verdict` / `APPROVE`) |
| `review.verdicts.security` | runtime | security marker + passing verdict (e.g. `barb-verdict` / `CLEARED`) |
| `agents.*` | docs / runtime | station → agent name; `null` disables that station's gate with a loud WARN |
| `verification.tiers` | docs | the two-tier verification model (parallel functional / serial fidelity) |
| `docs.todoSnapshot` / `docs.workflowRef` / `docs.historyDir` | docs | doc locations |

**Tier precedence:** ANY security match → security; else ALL docs → docs; else code.
**Gate per tier:** docs = CI alone · code = CI + reviewer · security = CI + reviewer + security auditor.

The scripts read the config at runtime and fall back to **hardcoded reference-instance literals + a
loud WARN** only when a key is absent — so a fully-configured instance never touches a fallback, and
a mis-configured one is loud rather than silently wrong.

## Verify

Two committed regression suites (installed to `tools/dev/`):

- **`test-hooks.sh`** — feeds synthetic hook payloads to the safety hooks and asserts exit codes
  across the D/F/W rules, quoting/prefix-normalization bypasses, refspec spellings, and the secret
  patterns. No command in its table is ever executed. Run it after any hook edit.
- **`test-land-pr.sh`** — drives the funnel's self-test mode over every tracked path plus an
  adversarial near-miss set and asserts the config-driven and fallback tier classifiers agree
  exactly, and that the self-protection paths resolve to the security tier. Run it after any change
  to the tier patterns or the funnel's tier logic.

A live smoke test is simply: from an agent session, run a raw `gh pr merge` (should be blocked by
F1), a push to the trunk (blocked by F2 / pre-push), and a benign command (should pass) — the block
messages confirm the hooks are wired.

## Uninstall

No uninstaller ships; removal is the mirror image of install:

1. Delete the installed files: `.claude/hooks/*.sh`, `.claude/commands/{land,issue,linear-triage}.md`,
   `.claude/agents/radar.md`, `.claude/references/pm/{workflow,linear}.md`, `tools/dev/{land-pr,setup-repo,test-hooks,test-land-pr}.sh`,
   `.githooks/pre-push`, `.github/workflows/main-guard.yml`, `.claude/workflow.config.json`.
2. Remove the bundle's keys from `.claude/settings.json` (the hook wiring under
   `hooks.PreToolUse`/`hooks.PostToolUse`, and `enabledMcpjsonServers` if the fragment added it).
   Leave every other key alone; `settings.local.json` was never touched.
3. `git config --unset core.hooksPath` (and optionally `fetch.prune`).
4. Revert the GitHub console ops only if you want the old merge behavior back.
5. Commit the removals.

## Known limitations

- **Reference-instance fallbacks.** The runtime scripts carry the reference project's values (an
  Android trunk named `main`, its tier patterns, its CI check name) as fallbacks. A correct
  `workflow.config.json` overrides every one; the fallbacks only surface for a repo that ships no
  config at all (then the bundle is turnkey only if it happens to share those conventions).
- **F1 `gh pr merge` arg-grammar mirror.** The funnel guard walks `gh pr merge`'s tokens and skips
  each value-taking flag's value so a PR URL in a `--body` isn't mistaken for the merge target. That
  flag list is a static mirror of `gh`'s grammar and must be updated if a future `gh` adds a
  value-taking merge flag (otherwise it over-blocks — fail-safe, never toward letting a raw merge
  through).
- **Whitespace-obfuscation evasion.** The common shell field-separator forms (`${IFS}`, its
  `%`-suffix parameter-expansion variant, and the unbraced `$IFS`) **and empty-expansion glue**
  (empty-positional params `$1`–`$9`/`$@`/`$*` used to join a keyword to an adjacent token, including
  an `$IFS` re-glued through an empty quote) are normalized to a space before the rules run, so those
  specific tricks no longer slip the Bash gate (SAD-258, SAD-357). Arbitrary obfuscation beyond these
  forms — or simply splitting a command across two separate Bash calls — remains the accepted threat
  boundary: a determined agent is out of scope by design, and `main-guard` is the server-side
  backstop. See the threat model in
  [architecture.md](architecture.md#threat-model--what-this-defends-against).
- **In-tree git hooks + untrusted branches.** `setup-repo.sh` points `core.hooksPath` at the
  in-tree `.githooks/` directory, so whatever `pre-push` exists on the *currently checked-out
  branch* runs on plain git operations. That's safe when every branch is authored by people you
  trust. If you accept forks or run untrusted contributor branches, **review `.githooks/` before
  checking one out** — a hostile branch could otherwise run its own hook on your machine at
  `git push`. This is an inherent tradeoff of in-tree hooks, not specific to this bundle.
