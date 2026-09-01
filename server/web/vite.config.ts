import tailwindcss from "@tailwindcss/vite";
import react from "@vitejs/plugin-react";
import { createHash } from "node:crypto";
import { readFileSync, writeFileSync } from "node:fs";
import { resolve } from "node:path";
import { defineConfig, type Plugin } from "vite";

// Replaces the `self.__PRECACHE_MANIFEST` placeholder in public/sw.js with the
// entry assets referenced by index.html. Route chunks stay truly lazy and are
// cached on first use by the service worker instead of downloading at install.
function injectServiceWorkerManifest(): Plugin {
  let outDir = "dist";
  return {
    name: "inject-sw-precache-manifest",
    apply: "build",
    configResolved(config) {
      outDir = resolve(config.root, config.build.outDir);
    },
    closeBundle() {
      const index = readFileSync(resolve(outDir, "index.html"), "utf8");
      const assets = Array.from(
        index.matchAll(/(?:src|href)="(\/assets\/[^"]+)"/g),
        (match) => match[1],
      );
      const buildID = createHash("sha256").update(assets.slice().sort().join("\n")).digest("hex").slice(0, 12);
      const swPath = resolve(outDir, "sw.js");
      const source = readFileSync(swPath, "utf8");
      writeFileSync(
        swPath,
        source
          .replace("self.__PRECACHE_MANIFEST", JSON.stringify(assets))
          .replace("self.__BUILD_ID", JSON.stringify(buildID)),
      );
    },
  };
}

export default defineConfig({
  plugins: [react(), tailwindcss(), injectServiceWorkerManifest()],
  server: {
    port: 4173,
    proxy: {
      "/api": "http://127.0.0.1:8001",
    },
  },
  build: {
    manifest: true,
    sourcemap: false,
  },
});
