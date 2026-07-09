---
description: Record a bug / task / field-finding as a Linear issue (Sadiga › Endurance Logger)
argument-hint: [what to record — a bug, task, or finding; omit to capture from recent chat]
allowed-tools: mcp__claude_ai_Linear__list_issues, mcp__claude_ai_Linear__get_issue, mcp__claude_ai_Linear__save_issue, mcp__claude_ai_Linear__save_comment, mcp__claude_ai_Linear__list_issue_labels, Grep, Read
---

File a Linear issue in the **Sadiga** team / **Endurance Logger** project for the item(s) below.

**First, `Read` `.claude/references/pm/linear.md`** — it is the source of truth for the field
conventions (priority mapping, label taxonomy, state rules, relationship-wiring + the
archived-relation gotcha, the `SAD-N`-only referencing rule). Follow its **"Filing a new issue"**
section. This command only adds the entry-point flow below (dup-check → classify → file → render).

The Linear tools are deferred MCP tools; ToolSearch them if not loaded (e.g.
`select:mcp__claude_ai_Linear__save_issue,mcp__claude_ai_Linear__list_issues`).

## Input
$ARGUMENTS

If empty, scan the **recent conversation** for untracked bugs/tasks/field findings — list the
candidates and ask Jason to confirm/trim **before** filing. One item → one issue; several distinct
items → one issue each.

## For each candidate
1. **Duplicate check (always).** `list_issues project="Endurance Logger" query="<keywords>"` with a
   couple of keyword variants; `get_issue` any plausible hit. Then classify:
   - **No match** → file it (per the reference).
   - **Clear dup, nothing new** → don't file; report `Duplicate of SAD-N`.
   - **Same issue + new info** (new repro, "still happening", a different R-ID) → don't file;
     `save_comment` the dated context on the existing `SAD-N`.
   - **Genuinely ambiguous** → ask Jason before acting.
2. **File** (only if no dup) with `save_issue`, `team="Sadiga"` + `project="Endurance Logger"`,
   setting title / priority / labels / body / relationships / state **per the reference's filing
   convention**. Verify any relation stuck (`get_issue includeRelations=true`) — relations no-op
   against archived targets.

## Report
For each candidate, one of:
- **Filed** — `SAD-N` + URL, then the **full issue content rendered inline** so it's readable
  without opening Linear:
  ```
  ### SAD-<N>: <title>
  **Priority:** <High|Medium|Low> · **Labels:** <type(s)>, <size>[, parked] · **State:** <state>

  <full body, verbatim>
  ```
- **Duplicate of SAD-N — noted, no action.**
- **Duplicate of SAD-N — added context** (one-line summary).

One-line reminder: the fixing commit cites the R-ID + `Fixes SAD-N` so the GitHub↔Linear
integration auto-closes it.

Scope guard: this command only records issues (incl. commenting on a confirmed dup). Do **not**
edit code/docs, and do **not** push.
