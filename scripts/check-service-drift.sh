#!/bin/sh
# Report how each service's house furniture differs from the template
# (mcl-om#56), and which distribution form it starts its node with
# (mcl-om#24's remaining half).
#
#   scripts/check-service-drift.sh ~/work/github.com/macula-services
#   scripts/check-service-drift.sh path/to/mcl-jobs path/to/mcl-tube ...
#
# A directory argument sweeps the repositories under it; a repository argument
# checks that one. Either way the output is the same TSV, so it can be read by
# a person and filed from by a script:
#
#   # service  ref  sha  kind  detail
#   mcl-jobs   origin/main  4e0f2a1  missing       scripts/promote_latest.sh
#   mcl-jobs   origin/main  4e0f2a1  differs       scripts/is_newest_release.sh
#   mcl-jobs   origin/main  4e0f2a1  distribution  open
#
# READ-ONLY AND OFFLINE. Every file of a SERVICE is read with `git show' at
# origin/main (or at HEAD when a repository has no origin/main), never from that
# repository's working tree, so a checkout left on a branch reports what people
# deploy rather than what somebody is editing. The template side is read from
# THIS checkout's working tree, which is the point: it is what is being compared
# against, including edits not yet committed. Nothing is fetched, nothing is
# written anywhere.
#
# WHY ONLY THESE FILES ARE COMPARED. The template renders a service's own name,
# org, registry and images into nearly all of its files, so comparing those
# against a concrete service would report a difference on every substituted
# line and bury the ones that matter. The files below carry no substitution at
# all, so in a service they must be byte-identical to the template and a
# difference is drift with no judgement in it. A file the service is missing is
# reported too: for a service older than the template that is the usual finding,
# and it is still a difference.
set -eu

usage() {
    cat >&2 <<'USAGE'
usage: check-service-drift.sh <root-or-repository> [<root-or-repository> ...]

Prints one line per finding:
  <service> <ref> <sha> <missing|differs|distribution|image-cookie|compose-cookie> <detail>

Reads origin/main (or HEAD) with git show. Read-only; fetches nothing.
USAGE
    exit 64
}

[ $# -gt 0 ] || usage
for arg in "$@"; do
    [ -d "$arg" ] || { echo "check-service-drift.sh: no such directory: $arg" >&2; exit 64; }
done

TEMPLATES=$(cd "$(dirname "$0")/../priv/templates" && pwd)
TEMPLATE="$TEMPLATES/mcl_service"

# THE LIST IS DERIVED, NOT TYPED. priv/templates/mcl_service.template maps each
# template file to the path it lands at; a file the template substitutes nothing
# into -- and whose destination names no variable beyond the repository -- is
# one a service must carry unchanged. Adding a verbatim file to the template
# adds it here, and a file that starts taking a variable leaves, without anyone
# editing this script.
verbatim_files() {
    sed -n 's/^{template, *"mcl_service\/\([^"]*\)", *"{{repo}}\/\([^"]*\)"}.*/\1	\2/p' \
        "$TEMPLATES/mcl_service.template" |
    while IFS='	' read -r src dest; do
        case "$dest" in *'{''{'*) continue ;; esac
        if grep -q '{''{' "$TEMPLATE/$src" 2>/dev/null; then
            continue
        fi
        printf '%s	%s\n' "$src" "$dest"
    done
}

repositories() {
    for arg in "$@"; do
        if [ -d "$arg/.git" ]; then
            printf '%s\n' "$arg"
        else
            for repo in "$arg"/*; do
                [ -d "$repo/.git" ] && printf '%s\n' "$repo"
            done
        fi
    done
}

printf '# service\tref\tsha\tkind\tdetail\n'

repositories "$@" | while IFS= read -r repo; do
    [ -n "$repo" ] || continue
    name=$(basename "$repo")
    ref=HEAD
    if git -C "$repo" rev-parse --verify --quiet origin/main >/dev/null 2>&1; then
        ref=origin/main
    fi
    sha=$(git -C "$repo" rev-parse --short "$ref" 2>/dev/null) || continue
    files=$(git -C "$repo" ls-tree -r --name-only "$ref" 2>/dev/null) || continue

    # A SERVICE IS SOMETHING THAT SHIPS AN IMAGE OR AN OTP APP. Anything else in
    # the org's checkout directory -- a corpus, the library, the testkit -- is
    # not drift and is named as skipped rather than silently dropped, so a
    # sweep that quietly checked nothing cannot be mistaken for a clean one.
    if ! printf '%s\n' "$files" | grep -qE '^Containerfile$|^apps/[^/]+/src/[^/]+_app\.erl$'; then
        echo "$name	$ref	$sha	not-a-service	-"
        continue
    fi

    verbatim_files | while IFS='	' read -r src dest; do
        if ! printf '%s\n' "$files" | grep -qx "$dest"; then
            echo "$name	$ref	$sha	missing	$dest"
        elif [ "$(git -C "$repo" show "$ref:$dest" 2>/dev/null | sha256sum)" != \
               "$(sha256sum < "$TEMPLATE/$src")" ]; then
            echo "$name	$ref	$sha	differs	$dest"
        fi
    done

    # THE DISTRIBUTION FORM (#24). Four answers, and which one a service gives
    # decides whether anyone who reaches its box can attach to the node holding
    # its keys:
    #   no-listener  starts no epmd and no listener at all -- the template's form
    #   loopback     listens, but only on 127.0.0.1
    #   open         a -name and neither of the above: it listens on every address
    #   unknown      no config/vm.args.src to read
    vmargs=$(git -C "$repo" show "$ref:config/vm.args.src" 2>/dev/null || true)
    if [ -z "$vmargs" ]; then
        echo "$name	$ref	$sha	distribution	unknown"
    else
        # ONLY FLAG LINES, AND ONLY THE FLAG. A vm.args is not a fixed shape: the
        # comment above the flags in a fixed service names `-name' and
        # `-setcookie' while using neither; a file may be tab-indented; and a flag
        # may carry a trailing comment or a CR from a file written elsewhere. Each
        # is stripped before the flag is matched from its own start, because the
        # answer here decides whether a reader is told a node is exposed.
        flags=$(printf '%s\n' "$vmargs" | tr -d '\r' |
                sed -e 's/[[:space:]]#.*$//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' |
                grep -E '^-' || true)
        # Written as ifs rather than `grep && named=yes': under `set -e' a
        # failing command in an AND-OR list is a trap, and this is the one place
        # where a false answer would be read as "the safe form".
        # `-dist_listen false' outranks the rest: relx's start script wants a
        # node name, so a name on its own says nothing about whether a listener
        # is opened, and it is the listener that matters.
        if printf '%s\n' "$flags" | grep -qE '^-dist_listen[[:space:]]+false$' &&
           printf '%s\n' "$flags" | grep -qE '^-start_epmd[[:space:]]+false$'; then
            echo "$name	$ref	$sha	distribution	no-listener"
        elif printf '%s\n' "$flags" | grep -qE '^-(name|sname|setcookie)([[:space:]]|$)'; then
            # LOOPBACK IS ONE ADDRESS, NOT ONE DIRECTIVE. `inet_dist_use_interface'
            # is also how a node binds an address the world can reach: `{0,0,0,0}'
            # or the box's own LAN address reads as loopback under a check that
            # only asks whether the line is there, which would report an exposed
            # node as the safe form.
            bind=$(printf '%s\n' "$flags" |
                   sed -n 's/^\(-kernel[[:space:]]\+\)\?inet_dist_use_interface[[:space:]]*//p' |
                   tr -d '[:space:]"')
            if case "$bind" in
                   "{127,0,0,1}"|"{0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,1}"|"127.0.0.1"|"::1")
                       true ;;
                   *) false ;;
               esac; then
                echo "$name	$ref	$sha	distribution	loopback"
            else
                echo "$name	$ref	$sha	distribution	open"
            fi
        else
            echo "$name	$ref	$sha	distribution	unknown"
        fi
    fi

    # A COOKIE IN THE IMAGE IS ONE COOKIE IN EVERY COPY OF A PUBLIC IMAGE: the
    # node's only other defence is the box's firewall, so it is reported apart
    # from the form even when the form is open.
    container=$(git -C "$repo" show "$ref:Containerfile" 2>/dev/null || true)
    # `env' in lower case is the same instruction, so the scan is
    # case-insensitive in both the keyword and the variable.
    if printf '%s\n' "$container" | grep -qiE '^[[:space:]]*env[[:space:]]+[a-z_]*cookie'; then
        echo "$name	$ref	$sha	image-cookie	Containerfile"
    fi
    compose=$(git -C "$repo" show "$ref:deploy/docker-compose.yml" 2>/dev/null || true)
    # A COOKIE THE COMPOSE FILE PASSES THROUGH IS NOT A BAKED-IN ONE: the house
    # form reads it from the box's environment, which is the point of the form.
    # Only a literal value is a cookie this repository carries.
    if printf '%s\n' "$compose" | tr -d '\r' |
       grep -qE '^[[:space:]]*(-[[:space:]]*)?[A-Za-z_]*COOKIE[[:space:]]*[:=][[:space:]]*[^$[:space:]]'; then
        echo "$name	$ref	$sha	compose-cookie	deploy/docker-compose.yml"
    fi
done
