# loopcalc — agent-loop cost calculator

Measures the token/$ economics of a browser-agent loop driven through
[kuri](../../readme.md). Two modes:

- **`estimate`** — no LLM. Replays one action sequence against a live page and
  tallies the *observation* tokens each strategy would send to the model
  (`tiktoken o200k_base`). Observations dominate a browser agent's bill — a
  snapshot every step — so this is the number that decides loop cost.
- **`live`** — real ground truth. Runs an actual [codegraff](https://github.com/justrach/codegraff)
  agent loop that drives kuri over MCP, and reads `context_tokens` / `cost_usd`
  off the harness `turn` event. Needs a provider key (`graff key list`).

Both modes need a running kuri server (any Chrome attached via `CDP_URL`).

## Setup

```sh
bun install
export KURI_BASE=http://127.0.0.1:8081     # default
export KURI_API_TOKEN=...                  # kuri bearer token
```

## estimate — price observation strategies (no LLM)

```sh
bun run src/cli.ts estimate \
  --url http://lvh.me:8899/feed.html \
  --click "Upvote:9" \
  --strategies full,interactive,diff,truncated:5,interactive+diff,truncated:5+diff \
  --model claude-fable-5
```

Strategies compose as `base[+diff]`:

| spec | base observation | per-step observation |
|---|---|---|
| `full` | full compact snapshot | full snapshot again |
| `interactive` | `filter=interactive` | same |
| `truncated:N` | `limit=N` sibling-run truncation | same |
| `diff` | first `/diff/snapshot` (whole page as `+` lines) | diff only |
| `X+diff` | strategy X, then an uncounted diff prime | diff only |

Actions: `--click <substr>:<n>` (click n distinct elements whose snapshot line
matches substr), `--scroll <n>`, or `--config file.json` for a full
`EstimateConfig` (navigate/fill/repeat supported). Ref resolution uses a fresh
*uncounted* full snapshot before each click so every strategy replays the same
semantic sequence.

Measured example (50-item feed fixture, 9 upvote clicks, 2026-07-04):

```
strategy                base  per-step    total         $  vs best
full                    4424      4429    44285   $0.2214  49.32x
interactive             2897      2899    28988   $0.1449  32.28x
diff                    4937        38     5280   $0.0264  5.88x
truncated:5              555       560     5587   $0.0279  6.22x
interactive+diff        2897        38     3240   $0.0162  3.61x
truncated:5+diff         555        38      898   $0.0045  ★ best
```

The `$` column prices observation input tokens only (`--model` name or
`--price $/1Mtok`); model output/reasoning tokens are separate.

### Real sites (2026-07-04)

Same estimator on live pages. `truncated:5+diff` carries its limit into the
diff, so the page-replaced fallback after a navigation is truncated too:

| site (actions) | full | truncated:5 | truncated:5+diff | spread |
|---|---:|---:|---:|---:|
| news.ycombinator.com (click More, scroll) | 12,402 | 1,143 | **773** | 16.0× |
| MDN Fetch API docs (2 scrolls) | 50,427 | 4,965 | **1,826** | 27.6× |
| Google Flights landing (base only) | 1,670 | 1,483 | — | 1.7× (interactive wins: 1,001) |

Read the Flights row honestly: truncation is a *list* lever. On a form-heavy
landing page it barely helps — `filter=interactive` is the right cut there.
On list/doc pages the truncated-base diff loop is 16–28× cheaper than naive
full re-snapshots.

## live — real agent loop, real bill

```sh
bun run src/cli.ts live \
  --url http://lvh.me:8899/feed.html \
  --task "Upvote the first 3 stories, then stop." \
  --strategy diff --max-steps 10          # --model to pin one; default = graff's default
```

Spawns `graff` (the codegraff CLI) in a temp workdir whose `.mcp.json` points
at `kuri-mcp`, injects the observation strategy into the system prompt, streams
observe/act lines to stderr, and reports the real `context_tokens` (full context
at the final turn) and `cost_usd` (summed across turns) from the harness `turn`
events. Chatty models that end a turn mid-task are re-prompted up to 6 turns
until they report `DONE:`. `--max-steps` maps to `graff --max-tool-calls` (×3:
observe + act + observe per step, plus slack). The prompt forbids
payment/checkout actions.

### Measured: live strategy A/B (2026-07-04, gpt-5.5 via graff default)

Same task — "upvote the first 3 stories" on the 50-item feed fixture; every run
finished in one turn with 4 observations / 4 actions:

| strategy | live context tokens | vs full |
|---|---:|---:|
| full (no-args control) | 25,301 | 1.00× |
| diff | 12,681 | 2.00× fewer |
| truncated (`limit:5`) | 9,880 | 2.56× fewer |

**Calibration:** the estimator's predicted observation-token deltas match the
live bills to ~0.3% — full−diff predicted 12,645 vs 12,620 live; full−truncated
predicted 15,461 vs 15,421 live. The free `estimate` mode is a faithful proxy
for real harness spend.

Two footnotes from the runs, reported honestly:
- On a 3-step task the truncated *snapshot* loop beats the diff loop, because
  diff's first call renders the whole page as `+` lines (4,937 tok) while a
  `limit:5` snapshot is 555. Diffs win as trajectories get longer (per-step 38
  vs 560 — the estimator's 9-click table shows the crossover).
- In an early "full" run the model **self-optimized**: gpt-5.5 read the MCP tool
  description and passed `limit:10` unprompted, cutting each observation ~4×.
  The control prompt now forbids it; the anecdote is evidence the `limit`
  affordance is discoverable in practice.

## Files

- `src/kuri.ts` — thin kuri HTTP client (navigate / snapshot variants / diff / action)
- `src/estimate.ts` — strategy simulation + token tally
- `src/report.ts` — table / `--json` rendering
- `src/live.ts` — codegraff harness runner (MCP wiring, event accounting)
- `src/tokens.ts` — `o200k_base` counting + input-price table
- `src/cli.ts` — `estimate` / `live` commands

Honest-metrics notes: tokens are real tokenizer counts, never `chars/4`; the
estimator replays *identical* action sequences across strategies; `truncated:*`
is opt-in in kuri (the default snapshot stays untruncated). Single-machine
numbers — treat ratios as the signal.
