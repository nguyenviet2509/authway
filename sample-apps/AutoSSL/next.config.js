/** @type {import('next').NextConfig} */
const nextConfig = {
  env: {
    ALLOWED_IPS: process.env.ALLOWED_IPS || "",
    ALLOWED_CIDRS: process.env.ALLOWED_CIDRS || "",
  },
};
module.exports = nextConfig;
