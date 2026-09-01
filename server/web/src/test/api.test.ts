import { IDBFactory } from "fake-indexeddb";
import { beforeEach, describe, expect, it, vi } from "vitest";

function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json" },
  });
}

function deferred<T>() {
  let resolve!: (value: T | PromiseLike<T>) => void;
  let reject!: (reason?: unknown) => void;
  const promise = new Promise<T>((resolvePromise, rejectPromise) => {
    resolve = resolvePromise;
    reject = rejectPromise;
  });
  return { promise, resolve, reject };
}

describe("web API session handling", () => {
  beforeEach(() => {
    vi.resetModules();
    vi.restoreAllMocks();
  });

  it("rotates an expired cookie session once and retries the request", async () => {
    const fetchMock = vi
      .fn<typeof fetch>()
      .mockResolvedValueOnce(jsonResponse({ detail: "Expired" }, 401))
      .mockResolvedValueOnce(new Response(null, { status: 204 }))
      .mockResolvedValueOnce(jsonResponse([{ id: "task-1" }]));
    vi.stubGlobal("fetch", fetchMock);
    const { api } = await import("../api");

    await expect(api<Array<{ id: string }>>("/tasks/")).resolves.toEqual([{ id: "task-1" }]);

    expect(fetchMock).toHaveBeenCalledTimes(3);
    expect(fetchMock.mock.calls[0]?.[0]).toBe("/api/tasks/");
    expect(fetchMock.mock.calls[1]?.[0]).toBe("/api/auth/web/refresh");
    expect(fetchMock.mock.calls[2]?.[0]).toBe("/api/tasks/");
    expect(fetchMock.mock.calls[0]?.[1]).toMatchObject({ credentials: "same-origin" });
  });

  it("does not attempt session rotation for a rejected login", async () => {
    const fetchMock = vi.fn<typeof fetch>().mockResolvedValue(
      jsonResponse({ detail: "Incorrect email or password" }, 401),
    );
    vi.stubGlobal("fetch", fetchMock);
    const { login } = await import("../api");

    await expect(login("dom@example.invalid", "wrong")).rejects.toEqual(
      expect.objectContaining({ status: 401, message: "Incorrect email or password" }),
    );
    expect(fetchMock).toHaveBeenCalledTimes(1);
  });

  it("restores a browser session through the refresh cookie after reload", async () => {
    const currentUser = { id: "dom", name: "Alex" };
    const fetchMock = vi
      .fn<typeof fetch>()
      .mockResolvedValueOnce(jsonResponse({ detail: "Expired" }, 401))
      .mockResolvedValueOnce(new Response(null, { status: 204 }))
      .mockResolvedValueOnce(jsonResponse(currentUser));
    vi.stubGlobal("fetch", fetchMock);
    const { session } = await import("../api");

    await expect(session()).resolves.toEqual(currentUser);
    expect(fetchMock.mock.calls.map(([path]) => path)).toEqual([
      "/api/auth/web/session",
      "/api/auth/web/refresh",
      "/api/auth/web/session",
    ]);
  });

  it("does not refresh, retry, or expire a delayed response from a replaced identity", async () => {
    const firstResponse = deferred<Response>();
    const fetchMock = vi.fn<typeof fetch>().mockReturnValue(firstResponse.promise);
    vi.stubGlobal("fetch", fetchMock);
    const expired = vi.fn();
    window.addEventListener("hausklar:auth-expired", expired);
    const { api, installAuthIdentity } = await import("../api");
    installAuthIdentity({ id: "user-a", family_id: "family-a" });

    const request = api("/profile");
    const assertion = expect(request).rejects.toEqual(expect.objectContaining({ status: 401 }));
    installAuthIdentity({ id: "user-b", family_id: "family-b" });
    firstResponse.resolve(jsonResponse({ detail: "Expired A" }, 401));

    await assertion;
    expect(fetchMock).toHaveBeenCalledTimes(1);
    expect(expired).not.toHaveBeenCalled();
    window.removeEventListener("hausklar:auth-expired", expired);
  });

  it("preserves the installed identity when its epoch changes during a failed refresh", async () => {
    const refreshResponse = deferred<Response>();
    const fetchMock = vi
      .fn<typeof fetch>()
      .mockResolvedValueOnce(jsonResponse({ detail: "Expired A" }, 401))
      .mockReturnValueOnce(refreshResponse.promise);
    vi.stubGlobal("fetch", fetchMock);
    const expired = vi.fn();
    window.addEventListener("hausklar:auth-expired", expired);
    const { api, getAuthSessionEpoch, installAuthIdentity } = await import("../api");
    installAuthIdentity({ id: "user-a", family_id: "family-a" });

    const request = api("/tasks/");
    const assertion = expect(request).rejects.toEqual(expect.objectContaining({ status: 401 }));
    await vi.waitFor(() => expect(fetchMock).toHaveBeenCalledTimes(2));
    const userBEpoch = installAuthIdentity({ id: "user-b", family_id: "family-b" });
    refreshResponse.resolve(jsonResponse({ detail: "Refresh A failed" }, 401));

    await assertion;
    expect(getAuthSessionEpoch()).toBe(userBEpoch);
    expect(fetchMock).toHaveBeenCalledTimes(2);
    expect(expired).not.toHaveBeenCalled();
    window.removeEventListener("hausklar:auth-expired", expired);
  });

  it("never retries a delayed mutation under a replacement identity", async () => {
    const mutationResponse = deferred<Response>();
    const fetchMock = vi.fn<typeof fetch>().mockReturnValue(mutationResponse.promise);
    vi.stubGlobal("fetch", fetchMock);
    const { api, installAuthIdentity } = await import("../api");
    installAuthIdentity({ id: "user-a", family_id: "family-a" });

    const request = api("/tasks/task-a", {
      method: "PUT",
      body: JSON.stringify({ title: "A's private change" }),
    });
    const assertion = expect(request).rejects.toEqual(expect.objectContaining({ status: 401 }));
    installAuthIdentity({ id: "user-b", family_id: "family-b" });
    mutationResponse.resolve(jsonResponse({ detail: "Expired A" }, 401));

    await assertion;
    expect(fetchMock).toHaveBeenCalledTimes(1);
    expect(fetchMock.mock.calls[0]?.[0]).toBe("/api/tasks/task-a");
  });

  it("does not let a stale successful response start a chained request as the replacement identity", async () => {
    const uploadResponse = deferred<Response>();
    const fetchMock = vi.fn<typeof fetch>().mockReturnValue(uploadResponse.promise);
    vi.stubGlobal("fetch", fetchMock);
    const { api, installAuthIdentity } = await import("../api");
    installAuthIdentity({ id: "user-a", family_id: "shared-family" });

    const workflow = api<{ id: string }>("/documents/", {
      method: "POST",
      body: new FormData(),
    }).then((document) => api("/calendar/", {
      method: "POST",
      body: JSON.stringify({
        id: "event-a",
        title: "A's private draft",
        source_document_id: document.id,
      }),
    }));
    const assertion = expect(workflow).rejects.toEqual(expect.objectContaining({
      status: 409,
      message: "This request belonged to an older signed-in session.",
    }));

    installAuthIdentity({ id: "user-b", family_id: "shared-family" });
    uploadResponse.resolve(jsonResponse({ id: "document-a" }));

    await assertion;
    expect(fetchMock).toHaveBeenCalledTimes(1);
    expect(fetchMock.mock.calls[0]?.[0]).toBe("/api/documents/");
  });

  it("does not queue a failed A mutation for B after a delayed network error", async () => {
    Object.defineProperty(globalThis, "indexedDB", {
      configurable: true,
      value: new IDBFactory(),
    });
    Object.defineProperty(window.navigator, "onLine", { configurable: true, value: true });
    const networkFailure = deferred<Response>();
    vi.stubGlobal("fetch", vi.fn<typeof fetch>().mockReturnValue(networkFailure.promise));
    const { api, installAuthIdentity } = await import("../api");
    const { heldQueuedMutations, queuedMutations, setOfflineQueueOwner } = await import("../offlineQueue");
    const userA = { id: "user-a", family_id: "family-a" };
    const userB = { id: "user-b", family_id: "family-b" };
    installAuthIdentity(userA);
    setOfflineQueueOwner(userA);

    const request = api("/tasks/", {
      method: "POST",
      body: JSON.stringify({ id: "task-a", title: "A only" }),
    });
    const assertion = expect(request).rejects.toBeInstanceOf(TypeError);
    installAuthIdentity(userB);
    setOfflineQueueOwner(userB);
    networkFailure.reject(new TypeError("Network changed"));

    await assertion;
    expect(await queuedMutations()).toEqual([]);
    expect(await heldQueuedMutations()).toEqual([]);
  });

  it("does not queue a timed-out A mutation for B after the epoch changes", async () => {
    vi.useFakeTimers();
    try {
      Object.defineProperty(globalThis, "indexedDB", {
        configurable: true,
        value: new IDBFactory(),
      });
      Object.defineProperty(window.navigator, "onLine", { configurable: true, value: true });
      const fetchMock = vi.fn<typeof fetch>((_input, init) => new Promise((_resolve, reject) => {
        init?.signal?.addEventListener("abort", () => reject(new DOMException("Aborted", "AbortError")));
      }));
      vi.stubGlobal("fetch", fetchMock);
      const { api, installAuthIdentity } = await import("../api");
      const { heldQueuedMutations, queuedMutations, setOfflineQueueOwner } = await import("../offlineQueue");
      const userA = { id: "user-a", family_id: "family-a" };
      const userB = { id: "user-b", family_id: "family-b" };
      installAuthIdentity(userA);
      setOfflineQueueOwner(userA);

      const request = api("/calendar/", {
        method: "POST",
        body: JSON.stringify({ id: "event-a", title: "A only" }),
        timeoutMs: 25,
      });
      const assertion = expect(request).rejects.toEqual(expect.objectContaining({ status: 408 }));
      installAuthIdentity(userB);
      setOfflineQueueOwner(userB);
      await vi.advanceTimersByTimeAsync(25);

      await assertion;
      vi.useRealTimers();
      expect(await queuedMutations()).toEqual([]);
      expect(await heldQueuedMutations()).toEqual([]);
    } finally {
      vi.useRealTimers();
    }
  });

  it("coalesces concurrent 401 responses into one same-epoch refresh", async () => {
    const refreshResponse = deferred<Response>();
    const attempts = new Map<string, number>();
    const fetchMock = vi.fn<typeof fetch>((input) => {
      const path = String(input);
      if (path === "/api/auth/web/refresh") return refreshResponse.promise;
      const attempt = (attempts.get(path) ?? 0) + 1;
      attempts.set(path, attempt);
      return Promise.resolve(attempt === 1
        ? jsonResponse({ detail: "Expired" }, 401)
        : jsonResponse({ path }));
    });
    vi.stubGlobal("fetch", fetchMock);
    const { api, installAuthIdentity } = await import("../api");
    installAuthIdentity({ id: "user-a", family_id: "family-a" });

    const first = api<{ path: string }>("/tasks/one");
    const second = api<{ path: string }>("/tasks/two");
    await vi.waitFor(() => {
      expect(fetchMock.mock.calls.filter(([path]) => path === "/api/auth/web/refresh")).toHaveLength(1);
    });
    refreshResponse.resolve(new Response(null, { status: 204 }));

    await expect(Promise.all([first, second])).resolves.toEqual([
      { path: "/api/tasks/one" },
      { path: "/api/tasks/two" },
    ]);
    expect(fetchMock.mock.calls.filter(([path]) => path === "/api/auth/web/refresh")).toHaveLength(1);
    expect(fetchMock).toHaveBeenCalledTimes(5);
  });

  it("waits for an already-started refresh before sending a login", async () => {
    const refreshResponse = deferred<Response>();
    const fetchMock = vi.fn<typeof fetch>((input) => {
      const path = String(input);
      if (path === "/api/tasks/") return Promise.resolve(jsonResponse({ detail: "Expired A" }, 401));
      if (path === "/api/auth/web/refresh") return refreshResponse.promise;
      if (path === "/api/auth/web/login") {
        return Promise.resolve(jsonResponse({
          id: "user-b",
          family_id: "family-b",
          name: "B",
          email: "b@example.invalid",
          role: "user",
          priority: 10,
        }));
      }
      throw new Error(`Unexpected request: ${path}`);
    });
    vi.stubGlobal("fetch", fetchMock);
    const { api, installAuthIdentity, login } = await import("../api");
    installAuthIdentity({ id: "user-a", family_id: "family-a" });

    const oldRequest = api("/tasks/");
    const oldAssertion = expect(oldRequest).rejects.toEqual(expect.objectContaining({ status: 401 }));
    await vi.waitFor(() => expect(fetchMock).toHaveBeenCalledTimes(2));
    const signIn = login("b@example.invalid", "private-password");
    await Promise.resolve();
    expect(fetchMock.mock.calls.some(([path]) => path === "/api/auth/web/login")).toBe(false);

    refreshResponse.resolve(new Response(null, { status: 204 }));
    await oldAssertion;
    await expect(signIn).resolves.toEqual(expect.objectContaining({ id: "user-b" }));
    expect(fetchMock.mock.calls.map(([path]) => path)).toEqual([
      "/api/tasks/",
      "/api/auth/web/refresh",
      "/api/auth/web/login",
    ]);
  });

  it("coalesces and briefly reuses identical Finance reads", async () => {
    const fetchMock = vi.fn<typeof fetch>().mockResolvedValue(jsonResponse({ default_currency: "GBP" }));
    vi.stubGlobal("fetch", fetchMock);
    const { api, installAuthIdentity } = await import("../api");
    installAuthIdentity({ id: "user-a", family_id: "family-a" });

    const [first, second] = await Promise.all([
      api<{ default_currency: string }>("/finance/settings", {}, true, false),
      api<{ default_currency: string }>("/finance/settings", {}, true, false),
    ]);
    const third = await api<{ default_currency: string }>("/finance/settings", {}, true, false);

    expect(first).toEqual({ default_currency: "GBP" });
    expect(second).toEqual(first);
    expect(third).toEqual(first);
    expect(fetchMock).toHaveBeenCalledTimes(1);
    expect(fetchMock).toHaveBeenCalledWith(
      "/api/finance/settings",
      expect.objectContaining({ credentials: "same-origin" }),
    );
  });

  it("keeps a shared Finance read alive when one screen stops observing it", async () => {
    const response = deferred<Response>();
    const fetchMock = vi.fn<typeof fetch>().mockReturnValue(response.promise);
    vi.stubGlobal("fetch", fetchMock);
    const { api, installAuthIdentity } = await import("../api");
    installAuthIdentity({ id: "user-a", family_id: "family-a" });
    const firstController = new AbortController();
    const secondController = new AbortController();

    const first = api("/finance/accounts?space_id=personal", { signal: firstController.signal }, true, false);
    const second = api<Array<{ id: string }>>("/finance/accounts?space_id=personal", { signal: secondController.signal }, true, false);
    firstController.abort();
    const firstAssertion = expect(first).rejects.toEqual(expect.objectContaining({ name: "AbortError" }));
    response.resolve(jsonResponse([{ id: "account-1" }]));

    await firstAssertion;
    await expect(second).resolves.toEqual([{ id: "account-1" }]);
    expect(fetchMock).toHaveBeenCalledTimes(1);
    expect(fetchMock.mock.calls[0]?.[1]?.signal).not.toBe(firstController.signal);
    expect(fetchMock.mock.calls[0]?.[1]?.signal).not.toBe(secondController.signal);
  });

  it("invalidates Finance reads after a write and at every identity change", async () => {
    let accountVersion = 0;
    const fetchMock = vi.fn<typeof fetch>((input, init) => {
      if (String(input) === "/api/finance/accounts?space_id=personal") {
        accountVersion += 1;
        return Promise.resolve(jsonResponse([{ id: `account-${accountVersion}` }]));
      }
      if (String(input) === "/api/finance/goals" && init?.method === "POST") {
        return Promise.resolve(jsonResponse({ id: "goal-1" }));
      }
      throw new Error(`Unexpected request: ${String(input)}`);
    });
    vi.stubGlobal("fetch", fetchMock);
    const { api, installAuthIdentity } = await import("../api");
    installAuthIdentity({ id: "user-a", family_id: "family-a" });

    await expect(api<Array<{ id: string }>>("/finance/accounts?space_id=personal", {}, true, false))
      .resolves.toEqual([{ id: "account-1" }]);
    await api("/finance/goals", { method: "POST", body: JSON.stringify({ name: "House" }) }, true, false);
    await expect(api<Array<{ id: string }>>("/finance/accounts?space_id=personal", {}, true, false))
      .resolves.toEqual([{ id: "account-2" }]);
    installAuthIdentity({ id: "user-b", family_id: "family-a" });
    await expect(api<Array<{ id: string }>>("/finance/accounts?space_id=personal", {}, true, false))
      .resolves.toEqual([{ id: "account-3" }]);

    expect(fetchMock).toHaveBeenCalledTimes(4);
  });

  it("keeps analysis reads cached but invalidates after saving an analysis view", async () => {
    let settingsVersion = 0;
    const fetchMock = vi.fn<typeof fetch>((input) => {
      if (String(input) === "/api/finance/settings") {
        settingsVersion += 1;
        return Promise.resolve(jsonResponse({ version: settingsVersion }));
      }
      if (String(input) === "/api/finance/analysis") {
        return Promise.resolve(jsonResponse({ total: 0 }));
      }
      throw new Error(`Unexpected request: ${String(input)}`);
    });
    vi.stubGlobal("fetch", fetchMock);
    const { api, installAuthIdentity } = await import("../api");
    installAuthIdentity({ id: "user-a", family_id: "family-a" });

    await expect(api<{ version: number }>("/finance/settings", {}, true, false))
      .resolves.toEqual({ version: 1 });
    await api(
      "/finance/analysis",
      { method: "POST", body: JSON.stringify({ save_as: null }) },
      true,
      false,
    );
    await expect(api<{ version: number }>("/finance/settings", {}, true, false))
      .resolves.toEqual({ version: 1 });
    await api(
      "/finance/analysis",
      { method: "POST", body: JSON.stringify({ save_as: "Monthly view" }) },
      true,
      false,
    );
    await expect(api<{ version: number }>("/finance/settings", {}, true, false))
      .resolves.toEqual({ version: 2 });

    expect(fetchMock).toHaveBeenCalledTimes(4);
  });

  it("sends reset tokens only in the request body", async () => {
    const fetchMock = vi.fn<typeof fetch>().mockResolvedValue(jsonResponse({ message: "ok" }));
    vi.stubGlobal("fetch", fetchMock);
    const { resetPassword } = await import("../api");

    await resetPassword("header.payload.signature", "a-new-private-password");

    expect(fetchMock.mock.calls[0]?.[0]).toBe("/api/auth/reset-password");
    expect(fetchMock.mock.calls[0]?.[1]).toMatchObject({
      method: "POST",
      body: JSON.stringify({
        token: "header.payload.signature",
        new_password: "a-new-private-password",
      }),
    });
  });

  it("requests a password reset without exposing the email in the URL", async () => {
    const fetchMock = vi.fn<typeof fetch>().mockResolvedValue(jsonResponse({ message: "ok" }));
    vi.stubGlobal("fetch", fetchMock);
    const { requestPasswordReset } = await import("../api");

    await requestPasswordReset("kat@example.invalid");

    expect(fetchMock).toHaveBeenCalledTimes(1);
    expect(fetchMock.mock.calls[0]?.[0]).toBe("/api/auth/forgot-password");
    expect(fetchMock.mock.calls[0]?.[1]).toMatchObject({
      method: "POST",
      body: JSON.stringify({ email: "kat@example.invalid" }),
    });
  });

  it("aborts a stalled request and returns a useful timeout error", async () => {
    vi.useFakeTimers();
    try {
      const fetchMock = vi.fn<typeof fetch>((_input, init) =>
        new Promise((_resolve, reject) => {
          init?.signal?.addEventListener("abort", () => {
            reject(new DOMException("Aborted", "AbortError"));
          });
        }),
      );
      vi.stubGlobal("fetch", fetchMock);
      const { api } = await import("../api");

      const request = api("/tasks/", { timeoutMs: 25 });
      const assertion = expect(request).rejects.toEqual(
        expect.objectContaining({ status: 408, message: expect.stringContaining("too long") }),
      );
      await vi.advanceTimersByTimeAsync(25);

      await assertion;
      expect(fetchMock.mock.calls[0]?.[1]?.signal?.aborted).toBe(true);
    } finally {
      vi.useRealTimers();
    }
  });

  it("reports network and durable-cache read provenance without changing returned values", async () => {
    Object.defineProperty(globalThis, "indexedDB", {
      configurable: true,
      value: new IDBFactory(),
    });
    Object.defineProperty(window.navigator, "onLine", { configurable: true, value: true });
    const fetchMock = vi.fn<typeof fetch>()
      .mockResolvedValueOnce(jsonResponse({ date: "2026-08-10", tasks: ["network"] }))
      .mockRejectedValueOnce(new TypeError("Network unavailable"));
    vi.stubGlobal("fetch", fetchMock);
    const { api, installAuthIdentity } = await import("../api");
    const { setOfflineQueueOwner } = await import("../offlineQueue");
    const user = { id: "dom", family_id: "family-a" };
    installAuthIdentity(user);
    setOfflineQueueOwner(user);
    const sources: string[] = [];

    await expect(api<{ tasks: string[] }>("/briefing/dashboard", {
      onReadSource: (source) => sources.push(source),
    })).resolves.toMatchObject({ tasks: ["network"] });
    await expect(api<{ tasks: string[] }>("/briefing/dashboard", {
      onReadSource: (source) => sources.push(source),
    })).resolves.toMatchObject({ tasks: ["network"] });

    expect(sources).toEqual(["network", "cache"]);
    expect(fetchMock).toHaveBeenCalledTimes(2);
  });

  it("queues replay-safe writes and keeps external actions network-only", async () => {
    const { isOfflineQueueable } = await import("../api");
    expect(isOfflineQueueable("/calendar/", "POST")).toBe(true);
    expect(isOfflineQueueable("/facilities/weights-bookings", "POST", JSON.stringify({}))).toBe(true);
    expect(isOfflineQueueable("/tasks/", "POST")).toBe(true);
    expect(isOfflineQueueable("/meals/shopping", "POST")).toBe(true);
    expect(isOfflineQueueable("/cycles/settings", "PUT")).toBe(true);
    expect(isOfflineQueueable("/cycles/periods", "POST")).toBe(true);
    expect(isOfflineQueueable("/cycles/periods/period-id", "DELETE")).toBe(true);
    expect(isOfflineQueueable("/medicine/doses", "POST")).toBe(true);
    expect(isOfflineQueueable("/documents/", "POST", new FormData())).toBe(true);
    expect(isOfflineQueueable("/tasks/task-id", "DELETE")).toBe(true);
    expect(isOfflineQueueable("/assistant/messages", "POST")).toBe(false);
    expect(isOfflineQueueable("/commitments/from-source", "POST")).toBe(false);
    expect(isOfflineQueueable("/commitments/free-windows/query", "POST")).toBe(false);
    expect(isOfflineQueueable("/commitments/commitment-id", "PATCH")).toBe(true);
    expect(isOfflineQueueable("/fitness/records", "POST")).toBe(false);
    expect(isOfflineQueueable("/finance/connections", "POST")).toBe(false);
    expect(isOfflineQueueable("/home/services", "POST", JSON.stringify({}))).toBe(false);
  });

  it("keeps an offline document file and replays it with the same ID", async () => {
    Object.defineProperty(globalThis, "indexedDB", { configurable: true, value: new IDBFactory() });
    Object.defineProperty(window.navigator, "onLine", { configurable: true, value: false });
    const { api, flushOfflineQueue } = await import("../api");
    const { currentOfflineQueueOwner, queuedMutations, setOfflineQueueOwner } = await import("../offlineQueue");
    setOfflineQueueOwner({ id: "dom", family_id: "family-a" });
    const documentID = crypto.randomUUID();
    const form = new FormData();
    form.set("document_id", documentID);
    form.set("title", "School letter");
    form.set("file", new File(["letter"], "letter.txt", { type: "text/plain" }));

    await expect(api<{ id: string }>("/documents/", { method: "POST", body: form })).resolves.toMatchObject({ id: documentID });
    const [queued] = await queuedMutations();
    expect(queued?.formData?.map((part) => part.name)).toEqual(["document_id", "title", "file"]);

    Object.defineProperty(window.navigator, "onLine", { configurable: true, value: true });
    expect(navigator.onLine).toBe(true);
    expect(currentOfflineQueueOwner()).toEqual({ userId: "dom", familyId: "family-a" });
    expect(await queuedMutations()).toHaveLength(1);
    const fetchMock = vi.fn<typeof fetch>().mockResolvedValue(jsonResponse({ id: documentID }, 201));
    vi.stubGlobal("fetch", fetchMock);
    await flushOfflineQueue();

    expect(fetchMock.mock.calls.map(([path, init]) => [path, init?.body?.constructor.name])).toEqual([
      ["/api/documents/", "FormData"],
    ]);
    const replay = fetchMock.mock.calls.find(([path]) => path === "/api/documents/")?.[1]?.body as FormData;
    expect(replay.get("document_id")).toBe(documentID);
    expect((replay.get("file") as File).name).toBe("letter.txt");
    expect(await queuedMutations()).toEqual([]);
  });

  it("persists stable cycle operation IDs while the NUC is unreachable", async () => {
    Object.defineProperty(globalThis, "indexedDB", {
      configurable: true,
      value: new IDBFactory(),
    });
    Object.defineProperty(window.navigator, "onLine", {
      configurable: true,
      value: false,
    });
    const { api, isOfflineQueuedResult } = await import("../api");
    const { queuedMutations, setOfflineQueueOwner } = await import("../offlineQueue");
    setOfflineQueueOwner({ id: "kat", family_id: "family-a" });
    const periodId = crypto.randomUUID();

    const result = await api("/cycles/periods", {
      method: "POST",
      body: JSON.stringify({ id: periodId, started_on: "2026-08-01" }),
    });

    expect(isOfflineQueuedResult(result)).toBe(true);
    const [queued] = await queuedMutations();
    expect(queued).toMatchObject({
      path: "/cycles/periods",
      method: "POST",
    });
    expect(JSON.parse(String(queued?.body))).toEqual({
      id: periodId,
      started_on: "2026-08-01",
    });
    Object.defineProperty(window.navigator, "onLine", {
      configurable: true,
      value: true,
    });
  });
});
