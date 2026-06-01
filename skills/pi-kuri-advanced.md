---
name: pi-kuri-advanced
description: Advanced Kuri browser automation for pi.dev agents — click, type, fill, select, scroll, JavaScript evaluation, cookies, security audits, session management, HAR recording, and the experimental kuri-browser CLI. Load this on demand when the core skill (`skills/pi-kuri-skills.md`) is not enough.
---

# Pi Kuri Advanced Reference

This file covers operations beyond the core skill (`skills/pi-kuri-skills.md`).
Load it when you need interactive actions, JavaScript evaluation, cookies,
security audits, session management, or experimental features.

---

## Using `X-Kuri-Session`

Most examples below use the `X-Kuri-Session` header, which groups tabs and tracks
a current tab per session so you don't need to repeat `tab_id` on every call.

```bash
BASE=http://127.0.0.1:8080
SESSION=my-session

# All subsequent calls use this session
curl -s -H "X-Kuri-Session: $SESSION" "$BASE/action?action=click&ref=e1"
```

If you need to target a specific tab, add `&tab_id=TABID123` to any endpoint.
Use `/tabs` to discover tab IDs.

---

## 🖱️ Mouse Actions

### Click an element

```bash
# Click by snapshot ref
curl -s -H "X-Kuri-Session: $SESSION" \
  "http://127.0.0.1:8080/action?action=click&ref=e1"

# Click with a specific tab
curl -s "http://127.0.0.1:8080/action?action=click&ref=e1&tab_id=TABID123"

# Click with modifiers (shift, ctrl, meta)
curl -s -H "X-Kuri-Session: $SESSION" \
  "http://127.0.0.1:8080/action?action=click&ref=e1&modifiers=shift"
```

### Right-click

```bash
curl -s -H "X-Kuri-Session: $SESSION" \
  "http://127.0.0.1:8080/action?action=click&ref=e1&button=right"
```

### Double-click

```bash
curl -s -H "X-Kuri-Session: $SESSION" \
  "http://127.0.0.1:8080/action?action=click&ref=e1&clickCount=2"
```

### Hover

Use the snapshot to detect hover-triggered UI, then evaluate JS for precise
hover scenarios:

```bash
curl -s -H "X-Kuri-Session: $SESSION" \
  "http://127.0.0.1:8080/evaluate?expression=document.querySelector('button').dispatchEvent(new MouseEvent('mouseover',{bubbles:true}))"
```

---

## ⌨️ Keyboard Actions

### Type text into an input

Replaces existing content with the provided text:

```bash
curl -s -H "X-Kuri-Session: $SESSION" \
  "http://127.0.0.1:8080/action?action=type&ref=e2&value=hello%20world"
```

### Fill input value

Sets the input's value directly (similar to type, may clear first):

```bash
curl -s -H "X-Kuri-Session: $SESSION" \
  "http://127.0.0.1:8080/action?action=fill&ref=e2&value=user@example.com"
```

### Select a dropdown option

```bash
curl -s -H "X-Kuri-Session: $SESSION" \
  "http://127.0.0.1:8080/action?action=select&ref=e3&value=option-value"
```

---

## 📜 Scrolling

```bash
# Scroll down (default)
curl -s -H "X-Kuri-Session: $SESSION" \
  "http://127.0.0.1:8080/action?action=scroll&direction=down"

# Scroll up with specified amount
curl -s -H "X-Kuri-Session: $SESSION" \
  "http://127.0.0.1:8080/action?action=scroll&direction=up&amount=10"

# Scroll right (for horizontally scrollable content)
curl -s -H "X-Kuri-Session: $SESSION" \
  "http://127.0.0.1:8080/action?action=scroll&direction=right&amount=3"
```

The `amount` parameter controls distance (lines or approximate pixels).

---

## 🧠 JavaScript Evaluation

### Execute JavaScript in the page context

```bash
# Get page title
curl -s -H "X-Kuri-Session: $SESSION" \
  "http://127.0.0.1:8080/evaluate?expression=document.title"

# Read heading text
curl -s -H "X-Kuri-Session: $SESSION" \
  "http://127.0.0.1:8080/evaluate?expression=document.querySelector('h1').textContent"

# Extract dynamic state
curl -s -H "X-Kuri-Session: $SESSION" \
  "http://127.0.0.1:8080/evaluate?expression=JSON.stringify(window.__INITIAL_STATE__)"

# Get page metrics
curl -s -H "X-Kuri-Session: $SESSION" \
  "http://127.0.0.1:8080/evaluate?expression=document.body.scrollHeight"

# Check element visibility
curl -s -H "X-Kuri-Session: $SESSION" \
  "http://127.0.0.1:8080/evaluate?expression=document.querySelector('.spinner').offsetParent!==null"
```

Returns the evaluated result as a string, number, boolean, or JSON value.

---

## 🍪 Cookies

List all cookies for the current page with security flags:

```bash
curl -s -H "X-Kuri-Session: $SESSION" \
  "http://127.0.0.1:8080/cookies"
```

Returns an array of cookies with: `name`, `value`, `domain`, `path`, `secure`,
`httpOnly`, `sameSite`, `expires`.

---

## 🔒 Security Audit

Run a full security audit on the current page:

```bash
curl -s -H "X-Kuri-Session: $SESSION" \
  "http://127.0.0.1:8080/audit"
```

Checks performed:
- Security response headers: HSTS, CSP, X-Frame-Options, X-Content-Type-Options
- Cookie security: Secure flag, HttpOnly flag, SameSite attribute
- HTTPS enforcement
- Mixed content warnings

---

## 📡 HAR Recording (HTTP Archive)

Record network activity for API discovery or debugging:

```bash
# Start recording
curl -s -H "X-Kuri-Session: $SESSION" \
  "http://127.0.0.1:8080/har/start"

# Perform actions that make network requests...

# Stop and retrieve the HAR log
curl -s -H "X-Kuri-Session: $SESSION" \
  "http://127.0.0.1:8080/har/stop"

# Get current HAR log without stopping
curl -s -H "X-Kuri-Session: $SESSION" \
  "http://127.0.0.1:8080/har"
```

Useful for reverse-engineering API calls, finding XHR endpoints, or debugging
network issues.

---

## 📑 Tab & Session Management

### List all tabs

```bash
curl -s "http://127.0.0.1:8080/tabs"
```

### Create a new tab

```bash
curl -s -H "X-Kuri-Session: $SESSION" \
  "http://127.0.0.1:8080/tab/new?url=https%3A%2F%2Fexample.com"
```

### Close a tab

```bash
curl -s -H "X-Kuri-Session: $SESSION" \
  "http://127.0.0.1:8080/tab/close?tab_id=TABID123"
```

### Set current tab

```bash
curl -s -H "X-Kuri-Session: $SESSION" \
  "http://127.0.0.1:8080/tab/current?tab_id=TABID123"
```

### Browser navigation

```bash
# Back
curl -s -H "X-Kuri-Session: $SESSION" \
  "http://127.0.0.1:8080/back"

# Forward
curl -s -H "X-Kuri-Session: $SESSION" \
  "http://127.0.0.1:8080/forward"

# Reload
curl -s -H "X-Kuri-Session: $SESSION" \
  "http://127.0.0.1:8080/reload"
```

### Multiple sessions

Run independent browser sessions in parallel by using different session IDs:

```bash
curl -s -H "X-Kuri-Session: session-A" "http://127.0.0.1:8080/tab/new?url=https%3A%2F%2Fexample.com"
curl -s -H "X-Kuri-Session: session-B" "http://127.0.0.1:8080/tab/new?url=https%3A%2F%2Fother.com"
```

Each session tracks its own tabs and current tab independently.

---

## 🧪 Experimental — kuri-browser

The `kuri-browser/` subdirectory is an **experimental** Zig-native browser
runtime with its own rendering engine. It is a separate build and is not wired
into Kuri's root build. Use it for evaluation and development only.

### Build and run

```bash
cd kuri-browser
zig build run -- render https://news.ycombinator.com --selector ".titleline a" --dump text
zig build run -- render https://todomvc.com/examples/react/dist/ --js --wait-eval "document.querySelectorAll('.todo-list li').length >= 1"
zig build run -- bench --offline
zig build run -- parity --offline
zig build run -- serve-cdp --port 9333
```

`serve-cdp` exposes a minimal CDP-compatible WebSocket server useful for
protocol smoke tests, but it is not Playwright/Puppeteer-compatible enough
to replace Chrome.

### Screenshot via kuri-browser

Screenshots currently fall back to the main Kuri/CDP renderer, so start the
normal Kuri server first:

```bash
# terminal 1 — start main Kuri
zig build
./zig-out/bin/kuri

# terminal 2 — take screenshot via kuri-browser
cd kuri-browser
zig build run -- screenshot https://example.com --out example.jpg \
  --compress --kuri-base http://127.0.0.1:8080
```

`--compress` captures PNG and JPEG, writes the smaller file, and reports
size savings.

---

## Common Workflow Patterns

### Pattern 1: Quick screenshot verification

```bash
SESSION=verify

# Open page
curl -s -H "X-Kuri-Session: $SESSION" \
  "http://127.0.0.1:8080/tab/new?url=https%3A%2F%2Fexample.com"

# Confirm loaded
curl -s -H "X-Kuri-Session: $SESSION" \
  "http://127.0.0.1:8080/page/info"

# Capture visual evidence
curl -s -H "X-Kuri-Session: $SESSION" \
  "http://127.0.0.1:8080/screenshot" -o evidence.png
```

### Pattern 2: Fill form and submit

```bash
SESSION=login

# Open login page
curl -s -H "X-Kuri-Session: $SESSION" \
  "http://127.0.0.1:8080/tab/new?url=https%3A%2F%2Fexample.com%2Flogin"

# Get snapshot for refs
curl -s -H "X-Kuri-Session: $SESSION" \
  "http://127.0.0.1:8080/snapshot?filter=interactive&format=compact"

# Fill credentials (use refs from snapshot)
curl -s -H "X-Kuri-Session: $SESSION" \
  "http://127.0.0.1:8080/action?action=type&ref=e0&value=user@example.com"
curl -s -H "X-Kuri-Session: $SESSION" \
  "http://127.0.0.1:8080/action?action=type&ref=e1&value=password123"

# Click submit button
curl -s -H "X-Kuri-Session: $SESSION" \
  "http://127.0.0.1:8080/action?action=click&ref=e2"

# Verify result
curl -s -H "X-Kuri-Session: $SESSION" \
  "http://127.0.0.1:8080/page/info"
```

### Pattern 3: Extract dynamic content

```bash
SESSION=extract

curl -s -H "X-Kuri-Session: $SESSION" \
  "http://127.0.0.1:8080/tab/new?url=https%3A%2F%2Fexample.com%2Fapp"

# Extract JS state
curl -s -H "X-Kuri-Session: $SESSION" \
  "http://127.0.0.1:8080/evaluate?expression=JSON.stringify(window.__DATA__)"

# Also get rendered text
curl -s -H "X-Kuri-Session: $SESSION" \
  "http://127.0.0.1:8080/text"
```

### Pattern 4: Multi-step interaction loop

```bash
SESSION=search

# 1. Open page
curl -s -H "X-Kuri-Session: $SESSION" \
  "http://127.0.0.1:8080/tab/new?url=https%3A%2F%2Fexample.com%2Fsearch"

# 2. Get snapshot for refs
curl -s -H "X-Kuri-Session: $SESSION" \
  "http://127.0.0.1:8080/snapshot?filter=interactive&format=compact"

# 3. Type search query
curl -s -H "X-Kuri-Session: $SESSION" \
  "http://127.0.0.1:8080/action?action=type&ref=e0&value=query+text"

# 4. Wait and check for results via JS
curl -s -H "X-Kuri-Session: $SESSION" \
  "http://127.0.0.1:8080/evaluate?expression=document.querySelectorAll('.result').length"

# 5. Re-snap after DOM change
curl -s -H "X-Kuri-Session: $SESSION" \
  "http://127.0.0.1:8080/snapshot?filter=interactive&format=compact"

# 6. Click a result
curl -s -H "X-Kuri-Session: $SESSION" \
  "http://127.0.0.1:8080/action?action=click&ref=e3"

# 7. Verify new page
curl -s -H "X-Kuri-Session: $SESSION" \
  "http://127.0.0.1:8080/page/info"

# 8. Screenshot for evidence
curl -s -H "X-Kuri-Session: $SESSION" \
  "http://127.0.0.1:8080/screenshot" -o result.png
```

---

## Quick Parameter Reference

### Common query parameters

| Parameter | Type | Applies to | Description |
|-----------|------|-----------|-------------|
| `tab_id` | string | Most endpoints | Target a specific tab |
| `ref` | string | `/action` | Element reference from snapshot |
| `action` | string | `/action` | `click`, `type`, `fill`, `select`, `scroll` |
| `value` | string | type / fill / select | Text or option value |
| `direction` | string | scroll | `up`, `down`, `left`, `right` |
| `amount` | number | scroll | Scroll distance (lines or pixels) |
| `button` | string | click | `left`, `right`, `middle` |
| `clickCount` | number | click | `1` = single, `2` = double |
| `modifiers` | string | click | `shift`, `ctrl`, `meta` (comma-separated) |
| `expression` | string | `/evaluate` | JavaScript to execute |
| `filter` | string | `/snapshot` | `interactive`, `all` |
| `format` | string | `/snapshot` | `compact`, `json`, `verbose` |
| `session` | string | Most endpoints | `X-Kuri-Session` header override |
| `wait` | number | Most endpoints | Milliseconds to wait before response |
| `timeout` | number | Most endpoints | Operation timeout in milliseconds |
| `url` | string | `/navigate`, `/tab/new` | Target URL (URL-encoded) |

### Full endpoint map

| Method | Endpoint | Purpose |
|--------|----------|---------|
| GET | `/health` | Server health check |
| GET | `/tabs` | List all tabs |
| GET/POST | `/tab/new` | Create a new tab |
| GET | `/tab/close` | Close a tab |
| GET | `/tab/current` | Set or get current tab |
| GET | `/navigate` | Navigate a tab to a URL |
| GET | `/page/info` | Current page metadata (URL, title, state) |
| GET | `/page/state` | Lightweight page observation (48 tokens) |
| GET | `/screenshot` | Capture viewport screenshot |
| GET | `/snapshot` | Accessibility tree snapshot |
| GET | `/text` | Page plain text |
| GET | `/markdown` | Page as markdown |
| GET | `/links` | Extract all links |
| GET | `/action` | Perform action (click, type, fill, select, scroll) |
| GET | `/evaluate` | Execute JavaScript |
| GET | `/cookies` | List cookies with security flags |
| GET | `/audit` | Full security audit |
| GET | `/back` | Browser back |
| GET | `/forward` | Browser forward |
| GET | `/reload` | Reload page |
| GET | `/har` | Current HAR log |
| GET | `/har/start` | Start HAR recording |
| GET | `/har/stop` | Stop and return HAR |
| GET | `/headers` | Response security headers |
| GET | `/token` | Print or rotate API token |
| GET | `/discover` | Discover CDP tabs |
| POST | `/batch` | Execute multiple commands in one call |
| GET | `/element/state` | Quick element state check |
| GET | `/find-element` | Semantic locator search |
| GET | `/clipboard/read` | Read clipboard content |
| GET | `/clipboard/write` | Write to clipboard |
| GET | `/dialog/auto` | Auto-accept dialogs |
| GET | `/dialog/accept` | Accept current dialog |
| GET | `/dialog/dismiss` | Dismiss current dialog |
| GET | `/mouse/move` | Move mouse to coordinates |
| GET | `/mouse/down` | Mouse button down |
| GET | `/mouse/up` | Mouse button up |
| GET | `/mouse/wheel` | Mouse wheel scroll |
| GET | `/timezone` | Set emulated timezone |
| GET | `/locale` | Set emulated locale |
| GET | `/permissions` | Set browser permissions |
| GET | `/clear` | Clear input content |
| GET | `/selectall` | Select all in input |
| GET | `/boundingbox` | Element bounding box |
| GET | `/getattribute` | Get element attribute |
| GET | `/inputvalue` | Get input value |
| GET | `/evalhandle` | Evaluate and return JS handle |
| GET | `/recording/start` | Start action recording |
| GET | `/recording/stop` | Stop and export recording |
| GET | `/recording/export` | Export recording as batch JSON |
| GET | `/vitals` | Core Web Vitals (LCP, CLS, FID, TTFB, FCP) |
| GET | `/pushstate` | Simulate pushState navigation |
| GET | `/bringtofront` | Bring tab to front |
| GET | `/frame` | Switch iframe context |
| GET | `/mainframe` | Switch to main frame |
| GET | `/addstyle` | Inject CSS into page |
| GET | `/expose` | Expose Node.js function to page |
| GET | `/setcontent` | Set page HTML content |
| GET | `/request/detail` | Request detail by ID |
| GET | `/response/body` | Response body by request ID |
| GET | `/download` | Download a file |
| GET | `/diff/url` | Compare two URLs side by side |
| GET | `/cache/set` | Cache a value |
| GET | `/cache/get` | Get cached value |
| GET | `/cache/clear` | Clear cache |
| GET | `/cache/list` | List cache keys |
| GET | `/screenshot/som` | Set-of-Marks screenshot with numbered overlays |
| GET | `/snapshot/changes` | Smart diff — only changed lines since last snapshot |

See the main README for a complete, always-up-to-date endpoint list.
