/**
 * cert-header-signer/server.ts — Sidecar that signs X-Client-Cert-CN header for Traefik.
 * Phase 06 Step 7 (Red Team Fix #3).
 *
 * Deployed as separate small container; Traefik forwardauth middleware calls
 *   http://cert-header-signer:8090/sign
 * on every request that passed strict-mtls TLS handshake.
 *
 * Input header from Traefik passTLSClientCert:
 *   X-Forwarded-Tls-Client-Cert-Info: Subject="CN=onemcp-backend,O=..."
 *
 * Output response headers (forwarded to backend by Traefik):
 *   X-Client-Cert-CN:      onemcp-backend
 *   X-Client-Cert-Sig:     hmac-sha256(secret, `${ts}.${cn}`)
 *   X-Client-Cert-Sig-Ts:  unix seconds
 *
 * Secret loaded from /run/secrets/cert_hmac at startup + on SIGHUP.
 * Reject if cert info header missing (Traefik didn't extract cert).
 */
import Fastify, { type FastifyRequest, type FastifyReply } from 'fastify';
import { createHmac } from 'node:crypto';
import { existsSync, readFileSync, watchFile } from 'node:fs';

const PORT = parseInt(process.env.PORT ?? '8090', 10);
const HMAC_SECRET_PATH = process.env.HMAC_SECRET_PATH ?? '/run/secrets/cert_hmac';

let hmacSecret = '';
function loadSecret(): void {
  if (!existsSync(HMAC_SECRET_PATH)) {
    console.error(`FATAL: HMAC secret not found at ${HMAC_SECRET_PATH}`);
    process.exit(1);
  }
  hmacSecret = readFileSync(HMAC_SECRET_PATH, 'utf8').trim();
  if (!hmacSecret) {
    console.error(`FATAL: HMAC secret at ${HMAC_SECRET_PATH} is empty`);
    process.exit(1);
  }
  console.log(`hmac secret loaded (${hmacSecret.length} chars)`);
}
loadSecret();
// Hot-reload secret on file change (docker secret rotation)
watchFile(HMAC_SECRET_PATH, { interval: 60_000 }, () => {
  console.log('secret file changed — reloading');
  loadSecret();
});

/**
 * Extract CN from Traefik passTLSClientCert Subject string.
 * Format: 'Subject="CN=onemcp-backend,O=OneLog,..."'
 * Or: 'Subject=CN=onemcp-backend' (older versions)
 */
function extractCN(subjectHeader: string | undefined): string | null {
  if (!subjectHeader) return null;
  // Strip Subject= prefix and quotes
  const raw = subjectHeader.replace(/^Subject=/i, '').replace(/^"/, '').replace(/"$/, '');
  const parts = raw.split(',').map((p) => p.trim());
  for (const p of parts) {
    const [k, ...rest] = p.split('=');
    if (k?.toUpperCase() === 'CN' && rest.length > 0) {
      return rest.join('=');
    }
  }
  return null;
}

const app = Fastify({ logger: true, disableRequestLogging: false });

app.get('/health', async () => ({ ok: true }));

app.all('/sign', async (req: FastifyRequest, reply: FastifyReply) => {
  const infoHeader = req.headers['x-forwarded-tls-client-cert-info'];
  const raw = Array.isArray(infoHeader) ? infoHeader[0] : infoHeader;
  const cn = extractCN(raw);

  if (!cn) {
    req.log.warn({ header: raw }, 'missing or unparseable X-Forwarded-Tls-Client-Cert-Info');
    // Return 401 — Traefik forwardauth will block downstream on non-2xx
    return reply.status(401).send({ error: 'no client cert' });
  }

  const ts = Math.floor(Date.now() / 1000).toString();
  const sig = createHmac('sha256', hmacSecret).update(`${ts}.${cn}`).digest('hex');

  return reply
    .header('X-Client-Cert-CN', cn)
    .header('X-Client-Cert-Sig', sig)
    .header('X-Client-Cert-Sig-Ts', ts)
    .status(200)
    .send({ ok: true, cn });
});

app.listen({ port: PORT, host: '0.0.0.0' }, (err, addr) => {
  if (err) {
    console.error(err);
    process.exit(1);
  }
  console.log(`cert-header-signer listening on ${addr}`);
});

// Graceful shutdown
process.on('SIGTERM', () => {
  console.log('SIGTERM — closing');
  void app.close().then(() => process.exit(0));
});
process.on('SIGINT', () => {
  console.log('SIGINT — closing');
  void app.close().then(() => process.exit(0));
});
