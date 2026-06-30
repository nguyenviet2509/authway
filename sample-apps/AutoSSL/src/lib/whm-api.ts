interface WHMResponse {
  metadata?: {
    version: number;
    reason: string;
    result: number;
    command: string;
  };
  data?: any;
  [key: string]: any;
}

export class WHMApi {
  private baseUrl: string;
  private token: string;
  private username: string;

  constructor(hostname: string, token: string, username: string = "root") {
    this.baseUrl = `https://${hostname}:2087`;
    this.token = token;
    this.username = username;
  }

  private async request(
    endpoint: string,
    method: "GET" | "POST" = "GET",
    body?: Record<string, string>,
    params?: Record<string, string>
  ): Promise<WHMResponse> {
    const query = new URLSearchParams({ "api.version": "1", ...params });
    const url = `${this.baseUrl}/json-api/${endpoint}?${query.toString()}`;
    const headers: Record<string, string> = {
      Authorization: `whm ${this.username}:${this.token}`,
    };

    const options: RequestInit = {
      method,
      headers,
      // @ts-ignore - Node.js specific option for self-signed certs
      rejectUnauthorized: false,
    };

    if (method === "POST" && body) {
      headers["Content-Type"] = "application/x-www-form-urlencoded";
      options.body = new URLSearchParams(body).toString();
    }

    const response = await fetch(url, options);
    if (!response.ok) {
      throw new Error(`WHM API error: ${response.status} ${response.statusText}`);
    }
    return response.json();
  }

  async listAccounts(): Promise<any> {
    const result = await this.request("listaccts");
    return result?.data?.acct || result?.acct || [];
  }

  async getDomainUserData(domain: string): Promise<any> {
    return this.request("domainuserdata", "GET", undefined, { domain });
  }

  async listIps(): Promise<string[]> {
    const ips: string[] = [];
    // Try listips first (root only)
    try {
      const result = await this.request("listips");
      const list = result?.data?.ip || result?.result || [];
      for (const entry of list) {
        if (entry.ip) ips.push(entry.ip);
      }
      if (ips.length > 0) return ips;
    } catch {}
    // Fallback: collect IPs from listaccts (reseller-safe)
    try {
      const accounts = await this.listAccounts();
      for (const acct of accounts) {
        if (acct.ip && !ips.includes(acct.ip)) ips.push(acct.ip);
      }
    } catch {}
    return ips;
  }

  async startAutoSSL(username?: string): Promise<WHMResponse> {
    const body: Record<string, string> = {};
    if (username) {
      body.username = username;
    }
    return this.request("start_autossl_check_for_one_provider", "POST", body);
  }

  async fetchSSLInfo(domain: string): Promise<WHMResponse> {
    return this.request("fetchsslinfo", "GET", undefined, { domain });
  }

  async installSSL(
    domain: string,
    crt: string,
    key: string,
    cab?: string
  ): Promise<WHMResponse> {
    const body: Record<string, string> = {
      domain,
      crt,
      key,
    };
    if (cab) {
      body.cab = cab;
    }
    return this.request("installssl", "POST", body);
  }

  async accountSummary(domain: string): Promise<WHMResponse> {
    return this.request("accountsummary", "GET", undefined, { domain });
  }

  async cpanelUAPI(cpanelUser: string, module: string, func: string, args?: Record<string, string>): Promise<any> {
    const params: Record<string, string> = {
      cpanel_jsonapi_user: cpanelUser,
      cpanel_jsonapi_apiversion: "3",
      cpanel_jsonapi_module: module,
      cpanel_jsonapi_func: func,
      ...(args || {}),
    };
    const query = new URLSearchParams(params);
    const url = `${this.baseUrl}/json-api/cpanel?${query.toString()}`;
    const response = await fetch(url, {
      method: "GET",
      headers: { Authorization: `whm ${this.username}:${this.token}` },
      // @ts-ignore
      rejectUnauthorized: false,
    });
    if (!response.ok) {
      throw new Error(`cPanel UAPI error: ${response.status}`);
    }
    return response.json();
  }

  async fetchBestCertForDomain(cpanelUser: string, domain: string): Promise<{
    crt: string;
    key: string;
    cab: string;
  } | null> {
    try {
      const result = await this.cpanelUAPI(cpanelUser, "SSL", "fetch_best_for_domain", { domain });
      const data = result?.result?.data;
      if (data?.crt) {
        return {
          crt: data.crt,
          key: data.key || "",
          cab: data.cab || "",
        };
      }
      return null;
    } catch {
      return null;
    }
  }

  async getSSLCertForDomain(domain: string): Promise<{
    crt: string;
    key: string;
    cab: string;
  } | null> {
    try {
      const result = await this.fetchSSLInfo(domain);
      if (result?.data?.crt) {
        return {
          crt: result.data.crt,
          key: result.data.key || "",
          cab: result.data.cab || "",
        };
      }
      return null;
    } catch {
      return null;
    }
  }
}

export class CPanelApi {
  private baseUrl: string;
  private token: string;
  private username: string;

  constructor(hostname: string, whmToken: string, username: string) {
    this.baseUrl = `https://${hostname}:2087`;
    this.token = whmToken;
    this.username = username;
  }

  private async request(
    module: string,
    func: string,
    params?: Record<string, string>
  ): Promise<any> {
    const queryParams = new URLSearchParams({
      cpanel_jsonapi_user: this.username,
      cpanel_jsonapi_apiversion: "3",
      cpanel_jsonapi_module: module,
      cpanel_jsonapi_func: func,
      ...(params || {}),
    });

    const url = `${this.baseUrl}/json-api/cpanel?${queryParams.toString()}`;
    const response = await fetch(url, {
      method: "GET",
      headers: {
        Authorization: `whm root:${this.token}`,
      },
      // @ts-ignore
      rejectUnauthorized: false,
    });

    if (!response.ok) {
      throw new Error(
        `cPanel API error: ${response.status} ${response.statusText}`
      );
    }
    return response.json();
  }

  async getInstalledSSL(): Promise<any> {
    return this.request("SSL", "installed_hosts");
  }

  async installSSL(
    domain: string,
    crt: string,
    key: string,
    cab?: string
  ): Promise<any> {
    const params: Record<string, string> = {
      domain,
      cert: crt,
      key,
    };
    if (cab) {
      params.cabundle = cab;
    }
    return this.request("SSL", "install_ssl", params);
  }
}
