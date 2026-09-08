#!/usr/bin/env bash
# Stop. One line into the session saying where this stretch of work got to.
#
# WHAT IT IS NOT: a close. Closing `complete` is a CLAIM — a brief revision, a
# HEAD sha, a verifier verdict, every criterion accounted for, screenshots and
# what it cost (S1.3) — and none of that is knowable to a hook watching a
# process end. A hook that closed would either close `error` on every ordinary
# stop, which says the work broke when it did not, or assemble the contract
# out of guesses, which is worse. So the session STAYS OPEN and /loopable:ship
# closes it (S2.5). A session that is still open at the end of a stretch is
# accurate: the work is not finished.
#
# THE KIND IS `result`. S1.2's vocabulary is thought | action | question |
# result | error and there is no `summary` in it; the summary of a stretch of
# work is a result, and inventing a sixth kind for a hook would put a word in
# the schema that no reader knows.
#
# WHAT IT SAYS: the last commit's subject and how many files are still
# uncommitted. NOT the transcript, not the last message, not a model's account
# of itself — the transcript is the session's reasoning, an activity body is
# read by whoever opens the console, and a hook that shipped one into the
# other would be exfiltrating a working process into a shared record. Two
# facts, both read from git, both already visible to anybody with the branch.
#
# It flushes the PostToolUse batch first, so the ordering in the stream is the
# ordering things happened in.
#
# EVERY FAILURE IS A PASS, and silence with it: a Stop hook's stdout is shown,
# so this prints nothing on any path and exits 0.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
. "$HERE/lib.sh"

command -v jq >/dev/null 2>&1 || exit 0
command -v git >/dev/null 2>&1 || exit 0
# Drain stdin so the harness never sees a closed pipe, and ignore it: nothing
# in the payload is a fact about the repository.
cat >/dev/null 2>&1

SESSION=$(loopable_state session) || exit 0
[ -n "$SESSION" ] || exit 0
REPO=$(loopable_repo) || exit 0

loopable_flush_actions

SUBJECT=$(git -C "$REPO" log -1 --format=%s 2>/dev/null) || SUBJECT=""
DIRTY=$(git -C "$REPO" status --short 2>/dev/null | grep -c .) || DIRTY=0
BRANCH=$(loopable_branch) || BRANCH=""

BODY="Session stopped on ${BRANCH:-this branch}."
[ -n "$SUBJECT" ] && BODY="$BODY Last commit: $(loopable_safe "$SUBJECT")."
BODY="$BODY ${DIRTY:-0} uncommitted file(s). The session stays open — /loopable:ship closes it with the contract."

loopable_activity result "$BODY"
exit 0
