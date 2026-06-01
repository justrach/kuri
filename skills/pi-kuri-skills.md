---
name: pi-kuri-skills
description: Kuri browser automation for pi.dev agents — navigate, screenshot, extract content, and interact with web pages via the Kuri HTTP server. Use when an agent needs to browse the web, read pages, take screenshots, or perform browser interactions. Commands use the `kuri-skill` CLI from `skills/pi-kuri-plugin/`. For advanced operations (click, type, scroll, etc.) read `skills/pi-kuri-advanced.md`.
---

# Pi Kuri Skills

Kuri is a Zig-native browser automation server. This skill uses the
`kuri-skill` CLI wrapper from `skills/pi-kuri-plugin/` to drive Kuri's
HTTP API — no curl, no manual HTTP calls.

If `kuri-skill` is not available globally, install it:

```bash
cd skills/pi-kuri-plugin
npm install
npm link            # makes `kuri-skill` available on PATH
# or
node scripts/kuri.js <command>
```

This skill has two tiers:

| Tier | Covered here | When to use |
|------|-------------|-------------|
| **Core** 🟢 | Server health check, start, navigate, screenshot, page info, text & markdown extraction, links, accessibility snapshots | Most tasks |
| **Advanced** 🔵 | Click, type, fill, select, scroll, JS eval, cookies, audit, HAR, session mgmt | Read `skills/pi-kuri-advanced.md` on demand |

---

## 1. Setup — Validate & Start

### Check if Kuri is running

```bash
kuri-skill health
```

A healthy server returns `{"ok":true}` with the server version.

If the health check fails — connection refused or timeout — the server is not running.

### Start Kuri

If you built from source:

```bash
# From the kuri repo root
zig build
./zig-out/bin/kuri
```

If you installed via the install script:

```bash
kuri
```

Kuri starts a Chrome instance (managing it automatically) and listens on
`http://127.0.0.1:8080` by default. Customize with `HOST`, `PORT`, `CDP_URL`
(see the configuration table in the README).

### List available tabs

```bash
kuri-skill tabs
```

Returns the active session's tabs with their IDs, URLs, and titles.

---

## 2. Core Operations

### Create a tab and navigate

```bash
kuri-skill tab-new https://example.com
kuri-skill navigate https://example.com
```

### Get page info

```bash
kuri-skill page-info
```

Returns `url`, `title`, and page `readyState`. Always call this after navigation
to confirm the page loaded before taking further actions.

### Screenshot

```bash
kuri-skill screenshot
```

Saves a PNG. Customize the output path with `KURI_OUTPUT`.

### Content extraction

```bash
kuri-skill text
kuri-skill markdown
kuri-skill links
```

### Accessibility snapshot (interactive refs)

```bash
kuri-skill snap
```

Returns a compact text-tree of interactive elements with refs like `e0`, `e1`.
These refs are used as targets for advanced actions (click, type, fill, etc.).

**Re-snap after any navigation or DOM change** — refs are snapshot-local and
become stale once the page updates.

---

## 3. Advanced Operations

For click, type, fill, select, scroll, JavaScript evaluation, cookies, security
audits, HAR recording, and session management, read:

```
skills/pi-kuri-advanced.md
```

**What's available at a glance:**

| Category | Capabilities |
|----------|-------------|
| 🖱️ Mouse | click, right-click, double-click, hover |
| ⌨️ Keyboard | type text, fill input, select option |
| 📜 Scroll | up, down, left, right, pixel-amount |
| 🧠 JS Eval | arbitrary JavaScript, return values |
| 🍪 Cookies | list, inspect security flags |
| 🔒 Security | audit headers, cookies, HTTPS, mixed content |
| 📡 HAR | HTTP archive recording (start, stop, export) |
| 📑 Tabs & Sessions | multi-tab, multi-session orchestration |
| 🧪 Experimental | kuri-browser render, bench, parity, serve-cdp |

Read the advanced file only when you need one of those capabilities.

---

## Tips

- **Prefer `kuri-skill` with sessions** — set `KURI_SESSION` env var to group
  tabs without repeating `tab_id` on every call.
- **Call `kuri-skill page-info` before acting** — confirm the right page is loaded.
- **Treat refs as snapshot-local** — refresh after navigation or DOM updates.
- **`KURI_ALLOW_PRIVATE=1`** — if you need to reach localhost or private IPs
  during development, set this before starting the Kuri server.

## Plugin reference

- `skills/pi-kuri-plugin/` — the npm-installable plugin with `kuri-skill` CLI
- `skills/pi-kuri-plugin/package.json` — `pi.skills` field for pi auto-discovery
- `skills/pi-kuri-plugin/SKILL.md` — pi agent skill (synchronized with this file)
