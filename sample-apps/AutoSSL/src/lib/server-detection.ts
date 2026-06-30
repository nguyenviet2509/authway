import { servers } from "@/lib/servers";
import { getWhmToken } from "@/lib/tokens";
import { WHMApi } from "@/lib/whm-api";
import { Server } from "@/types";

export interface DetectedServer {
  server: Server;
  token: string;
  cpanelUser?: string;
  assignedIp?: string | null;
  matchType: "main_ip" | "domainuserdata" | "listaccts";
  lookupError?: string;
}

function getUserDataPayload(result: any) {
  return result?.data?.userdata || result?.userdata || null;
}

async function findByDomainUserData(
  domain: string,
  server: Server,
  token: string
): Promise<DetectedServer | null> {
  const whm = new WHMApi(server.hostname, token, server.whmUsername);
  const result = await whm.getDomainUserData(domain);
  const metadata = result?.metadata;
  const userdata = getUserDataPayload(result);

  if (metadata?.result === 0) {
    return null;
  }

  if (!userdata?.user) {
    return null;
  }

  return {
    server,
    token,
    cpanelUser: userdata.user,
    assignedIp: userdata.ip || null,
    matchType: "domainuserdata",
  };
}

async function findByListAccounts(
  domain: string,
  server: Server,
  token: string
): Promise<DetectedServer | null> {
  const whm = new WHMApi(server.hostname, token, server.whmUsername);
  const accounts = await whm.listAccounts();
  const match = accounts.find(
    (account: any) => account.domain?.toLowerCase() === domain.toLowerCase()
  );

  if (!match?.user) {
    return null;
  }

  return {
    server,
    token,
    cpanelUser: match.user,
    assignedIp: match.ip || null,
    matchType: "listaccts",
  };
}

export async function detectServerForDomain(
  domain: string,
  resolvedIp?: string | null
): Promise<DetectedServer | null> {
  if (resolvedIp) {
    const matchedMainIpServer = servers.find(
      (server) => server.ip === resolvedIp && getWhmToken(server.id)
    );

    if (matchedMainIpServer) {
      const token = getWhmToken(matchedMainIpServer.id);
      if (token) {
        return {
          server: matchedMainIpServer,
          token,
          assignedIp: resolvedIp,
          matchType: "main_ip",
        };
      }
    }
  }

  const serverPool = servers
    .map((server) => ({ server, token: getWhmToken(server.id) }))
    .filter(
      (item): item is { server: Server; token: string } => Boolean(item.token)
    );

  const domainUserDataResults = await Promise.allSettled(
    serverPool.map(({ server, token }) =>
      findByDomainUserData(domain, server, token)
    )
  );

  for (const result of domainUserDataResults) {
    if (result.status === "fulfilled" && result.value) {
      return result.value;
    }
  }

  const listAccountResults = await Promise.allSettled(
    serverPool.map(({ server, token }) => findByListAccounts(domain, server, token))
  );

  for (const result of listAccountResults) {
    if (result.status === "fulfilled" && result.value) {
      return result.value;
    }
  }

  return null;
}
