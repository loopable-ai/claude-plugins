# The loopable plugin

Keeps a repository and the Loopable backlog telling the same story.

A repository names its project in `.loopable.yaml` at the root (see the skill
for the three keys). From then on six hooks apply, each doing one mechanical
thing — anything needing judgement is a skill, not a hook — plus two commands,
which are the two ends of a piece of work (`/loopable:start` begins one,
`/loopable:ship` finishes it), a planning skill, `/loopable:plan`, that asks
every question for a batch before any of it is built, and six agents: the
`verifier` and `reviewer` that ship runs, and the `driver`, `builder` and
`masterbuilder` that run the commands for you, with the `surveyor` that maps the
code for an item whose brief names no paths before its builder starts.

| hook | event | |
|---|---|---|
| `open-work.sh` | SessionStart | Lists what is in progress before there is anything to interrupt. The half a merge guard cannot fix: nothing stops a session simply not knowing the backlog exists. |
| `session-start.sh` | SessionStart | Opens — or resumes — the session for the item this branch is working, so the console shows a harness at work without anybody remembering to say so. |
| `tool-use.sh` | PostToolUse | Reports a created PR at once, and batches everything else into one `action` activity. |
| `stop.sh` | Stop | One `result` activity saying where this stretch got to. It does not close the session. |
| `guard-main.sh` | PreToolUse Edit/Write | Refuses an edit **on `main`** to a tracked path, and prints how a branch is started here — `/loopable:start`, and the repository's own `start:` line. One worktree per item is what lets several agents share one repository. |
| `guard-merge.sh` | PreToolUse Bash | Refuses `gh pr merge` only for a **failed or moved head**: the item's close at this PR's HEAD sha says `fail`, or it has closes and none at that HEAD — whatever its status, and found through its sessions when the body names none. Every other merge of a tracked PR goes through with a warning and a `guard_allowed` activity on the item's newest closed session. |

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
plugin holds a secret. Every studio member mints their own under **My agent
tokens** in the account menu, where it is shown once; see [the MCP server's
README](../mcp/) for what a token may do and the two lines that put it in
place.

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
and the item in `ref`. The session row has a `pr_url` of its own now, but it is
the CLOSE's to write and only at close — a hook watching a tool call cannot
close anything — so the activity is still how a pull request opened mid-run
becomes visible while the run is still going. Everything else
appends **one line to a file and makes no request at all**, posted as a single
`action` activity at ten lines or five minutes, whichever comes first. Per-call
activities would be a session with four hundred rows and a bill to match.

**The session is the call's worktree's, not the process's.** Under the driver
Claude Code runs in the main checkout and a builder works in its worktree with
`cd <wt> && …`, so the session a call belongs to is found from the call itself:
the file an edit names, then the directory a command's leading `cd` goes to,
then the harness's `cwd` — and only when none of them is in a git repository,
the project directory. A call that resolved to a worktree with no session
posts nothing; it never falls back into another worktree's session. The call
picks the worktree, **never the repository**: a target the project directory's
own `git worktree list` does not name — a clone with its own `.loopable.yaml`
and session file, or a directory whose hand-written `.git` points into ours —
posts nothing, and a session, item or project that is not a plain id never
reaches an API path (`bin/ship.sh` refuses one too). A call into a nested
repository inside a worktree — a submodule, a vendored clone — resolves to that
repository, which no worktree list names, so it is recorded nowhere, on purpose. Stop flushes every worktree's waiting
batch into that worktree's own session.

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

## Every failure is a pass

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

**The merge guard was the exception, and since 363 it is not.** It used to
refuse what it could not verify — no token, no network, a ref that resolves to
nothing, no close, a `not_run` — on the argument that a merge cannot be taken
back. Once the driver judges merges, those are judgements, not facts: hand it to
a person, merge after a check by hand, wait for the backlog. A wall in front of
a decision somebody has already weighed gets its door used every time, and the
door records nothing. So the guard refuses only the two confident negatives —
**a failed head** (the item's close at this PR's HEAD sha says `fail`) and **a
moved head** (the item has complete closes and none at that HEAD), whatever the
item's status — and lets the rest through **out loud**: a warning on stderr, and
a `guard_allowed` activity on the item's newest **closed** session with the PR,
the reason and the head in its `ref` (`no_marker`, `none`, `unresolved_ref`,
`not_in_review`, `no_session`, `not_run`, `unknown_verdict`, `unreachable`,
`no_project`, and `no_pr_resolved` for a merge whose PR it could not tell,
which is printed only). Never an open session: an activity marks one active and resets
its clock, which would un-mark a stall on the say-so of somebody else's merge.
A merge with no item, no closed session or no backlog to post to is printed
only, and the warning says which; a merge it refuses records nothing, because
nothing was let through.

It is the one hook that speaks on a failure, because a merge is the moment
somebody should know the check did not happen. `gh` failing is still a silent
pass, because a `gh pr view` that cannot answer means a `gh pr merge` that
cannot merge — there is no PR to warn about. And every refusal prints
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

Naming the item is the first half. The second is the close contract, not a
status somebody typed: `/loopable:ship` closes a session carrying the brief
revision, the head sha, the verdict and its reason, every criterion with an
`implemented_at` and a status, the screenshot attachment ids and the cost, and
a complete close moves the item to `in_review` by itself. The guard reads that
close against the PR's HEAD: `fail` there, or closes none of which is there, is
refused; `pass` there is a quiet merge; anything else is let through with a
warning and a `guard_allowed` activity.

**Leaving the line out does not leave the rules out, and naming another item
does not either.** The guard always reads the project's sessions and takes
every item whose close recorded this PR's number, or whose session ran on its
head branch. When the body names no item — no line, `none`, or a ref nothing
answers to — those are the PR's items. When it names one, they are checked
beside it: the named item gets the full reading, a tied item the body does not
name gets the two refusals and nothing else, and a refusal from any of them
refuses the merge.

`not_run` is not a synonym for `fail`, and the guard no longer judges it: it is
the driver's, or the person's, to decide whether a head nobody verified is
merged, and the guard records that it was.

**The PR argument is read the way gh reads it.** For every `gh pr [-R <repo>]
merge` — inside quotes too, because `eval`, `bash -c`, awk's `system()` and
sed's `e` run what they quote — the guard skips options and their values the
way gh's flag parser does: `--repo`, `--subject`, `--body`, `--body-file`,
`--author-email` and `--match-head-commit` take the next word unless they carry
`=`, and in a short cluster the first of `R t b F A` takes the rest of the word
(`-Rowner/name`, `-dRo/r`, `-tSubject`) or the next word when it is the last
letter (`-sR o/r`). A redirect and its target are not arguments, and a pipe, a
`;`, an `&` or a `#` ends the command, so `gh pr merge 85 --merge
--match-head-commit 54bbc22 --delete-branch 2>&1 | tail -5` asks about PR 85 and
nothing else. The first word left is a number, `#<n>` or a pull request url; a
branch name, which gh resolves; or nothing, which is the current branch's PR,
asked of gh in the command's own directory. **When it still cannot tell** — a
`$PR`, a quoted stretch it cannot see the end of — every number in the command
is a candidate, as it was before 363: it over-collects rather than wave a merge
through. A quoted merge with no PR read adds the current branch's PR too —
`bash -c 'gh pr merge --squash'` merges it — **failing closed**: the only quoted
merges that do not are those whose command never runs its arguments (`grep`,
`egrep`, `fgrep`, `rg`, `ag`, `ack`, `echo`, `printf`, and `git commit`, `git
tag`, `git log`), which are mentions, so a branch at a moved head does not make
them a refusal. Any other command, known or not (`nohup`, `sudo -u`, `find
-exec`, awk's `system()`, a script), counts as running it, and so does an
`echo` or a `printf` in a command holding any shell metacharacter (`| & ; < >
( ) $`, a backtick, a newline: `echo 'gh pr merge' | bash`, `> >(bash)`), an
`rg` given `--pre` or `--pre-glob` (it runs a program on every file), or any
mention inside a `$(…)` or backticks. The first-word pass (a leading `echo`,
`cat`… cannot run anything) fails closed the same way: it is taken only for a
command with no shell metacharacter at all, so `echo ok; gh pr merge 9` and
`true && gh pr merge 9` are read (bug 372). What the reader still misses on a
crafted command is filed as bug 373. The repository the command names (`-R`,
`--repo`, wherever it sits) goes to every `gh pr` lookup the guard makes, when
it reads as `OWNER/REPO` or `HOST/OWNER/REPO`; a pull request url names its own,
which gh takes over `-R`, so that PR is looked up in the url's repository, and
in `-R`'s as well when the two disagree.

**It reads what the shell runs.** Whether a command mentions a merge at all is
asked of its text with every quote and every backslash-newline taken out, the
way the shell takes them out: `g"h" pr merge 9` and a `gh pr \` line break are
the merge they run. That text is never parsed for numbers (dropping the quotes
would make `--subject "fix 12"` read 12); its merges are matched to the raw
reading's by where their `gh` stands, and one the raw reading did not find there
is a merge a quote hid: every number in the command and the current branch's PR
are checked. Matched by place, not counted, because a decoy only the raw text
shows (`true _"gh pr merge 1"; g'h' pr merge 9`) would cancel a count out.

**A merge whose PR nothing resolves** — no number, url or branch it could
resolve, and no number in the command that is one — is let through (Joel,
2026-11-07) as `no_pr_resolved`, and printed only: with no PR there is no item
and so no closed session to record it on, and the worktree's own session is
open. A quote straight after `merge`, the shape of `grep 'gh pr merge'`, is
checked the same way but not reported.

## Four security rounds, and what they say

The merge guard is about three hundred lines of shell against attacker-shaped
input, and four separate reviews each found something the last one's tests
did not cover.

- It read the PR number only where a regex expected it, so `gh pr merge
  --squash 367` walked past. It then collected every integer in the command,
  which over-collected: a sha, a `2>&1` and a `| tail` after the number each
  named a PR of their own, and a good merge was refused for somebody else's.
  Since 363 it reads the PR argument itself, skipping options and their values
  (see "Naming the item").
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
   .loopable/worktrees/<branch-slug> origin/main`, the branch with its `/` made
   a `-`, under the main checkout even when started from a linked worktree. Either way `.loopable/` goes into the repository's
   `info/exclude` once, so a worktree under the checkout is not an untracked
   directory in it.

   **The branch is the `-b` (or `-B`) argument of the `start:` command, after
   substitution; a command with neither names it as its last word.** That is
   stated rather than inferred: it is how a branch already standing is found
   *before* anything is created, and the worktree itself is then found by asking
   git which checkout holds that branch — never by parsing what the command
   printed. A start line should still put `-b` last, so every `start.sh` before
   0.6.10, which read only the last word, finds it too.

   **A branch already standing with a worktree on it is reused**, not refused:
   the item is `ready`, so nobody has claimed it, and what the worktree lacks is
   the claim and the session. A branch with no worktree on it is still refused,
   and so is one whose worktree git still lists but whose directory is gone
   (`git worktree prune` first).
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
anything was created or reported. **What a failed run made, it takes back — and
nothing else.** A failure after the worktree (the command failing, no worktree
on the branch, the claim refused) removes the worktree and the branch *this run*
made when nothing is lost by it — a clean tree, and no commit beyond
`origin/main` — and says so; anything else stays and is named with the reason.
A worktree or branch that was there before the run is never touched, and
neither is one that appeared meanwhile but is not this run's — on its branch, at
its fallback path, or named by a word of its command — since another start may
be making its own in the same window. A branch
left standing was what made every retry refuse (344, 347, 352). The plugin's
only other removal is the driver's cleanup, of worktrees whose pull request has
ended (below).

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
the way past would be closing at a commit no verifier ever saw. A session closes
once, so when the one on record has closed — a fix round — it opens the next on
the same item, harness, repo and branch and records it. Then it clears
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
directory, the pull request body and comment — for the reason the item and session ids do:
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
3. **Finishes the pull request.** When the branch has one already — the draft a
   builder opens on its first push, so CI runs while the verifier works — the
   title and body are the builder's and are never edited: the criteria as a
   ticked checklist, the verdict and the reviewer's last line go on it as ONE
   comment naming the HEAD it is about, and `gh pr ready` takes it out of draft.
   When it has none, it **opens** one, titled from the item and bodied with the
   ask, that same checklist, verdict and last line, and `Loopable: <ref>`.
   `--trailer '<line>'` appends a harness's own session link to either;
   a script cannot know one. **Before the close, and that order is deliberate**:
   the close takes the url and a closed session is never updated again, so this
   is the only moment the link can be recorded. It also means a `gh` that fails
   costs the url and the exit code rather than leaving an item in `in_review`
   with no pull request, which is what the old order could do.
4. **Posts the close contract**: brief revision, HEAD sha, verdict and reason,
   every criterion with where it landed and whether it is met, the screenshot
   ids, the cost, and the pull request url when there is one. `not_met` is
   recorded as `skipped` — the only two endings a close may write — with the
   words "not met" carried into `implemented_at` where a person will read them.
   **The cost is zeros unless something wrote a `cost` file into the state
   directory**, because no hook here is handed a token count and a guessed
   number is worse than an honest zero.
5. **Says the item moved by itself.** A complete close writes `in_review` in the
   same statement, through the transitions table. A `report_progress` afterwards
   would be a second write saying what the first already said, and the day they
   disagree the item is the one that is wrong.
6. **Exits 1 on a `fail` or `not_run` verdict — after closing.** The contract
   wants the truth, and a harness that only reported successes would be a
   harness whose reports mean nothing. The pull request says so in a banner; the
   merge guard refuses a `fail` at the commit being merged, and records a
   `not_run` merge it lets through.

## Planning a batch

```
/loopable:plan [<ref> <ref> ... | <epic ref>]
```

`skills/plan/SKILL.md`, a port of the plan skill in Avanti Studio's fountain
plugin with the backlog in place of GitHub issues. It runs in plan mode, before
the driver builds anything: it takes the refs it is given, an epic's open
children, or with nothing the ready queue plus the `todo` items the person
names; reads each item's pack and links (`pull_item`, `get_item`) and what is
in flight (`in_progress` and `in_review` items, `gh pr list`, `git worktree
list`); judges each `ready`, `ready once answered` or `not now`; and asks the
person every question only they can answer in one pass of `AskUserQuestion`,
each naming its item, its recommendation first.

Nothing is written until the person approves, and then **only into the
backlog**: each item's answers and every `Decided in advance: if X, then Y`
fork go into its brief through `write_brief` (the next revision, the open
questions it answered cleared), the order between items into blocking links
through `link_items`, and the items the person names ready through
`report_progress`, when the token carries the grant. There is no plan file, in
the repository or beside it: the driver reads a planned batch from the briefs
and the links, treats those lines as answered, and runs each item to a merge, a
person, or parked, without a question mid-run. `test.sh` holds the skill's
frontmatter (`disable-model-invocation`, so only a person starts it) and that
it names `write_brief` and `link_items` and no plan file.

## The driver

```
claude --agent loopable:driver
```

A session started as the driver is a lead, not a builder, and it works on the
person's behalf. Its mission is **no human step the project did not ask for**.
It cleans up, reads the repository's `AGENTS.md` and the backlog, says the goal,
the last decision and the next action, and then **files** what the person
describes (`add_item`, `write_brief` with a verify method on every criterion),
**runs** ready items, up to four at once, to merged pull requests, and **does
what the person asks** in the session — a tracked-file change through a builder,
anything else itself. Adapted from the driver in Avanti Studio's fountain
plugin, with the backlog in place of GitHub issues and this plugin's scripts in
place of its own:

```
start.sh  →  builder  →  ship.sh --prepare  →  verifier + reviewer  →  ship.sh --close  →  merge
```

**It hands a person three things and nothing else**: what `AGENTS.md` names as
a person's (a sign-off, the `ready` gate); what is hard to undo (deleting data,
tearing down a stack, a secret, a public API, weakening its own gates without a
person's decision); and a risk a person must own (one the reviewer names, a head
nothing could verify). A question only the person can answer is asked once, in a
line, while the rest goes on. Safe operational writes are its own — re-sending an
invite (cancel and create again through the app's own invite route,
`/v1/studios/{studioId}/invites` — the same API, no cloud write), a read-only
probe, a release tag `AGENTS.md` names — and destructive or production-data
writes stay the person's to run.

**It drives the same machinery a person does, and adds none.** `start.sh` still
refuses an item that is not `ready`, the close contract is still written by
`ship.sh` from two reports the builder never touched, and the merge guard still
refuses a failed or a moved head and records every other merge it lets through
as `guard_allowed` — which the driver reads and never takes for a pass: it
merges only on a `pass` at the head going in. When `start.sh` or
`ship.sh` **breaks** — fails at its own job rather than refusing the item — the
driver stands in: it does the steps the script did not, in its order and with its
refusals — for `--close`, every one: the attachments, the comment and
`gh pr ready` on the builder's draft (or a new pull request's body), an OPEN
pull request only, and the whole contract with `pr_url`, since a closed
session takes nothing afterwards — files the bug, and records what it did as a
`stood_in` naming that bug. The merge guard is a gate, not machinery: nobody stands in for it.

**Rounds have no fixed cap; the driver judges convergence.** Findings go back to
the same builder while each round narrows what is wrong. When the fixes stop
holding — a round regresses, a finding comes back, or a third round is due — the
item goes to `masterbuilder-<ref>`, an opus agent with every builder limit that
takes over the worktree, branch and pull request, reads every round together,
writes a diagnosis of at most ten lines, and may replace the approach inside the
brief. When the findings keep widening instead, after two rounds a finding
outside the pull request's lines that breaks no criterion becomes a follow-up
item (`add_item`) rather than another round; one that says a criterion is
broken, the verifier's or the reviewer's, always starts a round. Every round is written down where the next hand reads it:
the brief file `<wt gitdir>/loopable/brief.md` (the pack, with each round's
findings appended under `## Amendments`, which the builder re-reads before it
pushes and before it reports), and each run's reports copied to
`<wt gitdir>/loopable/rounds/<n>/` before the next `--prepare` clears them. The
reviewer reads a fix round's diff first, and earlier code blocks only for a
security or data-loss defect or a broken criterion.

**It surveys before it builds, when the brief names no paths.** A builder handed
only criteria starts from a cold repository, so for such an item the driver first
spawns `surveyor-<ref>`: read tools and Bash, no editor and no backlog tool, which
reads the pack, the items and decisions around it and the code, and writes
`<wt gitdir>/loopable/survey.md` in at most 40 lines — what to read first, the
likely paths each with a reason, the checks `AGENTS.md` names for them, the
risks, prior pull requests and open questions. The builder is handed its path
and reads it as a map, never as the contract. Adapted from the surveyor in
Avanti Studio's fountain plugin; `test.sh` holds its frontmatter, its missing
editor, its sections, and that the driver spawns it before the builder and
passes the path on.

**It cleans up after itself.** At the start and end of every session it removes
every worktree `git worktree list` shows — `.claude/worktrees/`,
`.loopable/worktrees/` or elsewhere — whose pull request is merged or closed,
whose tree is clean and whose head is the pull request's, then deletes their
branches in one `git branch -D`. Never `--force`: a tree git refuses has
something in it, and the person is told. Nor does an ignored file other than
dependencies and build output go silently: `git worktree remove` deletes a
`.env` without a word, so `git status --ignored` is read first and the person
is told.

**The ready gate binds it.** An agent token cannot set `ready`, so the driver
files work and then says which items need marking ready. That is the point
rather than a limitation: a person approves the work before an agent builds it.
A person may mint their token on `/tokens` with the grant to set `ready`,
`verifying` and `done` for them; the driver then sets one only when that person
asks for it in the session and names the items, never on its own.

**It never edits.** The lead that writes code stops judging it, so every change
is a `builder`'s, one per item, in that item's worktree — or, once escalated,
the `masterbuilder`'s, whose tool list `test.sh` holds to the builder's exactly. That is how the driver
works, not a tool taken away: it keeps Edit and Write, because a
`disallowedTools` list on the driver reaches the agents it spawns, and a
builder without an editor cannot build — `test.sh` goes red if the list comes
back. The builder's
tool list is editors and Bash, **no MCP and no Agent** — `start.sh` claimed the
item and `ship.sh` closes it, and a builder reporting on its own work is exactly
the sentence the close contract replaced. That takes the obvious paths away,
not every path: Bash could still run `gh pr merge` or `ship.sh`, so those rules
are the builder's to keep, and the merge guard is what holds if it does not —
no merge on a failed or moved head, and every other merge it lets through on
the record as `guard_allowed`. It commits and pushes
its branch, which `/loopable:ship` will not do for a person: starting the driver
is the person delegating that, and nothing reaches `main` past the verifier,
the reviewer and the guard.

**Its judgements are events in the session.** A builder started, a brief
defect, each fix round and the finding behind it, an escalation, a follow-up, a
stand-in, a merge and what ran after it, a worktree removed and a hand-off are
each a `post_activity` with the event in the `ref` — a fixed list of names and
fields in `skills/loopable/driver-events.md`, which `test.sh` holds the driver
to. A decision about a verdict comes after `ship.sh --close`, so it goes on the
session that closed with that verdict: its holder may still add to a closed
session's stream, and nothing about the ending moves. A refused start opens no
session, so `start_refused` is listed and not yet posted.

**Its memory is the backlog**, not a file of its own: status notes, sessions
and close contracts are what the next session reads. `test.sh` checks that every
script and agent the driver's prose names exists, because prose does not fail
when a script is renamed.

## What it will not catch

It cannot tell you named the wrong item, and it cannot make you create an item
for work that had none. It closes the gaps that actually bit — edited on main,
merged and never reported — and no more than that.

## Testing

`plugin/hooks/test.sh`, run by `guards` on every PR. `gh` and
`curl` are stubbed, the config file is a fixture, and the write guard runs
against a throwaway git repository it creates — no network, no token, no state
from this checkout. Half the cases assert a PASS, which is the half worth
having. Its last line is the count of cases it ran — read the count, not the
colour.
