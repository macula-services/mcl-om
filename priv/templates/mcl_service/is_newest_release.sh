#!/bin/sh
# Says whether a release tag is the newest release in this repository, and
# prints promote=true or promote=false for $GITHUB_OUTPUT.
#
#   scripts/is_newest_release.sh <tag>        e.g. v0.5.1
#
# :latest must never move backwards. Tags run their builds in parallel, so
# v0.5.0 and v0.5.1 can finish in either order, and a patch v0.4.1 cut after
# v0.5.0 finishes last by design. Only the newest tag by version order moves
# :latest; an older one leaves it where it is, which is not a failure, and
# says so. The caller fetches every tag first.
#
# A PRERELEASE IS A REHEARSAL, NOT A RELEASE. The house cuts v1.1.0-rc1 before
# v1.1.0, and git's `--sort=-v:refname' puts the rc ABOVE its release: git's
# version sort reads "rc1" as text after the empty suffix a plain release has,
# where SemVer says a prerelease sorts before the release it precedes. On the
# bare sort, cutting an rc would move :latest to a rehearsal, and the release
# after it would never reach :latest at all. So only plain vMAJOR.MINOR.PATCH
# tags are releases here: a prerelease never promotes, and never counts as the
# newest.
set -eu

TAG="${1:?usage: is_newest_release.sh <tag>}"
RELEASE='^v[0-9]+\.[0-9]+\.[0-9]+$'

if ! printf '%s\n' "$TAG" | grep -qE "$RELEASE"; then
    echo "::notice::$TAG is not a plain release tag (vX.Y.Z); :latest stays where it is" >&2
    echo "promote=false"
    exit 0
fi

NEWEST=$(git tag -l 'v*' --sort=-v:refname | grep -E "$RELEASE" | head -n 1)

if [ "$TAG" = "$NEWEST" ]; then
    echo "promote=true"
else
    echo "::notice::$TAG is not the newest release (${NEWEST:-none}); :latest stays where it is" >&2
    echo "promote=false"
fi
