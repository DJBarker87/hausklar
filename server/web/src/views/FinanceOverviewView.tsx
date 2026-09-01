import { CalendarDays, PiggyBank, ReceiptText, Target } from "lucide-react";

import type { FinanceOverview, FinanceSpendingType } from "../types";
import type { FinanceLocale } from "../financeStrings";

function formatMoney(minor: number, currency: string, locale: FinanceLocale, signed = false) {
  return new Intl.NumberFormat(locale === "de" ? "de-DE" : "en-GB", {
    style: "currency",
    currency,
    currencyDisplay: "symbol",
    signDisplay: signed ? "exceptZero" : "auto",
  }).format(minor / 100);
}

function formatDate(value: string, locale: FinanceLocale, style: "month" | "short" = "short") {
  const date = new Date(`${value}T00:00:00`);
  if (Number.isNaN(date.valueOf())) return value;
  return new Intl.DateTimeFormat(locale === "de" ? "de-DE" : "en-GB", style === "month"
    ? { month: "long", year: "numeric" }
    : { day: "numeric", month: "short" }).format(date);
}

const SPENDING_TYPE_ORDER: FinanceSpendingType[] = ["FIXED", "FLEXIBLE", "DISCRETIONARY", "UNCATEGORISED"];

function spendingTypeLabel(type: FinanceSpendingType, locale: FinanceLocale) {
  const english: Record<FinanceSpendingType, string> = {
    FIXED: "Fixed",
    FLEXIBLE: "Flexible",
    DISCRETIONARY: "Discretionary",
    UNCATEGORISED: "Uncategorised",
  };
  const german: Record<FinanceSpendingType, string> = {
    FIXED: "Fix",
    FLEXIBLE: "Flexibel",
    DISCRETIONARY: "Optional",
    UNCATEGORISED: "Nicht kategorisiert",
  };
  return (locale === "de" ? german : english)[type];
}

function SpendTypeChart({ overview, locale }: { overview: FinanceOverview; locale: FinanceLocale }) {
  const categories = overview.spending_by_category
    .filter((item) => item.spent_minor > 0)
    .sort((left, right) => {
      const typeOrder = SPENDING_TYPE_ORDER.indexOf(left.spending_type) - SPENDING_TYPE_ORDER.indexOf(right.spending_type);
      return typeOrder || right.spent_minor - left.spent_minor || left.name.localeCompare(right.name);
    });
  if (!categories.length || overview.spending_minor <= 0) {
    return (
      <div className="finance-overview-inline-empty">
        <ReceiptText aria-hidden="true" size={20} />
        <p>{locale === "de" ? "In diesem Monat wurden noch keine Ausgaben erfasst." : "No spending recorded this month yet."}</p>
      </div>
    );
  }
  const description = categories
    .map((item) => `${item.name} ${formatMoney(item.spent_minor, overview.currency, locale)}`)
    .join(", ");
  return (
    <div className="finance-overview-spend-chart">
      <div className="finance-overview-spend-bar" role="img" aria-label={description}>
        {categories.map((item, index) => (
          <span
            key={item.category_key}
            className={`finance-series-${(index % 6) + 1}`}
            style={{ width: `${Math.max(0, item.share_bps) / 100}%` }}
          />
        ))}
      </div>
      <div className="finance-overview-spend-groups">
        {SPENDING_TYPE_ORDER.map((type) => {
          const grouped = categories.filter((category) => category.spending_type === type);
          if (!grouped.length) return null;
          return <section key={type} aria-labelledby={`finance-spend-type-${type}`}><h3 id={`finance-spend-type-${type}`}>{spendingTypeLabel(type, locale)}</h3><ul className="finance-overview-spend-legend">{grouped.map((item) => {
            const index = categories.findIndex((category) => category.category_key === item.category_key);
            return <li key={item.category_key}><i className={`finance-series-${(index % 6) + 1}`} aria-hidden="true" /><span>{item.name}</span><strong>{formatMoney(item.spent_minor, overview.currency, locale)}</strong></li>;
          })}</ul></section>;
        })}
      </div>
    </div>
  );
}

function SavingsTrend({ overview, locale }: { overview: FinanceOverview; locale: FinanceLocale }) {
  const points = overview.savings_series;
  if (points.length < 2) return null;
  const width = 720;
  const height = 132;
  const padX = 4;
  const padY = 12;
  const values = points.map((point) => point.balance_minor);
  const min = Math.min(...values);
  const max = Math.max(...values);
  const span = max - min || 1;
  const x = (index: number) => padX + (index / (points.length - 1)) * (width - padX * 2);
  const y = (value: number) => padY + (1 - (value - min) / span) * (height - padY * 2);
  const line = points
    .map((point, index) => `${index === 0 ? "M" : "L"} ${x(index).toFixed(1)} ${y(point.balance_minor).toFixed(1)}`)
    .join(" ");
  const area = `${line} L ${x(points.length - 1).toFixed(1)} ${height - padY} L ${padX} ${height - padY} Z`;
  const label = locale === "de"
    ? `Spartrend von ${formatMoney(values[0], overview.currency, locale)} auf ${formatMoney(values.at(-1) ?? 0, overview.currency, locale)}`
    : `Savings trend from ${formatMoney(values[0], overview.currency, locale)} to ${formatMoney(values.at(-1) ?? 0, overview.currency, locale)}`;
  return (
    <figure className="finance-overview-savings-chart">
      <svg viewBox={`0 0 ${width} ${height}`} preserveAspectRatio="none" role="img" aria-label={label}>
        <path className="finance-overview-savings-area" d={area} />
        <path className="finance-overview-savings-line" d={line} />
      </svg>
      <figcaption>
        <time dateTime={points[0].date}>{formatDate(points[0].date, locale)}</time>
        <time dateTime={points.at(-1)?.date}>{formatDate(points.at(-1)?.date ?? "", locale)}</time>
      </figcaption>
    </figure>
  );
}

export function FinanceOverviewView({
  overview,
  locale,
  onOpenGoals,
}: {
  overview: FinanceOverview;
  locale: FinanceLocale;
  onOpenGoals: () => void;
}) {
  const isGerman = locale === "de";
  const monthLabel = formatDate(overview.month_start, locale, "month");
  const savingsChange = overview.savings_change_minor;
  return (
    <div className="finance-overview">
      <section className="finance-overview-section finance-overview-month" aria-labelledby="finance-overview-month-title">
        <header>
          <div>
            <span className="finance-overview-kicker">{monthLabel}</span>
            <h2 id="finance-overview-month-title">{isGerman ? "Ausgaben in diesem Monat" : "Spending this month"}</h2>
            <p>{overview.scope === "household"
              ? (isGerman ? "Zusammengefasste Haushaltszahlen" : "Combined household totals")
              : `${isGerman ? "Bis" : "Through"} ${formatDate(overview.through_date, locale)}`}</p>
          </div>
          <strong className="finance-overview-primary-money">{formatMoney(overview.spending_minor, overview.currency, locale)}</strong>
        </header>
        <SpendTypeChart overview={overview} locale={locale} />
      </section>

      <section className="finance-overview-section finance-overview-budgets" aria-labelledby="finance-overview-budgets-title">
        <header>
          <div>
            <span className="finance-overview-icon"><Target aria-hidden="true" size={18} /></span>
            <div><h2 id="finance-overview-budgets-title">{isGerman ? "Budgets" : "Budgets"}</h2><p>{isGerman ? "Ausgegeben und verbleibend" : "Spent and remaining"}</p></div>
          </div>
        </header>
        {overview.budget_buckets.length ? (
          <ul className="finance-overview-budget-list">
            {overview.budget_buckets.map((budget) => {
              const maximum = Math.max(1, budget.budget_minor);
              const value = Math.min(maximum, Math.max(0, budget.spent_minor));
              return (
                <li key={budget.category_key}>
                  <div><strong>{budget.name}</strong><span><b>{formatMoney(budget.spent_minor, overview.currency, locale)}</b> {isGerman ? "ausgegeben" : "spent"}</span></div>
                  <progress aria-label={`${budget.name}: ${isGerman ? "ausgegeben" : "spent"}`} max={maximum} value={value} />
                  <span><b>{formatMoney(budget.remaining_minor, overview.currency, locale)}</b> {isGerman ? "übrig" : "left"}</span>
                </li>
              );
            })}
          </ul>
        ) : (
          <div className="finance-overview-setup">
            <p>{isGerman ? "Lege ein paar Budgets fest, damit du auf einen Blick siehst, was noch übrig ist." : "Set a few budgets to see what is still available at a glance."}</p>
            <button type="button" className="button button--secondary" onClick={onOpenGoals}>{isGerman ? "Budgets einrichten" : "Set up budgets"}</button>
          </div>
        )}
      </section>

      <section className="finance-overview-section finance-overview-payday" aria-labelledby="finance-overview-payday-title">
        <header>
          <div>
            <span className="finance-overview-icon"><CalendarDays aria-hidden="true" size={18} /></span>
            <div><h2 id="finance-overview-payday-title">{isGerman ? "Bis zum nächsten Zahltag" : "Until next payday"}</h2><p>{overview.next_paycheck_date ? <>{formatDate(overview.next_paycheck_date, locale)}{overview.next_paycheck_minor == null ? null : ` · ${formatMoney(overview.next_paycheck_minor, overview.currency, locale)}`}</> : (isGerman ? "Noch kein bestätigter Zahltag" : "No confirmed payday yet")}</p></div>
          </div>
          <div className="finance-overview-payday-total"><span>{isGerman ? "Verfügbar" : "Money left"}</span><strong>{overview.left_until_payday_minor == null ? "—" : formatMoney(overview.left_until_payday_minor, overview.currency, locale)}</strong>{overview.current_available_minor == null ? null : <small>{isGerman ? "Aktuell verfügbar" : "Available now"} {formatMoney(overview.current_available_minor, overview.currency, locale)}</small>}</div>
        </header>
        <div className="finance-overview-commitments">
          <h3>{overview.next_paycheck_date
            ? (isGerman ? "Vorher noch fällig" : "Still due before then")
            : (isGerman ? "Kommende Verpflichtungen" : "Upcoming commitments")}</h3>
          {overview.commitments_before_payday_count ? <p className="finance-overview-commitment-total"><strong>{formatMoney(overview.commitments_before_payday_minor, overview.currency, locale)}</strong> · {overview.commitments_before_payday_count} {isGerman ? (overview.commitments_before_payday_count === 1 ? "Verpflichtung" : "Verpflichtungen") : (overview.commitments_before_payday_count === 1 ? "commitment" : "commitments")}</p> : null}
          {overview.upcoming_commitments.length ? <ul>{overview.upcoming_commitments.map((commitment, index) => (
            <li key={`${commitment.name}-${commitment.due_date}-${index}`}><span><strong>{commitment.name}</strong><time dateTime={commitment.due_date}>{formatDate(commitment.due_date, locale)}</time></span><strong>{formatMoney(commitment.amount_minor, overview.currency, locale)}</strong></li>
          ))}</ul> : <p>{overview.next_paycheck_date ? (overview.commitments_before_payday_count ? (isGerman ? "Die Summe enthält alle Verpflichtungen vor dem Zahltag." : "The total includes every commitment before payday.") : (isGerman ? "Vor dem Zahltag sind keine weiteren Verpflichtungen fällig." : "No more commitments are due before payday.")) : (isGerman ? "Füge einen bestätigten Zahltag hinzu, um diesen Betrag zu berechnen." : "Add a confirmed payday to calculate this amount.")}</p>}
        </div>
      </section>

      <section className="finance-overview-section finance-overview-savings" aria-labelledby="finance-overview-savings-title">
        <header>
          <div>
            <span className="finance-overview-icon"><PiggyBank aria-hidden="true" size={18} /></span>
            <div><h2 id="finance-overview-savings-title">{isGerman ? "Ersparnisse" : "Savings"}</h2>{savingsChange == null ? null : <p className={savingsChange < 0 ? "is-negative" : "is-positive"}>{formatMoney(savingsChange, overview.currency, locale, true)} {isGerman ? "in diesem Zeitraum" : "this period"}</p>}</div>
          </div>
          <strong className="finance-overview-secondary-money">{overview.savings_balance_minor == null ? "—" : formatMoney(overview.savings_balance_minor, overview.currency, locale)}</strong>
        </header>
        <SavingsTrend overview={overview} locale={locale} />
        {overview.savings_balance_minor == null && !overview.savings_series.length ? <p className="finance-overview-muted">{isGerman ? "Sobald Sparkonten oder Ziele verbunden sind, erscheint hier ihr Verlauf." : "Connect savings accounts or goals to see their progress here."}</p> : null}
      </section>
    </div>
  );
}
