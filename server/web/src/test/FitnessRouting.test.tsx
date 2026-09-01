import { fireEvent, render, screen, waitFor, within } from "@testing-library/react";
import { format } from "date-fns";
import { beforeEach, describe, expect, it, vi } from "vitest";

import App, { readLocation } from "../App";
import { api } from "../api";
import { flushFitnessNutritionLabels } from "../fitness/offlineStore";

vi.mock("../AuthContext", () => ({
  useAuth: () => ({
    user: {
      id: "dom",
      name: "Alex",
      email: "dom@example.invalid",
      role: "admin",
      priority: 5,
      family_id: "family",
    },
    loading: false,
    signOut: vi.fn(),
    updateUser: vi.fn(),
  }),
}));

vi.mock("../api", () => ({
  api: vi.fn(),
  ApiError: class ApiError extends Error {
    status: number;
    constructor(message: string, status: number) { super(message); this.status = status; }
  },
  flushOfflineQueue: vi.fn().mockResolvedValue(undefined),
  offlineQueueSummary: vi.fn().mockResolvedValue({ pending: 0, failed: 0, held: 0 }),
}));

vi.mock("../offlineQueue", () => ({
  heldQueuedMutations: vi.fn().mockResolvedValue([]),
  queuedMutations: vi.fn().mockResolvedValue([]),
  removeQueuedMutation: vi.fn().mockResolvedValue(undefined),
}));

vi.mock("../fitness/offlineStore", () => ({
  cacheFitnessFoodLogDay: vi.fn().mockResolvedValue(undefined),
  cacheFitnessRecords: vi.fn().mockResolvedValue(undefined),
  cacheFitnessProgressCharts: vi.fn().mockResolvedValue(undefined),
  cachedFitnessFoodLogDay: vi.fn().mockResolvedValue(null),
  cachedFitnessRecords: vi.fn().mockResolvedValue([]),
  cachedFitnessProgressCharts: vi.fn().mockResolvedValue(null),
  fitnessSyncSummary: vi.fn().mockResolvedValue({ pending: 0, failed: 0, compatibilityBlocked: false, compatibilityMessage: null, lastSyncedAt: null }),
  fitnessNotices: vi.fn().mockResolvedValue([]),
  dismissFitnessNotice: vi.fn().mockResolvedValue(undefined),
  flushFitnessSync: vi.fn().mockResolvedValue(null),
  flushFitnessFitImports: vi.fn().mockResolvedValue([]),
  flushFitnessProgressPhotos: vi.fn().mockResolvedValue([]),
  flushFitnessPlannedMealLogs: vi.fn().mockResolvedValue([]),
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
const flushNutritionLabelsMock = vi.mocked(flushFitnessNutritionLabels);

function todayDashboard() {
  return {
    generated_at: new Date().toISOString(), date: format(new Date(), "yyyy-MM-dd"),
    events: [], tasks: [], naps: [], illnesses: [], routines: [], meals: [], dog: null,
    coordination: null, memories: [], insights: [], prep_suggestions: [], medicine: [],
    birthdays: [], weather: null, unavailable: [], finance_action: null,
  };
}

describe("Fitness query routing", () => {
  beforeEach(() => {
    window.history.replaceState({}, "", "/?view=today");
    window.localStorage.clear();
    window.scrollTo = vi.fn();
    apiMock.mockReset();
    flushNutritionLabelsMock.mockClear();
    apiMock.mockImplementation(async (path) => {
      if (path === "/fitness/workspace") return { enabled: true, pinned: true };
      if (path === "/family/members") return [];
      if (path.startsWith("/briefing/dashboard")) return todayDashboard();
      if (path === "/fitness/today-card") return null;
      if (path === "/fitness/overview") return { date: "2026-08-02", session: null, primary_action: { kind: "create_session", label: "Plan a session", destination: "plan", target_id: null }, secondary_action: null, quick_actions: [], coach_nudge: null, safety_adjustment: null };
      if (path === "/fitness/onboarding") return { id: "setup", status: "complete", main_outcome: "Feel fitter", availability: [], activities: [], equipment: [], food_preferences: [], source_connections: [], coach_style: "Balanced and practical", use_family_calendar: false, use_household_meals: false, use_weather: false, memory_enabled: false, preview: null, confirmation: null };
      if (path === "/fitness/foods") return [];
      if (path.startsWith("/fitness/food-log?date=")) return { entries: [], totals: {}, measured_share: null };
      return [];
    });
  });

  it("keeps every legacy Fitness URL exact while selecting its current screen", () => {
    const aliases = [
      ["today", "today"], ["more", "today"], ["overview", "progress"], ["nutrition", "nutrition"], ["log", "nutrition"],
      ["training", "training"], ["plan", "training"], ["runPlans", "training"], ["strength", "strength"],
      ["activity", "activity"], ["progress", "progress"], ["measurements", "progress"], ["photos", "progress"],
      ["recovery", "recovery"], ["explore", "explore"], ["analysis", "explore"], ["coach", "coach"],
    ] as const;
    for (const [section, expected] of aliases) {
      window.history.replaceState({}, "", `/?view=fitness&section=${section}&focus=kept`);
      expect(readLocation()).toMatchObject({ view: "fitness", fitness: expected });
      expect(new URLSearchParams(window.location.search).get("section")).toBe(section);
    }
  });

  it("opens Fitness directly from the five-item mobile navigation and loads sections lazily", async () => {
    render(<App />);
    const mobileNavigation = screen.getAllByRole("navigation", { name: "Main navigation" })[1];
    await waitFor(() => expect(within(mobileNavigation).getAllByRole("button")).toHaveLength(5));
    fireEvent.click(within(mobileNavigation).getByRole("button", { name: "Fitness" }));

    expect(await screen.findByRole("heading", { name: "Fitness", level: 1 }, { timeout: 5_000 })).toBeInTheDocument();
    await waitFor(() => expect(flushNutritionLabelsMock).toHaveBeenCalled());
    expect(await screen.findByRole("heading", { name: "Review", level: 2 })).toBeInTheDocument();
    expect(new URLSearchParams(window.location.search).get("view")).toBe("fitness");
    expect(apiMock).not.toHaveBeenCalledWith("/fitness/foods", expect.anything(), expect.anything(), expect.anything());

    fireEvent.click(within(screen.getByRole("navigation", { name: "Fitness sections" })).getByRole("button", { name: "Food" }));
    expect(await screen.findByRole("heading", { name: "Log", level: 2 })).toBeInTheDocument();
    await waitFor(() => expect(apiMock).toHaveBeenCalledWith(
      "/fitness/foods",
      { signal: expect.any(AbortSignal) },
      true,
      false,
    ));
    expect(new URLSearchParams(window.location.search).get("section")).toBe("nutrition");
  });

  it("hides unpinned Fitness from primary navigation but keeps the enabled workspace reachable", async () => {
    apiMock.mockImplementation(async (path) => {
      if (path === "/fitness/workspace") return { enabled: true, pinned: false };
      if (path === "/family/members") return [];
      if (path.startsWith("/briefing/dashboard")) return todayDashboard();
      if (path === "/fitness/onboarding") return { id: "setup", status: "complete", main_outcome: "Move consistently", availability: [], activities: [], equipment: [], food_preferences: [], source_connections: [], coach_style: null, use_family_calendar: false, use_household_meals: false, use_weather: false, memory_enabled: false, preview: null, confirmation: null };
      if (path === "/fitness/overview") return { date: "2026-08-02", focus: { outcome: "Move consistently", label: "Movement this week", value: "2 active days this week", detail: null, destination: "progress" }, session: null, primary_action: { kind: "create_session", label: "Plan a session", destination: "plan", target_id: null }, secondary_action: null, quick_actions: [], coach_nudge: null, safety_adjustment: null };
      return [];
    });

    render(<App />);
    await waitFor(() => expect(apiMock).toHaveBeenCalledWith("/fitness/workspace", {}, true, false));
    const navigations = screen.getAllByRole("navigation", { name: "Main navigation" });
    expect(navigations.every((navigation) => within(navigation).queryByRole("button", { name: "Fitness" }) === null)).toBe(true);

    fireEvent.click(screen.getByRole("button", { name: "More navigation and appearance" }));
    fireEvent.click(await screen.findByRole("button", { name: /Fitness/ }));
    expect(await screen.findByRole("heading", { name: "Fitness", level: 1 })).toBeInTheDocument();
  });

  it("routes a Today strength Start to the exact prefilled session", async () => {
    const today = format(new Date(), "yyyy-MM-dd");
    apiMock.mockImplementation(async (path) => {
      if (path === "/fitness/workspace") return { enabled: true, pinned: true };
      if (path === "/family/members") return [];
      if (path.startsWith("/briefing/dashboard")) return todayDashboard();
      if (path === "/fitness/today-card") return {
        date: today,
        session: {
          id: "strength-plan-1", kind: "planned_session", title: "Full body",
          sport_key: "strength", status: "accepted", starts_at: null,
          scheduled_date: today, duration_minutes: 40, movable: true,
        },
        primary_action: { kind: "start_session", label: "Start", destination: "plan", target_id: "strength-plan-1" },
        secondary_action: { kind: "move_session", label: "Move", destination: "plan", target_id: "strength-plan-1" },
      };
      return [];
    });

    render(<App />);
    fireEvent.click(await screen.findByRole("button", { name: "Start" }));

    const query = new URLSearchParams(window.location.search);
    expect(query.get("view")).toBe("fitness");
    expect(query.get("section")).toBe("strength");
    expect(query.get("fitness-strength-start")).toBe("strength-plan-1");
    expect(query.get("session")).toBeNull();
  });

  it("routes an empty Today fitness card to an immediate blank strength start", async () => {
    const today = format(new Date(), "yyyy-MM-dd");
    apiMock.mockImplementation(async (path) => {
      if (path === "/fitness/workspace") return { enabled: true, pinned: true };
      if (path === "/family/members") return [];
      if (path.startsWith("/briefing/dashboard")) return todayDashboard();
      if (path === "/fitness/today-card") return {
        date: today,
        has_completed_activity_today: false,
        session: null,
        primary_action: { kind: "start_strength", label: "Start workout", destination: "plan", target_id: null },
        secondary_action: null,
        nutrition: null,
      };
      return [];
    });

    render(<App />);
    fireEvent.click(await screen.findByRole("button", { name: "Start workout" }));

    const query = new URLSearchParams(window.location.search);
    expect(query.get("view")).toBe("fitness");
    expect(query.get("section")).toBe("strength");
    expect(query.get("fitness-strength-start")).toBe("blank");
    expect(query.get("session")).toBeNull();
  });

  it("routes a Today Move action to the exact planned-session editor", async () => {
    const today = format(new Date(), "yyyy-MM-dd");
    apiMock.mockImplementation(async (path) => {
      if (path === "/fitness/workspace") return { enabled: true, pinned: true };
      if (path === "/family/members") return [];
      if (path.startsWith("/briefing/dashboard")) return todayDashboard();
      if (path === "/fitness/today-card") return {
        date: today,
        session: {
          id: "run-plan-1", kind: "planned_session", title: "Easy run",
          sport_key: "running", status: "accepted", starts_at: null,
          scheduled_date: today, duration_minutes: 35, movable: true,
        },
        primary_action: { kind: "open_session", label: "Open", destination: "plan", target_id: "run-plan-1" },
        secondary_action: { kind: "move_session", label: "Move", destination: "plan", target_id: "run-plan-1" },
      };
      return [];
    });

    render(<App />);
    fireEvent.click(await screen.findByRole("button", { name: "Move" }));

    const query = new URLSearchParams(window.location.search);
    expect(query.get("view")).toBe("fitness");
    expect(query.get("section")).toBe("training");
    expect(query.get("session")).toBe("run-plan-1");
    expect(query.get("fitness-strength-start")).toBeNull();
  });
});
