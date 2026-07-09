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
     (the GitHub integration usually drives it off the `Fixes SAD-N` body; Radar's pass
     is idempotent verification).
   - Walk the remaining close-out surfaces (todo snapshot line; R-ID iff a quality bar
     moved; ADR/spec-row iff architectural) per `.claude/references/pm/workflow.md` §7.
   - Remove the branch's worktree if one exists (`git worktree remove <path>`).
