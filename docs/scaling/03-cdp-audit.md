# Track 3 — CDP Session-Layer Audit (multi-tenant readiness)

> Adversarial audit of the CDP session layer before exposing kuri as a managed,
> multi-tenant service. Method: 5 parallel finder agents (one per failure-mode
> dimension) over `cdp/client.zig`, `cdp/websocket.zig`, `cdp/har.zig`,
> `cdp/protocol.zig`, `bridge/bridge.zig`; **every finding was independently
> re-verified against the code** by a second agent. Result: **28 confirmed,
> 9 rejected** (37 examined). Status: findings below — confirm at the cited
> `file:line` before acting; these were surfaced by LLM agents and the line
> numbers reflect the working tree at audit time.

## 0. The fact that reframes everything: the server is multi-threaded

`server/router.zig:36` spawns a **detached `std.Thread` per connection**, and all
handler threads share **one `Bridge`** (`router.zig:81`). So concurrency is not a
future multi-tenant concern — it is the **current** execution model. The Bridge
guards its maps with `compat.PthreadRwLock` (`mu`), but the audit found paths that
read/write shared state *outside* that lock, plus pointers that escape the lock.

Two mitigations to keep in mind when reading severities:
- **Per-process browser isolation (Track 1 gateway):** one Chrome per *worker
  process* per session means cross-**tenant** leakage claims do **not** hold — a
  worker only ever holds one tenant's browser. The concurrency bugs instead bite a
  single tenant's own concurrent requests (still real, still crash-class).
- The verifier already walked back the worst over-claims (see §6 rejected).

## 1. Concurrency / shared-state — highest priority (live today)

| Sev | Finding | Location |
|---|---|---|
| HIGH | `setCdpAddress` writes `cdp_host`/`cdp_port` **without** `mu`, while `refreshTabWsUrl` reads them under `mu` → asymmetric data race; a torn read connects to the wrong CDP port. | `bridge.zig:322-325` / `:370-374` |
| HIGH | `global_single_threaded` I/O singleton used from many handler threads, including blocking socket reads inside `refreshTabWsUrl`. Concurrent use of a single-threaded io context is undefined. | `bridge.zig:375`, `router.zig:21/46` |
| MED | **Pointer escape / use-after-free:** `getCdpClient` returns a pointer to a map-resident `CdpClient`, then releases `mu`; another thread's `removeTab` can `destroy` it before the caller uses it. | `bridge.zig:330-365` |
| MED | `Bridge.deinit` iterates all 7 maps **without** `mu` while handler threads may still be live (shutdown race → UAF/double-free). | `bridge.zig:79-131` |
| MED | `RefCache` mutated under `mu` by `handleSnapshot` but `deinit`/`clear` touch it unlocked; `clear` uses an iterate-then-`clearRetainingCapacity` pattern. | `bridge.zig:24-48` |
| MED | Lock held across blocking I/O: `getCdpClient` holds `mu` while `refreshTabWsUrl` does a blocking `/json/list` fetch — serializes *all* tabs behind one slow HTTP call (2s+ stalls, cascading timeouts). | `bridge.zig` (getCdpClient→refreshTabWsUrl) |

**Direction:** make `setCdpAddress` take `mu`; never return a bare `*CdpClient`
that outlives the lock (return a refcount/handle, or copy what's needed under
lock); don't hold `mu` across network I/O (snapshot the address under lock, fetch
unlocked, re-acquire to store); quiesce handler threads before `deinit`; give each
worker its **own** io context rather than the process-global single-threaded one.

## 2. Client lifecycle / reconnect

| Sev | Finding | Location |
|---|---|---|
| HIGH | Stale `ws_url` accepted: `refreshTabWsUrl` has ~6 silent failure paths; the `ws_url.len == 0` guard still lets a **non-empty-but-stale** URL through → every `send` fails → client marked dead → recreated → same stale URL → **tight reconnect loop** (CPU/mem churn) on renderer swaps. | `bridge.zig:348-351`, `:376-403` |
| MED | Dead-client recycle loses buffered events: destroying a dead client drains its `event_buf`; a concurrent waiter for the same tab can lose its target event and hang. (Mitigated somewhat by destroy-and-recreate, but waiters aren't migrated.) | `client.zig` + `bridge.zig:335,353-364` |
| MED | `connectWs` does **not** `drain` `event_buf` before connecting — dormant today (clients are destroyed not reused), but a latent footgun if pooling/reuse is ever added. | `client.zig:120-134` |
| MED | `next_id` (u32) reuse across reconnects can collide with a still-buffered response id. Practically only at extreme sustained volume, but real; pair ids with a connection epoch. | `client.zig` |

## 3. WebSocket framing / protocol robustness

| Sev | Finding | Location |
|---|---|---|
| HIGH | Handshake validated by **substring search**, not real header parsing — a 101 response containing the literal `websocket` anywhere passes even without proper `Upgrade`/`Connection` headers. Parse headers and check `Upgrade: websocket` + `Connection: Upgrade` (case-insensitive). | `websocket.zig` |
| MED | `readFrame`/`readFrameAlloc` recurse on ping/pong/control frames with **no depth limit** → a stream of control frames can exhaust the stack. Convert to an iterative loop. | `websocket.zig:322,326,335,393` |
| MED | No RFC 6455 §5.2 enforcement that control frames are ≤125 bytes; a crafted control length can make `readExact` block for the full 10s socket timeout (per-frame stall). | `websocket.zig` |
| MED | FIN bit never checked — control frames with `FIN=0` are accepted (must be `FIN=1`), risking parser desync. | `websocket.zig` |

> Note: the u64→usize length casts the finders worried about are **already
> guarded** (`> std.math.maxInt(usize)` checks) — verifier rejected those (§6).

## 4. Memory lifetime / leaks under churn

| Sev | Finding | Location |
|---|---|---|
| HIGH | `har.zig` `deinit` frees `PendingRequest` entries but **not** their `headers_json`/`post_data` — requests that never get a response leak on teardown (compounds across session cycling). | `har.zig:319-324` |
| HIGH | `handleCdpEvent` uses `catch ""` on header/post_data dupes — masks OOM and can orphan partial allocations; mirror `addEntry`'s per-step `errdefer`. | `har.zig:204-207` |
| MED | `snapshots` map uses `getPtr`+`remove` instead of `fetchRemove`, so the `tab_id` **key** string isn't freed on `removeTab` (per-tab ~16-32 byte leak; every other map uses `fetchRemove`). | `bridge.zig` removeTab |
| MED | `HarRecorder.toJson` lacks `errdefer` on the build buffer — partial allocations orphaned if `appendSlice`/`toOwnedSlice` fails under memory pressure. | `har.zig:137-165` |

## 5. Resource exhaustion / DoS / quotas

| Sev | Finding | Location |
|---|---|---|
| HIGH | **No per-session/per-tenant resource quota.** All sessions share one GPA; `receiveMessageAlloc` allows 2MB/msg and `EventBuffer` holds 256×~2MB. One tenant opening many tabs / flooding events can exhaust server memory. | `client.zig` |
| HIGH | `pending_requests` HashMap grows **unbounded** when `responseReceived` never arrives (timeouts, crashes, malicious pages) — no expiry / high-water mark. | `har.zig` |
| HIGH | Single-threaded CDP read loop holds the client mutex for up to 500×10s; a slow/heavily-instrumented page can tie up a worker thread and stall its other requests. | `websocket.zig`, `client.zig:140-141` |
| HIGH | No wall-clock timeout/backpressure on `waitForEvent`; callers pass `max_attempts=1000` → ~10,000s of potential blocking if a server drip-feeds. | `client.zig` |
| HIGH/MED | `EventBuffer` silently drops the oldest event at 256 (no log/metric) — event loss on heavy SPAs with zero visibility; and the 500-attempt cap is really a **correctness** drop (late response lost), not just resource bound. | `client.zig` |

**Direction (dovetails with the gateway, Track 1):** enforce per-session memory +
event-rate quotas at the worker, bound `pending_requests` with a TTL sweep, add a
wall-clock deadline to `waitForEvent`, and surface dropped-event counts as metrics
(the gateway then bills/limits on them).

## 6. Rejected findings (verifier dismissed — for the record)

The verification pass killed 9 plausible-but-wrong findings, which is the point of
the adversarial step:

- u64→usize length casts "unguarded" — **false**: guarded by `> maxInt(usize)` /
  `> read_buf.len` checks before every `@intCast` (`websocket.zig:322,331,338,388,396`).
- u64→u8 cast in `writeFrame` "unsafe" — **false**: guarded by `data.len <= 65535`.
- `removeTab` iterator invalidation / `exportState` race — **false**: both fully
  under the `PthreadRwLock` (writer-exclusive).
- `EventBuffer.push` "double-free" — **false**: frees two *distinct* allocations
  (original + dupe), correct ownership transfer.
- HAR `status_text`/`mime` use-after-free — **false**: `addEntry` `dupe`s
  synchronously while the source buffer is still alive.
- `importState` arena "leak on error" — **false**: `defer arena.deinit()` runs on
  all paths (real issue there is a double-copy inefficiency, not a leak).
- `connectWs` stale-event leak on reconnect — **false** in current flow (dead
  clients are destroyed+recreated, not reused).

## 7. Prioritized remediation

1. **Concurrency correctness (§1)** — these are crash/UAF class and live today:
   lock `setCdpAddress`; eliminate the escaping `*CdpClient`; stop holding `mu`
   across I/O; per-worker io context. *Do before any GA traffic.*
2. **Stale-ws_url reconnect loop (§2, HIGH)** — bound retries + surface the failure
   instead of silently re-creating dead clients.
3. **Quotas + unbounded growth (§5, §4 HIGH)** — `pending_requests` TTL, per-session
   memory cap, `waitForEvent` deadline, dropped-event metrics. Wire the caps to the
   gateway's metering (Track 1 §7).
4. **WebSocket robustness (§3)** — real handshake header parsing; iterative frame
   reader; control-frame size/FIN checks. Matters most when connecting to
   untrusted CDP endpoints.
5. **Leaks under churn (§4 MED)** — `fetchRemove` for `snapshots`; `errdefer` in
   `toJson`/`handleCdpEvent`. Lower severity but cheap.

These pair naturally with Track 1: the gateway's one-Chrome-per-worker isolation
shrinks the blast radius, and its quota/metering layer is where the §5 limits get
enforced and billed.
