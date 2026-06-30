import fs from "fs";
import path from "path";

const STATS_DIR = path.join(process.cwd(), "data");
const STATS_FILE = path.join(STATS_DIR, "stats.json");

interface Stats {
  totalInstalls: number;
  byServer: Record<number, number>;
  lastInstall: string | null;
  history: Array<{ date: string; count: number }>;
}

function defaultStats(): Stats {
  return {
    totalInstalls: 0,
    byServer: {},
    lastInstall: null,
    history: [],
  };
}

export function getStats(): Stats {
  try {
    if (fs.existsSync(STATS_FILE)) {
      return JSON.parse(fs.readFileSync(STATS_FILE, "utf8"));
    }
  } catch {}
  return defaultStats();
}

function saveStats(stats: Stats): void {
  try {
    if (!fs.existsSync(STATS_DIR)) {
      fs.mkdirSync(STATS_DIR, { recursive: true });
    }
    fs.writeFileSync(STATS_FILE, JSON.stringify(stats, null, 2));
  } catch {}
}

export async function incrementStats(serverId: number): Promise<Stats> {
  const stats = getStats();
  stats.totalInstalls++;
  stats.byServer[serverId] = (stats.byServer[serverId] || 0) + 1;
  stats.lastInstall = new Date().toISOString();

  // Update daily history
  const today = new Date().toISOString().split("T")[0];
  const todayEntry = stats.history.find((h) => h.date === today);
  if (todayEntry) {
    todayEntry.count++;
  } else {
    stats.history.push({ date: today, count: 1 });
    // Keep last 90 days
    if (stats.history.length > 90) {
      stats.history = stats.history.slice(-90);
    }
  }

  saveStats(stats);
  return stats;
}
