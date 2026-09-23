#!/usr/bin/env bash
# Runs a lint workflow's toolchain step inside the image that workflow names.
#
#   scripts/is_lint_toolchain_runnable.sh <lint.yml>
#
# The step is the text between `# toolchain-begin' and `# toolchain-end' in the
# file; the image is the job's `image:' line. Exits with the step's own status,
# so a toolchain the image cannot provide fails here, not on a service's first
# push. The scaffold's lint image once had no rebar3, git or curl, and every
# test that read the file's TEXT passed.
#
# Needs podman or docker. Exits 3 when neither exists, rather than passing.
set -euo pipefail

LINT="${1:?usage: is_lint_toolchain_runnable.sh <lint.yml>}"

IMAGE=$(sed -n 's/^[[:space:]]*image:[[:space:]]*//p' "$LINT" | head -n 1)
STEP=$(sed -n '/# toolchain-begin/,/# toolchain-end/p' "$LINT" | sed 's/^[[:space:]]\{10\}//')

[ -n "$IMAGE" ] || { echo "no image: line in $LINT" >&2; exit 2; }
[ -n "$STEP" ]  || { echo "no toolchain-begin/-end block in $LINT" >&2; exit 2; }

RUNTIME=$(command -v podman || command -v docker || true)
[ -n "$RUNTIME" ] || { echo "neither podman nor docker is installed" >&2; exit 3; }

echo "image: $IMAGE"
exec "$RUNTIME" run --rm -e DEBIAN_FRONTEND=noninteractive "$IMAGE" bash -euo pipefail -c "$STEP"
