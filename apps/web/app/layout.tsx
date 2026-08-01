import type { Metadata, Viewport } from "next";
import { Manrope } from "next/font/google";
import type { ReactNode } from "react";
import "./globals.css";
import { getSiteUrl, PRODUCT_NAME } from "./site";

const manrope = Manrope({
  subsets: ["latin"],
  variable: "--font-manrope",
  display: "swap",
});

const description =
  "A native macOS focus timer for choosing one task, committing to a timed block, and keeping a private local ledger.";

export const metadata: Metadata = {
  metadataBase: getSiteUrl(),
  title: {
    default: "Focus Tracker: Commit to the block",
    template: `%s | ${PRODUCT_NAME}`,
  },
  description,
  applicationName: PRODUCT_NAME,
  authors: [{ name: "Focus Tracker" }],
  creator: "Focus Tracker",
  publisher: "Focus Tracker",
  category: "productivity",
  keywords: [
    "focus timer",
    "macOS productivity",
    "local-first",
    "Apple Silicon",
    "time blocking",
  ],
  alternates: { canonical: "/" },
  openGraph: {
    type: "website",
    url: "/",
    siteName: PRODUCT_NAME,
    title: "Choose the work. Commit to the block.",
    description,
    images: [
      {
        url: "/opengraph-image",
        width: 1200,
        height: 630,
        alt: "Focus Tracker: Choose the work. Commit to the block.",
      },
    ],
  },
  twitter: {
    card: "summary_large_image",
    title: "Choose the work. Commit to the block.",
    description,
    images: ["/opengraph-image"],
  },
};

export const viewport: Viewport = {
  width: "device-width",
  initialScale: 1,
  themeColor: "#f2f1ec",
  colorScheme: "light",
};

export default function RootLayout({ children }: Readonly<{ children: ReactNode }>) {
  return (
    <html lang="en" className={manrope.variable}>
      <body>{children}</body>
    </html>
  );
}
