import type {
  FitnessExercise,
  FitnessExerciseSetup,
  FitnessPlannedSession,
  FitnessStrengthExerciseProgress,
  FitnessStrengthSession,
  FitnessStrengthSessionExercise,
  FitnessStrengthSetComponent,
  FitnessStrengthSetGroup,
  FitnessWorkoutDefinition,
  FitnessWorkoutVersion,
} from "./contract";
import { isPerformedStrengthComponent } from "./strengthSemantics";

export const STRENGTH_SESSION_RESUME_WINDOW_MS = 60 * 60 * 1_000;

export function strengthSessionIsResumable(
  session: FitnessStrengthSession,
  now: Date = new Date(),
): boolean {
  if (session.status !== "in_progress") return false;
  const startedAt = Date.parse(session.started_at_utc);
  if (!Number.isFinite(startedAt)) return false;
  return now.getTime() - startedAt <= STRENGTH_SESSION_RESUME_WINDOW_MS;
}

export function strengthSetupLoadLabel(
  setup?: FitnessExerciseSetup | null,
  exercise?: FitnessExercise | null,
): string {
  const mode = setup?.load_entry_mode ?? exercise?.load_entry_mode ?? "total_external";
  const labels: Record<string, string> = {
    total_external: "kg total",
    per_hand: "kg each",
    per_side: "kg per side",
    machine_stack: "stack kg",
    machine_level: "machine level",
    added_bodyweight: "added kg",
    assistance: "assistance kg",
    bodyweight_only: "bodyweight only",
    none: "no load",
  };
  return labels[mode] ?? mode.replaceAll("_", " ");
}

export function strengthRepetitionLabel(
  setup?: FitnessExerciseSetup | null,
  exercise?: FitnessExercise | null,
): string {
  const mode = setup?.rep_count_mode ?? exercise?.rep_count_mode ?? "total";
  if (mode === "per_side") return "Repetitions per side";
  if (mode === "left_right_separate") return "Repetitions by side";
  return "Repetitions";
}

export function normalizedStrengthLoad(
  load: number,
  setup?: FitnessExerciseSetup | null,
  exercise?: FitnessExercise | null,
): number | null {
  const mode = setup?.load_entry_mode ?? exercise?.load_entry_mode ?? "total_external";
  if (["bodyweight_only", "added_bodyweight", "none", "machine_level", "assistance"].includes(mode)) return null;
  if (mode === "per_hand") return load * 2;
  if (mode === "per_side") return load * (setup?.side_multiplier ?? 2) + (setup?.bar_weight_kg ?? 0);
  return load + (setup?.machine_base_load_kg ?? 0);
}

export function plannedStrengthTarget(
  item?: NonNullable<FitnessPlannedSession["exercise_items"]>[number] | null,
): string | null {
  if (!item?.planned_sets?.length) return null;
  return item.planned_sets.map((set) => {
    const reps = set.reps_min == null && set.reps_max == null
      ? null
      : set.reps_min === set.reps_max || set.reps_max == null
        ? `${set.reps_min ?? set.reps_max} reps`
        : `${set.reps_min ?? "?"}–${set.reps_max} reps`;
    const load = set.load_min == null && set.load_max == null
      ? null
      : set.load_min === set.load_max || set.load_max == null
        ? `${set.load_min ?? set.load_max} ${set.load_unit ?? "kg"}`
        : `${set.load_min ?? "?"}–${set.load_max} ${set.load_unit ?? "kg"}`;
    const effort = set.rir_min != null
      ? `RIR ${set.rir_min}${set.rir_max != null && set.rir_max !== set.rir_min ? `–${set.rir_max}` : ""}`
      : set.rpe_min != null
        ? `RPE ${set.rpe_min}${set.rpe_max != null && set.rpe_max !== set.rpe_min ? `–${set.rpe_max}` : ""}`
        : null;
    const structure = set.component_count > 1 ? `${set.structure_type.replaceAll("_", " ")} ×${set.component_count}` : null;
    return [reps, load, effort, structure].filter(Boolean).join(" · ");
  }).join(" / ");
}

export function mergedStrengthSessionExercises(
  session: FitnessStrengthSession | null,
  local: FitnessStrengthSessionExercise[],
): FitnessStrengthSessionExercise[] {
  const values = new Map<string, FitnessStrengthSessionExercise>();
  for (const exercise of session?.exercises ?? []) values.set(exercise.id, exercise);
  for (const exercise of local.filter((item) => item.activity_id === session?.id)) {
    values.set(exercise.id, { ...values.get(exercise.id), ...exercise });
  }
  return [...values.values()].sort((left, right) => left.sequence - right.sequence);
}

export function mergedStrengthGroups(
  session: FitnessStrengthSession | null,
  exercises: FitnessStrengthSessionExercise[],
  local: FitnessStrengthSetGroup[],
): FitnessStrengthSetGroup[] {
  const values = new Map<string, FitnessStrengthSetGroup>();
  for (const exercise of session?.exercises ?? []) {
    for (const group of exercise.set_groups ?? []) values.set(group.id, group);
  }
  for (const group of local.filter((item) => item.activity_id === session?.id)) {
    values.set(group.id, { ...values.get(group.id), ...group });
  }
  const validExerciseIds = new Set(exercises.map((item) => item.id));
  return [...values.values()]
    .filter((group) => validExerciseIds.has(group.session_exercise_id))
    .sort((left, right) => left.sequence - right.sequence);
}

export function mergedStrengthComponents(
  session: FitnessStrengthSession | null,
  groups: FitnessStrengthSetGroup[],
  local: FitnessStrengthSetComponent[],
): FitnessStrengthSetComponent[] {
  const values = new Map<string, FitnessStrengthSetComponent>();
  for (const exercise of session?.exercises ?? []) {
    for (const group of exercise.set_groups ?? []) {
      for (const component of group.components ?? []) values.set(component.id, component);
    }
  }
  for (const component of local) values.set(component.id, { ...values.get(component.id), ...component });
  const validGroupIds = new Set(groups.map((item) => item.id));
  return [...values.values()]
    .filter((component) => validGroupIds.has(component.set_group_id))
    .sort((left, right) => left.component_index - right.component_index);
}

export function previousComparableComponents(
  sessions: FitnessStrengthSession[],
  exerciseId: string,
  setupId?: string | null,
  beforeSessionId?: string | null,
): { session: FitnessStrengthSession; exercise: FitnessStrengthSessionExercise; components: FitnessStrengthSetComponent[] } | null {
  for (const session of [...sessions]
    .filter((item) => item.id !== beforeSessionId && item.status === "completed")
    .sort((left, right) => right.started_at_utc.localeCompare(left.started_at_utc))) {
    const exercise = session.exercises?.find((item) => item.exercise_id === exerciseId && item.exercise_setup_id === setupId);
    if (!exercise) continue;
    const components = (exercise.set_groups ?? [])
      .filter((group) => ["working", "backoff", "test"].includes(group.training_role))
      .flatMap((group) => group.components ?? [])
      .filter(isPerformedStrengthComponent);
    if (components.length) return { session, exercise, components };
  }
  return null;
}

export function previousPerformanceLabel(
  value: ReturnType<typeof previousComparableComponents>,
): string | null {
  if (!value) return null;
  return value.components.slice(0, 4).map((component) => {
    const load = component.load_value == null ? "" : `${component.load_value} ${component.load_unit ?? "kg"} × `;
    const reps = component.reps_left != null || component.reps_right != null
      ? `${component.reps_left ?? "?"}/${component.reps_right ?? "?"}`
      : component.reps ?? (component.duration_s != null ? `${component.duration_s}s` : component.distance_m != null ? `${component.distance_m}m` : "work");
    const effort = component.rir != null ? ` @ RIR ${component.rir}` : component.rpe != null ? ` @ RPE ${component.rpe}` : "";
    return `${load}${reps}${effort}`;
  }).join("; ");
}

export function strengthWorkoutVersion(
  definition?: FitnessWorkoutDefinition | null,
  versionId?: string | null,
): FitnessWorkoutVersion | null {
  if (!definition) return null;
  const versions = [definition.current_version, definition.version, ...(definition.versions ?? [])]
    .filter((version): version is FitnessWorkoutVersion => Boolean(version));
  if (versionId) return versions.find((version) => version.id === versionId) ?? null;
  return versions[0] ?? null;
}

export function strengthTemplateItems(definition?: FitnessWorkoutDefinition | null, versionId?: string | null) {
  return strengthWorkoutVersion(definition, versionId)?.exercise_items ?? [];
}

export function strengthProgressionSuggestion(
  progress: FitnessStrengthExerciseProgress | null,
  planned?: NonNullable<FitnessPlannedSession["exercise_items"]>[number] | null,
): { title: string; reason: string } | null {
  if (!progress?.observed_sets.length) return null;
  const recent = [...progress.observed_sets]
    .sort((left, right) => right.started_at_utc.localeCompare(left.started_at_utc))
    .slice(0, 4);
  const plannedWorking = planned?.planned_sets?.filter((set) => ["working", "backoff", "test"].includes(set.training_role)) ?? [];
  const top = plannedWorking[0];
  if (top?.reps_max != null && recent.length >= Math.min(2, plannedWorking.length || 2)) {
    const allAtTop = recent.every((set) => (set.reps ?? 0) >= top.reps_max!
      && (set.rir == null || top.rir_min == null || set.rir >= top.rir_min)
      && (set.rpe == null || top.rpe_max == null || set.rpe <= top.rpe_max));
    if (allAtTop) return {
      title: "Consider the next small load increase",
      reason: `The latest ${recent.length} comparable recorded sets all reached at least ${top.reps_max} reps without exceeding the planned effort ceiling.`,
    };
  }
  const best = progress.records.heaviest;
  return {
    title: "Hold the setup and build from observed work",
    reason: best?.normalized_external_load_kg != null
      ? `The heaviest comparable recorded set is ${best.normalized_external_load_kg} kg for ${best.reps ?? "recorded"} reps; no complete top-of-range progression signal is present.`
      : "There is recorded performance, but not enough comparable load-and-repetition evidence for a load increase.",
  };
}

export function formatStrengthClock(seconds: number): string {
  const safe = Math.max(0, Math.floor(seconds));
  const hours = Math.floor(safe / 3600);
  const minutes = Math.floor((safe % 3600) / 60);
  const remainder = safe % 60;
  return hours > 0
    ? `${hours}:${String(minutes).padStart(2, "0")}:${String(remainder).padStart(2, "0")}`
    : `${minutes}:${String(remainder).padStart(2, "0")}`;
}

function strengthExportDuration(start?: string | null, end?: string | null): string | null {
  if (!start || !end) return null;
  const seconds = Math.max(0, Math.round((Date.parse(end) - Date.parse(start)) / 1_000));
  return Number.isFinite(seconds) ? formatStrengthClock(seconds) : null;
}

function strengthExportComponent(component: FitnessStrengthSetComponent): string {
  const load = component.load_value != null
    ? `${component.load_value} ${component.load_unit ?? "kg"}`
    : null;
  const reps = component.reps_left != null || component.reps_right != null
    ? `${component.reps_left ?? "?"}/${component.reps_right ?? "?"} reps (left/right)`
    : component.reps != null
      ? `${component.reps} reps`
      : component.duration_s != null
        ? `${formatStrengthClock(component.duration_s)}`
        : component.distance_m != null
          ? `${component.distance_m} m`
          : component.component_status;
  return [load, reps, component.rir != null ? `RIR ${component.rir}` : null,
    component.rpe != null ? `RPE ${component.rpe}` : null, component.notes?.trim() || null]
    .filter(Boolean).join(" × ");
}

/** A compact, lossless-enough workout transcript intended for pasting into an LLM. */
export function strengthWorkoutExportText(session: FitnessStrengthSession): string {
  const duration = strengthExportDuration(session.started_at_utc, session.ended_at_utc);
  const performedGroups = (session.exercises ?? []).flatMap((item) => item.set_groups ?? [])
    .filter((group) => ["completed", "partial"].includes(group.status));
  const header = [
    `Strength workout: ${session.title}`,
    `Started: ${session.started_at_utc}`,
    session.ended_at_utc ? `Ended: ${session.ended_at_utc}` : "Ended: in progress",
    duration ? `Duration: ${duration}` : null,
    `Status: ${session.status.replaceAll("_", " ")}`,
    session.session_rpe != null ? `Session RPE: ${session.session_rpe}` : null,
    session.perceived_performance != null ? `Perceived performance: ${session.perceived_performance}/5` : null,
    `Summary: ${(session.exercises ?? []).length} exercises, ${performedGroups.length} performed sets`,
  ].filter(Boolean) as string[];
  const exercises = (session.exercises ?? []).map((item, exerciseIndex) => {
    const name = item.exercise_name ?? item.exercise?.name ?? `Exercise ${exerciseIndex + 1}`;
    const setupName = item.source_setup_label ?? item.setup?.name ?? null;
    const groups = (item.set_groups ?? []).filter((group) => group.status !== "planned");
    const lines = [`\n${exerciseIndex + 1}. ${name}${setupName ? ` (${setupName})` : ""}`];
    if (!groups.length) lines.push("   No performed sets recorded.");
    groups.forEach((group, groupIndex) => {
      const components = (group.components ?? []).filter((component) => component.component_status !== "skipped");
      const failure = group.failure_state && group.failure_state !== "none"
        ? ` | Failure: ${group.failure_state.replaceAll("_", " ")}`
        : "";
      const setDuration = strengthExportDuration(group.started_at_utc, group.completed_at_utc);
      const timing = setDuration ? ` | Set time: ${setDuration}` : "";
      const detail = components.length
        ? components.map(strengthExportComponent).join("; ")
        : group.status.replaceAll("_", " ");
      lines.push(`   Set ${groupIndex + 1}: ${detail}${failure}${timing}`);
    });
    return lines.join("\n");
  });
  const notes = session.notes?.replace(/\[bodyweight_snapshot=[^\]]+\]\s*/g, "").trim();
  return [...header, ...exercises, notes ? `\nWorkout notes: ${notes}` : null]
    .filter((line): line is string => Boolean(line)).join("\n");
}
