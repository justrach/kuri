# Agentic Browdie 🧁

> A high-performance browser automation & web crawling toolkit for AI agents — written in **Zig**.
>
> Inspired by [Pinchtab](https://github.com/pinchtab/pinchtab), [Pathik](https://github.com/justrach/pathik), and [agent-browser](https://github.com/vercel-labs/agent-browser). Rebuilt from scratch in Zig for maximum performance, minimal memory footprint, and zero-dependency deployment.

---

## Why Zig?

| Dimension | Go (Pinchtab / Pathik) | Zig (Agentic Browdie) |
|---|---|---|
| **Memory** | GC pauses, ~50-100 MB baseline | No GC, arena allocators, ~5-15 MB baseline |
| **Binary size** | ~15-30 MB | ~2-5 MB (static, no libc) |
| **Startup** | ~50-100ms | ~1-5ms |
| **Concurrency** | Goroutines (M:N scheduler) | Thread pool + per-request arenas |
| **Cross-compile** | `GOOS/GOARCH` | Single binary, any target from any host |

---

## Quick Start

### Prerequisites

- **Zig ≥ 0.15.1**
- **Chrome / Chromium** (auto-detected on macOS + Linux)

### Build & Run

```bash
# Build
zig build

# Run — launches Chrome automatically
./zig-out/bin/agentic-browdie

# Or connect to an existing Chrome instance
CDP_URL=ws://127.0.0.1:9222 ./zig-out/bin/agentic-browdie

# Run all tests (99+)
zig build test
```

### Usage — Browse vercel.com in 4 commands

```bash
# 1. Discover Chrome tabs
curl -s http://localhost:8080/discover
# → {"discovered":1,"total_tabs":1}

# 2. Get tab ID
curl -s http://localhost:8080/tabs
# → [{"id":"ABC123","url":"chrome://newtab/","title":"New Tab"}]

# 3. Navigate to vercel.com
curl -s "http://localhost:8080/navigate?tab_id=ABC123&url=https://vercel.com"

# 4. Get accessibility snapshot (token-optimized for LLMs)
curl -s "http://localhost:8080/snapshot?tab_id=ABC123&filter=interactive"
# → [{"ref":"e0","role":"link","name":"VercelLogotype"},
#    {"ref":"e1","role":"button","name":"Ask AI"},
#    {"ref":"e2","role":"link","name":"Start Deploying"}, ...]
```

---

## HTTP API

All endpoints return JSON. Optional auth via `BROWDIE_SECRET` env var.

### Core

| Path | Description |
|------|-------------|
| `/health` | Server status, tab count, version |
| `/tabs` | List all registered tabs |
| `/discover` | Auto-discover Chrome tabs via CDP |
| `/browdie` | 🧁 |

### Browser Control

| Path | Params | Description |
|------|--------|-------------|
| `/navigate` | `tab_id`, `url` | Navigate tab to URL |
| `/snapshot` | `tab_id`, `filter=interactive` | Accessibility tree snapshot with `@eN` refs |
| `/text` | `tab_id` | Extract page text |
| `/screenshot` | `tab_id` | Capture screenshot (base64 PNG) |
| `/action` | `tab_id`, `ref`, `kind` | Click/type/scroll elements by ref |
| `/evaluate` | `tab_id`, `expr` | Execute JavaScript |
| `/close` | `tab_id` (optional) | Close tab + cleanup resources |

### HAR Recording

| Path | Description |
|------|-------------|
| `/har/start?tab_id=` | Start recording network traffic |
| `/har/stop?tab_id=` | Stop recording, return HAR 1.2 JSON |
| `/har/status?tab_id=` | Check recording state + entry count |

---

## Architecture

```
┌──────────────────────────────────────────────────────────┐
│                     HTTP API Layer                        │
│         (std.http.Server, thread-per-connection)          │
├──────────────┬──────────────────┬────────────────────────┤
│   Browser    │  Crawler Engine  │   Storage (stubs)       │
│   Bridge     │                  │                         │
├──────────────┼──────────────────┼────────────────────────┤
│ CDP Client   │ URL Validator    │ Kafka Producer          │
│ Tab Registry │ HTML→Markdown    │ R2/S3 Uploader          │
│ A11y Snapshot│ Readability      │ Local File Writer       │
│ Ref Cache    │ Pipeline         │                         │
│ HAR Recorder │                  │                         │
│ Stealth JS   │                  │                         │
├──────────────┴──────────────────┴────────────────────────┤
│  Chrome Lifecycle Manager                                 │
│  (launch, health-check, auto-restart, port detection)     │
└──────────────────────────────────────────────────────────┘
```

### Memory Safety

- **Arena-per-request** — all per-request memory freed in one `deinit()` call
- **Proper cleanup chains** — `Launcher → Bridge → CdpClients → HarRecorders → Snapshots → Tabs`
- **`removeTab` cleans everything** — CDP connections, HAR recorders, snapshots, owned strings
- **Chrome process killed on shutdown** — `kill()` + `wait()` in `Launcher.deinit()`
- **`errdefer` guards** — tab registration rolls back on partial failure
- **No GC, no leaks** — `GeneralPurposeAllocator` in debug mode catches everything

### Chrome Lifecycle

| Mode | Behavior |
|------|----------|
| **Managed** (no `CDP_URL`) | Browdie launches Chrome headless, finds free CDP port, supervises, auto-restarts on crash (max 3 retries), kills on shutdown |
| **External** (`CDP_URL` set) | Connects to existing Chrome, health-checks via `/json/version`, does NOT kill on shutdown |

---

## Project Structure

```
agentic-browdie/
├── build.zig                  # Build system (Zig 0.15.1)
├── build.zig.zon              # Package manifest
├── src/
│   ├── main.zig               # Entry point — Chrome launch, bridge init, server start
│   ├── chrome/
│   │   └── launcher.zig       # Chrome lifecycle (launch, health-check, supervise, restart)
│   ├── server/
│   │   ├── router.zig         # HTTP route dispatch (15 endpoints)
│   │   ├── middleware.zig     # Auth middleware
│   │   └── response.zig      # JSON response helpers
│   ├── bridge/
│   │   ├── bridge.zig         # Central state (tabs, CDP clients, HAR recorders, snapshots)
│   │   └── config.zig         # Env var configuration
│   ├── cdp/
│   │   ├── client.zig         # CDP WebSocket client with message correlation
│   │   ├── websocket.zig      # Raw WebSocket frame encoder/decoder
│   │   ├── protocol.zig       # CDP method constants
│   │   ├── actions.zig        # High-level CDP actions
│   │   ├── stealth.zig        # Bot detection bypass
│   │   └── har.zig            # HAR 1.2 recorder
│   ├── snapshot/
│   │   ├── a11y.zig           # A11y tree builder with interactive filter
│   │   ├── diff.zig           # Snapshot delta diffing
│   │   └── ref_cache.zig      # @eN ref → node ID cache
│   ├── crawler/
│   │   ├── validator.zig      # SSRF defense, URL validation
│   │   ├── markdown.zig       # HTML → Markdown converter
│   │   ├── fetcher.zig        # Page fetching (stub)
│   │   ├── extractor.zig      # Readability extraction (stub)
│   │   └── pipeline.zig       # Parallel crawl pipeline (stub)
│   ├── storage/
│   │   ├── local.zig          # Local file writer (stub)
│   │   ├── kafka.zig          # Kafka producer (stub)
│   │   └── r2.zig             # R2/S3 uploader (stub)
│   ├── util/
│   │   └── json.zig           # JSON serialization helpers
│   └── test/
│       ├── harness.zig        # Test HTTP client, snapshot assertions
│       └── integration.zig    # 30+ integration tests
└── js/
    ├── stealth.js             # Bot detection bypass script
    └── readability.js         # Content extraction script
```

---

## Configuration

| Env Var | Default | Description |
|---------|---------|-------------|
| `HOST` | `127.0.0.1` | Server bind address |
| `PORT` | `8080` | Server port |
| `CDP_URL` | *(none)* | Connect to existing Chrome (e.g. `ws://127.0.0.1:9222`) |
| `BROWDIE_SECRET` | *(none)* | Auth secret for API requests |
| `STATE_DIR` | `.browdie` | Directory for session state |
| `REQUEST_TIMEOUT_MS` | `30000` | HTTP request timeout |
| `NAVIGATE_TIMEOUT_MS` | `30000` | Page navigation timeout |
| `STALE_TAB_INTERVAL_S` | `30` | Stale tab cleanup interval |

---

## Token Cost (from Pinchtab benchmarks)

For a 50-page monitoring task:

| Method | Tokens | Cost ($) | Best For |
|--------|--------|----------|----------|
| `/text` | ~40,000 | $0.20 | Read-heavy tasks (13x cheaper than screenshots) |
| `/snapshot?filter=interactive` | ~180,000 | $0.90 | Element interaction |
| `/snapshot` (full) | ~525,000 | $2.63 | Full page understanding |
| `/screenshot` | ~100,000 | $1.00 | Visual verification |

---

## Acknowledgments

- **[Pinchtab](https://github.com/pinchtab/pinchtab)** — Browser control for AI agents (Go)
- **[Pathik](https://github.com/justrach/pathik)** — High-performance web crawler (Go)
- **[agent-browser](https://github.com/vercel-labs/agent-browser)** — Vercel's agent-first browser automation — `@eN` ref system, snapshot diffing, HAR recording patterns

## License

Apache-2.0
