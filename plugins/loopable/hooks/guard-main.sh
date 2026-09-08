#!/usr/bin/env bash
# PreToolUse/Write|Edit. Refuses an edit ON MAIN to a path this repository
# tracks in Loopable.
#
# WHY. One worktree per item is what makes several agents on one repository
# safe: each branch is started from origin/main, each PR names its item, and
# nothing two agents do can land in the same working tree. The repository's
# own rules already refuse a commit on main; this refuses the edit, which is
# a minute earlier and the moment the mistake is cheap.
#
# THE REPOSITORY IS THE FILE'S, NOT THE SESSION'S. A session sitting in a main
# checkout that edits a file inside a worktree is doing exactly the right
# thing, and the branch that matters is the worktree's. So the branch is read
# from the file's own directory, and `.loopable.yaml` from that repository's
# root.
#
# EVERY FAILURE IS A PASS, as in lib.sh: no git, no repository, a detached
# HEAD, a file outside the tracked paths — all pass. The guard denies on one
# confident fact: the branch is main or master, and the path is tracked.
# LOOPABLE_ALLOW_MAIN=1 overrides it once, on purpose, for the person who has
# a reason.
#
# Exit 0 always: the decision travels in the JSON, not the exit code.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
. "$HERE/lib.sh"

INPUT=$(cat)
FILE=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // ""')
CWD=$(printf '%s' "$INPUT" | jq -r '.cwd // ""')
[ -n "$FILE" ] || exit 0
[ "${LOOPABLE_ALLOW_MAIN:-}" = 1 ] && exit 0
command -v git >/dev/null 2>&1 || exit 0
[ -n "$CWD" ] || CWD=$PWD
case "$FILE" in /*) : ;; *) FILE="$CWD/$FILE" ;; esac

# The nearest directory that exists — the file itself may be new.
DIR=$(dirname "$FILE")
while [ ! -d "$DIR" ] && [ "$DIR" != / ]; do DIR=$(dirname "$DIR"); done

ROOT=$(git -C "$DIR" rev-parse --show-toplevel 2>/dev/null) || exit 0
[ -n "$ROOT" ] || exit 0
BRANCH=$(git -C "$DIR" symbolic-ref --quiet --short HEAD 2>/dev/null) || exit 0
case "$BRANCH" in main|master) ;; *) exit 0 ;; esac

REL=${FILE#"$ROOT"/}
[ "$REL" != "$FILE" ] || exit 0

export LOOPABLE_REPO="$ROOT"
loopable_touches "$REL" || exit 0

START=$(loopable_config start) || START=""
[ -n "$START" ] || START="git worktree add <path> -b <type>/<slug> origin/main"

# TWO WAYS TO START, and the command is named first because it does the whole
# sequence — the pack, the readiness refusal, the worktree from origin/main, the
# progress report, the session — while `start:` is only the worktree half. The
# repository's own line stays: it is what a person types, what runs when there
# is no Loopable item to pull, and what /loopable:start itself executes.
jq -nc --arg r "$(printf '%s is on branch %s. Work on %s happens on a branch in its own worktree, never on main — one worktree per item is what lets several agents share this repository, and the PR that lands it must name its Loopable item.\n\nStart one:\n\n  /loopable:start <item id | ref | next>\n\nwhich pulls the item brief, refuses work that is not ready, makes the worktree and reports it. Or, by hand:\n\n  %s\n\nthen make the edit there. LOOPABLE_ALLOW_MAIN=1 overrides this once, on purpose.' \
  "$REL" "$BRANCH" "$(loopable_paths_phrase)" "$START")" '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    permissionDecision: "deny",
    permissionDecisionReason: $r
  }
}'
exit 0
