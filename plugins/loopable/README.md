# The loopable plugin

Keeps a repository and the Loopable backlog telling the same story.

A repository names its project in `.loopable.yaml` at the root (see the skill
for the three keys). From then on six hooks apply, each doing one mechanical
thing — anything needing judgement is a skill, not a hook:

| hook | event | |
|---|---|---|
| `open-work.sh` | SessionStart | Lists what is in progress before there is anything to interrupt. The half a merge guard cannot fix: nothing stops a session simply not knowing the backlog exists. |
| `session-start.sh` | SessionStart | Opens — or resumes — the session for the item this branch is working, so the console shows a harness at work without anybody remembering to say so. |
| `tool-use.sh` | PostToolUse | Reports a created PR at once, and batches everything else into one `action` activity. |
| `stop.sh` | Stop | One `result` activity saying where this stretch got to. It does not close the session. |
| `guard-main.sh` | PreToolUse Edit/Write | Refuses an edit **on `main`** to a tracked path, and prints how a branch is started here. One worktree per item is what lets several agents share one repository. |
| `guard-merge.sh` | PreToolUse Bash | Refuses `gh pr merge` for a PR that touches a tracked path and names no work item, or names one the backlog still calls `todo`. |

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
the state file a previous hook wrote; a short id at the end of the branch name
(`<kind>/<slug>-<shortid>`, which is how `/loopable:start` names them); or the
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

## Naming the item

```
Loopable: 4e90ea71-bc6a-445d-8517-f732d064a1f5
Loopable: none — a platform change with nothing in the backlog yet
```

`none` is an escape hatch on purpose, and a visible one: a stated exception can
be argued with in review, and silence cannot.

## Three security rounds, and what they say

The merge guard is about two hundred lines of shell against attacker-shaped
input, and three separate reviews each found something the last one's tests
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

The honest conclusion: guards written in shell against attacker-shaped input
want adversarial review every time they change, not once.

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
