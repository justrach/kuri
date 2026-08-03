# Track 2 — Multi-Tenant Cloud Profile Store

> Promote the key-isolated `connect` vault from single-tenant to a managed,
> multi-tenant **cloud profile store** — kuri's standout wedge versus
> browser-use Cloud's "Browser Profiles".
> Status: **design + first code change** (tenant-namespaced `connect_store`).

## 1. Why this is the wedge

browser-use Cloud's Profiles persist cookies/localStorage across runs, keyed by a
`profile_id`. kuri already has the same capability **with a better security
model**: the `kuri-connect-broker` holds the vault passphrase so the agent never
does (`src/connect_broker.zig:1-19`). A compromised agent can only replay the
sessions it explicitly asks for; it cannot decrypt the at-rest vault or dump other
services. That is architecturally ahead of "a cloud folder of browser data."

The gap to a managed service is **tenancy**: today there is exactly one vault
(`<state_dir>/connections.ns`) protected by one passphrase
(`connect_store.zig:9-12`). A managed service needs per-tenant isolation —
tenant A's compromise must not expose tenant B.

## 2. Current shape (single-tenant)

```
KURI_VAULT_PASSPHRASE ─┐
                       ▼
  connect_store.openVault(state_dir, passphrase)
                       ▼
  <state_dir>/connections.ns      ← ONE vault, ONE key, ONE namespace
     connections/<service> = { base_url, auth.session = <payload> }
```

- `saveSession / loadSession / listSessions / deleteSession`
  (`connect_store.zig:34-93`) all key only by `service` name.
- The broker exposes `/save /load /list /delete` gated by one broker token
  (`connect_broker.zig:84-105`); no tenant dimension.

## 3. Target shape (multi-tenant)

Two changes, layered:

### 3.1 Namespace vaults by tenant (this change)

```
  <state_dir>/tenants/<tenant_id>/connections.ns   ← one vault PER TENANT
```

- New `tenantStateDir(state_dir, tenant_id)` derives the per-tenant directory.
- `tenant_id` is **sanitized** (reject `/`, `\`, `.`, NUL, empty, over-long) so a
  hostile `tenant_id` like `../../etc` cannot escape the state root. This is the
  load-bearing security check — a profile store keyed by a network-supplied id is
  a path-traversal magnet.
- New `*ForTenant` functions wrap the existing ones with the derived dir, so the
  single-tenant API stays intact (back-compat for the local `kuri connect` CLI).

### 3.2 Per-tenant keys (next change, designed here)

Directory isolation alone still shares one passphrase. For real blast-radius
containment each tenant vault must be wrapped by its **own** key:

- The gateway (Track 1) authenticates the tenant and resolves a **per-tenant
  passphrase** — never a global one — before calling the broker.
- Sourcing options, weakest → strongest:
  1. **Derived**: `tenant_pass = HKDF(master_secret, tenant_id)`. One master to
     hold; per-tenant keys are deterministic. Compromise of the master is total,
     so the master lives only in the broker/KMS, never in a worker.
  2. **Per-tenant secret**: a random passphrase per tenant stored in a KMS
     (AWS KMS / GCP KMS / Vault), fetched by the broker on demand. Master
     compromise ≠ tenant compromise. Preferred for GA.
  3. **Customer-managed key (BYOK)**: enterprise tenants supply their own KMS key;
     kuri never holds plaintext. Sell as a tier.
- nanostore already wraps its DEK with an Argon2id-derived key
  (`connect_store.zig:9-12`), so per-tenant passphrase = per-tenant DEK wrapping
  with no nanostore change.

## 4. Broker & gateway integration

### Broker (`connect_broker.zig`)

Add a `tenant` query param to `/save /load /list /delete` and route through the
`*ForTenant` functions. The broker resolves the per-tenant passphrase (§3.2)
instead of using a single `KURI_VAULT_PASSPHRASE`:

```
GET /load?tenant=<id>&service=<name>&cdp=<ws>&token=<broker-token>
```

The broker stays the only holder of key material; the worker/agent still only ever
sees "loaded:true", never the secret (`connect_broker.zig:138-139`).

### Gateway (`gateway_main.zig`, Track 1)

`POST /v1/sessions { "profile_id": "..." }` → on worker readiness, the gateway
calls the broker `/load?tenant=<tenant>&service=<profile_id>&cdp=<worker_ws>` to
inject the saved login before handing the session back. `profile_id` *is* the
service name within the tenant's vault. A "profile sync" flow (log in once, capture
to the vault) maps to broker `/save`.

## 5. Public API (profiles)

```
POST   /v1/profiles                 → { profile_id }          (create empty)
POST   /v1/profiles/:id/sync        → { live_url }            (interactive login → /save)
GET    /v1/profiles                 → { profiles:[...] }      (tenant-scoped list)
DELETE /v1/profiles/:id             → { deleted:true }
# use:  POST /v1/sessions { "profile_id": ":id" }  injects it on boot
```

All tenant-scoped via the gateway's bearer→tenant mapping; the gateway never
returns secret values, mirroring the broker's no-echo rule.

## 6. What lands in code now

- `connect_store.zig`: `tenantStateDir` + `sanitizeTenantId` + `saveSessionForTenant`
  / `loadSessionForTenant` / `listSessionsForTenant` / `deleteSessionForTenant`,
  with an isolation test (tenant A cannot see tenant B's services, traversal ids
  rejected).
- Single-tenant functions untouched (local CLI back-compat).

## 7. What's deferred

- Per-tenant key sourcing (HKDF/KMS/BYOK) — needs the secret-management decision.
- Broker `tenant` param + gateway `/v1/profiles` routes — follow once §3.2 lands.
- The `vault.zig` duplication of nanostore's crypto/store modules (tracked debt)
  should be collapsed before this ships to avoid two crypto code paths.
