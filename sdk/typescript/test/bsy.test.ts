import { describe, expect, it } from "vitest";
import {
  BSY_DECIMALS,
  BSY_NAME,
  BSY_SCALE,
  BSY_SYMBOL,
  MAX_SUPPLY_BASE,
  MAX_SUPPLY_WHOLE,
  checkedAdd,
  checkedSub,
  formatBsy,
  fromWhole,
  parseBsy,
} from "../src/bsy.js";

describe("BSY amounts", () => {
  it("constants match the protocol spec", () => {
    expect(BSY_NAME).toBe("BitSync");
    expect(BSY_SYMBOL).toBe("BSY");
    expect(BSY_DECIMALS).toBe(8);
    expect(BSY_SCALE).toBe(100_000_000n);
    expect(MAX_SUPPLY_WHOLE).toBe(42_000_000n);
    expect(MAX_SUPPLY_BASE).toBe(42_000_000n * 100_000_000n);
  });

  it("parses and formats", () => {
    expect(parseBsy("1.23456789 BSY")).toBe(123_456_789n);
    expect(formatBsy(123_456_789n)).toBe("1.23456789 BSY");
    expect(parseBsy("42000000")).toBe(MAX_SUPPLY_BASE);
    expect(() => parseBsy("42000001")).toThrow();
    expect(() => parseBsy("1.123456789")).toThrow();
  });

  it("checked arithmetic", () => {
    const a = fromWhole(1n);
    const b = fromWhole(2n);
    expect(checkedAdd(a, b)).toBe(3n * BSY_SCALE);
    expect(() => checkedSub(a, b)).toThrow();
    expect(() => checkedAdd(MAX_SUPPLY_BASE, 1n)).toThrow();
  });
});
