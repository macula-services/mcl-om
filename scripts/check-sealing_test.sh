#!/usr/bin/env bash
# Test scripts/check-sealing.sh. No mesh, no network: every case is a fixture.
#
# WHY THIS EXISTS. check-sealing.sh is the half of the sealing measurement that can be
# tested offline, and an untested checker is worse than none: a checker that silently
# reports "no findings" when it should have failed is evidence of the opposite of what
# it claims. Each rule gets a case that must fire and a case that must stay quiet, and
# the quiet case is the one that matters -- a checker that fails everything is useless.
#
# Usage: scripts/check-sealing_test.sh [--verbose]
#
# Exits 0 when every case behaves, 1 when any does not, printing the case that broke
# and the checker's own output for it.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECK="$SCRIPT_DIR/check-sealing.sh"
FIXTURES="$SCRIPT_DIR/sealing/fixtures"
VERBOSE=0
[ "${1:-}" = "--verbose" ] && VERBOSE=1

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0
OUT="$TMP/out"

# Every case starts from an EMPTY not-a-service file, so a case that does not mean
# to test rule E cannot start firing because someone added a real entry to the
# committed file. A case that passes its own --not-services overrides this.
NSNONE="$FIXTURES/not-services-empty.tsv"

# ...and from an EMPTY stations file, for the same reason: rule F reads the committed
# station list, which is the fleet's, and a fixture listing names no stations at all.
# A case that tests rule F passes its own --stations.
STNONE="$FIXTURES/stations-none.tsv"

# Run the checker and record its exit code. Output is kept in $OUT for the assertions.
run() {
    case " $* " in
        *" --not-services "*) nsf=0 ;;
        *)                    nsf=1 ;;
    esac
    case " $* " in
        *" --stations "*) stf=0 ;;
        *)                stf=1 ;;
    esac
    set -- "$@" \
        $([ "$nsf" = 1 ] && printf '%s\n' --not-services "$NSNONE") \
        $([ "$stf" = 1 ] && printf '%s\n' --stations "$STNONE")
    "$CHECK" "$@" >"$OUT" 2>&1
    echo $?
}

ok() { pass=$((pass + 1)); [ "$VERBOSE" = 1 ] && printf 'ok    %s\n' "$1"; return 0; }

bad() {
    fail=$((fail + 1))
    printf 'FAIL  %s\n' "$1"
    sed 's/^/      | /' "$OUT"
}

# A case is <description> <expected exit> <checker args...>.
case_exit() {
    desc="$1"; want="$2"; shift 2
    got="$(run "$@")"
    if [ "$got" = "$want" ]; then ok "$desc"; else bad "$desc (exit $got, wanted $want)"; fi
}

# The checker's output must carry a finding line starting with <tag>.
case_tag() {
    desc="$1"; tag="$2"; shift 2
    got="$(run "$@")"
    if [ "$got" = "0" ]; then bad "$desc (exit 0, no findings, wanted $tag)"; return; fi
    if grep -q "^$tag " "$OUT"; then ok "$desc"; else bad "$desc (wanted a $tag finding)"; fi
}

# ...and must NOT carry one. This is the half that catches a checker which fails
# everything, or which fires on a fixture that is correct.
case_no_tag() {
    desc="$1"; tag="$2"; shift 2
    run "$@" >/dev/null
    if grep -q "^$tag " "$OUT"; then bad "$desc (unexpected $tag finding)"; else ok "$desc"; fi
}

S="$FIXTURES/services-small.tsv"
NONE="$FIXTURES/opt-outs-empty.tsv"

# --- Rule A: a keyless advertisement with no written opt-out -------------------
case_tag    "A  keyless with no opt-out is NO-OFF"     NO-OFF \
    "$FIXTURES/keyless-no-off.tsv" --services "$S" --opt-outs "$NONE" --quiet
case_exit   "A  keyless with no opt-out exits 1"       1 \
    "$FIXTURES/keyless-no-off.tsv" --services "$S" --opt-outs "$NONE" --quiet
case_no_tag "A  a written opt-out answers it"          NO-OFF \
    "$FIXTURES/keyless-with-off.tsv" --services "$S" --opt-outs "$FIXTURES/opt-outs-one.tsv" --quiet
case_exit   "A  keyless with a written opt-out passes" 0 \
    "$FIXTURES/keyless-with-off.tsv" --services "$S" --opt-outs "$FIXTURES/opt-outs-one.tsv" --quiet

# --- Rule B: an opt-out that nothing answers ----------------------------------
case_tag    "B  a stale opt-out is STALE-OFF"          STALE-OFF \
    "$FIXTURES/all-keyed.tsv" --services "$S" --opt-outs "$FIXTURES/opt-outs-stale.tsv" --quiet
case_exit   "B  a stale opt-out exits 1"               1 \
    "$FIXTURES/all-keyed.tsv" --services "$S" --opt-outs "$FIXTURES/opt-outs-stale.tsv" --quiet

# --- Rule C: a service that advertised nothing --------------------------------
case_tag    "C  a silent service is ABSENT"            ABSENT \
    "$FIXTURES/absent.tsv" --services "$S" --opt-outs "$NONE" --quiet
case_exit   "C  a silent service exits 1"              1 \
    "$FIXTURES/absent.tsv" --services "$S" --opt-outs "$NONE" --quiet

# --- Rule D: a procedure belonging to no known service ------------------------
case_tag    "D  an unknown procedure is UNKNOWN"       UNKNOWN \
    "$FIXTURES/unknown.tsv" --services "$S" --opt-outs "$NONE" --quiet
case_exit   "D  an unknown procedure exits 1"          1 \
    "$FIXTURES/unknown.tsv" --services "$S" --opt-outs "$NONE" --quiet

# --- Mid-roll: one procedure advertised both ways ------------------------------
# The box-by-box roll is the fleet's normal state, and the half that has not rolled
# is still readable. One NO-OFF, not one per distinct mode.
case_tag    "mixed roll is NO-OFF"                     NO-OFF \
    "$FIXTURES/mixed-roll.tsv" --services "$S" --opt-outs "$NONE" --quiet
case_exit   "mixed roll exits 1"                       1 \
    "$FIXTURES/mixed-roll.tsv" --services "$S" --opt-outs "$NONE" --quiet
run "$FIXTURES/mixed-roll.tsv" --services "$S" --opt-outs "$NONE" --quiet >/dev/null
if [ "$(grep -c '^NO-OFF ' "$OUT")" = "1" ]; then ok "mixed roll reports the procedure once"
else bad "mixed roll reports the procedure once (got $(grep -c '^NO-OFF ' "$OUT"))"; fi

# --- Rule E: a declared not-a-service prefix nothing answers --------------------
# Rule D is answered by a WRITTEN claim, and the claim is held to the same
# discipline as an opt-out: one that matches nothing is a finding.
NS="$FIXTURES/not-services-ring.tsv"
case_exit   "a declared not-a-service prefix answers the procedure" 0 \
    "$FIXTURES/with-ring.tsv" --services "$S" --opt-outs "$NONE" --not-services "$NS" --quiet
case_no_tag "a declared not-a-service prefix is not UNKNOWN"       UNKNOWN \
    "$FIXTURES/with-ring.tsv" --services "$S" --opt-outs "$NONE" --not-services "$NS" --quiet
case_tag    "an undeclared prefix is still UNKNOWN"                UNKNOWN \
    "$FIXTURES/with-ring.tsv" --services "$S" --opt-outs "$NONE" --quiet
case_no_tag "a clear procedure under a declared prefix is not NO-OFF" NO-OFF \
    "$FIXTURES/with-clear-ring.tsv" --services "$S" --opt-outs "$NONE" --not-services "$NS" --quiet
case_exit   "a clear procedure under a declared prefix passes"       0 \
    "$FIXTURES/with-clear-ring.tsv" --services "$S" --opt-outs "$NONE" --not-services "$NS" --quiet
case_tag    "a not-a-service prefix that matched nothing is stale"  STALE-NOT-SERVICE \
    "$FIXTURES/all-keyed.tsv" --services "$S" --opt-outs "$NONE" --not-services "$NS" --quiet

# --- Rule F: the listing must have read every station --------------------------
# A DHT read is answered from the records ONE station holds, so a listing taken from
# one station is one replica set and an advertisement held only on another station's
# replicas never appears (mcl-om#44 R1). The committed station list is what turns a
# quiet zero into a finding.
ST6="$FIXTURES/stations-six.tsv"
case_tag    "F  a station the listing never names is UNMEASURED" UNMEASURED \
    "$FIXTURES/stations-five-covered.tsv" --services "$S" --opt-outs "$NONE" --stations "$ST6" --quiet
case_exit   "F  an unmeasured station exits 1"          1 \
    "$FIXTURES/stations-five-covered.tsv" --services "$S" --opt-outs "$NONE" --stations "$ST6" --quiet
if grep -q '^UNMEASURED *station station-6 ' "$OUT"; then ok "F  the missing station is the one named"
else bad "F  the missing station is the one named"; fi
case_tag    "F  a station that advertised nothing is UNMEASURED" UNMEASURED \
    "$FIXTURES/stations-empty-one.tsv" --services "$S" --opt-outs "$NONE" --stations "$ST6" --quiet
case_exit   "F  a station with nothing to show exits 1"  1 \
    "$FIXTURES/stations-empty-one.tsv" --services "$S" --opt-outs "$NONE" --stations "$ST6" --quiet
# ...and the half that matters: a full survey fires nothing.
case_no_tag "F  a full survey has no UNMEASURED"        UNMEASURED \
    "$FIXTURES/stations-all-covered.tsv" --services "$S" --opt-outs "$NONE" --stations "$ST6" --quiet
case_exit   "F  a full survey passes"                   0 \
    "$FIXTURES/stations-all-covered.tsv" --services "$S" --opt-outs "$NONE" --stations "$ST6" --quiet

# --- R3: an empty file must not shift the sections -----------------------------
# A 0-byte file has no first line, so a section boundary inferred from FNR would
# never fire for it and every later section would be read one file early -- the
# listing read as the not-services file, and the wrong findings printed (mcl-om#44
# R3). Sections are marked now. This case puts a 0-byte file in the middle and
# asserts the listing still arrives whole, by its own summary line.
got="$(run "$FIXTURES/all-keyed.tsv" --services "$S" --opt-outs "$FIXTURES/zero-byte-opt-outs.tsv")"
if [ "$got" = "0" ] && grep -q '^procedures listed   2$' "$OUT"; then
    ok "R3 a 0-byte opt-out file leaves the listing intact"
else
    bad "R3 a 0-byte opt-out file leaves the listing intact (exit $got)"
fi
: >"$TMP/zero.tsv"
got="$(run "$FIXTURES/keyless-no-off.tsv" --services "$S" --opt-outs "$NONE" --not-services "$TMP/zero.tsv")"
if [ "$got" = "1" ] && grep -q '^NO-OFF ' "$OUT" && ! grep -q '^UNKNOWN \|^MALFORMED ' "$OUT"; then
    ok "R3 a 0-byte not-services file still reads the listing"
else
    bad "R3 a 0-byte not-services file still reads the listing (exit $got)"
fi

# --- The clean case: nothing may fire -----------------------------------------
case_exit   "clean listing passes"                     0 \
    "$FIXTURES/all-keyed.tsv" --services "$S" --opt-outs "$NONE" --quiet
got="$(run "$FIXTURES/all-keyed.tsv" --services "$S" --opt-outs "$NONE")"
if [ "$got" = "0" ] && grep -q '^no findings$' "$OUT"; then ok "clean listing says no findings"
else bad "clean listing says no findings (exit $got)"; fi

# --- Malformed input ----------------------------------------------------------
F="$TMP/malformed-mode.tsv"
printf 'mcl-warden/limits\tsealed\n' >"$F"
case_tag    "a mode other than keyed/keyless is MALFORMED" MALFORMED \
    "$F" --services "$S" --opt-outs "$NONE" --quiet

F="$TMP/malformed-short.tsv"
printf 'mcl-warden/limits\n' >"$F"
case_tag    "a listing line with no mode is MALFORMED" MALFORMED \
    "$F" --services "$S" --opt-outs "$NONE" --quiet

F="$TMP/comments.tsv"
printf '# a comment\n\nmcl-warden/limits\tkeyed\t# trailing comment\n' >"$F"
case_exit   "comments and blank lines are ignored"     0 \
    "$F" --services "$FIXTURES/services-warden-only.tsv" --opt-outs "$NONE" --quiet

case_exit   "a missing listing exits 2"                2 \
    "$TMP/does-not-exist.tsv" --services "$S" --opt-outs "$NONE"

# --- The real inventory -------------------------------------------------------
# Every service in the committed services.tsv must attribute a plausibly named
# procedure, including the pair that makes longest-prefix matching load-bearing:
# mcl-bookclub is a prefix of mcl-bookclub-observer, so a listing that carries only
# observer procedures must not leave observer ABSENT by crediting bookclub.
REAL="$SCRIPT_DIR/sealing/services.tsv"
gen="$TMP/real.tsv"
awk -F'\t' '$1 !~ /^#/ && NF >= 1 && $1 != "" { printf "%s/probe\tkeyed\n", $1 }' "$REAL" >"$gen"
case_exit   "every committed service attributes a probe procedure" 0 \
    "$gen" --services "$REAL" --opt-outs "$NONE" --quiet

# A service name is not a prefix of another: mcl-bookclub is a prefix of
# mcl-bookclub-phoenix/info, and a bare `index(proc, s) == 1` credited that procedure
# to mcl-bookclub -- so the undeployed service was neither UNKNOWN nor its own owner
# ABSENT (mcl-om#44 R2). Match on the first path SEGMENT.
case_tag    "a phoenix procedure is not a bookclub procedure" UNKNOWN \
    "$FIXTURES/bookclub-phoenix.tsv" --services "$REAL" --opt-outs "$NONE" --quiet
if grep -q '^UNKNOWN *mcl-bookclub-phoenix/info' "$OUT"; then ok "the phoenix procedure is the UNKNOWN one"
else bad "the phoenix procedure is the UNKNOWN one"; fi
if grep -q '^ABSENT *mcl-bookclub-observer ' "$OUT"; then bad "observer is not left ABSENT by phoenix"
else ok "observer is not left ABSENT by phoenix"; fi

F="$TMP/bookclub.tsv"
printf 'mcl-bookclub-observer/probe\tkeyed\n' >"$F"
case_tag    "observer is not credited to bookclub"     ABSENT \
    "$F" --services "$REAL" --opt-outs "$NONE" --quiet
if grep -q '^ABSENT *mcl-bookclub ' "$OUT" && ! grep -q '^ABSENT *mcl-bookclub-observer' "$OUT"; then
    ok "bookclub alone is the ABSENT one"
else
    bad "bookclub alone is the ABSENT one"
fi

# --- Summary ------------------------------------------------------------------
printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
exit 0
