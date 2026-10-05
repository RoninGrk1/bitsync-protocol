/**
 * BitSync (BSY) amount helpers.
 *
 * - Name: BitSync
 * - Symbol: BSY
 * - Decimals: 8 (1 BSY = 10^8 base units — Bitcoin-native sat-style scale)
 * - Max / total supply: 42_000_000 BSY (minted once at deployment; inflation 0%)
 */

export const BSY_NAME = "BitSync" as const;
export const BSY_SYMBOL = "BSY" as const;
export const BSY_DECIMALS = 8 as const;
export const BSY_SCALE = 100_000_000n;
export const MAX_SUPPLY_WHOLE = 42_000_000n;
export const MAX_SUPPLY_BASE = MAX_SUPPLY_WHOLE * BSY_SCALE;

export type BsyAmount = bigint;

export function fromBaseUnits(base: bigint): BsyAmount {
  if (base < 0n) throw new Error("negative amount");
  return base;
}

export function fromWhole(whole: bigint): BsyAmount {
  if (whole < 0n) throw new Error("negative");
  const base = whole * BSY_SCALE;
  if (base > MAX_SUPPLY_BASE) throw new Error("exceeds MAX_SUPPLY");
  return base;
}

export function parseBsy(input: string): BsyAmount {
  const s = input.trim().replace(/\s*BSY$/i, "").trim();
  if (!s) throw new Error("empty amount");
  const [wholeS, fracS = ""] = s.split(".");
  if (fracS.length > BSY_DECIMALS) throw new Error("too many fractional digits");
  if (!/^\d*$/.test(wholeS) || !/^\d*$/.test(fracS)) throw new Error("invalid charset");
  const whole = BigInt(wholeS || "0");
  let frac = BigInt(fracS || "0");
  for (let i = fracS.length; i < BSY_DECIMALS; i++) frac *= 10n;
  const base = whole * BSY_SCALE + frac;
  if (base > MAX_SUPPLY_BASE) throw new Error("exceeds MAX_SUPPLY");
  return base;
}

export function formatBsy(amount: BsyAmount, withSymbol = true): string {
  const whole = amount / BSY_SCALE;
  const frac = amount % BSY_SCALE;
  const body =
    frac === 0n ? whole.toString() : `${whole}.${frac.toString().padStart(BSY_DECIMALS, "0")}`;
  return withSymbol ? `${body} ${BSY_SYMBOL}` : body;
}

export function checkedAdd(a: BsyAmount, b: BsyAmount): BsyAmount {
  const s = a + b;
  if (s > MAX_SUPPLY_BASE) throw new Error("overflow cap");
  return s;
}

export function checkedSub(a: BsyAmount, b: BsyAmount): BsyAmount {
  if (b > a) throw new Error("underflow");
  return a - b;
}
