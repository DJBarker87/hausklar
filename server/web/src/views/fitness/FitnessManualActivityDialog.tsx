import { Activity, Calculator, Clock3, Gauge, MapPin, Save } from "lucide-react";
import { useEffect, useMemo, useState } from "react";

import { api } from "../../api";
import { Modal } from "../../components/ui";
import type {
  FitnessActivitySportDefinition,
  FitnessActivitySummary,
  FitnessBodyMeasurement,
  FitnessManualActivityDefaults,
} from "../../fitness/contract";
import {
  cachedFitnessRecords,
  flushFitnessSync,
  saveFitnessRecord,
} from "../../fitness/offlineStore";
import { errorMessage } from "./shared";

const fallbackSports: FitnessActivitySportDefinition[] = [
  { key: "running", display_name: "Running", distance_meaningful: true },
  { key: "walking", display_name: "Walking", distance_meaningful: true },
  { key: "cycling", display_name: "Cycling", distance_meaningful: true },
  { key: "hiking", display_name: "Hiking", distance_meaningful: true },
  { key: "other", display_name: "Other activity", distance_meaningful: false },
];

function localDateTimeValue(date = new Date()): string {
  const local = new Date(date.getTime() - date.getTimezoneOffset() * 60_000);
  return local.toISOString().slice(0, 16);
}

function activityMet(sportKey: string, durationS: number, distanceM: number | null): number {
  const hours = durationS / 3_600;
  const speedKmh = distanceM && hours > 0 ? distanceM / 1_000 / hours : null;
  if (sportKey === "running") {
    if (speedKmh == null) return 8;
    for (const [ceiling, met] of [[6.4, 6], [8, 8], [9.7, 9.8], [11.3, 11], [12.9, 11.8], [14.5, 12.8]]) {
      if (speedKmh < ceiling) return met;
    }
    return 14.5;
  }
  if (sportKey === "walking") {
    if (speedKmh == null) return 3.5;
    for (const [ceiling, met] of [[3.2, 2.8], [4.8, 3.5], [5.6, 4], [6.4, 4.8]]) {
      if (speedKmh < ceiling) return met;
    }
    return 6;
  }
  if (sportKey === "cycling") {
    if (speedKmh == null) return 6.8;
    for (const [ceiling, met] of [[16, 4], [19, 6.8], [22, 8], [26, 10]]) {
      if (speedKmh < ceiling) return met;
    }
    return 12;
  }
  return ({ hiking: 6, rowing_indoor: 7, rowing_water: 7, swimming_pool: 6, swimming_open_water: 6, other: 5 } as Record<string, number>)[sportKey] ?? 5;
}

function paceLabel(durationS: number, distanceM: number | null): string | null {
  if (!distanceM || distanceM <= 0) return null;
  const secondsPerKm = durationS / (distanceM / 1_000);
  const minutes = Math.floor(secondsPerKm / 60);
  return `${minutes}:${String(Math.round(secondsPerKm % 60)).padStart(2, "0")} /km`;
}

async function loadDefaults(): Promise<FitnessManualActivityDefaults> {
  try {
    return await api<FitnessManualActivityDefaults>("/fitness/activities/manual-defaults", {}, true, false);
  } catch (requestError) {
    const measurements = await cachedFitnessRecords<FitnessBodyMeasurement>("body_measurement").catch(() => []);
    const latest = measurements
      .filter((item) => item.metric_key === "body.weight_kg" && item.canonical_state !== "duplicate" && item.canonical_state !== "excluded")
      .sort((left, right) => right.measured_at_utc.localeCompare(left.measured_at_utc))[0];
    if (!latest) throw requestError;
    return {
      latest_weight_kg: latest.unit_key.toLowerCase() === "kg" ? latest.value : null,
      latest_weight_measured_at_utc: latest.measured_at_utc,
      energy_estimation_method: "adult_compendium_2024_met",
    };
  }
}

export function FitnessManualActivityDialog({
  open,
  onOpenChange,
  sports,
  online,
  onSaved,
}: {
  open: boolean;
  onOpenChange: (open: boolean) => void;
  sports: FitnessActivitySportDefinition[];
  online: boolean;
  onSaved: (activity: FitnessActivitySummary, message: string) => void;
}) {
  const availableSports = useMemo(() => {
    const source = sports.length ? sports : fallbackSports;
    return source.filter((sport) => sport.key !== "strength");
  }, [sports]);
  const [sportKey, setSportKey] = useState("running");
  const [startedLocal, setStartedLocal] = useState(localDateTimeValue);
  const [hours, setHours] = useState("0");
  const [minutes, setMinutes] = useState("30");
  const [distanceKm, setDistanceKm] = useState("5");
  const [title, setTitle] = useState("");
  const [classification, setClassification] = useState("");
  const [rpe, setRpe] = useState("");
  const [notes, setNotes] = useState("");
  const [estimateEnergy, setEstimateEnergy] = useState(true);
  const [defaults, setDefaults] = useState<FitnessManualActivityDefaults | null>(null);
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [validationError, setValidationError] = useState<{
    field: "started" | "duration" | "distance";
    message: string;
  } | null>(null);

  useEffect(() => {
    if (!open) return;
    setError(null);
    setValidationError(null);
    void loadDefaults().then(setDefaults).catch(() => setDefaults({
      latest_weight_kg: null,
      latest_weight_measured_at_utc: null,
      energy_estimation_method: "adult_compendium_2024_met",
    }));
  }, [open]);

  const selectedSport = availableSports.find((sport) => sport.key === sportKey) ?? availableSports[0] ?? fallbackSports[0];
  const durationS = (Number(hours) * 60 + Number(minutes)) * 60;
  const parsedDistance = distanceKm.trim() ? Number(distanceKm) * 1_000 : null;
  const distanceM = parsedDistance != null && Number.isFinite(parsedDistance) ? parsedDistance : null;
  const met = durationS > 0 ? activityMet(sportKey, durationS, distanceM) : null;
  const estimatedKcal = estimateEnergy && defaults?.latest_weight_kg && met
    ? Math.round(met * defaults.latest_weight_kg * durationS / 3_600)
    : null;
  const pace = durationS > 0 ? paceLabel(durationS, distanceM) : null;

  function resetAfterSave() {
    setStartedLocal(localDateTimeValue());
    setHours("0");
    setMinutes("30");
    setDistanceKm(sportKey === "running" ? "5" : "");
    setTitle("");
    setClassification("");
    setRpe("");
    setNotes("");
  }

  async function submit(event: React.FormEvent<HTMLFormElement>) {
    event.preventDefault();
    setError(null);
    setValidationError(null);
    const parsedHours = Number(hours);
    const parsedMinutes = Number(minutes);
    if (!Number.isInteger(parsedHours) || parsedHours < 0 || parsedHours > 168
      || !Number.isInteger(parsedMinutes) || parsedMinutes < 0 || parsedMinutes > 59
      || !Number.isFinite(durationS) || durationS <= 0 || durationS > 604_800) {
      setValidationError({ field: "duration", message: "Enter a duration of up to 168 hours, using 0–59 minutes." });
      return;
    }
    if (distanceKm.trim() && (distanceM == null || distanceM < 0 || distanceM > 2_000_000)) {
      setValidationError({ field: "distance", message: "Enter a distance up to 2,000 km, or leave it blank." });
      return;
    }
    const started = new Date(startedLocal);
    if (Number.isNaN(started.getTime())) {
      setValidationError({ field: "started", message: "Choose when the activity started." });
      return;
    }
    if (started.getTime() > Date.now() + 60_000) {
      setValidationError({ field: "started", message: "A completed activity cannot start in the future." });
      return;
    }
    setSaving(true);
    try {
      const payload = {
        sport_key: sportKey,
        title: title.trim() || null,
        started_at_utc: started.toISOString(),
        local_timezone: Intl.DateTimeFormat().resolvedOptions().timeZone || "UTC",
        duration_s: durationS,
        distance_m: distanceM,
        session_rpe: rpe ? Number(rpe) : null,
        workout_classification: classification || null,
        notes: notes.trim() || null,
        estimate_energy: estimateEnergy,
      };
      const saved = await saveFitnessRecord("manual_activity", payload);
      let queuedOffline = !online || !navigator.onLine;
      const activity: FitnessActivitySummary = {
        id: saved.id,
        queued_offline: queuedOffline,
        title: payload.title ?? selectedSport.display_name,
        sport_key: payload.sport_key,
        started_at_utc: payload.started_at_utc,
        local_timezone: payload.local_timezone,
        status: "completed",
        planned_session_id: null,
        workout_classification: payload.workout_classification,
        distance_m: payload.distance_m,
        duration_s: payload.duration_s,
        elapsed_duration_s: payload.duration_s,
        timer_duration_s: payload.duration_s,
        moving_duration_s: payload.duration_s,
        energy_kcal: estimatedKcal,
        energy_estimation_method: estimatedKcal ? defaults?.energy_estimation_method : null,
        energy_estimation_weight_kg: estimatedKcal ? defaults?.latest_weight_kg : null,
        energy_estimation_weight_measured_at_utc: estimatedKcal ? defaults?.latest_weight_measured_at_utc : null,
        energy_estimation_met: estimatedKcal ? met : null,
        notes: payload.notes,
        route_preview: [],
        primary_metrics: [],
        gear: [],
      };
      if (!queuedOffline) {
        try {
          await flushFitnessSync();
        } catch {
          queuedOffline = true;
          activity.queued_offline = true;
        }
      }
      onSaved(activity, queuedOffline ? `${activity.title} saved offline` : `${activity.title} saved`);
      resetAfterSave();
      onOpenChange(false);
    } catch (requestError) {
      setError(errorMessage(requestError));
    } finally {
      setSaving(false);
    }
  }

  return <Modal
    open={open}
    onOpenChange={(nextOpen) => { if (!saving) onOpenChange(nextOpen); }}
    title="Log completed activity"
    description="For a run, walk or workout that is not already in Garmin. No plan is required."
  >
    <form className="fitness-module__form fitness-module__manual-activity" aria-busy={saving} onSubmit={(event) => void submit(event)}>
      <div className="fitness-module__fields">
        <label className="fitness-module__field">Activity
          <select value={sportKey} onChange={(event) => setSportKey(event.target.value)}>
            {availableSports.map((sport) => <option value={sport.key} key={sport.key}>{sport.display_name}</option>)}
          </select>
        </label>
        <label className="fitness-module__field">Started
          <input type="datetime-local" required max={localDateTimeValue()} value={startedLocal} aria-invalid={validationError?.field === "started" || undefined} aria-describedby={validationError?.field === "started" ? "manual-started-error" : undefined} onChange={(event) => setStartedLocal(event.target.value)} />
          {validationError?.field === "started" ? <span id="manual-started-error" className="fitness-module__field-error">{validationError.message}</span> : null}
        </label>
        <label className="fitness-module__field">Hours
          <input type="text" inputMode="numeric" pattern="[0-9]*" autoComplete="off" value={hours} aria-invalid={validationError?.field === "duration" || undefined} aria-describedby={validationError?.field === "duration" ? "manual-duration-error" : undefined} onChange={(event) => setHours(event.target.value)} />
          {validationError?.field === "duration" ? <span id="manual-duration-error" className="fitness-module__field-error">{validationError.message}</span> : null}
        </label>
        <label className="fitness-module__field">Minutes
          <input type="text" inputMode="numeric" pattern="[0-9]*" autoComplete="off" value={minutes} aria-invalid={validationError?.field === "duration" || undefined} aria-describedby={validationError?.field === "duration" ? "manual-duration-error" : undefined} onChange={(event) => setMinutes(event.target.value)} />
        </label>
        <label className="fitness-module__field is-wide">Distance <span className="fitness-module__field-unit">km</span>
          <input type="text" inputMode="decimal" autoComplete="off" value={distanceKm} placeholder={selectedSport.distance_meaningful === false ? "Optional" : "5.00"} aria-invalid={validationError?.field === "distance" || undefined} aria-describedby={validationError?.field === "distance" ? "manual-distance-error" : undefined} onChange={(event) => setDistanceKm(event.target.value)} />
          {validationError?.field === "distance" ? <span id="manual-distance-error" className="fitness-module__field-error">{validationError.message}</span> : null}
        </label>
      </div>

      <div className="fitness-module__manual-preview" aria-label="Activity preview">
        <div><MapPin aria-hidden="true" size={18} /><span>Distance<strong>{distanceM == null ? "—" : `${(distanceM / 1_000).toFixed(2)} km`}</strong></span></div>
        <div><Clock3 aria-hidden="true" size={18} /><span>Time<strong>{durationS > 0 ? `${Math.floor(durationS / 3_600)}h ${Math.floor((durationS % 3_600) / 60)}m` : "—"}</strong></span></div>
        <div><Gauge aria-hidden="true" size={18} /><span>{pace ? "Pace" : "Intensity"}<strong>{pace ?? (met ? `${met} MET` : "—")}</strong></span></div>
        <div><Calculator aria-hidden="true" size={18} /><span>Calories<strong>{estimatedKcal == null ? "—" : `≈ ${estimatedKcal} kcal`}</strong></span></div>
      </div>

      <label className="fitness-module__check">
        <input type="checkbox" checked={estimateEnergy} onChange={(event) => setEstimateEnergy(event.target.checked)} />
        Estimate calories from my latest weight
      </label>
      <p className="fitness-module__manual-estimate-note">
        {defaults?.latest_weight_kg
          ? `Uses ${defaults.latest_weight_kg.toFixed(1)} kg and a standard activity-intensity estimate. Garmin sensor data will always be more precise.`
          : "No canonical weight is available yet. The activity will still save without a calorie figure."}
      </p>

      <details className="fitness-module__details">
        <summary>Add a title, effort or notes</summary>
        <div className="fitness-module__fields fitness-module__manual-optional">
          <label className="fitness-module__field is-wide">Title
            <input value={title} maxLength={200} placeholder={selectedSport.display_name} onChange={(event) => setTitle(event.target.value)} />
          </label>
          {sportKey === "running" ? <label className="fitness-module__field">Run type
            <select value={classification} onChange={(event) => setClassification(event.target.value)}>
              <option value="">Not set</option>
              {['recovery', 'easy', 'steady', 'long', 'tempo', 'threshold', 'interval', 'hill', 'race', 'time_trial', 'progression', 'mixed'].map((value) => <option value={value} key={value}>{value.replaceAll('_', ' ')}</option>)}
            </select>
          </label> : null}
          <label className="fitness-module__field">Effort
            <select value={rpe} onChange={(event) => setRpe(event.target.value)}>
              <option value="">Not set</option>
              {Array.from({ length: 10 }, (_, index) => index + 1).map((value) => <option value={value} key={value}>{value} / 10</option>)}
            </select>
          </label>
          <label className="fitness-module__field is-wide">Notes
            <textarea value={notes} maxLength={8000} onChange={(event) => setNotes(event.target.value)} />
          </label>
        </div>
      </details>

      {error ? <div className="fitness-module__notice fitness-module__notice--error" role="alert">{error}</div> : null}
      <div className="fitness-module__button-row fitness-module__manual-actions">
        <button type="button" className="button button--secondary" disabled={saving} onClick={() => onOpenChange(false)}>Cancel</button>
        <button type="submit" className="button button--primary" disabled={saving}><Save aria-hidden="true" size={17} /> {saving ? "Saving…" : "Save activity"}</button>
      </div>
    </form>
  </Modal>;
}
