#!/bin/sh
# Seed a freshly created repository with the labels and the first issues the
# house expects of a service (mcl-om#55).
#
#   scripts/seed-repository.sh <org>/<repo>              # print the plan, create nothing
#   scripts/seed-repository.sh <org>/<repo> --file       # create it
#   scripts/seed-repository.sh <org>/<repo> --crew=a,b   # also seed crew:<member> labels
#
# WHY THIS IS NOT PART OF THE SCAFFOLD ITSELF. `rebar3 new' writes files and
# cannot know the repository exists: it is created after, by a human, because
# who owns it and whether it is public is a decision, not a default. So the
# scaffold prints this command and the human runs it once the repository is
# there.
#
# DRY BY DEFAULT. What is created should be readable before it is created, and
# a plan that is printed rather than applied is also what makes it testable:
# mcl_service_template_SUITE runs this with a stand-in `gh' on PATH and asserts
# on what it would have done.
#
# NOTHING HOUSE-SPECIFIC GOES IN A BODY. These issues are created in a
# repository that may be public, and its readers are not us: no box names, no
# home paths, no node ids, no internal repository names. The bodies say what a
# service owes its readers, wherever it is deployed.
#
# CREW LABELS ARE NAMED, NEVER GUESSED. A `crew:<member>' label is created for a
# member named with --crew, or MCL_CREW=a,b; with none, none are made. Members
# come and go, and a scaffold that invented them would leave a repository full
# of labels naming people who never touch it.
set -eu

usage() {
    cat >&2 <<'USAGE'
usage: seed-repository.sh <org>/<repo> [--file] [--crew=member,member]

  --file           create the labels and issues; without it, print the plan
  --crew=a,b       also create a label per named crew member

Requires `gh', authenticated for <org>/<repo>. Run it after `gh repo create'.
USAGE
    exit 64
}

REPO=""
FILE=0
CREW="${MCL_CREW:-}"

for arg in "$@"; do
    case "$arg" in
        --file)   FILE=1 ;;
        --crew=*) CREW="${arg#--crew=}" ;;
        -h|--help) usage ;;
        -*)
            echo "seed-repository.sh: unknown option '$arg'" >&2
            usage
            ;;
        *)
            [ -z "$REPO" ] || { echo "seed-repository.sh: one repository at a time" >&2; usage; }
            REPO="$arg" ;;
    esac
done

[ -n "$REPO" ] || usage
case "$REPO" in
    */*) ;;
    *) echo "seed-repository.sh: '$REPO' is not <org>/<repo>" >&2; exit 64 ;;
esac

# THE WORKFLOW LABELS THE ORG USES. Same words and colours as the services
# carry, so a member moved between repositories finds the same vocabulary.
LABELS="plan|C5DEF5|A plan the team means to act on
backlog|FBCA04|Queued work, not yet cut as a package
proposal|BFD4F2|An idea, not approved
work-package|1D76DB|Assigned work package
design|1d76db|A design decision or note"

emit() { printf '%s\n' "$*"; }

label() {
    name="$1"; colour="$2"; description="$3"
    if [ "$FILE" = 1 ]; then
        # --force makes it idempotent: an existing label is updated, not an
        # error, so running this twice is safe.
        # </dev/null: this runs inside a `while read' over the label list, and a
        # command that reads stdin would eat the labels still to come.
        gh label create "$name" --repo "$REPO" --color "$colour" \
            --description "$description" --force </dev/null >/dev/null
    else
        emit "label  $name  #$colour  $description"
    fi
}

crew_labels() {
    [ -n "$CREW" ] || return 0
    # The trailing newline is what makes `read' see the LAST name: without it,
    # read answers failure at EOF and the final member is silently skipped.
    printf '%s\n' "$CREW" | tr ',' '\n' | while IFS= read -r member; do
        [ -n "$member" ] || continue
        label "crew:$member" "5319E7" "Crew member $member"
    done
}

issue() {
    title="$1"; body="$2"
    if [ "$FILE" = 1 ]; then
        # A RERUN MUST NOT FILE EVERYTHING TWICE. A run that stopped on the
        # third issue -- a network blip, a rate limit -- is finished by running
        # this again, and the two already created are not duplicated: their
        # titles are read back first and skipped, out loud, so a short run is
        # never mistaken for one that changed nothing.
        if printf '%s\n' "$EXISTING" | grep -Fxq "$title"; then
            echo "skip   $title — already filed in $REPO"
            return 0
        fi
        "$body" | gh issue create --repo "$REPO" --title "$title" --label plan \
            --body-file - >/dev/null
    else
        emit "issue  $title  [plan]"
        "$body" | sed 's/^/       | /'
        emit ""
    fi
}

# One listing rather than a search per issue: the titles are read once, before
# anything is created, and an empty answer is not a failure -- a repository
# with no issues has none to skip.
existing_titles() {
    gh issue list --repo "$REPO" --state all --limit 200 --json title \
        --jq '.[].title' </dev/null 2>/dev/null || true
}

# WHY (capability) AND NOT (upkeep): the reader this is written for is whoever
# opens the repository next, and what they can do afterwards is decide what the
# service talks to before there is code to read.
body_c4() {
    cat <<'BODY'
Purpose (capability): whoever picks this service up can see what it talks to and
what it is made of before there is code to read, so the boundary is a decision
someone wrote down rather than something discovered from the source.

`architecture/README.md` describes the service's context and its components. It
owes two diagrams in `assets/`, a context one and a components one, drawn from
this service's own design rather than from the template.

Nothing in the model is implementation detail: the context diagram names the
other services and systems this one talks to and what it asks them for, and the
components diagram names the pieces inside it and what each holds.

Done when `assets/c4-context.svg` and `assets/c4-components.svg` exist and both
`README.md` and `architecture/README.md` show them.
BODY
}

body_readme() {
    cat <<'BODY'
Purpose (usability): someone arriving at this repository can tell what the
service does, how to run it, and who to contact, without asking anyone.

The README head is already the house template — badge row, this service's own
logo in `assets/`, and its one-line description. What this issue is for is the
part only this service can write: what it does, what it does not do yet, and
the vocabulary a reader needs (the desks it runs, the read models it keeps).

Keep the sections that exist; fill them in rather than replacing them. The
status section is the one to be strict about: it should say what is built and
what is not, and nothing in it should be aspirational.

Done when a reader who has never seen this service can answer "what does it do
and how do I run it" from the README alone.
BODY
}

body_skeleton() {
    cat <<'BODY'
Purpose (capability): the service is built, published, deployed and can record
one thing end to end, before any feature is designed — so the first feature is
written into a working skeleton instead of being the thing that proves it.

Three parts, in this order.

1. **CI/CD operational.** The generated workflows already lint, test, assemble
   the release and publish an image on a tag. What is missing is the first run
   against this repository: the toolchain check passing, the package public if
   this repository is, and a `v0.1.0` that produces an image someone else can
   pull.

2. **A deployment entry that is pinned.** Wherever this service is deployed,
   the image is named by digest, not by a moving tag, and that pin is checked:
   a line in the deployment descriptor that fails when the digest it names no
   longer resolves. A service that deploys by tag cannot say what it is running.

3. **The first two desks.** `initiate_<subject>` and `archive_<subject>` in the
   CMD container: one records that something began and answers with its event,
   the other that it ended. The smallest honest pair, not a feature — what they
   record can be thrown away when the first real capability lands.

Done when a change goes through CI, a tagged version publishes an image, the
deployment descriptor names it by digest, and a round trip through the two
desks passes a test.
BODY
}

body_release() {
    cat <<'BODY'
Purpose (reliability): there is a version other people can pin, and it carries
the walking skeleton rather than a promise.

Cut `v0.1.0` on the commit where the walking skeleton is complete: CI green,
an image published by digest, the deployment entry pinned, and the two desks
round-tripping in a test.

What a first release owes a reader:

- a CHANGELOG entry saying what the skeleton is, and what this version does not
  do yet;
- the image's digest recorded where it is deployed;
- no tag cut off a red tree: CI runs on the tagged commit and the tag is the
  release only if it passes.

Done when the tag exists, the published image is pinned where the service runs,
and this issue is closed with the tag and the digest in it.
BODY
}

[ "$FILE" = 1 ] || emit "# seed $REPO — nothing is created without --file"

printf '%s\n' "$LABELS" | while IFS='|' read -r name colour description; do
    label "$name" "$colour" "$description"
done
crew_labels

[ "$FILE" = 1 ] || emit ""

EXISTING=""
if [ "$FILE" = 1 ]; then
    EXISTING=$(existing_titles)
fi

issue "Model the service in C4 before writing it" body_c4
issue "Bring the README up to the house template, with the service's own logo" body_readme
issue "Stand up the walking skeleton: CI, a pinned deployment entry, and the first two desks" body_skeleton
issue "Release v0.1.0" body_release

[ "$FILE" = 0 ] && emit "# run again with --file to create these in $REPO"
exit 0
