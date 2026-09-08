#!/usr/bin/env bash
# Shared by every Loopable hook: how to reach the backlog, and when not to try.
#
# EVERY FAILURE HERE IS A PASS — with ONE stated exception, guard-merge.sh,
# which refuses what it cannot verify because a merge cannot be taken back.
# The helpers below therefore report failure honestly (a non-zero return, not
# an empty answer that reads like "no") and each CALLER decides what silence
# means for it. See "cannot verify" in guard-merge.sh.
#
# A hook that blocks real work because Aurora was
# asleep, or because somebody has no token, is worse than no hook at all — the
# person it blocks cannot easily override it, and the first thing they will do
# is switch it off. So the guard only ever speaks up on a CONFIDENT negative:
# the backlog answered, and the answer was no.
set -uo pipefail

LOOPABLE_API="${LOOPABLE_API_URL:-https://api.loopable.ai}"

# The same file the MCP server reads. One secret, one place — see
# apps/loopable/mcp/lib/token.mjs.
loopable_token() {
  if [ -n "${LOOPABLE_TOKEN:-}" ]; then printf '%s' "$LOOPABLE_TOKEN"; return; fi
  local f="${LOOPABLE_TOKEN_FILE:-$HOME/.config/loopable/token}"
  [ -r "$f" ] && tr -d '[:space:]' < "$f"
}

# A short timeout on purpose. This runs in front of a person waiting to merge,
# and the budget for being helpful is a couple of seconds.
#
# A COMMAND IS NOT A HOOK, and `LOOPABLE_MAX_TIME` is where the difference is
# said. A hook that waits eight seconds on a sleeping Aurora has spent
# somebody's session on its own bookkeeping, so it gives up early and silently;
# `bin/start.sh` was ASKED for the backlog and has nothing to do without it, so
# it waits longer and reports what went wrong. Four seconds stays the default,
# and every hook keeps the budget it was written with.
LOOPABLE_MAX_TIME="${LOOPABLE_MAX_TIME:-4}"

loopable_get() { # loopable_get <path> -> body on stdout, non-zero if unreachable
  local token; token=$(loopable_token) || return 1
  [ -n "$token" ] || return 1
  curl -fsS --max-time "$LOOPABLE_MAX_TIME" \
    -H "Authorization: Bearer $token" "$LOOPABLE_API$1" 2>/dev/null
}

# The write half. Same discipline, same silence: curl's own diagnostics go to
# /dev/null because a hook that prints to stderr has printed into somebody's
# session, and "the backlog was asleep" is not news a session needs.
loopable_post() { # loopable_post <path> <json body> -> body on stdout, non-zero
  local token; token=$(loopable_token) || return 1
  [ -n "$token" ] || return 1
  curl -fsS --max-time "$LOOPABLE_MAX_TIME" -X POST \
    -H "Authorization: Bearer $token" -H 'Content-Type: application/json' \
    --data-binary "$2" "$LOOPABLE_API$1" 2>/dev/null
}

# The third verb, because reporting progress is a PATCH and nothing else here
# needed one: `report_progress` in the MCP is `PATCH /items/{id}` with a status
# and a note, and bin/start.sh takes that same edge when it claims an item.
loopable_patch() { # loopable_patch <path> <json body> -> body on stdout, non-zero
  local token; token=$(loopable_token) || return 1
  [ -n "$token" ] || return 1
  curl -fsS --max-time "$LOOPABLE_MAX_TIME" -X PATCH \
    -H "Authorization: Bearer $token" -H 'Content-Type: application/json' \
    --data-binary "$2" "$LOOPABLE_API$1" 2>/dev/null
}

# ---------------------------------------------------------- the config file --
#
# `.loopable.yaml` at the repository root says which Loopable project this
# repository belongs to, which paths must name a work item, and how a branch is
# started here. Plain `key: value` lines and a `- item` list, parsed with sed
# and awk so the plugin carries no dependency. Quoting is not supported and a
# value ends at the first `#`.
#
# WHICH REPOSITORY: LOOPABLE_REPO when a caller has already decided (the write
# guard, which judges the repository the FILE is in, not the session's);
# CLAUDE_PROJECT_DIR when the harness set it; the git toplevel of the cwd
# otherwise. No repository, no config, and every reader below treats that as
# "not configured" rather than as an error.
loopable_repo() {
  if [ -n "${LOOPABLE_REPO:-}" ]; then printf '%s' "$LOOPABLE_REPO"; return; fi
  if [ -n "${CLAUDE_PROJECT_DIR:-}" ]; then printf '%s' "$CLAUDE_PROJECT_DIR"; return; fi
  git rev-parse --show-toplevel 2>/dev/null
}
loopable_config_file() {
  local r; r=$(loopable_repo) || return 1
  [ -n "$r" ] && [ -r "$r/.loopable.yaml" ] || return 1
  printf '%s' "$r/.loopable.yaml"
}
loopable_config() { # loopable_config <key> -> the scalar, or nothing
  local f; f=$(loopable_config_file) || return 1
  sed -nE "s|^$1:[[:space:]]*([^#]*[^#[:space:]]).*|\1|p" "$f" | head -1
}
loopable_paths() { # the `paths:` list, one per line, trailing slashes stripped
  local f; f=$(loopable_config_file) || return 0
  awk '/^paths:/ {f=1; next}
       f && /^[[:space:]]+-[[:space:]]*/ {
         sub(/^[[:space:]]+-[[:space:]]*/, ""); sub(/[[:space:]]*#.*$/, ""); sub(/\/+$/, "")
         if (length) print; next }
       f && !/^[[:space:]]/ {f=0}' "$f"
}
# Does this change touch what the repository tracks in Loopable?
#
# NO CONFIG, NOTHING TRACKED. A repository without `.loopable.yaml` has not
# said it belongs to a project, and a plugin that refused edits and merges
# there would be refusing work in every repository its user opens — which is
# the fastest way to get switched off. With a config and no `paths:`, the
# whole repository is tracked: naming a project and no paths is saying all of
# it belongs there.
loopable_touches() { # loopable_touches <newline-separated repo-relative files>
  local paths p
  loopable_config_file >/dev/null 2>&1 || return 1
  paths=$(loopable_paths)
  if [ -z "$paths" ]; then [ -n "$1" ]; return; fi
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    printf '%s\n' "$1" | grep -q "^$p/" && return 0
  done <<EOF
$paths
EOF
  return 1
}
# The paths, as a phrase for a message: "apps/loopable/" or "this repository".
loopable_paths_phrase() {
  local paths; paths=$(loopable_paths)
  if [ -z "$paths" ]; then printf 'this repository'; return; fi
  printf '%s\n' "$paths" | awk '{printf "%s%s/", (NR>1 ? ", " : ""), $0}'
}

# Every item this token can see in the configured project — or, with no
# project configured, in every project it can see — as
# `<id>\t<status>\t<title>\t<ref>` lines.
#
# THE REF IS THE FOURTH FIELD and rides along everywhere the first three go:
# every caller of this function is a place a person might have written `s41`
# instead of a uuid (S1.10), and a second fetch to translate one would be a
# second answer to "what is in this backlog".
loopable_items() {
  local me projects
  projects=$(loopable_config project) || projects=""
  if [ -z "$projects" ]; then
    me=$(loopable_get /agent/whoami) || return 1
    projects=$(printf '%s' "$me" | jq -r '.projects[].id') || return 1
  fi
  local p
  for p in $projects; do
    loopable_get "/agent/projects/$p/items" |
      jq -r '.items[] | [.id, .status, .title, .ref] | @tsv' || return 1
  done
}

# --------------------------------------------- naming an item in a PR body --
#
# WHATEVER FOLLOWS `Loopable:` IS OPAQUE TO EVERY CALLER. The merge guard used
# to carry its own 36-character regex, which made the shape of a reference a
# property of the guard rather than of the backlog: the day short ids became a
# way to name an item (S1.10), the guard would have gone on refusing them while
# the MCP accepted them, and two ideas of "what names an item" would be loose
# in one plugin.
#
# So there is one pair of functions. `loopable_refs` harvests the raw string —
# anything up to the first space — and `loopable_resolve_ref` is the ONLY thing
# that decides what a string means, by asking the backlog rather than by
# matching a shape. Adding a new spelling is one edit here and no edit anywhere
# else, and a guard rule written on top of a resolved id (the HEAD-sha rule
# below) composes with it automatically.
loopable_refs() { # loopable_refs <pr body> -> one raw ref per line
  # grep first so the marker is matched case-insensitively the same way the
  # `none` escape hatch is: sed's `I` flag is a GNU extension and this runs on
  # whatever anybody's laptop has.
  printf '%s\n' "$1" |
    grep -iE '^[[:space:]]*Loopable:[[:space:]]*[^[:space:]]' |
    sed -nE 's|^[[:space:]]*[Ll][Oo][Oo][Pp][Aa][Bb][Ll][Ee]:[[:space:]]*([^[:space:]]+).*|\1|p' |
    grep -viE '^none$'
}
# RESOLVED AGAINST THE BACKLOG, NEVER TRUSTED. A full id has to be an id this
# token can actually see; a SHORT REF (s41, loop/s41) is looked up as the ref
# the backlog itself hands back; a shorter string is a prefix, and a prefix
# that matches two items resolves to nothing — the loopable_item tie rule, for
# the same reason. Nothing here decides that an unresolved ref is fine: it
# returns non-zero and the caller says what that means.
loopable_resolve_ref() { # loopable_resolve_ref <ref> [items tsv] -> an id
  local ref id items short
  ref=$(printf '%s' "${1:-}" | tr 'A-Z' 'a-z')
  [ -n "$ref" ] || return 1
  items=${2:-}
  [ -n "$items" ] || items=$(loopable_items) || return 1

  # A full id, exactly.
  id=$(printf '%s\n' "$items" | awk -F'\t' -v r="$ref" '$1 == r {print $1; exit}')
  [ -n "$id" ] && { printf '%s' "$id"; return; }

  # A SHORT REF (S1.10): `s41`, `loop/s41` — the fourth field, which is what
  # the backlog itself calls the row. The project key in front is stripped:
  # `.loopable.yaml` already decides which project this repository talks to,
  # and a key naming another one resolves to nothing here anyway. The letter
  # is a hint about the kind; the number is the identity.
  short=${ref##*/}
  if printf '%s' "$short" | grep -qE '^[estbf][0-9]+$'; then
    id=$(printf '%s\n' "$items" |
      awk -F'\t' -v r="$short" 'tolower($4) == r {print $1; exit}')
    [ -n "$id" ] && { printf '%s' "$id"; return; }
  fi

  # Otherwise a PREFIX of an id, and only when exactly one item matches — the
  # loopable_item tie rule, for the same reason.
  id=$(printf '%s\n' "$items" | awk -F'\t' -v r="$ref" 'index($1, r) == 1 {print $1}')
  [ "$(printf '%s\n' "$id" | grep -c .)" = 1 ] || return 1
  printf '%s' "$id"
}

# ------------------------------------------- what a session claimed, and at --
#
# The close contract (S1.3) as three fields per closed session: the state, the
# sha it was built at, and what the verifier made of it. `state=complete` is
# asked of the API rather than filtered here, so a session that ended in
# `error` — which claims nothing and proves nothing — never reaches a caller.
loopable_sessions() { # loopable_sessions <project> <item> -> state\tsha\tverdict\treason
  local out
  out=$(loopable_get "/agent/projects/$1/sessions?item_id=$2&state=complete") || return 1
  printf '%s' "$out" |
    jq -r '.sessions[]? | [.state, (.head_sha // ""), (.verdict // ""), (.verdict_reason // "")] | @tsv'
}

# The verify methods of an item's acceptance criteria, one per line. Only
# `browser` matters to a caller today: it is the method S1.3 made screenshots
# mandatory for, and therefore the one that says a verifier had something to
# drive. An item with none of them is an item `not_run` can be honest about.
loopable_verify_methods() { # loopable_verify_methods <project> <item>
  local out
  out=$(loopable_get "/agent/projects/$1/items/$2") || return 1
  printf '%s' "$out" | jq -r '.brief.criteria[]?.verify // empty'
}

# ONE PLACE THAT MAKES BACKLOG TEXT SAFE TO SHOW.
#
# It lives here because the first attempt at it did not: the session banner was
# sanitized and the merge guard's denial reason was not, although both put the
# same text into the same agent's context. Fixing one of a pair and leaving the
# other is its own bug class, and the only durable answer is that there is no
# pair — there is one function.
#
# A work item title can begin life as a sentence a client typed in chat, which
# the product owner drafted into a requirement and somebody approved. Stripping
# rather than escaping, because a title has no legitimate use for a control
# character and stripping cannot be got subtly wrong the way escaping can.
loopable_safe() { # loopable_safe <text> -> one printable line, at most 80 chars
  printf '%s' "$1" | awk '{
    gsub(/[^[:print:]]/, " ")
    gsub(/[[:space:]]+/, " ")
    sub(/^ /, ""); sub(/ $/, "")
    if (length($0) > 80) $0 = substr($0, 1, 77) "…"
    printf "%s", $0
  }' RS='\0'
}

# ------------------------------------------------------- the session hooks --
#
# S2.2. Three hooks report a session into the backlog while it runs, and every
# one of them has to answer the same two questions first: WHICH ITEM is this
# branch, and WHERE do I keep what I learned. Both live here, because a hook
# that resolved them its own way would be a second answer, and the pair would
# drift the way the sanitizer pair did.

# WHERE THE STATE LIVES: inside the git directory, never the working tree.
#
# `.loopable-item` in the worktree root was the obvious place and is the wrong
# one. The plugin cannot edit somebody's `.gitignore` — it is their file, in
# their repository, and a plugin that writes to it has done something the
# person did not ask for — and `.git/info/exclude` only works for a repository
# that has one, which is a second thing to get right. A file under the git
# directory cannot be committed at all: there is no rule to add and no rule
# that can be removed. It is per-worktree too — `--absolute-git-dir` in a
# linked worktree is `.git/worktrees/<name>` — which is exactly the scope
# these files want, since the item IS the branch.
loopable_state_dir() { # -> a directory, created, or non-zero
  local d r
  r=$(loopable_repo) || return 1
  [ -n "$r" ] || return 1
  d=$(git -C "$r" rev-parse --absolute-git-dir 2>/dev/null) || return 1
  [ -n "$d" ] || return 1
  mkdir -p "$d/loopable" 2>/dev/null || return 1
  printf '%s' "$d/loopable"
}
loopable_state() { # loopable_state <name> -> its contents, or non-zero
  local d; d=$(loopable_state_dir) || return 1
  [ -r "$d/$1" ] || return 1
  cat "$d/$1"
}
loopable_state_put() { # loopable_state_put <name> <value>
  local d; d=$(loopable_state_dir) || return 1
  printf '%s' "$2" > "$d/$1" 2>/dev/null
}

# The branch this session is on, or nothing on main and nothing detached.
# Main is where dispatching happens (guard-main.sh refuses the edits), so a
# session there is not working an item and has no session to open.
loopable_branch() {
  local r b; r=$(loopable_repo) || return 1
  b=$(git -C "$r" symbolic-ref --quiet --short HEAD 2>/dev/null) || return 1
  case "$b" in main|master|'') return 1 ;; esac
  printf '%s' "$b"
}

# The project this repository belongs to: the config, or the single project
# the token can see. Two projects and no config is an ambiguity, and a hook
# guesses at nothing.
loopable_project() {
  local p me
  p=$(loopable_config project) && [ -n "$p" ] && { printf '%s' "$p"; return; }
  me=$(loopable_get /agent/whoami) || return 1
  p=$(printf '%s' "$me" | jq -r '.projects | if length == 1 then .[0].id else empty end') || return 1
  [ -n "$p" ] || return 1
  printf '%s' "$p"
}

# A title, or a branch name, as comparable words.
loopable_slug() {
  printf '%s' "$1" | tr 'A-Z' 'a-z' |
    sed -E 's|[^a-z0-9]+|-|g; s|^-+||; s|-+$||'
}

# WHICH ITEM IS THIS BRANCH? Four answers, cheapest and most explicit first.
#
#   1. LOOPABLE_ITEM         somebody said so; nothing outranks that
#   2. the state file        this session already worked it out
#   3. the branch's short id  `<kind>/<slug>-<shortid>`, which is how
#                             /loopable:start (S2.4) will name branches
#   4. the one in_progress item whose title matches the branch slug — the
#      answer for the branches that exist today, `<type>/<app>-<slug>`
#
# NOTHING RESOLVES, NOTHING HAPPENS. An item guessed wrong is worse than no
# item: it writes one person's work into another person's session. So a tie
# at step 4 resolves to nothing, deliberately.
loopable_item() { # -> a work item id, or non-zero
  local branch slug short items id
  [ -n "${LOOPABLE_ITEM:-}" ] && { printf '%s' "$LOOPABLE_ITEM"; return; }
  id=$(loopable_state item) && [ -n "$id" ] && { printf '%s' "$id"; return; }

  branch=$(loopable_branch) || return 1
  slug=$(loopable_slug "${branch#*/}")
  items=$(loopable_items) || return 1
  [ -n "$items" ] || return 1

  # A REF, if the branch ends in one: `feat/loopable-brief-pack-s41`. First,
  # because it is the only step that is exact — a ref is a name somebody chose
  # to put there, and the two steps under it are inference.
  short=$(printf '%s' "$slug" | sed -nE 's|.*-([estbf][0-9]+)$|\1|p')
  if [ -n "$short" ]; then
    id=$(loopable_resolve_ref "$short" "$items") && [ -n "$id" ] &&
      { printf '%s' "$id"; return; }
  fi

  # A short id, if the branch carries one: the last dash-separated run of at
  # least six hex characters. Resolved against the backlog by prefix rather
  # than trusted — a slug ending in `decade` is hex too.
  short=$(printf '%s' "$slug" | sed -nE 's|.*-([0-9a-f]{6,})$|\1|p')
  if [ -n "$short" ]; then
    id=$(printf '%s\n' "$items" | awk -F'\t' -v s="$short" 'index($1, s) == 1 {print $1}')
    [ "$(printf '%s\n' "$id" | grep -c .)" = 1 ] && { printf '%s' "$id"; return; }
  fi

  # Otherwise the in_progress item this branch is named after, by SHARED
  # WORDS rather than by containment. Neither string contains the other in
  # practice — `feat/loopable-session-hooks` carries an app id the title does
  # not, and "S2.2 · Session hooks" carries a number the branch does not — so
  # the match is how many words of at least three letters they have in common.
  #
  # TWO WORDS, AND A CLEAR WINNER. One shared word is a coincidence ("the
  # api"); a tie is two items with equal claim, and picking either writes one
  # person's work into another person's session. Both resolve to nothing, and
  # nothing means the hook does nothing at all.
  id=$(printf '%s\n' "$items" | awk -F'\t' -v s="-$slug-" '
    $2 != "in_progress" { next }
    {
      t = tolower($3); gsub(/[^a-z0-9]+/, "-", t)
      n = split(t, w, "-"); score = 0
      for (i = 1; i <= n; i++) if (length(w[i]) >= 3 && index(s, "-" w[i] "-")) score++
      if (score > best) { best = score; id = $1; ties = 1 }
      else if (score == best && score > 0) ties++
    }
    END { if (best >= 2 && ties == 1) print id }')
  [ -n "$id" ] || return 1
  printf '%s' "$id"
}

# Post one activity to the session this worktree has open. Silent, and false
# on anything at all — no session, no token, no network, a 404 because the
# session was closed by /loopable:ship while the hook was in flight.
loopable_activity() { # loopable_activity <kind> <body> [ref json]
  local p s ref payload
  p=$(loopable_project) || return 1
  s=$(loopable_state session) || return 1
  [ -n "$s" ] || return 1
  ref=${3:-}
  [ -n "$ref" ] || ref='{}'
  payload=$(jq -nc --arg k "$1" --arg b "$2" --argjson r "$ref" \
    '{kind: $k, body: $b, ref: $r}') || return 1
  loopable_post "/agent/projects/$p/sessions/$s/activities" "$payload" >/dev/null
}

# THE BUFFER IS CLAIMED BY RENAMING IT, then posted. Two tool calls finishing
# at once would otherwise both read a full buffer and post it twice; `mv` is
# the one operation that can only succeed for one of them. If the post then
# fails there is nothing to put back — a retried batch is a duplicate, and a
# dropped one is a gap in a stream that already tolerates gaps.
loopable_flush_actions() {
  local d claim body
  d=$(loopable_state_dir) || return 1
  [ -s "$d/actions" ] || return 1
  claim="$d/actions.$$"
  mv "$d/actions" "$claim" 2>/dev/null || return 1
  rm -f "$d/at" 2>/dev/null
  body=$(printf '%s\n%s' "What this session did:" "$(cat "$claim")")
  rm -f "$claim" 2>/dev/null
  loopable_activity action "$body"
}
