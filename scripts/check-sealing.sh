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
# SIX RULES, each a way the fleet can look fine while being wrong:
#   A  a keyless procedure with no matching opt-out   -> clear by omission. A
#      procedure under a declared not-a-service prefix is exempt: its claim is its
#      reason, and what this measurement moves is about service payloads.
#   B  an opt-out naming a procedure that never appeared -> a stale decision, or a
#      listing that missed the service, and neither may pass silently
#   C  a service in services.tsv absent from the listing -> absence is a FINDING.
#      A service that is down, booting or not advertising must not pass by being missing
#   D  a listed procedure that belongs to no known service and to no declared
#      not-a-service prefix -> an unmeasured service
#   E  a declared not-a-service prefix that matched nothing -> a written claim
#      about the fleet that the fleet no longer answers
#   F  a station in stations.tsv that the listing never names, or that contributed
#      nothing to it -> a hole in the measurement. A DHT read is answered from the
#      records ONE station holds, so a one-station listing is one replica set, and
#      an advertisement held only elsewhere would read as sealed (mcl-om#44 R1)
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
#                            [--not-services F] [--stations F] [--quiet]
#
# The listing is one line per advertisement, tab separated:
#
#   <procedure>	<keyed|keyless>
#
# produced by scripts/measure-sealing.escript, plus one `# station <label>
# advertisements=<n>' header per station that measurement read. Blank lines and lines
# starting with `#' are ignored in every file this script reads, EXCEPT those station
# headers, which are what rule F reads.
#
# ONE LINE PER ADVERTISEMENT, which means a procedure served by six boxes arrives
# six times, and a service mid-roll arrives keyed on some boxes and keyless on
# others. Every rule here is about the PROCEDURE, so a procedure is judged once --
# and a procedure seen keyless even once is keyless, because a caller can still
# reach that box.
#
# THE SECTIONS ARE MARKED, not inferred from file boundaries: a rule that counted
# files (`FNR == 1') never fires for an EMPTY file, so one 0-byte input shifted every
# section after it and the checker printed findings about the wrong file (mcl-om#44
# R3). The marked form cannot be missed, and a fixture with a 0-byte file holds it.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVICES="$SCRIPT_DIR/sealing/services.tsv"
OPT_OUTS="$SCRIPT_DIR/sealing/opt-outs.tsv"
NOT_SERVICES="$SCRIPT_DIR/sealing/not-services.tsv"
STATIONS="$SCRIPT_DIR/sealing/stations.tsv"
LISTING=""
QUIET=0

while [ $# -gt 0 ]; do
    case "$1" in
        --services)     SERVICES="$2"; shift 2 ;;
        --opt-outs)     OPT_OUTS="$2"; shift 2 ;;
        --not-services) NOT_SERVICES="$2"; shift 2 ;;
        --stations)     STATIONS="$2"; shift 2 ;;
        --quiet)        QUIET=1; shift ;;
        # The whole leading comment block, whatever it grows to: a fixed line range
        # silently cut the help in half the moment the header gained a rule.
        -h|--help)      awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' \
                            "${BASH_SOURCE[0]}"; exit 0 ;;
        *)              LISTING="$1"; shift ;;
    esac
done

for f in "$LISTING" "$SERVICES" "$OPT_OUTS" "$NOT_SERVICES" "$STATIONS"; do
    if [ ! -f "$f" ]; then
        echo "check-sealing: no such file: $f" >&2
        exit 2
    fi
done

{
    printf '@@section services\n';     cat "$SERVICES"
    printf '@@section opt-outs\n';     cat "$OPT_OUTS"
    printf '@@section not-services\n'; cat "$NOT_SERVICES"
    printf '@@section stations\n';     cat "$STATIONS"
    printf '@@section listing\n';      cat "$LISTING"
} | awk -F'\t' -v quiet="$QUIET" '
function trim(s) { gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
function report(tag, msg) { findings++; printf "%-8s %s\n", tag, msg }

# `# station <label> advertisements=<n>`, one per station the measurement read.
# A label here that the committed stations file does not name is not a finding by
# itself (a run may read more stations than the file lists); a label the file names
# that the listing never mentions, or one that says it contributed nothing, is.
function read_station_line(s,   label, count) {
    s = substr(s, length("# station ") + 1)
    label = s
    sub(/[ \t].*$/, "", label)
    count = s
    sub(/^.*advertisements=/, "", count)
    sub(/[^0-9].*$/, "", count)
    measured[label] = (count == "" ? 0 : count + 0)
}

# The sections are MARKED, not inferred from file boundaries: an empty file has no
# first line, so an FNR == 1 boundary never fires for it and the next section shifts by
# one -- which read a listing as the not-services file and reported the wrong
# findings (mcl-om#44 R3). A marker line cannot be missed, and the same file may be
# passed twice.
/^@@section / { section = $0; sub(/^@@section /, "", section); next }

section == "services" {
    line = $0
    sub(/#.*/, "", line)
    if (line ~ /^[ \t]*$/) next
    svc = trim($1)
    if (svc == "") next
    svc_seen[svc] = 0
    svc_call[++nsvc] = svc
    next
}
section == "opt-outs" {
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
section == "not-services" {
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
section == "stations" {
    line = $0
    sub(/#.*/, "", line)
    if (line ~ /^[ \t]*$/) next
    label = trim($1)
    if (label == "") next
    station_seen[label] = 0
    station_list[++nst] = label
    next
}
section == "listing" {
    # A station header line says how much of this listing came from that station.
    # It is read before the comment strip below, which throws comments away.
    if ($0 ~ /^# station /) { read_station_line($0); next }
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
    # One line PER ADVERTISEMENT, which means a procedure served by six boxes
    # arrives six times. Every rule below is about the procedure, not the box, so
    # a procedure is judged once -- and a procedure seen keyless even once is
    # keyless, because a caller can still reach that box.
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
            # Match on the FIRST PATH SEGMENT, not on a bare prefix: mcl-bookclub
            # is a prefix of mcl-bookclub-phoenix/info, and crediting that to
            # mcl-bookclub left the undeployed service neither UNKNOWN nor its
            # owner ABSENT (mcl-om#44 R2).
            if (index(proc, s "/") == 1 && length(s) > length(best)) best = s
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
                not_svc_owner[proc] = np
            }
        }
    }

    # Rule A: clear by omission. A procedure whose not-a-service claim is already
    # written down is not crying omission: the claim IS its reason, and the register
    # this measurement moves is about service payloads.
    for (i = 1; i <= nlines; i++) {
        proc = listed_order[i]
        if ((proc in keyless) && !(proc in off) && !(proc in not_svc_owner))
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

    # Rule F: the measurement must have read every station the fleet runs. A DHT
    # read answers from the records ONE station holds, so a listing taken from one
    # station describes one stations replica set -- and a keyless advertisement
    # held only on another station replicas never appears (mcl-om#44 R1). A station in
    # the committed list that the listing never mentions, or one that says it
    # contributed nothing, is a hole in the measurement, not a quiet zero.
    for (j = 1; j <= nst; j++) {
        label = station_list[j]
        if (!(label in measured))
            report("UNMEASURED", "station " label " is expected and the listing does not name it")
        else if (measured[label] + 0 == 0)
            report("UNMEASURED", "station " label " contributed no advertisement to this listing")
    }

    if (!quiet) {
        keyed = 0; clear = 0; clear_off = 0; clear_ns = 0
        # Per PROCEDURE, not per line: a procedure advertised by several boxes
        # appears once per advertisement.
        for (p in listed) {
            # A procedure advertised BOTH ways -- mid-roll, keyed on one box and
            # keyless on another -- counts as keyless: it can still be read, and
            # the summary must not say the fleet is sealed while it can be.
            if (p in keyless) {
                clear++
                if (p in off) clear_off++
                else if (p in not_svc_owner) clear_ns++
            }
            else { keyed++ }
        }
        printf "\n"
        printf "services expected   %d\n", nsvc
        printf "services seen       %d\n", nsvc - absent_count()
        printf "procedures listed   %d\n", nlines
        printf "  keyed             %d\n", keyed
        printf "  keyless           %d  (%d with a written opt-out, %d not a service)\n", clear, clear_off, clear_ns
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
}'
