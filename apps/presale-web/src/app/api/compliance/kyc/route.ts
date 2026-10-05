import { NextRequest, NextResponse } from "next/server";
import {
  createWalletClient,
  http,
  keccak256,
  toBytes,
  type Hex,
  type Address,
  type Chain,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { blockedCountries } from "@/lib/config";

/**
 * Stub EIP-712 KYC approval signer for local demos.
 * Uses ANVIL_COMPLIANCE_KEY (defaults to Anvil account #0) — never use in production.
 * Domain name must match BSYPresale EIP712("BitSync Presale", "1").
 */
export async function POST(req: NextRequest) {
  try {
    const body = (await req.json()) as { buyer?: string; country?: string };
    const buyer = body.buyer as Address | undefined;
    const country = (body.country || "XX").toUpperCase();
    if (!buyer || !/^0x[a-fA-F0-9]{40}$/.test(buyer)) {
      return NextResponse.json({ ok: false, error: "Invalid buyer address" }, { status: 400 });
    }
    if (blockedCountries.includes(country)) {
      return NextResponse.json(
        { ok: false, error: `Jurisdiction blocked: ${country}` },
        { status: 403 },
      );
    }

    const pk = (process.env.ANVIL_COMPLIANCE_KEY ||
      "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80") as Hex;
    const account = privateKeyToAccount(pk);
    const deadline = BigInt(Math.floor(Date.now() / 1000) + 3600);
    const jurisdictionHash = keccak256(toBytes(country));

    const chainId = Number(process.env.NEXT_PUBLIC_CHAIN_ID || 31337);
    const rpc = process.env.NEXT_PUBLIC_RPC_URL || "http://127.0.0.1:8545";
    const verifyingContract = (process.env.NEXT_PUBLIC_PRESALE_ADDRESS ||
      "0x0000000000000000000000000000000000000000") as Address;

    const chain: Chain = {
      id: chainId,
      name: `Chain ${chainId}`,
      nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
      rpcUrls: { default: { http: [rpc] } },
    };

    const client = createWalletClient({
      account,
      chain,
      transport: http(rpc),
    });

    const signature = await client.signTypedData({
      account,
      domain: {
        name: "BitSync Presale",
        version: "1",
        chainId,
        verifyingContract,
      },
      types: {
        KycApproval: [
          { name: "buyer", type: "address" },
          { name: "deadline", type: "uint256" },
          { name: "jurisdictionHash", type: "bytes32" },
        ],
      },
      primaryType: "KycApproval",
      message: {
        buyer,
        deadline,
        jurisdictionHash,
      },
    });

    return NextResponse.json({
      ok: true,
      signature,
      deadline: deadline.toString(),
      jurisdictionHash,
      signer: account.address,
      notice: "Stub KYC signer — replace with licensed provider.",
    });
  } catch (e: unknown) {
    return NextResponse.json(
      { ok: false, error: e instanceof Error ? e.message : String(e) },
      { status: 500 },
    );
  }
}
