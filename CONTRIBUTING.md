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
  `{mcl_om, "~> 0.27"}` and implements the `mcl_om_service` behaviour.
  Scaffold one with `scripts/scaffold-service.sh`. Don't write a new
  "service runner": extend this one.

## Issues

https://github.com/macula-services/mcl-om/issues
