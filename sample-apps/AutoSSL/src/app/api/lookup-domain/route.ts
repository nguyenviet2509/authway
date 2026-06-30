import { NextRequest, NextResponse } from "next/server";
import { getWhmToken, getServerById } from "@/lib/tokens";

export async function POST(request: NextRequest) {
  try {
    const body = await request.json();
    const { serverId, domain } = body;

    if (!serverId || !domain) {
      return NextResponse.json(
        { error: "Missing serverId or domain" },
        { status: 400 }
      );
    }

    const server = getServerById(serverId);
    if (!server) {
      return NextResponse.json(
        { error: `Server #${serverId} not found` },
        { status: 404 }
      );
    }

    const whmToken = getWhmToken(serverId);
    if (!whmToken) {
      return NextResponse.json(
        { error: `WHM token not configured for ${server.name}` },
        { status: 400 }
      );
    }

    // Use domainuserdata API — works for main, addon, subdomain, parked domains
    const whmUrl = `https://${server.hostname}:2087/json-api/domainuserdata?api.version=1&domain=${encodeURIComponent(domain)}`;
    
    const response = await fetch(whmUrl, {
      method: "GET",
      headers: {
        Authorization: `whm ${server.whmUsername}:${whmToken}`,
      },
      // @ts-ignore
      rejectUnauthorized: false,
    });

    if (!response.ok) {
      throw new Error(`WHM API error: ${response.status}`);
    }

    const data = await response.json();
    const userdata = data?.data?.userdata || data?.userdata;
    
    if (userdata && userdata.user) {
      return NextResponse.json({ 
        success: true, 
        username: userdata.user,
        domain: domain,
        ip: userdata.ip || null,
      });
    }

    return NextResponse.json(
      { error: `Domain "${domain}" not found on server ${server.name}` },
      { status: 404 }
    );

  } catch (err: any) {
    return NextResponse.json(
      { error: err.message || "Failed to lookup domain" },
      { status: 500 }
    );
  }
}
