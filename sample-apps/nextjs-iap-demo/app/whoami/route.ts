import { headers } from 'next/headers';
import { NextResponse } from 'next/server';

export const dynamic = 'force-dynamic';

export function GET() {
  const h = headers();
  return NextResponse.json({
    email: h.get('x-auth-request-email'),
    sub: h.get('x-auth-request-user'),
    preferred_username: h.get('x-auth-request-preferred-username'),
    groups: h.get('x-auth-request-groups'),
  });
}
