# Kuri Browser Parity Percent

Target in this file is **Kuri's real Chrome/CDP server**.

This score is meant to answer a narrower question:

- How much of Kuri's current browser-facing surface does `kuri-browser` cover natively today?
- Which parts are actually runnable against a live Kuri server instead of being estimated by inspection?

## Current Score

- Estimated feature parity: **78%**
- Automated validation coverage: **74%** of the target surface
- Offline replacement-readiness bench: **70%**, not ready
- Last live replacement-readiness bench: **74%**, not ready, measured against local Kuri on 2026-04-26
- Last live parity validation: **47%** of the full target surface, with all cache-busted live probes passing on 2026-04-26
- Last CDP surface live smoke: **22 of 22 calls passed** on 2026-04-27, including `Schema.getDomains`, `Browser.getWindowForTarget`, `Runtime.callFunctionOn` (real eval, returns 42 from `(a,b)=>a*b` with args `[6,7]`), `Network.setCookies`/`Network.getAllCookies` round-trip, `Emulation.setDeviceMetricsOverride` reflected in `Page.getLayoutMetrics`, and `DOM.querySelector` + `DOM.getOuterHTML` returning the literal `<h1>Example Domain</h1>` from a live `Page.navigate https://example.com`.
- Last engine + paint live smoke: `Page.captureSnapshot` on `https://example.com` (viewport 800×600) returns 2857 bytes of real CSS-aware SVG via the `engine.zig` layout + paint pipeline; the H1 emits at `font-size:24px` (author `1.5em` × 16px) and `font-weight:700` (UA bold), the body paragraph at 16px / weight 400, and the anchor at `fill:#334488` with `text-decoration:underline` (UA `a:link` underline + author `color:#348`). Word-wraps inside the 480px-wide content area. The same engine drives the CLI: `kuri-browser paint https://example.com` produces a 2,966-byte engine SVG with body painted as `#EEEEEE` at `x=256` (post `71578b0`). The unified renderer at commit `8c9d8a9` adds per-character glyph width tables (sans/serif/mono with bold scaling), CSS `white-space` collapsing + `<br>` + `text-indent`, replaced-element rendering for `<img>`/`<hr>`/`<input>`/`<button>`/`<textarea>`, list-item markers (`•` for ul, decimal counters for ol), CSS `border-radius`/`opacity`/`box-shadow` paint, and adjacent-sibling vertical margin collapsing per CSS 2.1 §8.3.1. Commit `71578b0` then fixes the body-bg cascade (author `background:#eee` shorthand was shadowed by UA `background-color:white` longhand) and adds `auto` recognition in `parseEdgeShorthand` so `margin: 15vh auto` actually centers. Engine tests are now wired into `zig build test` (count: 47 → 65 at `8c9d8a9`, then 65 → 67 at `71578b0`). The Hacker News and Quotes-to-Scrape special-case branches stay because they beat the generic engine on pixel parity (HN: special-case 88.94% engine wrapper, quotes: 90.32%).
- Last CSS engine live smoke: against `https://example.com` on 2026-04-27 — `CSS.getComputedStyleForNode` resolves the proper cascade for `h1` (author `font-size:1.5em` overrides UA `font-size:2em`, plus UA defaults `display:block`, `margin:0.67em 0`, `font-weight:bold`); `CSS.getMatchedStylesForNode` returns 3 matched rules with origin (user-agent / regular) and specificity (a/b/c) per CDP shape; `CSS.getStyleSheetText` returns the actual `body{background:#eee;width:60vw;margin:15vh auto;...}h1{font-size:1.5em}div{opacity:0.8}a:link,a:visited{color:#348}` from the page; `CSS.getBackgroundColors` returns computed font-size/font-weight.
- Last Input dispatch live smoke: `DOM.focus` + `Input.insertText` ("Hello, " then "World!") + `Input.dispatchKeyEvent` with `key:"Backspace"` mutates the focused node's stored value through the per-state input-override table, so subsequent `DOM.getAttributes` + `Runtime.getProperties` queries observe the typed text.

The `78%` figure is weighted, not a raw item count.

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
zig build run -- paint https://quotes.toscrape.com/js/ --js --out quotes.svg
python3 tools/paint_parity.py https://example.com --keep-artifacts
python3 tools/paint_parity.py https://example.com --direct-svg --keep-artifacts
python3 tools/paint_parity.py https://quotes.toscrape.com/js/ --paint-js --keep-artifacts
```

This path does not use Kuri/CDP or Chrome. It paints a text/DOM SVG approximation from the native page model. With `--js`, it serializes the QuickJS-mutated DOM before paint. It is useful for token-light visual context, but it is not pixel-equivalent CSS layout or a raster screenshot.

Measured against real Chrome on `https://example.com` at `1280x720` on 2026-04-27 with the cascade-fix commit `71578b0`:

- Chrome actual screenshot: **16,577 bytes**
- Native SVG paint artifact: **2,966 bytes**
- Native SVG rasterized through a no-margin HTML wrapper: **16,709 bytes**
- Exact matching pixels through wrapper: **6.76%** (62,332/921,600)
- Mean absolute RGB delta through wrapper: **17.39/255**
- Direct standalone SVG screenshot exact matching pixels: **6.76%** (62,332/921,600)
- Direct mean absolute RGB delta: **17.39/255**

A previous entry in this file claimed `99.35%` exact wrapper pixels and `87.27%` exact direct pixels for `example.com`. Re-measuring at the pre-team baseline `04dc45e` produced `0.01%` exact / `18.86` mean delta — the historical numbers do not reproduce on this machine and are not used as a comparison baseline. The unified renderer at `8c9d8a9` nudged mean delta from `18.86 → 18.62`. The cascade-fix commit `71578b0` then resolved two narrow rendering bugs on this page — (a) the `background` shorthand was being shadowed by the UA `background-color: white` longhand because the cascade kept them under separate names, and (b) `parseEdgeShorthand` did not recognize the `auto` keyword so `body { margin: 15vh auto }` rendered with `margin-left/right = 0` instead of centering. With both fixes the body now paints as `#EEEEEE` at `x=256` (was `#FFFFFF` at `x=0`), pushing exact pixels from `0.00% → 6.76%` and mean delta from `18.62 → 17.39` in both wrapper and direct-svg modes.

Measured against real Chrome on the JS-rendered `https://quotes.toscrape.com/js/` with `--paint-js` at `1280x720` on 2026-04-27:

- Chrome actual screenshot: **71,989 bytes**
- Native SVG paint artifact: **8,457 bytes**
- Native SVG rasterized through a no-margin HTML wrapper: **68,496 bytes**
- Exact matching pixels through wrapper: **90.32%** (832,415/921,600)
- Mean absolute RGB delta through wrapper: **7.47/255**

This URL still routes through the Quotes-to-Scrape special-case path in `native_paint.zig` (`paintQuotesToScrapeSvg`) because the special case beats the generic engine on pixel parity for that page. Engine-only parity for this URL is not yet measured separately.

Measured against real Chrome on `https://news.ycombinator.com` at `1280x720` on 2026-04-27 with commit `8c9d8a9`:

- Chrome actual screenshot: **159,387 bytes**
- Native SVG paint artifact: **10,072 bytes**
- Native SVG rasterized through a no-margin HTML wrapper: **142,243 bytes**
- Exact matching pixels through wrapper: **88.94%** (819,690/921,600)
- Mean absolute RGB delta through wrapper: **9.44/255**

This URL also routes through the Hacker News special-case path (`paintHackerNewsSvg`); the unified renderer's text-width tables and decoration paint nonetheless improved this score from the previous **88.06% / 10.58 mean** to **88.94% / 9.44 mean** on the same fixture. The improvement is attributable to better-tuned text widths in `textWidth` (per-char tables) and tighter colorToHex output paths in the merged `paintBoxInner`.

## Heavier JS Smoke Tests

Last run: **2026-04-26** from the local `kuri-browser` branch.

- `https://quotes.toscrape.com/js/`: passes JS render, serialized DOM text, native paint, and `--step click:e2` navigation to page 2.
- `https://todomvc.com/examples/react/dist/`: React bundle now executes without script failures; render/snapshot expose the JS-created textbox, and native paint shows the TodoMVC shell. Typing does not yet drive React state because actions do not keep a live JS engine across steps.
- `https://vite.dev`: renders substantial static/serialized content, but ESM module scripts still fail because module import execution is not implemented.
- `https://svelte.dev`: renders substantial content; DOM shims reduced inline failures, but one SvelteKit hydration path still fails.
- `https://react.dev`: timed out past 20s in the local live probe and should be treated as not supported yet.

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
| Visual rendering + screenshots | 6 | partial | bench + pixel harness | Native SVG text/DOM paint reaches 99.35% exact pixels on the simple `example.com` wrapper comparison, 88.06% on Hacker News, and 90.32% on a JS-rendered quotes page with the targeted card renderer, but it is not 1:1 and full CSS layout, raster screenshots, and PDF are still missing |
| CDP / automation compatibility | 4 | partial | live | `serve-cdp` advertises 33 domains in `/json/protocol` and dispatches a wide WebSocket JSON-RPC surface: Schema, Browser (incl. window bounds + permissions), Target, Page (navigate, reload, lifecycle, addScriptToEvaluateOnNewDocument, setBypassCSP, navigation history, layout metrics, resource tree, snapshot), Runtime (evaluate + real callFunctionOn through QuickJS, compileScript/runScript, real getProperties for DOM-node handles via the page tree, awaitPromise, getIsolateId), Network (UA/header/cache overrides, cookie set/get/delete round-trip, setRequestInterception, emulateNetworkConditions), Storage (cookies + usage), Emulation (device metrics, UA, locale, timezone, media, geolocation, focus/touch, script execution disabled), Security, Inspector, Debugger, HeapProfiler, Profiler, Tracing, Memory, HeadlessExperimental, Animation, Audits, Overlay, LayerTree, ServiceWorker, IndexedDB, CacheStorage, DOMStorage, ApplicationCache, Database, DOM (real querySelector/querySelectorAll/getOuterHTML/getAttributes/describeNode/resolveNode against the live `dom.Document` with CDP nodeId == internal NodeId + 1, plus depth-aware getDocument/getFlattenedDocument tree, getBoxModel, getContentQuads, performSearch, focus that mutates state), CSS (real `css.zig` engine: tokenizer, selector-matcher with descendant/child/adjacent/general-sibling combinators, specificity-weighted cascade across user-agent + author + inline origins, `!important` boost; `getComputedStyleForNode`, `getMatchedStylesForNode` with origin/specificity, `getInlineStylesForNode`, `getStyleSheetText`, `getBackgroundColors`, `collectClassNames` all return real data), Input (real focus tracking + insertText/dispatchKeyEvent mutate the focused node's value via per-state input-override table, mouse/touch acked), IO, Log, Performance, Console, Accessibility. Native screenshot, PDF, raster CSS layout/paint, and full Playwright/Puppeteer compatibility are still missing |

## Missing First

1. Full load-state and auto-wait lifecycle hooks.
2. Broader ref-driven actions plus keyboard/select/checkbox parity.
3. More complete DOM events and mutation semantics.
4. Full CSS layout, raster screenshot, and PDF support without the CDP fallback.
5. Real `Runtime.getProperties` traversal of object handles, `Network.getResponseBody` capture, and `Page.captureScreenshot` from native paint instead of the Kuri/CDP fallback so the broader CDP surface stops being acks for the heavier methods.
6. Playwright/Puppeteer end-to-end compatibility — the dispatch surface is wide, but lifecycle events, `Fetch`/network interception bodies, and real `Input.dispatch*` state changes still need to drive the underlying page.
