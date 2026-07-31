import type { EstimateResult } from "./estimate.ts";

function pad(s: string, n: number): string {
  return s.length >= n ? s : s + " ".repeat(n - s.length);
}
function padl(s: string, n: number): string {
  return s.length >= n ? s : " ".repeat(n - s.length) + s;
}

export function renderEstimate(r: EstimateResult): string {
  const lines: string[] = [];
  lines.push(`\nagent-loop cost — ${r.target}   (${r.steps} action steps, o200k_base tokens)`);
  lines.push("=".repeat(78));
  lines.push(
    `${pad("strategy", 20)} ${padl("base", 7)} ${padl("per-step", 9)} ${padl("total", 8)} ${padl("$", 9)}  vs best`,
  );
  lines.push("-".repeat(78));
  const best = Math.min(...r.results.map((x) => x.totalTokens));
  for (const s of r.results) {
    const ratio = s.totalTokens === best ? "★ best" : `${(s.totalTokens / best).toFixed(2)}x`;
    lines.push(
      `${pad(s.name, 20)} ${padl(String(s.baseTokens), 7)} ${padl(String(s.perStepMedian), 9)} ${padl(String(s.totalTokens), 8)} ${padl("$" + s.dollarsTotal.toFixed(4), 9)}  ${ratio}`,
    );
  }
  lines.push("-".repeat(78));
  const worst = Math.max(...r.results.map((x) => x.totalTokens));
  lines.push(`spread: ${worst} → ${best} tokens  (${(worst / best).toFixed(1)}x between worst and best strategy)`);
  return lines.join("\n");
}

export function estimateToJson(r: EstimateResult): string {
  return JSON.stringify(r, null, 2);
}
