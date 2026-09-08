#!/usr/bin/env bash
# PreToolUse/Bash. Refuses to merge loopable work that the backlog has not
# heard about.
#
# WHY THIS EXISTS. Phase 2 shipped four PRs — Bedrock, conversations, the PO's
# grounding, the engine — and every one of its backlog items still read "Not
# Started" afterwards. The plan had predicted exactly that, in writing:
# "reporting completion has to sit on the path already being walked ... if it
# becomes a detour we will have rebuilt the same problem behind a nicer
# screen." A reminder is a detour. This is not a reminder.
#
# The rule: a PR that touches what `.loopable.yaml` lists under `paths:` (or
# anything at all, when it lists nothing) must name the work item it lands, and
# that item must have moved off `todo`. Naming it in the PR body is worth
# something on its own — it is a permanent link from the merge commit to the
# reason for it, which no commit message reliably carries.
#
#   Loopable: 4e90ea71-bc6a-445d-8517-f732d064a1f5
#   Loopable: none — the plugin that enforces this, which has no item yet
#
# The escape hatch is deliberate and deliberately visible: "none" with a reason
# is a statement somebody can disagree with in review. Silence is not.
#
# EVERY FAILURE IS A PASS — see lib.sh. Exit 0 always: the decision travels in
# the JSON, not the exit code.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
. "$HERE/lib.sh"

INPUT=$(cat)
CMD=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // ""')

pass() { exit 0; }
deny() {
  jq -nc --arg r "$1" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: $r
    }
  }'
  exit 0
}

# Only `gh pr merge`, and only with a PR number to look up. A bare `gh pr merge`
# on the current branch is not worth guessing about.
# NO REGEX PRETENDS TO BE A SHELL PARSER HERE.
#
# The previous version decided "invoked or merely mentioned?" by looking for
# quotes around the string. That is a parser differential, and it lost:
# `eval "gh pr merge 367"` and `bash -c 'gh pr merge 367'` both passed, because
# the text sat inside quotes and the heuristic called it a mention. Shell
# quoting cannot be modelled this way and should not be attempted.
#
# So the default is inverted. If the command mentions a merge at all, it is
# checked — UNLESS it starts with something that cannot merge anything, which
# is the case the exemption actually existed for (`echo`, `grep`, a search
# through the docs). Anything else is checked, `eval` and `bash -c` included.
#
# "Mentions a merge at all" is enforced directly below. It used to be only a
# description — the check itself was never written, so every command with a
# number in it was treated as a candidate merge.
#
# Failing closed is affordable here precisely because the escape hatch is not
# in this file: `Loopable: none — <why>` in the PR body is a visible, reviewable
# override, and a person blocked by a false positive has one line to write.
# THE TEST IS "CANNOT RUN ANOTHER PROGRAM", not "reads text".
#
# The first version of this list was the second one, and it was wrong in a way
# that is obvious once said: text tools execute things. awk has system(). GNU
# sed has the `e` command. rg and ag take --pre. less, more and man all have a
# `!` shell escape. Seven of the fifteen entries could run the very command
# being guarded, and three of them were confirmed doing it:
#
#     awk "BEGIN{system(\"gh pr merge 367\")}"     passed
#     sed '1e gh pr merge 367' /dev/null           passed
#
# So the list is now only programs that cannot start another one. It is short
# because it can be: this exemption applies only when the command ALSO carries
# a number, and searching for the string without one already passes. There is a
# test asserting membership rather than behaviour, so putting awk back fails on
# the list itself rather than on somebody remembering to write the exploit.
# FIRST: IS THIS A MERGE AT ALL?
#
# It was not asking. Everything below harvests every integer in the command and
# looks each one up as a PR, and nothing established that the command had
# anything to do with merging — so ANY command carrying a number that happened
# to match a merged PR touching apps/loopable/ was denied. Three, in one
# session, none of them a merge:
#
#   · a `wc -l` on a scratch file, because the hex in the session path spelled
#     a PR number
#   · a `grep -n` through this suite, because the pattern quoted one
#   · the `gh issue create` reporting the first two, because the body did
#
# Describing the bug reproduced it. That is the failure this file's own header
# names — "the way a refusing hook fails is by refusing work it should not,
# which nobody notices until they are blocked and cross" — and the escape hatch
# does not reach it: `Loopable: none` goes in the body of the PR being merged,
# and there is no PR here, just a `wc`.
#
# So: both words, or nothing. Every DENY case in the suite carries the literal
# string `gh pr merge` — eval, bash -c and awk included, since they quote the
# command rather than assembling it — so this narrows the false positives
# without widening a single hole. \bgh\b does not match `github`: the `i`
# denies the word boundary, which matters because this repo lives under a path
# containing it.
printf '%s' "$CMD" | grep -qiE '\bmerge\b' || pass
printf '%s' "$CMD" | grep -qiE '\bgh\b'    || pass

CANNOT_EXEC='echo printf cat head tail comm'
FIRST=$(printf '%s' "$CMD" | sed -nE 's|^[[:space:]]*([A-Za-z0-9_./-]+).*|\1|p' | head -1)
for safe in $CANNOT_EXEC; do
  [ "${FIRST##*/}" = "$safe" ] && pass
done

# EVERY NUMBER IN THE COMMAND IS A CANDIDATE PR, not just one sitting where a
# regex expected it. The first version read the integer immediately after
# `gh pr merge`, which meant `gh pr merge --squash 367` and
# `gh pr merge --repo owner/name 367` both walked straight past — verified, on
# a PR that should have been denied. The greedy match also judged a chained
# command on whichever merge came last.
#
# Over-collecting is free: a number that is not a PR makes `gh pr diff` fail,
# and a candidate that cannot be looked up passes. Under-collecting is the bug.
PRS=$(printf '%s' "$CMD" | grep -oE '[0-9]+' | sort -u)
[ -n "$PRS" ] || pass

command -v gh >/dev/null 2>&1 || pass
command -v jq >/dev/null 2>&1 || pass

# Fetched once, not per candidate: a merge command names few PRs and the
# backlog does not change between them.
ITEMS_CACHE=""

# One candidate at a time. Anything that cannot be answered confidently is a
# pass for that candidate and nothing more — an unknown number must not make
# the whole command suspicious, or `gh pr merge 12 --squash` in a repo with no
# PR 12 would block on a typo.
check_pr() { # check_pr <n> -> prints a denial reason, or nothing
  local pr=$1 files body ids stale row status title id

  files=$(gh pr diff "$pr" --name-only 2>/dev/null) || return 0
  loopable_touches "$files" || return 0

  body=$(gh pr view "$pr" --json body -q .body 2>/dev/null) || return 0

  # `Loopable: none — <reason>` is an explicit, reviewable decision to land
  # something the backlog does not track.
  printf '%s\n' "$body" | grep -qiE '^[[:space:]]*Loopable:[[:space:]]*none\b' && return 0

  # grep first, so the match is case-insensitive the same way the `none` check
  # is. sed's case-insensitive flag is a GNU extension, and this has to run on
  # whatever anybody's laptop has.
  ids=$(printf '%s\n' "$body" | grep -iE '^[[:space:]]*Loopable:[[:space:]]*[0-9a-fA-F-]{36}' |
    sed -nE 's|^[[:space:]]*[Ll][Oo][Oo][Pp][Aa][Bb][Ll][Ee]:[[:space:]]*([0-9a-fA-F-]{36}).*|\1|p')

  if [ -z "$ids" ]; then
    printf 'PR #%s touches %s and its body names no work item, so merging it would leave the Loopable backlog saying this was never done.\n\nAdd a line to the PR body:\n\n  Loopable: <item-id>\n\nand report it through the MCP (report_progress) before merging. If this genuinely has no item, say so on purpose:\n\n  Loopable: none — <why>\n' "$pr" "$(loopable_paths_phrase)"
    return 0
  fi

  # The backlog's own answer. Unreachable, no token, asleep — all pass.
  [ -n "$ITEMS_CACHE" ] || ITEMS_CACHE=$(loopable_items) || return 0
  [ -n "$ITEMS_CACHE" ] || return 0

  stale=""
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    row=$(printf '%s\n' "$ITEMS_CACHE" | awk -F'\t' -v want="$id" '$1 == want {print; exit}')
    # An id this token cannot see is not a confident negative: it may belong to
    # another studio, or the token may be narrower than the person merging.
    [ -n "$row" ] || continue
    status=$(printf '%s' "$row" | cut -f2)
    # Through the SAME sanitizer the session banner uses. A denial reason
    # lands in an agent's context exactly the way session context does, and
    # this line is where that was forgotten last time.
    title=$(loopable_safe "$(printf '%s' "$row" | cut -f3)")
    [ "$status" = todo ] && stale="$stale
  · $title ($id)"
  done <<EOF
$ids
EOF

  [ -n "$stale" ] && printf "PR #%s names work the backlog still calls 'todo':\n%s\n\nReport it through the MCP before merging — report_progress with in_progress or done. The backlog is the source of truth now, and a merge it never heard about is how it starts lying.\n" "$pr" "$stale"
  return 0
}

REASONS=""
for pr in $PRS; do
  reason=$(check_pr "$pr")
  [ -n "$reason" ] && REASONS="$REASONS$reason
"
done

[ -n "$REASONS" ] && deny "$REASONS"
pass
