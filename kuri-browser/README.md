# kuri-browser

Experimental standalone browser-runtime workspace for Kuri.

This folder is intentionally not wired into the root `build.zig`. It exists as a separate Zig build so we can prototype a standalone fetch + DOM + JS runtime without disturbing Kuri's current Chrome/CDP path.

## Current Layout

- `src/model.zig`: shared `Page`, `Link`, and fallback-mode types
- `src/core.zig`: runtime shape plus page-loading orchestration
- `src/dom.zig`: parsed DOM tree plus basic selector queries
- `src/fetch.zig`: network acquisition, validation, redirects, and `curl` fallback
- `src/render.zig`: parsed-page extraction into the shared page model
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
- start with real HTTP fetch plus a parsed DOM tree and selector queries
- keep a stable `Page` model so future DOM/JS layers have a fixed handoff point
- keep JS, layout, and CDP compatibility out of scope for the first slice

## Current Commands

```sh
zig build run -- status
zig build run -- roadmap
zig build run -- render https://news.ycombinator.com
zig build run -- render https://example.com --dump html
zig build run -- render https://news.ycombinator.com --dump links
zig build run -- render https://news.ycombinator.com --selector ".titleline a" --dump text
```

## Target Direction

1. HTTP navigation, redirects, cookies, and resource loading
2. DOM tree construction and selector queries
3. Embedded JS runtime for page execution
4. Agent-facing snapshot/evaluate APIs
5. Optional partial CDP compatibility once the core runtime is stable
