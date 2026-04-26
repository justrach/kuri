# Kuri Browser Parity Percent

Target in this file is **Kuri's real Chrome/CDP server**.

This score is meant to answer a narrower question:

- How much of Kuri's current browser-facing surface does `kuri-browser` cover natively today?
- Which parts are actually runnable against a live Kuri server instead of being estimated by inspection?

## Current Score

- Estimated feature parity: **66%**
- Automated validation coverage: **63%** of the target surface
- Offline replacement-readiness bench: **66%**, not ready
- Last live replacement-readiness bench: **71%**, not ready, measured against local Kuri on 2026-04-26

The `66%` figure is weighted, not a raw item count.

- `yes` = full weight
- `partial` = half weight
- `no` = zero

## How To Recompute

Run the standalone suite from `kuri-browser/`:

```sh
zig build run -- parity --kuri-base http://127.0.0.1:8080
```

If you only want the tracked scorecard without probing a live Kuri server:

```sh
zig build run -- parity --offline
```

Run the broader replacement-readiness bench:

```sh
zig build run -- bench --offline
```

That bench covers JS/runtime completeness, wait semantics, CDP surface area, Playwright/Puppeteer compatibility, and whether this can replace headless Chrome yet.

Run the minimal CDP server:

```sh
zig build run -- serve-cdp --port 9333
curl http://127.0.0.1:9333/json/version
curl http://127.0.0.1:9333/json/list
```

This exposes Chrome-style HTTP discovery plus a minimal WebSocket JSON-RPC router on the advertised `webSocketDebuggerUrl`. It can answer a small Browser/Target/Page/Runtime/Network/DOM/Input surface, including `Runtime.evaluate` with V8-shaped remote objects backed by QuickJS. It does not embed V8, and it is not broad Playwright/Puppeteer compatibility yet.

Capture screenshots through the existing Kuri/CDP renderer fallback:

```sh
zig build run -- screenshot https://example.com --out example.png --kuri-base http://127.0.0.1:8080
zig build run -- screenshot https://example.com --out example.jpg --compress --kuri-base http://127.0.0.1:8080
```

This is intentionally a fallback renderer. It proves the screenshot path works by delegating to Kuri's current Chrome/CDP server; it does not mean `kuri-browser` has native layout or paint.

`--compress` is token-oriented: it captures a PNG baseline, captures a JPEG candidate, keeps the smaller output, and reports `saved-bytes` plus `saved-percent`. The current default compression quality is JPEG 50 when `--quality` is not explicit.

Measured on `https://example.com` through the local Kuri/CDP fallback:

- PNG baseline: **20,523 bytes**
- Compressed output: **18,183 bytes** as JPEG quality 50
- Savings: **2,340 bytes**, **11%** smaller than PNG

Current bench result from this branch:

- Offline deterministic readiness: **66%**, not ready
- Offline + live probes readiness: **71%**, not ready
- JS/runtime completeness: **100%**
- Wait semantics: **100%**
- CDP automation surface: **77-79%** depending on live Kuri availability
- Playwright/Puppeteer compatibility: **39%**
- Replace-headless-Chrome readiness: **41-52%** depending on live probes

The live run passed Hacker News selector extraction, `quotes.toscrape.com/js/`, TodoMVC wait/eval, HAR capture, the CDP screenshot fallback, the local Kuri health probe, and the minimal local CDP WebSocket dispatch smoke test.

The live suite currently probes:

- page title parity on `example.com`
- text parity on `example.com`
- selector count parity on Hacker News
- redirect/cookie parity on `httpbingo`
- JS DOM-count parity on `quotes.toscrape.com/js/`
- SPA shell parity on TodoMVC
- HAR capture parity on `example.com`
- ref click parity on `example.com`

## Weighted Matrix

| Surface | Weight | Status | Validation | Gap |
|---|---:|---|---|---|
| Navigation + page metadata | 10 | yes | live | Good on the current native path |
| Text extraction | 8 | yes | live | Text-first output is already strong |
| DOM selectors | 8 | yes | live | Basic selectors work; broader CSS parity is still incomplete |
| Redirects + cookies | 8 | yes | live | Cookie jar is still simpler than a full browser store |
| Forms inspect + submit | 8 | partial | manual | Only a narrower GET/POST urlencoded subset is covered |
| Static subresource loading | 6 | partial | manual | Not a full browser resource model |
| HAR capture | 6 | partial | live | Standalone HAR is useful but not full CDP parity |
| JS execution + eval | 12 | partial | live | Real sites work, but the shim surface is still incomplete |
| Browser-side fetch/XHR/storage | 8 | partial | manual | Basic bridge exists; broad compatibility still missing |
| SPA compatibility | 8 | partial | live | Representative React flow works; arbitrary SPAs do not |
| Wait semantics + async lifecycle | 8 | partial | bench | `--wait-selector` and `--wait-eval` cover bounded JS polling; load-state parity is still missing |
| Agent snapshots, refs, and actions | 8 | partial | live | Snapshot refs plus basic click/type flows exist; broader action parity is still missing |
| Visual rendering + screenshots | 6 | partial | bench | Screenshot can delegate to Kuri/CDP fallback; native layout/paint/PDF are still missing |
| CDP / automation compatibility | 4 | partial | bench | `serve-cdp` exposes HTTP discovery plus a minimal WebSocket JSON-RPC router; broad CDP domains and Playwright/Puppeteer parity are still missing |

## Missing First

1. Full load-state and auto-wait lifecycle hooks.
2. Broader ref-driven actions plus keyboard/select/checkbox parity.
3. More complete DOM events and mutation semantics.
4. Native rendered output or screenshot support without the CDP fallback.
5. Broader CDP browser protocol domains beyond the minimal WebSocket router.
