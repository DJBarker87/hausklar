import {
  Activity,
  AlertCircle,
  CheckCircle2,
  Clock3,
  Copy,
  Dumbbell,
  FileUp,
  Filter,
  Footprints,
  Map,
  Plus,
  RefreshCw,
  RotateCcw,
  Trash2,
  WifiOff,
} from "lucide-react";
import { lazy, Suspense, useCallback, useEffect, useMemo, useRef, useState } from "react";

import { api } from "../../api";
import { SkeletonList, cn } from "../../components/ui";
import { activitySportOptions, emptyActivityRegistry } from "../../fitness/activityRegistry";
import { asFitnessArray, type FitnessActivityRegistry, type FitnessActivitySummary, type FitnessGearItem, type FitnessPhase, type FitnessStrengthSession } from "../../fitness/contract";
import { strengthWorkoutExportText } from "../../fitness/strengthWorkout";
import {
  fitnessPendingImports,
  flushFitnessFitImports,
  queueFitnessFitImport,
  removeFitnessFitImport,
  retryFitnessFitImport,
  type FitnessPendingImport,
} from "../../fitness/offlineStore";
import type { FitnessViewProps } from "./FitnessModuleView";
import { FitnessManualActivityDialog } from "./FitnessManualActivityDialog";
import {
  FitnessCard,
  FitnessLoadingOrError,
  FitnessPageHeading,
  errorMessage,
  formatFitnessDateTime,
  localDateValue,
  useFitnessCollection,
  useFitnessEndpoint,
} from "./shared";

const FitnessActivityDetailDialog = lazy(() => import("./FitnessActivityDetailDialog").then((module) => ({ default: module.FitnessActivityDetailDialog })));
const FitnessGearManager = lazy(() => import("./FitnessGearManager").then((module) => ({ default: module.FitnessGearManager })));

type ActivityFilters = {
  sportKey: string;
  fromDate: string;
  toDate: string;
  phaseId: string;
  classification: string;
  gearId: string;
  status: string;
};

type RunningLoadWindow = {
  days: number;
  distance_m: number;
  duration_s: number;
  session_count: number;
  hard_session_count: number;
  session_rpe_load: number | null;
};

type RunningLoadSummary = {
  windows: { "7d": RunningLoadWindow; "28d": RunningLoadWindow; "42d": RunningLoadWindow };
  volume_change_pct: number | null;
  missing_rpe_sessions: number;
  explanation: string;
};

const emptyRunningLoad: RunningLoadSummary = {
  windows: {
    "7d": { days: 7, distance_m: 0, duration_s: 0, session_count: 0, hard_session_count: 0, session_rpe_load: null },
    "28d": { days: 28, distance_m: 0, duration_s: 0, session_count: 0, hard_session_count: 0, session_rpe_load: null },
    "42d": { days: 42, distance_m: 0, duration_s: 0, session_count: 0, hard_session_count: 0, session_rpe_load: null },
  },
  volume_change_pct: null,
  missing_rpe_sessions: 0,
  explanation: "Distance, duration, hard days and session-RPE load are kept separate; missing RPE is not inferred.",
};

const initialFilters: ActivityFilters = {
  sportKey: "",
  fromDate: "",
  toDate: localDateValue(),
  phaseId: "",
  classification: "",
  gearId: "",
  status: "",
};

function activityIdFromLocation(): string | null {
  return new URL(window.location.href).searchParams.get("activity");
}

function durationLabel(seconds?: number | null): string {
  if (seconds == null) return "Duration unavailable";
  const hours = Math.floor(seconds / 3600);
  const minutes = Math.floor((seconds % 3600) / 60);
  return hours ? `${hours}h ${minutes}m` : `${minutes} min`;
}

function activityDuration(activity: FitnessActivitySummary): number | null {
  return activity.moving_duration_s ?? activity.timer_duration_s ?? activity.duration_s ?? null;
}

function preciseDurationLabel(seconds: number): string {
  const rounded = Math.max(0, Math.round(seconds));
  const hours = Math.floor(rounded / 3_600);
  const minutes = Math.floor((rounded % 3_600) / 60);
  const remainingSeconds = rounded % 60;
  return hours
    ? `${hours}:${String(minutes).padStart(2, "0")}:${String(remainingSeconds).padStart(2, "0")}`
    : `${minutes}:${String(remainingSeconds).padStart(2, "0")}`;
}

function activityMetricNumber(activity: FitnessActivitySummary, ...keys: string[]): number | null {
  return activity.primary_metrics?.find((metric) => keys.includes(metric.metric_key))?.value_number ?? null;
}

function runPaceSeconds(activity: FitnessActivitySummary): number | null {
  const recordedPace = activityMetricNumber(
    activity,
    "running.average_pace_s_per_km",
    "pace.average_s_per_km",
    "pace_s_per_km",
  );
  if (recordedPace != null && recordedPace > 0) return recordedPace;
  const speed = activityMetricNumber(activity, "speed.average_mps");
  if (speed != null && speed > 0) return 1_000 / speed;
  const duration = activityDuration(activity);
  if (activity.distance_m != null && activity.distance_m > 0 && duration != null && duration > 0) {
    return duration * 1_000 / activity.distance_m;
  }
  return null;
}

function paceLabel(secondsPerKilometre: number): string {
  const rounded = Math.max(0, Math.round(secondsPerKilometre));
  return `${Math.floor(rounded / 60)}:${String(rounded % 60).padStart(2, "0")}/km`;
}

async function writeClipboardText(value: string) {
  if (navigator.clipboard?.writeText) {
    await navigator.clipboard.writeText(value);
    return;
  }
  const textarea = document.createElement("textarea");
  textarea.value = value;
  textarea.style.position = "fixed";
  textarea.style.opacity = "0";
  document.body.appendChild(textarea);
  textarea.select();
  document.execCommand("copy");
  textarea.remove();
}

function startOfCurrentWeek(): string {
  const date = new Date();
  const mondayOffset = (date.getDay() + 6) % 7;
  date.setDate(date.getDate() - mondayOffset);
  return localDateValue(date);
}

function ActivityRoutePreview({ points }: { points: Array<[number, number]> }) {
  if (points.length < 2) return null;
  const latitudes = points.map(([latitude]) => latitude);
  const longitudes = points.map(([, longitude]) => longitude);
  const minLatitude = Math.min(...latitudes);
  const maxLatitude = Math.max(...latitudes);
  const minLongitude = Math.min(...longitudes);
  const maxLongitude = Math.max(...longitudes);
  const meanLatitude = (minLatitude + maxLatitude) / 2;
  const longitudeScale = Math.max(Math.cos(meanLatitude * Math.PI / 180), 0.01);
  const projectedPoints = points.map(([latitude, longitude]) => ({
    x: (longitude - minLongitude) * longitudeScale,
    y: latitude - minLatitude,
  }));
  const projectedWidth = (maxLongitude - minLongitude) * longitudeScale;
  const projectedHeight = maxLatitude - minLatitude;
  const availableWidth = 146;
  const availableHeight = 56;
  const plotScale = Math.min(
    availableWidth / Math.max(projectedWidth, 0.000001),
    availableHeight / Math.max(projectedHeight, 0.000001),
  );
  const renderedWidth = projectedWidth * plotScale;
  const renderedHeight = projectedHeight * plotScale;
  const plottedPoints = projectedPoints.map(({ x, y }) => ({
    x: 7 + (availableWidth - renderedWidth) / 2 + x * plotScale,
    y: 7 + (availableHeight - renderedHeight) / 2 + (projectedHeight - y) * plotScale,
  }));
  const path = plottedPoints.map(({ x, y }, index) => `${index ? "L" : "M"}${x.toFixed(1)},${y.toFixed(1)}`).join(" ");
  const start = plottedPoints[0];
  const finish = plottedPoints.at(-1);
  return <svg className="fitness-module__route-preview" viewBox="0 0 160 70" role="img" aria-label="Recorded route shape">
    <path d={path} />
    {start ? <circle className="is-start" cx={start.x} cy={start.y} r="3.5" /> : null}
    {finish ? <circle className="is-finish" cx={finish.x} cy={finish.y} r="3.5" /> : null}
  </svg>;
}

function RunActivityCard({ activity, onOpen }: { activity: FitnessActivitySummary; onOpen: () => void }) {
  const duration = activityDuration(activity);
  const pace = runPaceSeconds(activity);
  const heartRate = activityMetricNumber(activity, "heart_rate.average_bpm", "heart_rate_bpm");
  const route = (activity.route_preview?.length ?? 0) > 1 ? activity.route_preview : null;
  const stats = [
    activity.distance_m != null ? { label: "Distance", value: `${(activity.distance_m / 1_000).toFixed(2)} km` } : null,
    duration != null ? { label: "Time", value: preciseDurationLabel(duration) } : null,
    pace != null ? { label: "Pace", value: paceLabel(pace) } : null,
    heartRate != null ? { label: "Avg HR", value: `${Math.round(heartRate)} bpm` } : null,
  ].filter((stat): stat is { label: string; value: string } => stat !== null);
  const statSummary = stats.map((stat) => `${stat.label} ${stat.value}`).join(", ");
  const detailSummary = [route ? "Route recorded" : null, statSummary || null].filter(Boolean).join(". ");

  return <button
    type="button"
    className={cn("fitness-module__activity-card", "is-run", route && "has-route")}
    aria-label={`Open ${activity.title} run details${detailSummary ? `. ${detailSummary}` : ""}`}
    onClick={onOpen}
  >
    <span className="fitness-module__run-card-body">
      <span className="fitness-module__run-card-top">
        <span className="fitness-module__run-card-heading">
          <span><small>{formatFitnessDateTime(activity.started_at_utc)} · {activity.sport_key.replaceAll("_", " ")}</small><strong>{activity.title}</strong></span>
          {activity.workout_classification ? <em className="fitness-module__pill is-neutral">{activity.workout_classification.replaceAll("_", " ")}</em> : null}
          {activity.status && !["complete", "completed"].includes(activity.status) ? <em className={cn("fitness-module__pill", activity.status === "error" ? "is-warning" : "is-neutral")}>{activity.status.replaceAll("_", " ")}</em> : null}
        </span>
        {activity.planned_session_title ? <small className="fitness-module__activity-match">Matched to {activity.planned_session_title}</small> : null}
        {route ? <span className="fitness-module__run-card-route"><ActivityRoutePreview points={route} /></span> : null}
      </span>
      {stats.length ? <span className="fitness-module__run-card-stats">{stats.map((stat) => <span key={stat.label}><small>{stat.label}</small><strong>{stat.value}</strong></span>)}</span> : <small className="fitness-module__muted">Open this run to see its recorded detail.</small>}
    </span>
  </button>;
}

function StrengthActivityCard({ activity, session, onOpen, onCopy }: {
  activity: FitnessActivitySummary;
  session?: FitnessStrengthSession;
  onOpen: () => void;
  onCopy: () => void;
}) {
  const summary = activity.strength_summary;
  const facts = [
    summary ? `${summary.exercise_count} ${summary.exercise_count === 1 ? "exercise" : "exercises"}` : null,
    summary ? `${summary.set_count} ${summary.set_count === 1 ? "set" : "sets"}` : null,
    durationLabel(activityDuration(activity)),
    summary?.volume_kg ? `${summary.volume_kg.toLocaleString()} kg volume` : null,
  ].filter(Boolean).join(" · ");
  return <article className="fitness-module__strength-activity-card">
    <button type="button" className="fitness-module__activity-card" onClick={onOpen}>
      <div className="fitness-module__activity-card-icon"><Dumbbell aria-hidden="true" size={21} /></div>
      <div className="fitness-module__activity-card-main"><span>{formatFitnessDateTime(activity.started_at_utc)} · strength</span><strong>{activity.title}</strong><small>{facts}</small>{summary?.failure_set_count ? <em className="fitness-module__pill is-neutral">{summary.failure_set_count} to failure</em> : null}</div>
      <span className="fitness-module__strength-card-summary"><small>Working sets</small><strong>{summary?.working_set_count ?? "—"}</strong></span>
    </button>
    <button type="button" className="button button--secondary" disabled={!session} aria-label={`Copy ${activity.title} workout for an LLM`} onClick={onCopy}><Copy aria-hidden="true" size={16} /> Copy workout</button>
  </article>;
}

function ImportStatus({ item, online, onOpen, onRetry, onRemove }: {
  item: FitnessPendingImport;
  online: boolean;
  onOpen: (activityId: string) => void;
  onRetry: (id: string) => void;
  onRemove: (id: string) => void;
}) {
  const Icon = item.status === "complete" ? CheckCircle2 : item.status === "error" ? AlertCircle : item.status === "queued" && !online ? WifiOff : RefreshCw;
  return <li className={cn("fitness-module__import-row", `is-${item.status}`)}>
    <Icon aria-hidden="true" size={19} className={cn(["uploading", "processing"].includes(item.status) && "is-spinning")} />
    <div><strong>{item.fileName}</strong><small>{item.status === "queued" && !online ? "Saved on this device; uploads when you reconnect" : item.status === "processing" ? item.sourceRetained ? "Server source retained; activity is being parsed" : "Processing; local source stays on this device until retention is acknowledged" : item.status === "uploading" ? "Uploading unchanged FIT source" : item.status === "complete" ? item.sourceRetained ? "Import complete · source retained" : "Import complete · local source retained pending server acknowledgement" : item.error ?? "Waiting to upload"}</small></div>
    <div className="fitness-module__button-row">
      {item.activityId ? <button type="button" className="button button--secondary" onClick={() => onOpen(item.activityId ?? "")}>Open</button> : null}
      {item.status === "error" && item.retryable ? <button type="button" className="button button--secondary" disabled={!online && !item.hasLocalFile} onClick={() => onRetry(item.id)}><RotateCcw aria-hidden="true" size={15} /> Retry</button> : null}
      {["complete", "error"].includes(item.status) && (item.sourceRetained || !item.hasLocalFile) ? <button type="button" className="button button--secondary" aria-label={`Dismiss ${item.fileName} import`} onClick={() => onRemove(item.id)}><Trash2 aria-hidden="true" size={15} /></button> : null}
    </div>
  </li>;
}

export function FitnessActivityView({ online, revision, onDataChanged, onAskCoachAboutActivity }: FitnessViewProps) {
  const [filters, setFilters] = useState(initialFilters);
  const [activities, setActivities] = useState<FitnessActivitySummary[]>([]);
  const [imports, setImports] = useState<FitnessPendingImport[]>([]);
  const [selectedActivityId, setSelectedActivityId] = useState(activityIdFromLocation);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [importError, setImportError] = useState<string | null>(null);
  const [gearManagerOpen, setGearManagerOpen] = useState(false);
  const [manualActivityOpen, setManualActivityOpen] = useState(false);
  const [saveNotice, setSaveNotice] = useState<string | null>(null);
  const [nonce, setNonce] = useState(0);
  const fileInput = useRef<HTMLInputElement>(null);
  const gear = useFitnessEndpoint<FitnessGearItem[]>("/fitness/gear", [], revision);
  const phases = useFitnessCollection<FitnessPhase>("/fitness/phases", "training_phase", revision);
  const strengthSessions = useFitnessCollection<FitnessStrengthSession>("/fitness/strength/sessions", "strength_session", revision);
  const registry = useFitnessEndpoint<FitnessActivityRegistry>("/fitness/activity-registry", emptyActivityRegistry, revision);
  const weekStart = startOfCurrentWeek();
  const weeklyActivities = useFitnessEndpoint<FitnessActivitySummary[] | { items?: FitnessActivitySummary[] }>(`/fitness/activities?from_date=${weekStart}&to_date=${localDateValue()}&limit=100&offset=0`, [], revision);
  const runningLoad = useFitnessEndpoint<RunningLoadSummary>("/fitness/running/load", emptyRunningLoad, revision);
  const sportOptions = useMemo(() => activitySportOptions(registry.data, activities.map((activity) => activity.sport_key)), [activities, registry.data]);
  const thisWeek = asFitnessArray(weeklyActivities.data);
  const weeklyDistanceM = thisWeek.reduce((total, activity) => total + (activity.distance_m ?? 0), 0);
  const weeklyDurationS = thisWeek.reduce((total, activity) => total + (activity.timer_duration_s ?? activity.duration_s ?? 0), 0);
  const weeklyElevationM = thisWeek.reduce((total, activity) => total + (activity.primary_metrics?.find((metric) => metric.metric_key === "elevation.gain_m")?.value_number ?? 0), 0);
  const weeklyStrengthCount = thisWeek.filter((activity) => activity.sport_key === "strength").length;

  const query = useMemo(() => {
    const value = new URLSearchParams({ limit: "100", offset: "0" });
    if (filters.sportKey) value.set("sport_key", filters.sportKey);
    if (filters.fromDate) value.set("from_date", filters.fromDate);
    if (filters.toDate) value.set("to_date", filters.toDate);
    if (filters.phaseId) value.set("phase_id", filters.phaseId);
    if (filters.classification) value.set("workout_classification", filters.classification);
    if (filters.gearId) value.set("gear_id", filters.gearId);
    if (filters.status) value.set("status", filters.status);
    return value.toString();
  }, [filters]);

  const refreshImports = useCallback(async (flush = false) => {
    try {
      const next = flush && navigator.onLine ? await flushFitnessFitImports() : await fitnessPendingImports();
      setImports(next);
    } catch {
      // A signed-out transition can race this private local-store refresh.
    }
  }, []);

  useEffect(() => {
    const changed = () => void refreshImports();
    window.addEventListener("hausklar:fitness-imports-changed", changed);
    void refreshImports(online);
    return () => window.removeEventListener("hausklar:fitness-imports-changed", changed);
  }, [online, refreshImports]);

  useEffect(() => {
    if (!imports.some((item) => item.status === "processing" || (item.status === "complete" && !item.sourceRetained)) || !online) return;
    const timer = window.setInterval(() => void refreshImports(true), 8_000);
    return () => window.clearInterval(timer);
  }, [imports, online, refreshImports]);

  useEffect(() => {
    let active = true;
    setLoading(true);
    setError(null);
    void api<FitnessActivitySummary[]>(`/fitness/activities?${query}`, {}, true, false)
      .then((response) => { if (active) setActivities(response); })
      .catch((requestError) => { if (active) setError(errorMessage(requestError)); })
      .finally(() => { if (active) setLoading(false); });
    return () => { active = false; };
  }, [nonce, query, revision]);

  useEffect(() => {
    const popped = () => setSelectedActivityId(activityIdFromLocation());
    window.addEventListener("popstate", popped);
    return () => window.removeEventListener("popstate", popped);
  }, []);

  function openActivity(activityId: string) {
    const url = new URL(window.location.href);
    url.searchParams.set("view", "fitness");
    url.searchParams.set("section", "activity");
    url.searchParams.set("activity", activityId);
    window.history.pushState({}, "", url);
    setSelectedActivityId(activityId);
  }

  function closeActivity() {
    const url = new URL(window.location.href);
    url.searchParams.delete("activity");
    window.history.replaceState({}, "", url);
    setSelectedActivityId(null);
  }

  async function chooseFile(file: File | null) {
    if (!file) return;
    setImportError(null);
    try {
      await queueFitnessFitImport(file);
      await refreshImports(online);
    } catch (requestError) {
      setImportError(errorMessage(requestError));
    } finally {
      if (fileInput.current) fileInput.current.value = "";
    }
  }

  async function retryImport(id: string) {
    setImportError(null);
    try {
      await retryFitnessFitImport(id);
      await refreshImports();
    } catch (requestError) {
      setImportError(errorMessage(requestError));
    }
  }

  async function copyStrengthWorkout(session: FitnessStrengthSession) {
    try {
      await writeClipboardText(strengthWorkoutExportText(session));
      setSaveNotice("Workout copied — ready to paste into an LLM.");
    } catch {
      setSaveNotice("Could not copy the workout. Try again after allowing clipboard access.");
    }
  }

  const activityCard = (activity: FitnessActivitySummary) => activity.sport_key === "strength" ? <StrengthActivityCard activity={activity} session={strengthSessions.data.find((item) => item.id === activity.id)} onOpen={() => openActivity(activity.id)} onCopy={() => { const session = strengthSessions.data.find((item) => item.id === activity.id); if (session) void copyStrengthWorkout(session); }} key={activity.id} /> : activity.sport_key.includes("run") ? <RunActivityCard activity={activity} onOpen={() => openActivity(activity.id)} key={activity.id} /> : <button type="button" className="fitness-module__activity-card" onClick={() => openActivity(activity.id)} key={activity.id}>
    <div className="fitness-module__activity-card-icon"><Activity aria-hidden="true" size={21} /></div>
    <div className="fitness-module__activity-card-main"><span>{formatFitnessDateTime(activity.started_at_utc)} · {activity.sport_key.replaceAll("_", " ")}</span><strong>{activity.title}</strong><small>{[activity.distance_m != null ? `${(activity.distance_m / 1000).toFixed(2)} km` : null, durationLabel(activity.timer_duration_s ?? activity.duration_s), activity.energy_kcal != null ? `${activity.energy_estimation_method ? "≈ " : ""}${Math.round(activity.energy_kcal)} kcal` : null, activity.workout_classification?.replaceAll("_", " "), activity.gear?.map((item) => item.name).join(", ")].filter(Boolean).join(" · ")}</small>{activity.planned_session_title ? <small className="fitness-module__activity-match">Matched to {activity.planned_session_title}</small> : null}{activity.status && !["complete", "completed"].includes(activity.status) ? <em className={cn("fitness-module__pill", activity.status === "error" ? "is-warning" : "is-neutral")}>{activity.status.replaceAll("_", " ")}</em> : null}</div>
    {activity.route_preview?.length ? <ActivityRoutePreview points={activity.route_preview} /> : <Map aria-hidden="true" size={21} />}
  </button>;

  return <section aria-labelledby="fitness-activity-title">
    <FitnessPageHeading
      title="Activities"
      detail="Past runs, rides and workouts."
      actions={<button type="button" className="button button--primary" onClick={() => { setSaveNotice(null); setManualActivityOpen(true); }}><Plus aria-hidden="true" size={17} /> Log activity</button>}
    />
    {saveNotice ? <div className="fitness-module__notice fitness-module__notice--success" role="status">{saveNotice}</div> : null}

    <FitnessCard title="This week" detail={`${weekStart} to today`} className="is-wide">
      <div className="fitness-module__weekly-summary">
        <div><small>Activities</small><strong>{weeklyActivities.loading ? "—" : thisWeek.length}</strong></div>
        <div><small>Active time</small><strong>{weeklyActivities.loading ? "—" : durationLabel(weeklyDurationS)}</strong></div>
        <div><small>Strength sessions</small><strong>{weeklyActivities.loading ? "—" : weeklyStrengthCount}</strong></div>
        <div><small>Distance</small><strong>{weeklyActivities.loading ? "—" : weeklyDistanceM ? `${(weeklyDistanceM / 1000).toFixed(1)} km` : "—"}</strong></div>
        {!weeklyActivities.loading && weeklyElevationM > 0 ? <div><small>Elevation</small><strong>{Math.round(weeklyElevationM).toLocaleString()} m</strong></div> : null}
      </div>
      {!runningLoad.loading && !runningLoad.error ? <div className="fitness-module__running-load" aria-label="Transparent running load summary"><div><strong>7-day running load</strong><span>{(runningLoad.data.windows["7d"].distance_m / 1000).toFixed(1)} km · {durationLabel(runningLoad.data.windows["7d"].duration_s)} · {runningLoad.data.windows["7d"].hard_session_count} hard</span><small>{runningLoad.data.windows["7d"].session_rpe_load == null ? "Session-RPE load unavailable" : `Session-RPE load ${runningLoad.data.windows["7d"].session_rpe_load.toLocaleString()}`}</small></div><div><strong>28-day running load</strong><span>{(runningLoad.data.windows["28d"].distance_m / 1000).toFixed(1)} km · {durationLabel(runningLoad.data.windows["28d"].duration_s)} · {runningLoad.data.windows["28d"].hard_session_count} hard</span><small>{runningLoad.data.windows["28d"].session_rpe_load == null ? "Session-RPE load unavailable" : `Session-RPE load ${runningLoad.data.windows["28d"].session_rpe_load.toLocaleString()}`}</small></div></div> : null}
      {runningLoad.error ? <p className="fitness-module__muted">Running load is unavailable right now.</p> : null}
      <details className="fitness-module__details"><summary>How running load is calculated</summary><p>{runningLoad.data.explanation}</p><p>{runningLoad.data.missing_rpe_sessions} recent running {runningLoad.data.missing_rpe_sessions === 1 ? "session is" : "sessions are"} missing RPE; HausKlar leaves that component unknown.</p></details>
    </FitnessCard>

    <FitnessLoadingOrError loading={loading} error={error} retry={() => setNonce((value) => value + 1)} />
    {!loading && !error ? <FitnessCard title="Recent activity" detail={`${activities.length} ${activities.length === 1 ? "activity" : "activities"} in this view`} className="is-wide">
      <div className="fitness-module__activity-list">
        {activities.slice(0, 12).map(activityCard)}
        {!activities.length ? <div className="fitness-module__empty"><strong>No activities match</strong><span>Log a completed activity, import a FIT source, or open Manage to clear filters.</span></div> : null}
      </div>
      {activities.length > 12 ? <details className="fitness-module__details"><summary>Older activity history ({activities.length - 12})</summary><div className="fitness-module__activity-list">{activities.slice(12).map(activityCard)}</div></details> : null}
    </FitnessCard> : null}

    <details className="fitness-module__maintenance">
      <summary>Manage imports, gear and filters</summary>
      <div className="fitness-module__maintenance-body">
        <div className="fitness-module__button-row"><input ref={fileInput} aria-label="Choose FIT file to import" className="fitness-module__file-input" type="file" accept=".fit,application/octet-stream" onChange={(event) => void chooseFile(event.target.files?.[0] ?? null)} /><button type="button" className="button button--secondary" onClick={() => setGearManagerOpen((value) => !value)}><Footprints aria-hidden="true" size={17} /> Gear</button><button type="button" className="button button--primary" onClick={() => fileInput.current?.click()}><FileUp aria-hidden="true" size={17} /> Import FIT</button></div>
        {gearManagerOpen ? <Suspense fallback={<SkeletonList rows={4} />}><FitnessGearManager items={gear.data} onChanged={() => { gear.reload(); setNonce((value) => value + 1); }} onClose={() => setGearManagerOpen(false)} /></Suspense> : null}
        <FitnessCard title="Manual FIT imports" detail="Files chosen offline stay on this device. Parser errors retain the server source for an explicit retry.">
          {importError ? <div className="fitness-module__notice fitness-module__notice--error" role="alert">{importError}</div> : null}
          {imports.length ? <ul className="fitness-module__imports">{imports.map((item) => <ImportStatus item={item} online={online} onOpen={openActivity} onRetry={(id) => void retryImport(id)} onRemove={(id) => void removeFitnessFitImport(id).then(() => refreshImports())} key={item.id} />)}</ul> : <div className="fitness-module__empty"><strong>No FIT import pending</strong><span>Choose an original .fit file from Garmin, Files, or another source.</span></div>}
        </FitnessCard>
        <FitnessCard title="History filters" detail="Narrow this private history without changing the weekly summary.">
          <div className="fitness-module__fields fitness-module__activity-filters">
            <label className="fitness-module__field">Sport<select value={filters.sportKey} onChange={(event) => setFilters((value) => ({ ...value, sportKey: event.target.value }))}><option value="">All sports</option>{sportOptions.map((sport) => <option value={sport.key} key={sport.key}>{sport.display_name}</option>)}</select></label>
            <label className="fitness-module__field">From<input type="date" value={filters.fromDate} max={filters.toDate} onChange={(event) => setFilters((value) => ({ ...value, fromDate: event.target.value }))} /></label>
            <label className="fitness-module__field">To<input type="date" value={filters.toDate} min={filters.fromDate} onChange={(event) => setFilters((value) => ({ ...value, toDate: event.target.value }))} /></label>
            <label className="fitness-module__field">Phase<select value={filters.phaseId} onChange={(event) => setFilters((value) => ({ ...value, phaseId: event.target.value }))}><option value="">All phases</option>{phases.data.map((phase) => <option value={phase.id} key={phase.id}>{phase.name}</option>)}</select></label>
            <label className="fitness-module__field">Classification<select value={filters.classification} onChange={(event) => setFilters((value) => ({ ...value, classification: event.target.value }))}><option value="">All classifications</option>{["recovery", "easy", "steady", "long", "tempo", "threshold", "interval", "hill", "race", "time_trial", "progression", "mixed", "unclassified"].map((value) => <option value={value} key={value}>{value.replaceAll("_", " ")}</option>)}</select></label>
            <label className="fitness-module__field">Gear<select value={filters.gearId} onChange={(event) => setFilters((value) => ({ ...value, gearId: event.target.value }))}><option value="">All gear</option>{gear.data.map((item) => <option value={item.id} key={item.id}>{item.name}</option>)}</select></label>
            <label className="fitness-module__field">Import state<select value={filters.status} onChange={(event) => setFilters((value) => ({ ...value, status: event.target.value }))}><option value="">All states</option><option value="complete">Complete</option><option value="importing">Importing</option><option value="regenerating">Regenerating</option><option value="error">Needs attention</option></select></label>
            <button type="button" className="button button--secondary" onClick={() => setFilters(initialFilters)}><Filter aria-hidden="true" size={16} /> Clear filters</button>
          </div>
        </FitnessCard>
        <p className="fitness-module__privacy-note"><Clock3 aria-hidden="true" size={16} /> Initial activity details load before stream files; overview requests are downsampled and zoom requests only the selected range.</p>
      </div>
    </details>

    {selectedActivityId ? <Suspense fallback={<SkeletonList rows={6} />}><FitnessActivityDetailDialog activityId={selectedActivityId} open online={online} onOpenChange={(nextOpen) => { if (!nextOpen) closeActivity(); }} onChanged={() => { setNonce((value) => value + 1); onDataChanged(); }} onAskCoach={onAskCoachAboutActivity} /></Suspense> : null}
    <FitnessManualActivityDialog
      open={manualActivityOpen}
      onOpenChange={setManualActivityOpen}
      sports={sportOptions}
      online={online}
      onSaved={(activity, message) => {
        setActivities((current) => [activity, ...current.filter((item) => item.id !== activity.id)]);
        setSaveNotice(message);
        if (online) {
          setNonce((value) => value + 1);
          onDataChanged();
        }
      }}
    />
  </section>;
}
