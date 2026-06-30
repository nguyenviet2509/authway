"use client";

import { useCallback, useMemo, useState } from "react";
import { DomainEntry, LogEntry } from "@/types";
import { generateId } from "@/lib/utils";
import DomainResults from "@/components/DomainResults";
import LogPanel from "@/components/LogPanel";
import {
  Globe,
  Loader2,
  Search,
  ShieldCheck,
  Sparkles,
  Zap,
  WandSparkles,
} from "lucide-react";

const CF_PREFIXES = [
  "104.16.",
  "104.17.",
  "104.18.",
  "104.19.",
  "104.20.",
  "104.21.",
  "104.22.",
  "104.23.",
  "104.24.",
  "104.25.",
  "104.26.",
  "104.27.",
  "172.64.",
  "172.65.",
  "172.66.",
  "172.67.",
  "173.245.",
  "103.21.",
  "103.22.",
  "103.31.",
  "141.101.",
  "108.162.",
  "190.93.",
  "188.114.",
  "197.234.",
  "198.41.",
];

const MAX_LOGS = 250;

function createDomainEntry(domain: string, existing?: DomainEntry): DomainEntry {
  if (existing) {
    return existing;
  }

  return {
    id: generateId(),
    domain,
    resolvedIp: null,
    serverId: null,
    type: "unknown",
    sslStatus: "pending",
    logs: [],
  };
}

export default function HomePage() {
  const [domainText, setDomainText] = useState("");
  const [domains, setDomains] = useState<DomainEntry[]>([]);
  const [logs, setLogs] = useState<LogEntry[]>([]);
  const [isCheckingDNS, setIsCheckingDNS] = useState(false);
  const [isInstalling, setIsInstalling] = useState(false);

  const addLog = useCallback(
    (level: LogEntry["level"], message: string, domain?: string) => {
      setLogs((prev) => {
        const next = [
          ...prev,
          {
            id: generateId(),
            timestamp: new Date(),
            level,
            message,
            domain,
          },
        ];

        return next.slice(-MAX_LOGS);
      });
    },
    []
  );

  const parsedDomains = useMemo(
    () =>
      domainText
        .split("\n")
        .map((item) => item.trim().toLowerCase())
        .filter((item, index, array) => item && array.indexOf(item) === index),
    [domainText]
  );

  const buildEntries = (sourceDomains: string[]) => {
    const currentMap = new Map(
      domains.map((item) => [item.domain.toLowerCase(), item])
    );

    return sourceDomains.map((domain) =>
      createDomainEntry(domain, currentMap.get(domain.toLowerCase()))
    );
  };

  const updateDomain = (
    targetDomain: string,
    updater: (entry: DomainEntry) => DomainEntry
  ) => {
    setDomains((prev) =>
      prev.map((entry) =>
        entry.domain === targetDomain ? updater(entry) : entry
      )
    );
  };

  const handleCheckDNS = async () => {
    if (parsedDomains.length === 0) {
      addLog("warning", "Vui lòng nhập ít nhất 1 domain.");
      return;
    }

    const nextEntries = buildEntries(parsedDomains);
    setDomains(nextEntries);
    setIsCheckingDNS(true);
    addLog("info", `Đang kiểm tra DNS cho ${parsedDomains.length} domain...`);

    try {
      const response = await fetch("/api/check-dns", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ domains: parsedDomains }),
      });

      const data = await response.json();
      const resultMap = new Map<string, any>(
        (data.results || []).map((item: any) => [item.domain.toLowerCase(), item])
      );

      const updatedEntries = nextEntries.map((entry) => {
        const result = resultMap.get(entry.domain.toLowerCase());
        if (!result) {
          return entry;
        }

        const ip = result.ip || null;
        const isCloudflare = ip
          ? CF_PREFIXES.some((prefix) => ip.startsWith(prefix))
          : false;
        const isMainIp = Boolean(ip && result.serverIp && ip === result.serverIp);

        let type: DomainEntry["type"] = "unknown";
        let sslStatus: DomainEntry["sslStatus"] = "error";
        let error: string | undefined;

        if (isCloudflare) {
          error =
            "Domain đang dùng Proxy. Cần tắt Proxy ở bản ghi @ trước khi cài SSL.";
          addLog("warning", error, entry.domain);
        } else if (!ip) {
          const dnsError = result.error || "Không phân giải được DNS.";
          error = dnsError;
          addLog("error", dnsError, entry.domain);
        } else if (result.onServer) {
          type = isMainIp ? "main" : "addon";
          sslStatus = isMainIp ? "skipped" : "dns_done";
          addLog(
            "info",
            `${ip} → ${result.serverName || "Đã nhận diện server"}${
              result.cpanelUser ? ` · user: ${result.cpanelUser}` : ""
            }`,
            entry.domain
          );
        } else {
          error = "Không tự nhận diện được server chứa domain này.";
          addLog("warning", error, entry.domain);
        }

        return {
          ...entry,
          resolvedIp: ip,
          serverId: result.serverId || null,
          serverName: result.serverName || undefined,
          serverIp: result.serverIp || undefined,
          cpanelUser: result.cpanelUser || undefined,
          type,
          sslStatus,
          error,
        };
      });

      setDomains(updatedEntries);
    } catch (error: any) {
      addLog("error", `Kiểm tra DNS thất bại: ${error.message}`);
      setDomains((prev) =>
        prev.map((entry) => ({
          ...entry,
          sslStatus: "error",
          error: error.message,
        }))
      );
    } finally {
      setIsCheckingDNS(false);
      addLog("info", "Kiểm tra DNS hoàn tất.");
    }
  };

  const handleInstallSSL = async () => {
    if (parsedDomains.length === 0) {
      addLog("warning", "Vui lòng nhập ít nhất 1 domain.");
      return;
    }

    const nextEntries = buildEntries(parsedDomains);
    setDomains(nextEntries);
    setIsInstalling(true);
    addLog("info", `Bắt đầu cài SSL cho ${parsedDomains.length} domain...`);

    for (const entry of nextEntries) {
      updateDomain(entry.domain, (current) => ({
        ...current,
        sslStatus: "installing_cpanel",
        error: undefined,
      }));

      try {
        const response = await fetch("/api/install-ssl", {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({
            domain: entry.domain,
            resolvedIp: entry.resolvedIp,
            serverId: entry.serverId,
          }),
        });

        const data = await response.json();

        if (data.logs) {
          data.logs.forEach((log: string) => addLog("info", log, entry.domain));
        }

        if (data.success) {
          updateDomain(entry.domain, (current) => ({
            ...current,
            serverId: data.serverId || current.serverId,
            serverName: data.serverName || current.serverName,
            serverIp: data.serverIp || current.serverIp,
            cpanelUser: data.cpanelUser || current.cpanelUser,
            sslStatus: "success",
            error: undefined,
          }));
          addLog("success", "Cài SSL thành công.", entry.domain);
          continue;
        }

        if (data.pending) {
          updateDomain(entry.domain, (current) => ({
            ...current,
            serverId: data.serverId || current.serverId,
            serverName: data.serverName || current.serverName,
            serverIp: data.serverIp || current.serverIp,
            cpanelUser: data.cpanelUser || current.cpanelUser,
            sslStatus: "cpanel_done",
            error: data.error,
          }));
          addLog("warning", "AutoSSL đã kích hoạt. Tự động thử lại sau 15s...", entry.domain);

          // Auto-retry: poll every 15s, max 8 attempts (2 min)
          let retryCount = 0;
          const maxRetries = 8;
          const retryLoop = async () => {
            while (retryCount < maxRetries) {
              await new Promise((r) => setTimeout(r, 15000));
              retryCount++;
              addLog("info", `[Retry ${retryCount}/${maxRetries}] Thử cài lại...`, entry.domain);
              try {
                const retryResp = await fetch("/api/install-ssl", {
                  method: "POST",
                  headers: { "Content-Type": "application/json" },
                  body: JSON.stringify({
                    domain: entry.domain,
                    resolvedIp: entry.resolvedIp,
                    serverId: data.serverId || entry.serverId,
                  }),
                });
                const retryData = await retryResp.json();
                if (retryData.logs) {
                  retryData.logs.forEach((log: string) => addLog("info", log, entry.domain));
                }
                if (retryData.success) {
                  updateDomain(entry.domain, (current) => ({
                    ...current,
                    sslStatus: "success",
                    error: undefined,
                  }));
                  addLog("success", "Cài SSL thành công!", entry.domain);
                  return;
                }
                if (!retryData.pending) {
                  updateDomain(entry.domain, (current) => ({
                    ...current,
                    sslStatus: "error",
                    error: retryData.error,
                  }));
                  addLog("error", retryData.error || "Cài thất bại.", entry.domain);
                  return;
                }
              } catch {
                addLog("error", `Retry ${retryCount} lỗi kết nối.`, entry.domain);
              }
            }
            addLog("warning", "Hết lượt retry. Hãy thử WHM Only thủ công.", entry.domain);
          };
          // Run retry loop in background (don't block other domains)
          retryLoop();
          continue;
        }

        updateDomain(entry.domain, (current) => ({
          ...current,
          serverId: data.serverId || current.serverId,
          serverName: data.serverName || current.serverName,
          serverIp: data.serverIp || current.serverIp,
          cpanelUser: data.cpanelUser || current.cpanelUser,
          sslStatus: "error",
          error: data.error,
        }));
        addLog("error", data.error || "Cài SSL thất bại.", entry.domain);
      } catch (error: any) {
        updateDomain(entry.domain, (current) => ({
          ...current,
          sslStatus: "error",
          error: error.message,
        }));
        addLog("error", error.message, entry.domain);
      }
    }

    setIsInstalling(false);
    addLog("success", "Hoàn tất lượt cài SSL.");
  };

  const handleInstallWHMOnly = async () => {
    if (parsedDomains.length === 0) {
      addLog("warning", "Vui lòng nhập ít nhất 1 domain.");
      return;
    }

    const nextEntries = buildEntries(parsedDomains);
    setDomains(nextEntries);
    setIsInstalling(true);
    addLog("info", `Bắt đầu chạy WHM Only cho ${parsedDomains.length} domain...`);

    for (const entry of nextEntries) {
      updateDomain(entry.domain, (current) => ({
        ...current,
        sslStatus: "installing_whm",
        error: undefined,
      }));

      try {
        const response = await fetch("/api/whm-install", {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({
            domain: entry.domain,
            resolvedIp: entry.resolvedIp,
            serverId: entry.serverId,
          }),
        });

        const data = await response.json();

        if (data.logs) {
          data.logs.forEach((log: string) => addLog("info", log, entry.domain));
        }

        if (data.success) {
          updateDomain(entry.domain, (current) => ({
            ...current,
            serverId: data.serverId || current.serverId,
            serverName: data.serverName || current.serverName,
            serverIp: data.serverIp || current.serverIp,
            sslStatus: "success",
            error: undefined,
          }));
          addLog("success", "WHM Only hoàn tất.", entry.domain);
        } else {
          updateDomain(entry.domain, (current) => ({
            ...current,
            serverId: data.serverId || current.serverId,
            serverName: data.serverName || current.serverName,
            serverIp: data.serverIp || current.serverIp,
            sslStatus: "error",
            error: data.error,
          }));
          addLog("error", data.error || "WHM Only thất bại.", entry.domain);
        }
      } catch (error: any) {
        updateDomain(entry.domain, (current) => ({
          ...current,
          sslStatus: "error",
          error: error.message,
        }));
        addLog("error", error.message, entry.domain);
      }
    }

    setIsInstalling(false);
    addLog("success", "Hoàn tất lượt WHM Only.");
  };

  const successCount = domains.filter((entry) => entry.sslStatus === "success").length;
  const processingCount = domains.filter((entry) =>
    ["checking_dns", "installing_cpanel", "installing_whm"].includes(
      entry.sslStatus
    )
  ).length;

  return (
    <main className="shell">
      <section className="hero-panel mb-6">
        <div className="hero-copy">
          <div className="hero-icon">
            <ShieldCheck className="h-5 w-5" />
          </div>
          <div>
            <p className="hero-eyebrow">AutoSSL Manager</p>
            <h1 className="hero-title">Tự nhận diện server, cài SSL gọn và rõ ràng</h1>
            <p className="hero-subtitle">
              Chỉ cần nhập domain. Hệ thống sẽ dò server tương ứng, kiểm tra DNS
              và xử lý luồng AutoSSL theo đúng tài khoản.
            </p>
          </div>
        </div>

        <div className="hero-stats">
          <div className="hero-stat">
            <span className="hero-stat-label">Đã nhập</span>
            <strong className="hero-stat-value">{parsedDomains.length}</strong>
          </div>
          <div className="hero-stat">
            <span className="hero-stat-label">Hoàn tất</span>
            <strong className="hero-stat-value">{successCount}</strong>
          </div>
          <div className="hero-stat">
            <span className="hero-stat-label">Đang xử lý</span>
            <strong className="hero-stat-value">{processingCount}</strong>
          </div>
        </div>
      </section>

      <div className="grid gap-6 xl:grid-cols-[420px,minmax(0,1fr)]">
        <section className="panel panel-form p-6">
          <div className="mb-5 flex items-start justify-between gap-4">
            <div>
              <h2 className="panel-heading">Danh sách domain</h2>
              <p className="panel-text">
                Mỗi dòng một domain. Không cần chọn server thủ công.
              </p>
            </div>
            <div className="panel-chip">
              <WandSparkles className="h-3.5 w-3.5" />
              Tự nhận diện
            </div>
          </div>

          <textarea
            value={domainText}
            onChange={(event) => setDomainText(event.target.value)}
            rows={13}
            placeholder={"example.com\nshop.com\nlandingpage.net"}
            className="field field-large resize-y font-mono text-[13px]"
          />

          <div className="mt-4 grid grid-cols-2 gap-3">
            <div className="panel-soft px-4 py-3">
              <p className="metric-label">Domain</p>
              <p className="metric-value">{parsedDomains.length}</p>
            </div>
            <div className="panel-soft px-4 py-3">
              <p className="metric-label">Thành công</p>
              <p className="metric-value">{successCount}</p>
            </div>
          </div>

          <div className="mt-4 space-y-3">
            <div className="warn-note">
              Không áp dụng cho domain đang dùng Proxy. Cần tắt Proxy ở bản ghi
              @ trước khi cài SSL.
            </div>
            <div className="muted-note">
              Nếu account owner là <span className="font-mono">root</span>,
              reseller token có thể không nhìn thấy domain dù site nằm trên cùng
              server.
            </div>
          </div>

          <div className="mt-5 grid gap-3 sm:grid-cols-3 xl:grid-cols-1">
            <button
              type="button"
              onClick={handleCheckDNS}
              disabled={parsedDomains.length === 0 || isCheckingDNS || isInstalling}
              className="action-btn-secondary"
            >
              {isCheckingDNS ? (
                <Loader2 className="h-4 w-4 animate-spin" />
              ) : (
                <Search className="h-4 w-4" />
              )}
              Check DNS
            </button>

            <button
              type="button"
              onClick={handleInstallSSL}
              disabled={parsedDomains.length === 0 || isCheckingDNS || isInstalling}
              className="action-btn-primary"
            >
              {isInstalling ? (
                <Loader2 className="h-4 w-4 animate-spin" />
              ) : (
                <Sparkles className="h-4 w-4" />
              )}
              Cài SSL
            </button>

            <button
              type="button"
              onClick={handleInstallWHMOnly}
              disabled={parsedDomains.length === 0 || isCheckingDNS || isInstalling}
              className="action-btn-warning"
            >
              {isInstalling ? (
                <Loader2 className="h-4 w-4 animate-spin" />
              ) : (
                <Zap className="h-4 w-4" />
              )}
              WHM Only
            </button>
          </div>
        </section>

        <section className="space-y-6">
          {domains.length > 0 ? (
            <DomainResults domains={domains} />
          ) : (
            <div className="empty-box">
              <div>
                <div className="empty-icon">
                  <Globe className="h-5 w-5" />
                </div>
                <h2 className="text-base font-semibold text-slate-900">
                  Chưa có dữ liệu
                </h2>
                <p className="mt-2 text-sm leading-6 text-slate-500">
                  Nhập domain rồi bấm Check DNS hoặc Cài SSL để bắt đầu.
                </p>
              </div>
            </div>
          )}

          <LogPanel logs={logs} onClear={() => setLogs([])} />
        </section>
      </div>
    </main>
  );
}
