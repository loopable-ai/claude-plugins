#!/usr/bin/env bash
# PreToolUse/Bash. Refuses to merge a pull request whose head the backlog's own
# record says is broken, or is not the head that was verified — and lets every
# other merge through, out loud and on the record.
#
# WHY THIS EXISTS. Phase 2 shipped four PRs — Bedrock, conversations, the PO's
# grounding, the engine — and every one of its backlog items still read "Not
# Started" afterwards. The plan had predicted exactly that, in writing:
# "reporting completion has to sit on the path already being walked ... if it
# becomes a detour we will have rebuilt the same problem behind a nicer
# screen." A reminder is a detour. This sits on the path.
#
# THE RULE (363, plan W4). "What should the merge guard still refuse once the
# driver judges merges?" — "Only a failed or moved head" (Joel, 2026-11-07).
# For a PR that touches what `.loopable.yaml` lists under `paths:` (or anything
# at all, when it lists nothing), and the item it belongs to:
#
#   · A FAILED HEAD. The item's newest complete close at THIS PR's HEAD sha
#     carries the verifier verdict `fail`: what is about to be merged is known
#     not to work.
#   · A MOVED HEAD. The item has complete closes and none of them is at this
#     PR's HEAD sha: the branch moved after it was verified, so what is about
#     to be merged is not what was verified. A close says "I verified THIS";
#     push three more commits and that sentence is still on the record and no
#     longer about the thing being merged. One string comparison is the whole
#     difference between a report and evidence.
#
# A PASS THAT OWES A CHECK AFTER THE MERGE IS A PASS (365). A close may leave a
# criterion `after_merge` — one only the deploy can show — and its verdict is
# still `pass`, which is all this guard reads: the merge is what lets that
# check run, so refusing it would keep the check from ever happening. The
# driver runs it after the deploy, with the item in `verifying`.
#
# WHATEVER THE ITEM'S STATUS (brief rev 2). The record of a close is the
# evidence; a status is a sentence somebody typed, and an item moved off
# in_review after a failed close is still an item whose head failed.
#
# WHATEVER THE BODY SAYS. The item is the one the body names; when it names
# none — no `Loopable:` line, `Loopable: none`, a ref nothing answers to — it is
# the one the sessions tied to this PR belong to: a close that recorded this
# PR's number, or a session on its head branch. Leaving the line out is not a
# way past either rule.
#
# Both are CONFIDENT NEGATIVES — the backlog answered and its own record says
# no — which is lib.sh's rule for every hook, and this one is no longer the
# exception to it.
#
# EVERYTHING ELSE IS ALLOWED, WITH A WARNING ON STDERR AND A `guard_allowed`
# ACTIVITY naming the PR, the reason and the head:
#
#   no_marker        the PR names no item (no `Loopable:` line)
#   none             `Loopable: none — <why>`
#   unresolved_ref   a ref this token cannot resolve to an item
#   not_in_review    the item is not in_review
#   no_session       the item has no complete close at all
#   not_run          the close at this head says nothing verified it
#   unknown_verdict  the close at this head carries a verdict not listed here
#   unreachable      the backlog did not answer: no token, no network, asleep
#   no_project       this repository resolves to no Loopable project
#   no_pr_resolved   the merge names no PR the guard could resolve (printed only)
#
# WHY ALLOW WHAT CANNOT BE VERIFIED. The guard used to refuse every one of
# those, on the argument that a merge cannot be taken back. Under the driver
# that argument points the other way: a `not_run`, an item with no close, a
# backlog that is asleep are JUDGEMENTS — hand it to a person, merge after a
# check by hand, wait — and the driver and the person merging are the ones who
# make them. A wall that refuses a decision somebody has already weighed gets
# its door used every time, and `LOOPABLE_ALLOW_MERGE=1` records nothing. So
# the guard keeps the two refusals nobody needs to weigh, and turns the rest
# into a record: a warning in the terminal, and an activity the factory can
# count (AGENTS.md, "Legibility is the rule").
#
# WHERE IT IS RECORDED: on the item's NEWEST CLOSED session, never an open one.
# An activity on an open session marks it active and resets its clock
# (postActivity in api/lib/sessions.mjs), which would un-mark a stall the stall
# clock found, on the say-so of a merge somebody else typed; a closed session
# takes the line from the member who held it and changes nothing about its
# ending. No item, no closed session on it, or no backlog to post to, and the
# warning is the only record — and it says which of those it was. A merge that
# is refused records nothing at all: nothing was let through.
#
# THE OVERRIDE IS A PERSON'S, NOT A COMMAND'S. `LOOPABLE_ALLOW_MERGE=1` is read
# from THIS PROCESS's environment — the session the hook runs inside — and a
# `LOOPABLE_ALLOW_MERGE=1 gh pr merge 9` typed as a command sets it in a child
# shell this hook never sees. So the escape hatch belongs to whoever started
# the session, which is a person, and an agent cannot reach for it by writing a
# longer command. Every refusal prints it, because a guard that cannot be
# overridden is a guard that gets deleted.
#
# `gh` ITSELF FAILING IS A SILENT PASS. If `gh pr view` cannot answer, `gh pr
# merge` cannot merge either — there is no PR to warn about, and nothing to
# record it against.
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

# Printed under every refusal, and it is not decoration. The security rounds'
# honest conclusion is that a guard written in shell against attacker-shaped
# input will get something wrong; the cost of that being survivable is that
# the person it blocks wrongly has a documented door.
OVERRIDE='If this is wrong — the close is somebody else'"'"'s, the check itself is broken — a person can start the session with LOOPABLE_ALLOW_MERGE=1 and merge anyway. Prefixing the command with it does nothing: the hook reads its own environment, not yours.'

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

# FIRST: IS THIS A MERGE AT ALL? `gh pr`, then `merge` somewhere after it, or
# nothing; the reading below decides whether `merge` is the subcommand.
#
# It once was not asking: every integer in any command was looked up as a PR,
# so a `wc -l` on a scratch file whose path spelled a PR number was denied, and
# so was the grep that found it, and so was the bug report quoting both. The
# words are case-insensitive, and `gh` must be a word of its own — `github pr
# merge` is not a merge, and this repository lives under a path containing it.
#
# ON THE COMMAND AS THE SHELL WILL SEE IT, not as it was typed (security
# review of round 1). The shell joins a backslash-newline and drops quotes
# inside a word, so `g"h" pr merge 5` and `gh \<newline> pr merge 5` both run
# a merge while the raw text spells neither `gh pr` nor `merge`. NORM is the
# text with backslash-newlines joined and every quote and backslash removed:
# too crude to read arguments from, exactly right for "could this be a merge".
# ONE PASS, which also answers where each of its characters stood in the raw
# text (P, a list of NORM positions, in; their raw positions, out): a merge the
# shell's reading finds is matched to the raw reading by where its `gh` stands.
NORM_AWK='{ s = s (NR > 1 ? "\n" : "") $0 }
END {
  n = length(s); out = ""; k = 0
  for (i = 1; i <= n; i++) {
    c = substr(s, i, 1)
    if (c == "\\" && substr(s, i + 1, 1) == "\n") { i++; continue }
    if (c == "\\" || c == "\"" || c == SQ) continue
    out = out c; k++; at[k] = i
  }
  if (P == "") { printf "%s", out; exit }
  m = split(P, ps, " ")
  for (j = 1; j <= m; j++) print at[ps[j]]
}'
NORM=$(printf '%s\n' "$CMD" | awk -v SQ="'" -v P= "$NORM_AWK")
printf '%s' "$NORM" | grep -qiE '(^|[^[:alnum:]_])gh[[:space:]]+pr[[:space:]]' || pass
printf '%s' "$NORM" | grep -qiE 'merge' || pass

# A COMMAND THAT CANNOT RUN ANOTHER PROGRAM CANNOT MERGE, whatever it quotes.
#
# THE TEST IS "CANNOT RUN ANOTHER PROGRAM", not "reads text". The first version
# of this list was a list of text tools, and text tools execute things: awk has
# system(), GNU sed has the `e` command, rg and ag take --pre, and less, more
# and man all have a `!` shell escape. Three of them were confirmed running the
# very command being guarded:
#
#     awk "BEGIN{system(\"gh pr merge 367\")}"     passed
#     sed '1e gh pr merge 367' /dev/null           passed
#
# So the list is only programs that cannot start another one. There is a test
# asserting membership rather than behaviour, so putting awk back fails on the
# list itself rather than on somebody remembering to write the exploit.
#
# ONLY FOR A COMMAND WITH NO SHELL METACHARACTER AT ALL (security review, fix
# round 4): `echo 'gh pr merge' | bash`, `$(echo ...)`, `echo ... > >(bash)`
# hand the text to something that runs it, and `echo ok; gh pr merge 9` or
# `true && gh pr merge 9` (bug 372) run a second command the first word says
# nothing about. A list of the dangerous ones missed `>(` the day it was
# written, so the fast path fails closed instead: any of | & ; < > ( ) $ ` or
# a newline, and the command goes to the reader like any other.
CANNOT_EXEC='echo printf cat head tail comm'
FIRST=$(printf '%s' "$CMD" | sed -nE 's|^[[:space:]]*([A-Za-z0-9_./-]+).*|\1|p' | head -1)
NL='
'
case $CMD in
  *[\|\&\;\<\>\(\)\$\`]*|*"$NL"*) ;;
  *) for safe in $CANNOT_EXEC; do
       [ "${FIRST##*/}" = "$safe" ] && pass
     done ;;
esac

# THE PR ARGUMENT, READ THE WAY gh READS IT (363, brief rev 2).
#
# Every integer in the command used to be a candidate PR, which was right about
# `gh pr merge --squash 367` and wrong about everything after the number: in
# `gh pr merge 85 --merge --match-head-commit 54bbc22 --delete-branch 2>&1 |
# tail -5`, the sha, the `2>&1` and the `tail` each named a PR of their own,
# and a good merge was refused for somebody else's. So for every `gh pr [its
# options] merge` in the command, the guard reads what gh itself reads as the
# pull request — the first word that is not an option or an option's value —
# and prints one line for it:
#
#   PR <n>       a number, `#<n>`, or a pull request url
#   BRANCH <b>   a branch name, which gh resolves to its PR
#   CURRENT      no argument at all: gh merges the current branch's PR
#   UNKNOWN      it cannot tell — and then every integer in the command is a
#                candidate, as it was before 363, and the current branch's PR
#                too unless its command never runs its arguments (runs_string)
#
# OPTIONS THE WAY gh's FLAG PARSER (pflag) READS THEM. A long option that takes
# a value (--repo, --subject, --body, --body-file, --author-email,
# --match-head-commit) takes the next word unless it carries `=`. In a short
# cluster the first letter that takes a value (R t b F A; `gh pr` itself takes
# only R) takes the REST of the word — `-Rowner/name`, `-dRo/r`, `-tSubject`,
# `-b2` — or the next word when it is the last letter (`-sR o/r`). The first
# round looked only at the last letter, and `-Rowner/name 9` read no PR at all.
#
# NOT A SHELL PARSER, AND IT DOES NOT DECIDE "INVOKED OR MENTIONED". The words
# are found wherever they are, inside quotes included, because `eval`, `bash
# -c`, awk's system() and sed's `e` all run what they quote. What is read is
# only the words after `gh`: a quoted stretch is part of its word, a redirect
# and its target are skipped (`2>&1`'s `2` is the redirect's, not a PR), and a
# `;`, `&`, `|`, `(`, `)`, newline, backtick or `#` ends the command. A quote or
# a backslash that closes whatever the words sat inside ends them too, and
# what it leaves unread is UNKNOWN rather than CURRENT: `grep 'gh pr merge'`
# is not a merge of the current branch.
MERGE_ARGS='
function pr_of(w) {
  sub(/^#/, "", w)
  if (w ~ /^[0-9]+$/) { sub(/^0+/, "", w); return w }
  if (w ~ /^https?:\/\/[^[:space:]]*\/pull\/[0-9]+([\/#?].*)?$/) {
    sub(/^.*\/pull\//, "", w); sub(/[^0-9].*$/, "", w); sub(/^0+/, "", w); return w
  }
  return ""
}
function closer(s, i,    q, j) {  # the index of the quote closing the one at i, or 0
  q = substr(s, i, 1)
  for (j = i + 1; j <= length(s); j++) if (substr(s, j, 1) == q) return j
  return 0
}
# ONE WORD from i. Sets W, the word; HAS, whether there was one (an empty
# quoted word counts); NI, where to go on; and STOP: "" when more words may
# follow, "cmd" when the command ended, "redir" when a < or > is next (at NI),
# "quote" when a quote or a backslash closed whatever the words sat inside.
function word(s, i,    n, c, j) {
  n = length(s); W = ""; HAS = 0; STOP = ""
  while (i <= n) {
    c = substr(s, i, 1)
    if (c == " " || c == "\t") { i++; continue }
    if (c == "\\" && substr(s, i + 1, 1) == "\n") { i += 2; continue }
    break
  }
  NI = i
  if (i > n) { STOP = "cmd"; return }
  c = substr(s, i, 1)
  if (index(";&|()#`\n", c)) { STOP = "cmd"; return }
  if (c == "<" || c == ">") { STOP = "redir"; return }
  while (i <= n) {
    c = substr(s, i, 1)
    if (c == " " || c == "\t") break
    if (c == SQ || c == "\"") {
      j = closer(s, i)
      if (!j) { STOP = "quote"; break }
      W = W substr(s, i + 1, j - i - 1); HAS = 1; i = j + 1; continue
    }
    if (c == "\\") { STOP = "quote"; break }
    if (c == "<" || c == ">") { if (W ~ /^[0-9]+$/) { W = ""; HAS = 0 }; STOP = "redir"; break }
    if (index(";&|()`\n", c)) { STOP = "cmd"; break }
    W = W c; HAS = 1; i++
  }
  NI = i
  if (STOP == "" && i > n) STOP = "cmd"
}
# A redirect at i: its operator, then its target word, both unread as arguments.
function redir(s, i) {
  while (substr(s, i, 1) == "<" || substr(s, i, 1) == ">") i++
  if (substr(s, i, 1) == "&" || substr(s, i, 1) == "|") i++
  word(s, i)
  return NI
}
# pflag: does this short cluster leave its value for the NEXT word?
function takes_next(w, letters,    k) {
  for (k = 2; k <= length(w); k++)
    if (index(letters, substr(w, k, 1))) return k == length(w)
  return 0
}
# The repository a -R cluster names when its value is attached, or "".
function attached_repo(w,    k, c) {
  for (k = 2; k <= length(w); k++) {
    c = substr(w, k, 1)
    if (index("RtbFA", c)) return (c == "R" && k < length(w)) ? substr(w, k + 1) : ""
  }
  return ""
}
# Does a short cluster leave the NEXT word to -R in particular?
function next_is_repo(w,    k, c) {
  for (k = 2; k <= length(w); k++) {
    c = substr(w, k, 1)
    if (index("RtbFA", c)) return c == "R" && k == length(w)
  }
  return 0
}
# The repository a pull request url names, as gh takes it for --repo: OWNER/REPO
# on github.com, HOST/OWNER/REPO elsewhere. Kept in URLREPO, or "".
function url_repo(w,    h) {
  if (w !~ /^https?:\/\/[^\/]+\/[^\/]+\/[^\/]+\/pull\/[0-9]/) return ""
  sub(/^https?:\/\//, "", w); sub(/\/pull\/.*$/, "", w)
  h = w; sub(/\/.*$/, "", h)
  if (tolower(h) == "github.com" || tolower(h) == "www.github.com") sub(/^[^\/]+\//, "", w)
  return w
}
function positional(w,    n) {
  n = pr_of(w)
  if (n != "") URLREPO = url_repo(w)
  if (n != "") return "PR " n
  if (length(w) <= 200 && w ~ /^[A-Za-z0-9._][A-Za-z0-9._\/-]*$/) return "BRANCH " w
  return "UNKNOWN"
}
# The arguments of one `merge`, from i.
# The repository it names (-R, --repo) is kept in REPO, for the lookups.
# It reads on past the PR to the end of the command, because gh takes options
# after it too, and `gh pr merge 9 --repo o/r` is PR 9 of o/r.
function merge_arg(s, i,    skip, dd, pend, res) {
  skip = 0; dd = 0; pend = 0; res = ""
  while (1) {
    word(s, i); i = NI
    if (HAS) {
      if (skip) { skip = 0; if (pend) REPO = W; pend = 0 }
      else if (!dd && W == "--") dd = 1
      else if (!dd && W ~ /^--./) {
        if (W ~ /^--repo=/) REPO = substr(W, 8)
        if (W ~ /^--(repo|subject|body|body-file|author-email|match-head-commit)$/) { skip = 1; pend = (W == "--repo") }
      }
      else if (!dd && W ~ /^-./) {
        skip = takes_next(W, "RtbFA"); pend = next_is_repo(W)
        if (attached_repo(W) != "") REPO = attached_repo(W)
      }
      else if (res == "") res = positional(W)
    }
    while (STOP == "redir") i = redir(s, i)
    if (res != "" && STOP != "") return res
    if (STOP == "cmd") return skip ? "UNKNOWN" : "CURRENT"
    if (STOP == "quote") return "UNKNOWN"
  }
}
# IS THE QUOTE AROUND pos A STRING SOMETHING MAY RUN? 0 when no quote is open
# at pos; 2 (a mention) when one is and its simple command is one that never
# runs its arguments; 1 otherwise. FAIL CLOSED (fix round 4): a list of the
# runners missed nohup, sudo -u, time, nice, su -c, script -c, find -exec,
# awk system() and parallel, so the list is of the commands that cannot run
# a string instead: grep egrep fgrep rg ag ack, echo printf, and git commit,
# tag and log (whose messages and patterns are text). The first word is taken
# after VAR=value, env, sudo, command and exec words, path-qualified or not;
# a word it does not know is a runner. A backslash outside single quotes
# escapes the next character, as the shell reads it, so that it\x27s does not
# open a quote that the text never opened.
#
# AND A MENTION WHOSE OUTPUT CAN BE RUN IS NOT ONE (security review, fix round
# 4): an echo or a printf in a command holding any shell metacharacter (the
# set the first-word pass uses: | & ; < > ( ) $ backtick, newline) may be
# feeding a shell, and any mention inside a $( or a backtick is output the
# shell may run. Both are 1.
function runs_string(t, pos,    i, c, q, qs, cs, sub0, pre, n, k, w, ws, first, sub1, prerun) {
  q = ""; qs = 0; cs = 1; sub0 = 0
  for (i = 1; i < pos; i++) {
    c = substr(t, i, 1)
    if (c == "\\" && q != SQ) { i++; continue }
    if (q != "") { if (c == q) q = ""; continue }
    if (c == SQ || c == "\"") { q = c; qs = i; continue }
    if (index(";&|()`\n", c)) {
      cs = i + 1
      sub0 = (c == "`" || (c == "(" && i > 1 && substr(t, i - 1, 1) == "$"))
    }
  }
  if (q == "") return 0
  if (sub0) return 1
  pre = substr(t, cs, qs - cs)
  n = split(pre, ws, /[ \t]+/)
  first = ""; sub1 = ""; prerun = 0
  for (k = 1; k <= n; k++) {
    w = ws[k]
    if (w == "") continue
    if (first == "") {
      if (w ~ /^[A-Za-z_][A-Za-z0-9_]*=/ || w == "env" || w == "sudo" || w == "command" || w == "exec") continue
      first = w; sub(/^.*\//, "", first); continue
    }
    # rg runs a program on every file it reads with --pre (security review,
    # fix round 4): then the quote may be that program, and is not a mention.
    if (first == "rg" && w ~ /^--pre(=|$)|^--pre-glob/) prerun = 1
    # the subcommand of git: past its options, and past the value of -C and -c
    if (first == "git" && sub1 == "") {
      if (w == "-C" || w == "-c") { k++; continue }
      if (w ~ /^-/) continue
      sub1 = w
    }
  }
  if (prerun) return 1
  if (first ~ /^(echo|printf)$/ && t ~ /[|&;<>()$`\n]/) return 1
  if (first ~ /^(grep|egrep|fgrep|rg|ag|ack|echo|printf)$/) return 2
  if (first == "git" && sub1 ~ /^(commit|tag|log)$/) return 2
  return 1
}
# RUN, Q (inside a quote nothing runs: a mention) or - (not quoted).
function run_mark(t, pos,    k) {
  k = runs_string(t, pos)
  return k == 1 ? "RUN" : (k == 2 ? "Q" : "-")
}
{ cmd = cmd (NR > 1 ? "\n" : "") $0 }
END {
  # ASK, a position, asks only what run_mark says about a gh there.
  if (ASK != "") { print run_mark(cmd, ASK + 0); exit }
  s = " " cmd; base = -1   # s, at j, is cmd at base + j
  while (match(s, /[^A-Za-z0-9_][Gg][Hh][ \t]/)) {
    POS = base + RSTART + 1  # where this gh stands in the text read
    base += RSTART + RLENGTH - 2
    s = substr(s, RSTART + RLENGTH - 1)
    word(s, 1)
    if (STOP != "" || tolower(W) != "pr") continue
    i = NI; ok = 0; REPO = ""; URLREPO = ""
    while (1) {  # the options of `gh pr` itself, then its subcommand
      word(s, i); i = NI
      if (!HAS) break
      if (W ~ /^--./) {
        if (W ~ /^--repo=/) REPO = substr(W, 8)
        if (W == "--repo" && STOP == "") { word(s, i); i = NI; REPO = W }
        if (STOP != "") break
        continue
      }
      if (W ~ /^-./) {
        if (attached_repo(W) != "") REPO = attached_repo(W)
        if (takes_next(W, "R") && STOP == "") { word(s, i); i = NI; REPO = W }
        if (STOP != "") break
        continue
      }
      if (tolower(W) == "merge") { ok = 1; MEND = base + i - 1 }
      break
    }
    if (!ok) continue
    # BARE: a quote closed the text straight after the word merge, as in a
    # grep for the phrase as much as in a bash -c of it. Checked like UNKNOWN,
    # but not reported as a merge nobody could resolve: it is usually not one.
    if (STOP == "cmd") r = "CURRENT"
    else if (STOP == "quote") r = "BARE"
    else r = merge_arg(s, i)
    if (r !~ / /) r = r " -"
    print r " " (REPO == "" ? "-" : REPO) " " (URLREPO == "" ? "-" : URLREPO) " " POS " " run_mark(cmd, POS) " " MEND
  }
}'
# The single quote arrives as a variable: this program is itself single-quoted,
# and `\x27` is not an escape every awk knows.
MERGES=$(printf '%s\n' "$CMD" | awk -v SQ="'" "$MERGE_ARGS")
# THE SAME READING OF THE NORMALISED TEXT, asked only WHERE it finds merges,
# never which PR: dropping every quote would make `--subject "fix 12" 9` read
# 12. A merge the shell's reading finds whose `gh` the raw reading did not
# find at the same place is one a quote or a backslash hid, and its PR cannot
# be told: every number in the command becomes a candidate. Matched by place,
# not counted (fix round 2): a decoy only the raw reading sees, `true _"gh pr
# merge 1"; g'h' pr merge 9`, cancelled the hidden merge out of a count, and
# PR 9 went unchecked. Nor "any quote at all", which would make every quoted
# subject a list of PR numbers again.
#
# MISREAD, not hidden (fix round 3): when the `gh ... merge` phrase stands in
# the raw text exactly as in the shell's (nothing was taken out of it), no
# quote hid it — the raw reading started inside a quote and paired it with the
# wrong one, as in `grep 'gh pr merge' a; bash -c 'true'`. That merge is read
# like a quoted raw one: every number, and the current branch's PR only when
# the quote is a string something runs (run_mark says RUN).
HIDDEN=0; MISREAD=""; MISREAD_RUNS=""
if [ "$NORM" != "$CMD" ]; then
  NM=$(printf '%s\n' "$NORM" | awk -v SQ="'" "$MERGE_ARGS" | awk 'NF {print $5, $7}')
  RPOS=" $(printf '%s\n' "$MERGES" | awk 'NF {print $5}' | tr '\n' ' ') "
  if [ -n "$NM" ]; then
    MAPPED=$(printf '%s\n' "$CMD" | awk -v SQ="'" -v P="$(printf '%s' "$NM" | tr '\n' ' ')" "$NORM_AWK" | paste -d' ' - -)
    while read -r np ne && read -r rp re <&3; do
      case $RPOS in *" $rp "*) continue ;; esac
      # WHY EQUAL LENGTHS MEAN NOTHING WAS HIDDEN: NORM is the raw text with
      # characters DELETED and none added or reordered (NORM_AWK), so the map
      # is strictly increasing, and the raw span from the gh to the end of
      # the merge word is at least as long as the normalised one — longer by
      # exactly the quotes, backslashes and joined line breaks taken out of
      # it. Equal lengths mean none were, so the raw text spells the same
      # phrase, character for character, and no quote sat inside it.
      if [ $((re - rp)) -eq $((ne - np)) ]; then
        MISREAD=1
        [ "$(printf '%s\n' "$CMD" | awk -v SQ="'" -v ASK="$rp" "$MERGE_ARGS")" = RUN ] && MISREAD_RUNS=1
      else
        HIDDEN=1
      fi
    done <<EOF 3<<EOF3
$NM
EOF
$MAPPED
EOF3
  fi
fi
[ -n "$MERGES" ] || [ "$HIDDEN" -gt 0 ] || [ -n "$MISREAD" ] || pass

command -v gh >/dev/null 2>&1 || pass
command -v jq >/dev/null 2>&1 || pass

# THE COMMAND'S OWN DIRECTORY, because a branch is a checkout's: the leading
# `cd` when there is one (relative to the call's cwd), else the call's cwd.
# Under the driver the process sits in the main checkout and a merge typed as
# `cd <wt> && gh pr merge` merges the worktree's branch, not main's.
CMD_DIR=$(printf '%s' "$INPUT" | jq -r '.cwd // ""' 2>/dev/null) || CMD_DIR=""
CD_TO=$(loopable_cd_target "$CMD") || CD_TO=""
if [ -n "$CD_TO" ]; then
  case $CD_TO in "~") CD_TO=$HOME ;; "~/"*) CD_TO="$HOME/${CD_TO#\~/}" ;; esac
  case $CD_TO in /*) CMD_DIR=$CD_TO ;; *) CMD_DIR="${CMD_DIR:-.}/$CD_TO" ;; esac
fi
# THE REPOSITORY THE COMMAND NAMES, passed to every lookup, so `-R o/r 9` is
# checked as PR 9 of o/r rather than of whatever this checkout points at. Only
# a plain [HOST/]OWNER/REPO reaches gh's argv.
repo_ok() { [[ $1 =~ ^([A-Za-z0-9.-]+/)?[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; }
pr_of_branch() { # pr_of_branch <branch or empty> <repo or empty> -> its PR number
  local out
  if [ -n "$CMD_DIR" ]; then
    out=$(cd "$CMD_DIR" 2>/dev/null && gh pr view ${1:+"$1"} ${2:+--repo "$2"} --json number 2>/dev/null) || return 1
  else
    out=$(gh pr view ${1:+"$1"} ${2:+--repo "$2"} --json number 2>/dev/null) || return 1
  fi
  printf '%s' "$out" | jq -r '.number // empty' 2>/dev/null | grep -E '^[0-9]+$'
}

# One `<pr> <repo or ->` per line.
PRS=""
CURRENT_REPO=""
FALLBACK=""
UNRESOLVED=""
# A merge only the shell's reading sees: every number, and the current
# branch's PR (`g'h' pr merge --squash` merges that one). Reported as
# unresolved only when the raw text shows no merge at all — a raw BARE or
# UNKNOWN beside it already says what it is.
CURRENT_TOO=""
if [ "$HIDDEN" -gt 0 ]; then
  FALLBACK=1; CURRENT_TOO=1
  [ -n "$MERGES" ] || UNRESOLVED=1
fi
[ -n "$MISREAD" ] && FALLBACK=1
[ -n "$MISREAD_RUNS" ] && CURRENT_TOO=1
while read -r kind arg repo urlrepo _pos run _end; do
  [ -n "$kind" ] || continue
  repo_ok "${repo:--}" || repo=""
  repo_ok "${urlrepo:--}" || urlrepo=""
  n=""
  case $kind in
    PR) n=$arg ;;
    BRANCH) n=$(pr_of_branch "$arg" "$repo") || n="" ;;
    CURRENT) n=$(pr_of_branch "" "$repo") || n="" ;;
    # A QUOTED MERGE WITH NO PR READ may be run (`bash -c 'gh pr merge
    # --squash'`) and then merges the current branch's PR, so that PR is a
    # candidate beside every number (security review, fix round 2). Unless
    # its command is one that never runs its arguments — a grep, an echo, a
    # git commit message — where it is a mention, and a branch at a moved
    # head refused it (reviewer, fix round 3). runs_string decides, failing
    # closed: a command it does not know is RUN (fix round 4).
    BARE|UNKNOWN) [ "$run" = RUN ] && CURRENT_TOO=1 ;;
  esac
  if [ -n "$n" ] && [ -n "$urlrepo" ]; then
    # A PR URL NAMES ITS OWN REPOSITORY, and gh takes it over -R. If the two
    # disagree, the PR is checked in both: whichever gh merges, it was read.
    PRS="$PRS$n $urlrepo
"
    [ -n "$repo" ] && [ "$repo" != "$urlrepo" ] && PRS="$PRS$n $repo
"
  elif [ -n "$n" ]; then
    PRS="$PRS$n ${repo:--}
"
  else
    FALLBACK=1
    # A quoted merge nothing runs (Q) is a mention: checked, never reported.
    [ "$kind" = BARE ] || [ "$run" = Q ] || UNRESOLVED=1
  fi
  [ -n "$repo" ] && CURRENT_REPO=$repo
done <<EOF
$MERGES
EOF
if [ -n "$CURRENT_TOO" ]; then
  n=$(pr_of_branch "" "${CURRENT_REPO:-}") || n=""
  [ -n "$n" ] && PRS="$PRS$n ${CURRENT_REPO:--}
"
fi
# NOTHING PASSES UNCHECKED. A merge whose PR cannot be told makes every
# integer in the command a candidate, which is the guard before 363: it
# over-collects, and a number that is not a PR fails its own lookup and costs
# nothing.
if [ -n "$FALLBACK" ]; then
  PRS="$PRS$(printf '%s' "$CMD" | grep -oE '[0-9]+' | sort -un | sed 's/$/ -/')
"
fi
PRS=$(printf '%s' "$PRS" | awk 'NF && !seen[$1 " " $2]++')
[ -n "$PRS" ] || [ -n "$UNRESOLVED" ] || pass

# Fetched once, not per candidate: a merge command names few PRs and the
# backlog does not change between them. `unreachable` is remembered separately
# from `empty`, because the second is an answer and the first is not.
ITEMS_CACHE=""
ITEMS_DOWN=""
PROJECT=""
PROJECT_TRIED=""
DOWN='the Loopable backlog did not answer'

# What the guard decided, PR by PR. Refusals are paragraphs for the reason;
# allows are records, one per line, fields split by the unit separator so an
# empty session survives `read`:
#   pr  head  reason  session  sentence  why-nothing-was-recorded
DENIALS=""
ALLOWS=""
US=$(printf '\037')

refuse() { # refuse <paragraph>
  DENIALS="$DENIALS$1

$OVERRIDE
"
}
allow() { # allow <pr> <head> <reason> <session or empty> <sentence> <why not recorded>
  ALLOWS="$ALLOWS$1$US$2$US$3$US$4$US$5$US$6
"
}

# ONE ITEM, against this PR's head. The head rules first and whatever the
# status; then the status; then what the close at the head says.
#
# <marker> is empty when the body named the item, and otherwise the reason the
# body gave none (no_marker, none, unresolved_ref) — the item was found
# through its sessions, <said> is the sentence for that, and <sessions> are
# the project's, already read.
#
# <tied>, when set, is an item the body does NOT name but this PR's sessions
# are on (security review of round 1): only the two refusals apply to it, and
# the item the body names carries the warning.
check_item() { # check_item <pr> <head> <id> [marker] [said] [sessions] [tied]
  local pr=$1 head=$2 id=$3 marker=${4:-} said=${5:-} sessions=${6:-} tied=${7:-}
  local short row status title who lead target nowhere closes matched last verdict reason
  short=$(printf '%s' "$head" | cut -c1-12)
  row=$(printf '%s\n' "$ITEMS_CACHE" | awk -F'\t' -v want="$id" '$1 == want {print; exit}')
  status=$(printf '%s' "$row" | cut -f2)
  # THROUGH THE SAME SANITIZER THE SESSION BANNER USES. A title can begin life
  # as a sentence a client wrote in chat.
  title="$(loopable_safe "$(printf '%s' "$row" | cut -f3)") ($id)"
  if [ -z "$marker" ]; then
    who="names $title"; lead="It names $title"
  else
    who="names no item itself, and its sessions tie it to $title"
    lead="$said Its sessions tie it to $title"
  fi
  [ -n "$tied" ] && who="is tied by its sessions to $title, which its body does not name"

  if [ -z "$PROJECT" ]; then
    allow "$pr" "$head" no_project "" "$lead, and this repository resolves to no Loopable project, so its sessions could not be read." \
      "this repository resolves to no Loopable project"
    return 0
  fi
  if [ -n "$sessions" ]; then
    sessions=$(printf '%s\n' "$sessions" | awk -F'\t' -v want="$id" '$5 == want')
  elif ! sessions=$(loopable_sessions "$PROJECT" "$id"); then
    allow "$pr" "$head" unreachable "" "$lead, and its sessions could not be read." "$DOWN"
    return 0
  fi

  # Where a warning is recorded: the newest CLOSED session (see the header).
  target=$(printf '%s\n' "$sessions" | awk -F'\t' '$2 == "complete" || $2 == "error" {print $1; exit}')
  nowhere="$title has no closed session to record it on"

  # A COMPLETE CLOSE is the only one that claims anything: an `error` close
  # stopped because something broke, and an open session has said nothing.
  closes=$(printf '%s\n' "$sessions" | awk -F'\t' '$2 == "complete"')
  matched=""
  if [ -n "$closes" ]; then
    matched=$(printf '%s\n' "$closes" | awk -F'\t' -v s="$head" 'tolower($3) == s {print; exit}')
    if [ -z "$matched" ]; then
      # THE MOVED HEAD. A close says "I verified THIS"; a branch that moved
      # afterwards is a branch nobody verified, and the record still reads like
      # a pass.
      last=$(printf '%s\n' "$closes" | awk -F'\t' '$3 != "" {print substr($3, 1, 12); exit}')
      refuse "PR #$pr $who, whose newest complete close was verified at ${last:-no commit at all} while this PR HEAD is $short — the branch moved after it was checked, so what is about to be merged is not what was verified.

Re-run the verifier and close a session at $short (/loopable:ship)."
      return 0
    fi
    verdict=$(printf '%s' "$matched" | cut -f4)
    reason=$(loopable_safe "$(printf '%s' "$matched" | cut -f8)")
    [ -n "$reason" ] || reason='no reason given'
    if [ "$verdict" = fail ]; then
      refuse "PR #$pr $who, whose close at $short carries a verifier verdict of fail — $reason — so what is about to be merged is known not to work.

Fix it, re-run the verifier and close a session at the new HEAD (/loopable:ship)."
      return 0
    fi
  fi

  # THE HEAD RULES HELD. What is left is the merger's judgement, recorded —
  # for the item the body names; a tied item it does not name was here for the
  # refusals only.
  [ -n "$tied" ] && return 0
  if [ "$status" != "in_review" ]; then
    allow "$pr" "$head" not_in_review "$target" "$lead, which the backlog calls ${status:-nothing} rather than in_review, so no close has reported this work finished." "$nowhere"
  elif [ -z "$closes" ]; then
    allow "$pr" "$head" no_session "$target" "$lead, and no session on it has closed complete, so nothing has verified any commit of it." "$nowhere"
  else
    case "$verdict" in
      pass)
        [ -n "$marker" ] && allow "$pr" "$head" "$marker" "$target" "$lead, whose close at $short passed." "$nowhere"
        ;;
      not_run)
        allow "$pr" "$head" not_run "$target" "$lead, whose close at $short carries a verdict of not_run — $reason — so nothing verified that this head works." "$nowhere"
        ;;
      *)
        allow "$pr" "$head" unknown_verdict "$target" "$lead, whose close at $short carries a verdict this guard does not know ($(loopable_safe "${verdict:-none}"))." "$nowhere"
        ;;
    esac
  fi
  return 0
}

# One PR at a time, in THIS shell, so the caches above serve them all. A
# number that is not a PR is a silent pass for that number and nothing more —
# an unknown number must not make the whole command suspicious, or `gh pr merge
# 12 --squash` in a repo with no PR 12 would block on a typo.
check_pr() { # check_pr <n> [repo]
  local pr=$1 repo=${2:-} files view body head headref none_line refs ref id ids="" unresolved="" marker="" said all tied

  files=$(gh pr diff "$pr" --name-only ${repo:+--repo "$repo"} 2>/dev/null) || return 0
  RESOLVED=1
  loopable_touches "$files" || return 0

  # ONE `gh pr view`, CARRYING ALL THREE. The body, the sha and the branch have
  # to describe the same PR at the same instant; two calls are two instants,
  # and the gap between them is exactly a push.
  #
  # ALL OF IT COMES FROM GITHUB, NONE OF IT FROM THE COMMAND. Nothing in the
  # command text is ever read as a marker or as a sha. `gh pr merge 9  #
  # Loopable: <some in_review item>` has written a comment, and an argument
  # spelling a sha is an argument.
  view=$(gh pr view "$pr" --json body,headRefOid,headRefName ${repo:+--repo "$repo"} 2>/dev/null) || return 0
  body=$(printf '%s' "$view" | jq -r '.body // ""' 2>/dev/null) || return 0
  head=$(printf '%s' "$view" | jq -r '.headRefOid // ""' 2>/dev/null | tr 'A-Z' 'a-z')
  headref=$(printf '%s' "$view" | jq -r '.headRefName // ""' 2>/dev/null) || headref=""
  # No sha, no rule to apply — and no PR either, in practice. `gh` answering
  # without one is `gh` not answering.
  [ -n "$head" ] || return 0

  # WHAT THE BODY NAMES. `Loopable: none — <reason>` is an explicit, reviewable
  # decision to land something the backlog does not track; whatever follows a
  # `Loopable:` otherwise is kept opaque, because the shape of a reference is
  # lib.sh's business (loopable_refs / loopable_resolve_ref).
  none_line=$(printf '%s\n' "$body" | grep -iE '^[[:space:]]*Loopable:[[:space:]]*none\b' | head -1)
  if [ -n "$none_line" ]; then
    marker=none
    said="It says \"$(loopable_safe "$none_line")\", so it lands work the backlog does not track."
  else
    refs=$(loopable_refs "$body")
    if [ -z "$refs" ]; then
      marker=no_marker
      said="It touches $(loopable_paths_phrase) and its body names no work item (no \`Loopable:\` line), so the backlog will not hear that this landed."
    fi
  fi

  if [ -z "$ITEMS_CACHE" ] && [ -z "$ITEMS_DOWN" ]; then
    ITEMS_CACHE=$(loopable_items) || ITEMS_DOWN=1
    [ -n "$ITEMS_CACHE" ] || ITEMS_DOWN=1
  fi
  if [ -n "$ITEMS_DOWN" ]; then
    if [ -n "$marker" ]; then
      allow "$pr" "$head" "$marker" "" "$said It could not be tied to an item either." "$DOWN"
    else
      allow "$pr" "$head" unreachable "" "It names $(loopable_safe "$(printf '%s' "$refs" | tr '\n' ' ')"), and the backlog did not answer — no token, no network, or a sleeping database — so nothing here could read its close." "$DOWN"
    fi
    return 0
  fi
  if [ -z "$PROJECT_TRIED" ]; then
    PROJECT=$(loopable_project) || PROJECT=""
    PROJECT_TRIED=1
  fi

  while IFS= read -r ref; do
    [ -n "$ref" ] || continue
    if id=$(loopable_resolve_ref "$ref" "$ITEMS_CACHE"); then
      case " $ids " in *" $id "*) ;; *) ids="$ids $id" ;; esac
    else
      # One per line and never through an unquoted `for`: a ref is somebody's
      # typing, and `Loopable: *` would glob.
      unresolved="$unresolved$(loopable_safe "$ref")
"
    fi
  done <<EOF
${refs:-}
EOF

  # THE ITEMS THIS PR's SESSIONS ARE ON, whatever the body names (security
  # review of round 1): a close that recorded its number, or a session on its
  # head branch. Read every time, because a body naming an innocent item must
  # not hide the item whose close at this head says `fail`. One read of the
  # project's sessions serves both the finding and those items' head rules.
  all="!"; tied=""
  if [ -n "$PROJECT" ] && all=$(loopable_sessions "$PROJECT"); then
    tied=$(printf '%s\n' "$all" | awk -F'\t' -v pr="$pr" -v br="$headref" \
      '$5 != "" && ($7 == pr || (br != "" && $6 == br)) && !seen[$5]++ {print $5}')
  else
    all="!"
  fi

  if [ -n "$ids" ]; then
    while IFS= read -r ref; do
      [ -n "$ref" ] || continue
      allow "$pr" "$head" unresolved_ref "" "It names $ref, which this token cannot resolve to a work item." \
        "$ref is not an item this token can see, so there is nothing to record it on"
    done <<EOF
$unresolved
EOF
    for id in $ids; do check_item "$pr" "$head" "$id"; done
    # THE UNION: an item the sessions tie to this PR and the body does not
    # name gets the two refusals, and only those.
    for id in $tied; do
      case " $ids " in *" $id "*) continue ;; esac
      loopable_id_ok "$id" || continue
      check_item "$pr" "$head" "$id" "" "" "$all" tied
    done
    return 0
  fi

  # THE BODY NAMES NO ITEM, so the tied items are the PR's items.
  if [ -z "$marker" ]; then
    marker=unresolved_ref
    said="It names $(printf '%s' "$unresolved" | tr '\n' ' ' | sed 's/ $//'), which this token cannot resolve to a work item."
  fi
  if [ -z "$PROJECT" ]; then
    allow "$pr" "$head" "$marker" "" "$said" "this repository resolves to no Loopable project"
    return 0
  fi
  if [ "$all" = "!" ]; then
    allow "$pr" "$head" "$marker" "" "$said It could not be tied to an item either." "$DOWN"
    return 0
  fi
  if [ -z "$tied" ]; then
    allow "$pr" "$head" "$marker" "" "$said" "no session is tied to this pull request, so there is no item to record it on"
    return 0
  fi
  for id in $tied; do
    loopable_id_ok "$id" || continue
    check_item "$pr" "$head" "$id" "$marker" "$said" "$all"
  done
  return 0
}

RESOLVED=""
while read -r pr repo; do
  [ -n "$pr" ] || continue
  [ "$repo" = - ] && repo=""
  check_pr "$pr" "$repo" </dev/null
done <<EOF
$PRS
EOF

# A MERGE WHOSE PR NOTHING RESOLVED is allowed — Joel, 2026-11-07: everything
# but a failed or a moved head is allowed — and said out loud, as
# `no_pr_resolved`. PRINTED ONLY: with no PR there is no item and so no closed
# session to record on, and the one session at hand, the worktree's, is open —
# an activity there would mark it active and reset its clock (fix round 2). A
# quote straight after `merge` (BARE) is not counted: `grep 'gh pr merge'` is
# the usual shape of that.
if [ -z "$DENIALS" ] && [ -n "$UNRESOLVED" ] && [ -z "$RESOLVED" ]; then
  printf 'Loopable merge guard: allowing a merge whose pull request it could not tell (guard_allowed: no_pr_resolved).\n  No number, url or branch it could resolve, and no number in the command that is one, so nothing was checked.\n  The guard refuses only a failed or a moved head; this merge is the judgement of whoever runs it — recorded nowhere: with no pull request there is no item, and so no closed session to record on.\n' >&2
fi

[ -n "$DENIALS" ] && deny "$DENIALS"

# LET THROUGH, OUT LOUD. The warning goes to stderr, where a person running the
# merge sees it and the harness does not read it as a decision; the activity
# goes to the item's newest closed session, where the factory can count it.
# Nothing printed here can block the merge: a post that fails is a warning that
# says it was not recorded.
while IFS="$US" read -r pr head reason session sentence nowhere; do
  [ -n "$pr" ] || continue
  short=$(printf '%s' "$head" | cut -c1-12)
  where="recorded nowhere: $nowhere"
  if [ -n "$session" ]; then
    ref=$(jq -nc --argjson pr "$pr" --arg reason "$reason" --arg head "$head" \
      '{event: "guard_allowed", pr: $pr, reason: $reason, head: $head}' 2>/dev/null)
    if [ -n "$ref" ] && loopable_post_activity "$PROJECT" "$session" result \
        "The merge guard let PR #$pr through at $short ($reason). $sentence" "$ref"; then
      where="recorded as guard_allowed on session $session"
    else
      where="recorded nowhere: the post to session $(loopable_safe "$session") did not go through"
    fi
  fi
  printf 'Loopable merge guard: allowing PR #%s at %s (guard_allowed: %s).\n  %s\n  The guard refuses only a failed or a moved head; this merge is the judgement of whoever runs it — %s.\n' \
    "$pr" "$short" "$reason" "$sentence" "$where" >&2
done <<EOF
$ALLOWS
EOF
pass
