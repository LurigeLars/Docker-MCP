# AIRSEA read-only aggregate inspection

## Decision and ownership

This is a **manual/on-demand inspection adapter**, not a new Market Engine
integration, monitor, alert source, Trade Spine signal, collector, or scheduled
job. AIRSEA-Monitor remains the data owner; DockerLocal supplies only the
existing Windows-host read bridge. A failed ChatGPT automation or one-off
reporting request is **not** a reason to add a recurring trading pipeline.

### Deliberate security boundary

The single MCP tool is `airsea_coverage_report()`, with **no parameters**.
It is exposed via the existing DockerLocal maintenance request/response runner
and is permitted only if the local host allowlist includes the
`MarketObservationPilotShadow` scheduled-task alias. It cannot start, stop,
restart, enable or migrate the pilot.

The installed `airsea-coverage-report.py` reads a **fixed local pilot database
location relative to the Windows user's LOCALAPPDATA**; callers cannot choose
a file, path, table, query, time range, vessel, MMSI or other selector.
It opens SQLite in `mode=ro` and `PRAGMA query_only=ON`.

Only explicit aggregate columns in `meta`, `day_stats`, and (when installed)
`ais_intake_day` are read. No raw positions, vessel-state, MMSI, hashes,
secrets, logs, exception messages, identities or absolute host paths are sent
to the MCP caller. The Python reader rejects unsupported schema versions.
The MCP server independently rebuilds the outgoing JSON from an explicit
field/type allowlist rather than forwarding raw host-runner results.

The response contains at most 14 recent aggregate UTC days, including:

- accepted AIS positions and static AIS messages;
- W/M/E aggregate messages and pseudonymous vessel counts;
- coarse observed transitions and tanker-type lower-bound transitions;
- AIS connected seconds/disconnects and provider snapshot/error counts;
- where instrumented, received AIS frames, accepted/rejected totals,
  fixed rejection categories, processing errors and accounting consistency;
- instrument start timestamps and explicit pre-instrumentation / partial
  first-day status.

A period without intake instrumentation returns `intake: null`, not
invented zeroes. AIS connection time is **not** full geographic data coverage.
Missing or low eastern-zone messages must **not** be interpreted as absent
physical traffic through Hormuz.

### Installation

Both the updated containerized DockerLocal server and the Windows host-side
Maintenance Runner must use this revision. A GitHub merge is NOT a live
deployment. The normal host installer now copies the fixed-purpose Python
reporter adjacent to `maintenance-runner.ps1` under DockerLocal's existing
per-user state directory, and restarts the dedicated Maintenance Runner.
This does not affect the existing AIRSEA task or database.

Run the existing reviewed DockerLocal release process, then validate that
`airsea_coverage_report` appears among the DockerLocal MCP tools. No new
local config entry is needed **if** the `MarketObservationPilotShadow`
scheduled-task alias is already allowlisted. If not, add that task through
DockerLocal's existing opt-in host-maintenance onboarding procedure. Never
add an arbitrary filesystem read action or extend the host runner to general
SQL execution.

### Safety validation

Synthetic tests in `tests/test_airsea_coverage_hardening.py` verify
no raw table data leak, aggregate value preservation, zero/unknown treatment,
schema gating, response whitelisting, malformed-response rejection, and the
host-side action allowlist. Windows CI must also parse the PowerShell runner,
run its self-test and pass existing hardening tests.

This adapter is *on demand only*. If a persistent Market Engine feature is
proposed later, first require independent coverage validation, incremental
decision usefulness, and explicit approval to add that dependency.
