# pi-kuri-skill

A [Pi](https://pi.dev) skill plugin for **Kuri** browser automation — navigate,
screenshot, extract page content, and interact with web pages via Kuri's HTTP API.

This package provides:

- **`pi-kuri.ts`** — Pi agent extension registering Kuri tools (`kuri_navigate`,
  `kuri_snap`, `kuri_screenshot`, `kuri_text`, `kuri_evaluate`, `kuri_click`,
  `kuri_console_errors`, etc.) for agent-driven browser automation
- **`kuri-skill` CLI** — a portable Node.js wrapper around Kuri's HTTP API
- **`SKILL.md`** — pi.dev agent skill with two-tier progressive disclosure
- **`references/ADVANCED.md`** — on-demand reference for click, type, JS eval, etc.

## Prerequisites

- [Kuri](https://github.com/justrach/kuri) — the Zig-native browser automation server
- Node.js 18+

## Install

### As a pi.dev skill package

```bash
pi install npm:pi-kuri-skill
```

### Standalone (global CLI)

```bash
npm install -g pi-kuri-skill
```

### Extension setup

To make the Pi extension available to your agent:

```bash
ln -s $(pwd)/pi-kuri.ts ~/.pi/agent/extensions/pi-kuri.ts
```

Then restart pi.dev. The agent will have all Kuri tools registered.

Then use the `kuri-skill` command:

```bash
kuri-skill health
kuri-skill navigate https://example.com
kuri-skill screenshot
```

### Project-local

```bash
npm install pi-kuri-skill
npx kuri-skill health
```

### From the kuri repository

```bash
cd skills/pi-kuri-plugin
npm install
npm link               # makes `kuri-skill` available globally
```

## Quick Start

1. **Start Kuri** (if not already running):

   ```bash
   kuri
   ```

2. **Check the server is alive:**

   ```bash
   kuri-skill health
   ```

3. **Navigate to a page:**

   ```bash
   kuri-skill navigate https://example.com
   ```

4. **Inspect the page:**

   ```bash
   kuri-skill page-info
   kuri-skill screenshot
   kuri-skill text
   ```

5. **Use interactive refs:**

   ```bash
   kuri-skill snap
   kuri-skill action click e1
   ```

## Core Commands

| Command | Description |
|---------|-------------|
| `kuri-skill health` | Server health check |
| `kuri-skill tabs` | List all browser tabs |
| `kuri-skill tab-new [url]` | Open new tab |
| `kuri-skill navigate <url>` | Navigate to URL |
| `kuri-skill page-info` | Current page info |
| `kuri-skill screenshot` | Capture screenshot |
| `kuri-skill text` | Extract plain text |
| `kuri-skill markdown` | Extract as markdown |
| `kuri-skill links` | Extract all links |
| `kuri-skill snap` | Accessibility snapshot |
| `kuri-skill action <...>` | Advanced actions |
| `kuri-skill advanced` | Print advanced reference path |

## Advanced Reference

```bash
kuri-skill advanced
```

Or read `references/ADVANCED.md` directly for the full API reference covering
~80 endpoints, options, and workflow patterns.

## Configuration

| Variable | Default | Description |
|----------|---------|-------------|
| `KURI_BASE_URL` | `http://127.0.0.1:8080` | Kuri server URL |
| `KURI_SESSION` | `pi-kuri-skill` | Active session ID |
| `KURI_API_TOKEN` | (from `~/.kuri/api.token`) | API auth token |
| `KURI_TAB_ID` | (empty) | Default tab ID override |
| `KURI_OUTPUT` | `/tmp/kuri-*.png` | Screenshot output path |
| `KURI_PORT` | `8080` | Server port |

## Structure

```
pi-kuri-plugin/
├── SKILL.md                  # Pi agent skill (loaded by pi)
├── package.json              # npm package metadata + pi.skills
├── README.md                 # This file
├── scripts/
│   └── kuri.js               # CLI wrapper (also the `kuri-skill` bin)
└── references/
    └── ADVANCED.md           # On-demand advanced reference
```

## Related

- [Kuri](https://github.com/justrach/kuri) — Zig-native browser automation server
- [Pi](https://pi.dev) — The coding agent harness
- [`skills/pi-kuri-skills.md`](../pi-kuri-skills.md) — Canonical curl-based core skill
- [`skills/pi-kuri-advanced.md`](../pi-kuri-advanced.md) — Canonical curl-based advanced reference
