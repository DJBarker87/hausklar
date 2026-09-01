import { api } from "../api";
import type {
  FitnessAnalysisFilter,
  FitnessAnalysisQuery,
  FitnessAnalysisQueryResult,
  FitnessAnalysisRegistry,
} from "./contract";

export type FitnessAnalysisPreset = FitnessAnalysisRegistry["default_queries"][number];

function utcDate(value: string): number {
  return Date.parse(`${value}T00:00:00Z`);
}

export function analysisWindowDays(start: string, end: string): number {
  const startMs = utcDate(start);
  const endMs = utcDate(end);
  if (!Number.isFinite(startMs) || !Number.isFinite(endMs) || endMs < startMs) return 0;
  return Math.floor((endMs - startMs) / 86_400_000) + 1;
}

export function dateDaysAgo(end: string, days: number): string {
  const date = new Date(`${end}T12:00:00Z`);
  date.setUTCDate(date.getUTCDate() - Math.max(0, days - 1));
  return date.toISOString().slice(0, 10);
}

export function validateFitnessAnalysisQuery(query: FitnessAnalysisQuery, registry: FitnessAnalysisRegistry): string | null {
  const dimension = registry.dimensions.find((item) => item.key === query.dimension_key);
  if (!dimension) return "Choose an available grouping.";
  const measure = registry.measures.find((item) => item.key === query.measure_key);
  if (!measure) return "Choose an available measure.";
  if (!measure.supported_dimensions.includes(dimension.key)) return "That measure cannot be grouped by this dimension.";
  if (!measure.chart_types.includes(query.chart_type_key) || !registry.chart_types.some((item) => item.key === query.chart_type_key)) return "That chart is not available for this measure.";
  const days = analysisWindowDays(query.date_range.start, query.date_range.end);
  if (!days) return "Choose a valid date window.";
  if (days > registry.limits.max_window_days) return `The maximum analysis window is ${registry.limits.max_window_days} days.`;
  if (!Number.isInteger(query.max_points) || query.max_points < 1 || query.max_points > registry.limits.max_output_points) return `Results are limited to ${registry.limits.max_output_points} points.`;
  if (query.filters.length > registry.limits.max_filters) return `Use at most ${registry.limits.max_filters} filters.`;
  const seen = new Set<string>();
  for (const filter of query.filters) {
    if (seen.has(filter.key)) return "Use each filter once.";
    seen.add(filter.key);
    if (!measure.allowed_filter_keys.includes(filter.key)) return `The ${filter.key} filter is not available for this measure.`;
    const definition = registry.filters.find((item) => item.key === filter.key);
    if (!definition || !definition.operators.includes(filter.operator)) return "Choose an available filter and condition.";
    const values = Array.isArray(filter.value) ? filter.value : [filter.value];
    if (definition.max_values != null && values.length > definition.max_values) return `${definition.label} accepts at most ${definition.max_values} values.`;
    if (definition.values?.length && values.some((value) => !definition.values?.some((option) => option.key === String(value)))) return `Choose an available ${definition.label.toLocaleLowerCase()} value.`;
  }
  if (query.comparison_key) {
    if (!registry.comparisons.some((item) => item.key === query.comparison_key) || !measure.comparison_forms?.includes(query.comparison_key)) return "That comparison is not available for this measure.";
  }
  return null;
}

export function queryFromAnalysisPreset(
  preset: FitnessAnalysisPreset,
  registry: FitnessAnalysisRegistry,
  end: string,
): FitnessAnalysisQuery {
  return {
    measure_key: preset.measure_key,
    dimension_key: preset.dimension_key,
    chart_type_key: preset.chart_type_key,
    date_range: {
      start: dateDaysAgo(end, Math.min(preset.date_window_days, registry.limits.max_window_days)),
      end,
    },
    filters: preset.filters ?? [],
    comparison_key: preset.comparison_key ?? null,
    max_points: registry.limits.max_output_points,
  };
}

export function compatibleAnalysisFilters(
  filters: FitnessAnalysisFilter[],
  measureKey: string,
  registry: FitnessAnalysisRegistry,
): FitnessAnalysisFilter[] {
  const allowed = new Set(registry.measures.find((item) => item.key === measureKey)?.allowed_filter_keys ?? []);
  return filters.filter((filter) => allowed.has(filter.key));
}

export type FitnessAnalysisWait = (milliseconds: number, signal?: AbortSignal) => Promise<void>;

function abortableDelay(milliseconds: number, signal?: AbortSignal): Promise<void> {
  return new Promise((resolve, reject) => {
    const timer = window.setTimeout(resolve, milliseconds);
    signal?.addEventListener("abort", () => {
      window.clearTimeout(timer);
      reject(new DOMException("Analysis cancelled", "AbortError"));
    }, { once: true });
  });
}

export async function runFitnessAnalysis(
  query: FitnessAnalysisQuery,
  registry: FitnessAnalysisRegistry,
  onUpdate?: (result: FitnessAnalysisQueryResult) => void,
  signal?: AbortSignal,
  wait: FitnessAnalysisWait = abortableDelay,
): Promise<FitnessAnalysisQueryResult> {
  const problem = validateFitnessAnalysisQuery(query, registry);
  if (problem) throw new Error(problem);
  let result = await api<FitnessAnalysisQueryResult>("/fitness/analysis/query", {
    method: "POST",
    body: JSON.stringify(query),
    signal,
  }, true, false);
  onUpdate?.(result);
  let polls = 0;
  while ((result.status === "queued" || result.status === "processing") && result.job_id && polls < 120) {
    const delay = Math.min(10_000, Math.max(500, result.poll_after_ms ?? registry.limits.heavy_poll_interval_ms ?? 2_000));
    await wait(delay, signal);
    result = await api<FitnessAnalysisQueryResult>(`/fitness/analysis/jobs/${encodeURIComponent(result.job_id)}`, { signal }, true, false);
    onUpdate?.(result);
    polls += 1;
  }
  if (result.status === "queued" || result.status === "processing") throw new Error("This analysis is still taking longer than expected. You can run it again later without losing any records.");
  if (result.status === "error") throw new Error(result.summary ?? result.limitations[0] ?? "The analysis could not be completed.");
  return result;
}
