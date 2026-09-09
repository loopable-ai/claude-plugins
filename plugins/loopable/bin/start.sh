#!/usr/bin/env bash
# /loopable:start — the whole start sequence, as ONE script.
#
#   start.sh <item id | ref | next>
#
# Pull the item's brief pack; refuse anything that is not `ready` and say what
# is missing; make the worktree from `origin/main`; report `in_progress`; open
# the session; print the pack.
#
# WHY A SCRIPT AND NOT A PROMPT. The command file beside this one
# (`commands/start.md`) is four lines long on purpose: it says run this, then
# read what it printed. Every step below is a step that must happen in this
# order, every time, whatever else is in the context — and a model asked to
# remember six steps will one day do five of them, most likely dropping the
# readiness refusal, which is the one with a person's judgement behind it. So
# the sequence is code and the model's part is the part that needs a model.
#
# A COMMAND IS NOT A HOOK, and everything about the failure discipline is
# inverted here. A hook fails silently because nobody asked it to run; this was
# asked for by name, and a person waiting for a worktree needs to be told when
# there is no worktree. So: every failure prints a sentence and exits non-zero,
# nothing is guessed at, and the readiness refusal is a refusal rather than a
# warning. `--max-time` grows too (LOOPABLE_MAX_TIME in lib.sh) — waiting eight
# seconds for a sleeping database is fine for a command somebody typed.
#
# ORDER MATTERS, and it is: read, refuse, create, claim, open. The claim comes
# AFTER the worktree because an item reported `in_progress` with no branch
# under it is a lie the console shows to everyone; the session comes after the
# claim because a session is opened on work somebody has taken.
#
# NOTHING IS EVER UNDONE. If the claim or the session fails the worktree stands
# and the script says so — removing a worktree is the one thing this plugin
# does not do, anywhere, and a half-finished start is recoverable by hand while
# a deleted branch is not.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
. "$HERE/../hooks/lib.sh"

# Long enough for a cold Aurora, short enough that a person does not wonder.
LOOPABLE_MAX_TIME="${LOOPABLE_MAX_TIME:-20}"

say() { printf '%s\n' "$*"; }
die() { printf '%s\n' "$*" >&2; exit 1; }

ARG="${1:-}"
[ -n "$ARG" ] || die "Which item? Usage: /loopable:start <item id | ref | next>"

command -v jq  >/dev/null 2>&1 || die "jq is needed to read the brief pack, and is not on PATH."
command -v git >/dev/null 2>&1 || die "git is needed to make the worktree, and is not on PATH."
[ -n "$(loopable_token)" ] || die \
  "No Loopable token. Put one at ~/.config/loopable/token (0600), or set LOOPABLE_TOKEN."

REPO=$(loopable_repo) && [ -n "$REPO" ] ||
  die "Not inside a git repository, so there is nowhere to make a worktree."
loopable_config_file >/dev/null 2>&1 ||
  die "No .loopable.yaml at $REPO — this repository has not said which Loopable project it
belongs to, so there is no backlog to start from. Add one:

  project: <project id, from whoami>
  paths:
    - <a directory whose PRs must name a work item>
  start: <how a branch is started here>"

PROJECT=$(loopable_project) || die \
  "Cannot tell which project this repository belongs to: no \`project:\` in .loopable.yaml,
and this token can see more than one. Name it in the config."

# ------------------------------------------------------------- 1. the pack --
#
# `next` asks the backlog to choose; anything else is a reference to resolve —
# a full id, or the prefix/short id `loopable_resolve_ref` understands. The
# resolution lives in lib.sh, once, so that the day a ref gains a new spelling
# (S1.10) this file does not have to learn it.
if [ "$ARG" = next ] || [ "$ARG" = --next ]; then
  ANSWER=$(loopable_get "/agent/projects/$PROJECT/items/next-ready") || die \
    "The backlog did not answer $LOOPABLE_API. Nothing has been created or reported."
  PACK=$(printf '%s' "$ANSWER" | jq -c '.pack // empty' 2>/dev/null)
  [ -n "$PACK" ] || die \
    "Nothing to pick up: no item is \`ready\` and free right now. Everything ready is
already being worked, or nothing has been groomed yet. Name an item instead, or ask
the product owner to groom the backlog."
else
  ITEMS=$(loopable_items) || die \
    "The backlog did not answer $LOOPABLE_API. Nothing has been created or reported."
  ITEM_ID=$(loopable_resolve_ref "$ARG" "$ITEMS") || die \
    "No item in this project answers to '$(loopable_safe "$ARG")' — an id this token cannot see,
or a prefix that matches more than one. Use the full id."
  ANSWER=$(loopable_get "/agent/projects/$PROJECT/items/$ITEM_ID/pack") || die \
    "The backlog did not answer for $ITEM_ID. Nothing has been created or reported."
  PACK=$(printf '%s' "$ANSWER" | jq -c '.pack // empty' 2>/dev/null)
  [ -n "$PACK" ] || die "The pack for $ITEM_ID came back empty. Nothing has been created or reported."
fi

field() { printf '%s' "$PACK" | jq -r "$1 // empty"; }
ITEM_ID=$(field '.item.id')
KIND=$(field '.item.kind')
TITLE=$(field '.item.title')
STATUS=$(field '.item.status')
NOTE=$(field '.item.status_note')
# The item's ref — a plain number — when it carries one; the head of the uuid
# until then.
# Read rather than derived, so that the day items have refs the branch names
# start using them with no edit here.
REF=$(field '.item.ref')
[ -n "$ITEM_ID" ] || die "The pack carries no item id. Nothing has been created or reported."

# ------------------------------------------------------------ 2. the refusal --
#
# READY IS A DECISION SOMEBODY ELSE TOOK. api/lib/readiness.mjs is three
# queries and no model, and the whole value of that determinism is that the
# things downstream lean on it rather than re-deciding. So this refuses, and it
# refuses by printing the blockers the pack already carries: an agent that
# started anyway would be building to a brief nobody can check.
blocker_sentence() { # the words web/src/locales/en.json shows, for the same code
  case "$1" in
    no_verifiable_criterion)
      printf 'No acceptance criterion says how it would be checked, so there is nothing to verify against.' ;;
    no_environment)
      printf 'No environment is registered for this project, so there is nowhere to try anything.' ;;
    no_cast)
      printf 'No cast has been compiled for this project yet, so nobody would run through it.' ;;
    # A code this plugin has not learned yet is still an answer, and printing it
    # raw beats printing nothing: the backlog is the newer half of the pair.
    *) printf '%s' "$1" ;;
  esac
}

if [ "$STATUS" != ready ]; then
  say "Not ready: $(loopable_safe "$TITLE") is \`$STATUS\`."
  say
  BLOCKERS=$(printf '%s' "$PACK" | jq -r '.item.ready_blockers[]?' 2>/dev/null)
  if [ -n "$BLOCKERS" ]; then
    say "What is missing:"
    while IFS= read -r b; do [ -n "$b" ] && say "  · $(blocker_sentence "$b")"; done <<EOF
$BLOCKERS
EOF
  elif [ "$STATUS" = in_progress ] || [ "$STATUS" = in_review ] || [ "$STATUS" = verifying ]; then
    say "Somebody is already on it. Two agents on one item is the collision the worktree"
    say "rule exists to prevent — take a different item, or ask whoever holds this one."
  elif [ "$STATUS" = blocked ] || [ "$STATUS" = awaiting_input ]; then
    say "It is parked, waiting on somebody. Answer what it is waiting for first."
  else
    say "Nothing has judged it ready yet — grooming runs on the clock and writes the"
    say "reasons into the item. Ask the product owner to groom it, or give it acceptance"
    say "criteria and the project an environment."
  fi
  [ -n "$NOTE" ] && { say; say "The backlog's own note: $(loopable_safe "$NOTE")"; }
  say
  say "Nothing has been created and nothing has been reported."
  exit 1
fi

# -------------------------------------------------------------- 3. the slug --
#
# The title, as words a branch can carry: lowercase ascii, hyphens, and no
# leading item code — "S2.4 · /loopable:start" is `loopable-start`, because the
# code is already in the ref and a branch reading `s2-4-loopable-start`
# says the same thing twice.
slug_of() {
  printf '%s' "$1" | tr 'A-Z' 'a-z' |
    sed -E 's|^[[:space:]]*[a-z]?[0-9]+(\.[0-9]+)*[[:space:]]*[^a-z0-9]*||' |
    sed -E 's|[^a-z0-9]+|-|g; s|^-+||; s|-+$||' |
    cut -c1-40 | sed -E 's|-+$||'
}
SLUG=$(slug_of "$TITLE")
[ -n "$SLUG" ] || SLUG=item
# THE REF IS WHAT THE BACKLOG CALLS THE ROW, and a branch ending in one is the
# only EXACT answer `loopable_item` has to "which item is this branch" — every
# other step it takes is inference. So: the pack's own ref if it carries one,
# else the backlog's (the fourth field of loopable_items, S1.10), else the head
# of the uuid, which is what branches carried before refs existed.
if [ -z "$REF" ]; then
  [ -n "${ITEMS:-}" ] || ITEMS=$(loopable_items) || ITEMS=""
  REF=$(printf '%s\n' "$ITEMS" | awk -F'\t' -v i="$ITEM_ID" '$1 == i {print $4; exit}')
fi
SHORT=${REF:-$(printf '%s' "$ITEM_ID" | cut -c1-8)}
# The conventional-commit type, for a repository whose branches are named that
# way. A bug is a fix; everything else is a feature.
case "$KIND" in bug) TYPE=fix ;; *) TYPE=feat ;; esac

# ---------------------------------------------------------- 4. the worktree --
#
# TWO PATHS, AND THE REPOSITORY DECIDES WHICH. `start:` in .loopable.yaml is
# how a branch is started HERE — sanfrancisco's is `platform/bin/work.sh
# <type>/loopable-<slug>`, which branches from origin/main, places the worktree
# and, inside herdr, opens a workspace for it. Re-implementing that would mean
# this command creating branches the repository's own convention does not
# recognise, so when the key is there it is RUN, with the placeholders filled
# in; when it is absent the fallback is a plain `git worktree add` and the
# branch is the one the story names, `<kind>/<slug>-<shortid>`.
#
# THE LAST WORD OF THE COMMAND IS THE BRANCH. That is the rule, and it is
# stated rather than inferred: it is how the branch is known BEFORE the command
# runs (so an existing one is refused rather than half-created) and how the
# worktree is found afterwards, by asking git which checkout holds that branch
# rather than by parsing whatever the command chose to print.
#
# Running a value out of the repository's own config is running the
# repository's own code — the same trust a Makefile or a git hook already has.
# It is not attacker input: a `.loopable.yaml` that can be edited is a
# repository whose scripts can be edited.
START=$(loopable_config start) || START=""
if [ -n "$START" ]; then
  case "$START" in
    *'<shortid>'*|*'<ref>'*) SLUG_SUB="$SLUG" ;;
    # No place for the ref in the template, so it rides on the slug: a branch
    # ending in one — `feat/loopable-integer-refs-249` — is what lets every
    # session hook resolve the item exactly rather than by matching words.
    *) SLUG_SUB="$SLUG-$SHORT" ;;
  esac
  CMD=$(printf '%s' "$START" |
    sed -e "s|<type>|$TYPE|g" -e "s|<kind>|$KIND|g" \
        -e "s|<shortid>|$SHORT|g" -e "s|<ref>|$SHORT|g" -e "s|<slug>|$SLUG_SUB|g")
  BRANCH=${CMD##* }
else
  BRANCH="$KIND/$SLUG-$SHORT"
  CMD=""
fi

git -C "$REPO" show-ref --verify --quiet "refs/heads/$BRANCH" && die \
  "The branch $BRANCH already exists. Somebody has started this item — finish that
worktree, or remove it, before starting again. Nothing has been reported."

if [ -n "$CMD" ]; then
  ( cd "$REPO" && eval "$CMD" ) || die \
    "The repository's own start command failed:

  $CMD

Nothing has been reported. Fix that, or run it by hand, before starting again."
else
  git -C "$REPO" fetch origin >/dev/null 2>&1 || die \
    "\`git fetch origin\` failed, so origin/main cannot be trusted to be current.
A branch cut from a stale main is the bug this command exists to avoid."
  git -C "$REPO" worktree add -q -b "$BRANCH" "$REPO/.claude/worktrees/$BRANCH" origin/main ||
    die "Could not create the worktree for $BRANCH from origin/main. Nothing has been reported."
fi

# Which checkout holds it, asked of git rather than assumed — the configured
# command decides where its worktrees live, and this one does not have to know.
WORKTREE=$(git -C "$REPO" worktree list --porcelain |
  awk -v b="refs/heads/$BRANCH" '
    /^worktree /  { p = substr($0, 10) }
    $0 == "branch " b { print p; exit }')
[ -n "$WORKTREE" ] || die \
  "$BRANCH was started but no worktree is checked out on it. Nothing has been reported;
look at \`git worktree list\` before starting again."

# ------------------------------------------------------------- 5. the claim --
#
# `in_progress`, with a note naming the branch. The note is the half a person
# reading the console needs and the API cannot infer: an item in progress with
# no branch named is an item somebody has to go and ask about.
CLAIM=$(jq -nc --arg b "$BRANCH" --arg w "$WORKTREE" \
  '{status: "in_progress", note: ("started on branch " + $b + " (worktree " + $w + ")")}') ||
  die "Could not build the progress report. The worktree at $WORKTREE stands."
loopable_patch "/agent/projects/$PROJECT/items/$ITEM_ID" "$CLAIM" >/dev/null || die \
  "The worktree at $WORKTREE is ready, but reporting \`in_progress\` failed — the backlog
still shows this item as \`ready\` and another agent may take it. Report it before
working: report_progress in_progress, or PATCH /agent/projects/$PROJECT/items/$ITEM_ID."

# ----------------------------------------------------------- 6. the session --
#
# The same payload session-start.sh posts, for the same reason it posts it: the
# console and the stall detector want a harness at work on a branch. It opens
# rather than resumes because the branch did not exist a moment ago — an
# existing session on it is impossible, and the branch-exists refusal above is
# what keeps that true on a second run.
REPO_NAME=$(git -C "$REPO" remote get-url origin 2>/dev/null |
  sed -E 's|^.*[:/]([^/:]+/[^/]+?)(\.git)?$|\1|') || REPO_NAME=""
[ -n "$REPO_NAME" ] || REPO_NAME=$(basename "$REPO")
SESSION=$(loopable_post "/agent/projects/$PROJECT/sessions" \
  "$(jq -nc --arg i "$ITEM_ID" --arg h claude-code --arg r "$REPO_NAME" --arg b "$BRANCH" \
     '{item_id: $i, harness: $h, repo: $r, branch: $b}')" |
  jq -r '.session.id // empty' 2>/dev/null) || SESSION=""
if [ -n "$SESSION" ]; then
  # WRITTEN INTO THE NEW WORKTREE, not this one. The next session that starts
  # there finds the item and the session already resolved, and session-start.sh
  # RESUMES rather than opening a second session on one piece of work — which
  # is what would otherwise happen, since the state is per-worktree and this
  # process is standing somewhere else.
  GITDIR=$(git -C "$WORKTREE" rev-parse --absolute-git-dir 2>/dev/null) || GITDIR=""
  if [ -n "$GITDIR" ] && mkdir -p "$GITDIR/loopable" 2>/dev/null; then
    printf '%s' "$ITEM_ID" > "$GITDIR/loopable/item"
    printf '%s' "$SESSION" > "$GITDIR/loopable/session"
  fi
else
  # NOT FATAL, and the one place that is true: the worktree is made and the
  # item is claimed, so the work can proceed. The session opens by itself the
  # moment a session starts in the new worktree.
  say "The session could not be opened — the backlog did not answer. The worktree and the"
  say "progress report stand; a session will open when a Claude Code session starts there."
  say
fi

# -------------------------------------------------------------- 7. the pack --
#
# Printed as text rather than handed over as JSON, because what reads this is a
# model about to build the thing and the pack is already shaped for reading:
# titles not ids, criteria whole, decisions that govern it, somewhere to point.
say "Loopable — $(loopable_safe "$TITLE")"
say "  kind      $KIND"
say "  item      $ITEM_ID"
say "  branch    $BRANCH"
say "  worktree  $WORKTREE"
say "  session   ${SESSION:-none}"
say "  status    in_progress (reported)"
say

ASK=$(field '.item.ask'); BODY=$(field '.item.body')
if [ -n "$ASK" ]; then say "The ask"; say "$ASK"; say; fi
if [ -n "$BODY" ]; then say "The item"; say "$BODY"; say; fi

REV=$(field '.item.brief_rev')
say "Acceptance criteria — build to these (brief_rev ${REV:-0})"
CRIT=$(printf '%s' "$PACK" |
  jq -r '.criteria[]? | "  · [" + (.verify // "?") + (if .status == "skipped" then ", skipped" else "" end) + "] " + .text' 2>/dev/null)
say "${CRIT:-  · none written yet}"
say

NEIGH=$(printf '%s' "$PACK" | jq -r '
  ((.neighbourhood.nodes // [])[] | "  · " + .[0] + " — " + .[1]),
  ((.neighbourhood.edges // [])[] | "    " + .relation + ": " + (.from // "?") + " → " + (.to // "?"))' 2>/dev/null)
[ -n "$NEIGH" ] && { say "Around it (titles, never ids)"; say "$NEIGH"; say; }

DEC=$(printf '%s' "$PACK" | jq -r '
  .decisions[]? | "  · " + (if .about then "[about this] " else "" end) + .what +
  (if .why then " — " + .why else "" end)' 2>/dev/null)
[ -n "$DEC" ] && { say "Decisions that govern it"; say "$DEC"; say; }

ENV=$(printf '%s' "$PACK" | jq -r '.environments[]? | "  · " + .kind + "  " + (.base_url // "")' 2>/dev/null)
[ -n "$ENV" ] && { say "Environments"; say "$ENV"; say; }

TRIMMED=$(printf '%s' "$PACK" | jq -r 'if .truncated then (.trimmed // []) | join(", ") else empty end' 2>/dev/null)
[ -n "$TRIMMED" ] && { say "The pack did not fit whole; trimmed: $TRIMMED. Ask for what you need."; say; }

# THE LAST LINE, and it is the honest one. A running process cannot `cd` its
# own session into the new worktree, so the command does not pretend to: it
# says where the work is and leaves the choice — a new session there, or this
# one with every path under that directory — to whoever is reading.
say "The work is at $WORKTREE"
say "Open a new session in $WORKTREE, or continue here with all edits under $WORKTREE."
exit 0
