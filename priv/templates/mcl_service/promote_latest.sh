#!/bin/sh
# Points <image>:latest at a signed digest, as a CARBON COPY of its manifest.
#
#   scripts/promote_latest.sh <registry>/<repository> <sha256:digest>
#
# Plain curl against the registry API, so it runs wherever the build runs,
# docker or a podman shim alike (no buildx). The manifest is fetched by
# digest, its bytes are checked against that digest, and the same bytes are
# put under :latest; re-serialising it (a pull, tag and push, or an index
# wrapped around it) would give :latest a digest that was never signed. Then
# :latest is read back and must name the digest, or the run fails.
#
# REGISTRY_USER and REGISTRY_TOKEN, when set, are exchanged at the
# registry's token endpoint for a pull,push bearer on this repository only.
# REGISTRY_SCHEME (default https) lets the test run against a local registry.
set -eu

IMAGE="${1:?usage: promote_latest.sh <registry>/<repository> <sha256:digest>}"
DIGEST="${2:?usage: promote_latest.sh <registry>/<repository> <sha256:digest>}"
REGISTRY="${IMAGE%%/*}"
REPOSITORY="${IMAGE#*/}"
BASE="${REGISTRY_SCHEME:-https}://$REGISTRY/v2/$REPOSITORY/manifests"
ACCEPT="application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json, application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json"

case "$DIGEST" in
    sha256:*) ;;
    *) echo "::error::not a sha256 digest: $DIGEST"; exit 1 ;;
esac

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# The bearer goes in a curl config file, never on a command line.
: > "$WORK/auth"
if [ -n "${REGISTRY_TOKEN:-}" ]; then
    bearer=$(printf 'user = "%s:%s"\n' "${REGISTRY_USER:?REGISTRY_USER is not set}" "$REGISTRY_TOKEN" \
        | curl -fsS -K - "${REGISTRY_SCHEME:-https}://$REGISTRY/token?scope=repository:$REPOSITORY:pull,push" \
        | sed -n 's/.*"token" *: *"\([^"]*\)".*/\1/p')
    [ -n "$bearer" ] || { echo "::error::the registry issued no token for $REPOSITORY"; exit 1; }
    printf 'header = "Authorization: Bearer %s"\n' "$bearer" > "$WORK/auth"
fi

curl -fsS -K "$WORK/auth" -H "Accept: $ACCEPT" -D "$WORK/headers" -o "$WORK/manifest" "$BASE/$DIGEST"
got="sha256:$(sha256sum "$WORK/manifest" | cut -d' ' -f1)"
[ "$got" = "$DIGEST" ] || { echo "::error::the manifest fetched for $DIGEST hashes to $got"; exit 1; }
type=$(tr -d '\r' < "$WORK/headers" | sed -n 's/^[Cc]ontent-[Tt]ype: *//p' | tail -1)
[ -n "$type" ] || { echo "::error::the registry named no media type for $DIGEST"; exit 1; }

curl -fsS -K "$WORK/auth" -X PUT -H "Content-Type: $type" --data-binary "@$WORK/manifest" "$BASE/latest" -o /dev/null

now=$(curl -fsS -K "$WORK/auth" -I -H "Accept: $ACCEPT" "$BASE/latest" \
    | tr -d '\r' | sed -n 's/^[Dd]ocker-[Cc]ontent-[Dd]igest: *//p')
[ "$now" = "$DIGEST" ] || { echo "::error:::latest resolves to ${now:-nothing}, not the signed $DIGEST"; exit 1; }
echo ":latest -> $DIGEST"
