import {
  AlertTriangle,
  Award,
  CheckCircle2,
  Copy,
  Dumbbell,
  Footprints,
  Gauge,
  Link2,
  MessageCircle,
  Pencil,
  RefreshCw,
  ShieldAlert,
  SlidersHorizontal,
} from "lucide-react";
import { lazy, Suspense, useEffect, useMemo, useState } from "react";

import { api } from "../../api";
import { Modal, SkeletonList, cn } from "../../components/ui";
import { availableFitnessActivityPanels } from "../../fitness/activityPanels";
import { flushFitnessSync, saveFitnessRecords, type SaveFitnessRecordInput } from "../../fitness/offlineStore";
import type {
  FitnessActivityDetail,
  FitnessActivityGoalLink,
  FitnessActivityInterval,
  FitnessActivityRecord,
  FitnessAnalysisFinding,
  FitnessBodyIssue,
  FitnessBodyLocation,
  FitnessComparableRun,
  FitnessDataQualityFinding,
  FitnessGearItem,
  FitnessGoal,
  FitnessPlannedSession,
  FitnessStrengthSession,
} from "../../fitness/contract";
import { strengthWorkoutExportText } from "../../fitness/strengthWorkout";
import {
  comparisonSelectionExplanation,
  orderedComparableRuns,
  visibleRunningFindings,
} from "../../fitness/runningAnalysis";
import {
  FitnessCard,
  FitnessStat,
  errorMessage,
  formatFitnessDateTime,
  localTimeZone,
} from "./shared";

const ActivityVisualiser = lazy(() => import("./ActivityVisualiser").then((module) => ({ default: module.ActivityVisualiser })));

const nonChartStreamMetrics = new Set([
  "elapsed_ms",
  "timer_ms",
  "distance_m",
  "latitude_deg",
  "longitude_deg",
]);

type ActivityAnalysisResponse = {
  findings?: FitnessAnalysisFinding[];
  records?: FitnessActivityRecord[];
  achievements?: FitnessActivityRecord[];
  data_quality?: FitnessDataQualityFinding[];
  training_load?: {
    as_of: string;
    algorithm_version: string;
    windows: Record<string, {
      days: number;
      distance_m: number;
      duration_s: number;
      session_count: number;
      hard_session_count: number;
      session_rpe_load?: number | null;
      long_run_share?: number | null;
    }>;
    previous_7d?: { distance_m?: number | null };
    volume_change_pct?: number | null;
    sudden_volume_change?: boolean;
    consecutive_hard_days?: Array<[string, string]>;
    intensity_distribution_7d?: Record<string, number>;
    training_monotony_7d?: number | null;
    missing_rpe_sessions?: number;
    sample_size?: number;
    explanation?: string;
  } | null;
};

type ComparisonOverlayResponse = {
  distance_m: number[];
  metrics: string[];
  alignment?: string;
  activities: Array<{
    activity_id: string;
    title: string;
    series: Record<string, Array<number | null>>;
  }>;
};

function formatDuration(seconds?: number | null): string {
  if (seconds == null) return "—";
  const totalSeconds = Math.max(0, Math.round(seconds));
  const hours = Math.floor(totalSeconds / 3600);
  const minutes = Math.floor((totalSeconds % 3600) / 60);
  const remaining = totalSeconds % 60;
  return hours ? `${hours}:${String(minutes).padStart(2, "0")}:${String(remaining).padStart(2, "0")}` : `${minutes}:${String(remaining).padStart(2, "0")}`;
}

function metricValue(value?: number | null, unit?: string | null): string {
  if (value == null) return "—";
  if (unit === "m" && value >= 1000) return `${(value / 1000).toFixed(2)} km`;
  if (unit === "s_per_km" || unit === "s/km") {
    const totalSeconds = Math.max(0, Math.round(value));
    return `${Math.floor(totalSeconds / 60)}:${String(totalSeconds % 60).padStart(2, "0")}/km`;
  }
  return `${Number.isInteger(value) ? value : value.toFixed(1)}${unit ? ` ${unit}` : ""}`;
}

function summaryMetricNumber(detail: FitnessActivityDetail, ...keys: string[]): number | null {
  return detail.summary_metrics.find((metric) => keys.includes(metric.metric_key))?.value_number ?? null;
}

function qualityFindingIdentity(finding: FitnessDataQualityFinding): string {
  return [
    finding.key,
    finding.severity,
    finding.message,
    finding.start_offset_ms ?? "",
    finding.end_offset_ms ?? "",
    [...(finding.limits_analysis_keys ?? [])].sort().join(","),
  ].join(":");
}

function uniqueQualityFindings(...groups: Array<FitnessDataQualityFinding[] | undefined>): FitnessDataQualityFinding[] {
  const findings = new Map<string, FitnessDataQualityFinding>();
  groups.forEach((group) => group?.forEach((finding) => findings.set(qualityFindingIdentity(finding), finding)));
  return Array.from(findings.values());
}

function uniqueAnalysisFindings(findings: FitnessAnalysisFinding[]): FitnessAnalysisFinding[] {
  const unique = new Map<string, FitnessAnalysisFinding>();
  const statusRank = (status?: string) => status === "valid" ? 3 : status === "limited" ? 2 : 1;
  findings.forEach((finding) => {
    const existing = unique.get(finding.key);
    if (!existing || statusRank(finding.status) > statusRank(existing.status)) unique.set(finding.key, finding);
  });
  return Array.from(unique.values());
}

const activitySourceLabels: Record<string, string> = {
  healthkit: "Apple Health",
  manual_fit: "Uploaded FIT file",
  garmin_api: "Garmin",
  file_import: "Imported file",
  manual: "Manual entry",
};

function readableRegistryKey(value: string): string {
  const words = value.replaceAll("_", " ").replaceAll(".", " ").replace(/\s+/g, " ").trim();
  return words ? words[0].toLocaleUpperCase() + words.slice(1) : "Recorded data";
}

function activitySourceLabel(value: string): string {
  return activitySourceLabels[value] ?? readableRegistryKey(value);
}

export function activityPrimaryStats(detail: FitnessActivityDetail): Array<{ label: string; value: string; detail?: string }> {
  if (detail.activity.sport_key === "strength") {
    const strength = detail.activity.strength_summary;
    return [
      { label: "Workout time", value: formatDuration(detail.activity.duration_s) },
      { label: "Exercises", value: strength ? String(strength.exercise_count) : "—" },
      { label: "Sets", value: strength ? String(strength.set_count) : "—" },
      { label: "Working sets", value: strength ? String(strength.working_set_count) : "—" },
      { label: "Sets to failure", value: strength ? String(strength.failure_set_count) : "—" },
      { label: "External volume", value: strength && strength.volume_kg > 0 ? `${Math.round(strength.volume_kg).toLocaleString()} kg` : "—" },
    ];
  }
  const registeredPace = summaryMetricNumber(detail, "running.average_pace_s_per_km");
  const averageSpeed = summaryMetricNumber(detail, "speed.average_mps");
  const averageHeartRate = summaryMetricNumber(detail, "heart_rate.average_bpm");
  const elevationGain = summaryMetricNumber(detail, "elevation.gain_m");
  const movingPace = detail.activity.distance_m != null
    && detail.activity.distance_m > 0
    && detail.activity.moving_duration_s != null
    && detail.activity.moving_duration_s > 0
    ? detail.activity.moving_duration_s * 1_000 / detail.activity.distance_m
    : null;
  const primaryPace = registeredPace != null && registeredPace > 0
    ? registeredPace
    : averageSpeed != null && averageSpeed > 0
      ? 1_000 / averageSpeed
      : movingPace;
  return [
    { label: "Distance", value: detail.activity.distance_m != null ? `${(detail.activity.distance_m / 1_000).toFixed(2)} km` : "—" },
    {
      label: detail.activity.moving_duration_s != null ? "Moving time" : "Timer time",
      value: formatDuration(detail.activity.moving_duration_s ?? detail.activity.timer_duration_s ?? detail.activity.duration_s),
      detail: detail.activity.elapsed_duration_s != null ? `${formatDuration(detail.activity.elapsed_duration_s)} elapsed` : undefined,
    },
    detail.activity.sport_key.includes("run")
      ? { label: "Average pace", value: metricValue(primaryPace, "s_per_km") }
      : { label: "Average speed", value: averageSpeed != null ? `${(averageSpeed * 3.6).toFixed(1)} km/h` : "—" },
    { label: "Average heart rate", value: averageHeartRate != null ? `${Math.round(averageHeartRate)} bpm` : "—" },
    { label: "Elevation gain", value: elevationGain != null ? `${Math.round(elevationGain)} m` : "—" },
    { label: "Energy", value: detail.activity.energy_kcal != null ? `${detail.activity.energy_estimation_method ? "≈ " : ""}${Math.round(detail.activity.energy_kcal)} kcal` : "—" },
  ];
}

export function hasActivityChartMetrics(detail: FitnessActivityDetail): boolean {
  return detail.available_stream_metrics.some((metric) => !nonChartStreamMetrics.has(metric));
}

function ActivitySectionNav({ detail, hasAnalysis }: { detail: FitnessActivityDetail; hasAnalysis: boolean }) {
  const hasRoute = (
    detail.available_stream_metrics.includes("latitude_deg")
    && detail.available_stream_metrics.includes("longitude_deg")
  ) || (detail.activity.route_preview?.length ?? 0) > 1;
  const hasRecordedLaps = detail.intervals.some((interval) => interval.interval_kind === "source_lap");
  const sections = [
    { id: "activity-route", label: "Route", visible: hasRoute },
    { id: "activity-overview", label: "Overview", visible: true },
    { id: "activity-strength", label: "Exercises", visible: detail.activity.sport_key === "strength" },
    { id: "activity-splits", label: hasRecordedLaps ? "Laps" : "Splits", visible: detail.intervals.length > 0 },
    { id: "activity-charts", label: "Charts", visible: hasActivityChartMetrics(detail) },
    { id: "activity-analysis", label: "Analysis", visible: hasAnalysis },
    { id: "activity-context", label: "Context", visible: true },
    { id: "activity-manage", label: "Manage", visible: true },
  ].filter((section) => section.visible);

  function moveTo(id: string) {
    const reducedMotion = window.matchMedia?.("(prefers-reduced-motion: reduce)").matches;
    const section = document.getElementById(id);
    if (section && typeof section.scrollIntoView === "function") {
      section.scrollIntoView({ behavior: reducedMotion ? "auto" : "smooth", block: "start" });
    }
  }

  return <nav className="fitness-module__activity-section-nav" aria-label="Activity detail sections">
    {sections.map((section) => <button type="button" onClick={() => moveTo(section.id)} key={section.id}>{section.label}</button>)}
  </nav>;
}

function StrengthSessionSummary({ session }: { session: FitnessStrengthSession }) {
  const [copied, setCopied] = useState(false);
  async function copyWorkout() {
    const text = strengthWorkoutExportText(session);
    if (navigator.clipboard?.writeText) await navigator.clipboard.writeText(text);
    else {
      const textarea = document.createElement("textarea");
      textarea.value = text;
      textarea.style.position = "fixed";
      textarea.style.opacity = "0";
      document.body.appendChild(textarea);
      textarea.select();
      document.execCommand("copy");
      textarea.remove();
    }
    setCopied(true);
  }
  return <section id="activity-strength" className="fitness-module__activity-anchor"><FitnessCard title="Strength workout" detail={`${session.exercises?.length ?? 0} exercises · the complete recorded session`}>
    <div className="fitness-module__form-footer"><button className="button button--primary" type="button" onClick={() => void copyWorkout()}><Copy aria-hidden="true" size={16} /> Copy workout for an LLM</button>{copied ? <span role="status">Copied</span> : null}</div>
    <ol className="fitness-module__strength-summary-list">{(session.exercises ?? []).map((item, exerciseIndex) => <li key={item.id}><div><Dumbbell aria-hidden="true" size={18} /><strong>{item.exercise_name ?? item.exercise?.name ?? `Exercise ${exerciseIndex + 1}`}</strong><small>{item.source_setup_label ?? item.setup?.name}</small></div><ol>{(item.set_groups ?? []).filter((group) => group.status !== "planned").map((group, setIndex) => <li key={group.id}><strong>Set {setIndex + 1}</strong><span>{(group.components ?? []).filter((component) => component.component_status !== "skipped").map((component) => [component.load_value != null ? `${component.load_value} ${component.load_unit ?? "kg"}` : null, component.reps != null ? `${component.reps} reps` : component.reps_left != null || component.reps_right != null ? `${component.reps_left ?? "?"}/${component.reps_right ?? "?"} reps` : component.duration_s != null ? `${component.duration_s}s` : null].filter(Boolean).join(" × ")).join("; ") || group.status}</span>{group.failure_state && group.failure_state !== "none" ? <em>Failure</em> : null}</li>)}</ol></li>)}</ol>
  </FitnessCard></section>;
}

function ActivityOverview({ detail, onAskCoach }: { detail: FitnessActivityDetail; onAskCoach?: (activityId: string, title: string) => void }) {
  const isRun = detail.activity.sport_key.includes("run");
  const summaryStats = activityPrimaryStats(detail).filter((stat) => !isRun || stat.value !== "—");
  return <section className="fitness-module__activity-overview" id="activity-overview">
    <div className="fitness-module__activity-hero">
      <div>
        <span className="fitness-module__eyebrow">{isRun ? "Run summary" : "Activity summary"}</span>
        <div className="fitness-module__activity-badges"><span className="fitness-module__pill">{detail.activity.sport_key.replaceAll("_", " ")}</span><span className="fitness-module__pill is-neutral">{detail.activity.workout_classification?.replaceAll("_", " ") ?? "Unclassified"}</span></div>
        <p>{formatFitnessDateTime(detail.activity.started_at_utc)}{detail.activity.phase_name ? ` · ${detail.activity.phase_name}` : ""}</p>
      </div>
      {onAskCoach ? <button type="button" className="button button--primary" onClick={() => onAskCoach(detail.activity.id, detail.activity.title)}><MessageCircle aria-hidden="true" size={17} /> Ask Coach about this activity</button> : null}
    </div>
    {summaryStats.length ? <dl className={cn("fitness-module__activity-primary-stats", isRun && "is-run")}>{summaryStats.map((stat) => <div key={stat.label}><dt>{stat.label}</dt><dd>{stat.value}</dd>{stat.detail ? <small>{stat.detail}</small> : null}</div>)}</dl> : null}
  </section>;
}

function ActivitySummaryMetrics({ detail }: { detail: FitnessActivityDetail }) {
  if (!detail.summary_metrics.length) return <div className="fitness-module__empty"><strong>No additional stats</strong><span>The activity headline has everything available here.</span></div>;
  return <dl className="fitness-module__activity-metric-grid">{detail.summary_metrics.map((metric) => <div key={metric.metric_key}>
    <dt>{metric.label ?? metric.metric_key.replaceAll("_", " ").replaceAll(".", " ")}</dt>
    <dd>{metric.value_text ?? metricValue(metric.value_number, metric.unit_key)}</dd>
  </div>)}</dl>;
}

function AutomaticRunComparison({ comparables, loaded }: { comparables: FitnessComparableRun[]; loaded: boolean }) {
  if (!loaded) return <FitnessCard title="Previous similar run" detail="Finding the nearest run at this distance…"><SkeletonList rows={1} /></FitnessCard>;
  const previous = comparables.find((item) => item.is_previous_similar_distance && item.automatic_comparison);
  const comparison = previous?.automatic_comparison;
  if (!previous || !comparison) return <FitnessCard title="No similar-distance run yet" detail="The next run near this distance will compare with this one automatically."><div className="fitness-module__empty"><strong>A clean baseline</strong><span>No comparison is invented when there is no earlier run within 5% of this distance.</span></div></FitnessCard>;
  const improvement = comparison.pace_improvement_s_per_km;
  const change = Math.abs(improvement) < 0.5
    ? "About the same pace"
    : `${formatDuration(Math.abs(improvement))}/km ${improvement > 0 ? "faster" : "slower"}`;
  return <FitnessCard title={`${comparison.distance_label} progress`} detail={`Compared automatically with ${previous.activity.title} · ${formatFitnessDateTime(previous.activity.started_at_utc)}`}>
    <div className="fitness-module__activity-comparison-result"><strong>{change}</strong><div className="fitness-module__stats"><FitnessStat label="This run" value={`${formatDuration(comparison.current_pace_s_per_km)}/km`} detail={formatDuration(comparison.current_duration_s)} /><FitnessStat label="Previous" value={`${formatDuration(comparison.previous_pace_s_per_km)}/km`} detail={formatDuration(comparison.previous_duration_s)} /></div>{Math.abs(comparison.distance_delta_m) > 10 ? <small>Distances differed by {(Math.abs(comparison.distance_delta_m) / 1_000).toFixed(2)} km; pace is the fairer comparison.</small> : null}</div>
  </FitnessCard>;
}

type SplitGroupKey = "kilometre" | "source_lap" | "mile" | "interval";

function intervalNumber(interval: FitnessActivityInterval, ...keys: string[]): number | null {
  const values = interval.metrics ?? interval.metrics_json ?? {};
  for (const key of keys) {
    const value = values[key];
    if (typeof value === "number" && Number.isFinite(value)) return value;
  }
  return null;
}

function intervalDistance(interval: FitnessActivityInterval): number | null {
  if (interval.start_distance_m != null && interval.end_distance_m != null) return Math.max(0, interval.end_distance_m - interval.start_distance_m);
  return interval.end_distance_m ?? intervalNumber(interval, "distance_m");
}

function intervalElapsedDuration(interval: FitnessActivityInterval): number {
  return intervalNumber(interval, "elapsed_duration_s", "duration_s", "elapsed_time_s")
    ?? Math.max(0, interval.end_offset_ms - interval.start_offset_ms) / 1_000;
}

function intervalTimerDuration(interval: FitnessActivityInterval): number {
  return intervalNumber(interval, "timer_duration_s", "moving_duration_s", "moving_time_s")
    ?? intervalElapsedDuration(interval);
}

function intervalPace(interval: FitnessActivityInterval): number | null {
  const explicit = intervalNumber(interval, "pace_s_per_km", "pace.average_s_per_km");
  if (explicit != null) return explicit;
  const speed = intervalNumber(interval, "speed.average_mps", "average_speed_mps");
  if (speed != null && speed > 0) return 1_000 / speed;
  const distance = intervalDistance(interval);
  const duration = intervalTimerDuration(interval);
  return distance != null && distance > 0 && duration > 0 ? duration * 1_000 / distance : null;
}

function intervalElevation(interval: FitnessActivityInterval): number | null {
  return intervalNumber(
    interval,
    "elevation.change_m",
    "elevation.delta_m",
  );
}

function splitPositionHeading(group: SplitGroupKey): string {
  if (group === "kilometre") return "Km";
  if (group === "mile") return "Mi";
  if (group === "source_lap") return "Lap";
  return "Step";
}

function ActivitySplits({ intervals, preferSourceLaps = false }: { intervals: FitnessActivityInterval[]; preferSourceLaps?: boolean }) {
  const standardDefinitions: Array<{ key: SplitGroupKey; label: string; matches: (interval: FitnessActivityInterval) => boolean }> = [
    { key: "kilometre", label: "Kilometres", matches: (interval) => interval.interval_kind === "kilometre_split" },
    { key: "source_lap", label: "Laps", matches: (interval) => interval.interval_kind === "source_lap" },
    { key: "mile", label: "Miles", matches: (interval) => interval.interval_kind === "mile_split" },
    { key: "interval", label: "Workout intervals", matches: (interval) => ["work_interval", "recovery_interval", "warmup", "cooldown", "plan_step", "planned_step"].includes(interval.interval_kind) },
  ];
  const definitions = preferSourceLaps
    ? [standardDefinitions[1], standardDefinitions[0], standardDefinitions[2], standardDefinitions[3]]
    : standardDefinitions;
  const groups = definitions.map((definition) => ({ ...definition, rows: intervals.filter(definition.matches) })).filter((group) => group.rows.length > 0);
  const [selectedGroup, setSelectedGroup] = useState<SplitGroupKey>(groups[0]?.key ?? (preferSourceLaps ? "source_lap" : "kilometre"));
  const active = groups.find((group) => group.key === selectedGroup) ?? groups[0];
  if (!active) return null;
  const paces = active.rows.map(intervalPace).filter((pace): pace is number => pace != null);
  const fastest = paces.length ? Math.min(...paces) : null;
  const slowest = paces.length ? Math.max(...paces) : null;
  const hasDistance = active.rows.some((interval) => intervalDistance(interval) != null);
  const hasPace = active.rows.some((interval) => intervalPace(interval) != null);
  const hasHeartRate = active.rows.some((interval) => intervalNumber(interval, "heart_rate.average_bpm", "average_heart_rate_bpm", "heart_rate_bpm") != null);
  const hasPower = active.rows.some((interval) => intervalNumber(interval, "power.average_w", "average_power_w", "power_w") != null);

  const rows = active.rows.map((interval, index) => {
    const distance = intervalDistance(interval);
    const pace = intervalPace(interval);
    const elevation = intervalElevation(interval);
    const heartRate = intervalNumber(interval, "heart_rate.average_bpm", "average_heart_rate_bpm", "heart_rate_bpm");
    const maximumHeartRate = intervalNumber(interval, "heart_rate.maximum_bpm", "maximum_heart_rate_bpm");
    const power = intervalNumber(interval, "power.average_w", "average_power_w", "power_w");
    const elapsedDuration = intervalElapsedDuration(interval);
    const timerDuration = intervalTimerDuration(interval);
    const fill = pace == null || fastest == null || slowest == null
      ? 0
      : slowest === fastest ? 76 : 36 + ((slowest - pace) / (slowest - fastest)) * 60;
    return {
      distance,
      elevation,
      elapsedDuration,
      fill,
      heartRate,
      index,
      interval,
      maximumHeartRate,
      pace,
      power,
      timerDuration,
    };
  });

  return <div className="fitness-module__split-analysis">
    <div className="fitness-module__split-tabs" role="group" aria-label="Split type">
      {groups.map((group) => <button type="button" className={active.key === group.key ? "is-active" : undefined} aria-pressed={active.key === group.key} onClick={() => setSelectedGroup(group.key)} key={group.key}>{group.label}<span>{group.rows.length}</span></button>)}
    </div>
    {preferSourceLaps ? <div className="fitness-module__run-split-table-wrap"><table className="fitness-module__run-split-table" aria-label={`${active.label} split comparison`}>
      <caption className="sr-only">Longer pace bars mark faster sections.</caption>
      <colgroup><col className="is-position" /><col className="is-pace" /><col className="is-elevation" /><col className="is-heart-rate" /><col className="is-power" /></colgroup>
      <thead><tr>
        <th scope="col">{splitPositionHeading(active.key)}</th>
        <th scope="col">Pace</th>
        <th scope="col" aria-label="Elevation change in metres">Elev</th>
        <th scope="col" aria-label="Average heart rate">HR</th>
        <th scope="col" aria-label="Average power in watts">W</th>
      </tr></thead>
      <tbody>{rows.map(({ distance, elevation, elapsedDuration, fill, heartRate, index, interval, maximumHeartRate, pace, power, timerDuration }) => <tr key={interval.id}>
        <td><strong aria-hidden="true">{index + 1}</strong><span className="sr-only">{interval.label ?? `Section ${index + 1}`}</span>{distance != null ? <span className="sr-only">{distance >= 1_000 ? `${(distance / 1_000).toFixed(2)} kilometres` : `${Math.round(distance)} metres`}</span> : null}<span className="sr-only">{formatDuration(elapsedDuration)} elapsed</span>{Math.abs(elapsedDuration - timerDuration) >= 1 ? <span className="sr-only">{formatDuration(timerDuration)} moving</span> : null}{maximumHeartRate != null ? <span className="sr-only">{Math.round(maximumHeartRate)} max</span> : null}</td>
        <td><div className="fitness-module__run-split-pace"><strong>{pace != null ? formatDuration(pace) : "—"}</strong><span className="fitness-module__run-split-bar" aria-hidden="true"><span style={{ width: `${fill}%` }} /></span></div></td>
        <td><span aria-hidden="true">{elevation != null ? Math.round(elevation) : "—"}</span><span className="sr-only">{elevation != null ? `${Math.round(elevation)} metres elevation change` : "No elevation-change reading"}</span></td>
        <td><span aria-hidden="true">{heartRate != null ? Math.round(heartRate) : "—"}</span><span className="sr-only">{heartRate != null ? `${Math.round(heartRate)} beats per minute` : "No heart-rate reading"}</span></td>
        <td><span aria-hidden="true">{power != null ? Math.round(power) : "—"}</span><span className="sr-only">{power != null ? `${Math.round(power)} watts` : "No power reading"}</span></td>
      </tr>)}</tbody>
    </table></div> : <div className="fitness-module__table-wrap fitness-module__split-table-wrap"><table className="fitness-module__table fitness-module__split-table">
      <thead><tr><th>Section</th><th>Time</th>{hasDistance ? <th>Distance</th> : null}{hasPace ? <th>Pace</th> : null}{hasHeartRate ? <th>Heart rate</th> : null}{hasPower ? <th>Power</th> : null}</tr></thead>
      <tbody>{rows.map(({ distance, elapsedDuration, fill, heartRate, interval, maximumHeartRate, pace, power, timerDuration }) => <tr key={interval.id}>
          <td data-label="Section"><strong>{interval.label ?? `#${interval.sequence + 1}`}</strong></td>
          <td data-label="Time"><strong>{formatDuration(elapsedDuration)}</strong>{Math.abs(elapsedDuration - timerDuration) >= 1 ? <small>{formatDuration(timerDuration)} moving</small> : null}</td>
          {hasDistance ? <td data-label="Distance">{distance != null ? distance >= 1_000 ? `${(distance / 1_000).toFixed(2)} km` : `${Math.round(distance)} m` : "—"}</td> : null}
          {hasPace ? <td data-label="Pace" className="fitness-module__split-pace"><span style={{ width: `${fill}%` }} aria-hidden="true" /><strong>{metricValue(pace, "s_per_km")}</strong></td> : null}
          {hasHeartRate ? <td data-label="Heart rate">{heartRate != null ? <><strong>{Math.round(heartRate)} bpm</strong>{maximumHeartRate != null ? <small>{Math.round(maximumHeartRate)} max</small> : null}</> : "—"}</td> : null}
          {hasPower ? <td data-label="Power">{power != null ? `${Math.round(power)} W` : "—"}</td> : null}
        </tr>)}</tbody>
    </table></div>}
  </div>;
}

function ActivitySplitsSection({ detail }: { detail: FitnessActivityDetail }) {
  const isRun = detail.activity.sport_key.includes("run");
  if (!detail.intervals.length) return isRun ? <section id="activity-splits" className="fitness-module__activity-anchor fitness-module__activity-missing">
    <strong>No laps recorded</strong>
    <span>The recording did not include lap data.</span>
  </section> : null;
  const hasRecordedLaps = detail.intervals.some((interval) => interval.interval_kind === "source_lap");
  const title = isRun && hasRecordedLaps ? "Laps" : isRun ? "Splits" : "Splits and laps";
  const description = isRun && hasRecordedLaps
    ? "Pace, elevation, heart rate and power for each recorded lap."
    : "See how the activity changed section by section.";
  return <section id="activity-splits" className="fitness-module__activity-anchor">
    <FitnessCard title={title} detail={description} className={isRun ? "fitness-module__splits-card" : undefined}>
      <ActivitySplits intervals={detail.intervals} preferSourceLaps={isRun} key={detail.activity.id} />
    </FitnessCard>
  </section>;
}

function bodyLocationLabel(locationKey: string, locations: FitnessBodyLocation[]): string {
  return locations.find((location) => location.location_key === locationKey)?.display_name
    ?? `Custom/legacy: ${locationKey.replaceAll("_", " ")}`;
}

function ActivityRecords({ records }: { records: FitnessActivityRecord[] }) {
  if (!records.length) return null;
  return <FitnessCard title="Records and achievements" detail="Each result retains the activity position that supports it.">
    <ul className="fitness-module__list">{records.map((record) => <li key={record.id}><div><strong>{record.label}</strong><small>{record.record_key.replaceAll("_", " ")}</small></div><span className={cn("fitness-module__pill", record.is_personal_best ? "is-success" : "is-neutral")}>{record.value}</span></li>)}</ul>
  </FitnessCard>;
}

function ComparisonRouteOverlay({
  current,
  comparables,
}: {
  current: Array<[number, number]>;
  comparables: FitnessComparableRun[];
}) {
  const routes = [current, ...comparables.filter((entry) => entry.selected !== false).map((entry) => entry.activity.route_preview ?? []).filter((route) => route.length > 1)];
  if (routes.length < 2) return null;
  const points = routes.flat();
  const latitudes = points.map(([latitude]) => latitude);
  const longitudes = points.map(([, longitude]) => longitude);
  const minLatitude = Math.min(...latitudes);
  const maxLatitude = Math.max(...latitudes);
  const minLongitude = Math.min(...longitudes);
  const maxLongitude = Math.max(...longitudes);
  const latitudeSpan = Math.max(maxLatitude - minLatitude, 0.000001);
  const longitudeSpan = Math.max(maxLongitude - minLongitude, 0.000001);
  function path(route: Array<[number, number]>): string {
    return route.map(([latitude, longitude], index) => {
      const x = 10 + (longitude - minLongitude) / longitudeSpan * 580;
      const y = 250 - (latitude - minLatitude) / latitudeSpan * 240;
      return `${index ? "L" : "M"}${x.toFixed(1)},${y.toFixed(1)}`;
    }).join(" ");
  }
  return <figure className="fitness-module__comparison-map"><svg viewBox="0 0 600 260" role="img" aria-label={`Route overlay for this activity and ${routes.length - 1} selected comparable ${routes.length === 2 ? "run" : "runs"}.`}>{routes.map((route, index) => <path className={index === 0 ? "is-current" : "is-comparison"} d={path(route)} key={index} />)}</svg><figcaption>Solid: this run · dashed: selected comparable routes</figcaption></figure>;
}

function ComparisonDistanceOverlay({ activityId, comparisonIds, online }: { activityId: string; comparisonIds: string[]; online: boolean }) {
  const [opened, setOpened] = useState(false);
  const [data, setData] = useState<ComparisonOverlayResponse | null>(null);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [retry, setRetry] = useState(0);
  const comparisonKey = comparisonIds.join(",");

  useEffect(() => {
    if (!opened || !online || !comparisonIds.length) return;
    let active = true;
    setLoading(true);
    setError(null);
    const query = new URLSearchParams({ comparison_ids: comparisonKey, metrics: "pace_s_per_km,heart_rate_bpm", points: "160" });
    void api<ComparisonOverlayResponse>(`/fitness/activities/${encodeURIComponent(activityId)}/comparison-overlay?${query.toString()}`, {}, true, false)
      .then((result) => { if (active) setData(result); })
      .catch((requestError) => { if (active) setError(errorMessage(requestError)); })
      .finally(() => { if (active) setLoading(false); });
    return () => { active = false; };
  }, [activityId, comparisonIds.length, comparisonKey, online, opened, retry]);

  function chartPath(values: Array<number | null>, min: number, max: number): string {
    const span = Math.max(max - min, 0.0001);
    let drawing = false;
    return values.map((value, index) => {
      if (value == null) { drawing = false; return ""; }
      const x = data?.distance_m.length === 1 ? 10 : 10 + index / Math.max(1, (data?.distance_m.length ?? 1) - 1) * 580;
      const y = 160 - (value - min) / span * 140;
      const command = drawing ? "L" : "M";
      drawing = true;
      return `${command}${x.toFixed(1)},${y.toFixed(1)}`;
    }).join(" ");
  }

  return <details className="fitness-module__details fitness-module__distance-overlay" onToggle={(event) => setOpened(event.currentTarget.open)}><summary>Compare pace and heart rate by distance</summary>
    <div className="fitness-module__distance-overlay-body">
      {!online ? <p className="fitness-module__muted">Reconnect to compare these runs.</p> : null}
      {loading ? <p className="fitness-module__form-status"><RefreshCw className="is-spinning" aria-hidden="true" size={15} /> Aligning selected runs…</p> : null}
      {error ? <div className="fitness-module__notice fitness-module__notice--error" role="alert"><span>{error}</span><button type="button" className="button button--secondary button--compact" onClick={() => setRetry((value) => value + 1)}>Try again</button></div> : null}
      {!loading && data ? <>{data.metrics.map((metric) => {
        const values = data.activities.flatMap((activity) => activity.series[metric] ?? []).filter((value): value is number => value != null);
        if (!values.length) return <p className="fitness-module__muted" key={metric}>No {metric.replaceAll("_", " ")} stream is shared by the selected runs.</p>;
        const min = Math.min(...values); const max = Math.max(...values);
        const label = metric === "pace_s_per_km" ? "Pace by distance" : metric === "heart_rate_bpm" ? "Heart rate by distance" : metric.replaceAll("_", " ");
        return <figure className="fitness-module__comparison-series" key={metric}><figcaption><strong>{label}</strong><span>{Math.round(min)}–{Math.round(max)} {metric === "pace_s_per_km" ? "s/km" : metric === "heart_rate_bpm" ? "bpm" : ""}</span></figcaption><svg viewBox="0 0 600 170" role="img" aria-label={`${label} for this activity and ${comparisonIds.length} selected comparison runs`}>{data.activities.map((activity, index) => <path className={`is-series-${index % 6}`} d={chartPath(activity.series[metric] ?? [], min, max)} key={activity.activity_id} />)}</svg></figure>;
      })}<ul className="fitness-module__analysis-legend">{data.activities.map((activity, index) => <li className={`is-series-${index % 6}`} key={activity.activity_id}><span>●</span>{activity.title}</li>)}</ul><small>Aligned by distance to the shortest selected run.</small></> : null}
    </div>
  </details>;
}

function AnalysisPanel({ finding }: { finding: FitnessAnalysisFinding }) {
  const limited = finding.status === "limited" || finding.status === "unavailable";
  return <article className={cn("fitness-module__analysis-finding", limited && "is-limited")}>
    <header><strong>{finding.title}</strong>{limited ? <span className="fitness-module__pill is-neutral">Rough signal</span> : null}</header>
    <p>{finding.summary}</p>
    {finding.evidence?.length ? <ul>{finding.evidence.map((item, index) => <li key={`${item.label}-${index}`}><span>{item.label}</span><strong>{item.value}</strong></li>)}</ul> : null}
  </article>;
}

function ActivityContextEditor({
  detail,
  gear,
  goals,
  plans,
  bodyLocations,
  onSaved,
}: {
  detail: FitnessActivityDetail;
  gear: FitnessGearItem[];
  goals: FitnessGoal[];
  plans: FitnessPlannedSession[];
  bodyLocations: FitnessBodyLocation[];
  onSaved: () => void;
}) {
  const [notes, setNotes] = useState(detail.notes ?? "");
  const [sessionRpe, setSessionRpe] = useState(detail.session_rpe?.toString() ?? "");
  const [classification, setClassification] = useState(detail.activity.workout_classification ?? "unclassified");
  const [plannedSessionId, setPlannedSessionId] = useState(detail.planned_session?.id ?? "");
  const [gearIds, setGearIds] = useState(detail.gear?.map((item) => item.id) ?? []);
  const [goalRoles, setGoalRoles] = useState<Record<string, "user_assigned" | "inferred_reviewed">>(() => Object.fromEntries((detail.goal_links ?? []).flatMap((link) => link.role === "planned" ? [] : [[link.goal_id, link.role] as const])));
  const [issueOpen, setIssueOpen] = useState(false);
  const [issueLocation, setIssueLocation] = useState(bodyLocations.find((location) => location.active)?.location_key ?? "");
  const [issueSide, setIssueSide] = useState("unknown");
  const [issueSeverity, setIssueSeverity] = useState("3");
  const [issueChanged, setIssueChanged] = useState(false);
  const [issueChange, setIssueChange] = useState("reduced_pace");
  const [saving, setSaving] = useState(false);
  const [saveError, setSaveError] = useState<string | null>(null);

  async function save() {
    setSaving(true);
    setSaveError(null);
    try {
      const existingEditableLinks = (detail.goal_links ?? []).filter((link): link is FitnessActivityGoalLink & { role: "user_assigned" | "inferred_reviewed" } => link.role !== "planned");
      const mutations: SaveFitnessRecordInput[] = [{
        entityType: "activity_context",
        payload: {
          notes: notes.trim() || null,
          session_rpe: sessionRpe ? Number(sessionRpe) : null,
          workout_classification: classification,
          planned_session_id: plannedSessionId || null,
          gear_ids: gearIds,
        },
        options: { entityId: detail.activity.id, baseRevision: detail.activity.revision ?? null },
      }];
      for (const link of existingEditableLinks) {
        const nextRole = goalRoles[link.goal_id];
        mutations.push(nextRole ? {
          entityType: "activity_goal_link",
          payload: { activity_id: detail.activity.id, goal_id: link.goal_id, role: nextRole },
          options: { entityId: link.id, baseRevision: link.revision ?? null },
        } : {
          entityType: "activity_goal_link",
          payload: {},
          options: { entityId: link.id, baseRevision: link.revision ?? null, operation: "delete" },
        });
      }
      for (const [goalId, role] of Object.entries(goalRoles)) {
        if (existingEditableLinks.some((link) => link.goal_id === goalId)) continue;
        mutations.push({
          entityType: "activity_goal_link",
          payload: { activity_id: detail.activity.id, goal_id: goalId, role },
          options: { entityId: crypto.randomUUID() },
        });
      }
      if (issueOpen) {
        mutations.push({
          entityType: "body_issue",
          payload: {
            activity_id: detail.activity.id,
            observed_at_utc: new Date().toISOString(),
            timing: "post",
            issue_type_key: "pain",
            body_location_key: issueLocation,
            side: issueSide,
            severity_0_10: Number(issueSeverity),
            changed_session: issueChanged,
            session_change_key: issueChanged ? issueChange : "none",
            trend_key: "unknown",
            status: "active",
            notes: null,
          },
          options: { entityId: crypto.randomUUID() },
        });
      }
      await saveFitnessRecords(mutations);
      if (navigator.onLine) await flushFitnessSync();
      onSaved();
    } catch (requestError) {
      setSaveError(errorMessage(requestError));
    } finally {
      setSaving(false);
    }
  }

  return <FitnessCard title="Edit activity context" detail="Retrospective notes and effort stay labelled; this never creates pre-run readiness.">
    <form className="fitness-module__form" onSubmit={(event) => { event.preventDefault(); void save(); }}>
      <div className="fitness-module__fields">
        <label className="fitness-module__field is-wide">Retrospective note<textarea value={notes} onChange={(event) => setNotes(event.target.value)} placeholder="What happened, or why the plan changed" /></label>
        <label className="fitness-module__field">Post-session effort (RPE)<input type="number" min="1" max="10" step="0.5" inputMode="decimal" value={sessionRpe} onChange={(event) => setSessionRpe(event.target.value)} /></label>
        <label className="fitness-module__field">Run classification<select value={classification} onChange={(event) => setClassification(event.target.value)}><option value="unclassified">Unclassified</option><option value="recovery">Recovery</option><option value="easy">Easy</option><option value="steady">Steady</option><option value="long">Long</option><option value="tempo">Tempo</option><option value="threshold">Threshold</option><option value="interval">Intervals</option><option value="hill">Hills</option><option value="race">Race</option><option value="time_trial">Time trial</option><option value="progression">Progression</option><option value="mixed">Mixed</option></select></label>
        <label className="fitness-module__field is-wide">Linked planned session<select value={plannedSessionId} onChange={(event) => setPlannedSessionId(event.target.value)}><option value="">No linked plan</option>{plans.map((plan) => <option value={plan.id} key={plan.id}>{plan.title} · {formatFitnessDateTime(plan.scheduled_start_utc ?? plan.scheduled_date)}</option>)}</select></label>
        <fieldset className="fitness-module__field is-wide"><legend>Actual gear</legend>{gear.length ? gear.filter((item) => item.active !== false).map((item) => <label className="fitness-module__check" key={item.id}><input type="checkbox" checked={gearIds.includes(item.id)} onChange={(event) => setGearIds((current) => event.target.checked ? [...current, item.id] : current.filter((id) => id !== item.id))} /> {item.name}{item.default_for_sport_key === detail.activity.sport_key ? " · usual" : ""}</label>) : <span>No gear saved yet.</span>}</fieldset>
        <details className="fitness-module__details is-wide"><summary>Goals ({(detail.goal_links ?? []).filter((link) => link.role === "planned").length + Object.keys(goalRoles).length})</summary><fieldset className="fitness-module__activity-goal-links"><legend className="sr-only">Goals supported by this activity</legend>{goals.length ? goals.filter((goal) => goal.status === "active" || (detail.goal_links ?? []).some((link) => link.goal_id === goal.id)).map((goal) => { const planned = (detail.goal_links ?? []).some((link) => link.goal_id === goal.id && link.role === "planned"); const selectedRole = goalRoles[goal.id]; return <div key={goal.id}><label className="fitness-module__check"><input type="checkbox" checked={planned || Boolean(selectedRole)} disabled={planned} onChange={(event) => setGoalRoles((current) => { const next = { ...current }; if (event.target.checked) next[goal.id] = "user_assigned"; else delete next[goal.id]; return next; })} /> {goal.name}{planned ? " · inherited from plan" : ""}</label>{selectedRole && !planned ? <select aria-label={`Role for ${goal.name}`} value={selectedRole} onChange={(event) => setGoalRoles((current) => ({ ...current, [goal.id]: event.target.value as "user_assigned" | "inferred_reviewed" }))}><option value="user_assigned">I linked this</option><option value="inferred_reviewed">Reviewed suggestion</option></select> : null}</div>; }) : <span>No goals are available.</span>}</fieldset><small className="fitness-module__muted">Links inherited from the accepted plan are immutable; your own links remain editable.</small></details>
        <label className="fitness-module__check is-wide"><input type="checkbox" checked={issueOpen} onChange={(event) => setIssueOpen(event.target.checked)} /> Record a structured post-session body issue</label>
        {issueOpen ? <>
          <label className="fitness-module__field">Body location<select required value={issueLocation} disabled={!bodyLocations.some((location) => location.active)} onChange={(event) => setIssueLocation(event.target.value)}><option value="">Choose a location</option>{bodyLocations.filter((location) => location.active).map((location) => <option value={location.location_key} key={location.location_key}>{location.display_name}</option>)}</select></label>
          <label className="fitness-module__field">Side<select value={issueSide} onChange={(event) => setIssueSide(event.target.value)}><option value="unknown">Unknown</option><option value="left">Left</option><option value="right">Right</option><option value="bilateral">Both</option><option value="midline">Midline</option><option value="not_applicable">Not applicable</option></select></label>
          <label className="fitness-module__field">Severity (0–10)<input type="number" min="0" max="10" inputMode="numeric" value={issueSeverity} onChange={(event) => setIssueSeverity(event.target.value)} /></label>
          <label className="fitness-module__check"><input type="checkbox" checked={issueChanged} onChange={(event) => setIssueChanged(event.target.checked)} /> It changed the session</label>
          {issueChanged ? <label className="fitness-module__field">What changed<select value={issueChange} onChange={(event) => setIssueChange(event.target.value)}><option value="reduced_pace">Reduced pace</option><option value="reduced_load">Reduced load</option><option value="reduced_range">Reduced range</option><option value="substituted">Substituted</option><option value="stopped">Stopped</option><option value="other">Other</option></select></label> : null}
          {!bodyLocations.some((location) => location.active) ? <p className="fitness-module__muted is-wide">No active body locations are available. Reconnect before recording a new issue.</p> : null}
        </> : null}
      </div>
      {saveError ? <div className="fitness-module__notice fitness-module__notice--error" role="alert">{saveError}</div> : null}
      <div className="fitness-module__form-footer"><button type="submit" className="button button--primary" disabled={saving}>{saving ? "Saving…" : "Save context"}</button></div>
    </form>
  </FitnessCard>;
}

export function FitnessActivityDetailDialog({
  activityId,
  open,
  onOpenChange,
  onChanged,
  online,
  onAskCoach,
}: {
  activityId: string | null;
  open: boolean;
  onOpenChange: (open: boolean) => void;
  onChanged: () => void;
  online?: boolean;
  onAskCoach?: (activityId: string, title: string) => void;
}) {
  const [detail, setDetail] = useState<FitnessActivityDetail | null>(null);
  const [analysis, setAnalysis] = useState<ActivityAnalysisResponse>({});
  const [comparables, setComparables] = useState<FitnessComparableRun[]>([]);
  const [comparisonsLoaded, setComparisonsLoaded] = useState(false);
  const [gear, setGear] = useState<FitnessGearItem[]>([]);
  const [goals, setGoals] = useState<FitnessGoal[]>([]);
  const [plans, setPlans] = useState<FitnessPlannedSession[]>([]);
  const [bodyLocations, setBodyLocations] = useState<FitnessBodyLocation[]>([]);
  const [strengthSession, setStrengthSession] = useState<FitnessStrengthSession | null>(null);
  const [selectedComparisonIds, setSelectedComparisonIds] = useState<string[]>([]);
  const [editing, setEditing] = useState(false);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [reanalysing, setReanalysing] = useState(false);
  const [reanalysisStatus, setReanalysisStatus] = useState<string | null>(null);
  const [reanalysisError, setReanalysisError] = useState<string | null>(null);
  const [nonce, setNonce] = useState(0);

  useEffect(() => {
    if (!open || !activityId) return;
    let active = true;
    setLoading(true);
    setError(null);
    setDetail(null);
    setAnalysis({});
    setComparables([]);
    setComparisonsLoaded(false);
    setSelectedComparisonIds([]);
    setGear([]);
    setGoals([]);
    setPlans([]);
    setBodyLocations([]);
    setStrengthSession(null);
    void api<FitnessActivityDetail>(`/fitness/activities/${encodeURIComponent(activityId)}`, {}, true, false).then((nextDetail) => {
      if (!active) return null;
      setDetail(nextDetail);
      setLoading(false);
      return Promise.all([
        api<ActivityAnalysisResponse>(`/fitness/activities/${encodeURIComponent(activityId)}/analysis`, {}, true, false).catch(() => ({})),
        api<FitnessComparableRun[]>(`/fitness/activities/${encodeURIComponent(activityId)}/comparisons`, {}, true, false).catch(() => []),
        api<FitnessGearItem[]>("/fitness/gear", {}, true, false).catch(() => []),
        api<FitnessGoal[]>("/fitness/goals", {}, true, false).catch(() => []),
        api<FitnessPlannedSession[]>("/fitness/planned-sessions", {}, true, false).catch(() => []),
        api<FitnessBodyLocation[]>("/fitness/body-locations", {}, true, false).catch(() => []),
        nextDetail.activity.sport_key === "strength"
          ? api<FitnessStrengthSession>(`/fitness/strength/sessions/${encodeURIComponent(activityId)}`, {}, true, false).catch(() => null)
          : Promise.resolve(null),
      ] as const);
    }).then((secondary) => {
      if (!active || !secondary) return;
      const [nextAnalysis, nextComparables, nextGear, nextGoals, nextPlans, nextBodyLocations, nextStrengthSession] = secondary;
      setAnalysis(nextAnalysis);
      setComparables(nextComparables);
      setComparisonsLoaded(true);
      const ordered = orderedComparableRuns(nextComparables);
      const suggested = ordered.filter((entry) => entry.selected === true);
      setSelectedComparisonIds((suggested.length ? suggested : ordered).slice(0, 5).map((entry) => entry.activity.id));
      setGear(nextGear);
      setGoals(nextGoals);
      setPlans(nextPlans);
      setBodyLocations(nextBodyLocations);
      setStrengthSession(nextStrengthSession);
    }).catch((requestError) => {
      if (!active) return;
      setError(errorMessage(requestError));
      setLoading(false);
    });
    return () => { active = false; };
  }, [activityId, nonce, open]);

  const panels = useMemo(() => detail ? availableFitnessActivityPanels(detail) : [], [detail]);
  const quality = uniqueQualityFindings(detail?.data_quality, analysis.data_quality);
  const findings = uniqueAnalysisFindings(visibleRunningFindings(analysis.findings ?? [], quality));
  const selectedComparables = orderedComparableRuns(comparables).map((entry) => ({ ...entry, selected: selectedComparisonIds.includes(entry.activity.id) }));
  const allRecords = [...(detail?.records ?? []), ...(detail?.achievements ?? []), ...(analysis.records ?? []), ...(analysis.achievements ?? [])]
    .filter((record, index, records) => records.findIndex((entry) => entry.id === record.id) === index);
  const connected = online ?? (typeof navigator === "undefined" || navigator.onLine);
  const canReanalyse = detail?.sources.some((source) => source.source_type === "manual_fit") ?? false;
  const hasVisualiser = panels.some((panel) => panel.key === "route_map" || panel.key === "synchronised_line_chart");
  const shouldUseVisualiser = Boolean(detail?.activity.sport_key.includes("run")) || hasVisualiser;
  const hasAnalysis = panels.some((panel) => panel.key === "run_pacing_analysis") || Boolean(findings.length || analysis.training_load);

  async function reanalyse() {
    if (!activityId || !canReanalyse || !connected || reanalysing) return;
    setReanalysing(true);
    setReanalysisError(null);
    setReanalysisStatus(null);
    try {
      const result = await api<{ status: string; job_id: string; activity_id: string }>(`/fitness/activities/${encodeURIComponent(activityId)}/reanalyse`, { method: "POST" }, true, false);
      setReanalysisStatus(result.status === "regenerating" ? "Reanalysis is already running." : "Reanalysis started.");
      setNonce((value) => value + 1);
      onChanged();
    } catch (requestError) {
      setReanalysisError(errorMessage(requestError));
    } finally {
      setReanalysing(false);
    }
  }

  return <Modal open={open} onOpenChange={onOpenChange} size="activity" title={detail?.activity.title ?? "Activity"} description={detail ? `${detail.activity.sport_key.replaceAll("_", " ")} · ${formatFitnessDateTime(detail.activity.started_at_utc)}` : "Private activity detail"}>
    <div className="fitness-module fitness-module__activity-dialog">
      {loading ? <SkeletonList rows={7} /> : null}
      {error ? <div className="fitness-module__notice fitness-module__notice--error" role="alert"><span>{error}</span><button type="button" onClick={() => setNonce((value) => value + 1)}><RefreshCw aria-hidden="true" size={16} /> Retry</button></div> : null}
      {detail ? <>
        {shouldUseVisualiser ? <Suspense fallback={<div className="fitness-module__visualiser"><div className="fitness-module__visual-skeleton-map" aria-hidden="true" /><ActivitySectionNav detail={detail} hasAnalysis={hasAnalysis} /><ActivityOverview detail={detail} onAskCoach={onAskCoach} /><ActivitySplitsSection detail={detail} /><SkeletonList rows={4} /></div>}><ActivityVisualiser
          detail={detail}
          navigation={<ActivitySectionNav detail={detail} hasAnalysis={hasAnalysis} />}
          overview={<ActivityOverview detail={detail} onAskCoach={onAskCoach} />}
          splits={<ActivitySplitsSection detail={detail} />}
        /></Suspense> : <><ActivitySectionNav detail={detail} hasAnalysis={hasAnalysis} /><ActivityOverview detail={detail} onAskCoach={onAskCoach} /><ActivitySplitsSection detail={detail} /></>}

        {detail.activity.sport_key.includes("run") ? <AutomaticRunComparison comparables={comparables} loaded={comparisonsLoaded} /> : null}
        {strengthSession ? <StrengthSessionSummary session={strengthSession} /> : null}

        {quality.length ? <FitnessCard title="Things to note" detail="Useful context for reading this activity."><ul className="fitness-module__quality-list">{quality.map((finding) => <li key={qualityFindingIdentity(finding)}><ShieldAlert aria-hidden="true" size={18} /><div><strong>{finding.message}</strong></div></li>)}</ul></FitnessCard> : null}

        <section id="activity-analysis" className="fitness-module__activity-analysis fitness-module__activity-anchor">
        {panels.some((panel) => panel.key === "run_pacing_analysis") ? <FitnessCard title="Running analysis" detail="The strongest takeaways from this activity.">
          {findings.length ? <div className="fitness-module__analysis-grid">{findings.map((finding) => <AnalysisPanel finding={finding} key={finding.key} />)}</div> : <div className="fitness-module__empty"><strong>No extra insight yet</strong><span>The route, headline, splits and charts are ready to use.</span></div>}
        </FitnessCard> : null}

        {analysis.training_load ? <FitnessCard className="fitness-module__activity-load"><details className="fitness-module__details"><summary>Training load context</summary><div className="fitness-module__activity-load-body"><p>{analysis.training_load.explanation ?? "See how this run sits within the last four weeks."}</p><div className="fitness-module__stats"><FitnessStat label="Last 7 days" value={`${((analysis.training_load.windows["7d"]?.distance_m ?? 0) / 1000).toFixed(1)} km`} detail={`${analysis.training_load.windows["7d"]?.session_count ?? 0} sessions · ${analysis.training_load.windows["7d"]?.hard_session_count ?? 0} hard`} /><FitnessStat label="Last 28 days" value={`${((analysis.training_load.windows["28d"]?.distance_m ?? 0) / 1000).toFixed(1)} km`} detail={`${analysis.training_load.windows["28d"]?.session_count ?? 0} sessions`} /><FitnessStat label="Week change" value={analysis.training_load.volume_change_pct == null ? "Not comparable" : `${analysis.training_load.volume_change_pct > 0 ? "+" : ""}${analysis.training_load.volume_change_pct.toFixed(1)}%`} detail={analysis.training_load.sudden_volume_change ? "A larger change than usual" : "Compared with the previous week"} /><FitnessStat label="Effort load" value={analysis.training_load.windows["7d"]?.session_rpe_load?.toFixed(0) ?? "Not enough check-ins"} /></div></div></details></FitnessCard> : null}

        {panels.some((panel) => panel.key === "run_pacing_analysis") && comparables.length ? <FitnessCard title="Compare more runs" detail={comparisonSelectionExplanation(selectedComparables)}>
          {detail.activity.route_preview?.length ? <ComparisonRouteOverlay current={detail.activity.route_preview} comparables={selectedComparables} /> : null}
          <div className="fitness-module__comparison-list">{selectedComparables.map((entry) => <label key={entry.activity.id}><input type="checkbox" checked={entry.selected !== false} disabled={entry.selected === false && selectedComparisonIds.length >= 5} onChange={(event) => setSelectedComparisonIds((current) => event.target.checked ? [...current, entry.activity.id].slice(0, 5) : current.filter((id) => id !== entry.activity.id))} /><span><strong>{entry.activity.title}</strong><small>{formatFitnessDateTime(entry.activity.started_at_utc)} · {entry.reasons.join(" · ") || "Available context"}</small></span><b>{Math.round(entry.score * 100)}%</b></label>)}</div>
          {selectedComparisonIds.length ? <ComparisonDistanceOverlay activityId={detail.activity.id} comparisonIds={selectedComparisonIds} online={connected} /> : null}
          <p className="fitness-module__privacy-note"><SlidersHorizontal aria-hidden="true" size={16} /> Choose up to five runs to compare.</p>
        </FitnessCard> : null}

        {detail.adherence ? <FitnessCard title="Plan execution" detail="Adherence describes what happened; it is not a moral score.">
          <div className="fitness-module__stats"><FitnessStat label="Distance" value={detail.adherence.completed_distance_m != null ? `${((detail.adherence.completed_distance_m ?? 0) / 1000).toFixed(2)} / ${((detail.adherence.planned_distance_m ?? 0) / 1000).toFixed(2)} km` : "—"} /><FitnessStat label="Target time" value={detail.adherence.target_time_s ? `${Math.round((detail.adherence.time_in_target_s ?? 0) / detail.adherence.target_time_s * 100)}%` : "—"} /></div>
          {detail.adherence.steps?.length ? <ul className="fitness-module__list">{detail.adherence.steps.map((step) => <li key={step.id}><div><strong>{step.label}</strong><small>{step.actual} · planned {step.planned}</small></div><span className="fitness-module__pill is-neutral">{step.state}</span></li>)}</ul> : null}
          {detail.adherence.explanation ? <p>{detail.adherence.explanation}</p> : null}
        </FitnessCard> : null}
        </section>

        <section id="activity-context" className="fitness-module__activity-context fitness-module__activity-anchor">
        <ActivityRecords records={allRecords} />

        <div className="fitness-module__grid">
          <FitnessCard title="Readiness and effort" detail="Your check-ins around this activity.">
            {detail.checkins?.length ? <ul className="fitness-module__list">{detail.checkins.map((checkin) => <li key={checkin.id}><div><strong>{checkin.timing === "pre" && checkin.capture_quality === "contemporaneous" && checkin.captured_before_activity_start ? `Readiness ${checkin.readiness_1_5 ?? "—"}/5` : checkin.timing === "post" ? `Post-session RPE ${checkin.session_rpe_1_10 ?? "—"}/10` : "Later check-in"}</strong><small>{formatFitnessDateTime(checkin.captured_at_utc)}</small></div>{checkin.capture_quality === "contemporaneous" ? <CheckCircle2 aria-hidden="true" size={18} /> : <AlertTriangle aria-hidden="true" size={18} />}</li>)}</ul> : <div className="fitness-module__empty"><strong>No check-in for this activity</strong><span>Add one next time if it would help you compare sessions.</span></div>}
          </FitnessCard>
          <FitnessCard title="Body issues" detail="Structured observations are context, not a diagnosis.">
            {detail.body_issues?.length ? <ul className="fitness-module__list">{detail.body_issues.map((issue: FitnessBodyIssue) => <li key={issue.id}><div><strong>{bodyLocationLabel(issue.body_location_key, bodyLocations)} · {issue.severity_0_10}/10</strong><small>{issue.side?.replaceAll("_", " ")} · {issue.timing.replaceAll("_", " ")}{issue.changed_session ? ` · ${issue.session_change_key.replaceAll("_", " ")}` : ""}</small></div><Gauge aria-hidden="true" size={18} /></li>)}</ul> : <div className="fitness-module__empty"><strong>No issue recorded</strong><span>Missing issue context remains missing.</span></div>}
          </FitnessCard>
        </div>
        </section>

        <section id="activity-manage" className="fitness-module__activity-anchor fitness-module__activity-manage">
          <details className="fitness-module__details">
            <summary>Manage activity</summary>
            <div className="fitness-module__activity-manage-body">
              <div className="fitness-module__button-row">{canReanalyse ? <button type="button" className="button button--secondary" disabled={!connected || reanalysing} aria-busy={reanalysing} onClick={() => void reanalyse()}><RefreshCw className={reanalysing ? "is-spinning" : undefined} aria-hidden="true" size={16} /> {reanalysing ? "Queuing…" : "Reanalyse FIT"}</button> : null}<button type="button" className="button button--secondary" onClick={() => setEditing((value) => !value)}><Pencil aria-hidden="true" size={16} /> {editing ? "Close editor" : "Edit context"}</button></div>
              {reanalysisStatus ? <div className="fitness-module__notice" role="status">{reanalysisStatus}</div> : null}
              {reanalysisError ? <div className="fitness-module__notice fitness-module__notice--error" role="alert">{reanalysisError}</div> : null}
              {detail.activity.sport_key.includes("run") && !detail.gear?.length ? <div className="fitness-module__notice" role="status"><span>No running shoe is linked.</span><button type="button" onClick={() => setEditing(true)}>Choose shoe</button></div> : null}
              {editing ? <ActivityContextEditor detail={detail} gear={gear} goals={goals} plans={plans} bodyLocations={bodyLocations} onSaved={() => { setEditing(false); if (connected) setNonce((value) => value + 1); onChanged(); }} /> : null}
              <div className="fitness-module__grid">
                <FitnessCard title="All activity stats" detail="More measurements from this activity.">
                  <ActivitySummaryMetrics detail={detail} />
                </FitnessCard>
                <FitnessCard title="Import details" detail="Device, gear and planned-session links.">
                  <ul className="fitness-module__list">
                    {detail.sources.map((source) => <li key={source.id}><div><strong>{source.device_name ?? source.provider ?? activitySourceLabel(source.source_type)}</strong><small>{activitySourceLabel(source.source_type)} · {source.status ? readableRegistryKey(source.status) : "Attached"}</small></div>{source.is_primary ? <span className="fitness-module__pill is-neutral">Primary</span> : null}</li>)}
                    {detail.gear?.map((item) => <li key={item.id}><div><strong>{item.name}</strong><small>{item.gear_type_key.replaceAll("_", " ")}</small></div><Footprints aria-hidden="true" size={18} /></li>)}
                    {detail.planned_session ? <li><div><strong>{detail.planned_session.title}</strong><small>Linked plan</small></div><Link2 aria-hidden="true" size={18} /></li> : null}
                  </ul>
                </FitnessCard>
              </div>
            </div>
          </details>
        </section>

        <p className="fitness-module__privacy-note"><Award aria-hidden="true" size={16} /> Private activity record. There is no public feed, kudos, follower graph, or leaderboard.</p>
      </> : null}
    </div>
  </Modal>;
}
