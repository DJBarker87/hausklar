import type { User } from "./types";
import {
  cacheApiResponse,
  cachedApiResponse,
  cachedApiResponses,
  enqueueMutation,
  currentOfflineQueueOwner,
  markQueuedMutationFailed,
  offlineQueueSummary,
  queuedMutations,
  removeQueuedMutation,
  updateCachedApiResponse,
  type QueuedFormDataPart,
} from "./offlineQueue";

export class ApiError extends Error {
  status: number;
  code: string | null;
  body: unknown;

  constructor(message: string, status: number, code: string | null = null, body: unknown = null) {
    super(message);
    this.name = "ApiError";
    this.status = status;
    this.code = code;
    this.body = body;
  }
}

export type ApiRequestInit = RequestInit & {
  timeoutMs?: number;
  /** Reuse the durable operation UUID when replaying an offline mutation. */
  offlineOperationId?: string;
  /** Observe whether a successful read came from the server or durable offline storage. */
  onReadSource?: (source: ApiReadSource) => void;
};
export type OfflineQueuedResult = { queued_offline: true };
export type ApiReadSource = "network" | "cache";

const DEFAULT_API_TIMEOUT_MS = 20_000;
const HAUSKLAR_WEB_VERSION = import.meta.env.VITE_APP_VERSION || "1.0.0";
type RefreshOutcome = "refreshed" | "failed" | "stale";
type TaggedRefreshRequest = {
  epoch: number;
  promise: Promise<Exclude<RefreshOutcome, "stale">>;
};
type AuthTransition = {
  epoch: number;
  settled: Promise<void>;
  settle: () => void;
};

export type AuthExpiredDetail = { epoch: number };

let authSessionEpoch = 0;
let installedIdentityKey: string | null = null;
let refreshRequest: TaggedRefreshRequest | null = null;
let authTransition: AuthTransition | null = null;
let flushRequest: Promise<void> | null = null;

type FinanceRequestCacheEntry = {
  epoch: number;
  expiresAt: number;
  promise: Promise<unknown>;
};

const FINANCE_REQUEST_CACHE_MS = 20_000;
const FINANCE_REQUEST_CACHE_LIMIT = 200;
const financeRequestCache = new Map<string, FinanceRequestCacheEntry>();
const sharedReadRequests = new Map<string, Promise<unknown>>();
const pendingReadCacheWrites = new Map<string, Promise<void>>();

function isFinancePath(path: string): boolean {
  return /^\/finance(?:\/|$)/.test(path);
}

function isReadOnlyFinanceCommand(
  path: string,
  method: string,
  body?: BodyInit | null,
): boolean {
  if (method === "GET" || method === "HEAD" || method === "OPTIONS") return true;
  if (method !== "POST") return false;
  if (/^\/finance\/analysis(?:\?|$)/.test(path) && typeof body === "string") {
    try {
      const request = JSON.parse(body) as { save_as?: unknown };
      return request.save_as == null;
    } catch {
      return false;
    }
  }
  return /^\/finance\/(?:forecasts\/overview(?:\?|$)|safe-to-spend(?:\?|$)|coach\/ask(?:\?|$)|shares\/preview(?:\?|$)|assets\/hl\/import-preview(?:\?|$)|imports\/preview(?:\?|$))/.test(path);
}

function trimFinanceRequestCache(): void {
  while (financeRequestCache.size > FINANCE_REQUEST_CACHE_LIMIT) {
    const oldestKey = financeRequestCache.keys().next().value;
    if (typeof oldestKey !== "string") return;
    financeRequestCache.delete(oldestKey);
  }
}

/**
 * Drop short-lived in-memory Finance request reuse. Durable offline reads are
 * stored separately in the owner-scoped response cache.
 */
export function invalidateFinanceRequestCache(pathPrefix?: string): void {
  if (!pathPrefix) {
    financeRequestCache.clear();
    return;
  }
  for (const [key] of financeRequestCache) {
    const separator = key.indexOf(":");
    const path = separator >= 0 ? key.slice(separator + 1) : key;
    if (path.startsWith(pathPrefix)) financeRequestCache.delete(key);
  }
}

function bumpAuthSessionEpoch(): number {
  // Cached Finance responses must never survive an identity transition, even
  // in memory. The epoch remains part of the key as a second line of defence.
  invalidateFinanceRequestCache();
  authSessionEpoch += 1;
  return authSessionEpoch;
}

export function getAuthSessionEpoch(): number {
  return authSessionEpoch;
}

function identityKey(user: Pick<User, "id" | "family_id"> | null): string | null {
  return user ? `${user.id}\u0000${user.family_id ?? ""}` : null;
}

/** Install the identity whose cookies and app state are now authoritative. */
export function installAuthIdentity(user: Pick<User, "id" | "family_id"> | null): number {
  const nextIdentityKey = identityKey(user);
  if (nextIdentityKey !== installedIdentityKey) {
    installedIdentityKey = nextIdentityKey;
    bumpAuthSessionEpoch();
  }
  return authSessionEpoch;
}

/** Clear an identity only if the caller still belongs to the expected generation. */
export function resetAuthIdentity(expectedEpoch?: number): boolean {
  if (expectedEpoch !== undefined && expectedEpoch !== authSessionEpoch) return false;
  installedIdentityKey = null;
  bumpAuthSessionEpoch();
  return true;
}

function isCurrentAuthEpoch(epoch: number): boolean {
  return epoch === authSessionEpoch;
}

function sameOfflineQueueOwner(
  left: ReturnType<typeof currentOfflineQueueOwner>,
  right: ReturnType<typeof currentOfflineQueueOwner>,
): boolean {
  return left?.userId === right?.userId
    && left?.familyId === right?.familyId
    && (left !== null) === (right !== null);
}

function beginAuthTransition(): { transition: AuthTransition; blockers: Promise<unknown>[] } {
  const epoch = bumpAuthSessionEpoch();
  const blockers: Promise<unknown>[] = [];
  if (refreshRequest) blockers.push(refreshRequest.promise);
  if (authTransition) blockers.push(authTransition.settled);
  let settle: () => void = () => {};
  const settled = new Promise<void>((resolve) => { settle = resolve; });
  const transition = { epoch, settled, settle };
  authTransition = transition;
  return { transition, blockers };
}

function finishAuthTransition(transition: AuthTransition): void {
  transition.settle();
  if (authTransition === transition) authTransition = null;
}

const NETWORK_ONLY_MUTATION_PATHS = [
  /^\/auth(?:\/|$)/,
  /^\/assistant(?:\/|$)/,
  /^\/capture\/parse(?:\?|$)/,
  // These return a reviewed proposal/search result to the caller and may use
  // bounded interpretation. Replaying them later without their review UI is
  // neither useful nor safe.
  /^\/commitments\/(?:from-source|free-windows\/query)(?:\?|$)/,
  /^\/home\/(?:actions|services)(?:\/|$)/,
  /^\/photos\/search(?:\?|$)/,
  /^\/yearbook\/[^/]+\/[^/]+\/refresh(?:\?|$)/,
  /^\/calendar\/sources\/[^/]+\/sync(?:\?|$)/,
  /^\/calendar\/feed\/rotate(?:\?|$)/,
  /^\/reminders\/(?:test|push)(?:\/|\?|$)/,
  // Catalogue credentials and live provider commands must never enter the
  // browser's durable offline mutation queue.
  /^\/library\/accounts(?:\/|\?|$)/,
  // Fitness owns a richer entity outbox and must not be double-queued here.
  /^\/fitness(?:\/|$)/,
  // These commands contact banks, providers, or reasoning services rather than
  // merely changing family-owned records.
  /^\/finance\/(?:analysis|coach|capture\/interpret|connections|forecasts\/overview|imports?\/(?:preview|confirm)|assets\/hl\/import-preview|safe-to-spend)(?:\/|\?|$)/,
  /^\/finance\/(?:patterns\/scan|reports\/[^/]+\/refresh|shares\/preview|product-prices\/rebuild)(?:\/|\?|$)/,
  /^\/finance\/assets\/(?:hl\/refresh-prices|sources\/[^/]+\/refresh)(?:\/|\?|$)/,
  /^\/finance\/email-addresses\/[^/]+\/(?:send-test|enrollments)(?:\/|\?|$)/,
  /^\/facilities\/example_school\/(?:preview|import)(?:\?|$)/,
  /^\/toast-club\/(?:preview|import)(?:\?|$)/,
];

// Only data with a deliberate offline workflow enters the generic durable
// cache. Fitness owns its richer IndexedDB store; Finance, auth, assistants,
// search, streams and live integrations stay out of browser persistence.
const OFFLINE_READ_CACHE_PATHS = [
  /^\/briefing\/(?:dashboard|glance)(?:\?|$)/,
  /^\/calendar(?:\/|\?|$)/,
  /^\/tasks(?:\/|\?|$)/,
  /^\/family(?:\/|\?|$)/,
  /^\/children(?:\/|\?|$)/,
  /^\/medicine(?:\/|\?|$)/,
  /^\/illness(?:\/|\?|$)/,
  /^\/naps(?:\/|\?|$)/,
  /^\/dog(?:\/|\?|$)/,
  /^\/routines(?:\/|\?|$)/,
  /^\/clubs(?:\/|\?|$)/,
  /^\/toast-club(?:\/|\?|$)/,
  /^\/meals(?:\/|\?|$)/,
  /^\/grocery(?:\/|\?|$)/,
  /^\/birthdays(?:\/|\?|$)/,
  /^\/homework(?:\/|\?|$)/,
  /^\/presents(?:\/|\?|$)/,
  /^\/renewals(?:\/|\?|$)/,
  /^\/library(?:\/|\?|$)/,
  /^\/documents(?:\/|\?|$)/,
  /^\/commitments(?:\/|\?|$)/,
  /^\/cycles(?:\/|\?|$)/,
  /^\/onboarding(?:\/|\?|$)/,
  /^\/workspace(?:\/|\?|$)/,
];

function persistentReadCacheKey(path: string, method: string, body?: BodyInit | null): string | null {
  if (
    method === "GET"
    && !body
    && OFFLINE_READ_CACHE_PATHS.some((pattern) => pattern.test(path))
  ) return path;
  return null;
}

async function durableCachedRead<T>(cacheKey: string): Promise<T | null> {
  await pendingReadCacheWrites.get(cacheKey)?.catch(() => undefined);
  return cachedApiResponse<T>(cacheKey);
}

function persistReadInBackground(cacheKey: string, value: unknown): void {
  const write = cacheApiResponse(cacheKey, value);
  pendingReadCacheWrites.set(cacheKey, write);
  void write.catch(() => undefined).finally(() => {
    if (pendingReadCacheWrites.get(cacheKey) === write) {
      pendingReadCacheWrites.delete(cacheKey);
    }
  });
}

export function isOfflineQueueable(path: string, method = "GET", body?: BodyInit | null): boolean {
  const normalised = method.toUpperCase();
  if (!["POST", "PUT", "PATCH", "DELETE"].includes(normalised)) return false;
  if (body != null && typeof body !== "string" && !(body instanceof FormData)) return false;
  return !NETWORK_ONLY_MUTATION_PATHS.some((pattern) => pattern.test(path));
}

function parseMutationBody(body: BodyInit | null): Record<string, unknown> {
  if (!body) return {};
  if (body instanceof FormData) {
    const result: Record<string, unknown> = {};
    for (const [key, value] of body.entries()) {
      if (typeof value === "string") result[key] = value;
    }
    return result;
  }
  if (typeof body !== "string") return {};
  try {
    const decoded = JSON.parse(body) as unknown;
    return decoded && typeof decoded === "object" && !Array.isArray(decoded)
      ? decoded as Record<string, unknown>
      : {};
  } catch {
    return {};
  }
}

function pathWithoutQuery(path: string): string {
  return path.split("?", 1)[0]!.replace(/\/$/, "");
}

function mutationRecordID(path: string, data: Record<string, unknown>, operationId: string): string {
  if (typeof data.id === "string" && data.id) return data.id;
  if (typeof data.client_id === "string" && data.client_id) return data.client_id;
  if (typeof data.document_id === "string" && data.document_id) return data.document_id;
  if (typeof data.source_id === "string" && data.source_id) return data.source_id;
  const segments = pathWithoutQuery(path).split("/").filter(Boolean);
  if (segments[0] === "family" && segments[1] === "members" && segments[2] && segments[3] === "avatar") {
    return segments[2];
  }
  const actionNames = new Set(["complete", "reopen", "check", "end", "renewed", "score", "accept", "dismiss"]);
  const last = segments.at(-1);
  if (last && !actionNames.has(last) && !["start", "doses", "types", "temperature", "activities", "vaccinations", "reading", "spellings", "ideas", "shopping", "plan"].includes(last)) {
    return last;
  }
  if (last && actionNames.has(last) && segments.length > 1) return segments.at(-2)!;
  return operationId;
}

async function cachedEntity(recordId: string): Promise<Record<string, unknown> | null> {
  for (const entry of await cachedApiResponses()) {
    const values: unknown[] = Array.isArray(entry.value)
      ? entry.value
      : entry.value && typeof entry.value === "object"
        ? [entry.value, ...Object.values(entry.value as Record<string, unknown>)]
        : [];
    for (const value of values) {
      if (Array.isArray(value)) {
        const match = value.find((item) => item && typeof item === "object" && (item as { id?: unknown }).id === recordId);
        if (match && typeof match === "object") return match as Record<string, unknown>;
      } else if (value && typeof value === "object" && (value as { id?: unknown }).id === recordId) {
        return value as Record<string, unknown>;
      }
    }
  }
  return null;
}

type LocalMedicineWarning = {
  type: "too_soon" | "max_reached";
  message: string;
  next_safe_at: string | null;
};

async function offlineMedicineWarnings(data: Record<string, unknown>): Promise<LocalMedicineWarning[]> {
  const medicineTypeId = typeof data.medicine_type_id === "string" ? data.medicine_type_id : null;
  const childId = typeof data.child_id === "string" ? data.child_id : null;
  const givenAt = typeof data.given_at === "string" ? new Date(data.given_at) : null;
  if (!medicineTypeId || !childId || !givenAt || Number.isNaN(givenAt.getTime())) return [];

  let medicineType: Record<string, unknown> | null = null;
  const dosesByID = new Map<string, Record<string, unknown>>();
  for (const entry of await cachedApiResponses()) {
    const values = Array.isArray(entry.value) ? entry.value : [];
    if (pathWithoutQuery(entry.path).startsWith("/medicine/types")) {
      const match = values.find((item) => item && typeof item === "object" && (item as { id?: unknown }).id === medicineTypeId);
      if (match && typeof match === "object") medicineType = match as Record<string, unknown>;
    }
    if (pathWithoutQuery(entry.path).startsWith("/medicine/doses")) {
      for (const item of values) {
        if (!item || typeof item !== "object") continue;
        const dose = item as Record<string, unknown>;
        if (dose.medicine_type_id !== medicineTypeId || dose.child_id !== childId) continue;
        const key = typeof dose.id === "string"
          ? dose.id
          : `${String(dose.given_at)}\0${String(dose.dose_amount)}`;
        dosesByID.set(key, dose);
      }
    }
  }
  if (!medicineType) return [];

  const minHours = Number(medicineType.min_hours_between_doses);
  const maxDoses = Number(medicineType.max_doses_24h);
  const proposedMs = givenAt.getTime();
  const doseTimes = [...dosesByID.values()]
    .map((dose) => typeof dose.given_at === "string" ? new Date(dose.given_at).getTime() : Number.NaN)
    .filter(Number.isFinite)
    .sort((left, right) => left - right);
  const warnings: LocalMedicineWarning[] = [];
  if (Number.isFinite(minHours) && minHours > 0) {
    const minMs = minHours * 3_600_000;
    const previous = doseTimes.filter((time) => time <= proposedMs).at(-1);
    const next = doseTimes.find((time) => time > proposedMs);
    if (previous !== undefined && proposedMs - previous < minMs) {
      const hours = (proposedMs - previous) / 3_600_000;
      warnings.push({
        type: "too_soon",
        message: `Only ${hours.toFixed(1)}h since last dose. Minimum interval is ${minHours}h.`,
        next_safe_at: new Date(previous + minMs).toISOString(),
      });
    } else if (next !== undefined && next - proposedMs < minMs) {
      const hours = (next - proposedMs) / 3_600_000;
      warnings.push({
        type: "too_soon",
        message: `A dose already exists ${hours.toFixed(1)}h after this time. Minimum interval is ${minHours}h.`,
        next_safe_at: new Date(proposedMs + minMs).toISOString(),
      });
    }
  }
  if (Number.isFinite(maxDoses) && maxDoses > 0) {
    const dayMs = 86_400_000;
    const nearby = doseTimes.filter((time) => proposedMs - dayMs <= time && time <= proposedMs + dayMs);
    const windowEnds = [proposedMs, ...nearby.filter((time) => time >= proposedMs)];
    const count = Math.max(...windowEnds.map((end) => nearby.filter((time) => end - dayMs <= time && time <= end).length));
    if (count >= maxDoses) {
      warnings.push({
        type: "max_reached",
        message: `A 24-hour window containing this dose already has ${count} dose(s). Maximum is ${maxDoses}.`,
        next_safe_at: null,
      });
    }
  }
  return warnings;
}

async function optimisticQueuedResponse<T>(
  path: string,
  method: string,
  body: BodyInit | null,
  operationId: string,
): Promise<T> {
  const data = parseMutationBody(body);
  const now = new Date().toISOString();
  const id = mutationRecordID(path, data, operationId);
  const existing = await cachedEntity(id) ?? {};
  const queued = { queued_offline: true, offline_operation_id: operationId };
  if (method === "DELETE") return queued as T;
  if (path === "/cycles/settings") return { ...existing, ...data, ...queued } as T;
  if (path === "/cycles/periods") {
    return { id, created_at: now, updated_at: now, ...existing, ...data, ...queued } as T;
  }
  if (path.startsWith("/cycles/periods/")) return queued as T;
  const action = pathWithoutQuery(path).split("/").filter(Boolean).at(-1);
  const actionFields: Record<string, unknown> = {};
  if (action === "complete") actionFields.completed_at = now;
  if (action === "reopen") actionFields.completed_at = null;
  if (action === "end") actionFields.ended_at = typeof data.ended_at === "string" ? data.ended_at : now;
  if (action === "check") actionFields.checked = !(existing.checked === true);

  const entity: Record<string, unknown> = {
    id,
    created_at: typeof existing.created_at === "string" ? existing.created_at : now,
    updated_at: now,
    ...existing,
    ...data,
    ...actionFields,
    ...queued,
  };
  if (path === "/tasks/") {
    Object.assign(entity, {
      category: entity.category ?? "other",
      priority: entity.priority ?? 2,
      assignees: entity.assignees ?? [],
    });
  }
  if (path === "/calendar/") {
    entity.all_day = entity.all_day ?? false;
  }
  if (path === "/naps/start") {
    Object.assign(entity, {
      started_at: entity.started_at ?? now,
      ended_at: null,
      sleep_type: entity.sleep_type ?? "nap",
      duration_minutes: null,
    });
  }
  if (path === "/medicine/doses") {
    const dose = {
      ...entity,
      given_at: entity.given_at ?? now,
      given_by: entity.given_by ?? "Saved offline",
    };
    return { dose, warnings: await offlineMedicineWarnings(data), ...queued } as T;
  }
  if (path === "/child-photos/") return { photos: [], ...queued } as T;
  entity.checked = entity.checked ?? false;
  return entity as T;
}

export function isOfflineQueuedResult(value: unknown): value is OfflineQueuedResult {
  return Boolean(
    value
      && typeof value === "object"
      && "queued_offline" in value
      && (value as OfflineQueuedResult).queued_offline === true,
  );
}

function announceQueueChanged(detail?: { queued?: boolean; synced?: number }) {
  window.dispatchEvent(new CustomEvent("hausklar:queue-changed", { detail }));
}

function collectionPrefixForMutation(path: string): string {
  const clean = pathWithoutQuery(path);
  if (clean === "/naps/start" || /^\/naps\/[^/]+\/(?:end)$/.test(clean)) return "/naps";
  if (/^\/tasks\/[^/]+\/(?:complete|reopen)(?:\/[^/]+)?$/.test(clean)) return "/tasks";
  if (/^\/meals\/shopping(?:\/|$)/.test(clean)) return "/meals/shopping";
  if (/^\/medicine\/doses(?:\/|$)/.test(clean)) return "/medicine/doses";
  if (/^\/medicine\/types(?:\/|$)/.test(clean)) return "/medicine/types";
  if (/^\/illness\/temperature(?:\/|$)/.test(clean)) return "/illness/temperature";
  const segments = clean.split("/").filter(Boolean);
  if (segments.length <= 1) return clean;
  const last = segments.at(-1)!;
  if (["start", "doses", "types", "temperature", "activities", "vaccinations", "reading", "spellings", "ideas", "shopping", "plan"].includes(last)) return clean;
  return `/${segments.slice(0, -1).join("/")}`;
}

function optimisticEntity(value: unknown): Record<string, unknown> | null {
  if (!value || typeof value !== "object") return null;
  const object = value as Record<string, unknown>;
  if (object.dose && typeof object.dose === "object") return object.dose as Record<string, unknown>;
  return object;
}

async function applyOptimisticMutationToCache(
  path: string,
  method: string,
  optimistic: unknown,
): Promise<void> {
  const entity = optimisticEntity(optimistic);
  const recordId = typeof entity?.id === "string" ? entity.id : null;
  const prefix = collectionPrefixForMutation(path);
  const cleanMutationPath = pathWithoutQuery(path);
  for (const entry of await cachedApiResponses()) {
    const cleanCachedPath = pathWithoutQuery(entry.path);
    const related = cleanCachedPath.startsWith(prefix)
      || prefix.startsWith(cleanCachedPath)
      || cleanCachedPath === cleanMutationPath;
    if (!related) continue;
    let next = entry.value;
    if (Array.isArray(entry.value) && recordId) {
      if (method === "DELETE") {
        next = entry.value.filter((item) => !(item && typeof item === "object" && (item as { id?: unknown }).id === recordId));
      } else {
        const index = entry.value.findIndex((item) => item && typeof item === "object" && (item as { id?: unknown }).id === recordId);
        if (index >= 0) {
          next = entry.value.map((item, itemIndex) => itemIndex === index ? { ...(item as object), ...entity } : item);
        } else if (cleanCachedPath.startsWith(prefix)) {
          next = [entity, ...entry.value];
        }
      }
    } else if (entry.value && typeof entry.value === "object" && recordId) {
      const object = entry.value as Record<string, unknown>;
      if (object.id === recordId && method !== "DELETE") next = { ...object, ...entity };
      else {
        let changed = false;
        const patched = { ...object };
        for (const [key, child] of Object.entries(object)) {
          if (!Array.isArray(child)) continue;
          const index = child.findIndex((item) => item && typeof item === "object" && (item as { id?: unknown }).id === recordId);
          if (index < 0) continue;
          patched[key] = method === "DELETE"
            ? child.filter((_item, itemIndex) => itemIndex !== index)
            : child.map((item, itemIndex) => itemIndex === index ? { ...(item as object), ...entity } : item);
          changed = true;
        }
        if (changed) next = patched;
      }
    }
    if (next !== entry.value) await updateCachedApiResponse(entry.path, next);
  }
}

async function queueOfflineMutation<T>(
  path: string,
  init: RequestInit,
  operationId: string,
): Promise<T> {
  if (typeof indexedDB === "undefined") {
    throw new ApiError("Offline storage is unavailable in this browser.", 503);
  }
  const requestBody = init.body ?? null;
  const body = typeof requestBody === "string" ? requestBody : null;
  const formData = requestBody instanceof FormData ? serialiseFormData(requestBody) : null;
  const method = (init.method ?? "POST").toUpperCase();
  await enqueueMutation({ id: operationId, path, method, body, formData });
  const optimistic = await optimisticQueuedResponse<T>(path, method, requestBody, operationId);
  await applyOptimisticMutationToCache(path, method, optimistic);
  window.setTimeout(() => announceQueueChanged({ queued: true }), 0);
  return optimistic;
}

function serialiseFormData(form: FormData): QueuedFormDataPart[] {
  return [...form.entries()].map(([name, value]) => typeof value === "string"
    ? { name, value }
    : { name, value, filename: value.name });
}

async function restoreFormData(parts: QueuedFormDataPart[]): Promise<FormData> {
  const form = new FormData();
  for (const part of parts) {
    if (typeof part.value === "string") form.append(part.name, part.value);
    else {
      const stored = part.value as unknown;
      let value: Blob;
      if (stored instanceof Blob) {
        value = stored;
      } else if (
        stored
        && typeof stored === "object"
        && "arrayBuffer" in stored
        && typeof stored.arrayBuffer === "function"
      ) {
        const persisted = stored as { arrayBuffer: () => Promise<ArrayBuffer>; type?: string };
        value = new Blob([await persisted.arrayBuffer()], { type: persisted.type ?? "" });
      } else {
        value = new Blob([stored as BlobPart]);
      }
      if (part.filename) form.append(part.name, value, part.filename);
      else form.append(part.name, value);
    }
  }
  return form;
}

function installMultipartReplayIDs(path: string, body: FormData, operationId: string): void {
  const cleanPath = pathWithoutQuery(path);
  if (cleanPath === "/documents" && !body.get("document_id")) body.set("document_id", operationId);
  if (cleanPath === "/artworks" && !body.get("client_id")) body.set("client_id", operationId);
  if (cleanPath === "/finance/purchases/evidence/upload" && !body.get("source_id")) body.set("source_id", operationId);
  if (/^\/family\/members\/[^/]+\/avatar$/.test(cleanPath) && !body.get("operation_id")) {
    body.set("operation_id", operationId);
  }
  if (cleanPath === "/child-photos") {
    const files = body.getAll("files").length;
    const ids = body.getAll("client_id").length;
    for (let index = ids; index < files; index += 1) body.append("client_id", `${operationId}-${index + 1}`);
  }
}

async function fetchWithTimeout(
  input: RequestInfo | URL,
  init: RequestInit,
  timeoutMs: number,
): Promise<Response> {
  const controller = new AbortController();
  let timedOut = false;
  const abortFromCaller = () => controller.abort(init.signal?.reason);
  if (init.signal?.aborted) abortFromCaller();
  else init.signal?.addEventListener("abort", abortFromCaller, { once: true });
  const timeout = window.setTimeout(() => {
    timedOut = true;
    controller.abort();
  }, timeoutMs);

  try {
    return await fetch(input, { ...init, signal: controller.signal });
  } catch (error) {
    if (timedOut) {
      throw new ApiError("HausKlar took too long to respond. Please try again.", 408);
    }
    throw error;
  } finally {
    window.clearTimeout(timeout);
    init.signal?.removeEventListener("abort", abortFromCaller);
  }
}

async function rotateWebSession(epoch: number): Promise<RefreshOutcome> {
  if (!isCurrentAuthEpoch(epoch) || authTransition?.epoch === epoch) return "stale";

  const existing = refreshRequest;
  if (existing?.epoch === epoch) return existing.promise;
  if (existing) {
    // Do not reuse an older generation's result, but let its cookie response
    // settle before issuing another cookie-writing refresh request.
    await existing.promise;
    if (!isCurrentAuthEpoch(epoch) || authTransition?.epoch === epoch) return "stale";
    return rotateWebSession(epoch);
  }

  let taggedRequest: TaggedRefreshRequest;
  const promise = fetchWithTimeout(
    "/api/auth/web/refresh",
    { method: "POST", credentials: "same-origin" },
    15_000,
  )
    .then((response): Exclude<RefreshOutcome, "stale"> => response.ok ? "refreshed" : "failed")
    .catch((): Exclude<RefreshOutcome, "stale"> => "failed")
    .finally(() => {
      if (refreshRequest === taggedRequest) refreshRequest = null;
    });
  taggedRequest = { epoch, promise };
  refreshRequest = taggedRequest;
  return promise;
}

async function parseResponse<T>(response: Response): Promise<T> {
  if (response.status === 204) return undefined as T;
  const contentType = response.headers.get("content-type") ?? "";
  if (contentType.includes("application/json")) return (await response.json()) as T;
  return (await response.text()) as T;
}

async function apiAtEpoch<T>(
  path: string,
  init: ApiRequestInit = {},
  retry = true,
  allowOfflineQueue = true,
  requestEpoch: number,
  requestQueueOwner = currentOfflineQueueOwner(),
): Promise<T> {
  const {
    timeoutMs = DEFAULT_API_TIMEOUT_MS,
    offlineOperationId,
    onReadSource,
    ...requestInit
  } = init;
  const headers = new Headers(requestInit.headers);
  headers.set("X-HausKlar-Client", "web");
  headers.set("X-HausKlar-App-Version", HAUSKLAR_WEB_VERSION);
  if (requestInit.body && !(requestInit.body instanceof FormData) && !headers.has("Content-Type")) {
    headers.set("Content-Type", "application/json");
  }
  const method = (requestInit.method ?? "GET").toUpperCase();
  const readCacheKey = persistentReadCacheKey(path, method, requestInit.body);
  const mutationEligible = isOfflineQueueable(path, method, requestInit.body);
  const operationId = mutationEligible ? offlineOperationId ?? crypto.randomUUID() : null;
  if (operationId && requestInit.body instanceof FormData) {
    installMultipartReplayIDs(path, requestInit.body, operationId);
  }
  if (operationId) headers.set("X-HausKlar-Operation-ID", operationId);
  const request = { ...requestInit, headers, credentials: "same-origin" as RequestCredentials };
  const queueable = allowOfflineQueue && mutationEligible;
  if (readCacheKey && !navigator.onLine && !path.startsWith("/auth/")) {
    const cached = await durableCachedRead<T>(readCacheKey);
    if (cached !== null) {
      onReadSource?.("cache");
      return cached;
    }
  }
  if (queueable && !navigator.onLine && operationId) {
    return queueOfflineMutation<T>(path, request, operationId);
  }
  let response: Response;
  try {
    response = await fetchWithTimeout(`/api${path}`, request, timeoutMs);
  } catch (error) {
    const canFallBackOffline = error instanceof TypeError
      || (error instanceof ApiError && error.status === 408);
    if (
      queueable
      && canFallBackOffline
      && isCurrentAuthEpoch(requestEpoch)
      && sameOfflineQueueOwner(requestQueueOwner, currentOfflineQueueOwner())
      && operationId
    ) {
      return queueOfflineMutation<T>(path, request, operationId);
    }
    if (
      readCacheKey !== null
      && canFallBackOffline
      && isCurrentAuthEpoch(requestEpoch)
      && sameOfflineQueueOwner(requestQueueOwner, currentOfflineQueueOwner())
      && !path.startsWith("/auth/")
    ) {
      const cached = await durableCachedRead<T>(readCacheKey);
      if (cached !== null) {
        onReadSource?.("cache");
        return cached;
      }
    }
    throw error;
  }

  const canRotateBrowserSession = !path.startsWith("/auth/web/")
    || path === "/auth/web/session"
    || path === "/auth/web/change-password";
  if (response.status === 401 && retry && canRotateBrowserSession) {
    // A response from an older identity must never refresh, retry, or expire
    // the identity that has since been installed.
    if (isCurrentAuthEpoch(requestEpoch)) {
      const refreshOutcome = await rotateWebSession(requestEpoch);
      if (isCurrentAuthEpoch(requestEpoch)) {
        if (refreshOutcome === "refreshed") {
          if (isCurrentAuthEpoch(requestEpoch)) {
            return apiAtEpoch<T>(
              path,
              init,
              false,
              allowOfflineQueue,
              requestEpoch,
              requestQueueOwner,
            );
          }
        } else if (refreshOutcome === "failed" && isCurrentAuthEpoch(requestEpoch)) {
          window.dispatchEvent(new CustomEvent<AuthExpiredDetail>("hausklar:auth-expired", {
            detail: { epoch: requestEpoch },
          }));
        }
      }
    }
  }
  if (!response.ok) {
    const body = await parseResponse<{
      detail?: unknown;
      message?: unknown;
      status?: string;
      code?: string;
    } | string>(response);
    const detail = typeof body === "string" ? null : body.detail;
    const detailObject = detail && typeof detail === "object"
      ? detail as { message?: unknown; status?: unknown; code?: unknown }
      : null;
    const messageCandidate = typeof body === "string"
      ? body
      : typeof detail === "string"
        ? detail
        : typeof body.message === "string"
          ? body.message
          : typeof detailObject?.message === "string"
            ? detailObject.message
            : null;
    const codeCandidate = typeof body === "string"
      ? null
      : body.status ?? body.code ?? detailObject?.status ?? detailObject?.code;
    const code = typeof codeCandidate === "string" ? codeCandidate : null;
    throw new ApiError(
      messageCandidate || "HausKlar could not complete that request.",
      response.status,
      code,
      body,
    );
  }
  // A successful response can still belong to an identity that was replaced
  // while the request was in flight. Do not hand that result back to an async
  // workflow: it could otherwise use it to start a second request with the new
  // account's cookies (for example upload A's document, then create B's event).
  if (!isCurrentAuthEpoch(requestEpoch)) {
    throw new ApiError("This request belonged to an older signed-in session.", 409);
  }
  const result = await parseResponse<T>(response);
  if (!isCurrentAuthEpoch(requestEpoch)) {
    throw new ApiError("This request belonged to an older signed-in session.", 409);
  }
  if (readCacheKey && !path.startsWith("/auth/")) {
    persistReadInBackground(readCacheKey, result);
  }
  onReadSource?.("network");
  return result;
}

function observeCachedFinanceRequest<T>(promise: Promise<T>, signal?: AbortSignal | null): Promise<T> {
  if (!signal) return promise;
  if (signal.aborted) return Promise.reject(new DOMException("Aborted", "AbortError"));
  return new Promise<T>((resolve, reject) => {
    const abort = () => reject(new DOMException("Aborted", "AbortError"));
    signal.addEventListener("abort", abort, { once: true });
    promise.then(resolve, reject).finally(() => signal.removeEventListener("abort", abort));
  });
}

function cachedFinanceRead<T>(
  path: string,
  init: ApiRequestInit,
  retry: boolean,
  allowOfflineQueue: boolean,
  requestEpoch: number,
  requestQueueOwner: ReturnType<typeof currentOfflineQueueOwner>,
): Promise<T> {
  const cacheKey = `${requestEpoch}:${path}`;
  const now = Date.now();
  if (init.cache === "reload") financeRequestCache.delete(cacheKey);
  const cached = financeRequestCache.get(cacheKey);
  if (cached && cached.epoch === requestEpoch && cached.expiresAt > now) {
    // Refresh insertion order so the bounded cache behaves like a small LRU.
    financeRequestCache.delete(cacheKey);
    financeRequestCache.set(cacheKey, cached);
    return observeCachedFinanceRequest(cached.promise as Promise<T>, init.signal);
  }
  if (cached) financeRequestCache.delete(cacheKey);

  // A component leaving the screen should stop observing this request without
  // cancelling a same-scope request that another Finance screen is reusing.
  const sharedInit = { ...init };
  delete sharedInit.signal;
  const entry: FinanceRequestCacheEntry = {
    epoch: requestEpoch,
    expiresAt: Number.POSITIVE_INFINITY,
    promise: Promise.resolve(undefined),
  };
  const request = apiAtEpoch<T>(
    path,
    sharedInit,
    retry,
    allowOfflineQueue,
    requestEpoch,
    requestQueueOwner,
  )
    .then((result) => {
      if (financeRequestCache.get(cacheKey) === entry) {
        entry.expiresAt = Date.now() + FINANCE_REQUEST_CACHE_MS;
      }
      return result;
    })
    .catch((error: unknown) => {
      if (financeRequestCache.get(cacheKey) === entry) financeRequestCache.delete(cacheKey);
      throw error;
    });
  entry.promise = request;
  financeRequestCache.set(cacheKey, entry);
  trimFinanceRequestCache();
  return observeCachedFinanceRequest(request, init.signal);
}

export async function api<T>(
  path: string,
  init: ApiRequestInit = {},
  retry = true,
  allowOfflineQueue = true,
): Promise<T> {
  const requestEpoch = authSessionEpoch;
  const requestQueueOwner = currentOfflineQueueOwner();
  const method = (init.method ?? "GET").toUpperCase();
  const headers = new Headers(init.headers);
  const cacheableFinanceRead = isFinancePath(path)
    && method === "GET"
    && !init.body
    && !init.onReadSource
    && headers.keys().next().done
    && init.cache !== "no-store";
  if (cacheableFinanceRead) {
    return cachedFinanceRead<T>(
      path,
      init,
      retry,
      allowOfflineQueue,
      requestEpoch,
      requestQueueOwner,
    );
  }
  const shareableRead = method === "GET"
    && !init.body
    && !init.signal
    && !init.onReadSource
    && headers.keys().next().done
    && init.cache !== "reload"
    && init.cache !== "no-store";
  if (shareableRead) {
    const key = `${requestEpoch}:${path}`;
    const existing = sharedReadRequests.get(key);
    if (existing) return existing as Promise<T>;
    const request = apiAtEpoch<T>(
      path,
      init,
      retry,
      allowOfflineQueue,
      requestEpoch,
      requestQueueOwner,
    );
    sharedReadRequests.set(key, request);
    void request.finally(() => {
      if (sharedReadRequests.get(key) === request) sharedReadRequests.delete(key);
    }).catch(() => undefined);
    return request;
  }
  const result = await apiAtEpoch<T>(path, init, retry, allowOfflineQueue, requestEpoch, requestQueueOwner);
  if (isFinancePath(path) && !isReadOnlyFinanceCommand(path, method, init.body)) {
    invalidateFinanceRequestCache();
  }
  return result;
}

export async function flushOfflineQueue(): Promise<void> {
  if (flushRequest) return flushRequest;
  flushRequest = (async () => {
    if (!navigator.onLine || typeof indexedDB === "undefined") return;
    const owner = currentOfflineQueueOwner();
    if (!owner) return;
    let synced = 0;
    for (const mutation of await queuedMutations()) {
      const currentOwner = currentOfflineQueueOwner();
      if (
        !currentOwner
        || currentOwner.userId !== owner.userId
        || currentOwner.familyId !== owner.familyId
      ) break;
      try {
        await api(
          mutation.path,
          {
            method: mutation.method,
            body: mutation.formData?.length
              ? await restoreFormData(mutation.formData)
              : mutation.body ?? undefined,
            offlineOperationId: mutation.id,
          },
          true,
          false,
        );
        const ownerAfterRequest = currentOfflineQueueOwner();
        if (
          !ownerAfterRequest
          || ownerAfterRequest.userId !== owner.userId
          || ownerAfterRequest.familyId !== owner.familyId
        ) break;
        await removeQueuedMutation(mutation.id);
        synced += 1;
      } catch (error) {
        const ownerAfterError = currentOfflineQueueOwner();
        if (
          !ownerAfterError
          || ownerAfterError.userId !== owner.userId
          || ownerAfterError.familyId !== owner.familyId
        ) break;
        if (error instanceof ApiError && error.status >= 400 && error.status < 500 && error.status !== 408) {
          await markQueuedMutationFailed(mutation.id, error.message);
          continue;
        }
        break;
      }
    }
    announceQueueChanged({ synced });
  })().finally(() => { flushRequest = null; });
  return flushRequest;
}

export { offlineQueueSummary };

export async function login(email: string, password: string): Promise<User> {
  return startWebSession("/auth/web/login", { email, password });
}

async function startWebSession(path: string, body: Record<string, string>): Promise<User> {
  const { transition, blockers } = beginAuthTransition();
  try {
    // A refresh that started for the previous identity must finish before the
    // login response is allowed to install a newer cookie.
    await Promise.all(blockers);
    if (!isCurrentAuthEpoch(transition.epoch)) {
      throw new ApiError("This sign-in was superseded by a newer session change.", 409);
    }
    const user = await apiAtEpoch<User>(
      path,
      { method: "POST", body: JSON.stringify(body) },
      false,
      true,
      transition.epoch,
    );
    if (!isCurrentAuthEpoch(transition.epoch)) {
      throw new ApiError("This sign-in was superseded by a newer session change.", 409);
    }
    installAuthIdentity(user);
    return user;
  } finally {
    finishAuthTransition(transition);
  }
}

export async function registerFamily(
  familyName: string,
  userName: string,
  email: string,
  password: string,
): Promise<User> {
  return startWebSession("/auth/web/register-family", {
    family_name: familyName, user_name: userName, email, password,
  });
}

export async function joinFamily(
  inviteCode: string,
  userName: string,
  email: string,
  password: string,
): Promise<User> {
  return startWebSession("/auth/web/join-family", {
    invite_code: inviteCode, user_name: userName, email, password,
  });
}

export async function session(): Promise<User> {
  const requestEpoch = authSessionEpoch;
  const user = await apiAtEpoch<User>("/auth/web/session", {}, true, true, requestEpoch);
  if (!isCurrentAuthEpoch(requestEpoch)) {
    throw new ApiError("This session restore was superseded by a newer session change.", 409);
  }
  // The AuthProvider installs the returned identity. Keeping this fetch side-effect
  // free lets React's development double-mount (and ordinary duplicate callers)
  // complete the same valid restore without the first response invalidating the
  // second response's session epoch.
  return user;
}

export async function logout(): Promise<void> {
  const { transition, blockers } = beginAuthTransition();
  try {
    await Promise.all(blockers);
    if (!isCurrentAuthEpoch(transition.epoch)) return;
    await apiAtEpoch<void>(
      "/auth/web/logout",
      { method: "POST" },
      false,
      true,
      transition.epoch,
    );
  } finally {
    if (isCurrentAuthEpoch(transition.epoch)) installAuthIdentity(null);
    finishAuthTransition(transition);
  }
}

export async function requestPasswordReset(email: string): Promise<void> {
  await api<{ message: string }>(
    "/auth/forgot-password",
    { method: "POST", body: JSON.stringify({ email }) },
    false,
  );
}

export async function resetPassword(token: string, newPassword: string): Promise<void> {
  await api<void>(
    "/auth/reset-password",
    { method: "POST", body: JSON.stringify({ token, new_password: newPassword }) },
    false,
  );
}

export function localISODate(date: Date): string {
  const year = date.getFullYear();
  const month = String(date.getMonth() + 1).padStart(2, "0");
  const day = String(date.getDate()).padStart(2, "0");
  return `${year}-${month}-${day}`;
}

export function localISODateTime(date: Date): string {
  const offset = -date.getTimezoneOffset();
  const sign = offset >= 0 ? "+" : "-";
  const hours = String(Math.floor(Math.abs(offset) / 60)).padStart(2, "0");
  const minutes = String(Math.abs(offset) % 60).padStart(2, "0");
  const time = `${String(date.getHours()).padStart(2, "0")}:${String(date.getMinutes()).padStart(2, "0")}:00`;
  return `${localISODate(date)}T${time}${sign}${hours}:${minutes}`;
}
