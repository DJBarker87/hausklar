import { Ban, Check, Play, Save, SkipForward } from "lucide-react";
import { useMemo, useState } from "react";

import { ConfirmDialog } from "../../components/ui";
import type {
  FitnessGearItem,
  FitnessGoal,
  FitnessPlannedSession,
  FitnessTrainingProgramme,
  FitnessWorkoutDefinition,
  FitnessWorkoutVersion,
} from "../../fitness/contract";
import { strengthWorkoutVersion } from "../../fitness/strengthWorkout";
import {
  FitnessCard,
  FitnessFormStatus,
  localDateTimeValue,
  localDateValue,
  localTimeZone,
  useFitnessSave,
} from "./shared";

function localInputFromUtc(value?: string | null): string {
  if (!value) return localDateTimeValue();
  const date = new Date(value);
  if (Number.isNaN(date.valueOf())) return localDateTimeValue();
  return localDateTimeValue(date);
}

function latestVersionId(definition: FitnessWorkoutDefinition): string | null {
  return definition.current_version?.id ?? definition.version?.id ?? definition.versions?.at(-1)?.id ?? null;
}

export function FitnessPlannedSessionEditor({
  session,
  goals,
  programmes,
  definitions,
  gear,
  onDataChanged,
  onClose,
  onStartStrength,
}: {
  session: FitnessPlannedSession;
  goals: FitnessGoal[];
  programmes: FitnessTrainingProgramme[];
  definitions: FitnessWorkoutDefinition[];
  gear: FitnessGearItem[];
  onDataChanged: () => void;
  onClose: () => void;
  onStartStrength: () => void;
}) {
  const save = useFitnessSave(onDataChanged);
  const checkinSave = useFitnessSave(onDataChanged);
  const initialPrecision = session.scheduled_start_utc ? "exact" : session.time_window_start_utc ? "window" : "date";
  const [title, setTitle] = useState(session.title);
  const [precision, setPrecision] = useState<"exact" | "window" | "date">(initialPrecision);
  const [startsAt, setStartsAt] = useState(localInputFromUtc(session.scheduled_start_utc ?? session.time_window_start_utc));
  const [windowEnd, setWindowEnd] = useState(localInputFromUtc(session.time_window_end_utc ?? new Date(Date.now() + 3_600_000).toISOString()));
  const [date, setDate] = useState(session.scheduled_date ?? localDateValue());
  const [durationMinutes, setDurationMinutes] = useState(session.expected_duration_s ? String(Math.round(session.expected_duration_s / 60)) : "");
  const [distanceKm, setDistanceKm] = useState(session.expected_distance_m ? String(session.expected_distance_m / 1000) : "");
  const [movable, setMovable] = useState(session.movable !== false);
  const [visibility, setVisibility] = useState<"private" | "logistics_shared">(session.visibility === "logistics_shared" ? "logistics_shared" : "private");
  const [sharedTitle, setSharedTitle] = useState(session.shared_title ?? (session.sport_key === "running" ? "Running" : "Training"));
  const [goalId, setGoalId] = useState(session.goal_links?.find((link) => link.role === "primary")?.goal_id ?? "");
  const [programmeId, setProgrammeId] = useState(session.training_programme_id ?? "");
  const [workoutVersionId, setWorkoutVersionId] = useState(session.workout_version_id ?? "");
  const [reason, setReason] = useState(session.reason_for_placement ?? "");
  const [gearIds, setGearIds] = useState(session.intended_gear_ids ?? []);
  const [readiness, setReadiness] = useState<number | null>(null);
  const [pendingOutcome, setPendingOutcome] = useState<"skipped" | "cancelled" | null>(null);
  const workoutChoices = useMemo(() => definitions.filter((definition) => definition.sport_key === session.sport_key && latestVersionId(definition)), [definitions, session.sport_key]);
  const selectedWorkoutVersion = useMemo(() => definitions
    .map((definition) => strengthWorkoutVersion(definition, workoutVersionId))
    .find((version): version is FitnessWorkoutVersion => Boolean(version)) ?? null, [definitions, workoutVersionId]);

  function payload(status = session.status) {
    const schedule = precision === "exact"
      ? { scheduled_start_utc: new Date(startsAt).toISOString(), scheduled_date: startsAt.slice(0, 10), time_window_start_utc: null, time_window_end_utc: null }
      : precision === "window"
        ? { scheduled_start_utc: null, scheduled_date: startsAt.slice(0, 10), time_window_start_utc: new Date(startsAt).toISOString(), time_window_end_utc: new Date(windowEnd).toISOString() }
        : { scheduled_start_utc: null, scheduled_date: date, time_window_start_utc: null, time_window_end_utc: null };
    return {
      sport_key: session.sport_key,
      title: title.trim(),
      local_timezone: session.local_timezone ?? localTimeZone(),
      training_programme_id: programmeId || null,
      workout_version_id: workoutVersionId || null,
      status,
      session_source: session.session_source ?? "user",
      expected_duration_s: durationMinutes ? Number(durationMinutes) * 60 : null,
      expected_distance_m: distanceKm ? Number(distanceKm) * 1000 : null,
      priority: session.priority ?? 0,
      movable,
      visibility,
      shared_title: visibility === "logistics_shared" ? sharedTitle.trim() || "Training" : null,
      reason_for_placement: reason.trim() || null,
      completion_activity_id: session.completion_activity_id ?? null,
      completion_state: status === "skipped" ? "skipped" : session.completion_state ?? null,
      goal_links: [
        ...(goalId ? [{ goal_id: goalId, role: "primary" }] : []),
        ...(session.goal_links ?? []).filter((link) => link.role !== "primary" && link.goal_id !== goalId),
      ],
      intended_gear_ids: gearIds,
      exercise_items: workoutVersionId
        ? selectedWorkoutVersion?.exercise_items ?? session.exercise_items ?? []
        : [],
      ...schedule,
    };
  }

  async function persist(status = session.status) {
    try {
      await save.save("planned_session", payload(status), { entityId: session.id, baseRevision: session.revision ?? null });
      onClose();
    } catch {
      setPendingOutcome(null);
    }
  }

  async function recordReadiness(value: number) {
    setReadiness(value);
    await checkinSave.save("session_checkin", {
      planned_session_id: session.id,
      activity_id: null,
      captured_at_utc: new Date().toISOString(),
      timing: "pre",
      capture_quality: "contemporaneous",
      captured_before_activity_start: true,
      readiness_1_5: value,
      notes: null,
    });
  }

  return <FitnessCard title={`Manage ${session.title}`} detail="Move, shorten, replace, skip, or share logistics without changing an accepted workout version.">
    <div className="fitness-module__fields">
      <label className="fitness-module__field is-wide">Title<input value={title} onChange={(event) => setTitle(event.target.value)} /></label>
      <div className="fitness-module__choice-grid is-wide" role="group" aria-label="Scheduling precision">{(["exact", "window", "date"] as const).map((value) => <button type="button" className={precision === value ? "is-active" : undefined} aria-pressed={precision === value} onClick={() => setPrecision(value)} key={value}>{value === "date" ? "Date only" : value === "window" ? "Time window" : "Exact time"}</button>)}</div>
      {precision === "date" ? <label className="fitness-module__field">Date<input type="date" value={date} onChange={(event) => setDate(event.target.value)} /></label> : <label className="fitness-module__field">{precision === "window" ? "Window starts" : "Starts"}<input type="datetime-local" value={startsAt} onChange={(event) => setStartsAt(event.target.value)} /></label>}
      {precision === "window" ? <label className="fitness-module__field">Window ends<input type="datetime-local" min={startsAt} value={windowEnd} onChange={(event) => setWindowEnd(event.target.value)} /></label> : null}
      <label className="fitness-module__field">Shorten or extend (minutes)<input type="number" min="0" inputMode="numeric" value={durationMinutes} onChange={(event) => setDurationMinutes(event.target.value)} /></label>
      <label className="fitness-module__field">Expected distance (km)<input type="number" min="0" step="0.1" inputMode="decimal" value={distanceKm} onChange={(event) => setDistanceKm(event.target.value)} /></label>
      <label className="fitness-module__field">Primary goal<select value={goalId} onChange={(event) => setGoalId(event.target.value)}><option value="">No primary goal</option>{goals.filter((goal) => goal.status === "active").map((goal) => <option value={goal.id} key={goal.id}>{goal.name}</option>)}</select></label>
      <label className="fitness-module__field">Programme<select value={programmeId} onChange={(event) => setProgrammeId(event.target.value)}><option value="">No programme</option>{programmes.map((programme) => <option value={programme.id} key={programme.id}>{programme.name}</option>)}</select></label>
      <label className="fitness-module__field is-wide">Replace workout<select value={workoutVersionId} onChange={(event) => setWorkoutVersionId(event.target.value)}><option value="">No structured workout</option>{workoutChoices.map((definition) => <option value={latestVersionId(definition) ?? ""} key={definition.id}>{definition.name}</option>)}</select><small>Choosing another accepted version changes this plan link; it never edits either version.</small></label>
      <label className="fitness-module__field is-wide">Reason for placement or change<textarea value={reason} onChange={(event) => setReason(event.target.value)} /></label>
      <label className="fitness-module__check"><input type="checkbox" checked={movable} onChange={(event) => setMovable(event.target.checked)} /> Session can move</label>
      <label className="fitness-module__check"><input type="checkbox" checked={visibility === "logistics_shared"} onChange={(event) => setVisibility(event.target.checked ? "logistics_shared" : "private")} /> Share logistics with household</label>
      {visibility === "logistics_shared" ? <label className="fitness-module__field">Household title<input value={sharedTitle} onChange={(event) => setSharedTitle(event.target.value)} /><small>No workout, route, readiness, issue, or coaching detail is copied.</small></label> : null}
      <fieldset className="fitness-module__field is-wide"><legend>Intended gear</legend>{gear.filter((item) => item.active !== false).map((item) => <label className="fitness-module__check" key={item.id}><input type="checkbox" checked={gearIds.includes(item.id)} onChange={(event) => setGearIds((current) => event.target.checked ? [...current, item.id] : current.filter((id) => id !== item.id))} /> {item.name}{item.default_for_sport_key === session.sport_key ? " · usual" : ""}</label>)}</fieldset>
    </div>
    <div className="fitness-module__readiness"><strong>Readiness before starting</strong><div role="group" aria-label="Readiness from 1 to 5">{[1, 2, 3, 4, 5].map((value) => <button type="button" className={readiness === value ? "is-active" : undefined} aria-pressed={readiness === value} disabled={checkinSave.saving} onClick={() => void recordReadiness(value)} key={value}>{value}</button>)}</div><small>Captured now as contemporaneous pre-session context.</small></div>
    <div className="fitness-module__form-footer"><button type="button" className="button button--primary" disabled={save.saving || !title.trim()} onClick={() => void persist()}><Save aria-hidden="true" size={16} /> Save changes</button>{session.status === "proposed" ? <button type="button" className="button button--secondary" disabled={save.saving || !title.trim()} onClick={() => void persist("accepted")}><Check aria-hidden="true" size={16} /> Accept plan</button> : null}<button type="button" className="button button--secondary" disabled={save.saving || ["skipped", "cancelled"].includes(session.status)} onClick={() => setPendingOutcome("skipped")}><SkipForward aria-hidden="true" size={16} /> Skip</button><button type="button" className="button button--secondary" disabled={save.saving || session.status === "cancelled"} onClick={() => setPendingOutcome("cancelled")}><Ban aria-hidden="true" size={16} /> Cancel session</button>{session.sport_key === "strength" && ["accepted", "scheduled", "in_progress"].includes(session.status) ? <button type="button" className="button button--secondary" onClick={onStartStrength}><Play aria-hidden="true" size={16} /> Start strength</button> : null}<button type="button" className="button button--secondary" onClick={onClose}>Close</button><FitnessFormStatus saving={save.saving || checkinSave.saving} saved={save.saved || checkinSave.saved} error={save.saveError ?? checkinSave.saveError} /></div>
    {readiness ? <p className="fitness-module__privacy-note"><Check aria-hidden="true" size={16} /> Readiness {readiness}/5 saved and will link to the completed activity rather than being copied.</p> : null}
    <ConfirmDialog
      open={pendingOutcome !== null}
      onOpenChange={(open) => { if (!open && !save.saving) setPendingOutcome(null); }}
      title={pendingOutcome === "cancelled" ? "Cancel this session?" : "Skip this session?"}
      description={pendingOutcome === "cancelled"
        ? `${session.title} will move to completed plan outcomes as cancelled. Its accepted workout definition will remain unchanged.`
        : `${session.title} will move to completed plan outcomes as skipped. Its accepted workout definition will remain unchanged.`}
      confirmLabel={pendingOutcome === "cancelled" ? "Cancel session" : "Skip session"}
      onConfirm={() => { if (pendingOutcome) void persist(pendingOutcome); }}
      busy={save.saving}
      destructive
    />
  </FitnessCard>;
}
