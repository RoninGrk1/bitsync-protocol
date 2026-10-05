import type { Metadata } from "next";

export const metadata: Metadata = {
  title: "Terms & Risk Disclosure — BitSync",
};

export default function LegalPage() {
  return (
    <article className="mx-auto max-w-3xl px-4 py-10 sm:py-16">
      <h1 className="text-2xl font-semibold leading-tight text-bit sm:text-3xl">
        Terms &amp; Risk Disclosure
      </h1>
      <p className="mt-3 text-sm leading-relaxed text-bit-muted sm:text-base">
        Last updated: 5 October 2026. This page is a stub for product development — replace with
        counsel-reviewed terms before any public sale.
      </p>

      <h2 className="mt-10 text-lg font-semibold text-bit sm:text-xl">Not financial advice</h2>
      <p className="mt-2 text-sm leading-relaxed text-bit-muted sm:text-base">
        Nothing on this website constitutes an offer to sell, solicitation to buy, investment advice,
        or a recommendation. Digital assets are highly risky and may lose all value.
      </p>

      <h2 className="mt-8 text-lg font-semibold text-bit sm:text-xl">Unaudited software</h2>
      <p className="mt-2 text-sm leading-relaxed text-bit-muted sm:text-base">
        The BitSync protocol, BSY token, and presale contracts are <strong>unaudited</strong> and{" "}
        <strong>not mainnet-ready</strong>. Do not use them with real funds until independent audits,
        a public bug bounty, and legal review are complete.
      </p>

      <h2 className="mt-8 text-lg font-semibold text-bit sm:text-xl">
        Eligibility &amp; jurisdiction
      </h2>
      <p className="mt-2 text-sm leading-relaxed text-bit-muted sm:text-base">
        Access may be restricted by jurisdiction. By default the demo blocks purchases from the
        United States, United Kingdom, and other listed countries via a compliance API stub. On-chain
        purchases can additionally require an EIP-712 KYC approval from a compliance signer.
        Circumventing geo or KYC controls is prohibited.
      </p>

      <h2 className="mt-8 text-lg font-semibold text-bit sm:text-xl">Token &amp; sale risks</h2>
      <ul className="mt-2 list-disc space-y-2 pl-5 text-sm leading-relaxed text-bit-muted sm:text-base">
        <li>Smart-contract bugs, oracle failures, or pause events may prevent buys or claims.</li>
        <li>Suggested prices and FDV figures are illustrative and governance-configurable.</li>
        <li>Soft-cap failure (if enabled) may entitle buyers only to refunds, not tokens.</li>
        <li>Vesting schedules may delay claimability after TGE.</li>
        <li>Regulatory action could halt the sale or require refunds.</li>
      </ul>

      <h2 className="mt-8 text-lg font-semibold text-bit sm:text-xl">Proceeds</h2>
      <p className="mt-2 text-sm leading-relaxed text-bit-muted sm:text-base">
        Sale proceeds are withdrawable only to a configured treasury / multisig address. BitSync
        makes no guarantee of listing, liquidity, or secondary-market price.
      </p>

      <p className="mt-10 text-sm leading-relaxed text-bit-muted">
        Contact legal counsel and a licensed KYC/AML provider before any public launch. See also{" "}
        <a
          className="break-all text-sync-glow underline"
          href="https://github.com/RoninGrk1/bitsync-protocol"
        >
          the protocol repository
        </a>
        .
      </p>
    </article>
  );
}
