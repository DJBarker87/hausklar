import { defineConfig } from "@playwright/test";

export default defineConfig({
  testDir: "./e2e",
  outputDir: "./test-results",
  reporter: "line",
  fullyParallel: false,
  timeout: 45_000,
  use: {
    baseURL: process.env.E2E_BASE_URL ?? "http://127.0.0.1:8001",
    locale: "en-GB",
    timezoneId: "Europe/London",
    screenshot: "only-on-failure",
    trace: "retain-on-failure",
  },
  projects: [
    { name: "mobile", use: { viewport: { width: 375, height: 812 } } },
    { name: "tablet", use: { viewport: { width: 768, height: 1024 } } },
    { name: "desktop", use: { viewport: { width: 1280, height: 900 } } },
  ],
});
