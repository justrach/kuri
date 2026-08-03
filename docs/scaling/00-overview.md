# Scaling kuri into a managed service

This directory captures the design + first code for turning single-tenant `kuri`
into a managed, multi-tenant browser-automation service — the same product shape
as **Browser Use Cloud**, built on kuri's token-efficient Zig data plane.

## The reference model (browser-use Cloud)

browser-use shares kuri's core (CDP + accessibility-tree-to-LLM + an action
registry) and monetizes via a hosted product whose moving parts are:

| Capability | browser-use Cloud | kuri today | Track |
|---|---|---|---|
| Async task API (`POST /tasks` → poll/webhook) | ✅ | ❌ | **1** |
| One isolated browser per session (own process/socket/state) | ✅ | local only (one Chrome/process) | **1** |
| Session lifecycle + runtime caps + usage billing | ✅ (15m free → 4h paid, prorated) | ❌ | **1** |
| Persistent encrypted profiles (cookies/localStorage) | ✅ `profile_id` | ✅ `connect` vault, **key-isolated** | **2** |
| Per-tenant isolation of profiles | ✅ | ❌ (single vault) | **2** |
| Stealth / residential proxy / captcha | ✅ bundled | partial (`KURI_PROXY`, stealth.js) | roadmap |
| Live view + human takeover | ✅ `liveUrl` | building blocks (`/screencast`,`/ws`) | 1 (§3.1) |
| Token/cost accounting | ✅ `max_cost_usd` | telemetry shape exists | 1 (§7) |

## kuri's differentiated wedge

1. **Token efficiency as a billed SLA** — measurably cheaper per task than
   chrome-devtools-mcp / agent-browser. Make it the headline.
2. **Key-isolated credential vault** — the broker holds the key, the agent never
   does. Architecturally ahead of "a cloud folder of browser data" (Track 2).
3. **Single static binary** — trivial to pack into a microVM per session; no
   Node/Python cold-start tax that the reference product carries.
4. **MCP-native** — the managed service can be sold directly as a remote MCP
   endpoint.

## The three tracks

1. **[Control plane & async task API](01-control-plane.md)** — a `kuri-gateway`
   that spawns/leases/reaps one `kuri` worker (its own Chrome) per session,
   exposes `/v1/sessions` + `/v1/tasks`, and reverse-proxies the existing 200+
   endpoints scoped by session. *Status: worker-spawn + reverse-proxy wired
   (`src/gateway_main.zig`); verified live end-to-end (real Chrome per session,
   proxied snapshot, per-session isolation, clean teardown). Async task API + a
   background reaper still pending.*
2. **[Multi-tenant cloud profile store](02-cloud-profiles.md)** — namespace the
   `connect` vault by tenant with per-tenant keys. *Status: tenant-namespaced
   `connect_store` with path-traversal hardening + isolation test landed.*
3. **[CDP session-layer audit](03-cdp-audit.md)** — find the concurrency /
   lifetime / resource failure modes that bite under multi-tenant load before GA.
   *Status: audit run; findings in the doc.*

## Suggested build order

Phase 1 (this doc set) → wire worker spawn + reverse proxy in the gateway →
per-tenant key sourcing for profiles → isolation hardening (container/microVM per
session) → proxy/captcha/liveUrl parity → Windows + collapse the `vault.zig`
nanostore duplication before GA.
