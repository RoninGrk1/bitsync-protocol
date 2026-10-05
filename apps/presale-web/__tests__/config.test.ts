import { describe, it, expect } from "vitest";
import { blockedCountries, chainId } from "../src/lib/config";

describe("presale-web config", () => {
  it("defaults to Anvil chainId 31337", () => {
    expect(chainId).toBe(31337);
  });

  it("blocks US and UK by default", () => {
    expect(blockedCountries).toContain("US");
    expect(blockedCountries.some((c) => c === "GB" || c === "UK")).toBe(true);
  });
});
