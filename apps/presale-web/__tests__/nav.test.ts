import { describe, it, expect } from "vitest";
import {
  NAV_LINKS,
  closeMobileMenu,
  openMobileMenu,
  toggleMobileMenu,
} from "../src/lib/nav";

describe("responsive nav helpers", () => {
  it("exposes the primary mobile/desktop links", () => {
    const labels = NAV_LINKS.map((l) => l.label);
    expect(labels).toEqual(["Presale", "Features", "Tokenomics", "Roadmap", "Legal"]);
    expect(NAV_LINKS.every((l) => l.href.startsWith("/") || l.href.startsWith("/#"))).toBe(true);
  });

  it("toggles, opens, and closes the mobile menu state", () => {
    let state = { open: false };
    state = toggleMobileMenu(state);
    expect(state.open).toBe(true);
    state = toggleMobileMenu(state);
    expect(state.open).toBe(false);
    state = openMobileMenu(state);
    expect(state.open).toBe(true);
    state = closeMobileMenu(state);
    expect(state.open).toBe(false);
  });
});
