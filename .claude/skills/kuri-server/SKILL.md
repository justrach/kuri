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

## Choosing the right Kuri browser path

Use the main `kuri` server for production browser automation. It drives Chrome/CDP and exposes HTTP sessions, page info, snapshots, actions, HAR, cookies, and screenshots.

Use the separate `kuri-browser/` workspace only for the experimental Zig-native browser runtime. It is not wired into the root build and cannot replace headless Chrome yet.

```bash
cd kuri-browser
zig build run -- render https://news.ycombinator.com --selector ".titleline a" --dump text
zig build run -- render https://todomvc.com/examples/react/dist/ --js --wait-eval "document.querySelectorAll('.todo-list li').length >= 1"
zig build run -- bench --offline
zig build run -- parity --offline
zig build run -- serve-cdp --port 9333
```

`serve-cdp` exposes Chrome-style HTTP discovery plus a minimal WebSocket JSON-RPC router. It can answer basic Browser/Target/Page/Runtime/DOM methods, and `Runtime.evaluate` returns V8-shaped CDP remote objects backed by QuickJS. This is useful for protocol smoke tests, but it is not broad Playwright/Puppeteer compatibility and cannot replace Chrome yet.

For screenshots, `kuri-browser` currently delegates to the main Kuri/CDP renderer:

```bash
# terminal 1, repo root
zig build
./zig-out/bin/kuri

# terminal 2
cd kuri-browser
zig build run -- screenshot https://example.com --out example.jpg --compress --kuri-base http://127.0.0.1:8080
```

`--compress` captures a PNG baseline and JPEG candidate, writes the smaller file, and reports byte savings. Current local measurement on `https://example.com`: `20,523` bytes PNG to `18,183` bytes JPEG quality 50, saving `2,340` bytes or `11%`.

## Key endpoints

**Design limit — paused CDP events need a live command to make progress.** Chrome delivers most async CDP events (screencast frames, exposed-binding calls, network records, tracing completion, download signals, dialog opens) only while some command is in flight on the same CDP socket; nothing else reads it. Endpoints that consume a ring/collector (`/screencast/stop`, `/expose/calls`, `/network?mode=list`, `/response/body?url=...`, `/trace/stop`, `/wait/download`, `/dialog/auto`) explicitly drain the socket (`drainWsEvents`/`waitForEvent`) before reading, so a normal call sequence self-heals on the very next request. A caller that goes fully idle between calls won't see new events arrive on their own — this is a documented limitation, not a bug, and does not need (or want) a background thread to paper over it.

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
| `GET /mainframe?tab_id=X` | Get the main frame's `frameId`/`loaderId`/`url` via `Page.getFrameTree` |
| `GET /frame?tab_id=X&name=N` (or `&url=U`) | Find a frame anywhere in the recursively-walked frame tree — not just the top document's direct `<iframe>` children — by name or url substring, then evaluate `{title,url}` inside that frame's own isolated-world execution context (`Page.createIsolatedWorld`). Works across nested and cross-origin frames still attached to this CDP session; `502` if `Page.createIsolatedWorld` fails (e.g. a true out-of-process subframe not attached to this session) |

### Reading the page
| Endpoint | Description |
|---|---|
| `GET /snapshot?tab_id=X&filter=interactive&format=compact` | Lowest-token interactive a11y refs (best for agents) |
| `GET /snapshot?tab_id=X&filter=interactive` | Only interactive elements as JSON |
| `GET /diff/snapshot?tab_id=X` | Changes since last snapshot |
| `GET /text?tab_id=X` | Page text content |
| `GET /evaluate?tab_id=X&expression=JS` | Run JavaScript |
| `GET /screenshot?tab_id=X` | Base64 screenshot |
| `GET /screenshot/annotated?tab_id=X&ref=eN` | Screenshot with the referenced element highlighted |
| `GET /markdown?tab_id=X` | Page as markdown |
| `GET /links?tab_id=X` | All hyperlinks |
| `GET /get?tab_id=X&type=title` | Get title/url/html/text/value |
| `GET /vitals?tab_id=X` | Core Web Vitals (LCP/CLS/FID/TTFB/FCP/domInteractive) via buffered `performance.getEntriesByType`. CLS uses the real windowed max-session-gap algorithm (gap <1s between shifts, session ≤5s) instead of a naive lifetime running sum. `lcp_measured`/`cls_measured`/`fid_measured` flags distinguish a genuine `0` from "hasn't happened yet" |

### Interacting
| Endpoint | Description |
|---|---|
| `GET /action?tab_id=X&ref=eN&action=click` | Click element |
| `GET /action?tab_id=X&ref=eN&action=fill&value=V` | Fill input field |
| `GET /action?tab_id=X&ref=eN&action=select&value=V` | Select option |
| `GET /action?tab_id=X&ref=eN&action=hover` | Hover element |
| `GET /action?tab_id=X&ref=eN&action=focus` | Focus element |
| `GET /keyboard/type?tab_id=X&text=hello` | Type text, one Unicode codepoint at a time (safe for accents/emoji/CJK) |
| `GET /keydown?tab_id=X&key=Enter` | Press key |
| `GET /scrollintoview?tab_id=X&ref=eN` | Scroll to element |
| `GET /drag?tab_id=X&src=eN&tgt=eM` | Drag and drop — fires the full `dragstart`/`drag` then `dragenter`/`dragover`/`drop` then `dragend` sequence across both elements |
| `GET /dispatch?tab_id=X&ref=eN&type=click` | Dispatch a real DOM event by type — `click`/`submit` trigger the browser's native action (link navigation, form submission); mouse types (`mousedown`, `mouseover`, ...) dispatch a `MouseEvent`; pointer types (`pointerdown`, `pointerup`, `pointermove`, `pointerover`, `pointerout`, `pointerenter`, `pointerleave`, `pointercancel`) dispatch a `PointerEvent` with `clientX`/`clientY` computed from the element's `getBoundingClientRect()` center and `pointerId:1, pointerType:'mouse', isPrimary:true`; keyboard types (`keydown`, `keyup`, `keypress`) dispatch a `KeyboardEvent`; everything else dispatches a plain `Event` |

### Downloads
| Endpoint | Description |
|---|---|
| `GET /download?tab_id=X&url=U&dir=/path` | Sets `Page.setDownloadBehavior` (download directory defaults to `/tmp/kuri-downloads`, overridable via `?dir=`) then triggers the download via a synthetic anchor click. A `Page.setDownloadBehavior` failure now surfaces as a real `502` instead of being silently swallowed |
| `GET /wait/download?tab_id=X&timeout=30000&dir=/path` | Waits for a real `Page.downloadWillBegin` event (fires exactly once per download) instead of returning a canned success. Confirms a download *started*; per-download guid/path/completion state isn't exposed yet — surfacing it would need `client.zig` to expose matched-event payloads to callers, out of scope for this router-level fix. `{"ok":true,"detected":true,...}` on success, `{"ok":false,"detected":false,...}` on timeout |

### Inspector
| Endpoint | Description |
|---|---|
| `GET /inspect?tab_id=X` | Sends real `Inspector.enable` (a `502` now surfaces if the CDP call itself errors, previously swallowed). CDP's `Inspector` domain has no synchronous introspection counterpart — the response is an honest note saying so, not a fabricated "DevTools enabled"; there is no further state to retrieve from this endpoint |

### Debugging (console & errors)
| Endpoint | Description |
|---|---|
| `GET /console?tab_id=X` | Console messages (log/info/warn/error/debug) captured since the last call; read-and-clear. Honors `X-Kuri-Session`, so `tab_id` is optional when a session tab is set. |
| `GET /errors?tab_id=X` | Uncaught errors + unhandled promise rejections; read-and-clear. Same session behavior. |

Both return the raw CDP wrapper — unwrap with `jq -r '.result.result.value' | jq '.'`. A collector script is injected on every navigation, so console output and errors are captured from page load. Caveat: messages emitted on a brand-new tab's *first* document, before the collector installs, are not captured — navigate or reload once and every subsequent load captures fully.

### Network & cookies
| Endpoint | Description |
|---|---|
| `GET /cookies?tab_id=X` | Get all cookies |
| `GET /cookies/set?tab_id=X` | Set cookies (POST body) |
| `GET /cookies/delete?tab_id=X&name=N` | Delete cookie |
| `GET /headers?tab_id=X` | Set extra HTTP headers (POST body) |
| `GET /set/credentials?tab_id=X&username=U&password=P` | Set a preemptive HTTP Basic `Authorization` header for the tab (works for servers that accept preemptive Basic auth; does not answer real `Fetch.authRequired` challenges — nothing in this codebase does yet) |
| `GET /network?tab_id=X&mode=enable\|disable` | Enable/disable the CDP `Network` domain for the tab (default `mode=enable`). `mode=disable` also clears the local network-request ring |
| `GET /network?tab_id=X&mode=list&url=SUBSTRING` | Lightweight bounded (200-record) traffic view — `request_id`/`url`/`method`/`mime_type`/`timestamp` only, no headers/timing/bodies. Never touches enable/disable state. For full capture use `/har/start` + `/har/stop` |
| `GET /response/body?tab_id=X&request_id=ID` (or `&url=SUBSTRING`) | Real `Network.getResponseBody` for a request already observed via `/network?mode=enable`. Resolves `request_id` directly, or by substring match against recorded traffic (needs `mode=enable` active and the request already observed). Replaces the old `fetch(url)`-from-the-page workaround; surfaces CDP-level errors (e.g. "No resource with given identifier") as `502` instead of masking them. `400` if neither param given, `404` if no match |
| `GET /har/start?tab_id=X` | Start recording network traffic |
| `GET /har/stop?tab_id=X` | Stop + get HAR JSON |
| `GET /har/replay?tab_id=X&filter=api&format=all` | Get API map with code snippets |
| `GET /har/status?tab_id=X` | Check recording status |

### Network interception (Fetch domain)
| Endpoint | Description |
|---|---|
| `GET/POST /intercept/start?tab_id=X&patterns=*.png,*.jpg` | `Fetch.enable` with the given comma-separated CDP glob patterns (Chrome's own `urlPattern` syntax). Default — and what an all-blank list falls back to — is `*` (match everything). Response echoes what was actually enabled: `{"status":"ok","message":"Fetch.enable sent","tab_id":"...","patterns":["*.png","*.jpg"]}` |
| `GET/POST /intercept/stop?tab_id=X` | `Fetch.disable`, then clears both the local rule table and the paused-request ring |
| `GET /intercept/rules?tab_id=X` | List the local rule table: `{"rules":[{"url_pattern":"...","action":"continue\|abort\|fulfill","status":N,"content_type":"...","body":"...","error_reason":"..."}],"count":N}` |
| `POST /intercept/rules?tab_id=X` | Add a rule. JSON body: `{"url_pattern":"substring or *","action":"continue\|abort\|fulfill","status":200,"body":"...","content_type":"...","error_reason":"..."}` (`pattern` also accepted as an alias for `url_pattern`) |
| `POST /intercept/rules/clear?tab_id=X` | Drop all rules only — leaves interception and the paused-request ring untouched (unlike `/intercept/stop`, which clears both) |
| `GET /intercept/requests?tab_id=X` | Paused requests if interception is active, otherwise a Resource Timing fallback — see below |

All six honor `X-Kuri-Session` in place of `tab_id`.

**Two different matching engines — don't confuse them.** `/intercept/start`'s `patterns` param maps onto real CDP `Fetch.enable` glob patterns (Chrome's own `urlPattern` syntax, e.g. `api.*.com` matches as a glob). `/intercept/rules`'s `url_pattern` does **not** — rules match by plain substring containment against the request URL, in the order added; `"*"` is special-cased only as a whole-pattern catch-all, not as a mid-string wildcard (`"api.*.com"` is matched literally, asterisk included). `Fetch.authRequired` (real 401/407 auth challenges) is not answered anywhere in this codebase yet — only request pausing is handled.

`GET /intercept/requests?tab_id=X` branches on whether interception is currently active for the tab (tracked precisely by `/intercept/start`/`/intercept/stop`, not inferred from request count). Active: `{"source":"intercepted","requests":[{"request_id","url","method","resource_type","action":"continue|abort|fulfill","status","timestamp"}],"count":N}` — the real ring of paused requests; an empty array is a valid answer if nothing has paused yet. Inactive: falls back to the pre-existing Resource Timing API `Runtime.evaluate` call, byte-for-byte unchanged, with `"source":"resource_timing"` spliced into the raw CDP envelope so old code parsing `.result.result.value` keeps working while new code can check `.source`.

### JS bindings (`window.<name>()` → host)
| Endpoint | Description |
|---|---|
| `GET /expose?tab_id=X&name=N` | `Runtime.enable` + `Runtime.addBinding`. (`Runtime.enable` was previously missing here, so `Runtime.bindingCalled` could never be delivered and the endpoint silently could never work — fixed.) Response includes `"retrieve_calls_at":"/expose/calls?tab_id=X&name=N"` |
| `GET /expose/calls?tab_id=X&name=N&clear=true` | Drains the socket and returns page→host calls captured on the binding since it was added, optionally filtered by `name`, optionally draining the ring with `clear=true` so repeated polling doesn't see the same calls twice |

### Dialogs
| Endpoint | Description |
|---|---|
| `GET /dialog/auto?tab_id=X&mode=accept` | Auto-accept `alert`/`confirm`/`prompt` dialogs going forward |
| `GET /dialog/auto?tab_id=X&mode=dismiss` | Auto-dismiss dialogs going forward |
| `GET /dialog/auto?tab_id=X&mode=accept&text=hello` | `text` supplies the value returned to `window.prompt()` |
| `GET /dialog/auto?tab_id=X&mode=off` | Turn the auto-responder back off (`mode=disable` also works) without touching any dialog that's currently open |

Response: `{"ok":true,"mode":"accept|dismiss|off"}`. Honors `X-Kuri-Session`. `mode=accept`/`mode=dismiss` now also arms the CDP-level auto-responder in the client itself, so `Page.javascriptDialogOpening` is actually answered between HTTP calls — previously this endpoint only touched page-local JS globals and left native dialogs outside those calls to hang the tab.

### Bot protection
| Endpoint | Description |
|---|---|
| `GET /navigate?...&bot_detect=true` | Auto-detect blocks (default) |
| Response when blocked | `{"blocked":true,"blocker":"akamai","fallback":{"suggestions":[...]}}` |
| Stealth | Auto-applied on startup (UA rotation, webdriver hide, WebGL/canvas spoof) |
| Proxy | Set `KURI_PROXY=socks5://...` env var |

### Screencast, video & tracing
| Endpoint | Description |
|---|---|
| `GET /screencast/start?tab_id=X&format=jpeg\|png&quality=0-100` | Real `Page.startScreencast`. `format`/`quality` are validated, not interpolated raw into the outgoing CDP command; clears any stale frames left over from a previous session first |
| `GET /screencast/stop?tab_id=X&frames=latest\|all\|none` | Drains the socket before *and* after `Page.stopScreencast` to catch frames that raced the stop ack. `frames=latest` (default): just the single newest frame. `frames=all`: every held frame inline (safe — the ring already bounds this to ≤32 MiB / 30 frames). `frames=none`: counts only |
| `GET /video/start`, `GET /video/stop` | Same shared core as `/screencast/*` — **not a second capability**. kuri has no video encoder (no ffmpeg/libav dependency); these are honest wrappers with `status:"video_started"`/`"video_stopped"` and an explicit `"note"` field stating no `.mp4`/`.webm` is produced. Encode client-side from the returned frames if you need a video file |
| `GET /trace/start?tab_id=X&categories=...` | `Tracing.start` with `transferMode:"ReturnAsStream"` (required — without it there is no stream for `/trace/stop` to read back) |
| `GET /trace/stop?tab_id=X` | `Tracing.end`, waits for `Tracing.tracingComplete`, then streams the trace to `~/.kuri/traces/trace-<tab_id>-<millis>.json` in 1 MiB chunks (512 MiB safety cap) instead of buffering the whole thing in memory. `{"ok":true,"status":"trace_complete","path":"...","bytes":N,"data_loss":bool,"trace_format":"..."}`; `"status":"trace_complete_no_stream"` if the trace completed with no stream (e.g. an empty trace); `504` if `Tracing.tracingComplete` is never observed |

### React introspection
| Endpoint | Description |
|---|---|
| `GET /react/tree?tab_id=X&max_nodes=500&max_depth=40&include_host_text=false` | Real fiber walk classified via `Symbol.for('react.*')` — never gated on `__REACT_DEVTOOLS_GLOBAL_HOOK__` already existing. Bounded server-side (`max_nodes` hard-capped at 3000, `max_depth` at 150); truncation is explicit (`truncated`, `moreChildren`, `nodeCount` in the payload). No React on the page → `{"react":false}` |
| `GET /react/inspect?tab_id=X&ref=eN` (or `&id=...` from a prior tree/suspense call, or `&selector=CSS`) | Props/state/hooks via a depth-, array-, string-, and value-budget-capped safe serializer with a cycle guard. Functions, DOM nodes, and circular references are stubbed, never followed |
| `GET /react/renders?tab_id=X` | Real bounded (200-entry) commit log fed by an `onCommitFiberRoot` hook stub — not the React Profiler API (no start/stopProfiling, no interaction traces). Requires a page reload *after* kuri attaches before it starts populating; `hookAttachedBeforeInit` plus a `note` field say so explicitly rather than silently returning nothing |
| `GET /react/suspense?tab_id=X&max_nodes=500` | Finds `Symbol.for('react.suspense')` boundaries across *all* roots (not just the first), reporting `{id, path, showingFallback}` per boundary |

All four degrade identically to `{"react":false}` when no React is on the page — never an error. Fiber/suspense `id`s are single-slot per tab and last-call-wins (fibers aren't stable across re-renders), so an `id` from `/react/tree` or `/react/suspense` is only valid until the next call to either on that tab. No iframe/OOPIF walking (same v1 boundary as `/frame`/`/mainframe`). Pre-Fiber React (≤15) is indistinguishable from "no React."

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

## Endpoints that require an explicit `tab_id`

Every endpoint that operates on exactly one tab resolves it from `X-Kuri-Session` (or an explicit `tab_id`/`session` query param) the same way `/console` does — a full audit of the route table found 113 direct `requireEffectiveTabId` call sites plus 9 more via the inline session/tab_id resolver already used by `/console`, `/errors`, and all `/intercept/*`. A handful of routes are intentionally exempt because "the current tab for this session" isn't the right concept for them:

| Route(s) | Why it's exempt |
|---|---|
| `/health` | No tab concept — server-wide status/version |
| `/tabs`, `/discover`, `/session/list` | List **all** tabs, not one |
| `/browdie` | Static response, no tab/bridge param at all |
| `/session/save`, `/session/load` | Export/import state for potentially many tabs |
| `/auth/profile/list`, `/auth/profile/delete` | Read/delete profiles on disk by name; no bridge/tab param |
| `/auth/extract` | Reads cookies directly from a local browser's on-disk SQLite DB; no live CDP tab involved |
| `/tab/new`, `/window/new` | **Create** a new tab — there is no pre-existing tab_id to resolve |
| `/tab/current` | Its `tab_id` param means "the tab to become current for this session" — the inverse of resolving a current tab; session resolution here would be circular |
| `/close` | Dual-mode by design: resolves one tab via the session when possible, explicitly falls back to "close every tab" otherwise |
| `/batch` | A single request fans out over a JSON body of sub-operations, each carrying its own per-op `tab_id` |

Everything not in this list honors `X-Kuri-Session`.

## Tips for agents

1. **Prefer session headers** — set `X-Kuri-Session` and let the server remember the current tab. This covers nearly every `tab_id=X` endpoint above — cookies, storage, HAR, emulation, keyboard input, tracing, network interception, downloads, screencast/video, exposed bindings, React introspection, and dialog auto-response all resolve the session the same way `/console`/`/errors` do. See "Endpoints that require an explicit `tab_id`" above for the intentional exceptions.
2. **Use `/page/info` between steps** — it is the cheapest live state check for URL/title/ready state.
3. **Use compact interactive snapshots** — `filter=interactive&format=compact` gives refs like `e0`, `e1` plus useful `state` such as `checked=false`, `disabled`, or `expanded=false` at lower token cost.
4. **Bot detection is automatic** — if navigate returns `{"blocked":true}`, read the `fallback.suggestions`.
5. **HAR for API discovery** — start HAR before navigating, then use `/har/replay?filter=api` to find the site's API endpoints.
6. **Cookies transfer** — use `/cookies` to get browser session cookies, then make direct `curl` calls.
7. **Refs persist per snapshot only** — take a new snapshot after any navigation or meaningful DOM change.
8. **Native browser experiment is separate** — `kuri-browser` is useful for parity work and benchmarks. Its `serve-cdp` router is minimal, screenshots still use the Kuri/CDP fallback, and native layout/paint is not implemented.
9. **Idle tabs don't self-update** — screencast frames, exposed-binding calls, network records, and trace/download completion only get pulled off the CDP socket while some command is in flight. If you go fully idle between calls, make one more call (even the same read) to let the server catch up; see the design-limit note under "Key endpoints" above.
