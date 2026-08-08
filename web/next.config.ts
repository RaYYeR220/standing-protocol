import type { NextConfig } from "next";

const nextConfig: NextConfig = {
  reactStrictMode: true,
  // This app is self-contained; pin tracing here so a lockfile further up the tree
  // is not mistaken for the workspace root.
  outputFileTracingRoot: import.meta.dirname,
  webpack: (config) => {
    // Optional peer deps pulled in by the wallet connector stack; not used in the browser build.
    config.externals.push("pino-pretty", "lokijs", "encoding");
    return config;
  },
};

export default nextConfig;
