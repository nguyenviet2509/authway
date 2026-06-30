"use client";

import { Server } from "@/types";
import { cn } from "@/lib/utils";

interface ServerGridProps {
  servers: Server[];
  selectedServerId: number | null;
  onSelectServer: (server: Server) => void;
}

export default function ServerGrid({
  servers,
  selectedServerId,
  onSelectServer,
}: ServerGridProps) {
  return (
    <div className="grid gap-3 sm:grid-cols-2 xl:grid-cols-3">
      {servers.map((server) => {
        const isSelected = selectedServerId === server.id;

        return (
          <button
            key={server.id}
            type="button"
            onClick={() => onSelectServer(server)}
            className={cn(
              "rounded-2xl border px-4 py-3 text-left transition-colors",
              isSelected
                ? "border-blue-500 bg-blue-50"
                : "border-slate-200 bg-slate-50 hover:border-slate-300 hover:bg-white"
            )}
          >
            <div className="flex items-start justify-between gap-3">
              <div className="min-w-0">
                <p className="truncate text-sm font-semibold text-slate-900">
                  {server.name}
                </p>
                <p className="mt-1 text-xs text-slate-500">{server.ip}</p>
              </div>
              <span
                className={cn(
                  "mt-0.5 h-2.5 w-2.5 shrink-0 rounded-full",
                  isSelected ? "bg-blue-600" : "bg-slate-300"
                )}
              />
            </div>
          </button>
        );
      })}
    </div>
  );
}
