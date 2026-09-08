# claude-plugins

Claude Code plugins for [Loopable](https://loopable.ai), the AI product owner
for software studios and their clients.

| Plugin | Purpose |
|--------|---------|
| [`loopable`](plugins/loopable/) | The Loopable backlog, wired into how a repository is worked: what is in progress arrives at session start, an edit on `main` to a tracked path is refused, and tracked work cannot be merged without naming its item |

## Install

```bash
claude plugin marketplace add loopable-ai/claude-plugins
claude plugin install loopable@loopable-ai
```

Then, in each repository that belongs to a Loopable project, a `.loopable.yaml`
at the root:

```yaml
project: <project id, from the MCP's whoami>
paths:                      # optional — only these must name a work item
  - apps/loopable
start: make branch NAME=<slug>   # optional — printed when an edit on main is refused
```

The agent token goes in `~/.config/loopable/token` (mode 0600). Nothing in the
plugin holds a secret.

## Where the source lives

This repository is a release mirror. The plugin is developed and tested in the
application's own repository and published here on each release, so a change
lands as one commit with its version. Issues are welcome here.
