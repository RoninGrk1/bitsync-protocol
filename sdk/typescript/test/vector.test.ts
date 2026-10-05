import { readFileSync } from "node:fs";
import { resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";
import {
  type Address,
  type Hex,
  hashTypedData,
  recoverAddress,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { REPORT_TYPES, type Report } from "../src/report.js";

const __dirname = dirname(fileURLToPath(import.meta.url));
const vectorPath = resolve(__dirname, "../../../test-vectors/report_hash.json");

interface Vector {
  chainId: number;
  verifyingContract: Address;
  feedId: Hex;
  reportPrice: number | string;
  reportConfidence: number | string;
  observationPrice: number | string;
  observationConfidence: number | string;
  timestamp: number;
  round: number;
  reportDigest: Hex;
  observationDigest: Hex;
  signer: Address;
  signerPrivateKey: Hex;
  reportSignature: Hex;
  observationSignature: Hex;
}

const OBSERVATION_TYPES = {
  Observation: [
    { name: "feedId", type: "bytes32" },
    { name: "price", type: "int256" },
    { name: "confidence", type: "uint256" },
    { name: "timestamp", type: "uint64" },
    { name: "round", type: "uint64" },
  ],
} as const;

describe("shared EIP-712 vector", () => {
  const v: Vector = JSON.parse(readFileSync(vectorPath, "utf8"));

  it("matches report + observation digests and recovers the signer", async () => {
    const domain = {
      name: "BitSync Oracle",
      version: "1",
      chainId: v.chainId,
      verifyingContract: v.verifyingContract,
    };
    const report: Report = {
      feedId: v.feedId,
      price: BigInt(v.reportPrice),
      confidence: BigInt(v.reportConfidence),
      timestamp: BigInt(v.timestamp),
      round: BigInt(v.round),
    };
    const reportDigest = hashTypedData({
      domain,
      types: REPORT_TYPES,
      primaryType: "Report",
      message: {
        feedId: report.feedId,
        price: report.price,
        confidence: report.confidence,
        timestamp: report.timestamp,
        round: report.round,
      },
    });
    const obsDigest = hashTypedData({
      domain,
      types: OBSERVATION_TYPES,
      primaryType: "Observation",
      message: {
        feedId: v.feedId,
        price: BigInt(v.observationPrice),
        confidence: BigInt(v.observationConfidence),
        timestamp: BigInt(v.timestamp),
        round: BigInt(v.round),
      },
    });
    expect(reportDigest).toBe(v.reportDigest);
    expect(obsDigest).toBe(v.observationDigest);

    expect(
      (await recoverAddress({ hash: reportDigest, signature: v.reportSignature })).toLowerCase(),
    ).toBe(v.signer.toLowerCase());
    expect(
      (await recoverAddress({ hash: obsDigest, signature: v.observationSignature })).toLowerCase(),
    ).toBe(v.signer.toLowerCase());

    // Re-sign with the published vector key and confirm a fresh sig also recovers.
    const account = privateKeyToAccount(v.signerPrivateKey);
    expect(account.address.toLowerCase()).toBe(v.signer.toLowerCase());
  });
});
