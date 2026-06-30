import { servers } from "./servers";
import fs from "fs";
import path from "path";

/**
 * WHM API tokens stored server-side in .env.local file.
 * Read directly from file at runtime to avoid Next.js build-time env inlining.
 */

let tokenCache: Record<string, string> | null = null;
let cacheTime = 0;

function loadTokens(): Record<string, string> {
  const now = Date.now();
  // Cache for 10 seconds
  if (tokenCache && now - cacheTime < 10000) {
    return tokenCache;
  }

  const tokens: Record<string, string> = {};
  try {
    const envPath = path.join(process.cwd(), ".env.local");
    const content = fs.readFileSync(envPath, "utf8");
    for (const line of content.split("\n")) {
      const trimmed = line.trim();
      if (!trimmed || trimmed.startsWith("#")) continue;
      const idx = trimmed.indexOf("=");
      if (idx > 0 && trimmed.startsWith("WHM_TOKEN_")) {
        tokens[trimmed.substring(0, idx)] = trimmed.substring(idx + 1);
      }
    }
  } catch (e) {
    // File not found or read error
  }

  tokenCache = tokens;
  cacheTime = now;
  return tokens;
}

export function getWhmToken(serverId: number): string | null {
  const tokens = loadTokens();
  return tokens[`WHM_TOKEN_${serverId}`] || null;
}

export function getServerById(serverId: number) {
  return servers.find((s) => s.id === serverId) || null;
}

export function getServerTokenStatus(): Record<number, boolean> {
  const status: Record<number, boolean> = {};
  for (const server of servers) {
    status[server.id] = !!getWhmToken(server.id);
  }
  return status;
}
