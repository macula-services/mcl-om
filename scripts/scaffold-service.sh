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
#   scripts/scaffold-service.sh mcl-foo "Does X over the mesh" 8484
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

echo "[scaffold] ${REPO_NAME} (app ${APP_NAME}, ${REGISTRY}/${ORG}, health port ${HEALTH_PORT})"

rebar3 new mcl_service \
    repo="${REPO_NAME}" \
    name="${APP_NAME}" \
    desc="${DESCRIPTION}" \
    org="${ORG}" \
    registry="${REGISTRY}" \
    health_port="${HEALTH_PORT}"

cat <<EOF

Next, and none of these can be generated:

  cd ${REPO_NAME}
  rebar3 eunit && rebar3 lint
  git init -b main && git add . && git commit
  gh repo create ${ORG}/${REPO_NAME} --public --source=. --remote=github
  git remote set-url github git@github.com:${ORG}/${REPO_NAME}.git

The remote must be SSH. An HTTPS push that creates .github/workflows/ needs a
token with the 'workflow' scope, and the error names the file, not the scope.

Once CI has pushed the first image, check the package is PUBLIC. It may be
created private, and the pull then fails on the host with a bare "unauthorized"
that names nothing.
EOF

if [ "${ORG}" = "macula-services" ]; then
cat <<EOF

Deploying on the macula-services fleet, which is ours and not part of the
scaffold:

  CI pushes :latest and the semver tag to ghcr.io on every merge to main;
  watchtower on the beam nodes rolls :latest within seconds. A rollback is
  pinning the node to a semver tag. The identity key file mounts from the
  node's secret store onto /etc/mcl/secrets/ (the Containerfile VOLUME); the
  PQ client model also needs the station pin (MACULA_STATION_NODE_IDS) and
  the realm the service belongs to -- neither belongs in this repository.
EOF
fi
