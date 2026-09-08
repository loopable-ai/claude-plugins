<!--
THE ONE COPY. Edit this file and nothing else, then run:

    apps/loopable/bin/sync-vocabulary.mjs

which writes the byte-identical copies the code actually reads — api/lib/
vocabulary.md (the container image only carries what is under api/), plugin/
skills/loopable/vocabulary.md (the release copies plugin/ wholesale) — and
regenerates the prompt section, the Help page's definitions and the prompt
fixture from it. api/test/vocabulary.test.mjs fails when any of them drifts.

The shape is load-bearing: each term is an `## H2`, and the first sentence of
the paragraph under it is the definition every other reader quotes. Write that
sentence so a client can read it on its own.
-->

# The words we use

Loopable has six words for the shape of work and four for the machinery
around it. They are worth defining once because four readers use them at
once — the product owner writing a backlog, a person reading a roadmap, a
coding agent picking something up, and a client asking what is going on —
and a word that means four things is a word nobody can plan with.

Two planes run through all of it. **Features are the nouns**: the surfaces of
the product, which are never finished. **Work items are the verbs**: the
things that happen to those surfaces, which are. Tags join them.

## Feature

A feature is a part of the product a person can point at — a page, a flow, a
report, an integration.

**When.** Whenever there is a surface somebody could name and ask about. It
carries a lifecycle rather than a finish line: proposed, then building, then
live, and it stays live while work keeps happening to it. It leaves only by
decision — retired when it is switched off, superseded when another feature
answers the same need and names it.

**Not when.** Not for a piece of work, however large. An epic that never ends
is a feature that was written down as work.

**Why.** A client asks "how is billing going?", not "how is item 41 going?".
Features are what the question is about, and the answer is the work tagged
with them. Only people write a feature; an agent proposes one and a person
accepts it.

## Epic

An epic is an outcome, not a bucket: something the client would notice and
could name, like "clients can approve from email".

**When.** Weeks of work, not days, with stories under it. Its status is meant
to follow its stories'.

**Not when.** Not a pile of unrelated chores, not a sprint, not one person's
list, and not a feature in disguise — if it can never be finished, it is a
surface and belongs on the other plane.

**Why.** The roadmap is read by people who do not read the backlog. An epic is
the unit they read, so it has to be a sentence about them and not about us.

## Story

A story is one change a person can see or verify when it lands: a screen
behaves differently, a route exists, a report says something new.

**When.** Days, not weeks. It carries what done looks like, and, where it
adds a guard, how to sabotage that guard.

**Not when.** Not a step nobody outside the code could observe — that is a
task. Not a whole outcome — that is an epic.

**Why.** A story is the unit everything else hangs on: the PR names it, the
person accepting the work verifies it, and the pair of people and agents
working on it are measured by it. Make it bigger and none of those three can
be done honestly.

## Task

A task is a step with no user-visible outcome of its own: a migration, a
refactor, a configuration change, a chore.

**When.** Under a story, or straight under an epic — levels may be skipped.

**Not when.** Not for anything the client would ask about. If they would, it
is a story, so that it shows up on the roadmap. A task with no parent at all
is legal but a smell: nobody outside the code can see why it exists.

**Why.** Work that nobody outside the team can observe still has to be
written down, and calling it a story would put noise on the roadmap.

## Bug

A bug is something that worked and does not, on a surface that already
exists.

**When.** With `feature_ids` naming the surface that is broken. It stands
alone: no parent, no children.

**Not when.** Not for a missing thing that was never promised — that is a
story, or an ask for one.

**Why.** A bug is about what IS; an epic is about what WILL BE. Nesting one
inside the other puts two tenses in the same tree, and the roadmap stops
being readable. That is why bug is absent from the rank order rather than
placed somewhere in it.

## Decision

A decision is a commitment with a reason attached, written down once and
changed only by superseding it.

**When.** Whenever the answer to "why is it like this?" would otherwise live
in somebody's memory or a chat thread.

**Not when.** Not work. A decision is never done, assigned or estimated.

**Why.** Decisions are insert-only on purpose. Editing one would rewrite the
past, and the reason to keep them is precisely that the past can be read
back: the product owner recites the ones that still stand, and a superseded
row stays visible as history.

## Session

A session is one harness — a coding agent and the person with it — sitting
on one work item, from the moment it picks the item up to the moment it hands
it back.

**When.** Opened and closed through the plugin, never by hand. Its activities
are what happened inside it.

**Not when.** Not a sprint, not a meeting, and not a unit of work: an item may
take several sessions, and a session touches exactly one item.

**Why.** Without it, "in progress" means an item nobody has picked up and an
item being written at this second, and the product owner cannot tell a client
which one it is looking at.

## Brief

A brief is what a work item says: the ask in the words it was asked in, and
the acceptance criteria, each saying how it will be checked.

**When.** On a story, a task or a bug — the things somebody builds.

**Not when.** Never on an epic, which is a container rather than a thing to
build.

**Why.** A criterion nobody wrote down is a criterion nobody checks. Rewriting
a brief makes a new revision; ticking a criterion off as the work happens does
not, because reporting progress is not changing the spec.

## Environment

An environment is a place the built thing actually runs, registered against
the project so that a claim about it can be checked.

**When.** Wherever a person or a check needs a URL to look at — a preview, a
staging deployment, production.

**Not when.** Not a branch, and not a machine. It is the address, and what is
supposed to be true at it.

**Why.** "It works" is not evidence. An environment gives a criterion
somewhere to be verified, which is what separates a report of progress from a
demonstration of it.

## States

A state says where an item is right now — not how good it is, and not whose
fault anything is.

- **todo** — nobody has started; it may not even be fit to start.
- **ready** — groomed: criteria somebody could act on, and somewhere to run it.
- **in_progress** — somebody or something is working on it.
- **in_review** — the work is written and a person has to read it.
- **verifying** — merged and deployed; the checks are running.
- **done** — accepted by a person.
- **blocked** — waiting on something else in the world.
- **awaiting_input** — waiting on an answer from a person.
- **dropped** — closed without being done: a duplicate, or something no longer
  worth doing.

The first six are a road and the last three are places to stand. Who may take
which step is not the same question: a person may take any of them, and an
agent may report its way to `in_review` and no further — it does not groom
its own work, it does not decide that a deploy happened, and it does not
accept what it built. That table is `TRANSITIONS` in `api/lib/work-items.mjs`.

## The rank rule

Epic outranks story outranks task, a parent must outrank its child, levels
may be skipped, and a bug sits outside the ranks entirely: no parent, no
children.

Skipping is allowed because a task under an epic is a real situation and
inventing a story to hold it would be paperwork. The direction never moves:
nothing puts an epic under a task. Bug is not ranked low, it is not ranked at
all — a kind absent from the order loses every comparison, which is exactly
the rule "no parent, no children" written as an absence.

## The rule of thumb

If you cannot say what a person will see when it lands, it is not a story; if
you cannot say what the client would call it, it is not an epic.

Everything else follows. What is left over when both tests fail is a task,
unless something that used to work has stopped, in which case it is a bug.
