# kuri vs chrome-devtools-mcp — capability + token-efficiency comparison

A 1:1 comparison of kuri against [ChromeDevTools/chrome-devtools-mcp](https://github.com/ChromeDevTools/chrome-devtools-mcp):
capability coverage, and **per-snapshot token cost** (the metric that dominates an
agent's token budget, since a snapshot is taken almost every step).

## Environment (per AGENTS.md benchmark-honesty rules)

- Date: 2026-05-31 (UTC)
- Machine/OS: Darwin arm64 (macOS, Apple Silicon)
- Chrome: Google Chrome 148.0.7778.179 (headless=new)
- chrome-devtools-mcp: v1.1.1 (installed via npm), driven over MCP stdio
- kuri: built from `release/0.5.0`, Zig 0.16.0
- Token counts: `tiktoken` `cl100k_base` encoding (locally computed)
- Run mode: **fair same-tab** — one Chrome launched with `--remote-debugging-port=9222`;
  chrome-devtools-mcp attached via `--browserUrl http://127.0.0.1:9222`, kuri attached
  via the same CDP. Both snapshot the **identical rendered DOM**. Cache state: a fresh
  Chrome profile (cold) per run; live public pages (not cache-busted — see caveat).

## Token efficiency — `take_snapshot` (the headline)

Same page, same render, snapshot output token count (lower = cheaper per agent step):

| Page | chrome-devtools-mcp `take_snapshot` | kuri `snap` (compact) | kuri `snap --interactive` |
|---|---|---|---|
| Hacker News (`news.ycombinator.com`) | 13,195 | **4,141 (3.2× fewer)** | **2,380 (5.5× fewer)** |
| Wikipedia "Web browser" | 38,914 | **8,953 (4.3× fewer)** | **3,922 (9.9× fewer)** |

**kuri's accessibility snapshot is 3–10× fewer tokens than chrome-devtools-mcp's** for the
same page. The gap comes from kuri pruning semantically-empty nodes (`none`, bare layout
rows) and inlining names, whereas chrome-devtools-mcp emits the fuller a11y tree with a
`uid=…`/`url=…` line per node.

### Same result over MCP

kuri ships `kuri-mcp`, a stdio MCP server (chrome-devtools-mcp-compatible tool names)
that forwards to the kuri HTTP API. Its `take_snapshot` returns kuri's compact snapshot,
so the token advantage holds when kuri is consumed *as an MCP server*: **4,137 tokens vs
13,195** on Hacker News (verified end-to-end over the MCP handshake).

## Capability coverage (1:1 tool mapping)

| chrome-devtools-mcp | kuri |
|---|---|
| Input: click, drag, fill, hover, press_key, type_text, upload_file, click_at, handle_dialog | ✅ all (`/action`, `/drag`, `/keyboard/*`, `/upload`, `/mouse/*`, `/tap`, `/dialog/*`) |
| Navigation: navigate/new/close/list/select page, wait_for | ✅ all |
| Emulation: emulate, resize | ✅ exceeds (split into `/emulate`, `/set/offline`, `/geolocation`, `/set/media`, `/set/viewport`, `/set/useragent`, `/timezone`, `/locale`) |
| Network: list/get request | ✅ (`/network`, `/har/*`, `/request/detail`, `/response/body`, `/intercept/*`) |
| Debugging: evaluate, console, screenshot, snapshot, screencast | ✅ all |
| MCP server transport | ✅ now via `kuri-mcp` (12 tools) |
| **lighthouse_audit** | ❌ none (kuri `/audit` is *security*, not Lighthouse) |
| **performance_analyze_insight** | ◑ raw `/trace/*`, `/vitals`, `/perf/lcp` — no Insights/CrUX analysis |
| **Memory heap snapshot (+4 analysis tools)** | ❌ none (kuri has CPU `/profiler/*`, not heap) |
| **Extension management** (install/uninstall/reload/trigger/list) | ❌ none (load via config only) |
| **WebMCP / 3p developer tools** | ❌ none (experimental Chrome) |

kuri also has a large surface chrome-devtools-mcp lacks: React DevTools inspection,
cookie/JWT/storage extraction, security audit + IDOR probe, stealth, the nanostore
auth/connect vault, markdown/links/PDF extraction, set-of-marks screenshots, snapshot
diffing, clipboard, batch, recording export.

## Verdict
- **Token efficiency: kuri wins decisively** — 3–10× fewer snapshot tokens, the cost that
  recurs every agent step. Holds both as a CLI and as an MCP server (`kuri-mcp`).
- **Capabilities: kuri is a superset on automation/security**, missing four
  *DevTools-diagnostic* tools (Lighthouse, heap snapshots, analyzed Performance Insights,
  extension management) and the experimental WebMCP/3p tools.

## Caveats (honest)
- Live public pages were used without cache-busting; content can drift between runs, so
  absolute token counts vary — the **ratio** is the stable signal and was consistent across
  two structurally different pages.
- chrome-devtools-mcp `take_snapshot` is the full tree; kuri `--interactive` filters to
  actionable elements (not apples-to-apples with the full snapshot — both columns shown).
- This measures snapshot payload tokens only, not end-to-end task success or model quality.

### Reproduce

```sh
# shared Chrome
"Google Chrome" --headless=new --remote-debugging-port=9222 --user-data-dir=$(mktemp -d) https://news.ycombinator.com
# chrome-devtools-mcp (MCP): initialize -> select_page -> take_snapshot via --browserUrl http://127.0.0.1:9222
npx chrome-devtools-mcp@1.1.1 --browserUrl http://127.0.0.1:9222
# kuri: attach + compact snapshot
kuri-agent use <ws> && kuri-agent snap          # compact
kuri-agent snap --interactive                   # actionable-only
# count tokens with tiktoken cl100k_base
```
