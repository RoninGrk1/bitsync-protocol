import { type Address, type Chain, http } from "viem";

export const walletConnectProjectId =
  process.env.NEXT_PUBLIC_WALLETCONNECT_PROJECT_ID || "bitsync_placeholder_project_id";

export const chainId = Number(process.env.NEXT_PUBLIC_CHAIN_ID || 31337);
export const rpcUrl = process.env.NEXT_PUBLIC_RPC_URL || "http://127.0.0.1:8545";

export const addresses = {
  bsy: (process.env.NEXT_PUBLIC_BSY_ADDRESS || "0x0000000000000000000000000000000000000000") as Address,
  presale: (process.env.NEXT_PUBLIC_PRESALE_ADDRESS ||
    "0x0000000000000000000000000000000000000000") as Address,
  usdc: (process.env.NEXT_PUBLIC_USDC_ADDRESS || "0x0000000000000000000000000000000000000000") as Address,
  usdt: (process.env.NEXT_PUBLIC_USDT_ADDRESS || "0x0000000000000000000000000000000000000000") as Address,
};

export const blockedCountries = (process.env.BLOCKED_COUNTRIES || "US,GB,UK")
  .split(",")
  .map((s) => s.trim().toUpperCase())
  .filter(Boolean);

export function activeChain(): Chain {
  const base: Chain = {
    id: chainId,
    name: chainId === 31337 ? "Anvil" : chainId === 11155111 ? "Sepolia" : `Chain ${chainId}`,
    nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
    rpcUrls: { default: { http: [rpcUrl] }, public: { http: [rpcUrl] } },
  };
  return base;
}

export const transports = { [activeChain().id]: http(rpcUrl) } as const;
