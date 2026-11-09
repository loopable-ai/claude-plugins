---
description: Finish a Loopable item — check the branch, run the verifier and the reviewer, open the pull request naming the item, close the session with the contract and that url.
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
Under the driver that decision is made: starting it delegated the push to the
builder, so a refusal goes back to the builder.

A script that **breaks** instead — fails at its own job, naming nothing about the
branch — is not a refusal. Do the steps it did not, in its order and with its
refusals, and never redo one it finished: for `--prepare`, the same three checks,
`open_session` when the one on record has closed, and the last run's reports
cleared from `.git/loopable/`. For `--close`, every step it takes, because a
closed session never takes anything afterwards, the pull request's link
included:

1. the report's criteria mapped onto the brief's by their words, refusing the
   close when one is missing;
2. `verify.md`, `review.md` and every cited screenshot uploaded as session
   attachments (request, presigned POST, confirm), the screenshots' ids kept for
   `screenshot_ids`;
3. what the pull request gets, as the script writes it (its file when it got
   that far): the not-verified banner unless the verdict is `pass`, the criteria
   as a checklist, the verdict and reason, and the reviewer's last line — always
   as a comment naming the commit (`.git/loopable/pr-comment.md`); a new pull
   request's body (`.git/loopable/pr-body.md`) is only the ask, a line saying
   the verification is in the newest comment, and `Loopable: <ref>`;
4. the pull request — only an OPEN one for this branch counts
   (`gh pr list --head <branch> --state open`); with none, `gh pr create
   --draft` with that body first. On it, `gh pr comment` with that comment, and
   `gh pr ready` only on a `pass` — a `fail` or `not_run` leaves it a draft.
   Never an edit of its title or body. A merged or closed one is never this
   close's link;
5. `close_session` with the whole contract — brief revision, HEAD sha, the
   verdict and reason exactly as `verify.json` has them, every criterion with
   `implemented_at` and its status, `screenshot_ids`, the cost, and `pr_url`.

Then file the bug with `add_item` first, so its ref is real, and say what you
did as a `post_activity` on the session, naming that ref — the driver posts it as
`stood_in`. A step you could not do goes in that activity too.

A session closes once, so a run after a `fail` or `not_run` close needs a new
one. `--prepare` handles it: when the session on record is closed, it opens the
next on the same item, harness, repo and branch, records it, and says so in one
line. Never open one by hand — unless `--prepare` broke before it did, which is
the stand-in above.

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
  the default branch, and in a fix round the sha the last review was made at and
  that review's path, so it reads what the round changed first. It writes
  `.git/loopable/review.md`.

Do not summarise the implementation for either of them, do not tell them what
works, and do not edit what they return. A report you corrected is your report.

**3. Close.** Run this once:

```bash
"${CLAUDE_PLUGIN_ROOT}/bin/ship.sh" --close
```

It reads the two reports, attaches them and the screenshots to the Loopable
session, and finishes the pull request. When the branch already has one — the
draft a builder opens on its first push — it posts the verification and the
review on it as one comment, and never edits its title or body. When it has
none, it opens one as a draft, whose body is the ask, a line pointing at the
newest comment and `Loopable: <ref>`, and posts the same comment on it. Only a
`pass` runs `gh pr ready`; on `fail` or `not_run` the pull request stays a
draft. Then it closes the session with the contract — brief revision,
HEAD sha, verdict and reason, every criterion with where it landed and whether
it is met, the screenshot ids, the cost, and that pull request's url. The pull
request comes first because a closed session is never updated again, so the
close is the only moment the link can be recorded. The close moves the item to
`in_review` by itself: **do not report progress again afterwards.**

Pass `--trailer '<line>'` when this harness has a session link the repository
puts at the end of a pull request body; it becomes the last line.

If the verdict is `fail` or `not_run`, `--close` still closes — the contract wants
the truth — the pull request says so, and the script exits 1. That is not an
error to work around: fix what the report names, commit, push, and run
`/loopable:ship` again. The merge guard refuses the merge while the close at the
commit being merged says `fail`, or when the branch moved after the close; a
`not_run` goes through only with a warning on the record.

The next `--prepare` clears this run's reports. When the rounds matter — the
driver keeps every one — copy `verify.json`, `verify.md` and `review.md` into
`.git/loopable/rounds/<n>/` first, with the HEAD sha in `rounds/<n>/head`: the
next review starts from that sha, and a master builder reads every round.
