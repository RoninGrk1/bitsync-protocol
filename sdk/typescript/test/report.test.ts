import { describe, expect, it } from "vitest";
import { generatePrivateKey, privateKeyToAccount } from "viem/accounts";
import {
  feedIdFromLabel,
  reportDigest,
  verifyQuorum,
  type Report,
  type StakeMap,
} from "../src/report.js";

describe("report EIP-712", () => {
  it("verifies a stake-weighted >2/3 quorum (BSY-H8)", async () => {
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
    expect(reportDigest(report, domain).startsWith("0x")).toBe(true);
    expect(feedIdFromLabel("BTC/USD")).toBe(
      "0x4254432f55534400000000000000000000000000000000000000000000000000",
    );

    const accounts = [0, 1, 2, 3].map(() => privateKeyToAccount(generatePrivateKey()));
    accounts.sort((a, b) => (a.address.toLowerCase() < b.address.toLowerCase() ? -1 : 1));
    const stakes: StakeMap = {};
    for (const a of accounts) stakes[a.address.toLowerCase()] = 100n;

    const signers = accounts.slice(0, 3); // 300/400 > 2/3
    const signatures = [];
    for (const account of signers) {
      signatures.push(
        await account.signTypedData({
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
        }),
      );
    }
    await verifyQuorum(report, domain, signatures, stakes, { minSigners: 3 });

    // Exact 2/3 (2 of 3 equal) must fail on-chain rule
    const two = signatures.slice(0, 2);
    await expect(verifyQuorum(report, domain, two, stakes, { minSigners: 1 })).rejects.toThrow(
      /insufficient stake quorum/,
    );

    // Attacker-controlled operators with no stake entry are rejected
    const forged = privateKeyToAccount(generatePrivateKey());
    const forgedSig = await forged.signTypedData({
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
        price: 1n,
        confidence: 0n,
        timestamp: report.timestamp,
        round: 999n,
      },
    });
    await expect(
      verifyQuorum(
        { ...report, price: 1n, round: 999n },
        domain,
        [forgedSig],
        stakes,
      ),
    ).rejects.toThrow(/not an active operator/);
  });
});
