# Kuri Browser Parity Percent

Target in this file is **Kuri's real Chrome/CDP server**, not Obscura.

This score is meant to answer a narrower question:

- How much of Kuri's current browser-facing surface does `kuri-browser` cover natively today?
- Which parts are actually runnable against a live Kuri server instead of being estimated by inspection?

## Current Score

- Estimated feature parity: **57%**
- Automated validation coverage: **63%** of the target surface
- Live-validated parity: **depends on the current Kuri run**

The `57%` figure is weighted, not a raw item count.

- `yes` = full weight
- `partial` = half weight
- `no` = zero

## How To Recompute

Run the standalone suite from `kuri-browser/`:

```sh
zig build run -- parity --kuri-base http://127.0.0.1:8080
```

If you only want the tracked scorecard without probing a live Kuri server:

```sh
zig build run -- parity --offline
```

The live suite currently probes:

- page title parity on `example.com`
- text parity on `example.com`
- selector count parity on Hacker News
- redirect/cookie parity on `httpbingo`
- JS DOM-count parity on `quotes.toscrape.com/js/`
- SPA shell parity on TodoMVC
- HAR capture parity on `example.com`
- ref click parity on `example.com`

## Weighted Matrix

| Surface | Weight | Status | Validation | Gap |
|---|---:|---|---|---|
| Navigation + page metadata | 10 | yes | live | Good on the current native path |
| Text extraction | 8 | yes | live | Text-first output is already strong |
| DOM selectors | 8 | yes | live | Basic selectors work; broader CSS parity is still incomplete |
| Redirects + cookies | 8 | yes | live | Cookie jar is still simpler than a full browser store |
| Forms inspect + submit | 8 | partial | manual | Only a narrower GET/POST urlencoded subset is covered |
| Static subresource loading | 6 | partial | manual | Not a full browser resource model |
| HAR capture | 6 | partial | live | Standalone HAR is useful but not full CDP parity |
| JS execution + eval | 12 | partial | live | Real sites work, but the shim surface is still incomplete |
| Browser-side fetch/XHR/storage | 8 | partial | manual | Basic bridge exists; broad compatibility still missing |
| SPA compatibility | 8 | partial | live | Representative React flow works; arbitrary SPAs do not |
| Wait semantics + async lifecycle | 8 | no | none | No stable wait model yet |
| Agent snapshots, refs, and actions | 8 | partial | live | Snapshot refs plus basic click/type flows exist; broader action parity is still missing |
| Visual rendering + screenshots | 6 | no | none | No layout/paint/screenshot path |
| CDP / automation compatibility | 4 | no | none | No CDP-compatible server |

## Missing First

1. Wait semantics and lifecycle hooks.
2. Broader ref-driven actions plus keyboard/select/checkbox parity.
3. More complete DOM events and mutation semantics.
4. Rendered output or screenshot support.
5. Any CDP-compatibility layer after the native runtime is stable.
