#!/usr/bin/env bash
# The watch: one background process an agent keeps while it has anything in
# flight. It EXITS, and so wakes the agent, when something the agent named
# changed, and prints what changed, so the wake carries the news.
#
#   watch.sh [--project <id>]
#            [--inbox-session <uuid> | --inbox-person <uuid> | --inbox-lane <name>]
#            [--role <role>] [--self-session <uuid>] [--self-actor <name>]
#            [--ignore-kind <feed row kind>]...
#            [--item <ref>]... [--lane <name>]...
#            [--pr <number>]... [--branch <default branch>]
#            [--deadline <label>=<when>]...
#
# Run it with `run_in_background`; the agent starts it again, with what it now
# waits on, every time it wakes. ONE watch per agent.
#
# WHAT WAKES IT (exit 0, the news on stdout, one line each, `MESSAGE`, `CHANGE`,
# `PR`, `BRANCH` or `DEADLINE`):
#   - a message addressed to the inbox (a session, a person or a lane, exactly
#     one), read from the messages route after the cursor taken at the start.
#     `--role` keeps only messages whose to_role is that role;
#   - a row of the change feed (414) about a named item or lane: a move, a
#     message, a lane rewrite. The feed is only read when something is named,
#     because a read with nothing named is the whole project;
#   - a named pull request whose checks complete, that is reviewed or that
#     merges or closes; the default branch's latest completed run turning red;
#   - a deadline (`label=<when>`: epoch seconds, which is portable; any other
#     form needs GNU date -d) coming due.
# And after an hour (LOOPABLE_WATCH_MAX) whatever happened: exit 0 saying so.
# Free text in the news (a message's text, a feed summary, a run's name) is
# printed escaped on ONE line: a newline reads \n and any other control
# character ?, so nothing a sender wrote can start a line like the watch's own.
#
# THE WATCH REPORTS CHANGES, NOT STATE. A pull request already green when it
# starts is a baseline, not news: read `gh pr checks` once before starting it.
#
# WHAT IT IGNORES: everything before it started (the cursor of each read is
# taken once, at the start: a replayed history is not news); a message the
# agent's own session sent (`--self-session`, matched on from_session_id); and
# a pull request or a branch that stays as it was. The change feed names NO
# session, and today its `actor` is null on every row (454 asks for a session
# on the rows), so an agent's own moves are told apart by what they are:
#   --ignore-kind <kind>   (repeatable) drops feed rows of that kind, for the
#                          kinds only this agent writes on its item, such as
#                          item_moved and session_closed for the driver. A
#                          person's move of the same kind is dropped with it.
#   --role <role>          also drops the feed's messages sent BY that role
#                          (the summary names the sender's role).
#   --self-actor <name>    drops rows whose actor is that name, for the day the
#                          feed carries one (it names the token's user, not the
#                          agent, so share-nothing tokens only).
#
# WHEN IT CANNOT READ: three reads of Loopable in a row, or of GitHub, that
# fail (no answer, or a 5xx) end it with exit 2 and a line saying which. The
# agent falls back to a timer then. No token is the same, at once. A 4xx is a
# refusal, not an outage: it ends the watch at once with exit 64 and the
# refusal, and a bad --item is refused at the start.
#
# HOW FAST: Loopable is polled every 30 seconds, GitHub every 60 (the answer to
# the item's open question). A held-open read in the API is a follow-up.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
. "$HERE/../hooks/lib.sh"

LOOPABLE_MAX_TIME="${LOOPABLE_MAX_TIME:-10}"
MAX="${LOOPABLE_WATCH_MAX:-3600}"
EVERY="${LOOPABLE_WATCH_EVERY:-30}"
GH_EVERY="${LOOPABLE_WATCH_GH_EVERY:-60}"
MAX_FAILS=3

die() { printf '%s\n' "$*" >&2; exit 64; }

PROJECT="" ISESSION="" IPERSON="" ILANE="" ROLE="" SELF_SESSION="" SELF_ACTOR="" IGNORE_KINDS=""
BRANCH=""
ITEMS=() LANES=() PRS=() DEADLINES=()
while [ $# -gt 0 ]; do
  [ $# -ge 2 ] || die "watch.sh: $1 takes a value."
  case "$1" in
    --project) PROJECT=$2 ;;
    --inbox-session) ISESSION=$2 ;;
    --inbox-person) IPERSON=$2 ;;
    --inbox-lane) ILANE=$2 ;;
    --role) ROLE=$2 ;;
    --self-session) SELF_SESSION=$2 ;;
    --self-actor) SELF_ACTOR=$2 ;;
    --ignore-kind) IGNORE_KINDS="${IGNORE_KINDS:+$IGNORE_KINDS,}$2" ;;
    --item)
      [[ "$2" =~ ^[0-9]{1,9}$ || "$2" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]] ||
        die "watch.sh: --item is a ref (a number) or a uuid, as the change feed reads it. Got: $2. A question is a message: pass the item it is about."
      ITEMS+=("$2") ;;
    --lane) LANES+=("$2") ;;
    --pr) PRS+=("$2") ;;
    --branch) BRANCH=$2 ;;
    --deadline) DEADLINES+=("$2") ;;
    *) die "watch.sh: unknown argument $1." ;;
  esac
  shift 2
done

INBOXES=0
for v in "$ISESSION" "$IPERSON" "$ILANE"; do [ -n "$v" ] && INBOXES=$((INBOXES + 1)); done
[ "$INBOXES" -le 1 ] || die "watch.sh: name one inbox: a session, a person or a lane."
[ "$INBOXES" -gt 0 ] || [ ${#ITEMS[@]} -gt 0 ] || [ ${#LANES[@]} -gt 0 ] || [ ${#PRS[@]} -gt 0 ] ||
  [ -n "$BRANCH" ] || [ ${#DEADLINES[@]} -gt 0 ] || die "watch.sh: nothing to watch. Name an inbox, an item, a lane, a pull request, a branch or a deadline."

for tool in jq curl; do
  command -v "$tool" >/dev/null 2>&1 || die "watch.sh needs $tool on PATH."
done

WATCH_LOOPABLE=0
{ [ "$INBOXES" -gt 0 ] || [ ${#ITEMS[@]} -gt 0 ] || [ ${#LANES[@]} -gt 0 ]; } && WATCH_LOOPABLE=1
WATCH_GH=0
{ [ ${#PRS[@]} -gt 0 ] || [ -n "$BRANCH" ]; } && WATCH_GH=1

if [ "$WATCH_LOOPABLE" = 1 ]; then
  [ -n "$(loopable_token)" ] || { echo "WATCH cannot read Loopable: no token. Fall back to a timer." >&2; exit 2; }
  [ -n "$PROJECT" ] || PROJECT=$(loopable_project 2>/dev/null) || PROJECT=""
  [ -n "$PROJECT" ] || die "watch.sh: no project. Pass --project <id> (from whoami)."
fi

# Each deadline as `label<TAB>epoch`, kept where the loop reads it.
DL_LABELS=() DL_EPOCHS=()
for d in "${DEADLINES[@]+"${DEADLINES[@]}"}"; do
  label=${d%=*}; when=${d##*=}
  [ "$label" != "$d" ] || die "watch.sh: a deadline is <label>=<when>. Got: $d"
  if [[ "$when" =~ ^[0-9]+$ ]]; then epoch=$when; else epoch=$(date -d "$when" +%s 2>/dev/null) || die "watch.sh: cannot read the time in deadline $d."; fi
  DL_LABELS+=("$label"); DL_EPOCHS+=("$epoch")
done

STATE=$(mktemp -d)
trap 'rm -rf "$STATE"' EXIT
OUT="$STATE/out"; : > "$OUT"
emit() { printf '%s\n' "$*" >> "$OUT"; }
uri() { jq -rn --arg v "$1" '$v|@uri'; }

# Every free-text field printed is ONE line with no control character in it
# (a newline becomes the two characters \n, any other control becomes ?), so
# text somebody else wrote can never start a line that looks like the watch's
# own (MESSAGE, CHANGE, PR, BRANCH, DEADLINE).
ESC='def esc: tostring | gsub("\n"; "\\n") | gsub("[\u0000-\u001f\u007f-\u009f  ]"; "?");'

# lget <path>: the body on stdout. Returns 1 when Loopable cannot be read (no
# answer, or a 5xx), and 3 when it ANSWERED with a refusal (a 4xx), keeping the
# refusal in $STATE/refused: that is a wrong argument or a lost token, not an
# outage, and a timer would not fix it.
lget() {
  local token out code
  token=$(loopable_token); [ -n "$token" ] || return 1
  out=$(curl -sS --max-time "$LOOPABLE_MAX_TIME" -w '\n%{http_code}' \
    -H "Authorization: Bearer $token" "$LOOPABLE_API$1" 2>/dev/null) || return 1
  code=${out##*$'\n'}; out=${out%$'\n'*}
  case "$code" in
    2??) printf '%s' "$out" ;;
    4??) printf '%s %s' "$code" "$out" | jq -Rr "$ESC"' esc' > "$STATE/refused"; return 3 ;;
    *) return 1 ;;
  esac
}

# ---------------------------------------------------------------- Loopable --
MCURSOR="" CCURSOR=""
LFAIL=0 GFAIL=0

inbox_url() { # inbox_url <after> <limit>
  local sel
  if [ -n "$ISESSION" ]; then sel="session=$(uri "$ISESSION")"
  elif [ -n "$IPERSON" ]; then sel="person=$(uri "$IPERSON")"
  else sel="lane=$(uri "$ILANE")"; fi
  printf '/agent/projects/%s/messages?%s&after=%s&limit=%s' "$PROJECT" "$sel" "$1" "$2"
}

# The cursor of "now": page through the inbox until a short page, because the
# route has no "latest" and reads oldest first.
inbox_baseline() {
  local after=0 r n
  while :; do
    r=$(lget "$(inbox_url "$after" 500)") && jq -e '.messages' >/dev/null 2>&1 <<<"$r" || return 1
    n=$(jq '.messages | length' <<<"$r"); after=$(jq -r '.cursor // 0' <<<"$r")
    [ "$n" -lt 500 ] && break
  done
  MCURSOR=$after
}

inbox_poll() {
  local r
  r=$(lget "$(inbox_url "$MCURSOR" 200)") && jq -e '.messages' >/dev/null 2>&1 <<<"$r" || return 1
  MCURSOR=$(jq -r --arg c "$MCURSOR" '.cursor // $c' <<<"$r")
  jq -r --arg role "$ROLE" --arg self "$SELF_SESSION" "$ESC"'
    .messages[]
    | select(($role == "" or .to_role == $role) and ($self == "" or .from_session_id != $self))
    | "MESSAGE \(.type | esc) from \(.from_role | esc) to \(.to_role | esc) item \(.item_id // "-" | esc) lane \(.lane // "-" | esc) id \(.id // "-" | esc)\n  \((.text // "")[0:2000] | esc)"' \
    <<<"$r" >> "$OUT"
}

feed_url() { # feed_url [cursor]
  local q="" i
  [ -n "${1:-}" ] && q="cursor=$(uri "$1")"
  if [ ${#ITEMS[@]} -gt 0 ]; then i=$(IFS=,; echo "${ITEMS[*]}"); q="${q:+$q&}items=$(uri "$i")"; fi
  if [ ${#LANES[@]} -gt 0 ]; then i=$(IFS=,; echo "${LANES[*]}"); q="${q:+$q&}lanes=$(uri "$i")"; fi
  printf '/agent/projects/%s/changes%s' "$PROJECT" "${q:+?$q}"
}

feed_poll() {
  local r
  if [ -z "$CCURSOR" ]; then
    # A read with no cursor is "now" with no history, and names nothing.
    r=$(lget "/agent/projects/$PROJECT/changes") && jq -e '.cursor' >/dev/null 2>&1 <<<"$r" || return 1
    CCURSOR=$(jq -r '.cursor' <<<"$r"); return 0
  fi
  r=$(lget "$(feed_url "$CCURSOR")") && jq -e '.changes' >/dev/null 2>&1 <<<"$r" || return 1
  CCURSOR=$(jq -r --arg c "$CCURSOR" '.cursor // $c' <<<"$r")
  jq -r --arg role "$ROLE" --arg actor "$SELF_ACTOR" --arg kinds "$IGNORE_KINDS" "$ESC"'
    ($kinds | split(",")) as $skip
    | .changes[]
    | select(($actor == "" or .actor != $actor)
             and ((.kind as $k | $skip | index($k)) == null)
             and (($role == "" or .kind != "message") or (.summary | test("^[a-z_]+ " + $role + " to ") | not)))
    | "CHANGE \(.kind | esc) item \(.item // "-" | esc) lane \(.lane // "-" | esc) at \(.at // "-" | esc): \((.summary // "")[0:400] | esc)"' \
    <<<"$r" >> "$OUT"
}

poll_loopable() {
  local ok=1
  if [ "$INBOXES" -gt 0 ]; then
    if [ -z "$MCURSOR" ]; then inbox_baseline || ok=0; else inbox_poll || ok=0; fi
  fi
  if [ ${#ITEMS[@]} -gt 0 ] || [ ${#LANES[@]} -gt 0 ]; then feed_poll || ok=0; fi
  if [ "$ok" = 1 ]; then LFAIL=0; else LFAIL=$((LFAIL + 1)); fi
}

# ------------------------------------------------------------------ GitHub --
pr_snapshot() { # -> {state, review, checks} as one json line
  gh pr view "$1" --json state,reviewDecision,statusCheckRollup 2>/dev/null | jq -ce '
    (.statusCheckRollup // []) as $c
    | {state: (.state // ""), review: (.reviewDecision // ""),
       checks: (if ($c | length) == 0 then "none"
                elif any($c[]; ((.status // "COMPLETED") != "COMPLETED") or ((.state // "") | IN("PENDING", "EXPECTED"))) then "pending"
                elif any($c[]; ((.conclusion // "") | IN("FAILURE", "TIMED_OUT", "CANCELLED", "ACTION_REQUIRED", "STARTUP_FAILURE"))
                              or ((.state // "") | IN("FAILURE", "ERROR"))) then "red"
                else "green" end)}'
}

poll_pr() { # poll_pr <number>
  local n=$1 new old f="$STATE/pr-$1"
  new=$(pr_snapshot "$n") && [ -n "$new" ] || return 1
  if [ -f "$f" ]; then
    old=$(cat "$f")
    local os ns orv nrv oc nc
    os=$(jq -r .state <<<"$old"); ns=$(jq -r .state <<<"$new")
    orv=$(jq -r .review <<<"$old"); nrv=$(jq -r .review <<<"$new")
    oc=$(jq -r .checks <<<"$old"); nc=$(jq -r .checks <<<"$new")
    [ "$os" = "$ns" ] || emit "PR #$n state $os -> $ns"
    [ "$orv" = "$nrv" ] || emit "PR #$n review ${orv:-none} -> ${nrv:-none}"
    if [ "$oc" != "$nc" ] && { [ "$nc" = green ] || [ "$nc" = red ]; }; then emit "PR #$n checks complete: $nc"; fi
  fi
  printf '%s' "$new" > "$f"
}

poll_branch() {
  local run old f="$STATE/branch" id conclusion
  run=$(gh run list --branch "$BRANCH" --limit 5 --json databaseId,status,conclusion,name 2>/dev/null |
    jq -ce '[.[] | select(.status == "completed")][0] // {}') && [ -n "$run" ] || return 1
  id=$(jq -r '.databaseId // "none"' <<<"$run"); conclusion=$(jq -r '.conclusion // ""' <<<"$run")
  if [ -f "$f" ]; then
    old=$(cat "$f")
    if [ "$conclusion" = failure ] && [ "$old" != "$id:failure" ]; then
      emit "BRANCH $BRANCH is red: run $(jq -r "$ESC"' (.databaseId // "-") | esc' <<<"$run") ($(jq -r "$ESC"' (.name // "-") | esc' <<<"$run")) failed"
    fi
  fi
  printf '%s' "$id:$conclusion" > "$f"
}

poll_github() {
  local ok=1 n
  command -v gh >/dev/null 2>&1 || ok=0
  if [ "$ok" = 1 ]; then
    for n in "${PRS[@]+"${PRS[@]}"}"; do poll_pr "$n" || ok=0; done
    [ -z "$BRANCH" ] || poll_branch || ok=0
  fi
  if [ "$ok" = 1 ]; then GFAIL=0; else GFAIL=$((GFAIL + 1)); fi
}

# -------------------------------------------------------------------- loop --
START=$(date +%s)
LAST_GH=0
while :; do
  now=$(date +%s)
  [ "$WATCH_LOOPABLE" = 0 ] || poll_loopable
  if [ "$WATCH_GH" = 1 ] && [ $((now - LAST_GH)) -ge "$GH_EVERY" ]; then LAST_GH=$now; poll_github; fi

  if [ -s "$STATE/refused" ]; then
    echo "WATCH Loopable refused a read (HTTP $(cat "$STATE/refused")). That is an argument or a token, not an outage: fix it and start the watch again." >&2; exit 64
  fi
  if [ "$LFAIL" -ge "$MAX_FAILS" ]; then
    echo "WATCH cannot read Loopable: $MAX_FAILS reads in a row failed. Fall back to a timer." >&2; exit 2
  fi
  if [ "$GFAIL" -ge "$MAX_FAILS" ]; then
    echo "WATCH cannot read GitHub: $MAX_FAILS reads in a row failed. Fall back to a timer." >&2; exit 2
  fi

  nap=$EVERY
  for i in "${!DL_EPOCHS[@]}"; do
    left=$((DL_EPOCHS[i] - now))
    if [ "$left" -le 0 ]; then emit "DEADLINE ${DL_LABELS[i]} is due"
    elif [ "$left" -lt "$nap" ]; then nap=$left; fi
  done
  if [ -s "$OUT" ]; then cat "$OUT"; exit 0; fi

  left=$((START + MAX - now))
  if [ "$left" -le 0 ]; then
    echo "WATCH ended: nothing happened in ${MAX} seconds, the most a watch runs. Start it again with what you still wait on."
    exit 0
  fi
  [ "$left" -lt "$nap" ] && nap=$left
  sleep "$nap"
done
