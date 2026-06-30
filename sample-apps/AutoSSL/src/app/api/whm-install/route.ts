import { NextRequest, NextResponse } from "next/server";
import { WHMApi } from "@/lib/whm-api";
import { getWhmToken, getServerById } from "@/lib/tokens";
import { detectServerForDomain } from "@/lib/server-detection";
import { incrementStats } from "@/lib/stats";

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
      logs.push(`[Detect] ${domain} thuộc ${server.name} (${server.ip})`);
    }

    const whm = new WHMApi(server.hostname, whmToken, server.whmUsername);

    logs.push(`[WHM] Đang lấy chứng chỉ cho ${domain}...`);
    const sslInfo = await whm.fetchSSLInfo(domain);

    if (!sslInfo?.data?.crt) {
      logs.push(`[WHM] Chưa tìm thấy chứng chỉ cho ${domain}`);
      return NextResponse.json({
        success: false,
        logs,
        serverId: server.id,
        serverName: server.name,
        serverIp: server.ip,
        error: "Chưa có chứng chỉ. Hãy chạy AutoSSL trước.",
      });
    }

    logs.push("[WHM] Đã có chứng chỉ. Đang cài lên WHM...");
    const installResult = await whm.installSSL(
      domain,
      sslInfo.data.crt,
      sslInfo.data.key,
      sslInfo.data.cab
    );

    if (installResult?.metadata?.result === 1) {
      logs.push(`[WHM] Cài SSL thành công cho ${domain}`);
      await incrementStats(server.id);
      return NextResponse.json({
        success: true,
        logs,
        serverId: server.id,
        serverName: server.name,
        serverIp: server.ip,
      });
    }

    const reason = installResult?.metadata?.reason || "Unknown error";
    logs.push(`[WHM] Cài thất bại: ${reason}`);
    return NextResponse.json({
      success: false,
      logs,
      serverId: server.id,
      serverName: server.name,
      serverIp: server.ip,
      error: reason,
    });
  } catch (err: any) {
    return NextResponse.json(
      { error: err.message || "Internal server error" },
      { status: 500 }
    );
  }
}
