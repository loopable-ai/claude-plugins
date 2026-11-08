#!/usr/bin/env bash
# Admits the two revisions plugin-evals.yml hands ANTHROPIC_API_KEY to, and only
# commits main already holds. The workflow runs this script and nothing else to
# decide; test-fixtures.py (TheRevisionCheck) runs the same script against a
# scratch origin with every way round it found so far.
#
# Usage: main-revisions.sh <old> <new>
#   Each revision is one of, and nothing else:
#     main | origin/main | refs/remotes/origin/main
#                                   the origin's main, fetched by its full name
#     HEAD                          the commit the workflow checked out
#     loopable-plugin-v<x.y.z>      a release tag, read as refs/tags/<it>
#     7 to 40 hex digits            a commit, looked up as an object, never a ref
#   Prints old=<sha> and new=<sha> on stdout (for $GITHUB_OUTPUT), after both
#   are admitted; every refusal goes to stderr and exits 1.
#
# NO NAME IS GIVEN TO GIT TO INTERPRET. A short name is resolved by git in an
# order where a tag or a local branch called `origin/main` outranks the real
# remote-tracking ref, a value starting with `-` is read as an option, and a hex
# prefix loses to a ref of the same name. So the input is matched against the
# forms above, and each form becomes a full ref or an object id here; the one
# thing every form must then be is an ancestor of the origin's main, read as
# refs/remotes/origin/main straight after fetching it by its full name. A tag
# earns nothing on its name: anyone with write access can push one at any commit.
set -euo pipefail
[ $# -eq 2 ] || { echo "usage: main-revisions.sh <old> <new>" >&2; exit 2; }

git fetch -q --no-tags origin '+refs/heads/main:refs/remotes/origin/main'
git fetch -q --no-tags origin '+refs/tags/loopable-plugin-v*:refs/tags/loopable-plugin-v*'
main=$(git rev-parse --verify --quiet --end-of-options 'refs/remotes/origin/main^{commit}') ||
  { echo "::error::the origin has no main to compare with" >&2; exit 1; }

admit() { # <arm> <value>: prints the commit's sha, or refuses
  local arm=$1 ref=$2 full sha
  case "$ref" in
    main|origin/main|refs/remotes/origin/main) full=refs/remotes/origin/main ;;
    HEAD) full=HEAD ;;
    *)
      if [[ $ref =~ ^loopable-plugin-v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        full=refs/tags/$ref
      elif [[ $ref =~ ^[0-9a-f]{7,40}$ ]]; then
        # Objects only: --disambiguate lists the objects with this prefix and
        # never looks at a ref, so a tag named like the prefix cannot stand in.
        local hits=() o
        while read -r o; do
          if [ "$(git cat-file -t "$o")" = commit ]; then hits+=("$o"); fi
        done < <(git rev-parse --disambiguate="$ref" 2>/dev/null || true)
        [ ${#hits[@]} -eq 1 ] ||
          { echo "::error::$arm '$ref' names ${#hits[@]} commits; give one, in full" >&2; return 1; }
        full=${hits[0]}
      else
        echo "::error::$arm '$ref' is not main, HEAD, a loopable-plugin-v<x.y.z> tag or a commit's hex" >&2
        return 1
      fi ;;
  esac
  sha=$(git rev-parse --verify --quiet --end-of-options "$full^{commit}") ||
    { echo "::error::$arm '$ref' is not a revision here" >&2; return 1; }
  if ! git merge-base --is-ancestor "$sha" "$main"; then
    echo "::error::$arm '$ref' ($sha) is not a commit on the origin's main: the key is never handed to code main does not hold" >&2
    return 1
  fi
  echo "$arm '$ref' is $sha, on the origin's main ($main)" >&2
  printf '%s\n' "$sha"
}

old=$(admit old "$1")
new=$(admit new "$2")
printf 'old=%s\nnew=%s\n' "$old" "$new"
