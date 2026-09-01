import {
  CalendarDays,
  CalendarPlus,
  ChevronRight,
  Dumbbell,
  Footprints,
  Layers3,
  Link2,
  SlidersHorizontal,
  Target,
} from "lucide-react";
import { lazy, Suspense, useEffect, useMemo, useState } from "react";

import { api } from "../../api";
import { SkeletonList, cn } from "../../components/ui";
import { activitySportOptions, emptyActivityRegistry } from "../../fitness/activityRegistry";
import type {
  FitnessActivityRegistry,
  FitnessExercise,
  FitnessExerciseSetup,
  FitnessGearItem,
  FitnessGoal,
  FitnessGoalFromTemplateResponse,
  FitnessGoalTemplate,
  FitnessPhase,
  FitnessPlannedSession,
  FitnessTrainingProgramme,
  FitnessWorkoutDefinition,
} from "../../fitness/contract";
import type { FitnessViewProps } from "./FitnessModuleView";
import "./fitness-wave4.css";
import { FitnessSessionLauncher } from "./FitnessSessionComposer";
import {
  FitnessCard,
  FitnessFormStatus,
  FitnessLoadingOrError,
  FitnessPageHeading,
  errorMessage,
  formatFitnessDate,
  formatFitnessDateTime,
  localDateTimeValue,
  localDateValue,
  localTimeZone,
  submitForm,
  useFitnessBatchSave,
  useFitnessCollection,
  useFitnessEndpoint,
  useFitnessSave,
  utcFromLocalInput,
} from "./shared";

const FitnessRunPlanEditor = lazy(() => import("./FitnessRunPlanEditor").then((module) => ({ default: module.FitnessRunPlanEditor })));
const FitnessPlannedSessionEditor = lazy(() => import("./FitnessPlannedSessionEditor").then((module) => ({ default: module.FitnessPlannedSessionEditor })));
const FitnessProgrammeEditor = lazy(() => import("./FitnessTrainingPlanningPanels").then((module) => ({ default: module.FitnessProgrammeEditor })));
const FitnessIntervalsGarminPanel = lazy(() => import("./FitnessTrainingPlanningPanels").then((module) => ({ default: module.FitnessIntervalsGarminPanel })));
const FitnessPlanAdherencePanel = lazy(() => import("./FitnessTrainingPlanningPanels").then((module) => ({ default: module.FitnessPlanAdherencePanel })));
const FitnessGearManager = lazy(() => import("./FitnessGearManager").then((module) => ({ default: module.FitnessGearManager })));

type ManagePanel = "goals" | "programmes" | "runs" | "gear" | null;

type PlannedExerciseDraft = {
  key: string;
  exerciseId: string;
  setupId: string;
  setCount: number;
  role: string;
  structure: string;
  componentCount: number;
  repsMin: number;
  repsMax: number;
  load: number | null;
  rir: number | null;
  rest: number | null;
  amrap: boolean;
  substitutionExerciseIds: string[];
};

function sessionDate(session: FitnessPlannedSession): string {
  return session.scheduled_date
    ?? session.scheduled_start_utc?.slice(0, 10)
    ?? session.time_window_start_utc?.slice(0, 10)
    ?? "";
}

function humanSport(value: string): string {
  return value.replaceAll("_", " ").replace(/\b\w/g, (letter) => letter.toUpperCase());
}

function currentWeek(): Array<{ date: string; weekday: string; day: string; today: boolean }> {
  const today = localDateValue();
  const start = new Date(`${today}T12:00:00`);
  start.setDate(start.getDate() - ((start.getDay() + 6) % 7));
  return Array.from({ length: 7 }, (_, index) => {
    const date = new Date(start);
    date.setDate(start.getDate() + index);
    const value = localDateValue(date);
    return {
      date: value,
      weekday: new Intl.DateTimeFormat(undefined, { weekday: "short" }).format(date),
      day: new Intl.DateTimeFormat(undefined, { day: "numeric" }).format(date),
      today: value === today,
    };
  });
}

function initialManagePanel(): ManagePanel {
  const query = new URLSearchParams(window.location.search);
  const requested = query.get("fitness-plan-manage");
  if (requested === "goals" || requested === "programmes" || requested === "runs" || requested === "gear") return requested;
  if (["runPlans", "run-plans", "run_plans"].includes(query.get("section") ?? "")) return "runs";
  if (query.has("intervals")) return "gear";
  return null;
}

function startStrengthPlan(session: FitnessPlannedSession, onSectionChange: FitnessViewProps["onSectionChange"]) {
  const url = new URL(window.location.href);
  url.searchParams.set("fitness-strength-plan", session.id);
  window.history.replaceState(window.history.state, "", url);
  onSectionChange("strength");
}

function SessionEditorPanel({ session, programmes, revision, onDataChanged, onClose, onSectionChange }: {
  session: FitnessPlannedSession;
  programmes: FitnessTrainingProgramme[];
  revision: number;
  onDataChanged: () => void;
  onClose: () => void;
  onSectionChange: FitnessViewProps["onSectionChange"];
}) {
  const goals = useFitnessCollection<FitnessGoal>("/fitness/goals", "goal", revision);
  const definitions = useFitnessCollection<FitnessWorkoutDefinition>("/fitness/workout-definitions", "workout_definition", revision);
  const gear = useFitnessEndpoint<FitnessGearItem[]>("/fitness/gear", [], revision);
  const loading = goals.loading || definitions.loading || gear.loading;
  const error = goals.error ?? definitions.error ?? gear.error;
  return <Suspense fallback={<SkeletonList rows={5} />}>
    <FitnessLoadingOrError loading={loading} error={error} retry={() => { goals.reload(); definitions.reload(); gear.reload(); }} />
    {!loading && !error ? <FitnessPlannedSessionEditor session={session} goals={goals.data} programmes={programmes} definitions={definitions.data} gear={gear.data} onDataChanged={onDataChanged} onClose={onClose} onStartStrength={() => startStrengthPlan(session, onSectionChange)} /> : null}
  </Suspense>;
}

export function LegacyPlanSessionComposer({ revision, programmes, onDataChanged, onClose }: {
  revision: number;
  programmes: FitnessTrainingProgramme[];
  onDataChanged: () => void;
  onClose: () => void;
}) {
  const goals = useFitnessCollection<FitnessGoal>("/fitness/goals", "goal", revision);
  const exercises = useFitnessCollection<FitnessExercise>("/fitness/exercises", "exercise", revision);
  const setups = useFitnessCollection<FitnessExerciseSetup>("/fitness/exercise-setups", "exercise_setup", revision);
  const registry = useFitnessEndpoint<FitnessActivityRegistry>("/fitness/activity-registry", emptyActivityRegistry, revision);
  const save = useFitnessBatchSave(onDataChanged);
  const [title, setTitle] = useState("");
  const [sport, setSport] = useState("strength");
  const [scheduledAt, setScheduledAt] = useState(localDateTimeValue(new Date(Date.now() + 86_400_000)));
  const [duration, setDuration] = useState("60");
  const [movable, setMovable] = useState(true);
  const [goalId, setGoalId] = useState("");
  const [programmeId, setProgrammeId] = useState("");
  const [exerciseId, setExerciseId] = useState("");
  const [setupId, setSetupId] = useState("");
  const [setCount, setSetCount] = useState("3");
  const [repsMin, setRepsMin] = useState("6");
  const [repsMax, setRepsMax] = useState("8");
  const [load, setLoad] = useState("");
  const [rir, setRir] = useState("2");
  const [rest, setRest] = useState("120");
  const [role, setRole] = useState("working");
  const [structure, setStructure] = useState("straight");
  const [components, setComponents] = useState("1");
  const [amrap, setAmrap] = useState(false);
  const [planned, setPlanned] = useState<PlannedExerciseDraft[]>([]);
  const sportOptions = activitySportOptions(registry.data);
  const loading = goals.loading || exercises.loading || setups.loading || registry.loading;
  const error = goals.error ?? exercises.error ?? setups.error ?? registry.error;

  function addExercise() {
    if (!exerciseId) return;
    setPlanned((current) => [...current, {
      key: crypto.randomUUID(),
      exerciseId,
      setupId,
      setCount: Number(setCount),
      role,
      structure,
      componentCount: Number(components),
      repsMin: Number(repsMin),
      repsMax: Number(repsMax),
      load: load ? Number(load) : null,
      rir: rir ? Number(rir) : null,
      rest: rest ? Number(rest) : null,
      amrap,
      substitutionExerciseIds: [],
    }]);
    setExerciseId("");
    setSetupId("");
  }

  function moveExercise(index: number, direction: -1 | 1) {
    setPlanned((current) => {
      const target = index + direction;
      if (target < 0 || target >= current.length) return current;
      const next = [...current];
      [next[index], next[target]] = [next[target], next[index]];
      return next;
    });
  }

  function setSubstitution(key: string, candidateId: string, selected: boolean) {
    setPlanned((current) => current.map((item) => item.key !== key ? item : {
      ...item,
      substitutionExerciseIds: selected ? [...item.substitutionExerciseIds, candidateId] : item.substitutionExerciseIds.filter((id) => id !== candidateId),
    }));
  }

  async function create() {
    const exerciseItems = sport === "strength" ? planned.map((item, sequence) => ({
      id: crypto.randomUUID(),
      exercise_id: item.exerciseId,
      exercise_setup_id: item.setupId || null,
      sequence,
      superset_group_key: null,
      substitution_exercise_ids: item.substitutionExerciseIds,
      notes: null,
      planned_sets: Array.from({ length: item.setCount }, (_, setSequence) => ({
        id: crypto.randomUUID(),
        sequence: setSequence,
        training_role: item.role,
        structure_type: item.structure,
        component_count: item.componentCount,
        reps_min: item.repsMin,
        reps_max: item.repsMax,
        load_min: item.load,
        load_max: item.load,
        load_unit: item.load == null ? null : "kg",
        rpe_min: null,
        rpe_max: null,
        rir_min: item.rir,
        rir_max: item.rir,
        rest_s: item.rest,
        is_amrap: item.amrap,
        notes: null,
      })),
    })) : [];
    const sessionId = crypto.randomUUID();
    const workoutDefinitionId = sport === "strength" ? crypto.randomUUID() : null;
    const workoutVersionId = sport === "strength" ? crypto.randomUUID() : null;
    const acceptedAt = new Date().toISOString();
    const session = {
      id: sessionId,
      sport_key: sport,
      title: title.trim(),
      status: sport === "strength" ? "accepted" : "scheduled",
      session_source: "user",
      scheduled_start_utc: utcFromLocalInput(scheduledAt),
      scheduled_date: scheduledAt.slice(0, 10),
      local_timezone: localTimeZone(),
      expected_duration_s: Number(duration) * 60,
      priority: 1,
      movable,
      visibility: "private",
      training_programme_id: programmeId || null,
      goal_links: goalId ? [{ goal_id: goalId, role: "primary" }] : [],
      workout_version_id: workoutVersionId,
      exercise_items: exerciseItems,
    };
    await save.save(sport === "strength" && workoutDefinitionId && workoutVersionId ? [{
      entityType: "workout_definition",
      payload: {
        id: workoutDefinitionId,
        sport_key: "strength",
        name: title.trim(),
        description: null,
        active: true,
        version: {
          id: workoutVersionId,
          title: title.trim(),
          purpose: null,
          estimated_duration_s: Number(duration) * 60,
          estimated_distance_m: null,
          structured_summary: { schema: "strength_plan_v1", exercise_count: exerciseItems.length },
          version_source: "user",
          accepted_at: acceptedAt,
          exercise_items: exerciseItems,
          run_steps: [],
          run_cues: [],
        },
      },
      options: { entityId: workoutDefinitionId },
    }, { entityType: "planned_session", payload: session, options: { entityId: sessionId } }] : [{ entityType: "planned_session", payload: session, options: { entityId: sessionId } }]);
    onClose();
  }

  return <FitnessCard title="Create a session" detail="Choose the useful basics now. More detail stays optional.">
    <FitnessLoadingOrError loading={loading} error={error} retry={() => { goals.reload(); exercises.reload(); setups.reload(); registry.reload(); }} />
    {!loading && !error ? <form className="fitness-module__form" onSubmit={submitForm(create)}>
      <div className="fitness-module__fields">
        <label className="fitness-module__field is-wide">Session title<input required value={title} onChange={(event) => setTitle(event.target.value)} placeholder="Full body A" /></label>
        <label className="fitness-module__field">Activity<select value={sport} onChange={(event) => setSport(event.target.value)}>{sportOptions.map((option) => <option value={option.key} key={option.key}>{option.display_name}</option>)}</select></label>
        <label className="fitness-module__field">Start<input type="datetime-local" required value={scheduledAt} onChange={(event) => setScheduledAt(event.target.value)} /></label>
        <label className="fitness-module__field">Minutes<input type="text" inputMode="numeric" pattern="[0-9]*" required value={duration} onChange={(event) => setDuration(event.target.value)} /></label>
        <label className="fitness-module__check"><input type="checkbox" checked={movable} onChange={(event) => setMovable(event.target.checked)} /> This can move</label>
        <label className="fitness-module__field">Goal<select value={goalId} onChange={(event) => setGoalId(event.target.value)}><option value="">No goal</option>{goals.data.filter((goal) => goal.status === "active").map((goal) => <option value={goal.id} key={goal.id}>{goal.name}</option>)}</select></label>
        <label className="fitness-module__field">Programme<select value={programmeId} onChange={(event) => setProgrammeId(event.target.value)}><option value="">No programme</option>{programmes.filter((programme) => ["draft", "active", "paused"].includes(programme.status)).map((programme) => <option value={programme.id} key={programme.id}>{programme.name}</option>)}</select></label>
      </div>

      {sport === "strength" ? <section className="fitness-wave4__strength-prescription" aria-labelledby="strength-prescription-title"><header><h4 id="strength-prescription-title">Strength workout</h4><p>Add exercises in the order you want to do them.</p></header>
        {planned.length ? <ol className="fitness-module__list">{planned.map((item, index) => {
          const exercise = exercises.data.find((candidate) => candidate.id === item.exerciseId);
          const setup = setups.data.find((candidate) => candidate.id === item.setupId);
          const substitutions = exercises.data.filter((candidate) => candidate.active !== false && candidate.id !== item.exerciseId);
          return <li key={item.key}><div><strong>{index + 1}. {exercise?.name ?? "Exercise"}</strong><small>{item.setCount} × {item.repsMin}{item.repsMax !== item.repsMin ? `–${item.repsMax}` : ""}{item.load != null ? ` at ${item.load} kg` : ""}{setup ? ` · ${setup.name}` : ""}</small>{substitutions.length ? <details className="fitness-module__details"><summary>Acceptable substitutions ({item.substitutionExerciseIds.length})</summary><div className="fitness-module__check-grid">{substitutions.map((candidate) => <label className="fitness-module__check" key={candidate.id}><input type="checkbox" checked={item.substitutionExerciseIds.includes(candidate.id)} onChange={(event) => setSubstitution(item.key, candidate.id, event.target.checked)} /> {candidate.name}</label>)}</div></details> : null}</div><div className="fitness-module__button-row"><button type="button" className="button button--secondary button--compact" aria-label={`Move ${exercise?.name ?? "exercise"} up`} disabled={index === 0} onClick={() => moveExercise(index, -1)}>↑</button><button type="button" className="button button--secondary button--compact" aria-label={`Move ${exercise?.name ?? "exercise"} down`} disabled={index === planned.length - 1} onClick={() => moveExercise(index, 1)}>↓</button><button type="button" className="button button--secondary button--compact" onClick={() => setPlanned((current) => current.filter((candidate) => candidate.key !== item.key))}>Remove</button></div></li>;
        })}</ol> : <div className="fitness-module__empty"><Dumbbell aria-hidden="true" size={24} /><strong>Add the first exercise</strong><span>You can still adjust it when the workout starts.</span></div>}
        <div className="fitness-module__fields">
          <label className="fitness-module__field">Exercise<select value={exerciseId} onChange={(event) => { const id = event.target.value; setExerciseId(id); setSetupId(setups.data.find((item) => item.exercise_id === id && item.is_default)?.id ?? ""); }}><option value="">Choose exercise</option>{exercises.data.filter((item) => item.active !== false).map((item) => <option value={item.id} key={item.id}>{item.name}</option>)}</select></label>
          <label className="fitness-module__field">Setup<select value={setupId} onChange={(event) => setSetupId(event.target.value)}><option value="">Choose at start</option>{setups.data.filter((item) => item.exercise_id === exerciseId && item.active !== false).map((item) => <option value={item.id} key={item.id}>{item.name}</option>)}</select></label>
          <label className="fitness-module__field">Sets<input type="text" inputMode="numeric" pattern="[0-9]*" value={setCount} onChange={(event) => setSetCount(event.target.value)} /></label>
          <label className="fitness-module__field">Reps from<input type="text" inputMode="numeric" pattern="[0-9]*" value={repsMin} onChange={(event) => setRepsMin(event.target.value)} /></label>
          <label className="fitness-module__field">Reps to<input type="text" inputMode="numeric" pattern="[0-9]*" value={repsMax} onChange={(event) => setRepsMax(event.target.value)} /></label>
          <label className="fitness-module__field">Load (kg)<input type="text" inputMode="decimal" value={load} onChange={(event) => setLoad(event.target.value)} /></label>
          <label className="fitness-module__field">Reps in reserve<input type="text" inputMode="decimal" value={rir} onChange={(event) => setRir(event.target.value)} /></label>
          <label className="fitness-module__field">Rest (seconds)<input type="text" inputMode="numeric" pattern="[0-9]*" value={rest} onChange={(event) => setRest(event.target.value)} /></label>
        </div>
        <details className="fitness-module__details"><summary>Advanced set structure</summary><div className="fitness-module__fields"><label className="fitness-module__field">Set role<select value={role} onChange={(event) => setRole(event.target.value)}><option value="warmup">Warm-up</option><option value="working">Working</option><option value="backoff">Back-off</option><option value="technique">Technique</option><option value="test">Test</option><option value="other">Other</option></select></label><label className="fitness-module__field">Structure<select value={structure} onChange={(event) => { setStructure(event.target.value); if (event.target.value === "straight") setComponents("1"); }}><option value="straight">Straight</option><option value="drop">Drop</option><option value="rest_pause">Rest-pause</option><option value="cluster">Cluster</option><option value="other">Other</option></select></label><label className="fitness-module__field">Parts per set<input type="text" inputMode="numeric" pattern="[0-9]*" disabled={structure === "straight"} value={components} onChange={(event) => setComponents(event.target.value)} /></label><label className="fitness-module__check"><input type="checkbox" checked={amrap} onChange={(event) => setAmrap(event.target.checked)} /> As many reps as possible</label></div></details>
        <button type="button" className="button button--secondary" disabled={!exerciseId || Number(repsMax) < Number(repsMin)} onClick={addExercise}>Add exercise</button>
      </section> : null}

      <div className="fitness-module__form-footer"><button type="submit" className="button button--primary" aria-busy={save.saving} disabled={save.saving || !title.trim() || (sport === "strength" && !planned.length)}>Save session</button><button type="button" className="button button--secondary" onClick={onClose}>Cancel</button><FitnessFormStatus saving={save.saving} saved={save.saved} error={save.saveError} /></div>
    </form> : null}
  </FitnessCard>;
}

function GoalTemplatesPanel({ revision, online, onDataChanged }: Pick<FitnessViewProps, "revision" | "online" | "onDataChanged">) {
  const templates = useFitnessEndpoint<FitnessGoalTemplate[]>("/fitness/goal-templates", [], revision);
  const goals = useFitnessCollection<FitnessGoal>("/fitness/goals", "goal", revision);
  const phases = useFitnessCollection<FitnessPhase>("/fitness/phases", "training_phase", revision);
  const phaseSave = useFitnessSave(onDataChanged);
  const [selectedId, setSelectedId] = useState<FitnessGoalTemplate["id"] | "">("");
  const selected = templates.data.find((item) => item.id === selectedId) ?? null;
  const [target, setTarget] = useState("");
  const [startsOn, setStartsOn] = useState(localDateValue());
  const [targetDate, setTargetDate] = useState("");
  const [creating, setCreating] = useState(false);
  const [createError, setCreateError] = useState<string | null>(null);
  const [created, setCreated] = useState<FitnessGoalFromTemplateResponse | null>(null);
  const [phaseOpen, setPhaseOpen] = useState(false);
  const [phaseName, setPhaseName] = useState("");
  const [phaseType, setPhaseType] = useState("custom");
  const [phaseStart, setPhaseStart] = useState(localDateValue());
  const [phaseEnd, setPhaseEnd] = useState("");
  const [primaryGoalId, setPrimaryGoalId] = useState("");
  const [tradeoff, setTradeoff] = useState("");
  const loading = templates.loading || goals.loading || phases.loading;
  const error = templates.error ?? goals.error ?? phases.error;
  const primaryTemplateIds = new Set([
    "run-faster-5k",
    "run-weekly-distance",
    "run-consistently",
    "strength-consistency",
    "move-consistently",
  ]);
  const primaryTemplates = templates.data.filter((template) => primaryTemplateIds.has(template.id));
  const otherTemplates = templates.data.filter((template) => !primaryTemplateIds.has(template.id));

  function chooseTemplate(template: FitnessGoalTemplate) {
    setSelectedId(template.id);
    setTarget(String(template.suggested_value));
    setCreated(null);
    setCreateError(null);
  }

  async function createGoal() {
    if (!selected || !target || !online) return;
    setCreating(true);
    setCreateError(null);
    setCreated(null);
    try {
      const result = await api<FitnessGoalFromTemplateResponse>("/fitness/goals/from-template", {
        method: "POST",
        body: JSON.stringify({
          id: crypto.randomUUID(),
          template_id: selected.id,
          target_value: Number(target),
          starts_on: startsOn,
          target_date: targetDate || null,
          priority: 50,
          client_id: "hausklar-web",
          client_timestamp: new Date().toISOString(),
        }),
      }, true, false);
      setCreated(result);
      goals.reload();
      onDataChanged();
    } catch (requestError) {
      setCreateError(errorMessage(requestError));
    } finally {
      setCreating(false);
    }
  }

  async function createPhase() {
    await phaseSave.save("training_phase", {
      phase_type: phaseType,
      name: phaseName.trim(),
      starts_on: phaseStart,
      ends_on: phaseEnd || null,
      goal_links: primaryGoalId ? [{ goal_id: primaryGoalId, role: "primary" }] : [],
      accepted_tradeoffs: tradeoff.trim() ? [tradeoff.trim()] : [],
      active: true,
    });
    setPhaseOpen(false);
    setPhaseName("");
    phases.reload();
  }

  return <div className="fitness-wave4__manage-panel">
    <FitnessLoadingOrError loading={loading} error={error} retry={() => { templates.reload(); goals.reload(); phases.reload(); }} />
    {!loading && !error ? <>
      <FitnessCard title="What do you want to improve?" detail="Choose the outcome in your own words. HausKlar handles the measurement underneath.">
        <fieldset className="fitness-wave4__goal-templates"><legend className="sr-only">Main goal</legend>{primaryTemplates.map((template) => <label className={cn(selectedId === template.id && "is-selected")} key={template.id}><input type="radio" name="goal-template" value={template.id} checked={selectedId === template.id} onChange={() => chooseTemplate(template)} /><span><strong>{template.title}</strong><small>{template.description}</small></span></label>)}</fieldset>
        {otherTemplates.length ? <details className="fitness-wave4__other-goals"><summary>Other goals</summary><fieldset className="fitness-wave4__goal-templates"><legend className="sr-only">Other goals</legend>{otherTemplates.map((template) => <label className={cn(selectedId === template.id && "is-selected")} key={template.id}><input type="radio" name="goal-template" value={template.id} checked={selectedId === template.id} onChange={() => chooseTemplate(template)} /><span><strong>{template.title}</strong><small>{template.description}</small></span></label>)}</fieldset></details> : null}
        {selected ? <form className="fitness-module__form fitness-wave4__goal-form" onSubmit={submitForm(createGoal)}>
          {selected.input_kind === "duration_minutes_seconds" ? <div className="fitness-module__field is-wide"><span>{selected.target_prompt}</span><div className="fitness-sessions__clock-input" role="group" aria-label={selected.target_prompt}><label>Minutes<input type="number" min="12" max="120" inputMode="numeric" value={Math.floor(Number(target || 0) / 60) || ""} onChange={(event) => setTarget(String(Number(event.target.value || 0) * 60 + Number(target || 0) % 60))} /></label><span>:</span><label>Seconds<input type="number" min="0" max="59" inputMode="numeric" value={Number(target || 0) % 60} onChange={(event) => setTarget(String(Math.floor(Number(target || 0) / 60) * 60 + Math.min(59, Math.max(0, Number(event.target.value || 0)))))} /></label></div></div> : <label className="fitness-module__field is-wide">{selected.target_prompt}<span className="fitness-wave4__input-with-unit"><input type="text" inputMode="decimal" required value={target} onChange={(event) => setTarget(event.target.value)} /><span>{selected.unit_label}</span></span></label>}
          <details className="fitness-sessions__more"><summary>Dates (optional)</summary><div className="fitness-module__fields"><label className="fitness-module__field">Start date<input type="date" required value={startsOn} onChange={(event) => setStartsOn(event.target.value)} /></label>{selected.supports_target_date ? <label className="fitness-module__field">Target date<input type="date" min={startsOn} value={targetDate} onChange={(event) => setTargetDate(event.target.value)} /></label> : null}</div></details>
          <div className="fitness-module__form-footer"><button type="submit" className="button button--primary" aria-busy={creating} disabled={!online || creating || !target || Number(target) < selected.minimum_value || Number(target) > selected.maximum_value}>{creating ? "Creating goal…" : "Create goal"}</button></div>
          {!online ? <p className="fitness-module__form-status">Connect to the internet to create this goal.</p> : null}
          {createError ? <div className="fitness-module__notice fitness-module__notice--error" role="alert"><span>{createError}</span><button type="submit" className="button button--secondary button--compact">Try again</button></div> : null}
          {created ? <div className="fitness-module__notice is-success" role="status"><Target aria-hidden="true" size={17} /><span><strong>{created.title}</strong> · {created.target_text}</span></div> : null}
        </form> : null}
      </FitnessCard>
      <FitnessCard title="Active goals" detail="The highest-priority goal guides the weekly review.">{goals.data.filter((goal) => goal.status === "active").length ? <ul className="fitness-module__list">{goals.data.filter((goal) => goal.status === "active").map((goal) => <li key={goal.id}><div><strong>{goal.name}</strong><small>{goal.target_date ? `Target date ${formatFitnessDate(goal.target_date)}` : "Ongoing"}</small></div></li>)}</ul> : <div className="fitness-module__empty"><Target aria-hidden="true" size={24} /><strong>No active goal</strong><span>Choose one above when it would make the week clearer.</span></div>}</FitnessCard>
      <button type="button" className="button button--secondary" onClick={() => setPhaseOpen((open) => !open)}><Layers3 aria-hidden="true" size={17} /> {phaseOpen ? "Close phase form" : "Create a training phase"}</button>
      {phaseOpen ? <FitnessCard title="Create a training phase" detail="Group a period of training around one primary goal."><form className="fitness-module__form" onSubmit={submitForm(createPhase)}><div className="fitness-module__fields"><label className="fitness-module__field is-wide">Phase name<input required value={phaseName} onChange={(event) => setPhaseName(event.target.value)} placeholder="Autumn strength block" /></label><label className="fitness-module__field">Focus<select value={phaseType} onChange={(event) => setPhaseType(event.target.value)}><option value="custom">General fitness</option><option value="strength_emphasis">Strength</option><option value="fat_loss">Fat loss</option><option value="maintenance">Maintenance</option><option value="recomposition">Body recomposition</option><option value="running_base">Running base</option><option value="race_preparation">Race preparation</option><option value="recovery">Recovery</option><option value="return_to_training">Return to training</option></select></label><label className="fitness-module__field">Primary goal<select value={primaryGoalId} onChange={(event) => setPrimaryGoalId(event.target.value)}><option value="">No goal</option>{goals.data.filter((goal) => goal.status === "active").map((goal) => <option value={goal.id} key={goal.id}>{goal.name}</option>)}</select></label><label className="fitness-module__field">Starts<input type="date" required value={phaseStart} onChange={(event) => setPhaseStart(event.target.value)} /></label><label className="fitness-module__field">Ends (optional)<input type="date" min={phaseStart} value={phaseEnd} onChange={(event) => setPhaseEnd(event.target.value)} /></label><label className="fitness-module__field is-wide">Constraint or trade-off (optional)<textarea value={tradeoff} onChange={(event) => setTradeoff(event.target.value)} placeholder="Keep Sundays free" /></label></div><div className="fitness-module__form-footer"><button type="submit" className="button button--primary" disabled={phaseSave.saving || !phaseName.trim()}>Create phase</button><FitnessFormStatus saving={phaseSave.saving} saved={phaseSave.saved} error={phaseSave.saveError} /></div></form></FitnessCard> : null}
      {phases.data.length ? <FitnessCard title="Training phases" detail="Current and previous blocks."><ul className="fitness-module__list">{[...phases.data].sort((left, right) => right.starts_on.localeCompare(left.starts_on)).map((phase) => <li key={phase.id}><div><strong>{phase.name}</strong><small>{formatFitnessDate(phase.starts_on)}{phase.ends_on ? ` – ${formatFitnessDate(phase.ends_on)}` : " onwards"}</small></div>{phase.active ? <span className="fitness-module__pill is-success">Active</span> : null}</li>)}</ul></FitnessCard> : null}
    </> : null}
  </div>;
}

function ProgrammeManager({ revision, sessions, programmes, onDataChanged }: {
  revision: number;
  sessions: FitnessPlannedSession[];
  programmes: FitnessTrainingProgramme[];
  onDataChanged: () => void;
}) {
  const goals = useFitnessCollection<FitnessGoal>("/fitness/goals", "goal", revision);
  const phases = useFitnessCollection<FitnessPhase>("/fitness/phases", "training_phase", revision);
  const [editorOpen, setEditorOpen] = useState(false);
  const [adherenceOpen, setAdherenceOpen] = useState(false);
  const loading = goals.loading || phases.loading;
  const error = goals.error ?? phases.error;
  return <div className="fitness-wave4__manage-panel"><FitnessLoadingOrError loading={loading} error={error} retry={() => { goals.reload(); phases.reload(); }} />{!loading && !error ? <>
    <div className="fitness-module__button-row"><button type="button" className="button button--primary" onClick={() => setEditorOpen(true)}><CalendarPlus aria-hidden="true" size={17} /> Create programme</button><button type="button" className="button button--secondary" onClick={() => setAdherenceOpen((open) => !open)}>Review completed plan</button></div>
    {editorOpen ? <Suspense fallback={<SkeletonList rows={4} />}><FitnessProgrammeEditor goals={goals.data} phases={phases.data} programmes={programmes} onDataChanged={onDataChanged} onClose={() => setEditorOpen(false)} /></Suspense> : null}
    {adherenceOpen ? <Suspense fallback={<SkeletonList rows={4} />}><FitnessPlanAdherencePanel sessions={sessions} /></Suspense> : null}
  </> : null}</div>;
}

function RunPlanManager({ revision, programmes, onDataChanged }: {
  revision: number;
  programmes: FitnessTrainingProgramme[];
  onDataChanged: () => void;
}) {
  const goals = useFitnessCollection<FitnessGoal>("/fitness/goals", "goal", revision);
  const definitions = useFitnessCollection<FitnessWorkoutDefinition>("/fitness/workout-definitions", "workout_definition", revision);
  const loading = goals.loading || definitions.loading;
  const error = goals.error ?? definitions.error;
  return <div className="fitness-wave4__manage-panel"><FitnessLoadingOrError loading={loading} error={error} retry={() => { goals.reload(); definitions.reload(); }} />{!loading && !error ? <>
    <Suspense fallback={<SkeletonList rows={5} />}><FitnessRunPlanEditor goals={goals.data} programmes={programmes} definitions={definitions.data} onClose={() => undefined} onAccepted={onDataChanged} /></Suspense>
    <FitnessCard title="Workout library" detail="Accepted run and strength sessions saved for reuse.">{definitions.data.length ? <ul className="fitness-module__list">{definitions.data.map((definition) => <li key={definition.id}><div><strong>{definition.name}</strong><small>{definition.sport_key.replaceAll("_", " ")}</small></div></li>)}</ul> : <div className="fitness-module__empty"><Footprints aria-hidden="true" size={24} /><strong>No saved workouts yet</strong><span>Create a run above or save a strength session.</span></div>}</FitnessCard>
  </> : null}</div>;
}

function GearConnectionsManager({ revision, sessions, online, onDataChanged }: {
  revision: number;
  sessions: FitnessPlannedSession[];
  online: boolean;
  onDataChanged: () => void;
}) {
  const gear = useFitnessEndpoint<FitnessGearItem[]>("/fitness/gear", [], revision);
  const definitions = useFitnessCollection<FitnessWorkoutDefinition>("/fitness/workout-definitions", "workout_definition", revision);
  const [gearOpen, setGearOpen] = useState(false);
  const [connectionOpen, setConnectionOpen] = useState(() => new URLSearchParams(window.location.search).has("intervals"));
  const loading = gear.loading || definitions.loading;
  const error = gear.error ?? definitions.error;
  return <div className="fitness-wave4__manage-panel"><FitnessLoadingOrError loading={loading} error={error} retry={() => { gear.reload(); definitions.reload(); }} />{!loading && !error ? <>
    <div className="fitness-module__button-row"><button type="button" className="button button--secondary" onClick={() => setGearOpen((open) => !open)}>{gearOpen ? "Close gear" : "Manage gear"}</button><button type="button" className="button button--secondary" onClick={() => setConnectionOpen((open) => !open)}><Link2 aria-hidden="true" size={17} /> {connectionOpen ? "Close connection tools" : "Training connections"}</button></div>
    {gearOpen ? <Suspense fallback={<SkeletonList rows={4} />}><FitnessGearManager items={gear.data} onChanged={() => { gear.reload(); onDataChanged(); }} onClose={() => setGearOpen(false)} /></Suspense> : <FitnessCard title="Gear" detail="Shoes and equipment attached to training.">{gear.data.filter((item) => item.active !== false).length ? <ul className="fitness-module__list">{gear.data.filter((item) => item.active !== false).map((item) => <li key={item.id}><div><strong>{item.name}</strong><small>{item.gear_type_key.replaceAll("_", " ")}{item.usage_distance_m != null ? ` · ${(item.usage_distance_m / 1_000).toFixed(0)} km` : ""}</small></div></li>)}</ul> : <div className="fitness-module__empty"><strong>No gear saved</strong><span>Add only the equipment you want attached to sessions.</span></div>}</FitnessCard>}
    {connectionOpen ? <Suspense fallback={<SkeletonList rows={5} />}><FitnessIntervalsGarminPanel definitions={definitions.data} sessions={sessions} online={online} /></Suspense> : null}
  </> : null}</div>;
}

function TrainingManage({ panel, onPanelChange, revision, online, sessions, programmes, onDataChanged }: {
  panel: ManagePanel;
  onPanelChange: (panel: ManagePanel) => void;
  revision: number;
  online: boolean;
  sessions: FitnessPlannedSession[];
  programmes: FitnessTrainingProgramme[];
  onDataChanged: () => void;
}) {
  return <div className="fitness-wave4__manage"><div className="fitness-wave4__manage-nav" role="group" aria-label="Manage Plan"><button type="button" className={cn(panel === "goals" && "is-active")} onClick={() => onPanelChange("goals")}><Target aria-hidden="true" size={17} /> Goals &amp; phases</button><button type="button" className={cn(panel === "programmes" && "is-active")} onClick={() => onPanelChange("programmes")}><Layers3 aria-hidden="true" size={17} /> Programmes</button><button type="button" className={cn(panel === "runs" && "is-active")} onClick={() => onPanelChange("runs")}><Footprints aria-hidden="true" size={17} /> Run plans</button><button type="button" className={cn(panel === "gear" && "is-active")} onClick={() => onPanelChange("gear")}><SlidersHorizontal aria-hidden="true" size={17} /> Gear &amp; connections</button></div>
    {panel === "goals" ? <GoalTemplatesPanel revision={revision} online={online} onDataChanged={onDataChanged} /> : null}
    {panel === "programmes" ? <ProgrammeManager revision={revision} sessions={sessions} programmes={programmes} onDataChanged={onDataChanged} /> : null}
    {panel === "runs" ? <RunPlanManager revision={revision} programmes={programmes} onDataChanged={onDataChanged} /> : null}
    {panel === "gear" ? <GearConnectionsManager revision={revision} sessions={sessions} online={online} onDataChanged={onDataChanged} /> : null}
  </div>;
}

export function FitnessTrainingView({ revision, online, onDataChanged, onSectionChange, onOpenCalendar }: FitnessViewProps) {
  const sessions = useFitnessCollection<FitnessPlannedSession>("/fitness/planned-sessions", "planned_session", revision);
  const programmes = useFitnessCollection<FitnessTrainingProgramme>("/fitness/training-programmes", "training_programme", revision);
  const [managedSession, setManagedSession] = useState<FitnessPlannedSession | null>(null);
  const [managePanel, setManagePanel] = useState<ManagePanel>(initialManagePanel);
  const [manageOpen, setManageOpen] = useState(() => initialManagePanel() !== null);
  const week = useMemo(currentWeek, []);
  const today = localDateValue();
  const ordered = useMemo(() => [...sessions.data].sort((left, right) => (left.scheduled_start_utc ?? left.time_window_start_utc ?? left.scheduled_date ?? "").localeCompare(right.scheduled_start_utc ?? right.time_window_start_utc ?? right.scheduled_date ?? "")), [sessions.data]);
  const upcoming = ordered.filter((session) => ["proposed", "accepted", "scheduled", "in_progress"].includes(session.status) && (!sessionDate(session) || sessionDate(session) >= today));
  const nextSession = upcoming.find((session) => ["accepted", "scheduled", "in_progress"].includes(session.status)) ?? upcoming[0] ?? null;
  const loading = sessions.loading || programmes.loading;
  const error = sessions.error ?? programmes.error;

  useEffect(() => {
    if (sessions.loading || managedSession) return;
    const target = new URLSearchParams(window.location.search).get("session");
    if (!target) return;
    const match = sessions.data.find((session) => session.id === target);
    if (match) setManagedSession(match);
  }, [managedSession, sessions.data, sessions.loading]);

  function changeManagePanel(next: ManagePanel) {
    setManagePanel(next);
    const url = new URL(window.location.href);
    if (next) url.searchParams.set("fitness-plan-manage", next);
    else url.searchParams.delete("fitness-plan-manage");
    window.history.replaceState(window.history.state, "", url);
  }

  function openSession(session: FitnessPlannedSession) {
    const url = new URL(window.location.href);
    url.searchParams.set("session", session.id);
    window.history.replaceState(window.history.state, "", url);
    setManagedSession(session);
  }

  return <section aria-label="Sessions" className="fitness-wave4__plan fitness-sessions">
    <FitnessPageHeading title="Sessions" detail="Plan ahead or log what you did. Only add the detail that helps." actions={onOpenCalendar ? <button type="button" className="button button--secondary button--compact" onClick={onOpenCalendar}><CalendarDays aria-hidden="true" size={17} /> Calendar</button> : undefined} />
    <FitnessLoadingOrError loading={loading} error={error} retry={() => { sessions.reload(); programmes.reload(); }} />

    {!loading && !error ? <>
      <FitnessSessionLauncher online={online} revision={revision} programmes={programmes.data} onDataChanged={onDataChanged} onOpenStrength={() => onSectionChange("strength")} />

      <FitnessCard className="fitness-wave4__next-session">
        <div className="fitness-wave4__eyebrow">Up next</div>
        {nextSession ? <div className="fitness-wave4__next-session-body"><div><h3>{nextSession.title}</h3><p>{humanSport(nextSession.sport_key)} · {formatFitnessDateTime(nextSession.scheduled_start_utc ?? nextSession.time_window_start_utc ?? nextSession.scheduled_date)}{nextSession.expected_duration_s ? ` · ${Math.round(nextSession.expected_duration_s / 60)} min` : ""}{nextSession.expected_pace_s_per_km ? ` · ${Math.floor(nextSession.expected_pace_s_per_km / 60)}:${String(Math.round(nextSession.expected_pace_s_per_km % 60)).padStart(2, "0")}/km` : ""}</p></div><div className="fitness-module__button-row">{nextSession.sport_key === "strength" && ["accepted", "scheduled", "in_progress"].includes(nextSession.status) ? <button type="button" className="button button--primary" onClick={() => startStrengthPlan(nextSession, onSectionChange)}>Start</button> : <button type="button" className="button button--primary" onClick={() => openSession(nextSession)}>Open</button>}{nextSession.movable !== false ? <button type="button" className="button button--secondary" onClick={() => openSession(nextSession)}>Move</button> : null}</div></div> : <div className="fitness-module__empty"><CalendarPlus aria-hidden="true" size={26} /><strong>Nothing planned yet</strong><span>That is fine. Choose an activity above when you are ready.</span></div>}
      </FitnessCard>

      <section className="fitness-wave4__week" aria-labelledby="plan-week-title"><header><div><span>This week</span><h3 id="plan-week-title">Seven days at a glance</h3></div><small>{formatFitnessDate(week[0].date)} – {formatFitnessDate(week[6].date)}</small></header><ol>{week.map((day) => {
        const daySessions = ordered.filter((session) => sessionDate(session) === day.date && session.status !== "cancelled");
        return <li className={cn(day.today && "is-today")} key={day.date}><div><span>{day.weekday}</span><strong>{day.day}</strong></div>{daySessions.length ? <div>{daySessions.map((session) => <button type="button" aria-label={`Open ${session.title} on ${formatFitnessDate(day.date)}`} onClick={() => openSession(session)} key={session.id}><span>{session.title}</span><small>{session.expected_duration_s ? `${Math.round(session.expected_duration_s / 60)} min` : humanSport(session.sport_key)}</small></button>)}</div> : <span className="fitness-wave4__rest-day">Open</span>}</li>;
      })}</ol></section>

      {managedSession ? <SessionEditorPanel session={managedSession} programmes={programmes.data} revision={revision} onDataChanged={onDataChanged} onClose={() => setManagedSession(null)} onSectionChange={onSectionChange} /> : null}

      <section className="fitness-wave4__programmes" aria-labelledby="plan-programmes-title"><header><div><span>Programmes</span><h3 id="plan-programmes-title">The longer view</h3></div><button type="button" className="button button--secondary button--compact" onClick={() => { setManageOpen(true); changeManagePanel("programmes"); }}>Manage programmes</button></header>{programmes.data.length ? <div>{programmes.data.map((programme) => {
        const programmeSessions = ordered.filter((session) => session.training_programme_id === programme.id);
        const strengthCount = programmeSessions.filter((session) => session.sport_key === "strength").length;
        const runningCount = programmeSessions.filter((session) => session.sport_key === "running").length;
        return <article key={programme.id}><div><h4>{programme.name}</h4><p>{programme.purpose ?? "A saved block of training."}</p><small>{formatFitnessDate(programme.starts_on)}{programme.ends_on ? ` – ${formatFitnessDate(programme.ends_on)}` : " onwards"}</small></div><dl><div><dt>Strength</dt><dd>{strengthCount}</dd></div><div><dt>Running</dt><dd>{runningCount}</dd></div><div><dt>Total</dt><dd>{programmeSessions.length}</dd></div></dl></article>;
      })}</div> : <div className="fitness-module__empty"><Layers3 aria-hidden="true" size={24} /><strong>No programme yet</strong><span>Individual sessions work perfectly well on their own.</span><button type="button" className="button button--secondary" onClick={() => { setManageOpen(true); changeManagePanel("programmes"); }}>Create a programme</button></div>}<div className="fitness-wave4__programme-links"><button type="button" onClick={() => onSectionChange("strength")}><Dumbbell aria-hidden="true" size={18} /><span><strong>Strength mode</strong><small>Start, log and review strength work</small></span><ChevronRight aria-hidden="true" size={18} /></button><button type="button" onClick={() => { setManageOpen(true); changeManagePanel("runs"); }}><Footprints aria-hidden="true" size={18} /><span><strong>Running plans</strong><small>Build and reuse structured runs</small></span><ChevronRight aria-hidden="true" size={18} /></button></div></section>

      <details className="fitness-module__maintenance fitness-wave4__plan-manage" open={manageOpen} onToggle={(event) => { setManageOpen(event.currentTarget.open); if (event.currentTarget.open && !managePanel) changeManagePanel("goals"); }}><summary><SlidersHorizontal aria-hidden="true" size={17} /> Goals and training tools</summary>{manageOpen ? <div className="fitness-module__maintenance-body"><TrainingManage panel={managePanel ?? "goals"} onPanelChange={changeManagePanel} revision={revision} online={online} sessions={sessions.data} programmes={programmes.data} onDataChanged={onDataChanged} /></div> : null}</details>
    </> : null}
  </section>;
}
