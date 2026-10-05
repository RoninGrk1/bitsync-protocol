/**
 * Provider-agnostic KYC attestation hook (BSY-C2).
 * Production wires Sumsub/Persona/etc. Fail closed when unconfigured.
 */

export type KycAttestation = {
  buyer: `0x${string}`;
  country: string;
  /** Opaque provider reference (session / applicant id). */
  providerRef: string;
  approved: boolean;
};

export interface KycProvider {
  /** Verify the caller completed KYC with the external provider. */
  attest(input: { buyer: `0x${string}`; country: string; providerToken?: string }): Promise<KycAttestation>;
}

/** Fail-closed default: rejects every request until a real provider is configured. */
export class UnconfiguredKycProvider implements KycProvider {
  async attest(): Promise<KycAttestation> {
    throw new Error("KYC provider unconfigured — set KYC_PROVIDER=stub only for local demos, or integrate a licensed provider");
  }
}

/**
 * Local-demo stub. Enabled only when KYC_PROVIDER=stub AND COMPLIANCE_SIGNER_KEY is set
 * (server-only env — never NEXT_PUBLIC_*). Still requires a non-blocked country from headers.
 */
export class StubKycProvider implements KycProvider {
  async attest(input: { buyer: `0x${string}`; country: string }): Promise<KycAttestation> {
    return {
      buyer: input.buyer,
      country: input.country,
      providerRef: `stub:${input.buyer}:${input.country}`,
      approved: true,
    };
  }
}

export function getKycProvider(): KycProvider {
  const mode = (process.env.KYC_PROVIDER || "").toLowerCase();
  if (mode === "stub") return new StubKycProvider();
  return new UnconfiguredKycProvider();
}

/** Country from trusted edge headers only — never from query/body (BSY-C2). */
export function countryFromHeaders(headers: Headers): string {
  const raw =
    headers.get("cf-ipcountry") ||
    headers.get("x-vercel-ip-country") ||
    headers.get("x-country-code") ||
    "";
  return raw.toUpperCase() || "XX";
}
