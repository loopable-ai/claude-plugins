# The loopable plugin

Keeps a repository and the Loopable backlog telling the same story.

A repository names its project in `.loopable.yaml` at the root (see the skill
for the three keys). From then on six hooks apply, each doing one mechanical
thing — anything needing judgement is a skill, not a hook — plus two commands
and two agents, which are the two ends of a piece of work: `/loopable:start`
begins one, `/loopable:ship` finishes it.

| hook | event | |
|---|---|---|
| `open-work.sh` | SessionStart | Lists what is in progress before there is anything to interrupt. The half a merge guard cannot fix: nothing stops a session simply not knowing the backlog exists. |
| `session-start.sh` | SessionStart | Opens — or resumes — the session for the item this branch is working, so the console shows a harness at work without anybody remembering to say so. |
| `tool-use.sh` | PostToolUse | Reports a created PR at once, and batches everything else into one `action` activity. |
| `stop.sh` | Stop | One `result` activity saying where this stretch got to. It does not close the session. |
| `guard-main.sh` | PreToolUse Edit/Write | Refuses an edit **on `main`** to a tracked path, and prints how a branch is started here — `/loopable:start`, and the repository's own `start:` line. One worktree per item is what lets several agents share one repository. |
| `guard-merge.sh` | PreToolUse Bash | Refuses `gh pr merge` for a PR that touches a tracked path and names no work item, or names one that is not `in_review` with a verified close at **this PR's HEAD sha**. |

It exists because the story diverged once: four PRs shipped a whole phase and
every one of its backlog items still read "Not Started" afterwards. The plan
had predicted it, in writing: *reporting completion has to sit on the path
already being walked — part of finishing a task, not a chore afterwards.* A
reminder at merge time is a detour. These are not reminders.

## Install

```bash
claude plugin marketplace add loopable-ai/claude-plugins
claude plugin install loopable@loopable-ai
```

The plugin registers the MCP server too (`.mcp.json` runs `@loopable/mcp`
from npm), so one install gives a session both the tools and the hooks. This
repository installs it the same way — `.claude/settings.json` names the
`loopable-ai` marketplace — and develops it here: the public repository is a
release mirror, published by `.github/workflows/loopable-plugin-release.yml`
on a `loopable-plugin-v<version>` tag whose version matches the manifest.

The token is read from `~/.config/loopable/token` (or `LOOPABLE_TOKEN`, or
`LOOPABLE_TOKEN_FILE`) — the same file the MCP server reads. Nothing in the
plugin holds a secret.

## The session, reported while it happens

A Loopable session is the live record of one piece of work: the console reads
it, and so does the product owner looking for a stall. Three of the hooks keep
it current with no model call anywhere in the path — a hook that asked a model
what it had just done would cost a request per tool call and answer with a
paraphrase of the transcript.

**Which item is this branch?** Four answers, cheapest first: `LOOPABLE_ITEM`;
the state file a previous hook wrote; a ref at the end of the branch name
(`<kind>/<slug>-<ref>` — a plain number, which is how `/loopable:start` names
them); or the
one `in_progress` item sharing at least two words of at least three letters
with the branch slug. **A tie resolves to nothing**, and so does everything
else that does not resolve — an item guessed wrong writes one person's work
into another person's session, which is worse than no session. On `main` there
is nothing to open at all.

**SessionStart resumes before it opens.** A session is one piece of work, not
one process: a `--continue`, a crash and a second window on the same worktree
are the same session, and opening a new one each time turns the console into a
list of ghosts and the stall detector into a liar.

**PostToolUse batches.** A `gh pr create` whose *output* carried a pull request
url is an event and gets its own activity immediately, with the url, the number
and the item in `ref` — `agent_sessions` has no `pr_url` column, and inventing
one for a hook would be a migration in service of a convenience, so the link is
an activity where the schema already says "what this points at". Everything else
appends **one line to a file and makes no request at all**, posted as a single
`action` activity at ten lines or five minutes, whichever comes first. Per-call
activities would be a session with four hundred rows and a bill to match.

**Stop summarises; it does not close.** Closing `complete` is a claim, and the
close contract wants a brief revision, a HEAD sha, a verifier verdict, every
criterion accounted for, screenshots and a cost — none of it knowable to a hook
watching a process end. So the session stays open, which is accurate, and
`/loopable:ship` closes it. The summary is the last commit's subject and how
many files are uncommitted, both read from git. **Never the transcript**: an
activity body is read by whoever opens the console, and a hook that piped a
session's reasoning into a shared record would be exfiltrating a working
process, not reporting one.

**Nothing is written into the working tree.** The item and session ids, and the
batch buffer, live under `.git/loopable/` — per-worktree, since the item *is*
the branch, and impossible to commit. The obvious place, a dotfile in the
repository root, needs a `.gitignore` entry, and a plugin editing somebody's
`.gitignore` has done something they did not ask for. `.git/info/exclude` would
work and is still a rule that can be removed; a file the git directory owns is
not a rule at all.

## Every failure is a pass — except one

No token, no network, a sleeping database, an id the token cannot see, no git,
a detached HEAD — all pass. A guard speaks only on a confident negative: the
backlog answered and the answer was no; the branch is `main` and the path is
tracked. The reason matters more than being thorough:

> A hook that fires during ordinary work gets switched off.

For the reporting hooks the same rule reads slightly differently: a failure is
not just permitted, it must be **silent**. A `PostToolUse` or `Stop` hook's
stdout lands in the transcript, so a hook that complained about the backlog
being unreachable would be a hook talking to an agent about its own
bookkeeping. They exit 0 having printed nothing on every path, `curl`'s own
diagnostics included — and the suite points a hook at a closed port, with a
token in hand so the request is really attempted, to prove it. That case was
written twice: the first version also unset the token, so the helper returned
before `curl` ran and deleting the `2>/dev/null` left the suite green.

The write guard judges the repository **the file is in**, not the session's: a
session in a main checkout editing a file inside a worktree is doing the right
thing, and the worktree's branch is the one that counts.

**The merge guard is the exception, and it is deliberate.** A `Write` refused
in error costs somebody thirty seconds; a merge cannot be taken back. If this
guard failed open whenever the backlog was unreachable, its entire ruleset
would be switched off by a dropped connection — "the API was down" is the
cheapest exploit anybody will ever find, and it leaves no trace that a check
was skipped. So `gh pr merge` REFUSES WHAT IT CANNOT VERIFY: no token, no
network, a sleeping database, a ref the token cannot resolve to an item. The
refusal says the backlog is what did not answer, so nobody reads it as a
statement about their work.

Three things keep that from being intolerable. The stated exception is checked
**before anything that can fail**, so `Loopable: none — <why>` still works with
the API down. `gh` failing is still a pass, because a `gh pr view` that cannot
answer means a `gh pr merge` that cannot merge — there is no state to protect,
and refusing there would be theatre. And every refusal prints
`LOOPABLE_ALLOW_MERGE=1`, which is a **person's** door: the hook reads its own
environment, so the variable has to have been set in the session somebody
started, and an agent cannot reach for it by prefixing the command it was just
refused.

## Naming the item

```
Loopable: 41
Loopable: 4e90ea71-bc6a-445d-8517-f732d064a1f5
Loopable: none — a platform change with nothing in the backlog yet
```

The ref is a plain number and so is what a branch name carries. The letter refs
used to wear (`s41`) still resolve here, because a PR body written before
2026-09-08 has to go on meaning what it meant.

`none` is an escape hatch on purpose, and a visible one: a stated exception can
be argued with in review, and silence cannot.

Naming the item is the first half. The second is that the item is **`in_review`
with a close at this PR's HEAD sha whose verdict is `pass`** — the close
contract, not a status somebody typed. `/loopable:ship` (S2.5) will do it in
one step; until it exists, it is one `close_session` through the MCP carrying
the brief revision, the head sha, the verdict and its reason, every criterion
with an `implemented_at` and a status, the screenshot attachment ids and the
cost. A complete close moves the item to `in_review` by itself, so satisfying
the contract satisfies the status too.

`not_run` is not a synonym for `fail`. It is refused, naming the verdict —
unless the item's acceptance criteria carry no `browser` verify method, in
which case there was nothing for a browser verifier to drive and the verdict is
a true statement. That rule is read off what S1.3 stored (`browser` is exactly
the method the database makes screenshots mandatory for), not invented in the
hook.

## Four security rounds, and what they say

The merge guard is about three hundred lines of shell against attacker-shaped
input, and four separate reviews each found something the last one's tests
did not cover.

- It read the PR number only where a regex expected it, so `gh pr merge
  --squash 367` walked past. It now collects every integer in the command; a
  number that is not a PR fails its own lookup and costs nothing.
- It decided "invoked or merely mentioned?" by looking for quotes — a regex
  pretending to be a shell parser, which `eval` and `bash -c` walk through. The
  default is inverted: a command mentioning a merge is checked unless it
  *starts* with something that cannot start another program. That list is
  `echo printf cat head tail comm`, and a test asserts membership rather than
  behaviour, because `awk` has `system()`, GNU `sed` has `e`, `rg` takes
  `--pre`, and `less` has a `!` escape.
- The session banner sanitized work item titles and the denial reason did not,
  although both land in an agent's context the same way. A title can begin
  life as a sentence a client typed in chat. There is one sanitizer now,
  `loopable_safe` in `lib.sh`, and both callers use it.
- **It checked a status, and a status is a sentence somebody types.** "Not
  `todo`" was satisfied by one `report_progress` call, which is the agent
  saying so about its own work — a guard reading it is checking that the right
  words were used. The close contract (S1.3) is the first thing here that is
  not a sentence: it costs a brief revision, every criterion accounted for,
  screenshots where a browser was the way to check, a cost, and **a HEAD sha**.
  The sha is what makes the claim checkable from a hook — the API says what was
  verified, `gh pr view --json headRefOid` says what is about to be merged, and
  this is the one place both are in hand. **A PR whose HEAD moved after the
  close is a PR nobody verified**, and the record still reads like a pass: the
  close is still on file, still says `pass`, and now describes a commit that is
  not the one going in. One string comparison is the whole difference between a
  report and evidence. The same round moved the marker and the sha to
  **GitHub's copy alone** — both come from one `gh pr view`, so they describe
  the same PR at the same instant, and nothing in the command text is ever read
  as either. `gh pr merge 9  # Loopable: <an in_review item>` has written a
  comment. And whatever follows `Loopable:` became opaque to the guard: one
  `lib.sh` pair harvests the string and resolves it against the backlog, so a
  new spelling — short ids in S1.10, and plain numbers replacing them — composes
  with the sha rule without either knowing about the other.

The honest conclusion: guards written in shell against attacker-shaped input
want adversarial review every time they change, not once.

## Starting work

```
/loopable:start <item id | ref | next>
```

One command, and it is `bin/start.sh` — the command file is four lines telling
Claude to run the script and read what it printed. **All of the sequence is in
the script and none of it is in the prose**, because a model asked to remember
six steps will one day do five, and the step it drops is the readiness refusal:
the one with a person's judgement behind it.

In order, every time:

1. **Pull the brief pack** — `next` lets the backlog choose the oldest ready
   item nobody is on; anything else is resolved through the same `lib.sh` pair
   the merge guard uses, so a full id and a short id mean the same thing here as
   they do there.
2. **Refuse anything that is not `ready`**, and print the blockers the pack
   carries as sentences. `ready` is three deterministic queries somebody else
   already ran; leaning on that answer is the whole reason it is deterministic.
   An item already in progress is refused with the reason a person needs — two
   agents on one item is the collision the worktree rule exists to prevent.
3. **Make the worktree from `origin/main`.** With a `start:` line in
   `.loopable.yaml` that command is RUN, placeholders filled in (`<type>`,
   `<kind>`, `<slug>`, `<shortid>`) — re-implementing it would create branches
   the repository's own convention does not recognise. Without one, the fallback
   is `git fetch origin && git worktree add -b <kind>/<slug>-<shortid>
   .claude/worktrees/<branch> origin/main`.

   **The last word of the `start:` command, after substitution, is the branch.**
   That is stated rather than inferred: it is how an existing branch is refused
   *before* anything is created, and the worktree itself is then found by asking
   git which checkout holds that branch — never by parsing what the command
   printed.
4. **Report `in_progress`**, with a note naming the branch. After the worktree,
   not before: an item claimed with no branch under it is a lie the console
   shows everyone.
5. **Open the session**, with the payload `session-start.sh` posts, and write
   `.git/loopable/` state **into the new worktree** — so the first session that
   starts there *resumes* this one instead of opening a second on the same work.
6. **Print the pack** and where the work now is.

**A command is not a hook, and the failure discipline is inverted.** A hook
fails silently because nobody asked it to run; this was asked for by name, so
every failure is a sentence and a non-zero exit, and each one says whether
anything was created or reported. Nothing is ever undone: if the claim fails the
worktree stands and the message says so, because removing a worktree is the one
thing this plugin does not do anywhere.

**It cannot `cd` your session.** A running process cannot move the session that
started it, so the last line does not pretend to — it says where the work is and
leaves the choice between a new session there and this one editing under that
path.

## Shipping

```
/loopable:ship
```

The other end of `/loopable:start`, and the only thing that closes a session.
It is `bin/ship.sh` in two halves with a model in between, because **a shell
cannot spawn an agent** and two agents are the point:

```
ship.sh --prepare  →  verifier + reviewer  →  ship.sh --close
```

`commands/ship.md` is those three lines. Everything on either side of the seam
is code, for start.sh's reason.

**--prepare** refuses what cannot be shipped, and each refusal prints the one
command that fixes it: no session in this worktree (`/loopable:start` first), an
uncommitted tree, a branch that is not pushed. **It commits nothing and pushes
nothing** — a close says "I verified THIS commit", and a script that committed on
the way past would be closing at a commit no verifier ever saw. Then it clears
the reports from any previous run — a `verify.md` describing a commit that has
since moved is exactly what the merge guard's sha rule exists to catch — and
prints the item, the criteria with their verify methods, the environments, the
HEAD sha and the exact shape the reports must have.

**The two agents**, `agents/verifier.md` and `agents/reviewer.md`, adapted from
Avanti Studio's fountain plugin. Two hands, two questions, and neither is the
builder's to answer about their own work:

| | asks | has | writes |
|---|---|---|---|
| `verifier` | does the running thing do what the criteria say, at this sha | read tools, Bash, and the browser MCPs | `verify.json` + `verify.md`, and screenshots |
| `reviewer` | is the diff right — correct, tested, in scope, conformant, safe | read tools and Bash | `review.md`, ending `ship` or `hold` |

**Neither has Edit or Write, and that is structural**: naming a gap and patching
it are two jobs, and one hand cannot be trusted to do both honestly. Both have
Bash, because verifying means running things and reviewing means running tests —
so the discipline is stated in each agent (Bash runs and reads, never writes a
tracked file) and there is a mechanical backstop under it: `--close` refuses on
a dirty tree, so an agent that edited the code stops the ship. The verifier
keeps the browser tools and the reviewer keeps none: running the app is the
verifier's evidence, and gathering it in a review would blur the line that makes
both reports worth reading.

**Everything lands under `.git/loopable/`** — the reports, the evidence
directory, the pull request body — for the reason the item and session ids do:
a file the git directory owns cannot be committed, so there is no `.gitignore`
rule to add and none to remove.

**--close** does the six things a person would otherwise do in order and
sometimes not:

1. **Maps the report's criteria onto the brief's, by their words.** The pack a
   verifier reads carries no ids at all, so the mapping happens here, once. A
   criterion the report never mentions is a **refusal before anything is
   uploaded** — a close cannot leave one open, and finding that out from a 422
   after three attachments have landed is finding it out late.
2. **Uploads the two reports and the screenshots** as attachments on the
   *session* — request, PUT to the presigned POST, confirm. The API grew a
   seventh register for this (`session`), because a run's exhaust is not a
   knowledge register: the session already is the row for "this run, on this
   item, at this sha".
3. **Posts the close contract**: brief revision, HEAD sha, verdict and reason,
   every criterion with where it landed and whether it is met, the screenshot
   ids, the cost. `not_met` is recorded as `skipped` — the only two endings a
   close may write — with the words "not met" carried into `implemented_at`
   where a person will read them. **The cost is zeros unless something wrote a
   `cost` file into the state directory**, because no hook here is handed a
   token count and a guessed number is worse than an honest zero.
4. **Opens the pull request**, titled from the item and bodied with the ask, the
   criteria as a ticked checklist, the verdict, the reviewer's last line and
   `Loopable: <ref>`. `--trailer '<line>'` appends a harness's own session link;
   a script cannot know one.
5. **Says the item moved by itself.** A complete close writes `in_review` in the
   same statement, through the transitions table. A `report_progress` afterwards
   would be a second write saying what the first already said, and the day they
   disagree the item is the one that is wrong.
6. **Exits 1 on a `fail` or `not_run` verdict — after closing.** The contract
   wants the truth, and a harness that only reported successes would be a
   harness whose reports mean nothing. The pull request says so in a banner and
   the merge guard refuses the merge until a session closes `pass` at the commit
   being merged.

## What it will not catch

It cannot tell you named the wrong item, and it cannot make you create an item
for work that had none. It closes the gaps that actually bit — edited on main,
merged and never reported — and no more than that.

## Testing

`apps/loopable/plugin/hooks/test.sh`, run by `guards` on every PR. `gh` and
`curl` are stubbed, the config file is a fixture, and the write guard runs
against a throwaway git repository it creates — no network, no token, no state
from this checkout. Half the cases assert a PASS, which is the half worth
having.
