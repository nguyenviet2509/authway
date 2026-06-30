import { NextRequest, NextResponse } from "next/server";
import dns from "dns";
import { promisify } from "util";
import { detectServerForDomain } from "@/lib/server-detection";

const resolve4 = promisify(dns.resolve4);

export async function POST(request: NextRequest) {
  try {
    const { domains } = await request.json();

    if (!domains || !Array.isArray(domains)) {
      return NextResponse.json(
        { error: "domains must be an array of strings" },
        { status: 400 }
      );
    }

    const results = await Promise.all(
      domains.map(async (rawDomain: string) => {
        const domain = String(rawDomain || "").trim().toLowerCase();

        let ip: string | null = null;
        let error: string | null = null;

        try {
          const addresses = await resolve4(domain);
          ip = addresses[0] || null;
        } catch (err: any) {
          error = err.code || err.message || "DNS resolution failed";
        }

        const detected = ip ? await detectServerForDomain(domain, ip) : null;

        return {
          domain,
          ip,
          error,
          onServer: !!detected,
          cpanelUser: detected?.cpanelUser || null,
          serverId: detected?.server.id || null,
          serverName: detected?.server.name || null,
          serverIp: detected?.server.ip || null,
          matchType: detected?.matchType || null,
          assignedIp: detected?.assignedIp || null,
        };
      })
    );

    return NextResponse.json({ results });
  } catch (err: any) {
    return NextResponse.json(
      { error: err.message || "Internal server error" },
      { status: 500 }
    );
  }
}
