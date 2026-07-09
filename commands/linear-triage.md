---
description: Sweep the Linear Triage queue + project-less feedback issues via Radar, for the current repo's Linear project
argument-hint: [optional — "dry-run" to report without writing, or a specific issue id to triage just that one]
---

Kick off the **Radar** PM agent to run the **project-hygiene / Triage sweep** for **this repo's**
Linear project. This is the safety net for feedback-pipeline issues: the GitHub↔Linear sync maps a
repo → *team*, not → *project*, so app-submitted bug/idea reports arrive in the **Triage** queue
with **no project**. Radar catches them and stamps the repo's project.

**Project-agnostic — resolve the target from THIS repo, never hardcode.** The Linear **team**,
**project**, and issue-key prefix all come from the invoking repo's PM reference, so this same
command works in any repo that follows the convention.

## Dispatch
Launch the **`radar`** subagent (per the orchestrator model, PM work runs as a subagent — never do
the Linear writes inline). If `radar` isn't resolvable as a subagent type, launch a
`general-purpose` agent with the SAME brief and point it at `.claude/agents/radar.md` as its
charter. Then **relay Radar's before → after report** to the user.

## Brief to hand Radar
> **First, resolve the target from THIS repo — do not assume any team/project name.** `Read`
> `.claude/references/pm/linear.md` (the repo's Linear PM reference); take the **team**, **project**,
> and **issue-key prefix** from it (e.g. its "Team · Project · Issue key" line), and follow its
> **"Project-hygiene sweep"** section for the state semantics + the never-move-to-Done rule. If that
> reference is absent or doesn't declare a Linear team + project, **STOP and report that this repo
> has no Linear PM config** — do not guess a team/project. Otherwise:
> 1. `list_issues` for the resolved **team**, filtered to the **Triage** state AND/OR **no project**.
> 2. For each, note: identifier · title · current project (or "none") · current priority · current
>    labels (incl. whether a `size:*` label is present) · whether it's a feedback / GitHub-synced
>    issue (a GitHub attachment, or a "reported via … feedback" note in the body).
> 3. For each that clearly belongs to this repo's app (all feedback-pipeline ones do): `save_issue`
>    with **`project=<the repo's project>`**, and if it's sitting in **Triage** accept it out by
>    moving state → **Backlog**. **Never move to Done** — a two-way GitHub sync could close the
>    linked GitHub issue.
> 4. **Also normalize priority + size on the same `save_issue` call** — do NOT leave them blank.
>    Read the title + body and apply the reference's "Filing a new issue" defaults/heuristics:
>    priority defaults to `4` Low (bump to High/Medium only for a clear crash/data-loss/core-flow
>    severity); size is a best-effort `size:S/M/L/XL` estimate from what the report is actually
>    asking for (a terse ask can still be `size:M`+ if the underlying feature is substantial — judge
>    by scope, not by report length). Leave the type label as synced from GitHub; only priority +
>    size are Radar's addition. This is the same classification `/issue` does for every other filed
>    issue — feedback-pipeline issues get no less complete a treatment.
> 5. Genuinely-ambiguous / off-project items **stay in Triage** — flag them, don't guess (this
>    ambiguity is about project OWNERSHIP, not about priority/size — sizing an issue you've already
>    confirmed belongs here is not the same judgment call, and should not be skipped).
> 6. Confirm each change with a fresh `get_issue`, and report a concise **before → after** per item
>    (identifier · title · project `none → <project>` · state `Triage → Backlog` · priority
>    `No priority → <level>` · size `— → size:X`).

## Input
$ARGUMENTS

- **empty** → the full sweep above.
- **`dry-run`** (or `report`) → Radar only LISTS what's in Triage / project-less and what it WOULD
  change — **no writes**.
- **a specific issue id** → triage just that one issue.

## Report
Relay Radar's outcome: which issues it caught, the project/state/priority/size changes it made, and
anything left in Triage (with the reason). If the queue is empty, say **"Triage clear — nothing to
sweep."** If the repo has no Linear PM reference, relay that instead.

## Pre-flight
Radar needs the claude.ai Linear MCP authed this session (the CRUD tools, not just the auth
handshake). If Radar reports it only has `Read`/`Grep`, ask the user to run `/mcp` → "claude.ai
Linear" once, then re-run.

Scope guard: this command only triages Linear issues (assign project + accept-from-Triage). Do
**not** edit code/docs, and do **not** push.
