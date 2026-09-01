import { ArrowLeft, Bookmark, HeartPulse, LoaderCircle, Play, Plus, Target, Trash2, TrendingUp } from "lucide-react";
import { useEffect, useMemo, useRef, useState } from "react";

import { api } from "../../api";
import { cn } from "../../components/ui";
import {
  analysisWindowDays,
  compatibleAnalysisFilters,
  dateDaysAgo,
  queryFromAnalysisPreset,
  runFitnessAnalysis,
  validateFitnessAnalysisQuery,
  type FitnessAnalysisPreset,
} from "../../fitness/analysis";
import {
  asFitnessArray,
  type FitnessAnalysisFilter,
  type FitnessAnalysisFilterDefinition,
  type FitnessAnalysisQuery,
  type FitnessAnalysisQueryResult,
  type FitnessAnalysisRegistry,
  type FitnessSavedChartDefinition,
  type FitnessWeeklyReview,
} from "../../fitness/contract";
import { FitnessAnalysisVisualisation } from "./FitnessAnalysisVisualisation";
import type { FitnessViewProps } from "./FitnessModuleView";
import "./fitness-wave4.css";
import {
  FitnessCard,
  FitnessLoadingOrError,
  FitnessPageHeading,
  errorMessage,
  localDateValue,
  useFitnessEndpoint,
} from "./shared";

const emptyRegistry: FitnessAnalysisRegistry = {
  dimensions: [],
  measures: [],
  chart_types: [],
  filters: [],
  comparisons: [],
  limits: { max_window_days: 366, max_output_points: 200, max_filters: 4 },
  default_queries: [],
};

type CatalogueCategory = "all" | "nutrition" | "body" | "recovery" | "running" | "strength" | "issues" | "gear" | "goals";

const categoryLabels: Record<CatalogueCategory, string> = {
  all: "All",
  nutrition: "Nutrition",
  body: "Body",
  recovery: "Recovery",
  running: "Running",
  strength: "Strength",
  issues: "Body issues",
  gear: "Gear",
  goals: "Goals",
};

function initialFilterValue(definition: FitnessAnalysisFilterDefinition): FitnessAnalysisFilter["value"] {
  if (definition.values?.length) return definition.values[0].key;
  if (definition.value_type === "boolean") return false;
  if (definition.value_type === "number") return 0;
  if (definition.value_type === "date") return localDateValue();
  return "";
}

function FilterValueEditor({ definition, filter, onChange }: {
  definition: FitnessAnalysisFilterDefinition;
  filter: FitnessAnalysisFilter;
  onChange: (next: FitnessAnalysisFilter) => void;
}) {
  if (definition.values?.length) {
    if (filter.operator === "in") return <select multiple aria-label={`${definition.label} values`} value={(Array.isArray(filter.value) ? filter.value : [filter.value]).map(String)} onChange={(event) => onChange({ ...filter, value: Array.from(event.target.selectedOptions, (option) => option.value) })}>{definition.values.map((option) => <option value={option.key} key={option.key}>{option.label}</option>)}</select>;
    return <select aria-label={`${definition.label} value`} value={String(Array.isArray(filter.value) ? filter.value[0] ?? "" : filter.value)} onChange={(event) => onChange({ ...filter, value: event.target.value })}>{definition.values.map((option) => <option value={option.key} key={option.key}>{option.label}</option>)}</select>;
  }
  if (definition.value_type === "boolean") return <select aria-label={`${definition.label} value`} value={String(Array.isArray(filter.value) ? filter.value[0] : filter.value)} onChange={(event) => onChange({ ...filter, value: event.target.value === "true" })}><option value="true">Yes</option><option value="false">No</option></select>;
  const inputType = definition.value_type === "date" ? "date" : definition.value_type === "number" ? "number" : "text";
  if (filter.operator === "between") {
    const values = Array.isArray(filter.value) ? filter.value : [filter.value, filter.value];
    return <span className="fitness-module__analysis-between"><input aria-label={`${definition.label} minimum`} type={inputType} value={String(values[0] ?? "")} onChange={(event) => onChange({ ...filter, value: [definition.value_type === "number" ? Number(event.target.value) : event.target.value, values[1] ?? ""] })} /><span>to</span><input aria-label={`${definition.label} maximum`} type={inputType} value={String(values[1] ?? "")} onChange={(event) => onChange({ ...filter, value: [values[0] ?? "", definition.value_type === "number" ? Number(event.target.value) : event.target.value] })} /></span>;
  }
  return <input aria-label={`${definition.label} value`} type={inputType} value={String(Array.isArray(filter.value) ? filter.value[0] ?? "" : filter.value)} onChange={(event) => onChange({ ...filter, value: definition.value_type === "number" ? Number(event.target.value) : event.target.value })} />;
}

function RegisteredFilterRow({ filter, definitions, onChange, onRemove }: {
  filter: FitnessAnalysisFilter;
  definitions: FitnessAnalysisFilterDefinition[];
  onChange: (next: FitnessAnalysisFilter) => void;
  onRemove: () => void;
}) {
  const definition = definitions.find((item) => item.key === filter.key) ?? definitions[0];
  if (!definition) return null;
  return <div className="fitness-module__analysis-filter">
    <label className="fitness-module__field">Filter<select value={definition.key} onChange={(event) => {
      const next = definitions.find((item) => item.key === event.target.value);
      if (next) onChange({ key: next.key, operator: next.operators[0], value: initialFilterValue(next) });
    }}>{definitions.map((item) => <option value={item.key} key={item.key}>{item.label}</option>)}</select></label>
    <label className="fitness-module__field">Rule<select value={filter.operator} onChange={(event) => onChange({ ...filter, operator: event.target.value as FitnessAnalysisFilter["operator"], value: event.target.value === "between" ? [filter.value as string | number | boolean, filter.value as string | number | boolean] : filter.value })}>{definition.operators.map((operator) => <option value={operator} key={operator}>{operator.replaceAll("_", " ")}</option>)}</select></label>
    <label className="fitness-module__field">Value<FilterValueEditor definition={definition} filter={filter} onChange={onChange} /></label>
    <button type="button" className="button button--secondary" aria-label={`Remove ${definition.label} filter`} onClick={onRemove}><Trash2 aria-hidden="true" size={16} /></button>
  </div>;
}

function presetIsRegistered(preset: FitnessAnalysisPreset, registry: FitnessAnalysisRegistry): boolean {
  const measure = registry.measures.find((item) => item.key === preset.measure_key);
  return Boolean(
    measure
    && registry.dimensions.some((item) => item.key === preset.dimension_key)
    && measure.supported_dimensions.includes(preset.dimension_key)
    && measure.chart_types.includes(preset.chart_type_key)
    && registry.chart_types.some((item) => item.key === preset.chart_type_key),
  );
}

function AnalysisStatus({ result }: { result: FitnessAnalysisQueryResult }) {
  if (result.status !== "queued" && result.status !== "processing") return null;
  return <div className="fitness-module__notice" role="status"><LoaderCircle className="is-spinning" aria-hidden="true" size={17} /><strong>{result.status === "queued" ? "Analysis queued" : "Analysis running"}</strong><span>HausKlar handles one detailed analysis at a time. This page will show the result when it is ready.</span></div>;
}

function FitnessAdvancedInsights({ online, revision }: FitnessViewProps) {
  const registry = useFitnessEndpoint<FitnessAnalysisRegistry>("/fitness/analysis/registry", emptyRegistry, revision);
  const saved = useFitnessEndpoint<FitnessSavedChartDefinition[] | { items?: FitnessSavedChartDefinition[] }>("/fitness/analysis/charts", [], revision);
  const endToday = localDateValue();
  const [dimensionKey, setDimensionKey] = useState("");
  const [measureKey, setMeasureKey] = useState("");
  const [chartTypeKey, setChartTypeKey] = useState<FitnessAnalysisQuery["chart_type_key"]>("line");
  const [start, setStart] = useState(() => dateDaysAgo(endToday, 84));
  const [end, setEnd] = useState(endToday);
  const [filters, setFilters] = useState<FitnessAnalysisFilter[]>([]);
  const [comparisonKey, setComparisonKey] = useState("");
  const [maxPoints, setMaxPoints] = useState(200);
  const [category, setCategory] = useState<CatalogueCategory>("all");
  const [result, setResult] = useState<FitnessAnalysisQueryResult | null>(null);
  const [running, setRunning] = useState(false);
  const [queryError, setQueryError] = useState<string | null>(null);
  const [saveName, setSaveName] = useState("");
  const [savingChart, setSavingChart] = useState(false);
  const [savedNonce, setSavedNonce] = useState(0);
  const [savedError, setSavedError] = useState<string | null>(null);
  const abortRef = useRef<AbortController | null>(null);

  useEffect(() => () => abortRef.current?.abort(), []);

  useEffect(() => {
    if (!registry.data.measures.length || measureKey) return;
    const preset = registry.data.default_queries.find((item) => item.surface !== "progress" && presetIsRegistered(item, registry.data));
    const firstMeasure = registry.data.measures[0];
    setMeasureKey(preset?.measure_key ?? firstMeasure.key);
    setDimensionKey(preset?.dimension_key ?? firstMeasure.supported_dimensions[0] ?? registry.data.dimensions[0]?.key ?? "");
    setChartTypeKey(preset?.chart_type_key ?? firstMeasure.default_chart_type ?? firstMeasure.chart_types[0] ?? "table");
    setMaxPoints(registry.data.limits.max_output_points);
    if (preset) {
      const query = queryFromAnalysisPreset(preset, registry.data, endToday);
      setStart(query.date_range.start);
      setFilters(query.filters);
      setComparisonKey(query.comparison_key ?? "");
    }
  }, [endToday, measureKey, registry.data]);

  const selectedMeasure = registry.data.measures.find((item) => item.key === measureKey);
  const availableDimensions = useMemo(() => registry.data.dimensions.filter((item) => selectedMeasure?.supported_dimensions.includes(item.key)), [registry.data.dimensions, selectedMeasure]);
  const availableCharts = useMemo(() => registry.data.chart_types.filter((item) => selectedMeasure?.chart_types.includes(item.key)), [registry.data.chart_types, selectedMeasure]);
  const availableFilterDefinitions = useMemo(() => registry.data.filters.filter((item) => selectedMeasure?.allowed_filter_keys.includes(item.key)), [registry.data.filters, selectedMeasure]);
  const availableComparisons = useMemo(() => registry.data.comparisons.filter((item) => selectedMeasure?.comparison_forms?.includes(item.key)), [registry.data.comparisons, selectedMeasure]);
  const presets = useMemo(() => registry.data.default_queries.filter((item) => item.surface !== "progress" && (category === "all" || item.category === category)), [category, registry.data.default_queries]);
  const savedCharts = asFitnessArray(saved.data);

  useEffect(() => {
    if (!selectedMeasure) return;
    if (!selectedMeasure.supported_dimensions.includes(dimensionKey)) setDimensionKey(selectedMeasure.supported_dimensions[0] ?? "");
    if (!selectedMeasure.chart_types.includes(chartTypeKey)) setChartTypeKey(selectedMeasure.default_chart_type ?? selectedMeasure.chart_types[0] ?? "table");
    setFilters((current) => compatibleAnalysisFilters(current, selectedMeasure.key, registry.data));
    if (comparisonKey && !selectedMeasure.comparison_forms?.includes(comparisonKey)) setComparisonKey("");
  }, [chartTypeKey, comparisonKey, dimensionKey, registry.data, selectedMeasure]);

  function currentQuery(): FitnessAnalysisQuery {
    return {
      measure_key: measureKey,
      dimension_key: dimensionKey,
      chart_type_key: chartTypeKey,
      date_range: { start, end },
      filters,
      comparison_key: comparisonKey || null,
      max_points: Math.min(maxPoints, registry.data.limits.max_output_points),
    };
  }

  function applyPreset(preset: FitnessAnalysisPreset) {
    const query = queryFromAnalysisPreset(preset, registry.data, end);
    setMeasureKey(query.measure_key);
    setDimensionKey(query.dimension_key);
    setChartTypeKey(query.chart_type_key);
    setStart(query.date_range.start);
    setFilters(query.filters);
    setComparisonKey(query.comparison_key ?? "");
    setMaxPoints(query.max_points);
    setResult(null);
    setQueryError(null);
  }

  async function runQuery() {
    if (!online) {
      setQueryError("Reconnect to run an analysis. No query is queued while offline.");
      return;
    }
    const query = currentQuery();
    const validation = validateFitnessAnalysisQuery(query, registry.data);
    if (validation) {
      setQueryError(validation);
      return;
    }
    abortRef.current?.abort();
    const controller = new AbortController();
    abortRef.current = controller;
    setRunning(true);
    setQueryError(null);
    setResult(null);
    try {
      const response = await runFitnessAnalysis(query, registry.data, setResult, controller.signal);
      setResult(response);
    } catch (requestError) {
      if (!(requestError instanceof DOMException && requestError.name === "AbortError")) setQueryError(errorMessage(requestError));
    } finally {
      if (abortRef.current === controller) {
        abortRef.current = null;
        setRunning(false);
      }
    }
  }

  async function saveChart() {
    const query = currentQuery();
    const validation = validateFitnessAnalysisQuery(query, registry.data);
    if (validation) {
      setSavedError(validation);
      return;
    }
    if (!online) {
      setSavedError("Reconnect to save this chart definition.");
      return;
    }
    setSavingChart(true);
    setSavedError(null);
    try {
      await api<FitnessSavedChartDefinition>("/fitness/analysis/charts", {
        method: "POST",
        body: JSON.stringify({
          name: saveName.trim() || selectedMeasure?.label || "Saved analysis",
          measure_key: query.measure_key,
          dimension_key: query.dimension_key,
          chart_type_key: query.chart_type_key,
          filter_keys: query.filters.map((filter) => filter.key),
          comparison_key: query.comparison_key,
          date_window_days: analysisWindowDays(query.date_range.start, query.date_range.end),
        }),
      }, true, false);
      setSaveName("");
      setSavedNonce((value) => value + 1);
      saved.reload();
    } catch (requestError) {
      setSavedError(errorMessage(requestError));
    } finally {
      setSavingChart(false);
    }
  }

  function applySavedChart(chart: FitnessSavedChartDefinition) {
    const measure = registry.data.measures.find((item) => item.key === chart.measure_key);
    if (!measure || !measure.supported_dimensions.includes(chart.dimension_key) || !measure.chart_types.includes(chart.chart_type_key)) {
      setSavedError("That saved chart is no longer available.");
      return;
    }
    setMeasureKey(chart.measure_key);
    setDimensionKey(chart.dimension_key);
    setChartTypeKey(chart.chart_type_key);
    setStart(dateDaysAgo(end, Math.min(chart.date_window_days, registry.data.limits.max_window_days)));
    setComparisonKey(chart.comparison_key && measure.comparison_forms?.includes(chart.comparison_key) ? chart.comparison_key : "");
    setFilters(chart.filter_keys.flatMap((key) => {
      const definition = registry.data.filters.find((item) => item.key === key && measure.allowed_filter_keys.includes(key));
      return definition ? [{ key, operator: definition.operators[0], value: initialFilterValue(definition) }] : [];
    }));
    setResult(null);
  }

  useEffect(() => {
    const url = new URL(window.location.href);
    const target = url.searchParams.get("fitness-analysis-chart");
    if (!target || registry.loading || saved.loading) return;
    const chart = savedCharts.find((item) => item.id === target);
    if (!chart) return;
    applySavedChart(chart);
    url.searchParams.delete("fitness-analysis-chart");
    window.history.replaceState({}, "", url);
    window.requestAnimationFrame(() => {
      const row = document.getElementById(`fitness-analysis-chart-${target}`);
      const reducedMotion = window.matchMedia?.("(prefers-reduced-motion: reduce)").matches ?? false;
      row?.scrollIntoView({ block: "center", behavior: reducedMotion ? "auto" : "smooth" });
      row?.focus({ preventScroll: true });
    });
  }, [registry.loading, saved.loading, savedCharts]);

  async function removeSavedChart(chart: FitnessSavedChartDefinition) {
    if (!online) {
      setSavedError("Reconnect to remove this saved chart.");
      return;
    }
    try {
      await api(`/fitness/analysis/charts/${encodeURIComponent(chart.id)}`, { method: "DELETE" }, true, false);
      setSavedNonce((value) => value + 1);
      saved.reload();
    } catch (requestError) {
      setSavedError(errorMessage(requestError));
    }
  }

  const queryValidation = registry.data.measures.length ? validateFitnessAnalysisQuery(currentQuery(), registry.data) : "No analyses are available.";

  return <section aria-label="Advanced Insights" data-saved-revision={savedNonce}>
    <FitnessPageHeading title="Advanced Insights" detail="Build a custom chart when the ready-made questions are not enough." />
    {!online ? <div className="fitness-module__notice" role="status"><strong>Analysis is offline</strong><span>Reconnect to run or save a query. Existing Fitness records remain available in their normal sections.</span></div> : null}
    <FitnessLoadingOrError loading={registry.loading} error={registry.error} retry={registry.reload} />

    {!registry.loading && !registry.error ? <>
      <FitnessCard title="Analysis catalogue" detail="Choose a ready-made question from your own Fitness records.">
        <div className="fitness-module__analysis-categories" role="group" aria-label="Analysis categories">{(Object.keys(categoryLabels) as CatalogueCategory[]).map((item) => <button type="button" className={cn(category === item && "is-active")} aria-pressed={category === item} onClick={() => setCategory(item)} key={item}>{categoryLabels[item]}</button>)}</div>
        {presets.length ? <div className="fitness-module__analysis-presets">{presets.map((preset) => {
          const available = presetIsRegistered(preset, registry.data);
          return <button type="button" onClick={() => applyPreset(preset)} disabled={!available} key={preset.key}><strong>{preset.label}</strong><span>{preset.description ?? `${categoryLabels[(preset.category as CatalogueCategory) ?? "all"] ?? "Available"} analysis`}</span>{!available ? <small>This option is unavailable</small> : null}</button>;
        })}</div> : <div className="fitness-module__empty"><strong>No ready-made questions in this category</strong><span>Try another category.</span></div>}
      </FitnessCard>

      <FitnessCard title="Configure analysis" detail={selectedMeasure?.description ?? "Choose only compatible dimensions, filters, comparisons, and chart shapes."} className="is-wide">
        {registry.data.measures.length ? <form className="fitness-module__form" onSubmit={(event) => { event.preventDefault(); void runQuery(); }}>
          <div className="fitness-module__fields">
            <label className="fitness-module__field">Measure<select value={measureKey} onChange={(event) => setMeasureKey(event.target.value)}>{registry.data.measures.map((item) => <option value={item.key} key={item.key}>{item.label}</option>)}</select></label>
            <label className="fitness-module__field">Group by<select value={dimensionKey} onChange={(event) => setDimensionKey(event.target.value)}>{availableDimensions.map((item) => <option value={item.key} key={item.key}>{item.label}</option>)}</select></label>
            <label className="fitness-module__field">Chart<select value={chartTypeKey} onChange={(event) => setChartTypeKey(event.target.value as FitnessAnalysisQuery["chart_type_key"])}>{availableCharts.map((item) => <option value={item.key} key={item.key}>{item.label}</option>)}</select></label>
            <label className="fitness-module__field">From<input type="date" value={start} max={end} onChange={(event) => setStart(event.target.value)} /></label>
            <label className="fitness-module__field">To<input type="date" value={end} min={start} max={endToday} onChange={(event) => setEnd(event.target.value)} /></label>
            {availableComparisons.length ? <label className="fitness-module__field">Comparison<select value={comparisonKey} onChange={(event) => setComparisonKey(event.target.value)}><option value="">None</option>{availableComparisons.map((item) => <option value={item.key} key={item.key}>{item.label}</option>)}</select></label> : null}
            <label className="fitness-module__field">Maximum points<input type="number" min="1" max={registry.data.limits.max_output_points} value={maxPoints} onChange={(event) => setMaxPoints(Number(event.target.value))} /></label>
          </div>

          {filters.map((filter, index) => <RegisteredFilterRow filter={filter} definitions={availableFilterDefinitions.filter((definition) => definition.key === filter.key || !filters.some((item) => item.key === definition.key))} onChange={(next) => setFilters((current) => current.map((item, itemIndex) => itemIndex === index ? next : item))} onRemove={() => setFilters((current) => current.filter((_, itemIndex) => itemIndex !== index))} key={`${filter.key}-${index}`} />)}
          {availableFilterDefinitions.some((definition) => !filters.some((filter) => filter.key === definition.key)) && filters.length < registry.data.limits.max_filters ? <button type="button" className="button button--secondary" onClick={() => {
            const definition = availableFilterDefinitions.find((item) => !filters.some((filter) => filter.key === item.key));
            if (definition) setFilters((current) => [...current, { key: definition.key, operator: definition.operators[0], value: initialFilterValue(definition) }]);
          }}><Plus aria-hidden="true" size={16} /> Add filter</button> : null}

          {selectedMeasure?.classification === "correlational" ? <div className="fitness-module__notice"><strong>Association, not cause</strong><span>This result can compare recorded patterns but cannot show that one factor caused another.</span></div> : null}
          {queryValidation ? <p className="fitness-module__form-status is-error" role="status">{queryValidation}</p> : null}
          <div className="fitness-module__form-footer"><button type="submit" className="button button--primary" disabled={running || Boolean(queryValidation) || !online}>{running ? <LoaderCircle className="is-spinning" aria-hidden="true" size={16} /> : <Play aria-hidden="true" size={16} />} {running ? "Running…" : "Run analysis"}</button>{running ? <button type="button" className="button button--secondary" onClick={() => abortRef.current?.abort()}>Cancel</button> : null}</div>
        </form> : <div className="fitness-module__empty"><strong>No analysis is ready yet</strong><span>There isn’t a ready-made question for this view.</span></div>}
        {queryError ? <div className="fitness-module__notice fitness-module__notice--error" role="alert">{queryError}</div> : null}
      </FitnessCard>

      {result ? <FitnessCard title={result.title} detail={result.description ?? `${result.metadata.sample_size} observations · ${Math.round(result.metadata.missing_rate * 100)}% missing`} className="is-wide"><AnalysisStatus result={result} />{result.status !== "queued" && result.status !== "processing" ? <FitnessAnalysisVisualisation result={result} /> : null}</FitnessCard> : null}

      <FitnessCard title="Saved charts" detail="A saved chart remembers the question and date window; your underlying records stay private.">
        <div className="fitness-module__form-footer"><label className="fitness-module__field fitness-module__save-chart-name">Chart name<input value={saveName} maxLength={80} placeholder={selectedMeasure?.label ?? "Saved analysis"} onChange={(event) => setSaveName(event.target.value)} /></label><button type="button" className="button button--secondary" disabled={savingChart || Boolean(queryValidation) || !online} onClick={() => void saveChart()}><Bookmark aria-hidden="true" size={16} /> {savingChart ? "Saving…" : "Save definition"}</button></div>
        {saved.loading ? <p className="fitness-module__form-status"><LoaderCircle className="is-spinning" aria-hidden="true" size={15} /> Loading saved charts…</p> : null}
        {savedCharts.length ? <ul className="fitness-module__list">{savedCharts.map((chart) => { const measureLabel = registry.data.measures.find((item) => item.key === chart.measure_key)?.label ?? "Saved measure"; const dimensionLabel = registry.data.dimensions.find((item) => item.key === chart.dimension_key)?.label ?? "saved grouping"; return <li id={`fitness-analysis-chart-${chart.id}`} tabIndex={-1} key={chart.id}><button type="button" className="fitness-module__saved-chart" onClick={() => applySavedChart(chart)}><strong>{chart.name}</strong><small>{measureLabel} by {dimensionLabel} · {chart.date_window_days} days</small></button><button type="button" className="button button--secondary" aria-label={`Remove ${chart.name}`} onClick={() => void removeSavedChart(chart)}><Trash2 aria-hidden="true" size={15} /></button></li>; })}</ul> : !saved.loading ? <div className="fitness-module__empty"><strong>No saved charts</strong><span>Configure a chart above, then save it for later.</span></div> : null}
        {saved.error || savedError ? <p className="fitness-module__form-status is-error" role="alert">{savedError ?? saved.error}</p> : null}
      </FitnessCard>
    </> : null}

    <div className="fitness-module__callout"><strong>See what each result is based on</strong><p>Open Data and method beneath a result for its period, sample, missing data, source quality and limitations.</p></div>
  </section>;
}

type InsightQuestion = "month" | "recovery" | "goal";

const insightQuestions: Array<{ id: InsightQuestion; label: string; detail: string; icon: typeof TrendingUp }> = [
  { id: "month", label: "What changed this month?", detail: "See the clearest recent movement in your records.", icon: TrendingUp },
  { id: "recovery", label: "Why has recovery fallen?", detail: "Look at your recent sleep pattern before drawing conclusions.", icon: HeartPulse },
  { id: "goal", label: "Am I progressing toward my goal?", detail: "Compare this week with the target you chose.", icon: Target },
];

function humanInsightValue(value: number, unit?: string | null): string {
  if (unit === "m") return `${(value / 1_000).toLocaleString(undefined, { maximumFractionDigits: 1 })} km`;
  if (unit === "s") return `${Math.round(value / 60)} min`;
  if (unit === "s_per_km") {
    const minutes = Math.floor(value / 60);
    return `${minutes}:${String(Math.round(value % 60)).padStart(2, "0")} /km`;
  }
  if (unit === "kg_reps") return `${value.toLocaleString(undefined, { maximumFractionDigits: 0 })} kg lifted`;
  const known: Record<string, string> = { kg: "kg", "%": "%", bpm: "bpm", ms: "ms", count: "", sets: "sets" };
  const suffix = unit ? known[unit] ?? "" : "";
  return `${value.toLocaleString(undefined, { maximumFractionDigits: 1 })}${suffix ? ` ${suffix}` : ""}`;
}

function HumanInsightResult({ result }: { result: FitnessAnalysisQueryResult }) {
  const points = result.series[0]?.points.filter((point) => point.value != null).slice(-8) ?? [];
  if (result.status === "empty" || result.status === "insufficient_sample") return <div className="fitness-module__empty"><TrendingUp aria-hidden="true" size={24} /><strong>Not enough history yet</strong><span>Keep using Fitness normally and try this question again later.</span></div>;
  if (result.status === "queued" || result.status === "processing") return <div className="fitness-wave4__insight-loading" role="status"><LoaderCircle className="is-spinning" aria-hidden="true" size={18} /><span>Looking for a useful pattern…</span></div>;
  return <div className="fitness-wave4__insight-result"><div><span>{result.title}</span><strong>{result.summary ?? result.description ?? "Your recent pattern is ready."}</strong></div>{result.difference ? <p><span>{result.difference.label}</span><strong>{humanInsightValue(result.difference.value, result.difference.unit_key ?? result.unit_key)}</strong></p> : null}{points.length ? <figure><figcaption className="sr-only">{result.title}: {points.map((point) => `${point.label} ${humanInsightValue(point.value ?? 0, result.unit_key)}`).join(", ")}</figcaption><div role="img" aria-label={`${result.title}: ${points.map((point) => `${point.label} ${humanInsightValue(point.value ?? 0, result.unit_key)}`).join(", ")}`}>{points.map((point) => { const maximum = Math.max(1, ...points.map((item) => item.value ?? 0)); return <span key={point.key}><i style={{ height: `${Math.max(6, (point.value ?? 0) / maximum * 100)}%` }} /><small>{point.label}</small></span>; })}</div></figure> : null}</div>;
}

function QuestionInsight({ question, online, revision, onCoach }: { question: Exclude<InsightQuestion, "goal">; online: boolean; revision: number; onCoach: () => void }) {
  const registry = useFitnessEndpoint<FitnessAnalysisRegistry>("/fitness/analysis/registry", emptyRegistry, revision);
  const [result, setResult] = useState<FitnessAnalysisQueryResult | null>(null);
  const [running, setRunning] = useState(false);
  const [runError, setRunError] = useState<string | null>(null);
  const [nonce, setNonce] = useState(0);
  const ranKey = useRef("");

  useEffect(() => {
    if (!online || registry.loading || registry.error || !registry.data.default_queries.length) return;
    const key = `${question}:${revision}:${nonce}`;
    if (ranKey.current === key) return;
    const preferredKeys = question === "recovery" ? ["sleep-progress"] : ["weight-progress", "running-progress", "strength-progress"];
    const preset = preferredKeys.flatMap((presetKey) => registry.data.default_queries.filter((item) => item.key === presetKey && presetIsRegistered(item, registry.data)))[0];
    ranKey.current = key;
    if (!preset) { setRunError("This question needs a little more Fitness history first."); return; }
    const controller = new AbortController();
    setRunning(true);
    setRunError(null);
    setResult(null);
    const query = queryFromAnalysisPreset(preset, registry.data, localDateValue());
    if (question === "month") query.date_range.start = dateDaysAgo(query.date_range.end, 27);
    void runFitnessAnalysis(query, registry.data, setResult, controller.signal)
      .then(setResult)
      .catch((requestError) => {
        if (!(requestError instanceof DOMException && requestError.name === "AbortError")) setRunError("That question could not be answered just now. Try again in a moment.");
      })
      .finally(() => setRunning(false));
    return () => controller.abort();
  }, [nonce, online, question, registry.data, registry.error, registry.loading, revision]);

  return <FitnessCard title={question === "month" ? "What changed this month?" : "Why has recovery fallen?"} detail={question === "month" ? "The clearest recent movement in your Fitness history." : "Your recent sleep pattern, shown without guessing at a cause."} className="fitness-wave4__question-result">
    <FitnessLoadingOrError loading={registry.loading} error={registry.error} retry={registry.reload} />
    {!online ? <div className="fitness-module__empty"><strong>This question needs an internet connection</strong><span>Your normal Fitness records remain available.</span></div> : null}
    {running && !result ? <div className="fitness-wave4__insight-loading" role="status"><LoaderCircle className="is-spinning" aria-hidden="true" size={18} /><span>Looking for a useful pattern…</span></div> : null}
    {result ? <HumanInsightResult result={result} /> : null}
    {runError ? <div className="fitness-module__notice fitness-module__notice--error" role="alert"><span>{runError}</span><button type="button" className="button button--secondary button--compact" onClick={() => { ranKey.current = ""; setNonce((value) => value + 1); }}>Try again</button></div> : null}
    {result && result.status === "complete" ? <button type="button" className="button button--secondary" onClick={onCoach}>Ask Coach about this</button> : null}
  </FitnessCard>;
}

function weekStartValue(): string {
  const date = new Date(`${localDateValue()}T12:00:00`);
  date.setDate(date.getDate() - ((date.getDay() + 6) % 7));
  return localDateValue(date);
}

function GoalQuestionInsight({ revision, onPlan, onCoach }: { revision: number; onPlan: () => void; onCoach: () => void }) {
  const review = useFitnessEndpoint<FitnessWeeklyReview>(`/fitness/weekly-review?week_start=${weekStartValue()}`, {
    week_start: weekStartValue(), week_end: weekStartValue(), totals: { completed_sessions: 0, active_days: 0 }, goal: null,
    highlight: { title: "A fresh week", detail: "Your first useful step can be small." },
    opportunity: { title: "Choose the next step", detail: "Put one realistic session in the week.", destination: "plan", action: "plan_session", action_label: "Open Plan" },
  }, revision);
  return <FitnessCard title="Am I progressing toward my goal?" detail="This week against the target you chose." className="fitness-wave4__question-result"><FitnessLoadingOrError loading={review.loading} error={review.error} retry={review.reload} />{!review.loading && !review.error ? review.data.goal ? <div className="fitness-wave4__goal-answer"><span>{review.data.goal.goal_name}</span><strong>{review.data.goal.progress_text}</strong>{review.data.goal.progress_percent != null ? <div className="fitness-wave4__goal-progress" role="progressbar" aria-label={`${review.data.goal.goal_name}: ${review.data.goal.progress_percent}%`} aria-valuemin={0} aria-valuemax={100} aria-valuenow={review.data.goal.progress_percent}><span style={{ width: `${review.data.goal.progress_percent}%` }} /></div> : null}<p>{review.data.highlight.detail}</p><div className="fitness-module__button-row"><button type="button" className="button button--primary" onClick={onPlan}>{review.data.opportunity.action_label}</button><button type="button" className="button button--secondary" onClick={onCoach}>Ask Coach about this</button></div></div> : <div className="fitness-module__empty"><Target aria-hidden="true" size={24} /><strong>No goal selected</strong><span>Choose one goal in Plan so this question has a clear answer.</span><button type="button" className="button button--primary" onClick={onPlan}>Choose a goal</button></div> : null}</FitnessCard>;
}

function initialInsightState(): { question: InsightQuestion | null; advanced: boolean } {
  const query = new URLSearchParams(window.location.search);
  const question = query.get("fitness-insight");
  return {
    question: question === "month" || question === "recovery" || question === "goal" ? question : null,
    advanced: query.get("section") === "analysis" || query.has("fitness-analysis-chart") || query.get("fitness-insights") === "advanced",
  };
}

export function FitnessExploreView(props: FitnessViewProps) {
  const initial = initialInsightState();
  const [question, setQuestionState] = useState<InsightQuestion | null>(initial.question);
  const [advanced, setAdvancedState] = useState(initial.advanced);

  function setQuestion(next: InsightQuestion | null) {
    setQuestionState(next);
    const url = new URL(window.location.href);
    if (next) url.searchParams.set("fitness-insight", next);
    else url.searchParams.delete("fitness-insight");
    window.history.replaceState(window.history.state, "", url);
  }

  function setAdvanced(next: boolean) {
    setAdvancedState(next);
    const url = new URL(window.location.href);
    if (next) url.searchParams.set("fitness-insights", "advanced");
    else url.searchParams.delete("fitness-insights");
    window.history.replaceState(window.history.state, "", url);
  }

  if (advanced) return <section className="fitness-wave4__advanced-insights"><button type="button" className="button button--secondary" onClick={() => setAdvanced(false)}><ArrowLeft aria-hidden="true" size={17} /> Back to questions</button><FitnessAdvancedInsights {...props} /></section>;

  return <section aria-label="Insights" className="fitness-wave4__insights"><FitnessPageHeading title="Insights" detail="Start with the question you actually want answered." />
    <div className="fitness-wave4__insight-questions" aria-label="Insight questions">{insightQuestions.map((item) => { const Icon = item.icon; return <button type="button" className={cn(question === item.id && "is-active")} aria-pressed={question === item.id} onClick={() => setQuestion(item.id)} key={item.id}><Icon aria-hidden="true" size={21} /><span><strong>{item.label}</strong><small>{item.detail}</small></span></button>; })}</div>
    {question === "goal" ? <GoalQuestionInsight revision={props.revision} onPlan={() => { const url = new URL(window.location.href); url.searchParams.set("fitness-plan-manage", "goals"); window.history.replaceState(window.history.state, "", url); props.onSectionChange("training"); }} onCoach={() => props.onSectionChange("coach")} /> : null}
    {question === "month" || question === "recovery" ? <QuestionInsight question={question} online={props.online} revision={props.revision} onCoach={() => props.onSectionChange("coach")} /> : null}
    <details className="fitness-module__maintenance"><summary>Advanced</summary><div className="fitness-module__maintenance-body"><p className="fitness-module__muted">Build a custom chart when the ready-made questions do not fit.</p><button type="button" className="button button--secondary" onClick={() => setAdvanced(true)}>Open advanced builder</button></div></details>
  </section>;
}
