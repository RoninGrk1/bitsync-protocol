"use client";

import Link from "next/link";
import { useEffect, useId, useState } from "react";
import { ConnectButton } from "@rainbow-me/rainbowkit";
import { Logo } from "./Logo";
import {
  NAV_LINKS,
  closeMobileMenu,
  toggleMobileMenu,
  type MobileMenuState,
} from "@/lib/nav";

export function Header() {
  const [menu, setMenu] = useState<MobileMenuState>({ open: false });
  const panelId = useId();

  useEffect(() => {
    if (!menu.open) return;
    const onKey = (e: KeyboardEvent) => {
      if (e.key === "Escape") setMenu(closeMobileMenu);
    };
    document.addEventListener("keydown", onKey);
    const prev = document.body.style.overflow;
    document.body.style.overflow = "hidden";
    return () => {
      document.removeEventListener("keydown", onKey);
      document.body.style.overflow = prev;
    };
  }, [menu.open]);

  function go(href: string) {
    setMenu(closeMobileMenu);
    // allow hash navigation after close
    if (href.startsWith("/#")) {
      const id = href.slice(2);
      requestAnimationFrame(() => {
        document.getElementById(id)?.scrollIntoView({ behavior: "smooth" });
      });
    }
  }

  return (
    <header className="sticky top-0 z-50 border-b border-white/5 bg-ink/90 backdrop-blur-xl pt-[env(safe-area-inset-top)]">
      <div className="mx-auto flex max-w-6xl items-center justify-between gap-3 px-4 py-3 sm:py-4">
        <Link href="/" className="flex min-h-[44px] min-w-[44px] items-center gap-3" onClick={() => setMenu(closeMobileMenu)}>
          <Logo className="text-xl sm:text-2xl" />
        </Link>

        <nav className="hidden items-center gap-6 text-sm text-bit-muted md:flex" aria-label="Primary">
          {NAV_LINKS.map((l) => (
            <Link key={l.href} href={l.href} className="hover:text-sync-glow">
              {l.label}
            </Link>
          ))}
        </nav>

        <div className="flex items-center gap-2">
          <div className="rk-connect shrink-0">
            <ConnectButton
              showBalance={false}
              chainStatus="icon"
              accountStatus={{
                smallScreen: "avatar",
                largeScreen: "full",
              }}
            />
          </div>

          <button
            type="button"
            className="inline-flex h-11 w-11 items-center justify-center rounded-xl border border-white/15 text-bit md:hidden"
            aria-label={menu.open ? "Close menu" : "Open menu"}
            aria-expanded={menu.open}
            aria-controls={panelId}
            data-testid="mobile-menu-button"
            onClick={() => setMenu((s) => toggleMobileMenu(s))}
          >
            <span className="sr-only">{menu.open ? "Close" : "Menu"}</span>
            {menu.open ? (
              <svg width="22" height="22" viewBox="0 0 24 24" fill="none" aria-hidden>
                <path d="M6 6l12 12M18 6L6 18" stroke="currentColor" strokeWidth="2" strokeLinecap="round" />
              </svg>
            ) : (
              <svg width="22" height="22" viewBox="0 0 24 24" fill="none" aria-hidden>
                <path d="M4 7h16M4 12h16M4 17h16" stroke="currentColor" strokeWidth="2" strokeLinecap="round" />
              </svg>
            )}
          </button>
        </div>
      </div>

      {/* Backdrop */}
      <div
        className={`fixed inset-0 z-40 bg-black/60 transition-opacity md:hidden ${
          menu.open ? "opacity-100" : "pointer-events-none opacity-0"
        }`}
        aria-hidden={!menu.open}
        onClick={() => setMenu(closeMobileMenu)}
      />

      {/* Slide-out panel */}
      <aside
        id={panelId}
        data-testid="mobile-menu-panel"
        data-open={menu.open ? "true" : "false"}
        className={`fixed right-0 top-0 z-50 flex h-[100dvh] w-[min(100%,20rem)] flex-col border-l border-white/10 bg-ink-soft pt-[env(safe-area-inset-top)] shadow-2xl transition-transform duration-200 ease-out md:hidden ${
          menu.open ? "translate-x-0" : "translate-x-full"
        }`}
        aria-hidden={!menu.open}
      >
        <div className="flex items-center justify-between border-b border-white/10 px-4 py-3">
          <Logo className="text-xl" />
          <button
            type="button"
            className="inline-flex h-11 w-11 items-center justify-center rounded-xl border border-white/15"
            aria-label="Close menu"
            onClick={() => setMenu(closeMobileMenu)}
          >
            <svg width="22" height="22" viewBox="0 0 24 24" fill="none" aria-hidden>
              <path d="M6 6l12 12M18 6L6 18" stroke="currentColor" strokeWidth="2" strokeLinecap="round" />
            </svg>
          </button>
        </div>

        <nav className="flex flex-1 flex-col gap-1 overflow-y-auto p-4" aria-label="Mobile">
          {NAV_LINKS.map((l) => (
            <Link
              key={l.href}
              href={l.href}
              className="flex min-h-[48px] items-center rounded-xl px-4 text-base font-medium text-bit hover:bg-white/5 hover:text-sync-glow"
              onClick={() => go(l.href)}
            >
              {l.label}
            </Link>
          ))}
        </nav>

        <div className="border-t border-white/10 p-4 pb-[max(1rem,env(safe-area-inset-bottom))]">
          <p className="mb-3 text-xs text-bit-muted">Connect a wallet to join the presale.</p>
          <div className="rk-connect flex justify-stretch [&_button]:min-h-[44px] [&_button]:w-full">
            <ConnectButton
              showBalance={false}
              chainStatus="full"
              accountStatus="full"
              label="Connect Wallet"
            />
          </div>
        </div>
      </aside>
    </header>
  );
}

// Re-export for tests / external use
export { closeMobileMenu, toggleMobileMenu, NAV_LINKS };
