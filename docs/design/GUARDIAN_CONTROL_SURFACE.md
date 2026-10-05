# The guardian control surface: `get_limits`, `set_limits` and `denials_observed`

This exists so one guardian (mcl-sec-guard) reads and retunes the inbound limits of every
mcl_om service through one gated, audited interface, and so no service invents a second one.

Shipped in mcl_om 0.37.1 (`mcl_om_guard`, `mcl_om_guard_limits`, `mcl_om_guard_control`,
`mcl_om_guard_pipeline`). Decided by Raf, 2026-10-04: one control surface; the guardian tier
gates `set_limits`; humans change limits and the envelope through deploy config and the
service's own admin surface, and there is no operator mesh capability. The guardian that
consumes this lives in macula-services/mcl-sec-guard.

## The inbound guard

Every response-kind capability advertised through `mcl_om_capabilities` flows through
`mcl_om_guard_pipeline`: a payload-size stage, a fixed-window rate stage, then the handler.
A capability overrides the limits with a `limits` key, adds per-key min/max clamps with an
`envelope`, or opts out with `guard => none`. Streamers are unaffected.

| Key | Default | Meaning |
|---|---|---|
| `max_payload_external_size` | 65536 | bytes of an inbound payload |
| `window_ms` | 10000 | the fixed window's length |
| `per_caller_max` | 600 | calls per caller per window |
| `global_max` | 6000 | calls from everyone per window |
| `max_distinct_callers` | 1024 | distinct callers per window |

`per_caller_max` must not exceed `global_max`. Windows are keyed by their start on the wall
clock (`(Now div window_ms) * window_ms`), so starts can be compared across services. Old
windows are swept once they are older than three times the largest `window_ms` in use.

## Alert facts: services to the guardian

Sensing is push. On a timer (`inbound_guard.alert_tick_ms`, default 10 s) each service walks
its declared procedures and publishes one fact per procedure per **new** window, and only
when that window saw a denial or a caller over its limit. A quiet service publishes nothing,
so it cannot be used as a fact amplifier, and a flood of denials collapses into one fact per
window.

- **Topic:** `denials_observed` by default (`inbound_guard.alert_topic`). The procedure rides
  in the payload, never in the topic.
- **Payload** (binaries and numbers only, no booleans):

  `#{procedure, window_start_ms, denied_rate, denied_size, callers_over_limit,
     global_count, global_max, per_caller_max, distinct_callers, top_callers}`

  `top_callers` is a list of `#{caller, count}` maps, at most 10, heaviest first, each caller
  hex-encoded (node ids are arbitrary bytes; the wire carries text as UTF-8).

## The pair

Every service exposes both names in its org namespace; a service that declares either name
itself is refused at start.

- **`<org>/get_limits`**, `auth => open`: public facts, nothing secret or caller-private
  beyond the hex ids in `top_callers`. Payload: none, or `#{procedure => P}`. Reply: that
  procedure's stats, or `#{procedures => #{P => Stats}}` for every declared one. Stats
  (`mcl_om_guard:stats/1`): `limits`, `envelope`, `global_max`, `current_window`,
  `global_count`, `distinct_callers`, `callers_over_limit`, `top_callers`, `denied_rate`,
  `denied_size`, and `audit` (the recent applied changes).
- **`<org>/set_limits`**, `auth => {realm_member_required, RealmDid, GuardianTier}`.
  Advertised only when `{mcl_om, inbound_guard, #{guardian => #{realm_did,
  guardian_tier}}}` names the realm's 32-byte key and the tier; without it the service logs
  once and no gated surface exists on the wire. Payload: `#{procedure => P, limits =>
  Overrides}`. Reply: `{ok, #{limits, envelope}}` with the effective values, or
  `{error, Reason}`.

## Semantics of a set

- A partial merge of `Overrides` over the effective limits, validated whole before it is
  applied; a refused set changes nothing.
- Refusals: `bad_payload`, `bad_procedure`, `bad_limits`, `{unknown_procedure, P}`,
  `{unknown_key, K}`, `{not_a_positive_integer, K, V}`,
  `{per_caller_above_global, PerCaller, Global}`, `{envelope_exceeded, K, V}`.
- **Envelope.** Every key a guardian-tier set changes must lie inside that key's
  `#{min, max}`; a key the envelope does not cover cannot be moved by the guardian at all
  (no envelope, no movement). The envelope itself is deploy config, never settable over the
  mesh.
- A service's republish tick re-declares its base limits without undoing the overrides a
  guardian set; overrides live in `persistent_term`, so they hold while the node runs.
- The apply path is the same for the guardian as for any caller of `mcl_om_guard_limits`.
  `set_limits` is itself a guarded capability: the guardian pays the default rate budget like
  every caller.

## Audit

Every **applied** change lands on the guard's audit ring (32 entries per procedure) and in
the log: tier, caller, before and after. An unchanged set is a no-op and gets no entry. The
ring is a readable trail, not the tamper-evident event stream the security register's
"Security audit log" row still owes.

## Not built here

- A service-side minimum interval between applies per (caller, service). Today the only
  bound on a guardian's apply rate is the capability's own rate limit.
- Station limits: macula-station's call bounds and rate limits, meant to expose the same
  pair under the same names.

Both are tracked with the guardian's plan in mcl-sec-guard.
