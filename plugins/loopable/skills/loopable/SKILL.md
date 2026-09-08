---
name: loopable-backlog
description: Use when working in a repository that belongs to a Loopable project — planning, picking up work, or landing a PR. Explains that the Loopable backlog is the source of truth for that work, which MCP tool does what, why an edit on main is refused, why a PR touching tracked paths must name its work item, and what the session hooks already report on your behalf. Also defines the vocabulary — feature, epic, story, task, bug, decision, session, brief, environment and the item states — in vocabulary.md beside this file. Triggers on "what's next", "start on this item", "/loopable:start", "/loopable:ship", "ship it", "close the session", "open the PR", "the loopable backlog", "report progress", "propose", "add_item", "landing a PR", "why was my edit refused", "post_activity", "open_session", ".loopable.yaml", "epic", "story", "task", "bug", "what kind", "which kind".
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
| `pull_item` | the brief pack of one item. **The first call of a work session** — see below. |
| `next_ready` | what to pick up next, as the same pack. `null` means nothing is ready or free. |
| `list_backlog` | what exists. Start here when browsing rather than starting. |
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

## Starting work: pull the pack first

Before writing anything, `pull_item` on the item you are about to build (or
`next_ready` to be given one). It is one bounded answer carrying the item and
its ask, the acceptance criteria with how each will be checked, one hop of the
graph **by title**, the standing decisions that govern it, and the registered
environments to point at. It replaces get_item plus neighbourhood plus
list_decisions, and it is capped at 24 KB, so it costs the same every time and
there is no judgement call about whether you can afford it.

**Read `ready_blockers` first.** A non-empty list means nobody has groomed the
item — no criterion carries a verify method, or the project has no registered
environment — and it is not work to pick up yet. Say so and ask, rather than
starting.

**Build to the criteria, not to the title.** They are the spec, they are never
trimmed out of a pack however big it gets, and `close_session` will ask you for
each one by the revision (`brief_rev`) you were given.

**The pack carries no ids but the item's own** — everything else is titles, so
look an id up by title when you need one. The item's own id is the one that
goes in `report_progress` and in `Loopable: <id>` in the PR body.

**Pulling is not claiming.** `next_ready` is a read; two harnesses asking at
once are told the same item. What claims it is `/loopable:start`:

```
/loopable:start <item id | ref | next>
```

That is the one command for beginning work, and it does the whole sequence in
order — pull the pack, refuse an item that is not `ready` and list its blockers,
make the worktree from `origin/main` (through the repository's own `start:`
command when it has one), report `in_progress`, open the session, print the
pack. Use it instead of doing those five by hand: the order is the point, and
the step that gets skipped by hand is the refusal.

It refuses loudly rather than silently — a non-zero exit and a sentence — and a
refusal means nothing was created and nothing was reported. When it refuses
because the item is not ready, the blockers it prints are the answer: say them
and stop, rather than starting anyway.

It cannot move your session into the worktree it made. Its last line says where
the work is; open a new session there, or keep every edit under that path.

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
its own worktree — `/loopable:start <item>` does it, and the refusal prints that
along with the repository's own `start:` line — and work there. One
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
closes it with the contract, and it is the only thing that does.

If nothing is reported, the branch's item did not resolve — `main`, no
`.loopable.yaml`, or two items with equal claim on the branch name. Set
`LOOPABLE_ITEM=<id>` and it will.

## Finishing: run `/loopable:ship`

A backlog is only as current as the moment somebody updates it, and updating it
as a separate act of remembering is how it goes stale. So finishing is one
command, the way starting is:

```
/loopable:ship
```

It prepares — refusing a worktree with no session, an uncommitted tree or a
branch nobody pushed, each with the command that fixes it, and **never
committing or pushing for you** — then dispatches the `verifier` and the
`reviewer`, then closes. You do not write either report and you do not edit what
they return: a report you corrected is your report, and the verdict is the one
thing in the close contract that has to come from a hand other than the one that
built the thing.

The close is the report. It carries the brief revision, the HEAD sha, the
verdict and its reason, every criterion with an `implemented_at` and a status,
the screenshot attachment ids and the cost — and it moves the item to
`in_review` by itself, so **do not `report_progress` afterwards**. The verifier's
and reviewer's reports are attached to the session, with the screenshots they
cite; the pull request carries the criteria as a checklist and `Loopable: <ref>`.

A verdict of `fail` or `not_run` still closes, because the contract wants the
truth: the pull request says so, the command exits 1, and the work is to fix
what the report names, commit, push and ship again. **Push after you close and
the close is stale** — it was bound to a commit, and a branch that moved
afterwards is a branch nobody verified.

The rules the guard applies to all of that:

**A PR that touches a tracked path must name its work item in the body.**

```
Loopable: 4e90ea71-bc6a-445d-8517-f732d064a1f5
```

**And the item has to be `in_review`, with a close at that PR's HEAD sha.**

The merge guard refuses a PR that names nothing; that names an item the backlog
does not call `in_review`; or whose newest complete session was closed at a
different commit from the one about to be merged. A close says "I verified
this", and a branch that moved afterwards is a branch nobody verified — so
**push after you close and the close is stale**: close again at the new HEAD.

`/loopable:ship` is what satisfies both, and `close_session` through the MCP is
the same payload by hand for a session the command cannot reach. Either way a
complete close moves the item to `in_review` — that is the report, and
`report_progress` is not a substitute for it. `verifying` is the deploy and
`done` is a person accepting the work; the API refuses both from a token.

A verdict of `fail` is refused, and so is `not_run` — unless the item has no
acceptance criterion a browser has to check, in which case there was nothing
for a browser verifier to drive and the verdict is honest.

If something genuinely has no item, say so on purpose — `Loopable: none —
<why>` — because a stated exception can be argued with and silence cannot. It
is the one thing the guard honours even when the backlog is unreachable: unlike
every other hook here, this one **refuses what it cannot verify**, because a
merge cannot be taken back and "the API was down" must not be a way through.
`LOOPABLE_ALLOW_MERGE=1` is one, and it belongs to whoever started the session:
the hook reads its own environment, so prefixing your command with it does
nothing.

## What the guards will not catch

They cannot tell that you named the *wrong* item, and they cannot make you
create an item for work that had none. They close the gaps that actually bite —
edited on main, merged and never reported — and no more than that.
