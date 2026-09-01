import { Camera, CheckCircle2, ChevronLeft, ChevronRight, Columns2, HeartPulse, Link, LoaderCircle, Maximize2, RefreshCw, Scale, Unlink, X, ZoomIn, ZoomOut } from "lucide-react";
import { type PointerEvent as ReactPointerEvent, type WheelEvent as ReactWheelEvent, useCallback, useEffect, useMemo, useRef, useState } from "react";

import { api } from "../../api";
import { cn } from "../../components/ui";
import {
  asFitnessArray,
  type FitnessProgressPhoto,
  type FitnessMeasurementHistory,
  type FitnessMeasurementHistoryPoint,
  type FitnessMeasurementHistorySeries,
  type FitnessMeasurementMetric,
  type FitnessWithingsConnectionStatus,
  type FitnessWithingsSyncResult,
} from "../../fitness/contract";
import {
  cacheFitnessProgressPhotos,
  fitnessProgressPhotosOnDevice,
  type FitnessPendingProgressPhoto,
} from "../../fitness/offlineStore";
import {
  FitnessProgressPhotoPreview,
  fitnessProgressPhotoPoseLabels,
  type FitnessProgressPhotoItem,
} from "./FitnessProgressPhotoPreview";
import { errorMessage, formatFitnessDate, formatFitnessDateTime } from "./shared";

type DisplayMode = "trend" | "raw";
type RangeKey = "7d" | "30d" | "90d" | "1y";
type VerticalScale = "tight" | "fit" | "wide";
type MeasurementGraphPresentation = "detail" | "overview";

const DAY_MS = 86_400_000;
const MIN_WINDOW_MS = 7 * DAY_MS;
const DEFAULT_CHART_WIDTH = 900;
const DEFAULT_CHART_HEIGHT = 470;
const ranges: Array<{ key: RangeKey; label: string; milliseconds: number | null }> = [
  { key: "7d", label: "7 Days", milliseconds: 7 * DAY_MS },
  { key: "30d", label: "30 Days", milliseconds: 30 * DAY_MS },
  { key: "90d", label: "90 Days", milliseconds: 90 * DAY_MS },
  { key: "1y", label: "365 Days", milliseconds: 365 * DAY_MS },
];
const overviewRanges: Array<{ key: RangeKey; label: string; milliseconds: number | null }> = [
  { key: "7d", label: "7 Days", milliseconds: 7 * DAY_MS },
  { key: "30d", label: "1 Month", milliseconds: 30 * DAY_MS },
  { key: "1y", label: "365 Days", milliseconds: 365 * DAY_MS },
];
const metrics: Array<{ key: FitnessMeasurementMetric; label: string; icon: typeof Scale }> = [
  { key: "weight", label: "Weight", icon: Scale },
  { key: "body_fat", label: "Body fat", icon: Scale },
  { key: "blood_pressure", label: "Blood pressure", icon: HeartPulse },
];

function chartPreferences(presentation: MeasurementGraphPresentation): {
  metric: FitnessMeasurementMetric;
  mode: DisplayMode;
  range: RangeKey;
  verticalScale: VerticalScale;
} {
  const query = new URLSearchParams(window.location.search);
  const isOverview = presentation === "overview";
  const availableRanges = isOverview ? overviewRanges : ranges;
  const metric = isOverview ? "weight" : query.get("fitness-chart-metric");
  const mode = query.get(isOverview ? "fitness-overview-weight-display" : "fitness-chart-display");
  const range = query.get(isOverview ? "fitness-overview-weight-range" : "fitness-chart-range");
  const verticalScale = query.get("fitness-chart-scale");
  return {
    metric: metrics.some((item) => item.key === metric) ? metric as FitnessMeasurementMetric : "weight",
    mode: mode === "raw" ? "raw" : "trend",
    range: availableRanges.some((item) => item.key === range) ? range as RangeKey : isOverview ? "30d" : "90d",
    verticalScale: verticalScale === "tight" || verticalScale === "wide" ? verticalScale : "fit",
  };
}

function replaceChartPreference(parameter: string, value: string, defaultValue: string) {
  const url = new URL(window.location.href);
  if (value === defaultValue) url.searchParams.delete(parameter);
  else url.searchParams.set(parameter, value);
  window.history.replaceState(window.history.state, "", url);
}

function clearChartPreference(parameter: string) {
  const url = new URL(window.location.href);
  url.searchParams.delete(parameter);
  window.history.replaceState(window.history.state, "", url);
}

function emptyHistory(metric: FitnessMeasurementMetric): FitnessMeasurementHistory {
  const title = metric === "weight" ? "Weight" : metric === "body_fat" ? "Body fat" : "Blood pressure";
  return { metric, title, unit: metric === "weight" ? "kg" : metric === "body_fat" ? "%" : "mmHg", smoothing_method: "time_weighted_exponential", smoothing_half_life_days: 7, series: [], sample_count: 0 };
}

function localDayKey(value: string | number): string | null {
  const date = new Date(value);
  if (!Number.isFinite(date.valueOf())) return null;
  return `${date.getFullYear()}-${String(date.getMonth() + 1).padStart(2, "0")}-${String(date.getDate()).padStart(2, "0")}`;
}

function mergedProgressPhotos(remote: FitnessProgressPhoto[], local: FitnessPendingProgressPhoto[], online: boolean): FitnessProgressPhotoItem[] {
  const byId = new Map<string, FitnessProgressPhotoItem>();
  remote.forEach((photo) => byId.set(photo.id, { photo, local: null }));
  local.forEach((record) => {
    if (!online || !record.metadataAcknowledged) byId.set(record.id, { photo: record.photo, local: record });
    else if (byId.has(record.id)) byId.set(record.id, { photo: byId.get(record.id)!.photo, local: record });
  });
  return [...byId.values()].sort((left, right) => left.photo.captured_at.localeCompare(right.photo.captured_at));
}

function useGraphProgressPhotos(online: boolean, revision: number, enabled: boolean) {
  const [items, setItems] = useState<FitnessProgressPhotoItem[]>([]);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [reload, setReload] = useState(0);

  useEffect(() => {
    if (!enabled) return undefined;
    let cancelled = false;
    setLoading(true);
    setError(null);
    void (async () => {
      const local = await fitnessProgressPhotosOnDevice().catch(() => []);
      if (!cancelled) setItems(mergedProgressPhotos([], local, false));
      if (!online) return;
      try {
        const response = await api<FitnessProgressPhoto[] | { items?: FitnessProgressPhoto[] }>("/fitness/progress-photos", {}, true, false);
        const remote = asFitnessArray(response);
        await cacheFitnessProgressPhotos(remote).catch(() => undefined);
        const refreshedLocal = await fitnessProgressPhotosOnDevice().catch(() => local);
        if (!cancelled) setItems(mergedProgressPhotos(remote, refreshedLocal, true));
      } catch (requestError) {
        if (!cancelled && local.length === 0) setError(errorMessage(requestError));
      }
    })().finally(() => { if (!cancelled) setLoading(false); });
    return () => { cancelled = true; };
  }, [enabled, online, reload, revision]);

  useEffect(() => {
    if (!enabled) return undefined;
    const changed = () => setReload((value) => value + 1);
    window.addEventListener("hausklar:fitness-progress-photos-changed", changed);
    return () => window.removeEventListener("hausklar:fitness-progress-photos-changed", changed);
  }, [enabled]);

  return { items, loading, error, retry: () => setReload((value) => value + 1) };
}

function normaliseHistory(candidate: unknown, metric: FitnessMeasurementMetric): FitnessMeasurementHistory {
  const fallback = emptyHistory(metric);
  if (!candidate || typeof candidate !== "object" || Array.isArray(candidate)) return fallback;

  const partial = candidate as Partial<FitnessMeasurementHistory>;
  const series = Array.isArray(partial.series)
    ? partial.series.flatMap((item) => {
      if (!item || typeof item !== "object" || typeof item.key !== "string") return [];
      const points = Array.isArray(item.points)
        ? item.points.filter((point): point is FitnessMeasurementHistoryPoint => Boolean(point && typeof point === "object"))
        : [];
      return [{ ...item, points } as FitnessMeasurementHistorySeries];
    })
    : [];
  const pointCount = series.reduce((total, item) => total + item.points.length, 0);
  const suppliedCount = typeof partial.sample_count === "number" && Number.isFinite(partial.sample_count)
    ? Math.max(0, partial.sample_count)
    : pointCount;

  return {
    ...fallback,
    ...partial,
    metric,
    title: typeof partial.title === "string" && partial.title.trim() ? partial.title : fallback.title,
    unit: typeof partial.unit === "string" && partial.unit.trim() ? partial.unit : fallback.unit,
    smoothing_method: typeof partial.smoothing_method === "string" && partial.smoothing_method.trim()
      ? partial.smoothing_method
      : fallback.smoothing_method,
    smoothing_half_life_days: typeof partial.smoothing_half_life_days === "number" && Number.isFinite(partial.smoothing_half_life_days)
      ? partial.smoothing_half_life_days
      : fallback.smoothing_half_life_days,
    series,
    sample_count: series.length ? Math.max(pointCount, suppliedCount) : 0,
  };
}

function time(point: FitnessMeasurementHistoryPoint): number | null {
  const value = Date.parse(point.measured_at_utc);
  return Number.isFinite(value) ? value : null;
}

function historyExtent(history: FitnessMeasurementHistory): { minimum: number; maximum: number; allWindow: number } | null {
  const values = history.series.flatMap((series) => series.points.map(time).filter((value): value is number => value != null)).sort((left, right) => left - right);
  if (!values.length) return null;
  const minimum = values[0];
  const maximum = values[values.length - 1];
  return { minimum, maximum, allWindow: Math.max(MIN_WINDOW_MS, maximum - minimum + 2 * DAY_MS) };
}

function clampEnd(end: number, windowMs: number, extent: NonNullable<ReturnType<typeof historyExtent>>): number {
  if (windowMs >= extent.allWindow) return extent.maximum + DAY_MS;
  return Math.min(extent.maximum + DAY_MS, Math.max(extent.minimum + windowMs - DAY_MS, end));
}

function value(point: FitnessMeasurementHistoryPoint, mode: DisplayMode): number {
  return mode === "raw" ? point.raw_value : point.trend_value;
}

function formatValue(valueNumber: number, metric: FitnessMeasurementMetric): string {
  return valueNumber.toLocaleString(undefined, {
    minimumFractionDigits: metric === "blood_pressure" ? 0 : 1,
    maximumFractionDigits: metric === "blood_pressure" ? 0 : 1,
  });
}

function formatAxisDate(timestamp: number, windowMs: number): string {
  const includeDay = windowMs <= 90 * DAY_MS;
  const includeYear = windowMs > 300 * DAY_MS;
  return new Date(timestamp).toLocaleDateString(undefined, {
    day: includeDay ? "numeric" : undefined,
    month: "short",
    year: includeYear ? "2-digit" : undefined,
  });
}

function formatCrosshairDate(timestamp: number, compact: boolean): string {
  return new Date(timestamp).toLocaleDateString(undefined, compact
    ? { day: "numeric", month: "short" }
    : { day: "numeric", month: "short", year: "numeric" });
}

function seriesClass(key: string): string {
  if (key === "systolic") return "is-systolic";
  if (key === "diastolic") return "is-diastolic";
  if (key === "body_fat") return "is-body-fat";
  return "is-weight";
}

type PlotPoint = {
  source: FitnessMeasurementHistoryPoint;
  timestamp: number;
  value: number;
  x: number;
  y: number;
};

type PlotSeries = {
  source: FitnessMeasurementHistorySeries;
  points: PlotPoint[];
  path: string;
  smoothPath: string;
  directionBands: Array<{ path: string; direction: "falling" | "rising" }>;
};

type SvgPoint = { x: number; y: number };

type ActivePointer = { x: number; y: number };
type PinchState = {
  startDistance: number;
  startWindow: number;
  focusRatio: number;
  focusTime: number;
};

type ChartGeometry = {
  width: number;
  height: number;
  plotLeft: number;
  plotRight: number;
  plotTop: number;
  plotBottom: number;
};

function chartGeometry(width: number): ChartGeometry {
  const safeWidth = Math.max(280, width);
  const height = safeWidth < 480 ? 390 : safeWidth < 760 ? 430 : DEFAULT_CHART_HEIGHT;
  return {
    width: safeWidth,
    height,
    plotLeft: safeWidth < 480 ? 54 : 62,
    plotRight: safeWidth < 480 ? 10 : 16,
    plotTop: safeWidth < 480 ? 38 : 42,
    plotBottom: safeWidth < 480 ? 34 : 38,
  };
}

function pointerDistance(points: ActivePointer[]): number {
  if (points.length < 2) return 0;
  return Math.hypot(points[1].x - points[0].x, points[1].y - points[0].y);
}

function linearSvgPath(points: SvgPoint[]): string {
  return points.map((point, index) => `${index ? "L" : "M"}${point.x.toFixed(1)},${point.y.toFixed(1)}`).join(" ");
}

function smoothSvgPath(points: SvgPoint[]): string {
  if (points.length < 3) return linearSvgPath(points);
  const clamp = (numberValue: number, minimum: number, maximum: number) => Math.min(maximum, Math.max(minimum, numberValue));
  let path = `M${points[0].x.toFixed(1)},${points[0].y.toFixed(1)}`;
  for (let index = 0; index < points.length - 1; index += 1) {
    const first = points[Math.max(0, index - 1)];
    const start = points[index];
    const end = points[index + 1];
    const last = points[Math.min(points.length - 1, index + 2)];
    const minimumY = Math.min(start.y, end.y);
    const maximumY = Math.max(start.y, end.y);
    const minimumX = Math.min(start.x, end.x);
    const maximumX = Math.max(start.x, end.x);
    const controlOneX = clamp(start.x + (end.x - first.x) / 6, minimumX, maximumX);
    const controlTwoX = clamp(end.x - (last.x - start.x) / 6, minimumX, maximumX);
    const controlOneY = clamp(start.y + (end.y - first.y) / 6, minimumY, maximumY);
    const controlTwoY = clamp(end.y - (last.y - start.y) / 6, minimumY, maximumY);
    path += ` C${controlOneX.toFixed(1)},${controlOneY.toFixed(1)} ${controlTwoX.toFixed(1)},${controlTwoY.toFixed(1)} ${end.x.toFixed(1)},${end.y.toFixed(1)}`;
  }
  return path;
}

function directionBandPath(points: PlotPoint[], y: (value: number) => number, halfWidth: number): string {
  const upper = points.map((point) => ({ x: point.x, y: y(point.source.trend_value + halfWidth) }));
  const lower = [...points].reverse().map((point) => ({ x: point.x, y: y(point.source.trend_value - halfWidth) }));
  if (!upper.length) return "";
  return `${smoothSvgPath(upper)} ${smoothSvgPath(lower).replace(/^M/, "L")} Z`;
}

function weightDirectionBands(points: PlotPoint[], y: (value: number) => number, domainRange: number): PlotSeries["directionBands"] {
  if (points.length < 2) return [];
  const averageDeviation = points.reduce((total, point) => total + Math.abs(point.source.raw_value - point.source.trend_value), 0) / points.length;
  const halfWidth = Math.min(domainRange * 0.18, Math.max(domainRange * 0.08, averageDeviation * 1.15, 0.3));
  const directions = points.map((point, index): "falling" | "rising" => {
    const before = points[Math.max(0, index - 2)].source.trend_value;
    const after = points[Math.min(points.length - 1, index + 2)].source.trend_value;
    return after < before ? "falling" : "rising";
  });
  const segments: PlotSeries["directionBands"] = [];
  let segmentStart = 0;
  for (let index = 1; index <= points.length; index += 1) {
    if (index < points.length && directions[index] === directions[segmentStart]) continue;
    const from = Math.max(0, segmentStart - 1);
    const to = Math.min(points.length, index + 1);
    const segment = points.slice(from, to);
    if (segment.length > 1) segments.push({ path: directionBandPath(segment, y, halfWidth), direction: directions[segmentStart] });
    segmentStart = index;
  }
  return segments;
}

function calendarBands(start: number, end: number, x: (timestamp: number) => number) {
  const startDate = new Date(start);
  const firstMonday = Date.UTC(startDate.getUTCFullYear(), startDate.getUTCMonth(), startDate.getUTCDate());
  const mondayOffset = (new Date(firstMonday).getUTCDay() + 6) % 7;
  const firstWeek = firstMonday - mondayOffset * DAY_MS;
  const weeks = [];
  for (let weekStart = firstWeek, index = 0; weekStart < end; weekStart += 7 * DAY_MS, index += 1) {
    if (index % 2 === 0) {
      const visibleStart = Math.max(start, weekStart);
      const visibleEnd = Math.min(end, weekStart + 7 * DAY_MS);
      weeks.push({ x: x(visibleStart), width: Math.max(0, x(visibleEnd) - x(visibleStart)) });
    }
  }
  const months: Array<{ x: number; label: string }> = [];
  let monthStart = Date.UTC(startDate.getUTCFullYear(), startDate.getUTCMonth(), 1);
  while (monthStart < end) {
    const monthDate = new Date(monthStart);
    const nextMonth = Date.UTC(monthDate.getUTCFullYear(), monthDate.getUTCMonth() + 1, 1);
    const visibleStart = Math.max(start, monthStart);
    const visibleEnd = Math.min(end, nextMonth);
    if (x(visibleEnd) - x(visibleStart) >= 34) {
      const month = monthDate.toLocaleDateString(undefined, { month: "short", timeZone: "UTC" });
      const includeYear = monthDate.getUTCMonth() === 0 || months.length === 0;
      months.push({ x: (x(visibleStart) + x(visibleEnd)) / 2, label: includeYear ? `${month} ${monthDate.getUTCFullYear()}` : month });
    }
    monthStart = nextMonth;
  }
  return { weeks, months };
}

function chartModel(history: FitnessMeasurementHistory, mode: DisplayMode, verticalScale: VerticalScale, start: number, end: number, geometry: ChartGeometry) {
  const visible = history.series.map((series) => ({
    source: series,
    points: series.points.flatMap((point) => {
      const timestamp = time(point);
      const numberValue = value(point, mode);
      return timestamp != null && timestamp >= start && timestamp <= end && Number.isFinite(numberValue)
        ? [{ source: point, timestamp, value: numberValue }]
        : [];
    }),
  }));
  const values = visible.flatMap((series) => series.points.flatMap((point) =>
    mode === "trend" && history.metric === "weight"
      ? [point.value, point.source.raw_value]
      : [point.value],
  ));
  const low = values.length ? Math.min(...values) : 0;
  const high = values.length ? Math.max(...values) : 1;
  const scalePadding = verticalScale === "tight"
    ? { fraction: 0.05, minimum: history.metric === "blood_pressure" ? 2 : 0.25 }
    : verticalScale === "wide"
      ? { fraction: 0.35, minimum: history.metric === "blood_pressure" ? 10 : 2 }
      : { fraction: 0.12, minimum: history.metric === "blood_pressure" ? 5 : 1 };
  const padding = Math.max(scalePadding.minimum, (high - low) * scalePadding.fraction);
  const yMinimum = low - padding;
  const yMaximum = high + padding;
  const plotWidth = geometry.width - geometry.plotLeft - geometry.plotRight;
  const plotHeight = geometry.height - geometry.plotTop - geometry.plotBottom;
  const x = (timestamp: number) => geometry.plotLeft + ((timestamp - start) / Math.max(1, end - start)) * plotWidth;
  const y = (numberValue: number) => geometry.plotTop + (1 - (numberValue - yMinimum) / Math.max(1, yMaximum - yMinimum)) * plotHeight;
  const series: PlotSeries[] = visible.map((item) => {
    const points = item.points.map((point) => ({ ...point, x: x(point.timestamp), y: y(point.value) }));
    return {
      source: item.source,
      points,
      path: linearSvgPath(points),
      smoothPath: smoothSvgPath(points),
      directionBands: mode === "trend" && history.metric === "weight"
        ? weightDirectionBands(points, y, yMaximum - yMinimum)
        : [],
    };
  });
  const grid = Array.from({ length: 5 }, (_, index) => {
    const fraction = index / 4;
    return { y: geometry.plotTop + fraction * plotHeight, label: yMaximum - fraction * (yMaximum - yMinimum) };
  });
  const timeGridCount = geometry.width < 480 ? 3 : geometry.width < 760 ? 4 : 6;
  const timeGrid = Array.from({ length: timeGridCount }, (_, index) => {
    const ratio = index / Math.max(1, timeGridCount - 1);
    const timestamp = start + ratio * (end - start);
    return { x: x(timestamp), timestamp };
  });
  const calendar = calendarBands(start, end, x);
  return { series, grid, timeGrid, calendar, x, y, hasValues: values.length > 0, yMinimum, yMaximum };
}

export function FitnessMeasurementTrends({
  online,
  revision,
  onDataChanged,
  presentation = "detail",
  historyOverride,
  onOpen,
}: {
  online: boolean;
  revision: number;
  onDataChanged: () => void;
  presentation?: MeasurementGraphPresentation;
  historyOverride?: FitnessMeasurementHistory;
  onOpen?: () => void;
}) {
  const isOverview = presentation === "overview";
  const activeRanges = isOverview ? overviewRanges : ranges;
  const rangePreference = isOverview ? "fitness-overview-weight-range" : "fitness-chart-range";
  const modePreference = isOverview ? "fitness-overview-weight-display" : "fitness-chart-display";
  const defaultRange: RangeKey = isOverview ? "30d" : "90d";
  const initialPreferences = useRef(chartPreferences(presentation)).current;
  const [metric, setMetric] = useState<FitnessMeasurementMetric>(initialPreferences.metric);
  const [mode, setMode] = useState<DisplayMode>(initialPreferences.mode);
  const [verticalScale, setVerticalScale] = useState<VerticalScale>(initialPreferences.verticalScale);
  const [history, setHistory] = useState<FitnessMeasurementHistory>(() => historyOverride
    ? normaliseHistory(historyOverride, "weight")
    : emptyHistory(initialPreferences.metric));
  const [status, setStatus] = useState<FitnessWithingsConnectionStatus | null>(null);
  const [loading, setLoading] = useState(true);
  const [busy, setBusy] = useState<"connect" | "sync" | "disconnect" | null>(null);
  const [confirmingDisconnect, setConfirmingDisconnect] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [notice, setNotice] = useState<string | null>(() => {
    const outcome = new URLSearchParams(window.location.search).get("withings");
    return outcome === "connected" ? "Withings connected. Measurement history is updating." : outcome === "cancelled" ? "Withings connection cancelled." : outcome === "failed" ? "Withings could not complete the connection." : null;
  });
  const [selectedRange, setSelectedRange] = useState<RangeKey | null>(initialPreferences.range);
  const [windowMs, setWindowMs] = useState(() => activeRanges.find((item) => item.key === initialPreferences.range)?.milliseconds ?? (isOverview ? 30 : 90) * DAY_MS);
  const [viewEnd, setViewEnd] = useState(Date.now());
  const [selectedTime, setSelectedTime] = useState<number | null>(null);
  const [activePhotoId, setActivePhotoId] = useState<string | null>(null);
  const [comparisonPhotoId, setComparisonPhotoId] = useState<string | null>(null);
  const [chartWidth, setChartWidth] = useState(DEFAULT_CHART_WIDTH);
  const [interacting, setInteracting] = useState(false);
  const chartHost = useRef<HTMLDivElement | null>(null);
  const selectedComparisonButton = useRef<HTMLButtonElement | null>(null);
  const userMovedViewport = useRef(false);
  const selectedRangeRef = useRef<RangeKey | null>(initialPreferences.range);
  const drag = useRef<{ pointerId: number; startX: number; startEnd: number; moved: boolean } | null>(null);
  const activePointers = useRef(new Map<number, ActivePointer>());
  const pinch = useRef<PinchState | null>(null);
  const lastTouchTap = useRef(0);
  const graphPhotos = useGraphProgressPhotos(online, revision, selectedTime != null);

  const load = useCallback(async (quiet = false) => {
    if (historyOverride) {
      const usableHistory = normaliseHistory(historyOverride, "weight");
      setHistory(usableHistory);
      setMetric("weight");
      setLoading(false);
      setError(null);
      const overrideExtent = historyExtent(usableHistory);
      if (overrideExtent) {
        const selectedKey = selectedRangeRef.current ?? defaultRange;
        const preset = activeRanges.find((item) => item.key === selectedKey) ?? activeRanges.find((item) => item.key === defaultRange)!;
        const nextWindow = Math.min(overrideExtent.allWindow, Math.max(MIN_WINDOW_MS, preset.milliseconds ?? overrideExtent.allWindow));
        setWindowMs(nextWindow);
        setViewEnd(overrideExtent.maximum + DAY_MS);
      }
      return;
    }
    if (!online) { setLoading(false); return; }
    if (!quiet) setLoading(true);
    setError(null);
    try {
      const [nextHistory, nextStatus] = isOverview
        ? [await api<FitnessMeasurementHistory>(`/fitness/measurements/history?metric=weight`, {}, true, false), null]
        : await Promise.all([
          api<FitnessMeasurementHistory>(`/fitness/measurements/history?metric=${metric}`, {}, true, false),
          api<FitnessWithingsConnectionStatus>("/fitness/integrations/withings/status", {}, true, false),
        ]);
      const usableHistory = normaliseHistory(nextHistory, metric);
      setHistory(usableHistory);
      if (nextStatus) setStatus(nextStatus);
      const extent = historyExtent(usableHistory);
      if (extent) {
        setWindowMs((currentWindow) => {
          const selectedKey = selectedRangeRef.current;
          const preset = selectedKey == null ? null : activeRanges.find((item) => item.key === selectedKey);
          const nextWindow = selectedKey == null
            ? Math.min(extent.allWindow, Math.max(MIN_WINDOW_MS, currentWindow))
            : preset?.milliseconds == null
              ? extent.allWindow
              : Math.min(extent.allWindow, Math.max(MIN_WINDOW_MS, preset.milliseconds));
          setViewEnd((current) => userMovedViewport.current ? clampEnd(current, nextWindow, extent) : extent.maximum + DAY_MS);
          return nextWindow;
        });
      }
    } catch (requestError) {
      setError(errorMessage(requestError));
    } finally {
      setLoading(false);
    }
  }, [activeRanges, defaultRange, historyOverride, isOverview, metric, online]);

  useEffect(() => {
    userMovedViewport.current = false;
    setSelectedTime(null);
  }, [metric]);

  useEffect(() => {
    setActivePhotoId(null);
    setComparisonPhotoId(null);
  }, [selectedTime]);

  useEffect(() => {
    selectedComparisonButton.current?.scrollIntoView({ block: "nearest", inline: "center" });
  }, [comparisonPhotoId]);

  useEffect(() => {
    void load();
    if (!online || historyOverride) return undefined;
    const interval = window.setInterval(() => void load(true), 60_000);
    return () => window.clearInterval(interval);
  }, [historyOverride, load, online, revision]);

  useEffect(() => {
    const url = new URL(window.location.href);
    if (!url.searchParams.has("withings")) return;
    url.searchParams.delete("withings");
    window.history.replaceState(window.history.state, "", url);
  }, []);

  useEffect(() => {
    const host = chartHost.current;
    if (!host) return undefined;
    const updateSize = () => {
      const nextWidth = Math.round(host.getBoundingClientRect().width);
      if (nextWidth > 0) setChartWidth((current) => current === nextWidth ? current : nextWidth);
    };
    updateSize();
    if (typeof ResizeObserver === "undefined") return undefined;
    const observer = new ResizeObserver(updateSize);
    observer.observe(host);
    return () => observer.disconnect();
  }, [history.sample_count]);

  const extent = useMemo(() => historyExtent(history), [history]);
  const end = extent ? clampEnd(viewEnd, windowMs, extent) : viewEnd;
  const start = end - windowMs;
  const geometry = useMemo(() => chartGeometry(chartWidth), [chartWidth]);
  const plot = useMemo(() => chartModel(history, mode, verticalScale, start, end, geometry), [end, geometry, history, mode, start, verticalScale]);

  async function connect() {
    setBusy("connect"); setError(null); setNotice(null);
    try {
      const response = await api<{ authorization_url: string }>("/fitness/integrations/withings/start", { method: "POST", body: JSON.stringify({ return_surface: "web" }) }, true, false);
      window.location.assign(response.authorization_url);
    } catch (requestError) {
      setError(errorMessage(requestError)); setBusy(null);
    }
  }

  async function syncNow() {
    setBusy("sync"); setError(null); setNotice(null);
    try {
      const result = await api<FitnessWithingsSyncResult>("/fitness/integrations/withings/sync", { method: "POST" }, true, false);
      const changed = result.imported + result.updated;
      setNotice(changed ? `Updated ${changed} measurement${changed === 1 ? "" : "s"} from Withings.` : "Withings is up to date.");
      userMovedViewport.current = false;
      await load(true);
      onDataChanged();
    } catch (requestError) {
      setError(errorMessage(requestError));
    } finally { setBusy(null); }
  }

  async function disconnect() {
    setBusy("disconnect"); setError(null);
    try {
      const result = await api<{ retained_measurement_count: number }>("/fitness/integrations/withings", { method: "DELETE" }, true, false);
      setNotice(`Withings disconnected. ${result.retained_measurement_count} imported measurement${result.retained_measurement_count === 1 ? "" : "s"} kept.`);
      setConfirmingDisconnect(false);
      await load(true);
    } catch (requestError) {
      setError(errorMessage(requestError));
    } finally { setBusy(null); }
  }

  function applyRange(key: RangeKey) {
    if (!extent) return;
    const range = activeRanges.find((item) => item.key === key);
    if (!range) return;
    const nextWindow = range.milliseconds == null ? extent.allWindow : Math.min(extent.allWindow, Math.max(MIN_WINDOW_MS, range.milliseconds));
    userMovedViewport.current = true;
    selectedRangeRef.current = key;
    setSelectedRange(key); setWindowMs(nextWindow); setViewEnd(extent.maximum + DAY_MS); setSelectedTime(null);
    replaceChartPreference(rangePreference, key, defaultRange);
  }

  function chooseMetric(nextMetric: FitnessMeasurementMetric) {
    setMetric(nextMetric);
    setHistory(emptyHistory(nextMetric));
    setLoading(true);
    setSelectedTime(null);
    replaceChartPreference("fitness-chart-metric", nextMetric, "weight");
  }

  function chooseMode(nextMode: DisplayMode) {
    setMode(nextMode);
    setSelectedTime(null);
    replaceChartPreference(modePreference, nextMode, "trend");
  }

  function chooseVerticalScale(nextScale: VerticalScale) {
    setVerticalScale(nextScale);
    setSelectedTime(null);
    replaceChartPreference("fitness-chart-scale", nextScale, "fit");
  }

  function pointRatio(clientX: number, target: SVGSVGElement): number {
    const bounds = target.getBoundingClientRect();
    const svgX = ((clientX - bounds.left) / Math.max(1, bounds.width)) * geometry.width;
    const plotWidth = geometry.width - geometry.plotLeft - geometry.plotRight;
    return Math.max(0, Math.min(1, (svgX - geometry.plotLeft) / Math.max(1, plotWidth)));
  }

  function selectAt(clientX: number, target: SVGSVGElement) {
    const targetTime = start + pointRatio(clientX, target) * windowMs;
    const visibleTimes = plot.series.flatMap((series) => series.points.map((point) => point.timestamp));
    if (!visibleTimes.length) { setSelectedTime(null); return; }
    const nearest = visibleTimes.reduce((closest, candidate) =>
      Math.abs(candidate - targetTime) < Math.abs(closest - targetTime) ? candidate : closest,
    );
    setSelectedTime(nearest);
  }

  function zoomAround(nextWindowValue: number, ratio: number, focusTime = start + ratio * windowMs) {
    if (!extent) return;
    const nextWindow = Math.min(extent.allWindow, Math.max(MIN_WINDOW_MS, nextWindowValue));
    const nextStart = focusTime - ratio * nextWindow;
    userMovedViewport.current = true;
    if (selectedRangeRef.current !== null) clearChartPreference(rangePreference);
    selectedRangeRef.current = null;
    setSelectedRange(null);
    setSelectedTime(null);
    setWindowMs(nextWindow);
    setViewEnd(clampEnd(nextStart + nextWindow, nextWindow, extent));
  }

  function zoomBy(factor: number) {
    zoomAround(windowMs * factor, 0.5);
  }

  function resetViewport() {
    if (!extent) return;
    const key = selectedRange ?? defaultRange;
    const range = activeRanges.find((item) => item.key === key) ?? activeRanges.find((item) => item.key === defaultRange)!;
    const nextWindow = range.milliseconds == null ? extent.allWindow : Math.min(extent.allWindow, Math.max(MIN_WINDOW_MS, range.milliseconds));
    userMovedViewport.current = false;
    selectedRangeRef.current = key;
    setSelectedRange(key);
    setWindowMs(nextWindow);
    setViewEnd(extent.maximum + DAY_MS);
    setSelectedTime(null);
    replaceChartPreference(rangePreference, key, defaultRange);
  }

  function pointerDown(event: ReactPointerEvent<SVGSVGElement>) {
    event.currentTarget.setPointerCapture(event.pointerId);
    setInteracting(true);
    activePointers.current.set(event.pointerId, { x: event.clientX, y: event.clientY });
    if (activePointers.current.size === 1) {
      drag.current = { pointerId: event.pointerId, startX: event.clientX, startEnd: end, moved: false };
      pinch.current = null;
      return;
    }
    if (activePointers.current.size === 2) {
      event.preventDefault();
      const points = Array.from(activePointers.current.values());
      const midpointX = (points[0].x + points[1].x) / 2;
      const ratio = pointRatio(midpointX, event.currentTarget);
      pinch.current = {
        startDistance: Math.max(1, pointerDistance(points)),
        startWindow: windowMs,
        focusRatio: ratio,
        focusTime: start + ratio * windowMs,
      };
      drag.current = null;
    }
  }

  function pointerMove(event: ReactPointerEvent<SVGSVGElement>) {
    if (!activePointers.current.has(event.pointerId)) return;
    activePointers.current.set(event.pointerId, { x: event.clientX, y: event.clientY });
    if (pinch.current && activePointers.current.size >= 2) {
      event.preventDefault();
      const points = Array.from(activePointers.current.values()).slice(0, 2);
      const distance = Math.max(1, pointerDistance(points));
      zoomAround(
        pinch.current.startWindow * (pinch.current.startDistance / distance),
        pinch.current.focusRatio,
        pinch.current.focusTime,
      );
      return;
    }
    if (!drag.current || drag.current.pointerId !== event.pointerId) {
      return;
    }
    const bounds = event.currentTarget.getBoundingClientRect();
    const delta = event.clientX - drag.current.startX;
    if (Math.abs(delta) > 4) drag.current.moved = true;
    if (!extent) return;
    userMovedViewport.current = true;
    if (selectedRangeRef.current !== null) clearChartPreference(rangePreference);
    selectedRangeRef.current = null;
    setSelectedRange(null);
    const plotWidth = bounds.width * ((geometry.width - geometry.plotLeft - geometry.plotRight) / geometry.width);
    setViewEnd(clampEnd(drag.current.startEnd - (delta / Math.max(1, plotWidth)) * windowMs, windowMs, extent));
  }

  function finishPointer(event: ReactPointerEvent<SVGSVGElement>, cancelled = false) {
    const wasPinching = pinch.current != null;
    activePointers.current.delete(event.pointerId);
    if (!wasPinching && !cancelled && drag.current && !drag.current.moved) {
      const now = performance.now();
      if (event.pointerType === "touch" && now - lastTouchTap.current < 320) {
        resetViewport();
        lastTouchTap.current = 0;
      } else {
        selectAt(event.clientX, event.currentTarget);
        if (event.pointerType === "touch") lastTouchTap.current = now;
      }
    }
    drag.current = null;
    if (activePointers.current.size < 2) pinch.current = null;
    if (activePointers.current.size === 0) setInteracting(false);
    if (event.currentTarget.hasPointerCapture(event.pointerId)) {
      event.currentTarget.releasePointerCapture(event.pointerId);
    }
  }

  function wheel(event: ReactWheelEvent<SVGSVGElement>) {
    if (!extent) return;
    event.preventDefault();
    const ratio = pointRatio(event.clientX, event.currentTarget);
    const focus = start + ratio * windowMs;
    zoomAround(windowMs * Math.exp(event.deltaY * 0.002), ratio, focus);
  }

  const selected = selectedTime == null ? [] : history.series.flatMap((series) => {
    const point = series.points.filter((candidate) => {
      const candidateTime = time(candidate);
      return candidateTime != null && candidateTime >= start && candidateTime <= end;
    }).reduce<FitnessMeasurementHistoryPoint | null>((closest, candidate) => {
      const candidateTime = time(candidate); const closestTime = closest ? time(closest) : null;
      if (candidateTime == null) return closest;
      return closestTime == null || Math.abs(candidateTime - selectedTime) < Math.abs(closestTime - selectedTime) ? candidate : closest;
    }, null);
    return point ? [{ series, point }] : [];
  });
  const selectedRuleX = selectedTime == null ? null : plot.x(selectedTime);
  const visibleSummaries = history.series.map((series) => {
    const points = series.points.filter((point) => { const timestamp = time(point); return timestamp != null && timestamp >= start && timestamp <= end; });
    const first = points[0]; const latest = points[points.length - 1];
    return { series, latest, change: first && latest && first.id !== latest.id ? value(latest, mode) - value(first, mode) : null };
  });
  const visiblePointCount = Math.max(0, ...plot.series.map((series) => series.points.length));
  const smoothedWeight = mode === "trend" && metric === "weight";
  const markerRadius = visiblePointCount > 420 ? 1.9 : visiblePointCount > 180 ? 2.6 : visiblePointCount > 80 ? 3.6 : 5;
  const deviationWidth = visiblePointCount > 420 ? 1.2 : visiblePointCount > 180 ? 1.8 : 3.2;
  const activeReadings = selectedTime == null
    ? visibleSummaries.flatMap(({ series, latest }) => latest ? [{ series, point: latest }] : [])
    : selected;
  const activeDate = selectedTime ?? (activeReadings[0] ? time(activeReadings[0].point) : null);
  const primaryReading = activeReadings[0] ?? null;
  const primaryValue = primaryReading
    ? mode === "trend" && metric === "weight" ? primaryReading.point.raw_value : value(primaryReading.point, mode)
    : null;
  const selectedDay = selectedTime == null || !primaryReading ? null : localDayKey(primaryReading.point.measured_at_utc);
  const photosOnSelectedDay = selectedDay == null ? [] : graphPhotos.items.filter((item) => localDayKey(item.photo.captured_at) === selectedDay);
  const activePhoto = photosOnSelectedDay.find((item) => item.photo.id === activePhotoId) ?? photosOnSelectedDay[0] ?? null;
  const comparisonCandidates = activePhoto == null ? [] : graphPhotos.items
    .filter((item) => localDayKey(item.photo.captured_at) !== selectedDay)
    .sort((left, right) => left.photo.captured_at.localeCompare(right.photo.captured_at));
  const recommendedComparisonPhoto = activePhoto == null ? null : [...comparisonCandidates]
    .sort((left, right) => {
      const poseDifference = Number(left.photo.pose !== activePhoto.photo.pose) - Number(right.photo.pose !== activePhoto.photo.pose);
      if (poseDifference !== 0) return poseDifference;
      return Math.abs(Date.parse(left.photo.captured_at) - selectedTime!) - Math.abs(Date.parse(right.photo.captured_at) - selectedTime!);
    })[0] ?? null;
  const comparisonPhoto = comparisonCandidates.find((item) => item.photo.id === comparisonPhotoId) ?? null;
  const comparisonIndex = comparisonPhoto == null ? -1 : comparisonCandidates.findIndex((item) => item.photo.id === comparisonPhoto.photo.id);
  const comparisonPair = activePhoto && comparisonPhoto
    ? [activePhoto, comparisonPhoto].sort((left, right) => left.photo.captured_at.localeCompare(right.photo.captured_at))
    : [];

  function moveComparisonPhoto(offset: number) {
    const next = comparisonCandidates[comparisonIndex + offset];
    if (next) setComparisonPhotoId(next.photo.id);
  }
  const crosshairY = selectedTime != null && primaryValue != null ? plot.y(primaryValue) : null;
  const valueBadgeWidth = metric === "blood_pressure" ? 46 : 52;
  const valueBadgeX = geometry.width - valueBadgeWidth - 6;
  const dateBadgeWidth = geometry.width < 480 ? 76 : 94;
  const dateBadgeX = selectedRuleX == null
    ? 0
    : Math.max(geometry.plotLeft, Math.min(geometry.width - geometry.plotRight - dateBadgeWidth, selectedRuleX - dateBadgeWidth / 2));

  const statusText = !status ? "Loading measurements…" : !status.configured ? "Recorded measurements" : status.connected ? status.webhook_status === "active" ? "Withings connected · automatic updates" : "Withings connected · scheduled updates" : status.status === "reauth_required" ? "Reconnect Withings" : status.status === "provider_down" ? "Withings is temporarily unavailable" : "Connect Withings for automatic updates";
  const titleId = isOverview ? "fitness-overview-weight-title" : "fitness-measurements-title";
  const helpId = isOverview ? "fitness-overview-weight-help" : "fitness-measurements-help";

  return <article className={cn("fitness-measurements", isOverview && "fitness-measurements--overview")} aria-labelledby={titleId}>
    <header className="fitness-measurements__source">
      <div className="fitness-measurements__source-identity">
        <span className={cn("fitness-measurements__source-icon", !isOverview && status?.connected && "is-connected")}>{isOverview ? <Scale aria-hidden="true" size={22} /> : <HeartPulse aria-hidden="true" size={22} />}</span>
        <div><h3 id={titleId}>{isOverview ? "Weight progress" : "Detailed measurement graph"}</h3><p>{isOverview ? "Actual weigh-ins and the clearer smoothed trend." : statusText}</p></div>
      </div>
      <div className="fitness-measurements__source-actions">
        {isOverview && onOpen ? <button type="button" className="button button--secondary button--compact" aria-label="View weight progress" onClick={onOpen}>View all</button> : status?.connected ? <><button type="button" className="button button--primary" disabled={!online || busy != null} onClick={() => void syncNow()}>{busy === "sync" ? <LoaderCircle className="is-spinning" size={16} /> : <RefreshCw size={16} />} Sync now</button><button type="button" className="button button--secondary" disabled={!online || busy != null} onClick={() => setConfirmingDisconnect(true)}><Unlink size={16} /> Disconnect</button></> : status?.configured ? <button type="button" className="button button--primary" disabled={!online || busy != null} onClick={() => void connect()}>{busy === "connect" ? <LoaderCircle className="is-spinning" size={16} /> : <Link size={16} />} Connect</button> : null}
      </div>
    </header>
    {!isOverview && confirmingDisconnect ? <div className="fitness-module__notice fitness-module__notice--error" role="alert"><span><strong>Stop automatic Withings updates?</strong> Imported history will be kept.</span><div className="fitness-module__button-row"><button type="button" className="button button--danger button--compact" disabled={busy != null} onClick={() => void disconnect()}>{busy === "disconnect" ? "Disconnecting…" : "Disconnect"}</button><button type="button" className="button button--secondary button--compact" disabled={busy != null} onClick={() => setConfirmingDisconnect(false)}>Cancel</button></div></div> : null}
    {!isOverview && notice ? <div className="fitness-module__notice fitness-module__notice--success" role="status"><CheckCircle2 size={17} aria-hidden="true" /><span>{notice}</span></div> : null}
    {error ? <div className="fitness-module__notice fitness-module__notice--error" role="alert"><span>{error}</span><button className="button button--secondary button--compact" type="button" onClick={() => void load()}>Try again</button></div> : null}

    <div className="fitness-measurements__toolbar" aria-label="Measurement graph controls">
      {!isOverview ? <fieldset className="fitness-measurements__control-group fitness-measurements__metrics">
        <legend>Measure</legend>
        <div>
          {metrics.map((item) => { const Icon = item.icon; return <label key={item.key}><input type="radio" name="fitness-chart-metric" value={item.key} checked={metric === item.key} onChange={() => chooseMetric(item.key)} /><span><Icon size={16} aria-hidden="true" /> {item.label}</span></label>; })}
        </div>
      </fieldset> : null}
      <fieldset className="fitness-measurements__control-group fitness-measurements__mode">
        <legend>Display</legend>
        <div>
          {(["trend", "raw"] as DisplayMode[]).map((item) => <label key={item}><input type="radio" name={isOverview ? "fitness-overview-weight-display" : "fitness-chart-display"} value={item} checked={mode === item} onChange={() => chooseMode(item)} /><span>{item === "trend" ? "Smoothed" : "Raw"}</span></label>)}
        </div>
      </fieldset>
      {!isOverview ? <fieldset className="fitness-measurements__control-group fitness-measurements__scale">
        <legend>Vertical scale</legend>
        <div>
          {(["tight", "fit", "wide"] as VerticalScale[]).map((item) => <label key={item}><input type="radio" name="fitness-chart-scale" value={item} checked={verticalScale === item} onChange={() => chooseVerticalScale(item)} /><span>{item === "tight" ? "Tight" : item === "wide" ? "Wide" : "Fit"}</span></label>)}
        </div>
      </fieldset> : null}
      <fieldset className="fitness-measurements__control-group fitness-measurements__ranges">
        <legend>Time range</legend>
        <div>
          {activeRanges.map((range) => <label key={range.key}><input type="radio" name={isOverview ? "fitness-overview-weight-range" : "fitness-chart-range"} value={range.key} checked={selectedRange === range.key} disabled={!extent} onChange={() => applyRange(range.key)} /><span>{range.label}</span></label>)}
        </div>
      </fieldset>
    </div>

    {loading && history.sample_count === 0 ? <div className="fitness-measurements__loading" aria-label="Loading measurements"><span /><span /><span /></div> : history.sample_count === 0 ? <div className="fitness-module__empty"><Scale size={25} aria-hidden="true" /><strong>No {history.title.toLocaleLowerCase()} readings yet</strong><span>{isOverview ? "Add a weight reading to start your graph." : "Connect Withings or record a measurement. New readings will update automatically."}</span></div> : <>
      <figure className="fitness-measurements__chart">
        <figcaption>
          <div className="fitness-measurements__quote">
            <span className="fitness-measurements__quote-date">{activeDate == null ? history.title : selectedTime == null ? `Latest · ${formatCrosshairDate(activeDate, false)}` : formatCrosshairDate(activeDate, false)}</span>
            <div className="fitness-measurements__readouts">
              {activeReadings.map(({ series, point }) => <div key={series.key} className={cn("fitness-measurements__readout", seriesClass(series.key))}>
                {history.series.length > 1 ? <span className="fitness-measurements__readout-label"><i />{series.label}</span> : null}
                <strong>{formatValue(mode === "trend" && metric === "weight" ? point.raw_value : value(point, mode), metric)} <small>{series.unit}</small></strong>
                {smoothedWeight ? <span>Smoothed {formatValue(point.trend_value, metric)} {series.unit}</span> : null}
              </div>)}
            </div>
            <span className="fitness-measurements__quote-meta">{visiblePointCount.toLocaleString()} in view · {history.sample_count.toLocaleString()} total</span>
          </div>
        </figcaption>
        {!isOverview ? <div className="fitness-measurements__chart-navigation" aria-label="Chart zoom controls">
          <button type="button" disabled={!extent || windowMs >= extent.allWindow} onClick={() => zoomBy(1.8)}><ZoomOut aria-hidden="true" size={17} /> Zoom out</button>
          <button type="button" disabled={!extent || windowMs <= MIN_WINDOW_MS} onClick={() => zoomBy(0.55)}><ZoomIn aria-hidden="true" size={17} /> Zoom in</button>
          <button type="button" disabled={!extent} onClick={resetViewport}><Maximize2 aria-hidden="true" size={17} /> Reset</button>
        </div> : null}
        {smoothedWeight ? <div className="fitness-measurements__key" aria-label="Chart key"><span><i className="is-trend-key" />Smoothed</span><span><i className="is-falling-band" />Falling</span><span><i className="is-rising-band" />Rising</span></div> : null}
        <div ref={chartHost} className="fitness-measurements__chart-stage">
          <svg className={cn(interacting && "is-interacting")} viewBox={`0 0 ${geometry.width} ${geometry.height}`} role="img" tabIndex={0} aria-describedby={helpId} aria-label={`${history.title} ${mode === "trend" ? "smoothed" : "raw"} chart with ${history.sample_count} readings${isOverview ? ". Drag to see earlier dates and select a reading." : ` and ${verticalScale} vertical scale. Drag to pan, pinch or scroll to zoom, and double tap to reset.`}`} onPointerDown={pointerDown} onPointerMove={pointerMove} onPointerUp={(event) => finishPointer(event)} onPointerCancel={(event) => finishPointer(event, true)} onDoubleClick={resetViewport} onWheel={wheel} onKeyDown={(event) => { if (!extent) return; if (event.key === "ArrowLeft" || event.key === "ArrowRight") { event.preventDefault(); userMovedViewport.current = true; if (selectedRangeRef.current !== null) clearChartPreference(rangePreference); selectedRangeRef.current = null; setSelectedRange(null); setViewEnd(clampEnd(end + (event.key === "ArrowLeft" ? -1 : 1) * windowMs * 0.2, windowMs, extent)); } else if (event.key === "+" || event.key === "=") { event.preventDefault(); zoomBy(0.55); } else if (event.key === "-") { event.preventDefault(); zoomBy(1.8); } else if (event.key === "Home" || event.key === "0") { event.preventDefault(); resetViewport(); } else if (event.key === "Escape") { setSelectedTime(null); } }}>
            <defs>
              <linearGradient id="fitness-measurements-area" x1="0" x2="0" y1="0" y2="1">
                <stop offset="0%" stopColor="var(--primary)" stopOpacity="0.26" />
                <stop offset="58%" stopColor="var(--primary)" stopOpacity="0.08" />
                <stop offset="100%" stopColor="var(--primary)" stopOpacity="0" />
              </linearGradient>
              <clipPath id="fitness-measurements-plot-clip"><rect x={geometry.plotLeft} y={geometry.plotTop} width={geometry.width - geometry.plotLeft - geometry.plotRight} height={geometry.height - geometry.plotTop - geometry.plotBottom} /></clipPath>
            </defs>
            <g clipPath="url(#fitness-measurements-plot-clip)">{smoothedWeight ? plot.calendar.weeks.map((band, index) => <rect className="is-calendar-band" key={`${band.x}-${index}`} x={band.x} y={geometry.plotTop} width={band.width} height={geometry.height - geometry.plotTop - geometry.plotBottom} />) : null}</g>
            {smoothedWeight ? plot.calendar.months.map((month) => <text className="is-month-label" key={`${month.x}-${month.label}`} x={month.x} y={24} textAnchor="middle">{month.label}</text>) : null}
            {plot.timeGrid.map((tick) => <g key={tick.timestamp}><line className="is-grid is-grid-vertical" x1={tick.x} x2={tick.x} y1={geometry.plotTop} y2={geometry.height - geometry.plotBottom} />{smoothedWeight ? null : <text className="is-time-label" x={tick.x} y={geometry.height - 7} textAnchor={tick.x === geometry.plotLeft ? "start" : tick.x >= geometry.width - geometry.plotRight - 1 ? "end" : "middle"}>{formatAxisDate(tick.timestamp, windowMs)}</text>}</g>)}
            {plot.grid.map((line) => <g key={line.y}><line className="is-grid" x1={geometry.plotLeft} x2={geometry.width - geometry.plotRight} y1={line.y} y2={line.y} /><text x={geometry.plotLeft - 8} y={line.y + 4} textAnchor="end">{formatValue(line.label, metric)}</text></g>)}
            <g clipPath="url(#fitness-measurements-plot-clip)">{plot.series.map((series) => {
              const trendStyle = mode === "trend";
              const displayPath = trendStyle ? series.smoothPath : series.path;
              const areaStyle = trendStyle && !smoothedWeight && history.series.length === 1 && series.points.length > 1;
              return <g key={series.source.key} className={seriesClass(series.source.key)}>
                {smoothedWeight ? series.directionBands.map((band, index) => <path className={cn("is-direction-band", band.direction === "falling" ? "is-falling-band" : "is-rising-band")} d={band.path} key={`${band.direction}-${index}`} />) : null}
                {areaStyle ? <path className="is-area" d={`${displayPath} L${series.points[series.points.length - 1].x.toFixed(1)},${(geometry.height - geometry.plotBottom).toFixed(1)} L${series.points[0].x.toFixed(1)},${(geometry.height - geometry.plotBottom).toFixed(1)} Z`} /> : null}
                {smoothedWeight ? series.points.map((point) => <line className="is-deviation" style={{ strokeWidth: deviationWidth }} key={`bar-${point.source.id}`} x1={point.x} x2={point.x} y1={plot.y(point.source.trend_value)} y2={plot.y(point.source.raw_value)} />) : null}
                {series.points.length > 1 && trendStyle ? <path className="is-trend-halo" d={displayPath} /> : null}
                {series.points.length > 1 ? <path className={cn("is-line", trendStyle && "is-trend-line")} d={displayPath} /> : null}
                {smoothedWeight
                  ? series.points.map((point) => <circle className="is-actual-point" key={`point-${point.source.id}`} cx={point.x} cy={plot.y(point.source.raw_value)} r={markerRadius} />)
                  : (mode === "raw" || series.points.length < 2) ? series.points.map((point) => <circle className="is-point" key={point.source.id} cx={point.x} cy={point.y} r={markerRadius} />) : null}
              </g>;
            })}</g>
            {selectedRuleX != null && crosshairY != null && selectedRuleX >= geometry.plotLeft && selectedRuleX <= geometry.width - geometry.plotRight ? <g className="is-crosshair">
              <line className="is-selection" x1={selectedRuleX} x2={selectedRuleX} y1={geometry.plotTop} y2={geometry.height - geometry.plotBottom} />
              <line className="is-selection" x1={geometry.plotLeft} x2={geometry.width - geometry.plotRight} y1={crosshairY} y2={crosshairY} />
              <circle className="is-crosshair-halo" cx={selectedRuleX} cy={crosshairY} r={10} />
              <circle className="is-crosshair-point" cx={selectedRuleX} cy={crosshairY} r={5} />
              <rect className="is-axis-badge" x={valueBadgeX} y={crosshairY - 11} width={valueBadgeWidth} height={22} rx={4} />
              <text className="is-axis-badge-text" x={valueBadgeX + valueBadgeWidth / 2} y={crosshairY + 4} textAnchor="middle">{formatValue(primaryValue!, metric)}</text>
              <rect className="is-axis-badge" x={dateBadgeX} y={geometry.height - geometry.plotBottom + 5} width={dateBadgeWidth} height={22} rx={4} />
              <text className="is-axis-badge-text" x={dateBadgeX + dateBadgeWidth / 2} y={geometry.height - geometry.plotBottom + 20} textAnchor="middle">{formatCrosshairDate(selectedTime!, geometry.width < 480)}</text>
            </g> : null}
          </svg>
        </div>
        <div className="fitness-measurements__chart-footer">
          <span id={helpId}>{isOverview ? "Drag to see earlier dates · click or tap a reading" : "Click or tap a reading · drag to pan · pinch or scroll to zoom"}</span>
        </div>
      </figure>
      {metric === "weight" && selectedTime != null ? <section className="fitness-measurements__photo-panel" aria-label="Progress photo for selected weigh-in">
        {graphPhotos.loading && !activePhoto ? <div className="fitness-measurements__photo-state" role="status"><LoaderCircle className="is-spinning" aria-hidden="true" size={22} /><span>Looking for a photo from this date…</span></div>
          : graphPhotos.error && !activePhoto ? <div className="fitness-measurements__photo-state is-error" role="alert"><Camera aria-hidden="true" size={22} /><span>{graphPhotos.error}</span><button type="button" className="button button--secondary button--compact" onClick={graphPhotos.retry}>Try again</button></div>
            : !activePhoto ? <div className="fitness-measurements__photo-state"><Camera aria-hidden="true" size={22} /><span>No progress photo from {primaryReading ? formatFitnessDate(primaryReading.point.measured_at_utc) : "this date"}.</span></div>
              : comparisonPair.length === 2 ? <>
                <header className="fitness-measurements__photo-heading">
                  <div><span>Progress photos</span><strong>Compare dates</strong></div>
                  <button type="button" className="fitness-measurements__photo-close" aria-label="Close photo comparison" onClick={() => setComparisonPhotoId(null)}><X aria-hidden="true" size={19} /></button>
                </header>
                <div className="fitness-measurements__photo-comparison">
                  {comparisonPair.map((item, index) => <figure key={item.photo.id}>
                    <FitnessProgressPhotoPreview item={item} online={online} alt={`${fitnessProgressPhotoPoseLabels[item.photo.pose]} progress photo from ${formatFitnessDate(item.photo.captured_at)}`} className="fitness-measurements__photo-image" />
                    <figcaption><strong>{index === 0 ? "Before" : "After"}</strong><span>{formatFitnessDate(item.photo.captured_at)}</span></figcaption>
                  </figure>)}
                </div>
                <div className="fitness-measurements__photo-browser">
                  <div className="fitness-measurements__photo-browser-heading">
                    <div><strong>Other photo</strong><span>Swipe through the photos, then tap one.</span></div>
                    <div className="fitness-measurements__photo-browser-buttons">
                      <button type="button" aria-label="Previous progress photo" disabled={comparisonIndex <= 0} onClick={() => moveComparisonPhoto(-1)}><ChevronLeft aria-hidden="true" size={20} /></button>
                      <button type="button" aria-label="Next progress photo" disabled={comparisonIndex >= comparisonCandidates.length - 1} onClick={() => moveComparisonPhoto(1)}><ChevronRight aria-hidden="true" size={20} /></button>
                    </div>
                  </div>
                  <div className="fitness-measurements__photo-strip" role="list" aria-label="Photos available to compare">
                    {comparisonCandidates.map((item) => <div role="listitem" key={item.photo.id}>
                      <button ref={item.photo.id === comparisonPhotoId ? selectedComparisonButton : undefined} type="button" className={cn(item.photo.id === comparisonPhotoId && "is-active")} aria-pressed={item.photo.id === comparisonPhotoId} aria-label={`Compare with ${fitnessProgressPhotoPoseLabels[item.photo.pose].toLocaleLowerCase()} photo from ${formatFitnessDate(item.photo.captured_at)}`} onClick={() => setComparisonPhotoId(item.photo.id)}>
                        <FitnessProgressPhotoPreview item={item} online={online} alt="" className="fitness-measurements__photo-thumbnail" />
                        <span><strong>{fitnessProgressPhotoPoseLabels[item.photo.pose]}</strong><time dateTime={item.photo.captured_at}>{formatFitnessDate(item.photo.captured_at)}</time></span>
                      </button>
                    </div>)}
                  </div>
                </div>
              </> : <>
                <header className="fitness-measurements__photo-heading">
                  <div><span>Progress photo</span><strong>{formatFitnessDateTime(activePhoto.photo.captured_at)}</strong></div>
                  <button type="button" className="button button--secondary" disabled={!recommendedComparisonPhoto} onClick={() => setComparisonPhotoId(recommendedComparisonPhoto?.photo.id ?? null)}><Columns2 aria-hidden="true" size={17} /> Compare</button>
                </header>
                {photosOnSelectedDay.length > 1 ? <label className="fitness-measurements__photo-picker">Photo
                  <select value={activePhoto.photo.id} onChange={(event) => { setActivePhotoId(event.target.value); setComparisonPhotoId(null); }}>
                    {photosOnSelectedDay.map((item) => <option key={item.photo.id} value={item.photo.id}>{fitnessProgressPhotoPoseLabels[item.photo.pose]} · {formatFitnessDateTime(item.photo.captured_at)}</option>)}
                  </select>
                </label> : null}
                <figure className="fitness-measurements__selected-photo">
                  <FitnessProgressPhotoPreview item={activePhoto} online={online} alt={`${fitnessProgressPhotoPoseLabels[activePhoto.photo.pose]} progress photo from ${formatFitnessDate(activePhoto.photo.captured_at)}`} className="fitness-measurements__photo-image" />
                  <figcaption>{fitnessProgressPhotoPoseLabels[activePhoto.photo.pose]}</figcaption>
                </figure>
              </>}
      </section> : null}
      <p className="fitness-measurements__help">{mode === "raw" ? "Raw shows every recorded value without changing it." : metric === "weight" ? `Dots and stems are actual weigh-ins. The bold line is the smoothed ${history.smoothing_half_life_days}-day trend; the band shows whether it is falling or rising.` : `Smoothed reduces day-to-day noise using a time-aware exponential average with a ${history.smoothing_half_life_days}-day half-life.`}</p>
    </>}
  </article>;
}
