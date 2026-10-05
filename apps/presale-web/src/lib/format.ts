import { BSY_SCALE, BSY_SYMBOL, type BsyAmount } from "@bitsync/sdk";

/** Insert thousands separators into a non-negative integer digit string. */
export function withThousands(raw: string): string {
  const neg = raw.startsWith("-");
  const s = neg ? raw.slice(1) : raw;
  const [whole, frac] = s.split(".");
  const grouped = whole.replace(/\B(?=(\d{3})+(?!\d))/g, ",");
  const body = frac !== undefined && frac.length > 0 ? `${grouped}.${frac}` : grouped;
  return neg ? `-${body}` : body;
}

/** Display BSY with thousands separators, e.g. "6,300,000 BSY". */
export function formatBsyGrouped(amount: BsyAmount, withSymbol = true): string {
  const whole = amount / BSY_SCALE;
  const frac = amount % BSY_SCALE;
  let body: string;
  if (frac === 0n) {
    body = withThousands(whole.toString());
  } else {
    const fracStr = frac.toString().padStart(8, "0").replace(/0+$/, "");
    body = `${withThousands(whole.toString())}.${fracStr}`;
  }
  return withSymbol ? `${body} ${BSY_SYMBOL}` : body;
}
