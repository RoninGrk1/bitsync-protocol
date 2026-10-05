import Link from "next/link";
import { Logo } from "./Logo";

export function Footer() {
  return (
    <footer className="border-t border-white/5 bg-ink-soft/60">
      <div className="mx-auto flex max-w-6xl flex-col gap-6 px-4 py-10 md:flex-row md:items-center md:justify-between">
        <div>
          <Logo />
          <p className="mt-2 max-w-md text-sm text-bit-muted">
            The institutional oracle layer for Bitcoin. Sync Bitcoin with the real world.
          </p>
        </div>
        <div className="flex flex-wrap gap-4 text-sm text-bit-muted">
          <a href="https://github.com/RoninGrk1/bitsync-protocol" target="_blank" rel="noreferrer">
            GitHub
          </a>
          <Link href="/legal">Terms &amp; risk disclosure</Link>
          <span className="text-bit-muted/70">Not financial advice</span>
        </div>
      </div>
      <p className="border-t border-white/5 px-4 py-4 text-center text-xs text-bit-muted/70">
        Software is unaudited and not mainnet-ready. Participation may be restricted by jurisdiction.
      </p>
    </footer>
  );
}
