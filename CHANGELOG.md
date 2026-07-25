# Changelog

All notable changes to kuri are documented here.

## [0.4.11] — 2026-07-25

### Fixes — kuri no longer takes over your machine

Driving the Simulator used to seize the user's foreground window and move their cursor. Every input command called `sim_window.activate` before doing anything, because `CGEventPost(kCGHIDEventTap, …)` injects into the *global* event stream — events land wherever focus happens to be, so Simulator.app had to be raised first for a tap to hit the right thing. That made kuri unusable on a machine somebody is actually working on.

- **Input is delivered to Simulator.app by pid** — `CGEventPostToPid` instead of the global HID tap. Events go straight into Simulator's own queue, so no window is raised and the cursor is never warped. Covers `tap`, `doubletap`, `longpress`, `swipe`, `gesture`, `touch`, `key`, `key-sequence`, `batch`
- **`type` no longer routes through AppleScript.** It shelled out to System Events `keystroke`, which is delivered to whichever app is frontmost — so `ios type` was doubly hostile: it *had* to steal focus to be correct, and if it ever ran without doing so it would type your text into whatever you had open. Now Unicode `CGEvent`s addressed to the pid, which needs no virtual-keycode table either. `osascript` is gone from this path
- **`uitree`, `find` and `wait-for-ui` no longer activate at all.** They only read the accessibility tree, which works fine on a background app. `wait-for-ui` was the worst offender — it polls every 250ms, so it re-stole the foreground on every poll for the length of the wait
- **`button` and `background` no longer activate.** They already used `AXPress`, which never needed focus
- **`open-sim` launches in the background** (`open -g`). Opening a simulator is a setup step, not a request to be interrupted
- **`--activate` restores the old behaviour** per command, for the case where a gesture genuinely needs Simulator.app to be key. Off by default

### Fixes — real devices

- **`ios terminate --device` could never have succeeded.** It built `devicectl device process terminate --device <udid> <bundle-id>`, but devicectl's terminate takes `--pid` and accepts no bundle id at all — every invocation died on devicectl's own argument parser. `launch --device` now reads the launched pid from `--json-output` and prints `pid=N`; `terminate --device --pid N` does the direct thing; `terminate --device <bundle-id>` resolves the bundle id to a running pid by matching `device info processes` against the app's on-device bundle URL. A launch that reports success without an identifier is now an error rather than a silent zero, which would later terminate an unrelated process
- **`ios list-apps --device` silently hid every system app.** `devicectl device info apps` defaults to *developer apps only* and says nothing about it, so a command documented as "list installed apps" returned a handful of entries on a phone with hundreds — and exited 0. Now passes `--include-default-apps --include-app-clips`. The same defaulting broke bundle-id lookups, so terminate-by-bundle-id could not resolve a system app either
- **`ios list-apps` on the simulator no longer demands `--udid`.** It resolves the booted simulator like `launch`, `screenshot` and `uitree` already did; requiring it made `list-apps` the odd command out for no reason a caller could infer

### Fixes — diagnosis

- **"Simulator.app is not running" when Simulator.app was running.** The accessibility tree hangs off a window, and a device booted with `simctl boot` does not open one — so a running-but-windowless Simulator produced an error that sent you to restart an app that was already up. Now a distinct `SimulatorHasNoWindow` error carrying the actual remedy, and `doctor` reports window presence rather than just the process

### Tests

- **`zig build e2e-ios-device`** — a new end-to-end suite against physically attached hardware: inspection, the install → list-apps → launch → terminate → uninstall round trip both by pid and by bundle id, and assertions that the XCUITest-only commands still refuse cleanly *while a real device is attached*. Skips with a reason when nothing is plugged in, when no bundle id is configured, or when the screen is locked — phones re-lock on their own timeout, and SpringBoard refuses every launch while they are, which is the environment rather than a defect. Verified: **24 passed, 0 failed** against an iPhone 16 Pro Max
- **A real-device command contract group in `e2e-ios`, needing no hardware.** 21 hermetic cases pinning the silent-success class fixed in 0.4.10: every `--device` command must fail loudly against a fake udid, missing arguments must exit 2 rather than 1, and the XCUITest-only commands must exit 3 with an explanation. Two of them assert the *absence* of devicectl's argument-parser complaint, which is what distinguishes "the device is missing" from "we called devicectl wrong" — the exact bug fixed above
- **`e2e-ios` now degrades instead of failing** on preconditions a machine cannot supply. The Accessibility grant, a Simulator window and the Xcode toolchain are each probed and skipped with a reason, which is what lets the suite be a CI gate rather than a red build on a runner that can never hold a TCC grant
- **More simulator coverage** — `list-apps`, `status-bar` override/clear, `ui appearance` set-and-read-back, `set-location`/`reset-location`, `log --last`, `terminate`. Verified: **54 passed, 0 failed** against a booted simulator
- devicectl's JSON shapes are now unit-tested against fixtures — a missing pid must not decode as 0, and a process match must not be made on a coincidental path prefix (`/var/Demo.appendix` is not inside `/var/Demo.app`)

### CI

- **The e2e suite finally runs in CI.** A new `mobile-macos` job builds kuri-mobile, runs its unit tests, boots a simulator and runs both suites. Until now nothing caught a regression on the device path, which is how the silent `--device` no-op survived from 0.4.6 to 0.4.10
- It picks and boots the simulator *through kuri-mobile itself* rather than `xcrun simctl` — partly to exercise `list-devices` and `boot` for real, and partly because bare `xcrun` resolves through `xcode-select`, which is the exact indirection whose failure mode this project exists to avoid
- The job never opens Simulator.app, so it runs headless and the accessibility cases skip
- kuri-mobile's unit tests now also run on the Linux job; they had their own `build.zig` and the root `test` step never reached them

## [0.4.10] — 2026-07-25

### Fixes
- **Every `--device` command silently did nothing and reported success.** `devicectl.zig` shelled out to bare `xcrun devicectl`, which resolves through `xcode-select` — and when that points at CommandLineTools, devicectl does not exist there. Combined with an unchecked exit status, `ios launch --device` exited 0 having done nothing at all. This is the same bug class fixed for `simctl` in 0.4.6; devicectl was missed. It is now invoked by absolute path through the Xcode resolver with a checked exit status, so a failure surfaces devicectl's own diagnostic
- **`listDevicesJson` passed `--json-output -`**, but devicectl only writes JSON to a file on disk — never stdout — so this would have created a file literally named `-`. Replaced with the human-readable listing

### Features — physical iOS devices
- **`install` / `uninstall` / `list-apps` now work on real devices** via devicectl instead of erroring or being simulator-only
- **New device-scoped commands** — `device-info`, `device-processes`, `lock-state`, `displays`, `reboot`. `lock-state` in particular addresses a common silent failure: automation that appears to do nothing because the screen is locked
- iOS surface is 41 commands, 12 of which work against physical hardware

### Scope, stated honestly
- devicectl exposes **no screenshot and no UI hierarchy**, so `tap`/`swipe`/`type`/`uitree`/`screenshot` remain simulator-only no matter what is plugged in — those need XCUITest. The registry's `scope` field now reflects this exactly: 29 simulator-only, 7 simulator+device, 5 device-only

## [0.4.9] — 2026-07-25

### Tests
- **`zig build e2e-ios`** — an end-to-end suite that drives a real booted Simulator through the built binary, so it exercises the artifact that would actually ship rather than a test-only code path. 20 cases covering the registry, `doctor`, `install`, `launch`, `uitree`, `find`, `wait-for-ui` and `screenshot`
- Deliberately excluded from `zig build test`, which must stay runnable without a device. With no simulator booted the suite prints SKIP and exits 0, so it can sit in a pipeline without becoming a flaky gate
- Defaults to Settings (`com.apple.Preferences`), present on every simulator, so it is reproducible on any machine. Point it at your own app with `KURI_E2E_BUNDLE_ID`, `KURI_E2E_LABEL` and `KURI_E2E_APP`
- **Timeout regression guard** — asserts `wait-for-ui` returns within 3x its requested deadline, locking in the 0.4.7 fix where a 3s timeout waited 13.5s
- Assertions are behavioural, not just exit codes: `find` must emit a `tap=` centroid, `uitree` must contain the expected label and device-pixel bounds, and `screenshot` must produce a file with valid PNG magic rather than an empty one
- **Shell-escaping tests** — the Android quoting added in 0.4.8 had no coverage. Now tested against command-injection payloads (`x; rm -rf /`, `$(whoami)`, backticks), embedded single quotes, and an exhaustive sweep asserting no byte in 1..126 can leave an unbalanced quote

### Verified
- `ios install` had never been exercised until now; it installs a real `.app` bundle in ~2.9s and the app launches and reports its accessibility tree correctly

## [0.4.8] — 2026-07-25

### Features — kuri-mobile Android reaches parity
- **`android tools`** — Android now has the same meta tool iOS gained in 0.4.7. Both render from one shared module (`common/toolinfo.zig`), so the two platforms describe themselves identically and an agent can consume `ios tools --json` and `android tools --json` with a single parser. Combined surface is 63 commands (36 iOS, 27 Android)
- **`wait-for-ui` / `find`** — the same polling and query primitives as iOS, backed by the uiautomator hierarchy. `find` exits non-zero on no match so it works directly as an assertion; `wait-for-ui` uses a wall-clock deadline rather than counting sleeps
- **`batch`** — several actions over one adb session (`tap:120,400 type:hi press:enter wait:500 label:Done`), so serial resolution happens once instead of per command
- **`gesture`/`drag` and `touch`** — multi-point paths via `input motionevent` (Android 11+). `input swipe` only ever interpolates between two points, so shaped drags were previously impossible
- **Lifecycle & state** — `uninstall`, `clear` (wipe app data), `openurl`/`navigate`, `keyevent` (raw keycodes), `current-activity`, `logcat` (bounded `-d` read), `screen-info`, `getprop`, `dumpsys`
- **More key names** — `recents`, `wakeup`, `sleep`, `search`, `camera`, `escape`, `backspace`, `notification`

### Internal
- Tool-registry rendering moved to `common/toolinfo.zig`. Shared invariant tests (`verifyTable`, `verifyJson`) run against both platform tables, so a new entry is checked for a summary, a known category, globally unique name/aliases, and JSON round-trip wherever it is added
- Android shell commands that carry user text (package names, URLs, log filters, dumpsys sections) are now single-quote escaped, so a value containing shell metacharacters cannot break out of the constructed command
- iOS tool entries carry an explicit `scope` rather than relying on a per-platform default

### Not implemented
- `android install` and `android record-video` need the adb SYNC protocol (file push/pull), which this client does not implement. Both are called out in the help text rather than left to fail confusingly

## [0.4.7] — 2026-07-25

### Toolchain
- **Zig 0.17.0-dev** — the project, both build files and CI now target `0.17.0-dev.813+2153f8143`. `b.args` became `Run.addPassthruArgs()` and `Allocator.dupeZ` became `dupeSentinel`. The nightly is pinned exactly, since dev tarballs are not permanent. Measured against 0.16.0 on this codebase: cold builds are ~36% slower (40.3s vs 29.6s), warm rebuilds and binary size are unchanged

### Features — kuri-mobile
- **`ios tools`** — the command surface as data. Both the help text and `--json` render from one comptime table, so the dispatcher, the docs and the machine-readable listing cannot drift apart. Each entry carries name, aliases, positional shape, flags and a `scope` of `simulator`/`device`/`simulator+device`, so an agent can distinguish "not supported here" from "not configured yet" without probing
- **`doctor`** — checks the preconditions that otherwise get misdiagnosed at the point of use: developer-dir resolution, `simctl` presence, the macOS Accessibility grant, whether Simulator.app is running, booted device count, and adb reachability. Each failure prints its own remedy. Exits non-zero only on blocking problems
- **`wait-for-ui`** — block until an element appears, or disappears with `--absent`. Polls the accessibility tree rather than the clock, so it returns as soon as the UI is ready and fails loudly when it never is. Replaces sleep-and-hope, which is the main source of flakiness when driving a simulator
- **`find`** — print every element matching a label, with tap-ready centroids. Exits non-zero on no match, so it works directly as a test assertion
- **`batch`** — several actions in one process (`tap:120,400 type:hi key:return wait:500 label:Done`). The win is setup cost: device resolution and window focus happen once for the whole sequence rather than once per command
- **`gesture`/`drag`** — drag along a multi-point path, for motions whose shape matters and that a two-point swipe would flatten
- **`touch down|move|up`** — raw touch primitives for gestures the named commands don't cover
- **`key-sequence`** — press several named keys in order; the whole sequence is validated before anything is pressed, so a typo can't leave the UI half-driven
- **App & device state** — `install`, `uninstall`, `erase`, `open-sim`, `set-location`, `reset-location`, `record-video` (bounded, SIGINT-finalised so the file stays playable), and `keyboard on|off` to control whether the software keyboard appears

### Fixes
- **`wait-for-ui` overshot its timeout by ~4x** — the deadline summed sleep intervals while ignoring the ~0.5s cost of each accessibility poll, so `--timeout 3000` actually waited 13.5s. Now measured against a monotonic clock: 3s requested, 4.2s observed (one final poll)
- **`kuri-mobile --version` reported 0.0.1** — it now tracks the release it ships in

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
