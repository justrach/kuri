---
name: pi-kuri-advanced
description: Advanced Kuri browser automation for pi.dev agents — click, type, fill, select, scroll, JavaScript evaluation, cookies, security audits, session management, HAR recording, and the experimental kuri-browser CLI. Load this on demand when the core skill (`skills/pi-kuri-skills.md`) is not enough.
---

# Pi Kuri Advanced Reference

This file covers operations beyond the core skill (`skills/pi-kuri-skills.md`).
Load it when you need interactive actions, JavaScript evaluation, cookies,
security audits, session management, or experimental features.

All commands use the `kuri-skill` CLI from `skills/pi-kuri-plugin/`. If
`kuri-skill` is not on your PATH, run commands via:

```bash
node skills/pi-kuri-plugin/scripts/kuri.js <command>
```

Set `KURI_SESSION` to group tabs without repeating `tab_id` on every call:

```bash
export KURI_SESSION=my-session
```

---

## 🖱️ Mouse Actions

### Click an element

```bash
kuri-skill action click e1
kuri-skill action click ref=e1 tab_id=TABID123

# Right-click
kuri-skill action click ref=e1 button=right

# Double-click
kuri-skill action click ref=e1 clickCount=2
```

### Hover

Use the snapshot to detect hover-triggered UI, then evaluate JS for precise
hover scenarios:

```bash
kuri-skill action evaluate \
  expression="document.querySelector('button').dispatchEvent(new MouseEvent('mouseover',{bubbles:true}))"
```

---

## ⌨️ Keyboard Actions

### Type text into an input

```bash
kuri-skill action type e2 "hello world"
kuri-skill action type ref=e2 value="hello world"
```

### Fill input value

```bash
kuri-skill action fill e2 "user@example.com"
kuri-skill action fill ref=e2 value="user@example.com"
```

### Select a dropdown option

```bash
kuri-skill action select e3 "option-value"
kuri-skill action select ref=e3 value="option-value"
```

---

## 📜 Scrolling

```bash
# Scroll down (default)
kuri-skill action scroll

# Scroll up
kuri-skill action scroll direction=up amount=10

# Scroll right
kuri-skill action scroll direction=right amount=3

# Scroll by pixel amount
kuri-skill action scroll direction=down amount=500
```

---

## 🧠 JavaScript Evaluation

```bash
# Get page title
kuri-skill action evaluate expression="document.title"

# Read heading text
kuri-skill action evaluate \
  expression="document.querySelector('h1').textContent"

# Extract dynamic state
kuri-skill action evaluate \
  expression="JSON.stringify(window.__INITIAL_STATE__)"

# Get page metrics
kuri-skill action evaluate \
  expression="document.body.scrollHeight"

# Check element visibility
kuri-skill action evaluate \
  expression="document.querySelector('.spinner').offsetParent!==null"
```

Returns the evaluated result as a string, number, boolean, or JSON value.

---

## 🍪 Cookies

```bash
kuri-skill action cookies
```

Returns an array of cookies with: `name`, `value`, `domain`, `path`, `secure`,
`httpOnly`, `sameSite`, `expires`.

---

## 🔒 Security Audit

```bash
kuri-skill action audit
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
kuri-skill action har-start

# Perform actions that make network requests...

# Stop and retrieve the HAR log
kuri-skill action har-stop

# Get current HAR log without stopping
kuri-skill action har
```

Useful for reverse-engineering API calls or debugging network issues.

---

## 📑 Tab & Session Management

```bash
# List all tabs
kuri-skill tabs

# Create a new tab
kuri-skill tab-new https://example.com

# Close a tab
kuri-skill action close-tab TABID123

# Browser back
kuri-skill action back

# Browser forward
kuri-skill action forward

# Reload
kuri-skill action reload
```

### Multiple sessions

Run independent browser sessions by setting `KURI_SESSION` to different values:

```bash
KURI_SESSION=session-a kuri-skill tab-new https://example.com
KURI_SESSION=session-b kuri-skill tab-new https://other.com
```

Each session tracks its own tabs and current tab independently.

---

## 🧪 Experimental — kuri-browser

The `kuri-browser/` subdirectory is an **experimental** Zig-native browser
runtime with its own rendering engine (separate build, not wired into Kuri's
root build). Use for evaluation and development only.

```bash
cd kuri-browser
zig build run -- render https://news.ycombinator.com --selector ".titleline a" --dump text
zig build run -- render https://todomvc.com/examples/react/dist/ --js --wait-eval "..."
zig build run -- bench --offline
zig build run -- serve-cdp --port 9333
```

Screenshots fall back to the main Kuri/CDP renderer — start the normal Kuri
server first, then:

```bash
cd kuri-browser
zig build run -- screenshot https://example.com --out example.jpg \
  --compress --kuri-base http://127.0.0.1:8080
```

---

## Common Workflow Patterns

### Pattern 1: Quick screenshot verification

```bash
export KURI_SESSION=verify

kuri-skill tab-new https://example.com
kuri-skill page-info
kuri-skill screenshot     # set KURI_OUTPUT to customize path
```

### Pattern 2: Fill form and submit

```bash
export KURI_SESSION=login

kuri-skill tab-new https://example.com/login
kuri-skill snap                        # Get refs

kuri-skill action type e0 "user@example.com"
kuri-skill action type e1 "password123"
kuri-skill action click e2             # Submit button

kuri-skill page-info                   # Check result
```

### Pattern 3: Extract dynamic content

```bash
export KURI_SESSION=extract

kuri-skill tab-new https://example.com/app
kuri-skill action evaluate expression="JSON.stringify(window.__DATA__)"
kuri-skill text                        # Also get rendered text
```

### Pattern 4: Multi-step interaction loop

```bash
export KURI_SESSION=search

# 1. Open page
kuri-skill tab-new https://example.com/search

# 2. Get snapshot for refs
kuri-skill snap

# 3. Type search query
kuri-skill action type e0 "query text"

# 4. Check for results via JS
kuri-skill action evaluate \
  expression="document.querySelectorAll('.result').length"

# 5. Re-snap after DOM change
kuri-skill snap

# 6. Click a result
kuri-skill action click e3

# 7. Verify new page
kuri-skill page-info

# 8. Screenshot for evidence
kuri-skill screenshot
```

---

## Quick Parameter Reference

| Parameter | Applies to | Description |
|-----------|-----------|-------------|
| `ref` | action | Element reference from snapshot |
| `action` | action | `click`, `type`, `fill`, `select`, `scroll` |
| `value` | type / fill / select | Text or option value |
| `direction` | scroll | `up`, `down`, `left`, `right` |
| `amount` | scroll | Scroll distance (lines or pixels) |
| `button` | click | `left`, `right`, `middle` |
| `clickCount` | click | `1` = single, `2` = double |
| `modifiers` | click | `shift`, `ctrl`, `meta` |
| `expression` | evaluate | JavaScript to execute |
| `tab_id` | Most commands | Target a specific tab |

## Full Endpoint Map

The `kuri-skill` CLI wraps all major Kuri HTTP endpoints. For the complete
list of ~80+ endpoints, see the main Kuri README.

| Endpoint | `kuri-skill` | Purpose |
|----------|-------------|---------|
| `/health` | `health` | Server health check |
| `/tabs` | `tabs` | List all tabs |
| `/tab/new` | `tab-new` | Create a new tab |
| `/tab/close` | `action close-tab` | Close a tab |
| `/tab/current` | — (use `KURI_SESSION`) | Set current tab |
| `/navigate` | `navigate` | Navigate to URL |
| `/page/info` | `page-info` | Page metadata |
| `/page/state` | — | Lightweight observation |
| `/screenshot` | `screenshot` | Capture screenshot |
| `/snapshot` | `snap` | Accessibility tree |
| `/text` | `text` | Page plain text |
| `/markdown` | `markdown` | Page as markdown |
| `/links` | `links` | Extract links |
| `/action` | `action <op>` | Click, type, fill, select, scroll |
| `/evaluate` | `action evaluate` | Execute JavaScript |
| `/cookies` | `action cookies` | List cookies |
| `/audit` | `action audit` | Security audit |
| `/back` | `action back` | Browser back |
| `/forward` | `action forward` | Browser forward |
| `/reload` | `action reload` | Reload page |
| `/har` | `action har` | Current HAR log |
| `/har/start` | `action har-start` | Start HAR recording |
| `/har/stop` | `action har-stop` | Stop HAR recording |
| `/batch` | — | Multi-command batch |
| `/evaluate` | `action evaluate` | JS evaluation |
| `/clipboard/*` | — | Clipboard read/write |
| `/dialog/*` | — | Dialog handling |
| `/mouse/*` | — | Mouse control |
| `/recording/*` | — | Action recording |
| `/vitals` | — | Core Web Vitals |
| `/cache/*` | — | Action caching |

For the complete list see the main [Kuri README](../readme.md).
