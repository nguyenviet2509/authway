import type { Metadata } from "next";
import "./globals.css";

export const metadata: Metadata = {
  title: "AutoSSL",
  description: "Quản lý AutoSSL gọn nhẹ cho SEO Hosting",
};

export default function RootLayout({
  children,
}: Readonly<{
  children: React.ReactNode;
}>) {
  return (
    <html lang="vi">
      <body>{children}</body>
    </html>
  );
}
