import type {
  FitnessStrengthSetComponent,
  FitnessStrengthSetGroup,
} from "./contract";

export function isPerformedStrengthComponent(component: FitnessStrengthSetComponent): boolean {
  return component.component_status === "completed"
    || (component.component_status === "partial" && (
      (component.reps ?? 0) > 0
      || (component.reps_left ?? 0) > 0
      || (component.reps_right ?? 0) > 0
      || (component.duration_s ?? 0) > 0
      || (component.distance_m ?? 0) > 0
    ));
}

export function nextCompoundGroupStatus(
  existing: FitnessStrengthSetComponent[],
  appendedStatus: FitnessStrengthSetComponent["component_status"],
): FitnessStrengthSetGroup["status"] {
  const anyPerformed = existing.some(isPerformedStrengthComponent);
  const anyIncomplete = existing.some((component) => component.component_status !== "completed");
  if (appendedStatus === "partial" || anyIncomplete || (appendedStatus === "skipped" && anyPerformed)) {
    return "partial";
  }
  return appendedStatus === "skipped" ? "skipped" : "completed";
}

export function eligibleEstimatedOneRepMax(
  group: FitnessStrengthSetGroup,
  component: FitnessStrengthSetComponent,
): number | null {
  const repetitions = component.reps ?? 0;
  const effectiveRepetitions = effectiveRepetitionsForE1RM(group, component);
  const eligibleRole = ["working", "backoff", "test"].includes(group.training_role);
  if (
    !isPerformedStrengthComponent(component)
    || effectiveRepetitions == null
    || !eligibleRole
    || group.structure_type !== "straight"
    || repetitions < 1
    || effectiveRepetitions > 10
    || component.normalized_external_load_kg == null
  ) return null;
  return component.normalized_external_load_kg * (1 + effectiveRepetitions / 30);
}

export function effectiveRepetitionsForE1RM(
  group: FitnessStrengthSetGroup,
  component: FitnessStrengthSetComponent,
): number | null {
  const repetitions = component.reps ?? 0;
  if (group.failure_state === "technical" || group.failure_state === "muscular") {
    return repetitions;
  }
  if (component.rir != null && component.rir >= 0 && component.rir <= 3) {
    return repetitions + component.rir;
  }
  if (component.rpe != null && component.rpe >= 7 && component.rpe <= 10) {
    return repetitions + (10 - component.rpe);
  }
  return null;
}
