import { NextRequest, NextResponse } from "next/server";
import { blockedCountries } from "@/lib/config";

/**
 * Stub geo / jurisdiction check.
 * Production: replace with a real geo-IP + KYC provider (e.g. Sumsub, Persona).
 * Client may pass ?country=XX for local testing; otherwise uses CF-IPCountry / Accept-Language heuristic.
 */
export async function GET(req: NextRequest) {
  const url = new URL(req.url);
  const override = url.searchParams.get("country")?.toUpperCase();
  const headerCountry =
    req.headers.get("cf-ipcountry") ||
    req.headers.get("x-vercel-ip-country") ||
    req.headers.get("x-country-code") ||
    "";
  const country = (override || headerCountry || "XX").toUpperCase();
  const blocked = blockedCountries.includes(country);
  const kycRequired = process.env.KYC_REQUIRED === "true";

  return NextResponse.json({
    ok: true,
    country,
    blocked,
    kycRequired,
    blockedList: blockedCountries,
    notice: "Stub compliance API — not production grade.",
  });
}
