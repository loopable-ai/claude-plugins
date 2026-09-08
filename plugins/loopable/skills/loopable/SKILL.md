---
name: loopable-backlog
description: Use when working in a repository that belongs to a Loopable project — planning, picking up work, or landing a PR. Explains that the Loopable backlog is the source of truth for that work, which MCP tool does what, why an edit on main is refused, why a PR touching tracked paths must name its work item, and what the session hooks already report on your behalf. Also defines the vocabulary — feature, epic, story, task, bug, decision, session, brief, environment and the item states — in vocabulary.md beside this file. Triggers on "what's next", "the loopable backlog", "report progress", "propose", "add_item", "landing a PR", "why was my edit refused", "post_activity", "open_session", ".loopable.yaml", "epic", "story", "task", "bug", "what kind", "which kind".
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
| `node` | one node and the edges touching it. The cheapest way to see what an item is joined to. |
| `neighbourhood` | what is around a node, one or two hops, filtered by relation. Orientation before building. |
| `path` | how two things relate — the shortest route between them. `found: false` means no route **you may see**. |
| `add_item` | work the studio has decided to do. The backlog is the studio's own; a member writing in it is a member doing their job. |
| `propose` | something **somebody else** asked for, or a **new feature** (a surface). It goes to the approval queue for a person to accept, reword or decline. |
| `revise` | fix an item's title or body. Not its visibility, kind or parent. |
| `link_items` | this must be done before that |
| `ask_studio` | a question a person has to answer, into the escalations inbox |
| `report_progress` | `todo` / `in_progress` / `in_review` / `blocked` / `awaiting_input`, with one sentence about what happened. Not `done` — a person accepts the work. |

`add_item` and `propose` are not two ways to do one thing. The line is **where
the work came from**, not how much anybody is trusted: our own decided work
goes in the backlog, an outside ask goes in the queue. Routing everything
through the queue would not add a safeguard, it would add a rubber stamp.

## Which kind: read vocabulary.md

`vocabulary.md`, beside this file, is the definitions — feature, epic, story,
task, bug, decision, session, brief, environment, the item states, the rank
rule and the rule of thumb. It is a copy of the project's own
`VOCABULARY.md`, and it is the same text the Loopable product owner is given
and the same text the in-app Help page shows a client: filing work by these
words means the studio, the client and every other agent read the item the way
you meant it.

Read it before choosing a kind or a parent. The one line that decides most
cases: if you cannot say what a person will see when it lands, it is not a
story; if you cannot say what the client would call it, it is not an epic.

## One worktree per item

An edit on `main` to a tracked path is refused by the plugin. Start a branch in
its own worktree — the refusal prints how, from `start:` — and work there. One
worktree per item is what lets several agents share one repository: each branch
starts from `origin/main`, each PR names its item, and nothing two agents do
lands in the same working tree. `LOOPABLE_ALLOW_MAIN=1` overrides the refusal
once, for a person with a reason.

## Your session is already being reported

You do not open a session, and you do not narrate your tool calls. The plugin's
hooks do it: one is opened (or resumed) for this branch's item when the session
starts, a batched `action` activity carries what you ran, a created PR is posted
the moment `gh pr create` prints its url, and a `result` summary goes in when
the session stops. No model call is involved in any of that, and none of it
reads your transcript.

So `post_activity` is for the things a hook cannot know: a decision you made and
why, something that turned out to be harder than the item said, a question you
are about to ask. Write those for a person watching the console, plainly.

What the hooks will **not** do is close the session. A `complete` close is a
claim — brief revision, HEAD sha, verifier verdict, every criterion accounted
for, screenshots, cost — and a hook watching a process end knows none of it. A
session left open says the work is not finished, which is true. `/loopable:ship`
closes it with the contract.

If nothing is reported, the branch's item did not resolve — `main`, no
`.loopable.yaml`, or two items with equal claim on the branch name. Set
`LOOPABLE_ITEM=<id>` and it will.

## Report as part of finishing, not afterwards

A backlog is only as current as the moment somebody updates it, and updating it
as a separate act of remembering is how it goes stale. So:

**A PR that touches a tracked path must name its work item in the body.**

```
Loopable: 4e90ea71-bc6a-445d-8517-f732d064a1f5
```

`report_progress` it before merging — `in_review` when the PR is open, which is
as far as an agent goes: `verifying` is the deploy and `done` is a person
accepting the work, and the API refuses both from a token. The merge guard
refuses a PR that names nothing, or that names an item the backlog still calls
`todo`. If something
genuinely has no item, say so on purpose — `Loopable: none — <why>` — because a
stated exception can be argued with and silence cannot.

## What the guards will not catch

They cannot tell that you named the *wrong* item, and they cannot make you
create an item for work that had none. They close the gaps that actually bite —
edited on main, merged and never reported — and no more than that.
