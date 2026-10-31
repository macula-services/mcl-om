#!/usr/bin/env bash
# Check a sealing measurement against what the fleet is supposed to be.
#
# WHY THIS EXISTS. The sealing design (macula-io/macula#135, releases A0/A/B in
# #137 and #138) closes the register row "Payload sealing for calls and streams" on a
# measurement, not on a merge. That measurement is a list of the
# `procedure_advertisement' records the fleet is actually serving, and a list on its
# own proves nothing: it cannot tell a procedure that seals from one that was simply
# not advertising when the listing ran. This script is the other half -- it holds two
# opinions the listing cannot hold by itself (which services must appear, and which
# procedures were WRITTEN `off'), and it fails when the listing and those disagree.
#
# WHAT IT DOES NOT DO. It does not talk to the mesh. Acquisition is a separate step
# (scripts/measure-sealing.escript) because a live query cannot be tested offline and
# this check can: it is pure, and its fixtures are in scripts/sealing/fixtures/.
#
# FIVE RULES, each a way the fleet can look fine while being wrong:
#   A  a keyless procedure with no matching opt-out   -> clear by omission
#   B  an opt-out naming a procedure that never appeared -> a stale decision, or a
#      listing that missed the service, and neither may pass silently
#   C  a service in services.tsv absent from the listing -> absence is a FINDING.
#      A service that is down, booting or not advertising must not pass by being missing
#   D  a listed procedure that belongs to no known service and to no declared
#      not-a-service prefix -> an unmeasured service
#   E  a declared not-a-service prefix that matched nothing -> a written claim
#      about the fleet that the fleet no longer answers
#
# not-services.tsv is the answer to rule D, and it is a list of CLAIMS (each with a
# reason), not an exclusion list: an agent's ring procedure and the realm's own
# identity surface are not services, but that has to be written down somewhere a
# reviewer sees, or the check could never reach "no findings" and so could never be
# a gate. Rule E keeps it honest.
#
# Usage:
#
#   scripts/check-sealing.sh <listing.tsv> [--services F] [--opt-outs F]
#                            [--not-services F] [--quiet]
#
# The listing is one line per advertisement, tab separated:
#
#   <procedure>	<keyed|keyless>
#
# produced by scripts/measure-sealing.escript. Blank lines and lines starting with `#'
# are ignored in every file this script reads.
#
# ONE LINE PER ADVERTISEMENT, which means a procedure served by six boxes arrives
# six times, and a service mid-roll arrives keyed on some boxes and keyless on
# others. Every rule here is about the PROCEDURE, so a procedure is judged once --
# and a procedure seen keyless even once is keyless, because a caller can still
# reach that box.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVICES="$SCRIPT_DIR/sealing/services.tsv"
OPT_OUTS="$SCRIPT_DIR/sealing/opt-outs.tsv"
NOT_SERVICES="$SCRIPT_DIR/sealing/not-services.tsv"
LISTING=""
QUIET=0

while [ $# -gt 0 ]; do
    case "$1" in
        --services)     SERVICES="$2"; shift 2 ;;
        --opt-outs)     OPT_OUTS="$2"; shift 2 ;;
        --not-services) NOT_SERVICES="$2"; shift 2 ;;
        --quiet)        QUIET=1; shift ;;
        -h|--help)      sed -n '2,48p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *)              LISTING="$1"; shift ;;
    esac
done

for f in "$LISTING" "$SERVICES" "$OPT_OUTS" "$NOT_SERVICES"; do
    if [ ! -f "$f" ]; then
        echo "check-sealing: no such file: $f" >&2
        exit 2
    fi
done

awk -F'\t' -v quiet="$QUIET" '
function trim(s) { gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
function report(tag, msg) { findings++; printf "%-8s %s\n", tag, msg }

# Four files, in a fixed order: services, opt-outs, not-services, listing. The
# section is counted, not guessed from FNR == NR, so the same file may be passed
# for two of them (a test does exactly that) and still be read correctly.
FNR == 1 { section++ }

section == 1 {
    line = $0
    sub(/#.*/, "", line)
    if (line ~ /^[ \t]*$/) next
    svc = trim($1)
    if (svc == "") next
    svc_seen[svc] = 0
    svc_call[++nsvc] = svc
    next
}
section == 2 {
    line = $0
    sub(/#.*/, "", line)
    if (line ~ /^[ \t]*$/) next
    proc = trim($1)
    if (proc == "") next
    off[proc] = 1
    off_list[++noff] = proc
    off_seen[proc] = 0
    next
}
section == 3 {
    line = $0
    sub(/#.*/, "", line)
    if (line ~ /^[ \t]*$/) next
    prefix = trim($1)
    if (prefix == "") next
    not_svc[prefix] = 1
    not_svc_list[++nnos] = prefix
    not_svc_seen[prefix] = 0
    next
}
section == 4 {
    line = $0
    sub(/#.*/, "", line)
    if (line ~ /^[ \t]*$/) next
    if (NF < 2) { report("MALFORMED", "listing line with no mode: " $0); next }
    proc = trim($1)
    mode = trim($2)
    if (mode != "keyed" && mode != "keyless") {
        report("MALFORMED", "mode must be keyed or keyless, got \"" mode "\" for " proc)
        next
    }
    listed[proc] = mode
    # One line PER ADVERTISEMENT, so a procedure served by six boxes arrives six
    # times. Every rule below is about the procedure, not the box: report it once.
    if (!(proc in seen_proc)) {
        seen_proc[proc] = 1
        listed_order[++nlines] = proc
    }
    if (mode == "keyless") keyless[proc] = 1
    if (proc in off) off_seen[proc] = 1
}

END {
    # Rule D first, so later rules can say "of the known services".
    for (i = 1; i <= nlines; i++) {
        proc = listed_order[i]
        best = ""
        for (j = 1; j <= nsvc; j++) {
            s = svc_call[j]
            if (index(proc, s) == 1 && length(s) > length(best)) best = s
        }
        if (best != "") {
            svc_seen[best]++
            owner[proc] = best
        } else {
            # Not a service. Allowed only where someone wrote down why, and the
            # prefix that answered is recorded so a written claim nothing answers
            # is a finding too (rule E).
            np = ""
            for (j = 1; j <= nnos; j++) {
                p = not_svc_list[j]
                if (index(proc, p) == 1 && length(p) > length(np)) np = p
            }
            if (np == "") {
                report("UNKNOWN", proc " belongs to no service in the services file")
            } else {
                not_svc_seen[np]++
            }
        }
    }

    # Rule A: clear by omission.
    for (i = 1; i <= nlines; i++) {
        proc = listed_order[i]
        if ((proc in keyless) && !(proc in off))
            report("NO-OFF", proc " is advertised keyless and has no written opt-out")
    }

    # Rule B: an opt-out nothing in the listing answers.
    for (i = 1; i <= noff; i++) {
        proc = off_list[i]
        if (!(proc in listed))
            report("STALE-OFF", proc " is on the opt-out list but was not advertised")
    }

    # Rule C: absence is a finding.
    for (j = 1; j <= nsvc; j++) {
        s = svc_call[j]
        if (svc_seen[s] == 0)
            report("ABSENT", s " is expected on the fleet and advertised nothing")
    }

    # Rule E: a written "this is not a service" that nothing answers. The same
    # discipline as a stale opt-out: a decision nobody re-read is how a list
    # drifts away from the fleet it claims to describe.
    for (j = 1; j <= nnos; j++) {
        p = not_svc_list[j]
        if (not_svc_seen[p] == 0)
            report("STALE-NOT-SERVICE", p " is declared not-a-service but matched nothing")
    }

    if (!quiet) {
        keyed = 0; clear = 0; clear_off = 0
        # Per PROCEDURE, not per line: a procedure advertised by several boxes
        # appears once per advertisement.
        for (p in listed) {
            # A procedure advertised BOTH ways -- mid-roll, keyed on one box and
            # keyless on another -- counts as keyless: it can still be read, and
            # the summary must not say the fleet is sealed while it can be.
            if (p in keyless) { clear++; if (p in off) clear_off++ }
            else { keyed++ }
        }
        printf "\n"
        printf "services expected   %d\n", nsvc
        printf "services seen       %d\n", nsvc - absent_count()
        printf "procedures listed   %d\n", nlines
        printf "  keyed             %d\n", keyed
        printf "  keyless           %d  (%d with a written opt-out)\n", clear, clear_off
        printf "written opt-outs    %d\n", noff
        printf "not-a-service prefs %d\n", nnos
    }

    if (findings > 0) {
        printf "\n%d finding(s)\n", findings
        exit 1
    }
    printf "\nno findings\n"
    exit 0
}

function absent_count(   j, n) {
    n = 0
    for (j = 1; j <= nsvc; j++) if (svc_seen[svc_call[j]] == 0) n++
    return n
}
' "$SERVICES" "$OPT_OUTS" "$NOT_SERVICES" "$LISTING"
