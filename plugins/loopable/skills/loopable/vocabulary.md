<!--
THE ONE COPY. Edit this file and nothing else, then run:

    bin/sync-vocabulary.mjs

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

Loopable has six words for the shape of work, seven for what the product owner
proposes, escalates and remembers, and five for the machinery around it. They
are worth defining once because four readers use them at once — the product
owner writing a backlog, a person reading a roadmap, a coding agent picking
something up, and a client asking what is going on — and a word that means
four things is a word nobody can plan with.

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

A decision is a choice the project has made, with its reason attached, written
down once and changed only by superseding it.

**When.** Whenever the answer to "why is it like this?" would otherwise live
in somebody's memory or a chat thread.

**Not when.** Not work. A decision is never done, assigned or estimated.

**Why.** Decisions are insert-only on purpose. Editing one would rewrite the
past, and the reason to keep them is precisely that the past can be read
back: the product owner recites the ones that still stand, and a superseded
row stays visible as history.

## Draft

A draft is a proposal waiting in the approval queue, which becomes real only
when a person at the studio accepts it.

**When.** Whenever the product owner wants to change what the project holds:
a requirement somebody asked for, a decision somebody made out loud, a brief,
a commitment, a RAID entry, a piece of evidence, two items that are the same
work, an item that has gone quiet. Coding agents and members propose the same
way when the change is somebody else's to agree to.

**Not when.** Not for work the studio has already decided to do; a member
files that directly.

**Why.** The product owner never writes the plan or the registers itself. It
proposes, and a person accepts, rewords or declines with a reason. A decline
is kept, and when the ask came from a client's conversation the product owner
tells them it was declined and why.

## Escalation

An escalation is a question put in front of a person at the studio because it
is not the product owner's to answer.

**When.** The product owner raises one when it is asked about scope, schedule
or price, which it never promises, or when it does not know. It raises one
too when its own reply fails the check every reply goes through, and then it
tells the client "I will take this to the team and come back to you" instead
of sending it. A member or a coding agent raises one by asking the studio
something outside any conversation. The other direction is a chase: the
studio asking the client for something, which the client sees as something
the studio needs from them.

**Not when.** Not a request for work, which is a draft, and not a bug report.

**Why.** It is how "that is not mine to promise" ends in an answer instead of
a silence. A person resolves it, and the answer goes back into the same
conversation in the product owner's voice; one that is dismissed reaches
nobody. A client sees only the chases addressed to them, never the studio's
own escalations.

## Commitment

A commitment is a promise made on the project, with who made it, when it was
made and when it is due.

**When.** In either direction: a promise the studio owes the client, or one
the client owes the studio, which the studio may chase. It ends met or
withdrawn and is never deleted.

**Not when.** Not the work that keeps the promise. That is filed as work, and
the commitment says what was promised, not how.

**Why.** Promises made in a call are the first thing nobody remembers. A
client sees only the promises made to them, and only once their studio has
turned that on.

## RAID

RAID is the register of risks, assumptions, issues and dependencies: the
things that could change the plan without anybody choosing to.

**When.** Each entry has a severity, an owner who may be outside the studio,
and a date by which somebody looks at it again. Entries are mitigated and
closed, never deleted.

**Not when.** Not a bug, which is something already broken on a surface, and
not a task to fix one.

**Why.** A risk somebody saw and nobody wrote down becomes a surprise. Reviews
that come due land in front of the studio, and a client sees the register
only once their studio has turned it on.

## Evidence

Evidence is something the world said about the product, written down once and
tagged to the features it is about.

**When.** A client remark, a usage number, a support ticket, a signal from the
market. It is dismissed when it stops mattering, never deleted.

**Not when.** Not a request for work, which is a draft, and not an opinion
from inside the studio.

**Why.** What to build next should rest on what was observed, not on what
somebody remembers hearing. A client sees it only once their studio has
turned it on.

## Stakeholder

A stakeholder is a person who matters to the project, on the client's side,
the studio's or a third party's, with their role and how they expect to hear
about it.

**When.** For everybody whose say or whose silence would change the plan.

**Not when.** Not a login. A stakeholder is somebody the studio keeps in
mind, whether or not they ever sign in.

**Why.** The studio has to know who to keep informed and who decides. This
map is never shown to a client: a list of who matters is not shown to the
people on it.

## Digest

The digest is the product owner's weekly note to the client: a few plain
sentences about what moved, written into the client's open conversation.

**When.** Once a week, on Monday, read with exactly what the client is
allowed to see. A quiet week sends nothing, and so does a project with no
open conversation.

**Not when.** Not a report and not a promise: it names what happened and
never a date.

**Why.** A client should not have to ask to know where things are. The
product owner also looks at what moved twice a day, but that review only
proposes, into the approval queue, for a person to accept.

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

## Refs

A ref is the short name of a work item or a feature: a number the project hands
out once, like 41 or 7.

**When.** Whenever you need to name one thing to somebody else — in a chat, in
a stand-up, in a branch name, in a PR body, in a note on an activity. Across
projects, put the project key in front: `loop/41`.

**Not when.** Not as a title. A ref says which thing, never what it is, so a
sentence that is only refs is a sentence nobody can read.

**Why.** One counter per project serves both planes, so the number alone names
exactly one thing — a work item and a feature can never wear the same number,
and there is nothing left for a letter to disambiguate. Refs used to carry one
(`s41`, `f7`); it was a hint about the kind, and a hint that survives writing
but not speech, a search box or the middle of a branch name is one more thing
to get wrong. The old spellings are still understood wherever a ref is
accepted, because a name that stops working is not a name; nothing writes them
any more. A number is never reused, so a ref written down a year ago still
points where it pointed. The uuid is still there and still works; it is simply
not a name.

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
