#!/usr/bin/env bash
# Shared by both Loopable hooks: how to reach the backlog, and when not to try.
#
# EVERY FAILURE HERE IS A PASS. A hook that blocks real work because Aurora was
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
loopable_get() { # loopable_get <path> -> body on stdout, non-zero if unreachable
  local token; token=$(loopable_token) || return 1
  [ -n "$token" ] || return 1
  curl -fsS --max-time 4 -H "Authorization: Bearer $token" "$LOOPABLE_API$1"
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
# `<id>\t<status>\t<title>` lines.
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
      jq -r '.items[] | [.id, .status, .title] | @tsv' || return 1
  done
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
