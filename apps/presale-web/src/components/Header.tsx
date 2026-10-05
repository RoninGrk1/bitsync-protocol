"use client";

import Link from "next/link";
import { ConnectButton } from "@rainbow-me/rainbowkit";
import { Logo } from "./Logo";

const links = [
  { href: "/#presale", label: "Presale" },
  { href: "/#features", label: "Features" },
  { href: "/#tokenomics", label: "Tokenomics" },
  { href: "/#roadmap", label: "Roadmap" },
  { href: "/legal", label: "Legal" },
];

export function Header() {
  return (
    <header className="sticky top-0 z-40 border-b border-white/5 bg-ink/80 backdrop-blur-xl">
      <div className="mx-auto flex max-w-6xl items-center justify-between gap-4 px-4 py-4">
        <Link href="/" className="flex items-center gap-3">
          <Logo />
        </Link>
        <nav className="hidden items-center gap-6 text-sm text-bit-muted md:flex">
          {links.map((l) => (
            <Link key={l.href} href={l.href} className="hover:text-sync-glow">
              {l.label}
            </Link>
          ))}
        </nav>
        <ConnectButton showBalance={false} chainStatus="icon" accountStatus="address" />
      </div>
    </header>
  );
}
