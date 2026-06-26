export const metadata = { title: 'Authway IAP Demo — Next.js' };

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en">
      <body style={{ fontFamily: 'system-ui, sans-serif', maxWidth: 720, margin: '40px auto', padding: 16 }}>
        {children}
      </body>
    </html>
  );
}
