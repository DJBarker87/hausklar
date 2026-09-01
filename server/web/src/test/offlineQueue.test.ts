import { IDBFactory } from "fake-indexeddb";
import { beforeEach, describe, expect, it, vi } from "vitest";

import {
  cacheCycleProfiles,
  cachedCycleProfiles,
  enqueueMutation,
  heldQueuedMutations,
  offlineQueueSummary,
  purgeOfflineOwnerData,
  queuedMutations,
  setOfflineQueueOwner,
} from "../offlineQueue";

const dom = { id: "dom", family_id: "family-a" };
const reviewer = { id: "reviewer", family_id: "family-b" };

function deferred<T>() {
  let resolve!: (value: T | PromiseLike<T>) => void;
  const promise = new Promise<T>((resolvePromise) => { resolve = resolvePromise; });
  return { promise, resolve };
}

async function seedLegacyUnownedMutation(): Promise<void> {
  const database = await new Promise<IDBDatabase>((resolve, reject) => {
    const request = indexedDB.open("hausklar-offline", 1);
    request.onupgradeneeded = () => {
      request.result.createObjectStore("mutations", { keyPath: "id" });
    };
    request.onsuccess = () => resolve(request.result);
    request.onerror = () => reject(request.error);
  });
  await new Promise<void>((resolve, reject) => {
    const transaction = database.transaction("mutations", "readwrite");
    transaction.objectStore("mutations").add({
      id: "legacy-change",
      path: "/tasks/",
      method: "POST",
      body: JSON.stringify({ title: "Old private title" }),
      createdAt: "2026-07-01T08:00:00Z",
      attempts: 0,
      lastError: null,
    });
    transaction.oncomplete = () => resolve();
    transaction.onerror = () => reject(transaction.error);
  });
  database.close();
}

describe("offline queue account isolation", () => {
  beforeEach(() => {
    Object.defineProperty(globalThis, "indexedDB", {
      configurable: true,
      value: new IDBFactory(),
    });
    setOfflineQueueOwner(null);
    vi.restoreAllMocks();
  });

  it("quarantines family A changes when family B signs in", async () => {
    setOfflineQueueOwner(dom);
    const familyAChange = await enqueueMutation({
      path: "/calendar/",
      method: "POST",
      body: JSON.stringify({ id: "event-a", title: "Private family A appointment" }),
    });

    setOfflineQueueOwner(reviewer);

    expect(await queuedMutations()).toEqual([]);
    expect((await heldQueuedMutations()).map((change) => change.id)).toEqual([
      familyAChange.id,
    ]);
    expect(await offlineQueueSummary()).toEqual({ pending: 0, failed: 0, held: 1 });

    const familyBChange = await enqueueMutation({
      path: "/tasks/",
      method: "POST",
      body: JSON.stringify({ id: "task-b", title: "Family B task" }),
    });
    expect((await queuedMutations()).map((change) => change.id)).toEqual([
      familyBChange.id,
    ]);
    expect((await heldQueuedMutations()).map((change) => change.id)).toEqual([
      familyAChange.id,
    ]);

    setOfflineQueueOwner(dom);
    expect((await queuedMutations()).map((change) => change.id)).toEqual([
      familyAChange.id,
    ]);
    expect((await heldQueuedMutations()).map((change) => change.id)).toEqual([
      familyBChange.id,
    ]);
  });

  it("refuses to queue sensitive work without an authenticated owner", async () => {
    await expect(enqueueMutation({
      path: "/tasks/",
      method: "POST",
      body: JSON.stringify({ title: "Should never be unowned" }),
    })).rejects.toThrow("Sign in again");
  });

  it("keeps cached cycle data scoped to its authenticated adult", async () => {
    setOfflineQueueOwner(dom);
    await cacheCycleProfiles([{ id: "dom-cycle", latest_period_start: "2026-07-01" }]);
    expect(await cachedCycleProfiles()).toEqual([
      { id: "dom-cycle", latest_period_start: "2026-07-01" },
    ]);

    setOfflineQueueOwner(reviewer);
    expect(await cachedCycleProfiles()).toBeNull();
    await cacheCycleProfiles([{ id: "reviewer-cycle" }]);
    expect(await cachedCycleProfiles()).toEqual([{ id: "reviewer-cycle" }]);

    setOfflineQueueOwner(dom);
    expect(await cachedCycleProfiles()).toEqual([
      { id: "dom-cycle", latest_period_start: "2026-07-01" },
    ]);
  });

  it("purges only the explicitly signed-out owner's queue and cycle cache", async () => {
    setOfflineQueueOwner(dom);
    await enqueueMutation({ path: "/tasks/", method: "POST", body: "{}" });
    await cacheCycleProfiles([{ id: "dom-cycle" }]);
    setOfflineQueueOwner(reviewer);
    await enqueueMutation({ path: "/tasks/", method: "POST", body: "{}" });
    await cacheCycleProfiles([{ id: "reviewer-cycle" }]);

    await purgeOfflineOwnerData({ userId: dom.id, familyId: dom.family_id });

    setOfflineQueueOwner(dom);
    expect(await queuedMutations()).toEqual([]);
    expect(await cachedCycleProfiles()).toBeNull();
    setOfflineQueueOwner(reviewer);
    expect(await queuedMutations()).toHaveLength(1);
    expect(await cachedCycleProfiles()).toEqual([{ id: "reviewer-cycle" }]);
  });

  it("quarantines queue entries created before ownership metadata existed", async () => {
    await seedLegacyUnownedMutation();
    setOfflineQueueOwner(dom);

    expect(await queuedMutations()).toEqual([]);
    expect((await heldQueuedMutations()).map((change) => change.id)).toEqual([
      "legacy-change",
    ]);
  });

  it("flushes only the currently authenticated family's records", async () => {
    setOfflineQueueOwner(dom);
    await enqueueMutation({
      path: "/calendar/",
      method: "POST",
      body: JSON.stringify({ id: "event-a", title: "Family A only" }),
    });
    setOfflineQueueOwner(reviewer);
    await enqueueMutation({
      path: "/tasks/",
      method: "POST",
      body: JSON.stringify({ id: "task-b", title: "Family B only" }),
    });
    const fetchMock = vi.fn<typeof fetch>().mockResolvedValue(
      new Response(JSON.stringify({ id: "task-b" }), {
        status: 201,
        headers: { "content-type": "application/json" },
      }),
    );
    vi.stubGlobal("fetch", fetchMock);
    Object.defineProperty(window.navigator, "onLine", {
      configurable: true,
      value: true,
    });
    const { flushOfflineQueue } = await import("../api");

    await flushOfflineQueue();

    expect(fetchMock).toHaveBeenCalledTimes(1);
    expect(fetchMock.mock.calls[0]?.[0]).toBe("/api/tasks/");
    expect(await queuedMutations()).toEqual([]);
    expect(await heldQueuedMutations()).toHaveLength(1);
  });

  it("does not mark the previous owner's mutation failed after an account switch", async () => {
    setOfflineQueueOwner(dom);
    const queued = await enqueueMutation({
      path: "/tasks/",
      method: "POST",
      body: JSON.stringify({ id: "task-a", title: "Family A only" }),
    });
    const response = deferred<Response>();
    const fetchMock = vi.fn<typeof fetch>().mockReturnValue(response.promise);
    vi.stubGlobal("fetch", fetchMock);
    Object.defineProperty(window.navigator, "onLine", { configurable: true, value: true });
    const { flushOfflineQueue, installAuthIdentity } = await import("../api");
    installAuthIdentity(dom);

    const flush = flushOfflineQueue();
    await vi.waitFor(() => expect(fetchMock).toHaveBeenCalledTimes(1));
    installAuthIdentity(reviewer);
    setOfflineQueueOwner(reviewer);
    response.resolve(new Response(JSON.stringify({ id: "task-a" }), {
      status: 201,
      headers: { "content-type": "application/json" },
    }));
    await flush;

    setOfflineQueueOwner(dom);
    const [preserved] = await queuedMutations();
    expect(preserved).toMatchObject({ id: queued.id, attempts: 0, lastError: null });
  });
});
