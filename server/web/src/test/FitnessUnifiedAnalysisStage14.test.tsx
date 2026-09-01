import { fireEvent, render, screen, waitFor } from "@testing-library/react";
import { beforeEach, describe, expect, it, vi } from "vitest";

import { api } from "../api";
import { runFitnessAnalysis, validateFitnessAnalysisQuery } from "../fitness/analysis";
import type {
  FitnessAnalysisChartType,
  FitnessAnalysisQueryResult,
  FitnessAnalysisRegistry,
} from "../fitness/contract";
import { FitnessAnalysisVisualisation } from "../views/fitness/FitnessAnalysisVisualisation";
import { FitnessExploreView } from "../views/fitness/FitnessExploreView";
import { FitnessProgressView } from "../views/fitness/FitnessProgressView";

vi.mock("../api", () => ({
  api: vi.fn(),
  ApiError: class ApiError extends Error {
    status: number;
    constructor(message: string, status: number) { super(message); this.status = status; }
  },
}));

vi.mock("../fitness/offlineStore", () => ({
  cacheFitnessProgressCharts: vi.fn().mockResolvedValue(undefined),
  cacheFitnessRecords: vi.fn().mockResolvedValue(undefined),
  cachedFitnessProgressCharts: vi.fn().mockResolvedValue(null),
  cachedFitnessRecords: vi.fn().mockResolvedValue([]),
  saveFitnessRecord: vi.fn(),
  fitnessProgressPhotosOnDevice: vi.fn().mockResolvedValue([]),
}));

const apiMock = vi.mocked(api);
const chartTypes: FitnessAnalysisChartType[] = ["line", "rolling_average", "bar", "stacked_bar", "scatter", "histogram", "calendar_heatmap", "range_band", "table"];

function registry(): FitnessAnalysisRegistry {
  return {
    dimensions: [
      { key: "week", label: "Week", value_type: "date" },
      { key: "readiness", label: "Contemporaneous readiness", value_type: "category" },
    ],
    measures: [{
      key: "running.comparable_pace",
      label: "Comparable running pace",
      description: "Observed comparable performance.",
      unit_key: "s_per_km",
      supported_dimensions: ["week", "readiness"],
      chart_types: chartTypes,
      allowed_filter_keys: ["sport_key"],
      comparison_forms: ["previous_period"],
      default_chart_type: "line",
      classification: "correlational",
      minimum_sample_size: 3,
    }],
    chart_types: chartTypes.map((key) => ({ key, label: key.replaceAll("_", " ") })),
    filters: [{ key: "sport_key", label: "Sport", value_type: "registered_key", operators: ["eq", "in"], values: [{ key: "running", label: "Running" }], max_values: 2 }],
    comparisons: [{ key: "previous_period", label: "Previous period" }],
    limits: { max_window_days: 366, max_output_points: 200, max_filters: 4, heavy_poll_interval_ms: 1 },
    default_queries: [{ key: "running-progress", label: "Running progress", description: "Comparable observed runs", dimension_key: "week", measure_key: "running.comparable_pace", chart_type_key: "line", date_window_days: 84, surface: "both", category: "running" }],
  };
}

function result(chartType: FitnessAnalysisChartType = "line", status: FitnessAnalysisQueryResult["status"] = "complete"): FitnessAnalysisQueryResult {
  return {
    status,
    title: "Comparable running pace",
    description: "Recorded outcomes at comparable effort.",
    dimension_key: "week",
    measure_key: "running.comparable_pace",
    chart_type_key: chartType,
    unit_key: "s_per_km",
    series: [
      { key: "observed", label: "Observed", unit_key: "s_per_km", points: [
        { key: "one", label: "Week one", x: "2026-07-20", x_value: 1, value: 312, low: 300, high: 325, sample_size: 3, missing_rate: 0.1, quality: "measured" },
        { key: "two", label: "Week two", x: "2026-07-27", x_value: 2, value: 304, low: 296, high: 316, sample_size: 4, missing_rate: 0, quality: "measured" },
      ] },
      { key: "comparison", label: "Previous period", unit_key: "s_per_km", points: [
        { key: "one", label: "Week one", x_value: 1, value: 320, sample_size: 2, missing_rate: 0.2 },
        { key: "two", label: "Week two", x_value: 2, value: 315, sample_size: 3, missing_rate: 0.1 },
      ] },
    ],
    metadata: {
      period: { start: "2026-07-01", end: "2026-08-02" },
      sample_size: 7,
      missing_count: 1,
      missing_rate: 0.125,
      source_quality: ["recorded activity"],
      measurement_quality: ["measured"],
      canonical_policy: "canonical activities and exercise IDs",
      duplicate_policy: "duplicates excluded",
      classification: "correlational",
    },
    summary: "Faster pace coincided with the later weeks.",
    difference: { label: "Descriptive difference", value: -8, unit_key: "s_per_km" },
    limitations: ["Small owner-specific sample."],
  };
}

const props = { online: true, revision: 0, onDataChanged: vi.fn(), onSectionChange: vi.fn() };

describe("Fitness Stage 14 unified analysis", () => {
  beforeEach(() => {
    apiMock.mockReset();
    props.onDataChanged.mockReset();
    window.history.replaceState({}, "", "/");
    Object.defineProperty(window.navigator, "onLine", { configurable: true, value: true });
  });

  it("rejects unknown and incompatible keys before issuing a request", () => {
    const known = { measure_key: "running.comparable_pace", dimension_key: "week", chart_type_key: "line" as const, date_range: { start: "2026-07-01", end: "2026-08-02" }, filters: [], comparison_key: null, max_points: 100 };
    expect(validateFitnessAnalysisQuery(known, registry())).toBeNull();
    expect(validateFitnessAnalysisQuery({ ...known, measure_key: "raw.sql" }, registry())).toBe("Choose an available measure.");
    expect(validateFitnessAnalysisQuery({ ...known, dimension_key: "owner_id" }, registry())).toBe("Choose an available grouping.");
    expect(validateFitnessAnalysisQuery({ ...known, chart_type_key: "bar", date_range: { start: "2020-01-01", end: "2026-08-02" } }, registry())).toBe("The maximum analysis window is 366 days.");
  });

  it("renders every registered chart shape with an accessible data/method fallback and non-causal wording", () => {
    const view = render(<FitnessAnalysisVisualisation result={result("line")} />);
    for (const chartType of chartTypes) {
      view.rerender(<FitnessAnalysisVisualisation result={result(chartType)} />);
      if (chartType === "table") expect(screen.getByRole("table")).toBeInTheDocument();
      else expect(screen.getByRole("img", { name: new RegExp(chartType.replaceAll("_", " "), "i") })).toBeInTheDocument();
    }
    expect(screen.getByText(/Association only — this does not show that one factor caused another/i)).toBeInTheDocument();
    expect(screen.getByText("chosen activities and exercise IDs")).toBeInTheDocument();
    expect(screen.getByText("duplicates excluded")).toBeInTheDocument();
  });

  it("polls a queued bounded query through its registered job endpoint", async () => {
    apiMock.mockImplementation(async (path) => {
      if (path === "/fitness/analysis/query") return { ...result("line", "queued"), job_id: "job-1", poll_after_ms: 1 };
      if (path === "/fitness/analysis/jobs/job-1") return result("line");
      throw new Error(`Unexpected request: ${path}`);
    });
    const query = {
      measure_key: "running.comparable_pace",
      dimension_key: "week",
      chart_type_key: "line" as const,
      date_range: { start: "2026-07-01", end: "2026-08-02" },
      filters: [],
      comparison_key: null,
      max_points: 100,
    };
    const updates: FitnessAnalysisQueryResult[] = [];

    const completed = await runFitnessAnalysis(query, registry(), (update) => updates.push(update), undefined, async () => undefined);

    expect(completed.status).toBe("complete");
    expect(updates.map((update) => update.status)).toEqual(["queued", "complete"]);
    expect(apiMock).toHaveBeenCalledWith("/fitness/analysis/jobs/job-1", { signal: undefined }, true, false);
  });

  it("saves only registered analysis definition keys", async () => {
    apiMock.mockImplementation(async (path, init) => {
      if (path === "/fitness/analysis/registry") return registry();
      if (path === "/fitness/analysis/charts" && !init?.method) return [];
      if (path === "/fitness/analysis/query") return result("line");
      if (path === "/fitness/analysis/charts" && init?.method === "POST") return { id: "chart-1", revision: 1, ...JSON.parse(String(init.body)) };
      throw new Error(`Unexpected request: ${path}`);
    });

    render(<FitnessExploreView {...props} />);
    fireEvent.click(screen.getByText("Advanced"));
    fireEvent.click(screen.getByRole("button", { name: "Open advanced builder" }));
    expect(await screen.findByRole("option", { name: "Comparable running pace" })).toBeInTheDocument();
    await waitFor(() => expect(screen.getByLabelText("Group by")).toHaveValue("week"));
    fireEvent.click(screen.getByRole("button", { name: "Add filter" }));
    fireEvent.click(screen.getByRole("button", { name: "Run analysis" }));
    expect(await screen.findByText("Faster pace coincided with the later weeks.", {}, { timeout: 2_000 })).toBeInTheDocument();

    fireEvent.change(screen.getByLabelText("Chart name"), { target: { value: "My running view" } });
    fireEvent.click(screen.getByRole("button", { name: "Save definition" }));
    await waitFor(() => expect(apiMock).toHaveBeenCalledWith("/fitness/analysis/charts", expect.objectContaining({ method: "POST" }), true, false));
    const saveCall = apiMock.mock.calls.find(([path, init]) => path === "/fitness/analysis/charts" && init?.method === "POST");
    const body = JSON.parse(String(saveCall?.[1]?.body));
    expect(body).toEqual({ name: "My running view", measure_key: "running.comparable_pace", dimension_key: "week", chart_type_key: "line", filter_keys: ["sport_key"], comparison_key: null, date_window_days: 84 });
    expect(JSON.stringify(body)).not.toMatch(/sql|running\"/i);
  });

  it("keeps coaching in Coach instead of duplicating assistant UI in Explore", async () => {
    apiMock.mockImplementation(async (path) => {
      if (path === "/fitness/analysis/registry") return registry();
      if (path === "/fitness/analysis/charts") return [];
      throw new Error(`Unexpected request: ${path}`);
    });

    render(<FitnessExploreView {...props} />);
    fireEvent.click(screen.getByText("Advanced"));
    fireEvent.click(screen.getByRole("button", { name: "Open advanced builder" }));
    await screen.findByRole("option", { name: "Comparable running pace" });

    expect(screen.queryByText("Ask Hermes about this")).not.toBeInTheDocument();
    expect(screen.queryByLabelText("Ask Hermes about this analysis")).not.toBeInTheDocument();
    expect(apiMock.mock.calls.some(([path]) => path === "/auth/ai-consent" || path === "/fitness/coach/message")).toBe(false);
  });

  it("keeps Progress on its weekly review and leaves analysis unloaded until Insights", async () => {
    apiMock.mockImplementation(async (path) => {
      if (path === "/fitness/goals" || String(path).startsWith("/fitness/activities?")) return [];
      if (String(path).startsWith("/fitness/weekly-review?")) return {
        week_start: "2026-08-03", week_end: "2026-08-09",
        totals: { completed_sessions: 0, active_days: 0 }, goal: null,
        highlight: { title: "A fresh week", detail: "One useful action is enough." },
        opportunity: { title: "Plan one session", detail: "Make the week concrete.", destination: "plan", action: "plan_session", action_label: "Plan a session" },
      };
      throw new Error(`Unexpected request: ${path}`);
    });

    render(<FitnessProgressView {...props} />);
    expect(await screen.findByText("A fresh week")).toBeInTheDocument();
    expect(screen.getByText("Choose one goal to follow")).toBeInTheDocument();
    expect(screen.getByRole("heading", { name: "Recent activity" })).toBeInTheDocument();
    expect(apiMock).not.toHaveBeenCalledWith("/fitness/progress", expect.anything(), expect.anything(), expect.anything());
    expect(apiMock.mock.calls.some(([path]) => path === "/fitness/analysis/registry" || path === "/fitness/analysis/query")).toBe(false);
  });
});
