# Kuri Browser Parity Percent

Target in this file is **Kuri's real Chrome/CDP server**.

This score is meant to answer a narrower question:

- How much of Kuri's current browser-facing surface does `kuri-browser` cover natively today?
- Which parts are actually runnable against a live Kuri server instead of being estimated by inspection?

## Current Score

- Estimated feature parity: **66%**
- Automated validation coverage: **63%** of the target surface
- Offline replacement-readiness bench: **70%**, not ready
- Last live replacement-readiness bench: **74%**, not ready, measured against local Kuri on 2026-04-26
- Last live parity validation: **47%** of the full target surface, with all cache-busted live probes passing on 2026-04-26

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
zig build run -- bench --kuri-base http://127.0.0.1:8080
```

That bench covers JS/runtime completeness, wait semantics, CDP surface area, Playwright/Puppeteer compatibility, and whether this can replace headless Chrome yet.

Benchmark and parity runs must disclose cache state:

- Offline checks use in-memory fixtures and do not touch network or browser caches.
- Live native probes create fresh `BrowserRuntime`/fetch sessions and use cache-busted top-level URLs.
- Kuri comparison probes and screenshot fallback open fresh tabs, but they still delegate to the running Kuri/Chrome process. Chrome profile cache, subresource cache, service workers, cookies, and IndexedDB can still affect those fallback-backed probes if the server was already warm.
- Do not use fallback-backed numbers as native-rendering proof.

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

Native SVG paint is now separately available, but it is not 1:1 with real browser rendering:

```sh
zig build run -- paint https://example.com --out example.svg
python3 tools/paint_parity.py https://example.com --keep-artifacts
python3 tools/paint_parity.py https://example.com --direct-svg --keep-artifacts
```

This path does not use Kuri/CDP or Chrome. It paints a text/DOM SVG approximation from the native page model and is useful for token-light visual context, but it is not pixel-equivalent CSS layout or a raster screenshot.

Measured against real Chrome on `https://example.com` at `1280x720`:

- Chrome actual screenshot: **16,577 bytes**
- Native SVG paint artifact: **758 bytes**
- Native SVG rasterized through a no-margin HTML wrapper: **16,583 bytes**
- Exact matching pixels through wrapper: **99.35%**
- Mean absolute RGB delta through wrapper: **0.48/255**
- Direct standalone SVG screenshot exact matching pixels: **87.27%**

The wrapper mode removes Chrome's standalone-SVG page display artifact and measures the renderer content. It is still not 1:1 because the remaining text pixels differ from Chrome's HTML layout/raster path.

Measured against real Chrome on `https://news.ycombinator.com` at `1280x720`:

- Chrome actual screenshot: **159,387 bytes**
- Native SVG paint artifact: **10,127 bytes**
- Native SVG rasterized through a no-margin HTML wrapper: **146,370 bytes**
- Exact matching pixels through wrapper: **88.06%**
- Mean absolute RGB delta through wrapper: **10.58/255**

Measured on cache-busted `https://example.com` in the local live bench before pixel comparison:

- Native SVG paint path: **1,081ms**, **1,557 bytes**
- Kuri/CDP screenshot fallback: **1,657ms**, **18,183 bytes** as JPEG quality 50
- This timing is not a render-correctness claim because the outputs are not equivalent

Current bench result from this branch:

- Offline deterministic readiness: **70%**, not ready
- Offline + live probes readiness: **74%**, not ready
- JS/runtime completeness: **100%**
- Wait semantics: **100%**
- CDP automation surface: **77-79%** depending on live Kuri availability
- Playwright/Puppeteer compatibility: **39%**
- Replace-headless-Chrome readiness: **56-63%** depending on live probes

The latest cache-busted live run passed Hacker News selector extraction, `quotes.toscrape.com/js/`, TodoMVC wait/eval, HAR capture, native SVG paint, the CDP screenshot fallback, the local Kuri health probe, and the minimal local CDP WebSocket dispatch smoke test.

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
| Visual rendering + screenshots | 6 | partial | bench + pixel harness | Native SVG text/DOM paint reaches 99.35% exact pixels on the simple `example.com` wrapper comparison and 88.06% on Hacker News, but it is not 1:1 and full CSS layout, raster screenshots, and PDF are still missing |
| CDP / automation compatibility | 4 | partial | bench | `serve-cdp` exposes HTTP discovery plus a minimal WebSocket JSON-RPC router; broad CDP domains and Playwright/Puppeteer parity are still missing |

## Missing First

1. Full load-state and auto-wait lifecycle hooks.
2. Broader ref-driven actions plus keyboard/select/checkbox parity.
3. More complete DOM events and mutation semantics.
4. Full CSS layout, raster screenshot, and PDF support without the CDP fallback.
5. Broader CDP browser protocol domains beyond the minimal WebSocket router.
