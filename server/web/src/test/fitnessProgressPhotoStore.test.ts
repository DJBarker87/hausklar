import { IDBFactory } from "fake-indexeddb";
import { beforeEach, describe, expect, it, vi } from "vitest";

import { setOfflineQueueOwner } from "../offlineQueue";
import {
  fitnessProgressPhotoLocalBlob,
  fitnessProgressPhotosOnDevice,
  flushFitnessProgressPhotos,
  purgeCurrentFitnessOwnerData,
  queueFitnessProgressPhoto,
  retryFitnessProgressPhoto,
} from "../fitness/offlineStore";

const dom = { id: "dom", family_id: "family-a" };
const kat = { id: "kat", family_id: "family-a" };

function setOnline(value: boolean) {
  Object.defineProperty(window.navigator, "onLine", { configurable: true, value });
}

function photograph(name = "front.jpg", type = "image/jpeg") {
  return new File([new Uint8Array([255, 216, 255, 217])], name, {
    type,
    lastModified: Date.parse("2026-08-02T08:00:00Z"),
  });
}

describe("Fitness progress-photo private queue", () => {
  beforeEach(() => {
    Object.defineProperty(globalThis, "indexedDB", {
      configurable: true,
      value: new IDBFactory(),
    });
    setOfflineQueueOwner(dom);
    setOnline(false);
    vi.restoreAllMocks();
  });

  it("commits the original Blob before reporting an offline capture saved", async () => {
    const queued = await queueFitnessProgressPhoto(photograph(), {
      captured_at: "2026-08-02T08:00:00Z",
      pose: "front",
      body_weight_kg: 78.4,
      measurement_snapshot_json: { waist_cm: 82 },
    });

    expect(queued).toMatchObject({
      state: "pending_upload",
      uploadAcknowledged: false,
      metadataAcknowledged: false,
      hasLocalOriginal: true,
      photo: {
        pose: "front",
        body_weight_kg: 78.4,
        original_state: "pending",
      },
    });
    const durable = await fitnessProgressPhotoLocalBlob(queued.id);
    // fake-indexeddb does not preserve jsdom's cross-realm Blob prototype, so
    // the public retained-original flag plus a non-null durable value is the
    // reliable assertion here. Real browsers retain the native Blob.
    expect(durable).not.toBeNull();
  });

  it("derives an allowlisted image MIME from a recognised extension", async () => {
    const queued = await queueFitnessProgressPhoto(photograph("side.heic", ""), {
      captured_at: "2026-08-02T08:00:00Z",
      pose: "side_left",
    });

    expect(queued).toMatchObject({ fileType: "image/heic", hasLocalOriginal: true });
  });

  it("retains the local original until upload and metadata are explicitly acknowledged", async () => {
    const queued = await queueFitnessProgressPhoto(photograph(), {
      captured_at: "2026-08-02T08:00:00Z",
      pose: "front",
    });
    let metadataAcknowledged = false;
    const requests: string[] = [];
    vi.stubGlobal("fetch", vi.fn<typeof fetch>().mockImplementation(async (input, init) => {
      const path = String(input);
      requests.push(path);
      if (path.endsWith("/fitness/files/private")) {
        return new Response(JSON.stringify({
          asset_id: queued.originalAssetId,
          state: "staged",
          storage_class: "private_required",
          upload_acknowledged: true,
        }), { status: 200, headers: { "content-type": "application/json" } });
      }
      if (path.endsWith("/fitness/progress-photos")) {
        const body = JSON.parse(String(init?.body)) as Record<string, unknown>;
        return new Response(JSON.stringify({
          ...body,
          original_state: metadataAcknowledged ? "ready" : "staged",
          thumbnail_state: "pending",
          metadata_acknowledged: metadataAcknowledged,
        }), { status: 200, headers: { "content-type": "application/json" } });
      }
      throw new Error(`Unexpected request: ${path}`);
    }));
    setOnline(true);

    await flushFitnessProgressPhotos();
    expect(await fitnessProgressPhotosOnDevice()).toEqual([
      expect.objectContaining({
        id: queued.id,
        state: "error",
        uploadAcknowledged: true,
        metadataAcknowledged: false,
        hasLocalOriginal: true,
      }),
    ]);
    expect(requests.filter((path) => path.endsWith("/fitness/files/private"))).toHaveLength(1);

    metadataAcknowledged = true;
    await retryFitnessProgressPhoto(queued.id);
    expect(await fitnessProgressPhotosOnDevice()).toEqual([
      expect.objectContaining({
        id: queued.id,
        state: "ready",
        uploadAcknowledged: true,
        metadataAcknowledged: true,
        hasLocalOriginal: false,
      }),
    ]);
    expect(requests.filter((path) => path.endsWith("/fitness/files/private"))).toHaveLength(1);
    expect(requests.filter((path) => path.endsWith("/fitness/progress-photos"))).toHaveLength(2);
  });

  it("isolates private Blobs by owner and purges only the deleted owner", async () => {
    await queueFitnessProgressPhoto(photograph("dom.jpg"), {
      captured_at: "2026-08-02T08:00:00Z",
      pose: "front",
    });
    setOfflineQueueOwner(kat);
    expect(await fitnessProgressPhotosOnDevice()).toEqual([]);
    await queueFitnessProgressPhoto(photograph("kat.jpg"), {
      captured_at: "2026-08-01T08:00:00Z",
      pose: "back",
    });

    setOfflineQueueOwner(dom);
    await purgeCurrentFitnessOwnerData();
    expect(await fitnessProgressPhotosOnDevice()).toEqual([]);
    setOfflineQueueOwner(kat);
    expect(await fitnessProgressPhotosOnDevice()).toEqual([
      expect.objectContaining({ fileName: "kat.jpg", hasLocalOriginal: true }),
    ]);
  });

  it("does not apply an upload acknowledgement after the active owner changes", async () => {
    const queued = await queueFitnessProgressPhoto(photograph(), {
      captured_at: "2026-08-02T08:00:00Z",
      pose: "front",
    });
    let releaseUpload: (response: Response) => void = () => {};
    let markStarted: () => void = () => {};
    const started = new Promise<void>((resolve) => { markStarted = resolve; });
    vi.stubGlobal("fetch", vi.fn<typeof fetch>().mockImplementation(async (input) => {
      if (!String(input).endsWith("/fitness/files/private")) throw new Error(`Unexpected request: ${input}`);
      markStarted();
      return new Promise<Response>((resolve) => { releaseUpload = resolve; });
    }));
    setOnline(true);

    const flushing = flushFitnessProgressPhotos();
    await started;
    setOfflineQueueOwner(kat);
    releaseUpload(new Response(JSON.stringify({
      asset_id: queued.originalAssetId,
      state: "staged",
      storage_class: "private_required",
      upload_acknowledged: true,
    }), { status: 200, headers: { "content-type": "application/json" } }));
    await flushing;

    expect(await fitnessProgressPhotosOnDevice()).toEqual([]);
    setOfflineQueueOwner(dom);
    expect(await fitnessProgressPhotosOnDevice()).toEqual([
      expect.objectContaining({ id: queued.id, uploadAcknowledged: false, metadataAcknowledged: false, hasLocalOriginal: true }),
    ]);
  });
});
