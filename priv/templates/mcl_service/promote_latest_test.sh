#!/bin/sh
# Proves scripts/promote_latest.sh against a registry nobody else uses.
#
#   REGISTRY=localhost:5000 scripts/promote_latest_test.sh
#
# lint.yml runs it with a registry service container. Two images, one and two,
# go to the registry, and :latest starts on two. Then:
#   P1  promoting one's digest makes :latest name exactly that digest
#   P2  a digest the registry does not hold fails, and :latest stays put
#   P3  a digest that is not sha256 fails before any request is sent
set -eu

REGISTRY="${REGISTRY:?REGISTRY is not set, e.g. localhost:5000}"
REPO="$REGISTRY/promote-latest-test"
HERE=$(cd "$(dirname "$0")" && pwd)
# Indexes too: docker 29 on a hosted runner pushes an OCI index (the image
# beside its attestation manifests), and a registry answers 404 for a reference
# whose media type the request does not accept.
ACCEPT="application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json, application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
fails=0

digest_of() {
    curl -fsS -I -H "Accept: $ACCEPT" "http://$REGISTRY/v2/promote-latest-test/manifests/$1" \
        | tr -d '\r' | sed -n 's/^[Dd]ocker-[Cc]ontent-[Dd]igest: *//p'
}

check() {
    if [ "$2" = "$3" ]; then echo "PASS $1"; else echo "FAIL $1: expected $3, got $2"; fails=$((fails + 1)); fi
}

for name in one two; do
    mkdir -p "$WORK/$name"
    echo "$name" > "$WORK/$name/content"
    printf 'FROM scratch\nCOPY content /content\n' > "$WORK/$name/Containerfile"
    docker build -q -f "$WORK/$name/Containerfile" -t "$REPO:$name" "$WORK/$name" > /dev/null
    docker push -q "$REPO:$name" > /dev/null
done
docker tag "$REPO:two" "$REPO:latest"
docker push -q "$REPO:latest" > /dev/null

one=$(digest_of one)
two=$(digest_of two)
[ -n "$one" ] && [ "$one" != "$two" ] || { echo "FAIL setup: one=$one two=$two"; exit 1; }
check "setup: :latest starts on two" "$(digest_of latest)" "$two"

if REGISTRY_SCHEME=http sh "$HERE/promote_latest.sh" "$REPO" "$one"; then rc=0; else rc=1; fi
check "P1 the promotion succeeds" "$rc" 0
check "P1 :latest names the promoted digest" "$(digest_of latest)" "$one"

missing=sha256:0000000000000000000000000000000000000000000000000000000000000000
if REGISTRY_SCHEME=http sh "$HERE/promote_latest.sh" "$REPO" "$missing" 2>/dev/null; then rc=0; else rc=1; fi
check "P2 an unknown digest is refused" "$rc" 1
check "P2 :latest stays put" "$(digest_of latest)" "$one"

if REGISTRY_SCHEME=http sh "$HERE/promote_latest.sh" "$REPO" "latest" > "$WORK/p3" 2>&1; then rc=0; else rc=1; fi
check "P3 a non-digest is refused" "$rc" 1
check "P3 it says why" "$(grep -c 'not a sha256 digest' "$WORK/p3")" 1

for tag in one two latest; do docker rmi "$REPO:$tag" > /dev/null 2>&1 || true; done
[ "$fails" -eq 0 ] || { echo "$fails check(s) failed"; exit 1; }
echo "PASS: promote_latest.sh carbon-copies a digest to :latest and refuses anything else"
