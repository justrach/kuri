# kuri-browser

Experimental standalone browser-runtime workspace for Kuri.

This folder is intentionally not wired into the root `build.zig`. It exists as a separate Zig build so we can prototype a standalone fetch + DOM + JS runtime without disturbing Kuri's current Chrome/CDP path.

## Current Layout

- `src/model.zig`: shared `Page`, `Link`, and fallback-mode types
- `src/core.zig`: runtime shape plus page-loading orchestration
- `src/dom.zig`: parsed DOM tree plus basic selector queries
- `src/fetch.zig`: network acquisition, validation, redirects, and `curl` fallback
- `src/js_engine.zig`: QuickJS-backed page execution plus browser API shims
- `src/render.zig`: parsed-page extraction into the shared page model
- `src/native_paint.zig`: native SVG text/DOM paint output
- `src/screenshot.zig`: screenshot fallback through Kuri's existing CDP server
- `src/bench.zig`: replacement-readiness benchmark
- `src/parity.zig`: weighted parity score against Kuri's current browser surface
- `src/cdp_server.zig`: minimal Chrome-style HTTP discovery plus WebSocket JSON-RPC routing
- `src/shell.zig`: CLI-facing usage, status, roadmap, and text rendering
- `src/runtime.zig`: thin facade used by `src/main.zig`

This is intentionally closer to the repo boundaries in `nanoapi` and `turboAPI`: stable shared types in the middle, thin shell edges, and transport/rendering logic kept separate.

## Build

```sh
cd kuri-browser
zig build
zig build run -- --help
zig build run -- status
zig build run -- render https://example.com
```

## Current Scope

- keep Kuri's existing managed-Chrome/CDP server untouched
- prototype a Zig-native browser runtime in isolation
- use real HTTP fetch, redirects, cookies, parsed DOM, selector queries, and QuickJS-backed page evaluation
- keep a stable `Page` model so future DOM/JS layers have a fixed handoff point
- provide a small CDP discovery and WebSocket JSON-RPC shim while the native runtime evolves
- keep full native CSS layout, raster screenshots, PDF, broad CDP domain coverage, and full Playwright/Puppeteer compatibility out of scope until the runtime is stable

This is not wired into the root `zig build`, and it is not a production replacement for Kuri's managed Chrome path yet.

## Current Commands

```sh
zig build run -- status
zig build run -- roadmap
zig build run -- parity --offline
zig build run -- bench --offline
zig build run -- render https://news.ycombinator.com
zig build run -- render https://example.com --dump html
zig build run -- render https://news.ycombinator.com --dump links
zig build run -- render https://news.ycombinator.com --selector ".titleline a" --dump text
zig build run -- render https://todomvc.com/examples/react/dist/ --js --wait-eval "document.querySelectorAll('.todo-list li').length >= 1"
zig build run -- render https://example.com --har example.har
zig build run -- paint https://example.com --out example.svg
zig build run -- serve-cdp --port 9333
```

### CDP Shim

`serve-cdp` is an experimental compatibility shim, not a full browser protocol implementation.

```sh
zig build run -- serve-cdp --port 9333
curl http://127.0.0.1:9333/json/version
curl http://127.0.0.1:9333/json/list
```

The advertised `webSocketDebuggerUrl` upgrades to WebSocket and routes a small JSON-RPC surface: `Browser.getVersion`, basic `Target` lifecycle, `Runtime.evaluate`, `Page.navigate`, `Page.getFrameTree`, `DOM.getDocument`, and no-op enable/input methods. Runtime values are V8-shaped CDP remote objects backed by the existing QuickJS page runtime; no V8 dependency is added.

This is enough for local protocol smoke tests and parity tracking. It is not enough to replace Chrome for Playwright/Puppeteer yet because sessions, isolated worlds, robust target/frame events, locator actionability, screenshots, tracing, downloads, and native layout/paint are still incomplete.

### Native SVG Paint

`paint` writes a native SVG approximation directly from the fetched page model:

```sh
zig build run -- paint https://example.com --out example.svg
```

This does not call Kuri/CDP or Chrome. It is useful for fast, token-light visual context from page title, text, links, form controls, images, and code blocks. It is not CSS layout, raster screenshot, PDF, canvas, video, or pixel-equivalent rendering.

Check pixel parity against real Chrome before treating this as a renderer replacement:

```sh
zig build
python3 tools/paint_parity.py https://example.com --keep-artifacts
python3 tools/paint_parity.py https://example.com --direct-svg --keep-artifacts
```

Current local Chrome comparison on `https://example.com` at `1280x720`:

- Chrome actual screenshot: `16,577` bytes
- Native SVG paint artifact: `758` bytes
- Native SVG rasterized through a no-margin HTML wrapper: `16,583` bytes
- Exact matching pixels through wrapper: `99.35%`
- Mean absolute RGB delta through wrapper: `0.48/255`
- Direct standalone SVG screenshot exact matching pixels: `87.27%`

So this is much closer for the simple `example.com` target, but it is still not 1:1. Exact pixel parity requires matching Chrome's layout, font shaping, antialiasing, viewport behavior, and raster pipeline, not just drawing similar SVG text.

Current local Hacker News comparison on `https://news.ycombinator.com` at `1280x720`:

- Chrome actual screenshot: `159,387` bytes
- Native SVG paint artifact: `10,127` bytes
- Native SVG rasterized through wrapper: `146,370` bytes
- Exact matching pixels through wrapper: `88.06%`
- Mean absolute RGB delta through wrapper: `10.58/255`

### Screenshot Fallback

`kuri-browser` can capture screenshots through the existing Kuri/CDP renderer while full native layout and raster paint are still missing.

Start the normal Kuri server in another terminal:

```sh
cd ..
zig build
./zig-out/bin/kuri
```

Then run:

```sh
cd kuri-browser
zig build run -- screenshot https://example.com --out example.png --kuri-base http://127.0.0.1:8080
zig build run -- screenshot https://example.com --out example.jpg --compress --kuri-base http://127.0.0.1:8080
```

`--compress` is token-oriented. It captures a PNG baseline, captures a JPEG candidate, keeps whichever file is smaller, fixes the output extension to match the selected format, and prints:

- `original-bytes`: PNG baseline size
- `bytes`: selected output size
- `saved-bytes`: byte delta versus PNG
- `saved-percent`: rounded percentage saved versus PNG

Current local measurement on `https://example.com`: PNG `20,523` bytes to JPEG quality 50 `18,183` bytes, saving `2,340` bytes or `11%`.

### Readiness Checks

Use these commands to keep the experiment honest:

```sh
zig build test
zig build run -- parity --offline
zig build run -- bench --offline
zig build run -- bench --kuri-base http://127.0.0.1:8080
```

The current live bench is useful for tracking progress, but the answer is still "not ready to replace headless Chrome" until broader CDP browser domains, full native layout/raster paint, pixel-parity checks, and Playwright/Puppeteer lifecycle support exist.

## Target Direction

1. HTTP navigation, redirects, cookies, and resource loading
2. DOM tree construction and selector queries
3. Embedded JS runtime for page execution
4. Agent-facing snapshot/evaluate APIs
5. Broader CDP and Playwright/Puppeteer compatibility once the core runtime is stable
