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
import { countryFromHeaders, getKycProvider } from "@/lib/compliance/provider";

/**
 * EIP-712 KYC approval signer.
 * - Signer key: COMPLIANCE_SIGNER_KEY (server-only; no Anvil default).
 * - Country: from request headers only.
 * - Provider attestation required (fail closed when unconfigured).
 * - Nonce must match on-chain kycNonce(buyer).
 */
export async function POST(req: NextRequest) {
  try {
    const body = (await req.json()) as {
      buyer?: string;
      nonce?: string | number;
      providerToken?: string;
    };
    const buyer = body.buyer as Address | undefined;
    if (!buyer || !/^0x[a-fA-F0-9]{40}$/.test(buyer)) {
      return NextResponse.json({ ok: false, error: "Invalid buyer address" }, { status: 400 });
    }

    const country = countryFromHeaders(req.headers);
    if (blockedCountries.includes(country)) {
      return NextResponse.json(
        { ok: false, error: `Jurisdiction blocked: ${country}` },
        { status: 403 },
      );
    }

    const pk = process.env.COMPLIANCE_SIGNER_KEY as Hex | undefined;
    if (!pk || !/^0x[a-fA-F0-9]{64}$/.test(pk)) {
      return NextResponse.json(
        { ok: false, error: "COMPLIANCE_SIGNER_KEY not configured" },
        { status: 503 },
      );
    }

    const provider = getKycProvider();
    let attestation;
    try {
      attestation = await provider.attest({
        buyer,
        country,
        providerToken: body.providerToken,
      });
    } catch (e: unknown) {
      return NextResponse.json(
        { ok: false, error: e instanceof Error ? e.message : String(e) },
        { status: 503 },
      );
    }
    if (!attestation.approved) {
      return NextResponse.json({ ok: false, error: "KYC not approved" }, { status: 403 });
    }

    const account = privateKeyToAccount(pk);
    const deadline = BigInt(Math.floor(Date.now() / 1000) + 3600);
    const jurisdictionHash = keccak256(toBytes(country));
    const nonce = BigInt(body.nonce ?? 0);

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

    const client = createWalletClient({ account, chain, transport: http(rpc) });
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
          { name: "nonce", type: "uint256" },
          { name: "deadline", type: "uint256" },
          { name: "jurisdictionHash", type: "bytes32" },
        ],
      },
      primaryType: "KycApproval",
      message: { buyer, nonce, deadline, jurisdictionHash },
    });

    return NextResponse.json({
      ok: true,
      signature,
      deadline: deadline.toString(),
      nonce: nonce.toString(),
      jurisdictionHash,
      signer: account.address,
      country,
      providerRef: attestation.providerRef,
    });
  } catch (e: unknown) {
    return NextResponse.json(
      { ok: false, error: e instanceof Error ? e.message : String(e) },
      { status: 500 },
    );
  }
}
