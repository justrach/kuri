---
name: kuri-server
description: Use kuri-server to automate Chrome via HTTP API — navigate pages, get a11y snapshots, interact with elements, capture network traffic (HAR), extract cookies, and bypass bot protection. Use when the user wants to browse websites, scrape data, fill forms, test web apps, or interact with protected sites via a headless browser. Trigger phrases include "browse to", "open the page", "get the page content", "fill the form", "capture network traffic", "get cookies", "bypass bot protection".
argument-hint: "[endpoint] [params]"
allowed-tools: Bash
---

# kuri — HTTP API Browser Automation Server

kuri is a CDP automation server. It launches Chrome, connects via WebSocket, and exposes an HTTP API for browser control. Zero Node.js, single binary.

## Starting the server

```bash
# Default — launches headless Chrome, listens on :8080
./zig-out/bin/kuri

# Visible Chrome (for debugging)
HEADLESS=false ./zig-out/bin/kuri

# With residential proxy (for bot-protected sites)
KURI_PROXY=socks5://user:pass@proxy:1080 ./zig-out/bin/kuri

# Connect to existing Chrome
CDP_URL=ws://127.0.0.1:9222/devtools/browser/... ./zig-out/bin/kuri
```

## Core workflow

Prefer the session-first loop: **tab/new → page/info → snapshot → act → repeat**

```bash
BASE=http://127.0.0.1:8080
SESSION=agent-demo

# 1. Create or switch into a session-scoped tab
curl -s -H "X-Kuri-Session: $SESSION" \
  "$BASE/tab/new?url=https%3A%2F%2Fexample.com"

# 2. Read live page info
curl -s -H "X-Kuri-Session: $SESSION" "$BASE/page/info"
# → {"tab_id":"ABC123","url":"https://example.com/","title":"Example Domain",...}

# 3. Snapshot (a11y tree with element refs)
curl -s -H "X-Kuri-Session: $SESSION" "$BASE/snapshot?filter=interactive&format=compact"
# → [{"ref":"e0","role":"heading","name":"Example Domain"},
#    {"ref":"e1","role":"link","name":"More information..."}]

# 4. Interact via refs
curl -s -H "X-Kuri-Session: $SESSION" "$BASE/action?ref=e1&action=click"
curl -s -H "X-Kuri-Session: $SESSION" "$BASE/action?ref=e2&action=fill&value=hello"

# 5. Read results
curl -s -H "X-Kuri-Session: $SESSION" "$BASE/page/info"
curl -s -H "X-Kuri-Session: $SESSION" "$BASE/snapshot?filter=interactive&format=compact"
```

If you already know a tab id, set it directly with:

```bash
curl -s -H "X-Kuri-Session: $SESSION" "$BASE/tab/current?tab_id=ABC123"
```

## Key endpoints

### Navigation & page control
| Endpoint | Description |
|---|---|
| `GET /tab/current` | Get or set the current tab for an `X-Kuri-Session` |
| `GET /page/info` | Get live URL, title, ready state, viewport, and scroll |
| `GET /navigate?tab_id=X&url=URL` | Navigate to URL (auto bot-detection) |
| `GET /navigate?...&bot_detect=false` | Navigate without bot check (faster) |
| `GET /back?tab_id=X` | Browser back |
| `GET /forward?tab_id=X` | Browser forward |
| `GET /reload?tab_id=X` | Reload page |
| `GET /wait?tab_id=X&selector=CSS` | Wait for element to appear |
| `GET /stop?tab_id=X` | Stop page loading |

### Reading the page
| Endpoint | Description |
|---|---|
| `GET /snapshot?tab_id=X&filter=interactive&format=compact` | Lowest-token interactive a11y refs (best for agents) |
| `GET /snapshot?tab_id=X&filter=interactive` | Only interactive elements as JSON |
| `GET /diff/snapshot?tab_id=X` | Changes since last snapshot |
| `GET /text?tab_id=X` | Page text content |
| `GET /evaluate?tab_id=X&expression=JS` | Run JavaScript |
| `GET /screenshot?tab_id=X` | Base64 screenshot |
| `GET /markdown?tab_id=X` | Page as markdown |
| `GET /links?tab_id=X` | All hyperlinks |
| `GET /get?tab_id=X&type=title` | Get title/url/html/text/value |

### Interacting
| Endpoint | Description |
|---|---|
| `GET /action?tab_id=X&ref=eN&action=click` | Click element |
| `GET /action?tab_id=X&ref=eN&action=fill&value=V` | Fill input field |
| `GET /action?tab_id=X&ref=eN&action=select&value=V` | Select option |
| `GET /action?tab_id=X&ref=eN&action=hover` | Hover element |
| `GET /action?tab_id=X&ref=eN&action=focus` | Focus element |
| `GET /keyboard/type?tab_id=X&text=hello` | Type text |
| `GET /keydown?tab_id=X&key=Enter` | Press key |
| `GET /scrollintoview?tab_id=X&ref=eN` | Scroll to element |
| `GET /drag?tab_id=X&src=eN&tgt=eM` | Drag and drop |

### Network & cookies
| Endpoint | Description |
|---|---|
| `GET /cookies?tab_id=X` | Get all cookies |
| `GET /cookies/set?tab_id=X` | Set cookies (POST body) |
| `GET /cookies/delete?tab_id=X&name=N` | Delete cookie |
| `GET /headers?tab_id=X` | Set extra HTTP headers (POST body) |
| `GET /har/start?tab_id=X` | Start recording network traffic |
| `GET /har/stop?tab_id=X` | Stop + get HAR JSON |
| `GET /har/replay?tab_id=X&filter=api&format=all` | Get API map with code snippets |
| `GET /har/status?tab_id=X` | Check recording status |

### Bot protection
| Endpoint | Description |
|---|---|
| `GET /navigate?...&bot_detect=true` | Auto-detect blocks (default) |
| Response when blocked | `{"blocked":true,"blocker":"akamai","fallback":{"suggestions":[...]}}` |
| Stealth | Auto-applied on startup (UA rotation, webdriver hide, WebGL/canvas spoof) |
| Proxy | Set `KURI_PROXY=socks5://...` env var |

## HAR replay workflow (bypass browser for API calls)

When browser interaction is flaky or you want to call APIs directly:

```bash
# 1. Start recording
curl -s "$BASE/har/start?tab_id=ABC123"

# 2. Navigate and let the page load
curl -s "$BASE/navigate?tab_id=ABC123&url=https://target.com&bot_detect=false"
sleep 8

# 3. Get API map with code snippets
curl -s "$BASE/har/replay?tab_id=ABC123&filter=api&format=curl"
# → {"api_calls":[
#     {"method":"POST","url":"https://target.com/api/v4/data",
#      "request_headers":"{\"Cookie\":\"...\",\"X-CSRFToken\":\"...\"}",
#      "post_data":"{\"query\":\"...\"}",
#      "curl":"curl -X POST 'https://target.com/api/v4/data'"}
#   ]}

# 4. Grab cookies for direct API calls
curl -s "$BASE/cookies?tab_id=ABC123"

# 5. Call APIs directly with captured cookies + headers
curl -s 'https://target.com/api/v4/data' \
  -H 'Cookie: session=abc; csrf=xyz' \
  -H 'X-CSRFToken: xyz'
```

## Tips for agents

1. **Prefer session headers** — set `X-Kuri-Session` and let the server remember the current tab.
2. **Use `/page/info` between steps** — it is the cheapest live state check for URL/title/ready state.
3. **Use compact interactive snapshots** — `filter=interactive&format=compact` gives refs like `e0`, `e1` plus useful `state` such as `checked=false`, `disabled`, or `expanded=false` at lower token cost.
4. **Bot detection is automatic** — if navigate returns `{"blocked":true}`, read the `fallback.suggestions`.
5. **HAR for API discovery** — start HAR before navigating, then use `/har/replay?filter=api` to find the site's API endpoints.
6. **Cookies transfer** — use `/cookies` to get browser session cookies, then make direct `curl` calls.
7. **Refs persist per snapshot only** — take a new snapshot after any navigation or meaningful DOM change.
