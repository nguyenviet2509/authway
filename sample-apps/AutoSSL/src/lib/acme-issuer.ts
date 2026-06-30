import * as acme from "acme-client";
import { WHMApi } from "./whm-api";
import * as fs from "fs";
import * as path from "path";

const ACCOUNT_KEY_PATH = path.join(process.cwd(), "data", "acme-account.pem");

async function getOrCreateAccountKey(): Promise<Buffer> {
  try {
    return fs.readFileSync(ACCOUNT_KEY_PATH);
  } catch {
    const key = await acme.crypto.createPrivateKey();
    fs.mkdirSync(path.dirname(ACCOUNT_KEY_PATH), { recursive: true });
    fs.writeFileSync(ACCOUNT_KEY_PATH, key);
    return key;
  }
}

export async function issueCertViaACME(
  whm: WHMApi,
  cpanelUser: string,
  domain: string,
  logs: string[]
): Promise<{ crt: string; key: string; cab: string } | null> {
  // Step 1: Get document root
  const ud = await whm.getDomainUserData(domain);
  const udata = ud?.data?.userdata || ud?.userdata;
  const documentRoot = udata?.documentroot;
  const homeDir = udata?.homedir || `/home/${cpanelUser}`;

  if (!documentRoot) {
    logs.push("[ACME] Không lấy được document root");
    return null;
  }

  const relDocRoot = documentRoot.replace(homeDir + "/", "");
  logs.push(`[ACME] Document root: ${relDocRoot}`);

  // Step 2: Create ACME client
  const accountKey = await getOrCreateAccountKey();
  const client = new acme.Client({
    directoryUrl: acme.directory.letsencrypt.production,
    accountKey,
  });

  await client.createAccount({
    termsOfServiceAgreed: true,
    contact: ["mailto:autossl@trungtq.io.vn"],
  });

  // Step 3: Create order
  logs.push("[ACME] Tạo yêu cầu chứng chỉ...");
  const order = await client.createOrder({
    identifiers: [{ type: "dns", value: domain }],
  });

  const authorizations = await client.getAuthorizations(order);
  const auth = authorizations[0];
  const challenge = auth.challenges.find(
    (c: any) => c.type === "http-01"
  );

  if (!challenge) {
    logs.push("[ACME] Không tìm thấy HTTP-01 challenge");
    return null;
  }

  const keyAuthorization = await client.getChallengeKeyAuthorization(challenge);
  const challengeDir = `${relDocRoot}/.well-known/acme-challenge`;

  // Step 4: Write challenge file via cPanel Fileman
  logs.push("[ACME] Đặt file xác thực...");
  try {
    await whm.cpanelUAPI(cpanelUser, "Fileman", "save_file_content", {
      dir: challengeDir,
      file: challenge.token,
      content: keyAuthorization,
    });
  } catch (err: any) {
    logs.push(`[ACME] Lỗi ghi file: ${err.message}`);
    return null;
  }

  // Step 5: Complete and verify challenge
  logs.push("[ACME] Đang xác thực domain với Let's Encrypt...");
  try {
    await client.completeChallenge(challenge);
    await client.waitForValidStatus(challenge);
  } catch (err: any) {
    logs.push(`[ACME] Xác thực thất bại: ${err.message}`);
    // Clean up
    try {
      await whm.cpanelUAPI(cpanelUser, "Fileman", "save_file_content", {
        dir: challengeDir,
        file: challenge.token,
        content: "",
      });
    } catch {}
    return null;
  }

  // Step 6: Generate CSR and finalize
  logs.push("[ACME] Tạo chứng chỉ...");
  const [csrKey, csr] = await acme.crypto.createCsr({
    commonName: domain,
  });

  await client.finalizeOrder(order, csr);
  const cert = await client.getCertificate(order);

  // Step 7: Split cert chain
  const certs = cert.split(/(?=-----BEGIN CERTIFICATE-----)/);
  const mainCert = certs[0]?.trim() || "";
  const chainCerts = certs.slice(1).map((c: string) => c.trim()).join("\n");

  // Clean up challenge file
  try {
    await whm.cpanelUAPI(cpanelUser, "Fileman", "save_file_content", {
      dir: challengeDir,
      file: challenge.token,
      content: "",
    });
  } catch {}

  logs.push("[ACME] Chứng chỉ Let's Encrypt đã tạo thành công!");
  return {
    crt: mainCert,
    key: csrKey.toString().trim(),
    cab: chainCerts,
  };
}
