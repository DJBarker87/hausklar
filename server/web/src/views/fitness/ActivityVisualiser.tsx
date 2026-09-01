import { Crosshair, LoaderCircle, MapPinned, TimerReset } from "lucide-react";
import { useEffect, useMemo, useRef, useState, type ReactNode } from "react";

import { api } from "../../api";
import type { FitnessActivityDetail, FitnessActivityStream } from "../../fitness/contract";
import { ActivityRouteMap } from "./ActivityRouteMap";
import { routePointsFromStreams, type ActivityRoutePoint } from "./activityRouteGeometry";
import { errorMessage } from "./shared";

type AnalysisAxis = "time" | "distance";

const chartMetricOrder = [
  "pace_s_per_km",
  "speed_mps",
  "heart_rate_bpm",
  "altitude_m",
  "cadence_spm",
  "power_w",
  "stride_length_m",
  "vertical_oscillation_mm",
  "vertical_ratio_pct",
  "ground_contact_time_ms",
  "ground_contact_balance_pct",
  "respiration_rate_bpm",
  "temperature_c",
  "stroke_rate_spm",
];

const coordinateMetrics = new Set(["latitude_deg", "longitude_deg"]);
const axisMetrics = new Set(["elapsed_ms", "timer_ms", "distance_m"]);

const metricLabels: Record<string, string> = {
  pace_s_per_km: "Pace",
  speed_mps: "Speed",
  heart_rate_bpm: "Heart rate",
  altitude_m: "Elevation",
  cadence_spm: "Cadence",
  power_w: "Power",
  stride_length_m: "Stride length",
  vertical_oscillation_mm: "Vertical oscillation",
  vertical_ratio_pct: "Vertical ratio",
  ground_contact_time_ms: "Ground contact time",
  ground_contact_balance_pct: "Ground contact balance",
  respiration_rate_bpm: "Respiration rate",
  temperature_c: "Temperature",
  stroke_rate_spm: "Stroke rate",
};

const runningCoreMetrics = ["pace_s_per_km", "heart_rate_bpm", "altitude_m", "cadence_spm", "power_w"];
const cyclingCoreMetrics = ["speed_mps", "power_w", "heart_rate_bpm", "cadence_spm", "altitude_m"];

function labelForMetric(metric: string): string {
  return metricLabels[metric] ?? metric.replaceAll("_", " ").replace(/\b\w/g, (letter) => letter.toUpperCase());
}

function finiteValues(values: Array<number | null | undefined>): number[] {
  return values.filter((value): value is number => value != null && Number.isFinite(value));
}

function finiteExtent(values: Array<number | null | undefined>): { minimum: number; maximum: number } | null {
  const valid = finiteValues(values);
  if (!valid.length) return null;
  return { minimum: Math.min(...valid), maximum: Math.max(...valid) };
}

const canonicalAverageMetricKeys: Record<string, string[]> = {
  pace_s_per_km: ["running.average_pace_s_per_km", "pace.average_s_per_km"],
  speed_mps: ["speed.average_mps"],
  heart_rate_bpm: ["heart_rate.average_bpm"],
  altitude_m: ["elevation.average_m"],
  cadence_spm: ["cadence.average_spm"],
  power_w: ["power.average_w"],
  stride_length_m: ["running.stride_length_average_m", "stride_length.average_m"],
  vertical_oscillation_mm: ["running.vertical_oscillation_average_mm"],
  vertical_ratio_pct: ["running.vertical_ratio_average_pct"],
  ground_contact_time_ms: ["running.ground_contact_time_average_ms"],
  ground_contact_balance_pct: ["running.ground_contact_balance_average_pct"],
  respiration_rate_bpm: ["respiration_rate.average_bpm"],
  temperature_c: ["temperature.average_c"],
  stroke_rate_spm: ["stroke_rate.average_spm"],
};

function canonicalChartAverage(detail: FitnessActivityDetail, metric: string): number | null {
  const keys = canonicalAverageMetricKeys[metric] ?? [];
  const direct = detail.summary_metrics.find((summary) => keys.includes(summary.metric_key))?.value_number;
  if (direct != null && Number.isFinite(direct)) return direct;
  if (metric === "pace_s_per_km") {
    const speed = detail.summary_metrics.find((summary) => summary.metric_key === "speed.average_mps")?.value_number;
    if (speed != null && Number.isFinite(speed) && speed > 0) return 1_000 / speed;
  }
  return null;
}

function formatDuration(milliseconds: number): string {
  const totalSeconds = Math.max(0, Math.round(milliseconds / 1_000));
  const hours = Math.floor(totalSeconds / 3_600);
  const minutes = Math.floor((totalSeconds % 3_600) / 60);
  const seconds = totalSeconds % 60;
  return hours
    ? `${hours}:${String(minutes).padStart(2, "0")}:${String(seconds).padStart(2, "0")}`
    : `${minutes}:${String(seconds).padStart(2, "0")}`;
}

function formatDistance(metres: number): string {
  return metres >= 1_000 ? `${(metres / 1_000).toFixed(metres >= 10_000 ? 1 : 2)} km` : `${Math.round(metres)} m`;
}

function displayUnit(metric: string, sourceUnit?: string): string {
  if (metric === "pace_s_per_km") return "/km";
  if (metric === "speed_mps") return "km/h";
  if (metric === "temperature_c") return "°C";
  if (sourceUnit === "degC") return "°C";
  return sourceUnit ?? "";
}

function formatMetric(value: number | null | undefined, metric: string, unit?: string): string {
  if (value == null || !Number.isFinite(value)) return "No sample";
  if (metric === "pace_s_per_km") {
    const totalSeconds = Math.max(0, Math.round(value));
    return `${Math.floor(totalSeconds / 60)}:${String(totalSeconds % 60).padStart(2, "0")}/km`;
  }
  const converted = metric === "speed_mps" ? value * 3.6 : value;
  const precision = ["altitude_m", "temperature_c", "stride_length_m", "vertical_ratio_pct", "ground_contact_balance_pct"].includes(metric) ? 1 : 0;
  return `${converted.toFixed(precision)}${displayUnit(metric, unit) ? ` ${displayUnit(metric, unit)}` : ""}`;
}

function defaultVisibleMetrics(metrics: string[], sportKey: string): string[] {
  const preferred = sportKey.includes("run")
    ? metrics.includes("pace_s_per_km") ? runningCoreMetrics : ["speed_mps", ...runningCoreMetrics.slice(1)]
    : sportKey.includes("cycl")
      ? cyclingCoreMetrics
      : ["speed_mps", "heart_rate_bpm", "altitude_m", "cadence_spm", "power_w"];
  const selected = preferred.filter((metric) => metrics.includes(metric));
  return (selected.length ? selected : metrics).slice(0, 5);
}

function xSeries(stream: FitnessActivityStream, axis: AnalysisAxis): Array<number | null> {
  return axis === "distance"
    ? (stream.distance_m ?? stream.offset_ms.map(() => null))
    : stream.offset_ms;
}

function xPosition(values: Array<number | null>, index: number, width = 760): number {
  const extent = finiteExtent(values);
  const value = values[index];
  if (!extent || value == null) return 0;
  return ((value - extent.minimum) / Math.max(extent.maximum - extent.minimum, 0.0001)) * width;
}

function linePath(
  values: Array<number | null>,
  xValues: Array<number | null>,
  width = 760,
  height = 150,
  invert = false,
): string {
  const extent = finiteExtent(values);
  const xExtent = finiteExtent(xValues);
  if (!extent || !xExtent || values.length < 2) return "";
  const span = Math.max(extent.maximum - extent.minimum, 0.0001);
  const xSpan = Math.max(xExtent.maximum - xExtent.minimum, 0.0001);
  let drawing = false;
  return values.map((value, index) => {
    const xValue = xValues[index];
    if (value == null || xValue == null || !Number.isFinite(value) || !Number.isFinite(xValue)) {
      drawing = false;
      return "";
    }
    const x = ((xValue - xExtent.minimum) / xSpan) * width;
    const fraction = (value - extent.minimum) / span;
    const y = invert ? 6 + fraction * (height - 12) : height - 6 - fraction * (height - 12);
    const command = drawing ? "L" : "M";
    drawing = true;
    return `${command}${x.toFixed(2)},${y.toFixed(2)}`;
  }).filter(Boolean).join(" ");
}

function valueY(value: number, extent: { minimum: number; maximum: number }, height = 150, invert = false): number {
  const fraction = (value - extent.minimum) / Math.max(extent.maximum - extent.minimum, 0.0001);
  return invert ? 6 + fraction * (height - 12) : height - 6 - fraction * (height - 12);
}

export function nearestStreamIndex(offsets: number[], ratio: number): number {
  if (!offsets.length) return 0;
  const boundedRatio = Math.max(0, Math.min(1, ratio));
  const firstOffset = offsets[0] ?? 0;
  const lastOffset = offsets.at(-1) ?? firstOffset;
  const targetOffset = firstOffset + boundedRatio * (lastOffset - firstOffset);
  let nearestIndex = 0;
  let nearestDelta = Number.POSITIVE_INFINITY;
  offsets.forEach((offset, index) => {
    const delta = Math.abs(offset - targetOffset);
    if (delta < nearestDelta) {
      nearestDelta = delta;
      nearestIndex = index;
    }
  });
  return nearestIndex;
}

export function streamIndexNearestOffset(offsets: number[], targetOffset: number): number {
  if (!offsets.length) return 0;
  let nearestIndex = 0;
  let nearestDelta = Number.POSITIVE_INFINITY;
  offsets.forEach((offset, index) => {
    const delta = Math.abs(offset - targetOffset);
    if (delta < nearestDelta) {
      nearestIndex = index;
      nearestDelta = delta;
    }
  });
  return nearestIndex;
}

function nearestAxisIndex(values: Array<number | null>, ratio: number): number {
  const extent = finiteExtent(values);
  if (!extent) return 0;
  const target = extent.minimum + Math.max(0, Math.min(1, ratio)) * (extent.maximum - extent.minimum);
  let nearestIndex = 0;
  let nearestDelta = Number.POSITIVE_INFINITY;
  values.forEach((value, index) => {
    if (value == null) return;
    const delta = Math.abs(value - target);
    if (delta < nearestDelta) {
      nearestIndex = index;
      nearestDelta = delta;
    }
  });
  return nearestIndex;
}

export function streamOffsetX(offsets: number[], index: number, width = 760): number {
  const firstOffset = offsets[0] ?? 0;
  const lastOffset = offsets.at(-1) ?? firstOffset + 1;
  const selectedOffset = offsets[index] ?? firstOffset;
  return ((selectedOffset - firstOffset) / Math.max(lastOffset - firstOffset, 1)) * width;
}

function ChartsSkeleton() {
  return <section id="activity-charts" className="fitness-module__activity-anchor fitness-module__visual-skeleton" role="status" aria-label="Loading activity charts">
      <div className="fitness-module__visual-skeleton-toolbar" aria-hidden="true" />
      <div className="fitness-module__visual-skeleton-charts" aria-hidden="true"><span /><span /></div>
    </section>;
}

function MissingRecordedSection({ id, title, detail }: { id: string; title: string; detail: string }) {
  return <section id={id} className="fitness-module__activity-anchor fitness-module__activity-missing">
    <strong>{title}</strong>
    <span>{detail}</span>
  </section>;
}

function RouteMapModuleSkeleton({ selectedSummary }: { selectedSummary: string }) {
  return <figure className="fitness-module__route-map" aria-label="Loading interactive activity route">
    <figcaption><MapPinned aria-hidden="true" size={17} /><span>Activity route</span><strong>{selectedSummary}</strong></figcaption>
    <div className="fitness-module__route-map-viewport"><div className="fitness-module__route-map-loading" role="status"><span aria-hidden="true" /><strong>Preparing route…</strong></div></div>
  </figure>;
}

export function ActivityVisualiser({
  detail,
  overview,
  splits,
  navigation,
}: {
  detail: FitnessActivityDetail;
  overview?: ReactNode;
  splits?: ReactNode;
  navigation?: ReactNode;
}) {
  const chartMetrics = useMemo(() => [
    ...chartMetricOrder.filter((metric) => detail.available_stream_metrics.includes(metric)),
    ...detail.available_stream_metrics.filter((metric) => (
      !chartMetricOrder.includes(metric)
      && !coordinateMetrics.has(metric)
      && !axisMetrics.has(metric)
    )),
  ], [detail.available_stream_metrics]);
  const requestedMetrics = useMemo(() => chartMetrics.length ? [
    ...chartMetrics,
    ...detail.available_stream_metrics.filter((metric) => coordinateMetrics.has(metric)),
  ] : [], [chartMetrics, detail.available_stream_metrics]);
  const requestedMetricKey = requestedMetrics.join(",");
  const coreMetrics = useMemo(
    () => defaultVisibleMetrics(chartMetrics, detail.activity.sport_key),
    [chartMetrics, detail.activity.sport_key],
  );
  const [visibleMetrics, setVisibleMetrics] = useState<string[]>(coreMetrics);
  const [clock, setClock] = useState<"elapsed" | "timer">("elapsed");
  const [axis, setAxis] = useState<AnalysisAxis>("time");
  const [selection, setSelection] = useState<[number, number]>([0, 100]);
  const [requestedRange, setRequestedRange] = useState<[number, number] | null>(null);
  const [stream, setStream] = useState<FitnessActivityStream | null>(null);
  const [routeStream, setRouteStream] = useState<FitnessActivityStream | null>(null);
  const [routeLoading, setRouteLoading] = useState(false);
  const [selectedIndex, setSelectedIndex] = useState(0);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [requestNonce, setRequestNonce] = useState(0);
  const requestGeneration = useRef(0);
  const routeRequestGeneration = useRef(0);
  const hasRouteStream = detail.available_stream_metrics.includes("latitude_deg")
    && detail.available_stream_metrics.includes("longitude_deg");
  const previewRoutePoints = useMemo<ActivityRoutePoint[]>(() => {
    const coordinates = detail.activity.route_preview ?? [];
    const streamMaximum = Math.max(0, (stream?.offset_ms.length ?? coordinates.length) - 1);
    return coordinates.flatMap((coordinate, index) => {
      const latitude = coordinate[0];
      const longitude = coordinate[1];
      if (!Number.isFinite(latitude) || !Number.isFinite(longitude) || Math.abs(latitude) > 90 || Math.abs(longitude) > 180) return [];
      return [{
        coordinate: [longitude, latitude],
        streamIndex: Math.round(index / Math.max(1, coordinates.length - 1) * streamMaximum),
      } satisfies ActivityRoutePoint];
    });
  }, [detail.activity.route_preview, stream?.offset_ms.length]);
  useEffect(() => {
    setVisibleMetrics(coreMetrics);
    setClock("elapsed");
    setAxis("time");
    setSelection([0, 100]);
    setRequestedRange(null);
    setStream(null);
    setRouteStream(null);
    setSelectedIndex(0);
  }, [coreMetrics, detail.activity.id]);

  useEffect(() => {
    const generation = ++requestGeneration.current;
    if (!requestedMetricKey) {
      setStream(null);
      setLoading(false);
      return;
    }
    setLoading(true);
    setError(null);
    const query = new URLSearchParams({
      metrics: requestedMetricKey,
      clock,
      max_points: requestedRange ? "1600" : "700",
    });
    if (requestedRange) {
      query.set("from_offset_ms", String(requestedRange[0]));
      query.set("to_offset_ms", String(requestedRange[1]));
    }
    void api<FitnessActivityStream>(
      `/fitness/activities/${encodeURIComponent(detail.activity.id)}/streams?${query.toString()}`,
      {},
      true,
      false,
    ).then((response) => {
      if (generation !== requestGeneration.current) return;
      setStream(response);
      setSelectedIndex(Math.floor(Math.max(0, response.offset_ms.length - 1) / 2));
    }).catch((requestError) => {
      if (generation === requestGeneration.current) setError(errorMessage(requestError));
    }).finally(() => {
      if (generation === requestGeneration.current) setLoading(false);
    });
  }, [clock, detail.activity.id, requestedMetricKey, requestedRange, requestNonce]);

  useEffect(() => {
    const generation = ++routeRequestGeneration.current;
    if (!hasRouteStream) {
      setRouteStream(null);
      setRouteLoading(false);
      return;
    }
    setRouteStream(null);
    setRouteLoading(true);
    const query = new URLSearchParams({
      metrics: "latitude_deg,longitude_deg",
      clock,
      max_points: "20000",
    });
    void api<FitnessActivityStream>(
      `/fitness/activities/${encodeURIComponent(detail.activity.id)}/streams?${query.toString()}`,
      {},
      true,
      false,
    ).then((response) => {
      if (generation === routeRequestGeneration.current) setRouteStream(response);
    }).catch(() => {
      // The chart overview also contains a bounded GPS trace, so it remains a
      // useful fallback if the high-resolution route request fails.
      if (generation === routeRequestGeneration.current) setRouteStream(null);
    }).finally(() => {
      if (generation === routeRequestGeneration.current) setRouteLoading(false);
    });
  }, [clock, detail.activity.id, hasRouteStream]);

  function selectAt(clientX: number, element: SVGSVGElement) {
    if (!stream?.offset_ms.length) return;
    const bounds = element.getBoundingClientRect();
    const ratio = Math.max(0, Math.min(1, (clientX - bounds.left) / Math.max(bounds.width, 1)));
    setSelectedIndex(axis === "time"
      ? nearestStreamIndex(stream.offset_ms, ratio)
      : nearestAxisIndex(xSeries(stream, axis), ratio));
  }

  function moveSelection(direction: -1 | 1) {
    if (!stream?.offset_ms.length) return;
    setSelectedIndex((current) => Math.max(0, Math.min(stream.offset_ms.length - 1, current + direction)));
  }

  function changeClock(nextClock: "elapsed" | "timer") {
    setClock(nextClock);
    setSelection([0, 100]);
    setRequestedRange(null);
  }

  function toggleMetric(metric: string) {
    setVisibleMetrics((current) => current.includes(metric)
      ? current.length === 1 ? current : current.filter((item) => item !== metric)
      : [...current, metric]);
  }

  const totalOffset = Math.max(
    0,
    (clock === "timer"
      ? detail.activity.timer_duration_s ?? detail.activity.duration_s
      : detail.activity.elapsed_duration_s ?? detail.activity.duration_s ?? detail.activity.timer_duration_s
    ) ?? 0,
  ) * 1_000;

  function loadSelectedRange() {
    const from = Math.round(totalOffset * selection[0] / 100);
    const to = Math.round(totalOffset * selection[1] / 100);
    if (to > from) setRequestedRange([from, to]);
  }

  const routeSource = routeStream ?? (routeLoading ? null : stream);
  const streamedRoutePoints = useMemo(() => routePointsFromStreams(
    routeSource?.series.latitude_deg ?? [],
    routeSource?.series.longitude_deg ?? [],
  ), [routeSource]);
  const routePoints = streamedRoutePoints.length > 1 ? streamedRoutePoints : previewRoutePoints;
  const selectedOffsetForRoute = stream?.offset_ms[selectedIndex] ?? 0;
  const selectedRouteIndex = routeSource && streamedRoutePoints.length > 1
    ? streamIndexNearestOffset(routeSource.offset_ms, selectedOffsetForRoute)
    : selectedIndex;

  function selectRouteIndex(routeIndex: number) {
    const routeOffset = routeSource?.offset_ms[routeIndex];
    if (!stream) { setSelectedIndex(routeIndex); return; }
    setSelectedIndex(routeOffset == null
      ? Math.max(0, Math.min(stream.offset_ms.length - 1, routeIndex))
      : streamIndexNearestOffset(stream.offset_ms, routeOffset));
  }

  const isRun = detail.activity.sport_key.includes("run");
  const selectedRouteOffset = stream?.offset_ms[selectedIndex] ?? routeSource?.offset_ms[selectedRouteIndex] ?? null;
  const selectedRouteDistance = stream?.distance_m?.[selectedIndex] ?? routeSource?.distance_m?.[selectedRouteIndex] ?? null;
  const routeSummary = selectedRouteOffset == null
    ? "Route preview"
    : selectedRouteDistance != null
      ? `${formatDistance(selectedRouteDistance)} · ${formatDuration(selectedRouteOffset)}`
      : formatDuration(selectedRouteOffset);
  const hasRoute = routeLoading || routePoints.length > 1;
  const routeSection = hasRoute ? <section id="activity-route" className="fitness-module__activity-anchor">
    <div className="fitness-module__visual-stage has-route">
      {routePoints.length > 1 ? <ActivityRouteMap points={routePoints} selectedStreamIndex={selectedRouteIndex} selectedSummary={routeSummary} onSelectStreamIndex={selectRouteIndex} /> : <RouteMapModuleSkeleton selectedSummary={routeSummary} />}
    </div>
  </section> : isRun ? <MissingRecordedSection id="activity-route" title="No route recorded" detail="This run has no recorded route." /> : null;
  const graphsMissing = isRun ? <MissingRecordedSection id="activity-charts" title="No graphs recorded" detail="This run has no pace, heart-rate or other sensor graph data." /> : null;

  if (!chartMetrics.length) return <div className="fitness-module__visualiser" aria-busy={routeLoading}>
    {routeSection}
    {navigation}
    {overview}
    {splits}
    {graphsMissing}
  </div>;
  if (loading && !stream) return <div className="fitness-module__visualiser" aria-busy="true">
    {routeSection}
    {navigation}
    {overview}
    {splits}
    <ChartsSkeleton />
  </div>;
  if (error && !stream) return <div className="fitness-module__visualiser">
    {routeSection}
    {navigation}
    {overview}
    {splits}
    <section id="activity-charts" className="fitness-module__activity-anchor"><div className="fitness-module__notice fitness-module__notice--error" role="alert"><div><strong>Couldn’t load the activity charts</strong><span>{error}</span></div><button type="button" className="button button--secondary" onClick={() => setRequestNonce((value) => value + 1)}>Try again</button></div></section>
  </div>;
  if (!stream?.offset_ms.length) return <div className="fitness-module__visualiser">
    {routeSection}
    {navigation}
    {overview}
    {splits}
    {graphsMissing ?? <MissingRecordedSection id="activity-charts" title="No graphs recorded" detail="This activity has no sensor graph data." />}
  </div>;

  const distanceValues = stream.distance_m ?? [];
  const distanceExtent = finiteExtent(distanceValues);
  const hasDistanceAxis = Boolean(distanceExtent && distanceExtent.maximum > distanceExtent.minimum);
  const effectiveAxis = axis === "distance" && hasDistanceAxis ? "distance" : "time";
  const chartXValues = xSeries(stream, effectiveAxis);
  const selectedOffset = selectedOffsetForRoute;
  const selectedDistance = distanceValues[selectedIndex];
  const crosshairX = xPosition(chartXValues, selectedIndex);
  const displayedMetrics = visibleMetrics.filter((metric) => chartMetrics.includes(metric));
  const boundaries = detail.intervals.filter((interval) => [
    "source_lap", "kilometre_split", "mile_split", "work_interval", "recovery_interval",
    "warmup", "cooldown", "plan_step", "planned_step",
  ].includes(interval.interval_kind));
  const xExtent = finiteExtent(chartXValues);
  const pointInspector = <aside className="fitness-module__point-inspector" aria-label="Selected activity point">
    <Crosshair aria-hidden="true" size={18} />
    <div><span>Selected point</span><strong>{formatDuration(selectedOffset)}</strong>{selectedDistance != null ? <small>{formatDistance(selectedDistance)}</small> : null}</div>
    <dl>{displayedMetrics.map((metric) => <div key={metric}><dt>{labelForMetric(metric)}</dt><dd>{formatMetric(stream.series[metric]?.[selectedIndex], metric, stream.units[metric])}</dd></div>)}</dl>
  </aside>;

  return <div className="fitness-module__visualiser" aria-busy={loading}>
    {routeSection}

    {navigation}
    {overview}
    {splits}

    <section id="activity-charts" className="fitness-module__activity-anchor fitness-module__visual-charts-section">
      <div className="fitness-module__visualiser-intro">
        <div>
          <span className="fitness-module__eyebrow">Charts</span>
          <strong>Follow the effort</strong>
          <p>Tap, drag or use the arrow keys on any chart. The route and every visible chart follow the same moment.</p>
        </div>
        {loading ? <span className="fitness-module__pill is-neutral" role="status"><LoaderCircle className="is-spinning" aria-hidden="true" size={14} /> Updating…</span> : null}
      </div>

      {error ? <div className="fitness-module__notice fitness-module__notice--error" role="alert"><span>Couldn’t update this chart view. {error}</span><button type="button" onClick={() => setRequestNonce((value) => value + 1)}>Try again</button></div> : null}

      <div className="fitness-module__visual-toolbar">
        <div className="fitness-module__visual-toolbar-group">
          <span>Show progress by</span>
          <div className="fitness-module__choice-grid" role="group" aria-label="Chart horizontal axis">
            <button type="button" className={effectiveAxis === "time" ? "is-active" : undefined} aria-pressed={effectiveAxis === "time"} onClick={() => setAxis("time")}>Time</button>
            <button type="button" className={effectiveAxis === "distance" ? "is-active" : undefined} aria-pressed={effectiveAxis === "distance"} disabled={!hasDistanceAxis} onClick={() => setAxis("distance")}>Distance</button>
          </div>
        </div>
        <div className="fitness-module__visual-toolbar-group">
          <span>Time view</span>
          <div className="fitness-module__choice-grid" role="group" aria-label="Chart time view">
            <button type="button" className={clock === "elapsed" ? "is-active" : undefined} aria-pressed={clock === "elapsed"} disabled={loading} onClick={() => changeClock("elapsed")}>Elapsed</button>
            <button type="button" className={clock === "timer" ? "is-active" : undefined} aria-pressed={clock === "timer"} disabled={loading} onClick={() => changeClock("timer")}>Timer</button>
          </div>
        </div>
      </div>

      {chartMetrics.length ? <div className="fitness-module__metric-picker">
        <div className="fitness-module__metric-picker-heading"><div><strong>Choose charts</strong><span>Keep the view focused or show everything.</span></div><div className="fitness-module__button-row"><button type="button" className="button button--secondary button--compact" aria-pressed={visibleMetrics.length === coreMetrics.length && coreMetrics.every((metric) => visibleMetrics.includes(metric))} onClick={() => setVisibleMetrics(coreMetrics)}>Highlights</button><button type="button" className="button button--secondary button--compact" aria-pressed={visibleMetrics.length === chartMetrics.length} onClick={() => setVisibleMetrics(chartMetrics)}>All data</button></div></div>
        <div className="fitness-module__metric-chips" role="group" aria-label="Choose visible activity charts">
          {chartMetrics.map((metric) => <button type="button" className={visibleMetrics.includes(metric) ? "is-active" : undefined} aria-pressed={visibleMetrics.includes(metric)} onClick={() => toggleMetric(metric)} key={metric}>{labelForMetric(metric)}</button>)}
        </div>
      </div> : null}

      <div className="fitness-module__charts" aria-label="Activity charts">
        {displayedMetrics.map((metric) => {
          const values = stream.series[metric] ?? [];
          const extent = finiteExtent(values);
          if (!extent) return <div className="fitness-module__empty fitness-module__chart-empty" key={metric}><strong>No {labelForMetric(metric).toLocaleLowerCase()} here</strong><span>Choose a wider section or hide this chart.</span></div>;
          const canonicalAverage = canonicalChartAverage(detail, metric);
          const inverted = metric === "pace_s_per_km";
          const selectedValue = values[selectedIndex];
          const selectedY = selectedValue == null ? null : valueY(selectedValue, extent, 150, inverted);
          return <figure className="fitness-module__stream-chart" key={metric}>
            <figcaption><div><strong>{labelForMetric(metric)}</strong><span>{displayUnit(metric, stream.units[metric]) || "Value"}</span></div><div><strong>{formatMetric(selectedValue, metric, stream.units[metric])}</strong><span>At {effectiveAxis === "distance" && selectedDistance != null ? formatDistance(selectedDistance) : formatDuration(selectedOffset)}</span></div></figcaption>
            <svg
              viewBox="0 0 760 150"
              role="img"
              tabIndex={0}
              aria-label={`${labelForMetric(metric)} chart. Visible range ${formatMetric(extent.minimum, metric, stream.units[metric])} to ${formatMetric(extent.maximum, metric, stream.units[metric])}. Use left and right arrow keys to inspect samples.`}
              onPointerMove={(event) => { if (event.pointerType === "mouse" || event.buttons === 1) selectAt(event.clientX, event.currentTarget); }}
              onPointerDown={(event) => selectAt(event.clientX, event.currentTarget)}
              onKeyDown={(event) => {
                if (event.key === "ArrowLeft") { event.preventDefault(); moveSelection(-1); }
                if (event.key === "ArrowRight") { event.preventDefault(); moveSelection(1); }
                if (event.key === "Home") { event.preventDefault(); setSelectedIndex(0); }
                if (event.key === "End") { event.preventDefault(); setSelectedIndex(stream.offset_ms.length - 1); }
              }}
            >
              {[0.25, 0.5, 0.75].map((position) => <line className="is-grid" x1="0" x2="760" y1={position * 150} y2={position * 150} key={position} />)}
              {boundaries.map((interval) => {
                if (!xExtent) return null;
                const boundaryValue = effectiveAxis === "distance" ? interval.start_distance_m : interval.start_offset_ms;
                if (boundaryValue == null) return null;
                const x = ((boundaryValue - xExtent.minimum) / Math.max(xExtent.maximum - xExtent.minimum, 0.0001)) * 760;
                return x >= 0 && x <= 760 ? <line className="is-boundary" x1={x} x2={x} y1="0" y2="150" key={interval.id} /> : null;
              })}
              {canonicalAverage != null ? <line className="is-average" x1="0" x2="760" y1={valueY(canonicalAverage, extent, 150, inverted)} y2={valueY(canonicalAverage, extent, 150, inverted)} /> : null}
              <path className="is-series" d={linePath(values, chartXValues, 760, 150, inverted)} />
              <line className="is-crosshair" x1={crosshairX} x2={crosshairX} y1="0" y2="150" />
              {selectedY != null ? <circle className="is-selected-point" cx={crosshairX} cy={selectedY} r="5" /> : null}
            </svg>
            <div className="fitness-module__chart-axis" aria-hidden="true"><span>{effectiveAxis === "distance" ? formatDistance(xExtent?.minimum ?? 0) : formatDuration(xExtent?.minimum ?? 0)}</span><span>{canonicalAverage != null ? `Average ${formatMetric(canonicalAverage, metric, stream.units[metric])}` : ""}</span><span>{effectiveAxis === "distance" ? formatDistance(xExtent?.maximum ?? 0) : formatDuration(xExtent?.maximum ?? 0)}</span></div>
          </figure>;
        })}
      </div>

      <details className="fitness-module__details fitness-module__point-inspector-details">
        <summary>Selected point details · {formatDuration(selectedOffset)}</summary>
        {pointInspector}
      </details>

      {totalOffset > 0 ? <details className="fitness-module__details fitness-module__range-controls">
        <summary><TimerReset aria-hidden="true" size={18} /> Focus on a section</summary>
        <div><div><strong>Selected section</strong><span>{formatDuration(totalOffset * selection[0] / 100)} – {formatDuration(totalOffset * selection[1] / 100)}</span></div>{requestedRange ? <span className="fitness-module__pill is-neutral">Focused</span> : null}</div>
        <div className="fitness-module__range-quick" role="group" aria-label="Quick activity sections"><button type="button" onClick={() => setSelection([0, 100])}>Full activity</button><button type="button" onClick={() => setSelection([0, 50])}>First half</button><button type="button" onClick={() => setSelection([50, 100])}>Second half</button></div>
        <label><span>Start</span><input type="range" min="0" max="95" value={selection[0]} disabled={loading} onChange={(event) => setSelection(([, end]) => [Math.min(Number(event.target.value), end - 1), end])} /></label>
        <label><span>End</span><input type="range" min="5" max="100" value={selection[1]} disabled={loading} onChange={(event) => setSelection(([start]) => [start, Math.max(Number(event.target.value), start + 1)])} /></label>
        <div className="fitness-module__button-row"><button type="button" className="button button--primary" disabled={loading || (selection[0] === 0 && selection[1] === 100 && !requestedRange)} onClick={loadSelectedRange}>Show selected section</button>{requestedRange ? <button type="button" className="button button--secondary" disabled={loading} onClick={() => { setRequestedRange(null); setSelection([0, 100]); }}>Show full activity</button> : null}</div>
      </details> : null}
    </section>
  </div>;
}
