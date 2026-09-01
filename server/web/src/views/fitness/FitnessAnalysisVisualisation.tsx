import type {
  FitnessAnalysisChartType,
  FitnessAnalysisPoint,
  FitnessAnalysisQueryResult,
  FitnessAnalysisSeries,
} from "../../fitness/contract";
import type { CSSProperties, ReactNode } from "react";
import { formatFitnessDate } from "./shared";

const WIDTH = 720;
const HEIGHT = 300;
const INSET_X = 46;
const INSET_Y = 28;
const SERIES_MARKERS = ["●", "■", "▲", "◆", "✚", "✦"];

type NumericPoint = {
  point: FitnessAnalysisPoint;
  series: FitnessAnalysisSeries;
  seriesIndex: number;
  pointIndex: number;
  value: number;
};

function presentUnit(unit?: string | null): string {
  if (!unit || unit === "count") return "";
  const known: Record<string, string> = {
    bpm: "bpm",
    g: "g",
    kg: "kg",
    kcal: "kcal",
    m: "m",
    ms: "ms",
    percent: "%",
    ratio: "",
    s: "s",
  };
  return known[unit] ?? unit.replaceAll("_", " ");
}

function presentValue(value: number | null | undefined, unit?: string | null): string {
  if (value == null || !Number.isFinite(value)) return "—";
  const rounded = Math.abs(value) >= 100 ? value.toFixed(0) : Math.abs(value) >= 10 ? value.toFixed(1) : value.toFixed(2);
  const suffix = presentUnit(unit);
  return `${rounded}${suffix === "%" ? suffix : suffix ? ` ${suffix}` : ""}`;
}

function numericPoints(series: FitnessAnalysisSeries[]): NumericPoint[] {
  return series.flatMap((item, seriesIndex) => item.points.flatMap((point, pointIndex) => (
    point.value != null && Number.isFinite(point.value)
      ? [{ point, series: item, seriesIndex, pointIndex, value: point.value }]
      : []
  )));
}

function chartLabel(result: FitnessAnalysisQueryResult, points: NumericPoint[]): string {
  if (!points.length) return `${result.title}. No numeric values.`;
  const values = points.map((item) => item.value);
  return `${result.title}. ${result.chart_type_key.replaceAll("_", " ")} chart with ${points.length} values from ${presentValue(Math.min(...values), result.unit_key)} to ${presentValue(Math.max(...values), result.unit_key)}.`;
}

function yScale(values: number[]) {
  const minimum = Math.min(0, ...values);
  const maximum = Math.max(0, ...values);
  const span = Math.max(maximum - minimum, 0.0001);
  return {
    minimum,
    maximum,
    y: (value: number) => HEIGHT - INSET_Y - ((value - minimum) / span) * (HEIGHT - INSET_Y * 2),
  };
}

function PlotFrame({ children, label }: { children: ReactNode; label: string }) {
  return <svg className="fitness-module__analysis-chart" viewBox={`0 0 ${WIDTH} ${HEIGHT}`} role="img" aria-label={label}>
    {[0, 0.5, 1].map((fraction) => <line className="is-grid" key={fraction} x1={INSET_X} x2={WIDTH - INSET_X} y1={INSET_Y + fraction * (HEIGHT - INSET_Y * 2)} y2={INSET_Y + fraction * (HEIGHT - INSET_Y * 2)} />)}
    {children}
  </svg>;
}

function LineChart({ result, rolling }: { result: FitnessAnalysisQueryResult; rolling: boolean }) {
  const points = numericPoints(result.series);
  const scale = yScale(points.map((item) => item.value));
  return <PlotFrame label={chartLabel(result, points)}>{result.series.map((series, seriesIndex) => {
    const values = series.points.filter((point): point is FitnessAnalysisPoint & { value: number } => point.value != null && Number.isFinite(point.value));
    const path = values.map((point, index) => {
      const x = values.length === 1 ? WIDTH / 2 : INSET_X + index / (values.length - 1) * (WIDTH - INSET_X * 2);
      return `${index ? "L" : "M"}${x.toFixed(1)},${scale.y(point.value).toFixed(1)}`;
    }).join(" ");
    return <g className={`is-series-${seriesIndex % 6}`} key={series.key}>
      <path className={rolling ? "is-line is-rolling" : "is-line"} d={path} />
      {values.map((point, index) => {
        const x = values.length === 1 ? WIDTH / 2 : INSET_X + index / (values.length - 1) * (WIDTH - INSET_X * 2);
        return <circle className="is-point" cx={x} cy={scale.y(point.value)} r={rolling ? 3 : 4} key={`${point.key}-${index}`}><title>{series.label}: {point.label}, {presentValue(point.value, series.unit_key ?? result.unit_key)}</title></circle>;
      })}
    </g>;
  })}</PlotFrame>;
}

function BarChart({ result, stacked = false }: { result: FitnessAnalysisQueryResult; stacked?: boolean }) {
  const points = numericPoints(result.series);
  const keys = Array.from(new Set(result.series.flatMap((series) => series.points.map((point) => point.key))));
  const totals = stacked
    ? keys.map((key) => result.series.reduce((sum, series) => sum + Math.max(0, series.points.find((point) => point.key === key)?.value ?? 0), 0))
    : points.map((item) => item.value);
  const scale = yScale(totals.length ? totals : [0]);
  const groupWidth = (WIDTH - INSET_X * 2) / Math.max(keys.length, 1);
  return <PlotFrame label={chartLabel(result, points)}>{keys.flatMap((key, groupIndex) => {
    let stackedValue = 0;
    return result.series.flatMap((series, seriesIndex) => {
      const point = series.points.find((candidate) => candidate.key === key);
      if (point?.value == null || !Number.isFinite(point.value)) return [];
      const barWidth = stacked ? Math.max(5, groupWidth * 0.66) : Math.max(4, groupWidth * 0.72 / Math.max(result.series.length, 1));
      const x = INSET_X + groupIndex * groupWidth + groupWidth * 0.14 + (stacked ? 0 : seriesIndex * barWidth);
      const startValue = stacked ? stackedValue : 0;
      const endValue = stacked ? stackedValue + point.value : point.value;
      stackedValue = endValue;
      const y = scale.y(Math.max(startValue, endValue));
      const height = Math.max(1, Math.abs(scale.y(startValue) - scale.y(endValue)));
      return [<rect className={`is-bar is-series-${seriesIndex % 6}`} x={x} y={y} width={barWidth} height={height} key={`${key}-${series.key}`}><title>{series.label}: {point.label}, {presentValue(point.value, series.unit_key ?? result.unit_key)}</title></rect>];
    });
  })}</PlotFrame>;
}

function ScatterChart({ result }: { result: FitnessAnalysisQueryResult }) {
  const points = numericPoints(result.series);
  const xValues = points.map((item) => item.point.x_value ?? (typeof item.point.x === "number" ? item.point.x : item.pointIndex));
  const xMin = Math.min(...xValues, 0);
  const xMax = Math.max(...xValues, 1);
  const xSpan = Math.max(xMax - xMin, 0.0001);
  const scale = yScale(points.map((item) => item.value));
  return <PlotFrame label={chartLabel(result, points)}>{points.map((item, index) => {
    const rawX = item.point.x_value ?? (typeof item.point.x === "number" ? item.point.x : item.pointIndex);
    const x = INSET_X + ((rawX - xMin) / xSpan) * (WIDTH - INSET_X * 2);
    return <g className={`is-series-${item.seriesIndex % 6}`} key={`${item.series.key}-${item.point.key}-${index}`}><circle className="is-scatter" cx={x} cy={scale.y(item.value)} r="6"><title>{item.series.label}: {item.point.label}, x {rawX}, y {presentValue(item.value, item.series.unit_key ?? result.unit_key)}</title></circle></g>;
  })}</PlotFrame>;
}

function RangeBandChart({ result }: { result: FitnessAnalysisQueryResult }) {
  const series = result.series[0];
  const bandPoints = (series?.points ?? []).filter((point): point is FitnessAnalysisPoint & { low: number; high: number } => point.low != null && point.high != null && Number.isFinite(point.low) && Number.isFinite(point.high));
  const values = bandPoints.flatMap((point) => [point.low, point.high, ...(point.value != null ? [point.value] : [])]);
  const scale = yScale(values.length ? values : [0]);
  const xAt = (index: number) => bandPoints.length === 1 ? WIDTH / 2 : INSET_X + index / (bandPoints.length - 1) * (WIDTH - INSET_X * 2);
  const upper = bandPoints.map((point, index) => `${xAt(index)},${scale.y(point.high)}`).join(" ");
  const lower = [...bandPoints].reverse().map((point, reverseIndex) => {
    const index = bandPoints.length - reverseIndex - 1;
    return `${xAt(index)},${scale.y(point.low)}`;
  }).join(" ");
  const central = bandPoints.flatMap((point, index) => point.value != null ? [{ point, index }] : []).map(({ point, index }, pathIndex) => `${pathIndex ? "L" : "M"}${xAt(index)},${scale.y(point.value ?? 0)}`).join(" ");
  const numeric = numericPoints(result.series);
  return <PlotFrame label={chartLabel(result, numeric)}><polygon className="is-range-band" points={`${upper} ${lower}`} />{central ? <path className="is-line" d={central} /> : null}</PlotFrame>;
}

function CalendarHeatmap({ result }: { result: FitnessAnalysisQueryResult }) {
  const points = numericPoints(result.series);
  const maximum = Math.max(...points.map((item) => Math.abs(item.value)), 1);
  return <div className="fitness-module__calendar-heatmap" role="img" aria-label={chartLabel(result, points)}>{points.map((item, index) => {
    const intensity = Math.max(0.08, Math.abs(item.value) / maximum);
    return <span className={`is-series-${item.seriesIndex % 6}`} style={{ "--heat": intensity } as CSSProperties} key={`${item.series.key}-${item.point.key}-${index}`} title={`${item.point.label}: ${presentValue(item.value, item.series.unit_key ?? result.unit_key)}`}><span className="sr-only">{item.point.label}: {presentValue(item.value, item.series.unit_key ?? result.unit_key)}</span></span>;
  })}</div>;
}

function ResultTable({ result, compact = false }: { result: FitnessAnalysisQueryResult; compact?: boolean }) {
  return <div className="fitness-module__table-wrap"><table className="fitness-module__table fitness-module__analysis-table">
    <thead><tr><th>Series</th><th>Group</th><th>Value</th><th>Range</th><th>Sample</th><th>Missing</th><th>Quality</th></tr></thead>
    <tbody>{result.series.flatMap((series) => series.points).length ? result.series.flatMap((series) => series.points.map((point, index) => <tr key={`${series.key}-${point.key}-${index}`}>
      <td>{series.label}</td><td>{point.label}</td><td>{presentValue(point.value, series.unit_key ?? result.unit_key)}</td><td>{point.low != null || point.high != null ? `${presentValue(point.low, series.unit_key ?? result.unit_key)}–${presentValue(point.high, series.unit_key ?? result.unit_key)}` : "—"}</td><td>{point.sample_size ?? "—"}</td><td>{point.missing_rate != null ? `${Math.round(point.missing_rate * 100)}%` : "—"}</td><td>{point.quality ?? "—"}</td>
    </tr>)) : <tr><td colSpan={7}>No observations in this result.</td></tr>}</tbody>
  </table>{compact ? null : <p className="fitness-module__privacy-note">Missing values remain missing; they are not silently filled.</p>}</div>;
}

function chartFor(result: FitnessAnalysisQueryResult) {
  const chartType = result.chart_type_key as string;
  if (chartType === "line") return <LineChart result={result} rolling={false} />;
  if (chartType === "rolling_average") return <LineChart result={result} rolling />;
  if (chartType === "bar" || chartType === "histogram") return <BarChart result={result} />;
  if (chartType === "stacked_bar") return <BarChart result={result} stacked />;
  if (chartType === "scatter") return <ScatterChart result={result} />;
  if (chartType === "calendar_heatmap") return <CalendarHeatmap result={result} />;
  if (chartType === "range_band") return <RangeBandChart result={result} />;
  if (chartType === "table") return <ResultTable result={result} />;
  return <div className="fitness-module__notice" role="status">This chart type is newer than this version of the app. The accessible result table is shown instead.</div>;
}

function classificationCopy(classification: FitnessAnalysisQueryResult["metadata"]["classification"]): string {
  if (classification === "correlational") return "Association only — this does not show that one factor caused another.";
  if (classification === "plan_arithmetic") return "Calculated from recorded plan and completion values.";
  return "A descriptive summary of recorded observations.";
}

function SeriesLegend({ result }: { result: FitnessAnalysisQueryResult }) {
  if (!result.series.length || result.chart_type_key === "table") return null;
  return <ul className="fitness-module__analysis-legend" aria-label="Chart series">{result.series.map((series, index) => <li key={series.key}><span className={`is-series-${index % 6}`} aria-hidden="true">{SERIES_MARKERS[index % SERIES_MARKERS.length]}</span>{series.label}</li>)}</ul>;
}

export function FitnessAnalysisVisualisation({ result, compact = false }: { result: FitnessAnalysisQueryResult; compact?: boolean }) {
  if (result.status === "empty") return <div className="fitness-module__empty"><strong>No matching observations</strong><span>{result.summary ?? "Try a wider period or fewer filters."}</span><AnalysisMetadata result={result} /></div>;
  if (result.status === "insufficient_sample") return <div className="fitness-module__empty"><strong>Not enough comparable data</strong><span>{result.summary ?? "More observations are needed before this comparison is useful."}</span><AnalysisMetadata result={result} /></div>;
  const knownChart = (["line", "rolling_average", "bar", "stacked_bar", "scatter", "histogram", "calendar_heatmap", "range_band", "table"] as string[]).includes(result.chart_type_key);
  return <div className="fitness-module__analysis-result">
    {result.summary ? <p className="fitness-module__analysis-summary">{result.summary}</p> : null}
    {result.difference ? <div className="fitness-module__analysis-difference"><span>{result.difference.label}</span><strong>{presentValue(result.difference.value, result.difference.unit_key ?? result.unit_key)}</strong></div> : null}
    <SeriesLegend result={result} />
    {chartFor(result)}
    {!compact && result.chart_type_key !== "table" ? <details className="fitness-module__analysis-data"><summary>View chart data</summary><ResultTable result={result} compact /></details> : null}
    {!knownChart ? <ResultTable result={result} compact /> : null}
    <AnalysisMetadata result={result} />
  </div>;
}

export function AnalysisMetadata({ result }: { result: FitnessAnalysisQueryResult }) {
  const metadata = result.metadata;
  return <details className="fitness-module__analysis-metadata"><summary>Data and method</summary>
    <dl>
      <div><dt>Period</dt><dd>{metadata.period.label ?? `${formatFitnessDate(metadata.period.start)}–${formatFitnessDate(metadata.period.end)}`}</dd></div>
      <div><dt>Sample</dt><dd>{metadata.sample_size} observations</dd></div>
      <div><dt>Missing</dt><dd>{Math.round(metadata.missing_rate * 100)}%{metadata.missing_count != null ? ` (${metadata.missing_count})` : ""}</dd></div>
      <div><dt>Source quality</dt><dd>{metadata.source_quality.length ? metadata.source_quality.join(", ") : "Not reported"}</dd></div>
      <div><dt>Measurement quality</dt><dd>{metadata.measurement_quality.length ? metadata.measurement_quality.join(", ") : "Not reported"}</dd></div>
      <div><dt>Reading selection</dt><dd>{metadata.canonical_policy.replace(/\bcanonical\b/gi, "chosen")}</dd></div>
      <div><dt>Duplicate handling</dt><dd>{metadata.duplicate_policy}</dd></div>
      <div><dt>Classification</dt><dd>{metadata.classification.replaceAll("_", " ")}</dd></div>
    </dl>
    <p className="fitness-module__analysis-classification">{classificationCopy(metadata.classification)}</p>
    {result.limitations.length ? <ul>{result.limitations.map((limitation) => <li key={limitation}>{limitation}</li>)}</ul> : <p>No additional limitations were reported.</p>}
  </details>;
}

export const FITNESS_ANALYSIS_CHART_TYPES: readonly FitnessAnalysisChartType[] = [
  "line", "rolling_average", "bar", "stacked_bar", "scatter", "histogram", "calendar_heatmap", "range_band", "table",
];
