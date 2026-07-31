// Live runner: a REAL codegraff agent loop driving kuri via MCP. The point is
// ground truth — codegraff's `turn` event reports actual context_tokens and
// cost_usd, so we measure what the loop really costs (not an estimate). The
// chosen strategy is injected via the system prompt (which observation tool the
// agent is told to prefer), so you can A/B loop designs on real token bills.
import { Harness } from "@codegraff/sdk";
import { mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

export interface LiveOpts {
  url: string;
  task: string;
  model?: string; // omit to use graff's default (subscription/flat-rate) model
  strategy: "diff" | "full" | "truncated";
  maxSteps: number;
  kuriBase: string;
  kuriToken: string;
  kuriMcpBin?: string; // path to kuri-mcp; default the repo build
}

const OBSERVE: Record<string, string> = {
  diff: "take_snapshot_diff — only what changed since your last observation (cheapest; use it after every action)",
  full: "take_snapshot with NO arguments — never pass limit or uid; this run measures the untruncated baseline",
  truncated: "take_snapshot with limit:5 — the page truncated to the first 5 items per section; drill in with a uid-scoped snapshot only if you need more",
};

// Prepare a working dir whose .mcp.json wires kuri-mcp (pointed at the running
// kuri server) so the agent gets navigate/snapshot/click tools.
function prepWorkdir(o: LiveOpts): string {
  const dir = mkdtempSync(join(tmpdir(), "loopcalc-live-"));
  const bin = o.kuriMcpBin ?? "/Users/blackfloofie/kuri/zig-out/bin/kuri-mcp";
  const mcp = {
    mcpServers: {
      kuri: {
        command: bin,
        args: [],
        env: { KURI_BASE: o.kuriBase, KURI_SECRET: o.kuriToken },
      },
    },
  };
  writeFileSync(join(dir, ".mcp.json"), JSON.stringify(mcp, null, 2));
  return dir;
}

function systemPrompt(o: LiveOpts): string {
  return [
    "You are a browser automation agent. You drive a real Chrome via the `kuri` MCP tools:",
    "navigate_page(url), take_snapshot, take_snapshot_diff, click(uid), fill(uid,value), get_page_state.",
    `OBSERVATION STRATEGY: after each action, observe with ${OBSERVE[o.strategy]}.`,
    "Snapshots use @uid refs (e.g. @e12); click/fill take that uid. Work in small steps:",
    "observe, act on one @uid, observe the result, repeat. Do NOT end your reply until the task",
    "is complete — keep calling tools. When (and only when) the task is done, reply with a line",
    "starting with DONE: and a one-line result. Do not ask for confirmation; do not perform",
    "any payment or irreversible purchase — stop before any final submit/checkout.",
  ].join("\n");
}

export async function runLive(o: LiveOpts): Promise<void> {
  const dir = prepWorkdir(o);
  console.error(`[loopcalc live] model=${o.model ?? "(graff default)"} strategy=${o.strategy} workdir=${dir}`);
  const h = Harness.init({
    model: o.model,
    yolo: true,
    cwd: dir,
    systemPrompt: systemPrompt(o),
    args: ["--max-tool-calls", String(o.maxSteps * 3)], // observe+act+observe per step, plus slack
  });

  // One h.chat() = one conversational turn; a chatty model may end its turn
  // mid-task, so keep prompting until it reports DONE (or errors / turn cap).
  // context_tokens is the full context size at each turn (take the last);
  // cost_usd is per-turn (sum them).
  let observes = 0;
  let acts = 0;
  let turns = 0;
  let contextTokens = 0;
  let costTotal = 0;
  let done = false;
  const maxTurns = 6;
  try {
    let prompt = `First navigate_page to ${o.url}. Then: ${o.task}`;
    while (!done && turns < maxTurns) {
      for await (const ev of h.chat(prompt)) {
        if (ev.type === "tool_call") {
          const n = ev.name;
          if (n.includes("attempt_completion")) done = true;
          else if (n.includes("snapshot") || n.includes("page_state")) { observes++; process.stderr.write(`  observe(${n})\n`); }
          else if (n.includes("click") || n.includes("fill") || n.includes("navigate")) { acts++; process.stderr.write(`  act(${n}) ${JSON.stringify(ev.input).slice(0, 60)}\n`); }
        } else if (ev.type === "turn") {
          turns++;
          contextTokens = ev.context_tokens ?? contextTokens;
          costTotal += ev.cost_usd ?? 0;
          if (/(^|\n)DONE:/.test(ev.text)) done = true;
        } else if (ev.type === "error") {
          process.stderr.write(`  [error] ${ev.message}\n`);
          done = true;
        }
      }
      prompt = "Continue the task with the kuri tools. If it is already complete, reply with DONE: and the result.";
    }
  } catch (e) {
    console.error("[loopcalc live] harness error:", (e as Error).message);
  } finally {
    h.close();
  }

  console.log("\n" + "=".repeat(70));
  console.log(`LIVE loop — ${o.url}`);
  console.log(`  model            : ${o.model ?? "(graff default)"}`);
  console.log(`  strategy         : ${o.strategy}`);
  console.log(`  turns            : ${turns}${done ? "" : "   (turn cap hit before DONE)"}`);
  console.log(`  observe / act    : ${observes} observations, ${acts} actions`);
  console.log(`  context tokens   : ${contextTokens}   (real: full context at final turn)`);
  console.log(`  cost             : $${costTotal.toFixed(5)}   (real, summed across turns)`);
  console.log("=".repeat(70));
}
