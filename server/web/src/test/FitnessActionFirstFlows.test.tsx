import { fireEvent, render, screen, waitFor } from "@testing-library/react";
import { beforeEach, describe, expect, it, vi } from "vitest";

import { api } from "../api";
import { currentOfflineQueueOwner } from "../offlineQueue";
import { deleteFitnessRecord, saveFitnessRecord } from "../fitness/offlineStore";
import { FitnessCoachView } from "../views/fitness/FitnessCoachView";
import {
  FitnessBarcodeScanner,
  FitnessFoodCataloguePanel,
  FitnessNutritionDiaryPanel,
} from "../views/fitness/FitnessNutritionPanels";
import { FitnessRecoveryView } from "../views/fitness/FitnessRecoveryView";
import { FitnessTodayView } from "../views/fitness/FitnessTodayView";

vi.mock("../api", () => ({
  api: vi.fn(),
  ApiError: class ApiError extends Error {
    status: number;
    constructor(message: string, status: number) { super(message); this.status = status; }
  },
}));

vi.mock("../offlineQueue", () => ({ currentOfflineQueueOwner: vi.fn() }));

vi.mock("../fitness/offlineStore", () => ({
  cacheFitnessFoodLogDay: vi.fn().mockResolvedValue(undefined),
  cacheFitnessRecords: vi.fn().mockResolvedValue(undefined),
  cachedFitnessFoodLogDay: vi.fn().mockResolvedValue(null),
  cachedFitnessRecords: vi.fn().mockResolvedValue([]),
  deleteFitnessRecord: vi.fn().mockResolvedValue(undefined),
  fitnessNutritionLabelsOnDevice: vi.fn().mockResolvedValue([]),
  flushFitnessNutritionLabels: vi.fn().mockResolvedValue([]),
  queueFitnessNutritionLabel: vi.fn(),
  retryFitnessNutritionLabel: vi.fn().mockResolvedValue(undefined),
  saveFitnessRecord: vi.fn(),
  saveFitnessRecords: vi.fn().mockResolvedValue([]),
}));

const apiMock = vi.mocked(api);
const ownerMock = vi.mocked(currentOfflineQueueOwner);
const saveMock = vi.mocked(saveFitnessRecord);
const deleteMock = vi.mocked(deleteFitnessRecord);
const onSectionChange = vi.fn();
const onDataChanged = vi.fn();
const commonProps = { online: true, revision: 0, onSectionChange, onDataChanged };

const nextAction = {
  title: "Keep today deliberately light",
  body: "Your current evidence supports a lower-load day.",
  urgency: "attention" as const,
  evidence: [{ id: "evidence-1", kind: "recovery", label: "Recent recovery", summary: "Below your own baseline." }],
  action: { kind: "open_today" as const, target: "today", label: "Open today" },
  secondary_action: null,
  expires_at: "2099-08-03T23:59:59Z",
  source: "next-action:body-issue:raw-record-uuid",
};
const initialNextActionBody = nextAction.body;

const porridge = {
  id: "food-1",
  revision: 1,
  name: "Porridge",
  favourite: true,
  active: true,
  quick_use: { usual_amount: 1, usual_unit: "bowl" },
  current_version: { id: "food-version-1", reference_amount: 100, reference_unit: "g", calories_kcal: 200, protein_g: 10 },
  versions: [{ id: "food-version-1", reference_amount: 100, reference_unit: "g", calories_kcal: 200, protein_g: 10 }],
  servings: [{ id: "serving-1", name: "one bowl", amount: 1, unit: "bowl", canonical_amount: 240, canonical_unit: "g", measurement_quality: "standard_serving", active: true }],
};

let coachMessage: Record<string, unknown> | null = null;
let confirmDecision: Record<string, unknown> | null = null;
let recoverySummary: Record<string, unknown> = {};

function installApi() {
  apiMock.mockImplementation(async (path, init) => {
    const requestPath = String(path);
    if (requestPath === "/fitness/overview") return {
      date: "2026-08-03", session: null,
      focus: { outcome: "Build strength", label: "Strength this week", value: "2 sessions this week", detail: "Work supporting your strength goal.", destination: "progress" },
      primary_action: { kind: "create_session", label: "Plan a session", destination: "plan", target_id: null },
      secondary_action: null,
      quick_actions: [],
      coach_nudge: { title: nextAction.title, message: nextAction.body, action: { kind: "open_coach", label: "Ask Coach", destination: "coach", target_id: null } },
      safety_adjustment: null,
    } as never;
    if (requestPath === "/fitness/today") return { date: "2026-08-03", next_action: nextAction, planned_sessions: [] } as never;
    if (["/fitness/goals", "/fitness/goal-relationships", "/fitness/gear", "/fitness/session-checkins", "/fitness/planned-sessions", "/fitness/recipes", "/fitness/meal-templates", "/fitness/nutrition/targets", "/fitness/phases", "/fitness/body-issues", "/fitness/body-locations", "/fitness/cycles"].includes(requestPath)) return [] as never;
    if (requestPath === "/fitness/foods") return [porridge] as never;
    if (requestPath.startsWith("/fitness/food-log?")) return { nutrition_date: "2026-08-03", entries: [], totals: {}, measured_share: null } as never;
    if (requestPath === "/fitness/body/weight-trend") return {} as never;
    if (requestPath === "/fitness/body/measurements?metric_key=body.weight_kg") return [
      { id: "weight-1", metric_key: "body.weight_kg", measured_at_utc: "2026-07-27T07:00:00Z", local_timezone: "Europe/London", value: 81.2, unit_key: "kg", canonical_state: "canonical" },
      { id: "weight-2", metric_key: "body.weight_kg", measured_at_utc: "2026-08-03T07:00:00Z", local_timezone: "Europe/London", value: 80.6, unit_key: "kg", canonical_state: "canonical" },
    ] as never;
    if (requestPath.startsWith("/fitness/recovery/summary?")) return recoverySummary as never;
    if (requestPath.startsWith("/fitness/sleep/sessions?") || requestPath.startsWith("/fitness/recovery/observations?")) return [] as never;
    if (requestPath === "/fitness/nutrition/settings") return { id: "nutrition-settings", timezone: "Europe/Berlin", nutrition_day_start_minutes: 240 } as never;
    if (requestPath.startsWith("/fitness/nutrition/analysis?")) return { start: "2026-07-07", end: "2026-08-03", sample_days: 0, calendar_days: 28, completeness: 0, contributors: [], recommendation: null } as never;
    if (requestPath === "/auth/ai-consent") return { consented: true, version: "2026-07-13", provider: "OpenAI", disclosure: "Explicit messages only.", background_processing: false } as never;
    if (requestPath === "/fitness/coach/status") return { status: "available", provider: "openai", model: "gpt-health", intents: ["discussion"] } as never;
    if (requestPath === "/fitness/coach/recommendations") return [] as never;
    if (requestPath === "/fitness/coach/message" && init?.method === "POST") return coachMessage as never;
    if (requestPath.endsWith("/confirm") && init?.method === "POST") return confirmDecision as never;
    if (requestPath.endsWith("/undo") && init?.method === "POST") return { status: "undone", message: "The confirmed records were undone.", affected_ids: ["session-a", "session-b"] } as never;
    if (requestPath === "/fitness/food-lookup/barcode/12345678") return {
      barcode: "12345678",
      name: "Live yoghurt",
      brand: "Example Dairy",
      reference_amount: 100,
      reference_unit: "g",
      nutrients: { calories_kcal: 72, protein_g: 5.2, carbohydrate_g: 8, sugars_g: 7.5, fat_g: 2, saturated_fat_g: 1.2, fibre_g: 0, salt_g: 0.1 },
      serving: { name: "pot", amount: 150, unit: "g" },
      source: "open_food_facts",
      source_url: "https://world.openfoodfacts.org/product/12345678",
      warnings: ["Check the package against these copied values."],
      needs_review: true,
    } as never;
    throw new Error(`Unexpected request: ${requestPath}`);
  });
}

describe("Fitness action-first flows", () => {
  beforeEach(() => {
    window.history.replaceState({}, "", "/?view=fitness&section=today");
    window.localStorage.clear();
    onSectionChange.mockReset();
    onDataChanged.mockReset();
    apiMock.mockReset();
    saveMock.mockReset();
    deleteMock.mockReset();
    ownerMock.mockReturnValue({ familyId: "family-a", userId: "user-a" } as never);
    saveMock.mockResolvedValue({ id: "saved-record", revision: 1 } as never);
    deleteMock.mockResolvedValue(undefined);
    coachMessage = null;
    confirmDecision = null;
    nextAction.body = initialNextActionBody;
    recoverySummary = { window: { from_date: "2026-07-27", to_date: "2026-08-03", expected_days: 8, days_with_sleep: 0 }, sleep: {}, baselines: [], relationships: [] };
    Object.defineProperty(window.navigator, "onLine", { configurable: true, value: true });
    Object.defineProperty(HTMLElement.prototype, "scrollIntoView", { configurable: true, value: vi.fn() });
    installApi();
  });

  it("shows at most one compact nudge on Overview without internal evidence or dismissal plumbing", async () => {
    const today = render(<FitnessTodayView {...commonProps} />);
    expect(await screen.findByText(nextAction.title)).toBeInTheDocument();
    expect(screen.getAllByText(nextAction.body)).toHaveLength(1);
    expect(screen.queryByText("Recent recovery")).not.toBeInTheDocument();
    expect(screen.queryByText("Why this?")).not.toBeInTheDocument();
    expect(screen.queryByRole("button", { name: "Dismiss" })).not.toBeInTheDocument();
    fireEvent.click(screen.getByRole("button", { name: "Ask Coach" }));
    expect(onSectionChange).toHaveBeenCalledWith("coach");
    today.unmount();

    render(<FitnessCoachView {...commonProps} />);
    expect(await screen.findByText("Ask Coach")).toBeInTheDocument();
    expect(screen.queryByText(nextAction.title)).not.toBeInTheDocument();
    expect(screen.queryByText("The same current recommendation shown on Today.")).not.toBeInTheDocument();
  });

  it("shows a goal-shaped fact and opens real connection setup in context", async () => {
    render(<FitnessTodayView {...commonProps} />);

    expect(await screen.findByRole("heading", { name: "Strength this week" })).toBeInTheDocument();
    expect(screen.getByText("2 sessions this week")).toBeInTheDocument();
    expect(screen.getByText("Weight progress")).toBeInTheDocument();
    expect(screen.getByRole("heading", { name: "Activity history" })).toBeInTheDocument();
    fireEvent.click(screen.getByRole("button", { name: "View activities" }));
    expect(onSectionChange).toHaveBeenCalledWith("activity");
    expect(screen.getByRole("img", { name: /Weight smoothed chart with 2 readings/i })).toBeInTheDocument();
    expect(screen.getByRole("radio", { name: "Smoothed" })).toBeChecked();
    expect(screen.getByRole("radio", { name: "1 Month" })).toBeChecked();
    expect(screen.getByRole("radio", { name: "7 Days" })).toBeInTheDocument();
    expect(screen.getByRole("radio", { name: "365 Days" })).toBeInTheDocument();
    expect(screen.queryByRole("radio", { name: "90 Days" })).not.toBeInTheDocument();
    expect(screen.queryByRole("radio", { name: "Body fat" })).not.toBeInTheDocument();
    expect(screen.queryByText(/calorie/i)).not.toBeInTheDocument();

    fireEvent.click(screen.getByRole("button", { name: "View weight progress" }));
    expect(onSectionChange).toHaveBeenCalledWith("progress");
    expect(new URLSearchParams(window.location.search).get("fitness-progress")).toBe("measurements");

    fireEvent.click(screen.getByText("Connect an app or device"));
    fireEvent.click(screen.getByRole("button", { name: "Garmin / Intervals.icu" }));
    expect(onSectionChange).toHaveBeenCalledWith("training");
    expect(new URLSearchParams(window.location.search).get("intervals")).toBe("setup");

    fireEvent.click(screen.getByRole("button", { name: "Withings" }));
    expect(onSectionChange).toHaveBeenCalledWith("progress");
    expect(new URLSearchParams(window.location.search).get("fitness-progress")).toBe("measurements");
    expect(new URLSearchParams(window.location.search).get("fitness-connect")).toBe("withings");
  });

  it("quick-logs a usual serving in one tap and offers a true soft-delete undo", async () => {
    saveMock.mockResolvedValueOnce({ id: "quick-log-1", revision: 3 } as never);
    render(<FitnessNutritionDiaryPanel {...commonProps} openLogRequest={0} onOpenCatalogue={vi.fn()} onOpenRecipes={vi.fn()} onOpenTemplates={vi.fn()} />);

    fireEvent.click(await screen.findByRole("button", { name: /Log Porridge/ }));
    await waitFor(() => expect(saveMock).toHaveBeenCalledWith("food_log_entry", expect.objectContaining({
      food_version_id: "food-version-1",
      entered_amount: 1,
      entered_unit: "bowl",
      canonical_amount: 240,
      canonical_unit: "g",
    }), undefined));
    expect(await screen.findByText("Porridge logged.")).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "Undo" })).toHaveFocus();

    fireEvent.click(screen.getByRole("button", { name: "Undo" }));
    await waitFor(() => expect(deleteMock).toHaveBeenCalledWith("food_log_entry", "quick-log-1", 3));
    expect(screen.queryByText("Porridge logged.")).not.toBeInTheDocument();
  });

  it("keeps barcode lookup review-only and preserves the fixed source when the user saves", async () => {
    render(<FitnessFoodCataloguePanel {...commonProps} openCreateRequest={1} />);
    fireEvent.change(await screen.findByLabelText("Barcode (optional)"), { target: { value: "12345678" } });
    fireEvent.click(screen.getByRole("button", { name: "Look up" }));

    expect(await screen.findByDisplayValue("Live yoghurt")).toBeInTheDocument();
    expect(screen.getByDisplayValue("Example Dairy")).toBeInTheDocument();
    expect(screen.queryByLabelText("Source")).not.toBeInTheDocument();
    expect(screen.queryByLabelText("Confidence")).not.toBeInTheDocument();
    expect(screen.queryByLabelText("Source note")).not.toBeInTheDocument();
    expect(screen.getByText("Check the package against these copied values.")).toBeInTheDocument();
    expect(saveMock).not.toHaveBeenCalled();

    fireEvent.click(screen.getByRole("button", { name: "Save food" }));
    await waitFor(() => expect(saveMock).toHaveBeenCalledWith("food", expect.objectContaining({
      barcode: "12345678",
      brand: "Example Dairy",
      version: expect.objectContaining({ source_type: "open_food_facts", source_note: "https://world.openfoodfacts.org/product/12345678", confidence: "copied" }),
    }), expect.objectContaining({ entityId: expect.any(String) })));
  });

  it("stops the camera stream on Escape/unmount and leaves the camera panel non-modal", async () => {
    const stop = vi.fn();
    const getUserMedia = vi.fn().mockResolvedValue({ getTracks: () => [{ stop }] });
    const play = vi.spyOn(HTMLMediaElement.prototype, "play").mockResolvedValue(undefined);
    Object.defineProperty(window, "BarcodeDetector", { configurable: true, value: class { static getSupportedFormats = vi.fn().mockResolvedValue(["ean_8"]); detect = vi.fn(() => new Promise(() => undefined)); } });
    Object.defineProperty(window.navigator, "mediaDevices", { configurable: true, value: { getUserMedia } });
    const close = vi.fn();
    const scanner = render(<FitnessBarcodeScanner onDetected={vi.fn()} onClose={close} />);

    expect(await screen.findByRole("region", { name: "Scan a barcode" })).toBeInTheDocument();
    expect(screen.queryByRole("dialog")).not.toBeInTheDocument();
    await waitFor(() => expect(getUserMedia).toHaveBeenCalledWith({ audio: false, video: { facingMode: { ideal: "environment" } } }));
    fireEvent.keyDown(document, { key: "Escape" });
    expect(close).toHaveBeenCalledTimes(1);
    scanner.unmount();
    expect(stop).toHaveBeenCalled();
    play.mockRestore();
    Object.defineProperty(window, "BarcodeDetector", { configurable: true, value: undefined });
  });

  it("reviews recovery evidence without turning a deep link into a data-entry task", async () => {
    recoverySummary = {
      window: { from_date: "2026-07-27", to_date: "2026-08-03", expected_days: 8, days_with_sleep: 5 },
      sleep: {},
      baselines: [{ metric_key: "recovery.hrv_rmssd_ms", label: "HRV (RMSSD)", status: "below_baseline", current_value: 42, baseline_value: 51, window_days: 28, unit_key: "ms" }],
      relationships: [],
    };
    window.history.replaceState({}, "", "/?view=fitness&section=recovery&fitness-recovery=recovery.hrv_rmssd_ms");
    const metricReview = render(<FitnessRecoveryView {...commonProps} />);
    const baseline = (await screen.findByText("HRV (RMSSD)")).closest("article");
    await waitFor(() => expect(baseline).toHaveFocus());
    expect(screen.queryByRole("heading", { name: "Manual recovery observation" })).not.toBeInTheDocument();
    expect(new URL(window.location.href).searchParams.has("fitness-recovery")).toBe(false);
    expect(screen.queryByText("Set up cycle tracking when it is useful")).not.toBeInTheDocument();
    expect(await screen.findByText("Manage Recovery")).toBeInTheDocument();
    metricReview.unmount();

    window.history.replaceState({}, "", "/?view=fitness&section=recovery&fitness-issue=stale-issue-id");
    render(<FitnessRecoveryView {...commonProps} />);
    await waitFor(() => expect(document.getElementById("fitness-body-issues")).toHaveFocus());
    expect(screen.queryByRole("heading", { name: "Record a body issue" })).not.toBeInTheDocument();
    expect(new URL(window.location.href).searchParams.has("fitness-issue")).toBe(false);
  });

  it("does not expose a partial training-week review when a nested step exceeds the preview bound", async () => {
    const runSteps: Array<Record<string, unknown>> = Array.from({ length: 60 }, (_, index) => ({
      display_name: index === 0 ? "Visible warm-up detail" : `Visible run step ${index + 1}`,
      duration_type: "time_s",
      duration_value: 60,
    }));
    runSteps[59] = {
      ...runSteps[59],
      children: [{ display_name: "Hidden overflow stride", duration_type: "time_s", duration_value: 30 }],
    };
    coachMessage = {
      status: "complete", answer: "Review every executable session before saving.", evidence: [], recommendation: null,
      proposal: {
        id: "proposal-week-bounded", kind: "training_week",
        payload: {
          name: "Foundation week", purpose: "Build consistency", starts_on: "2026-08-03",
          sessions: [
            { title: "Monday run", sport_key: "running", scheduled_date: "2026-08-03", expected_duration_s: 3600, steps: runSteps },
            { title: "Wednesday lift", sport_key: "strength", scheduled_date: "2026-08-05", expected_duration_s: 2400, exercises: [{ exercise_name: "Goblet squat", setup_name: "Home dumbbell", sets: [{ training_role: "working", structure_type: "straight", load_value: 24, load_unit: "kg", reps: 8, rir: 2 }] }] },
          ],
        },
        validation: { valid: true, issues: [] }, warnings: [], confirmable: true, expires_at: "2099-08-03T23:59:59Z",
      },
    };

    render(<FitnessCoachView {...commonProps} />);
    fireEvent.change(await screen.findByLabelText("Message your Fitness coach"), { target: { value: "Build next week" } });
    fireEvent.click(screen.getByRole("button", { name: "Send" }));

    expect(await screen.findByText("Ask Coach to make this suggestion again before saving it.")).toBeInTheDocument();
    expect(screen.queryByText(/Visible warm-up detail/)).not.toBeInTheDocument();
    expect(screen.queryByText("Goblet squat")).not.toBeInTheDocument();
    expect(screen.queryByText(/24 kg × 8 reps · RIR 2/)).not.toBeInTheDocument();
    expect(screen.queryByText("Hidden overflow stride")).not.toBeInTheDocument();
    expect(screen.queryByRole("button", { name: "Confirm" })).not.toBeInTheDocument();
    expect(screen.getByRole("button", { name: "Edit" })).toBeDisabled();
  });

  it("uses every authoritative post-confirm destination and undoes through the dedicated endpoint", async () => {
    coachMessage = {
      status: "complete", answer: "Review this week before saving.", evidence: [], recommendation: null,
      proposal: {
        id: "proposal-week", kind: "training_week", payload: { name: "Foundation week", sessions: [
          { title: "Monday run", sport_key: "running", scheduled_date: "2026-08-03", expected_duration_s: 1800, steps: [{ display_name: "Easy run", duration_type: "time_s", duration_value: 1800 }] },
          { title: "Wednesday lift", sport_key: "strength", scheduled_date: "2026-08-05", expected_duration_s: 2400, exercises: [{ exercise_name: "Goblet squat", setup_name: "Home dumbbell", sets: [{ training_role: "working", reps: 8 }] }] },
        ] },
        validation: { valid: true, issues: [] }, warnings: [], confirmable: true, expires_at: "2099-08-03T23:59:59Z",
      },
    };
    const destinations = [
      { kind: "planned_session", target: "session-a", label: "Open Monday run" },
      { kind: "planned_session", target: "session-b", label: "Open Wednesday lift" },
      { kind: "nutrition_target", target: "target-1", label: "Open protein target" },
      { kind: "meal_template", target: "template-1", label: "Open breakfast template" },
      { kind: "goal", target: "goal-1", label: "Open goal" },
      { kind: "analysis_chart", target: "chart-1", label: "Open chart" },
      { kind: "calendar_event", target: "event-1", label: "Open family event" },
      { kind: "food_log", target: "food-log-1", label: "Open diary entry" },
      { kind: "shopping", target: "shopping-1", label: "Open shopping item" },
      { kind: "task", target: "task-1", label: "Open task" },
      { kind: "fitness_reminder", target: "reminder-1", label: "Open reminder" },
    ];
    confirmDecision = {
      status: "confirmed", message: "The reviewed week was saved.", result_ids: ["wrong-positional-id"],
      next_destinations: destinations,
    };
    const onOpenCoachDestination = vi.fn();
    render(<FitnessCoachView {...commonProps} onOpenCoachDestination={onOpenCoachDestination} />);
    fireEvent.change(await screen.findByLabelText("Message your Fitness coach"), { target: { value: "Build next week" } });
    const sendButton = screen.getByRole("button", { name: "Send" });
    await waitFor(() => expect(sendButton).toBeEnabled());
    fireEvent.click(sendButton);
    fireEvent.click(await screen.findByRole("button", { name: "Confirm" }));

    expect(await screen.findByText("Saved")).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "Open Monday run" })).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "Open Wednesday lift" })).toBeInTheDocument();

    for (const destination of destinations) {
      fireEvent.click(screen.getByRole("button", { name: destination.label }));
      expect(onOpenCoachDestination).toHaveBeenLastCalledWith(destination);
    }
    expect(onOpenCoachDestination).toHaveBeenCalledTimes(11);
    expect(new URL(window.location.href).search).not.toContain("wrong-positional-id");

    fireEvent.click(screen.getByRole("button", { name: "Undo" }));
    expect(await screen.findByText("Undone")).toBeInTheDocument();
    expect(apiMock).toHaveBeenCalledWith("/fitness/coach/proposals/proposal-week/undo", { method: "POST" }, true, false);
  });
});
