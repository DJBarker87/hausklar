export type QueuedMutation = {
  id: string;
  ownerUserId: string;
  ownerFamilyId: string;
  path: string;
  method: string;
  body: string | null;
  formData?: QueuedFormDataPart[] | null;
  createdAt: string;
  attempts: number;
  lastError: string | null;
};

export type QueuedFormDataPart = {
  name: string;
  value: string | Blob;
  filename?: string;
};

export type CachedApiResponse = {
  id: string;
  ownerUserId: string;
  ownerFamilyId: string;
  path: string;
  value: unknown;
  updatedAt: string;
};

export type CachedOfflineSession = {
  id: "last-session";
  user: {
    id: string;
    family_id: string | null;
    [key: string]: unknown;
  };
  updatedAt: string;
};

export type OfflineQueueOwner = {
  userId: string;
  familyId: string;
};

const DATABASE = "hausklar-offline";
const VERSION = 5;
const STORE = "mutations";
const CYCLE_STORE = "cycle-profiles";
const RESPONSE_STORE = "api-responses";
const SESSION_STORE = "sessions";
const OWNER_INDEX = "by-owner";
const OWNER_CREATED_INDEX = "by-owner-created";
const OWNER_UPDATED_INDEX = "by-owner-updated";
const MAX_OWNER_CACHE_ENTRIES = 300;
const MAX_OWNER_CACHE_BYTES = 25 * 1024 * 1024;
const MAX_CACHE_AGE_MS = 30 * 24 * 60 * 60 * 1_000;
let activeOwner: OfflineQueueOwner | null = null;
let ownerEpoch = 0;
let databaseFactory: IDBFactory | null = null;
let databasePromise: Promise<IDBDatabase> | null = null;
const pendingPrunes = new Set<string>();

export function setOfflineQueueOwner(
  user: { id: string; family_id: string | null } | null,
): void {
  ownerEpoch += 1;
  activeOwner = user?.id && user.family_id
    ? { userId: user.id, familyId: user.family_id }
    : null;
}

export function currentOfflineQueueOwner(): OfflineQueueOwner | null {
  return activeOwner ? { ...activeOwner } : null;
}

function belongsToOwner(
  mutation: Partial<QueuedMutation>,
  owner: OfflineQueueOwner,
): boolean {
  return mutation.ownerUserId === owner.userId && mutation.ownerFamilyId === owner.familyId;
}

function openDatabase(): Promise<IDBDatabase> {
  const factory = indexedDB;
  if (databaseFactory !== factory) {
    if (databasePromise) void databasePromise.then((database) => database.close()).catch(() => undefined);
    databaseFactory = factory;
    databasePromise = null;
  }
  if (databasePromise) return databasePromise;
  databasePromise = new Promise((resolve, reject) => {
    const request = factory.open(DATABASE, VERSION);
    request.onupgradeneeded = () => {
      const database = request.result;
      const transaction = request.transaction!;
      const mutations = database.objectStoreNames.contains(STORE)
        ? transaction.objectStore(STORE)
        : database.createObjectStore(STORE, { keyPath: "id" });
      if (!database.objectStoreNames.contains(CYCLE_STORE)) {
        database.createObjectStore(CYCLE_STORE, { keyPath: "id" });
      }
      const responses = database.objectStoreNames.contains(RESPONSE_STORE)
        ? transaction.objectStore(RESPONSE_STORE)
        : database.createObjectStore(RESPONSE_STORE, { keyPath: "id" });
      if (!database.objectStoreNames.contains(SESSION_STORE)) {
        database.createObjectStore(SESSION_STORE, { keyPath: "id" });
      }
      if (!mutations.indexNames.contains(OWNER_INDEX)) {
        mutations.createIndex(OWNER_INDEX, ["ownerFamilyId", "ownerUserId"]);
      }
      if (!mutations.indexNames.contains(OWNER_CREATED_INDEX)) {
        mutations.createIndex(
          OWNER_CREATED_INDEX,
          ["ownerFamilyId", "ownerUserId", "createdAt"],
        );
      }
      if (!responses.indexNames.contains(OWNER_INDEX)) {
        responses.createIndex(OWNER_INDEX, ["ownerFamilyId", "ownerUserId"]);
      }
      if (!responses.indexNames.contains(OWNER_UPDATED_INDEX)) {
        responses.createIndex(
          OWNER_UPDATED_INDEX,
          ["ownerFamilyId", "ownerUserId", "updatedAt"],
        );
      }
    };
    request.onsuccess = () => {
      const database = request.result;
      database.onversionchange = () => {
        database.close();
        if (databaseFactory === factory) databasePromise = null;
      };
      resolve(database);
    };
    request.onerror = () => {
      databasePromise = null;
      reject(request.error ?? new Error("Offline storage is unavailable."));
    };
  });
  return databasePromise;
}

function ownerCacheKey(owner: OfflineQueueOwner): string {
  return `${owner.familyId}\u0000${owner.userId}`;
}

function responseCacheKey(owner: OfflineQueueOwner, path: string): string {
  return `${ownerCacheKey(owner)}\u0000${path}`;
}

export async function cacheCycleProfiles(profiles: unknown[]): Promise<void> {
  const owner = currentOfflineQueueOwner();
  if (!owner) return;
  const database = await openDatabase();
  await new Promise<void>((resolve, reject) => {
    const tx = database.transaction(CYCLE_STORE, "readwrite");
    const request = tx.objectStore(CYCLE_STORE).put({
      id: ownerCacheKey(owner),
      profiles,
      updatedAt: new Date().toISOString(),
    });
    request.onsuccess = () => resolve();
    request.onerror = () => reject(request.error);
    tx.onerror = () => reject(tx.error ?? new Error("Offline cycle data could not be updated."));
  });
}

export async function cachedCycleProfiles<T>(): Promise<T[] | null> {
  const owner = currentOfflineQueueOwner();
  if (!owner) return null;
  const database = await openDatabase();
  return new Promise<T[] | null>((resolve, reject) => {
    const tx = database.transaction(CYCLE_STORE, "readonly");
    const request = tx.objectStore(CYCLE_STORE).get(ownerCacheKey(owner));
    request.onsuccess = () => {
      const result = request.result as { profiles?: T[] } | undefined;
      resolve(result?.profiles ?? null);
    };
    request.onerror = () => reject(request.error);
    tx.onerror = () => reject(tx.error ?? new Error("Offline cycle data could not be read."));
  });
}

async function transaction<T>(
  mode: IDBTransactionMode,
  operation: (store: IDBObjectStore, resolve: (value: T) => void, reject: (reason?: unknown) => void) => void,
): Promise<T> {
  const database = await openDatabase();
  return new Promise<T>((resolve, reject) => {
    const tx = database.transaction(STORE, mode);
    const store = tx.objectStore(STORE);
    operation(store, resolve, reject);
    tx.onerror = () => reject(tx.error ?? new Error("Offline storage could not be updated."));
    tx.onabort = () => reject(tx.error ?? new Error("Offline storage update was cancelled."));
  });
}

async function storeTransaction<T>(
  storeName: string,
  mode: IDBTransactionMode,
  operation: (store: IDBObjectStore, resolve: (value: T) => void, reject: (reason?: unknown) => void) => void,
): Promise<T> {
  const database = await openDatabase();
  return new Promise<T>((resolve, reject) => {
    const tx = database.transaction(storeName, mode);
    const store = tx.objectStore(storeName);
    operation(store, resolve, reject);
    tx.onerror = () => reject(tx.error ?? new Error("Offline storage could not be updated."));
    tx.onabort = () => reject(tx.error ?? new Error("Offline storage update was cancelled."));
  });
}

export async function cacheOfflineSession(user: CachedOfflineSession["user"]): Promise<void> {
  if (typeof indexedDB === "undefined" || !user.id || !user.family_id) return;
  await storeTransaction<void>(SESSION_STORE, "readwrite", (store, resolve, reject) => {
    const request = store.put({ id: "last-session", user, updatedAt: new Date().toISOString() });
    request.onsuccess = () => resolve();
    request.onerror = () => reject(request.error);
  });
}

export async function cachedOfflineSession<T>(): Promise<T | null> {
  if (typeof indexedDB === "undefined") return null;
  return storeTransaction<T | null>(SESSION_STORE, "readonly", (store, resolve, reject) => {
    const request = store.get("last-session");
    request.onsuccess = () => resolve((request.result as CachedOfflineSession | undefined)?.user as T ?? null);
    request.onerror = () => reject(request.error);
  });
}

export async function clearOfflineSession(): Promise<void> {
  if (typeof indexedDB === "undefined") return;
  await storeTransaction<void>(SESSION_STORE, "readwrite", (store, resolve, reject) => {
    const request = store.delete("last-session");
    request.onsuccess = () => resolve();
    request.onerror = () => reject(request.error);
  });
}

export async function cacheApiResponse(path: string, value: unknown): Promise<void> {
  const owner = currentOfflineQueueOwner();
  if (!owner || typeof indexedDB === "undefined") return;
  const epoch = ownerEpoch;
  const entry: CachedApiResponse = {
    id: responseCacheKey(owner, path),
    ownerUserId: owner.userId,
    ownerFamilyId: owner.familyId,
    path,
    value,
    updatedAt: new Date().toISOString(),
  };
  await openDatabase();
  if (
    epoch !== ownerEpoch
    || !belongsToOwner(entry, currentOfflineQueueOwner() ?? { userId: "", familyId: "" })
  ) return;
  await storeTransaction<void>(RESPONSE_STORE, "readwrite", (store, resolve, reject) => {
    const request = store.put(entry);
    request.onsuccess = () => resolve();
    request.onerror = () => reject(request.error);
  });
  scheduleResponsePrune(owner);
}

export async function cachedApiResponse<T>(path: string): Promise<T | null> {
  const owner = currentOfflineQueueOwner();
  if (!owner || typeof indexedDB === "undefined") return null;
  return storeTransaction<T | null>(RESPONSE_STORE, "readonly", (store, resolve, reject) => {
    const request = store.get(responseCacheKey(owner, path));
    request.onsuccess = () => resolve((request.result as CachedApiResponse | undefined)?.value as T ?? null);
    request.onerror = () => reject(request.error);
  });
}

export async function cachedApiResponses(): Promise<CachedApiResponse[]> {
  const owner = currentOfflineQueueOwner();
  if (!owner || typeof indexedDB === "undefined") return [];
  return storeTransaction<CachedApiResponse[]>(RESPONSE_STORE, "readonly", (store, resolve, reject) => {
    const request = store.index(OWNER_INDEX).getAll(
      [owner.familyId, owner.userId],
    );
    request.onsuccess = () => resolve(request.result as CachedApiResponse[]);
    request.onerror = () => reject(request.error);
  });
}

function estimatedCacheBytes(entry: CachedApiResponse): number {
  try {
    return JSON.stringify(entry.value).length * 2 + entry.path.length * 2 + 200;
  } catch {
    return MAX_OWNER_CACHE_BYTES;
  }
}

async function pruneCachedApiResponses(owner: OfflineQueueOwner): Promise<void> {
  const entries = await storeTransaction<CachedApiResponse[]>(
    RESPONSE_STORE,
    "readonly",
    (store, resolve, reject) => {
      const request = store.index(OWNER_INDEX).getAll(
        [owner.familyId, owner.userId],
      );
      request.onsuccess = () => resolve(
        (request.result as CachedApiResponse[])
          .sort((left, right) => left.updatedAt.localeCompare(right.updatedAt)),
      );
      request.onerror = () => reject(request.error);
    },
  );
  const cutoff = Date.now() - MAX_CACHE_AGE_MS;
  let totalBytes = entries.reduce((total, entry) => total + estimatedCacheBytes(entry), 0);
  const remove = new Set<string>();
  for (const entry of entries) {
    if (Date.parse(entry.updatedAt) < cutoff) {
      remove.add(entry.id);
      totalBytes -= estimatedCacheBytes(entry);
    }
  }
  const retained = entries.filter((entry) => !remove.has(entry.id));
  while (retained.length > MAX_OWNER_CACHE_ENTRIES || totalBytes > MAX_OWNER_CACHE_BYTES) {
    const entry = retained.shift();
    if (!entry) break;
    remove.add(entry.id);
    totalBytes -= estimatedCacheBytes(entry);
  }
  if (!remove.size) return;
  await storeTransaction<void>(RESPONSE_STORE, "readwrite", (store, resolve, reject) => {
    let pending = remove.size;
    for (const id of remove) {
      const request = store.delete(id);
      request.onsuccess = () => { if (--pending === 0) resolve(); };
      request.onerror = () => reject(request.error);
    }
  });
}

function scheduleResponsePrune(owner: OfflineQueueOwner): void {
  const key = ownerCacheKey(owner);
  if (pendingPrunes.has(key)) return;
  pendingPrunes.add(key);
  globalThis.setTimeout(() => {
    void pruneCachedApiResponses(owner)
      .catch(() => undefined)
      .finally(() => pendingPrunes.delete(key));
  }, 0);
}

export async function updateCachedApiResponse(path: string, value: unknown): Promise<void> {
  await cacheApiResponse(path, value);
}

export async function enqueueMutation(
  input: Pick<QueuedMutation, "path" | "method" | "body" | "formData"> & { id?: string },
): Promise<QueuedMutation> {
  const owner = currentOfflineQueueOwner();
  if (!owner) {
    throw new Error("Sign in again before saving work offline.");
  }
  const mutation: QueuedMutation = {
    id: input.id ?? crypto.randomUUID(),
    ownerUserId: owner.userId,
    ownerFamilyId: owner.familyId,
    path: input.path,
    method: input.method,
    body: input.body,
    formData: input.formData ?? null,
    createdAt: new Date().toISOString(),
    attempts: 0,
    lastError: null,
  };
  await transaction<void>("readwrite", (store, resolve, reject) => {
    const request = store.add(mutation);
    request.onsuccess = () => resolve();
    request.onerror = () => reject(request.error);
  });
  return mutation;
}

async function allQueuedMutations(): Promise<QueuedMutation[]> {
  return transaction<QueuedMutation[]>("readonly", (store, resolve, reject) => {
    const request = store.getAll();
    request.onsuccess = () => resolve(
      (request.result as QueuedMutation[]).sort((left, right) => left.createdAt.localeCompare(right.createdAt)),
    );
    request.onerror = () => reject(request.error);
  });
}

export async function queuedMutations(): Promise<QueuedMutation[]> {
  const owner = currentOfflineQueueOwner();
  if (!owner) return [];
  return transaction<QueuedMutation[]>("readonly", (store, resolve, reject) => {
    const request = store.index(OWNER_INDEX).getAll(
      [owner.familyId, owner.userId],
    );
    request.onsuccess = () => resolve(
      (request.result as QueuedMutation[]).sort((left, right) => left.createdAt.localeCompare(right.createdAt)),
    );
    request.onerror = () => reject(request.error);
  });
}

/** Entries from another account (and legacy unowned entries) stay quarantined. */
export async function heldQueuedMutations(): Promise<QueuedMutation[]> {
  const owner = currentOfflineQueueOwner();
  const mutations = await allQueuedMutations();
  if (!owner) return mutations;
  return mutations.filter((mutation) => !belongsToOwner(mutation, owner));
}

export async function removeQueuedMutation(id: string): Promise<void> {
  await transaction<void>("readwrite", (store, resolve, reject) => {
    const request = store.delete(id);
    request.onsuccess = () => resolve();
    request.onerror = () => reject(request.error);
  });
}

export async function clearOfflineQueue(): Promise<void> {
  await transaction<void>("readwrite", (store, resolve, reject) => {
    const request = store.clear();
    request.onsuccess = () => resolve();
    request.onerror = () => reject(request.error);
  });
}

/** Remove only one owner's queued writes and locally cached data. */
export async function purgeOfflineOwnerData(owner: OfflineQueueOwner): Promise<void> {
  if (typeof indexedDB === "undefined") return;
  const database = await openDatabase();
  const tx = database.transaction([STORE, CYCLE_STORE, RESPONSE_STORE, SESSION_STORE], "readwrite");
  const mutations = tx.objectStore(STORE);
  const cycleProfiles = tx.objectStore(CYCLE_STORE);
  const responses = tx.objectStore(RESPONSE_STORE);
  const sessions = tx.objectStore(SESSION_STORE);
  const ownerRange = [owner.familyId, owner.userId];
  const allRequest = mutations.index(OWNER_INDEX).getAll(ownerRange);
  const responseRequest = responses.index(OWNER_INDEX).getAll(ownerRange);
  const sessionRequest = sessions.get("last-session");
  await new Promise<void>((resolve, reject) => {
    const purgeReady = () => {
      if (allRequest.readyState !== "done" || responseRequest.readyState !== "done" || sessionRequest.readyState !== "done") return;
      for (const mutation of allRequest.result as QueuedMutation[]) {
        if (belongsToOwner(mutation, owner)) mutations.delete(mutation.id);
      }
      for (const response of responseRequest.result as CachedApiResponse[]) {
        if (belongsToOwner(response, owner)) responses.delete(response.id);
      }
      const session = sessionRequest.result as CachedOfflineSession | undefined;
      if (session?.user.id === owner.userId && session.user.family_id === owner.familyId) {
        sessions.delete("last-session");
      }
      cycleProfiles.delete(ownerCacheKey(owner));
    };
    allRequest.onsuccess = purgeReady;
    responseRequest.onsuccess = purgeReady;
    sessionRequest.onsuccess = purgeReady;
    allRequest.onerror = () => reject(allRequest.error);
    responseRequest.onerror = () => reject(responseRequest.error);
    sessionRequest.onerror = () => reject(sessionRequest.error);
    tx.oncomplete = () => resolve();
    tx.onerror = () => reject(tx.error ?? new Error("Offline data could not be removed."));
    tx.onabort = () => reject(tx.error ?? new Error("Offline data removal was cancelled."));
  });
}

export async function markQueuedMutationFailed(id: string, message: string): Promise<void> {
  await transaction<void>("readwrite", (store, resolve, reject) => {
    const get = store.get(id);
    get.onsuccess = () => {
      const current = get.result as QueuedMutation | undefined;
      if (!current) {
        resolve();
        return;
      }
      const request = store.put({
        ...current,
        attempts: current.attempts + 1,
        lastError: message,
      });
      request.onsuccess = () => resolve();
      request.onerror = () => reject(request.error);
    };
    get.onerror = () => reject(get.error);
  });
}

export async function offlineQueueSummary(): Promise<{
  pending: number;
  failed: number;
  held: number;
}> {
  const [mutations, held] = await Promise.all([queuedMutations(), heldQueuedMutations()]);
  return {
    pending: mutations.length,
    failed: mutations.filter((mutation) => mutation.lastError !== null).length,
    held: held.length,
  };
}
