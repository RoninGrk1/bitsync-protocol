import { describe, it, expect } from "vitest";
import { PRESALE_ALLOCATION } from "@bitsync/sdk";
import { formatBsyGrouped, withThousands } from "../src/lib/format";

describe("grouped BSY labels", () => {
  it("formats the 6.3M progress cap with thousands separators", () => {
    expect(formatBsyGrouped(PRESALE_ALLOCATION)).toBe("6,300,000 BSY");
  });

  it("groups integer digit strings", () => {
    expect(withThousands("6300000")).toBe("6,300,000");
    expect(withThousands("42")).toBe("42");
  });
});
