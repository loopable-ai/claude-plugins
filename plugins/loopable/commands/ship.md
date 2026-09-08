---
description: Finish a Loopable item — check the branch, run the verifier and the reviewer, post the close contract, open the pull request naming the item.
argument-hint: "[nothing]"
---

Three steps, in this order, and nothing between them.

**1. Prepare.** Run this once:

```bash
"${CLAUDE_PLUGIN_ROOT}/bin/ship.sh" --prepare
```

If `$CLAUDE_PLUGIN_ROOT` is empty in that shell, find the loopable plugin
directory — the one holding `hooks/`, `commands/`, `agents/` and `bin/` — and run
`bin/ship.sh` from there instead.

If it exits non-zero it has refused, and nothing has been reported: say what it
said and stop. It refuses a worktree with no session (`/loopable:start` first), an
uncommitted tree, and a branch that is not pushed — each with the command to run.
Run that command, then `/loopable:ship` again. **Never** commit or push on your
own initiative to get past it; the person decides when work leaves the machine.

If it succeeds it has printed the item, the acceptance criteria with their verify
methods, the environments, the HEAD sha and where the two reports go. That
printout is the input to step 2.

**2. Run both agents.** Dispatch them with the Agent tool, in parallel, and do
neither job yourself:

- the **verifier** (`loopable:verifier`) — give it the criteria with their verify
  methods, the environments, the HEAD sha and the evidence directory, all from
  step 1, and the instruction that every status must come from a run at that sha.
  It writes `.git/loopable/verify.json` and `.git/loopable/verify.md`.
- the **reviewer** (`loopable:reviewer`) — give it the criteria, the HEAD sha and
  the default branch. It writes `.git/loopable/review.md`.

Do not summarise the implementation for either of them, do not tell them what
works, and do not edit what they return. A report you corrected is your report.

**3. Close.** Run this once:

```bash
"${CLAUDE_PLUGIN_ROOT}/bin/ship.sh" --close
```

It reads the two reports, attaches them and the screenshots to the Loopable
session, posts the close contract — brief revision, HEAD sha, verdict and reason,
every criterion with where it landed and whether it is met, the screenshot ids
and the cost — and opens the pull request with the criteria checklist and
`Loopable: <ref>` in its body. The close moves the item to `in_review` by itself:
**do not report progress again afterwards.**

Pass `--trailer '<line>'` when this harness has a session link the repository
puts at the end of a pull request body; it becomes the last line.

If the verdict is `fail` or `not_run`, `--close` still closes — the contract wants
the truth — the pull request says so, and the script exits 1. That is not an
error to work around: fix what the report names, commit, push, and run
`/loopable:ship` again. The merge guard refuses the merge until a session closes
`pass` at the commit being merged.
