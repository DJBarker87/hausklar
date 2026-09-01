import { AlertCircle, BarChart3, Bookmark, CheckCircle2, ChevronRight, FileSearch, MessageCircleMore, Play } from "lucide-react";
import { useEffect, useMemo, useState, type CSSProperties, type FormEvent } from "react";

import { api } from "../api";
import { FinanceDeliveryCalendarAction } from "../components/FinanceDeliveryCalendarAction";
import { FinanceNetWorthPanel } from "../components/FinanceNetWorthPanel";
import { SeriesLine, Donut, type SeriesPoint } from "../components/FinanceCharts";
import { getFinanceAdvancedStrings } from "../financeAdvancedStrings";
import { todayInTimeZone } from "../financeDate";
import type { FinanceLocale } from "../financeStrings";
import type {
  FinanceAccount,
  FinanceAnalysisBasis,
  FinanceAnalysisComparison,
  FinanceAnalysisFilters,
  FinanceAnalysisGrouping,
  FinanceAnalysisMeasure,
  FinanceAnalysisRequest,
  FinanceAnalysisResponse,
  FinanceCoachingReport,
  FinanceEvidenceDetail,
  FinanceExactValue,
  FinanceFinding,
  FinanceHabit,
  FinancePurchaseEvidence,
  FinanceSavedAnalysisView,
  FinanceSettings,
  FinanceSpace,
  FinanceTransaction,
} from "../types";

type ResultState = "idle" | "loading" | "ready" | "error";
type EvidenceState = "idle" | "loading" | "ready" | "error";

const purchaseGroupings = new Set<FinanceAnalysisGrouping>([
  "LINE_KIND", "ITEM", "PURPOSE", "RECIPIENT", "PLANNEDNESS", "UTILITY", "VALUE_FOR_MONEY",
  "DECISION_QUALITY", "OUTCOME", "ITEMISATION",
]);

const moneyMeasures = new Set<FinanceAnalysisMeasure>([
  "SPEND", "INCOME", "MEAN_SPEND", "MEDIAN_SPEND", "MIN_SPEND", "MAX_SPEND", "MEAN_UNIT_PRICE",
]);

function isAbortError(error: unknown) {
  return error instanceof DOMException && error.name === "AbortError";
}

function dateShift(value: string, days: number) {
  const date = new Date(`${value}T12:00:00Z`);
  date.setUTCDate(date.getUTCDate() + days);
  return date.toISOString().slice(0, 10);
}

function splitValues(value: string) {
  return [...new Set(value.split(",").map((part) => part.trim()).filter(Boolean))];
}

function exactNumber(value: FinanceExactValue) {
  return value.denominator === 0 ? 0 : value.numerator / value.denominator;
}

function formatExact(value: FinanceExactValue, measure: FinanceAnalysisMeasure, currency: string, locale: FinanceLocale) {
  const numeric = exactNumber(value);
  if (measure === "COUNT") return new Intl.NumberFormat(locale === "de" ? "de-DE" : "en-GB", { maximumFractionDigits: 4 }).format(numeric);
  if (measure === "SHARE_OF_SPEND") {
    const formatted = new Intl.NumberFormat(locale === "de" ? "de-DE" : "en-GB", { style: "percent", maximumFractionDigits: 2 }).format(numeric);
    return value.denominator === 1 ? formatted : `${formatted} (${value.numerator}/${value.denominator})`;
  }
  const formatted = new Intl.NumberFormat(locale === "de" ? "de-DE" : "en-GB", {
    style: "currency",
    currency,
    minimumFractionDigits: 2,
    maximumFractionDigits: 4,
  }).format(numeric / 100);
  return formatted;
}

function ExactDisplay({
  value,
  measure,
  currency,
  locale,
}: {
  value: FinanceExactValue;
  measure: FinanceAnalysisMeasure;
  currency: string;
  locale: FinanceLocale;
}) {
  return <span className="finance-analysis-exact">{formatExact(value, measure, currency, locale)}</span>;
}

function formatCurrency(minor: number, currency: string, locale: FinanceLocale) {
  return new Intl.NumberFormat(locale === "de" ? "de-DE" : "en-GB", { style: "currency", currency }).format(minor / 100);
}

function formatDate(value: string, locale: FinanceLocale) {
  const parsed = new Date(`${value}T00:00:00`);
  return Number.isNaN(parsed.valueOf()) ? value : new Intl.DateTimeFormat(
    locale === "de" ? "de-DE" : "en-GB",
    { dateStyle: "medium" },
  ).format(parsed);
}

function record(value: unknown): Record<string, unknown> | null {
  return value !== null && typeof value === "object" && !Array.isArray(value)
    ? value as Record<string, unknown>
    : null;
}

function finiteNumber(value: unknown) {
  return typeof value === "number" && Number.isFinite(value) ? value : null;
}

function emptyFilters(): FinanceAnalysisFilters {
  return {
    account_ids: [], merchants: [], categories: [], transaction_types: [], line_kinds: [],
    normalized_items: [], purposes: [], beneficiaries: [], plannedness: [], utilities: [],
    decision_qualities: [], value_for_money: [], outcomes: [], itemisation: [],
  };
}

function requestFor(spaceID: string, currency: string, endDate: string, scope: "mine" | "household"): FinanceAnalysisRequest {
  return {
    space_id: spaceID,
    scope,
    basis: "TRANSACTIONS",
    start_date: endDate ? dateShift(endDate, -89) : "",
    end_date: endDate,
    currency,
    grouping: "MONTH",
    measure: "SPEND",
    comparison: "PREVIOUS_PERIOD",
    pending_policy: "EXCLUDE",
    refund_policy: "NET",
    transfer_policy: "EXCLUDE",
    filters: emptyFilters(),
    save_as: null,
  };
}

export function FinanceAnalysisView({
  accounts,
  transactions,
  spaces,
  scope,
  locale,
  onAskAbout,
}: {
  accounts: FinanceAccount[];
  transactions: FinanceTransaction[];
  spaces: FinanceSpace[];
  scope: "mine" | "household";
  locale: FinanceLocale;
  onAskAbout: (question: string) => void;
}) {
  const advancedCopy = getFinanceAdvancedStrings(locale);
  const copy = advancedCopy.analysis;
  const reviewCopy = advancedCopy.purchaseReview;
  const initialParams = useMemo(() => new URL(window.location.href).searchParams, []);
  const initialAnalysisID = initialParams.get("analysis");
  const initialTransactionID = initialParams.get("transaction");
  const defaultEnd = transactions.map((transaction) => transaction.canonical_date).sort().at(-1) ?? "";
  const selectedSpace = spaces[0] ?? null;
  const firstSpace = selectedSpace?.id ?? "";
  const selectionKey = spaces.map((space) => space.id).join(":");
  const scopeSpaceIDs = useMemo(() => new Set(spaces.map((space) => space.id)), [selectionKey]);
  const currenciesForScope = () => [...new Set(accounts.filter((account) => scopeSpaceIDs.has(account.space_id)).map((account) => account.currency))].sort();
  const firstCurrency = currenciesForScope()[0] ?? "";
  const [request, setRequest] = useState<FinanceAnalysisRequest>(() => requestFor(firstSpace, firstCurrency, defaultEnd, scope));
  const [filterText, setFilterText] = useState({ merchants: "", categories: "", transactionTypes: "", items: "", purposes: "", beneficiaries: "" });
  const [chartType, setChartType] = useState<"bars" | "line" | "donut">("bars");
  const [resultState, setResultState] = useState<ResultState>("idle");
  const [result, setResult] = useState<FinanceAnalysisResponse | null>(null);
  const [insightState, setInsightState] = useState<ResultState>("loading");
  const [insightRetryKey, setInsightRetryKey] = useState(0);
  const [categoryInsight, setCategoryInsight] = useState<FinanceAnalysisResponse | null>(null);
  const [utilityInsight, setUtilityInsight] = useState<FinanceAnalysisResponse | null>(null);
  const [findings, setFindings] = useState<FinanceFinding[]>([]);
  const [habits, setHabits] = useState<FinanceHabit[]>([]);
  const [latestReport, setLatestReport] = useState<FinanceCoachingReport | null>(null);
  const [savedViews, setSavedViews] = useState<FinanceSavedAnalysisView[]>([]);
  const [savedViewsError, setSavedViewsError] = useState(false);
  const [selectedHandles, setSelectedHandles] = useState<string[]>([]);
  const [evidenceState, setEvidenceState] = useState<EvidenceState>("idle");
  const [evidence, setEvidence] = useState<FinanceEvidenceDetail | null>(null);
  const [evidenceSource, setEvidenceSource] = useState<FinancePurchaseEvidence | null>(null);
  const [error, setError] = useState("");
  const spaceAccounts = accounts.filter((account) => scopeSpaceIDs.has(account.space_id) && account.currency === request.currency);
  const currencies = currenciesForScope();
  const filteredSavedViews = savedViews.filter((view) => view.space_id === request.space_id);
  const groupingOptions = Object.entries(copy.groupingValues).filter(([value]) => {
    const grouping = value as FinanceAnalysisGrouping;
    if (request.basis === "TRANSACTIONS") return !purchaseGroupings.has(grouping);
    return grouping !== "ACCOUNT";
  });
  const measureOptions = Object.entries(copy.measureValues).filter(([value]) => {
    if (value === "INCOME") return request.basis === "TRANSACTIONS";
    if (value === "MEAN_UNIT_PRICE") return request.basis !== "TRANSACTIONS";
    return true;
  });

  useEffect(() => {
    if (!selectedSpace) return;
    const controller = new AbortController();
    let active = true;
    setSavedViewsError(false);
    setInsightState("loading");
    const encodedSpaceID = encodeURIComponent(selectedSpace.id);
    const settingsRequest = api<FinanceSettings>("/finance/settings", { signal: controller.signal }, true, false);
    const viewsRequest = api<FinanceSavedAnalysisView[]>(
      `/finance/analysis/views?space_id=${encodedSpaceID}`,
      { signal: controller.signal },
      true,
      false,
    );
    const supportingRequest = Promise.all([
      api<FinanceFinding[]>(`/finance/opportunities?space_id=${encodedSpaceID}`, { signal: controller.signal }, true, false).catch(() => []),
      api<FinanceHabit[]>(`/finance/habits?space_id=${encodedSpaceID}`, { signal: controller.signal }, true, false).catch(() => []),
      api<FinanceCoachingReport[]>(`/finance/reports?space_id=${encodedSpaceID}&report_kind=DAILY&limit=1`, { signal: controller.signal }, true, false).catch(() => []),
    ]);
    const automaticInsightRequest = settingsRequest.then(async (settings) => {
      const householdToday = todayInTimeZone(settings.household_timezone);
      const endDate = defaultEnd || householdToday;
      const baseRequest = requestFor(selectedSpace.id, firstCurrency, endDate, scope);
      const categoryRequest: FinanceAnalysisRequest = {
        ...baseRequest,
        grouping: "CATEGORY",
        comparison: "PREVIOUS_PERIOD",
      };
      const utilityRequest: FinanceAnalysisRequest = {
        ...baseRequest,
        basis: "PURCHASE_LINES",
        grouping: "UTILITY",
        comparison: "NONE",
      };
      const [loadedCategories, loadedUtility] = await Promise.all([
        firstCurrency
          ? api<FinanceAnalysisResponse>("/finance/analysis", { method: "POST", signal: controller.signal, body: JSON.stringify(categoryRequest) }, true, false).catch(() => null)
          : Promise.resolve(null),
        firstCurrency
          ? api<FinanceAnalysisResponse>("/finance/analysis", { method: "POST", signal: controller.signal, body: JSON.stringify(utilityRequest) }, true, false).catch(() => null)
          : Promise.resolve(null),
      ]);
      return { baseRequest, loadedCategories, loadedUtility };
    });
    Promise.all([viewsRequest, supportingRequest, automaticInsightRequest])
      .then(([views, [loadedFindings, loadedHabits, loadedReports], automatic]) => {
        if (!active) return;
        setRequest((current) => current.space_id === selectedSpace.id && current.scope === scope && current.end_date
          ? current
          : automatic.baseRequest);
        const loaded = views.filter((view) => view.space_id === selectedSpace.id);
        setSavedViews(loaded);
        const linked = initialAnalysisID ? loaded.find((view) => view.id === initialAnalysisID) : null;
        if (linked) void execute(linked.request, true);
        setFindings(loadedFindings.filter((item) => item.space_id === selectedSpace.id));
        setHabits(loadedHabits.filter((item) => item.space_id === selectedSpace.id));
        setLatestReport(loadedReports.find((item) => item.space_id === selectedSpace.id) ?? null);
        setCategoryInsight(automatic.loadedCategories?.basis === "TRANSACTIONS" ? automatic.loadedCategories : null);
        setUtilityInsight(automatic.loadedUtility?.basis === "PURCHASE_LINES" ? automatic.loadedUtility : null);
        setInsightState("ready");
      })
      .catch((caught: unknown) => {
        if (!active || isAbortError(caught)) return;
        setSavedViewsError(true);
        setInsightState("error");
      });
    return () => {
      active = false;
      controller.abort();
    };
  }, [selectionKey, scope, insightRetryKey]);

  useEffect(() => {
    if (!initialTransactionID) return;
    void openEvidence(`transaction:${initialTransactionID}`);
  }, []);

  useEffect(() => {
    if (request.space_id === firstSpace && request.scope === scope) return;
    const nextSpace = spaces[0]?.id ?? "";
    const nextCurrency = currenciesForScope()[0] ?? "";
    setRequest(requestFor(nextSpace, nextCurrency, defaultEnd, scope));
    setResult(null);
    setResultState("idle");
  }, [selectionKey, scope]);

  function updateBasis(basis: FinanceAnalysisBasis) {
    setRequest((current) => {
      const grouping = basis === "TRANSACTIONS"
        ? (purchaseGroupings.has(current.grouping) ? "MONTH" : current.grouping)
        : (current.grouping === "ACCOUNT" ? "MONTH" : current.grouping);
      const measure = basis === "TRANSACTIONS"
        ? (current.measure === "MEAN_UNIT_PRICE" ? "SPEND" : current.measure)
        : (current.measure === "INCOME" ? "SPEND" : current.measure);
      return { ...current, basis, grouping, measure, filters: emptyFilters() };
    });
    setFilterText({ merchants: "", categories: "", transactionTypes: "", items: "", purposes: "", beneficiaries: "" });
  }

  function requestWithTextFilters(base: FinanceAnalysisRequest): FinanceAnalysisRequest {
    return {
      ...base,
      save_as: base.save_as?.trim() || null,
      filters: {
        ...base.filters,
        merchants: splitValues(filterText.merchants),
        categories: splitValues(filterText.categories),
        transaction_types: splitValues(filterText.transactionTypes),
        normalized_items: splitValues(filterText.items),
        purposes: splitValues(filterText.purposes),
        beneficiaries: splitValues(filterText.beneficiaries),
      },
    };
  }

  async function execute(nextRequest: FinanceAnalysisRequest, fromSaved = false) {
    if (resultState === "loading" || nextRequest.space_id !== firstSpace) return;
    const scopedRequest = { ...nextRequest, scope, space_id: firstSpace };
    const body = fromSaved ? { ...scopedRequest, save_as: null } : requestWithTextFilters(scopedRequest);
    setRequest(body);
    if (fromSaved) {
      setFilterText({
        merchants: body.filters.merchants.join(", "), categories: body.filters.categories.join(", "),
        transactionTypes: body.filters.transaction_types.join(", "), items: body.filters.normalized_items.join(", "),
        purposes: body.filters.purposes.join(", "), beneficiaries: body.filters.beneficiaries.join(", "),
      });
    }
    setResultState("loading");
    setError("");
    setSelectedHandles([]);
    setEvidence(null);
    setEvidenceSource(null);
    setEvidenceState("idle");
    try {
      const loaded = await api<FinanceAnalysisResponse>(
        "/finance/analysis",
        { method: "POST", body: JSON.stringify(body) },
        true,
        false,
      );
      if (loaded.basis !== body.basis || loaded.currency !== body.currency) throw new Error(copy.errorDetail);
      setResult(loaded);
      setResultState("ready");
      if (loaded.saved_view) {
        setSavedViews((current) => [loaded.saved_view!, ...current.filter((view) => view.id !== loaded.saved_view!.id)]);
        setRequest((current) => ({ ...current, save_as: null }));
        const url = new URL(window.location.href);
        url.searchParams.set("analysis", loaded.saved_view.id);
        window.history.replaceState({}, "", url);
      }
    } catch {
      setResultState("error");
      setError(copy.errorDetail);
    }
  }

  async function openEvidence(handle: string) {
    const [kind, ...recordParts] = handle.split(":");
    const recordID = recordParts.join(":");
    if (!recordID || (kind !== "transaction" && kind !== "purchase-line")) {
      setEvidenceState("error");
      return;
    }
    setEvidenceState("loading");
    setEvidence(null);
    setEvidenceSource(null);
    try {
      const loaded = await api<FinanceEvidenceDetail>(
        `/finance/analysis/evidence/${kind}/${encodeURIComponent(recordID)}`,
        {},
        true,
        false,
      );
      if (loaded.handle !== handle || !scopeSpaceIDs.has(loaded.space_id)) throw new Error(copy.evidenceError);
      setEvidence(loaded);
      if (loaded.kind === "purchase-line") {
        try {
          const source = await api<FinancePurchaseEvidence>(
            `/finance/purchases/evidence/${encodeURIComponent(loaded.source_evidence_id)}`,
            {},
            true,
            false,
          );
          if (source.space_id === loaded.space_id) setEvidenceSource(source);
        } catch {
          setEvidenceSource(null);
        }
      }
      setEvidenceState("ready");
    } catch {
      setEvidenceState("error");
    }
  }

  const comparisonByKey = new Map(result?.comparison_groups.map((group) => [group.key, group]) ?? []);
  const currentByKey = new Map(result?.groups.map((group) => [group.key, group]) ?? []);
  const rowKeys = [...new Set([...(result?.groups.map((group) => group.key) ?? []), ...(result?.comparison_groups.map((group) => group.key) ?? [])])];
  const chartMax = Math.max(1, ...rowKeys.flatMap((key) => [
    Math.abs(exactNumber(currentByKey.get(key)?.value ?? { numerator: 0, denominator: 1 })),
    Math.abs(exactNumber(comparisonByKey.get(key)?.value ?? { numerator: 0, denominator: 1 })),
  ]));
  const evidenceByHandle = new Map(result?.evidence.map((item) => [item.handle, item]) ?? []);
  const seriesFor = (byKey: Map<string, { value: { numerator: number; denominator: number } }>): SeriesPoint[] =>
    rowKeys.map((key) => {
      const value = byKey.get(key)?.value ?? { numerator: 0, denominator: 1 };
      return { key, label: displayGroupKey(key), value: exactNumber(value), display: formatExact(value, request.measure, result!.currency, locale) };
    });
  const chartSeries = result ? seriesFor(currentByKey) : [];
  const chartComparison = result && request.comparison !== "NONE" ? seriesFor(comparisonByKey) : [];
  const chartTypeLabels = locale === "de"
    ? { bars: "Balken", line: "Linie", donut: "Ring" }
    : { bars: "Bars", line: "Line", donut: "Donut" };

  function displayGroupKey(key: string) {
    if (key === "(unknown)") return copy.unknown;
    if (request.grouping === "ACCOUNT") return accounts.find((account) => account.id === key)?.label ?? copy.unknown;
    if (request.grouping === "LINE_KIND") return copy.lineKindValues[key as keyof typeof copy.lineKindValues] ?? key;
    if (request.grouping === "PLANNEDNESS") return reviewCopy.plannednessValues[key as keyof typeof reviewCopy.plannednessValues] ?? key;
    if (request.grouping === "UTILITY") return reviewCopy.utilityValues[key as keyof typeof reviewCopy.utilityValues] ?? key;
    if (request.grouping === "VALUE_FOR_MONEY") return reviewCopy.valueValues[key as keyof typeof reviewCopy.valueValues] ?? key;
    if (request.grouping === "DECISION_QUALITY") return reviewCopy.decisionValues[key as keyof typeof reviewCopy.decisionValues] ?? key;
    if (request.grouping === "OUTCOME") return reviewCopy.outcomeValues[key as keyof typeof reviewCopy.outcomeValues] ?? key;
    if (request.grouping === "ITEMISATION") return copy.itemisationValues[key as keyof typeof copy.itemisationValues] ?? key;
    return key;
  }

  function askAboutResult() {
    const contextLabel = locale === "de" ? "Auswertungskontext" : "Analysis context";
    const humanFilters = [
      request.filters.account_ids.length ? `${copy.accounts}: ${request.filters.account_ids.map((id) => accounts.find((account) => account.id === id)?.label ?? copy.unknown).join(", ")}` : "",
      request.filters.merchants.length ? `${copy.merchants}: ${request.filters.merchants.join(", ")}` : "",
      request.filters.categories.length ? `${copy.categories}: ${request.filters.categories.join(", ")}` : "",
      request.filters.transaction_types.length ? `${copy.transactionType}: ${request.filters.transaction_types.join(", ")}` : "",
      request.filters.line_kinds.length ? `${copy.lineKind}: ${request.filters.line_kinds.map((value) => copy.lineKindValues[value]).join(", ")}` : "",
      request.filters.normalized_items.length ? `${copy.items}: ${request.filters.normalized_items.join(", ")}` : "",
      request.filters.purposes.length ? `${copy.purposes}: ${request.filters.purposes.join(", ")}` : "",
      request.filters.beneficiaries.length ? `${copy.beneficiaries}: ${request.filters.beneficiaries.join(", ")}` : "",
      request.filters.plannedness.length ? `${copy.plannedness}: ${request.filters.plannedness.map((value) => reviewCopy.plannednessValues[value]).join(", ")}` : "",
      request.filters.utilities.length ? `${copy.utility}: ${request.filters.utilities.map((value) => reviewCopy.utilityValues[value]).join(", ")}` : "",
      request.filters.decision_qualities.length ? `${copy.decisionQuality}: ${request.filters.decision_qualities.map((value) => reviewCopy.decisionValues[value]).join(", ")}` : "",
      request.filters.value_for_money.length ? `${copy.value}: ${request.filters.value_for_money.map((value) => reviewCopy.valueValues[value]).join(", ")}` : "",
      request.filters.outcomes.length ? `${copy.outcome}: ${request.filters.outcomes.map((value) => reviewCopy.outcomeValues[value]).join(", ")}` : "",
      request.filters.itemisation.length ? `${copy.itemisation}: ${request.filters.itemisation.map((value) => copy.itemisationValues[value]).join(", ")}` : "",
    ].filter(Boolean);
    const filters = humanFilters.join("; ");
    onAskAbout([
      copy.askPrompt,
      "",
      `${contextLabel}: ${copy.basisValues[request.basis]}; ${request.start_date}–${request.end_date}; ${request.currency}; ${copy.measureValues[request.measure]}; ${copy.groupingValues[request.grouping]}; ${copy.comparisonValues[request.comparison]}${filters ? `; ${filters}` : ""}.`,
    ].join("\n"));
  }

  function runPreset(kind: "MONTH" | "CATEGORIES" | "ITEMS" | "RETURNS") {
    const endDate = request.end_date || defaultEnd;
    if (!endDate) return;
    const base = requestFor(request.space_id, request.currency, endDate, scope);
    const firstOfMonth = `${endDate.slice(0, 7)}-01`;
    const next: FinanceAnalysisRequest = kind === "MONTH"
      ? { ...base, start_date: firstOfMonth, comparison: "PREVIOUS_PERIOD", grouping: "WEEK" }
      : kind === "CATEGORIES"
        ? { ...base, grouping: "CATEGORY", comparison: "PREVIOUS_PERIOD" }
        : kind === "ITEMS"
          ? { ...base, basis: "PURCHASE_LINES", grouping: "ITEM", comparison: "PREVIOUS_PERIOD" }
          : { ...base, basis: "PURCHASE_LINES", grouping: "OUTCOME", comparison: "NONE", filters: { ...emptyFilters(), outcomes: ["returned", "regretted"] } };
    void execute(next, true);
  }

  const categoryCurrent = new Map(categoryInsight?.groups.map((group) => [group.key, exactNumber(group.value)]) ?? []);
  const categoryEarlier = new Map(categoryInsight?.comparison_groups.map((group) => [group.key, exactNumber(group.value)]) ?? []);
  const categoryChanges = [...new Set([...categoryCurrent.keys(), ...categoryEarlier.keys()])]
    .map((key) => ({
      key,
      current: categoryCurrent.get(key) ?? 0,
      earlier: categoryEarlier.get(key) ?? 0,
      delta: (categoryCurrent.get(key) ?? 0) - (categoryEarlier.get(key) ?? 0),
    }))
    .sort((left, right) => Math.abs(right.delta) - Math.abs(left.delta));
  const topChange = categoryChanges[0] ?? null;
  const aboveNormal = categoryChanges.filter((item) => item.delta > 0).slice(0, 3);
  const categoryLabel = (key: string) => key === "(unknown)"
    ? (locale === "de" ? "Nicht kategorisiert" : "Uncategorised")
    : key;
  const utilityByKey = new Map(utilityInsight?.groups.map((group) => [group.key, exactNumber(group.value)]) ?? []);
  const essentialMinor = utilityByKey.get("essential") ?? 0;
  const flexibleMinor = (utilityByKey.get("useful") ?? 0) + (utilityByKey.get("optional") ?? 0);
  const unclassifiedMinor = (utilityByKey.get("unclear") ?? 0) + (utilityByKey.get("unknown") ?? 0);
  const topFinding = [...findings]
    .filter((finding) => finding.status === "OPEN")
    .sort((left, right) => right.saving_high_minor - left.saving_high_minor || right.confidence_bps - left.confidence_bps)[0] ?? null;
  const realisedCurrency = habits.find((habit) => habit.realised_saving_minor > 0)?.currency ?? firstCurrency;
  const realisedMinor = habits
    .filter((habit) => habit.currency === realisedCurrency)
    .reduce((sum, habit) => sum + habit.realised_saving_minor, 0);
  const coverageBps = utilityInsight?.itemisation_coverage?.coverage_bps
    ?? latestReport?.itemised_coverage_bps
    ?? null;
  const safeSummary = record(latestReport?.summary.safe_to_spend);
  const safeMinor = finiteNumber(safeSummary?.amount_minor ?? latestReport?.summary.safe_to_spend_minor);
  const safeCurrency = typeof safeSummary?.currency === "string"
    ? safeSummary.currency
    : latestReport?.currency ?? firstCurrency;
  const trajectoryLabels = locale === "de"
    ? { ON_PLAN: "Im Plan", WATCH: "Im Blick behalten", OFF_PLAN: "Plan anpassen", UNKNOWN: "Beste aktuelle Schätzung" }
    : { ON_PLAN: "On plan", WATCH: "Worth watching", OFF_PLAN: "Plan needs attention", UNKNOWN: "Best current estimate" };
  const hasAutomaticInsight = Boolean(categoryInsight || utilityInsight || topFinding || habits.length || latestReport);

  return (
    <section className="finance-analysis-panel" aria-labelledby="finance-analysis-title">
      <header className="finance-analysis-heading"><div><span className="finance-status-label"><BarChart3 aria-hidden="true" size={15} /> {copy.title}</span><h2 id="finance-analysis-title">{copy.title}</h2><p>{copy.detail}</p></div></header>

      <section className="finance-insights-overview" aria-labelledby="finance-insights-overview-title">
        <header>
          <div>
            <h3 id="finance-insights-overview-title">{locale === "de" ? "Auf einen Blick" : "At a glance"}</h3>
            <p>{scope === "mine"
              ? (locale === "de" ? "Private Einträge plus bewusst geteilte Haushaltseinträge." : "Private records plus deliberately shared Household records.")
              : (locale === "de" ? "Nur bewusst geteilte Haushaltseinträge." : "Deliberately shared Household records only.")}</p>
          </div>
        </header>
        {insightState === "loading" ? (
          <div className="finance-analysis-skeleton" aria-busy="true" aria-label={locale === "de" ? "Einblicke werden berechnet" : "Working out insights"}><div /><div /><div /></div>
        ) : insightState === "error" || !hasAutomaticInsight ? (
          <div className={`finance-analysis-state${insightState === "error" ? " is-error" : ""}`} role={insightState === "error" ? "alert" : "status"}>
            {insightState === "error" ? <AlertCircle aria-hidden="true" size={22} /> : <BarChart3 aria-hidden="true" size={22} />}
            <div>
              <strong>{insightState === "error"
                ? (locale === "de" ? "Automatische Einblicke konnten nicht geladen werden" : "Automatic insights could not load")
                : (locale === "de" ? "Beste Sicht aus den bisherigen Einträgen" : "Best view from the money recorded so far")}</strong>
              <p>{insightState === "error"
                ? (locale === "de" ? "Gespeicherte Ansichten und die detaillierte Auswertung darunter bleiben verfügbar." : "Saved views and the detailed view below still work.")
                : (locale === "de" ? "Noch sticht keine klare Veränderung oder Sparmöglichkeit heraus. Die detaillierten Summen unten zeigen weiterhin den aktuellen Stand." : "No clear change or savings win stands out yet. The detailed totals below still show the current position.")}</p>
            </div>
            {insightState === "error" ? <button type="button" className="button button--secondary" onClick={() => setInsightRetryKey((key) => key + 1)}>{locale === "de" ? "Erneut versuchen" : "Try again"}</button> : null}
          </div>
        ) : (
          <>
            <div className="finance-insight-grid">
              <article>
                <span>{locale === "de" ? "Größte Veränderung" : "Top change"}</span>
                <strong>{topChange ? categoryLabel(topChange.key) : (locale === "de" ? "Aktuelle Ausgaben sind der Ausgangspunkt" : "Current spending is the baseline")}</strong>
                {topChange ? <small>{topChange.delta > 0 ? "+" : ""}{formatCurrency(Math.round(topChange.delta), categoryInsight?.currency ?? firstCurrency, locale)} {locale === "de" ? "zum vorherigen Zeitraum" : "vs previous period"}</small> : null}
              </article>
              <article>
                <span>{locale === "de" ? "Unverzichtbar und flexibel" : "Essential vs flexible"}</span>
                {utilityInsight ? <dl><div><dt>{locale === "de" ? "Unverzichtbar" : "Essential"}</dt><dd>{formatCurrency(Math.round(essentialMinor), utilityInsight.currency, locale)}</dd></div><div><dt>{locale === "de" ? "Nützlich oder optional" : "Useful or optional"}</dt><dd>{formatCurrency(Math.round(flexibleMinor), utilityInsight.currency, locale)}</dd></div>{unclassifiedMinor > 0 ? <div><dt>{locale === "de" ? "Nicht eingeordnet" : "Unclassified"}</dt><dd>{formatCurrency(Math.round(unclassifiedMinor), utilityInsight.currency, locale)}</dd></div> : null}</dl> : <small>{locale === "de" ? "Vorerst aus Umsatzkategorien geschätzt" : "Estimated from transaction categories for now"}</small>}
              </article>
              <article>
                <span>{locale === "de" ? "Lohnend zu ändern" : "Worth changing"}</span>
                <strong>{topFinding?.title ?? (locale === "de" ? "Keine klare Kürzung gefunden" : "No clear cut found")}</strong>
                {topFinding ? <small>{locale === "de" ? "Möglich" : "Possible"}: {formatCurrency(topFinding.saving_low_minor, topFinding.currency, locale)}–{formatCurrency(topFinding.saving_high_minor, topFinding.currency, locale)}</small> : null}
              </article>
              <article>
                <span>{locale === "de" ? "Bereits gespart" : "Savings realised"}</span>
                <strong>{realisedCurrency ? formatCurrency(realisedMinor, realisedCurrency, locale) : "—"}</strong>
                <small>{locale === "de" ? "aus überprüften Gewohnheiten" : "from reviewed habits"}</small>
              </article>
              <article>
                <span>{locale === "de" ? "Belegdetails" : "Receipt detail"}</span>
                <strong>{coverageBps == null ? "—" : new Intl.NumberFormat(locale === "de" ? "de-DE" : "en-GB", { style: "percent", maximumFractionDigits: 0 }).format(coverageBps / 10_000)}</strong>
                <small>{locale === "de" ? "Einkaufswert mit Artikeldetails" : "shopping spend with item details"}</small>
              </article>
              <article>
                <span>{locale === "de" ? "Ausblick" : "Outlook"}</span>
                <strong>{latestReport ? trajectoryLabels[latestReport.trajectory_status] : (locale === "de" ? "Noch kein Ausblick" : "No outlook yet")}</strong>
                {safeMinor !== null && safeCurrency ? <small>{locale === "de" ? "Sicher verfügbar" : "Safe to spend"}: {formatCurrency(safeMinor, safeCurrency, locale)}</small> : null}
              </article>
            </div>
            {aboveNormal.length ? (
              <section className="finance-insight-above-normal" aria-labelledby="finance-insight-above-normal-title">
                <h4 id="finance-insight-above-normal-title">{locale === "de" ? "Kategorien über dem vorherigen Zeitraum" : "Categories above the previous period"}</h4>
                <ol>{aboveNormal.map((item) => <li key={item.key}><span>{categoryLabel(item.key)}</span><strong>+{formatCurrency(Math.round(item.delta), categoryInsight?.currency ?? firstCurrency, locale)}</strong></li>)}</ol>
              </section>
            ) : null}
          </>
        )}
      </section>

      {selectedSpace && request.currency ? <FinanceNetWorthPanel spaceID={selectedSpace.id} currency={request.currency} accounts={accounts} locale={locale} onAskAbout={onAskAbout} /> : null}

      <div className="finance-analysis-saved" aria-labelledby="finance-analysis-saved-title">
        <h3 id="finance-analysis-saved-title"><Bookmark aria-hidden="true" size={17} /> {copy.savedViews}</h3>
        {savedViewsError ? <p>{copy.errorDetail}</p> : filteredSavedViews.length ? <div>{filteredSavedViews.map((view) => <button type="button" className="button button--secondary" key={view.id} onClick={() => void execute(view.request, true)} aria-label={`${copy.openSaved}: ${view.name}`}>{view.name}</button>)}</div> : <p>{copy.noSavedViews}</p>}
      </div>

      <div className="finance-analysis-presets" aria-label={locale === "de" ? "Nützliche Auswertungen" : "Useful views"}>
        <button type="button" onClick={() => runPreset("MONTH")}>{locale === "de" ? "Ausgaben diesen Monat" : "Spending this month"}</button>
        <button type="button" onClick={() => runPreset("CATEGORIES")}>{locale === "de" ? "Wohin das Geld ging" : "Where the money went"}</button>
        <button type="button" onClick={() => runPreset("ITEMS")}>{locale === "de" ? "Häufig gekaufte Artikel" : "Items bought most often"}</button>
        <button type="button" onClick={() => runPreset("RETURNS")}>{locale === "de" ? "Rückgaben und Fehlkäufe" : "Returns and regrets"}</button>
      </div>

      <form className="finance-analysis-form" onSubmit={(event: FormEvent) => { event.preventDefault(); void execute(request); }} aria-busy={resultState === "loading"}>
        <details className="finance-analysis-builder">
        <summary>{locale === "de" ? "Eigene Auswertung erstellen" : "Build a custom view"}</summary>
        <div className="finance-analysis-core-fields">
          <div className="field"><label htmlFor="finance-analysis-basis">{copy.basis}</label><select id="finance-analysis-basis" value={request.basis} onChange={(event) => updateBasis(event.target.value as FinanceAnalysisBasis)}>{Object.entries(copy.basisValues).map(([value, label]) => <option value={value} key={value}>{label}</option>)}</select></div>
          <div className="field"><label htmlFor="finance-analysis-from">{copy.startDate}</label><input id="finance-analysis-from" type="date" autoComplete="off" max={request.end_date} value={request.start_date} onChange={(event) => setRequest((current) => ({ ...current, start_date: event.target.value }))} required /></div>
          <div className="field"><label htmlFor="finance-analysis-to">{copy.endDate}</label><input id="finance-analysis-to" type="date" autoComplete="off" min={request.start_date} value={request.end_date} onChange={(event) => setRequest((current) => ({ ...current, end_date: event.target.value }))} required /></div>
          <div className="field"><label htmlFor="finance-analysis-currency">{copy.currency}</label><select id="finance-analysis-currency" value={request.currency} onChange={(event) => setRequest((current) => ({ ...current, currency: event.target.value, filters: { ...current.filters, account_ids: [] } }))}>{currencies.map((currency) => <option value={currency} key={currency}>{currency}</option>)}</select></div>
          <div className="field"><label htmlFor="finance-analysis-grouping">{copy.grouping}</label><select id="finance-analysis-grouping" value={request.grouping} onChange={(event) => setRequest((current) => ({ ...current, grouping: event.target.value as FinanceAnalysisGrouping }))}>{groupingOptions.map(([value, label]) => <option value={value} key={value}>{label}</option>)}</select></div>
          <div className="field"><label htmlFor="finance-analysis-measure">{copy.measure}</label><select id="finance-analysis-measure" value={request.measure} onChange={(event) => setRequest((current) => ({ ...current, measure: event.target.value as FinanceAnalysisMeasure }))}>{measureOptions.map(([value, label]) => <option value={value} key={value}>{label}</option>)}</select></div>
          <div className="field"><label htmlFor="finance-analysis-comparison">{copy.comparison}</label><select id="finance-analysis-comparison" value={request.comparison} onChange={(event) => setRequest((current) => ({ ...current, comparison: event.target.value as FinanceAnalysisComparison }))}>{Object.entries(copy.comparisonValues).map(([value, label]) => <option value={value} key={value}>{label}</option>)}</select></div>
        </div>

        <details className="finance-analysis-filters"><summary>{copy.filters}</summary><div className="finance-analysis-filter-grid">
          {request.basis === "TRANSACTIONS" ? <div className="field"><label htmlFor="finance-analysis-account">{copy.accounts}</label><select id="finance-analysis-account" value={request.filters.account_ids[0] ?? ""} onChange={(event) => setRequest((current) => ({ ...current, filters: { ...current.filters, account_ids: event.target.value ? [event.target.value] : [] } }))}><option value="">—</option>{spaceAccounts.map((account) => <option value={account.id} key={account.id}>{account.label}</option>)}</select></div> : null}
          <div className="field"><label htmlFor="finance-analysis-merchants">{copy.merchants}</label><input id="finance-analysis-merchants" autoComplete="off" value={filterText.merchants} onChange={(event) => setFilterText((current) => ({ ...current, merchants: event.target.value }))} /><small>{copy.commaHint}</small></div>
          <div className="field"><label htmlFor="finance-analysis-categories">{copy.categories}</label><input id="finance-analysis-categories" autoComplete="off" value={filterText.categories} onChange={(event) => setFilterText((current) => ({ ...current, categories: event.target.value }))} /><small>{copy.commaHint}</small></div>
          {request.basis === "TRANSACTIONS" ? <div className="field"><label htmlFor="finance-analysis-transaction-types">{copy.transactionType}</label><input id="finance-analysis-transaction-types" autoComplete="off" value={filterText.transactionTypes} onChange={(event) => setFilterText((current) => ({ ...current, transactionTypes: event.target.value }))} /><small>{copy.commaHint}</small></div> : <>
            <div className="field"><label htmlFor="finance-analysis-items">{copy.items}</label><input id="finance-analysis-items" autoComplete="off" value={filterText.items} onChange={(event) => setFilterText((current) => ({ ...current, items: event.target.value }))} /><small>{copy.commaHint}</small></div>
            <div className="field"><label htmlFor="finance-analysis-purposes">{copy.purposes}</label><input id="finance-analysis-purposes" autoComplete="off" value={filterText.purposes} onChange={(event) => setFilterText((current) => ({ ...current, purposes: event.target.value }))} /><small>{copy.commaHint}</small></div>
            <div className="field"><label htmlFor="finance-analysis-beneficiaries">{copy.beneficiaries}</label><input id="finance-analysis-beneficiaries" autoComplete="off" value={filterText.beneficiaries} onChange={(event) => setFilterText((current) => ({ ...current, beneficiaries: event.target.value }))} /><small>{copy.commaHint}</small></div>
            <div className="field"><label htmlFor="finance-analysis-line-kind">{copy.lineKind}</label><select id="finance-analysis-line-kind" value={request.filters.line_kinds[0] ?? ""} onChange={(event) => setRequest((current) => ({ ...current, filters: { ...current.filters, line_kinds: event.target.value ? [event.target.value as FinanceAnalysisFilters["line_kinds"][number]] : [] } }))}><option value="">—</option>{Object.entries(copy.lineKindValues).map(([value, label]) => <option value={value} key={value}>{label}</option>)}</select></div>
            <div className="field"><label htmlFor="finance-analysis-plannedness">{copy.plannedness}</label><select id="finance-analysis-plannedness" value={request.filters.plannedness[0] ?? ""} onChange={(event) => setRequest((current) => ({ ...current, filters: { ...current.filters, plannedness: event.target.value ? [event.target.value as FinanceAnalysisFilters["plannedness"][number]] : [] } }))}><option value="">—</option>{Object.entries(reviewCopy.plannednessValues).map(([value, label]) => <option value={value} key={value}>{label}</option>)}</select></div>
            <div className="field"><label htmlFor="finance-analysis-utility">{copy.utility}</label><select id="finance-analysis-utility" value={request.filters.utilities[0] ?? ""} onChange={(event) => setRequest((current) => ({ ...current, filters: { ...current.filters, utilities: event.target.value ? [event.target.value as FinanceAnalysisFilters["utilities"][number]] : [] } }))}><option value="">—</option>{Object.entries(reviewCopy.utilityValues).map(([value, label]) => <option value={value} key={value}>{label}</option>)}</select></div>
            <div className="field"><label htmlFor="finance-analysis-quality">{copy.decisionQuality}</label><select id="finance-analysis-quality" value={request.filters.decision_qualities[0] ?? ""} onChange={(event) => setRequest((current) => ({ ...current, filters: { ...current.filters, decision_qualities: event.target.value ? [event.target.value as FinanceAnalysisFilters["decision_qualities"][number]] : [] } }))}><option value="">—</option>{Object.entries(reviewCopy.decisionValues).map(([value, label]) => <option value={value} key={value}>{label}</option>)}</select></div>
            <div className="field"><label htmlFor="finance-analysis-value">{copy.value}</label><select id="finance-analysis-value" value={request.filters.value_for_money[0] ?? ""} onChange={(event) => setRequest((current) => ({ ...current, filters: { ...current.filters, value_for_money: event.target.value ? [event.target.value as FinanceAnalysisFilters["value_for_money"][number]] : [] } }))}><option value="">—</option>{Object.entries(reviewCopy.valueValues).map(([value, label]) => <option value={value} key={value}>{label}</option>)}</select></div>
            <div className="field"><label htmlFor="finance-analysis-outcome">{copy.outcome}</label><select id="finance-analysis-outcome" value={request.filters.outcomes[0] ?? ""} onChange={(event) => setRequest((current) => ({ ...current, filters: { ...current.filters, outcomes: event.target.value ? [event.target.value as FinanceAnalysisFilters["outcomes"][number]] : [] } }))}><option value="">—</option>{Object.entries(reviewCopy.outcomeValues).map(([value, label]) => <option value={value} key={value}>{label}</option>)}</select></div>
            <div className="field"><label htmlFor="finance-analysis-itemisation">{copy.itemisation}</label><select id="finance-analysis-itemisation" value={request.filters.itemisation[0] ?? ""} onChange={(event) => setRequest((current) => ({ ...current, filters: { ...current.filters, itemisation: event.target.value ? [event.target.value as FinanceAnalysisFilters["itemisation"][number]] : [] } }))}><option value="">—</option>{Object.entries(copy.itemisationValues).map(([value, label]) => <option value={value} key={value}>{label}</option>)}</select></div>
          </>}
        </div><div className="finance-analysis-policy-grid">
          <label><input type="checkbox" checked={request.pending_policy === "INCLUDE"} onChange={(event) => setRequest((current) => ({ ...current, pending_policy: event.target.checked ? "INCLUDE" : "EXCLUDE" }))} /> {copy.includePending}</label>
          <label><input type="checkbox" checked={request.refund_policy === "EXCLUDE"} onChange={(event) => setRequest((current) => ({ ...current, refund_policy: event.target.checked ? "EXCLUDE" : "NET" }))} /> {copy.excludeRefunds}</label>
          <label><input type="checkbox" checked={request.transfer_policy === "INCLUDE"} onChange={(event) => setRequest((current) => ({ ...current, transfer_policy: event.target.checked ? "INCLUDE" : "EXCLUDE" }))} /> {copy.includeTransfers}</label>
        </div></details>
        <div className="finance-analysis-actions"><div className="field"><label htmlFor="finance-analysis-save">{copy.saveAs}</label><input id="finance-analysis-save" autoComplete="off" maxLength={120} value={request.save_as ?? ""} onChange={(event) => setRequest((current) => ({ ...current, save_as: event.target.value || null }))} /></div><button type="submit" className="button button--primary" disabled={resultState === "loading" || !request.space_id || !request.currency}><Play aria-hidden="true" size={17} /> {resultState === "loading" ? copy.running : copy.run}</button></div>
        </details>
      </form>

      {resultState === "loading" && !result ? <div className="finance-analysis-skeleton" aria-busy="true" aria-label={copy.running}><div /><div /><div /></div> : null}
      {resultState === "error" ? <div className="finance-analysis-state is-error" role="alert"><AlertCircle aria-hidden="true" size={22} /><div><strong>{copy.errorTitle}</strong><p>{error}</p></div></div> : null}
      {resultState === "idle" && !result ? <div className="finance-analysis-state"><BarChart3 aria-hidden="true" size={26} /><div><strong>{copy.initialTitle}</strong><p>{copy.initialDetail}</p></div></div> : null}

      {result ? <div className="finance-analysis-results">
        <div className="finance-analysis-summary">
          <article><span>{copy.total}</span><strong><ExactDisplay value={result.total} measure={request.measure} currency={result.currency} locale={locale} /></strong><small>{result.data_through ? `${copy.dataThrough}: ${formatDate(result.data_through, locale)}` : ""}</small></article>
          {result.comparison_total ? <article><span>{copy.earlierTotal}</span><strong><ExactDisplay value={result.comparison_total} measure={request.measure} currency={result.currency} locale={locale} /></strong><small>{result.comparison_start_date && result.comparison_end_date ? `${formatDate(result.comparison_start_date, locale)}–${formatDate(result.comparison_end_date, locale)}` : ""}</small></article> : null}
          {result.itemisation_coverage ? <article><span>{copy.coverage}</span><strong>{new Intl.NumberFormat(locale === "de" ? "de-DE" : "en-GB", { style: "percent", maximumFractionDigits: 1 }).format(result.itemisation_coverage.coverage_bps / 10_000)}</strong><small>{formatCurrency(result.itemisation_coverage.itemised_minor, result.currency, locale)} / {formatCurrency(result.itemisation_coverage.eligible_minor, result.currency, locale)} {copy.coverageDetail}</small></article> : null}
        </div>
        {result.saved_view ? <p className="finance-analysis-saved-notice" role="status"><CheckCircle2 aria-hidden="true" size={17} /> {copy.savedNotice}: {result.saved_view.name}</p> : null}

        {rowKeys.length ? <>
          <div className="finance-chart-switch" role="group" aria-label={locale === "de" ? "Diagrammtyp wählen" : "Choose chart type"}>
            {(["bars", "line", "donut"] as const).map((option) => (
              <button type="button" key={option} className={chartType === option ? "is-active" : undefined} aria-pressed={chartType === option} onClick={() => setChartType(option)}>{chartTypeLabels[option]}</button>
            ))}
          </div>
          {chartType === "line" ? (
            <SeriesLine series={chartSeries} comparison={chartComparison.length ? chartComparison : undefined} ariaLabel={`${copy.title}: ${copy.current}${chartComparison.length ? ` / ${copy.earlier}` : ""}`} />
          ) : chartType === "donut" ? (
            <Donut series={chartSeries} locale={locale} ariaLabel={`${copy.title}: ${copy.current}`} />
          ) : (
          <div className="finance-analysis-chart" aria-label={`${copy.current} / ${copy.earlier}`}>{rowKeys.map((key) => {
            const current = currentByKey.get(key);
            const earlier = comparisonByKey.get(key);
            const currentSize = Math.abs(exactNumber(current?.value ?? { numerator: 0, denominator: 1 })) / chartMax * 100;
            const earlierSize = Math.abs(exactNumber(earlier?.value ?? { numerator: 0, denominator: 1 })) / chartMax * 100;
            return <div className="finance-analysis-chart-row" key={key}><strong>{displayGroupKey(key)}</strong><div><span>{copy.current}</span><i className="is-current" style={{ "--finance-bar-size": `${currentSize}%` } as CSSProperties} /><b className="finance-bar-value"><ExactDisplay value={current?.value ?? { numerator: 0, denominator: 1 }} measure={request.measure} currency={result.currency} locale={locale} /></b></div>{request.comparison !== "NONE" ? <div><span>{copy.earlier}</span><i className="is-earlier" style={{ "--finance-bar-size": `${earlierSize}%` } as CSSProperties} /><b className="finance-bar-value"><ExactDisplay value={earlier?.value ?? { numerator: 0, denominator: 1 }} measure={request.measure} currency={result.currency} locale={locale} /></b></div> : null}</div>;
          })}</div>
          )}
          <div className="finance-analysis-table-scroll" tabIndex={0} role="region" aria-label={locale === "de" ? "Auswertungstabelle; horizontal scrollbar" : "Analysis table; scroll horizontally for more columns"}><table><thead><tr><th>{copy.group}</th><th>{copy.valueHeader}</th>{request.comparison !== "NONE" ? <th>{copy.comparisonHeader}</th> : null}<th>{copy.currentRecords}</th>{request.comparison !== "NONE" ? <th>{copy.earlierRecords}</th> : null}<th>{copy.evidence}</th></tr></thead><tbody>{rowKeys.map((key) => {
            const current = currentByKey.get(key);
            const earlier = comparisonByKey.get(key);
            const handles = [...new Set([...(current?.evidence_handles ?? []), ...(earlier?.evidence_handles ?? [])])];
            return <tr key={key}><th scope="row">{displayGroupKey(key)}</th><td><ExactDisplay value={current?.value ?? { numerator: 0, denominator: 1 }} measure={request.measure} currency={result.currency} locale={locale} /></td>{request.comparison !== "NONE" ? <td><ExactDisplay value={earlier?.value ?? { numerator: 0, denominator: 1 }} measure={request.measure} currency={result.currency} locale={locale} /></td> : null}<td>{current?.record_count ?? 0}</td>{request.comparison !== "NONE" ? <td>{earlier?.record_count ?? 0}</td> : null}<td><button type="button" className="button button--secondary" disabled={!handles.length} onClick={() => { setSelectedHandles(handles); setEvidence(null); setEvidenceSource(null); setEvidenceState("idle"); }}>{copy.viewEvidence}</button></td></tr>;
          })}</tbody></table></div>
        </> : <p className="finance-analysis-no-groups">{copy.noGroups}</p>}
        <button type="button" className="button button--primary finance-analysis-ask" onClick={askAboutResult}><MessageCircleMore aria-hidden="true" size={17} /> {copy.ask}</button>
      </div> : null}

      {selectedHandles.length || evidenceState !== "idle" ? <aside className="finance-analysis-evidence" aria-labelledby="finance-analysis-evidence-title">
        <header><div><h3 id="finance-analysis-evidence-title"><FileSearch aria-hidden="true" size={18} /> {copy.evidenceTitle}</h3><p>{copy.evidenceDetail}</p></div><button type="button" className="button button--secondary" onClick={() => { setSelectedHandles([]); setEvidence(null); setEvidenceSource(null); setEvidenceState("idle"); }}>{copy.close}</button></header>
        {selectedHandles.length ? <div className="finance-analysis-evidence-links">{selectedHandles.map((handle, index) => { const item = evidenceByHandle.get(handle); return <button type="button" key={handle} className="button button--secondary" onClick={() => void openEvidence(handle)}>{item?.kind === "purchase-line" ? copy.basisValues.PURCHASE_LINES : copy.basisValues.TRANSACTIONS} {index + 1} <ChevronRight aria-hidden="true" size={16} /></button>; })}</div> : null}
        {evidenceState === "loading" ? <div className="finance-analysis-evidence-skeleton" aria-busy="true" aria-label={copy.evidenceLoading}><div /><div /></div> : evidenceState === "error" ? <p className="form-error" role="alert">{copy.evidenceError}</p> : evidence ? <article><span>{copy.sourceRecord}</span><strong>{evidence.source_description}</strong><dl><div><dt>{copy.valueHeader}</dt><dd>{formatCurrency(evidence.amount_minor, evidence.currency, locale)}</dd></div><div><dt>{copy.dataThrough}</dt><dd>{formatDate(evidence.occurred_on, locale)}</dd></div></dl><div className="finance-analysis-evidence-actions"><a className="button button--secondary" href={evidence.deep_link}>{copy.openRecord}</a>{evidenceSource?.files?.map((file) => <a className="button button--secondary" key={file.id} href={`/api/finance/purchases/evidence/${encodeURIComponent(evidenceSource.id)}/files/${encodeURIComponent(file.id)}`} target="_blank" rel="noreferrer">{locale === "de" ? "Original öffnen" : "Open original"}: {file.filename}</a>)}</div><FinanceDeliveryCalendarAction sourceID={evidence.source_evidence_id} sourceSpaceID={evidence.space_id} sourceKind={evidence.source_kind} lineKind={evidence.line_kind} description={evidence.source_description} spaces={spaces} locale={locale} /></article> : !selectedHandles.length ? <p>{copy.evidenceEmpty}</p> : null}
      </aside> : null}
    </section>
  );
}
