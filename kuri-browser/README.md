# kuri-browser

Experimental standalone browser-runtime workspace for Kuri.

This folder is intentionally not wired into the root `build.zig`. It exists as a separate Zig build so we can prototype an Obscura-style fetch + DOM + JS runtime without disturbing Kuri's current Chrome/CDP path.

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
- start with real HTTP fetch plus a minimal HTML-to-text renderer
- keep JS, layout, and CDP compatibility out of scope for the first slice

## Current Commands

```sh
zig build run -- status
zig build run -- roadmap
zig build run -- render https://news.ycombinator.com
```

## Target Direction

1. HTTP navigation, redirects, cookies, and resource loading
2. DOM tree construction and selector queries
3. Embedded JS runtime for page execution
4. Agent-facing snapshot/evaluate APIs
5. Optional partial CDP compatibility once the core runtime is stable
