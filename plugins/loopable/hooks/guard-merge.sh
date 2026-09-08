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
# THE RULE (S2.6). A PR that touches what `.loopable.yaml` lists under `paths:`
# (or anything at all, when it lists nothing) must name the work item it lands,
# and that item must be `in_review` WITH A CLOSE PAYLOAD AT THIS PR'S HEAD SHA
# whose verifier verdict is `pass`.
#
#   Loopable: 4e90ea71-bc6a-445d-8517-f732d064a1f5
#   Loopable: none — the plugin that enforces this, which has no item yet
#
# It used to be "not `todo`", which any `report_progress` satisfied in one call
# — a status is a sentence an agent types, and a guard that reads one is a
# guard checking that somebody said the right thing. The close contract (S1.3)
# is the first thing in this system that is not: a `complete` close costs a
# brief revision, every criterion accounted for, screenshots where a browser
# was the way to check, a cost, and A HEAD SHA. That sha is what makes the
# claim checkable from here — the API says what was verified, `gh` says what is
# about to be merged, and this hook is the one place both are in hand.
#
# WHY THE SHA AND NOT JUST THE VERDICT. A close says "I verified THIS". Push
# three more commits and that sentence is still on the record and no longer
# about the thing being merged; a PR whose HEAD moved after the close is a PR
# nobody verified. Comparing the two is one string comparison, and it is the
# whole of the difference between a report and evidence.
#
# WHAT `not_run` MEANS. The contract's third verdict is first-class and it is
# not a synonym for `fail`: a change with no criterion verified in a browser
# has nothing for a browser verifier to drive, and S1.3 already says so — the
# database makes screenshots mandatory exactly when a criterion's `verify` is
# `browser`. So `not_run` is refused, naming the verdict, UNLESS the item's
# criteria carry no `browser` method at all. The rule is read off what S1.3
# stored rather than invented here, which is why it is one read and not a
# judgement.
#
# The escape hatch is deliberate and deliberately visible: "none" with a reason
# is a statement somebody can disagree with in review. Silence is not.
#
# EVERY FAILURE IS A PASS — EXCEPT HERE. lib.sh's rule is the right one for the
# reporting hooks and the wrong one for this file, and the difference is that a
# merge cannot be taken back. A hook that failed open when the backlog was
# unreachable would be a hook whose whole ruleset is switched off by unplugging
# a network cable, and "the API was down" is the cheapest exploit anybody will
# ever find. So this guard REFUSES WHAT IT CANNOT VERIFY, and says which of the
# two it is doing. What keeps that from being intolerable is not a softer rule:
# it is that the way through is one line in a PR body (`Loopable: none — why`)
# or one variable in a person's environment.
#
# THE OVERRIDE IS A PERSON'S, NOT A COMMAND'S. `LOOPABLE_ALLOW_MERGE=1` is read
# from THIS PROCESS's environment — the session the hook runs inside — and a
# `LOOPABLE_ALLOW_MERGE=1 gh pr merge 9` typed as a command sets it in a child
# shell this hook never sees. So the escape hatch belongs to whoever started
# the session, which is a person, and an agent cannot reach for it by writing a
# longer command. Every refusal prints it, because a guard that cannot be
# overridden is a guard that gets deleted.
#
# `gh` ITSELF FAILING IS STILL A PASS, and that is not an inconsistency. If
# `gh pr view` cannot answer, `gh pr merge` cannot merge either — there is no
# state to protect. The refusal is for the case where the merge would go
# through and only the CHECK was missing.
#
# Exit 0 always: the decision travels in the JSON, not the exit code.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
. "$HERE/lib.sh"

INPUT=$(cat)
CMD=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // ""')

pass() { exit 0; }

# A PERSON'S WAY THROUGH, read before any work is done. See the header: this
# variable can only have come from the environment the session was started in,
# so it is a decision somebody made with their hands.
[ "${LOOPABLE_ALLOW_MERGE:-}" = 1 ] && pass

# Printed under every refusal, and it is not decoration. The three security
# rounds' honest conclusion is that a guard written in shell against
# attacker-shaped input will get something wrong; the cost of that being
# survivable is that the person it blocks wrongly has a documented door.
OVERRIDE='If this is wrong — the backlog is down, the item is somebody else'"'"'s, the check itself is broken — a person can start the session with LOOPABLE_ALLOW_MERGE=1 and merge anyway. Prefixing the command with it does nothing: the hook reads its own environment, not yours.'

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
# backlog does not change between them. `unreachable` is remembered separately
# from `empty`, because those two now mean opposite things — see the header.
ITEMS_CACHE=""
ITEMS_DOWN=""
PROJECT=""

# The one sentence every "cannot verify" refusal ends with. It is a refusal
# ABOUT THE CHECK rather than about the work, and saying which is the whole
# difference between a guard somebody trusts and a guard somebody removes.
cannot_verify() { # cannot_verify <pr> <what did not answer>
  printf 'PR #%s touches %s and %s, so nothing here can say whether this work was verified at the commit about to be merged.\n\nThis guard refuses what it cannot check. A merge cannot be taken back, and a guard that passed silently whenever the backlog was unreachable would be a guard switched off by a dropped connection.\n\n%s\n' \
    "$1" "$(loopable_paths_phrase)" "$2" "$OVERRIDE"
}

# How a person satisfies this by hand TODAY. `/loopable:ship` (S2.5) is the
# one-step version and does not exist yet; until it does, the close is an MCP
# call, and a refusal that named only the tool nobody has would be a refusal
# with no way out but the override.
by_hand() { # by_hand <head sha>
  printf 'Close the session with the payload: `close_session` through the loopable MCP, carrying the brief revision, head_sha %s, the verifier verdict and its reason, every criterion with implemented_at and a status, the screenshot attachment ids and the cost. A complete close moves the item to in_review by itself. (/loopable:ship will do all of this in one step — S2.5, not built yet.)' "$1"
}

# One candidate at a time. A number that is not a PR is still a pass for that
# candidate and nothing more — an unknown number must not make the whole
# command suspicious, or `gh pr merge 12 --squash` in a repo with no PR 12
# would block on a typo. What changed in S2.6 is what happens AFTER the
# candidate is known to be a real PR touching tracked paths: from that line
# down, an unanswered question is a refusal.
check_pr() { # check_pr <n> -> prints a denial reason, or nothing
  local pr=$1 files view body head short refs ref id row status title
  local sessions matched newest verdict reason methods

  files=$(gh pr diff "$pr" --name-only 2>/dev/null) || return 0
  loopable_touches "$files" || return 0

  # ONE `gh pr view`, CARRYING BOTH. The body and the sha have to describe the
  # same PR at the same instant; two calls are two instants, and the gap
  # between them is exactly a push.
  #
  # BOTH COME FROM GITHUB, NEITHER FROM THE COMMAND. Nothing in the command
  # text is ever read as a marker or as a sha. `gh pr merge 9  # Loopable:
  # <some in_review item>` has written a comment, and an argument spelling a
  # sha is an argument. The command is used for one thing only: finding
  # candidate PR numbers.
  view=$(gh pr view "$pr" --json body,headRefOid 2>/dev/null) || return 0
  body=$(printf '%s' "$view" | jq -r '.body // ""' 2>/dev/null) || return 0
  head=$(printf '%s' "$view" | jq -r '.headRefOid // ""' 2>/dev/null | tr 'A-Z' 'a-z')
  # No sha, no rule to apply — and no PR either, in practice. `gh` answering
  # without one is `gh` not answering.
  [ -n "$head" ] || return 0
  short=$(printf '%s' "$head" | cut -c1-12)

  # `Loopable: none — <reason>` is an explicit, reviewable decision to land
  # something the backlog does not track. It is checked FIRST, before anything
  # that can fail, so the stated exception still works when the API is down —
  # which is the only reason a refusing guard is affordable at all.
  printf '%s\n' "$body" | grep -qiE '^[[:space:]]*Loopable:[[:space:]]*none\b' && return 0

  # WHATEVER FOLLOWS THE MARKER, kept opaque. The shape of a reference is
  # lib.sh's business (loopable_refs / loopable_resolve_ref), so a new spelling
  # — the short ids of S1.10 — composes with the sha rule below without either
  # story having to know about the other.
  refs=$(loopable_refs "$body")
  if [ -z "$refs" ]; then
    printf 'PR #%s touches %s and its body names no work item, so merging it would leave the Loopable backlog saying this was never done.\n\nAdd a line to the PR body:\n\n  Loopable: s41        (its short ref, or its uuid)\n\nand close its session with the payload before merging. If this genuinely has no item, say so on purpose:\n\n  Loopable: none — <why>\n\n%s\n' \
      "$pr" "$(loopable_paths_phrase)" "$OVERRIDE"
    return 0
  fi

  # The backlog's own answer. Unreachable, no token, asleep — all REFUSE now,
  # and the refusal says the backlog is what did not answer rather than
  # implying anything about the work.
  if [ -z "$ITEMS_CACHE" ] && [ -z "$ITEMS_DOWN" ]; then
    ITEMS_CACHE=$(loopable_items) || ITEMS_DOWN=1
  fi
  if [ -n "$ITEMS_DOWN" ] || [ -z "$ITEMS_CACHE" ]; then
    cannot_verify "$pr" 'the Loopable backlog did not answer — no token, no network, or a sleeping database'
    return 0
  fi
  [ -n "$PROJECT" ] || PROJECT=$(loopable_project) || PROJECT=""
  if [ -z "$PROJECT" ]; then
    cannot_verify "$pr" 'this repository resolves to no Loopable project'
    return 0
  fi

  while IFS= read -r ref; do
    [ -n "$ref" ] || continue
    # THROUGH THE SAME SANITIZER THE SESSION BANNER USES, everywhere text that
    # did not originate here reaches a reason. A ref is somebody's typing and a
    # title can begin life as a sentence a client wrote in chat; both land in
    # an agent's context the same way.
    id=$(loopable_resolve_ref "$ref" "$ITEMS_CACHE") || {
      # An id this token cannot resolve USED TO BE A PASS, on the reasoning
      # that the token might be narrower than the person merging. That
      # reasoning is a hole once the rule has teeth: any string at all in the
      # body would walk past every check below it. It is a cannot-verify, and
      # cannot-verify refuses.
      cannot_verify "$pr" "it names $(loopable_safe "$ref"), which this token cannot resolve to a work item"
      continue
    }
    row=$(printf '%s\n' "$ITEMS_CACHE" | awk -F'\t' -v want="$id" '$1 == want {print; exit}')
    status=$(printf '%s' "$row" | cut -f2)
    title=$(loopable_safe "$(printf '%s' "$row" | cut -f3)")

    # THE STATUS IS NOT THE EVIDENCE, but it is the cheapest thing to be wrong
    # about, and `in_review` is the state the close contract itself writes —
    # so an item that is not there has not been closed, and saying so names the
    # actual next step instead of talking about shas.
    if [ "$status" != "in_review" ]; then
      printf 'PR #%s names %s (%s), which the backlog calls %s rather than in_review, so nobody has reported this work as finished.\n\n%s\n\n%s\n' \
        "$pr" "$title" "$id" "$status" "$(by_hand "$short")" "$OVERRIDE"
      continue
    fi

    sessions=$(loopable_sessions "$PROJECT" "$id") || {
      cannot_verify "$pr" "the sessions of $title ($id) could not be read"
      continue
    }

    matched=$(printf '%s\n' "$sessions" | awk -F'\t' -v s="$head" 'tolower($2) == s {print; exit}')
    if [ -z "$matched" ]; then
      newest=$(printf '%s\n' "$sessions" | awk -F'\t' 'NF > 1 && $2 != "" {print substr($2, 1, 12); exit}')
      if [ -z "$newest" ]; then
        printf 'PR #%s names %s (%s), and no closed session on it claims any commit at all, so nothing about this branch has been verified.\n\n%s\n\n%s\n' \
          "$pr" "$title" "$id" "$(by_hand "$short")" "$OVERRIDE"
      else
        # THE ONE THIS STORY EXISTS FOR. A close says "I verified THIS"; a
        # branch that moved afterwards is a branch nobody verified, and the
        # record still reads like a pass.
        printf 'PR #%s names %s (%s), whose newest complete close was verified at %s while this PR HEAD is %s — the branch moved after it was checked, so what is about to be merged is not what was verified.\n\nRe-run the verifier and close a session at %s.\n\n%s\n' \
          "$pr" "$title" "$id" "$newest" "$short" "$short" "$OVERRIDE"
      fi
      continue
    fi

    verdict=$(printf '%s' "$matched" | cut -f3)
    reason=$(loopable_safe "$(printf '%s' "$matched" | cut -f4)")
    [ -n "$reason" ] || reason='no reason given'
    case "$verdict" in
      pass) ;;
      fail)
        printf 'PR #%s names %s (%s), whose close at %s carries a verifier verdict of fail — %s — so what is about to be merged is known not to work.\n\nFix it, re-run the verifier and close a session at the new HEAD.\n\n%s\n' \
          "$pr" "$title" "$id" "$short" "$reason" "$OVERRIDE"
        ;;
      not_run)
        # not_run IS HONEST WHEN THERE WAS NOTHING TO RUN. S1.3 decided what
        # that means and stored it: a criterion whose `verify` is `browser` is
        # exactly the case the database makes screenshots mandatory for. No
        # such criterion, nothing for a browser verifier to drive, and the
        # verdict is a true statement rather than a gap.
        methods=$(loopable_verify_methods "$PROJECT" "$id") || {
          cannot_verify "$pr" "the acceptance criteria of $title ($id) could not be read, and its verdict is not_run"
          continue
        }
        if printf '%s\n' "$methods" | grep -qx 'browser'; then
          printf 'PR #%s names %s (%s), whose close at %s carries a verdict of not_run — %s — and its acceptance criteria include ones a browser has to check, so nothing was actually verified.\n\nRun the verifier against those criteria and close a session at this HEAD.\n\n%s\n' \
            "$pr" "$title" "$id" "$short" "$reason" "$OVERRIDE"
        fi
        ;;
      *)
        cannot_verify "$pr" "the close of $title ($id) carries no verdict this guard understands"
        ;;
    esac
  done <<EOF
$refs
EOF
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
