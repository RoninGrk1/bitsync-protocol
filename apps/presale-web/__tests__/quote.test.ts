import { describe, it, expect } from "vitest";
import {
  offlineQuoteBsy,
  offlineQuoteUsd,
  parseUsd,
  SUGGESTED_PRICE_USD_PER_BSY,
  PRESALE_ALLOCATION,
  USD_SCALE,
} from "@bitsync/sdk";
import { BSY_SCALE } from "@bitsync/sdk";

describe("presale quote helpers (via SDK)", () => {
  it("quotes 5 BSY for $1 at $0.20", () => {
    const usd = parseUsd("1");
    const bsy = offlineQuoteBsy(usd, SUGGESTED_PRICE_USD_PER_BSY);
    expect(bsy).toBe(5n * BSY_SCALE);
  });

  it("never sells more than allocation in offline math", () => {
    const full = offlineQuoteUsd(PRESALE_ALLOCATION);
    const back = offlineQuoteBsy(full);
    expect(back).toBeLessThanOrEqual(PRESALE_ALLOCATION + 1n); // at most 1 base unit favour buyer
  });

  it("uses 1e8 USD scale", () => {
    expect(USD_SCALE).toBe(100_000_000n);
    expect(SUGGESTED_PRICE_USD_PER_BSY).toBe(20_000_000n);
  });
});
