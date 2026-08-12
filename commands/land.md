---
description: Land a PR through the gated merge funnel (tools/dev/land-pr.sh)
argument-hint: <PR number>
---

Run the merge funnel for PR **$ARGUMENTS**:

1. Execute `tools/dev/land-pr.sh $ARGUMENTS` via Bash and show its output.
2. **If any gate FAILS: report the failure output verbatim and STOP.** Do not merge
   another way — raw `gh pr merge` is hook-blocked (pre-bash-safety F1) and delegating
   a bypass to a subagent is still a bypass. Specifically:
   - G2 (CI) failure → investigate the run, fix on the branch, push, re-run `/land`.
   - G4 (verdicts) failure → request a FRESH Watson (and Barb, if security-tier) review
     of the **current head SHA**, post the new marker comment, re-run `/land`. Never
     work around a stale/missing verdict.
3. On success, run the close-out the script prints:
   - Fire **Radar** as a background agent to verify the Linear issue reached **Done**
     (the GitHub integration usually drives it off the `Fixes {{ISSUE_KEY}}-N` body; Radar's pass
     is idempotent verification).
   - Walk the remaining close-out surfaces (todo snapshot line; R-ID iff a quality bar
     moved; ADR/spec-row iff architectural) per `.claude/references/pm/workflow.md` §7.
   - **Worktree ({{ISSUE_KEY}}-418):** if the branch has one, remove it via the same split
     `/prune-worktrees` uses — Radar confirms the {{ISSUE_KEY}}-N reached Done, then Hubert (with
     explicit destructive-op authorization, quoting Radar's literal returned state) runs
     `tools/dev/prune-worktrees.sh remove <path>`. Don't hand-run `git worktree remove`
     here; this is the step that used to get silently skipped (see
     `.claude/commands/prune-worktrees.md` for the full flow — it also catches anything
     this misses). **You're almost always removing your OWN worktree here** — the script
     refuses self-removal (cwd inside the target path), so run it from the primary
     checkout or another worktree, not from the one being removed.
   - **If `tools/dev/prune-worktrees.sh` is missing, the step is NOT done.** The bundle
     installs it, so it should be there; a partial or hand-rolled install is the only way
     it isn't. In that case do the removal by hand — confirm the PR is MERGED and the
     worktree clean, then `git worktree remove <path>` + `git branch -d <branch>` — and
     **say in your report that you fell back**. "The script wasn't there" is never a
     reason to treat the worktree as cleaned up; a silently skipped close-out step is the
     exact failure {{ISSUE_KEY}}-418 was filed about.
