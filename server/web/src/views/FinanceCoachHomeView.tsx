import {
  AlertCircle,
  CalendarClock,
  ChevronDown,
  Lightbulb,
  RefreshCw,
  Repeat2,
  ShieldCheck,
  ShoppingBag,
} from "lucide-react";
import { useEffect, useRef, useState } from "react";

import { api } from "../api";
import { Donut, type SeriesPoint } from "../components/FinanceCharts";
import { getFinanceAdultStrings } from "../financeAdultStrings";
import type { FinanceLocale } from "../financeStrings";
import type {
  FinanceAnalysisFilters,
  FinanceAnalysisGroup,
  FinanceAnalysisResponse,
  FinanceCoachingReport,
  FinanceCommitment,
  FinanceFinding,
  FinanceGoal,
  FinanceHabit,
  FinancePurchaseException,
  FinanceReportPreference,
  FinanceSpace,
} from "../types";

type LoadState = "loading" | "ready" | "error";

function isAbortError(error: unknown) {
  return error instanceof DOMException && error.name === "AbortError";
}

function formatCurrency(minor: number, currency: string, locale: FinanceLocale) {
  return new Intl.NumberFormat(locale === "de" ? "de-DE" : "en-GB", {
    style: "currency",
    currency,
  }).format(minor / 100);
}

function findingObservation(finding: FinanceFinding, locale: FinanceLocale) {
  const amount = (key: string) => {
    const value = finding.baseline[key];
    return typeof value === "number" && Number.isFinite(value)
      ? formatCurrency(value, finding.currency, locale)
      : null;
  };
  if (finding.finding_type === "TREND_CHANGE") {
    const recent = amount("recent_minor");
    const prior = amount("prior_minor");
    const lastYear = amount("same_period_last_year_minor");
    const baseline = amount("baseline_90_day_minor");
    if (recent && prior && lastYear && baseline) {
      return locale === "de"
        ? `Die letzten 90 Tage ergeben ${recent}. Zuvor waren es ${prior}, im gleichen Zeitraum des Vorjahres ${lastYear}; der übliche Vergleichswert liegt bei ${baseline}.`
        : `The last 90 days total ${recent}. The previous period was ${prior}, the same period last year was ${lastYear}, and the usual comparison is ${baseline}.`;
    }
  }
  if (finding.finding_type === "SEASONAL") {
    const peak = amount("peak_minor");
    const typical = amount("typical_other_month_minor");
    const months = Array.isArray(finding.baseline.peak_months)
      ? finding.baseline.peak_months
        .filter((value): value is number => typeof value === "number" && Number.isInteger(value))
        .join(", ")
      : "";
    if (peak && typical && months) {
      return locale === "de"
        ? `In den Monaten ${months} sind es insgesamt ${peak}, sonst normalerweise ${typical}.`
        : `Months ${months} total ${peak}, compared with ${typical} in a typical month.`;
    }
  }
  if (finding.finding_type === "PRICE_DRIFT") {
    const first = amount("first_unit_price_minor");
    const latest = amount("latest_unit_price_minor");
    if (first && latest) {
      return locale === "de"
        ? `Der beobachtete Stückpreis ist von ${first} auf ${latest} gestiegen.`
        : `The observed unit price rose from ${first} to ${latest}.`;
    }
  }
  if (finding.finding_type === "REPEATED_ONE_OFF") {
    const annual = amount("annualised_minor");
    if (annual) {
      return locale === "de"
        ? `Diese unregelmäßigen Zahlungen ergeben inzwischen etwa ${annual} pro Jahr.`
        : `These irregular payments now add up to about ${annual} a year.`;
    }
  }
  if (finding.finding_type === "ANNUALISED_SMALL_COST") {
    const annual = amount("annualised_minor");
    const count = finding.baseline.payment_count;
    if (annual && typeof count === "number" && Number.isFinite(count)) {
      return locale === "de"
        ? `${count} kleine Zahlungen ergeben zusammen etwa ${annual} pro Jahr.`
        : `${count} small payments add up to about ${annual} a year.`;
    }
  }
  if (/minor[- ]units?/i.test(finding.observation)) {
    return locale === "de"
      ? "Öffne die gespeicherten Details für den vollständigen Vergleich."
      : "Open the saved details for the full comparison.";
  }
  return finding.observation;
}

function formatDate(value: string, locale: FinanceLocale) {
  const date = new Date(`${value}T12:00:00Z`);
  return Number.isNaN(date.valueOf())
    ? value
    : new Intl.DateTimeFormat(locale === "de" ? "de-DE" : "en-GB", {
        dateStyle: "medium",
        timeZone: "UTC",
      }).format(date);
}

function record(value: unknown): Record<string, unknown> | null {
  return value !== null && typeof value === "object" && !Array.isArray(value)
    ? (value as Record<string, unknown>)
    : null;
}

function number(value: unknown) {
  return typeof value === "number" && Number.isFinite(value) ? value : null;
}

function string(value: unknown) {
  return typeof value === "string" && value.trim() ? value : null;
}

function analysisFilters(): FinanceAnalysisFilters {
  return {
    account_ids: [], merchants: [], categories: [], transaction_types: [], line_kinds: [],
    normalized_items: [], purposes: [], beneficiaries: [], plannedness: [], utilities: [],
    decision_qualities: [], value_for_money: [], outcomes: [], itemisation: [],
  };
}

function shiftDate(iso: string, days: number): string {
  const date = new Date(`${iso}T00:00:00Z`);
  if (Number.isNaN(date.valueOf())) return iso;
  date.setUTCDate(date.getUTCDate() + days);
  return date.toISOString().slice(0, 10);
}

// Keep missing classification separate from the genuine long tail. Folding both
// into "everything else" makes weak source data look like a real spend category.
function categoryBreakdown(
  groups: FinanceAnalysisGroup[],
  currency: string,
  locale: FinanceLocale,
  unknownLabel: string,
  restLabel: string,
): { series: SeriesPoint[]; coverageBps: number; showDonut: boolean } {
  const scaled = groups
    .map((group) => ({ key: group.key, minor: Math.abs(Math.round(group.value.numerator / (group.value.denominator || 1))) }))
    .filter((entry) => entry.minor > 0)
    .sort((left, right) => right.minor - left.minor);
  const known = scaled.filter((entry) => entry.key !== "(unknown)");
  const unknownMinor = scaled.filter((entry) => entry.key === "(unknown)").reduce((sum, entry) => sum + entry.minor, 0);
  const top = known.slice(0, 5);
  const restMinor = known.slice(5).reduce((sum, entry) => sum + entry.minor, 0);
  const points: SeriesPoint[] = top.map((entry) => ({
    key: entry.key,
    label: entry.key,
    value: entry.minor,
    display: formatCurrency(entry.minor, currency, locale),
  }));
  if (restMinor > 0) {
    points.push({ key: "__rest__", label: restLabel, value: restMinor, display: formatCurrency(restMinor, currency, locale) });
  }
  if (unknownMinor > 0) {
    points.push({ key: "(unknown)", label: unknownLabel, value: unknownMinor, display: formatCurrency(unknownMinor, currency, locale) });
  }
  points.sort((left, right) => right.value - left.value);
  const totalMinor = scaled.reduce((sum, entry) => sum + entry.minor, 0);
  const coverageBps = totalMinor > 0 ? Math.max(0, Math.round((totalMinor - unknownMinor) / totalMinor * 10_000)) : 0;
  const knownCategories = known.length;
  return { series: points, coverageBps, showDonut: coverageBps >= 6_000 && knownCategories >= 2 };
}

function safeFromReport(report: FinanceCoachingReport | null) {
  if (!report) return { amount: null, low: null, high: null, currency: null };
  const nested = record(report.summary.safe_to_spend);
  return {
    amount: number(nested?.amount_minor ?? report.summary.safe_to_spend_minor),
    low: number(nested?.low_minor ?? report.summary.safe_to_spend_low_minor),
    high: number(nested?.high_minor ?? report.summary.safe_to_spend_high_minor),
    currency: string(nested?.currency ?? report.summary.currency),
  };
}

function clearActionLink() {
  const url = new URL(window.location.href);
  url.searchParams.delete("action");
  window.history.replaceState({}, "", url);
}

export function FinanceCoachHomeView({
  spaces,
  scope,
  commitments,
  goals,
  locale,
}: {
  spaces: FinanceSpace[];
  scope: "mine" | "household";
  commitments: FinanceCommitment[];
  goals: FinanceGoal[];
  locale: FinanceLocale;
}) {
  const copy = getFinanceAdultStrings(locale).coach;
  const calm = locale === "de" ? {
    moneyNow: "Geld im Moment",
    needsAttention: "Zu erledigen",
    availableAfterCommitments: "Nach festen Ausgaben verfügbar",
    nextBill: "Nächste Rechnung",
    conclusion: "Kurz gesagt",
    noProtectedCost: "Als Nächstes steht keine große Rechnung an.",
    oneAction: "Eine Sache diesen Monat erledigen",
    moved: "Ich habe es überwiesen",
    saving: "Wird gespeichert…",
    saved: "Erledigt. HausKlar prüft erneut, sobald die Bankdaten aktualisiert sind.",
    actionError: "Das konnte nicht gespeichert werden. Versuche es noch einmal.",
    decision: "Was möchtest du tun?",
    keep: "Beibehalten",
    adjust: "Anpassen",
    stop: "Beenden",
    difficulty: "Wie schwierig war es?",
    saveReview: "Prüfung speichern",
    more: "Mehr anzeigen",
    moreDetail: "Was du ausgeben kannst, Sparen, Gewohnheiten und mehr",
    currentRoom: "Was du ausgeben kannst",
    noCurrentRoom: "Noch kein Betrag zum Ausgeben berechnet.",
    weekly: "Wöchentlicher Haushalts-Check",
    weeklyDetail: "Der letzte ruhige Rückblick für die gemeinsamen Finanzen.",
    openDetails: "Finanzdetails öffnen",
  } : {
    moneyNow: "Money now",
    needsAttention: "Needs attention",
    availableAfterCommitments: "Available after commitments",
    nextBill: "Next bill",
    conclusion: "In short",
    noProtectedCost: "No big bill is coming up next.",
    oneAction: "One thing to finish this month",
    moved: "I've moved it",
    saving: "Saving…",
    saved: "Marked done. HausKlar will check again after the bank updates.",
    actionError: "That could not be saved. Try once more.",
    decision: "What should happen next?",
    keep: "Keep it",
    adjust: "Adjust it",
    stop: "Stop it",
    difficulty: "How difficult was it?",
    saveReview: "Save review",
    more: "Show more",
    moreDetail: "What you can spend, saving, habits and more",
    currentRoom: "What you can spend",
    noCurrentRoom: "No amount to spend is worked out yet.",
    weekly: "Weekly Household Finance check",
    weeklyDetail: "The latest quiet check of the shared finances.",
    openDetails: "Open Finance details",
  };
  const [state, setState] = useState<LoadState>("loading");
  const selectedSpace = spaces[0] ?? null;
  const spaceID = selectedSpace?.id ?? "";
  const [retryKey, setRetryKey] = useState(0);
  const [reports, setReports] = useState<FinanceCoachingReport[]>([]);
  const [weeklyReports, setWeeklyReports] = useState<FinanceCoachingReport[]>([]);
  const [preferences, setPreferences] = useState<FinanceReportPreference[]>([]);
  const [habits, setHabits] = useState<FinanceHabit[]>([]);
  const [findings, setFindings] = useState<FinanceFinding[]>([]);
  const [unresolved, setUnresolved] = useState<FinancePurchaseException[]>([]);
  const [refreshing, setRefreshing] = useState(false);
  const [refreshError, setRefreshError] = useState("");
  const [categoryGroups, setCategoryGroups] = useState<FinanceAnalysisGroup[]>([]);
  const [categoryCurrency, setCategoryCurrency] = useState("GBP");
  const [actionBusy, setActionBusy] = useState(false);
  const [actionError, setActionError] = useState("");
  const [actionNotice, setActionNotice] = useState("");
  const [habitDecision, setHabitDecision] = useState<"KEEP" | "ADJUST" | "STOP">("KEEP");
  const [friction, setFriction] = useState("1");
  const actionCardRef = useRef<HTMLElement>(null);
  const actionErrorRef = useRef<HTMLParagraphElement>(null);
  const selectionKey = selectedSpace?.id ?? "";

  useEffect(() => {
    const controller = new AbortController();
    let active = true;
    setState("loading");
    setRefreshError("");
    Promise.all(
      spaces.slice(0, 1).map(async (space) => {
        const encodedSpaceID = encodeURIComponent(space.id);
        const [spaceReports, spaceWeekly, spacePreference, spaceHabits, spaceFindings, spaceUnresolved] = await Promise.all([
          api<FinanceCoachingReport[]>(`/finance/reports?space_id=${encodedSpaceID}&report_kind=DAILY&limit=1`, { signal: controller.signal }, true, false),
          space.kind === "household"
            ? api<FinanceCoachingReport[]>(`/finance/reports?space_id=${encodedSpaceID}&report_kind=WEEKLY&limit=1`, { signal: controller.signal }, true, false)
                .catch((error: unknown) => { if (isAbortError(error)) throw error; return []; })
            : Promise.resolve([] as FinanceCoachingReport[]),
          api<FinanceReportPreference>(`/finance/report-preferences?space_id=${encodedSpaceID}`, { signal: controller.signal }, true, false)
            .catch((error: unknown) => { if (isAbortError(error)) throw error; return null; }),
          api<FinanceHabit[]>(`/finance/habits?space_id=${encodedSpaceID}`, { signal: controller.signal }, true, false)
            .catch((error: unknown) => { if (isAbortError(error)) throw error; return []; }),
          api<FinanceFinding[]>(`/finance/opportunities?space_id=${encodedSpaceID}`, { signal: controller.signal }, true, false)
            .catch((error: unknown) => { if (isAbortError(error)) throw error; return []; }),
          api<FinancePurchaseException[]>(`/finance/purchases/inbox?space_id=${encodedSpaceID}&offset=0&limit=3`, { signal: controller.signal }, true, false)
            .catch((error: unknown) => { if (isAbortError(error)) throw error; return []; }),
        ]);
        return { spaceReports, spaceWeekly, spacePreference, spaceHabits, spaceFindings, spaceUnresolved };
      }),
    )
      .then((results) => {
        if (!active) return;
        const loadedReports = results
          .flatMap((result) => result.spaceReports)
          .filter((item) => item.space_id === spaceID);
        setReports(loadedReports);
        setWeeklyReports(results.flatMap((result) => result.spaceWeekly).filter((item) => item.space_id === spaceID));
        setPreferences(results.map((result) => result.spacePreference).filter((item): item is FinanceReportPreference => item !== null && item.space_id === spaceID));
        setHabits(results.flatMap((result) => result.spaceHabits).filter((item) => item.space_id === spaceID));
        setFindings(results.flatMap((result) => result.spaceFindings).filter((item) => item.space_id === spaceID));
        setUnresolved(results.flatMap((result) => result.spaceUnresolved).filter((item) => item.space_id === spaceID));
        setState("ready");
      })
      .catch((error: unknown) => {
        if (!active || isAbortError(error)) return;
        setState("error");
      });
    return () => {
      active = false;
      controller.abort();
    };
  }, [selectionKey, retryKey]);

  const report = [...reports]
    .filter((item) => item.space_id === spaceID)
    .sort((left, right) => right.local_date.localeCompare(left.local_date) || right.created_at.localeCompare(left.created_at))[0] ?? null;
  const weekly = [...weeklyReports]
    .filter((item) => item.space_id === spaceID)
    .sort((left, right) => right.local_date.localeCompare(left.local_date) || right.created_at.localeCompare(left.created_at))[0] ?? null;
  const preference = preferences.find((item) => item.space_id === spaceID) ?? null;
  const reportSpace = selectedSpace;
  const actionID = string(report?.primary_action?.record_id);
  const actionKind = string(report?.primary_action?.kind);
  const actionHabit = actionID ? habits.find((item) => item.id === actionID) ?? null : null;
  const habit = [...habits]
    .filter((item) => item.space_id === spaceID && item.status === "ACTIVE")
    .sort((left, right) => left.slot.localeCompare(right.slot) || left.review_date.localeCompare(right.review_date))[0] ?? null;
  const suggestion = [...findings]
    .filter((item) => item.space_id === spaceID && item.status === "OPEN")
    .sort((left, right) => right.saving_high_minor - left.saving_high_minor || right.confidence_bps - left.confidence_bps)[0] ?? null;
  const goal = [...goals]
    .filter((item) => item.space_id === spaceID && item.status === "ACTIVE")
    .sort((left, right) => left.deadline.localeCompare(right.deadline))[0] ?? null;
  const purchase = [...unresolved]
    .filter((item) => item.space_id === spaceID && item.status === "OPEN")
    .sort((left, right) => right.priority - left.priority || Math.abs(right.amount_minor ?? 0) - Math.abs(left.amount_minor ?? 0))[0] ?? null;
  const fallbackCommitment = [...commitments]
    .filter((item) => item.space_id === spaceID && item.status === "ACTIVE" && item.next_due_date)
    .sort((left, right) => left.next_due_date!.localeCompare(right.next_due_date!))[0] ?? null;
  const reportCommitment = record(report?.summary.next_protected_commitment);
  const safe = safeFromReport(report);
  const reportCurrency = report?.currency ?? null;
  const reportDate = report?.local_date ?? null;

  // Load a simple "where it's going" category breakdown for the glance view.
  useEffect(() => {
    if (!spaceID || !reportCurrency || !reportDate) {
      setCategoryGroups([]);
      return;
    }
    const controller = new AbortController();
    let active = true;
    api<FinanceAnalysisResponse>(
      "/finance/analysis",
      {
        method: "POST",
        signal: controller.signal,
        body: JSON.stringify({
          space_id: spaceID,
          scope,
          basis: "TRANSACTIONS",
          start_date: shiftDate(reportDate, -29),
          end_date: reportDate,
          currency: reportCurrency,
          grouping: "CATEGORY",
          measure: "SPEND",
          comparison: "NONE",
          pending_policy: "EXCLUDE",
          refund_policy: "NET",
          transfer_policy: "EXCLUDE",
          filters: analysisFilters(),
          save_as: null,
        }),
      },
      true,
      false,
    )
      .then((result) => {
        if (!active) return;
        setCategoryGroups(result.groups);
        setCategoryCurrency(result.currency);
      })
      .catch((error: unknown) => {
        if (!active || isAbortError(error)) return;
        setCategoryGroups([]);
      });
    return () => {
      active = false;
      controller.abort();
    };
  }, [spaceID, scope, reportCurrency, reportDate]);

  const categories = categoryBreakdown(
    categoryGroups,
    categoryCurrency,
    locale,
    locale === "de" ? "Nicht kategorisiert" : "Uncategorised",
    locale === "de" ? "Sonstiges" : "Everything else",
  );

  useEffect(() => {
    const requestedAction = new URLSearchParams(window.location.search).get("action");
    if (!requestedAction || requestedAction !== actionID || state !== "ready") return;
    const reduced = window.matchMedia?.("(prefers-reduced-motion: reduce)").matches ?? false;
    actionCardRef.current?.focus();
    actionCardRef.current?.scrollIntoView({ block: "center", behavior: reduced ? "auto" : "smooth" });
  }, [actionID, state, spaceID]);

  function removeAction() {
    if (!report || !actionID) return;
    setReports((currentReports) => currentReports.map((item) => (
      item.id === report.id ? { ...item, primary_action: null } : item
    )));
    clearActionLink();
    setActionNotice(calm.saved);
  }

  async function finishPayday() {
    if (actionKind !== "PAYDAY_TRANSFER" || !actionID || actionBusy) return;
    setActionBusy(true);
    setActionError("");
    setActionNotice("");
    try {
      await api(
        `/finance/payday-actions/${encodeURIComponent(actionID)}/resolve`,
        { method: "POST", body: JSON.stringify({ status: "DONE", changed_amount_minor: null, note: null }) },
        true,
        false,
      );
      removeAction();
    } catch {
      setActionError(calm.actionError);
      window.requestAnimationFrame(() => actionErrorRef.current?.focus());
    } finally {
      setActionBusy(false);
    }
  }

  async function reviewHabit() {
    if (!actionID || !actionHabit || actionBusy) return;
    setActionBusy(true);
    setActionError("");
    setActionNotice("");
    try {
      const updated = await api<FinanceHabit>(
        `/finance/habits/${encodeURIComponent(actionID)}/review`,
        { method: "POST", body: JSON.stringify({ decision: habitDecision, friction_rating: Number(friction), note: null }) },
        true,
        false,
      );
      setHabits((currentHabits) => currentHabits.map((item) => item.id === updated.id ? updated : item));
      removeAction();
    } catch {
      setActionError(calm.actionError);
      window.requestAnimationFrame(() => actionErrorRef.current?.focus());
    } finally {
      setActionBusy(false);
    }
  }

  async function refreshReport() {
    const space = reportSpace;
    if (!space || refreshing) return;
    setRefreshing(true);
    setRefreshError("");
    try {
      const updated = await api<FinanceCoachingReport>(
        `/finance/reports/DAILY/refresh?space_id=${encodeURIComponent(space.id)}`,
        { method: "POST" },
        true,
        false,
      );
      if (updated.space_id !== space.id || updated.report_kind !== "DAILY") throw new Error(copy.errorDetail);
      setReports((currentReports) => [updated, ...currentReports.filter((item) => item.id !== updated.id)]);
    } catch {
      setRefreshError(copy.errorDetail);
    } finally {
      setRefreshing(false);
    }
  }

  if (state === "loading") return <div className="finance-adult-skeleton" aria-label={copy.loading} aria-busy="true"><div /><div /><div /></div>;
  if (state === "error") return <div className="finance-adult-state is-error" role="alert"><AlertCircle aria-hidden="true" size={24} /><div><strong>{copy.errorTitle}</strong><p>{copy.errorDetail}</p></div><button type="button" className="button button--secondary" onClick={() => setRetryKey((value) => value + 1)}>{copy.retry}</button></div>;

  const savedExplanation = report?.explanation.includes("saved Finance evidence")
    ? copy.reportReviewAction
    : report?.explanation;
  const explanation = savedExplanation;
  const explanationLanguageNotice = report && report.locale !== locale
    ? (locale === "de"
        ? `Gespeicherter Bericht auf ${report.locale === "en" ? "Englisch" : "Deutsch"}. Aktualisiere ihn für deine aktuelle Sprache.`
        : `Saved report in ${report.locale === "de" ? "German" : "English"}. Refresh it for your current language.`)
    : null;
  const safeHeadline = safe.amount !== null && safe.currency
    ? formatCurrency(safe.amount, safe.currency, locale)
    : safe.low !== null && safe.high !== null && safe.currency
      ? `${formatCurrency(safe.low, safe.currency, locale)}–${formatCurrency(safe.high, safe.currency, locale)}`
      : null;
  const actionAmount = number(report?.primary_action?.amount_minor);
  const actionCurrency = string(report?.primary_action?.currency);
  const actionTitle = report?.primary_action
    ? (actionKind && actionKind in copy.actionKinds
        ? copy.actionKinds[actionKind as keyof typeof copy.actionKinds]
        : string(report.primary_action.title) ?? copy.reportReviewAction)
    : copy.noAction;
  const commitmentName = string(reportCommitment?.name) ?? fallbackCommitment?.name ?? null;
  const commitmentDate = string(reportCommitment?.due_date) ?? fallbackCommitment?.next_due_date ?? null;
  const commitmentAmount = number(reportCommitment?.amount_minor)
    ?? fallbackCommitment?.exact_minor
    ?? fallbackCommitment?.expected_minor
    ?? fallbackCommitment?.remaining_minor
    ?? null;
  const commitmentCurrency = string(reportCommitment?.currency) ?? fallbackCommitment?.currency ?? report?.currency ?? null;

  return (
    <section className="finance-coach-home" aria-labelledby="finance-coach-home-title">
      <header>
        <div><span className="finance-status-label"><ShieldCheck aria-hidden="true" size={15} /> {copy.title}</span><h2 id="finance-coach-home-title">{copy.title}</h2><p>{copy.detail}</p></div>
        <div className="finance-coach-home-actions">
          <button type="button" className="button button--secondary" disabled={refreshing} onClick={() => void refreshReport()}><RefreshCw aria-hidden="true" size={16} /> {refreshing ? copy.refreshing : copy.refresh}</button>
        </div>
      </header>
      {refreshError ? <p className="form-error" role="alert">{refreshError}</p> : null}

      {!report ? <div className="finance-adult-state"><CalendarClock aria-hidden="true" size={24} /><div><strong>{copy.noReport}</strong><p>{copy.noReportDetail}</p></div></div> : (
        <>
          <section className="finance-decision-summary" aria-labelledby="finance-money-now-title">
            <h3 id="finance-money-now-title">{calm.moneyNow}</h3>
            <div className="finance-decision-strip">
              <article className={report.primary_action ? "is-attention" : "is-clear"}>
                <span>{calm.needsAttention}</span>
                <strong>{actionTitle}</strong>
              </article>
              <article>
                <span>{calm.availableAfterCommitments}</span>
                <strong>{safeHeadline ?? calm.noCurrentRoom}</strong>
              </article>
              <article>
                <span>{calm.nextBill}</span>
                {commitmentName ? <><strong>{commitmentName}</strong><small>{commitmentAmount !== null && commitmentCurrency ? formatCurrency(commitmentAmount, commitmentCurrency, locale) : null}{commitmentDate ? `${commitmentAmount !== null && commitmentCurrency ? " · " : ""}${copy.due} ${formatDate(commitmentDate, locale)}` : null}</small></> : <strong>{calm.noProtectedCost}</strong>}
              </article>
            </div>
          </section>

          <article className={`finance-calm-conclusion is-${report.trajectory_status.toLowerCase()}`}>
            <span>{calm.conclusion}</span>
            <h3>{copy.trajectories[report.trajectory_status]}</h3>
            <p lang={report.locale}>{explanation}</p>
            {explanationLanguageNotice ? <small>{explanationLanguageNotice}</small> : null}
          </article>

          {actionNotice ? <p className="form-success" role="status" aria-live="polite">{actionNotice}</p> : null}
          {report.primary_action && actionID ? (
            <article className="finance-calm-action" tabIndex={-1} ref={actionCardRef}>
              <span>{calm.oneAction}</span>
              <h3>{actionKind && actionKind in copy.actionKinds ? copy.actionKinds[actionKind as keyof typeof copy.actionKinds] : string(report.primary_action.title) ?? copy.reportReviewAction}</h3>
              {actionAmount !== null && actionCurrency ? <p>{formatCurrency(actionAmount, actionCurrency, locale)}</p> : null}
              {actionError ? <p className="form-error" role="alert" tabIndex={-1} ref={actionErrorRef}>{actionError}</p> : null}
              {actionKind === "HABIT_REVIEW" && actionHabit ? (
                <form className="finance-calm-habit-form" onSubmit={(event) => { event.preventDefault(); void reviewHabit(); }}>
                  <div className="field"><label htmlFor="finance-calm-decision">{calm.decision}</label><select id="finance-calm-decision" value={habitDecision} onChange={(event) => setHabitDecision(event.target.value as typeof habitDecision)}><option value="KEEP">{calm.keep}</option><option value="ADJUST">{calm.adjust}</option><option value="STOP">{calm.stop}</option></select></div>
                  <div className="field"><label htmlFor="finance-calm-friction">{calm.difficulty}</label><select id="finance-calm-friction" value={friction} onChange={(event) => setFriction(event.target.value)}>{[1, 2, 3, 4, 5].map((value) => <option value={String(value)} key={value}>{value}</option>)}</select></div>
                  <button type="submit" className="button button--primary" disabled={actionBusy}>{actionBusy ? calm.saving : calm.saveReview}</button>
                </form>
              ) : actionKind === "PURCHASE_REVIEW" ? (
                <a className="button button--primary" href={`/?view=finance&section=more${reportSpace?.kind === "household" ? "&scope=household" : ""}&line=${encodeURIComponent(actionID)}`}>{copy.openPurchase}</a>
              ) : actionKind === "PAYDAY_TRANSFER" ? (
                <button type="button" className="button button--primary" disabled={actionBusy} onClick={() => void finishPayday()}>{actionBusy ? calm.saving : calm.moved}</button>
              ) : actionKind === "PLAN_REVIEW" || actionKind === "HABIT_REVIEW" ? (
                <a className="button button--primary" href={`/?view=finance&section=plan${reportSpace?.kind === "household" ? "&scope=household" : ""}`}>{copy.openPlans}</a>
              ) : (
                <a className="button button--primary" href={`/?view=finance&section=activity${reportSpace?.kind === "household" ? "&scope=household" : ""}`}>{calm.openDetails}</a>
              )}
            </article>
          ) : null}

          <article className="finance-calm-suggestion"><h3><Lightbulb aria-hidden="true" size={18} /> {locale === "de" ? "Ein einfacher Gewinn" : "One easy win"}</h3>{suggestion ? <><strong>{suggestion.title}</strong><p>{findingObservation(suggestion, locale)}</p><p><strong>{copy.possibleSaving}: {formatCurrency(suggestion.saving_low_minor, suggestion.currency, locale)}–{formatCurrency(suggestion.saving_high_minor, suggestion.currency, locale)}</strong></p><a className="button button--secondary" href={`/?view=finance&section=explore${reportSpace?.kind === "household" ? "&scope=household" : ""}`}>{locale === "de" ? "So geht es" : "See how"}</a></> : <p>{copy.noSuggestion}</p>}</article>

          {reportSpace?.kind === "household" && weekly ? (
            <article className="finance-weekly-check">
              <span>{calm.weekly}</span>
              <h3>{copy.trajectories[weekly.trajectory_status]}</h3>
              <p lang={weekly.locale}>{weekly.explanation}</p>
              <small>{calm.weeklyDetail} · {formatDate(weekly.local_date, locale)}</small>
            </article>
          ) : null}

          {categories.series.length ? (
            <section className="finance-category-card" aria-labelledby="finance-category-title">
              <div className="finance-category-head">
                <h3 id="finance-category-title">{locale === "de" ? "Wohin das Geld geht" : "Where it's going"}</h3>
                <small>{locale === "de" ? "Letzte 30 Tage" : "Last 30 days"}</small>
              </div>
              <p className="finance-category-coverage">
                <strong>{new Intl.NumberFormat(locale === "de" ? "de-DE" : "en-GB", { style: "percent", maximumFractionDigits: 0 }).format(categories.coverageBps / 10_000)}</strong>
                {locale === "de" ? " der Ausgaben sind kategorisiert" : " of spending is categorised"}
              </p>
              {categories.showDonut ? (
                <Donut series={categories.series} locale={locale} ariaLabel={locale === "de" ? "Ausgaben nach Kategorie, letzte 30 Tage" : "Spending by category, last 30 days"} />
              ) : (
                <ol className="finance-category-ranking" aria-label={locale === "de" ? "Ausgaben nach Kategorie, größte zuerst" : "Spending by category, largest first"}>
                  {categories.series.map((category) => (
                    <li key={category.key}>
                      <span>{category.label}</span>
                      <strong>{category.display}</strong>
                      <progress value={category.value} max={Math.max(1, ...categories.series.map((item) => item.value))}>{category.display}</progress>
                    </li>
                  ))}
                </ol>
              )}
              <a className="finance-category-more" href={`/?view=finance&section=explore${reportSpace?.kind === "household" ? "&scope=household" : ""}`}>{locale === "de" ? "Mehr auswerten" : "Break it down further"}</a>
            </section>
          ) : null}

          <details className="finance-calm-details" key={`${spaceID}:${preference?.show_more_by_default}`} open={preference?.show_more_by_default || undefined}>
            <summary><span><strong>{calm.more} </strong><small>{calm.moreDetail}</small></span><ChevronDown aria-hidden="true" size={18} /></summary>
            {goal ? <article className="finance-house-goal-trajectory"><span>{locale === "de" ? "Dein Sparziel" : "Your savings target"}</span><h3>{goal.name}</h3><p><strong>{formatCurrency(goal.currently_allocated_minor, goal.currency, locale)}</strong> {locale === "de" ? "von" : "of"} {formatCurrency(goal.target_minor, goal.currency, locale)} · {locale === "de" ? "Zieldatum" : "target date"} {formatDate(goal.deadline, locale)}</p><progress value={Math.max(0, goal.currently_allocated_minor)} max={Math.max(1, goal.target_minor)}>{Math.round(Math.max(0, goal.currently_allocated_minor) / Math.max(1, goal.target_minor) * 100)}%</progress><a className="button button--secondary" href={`/?view=finance&section=plan${reportSpace?.kind === "household" ? "&scope=household" : ""}`}>{locale === "de" ? "Sparpläne vergleichen" : "Compare savings plans"}</a></article> : null}
            <div className="finance-coach-home-grid">
              <article><span>{copy.expectedSaving}</span><strong>{formatCurrency(report.expected_durable_saving_minor, report.currency, locale)}</strong></article>
              <article><span>{calm.currentRoom}</span>{safe.amount !== null && safe.currency ? <><strong>{formatCurrency(safe.amount, safe.currency, locale)}</strong><small>{copy.safeExact}</small></> : safe.low !== null && safe.high !== null && safe.currency ? <><strong>{formatCurrency(safe.low, safe.currency, locale)}–{formatCurrency(safe.high, safe.currency, locale)}</strong><small>{copy.safeRange}</small></> : <p>{calm.noCurrentRoom}</p>}</article>
            </div>
            <div className="finance-coach-home-secondary">
              <article><h3><Repeat2 aria-hidden="true" size={18} /> {copy.habit}</h3>{habit ? <><strong>{habit.name}</strong><p>{habit.trigger}</p><dl><div><dt>{copy.realised}</dt><dd>{formatCurrency(habit.realised_saving_minor, habit.currency, locale)}</dd></div><div><dt>{copy.expected}</dt><dd>{formatCurrency(habit.expected_saving_low_minor, habit.currency, locale)}–{formatCurrency(habit.expected_saving_high_minor, habit.currency, locale)}</dd></div><div><dt>{copy.review}</dt><dd>{formatDate(habit.review_date, locale)}</dd></div></dl></> : <p>{copy.noHabit}</p>}</article>
              <article><h3><ShoppingBag aria-hidden="true" size={18} /> {copy.unresolved}</h3>{purchase ? <><strong>{purchase.title}</strong><p>{purchase.detail}</p>{purchase.amount_minor !== null && purchase.currency ? <small>{formatCurrency(purchase.amount_minor, purchase.currency, locale)}</small> : null}<a className="button button--secondary" href={`/?view=finance&section=more&evidence=${encodeURIComponent(purchase.source_id)}`}>{copy.openPurchase}</a></> : <p>{copy.noUnresolved}</p>}</article>
            </div>
          </details>
        </>
      )}
    </section>
  );
}
