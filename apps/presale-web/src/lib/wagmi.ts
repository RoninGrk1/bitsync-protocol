"use client";

import { connectorsForWallets } from "@rainbow-me/rainbowkit";
import {
  metaMaskWallet,
  rainbowWallet,
  walletConnectWallet,
  injectedWallet,
} from "@rainbow-me/rainbowkit/wallets";
import { createConfig, http } from "wagmi";
import { activeChain, rpcUrl, walletConnectProjectId } from "./config";

const chain = activeChain();

const connectors = connectorsForWallets(
  [
    {
      groupName: "Recommended",
      wallets: [metaMaskWallet, rainbowWallet, walletConnectWallet, injectedWallet],
    },
  ],
  {
    appName: "BitSync Presale",
    projectId: walletConnectProjectId,
  },
);

export const config = createConfig({
  connectors,
  chains: [chain],
  transports: { [chain.id]: http(rpcUrl) },
  ssr: true,
});
