import { AlertTriangle, CalendarCheck2, Check, Plus, Repeat2, Route, Trash2 } from "lucide-react";
import { useEffect, useMemo, useState } from "react";

import { api } from "../../api";
import type {
  FitnessActivitySummary,
  FitnessBodyIssue,
  FitnessGoal,
  FitnessRunDurationType,
  FitnessRunTargetType,
  FitnessRunWorkoutCue,
  FitnessRunWorkoutStep,
  FitnessTrainingProgramme,
  FitnessWorkoutDefinition,
  FitnessWorkoutVersion,
} from "../../fitness/contract";
import {
  paceTextFromSeconds,
  secondsFromPaceText,
  validateFitnessRunPlan,
} from "../../fitness/runPlanSemantics";
import type { SaveFitnessRecordInput } from "../../fitness/offlineStore";
import {
  FitnessCard,
  FitnessFormStatus,
  errorMessage,
  formatFitnessDateTime,
  localDateTimeValue,
  localDateValue,
  localTimeZone,
  useFitnessBatchSave,
} from "./shared";

function newLeaf(name = "Warm-up"): FitnessRunWorkoutStep {
  return {
    id: crypto.randomUUID(),
    sequence: 0,
    step_kind: "step",
    duration_type: "distance_m",
    duration_value: 1000,
    target_type: "pace_s_per_km",
    target_low: 330,
    target_high: 360,
    target_unit: "s/km",
    intensity_label: "easy",
    display_name: name,
    instruction_text: "Settle into the planned rhythm.",
    mental_cue_text: "Relax shoulders and run tall.",
    spoken_cue_text: null,
    allow_manual_advance: false,
  };
}

function newRepeatBlock(): FitnessRunWorkoutStep {
  return {
    id: crypto.randomUUID(),
    sequence: 0,
    step_kind: "repeat_block",
    repeat_count: 4,
    duration_type: "open",
    duration_value: null,
    target_type: "none",
    display_name: "4 × work and recovery",
    children: [
      { ...newLeaf("Work"), id: crypto.randomUUID(), duration_type: "time_s", duration_value: 180, target_type: "pace_s_per_km", target_low: 270, target_high: 285, intensity_label: "threshold" },
      { ...newLeaf("Recovery"), id: crypto.randomUUID(), duration_type: "time_s", duration_value: 120, target_type: "none", target_low: null, target_high: null, target_unit: null, intensity_label: "recovery" },
    ],
  };
}

function updateNestedStep(
  steps: FitnessRunWorkoutStep[],
  id: string,
  update: Partial<FitnessRunWorkoutStep>,
): FitnessRunWorkoutStep[] {
  return steps.map((step) => step.id === id
    ? { ...step, ...update }
    : { ...step, children: step.children ? updateNestedStep(step.children, id, update) : undefined });
}

function removeNestedStep(steps: FitnessRunWorkoutStep[], id: string): FitnessRunWorkoutStep[] {
  return steps
    .filter((step) => step.id !== id)
    .map((step) => ({ ...step, children: step.children ? removeNestedStep(step.children, id) : undefined }));
}

function sequenceSteps(steps: FitnessRunWorkoutStep[], parentId: string | null = null): FitnessRunWorkoutStep[] {
  return steps.map((step, index) => ({
    ...step,
    parent_step_id: parentId,
    sequence: index,
    children: step.children ? sequenceSteps(step.children, step.id) : undefined,
  }));
}

function cloneRunStepsForDraft(
  steps: FitnessRunWorkoutStep[],
  idMap: Map<string, string>,
): FitnessRunWorkoutStep[] {
  return steps.map((step) => {
    const nextId = crypto.randomUUID();
    idMap.set(step.id, nextId);
    return {
      ...step,
      id: nextId,
      parent_step_id: null,
      children: step.children ? cloneRunStepsForDraft(step.children, idMap) : undefined,
    };
  });
}

function DurationEditor({ step, onChange }: { step: FitnessRunWorkoutStep; onChange: (update: Partial<FitnessRunWorkoutStep>) => void }) {
  const displayValue = step.duration_type === "distance_m"
    ? (step.duration_value ?? 0) / 1000
    : step.duration_type === "time_s"
      ? (step.duration_value ?? 0) / 60
      : step.duration_value ?? "";
  return <>
    <label className="fitness-module__field">Duration type<select value={step.duration_type} onChange={(event) => onChange({ duration_type: event.target.value as FitnessRunDurationType, duration_value: ["open", "lap_button"].includes(event.target.value) ? null : step.duration_value ?? 1 })}><option value="distance_m">Distance</option><option value="time_s">Time</option><option value="lap_button">Lap button</option><option value="open">Open</option><option value="calories">Calories</option></select></label>
    {!['open', 'lap_button'].includes(step.duration_type) ? <label className="fitness-module__field">{step.duration_type === "distance_m" ? "Kilometres" : step.duration_type === "time_s" ? "Minutes" : "Calories"}<input type="number" min="0.01" step={step.duration_type === "distance_m" ? "0.05" : "0.5"} inputMode="decimal" value={displayValue} onChange={(event) => { const value = Number(event.target.value); onChange({ duration_value: step.duration_type === "distance_m" ? value * 1000 : step.duration_type === "time_s" ? value * 60 : value }); }} /></label> : null}
  </>;
}

function TargetEditor({ step, onChange }: { step: FitnessRunWorkoutStep; onChange: (update: Partial<FitnessRunWorkoutStep>) => void }) {
  const pace = step.target_type === "pace_s_per_km";
  const [lowPaceText, setLowPaceText] = useState(paceTextFromSeconds(step.target_low).replace("/km", ""));
  const [highPaceText, setHighPaceText] = useState(paceTextFromSeconds(step.target_high).replace("/km", ""));
  useEffect(() => {
    setLowPaceText(paceTextFromSeconds(step.target_low).replace("/km", ""));
    setHighPaceText(paceTextFromSeconds(step.target_high).replace("/km", ""));
  }, [step.target_high, step.target_low, step.target_type]);
  const targetUnits: Record<FitnessRunTargetType, string | null> = {
    pace_s_per_km: "s/km",
    heart_rate_bpm: "bpm",
    heart_rate_zone: "zone",
    power_w: "W",
    power_zone: "zone",
    cadence_spm: "spm",
    rpe: "rpe",
    none: null,
  };
  return <>
    <label className="fitness-module__field">Target<select value={step.target_type} onChange={(event) => { const type = event.target.value as FitnessRunTargetType; onChange({ target_type: type, target_low: type === "none" ? null : step.target_low ?? 1, target_high: type === "none" ? null : step.target_high ?? 1, target_unit: targetUnits[type] }); }}><option value="none">No target</option><option value="pace_s_per_km">Pace</option><option value="heart_rate_bpm">Heart rate</option><option value="heart_rate_zone">HR zone</option><option value="power_w">Power</option><option value="power_zone">Power zone</option><option value="cadence_spm">Cadence</option><option value="rpe">RPE</option></select></label>
    {step.target_type !== "none" ? <><label className="fitness-module__field">Target from<input type={pace ? "text" : "number"} inputMode={pace ? "numeric" : "decimal"} placeholder={pace ? "5:15" : undefined} value={pace ? lowPaceText : step.target_low ?? ""} onChange={(event) => pace ? setLowPaceText(event.target.value) : onChange({ target_low: Number(event.target.value) })} onBlur={() => { if (!pace) return; const seconds = secondsFromPaceText(lowPaceText); if (seconds != null) onChange({ target_low: seconds }); else setLowPaceText(paceTextFromSeconds(step.target_low).replace("/km", "")); }} /></label><label className="fitness-module__field">Target to<input type={pace ? "text" : "number"} inputMode={pace ? "numeric" : "decimal"} placeholder={pace ? "5:30" : undefined} value={pace ? highPaceText : step.target_high ?? ""} onChange={(event) => pace ? setHighPaceText(event.target.value) : onChange({ target_high: Number(event.target.value) })} onBlur={() => { if (!pace) return; const seconds = secondsFromPaceText(highPaceText); if (seconds != null) onChange({ target_high: seconds }); else setHighPaceText(paceTextFromSeconds(step.target_high).replace("/km", "")); }} /></label></> : null}
  </>;
}

function StepEditor({
  step,
  nested = false,
  onChange,
  onRemove,
}: {
  step: FitnessRunWorkoutStep;
  nested?: boolean;
  onChange: (id: string, update: Partial<FitnessRunWorkoutStep>) => void;
  onRemove: (id: string) => void;
}) {
  return <article className={cnStep(nested)}>
    <header><strong>{step.step_kind === "repeat_block" ? <Repeat2 aria-hidden="true" size={17} /> : <Route aria-hidden="true" size={17} />}{step.display_name || "Unnamed step"}</strong><button type="button" className="button button--secondary" aria-label={`Remove ${step.display_name || "step"}`} onClick={() => onRemove(step.id)}><Trash2 aria-hidden="true" size={15} /></button></header>
    <div className="fitness-module__fields">
      <label className="fitness-module__field is-wide">Step name<input value={step.display_name} onChange={(event) => onChange(step.id, { display_name: event.target.value })} /></label>
      {step.step_kind === "repeat_block" ? <label className="fitness-module__field">Repeat count<input type="number" min="1" max="100" inputMode="numeric" value={step.repeat_count ?? 1} onChange={(event) => onChange(step.id, { repeat_count: Number(event.target.value) })} /></label> : <><DurationEditor step={step} onChange={(update) => onChange(step.id, update)} /><TargetEditor step={step} onChange={(update) => onChange(step.id, update)} /><label className="fitness-module__field">Intensity label<input value={step.intensity_label ?? ""} onChange={(event) => onChange(step.id, { intensity_label: event.target.value })} placeholder="easy, threshold…" /></label><label className="fitness-module__field is-wide">Instruction<input value={step.instruction_text ?? ""} onChange={(event) => onChange(step.id, { instruction_text: event.target.value })} /></label><label className="fitness-module__field is-wide">Mental cue<input value={step.mental_cue_text ?? ""} onChange={(event) => onChange(step.id, { mental_cue_text: event.target.value })} /></label><label className="fitness-module__field is-wide">Intended spoken cue<input value={step.spoken_cue_text ?? ""} onChange={(event) => onChange(step.id, { spoken_cue_text: event.target.value })} placeholder="Retained in HausKlar; Garmin support may omit it" /></label></>}
    </div>
    {step.children?.map((child) => <StepEditor step={child} nested onChange={onChange} onRemove={onRemove} key={child.id} />)}
    {step.step_kind === "repeat_block" ? <button type="button" className="button button--secondary" onClick={() => onChange(step.id, { children: [...(step.children ?? []), newLeaf(`Step ${(step.children?.length ?? 0) + 1}`)] })}><Plus aria-hidden="true" size={15} /> Child step</button> : null}
  </article>;
}

function cnStep(nested: boolean): string {
  return nested ? "fitness-module__run-step is-nested" : "fitness-module__run-step";
}

export function FitnessRunPlanEditor({
  goals,
  programmes,
  definitions = [],
  onClose,
  onAccepted,
}: {
  goals: FitnessGoal[];
  programmes: FitnessTrainingProgramme[];
  definitions?: FitnessWorkoutDefinition[];
  onClose: () => void;
  onAccepted: () => void;
}) {
  const save = useFitnessBatchSave(onAccepted);
  const [definitionId, setDefinitionId] = useState("");
  const [title, setTitle] = useState("Progression run");
  const [purpose, setPurpose] = useState("");
  const [expectedDifficulty, setExpectedDifficulty] = useState("Moderate");
  const [routeAssumptions, setRouteAssumptions] = useState("");
  const [scheduledType, setScheduledType] = useState<"exact" | "window" | "date">("exact");
  const [scheduledAt, setScheduledAt] = useState(localDateTimeValue(new Date(Date.now() + 86_400_000)));
  const [windowEnd, setWindowEnd] = useState(localDateTimeValue(new Date(Date.now() + 90_000_000)));
  const [scheduledDate, setScheduledDate] = useState(localDateValue(new Date(Date.now() + 86_400_000)));
  const [goalId, setGoalId] = useState("");
  const [programmeId, setProgrammeId] = useState("");
  const [reason, setReason] = useState("");
  const [movable, setMovable] = useState(true);
  const [shareLogistics, setShareLogistics] = useState(false);
  const [sharedTitle, setSharedTitle] = useState("Running");
  const [steps, setSteps] = useState<FitnessRunWorkoutStep[]>([newLeaf("Warm-up"), { ...newLeaf("Main run"), id: crypto.randomUUID(), duration_value: 5000, target_low: 300, target_high: 330 }, { ...newLeaf("Cool-down"), id: crypto.randomUUID(), target_type: "none", target_low: null, target_high: null, target_unit: null }]);
  const [cues, setCues] = useState<FitnessRunWorkoutCue[]>([]);
  const [kilometres, setKilometres] = useState("5");
  const [contextReviewed, setContextReviewed] = useState(false);
  const [activeIssues, setActiveIssues] = useState<FitnessBodyIssue[]>([]);
  const [recentRuns, setRecentRuns] = useState<FitnessActivitySummary[]>([]);
  const [contextError, setContextError] = useState<string | null>(null);
  const [submitted, setSubmitted] = useState(false);

  useEffect(() => {
    let active = true;
    void Promise.all([
      api<FitnessBodyIssue[]>("/fitness/body-issues?status=active", {}, true, false).catch(() => []),
      api<FitnessActivitySummary[]>("/fitness/activities?sport_key=running&limit=12&offset=0", {}, true, false).catch((error) => { throw error; }),
    ]).then(([issues, runs]) => {
      if (active) { setActiveIssues(issues); setRecentRuns(runs); }
    }).catch((error) => { if (active) setContextError(errorMessage(error)); });
    return () => { active = false; };
  }, []);

  const normalizedSteps = useMemo(() => sequenceSteps(steps), [steps]);
  const validation = validateFitnessRunPlan(normalizedSteps, { planningContextReviewed: contextReviewed });
  const recentLongestRunM = Math.max(0, ...recentRuns.map((run) => run.distance_m ?? 0));
  const unusuallyDemanding = recentLongestRunM > 0 && validation.totals.distanceM > recentLongestRunM * 1.25;

  function selectedVersion(definition: FitnessWorkoutDefinition): FitnessWorkoutVersion | null {
    return definition.current_version ?? definition.version ?? definition.versions?.at(-1) ?? null;
  }

  function chooseDefinition(nextId: string) {
    setDefinitionId(nextId);
    const definition = definitions.find((item) => item.id === nextId);
    if (!definition) return;
    const version = selectedVersion(definition);
    setTitle(version?.title ?? definition.name);
    setPurpose(version?.purpose ?? definition.description ?? "");
    const structured = version?.structured_summary as { run_steps?: FitnessRunWorkoutStep[]; run_cues?: FitnessRunWorkoutCue[]; expected_difficulty?: string; route_assumptions?: string | null } | undefined;
    const previousSteps = version?.run_steps ?? structured?.run_steps;
    const idMap = new Map<string, string>();
    if (previousSteps?.length) setSteps(cloneRunStepsForDraft(previousSteps, idMap));
    setCues((version?.run_cues ?? structured?.run_cues ?? []).map((cue) => ({ ...cue, id: crypto.randomUUID(), step_id: cue.step_id ? idMap.get(cue.step_id) ?? null : null })));
    setExpectedDifficulty(structured?.expected_difficulty ?? "Moderate");
    setRouteAssumptions(structured?.route_assumptions ?? "");
  }

  function updateStep(id: string, update: Partial<FitnessRunWorkoutStep>) {
    setSteps((current) => updateNestedStep(current, id, update));
  }

  function makeKilometreSequence() {
    const count = Math.min(50, Math.max(1, Number(kilometres)));
    setSteps(Array.from({ length: count }, (_, index) => ({
      ...newLeaf(`Kilometre ${index + 1}`),
      id: crypto.randomUUID(),
      kilometre_index: index + 1,
      target_low: 330 - Math.min(index * 5, 45),
      target_high: 345 - Math.min(index * 5, 45),
      instruction_text: index === 0 ? "Start deliberately under control." : "Hold the planned rhythm without chasing the watch.",
      mental_cue_text: index === count - 1 ? "Run tall and finish with intent." : "Relax shoulders. Quick, quiet feet.",
    })));
  }

  async function acceptPlan() {
    setSubmitted(true);
    if (validation.errors.length || !title.trim()) return;
    const existingDefinition = definitions.find((item) => item.id === definitionId);
    const acceptedDefinitionId = existingDefinition?.id ?? crypto.randomUUID();
    const versionId = crypto.randomUUID();
    const sessionId = crypto.randomUUID();
    const acceptedAt = new Date().toISOString();
    const version = {
      id: versionId,
      title: title.trim(),
      purpose: purpose.trim() || null,
      estimated_duration_s: validation.totals.durationS || null,
      estimated_distance_m: validation.totals.distanceM || null,
      structured_summary: {
        schema: "run_plan_v1",
        run_steps: normalizedSteps,
        run_cues: cues,
        expected_difficulty: expectedDifficulty,
        route_assumptions: routeAssumptions.trim() || null,
        totals: validation.totals,
      },
      version_source: "user",
      exercise_items: [],
      run_steps: normalizedSteps,
      run_cues: cues,
      accepted_at: acceptedAt,
    };
    const sessionSchedule = scheduledType === "exact"
      ? { scheduled_start_utc: new Date(scheduledAt).toISOString(), scheduled_date: scheduledAt.slice(0, 10), time_window_start_utc: null, time_window_end_utc: null }
      : scheduledType === "window"
        ? { scheduled_start_utc: null, scheduled_date: scheduledAt.slice(0, 10), time_window_start_utc: new Date(scheduledAt).toISOString(), time_window_end_utc: new Date(windowEnd).toISOString() }
        : { scheduled_start_utc: null, scheduled_date: scheduledDate, time_window_start_utc: null, time_window_end_utc: null };
    const inputs: SaveFitnessRecordInput[] = [
      { entityType: "workout_definition", payload: { id: acceptedDefinitionId, sport_key: "running", name: existingDefinition?.name ?? title.trim(), description: purpose.trim() || null, active: true, version }, options: { entityId: acceptedDefinitionId, baseRevision: existingDefinition?.revision ?? null } },
      { entityType: "planned_session", payload: {
        id: sessionId,
        sport_key: "running",
        title: title.trim(),
        status: "accepted",
        session_source: "user",
        local_timezone: localTimeZone(),
        training_programme_id: programmeId || null,
        workout_version_id: versionId,
        expected_duration_s: validation.totals.durationS || null,
        expected_distance_m: validation.totals.distanceM || null,
        priority: 1,
        movable,
        visibility: shareLogistics ? "logistics_shared" : "private",
        shared_title: shareLogistics ? sharedTitle.trim() || "Running" : null,
        reason_for_placement: reason.trim() || null,
        goal_links: goalId ? [{ goal_id: goalId, role: "primary" }] : [],
        exercise_items: [],
        ...sessionSchedule,
      } },
    ];
    await save.save(inputs);
    onClose();
  }

  return <div className="fitness-module__run-plan-editor">
    <FitnessCard title="Build an executable run" detail="Nothing is saved until you accept this review. An accepted plan stays exactly as agreed; later changes create a new version.">
      <div className="fitness-module__fields">
        <label className="fitness-module__field is-wide">Workout identity<select value={definitionId} onChange={(event) => chooseDefinition(event.target.value)}><option value="">Create a new reusable workout</option>{definitions.filter((definition) => definition.sport_key === "running" && definition.active !== false).map((definition) => <option value={definition.id} key={definition.id}>New version of {definition.name}</option>)}</select><small>Loading an existing workout creates a new accepted version; the previous accepted snapshot remains unchanged.</small></label>
        <label className="fitness-module__field is-wide">Workout title<input autoFocus required value={title} onChange={(event) => setTitle(event.target.value)} /></label>
        <label className="fitness-module__field is-wide">Purpose<textarea value={purpose} onChange={(event) => setPurpose(event.target.value)} placeholder="Why this supports the active goal" /></label>
        <label className="fitness-module__field">Expected difficulty<input value={expectedDifficulty} onChange={(event) => setExpectedDifficulty(event.target.value)} /></label>
        <label className="fitness-module__field is-wide">Route or terrain assumptions<input value={routeAssumptions} onChange={(event) => setRouteAssumptions(event.target.value)} placeholder="Flat loop; avoid steep descent…" /></label>
      </div>
    </FitnessCard>

    <FitnessCard title="Steps and cues" detail={`${(validation.totals.distanceM / 1000).toFixed(2)} km · ${Math.round(validation.totals.durationS / 60)} fixed minutes${validation.totals.hasOpenDuration ? " · plus open steps" : ""}`}>
      <div className="fitness-module__button-row"><button type="button" className="button button--secondary" onClick={() => setSteps((current) => [...current, newLeaf(`Step ${current.length + 1}`)])}><Plus aria-hidden="true" size={16} /> Step</button><button type="button" className="button button--secondary" onClick={() => setSteps((current) => [...current, newRepeatBlock()])}><Repeat2 aria-hidden="true" size={16} /> Repeat block</button><label className="fitness-module__inline-field">Kilometres<input type="number" min="1" max="50" value={kilometres} onChange={(event) => setKilometres(event.target.value)} /></label><button type="button" className="button button--secondary" onClick={makeKilometreSequence}>Create 1 km steps</button></div>
      <div className="fitness-module__run-steps">{normalizedSteps.map((step) => <StepEditor step={step} onChange={updateStep} onRemove={(id) => setSteps((current) => removeNestedStep(current, id))} key={step.id} />)}</div>
      <div className="fitness-module__run-cues"><header><strong>Independent cue events</strong><button type="button" className="button button--secondary" onClick={() => setCues((current) => [...current, { id: crypto.randomUUID(), sequence: current.length, trigger_type: "halfway", trigger_value: null, short_text: "Reset posture and breathing", spoken_text: null, priority: 1 }])}><Plus aria-hidden="true" size={15} /> Cue</button></header>{cues.map((cue) => <div className="fitness-module__fields" key={cue.id}><label className="fitness-module__field">Trigger<select value={cue.trigger_type} onChange={(event) => setCues((current) => current.map((item) => item.id === cue.id ? { ...item, trigger_type: event.target.value as FitnessRunWorkoutCue["trigger_type"] } : item))}><option value="workout_start">Workout start</option><option value="halfway">Halfway</option><option value="final_kilometre">Final kilometre</option><option value="distance_from_workout_start_m">Distance from start</option><option value="time_from_workout_start_s">Time from start</option><option value="manual">Manual</option></select></label><label className="fitness-module__field is-wide">Short cue<input value={cue.short_text} onChange={(event) => setCues((current) => current.map((item) => item.id === cue.id ? { ...item, short_text: event.target.value } : item))} /></label><button type="button" className="button button--secondary" aria-label="Remove cue" onClick={() => setCues((current) => current.filter((item) => item.id !== cue.id))}><Trash2 aria-hidden="true" size={15} /></button></div>)}</div>
    </FitnessCard>

    <FitnessCard title="Place the accepted version" detail="The private Fitness layer supports exact times, windows, and date-only sessions.">
      <div className="fitness-module__choice-grid" role="group" aria-label="Scheduling precision">{(["exact", "window", "date"] as const).map((value) => <button type="button" className={scheduledType === value ? "is-active" : undefined} aria-pressed={scheduledType === value} onClick={() => setScheduledType(value)} key={value}>{value === "date" ? "Date only" : value === "window" ? "Time window" : "Exact time"}</button>)}</div>
      <div className="fitness-module__fields">
        {scheduledType === "date" ? <label className="fitness-module__field">Date<input type="date" value={scheduledDate} onChange={(event) => setScheduledDate(event.target.value)} /></label> : <label className="fitness-module__field">{scheduledType === "window" ? "Window starts" : "Starts"}<input type="datetime-local" value={scheduledAt} onChange={(event) => setScheduledAt(event.target.value)} /></label>}
        {scheduledType === "window" ? <label className="fitness-module__field">Window ends<input type="datetime-local" min={scheduledAt} value={windowEnd} onChange={(event) => setWindowEnd(event.target.value)} /></label> : null}
        <label className="fitness-module__field">Primary goal<select value={goalId} onChange={(event) => setGoalId(event.target.value)}><option value="">No primary goal</option>{goals.filter((goal) => goal.status === "active").map((goal) => <option value={goal.id} key={goal.id}>{goal.name}</option>)}</select></label>
        <label className="fitness-module__field">Programme<select value={programmeId} onChange={(event) => setProgrammeId(event.target.value)}><option value="">No programme</option>{programmes.filter((programme) => programme.status === "active").map((programme) => <option value={programme.id} key={programme.id}>{programme.name}</option>)}</select></label>
        <label className="fitness-module__field is-wide">Placement reason<input value={reason} onChange={(event) => setReason(event.target.value)} /></label>
        <label className="fitness-module__check"><input type="checkbox" checked={movable} onChange={(event) => setMovable(event.target.checked)} /> Session can move</label>
        <label className="fitness-module__check"><input type="checkbox" checked={shareLogistics} onChange={(event) => setShareLogistics(event.target.checked)} /> Publish logistics only to the family calendar</label>
        {shareLogistics ? <label className="fitness-module__field">Shared title<input value={sharedTitle} onChange={(event) => setSharedTitle(event.target.value)} /><small>Only this title and the approved time are shared.</small></label> : null}
      </div>
    </FitnessCard>

    <FitnessCard title="Review current context" detail="This is a consistency review, not diagnosis or opaque safety scoring.">
      {contextError ? <div className="fitness-module__notice fitness-module__notice--error" role="alert">{contextError}</div> : null}
      <div className="fitness-module__grid">
        <div><strong>Recent running</strong>{recentRuns.length ? <ul className="fitness-module__list">{recentRuns.slice(0, 4).map((run) => <li key={run.id}><div><strong>{run.title}</strong><small>{formatFitnessDateTime(run.started_at_utc)}</small></div><span>{run.distance_m != null ? `${(run.distance_m / 1000).toFixed(1)} km` : "—"}</span></li>)}</ul> : <p>No recent run evidence is available.</p>}</div>
        <div><strong>Active body issues</strong>{activeIssues.length ? <ul className="fitness-module__list">{activeIssues.map((issue) => <li key={issue.id}><div><strong>{issue.body_location_key.replaceAll("_", " ")} · {issue.severity_0_10}/10</strong><small>{issue.changed_session ? `Changed session: ${issue.session_change_key.replaceAll("_", " ")}` : "Did not change recorded session"}</small></div><AlertTriangle aria-hidden="true" size={17} /></li>)}</ul> : <p>No active structured issue is recorded.</p>}</div>
      </div>
      {unusuallyDemanding ? <div className="fitness-module__notice" role="status"><AlertTriangle aria-hidden="true" size={17} /> This plan is more than 25% longer than the longest recent run shown ({(recentLongestRunM / 1000).toFixed(1)} km). You can still accept it after review.</div> : null}
      <label className="fitness-module__check fitness-module__review-check"><input type="checkbox" checked={contextReviewed} onChange={(event) => setContextReviewed(event.target.checked)} /> I reviewed the recent running, active issues, plan totals, target ranges, and Garmin limitations.</label>
    </FitnessCard>

    <FitnessCard title="Garmin mapping preview" detail="Standard FIT can represent ordered steps, durations, targets, and finite repeats. Watch display and audio cues still need checking on the Forerunner 970.">
      <ul className="fitness-module__list"><li><div><strong>Structured steps and target ranges</strong><small>Included in the Garmin FIT adapter.</small></div><Check aria-hidden="true" size={18} /></li><li><div><strong>Custom mental and spoken cues</strong><small>Retained in HausKlar; may be shortened or omitted from standard FIT.</small></div><AlertTriangle aria-hidden="true" size={18} /></li></ul>
      {validation.warnings.map((warning) => <p className="fitness-module__privacy-note" key={warning}><AlertTriangle aria-hidden="true" size={16} /> {warning}</p>)}
    </FitnessCard>

    {submitted && validation.errors.length ? <div className="fitness-module__notice fitness-module__notice--error" role="alert"><strong>Review the plan before acceptance</strong><ul>{validation.errors.map((error) => <li key={error}>{error}</li>)}</ul></div> : null}
    <div className="fitness-module__form-footer"><button type="button" className="button button--primary" disabled={save.saving || !title.trim()} onClick={() => void acceptPlan()}><CalendarCheck2 aria-hidden="true" size={17} /> Accept and schedule</button><button type="button" className="button button--secondary" onClick={onClose}>Discard draft</button><FitnessFormStatus saving={save.saving} saved={save.saved} error={save.saveError} /></div>
  </div>;
}
