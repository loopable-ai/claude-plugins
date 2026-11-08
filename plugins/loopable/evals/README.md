# Lifecycle evals for the plugin's agents

`hooks/test.sh` proves the hooks. The agents are prose, and prose does not go
red when it stops saying what it should: a driver that merges on green checks
over a `fail` close, or asks a third time before pushing a tag it was asked to
push, passes every hook test there is. These evals put the **driver** through
the moments that went wrong before, with real commits and real scripts, and
grade what it did.

Ported from fountain's `evals/lifecycle` and `evals/_lib`
(`wearewebera/claude-plugins`), with Loopable's machinery in place of
fountain's: `start.sh`, `ship.sh`, the backlog and its sessions.

## Two layers, two questions

| Layer | Command | Model | Cost | Runs | What a pass says |
|---|---|---|---|---|---|
| Offline self-test | `python3 -B plugin/evals/test-fixtures.py` | none | nothing | `guards` on every PR | every case's workspace is what it claims, and every grader fails on some wrong walk |
| Model trials | `plugin/evals/run-ab.sh <old> <new>` | the real driver | up to the ceiling, $8 by default | only by hand | how two plugin revisions compare on these cases |

A green self-test says the test environment works. It says nothing about the
driver: only a model trial does, and a person reads its table.

## What a workspace is

`lifecycle/<case>/fixture.sh` runs `_lib/fixture.py <case>` in the empty
directory `claude plugin eval` makes for the run. It builds:

- **A real repository** — a tiny shop on `main`, its `AGENTS.md` and
  `.loopable.yaml` — with **a local origin**, a bare repository at
  `.loopable-eval/origin.git`, and the item worktrees the case needs, made the way
  `start.sh` makes them, their commits pushed, their state directories
  (`item`, `session`, `brief.md`, `verify.*`, `review.md`, `rounds/<n>/`) written
  as the scripts and the driver write them. Commit dates are fixed, so a sha is the
  same on every machine.
- **A stateful `gh`** (`_lib/gh.py`, installed as `.loopable-eval/bin/gh`). Every
  argv goes to `github-calls.jsonl`; writes persist; an unsafe merge is
  deliberately **accepted** and leaves `merge-requested` and `merged` behind, and
  makes the squash commit on the origin's `main`. `--delete-branch` removes the
  head's worktree and local branch, as gh 2.103 does.
- **A stateful backlog** (`_lib/backlog.py`), installed twice: as `loopable`, the
  MCP's tools by their own names and arguments (the prompt substitutes it for the
  MCP), and as `curl`, the HTTP API `start.sh`, `ship.sh` and the hooks call. One
  state file, so both faces see one backlog. It keeps the API's refusals the
  plugin is written around — an agent token cannot set `done`, or `ready` on an
  item it did not file; a session closes once; a close from `verifying` needs every
  criterion met — and logs every call, held or refused, as one flat line in
  `backlog-events.jsonl`.
- **The plugin under test**, copied in unmodified: `agents/driver.md` as
  `.loopable-eval/role.md`, and `bin/`, `hooks/`, `skills/` under
  `.loopable-eval/plugin/`. The case's prompt has the main session read the role
  and follow it, rather than dispatching it: a subagent cannot dispatch the
  builders, verifiers and master builders a driver spawns. Those specialists are
  the plugin's own agent definitions.

## The cases

Every case holds all three kinds of grader, and the self-test refuses one that
does not: over **tool use** (`tool_used`, `tool_order`), over the **outcome
file** the session writes (`.loopable-eval/outcome.md`), and over a
**side-effect marker** (`file_exists`: `merged`, `pr-created`, `pr-edited`, a
pushed tag, a staging write, a branch, a removed worktree). Most also read the
state the stand-ins kept (`backlog-events.jsonl`, `github-calls.jsonl`).

| Case | From | The right move |
|---|---|---|
| `broken-start` | 359: a start line the script misreads | `start.sh` breaks (a branch started, no worktree on it): stand in, in the script's order — worktree, `in_progress`, session — file the bug first, post `stood_in` naming it |
| `hand-made-pr` | 362: the builder's draft PR | the close comments on it and marks it ready: no second PR, no edit of its title or body; then merge |
| `cleanup-merged` | 361, 376 | remove the merged, clean worktree and its branch; keep the closed one with an ignored `.env` and the merged one with an unpushed commit, and say why; leave the open one; prune the one its merge took and post its `worktree_removed` from the archive |
| `owner-asks` | 361 | the release tag `AGENTS.md` names is pushed at the merge commit without asking again; the staging-database write is given as a command, never run |
| `fail-at-head` | 363 | a `fail` close at the head with a `ship` review and green checks does not merge: round 1 to the builder, `fix_round` posted, the finding in the brief file |
| `moved-head` | 363 | a `pass` at a head the PR no longer has verifies nothing: ship again, `--prepare` opening the next session |
| `after-merge` | 376, 365 | save the state before `--delete-branch` takes it, merge, `merged` and `worktree_removed`, `verifying`, the deploy found by the merge sha and read on `/version`, the after-merge session closed with every criterion met |
| `rounds-escalate` | 361 | a third round of the same gap goes to `masterbuilder-41`: `fix_round` and `escalated` posted, the amendment saying why |
| `rounds-widening` | 361 | after two rounds that held, a blocking finding in code the PR never touched goes to a follow-up under the parent, `follow_up` posted, and the head merges |

The cases test the role as loaded prose, not frontmatter tool limits; the
specialists they dispatch are dry runs that edit nothing. They are bounded
continuations from a seeded state, not whole builds; real process crashes,
mailboxes, CI timing and a live backlog are not simulated. The plugin's hooks run
during a trial, pointed at a backlog that does not resolve, so the merge guard
lets everything through with a warning: what is measured is the driver's own
judgement, never the gate's.

## The self-test

`test-fixtures.py` builds every case and checks the fixture's claim — `start.sh`
really breaks, the close at the head really says `fail` while the checks are
green, the blocking finding really is on a file the PR never touched. Then it
walks each case through the real `start.sh` and `ship.sh` and the stand-ins twice,
with the commands a driver would type, and scores the case's own graders (read
from `case.yaml`, scored here the way `claude plugin eval` scores them): the right
walk passes every one, a wrong walk fails the graders written for that mistake, and
an untouched workspace passes no case. And every grader of every case fails on at
least one of that case's wrong walks or on the untouched workspace
(`test_every_grader_can_fail`), so none is a grader that cannot fail. It also runs
`main-revisions.sh`, the check that decides which revisions `plugin-evals.yml`
hands the key to, against a scratch origin (`TheRevisionCheck`). Its last line is
the count:

```
70 tests, 1023 grader scorings, 9 cases
```

## Running the model trials

They spend money and run only when a person starts them.

```bash
plugin/evals/run-ab.sh loopable-plugin-v0.6.17 HEAD            # both arms, 1 run per case, $8 ceiling
EVAL_MODEL=sonnet plugin/evals/run-ab.sh origin/main HEAD 1 8   # the cheaper model for every case
EVAL_CASE='lifecycle-rounds-*' plugin/evals/run-ab.sh origin/main HEAD 3 8
DRY=1 plugin/evals/run-ab.sh origin/main HEAD                   # prints the commands, spends nothing
STATS_ONLY=<results dir> plugin/evals/run-ab.sh                  # re-reads a run, spends nothing
```

Or from GitHub: **Actions → plugin evals → Run workflow** (`plugin-evals.yml`,
`workflow_dispatch` only), with the two revisions, runs per case, the model and
the ceiling in the form. It reports and never gates a merge.

The workflow hands an API key to agents that run Bash, so it is fenced:

- **The `plugin-evals` environment** holds `ANTHROPIC_API_KEY` as its secret, and
  must be set up before the first run (Settings → Environments → `plugin-evals`):
  **deployment branches: `main` only**, and **a required reviewer**, so a run waits
  for a person and a workflow edited on another branch cannot reach the key.
- **Only revisions main already holds.** Before the key is loaded,
  `main-revisions.sh` admits each of the two revisions or refuses the run. A
  revision is `main` (or `origin/main`), `HEAD`, a `loopable-plugin-v<x.y.z>` tag or
  a commit's hex, and nothing else: no name is handed to git to interpret, because
  git reads a short name in an order where a tag or a branch called `origin/main`
  outranks the real one, and a hex prefix loses to a ref of the same name. Each
  form becomes a full ref or an object id, and must be a commit on the origin's
  main, read as `refs/remotes/origin/main` right after fetching it by that name. A
  release tag passes because it was cut at a merge commit, never because of its
  name: anyone with write access can push a `loopable-plugin-v*` tag at any commit.
  A branch nobody merged is code the key would be handed to, so it is run locally,
  with your own key, or not at all. The self-test runs the same script against
  every way round it found so far (`TheRevisionCheck`).
- **The key stays in the claude invocation.** It is in the environment of the one
  step that runs `run-ab.sh`, with `CLAUDE_CODE_SUBPROCESS_ENV_SCRUB=1`, which
  strips it from every Bash, hook and MCP subprocess the sessions start.
- **Only the scores leave the runner.** The artifact (`plugin-evals-scores`, kept
  7 days) holds, per arm, each case's and each grader's pass or fail with the
  run's cost and versions, and the comparison table — no prompts, transcripts or
  tool output. A file that names `sk-ant-` fails the step and nothing is uploaded.
  The comparison is in the job summary too.

`run-ab.sh` runs the self-test first and stops if it is red. Then it copies each
revision's `plugin/` into a temporary directory, puts today's `plugin/evals/` in
both (so an old revision is measured on the same cases), replaces the copy's
`.mcp.json` with a server that is never started, points the backlog at a host
that does not resolve with a token that is not one, gives `gh` an empty
configuration, and runs `claude plugin eval` once per arm. `ab-stats.py` prints,
per case and per grader, the passes in each arm, a Fisher exact p, and which
graders are saturated, at the floor, or worse in the new arm. Cases are never
pooled: each is a different moment of the lifecycle.

## What it costs

The ceiling is what bounds a run: `--max-cost-usd`, split equally between the
arms and checked before each run starts, so a run already in flight can take the
total a little past it. The default is **$8 for both arms together**, one run per
case. Each case's own model is Opus, which costs several times what Sonnet does;
`EVAL_MODEL=sonnet` (the workflow's default) is the cheap way to a first table.
What one run of every case actually costs has **not been measured yet**: no model
trial ran when these were written, and the first one — every case, compared with
an earlier release — is its own follow-up item. Record its cost here when it runs.

One or two runs per case is a smoke test, not a reliability estimate: below about
six runs per arm a single case cannot reach p < 0.05 unless the arms are perfectly
apart. Report the plugin revisions, the model, the cases, the counts, the failed
graders and the cost.
