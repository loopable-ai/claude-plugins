---
description: Start work on a Loopable item — pull its brief pack, refuse it only if somebody else holds it or it is finished (readiness is warned, never refused), make the worktree from origin/main, report in_progress, open the session.
argument-hint: <item id | ref | next>
---

Run this once, exactly as written, and do nothing before it:

```bash
"${CLAUDE_PLUGIN_ROOT}/bin/start.sh" $ARGUMENTS
```

If `$CLAUDE_PLUGIN_ROOT` is empty in that shell, find the loopable plugin
directory — the one holding `hooks/`, `commands/` and `bin/` — and run
`bin/start.sh` from there instead. Run it once either way.

If it exits non-zero, read what it said; it is one of two things.

- **A refusal** names a blocker about the item — another session holds it, it
  is finished, its branch already exists — and nothing is left behind or
  reported: what a failed start made, it takes back, and says so. Say it, and
  the item starts once that is done (the holder finishes). Never make a branch,
  a worktree or a report past a refusal. Readiness is never a refusal: its
  blockers are printed as warnings and posted on the session.
- **A breakage** is the script failing at its own job: an error that names
  nothing about the item, or a step it says it could not finish. Do the steps it
  did not, in its order, and nothing it would have refused: `pull_item` first,
  and an item somebody else holds is still refused; then the worktree by the
  repository's `start:` line, `report_progress` `in_progress`, `open_session`,
  and the ids into `.git/loopable/`. Never redo a step it finished. Then file
  the bug with `add_item` first, so its ref is real, and say what you did as a
  `post_activity` on the session, naming that ref — the driver posts it as
  `stood_in`.

If it succeeds it has printed the brief pack: the item, its acceptance criteria,
one hop of the graph by title, the decisions that govern it, and where to point.
Read that, then begin the work in the worktree it names, building to the criteria
rather than to the title. The item is already reported `in_progress` and the
session is already open — do not report either again.
