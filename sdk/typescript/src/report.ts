import {
  type Address,
  type Hex,
  encodeAbiParameters,
  hashTypedData,
  hexToBytes,
  recoverAddress,
  type TypedDataDomain,
} from "viem";

export interface Report {
  feedId: Hex;
  price: bigint;
  confidence: bigint;
  timestamp: bigint;
  round: bigint;
}

export interface Domain {
  chainId: number;
  verifyingContract: Address;
}

export const REPORT_TYPES = {
  Report: [
    { name: "feedId", type: "bytes32" },
    { name: "price", type: "int256" },
    { name: "confidence", type: "uint256" },
    { name: "timestamp", type: "uint64" },
    { name: "round", type: "uint64" },
  ],
} as const;

export function bitsyncDomain(domain: Domain): TypedDataDomain {
  return {
    name: "BitSync Oracle",
    version: "1",
    chainId: domain.chainId,
    verifyingContract: domain.verifyingContract,
  };
}

export function reportDigest(report: Report, domain: Domain): Hex {
  return hashTypedData({
    domain: bitsyncDomain(domain),
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
}

export async function recoverReportSigner(
  report: Report,
  domain: Domain,
  signature: Hex,
): Promise<Address> {
  return recoverAddress({ hash: reportDigest(report, domain), signature });
}

export async function verifyQuorum(
  report: Report,
  domain: Domain,
  operators: Address[],
  signatures: Hex[],
  quorum: number,
): Promise<void> {
  if (operators.length !== signatures.length) {
    throw new Error("operators/signatures length mismatch");
  }
  const seen = new Set<string>();
  for (let i = 0; i < operators.length; i++) {
    const recovered = await recoverReportSigner(report, domain, signatures[i]);
    if (recovered.toLowerCase() !== operators[i].toLowerCase()) {
      throw new Error(`signature ${i} recovers to ${recovered}, expected ${operators[i]}`);
    }
    const key = recovered.toLowerCase();
    if (seen.has(key)) throw new Error(`duplicate operator ${recovered}`);
    seen.add(key);
  }
  if (seen.size < quorum) throw new Error(`quorum not met: ${seen.size} < ${quorum}`);
}

/** Right-pad a UTF-8 label into a bytes32 feed id (matches Rust helper). */
export function feedIdFromLabel(label: string): Hex {
  const bytes = new TextEncoder().encode(label);
  if (bytes.length > 32) throw new Error("label too long");
  const out = new Uint8Array(32);
  out.set(bytes);
  return `0x${Buffer.from(out).toString("hex")}` as Hex;
}

export { encodeAbiParameters, hexToBytes };
