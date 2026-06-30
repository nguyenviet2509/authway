"use client";

import { DomainEntry } from "@/types";
import { cn } from "@/lib/utils";
import { CheckCircle2, Loader2, XCircle } from "lucide-react";

interface DomainResultsProps {
  domains: DomainEntry[];
}

const statusConfig: Record<
  string,
  { label: string; color: string; bg: string }
> = {
  pending: { label: "Chờ xử lý", color: "text-slate-600", bg: "bg-slate-100" },
  checking_dns: {
    label: "Đang kiểm tra DNS",
    color: "text-blue-700",
    bg: "bg-blue-50",
  },
  dns_done: { label: "DNS hợp lệ", color: "text-blue-700", bg: "bg-blue-50" },
  installing_cpanel: {
    label: "Đang xử lý AutoSSL",
    color: "text-amber-700",
    bg: "bg-amber-50",
  },
  cpanel_done: {
    label: "Chờ WHM Only",
    color: "text-amber-700",
    bg: "bg-amber-50",
  },
  installing_whm: {
    label: "Đang cài WHM",
    color: "text-violet-700",
    bg: "bg-violet-50",
  },
  success: { label: "Hoàn tất", color: "text-emerald-700", bg: "bg-emerald-50" },
  skipped: { label: "Bỏ qua", color: "text-slate-600", bg: "bg-slate-100" },
  error: { label: "Lỗi", color: "text-red-700", bg: "bg-red-50" },
};

const typeLabels: Record<DomainEntry["type"], string> = {
  main: "IP chính",
  addon: "IP riêng",
  unknown: "Chưa rõ",
};

export default function DomainResults({ domains }: DomainResultsProps) {
  if (domains.length === 0) {
    return null;
  }

  const successCount = domains.filter((domain) => domain.sslStatus === "success").length;
  const errorCount = domains.filter((domain) => domain.sslStatus === "error").length;

  return (
    <section className="panel overflow-hidden">
      <div className="results-head">
        <div>
          <h2 className="panel-heading">Kết quả xử lý</h2>
          <p className="panel-text">
            {domains.length} domain
            {successCount > 0 ? ` · ${successCount} hoàn tất` : ""}
            {errorCount > 0 ? ` · ${errorCount} lỗi` : ""}
          </p>
        </div>
      </div>

      <div className="overflow-x-auto">
        <table className="min-w-full divide-y divide-slate-100">
          <thead className="bg-slate-50/90">
            <tr>
              <th className="results-th">Domain</th>
              <th className="results-th">IP</th>
              <th className="results-th">Server</th>
              <th className="results-th">Phân loại</th>
              <th className="results-th">Trạng thái</th>
            </tr>
          </thead>
          <tbody className="divide-y divide-slate-100 bg-white">
            {domains.map((domain) => {
              const status = statusConfig[domain.sslStatus] || statusConfig.pending;
              const isLoading = [
                "checking_dns",
                "installing_cpanel",
                "installing_whm",
              ].includes(domain.sslStatus);

              return (
                <tr key={domain.id} className="transition-colors hover:bg-slate-50/70">
                  <td className="results-td">
                    <p className="font-mono text-[13px] text-slate-800">{domain.domain}</p>
                    {domain.cpanelUser && (
                      <p className="mt-1 text-[11px] text-slate-500">
                        user: <span className="font-mono">{domain.cpanelUser}</span>
                      </p>
                    )}
                  </td>
                  <td className="results-td">
                    <span className="font-mono text-[12px] text-slate-500">
                      {domain.resolvedIp || "--"}
                    </span>
                  </td>
                  <td className="results-td">
                    {domain.serverName ? (
                      <div>
                        <p className="text-sm font-medium text-slate-800">
                          {domain.serverName}
                        </p>
                        {domain.serverIp && (
                          <p className="mt-1 font-mono text-[11px] text-slate-500">
                            {domain.serverIp}
                          </p>
                        )}
                      </div>
                    ) : (
                      <span className="text-xs text-slate-400">Chưa nhận diện</span>
                    )}
                  </td>
                  <td className="results-td">
                    <span className="text-xs font-medium text-slate-600">
                      {typeLabels[domain.type]}
                    </span>
                  </td>
                  <td className="results-td">
                    <div className={cn("status-pill", status.bg, status.color)}>
                      {isLoading && <Loader2 className="h-3.5 w-3.5 animate-spin" />}
                      {domain.sslStatus === "success" && (
                        <CheckCircle2 className="h-3.5 w-3.5" />
                      )}
                      {domain.sslStatus === "error" && (
                        <XCircle className="h-3.5 w-3.5" />
                      )}
                      <span>{status.label}</span>
                    </div>
                    {domain.error && (
                      <p className="mt-2 max-w-[260px] text-xs leading-5 text-red-600">
                        {domain.error}
                      </p>
                    )}
                  </td>
                </tr>
              );
            })}
          </tbody>
        </table>
      </div>
    </section>
  );
}
