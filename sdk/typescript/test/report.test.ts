import { describe, expect, it } from "vitest";
import { generatePrivateKey, privateKeyToAccount } from "viem/accounts";
import {
  feedIdFromLabel,
  reportDigest,
  verifyQuorum,
  type Report,
} from "../src/report.js";

describe("report EIP-712", () => {
  it("verifies a 3-of-3 quorum", async () => {
    const domain = {
      chainId: 1,
      verifyingContract: "0x1111111111111111111111111111111111111111" as const,
    };
    const report: Report = {
      feedId: feedIdFromLabel("BTC/USD"),
      price: 6_425_000_000_000n,
      confidence: 1_000_000_000n,
      timestamp: 1_700_000_000n,
      round: 42n,
    };
    const digest = reportDigest(report, domain);
    expect(digest.startsWith("0x")).toBe(true);

    const operators = [];
    const signatures = [];
    for (let i = 0; i < 3; i++) {
      const pk = generatePrivateKey();
      const account = privateKeyToAccount(pk);
      const sig = await account.signTypedData({
        domain: {
          name: "BitSync Oracle",
          version: "1",
          chainId: domain.chainId,
          verifyingContract: domain.verifyingContract,
        },
        types: {
          Report: [
            { name: "feedId", type: "bytes32" },
            { name: "price", type: "int256" },
            { name: "confidence", type: "uint256" },
            { name: "timestamp", type: "uint64" },
            { name: "round", type: "uint64" },
          ],
        },
        primaryType: "Report",
        message: {
          feedId: report.feedId,
          price: report.price,
          confidence: report.confidence,
          timestamp: report.timestamp,
          round: report.round,
        },
      });
      operators.push(account.address);
      signatures.push(sig);
    }
    await verifyQuorum(report, domain, operators, signatures, 3);
    await expect(verifyQuorum(report, domain, operators, signatures, 4)).rejects.toThrow();
  });
});
