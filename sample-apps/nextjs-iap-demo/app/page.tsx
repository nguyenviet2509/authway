import { headers } from 'next/headers';

// Server component đọc identity từ X-Auth-Request-* headers do oauth2-proxy inject.
// KHÔNG bao giờ trust input từ client — strip-auth-in middleware đảm bảo Traefik xóa
// X-Auth-* từ inbound request trước khi forwardAuth gọi oauth2-proxy ghi đè.
export default function Home() {
  const h = headers();
  const email = h.get('x-auth-request-email') ?? '(missing)';
  const user = h.get('x-auth-request-user') ?? '(missing)';
  const preferred = h.get('x-auth-request-preferred-username') ?? '(missing)';

  return (
    <main>
      <h1>Authway IAP Demo — Next.js</h1>
      <p>App downstream KHÔNG có code OIDC. Identity propagate qua HTTP headers từ oauth2-proxy.</p>

      <h2>Identity</h2>
      <table style={{ borderCollapse: 'collapse' }}>
        <tbody>
          <tr><td style={{ padding: 6 }}><strong>Email</strong></td><td style={{ padding: 6 }}>{email}</td></tr>
          <tr><td style={{ padding: 6 }}><strong>Subject</strong></td><td style={{ padding: 6 }}>{user}</td></tr>
          <tr><td style={{ padding: 6 }}><strong>Preferred username</strong></td><td style={{ padding: 6 }}>{preferred}</td></tr>
        </tbody>
      </table>

      <h2>Try</h2>
      <ul>
        <li><a href="/whoami">/whoami</a> — JSON identity endpoint</li>
        <li><a href="/oauth2/sign_out">/oauth2/sign_out</a> — logout (then redirect Zitadel end_session)</li>
      </ul>
    </main>
  );
}
