---
name: pi-kuri-skills
description: Kuri browser automation for pi.dev agents — navigate, screenshot, extract content, and interact with web pages via the Kuri HTTP server. Use when an agent needs to browse the web, read pages, take screenshots, or perform browser interactions. This is the pi.dev core skill — read skills/pi-kuri-advanced.md for click, type, fill, scroll, JavaScript evaluation, cookies, security audits, and more.
---

# Pi Kuri Skills

Kuri is a Zig-native browser automation server. Use its HTTP API for agent-driven
browser automation — no Node.js, no Playwright, no Python dependencies.

This skill has two tiers:

| Tier | Covered here | When to use |
|------|-------------|-------------|
| **Core** 🟢 | Server health check, start/stop, navigate, screenshot, page info, text & markdown extraction, links, accessibility snapshots | Most tasks |
| **Advanced** 🔵 | Click, type, fill, select, scroll, JS eval, cookies, audit, HAR recording, tab management, session control, experimental kuri-browser | Read `skills/pi-kuri-advanced.md` on demand when you need them |

---

## 1. Setup — Validate & Start

### Check if Kuri is running

```bash
curl -s http://127.0.0.1:8080/health
```

A healthy server returns `{"ok":true}` with the server version.

If the health check fails — connection refused or timeout — the server is not running.

### Start Kuri

If you built from source:

```bash
# From the repo root
zig build
./zig-out/bin/kuri
```

If you installed via the script:

```bash
kuri
```

Kuri starts a Chrome instance (managing it automatically) and listens on
`http://127.0.0.1:8080` by default. Customize with `HOST`, `PORT`, `CDP_URL`
(see the configuration table in the README).

### List available tabs

```bash
curl -s http://127.0.0.1:8080/tabs
```

Returns the active session's tabs with their IDs, URLs, and titles.

---

## 2. Core Operations

All examples use `curl` against the default server at `http://127.0.0.1:8080`.
Set `BASE=http://127.0.0.1:8080` and `SESSION=my-session` for reuse.

### Create a tab and navigate

```bash
# Open a new tab (session-scoped with X-Kuri-Session header)
curl -s -H "X-Kuri-Session: my-session" \
  "http://127.0.0.1:8080/tab/new?url=https%3A%2F%2Fexample.com"
```

### Get page info

```bash
curl -s -H "X-Kuri-Session: my-session" \
  "http://127.0.0.1:8080/page/info"
```

Returns `url`, `title`, and page `readyState`. Always call this after navigation
to confirm the page loaded before taking further actions.

### Screenshot

```bash
curl -s -H "X-Kuri-Session: my-session" \
  "http://127.0.0.1:8080/screenshot" -o screenshot.png
```

Returns a PNG. Add `?format=jpeg&quality=80` for smaller files.

### Content extraction

```bash
# Plain text
curl -s -H "X-Kuri-Session: my-session" \
  "http://127.0.0.1:8080/text"

# Markdown
curl -s -H "X-Kuri-Session: my-session" \
  "http://127.0.0.1:8080/markdown"

# All links
curl -s -H "X-Kuri-Session: my-session" \
  "http://127.0.0.1:8080/links"
```

### Accessibility snapshot (interactive refs)

```bash
curl -s -H "X-Kuri-Session: my-session" \
  "http://127.0.0.1:8080/snapshot?filter=interactive&format=compact"
```

Returns a compact text-tree of interactive elements with refs like `@e0`, `@e1`.
These refs are used as targets for advanced actions (click, type, fill, etc.).

**Re-snap after any navigation or DOM change** — refs are snapshot-local and
become stale once the page updates.

---

## 3. Advanced Operations

Kuri supports many more operations: click, right-click, double-click, hover,
type, fill, select dropdowns, scroll, JavaScript evaluation, cookies,
security audits, HAR recording, tab and session management, and the
experimental `kuri-browser` CLI.

For full details, read:

```
skills/pi-kuri-advanced.md
```

**What's in the advanced file at a glance:**

| Category | Capabilities |
|----------|-------------|
| 🖱️ Mouse | click, right-click, double-click, hover |
| ⌨️ Keyboard | type text, fill input, select option, press keys |
| 📜 Scroll | up, down, left, right, pixel-amount, element-scroll |
| 🧠 JS Eval | arbitrary JavaScript, return values |
| 🍪 Cookies | list, inspect security flags |
| 🔒 Security | audit headers, cookies, HTTPS, mixed content |
| 📡 HAR | HTTP archive recording (start, stop, export) |
| 📑 Tabs | create, close, list, switch, multi-tab workflows |
| 🔄 Sessions | X-Kuri-Session grouping, multi-session orchestration |
| 🧪 Experimental | kuri-browser render, bench, parity, serve-cdp |

Read the advanced file only when you need one of those capabilities. The
detailed instructions, endpoint signatures, and workflow examples live there.

---

## Tips

- **Prefer `X-Kuri-Session`** over repeating `tab_id` — sessions group tabs
  and Kuri tracks the current tab for you.
- **Call `/page/info` before acting** — confirm the right page is loaded.
- **Use `filter=interactive&format=compact`** for snapshot in agent loops.
  Reserve `format=json` for programmatic parsing.
- **Read snapshot `state`** before acting on controls — check for
  `checked`, `disabled`, `readonly`, `expanded`, `selected` properties.
- **Treat refs as snapshot-local** — refresh after navigation or DOM updates.
- **`KURI_ALLOW_PRIVATE=1`** — if you need to navigate to localhost or
  private IPs during development, set this env var before starting the server.

## Browser path reference

- **`kuri` (HTTP API)** — production path for agent loops (this skill).
- **`kuri-fetch`** — standalone no-Chrome text extraction from URLs.
- **`kuri-browse`** — interactive terminal browser.
- **`kuri-agent`** — scriptable CLI automation against the Kuri server.
- **`kuri-browser/`** — experimental Zig-native browser runtime (separate build).

## Custom project skills

Put site-specific workflows (login steps, selectors, data extraction patterns)
in `skills/custom/`. See `skills/custom/hackernews-page-2.md` for an example.
