import {
  type Address,
  type Hex,
  type PublicClient,
  type WalletClient,
  parseAbi,
  formatUnits,
  parseUnits,
} from "viem";
import {
  BSY_DECIMALS,
  BSY_SCALE,
  formatBsy,
  type BsyAmount,
} from "./bsy.js";

export const PRESALE_ALLOCATION = 6_300_000n * BSY_SCALE;
export const USD_SCALE = 100_000_000n; // 1e8
/** Suggested default: $0.20 / BSY (governance-configurable on-chain). */
export const SUGGESTED_PRICE_USD_PER_BSY = 20_000_000n;
/** Suggested listing reference only — not on-chain. */
export const SUGGESTED_LISTING_USD_PER_BSY = 30_000_000n;

export const PRESALE_ABI = parseAbi([
  "function PRESALE_ALLOCATION() view returns (uint256)",
  "function totalSold() view returns (uint256)",
  "function totalUsdRaised() view returns (uint256)",
  "function remaining() view returns (uint256)",
  "function saleActive() view returns (bool)",
  "function finalized() view returns (bool)",
  "function softCapFailed() view returns (bool)",
  "function saleFunded() view returns (bool)",
  "function quoteBsy(uint256 usdAmount) view returns (uint256)",
  "function quoteUsd(uint256 bsyAmount) view returns (uint256)",
  "function quoteEth(uint256 bsyAmount) view returns (uint256)",
  "function claimableOf(address account) view returns (uint256)",
  "function purchases(address) view returns (uint256 bsyAllocated, uint256 usdPaid, uint256 claimed, uint256 ethPaid, bool refunded)",
  "function getConfig() view returns ((uint64 start, uint64 end, uint64 tge, uint256 priceUsdPerBsy, uint256 softCapBsy, uint256 minBuyUsd, uint256 maxBuyUsd, uint16 tgeUnlockBps, uint64 vestingDuration, uint64 oracleMaxStale, bool kycRequired))",
  "function buyWithEth(uint256 minBsyOut, bytes kycSig, uint256 kycDeadline, bytes32 jurisdictionHash) payable",
  "function buyWithStable(address token, uint256 amount, uint256 minBsyOut, bytes kycSig, uint256 kycDeadline, bytes32 jurisdictionHash)",
  "function claim()",
  "function claimRefund()",
  "function kycDigest(address buyer, uint256 deadline, bytes32 jurisdictionHash) view returns (bytes32)",
]);

export const ERC20_ABI = parseAbi([
  "function approve(address spender, uint256 amount) returns (bool)",
  "function allowance(address owner, address spender) view returns (uint256)",
  "function decimals() view returns (uint8)",
  "function balanceOf(address) view returns (uint256)",
]);

export type PaymentMethod = "ETH" | "USDC" | "USDT";

export interface PresaleStatus {
  allocation: bigint;
  totalSold: bigint;
  remaining: bigint;
  totalUsdRaised: bigint;
  saleActive: boolean;
  finalized: boolean;
  softCapFailed: boolean;
  priceUsdPerBsy: bigint;
  start: bigint;
  end: bigint;
  tge: bigint;
  progressBps: number; // 0–10000
}

export interface PresaleClientConfig {
  publicClient: PublicClient;
  presaleAddress: Address;
  usdcAddress?: Address;
  usdtAddress?: Address;
}

export class PresaleClient {
  readonly publicClient: PublicClient;
  readonly address: Address;
  readonly usdc?: Address;
  readonly usdt?: Address;

  constructor(cfg: PresaleClientConfig) {
    this.publicClient = cfg.publicClient;
    this.address = cfg.presaleAddress;
    this.usdc = cfg.usdcAddress;
    this.usdt = cfg.usdtAddress;
  }

  async getStatus(): Promise<PresaleStatus> {
    const [allocation, totalSold, remaining, totalUsdRaised, saleActive, finalized, softCapFailed, config] =
      await Promise.all([
        this.publicClient.readContract({ address: this.address, abi: PRESALE_ABI, functionName: "PRESALE_ALLOCATION" }),
        this.publicClient.readContract({ address: this.address, abi: PRESALE_ABI, functionName: "totalSold" }),
        this.publicClient.readContract({ address: this.address, abi: PRESALE_ABI, functionName: "remaining" }),
        this.publicClient.readContract({ address: this.address, abi: PRESALE_ABI, functionName: "totalUsdRaised" }),
        this.publicClient.readContract({ address: this.address, abi: PRESALE_ABI, functionName: "saleActive" }),
        this.publicClient.readContract({ address: this.address, abi: PRESALE_ABI, functionName: "finalized" }),
        this.publicClient.readContract({ address: this.address, abi: PRESALE_ABI, functionName: "softCapFailed" }),
        this.publicClient.readContract({ address: this.address, abi: PRESALE_ABI, functionName: "getConfig" }),
      ]);
    const progressBps = allocation === 0n ? 0 : Number((totalSold * 10_000n) / allocation);
    return {
      allocation,
      totalSold,
      remaining,
      totalUsdRaised,
      saleActive,
      finalized,
      softCapFailed,
      priceUsdPerBsy: config.priceUsdPerBsy,
      start: BigInt(config.start),
      end: BigInt(config.end),
      tge: BigInt(config.tge),
      progressBps,
    };
  }

  async quote(bsyAmount: BsyAmount): Promise<{ usd: bigint; ethWei: bigint; formatted: string }> {
    const [usd, ethWei] = await Promise.all([
      this.publicClient.readContract({ address: this.address, abi: PRESALE_ABI, functionName: "quoteUsd", args: [bsyAmount] }),
      this.publicClient.readContract({ address: this.address, abi: PRESALE_ABI, functionName: "quoteEth", args: [bsyAmount] }),
    ]);
    return { usd, ethWei, formatted: formatBsy(bsyAmount) };
  }

  async quoteFromUsd(usdAmount: bigint): Promise<BsyAmount> {
    return this.publicClient.readContract({
      address: this.address,
      abi: PRESALE_ABI,
      functionName: "quoteBsy",
      args: [usdAmount],
    });
  }

  async getPurchase(account: Address) {
    const [bsyAllocated, usdPaid, claimed, ethPaid, refunded] = await this.publicClient.readContract({
      address: this.address,
      abi: PRESALE_ABI,
      functionName: "purchases",
      args: [account],
    });
    const claimable = await this.publicClient.readContract({
      address: this.address,
      abi: PRESALE_ABI,
      functionName: "claimableOf",
      args: [account],
    });
    return { bsyAllocated, usdPaid, claimed, ethPaid, refunded, claimable };
  }

  async buyWithEth(
    wallet: WalletClient,
    account: Address,
    ethWei: bigint,
    minBsyOut: bigint,
    kyc: { sig: Hex; deadline: bigint; jurisdictionHash: Hex } = {
      sig: "0x",
      deadline: 0n,
      jurisdictionHash: "0x0000000000000000000000000000000000000000000000000000000000000000",
    },
  ) {
    return wallet.writeContract({
      address: this.address,
      abi: PRESALE_ABI,
      functionName: "buyWithEth",
      args: [minBsyOut, kyc.sig, kyc.deadline, kyc.jurisdictionHash],
      value: ethWei,
      account,
      chain: wallet.chain,
    });
  }

  async buyWithStable(
    wallet: WalletClient,
    account: Address,
    token: Address,
    amount: bigint,
    minBsyOut: bigint,
    kyc: { sig: Hex; deadline: bigint; jurisdictionHash: Hex } = {
      sig: "0x",
      deadline: 0n,
      jurisdictionHash: "0x0000000000000000000000000000000000000000000000000000000000000000",
    },
  ) {
    const allowance = await this.publicClient.readContract({
      address: token,
      abi: ERC20_ABI,
      functionName: "allowance",
      args: [account, this.address],
    });
    if (allowance < amount) {
      const hash = await wallet.writeContract({
        address: token,
        abi: ERC20_ABI,
        functionName: "approve",
        args: [this.address, amount],
        account,
        chain: wallet.chain,
      });
      await this.publicClient.waitForTransactionReceipt({ hash });
    }
    return wallet.writeContract({
      address: this.address,
      abi: PRESALE_ABI,
      functionName: "buyWithStable",
      args: [token, amount, minBsyOut, kyc.sig, kyc.deadline, kyc.jurisdictionHash],
      account,
      chain: wallet.chain,
    });
  }

  async claim(wallet: WalletClient, account: Address) {
    return wallet.writeContract({
      address: this.address,
      abi: PRESALE_ABI,
      functionName: "claim",
      account,
      chain: wallet.chain,
    });
  }
}

/** Offline quote helpers (no RPC) using suggested price. */
export function offlineQuoteBsy(usdAmount: bigint, price = SUGGESTED_PRICE_USD_PER_BSY): BsyAmount {
  if (usdAmount === 0n || price === 0n) return 0n;
  return (usdAmount * USD_SCALE) / price;
}

export function offlineQuoteUsd(bsyAmount: BsyAmount, price = SUGGESTED_PRICE_USD_PER_BSY): bigint {
  if (bsyAmount === 0n || price === 0n) return 0n;
  return (bsyAmount * price + USD_SCALE - 1n) / USD_SCALE;
}

export function formatUsd(usdScaleAmount: bigint): string {
  return `$${formatUnits(usdScaleAmount, 8)}`;
}

export function parseUsd(input: string): bigint {
  return parseUnits(input.replace(/[$,]/g, ""), 8);
}

export { BSY_DECIMALS, formatBsy, parseUnits, formatUnits };
