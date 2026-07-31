# kuri vs libretto — token efficiency and loop economics

A head-to-head against [saffron-health/libretto](https://github.com/saffron-health/libretto)
(v0.6.33, MIT, TypeScript + Playwright + Node). libretto is the closest competitor
to kuri on the axis that matters for agents: **how many tokens a browser costs per
step**. This document is deliberately even-handed — kuri wins some cases and loses
others, and the losses are stated as plainly as the wins.

## Environment (per AGENTS.md benchmark-honesty rules)

- Date: 2026-07-04 (UTC)
- Machine/OS: Darwin arm64 (macOS, Apple Silicon)
- Chrome: Google Chrome 149.0.7827.201, one instance on `--remote-debugging-port=9333`
- kuri: built from `release/0.5.0`, Zig 0.16.0, attached via `CDP_URL`
- libretto: v0.6.33, attached to the **same** Chrome via `libretto connect http://127.0.0.1:9333`
- Token counts: `tiktoken` `o200k_base` (GPT-4o-class), computed locally
- **Fair same-tab**: both tools drive the identical rendered DOM on the same tab, so
  page content is byte-identical. libretto's screenshot-path and hint lines are stripped
  so only the page representation the model reasons over is counted.
- Fixtures: four local static pages (`simple`, `form`, `article`, and a 50-item `feed`)
  served over `lvh.me:8899` — now committed under `bench/fixtures/`.
- kuri numbers were re-measured after the parser was rewritten as a DFS pre-order tree
  walk (which re-orders the default snapshot); each page moved by ~3 tokens. libretto
  numbers are from the same day, same Chrome, same fixtures.

## 1. Per-observation: one snapshot of each page

Lower tokens = cheaper per agent step. "refs" = actionable elements exposed in that one
call. `limit=5` is kuri's opt-in sibling-run truncation (see §4); the default remains
full enumeration.

| Page | kuri tokens | libretto tokens | kuri refs | libretto refs | libretto truncations |
|---|---:|---:|---:|---:|---:|
| simple | **61** | 151 | 5 | 6 | 1 |
| form | 308 | **240** | 26 | 9 | 1 |
| article | **265** | 363 | 8 | 12 | 1 |
| feed (50 items), kuri default | 4,424 | **813** | 259 | 35 | 6 |
| feed (50 items), kuri `limit=5` | **555** | 813 | 34 | 35 | 6 |
| **total, kuri defaults** | 5,058 | **1,567** | — | — | — |
| **total, `limit=5` on the feed** | **1,189** | 1,567 | — | — | — |

**Read this honestly:**
- kuri wins the small and article pages (2.5× and 1.37× fewer tokens) on grammar alone —
  `@e0` refs, no per-line prefix, aggressive noise pruning.
- On the large feed the outcome depends on which mode you run. kuri's **default** emits all
  259 interactive elements — 5.4× more tokens than libretto, which truncates to ~4 children
  per container **by default**. With `limit=5`, kuri renders the first 5 items per sibling
  run plus a `… +45 more` marker and comes in at 555 tokens — **1.46× under libretto's 813**,
  with a comparable ref count (34 vs 35).
- The trade is explicit in both tools, but the defaults differ: libretto always truncates and
  expects the agent to drill in; kuri defaults to every ref up front (act on item #40
  immediately, no follow-up) and truncates only when asked. With `limit` the drill-in is
  `snapshot?scope=@ref` — a fresh scoped re-capture, never a cached subtree.

## 2. Latency per call

kuri is a persistent HTTP server; libretto is a CLI that boots Node on every invocation
(a background daemon holds the browser, but each command still pays V8 + module init).

| Page | kuri snapshot | libretto snapshot | ratio |
|---|---:|---:|---:|
| simple | 3.6 ms | 1,344 ms | 376× |
| form | 13.8 ms | 1,378 ms | 100× |
| article | 8.1 ms | 1,359 ms | 167× |
| feed | 117 ms | 1,500 ms | 13× |

kuri answers in single-digit-to-low-hundreds of milliseconds; libretto's floor is ~1.3 s
per command regardless of page. For an agent taking dozens of steps this is the difference
between a responsive loop and a visibly slow one — but it is wall-clock, not tokens, and
does not affect model cost.

## 3. Per-trajectory: the steady-state agent loop

The number that actually decides "tokens per task." Scenario: the 50-item feed, then
**9 upvote clicks**, re-observing after each action. All kuri rows were measured by
[`bench/loopcalc`](../bench/loopcalc/) replaying the identical click sequence under each
observation strategy (per-step = median). The libretto row is the same-day exec-loop run.

| Loop | Base observation | Per-step | 9 steps total |
|---|---:|---:|---:|
| kuri: full snapshot every step | 4,424 | 4,429 | 44,285 |
| kuri: `filter=interactive` every step | 2,897 | 2,899 | 28,988 |
| kuri: diff loop (first diff renders the whole page) | 4,937 | 38 | 5,280 |
| kuri: `limit=5` snapshot every step | 555 | 560 | 5,587 |
| kuri: `filter=interactive` base + diff loop | 2,897 | 38 | 3,240 |
| **kuri: `limit=5` base + diff loop** | **555** | **38** | **898** |
| **libretto: exec loop** | 813 | ~14 | **939** |

**kuri now takes this trajectory: 898 vs 939 tokens.** Treat it as parity-to-slight-edge —
4% is within run-to-run noise — but the loss is gone. The 2026-07-04 morning run had kuri
at 4,753 (5.1× behind) because its base observation enumerated the whole feed; the DFS
tree walk + `limit` truncation cut that base 8× (4,424 → 555), and the diff loop keeps
every subsequent step at ~38 tokens. Against kuri's own naive loop (full snapshot every
step), the truncated diff loop is **49× cheaper**.

## Verdict

- **Latency: kuri wins overwhelmingly** (13–376× faster per call) — a persistent server vs
  Node-per-command.
- **Per-observation tokens: kuri wins typical pages; on large lists it wins with `limit`,
  loses at its default.** kuri's grammar is tighter; truncation is opt-in where libretto's
  is always-on.
- **Per-trajectory tokens: parity, slight kuri edge** (898 vs 939) once the loop uses
  `limit` + diffs. The morning's 5.1× loss was the untruncated base, now fixed.
- **Architectural split:** kuri is ref-based (`snapshot → click @e40`) — simple for the
  agent, no code. libretto is code-based (write Playwright, act by selector) — and repeat
  runs are compiled to a deterministic script that costs **0 LLM tokens**. Replay
  amortization remains libretto's real moat; kuri has no equivalent yet.

## 4. What kuri adopted from libretto (this release)

Studying libretto's source directly informed these changes, all shipped and verified E2E:

1. **Diff-first loop** (`take_snapshot_diff` / `GET /diff/snapshot`) — mirror of libretto's
   after-action diff; ~38 tokens per step instead of a fresh snapshot.
2. **Adaptive diff** — when a diff would be larger than the page it describes (navigation,
   SPA route swap), kuri sends the full compact snapshot with a `! page replaced` header
   instead. libretto collapses whole-page changes the same way.
3. **Identity-only removals** — removed diff lines are now `- role "name" @ref` with no
   value/state, so removal-heavy diffs don't re-bill tokens for elements that are gone.
4. **Screenshots to disk** — `GET /screenshot?save=true` writes the PNG under
   `STATE_DIR/screenshots` and returns `{path,bytes}`; `kuri-mcp`'s `take_screenshot` no
   longer inlines base64 into the model context. This is libretto's artifact discipline.
5. **`get_page_state` in MCP** — kuri's ~48-token page observation (url/title/scroll/
   counts), now exposed as an MCP tool to orient before paying for a snapshot. libretto has
   no equally light observation.
6. **Per-container list truncation (`limit=N`)** — libretto's biggest per-observation win,
   adopted the kuri way. The morning attempt failed and was reverted because CDP's
   `Accessibility.getFullAXTree` does not emit nodes in DFS order, so sibling grouping
   collapsed unrelated content. `parseA11yNodes` has since been rewritten as a real tree
   walk (ordered `childIds`, explicit stack, pre-order depth), and on top of it:
   `limit=N` caps each same-role sibling run at N and emits one `… +K more <role>` line;
   `scope=@ref` re-captures and renders just that element's subtree (fresh, never cached);
   `hierarchy=true` renders real indentation. Exposed as `/snapshot?limit=&scope=&hierarchy=`
   and as `uid`/`limit` arguments on MCP `take_snapshot`. Unlike libretto, kuri's default
   stays untruncated — `limit` is a lever the agent pulls on list-heavy pages.
   The diff loop honors the same lever: `/diff/snapshot?limit=N` truncates the
   page-replaced fallback (so a navigation inside a truncated-base loop costs
   ~a truncated snapshot, not the full new page — HN trajectory 4,487 → 773);
   normal delta lines are never truncated.

## What kuri still lacks (honest)

**Replay compilation.** libretto compiles a completed trajectory into a deterministic
Playwright script; repeat runs cost 0 LLM tokens and survive minor DOM drift via
self-healing selectors. kuri re-pays the loop every run. This is the largest remaining
gap and is not addressed by anything in this document.

## Reproduce

```sh
# one shared Chrome
"Google Chrome" --headless=new --remote-debugging-port=9333 --user-data-dir="$(mktemp -d)"
# kuri attaches over CDP
CDP_URL=http://127.0.0.1:9333 PORT=8081 KURI_API_TOKEN=tok kuri
# fixtures
python3 -m http.server 8899 -d bench/fixtures &
# libretto attaches to the same Chrome
libretto connect http://127.0.0.1:9333 --session bench --write-access
# kuri trajectory rows: replay the click sequence under each strategy
cd bench/loopcalc && bun install
KURI_BASE=http://127.0.0.1:8081 KURI_API_TOKEN=tok bun run src/cli.ts estimate \
  --url http://lvh.me:8899/feed.html --click "Upvote:9" \
  --strategies full,interactive,diff,truncated:5,interactive+diff,truncated:5+diff
```

*Single-run, single-machine numbers — treat ratios as the stable signal and rerun in your
own environment before quoting a percentage. Measures snapshot/diff payload tokens and call
latency, not end-to-end task success or model quality.*
