import { fireEvent, render, screen, waitFor, within } from "@testing-library/react";
import { beforeEach, describe, expect, it, vi } from "vitest";

import { api } from "../api";
import { FitnessActivityDetailDialog } from "../views/fitness/FitnessActivityDetailDialog";
import visualiserSource from "../views/fitness/ActivityVisualiser.tsx?raw";
import privateMapSource from "../views/fitness/PrivateActivityRouteMap.tsx?raw";

vi.mock("../api", () => ({
  api: vi.fn(),
  ApiError: class ApiError extends Error {
    status: number;
    constructor(message: string, status: number) { super(message); this.status = status; }
  },
}));

vi.mock("../fitness/offlineStore", () => ({
  flushFitnessSync: vi.fn().mockResolvedValue(null),
  saveFitnessRecords: vi.fn().mockResolvedValue([]),
}));

vi.mock("../views/fitness/ActivityRouteMap", () => ({
  ActivityRouteMap: ({
    selectedStreamIndex,
    selectedSummary,
    onSelectStreamIndex,
  }: {
    selectedStreamIndex: number;
    selectedSummary: string;
    onSelectStreamIndex: (index: number) => void;
  }) => <div role="region" aria-label="Activity route map" data-testid="route-map" data-selected-index={selectedStreamIndex}>
    <output>{selectedSummary}</output>
    <button type="button" onClick={() => onSelectStreamIndex(0)}>Choose route start</button>
  </div>,
}));

const apiMock = vi.mocked(api);

const qualityFinding = {
  key: "brief_hr_gap",
  severity: "warning",
  message: "Heart rate briefly dropped out near the second kilometre.",
  start_offset_ms: 550_000,
  end_offset_ms: 570_000,
  limits_analysis_keys: [],
};

const detail = {
  activity: {
    id: "wave6-run",
    title: "River loop",
    sport_key: "running",
    started_at_utc: "2026-08-02T06:00:00Z",
    distance_m: 2_000,
    duration_s: 1_200,
    moving_duration_s: 1_190,
    elapsed_duration_s: 1_200,
    energy_kcal: 180,
    workout_classification: "easy",
  },
  sources: [{ id: "source-1", source_type: "healthkit", device_name: "Apple Watch", is_primary: true }],
  summary_metrics: [
    { metric_key: "running.average_pace_s_per_km", value_number: 310, unit_key: "s_per_km" },
    { metric_key: "heart_rate.average_bpm", value_number: 142, unit_key: "bpm" },
  ],
  available_stream_metrics: ["pace_s_per_km", "heart_rate_bpm", "latitude_deg", "longitude_deg"],
  intervals: [{
    id: "split-1",
    sequence: 0,
    interval_kind: "kilometre_split",
    start_offset_ms: 0,
    end_offset_ms: 600_000,
    start_distance_m: 0,
    end_distance_m: 1_000,
    label: "Kilometre 1",
  }],
  records: [],
  achievements: [],
  checkins: [],
  gear: [],
  data_quality: [qualityFinding],
};

const stream = {
  activity_id: "wave6-run",
  clock: "elapsed",
  offset_ms: [0, 600_000, 1_200_000],
  distance_m: [0, 1_000, 2_000],
  series: {
    pace_s_per_km: [305, 310, 315],
    heart_rate_bpm: [132, 142, 148],
    latitude_deg: [0.0006, 0.0006, 51.4904],
    longitude_deg: [0.0004, 0.0004, -0.6057],
  },
  units: { pace_s_per_km: "s/km", heart_rate_bpm: "bpm", latitude_deg: "deg", longitude_deg: "deg" },
  downsampled: false,
};

function isBefore(left: Element, right: Element): boolean {
  return Boolean(left.compareDocumentPosition(right) & Node.DOCUMENT_POSITION_FOLLOWING);
}

describe("production activity detail hierarchy", () => {
  beforeEach(() => {
    apiMock.mockReset();
    Object.defineProperty(window.navigator, "onLine", { configurable: true, value: true });
    apiMock.mockImplementation(async (path) => {
      if (path === "/fitness/activities/wave6-run") return detail as never;
      if (path === "/fitness/activities/wave6-run/analysis") return {
        data_quality: [{ ...qualityFinding }],
        findings: [
          { key: "pacing", title: "Pacing", summary: "The opening pace may be representative.", status: "limited" },
          { key: "pacing", title: "Pacing", summary: "You kept the two kilometres notably even.", status: "valid", evidence: [{ label: "Pace range", value: "10 sec/km" }] },
        ],
      } as never;
      if (path === "/fitness/activities/wave6-run/comparisons") return [];
      if (["/fitness/gear", "/fitness/goals", "/fitness/planned-sessions", "/fitness/body-locations"].includes(String(path))) return [];
      if (String(path).startsWith("/fitness/activities/wave6-run/streams?")) return stream as never;
      throw new Error(`Unexpected request: ${path}`);
    });
  });

  it("puts route, headline, splits and charts first, deduplicates findings, and keeps route and chart selection together", async () => {
    render(<FitnessActivityDetailDialog activityId="wave6-run" open onOpenChange={vi.fn()} onChanged={vi.fn()} />);

    const route = await screen.findByTestId("route-map");
    const overview = document.querySelector("#activity-overview");
    const splits = document.querySelector("#activity-splits");
    const charts = document.querySelector("#activity-charts");
    const manage = document.querySelector("#activity-manage");
    expect(overview && splits && charts && manage).toBeTruthy();
    expect(isBefore(route.closest("#activity-route")!, overview!)).toBe(true);
    expect(isBefore(overview!, splits!)).toBe(true);
    expect(isBefore(splits!, charts!)).toBe(true);
    expect(isBefore(charts!, manage!)).toBe(true);

    expect(screen.getAllByText(qualityFinding.message)).toHaveLength(1);
    expect(screen.getAllByText("Pacing")).toHaveLength(1);
    expect(screen.getByText("You kept the two kilometres notably even.")).toBeInTheDocument();
    expect(screen.queryByText("The opening pace may be representative.")).not.toBeInTheDocument();
    expect(screen.queryByText(/canonical|stale|provider|source count|calculation method|recorded data fields/i)).not.toBeInTheDocument();

    const paceChart = screen.getByRole("img", { name: /Pace chart/ });
    expect(paceChart).toHaveAttribute("tabindex", "0");
    expect(route).toHaveAttribute("data-selected-index", "1");
    fireEvent.keyDown(paceChart, { key: "End" });
    await waitFor(() => expect(route).toHaveAttribute("data-selected-index", "2"));
    fireEvent.click(within(route).getByRole("button", { name: "Choose route start" }));
    await waitFor(() => expect(route).toHaveAttribute("data-selected-index", "0"));
    expect(within(paceChart.closest("figure")!).getByText("5:05/km")).toBeInTheDocument();

    const navigation = screen.getByRole("navigation", { name: "Activity detail sections" });
    expect(within(navigation).getAllByRole("button").map((button) => button.textContent)).toEqual([
      "Route", "Overview", "Splits", "Charts", "Analysis", "Context", "Manage",
    ]);
    const manageDetails = screen.getByText("Manage activity").closest("details");
    expect(manageDetails).not.toHaveAttribute("open");
    fireEvent.click(screen.getByText("Manage activity"));
    expect(manageDetails).toHaveAttribute("open");
    expect(screen.getByRole("button", { name: "Edit context" })).toBeInTheDocument();
  });

  it("keeps keyboard semantics and contrast or motion preferences in the activity runtime", () => {
    expect(visualiserSource).toMatch(/aria-label="Activity charts"/);
    expect(visualiserSource).toMatch(/tabIndex=\{0\}/);
    expect(visualiserSource).toMatch(/event\.key === "Home"/);
    expect(visualiserSource).toMatch(/event\.key === "End"/);
    expect(privateMapSource).toMatch(/prefers-contrast:\s*more/);
    expect(privateMapSource).toMatch(/prefers-reduced-motion:\s*reduce/);
    expect(privateMapSource).toMatch(/aria-label="Zoom in route"/);
  });
});
