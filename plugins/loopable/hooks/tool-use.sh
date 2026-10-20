#!/usr/bin/env bash
# PostToolUse. Two jobs, and the second one is mostly about NOT doing the
# first.
#
# 1. A PR IS AN EVENT. `gh pr create` that printed a pull request URL is the
#    moment this session's work became reviewable, and it gets its own
#    activity, immediately, with the url and the number in `ref` so anything
#    reading the stream can link straight to it.
#
#    IT IS AN ACTIVITY, AND THE COLUMN IS THE CLOSE'S. `agent_sessions` grew a
#    `pr_url` (20260909130000), and it is written by the close and only by the
#    close — one write per ending is what makes a close worth trusting, and a
#    hook cannot close anything. So this stays what it always was: the moment
#    the work became reviewable, recorded while the session is still running,
#    in the jsonb `ref` that S1.2 put there for exactly this. The accept seat
#    reads the column first and falls back to these refs, so a run that opened
#    a pull request and closed without naming one still shows its link.
#
# 2. EVERYTHING ELSE IS BATCHED. A line per tool call would be a session with
#    four hundred activities and one HTTP request per keystroke-sized action,
#    which is not a stream anybody reads and not a bill anybody wants. So the
#    ordinary path appends ONE LINE to a worktree-local buffer and makes no
#    network call at all; the buffer is posted as a single `action` activity
#    when it reaches BATCH_LINES lines or BATCH_SECONDS have passed since its
#    first line — whichever comes first, checked on the next tool call. Stop
#    flushes whatever is left, so nothing is stranded.
#
#    Ten lines and five minutes. Small enough that a person watching the
#    console sees movement within a coffee-length pause, large enough that a
#    busy minute is one row rather than forty.
#
# NO MODEL CALL, and the common path is a file append.
#
# EVERY FAILURE IS A PASS — and here that means SILENCE, not permission: a
# PostToolUse hook's stdout lands in the transcript, so anything printed is a
# hook talking to an agent about its own bookkeeping. It prints nothing, ever,
# on any path, and exits 0.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
. "$HERE/lib.sh"

BATCH_LINES=10
BATCH_SECONDS=300

command -v jq >/dev/null 2>&1 || exit 0
INPUT=$(cat) || exit 0

# THE WORKTREE IS THE CALL'S, not the process's (336): a builder in a worktree
# under a driver in the main checkout reports into the worktree's session.
# Exported, so the state dir, the item and the project all agree with it.
#
# ONLY A WORKTREE OF THE REPOSITORY THE PROCESS TRUSTS — the one loopable_repo
# names, by ITS OWN worktree list. A target anywhere else (a clone, or a
# directory whose hand-written .git points into ours) is outside, and posts
# nothing: no fallback, because falling
# back would report a call in somebody else's repository into ours.
if ROOT=$(loopable_tool_repo "$INPUT") && [ -n "$ROOT" ]; then
  TRUSTED=$(loopable_repo) || exit 0
  [ -n "$TRUSTED" ] && loopable_trusted_worktree "$ROOT" "$TRUSTED" || exit 0
  export LOOPABLE_REPO="$ROOT"
fi

STATE=$(loopable_state_dir) || exit 0
# No session, nothing to report into. Cheap, and before anything else: a
# session that never opened (main, no config, no token) must cost a tool call
# nothing at all. A session file holding anything but an id is no session.
SESSION=$(loopable_state session) || exit 0
loopable_id_ok "$SESSION" || exit 0

TOOL=$(printf '%s' "$INPUT" | jq -r '.tool_name // ""') 2>/dev/null || exit 0
CMD=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // ""') 2>/dev/null || CMD=""
FILE=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // ""') 2>/dev/null || FILE=""

# ------------------------------------------------------------ the PR event --
#
# Both halves have to be true. The command SAYS it created a PR and the output
# CARRIES one — a `gh pr create` that failed, or that was only ever echoed
# into a comment, printed no url and reports nothing. The url is read from the
# tool's own output rather than from the command, which is what makes it a
# fact rather than an intention.
if [ -n "$CMD" ] && printf '%s' "$CMD" | grep -Eq '(^|[^[:alnum:]_-])gh[[:space:]]+pr[[:space:]]+create([^[:alnum:]_-]|$)'; then
  OUT=$(printf '%s' "$INPUT" | jq -r '
    [.tool_response?] | flatten | map(
      if type == "string" then . elif type == "object" then (.stdout? // .output? // "") else "" end
    ) | join("\n")') 2>/dev/null || OUT=""
  URL=$(printf '%s' "$OUT" |
    grep -Eo 'https://[a-zA-Z0-9.-]+/[^[:space:]]+/pull/[0-9]+' | head -1) || URL=""
  if [ -n "$URL" ]; then
    NUM=${URL##*/}
    ITEM=$(loopable_state item) || ITEM=""
    loopable_id_ok "$ITEM" || ITEM=""
    REF=$(jq -nc --arg u "$URL" --arg n "$NUM" --arg i "$ITEM" \
      '{pr_url: $u, pr_number: ($n | tonumber?), item_id: (if $i == "" then null else $i end)}
       | with_entries(select(.value != null))') || REF=""
    [ -n "$REF" ] && loopable_activity result "Pull request #$NUM opened: $URL" "$REF"
    exit 0
  fi
fi

# ---------------------------------------------------------- the batch line --
#
# THE LINE IS THE COMMAND, NOT WHERE IT RAN. A line is cut at 80 characters
# and a worktree path is ~105, so `cd <wt> && npm test` recorded whole showed
# only the path. When the leading `cd` is what chose this worktree, the
# session already says where: the prefix is dropped, and a `cd` into a
# directory inside the worktree keeps only the part relative to it.
if [ "$TOOL" = Bash ] && [ -n "${ROOT:-}" ] && REST=$(loopable_cd_rest "$CMD"); then
  TO=$(loopable_cd_target "$CMD")
  case "$TO" in
    /*) : ;;
    *) TO="$(printf '%s' "$INPUT" | jq -r '.cwd // ""' 2>/dev/null)/$TO" ;;
  esac
  TO=$(cd -P "$TO" 2>/dev/null && pwd -P) || TO=""
  WT=$(cd -P "$ROOT" 2>/dev/null && pwd -P) || WT=""
  if [ -n "$TO" ] && [ -n "$WT" ]; then
    case "$TO" in
      "$WT")   CMD=$REST ;;
      "$WT"/*) CMD="cd ${TO#"$WT"/} && $REST" ;;
    esac
  fi
fi

case "$TOOL" in
  Bash)        [ -n "$CMD" ] || exit 0; LINE="$ $(loopable_safe "$CMD")" ;;
  Edit|Write|NotebookEdit)
               [ -n "$FILE" ] || exit 0; LINE="edited $(loopable_safe "$FILE")" ;;
  *)           exit 0 ;;
esac

printf '%s\n' "$LINE" >> "$STATE/actions" 2>/dev/null || exit 0
[ -s "$STATE/at" ] || date +%s > "$STATE/at" 2>/dev/null

COUNT=$(wc -l < "$STATE/actions" 2>/dev/null | tr -d ' ') || exit 0
SINCE=$(cat "$STATE/at" 2>/dev/null) || SINCE=""
AGE=0
case "$SINCE" in *[!0-9]*|'') : ;; *) AGE=$(( $(date +%s) - SINCE )) ;; esac

[ "${COUNT:-0}" -ge "$BATCH_LINES" ] || [ "$AGE" -ge "$BATCH_SECONDS" ] || exit 0
loopable_flush_actions
exit 0
