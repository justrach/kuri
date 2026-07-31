#!/usr/bin/env bun
// loopcalc — agent-loop cost calculator.
//   estimate: replay an action sequence via kuri, price each observation strategy (no LLM).
//   live:     run a real codegraff agent loop driving kuri, report actual tokens + $.
import { readFileSync } from "node:fs";
import { Kuri } from "./kuri.ts";
import { estimate, type EstimateConfig, type Action } from "./estimate.ts";
import { renderEstimate, estimateToJson } from "./report.ts";
import { runLive } from "./live.ts";

function flag(args: string[], name: string): string | undefined {
  const i = args.indexOf(`--${name}`);
  return i >= 0 && i + 1 < args.length ? args[i + 1] : undefined;
}
function has(args: string[], name: string): boolean {
  return args.includes(`--${name}`);
}

async function mkKuri(): Promise<Kuri> {
  return Kuri.connect({
    base: process.env.KURI_BASE ?? "http://127.0.0.1:8081",
    token: process.env.KURI_API_TOKEN ?? "e2etok",
  });
}

async function cmdEstimate(args: string[]): Promise<void> {
  let cfg: EstimateConfig;
  const cfgFile = flag(args, "config") ?? (args[0] && !args[0].startsWith("--") ? args[0] : undefined);
  if (cfgFile) {
    cfg = JSON.parse(readFileSync(cfgFile, "utf8"));
  } else {
    const url = flag(args, "url");
    if (!url) throw new Error("estimate: need --url <url> or --config <file>");
    const actions: Action[] = [];
    // --click <substr>:<count>   e.g. --click Upvote:9
    const click = flag(args, "click");
    if (click) {
      const [m, n] = click.split(":");
      actions.push({ op: "click", refMatch: m, repeat: n ? parseInt(n, 10) : 1, distinct: true });
    }
    const scroll = flag(args, "scroll");
    if (scroll) actions.push({ op: "scroll", repeat: parseInt(scroll, 10) });
    cfg = {
      target: url,
      actions,
      strategies: (flag(args, "strategies") ?? "full,interactive,diff,truncated:5,interactive+diff").split(","),
      limit: flag(args, "limit") ? parseInt(flag(args, "limit")!, 10) : 5,
      settleMs: flag(args, "settle") ? parseInt(flag(args, "settle")!, 10) : 800,
      model: flag(args, "model"),
      price: flag(args, "price") ? parseFloat(flag(args, "price")!) : undefined,
    };
  }
  const result = await estimate(cfg, mkKuri);
  if (has(args, "json")) console.log(estimateToJson(result));
  else console.log(renderEstimate(result));
}

async function cmdLive(args: string[]): Promise<void> {
  const url = flag(args, "url");
  const task = flag(args, "task");
  if (!url || !task) throw new Error('live: need --url <url> --task "<what to do>"');
  await runLive({
    url,
    task,
    model: flag(args, "model"),
    strategy: (flag(args, "strategy") as any) ?? "diff",
    maxSteps: flag(args, "max-steps") ? parseInt(flag(args, "max-steps")!, 10) : 12,
    kuriBase: process.env.KURI_BASE ?? "http://127.0.0.1:8081",
    kuriToken: process.env.KURI_API_TOKEN ?? "e2etok",
  });
}

const [, , cmd, ...rest] = process.argv;
try {
  if (cmd === "estimate") await cmdEstimate(rest);
  else if (cmd === "live") await cmdLive(rest);
  else {
    console.log(`loopcalc — agent-loop cost calculator

  estimate  price each observation strategy on a replayed action sequence (no LLM)
    --url <url>                     target page
    --click <substr>:<n>           click n distinct elements whose line matches substr
    --scroll <n>                    scroll n times
    --strategies a,b,c             full,interactive,diff,truncated:5,interactive+diff (default)
    --limit <n>                    truncation N for 'truncated' (default 5)
    --model <name> / --price <$>   for the $ column ($/1M input tokens)
    --config <file.json>           full config instead of flags
    --json                         machine-readable output

  live      run a real codegraff agent loop driving kuri; report actual tokens + $
    --url <url> --task "<goal>"    what to do
    --model <name>                 codegraff model (default: graff's default model)
    --strategy <s>                 observation tool the agent is told to use (diff|full|truncated)
    --max-steps <n>                safety cap (default 12)

  env: KURI_BASE (default http://127.0.0.1:8081), KURI_API_TOKEN`);
    process.exit(cmd ? 1 : 0);
  }
} catch (e) {
  console.error("error:", (e as Error).message);
  process.exit(1);
}
