import { fireEvent, render, screen, waitFor } from "@testing-library/react";
import { beforeEach, describe, expect, it, vi } from "vitest";

import { api } from "../api";
import { saveFitnessRecords } from "../fitness/offlineStore";
import {
  previousComparableComponents,
  previousPerformanceLabel,
  strengthWorkoutExportText,
  strengthSessionIsResumable,
} from "../fitness/strengthWorkout";
import { FitnessStrengthProgressPanel } from "../views/fitness/FitnessStrengthProgressPanel";
import type { FitnessStrengthWorkspace } from "../views/fitness/FitnessStrengthView";
import { FitnessStrengthWorkoutPanel } from "../views/fitness/FitnessStrengthWorkoutPanel";

vi.mock("../api", () => ({
  api: vi.fn(),
  ApiError: class ApiError extends Error { status: number; constructor(message: string, status: number) { super(message); this.status = status; } },
}));

vi.mock("../fitness/offlineStore", () => ({
  cacheFitnessRecords: vi.fn().mockResolvedValue(undefined),
  cachedFitnessRecords: vi.fn().mockResolvedValue([]),
  saveFitnessRecord: vi.fn().mockImplementation(async (_type, payload, options) => ({ ...payload, id: options?.entityId ?? crypto.randomUUID(), queued_offline: true })),
  saveFitnessRecords: vi.fn(),
}));

const exercise = {
  id: "exercise-squat",
  name: "Back squat",
  active: true,
  favourite: true,
  measurement_mode: "reps_load",
  rep_count_mode: "total",
  load_entry_mode: "total_external",
  default_unit: "kg",
  bodyweight_involved: true,
  muscle_roles: [{ muscle_group_key: "quadriceps", role: "primary", contribution_weight: 1 }],
};
const setup = { id: "setup-rack", exercise_id: exercise.id, name: "Merged rack", active: true, is_default: true, load_entry_mode: "total_external" };

function workspace(overrides: Partial<FitnessStrengthWorkspace> = {}): FitnessStrengthWorkspace {
  return {
    exercises: [exercise],
    setups: [setup],
    sessions: [],
    plans: [],
    templates: [],
    bodyIssues: [],
    phases: [],
    bodyMeasurements: [],
    activeSession: null,
    activeExercises: [],
    activeGroups: [],
    activeComponents: [],
    ...overrides,
  } as FitnessStrengthWorkspace;
}

const saveMany = vi.mocked(saveFitnessRecords);
const apiMock = vi.mocked(api);

describe("Fitness Strength completion", () => {
  beforeEach(() => {
    window.history.replaceState({}, "", "/?view=fitness&section=strength");
    saveMany.mockReset();
    saveMany.mockImplementation(async (inputs) => inputs.map((input) => ({ ...input.payload, id: input.options?.entityId ?? crypto.randomUUID(), queued_offline: true })));
    apiMock.mockReset();
    apiMock.mockImplementation(async (path) => path === "/fitness/body-locations"
      ? [{ id: "location-knee", location_key: "knee", display_name: "Knee", active: true }]
      : [] as never);
    Object.defineProperty(window.navigator, "onLine", { configurable: true, value: true });
  });

  it("expires the resume window only after one hour", () => {
    const now = new Date("2026-08-13T12:00:00Z");
    const session = {
      id: "resume-window",
      title: "Strength",
      status: "in_progress" as const,
      started_at_utc: "2026-08-13T11:00:00Z",
      local_timezone: "Europe/London",
    };

    expect(strengthSessionIsResumable(session, now)).toBe(true);
    expect(strengthSessionIsResumable(
      { ...session, started_at_utc: "2026-08-13T10:59:59.999Z" },
      now,
    )).toBe(false);
  });

  it("consumes a linked planned shell and starts the next timer without claiming prior rest", async () => {
    const session = { id: "session-active", revision: 3, title: "Lower A", status: "in_progress" as const, started_at_utc: new Date(Date.now() - 60_000).toISOString(), local_timezone: "Europe/Berlin", notes: "[bodyweight_snapshot=78.2]" };
    const sessionExercise = { id: "session-exercise", activity_id: session.id, exercise_id: exercise.id, exercise_setup_id: setup.id, planned_exercise_id: "planned-exercise", sequence: 0 };
    const group = { id: "planned-group", revision: 2, activity_id: session.id, session_exercise_id: sessionExercise.id, planned_set_id: "planned-set", sequence: 0, training_role: "working" as const, structure_type: "straight" as const, status: "planned" as const, failure_state: "none" as const, notes: "Target: 6–8 reps · 80 kg · RIR 2" };
    render(<FitnessStrengthWorkoutPanel workspace={workspace({ activeSession: session, activeExercises: [sessionExercise], activeGroups: [group], sessions: [session] })} online={false} onDataChanged={vi.fn()} />);

    expect(screen.queryByLabelText("Bodyweight snapshot (kg)")).not.toBeInTheDocument();
    fireEvent.change(screen.getByLabelText("Weight (kg total)"), { target: { value: "80" } });
    fireEvent.change(screen.getByLabelText("Repetitions"), { target: { value: "8" } });
    fireEvent.click(screen.getByRole("button", { name: "Start set" }));
    const stopButton = screen.getByRole("button", { name: "Stop set" });
    await waitFor(() => expect(stopButton).toBeEnabled());
    fireEvent.click(stopButton);

    await waitFor(() => expect(saveMany).toHaveBeenCalled());
    const inputs = saveMany.mock.calls[0][0];
    expect(inputs).toEqual(expect.arrayContaining([
      expect.objectContaining({ entityType: "strength_set_group", options: expect.objectContaining({ entityId: group.id }), payload: expect.objectContaining({ planned_set_id: "planned-set", status: "completed" }) }),
      expect.objectContaining({ entityType: "strength_set_component", payload: expect.objectContaining({ reps: 8, load_value: 80, bodyweight_kg_snapshot: 78.2, rest_before_s: null, extra_metrics: { next_rest_timer_s: 120 } }) }),
      expect.objectContaining({ entityType: "strength_session", payload: expect.objectContaining({ rest_timer_deadline_utc: expect.any(String) }) }),
    ]));
    expect(screen.getByText("Rest elapsed")).toBeInTheDocument();
  });

  it("exports the whole workout as one readable LLM-ready block", () => {
    const text = strengthWorkoutExportText({
      id: "session-export",
      title: "Lower A",
      status: "completed",
      started_at_utc: "2026-08-20T10:00:00Z",
      ended_at_utc: "2026-08-20T11:05:00Z",
      local_timezone: "Europe/London",
      notes: "[bodyweight_snapshot=78.2]\nFelt strong",
      exercises: [{
        id: "session-exercise",
        activity_id: "session-export",
        exercise_id: exercise.id,
        exercise_name: exercise.name,
        source_setup_label: setup.name,
        sequence: 0,
        set_groups: [{
          id: "group-export",
          activity_id: "session-export",
          session_exercise_id: "session-exercise",
          sequence: 0,
          training_role: "working",
          structure_type: "straight",
          status: "completed",
          failure_state: "muscular",
          started_at_utc: "2026-08-20T10:05:00Z",
          completed_at_utc: "2026-08-20T10:05:40Z",
          components: [{ id: "component-export", set_group_id: "group-export", component_index: 0, component_status: "completed", load_value: 80, load_unit: "kg", reps: 8 }],
        }],
      }],
    });

    expect(text).toContain("Strength workout: Lower A");
    expect(text).toContain("Duration: 1:05:00");
    expect(text).toContain("1. Back squat");
    expect(text).toContain("Set 1: 80 kg × 8 reps | Failure: muscular | Set time: 0:40");
    expect(text).toContain("Workout notes: Felt strong");
    expect(text).not.toContain("bodyweight_snapshot");
  });

  it("silently snapshots the latest canonical bodyweight when a workout starts", async () => {
    const measuredAt = new Date(Date.now() - 30 * 86_400_000).toISOString();
    render(<FitnessStrengthWorkoutPanel workspace={workspace({ bodyMeasurements: [{ id: "weight-1", metric_key: "body.weight_kg", measured_at_utc: measuredAt, local_timezone: "Europe/Berlin", value: 77.6, unit_key: "kg", canonical_state: "canonical" }] })} online onDataChanged={vi.fn()} />);

    expect(screen.queryByText("Bodyweight snapshot for relevant exercises")).not.toBeInTheDocument();
    expect(screen.queryByText(/Latest selected weight/)).not.toBeInTheDocument();
    expect(screen.queryByLabelText(/bodyweight/i)).not.toBeInTheDocument();
    fireEvent.click(screen.getByRole("button", { name: "Start workout" }));
    await waitFor(() => expect(saveMany).toHaveBeenCalled());
    expect(saveMany.mock.calls[0][0][0]).toEqual(expect.objectContaining({
      entityType: "strength_session",
      payload: expect.objectContaining({ notes: "[bodyweight_snapshot=77.6]" }),
    }));
  });

  it("consumes a planned-session route intent and starts exactly once", async () => {
    const plannedSession = {
      id: "plan-one-tap",
      revision: 2,
      sport_key: "strength",
      title: "Full body one tap",
      status: "accepted",
      scheduled_date: "2026-08-03",
      movable: true,
      exercise_items: [],
    };
    window.history.replaceState({}, "", "/?view=fitness&section=strength&fitness-strength-start=plan-one-tap");
    const onDataChanged = vi.fn();
    const panel = render(<FitnessStrengthWorkoutPanel workspace={workspace({ plans: [plannedSession] as never })} online onDataChanged={onDataChanged} />);

    await waitFor(() => expect(saveMany).toHaveBeenCalledTimes(1));
    expect(saveMany.mock.calls[0][0][0]).toEqual(expect.objectContaining({
      entityType: "strength_session",
      payload: expect.objectContaining({
        title: "Full body one tap",
        planned_session_id: "plan-one-tap",
        status: "in_progress",
        matched_plan_key: "plan",
      }),
    }));
    expect(new URL(window.location.href).searchParams.get("fitness-strength-start")).toBeNull();

    panel.rerender(<FitnessStrengthWorkoutPanel workspace={workspace({ plans: [plannedSession] as never })} online onDataChanged={onDataChanged} />);
    await waitFor(() => expect(saveMany).toHaveBeenCalledTimes(1));
  });

  it("consumes the empty-day route intent and starts one blank live workout", async () => {
    window.history.replaceState({}, "", "/?view=fitness&section=strength&fitness-strength-start=blank");
    const onDataChanged = vi.fn();
    const panel = render(<FitnessStrengthWorkoutPanel workspace={workspace()} online onDataChanged={onDataChanged} />);

    await waitFor(() => expect(saveMany).toHaveBeenCalledTimes(1));
    expect(saveMany.mock.calls[0][0][0]).toEqual(expect.objectContaining({
      entityType: "strength_session",
      payload: expect.objectContaining({
        title: "Strength workout",
        planned_session_id: null,
        status: "in_progress",
        matched_plan_key: "blank",
      }),
    }));
    expect(new URL(window.location.href).searchParams.get("fitness-strength-start")).toBeNull();

    panel.rerender(<FitnessStrengthWorkoutPanel workspace={workspace()} online onDataChanged={onDataChanged} />);
    await waitFor(() => expect(saveMany).toHaveBeenCalledTimes(1));
  });

  it("queues a body issue with server-contract enum values when finishing", async () => {
    const session = { id: "session-finish", revision: 1, title: "Lower A", status: "in_progress" as const, started_at_utc: new Date(Date.now() - 60_000).toISOString(), local_timezone: "Europe/Berlin", notes: "[bodyweight_snapshot=unknown]" };
    render(<FitnessStrengthWorkoutPanel workspace={workspace({ activeSession: session, sessions: [session] })} online={false} onDataChanged={vi.fn()} />);
    fireEvent.click(screen.getByRole("button", { name: "Finish" }));
    await screen.findByRole("option", { name: "Knee" });
    fireEvent.change(screen.getByLabelText("Outcome"), { target: { value: "partial" } });
    fireEvent.change(screen.getByLabelText("Body issue region (optional)"), { target: { value: "knee" } });
    fireEvent.change(screen.getByLabelText("Side"), { target: { value: "left" } });
    fireEvent.click(screen.getByRole("button", { name: "Finish workout" }));
    await waitFor(() => expect(saveMany).toHaveBeenCalled());
    expect(saveMany.mock.calls[0][0]).toEqual(expect.arrayContaining([expect.objectContaining({
      entityType: "body_issue",
      payload: expect.objectContaining({
        issue_type_key: "discomfort",
        timing: "during",
        body_location_key: "knee",
        side: "left",
        changed_session: true,
        session_change_key: "reduced_load",
        trend_key: "unknown",
      }),
    })]));
  });

  it("keeps finish controls in an accessible modal and closes it with Escape", async () => {
    const session = { id: "session-finish", revision: 1, title: "Lower A", status: "in_progress" as const, started_at_utc: new Date(Date.now() - 60_000).toISOString(), local_timezone: "Europe/Berlin", notes: "[bodyweight_snapshot=unknown]" };
    render(<FitnessStrengthWorkoutPanel workspace={workspace({ activeSession: session, sessions: [session] })} online onDataChanged={vi.fn()} />);

    const finishButton = screen.getByRole("button", { name: "Finish" });
    fireEvent.click(finishButton);

    const dialog = await screen.findByRole("dialog", { name: "Finish workout" });
    await waitFor(() => expect(dialog).toContainElement(document.activeElement as HTMLElement | null));

    fireEvent.keyDown(dialog, { key: "Escape" });
    await waitFor(() => expect(screen.queryByRole("dialog", { name: "Finish workout" })).not.toBeInTheDocument());
    expect(finishButton).toHaveFocus();
  });

  it("only uses completed sessions with the exact setup for previous comparable work", () => {
    const component = { id: "component", set_group_id: "group", component_index: 0, component_status: "completed" as const, reps: 5, load_value: 100, load_unit: "kg" };
    const completed = { id: "completed", title: "Completed", status: "completed" as const, started_at_utc: "2026-07-30T10:00:00Z", local_timezone: "UTC", exercises: [{ id: "se-complete", activity_id: "completed", exercise_id: exercise.id, exercise_setup_id: setup.id, sequence: 0, set_groups: [{ id: "group", activity_id: "completed", session_exercise_id: "se-complete", sequence: 0, training_role: "working" as const, structure_type: "straight" as const, status: "completed" as const, components: [component] }] }] };
    const partialOtherSetup = { ...completed, id: "partial", status: "partial" as const, started_at_utc: "2026-08-01T10:00:00Z", exercises: [{ ...completed.exercises![0], id: "se-partial", activity_id: "partial", exercise_setup_id: "other-setup" }] };
    const result = previousComparableComponents([partialOtherSetup, completed], exercise.id, setup.id);
    expect(result?.session.id).toBe("completed");
    expect(previousPerformanceLabel(result)).toBe("100 kg × 5");
  });

  it("uses contextual server suggestions and keeps progress within one immutable setup key", async () => {
    const machineSetup = { id: "setup-machine", exercise_id: exercise.id, name: "Current machine name", active: true, is_default: false, load_entry_mode: "machine_level" };
    const recent = new Date().toISOString();
    const older = new Date(Date.now() - 86_400_000).toISOString();
    apiMock.mockImplementation(async (path) => {
      if (path === `/fitness/strength/exercises/${exercise.id}/progress`) return {
        exercise,
        redirect: null,
        logical_set_groups: [],
        observed_sets: [
          { id: "set-1", set_group_id: "group-1", component_index: 0, component_status: "completed", reps: null, reps_left: 8, reps_right: 8, load_value: 80, load_unit: "kg", normalized_external_load_kg: 80, load_entry_mode_snapshot: "per_side", activity_id: "activity-1", activity_title: "Lower", started_at_utc: recent, group_id: "group-1", setup_id: setup.id, source_setup_label: "Old garage rack", comparison_key: { exercise_id: exercise.id, setup_id: setup.id, load_entry_mode: "per_side", rep_count_mode: "total", unilateral_mode: "bilateral" }, structure_type: "straight", training_role: "working", failure_state: "none", rir: 2 },
          { id: "set-2", set_group_id: "group-2", component_index: 0, component_status: "completed", reps: 5, load_value: 200, load_unit: "kg", normalized_external_load_kg: 200, load_entry_mode_snapshot: "machine_level", activity_id: "activity-2", activity_title: "Gym lower", started_at_utc: older, group_id: "group-2", setup_id: machineSetup.id, source_setup_label: "Archived gym machine", comparison_key: { exercise_id: exercise.id, setup_id: machineSetup.id, load_entry_mode: "machine_level", rep_count_mode: "total", unilateral_mode: "bilateral" }, structure_type: "straight", training_role: "working", failure_state: "none", rir: 1 },
        ],
        records: { heaviest: null, best_by_rep_band: {} },
        estimated_1rm: [
          { estimated_1rm_kg: 101.3, source_set: { id: "set-1", started_at_utc: recent, comparison_key: { exercise_id: exercise.id, setup_id: setup.id, load_entry_mode: "per_side", rep_count_mode: "total", unilateral_mode: "bilateral" } } },
          { estimated_1rm_kg: 240, source_set: { id: "set-2", started_at_utc: older, comparison_key: { exercise_id: exercise.id, setup_id: machineSetup.id, load_entry_mode: "machine_level", rep_count_mode: "total", unilateral_mode: "bilateral" } } },
        ],
      } as never;
      if (path === "/fitness/strength/muscle-groups") return [] as never;
      if (path === "/fitness/strength/suggestions") return {
        generated_at: recent,
        planned_session: { id: "plan-1", title: "Lower A", status: "accepted", expected_duration_s: 3600 },
        session_candidate: { kind: "planned_strength_session", exercise_ids: [exercise.id], estimated_minutes: 12, reason: "Built from the accepted plan." },
        exercise_candidates: [{
          planned_exercise_id: "planned-exercise-1", exercise_id: exercise.id, exercise_name: exercise.name, exercise_setup_id: setup.id, setup_name: "Old garage rack", original_exercise_id: exercise.id, sequence: 0, included_in_time_budget: true, estimated_minutes: 12,
          progression: { action: "hold_load", reason: "Repeat 80 kg because the comparable sets remain in range.", evidence_group_ids: ["group-1"], missing_context: [] },
          recent_evidence: [{ group_id: "group-1", activity_id: "activity-1", activity_title: "Lower", performed_at: recent, source_setup_label: "Old garage rack", training_role: "working", failure_state: "none", components: [{ component_index: 0, reps: 8, reps_left: null, reps_right: null, load_kg: 80, rpe: null, rir: 2 }] }],
          active_body_issues: [], reasons: ["Latest comparable evidence is Lower."],
        }],
        recent_running_load: { window_days: 7, session_count: 1, distance_m: 5000, duration_s: 1800, latest_at: recent },
        active_body_issues: [], missing_context: [],
      } as never;
      throw new Error(String(path));
    });
    render(<FitnessStrengthProgressPanel workspace={workspace({ setups: [setup, machineSetup] })} revision={0} />);
    expect(await screen.findByText("Back squat: Hold load")).toBeInTheDocument();
    expect(screen.getByText(/Repeat 80 kg because/)).toBeInTheDocument();
    expect(screen.getByText(/Old garage rack \(kg per side\)/)).toBeInTheDocument();
    expect(screen.queryByText(/Merged rack \(kg per side\)/)).not.toBeInTheDocument();
    expect(screen.getAllByText("101.3 kg").length).toBeGreaterThan(0);
    expect(screen.queryAllByText("240.0 kg")).toHaveLength(0);
    expect(screen.getAllByText("80 kg × 8/8").length).toBeGreaterThan(0);
    expect(screen.queryByText("80 kg × 16")).not.toBeInTheDocument();
    expect(screen.getByText("7-10 reps").closest("li")).toHaveTextContent("80 kg × 8/8");

    fireEvent.change(screen.getByLabelText("Strength setup comparison"), { target: { value: JSON.stringify([exercise.id, machineSetup.id, "machine_level", "total", "bilateral"]) } });
    expect(screen.getByText(/Archived gym machine \(machine level\)/)).toBeInTheDocument();
    expect(screen.getAllByText("240.0 kg").length).toBeGreaterThan(0);
    expect(screen.queryByText(/Old garage rack \(kg per side\)/)).not.toBeInTheDocument();
  });
});
