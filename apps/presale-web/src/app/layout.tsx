import type { Metadata, Viewport } from "next";
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
  appleWebApp: {
    capable: true,
    statusBarStyle: "black-translucent",
    title: "BitSync",
  },
};

export const viewport: Viewport = {
  width: "device-width",
  initialScale: 1,
  maximumScale: 5,
  viewportFit: "cover",
  themeColor: "#050816",
};

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en">
      <body className="antialiased">
        <Providers>
          <Header />
          <main className="min-w-0 overflow-x-hidden">{children}</main>
          <Footer />
        </Providers>
      </body>
    </html>
  );
}
