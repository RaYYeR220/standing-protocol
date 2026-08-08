import type { Metadata, Viewport } from "next";
import { Archivo, IBM_Plex_Mono } from "next/font/google";
import "./globals.css";
import { Providers } from "./providers";
import { Rail } from "@/components/Rail";
import { Nav } from "@/components/Nav";
import { SubjectBar } from "@/components/SubjectBar";
import { Footer } from "@/components/Footer";

const archivo = Archivo({
  subsets: ["latin"],
  variable: "--font-archivo",
  display: "swap",
  weight: ["400", "500", "600", "700"],
});

const plexMono = IBM_Plex_Mono({
  subsets: ["latin"],
  variable: "--font-plex-mono",
  display: "swap",
  weight: ["400", "500", "600"],
});

export const metadata: Metadata = {
  title: "Standing Protocol — Underwriting Terminal",
  description:
    "Under-collateralized credit on Monad testnet and Base Sepolia, underwritten against a Cleanverse A-Pass and gated on-chain before every movement of value.",
};

export const viewport: Viewport = {
  themeColor: "#0A0D12",
  colorScheme: "dark",
};

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en" className={`${archivo.variable} ${plexMono.variable}`}>
      <body>
        <Providers>
          <div className="relative z-10 flex min-h-screen flex-col">
            <Rail />
            <Nav />
            <SubjectBar />
            <main className="mx-auto w-full max-w-[1680px] flex-1 px-4 py-5 lg:px-6">
              {children}
            </main>
            <Footer />
          </div>
        </Providers>
      </body>
    </html>
  );
}
