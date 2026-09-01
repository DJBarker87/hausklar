import { Dumbbell, Route, Scale } from "lucide-react";
import { useMemo, useState } from "react";

import type {
  FitnessBodyMeasurement,
  FitnessMeasurementHistory,
  FitnessProgressCharts,
  FitnessRunningProgressSeries,
  FitnessStrengthProgressChartSeries,
} from "../../fitness/contract";
import { FitnessMeasurementTrends } from "./FitnessMeasurementTrends";
import { FitnessCard, FitnessLoadingOrError } from "./shared";

type TrendPoint = {
  id: string;
  date: string;
  value: number;
};

export const emptyFitnessProgressCharts: FitnessProgressCharts = {
  weight: [],
  running: [
    { key: "5k", label: "5K", distance_m: 5000, points: [] },
    { key: "10k", label: "10K", distance_m: 10000, points: [] },
  ],
  strength: [
    { key: "squat", label: "Squat", points: [] },
    { key: "chest_press", label: "Chest press", points: [] },
    { key: "overhead_press", label: "Overhead press", points: [] },
  ],
};

function shortDate(value: string): string {
  const date = new Date(value);
  if (Number.isNaN(date.valueOf())) return value.slice(0, 10);
  return new Intl.DateTimeFormat(undefined, { day: "numeric", month: "short" }).format(date);
}

function duration(value: number): string {
  const total = Math.max(0, Math.round(value));
  const hours = Math.floor(total / 3_600);
  const minutes = Math.floor((total % 3_600) / 60);
  const seconds = total % 60;
  return hours > 0
    ? `${hours}:${String(minutes).padStart(2, "0")}:${String(seconds).padStart(2, "0")}`
    : `${minutes}:${String(seconds).padStart(2, "0")}`;
}

function changeText(change: number, unit: string, lowerIsBetter = false): string {
  if (Math.abs(change) < 0.01) return "unchanged";
  const formatted = unit === "s" ? duration(Math.abs(change)) : `${Math.abs(change).toLocaleString(undefined, { maximumFractionDigits: 1 })} ${unit}`;
  if (lowerIsBetter) return `${formatted} ${change < 0 ? "faster" : "slower"}`;
  return `${formatted} ${change > 0 ? "higher" : "lower"}`;
}

function chartLayout(points: TrendPoint[]) {
  const values = points.map((point) => point.value);
  const minimum = Math.min(...values);
  const maximum = Math.max(...values);
  const padding = Math.max((maximum - minimum) * 0.12, maximum === 0 ? 1 : Math.abs(maximum) * 0.005);
  const low = minimum - padding;
  const range = Math.max(maximum + padding - low, 0.5);
  const plotted = points.map((point, index) => ({
    ...point,
    x: 10 + index / Math.max(1, points.length - 1) * 300,
    y: 82 - (point.value - low) / range * 68,
  }));
  const ticks = [low + range, low + range / 2, low].map((value) => ({
    value,
    y: 82 - (value - low) / range * 68,
  }));
  return { plotted, ticks };
}

function TrendFigure({
  title,
  summary,
  points,
  compact = false,
  scaleValue = (value) => value.toLocaleString(undefined, { maximumFractionDigits: 1 }),
  pointValue = (point) => point.value.toLocaleString(undefined, { maximumFractionDigits: 1 }),
}: {
  title: string;
  summary: string;
  points: TrendPoint[];
  compact?: boolean;
  scaleValue?: (value: number) => string;
  pointValue?: (point: TrendPoint) => string;
}) {
  const [activePointId, setActivePointId] = useState<string | null>(null);
  const { plotted, ticks } = chartLayout(points);
  const polyline = plotted.map((point) => `${point.x.toFixed(1)},${point.y.toFixed(1)}`).join(" ");
  const first = points.at(0);
  const last = points.at(-1);
  const activePoint = plotted.find((point) => point.id === activePointId) ?? null;
  const activeXPercent = activePoint ? activePoint.x / 320 * 100 : 0;
  const activeYPercent = activePoint ? activePoint.y / 92 * 100 : 0;
  const tooltipBelowPoint = activeYPercent < 45;
  return <figure className={`fitness-progress-charts__figure${compact ? " is-compact" : ""}`}>
    <figcaption><span>{title}</span><strong>{summary}</strong></figcaption>
    <div className="fitness-progress-charts__plot">
      <div className="fitness-progress-charts__y-axis" aria-hidden="true">
        {ticks.map((tick) => <span key={tick.y} style={{ top: `${tick.y / 92 * 100}%` }}>{scaleValue(tick.value)}</span>)}
      </div>
      <div className="fitness-progress-charts__canvas">
        <svg viewBox="0 0 320 92" preserveAspectRatio="none" role="img" aria-label={summary}>
          {ticks.map((tick) => <path key={tick.y} d={`M10 ${tick.y}H310`} className="is-grid" />)}
          {plotted.length > 1 ? <polyline points={polyline} className="is-line" /> : null}
          {plotted.map((point) => {
            return <g
              key={point.id}
              className={`fitness-progress-charts__point${activePointId === point.id ? " is-active" : ""}`}
              aria-hidden="true"
            >
              <circle className="is-hit" cx={point.x} cy={point.y} r="18" />
              <circle cx={point.x} cy={point.y} r={compact ? 3 : 3.5} />
            </g>;
          })}
        </svg>
        {plotted.map((point) => <button
          type="button"
          key={`control-${point.id}`}
          className="fitness-progress-charts__point-button"
          style={{ left: `${point.x / 320 * 100}%`, top: `${point.y / 92 * 100}%` }}
          aria-label={`${shortDate(point.date)} · ${pointValue(point)}`}
          onPointerEnter={() => setActivePointId(point.id)}
          onPointerDown={() => setActivePointId(point.id)}
          onPointerLeave={(event) => { if (document.activeElement !== event.currentTarget) setActivePointId(null); }}
          onFocus={() => setActivePointId(point.id)}
          onBlur={() => setActivePointId(null)}
        />)}
        {activePoint ? <output
          className={`fitness-progress-charts__tooltip${tooltipBelowPoint ? " is-below" : ""}`}
          style={{
            left: `${Math.max(25, Math.min(75, activeXPercent))}%`,
            top: `${tooltipBelowPoint ? activeYPercent + 6 : activeYPercent - 6}%`,
          }}
        ><strong>{pointValue(activePoint)}</strong><span>{shortDate(activePoint.date)}</span></output> : null}
      </div>
    </div>
    <div className="fitness-progress-charts__x-axis" aria-hidden="true"><span>{first ? shortDate(first.date) : ""}</span><span>{last ? shortDate(last.date) : ""}</span></div>
  </figure>;
}

function canonicalWeights(measurements: FitnessBodyMeasurement[]): FitnessBodyMeasurement[] {
  return measurements
    .filter((item) => item.metric_key === "body.weight_kg" && item.canonical_state !== "duplicate" && item.canonical_state !== "excluded")
    .sort((left, right) => left.measured_at_utc.localeCompare(right.measured_at_utc));
}

function overviewWeightHistory(measurements: FitnessBodyMeasurement[]): FitnessMeasurementHistory {
  const weights = canonicalWeights(measurements);
  const byDay = new Map<string, FitnessBodyMeasurement[]>();
  for (const measurement of weights) {
    const day = measurement.measured_at_utc.slice(0, 10);
    byDay.set(day, [...(byDay.get(day) ?? []), measurement]);
  }
  let trend: number | null = null;
  let previousDay: number | null = null;
  const trendById = new Map<string, number>();
  for (const day of [...byDay.keys()].sort()) {
    const rows = byDay.get(day) ?? [];
    if (!rows.length) continue;
    const dailyValue = rows.reduce((total, row) => total + row.value, 0) / rows.length;
    const dayTime = Date.parse(`${day}T00:00:00Z`);
    if (trend == null || previousDay == null || !Number.isFinite(dayTime)) {
      trend = dailyValue;
    } else {
      const elapsedDays = Math.max(1, Math.round((dayTime - previousDay) / 86_400_000));
      const alpha = 1 - 0.5 ** (elapsedDays / 7);
      trend += alpha * (dailyValue - trend);
    }
    rows.forEach((row) => trendById.set(row.id, trend!));
    previousDay = dayTime;
  }
  return {
    metric: "weight",
    title: "Weight",
    unit: "kg",
    smoothing_method: "time_weighted_exponential",
    smoothing_half_life_days: 7,
    sample_count: weights.length,
    last_updated_at: weights.at(-1)?.measured_at_utc ?? null,
    series: [{
      key: "weight",
      label: "Weight",
      unit: "kg",
      points: weights.map((measurement) => ({
        id: measurement.id,
        measured_at_utc: measurement.measured_at_utc,
        raw_value: measurement.value,
        trend_value: trendById.get(measurement.id) ?? measurement.value,
      })),
    }],
  };
}

export function FitnessOverviewWeightChart({
  measurements,
  loading,
  error,
  retry,
  onOpen,
  online,
  revision,
  onDataChanged,
}: {
  measurements: FitnessBodyMeasurement[];
  loading: boolean;
  error: string | null;
  retry: () => void;
  onOpen: () => void;
  online: boolean;
  revision: number;
  onDataChanged: () => void;
}) {
  const history = useMemo(() => overviewWeightHistory(measurements), [measurements]);
  if (loading && !measurements.length) {
    return <FitnessCard className="fitness-module__overview-weight"><div className="fitness-module__overview-weight-heading"><div><Scale aria-hidden="true" size={18} /><span>Weight progress</span></div><button type="button" className="button button--secondary button--compact" aria-label="View weight progress" onClick={onOpen}>View all</button></div><FitnessLoadingOrError loading error={null} retry={retry} /></FitnessCard>;
  }
  if (error && !measurements.length) {
    return <FitnessCard className="fitness-module__overview-weight"><div className="fitness-module__overview-weight-heading"><div><Scale aria-hidden="true" size={18} /><span>Weight progress</span></div><button type="button" className="button button--secondary button--compact" aria-label="View weight progress" onClick={onOpen}>View all</button></div><FitnessLoadingOrError loading={false} error={error} retry={retry} /></FitnessCard>;
  }
  return <FitnessMeasurementTrends online={online} revision={revision} onDataChanged={onDataChanged} presentation="overview" historyOverride={history} onOpen={onOpen} />;
}

function RunningChart({ series }: { series: FitnessRunningProgressSeries }) {
  const points = series.points.map((point) => ({ id: point.activity_id, date: point.started_at_utc, value: point.duration_s }));
  const first = series.points.at(0);
  const latest = series.points.at(-1);
  if (!latest) return <article className="fitness-progress-charts__tile"><header><Route aria-hidden="true" size={18} /><strong>{series.label} time</strong></header><div className="fitness-progress-charts__empty"><span>Complete a {series.label} or longer run to begin this chart.</span></div></article>;
  const change = first ? latest.duration_s - first.duration_s : 0;
  const quality = latest.source === "best_effort" ? "best effort" : "average-pace estimate";
  const summary = `${duration(latest.duration_s)} · ${first && first.activity_id !== latest.activity_id ? changeText(change, "s", true) : quality}`;
  const kilometres = series.distance_m / 1_000;
  return <article className="fitness-progress-charts__tile"><header><Route aria-hidden="true" size={18} /><strong>{series.label} time</strong></header><TrendFigure
    title={`Latest ${quality}`}
    summary={summary}
    points={points}
    scaleValue={duration}
    pointValue={(point) => `${duration(point.value / kilometres)}/km · ${duration(point.value)} total`}
  /></article>;
}

function StrengthChart({ series }: { series: FitnessStrengthProgressChartSeries }) {
  const points = series.points.map((point) => ({ id: point.activity_id, date: point.performed_at_utc, value: point.load_kg }));
  const first = series.points.at(0);
  const latest = series.points.at(-1);
  const title = series.exercise_name ?? series.label;
  if (!latest) return <article className="fitness-progress-charts__tile"><header><Dumbbell aria-hidden="true" size={18} /><strong>{series.label}</strong></header><div className="fitness-progress-charts__empty"><span>Complete working sets for {series.label.toLocaleLowerCase()} to begin this chart.</span></div></article>;
  const reps = latest.repetitions ? ` × ${latest.repetitions}` : "";
  const change = first ? latest.load_kg - first.load_kg : 0;
  const setCount = `${latest.working_set_count} working set${latest.working_set_count === 1 ? "" : "s"}`;
  const summary = `${latest.load_kg.toLocaleString(undefined, { maximumFractionDigits: 1 })} kg${reps}${first && first.activity_id !== latest.activity_id ? ` · ${changeText(change, "kg")}` : ""} · ${setCount}`;
  const setup = series.setup_name ? ` · ${series.setup_name}` : "";
  return <article className="fitness-progress-charts__tile"><header><Dumbbell aria-hidden="true" size={18} /><strong>{title}</strong></header><TrendFigure title={`Top working set${setup}`} summary={summary} points={points} /></article>;
}

export function FitnessPerformanceCharts({
  data,
  loading,
  error,
  retry,
  onOpenRuns,
  onOpenStrength,
}: {
  data: FitnessProgressCharts;
  loading: boolean;
  error: string | null;
  retry: () => void;
  onOpenRuns: () => void;
  onOpenStrength: () => void;
}) {
  const running = data.running?.length ? data.running : emptyFitnessProgressCharts.running;
  const strength = data.strength?.length ? data.strength : emptyFitnessProgressCharts.strength;
  return <section className="fitness-progress-charts" aria-labelledby="fitness-performance-progress-title">
    <header><div><h3 id="fitness-performance-progress-title">Performance trends</h3><p>See how your runs and working sets are changing.</p></div></header>
    <FitnessLoadingOrError loading={loading} error={error} retry={retry} />
    {!loading && !error ? <>
      <FitnessCard title="Running" detail="Exact analysed efforts are used when available; otherwise the estimate follows the run's average pace.">
        <div className="fitness-progress-charts__grid is-running">{running.map((series) => <RunningChart key={series.key} series={series} />)}</div>
        <button type="button" className="button button--secondary" onClick={onOpenRuns}>Open run history</button>
      </FitnessCard>
      <FitnessCard title="Working sets" detail="Each line follows one exercise and setup. The point is the session's top recorded working set; warm-ups are excluded.">
        <div className="fitness-progress-charts__grid">{strength.map((series) => <StrengthChart key={series.key} series={series} />)}</div>
        <button type="button" className="button button--secondary" onClick={onOpenStrength}>Open strength progress</button>
      </FitnessCard>
    </> : null}
  </section>;
}
