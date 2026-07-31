# Telemetry

kuri ships anonymous, aggregate usage telemetry so we can see how the server is
used (which endpoints, how often, how fast, how much data) and prioritise work.
It is **on by default** and trivial to turn off.

## Opting out

Any one of these disables telemetry completely:

```bash
KURI_NO_TELEMETRY=1 kuri      # environment variable
kuri --no-telemetry           # CLI flag
```

When disabled, nothing is recorded, no file is written, and no network request
is ever made.

## What is collected

Only aggregate, non-identifying signal:

| Field | Example | Notes |
|-------|---------|-------|
| `http.route` | `/navigate`, `/screenshot` | **route name only** — the query string is stripped first |
| `http.request.method` | `GET`, `POST` | |
| `http.response.status_code` | `200`, `404` | |
| `http.server.request.duration_ns` | `1234567` | per-request latency |
| `http.response.body.size` | `4096` | response size in bytes |
| `error` | `false` | status ≥ 400 |
| `service.version` | `0.5.1` | kuri version |
| `os.type` / `host.arch` | `macos` / `aarch64` | platform |
| `service.instance.id` | random 128-bit hex | per-install id, so distinct installs can be counted |

## What is **never** collected

- The URLs you navigate to, or any query-string parameters (these are stripped
  before telemetry sees the route — see [`src/server/router.zig`](../src/server/router.zig)
  `handleConnection`).
- Page content, screenshots, DOM, cookies, storage, headers, or request bodies.
- Selectors, evaluated JavaScript, or any element data.
- Your API token, IP, hostname, username, or any other identifier.

The `service.instance.id` is a random value generated once per install and
stored at `~/.kuri/instance_id`. Delete that file to rotate it; it contains no
PII and is not derived from anything about your machine.

## Data flow

1. Each HTTP request appends one event to an in-process lock-free ring buffer.
2. The ring is flushed to an append-only write-ahead log at
   `~/.kuri/telemetry.ndjson` (newline-delimited log-record JSON) every 64
   events.
3. A background thread, every 30 seconds (and once on shutdown), wraps the WAL
   records in a `kuri.telemetry.v1` envelope (`schema_version`, `resource`,
   `scope`, `session`, `logRecords`) and `POST`s it to the ingest endpoint.
4. On a successful POST (HTTP 2xx) the WAL is truncated. If the POST fails the
   WAL is kept and retried on the next tick — no data loss, no blocking of the
   request path.

The payload is OpenTelemetry-aligned (resource → scope → logRecords, with
`timeUnixNano`, `body`, `severityText`/`severityNumber`, and `attributes`),
flattened into the `kuri.telemetry.v1` schema the ingest endpoint stores
one-row-per-record. Each `logRecord` `body` is an event name
(`kuri.session.start`, `kuri.http.request`) and `attributes` is a flat object.

### Payload shape

```json
{
  "schema_version": "kuri.telemetry.v1",
  "resource": {
    "service.name": "kuri",
    "service.version": "0.4.5",
    "service.instance.id": "<random per-install hex>",
    "telemetry.sdk.language": "zig",
    "telemetry.sdk.name": "kuri",
    "telemetry.sdk.version": "0.4.5"
  },
  "scope": { "name": "kuri", "version": "0.4.5" },
  "session": { "id": "<random per-run hex>" },
  "logRecords": [
    { "timeUnixNano": "...", "body": "kuri.session.start", "severityText": "INFO",
      "severityNumber": 9, "attributes": { "os.type": "macos", "host.arch": "aarch64" } },
    { "timeUnixNano": "...", "body": "kuri.http.request", "severityText": "INFO",
      "severityNumber": 9, "attributes": {
        "http.route": "/navigate", "http.request.method": "GET",
        "http.response.status_code": 200, "http.server.request.duration_ns": 229000,
        "http.response.body.size": 52, "error": false } }
  ]
}
```

## Endpoint

Defaults to the compiled `DEFAULT_TELEMETRY_URL` in
[`src/telemetry.zig`](../src/telemetry.zig). Override at runtime:

```bash
KURI_TELEMETRY_URL="https://example.com/api/telemetry/v1/kuri" kuri
```

## Implementation

All telemetry lives in [`src/telemetry.zig`](../src/telemetry.zig). The only
hooks elsewhere are:

- `src/server/router.zig` — times each request and records the route name.
- `src/server/response.zig` — reports response status + body size via a
  thread-local.
- `src/main.zig` — `telemetry.init` / `startSyncThread` / `recordSessionStart`
  / `deinit`, plus the `--no-telemetry` flag.
