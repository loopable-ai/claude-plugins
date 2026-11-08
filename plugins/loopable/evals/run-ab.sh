#!/usr/bin/env bash
# Runs the lifecycle evals (plugin/evals/lifecycle/) against two revisions of the
# plugin, so a change to an agent's definition is measured against the one it
# replaces. The cases and the stand-ins come from the WORKING TREE for both arms;
# only the plugin under test differs, so an old revision that never had evals is
# still measured on today's cases.
#
# Usage: run-ab.sh <old-ref> <new-ref> [runs-per-case] [total-max-cost-usd]
#   runs-per-case defaults to 1, the cost ceiling to 8 (USD, both arms together).
#   DRY=1        prints the commands and runs nothing; spends nothing.
#   STATS_ONLY=<dir>  reads <dir>/old.json and <dir>/new.json from an earlier run and
#                prints the comparison; spends nothing.
#   EVAL_CASE    a case-name glob (lifecycle-rounds-*); EVAL_TAG a tag (rounds).
#   EVAL_ARMS=new  runs only the new arm, compared with EVAL_BASELINE (a stored
#                new.json) when there is one.
#   EVAL_MODEL   overrides every case's model (each case says opus; sonnet is cheaper).
#   EVAL_CONCURRENCY  that many runs at once (1-8).
#   EVAL_OUT     where the results go (default: a new temporary directory).
#
# THIS SPENDS MONEY. Every run is a real Claude Code session on your credential.
# The ceiling is split equally between the arms and checked before each run starts,
# so the run already in flight can take the total a little past it. Nothing here
# runs in CI on its own: plugin-evals.yml starts it only by hand.
#
# NOTHING REAL IS REACHED. Each workspace's PATH carries the gh, loopable and curl
# stand-ins; and for anything that misses that PATH — the plugin's own hooks, which
# run in the session's environment — the backlog is pointed at a host that does not
# resolve, with a token that is not one, and gh at an empty configuration: a hook
# or a stray call finds nothing to write to. The copies' .mcp.json names no real
# server. Needs `claude plugin eval`, git, jq and python3.
set -euo pipefail
if [ -n "${STATS_ONLY:-}" ]; then
  exec python3 -I "$(dirname "$0")/ab-stats.py" "$STATS_ONLY/old.json" "$STATS_ONLY/new.json"
fi
old=${1:?usage: run-ab.sh <old-ref> <new-ref> [runs] [total-cost-usd]}
new=${2:?usage: run-ab.sh <old-ref> <new-ref> [runs] [total-cost-usd]}
runs=${3:-1}
total=${4:-8}
root=$(git rev-parse --show-toplevel)
evals=$root/plugin/evals
if [ -n "${DRY:-}" ]; then out=$(mktemp -d); else out=${EVAL_OUT:-$(mktemp -d)}; fi
arms=${EVAL_ARMS:-old new}
case "$arms" in "old new"|new) ;; *) echo "EVAL_ARMS must be 'old new' or 'new'" >&2; exit 2 ;; esac
per_arm=$(awk -v t="$total" -v n="$(wc -w <<< "$arms")" 'BEGIN { printf "%.2f", t / n }')

# The offline self-test first: a fixture that is not what it claims would make
# every paid run measure the wrong thing.
python3 -B "$evals/test-fixtures.py" > "$out/self-test.log" 2>&1 ||
  { tail -20 "$out/self-test.log" >&2; echo "the offline self-test is red; nothing was run" >&2; exit 1; }
tail -1 "$out/self-test.log"

export LOOPABLE_API_URL=https://backlog.example.invalid
export LOOPABLE_TOKEN=fixture-token
export LOOPABLE_TOKEN_FILE=/dev/null
GH_CONFIG_DIR=$(mktemp -d)
export GH_CONFIG_DIR
unset GH_TOKEN GITHUB_TOKEN

for arm in $arms; do
  ref=${!arm}
  dir=$out/$arm
  rm -rf "$dir" "$out/$arm.json"
  mkdir -p "$dir"
  git -C "$root" archive "$ref" plugin | tar -x -C "$dir"
  # The release's .mcp.json runs @loopable/mcp@latest against the real API. The
  # cases use the loopable stand-in instead, so the copy declares a server that
  # is never started and could reach nothing if it were.
  printf '{"mcpServers":{"loopable":{"command":"echo","args":["the loopable stand-in answers in evals"]}}}\n' \
    > "$dir/plugin/.mcp.json"
  rm -rf "$dir/plugin/evals"
  cp -R "$evals" "$dir/plugin/evals"
  rm -rf "$dir/plugin/evals/results"
  cmd=(claude plugin eval "$dir/plugin" --runs "$runs" --ablation none --scaffold
       --trust-plugin --no-publish --max-cost-usd "$per_arm" --json "$out/$arm.json"
       --allow-tools Write Edit Bash)
  [ -z "${EVAL_TAG:-}" ] || cmd+=(--tag "$EVAL_TAG")
  [ -z "${EVAL_CASE:-}" ] || cmd+=(--case "$EVAL_CASE")
  [ -z "${EVAL_MODEL:-}" ] || cmd+=(--model "$EVAL_MODEL")
  [ -z "${EVAL_CONCURRENCY:-}" ] || cmd+=(--concurrency "$EVAL_CONCURRENCY")
  echo "== $arm: $ref ($(git -C "$root" rev-parse --short "$ref"), plugin $(jq -r .version "$dir/plugin/.claude-plugin/plugin.json")), ceiling \$$per_arm"
  if [ -n "${DRY:-}" ]; then printf '%q ' "${cmd[@]}"; echo; else "${cmd[@]}" || echo "(exit $?; partial results are still read)"; fi
done

[ -n "${DRY:-}" ] && exit 0
if [ "$arms" = new ]; then
  [ -s "$out/new.json" ] || { echo "no result in $out: the new arm died before writing one" >&2; exit 1; }
  if [ -z "${EVAL_BASELINE:-}" ] || [ ! -s "$EVAL_BASELINE" ]; then
    echo "No stored baseline: the new arm is reported alone."
    jq -r '.cases[] | "\(.name)  \([.arms.with[] | select(.passed)] | length)/\(.arms.with | length)"' "$out/new.json"
    echo "results: $out"; exit 0
  fi
  cp "$EVAL_BASELINE" "$out/old.json"
fi
[ -s "$out/new.json" ] && [ -s "$out/old.json" ] || { echo "a result file is missing in $out: an arm died before writing one" >&2; exit 1; }
echo
python3 -I "$(dirname "$0")/ab-stats.py" "$out/old.json" "$out/new.json"
echo "results: $out"
