import { fireEvent, render, screen, waitFor, within } from "@testing-library/react";
import { beforeEach, describe, expect, it, vi } from "vitest";

import { api } from "../api";
import { saveFitnessRecord } from "../fitness/offlineStore";
import { FitnessExploreView } from "../views/fitness/FitnessExploreView";
import { FitnessProgressView } from "../views/fitness/FitnessProgressView";
import { FitnessRecoveryView } from "../views/fitness/FitnessRecoveryView";
import { FitnessTrainingView } from "../views/fitness/FitnessTrainingView";

vi.mock("../api", () => ({
  api: vi.fn(),
  ApiError: class ApiError extends Error {
    status: number;
    constructor(message: string, status: number) { super(message); this.status = status; }
  },
  getAuthSessionEpoch: vi.fn(() => 0),
}));

vi.mock("../fitness/offlineStore", () => ({
  cacheFitnessProgressCharts: vi.fn().mockResolvedValue(undefined),
  cacheFitnessRecords: vi.fn().mockResolvedValue(undefined),
  cachedFitnessProgressCharts: vi.fn().mockResolvedValue(null),
  cachedFitnessRecords: vi.fn().mockResolvedValue([]),
  saveFitnessRecord: vi.fn(),
  saveFitnessRecords: vi.fn().mockResolvedValue([]),
  fitnessProgressPhotosOnDevice: vi.fn().mockResolvedValue([]),
}));

const apiMock = vi.mocked(api);
const saveMock = vi.mocked(saveFitnessRecord);
const onDataChanged = vi.fn();
const onSectionChange = vi.fn();
const props = { online: true, revision: 0, onDataChanged, onSectionChange, onOpenCalendar: vi.fn() };

function localDate(date = new Date()): string {
  return `${date.getFullYear()}-${String(date.getMonth() + 1).padStart(2, "0")}-${String(date.getDate()).padStart(2, "0")}`;
}

function weekStart(): string {
  const date = new Date();
  date.setHours(12, 0, 0, 0);
  date.setDate(date.getDate() - ((date.getDay() + 6) % 7));
  return localDate(date);
}

function dateOffset(days: number): string {
  const date = new Date(`${weekStart()}T12:00:00`);
  date.setDate(date.getDate() + days);
  return localDate(date);
}

const weeklyReview = {
  week_start: weekStart(), week_end: dateOffset(6),
  totals: { completed_sessions: 2, active_days: 2, duration_minutes: 83, distance_km: 12.4 },
  goal: { goal_id: "goal-run", goal_name: "Run consistently", progress_text: "12.4 of 20 km", progress_percent: 62 },
  highlight: { title: "A strong week", detail: "Two planned sessions became completed activity." },
  opportunity: { title: "Place the next run", detail: "Choose a day that fits the family calendar.", destination: "plan", action: "plan_session", action_label: "Plan the next run" },
};

describe("Fitness Wave 4 production experience", () => {
  beforeEach(() => {
    window.history.replaceState({}, "", "/?view=fitness");
    Object.defineProperty(window.navigator, "onLine", { configurable: true, value: true });
    Object.defineProperty(window, "matchMedia", { configurable: true, value: vi.fn(() => ({ matches: false, addEventListener: vi.fn(), removeEventListener: vi.fn() })) });
    Object.defineProperty(window, "scrollTo", { configurable: true, value: vi.fn() });
    Object.defineProperty(HTMLElement.prototype, "scrollIntoView", { configurable: true, value: vi.fn() });
    apiMock.mockReset();
    saveMock.mockReset();
    saveMock.mockImplementation(async (_type, payload, options) => ({ ...payload, id: options?.entityId ?? crypto.randomUUID(), queued_offline: true }));
    onDataChanged.mockReset();
    onSectionChange.mockReset();
    props.onOpenCalendar.mockReset();
  });

  it("orders Plan around the next session and keeps goal creation lazy and human", async () => {
    const tomorrow = new Date(Date.now() + 86_400_000);
    const session = {
      id: "session-next", revision: 2, title: "Easy family run", sport_key: "running", status: "accepted",
      scheduled_date: localDate(tomorrow), scheduled_start_utc: `${localDate(tomorrow)}T07:00:00Z`, expected_duration_s: 2_400, movable: true,
    };
    const programme = { id: "programme-1", name: "Autumn base", purpose: "Build a calm running habit", starts_on: localDate(), status: "active" };
    const template = {
      id: "run-faster-5k", title: "Run a faster 5K", description: "Work towards a time that matters to you.",
      target_prompt: "What 5K time are you aiming for?", input_kind: "duration_minutes_seconds", unit_label: "5K time",
      minimum_value: 720, maximum_value: 7_200, step: 5, suggested_value: 1_500, supports_target_date: true,
    };
    const bodyWeightTemplate = {
      id: "body-weight-support", title: "Support a body-weight goal", description: "Follow a gradual weight trend.",
      target_prompt: "What weight?", input_kind: "target_weight_kg", unit_label: "kg",
      minimum_value: 30, maximum_value: 300, step: 0.1, suggested_value: 75, supports_target_date: true,
    };
    apiMock.mockImplementation(async (path, init) => {
      if (path === "/fitness/planned-sessions") return [session] as never;
      if (path === "/fitness/training-programmes") return [programme] as never;
      if (path === "/fitness/integrations/strava/status") return { configured: false, connected: false, status: "not_configured", imported_activity_count: 0 } as never;
      if (path === "/fitness/goal-templates") return [template, bodyWeightTemplate] as never;
      if (path === "/fitness/goals" || path === "/fitness/phases") return [] as never;
      if (path === "/fitness/goals/from-template" && init?.method === "POST") return { goal_id: "goal-new", template_id: template.id, title: "Run 5K in 22:30", target_text: "Run 5K in 22:30", starts_on: localDate(), target_date: null, priority: 50, status: "active" } as never;
      throw new Error(`Unexpected request: ${path}`);
    });

    render(<FitnessTrainingView {...props} />);
    const launcher = (await screen.findByRole("heading", { name: "What do you want to do?" })).closest("section")!;
    expect(within(launcher).getByRole("button", { name: "Run" })).toBeInTheDocument();
    expect(within(launcher).getByRole("button", { name: "Strength" })).toBeInTheDocument();
    expect(within(launcher).getByRole("button", { name: "Other" })).toBeInTheDocument();
    expect(within(launcher).queryByRole("button", { name: "Walk" })).not.toBeInTheDocument();
    expect(within(launcher).queryByRole("button", { name: "Ride" })).not.toBeInTheDocument();
    const next = screen.getByText("Up next").closest("section")!;
    const week = screen.getByRole("region", { name: "Seven days at a glance" });
    const programmes = screen.getByRole("region", { name: "The longer view" });
    expect(launcher.compareDocumentPosition(next) & Node.DOCUMENT_POSITION_FOLLOWING).toBeTruthy();
    expect(next.compareDocumentPosition(week) & Node.DOCUMENT_POSITION_FOLLOWING).toBeTruthy();
    expect(week.compareDocumentPosition(programmes) & Node.DOCUMENT_POSITION_FOLLOWING).toBeTruthy();
    expect(within(next).getByRole("button", { name: "Open" })).toBeInTheDocument();
    expect(within(next).getByRole("button", { name: "Move" })).toBeInTheDocument();
    expect(screen.getByText("Running plans")).toBeInTheDocument();
    expect(apiMock.mock.calls.map(([path]) => path)).toEqual(expect.arrayContaining(["/fitness/planned-sessions", "/fitness/training-programmes"]));
    expect(apiMock.mock.calls.some(([path]) => path === "/fitness/goal-templates" || path === "/fitness/gear" || path === "/fitness/exercises")).toBe(false);

    fireEvent.click(screen.getByText("Goals and training tools"));
    const goalChoice = await screen.findByRole("radio", { name: /Run a faster 5K/ });
    const otherGoals = screen.getByText("Other goals", { selector: "summary" }).closest("details");
    expect(otherGoals).not.toHaveAttribute("open");
    expect(within(otherGoals!).getByRole("radio", { name: /Support a body-weight goal/ })).toBeInTheDocument();
    fireEvent.click(goalChoice);
    const targetTime = screen.getByRole("group", { name: "What 5K time are you aiming for?" });
    fireEvent.change(within(targetTime).getByLabelText("Minutes"), { target: { value: "22" } });
    fireEvent.change(within(targetTime).getByLabelText("Seconds"), { target: { value: "30" } });
    expect(document.body.textContent).not.toContain("running.5k_seconds");
    fireEvent.click(screen.getByRole("button", { name: "Create goal" }));
    await waitFor(() => expect(apiMock).toHaveBeenCalledWith("/fitness/goals/from-template", expect.objectContaining({ method: "POST" }), true, false));
    const call = apiMock.mock.calls.find(([path, init]) => path === "/fitness/goals/from-template" && init?.method === "POST");
    expect(JSON.parse(String(call?.[1]?.body))).toMatchObject({ template_id: "run-faster-5k", target_value: 1_350, priority: 50, client_id: "hausklar-web" });
    expect(String(call?.[1]?.body)).not.toContain("metric_key");
  });

  it("renders weekly review, actual goal trend, and completed history in that order", async () => {
    const activities = [
      { id: "run-current", title: "Riverside run", sport_key: "running", started_at_utc: `${dateOffset(1)}T07:00:00Z`, distance_m: 7_400, duration_s: 2_300, moving_duration_s: 2_220, energy_kcal: 456, energy_estimation_method: "met_v1", status: "completed", planned_session_title: "Tuesday steady run" },
      { id: "run-current-2", title: "Park run", sport_key: "running", started_at_utc: `${dateOffset(3)}T07:00:00Z`, distance_m: 5_000, duration_s: 1_700, status: "complete" },
      { id: "run-importing", title: "Half imported run", sport_key: "running", started_at_utc: `${dateOffset(4)}T07:00:00Z`, distance_m: 99_000, duration_s: 8_000, status: "importing" },
    ];
    apiMock.mockImplementation(async (path) => {
      if (path === "/fitness/goals") return [{ id: "goal-run", name: "Run consistently", goal_type: "running", metric_key: "running.distance_m", starts_on: dateOffset(-30), status: "active" }] as never;
      if (String(path).startsWith("/fitness/activities?")) return activities as never;
      if (String(path).startsWith("/fitness/weekly-review?")) return weeklyReview as never;
      if (path === "/fitness/progress/charts") return {
        weight: [],
        running: [
          { key: "5k", label: "5K", distance_m: 5000, points: [{ activity_id: "run-old", started_at_utc: `${dateOffset(-14)}T07:00:00Z`, duration_s: 1_800, source: "best_effort" }, { activity_id: "run-current-2", started_at_utc: `${dateOffset(3)}T07:00:00Z`, duration_s: 1_700, source: "best_effort" }] },
          { key: "10k", label: "10K", distance_m: 10000, points: [] },
        ],
        strength: [
          { key: "squat", label: "Squat", exercise_id: "squat", exercise_name: "Barbell Back Squat", setup_id: "rack", setup_name: "Home rack", points: [{ activity_id: "lift-1", performed_at_utc: `${dateOffset(-14)}T18:00:00Z`, load_kg: 80, repetitions: 6, working_set_count: 3 }, { activity_id: "lift-2", performed_at_utc: `${dateOffset(2)}T18:00:00Z`, load_kg: 85, repetitions: 6, working_set_count: 3 }] },
          { key: "chest_press", label: "Chest press", points: [] },
          { key: "overhead_press", label: "Overhead press", points: [] },
        ],
      } as never;
      if (path === "/fitness/body/measurements") return [] as never;
      throw new Error(`Unexpected request: ${path}`);
    });

    render(<FitnessProgressView {...props} />);
    expect(await screen.findByRole("heading", { name: "Review", level: 2 })).toBeInTheDocument();
    const review = (await screen.findByText("A strong week")).closest("section")!;
    const goal = screen.getByRole("heading", { name: "Run consistently" }).closest("section")!;
    const history = screen.getByRole("heading", { name: "Recent activity" }).closest("section")!;
    expect(review.compareDocumentPosition(goal) & Node.DOCUMENT_POSITION_FOLLOWING).toBeTruthy();
    expect(goal.compareDocumentPosition(history) & Node.DOCUMENT_POSITION_FOLLOWING).toBeTruthy();
    expect(screen.getByRole("img", { name: /Synthetic public demo record 2: 12.4 km this week/i })).toBeInTheDocument();
    expect(screen.getByRole("img", { name: /1:40 faster/i })).toBeInTheDocument();
    expect(screen.getByRole("img", { name: /85 kg × 6 · 5 kg higher/i })).toBeInTheDocument();
    expect(screen.getByRole("img", { name: /3 working sets/i })).toBeInTheDocument();
    const fiveKTile = screen.getByText("5K time").closest("article")!;
    expect(fiveKTile.querySelectorAll(".fitness-progress-charts__y-axis span")).toHaveLength(3);
    const latestFiveK = within(fiveKTile).getByRole("button", { name: /5:40\/km · 28:20 total/ });
    fireEvent.pointerEnter(latestFiveK);
    const paceTooltip = within(fiveKTile).getByText("5:40/km · 28:20 total").closest("output");
    expect(paceTooltip).toBeInTheDocument();
    expect(paceTooltip).toHaveStyle({ left: "75%" });
    expect(screen.getByText(/5:40\/km · 28:20 total/)).toBeInTheDocument();
    expect(screen.getByText("Riverside run")).toBeInTheDocument();
    expect(screen.getByText(/7\.4 km · 5:00\/km · 37 min · ≈ 456 kcal/)).toBeInTheDocument();
    expect(screen.getByText("Matched to Tuesday steady run")).toBeInTheDocument();
    expect(screen.getByRole("heading", { name: "Weight progress" })).toBeInTheDocument();
    expect(screen.queryByText("Half imported run")).not.toBeInTheDocument();
    expect(screen.queryByText("kg lifted")).not.toBeInTheDocument();
    const activityPath = String(apiMock.mock.calls.find(([path]) => String(path).startsWith("/fitness/activities?"))?.[0]);
    expect(activityPath).toMatch(/date_from=\d{4}-\d{2}-\d{2}&date_to=\d{4}-\d{2}-\d{2}&limit=200/);
    expect(apiMock.mock.calls.some(([path]) => path === "/fitness/analysis/registry" || String(path).startsWith("/fitness/recovery/"))).toBe(false);
    expect(apiMock.mock.calls.some(([path]) => path === "/fitness/body/measurements")).toBe(true);
    expect(screen.getByRole("button", { name: "Ask Coach about this week" })).toBeInTheDocument();
    expect(apiMock.mock.calls.some(([path]) => String(path).startsWith("/fitness/coach"))).toBe(false);

    fireEvent.click(screen.getByRole("button", { name: /Riverside run/ }));
    expect(onSectionChange).toHaveBeenCalledWith("activity");
    expect(new URL(window.location.href).searchParams.get("activity")).toBe("run-current");

    fireEvent.click(screen.getByRole("button", { name: /Body.*Measurements and trends/i }));
    await waitFor(() => expect(apiMock).toHaveBeenCalledWith(
      "/fitness/body/measurements",
      { signal: expect.any(AbortSignal) },
      true,
      false,
    ));
  });

  it("keeps Recovery useful by default and moves connections and body issues into Manage", async () => {
    apiMock.mockImplementation(async (path) => {
      if (String(path).startsWith("/fitness/sleep/sessions?")) return [{ id: "sleep-1", sleep_start_utc: `${dateOffset(0)}T22:15:00Z`, sleep_end_utc: `${dateOffset(1)}T06:15:00Z`, duration_s: 28_800, source_quality: "wearable", source_stages: [], source: { origin_provider_key: "apple", transport_key: "healthkit", source_name: "Apple Watch", state: "active" } }] as never;
      if (String(path).startsWith("/fitness/recovery/summary?")) return { window: { from_date: dateOffset(-27), to_date: dateOffset(0), expected_days: 28, days_with_sleep: 22 }, sleep: { average_duration_s: 27_300, average_bedtime_minutes: 1_340, average_wake_time_minutes: 390, timing_regularity_minutes: 24 }, baselines: [], relationships: [] } as never;
      if (String(path).startsWith("/fitness/recovery/observations?")) return [] as never;
      if (path === "/fitness/body-issues") return [] as never;
      if (path === "/fitness/body-locations") return [{ id: "knee", location_key: "knee", display_name: "Knee", active: true }] as never;
      throw new Error(`Unexpected request: ${path}`);
    });

    render(<FitnessRecoveryView {...props} />);
    expect(await screen.findByText(/7h 35m average sleep/)).toBeInTheDocument();
    expect(screen.getByRole("heading", { name: "How ready do you feel?" })).toBeInTheDocument();
    expect(screen.queryByText("Connected apps")).not.toBeInTheDocument();
    expect(apiMock.mock.calls.some(([path]) => String(path).startsWith("/fitness/recovery/observations?") || path === "/fitness/body-issues")).toBe(false);
    fireEvent.click(screen.getByRole("button", { name: "Readiness 4, Good" }));
    fireEvent.click(screen.getByRole("button", { name: "Save readiness" }));
    await waitFor(() => expect(saveMock).toHaveBeenCalledWith("session_checkin", expect.objectContaining({ readiness_1_5: 4, capture_quality: "contemporaneous" }), undefined));

    fireEvent.click(screen.getByText("Manage Recovery"));
    expect(await screen.findByText("Connected apps")).toBeInTheDocument();
    expect(screen.getByText("Apple Health")).toBeInTheDocument();
    fireEvent.click(screen.getByRole("button", { name: /Body issues/ }));
    expect(await screen.findByText("No active body issues")).toBeInTheDocument();
  });

  it("keeps Insights question-led and opens data only after the user asks", async () => {
    apiMock.mockImplementation(async (path, init) => {
      if (String(path).startsWith("/fitness/weekly-review?")) return weeklyReview as never;
      if (path === "/fitness/analysis/registry") return {
        dimensions: [{ key: "week", label: "Week", value_type: "date" }],
        measures: [{ key: "running.comparable_pace", label: "Running pace", unit_key: "s_per_km", supported_dimensions: ["week"], chart_types: ["line"], allowed_filter_keys: [], comparison_forms: [], default_chart_type: "line", classification: "descriptive", minimum_sample_size: 2 }],
        chart_types: [{ key: "line", label: "Line" }], filters: [], comparisons: [], limits: { max_window_days: 366, max_output_points: 200, max_filters: 4 },
        default_queries: [{ key: "running-progress", label: "Running progress", dimension_key: "week", measure_key: "running.comparable_pace", chart_type_key: "line", date_window_days: 84, surface: "both", category: "running" }],
      } as never;
      if (path === "/fitness/analysis/query" && init?.method === "POST") return { status: "complete", title: "Running pace", summary: "Your recent runs became a little quicker.", dimension_key: "week", measure_key: "running.comparable_pace", chart_type_key: "line", unit_key: "s_per_km", series: [{ key: "pace", label: "Pace", points: [{ key: "one", label: "Week one", value: 315 }, { key: "two", label: "Week two", value: 304 }] }], metadata: { period: { start: dateOffset(-27), end: dateOffset(0) }, sample_size: 4, missing_rate: 0, source_quality: [], measurement_quality: [], classification: "descriptive" }, limitations: [] } as never;
      if (path === "/fitness/analysis/charts") return [] as never;
      throw new Error(`Unexpected request: ${path}`);
    });

    render(<FitnessExploreView {...props} />);
    expect(screen.getByRole("button", { name: /What changed this month\?/ })).toBeInTheDocument();
    expect(screen.getByRole("button", { name: /Why has recovery fallen\?/ })).toBeInTheDocument();
    expect(screen.getByRole("button", { name: /Am I progressing toward my goal\?/ })).toBeInTheDocument();
    expect(apiMock).not.toHaveBeenCalled();
    expect(document.body.textContent).not.toMatch(/\b(canonical|source priority|unknown hardness|e1rm|sync|stale|provider|model|confidence|evidence|validation)\b/i);

    fireEvent.click(screen.getByRole("button", { name: /Am I progressing toward my goal\?/ }));
    expect(await screen.findByText("12.4 of 20 km")).toBeInTheDocument();
    expect(apiMock.mock.calls.some(([path]) => path === "/fitness/analysis/registry")).toBe(false);

    fireEvent.click(screen.getByRole("button", { name: /What changed this month\?/ }));
    expect(await screen.findByText("Your recent runs became a little quicker.")).toBeInTheDocument();
    expect(apiMock).toHaveBeenCalledWith(
      "/fitness/analysis/registry",
      { signal: expect.any(AbortSignal) },
      true,
      false,
    );
    expect(apiMock).toHaveBeenCalledWith("/fitness/analysis/query", expect.objectContaining({ method: "POST" }), true, false);

    fireEvent.click(screen.getByText("Advanced", { selector: "summary" }));
    fireEvent.click(screen.getByRole("button", { name: "Open advanced builder" }));
    expect(await screen.findByRole("heading", { name: "Advanced Insights" })).toBeInTheDocument();
    expect(apiMock).toHaveBeenCalledWith(
      "/fitness/analysis/charts",
      { signal: expect.any(AbortSignal) },
      true,
      false,
    );
  });
});
