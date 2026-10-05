"use client";

import { useCallback, useEffect, useMemo, useState } from "react";
import { useAccount, usePublicClient, useWalletClient } from "wagmi";
import { parseEther, type Hex } from "viem";
import {
  PresaleClient,
  PRESALE_ALLOCATION,
  SUGGESTED_PRICE_USD_PER_BSY,
  offlineQuoteBsy,
  formatUsd,
  parseUsd,
  USD_SCALE,
} from "@bitsync/sdk";
import { formatBsy } from "@bitsync/sdk";
import { addresses } from "@/lib/config";

type Pay = "ETH" | "USDC" | "USDT";

export function PresaleWidget() {
  const { address, isConnected } = useAccount();
  const publicClient = usePublicClient();
  const { data: walletClient } = useWalletClient();
  const [pay, setPay] = useState<Pay>("ETH");
  const [amount, setAmount] = useState("0.1");
  const [acked, setAcked] = useState(false);
  const [status, setStatus] = useState<{
    totalSold: bigint;
    remaining: bigint;
    saleActive: boolean;
    end: bigint;
    priceUsdPerBsy: bigint;
    progressBps: number;
  } | null>(null);
  const [purchase, setPurchase] = useState<{
    bsyAllocated: bigint;
    claimable: bigint;
  } | null>(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [tx, setTx] = useState<string | null>(null);

  const client = useMemo(() => {
    if (!publicClient || addresses.presale === "0x0000000000000000000000000000000000000000") {
      return null;
    }
    return new PresaleClient({
      publicClient,
      presaleAddress: addresses.presale,
      usdcAddress: addresses.usdc,
      usdtAddress: addresses.usdt,
    });
  }, [publicClient]);

  const refresh = useCallback(async () => {
    if (!client) return;
    try {
      const s = await client.getStatus();
      setStatus({
        totalSold: s.totalSold,
        remaining: s.remaining,
        saleActive: s.saleActive,
        end: s.end,
        priceUsdPerBsy: s.priceUsdPerBsy,
        progressBps: s.progressBps,
      });
      if (address) {
        const p = await client.getPurchase(address);
        setPurchase({ bsyAllocated: p.bsyAllocated, claimable: p.claimable });
      }
    } catch (e) {
      console.warn(e);
    }
  }, [client, address]);

  useEffect(() => {
    refresh();
    const id = setInterval(refresh, 12_000);
    return () => clearInterval(id);
  }, [refresh]);

  const quote = useMemo(() => {
    const price = status?.priceUsdPerBsy ?? SUGGESTED_PRICE_USD_PER_BSY;
    if (pay === "ETH") {
      try {
        const eth = parseEther(amount || "0");
        // Offline approx at $2000/ETH for display before RPC quote
        const usd = (eth * 2000n * USD_SCALE) / 10n ** 18n;
        const bsy = offlineQuoteBsy(usd, price);
        return { bsy, label: `${formatBsy(bsy)} (est.)` };
      } catch {
        return { bsy: 0n, label: "—" };
      }
    }
    try {
      const usd = parseUsd(amount || "0");
      const bsy = offlineQuoteBsy(usd, price);
      return { bsy, label: formatBsy(bsy) };
    } catch {
      return { bsy: 0n, label: "—" };
    }
  }, [amount, pay, status]);

  const countdown = useMemo(() => {
    if (!status) return "—";
    const end = Number(status.end) * 1000;
    const ms = Math.max(0, end - Date.now());
    const d = Math.floor(ms / 86400000);
    const h = Math.floor((ms % 86400000) / 3600000);
    return `${d}d ${h}h`;
  }, [status]);

  async function onBuy() {
    setError(null);
    setTx(null);
    if (!acked) {
      setError("Please acknowledge the risk disclosure before purchasing.");
      return;
    }
    if (!isConnected || !walletClient || !address || !client) {
      setError("Connect a wallet and ensure contracts are configured in .env.local.");
      return;
    }
    // Geo gate via API
    const geo = await fetch("/api/compliance/check").then((r) => r.json());
    if (geo.blocked) {
      setError(`Purchases are not available in your jurisdiction (${geo.country || "unknown"}).`);
      return;
    }
    setBusy(true);
    try {
      let kyc = {
        sig: "0x" as Hex,
        deadline: 0n,
        jurisdictionHash:
          "0x0000000000000000000000000000000000000000000000000000000000000000" as Hex,
      };
      if (geo.kycRequired) {
        const signed = await fetch("/api/compliance/kyc", {
          method: "POST",
          headers: { "content-type": "application/json" },
          body: JSON.stringify({ buyer: address, country: geo.country }),
        }).then((r) => r.json());
        if (!signed.ok) throw new Error(signed.error || "KYC signer unavailable");
        kyc = {
          sig: signed.signature,
          deadline: BigInt(signed.deadline),
          jurisdictionHash: signed.jurisdictionHash,
        };
      }
      let hash: Hex;
      if (pay === "ETH") {
        const ethWei = parseEther(amount || "0");
        hash = await client.buyWithEth(walletClient, address, ethWei, quote.bsy > 0n ? (quote.bsy * 99n) / 100n : 0n, kyc);
      } else {
        const token = pay === "USDC" ? addresses.usdc : addresses.usdt;
        // amount is USD; convert to 6-dec stable
        const usd = parseUsd(amount || "0");
        const stableAmt = usd / 100n; // 1e8 -> 1e6
        hash = await client.buyWithStable(
          walletClient,
          address,
          token,
          stableAmt,
          quote.bsy > 0n ? (quote.bsy * 99n) / 100n : 0n,
          kyc,
        );
      }
      setTx(hash);
      await refresh();
    } catch (e: unknown) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setBusy(false);
    }
  }

  async function onClaim() {
    if (!walletClient || !address || !client) return;
    setBusy(true);
    setError(null);
    try {
      const hash = await client.claim(walletClient, address);
      setTx(hash);
      await refresh();
    } catch (e: unknown) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setBusy(false);
    }
  }

  const progress = status ? Math.min(100, status.progressBps / 100) : 0;
  const sold = status ? formatBsy(status.totalSold) : "—";
  const priceLabel = status
    ? formatUsd(status.priceUsdPerBsy)
    : formatUsd(SUGGESTED_PRICE_USD_PER_BSY);

  return (
    <div className="glass p-6 shadow-[0_0_60px_rgba(30,144,255,0.15)]" id="presale">
      <div className="mb-4 flex items-start justify-between gap-4">
        <div>
          <h2 className="text-xl font-semibold">BSY Presale</h2>
          <p className="text-sm text-bit-muted">
            6.3M BSY (15%) · suggested {priceLabel} / BSY · hard cap ~$1.26M
          </p>
        </div>
        <div className="rounded-lg bg-sync/15 px-3 py-1 text-xs font-medium text-sync-glow">
          Ends in {countdown}
        </div>
      </div>

      <div className="mb-4">
        <div className="mb-1 flex justify-between text-xs text-bit-muted">
          <span>{sold} sold</span>
          <span>{formatBsy(PRESALE_ALLOCATION)} cap</span>
        </div>
        <div className="h-2 overflow-hidden rounded-full bg-white/10">
          <div className="h-full rounded-full bg-gradient-to-r from-sync-deep to-sync-glow" style={{ width: `${progress}%` }} />
        </div>
      </div>

      <div className="mb-3 flex gap-2">
        {(["ETH", "USDC", "USDT"] as Pay[]).map((p) => (
          <button
            key={p}
            type="button"
            onClick={() => setPay(p)}
            className={`rounded-lg px-3 py-1.5 text-sm ${pay === p ? "bg-sync text-white" : "bg-white/5 text-bit-muted"}`}
          >
            {p}
          </button>
        ))}
      </div>

      <label className="mb-1 block text-xs text-bit-muted">
        Amount ({pay === "ETH" ? "ETH" : "USD"})
      </label>
      <input
        className="mb-3 w-full rounded-xl border border-white/10 bg-ink-soft px-4 py-3 outline-none focus:border-sync"
        value={amount}
        onChange={(e) => setAmount(e.target.value)}
        inputMode="decimal"
        aria-label="Purchase amount"
      />

      <div className="mb-4 rounded-xl bg-white/5 px-4 py-3 text-sm">
        <div className="flex justify-between">
          <span className="text-bit-muted">You receive</span>
          <span className="font-medium text-sync-glow">{quote.label}</span>
        </div>
        <div className="mt-1 flex justify-between text-xs text-bit-muted">
          <span>Your allocation</span>
          <span>{purchase ? formatBsy(purchase.bsyAllocated) : "—"}</span>
        </div>
        <div className="mt-1 flex justify-between text-xs text-bit-muted">
          <span>Claimable</span>
          <span>{purchase ? formatBsy(purchase.claimable) : "—"}</span>
        </div>
      </div>

      <label className="mb-4 flex items-start gap-2 text-xs text-bit-muted">
        <input
          type="checkbox"
          className="mt-0.5"
          checked={acked}
          onChange={(e) => setAcked(e.target.checked)}
        />
        <span>
          I have read the{" "}
          <a className="text-sync-glow underline" href="/legal">
            terms &amp; risk disclosure
          </a>
          , understand this is not financial advice, and that the software is{" "}
          <strong>unaudited</strong>.
        </span>
      </label>

      <div className="flex flex-col gap-2 sm:flex-row">
        <button type="button" className="btn-primary flex-1" disabled={busy || !acked} onClick={onBuy}>
          {busy ? "Confirm in wallet…" : isConnected ? `Buy with ${pay}` : "Connect wallet to buy"}
        </button>
        <button
          type="button"
          className="btn-ghost"
          disabled={busy || !purchase || purchase.claimable === 0n}
          onClick={onClaim}
        >
          Claim
        </button>
      </div>

      {error && <p className="mt-3 text-sm text-red-400" role="alert">{error}</p>}
      {tx && (
        <p className="mt-3 break-all text-xs text-bit-muted">
          Tx: {tx}
        </p>
      )}
      {!client && (
        <p className="mt-3 text-xs text-amber-300">
          Contracts not configured — run the local demo script or set addresses in{" "}
          <code>.env.local</code>. Offline quotes still use the suggested $0.20 price.
        </p>
      )}
    </div>
  );
}
