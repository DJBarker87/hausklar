import { AlertCircle, CheckCircle2, CreditCard, HelpCircle, ReceiptText } from "lucide-react";
import { useEffect, useLayoutEffect, useMemo, useRef, useState, type FormEvent } from "react";

import { api } from "../api";
import { getFinanceAdvancedStrings } from "../financeAdvancedStrings";
import { todayInTimeZone } from "../financeDate";
import type { FinanceLocale } from "../financeStrings";
import type { FinanceAccount, FinanceMaterialQuestion, FinancePatternScan, FinanceRecurringSeries, FinanceSettings, FinanceSpace } from "../types";

type LoadState = "loading" | "ready" | "error";

type SalaryForm = {
  name: string;
  expected: string;
  low: string;
  high: string;
  interval: "MONTHLY" | "FOUR_WEEKLY" | "ANNUAL" | "IRREGULAR";
  nextDate: string;
  workingDay: "" | "PREVIOUS" | "NEXT";
};

function isAbortError(error: unknown) {
  return error instanceof DOMException && error.name === "AbortError";
}

function amountToMinor(value: string): number | null {
  const normalized = value.trim().replace(",", ".");
  if (!/^(?:0|[1-9]\d*)(?:\.\d{1,2})?$/.test(normalized)) return null;
  const [whole, fraction = ""] = normalized.split(".");
  const minor = Number(whole) * 100 + Number(fraction.padEnd(2, "0"));
  return Number.isSafeInteger(minor) ? minor : null;
}

function amountInput(minor: number | null) {
  return minor == null ? "" : (minor / 100).toFixed(2);
}

function formatCurrency(minor: number, currency: string, locale: FinanceLocale) {
  return new Intl.NumberFormat(locale === "de" ? "de-DE" : "en-GB", {
    style: "currency",
    currency,
  }).format(minor / 100);
}

function questionPrompt(
  question: FinanceMaterialQuestion,
  series: FinanceRecurringSeries | null,
  locale: FinanceLocale,
) {
  if (
    question.question_kind === "SALARY"
    && question.action_kind === "CONFIRM_RECURRING"
    && /minor[- ]units?/i.test(question.prompt)
  ) {
    const name = series?.name ?? (locale === "de" ? "diese regelmäßige Zahlung" : "this regular payment");
    const amount = formatCurrency(
      series?.expected_minor ?? question.priority_minor,
      series?.currency ?? question.currency,
      locale,
    );
    return locale === "de"
      ? `Ist ${name} dein Gehalt, normalerweise etwa ${amount}?`
      : `Is ${name} your salary, normally around ${amount}?`;
  }
  if (
    question.question_kind === "LARGE_UNITEMISED_PURCHASE"
    && /minor[- ]units?/i.test(question.prompt)
  ) {
    const amount = formatCurrency(question.priority_minor, question.currency, locale);
    return locale === "de"
      ? `Was war in dem Einkauf über ${amount} enthalten?`
      : `What was included in the ${amount} purchase?`;
  }
  if (/minor[- ]units?/i.test(question.prompt)) {
    return locale === "de"
      ? "Prüfe die gespeicherten Angaben zu dieser Zahlung."
      : "Check the saved details for this payment.";
  }
  return question.prompt;
}

function salaryForm(series: FinanceRecurringSeries | null): SalaryForm {
  return {
    name: series?.name ?? "",
    expected: amountInput(series?.expected_minor ?? null),
    low: amountInput(series?.low_minor ?? series?.expected_minor ?? null),
    high: amountInput(series?.high_minor ?? series?.expected_minor ?? null),
    interval: series?.interval_kind ?? "MONTHLY",
    nextDate: series?.next_expected_date ?? "",
    workingDay: series?.working_day_adjustment ?? "",
  };
}

export function FinanceMaterialQuestionsView({
  spaces,
  accounts,
  locale,
  onOpenSetup,
  onOpenPurchases,
}: {
  spaces: FinanceSpace[];
  accounts: FinanceAccount[];
  locale: FinanceLocale;
  onOpenSetup: () => void;
  onOpenPurchases: (sourceID: string | null) => void;
}) {
  const copy = getFinanceAdvancedStrings(locale).questions;
  const [loadState, setLoadState] = useState<LoadState>("loading");
  const [retryKey, setRetryKey] = useState(0);
  const [questions, setQuestions] = useState<FinanceMaterialQuestion[]>([]);
  const [series, setSeries] = useState<FinanceRecurringSeries[]>([]);
  const [activeIndex, setActiveIndex] = useState(0);
  const [salary, setSalary] = useState<SalaryForm>(() => salaryForm(null));
  const [nurseryAmount, setNurseryAmount] = useState("");
  const [nurseryDates, setNurseryDates] = useState([""]);
  const [working, setWorking] = useState(false);
  const [error, setError] = useState("");
  const [notice, setNotice] = useState("");
  const [showDetails, setShowDetails] = useState(false);
  const [householdToday, setHouseholdToday] = useState("");
  const errorRef = useRef<HTMLParagraphElement>(null);
  const selectionKey = spaces.map((space) => space.id).join(":");
  const allowedSpaceIDs = useMemo(() => new Set(spaces.map((space) => space.id)), [spaces]);
  const activeQuestion = questions[Math.min(activeIndex, Math.max(0, questions.length - 1))] ?? null;
  const activeSeries = activeQuestion?.action_target_id
    ? series.find((item) => item.id === activeQuestion.action_target_id && item.space_id === activeQuestion.space_id) ?? null
    : null;
  const activeSpace = activeQuestion
    ? spaces.find((space) => space.id === activeQuestion.space_id) ?? null
    : null;

  useEffect(() => {
    const controller = new AbortController();
    let active = true;
    setLoadState("loading");
    setError("");
    Promise.all([
      api<FinanceSettings>("/finance/settings", { signal: controller.signal }, true, false),
      Promise.all(spaces.map(async (space) => {
        const encoded = encodeURIComponent(space.id);
        const currency = accounts.find((account) => account.space_id === space.id)?.currency ?? "GBP";
        return api<FinancePatternScan>(
          `/finance/patterns/scan?space_id=${encoded}&currency=${encodeURIComponent(currency)}`,
          { method: "POST", signal: controller.signal },
          true,
          false,
        );
      })),
    ])
      .then(([settings, results]) => {
        if (!active) return;
        setHouseholdToday(todayInTimeZone(settings.household_timezone));
        setQuestions(results.flatMap((result) => result.questions)
          .filter((question) => question.status === "OPEN" && allowedSpaceIDs.has(question.space_id))
          .sort((left, right) => right.priority_minor - left.priority_minor));
        setSeries(results.flatMap((result) => result.recurring_series)
          .filter((item) => allowedSpaceIDs.has(item.space_id)));
        setActiveIndex(0);
        setLoadState("ready");
      })
      .catch((caught: unknown) => {
        if (!active || isAbortError(caught)) return;
        setLoadState("error");
      });
    return () => {
      active = false;
      controller.abort();
    };
  }, [selectionKey, retryKey]);

  useLayoutEffect(() => {
    setSalary(salaryForm(activeSeries));
    setNurseryAmount("");
    setNurseryDates([""]);
    setError("");
    setShowDetails(false);
  }, [activeQuestion?.id, activeSeries?.id]);

  function showActionError() {
    setError(copy.actionError);
    window.requestAnimationFrame(() => errorRef.current?.focus());
  }

  function resolveLocally(questionID: string) {
    setQuestions((current) => current.filter((question) => question.id !== questionID));
    setActiveIndex(0);
    setNotice(copy.saved);
  }

  async function saveSalary(event: FormEvent) {
    event.preventDefault();
    if (!activeQuestion || working) return;
    const expected = amountToMinor(salary.expected);
    const low = amountToMinor(salary.low);
    const high = amountToMinor(salary.high);
    if (!householdToday || !salary.name.trim() || expected == null || low == null || high == null || low > expected || expected > high || !salary.nextDate || salary.nextDate < householdToday) {
      setError(copy.formError);
      return;
    }
    setWorking(true);
    setError("");
    setNotice("");
    try {
      const updated = await api<FinanceMaterialQuestion>(
        `/finance/questions/${encodeURIComponent(activeQuestion.id)}/correct`,
        {
          method: "PUT",
          body: JSON.stringify({
            recurring: {
              name: salary.name.trim(),
              series_type: "SALARY",
              interval_kind: salary.interval,
              expected_minor: expected,
              low_minor: low,
              high_minor: high,
              currency: activeQuestion.currency,
              next_expected_date: salary.nextDate,
              working_day_adjustment: salary.workingDay || null,
            },
          }),
        },
        true,
        false,
      );
      if (updated.id !== activeQuestion.id || updated.status !== "CORRECTED") throw new Error(copy.actionError);
      resolveLocally(activeQuestion.id);
    } catch {
      showActionError();
    } finally {
      setWorking(false);
    }
  }

  async function saveNursery(event: FormEvent) {
    event.preventDefault();
    if (!activeQuestion || working) return;
    const amount = amountToMinor(nurseryAmount);
    const dates = [...new Set(nurseryDates.filter(Boolean))].sort();
    if (!householdToday || amount == null || dates.length === 0 || dates.length !== nurseryDates.filter(Boolean).length || dates.some((date) => date < householdToday)) {
      setError(copy.formError);
      return;
    }
    setWorking(true);
    setError("");
    setNotice("");
    try {
      const updated = await api<FinanceMaterialQuestion>(
        `/finance/questions/${encodeURIComponent(activeQuestion.id)}/correct`,
        {
          method: "PUT",
          body: JSON.stringify({ nursery_expected_minor: amount, nursery_due_dates: dates }),
        },
        true,
        false,
      );
      if (updated.id !== activeQuestion.id || updated.status !== "CORRECTED") throw new Error(copy.actionError);
      resolveLocally(activeQuestion.id);
    } catch {
      showActionError();
    } finally {
      setWorking(false);
    }
  }

  async function dismissQuestion() {
    if (!activeQuestion || working) return;
    setWorking(true);
    setError("");
    setNotice("");
    try {
      const updated = await api<FinanceMaterialQuestion>(
        `/finance/questions/${encodeURIComponent(activeQuestion.id)}/dismiss`,
        { method: "POST" },
        true,
        false,
      );
      if (updated.id !== activeQuestion.id || updated.status !== "DISMISSED") throw new Error(copy.actionError);
      resolveLocally(activeQuestion.id);
    } catch {
      showActionError();
    } finally {
      setWorking(false);
    }
  }

  async function confirmQuestion() {
    if (!activeQuestion || working) return;
    setWorking(true);
    setError("");
    setNotice("");
    try {
      const updated = await api<FinanceMaterialQuestion>(
        `/finance/questions/${encodeURIComponent(activeQuestion.id)}/confirm`,
        { method: "POST", body: JSON.stringify({ answer_text: null }) },
        true,
        false,
      );
      if (updated.id !== activeQuestion.id || updated.status !== "CONFIRMED") throw new Error(copy.actionError);
      resolveLocally(activeQuestion.id);
    } catch {
      showActionError();
    } finally {
      setWorking(false);
    }
  }

  return (
    <section className="finance-material-panel" aria-labelledby="finance-material-title">
      <header>
        <div><span className="finance-status-label"><HelpCircle aria-hidden="true" size={15} /> {copy.title}</span><h2 id="finance-material-title">{copy.title}</h2><p>{copy.detail}</p></div>
      </header>

      {loadState === "loading" ? (
        <div className="finance-material-skeleton" aria-label={copy.loading} aria-busy="true"><div /><div /><div /></div>
      ) : loadState === "error" ? (
        <div className="finance-material-state is-error" role="alert"><AlertCircle aria-hidden="true" size={22} /><div><strong>{copy.errorTitle}</strong><p>{copy.errorDetail}</p></div><button type="button" className="button button--secondary" onClick={() => setRetryKey((value) => value + 1)}>{copy.retry}</button></div>
      ) : !activeQuestion ? (
        <div className="finance-material-state"><CheckCircle2 aria-hidden="true" size={24} /><div><strong>{copy.emptyTitle}</strong><p>{notice || copy.emptyDetail}</p></div></div>
      ) : (
        <article className="finance-material-card">
          <header>
            <span>{copy.questionOf} {Math.min(activeIndex + 1, questions.length)} {copy.of} {questions.length}</span>
            <strong>{formatCurrency(activeQuestion.priority_minor, activeQuestion.currency, locale)}</strong>
          </header>
          <div className="finance-question-scope"><span>{activeSpace?.kind === "personal" ? copy.personal : copy.household}</span><strong>{activeSpace?.name}</strong></div>
          <p className="finance-material-prompt">{questionPrompt(activeQuestion, activeSeries, locale)}</p>
          <small>{copy.impact}: {formatCurrency(activeQuestion.priority_minor, activeQuestion.currency, locale)}</small>

          <div className="finance-material-choices">
            {activeQuestion.question_kind === "SALARY" ? (
              <>
                {activeQuestion.action_kind === "CONFIRM_RECURRING" ? <button type="button" className="button button--primary" disabled={working} onClick={() => void confirmQuestion()}>{copy.yesUseThis}</button> : null}
                <button type="button" className={activeQuestion.action_kind === "CONFIRM_RECURRING" ? "button button--secondary" : "button button--primary"} disabled={working} onClick={() => setShowDetails(true)}>{activeQuestion.action_kind === "CONFIRM_RECURRING" ? copy.changeDetails : copy.addDetails}</button>
                <button type="button" className="button button--secondary" disabled={working} onClick={() => void dismissQuestion()}>{copy.notThis}</button>
              </>
            ) : activeQuestion.question_kind === "NURSERY" ? (
              <><button type="button" className="button button--primary" disabled={working} onClick={() => setShowDetails(true)}>{copy.addAmountDates}</button><button type="button" className="button button--secondary" disabled={working} onClick={() => void dismissQuestion()}>{copy.notNeeded}</button></>
            ) : activeQuestion.question_kind === "MISSING_CARD" ? (
              <><button type="button" className="button button--primary" onClick={onOpenSetup}><CreditCard aria-hidden="true" size={17} /> {copy.addCard}</button><button type="button" className="button button--secondary" disabled={working} onClick={() => void dismissQuestion()}>{copy.notNow}</button></>
            ) : (
              <><button type="button" className="button button--primary" onClick={() => onOpenPurchases(activeQuestion.action_target_id)}><ReceiptText aria-hidden="true" size={17} /> {copy.reviewPurchase}</button><button type="button" className="button button--secondary" disabled={working} onClick={() => void dismissQuestion()}>{copy.skipPurchase}</button></>
            )}
          </div>

          {activeQuestion.question_kind === "SALARY" && showDetails ? (
            <form className="finance-material-form" onSubmit={(event) => void saveSalary(event)} aria-busy={working}>
              <fieldset><legend>{copy.salaryDetails}</legend>
                <div className="finance-material-grid">
                  <div className="field"><label htmlFor="finance-salary-name">{copy.name}</label><input id="finance-salary-name" autoComplete="off" maxLength={200} value={salary.name} onChange={(event) => setSalary((current) => ({ ...current, name: event.target.value }))} /></div>
                  <div className="field"><label htmlFor="finance-salary-expected">{copy.expected}</label><input id="finance-salary-expected" type="text" inputMode="decimal" autoComplete="off" value={salary.expected} onChange={(event) => setSalary((current) => ({ ...current, expected: event.target.value }))} /></div>
                  <div className="field"><label htmlFor="finance-salary-low">{copy.low}</label><input id="finance-salary-low" type="text" inputMode="decimal" autoComplete="off" value={salary.low} onChange={(event) => setSalary((current) => ({ ...current, low: event.target.value }))} /></div>
                  <div className="field"><label htmlFor="finance-salary-high">{copy.high}</label><input id="finance-salary-high" type="text" inputMode="decimal" autoComplete="off" value={salary.high} onChange={(event) => setSalary((current) => ({ ...current, high: event.target.value }))} /></div>
                  <div className="field"><label htmlFor="finance-salary-interval">{copy.interval}</label><select id="finance-salary-interval" value={salary.interval} onChange={(event) => setSalary((current) => ({ ...current, interval: event.target.value as SalaryForm["interval"] }))}>{Object.entries(copy.intervals).map(([value, label]) => <option value={value} key={value}>{label}</option>)}</select></div>
                  <div className="field"><label htmlFor="finance-salary-date">{copy.nextDate}</label><input id="finance-salary-date" type="date" autoComplete="off" min={householdToday} value={salary.nextDate} onChange={(event) => setSalary((current) => ({ ...current, nextDate: event.target.value }))} /></div>
                  <div className="field"><label htmlFor="finance-salary-working-day">{copy.workingDay}</label><select id="finance-salary-working-day" value={salary.workingDay} onChange={(event) => setSalary((current) => ({ ...current, workingDay: event.target.value as SalaryForm["workingDay"] }))}><option value="">{copy.noShift}</option><option value="PREVIOUS">{copy.previousWorkingDay}</option><option value="NEXT">{copy.nextWorkingDay}</option></select></div>
                </div>
              </fieldset>
              {error ? <p className="form-error" role="alert" tabIndex={-1} ref={errorRef}>{error}</p> : null}
              <button type="submit" className="button button--primary" disabled={working}>{working ? copy.working : activeQuestion.action_kind === "CONFIRM_RECURRING" ? copy.confirmSalary : copy.saveSalary}</button>
            </form>
          ) : activeQuestion.question_kind === "NURSERY" && showDetails ? (
            <form className="finance-material-form" onSubmit={(event) => void saveNursery(event)} aria-busy={working}>
              <div className="field"><label htmlFor="finance-nursery-amount">{copy.nurseryAmount}</label><input id="finance-nursery-amount" type="text" inputMode="decimal" autoComplete="off" value={nurseryAmount} onChange={(event) => setNurseryAmount(event.target.value)} /></div>
              <fieldset><legend>{copy.nurseryDates}</legend><div className="finance-nursery-dates">{nurseryDates.map((date, index) => <div key={index}><input type="date" min={householdToday} aria-label={`${copy.nurseryDates} ${index + 1}`} autoComplete="off" value={date} onChange={(event) => setNurseryDates((current) => current.map((value, itemIndex) => itemIndex === index ? event.target.value : value))} />{nurseryDates.length > 1 ? <button type="button" className="button button--secondary" aria-label={`${copy.removeDate} ${index + 1}`} onClick={() => setNurseryDates((current) => current.filter((_, itemIndex) => itemIndex !== index))}>{copy.removeDate}</button> : null}</div>)}</div><button type="button" className="button button--secondary" onClick={() => setNurseryDates((current) => [...current, ""])}>{copy.addDate}</button></fieldset>
              {error ? <p className="form-error" role="alert" tabIndex={-1} ref={errorRef}>{error}</p> : null}
              <button type="submit" className="button button--primary" disabled={working}>{working ? copy.working : copy.saveNursery}</button>
            </form>
          ) : null}

          {!showDetails && error ? <p className="form-error" role="alert" tabIndex={-1} ref={errorRef}>{error}</p> : null}
        </article>
      )}
    </section>
  );
}
