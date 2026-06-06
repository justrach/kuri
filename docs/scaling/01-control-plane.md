# Track 1 — Control Plane & Async Task API

> Turning single-tenant `kuri` into a managed, multi-session service.
> Status: **gateway spawn + reverse-proxy implemented** in `src/gateway_main.zig`
> (verified live); async task API (sec 5) and background reaper still pending.

## 1. The constraint that shapes everything

`kuri` today is **one process = one `Bridge` = one Chrome**:

- `src/main.zig:103` builds a single `Bridge` (central state).
- `src/main.zig:83` launches/attaches exactly one Chrome via `chrome.Launcher`.
- The HTTP server (`src/server/router.zig`) serves the whole process; auth is one
  bearer token (`api_token.ensure`, `src/main.zig:71`).
- There *is* a lightweight session concept already: `getSessionId` (`router.zig:473`)
  reads an `X-Kuri-Session` header and maps it to a *current tab* inside the one
  browser. This is **tab multiplexing, not isolation** — every session shares the
  same Chrome, cookies, and memory.

This is exactly browser-use's local model (one `BrowserSession` per daemon), and
their Cloud scales it the same way we should: **isolation = a separate browser per
tenant session.** We do not rewrite the bridge to host N Chromes in one process
(huge blast radius, shared crash domain). Instead a thin **gateway** spawns and
leases N `kuri` worker processes, each owning one Chrome on an ephemeral port.

```
                 ┌──────────────────────────────────────────┐
   client ─────► │  kuri-gateway   (control plane, public)   │
   (task API)    │  - tenant auth + quota + rate limit       │
                 │  - session table (lease/spawn/reap)       │
                 │  - task queue + async executor            │
                 │  - reverse-proxy of the 200+ data-plane   │
                 │    endpoints, scoped by session_id        │
                 └───────┬───────────────┬───────────────────┘
                         │ spawn          │ spawn
                ┌────────▼──────┐  ┌──────▼────────┐   one Chrome each,
                │ kuri worker   │  │ kuri worker   │   ephemeral 127.0.0.1:PORT,
                │  +Chrome  #1  │  │  +Chrome  #2  │   per-worker api.token
                └───────────────┘  └───────────────┘
```

Everything the data plane already does (snapshot, action, har, screencast, …)
stays in the worker untouched. The gateway adds the three things a managed
service needs that a single binary cannot: **multi-tenancy, lifecycle, and async
jobs.**

## 2. New binary: `kuri-gateway`

A sibling executable (like `kuri-connect-broker`) so the worker binary stays lean
and the crash domains are separate. Reuses the existing HTTP idiom from
`connect_broker.zig` (`std.Io.net` + `std.http.Server`).

Responsibilities:

1. **Tenant auth** — bearer API keys scoped to a tenant (not the worker's
   per-process token). Maps `Authorization: Bearer sk_live_…` → `tenant_id`.
2. **Session manager** — allocate/lease/reap worker processes (§4).
3. **Task executor** — async job model over the worker data plane (§5).
4. **Reverse proxy** — forward `/v1/sessions/:id/*` to the right worker, injecting
   the worker's own bearer token so callers never see it (§6).
5. **Quota + metering** — per-tenant concurrency cap, session runtime cap, usage
   events (feeds billing; reuse `telemetry.zig`'s event shape, §7).

## 3. Public API (v1)

Base URL `https://api.<host>/v1`. All requests require `Authorization: Bearer <api-key>`.

### 3.1 Sessions (explicit browser lifecycle)

```
POST   /v1/sessions                 → { session_id, live_url, expires_at, ws_proxy }
GET    /v1/sessions/:id             → { status, created_at, expires_at, last_used }
DELETE /v1/sessions/:id             → { stopped:true, billed_ms }
GET    /v1/sessions                 → { sessions:[...] }   (tenant-scoped)
ANY    /v1/sessions/:id/<data-path> → proxied to worker (the existing 200+ routes)
```

`POST /v1/sessions` body (all optional):

```jsonc
{
  "headless": true,
  "profile_id": "prof_abc",     // Track 2: load encrypted cloud profile on boot
  "proxy_country": "us",        // residential proxy selection (Track 3 of roadmap)
  "ttl_seconds": 900,           // capped by plan: free 900, paid up to 14400
  "stealth": true,
  "viewport": { "width": 1280, "height": 800 }
}
```

`session_id` is opaque (e.g. `sess_<base32(rand128)>`). `live_url` is a gateway URL
that screencasts the worker (wraps the existing `/screencast/start` +
`/ws/start`, `router.zig:3579`, `router.zig:5663`) for live view + human takeover.

### 3.2 Tasks (async agent jobs — the headline product)

A task is "run this browser workflow and tell me when it's done." Mirrors
browser-use Cloud's `POST /tasks` → poll/`webhook` model.

```
POST /v1/tasks            → { task_id, session_id, status:"queued", live_url }
GET  /v1/tasks/:id        → full record (below)
GET  /v1/tasks/:id/status → { status, step, cost_usd } (cheap poll)
POST /v1/tasks/:id/stop   → { stopped:true }
GET  /v1/tasks            → tenant-scoped list, paginated
```

`POST /v1/tasks` body:

```jsonc
{
  "steps": [ /* array of data-plane calls — same JSON as POST /batch */ ],
  "session": { "profile_id": "prof_abc", "headless": true },  // or "session_id" to reuse
  "output_schema": { /* optional JSON Schema for structured extraction */ },
  "max_cost_usd": 0.50,        // hard ceiling; abort when exceeded
  "webhook_url": "https://...", // POSTed on terminal state
  "idempotency_key": "..."      // dedupe retried submissions
}
```

Status lifecycle: `queued → running → (succeeded | failed | stopped | expired)`.

Task record:

```jsonc
{
  "task_id": "task_…", "session_id": "sess_…",
  "status": "succeeded",
  "steps_total": 7, "steps_done": 7,
  "result": { /* last step output, or output_schema-validated object */ },
  "error": null,
  "started_at": "...", "finished_at": "...",
  "usage": { "wall_ms": 8423, "steps": 7, "cost_usd": 0.012 },
  "live_url": "https://…", "replay_url": "https://…/replay"
}
```

The executor is intentionally a thin loop over the worker's existing `/batch`
(`router.zig:5826`) and `/recording/export` (`router.zig:8051`) — those already do
multi-command execution and produce replayable JSON. **No new automation engine.**
The LLM-driven variant (free-text prompt → steps) is a later layer; v1 ships the
deterministic `steps[]` executor first because it needs zero model integration and
is fully testable.

### 3.3 Why both sessions *and* tasks

- **Sessions** = low-level, stateful, interactive (the SDK use case; you drive it).
- **Tasks** = high-level, fire-and-forget, async (the API product; we drive it).

Tasks are implemented *on top of* sessions: a task leases a session, runs steps,
releases (or keeps it warm if `session_id` was supplied).

## 4. Session manager (the core of the gateway)

In-memory table, one entry per live worker:

```zig
const Session = struct {
    id: [24]u8,           // sess_… (opaque)
    tenant: []const u8,
    pid: std.process.Child.Id,
    port: u16,            // worker HTTP port on 127.0.0.1
    worker_token: [43]u8, // the worker's own bearer token (never leaves gateway)
    created_ms: i64,
    last_used_ms: i64,    // for idle reap
    expires_ms: i64,      // hard TTL (plan cap)
    state: enum { booting, ready, draining, dead },
};
```

Lifecycle:

1. **Allocate** — pick a free 127.0.0.1 port (mirror `launcher.findFreePort`,
   `launcher.zig:461`). Generate a per-worker bearer token.
2. **Spawn** — `std.process.Child` exec of `kuri` with env:
   `PORT=<port> HOST=127.0.0.1 HEADLESS=true KURI_API_TOKEN=<worker_token>
    STATE_DIR=<per-session scratch> KURI_NO_TELEMETRY=1`
   (worker telemetry off; the *gateway* emits the billable events).
3. **Readiness** — poll `GET http://127.0.0.1:<port>/health` (`router.zig:576`)
   until 200 or boot-timeout (kill + retry once, then fail the request).
4. **Reap** — a background sweeper thread closes workers whose
   `now > expires_ms` (hard cap) or `now - last_used_ms > idle_grace`. SIGTERM the
   child; the worker's own `lifecycle.install` (`main.zig:89`) already tears down
   Chrome cleanly on signal. Compute `billed_ms` on reap.

Isolation knobs (defense in depth, layered as the service hardens):

- **v1**: separate process + separate Chrome user-data-dir per session
  (`STATE_DIR` scratch), `127.0.0.1`-only worker bind, gateway is the only
  reachable surface.
- **v2**: each worker in its own container/cgroup (mem + CPU caps, seccomp).
- **v3**: microVM (Firecracker/gVisor) per session for untrusted multi-tenant —
  the static `kuri` binary makes this image trivially small (no Node/Python).

## 5. Task executor

Per task (runs on a small worker pool of gateway threads):

```
lease session (reuse or spawn)
  → for each step in steps[]:
        proxy step to worker  (same JSON the data plane already accepts)
        accumulate usage; if cost_usd > max_cost_usd → abort(failed)
  → if output_schema: validate last result, coerce/repair once
  → persist task record (status, result, usage)
  → fire webhook_url if set
  → release session (or keep warm if caller passed session_id)
```

Steps are literally a `POST /batch` payload, so the executor can hand the whole
`steps[]` array to the worker in **one** call and stream partial results — the
worker already returns an array result (`handleBatch`, `router.zig:5826`). That
keeps the gateway thin and the hot path inside the optimized Zig data plane.

## 6. Reverse proxy for the data plane

`ANY /v1/sessions/:id/<rest>`:

1. Look up session → `{port, worker_token}`; 404 if unknown, 403 if wrong tenant.
2. Rebuild request to `http://127.0.0.1:<port>/<rest>` with
   `Authorization: Bearer <worker_token>` and the original body/query.
3. Stream the response back; bump `last_used_ms`.

This means the **entire existing 200+ endpoint surface is instantly available
through the managed API** with zero per-endpoint work — the gateway is path-
agnostic. Only `/health`, `/v1/sessions`, `/v1/tasks` are gateway-native.

## 7. Metering & quota

Reuse the telemetry event shape (`telemetry.zig`) but tag with `tenant` +
`session_id` and route to a billing sink instead of the anonymous endpoint:

- per-request: route, status, latency, bytes (already captured).
- per-session: `wall_ms` from spawn→reap → the billable unit (browser-minutes),
  with proportional refund on early `DELETE` (matches browser-use's model).
- per-task: steps + derived `cost_usd`.

Quota enforced at session allocation: reject `POST /v1/sessions` /`/v1/tasks` with
`429` when the tenant is at its concurrency cap; reject with `402` when over plan.

## 8. What lands in code now vs later

| Piece | Now (scaffold) | Later |
|---|---|---|
| `kuri-gateway` binary + build wiring | ✅ done | — |
| Session table + spawn/health | ✅ fork+exec worker, `/health` readiness poll | background idle/TTL reaper |
| Reverse proxy | ✅ Content-Length-aware proxy, per-session bearer + isolation | chunked/streaming endpoints (`/screencast`) |
| Task executor | record + status store | webhook, schema validate, cost abort |
| Tenant auth/quota | single static key | key store + plans |
| Live view / replay | URL shape | screencast bridge |

## 9. Open decisions (need product input)

1. **Worker reuse**: keep sessions warm between tasks (faster, costs idle browser-
   minutes) vs cold per task (cheaper, ~1–2s boot)? Suggest: warm pool of N per
   tenant tier.
2. **Persistence**: task records in-memory (lost on gateway restart) vs a small
   embedded store. Suggest: start with nanostore-backed append log, reuse the
   crypto we already own.
3. **LLM step generation**: build the prompt→steps planner in-gateway, or keep the
   gateway deterministic and let `kuri-mcp` clients do planning? Suggest:
   deterministic v1, planner as a separate opt-in service.

## 10. Session groups — many browser sessions per agent run

A single agent/task run often needs to drive **N browsers at once** — scrape 50
product pages, fill the same form across 10 tenants' accounts, A/B two flows side
by side. The gateway models this as a **session group** layered on the same
spawn/lease/reap machinery; no new browser plumbing.

API:

```
POST /v1/tasks
{
  "fanout": {
    "over": ["https://a", "https://b", ...],   // or N identical sessions
    "max_concurrency": 8,                        // gateway caps actual parallelism
    "session": { "profile_id": "...", "headless": true }
  },
  "steps": [ /* applied to EACH session, item bound to a placeholder */ ],
  "output_schema": { ... }                        // result is an array, one per item
}
→ { task_id, group_id, sessions:[{session_id, item}], live_urls:[...] }
```

Execution mirrors the workflow `pipeline()` pattern already used elsewhere in this
repo: the gateway leases up to `max_concurrency` workers (one Chrome each — full
isolation between items), runs the `steps[]` per item, and aggregates results into
an ordered array. Back-pressure is the lease pool: items queue when the tenant's
concurrency cap is reached, exactly like §4/§7.

Why this stays clean:
- **Isolation is free** — each item is its own worker process + Chrome, so one
  item's crash/captcha/cookie state never bleeds into another. This is the same
  property that makes the per-tenant model safe (Track 2), reused per-item.
- **Billing is additive** — group cost = sum of member session browser-minutes;
  the metering in §7 already counts per session.
- **Live view scales** — `live_urls[]` lets a human watch/!take over any one
  member mid-run.

Relationship to the data plane: a group member is just a session, so the full
200+ endpoint surface works per member via the §6 reverse proxy
(`/v1/sessions/:member_id/...`). The group is an orchestration convenience, not a
new execution engine.

> Caveat that ties to Track 3: driving many sessions concurrently from one run
> hammers the worker's thread-per-connection model. The §1 concurrency fixes in
> the CDP audit (lock discipline around the shared `Bridge`) are prerequisites for
> a single worker to safely serve a member's concurrent requests; cross-member
> isolation is already guaranteed by the one-Chrome-per-worker boundary.
