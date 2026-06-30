import { NextRequest, NextResponse } from "next/server";

const ALLOWED_IPS = (process.env.ALLOWED_IPS || "")
  .split(",")
  .map((ip) => ip.trim())
  .filter(Boolean);

const ALLOWED_CIDRS = (process.env.ALLOWED_CIDRS || "")
  .split(",")
  .map((cidr) => cidr.trim())
  .filter(Boolean);

function ipToLong(ip: string): number {
  return ip
    .split(".")
    .reduce((acc, octet) => (acc << 8) + parseInt(octet, 10), 0) >>> 0;
}

function cidrMatch(ip: string, cidr: string): boolean {
  const [network, bits] = cidr.split("/");
  const mask = ~(2 ** (32 - parseInt(bits, 10)) - 1) >>> 0;
  return (ipToLong(ip) & mask) === (ipToLong(network) & mask);
}

function getClientIp(request: NextRequest): string {
  const forwarded = request.headers.get("x-forwarded-for");
  if (forwarded) {
    return forwarded.split(",")[0].trim();
  }
  const realIp = request.headers.get("x-real-ip");
  if (realIp) {
    return realIp.trim();
  }
  return "unknown";
}

function isAllowed(ip: string): boolean {
  if (ALLOWED_IPS.length === 0 && ALLOWED_CIDRS.length === 0) {
    return true;
  }

  // Normalize IPv6-mapped IPv4 (::ffff:127.0.0.1 → 127.0.0.1)
  const normalizedIp = ip.startsWith("::ffff:") ? ip.slice(7) : ip;

  if (normalizedIp === "127.0.0.1" || normalizedIp === "::1" || normalizedIp === "localhost") {
    return true;
  }

  if (ALLOWED_IPS.includes(normalizedIp)) {
    return true;
  }

  for (const cidr of ALLOWED_CIDRS) {
    if (cidrMatch(ip, cidr)) {
      return true;
    }
  }

  return false;
}

export function middleware(request: NextRequest) {
  const clientIp = getClientIp(request);

  if (!isAllowed(clientIp)) {
    return new NextResponse(
      JSON.stringify({
        error: "Access denied",
        message: "IP của bạn không được phép truy cập.",
        ip: clientIp,
      }),
      {
        status: 403,
        headers: { "Content-Type": "application/json" },
      }
    );
  }

  return NextResponse.next();
}

export const config = {
  matcher: ["/((?!_next/static|_next/image|favicon.ico).*)"],
};
