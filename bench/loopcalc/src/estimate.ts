// Estimator: replay one action sequence against a live page and tally the
// OBSERVATION tokens each strategy would send to the model. No LLM required —
// deterministic, cheap, and calibrated to o200k_base. The observation stream is
// what dominates a browser-agent's token bill (a snapshot every step), so this
// is the number that decides loop cost.
import { Kuri, refsMatching } from "./kuri.ts";
import { countTokens, dollars } from "./tokens.ts";

export interface Action {
  op: "click" | "scroll" | "fill" | "navigate";
  ref?: string;
  refMatch?: string; // resolve to a ref by substring, against a fresh (uncounted) snapshot
  value?: string;
  url?: string;
  repeat?: number; // repeat this action N times (distinct refs when refMatch + distinct)
  distinct?: boolean;
}

export interface EstimateConfig {
  target: string;
  actions: Action[];
  strategies: string[]; // e.g. "full", "interactive", "diff", "truncated:5", "interactive+diff"
  limit?: number; // default truncation N when a strategy says "truncated" w/o a number
  settleMs?: number; // wait after each action for the page to settle
  model?: string; // for the $ column
  price?: number; // $/1M input tokens override
}

// A strategy = how the agent observes. `base` is the first observation (counted);
// `prime` sets an internal diff baseline the agent doesn't see (not counted);
// `step` is each post-action observation (counted).
interface Strategy {
  name: string;
  base: (k: Kuri) => Promise<string>;
  prime?: (k: Kuri) => Promise<void>;
  step: (k: Kuri) => Promise<string>;
}

function makeStrategy(spec: string, defaultLimit: number): Strategy {
  const full = (k: Kuri) => k.snapshot({});
  const inter = (k: Kuri) => k.snapshot({ filter: "interactive" });
  const trunc = (n: number) => (k: Kuri) => k.snapshot({ limit: n });
  const diff = (limit?: number) => (k: Kuri) => k.diff(limit);
  const prime = async (k: Kuri) => { await k.diff(); };

  const [head, tail] = spec.split("+");
  const [kind, arg] = head.split(":");
  const n = arg ? parseInt(arg, 10) : defaultLimit;

  // base observation
  let base: (k: Kuri) => Promise<string>;
  if (kind === "full") base = full;
  else if (kind === "interactive") base = inter;
  else if (kind === "truncated") base = trunc(n);
  else if (kind === "diff") base = diff(); // diff-first: base IS the priming full-page diff
  else throw new Error(`unknown strategy base: ${kind}`);

  // per-step observation; a truncated base carries its limit into the diff so
  // the page-replaced fallback (navigation) is truncated too
  const usesDiff = spec === "diff" || tail === "diff";
  const step = usesDiff ? diff(kind === "truncated" ? n : undefined) : base;

  // diff-based non-"diff" bases need an (uncounted) prime after the base view
  const needsPrime = usesDiff && kind !== "diff";

  return { name: spec, base, step, prime: needsPrime ? prime : undefined };
}

export interface StrategyResult {
  name: string;
  baseTokens: number;
  stepTokens: number[];
  totalTokens: number;
  perStepMedian: number;
  dollarsTotal: number;
}

export interface EstimateResult {
  target: string;
  steps: number;
  results: StrategyResult[];
}

// Resolve an action to a concrete ref (for click/fill) using a fresh full
// snapshot that is NOT counted — pure simulation bookkeeping so every strategy
// replays the same semantic sequence.
async function resolveRef(k: Kuri, a: Action, used: Set<string>): Promise<string | null> {
  if (a.ref) return a.ref;
  if (!a.refMatch) return null;
  const snap = await k.snapshot({});
  const refs = refsMatching(snap, a.refMatch);
  for (const r of refs) {
    if (a.distinct && used.has(r)) continue;
    used.add(r);
    return r;
  }
  return refs[0] ?? null;
}

// Flatten repeats into a concrete action list.
function expand(actions: Action[]): Action[] {
  const out: Action[] = [];
  for (const a of actions) {
    const n = a.repeat ?? 1;
    for (let i = 0; i < n; i++) out.push({ ...a, repeat: undefined });
  }
  return out;
}

export async function estimate(cfg: EstimateConfig, mkKuri: () => Promise<Kuri>): Promise<EstimateResult> {
  const settle = cfg.settleMs ?? 800;
  const defaultLimit = cfg.limit ?? 5;
  const strategies = cfg.strategies.map((s) => makeStrategy(s, defaultLimit));
  const actions = expand(cfg.actions);
  const results: StrategyResult[] = [];

  for (const strat of strategies) {
    const k = await mkKuri();
    await k.navigate(cfg.target);
    await sleep(settle);

    const baseText = await strat.base(k);
    const baseTokens = countTokens(baseText);
    if (strat.prime) await strat.prime(k);

    const used = new Set<string>();
    const stepTokens: number[] = [];
    for (const a of actions) {
      if (a.op === "scroll") {
        await k.action("scroll");
      } else if (a.op === "navigate" && a.url) {
        await k.navigate(a.url);
      } else if (a.op === "click" || a.op === "fill") {
        const ref = await resolveRef(k, a, used);
        if (ref) await k.action(a.op === "fill" ? "fill" : "click", ref, a.value);
      }
      await sleep(settle);
      stepTokens.push(countTokens(await strat.step(k)));
    }

    const total = baseTokens + stepTokens.reduce((s, t) => s + t, 0);
    const sorted = [...stepTokens].sort((a, b) => a - b);
    results.push({
      name: strat.name,
      baseTokens,
      stepTokens,
      totalTokens: total,
      perStepMedian: sorted.length ? sorted[Math.floor(sorted.length / 2)] : 0,
      dollarsTotal: dollars(total, cfg.model, cfg.price),
    });
  }

  return { target: cfg.target, steps: actions.length, results };
}

function sleep(ms: number): Promise<void> {
  return new Promise((r) => setTimeout(r, ms));
}
