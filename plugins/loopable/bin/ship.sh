#!/usr/bin/env bash
# /loopable:ship — the whole finish sequence, as ONE script in TWO halves.
#
#   ship.sh --prepare [--trailer <line>]
#   ship.sh --close   [--trailer <line>]
#
# WHY TWO HALVES AND NOT ONE. `bin/start.sh` is a single call because every
# step of starting is a step a script can take. Finishing is not: between the
# checks and the close there are two SUBAGENTS to run, and a shell cannot
# spawn an agent. So the sequence is split at exactly the seam where a model
# is required, and `commands/ship.md` is three lines long — prepare, run the
# two agents, close. Everything on either side of that seam is code, for
# start.sh's reason: a model asked to remember eight steps will one day do
# seven of them, and the one it drops will be the one with a refusal in it.
#
# --prepare  refuses what cannot be shipped (no session, a dirty tree, a
#            branch nobody has pushed), clears any report left over from a
#            previous run, and prints the pack, the HEAD sha and the exact
#            shape the two reports must have.
# --close    reads the two reports, uploads them and the screenshots as
#            attachments on the session, posts the close contract, opens the
#            pull request naming the item, and says what moved.
#
# A COMMAND IS NOT A HOOK. Every failure here prints a sentence and exits
# non-zero — somebody typed this and is waiting for a pull request. The
# timeout grows for the same reason (LOOPABLE_MAX_TIME in lib.sh).
#
# NOTHING IS EVER UNDONE, and this one has a sharper edge than start.sh: once
# the close is posted the item has MOVED, and a `gh pr create` that fails
# afterwards leaves an item in `in_review` with no pull request. That is
# recoverable by hand and by running `--close` again (the second close is a
# 404 and the script says so while still opening the PR); a script that tried
# to reopen a closed session would be inventing a state the API refuses on
# purpose.
#
# A `fail` VERDICT STILL CLOSES. The contract wants the truth, and a harness
# that only reported successes would be a harness whose reports mean nothing.
# The pull request says so in its body, the script exits 1, and the merge
# guard refuses the merge until a `pass` at the HEAD being merged.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
. "$HERE/../hooks/lib.sh"

# Long enough for a cold Aurora and an S3 round trip, short enough that a
# person does not wonder whether it has hung.
LOOPABLE_MAX_TIME="${LOOPABLE_MAX_TIME:-20}"

say() { printf '%s\n' "$*"; }
die() { printf '%s\n' "$*" >&2; exit 1; }

MODE=""
TRAILER=""
while [ $# -gt 0 ]; do
  case "$1" in
    --prepare|--close) MODE=${1#--} ;;
    --trailer) TRAILER=${2:-}; shift ;;
    *) die "ship.sh takes --prepare or --close, and an optional --trailer <line>. Got: $1" ;;
  esac
  shift
done
[ -n "$MODE" ] || die "ship.sh takes --prepare or --close. /loopable:ship runs both, in that order."

for tool in jq git curl; do
  command -v "$tool" >/dev/null 2>&1 || die "$tool is needed to ship, and is not on PATH."
done
[ -n "$(loopable_token)" ] || die \
  "No Loopable token. Put one at ~/.config/loopable/token (0600), or set LOOPABLE_TOKEN."

# ----------------------------------------------------------- the worktree --
#
# THE BRANCH THIS COMMAND IS STANDING IN, not the session's project directory.
# `loopable_repo` prefers CLAUDE_PROJECT_DIR, which is where the session
# started — and a session started in the main checkout that then worked inside
# a worktree would ship the wrong branch's sha. So the worktree is resolved
# from the current directory and then EXPORTED as LOOPABLE_REPO, so that every
# helper below (the state dir, the config file) agrees with it.
WORKTREE=$(git rev-parse --show-toplevel 2>/dev/null) ||
  die "Not inside a git repository, so there is no branch to ship."
[ -n "$WORKTREE" ] || die "Not inside a git repository, so there is no branch to ship."
export LOOPABLE_REPO="$WORKTREE"

loopable_config_file >/dev/null 2>&1 ||
  die "No .loopable.yaml at $WORKTREE — this repository has not said which Loopable
project it belongs to, so there is no session to close and no item to name."
PROJECT=$(loopable_project) || die \
  "Cannot tell which project this repository belongs to: no \`project:\` in .loopable.yaml,
and this token can see more than one."

BRANCH=$(git -C "$WORKTREE" symbolic-ref --quiet --short HEAD 2>/dev/null) || BRANCH=""
case "$BRANCH" in
  '' ) die "HEAD is detached, so there is no branch to open a pull request from." ;;
  main|master) die "You are on $BRANCH. A pull request opens from a branch — /loopable:start
makes one, in its own worktree." ;;
esac

STATE=$(loopable_state_dir) || die "Cannot write under this repository's git directory."
ITEM=$(loopable_state item 2>/dev/null) || ITEM=""
SESSION=$(loopable_state session 2>/dev/null) || SESSION=""
if [ -z "$ITEM" ] || [ -z "$SESSION" ]; then
  die "This worktree has no Loopable session open, so there is nothing to close.

Work is started with:

  /loopable:start <item id | ref | next>

which claims the item, makes the worktree and opens the session. If the session
was opened elsewhere, put its ids in $STATE/item and $STATE/session."
fi

# ------------------------------------------------------------- the checks --
#
# THIS SCRIPT COMMITS NOTHING AND PUSHES NOTHING, and both refusals below come
# from that one decision. A close says "I verified THIS commit"; a script that
# committed on the way past would be closing at a commit no verifier ever saw,
# and a script that pushed would be deciding on somebody's behalf that the work
# is ready to leave the machine. So the tree must be clean and the branch must
# already be on the remote, and the refusal prints the command to run.
DIRTY=$(git -C "$WORKTREE" status --porcelain 2>/dev/null | grep -c .)
if [ "$DIRTY" != 0 ]; then
  die "$DIRTY file(s) are uncommitted, so the sha a verifier checked is not the sha
about to be shipped. Commit them first:

  git -C $WORKTREE add -A && git -C $WORKTREE commit

Then run /loopable:ship again. This command never commits for you."
fi

UPSTREAM=$(git -C "$WORKTREE" rev-parse --abbrev-ref '@{u}' 2>/dev/null) || UPSTREAM=""
HEAD_SHA=$(git -C "$WORKTREE" rev-parse HEAD 2>/dev/null | tr 'A-Z' 'a-z')
[ -n "$HEAD_SHA" ] || die "This branch has no commits yet, so there is nothing to ship."
if [ -z "$UPSTREAM" ]; then
  die "$BRANCH has never been pushed, so there is no pull request to open on it:

  git -C $WORKTREE push -u origin $BRANCH

Then run /loopable:ship again. This command never pushes for you."
fi
REMOTE_SHA=$(git -C "$WORKTREE" rev-parse "$UPSTREAM" 2>/dev/null | tr 'A-Z' 'a-z')
if [ "$REMOTE_SHA" != "$HEAD_SHA" ]; then
  die "$BRANCH is ahead of $UPSTREAM: the close would claim $(printf '%s' "$HEAD_SHA" | cut -c1-12)
and the pull request would carry $(printf '%s' "$REMOTE_SHA" | cut -c1-12).

  git -C $WORKTREE push

Then run /loopable:ship again. This command never pushes for you."
fi

SHORT=$(printf '%s' "$HEAD_SHA" | cut -c1-12)
REPORTS="$STATE"
VERIFY_JSON="$REPORTS/verify.json"
VERIFY_MD="$REPORTS/verify.md"
REVIEW_MD="$REPORTS/review.md"
EVIDENCE="$REPORTS/evidence"

# The API, with the BODY and the STATUS both — unlike the hooks' helpers,
# which use `curl -f` and throw the body away. A 422 from the close contract
# names every missing field at once, and that sentence is the most useful
# thing this script can print.
# THE STATUS TRAVELS THROUGH A FILE, not a variable, because every call here
# is `x=$(api ...)` — a command substitution is a subshell, and a variable it
# sets is gone by the time the caller reads it. That bug is invisible until
# the day something refuses and the refusal says "HTTP 0".
API_CODE_FILE="${TMPDIR:-/tmp}/loopable-ship-$$.code"
trap 'rm -f "$API_CODE_FILE"' EXIT
api_code() { cat "$API_CODE_FILE" 2>/dev/null || printf '0'; }
api() { # api <METHOD> <path> [json body] -> the body on stdout, the status in api_code
  local out code token
  local -a data=()
  token=$(loopable_token)
  # An ARRAY, not `${3:+--data-binary "$3"}`: a JSON body has spaces in it and
  # an unquoted expansion would hand curl a dozen arguments.
  [ $# -ge 3 ] && data=(--data-binary "$3")
  out=$(curl -sS --max-time "$LOOPABLE_MAX_TIME" -X "$1" \
    -w '\n%{http_code}' \
    -H "Authorization: Bearer $token" -H 'Content-Type: application/json' \
    "${data[@]}" "$LOOPABLE_API$2" 2>/dev/null) || { printf '0' > "$API_CODE_FILE"; return 1; }
  code=$(printf '%s' "$out" | tail -1)
  printf '%s' "$code" > "$API_CODE_FILE"
  printf '%s' "$out" | sed '$d'
  case "$code" in 2*) return 0 ;; *) return 1 ;; esac
}
api_message() { # the API's own sentence, or a fallback
  local m; m=$(printf '%s' "$1" | jq -r '.message // .error // empty' 2>/dev/null)
  [ -n "$m" ] || m="HTTP $(api_code)"
  loopable_safe "$m"
}

# ============================================================== --prepare ==
if [ "$MODE" = prepare ]; then
  ANSWER=$(api GET "/agent/projects/$PROJECT/items/$ITEM/pack") || die \
    "The backlog did not answer for $ITEM ($(api_message "$ANSWER")). Nothing has been changed."
  PACK=$(printf '%s' "$ANSWER" | jq -c '.pack // empty' 2>/dev/null)
  [ -n "$PACK" ] || die "The pack for $ITEM came back empty. Nothing has been changed."
  field() { printf '%s' "$PACK" | jq -r "$1 // empty"; }

  # LAST RUN'S REPORTS ARE THIS RUN'S LIE. A verify.md written at a commit
  # that has since moved is exactly the failure the merge guard's sha rule
  # exists to catch, and leaving it on disk lets --close pick it up. So
  # preparing clears them, out loud.
  STALE=0
  for f in "$VERIFY_JSON" "$VERIFY_MD" "$REVIEW_MD"; do
    [ -e "$f" ] && { rm -f "$f"; STALE=1; }
  done
  rm -rf "$EVIDENCE" 2>/dev/null
  mkdir -p "$EVIDENCE" 2>/dev/null

  say "Ready to ship — $(loopable_safe "$(field '.item.title')")"
  say "  item      $ITEM"
  say "  session   $SESSION"
  say "  branch    $BRANCH  (pushed, tree clean)"
  say "  HEAD      $HEAD_SHA"
  say "  brief_rev $(field '.item.brief_rev')"
  [ "$STALE" = 1 ] && say "  (cleared the reports from a previous run — they described another commit)"
  say

  ASK=$(field '.item.ask')
  [ -n "$ASK" ] && { say "The ask"; say "$ASK"; say; }

  say "Acceptance criteria — every one of these is accounted for in the close"
  CRIT=$(printf '%s' "$PACK" |
    jq -r '.criteria[]? | "  · [" + (.verify // "manual") + "] " + .text' 2>/dev/null)
  say "${CRIT:-  · none written yet — a close cannot account for nothing, and will be refused}"
  say

  ENV=$(printf '%s' "$PACK" | jq -r '.environments[]? | "  · " + .kind + "  " + (.base_url // "")' 2>/dev/null)
  if [ -n "$ENV" ]; then
    say "Environments — where a verifier may point"
    say "$ENV"
  else
    say "Environments — none registered. A browser criterion cannot be verified against"
    say "nothing: the verdict is not_run, with that as the reason."
  fi
  say

  say "Where the reports go"
  say "  $VERIFY_JSON   the verifier's verdict, machine-read by --close"
  say "  $VERIFY_MD     the same thing for a person, attached to the session"
  say "  $REVIEW_MD     the reviewer's findings, attached to the session"
  say "  $EVIDENCE/     screenshots, attached and named in the close contract"
  say
  say "verify.json, exactly:"
  say '  {"verdict": "pass | fail | not_run",'
  say '   "reason": "one sentence — required unless the verdict is pass",'
  say '   "environment": "the base url that was driven, or none",'
  say '   "criteria": [{"text": "<the criterion, verbatim>",'
  say '                 "verify": "browser | http | eval | manual",'
  say '                 "status": "met | not_met | skipped",'
  say '                 "evidence": "what was done and what was seen",'
  say '                 "implemented_at": "a path, a route, a test name",'
  say '                 "screenshot": "an absolute path under evidence/, for browser ones"}]}'
  say
  say "Every criterion above must appear, matched by its text. A close cannot leave"
  say "one open: not_met is recorded as skipped, which is how the register says"
  say "\"a person decided this one is not met\" and keeps it visible."
  say
  say "Now run the verifier and the reviewer, then: ship.sh --close"
  exit 0
fi

# ================================================================ --close ==
[ -r "$VERIFY_JSON" ] || die \
  "There is no verifier report at $VERIFY_JSON, so there is nothing to close with.

The verifier writes it. Run /loopable:ship from the top: it prepares, dispatches the
verifier and the reviewer, and only then closes. A close invented without a verifier
is the one thing the close contract exists to make impossible."
[ -r "$REVIEW_MD" ] || die \
  "There is no reviewer report at $REVIEW_MD. Both hands report, or neither does —
run the reviewer, then /loopable:ship --close."
jq -e . "$VERIFY_JSON" >/dev/null 2>&1 || die \
  "$VERIFY_JSON is not valid JSON. Rewrite it in the shape ship.sh --prepare printed."

VERDICT=$(jq -r '.verdict // empty' "$VERIFY_JSON")
REASON=$(jq -r '.reason // ""' "$VERIFY_JSON")
case "$VERDICT" in
  pass|fail|not_run) ;;
  *) die "The verifier's verdict is '$(loopable_safe "$VERDICT")'. It is one of pass, fail, not_run." ;;
esac
[ "$VERDICT" = pass ] || [ -n "$REASON" ] ||
  die "A verdict of $VERDICT needs a sentence saying why, in \`reason\`."

# ---------------------------------------------------- the criteria, by id --
#
# THE REPORT NAMES CRITERIA BY TEXT AND THE CONTRACT WANTS IDS. The pack a
# verifier reads carries no ids at all (that is pack.mjs's rule — titles, not
# uuids), so the mapping happens here, once, against the item's own brief.
#
# MATCHED ON THE WORDS, not on order or position: a report that reorders its
# rows is still a report, and a criterion that was edited between prepare and
# close should fail loudly rather than bind to whatever sat in that slot.
ITEM_JSON=$(api GET "/agent/projects/$PROJECT/items/$ITEM") || die \
  "The backlog did not answer for $ITEM ($(api_message "$ITEM_JSON")). Nothing has been closed."
BRIEF_REV=$(printf '%s' "$ITEM_JSON" | jq -r '.brief.brief_rev // 0')
KNOWN=$(printf '%s' "$ITEM_JSON" | jq -c '.brief.criteria // []')
[ "$(printf '%s' "$KNOWN" | jq 'length')" != 0 ] || die \
  "This item has no acceptance criteria, so a complete close has nothing to account
for and the API will refuse it. Write the brief first."

# One jq pass: normalise both sides to comparable words, join, and report what
# did not match. Shell looping over criteria would be the same logic spread
# over two languages.
MAPPED=$(jq -n \
  --argjson known "$KNOWN" \
  --slurpfile report "$VERIFY_JSON" '
  def norm: (. // "") | ascii_downcase | gsub("[^a-z0-9]+"; " ") | gsub("^ | $"; "");
  ($report[0].criteria // []) as $r
  | [ $known[] as $k
      | ($r | map(select((.text | norm) == ($k.text | norm))) | first) as $m
      | { id: $k.id, text: $k.text, verify: ($k.verify // "manual"), match: $m } ]
  | { rows: ., missing: [ .[] | select(.match == null) | .text ] }') ||
  die "Could not read the criteria out of $VERIFY_JSON."

MISSING=$(printf '%s' "$MAPPED" | jq -r '.missing[]?')
if [ -n "$MISSING" ]; then
  say "The verifier's report does not account for every acceptance criterion, and a" >&2
  say "close cannot leave one open. Missing:" >&2
  while IFS= read -r m; do [ -n "$m" ] && say "  · $(loopable_safe "$m")" >&2; done <<EOF
$MISSING
EOF
  die "
Run the verifier again over the whole brief. Nothing has been closed."
fi

# not_met BECOMES skipped, AND SAYS SO. `met` and `skipped` are the only two
# endings a close may write (CRITERION_ENDINGS in api/lib/sessions.mjs) —
# `open` is absent because a complete close whose criterion is still open
# contradicts itself. So a criterion the verifier could not get to met is
# recorded as the decision it is, with the words "not met" carried into
# implemented_at where a person reading the register will see them.
CRITERIA=$(printf '%s' "$MAPPED" | jq -c '[
  .rows[] |
  (.match.status // "skipped") as $s |
  (.match.implemented_at // .match.evidence // "no note") as $where |
  { id: .id,
    implemented_at: (if $s == "met" then $where else "not met — " + $where end),
    status: (if $s == "met" then "met" else "skipped" end) }]')

# --------------------------------------------------------- the cost, if any --
#
# ZERO IS AN HONEST ANSWER and the contract says so in its own words ("zero if
# it spent none"). Nothing in the plugin accumulates a token count today —
# S2.2's hooks post activities and never read a usage number, because no hook
# is given one — so unless something has written a `cost` file into the state
# directory, this is zeros, deliberately, rather than a guess.
COST='{"tokens":0,"usd":0}'
if [ -r "$STATE/cost" ] && jq -e '.tokens and .usd' "$STATE/cost" >/dev/null 2>&1; then
  COST=$(jq -c '{tokens: (.tokens|floor), usd: .usd}' "$STATE/cost")
fi

# ----------------------------------------------------------- attachments --
#
# THE ORDER IS REQUEST, PUT, CONFIRM, and it is the API's order rather than a
# convenience: the pending row is a promise, the presigned POST carries the
# policy that caps the size and pins the content type, and only HeadObject
# turns the row into a fact. Skipping the confirm leaves a row nothing can
# use — the close contract only accepts attachments whose status is 'stored'.
SHOTS='[]'
upload() { # upload <path> <content-type> -> the attachment id, or nothing
  local path=$1 type=$2 name req id fields url rc
  [ -r "$path" ] || return 1
  name=$(basename "$path")
  req=$(api POST "/agent/projects/$PROJECT/sessions/$SESSION/attachments" \
    "$(jq -nc --arg f "$name" --arg t "$type" '{filename: $f, content_type: $t}')") || {
      say "  ! $name — the upload was refused: $(api_message "$req")" >&2; return 1; }
  id=$(printf '%s' "$req" | jq -r '.attachment_id // empty')
  url=$(printf '%s' "$req" | jq -r '.upload.url // empty')
  [ -n "$id" ] && [ -n "$url" ] || { say "  ! $name — no presigned upload came back" >&2; return 1; }

  # The signed POST: every field of the policy, then the file LAST. S3 reads
  # the fields in order and ignores anything after the file part.
  local -a form=()
  while IFS=$'\t' read -r k v; do
    [ -n "$k" ] && form+=(-F "$k=$v")
  done <<EOF
$(printf '%s' "$req" | jq -r '.upload.fields // {} | to_entries[] | [.key, .value] | @tsv')
EOF
  form+=(-F "file=@$path;type=$type")
  curl -sS --max-time "$LOOPABLE_MAX_TIME" -o /dev/null -f "${form[@]}" "$url" 2>/dev/null || {
    say "  ! $name — the bytes did not reach the bucket" >&2; return 1; }

  local conf
  conf=$(api POST "/agent/projects/$PROJECT/sessions/$SESSION/attachments/$id/confirm" '{}') || {
    say "  ! $name — the upload was not confirmed: $(api_message "$conf")" >&2; return 1; }
  printf '%s' "$id"
}

say "Attaching what this run produced to session $SESSION"
for pair in "$VERIFY_MD:text/markdown" "$REVIEW_MD:text/markdown"; do
  f=${pair%:*}; t=${pair##*:}
  [ -r "$f" ] || continue
  if id=$(upload "$f" "$t"); then say "  · $(basename "$f")  $id"; fi
done

# Screenshots: whatever the report points at, deduplicated, images only. The
# contract calls these `screenshot_ids` and the database checks the content
# type, so a PDF named a screenshot is refused there — it is refused here
# first, by name, where the message can be about the file.
while IFS= read -r shot; do
  [ -n "$shot" ] || continue
  case "$shot" in /*) ;; *) shot="$WORKTREE/$shot" ;; esac
  [ -r "$shot" ] || { say "  ! $(basename "$shot") — named in the report, not on disk" >&2; continue; }
  case "$shot" in
    *.png) t=image/png ;; *.jpg|*.jpeg) t=image/jpeg ;;
    *.gif) t=image/gif ;; *.webp) t=image/webp ;;
    *) say "  ! $(basename "$shot") — a screenshot is an image; this is not one" >&2; continue ;;
  esac
  if id=$(upload "$shot" "$t"); then
    say "  · $(basename "$shot")  $id"
    SHOTS=$(printf '%s' "$SHOTS" | jq -c --arg i "$id" '. + [$i]')
  fi
done <<EOF
$(jq -r '[.criteria[]?.screenshot // empty] | unique | .[]' "$VERIFY_JSON")
EOF
say

# ---------------------------------------------------------- the contract --
SUMMARY="verifier $VERDICT at $SHORT"
[ -n "$REASON" ] && SUMMARY="$SUMMARY — $REASON"
PAYLOAD=$(jq -nc \
  --argjson rev "${BRIEF_REV:-0}" --arg sha "$HEAD_SHA" \
  --arg v "$VERDICT" --arg r "$REASON" --arg s "$SUMMARY" \
  --argjson c "$CRITERIA" --argjson shots "$SHOTS" --argjson cost "$COST" \
  '{state: "complete", summary: $s, brief_rev: $rev, head_sha: $sha,
    verdict: $v, verdict_reason: $r, criteria: $c,
    screenshot_ids: $shots, cost: $cost}')

CLOSED=1
OUT=$(api POST "/agent/projects/$PROJECT/sessions/$SESSION/close" "$PAYLOAD") || CLOSED=0
if [ "$CLOSED" = 1 ]; then
  say "Closed session $SESSION at $SHORT — verdict $VERDICT."
  # THE CLOSE IS THE REPORT. api/lib/sessions.mjs moves the item to in_review
  # in the same statement, through the transitions table. A report_progress
  # afterwards would be a second write saying what the first one already said,
  # and the day they disagree the item is the one that is wrong.
  say "The item moved to in_review with it — no separate progress report is needed."
else
  say "The close was refused: $(api_message "$OUT")" >&2
  case "$(api_code)" in
    404) say "That session is not open — it was closed already, or belongs to another project." >&2 ;;
  esac
  say "Continuing to the pull request: the branch is pushed and the reports are attached," >&2
  say "so the work is visible. Fix the refusal above and run /loopable:ship again." >&2
fi
say

# --------------------------------------------------------- the pull request --
command -v gh >/dev/null 2>&1 || die \
  "gh is not on PATH, so the pull request cannot be opened from here. The session
is closed; open the PR by hand and put \`Loopable: $ITEM\` in its body."

# The item, as a person reads it. The leading code — "S2.5 · " — is dropped:
# the short ref is already in the body and a title saying it twice is noise.
TITLE_RAW=$(printf '%s' "$ITEM_JSON" | jq -r '.item.title // ""')
KIND=$(printf '%s' "$ITEM_JSON" | jq -r '.item.kind // "story"')
REF=$(printf '%s' "$ITEM_JSON" | jq -r '.item.ref // empty')
ASK=$(printf '%s' "$ITEM_JSON" | jq -r '.item.ask // ""')
TITLE_TEXT=$(printf '%s' "$TITLE_RAW" | sed -E 's|^[[:space:]]*[A-Za-z]?[0-9]+(\.[0-9]+)*[[:space:]]*[^A-Za-z0-9]*||')
[ -n "$TITLE_TEXT" ] || TITLE_TEXT="$TITLE_RAW"
case "$KIND" in bug) TYPE=fix ;; *) TYPE=feat ;; esac
# The scope is the tracked path's own name when there is exactly one — which
# is what `.loopable.yaml` already says this repository cares about
# (`apps/loopable` → `loopable`). Two tracked paths, or none, and the title
# carries no scope rather than a guessed one.
SCOPE=$(loopable_paths | awk 'NR==1{p=$0} END{if (NR==1) {sub(/.*\//, "", p); print p}}')
if [ -n "$SCOPE" ]; then PR_TITLE="$TYPE($SCOPE): $TITLE_TEXT"; else PR_TITLE="$TYPE: $TITLE_TEXT"; fi

BODY="$STATE/pr-body.md"
{
  [ "$VERDICT" = pass ] ||
    printf '> **Not verified.** The verifier says `%s` — %s\n>\n> The merge guard refuses this until a session closes `pass` at the HEAD being merged.\n\n' \
      "$VERDICT" "$REASON"
  [ -n "$ASK" ] && printf '%s\n\n' "$ASK"
  printf '## Acceptance criteria\n\n'
  printf '%s' "$MAPPED" | jq -r '.rows[] |
    "- [" + (if (.match.status // "skipped") == "met" then "x" else " " end) + "] " +
    .text + " — " + (.match.status // "skipped") + " (" + .verify + ")" +
    (if (.match.evidence // "") != "" then "\n      " + .match.evidence else "" end)'
  printf '\n## Verification\n\n'
  printf 'Verdict `%s`' "$VERDICT"
  [ -n "$REASON" ] && printf ' — %s' "$REASON"
  printf '\n\nThe verifier'"'"'s and reviewer'"'"'s reports are attached to Loopable session `%s`, with the screenshots they cite.\n' "$SESSION"
  printf '\n## Reviewer\n\n'
  # The reviewer's own last word, which is a line in its report. Grepped
  # rather than parsed: the report is for people, and only this one line has
  # to be machine-readable.
  grep -iE '^[[:space:]]*(ship|hold)\b' "$REVIEW_MD" | head -1 |
    sed -E 's|^[[:space:]]*||' | awk 'NF {print "Verdict: " $0}'
  printf '\n'
  printf 'Loopable: %s\n' "${REF:-$ITEM}"
  [ -n "$TRAILER" ] && printf '\n%s\n' "$TRAILER"
} > "$BODY"

PR_URL=$(gh pr view --json url -q .url 2>/dev/null) || PR_URL=""
if [ -n "$PR_URL" ]; then
  gh pr edit --body-file "$BODY" >/dev/null 2>&1 ||
    say "The pull request body could not be updated; it is at $BODY." >&2
  say "Updated $PR_URL"
else
  # The exit code is what decides, so the output goes to a file rather than
  # through a pipe — `| tail -1` would report tail's success as gh's.
  if gh pr create --title "$PR_TITLE" --body-file "$BODY" > "$STATE/pr-out" 2>&1; then
    PR_URL=$(grep -oE 'https://[^[:space:]]+' "$STATE/pr-out" | tail -1)
    say "Opened ${PR_URL:-the pull request}"
  else
    die "gh pr create failed:

$(cat "$STATE/pr-out")

The session is closed and the reports are attached. Open the pull request by hand
with \`Loopable: ${REF:-$ITEM}\` in its body."
  fi
fi
say

if [ "$VERDICT" != pass ]; then
  say "The verdict is $VERDICT, so this is not mergeable yet: $REASON"
  say "Fix what the report names, commit, push, and run /loopable:ship again — the"
  say "close is bound to a commit, and a branch that moved after it was checked is a"
  say "branch nobody checked."
  exit 1
fi
say "Shipped. A person reviews the diff and the verdict, and merges."
exit 0
