import {
  Activity,
  ArrowLeft,
  ChevronRight,
  Download,
  Dumbbell,
  HeartPulse,
  Images,
  LoaderCircle,
  Pencil,
  Plus,
  Scale,
  Sparkles,
  Target,
  TrendingUp,
} from "lucide-react";
import { lazy, Suspense, useMemo, useState } from "react";

import { api, getAuthSessionEpoch } from "../../api";
import { SkeletonList, cn } from "../../components/ui";
import { asFitnessArray } from "../../fitness/contract";
import type {
  FitnessActivitySummary,
  FitnessBodyMeasurement,
  FitnessGoal,
  FitnessWeeklyReview,
} from "../../fitness/contract";
import {
  emptyFitnessProgressCharts,
  FitnessOverviewWeightChart,
  FitnessPerformanceCharts,
} from "./FitnessProgressCharts";
import { FitnessMeasurementTrends } from "./FitnessMeasurementTrends";
import type { FitnessViewProps } from "./FitnessModuleView";
import "./fitness-wave4.css";
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
  useFitnessCollection,
  useFitnessEndpoint,
  useFitnessProgressCharts,
  useFitnessSave,
  utcFromLocalInput,
} from "./shared";

const FitnessProgressPhotos = lazy(() => import("./FitnessProgressPhotos").then((module) => ({ default: module.FitnessProgressPhotos })));

type ProgressArea = "summary" | "measurements" | "photos" | "export";

const bodyMeasurementChoices = [
  { key: "body.weight_kg", label: "Weight", unit: "kg" },
  { key: "body.height_cm", label: "Height", unit: "cm" },
  { key: "body.waist_cm", label: "Waist", unit: "cm" },
  { key: "body.chest_cm", label: "Chest", unit: "cm" },
  { key: "body.hips_cm", label: "Hips", unit: "cm" },
  { key: "body.upper_arm_cm", label: "Upper arm", unit: "cm" },
  { key: "body.thigh_cm", label: "Thigh", unit: "cm" },
  { key: "body.body_fat_pct", label: "Body fat", unit: "%" },
] as const;

const bodyFatMetricKeys = new Set(["body.body_fat_pct", "body.body_fat_percent"]);
const heightMetricKeys = new Set(["body.height_cm", "body.height_m"]);
const weightMetricKeys = new Set(["body.weight_kg"]);
const weekMilliseconds = 7 * 24 * 60 * 60 * 1_000;
const weeklyReferenceToleranceMilliseconds = 3 * 24 * 60 * 60 * 1_000;

type BodyTrendReading = Pick<FitnessBodyMeasurement, "id" | "measured_at_utc" | "value" | "unit_key">;

function currentWeekStart(): string {
  const date = new Date(`${localDateValue()}T12:00:00`);
  date.setDate(date.getDate() - ((date.getDay() + 6) % 7));
  return localDateValue(date);
}

function emptyWeeklyReview(weekStart: string): FitnessWeeklyReview {
  return {
    week_start: weekStart,
    week_end: weekStart,
    totals: { completed_sessions: 0, active_days: 0 },
    goal: null,
    highlight: { title: "A fresh week", detail: "One useful action is enough to begin." },
    opportunity: { title: "Make the first move", detail: "Choose one realistic session.", destination: "plan", action: "plan_session", action_label: "Plan a session" },
  };
}

function initialProgressArea(): ProgressArea {
  const query = new URLSearchParams(window.location.search);
  if (query.get("fitness-progress") === "photos" || query.get("section") === "photos") return "photos";
  if (query.get("fitness-progress") === "measurements" || query.get("section") === "measurements") return "measurements";
  return "summary";
}

function measurementLabel(key: string): string {
  if (bodyFatMetricKeys.has(key)) return "Body fat";
  if (heightMetricKeys.has(key)) return "Height";
  return bodyMeasurementChoices.find((item) => item.key === key)?.label
    ?? key.replace(/^body\./, "").replaceAll("_", " ").replace(/\b\w/g, (letter) => letter.toUpperCase());
}

function customMeasurementKey(name: string): string {
  const slug = name.trim().toLocaleLowerCase().replace(/[^a-z0-9]+/g, "_").replace(/^_+|_+$/g, "");
  return slug ? `body.${slug}` : "";
}

function exportFileName(response: Response): string {
  const disposition = response.headers.get("Content-Disposition") ?? response.headers.get("content-disposition") ?? "";
  const encoded = disposition.match(/filename\*=UTF-8''([^;]+)/i)?.[1];
  const plain = disposition.match(/filename="?([^";]+)"?/i)?.[1];
  if (encoded) return decodeURIComponent(encoded);
  if (plain) return plain;
  return `hausklar-fitness-export-${localDateValue()}.zip`;
}

export function FitnessDataExportCard({ online }: { online: boolean }) {
  const [exporting, setExporting] = useState(false);
  const [exportError, setExportError] = useState<string | null>(null);

  async function downloadExport() {
    if (!online || exporting) return;
    setExporting(true);
    setExportError(null);
    try {
      await api<unknown>("/auth/web/session", {}, true, false);
      const authEpoch = getAuthSessionEpoch();
      const response = await fetch("/api/fitness/export", { credentials: "same-origin", cache: "no-store", headers: { Accept: "application/zip" } });
      if (!response.ok) {
        let message = "Your Fitness data could not be prepared.";
        try {
          const body = await response.json() as { detail?: string };
          if (typeof body.detail === "string") message = body.detail;
        } catch { /* An empty response still gets a useful message. */ }
        throw new Error(message);
      }
      if (getAuthSessionEpoch() !== authEpoch) throw new Error("The signed-in account changed. Start this download again for the current account.");
      const blob = await response.blob();
      if (getAuthSessionEpoch() !== authEpoch) throw new Error("The signed-in account changed. Start this download again for the current account.");
      const url = URL.createObjectURL(blob);
      const link = document.createElement("a");
      link.href = url;
      link.download = exportFileName(response);
      link.style.display = "none";
      document.body.append(link);
      link.click();
      link.remove();
      window.setTimeout(() => URL.revokeObjectURL(url), 0);
    } catch (requestError) {
      setExportError(errorMessage(requestError));
    } finally {
      setExporting(false);
    }
  }

  return <FitnessCard title="Download your Fitness data" detail="A private copy of the Fitness records and files saved to your account.">
    <p className="fitness-module__muted">The download may take a moment if it includes activity files or private photos.</p>
    <div className="fitness-module__form-footer">
      <button className="button button--primary" disabled={!online || exporting} type="button" aria-busy={exporting} onClick={() => void downloadExport()}>{exporting ? <LoaderCircle className="is-spinning" size={16} aria-hidden="true" /> : <Download size={16} aria-hidden="true" />} {exporting ? "Preparing download…" : "Download ZIP"}</button>
    </div>
    {!online ? <p className="fitness-module__form-status">Connect to the internet to prepare a complete download.</p> : null}
    {exportError ? <div className="fitness-module__notice fitness-module__notice--error" role="alert"><span>{exportError}</span><button type="button" className="button button--secondary button--compact" onClick={() => void downloadExport()}>Try again</button></div> : null}
  </FitnessCard>;
}

type GoalTrendPoint = { label: string; value: number };

function trendSummary(label: string, points: GoalTrendPoint[], unit: string): string {
  const latest = points.at(-1)?.value ?? 0;
  const average = points.reduce((total, point) => total + point.value, 0) / Math.max(1, points.length);
  const formattedLatest = latest.toLocaleString(undefined, { maximumFractionDigits: 1 });
  const formattedAverage = average.toLocaleString(undefined, { maximumFractionDigits: 1 });
  return `${label}: ${formattedLatest} ${unit} this week, averaging ${formattedAverage} ${unit} across ${points.length} weeks.`;
}

function GoalTrendFigure({ title, points, unit }: { title: string; points: GoalTrendPoint[]; unit: string }) {
  const maximum = Math.max(1, ...points.map((point) => point.value));
  const polyline = points.map((point, index) => `${12 + index / Math.max(1, points.length - 1) * 276},${86 - point.value / maximum * 66}`).join(" ");
  const summary = trendSummary(title, points, unit);
  return <figure className="fitness-wave4__goal-chart"><figcaption><span>{title}</span><strong>{summary}</strong></figcaption><svg viewBox="0 0 300 96" preserveAspectRatio="none" role="img" aria-label={summary}><path d="M12 86H288" className="is-grid" /><polyline points={polyline} className="is-line" />{points.map((point, index) => <circle key={point.label} cx={12 + index / Math.max(1, points.length - 1) * 276} cy={86 - point.value / maximum * 66} r="3" />)}</svg><div aria-hidden="true">{points.map((point) => <span key={point.label}>{point.label}</span>)}</div></figure>;
}

function mondayFor(value: string): string {
  const date = new Date(`${value.slice(0, 10)}T12:00:00`);
  date.setDate(date.getDate() - ((date.getDay() + 6) % 7));
  return localDateValue(date);
}

function activityTrend(goal: FitnessGoal, activities: FitnessActivitySummary[]): { title: string; unit: string; points: GoalTrendPoint[] } {
  const thisWeek = new Date(`${currentWeekStart()}T12:00:00`);
  const weeks = Array.from({ length: 4 }, (_, index) => {
    const date = new Date(thisWeek);
    date.setDate(thisWeek.getDate() - (3 - index) * 7);
    const start = localDateValue(date);
    return { start, label: new Intl.DateTimeFormat(undefined, { day: "numeric", month: "short" }).format(date) };
  });
  const metric = goal.metric_key;
  const points = weeks.map((week) => {
    const rows = activities.filter((activity) => mondayFor(activity.started_at_utc) === week.start && ["complete", "completed"].includes(activity.status ?? ""));
    if (metric === "running.distance_m") return { label: week.label, value: rows.filter((activity) => activity.sport_key === "running").reduce((total, activity) => total + (activity.distance_m ?? 0), 0) / 1_000 };
    if (metric === "strength.sessions_per_week" || metric === "strength.sessions") return { label: week.label, value: rows.filter((activity) => activity.sport_key === "strength").length };
    if (metric === "activity.active_days_per_week") return { label: week.label, value: new Set(rows.map((activity) => activity.started_at_utc.slice(0, 10))).size };
    return { label: week.label, value: rows.length };
  });
  if (metric === "running.distance_m") return { title: "Synthetic public demo record 2", unit: "km", points };
  if (metric === "strength.sessions_per_week" || metric === "strength.sessions") return { title: "Weekly strength sessions", unit: "sessions", points };
  if (metric === "activity.active_days_per_week") return { title: "Active days each week", unit: "days", points };
  return { title: "Completed sessions each week", unit: "sessions", points };
}

function SelectedGoalTrend({ review, goal, activities, loading, error, retry }: {
  review: FitnessWeeklyReview;
  goal: FitnessGoal | null;
  activities: FitnessActivitySummary[];
  loading: boolean;
  error: string | null;
  retry: () => void;
}) {
  if (!review.goal) return <FitnessCard title="Selected goal" detail="One goal keeps Review focused."><div className="fitness-wave4__goal-empty"><Target aria-hidden="true" size={22} /><div><strong>Choose one goal to follow</strong><p>Your weekly review will turn it into a useful trend.</p></div></div></FitnessCard>;
  if (loading || error || !goal) return <FitnessCard title={review.goal.goal_name} detail={review.goal.progress_text} className="fitness-wave4__selected-goal"><FitnessLoadingOrError loading={loading} error={error ?? (!goal ? "This goal could not be opened." : null)} retry={retry} /></FitnessCard>;
  if (goal.metric_key === "body.weight_kg") return <FitnessCard title={goal.name} detail={review.goal.progress_text} className="fitness-wave4__selected-goal">{review.goal.progress_percent != null ? <div className="fitness-wave4__goal-progress" role="progressbar" aria-label={`${review.goal.goal_name}: ${review.goal.progress_percent}% this week`} aria-valuemin={0} aria-valuemax={100} aria-valuenow={review.goal.progress_percent}><span style={{ width: `${review.goal.progress_percent}%` }} /></div> : null}<p className="fitness-module__muted">Your weigh-ins and smoothed trend stay visible below.</p></FitnessCard>;
  const trend = activityTrend(goal, activities);
  return <FitnessCard title={goal.name} detail={review.goal.progress_text} className="fitness-wave4__selected-goal"><FitnessLoadingOrError loading={loading} error={error} retry={retry} />{!loading && !error ? <><GoalTrendFigure title={trend.title} points={trend.points} unit={trend.unit} />{review.goal.progress_percent != null ? <div className="fitness-wave4__goal-progress" role="progressbar" aria-label={`${review.goal.goal_name}: ${review.goal.progress_percent}% this week`} aria-valuemin={0} aria-valuemax={100} aria-valuenow={review.goal.progress_percent}><span style={{ width: `${review.goal.progress_percent}%` }} /></div> : null}</> : null}</FitnessCard>;
}

function activityDuration(activity: FitnessActivitySummary): number | null {
  return activity.moving_duration_s ?? activity.timer_duration_s ?? activity.duration_s ?? null;
}

function runningPace(activity: FitnessActivitySummary): string | null {
  const duration = activityDuration(activity);
  if (!activity.sport_key.includes("run") || !activity.distance_m || activity.distance_m <= 0 || !duration || duration <= 0) return null;
  const secondsPerKilometre = Math.round(duration / (activity.distance_m / 1_000));
  return `${Math.floor(secondsPerKilometre / 60)}:${String(secondsPerKilometre % 60).padStart(2, "0")}/km`;
}

function activitySummary(activity: FitnessActivitySummary): string {
  const duration = activityDuration(activity);
  return [
    formatFitnessDateTime(activity.started_at_utc),
    activity.sport_key.replaceAll("_", " "),
    activity.distance_m != null ? `${(activity.distance_m / 1_000).toFixed(1)} km` : null,
    runningPace(activity),
    duration != null ? `${Math.round(duration / 60)} min` : null,
    activity.energy_kcal != null ? `${activity.energy_estimation_method ? "≈ " : ""}${Math.round(activity.energy_kcal)} kcal` : null,
  ].filter(Boolean).join(" · ");
}

function ActivityHistory({ rows, loading, error, retry, onOpenActivity, onOpenHistory }: { rows: FitnessActivitySummary[]; loading: boolean; error: string | null; retry: () => void; onOpenActivity: (activityId: string) => void; onOpenHistory: () => void }) {
  return <FitnessCard title="Recent activity" detail="Your completed sessions, newest first." className="fitness-wave4__activity-card">
    <FitnessLoadingOrError loading={loading} error={error} retry={retry} />
    {!loading && !error && rows.length ? <ul className="fitness-wave4__activity-list">{rows.slice(0, 6).map((activity) => <li key={activity.id}><button type="button" className="fitness-wave4__activity-button" onClick={() => onOpenActivity(activity.id)}><Activity aria-hidden="true" size={18} /><div><strong>{activity.title}</strong><small>{activitySummary(activity)}</small>{activity.planned_session_title ? <small className="fitness-wave4__activity-match">Matched to {activity.planned_session_title}</small> : null}</div><ChevronRight aria-hidden="true" size={18} /></button></li>)}</ul> : null}
    {!loading && !error && !rows.length ? <div className="fitness-module__empty"><Activity aria-hidden="true" size={24} /><strong>No completed activity yet</strong><span>Finish a workout or add an activity to begin your history.</span></div> : null}
    <button type="button" className="button button--secondary" onClick={onOpenHistory}>Open activity history</button>
  </FitnessCard>;
}

function trackedMeasurements(measurements: FitnessBodyMeasurement[], metricKeys: Set<string>): BodyTrendReading[] {
  return measurements
    .filter((item) => metricKeys.has(item.metric_key) && item.canonical_state !== "excluded" && item.canonical_state !== "duplicate" && Number.isFinite(item.value) && Number.isFinite(Date.parse(item.measured_at_utc)))
    .sort((left, right) => left.measured_at_utc.localeCompare(right.measured_at_utc))
    .slice(-30);
}

function heightInMetres(reading: FitnessBodyMeasurement): number | null {
  const unit = reading.unit_key.trim().toLocaleLowerCase();
  const metres = reading.metric_key === "body.height_m" || unit === "m" || unit === "metre" || unit === "metres"
    ? reading.value
    : reading.value / 100;
  return Number.isFinite(metres) && metres > 0 ? metres : null;
}

function bmiMeasurements(measurements: FitnessBodyMeasurement[], weights: BodyTrendReading[]): BodyTrendReading[] {
  const heights = measurements
    .filter((item) => heightMetricKeys.has(item.metric_key) && item.canonical_state !== "excluded" && item.canonical_state !== "duplicate" && Number.isFinite(Date.parse(item.measured_at_utc)))
    .map((item) => ({ reading: item, metres: heightInMetres(item) }))
    .filter((item): item is { reading: FitnessBodyMeasurement; metres: number } => item.metres !== null)
    .sort((left, right) => left.reading.measured_at_utc.localeCompare(right.reading.measured_at_utc));
  if (!heights.length) return [];
  return weights.map((weight) => {
    const height = [...heights].reverse().find((item) => item.reading.measured_at_utc <= weight.measured_at_utc) ?? heights[0];
    return {
      id: `bmi-${weight.id}`,
      measured_at_utc: weight.measured_at_utc,
      value: weight.value / (height.metres * height.metres),
      unit_key: "",
    };
  }).filter((item) => Number.isFinite(item.value));
}

function readingValue(reading: BodyTrendReading): string {
  const value = reading.value.toLocaleString(undefined, { maximumFractionDigits: 1 });
  return reading.unit_key ? `${value} ${reading.unit_key}` : value;
}

function weeklyChange(readings: BodyTrendReading[], changeUnit?: string): string | null {
  const latest = readings.at(-1);
  if (!latest) return null;
  const targetTime = Date.parse(latest.measured_at_utc) - weekMilliseconds;
  const reference = readings
    .slice(0, -1)
    .map((item) => ({ item, distance: Math.abs(Date.parse(item.measured_at_utc) - targetTime) }))
    .filter((candidate) => candidate.distance <= weeklyReferenceToleranceMilliseconds)
    .sort((left, right) => left.distance - right.distance)[0]?.item;
  if (!reference) return null;
  const change = latest.value - reference.value;
  if (Math.abs(change) < 0.05) return "No change from a week ago";
  const amount = Math.abs(change).toLocaleString(undefined, { maximumFractionDigits: 1 });
  const unit = changeUnit ?? (latest.unit_key === "%" ? "points" : latest.unit_key);
  return `${amount}${unit ? ` ${unit}` : ""} ${change > 0 ? "higher" : "lower"} than a week ago`;
}

function CurrentMeasurement({ title, readings, emptyText = "No reading yet", changeUnit }: { title: string; readings: BodyTrendReading[]; emptyText?: string; changeUnit?: string }) {
  const latest = readings.at(-1);
  const change = weeklyChange(readings, changeUnit);
  return <article className="fitness-wave4__body-current-card">
    <span>{title}</span>
    {latest ? <>
      <div><strong>{latest.value.toLocaleString(undefined, { maximumFractionDigits: 1 })}</strong>{latest.unit_key ? <small>{latest.unit_key}</small> : null}</div>
      {change ? <p>{change}</p> : null}
    </> : <><div><strong>—</strong></div><p>{emptyText}</p></>}
  </article>;
}

function MeasurementTrend({ title, readings, emptyText = "Add a reading whenever it is useful.", changeUnit }: { title: string; readings: BodyTrendReading[]; emptyText?: string; changeUnit?: string }) {
  if (!readings.length) return <FitnessCard title={title}><div className="fitness-module__empty"><TrendingUp aria-hidden="true" size={24} /><strong>No {title === "BMI" ? "BMI" : title.toLocaleLowerCase()} trend yet</strong><span>{emptyText}</span></div></FitnessCard>;
  const values = readings.map((item) => item.value);
  const minimum = Math.min(...values);
  const maximum = Math.max(...values);
  const range = Math.max(maximum - minimum, 0.5);
  const points = readings.map((item, index) => {
    const x = 8 + index / Math.max(1, readings.length - 1) * 284;
    const y = 86 - (item.value - minimum) / range * 68;
    return { id: item.id, x, y };
  });
  const first = readings[0];
  const last = readings[readings.length - 1];
  const change = last.value - first.value;
  const unit = changeUnit ?? last.unit_key;
  const changeSummary = Math.abs(change) < 0.01
    ? "unchanged across the readings shown"
    : `${Math.abs(change).toLocaleString(undefined, { maximumFractionDigits: 1 })}${unit ? ` ${unit}` : ""} ${change > 0 ? "higher" : "lower"} across the readings shown`;
  const summary = readings.length === 1
    ? `${readingValue(last)} on ${formatFitnessDate(last.measured_at_utc)}.`
    : `${readingValue(last)} now, ${changeSummary}.`;
  return <FitnessCard title={title} className="fitness-wave4__body-trend-card"><figure className="fitness-wave4__mini-chart">
    <figcaption><strong>{summary}</strong></figcaption>
    <svg viewBox="0 0 300 96" role="img" aria-label={`${title}. ${summary}`} preserveAspectRatio="none"><path d="M8 86H292" className="is-grid" />{points.length > 1 ? <polyline points={points.map((point) => `${point.x.toFixed(1)},${point.y.toFixed(1)}`).join(" ")} className="is-line" /> : null}{points.map((point) => <circle key={point.id} cx={point.x} cy={point.y} r="3" />)}</svg>
    <div aria-hidden="true"><span>{formatFitnessDate(first.measured_at_utc)}</span><span>{formatFitnessDate(last.measured_at_utc)}</span></div>
  </figure></FitnessCard>;
}

function ProgressMeasurements({ online, revision, onDataChanged }: Pick<FitnessViewProps, "online" | "revision" | "onDataChanged">) {
  const measurements = useFitnessCollection<FitnessBodyMeasurement>("/fitness/body/measurements", "body_measurement", revision);
  const save = useFitnessSave(onDataChanged);
  const [formOpen, setFormOpen] = useState(false);
  const [editing, setEditing] = useState<FitnessBodyMeasurement | null>(null);
  const [kind, setKind] = useState("body.weight_kg");
  const [customName, setCustomName] = useState("");
  const [value, setValue] = useState("");
  const [unit, setUnit] = useState("kg");
  const [measuredAt, setMeasuredAt] = useState(localDateTimeValue());
  const [note, setNote] = useState("");

  const visible = useMemo(() => measurements.data
    .filter((item) => item.canonical_state !== "excluded" && item.canonical_state !== "duplicate")
    .sort((left, right) => right.measured_at_utc.localeCompare(left.measured_at_utc)), [measurements.data]);
  const weightReadings = useMemo(() => trackedMeasurements(measurements.data, weightMetricKeys), [measurements.data]);
  const bodyFatReadings = useMemo(() => trackedMeasurements(measurements.data, bodyFatMetricKeys), [measurements.data]);
  const bmiReadings = useMemo(() => bmiMeasurements(measurements.data, weightReadings), [measurements.data, weightReadings]);

  function closeForm() {
    setFormOpen(false);
    setEditing(null);
    setKind("body.weight_kg");
    setCustomName("");
    setValue("");
    setUnit("kg");
    setMeasuredAt(localDateTimeValue());
    setNote("");
  }

  function edit(item: FitnessBodyMeasurement) {
    if (item.source_record_id) return;
    setEditing(item);
    setKind(bodyFatMetricKeys.has(item.metric_key) ? "body.body_fat_pct" : item.metric_key);
    setValue(String(item.value));
    setUnit(item.unit_key);
    setMeasuredAt(localDateTimeValue(new Date(item.measured_at_utc)));
    setNote(item.notes ?? "");
    setFormOpen(true);
  }

  async function record() {
    const metricKey = kind === "__custom__" ? customMeasurementKey(customName) : kind;
    if (!metricKey || !value || !unit.trim()) return;
    await save.save("body_measurement", {
      metric_key: metricKey,
      measured_at_utc: utcFromLocalInput(measuredAt),
      local_timezone: localTimeZone(),
      value: Number(value),
      unit_key: unit.trim(),
      measurement_quality: "measured",
      canonical_state: editing?.canonical_state ?? "canonical",
      duplicate_of_measurement_id: editing?.duplicate_of_measurement_id ?? null,
      notes: note.trim() || null,
    }, editing ? { entityId: editing.id, baseRevision: editing.revision ?? null } : undefined);
    closeForm();
  }

  return <div className="fitness-wave4__subview">
    <FitnessLoadingOrError loading={measurements.loading} error={measurements.error} retry={measurements.reload} />

    {!measurements.loading && !measurements.error ? <>
      <section className="fitness-wave4__body-current" aria-label="Current body measurements">
        <CurrentMeasurement title="Current weight" readings={weightReadings} />
        <CurrentMeasurement title="Current body fat" readings={bodyFatReadings} />
        <CurrentMeasurement title="Current BMI" readings={bmiReadings} emptyText="Add your height to calculate BMI" changeUnit="points" />
      </section>

      <section className="fitness-wave4__body-trends" aria-labelledby="body-trends-title">
        <header><h3 id="body-trends-title">Trends</h3><p>Your weight, body fat and calculated BMI over time.</p></header>
        <div>
          <MeasurementTrend title="Weight" readings={weightReadings} />
          <MeasurementTrend title="Body fat" readings={bodyFatReadings} />
          <MeasurementTrend title="BMI" readings={bmiReadings} emptyText="Add your height once to calculate BMI from your weight readings." changeUnit="points" />
        </div>
      </section>

      <FitnessMeasurementTrends online={online} revision={revision} onDataChanged={onDataChanged} />
    </> : null}

    <div className="fitness-wave4__subview-actions"><button type="button" className="button button--primary" onClick={() => { if (formOpen && !editing) closeForm(); else { closeForm(); setFormOpen(true); } }}><Plus aria-hidden="true" size={17} /> Add measurement</button></div>
    {formOpen ? <FitnessCard title={editing ? `Edit ${measurementLabel(editing.metric_key)}` : "Add a measurement"} detail="Use the value and unit you normally track.">
      <form className="fitness-module__form" onSubmit={submitForm(record)}>
        <div className="fitness-module__fields">
          <label className="fitness-module__field" htmlFor="progress-measurement-kind">Measurement</label>
          <select id="progress-measurement-kind" disabled={Boolean(editing)} value={kind} onChange={(event) => { const next = event.target.value; setKind(next); const match = bodyMeasurementChoices.find((item) => item.key === next); if (match) setUnit(match.unit); }}><option value="body.weight_kg">Weight</option><option value="body.height_cm">Height</option><option value="body.waist_cm">Waist</option><option value="body.chest_cm">Chest</option><option value="body.hips_cm">Hips</option><option value="body.upper_arm_cm">Upper arm</option><option value="body.thigh_cm">Thigh</option><option value="body.body_fat_pct">Body fat</option><option value="__custom__">Something else…</option></select>
          {kind === "__custom__" ? <label className="fitness-module__field">Measurement name<input required value={customName} onChange={(event) => setCustomName(event.target.value)} placeholder="Neck" /></label> : null}
          <label className="fitness-module__field">Value<input required type="text" inputMode="decimal" value={value} onChange={(event) => setValue(event.target.value)} /></label>
          <label className="fitness-module__field">Unit<input required value={unit} onChange={(event) => setUnit(event.target.value)} placeholder="cm" /></label>
          <label className="fitness-module__field">Measured at<input required type="datetime-local" value={measuredAt} onChange={(event) => setMeasuredAt(event.target.value)} /></label>
          <label className="fitness-module__field is-wide">Note (optional)<textarea value={note} onChange={(event) => setNote(event.target.value)} /></label>
        </div>
        <div className="fitness-module__form-footer"><button type="submit" className="button button--primary" aria-busy={save.saving} disabled={save.saving || !value || !unit.trim() || (kind === "__custom__" && !customMeasurementKey(customName))}>{editing ? "Save changes" : "Save measurement"}</button><button type="button" className="button button--secondary" onClick={closeForm}>Cancel</button><FitnessFormStatus saving={save.saving} saved={save.saved} error={save.saveError} /></div>
      </form>
    </FitnessCard> : null}

    {!measurements.loading && !measurements.error ? <FitnessCard title="Recorded measurements" detail="Newest first. You can correct measurements you added yourself.">
      {visible.length ? <ul className="fitness-module__list">{visible.slice(0, 20).map((item) => <li key={item.id}><div><strong>{measurementLabel(item.metric_key)} · {item.value.toLocaleString(undefined, { maximumFractionDigits: 2 })} {item.unit_key}</strong><small>{formatFitnessDateTime(item.measured_at_utc)}</small></div>{item.source_record_id ? null : <button type="button" className="button button--secondary button--compact" aria-label={`Edit ${measurementLabel(item.metric_key)} ${item.value}`} onClick={() => edit(item)}><Pencil aria-hidden="true" size={14} /> Edit</button>}</li>)}</ul> : <div className="fitness-module__empty"><Scale aria-hidden="true" size={24} /><strong>No measurements yet</strong><span>Add the first reading when it is useful to you.</span></div>}
    </FitnessCard> : null}

  </div>;
}

function AreaHeading({ title, detail, onBack }: { title: string; detail: string; onBack: () => void }) {
  return <FitnessPageHeading title={title} detail={detail} actions={<button type="button" className="button button--secondary" onClick={onBack}><ArrowLeft aria-hidden="true" size={17} /> Back to Review</button>} />;
}

export function FitnessProgressView({ online, revision, onDataChanged, onSectionChange }: FitnessViewProps) {
  const [area, setAreaState] = useState<ProgressArea>(initialProgressArea);
  const weekStart = currentWeekStart();
  const trendStartDate = new Date(`${weekStart}T12:00:00`);
  trendStartDate.setDate(trendStartDate.getDate() - 21);
  const trendEndDate = new Date(`${weekStart}T12:00:00`);
  trendEndDate.setDate(trendEndDate.getDate() + 6);
  const activityWindowPath = `/fitness/activities?date_from=${localDateValue(trendStartDate)}&date_to=${localDateValue(trendEndDate)}&limit=200`;
  const goals = useFitnessCollection<FitnessGoal>("/fitness/goals", "goal", revision);
  const activities = useFitnessEndpoint<FitnessActivitySummary[] | { items?: FitnessActivitySummary[] }>(activityWindowPath, [], revision);
  const review = useFitnessEndpoint<FitnessWeeklyReview>(`/fitness/weekly-review?week_start=${weekStart}`, emptyWeeklyReview(weekStart), revision);
  const performanceCharts = useFitnessProgressCharts(emptyFitnessProgressCharts, revision);
  const measurements = useFitnessCollection<FitnessBodyMeasurement>("/fitness/body/measurements", "body_measurement", revision);

  function setArea(next: ProgressArea) {
    setAreaState(next);
    const url = new URL(window.location.href);
    if (next === "summary") url.searchParams.delete("fitness-progress");
    else url.searchParams.set("fitness-progress", next);
    window.history.replaceState(window.history.state, "", url);
    const reducedMotion = window.matchMedia?.("(prefers-reduced-motion: reduce)").matches ?? false;
    window.scrollTo({ top: 0, behavior: reducedMotion ? "auto" : "smooth" });
  }

  function followOpportunity() {
    const destination = reviewData.opportunity.destination;
    if (destination === "measurements") { setArea("measurements"); return; }
    const url = new URL(window.location.href);
    if (destination === "goals") url.searchParams.set("fitness-plan-manage", "goals");
    if (destination === "plan") url.searchParams.set("fitness-plan-action", "create");
    window.history.replaceState(window.history.state, "", url);
    if (destination === "strength") onSectionChange("strength");
    else if (destination === "activities") onSectionChange("activity");
    else if (destination === "today") onSectionChange("today");
    else onSectionChange("training");
  }

  function openActivity(activityId: string) {
    const url = new URL(window.location.href);
    url.searchParams.set("view", "fitness");
    url.searchParams.set("section", "activity");
    url.searchParams.set("activity", activityId);
    window.history.pushState(window.history.state, "", url);
    onSectionChange("activity");
  }

  if (area === "measurements") return <section aria-label="Body measurements"><AreaHeading title="Body measurements" detail="Record a reading and see the useful trend." onBack={() => setArea("summary")} /><ProgressMeasurements online={online} revision={revision} onDataChanged={onDataChanged} /></section>;
  if (area === "photos") return <section aria-label="Private progress photos"><AreaHeading title="Private progress photos" detail="Compare photos you intentionally saved to your account." onBack={() => setArea("summary")} /><Suspense fallback={<SkeletonList rows={5} />}><FitnessProgressPhotos online={online} revision={revision} onDataChanged={onDataChanged} /></Suspense></section>;
  if (area === "export") return <section aria-label="Export Fitness data"><AreaHeading title="Export Fitness data" detail="Download a private copy when you need one." onBack={() => setArea("summary")} /><FitnessDataExportCard online={online} /></section>;

  const reviewData = (review.data as FitnessWeeklyReview | null)?.totals ? review.data : emptyWeeklyReview(weekStart);
  const activityRows = asFitnessArray(activities.data).sort((left, right) => right.started_at_utc.localeCompare(left.started_at_utc));
  const completedActivityRows = activityRows.filter((activity) => ["complete", "completed"].includes(activity.status ?? ""));
  const selectedGoal = reviewData.goal ? goals.data.find((goal) => goal.id === reviewData.goal?.goal_id) ?? null : null;
  const weeklyStats = [
    { label: "active days", value: reviewData.totals.active_days },
    ...(reviewData.totals.duration_minutes != null ? [{ label: "minutes", value: reviewData.totals.duration_minutes }] : []),
    ...(reviewData.totals.distance_km != null ? [{ label: "km", value: reviewData.totals.distance_km }] : []),
    ...(reviewData.totals.strength_volume_kg != null ? [{ label: "kg lifted", value: reviewData.totals.strength_volume_kg }] : []),
  ];

  return <section aria-label="Review" className="fitness-wave4__progress">
    <FitnessPageHeading title="Review" detail="This week, your chosen goal and the next useful step." />

    <FitnessLoadingOrError loading={review.loading} error={review.error} retry={review.reload} />
    {!review.loading && !review.error ? <FitnessCard className="fitness-wave4__weekly-review">
      <div className="fitness-wave4__weekly-heading"><div><span>This week</span><h3>{formatFitnessDate(reviewData.week_start)} – {formatFitnessDate(reviewData.week_end)}</h3></div><span>{reviewData.totals.completed_sessions} {reviewData.totals.completed_sessions === 1 ? "session" : "sessions"}</span></div>
      <div className="fitness-wave4__weekly-stats" aria-label="Weekly totals">{weeklyStats.map((stat) => <div key={stat.label}><strong>{stat.value.toLocaleString(undefined, { maximumFractionDigits: 1 })}</strong><span>{stat.label}</span></div>)}</div>
      <div className="fitness-wave4__weekly-highlight"><Sparkles aria-hidden="true" size={18} /><div><strong>{reviewData.highlight.title}</strong><p>{reviewData.highlight.detail}</p></div></div>
      <div className="fitness-wave4__next-step"><div><span>Next useful step</span><strong>{reviewData.opportunity.title}</strong><p>{reviewData.opportunity.detail}</p></div><div className="fitness-module__button-row"><button type="button" className="button button--primary" onClick={followOpportunity}>{reviewData.opportunity.action_label}</button><button type="button" className="button button--secondary" onClick={() => onSectionChange("coach")}>Ask Coach about this week</button></div></div>
    </FitnessCard> : null}

    {!review.loading && !review.error ? <SelectedGoalTrend review={reviewData} goal={selectedGoal} activities={completedActivityRows} loading={goals.loading || activities.loading} error={goals.error ?? activities.error} retry={() => { goals.reload(); activities.reload(); }} /> : null}

    <FitnessOverviewWeightChart
      measurements={measurements.data}
      loading={measurements.loading}
      error={measurements.error}
      retry={measurements.reload}
      onOpen={() => setArea("measurements")}
      online={online}
      revision={revision}
      onDataChanged={onDataChanged}
    />

    <FitnessPerformanceCharts
      data={performanceCharts.data}
      loading={performanceCharts.loading}
      error={performanceCharts.error}
      retry={performanceCharts.reload}
      onOpenRuns={() => onSectionChange("activity")}
      onOpenStrength={() => onSectionChange("strength")}
    />

    <ActivityHistory rows={completedActivityRows} loading={activities.loading} error={activities.error} retry={activities.reload} onOpenActivity={openActivity} onOpenHistory={() => onSectionChange("activity")} />

    <section className="fitness-wave4__drilldowns" aria-labelledby="progress-drilldown-title"><header><h3 id="progress-drilldown-title">Look closer</h3><p>Open only the detail you need.</p></header><div>
      <button type="button" onClick={() => onSectionChange("strength")}><Dumbbell aria-hidden="true" size={20} /><span><strong>Strength</strong><small>Sessions and exercise progress</small></span></button>
      <button type="button" onClick={() => setArea("measurements")}><Scale aria-hidden="true" size={20} /><span><strong>Body</strong><small>Measurements and trends</small></span></button>
      <button type="button" onClick={() => onSectionChange("recovery")}><HeartPulse aria-hidden="true" size={20} /><span><strong>Recovery</strong><small>Sleep and readiness</small></span></button>
      <button type="button" onClick={() => setArea("photos")}><Images aria-hidden="true" size={20} /><span><strong>Photos</strong><small>Private comparisons</small></span></button>
      <button type="button" onClick={() => onSectionChange("explore")}><TrendingUp aria-hidden="true" size={20} /><span><strong>Insights</strong><small>Ask a focused question</small></span></button>
      <button type="button" onClick={() => setArea("export")}><Download aria-hidden="true" size={20} /><span><strong>Export</strong><small>Download your records</small></span></button>
    </div></section>
  </section>;
}
