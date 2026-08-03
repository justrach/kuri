# Benchmarks

Reproducible browser-output comparisons for `kuri-agent`, `agent-browser`, `lightpanda`, and an optional Webwright-style Playwright observation baseline.
The useful comparison is same page, same tokenizer, and saved raw outputs.

## Runner

Use [`run_token_matrix.sh`](/Users/rachpradhan/kuri/benchmarks/run_token_matrix.sh):

```bash
./benchmarks/run_token_matrix.sh
./benchmarks/run_token_matrix.sh https://example.com
./benchmarks/run_token_matrix.sh "https://www.google.com/travel/flights?q=Flights%20to%20TPE%20from%20SIN"
```

It ensures Chrome is available on CDP `9222`, captures tool outputs, tokenizes them with `cl100k_base`, and writes `summary.md`, `summary.json`, and `raw/`.
Ad hoc runs write to `.benchmarks/results/...`; checked-in `benchmarks/results/` is for curated reference runs only.

Each summary now reports two workflow views:

- `Raw captured output`: the literal bytes/tokens each CLI emitted for `go→snap-i→click→snap-i→eval`
- `Normalized page-state output`: only the state payloads an agent reads back, `snap-i + snap-i + eval`

The normalized view strips tool-specific action acknowledgement noise.

## Requirements

- `./zig-out/bin/kuri-agent`
- `/usr/bin/python3` with `tiktoken`
- optional: `agent-browser` on `$PATH`, `lightpanda` at `/tmp/lightpanda` or `$LIGHTPANDA_BIN`
- optional: Webwright/Playwright observation capture via `WEBWRIGHT_PYTHON_BIN`
  with `playwright` installed. Installing `webwright` is a convenient way to
  get the same dependency family, but the runner only captures a Playwright
  `body.aria_snapshot()` observation; it does not run Webwright's LLM agent
  loop.

Example local install for the Webwright observation baseline:

```bash
python3 -m pip install "git+https://github.com/microsoft/Webwright.git@1236f4d31186610d23badd997917f86712fe8bed"
WEBWRIGHT_REF=1236f4d31186610d23badd997917f86712fe8bed \
  WEBWRIGHT_PYTHON_BIN=python3 \
  ./benchmarks/run_token_matrix.sh https://example.com
```

If Playwright has not downloaded its bundled Chromium, either run
`python3 -m playwright install chromium` or set `CHROME_BIN` to an existing
Chrome/Chromium executable.

## Webwright Showcase Task Compare

To run one Webwright showcase task as a deterministic browser-substrate
comparison, use:

```bash
python3 -m venv .benchmarks/tmp-webwright-task-venv
.benchmarks/tmp-webwright-task-venv/bin/python -m pip install tiktoken "git+https://github.com/microsoft/Webwright.git@1236f4d31186610d23badd997917f86712fe8bed"
CHROME_BIN="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
  WEBWRIGHT_REF=1236f4d31186610d23badd997917f86712fe8bed \
  .benchmarks/tmp-webwright-task-venv/bin/python \
  benchmarks/run_webwright_showcase_task_compare.py driving_weather
```

Supported showcase tasks are `driving_weather`, `slickdeals`, and
`pokemon_tcg`. This compares Kuri/CDP against a Webwright-style Playwright
script on live task pages. It does not run Webwright's LLM agent loop.

## Docker

For constrained or repeatable environments, use:

```bash
chmod +x ./benchmarks/docker-run.sh
./benchmarks/docker-run.sh https://vercel.com
PROFILE=small ./benchmarks/docker-run.sh https://vercel.com
PROFILE=large ./benchmarks/docker-run.sh "https://www.google.com/travel/flights?q=Flights%20to%20TPE%20from%20SIN%20on%202026-03-23&curr=SGD"
```

This builds [`Dockerfile`](/Users/rachpradhan/kuri/benchmarks/Dockerfile), installs Zig, Chromium, `agent-browser`, `tiktoken`, and `lightpanda`, then runs the benchmark against headless Chromium inside the container.
The entrypoint always rebuilds `kuri-agent` inside Linux so it never reuses a host macOS binary from `zig-out/`.

### Resource presets

- `PROFILE=small` → `1 CPU`, `2 GB RAM`, `1 GB /dev/shm`
- `PROFILE=medium` → `2 CPU`, `4 GB RAM`, `2 GB /dev/shm`
- `PROFILE=large` → `4 CPU`, `8 GB RAM`, `4 GB /dev/shm`

You can also override them directly:

```bash
CPUS=1.5 MEMORY=3g SHM_SIZE=1g ./benchmarks/docker-run.sh https://vercel.com
```

## Notes

- `agent-browser` uses the shared Chrome CDP session on `9222`.
- `lightpanda` is measured via standalone `fetch --dump ...`, so it is not using Chrome.
- `Webwright/Playwright aria_snapshot` is an observation-payload baseline only.
  It launches a fresh local Playwright Chromium context and prints the same kind
  of ARIA snapshot Webwright-style scripts inspect. It is not a Webwright
  task-success benchmark and must not be compared to Webwright's published
  Online-Mind2Web or Odysseys scores.
- On interactive pages, the normalized page-state section is the better apples-to-apples comparison.

## Runner Size

Inside Docker, yes: use the presets above or override `CPUS`, `MEMORY`, and `SHM_SIZE`.
For hosted CI runner size, no: that has to be chosen outside the container.

## Latest Run

See the newest timestamped folder under [`results/`](/Users/rachpradhan/kuri/benchmarks/results).
