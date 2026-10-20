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
- **No session, no event.** `start.sh` refusing creates nothing, so there is
  nothing to post on; see `start_refused`.

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

The driver sent findings back to the builder. One event per round, posted when
it sends them. Kind `action`, on the session whose verdict, review or checks
produced the findings.

| field | |
|---|---|
| `event` | `"fix_round"` |
| `n` | the round, from 1; three at most |
| `source` | `"verifier"`, `"reviewer"` or `"check"` — whose finding it was |
| `finding` | the finding, verbatim; several findings from one source are one string, each on its own line |

Findings from two sources in one round are two events with the same `n`.

### `merged`

The driver merged the pull request. Kind `result`, on the session whose `pass`
it merged on, posted once `gh pr view` says `MERGED`.

| field | |
|---|---|
| `event` | `"merged"` |
| `pr` | the pull request number, as a number |
| `sha` | the merge commit's sha |
| `reason` | the one sentence of why |

### `handed_off`

The driver handed the item to a person: a `not_run` verdict, a sign-off
`AGENTS.md` asks for, a change hard to undo, a risk only a person can accept,
or three rounds spent. Kind `result`, on the session whose verdict it acted on.

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
