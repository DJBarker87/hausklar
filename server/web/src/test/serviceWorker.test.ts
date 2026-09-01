import { describe, expect, it, vi } from "vitest";

import serviceWorkerSource from "../../public/sw.js?raw";

type WorkerHandler = (event: {
  request?: { method: string; mode: string; url: string };
  respondWith?: (response: Promise<Response>) => void;
  waitUntil?: (work: Promise<unknown>) => void;
}) => void;

class MemoryCache {
  readonly entries = new Map<string, Response>();

  private key(input: string | { url: string }) {
    return new URL(typeof input === "string" ? input : input.url, "https://hausklar.test").href;
  }

  async addAll(paths: string[]) {
    paths.forEach((path) => this.entries.set(this.key(path), new Response("cached")));
  }

  async put(input: string | { url: string }, response: Response) {
    this.entries.set(this.key(input), response);
  }

  async match(input: string | { url: string }) {
    return this.entries.get(this.key(input));
  }
}

function workerHarness(fetcher: typeof fetch = vi.fn<typeof fetch>()) {
  const source = serviceWorkerSource;
  const handlers = new Map<string, WorkerHandler>();
  const stores = new Map<string, MemoryCache>();
  const cacheStorage = {
    open: async (name: string) => {
      const existing = stores.get(name);
      if (existing) return existing;
      const created = new MemoryCache();
      stores.set(name, created);
      return created;
    },
    keys: async () => [...stores.keys()],
    delete: async (name: string) => stores.delete(name),
    match: async (input: string | { url: string }) => {
      for (const cache of stores.values()) {
        const response = await cache.match(input);
        if (response) return response;
      }
      return undefined;
    },
  };
  const worker = {
    __PRECACHE_MANIFEST: [] as string[],
    __BUILD_ID: "test-build",
    location: { origin: "https://hausklar.test" },
    clients: {
      claim: vi.fn(async () => undefined),
      matchAll: vi.fn(async () => []),
      openWindow: vi.fn(async () => undefined),
    },
    registration: { showNotification: vi.fn(async () => undefined) },
    addEventListener: (name: string, handler: WorkerHandler) => handlers.set(name, handler),
  };
  const evaluate = new Function("self", "caches", "fetch", "setTimeout", "URL", source);
  evaluate(worker, cacheStorage, fetcher, setTimeout, URL);
  return { cacheStorage, handlers, source, stores };
}

describe("service worker", () => {
  it("serves the static shell for an offline Finance navigation without intercepting Finance APIs", async () => {
    const fetcher = vi.fn<typeof fetch>().mockRejectedValue(new TypeError("offline"));
    const { cacheStorage, handlers } = workerHarness(fetcher);
    const shell = await cacheStorage.open("hausklar-shell-test-build");
    await shell.put("/", new Response("HausKlar shell"));
    let navigation: Promise<Response> | null = null;

    handlers.get("fetch")?.({
      request: { method: "GET", mode: "navigate", url: "https://hausklar.test/?view=finance&section=plan" },
      respondWith: (response) => { navigation = response; },
    });

    expect(navigation).not.toBeNull();
    await expect(navigation!).resolves.toEqual(expect.any(Response));
    expect(await (await navigation!).text()).toBe("HausKlar shell");

    const financeApiResponse = vi.fn();
    handlers.get("fetch")?.({
      request: { method: "GET", mode: "cors", url: "https://hausklar.test/api/finance/accounts" },
      respondWith: financeApiResponse,
    });
    expect(financeApiResponse).not.toHaveBeenCalled();
  });

  it("keeps two previous builds' caches and does not replace an open tab mid-deploy", async () => {
    const { cacheStorage, handlers, source, stores } = workerHarness();
    for (const name of [
      "hausklar-shell-old-a", "hausklar-runtime-old-a",
      "hausklar-shell-old-b", "hausklar-runtime-old-b",
      "hausklar-shell-old-c", "hausklar-runtime-old-c",
      "unrelated-cache",
    ]) await cacheStorage.open(name);
    let activation: Promise<unknown> | null = null;

    handlers.get("activate")?.({ waitUntil: (work) => { activation = work; } });
    await activation;

    expect([...stores.keys()]).toEqual(expect.arrayContaining([
      "hausklar-shell-old-b", "hausklar-runtime-old-b",
      "hausklar-shell-old-c", "hausklar-runtime-old-c",
      "unrelated-cache",
    ]));
    expect(stores.has("hausklar-shell-old-a")).toBe(false);
    expect(stores.has("hausklar-runtime-old-a")).toBe(false);
    expect(source).not.toContain("skipWaiting");
  });
});
