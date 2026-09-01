import { IDBFactory } from "fake-indexeddb";
import { beforeEach, describe, expect, it, vi } from "vitest";

import {
  abandonFitnessNutritionLabel,
  cachedFitnessRecords,
  fitnessNutritionLabelsOnDevice,
  fitnessSyncSummary,
  flushFitnessNutritionLabels,
  flushFitnessSync,
  queueFitnessNutritionLabel,
} from "../fitness/offlineStore";
import { setOfflineQueueOwner } from "../offlineQueue";

const owner = { id: "dom", family_id: "family-a" };

function setOnline(value: boolean) {
  Object.defineProperty(window.navigator, "onLine", { configurable: true, value });
}

function labelImage() {
  return new File([new Uint8Array([255, 216, 255, 217])], "label.jpg", {
    type: "image/jpeg",
    lastModified: Date.parse("2026-08-02T08:00:00Z"),
  });
}

function syncResponse(overrides: Record<string, unknown> = {}) {
  return {
    status: "ok",
    current_sync_protocol_version: 1,
    current_client_schema_version: 1,
    minimum_supported_client_schema_version: 1,
    accepted: [],
    acked_mutation_ids: [],
    rejected_mutations: [],
    changes: [],
    redirects: [],
    notices: [],
    next_cursor: 1,
    ...overrides,
  };
}

async function queueLabel() {
  return queueFitnessNutritionLabel(labelImage(), {
    entityType: "food",
    payload: {
      name: "Porridge",
      household_shared: false,
      active: true,
      version: {
        id: "version-1",
        reference_amount: 100,
        reference_unit: "g",
        calories_kcal: 120,
      },
    },
    options: { entityId: "food-1" },
  });
}

describe("Fitness nutrition-label private queue", () => {
  beforeEach(() => {
    Object.defineProperty(globalThis, "indexedDB", {
      configurable: true,
      value: new IDBFactory(),
    });
    setOfflineQueueOwner(owner);
    setOnline(false);
    vi.restoreAllMocks();
  });

  it("atomically retains the Blob, local food version, and dependent mutation offline", async () => {
    const queued = await queueLabel();

    expect(queued.label).toMatchObject({
      state: "pending_upload",
      uploadAcknowledged: false,
      dependentAcknowledged: false,
      hasLocalOriginal: true,
    });
    expect(queued.record).toMatchObject({
      id: "food-1",
      version: { id: "version-1", label_asset_id: queued.label.assetId },
    });
    expect(await cachedFitnessRecords("food")).toEqual([
      expect.objectContaining({
        id: "food-1",
        version: expect.objectContaining({ label_asset_id: queued.label.assetId }),
      }),
    ]);
    expect(await fitnessSyncSummary()).toMatchObject({ pending: 1 });
  });

  it("releases the local original only after upload and dependent mutation acknowledgements", async () => {
    const queued = await queueLabel();
    vi.stubGlobal("fetch", vi.fn<typeof fetch>().mockImplementation(async (input, init) => {
      const path = String(input);
      if (path.endsWith("/fitness/files/private")) {
        const data = init?.body as FormData;
        expect(data.get("asset_kind")).toBe("nutrition_label");
        expect(data.get("asset_id")).toBe(queued.label.assetId);
        expect(data.get("file")).toBeTruthy();
        return new Response(JSON.stringify({
          asset_id: queued.label.assetId,
          state: "staged",
          storage_class: "private_required",
          upload_acknowledged: true,
        }), { status: 200, headers: { "content-type": "application/json" } });
      }
      if (path.endsWith("/fitness/sync")) {
        const body = JSON.parse(String(init?.body)) as { mutations: Array<{ mutation_id: string; entity_id: string; payload: Record<string, unknown> }> };
        expect(body.mutations).toHaveLength(1);
        expect(body.mutations[0]?.payload).toMatchObject({
          version: { label_asset_id: queued.label.assetId },
        });
        const mutation = body.mutations[0]!;
        return new Response(JSON.stringify(syncResponse({
          accepted: [{ mutation_id: mutation.mutation_id, entity_id: mutation.entity_id, revision: 1 }],
          acked_mutation_ids: [mutation.mutation_id],
        })), { status: 200, headers: { "content-type": "application/json" } });
      }
      throw new Error(`Unexpected request: ${path}`);
    }));
    setOnline(true);

    await flushFitnessNutritionLabels();

    expect(await fitnessNutritionLabelsOnDevice()).toEqual([
      expect.objectContaining({
        id: queued.label.id,
        state: "ready",
        uploadAcknowledged: true,
        dependentAcknowledged: true,
        hasLocalOriginal: false,
      }),
    ]);
    expect(await fitnessSyncSummary()).toMatchObject({ pending: 0 });
  });

  it("requests a second sync when label staging races the reconnect sync", async () => {
    const queued = await queueLabel();
    let releaseFirstSync = () => {};
    let markFirstSyncStarted = () => {};
    let markUploadStarted = () => {};
    const firstSyncGate = new Promise<void>((resolve) => { releaseFirstSync = resolve; });
    const firstSyncStarted = new Promise<void>((resolve) => { markFirstSyncStarted = resolve; });
    const uploadStarted = new Promise<void>((resolve) => { markUploadStarted = resolve; });
    let syncCalls = 0;
    vi.stubGlobal("fetch", vi.fn<typeof fetch>().mockImplementation(async (input, init) => {
      const path = String(input);
      if (path.endsWith("/fitness/files/private")) {
        markUploadStarted();
        return new Response(JSON.stringify({
          asset_id: queued.label.assetId,
          state: "staged",
          storage_class: "private_required",
          upload_acknowledged: true,
        }), { status: 200, headers: { "content-type": "application/json" } });
      }
      if (path.endsWith("/fitness/sync")) {
        syncCalls += 1;
        const body = JSON.parse(String(init?.body)) as { mutations: Array<{ mutation_id: string; entity_id: string }> };
        if (syncCalls === 1) {
          expect(body.mutations).toHaveLength(0);
          markFirstSyncStarted();
          await firstSyncGate;
          return new Response(JSON.stringify(syncResponse()), { status: 200, headers: { "content-type": "application/json" } });
        }
        expect(body.mutations).toHaveLength(1);
        const mutation = body.mutations[0]!;
        return new Response(JSON.stringify(syncResponse({
          accepted: [{ mutation_id: mutation.mutation_id, entity_id: mutation.entity_id, revision: 1 }],
          acked_mutation_ids: [mutation.mutation_id],
          next_cursor: 2,
        })), { status: 200, headers: { "content-type": "application/json" } });
      }
      throw new Error(`Unexpected request: ${path}`);
    }));
    setOnline(true);

    const reconnectSync = flushFitnessSync();
    await firstSyncStarted;
    const labelFlush = flushFitnessNutritionLabels();
    await uploadStarted;
    releaseFirstSync();
    await Promise.all([reconnectSync, labelFlush]);
    for (let attempt = 0; attempt < 20 && (await fitnessSyncSummary()).pending; attempt += 1) {
      await new Promise((resolve) => window.setTimeout(resolve, 0));
    }

    expect(syncCalls).toBe(2);
    expect(await fitnessSyncSummary()).toMatchObject({ pending: 0 });
    expect(await fitnessNutritionLabelsOnDevice()).toEqual([
      expect.objectContaining({ state: "ready", uploadAcknowledged: true, dependentAcknowledged: true, hasLocalOriginal: false }),
    ]);
  });

  it("keeps an uploaded staged original until the user abandons its unacknowledged version", async () => {
    const queued = await queueLabel();
    const requests: Array<{ path: string; method?: string }> = [];
    vi.stubGlobal("fetch", vi.fn<typeof fetch>().mockImplementation(async (input, init) => {
      const path = String(input);
      requests.push({ path, method: init?.method });
      if (path.endsWith("/fitness/files/private") && init?.method === "POST") {
        return new Response(JSON.stringify({
          asset_id: queued.label.assetId,
          state: "staged",
          storage_class: "private_required",
          upload_acknowledged: true,
        }), { status: 200, headers: { "content-type": "application/json" } });
      }
      if (path.endsWith("/fitness/sync")) {
        return new Response(JSON.stringify(syncResponse()), { status: 200, headers: { "content-type": "application/json" } });
      }
      if (path.endsWith(`/fitness/files/private/${queued.label.assetId}`) && init?.method === "DELETE") {
        return new Response(null, { status: 204 });
      }
      throw new Error(`Unexpected request: ${path}`);
    }));
    setOnline(true);

    await flushFitnessNutritionLabels();
    expect(await fitnessNutritionLabelsOnDevice()).toEqual([
      expect.objectContaining({
        state: "uploaded_waiting_reference",
        uploadAcknowledged: true,
        dependentAcknowledged: false,
        hasLocalOriginal: true,
      }),
    ]);

    await abandonFitnessNutritionLabel(queued.label.id);
    expect(await fitnessNutritionLabelsOnDevice()).toEqual([]);
    expect(await fitnessSyncSummary()).toMatchObject({ pending: 0 });
    expect(requests).toContainEqual(expect.objectContaining({
      path: expect.stringContaining(`/fitness/files/private/${queued.label.assetId}`),
      method: "DELETE",
    }));
  });
});
