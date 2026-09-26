#!/usr/bin/env bash
# Is each image reference pullable, anonymously, by the digest it pins?
#
#   scripts/is_image_published.sh <registry/repo[:tag]@sha256:digest>...
#
# The scaffold pins its default build and runtime images by digest, and every
# service generated from it inherits them. A digest that was deleted, or a
# package made private, would still pass every test that reads the text, and
# the first anyone would hear of it is a new service's first image build. This
# asks the registry for each manifest the way an anonymous `docker pull' would
# (a pull token, then a HEAD on the manifest by digest) and fails naming every
# reference that does not resolve.
#
# Speaks the OCI distribution API with the bearer-token flow ghcr.io and Docker
# Hub use. A reference without a digest is refused: pinning is the point.
set -euo pipefail

[ "$#" -gt 0 ] || { echo "usage: $0 <image@sha256:digest>..." >&2; exit 64; }

ACCEPT="application/vnd.oci.image.index.v1+json,application/vnd.oci.image.manifest.v1+json,application/vnd.docker.distribution.manifest.list.v2+json,application/vnd.docker.distribution.manifest.v2+json"

missing=0
for ref in "$@"; do
    case "$ref" in
        */*@sha256:*) ;;
        *) echo "NOT PINNED: $ref (needs registry/repository@sha256:<digest>)" >&2
           missing=1; continue ;;
    esac
    registry="${ref%%/*}"
    rest="${ref#*/}"
    digest="${rest##*@}"
    repo="${rest%@*}"
    repo="${repo%%:*}"
    # Docker Hub's names are shorthand for its API host and `library/'.
    if [ "$registry" = "docker.io" ]; then
        registry=registry-1.docker.io
        case "$repo" in */*) ;; *) repo="library/${repo}" ;; esac
    fi

    # The registry names its token service in the 401 it answers first (to a
    # GET: ghcr omits the header on a HEAD).
    challenge=$(curl -sS -D - -o /dev/null "https://${registry}/v2/" | tr -d '\r' \
                | sed -n 's/^[Ww][Ww][Ww]-[Aa]uthenticate: Bearer //p')
    realm=$(printf '%s' "$challenge" | sed -n 's/.*realm="\([^"]*\)".*/\1/p')
    service=$(printf '%s' "$challenge" | sed -n 's/.*service="\([^"]*\)".*/\1/p')
    auth=()
    if [ -n "$realm" ]; then
        token=$(curl -sS "${realm}?service=${service}&scope=repository:${repo}:pull" \
                | sed -n 's/.*"token":"\([^"]*\)".*/\1/p')
        [ -n "$token" ] && auth=(-H "Authorization: Bearer ${token}")
    fi

    status=$(curl -sS -o /dev/null -w '%{http_code}' -I \
                  ${auth[@]+"${auth[@]}"} -H "Accept: ${ACCEPT}" \
                  "https://${registry}/v2/${repo}/manifests/${digest}")
    if [ "$status" = "200" ]; then
        echo "published: $ref"
    else
        echo "NOT PUBLISHED (HTTP $status): $ref" >&2
        missing=1
    fi
done
exit "$missing"
