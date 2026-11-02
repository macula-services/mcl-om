#!/bin/sh
# Decides whether a push needs a new image, and prints build=true or
# build=false for $GITHUB_OUTPUT.
#
#   scripts/is_image_push.sh <before-sha> <after-sha>
#
# It builds UNLESS it can show that every changed path is documentation.
# A push to main publishes :main and :<sha>, which no box follows, so a README
# edit is not worth a build. But `paths-ignore' got the other
# half wrong: on the push that CREATES a branch GitHub has nothing to compare
# against and evaluates the filter on the head commit alone, so a first push
# ending in a docs commit built no image at all.
#
# So every case this script cannot read is a build: no before sha (a manual
# run), the all-zeros sha (a new branch or tag), a before sha that is not in
# the history (a force push), and an empty diff.
set -eu

BEFORE="${1:-}"
AFTER="${2:?usage: is_image_push.sh <before-sha> <after-sha>}"

build() {
    echo "build=$1"
    exit 0
}

case "$BEFORE" in
    "" | 0000000000000000000000000000000000000000) build true ;;
esac

CHANGED=$(git diff --name-only "$BEFORE" "$AFTER" 2>/dev/null) || build true
[ -n "$CHANGED" ] || build true

# Documentation: any Markdown file, anything under docs/ and assets/, and the
# licence. assets/ holds the C4 diagrams, which no build reads: a diagram-only
# commit must not rebuild and re-push an image.
if printf '%s\n' "$CHANGED" | grep -qvE '(\.md$|^docs/|^assets/|^LICENSE$)'; then
    build true
fi
build false
