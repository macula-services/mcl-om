#!/bin/sh
# Says whether a release tag is the newest v* tag in this repository, and
# prints promote=true or promote=false for $GITHUB_OUTPUT.
#
#   scripts/is_newest_release.sh <tag>        e.g. v0.5.1
#
# :latest must never move backwards. Tags run their builds in parallel, so
# v0.5.0 and v0.5.1 can finish in either order, and a patch v0.4.1 cut after
# v0.5.0 finishes last by design. Only the newest tag by version order moves
# :latest; an older one leaves it where it is, which is not a failure, and
# says so. The caller fetches every tag first.
set -eu

TAG="${1:?usage: is_newest_release.sh <tag>}"
NEWEST=$(git tag -l 'v*' --sort=-v:refname | head -n 1)

if [ "$TAG" = "$NEWEST" ]; then
    echo "promote=true"
else
    echo "::notice::$TAG is not the newest release (${NEWEST:-none}); :latest stays where it is" >&2
    echo "promote=false"
fi
