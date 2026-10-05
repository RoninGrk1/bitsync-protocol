import { describe, expect, it } from "vitest";
import {
  PRESALE_ALLOCATION,
  SUGGESTED_PRICE_USD_PER_BSY,
  SUGGESTED_LISTING_USD_PER_BSY,
  USD_SCALE,
  offlineQuoteBsy,
  offlineQuoteUsd,
  formatUsd,
  parseUsd,
} from "../src/presale.js";
import { BSY_SCALE, formatBsy } from "../src/bsy.js";

describe("presale helpers", () => {
  it("allocation is 15% of 42M", () => {
    expect(PRESALE_ALLOCATION).toBe(6_300_000n * BSY_SCALE);
  });

  it("suggested price quotes", () => {
    expect(SUGGESTED_PRICE_USD_PER_BSY).toBe(20_000_000n);
    expect(SUGGESTED_LISTING_USD_PER_BSY).toBe(30_000_000n);
    // $200 → 1000 BSY at $0.20
    expect(offlineQuoteBsy(200n * USD_SCALE)).toBe(1000n * BSY_SCALE);
    expect(offlineQuoteUsd(1000n * BSY_SCALE)).toBe(200n * USD_SCALE);
    expect(formatUsd(200n * USD_SCALE)).toContain("200");
    expect(parseUsd("1.50")).toBe(150_000_000n);
    expect(formatBsy(offlineQuoteBsy(parseUsd("1260000")))).toContain("6300000");
  });

  it("floor quote never favours buyer", () => {
    const usd = 123_456_789n;
    const bsy = offlineQuoteBsy(usd);
    expect((bsy * SUGGESTED_PRICE_USD_PER_BSY) / USD_SCALE).toBeLessThanOrEqual(usd);
  });
});
