# Changelog

All notable changes to kuri are documented here.

## [0.3.1] — 2026-04-23

### Maintenance
- **Zig 0.16 migration stabilization** — build, test, and startup paths updated for Zig 0.16 across local and GitHub Actions environments
- **CI portability fixes** — Linux libc linking, Chrome startup, and validator compatibility regressions resolved
- **Benchmark refresh** — README benchmark section updated with a fresh `kuri` rerun from `bench/token_benchmark.sh`
- **Version sync** — runtime strings, package metadata, and docs aligned to `0.3.1`

## [0.4.0] — 2026-04-10

### Stealth & Anti-Bot Evasion
- **Enhanced stealth.js** — Added WebGL renderer spoofing (Intel Iris), canvas fingerprint noise, AudioContext timing noise, `hardwareConcurrency`/`deviceMemory` spoofing, `navigator.connection` broadband values, `chrome.csi`/`chrome.loadTimes` stubs for Akamai bypass
- **Updated User Agents** — Chrome 131 → 135, Safari 18.2 → 18.4, Firefox 134 → 137
- **Anti-detection Chrome flags** — `--disable-blink-features=AutomationControlled`, `--disable-infobars`, `--disable-background-networking`, `--disable-dev-shm-usage`, `--window-size=1920,1080`
- **`--no-sandbox` Linux-only** — Removed on macOS where it's a bot detection signal (fixes #128)
- **Auto-stealth on startup** — Stealth patches + UA rotation applied to all tabs via `Page.addScriptToEvaluateOnNewDocument` during discovery. No manual `stealth` command needed in server mode
- **Proxy support** — `KURI_PROXY` env var passes `--proxy-server` to Chrome for residential proxy evasion. Supports `socks5://` and `http://` proxies

### Bot Block Detection & Fallback
- **Automatic bot detection** — `/navigate` now detects Akamai, Cloudflare, PerimeterX, DataDome, and generic captcha blocks after navigation
- **Structured fallback response** — When blocked, returns `{"blocked":true,"blocker":"akamai","ref_code":"...","fallback":{"suggestions":[...],"proxy_hint":"...","bypass_difficulty":"high"}}`
- **Bypass with `&bot_detect=false`** — Disable detection for speed-sensitive operations
- **Successfully bypassed Singapore Airlines** — Akamai WAF now passable with stealth patches + anti-detection flags (previously returned "SIA-Maintenance Page")

### HAR Replay & API Map
- **`/har/replay` endpoint** — Transforms captured HAR entries into model-friendly code snippets (curl, fetch, Python requests)
- **Request headers capture** — HAR now records full request headers from CDP `Network.requestWillBeSent` events
- **POST body capture** — HAR now records `postData` from request events
- **Filters** — `?filter=api` (JSON/XHR only), `?filter=doc` (HTML/JSON), `?filter=all`
- **Format** — `?format=curl`, `?format=fetch`, `?format=python`, `?format=all`

### Security Fixes
- **SSRF protection (#81)** — `/navigate` now validates URLs against private IPs, localhost, cloud metadata (169.254.x.x), and non-HTTP schemes via `validator.zig`
- **JSON injection fix (#82)** — All user-supplied values (URL, selector, key, value, name, domain, file_path) escaped via `jsonEscapeAlloc` before JSON/JS interpolation

### CDP Client Stability
- **Event buffer use-after-free fix (#83)** — `EventBuffer.push` now dupes data into persistent allocator, preventing segfaults when arena allocators are destroyed
- **Increased event headroom** — CDP `send()` now reads up to 500 events (was 100), handling heavy SPAs like Shopee/SIA
- **Auto-reconnect** — CDP client marks itself disconnected on WebSocket errors and reconnects on next `send()` call
- **Stale WebSocket cleanup** — `connectWs()` closes old WebSocket before opening new connection

## [0.3.0] — 2026-03-20

### Human Copilot Mode
- **`open [url]`** — one command to launch visible Chrome with CDP and auto-attach. The human sees the browser, the agent rides alongside. No headless, no bot detection issues.
- **`HEADLESS=false`** — kuri server mode now supports visible Chrome. Default remains headless for backward compat.
- **`stealth`** — anti-bot patches (UA override, navigator.webdriver=false, fake plugins). Persists across commands via session.

### Agent-Friendly Output
- All commands now return clean, flat JSON instead of raw CDP responses:
  - `go` → `{"ok":true,"url":"..."}`
  - `click` → `{"ok":true,"action":"clicked"}`
  - `eval` → raw value (no triple-nested JSON)
  - `text` → real newlines (not escaped `\n`)
  - `back/forward/reload/scroll` → `{"ok":true}`
- Agents no longer need `jq '.result.result.value'` to parse output.

### Popup & Redirect Following
- **`grab <ref>`** — click + follow popup redirects in the same tab. Hooks both `window.open` and dynamically created `<form target="_blank">` (Google Flights pattern).
- **`wait-for-tab`** — poll for new tabs opened by the page.
- Tested end-to-end: Google Flights → Scoot booking page landed successfully.

### Compact Snapshot (20x token reduction)
- Default `snap` output is now compact text-tree: `role "name" @ref`
- Noise roles filtered by default (none/generic/presentation/ignored)
- `--interactive` mode for agent loops (~1,927 tokens on Google Flights)
- `--json` flag restores old JSON format for backward compat

### Token Benchmark
- Full workflow benchmark: `go→snap→click→snap→eval`
- kuri: **4,110 tokens** vs agent-browser: **4,880 tokens** — **16% savings per cycle**
- Reproducible: `./bench/token_benchmark.sh [url]`

### Security Testing
- `cookies` — list with Secure/HttpOnly/SameSite flags
- `headers` — security response header audit (CSP, HSTS, X-Frame-Options)
- `audit` — full security scan (HTTPS + headers + JS-visible cookies)
- `storage` — dump localStorage/sessionStorage
- `jwt` — scan all storage + cookies for JWTs, base64-decode payloads
- `fetch` — authenticated fetch from browser context (uses session cookies + extra headers)
- `probe` — IDOR enumeration: `probe https://api.example.com/users/{id} 1 100`
- `set-header` / `clear-headers` / `show-headers` — persist auth headers across commands

### Install
- `curl -fsSL https://raw.githubusercontent.com/justrach/kuri/main/install.sh | sh`
- `bun install -g kuri-agent` / `npm install -g kuri-agent`
- GitHub release workflow with optional Apple notarization (add APPLE_* secrets)

### CI
- Fixed QuickJS Debug-mode crash on Linux (`-Doptimize=ReleaseSafe` in CI)

## [0.2.0] — 2026-03-17

### kuri-agent CLI
- Scriptable Chrome automation via CDP — stateless, one command per invocation
- Session persistence at `~/.kuri/session.json` (cdp_url, refs, extra_headers)
- Commands: tabs, use, go, snap, click, type, fill, select, hover, focus, scroll, viewport, eval, text, shot, back, forward, reload
- Accessibility tree snapshots with ref-based element targeting (@e0, @e1, ...)

### Compact Snapshot Format
- Text-tree format: `role "name" @ref` — replaces verbose JSON
- Noise filtering: skip none/generic/presentation roles
- `--interactive` / `--semantic` / `--all` / `--json` / `--text` flags

## [0.1.0] — 2026-03-14

### Initial Release
- **kuri** — CDP HTTP API server (Chrome automation, a11y snapshots, HAR recording)
- **kuri-fetch** — standalone fetcher with QuickJS JS engine, no Chrome needed
- **kuri-browse** — interactive terminal browser (navigate, follow links, search)
- 230+ tests, 4-target cross-compilation (macOS/Linux × arm64/x86_64)
- Zero Node.js dependencies, 464 KB server binary
