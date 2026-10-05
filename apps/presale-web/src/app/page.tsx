import Image from "next/image";
import { PresaleWidget } from "@/components/PresaleWidget";
import { Logo } from "@/components/Logo";

const features = [
  {
    title: "Real-world data",
    body: "Institutional sources with cryptographic payload verification feed every round.",
  },
  {
    title: "Decentralized oracles",
    body: "n = 3f + 1 stake-weighted BFT aggregation with outlier rejection and on-chain quorum.",
  },
  {
    title: "Built for Bitcoin",
    body: "EVM / Bitcoin L2 execution plus periodic OP_RETURN Merkle anchors to Bitcoin settlement.",
  },
  {
    title: "Secure & scalable",
    body: "Threshold FROST co-signing, HSM-ready signer trait, pausable contracts, progressive decentralization.",
  },
];

export default function HomePage() {
  return (
    <>
      <section className="relative overflow-hidden">
        <div className="mx-auto grid max-w-6xl items-center gap-8 px-4 py-10 sm:gap-10 sm:py-16 md:grid-cols-2 md:py-24">
          <div className="min-w-0 order-1">
            <p className="mb-3 text-[0.7rem] font-medium uppercase tracking-[0.18em] text-sync-glow sm:text-sm sm:tracking-[0.2em]">
              Sync Bitcoin with the real world
            </p>
            <h1 className="font-display text-[1.75rem] font-semibold leading-tight sm:text-4xl md:text-5xl">
              <Logo className="text-[1.75rem] sm:text-4xl md:text-5xl" />
              <span className="mt-3 block text-base font-semibold text-bit sm:text-2xl md:text-3xl">
                The institutional oracle layer for Bitcoin.
              </span>
            </h1>
            <p className="mt-4 max-w-xl text-sm leading-relaxed text-bit-muted sm:mt-5 sm:text-base">
              Fixed-supply BSY secures the oracle set. Join the 6.3M BSY (15%) presale —
              suggested $0.20 / BSY, governance-configurable before launch.
            </p>
            <div className="mt-6 flex w-full flex-col gap-3 sm:mt-8 sm:flex-row sm:flex-wrap">
              <a href="#presale" className="btn-primary w-full sm:w-auto">
                Join the presale
              </a>
              <a
                href="https://github.com/RoninGrk1/bitsync-protocol"
                className="btn-ghost w-full sm:w-auto"
                target="_blank"
                rel="noreferrer"
              >
                View the protocol
              </a>
            </div>
            <p className="mt-4 text-xs leading-relaxed text-amber-200/80">
              Unaudited software · Not mainnet-ready · Not financial advice
            </p>
          </div>
          <div className="relative order-2 mx-auto w-full max-w-md min-w-0 md:max-w-none">
            <div className="absolute -inset-4 rounded-full bg-sync/20 blur-3xl sm:-inset-6" aria-hidden />
            <Image
              src="/hero.jpg"
              alt="BitSync brand — Earth rising over a lunar horizon"
              width={720}
              height={720}
              sizes="(max-width: 768px) 100vw, 50vw"
              className="relative z-10 mx-auto h-auto w-full max-w-full rounded-2xl border border-white/10 shadow-2xl sm:rounded-3xl"
              priority
            />
          </div>
        </div>
      </section>

      <section className="mx-auto max-w-6xl px-4 pb-12 sm:pb-20">
        <div className="grid gap-6 md:grid-cols-5 md:gap-8">
          <div className="min-w-0 md:col-span-3">
            <PresaleWidget />
          </div>
          <aside className="glass min-w-0 p-5 text-sm text-bit-muted sm:p-6 md:col-span-2">
            <h3 className="mb-3 text-base font-semibold text-bit">Suggested parameters</h3>
            <ul className="space-y-2">
              <li>
                Allocation: <strong className="text-bit">6,300,000 BSY</strong> (15%)
              </li>
              <li>
                Price: <strong className="text-bit">$0.20</strong> / BSY (configurable)
              </li>
              <li>
                Hard cap: ~<strong className="text-bit">$1.26M</strong>
              </li>
              <li>Implied FDV at sale: ~$8.4M (illustrative)</li>
              <li>Listing reference: $0.30 (marketing only)</li>
              <li>Pay with ETH, USDC, or USDT</li>
              <li>Optional KYC / jurisdiction gate</li>
            </ul>
            <p className="mt-4 text-xs leading-relaxed">
              On-chain price and caps are set by governance before start — these figures are
              suggestions for the UI and local demo only.
            </p>
          </aside>
        </div>
      </section>

      <section id="features" className="border-y border-white/5 bg-ink-soft/40 py-12 sm:py-20">
        <div className="mx-auto max-w-6xl px-4">
          <h2 className="mb-8 text-center text-2xl font-semibold sm:mb-10 sm:text-3xl">
            Built for institutions
          </h2>
          <div className="grid grid-cols-1 gap-4 sm:grid-cols-2 sm:gap-6 lg:grid-cols-4">
            {features.map((f) => (
              <div key={f.title} className="glass p-5">
                <h3 className="mb-2 font-semibold text-sync-glow">{f.title}</h3>
                <p className="text-sm leading-relaxed text-bit-muted">{f.body}</p>
              </div>
            ))}
          </div>
        </div>
      </section>

      <section id="tokenomics" className="py-12 sm:py-20">
        <div className="mx-auto max-w-6xl px-4">
          <h2 className="mb-4 text-2xl font-semibold sm:text-3xl">Tokenomics</h2>
          <p className="mb-8 max-w-2xl text-sm leading-relaxed text-bit-muted sm:text-base">
            BitSync (BSY): fixed <strong className="text-bit">42,000,000</strong> supply,{" "}
            <strong className="text-bit">8 decimals</strong>,{" "}
            <strong className="text-bit">0% inflation</strong>. Full genesis mint to treasury — no
            mint function thereafter.
          </p>
          <div className="grid grid-cols-1 gap-4 sm:grid-cols-2 lg:grid-cols-4">
            {[
              { label: "Presale", pct: "15%", amt: "6.3M", note: "Fixed", hot: true },
              { label: "Ecosystem", pct: "40%", amt: "16.8M", note: "Proposed" },
              { label: "Treasury", pct: "25%", amt: "10.5M", note: "Proposed" },
              { label: "Contributors", pct: "20%", amt: "8.4M", note: "Proposed" },
            ].map((b) => (
              <div
                key={b.label}
                className={`glass p-5 ${b.hot ? "ring-1 ring-sync/50" : ""}`}
              >
                <div className="text-sm text-bit-muted">{b.label}</div>
                <div className="mt-1 text-2xl font-semibold text-bit">{b.pct}</div>
                <div className="text-sm text-sync-glow">{b.amt} BSY</div>
                <div className="mt-2 text-xs uppercase tracking-wide text-bit-muted">{b.note}</div>
              </div>
            ))}
          </div>
        </div>
      </section>

      <section id="roadmap" className="border-t border-white/5 bg-ink-soft/40 py-12 sm:py-20">
        <div className="mx-auto max-w-6xl px-4">
          <h2 className="mb-8 text-2xl font-semibold sm:text-3xl">Roadmap</h2>
          <ol className="grid grid-cols-1 gap-4 sm:grid-cols-2 lg:grid-cols-4">
            {[
              ["Now", "Unaudited testnet / local demo, networked oracle rounds, presale contracts"],
              ["Next", "External audit, KYC provider, WalletConnect production id, testnet sale"],
              ["Then", "Mainnet oracle + progressive decentralization (multisig → governor)"],
              ["Later", "Bitcoin-native BSY representation with 42M cross-chain invariant"],
            ].map(([t, d]) => (
              <li key={t} className="glass p-5">
                <div className="text-sm font-semibold text-sync-glow">{t}</div>
                <p className="mt-2 text-sm leading-relaxed text-bit-muted">{d}</p>
              </li>
            ))}
          </ol>
        </div>
      </section>

      <section id="security" className="py-12 sm:py-20">
        <div className="mx-auto max-w-6xl px-4">
          <h2 className="mb-4 text-2xl font-semibold sm:text-3xl">Security</h2>
          <div className="glass border-amber-400/30 p-5 text-sm leading-relaxed text-bit-muted sm:p-6">
            <p className="font-semibold text-amber-200">Unaudited — not mainnet-ready.</p>
            <p className="mt-2">
              Do not use this software with real funds until independent audits, a public bug bounty,
              and legal review are complete. See{" "}
              <code className="break-all text-sync-glow">docs/SECURITY.md</code> in the protocol
              repo.
            </p>
          </div>
        </div>
      </section>

      <section id="faq" className="border-t border-white/5 py-12 sm:py-20">
        <div className="mx-auto max-w-6xl px-4">
          <h2 className="mb-8 text-2xl font-semibold sm:text-3xl">FAQ</h2>
          <div className="space-y-4">
            {[
              [
                "What is BSY?",
                "BitSync is a fixed-supply utility token used for oracle staking, fees, and (roadmap) governance.",
              ],
              [
                "How do I buy?",
                "Connect a wallet, choose ETH or a stablecoin, enter an amount, acknowledge the disclosure, and confirm. KYC may be required depending on configuration.",
              ],
              [
                "When can I claim?",
                "After the sale ends and TGE timestamp, according to the on-chain vesting schedule (e.g. partial unlock at TGE + linear vest).",
              ],
              [
                "Is this available worldwide?",
                "No. Restricted jurisdictions are blocked via the compliance API and optional on-chain KYC signatures.",
              ],
            ].map(([q, a]) => (
              <details key={q} className="glass p-5">
                <summary className="min-h-[44px] cursor-pointer list-none font-medium outline-none [&::-webkit-details-marker]:hidden">
                  {q}
                </summary>
                <p className="mt-2 text-sm leading-relaxed text-bit-muted">{a}</p>
              </details>
            ))}
          </div>
        </div>
      </section>
    </>
  );
}
