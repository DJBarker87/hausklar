import { afterEach, describe, expect, it, vi } from "vitest";

import { installAuthIdentity } from "../api";
import { revokeCurrentBrowserPushSubscription } from "../pushSubscriptions";

function deferred<T>() {
  let resolve!: (value: T | PromiseLike<T>) => void;
  const promise = new Promise<T>((resolvePromise) => { resolve = resolvePromise; });
  return { promise, resolve };
}

describe("browser push subscription ownership", () => {
  const originalServiceWorker = Object.getOwnPropertyDescriptor(navigator, "serviceWorker");

  afterEach(() => {
    vi.restoreAllMocks();
    if (originalServiceWorker) Object.defineProperty(navigator, "serviceWorker", originalServiceWorker);
    else Reflect.deleteProperty(navigator, "serviceWorker");
  });

  it("does not let a delayed explicit disable issue A's cleanup under B", async () => {
    const ready = deferred<ServiceWorkerRegistration>();
    const unsubscribe = vi.fn().mockResolvedValue(true);
    const registration = {
      pushManager: {
        getSubscription: vi.fn().mockResolvedValue({
          endpoint: "https://push.example/browser-a",
          unsubscribe,
        }),
      },
    } as unknown as ServiceWorkerRegistration;
    Object.defineProperty(navigator, "serviceWorker", {
      configurable: true,
      value: { ready: ready.promise },
    });
    const fetchMock = vi.fn<typeof fetch>();
    vi.stubGlobal("fetch", fetchMock);
    installAuthIdentity({ id: "user-a", family_id: "family-a" });

    const cleanup = revokeCurrentBrowserPushSubscription();
    installAuthIdentity({ id: "user-b", family_id: "family-b" });
    ready.resolve(registration);
    await cleanup;

    expect(fetchMock).not.toHaveBeenCalled();
    expect(registration.pushManager.getSubscription).not.toHaveBeenCalled();
    expect(unsubscribe).not.toHaveBeenCalled();
  });

  it("does not let A's delayed server cleanup unsubscribe or close B's browser state", async () => {
    const serverRemoval = deferred<Response>();
    const unsubscribe = vi.fn().mockResolvedValue(true);
    const close = vi.fn();
    const registration = {
      pushManager: {
        getSubscription: vi.fn().mockResolvedValue({
          endpoint: "https://push.example/browser-a",
          unsubscribe,
        }),
      },
      getNotifications: vi.fn().mockResolvedValue([{ tag: "hausklar-task", close }]),
    } as unknown as ServiceWorkerRegistration;
    Object.defineProperty(navigator, "serviceWorker", {
      configurable: true,
      value: { ready: Promise.resolve(registration) },
    });
    const fetchMock = vi.fn<typeof fetch>().mockReturnValue(serverRemoval.promise);
    vi.stubGlobal("fetch", fetchMock);
    installAuthIdentity({ id: "user-a", family_id: "family-a" });

    const cleanup = revokeCurrentBrowserPushSubscription();
    await vi.waitFor(() => expect(fetchMock).toHaveBeenCalledOnce());
    installAuthIdentity({ id: "user-b", family_id: "family-b" });
    serverRemoval.resolve(new Response(null, { status: 204 }));
    await cleanup;

    expect(unsubscribe).not.toHaveBeenCalled();
    expect(registration.getNotifications).not.toHaveBeenCalled();
    expect(close).not.toHaveBeenCalled();
  });
});
