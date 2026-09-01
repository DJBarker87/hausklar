import { fireEvent, render, screen, waitFor, within } from "@testing-library/react";
import { beforeEach, describe, expect, it, vi } from "vitest";

import { api } from "../api";
import {
  fitnessProgressPhotosOnDevice,
  queueFitnessProgressPhoto,
  removeFitnessProgressPhotoFromDevice,
  saveFitnessRecord,
  type FitnessPendingProgressPhoto,
} from "../fitness/offlineStore";
import type { FitnessProgressPhoto } from "../fitness/contract";
import { FitnessProgressPhotos } from "../views/fitness/FitnessProgressPhotos";
import { FitnessRecoveryView } from "../views/fitness/FitnessRecoveryView";

vi.mock("../api", () => ({
  api: vi.fn(),
  ApiError: class ApiError extends Error {
    status: number;
    constructor(message: string, status: number) { super(message); this.status = status; }
  },
}));

vi.mock("../fitness/offlineStore", () => ({
  cacheFitnessRecords: vi.fn().mockResolvedValue(undefined),
  cachedFitnessRecords: vi.fn().mockResolvedValue([]),
  saveFitnessRecord: vi.fn(),
  saveFitnessRecords: vi.fn(),
  cacheFitnessProgressPhotos: vi.fn().mockResolvedValue(undefined),
  fitnessProgressPhotoLocalBlob: vi.fn().mockResolvedValue(null),
  fitnessProgressPhotosOnDevice: vi.fn().mockResolvedValue([]),
  flushFitnessProgressPhotos: vi.fn().mockResolvedValue([]),
  queueFitnessProgressPhoto: vi.fn(),
  removeFitnessProgressPhotoFromDevice: vi.fn().mockResolvedValue(undefined),
  retryFitnessProgressPhoto: vi.fn().mockResolvedValue(undefined),
}));

const apiMock = vi.mocked(api);
const saveMock = vi.mocked(saveFitnessRecord);
const queuePhotoMock = vi.mocked(queueFitnessProgressPhoto);
const removePhotoMock = vi.mocked(removeFitnessProgressPhotoFromDevice);
const onDevicePhotosMock = vi.mocked(fitnessProgressPhotosOnDevice);
const props = {
  online: true,
  revision: 0,
  onDataChanged: vi.fn(),
  onSectionChange: vi.fn(),
};

function readyRecord(photo: FitnessProgressPhoto): FitnessPendingProgressPhoto {
  return {
    id: photo.id,
    originalAssetId: photo.original_asset_id,
    fileName: `${photo.pose}.jpg`,
    fileSize: 1024,
    fileType: "image/jpeg",
    fileLastModified: Date.parse(photo.captured_at),
    photo,
    state: "ready",
    uploadAcknowledged: true,
    metadataAcknowledged: true,
    error: null,
    retryable: false,
    attempts: 1,
    createdAt: photo.captured_at,
    updatedAt: photo.captured_at,
    hasLocalOriginal: false,
  };
}

describe("Fitness Stage 13 recovery and private photographs", () => {
  beforeEach(() => {
    apiMock.mockReset();
    saveMock.mockReset();
    queuePhotoMock.mockReset();
    removePhotoMock.mockClear();
    onDevicePhotosMock.mockReset();
    onDevicePhotosMock.mockResolvedValue([]);
    props.onDataChanged.mockReset();
    Object.defineProperty(window.navigator, "onLine", { configurable: true, value: true });
    Object.defineProperty(URL, "createObjectURL", { configurable: true, value: vi.fn(() => "blob:private-preview") });
    Object.defineProperty(URL, "revokeObjectURL", { configurable: true, value: vi.fn() });
    saveMock.mockImplementation(async (_entityType, payload, options) => ({
      ...payload,
      id: options?.entityId ?? crypto.randomUUID(),
      queued_offline: true,
    }));
  });

  it("shows useful sleep first and loads signals, connections, and issues only from Manage", async () => {
    apiMock.mockImplementation(async (path) => {
      if (String(path).startsWith("/fitness/sleep/sessions?")) return [{
        id: "sleep-1",
        sleep_start_utc: "2026-08-01T21:30:00Z",
        sleep_end_utc: "2026-08-02T05:15:00Z",
        duration_s: 27_900,
        awake_duration_s: 900,
        source_quality: "wearable",
        source_stages: [{ stage: "deep", start_at_utc: "2026-08-01T22:00:00Z", end_at_utc: "2026-08-01T23:00:00Z", duration_s: 3600 }],
        source: { transport_key: "healthkit", origin_provider_key: "apple", source_namespace: "com.apple.health", source_device_identifier: "Apple Watch", state: "active" },
      }];
      if (String(path).startsWith("/fitness/recovery/observations?")) return [{
        id: "hrv-1",
        metric_key: "recovery.hrv_sdnn_ms",
        observed_at_utc: "2026-08-02T05:20:00Z",
        value_number: 51,
        unit_key: "ms",
        source_quality: "wearable",
        source: { transport_key: "healthkit", origin_provider_key: "apple", source_namespace: "com.apple.health", source_device_identifier: "Apple Watch", state: "active" },
      }];
      if (String(path).startsWith("/fitness/recovery/summary?")) return {
        window: { from_date: "2026-07-06", to_date: "2026-08-02", expected_days: 28, days_with_sleep: 19 },
        sleep: { average_duration_s: 27_900, average_bedtime_minutes: 1320, average_wake_time_minutes: 390, timing_regularity_minutes: 31 },
        baselines: [{ metric_key: "recovery.hrv_sdnn_ms", label: "HRV (SDNN)", unit_key: "ms", current_value: 51, baseline_value: 47, deviation_absolute: 4, deviation_percent: 8.5, status: "above_baseline", window_days: 28, observed_at_utc: "2026-08-02T05:20:00Z", source_name: "Apple Watch" }],
        relationships: [{ label: "Readiness and session outcome", summary: "Higher pre-session readiness coincided with stronger perceived outcomes.", sample_size: 7, limitation: "Small sample" }],
      };
      if (path === "/fitness/session-checkins") return [
        { id: "ready-1", captured_at_utc: "2026-08-02T06:00:00Z", timing: "pre", capture_quality: "contemporaneous", captured_before_activity_start: true, readiness_1_5: 4 },
        { id: "ready-2", captured_at_utc: "2026-08-01T08:00:00Z", timing: "pre", capture_quality: "retrospective", readiness_1_5: 2 },
      ];
      if (path === "/fitness/body-issues") return [{ id: "issue-1", observed_at_utc: "2026-08-01T08:00:00Z", issue_type_key: "pain", body_location_key: "left_knee", side: "left", severity_0_10: 3, timing: "post", changed_session: true, session_change_key: "reduced_pace", status: "resolved", resolved_at_utc: "2026-08-02T08:00:00Z" }];
      if (path === "/fitness/body-locations") return [{ id: "body-knee", location_key: "knee", display_name: "Knee", active: true }];
      throw new Error(`Unexpected request: ${path}`);
    });

    render(<FitnessRecoveryView {...props} />);

    expect((await screen.findAllByText("7h 45m")).length).toBeGreaterThan(0);
    expect(screen.getByText(/19 nights logged/)).toBeInTheDocument();
    expect(screen.getByRole("heading", { name: "How ready do you feel?" })).toBeInTheDocument();
    expect(apiMock.mock.calls.some(([path]) => String(path).startsWith("/fitness/recovery/observations?") || path === "/fitness/body-issues")).toBe(false);

    fireEvent.click(screen.getByText("Manage Recovery"));
    expect(await screen.findByText("HRV (SDNN)")).toBeInTheDocument();
    expect(screen.getByText("Above usual")).toBeInTheDocument();
    expect(screen.getByText("Apple Health")).toBeInTheDocument();
    expect(screen.getByText("Recovery and training")).toBeInTheDocument();

    fireEvent.click(screen.getByRole("button", { name: /Body issues/ }));
    expect(await screen.findByText(/left knee · 3\/10/i)).toBeInTheDocument();
    expect(screen.getByText("Resolved history (1)")).toBeInTheDocument();
  });

  it("saves manual sleep and recovery observations through the offline Fitness outbox", async () => {
    apiMock.mockImplementation(async (path) => {
      if (String(path).startsWith("/fitness/sleep/sessions?") || String(path).startsWith("/fitness/recovery/observations?")) return [];
      if (String(path).startsWith("/fitness/recovery/summary?")) return { window: { from_date: "", to_date: "", expected_days: 28, days_with_sleep: 0 }, sleep: {}, baselines: [], relationships: [] };
      if (path === "/fitness/session-checkins" || path === "/fitness/body-issues") return [];
      if (path === "/fitness/body-locations") return [{ id: "body-knee", location_key: "knee", display_name: "Knee", active: true }];
      throw new Error(`Unexpected request: ${path}`);
    });
    render(<FitnessRecoveryView {...props} />);
    await screen.findByText("No sleep logged yet");

    fireEvent.click(screen.getByRole("button", { name: "Add sleep" }));
    fireEvent.change(screen.getByLabelText("Sleep start"), { target: { value: "2026-08-01T22:00" } });
    fireEvent.change(screen.getByLabelText("Wake time"), { target: { value: "2026-08-02T06:30" } });
    fireEvent.click(screen.getByRole("button", { name: "Save sleep" }));
    await waitFor(() => expect(saveMock).toHaveBeenCalledWith("sleep_session", expect.objectContaining({
      duration_s: 30_600,
      source_quality: "manual",
      source: null,
    }), undefined));

    fireEvent.click(screen.getByText("Manage Recovery"));
    fireEvent.click(await screen.findByRole("button", { name: "Add recovery note" }));
    fireEvent.change(screen.getByLabelText("What are you recording?"), { target: { value: "recovery.hrv_rmssd_ms" } });
    fireEvent.change(screen.getByLabelText(/^Value \(ms\)/), { target: { value: "48" } });
    fireEvent.click(screen.getByRole("button", { name: "Save value" }));
    await waitFor(() => expect(saveMock).toHaveBeenCalledWith("recovery_observation", expect.objectContaining({
      metric_key: "recovery.hrv_rmssd_ms",
      value_number: 48,
      unit_key: "ms",
      source_quality: "manual",
    }), undefined));

    fireEvent.click(screen.getByRole("button", { name: /Body issues/ }));
    fireEvent.click(await screen.findByRole("button", { name: "Add body issue" }));
    fireEvent.change(screen.getByLabelText("Body area"), { target: { value: "knee" } });
    fireEvent.change(screen.getByLabelText("Side"), { target: { value: "left" } });
    fireEvent.click(screen.getByRole("button", { name: "Save issue" }));
    await waitFor(() => expect(saveMock).toHaveBeenCalledWith("body_issue", expect.objectContaining({
      body_location_key: "knee",
      side: "left",
    }), undefined));
  });

  it("queues capture metadata with the durable original and states the privacy boundary", async () => {
    apiMock.mockImplementation(async (path) => {
      if (path === "/fitness/phases") return [{ id: "phase-1", name: "Race block", phase_type: "race_preparation", starts_on: "2026-08-01" }];
      if (String(path).startsWith("/fitness/progress-photos?")) return [];
      throw new Error(`Unexpected request: ${path}`);
    });
    queuePhotoMock.mockResolvedValue(readyRecord({
      id: "photo-new",
      captured_at: "2026-08-02T08:00:00Z",
      pose: "front",
      original_asset_id: "asset-new",
      original_state: "pending",
      thumbnail_state: "pending",
    }));

    render(<FitnessProgressPhotos online revision={0} onDataChanged={props.onDataChanged} />);
    expect(await screen.findByText(/never supplied to the coach/i)).toBeInTheDocument();
    fireEvent.click(screen.getByRole("button", { name: "Capture or upload" }));
    const fileInput = document.querySelector<HTMLInputElement>("#fitness-progress-photo-file");
    expect(fileInput).not.toBeNull();
    const file = new File([new Uint8Array([1, 2, 3])], "front.jpg", { type: "image/jpeg" });
    fireEvent.change(fileInput!, { target: { files: [file] } });
    fireEvent.change(screen.getByLabelText("Body weight (kg, optional)"), { target: { value: "78.2" } });
    fireEvent.change(screen.getByLabelText("Waist (cm, optional)"), { target: { value: "81" } });
    fireEvent.change(screen.getByLabelText("Training phase"), { target: { value: "phase-1" } });
    fireEvent.click(screen.getByRole("button", { name: "Save private photograph" }));

    await waitFor(() => expect(queuePhotoMock).toHaveBeenCalledWith(file, expect.objectContaining({
      pose: "front",
      body_weight_kg: 78.2,
      measurement_snapshot_json: { waist_cm: 81 },
      phase_id: "phase-1",
    })));
    expect(await screen.findByText(/original stays here until upload and metadata are both acknowledged/i)).toBeInTheDocument();
  });

  it("compares two protected originals, regenerates a thumbnail, and requires explicit deletion", async () => {
    const before: FitnessProgressPhoto = { id: "photo-before", captured_at: "2026-06-01T08:00:00Z", pose: "front", body_weight_kg: 81, measurement_snapshot_json: { waist_cm: 86 }, phase_id: "phase-1", phase_name: "Base", original_asset_id: "asset-before", thumbnail_asset_id: "thumb-before", original_state: "ready", thumbnail_state: "ready", metadata_acknowledged: true };
    const after: FitnessProgressPhoto = { id: "photo-after", captured_at: "2026-08-01T08:00:00Z", pose: "front", body_weight_kg: 78, measurement_snapshot_json: { waist_cm: 82 }, phase_id: "phase-2", phase_name: "Race block", original_asset_id: "asset-after", thumbnail_asset_id: "thumb-after", original_state: "ready", thumbnail_state: "missing", metadata_acknowledged: true };
    const records = [readyRecord(after), readyRecord(before)];
    onDevicePhotosMock.mockResolvedValue(records);
    apiMock.mockImplementation(async (path, init) => {
      if (path === "/fitness/phases") return [];
      if (String(path).startsWith("/fitness/progress-photos?")) return [after, before];
      if (path === "/fitness/progress-photos/photo-after/thumbnail/regenerate" && init?.method === "POST") return { status: "queued" };
      if (path === "/fitness/progress-photos/photo-after" && init?.method === "DELETE") return undefined;
      throw new Error(`Unexpected request: ${path}`);
    });

    render(<FitnessProgressPhotos online revision={0} onDataChanged={props.onDataChanged} />);
    expect((await screen.findAllByRole("button", { name: "Compare" }))).toHaveLength(2);
    fireEvent.click(screen.getAllByRole("button", { name: "Compare" })[0]);
    fireEvent.click(screen.getAllByRole("button", { name: "Compare" })[0]);
    expect(await screen.findByText("Private comparison")).toBeInTheDocument();
    fireEvent.click(screen.getByRole("button", { name: "Slider" }));
    expect(screen.getByLabelText(/Reveal after photograph/)).toBeInTheDocument();

    fireEvent.click(screen.getByRole("button", { name: "Regenerate" }));
    await waitFor(() => expect(apiMock).toHaveBeenCalledWith("/fitness/progress-photos/photo-after/thumbnail/regenerate", { method: "POST" }, true, false));

    const afterCard = screen.getByText("78.0 kg").closest("article");
    expect(afterCard).not.toBeNull();
    fireEvent.click(within(afterCard!).getByRole("button", { name: /Delete Front photograph/ }));
    fireEvent.click(within(afterCard!).getByRole("button", { name: "Delete permanently" }));
    await waitFor(() => expect(apiMock).toHaveBeenCalledWith("/fitness/progress-photos/photo-after", { method: "DELETE" }, true, false));
    expect(removePhotoMock).toHaveBeenCalledWith("photo-after");
  });

  it("removes an acknowledged staged asset before discarding its local original", async () => {
    const stagedPhoto: FitnessProgressPhoto = { id: "photo-staged", captured_at: "2026-08-02T08:00:00Z", pose: "side_left", original_asset_id: "asset-staged", original_state: "staged", thumbnail_state: "pending", metadata_acknowledged: false };
    onDevicePhotosMock.mockResolvedValue([{
      ...readyRecord(stagedPhoto),
      state: "error",
      uploadAcknowledged: true,
      metadataAcknowledged: false,
      hasLocalOriginal: true,
      error: "Metadata acknowledgement is still required.",
      retryable: true,
    }]);
    apiMock.mockImplementation(async (path, init) => {
      if (path === "/fitness/phases") return [];
      if (String(path).startsWith("/fitness/progress-photos?")) return [];
      if (path === "/fitness/files/private/asset-staged" && init?.method === "DELETE") return undefined;
      throw new Error(`Unexpected request: ${path}`);
    });

    render(<FitnessProgressPhotos online revision={0} onDataChanged={props.onDataChanged} />);
    const deleteButton = await screen.findByRole("button", { name: /Delete Left side photograph/ });
    fireEvent.click(deleteButton);
    expect(screen.getByText(/unreferenced staged private asset must be removed/i)).toBeInTheDocument();
    fireEvent.click(screen.getByRole("button", { name: "Delete permanently" }));

    await waitFor(() => expect(apiMock).toHaveBeenCalledWith("/fitness/files/private/asset-staged", { method: "DELETE" }, true, false));
    expect(apiMock).not.toHaveBeenCalledWith("/fitness/progress-photos/photo-staged", expect.anything(), expect.anything(), expect.anything());
    expect(removePhotoMock).toHaveBeenCalledWith("photo-staged");
  });

  it("does not resurrect an acknowledged cached photo omitted by the authoritative online list", async () => {
    const stale: FitnessProgressPhoto = { id: "photo-stale", captured_at: "2026-08-01T08:00:00Z", pose: "back", body_weight_kg: 99, original_asset_id: "asset-stale", original_state: "ready", thumbnail_state: "ready", metadata_acknowledged: true };
    onDevicePhotosMock.mockResolvedValue([readyRecord(stale)]);
    apiMock.mockImplementation(async (path) => {
      if (path === "/fitness/phases") return [];
      if (String(path).startsWith("/fitness/progress-photos?")) return [];
      throw new Error(`Unexpected request: ${path}`);
    });

    render(<FitnessProgressPhotos online revision={0} onDataChanged={props.onDataChanged} />);
    expect(await screen.findByText("No progress photographs in this view")).toBeInTheDocument();
    expect(screen.queryByText("99.0 kg")).not.toBeInTheDocument();
  });
});
