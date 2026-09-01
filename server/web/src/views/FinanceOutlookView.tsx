import {
  AlertCircle,
  CalendarRange,
  CheckCircle2,
  CircleDollarSign,
  RefreshCw,
  ShieldCheck,
  TrendingDown,
} from "lucide-react";
import { useEffect, useMemo, useState, type FormEvent } from "react";

import { api } from "../api";
import { todayInTimeZone } from "../financeDate";
import type { FinanceLocale, FinanceStrings } from "../financeStrings";
import type {
  FinanceAccount,
  FinanceForecast,
  FinanceForecastEvent,
  FinanceForecastLimit,
  FinanceForecastOverview,
  FinanceSafeToSpend,
  FinanceSettings,
  FinanceSpace,
} from "../types";
import { cn } from "../components/ui";
import { OutlookChart } from "../components/FinanceCharts";

function formatCurrency(minor: number, currency: string, locale: FinanceLocale) {
  return new Intl.NumberFormat(locale === "de" ? "de-DE" : "en-GB", {
    style: "currency",
    currency,
  }).format(minor / 100);
}

function formatDate(value: string, locale: FinanceLocale) {
  const parsed = new Date(`${value}T00:00:00`);
  if (Number.isNaN(parsed.valueOf())) return value;
  return new Intl.DateTimeFormat(locale === "de" ? "de-DE" : "en-GB", {
    dateStyle: "medium",
  }).format(parsed);
}

function addDays(value: string, days: number) {
  const parsed = new Date(`${value}T12:00:00Z`);
  parsed.setUTCDate(parsed.getUTCDate() + days);
  return parsed.toISOString().slice(0, 10);
}

function amountToMinor(value: string) {
  const match = /^(\d+)(?:[.,](\d{1,2}))?$/.exec(value.trim());
  if (!match) return null;
  const result = BigInt(match[1]) * 100n + BigInt((match[2] ?? "").padEnd(2, "0") || "0");
  if (result > BigInt(Number.MAX_SAFE_INTEGER)) return null;
  return Number(result);
}

function isEligibleCashAccount(account: FinanceAccount) {
  return account.balance !== null
    && account.include_in_cashflow
    && ["CURRENT", "SAVINGS", "CASH"].includes(account.account_type)
    && ["OPERATING_CURRENT", "SAVINGS", "GOAL"].includes(account.purpose);
}

function plainForecastNote(note: string, copy: FinanceStrings) {
  const value = note.toLowerCase();
  if (value.includes("only current through")) return copy.outlookNotes.stale;
  if (value.includes("no balance has been saved")) return copy.outlookNotes.missingBalance;
  if (value.includes("no usable timestamp")) return copy.outlookNotes.unknownBalanceDate;
  if (value.includes("linked active reserves")) return copy.outlookNotes.linkedReserve;
  if (value.includes("unlinked active reserves")) return copy.outlookNotes.sharedReserve;
  if (value.includes("active reserve") && value.includes("left out")) return copy.outlookNotes.skippedReserve;
  if (value.includes("allocated goal savings") && value.includes("single saved")) return copy.outlookNotes.linkedGoal;
  if (value.includes("goal savings without one")) return copy.outlookNotes.sharedGoal;
  if (value.includes("no saved credit limit")) return copy.outlookNotes.cardLimit;
  if (value.includes("credit-card balance") || value.includes("settlement account or card timing")) return copy.outlookNotes.cardRepaymentUnknown;
  if (value.includes("extended through") && value.includes("card repayment")) return copy.outlookNotes.cardExtended;
  if (value.includes("commitment set-asides")) return copy.outlookNotes.commitmentReserve;
  if (value.includes("commitment") && (value.includes("left out") || value.includes("invalid reviewed date"))) return copy.outlookNotes.commitmentMissing;
  if (value.includes("unconfirmed repeating-payment")) return copy.outlookNotes.repeatingCandidate;
  if (value.includes("no confirmed repeating")) return copy.outlookNotes.noRepeating;
  if (value.includes("cautious low-income") || value.includes("cautious high-cost")) return copy.outlookNotes.cautiousRepeating;
  if (value.includes("repeating card") && value.includes("left out")) return copy.outlookNotes.cardRepeatingMissing;
  if (value.includes("confirmed repeating") && value.includes("left out")) return copy.outlookNotes.repeatingMissing;
  return copy.outlookNotes.other;
}

function safeReason(reason: string, copy: FinanceStrings) {
  const value = reason.toLowerCase();
  if (value.includes("card_timing_not_included")) return copy.safeReasons.cardTiming;
  if (value.includes("recent_spending_automatic")) return copy.safeReasons.recentSpending;
  if (value.includes("saved_outlook_gaps")) return copy.safeReasons.savedGaps;
  if (value.includes("data_date_not_saved")) return copy.safeReasons.unknownDate;
  if (value.includes("nearest_saved_day")) return copy.safeReasons.date;
  if (value.includes("nearest_included_account")) return copy.safeReasons.account;
  if (value.includes("saved_threshold_rule")) return copy.safeReasons.complex;
  if (value.includes("known_headroom") || value.includes("latest_balance")) return copy.safeReasons.knownMoney;
  if (value.includes("no_included_cash_account")) return copy.safeReasons.noCash;
  if (value.includes("predates saved-data")) return copy.safeReasons.savedGaps;
  if (value.includes("partial") && value.includes("unsafe")) return copy.safeReasons.savedGaps;
  if (value.includes("purchase_date_outside_snapshot")) return copy.safeReasons.date;
  if (value.includes("spend_account_not_found")) return copy.safeReasons.account;
  if (value.includes("card_account_not_found")) return copy.safeReasons.card;
  if (value.includes("settlement_account_not_found")) return copy.safeReasons.settlement;
  if (value.includes("no confirmed full-repayment route")) return copy.safeReasons.cardTiming;
  if (value.includes("card_repayment_outside_snapshot")) return copy.safeReasons.horizon;
  if (value.includes("no_finite_constraint")) return copy.safeReasons.unbounded;
  if (value.includes("threshold") || value.includes("non-monotone")) return copy.safeReasons.complex;
  const assumption = plainForecastNote(reason, copy);
  return assumption === copy.outlookNotes.other ? copy.safeReasons.unknown : assumption;
}

function displaySafeResult(
  result: FinanceSafeToSpend,
  forecast: FinanceForecast,
  accounts: FinanceAccount[],
  routeValue: string,
  unobservedHigh: string,
): FinanceSafeToSpend {
  if (result.answer_mode !== "CANNOT_MODEL") return result;
  const [routeKind, routeID] = routeValue.split(":", 2);
  const routeAccount = routeKind === "direct"
    ? routeID
    : accounts.find((account) => account.id === routeID)?.card_settlement_account_id
      ?? accounts.find((account) => account.primary_spending_account)?.id
      ?? null;
  const accountMinimum = routeAccount
    ? Math.min(...forecast.days.map((day) => day.accounts.find((item) => item.account_id === routeAccount)?.headroom_minor ?? Number.MAX_SAFE_INTEGER))
    : Number.MAX_SAFE_INTEGER;
  const highMinor = Math.max(0, Math.min(forecast.minimum_household_free_minor, accountMinimum));
  const enteredAllowance = amountToMinor(unobservedHigh) ?? 0;
  const smallAllowance = Math.max(enteredAllowance, Math.round(highMinor / 10));
  return {
    ...result,
    status: highMinor > 0 ? "OK" : "NO_SAFE_AMOUNT",
    answer_mode: "ESTIMATED_RANGE",
    amount_minor: null,
    low_minor: Math.max(0, highMinor - smallAllowance),
    high_minor: highMinor,
  };
}

function eventKind(event: FinanceForecastEvent, copy: FinanceStrings) {
  return event.kind === "transfer" && event.provenance?.startsWith("card-repayment:")
    ? copy.outlookEventKinds.card_repayment
    : copy.outlookEventKinds[event.kind];
}

function OutlookLimit({
  limit,
  forecast,
  accounts,
  locale,
  copy,
}: {
  limit: FinanceForecastLimit;
  forecast: Pick<FinanceForecast, "events">;
  accounts: Map<string, FinanceAccount>;
  locale: FinanceLocale;
  copy: FinanceStrings;
}) {
  const event = limit.event_id ? forecast.events.find((item) => item.event_id === limit.event_id) : null;
  const account = limit.account_id ? accounts.get(limit.account_id) : null;
  return (
    <div className="finance-safe-limit">
      <p><TrendingDown aria-hidden="true" size={17} /> {copy.safeLimitedBy} <strong>{formatDate(limit.day, locale)}</strong>{event ? ` — ${eventKind(event, copy)}` : ""}.</p>
      {account ? <p>{copy.safeLimitedAccount}: <strong>{account.label}</strong></p> : null}
    </div>
  );
}

export function FinanceOutlookView({
  accounts,
  spaces,
  online,
  locale,
  copy,
}: {
  accounts: FinanceAccount[];
  spaces: FinanceSpace[];
  online: boolean;
  locale: FinanceLocale;
  copy: FinanceStrings;
}) {
  const selectionKey = spaces.map((space) => space.id).join(":");
  const initialSpace = spaces[0]?.id ?? "";
  const initialCurrency = accounts.find((account) => account.space_id === initialSpace && isEligibleCashAccount(account))?.currency ?? "";
  const [spaceID, setSpaceID] = useState(initialSpace);
  const [currency, setCurrency] = useState(initialCurrency);
  const [forecast, setForecast] = useState<FinanceForecastOverview | null>(null);
  const [fullForecast, setFullForecast] = useState<FinanceForecast | null>(null);
  const [advancedOpen, setAdvancedOpen] = useState(false);
  const [advancedBusy, setAdvancedBusy] = useState(false);
  const [advancedError, setAdvancedError] = useState("");
  const [refreshing, setRefreshing] = useState(false);
  const [hasAttemptedLoad, setHasAttemptedLoad] = useState(false);
  const [loadKey, setLoadKey] = useState(0);
  const [refreshError, setRefreshError] = useState("");
  const [routeValue, setRouteValue] = useState("");
  const [spendDate, setSpendDate] = useState("");
  const [unobservedLow, setUnobservedLow] = useState("0.00");
  const [unobservedHigh, setUnobservedHigh] = useState("0.00");
  const [safeResult, setSafeResult] = useState<FinanceSafeToSpend | null>(null);
  const [safeBusy, setSafeBusy] = useState(false);
  const [safeError, setSafeError] = useState("");
  const [estimateError, setEstimateError] = useState("");
  const [scenarioOneOff, setScenarioOneOff] = useState("");
  const [scenarioMonthly, setScenarioMonthly] = useState("");

  const spaceAccounts = useMemo(
    () => accounts.filter((account) => account.space_id === spaceID),
    [accounts, spaceID],
  );
  const currencies = useMemo(
    () => [...new Set(spaceAccounts.filter(isEligibleCashAccount).map((account) => account.currency))].sort(),
    [spaceAccounts],
  );
  const accountByID = useMemo(() => new Map(accounts.map((account) => [account.id, account])), [accounts]);

  useEffect(() => {
    const nextSpace = spaces[0]?.id ?? "";
    const nextCurrency = accounts.find((account) => account.space_id === nextSpace && isEligibleCashAccount(account))?.currency ?? "";
    setSpaceID(nextSpace);
    setCurrency(nextCurrency);
    setForecast(null);
    setFullForecast(null);
    setAdvancedOpen(false);
    setAdvancedError("");
    setHasAttemptedLoad(false);
    setSafeResult(null);
    setRefreshError("");
    setSafeError("");
  }, [selectionKey]);

  function resetSavedResults() {
    setForecast(null);
    setFullForecast(null);
    setAdvancedOpen(false);
    setAdvancedError("");
    setHasAttemptedLoad(false);
    setSafeResult(null);
    setRefreshError("");
    setSafeError("");
  }

  function chooseSpace(nextSpaceID: string) {
    const nextCurrency = accounts.find((account) => account.space_id === nextSpaceID && isEligibleCashAccount(account))?.currency ?? "";
    setSpaceID(nextSpaceID);
    setCurrency(nextCurrency);
    resetSavedResults();
  }

  useEffect(() => {
    if (!spaceID || !currency) return;
    const controller = new AbortController();
    let active = true;
    setRefreshing(true);
    setRefreshError("");
    setSafeResult(null);
    setSafeError("");
    void (async () => {
      try {
      const settings = await api<FinanceSettings>(
        "/finance/settings",
        { signal: controller.signal },
        true,
        false,
      );
      const start = todayInTimeZone(settings.household_timezone);
      const loaded = await api<FinanceForecastOverview>(
        `/finance/forecasts/overview?space_id=${encodeURIComponent(spaceID)}`,
        {
          method: "POST",
          body: JSON.stringify({ end_date: addDays(start, 89), currency, household_buffer_minor: 0 }),
          signal: controller.signal,
        },
        true,
        false,
      );
      if (loaded.space_id !== spaceID || loaded.currency !== currency || loaded.source !== "SAVED") throw new Error(copy.outlookRefreshError);
      if (!active) return;
      setForecast(loaded);
      setFullForecast(null);
      setAdvancedOpen(false);
      setAdvancedError("");
      setSpendDate(loaded.start_date);
      const modelledIDs = new Set(loaded.opening_accounts.map((account) => account.account_id));
      const direct = accounts.filter((account) => (
        account.space_id === loaded.space_id
        && account.currency === loaded.currency
        && modelledIDs.has(account.id)
        && isEligibleCashAccount(account)
      ));
      const nextRoute = direct.find((account) => account.primary_spending_account) ?? direct[0] ?? null;
      setRouteValue(nextRoute ? `direct:${nextRoute.id}` : "");
      } catch (caught) {
        if (!active || (caught instanceof DOMException && caught.name === "AbortError")) return;
        setRefreshError(copy.outlookRefreshError);
      } finally {
        if (active) {
          setRefreshing(false);
          setHasAttemptedLoad(true);
        }
      }
    })();
    return () => {
      active = false;
      controller.abort();
    };
  }, [online, spaceID, currency, loadKey]);

  function refreshOutlook(event: FormEvent) {
    event.preventDefault();
    if (!online || !spaceID || !currency || refreshing) return;
    setLoadKey((value) => value + 1);
  }

  async function loadFullForecast(selected: FinanceForecastOverview) {
    if (fullForecast?.id === selected.id || advancedBusy) return;
    setAdvancedBusy(true);
    setAdvancedError("");
    try {
      const loaded = await api<FinanceForecast>(
        `/finance/forecasts/${encodeURIComponent(selected.id)}`,
        {},
        true,
        false,
      );
      if (loaded.id !== selected.id || loaded.input_snapshot_digest !== selected.input_snapshot_digest) {
        throw new Error(copy.outlookRefreshError);
      }
      setFullForecast(loaded);
    } catch {
      setAdvancedError(copy.outlookRefreshError);
    } finally {
      setAdvancedBusy(false);
    }
  }

  const modelledIDs = new Set(forecast?.opening_accounts.map((account) => account.account_id) ?? []);
  const directAccounts = forecast ? accounts.filter((account) => (
    account.space_id === forecast.space_id
    && account.currency === forecast.currency
    && modelledIDs.has(account.id)
    && isEligibleCashAccount(account)
  )) : [];
  const directIDs = new Set(directAccounts.map((account) => account.id));
  const cardAccounts = forecast ? accounts.filter((account) => (
    account.space_id === forecast.space_id
    && account.currency === forecast.currency
    && account.account_type === "CREDIT_CARD"
    && account.balance !== null
  )) : [];
  const routes = [
    ...directAccounts.map((account) => ({ value: `direct:${account.id}`, label: `${copy.safeDirectRoute} ${account.label}` })),
    ...cardAccounts.map((account) => {
      const hasFullRoute = account.card_paid_in_full
        && Boolean(account.card_settlement_account_id && directIDs.has(account.card_settlement_account_id))
        && account.card_statement_close_day !== null
        && account.card_repayment_day !== null;
      return {
        value: `card:${account.id}`,
        label: `${copy.safeCardRoute} ${account.label} (${hasFullRoute ? copy.safeCardRouteSuffix : copy.safeCardEstimateSuffix})`,
      };
    }),
  ];
  const routeKey = routes.map((route) => route.value).join(":");

  useEffect(() => {
    if (!forecast || routes.some((route) => route.value === routeValue)) return;
    const everyday = directAccounts.find((account) => account.primary_spending_account);
    setRouteValue(everyday ? `direct:${everyday.id}` : routes[0]?.value ?? "");
  }, [forecast?.id, routeValue, routeKey]);

  async function checkSafeAmount(event: FormEvent) {
    event.preventDefault();
    if (!forecast || !routeValue || safeBusy) return;
    const lowMinor = amountToMinor(unobservedLow);
    const highMinor = amountToMinor(unobservedHigh);
    if (lowMinor === null || highMinor === null || highMinor < lowMinor) {
      setEstimateError(copy.safeEstimateInvalid);
      return;
    }
    const [routeKind, accountID] = routeValue.split(":", 2);
    if (!accountID || (routeKind !== "direct" && routeKind !== "card")) return;
    setEstimateError("");
    setSafeError("");
    setSafeBusy(true);
    try {
      const body = routeKind === "direct"
        ? {
            forecast_id: forecast.id,
            route: "direct",
            spend_date: spendDate,
            account_id: accountID,
            unobserved_spend_low_minor: lowMinor,
            unobserved_spend_high_minor: highMinor,
          }
        : {
            forecast_id: forecast.id,
            route: "full_repayment_card",
            spend_date: spendDate,
            card_account_id: accountID,
            unobserved_spend_low_minor: lowMinor,
            unobserved_spend_high_minor: highMinor,
          };
      const loaded = await api<FinanceSafeToSpend>(
        "/finance/safe-to-spend",
        { method: "POST", body: JSON.stringify(body) },
        true,
        false,
      );
      if (loaded.forecast_id !== forecast.id || loaded.input_snapshot_digest !== forecast.input_snapshot_digest) throw new Error(copy.safeRequestError);
      setSafeResult(loaded);
    } catch {
      setSafeResult({
        forecast_id: forecast.id,
        input_snapshot_digest: forecast.input_snapshot_digest,
        status: "CANNOT_MODEL_DIRECT_ROUTE",
        answer_mode: "CANNOT_MODEL",
        currency: forecast.currency,
        amount_minor: null,
        low_minor: null,
        high_minor: null,
        data_through: forecast.data_through_at?.slice(0, 10) ?? null,
        evaluated_through: forecast.end_date,
        limiting_event: null,
        refusal_reasons: ["KNOWN_HEADROOM_RANGE_ESTIMATE"],
      });
    } finally {
      setSafeBusy(false);
    }
  }

  const openingAccounts = forecast?.opening_accounts ?? [];
  const assumptions = forecast
    ? [...new Set(forecast.input_notes
        .filter((note) => !note.toLowerCase().includes("only current through"))
        .map((note) => plainForecastNote(note, copy)))]
    : [];
  const relevantAccounts = forecast
    ? openingAccounts.map((row) => accountByID.get(row.account_id)).filter((account): account is FinanceAccount => Boolean(account))
    : [];
  const shownSafeResult = safeResult && fullForecast
    ? displaySafeResult(safeResult, fullForecast, accounts, routeValue, unobservedHigh)
    : safeResult;
  const safeHasNoAmount = shownSafeResult?.status === "NO_SAFE_AMOUNT";
  const safeNotes = shownSafeResult
    ? [...new Set(shownSafeResult.refusal_reasons.map((reason) => safeReason(reason, copy)))]
    : [];
  const safeBasisDetail = safeNotes.find((note) => note === copy.safeReasons.cardTiming)
    ?? safeNotes[0]
    ?? "";
  const noRouteHigh = Math.max(0, forecast?.minimum_household_free_minor ?? 0);
  const noRouteLow = Math.max(0, noRouteHigh - Math.round(noRouteHigh / 10));
  const keyEvents = forecast ? [...forecast.events].sort((left, right) => left.day.localeCompare(right.day)) : [];
  const firstKeyEvent = keyEvents[0] ?? null;
  const detailDays = fullForecast ? fullForecast.days.filter((day, index) => {
    if (index === 0 || index === fullForecast.days.length - 1 || day.day === fullForecast.minimum_household_free_date) return true;
    if (keyEvents.some((event) => event.day === day.day)) return true;
    return day.day.endsWith("-01");
  }) : [];

  return (
    <section className="finance-outlook-panel" aria-labelledby="finance-outlook-title">
      <header className="finance-outlook-heading">
        <div>
          <span className="finance-status-label"><CalendarRange aria-hidden="true" size={15} /> {copy.coach}</span>
          <h2 id="finance-outlook-title">{copy.outlookTitle}</h2>
          <p>{copy.outlookDetail}</p>
        </div>
      </header>

      <details className="finance-outlook-settings">
        <summary>{locale === "de" ? "Ausblick-Einstellungen" : "Outlook settings"}</summary>
        <form className="finance-outlook-controls" onSubmit={refreshOutlook} aria-busy={refreshing}>
          {spaces.length > 1 ? <div className="field">
            <label htmlFor="finance-outlook-destination">{copy.outlookDestination}</label>
            <select id="finance-outlook-destination" value={spaceID} disabled={refreshing} onChange={(event) => chooseSpace(event.target.value)}>
              {spaces.map((space) => <option value={space.id} key={space.id}>{space.name}</option>)}
            </select>
          </div> : null}
          <div className="field">
            <label htmlFor="finance-outlook-currency">{copy.outlookCurrency}</label>
            <select id="finance-outlook-currency" value={currency} disabled={refreshing || !currencies.length} onChange={(event) => { setCurrency(event.target.value); resetSavedResults(); }}>
              {currencies.map((value) => <option value={value} key={value}>{value}</option>)}
            </select>
          </div>
          <button type="submit" className="button button--primary" disabled={!online || refreshing || !spaceID || !currency} aria-busy={refreshing}>
            <RefreshCw aria-hidden="true" size={17} /> {refreshing ? copy.refreshingOutlook : copy.refreshOutlook}
          </button>
        </form>
      </details>

      {refreshError && !forecast ? <div className="finance-outlook-load-error" role="alert"><p className="form-error">{refreshError}</p><button type="button" className="button button--secondary" disabled={!online || refreshing} onClick={() => setLoadKey((value) => value + 1)}>{locale === "de" ? "Erneut versuchen" : "Try again"}</button></div> : null}
      {!currencies.length ? <p className="finance-outlook-inline-state"><AlertCircle aria-hidden="true" size={18} /> {copy.outlookNoCurrency}</p> : null}
      {!forecast && currencies.length && (refreshing || !hasAttemptedLoad) ? <div className="finance-outlook-skeleton" aria-busy="true" aria-label={copy.refreshingOutlook}><div /><div /><div /></div> : null}
      {!refreshing && hasAttemptedLoad && !forecast && currencies.length && !refreshError ? (
        <div className="finance-outlook-empty">
          <CalendarRange aria-hidden="true" size={30} />
          <strong>{copy.outlookEmptyTitle}</strong>
          <p>{copy.outlookEmptyDetail}</p>
        </div>
      ) : null}

      {forecast ? (
        <div className="finance-outlook-result">
          <div className="finance-outlook-summary">
            <article>
              <span>{copy.outlookLowestFree}</span>
              <strong>{formatCurrency(forecast.minimum_household_free_minor, forecast.currency, locale)}</strong>
              <p>{copy.outlookLowestFreeDetail}</p>
              <small>{copy.outlookLowestOn}: {formatDate(forecast.minimum_household_free_date, locale)}</small>
            </article>
            <article>
              <span>{locale === "de" ? "Nächster wichtiger Termin" : "Next key date"}</span>
              <strong>{firstKeyEvent ? formatDate(firstKeyEvent.day, locale) : "—"}</strong>
              <p>{firstKeyEvent ? eventKind(firstKeyEvent, copy) : copy.outlookNoEvents}</p>
              <small>{firstKeyEvent ? formatCurrency(firstKeyEvent.amount_minor, firstKeyEvent.currency, locale) : `${formatDate(forecast.start_date, locale)}–${formatDate(forecast.end_date, locale)}`}</small>
            </article>
          </div>

          <aside className={cn("finance-outlook-next-action", !forecast.passed && "is-warning")}>
            {forecast.passed ? <CheckCircle2 aria-hidden="true" size={20} /> : <AlertCircle aria-hidden="true" size={20} />}
            <div>
              <strong>{locale === "de" ? "Nächster Schritt" : "Next step"}</strong>
              <p>{forecast.passed
                ? (locale === "de" ? "Nichts Dringendes. Dein aktueller Plan bleibt über dem geschützten Betrag." : "Nothing urgent. Your current plan stays above the protected amount.")
                : (locale === "de" ? "Prüfe den niedrigsten Tag und passe eine geplante Ausgabe an." : "Check the lowest day and adjust one planned expense.")}</p>
            </div>
          </aside>

          {forecast.days.length > 1 ? (() => {
            const oneOffMinor = Math.round((parseFloat(scenarioOneOff) || 0) * 100);
            const monthlyMinor = Math.round((parseFloat(scenarioMonthly) || 0) * 100);
            const hasScenario = oneOffMinor !== 0 || monthlyMinor !== 0;
            const scenarioValues = hasScenario
              ? forecast.days.map((day, index) => day.household_free_minor - oneOffMinor + monthlyMinor * Math.floor(index / 30))
              : undefined;
            const scenarioLow = scenarioValues ? Math.min(...scenarioValues) : null;
            return (
            <figure className="finance-outlook-figure">
              <OutlookChart
                points={forecast.days.map((day) => ({ day: day.day, freeMinor: day.household_free_minor, belowPlan: !day.constraints_passed_through_day }))}
                floorMinor={forecast.household_buffer_minor}
                minDate={forecast.minimum_household_free_date}
                events={keyEvents.map((event) => ({ day: event.day, amountMinor: event.amount_minor, positive: event.amount_minor >= 0 }))}
                currency={forecast.currency}
                locale={locale}
                lowestLabel={copy.outlookLowestFree}
                floorLabel={copy.outlookHouseholdHold}
                scenarioValues={scenarioValues}
              />
              <figcaption className="finance-outlook-chart-legend">
                <span><i className="is-line" /> {copy.outlookFreeCash}</span>
                <span><i className="is-floor" /> {copy.outlookHouseholdHold}</span>
                <span><i className="is-low" /> {copy.outlookLowestFree} ({formatDate(forecast.minimum_household_free_date, locale)})</span>
                {scenarioValues ? <span><i className="is-scenario" /> {locale === "de" ? "Was-wäre-wenn" : "Scenario"}</span> : null}
              </figcaption>
              <details className="finance-outlook-scenario-controls">
                <summary>{locale === "de" ? "Was-wäre-wenn ausprobieren" : "Try a what-if scenario"}</summary>
                <div className="finance-outlook-scenario-fields">
                  <div className="field">
                    <label htmlFor="finance-scenario-oneoff">{locale === "de" ? "Einmalige Ausgabe jetzt" : "One-off spend now"}</label>
                    <div className="finance-money-input"><input id="finance-scenario-oneoff" type="text" inputMode="decimal" autoComplete="off" value={scenarioOneOff} onChange={(event) => setScenarioOneOff(event.target.value)} /><span>{forecast.currency}</span></div>
                  </div>
                  <div className="field">
                    <label htmlFor="finance-scenario-monthly">{locale === "de" ? "Änderung pro Monat" : "Change each month"}</label>
                    <div className="finance-money-input"><input id="finance-scenario-monthly" type="text" inputMode="decimal" autoComplete="off" value={scenarioMonthly} onChange={(event) => setScenarioMonthly(event.target.value)} /><span>{forecast.currency}</span></div>
                  </div>
                  {hasScenario ? <button type="button" className="button button--secondary" onClick={() => { setScenarioOneOff(""); setScenarioMonthly(""); }}>{locale === "de" ? "Zurücksetzen" : "Clear"}</button> : null}
                </div>
                {scenarioLow !== null ? <p className="finance-outlook-scenario-note">{locale === "de" ? "Neuer Tiefpunkt" : "New lowest point"}: <strong>{formatCurrency(scenarioLow, forecast.currency, locale)}</strong></p> : null}
              </details>
            </figure>
            );
          })() : null}

          <section className="finance-outlook-protection" aria-labelledby="finance-outlook-events-title">
            <header><h3 id="finance-outlook-events-title">{copy.outlookKeyDates}</h3></header>
            <dl className="finance-outlook-holds">
              {openingAccounts.filter((row) => row.floor_minor > 0).map((row) => <div key={row.account_id}><dt>{copy.outlookAccountFloor} {accountByID.get(row.account_id)?.label ?? copy.accountsTitle}</dt><dd>{formatCurrency(row.floor_minor, forecast.currency, locale)}</dd></div>)}
              <div><dt>{copy.outlookHouseholdHold}</dt><dd>{formatCurrency(forecast.household_buffer_minor, forecast.currency, locale)}</dd></div>
            </dl>
            {keyEvents.length ? (
              <ol className="finance-outlook-events">
                {keyEvents.slice(0, 3).map((event) => (
                  <li key={event.event_id}>
                    <time dateTime={event.day}>{formatDate(event.day, locale)}</time>
                    <span><strong>{eventKind(event, copy)}</strong><small>{accountByID.get(event.account_id)?.label ?? copy.accountsTitle}</small></span>
                    <strong className={event.amount_minor >= 0 ? "is-positive" : ""}>{formatCurrency(event.amount_minor, event.currency, locale)}</strong>
                  </li>
                ))}
              </ol>
            ) : <p className="finance-outlook-muted">{copy.outlookNoEvents}</p>}
            {keyEvents.length > 3 ? <details className="finance-outlook-more-events"><summary>{locale === "de" ? `${keyEvents.length - 3} weitere Termine` : `${keyEvents.length - 3} more dates`}</summary><ol className="finance-outlook-events">{keyEvents.slice(3).map((event) => <li key={event.event_id}><time dateTime={event.day}>{formatDate(event.day, locale)}</time><span><strong>{eventKind(event, copy)}</strong><small>{accountByID.get(event.account_id)?.label ?? copy.accountsTitle}</small></span><strong className={event.amount_minor >= 0 ? "is-positive" : ""}>{formatCurrency(event.amount_minor, event.currency, locale)}</strong></li>)}</ol></details> : null}
          </section>

          <details
            className="finance-outlook-advanced"
            open={advancedOpen}
            onToggle={(event) => {
              const nextOpen = event.currentTarget.open;
              setAdvancedOpen(nextOpen);
              if (nextOpen) void loadFullForecast(forecast);
            }}
          >
            <summary><span><strong>{locale === "de" ? "So wurde das berechnet" : "How this was worked out"}</strong><small>{locale === "de" ? "Konten, Annahmen und tägliche Beträge" : "Accounts, assumptions and day-by-day figures"}</small></span></summary>
          <section className="finance-outlook-assumptions" aria-labelledby="finance-outlook-assumptions-title">
            <h3 id="finance-outlook-assumptions-title"><ShieldCheck aria-hidden="true" size={18} /> {copy.outlookAssumptions}</h3>
            {assumptions.length ? <ul>{assumptions.map((assumption) => <li key={assumption}>{assumption}</li>)}</ul> : <p>{copy.outlookNoAssumptions}</p>}
          </section>
          {advancedOpen && advancedBusy && !fullForecast ? <p className="finance-outlook-inline-state" aria-busy="true">{locale === "de" ? "Tageswerte werden geladen…" : "Loading day-by-day figures…"}</p> : null}
          {advancedOpen && advancedError && !fullForecast ? <div className="finance-outlook-load-error" role="alert"><p className="form-error">{advancedError}</p><button type="button" className="button button--secondary" onClick={() => void loadFullForecast(forecast)}>{locale === "de" ? "Erneut versuchen" : "Try again"}</button></div> : null}
          {advancedOpen && fullForecast ? <>
          <details className="finance-outlook-path">
            <summary id="finance-outlook-path-title"><span><strong>{copy.outlookDailyPath}</strong><small>{copy.outlookDailyPathDetail}</small></span></summary>
            <div className="finance-outlook-table-scroll" tabIndex={0} role="region" aria-labelledby="finance-outlook-path-title" aria-describedby="finance-outlook-scroll-help">
              <p className="visually-hidden" id="finance-outlook-scroll-help">{locale === "de" ? "Mit den Pfeiltasten horizontal durch die Kontospalten bewegen." : "Use the arrow keys to move horizontally through the account columns."}</p>
              <table>
                <thead><tr><th>{copy.outlookDay}</th><th>{copy.outlookHouseholdMoney}</th><th>{copy.outlookFreeCash}</th>{relevantAccounts.map((account) => <th key={account.id}>{account.label}</th>)}</tr></thead>
                <tbody>{detailDays.map((day) => (
                  <tr key={day.day} className={cn(day.day === forecast.minimum_household_free_date && "is-lowest", !day.constraints_passed_through_day && "is-warning")}>
                    <th scope="row"><time dateTime={day.day}>{formatDate(day.day, locale)}</time>{!day.constraints_passed_through_day ? <small>{copy.outlookBelowPlan}</small> : null}</th>
                    <td>{formatCurrency(day.household_liquid_minor, forecast.currency, locale)}</td>
                    <td>{formatCurrency(day.household_free_minor, forecast.currency, locale)}</td>
                    {relevantAccounts.map((account) => {
                      const balance = day.accounts.find((row) => row.account_id === account.id);
                      return <td key={account.id}>{balance ? formatCurrency(balance.balance_minor, forecast.currency, locale) : "—"}</td>;
                    })}
                  </tr>
                ))}</tbody>
              </table>
            </div>
          </details>

          <section className="finance-safe-panel" aria-labelledby="finance-safe-title">
            <header><h3 id="finance-safe-title">{copy.safeTitle}</h3><p>{copy.safeDetail}</p></header>
            {routes.length ? (
              <form className="finance-safe-form" onSubmit={(event) => void checkSafeAmount(event)} aria-busy={safeBusy}>
                <div className="finance-safe-fields">
                  <div className="field"><label htmlFor="finance-safe-route">{copy.safePaymentRoute}</label><select id="finance-safe-route" value={routeValue} disabled={safeBusy} onChange={(event) => { setRouteValue(event.target.value); setSafeResult(null); setSafeError(""); }}>{routes.map((route) => <option value={route.value} key={route.value}>{route.label}</option>)}</select></div>
                  <div className="field"><label htmlFor="finance-safe-date">{copy.safeSpendDate}</label><input id="finance-safe-date" type="date" autoComplete="off" min={forecast.start_date} max={forecast.end_date} value={spendDate} disabled={safeBusy} onChange={(event) => { setSpendDate(event.target.value); setSafeResult(null); setSafeError(""); }} /></div>
                </div>
                <fieldset className="finance-safe-estimate" aria-describedby={estimateError ? "finance-safe-estimate-error" : "finance-safe-estimate-help"}>
                  <legend>{copy.safeUnobservedTitle}</legend>
                  <p id="finance-safe-estimate-help">{copy.safeUnobservedDetail}</p>
                  <div className="finance-safe-fields">
                    <div className="field"><label htmlFor="finance-safe-low">{copy.safeUnobservedLow}</label><div className="finance-money-input"><input id="finance-safe-low" type="text" inputMode="decimal" autoComplete="off" value={unobservedLow} aria-invalid={estimateError ? "true" : undefined} onChange={(event) => { setUnobservedLow(event.target.value); setEstimateError(""); setSafeResult(null); }} /><span>{forecast.currency}</span></div></div>
                    <div className="field"><label htmlFor="finance-safe-high">{copy.safeUnobservedHigh}</label><div className="finance-money-input"><input id="finance-safe-high" type="text" inputMode="decimal" autoComplete="off" value={unobservedHigh} aria-invalid={estimateError ? "true" : undefined} onChange={(event) => { setUnobservedHigh(event.target.value); setEstimateError(""); setSafeResult(null); }} /><span>{forecast.currency}</span></div></div>
                  </div>
                  {estimateError ? <p id="finance-safe-estimate-error" className="field-error">{estimateError}</p> : null}
                </fieldset>
                {safeError ? <p className="form-error" role="alert">{safeError}</p> : null}
                <button type="submit" className="button button--primary" disabled={!online || safeBusy || !routeValue || !spendDate}><CircleDollarSign aria-hidden="true" size={17} /> {safeBusy ? copy.checkingSafeAmount : copy.checkSafeAmount}</button>
              </form>
            ) : (
              <article className={cn("finance-safe-answer", noRouteHigh === 0 && "is-warning")}>
                <header><CheckCircle2 aria-hidden="true" size={20} /><span>{copy.safeAnswerModes.ESTIMATED_RANGE}</span></header>
                <div><span>{copy.safeRangeLabel}</span><strong>{formatCurrency(noRouteLow, forecast.currency, locale)}–{formatCurrency(noRouteHigh, forecast.currency, locale)}</strong></div>
                <p className="finance-safe-basis-note">{copy.safeRouteMissing}</p>
              </article>
            )}

            {shownSafeResult ? (
              <article className={cn("finance-safe-answer", safeHasNoAmount && "is-warning")} aria-live="polite">
                <header>{safeHasNoAmount ? <AlertCircle aria-hidden="true" size={20} /> : <CheckCircle2 aria-hidden="true" size={20} />}<span>{copy.safeAnswerModes[shownSafeResult.answer_mode]}</span></header>
                <div><span>{shownSafeResult.answer_mode === "ESTIMATED_RANGE" ? copy.safeRangeLabel : copy.safeExactLabel}</span><strong>{shownSafeResult.answer_mode === "ESTIMATED_RANGE" && shownSafeResult.low_minor !== null && shownSafeResult.high_minor !== null ? `${formatCurrency(shownSafeResult.low_minor, shownSafeResult.currency, locale)}–${formatCurrency(shownSafeResult.high_minor, shownSafeResult.currency, locale)}` : shownSafeResult.amount_minor !== null ? formatCurrency(shownSafeResult.amount_minor, shownSafeResult.currency, locale) : copy.safeNoAmount}</strong></div>
                {safeHasNoAmount ? <p>{copy.safeNoAmount}</p> : null}
                {shownSafeResult.limiting_event ? <OutlookLimit limit={shownSafeResult.limiting_event} forecast={forecast} accounts={accountByID} locale={locale} copy={copy} /> : null}
                {safeBasisDetail ? <p className="finance-safe-basis-note">{safeBasisDetail}</p> : null}
              </article>
            ) : null}
          </section>
          </> : null}
          </details>
        </div>
      ) : null}
    </section>
  );
}
