# Driver events

The driver's judgements, written where the factory can count them. Each one is a
`post_activity` on an item's session, with the event in the activity's `ref`:
the `body` is the sentence a person reads, the `ref` is what an analytics pass
reads by name. This file is the ONE list of those names and their fields — the
driver prompt (`agents/driver.md`) and the analytics story (338) both point
here, and `hooks/test.sh` goes red when the driver stops naming one of them.

The list is fixed. A new judgement worth counting is a new entry here, in the
same change as the driver prose that posts it; a name made up on the spot is a
row nothing will ever read.

## Which session

- **While a session is open** — after `start.sh`, before `ship.sh --close` —
  the event goes on it: the id is in
  `$(git -C <wt> rev-parse --absolute-git-dir)/loopable/session`.
- **A decision about a verdict** goes on **the session that closed with that
  verdict**, which is still the id in that file: `ship.sh --close` closed it,
  and the decision came after, on the checks of the pull request the close
  opened. A closed session takes activities from the member who held it and
  nobody else, and the post changes nothing about its ending. The re-ship
  session opened after a fix round is for the next run's own events.
- **A stand-in** goes on the session the item has — the one the stand-in
  opened, when the script broke before it opened one.
- **A worktree removed** goes on the session recorded in that worktree's state
  directory, read before the removal: removing the worktree removes the file.
- **No session, no event.** `start.sh` refusing creates nothing, so there is
  nothing to post on; see `start_refused`. A worktree with no session file is
  named in the driver's message instead.

Every `ref` carries `event`. The fields below are required; nothing else is.

## The events

### `builder_started`

The driver handed the worktree to a builder. Kind `action`, on the session
`start.sh` opened.

| field | |
|---|---|
| `event` | `"builder_started"` |
| `builder` | the builder's name, `builder-<ref>` |
| `branch` | the branch it builds on |

### `brief_defect`

A builder said the brief cannot be done as written. Kind `thought`, on the open
session. Not a fix round.

| field | |
|---|---|
| `event` | `"brief_defect"` |
| `defect` | what the builder said is wrong, verbatim |

### `fix_round`

The driver sent findings back to the item's implementer — the builder, or the
master builder once escalated. One event per round, posted when it sends them.
Kind `action`, on the session whose verdict, review or checks produced the
findings.

| field | |
|---|---|
| `event` | `"fix_round"` |
| `n` | the round, from 1, with no fixed cap; the master builder's rounds go on counting from the builder's |
| `source` | `"verifier"`, `"reviewer"` or `"check"` — whose finding it was |
| `finding` | the finding, verbatim; several findings from one source are one string, each on its own line |

Findings from two sources in one round are two events with the same `n`.

### `escalated`

The driver took the item from `builder-<ref>` and gave it to
`masterbuilder-<ref>`, because the fixes stopped holding. Once per item. Kind
`action`, on the session whose verdict it acted on, beside that round's
`fix_round`.

| field | |
|---|---|
| `event` | `"escalated"` |
| `n` | the round the master builder starts with |
| `sign` | `"regressed"`, `"finding_returned"` or `"third_round"` — which sign it was |
| `reason` | the one sentence of why, with the round numbers |

### `follow_up`

After two fix rounds, a finding outside the pull request's lines went to a new
item instead of another round. Kind `action`, on the session whose verdict,
review or checks raised it.

| field | |
|---|---|
| `event` | `"follow_up"` |
| `item` | the follow-up item's ref, as a number |
| `source` | `"verifier"`, `"reviewer"` or `"check"` — whose finding it was |
| `finding` | the finding, verbatim |

### `merged`

The driver merged the pull request. Kind `result`, on the session whose `pass`
it merged on, posted once `gh pr view` says `MERGED`.

| field | |
|---|---|
| `event` | `"merged"` |
| `pr` | the pull request number, as a number |
| `sha` | the merge commit's sha |
| `reason` | the one sentence of why, naming any finding that went to a follow-up |

### `after_merge`

What the driver ran after a merge because `AGENTS.md` names it — a release tag
pushed and the run it started, a deploy verified by sha — and what it showed.
One event per step. Kind `result`, on the session the `merged` went on.

| field | |
|---|---|
| `event` | `"after_merge"` |
| `step` | what ran: `"release_tag"` or `"deploy"` |
| `sha` | the merge commit's sha |
| `result` | `"green"` or `"red"` — a deploy whose sha does not match is red |
| `evidence` | the tag, the run's url, or what the version check answered |

### `handed_off`

The driver handed the item to a person: a sign-off `AGENTS.md` asks for, a
change hard to undo, a risk only a person can accept — a `not_run` that nothing
in the session could run is one — or a master builder whose rounds stopped
converging, with the question only the person can answer. Kind `result`, on the
session whose verdict it acted on.

| field | |
|---|---|
| `event` | `"handed_off"` |
| `pr_url` | the pull request url |
| `reason` | the one sentence of why |

### `start_refused`

`start.sh` refused the item. **Not posted, yet**: a refused start opens no
session, an activity needs one, and an open session that blocked the start is
somebody else's to write in. Until refusals get a home of their own (291), the
driver says the blockers in its message to the person. The fields are fixed
here so that home takes them as they are.

| field | |
|---|---|
| `event` | `"start_refused"` |
| `blockers` | what `start.sh` printed as the blockers, verbatim |

### `guard_allowed`

**Posted by the merge guard, never by the driver.** The guard refuses only a
failed head or a moved head; every other merge it lets through with a warning
on stderr and this event, on the item's newest **closed** session — never an
open one. With no closed session to post on it only prints, and a merge with no
pull request it could resolve prints `no_pr_resolved` and records nothing. Kind
`result`. It is listed here so the one list names every event a session's
stream can carry. The driver reads it and never takes it for a pass: a merge
the guard allowed is still the driver's to judge by its own rule.

| field | |
|---|---|
| `event` | `"guard_allowed"` |
| `pr` | the pull request number, as a number |
| `reason` | the guard's code for why nothing was refused — `not_run`, `no_session`, `not_in_review`, `unresolved_ref`, `unreachable`, and the rest `guard-merge.sh` names |
| `head` | the PR's head sha the guard checked |

### `stood_in`

`start.sh` or `ship.sh` broke — failed at its own job, not refused the item — and
the driver did by hand the steps it had not done, in its order, refusing what it
would have refused. Kind `action`, on the item's session.

| field | |
|---|---|
| `event` | `"stood_in"` |
| `script` | `"start.sh"`, `"ship.sh --prepare"` or `"ship.sh --close"` |
| `failure` | what the script printed, verbatim |
| `did` | the steps the driver took, one per line |
| `bug` | the ref of the bug item filed for it, as a number — filed before this event, so the ref is real |

### `worktree_removed`

The driver removed a worktree whose pull request was merged or closed, whose
tree was clean and whose head was the pull request's, and deleted its local
branch. Posted at the session's start or end, when the cleanup runs. Kind
`action`, on the session recorded in that worktree.

| field | |
|---|---|
| `event` | `"worktree_removed"` |
| `worktree` | the path it had |
| `branch` | the branch deleted with it |
| `pr` | the pull request number, as a number |
