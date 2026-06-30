import { NextRequest, NextResponse } from "next/server";
import { WHMApi } from "@/lib/whm-api";
import { getWhmToken, getServerById } from "@/lib/tokens";
import { detectServerForDomain } from "@/lib/server-detection";
import { incrementStats } from "@/lib/stats";
import { issueCertViaACME } from "@/lib/acme-issuer";

async function lookupUsername(
  whm: WHMApi,
  domain: string,
  logs: string[]
): Promise<string> {
  try {
    const userData = await whm.getDomainUserData(domain);
    const userdata = userData?.data?.userdata || userData?.userdata;
    if (userdata?.user) {
      logs.push(`[Lookup] Tìm thấy username: ${userdata.user}`);
      return userdata.user;
    }
  } catch (err: any) {
    logs.push(`[Lookup] domainuserdata: ${err.message}`);
  }

  try {
    const accounts = await whm.listAccounts();
    const match = accounts.find(
      (account: any) => account.domain?.toLowerCase() === domain.toLowerCase()
    );
    if (match?.user) {
      logs.push(`[Lookup] Tìm thấy username: ${match.user}`);
      return match.user;
    }
  } catch (err: any) {
    logs.push(`[Lookup] listaccts: ${err.message}`);
  }

  return "";
}

export async function POST(request: NextRequest) {
  try {
    const body = await request.json();
    const domain = String(body?.domain || "").trim().toLowerCase();
    const serverId = body?.serverId ? Number(body.serverId) : null;
    const resolvedIp = body?.resolvedIp ? String(body.resolvedIp) : null;

    if (!domain) {
      return NextResponse.json(
        { error: "Thiếu domain" },
        { status: 400 }
      );
    }

    let server = serverId ? getServerById(serverId) : null;
    let whmToken = serverId ? getWhmToken(serverId) : null;
    let cpanelUsername = "";
    const logs: string[] = [];

    if (!server || !whmToken) {
      const detected = await detectServerForDomain(domain, resolvedIp);

      if (!detected) {
        return NextResponse.json({
          success: false,
          logs,
          error: `Không tự nhận diện được server cho domain "${domain}"`,
        });
      }

      server = detected.server;
      whmToken = detected.token;
      cpanelUsername = detected.cpanelUser || "";
      logs.push(`[Detect] ${domain} thuộc ${server.name} (${server.ip})`);
    }

    const whm = new WHMApi(server.hostname, whmToken, server.whmUsername);

    if (!cpanelUsername) {
      logs.push(`[Lookup] Đang tìm cPanel username cho ${domain}...`);
      cpanelUsername = await lookupUsername(whm, domain, logs);
    }

    if (!cpanelUsername) {
      return NextResponse.json({
        success: false,
        logs,
        serverId: server.id,
        serverName: server.name,
        serverIp: server.ip,
        error: `Không tìm thấy account cPanel của "${domain}"`,
      });
    }

    // Step 2: Check cert via WHM fetchsslinfo
    logs.push("[SSL] Đang kiểm tra chứng chỉ...");
    let crt = "", key = "", cab = "";

    const sslInfo = await whm.fetchSSLInfo(domain);
    if (sslInfo?.data?.crt && (sslInfo?.data?.cab || "").length > 100) {
      crt = sslInfo.data.crt;
      key = sslInfo.data.key;
      cab = sslInfo.data.cab;
      logs.push("[SSL] Tìm thấy cert trên WHM.");
    }

    // Step 2b: If no cert on WHM, check cPanel cert store via UAPI
    if (!crt) {
      logs.push("[SSL] Không thấy trên WHM, kiểm tra kho cPanel...");
      const bestCert = await whm.fetchBestCertForDomain(cpanelUsername, domain);
      if (bestCert?.crt && (bestCert.cab || "").length > 100) {
        crt = bestCert.crt;
        key = bestCert.key;
        cab = bestCert.cab;
        logs.push("[SSL] Tìm thấy cert trong kho cPanel.");
      }
    }

    // Step 3: If cert found → install on WHM
    if (crt && cab.length > 100) {
      logs.push("[WHM] Đang cài chứng chỉ lên WHM...");
      const installResult = await whm.installSSL(domain, crt, key, cab);

      if (installResult?.metadata?.result === 1) {
        logs.push("[WHM] Cài SSL thành công.");
        await incrementStats(server.id);
        return NextResponse.json({
          success: true,
          logs,
          serverId: server.id,
          serverName: server.name,
          serverIp: server.ip,
          cpanelUser: cpanelUsername,
        });
      }

      return NextResponse.json({
        success: false,
        logs,
        serverId: server.id,
        serverName: server.name,
        serverIp: server.ip,
        error: installResult?.metadata?.reason || "WHM install failed",
      });
    }

    // Step 4: No cert → Issue via ACME (Let's Encrypt) directly
    logs.push("[ACME] Chưa có cert. Đang tự issue Let's Encrypt...");
    try {
      const acmeCert = await issueCertViaACME(whm, cpanelUsername, domain, logs);

      if (acmeCert) {
        logs.push("[WHM] Đang cài chứng chỉ ACME lên WHM...");
        const installResult = await whm.installSSL(
          domain,
          acmeCert.crt,
          acmeCert.key,
          acmeCert.cab
        );

        if (installResult?.metadata?.result === 1) {
          logs.push("[WHM] Cài SSL thành công!");
          await incrementStats(server.id);
          return NextResponse.json({
            success: true,
            logs,
            serverId: server.id,
            serverName: server.name,
            serverIp: server.ip,
            cpanelUser: cpanelUsername,
          });
        }

        return NextResponse.json({
          success: false,
          logs,
          serverId: server.id,
          serverName: server.name,
          serverIp: server.ip,
          error: installResult?.metadata?.reason || "WHM install failed",
        });
      }
    } catch (acmeErr: any) {
      logs.push(`[ACME] Lỗi: ${acmeErr.message}`);
    }

    // Fallback: trigger AutoSSL if ACME failed
    logs.push("[AutoSSL] ACME thất bại. Kích hoạt AutoSSL...");
    try {
      await whm.cpanelUAPI(cpanelUsername, "SSL", "start_autossl_check");
      logs.push(`[AutoSSL] Đã kích hoạt cho ${cpanelUsername}`);
    } catch {
      try {
        await whm.startAutoSSL(cpanelUsername);
        logs.push("[AutoSSL] Đã kích hoạt qua WHM");
      } catch {
        logs.push("[AutoSSL] Không kích hoạt được");
      }
    }

    return NextResponse.json({
      success: false,
      pending: true,
      logs,
      serverId: server.id,
      serverName: server.name,
      serverIp: server.ip,
      cpanelUser: cpanelUsername,
      error: "ACME thất bại. AutoSSL đã kích hoạt, thử lại sau.",
    });
  } catch (err: any) {
    return NextResponse.json(
      { error: err.message || "Internal server error" },
      { status: 500 }
    );
  }
}
