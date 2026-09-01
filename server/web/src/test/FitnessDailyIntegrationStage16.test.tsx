import { fireEvent, render, screen, waitFor, within } from "@testing-library/react";
import { beforeEach, describe, expect, it, vi } from "vitest";

import { api } from "../api";
import { cachedFitnessRecords, saveFitnessRecord } from "../fitness/offlineStore";
import { FitnessProgressView } from "../views/fitness/FitnessProgressView";
import { cachedFitnessOverview, FitnessTodayView } from "../views/fitness/FitnessTodayView";
import { FitnessTrainingView } from "../views/fitness/FitnessTrainingView";

vi.mock("../api", () => ({
  api: vi.fn(),
  ApiError: class ApiError extends Error { status: number; constructor(message: string, status: number) { super(message); this.status = status; } },
}));

vi.mock("../fitness/offlineStore", () => ({
  cacheFitnessProgressCharts: vi.fn().mockResolvedValue(undefined),
  cacheFitnessRecords: vi.fn().mockResolvedValue(undefined),
  cachedFitnessProgressCharts: vi.fn().mockResolvedValue(null),
  cachedFitnessRecords: vi.fn().mockResolvedValue([]),
  saveFitnessRecord: vi.fn(),
  saveFitnessRecords: vi.fn(),
}));

const plan = {
  id: "plan-1", revision: 2, sport_key: "strength", title: "Full body A", status: "accepted", scheduled_start_utc: "2026-08-02T17:00:00Z", time_window_start_utc: "2026-08-02T16:00:00Z", time_window_end_utc: "2026-08-02T19:00:00Z", expected_duration_s: 3600, intended_gear_ids: ["gear-1"], exercise_items: [],
};
const goal = { id: "goal-1", name: "Build durable strength", goal_type: "strength", metric_key: "strength.sessions", baseline_value: 1, current_value: 3, target_value: 5, unit_key: "sessions", starts_on: "2026-07-01", status: "active" };
const phase = { id: "phase-1", name: "Autumn build", phase_type: "strength_emphasis", starts_on: "2026-07-01", ends_on: "2026-10-01", active: true };
const activity = { id: "activity-1", title: "Steady 5K", sport_key: "running", started_at_utc: "2026-08-01T07:00:00Z", status: "complete", distance_m: 5000, duration_s: 1500 };

const apiMock = vi.mocked(api);
const saveMock = vi.mocked(saveFitnessRecord);
const cachedRecordsMock = vi.mocked(cachedFitnessRecords);
const props = { online: true, revision: 0, onDataChanged: vi.fn(), onSectionChange: vi.fn(), onOpenCalendar: vi.fn() };

describe("Fitness daily integration Stage 16", () => {
  beforeEach(() => {
    plan.status = "accepted";
    const tomorrow = new Date(Date.now() + 86_400_000);
    const tomorrowDate = `${tomorrow.getFullYear()}-${String(tomorrow.getMonth() + 1).padStart(2, "0")}-${String(tomorrow.getDate()).padStart(2, "0")}`;
    plan.scheduled_start_utc = `${tomorrowDate}T17:00:00Z`;
    plan.time_window_start_utc = `${tomorrowDate}T16:00:00Z`;
    plan.time_window_end_utc = `${tomorrowDate}T19:00:00Z`;
    window.history.replaceState({}, "", "/");
    props.onDataChanged.mockReset(); props.onSectionChange.mockReset(); props.onOpenCalendar.mockReset();
    saveMock.mockReset();
    saveMock.mockImplementation(async (_type, payload, options) => ({ ...payload, id: options?.entityId ?? crypto.randomUUID(), queued_offline: true }));
    cachedRecordsMock.mockReset();
    cachedRecordsMock.mockResolvedValue([]);
    apiMock.mockReset();
    Object.defineProperty(window.navigator, "onLine", { configurable: true, value: true });
    apiMock.mockImplementation(async (path) => {
      if (path === "/fitness/overview") return plan.status === "proposed" ? {
        date: "2026-08-02", session: null,
        primary_action: { kind: "create_session", label: "Plan a session", destination: "plan", target_id: null },
        secondary_action: null, quick_actions: [{ kind: "log_food", label: "Log food", destination: "log", target_id: null }],
        coach_nudge: null, safety_adjustment: null,
      } as never : {
        date: "2026-08-02",
        session: { id: plan.id, kind: "planned_session", title: plan.title, sport_key: "strength", status: "accepted", starts_at: plan.scheduled_start_utc, scheduled_date: "2026-08-02", duration_minutes: 60, movable: true },
        primary_action: { kind: "start_session", label: "Start", destination: "plan", target_id: plan.id },
        secondary_action: { kind: "move_session", label: "Move", destination: "plan", target_id: plan.id },
        quick_actions: [{ kind: "record_readiness", label: "Readiness", destination: "log", target_id: plan.id }, { kind: "log_food", label: "Log food", destination: "log", target_id: null }],
        coach_nudge: null, safety_adjustment: null,
      } as never;
      if (path === "/fitness/today") return { date: "2026-08-02", active_goals: [goal], active_phase: phase, planned_sessions: [plan], active_strength_session: null } as never;
      if (path === "/fitness/goals") return [goal] as never;
      if (String(path).startsWith("/fitness/food-log?")) return { nutrition_date: "2026-08-02", entries: [], totals: { calories_kcal: 1800, protein_g: 120 }, targets: { calories_kcal: 2300, protein_g: 150 } } as never;
      if (path === "/fitness/body/weight-trend") return { seven_day_average_kg: 78.4, weekly_rate_kg: -0.1 } as never;
      if (String(path).startsWith("/fitness/recovery/summary?")) return { window: { from_date: "2026-07-06", to_date: "2026-08-02", expected_days: 28, days_with_sleep: 24 }, sleep: { average_duration_s: 27000 }, baselines: [{ metric_key: "hrv", label: "HRV", status: "within_baseline", window_days: 28 }], relationships: [] } as never;
      if (path === "/fitness/gear") return [{ id: "gear-1", gear_type_key: "running_shoe", name: "Daily trainers", default_for_sport_key: "running", active: true, usage_distance_m: 120000 }] as never;
      if (path === "/fitness/session-checkins") return [] as never;
      if (String(path).startsWith("/fitness/body-issues")) return [{ id: "issue-1", observed_at_utc: "2026-08-01T12:00:00Z", issue_type_key: "pain", body_location_key: "knee", side: "left", severity_0_10: 3, timing: "during", changed_session: false, session_change_key: "none", trend_key: "unknown", status: "active" }] as never;
      if (path === "/fitness/coach/recommendations") return [] as never;
      if (path === "/fitness/phases") return [phase] as never;
      if (path === "/fitness/activity-registry") return { sports: [{ key: "strength", display_name: "Strength" }, { key: "running", display_name: "Running" }, { key: "walking", display_name: "Walk" }, { key: "cycling", display_name: "Ride" }, { key: "swimming_pool", display_name: "Pool swimming" }], metrics: [] } as never;
      if (path === "/fitness/planned-sessions") return [plan] as never;
      if (path === "/fitness/integrations/strava/status") return { configured: false, connected: false, status: "not_configured", imported_activity_count: 0 } as never;
      if (path === "/fitness/exercises" || path === "/fitness/exercise-setups" || path === "/fitness/training-programmes" || path === "/fitness/workout-definitions") return [] as never;
      if (String(path).startsWith("/fitness/activities?date_from=")) return [activity] as never;
      if (String(path).startsWith("/fitness/weekly-review?")) return {
        week_start: "2026-08-03", week_end: "2026-08-09",
        totals: { completed_sessions: 1, active_days: 1, duration_minutes: 25, distance_km: 5, strength_volume_kg: 1_800 },
        goal: { goal_id: goal.id, goal_name: goal.name, progress_text: "3 of 5 strength sessions", progress_percent: 60 },
        highlight: { title: "A solid start", detail: "You completed the session you planned." },
        opportunity: { title: "Plan the next lift", detail: "Choose a realistic day.", destination: "plan", action: "plan_session", action_label: "Plan session" },
      } as never;
      if (path === "/fitness/strength/sessions") return [{ id: "strength-1", title: "Lower A", status: "completed", started_at_utc: "2026-07-31T17:00:00Z", local_timezone: "Europe/Berlin" }] as never;
      if (path === "/fitness/strength/muscle-groups") return [{ muscle_group_key: "quadriceps", direct_working_sets: 6, indirect_set_equivalents: 2, direct_hard_sets: 4, unknown_hardness_sets: 1, frequency_days: 2, days_since_last_trained: 2, contributing_exercise_ids: [] }] as never;
      if (path === "/fitness/body/measurements") return [
        { id: "weight-week-ago", revision: 1, metric_key: "body.weight_kg", measured_at_utc: "2026-07-24T07:00:00Z", local_timezone: "Europe/Berlin", value: 79, unit_key: "kg", canonical_state: "canonical", measurement_quality: "measured" },
        { id: "weight-1", revision: 2, metric_key: "body.weight_kg", measured_at_utc: "2026-08-01T07:00:00Z", local_timezone: "Europe/Berlin", value: 78.2, unit_key: "kg", canonical_state: "canonical", measurement_quality: "measured" },
        { id: "fat-week-ago", revision: 1, metric_key: "body.body_fat_pct", measured_at_utc: "2026-07-24T07:00:00Z", local_timezone: "Europe/Berlin", value: 22, unit_key: "%", canonical_state: "canonical", measurement_quality: "measured" },
        { id: "fat-latest", revision: 1, metric_key: "body.body_fat_pct", measured_at_utc: "2026-08-01T07:00:00Z", local_timezone: "Europe/Berlin", value: 21.4, unit_key: "%", canonical_state: "canonical", measurement_quality: "measured", source_record_id: "fat-source" },
        { id: "height-1", revision: 1, metric_key: "body.height_cm", measured_at_utc: "2026-08-01T06:00:00Z", local_timezone: "Europe/Berlin", value: 180, unit_key: "cm", canonical_state: "canonical", measurement_quality: "measured" },
        { id: "weight-imported", revision: 1, metric_key: "body.weight_kg", measured_at_utc: "2026-07-31T07:00:00Z", local_timezone: "Europe/Berlin", value: 78.5, unit_key: "kg", canonical_state: "canonical", manual_canonical_override: true, measurement_quality: "measured", source_record_id: "source-1", source: { origin_provider_key: "apple", transport_key: "healthkit", source_namespace: "com.apple.health", source_device_identifier: "iPhone", state: "active" } },
        { id: "weight-duplicate", revision: 2, metric_key: "body.weight_kg", measured_at_utc: "2026-07-31T07:01:00Z", local_timezone: "Europe/Berlin", value: 78.5, unit_key: "kg", canonical_state: "duplicate", duplicate_of_measurement_id: "weight-imported", measurement_quality: "measured", source_record_id: "source-2", source: { origin_provider_key: "apple", transport_key: "file_import", source_namespace: "apple-export", source_device_identifier: "iPhone export", state: "active" } },
        { id: "weight-excluded", revision: 1, metric_key: "body.weight_kg", measured_at_utc: "2026-07-30T07:00:00Z", local_timezone: "Europe/Berlin", value: 80.1, unit_key: "kg", canonical_state: "excluded", measurement_quality: "measured", source_record_id: "source-3", source: { origin_provider_key: "apple", transport_key: "file_import", source_namespace: "apple-export", source_device_identifier: "iPhone export", state: "deleted" } },
      ] as never;
      if (String(path).startsWith("/fitness/measurements/history?metric=")) return {
        metric: "weight", title: "Weight", unit: "kg", smoothing_method: "time_weighted_exponential", smoothing_half_life_days: 7, sample_count: 3,
        series: [{ key: "weight", label: "Weight", unit: "kg", points: [
          { id: "history-1", measured_at_utc: "2026-07-20T07:00:00Z", raw_value: 79.1, trend_value: 79.1 },
          { id: "history-2", measured_at_utc: "2026-07-27T07:00:00Z", raw_value: 78.7, trend_value: 78.9 },
          { id: "history-3", measured_at_utc: "2026-08-01T07:00:00Z", raw_value: 78.2, trend_value: 78.5 },
        ] }],
      } as never;
      if (path === "/fitness/integrations/withings/status") return { configured: false, connected: false, status: "not_configured" } as never;
      if (path === "/fitness/analysis/registry") return { dimensions: [], measures: [], chart_types: [], filters: [], comparisons: [], limits: { max_window_days: 366, max_output_points: 200, max_filters: 4 }, default_queries: [] } as never;
      return [] as never;
    });
  });

  it("keeps Overview compact and captures readiness before one-tap strength start", async () => {
    render(<FitnessTodayView {...props} />);
    expect(await screen.findByText("Full body A")).toBeInTheDocument();
    expect(screen.queryByText(/gear: Daily trainers|1,800|active knee issue/i)).not.toBeInTheDocument();
    const readinessChoices = screen.getByRole("group", { name: "Record readiness from one to five" });
    expect(readinessChoices).toHaveClass("fitness-module__readiness--choices");
    expect(within(readinessChoices).getAllByRole("button")).toHaveLength(5);
    fireEvent.click(screen.getByRole("button", { name: "Record readiness 4 of 5" }));
    await waitFor(() => expect(saveMock).toHaveBeenCalledWith("session_checkin", expect.objectContaining({ planned_session_id: plan.id, timing: "pre", readiness_1_5: 4, captured_before_activity_start: true }), undefined));
    fireEvent.click(screen.getByRole("button", { name: "Start" }));
    expect(props.onSectionChange).toHaveBeenCalledWith("strength");
    expect(new URL(window.location.href).searchParams.get("fitness-strength-start")).toBe(plan.id);
  });

  it("does not present a proposed session as an accepted start", async () => {
    plan.status = "proposed";
    render(<FitnessTodayView {...props} />);
    expect(await screen.findByText("Choose your next session")).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "Plan a session" })).toBeInTheDocument();
    expect(screen.queryByRole("button", { name: "Start" })).not.toBeInTheDocument();
  });

  it("shows an invoked action failure beside the quick action", async () => {
    saveMock.mockRejectedValueOnce(new Error("Readiness could not be saved"));
    render(<FitnessTodayView {...props} />);
    fireEvent.click(await screen.findByRole("button", { name: "Record readiness 3 of 5" }));
    expect(await screen.findByRole("alert")).toHaveTextContent("Readiness could not be saved");
  });

  it("uses owner-scoped cached sessions silently on a first offline load", async () => {
    Object.defineProperty(window.navigator, "onLine", { configurable: true, value: false });
    const tomorrow = new Date(Date.now() + 24 * 60 * 60 * 1000);
    const tomorrowDate = `${tomorrow.getFullYear()}-${String(tomorrow.getMonth() + 1).padStart(2, "0")}-${String(tomorrow.getDate()).padStart(2, "0")}`;
    const staleRun = { ...plan, id: "stale-run", sport_key: "running", title: "Old accepted run", status: "accepted", scheduled_start_utc: "2020-01-01T07:00:00Z", time_window_start_utc: null, time_window_end_utc: null, movable: true };
    const cachedRun = { ...plan, id: "cached-run", sport_key: "running", title: "Cached easy run", status: "accepted", scheduled_date: tomorrowDate, scheduled_start_utc: `${tomorrowDate}T07:00:00Z`, time_window_start_utc: null, time_window_end_utc: null, movable: true };
    cachedRecordsMock.mockImplementation(async (entityType) => entityType === "planned_session" ? [staleRun, cachedRun] as never : [] as never);

    render(<FitnessTodayView {...props} />);
    expect(await screen.findByText("Cached easy run")).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "Open" })).toBeInTheDocument();
    expect(screen.queryByText("Old accepted run")).not.toBeInTheDocument();
    expect(screen.queryByText(/You.re offline|stale data|syncing|waiting to sync/i)).not.toBeInTheDocument();
    expect(apiMock.mock.calls.some(([path]) => path === "/fitness/overview")).toBe(false);

    fireEvent.click(screen.getByRole("button", { name: "Open" }));
    expect(props.onSectionChange).toHaveBeenCalledWith("training");
    expect(new URL(window.location.href).searchParams.get("session")).toBe("cached-run");
  });

  it("never offers Resume for a cached strength workout older than one hour", () => {
    const now = new Date("2026-08-13T12:00:00Z");
    const overview = cachedFitnessOverview([], [{
      id: "forgotten-strength",
      title: "Yesterday's strength",
      status: "in_progress",
      started_at_utc: "2026-08-13T10:59:59Z",
      local_timezone: "Europe/London",
    }], now);

    expect(overview.session).toBeNull();
    expect(overview.primary_action).toEqual(expect.objectContaining({
      kind: "create_session",
      label: "Plan a session",
    }));
  });

  it("keeps the last successful Overview response when a refresh fails", async () => {
    let failOverview = false;
    apiMock.mockImplementation(async (path) => {
      if (path === "/fitness/overview") {
        if (failOverview) throw new Error("refresh failed");
        return {
          date: "2026-08-02",
          session: { id: plan.id, kind: "planned_session", title: "Server session", sport_key: "strength", status: "accepted", starts_at: null, scheduled_date: "2026-08-02", duration_minutes: 60, movable: false },
          primary_action: { kind: "start_session", label: "Start", destination: "plan", target_id: plan.id },
          secondary_action: null, quick_actions: [], coach_nudge: null, safety_adjustment: null,
        } as never;
      }
      return [] as never;
    });
    const view = render(<FitnessTodayView {...props} />);
    expect(await screen.findByText("Server session")).toBeInTheDocument();

    failOverview = true;
    view.rerender(<FitnessTodayView {...props} revision={1} />);
    await waitFor(() => expect(apiMock.mock.calls.filter(([path]) => path === "/fitness/overview")).toHaveLength(2));
    expect(screen.getByText("Server session")).toBeInTheDocument();
    expect(screen.queryByRole("alert")).not.toBeInTheDocument();
  });

  it("orders Plan around the next session and defers unrelated detail", async () => {
    render(<FitnessTrainingView {...props} />);
    expect(await screen.findByRole("heading", { name: "What do you want to do?" })).toBeInTheDocument();
    expect(screen.getByText("Up next")).toBeInTheDocument();
    expect(screen.getByText("Seven days at a glance")).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "Run" })).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "Strength" })).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "Other" })).toBeInTheDocument();
    expect(screen.queryByRole("button", { name: "Walk" })).not.toBeInTheDocument();
    expect(screen.queryByRole("button", { name: "Ride" })).not.toBeInTheDocument();
    expect(screen.queryByText("Steady 5K")).not.toBeInTheDocument();
    expect(screen.queryByText("Daily trainers")).not.toBeInTheDocument();
    expect(apiMock.mock.calls.some(([path]) => path === "/fitness/gear" || path === "/fitness/body-issues")).toBe(false);
    fireEvent.click(screen.getByRole("button", { name: "Calendar" }));
    expect(props.onOpenCalendar).toHaveBeenCalled();
    const nextSessionCard = screen.getByText("Up next").closest("section");
    expect(nextSessionCard).not.toBeNull();
    fireEvent.click(within(nextSessionCard!).getByRole("button", { name: "Start" }));
    expect(props.onSectionChange).toHaveBeenCalledWith("strength");
    fireEvent.click(screen.getByRole("button", { name: "Other" }));
    expect(await screen.findByRole("option", { name: "Walk" })).toHaveValue("walking");
    expect(screen.getByRole("option", { name: "Ride" })).toHaveValue("cycling");
    expect(await screen.findByRole("option", { name: "Pool swimming" })).toHaveValue("swimming_pool");
  });

  it("reviews skip and cancellation before changing a planned outcome", async () => {
    render(<FitnessTrainingView {...props} />);
    fireEvent.click(await screen.findByRole("button", { name: "Move" }));
    expect(await screen.findByRole("heading", { name: "Manage Full body A" })).toBeInTheDocument();

    fireEvent.click(screen.getByRole("button", { name: "Skip" }));
    expect(saveMock).not.toHaveBeenCalled();
    expect(screen.getByRole("dialog", { name: "Skip this session?" })).toBeInTheDocument();
    fireEvent.click(screen.getByRole("button", { name: "Cancel" }));
    expect(screen.queryByRole("dialog", { name: "Skip this session?" })).not.toBeInTheDocument();

    fireEvent.click(screen.getByRole("button", { name: "Cancel session" }));
    const cancelDialog = screen.getByRole("dialog", { name: "Cancel this session?" });
    expect(cancelDialog).toBeInTheDocument();
    fireEvent.click(within(cancelDialog).getByRole("button", { name: "Cancel session" }));
    await waitFor(() => expect(saveMock).toHaveBeenCalledWith("planned_session", expect.objectContaining({ status: "cancelled" }), { entityId: plan.id, baseRevision: plan.revision }));
  });

  it("anchors Progress to the weekly review, selected goal trend, and activity history", async () => {
    render(<FitnessProgressView {...props} />);
    expect(await screen.findByText("A solid start")).toBeInTheDocument();
    expect(screen.getByRole("heading", { name: "Build durable strength" })).toBeInTheDocument();
    expect(screen.getByText("Weekly strength sessions")).toBeInTheDocument();
    expect(screen.getByText("Steady 5K")).toBeInTheDocument();
    expect(apiMock.mock.calls.some(([path]) => path === "/fitness/phases" || path === "/fitness/strength/sessions" || String(path).startsWith("/fitness/recovery/summary?") || path === "/fitness/analysis/registry")).toBe(false);
    expect(screen.queryByText(/overall fitness score/i)).not.toBeInTheDocument();
  });

  it("edits a manual measurement through the offline write path but keeps imported readings read-only", async () => {
    render(<FitnessProgressView {...props} />);
    fireEvent.click(await screen.findByRole("button", { name: /Body.*Measurements and trends/i }));
    fireEvent.click(await screen.findByRole("button", { name: "Edit Weight 78.2" }));

    expect(screen.getByRole("heading", { name: "Edit Weight" })).toBeInTheDocument();
    expect(screen.getByLabelText("Measurement")).toBeDisabled();
    expect(screen.queryByRole("button", { name: "Edit Weight 78.5" })).not.toBeInTheDocument();
    fireEvent.change(screen.getByLabelText("Value"), { target: { value: "78.1" } });
    fireEvent.click(screen.getByRole("button", { name: "Save changes" }));

    await waitFor(() => expect(saveMock).toHaveBeenCalledWith("body_measurement", expect.objectContaining({
      metric_key: "body.weight_kg",
      value: 78.1,
      canonical_state: "canonical",
    }), { entityId: "weight-1", baseRevision: 2 }));
  });

  it("puts current values and visible graph controls before recorded measurements", async () => {
    const view = render(<FitnessProgressView {...props} />);
    fireEvent.click(await screen.findByRole("button", { name: /Body.*Measurements and trends/i }));

    const current = await screen.findByRole("region", { name: "Current body measurements" });
    const trends = screen.getByRole("region", { name: "Trends" });
    const recorded = screen.getByRole("heading", { name: "Recorded measurements" }).closest("section")!;
    expect(within(current).getByText("Current weight")).toBeInTheDocument();
    expect(within(current).getByText("Current body fat")).toBeInTheDocument();
    const currentBmi = within(current).getByText("Current BMI").closest("article")!;
    expect(within(currentBmi).getByText("24.1")).toBeInTheDocument();
    expect(within(current).getByText("0.8 kg lower than a week ago")).toBeInTheDocument();
    expect(within(current).getByText("0.6 points lower than a week ago")).toBeInTheDocument();
    expect(within(current).getByText("0.2 points lower than a week ago")).toBeInTheDocument();
    expect(screen.getByRole("img", { name: /^Weight\./ })).toBeInTheDocument();
    expect(screen.getByRole("img", { name: /^Body fat\./ })).toBeInTheDocument();
    expect(screen.getByRole("img", { name: /^BMI\./ })).toBeInTheDocument();
    expect(current.compareDocumentPosition(trends) & Node.DOCUMENT_POSITION_FOLLOWING).toBeTruthy();
    expect(trends.compareDocumentPosition(recorded) & Node.DOCUMENT_POSITION_FOLLOWING).toBeTruthy();

    const detailedGraph = await screen.findByRole("heading", { name: "Detailed measurement graph" });
    expect(trends.compareDocumentPosition(detailedGraph) & Node.DOCUMENT_POSITION_FOLLOWING).toBeTruthy();
    expect(detailedGraph.compareDocumentPosition(recorded) & Node.DOCUMENT_POSITION_FOLLOWING).toBeTruthy();
    expect(screen.getByRole("radio", { name: "Smoothed" })).toBeChecked();
    expect(screen.getByRole("radio", { name: "Fit" })).toBeChecked();
    expect(screen.getByRole("radio", { name: "90 Days" })).toBeChecked();
    expect(await screen.findByRole("img", { name: /Weight smoothed chart with 3 readings and fit vertical scale/ })).toBeInTheDocument();

    fireEvent.click(screen.getByRole("radio", { name: "Raw" }));
    expect(new URLSearchParams(window.location.search).get("fitness-chart-display")).toBe("raw");
    expect(screen.getByRole("img", { name: /Weight raw chart/ })).toBeInTheDocument();
    fireEvent.click(screen.getByRole("radio", { name: "Wide" }));
    expect(new URLSearchParams(window.location.search).get("fitness-chart-scale")).toBe("wide");
    expect(screen.getByRole("img", { name: /wide vertical scale/ })).toBeInTheDocument();
    fireEvent.click(screen.getByRole("radio", { name: "30 Days" }));
    expect(new URLSearchParams(window.location.search).get("fitness-chart-range")).toBe("30d");
    expect(screen.getByRole("button", { name: "Zoom out" })).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "Zoom in" })).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "Reset" })).toBeInTheDocument();

    view.unmount();
    render(<FitnessProgressView {...props} />);
    expect(await screen.findByRole("radio", { name: "Raw" })).toBeChecked();
    expect(screen.getByRole("radio", { name: "Wide" })).toBeChecked();
    expect(screen.getByRole("radio", { name: "30 Days" })).toBeChecked();

    expect(screen.queryByText(/When two connections add the same reading/i)).not.toBeInTheDocument();
    expect(screen.queryByText("Connection unavailable")).not.toBeInTheDocument();
    expect(screen.queryByText("Chosen for trend")).not.toBeInTheDocument();
    expect(apiMock.mock.calls.some(([path]) => path === "/fitness/source-priorities")).toBe(false);
  });

  it("does not describe an old measurement as a reading from a week ago", async () => {
    const defaultImplementation = apiMock.getMockImplementation();
    apiMock.mockImplementation(async (path, ...args) => {
      if (path === "/fitness/body/measurements") return [
        { id: "weight-old", revision: 1, metric_key: "body.weight_kg", measured_at_utc: "2026-05-01T07:00:00Z", local_timezone: "Europe/Berlin", value: 81, unit_key: "kg", canonical_state: "canonical", measurement_quality: "measured" },
        { id: "weight-latest", revision: 1, metric_key: "body.weight_kg", measured_at_utc: "2026-08-01T07:00:00Z", local_timezone: "Europe/Berlin", value: 78, unit_key: "kg", canonical_state: "canonical", measurement_quality: "measured" },
      ] as never;
      return defaultImplementation?.(path, ...args) ?? [] as never;
    });

    render(<FitnessProgressView {...props} />);
    fireEvent.click(await screen.findByRole("button", { name: /Body.*Measurements and trends/i }));

    const current = await screen.findByRole("region", { name: "Current body measurements" });
    expect(within(current).getByText("78")).toBeInTheDocument();
    expect(within(current).queryByText(/week ago|week of readings/i)).not.toBeInTheDocument();
  });
});
