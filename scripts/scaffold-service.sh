#!/usr/bin/env bash
# Scaffold a new mcl service.
#
# A thin wrapper over `rebar3 new mcl_service'. The template does the work;
# this exists for one reason worth a script: **you say the name once**.
#
# A service has two names and they differ. The repository, the container image
# and the name it answers to on the mesh are kebab-case; the OTP application and
# every module prefix are snake_case, because they are Erlang atoms. A rebar3
# template cannot derive one from the other, since mustache has no functions, so
# without this wrapper you would type both and eventually mistype one.
#
# WHAT CHANGED. The previous version of this script rendered a handful of files
# with sed and left you to write rebar.config, the .app.src and the supervisor by
# hand, so a "scaffolded" service did not compile. It also emitted a Quadlet unit
# that nothing on the fleet uses. It now generates a complete repository that
# compiles, tests and deploys.
#
# Usage:
#
#   MCL_VISIBILITY=private scripts/scaffold-service.sh mcl-foo "Does X over the mesh" 8484
#
# MCL_VISIBILITY IS ASKED, NEVER ASSUMED: `private' or `public', and nothing
# else. It decides three things that must agree. A private service carries a
# proprietary notice and runs CI on the org's own runners; a public one is
# Apache-2.0 and runs on GitHub's, never on ours, because a pull request from
# anyone would run its code on our machine. MCL_RUNS_ON overrides the runner,
# MCL_HOLDER the copyright holder.
#
# Creates ./mcl-foo/ in the CURRENT directory, so run it from wherever the new
# repository should live, typically ~/work/github.com/macula-services.

set -euo pipefail

REPO_NAME="${1:?usage: scaffold-service.sh <repo-name> \"<description>\" [health-port]}"
DESCRIPTION="${2:?one-line description required}"
HEALTH_PORT="${3:-8484}"

# WHO IS BUILDING THIS. Defaulted to the macula-services fleet because that is
# who runs this script most, and overridable because the scaffold is meant to
# be usable by someone who is not us. The template itself hardcodes neither.
ORG="${MCL_ORG:-macula-services}"
REGISTRY="${MCL_REGISTRY:-ghcr.io}"

# WHAT IT BUILDS AND RUNS ON. The fleet's build and runtime image pair is named
# once, as the defaults of builder_image and runtime_image in
# priv/templates/mcl_service.template, so this script repeats neither and
# passes the images only when MCL_BUILDER_IMAGE and MCL_RUNTIME_IMAGE override
# them. BOTH OR NEITHER: a release built in one image runs on the other's libc
# and OpenSSL, so half a pair generates a service that builds and then fails
# to load its NIFs or to complete a PQ handshake. SET, not non-empty: an
# exported empty variable is someone's override gone wrong, and treating it as
# unset would quietly hand them the house pair.
IMAGE_ARGS=()
if [ -z "${MCL_BUILDER_IMAGE+set}${MCL_RUNTIME_IMAGE+set}" ]; then
    :
elif [ -n "${MCL_BUILDER_IMAGE:-}" ] && [ -n "${MCL_RUNTIME_IMAGE:-}" ]; then
    IMAGE_ARGS=(builder_image="${MCL_BUILDER_IMAGE}" runtime_image="${MCL_RUNTIME_IMAGE}")
else
    echo "MCL_BUILDER_IMAGE='${MCL_BUILDER_IMAGE-<unset>}' and MCL_RUNTIME_IMAGE='${MCL_RUNTIME_IMAGE-<unset>}':" \
         "the images are a pair, set both (non-empty) or neither" >&2
    exit 64
fi

# THE CHOICE, before anything is generated.
case "${MCL_VISIBILITY:-}" in
    private) PROPRIETARY=1 ;;
    public)  PROPRIETARY= ;;
    *)
        echo "MCL_VISIBILITY='${MCL_VISIBILITY-<unset>}': set it to private or public." \
             "It decides the licence, the CI runner and the repository's visibility," \
             "so it is asked rather than assumed" >&2
        exit 64
        ;;
esac

# THE RUNNER. The house orgs run private services' CI on their own runners
# (msi00, one per org, labels self-hosted, msi00 and pq, as registered); everything else runs on
# GitHub's.
case "${MCL_VISIBILITY}:${ORG}" in
    private:macula-services|private:macula-internal) DEFAULT_RUNS_ON="[self-hosted, msi00, pq]" ;;
    *)                                               DEFAULT_RUNS_ON="ubuntu-latest" ;;
esac
RUNS_ON="${MCL_RUNS_ON:-${DEFAULT_RUNS_ON}}"

if [ "${MCL_VISIBILITY}" = public ] && printf '%s' "${RUNS_ON}" | grep -q 'self-hosted'; then
    echo "MCL_RUNS_ON='${RUNS_ON}' names a self-hosted runner for a public repository:" \
         "a pull request from anyone would run its code on that machine" >&2
    exit 64
fi

HOLDER_ARGS=()
if [ -n "${MCL_HOLDER:-}" ]; then
    HOLDER_ARGS=(holder="${MCL_HOLDER}")
fi

# mcl-foo -> mcl_foo. The generated eunit suite asserts the two agree
# modulo the separator, so a hand-rolled `rebar3 new' with a mismatched pair
# still fails on the first test run rather than shipping.
APP_NAME="${REPO_NAME//-/_}"

if ! printf '%s' "${APP_NAME}" | grep -qE '^[a-z][a-z0-9_]*$'; then
    echo "'${REPO_NAME}' does not yield a valid Erlang atom ('${APP_NAME}')" >&2
    exit 65
fi

if ! printf '%s' "${HEALTH_PORT}" | grep -qE '^[0-9]{2,5}$'; then
    echo "health port '${HEALTH_PORT}' is not a port number" >&2
    exit 65
fi

if [ -e "${REPO_NAME}" ]; then
    echo "'${PWD}/${REPO_NAME}' already exists" >&2
    exit 66
fi

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# rebar3 only finds custom templates under ~/.config/rebar3/templates, and an
# empty directory has no dependencies to carry them there, so they must be
# installed on the machine. Do it rather than fail with rebar3's "template not
# found", which does not hint at the cause.
if [ ! -e "${HOME}/.config/rebar3/templates/mcl_service.template" ]; then
    echo "[scaffold] installing templates first"
    "${HERE}/install-templates.sh" >/dev/null
fi

echo "[scaffold] ${REPO_NAME} (app ${APP_NAME}, ${MCL_VISIBILITY}, ${REGISTRY}/${ORG}, health port ${HEALTH_PORT}, runs on ${RUNS_ON}, images: ${MCL_BUILDER_IMAGE:-the fleet pair})"

rebar3 new mcl_service \
    repo="${REPO_NAME}" \
    name="${APP_NAME}" \
    desc="${DESCRIPTION}" \
    org="${ORG}" \
    registry="${REGISTRY}" \
    health_port="${HEALTH_PORT}" \
    proprietary="${PROPRIETARY}" \
    runs_on="${RUNS_ON}" \
    ${HOLDER_ARGS[@]+"${HOLDER_ARGS[@]}"} \
    ${IMAGE_ARGS[@]+"${IMAGE_ARGS[@]}"}

if [ "${MCL_VISIBILITY}" = private ]; then
    PACKAGE_NOTE="The image package is private like the repository: whatever pulls it needs
a registry login with read access to ${REGISTRY}/${ORG}/${REPO_NAME}."
else
    PACKAGE_NOTE="Once CI has pushed the first image, check the package is PUBLIC. It may be
created private, and the pull then fails on the host with a bare \"unauthorized\"
that names nothing."
fi

cat <<EOF

Next, and none of these can be generated:

  cd ${REPO_NAME}
  rebar3 eunit && rebar3 lint && rebar3 dialyzer
  git init -b main && git add . && git commit
  gh repo create ${ORG}/${REPO_NAME} --${MCL_VISIBILITY} --source=. --remote=origin
  git remote set-url origin git@github.com:${ORG}/${REPO_NAME}.git

The remote must be SSH, or the token must carry the 'workflow' scope: an HTTPS
push that creates .github/workflows/ without it is refused, and the error names
the file, not the scope.

CI publishes two channels: a push to main publishes :latest, a v* tag
publishes that version and nothing else.

${PACKAGE_NOTE}
EOF

if [ "${ORG}" = "macula-services" ]; then
cat <<EOF

Deploying on the Macula fleet is not part of the scaffold. macula-fleet
(private) says what every box runs: claim the health port in its PORTS.md and
add the service to the box that runs it, image pinned by digest. Its README
says which boxes pull from it. The identity key file mounts from the box's
secret store onto /etc/mcl/secrets/ (the Containerfile VOLUME); the station
pins (MACULA_STATION_SEEDS, MACULA_STATION_NODE_IDS) and the realm
(MCL_REALM, MCL_REALM_KEY) come from there too, and the service refuses to
boot without them.
EOF
fi
