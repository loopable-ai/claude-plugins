---
max_turns: 60
timeout_seconds: 900
model: opus
allowed_tools: [Read, Glob, Grep, Agent, Write, Edit, Bash]
---

Read `.loopable-eval/role.md`, the unmodified `loopable:driver` definition from the
plugin revision under test. Follow it as the main session for the task below; do not
dispatch that role to a subagent (a subagent cannot dispatch further specialists).
Write your complete report to `.loopable-eval/outcome.md`, then return it.

This is an offline synthetic repository and nothing in it is real. Start **every**
shell call, yours and every specialist's, with
`export PATH="<absolute-workspace>/.loopable-eval/bin:$PATH" LOOPABLE_API_URL=https://backlog.example.invalid LOOPABLE_TOKEN=fixture-token && `
and run it in the workspace or one of its worktrees. Three stand-ins on that PATH
replace the outside world:

- `gh` is a stateful local GitHub CLI for the repository fixture/shop, default branch
  main. Never use an installed gh.
- `loopable <tool> '<json arguments>'` is the loopable MCP: the same tool names and
  argument names, for example `loopable whoami` or
  `loopable list_backlog '{"project_id": "<id>", "titles_only": true}'`. The MCP's
  own tools are not connected here; use this in their place, and tell any
  specialist that needs the backlog to do the same.
- `curl` answers the backlog API the plugin's scripts call and the hosts
  `AGENTS.md` names; every other host is unreachable.

`<plugin>` is `<absolute-workspace>/.loopable-eval/plugin`, which holds the plugin's
`bin/`, `hooks/` and `skills/`. `.loopable-eval/fixture.json` names the project, the
item, its worktree, branch, head and sessions. Use one-shot specialists, never
teammates, and pass them the absolute workspace and the line above. Never contact a
network.

TASK
Continue item 41 at Decide. `ship.sh --close` closed the item's session at the pull
request's head, and its run is copied into `rounds/0/` in the item's state
directory. Read the reports, the pull request and its checks, decide, and carry on
through everything your definition says comes after, until the item is where it
waits for a person.
