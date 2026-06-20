# Wiring kuri to a Tauri app (macOS WKWebView)

Status: design / proposal. Tracked in the kuri "Tauri / WKWebView control surface" issue.

## Problem

kuri drives Chrome over CDP: it discovers targets via Chrome's `/json/list`
(HTTP) and attaches to each target's `webSocketDebuggerUrl` (CDP over WebSocket)
- see `src/bridge/bridge.zig` (`refreshTabWsUrl`, `getCdpClient`, `cdp_host` /
`cdp_port` default `127.0.0.1:9222`, and the `CDP_URL` config in
`src/bridge/config.zig`).

A **Tauri** desktop app is a webview, but on macOS that webview is **WKWebView
(WebKit)**, which does NOT speak CDP - it speaks the WebKit Remote Web Inspector
(RWI) protocol. So kuri cannot attach to a macOS Tauri app out of the box.
(On Windows, Tauri uses WebView2 = Chromium = CDP, so it already works there; on
Linux it is WebKitGTK = RWI, same gap as macOS.)

## The wire (recommended): a CDP shim on the app's debug bridge

The cleanest path needs **no kuri code change** - kuri already attaches to any
CDP endpoint via `CDP_URL` / `cdp_host:cdp_port`. The work is on the **app side**:
expose a Chrome-CDP-compatible surface that kuri can discover + attach to.

codegraff's Tauri app already ships a debug bridge
(`gui/src-tauri/src/debug_bridge.rs`, HTTP on `:9233`) that evals JS in the
WKWebView and screenshots it (this is how `tdev` clicks/types today). Extend it
to speak the *discovery + minimal CDP* surface kuri expects:

1. `GET /json/version` and `GET /json/list` - return Chrome-style target
   descriptors:
   `[{ "id", "type":"page", "url", "title", "webSocketDebuggerUrl": "ws://127.0.0.1:9233/cdp/<id>" }]`.
   kuri's `refreshTabWsUrl` parses exactly these fields.
2. A WebSocket per target at `/cdp/<id>` implementing a **minimal CDP subset**
   over the WKWebView's `evaluateJavaScript` + screenshot:

   | kuri action       | CDP method                    | WKWebView impl |
   |-------------------|-------------------------------|----------------|
   | navigate          | `Page.navigate`               | eval `location.href = ...` |
   | snapshot (a11y)   | `Accessibility.getFullAXTree` | eval the DOM/a11y walker kuri already ships in `js/` |
   | eval / read value | `Runtime.evaluate`            | `evaluateJavaScript` -> JSON |
   | click (by ref)    | `Input.dispatchMouseEvent`    | eval `el.click()` / synth event |
   | type              | `Input.insertText`            | eval set value + dispatch `input` |
   | screenshot        | `Page.captureScreenshot`      | the bridge's existing WKWebView snapshot -> base64 PNG |

   Most of these the bridge already does via `eval`; the new part is wrapping
   them in CDP request/response framing so kuri's `CdpClient` speaks to them
   unchanged.

Then:

```sh
# point kuri at the Tauri app's CDP shim instead of Chrome
CDP_URL=http://127.0.0.1:9233/json/version kuri
# kuri's full toolset (snapshot, click-by-ref, type, screenshot, HAR) now drives
# the real Tauri app - identical to how it drives Chrome.
```

## Alternative: WKWebView RWI -> CDP bridge (more general, harder)

macOS WKWebView with `isInspectable = true` (Tauri can enable this) exposes the
**WebKit Remote Web Inspector** via `webinspectord`. A standalone proxy that
speaks RWI on one side and CDP (`/json/list` + WS) on the other would let kuri
(and any CDP client) drive *any* WKWebView app, not just ones that ship a
bridge. This is the `ios-webkit-debug-proxy` shape, ported to macOS in Zig.
Bigger lift; the natural long-term home is a `kuri webkit` / `kuri macos`
surface.

## Optional convenience: `kuri tauri`

A thin subcommand mirroring `kuri ios` / `kuri android` that:
- discovers a running Tauri app's bridge port (default `:9233`),
- sets `cdp_host` / `cdp_port` to it,
- exposes the same verbs as the browser path (snapshot/click/type/screenshot).

No new protocol - just discovery + config sugar over the CDP attach above.

## Why this shape

- Reuses kuri's existing CDP client, snapshot/ref-cache, and HAR machinery
  unchanged (`src/bridge`, `src/cdp`, `src/snapshot`).
- Reuses the app's existing eval bridge - the hard part (driving WKWebView) is
  already solved by `debug_bridge.rs` / `tdev`.
- One automation surface (kuri) for browser + iOS + Android + Tauri.
