// Tokenizer: o200k_base (GPT-4o / modern class), the same encoding the kuri
// benchmarks use so the numbers here line up with benchmarks/libretto_comparison.md.
import { getEncoding, type Tiktoken } from "js-tiktoken";

let enc: Tiktoken | null = null;

export function countTokens(text: string): number {
  if (!enc) enc = getEncoding("o200k_base");
  return enc.encode(text).length;
}

// Approximate model input pricing ($ per 1M input tokens), for a rough $ column
// on the *observation* side. These are the recurring per-step observation costs
// an agent pays; output/reasoning tokens are separate and, for a browser loop,
// dwarfed by observations. Update freely — pass --price to override.
export const INPUT_PRICE_PER_MTOK: Record<string, number> = {
  "claude-opus-4-8": 5.0,
  "claude-sonnet-4-6": 3.0,
  "claude-fable-5": 5.0,
  "gpt-5.5": 1.25,
  "gpt-5.4": 1.25,
  "kimi-k2.7": 0.6,
  "deepseek-v4-pro": 0.5,
  default: 3.0,
};

export function priceFor(model: string | undefined): number {
  if (!model) return INPUT_PRICE_PER_MTOK.default;
  return INPUT_PRICE_PER_MTOK[model] ?? INPUT_PRICE_PER_MTOK.default;
}

export function dollars(tokens: number, model?: string, priceOverride?: number): number {
  const price = priceOverride ?? priceFor(model);
  return (tokens / 1_000_000) * price;
}
