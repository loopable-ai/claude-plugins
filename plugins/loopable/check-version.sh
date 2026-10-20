#!/usr/bin/env bash
# Every change to the plugin is a release — enforced rather than remembered.
#
# `/plugin` installs from loopable-ai/claude-plugins, which release.yml fills
# only when a tag loopable-plugin-v<version> equal to the manifest's version
# is pushed. A merged change with the version left alone is a change nobody
# can install: the driver agent (332) merged as 0.6.0 and `/plugin` update
# still found 0.5.4 until the tag went out. So a change anywhere under
# plugin/ has to move the version, and the tag follows the merge.
#
#   check-version.sh <base> <head>     exit 1 when anything under plugin/
#                                      changed and the version in plugin.json
#                                      is not above main's, from the
#                                      merge-base (main's later work is not
#                                      the branch's)
#
# Run by the guards workflow on every pull request with the PR's base and head.
# On main there is no base to compare against and the guard does not run.
set -euo pipefail
base="${1:?usage: check-version.sh <base> <head>}"
head="${2:?usage: check-version.sh <base> <head>}"
dir="$(cd "$(dirname "$0")" && pwd)"
rel="$(git -C "$dir" rev-parse --show-prefix)"
manifest="${rel}.claude-plugin/plugin.json"

# WHAT THIS BRANCH CHANGED, from where it left main — not the two tips, which
# would count main's own later changes as the branch's.
fork=$(git -C "$dir" merge-base "$base" "$head")
changed=$(git -C "$dir" diff --name-only "$fork" "$head" -- . || true)
[ -n "$changed" ] || { echo "plugin unchanged"; exit 0; }

# AND HIGHER THAN MAIN IS NOW, not merely different: a branch cut before
# main's last bump that bumps to the same number, or below it, would publish
# a version that already exists or goes backwards.
version_at() { git -C "$dir" show "$1:$manifest" 2>/dev/null | jq -r .version; }
before=$(version_at "$base"); after=$(version_at "$head")
highest=$(printf '%s\n%s\n' "$before" "$after" | sort -V | tail -1)
if [ "$before" = "$after" ] || [ "$highest" != "$after" ]; then
  echo "::error file=$manifest::the plugin changed ($(echo "$changed" | tr '\n' ' ')) and plugin.json is $after, which is not above main's $before. Bump it past $before, and push loopable-plugin-v<version> after the merge — that tag is the only way a change reaches /plugin."
  exit 1
fi
echo "plugin version $before -> $after"
