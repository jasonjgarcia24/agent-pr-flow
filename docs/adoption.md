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
bash install.sh --target /path/to/your-repo --config your-workflow.config.json [--force] [--clobber-local]

# preview first — classifies the whole manifest, writes nothing, skips the doctor:
bash install.sh --target /path/to/your-repo --config your-workflow.config.json --check
```

`install.sh`:

1. **Copies** every bundle artifact to its destination (table below), creating directories as
   needed. Artifacts are **copied, not symlinked** — they must be committed into the target so they
   materialize in worktrees, clones, and CI (symlinks survive none of those).
2. **Renders** `{{VAR}}` placeholders from the config in the files that carry them. Every missing
   config key is collected and the run **fails listing them all** — nothing is written on a render
   failure. Variables: `{{TEAM}}` `{{PROJECT}}` `{{ISSUE_KEY}}` `{{MCP_PREFIX}}` `{{DEFAULT_BRANCH}}`
   `{{REQUIRED_CHECK}}` `{{CODE_TIER_POLICY}}`.
3. **Merges** `settings.fragment.json` into the target's `.claude/settings.json` (`jq -s '.[0] * .[1]'`
   — the fragment's hook wiring wins on conflicts, every other key is preserved). `settings.local.json`
   is **never** touched.
4. **Seeds** `.claude/workflow.config.json` from `--config` **only if absent** — an existing config
   is never overwritten, not even with `--force`.
5. **chmod +x** on the hooks/githooks/scripts, then runs the target's `tools/dev/setup-repo.sh` and
   propagates its exit status.

### Config values are validated — plan your team and project names

`install.sh` substitutes seven config values into shipped files, and several of those files
are read by agents as **instructions** (`agents/radar.md`, `commands/issue.md`,
`references/pm/linear.md`). Values are therefore validated at install time and a bad one
**aborts the install with nothing written** — it does not warn and continue.

| Key | Allowed |
|---|---|
| `tracker.issueKey` | `A-Z a-z 0-9 _` — non-empty |
| `tracker.mcpPrefix` | `A-Z a-z 0-9 _` |
| `git.defaultBranch` | `A-Z a-z 0-9 . _ / -` |
| `tracker.team`, `tracker.project` | `A-Z a-z 0-9`, space, `.` `_` `-` — **max 48 characters** |
| `ci.requiredCheck` | any single line without quotes, backslash, backtick or `$` |

**Team and project names are the constrained ones, and it is worth knowing before you start.**
`Core Platform (EU)`, `R&D` and `Frontend/Backend` are rejected — parentheses, ampersands and
slashes are not in the set, and neither is non-ASCII. Rename to `Core Platform EU`, `R and D`,
`Frontend-Backend`. The install fails loudly and names the allowed set, so you will not be
guessing; this is here so you meet the constraint as documentation rather than as a failed run.

**Why the restriction exists.** These two values render into files an agent reads as
instructions, so the risk is not shell injection but *prompt* injection. They are additionally
rendered inside backticks at every site so the value parses as a literal name, and the charset
excludes the backtick so a value cannot close the span it sits in. Excluding non-ASCII is
deliberate: homoglyph and bidi-override characters read as innocuous to a human reviewer and
behave differently to a model.

⚠ **The charset and length limits do not, and cannot, fully close prompt injection** — a short
imperative fits comfortably within any charset that also admits real project names. They close
shell breakout and comment termination, which they do provably. The honest boundary: a config
you wrote yourself is in your own trust boundary, since you could edit `agents/radar.md`
directly anyway. The case these guards exist for is running `--config` against **a config you
did not write**. Treat a third-party config as untrusted input and read it first.

**Idempotency:** re-running is safe. Byte-identical targets report `skip (unchanged)`; a target that
differs gets a unified diff printed and is **kept** (exit 1) — pass `--force` to overwrite.

### `--force` will not silently revert your repo

`--force` is not a blind overwrite. Bundle-managed files drift in **two** directions, and only one
of them is an update:

- the **bundle** moved ahead — you edited it upstream and want it installed; or
- the **target** moved ahead — someone edited the installed copy and never ported it up. Here the
  bundle copy is *older*, and installing it is a **revert**.

This bit for real: on 2026-07-30 a routine `--force` install silently reverted five files that had
drifted ahead in the target, and the run still reported success. It was caught only because a human
read `git status` before committing.

So before overwriting a differing file, `install.sh` asks **the target repo's own git history** which
direction the drift runs:

| class | meaning | with `--force` |
|---|---|---|
| `forward` | the target's content **is in the bundle's history** — the bundle genuinely moved on from it | overwritten |
| `ahead` | the bundle's content is **already in the target's history** for that path — installing it would revert work | **REFUSED** |
| `diverged` | **neither** side's content is in the other's history — both moved on independently | **REFUSED** |
| `dirty` | the target file has uncommitted changes (recoverable from nothing) | **REFUSED** |
| `unknown` | no target git repo, no **bundle** git, or the path was never committed | overwritten, **counted, and reported in the final summary** |

A refusal exits non-zero and changes nothing. **The fix for `ahead` and `diverged` is to port the
target's version up to the bundle**, then re-install — that is the direction the bundle-ownership
rule requires anyway. `--force --clobber-local` overrides the refusals and **discards** the target's
version; use it only when you mean to throw that work away.

`diverged` is the case that is easy to miss. "The bundle's content isn't in the target's history"
does **not** by itself mean the bundle is newer — both sides may carry unique work, and overwriting
still drops the target's half. So a fast-forward is confirmed *positively*, from the bundle's history,
rather than inferred from the absence of evidence. This was not hypothetical: the reference instance
had exactly one such file (`tools/dev/land-pr.sh`), and a one-directional check called it safe.

**Templated sources are checked too, and getting this wrong was a fail-open.** A templated source
stores `{{VAR}}` in bundle history while the target stores *rendered* bytes, so raw blobs can never
match. An earlier cut therefore skipped the check for them and let `forward` stand — which silently
clobbered local work with exit 0 and an ordinary-looking `overwrite` line. The mitigation claimed at
the time ("the `ahead` check still covers them") was **false**: `ahead` needs today's render to exist
verbatim as a past commit, which a squash-merge repo defeats (install and local edit arrive in one
commit) and which *any* config change defeats for every templated file at once. Two of the five files
in the original incident were templated. So each historical bundle version is now **rendered through
the same substitution** and compared against the target's bytes.

**Changing a config value is not drift, and is not treated as such.** A templated target file holds
bytes rendered from whatever the config said *at install time*, so comparing only against today's
values would make every templated file stop matching the moment anyone flips a documented knob —
reporting `diverged` for all of them at once, with a remedy ("port the target's changes up") that
cannot be acted on because there is nothing to port. The target's own history carries the configs it
was rendered under, so historical bundle versions are rendered under **each** of them (current plus
up to 50 historical, deduplicated).

**The limits that remain, stated plainly:** divergence detection needs the bundle to be a git
checkout — from an unpacked tarball it degrades to `unknown` (overwrite + a counted WARN), never to a
silent `forward`. History scans are bounded at 1000 commits per path and use `--full-history`, so
merge simplification cannot prune the commit that would have proven the direction. A config value
that was changed *without* being committed to the target is not recoverable from history, so a
templated file rendered under it reads as `diverged`.

**A refusal is atomic.** If any file is refused, *nothing* is installed — not even the files that
would have been fine — so a blocked run can never leave the target half-updated. Anything overwritten
without proof is counted and reported in the final summary, not just warned about inline where a
15-file run would scroll it away.

No state file, receipt, or bootstrap step is involved — the signal is the two repos' own histories, so
this works on the first run in a fresh clone or worktree. Regression suite: `scripts/test-install.sh`.

**Carve-out:** `.claude/settings.json` is a jq *merge*, not a copy, and is deliberately not
drift-classified — the merge preserves every target-only key by construction.

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

Three regression suites. **Two of them run from an INSTALLED repo, not from the bundle** — they
assert on `.claude/hooks/*` and `tools/dev/*`, so run from a bundle clone they fail every case with
"No such file or directory". Install into a scratch target first (that is also what the bundle's own
CI does, and it doubles as proof the manifest is complete):

- **`test-install.sh`** — runs from the **bundle repo** (`bash scripts/test-install.sh`). Drives
  install.sh's drift classification: ahead / diverged / dirty / forward / unknown, the atomicity of a
  refusal, `--dry-run`'s inertness, `review.codeTierPolicy` validation, and that every artifact the
  shipped commands reference actually installs.
- **`test-hooks.sh`** (installed to `tools/dev/`) — feeds synthetic hook payloads to the safety hooks
  and asserts exit codes across the D/F/W rules, quoting/prefix-normalization bypasses, refspec
  spellings, and the secret patterns. No command in its table is ever executed. Run it after any hook
  edit.
- **`test-land-pr.sh`** (installed to `tools/dev/`) — drives the funnel's self-test mode over every
  tracked path plus a fixed adversarial near-miss set, and asserts the config-driven and fallback
  tier classifiers agree exactly and that the self-protection paths resolve to the security tier. Run
  it after any change to the tier patterns or the funnel's tier logic.

```bash
bash scripts/test-install.sh                       # from the bundle repo

T=$(mktemp -d); git -C "$T" init -q                # then, for the other two:
bash install.sh --target "$T" --config templates/workflow.config.example.json
( cd "$T" && bash tools/dev/test-hooks.sh && bash tools/dev/test-land-pr.sh )
```

**Preview an install before running it:** `install.sh --target <repo> --check` classifies the whole
manifest, prints what each entry would do, and writes nothing. Worth doing on any target that has
been edited locally — because a refusal is atomic, one AHEAD file blocks the entire install, and
`--check` is the only way to see all of them in one pass rather than one re-run at a time.

A live smoke test is simply: from an agent session, run a raw `gh pr merge` (should be blocked by
F1), a push to the trunk (blocked by F2 / pre-push), and a benign command (should pass) — the block
messages confirm the hooks are wired.

## Uninstall

No uninstaller ships; removal is the mirror image of install:

1. Delete the installed files: `.claude/hooks/*.sh`,
   `.claude/commands/{land,issue,linear-triage,prune-worktrees,laymans}.md`,
   `.claude/agents/radar.md`, `.claude/references/pm/{workflow,linear}.md`,
   `tools/dev/{land-pr,prune-worktrees,setup-repo,test-hooks,test-land-pr}.sh`,
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
