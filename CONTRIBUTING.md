# Contributing

Trunk-based. Commit directly to `main`. No PRs.

## Build

```bash
rebar3 compile
rebar3 eunit
rebar3 ct
rebar3 lint
rebar3 dialyzer
```

## Style

- Erlang: `warnings_as_errors`, dialyzer clean
- Vertical slicing — no `services/`, no `helpers/`
- Every `macula-services/mcl-X` service depends on this library via
  `{mcl_om, "~> 1.5"}`, the floor the scaffold writes, and implements the
  `mcl_om_service` behaviour.
  Scaffold one with `scripts/scaffold-service.sh`. Don't write a new
  "service runner": extend this one.

## Releasing

Pushing a tag `vX.Y.Z` **is** the release. `.github/workflows/publish-hex.yml`
runs on the tag, checks that the checkout is the clean pushed tag, runs the
full suite on it, publishes the package and docs to hex.pm, and checks that
hex serves the tagged code. There is no manual publish step and no local
`rebar3 hex publish` in this repository's flow.

A version hex already serves is never re-pointed; a fix ships as the next
version. A tag that published nothing may move.

## Issues

https://github.com/macula-services/mcl-om/issues
