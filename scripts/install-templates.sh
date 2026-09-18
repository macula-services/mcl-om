#!/usr/bin/env bash
# Make `rebar3 new mcl_service' available on this machine.
#
# rebar3 discovers custom templates in ~/.config/rebar3/templates, and only
# there when you are standing in an empty directory with no rebar.config, which
# is exactly the situation you are in when scaffolding a new service. So the
# templates cannot simply be carried by the mcl_om dependency: nothing has
# fetched it yet.
#
# SYMLINKS RATHER THAN COPIES, so editing a template in this checkout takes
# effect immediately and there is one copy to keep right. That is the failure
# this whole thing is fixing: the previous templates drifted for months because
# nothing exercised them and nobody noticed.
#
# Usage:
#
#   scripts/install-templates.sh            # install or refresh
#   scripts/install-templates.sh --remove   # take them out again

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="${REPO}/priv/templates"
DEST="${HOME}/.config/rebar3/templates"

if [ ! -d "${SRC}" ]; then
    echo "no templates at ${SRC}" >&2
    exit 1
fi

# One entry per template: the .template manifest and the directory of sources it
# names. Discovered rather than listed, so adding a second template needs no
# change here.
entries() {
    find "${SRC}" -mindepth 1 -maxdepth 1 -printf '%f\n' | sort
}

remove() {
    local n
    while read -r n; do
        [ -L "${DEST}/${n}" ] || continue
        rm -f "${DEST}/${n}"
        echo "removed ${DEST}/${n}"
    done < <(entries)
}

install() {
    mkdir -p "${DEST}"
    local n
    while read -r n; do
        # A real file or directory that is not our symlink is somebody else's
        # template. Refuse rather than clobber it.
        if [ -e "${DEST}/${n}" ] && [ ! -L "${DEST}/${n}" ]; then
            echo "refusing to replace non-symlink ${DEST}/${n}" >&2
            exit 2
        fi
        ln -sfn "${SRC}/${n}" "${DEST}/${n}"
        echo "linked ${DEST}/${n} -> ${SRC}/${n}"
    done < <(entries)
}

case "${1:-}" in
    --remove) remove ;;
    "")       install
              echo
              echo "Now, from the directory that will hold the new repository:"
              echo
              echo "  rebar3 new mcl_service repo=mcl-foo name=mcl_foo \\"
              echo "      desc=\"Does X over the mesh\" health_port=8484"
              ;;
    *)        echo "usage: $0 [--remove]" >&2 ; exit 64 ;;
esac
