import Link from "next/link";
import { Logo } from "./Logo";

export function Footer() {
  return (
    <footer className="border-t border-white/5 bg-ink-soft/60 pb-[env(safe-area-inset-bottom)]">
      <div className="mx-auto flex max-w-6xl flex-col gap-6 px-4 py-8 sm:py-10 md:flex-row md:items-center md:justify-between">
        <div className="min-w-0">
          <Logo className="text-xl sm:text-2xl" />
          <p className="mt-2 max-w-md text-sm leading-relaxed text-bit-muted">
            The institutional oracle layer for Bitcoin. Sync Bitcoin with the real world.
          </p>
        </div>
        <div className="flex flex-col gap-3 text-sm text-bit-muted sm:flex-row sm:flex-wrap sm:gap-4">
          <a
            className="inline-flex min-h-[44px] items-center"
            href="https://github.com/RoninGrk1/bitsync-protocol"
            target="_blank"
            rel="noreferrer"
          >
            GitHub
          </a>
          <Link className="inline-flex min-h-[44px] items-center" href="/legal">
            Terms &amp; risk disclosure
          </Link>
          <span className="inline-flex min-h-[44px] items-center text-bit-muted/70">
            Not financial advice
          </span>
        </div>
      </div>
      <p className="border-t border-white/5 px-4 py-4 text-center text-xs leading-relaxed text-bit-muted/70">
        Software is unaudited and not mainnet-ready. Participation may be restricted by jurisdiction.
      </p>
    </footer>
  );
}
