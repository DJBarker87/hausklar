import { fireEvent, render, screen, waitFor, within } from "@testing-library/react";
import { beforeEach, describe, expect, it, vi } from "vitest";

import { api } from "../api";
import type { FitnessCycleProfile, FitnessCycleSettings } from "../fitness/contract";
import {
  cacheFitnessRecords,
  cachedFitnessRecords,
  saveFitnessRecord,
} from "../fitness/offlineStore";
import { FitnessCycleTracking } from "../views/fitness/FitnessCycleTracking";

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
}));

const apiMock = vi.mocked(api);
const cacheMock = vi.mocked(cacheFitnessRecords);
const cachedMock = vi.mocked(cachedFitnessRecords);
const saveMock = vi.mocked(saveFitnessRecord);
const onDataChanged = vi.fn();

const profile: FitnessCycleProfile = {
  id: "cycle-settings-dom",
  owner_user_id: "dom",
  owner_name: "Alex",
  is_owner: true,
  cycle_length_days: 28,
  show_period_starts: true,
  show_predicted_period: true,
  show_estimated_ovulation: true,
  share_period_starts_with_adults: false,
  share_predicted_period_with_adults: false,
  share_estimated_ovulation_with_adults: false,
  latest_period_start: "2026-07-10",
  predicted_next_period: "2026-08-07",
  estimated_ovulation: "2026-07-24",
  period_starts: [{
    id: "period-1",
    started_on: "2026-07-10",
    revision: 2,
    created_at: "2026-07-10T08:00:00Z",
    updated_at: "2026-07-10T08:00:00Z",
  }],
  revision: 3,
  created_at: "2026-06-01T08:00:00Z",
  updated_at: "2026-07-10T08:00:00Z",
};

describe("Fitness cycle tracking", () => {
  beforeEach(() => {
    apiMock.mockReset();
    cacheMock.mockClear();
    cachedMock.mockReset();
    cachedMock.mockResolvedValue([]);
    saveMock.mockReset();
    onDataChanged.mockReset();
    window.history.replaceState({}, "", "/?view=fitness&section=recovery");
    Object.defineProperty(window.navigator, "onLine", { configurable: true, value: true });
  });

  it("loads the canonical Fitness route and keeps privacy choices behind a summary-first view", async () => {
    apiMock.mockResolvedValue([profile]);

    render(<FitnessCycleTracking online revision={0} onDataChanged={onDataChanged} />);

    expect(await screen.findByText("Your cycle at a glance")).toBeInTheDocument();
    expect(screen.getByText(/(?:Aug 7|7 Aug), 2026|7 Aug 2026/)).toBeInTheDocument();
    expect(screen.getByText(/not sent to Coach/i)).toBeInTheDocument();
    expect(apiMock).toHaveBeenCalledWith(
      "/fitness/cycles",
      { signal: expect.any(AbortSignal) },
      true,
      false,
    );
    await waitFor(() => {
      expect(cacheMock).toHaveBeenCalledWith("cycle_settings", [expect.objectContaining({ id: profile.id })]);
      expect(cacheMock).toHaveBeenCalledWith("cycle_period_start", [expect.objectContaining({ id: "period-1", owner_user_id: "dom" })]);
    });

    const settingsSummary = screen.getByText("Calendar and privacy settings").closest("summary");
    expect(settingsSummary?.parentElement).not.toHaveAttribute("open");
    fireEvent.click(settingsSummary!);
    expect(screen.getByRole("group", { name: "Show on my calendar" })).toBeInTheDocument();
    const sharing = screen.getByRole("group", { name: "Share with other adults" });
    expect(within(sharing).getAllByRole("checkbox")).toHaveLength(3);
    within(sharing).getAllByRole("checkbox").forEach((checkbox) => expect(checkbox).not.toBeChecked());
    expect(within(sharing).getByText(/Turning on a Calendar date above does not share it/i)).toBeInTheDocument();
  });

  it("validates cycle length without losing the draft and saves granular consent to the Fitness outbox", async () => {
    apiMock.mockResolvedValue([]);
    saveMock.mockImplementation(async (_entityType, payload, options) => ({
      ...payload,
      id: options?.entityId ?? "cycle-settings-new",
      queued_offline: true,
    }));

    render(<FitnessCycleTracking online revision={0} onDataChanged={onDataChanged} forceVisible />);
    fireEvent.click(await screen.findByRole("button", { name: "Set up cycle tracking" }));

    const length = screen.getByRole("textbox", { name: /Cycle length/ });
    expect(length).toHaveAttribute("inputmode", "numeric");
    fireEvent.change(length, { target: { value: "9" } });
    fireEvent.blur(length);
    expect(await screen.findByRole("alert")).toHaveTextContent("between 10 and 365");
    expect(length).toHaveValue("9");
    fireEvent.click(screen.getByRole("button", { name: "Finish setup" }));
    expect(saveMock).not.toHaveBeenCalled();

    fireEvent.change(length, { target: { value: "30" } });
    const sharing = screen.getByRole("group", { name: "Share with other adults" });
    fireEvent.click(within(sharing).getByRole("checkbox", { name: /Share predicted next period/ }));
    fireEvent.click(screen.getByRole("button", { name: "Finish setup" }));

    await waitFor(() => expect(saveMock).toHaveBeenCalledWith("cycle_settings", {
      cycle_length_days: 30,
      show_period_starts: true,
      show_predicted_period: true,
      show_estimated_ovulation: true,
      share_period_starts_with_adults: false,
      share_predicted_period_with_adults: true,
      share_estimated_ovulation_with_adults: false,
    }, {
      entityId: expect.any(String),
      baseRevision: null,
    }));
    expect(await screen.findByText("Your cycle at a glance")).toBeInTheDocument();
  });

  it("records and removes starts only through the singular Fitness entity type", async () => {
    apiMock.mockResolvedValue([profile]);
    saveMock.mockImplementation(async (entityType, payload, options) => ({
      ...payload,
      id: options?.entityId ?? (entityType === "cycle_period_start" ? "period-2" : "saved"),
      queued_offline: true,
    }));

    render(<FitnessCycleTracking online revision={0} onDataChanged={onDataChanged} />);
    await screen.findByText("Your cycle at a glance");
    fireEvent.change(screen.getByLabelText("Record a period start"), { target: { value: "2026-08-05" } });
    fireEvent.click(screen.getByRole("button", { name: "Period started" }));
    await waitFor(() => expect(saveMock).toHaveBeenCalledWith("cycle_period_start", {
      started_on: "2026-08-05",
    }, undefined));

    fireEvent.click(screen.getByText("Recorded starts").closest("summary")!);
    fireEvent.click(await screen.findByRole("button", { name: "Remove period start 2026-08-05" }));
    fireEvent.click(screen.getByRole("button", { name: "Remove" }));
    await waitFor(() => expect(saveMock).toHaveBeenCalledWith("cycle_period_start", {}, {
      entityId: "period-2",
      baseRevision: null,
      operation: "delete",
    }));
  });

  it("reconstructs the private summary from Fitness IndexedDB while offline", async () => {
    Object.defineProperty(window.navigator, "onLine", { configurable: true, value: false });
    cachedMock.mockImplementation(async (entityType) => {
      if (entityType === "cycle_settings") return [profileSettingsForCache()];
      if (entityType === "cycle_period_start") return [{ id: "period-offline", owner_user_id: "dom", started_on: "2026-07-10", revision: 1 }];
      return [];
    });

    render(<FitnessCycleTracking online={false} revision={0} onDataChanged={onDataChanged} />);

    expect(await screen.findByText(/(?:Aug 7|7 Aug), 2026|7 Aug 2026/)).toBeInTheDocument();
    expect(screen.queryByText(/showing cycle data saved/i)).not.toBeInTheDocument();
    expect(apiMock).not.toHaveBeenCalled();
  });
});

function profileSettingsForCache(): FitnessCycleSettings {
  const { period_starts: _periods, latest_period_start: _latest, predicted_next_period: _next, estimated_ovulation: _ovulation, ...settings } = profile;
  return settings;
}
