---
description: Start work on a Loopable item — pull its brief pack, refuse it if it is not ready, make the worktree from origin/main, report in_progress, open the session.
argument-hint: <item id | ref | next>
---

Run this once, exactly as written, and do nothing before it:

```bash
"${CLAUDE_PLUGIN_ROOT}/bin/start.sh" $ARGUMENTS
```

If `$CLAUDE_PLUGIN_ROOT` is empty in that shell, find the loopable plugin
directory — the one holding `hooks/`, `commands/` and `bin/` — and run
`bin/start.sh` from there instead. Run it once either way.

If it exits non-zero it has refused, and nothing was created or reported: say
what it said — the blockers are the answer — and stop. Do not make a branch, a
worktree or a report by hand instead.

If it succeeds it has printed the brief pack: the item, its acceptance criteria,
one hop of the graph by title, the decisions that govern it, and where to point.
Read that, then begin the work in the worktree it names, building to the criteria
rather than to the title. The item is already reported `in_progress` and the
session is already open — do not report either again.
