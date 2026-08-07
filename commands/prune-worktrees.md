---
description: Detect and remove worktrees whose PR has merged — Radar confirms the tracker is Done, Hubert executes
argument-hint: [optional — "dry-run" to only report, or a specific worktree path to handle just that one]
---

Sweep `.claude/worktrees/` and `<git.worktreeRoot>` for worktrees that are safe to remove: PR merged,
tree clean, and (per {{ISSUE_KEY}}-418) the tied {{TEAM}} issue confirmed **Done**. This is the safety net for
worktrees the `/land` close-out never reached — crashed/interrupted sessions, work predating this
automation, or manually-created worktrees. `/land`'s own close-out already runs this same flow for the
worktree it just landed; this command is for everything else.

**Split — Radar confirms, Hubert executes.** Radar has no Bash/git access (tracker-only by design);
Hubert has Bash and already owns branch/worktree mechanics. Neither one guesses the other's job.

## Steps

1. **Detect (read-only):** run `tools/dev/prune-worktrees.sh detect` via Bash. Parse its categorized
   output:
   - `SAFE <path> <branch> <issue-id> <pr#>` — merged PR, clean tree, has a parseable {{ISSUE_KEY}}-N — candidate.
   - `DIRTY <path> <branch> <issue-id> <pr#>` — merged PR but uncommitted changes. **Never touch.**
     Report it so the operator can decide whether the WIP is worth salvaging.
   - `ACTIVE <path> <branch> <issue-id> <pr#> <state>` — PR open. Skip silently (this is the normal,
     expected majority case).
   - `ORPHAN <path> <branch> <issue-id>` — no PR found, or PR closed unmerged. **Never touch** — flag it;
     could be abandoned work or a branch that landed under a different name/PR.
   - `LOCKED <path> <branch> <issue-id>` — an active session holds this worktree (`git worktree lock`).
     **Never touch, don't even flag as noteworthy** — this is expected steady-state for any worktree
     currently in use, not a problem to report.
   - `DETACHED <path>` — no branch checked out. **Never touch** — flag it; needs a human look.
   - `UNKNOWN <path> <branch> <issue-id>` — the script couldn't read the worktree's git status (broken/
     stale registration). **Never touch** — flag it.
   - A `SAFE` line with `issue-id` of `-` (no `{{ISSUE_KEY}}-NNN` parseable from the branch name) can't be
     Radar-confirmed — treat it like `ORPHAN` and flag it instead of guessing.

2. **If there are no `SAFE` candidates:** report "nothing to prune" (plus any `DIRTY`/`ORPHAN` flags)
   and stop — don't dispatch Radar or Hubert for an empty batch.

3. **Radar confirms (background is fine — there's no downstream step until it returns):** dispatch the
   `radar` subagent with the list of `{{ISSUE_KEY}}-N` candidates and ask it to `get_issue` each one and report
   back which are in the **Done** state. Radar does not write anything here — this is a read-only
   check. **If `radar` isn't resolvable, STOP — do NOT fall back to a `general-purpose` agent.**
   Report the detect-phase results (including any `DIRTY` / `ORPHAN` / `LOCKED` flags) and say the
   `radar` agent needs registering, or that Done should be confirmed in the tracker by hand and the
   command re-run. **Do not proceed to step 4.** Stopping here is safe: every mutation in this flow
   lives in step 4, so a stop leaves the tree byte-identical and the command is a re-runnable sweep —
   the degraded outcome is "worktrees accumulate", not "work is lost".

   Why no fallback: `radar`'s containment is its `tools:` allowlist, and a `general-purpose`
   substitute "pointed at `.claude/agents/radar.md`" is bound by prose only — it holds Bash, Edit
   and Write, and it is being handed issue text nobody has vetted. It matters more here than
   elsewhere because this command's next step authorizes an **irreversible** `branch -D`.
   *(Scoped honestly: `prune-worktrees.sh`'s `cmd_remove` independently re-validates PR state
   `MERGED`, worktree HEAD **exactly** the merged commit, clean tree, not locked, and not
   self-targeting — so a wrong Done-confirmation cannot reach unmerged work; the worst reachable
   outcome is deleting a branch whose tip is already in `{{DEFAULT_BRANCH}}`. An earlier draft of this
   paragraph said "a wrong Done-confirmation deletes work", which the step-4 note nine lines below
   refutes. The containment argument must not rest on that second check alone — but it must not
   overstate the hazard either, in a file whose subject is inaccurate mechanism claims.)*
   *(Provenance: {{ISSUE_KEY}}-340 retired this fallback for `/issue`; **this file was missed until
   {{ISSUE_KEY}}-606**, so it was the last live instance rather than a re-removal.)*

4. **Hubert executes, one candidate at a time, only for Radar-Done-confirmed paths:** dispatch the
   `hubert` subagent (or run inline if you're already positioned to) with an **explicit destructive-op
   authorization** in the prompt — Hubert refuses `branch -D` without one — instructing it to run
   `tools/dev/prune-worktrees.sh remove <path>` for each confirmed candidate. The script re-validates
   merged+clean itself before acting, so this is defense in depth, not the only check.
   - Hubert's authorization has no independent enforcement (his `Bash` access isn't scoped to this
     script — the refusal-without-authorization is persona discipline, not a hard boundary). Since
     "Radar confirmed it" is otherwise just the orchestrator's unverifiable say-so, **quote Radar's
     literal returned state per {{ISSUE_KEY}}-N** (e.g. "Radar: {{ISSUE_KEY}}-296 → Done, via get_issue") in Hubert's
     prompt instead of a bare "Radar confirmed" claim — a thin paper trail beats none.
   - A candidate Radar does **not** confirm Done ({{ISSUE_KEY}}-N still open/in-review despite a merged PR) is
     left alone and reported as a mismatch worth a look — don't override Radar's read.

5. **Report** a summary: pruned (path/branch/{{ISSUE_KEY}}-N/PR#), left dirty (with reason), left orphaned (with
   reason), and any tracker-state mismatches Radar flagged. Mirror the STATUS line convention from
   the project's CLAUDE.md when this closes out actual task work.

## Input

`$ARGUMENTS`

- **empty** → the full sweep above.
- **`dry-run`** → steps 1–2 only (detect + categorize); report candidates without dispatching Radar or
  Hubert.
- **a specific worktree path** → run steps 1–4 for just that one path (still goes through the same
  Radar-confirm → Hubert-execute gate; this isn't a way to skip the safety checks).
