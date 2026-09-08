# The loopable plugin

Keeps a repository and the Loopable backlog telling the same story.

A repository names its project in `.loopable.yaml` at the root (see the skill
for the three keys). From then on three hooks apply, each doing one mechanical
thing — anything needing judgement is a skill, not a hook:

| hook | event | |
|---|---|---|
| `open-work.sh` | SessionStart | Lists what is in progress before there is anything to interrupt. The half a merge guard cannot fix: nothing stops a session simply not knowing the backlog exists. |
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

## Every failure is a pass

No token, no network, a sleeping database, an id the token cannot see, no git,
a detached HEAD — all pass. A guard speaks only on a confident negative: the
backlog answered and the answer was no; the branch is `main` and the path is
tracked. The reason matters more than being thorough:

> A hook that fires during ordinary work gets switched off.

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
