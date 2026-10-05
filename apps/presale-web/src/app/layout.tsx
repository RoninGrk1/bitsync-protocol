import type { Metadata } from "next";
import "./globals.css";
import { Providers } from "@/components/Providers";
import { Header } from "@/components/Header";
import { Footer } from "@/components/Footer";

export const metadata: Metadata = {
  metadataBase: new URL(process.env.NEXT_PUBLIC_SITE_URL || "http://localhost:3001"),
  title: "BitSync — The institutional oracle layer for Bitcoin",
  description: "Sync Bitcoin with the real world. BSY token presale.",
  openGraph: {
    title: "BitSync Presale",
    description: "The institutional oracle layer for Bitcoin.",
    images: ["/hero.jpg"],
  },
  icons: { icon: "/hero.jpg" },
};

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en">
      <body>
        <Providers>
          <Header />
          <main>{children}</main>
          <Footer />
        </Providers>
      </body>
    </html>
  );
}
