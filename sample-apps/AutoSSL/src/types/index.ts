export interface Server {
  id: number;
  name: string;
  hostname: string;
  ip: string;
  whmUsername: string;
}

export interface DomainEntry {
  id: string;
  domain: string;
  resolvedIp: string | null;
  serverId: number | null;
  serverName?: string;
  serverIp?: string;
  type: "main" | "addon" | "unknown";
  sslStatus:
    | "pending"
    | "checking_dns"
    | "dns_done"
    | "installing_cpanel"
    | "cpanel_done"
    | "installing_whm"
    | "success"
    | "skipped"
    | "error";
  cpanelUser?: string;
  logs: string[];
  error?: string;
}

export interface LogEntry {
  id: string;
  timestamp: Date;
  level: "info" | "success" | "warning" | "error";
  message: string;
  domain?: string;
}

export interface ServerCredentials {
  whmToken: string;
}

export interface InstallSSLRequest {
  serverHostname: string;
  serverIp: string;
  whmToken: string;
  cpanelUsername: string;
  domain: string;
  type: "main" | "addon";
}

export interface CheckDNSRequest {
  domains: string[];
}

export interface CheckDNSResult {
  domain: string;
  ip: string | null;
  error?: string;
}
