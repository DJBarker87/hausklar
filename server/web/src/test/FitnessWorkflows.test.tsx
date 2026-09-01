import { fireEvent, render, screen, waitFor } from "@testing-library/react";
import { beforeEach, describe, expect, it, vi } from "vitest";

import { api } from "../api";
import { saveFitnessRecord } from "../fitness/offlineStore";
import { FitnessNutritionView } from "../views/fitness/FitnessNutritionView";
import { FitnessRecoveryView } from "../views/fitness/FitnessRecoveryView";
import { FitnessTodayView } from "../views/fitness/FitnessTodayView";
import { FitnessTrainingView } from "../views/fitness/FitnessTrainingView";

vi.mock("../api", () => ({
  api: vi.fn(),
  ApiError: class ApiError extends Error {
    status: number;
    constructor(message: string, status: number) { super(message); this.status = status; }
  },
}));

vi.mock("../fitness/offlineStore", () => ({
  cacheFitnessRecords: vi.fn().mockResolvedValue(undefined),
  cacheFitnessFoodLogDay: vi.fn().mockResolvedValue(undefined),
  cachedFitnessFoodLogDay: vi.fn().mockResolvedValue(null),
  cachedFitnessRecords: vi.fn().mockResolvedValue([]),
  saveFitnessRecord: vi.fn(),
  saveFitnessRecords: vi.fn(),
  deleteFitnessRecord: vi.fn().mockResolvedValue(undefined),
  fitnessNutritionLabelsOnDevice: vi.fn().mockResolvedValue([]),
  flushFitnessNutritionLabels: vi.fn().mockResolvedValue([]),
  queueFitnessNutritionLabel: vi.fn(),
  retryFitnessNutritionLabel: vi.fn().mockResolvedValue(undefined),
  cacheFitnessPlannedMeals: vi.fn().mockResolvedValue(undefined),
  cachedFitnessPlannedMeals: vi.fn().mockResolvedValue([]),
  fitnessLogUndo: vi.fn().mockResolvedValue(null),
  rememberFitnessLogUndo: vi.fn().mockResolvedValue(undefined),
  removeFitnessPlannedMealLogFromDevice: vi.fn().mockResolvedValue(false),
  saveFitnessPlannedMealLog: vi.fn(),
}));

const apiMock = vi.mocked(api);
const saveMock = vi.mocked(saveFitnessRecord);
const props = {
  online: true,
  revision: 0,
  onDataChanged: vi.fn(),
  onSectionChange: vi.fn(),
};

const exercise = {
  id: "00000000-0000-4000-8000-000000000801",
  name: "Back squat",
  active: true,
};
const substitutionExercise = {
  id: "00000000-0000-4000-8000-000000000805",
  name: "Front squat",
  active: true,
};
const setup = {
  id: "00000000-0000-4000-8000-000000000802",
  exercise_id: exercise.id,
  name: "Home rack",
  is_default: true,
  active: true,
};
const food = {
  id: "00000000-0000-4000-8000-000000000803",
  name: "Greek yoghurt",
  active: true,
  current_version: {
    id: "00000000-0000-4000-8000-000000000804",
    reference_amount: 100,
    reference_unit: "g",
    calories_kcal: 97,
    protein_g: 9,
  },
};

describe("Fitness core create workflows", () => {
  beforeEach(() => {
    props.onDataChanged.mockReset();
    props.onSectionChange.mockReset();
    apiMock.mockReset();
    apiMock.mockImplementation(async (path) => {
      if (path === "/fitness/overview") return { date: "2026-08-02", session: null, primary_action: { kind: "create_session", label: "Plan a session", destination: "plan", target_id: null }, secondary_action: null, quick_actions: [{ kind: "log_food", label: "Log food", destination: "log", target_id: null }], coach_nudge: null, safety_adjustment: null };
      if (path === "/fitness/today") return { active_goals: [], planned_sessions: [] };
      if (path === "/fitness/body/measurements?metric_key=body.weight_kg") return [];
      if (path === "/fitness/goals") return [];
      if (path === "/fitness/phases") return [];
      if (path === "/fitness/planned-sessions") return [];
      if (path === "/fitness/training-programmes") return [];
      if (path === "/fitness/integrations/strava/status") return { configured: false, connected: false, status: "not_configured", imported_activity_count: 0 };
      if (path === "/fitness/activity-registry") return { sports: [{ key: "strength", display_name: "Strength" }, { key: "running", display_name: "Running" }], metrics: [] };
      if (path === "/fitness/exercises") return [exercise, substitutionExercise];
      if (path === "/fitness/exercise-setups") return [setup];
      if (path === "/fitness/foods") return [food];
      if (path.startsWith("/fitness/food-log?date=")) return { entries: [], totals: {} };
      if (path === "/fitness/session-checkins" || path === "/fitness/body-issues") return [];
      if (path.startsWith("/fitness/sleep/sessions?")) return [];
      if (path.startsWith("/fitness/recovery/observations?")) return [];
      if (path.startsWith("/fitness/recovery/summary?")) return {
        window: { from_date: "2026-07-06", to_date: "2026-08-02", expected_days: 28, days_with_sleep: 0 },
        sleep: {},
        baselines: [],
        relationships: [],
      };
      throw new Error(`Unexpected Fitness request: ${path}`);
    });
    saveMock.mockReset();
    saveMock.mockImplementation(async (_entityType, payload, options) => ({
      ...payload,
      id: options?.entityId ?? crypto.randomUUID(),
      queued_offline: true,
    }));
    Object.defineProperty(window.navigator, "onLine", { configurable: true, value: true });
  });

  it("keeps Overview on the compact endpoint and sends planning to Plan", async () => {
    render(<FitnessTodayView {...props} />);
    fireEvent.click(await screen.findByRole("button", { name: "Plan a session" }));
    expect(props.onSectionChange).toHaveBeenCalledWith("training");
    expect(apiMock).toHaveBeenCalledWith(
      "/fitness/overview",
      { signal: expect.any(AbortSignal) },
      true,
      false,
    );
    expect(apiMock).not.toHaveBeenCalledWith("/fitness/today", expect.anything(), expect.anything(), expect.anything());
    expect(apiMock).not.toHaveBeenCalledWith("/fitness/goals", expect.anything(), expect.anything(), expect.anything());
  });

  it("creates an immutable food version and logs a synced version", async () => {
    render(<FitnessNutritionView {...props} />);
    fireEvent.change(await screen.findByRole("searchbox", { name: "Search foods" }), { target: { value: "Oats" } });
    fireEvent.click(screen.getByRole("button", { name: "Add it manually" }));
    fireEvent.change(await screen.findByLabelText("Food name"), { target: { value: "Oats" } });
    fireEvent.change(screen.getByLabelText("Calories (kcal)"), { target: { value: "370" } });
    fireEvent.change(screen.getByLabelText("Protein (g)"), { target: { value: "12" } });
    fireEvent.click(screen.getByRole("button", { name: "Save food" }));
    await waitFor(() => expect(saveMock).toHaveBeenCalledWith("food", expect.objectContaining({
      name: "Oats",
      version: expect.objectContaining({
        id: expect.any(String),
        reference_amount: 100,
        calories_kcal: 370,
        protein_g: 12,
      }),
    }), expect.objectContaining({ entityId: expect.any(String) })));

    fireEvent.click(screen.getByRole("button", { name: "Back to Log" }));
    fireEvent.change(await screen.findByRole("searchbox", { name: "Search foods" }), { target: { value: "Greek yoghurt" } });
    fireEvent.click(await screen.findByRole("button", { name: /Greek yoghurt/i }));
    fireEvent.change(screen.getByLabelText("Amount"), { target: { value: "150" } });
    fireEvent.click(screen.getByRole("button", { name: /^Add to / }));
    await waitFor(() => expect(saveMock).toHaveBeenCalledWith("food_log_entry", expect.objectContaining({
      food_version_id: food.current_version.id,
      entered_amount: 150,
      canonical_amount: 150,
      measurement_quality: "estimated",
    }), { entityId: expect.any(String), baseRevision: null }));
  });

  it("starts with Run and saves a useful session without demanding admin fields", async () => {
    render(<FitnessTrainingView {...props} />);
    fireEvent.click(await screen.findByRole("button", { name: "Run" }));
    expect(screen.getByRole("radio", { name: /Now.*I’m about to do it/i })).toBeChecked();
    fireEvent.change(screen.getByLabelText(/Distance/), { target: { value: "5" } });
    fireEvent.click(screen.getByRole("button", { name: "Target pace" }));
    const pace = screen.getByRole("group", { name: "Target pace" });
    fireEvent.change(pace.querySelectorAll("input")[0], { target: { value: "5" } });
    fireEvent.change(pace.querySelectorAll("input")[1], { target: { value: "0" } });
    fireEvent.click(screen.getByRole("button", { name: "Add run for now" }));

    await waitFor(() => expect(saveMock).toHaveBeenCalledWith("planned_session", expect.objectContaining({
      title: "Run",
      sport_key: "running",
      status: "accepted",
      expected_distance_m: 5_000,
      expected_duration_s: 1_500,
      expected_pace_s_per_km: 300,
      goal_links: [],
    }), expect.objectContaining({ entityId: expect.any(String) })));
    expect(apiMock.mock.calls.some(([path]) => path === "/fitness/goals" || path === "/fitness/exercises")).toBe(false);
  });

  it("uses the same Run flow to log something already completed", async () => {
    render(<FitnessTrainingView {...props} />);
    fireEvent.click(await screen.findByRole("button", { name: "Run" }));
    fireEvent.click(screen.getByRole("radio", { name: /Done.*I already did it/i }));
    fireEvent.change(screen.getByLabelText(/Minutes/), { target: { value: "42" } });
    fireEvent.change(screen.getByLabelText(/Distance/), { target: { value: "7.2" } });
    fireEvent.click(screen.getByRole("button", { name: "Log run" }));

    await waitFor(() => expect(saveMock).toHaveBeenCalledWith("manual_activity", expect.objectContaining({
      sport_key: "running",
      duration_s: 2_520,
      distance_m: 7_200,
      estimate_energy: true,
    }), expect.objectContaining({ entityId: expect.any(String) })));
  });

  it("opens the strength workout flow in one tap", async () => {
    render(<FitnessTrainingView {...props} />);
    fireEvent.click(await screen.findByRole("button", { name: "Strength" }));

    expect(props.onSectionChange).toHaveBeenCalledWith("strength");
    expect(screen.queryByRole("button", { name: "Open strength workouts" })).not.toBeInTheDocument();
  });

  it("pulls completed sessions from Strava in one tap after connection", async () => {
    apiMock.mockImplementation(async (path, init) => {
      if (path === "/fitness/planned-sessions" || path === "/fitness/training-programmes") return [] as never;
      if (path === "/fitness/integrations/strava/status") return { configured: true, connected: true, status: "connected", athlete_name: "Alex Runner", imported_activity_count: 4 } as never;
      if (path === "/fitness/integrations/strava/sync" && init?.method === "POST") return {
        imported_count: 1, updated_count: 0, unchanged_count: 4,
        latest_activity: { id: "run-5", title: "Morning run", sport_key: "running", started_at_utc: "2026-08-10T06:00:00Z", duration_s: 1_500, distance_m: 5_000 },
        status: { configured: true, connected: true, status: "connected", athlete_name: "Alex Runner", imported_activity_count: 5 },
      } as never;
      throw new Error(`Unexpected Fitness request: ${path}`);
    });
    render(<FitnessTrainingView {...props} />);
    fireEvent.click(await screen.findByRole("button", { name: "Pull latest from Strava" }));
    expect(await screen.findByText("1 session brought in from Strava.")).toBeInTheDocument();
    expect(apiMock).toHaveBeenCalledWith("/fitness/integrations/strava/sync", { method: "POST" }, true, false);
    expect(props.onDataChanged).toHaveBeenCalled();
  });

  it("retries a temporary Strava outage without asking for OAuth again", async () => {
    apiMock.mockImplementation(async (path, init) => {
      if (path === "/fitness/planned-sessions" || path === "/fitness/training-programmes") return [] as never;
      if (path === "/fitness/integrations/strava/status") return { configured: true, connected: true, status: "provider_down", athlete_name: "Alex Runner", imported_activity_count: 4 } as never;
      if (path === "/fitness/integrations/strava/sync" && init?.method === "POST") return {
        imported_count: 0, updated_count: 0, unchanged_count: 4, latest_activity: null,
        status: { configured: true, connected: true, status: "connected", athlete_name: "Alex Runner", imported_activity_count: 4 },
      } as never;
      throw new Error(`Unexpected Fitness request: ${path}`);
    });

    render(<FitnessTrainingView {...props} />);
    fireEvent.click(await screen.findByRole("button", { name: "Try Strava again" }));
    expect(await screen.findByText("Everything from Strava is already here.")).toBeInTheDocument();
    expect(apiMock).toHaveBeenCalledWith("/fitness/integrations/strava/sync", { method: "POST" }, true, false);
    expect(apiMock.mock.calls.some(([path]) => path === "/fitness/integrations/strava/start")).toBe(false);
  });

  it("records a contemporaneous one-tap readiness check-in", async () => {
    render(<FitnessRecoveryView {...props} />);
    fireEvent.click(screen.getByRole("button", { name: "Readiness 5, Excellent" }));
    fireEvent.click(screen.getByRole("button", { name: "Save readiness" }));

    await waitFor(() => expect(saveMock).toHaveBeenCalledWith("session_checkin", expect.objectContaining({
      timing: "pre",
      capture_quality: "contemporaneous",
      readiness_1_5: 5,
      captured_before_activity_start: true,
    }), undefined));
  });
});
