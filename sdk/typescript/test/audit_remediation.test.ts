import { describe, it, expect } from "vitest";
import { keccak256, toBytes } from "viem";
import { feedIdFromLabel } from "../src/report.js";

describe("audit remediation", () => {
  it("H1: feedIdFromLabel matches Solidity bytes32 label (not keccak)", () => {
    expect(feedIdFromLabel("BTC/USD")).toBe(
      "0x4254432f55534400000000000000000000000000000000000000000000000000",
    );
    expect(feedIdFromLabel("BTC/USD")).not.toEqual(keccak256(toBytes("BTC/USD")));
  });
});
