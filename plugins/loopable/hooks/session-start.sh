#!/usr/bin/env bash
# SessionStart. Opens — or resumes — the Loopable session for the item this
# branch is working, so that the console and the product owner can see a
# harness at work without anybody remembering to tell them.
#
# It is a SECOND SessionStart hook rather than more of open-work.sh on
# purpose. open-work.sh answers "what is in progress in this repository"; this
# answers "which of it am I, and is my session already open". Two questions,
# two scripts, and the harness merges the context they each add.
#
# RESUME BEFORE OPEN. A session is one piece of work, not one process: a
# `--continue`, a crash, a second window on the same worktree are all the same
# session, and opening a new one each time turns the console into a list of
# ghosts and the stall detector into a liar. So the existing open session for
# (item, this branch, claude-code) wins, and a new one is the fallback.
#
# NO MODEL CALL, and no node. Two curls at worst, four seconds each, and
# session start is not held up by anything else.
#
# EVERY FAILURE IS A PASS: no config, no token, no network, main, an item that
# does not resolve — exit 0, having printed nothing. Nobody's session fails to
# start because a database was asleep.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
. "$HERE/lib.sh"

command -v jq >/dev/null 2>&1 || exit 0
command -v git >/dev/null 2>&1 || exit 0
loopable_config_file >/dev/null 2>&1 || exit 0

BRANCH=$(loopable_branch) || exit 0
PROJECT=$(loopable_project) || exit 0
ITEM=$(loopable_item) || exit 0
STATE=$(loopable_state_dir) || exit 0
loopable_state_put item "$ITEM"

# The repository as a person would name it — `owner/name` from the remote,
# else the directory. It is a label on the session row, not an identifier.
REPO_NAME=$(git -C "$(loopable_repo)" remote get-url origin 2>/dev/null |
  sed -E 's|^.*[:/]([^/:]+/[^/]+?)(\.git)?$|\1|') || REPO_NAME=""
[ -n "$REPO_NAME" ] || REPO_NAME=$(basename "$(loopable_repo)" 2>/dev/null) || REPO_NAME=""

HARNESS=claude-code

# Already open for this branch? The API filters by item and state; the branch
# and harness are matched here, because two agents on two branches of the same
# item are two sessions and the API has no reason to know that.
SESSION=$(loopable_get \
  "/agent/projects/$PROJECT/sessions?item_id=$ITEM&state=pending,active,awaiting_input" |
  jq -r --arg b "$BRANCH" --arg h "$HARNESS" \
    'first(.sessions[]? | select(.branch == $b and .harness == $h) | .id) // empty') || SESSION=""

VERB=resumed
if [ -z "$SESSION" ]; then
  VERB=opened
  BODY=$(jq -nc --arg i "$ITEM" --arg h "$HARNESS" --arg r "$REPO_NAME" --arg b "$BRANCH" \
    '{item_id: $i, harness: $h, repo: $r, branch: $b}') || exit 0
  SESSION=$(loopable_post "/agent/projects/$PROJECT/sessions" "$BODY" |
    jq -r '.session.id // empty') || exit 0
fi
[ -n "$SESSION" ] || exit 0

loopable_state_put session "$SESSION"
# A buffer left by a previous session on this branch belongs to a session that
# is over. Flushing it into this one would date-stamp somebody else's tool
# calls as ours; dropping it is the honest loss.
rm -f "$STATE/actions" 2>/dev/null

jq -nc --arg c "Loopable — session $SESSION $VERB on item $ITEM (branch $BRANCH).

Activity is reported for you: a summary when this session stops, an 'action'
line per batch of tool calls, and the PR when one is created. You do not need
to call post_activity for those. Post one yourself when something happened
that a person watching would want said in words.

The session is NOT closed by any hook — closing 'complete' is a claim that
needs the whole close contract, which /loopable:ship assembles." '{
  hookSpecificOutput: { hookEventName: "SessionStart", additionalContext: $c }
}'
exit 0
