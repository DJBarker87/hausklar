import {
  Activity,
  CalendarClock,
  Check,
  CloudDownload,
  Dumbbell,
  Footprints,
  LoaderCircle,
  SlidersHorizontal,
} from "lucide-react";
import { useEffect, useMemo, useState } from "react";

import { api } from "../../api";
import { cn } from "../../components/ui";
import { finishUsageWorkflow, startStravaPull } from "../../usageMonitor";
import { activitySportOptions, emptyActivityRegistry } from "../../fitness/activityRegistry";
import type {
  FitnessActivityRegistry,
  FitnessGoal,
  FitnessStravaStatus,
  FitnessStravaSync,
  FitnessTrainingProgramme,
} from "../../fitness/contract";
import {
  FitnessFormStatus,
  errorMessage,
  localDateTimeValue,
  localDateValue,
  localTimeZone,
  submitForm,
  useFitnessCollection,
  useFitnessEndpoint,
  useFitnessSave,
  utcFromLocalInput,
} from "./shared";

type SessionMoment = "now" | "later" | "done";
type RunTarget = "none" | "time" | "pace";

const quickSports = [
  { key: "running", label: "Run", detail: "Just go, or add a target", icon: Footprints },
  { key: "strength", label: "Strength", detail: "Start or plan a workout", icon: Dumbbell },
  { key: "other", label: "Other", detail: "Choose another activity", icon: Activity },
] as const;

function sportName(key: string): string {
  return ({ running: "Run", walking: "Walk", cycling: "Ride", hiking: "Hike" } as Record<string, string>)[key]
    ?? key.replaceAll("_", " ").replace(/\b\w/g, (letter) => letter.toUpperCase());
}

function positiveNumber(value: string): number | null {
  if (!value.trim()) return null;
  const parsed = Number(value.replace(",", "."));
  return Number.isFinite(parsed) && parsed > 0 ? parsed : null;
}

function clockSeconds(minutes: string, seconds: string): number | null {
  const minuteValue = Number(minutes || 0);
  const secondValue = Number(seconds || 0);
  if (!Number.isInteger(minuteValue) || !Number.isInteger(secondValue) || minuteValue < 0 || secondValue < 0 || secondValue > 59) return null;
  const total = minuteValue * 60 + secondValue;
  return total > 0 ? total : null;
}

function OtherSportPicker({ revision, value, onChange }: {
  revision: number;
  value: string;
  onChange: (value: string) => void;
}) {
  const registry = useFitnessEndpoint<FitnessActivityRegistry>("/fitness/activity-registry", emptyActivityRegistry, revision);
  const options = activitySportOptions(registry.data).filter((item) => !["running", "strength"].includes(item.key));
  return <label className="fitness-module__field fitness-sessions__other-sport">Activity
    <select value={value} onChange={(event) => onChange(event.target.value)}>
      {options.map((option) => <option value={option.key} key={option.key}>{option.display_name}</option>)}
    </select>
  </label>;
}

function SessionDetails({ revision, programmes, planning, title, setTitle, goalId, setGoalId, programmeId, setProgrammeId, movable, setMovable }: {
  revision: number;
  programmes: FitnessTrainingProgramme[];
  planning: boolean;
  title: string;
  setTitle: (value: string) => void;
  goalId: string;
  setGoalId: (value: string) => void;
  programmeId: string;
  setProgrammeId: (value: string) => void;
  movable: boolean;
  setMovable: (value: boolean) => void;
}) {
  const goals = useFitnessCollection<FitnessGoal>("/fitness/goals", "goal", revision);
  return <div className="fitness-sessions__details-fields">
    <label className="fitness-module__field is-wide">Name (optional)
      <input value={title} onChange={(event) => setTitle(event.target.value)} placeholder="HausKlar will name it for you" />
    </label>
    {planning ? <>
      <label className="fitness-module__field">Goal (optional)
        <select value={goalId} onChange={(event) => setGoalId(event.target.value)} disabled={goals.loading}>
          <option value="">No goal</option>
          {goals.data.filter((goal) => goal.status === "active").map((goal) => <option value={goal.id} key={goal.id}>{goal.name}</option>)}
        </select>
      </label>
      <label className="fitness-module__field">Programme (optional)
        <select value={programmeId} onChange={(event) => setProgrammeId(event.target.value)}>
          <option value="">No programme</option>
          {programmes.filter((programme) => ["draft", "active", "paused"].includes(programme.status)).map((programme) => <option value={programme.id} key={programme.id}>{programme.name}</option>)}
        </select>
      </label>
      <label className="fitness-module__check"><input type="checkbox" checked={movable} onChange={(event) => setMovable(event.target.checked)} /> HausKlar may suggest moving this if the week changes</label>
    </> : null}
  </div>;
}

function SessionComposer({ sport, revision, programmes, onDataChanged, onClose }: {
  sport: string;
  revision: number;
  programmes: FitnessTrainingProgramme[];
  onDataChanged: () => void;
  onClose: () => void;
}) {
  const save = useFitnessSave(onDataChanged);
  const [actualSport, setActualSport] = useState(sport === "other" ? "hiking" : sport);
  const [moment, setMoment] = useState<SessionMoment>("now");
  const [scheduledAt, setScheduledAt] = useState(() => localDateTimeValue(new Date(Date.now() + 3_600_000)));
  const [finishedAt, setFinishedAt] = useState(localDateTimeValue);
  const [durationMinutes, setDurationMinutes] = useState("");
  const [distanceKm, setDistanceKm] = useState("");
  const [runTarget, setRunTarget] = useState<RunTarget>("none");
  const [targetMinutes, setTargetMinutes] = useState("");
  const [targetSeconds, setTargetSeconds] = useState("");
  const [paceMinutes, setPaceMinutes] = useState("");
  const [paceSeconds, setPaceSeconds] = useState("");
  const [detailsOpen, setDetailsOpen] = useState(false);
  const [title, setTitle] = useState("");
  const [goalId, setGoalId] = useState("");
  const [programmeId, setProgrammeId] = useState("");
  const [movable, setMovable] = useState(true);

  const planning = moment !== "done";
  const distance = positiveNumber(distanceKm);
  const loggedDuration = positiveNumber(durationMinutes);
  const targetTime = clockSeconds(targetMinutes, targetSeconds);
  const targetPace = clockSeconds(paceMinutes, paceSeconds);
  const expectedDuration = runTarget === "time"
    ? targetTime
    : runTarget === "pace" && targetPace && distance
      ? Math.round(targetPace * distance)
      : positiveNumber(durationMinutes) ? Math.round(Number(durationMinutes) * 60) : null;
  const invalidTarget = planning && actualSport === "running" && (
    (runTarget === "time" && targetTime == null)
    || (runTarget === "pace" && targetPace == null)
  );
  const valid = moment !== "done" || loggedDuration != null;
  const name = title.trim() || sportName(actualSport);

  async function saveSession() {
    const id = crypto.randomUUID();
    if (moment === "done") {
      if (!loggedDuration) return;
      const ended = new Date(utcFromLocalInput(finishedAt));
      const started = new Date(ended.getTime() - loggedDuration * 60_000);
      await save.save("manual_activity", {
        id,
        sport_key: actualSport,
        title: title.trim() || null,
        started_at_utc: started.toISOString(),
        local_timezone: localTimeZone(),
        duration_s: Math.round(loggedDuration * 60),
        distance_m: distance == null ? null : distance * 1_000,
        session_rpe: null,
        workout_classification: null,
        notes: null,
        estimate_energy: true,
      }, { entityId: id });
    } else {
      const start = moment === "now" ? new Date().toISOString() : utcFromLocalInput(scheduledAt);
      await save.save("planned_session", {
        id,
        sport_key: actualSport,
        title: name,
        status: moment === "now" ? "accepted" : "scheduled",
        session_source: "user",
        scheduled_start_utc: start,
        scheduled_date: (moment === "now" ? localDateValue() : scheduledAt.slice(0, 10)),
        local_timezone: localTimeZone(),
        expected_duration_s: expectedDuration,
        expected_distance_m: distance == null ? null : distance * 1_000,
        expected_pace_s_per_km: actualSport === "running" && runTarget === "pace" ? targetPace : null,
        priority: 1,
        movable: moment === "later" ? movable : false,
        visibility: "private",
        training_programme_id: programmeId || null,
        goal_links: goalId ? [{ goal_id: goalId, role: "primary" }] : [],
        exercise_items: [],
        intended_gear_ids: [],
      }, { entityId: id });
    }
    onClose();
  }

  return <div className="fitness-sessions__composer">
    <header><div><span className="fitness-sessions__eyebrow">{sportName(actualSport)}</span><h3>What are you doing?</h3><p>Save only what is useful. Every target and detail is optional.</p></div><button type="button" className="button button--secondary button--compact" onClick={onClose}>Close</button></header>
    {sport === "other" ? <OtherSportPicker revision={revision} value={actualSport} onChange={setActualSport} /> : null}
    <form onSubmit={submitForm(saveSession)}>
      <fieldset className="fitness-sessions__moment"><legend className="sr-only">When is this session?</legend>
        {([
          ["now", "Now", "I’m about to do it"],
          ["later", "Later", "Put it in my week"],
          ["done", "Done", "I already did it"],
        ] as const).map(([value, label, detail]) => <label className={cn(moment === value && "is-selected")} key={value}><input type="radio" name="session-moment" value={value} aria-label={`${label} — ${detail}`} checked={moment === value} onChange={() => setMoment(value)} /><span><strong>{label}</strong><small>{detail}</small></span></label>)}
      </fieldset>

      {moment === "later" ? <label className="fitness-module__field fitness-sessions__when">When
        <input type="datetime-local" required value={scheduledAt} onChange={(event) => setScheduledAt(event.target.value)} />
      </label> : null}
      {moment === "done" ? <div className="fitness-sessions__log-basics">
        <label className="fitness-module__field">Minutes <span aria-hidden="true">*</span><input type="number" inputMode="decimal" min="1" max="10080" required value={durationMinutes} onChange={(event) => setDurationMinutes(event.target.value)} placeholder="30" /></label>
        <label className="fitness-module__field">Finished<input type="datetime-local" max={localDateTimeValue()} required value={finishedAt} onChange={(event) => setFinishedAt(event.target.value)} /></label>
      </div> : null}

      <div className="fitness-sessions__targets">
        <label className="fitness-module__field">Distance <span>(optional)</span><span className="fitness-wave4__input-with-unit"><input type="number" inputMode="decimal" min="0" step="0.01" value={distanceKm} onChange={(event) => setDistanceKm(event.target.value)} placeholder="5" /><span>km</span></span></label>
        {planning && actualSport !== "running" ? <label className="fitness-module__field">Duration <span>(optional)</span><span className="fitness-wave4__input-with-unit"><input type="number" inputMode="decimal" min="1" value={durationMinutes} onChange={(event) => setDurationMinutes(event.target.value)} placeholder="30" /><span>min</span></span></label> : null}
      </div>

      {planning && actualSport === "running" ? <section className="fitness-sessions__run-target" aria-labelledby="run-target-title">
        <div><h4 id="run-target-title">Want a target?</h4><p>Leave this blank for an easy, unstructured run.</p></div>
        <div className="fitness-sessions__target-switch" role="group" aria-label="Run target">
          {([ ["none", "No target"], ["time", "Target time"], ["pace", "Target pace"] ] as const).map(([value, label]) => <button type="button" className={cn(runTarget === value && "is-active")} aria-pressed={runTarget === value} onClick={() => setRunTarget(value)} key={value}>{label}</button>)}
        </div>
        {runTarget === "time" ? <div className="fitness-sessions__clock-input" role="group" aria-label="Target time"><label>Minutes<input type="number" min="0" inputMode="numeric" value={targetMinutes} onChange={(event) => setTargetMinutes(event.target.value)} placeholder="25" /></label><span>:</span><label>Seconds<input type="number" min="0" max="59" inputMode="numeric" value={targetSeconds} onChange={(event) => setTargetSeconds(event.target.value)} placeholder="00" /></label></div> : null}
        {runTarget === "pace" ? <div className="fitness-sessions__clock-input" role="group" aria-label="Target pace"><label>Minutes<input type="number" min="0" inputMode="numeric" value={paceMinutes} onChange={(event) => setPaceMinutes(event.target.value)} placeholder="5" /></label><span>:</span><label>Seconds<input type="number" min="0" max="59" inputMode="numeric" value={paceSeconds} onChange={(event) => setPaceSeconds(event.target.value)} placeholder="00" /></label><strong>/km</strong></div> : null}
      </section> : null}

      <details className="fitness-sessions__more" open={detailsOpen} onToggle={(event) => setDetailsOpen(event.currentTarget.open)}><summary><SlidersHorizontal aria-hidden="true" size={17} /> More details</summary>
        {detailsOpen ? <SessionDetails revision={revision} programmes={programmes} planning={planning} title={title} setTitle={setTitle} goalId={goalId} setGoalId={setGoalId} programmeId={programmeId} setProgrammeId={setProgrammeId} movable={movable} setMovable={setMovable} /> : null}
      </details>

      <div className="fitness-module__form-footer">
        <button type="submit" className="button button--primary" disabled={save.saving || !valid || invalidTarget} aria-busy={save.saving}>
          {save.saving ? <LoaderCircle className="is-spinning" aria-hidden="true" size={17} /> : moment === "done" ? <Check aria-hidden="true" size={17} /> : <CalendarClock aria-hidden="true" size={17} />}
          {save.saving ? "Saving…" : moment === "done" ? `Log ${sportName(actualSport).toLocaleLowerCase()}` : moment === "now" ? `Add ${sportName(actualSport).toLocaleLowerCase()} for now` : `Add to my week`}
        </button>
        <FitnessFormStatus saving={save.saving} saved={save.saved} error={save.saveError} />
      </div>
    </form>
  </div>;
}

function StravaImport({ online, onDataChanged }: { online: boolean; onDataChanged: () => void }) {
  const [status, setStatus] = useState<FitnessStravaStatus | null>(null);
  const [loading, setLoading] = useState(online);
  const [working, setWorking] = useState(false);
  const [message, setMessage] = useState<string | null>(() => {
    const outcome = new URLSearchParams(window.location.search).get("strava");
    if (outcome === "connected") return "Strava is connected and your latest activities were checked.";
    if (outcome === "cancelled") return "Strava connection cancelled.";
    if (outcome === "failed") return "Strava could not be connected. Try again.";
    return null;
  });
  const [requestError, setRequestError] = useState<string | null>(null);

  useEffect(() => {
    if (!online) { setLoading(false); return; }
    let cancelled = false;
    void api<FitnessStravaStatus>("/fitness/integrations/strava/status", {}, true, false)
      .then((value) => { if (!cancelled) setStatus(value); })
      .catch((error) => { if (!cancelled) setRequestError(errorMessage(error)); })
      .finally(() => { if (!cancelled) setLoading(false); });
    return () => { cancelled = true; };
  }, [online]);

  if (!loading && status?.configured === false) return null;
  if (!loading && !status && !requestError) return null;

  async function connect() {
    if (!online || working) return;
    setWorking(true); setRequestError(null); setMessage(null);
    try {
      const response = await api<{ authorization_url: string }>("/fitness/integrations/strava/start", { method: "POST", body: JSON.stringify({ return_surface: "web" }) }, true, false);
      window.location.assign(response.authorization_url);
    } catch (error) {
      setRequestError(errorMessage(error)); setWorking(false);
    }
  }

  async function pull() {
    if (!online || working) return;
    const usageRun = startStravaPull();
    setWorking(true); setRequestError(null); setMessage(null);
    try {
      const response = await api<FitnessStravaSync>("/fitness/integrations/strava/sync", { method: "POST" }, true, false);
      setStatus(response.status);
      const changed = response.imported_count + response.updated_count;
      setMessage(changed > 0
        ? `${changed} ${changed === 1 ? "session" : "sessions"} brought in from Strava.`
        : "Everything from Strava is already here.");
      finishUsageWorkflow(usageRun, "completed", { interactions: 1 });
      if (changed > 0) onDataChanged();
    } catch (error) {
      finishUsageWorkflow(usageRun, "failed", { interactions: 1, error });
      setRequestError(errorMessage(error));
    } finally {
      setWorking(false);
    }
  }

  const connected = status?.connected === true;
  const providerDown = status?.status === "provider_down";
  return <aside className="fitness-sessions__strava" aria-label="Strava activity import">
    <div><CloudDownload aria-hidden="true" size={21} /><div><strong>{providerDown ? "Strava was unavailable" : connected ? "Logged it on Strava?" : "Log from Strava"}</strong><span>{providerDown ? "Your connection is safe. Try the same one-tap pull again." : connected ? "Bring in completed activities without typing them again." : "Connect once, then importing is one tap."}</span></div></div>
    <button type="button" className="button button--secondary" disabled={!online || working || loading} aria-busy={working || loading} onClick={() => void (connected ? pull() : connect())}>
      {working || loading ? <LoaderCircle className="is-spinning" aria-hidden="true" size={17} /> : <CloudDownload aria-hidden="true" size={17} />}
      {loading ? "Checking Strava…" : providerDown ? "Try Strava again" : connected ? "Pull latest from Strava" : status?.status === "reauth_required" ? "Reconnect Strava" : "Connect Strava"}
    </button>
    {!online ? <small>Connect to the internet to check Strava.</small> : null}
    {message ? <small className="is-success" role="status">{message}</small> : null}
    {requestError ? <small className="is-error" role="alert">{requestError}</small> : null}
  </aside>;
}

export function FitnessSessionLauncher({ online, revision, programmes, onDataChanged, onOpenStrength }: {
  online: boolean;
  revision: number;
  programmes: FitnessTrainingProgramme[];
  onDataChanged: () => void;
  onOpenStrength: () => void;
}) {
  const [sport, setSport] = useState<string | null>(null);
  const selected = useMemo(() => quickSports.find((item) => item.key === sport), [sport]);
  return <section className="fitness-sessions__start" aria-labelledby="fitness-session-start-title">
    <header><div><h3 id="fitness-session-start-title">What do you want to do?</h3><p>Choose the activity first. Plan it, do it now, or log it afterwards.</p></div></header>
    <div className="fitness-sessions__sports">
      {quickSports.map((item) => {
        const Icon = item.icon;
        return <button
          type="button"
          className={cn(sport === item.key && "is-selected")}
          aria-label={item.label}
          aria-pressed={sport === item.key}
          key={item.key}
          onClick={() => {
            if (item.key === "strength") {
              onOpenStrength();
              return;
            }
            setSport(item.key);
          }}
        ><Icon aria-hidden="true" size={23} /><span><strong>{item.label}</strong><small>{item.detail}</small></span></button>;
      })}
    </div>
    {selected ? <SessionComposer key={selected.key} sport={selected.key} revision={revision} programmes={programmes} onDataChanged={onDataChanged} onClose={() => setSport(null)} /> : null}
    <StravaImport online={online} onDataChanged={onDataChanged} />
  </section>;
}
