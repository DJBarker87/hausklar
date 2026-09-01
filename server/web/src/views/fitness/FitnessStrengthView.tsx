import { BarChart3, BookOpen, Dumbbell } from "lucide-react";
import { lazy, Suspense, useMemo, useState } from "react";

import type {
  FitnessBodyIssue,
  FitnessBodyMeasurement,
  FitnessExercise,
  FitnessExerciseSetup,
  FitnessPhase,
  FitnessPlannedSession,
  FitnessStrengthSession,
  FitnessStrengthSessionExercise,
  FitnessStrengthSetComponent,
  FitnessStrengthSetGroup,
  FitnessWorkoutDefinition,
} from "../../fitness/contract";
import {
  mergedStrengthComponents,
  mergedStrengthGroups,
  mergedStrengthSessionExercises,
  strengthSessionIsResumable,
} from "../../fitness/strengthWorkout";
import type { FitnessViewProps } from "./FitnessModuleView";
import {
  FitnessLoadingOrError,
  FitnessPageHeading,
  useFitnessCachedRecords,
  useFitnessCollection,
} from "./shared";

const FitnessStrengthWorkoutPanel = lazy(() => import("./FitnessStrengthWorkoutPanel").then((module) => ({ default: module.FitnessStrengthWorkoutPanel })));
const FitnessStrengthLibraryPanel = lazy(() => import("./FitnessStrengthLibraryPanel").then((module) => ({ default: module.FitnessStrengthLibraryPanel })));
const FitnessStrengthProgressPanel = lazy(() => import("./FitnessStrengthProgressPanel").then((module) => ({ default: module.FitnessStrengthProgressPanel })));

type StrengthTab = "workout" | "library" | "progress";

export type FitnessStrengthWorkspace = {
  exercises: FitnessExercise[];
  setups: FitnessExerciseSetup[];
  sessions: FitnessStrengthSession[];
  plans: FitnessPlannedSession[];
  templates: FitnessWorkoutDefinition[];
  bodyIssues: FitnessBodyIssue[];
  phases: FitnessPhase[];
  bodyMeasurements: FitnessBodyMeasurement[];
  activeSession: FitnessStrengthSession | null;
  activeExercises: FitnessStrengthSessionExercise[];
  activeGroups: FitnessStrengthSetGroup[];
  activeComponents: FitnessStrengthSetComponent[];
};

export function FitnessStrengthView({ revision, online, onDataChanged }: FitnessViewProps) {
  const [tab, setTab] = useState<StrengthTab>("workout");
  const exercises = useFitnessCollection<FitnessExercise>("/fitness/exercises", "exercise", revision);
  const setups = useFitnessCollection<FitnessExerciseSetup>("/fitness/exercise-setups", "exercise_setup", revision);
  const sessions = useFitnessCollection<FitnessStrengthSession>("/fitness/strength/sessions", "strength_session", revision);
  const plans = useFitnessCollection<FitnessPlannedSession>("/fitness/planned-sessions", "planned_session", revision);
  const templates = useFitnessCollection<FitnessWorkoutDefinition>("/fitness/strength/templates", "workout_definition", revision);
  const bodyIssues = useFitnessCollection<FitnessBodyIssue>("/fitness/body-issues?active_only=true", "body_issue", revision);
  const phases = useFitnessCollection<FitnessPhase>("/fitness/phases", "training_phase", revision);
  const bodyMeasurements = useFitnessCollection<FitnessBodyMeasurement>("/fitness/body/measurements?metric_key=body.weight_kg", "body_measurement", revision);
  const cachedExercises = useFitnessCachedRecords<FitnessStrengthSessionExercise>("strength_session_exercise", revision);
  const cachedGroups = useFitnessCachedRecords<FitnessStrengthSetGroup>("strength_set_group", revision);
  const cachedComponents = useFitnessCachedRecords<FitnessStrengthSetComponent>("strength_set_component", revision);

  const activeSession = useMemo(() => sessions.data
    .filter((session) => strengthSessionIsResumable(session))
    .sort((left, right) => right.started_at_utc.localeCompare(left.started_at_utc))[0] ?? null, [sessions.data]);
  const activeExercises = useMemo(
    () => mergedStrengthSessionExercises(activeSession, cachedExercises.data),
    [activeSession, cachedExercises.data],
  );
  const activeGroups = useMemo(
    () => mergedStrengthGroups(activeSession, activeExercises, cachedGroups.data),
    [activeExercises, activeSession, cachedGroups.data],
  );
  const activeComponents = useMemo(
    () => mergedStrengthComponents(activeSession, activeGroups, cachedComponents.data),
    [activeGroups, activeSession, cachedComponents.data],
  );

  const workspace: FitnessStrengthWorkspace = {
    exercises: exercises.data.filter((item) => item.active !== false),
    setups: setups.data.filter((item) => item.active !== false),
    sessions: sessions.data,
    plans: plans.data.filter((item) => item.sport_key === "strength"),
    templates: templates.data.filter((item) => item.sport_key === "strength" && item.active !== false),
    bodyIssues: bodyIssues.data,
    phases: phases.data,
    bodyMeasurements: bodyMeasurements.data,
    activeSession,
    activeExercises,
    activeGroups,
    activeComponents,
  };

  const primary = [exercises, setups, sessions];
  const loading = primary.some((resource) => resource.loading);
  const error = primary.map((resource) => resource.error).find(Boolean) ?? null;

  return (
    <section className="fitness-module__strength">
      <FitnessPageHeading
        title="Strength"
        detail="Plan, perform and review each logical set without losing detail when you are offline."
      />

      <nav className="fitness-module__subnav" aria-label="Strength sections">
        <button className={tab === "workout" ? "is-active" : ""} onClick={() => setTab("workout")} type="button">
          <Dumbbell size={16} aria-hidden="true" /> Workout
        </button>
        <button className={tab === "library" ? "is-active" : ""} onClick={() => setTab("library")} type="button">
          <BookOpen size={16} aria-hidden="true" /> Exercise library
        </button>
        <button className={tab === "progress" ? "is-active" : ""} onClick={() => setTab("progress")} type="button">
          <BarChart3 size={16} aria-hidden="true" /> Progress
        </button>
      </nav>

      <FitnessLoadingOrError loading={loading} error={error} retry={() => primary.forEach((resource) => resource.reload())} />
      {!loading && !error ? (
        <Suspense fallback={<div className="fitness-module__empty">Loading strength tools…</div>}>
          {tab === "workout" ? (
            <FitnessStrengthWorkoutPanel
              workspace={workspace}
              online={online}
              onDataChanged={onDataChanged}
            />
          ) : null}
          {tab === "library" ? (
            <FitnessStrengthLibraryPanel
              workspace={workspace}
              online={online}
              onDataChanged={onDataChanged}
            />
          ) : null}
          {tab === "progress" ? (
            <FitnessStrengthProgressPanel
              workspace={workspace}
              revision={revision}
            />
          ) : null}
        </Suspense>
      ) : null}
    </section>
  );
}
