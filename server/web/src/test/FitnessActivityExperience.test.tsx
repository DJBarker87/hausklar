import { fireEvent, render, screen, waitFor, within } from "@testing-library/react";
import { beforeEach, describe, expect, it, vi } from "vitest";

import { api } from "../api";
import { saveFitnessRecord, saveFitnessRecords } from "../fitness/offlineStore";
import { ActivityVisualiser } from "../views/fitness/ActivityVisualiser";
import {
  FitnessActivityDetailDialog,
  activityPrimaryStats,
  hasActivityChartMetrics,
} from "../views/fitness/FitnessActivityDetailDialog";
import { FitnessActivityView } from "../views/fitness/FitnessActivityView";
import { FitnessExploreView } from "../views/fitness/FitnessExploreView";

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
  fitnessPendingImports: vi.fn().mockResolvedValue([]),
  flushFitnessFitImports: vi.fn().mockResolvedValue([]),
  queueFitnessFitImport: vi.fn().mockResolvedValue({}),
  retryFitnessFitImport: vi.fn().mockResolvedValue(undefined),
  removeFitnessFitImport: vi.fn().mockResolvedValue(undefined),
  saveFitnessRecord: vi.fn().mockResolvedValue({ id: "manual-activity-1", queued_offline: true }),
  saveFitnessRecords: vi.fn().mockResolvedValue([]),
  flushFitnessSync: vi.fn().mockResolvedValue(null),
}));

vi.mock("../views/fitness/ActivityRouteMap", () => ({
  ActivityRouteMap: ({ onSelectStreamIndex }: { onSelectStreamIndex: (index: number) => void }) => <div role="img" aria-label="Activity route synchronized with the chart crosshair"><button type="button" onClick={() => onSelectStreamIndex(1)}>Select route point</button></div>,
}));

const apiMock = vi.mocked(api);
const saveMock = vi.mocked(saveFitnessRecord);
const saveManyMock = vi.mocked(saveFitnessRecords);
const props = {
  online: true,
  revision: 0,
  onDataChanged: vi.fn(),
  onSectionChange: vi.fn(),
};
const emptyRunningLoadForTest = {
  windows: {
    "7d": { days: 7, distance_m: 0, duration_s: 0, session_count: 0, hard_session_count: 0, session_rpe_load: null },
    "28d": { days: 28, distance_m: 0, duration_s: 0, session_count: 0, hard_session_count: 0, session_rpe_load: null },
    "42d": { days: 42, distance_m: 0, duration_s: 0, session_count: 0, hard_session_count: 0, session_rpe_load: null },
  },
  volume_change_pct: null,
  missing_rpe_sessions: 0,
  explanation: "No inferred load.",
};

describe("Fitness activity and registered analysis surfaces", () => {
  beforeEach(() => {
    apiMock.mockReset();
    saveMock.mockReset();
    saveMock.mockResolvedValue({ id: "manual-activity-1", queued_offline: true } as never);
    saveManyMock.mockReset();
    saveManyMock.mockResolvedValue([]);
    window.history.replaceState({}, "", "/?view=fitness&section=activity");
    Object.defineProperty(window.navigator, "onLine", { configurable: true, value: true });
  });

  it("prefers registered running pace, then speed, then distance over moving time", () => {
    const detail = {
      activity: {
        id: "pace-order",
        title: "Riverside 5K",
        sport_key: "running",
        started_at_utc: "2026-08-02T06:00:00Z",
        distance_m: 5_000,
        moving_duration_s: 1_650,
      },
      summary_metrics: [
        { metric_key: "running.average_pace_s_per_km", value_number: 315, unit_key: "s_per_km" },
        { metric_key: "speed.average_mps", value_number: 4, unit_key: "m/s" },
      ],
      sources: [],
      available_stream_metrics: [],
      intervals: [],
      records: [],
      achievements: [],
      checkins: [],
      gear: [],
      data_quality: [],
    };

    const pace = (value: typeof detail) => activityPrimaryStats(value as never).find((stat) => stat.label === "Average pace")?.value;
    expect(pace(detail)).toBe("5:15/km");
    expect(pace({ ...detail, summary_metrics: detail.summary_metrics.slice(1) })).toBe("4:10/km");
    expect(pace({ ...detail, summary_metrics: [] })).toBe("5:30/km");
  });

  it("does not advertise a charts destination for coordinate-only streams", () => {
    const detail = {
      activity: { id: "route-only", title: "Ride", sport_key: "cycling", started_at_utc: "2026-08-02T06:00:00Z" },
      summary_metrics: [],
      sources: [],
      available_stream_metrics: ["latitude_deg", "longitude_deg", "distance_m"],
      intervals: [],
    };

    expect(hasActivityChartMetrics(detail as never)).toBe(false);
    expect(hasActivityChartMetrics({ ...detail, available_stream_metrics: [...detail.available_stream_metrics, "speed_mps"] } as never)).toBe(true);
  });

  it("offers the selected activity to Coach from its detail", async () => {
    apiMock.mockImplementation(async (path) => {
      if (path === "/fitness/activities/ride-1") return {
        activity: { id: "ride-1", title: "Evening ride", sport_key: "cycling", started_at_utc: "2026-08-02T18:00:00Z" },
        sources: [], summary_metrics: [], available_stream_metrics: [], intervals: [],
        records: [], achievements: [], checkins: [], gear: [], data_quality: [],
      } as never;
      if (path === "/fitness/activities/ride-1/analysis") return {} as never;
      if (path === "/fitness/activities/ride-1/comparisons") return [] as never;
      if (["/fitness/gear", "/fitness/goals", "/fitness/planned-sessions", "/fitness/body-locations"].includes(String(path))) return [] as never;
      throw new Error(`Unexpected request: ${path}`);
    });
    const askCoach = vi.fn();

    render(<FitnessActivityDetailDialog activityId="ride-1" open onOpenChange={vi.fn()} onChanged={vi.fn()} onAskCoach={askCoach} />);
    fireEvent.click(await screen.findByRole("button", { name: "Ask Coach about this activity" }));

    expect(askCoach).toHaveBeenCalledWith("ride-1", "Evening ride");
  });

  it("automatically compares a run with its previous similar-distance run", async () => {
    apiMock.mockImplementation(async (path) => {
      if (path === "/fitness/activities/run-current") return {
        activity: {
          id: "run-current", title: "Thursday 10K", sport_key: "running",
          started_at_utc: "2026-08-20T06:00:00Z", distance_m: 10_000,
          moving_duration_s: 3_120,
        },
        sources: [], summary_metrics: [], available_stream_metrics: [], intervals: [],
        records: [], achievements: [], checkins: [], gear: [], data_quality: [],
      } as never;
      if (path === "/fitness/activities/run-current/analysis") return {} as never;
      if (path === "/fitness/activities/run-current/comparisons") return [{
        activity: {
          id: "run-previous", title: "Riverside 10K", sport_key: "running",
          started_at_utc: "2026-08-13T06:00:00Z", distance_m: 10_020,
          moving_duration_s: 3_200,
        },
        score: 0.98,
        reasons: ["similar distance"],
        is_previous_similar_distance: true,
        automatic_comparison: {
          algorithm_version: "previous-similar-distance-v1",
          distance_label: "10K",
          current_distance_m: 10_000,
          previous_distance_m: 10_020,
          distance_delta_m: -20,
          current_duration_s: 3_120,
          previous_duration_s: 3_200,
          duration_delta_s: -80,
          duration_improvement_s: 80,
          current_pace_s_per_km: 312,
          previous_pace_s_per_km: 319.36,
          pace_delta_s_per_km: -7.36,
          pace_improvement_s_per_km: 7.36,
        },
      }] as never;
      if (["/fitness/gear", "/fitness/goals", "/fitness/planned-sessions", "/fitness/body-locations"].includes(String(path))) return [] as never;
      throw new Error(`Unexpected request: ${path}`);
    });

    render(<FitnessActivityDetailDialog activityId="run-current" open onOpenChange={vi.fn()} onChanged={vi.fn()} />);

    expect(await screen.findByText("10K progress")).toBeInTheDocument();
    expect(screen.getByText("0:07/km faster")).toBeInTheDocument();
    expect(screen.getByText(/Compared automatically with Riverside 10K/)).toBeInTheDocument();
    expect(screen.getByText(/pace is the fairer comparison/)).toBeInTheDocument();
  });

  it("filters the private history by phase, classification, and gear", async () => {
    apiMock.mockImplementation(async (path) => {
      if (path === "/fitness/activity-registry") return { sports: [{ key: "running", display_name: "Running" }, { key: "rowing_indoor", display_name: "Indoor rowing" }], metrics: [] };
      if (path === "/fitness/phases") return [{ id: "phase-1", name: "Race block", phase_type: "race_preparation", starts_on: "2026-08-01", active: true }];
      if (path === "/fitness/gear") return [{ id: "shoe-1", name: "Daily trainers", gear_type_key: "running_shoe", active: true }];
      if (String(path).startsWith("/fitness/activities?")) return [{
        id: "run-1", title: "Morning run", sport_key: "running", started_at_utc: "2026-08-02T06:00:00Z",
        distance_m: 5000, duration_s: 1500, status: "complete", route_preview: [[51.5, -0.1], [51.51, -0.09]],
        primary_metrics: [
          { metric_key: "running.average_pace_s_per_km", value_number: 300, unit_key: "s/km" },
          { metric_key: "heart_rate.average_bpm", value_number: 148, unit_key: "bpm" },
        ],
      }];
      throw new Error(`Unexpected request: ${path}`);
    });

    render(<FitnessActivityView {...props} />);
    const runCard = await screen.findByRole("button", { name: /Open Morning run run details/ });
    const routePreview = within(runCard).getByRole("img", { name: "Recorded route shape" });
    expect(routePreview).toBeInTheDocument();
    expect(within(runCard).getByText("5.00 km")).toBeInTheDocument();
    expect(within(runCard).getByText("25:00")).toBeInTheDocument();
    expect(within(runCard).getByText("5:00/km")).toBeInTheDocument();
    expect(within(runCard).getByText("148 bpm")).toBeInTheDocument();
    expect(runCard).toHaveAccessibleName("Open Morning run run details. Route recorded. Distance 5.00 km, Time 25:00, Pace 5:00/km, Avg HR 148 bpm");
    expect(within(runCard).getByText("Morning run").compareDocumentPosition(routePreview) & Node.DOCUMENT_POSITION_FOLLOWING).toBeTruthy();
    expect(routePreview.parentElement).toHaveClass("fitness-module__run-card-route");
    const routePath = routePreview.querySelector("path")?.getAttribute("d") ?? "";
    const routeCoordinates = routePath.match(/-?\d+(?:\.\d+)?/g)?.map(Number) ?? [];
    expect(Math.abs(routeCoordinates[2] - routeCoordinates[0])).toBeLessThan(60);
    expect(apiMock.mock.calls.some(([path]) => String(path).includes("/streams?"))).toBe(false);
    expect(screen.getByRole("option", { name: "Indoor rowing" })).toHaveValue("rowing_indoor");
    fireEvent.change(screen.getByLabelText("Sport"), { target: { value: "rowing_indoor" } });
    fireEvent.change(screen.getByLabelText("Phase"), { target: { value: "phase-1" } });
    fireEvent.change(screen.getByLabelText("Classification"), { target: { value: "progression" } });
    fireEvent.change(screen.getByLabelText("Gear"), { target: { value: "shoe-1" } });

    await waitFor(() => expect(apiMock).toHaveBeenCalledWith(expect.stringMatching(/sport_key=rowing_indoor.*phase_id=phase-1.*workout_classification=progression.*gear_id=shoe-1/), {}, true, false));
  });

  it("shows strength sessions in activity history with totals and one-tap export", async () => {
    const activity = {
      id: "strength-1", title: "Lower A", sport_key: "strength",
      started_at_utc: "2026-08-20T10:00:00Z", duration_s: 3_600, status: "completed",
      strength_summary: { exercise_count: 3, set_count: 12, working_set_count: 9, failure_set_count: 1, volume_kg: 4_250 },
    };
    const session = {
      ...activity,
      local_timezone: "Europe/London",
      ended_at_utc: "2026-08-20T11:00:00Z",
      exercises: [],
    };
    const writeText = vi.fn().mockResolvedValue(undefined);
    Object.defineProperty(window.navigator, "clipboard", { configurable: true, value: { writeText } });
    apiMock.mockImplementation(async (path) => {
      if (path === "/fitness/activity-registry") return { sports: [{ key: "strength", display_name: "Strength" }], metrics: [] };
      if (path === "/fitness/phases" || path === "/fitness/gear") return [];
      if (path === "/fitness/strength/sessions") return [session] as never;
      if (path === "/fitness/running/load") return emptyRunningLoadForTest;
      if (String(path).startsWith("/fitness/activities?")) return [activity] as never;
      throw new Error(`Unexpected request: ${path}`);
    });

    render(<FitnessActivityView {...props} />);

    expect(await screen.findByText("Lower A")).toBeInTheDocument();
    expect(screen.getByText("3 exercises · 12 sets · 1h 0m · 4,250 kg volume")).toBeInTheDocument();
    expect(within(screen.getByText("Lower A").closest("article")!).getByText("9")).toBeInTheDocument();
    expect(screen.getByText("Strength sessions").nextElementSibling).toHaveTextContent("1");
    fireEvent.click(screen.getByRole("button", { name: "Copy Lower A workout for an LLM" }));
    await waitFor(() => expect(writeText).toHaveBeenCalledWith(expect.stringContaining("Strength workout: Lower A")));
  });

  it("logs an unplanned completed run and labels its weight-based calories as estimated", async () => {
    apiMock.mockImplementation(async (path) => {
      if (path === "/fitness/activity-registry") return { sports: [{ key: "running", display_name: "Running", distance_meaningful: true }], metrics: [] };
      if (path === "/fitness/phases" || path === "/fitness/gear") return [];
      if (path === "/fitness/activities/manual-defaults") return { latest_weight_kg: 80, latest_weight_measured_at_utc: "2026-08-03T06:30:00Z", energy_estimation_method: "adult_compendium_2024_met" };
      if (path === "/fitness/running/load") return emptyRunningLoadForTest;
      if (String(path).startsWith("/fitness/activities?")) return [];
      throw new Error(`Unexpected request: ${path}`);
    });

    render(<FitnessActivityView {...props} />);
    fireEvent.click(await screen.findByRole("button", { name: "Log activity" }));
    expect(await screen.findByRole("dialog", { name: "Log completed activity" })).toBeInTheDocument();
    expect(screen.getByText("≈ 440 kcal")).toBeInTheDocument();
    fireEvent.click(screen.getByRole("button", { name: "Save activity" }));

    await waitFor(() => expect(saveMock).toHaveBeenCalledWith("manual_activity", expect.objectContaining({
      sport_key: "running",
      duration_s: 1_800,
      distance_m: 5_000,
      estimate_energy: true,
    })));
    expect(await screen.findByText("Running saved")).toBeInTheDocument();
  });

  it("runs only a registered analysis query and renders its completeness", async () => {
    apiMock.mockImplementation(async (path, init) => {
      if (path === "/fitness/analysis/registry") return {
        dimensions: [{ key: "week", label: "Week", value_type: "date" }],
        measures: [{ key: "running.distance_m", label: "Running distance", unit_key: "m", supported_dimensions: ["week"], chart_types: ["bar", "table"], allowed_filter_keys: [], classification: "descriptive" }],
        chart_types: [{ key: "bar", label: "Bars" }, { key: "table", label: "Table" }],
        filters: [],
        comparisons: [],
        limits: { max_window_days: 366, max_output_points: 200, max_filters: 4 },
        default_queries: [{ key: "weekly-running", label: "Weekly running", dimension_key: "week", measure_key: "running.distance_m", chart_type_key: "bar", date_window_days: 84, surface: "explore", category: "running" }],
      };
      if (path === "/fitness/analysis/charts") return [];
      if (path === "/fitness/analysis/query" && init?.method === "POST") return {
        status: "complete",
        title: "Synthetic public demo record 2",
        dimension_key: "week",
        measure_key: "running.distance_m",
        chart_type_key: "bar",
        unit_key: "m",
        series: [{ key: "distance", label: "Distance", unit_key: "m", points: [{ key: "2026-W31", label: "Week 31", value: 18000, sample_size: 3, missing_rate: 0.25 }] }],
        metadata: { period: { start: "2026-06-01", end: "2026-08-02" }, sample_size: 3, missing_rate: 0.25, source_quality: ["recorded"], measurement_quality: ["measured"], canonical_policy: "owner canonical activities", duplicate_policy: "duplicates excluded", classification: "descriptive" },
        limitations: ["One run has no route."],
      };
      throw new Error(`Unexpected request: ${path}`);
    });

    render(<FitnessExploreView {...props} />);
    fireEvent.click(screen.getByText("Advanced"));
    fireEvent.click(screen.getByRole("button", { name: "Open advanced builder" }));
    expect(await screen.findByRole("option", { name: "Running distance" })).toBeInTheDocument();
    await waitFor(() => expect(screen.getByLabelText("Chart")).toHaveValue("bar"));
    expect(apiMock).not.toHaveBeenCalledWith("/fitness/progress", expect.anything(), expect.anything(), expect.anything());
    fireEvent.click(screen.getByRole("button", { name: "Run analysis" }));

    expect(await screen.findByText("Synthetic public demo record 2")).toBeInTheDocument();
    expect(screen.getByText("3 observations · 25% missing")).toBeInTheDocument();
    const queryCall = apiMock.mock.calls.find(([path]) => path === "/fitness/analysis/query");
    expect(JSON.parse(String(queryCall?.[1]?.body))).toMatchObject({
      dimension_key: "week",
      measure_key: "running.distance_m",
      chart_type_key: "bar",
      filters: [],
    });
  });

  it("requests the backend coordinate keys and renders their route stream", async () => {
    apiMock.mockImplementation(async (path) => {
      if (String(path).startsWith("/fitness/activities/run-1/streams?")) return {
        activity_id: "run-1",
        clock: "elapsed",
        offset_ms: [0, 60_000],
        series: {
          pace_s_per_km: [330, 325],
          latitude_deg: [0.0007, 0.0007],
          longitude_deg: [0.0001, 0.0001],
        },
        units: { pace_s_per_km: "s/km", latitude_deg: "deg", longitude_deg: "deg" },
        downsampled: false,
      } as never;
      throw new Error(`Unexpected request: ${path}`);
    });

    render(<ActivityVisualiser detail={{
      activity: { id: "run-1", title: "Morning run", sport_key: "running", started_at_utc: "2026-08-02T06:00:00Z", elapsed_duration_s: 60 },
      sources: [], summary_metrics: [], available_stream_metrics: ["pace_s_per_km", "latitude_deg", "longitude_deg"], intervals: [],
    }} />);

    expect(await screen.findByRole("img", { name: /Activity route synchronized with the chart crosshair/ })).toBeInTheDocument();
    const streamRequest = apiMock.mock.calls.find(([path]) => String(path).startsWith("/fitness/activities/run-1/streams?"));
    expect(decodeURIComponent(String(streamRequest?.[0]))).toContain("metrics=pace_s_per_km,latitude_deg,longitude_deg");
    expect(apiMock.mock.calls.some(([path]) => {
      const decoded = decodeURIComponent(String(path));
      return decoded.includes("metrics=latitude_deg,longitude_deg") && decoded.includes("max_points=20000");
    })).toBe(true);
  });

  it("keeps the stored Strava route visible when no GPS stream is available", async () => {
    render(<ActivityVisualiser detail={{
      activity: {
        id: "strava-route-preview",
        title: "Imported 5K",
        sport_key: "running",
        started_at_utc: "2026-08-03T06:00:00Z",
        route_preview: [[51.5000, -0.1000], [51.5010, -0.0980], [51.5020, -0.0970]],
      },
      sources: [], summary_metrics: [], available_stream_metrics: [], intervals: [],
    }} />);

    expect(await screen.findByRole("img", { name: /Activity route synchronized with the chart crosshair/ })).toBeInTheDocument();
    expect(apiMock).not.toHaveBeenCalledWith(expect.stringContaining("/streams?"), expect.anything(), expect.anything(), expect.anything());
  });

  it("shows a coordinate-only run as a route without an empty charts shell", async () => {
    apiMock.mockImplementation(async (path) => {
      if (String(path).startsWith("/fitness/activities/route-only-run/streams?")) return {
        activity_id: "route-only-run", clock: "elapsed", offset_ms: [0, 60_000],
        series: { latitude_deg: [51.50, 51.51], longitude_deg: [-0.10, -0.09] },
        units: { latitude_deg: "deg", longitude_deg: "deg" }, downsampled: false,
      } as never;
      throw new Error(`Unexpected request: ${path}`);
    });

    render(<ActivityVisualiser detail={{
      activity: { id: "route-only-run", title: "Route only run", sport_key: "running", started_at_utc: "2026-08-03T06:00:00Z" },
      sources: [], summary_metrics: [], available_stream_metrics: ["latitude_deg", "longitude_deg"], intervals: [],
    }} />);

    expect(await screen.findByRole("img", { name: /Activity route synchronized with the chart crosshair/ })).toBeInTheDocument();
    expect(screen.getByText("No graphs recorded")).toBeInTheDocument();
    expect(screen.queryByText("Follow the effort")).not.toBeInTheDocument();
    expect(apiMock.mock.calls.filter(([path]) => String(path).includes("/streams?")).length).toBe(1);
  });

  it("uses speed as the first run graph when pace was not recorded", async () => {
    const metrics = ["speed_mps", "heart_rate_bpm", "altitude_m", "cadence_spm", "power_w"];
    apiMock.mockImplementation(async (path) => {
      if (String(path).startsWith("/fitness/activities/speed-run/streams?")) return {
        activity_id: "speed-run", clock: "elapsed", offset_ms: [0, 60_000], distance_m: [0, 900],
        series: Object.fromEntries(metrics.map((metric, index) => [metric, [index + 1, index + 2]])),
        units: { speed_mps: "m/s", heart_rate_bpm: "bpm", altitude_m: "m", cadence_spm: "spm", power_w: "W" },
        downsampled: false,
      } as never;
      throw new Error(`Unexpected request: ${path}`);
    });

    render(<ActivityVisualiser detail={{
      activity: { id: "speed-run", title: "Speed stream run", sport_key: "running", started_at_utc: "2026-08-03T06:00:00Z" },
      sources: [], summary_metrics: [], available_stream_metrics: metrics, intervals: [],
    }} />);

    const speedChart = await screen.findByRole("img", { name: /Speed chart/ });
    const heartRateChart = screen.getByRole("img", { name: /Heart rate chart/ });
    expect(speedChart.compareDocumentPosition(heartRateChart) & Node.DOCUMENT_POSITION_FOLLOWING).toBeTruthy();
  });

  it("keeps every activity stream available and can reveal the full synchronized chart deck", async () => {
    const metrics = [
      "pace_s_per_km", "heart_rate_bpm", "altitude_m", "cadence_spm", "power_w",
      "stride_length_m", "vertical_oscillation_mm", "vertical_ratio_pct",
      "ground_contact_time_ms", "ground_contact_balance_pct", "respiration_rate_bpm",
      "temperature_c", "stamina_pct",
    ];
    apiMock.mockImplementation(async (path) => {
      if (String(path).startsWith("/fitness/activities/run-all/streams?")) return {
        activity_id: "run-all",
        clock: "elapsed",
        offset_ms: [0, 60_000, 120_000],
        distance_m: [0, 1_000, 2_000],
        series: Object.fromEntries(metrics.map((metric, index) => [metric, [index + 1, index + 2, index + 3]])),
        units: Object.fromEntries(metrics.map((metric) => [metric, metric === "temperature_c" ? "degC" : "recorded"])),
        downsampled: true,
        source_point_count: 2_400,
      } as never;
      throw new Error(`Unexpected request: ${path}`);
    });

    render(<ActivityVisualiser detail={{
      activity: { id: "run-all", title: "Garmin detail run", sport_key: "running", started_at_utc: "2026-08-02T06:00:00Z", elapsed_duration_s: 120, distance_m: 2_000 },
      sources: [], summary_metrics: [], available_stream_metrics: [...metrics, "distance_m"], intervals: [],
    }} />);

    expect(await screen.findByText("Follow the effort")).toBeInTheDocument();
    const streamRequest = apiMock.mock.calls.find(([path]) => String(path).startsWith("/fitness/activities/run-all/streams?"));
    expect(decodeURIComponent(String(streamRequest?.[0]))).toContain("temperature_c,stamina_pct");
    expect(screen.getByRole("button", { name: "Distance" })).toBeEnabled();
    fireEvent.click(screen.getByRole("button", { name: "All data" }));
    expect(screen.getByRole("img", { name: /Temperature chart/ })).toBeInTheDocument();
    expect(screen.getByRole("img", { name: /Stamina Pct chart/ })).toBeInTheDocument();
    expect(screen.queryByText(/^Average /)).not.toBeInTheDocument();
  });

  it("shows run content immediately and keeps missing recordings in their natural order", async () => {
    apiMock.mockImplementation(async (path) => {
      if (path === "/fitness/activities/sparse-run") return {
        activity: {
          id: "sparse-run", title: "Treadmill run", sport_key: "running",
          started_at_utc: "2026-08-04T06:00:00Z", distance_m: 5_000, duration_s: 1_650,
        },
        sources: [], summary_metrics: [], available_stream_metrics: [], intervals: [],
        records: [], achievements: [], checkins: [], gear: [], data_quality: [],
      } as never;
      if (path === "/fitness/activities/sparse-run/analysis") return new Promise<never>(() => undefined);
      if (path === "/fitness/activities/sparse-run/comparisons") return [];
      if (["/fitness/gear", "/fitness/goals", "/fitness/planned-sessions", "/fitness/body-locations"].includes(String(path))) return [];
      throw new Error(`Unexpected request: ${path}`);
    });

    render(<FitnessActivityDetailDialog activityId="sparse-run" open onOpenChange={vi.fn()} onChanged={vi.fn()} />);

    const noRoute = await screen.findByText("No route recorded");
    const summary = screen.getByText("Run summary");
    const noLaps = screen.getByText("No laps recorded");
    const noGraphs = screen.getByText("No graphs recorded");
    const orderedSections = [noRoute, summary, noLaps, noGraphs].map((item) => item.closest("section"));
    orderedSections.forEach((section) => expect(section).not.toBeNull());
    expect(orderedSections[0]!.compareDocumentPosition(orderedSections[1]!) & Node.DOCUMENT_POSITION_FOLLOWING).toBeTruthy();
    expect(orderedSections[1]!.compareDocumentPosition(orderedSections[2]!) & Node.DOCUMENT_POSITION_FOLLOWING).toBeTruthy();
    expect(orderedSections[2]!.compareDocumentPosition(orderedSections[3]!) & Node.DOCUMENT_POSITION_FOLLOWING).toBeTruthy();
  });

  it("opens a run in route, summary, recorded laps, then charts order", async () => {
    apiMock.mockImplementation(async (path) => {
      if (path === "/fitness/activities/run-layout") return {
        activity: {
          id: "run-layout", title: "Long Sunday run", sport_key: "running",
          started_at_utc: "2026-08-02T06:00:00Z", distance_m: 5_000,
          duration_s: 1_500, elapsed_duration_s: 1_530, moving_duration_s: 1_480,
          energy_kcal: 920, energy_estimation_method: "adult_compendium_2024_met", workout_classification: "long",
          route_preview: [[51.50, -0.10], [51.51, -0.09], [51.52, -0.08]],
        },
        sources: [{ id: "source-1", source_type: "healthkit", device_name: "Apple Watch", status: "active", is_primary: true }],
        summary_metrics: [
          { metric_key: "speed.average_mps", value_number: 3.333, unit_key: "m/s" },
          { metric_key: "heart_rate.average_bpm", value_number: 146, unit_key: "bpm" },
          { metric_key: "elevation.gain_m", value_number: 82, unit_key: "m" },
        ],
        available_stream_metrics: ["pace_s_per_km", "heart_rate_bpm", "altitude_m", "latitude_deg", "longitude_deg"],
        intervals: [
          { id: "km-1", sequence: 0, interval_kind: "kilometre_split", start_offset_ms: 0, end_offset_ms: 300_000, start_distance_m: 0, end_distance_m: 1_000, label: "Kilometre 1", origin: "derived" },
          {
            id: "lap-1", sequence: 0, interval_kind: "source_lap", start_offset_ms: 0, end_offset_ms: 620_000,
            start_distance_m: 0, end_distance_m: 2_000, label: "Garmin lap 1", origin: "source",
            metrics: {
              elapsed_duration_s: 620, timer_duration_s: 600, pace_s_per_km: 300,
              "heart_rate.average_bpm": 146, "heart_rate.maximum_bpm": 162,
              "elevation.change_m": -3, "elevation.gain_m": 12, "power.average_w": 278,
            },
          },
        ],
        records: [], achievements: [], checkins: [], gear: [], data_quality: [{
          key: "heart_rate_dropout",
          severity: "warning",
          message: "Heart-rate coverage is below 80%; heart-rate conclusions are limited.",
          limits_analysis_keys: ["heart_rate_decoupling"],
        }],
      } as never;
      if (path === "/fitness/activities/run-layout/analysis") return { data_quality: [{
        key: "heart_rate_dropout",
        severity: "warning",
        message: "Heart-rate coverage is below 80%; heart-rate conclusions are limited.",
        limits_analysis_keys: ["heart_rate_decoupling"],
      }] };
      if (path === "/fitness/activities/run-layout/comparisons") return [];
      if (["/fitness/gear", "/fitness/goals", "/fitness/planned-sessions", "/fitness/body-locations"].includes(String(path))) return [];
      if (String(path).startsWith("/fitness/activities/run-layout/streams?")) return {
        activity_id: "run-layout", clock: "elapsed", offset_ms: [0, 300_000, 620_000], distance_m: [0, 1_000, 2_000],
        series: {
          pace_s_per_km: [310, 300, 295], heart_rate_bpm: [132, 146, 158], altitude_m: [20, 34, 27],
          latitude_deg: [51.50, 51.51, 51.52], longitude_deg: [-0.10, -0.09, -0.08],
        },
        units: { pace_s_per_km: "s/km", heart_rate_bpm: "bpm", altitude_m: "m", latitude_deg: "deg", longitude_deg: "deg" },
        downsampled: false,
      } as never;
      throw new Error(`Unexpected request: ${path}`);
    });

    render(<FitnessActivityDetailDialog activityId="run-layout" open onOpenChange={vi.fn()} onChanged={vi.fn()} />);

    expect(await screen.findByText("Average pace")).toBeInTheDocument();
    expect(await screen.findByText("Follow the effort")).toBeInTheDocument();
    expect(screen.getAllByText("5:00/km").length).toBeGreaterThan(0);
    expect(screen.getByText("≈ 920 kcal")).toBeInTheDocument();
    expect(screen.getByRole("navigation", { name: "Activity detail sections" })).toBeInTheDocument();
    const route = screen.getByRole("img", { name: /Activity route synchronized with the chart crosshair/ });
    const summary = screen.getByText("Run summary");
    const lap = screen.getByText("Garmin lap 1");
    const charts = screen.getByText("Follow the effort");
    expect(route.compareDocumentPosition(summary) & Node.DOCUMENT_POSITION_FOLLOWING).toBeTruthy();
    expect(summary.compareDocumentPosition(lap) & Node.DOCUMENT_POSITION_FOLLOWING).toBeTruthy();
    expect(lap.compareDocumentPosition(charts) & Node.DOCUMENT_POSITION_FOLLOWING).toBeTruthy();
    expect(screen.queryByText("Kilometre 1")).not.toBeInTheDocument();
    const lapRow = lap.closest("tr");
    expect(lapRow).not.toBeNull();
    const splitsTable = screen.getByRole("table", { name: "Laps split comparison" });
    expect(within(splitsTable).getByRole("columnheader", { name: "Lap" })).toBeInTheDocument();
    expect(within(splitsTable).getByRole("columnheader", { name: "Pace" })).toBeInTheDocument();
    expect(within(splitsTable).getByRole("columnheader", { name: "Elevation change in metres" })).toHaveTextContent("Elev");
    expect(within(splitsTable).getByRole("columnheader", { name: "Average heart rate" })).toHaveTextContent("HR");
    expect(within(splitsTable).getByRole("columnheader", { name: "Average power in watts" })).toHaveTextContent("W");
    expect(within(lapRow as HTMLTableRowElement).getByText("5:00")).toBeInTheDocument();
    expect(within(lapRow as HTMLTableRowElement).getByText("-3", { exact: true })).toBeInTheDocument();
    expect(within(lapRow as HTMLTableRowElement).queryByText("12", { exact: true })).not.toBeInTheDocument();
    expect(within(lapRow as HTMLTableRowElement).getByText("146")).toBeInTheDocument();
    expect(within(lapRow as HTMLTableRowElement).getByText("278")).toBeInTheDocument();
    expect(lapRow?.querySelector<HTMLElement>(".fitness-module__run-split-bar > span")).toHaveStyle({ width: "76%" });
    expect(within(lapRow as HTMLTableRowElement).getByText("10:20 elapsed")).toBeInTheDocument();
    expect(within(lapRow as HTMLTableRowElement).getByText("10:00 moving")).toBeInTheDocument();
    expect(within(lapRow as HTMLTableRowElement).getByText("146 beats per minute")).toBeInTheDocument();
    expect(within(lapRow as HTMLTableRowElement).getByText("162 max")).toBeInTheDocument();
    expect(screen.getByRole("img", { name: /Pace chart/ })).toBeInTheDocument();
    expect(screen.getByRole("img", { name: /Heart rate chart/ })).toBeInTheDocument();
    expect(screen.getByText("Average 5:00/km")).toBeInTheDocument();
    expect(screen.queryByText("Average 5:02/km")).not.toBeInTheDocument();
    const pointDetails = screen.getByText(/Selected point details/);
    expect(charts.compareDocumentPosition(pointDetails) & Node.DOCUMENT_POSITION_FOLLOWING).toBeTruthy();
    expect(screen.queryByRole("button", { name: "Reanalyse FIT" })).not.toBeInTheDocument();
    expect(screen.getAllByText("Heart-rate coverage is below 80%; heart-rate conclusions are limited.")).toHaveLength(1);
    expect(screen.queryByText(/heart_rate_dropout|heart_rate_decoupling/)).not.toBeInTheDocument();
    fireEvent.click(screen.getByText("Manage activity"));
    expect(screen.getByRole("button", { name: "Edit context" })).toBeInTheDocument();
    expect(screen.getByText(/Apple Health · Active/)).toBeInTheDocument();
    fireEvent.click(screen.getByRole("button", { name: /^Kilometres/ }));
    expect(screen.getByText("Kilometre 1")).toBeInTheDocument();
    const kilometreTable = screen.getByRole("table", { name: "Kilometres split comparison" });
    expect(within(kilometreTable).getByRole("columnheader", { name: "Km" })).toBeInTheDocument();
    expect(within(kilometreTable).getByText("1")).toBeInTheDocument();
  });

  it("offers FIT reanalysis only when the retained source is a manual FIT upload", async () => {
    apiMock.mockImplementation(async (path) => {
      if (path === "/fitness/activities/retained-fit") return {
        activity: { id: "retained-fit", title: "Uploaded run", sport_key: "running", started_at_utc: "2026-08-02T06:00:00Z" },
        sources: [{ id: "source-fit", source_type: "manual_fit", device_name: "Uploaded FIT", is_primary: true }],
        summary_metrics: [], available_stream_metrics: [], intervals: [], records: [], achievements: [], checkins: [], gear: [], data_quality: [],
      } as never;
      if (path === "/fitness/activities/retained-fit/analysis") return {};
      if (path === "/fitness/activities/retained-fit/comparisons") return [];
      if (["/fitness/gear", "/fitness/goals", "/fitness/planned-sessions", "/fitness/body-locations"].includes(String(path))) return [];
      throw new Error(`Unexpected request: ${path}`);
    });

    render(<FitnessActivityDetailDialog activityId="retained-fit" open onOpenChange={vi.fn()} onChanged={vi.fn()} />);
    fireEvent.click(await screen.findByText("Manage activity"));
    expect(await screen.findByRole("button", { name: "Reanalyse FIT" })).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "Edit context" })).toBeInTheDocument();
  });

  it("uses the server body-location registry when adding activity context", async () => {
    apiMock.mockImplementation(async (path, init) => {
      if (path === "/fitness/activities/run-1") return {
        activity: { id: "run-1", title: "Morning run", sport_key: "running", started_at_utc: "2026-08-02T06:00:00Z" },
        sources: [], summary_metrics: [], available_stream_metrics: [], intervals: [], records: [], achievements: [], checkins: [], gear: [], data_quality: [],
        body_issues: [{ id: "legacy-issue", body_location_key: "old_spot", side: "left", severity_0_10: 2, timing: "post", changed_session: false, session_change_key: "none" }],
      } as never;
      if (path === "/fitness/activities/run-1/analysis") return {};
      if (path === "/fitness/goals") return [{ id: "goal-1", name: "Run consistently", goal_type: "running", starts_on: "2026-07-01", status: "active" }];
      if (path === "/fitness/activities/run-1/comparisons" || path === "/fitness/gear" || path === "/fitness/planned-sessions") return [];
      if (path === "/fitness/body-locations") return [{ id: "location-hamstring", location_key: "hamstring", display_name: "Hamstring", active: true }];
      throw new Error(`Unexpected request: ${path}`);
    });

    render(<FitnessActivityDetailDialog activityId="run-1" open onOpenChange={vi.fn()} onChanged={vi.fn()} />);
    expect(await screen.findByText("Custom/legacy: old spot · 2/10")).toBeInTheDocument();
    fireEvent.click(screen.getByText("Manage activity"));
    fireEvent.click(screen.getByRole("button", { name: "Edit context" }));
    fireEvent.click(screen.getByLabelText("Record a structured post-session body issue"));
    expect(await screen.findByRole("option", { name: "Hamstring" })).toBeInTheDocument();
    fireEvent.change(screen.getByLabelText("Body location"), { target: { value: "hamstring" } });
    fireEvent.click(screen.getByText("Goals (0)"));
    fireEvent.click(screen.getByRole("checkbox", { name: "Run consistently" }));
    fireEvent.click(screen.getByRole("button", { name: "Save context" }));

    await waitFor(() => expect(saveManyMock).toHaveBeenCalledWith(expect.arrayContaining([
      expect.objectContaining({ entityType: "activity_context", options: expect.objectContaining({ entityId: "run-1" }) }),
      expect.objectContaining({ entityType: "activity_goal_link", payload: expect.objectContaining({ activity_id: "run-1", goal_id: "goal-1", role: "user_assigned" }) }),
      expect.objectContaining({ entityType: "body_issue", payload: expect.objectContaining({ activity_id: "run-1", body_location_key: "hamstring" }) }),
    ])));
  });
});
