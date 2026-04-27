# AGENTS.md

Instructions for AI coding agents working in this repository.

## Benchmark Honesty

Never present a benchmark, parity score, or competitor comparison as stronger than the evidence supports.

- Always include the exact command, branch, commit, date, machine/OS when known, Zig/Chrome versions when relevant, run mode, and whether the run was offline or live.
- Always state whether each number is locally measured, CI-measured, copied from upstream documentation, or inferred from code inspection.
- Always report skipped checks, failed probes, timeouts, warmups, iteration counts, and sample size. Do not average away failures.
- Never compare Kuri numbers against another project's README numbers as apples-to-apples unless the same hardware, URLs, browser engine, cache policy, process model, and measurement tool were used.
- Treat README benchmark tables from other projects as upstream claims until reproduced locally.
- Do not claim `kuri-browser` can replace headless Chrome, Playwright, Puppeteer, Obscura, Lightpanda, or agent-browser unless the bench proves the same protocol surface and workload.
- If a benchmark depends on Kuri's Chrome/CDP fallback, label it as fallback-backed, not native `kuri-browser` rendering.

## Cache Disclosure

Benchmarks must explicitly disclose cache state.

- Prefer cold runs with fresh processes, fresh profiles, and cache-busted top-level URLs.
- If a live URL is used, add a cache-busting query parameter unless the endpoint semantics would be changed by doing so.
- If Chrome/CDP is involved, disclose whether the Chrome profile, HTTP cache, service workers, cookies, or IndexedDB may be warm.
- If a benchmark intentionally uses warm cache, label it `warm-cache` and explain why.
- If cache state is unknown, say `cache=unknown` and do not use the number for competitive claims.
- For `kuri-browser bench`, native fetch probes should use fresh runtime/fetch sessions. The screenshot probe delegates to Kuri/Chrome, so it must keep disclosing that Chrome cache can still affect fallback-rendered screenshots.

## Current Browser Baselines

Last refreshed from GitHub on 2026-04-26. Recheck upstream before changing comparative claims.

| Project | What it is | Current signal | How Kuri compares today |
|---|---|---|---|
| Obscura | Rust headless browser engine for agents/scraping | README claims V8, CDP, Puppeteer/Playwright compatibility, stealth mode, and Chrome-replacement metrics. The repo is split into `obscura-dom`, `obscura-net`, `obscura-browser`, `obscura-js`, `obscura-cdp`, and `obscura-cli`; `obscura-js` uses `deno_core` and creates a V8 startup snapshot. | `kuri-browser` is behind on engine completeness, stealth, and broad CDP. It has QuickJS-backed eval and a minimal CDP shim only. Do not claim parity. |
| Lightpanda | Zig headless browser designed for AI/automation | README says it is beta, uses V8, has DOM APIs, Ajax, cookies, proxy, network interception, CDP/websocket server, Puppeteer support, MCP, and a transparent 933-page crawler benchmark. Its `build.zig.zon` depends on `lightpanda-io/zig-v8-fork`, libcurl, html5ever-related pieces, and other browser infrastructure. | `kuri-browser` is architecturally closer because it is a Zig-native experiment, but it is much smaller: QuickJS, no native layout/paint, minimal CDP, no broad Web API matrix. |
| Vercel agent-browser | Rust browser automation CLI/daemon for AI agents | It is not a new browser engine. It drives Chrome for Testing or detected Chrome via CDP, has broad CLI actions, snapshots, screenshots, PDF, HAR, sessions/profiles, React/Web Vitals tooling, and benchmarks Node daemon vs Rust daemon in Vercel Sandbox. | Main `kuri` is the closer comparison because both automate Chrome/CDP. `kuri-browser` is not comparable as a Chrome replacement yet. |

Source URLs to recheck:

- https://github.com/h4ckf0r0day/obscura
- https://github.com/lightpanda-io/browser
- https://github.com/lightpanda-io/demo/blob/main/BENCHMARKS.md
- https://github.com/vercel-labs/agent-browser
- https://github.com/vercel-labs/agent-browser/tree/main/benchmarks

## Competitive Comparison Rules

- Obscura comparison must separate upstream claims from local reproduction. Its README currently does not provide enough hardware/cache/run detail for its headline table to be treated as verified here.
- Lightpanda comparison may cite its benchmark protocol because it publishes hardware, Chrome version, commit, page count, measurement tools, and commands. Still disclose that the upstream benchmark is their environment unless rerun locally.
- Agent-browser comparison must not be framed as native-browser parity. It benchmarks daemon overhead while still using Chrome, so compare it to Kuri's Chrome/CDP HTTP-agent path, not to `kuri-browser` native rendering.
- For any new comparison table, include a `Not Comparable Yet` row when workloads differ.
- If a score increases because a fallback path was added, report both native-only and fallback-backed interpretation.

## Local Verification Baseline

Before pushing browser-runtime benchmark changes, run:

```sh
cd kuri-browser
zig fmt src/bench.zig src/parity.zig src/cdp_server.zig src/js_runtime.zig
zig build test
zig build
./zig-out/bin/kuri-browser bench --offline
./zig-out/bin/kuri-browser parity --offline
```

When running live validation, start Kuri from a known state and record whether it was a fresh process:

```sh
cd ..
zig build
./zig-out/bin/kuri

cd kuri-browser
./zig-out/bin/kuri-browser bench --kuri-base http://127.0.0.1:8080
./zig-out/bin/kuri-browser parity --kuri-base http://127.0.0.1:8080
```
