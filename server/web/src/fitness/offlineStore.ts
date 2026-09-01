import { ApiError, api } from "../api";
import { currentOfflineQueueOwner, type OfflineQueueOwner } from "../offlineQueue";
import packageMetadata from "../../package.json";
import { foodLogEntryIsOnDate } from "./nutrition";
import {
  FITNESS_CLIENT_SCHEMA_VERSION,
  FITNESS_PAYLOAD_SCHEMA_VERSIONS,
  FITNESS_SYNC_PROTOCOL_VERSION,
  type FitnessEntityType,
  type FitnessImportResult,
  type FitnessMutationOperation,
  type FitnessFoodLogEntry,
  type FitnessProgressCharts,
  type FitnessPlannedHouseholdMeal,
  type FitnessPrivatePlannedMealLog,
  type FitnessPrivateAssetUploadResult,
  type FitnessProgressPhoto,
  type FitnessProgressPhotoPose,
  type FitnessSyncChange,
  type FitnessSyncMutation,
  type FitnessSyncNotice,
  type FitnessSyncRedirect,
  type FitnessSyncResponse,
  type FitnessSnapshotResponse,
} from "./contract";

const DATABASE = "hausklar-fitness";
const DATABASE_VERSION = 6;
const RECORDS_STORE = "records";
const OUTBOX_STORE = "outbox";
const META_STORE = "meta";
const NOTICES_STORE = "notices";
const IMPORTS_STORE = "imports";
const PROGRESS_PHOTOS_STORE = "progressPhotos";
const NUTRITION_LABELS_STORE = "nutritionLabels";
const PLANNED_MEAL_LOGS_STORE = "plannedMealLogs";
const DEVICE_ID_KEY = "hausklar:fitness-device-id";
const OWNER_INDEX = "by-owner";
const OWNER_ENTITY_INDEX = "by-owner-entity";

type FitnessLocalRecord = {
  key: string;
  ownerKey: string;
  entityType: FitnessEntityType;
  entityId: string;
  revision: number | null;
  payload: Record<string, unknown>;
  deleted: boolean;
  updatedAt: string;
};

type FitnessOutboxEntry = {
  key: string;
  ownerKey: string;
  mutation: FitnessSyncMutation;
  attempts: number;
  lastError: string | null;
};

type FitnessMetaRecord = {
  key: string;
  ownerKey: string;
  name: string;
  value: unknown;
};

type FitnessNoticeRecord = FitnessSyncNotice & {
  key: string;
  ownerKey: string;
};

type FitnessPendingImportRecord = {
  key: string;
  ownerKey: string;
  id: string;
  fileName: string;
  fileSize: number;
  fileType: string;
  fileLastModified: number;
  fileBlob: Blob | null;
  status: "queued" | "uploading" | "processing" | "complete" | "error";
  serverImportId: string | null;
  activityId: string | null;
  sourceRetained: boolean;
  sourceRecordId: string | null;
  error: string | null;
  retryable: boolean;
  attempts: number;
  createdAt: string;
  updatedAt: string;
};

type FitnessProgressPhotoQueueState =
  | "pending_upload"
  | "uploading"
  | "uploaded_waiting_metadata"
  | "saving_metadata"
  | "ready"
  | "error";

type FitnessProgressPhotoRecord = {
  key: string;
  ownerKey: string;
  id: string;
  originalAssetId: string;
  fileName: string;
  fileSize: number;
  fileType: string;
  fileLastModified: number;
  fileBlob: Blob | null;
  photo: FitnessProgressPhoto;
  state: FitnessProgressPhotoQueueState;
  uploadAcknowledged: boolean;
  metadataAcknowledged: boolean;
  error: string | null;
  retryable: boolean;
  attempts: number;
  createdAt: string;
  updatedAt: string;
};

type FitnessNutritionLabelQueueState =
  | "pending_upload"
  | "uploading"
  | "uploaded_waiting_reference"
  | "ready"
  | "error";

type FitnessNutritionLabelRecord = {
  key: string;
  ownerKey: string;
  id: string;
  assetId: string;
  dependentEntityType: "food" | "food_version";
  dependentEntityId: string;
  dependentMutationId: string;
  fileName: string;
  fileSize: number;
  fileType: string;
  fileLastModified: number;
  fileBlob: Blob | null;
  state: FitnessNutritionLabelQueueState;
  uploadAcknowledged: boolean;
  dependentAcknowledged: boolean;
  error: string | null;
  attempts: number;
  createdAt: string;
  updatedAt: string;
};

type FitnessPlannedMealLogRecord = {
  key: string;
  ownerKey: string;
  id: string;
  meal: FitnessPlannedHouseholdMeal;
  portion: number;
  unit: "serving" | "g";
  loggedAtUtc: string;
  localTimezone: string;
  notes: string | null;
  clientId: string | null;
  clientTimestamp: string | null;
  attempts: number;
  lastError: string | null;
  createdAt: string;
  updatedAt: string;
};

export type FitnessPendingImport = Omit<FitnessPendingImportRecord, "key" | "ownerKey" | "fileBlob"> & {
  hasLocalFile: boolean;
};

export type FitnessPendingProgressPhoto = Omit<FitnessProgressPhotoRecord, "key" | "ownerKey" | "fileBlob"> & {
  hasLocalOriginal: boolean;
};

export type FitnessPendingNutritionLabel = Omit<FitnessNutritionLabelRecord, "key" | "ownerKey" | "fileBlob"> & {
  hasLocalOriginal: boolean;
};

export type SaveFitnessPlannedMealLogInput = {
  id?: string;
  meal: FitnessPlannedHouseholdMeal;
  portion: number;
  unit: "serving" | "g";
  loggedAtUtc: string;
  localTimezone: string;
  notes?: string | null;
  clientId?: string | null;
  clientTimestamp?: string | null;
};

export type FitnessLogUndoToken = {
  nutritionDate: string;
  label: string;
  highlight?: string;
  records: Array<{ id: string; revision?: number }>;
  createdAt: string;
};

export type QueueFitnessNutritionLabelInput = {
  entityType: "food" | "food_version";
  payload: Record<string, unknown>;
  options?: SaveFitnessRecordOptions;
};

export type QueueFitnessProgressPhotoInput = {
  captured_at: string;
  pose: FitnessProgressPhotoPose;
  body_weight_kg?: number | null;
  measurement_snapshot_json?: Record<string, number | string | null> | null;
  phase_id?: string | null;
  notes?: string | null;
};

export type FitnessSyncSummary = {
  pending: number;
  failed: number;
  compatibilityBlocked: boolean;
  compatibilityMessage: string | null;
  lastSyncedAt: string | null;
};

export type SaveFitnessRecordOptions = {
  entityId?: string;
  baseRevision?: number | null;
  operation?: FitnessMutationOperation;
};

export type SaveFitnessRecordInput = {
  entityType: FitnessEntityType;
  payload: Record<string, unknown>;
  options?: SaveFitnessRecordOptions;
};

let flushRequest: Promise<FitnessSyncResponse | null> | null = null;
let flushAgainRequested = false;
let importFlushRequest: Promise<FitnessPendingImport[]> | null = null;
let progressPhotoFlushRequest: Promise<FitnessPendingProgressPhoto[]> | null = null;
let progressPhotoFlushAgainRequested = false;
let nutritionLabelFlushRequest: Promise<FitnessPendingNutritionLabel[]> | null = null;
let nutritionLabelFlushAgainRequested = false;
let plannedMealFlushRequest: Promise<FitnessFoodLogEntry[]> | null = null;
let databaseFactory: IDBFactory | null = null;
let databasePromise: Promise<IDBDatabase> | null = null;

function ownerStorageKey(owner: OfflineQueueOwner): string {
  return `${owner.familyId}\u0000${owner.userId}`;
}

function requireOwner(): { owner: OfflineQueueOwner; ownerKey: string } {
  const owner = currentOfflineQueueOwner();
  if (!owner) throw new Error("Sign in again before saving Fitness data.");
  return { owner, ownerKey: ownerStorageKey(owner) };
}

function sameOwner(owner: OfflineQueueOwner): boolean {
  const current = currentOfflineQueueOwner();
  return Boolean(
    current
      && current.userId === owner.userId
      && current.familyId === owner.familyId,
  );
}

function recordKey(ownerKey: string, entityType: string, entityId: string): string {
  return `${ownerKey}\u0000${entityType}\u0000${entityId}`;
}

function outboxKey(ownerKey: string, mutationId: string): string {
  return `${ownerKey}\u0000${mutationId}`;
}

function metaKey(ownerKey: string, name: string): string {
  return `${ownerKey}\u0000${name}`;
}

function noticeKey(ownerKey: string, noticeId: string): string {
  return `${ownerKey}\u0000${noticeId}`;
}

function requestResult<T>(request: IDBRequest<T>): Promise<T> {
  return new Promise((resolve, reject) => {
    request.onsuccess = () => resolve(request.result);
    request.onerror = () => reject(request.error ?? new Error("Fitness storage could not be read."));
  });
}

function transactionDone(transaction: IDBTransaction): Promise<void> {
  return new Promise((resolve, reject) => {
    transaction.oncomplete = () => resolve();
    transaction.onerror = () => reject(
      transaction.error ?? new Error("Fitness storage could not be updated."),
    );
    transaction.onabort = () => reject(
      transaction.error ?? new Error("Fitness storage update was cancelled."),
    );
  });
}

function openDatabase(): Promise<IDBDatabase> {
  if (typeof indexedDB === "undefined") {
    return Promise.reject(new Error("Offline Fitness storage is unavailable in this browser."));
  }
  const factory = indexedDB;
  if (databaseFactory !== factory) {
    if (databasePromise) void databasePromise.then((database) => database.close()).catch(() => undefined);
    databaseFactory = factory;
    databasePromise = null;
  }
  if (databasePromise) return databasePromise;
  databasePromise = new Promise((resolve, reject) => {
    const request = factory.open(DATABASE, DATABASE_VERSION);
    request.onupgradeneeded = () => {
      const database = request.result;
      const upgrade = request.transaction!;
      const store = (name: string) => database.objectStoreNames.contains(name)
        ? upgrade.objectStore(name)
        : database.createObjectStore(name, { keyPath: "key" });
      const records = store(RECORDS_STORE);
      const ownerStores = [
        records,
        store(OUTBOX_STORE),
        store(META_STORE),
        store(NOTICES_STORE),
        store(IMPORTS_STORE),
        store(PROGRESS_PHOTOS_STORE),
        store(NUTRITION_LABELS_STORE),
        store(PLANNED_MEAL_LOGS_STORE),
      ];
      for (const ownerStore of ownerStores) {
        if (!ownerStore.indexNames.contains(OWNER_INDEX)) {
          ownerStore.createIndex(OWNER_INDEX, "ownerKey");
        }
      }
      if (!records.indexNames.contains(OWNER_ENTITY_INDEX)) {
        records.createIndex(OWNER_ENTITY_INDEX, ["ownerKey", "entityType"]);
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
      reject(request.error ?? new Error("Offline Fitness storage is unavailable."));
    };
  });
  return databasePromise;
}

function announceFitnessSyncChanged(): void {
  if (typeof window !== "undefined") {
    window.dispatchEvent(new CustomEvent("hausklar:fitness-sync-changed"));
  }
}

function announceFitnessImportsChanged(): void {
  if (typeof window !== "undefined") {
    window.dispatchEvent(new CustomEvent("hausklar:fitness-imports-changed"));
  }
}

function announceFitnessProgressPhotosChanged(): void {
  if (typeof window !== "undefined") {
    window.dispatchEvent(new CustomEvent("hausklar:fitness-progress-photos-changed"));
  }
}

function announceFitnessNutritionLabelsChanged(): void {
  if (typeof window !== "undefined") {
    window.dispatchEvent(new CustomEvent("hausklar:fitness-nutrition-labels-changed"));
  }
}

function announceFitnessPlannedMealsChanged(): void {
  if (typeof window !== "undefined") {
    window.dispatchEvent(new CustomEvent("hausklar:fitness-planned-meals-changed"));
  }
}

function deviceId(): string {
  const existing = window.localStorage.getItem(DEVICE_ID_KEY);
  if (existing) return existing;
  const value = crypto.randomUUID();
  window.localStorage.setItem(DEVICE_ID_KEY, value);
  return value;
}

function entityTypeIsSupported(value: string): value is FitnessEntityType {
  return value in FITNESS_PAYLOAD_SCHEMA_VERSIONS;
}

function recordPayload(value: unknown): Record<string, unknown> {
  return value && typeof value === "object" && !Array.isArray(value)
    ? value as Record<string, unknown>
    : {};
}

function replaceIdentifier(value: unknown, sourceId: string, targetId: string): unknown {
  if (value === sourceId) return targetId;
  if (Array.isArray(value)) {
    return value.map((entry) => replaceIdentifier(entry, sourceId, targetId));
  }
  if (value && typeof value === "object") {
    return Object.fromEntries(
      Object.entries(value).map(([key, entry]) => [key, replaceIdentifier(entry, sourceId, targetId)]),
    );
  }
  return value;
}

async function putMeta(ownerKey: string, name: string, value: unknown): Promise<void> {
  const database = await openDatabase();
  const transaction = database.transaction(META_STORE, "readwrite");
  transaction.objectStore(META_STORE).put({
    key: metaKey(ownerKey, name), ownerKey, name, value,
  } satisfies FitnessMetaRecord);
  await transactionDone(transaction);
}

async function getMeta<T>(ownerKey: string, name: string): Promise<T | null> {
  const database = await openDatabase();
  const transaction = database.transaction(META_STORE, "readonly");
  const result = await requestResult(
    transaction.objectStore(META_STORE).get(metaKey(ownerKey, name)),
  ) as FitnessMetaRecord | undefined;
  await transactionDone(transaction);
  return result ? result.value as T : null;
}

function plannedMealLogKey(ownerKey: string, entryId: string): string {
  return `${ownerKey}\u0000${entryId}`;
}

function localPlannedMealEntry(
  record: FitnessPlannedMealLogRecord,
  response?: FitnessPrivatePlannedMealLog,
): FitnessFoodLogEntry {
  return {
    id: record.id,
    recipe_version_id: record.meal.recipe_version_id,
    source_meal_plan_id: record.meal.meal_plan_id,
    household_meal_link_id: record.meal.link_id,
    food_name: record.meal.recipe_name,
    logged_at_utc: response?.logged_at_utc ?? record.loggedAtUtc,
    local_timezone: record.localTimezone,
    nutrition_date: response?.nutrition_date ?? record.meal.date,
    meal_key: response?.meal_type ?? record.meal.meal_type,
    entered_amount: response?.portion ?? record.portion,
    entered_unit: response?.unit ?? record.unit,
    canonical_amount: response?.portion ?? record.portion,
    canonical_unit: response?.unit ?? record.unit,
    calories_kcal: response?.calories_kcal ?? null,
    protein_g: response?.protein_g ?? null,
    measurement_quality: record.unit === "serving" ? "standard_serving" : "measured",
    notes: record.notes,
    context_tags: [],
    queued_offline: response ? undefined : true,
  };
}

async function ownerPlannedMealLogRecords(ownerKey: string): Promise<FitnessPlannedMealLogRecord[]> {
  const database = await openDatabase();
  const transaction = database.transaction(PLANNED_MEAL_LOGS_STORE, "readonly");
  const records = await requestResult(
    transaction.objectStore(PLANNED_MEAL_LOGS_STORE).index(OWNER_INDEX).getAll(ownerKey),
  ) as FitnessPlannedMealLogRecord[];
  await transactionDone(transaction);
  return records.sort((left, right) => left.createdAt.localeCompare(right.createdAt));
}

async function putPlannedMealLogRecord(record: FitnessPlannedMealLogRecord): Promise<void> {
  const database = await openDatabase();
  const transaction = database.transaction(PLANNED_MEAL_LOGS_STORE, "readwrite");
  transaction.objectStore(PLANNED_MEAL_LOGS_STORE).put(record);
  await transactionDone(transaction);
  announceFitnessPlannedMealsChanged();
}

async function deletePlannedMealLogRecord(ownerKey: string, entryId: string): Promise<void> {
  const database = await openDatabase();
  const transaction = database.transaction(PLANNED_MEAL_LOGS_STORE, "readwrite");
  transaction.objectStore(PLANNED_MEAL_LOGS_STORE).delete(plannedMealLogKey(ownerKey, entryId));
  await transactionDone(transaction);
  announceFitnessPlannedMealsChanged();
}

async function cacheLocalRecordOnly(record: FitnessFoodLogEntry): Promise<void> {
  const { ownerKey } = requireOwner();
  const database = await openDatabase();
  const transaction = database.transaction(RECORDS_STORE, "readwrite");
  transaction.objectStore(RECORDS_STORE).put({
    key: recordKey(ownerKey, "food_log_entry", record.id),
    ownerKey,
    entityType: "food_log_entry",
    entityId: record.id,
    revision: record.revision ?? null,
    payload: recordPayload(record),
    deleted: false,
    updatedAt: new Date().toISOString(),
  } satisfies FitnessLocalRecord);
  await transactionDone(transaction);
}

async function removeLocalRecordOnly(ownerKey: string, entryId: string): Promise<void> {
  const database = await openDatabase();
  const transaction = database.transaction(RECORDS_STORE, "readwrite");
  transaction.objectStore(RECORDS_STORE).delete(recordKey(ownerKey, "food_log_entry", entryId));
  await transactionDone(transaction);
}

export async function cacheFitnessPlannedMeals(
  date: string,
  meals: FitnessPlannedHouseholdMeal[],
): Promise<void> {
  const { ownerKey } = requireOwner();
  await putMeta(ownerKey, `planned-meals:${date}`, meals);
}

export async function cachedFitnessPlannedMeals(date: string): Promise<FitnessPlannedHouseholdMeal[]> {
  const { ownerKey } = requireOwner();
  return await getMeta<FitnessPlannedHouseholdMeal[]>(ownerKey, `planned-meals:${date}`) ?? [];
}

export async function cacheFitnessProgressCharts(charts: FitnessProgressCharts): Promise<void> {
  const { ownerKey } = requireOwner();
  await putMeta(ownerKey, "progress-charts", charts);
}

export async function cachedFitnessProgressCharts(): Promise<FitnessProgressCharts | null> {
  const { ownerKey } = requireOwner();
  return getMeta<FitnessProgressCharts>(ownerKey, "progress-charts");
}

export async function rememberFitnessLogUndo(token: FitnessLogUndoToken | null): Promise<void> {
  const { ownerKey } = requireOwner();
  await putMeta(ownerKey, "log-undo", token);
}

export async function fitnessLogUndo(): Promise<FitnessLogUndoToken | null> {
  const { ownerKey } = requireOwner();
  return await getMeta<FitnessLogUndoToken>(ownerKey, "log-undo");
}

async function uploadPlannedMealLog(
  owner: OfflineQueueOwner,
  record: FitnessPlannedMealLogRecord,
): Promise<FitnessFoodLogEntry> {
  const response = await api<FitnessPrivatePlannedMealLog>(
    `/fitness/planned-meals/${encodeURIComponent(record.meal.meal_plan_id)}/log`,
    {
      method: "POST",
      body: JSON.stringify({
        id: record.id,
        portion: record.portion,
        unit: record.unit,
        logged_at_utc: record.loggedAtUtc,
        local_timezone: record.localTimezone,
        notes: record.notes,
        client_id: record.clientId,
        client_timestamp: record.clientTimestamp,
      }),
    },
    true,
    false,
  );
  if (!sameOwner(owner)) throw new Error("The signed-in Fitness owner changed while saving.");
  const entry = localPlannedMealEntry(record, response);
  await cacheLocalRecordOnly(entry);
  await deletePlannedMealLogRecord(ownerStorageKey(owner), record.id);
  return entry;
}

function plannedMealFailureCanRetry(error: unknown): boolean {
  if (!(error instanceof ApiError)) return true;
  return error.status === 408 || error.status === 429 || error.status >= 500;
}

export async function saveFitnessPlannedMealLog(
  input: SaveFitnessPlannedMealLogInput,
): Promise<FitnessFoodLogEntry> {
  if (!Number.isFinite(input.portion) || input.portion <= 0) {
    throw new Error("Enter a portion greater than zero.");
  }
  const { owner, ownerKey } = requireOwner();
  const now = new Date().toISOString();
  const id = input.id ?? crypto.randomUUID();
  const record: FitnessPlannedMealLogRecord = {
    key: plannedMealLogKey(ownerKey, id),
    ownerKey,
    id,
    meal: input.meal,
    portion: input.portion,
    unit: input.unit,
    loggedAtUtc: input.loggedAtUtc,
    localTimezone: input.localTimezone,
    notes: input.notes ?? null,
    clientId: input.clientId ?? deviceId(),
    clientTimestamp: input.clientTimestamp ?? now,
    attempts: 0,
    lastError: null,
    createdAt: now,
    updatedAt: now,
  };
  const localEntry = localPlannedMealEntry(record);
  await putPlannedMealLogRecord(record);
  await cacheLocalRecordOnly(localEntry);
  if (!navigator.onLine) return localEntry;
  try {
    return await uploadPlannedMealLog(owner, record);
  } catch (error) {
    if (plannedMealFailureCanRetry(error)) {
      await putPlannedMealLogRecord({
        ...record,
        attempts: 1,
        lastError: error instanceof Error ? error.message : "Could not save yet.",
        updatedAt: new Date().toISOString(),
      });
      return localEntry;
    }
    await deletePlannedMealLogRecord(ownerKey, id);
    await removeLocalRecordOnly(ownerKey, id);
    throw error;
  }
}

export async function removeFitnessPlannedMealLogFromDevice(entryId: string): Promise<boolean> {
  const { ownerKey } = requireOwner();
  const pending = (await ownerPlannedMealLogRecords(ownerKey)).some((record) => record.id === entryId);
  if (!pending) return false;
  await deletePlannedMealLogRecord(ownerKey, entryId);
  await removeLocalRecordOnly(ownerKey, entryId);
  return true;
}

export async function flushFitnessPlannedMealLogs(): Promise<FitnessFoodLogEntry[]> {
  if (!navigator.onLine) return [];
  if (plannedMealFlushRequest) return plannedMealFlushRequest;
  const { owner, ownerKey } = requireOwner();
  plannedMealFlushRequest = (async () => {
    const saved: FitnessFoodLogEntry[] = [];
    for (const record of await ownerPlannedMealLogRecords(ownerKey)) {
      if (!sameOwner(owner)) break;
      try {
        saved.push(await uploadPlannedMealLog(owner, record));
      } catch (error) {
        await putPlannedMealLogRecord({
          ...record,
          attempts: record.attempts + 1,
          lastError: error instanceof Error ? error.message : "Could not save yet.",
          updatedAt: new Date().toISOString(),
        });
      }
    }
    return saved;
  })().finally(() => {
    plannedMealFlushRequest = null;
  });
  return plannedMealFlushRequest;
}

async function ownerOutbox(ownerKey: string): Promise<FitnessOutboxEntry[]> {
  const database = await openDatabase();
  const transaction = database.transaction(OUTBOX_STORE, "readonly");
  const values = await requestResult(
    transaction.objectStore(OUTBOX_STORE).index(OWNER_INDEX).getAll(ownerKey),
  ) as FitnessOutboxEntry[];
  await transactionDone(transaction);
  return values
    .sort((left, right) => left.mutation.created_at_client.localeCompare(right.mutation.created_at_client));
}

export async function cachedFitnessRecords<T extends { id: string }>(
  entityType: FitnessEntityType,
): Promise<T[]> {
  const { ownerKey } = requireOwner();
  if (typeof indexedDB === "undefined") return [];
  const database = await openDatabase();
  const transaction = database.transaction(RECORDS_STORE, "readonly");
  const values = await requestResult(
    transaction.objectStore(RECORDS_STORE).index(OWNER_ENTITY_INDEX).getAll([ownerKey, entityType]),
  ) as FitnessLocalRecord[];
  await transactionDone(transaction);
  return values
    .filter((record) => !record.deleted)
    .map((record) => ({
      ...record.payload,
      id: record.entityId,
      revision: record.revision ?? undefined,
    }) as unknown as T);
}

export async function cacheFitnessRecords<T extends { id: string; revision?: number }>(
  entityType: FitnessEntityType,
  records: T[],
): Promise<void> {
  const { ownerKey } = requireOwner();
  if (typeof indexedDB === "undefined") return;
  const pendingEntityIds = new Set(
    (await ownerOutbox(ownerKey))
      .filter((entry) => entry.mutation.entity_type === entityType)
      .map((entry) => entry.mutation.entity_id),
  );
  const database = await openDatabase();
  const transaction = database.transaction(RECORDS_STORE, "readwrite");
  const store = transaction.objectStore(RECORDS_STORE);
  const removedEntityIds = await locallyRemovedEntityIds(store, ownerKey, entityType);
  for (const record of records) {
    if (pendingEntityIds.has(record.id)) continue;
    // A list response is a snapshot taken before this device removed the
    // record, so it must never reinstate one. Only the cursor-ordered sync
    // change stream may bring a removed record back.
    if (removedEntityIds.has(record.id)) continue;
    store.put({
      key: recordKey(ownerKey, entityType, record.id),
      ownerKey,
      entityType,
      entityId: record.id,
      revision: record.revision ?? null,
      payload: recordPayload(record),
      deleted: false,
      updatedAt: new Date().toISOString(),
    } satisfies FitnessLocalRecord);
  }
  await transactionDone(transaction);
}

async function locallyRemovedEntityIds(
  store: IDBObjectStore,
  ownerKey: string,
  entityType: FitnessEntityType,
): Promise<Set<string>> {
  const values = await requestResult(
    store.index(OWNER_ENTITY_INDEX).getAll([ownerKey, entityType]),
  ) as FitnessLocalRecord[];
  return new Set(values.filter((record) => record.deleted).map((record) => record.entityId));
}

/**
 * The diary this device holds for one nutrition day, or null when this browser
 * keeps no cache at all — only then may a caller fall back to a list response.
 */
export async function cachedFitnessFoodLogDay(
  nutritionDate: string,
): Promise<FitnessFoodLogEntry[] | null> {
  if (typeof indexedDB === "undefined") return null;
  const cached = await cachedFitnessRecords<FitnessFoodLogEntry>("food_log_entry");
  return cached.filter((entry) => foodLogEntryIsOnDate(entry, nutritionDate));
}

/**
 * Replaces the cached diary for one nutrition day with the server's own list.
 *
 * Caching alone only ever added rows, so an entry the server no longer holds —
 * one removed on another device, or removed here while a list request was
 * already in flight — stayed in the diary indefinitely. Rows saved after the
 * request left this device cannot appear in its response, so they are kept.
 */
export async function cacheFitnessFoodLogDay(
  nutritionDate: string,
  entries: Array<FitnessFoodLogEntry & { revision?: number }>,
  requestStartedAt: string,
): Promise<void> {
  const { ownerKey } = requireOwner();
  if (typeof indexedDB === "undefined") return;
  const pendingEntityIds = new Set(
    (await ownerOutbox(ownerKey))
      .filter((entry) => entry.mutation.entity_type === "food_log_entry")
      .map((entry) => entry.mutation.entity_id),
  );
  const serverIds = new Set(entries.map((entry) => entry.id));
  const database = await openDatabase();
  const transaction = database.transaction(RECORDS_STORE, "readwrite");
  const store = transaction.objectStore(RECORDS_STORE);
  const cached = await requestResult(
    store.index(OWNER_ENTITY_INDEX).getAll([ownerKey, "food_log_entry"]),
  ) as FitnessLocalRecord[];
  const removedEntityIds = new Set(
    cached.filter((record) => record.deleted).map((record) => record.entityId),
  );
  for (const record of cached) {
    if (serverIds.has(record.entityId) && !record.deleted) continue;
    if (pendingEntityIds.has(record.entityId)) continue;
    if (record.updatedAt >= requestStartedAt) continue;
    if (!foodLogEntryIsOnDate(record.payload as unknown as FitnessFoodLogEntry, nutritionDate)) continue;
    store.delete(record.key);
  }
  const now = new Date().toISOString();
  for (const entry of entries) {
    if (pendingEntityIds.has(entry.id)) continue;
    if (removedEntityIds.has(entry.id)) continue;
    store.put({
      key: recordKey(ownerKey, "food_log_entry", entry.id),
      ownerKey,
      entityType: "food_log_entry",
      entityId: entry.id,
      revision: entry.revision ?? null,
      payload: recordPayload(entry),
      deleted: false,
      updatedAt: now,
    } satisfies FitnessLocalRecord);
  }
  await transactionDone(transaction);
}

export async function saveFitnessRecord<T extends Record<string, unknown>>(
  entityType: FitnessEntityType,
  payload: T,
  options: SaveFitnessRecordOptions = {},
): Promise<T & { id: string; revision?: number; queued_offline: true }> {
  const [record] = await saveFitnessRecords([{ entityType, payload, options }]);
  return record as T & { id: string; revision?: number; queued_offline: true };
}

export async function saveFitnessRecords(
  inputs: SaveFitnessRecordInput[],
): Promise<Array<Record<string, unknown> & { id: string; queued_offline: true }>> {
  const { ownerKey } = requireOwner();
  const createdAt = new Date().toISOString();
  const prepared = inputs.map(({ entityType, payload, options = {} }, index) => {
    const entityId = options.entityId ?? (typeof payload.id === "string" ? payload.id : crypto.randomUUID());
    const mutationId = crypto.randomUUID();
    const operation = options.operation ?? "upsert";
    const normalizedPayload = operation === "delete" ? {} : { ...payload, id: entityId };
    const mutation: FitnessSyncMutation = {
      mutation_id: mutationId,
      entity_type: entityType,
      entity_id: entityId,
      operation,
      payload_schema_version: FITNESS_PAYLOAD_SCHEMA_VERSIONS[entityType],
      base_revision: options.baseRevision ?? null,
      payload: normalizedPayload,
      created_at_client: new Date(Date.parse(createdAt) + index).toISOString(),
    };
    return { entityType, entityId, mutationId, operation, normalizedPayload, mutation, options };
  });
  const database = await openDatabase();
  const transaction = database.transaction([RECORDS_STORE, OUTBOX_STORE], "readwrite");
  for (const item of prepared) {
    transaction.objectStore(RECORDS_STORE).put({
      key: recordKey(ownerKey, item.entityType, item.entityId),
      ownerKey,
      entityType: item.entityType,
      entityId: item.entityId,
      revision: item.options.baseRevision ?? null,
      payload: item.normalizedPayload,
      deleted: item.operation === "delete",
      updatedAt: createdAt,
    } satisfies FitnessLocalRecord);
    transaction.objectStore(OUTBOX_STORE).add({
      key: outboxKey(ownerKey, item.mutationId),
      ownerKey,
      mutation: item.mutation,
      attempts: 0,
      lastError: null,
    } satisfies FitnessOutboxEntry);
  }
  await transactionDone(transaction);
  announceFitnessSyncChanged();
  if (navigator.onLine) {
    if (flushRequest) flushAgainRequested = true;
    else void flushFitnessSync().catch(() => undefined);
  }
  return prepared.map((item) => ({
    ...item.normalizedPayload,
    id: item.entityId,
    queued_offline: true as const,
  }));
}

export async function deleteFitnessRecord(
  entityType: FitnessEntityType,
  entityId: string,
  baseRevision: number | null = null,
): Promise<void> {
  await saveFitnessRecord(entityType, {}, {
    entityId,
    baseRevision,
    operation: "delete",
  });
}

function publicNutritionLabel(record: FitnessNutritionLabelRecord): FitnessPendingNutritionLabel {
  const { key: _key, ownerKey: _ownerKey, fileBlob, ...value } = record;
  return { ...value, hasLocalOriginal: fileBlob !== null };
}

async function ownerNutritionLabelRecords(ownerKey: string): Promise<FitnessNutritionLabelRecord[]> {
  const database = await openDatabase();
  const transaction = database.transaction(NUTRITION_LABELS_STORE, "readonly");
  const values = await requestResult(
    transaction.objectStore(NUTRITION_LABELS_STORE).index(OWNER_INDEX).getAll(ownerKey),
  ) as FitnessNutritionLabelRecord[];
  await transactionDone(transaction);
  return values.sort((left, right) => right.createdAt.localeCompare(left.createdAt));
}

async function putNutritionLabelRecord(record: FitnessNutritionLabelRecord): Promise<void> {
  const database = await openDatabase();
  const transaction = database.transaction(NUTRITION_LABELS_STORE, "readwrite");
  transaction.objectStore(NUTRITION_LABELS_STORE).put(record);
  await transactionDone(transaction);
  announceFitnessNutritionLabelsChanged();
}

export async function fitnessNutritionLabelsOnDevice(): Promise<FitnessPendingNutritionLabel[]> {
  const { ownerKey } = requireOwner();
  if (typeof indexedDB === "undefined") return [];
  return (await ownerNutritionLabelRecords(ownerKey)).map(publicNutritionLabel);
}

function nutritionLabelMediaType(file: File): string {
  const declared = file.type.toLocaleLowerCase() === "image/jpg" ? "image/jpeg" : file.type.toLocaleLowerCase();
  const extension = file.name.toLocaleLowerCase().match(/\.([a-z0-9]+)$/)?.[1] ?? "";
  const derived = ({
    jpg: "image/jpeg",
    jpeg: "image/jpeg",
    png: "image/png",
    heic: "image/heic",
    heif: "image/heif",
  } as Record<string, string>)[extension] ?? "";
  const mediaType = /^(image\/(jpeg|png|heic|heif))$/.test(declared) ? declared : declared ? "" : derived;
  if (!mediaType) throw new Error("Choose a JPEG, PNG, HEIC, or HEIF nutrition-label image.");
  if (file.size === 0) throw new Error("That nutrition-label image is empty.");
  if (file.size > 15 * 1024 * 1024) throw new Error("Nutrition-label images must be 15 MB or smaller.");
  return mediaType;
}

export async function queueFitnessNutritionLabel(
  file: File,
  input: QueueFitnessNutritionLabelInput,
): Promise<{ record: Record<string, unknown> & { id: string; queued_offline: true }; label: FitnessPendingNutritionLabel }> {
  const fileType = nutritionLabelMediaType(file);
  const { owner, ownerKey } = requireOwner();
  const now = new Date().toISOString();
  const entityId = input.options?.entityId
    ?? (typeof input.payload.id === "string" ? input.payload.id : crypto.randomUUID());
  const assetId = crypto.randomUUID();
  const labelId = crypto.randomUUID();
  const mutationId = crypto.randomUUID();
  const version = recordPayload(input.payload.version);
  const payload = input.entityType === "food"
    ? { ...input.payload, id: entityId, version: { ...version, label_asset_id: assetId } }
    : { ...input.payload, id: entityId, label_asset_id: assetId };
  const mutation: FitnessSyncMutation = {
    mutation_id: mutationId,
    entity_type: input.entityType,
    entity_id: entityId,
    operation: "upsert",
    payload_schema_version: FITNESS_PAYLOAD_SCHEMA_VERSIONS[input.entityType],
    base_revision: input.options?.baseRevision ?? null,
    payload,
    created_at_client: now,
  };
  const label: FitnessNutritionLabelRecord = {
    key: recordKey(ownerKey, "nutrition_label", labelId),
    ownerKey,
    id: labelId,
    assetId,
    dependentEntityType: input.entityType,
    dependentEntityId: entityId,
    dependentMutationId: mutationId,
    fileName: file.name,
    fileSize: file.size,
    fileType,
    fileLastModified: file.lastModified,
    fileBlob: file,
    state: "pending_upload",
    uploadAcknowledged: false,
    dependentAcknowledged: false,
    error: null,
    attempts: 0,
    createdAt: now,
    updatedAt: now,
  };
  if (!sameOwner(owner)) throw new Error("The signed-in Fitness owner changed before this label was saved.");
  const database = await openDatabase();
  const transaction = database.transaction(
    [RECORDS_STORE, OUTBOX_STORE, NUTRITION_LABELS_STORE],
    "readwrite",
  );
  transaction.objectStore(RECORDS_STORE).put({
    key: recordKey(ownerKey, input.entityType, entityId),
    ownerKey,
    entityType: input.entityType,
    entityId,
    revision: input.options?.baseRevision ?? null,
    payload,
    deleted: false,
    updatedAt: now,
  } satisfies FitnessLocalRecord);
  transaction.objectStore(OUTBOX_STORE).add({
    key: outboxKey(ownerKey, mutationId),
    ownerKey,
    mutation,
    attempts: 0,
    lastError: null,
  } satisfies FitnessOutboxEntry);
  transaction.objectStore(NUTRITION_LABELS_STORE).add(label);
  await transactionDone(transaction);
  if (!sameOwner(owner)) throw new Error("The signed-in Fitness owner changed before this label was saved.");
  announceFitnessSyncChanged();
  announceFitnessNutritionLabelsChanged();
  if (navigator.onLine) void flushFitnessNutritionLabels().catch(() => undefined);
  return {
    record: { ...payload, id: entityId, queued_offline: true },
    label: publicNutritionLabel(label),
  };
}

async function uploadNutritionLabel(
  record: FitnessNutritionLabelRecord,
  owner: OfflineQueueOwner,
): Promise<FitnessNutritionLabelRecord> {
  if (record.uploadAcknowledged || !record.fileBlob || !sameOwner(owner)) return record;
  const uploading = { ...record, state: "uploading" as const, error: null, updatedAt: new Date().toISOString() };
  await putNutritionLabelRecord(uploading);
  const data = new FormData();
  data.append("file", new File([record.fileBlob], record.fileName, {
    type: record.fileType,
    lastModified: record.fileLastModified,
  }));
  data.append("asset_id", record.assetId);
  data.append("asset_kind", "nutrition_label");
  try {
    const result = await api<FitnessPrivateAssetUploadResult>(
      "/fitness/files/private",
      { method: "POST", body: data, timeoutMs: 60_000 },
      true,
      false,
    );
    if (!sameOwner(owner)) return record;
    if (!(result.upload_acknowledged === true
      && result.asset_id === record.assetId
      && result.state === "staged"
      && result.storage_class === "private_required")) {
      throw new Error("The server did not explicitly acknowledge the staged nutrition label.");
    }
    const next: FitnessNutritionLabelRecord = {
      ...uploading,
      fileBlob: record.fileBlob,
      state: "uploaded_waiting_reference",
      uploadAcknowledged: true,
      error: null,
      attempts: record.attempts + 1,
      updatedAt: new Date().toISOString(),
    };
    await putNutritionLabelRecord(next);
    return next;
  } catch (error) {
    if (!sameOwner(owner)) return record;
    const next: FitnessNutritionLabelRecord = {
      ...record,
      state: "error",
      error: error instanceof Error ? error.message : "The nutrition label could not be uploaded.",
      attempts: record.attempts + 1,
      updatedAt: new Date().toISOString(),
    };
    await putNutritionLabelRecord(next);
    return next;
  }
}

export async function flushFitnessNutritionLabels(): Promise<FitnessPendingNutritionLabel[]> {
  if (nutritionLabelFlushRequest) {
    nutritionLabelFlushAgainRequested = true;
    return nutritionLabelFlushRequest;
  }
  nutritionLabelFlushRequest = (async () => {
    if (!navigator.onLine || typeof indexedDB === "undefined") return fitnessNutritionLabelsOnDevice();
    const { owner, ownerKey } = requireOwner();
    const records = await ownerNutritionLabelRecords(ownerKey);
    for (const record of records.filter((entry) => !entry.uploadAcknowledged && !entry.dependentAcknowledged)) {
      if (!sameOwner(owner)) break;
      await uploadNutritionLabel(record, owner);
    }
    if (sameOwner(owner)) await flushFitnessSync();
    if (!sameOwner(owner)) return [];
    return (await ownerNutritionLabelRecords(ownerKey)).map(publicNutritionLabel);
  })().finally(() => {
    nutritionLabelFlushRequest = null;
    if (nutritionLabelFlushAgainRequested) {
      nutritionLabelFlushAgainRequested = false;
      void flushFitnessNutritionLabels().catch(() => undefined);
    }
  });
  return nutritionLabelFlushRequest;
}

export async function retryFitnessNutritionLabel(labelId: string): Promise<void> {
  const { ownerKey } = requireOwner();
  const record = (await ownerNutritionLabelRecords(ownerKey)).find((entry) => entry.id === labelId);
  if (!record) throw new Error("That nutrition label is no longer on this device.");
  if (!record.uploadAcknowledged && !record.fileBlob) throw new Error("Choose the nutrition-label image again before retrying.");
  await putNutritionLabelRecord({
    ...record,
    state: record.uploadAcknowledged ? "uploaded_waiting_reference" : "pending_upload",
    error: null,
    updatedAt: new Date().toISOString(),
  });
  if (navigator.onLine) await flushFitnessNutritionLabels();
}

export async function abandonFitnessNutritionLabel(labelId: string): Promise<void> {
  const { ownerKey } = requireOwner();
  const record = (await ownerNutritionLabelRecords(ownerKey)).find((entry) => entry.id === labelId);
  if (!record || record.dependentAcknowledged) return;
  if (record.uploadAcknowledged) {
    if (!navigator.onLine) throw new Error("Reconnect before abandoning this staged nutrition label.");
    await api<void>(
      `/fitness/files/private/${encodeURIComponent(record.assetId)}`,
      { method: "DELETE" },
      true,
      false,
    );
  }
  const database = await openDatabase();
  const transaction = database.transaction(
    [RECORDS_STORE, OUTBOX_STORE, NUTRITION_LABELS_STORE],
    "readwrite",
  );
  transaction.objectStore(RECORDS_STORE).delete(
    recordKey(ownerKey, record.dependentEntityType, record.dependentEntityId),
  );
  transaction.objectStore(OUTBOX_STORE).delete(outboxKey(ownerKey, record.dependentMutationId));
  transaction.objectStore(NUTRITION_LABELS_STORE).delete(record.key);
  await transactionDone(transaction);
  announceFitnessSyncChanged();
  announceFitnessNutritionLabelsChanged();
}

async function applyRedirects(
  recordsStore: IDBObjectStore,
  outboxStore: IDBObjectStore,
  ownerKey: string,
  redirects: FitnessSyncRedirect[],
): Promise<void> {
  if (redirects.length === 0) return;
  const records = await requestResult(
    recordsStore.index(OWNER_INDEX).getAll(ownerKey),
  ) as FitnessLocalRecord[];
  const outbox = await requestResult(
    outboxStore.index(OWNER_INDEX).getAll(ownerKey),
  ) as FitnessOutboxEntry[];
  for (const redirect of redirects) {
    for (const record of records) {
      const isRedirectedIdentity = record.entityId === redirect.source_id
        && record.entityType === redirect.entity_type;
      if (isRedirectedIdentity) {
        // A merge redirect identifies an alias. Never copy its fields over the
        // survivor; the server notice retains the attempted fields for review.
        recordsStore.delete(record.key);
        continue;
      }
      const nextPayload = replaceIdentifier(record.payload, redirect.source_id, redirect.target_id) as Record<string, unknown>;
      recordsStore.put({
        ...record,
        payload: nextPayload,
      } satisfies FitnessLocalRecord);
    }
    for (const entry of outbox) {
      const isRedirectedIdentity = entry.mutation.entity_id === redirect.source_id
        && entry.mutation.entity_type === redirect.entity_type;
      if (isRedirectedIdentity) {
        // Replaying an alias edit against the survivor could overwrite its
        // canonical fields. The redirect notice is the recovery record.
        outboxStore.delete(entry.key);
        continue;
      }
      outboxStore.put({
        ...entry,
        mutation: {
          ...entry.mutation,
          payload: replaceIdentifier(
            entry.mutation.payload,
            redirect.source_id,
            redirect.target_id,
          ) as Record<string, unknown>,
        },
      } satisfies FitnessOutboxEntry);
    }
  }
}

function applyServerChange(
  recordsStore: IDBObjectStore,
  ownerKey: string,
  change: FitnessSyncChange,
): void {
  if (!entityTypeIsSupported(change.entity_type)) return;
  const payload = change.data ?? {};
  recordsStore.put({
    key: recordKey(ownerKey, change.entity_type, change.entity_id),
    ownerKey,
    entityType: change.entity_type,
    entityId: change.entity_id,
    revision: change.revision ?? null,
    payload: recordPayload(payload),
    deleted: change.operation === "delete",
    updatedAt: new Date().toISOString(),
  } satisfies FitnessLocalRecord);
}

async function replaceOwnerRecordsFromSnapshot(
  recordsStore: IDBObjectStore,
  outboxStore: IDBObjectStore,
  ownerKey: string,
  snapshot: FitnessSnapshotResponse,
  acceptedIds: Set<string>,
): Promise<void> {
  const [records, outbox] = await Promise.all([
    requestResult(recordsStore.index(OWNER_INDEX).getAll(ownerKey)) as Promise<FitnessLocalRecord[]>,
    requestResult(outboxStore.index(OWNER_INDEX).getAll(ownerKey)) as Promise<FitnessOutboxEntry[]>,
  ]);
  const pendingIdentities = new Set(
    outbox
      .filter((entry) => !acceptedIds.has(entry.mutation.mutation_id))
      .map((entry) => `${entry.mutation.entity_type}\u0000${entry.mutation.entity_id}`),
  );
  for (const record of records) {
    if (!pendingIdentities.has(`${record.entityType}\u0000${record.entityId}`)) {
      recordsStore.delete(record.key);
    }
  }
  for (const entity of snapshot.entities) {
    if (!entityTypeIsSupported(entity.entity_type)) continue;
    if (pendingIdentities.has(`${entity.entity_type}\u0000${entity.entity_id}`)) continue;
    recordsStore.put({
      key: recordKey(ownerKey, entity.entity_type, entity.entity_id),
      ownerKey,
      entityType: entity.entity_type,
      entityId: entity.entity_id,
      revision: entity.revision,
      payload: recordPayload(entity.data),
      deleted: false,
      updatedAt: snapshot.generated_at,
    } satisfies FitnessLocalRecord);
  }
}

function compatibilityMessage(error: unknown): string | null {
  if (!(error instanceof ApiError) || (error.status !== 409 && error.status !== 426)) return null;
  return error.message || "This version of HausKlar cannot sync Fitness data yet. Update the app and try again.";
}

export async function flushFitnessSync(): Promise<FitnessSyncResponse | null> {
  if (flushRequest) {
    flushAgainRequested = true;
    return flushRequest;
  }
  const ownerAtStart = currentOfflineQueueOwner();
  flushRequest = (async () => {
    if (!navigator.onLine || typeof indexedDB === "undefined") return null;
    const { owner, ownerKey } = requireOwner();
    const allEntries = await ownerOutbox(ownerKey);
    const labels = await ownerNutritionLabelRecords(ownerKey);
    const blockedLabelMutations = new Set(
      labels
        .filter((label) => !label.uploadAcknowledged && !label.dependentAcknowledged)
        .map((label) => label.dependentMutationId),
    );
    // A staged private asset must exist before its dependent version mutation
    // can promote that asset to ready on the server.
    const entries = allEntries.filter((entry) => !blockedLabelMutations.has(entry.mutation.mutation_id));
    const cursor = await getMeta<number>(ownerKey, "cursor") ?? 0;
    const response = await api<FitnessSyncResponse>(
      "/fitness/sync",
      {
        method: "POST",
        body: JSON.stringify({
          sync_protocol_version: FITNESS_SYNC_PROTOCOL_VERSION,
          client_schema_version: FITNESS_CLIENT_SCHEMA_VERSION,
          client_app_version: packageMetadata.version,
          client_build: import.meta.env.VITE_APP_BUILD ?? packageMetadata.version,
          platform: "web",
          device_id: deviceId(),
          cursor,
          mutations: entries.map((entry) => entry.mutation),
        }),
      },
      true,
      false,
    );
    if (!sameOwner(owner)) return null;

    let snapshot: FitnessSnapshotResponse | null = null;
    if (response.status === "full_snapshot_required") {
      if (response.snapshot_url !== "/api/fitness/sync/snapshot" && response.snapshot_url !== "/fitness/sync/snapshot") {
        throw new Error("The Fitness server requested an unsupported snapshot location.");
      }
      snapshot = await api<FitnessSnapshotResponse>(
        "/fitness/sync/snapshot",
        { method: "GET" },
        true,
        false,
      );
      if (!sameOwner(owner)) return null;
    }

    const acceptedIds = new Set([
      ...(response.acked_mutation_ids ?? []),
      ...response.accepted.map((entry) => entry.mutation_id),
    ]);
    const rejectedById = new Map(
      (response.rejected_mutations ?? []).map((entry) => [entry.mutation_id, entry]),
    );
    const database = await openDatabase();
    const transaction = database.transaction(
      [RECORDS_STORE, OUTBOX_STORE, META_STORE, NOTICES_STORE, NUTRITION_LABELS_STORE],
      "readwrite",
    );
    const recordsStore = transaction.objectStore(RECORDS_STORE);
    const outboxStore = transaction.objectStore(OUTBOX_STORE);
    const metaStore = transaction.objectStore(META_STORE);
    const noticesStore = transaction.objectStore(NOTICES_STORE);
    const labelsStore = transaction.objectStore(NUTRITION_LABELS_STORE);
    for (const entry of entries) {
      if (acceptedIds.has(entry.mutation.mutation_id)) {
        outboxStore.delete(entry.key);
        continue;
      }
      const rejected = rejectedById.get(entry.mutation.mutation_id);
      if (rejected) {
        outboxStore.put({
          ...entry,
          attempts: entry.attempts + 1,
          lastError: rejected.message,
        } satisfies FitnessOutboxEntry);
      }
    }
    for (const label of labels) {
      if (!acceptedIds.has(label.dependentMutationId)) continue;
      labelsStore.put({
        ...label,
        // Upload acknowledgement alone never releases the original. The
        // dependent mutation has now promoted the staged asset to ready.
        fileBlob: null,
        state: "ready",
        dependentAcknowledged: true,
        error: null,
        updatedAt: new Date().toISOString(),
      } satisfies FitnessNutritionLabelRecord);
    }
    if (snapshot) {
      await replaceOwnerRecordsFromSnapshot(recordsStore, outboxStore, ownerKey, snapshot, acceptedIds);
      await applyRedirects(recordsStore, outboxStore, ownerKey, snapshot.redirects);
    } else {
      for (const change of response.changes) applyServerChange(recordsStore, ownerKey, change);
      await applyRedirects(recordsStore, outboxStore, ownerKey, response.redirects);
    }
    for (const notice of response.notices) {
      noticesStore.put({
        ...notice,
        key: noticeKey(ownerKey, notice.id),
        ownerKey,
      } satisfies FitnessNoticeRecord);
    }
    metaStore.put({
      key: metaKey(ownerKey, "cursor"), ownerKey, name: "cursor", value: snapshot?.next_cursor ?? response.next_cursor,
    } satisfies FitnessMetaRecord);
    metaStore.put({
      key: metaKey(ownerKey, "lastSyncedAt"), ownerKey, name: "lastSyncedAt", value: new Date().toISOString(),
    } satisfies FitnessMetaRecord);
    metaStore.put({
      key: metaKey(ownerKey, "compatibility"), ownerKey, name: "compatibility", value: null,
    } satisfies FitnessMetaRecord);
  await transactionDone(transaction);
    announceFitnessSyncChanged();
    if (labels.some((label) => acceptedIds.has(label.dependentMutationId))) {
      announceFitnessNutritionLabelsChanged();
    }
    return response;
  })()
    .catch(async (error) => {
      const message = compatibilityMessage(error);
      if (ownerAtStart && sameOwner(ownerAtStart) && message) {
        await putMeta(ownerStorageKey(ownerAtStart), "compatibility", message);
        announceFitnessSyncChanged();
      }
      throw error;
    })
    .finally(() => {
      flushRequest = null;
      if (flushAgainRequested) {
        flushAgainRequested = false;
        void flushFitnessSync().catch(() => undefined);
      }
    });
  return flushRequest;
}

export async function fitnessSyncSummary(): Promise<FitnessSyncSummary> {
  const owner = currentOfflineQueueOwner();
  if (!owner || typeof indexedDB === "undefined") {
    return {
      pending: 0,
      failed: 0,
      compatibilityBlocked: false,
      compatibilityMessage: null,
      lastSyncedAt: null,
    };
  }
  const ownerKey = ownerStorageKey(owner);
  const [entries, compatibility, lastSyncedAt] = await Promise.all([
    ownerOutbox(ownerKey),
    getMeta<string>(ownerKey, "compatibility"),
    getMeta<string>(ownerKey, "lastSyncedAt"),
  ]);
  return {
    pending: entries.length,
    failed: entries.filter((entry) => entry.lastError !== null).length,
    compatibilityBlocked: compatibility !== null,
    compatibilityMessage: compatibility,
    lastSyncedAt,
  };
}

export async function fitnessNotices(): Promise<FitnessSyncNotice[]> {
  const { ownerKey } = requireOwner();
  if (typeof indexedDB === "undefined") return [];
  const database = await openDatabase();
  const transaction = database.transaction(NOTICES_STORE, "readonly");
  const values = await requestResult(
    transaction.objectStore(NOTICES_STORE).index(OWNER_INDEX).getAll(ownerKey),
  ) as FitnessNoticeRecord[];
  await transactionDone(transaction);
  return values;
}

export async function dismissFitnessNotice(noticeId: string): Promise<void> {
  const { ownerKey } = requireOwner();
  if (!navigator.onLine) throw new Error("Reconnect before dismissing this sync notice.");
  await api<void>(
    `/fitness/sync/notices/${encodeURIComponent(noticeId)}/dismiss`,
    { method: "POST" },
    true,
    false,
  );
  const database = await openDatabase();
  const transaction = database.transaction(NOTICES_STORE, "readwrite");
  transaction.objectStore(NOTICES_STORE).delete(noticeKey(ownerKey, noticeId));
  await transactionDone(transaction);
  announceFitnessSyncChanged();
}

function publicPendingImport(record: FitnessPendingImportRecord): FitnessPendingImport {
  const { key: _key, ownerKey: _ownerKey, fileBlob, ...value } = record;
  return { ...value, hasLocalFile: fileBlob !== null };
}

async function ownerImportRecords(ownerKey: string): Promise<FitnessPendingImportRecord[]> {
  const database = await openDatabase();
  const transaction = database.transaction(IMPORTS_STORE, "readonly");
  const values = await requestResult(
    transaction.objectStore(IMPORTS_STORE).index(OWNER_INDEX).getAll(ownerKey),
  ) as FitnessPendingImportRecord[];
  await transactionDone(transaction);
  return values.sort((left, right) => right.createdAt.localeCompare(left.createdAt));
}

async function putImportRecord(record: FitnessPendingImportRecord): Promise<void> {
  const database = await openDatabase();
  const transaction = database.transaction(IMPORTS_STORE, "readwrite");
  transaction.objectStore(IMPORTS_STORE).put(record);
  await transactionDone(transaction);
  announceFitnessImportsChanged();
}

export async function fitnessPendingImports(): Promise<FitnessPendingImport[]> {
  const { ownerKey } = requireOwner();
  if (typeof indexedDB === "undefined") return [];
  return (await ownerImportRecords(ownerKey)).map(publicPendingImport);
}

export async function queueFitnessFitImport(file: File): Promise<FitnessPendingImport> {
  if (!file.name.toLowerCase().endsWith(".fit")) {
    throw new Error("Choose a Garmin FIT file ending in .fit.");
  }
  if (file.size === 0) throw new Error("That FIT file is empty.");
  if (file.size > 64 * 1024 * 1024) throw new Error("FIT files must be 64 MB or smaller.");
  const { ownerKey } = requireOwner();
  const id = crypto.randomUUID();
  const now = new Date().toISOString();
  const record: FitnessPendingImportRecord = {
    key: recordKey(ownerKey, "fit_import", id),
    ownerKey,
    id,
    fileName: file.name,
    fileSize: file.size,
    fileType: file.type || "application/octet-stream",
    fileLastModified: file.lastModified,
    fileBlob: file,
    status: "queued",
    serverImportId: null,
    activityId: null,
    sourceRetained: false,
    sourceRecordId: null,
    error: null,
    retryable: true,
    attempts: 0,
    createdAt: now,
    updatedAt: now,
  };
  await putImportRecord(record);
  if (navigator.onLine) void flushFitnessFitImports().catch(() => undefined);
  return publicPendingImport(record);
}

async function refreshServerImport(record: FitnessPendingImportRecord): Promise<FitnessPendingImportRecord> {
  if (!record.serverImportId || (record.status !== "processing" && record.sourceRetained)) return record;
  try {
    const result = await api<FitnessImportResult>(
      `/fitness/imports/${encodeURIComponent(record.serverImportId)}`,
      {},
      true,
      false,
    );
    const sourceRetained = record.sourceRetained || result.source_retained === true;
    const next: FitnessPendingImportRecord = {
      ...record,
      fileBlob: sourceRetained ? null : record.fileBlob,
      status: result.status,
      activityId: result.activity_id ?? record.activityId,
      error: result.error ?? null,
      retryable: result.retryable ?? true,
      sourceRetained,
      sourceRecordId: result.source_record_id ?? record.sourceRecordId,
      updatedAt: result.updated_at ?? new Date().toISOString(),
    };
    await putImportRecord(next);
    return next;
  } catch {
    return record;
  }
}

async function uploadImport(record: FitnessPendingImportRecord): Promise<FitnessPendingImportRecord> {
  if (!record.fileBlob || record.status !== "queued") return record;
  const uploading = { ...record, status: "uploading" as const, error: null, updatedAt: new Date().toISOString() };
  await putImportRecord(uploading);
  const data = new FormData();
  data.append(
    "file",
    new File([record.fileBlob], record.fileName, {
      type: record.fileType,
      lastModified: record.fileLastModified,
    }),
  );
  data.append("client_import_id", record.id);
  try {
    const result = await api<FitnessImportResult>(
      "/fitness/imports/fit",
      { method: "POST", body: data, timeoutMs: 60_000 },
      true,
      false,
    );
    const sourceRetained = result.source_retained === true;
    const next: FitnessPendingImportRecord = {
      ...uploading,
      fileBlob: sourceRetained ? null : record.fileBlob,
      status: result.status,
      serverImportId: result.id,
      activityId: result.activity_id ?? null,
      error: result.error ?? null,
      retryable: result.retryable ?? true,
      sourceRetained,
      sourceRecordId: result.source_record_id ?? null,
      attempts: record.attempts + 1,
      updatedAt: result.updated_at ?? new Date().toISOString(),
    };
    await putImportRecord(next);
    return next;
  } catch (error) {
    const transient = error instanceof TypeError || (error instanceof ApiError && error.status >= 500);
    const next: FitnessPendingImportRecord = {
      ...record,
      status: transient ? "queued" : "error",
      error: error instanceof Error ? error.message : "The FIT file could not be uploaded.",
      retryable: true,
      attempts: record.attempts + 1,
      updatedAt: new Date().toISOString(),
    };
    await putImportRecord(next);
    return next;
  }
}

export async function flushFitnessFitImports(): Promise<FitnessPendingImport[]> {
  if (importFlushRequest) return importFlushRequest;
  importFlushRequest = (async () => {
    if (!navigator.onLine || typeof indexedDB === "undefined") return fitnessPendingImports();
    const { owner, ownerKey } = requireOwner();
    let records = await ownerImportRecords(ownerKey);
    for (const record of records.filter((entry) => entry.status === "queued")) {
      if (!sameOwner(owner)) break;
      await uploadImport(record);
    }
    if (!sameOwner(owner)) return [];
    records = await ownerImportRecords(ownerKey);
    for (const record of records.filter((entry) => (
      entry.status === "processing"
      || (entry.status === "complete" && Boolean(entry.serverImportId) && !entry.sourceRetained)
    ))) {
      if (!sameOwner(owner)) break;
      await refreshServerImport(record);
    }
    if (!sameOwner(owner)) return [];
    return (await ownerImportRecords(ownerKey)).map(publicPendingImport);
  })().finally(() => { importFlushRequest = null; });
  return importFlushRequest;
}

export async function retryFitnessFitImport(importId: string): Promise<void> {
  const { ownerKey } = requireOwner();
  const record = (await ownerImportRecords(ownerKey)).find((entry) => entry.id === importId);
  if (!record) throw new Error("That pending FIT import is no longer on this device.");
  if (record.serverImportId && record.sourceRetained) {
    if (!navigator.onLine) throw new Error("Reconnect before retrying the server import.");
    const result = await api<FitnessImportResult>(
      `/fitness/imports/${encodeURIComponent(record.serverImportId)}/retry`,
      { method: "POST" },
      true,
      false,
    );
    await putImportRecord({
      ...record,
      fileBlob: (record.sourceRetained || result.source_retained === true) ? null : record.fileBlob,
      status: result.status,
      activityId: result.activity_id ?? record.activityId,
      error: result.error ?? null,
      retryable: result.retryable ?? true,
      sourceRetained: record.sourceRetained || result.source_retained === true,
      sourceRecordId: result.source_record_id ?? record.sourceRecordId,
      updatedAt: result.updated_at ?? new Date().toISOString(),
    });
    return;
  }
  if (!record.fileBlob) throw new Error("The local FIT file is no longer available. Choose it again.");
  await putImportRecord({ ...record, status: "queued", error: null, updatedAt: new Date().toISOString() });
  await flushFitnessFitImports();
}

export async function removeFitnessFitImport(importId: string): Promise<void> {
  const { ownerKey } = requireOwner();
  const database = await openDatabase();
  const transaction = database.transaction(IMPORTS_STORE, "readwrite");
  transaction.objectStore(IMPORTS_STORE).delete(recordKey(ownerKey, "fit_import", importId));
  await transactionDone(transaction);
  announceFitnessImportsChanged();
}

function publicProgressPhoto(record: FitnessProgressPhotoRecord): FitnessPendingProgressPhoto {
  const { key: _key, ownerKey: _ownerKey, fileBlob, ...value } = record;
  return { ...value, hasLocalOriginal: fileBlob !== null };
}

async function ownerProgressPhotoRecords(ownerKey: string): Promise<FitnessProgressPhotoRecord[]> {
  const database = await openDatabase();
  const transaction = database.transaction(PROGRESS_PHOTOS_STORE, "readonly");
  const values = await requestResult(
    transaction.objectStore(PROGRESS_PHOTOS_STORE).index(OWNER_INDEX).getAll(ownerKey),
  ) as FitnessProgressPhotoRecord[];
  await transactionDone(transaction);
  return values.sort((left, right) => right.photo.captured_at.localeCompare(left.photo.captured_at));
}

async function putProgressPhotoRecord(record: FitnessProgressPhotoRecord): Promise<void> {
  const database = await openDatabase();
  const transaction = database.transaction(PROGRESS_PHOTOS_STORE, "readwrite");
  transaction.objectStore(PROGRESS_PHOTOS_STORE).put(record);
  await transactionDone(transaction);
  announceFitnessProgressPhotosChanged();
}

export async function fitnessProgressPhotosOnDevice(): Promise<FitnessPendingProgressPhoto[]> {
  const { ownerKey } = requireOwner();
  if (typeof indexedDB === "undefined") return [];
  return (await ownerProgressPhotoRecords(ownerKey)).map(publicProgressPhoto);
}

export async function cacheFitnessProgressPhotos(photos: FitnessProgressPhoto[]): Promise<void> {
  const { owner, ownerKey } = requireOwner();
  if (typeof indexedDB === "undefined") return;
  const existing = new Map(
    (await ownerProgressPhotoRecords(ownerKey)).map((record) => [record.id, record]),
  );
  const now = new Date().toISOString();
  const database = await openDatabase();
  const transaction = database.transaction(PROGRESS_PHOTOS_STORE, "readwrite");
  const store = transaction.objectStore(PROGRESS_PHOTOS_STORE);
  if (!sameOwner(owner)) {
    transaction.abort();
    await transactionDone(transaction).catch(() => undefined);
    return;
  }
  for (const photo of photos) {
    const local = existing.get(photo.id);
    if (local && !local.metadataAcknowledged) continue;
    store.put({
      key: recordKey(ownerKey, "progress_photo", photo.id),
      ownerKey,
      id: photo.id,
      originalAssetId: photo.original_asset_id,
      fileName: local?.fileName ?? "",
      fileSize: local?.fileSize ?? 0,
      fileType: local?.fileType ?? "",
      fileLastModified: local?.fileLastModified ?? 0,
      fileBlob: null,
      photo,
      state: "ready",
      uploadAcknowledged: true,
      metadataAcknowledged: true,
      error: null,
      retryable: false,
      attempts: local?.attempts ?? 0,
      createdAt: local?.createdAt ?? photo.created_at ?? now,
      updatedAt: photo.updated_at ?? now,
    } satisfies FitnessProgressPhotoRecord);
  }
  await transactionDone(transaction);
  announceFitnessProgressPhotosChanged();
}

export async function fitnessProgressPhotoLocalBlob(photoId: string): Promise<Blob | null> {
  const { ownerKey } = requireOwner();
  if (typeof indexedDB === "undefined") return null;
  const database = await openDatabase();
  const transaction = database.transaction(PROGRESS_PHOTOS_STORE, "readonly");
  const record = await requestResult(
    transaction.objectStore(PROGRESS_PHOTOS_STORE).get(recordKey(ownerKey, "progress_photo", photoId)),
  ) as FitnessProgressPhotoRecord | undefined;
  await transactionDone(transaction);
  return record?.ownerKey === ownerKey ? record.fileBlob : null;
}

export async function queueFitnessProgressPhoto(
  file: File,
  metadata: QueueFitnessProgressPhotoInput,
): Promise<FitnessPendingProgressPhoto> {
  const declaredType = file.type.toLocaleLowerCase() === "image/jpg" ? "image/jpeg" : file.type.toLocaleLowerCase();
  const extension = file.name.toLocaleLowerCase().match(/\.([a-z0-9]+)$/)?.[1] ?? "";
  const derivedType = ({
    jpg: "image/jpeg",
    jpeg: "image/jpeg",
    png: "image/png",
    heic: "image/heic",
    heif: "image/heif",
  } as Record<string, string>)[extension] ?? null;
  const mediaType = /^(image\/(jpeg|png|heic|heif))$/.test(declaredType)
    ? declaredType
    : declaredType
      ? null
      : derivedType;
  if (!mediaType) throw new Error("Choose a JPEG, PNG, HEIC, or HEIF image with a recognised media type.");
  if (file.size === 0) throw new Error("That photograph is empty.");
  if (file.size > 25 * 1024 * 1024) throw new Error("Progress photographs must be 25 MB or smaller.");
  if (!metadata.captured_at || !metadata.pose) throw new Error("Capture date and pose are required.");
  const { owner, ownerKey } = requireOwner();
  const id = crypto.randomUUID();
  const originalAssetId = crypto.randomUUID();
  const now = new Date().toISOString();
  const record: FitnessProgressPhotoRecord = {
    key: recordKey(ownerKey, "progress_photo", id),
    ownerKey,
    id,
    originalAssetId,
    fileName: file.name,
    fileSize: file.size,
    fileType: mediaType,
    fileLastModified: file.lastModified,
    fileBlob: file,
    photo: {
      id,
      captured_at: metadata.captured_at,
      pose: metadata.pose,
      body_weight_kg: metadata.body_weight_kg ?? null,
      measurement_snapshot_json: metadata.measurement_snapshot_json ?? null,
      phase_id: metadata.phase_id ?? null,
      original_asset_id: originalAssetId,
      original_state: "pending",
      thumbnail_state: "pending",
      notes: metadata.notes ?? null,
      created_at: now,
      updated_at: now,
    },
    state: "pending_upload",
    uploadAcknowledged: false,
    metadataAcknowledged: false,
    error: null,
    retryable: true,
    attempts: 0,
    createdAt: now,
    updatedAt: now,
  };
  // IndexedDB commits the durable Blob and metadata together before capture is
  // reported as saved. A network request is never the only copy.
  if (!sameOwner(owner)) throw new Error("The signed-in Fitness owner changed before this photograph was saved.");
  await putProgressPhotoRecord(record);
  if (!sameOwner(owner)) throw new Error("The signed-in Fitness owner changed before this photograph was saved.");
  if (navigator.onLine) void flushFitnessProgressPhotos().catch(() => undefined);
  return publicProgressPhoto(record);
}

async function uploadProgressPhotoOriginal(
  record: FitnessProgressPhotoRecord,
  owner: OfflineQueueOwner,
): Promise<FitnessProgressPhotoRecord> {
  if (record.uploadAcknowledged || !record.fileBlob) return record;
  if (!sameOwner(owner)) return record;
  const uploading: FitnessProgressPhotoRecord = {
    ...record,
    state: "uploading",
    error: null,
    updatedAt: new Date().toISOString(),
  };
  await putProgressPhotoRecord(uploading);
  if (!sameOwner(owner)) return record;
  const data = new FormData();
  data.append("file", new File([record.fileBlob], record.fileName, {
    type: record.fileType,
    lastModified: record.fileLastModified,
  }));
  data.append("asset_id", record.originalAssetId);
  data.append("asset_kind", "progress_photo");
  try {
    const result = await api<FitnessPrivateAssetUploadResult>(
      "/fitness/files/private",
      { method: "POST", body: data, timeoutMs: 60_000 },
      true,
      false,
    );
    if (!sameOwner(owner)) return record;
    const acknowledged = result.upload_acknowledged === true
      && result.asset_id === record.originalAssetId
      && result.state === "staged"
      && result.storage_class === "private_required";
    if (!acknowledged) {
      throw new Error("The server did not explicitly acknowledge the staged private original.");
    }
    const next: FitnessProgressPhotoRecord = {
      ...uploading,
      // Keep the Blob: staged upload alone is not enough to release it.
      fileBlob: record.fileBlob,
      state: "uploaded_waiting_metadata",
      uploadAcknowledged: true,
      error: null,
      attempts: record.attempts + 1,
      photo: { ...record.photo, original_state: "staged" },
      updatedAt: new Date().toISOString(),
    };
    if (!sameOwner(owner)) return record;
    await putProgressPhotoRecord(next);
    return next;
  } catch (error) {
    if (!sameOwner(owner)) return record;
    const next: FitnessProgressPhotoRecord = {
      ...record,
      state: "error",
      error: error instanceof Error ? error.message : "The private original could not be uploaded.",
      retryable: true,
      attempts: record.attempts + 1,
      updatedAt: new Date().toISOString(),
    };
    await putProgressPhotoRecord(next);
    return next;
  }
}

async function acknowledgeProgressPhotoMetadata(
  record: FitnessProgressPhotoRecord,
  owner: OfflineQueueOwner,
): Promise<FitnessProgressPhotoRecord> {
  if (!record.uploadAcknowledged || record.metadataAcknowledged) return record;
  if (!sameOwner(owner)) return record;
  const saving: FitnessProgressPhotoRecord = {
    ...record,
    state: "saving_metadata",
    error: null,
    updatedAt: new Date().toISOString(),
  };
  await putProgressPhotoRecord(saving);
  if (!sameOwner(owner)) return record;
  const { id, captured_at, pose, body_weight_kg, measurement_snapshot_json, phase_id, original_asset_id, notes } = record.photo;
  try {
    const result = await api<FitnessProgressPhoto>(
      "/fitness/progress-photos",
      {
        method: "POST",
        body: JSON.stringify({
          id,
          captured_at,
          pose,
          body_weight_kg: body_weight_kg ?? null,
          measurement_snapshot_json: measurement_snapshot_json ?? null,
          phase_id: phase_id ?? null,
          original_asset_id,
          notes: notes ?? null,
        }),
      },
      true,
      false,
    );
    if (!sameOwner(owner)) return record;
    const acknowledged = result.metadata_acknowledged === true
      && result.id === record.id
      && result.original_asset_id === record.originalAssetId;
    if (!acknowledged) {
      throw new Error("The server did not explicitly acknowledge the progress-photo metadata.");
    }
    const next: FitnessProgressPhotoRecord = {
      ...saving,
      // Both independent acknowledgements now exist; the protected server
      // original, not this local Blob, becomes the required source of truth.
      fileBlob: null,
      photo: { ...record.photo, ...result, metadata_acknowledged: true },
      state: "ready",
      metadataAcknowledged: true,
      error: null,
      retryable: false,
      updatedAt: result.updated_at ?? new Date().toISOString(),
    };
    if (!sameOwner(owner)) return record;
    await putProgressPhotoRecord(next);
    return next;
  } catch (error) {
    if (!sameOwner(owner)) return record;
    const next: FitnessProgressPhotoRecord = {
      ...record,
      state: "error",
      error: error instanceof Error ? error.message : "The photograph metadata could not be saved.",
      retryable: true,
      attempts: record.attempts + 1,
      updatedAt: new Date().toISOString(),
    };
    await putProgressPhotoRecord(next);
    return next;
  }
}

export async function flushFitnessProgressPhotos(): Promise<FitnessPendingProgressPhoto[]> {
  if (progressPhotoFlushRequest) {
    progressPhotoFlushAgainRequested = true;
    return progressPhotoFlushRequest;
  }
  progressPhotoFlushRequest = (async () => {
    if (!navigator.onLine || typeof indexedDB === "undefined") return fitnessProgressPhotosOnDevice();
    const { owner, ownerKey } = requireOwner();
    const records = await ownerProgressPhotoRecords(ownerKey);
    for (const record of records.filter((entry) => !entry.metadataAcknowledged)) {
      if (!sameOwner(owner)) break;
      let next = record;
      if (!next.uploadAcknowledged) next = await uploadProgressPhotoOriginal(next, owner);
      if (!sameOwner(owner)) break;
      if (next.uploadAcknowledged && !next.metadataAcknowledged) {
        await acknowledgeProgressPhotoMetadata(next, owner);
      }
    }
    if (!sameOwner(owner)) return [];
    return (await ownerProgressPhotoRecords(ownerKey)).map(publicProgressPhoto);
  })().finally(() => {
    progressPhotoFlushRequest = null;
    if (progressPhotoFlushAgainRequested) {
      progressPhotoFlushAgainRequested = false;
      void flushFitnessProgressPhotos().catch(() => undefined);
    }
  });
  return progressPhotoFlushRequest;
}

export async function retryFitnessProgressPhoto(photoId: string): Promise<void> {
  const { owner, ownerKey } = requireOwner();
  const record = (await ownerProgressPhotoRecords(ownerKey)).find((entry) => entry.id === photoId);
  if (!record) throw new Error("That progress photograph is no longer on this device.");
  if (!record.uploadAcknowledged && !record.fileBlob) {
    throw new Error("The local original is missing. Choose the photograph again before retrying.");
  }
  if (!sameOwner(owner)) return;
  await putProgressPhotoRecord({
    ...record,
    state: record.uploadAcknowledged ? "uploaded_waiting_metadata" : "pending_upload",
    error: null,
    retryable: true,
    updatedAt: new Date().toISOString(),
  });
  if (!sameOwner(owner)) return;
  if (navigator.onLine) await flushFitnessProgressPhotos();
}

export async function removeFitnessProgressPhotoFromDevice(photoId: string): Promise<void> {
  const { ownerKey } = requireOwner();
  const record = (await ownerProgressPhotoRecords(ownerKey)).find((entry) => entry.id === photoId);
  if (!record) return;
  if (!record.metadataAcknowledged && progressPhotoFlushRequest) {
    throw new Error("Wait for the current private save to finish, then delete the photograph.");
  }
  const database = await openDatabase();
  const transaction = database.transaction(PROGRESS_PHOTOS_STORE, "readwrite");
  transaction.objectStore(PROGRESS_PHOTOS_STORE).delete(recordKey(ownerKey, "progress_photo", photoId));
  await transactionDone(transaction);
  announceFitnessProgressPhotosChanged();
}

/** Remove one owner's private Fitness cache and pending local files. */
export async function purgeFitnessOwnerData(owner: OfflineQueueOwner): Promise<void> {
  if (!owner || typeof indexedDB === "undefined") return;
  const ownerKey = ownerStorageKey(owner);
  const database = await openDatabase();
  const storeNames = [
    RECORDS_STORE,
    OUTBOX_STORE,
    META_STORE,
    NOTICES_STORE,
    IMPORTS_STORE,
    PROGRESS_PHOTOS_STORE,
    NUTRITION_LABELS_STORE,
    PLANNED_MEAL_LOGS_STORE,
  ];
  const transaction = database.transaction(storeNames, "readwrite");
  const stores = storeNames.map((storeName) => transaction.objectStore(storeName));
  const valuesByStore = await Promise.all(stores.map((store) => (
    requestResult(store.index(OWNER_INDEX).getAll(ownerKey)) as Promise<Array<{ key: string; ownerKey?: string }>>
  )));
  stores.forEach((store, index) => {
    const values = valuesByStore[index];
    for (const value of values) {
      store.delete(value.key);
    }
  });
  await transactionDone(transaction);
  announceFitnessSyncChanged();
  announceFitnessImportsChanged();
  announceFitnessProgressPhotosChanged();
  announceFitnessNutritionLabelsChanged();
  announceFitnessPlannedMealsChanged();
}

export async function purgeCurrentFitnessOwnerData(): Promise<void> {
  const owner = currentOfflineQueueOwner();
  if (!owner) return;
  await purgeFitnessOwnerData(owner);
}
