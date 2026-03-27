# Benchmarks

This folder holds reproducible browser-output comparisons between:

- `kuri-agent`
- `agent-browser`
- `lightpanda`

The goal is not "smallest output wins" in isolation. The useful comparison is:

- same page
- same date
- same tokenizer
- auditable raw outputs

## Runner

Use [`run_token_matrix.sh`](/Users/rachpradhan/kuri/benchmarks/run_token_matrix.sh):

```bash
./benchmarks/run_token_matrix.sh
./benchmarks/run_token_matrix.sh https://example.com
./benchmarks/run_token_matrix.sh "https://www.google.com/travel/flights?q=Flights%20to%20TPE%20from%20SIN"
```

What it does:

- ensures Chrome is available on CDP port `9222` via `kuri-agent`
- captures `kuri-agent` outputs
- captures `agent-browser` outputs if installed
- captures `lightpanda` outputs if `LIGHTPANDA_BIN` or `/tmp/lightpanda` exists
- tokenizes all outputs with `cl100k_base`
- writes:
  - `summary.md`
  - `summary.json`
  - raw tool outputs under `raw/`

Each summary now reports two workflow views:

- `Raw captured output`: the literal bytes/tokens each CLI emitted for `go→snap-i→click→snap-i→eval`
- `Normalized page-state output`: only the state payloads an agent reads back, `snap-i + snap-i + eval`

That second view intentionally strips tool-specific action acknowledgement noise from the comparison.

## Requirements

- built `kuri-agent` at `./zig-out/bin/kuri-agent`
- `/usr/bin/python3`
- `tiktoken` installed for that interpreter
- optional:
  - `agent-browser` on `$PATH`
  - `lightpanda` at `/tmp/lightpanda` or `$LIGHTPANDA_BIN`

## Notes

- `agent-browser` is measured against a shared Chrome CDP session on `9222`.
- `lightpanda` is measured via standalone `fetch --dump ...`, so it is not using Chrome.
- That means the `lightpanda` leg is best read as "standalone browser output shape and token cost", not "same underlying engine state as the Chrome-based tools".
- On highly interactive pages, the normalized page-state section is the more defensible apples-to-apples comparison than raw CLI output totals.

## Latest Run

See the newest timestamped folder under [`results/`](/Users/rachpradhan/kuri/benchmarks/results).
