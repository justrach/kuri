<p align="center">
  <img src="kuri.png" alt="Kuri" width="200" />
</p>

<h1 align="center">Kuri 🌰</h1>

<p align="center">
  <a href="https://kuri.trilok.ai/download/latest.json"><img src="https://img.shields.io/badge/stable-v0.6.0-brightgreen?style=flat-square" alt="Stable release"></a>
  <a href="https://github.com/justrach/kuri/blob/main/LICENSE"><img src="https://img.shields.io/github/license/justrach/kuri?style=flat-square" alt="License"></a>
  <img src="https://img.shields.io/badge/zig-0.16.0-f7a41d?style=flat-square" alt="Zig">
  <img src="https://img.shields.io/badge/node__modules-0_files-brightgreen?style=flat-square" alt="node_modules">
  <img src="https://img.shields.io/badge/status-stable-brightgreen?style=flat-square" alt="status">
</p>

## Install

```sh
curl -fsSL https://kuri.trilok.ai/download | sh
```

macOS arm64/x86_64 and Linux x86_64/arm64. Single binary, no runtime deps.

Direct downloads: [macOS arm64](https://kuri.trilok.ai/download/v0.6.0/kuri-v0.6.0-aarch64-macos.tar.gz) · [macOS x86_64](https://kuri.trilok.ai/download/v0.6.0/kuri-v0.6.0-x86_64-macos.tar.gz) · [Linux x86_64](https://kuri.trilok.ai/download/v0.6.0/kuri-v0.6.0-x86_64-linux.tar.gz) · [Linux arm64](https://kuri.trilok.ai/download/v0.6.0/kuri-v0.6.0-aarch64-linux.tar.gz)

---

**Browser automation & web crawling for AI agents. Written in Zig. Zero Node.js.**

CDP automation · A11y snapshots · HAR recording · Standalone fetcher · Interactive terminal browser · Agentic CLI · Security testing · iOS + Android device control

[Quick Start](#-quick-start) · [Benchmarks](#-benchmarks) · [kuri-agent](#-kuri-agent) · [Security Testing](#-security-testing) · [API](#-http-api) · [Skills](#-skills) · [Changelog](CHANGELOG.md)

> **Why teams switch to Kuri:** current Apple Silicon `ReleaseFast` builds stay sub-2 MB per binary, and a fresh Google Flights rerun on 2026-04-23 measured **3,392 tokens** for a full `kuri-agent` loop (`go→snap→click→snap→eval`). Cross-tool deltas should be rerun in the same environment before quoting a percentage.

---

## Why Kuri Wins for Agents

Most browser tooling was built for QA engineers. Kuri is built for agent loops: read the page, keep token cost low, act on stable refs, and move on.

- **135 HTTP endpoints** — full parity with agent-browser and browser-use, from React inspection to Core Web Vitals.
- **7-12% fewer tokens** than agent-browser on real pages thanks to `@eN` ref format and zero-prefix rendering.
- **44x lighter observations** with `/page/state` (48 tokens) vs full snapshot (2,124 tokens) for the same Google Flights page.
- **Batch execution** — `POST /batch` sends N commands in one HTTP call, eliminating N-1 round-trips and N-1 LLM turns.
- **React-compatible** — trusted CDP mouse events and per-character key events fire React 18/19 `onClick` and `onChange`.

### Snapshot tokens: Google Flights `SIN → TPE`

Fresh rerun on 2026-05-24 in this workspace, measured with `wc -c` and `chars/4` approximation.

| Tool / Mode | Chars | ~Tokens | Note |
|---|---:|---:|---|
| `kuri snap` (full) | 8,499 | **2,124** | All nodes + interactive refs |
| `kuri snap` (interactive only) | ~3,000 | **~750** | Best for agent loops |
| `kuri /page/state` | 190 | **48** | Lightweight observation (url, title, scroll%, counts) |
| agent-browser snap (estimated) | ~9,183 | **~2,295** | `[ref=e0]` format overhead |

### Token efficiency: kuri vs agent-browser

| Page | kuri tokens | agent-browser tokens | Savings |
|---|---:|---:|---|
| example.com | 40 | 35 | -13% (trivial page, agent-browser skips root) |
| Hacker News | 386 | ~440 | **12% fewer** |
| Google Flights SIN→TPE | 2,124 | ~2,295 | **7% fewer** |

The savings come from kuri's compact format:
- `@e0` refs (3 chars) vs `[ref=e0]` (9 chars)
- No `- ` prefix per line (saves 2 chars × line count)
- Same indentation, same node filtering

### Full workflow cost: `go → snap → click → snap → eval`

| Tool | Tokens per cycle |
|---|---:|
| **kuri-agent** | **~3,400** |
| With `/page/state` instead of second snap | **~1,700** |
| With `POST /batch` (all in one call) | **~1,700** (same tokens, 1 HTTP call instead of 5) |

### kuri vs libretto

[libretto](https://github.com/saffron-health/libretto) (Playwright + Node) is the closest competitor on per-step token cost. Measured head-to-head on 2026-07-04 — same Chrome, same tab, real `tiktoken` `o200k_base` counts (full methodology and reproduction: **[benchmarks/libretto_comparison.md](benchmarks/libretto_comparison.md)**). The honest split:

| Axis | Winner | Detail |
|---|---|---|
| Latency per call | **kuri** | 4–117 ms vs 1,344–1,500 ms (**13–376× faster** — persistent server vs Node-per-command) |
| Snapshot tokens, typical page | **kuri** | simple 61 vs 151 (2.5×), article 265 vs 363 (1.37×) — tighter grammar |
| Snapshot tokens, large list | split | kuri default 4,424 vs 813 — kuri emits all 259 refs, libretto truncates by default. With `limit=5` kuri renders 555 tokens (**1.46× under libretto**), 34 refs + `… +45 more` markers |
| Trajectory (feed, 9 clicks) | **kuri**, barely | 898 vs 939 tokens (`limit=5` base + diff loop vs exec loop) — parity-to-slight-edge; the morning's 5.1× loss was the untruncated base |
| Repeat runs | **libretto** | compiles trajectories to a Playwright script → 0-token replays; kuri re-pays the loop every run |

**What kuri gained from studying libretto** (all shipped this release): a diff-first loop (`take_snapshot_diff`, ~38 tokens/step); an adaptive diff that falls back to a full snapshot with a `! page replaced` header on navigation; identity-only removal lines; screenshots written to disk (path returned, bytes never enter context); `get_page_state` over MCP; and — after rewriting `parseA11yNodes` as a real DFS tree walk — **opt-in list truncation** (`/snapshot?limit=N`, one `… +K more` line per capped run), **scoped re-capture** (`scope=@ref`), and **hierarchy indentation**, also exposed as `uid`/`limit` on MCP `take_snapshot`. The 9-click feed trajectory that cost 44,285 tokens with naive full re-snapshots costs **898** with a truncated base + diffs — 49× cheaper, and past libretto's 939.

> The older tables above use a `chars/4` token approximation; the libretto comparison uses real `tiktoken` counts. Rerun cross-tool numbers in your own environment before quoting a percentage.

### Binary size and memory

Measured on Apple M4 Pro, macOS 26.4.1. Current binaries were built with `-Doptimize=ReleaseFast`.

| Binary | Current size |
|---|---:|
| `kuri` | 1,093,840 B (1.04 MiB) |
| `kuri-agent` | 629,904 B (615 KiB) |
| `kuri-browse` | 1,089,120 B (1.04 MiB) |
| `kuri-fetch` | 2,063,488 B (1.97 MiB) |

### RSS stayed flat across the Zig 0.16 migration

Measured against the current `v0.4.3` `ReleaseFast` build with `/usr/bin/time -l`.

| Command | `v0.4.3` mean max RSS |
|---|---:|
| `kuri-fetch --version` | ~2.45 MiB |
| `kuri-browse --version` | ~2.45 MiB |
| `kuri-fetch --quiet --dump markdown http://example.com/` | ~9.17 MiB |

## The Problem

Every browser automation tool drags in Playwright (~300 MB), a Node.js runtime, and a cascade of npm dependencies. Your AI agent just wants to read a page, click a button, and move on.
**Kuri is a single Zig binary.** Four modes, zero runtime:

```
kuri           →  CDP server (Chrome automation, a11y snapshots, HAR)
kuri-fetch     →  standalone fetcher (no Chrome, QuickJS for JS, ~2 MB)
kuri-browse    →  interactive terminal browser (navigate, follow links, search)
kuri-agent     →  agentic CLI (scriptable Chrome automation + security testing)
```

---
## 📦 Installation

### One-line install (macOS / Linux)

```sh
curl -fsSL https://raw.githubusercontent.com/justrach/kuri/release-channel/stable/install.sh | sh
```

Detects your platform, downloads the right binary, installs to `~/.local/bin`.
Downloads come from Kuri's self-managed `release-channel` branch. macOS binaries are locally signed with a Developer ID certificate. GitHub Release assets mirror these same tarballs.

### bun / npm

```sh
bun install -g kuri-agent
# or: npm install -g kuri-agent
```

Downloads the correct native binary for your platform at install time.

### Release channel

Kuri's stable binaries live on the `release-channel` branch and are served directly from GitHub raw URLs.

- Stable installer: `https://raw.githubusercontent.com/justrach/kuri/release-channel/stable/install.sh`
- Stable manifest: `https://raw.githubusercontent.com/justrach/kuri/release-channel/stable/latest.json`
- Branch view: `https://github.com/justrach/kuri/tree/release-channel/stable`
- Direct download pattern: `https://raw.githubusercontent.com/justrach/kuri/release-channel/stable/<version>/kuri-<version>-<target>.tar.gz`

### Manual

Download the tarball for your platform from the [stable release manifest](https://raw.githubusercontent.com/justrach/kuri/release-channel/stable/latest.json) or from the [GitHub Releases page](https://github.com/justrach/kuri/releases) and unpack it to your `$PATH`.

Stable install URL:

```sh
curl -fsSL https://raw.githubusercontent.com/justrach/kuri/release-channel/stable/install.sh | sh
```

The manifest includes exact asset URLs plus SHA-256 checksums for `aarch64-linux`, `x86_64-linux`, `aarch64-macos`, and `x86_64-macos`.

### Platform support

| Platform | Status |
|---|---|
| macOS (`aarch64`, `x86_64`) | Prebuilt binaries, signed + notarized |
| Linux (`aarch64`, `x86_64`) | Prebuilt binaries |
| Windows (`x86_64`) | **Experimental — cross-compile only.** `zig build -Dtarget=x86_64-windows-gnu` is CI-verified, but Chrome automation, daemonization, signal-based shutdown, HAR recording, and the file-backed auth store are all stubbed with `error.UnsupportedOnWindows` at runtime. Use **WSL2** if you need the real feature set. Tracked at [#153](https://github.com/justrach/kuri/issues/153). |

Kuri leans on POSIX primitives (`fork`, `clock_gettime`, raw sockets) in several spots, so a full native Windows port is real work. The compile-level baseline above lets the `--version`/`--help` paths and pure in-memory operations run; the gnarly bits (Chrome, sockets, daemonize) need real Win32 implementations before they come off the stub list. If you want to take any of those on, +1 [#153](https://github.com/justrach/kuri/issues/153) or open a PR.

### Build from source

Requires [Zig ≥ 0.16.0](https://ziglang.org/download/).

```bash
git clone https://github.com/justrach/kuri.git
cd kuri
zig build -Doptimize=ReleaseFast
# Binaries in zig-out/bin/: kuri  kuri-agent  kuri-fetch  kuri-browse
```

---

## ⚡ Quick Start

**Requirements:** [Zig ≥ 0.16.0](https://ziglang.org/download/) · Chrome/Chromium (for CDP mode)

```bash
git clone https://github.com/justrach/kuri.git
cd kuri

zig build              # build everything
zig build test         # run 252+ tests

# CDP mode — launches Chrome automatically
./zig-out/bin/kuri

# Standalone mode — no Chrome needed
./zig-out/bin/kuri-fetch https://example.com

# Interactive browser — browse from your terminal
./zig-out/bin/kuri-browse https://example.com

# Experimental standalone browser runtime — separate build, not production
(cd kuri-browser && zig build run -- render https://example.com)
(cd kuri-browser && zig build run -- bench --offline)
```

### First run, shortest path

```bash
# start the server; if CDP_URL is unset, kuri launches managed Chrome for you
./zig-out/bin/kuri

# discover tabs from that managed browser
curl -s http://127.0.0.1:8080/discover

# inspect the discovered tab list
curl -s http://127.0.0.1:8080/tabs
```

### Session-first agent loop

For agent-style HTTP usage, prefer a session header plus `/tab/new`, `/page/info`, and `/snapshot` instead of repeating `tab_id` on every call.

```bash
SESSION=hn-demo
BASE=http://127.0.0.1:8080

curl -s -H "X-Kuri-Session: $SESSION" \
  "$BASE/tab/new?url=https%3A%2F%2Fnews.ycombinator.com"

curl -s -H "X-Kuri-Session: $SESSION" "$BASE/page/info"
SNAP=$(curl -s -H "X-Kuri-Session: $SESSION" "$BASE/snapshot?filter=interactive&format=compact")
MORE_REF=$(printf '%s' "$SNAP" | python3 -c 'import re,sys; print(re.search(r"\"More\" @(e\\d+)", sys.stdin.read()).group(1))')
curl -s -H "X-Kuri-Session: $SESSION" "$BASE/action?action=click&ref=$MORE_REF"
curl -s -H "X-Kuri-Session: $SESSION" "$BASE/page/info"
```

There is also a thin experimental wrapper at `tools/kuri_harness.py` if you want Python helpers on top of the same HTTP surface.

If you already have Chrome running with remote debugging, set `CDP_URL` to either the WebSocket or HTTP endpoint:

```bash
CDP_URL=ws://127.0.0.1:9222/devtools/browser/... ./zig-out/bin/kuri
# or
CDP_URL=http://127.0.0.1:9222 ./zig-out/bin/kuri
```

### Browse vercel.com in 4 commands

```bash
# 1. Discover Chrome tabs
curl -s http://localhost:8080/discover
# → {"discovered":1,"total_tabs":1}

# 2. Get tab ID
curl -s http://localhost:8080/tabs
# → [{"id":"ABC123","url":"chrome://newtab/","title":"New Tab"}]

# 3. Navigate
curl -s "http://localhost:8080/navigate?tab_id=ABC123&url=https://vercel.com"

# 4. Get accessibility snapshot (token-optimized for LLMs)
curl -s "http://localhost:8080/snapshot?tab_id=ABC123&filter=interactive"
# → [{"ref":"e0","role":"link","name":"VercelLogotype"},
#    {"ref":"e1","role":"button","name":"Ask AI"}, ...]
```

---

## 🌐 HTTP API

All endpoints return JSON. Optional auth via `KURI_SECRET` env var. **135 endpoints** — full parity with agent-browser and browser-use.

### Core

| Path | Description |
|------|-------------|
| `GET /health` | Server status, tab count, version |
| `GET /tabs` | List all registered tabs |
| `GET /discover` | Auto-discover Chrome tabs via CDP |
| `GET /tab/current` | Get or set the current tab for an `X-Kuri-Session` |
| `GET /page/info` | Live URL/title/ready-state/viewport/scroll for the active tab |
| `GET /page/state` | Compact page observation: url, title, scroll%, viewport, counts of forms/links/images/inputs |
| `POST /batch` | Execute multiple commands in one HTTP call — returns array of results |
| `GET /browdie` | 🌰 (easter egg) |

### Browser Control

| Path | Params | Description |
|------|--------|-------------|
| `GET /navigate` | `tab_id`, `url` | Navigate tab to URL |
| `GET /tab/new` | `url`, `activate`, `wait` | Create a new tab and optionally hydrate/set current tab |
| `GET /tab/close` | `tab_id` | Close a tab |
| `GET /window/new` | `url`, `activate`, `wait` | Create a new window/tab target |
| `GET /snapshot` | `tab_id`, `filter`, `format` | A11y tree snapshot with `eN` refs. Use `filter=interactive&format=compact` for low-token agent loops. |
| `GET /text` | `tab_id` | Extract page text |
| `GET /screenshot` | `tab_id`, `format`, `quality`, `save` | Capture screenshot (base64); `save=true` writes the PNG to `STATE_DIR/screenshots` and returns `{path,bytes}` instead |
| `GET /screenshot/annotated` | `tab_id` | Screenshot with numbered element labels |
| `GET /screenshot/diff` | `tab_id`, `baseline` | Visual diff between current and baseline screenshots |
| `GET /action` | `tab_id`, `ref`, `action`, `value` | Click/type/fill/select/scroll/hover/dblclick/check/uncheck/blur by ref |
| `GET /evaluate` | `tab_id`, `expression` | Execute JavaScript |
| `GET /evalhandle` | `tab_id`, `expression` | Execute JS, return objectId handle (not value) |
| `GET /close` | `tab_id` | Close tab + cleanup |
| `GET /bringtofront` | `tab_id` | Bring tab to front |

### Actions

| Path | Params | Description |
|------|--------|-------------|
| `GET /clear` | `ref` | Clear input field value |
| `GET /selectall` | `ref` | Select all text in input/contenteditable |
| `GET /setvalue` | `ref`, `value` | Set input value directly (bypasses key events) |
| `GET /dispatch` | `ref`, `type` | Dispatch custom DOM event on element |
| `GET /boundingbox` | `ref` | Get element bounding rect (x, y, width, height, centerX, centerY) |
| `GET /getattribute` | `ref`, `name` | Get element attribute by name |
| `GET /inputvalue` | `ref` | Get current input element value |
| `GET /element/state` | `ref`, `check` | Quick boolean: `exists`, `visible`, `enabled`, `checked` |
| `GET /find-element` | `text`/`role`/`label`/`placeholder`/`testid` | Semantic locator — find element without snap |
| `GET /highlight` | `ref` or `selector` | Highlight element with overlay |

### Mouse & Touch

| Path | Params | Description |
|------|--------|-------------|
| `GET /mouse/move` | `x`, `y` | Move mouse to coordinates |
| `GET /mouse/down` | `x`, `y`, `button` | Mouse button down |
| `GET /mouse/up` | `x`, `y`, `button` | Mouse button up |
| `GET /mouse/wheel` | `x`, `y`, `deltaX`, `deltaY` | Mouse wheel scroll |
| `GET /tap` | `x`, `y` | Touch tap (touchStart + touchEnd) |
| `GET /swipe` | `startX`, `startY`, `endX`, `endY` | Touch swipe gesture |
| `GET /drag` | `src_ref`, `tgt_ref` | Drag element to target |

### Keyboard

| Path | Params | Description |
|------|--------|-------------|
| `GET /keyboard/type` | `tab_id`, `text` | Type text via key events |
| `GET /keyboard/inserttext` | `tab_id`, `text` | Insert text directly |
| `GET /keydown` | `tab_id`, `key` | Key down event |
| `GET /keyup` | `tab_id`, `key` | Key up event |

### Content Extraction

| Path | Description |
|------|-------------|
| `GET /markdown` | Convert page to Markdown |
| `GET /links` | Extract all links |
| `GET /dom/query` | CSS selector query |
| `GET /dom/html` | Get element HTML |
| `GET /dom/attributes` | Get element attributes |
| `GET /pdf` | Print page to PDF |
| `GET /find` | In-page text search |

### Waiting

| Path | Params | Description |
|------|--------|-------------|
| `GET /wait` | `selector`, `text`, `url`, `state`, `visible`, `timeout` | Wait for selector/text/URL pattern/networkidle/load state |
| `GET /wait/function` | `expression`, `timeout` | Wait for arbitrary JS expression to be truthy |
| `GET /wait/download` | `timeout` | Wait for file download to complete |

### Dialog Handling

| Path | Description |
|------|-------------|
| `GET /dialog/auto` | Auto-handle all JS dialogs (accept or dismiss) |
| `GET /dialog/accept` | Accept current dialog (with optional prompt text) |
| `GET /dialog/dismiss` | Dismiss current dialog |

### Network & HAR

| Path | Description |
|------|-------------|
| `GET /har/start` | Start recording network traffic |
| `GET /har/stop` | Stop + return HAR 1.2 JSON |
| `GET /har/status` | Recording state + entry count |
| `GET /har/replay` | API map with curl/fetch/python code snippets |
| `GET /cookies` | Get cookies |
| `GET /cookies/set` | Set cookies |
| `GET /cookies/delete` | Delete cookies |
| `GET /cookies/clear` | Clear all cookies |
| `GET /headers` | Set custom request headers |
| `GET /intercept/start` | Start request interception |
| `GET /intercept/stop` | Stop request interception |
| `GET /intercept/requests` | List intercepted requests |
| `GET /request/detail` | Get response body for a request ID |
| `GET /response/body` | Fetch URL and return response body |
| `GET /network` | Network traffic stats |
| `GET /download` | Trigger file download |

### Navigation & State

| Path | Description |
|------|-------------|
| `GET /back` | Browser back |
| `GET /forward` | Browser forward |
| `GET /reload` | Reload page |
| `GET /stop` | Stop page loading |
| `GET /pushstate` | SPA navigation via history.pushState |
| `GET /storage/local` | Get/set localStorage |
| `GET /storage/session` | Get/set sessionStorage |
| `GET /storage/local/clear` | Clear localStorage |
| `GET /storage/session/clear` | Clear sessionStorage |
| `GET /session/save` | Save browser session |
| `GET /session/load` | Restore browser session |
| `GET /session/list` | List saved sessions |
| `GET /setcontent` | Set page HTML directly (POST) |

### Auth Profiles

| Path | Description |
|------|-------------|
| `GET /auth/profile/save` | Save cookies + storage as a named auth profile |
| `GET /auth/profile/load` | Restore a named auth profile into a tab |
| `GET /auth/profile/list` | List saved auth profiles |
| `GET /auth/profile/delete` | Delete a saved auth profile |
| `GET /auth/extract` | Extract auth tokens (JWT, cookies, headers) |
| `GET /set/credentials` | Set HTTP basic auth credentials |

On macOS, auth profile secrets are stored in the user Keychain.

### Emulation

| Path | Params | Description |
|------|--------|-------------|
| `GET /emulate` | device type, screen size | Device emulation |
| `GET /set/viewport` | `width`, `height` | Set viewport size |
| `GET /set/useragent` | `ua` | Set user agent |
| `GET /set/media` | `media` | Emulate media type |
| `GET /set/offline` | `offline` | Toggle offline mode |
| `GET /geolocation` | `lat`, `lng` | Override geolocation |
| `GET /timezone` | `timezone` | Override timezone (e.g. `America/New_York`) |
| `GET /locale` | `locale` | Override locale (e.g. `en-US`) |
| `GET /permissions` | `name`, `state` | Grant/deny permissions (geolocation, notifications, clipboard) |

### Scripts & Injection

| Path | Description |
|------|-------------|
| `GET /script/inject` | Inject JavaScript into page (persists across nav) |
| `GET /initscript/remove` | Remove a previously injected init script |
| `GET /addstyle` | Inject CSS stylesheet |
| `GET /expose` | Expose a named function to page JS context |

### React Inspection

| Path | Description |
|------|-------------|
| `GET /react/tree` | React component tree via DevTools hook |
| `GET /react/inspect` | React component props and state |
| `GET /react/renders` | React render tracking (start/stop) |
| `GET /react/suspense` | React Suspense boundary status |

### Recording & Performance

| Path | Description |
|------|-------------|
| `GET /recording/start` | Record user actions (click, input, navigate) |
| `GET /recording/stop` | Stop recording + return action log |
| `GET /vitals` | Core Web Vitals (LCP, CLS, FID, TTFB, FCP, domInteractive) |
| `GET /perf/lcp` | Largest Contentful Paint timing |
| `GET /trace/start` | Start performance trace |
| `GET /trace/stop` | Stop trace |
| `GET /profiler/start` | Start JS profiler |
| `GET /profiler/stop` | Stop profiler |

### Debugging

| Path | Description |
|------|-------------|
| `GET /debug/enable` | Enable in-page debug HUD and optional freeze mode |
| `GET /debug/disable` | Disable in-page debug HUD |
| `GET /inspect` | Element inspection |
| `GET /errors` | Collect JS errors |
| `GET /console` | Read console logs |
| `GET /frames` | List page frames |
| `GET /frame` | Switch to iframe context by name or URL |
| `GET /mainframe` | Switch back to main frame |
| `GET /diff/snapshot` | Compact `+`/`~`/`-` diff vs the previous call for this tab — the token-efficient action loop (aliased by `/snapshot/changes`). Falls back to a full snapshot with a `! page replaced` header on mass change. |
| `GET /diff/url` | Compare two URLs side by side (navigate, snapshot, diff) |

### Streaming

| Path | Description |
|------|-------------|
| `GET /screencast/start` | Start screen recording |
| `GET /screencast/stop` | Stop screen recording |
| `GET /video/start` | Start video capture |
| `GET /video/stop` | Stop video capture |
| `GET /ws/start` | WebSocket tunnel start |
| `GET /ws/stop` | WebSocket tunnel stop |

### Agent-friendly loop

The lowest-friction server loop is:

1. `GET /tab/new?url=...`
2. `GET /page/state` (lightweight) or `GET /snapshot?filter=interactive&format=compact` (full)
3. `GET /action?action=click&ref=eN`
4. Repeat — or use `POST /batch` for multi-step operations in one call

`url` and `expression` query params are percent-decoded. Send `X-Kuri-Session: my-agent` to persist tab context server-side.
---

## 🧠 Skills

The repo includes a user-extensible skill area:

- `skills/kuri-skill.md` is the base Kuri HTTP-agent skill
- `skills/custom/` is reserved for your own project-specific skills
- `skills/custom/hackernews-page-2.md` is a concrete example custom skill
- `.claude/skills/kuri-server/SKILL.md` stays in sync for Claude-style repo skills

The base skill now also explains which browser path to use:

- `kuri` HTTP API: production Chrome/CDP automation with sessions, snapshots, actions, HAR, cookies, and screenshots
- `kuri-fetch`: standalone no-Chrome fetch/text extraction
- `kuri-browse`: interactive terminal browsing
- `kuri-agent`: scriptable CLI automation against the Kuri server
- `kuri-browser/`: experimental separate Zig-native browser runtime for parity work

For the experimental browser CLI:

```bash
cd kuri-browser
zig build run -- render https://news.ycombinator.com --selector ".titleline a" --dump text
zig build run -- render https://todomvc.com/examples/react/dist/ --js --wait-eval "document.querySelectorAll('.todo-list li').length >= 1"
zig build run -- parity --offline
zig build run -- bench --offline
zig build run -- serve-cdp --port 9333
```

`kuri-browser serve-cdp` exposes Chrome-style HTTP discovery plus a minimal WebSocket JSON-RPC router for protocol smoke tests. Runtime eval returns V8-shaped CDP remote objects backed by QuickJS; this does not add a V8 dependency and is not full Playwright/Puppeteer compatibility yet.

Screenshots in `kuri-browser` currently delegate to the main Kuri/CDP renderer. Start `./zig-out/bin/kuri` first, then:

```bash
cd kuri-browser
zig build run -- screenshot https://example.com --out example.jpg --compress --kuri-base http://127.0.0.1:8080
```

`--compress` captures a PNG baseline and JPEG candidate, writes the smaller file, and reports byte savings. Current local measurement on `https://example.com`: `20,523` bytes PNG to `18,183` bytes JPEG quality 50, saving `2,340` bytes or `11%`.

### Advanced

| Path | Description |
|------|-------------|
| `GET /diff/snapshot` | Compact `+`/`~`/`-` delta vs the previous snapshot (agent action loop) |
| `GET /emulate` | Device emulation |
| `GET /geolocation` | Set geolocation |
| `POST /upload` | File upload |
| `GET /script/inject` | Inject JavaScript |
| `GET /intercept/start` | Start request interception |
| `GET /intercept/stop` | Stop interception |
| `GET /screenshot/annotated` | Screenshot with element annotations |
| `GET /screenshot/diff` | Visual diff between screenshots |
| `GET /screencast/start` | Start screencast |
| `GET /screencast/stop` | Stop screencast |
| `GET /video/start` | Start video recording |
| `GET /video/stop` | Stop video recording |
| `GET /console` | Get console messages |
| `GET /stop` | Stop page loading |
| `GET /get` | Direct HTTP fetch (server-side) |
| `GET /scrollintoview` | Scroll a referenced element into view |
| `GET /drag` | Drag from one ref to another |
| `GET /keyboard/type` | Type text with key events |
| `GET /keyboard/inserttext` | Insert text directly |
| `GET /keydown` | Dispatch a keydown event |
| `GET /keyup` | Dispatch a keyup event |
| `GET /wait` | Wait for ready state or element conditions |
| `GET /tab/close` | Close a tab |
| `GET /highlight` | Highlight an element by ref or selector |
| `GET /errors` | Get page/runtime errors |
| `GET /set/offline` | Toggle offline network emulation |
| `GET /set/media` | Set emulated media features |
| `GET /set/credentials` | Set HTTP basic auth credentials |
| `GET /find` | Find text matches in the current page |
| `GET /trace/start` | Start Chrome tracing |
| `GET /trace/stop` | Stop tracing and return trace data |
| `GET /profiler/start` | Start JS profiler |
| `GET /profiler/stop` | Stop JS profiler |
| `GET /inspect` | Inspect an element or page state |
| `GET /set/viewport` | Set viewport size |
| `GET /set/useragent` | Override user agent |
| `GET /dom/attributes` | Get element attributes |
| `GET /frames` | List frame tree |
| `GET /network` | Inspect network state/requests |

---

## 🛡️ Stealth & Bot Evasion

Kuri applies anti-detection patches automatically on startup — no manual config needed.

### What's applied

- **`Page.addScriptToEvaluateOnNewDocument`** — stealth patches run before any page JS
- **navigator.webdriver = false** — hides automation flag at Chromium level (`--disable-blink-features=AutomationControlled`)
- **WebGL/Canvas/AudioContext spoofing** — defeats fingerprint-based detection
- **UA rotation** — 5 realistic Chrome/Safari/Firefox user agents
- **chrome.csi/chrome.loadTimes** — stubs for Akamai-specific checks

### Bot block detection

Navigate auto-detects blocks and returns structured fallback:

```bash
curl -s "http://localhost:8080/navigate?tab_id=ABC&url=https://protected-site.com"
# If blocked:
# {"blocked":true,"blocker":"akamai","ref_code":"0.7d...",
#  "fallback":{"suggestions":["Open URL directly in browser","Use KURI_PROXY"]}}
# If ok: normal CDP response
```

Detects: **Akamai**, **Cloudflare**, **PerimeterX**, **DataDome**, generic captcha.

### Proxy support

```bash
KURI_PROXY=socks5://user:pass@residential-proxy:1080 ./zig-out/bin/kuri
KURI_PROXY=http://proxy:8080 ./zig-out/bin/kuri
```

### Tested sites

| Site | Protection | Result |
|------|-----------|--------|
| Singapore Airlines | Akamai WAF | ✅ Bypassed (was blocked before v0.4.0) |
| Shopee SG | Custom anti-fraud | ✅ Page loads, redirects to login |
| Google Flights | None | ✅ Full interaction |
| Booking.com | PerimeterX | ⚠️ Needs proxy |

---

## 🔧 kuri-fetch

Standalone HTTP fetcher — no Chrome, no Playwright, no npm. Ships as a ~2 MB binary with built-in QuickJS for JS execution.

```bash
zig build fetch    # build + run

# Default: convert to Markdown
kuri-fetch https://example.com

# Extract links
kuri-fetch -d links https://news.ycombinator.com

# Structured JSON output
kuri-fetch --json https://example.com

# Execute inline scripts via QuickJS
kuri-fetch --js https://example.com

# Write to file, quiet mode
kuri-fetch -o page.md -q https://example.com

# Pipe-friendly: content → stdout, status → stderr
kuri-fetch -d text https://example.com | wc -w
```

### Features

- **5 output modes** — `markdown`, `html`, `links`, `text`, `json`
- **QuickJS JS engine** — `--js` executes inline `<script>` tags
- **DOM stubs** — `document.querySelector`, `getElementById`, `window.location`, `document.title`, `console.log`, `setTimeout` (SSR-style)
- **SSRF defense** — blocks private IPs, metadata endpoints, non-HTTP schemes
- **Colored output** — respects `NO_COLOR`, `TERM=dumb`, `--no-color`, TTY detection
- **File output** — `-o` / `--output` with byte count + timing summary
- **Custom UA** — `--user-agent` flag
- **Quiet mode** — `-q` suppresses stderr status

---

## 🌐 kuri-browse

Interactive terminal browser — browse the web from your terminal. No Chrome needed.

```bash
zig build browse   # build + run

kuri-browse https://example.com
```

```
🌰 kuri-browse — terminal browser
→ loading https://example.com

# Example Domain
This domain is for use in documentation examples...
Learn more [1]

───── Links ─────
  [1] https://iana.org/domains/example

✓ 528 bytes, 1 links (133ms)
[nav] https://example.com> 1     ← type 1 to follow the link
```

### Commands

| Command | Action |
|---------|--------|
| `<number>` | Follow link [N] |
| `<url>` | Navigate (if contains `.`) |
| `:go <url>` | Navigate to URL |
| `:back`, `:b` | Go back in history |
| `:forward`, `:f` | Go forward |
| `:reload`, `:r` | Re-fetch current page |
| `:links`, `:l` | Show link index |
| `/<term>` | Search in page (highlights matches) |
| `:search <t>` | Search in page |
| `:n`, `:next` | Re-highlight search |
| `:history` | Show navigation history |
| `:help`, `:h` | Show all commands |
| `:quit`, `:q` | Exit |

### Features

- **Colored markdown rendering** — headings, links, code blocks, bold, blockquotes
- **Numbered links** — every link gets `[N]`, type the number to follow it
- **Navigation history** — back/forward like a real browser
- **In-page search** — `/term` highlights all matches
- **Relative URL resolution** — follows links naturally across pages
- **Smart filtering** — skips `javascript:` and `mailto:` hrefs

---

## 🤖 kuri-agent

Scriptable CLI for Chrome automation — drives the browser command-by-command from your terminal or shell scripts. Shares session state across invocations via `~/.kuri/session.json`.

```bash
zig build agent   # build kuri-agent

# 1. Find a Chrome tab
kuri-agent tabs
# → ws://127.0.0.1:9222/devtools/page/ABC123  https://example.com

# 2. Attach to it
kuri-agent use ws://127.0.0.1:9222/devtools/page/ABC123

# 3. Navigate + interact
kuri-agent go https://example.com
kuri-agent snap --interactive        # → [{"ref":"e0","role":"link","name":"More info"}]
kuri-agent click e0
kuri-agent shot                      # saves ~/.kuri/screenshots/<ts>.png
```

### Commands

| Command | Description |
|---------|-------------|
| `tabs [--port N]` | List Chrome tabs |
| `use <ws_url>` | Attach to a tab (saves session) |
| `open [url] [--port N]` | Open a new tab (optionally navigating to url) |
| `status` | Show current session |
| `go <url>` | Navigate to URL |
| `snap [--interactive] [--json] [--text] [--depth N]` | A11y snapshot, saves `eN` refs |
| `click <ref>` | Click element by ref (CDP mouse events, React-compatible) |
| `type <ref> <text>` | Type into element (per-character key events, React-compatible) |
| `fill <ref> <text>` | Fill input value |
| `select <ref> <value>` | Select dropdown option |
| `hover <ref>` | Hover over element |
| `focus <ref>` | Focus element |
| `scroll` | Scroll the page |
| `viewport [width height]` | Get or set viewport dimensions |
| `eval <js>` | Evaluate JavaScript |
| `text [selector]` | Get page text |
| `shot [--out file.png]` | Screenshot |
| `back` | Navigate back |
| `forward` | Navigate forward |
| `reload` | Reload current page |
| `cookies` | List cookies with security flags |
| `headers` | Check security response headers |
| `audit` | Full security audit |
| `storage [local\|session\|all]` | Dump localStorage / sessionStorage |
| `jwt` | Extract and decode JWTs from cookies and storage |
| `fetch <method> <url> [--data <json>]` | Authenticated fetch using page cookies |
| `probe <url-template> <start> <end>` | IDOR probe: iterate numeric IDs in URL |
| `grab <ref>` | Click ref, intercept `window.open`, follow redirect in-tab |
| `wait-for-tab [--port N]` | Poll for a new tab, auto-switch session |
| `stealth` | Apply anti-detection patches |
| `set-header <name> <value>` | Add a custom header to all requests |
| `show-headers` | Show stored extra headers |
| `clear-headers` | Remove all extra headers |
---

## 📱 kuri-mobile (iOS + Android)

Native Zig CLI for driving iOS Simulators, real iPhones (listing + launch/terminate), and Android devices/emulators — inspired by [`mobile-device-mcp`](https://github.com/srmorete/mobile-device-mcp), reimplemented in Zig with no Bun/Node/Gradle/Xcode in the build path.

```bash
cd kuri-mobile && zig build && cp zig-out/bin/kuri-mobile ../zig-out/bin/

# The main `kuri` binary forwards android/ios subcommands to kuri-mobile:
kuri ios list-devices                              # sims + real devices (usbmuxd, native)
kuri ios openurl https://example.com               # navigate Safari
kuri ios screenshot out.png                        # auto-picks booted sim
kuri ios launch com.apple.Preferences

kuri android list-devices                          # native Zig adb wire-protocol client
kuri android tap 540 1200
kuri android swipe 100 1500 100 500
kuri android screenshot phone.png
kuri android uitree                                # flat element list via uiautomator dump
```

**What's native Zig:** adb host protocol (libc sockets, 4-hex framing over `host:transport:`/`shell:`/`exec:`), Android XML UI tree parser, usbmuxd `ListDevices` plist client.
**What shells out:** `xcrun simctl` (iOS Simulator), `xcrun devicectl` (iOS real-device launch/terminate).
**Driverless by design:** no on-device app is installed, so `run_code` sandboxes and XCUITest-backed tap/uitree on real iOS devices are intentionally **not** available. See [`kuri-mobile/README.md`](kuri-mobile/README.md) for the full parity matrix vs upstream.

---

## 🔒 Security Testing

`kuri-agent` supports browser-native security trajectories — log in once, then run reconnaissance and header/cookie audits without leaving the terminal.

### Trajectories

**Enumerate → Inspect** — after authenticating, dump auth cookies and check security flags:

```bash
kuri-agent go https://target.example.com/login
kuri-agent snap --interactive
kuri-agent fill e2 myuser
kuri-agent fill e3 mypassword
kuri-agent click e4                  # submit login

kuri-agent cookies
# cookies (3):
#   session_id  domain=.example.com path=/  [Secure] [HttpOnly] [SameSite=Strict]
#   csrf_token  domain=.example.com path=/  [Secure] [!HttpOnly]
#   tracking    domain=.example.com path=/  [!Secure] [!HttpOnly]
```

**Header audit** — check what security headers the target sends:

```bash
kuri-agent go https://target.example.com
kuri-agent headers
# → {"url":"https://...","status":200,"headers":{
#     "content-security-policy":"default-src 'self'",
#     "strict-transport-security":"max-age=31536000",
#     "x-frame-options":"(missing)",
#     "x-content-type-options":"nosniff", ...}}
```

**Full audit** — HTTPS, missing headers, JS-visible cookies in one shot:

```bash
kuri-agent audit
# → {"protocol":"https:","url":"https://...","score":6,
#     "issues":["MISSING:x-frame-options","COOKIES_EXPOSED_TO_JS:2"],
#     "headers":{"content-security-policy":"default-src 'self'", ...}}
```

**Cross-account trajectory** — use `eval` to replay API calls with different tokens:

```bash
# After login, grab the auth token from localStorage
kuri-agent eval "localStorage.getItem('token')"

# Probe a resource ID with the current session
kuri-agent eval "fetch('/api/assessments/42').then(r=>r.status)"

# Check for IDOR: does a different user's resource return 200 or 403?
kuri-agent eval "fetch('/api/assessments/99').then(r=>r.status)"
```

### Trajectory Report Format

kuri-agent outputs JSON suitable for pipeline integration. Each security command emits a single JSON line — pipe through `jq` for triage:

```bash
kuri-agent audit | jq '.issues[]'
kuri-agent cookies | head -20
kuri-agent headers | jq '.headers | to_entries[] | select(.value == "(missing)") | .key'
```

---


## 🏗 Architecture

```
┌──────────────────────────────────────────────────────────┐
│                     HTTP API Layer                        │
│         (std.http.Server, thread-per-connection)          │
├──────────────┬──────────────────┬────────────────────────┤
│   Browser    │  Crawler Engine  │   kuri-fetch / browse   │
│   Bridge     │                  │   (standalone CLIs)     │
├──────────────┼──────────────────┼────────────────────────┤
│ CDP Client   │ URL Validator    │ std.http.Client         │
│ Tab Registry │ HTML→Markdown    │ QuickJS JS Engine       │
│ A11y Snapshot│ Link Extractor   │ DOM Stubs (Layer 3)     │
│ Ref Cache    │ Text Extractor   │ SSRF Validator          │
│ HAR Recorder │                  │ Colored Renderer        │
│ Stealth JS   │                  │ History + REPL          │
├──────────────┴──────────────────┴────────────────────────┤
│  Chrome Lifecycle Manager                                 │
│  (launch, health-check, auto-restart, port detection)     │
└──────────────────────────────────────────────────────────┘
```

### Memory Model

- **Arena-per-request** — all per-request memory freed in one `deinit()` call
- **No GC** — `GeneralPurposeAllocator` in debug mode catches every leak
- **Proper cleanup chains** — `Launcher → Bridge → CdpClients → HarRecorders → Snapshots → Tabs`
- **`errdefer` guards** — partial failures roll back cleanly

### Chrome Lifecycle

| Mode | Behavior |
|------|----------|
| **Managed** (no `CDP_URL`) | Launches Chrome headless, finds free CDP port, supervises, auto-restarts on crash (max 3 retries), kills on shutdown |
| **External** (`CDP_URL` set) | Connects to existing Chrome, health-checks via `/json/version`, does NOT kill on shutdown |

---

## 📁 Structure

```
kuri/
├── build.zig                  # Build system (Zig 0.16.0)
├── build.zig.zon              # Package manifest + QuickJS dep
├── src/
│   ├── main.zig               # CDP server entry point
│   ├── fetch_main.zig         # kuri-fetch CLI entry point
│   ├── browse_main.zig        # kuri-browse CLI entry point
│   ├── js_engine.zig          # QuickJS wrapper + DOM stubs
│   ├── bench.zig              # Benchmark harness
│   ├── chrome/
│   │   └── launcher.zig       # Chrome lifecycle manager
│   ├── server/
│   │   ├── router.zig         # HTTP route dispatch (40+ endpoints)
│   │   ├── middleware.zig     # Auth (constant-time comparison)
│   │   └── response.zig      # JSON response helpers
│   ├── bridge/
│   │   ├── bridge.zig         # Central state (tabs, CDP, HAR, snapshots)
│   │   └── config.zig         # Env var configuration
│   ├── cdp/
│   │   ├── client.zig         # CDP WebSocket client
│   │   ├── websocket.zig      # WebSocket frame codec
│   │   ├── protocol.zig       # CDP method constants
│   │   ├── actions.zig        # High-level CDP actions
│   │   ├── stealth.zig        # Bot detection bypass
│   │   └── har.zig            # HAR 1.2 recorder
│   ├── snapshot/
│   │   ├── a11y.zig           # A11y tree with interactive filter
│   │   ├── diff.zig           # Snapshot delta diffing
│   │   └── ref_cache.zig      # eN ref → node ID cache
│   ├── crawler/
│   │   ├── validator.zig      # SSRF defense, URL validation
│   │   ├── markdown.zig       # HTML → Markdown (SIMD tag counting)
│   │   ├── fetcher.zig        # Page fetching
│   │   ├── extractor.zig      # Readability extraction
│   │   └── pipeline.zig       # Parallel crawl pipeline
│   ├── storage/
│   │   ├── local.zig          # Local file writer
│   │   └── r2.zig             # R2/S3 uploader
│   ├── util/
│   │   └── json.zig           # JSON helpers
│   └── test/
│       ├── harness.zig        # Test HTTP client
│       ├── integration.zig    # Integration tests
│       └── merjs_e2e.zig      # E2E tests
├── js/
│   ├── stealth.js             # Bot detection bypass
│   └── readability.js         # Content extraction
├── kuri-browser/              # Native Zig rendering experiments
└── kuri-mobile/               # iOS + Android device control (Zig-native adb + usbmuxd)
    ├── src/
    │   ├── common/            # io helpers, unified UI tree parser
    │   ├── android/           # adb wire protocol client, driver, CLI
    │   └── ios/               # simctl, usbmuxd, devicectl, CLI
    └── README.md              # Full parity matrix vs mobile-device-mcp
```

---

## ⚙️ Configuration

| Env Var | Default | Description |
|---------|---------|-------------|
| `HOST` | `127.0.0.1` | Server bind address |
| `PORT` | `8080` | Server port |
| `CDP_URL` | *(none)* | Connect to existing Chrome (`ws://...` or `http://127.0.0.1:9222`) |
| `KURI_SECRET` | *(none)* | Auth secret for API requests |
| `STATE_DIR` | `.kuri` | Session state directory |
| `REQUEST_TIMEOUT_MS` | `30000` | HTTP request timeout |
| `NAVIGATE_TIMEOUT_MS` | `30000` | Navigation timeout |
| `STALE_TAB_INTERVAL_S` | `30` | Stale tab cleanup interval |
| `NO_COLOR` | *(none)* | Disable colored CLI output |

---

## 💰 Token Cost

For a 50-page monitoring task (from Pinchtab benchmarks):

| Method | Tokens | Cost ($) | Best For |
|--------|--------|----------|----------|
| `/text` | ~40,000 | $0.20 | Read-heavy (13× cheaper than screenshots) |
| `/snapshot?filter=interactive&format=compact` | ~40,000 | $0.20 | Low-token element interaction |
| `/snapshot` (full) | ~525,000 | $2.63 | Full page understanding |
| `/screenshot` | ~100,000 | $1.00 | Visual verification |

---

## 🤝 Contributing

Open an issue before submitting a large PR so we can align on the approach.

```bash
git clone https://github.com/justrach/kuri.git
cd kuri
zig build test         # 252+ tests must pass
zig build test-fetch   # kuri-fetch tests (69 tests)
zig build test-browse  # kuri-browse tests (22 tests)
```

See [CONTRIBUTORS.md](CONTRIBUTORS.md) for guidelines.

---

## Credits

| Project | What we borrowed |
|---------|-----------------|
| [agent-browser](https://github.com/vercel-labs/agent-browser) | `@eN` ref system, snapshot diffing, HAR recording patterns |
| [Pinchtab](https://github.com/pinchtab/pinchtab) | Browser control architecture for AI agents |
| [Pathik](https://github.com/justrach/pathik) | High-performance crawling patterns |
| [QuickJS-ng](https://github.com/nicklausw/quickjs-ng) via [mitchellh/zig-quickjs-ng](https://github.com/mitchellh/zig-quickjs-ng) | JS engine for `kuri-fetch` |
| [Lightpanda](https://github.com/lightpanda-io/browser) | Zig-native headless browser pioneer, CDP compatibility patterns |
| [Zig 0.16.0](https://ziglang.org) | The whole stack |

## License

Apache-2.0
