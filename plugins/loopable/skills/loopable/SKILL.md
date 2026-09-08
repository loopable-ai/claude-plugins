---
name: loopable-backlog
description: Use when working in a repository that belongs to a Loopable project — planning, picking up work, or landing a PR. Explains that the Loopable backlog is the source of truth for that work, which MCP tool does what, why an edit on main is refused, and why a PR touching tracked paths must name its work item. Triggers on "what's next", "the loopable backlog", "report progress", "propose", "add_item", "landing a PR", "why was my edit refused", ".loopable.yaml".
---

# The Loopable backlog is the source of truth

This repository names its Loopable project in `.loopable.yaml` at its root:

```yaml
project: <project id, from whoami>
paths:            # optional: only these must name a work item; omit for all
  - apps/loopable
start: platform/bin/work.sh <type>/<slug>   # optional: printed when an edit on main is refused
```

Read the backlog there, not in any markdown file that describes it. Files
describe reasoning; the backlog says what is left to do.

## Which tool, and when

| | |
|---|---|
| `whoami` | the project ids this token can see |
| `list_backlog` | what exists. Start here. |
| `get_item` | one item, with its links and tags |
| `add_item` | work the studio has decided to do. The backlog is the studio's own; a member writing in it is a member doing their job. |
| `propose` | something **somebody else** asked for, or a **new feature** (a surface). It goes to the approval queue for a person to accept, reword or decline. |
| `revise` | fix an item's title or body. Not its visibility, kind or parent. |
| `link_items` | this must be done before that |
| `ask_studio` | a question a person has to answer, into the escalations inbox |
| `report_progress` | `todo` / `in_progress` / `done`, with one sentence about what happened |

`add_item` and `propose` are not two ways to do one thing. The line is **where
the work came from**, not how much anybody is trusted: our own decided work
goes in the backlog, an outside ask goes in the queue. Routing everything
through the queue would not add a safeguard, it would add a rubber stamp.

## One worktree per item

An edit on `main` to a tracked path is refused by the plugin. Start a branch in
its own worktree — the refusal prints how, from `start:` — and work there. One
worktree per item is what lets several agents share one repository: each branch
starts from `origin/main`, each PR names its item, and nothing two agents do
lands in the same working tree. `LOOPABLE_ALLOW_MAIN=1` overrides the refusal
once, for a person with a reason.

## Report as part of finishing, not afterwards

A backlog is only as current as the moment somebody updates it, and updating it
as a separate act of remembering is how it goes stale. So:

**A PR that touches a tracked path must name its work item in the body.**

```
Loopable: 4e90ea71-bc6a-445d-8517-f732d064a1f5
```

`report_progress` it before merging. The merge guard refuses a PR that names
nothing, or that names an item the backlog still calls `todo`. If something
genuinely has no item, say so on purpose — `Loopable: none — <why>` — because a
stated exception can be argued with and silence cannot.

## What the guards will not catch

They cannot tell that you named the *wrong* item, and they cannot make you
create an item for work that had none. They close the gaps that actually bite —
edited on main, merged and never reported — and no more than that.
