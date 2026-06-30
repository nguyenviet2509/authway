import { NextResponse } from "next/server";
import { getServerTokenStatus } from "@/lib/tokens";

export async function GET() {
  const status = getServerTokenStatus();
  return NextResponse.json({ tokens: status });
}
