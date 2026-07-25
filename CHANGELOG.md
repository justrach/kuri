# Changelog

All notable changes to kuri are documented here.

## [0.4.6] — 2026-07-25

### Features — kuri-mobile iOS, driverless
- **`ios uitree`** — dumps the running app's real accessibility tree (labels, identifiers, values, device-pixel bounds) with no XCUITest bundle and no on-device agent. Works by enabling `ApplicationAccessibilityEnabled` inside the simulated runtime, which populates Simulator.app's host-side AX hierarchy
- **Tap by label** — `--label` targets an element by accessibility label, identifier or value (exact match, then substring) instead of raw coordinates
- **Input** — `doubletap`, `longpress`, `swipe`/`scroll`/`pan`, `type`, and `key` with modifier support (`key return --cmd`)
- **Hardware buttons** — `ios button home|lock|volup|voldown|action` driven through the host accessibility bridge
- **Lifecycle & environment** — `ios background`, `ios privacy`, `ios ui`, `ios status-bar`, `ios log`, `ios list-devices`

### Fixes
- **Release pipeline never published** — `build-macos-x86` pinned `macos-13`, a runner label GitHub has retired. The job never got a runner, sat queued until the 24-hour job limit cancelled it, and skipped both publish jobs. Every tag from v0.3.3 to v0.4.5 died this way. macOS now cross-compiles both arches on one `macos-latest` runner, and every job has an explicit `timeout-minutes`
- **Release notes generation crashed** — the notes/checksum script split on a literal `\n` (backslash-n) rather than a newline, raising `IndexError` on the first successful run. Never observed because the job had always been skipped
- **kuri-mobile was never shipped** — the root build had no reference to it, so releases omitted the binary that `kuri` execs as a sibling. It is now a path dependency of the root build and lands in every tarball
- **kuri-mobile did not build off native macOS** — an inferred error set collapsed to `MacOsOnly` on non-macOS targets, and cross-compiling to `x86_64-macos` could not find `ApplicationServices`. Both arches and both Linux arches now build
- **Use-after-free in the accessibility walker** — `CFArrayGetValueAtIndex` follows CoreFoundation's Get Rule, so releasing the parent array freed elements still in use. This crashed `uitree` and made `ios button` intermittently fail. Elements are now retained at the match point
- **Silent tool-resolution failures** — `ios list-devices` exited 0 printing nothing when `xcode-select` pointed at CommandLineTools. Developer tools are now resolved to absolute paths with checked exit status
- **Version strings** — `kuri`, `kuri-browse` and `kuri-fetch` reported 0.4.1/0.4.0 regardless of the release they shipped in

### Known limitations
- macOS assets are unsigned and un-notarized until Apple credentials are configured as repository secrets
- `tap`/`swipe`/`type`/`uitree` remain Simulator-only; real devices need XCUITest
- `ios privacy` cannot reset camera authorization — `simctl privacy` has no camera service

## [0.4.5] — 2026-05-27

### Fixes
- **CDP session auto-recovery** — When Chrome performs a cross-process renderer swap (e.g., navigating to Instagram), it detaches the old CDP target and assigns a new `webSocketDebuggerUrl`. Kuri now detects dead clients, re-fetches `/json/list`, and reconnects automatically instead of silently failing (#172)
- **Dead client detection** — `CdpClient` now tracks whether its WebSocket connection is permanently broken, distinguishing transient disconnects from stale target URLs

## [0.4.4] — 2026-05-24

### Features — beyond parity (142 HTTP endpoints)
- **Action caching** — `/cache/set`, `/cache/get`, `/cache/clear`, `/cache/list` — cache ref mappings so repeated workflows skip LLM inference entirely
- **Set-of-Marks screenshot** — `/screenshot/som` — screenshot with numbered bounding-box overlays on interactive elements for vision models
- **Hybrid snapshot** — `/snapshot?include_screenshot=true` — a11y tree + screenshot in one call for multimodal agents
- **Smart diff** — `/snapshot/changes` — returns only added/removed lines since last snapshot (10-100x fewer tokens)
- **Recording export** — `/recording/export` — convert recorded actions into replayable `/batch` JSON
## [0.4.3] — 2026-05-24

### Features — full agent-browser parity (135 HTTP endpoints)
- **Batch execution** — `POST /batch` runs multiple commands in one HTTP call, returns array of results
- **Enhanced wait** — `/wait` now supports `text`, `url`, `state=networkidle`, `visible=true` params; new `/wait/function` and `/wait/download`
- **Element state queries** — `/element/state?ref=e0&check=visible` for quick boolean checks without full snapshot
- **Semantic locators** — `/find-element?text=Submit` / `?role=button` / `?label=Email` / `?placeholder=Search` / `?testid=login-btn`
- **Page state** — `/page/state` lightweight observation (48 tokens vs 2,124 for full snap)
- **Dialog handling** — `/dialog/auto`, `/dialog/accept`, `/dialog/dismiss`
- **Mouse control** — `/mouse/move`, `/mouse/down`, `/mouse/up`, `/mouse/wheel`
- **Touch events** — `/tap`, `/swipe`
- **Clipboard** — `/clipboard/read`, `/clipboard/write`
- **Form operations** — `/clear`, `/selectall`, `/setvalue`, `/multiselect`
- **Element queries** — `/boundingbox`, `/getattribute`, `/inputvalue`, `/evalhandle`
- **Emulation** — `/timezone`, `/locale`, `/permissions`
- **React inspection** — `/react/tree`, `/react/inspect`, `/react/renders`, `/react/suspense`
- **Recording** — `/recording/start`, `/recording/stop`
- **Performance** — `/vitals` (LCP, CLS, FID, TTFB, FCP, domInteractive)
- **Navigation** — `/pushstate`, `/bringtofront`, `/frame`, `/mainframe`
- **Injection** — `/addstyle`, `/expose`, `/initscript/remove`, `/setcontent`
- **Network** — `/request/detail`, `/response/body`, `/download`
- **Diff** — `/diff/url` (compare two URLs side by side)

### Token efficiency
- 7-12% fewer tokens than agent-browser on real pages (`@e0` vs `[ref=e0]`)
- `/page/state` is 44x lighter than full snapshot (48 vs 2,124 tokens on Google Flights)
## [0.4.2] — 2026-05-24

### Fixes
- **React/Vue click compatibility** — `click`, `check`, and `uncheck` actions now use CDP `Input.dispatchMouseEvent` (mousePressed/mouseReleased) instead of DOM `.click()`, producing trusted `isTrusted:true` events that React 18/19 event delegation recognizes (#164)
- **React/Vue type/fill compatibility** — `type` and `fill` actions now use per-character CDP `Input.dispatchKeyEvent` instead of setting `target.value` directly, so React controlled inputs fire `onChange` correctly (#164)
- **Click coordinate bug** — fixed JS operator precedence in bounding-rect center calculation that caused `r.y + r.height/2` to be string-concatenated instead of added
- **Server type/fill default** — `realistic` mode (CDP key events) is now the default for the HTTP server `/action` endpoint; opt out with `realistic=false`

### Testing
- **React e2e fixture** — added `test/react-form.html` for validating form fill + click against React 18 controlled components

## [0.4.1] — 2026-05-23

### Release and install fixes
- **Installer parsing fix** — Adds `--color=never` to installer grep calls so ANSI escapes do not corrupt macOS `sed` parsing.
- **README install polish** — Moves the copyable install command and direct download links to the top of the README for easier release consumption.
- **Release metadata sync** — Runtime version string and npm package metadata aligned for the v0.4.1 patch release.

## [0.4.0] — 2026-05-22

### kuri-browser — Standalone Browser Engine
- **Native rendering engine** — Full DOM tree, CSS cascade with layout/paint, real `<table>` layout, font shorthands (border/padding/margin/list-style), text metrics with per-character glyph widths calibrated against headless Chrome
- **QuickJS runtime** — JavaScript evaluation, fetch/XHR bridge, cookie-aware navigation state, form extraction, session-backed form submission, HAR capture for browser flows
- **CDP server** — Minimal CDP WebSocket router, CDP discovery server, compressed screenshot fallback, parsed DOM selectors
- **Agent actions** — Click, type, snap, scroll, navigate, eval, back/forward via CDP-compatible commands
- **Parity tracking** — Pixel parity benchmark harness vs Chrome, example.com parity tracking (98.45% wrapper / 86.37% direct), per-char glyph width calibration

### kuri-mobile — iOS + Android Device Control
- **Zig-native device automation** — Driverless: no on-device app, no Bun, no Gradle, no Xcode-time builds
- **Android** — ADB host protocol, XML UI tree parser, device listing, tap/swipe/type via input commands
- **iOS** — Simulator control via `xcrun simctl`, real device listing via usbmuxd, CGEvent-based tap/swipe/pan/type into Simulator.app

### Server
- **Bearer-token API auth** — All endpoints protected by configurable bearer token, new `kuri token` CLI command for token management
- **Signal-safe Chrome lifecycle** — Chrome process shutdown uses signal-safe paths, preventing orphan processes

### CI
- **Startup smoke tests** — CI now validates the bearer-token authentication wall
- **Mobile skills discovery** — Help/version regression guard for kuri-mobile CLI

## [0.3.3] — 2026-04-25

### Fixes
- **Auth profile reliability** — macOS keychain-backed auth profiles now resolve `security` correctly, and profile metadata round-trips escaped JSON safely
- **Session persistence safety** — bridge export/import now uses real JSON serialization/parsing instead of fragile string scanning
- **Redirect and localhost hardening** — URL validation now normalizes localhost aliases and re-validates redirect hops in both HTTP fetch paths
- **CDP stability** — stale buffered events no longer satisfy later `waitForEvent()` calls, and unsupported external CDP endpoint shapes are rejected up front
- **Packaging correctness** — HAR status/duration output is fixed, Chrome binary discovery checks `PATH`, and the npm installer rejects unsupported platforms instead of treating Windows as Linux

### Release
- **Notarized macOS artifacts in GitHub Releases** — tagged releases now mirror the signed/notarized macOS tarballs alongside the self-managed release channel

## [0.3.2] — 2026-04-24

### Release channel
- **Self-managed stable channel** — installers and manifests now resolve binaries from the `release-channel` branch instead of GitHub Releases
- **Channel-only release flow** — tag publishing updates the raw GitHub channel manifest and asset paths without creating a GitHub Release entry
- **macOS notarization kept in path** — stable macOS tarballs remain signed and notarized, with raw GitHub download URLs exposed directly in the README and channel manifest

## [0.3.1] — 2026-04-23

### Maintenance
- **Zig 0.16 migration stabilization** — build, test, and startup paths updated for Zig 0.16 across local and GitHub Actions environments
- **CI portability fixes** — Linux libc linking, Chrome startup, and validator compatibility regressions resolved
- **Benchmark refresh** — README benchmark section updated with a fresh `kuri` rerun from `bench/token_benchmark.sh`
- **Version sync** — runtime strings, package metadata, and docs aligned to `0.3.1`

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
