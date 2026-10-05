export const NAV_LINKS = [
  { href: "/#presale", label: "Presale" },
  { href: "/#features", label: "Features" },
  { href: "/#tokenomics", label: "Tokenomics" },
  { href: "/#roadmap", label: "Roadmap" },
  { href: "/legal", label: "Legal" },
] as const;

export type MobileMenuState = { open: boolean };

export function openMobileMenu(state: MobileMenuState): MobileMenuState {
  return { open: true };
}

export function closeMobileMenu(_state: MobileMenuState): MobileMenuState {
  return { open: false };
}

export function toggleMobileMenu(state: MobileMenuState): MobileMenuState {
  return { open: !state.open };
}
