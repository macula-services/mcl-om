#!/usr/bin/env bash
# Publish mcl_om to hex.pm.
#
# YOU run this — it fires the actual `rebar3 hex publish`. Claude prepares the
# release (version bump, CHANGELOG, docs, dialyzer/edoc verification) but never
# runs the publish itself.
#
# Pre-flight (Claude does these before handing off):
#   - src/mcl_om.app.src vsn bumped + matching CHANGELOG.md entry
#   - rebar3 ct        (tests green)
#   - rebar3 dialyzer  (clean)
#   - rebar3 ex_doc    (builds clean — verify guides/extras render)
#
# Requires HEX_API_KEY in the environment (see ~/.config/zshrc/01-secrets:
# HEX_API_KEY / HEX_MACULA_CICD_API_KEY). `rebar3 hex publish` is interactive
# and asks for confirmation before it uploads.
#
# Dependency-aware order: macula (4.8.0+) must already be on hex — it is.
set -euo pipefail

cd "$(dirname -- "$0")/.."

VSN=$(grep -oE '\{vsn, *"[^"]+"' src/mcl_om.app.src | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')
echo "==> Preparing to publish mcl_om ${VSN}"

grep -q "## \[${VSN}\]" CHANGELOG.md \
    || { echo "ERROR: no CHANGELOG.md entry for ${VSN}" >&2; exit 1; }

: "${HEX_API_KEY:?set HEX_API_KEY (source ~/.config/zshrc/01-secrets)}"

echo "==> Re-running release gates"
rebar3 ct
rebar3 dialyzer
rebar3 ex_doc

echo "==> Publishing package + docs to hex.pm (interactive confirm)"
rebar3 hex publish

echo "==> Done. Tag the release:"
echo "    git tag v${VSN} && git push origin v${VSN}"
