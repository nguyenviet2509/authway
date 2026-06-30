"use client";

import { useEffect, useRef } from "react";
import { LogEntry } from "@/types";
import { cn } from "@/lib/utils";
import { Trash2 } from "lucide-react";

interface LogPanelProps {
  logs: LogEntry[];
  onClear: () => void;
}

const levelClasses: Record<LogEntry["level"], string> = {
  info: "text-slate-600",
  success: "text-emerald-700",
  warning: "text-amber-700",
  error: "text-red-700",
};

export default function LogPanel({ logs, onClear }: LogPanelProps) {
  const containerRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    if (containerRef.current) {
      containerRef.current.scrollTop = containerRef.current.scrollHeight;
    }
  }, [logs]);

  return (
    <section className="panel overflow-hidden">
      <div className="results-head">
        <div>
          <h2 className="panel-heading">Nhật ký</h2>
          <p className="panel-text">{logs.length} dòng log</p>
        </div>
        <button
          type="button"
          onClick={onClear}
          className="inline-flex items-center gap-2 rounded-xl border border-slate-200 px-3 py-2 text-xs font-medium text-slate-500 transition-colors hover:bg-slate-50 hover:text-slate-700"
        >
          <Trash2 className="h-3.5 w-3.5" />
          Xóa log
        </button>
      </div>

      <div
        ref={containerRef}
        className="log-scroll max-h-[340px] min-h-[220px] overflow-y-auto bg-slate-50/80 px-5 py-4"
      >
        {logs.length === 0 ? (
          <div className="flex h-full min-h-[180px] items-center justify-center text-sm text-slate-400">
            Chưa có log.
          </div>
        ) : (
          <div className="space-y-2 font-mono text-[12px] leading-6">
            {logs.map((log) => (
              <div
                key={log.id}
                className="grid grid-cols-[68px,1fr] gap-3 rounded-xl px-2 py-1.5 transition-colors hover:bg-white"
              >
                <span className="text-slate-400">
                  {new Date(log.timestamp).toLocaleTimeString("vi-VN", {
                    hour: "2-digit",
                    minute: "2-digit",
                    second: "2-digit",
                  })}
                </span>
                <div className={cn("break-words", levelClasses[log.level])}>
                  {log.domain ? `[${log.domain}] ` : ""}
                  {log.message}
                </div>
              </div>
            ))}
          </div>
        )}
      </div>
    </section>
  );
}
