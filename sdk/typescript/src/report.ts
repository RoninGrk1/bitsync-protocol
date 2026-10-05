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

export type StakeMap = Record<string, bigint>; // address(lowercase) -> active stake

/**
 * Verify report signatures against a trusted operator stake set.
 * Requires signed stake *strictly greater than* 2/3 of totalActiveStake
 * (matches OracleAggregator) and optional minSigners floor (BSY-H8).
 */
export async function verifyQuorum(
  report: Report,
  domain: Domain,
  signatures: Hex[],
  stakes: StakeMap,
  opts: { minSigners?: number } = {},
): Promise<{ signedStake: bigint; totalActiveStake: bigint; signers: Address[] }> {
  const totalActiveStake = Object.values(stakes).reduce((a, b) => a + b, 0n);
  if (totalActiveStake === 0n) throw new Error("no active stake");

  const minSigners = opts.minSigners ?? 1;
  if (signatures.length < minSigners) {
    throw new Error(`too few signers: ${signatures.length} < ${minSigners}`);
  }

  const seen = new Set<string>();
  const signers: Address[] = [];
  let signedStake = 0n;
  let prev = "";
  for (let i = 0; i < signatures.length; i++) {
    const recovered = (await recoverReportSigner(report, domain, signatures[i])).toLowerCase() as Address;
    if (prev && recovered.toLowerCase() <= prev) {
      throw new Error("signers not strictly ascending");
    }
    prev = recovered.toLowerCase();
    if (seen.has(prev)) throw new Error(`duplicate operator ${recovered}`);
    const stake = stakes[prev] ?? 0n;
    if (stake === 0n) throw new Error(`not an active operator: ${recovered}`);
    seen.add(prev);
    signers.push(recovered);
    signedStake += stake;
  }
  // Strictly > 2/3: signed * 3 > total * 2
  if (signedStake * 3n <= totalActiveStake * 2n) {
    throw new Error(
      `insufficient stake quorum: signed ${signedStake} / total ${totalActiveStake} (need >2/3)`,
    );
  }
  return { signedStake, totalActiveStake, signers };
}

/** @deprecated Use verifyQuorum(report, domain, signatures, stakes). Count-only checks are unsafe. */
export async function verifyQuorumCountOnly(
  report: Report,
  domain: Domain,
  operators: Address[],
  signatures: Hex[],
  quorum: number,
): Promise<void> {
  if (operators.length !== signatures.length) {
    throw new Error("operators/signatures length mismatch");
  }
  const stakes: StakeMap = {};
  for (const op of operators) stakes[op.toLowerCase()] = 1n;
  // Equal stake of 1 each → need strict >2/3 of operators.length
  await verifyQuorum(report, domain, signatures, stakes, { minSigners: quorum });
}

/** Canonical feed id: UTF-8 label left-aligned in bytes32, zero-padded (matches Solidity BitSyncTypes / Rust). */
export function feedIdFromLabel(label: string): Hex {
  const bytes = new TextEncoder().encode(label);
  if (bytes.length > 32) throw new Error("label too long");
  const out = new Uint8Array(32);
  out.set(bytes);
  return `0x${Buffer.from(out).toString("hex")}` as Hex;
}

export { encodeAbiParameters, hexToBytes };
