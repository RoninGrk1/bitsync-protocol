import { NextRequest, NextResponse } from "next/server";
import { blockedCountries } from "@/lib/config";
import { countryFromHeaders } from "@/lib/compliance/provider";

/**
 * Geo / jurisdiction check. Country is derived from edge headers only
 * (cf-ipcountry / x-vercel-ip-country). Query overrides are ignored (BSY-C2).
 */
export async function GET(req: NextRequest) {
  const country = countryFromHeaders(req.headers);
  const blocked = blockedCountries.includes(country);
  const kycRequired = process.env.KYC_REQUIRED === "true";
  const providerConfigured =
    (process.env.KYC_PROVIDER || "").length > 0 && !!process.env.COMPLIANCE_SIGNER_KEY;

  return NextResponse.json({
    ok: true,
    country,
    blocked,
    kycRequired,
    providerConfigured,
    blockedList: blockedCountries,
  });
}
