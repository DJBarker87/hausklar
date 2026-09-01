import { describe, expect, it } from "vitest";

import type {
  FitnessStrengthSetComponent,
  FitnessStrengthSetGroup,
} from "../fitness/contract";
import {
  eligibleEstimatedOneRepMax,
  effectiveRepetitionsForE1RM,
  isPerformedStrengthComponent,
  nextCompoundGroupStatus,
} from "../fitness/strengthSemantics";

const group: FitnessStrengthSetGroup = {
  id: "group-1",
  activity_id: "session-1",
  session_exercise_id: "exercise-1",
  sequence: 0,
  training_role: "working",
  structure_type: "drop",
  status: "completed",
  is_amrap: false,
  failure_state: "none",
};

function component(overrides: Partial<FitnessStrengthSetComponent> = {}): FitnessStrengthSetComponent {
  return {
    id: "component-1",
    set_group_id: group.id,
    component_index: 0,
    component_status: "completed",
    reps: 8,
    normalized_external_load_kg: 80,
    rir: 2,
    ...overrides,
  };
}

describe("Fitness strength semantics", () => {
  it("counts partial positive work but never skipped or empty partial work", () => {
    expect(isPerformedStrengthComponent(component({ component_status: "partial", reps: 3 }))).toBe(true);
    expect(isPerformedStrengthComponent(component({ component_status: "partial", reps: 0 }))).toBe(false);
    expect(isPerformedStrengthComponent(component({ component_status: "skipped", reps: 8 }))).toBe(false);
  });

  it("keeps an appended drop component in one logical group and updates its status", () => {
    const first = component();
    expect(nextCompoundGroupStatus([first], "completed")).toBe("completed");
    expect(nextCompoundGroupStatus([first], "partial")).toBe("partial");
    expect(nextCompoundGroupStatus([first], "skipped")).toBe("partial");
    expect(nextCompoundGroupStatus([], "skipped")).toBe("skipped");
    expect(new Set([first.set_group_id, component({ id: "component-2", component_index: 1 }).set_group_id]).size).toBe(1);
  });

  it("only estimates near-hard straight work of ten reps or fewer", () => {
    expect(eligibleEstimatedOneRepMax(group, component())).toBeNull();
    const straight = { ...group, structure_type: "straight" as const };
    expect(effectiveRepetitionsForE1RM(straight, component())).toBe(10);
    expect(eligibleEstimatedOneRepMax(straight, component())).toBeCloseTo(106.67, 2);
    expect(eligibleEstimatedOneRepMax(straight, component({ reps: 9 }))).toBeNull();
    expect(eligibleEstimatedOneRepMax(straight, component({ reps: 7, rir: 3 }))).toBeCloseTo(106.67, 2);
    expect(eligibleEstimatedOneRepMax(straight, component({ reps: 8, rir: null, rpe: 8 }))).toBeCloseTo(106.67, 2);
    expect(eligibleEstimatedOneRepMax(straight, component({ rir: 4, rpe: null }))).toBeNull();
    expect(eligibleEstimatedOneRepMax(
      { ...straight, is_amrap: true },
      component({ rir: null, rpe: null }),
    )).toBeNull();
  });
});
