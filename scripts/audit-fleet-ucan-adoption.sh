#!/usr/bin/env bash
# Fleet-wide audit for PLAN_ROLL_OUT_UCAN_REQUIRED.md's Phase 1: which
# hecate-services can `mcl_om_capabilities:unguarded_capabilities/1`
# (and the boot-time warning built on it, in this same release) actually
# see, and which cannot.
#
# WHY A SEPARATE SCRIPT. `unguarded_capabilities/1` audits whatever a
# service's own `capabilities/0' callback reports -- but `capabilities/0'
# can under-report: a service that calls `macula:advertise/5',
# `macula_response:advertise_direct/7' or `macula_streamer:advertise_direct/7'
# directly, outside `mcl_om_capabilities:register/1', is advertising
# something the in-process audit never sees at all (this was
# `hecate-rag''s own state before its 0.17.0 migration -- see
# plans/PLAN_UCAN_GATED_CAPABILITIES.md). This script finds that bypass
# pattern by source, since no running BEAM node can observe another
# repo's code. It does NOT attempt to grep a capability list's own
# `auth' keys out of Erlang source -- that would silently give false
# confidence from a regex that can't actually parse a multi-line map
# literal correctly; that check belongs to the runtime audit, which
# reads the real capability() terms, not text.
#
# Usage:
#
#   scripts/audit-fleet-ucan-adoption.sh [workspace-root]
#
# workspace-root defaults to this script's own grandparent directory
# (i.e. ~/work/github.com/hecate-services when run from a normal
# checkout) -- deliberately derived, not hardcoded, so this script stays
# usable against any hecate-services workspace, not just this fleet's.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_ROOT="${1:-$(dirname "$SCRIPT_DIR")/..}"
WORKSPACE_ROOT="$(cd "$WORKSPACE_ROOT" && pwd)"
THIS_REPO="$(basename "$(dirname "$SCRIPT_DIR")")"

BYPASS_PATTERN='macula:advertise\(|macula_response:advertise_direct\(|macula_streamer:advertise_direct\('

echo "Auditing hecate-services under: $WORKSPACE_ROOT"
echo "(excluding $THIS_REPO itself, and each repo's own _build/ output)"
echo

printf '%-24s %-18s %-14s %s\n' "SERVICE" "USES_MCL_OM" "OWN_BOOT_CALL" "DIRECT_ADVERTISE_CALLS (bypass risk)"
printf '%-24s %-18s %-14s %s\n' "-------" "--------------" "-------------" "-------------------------------------"

for repo_path in "$WORKSPACE_ROOT"/*/; do
    repo_name="$(basename "$repo_path")"
    [ "$repo_name" = "$THIS_REPO" ] && continue
    [ -f "$repo_path/rebar.config" ] || continue

    uses_mcl_om="no"
    grep -q '{mcl_om,' "$repo_path/rebar.config" 2>/dev/null && uses_mcl_om="yes"

    # Recursive, not a literal src/ glob: a service is as likely to be an
    # umbrella app (apps/<name>/src/*.erl, no top-level src/ at all) as
    # flat -- a literal "$repo_path/src" glob silently missed EVERY
    # umbrella-structured repo the first time this script was run
    # (hecate-agora, hecate-citizens, hecate-mail, hecate-warden and
    # others all reported false "no"s for both checks below). Always
    # exclude _build -- that's a compiled copy of mcl_om itself plus
    # release artifacts, not this repo's own source.
    calls_boot="no"
    { grep -rq 'mcl_om:boot(' --include='*.erl' --exclude-dir=_build "$repo_path" 2>/dev/null && calls_boot="yes"; } || true

    # test/ and test_live/ deliberately excluded: a live-fleet test
    # fixture calling advertise_direct to stand up a fake peer is not
    # the service's own production capability path (found live:
    # hecate-tube/test_live/tube_content_live_station_tests.erl).
    direct_calls="$( { grep -rlE "$BYPASS_PATTERN" --include='*.erl' \
                        --exclude-dir=_build --exclude-dir=test --exclude-dir=test_live \
                        "$repo_path" 2>/dev/null || true; } | sed "s#^$repo_path##" | tr '\n' ' ')"
    [ -z "$direct_calls" ] && direct_calls="-"

    printf '%-24s %-18s %-14s %s\n' "$repo_name" "$uses_mcl_om" "$calls_boot" "$direct_calls"
done

echo
echo "DIRECT_ADVERTISE_CALLS != '-' means: review those file(s) by hand."
echo "Either they're the legacy hand-rolled path (capabilities/0 under-reports,"
echo "unguarded_capabilities/1 cannot see what's advertised there), or they're"
echo "something mcl_om itself doesn't cover yet -- this script can't tell"
echo "those two apart, only that direct advertise calls exist outside the"
echo "framework's own registration path."
