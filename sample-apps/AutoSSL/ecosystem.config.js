const fs = require("fs");
const path = require("path");

// Load .env.local and merge into env
const envPath = path.join("/var/www/autossl", ".env.local");
const envVars = { NODE_ENV: "production", PORT: 3000 };
try {
  const content = fs.readFileSync(envPath, "utf8");
  content.split("\n").forEach((line) => {
    line = line.trim();
    if (!line || line.startsWith("#")) return;
    const idx = line.indexOf("=");
    if (idx > 0) {
      envVars[line.substring(0, idx)] = line.substring(idx + 1);
    }
  });
} catch (e) {}

module.exports = {
  apps: [
    {
      name: "autossl",
      script: "node_modules/.bin/next",
      args: "start -p 3000",
      cwd: "/var/www/autossl",
      instances: 1,
      autorestart: true,
      watch: false,
      max_memory_restart: "512M",
      env: envVars,
    },
  ],
};
