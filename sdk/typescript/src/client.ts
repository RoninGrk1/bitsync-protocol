import {
  type Address,
  type Hex,
  type PublicClient,
  createPublicClient,
  http,
  parseAbi,
} from "viem";
import type { Report } from "./report.js";

const ORACLE_ABI = parseAbi([
  "function latestRoundData(bytes32 feedId) view returns (int256 price, uint256 confidence, uint64 timestamp, uint64 round, uint64 answeredAt)",
  "function feeds(bytes32 feedId) view returns (bool active, uint8 decimals, uint64 minQuorum, uint64 maxStaleness)",
]);

export interface FeedClientConfig {
  rpcUrl: string;
  oracleAddress: Address;
}

export class FeedClient {
  readonly client: PublicClient;
  readonly oracle: Address;

  constructor(cfg: FeedClientConfig) {
    this.client = createPublicClient({ transport: http(cfg.rpcUrl) });
    this.oracle = cfg.oracleAddress;
  }

  async latestRoundData(feedId: Hex): Promise<{
    price: bigint;
    confidence: bigint;
    timestamp: bigint;
    round: bigint;
    answeredAt: bigint;
  }> {
    const [price, confidence, timestamp, round, answeredAt] = await this.client.readContract({
      address: this.oracle,
      abi: ORACLE_ABI,
      functionName: "latestRoundData",
      args: [feedId],
    });
    return { price, confidence, timestamp, round, answeredAt };
  }

  async toReport(feedId: Hex): Promise<Report> {
    const d = await this.latestRoundData(feedId);
    return {
      feedId,
      price: d.price,
      confidence: d.confidence,
      timestamp: d.timestamp,
      round: d.round,
    };
  }
}
