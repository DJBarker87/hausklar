import { BarChart3, MessageCircleMore } from "lucide-react";
import { memo, useEffect, useMemo, useRef, useState } from "react";

import { api } from "../api";
import { getFinanceAdultStrings } from "../financeAdultStrings";
import type { FinanceLocale } from "../financeStrings";
import type {
  FinanceAccount,
  FinanceAssetClass,
  FinanceNetWorthHistory,
  FinanceNetWorthPoint,
} from "../types";

const INCLUDED_LAYERS: FinanceAssetClass[] = [
  "OPERATING_CASH",
  "GOAL_CASH",
  "ACCESSIBLE_SAVINGS",
  "BROKERAGE_INVESTMENT",
  "PENSION_LOCKED",
  "STABLE_CRYPTO",
  "VOLATILE_CRYPTO",
  "PROPERTY",
  "OTHER_ASSET",
  "LIABILITY",
];

type SeriesKey = "TOTAL" | FinanceAssetClass;
type LoadState = "loading" | "ready" | "fallback";
const HISTORY_PAGE_SIZE = 100;
const MAX_CACHED_RANGES = 6;
const moneyFormatters = new Map<string, Intl.NumberFormat>();
const dateFormatters = new Map<FinanceLocale, Intl.DateTimeFormat>();

function seriesClass(key: SeriesKey) {
  const index = key === "TOTAL" ? 0 : INCLUDED_LAYERS.indexOf(key) + 1;
  return `finance-series-${(Math.max(index, 0) % 6) + 1}`;
}

function formatMoney(minor: number, currency: string, locale: FinanceLocale, signed = false) {
  const maximumFractionDigits = Math.abs(minor) >= 100_000 ? 0 : 2;
  const key = `${locale}:${currency}:${maximumFractionDigits}`;
  let formatter = moneyFormatters.get(key);
  if (!formatter) {
    formatter = new Intl.NumberFormat(locale === "de" ? "de-DE" : "en-GB", {
      style: "currency",
      currency,
      maximumFractionDigits,
    });
    moneyFormatters.set(key, formatter);
  }
  const formatted = formatter.format(minor / 100);
  return signed && minor > 0 ? `+${formatted}` : formatted;
}

function formatDay(value: string, locale: FinanceLocale) {
  const date = new Date(`${value.slice(0, 10)}T12:00:00Z`);
  let formatter = dateFormatters.get(locale);
  if (!formatter) {
    formatter = new Intl.DateTimeFormat(locale === "de" ? "de-DE" : "en-GB", {
      dateStyle: "medium",
      timeZone: "UTC",
    });
    dateFormatters.set(locale, formatter);
  }
  return formatter.format(date);
}

function layerValue(point: FinanceNetWorthPoint, key: SeriesKey) {
  if (key === "TOTAL") return point.total_minor;
  return point.layers.find((layer) => layer.layer === key)?.amount_minor ?? 0;
}

const NetWorthLineChart = memo(function NetWorthLineChart({
  points,
  series,
  labels,
  currency,
  locale,
}: {
  points: FinanceNetWorthPoint[];
  series: SeriesKey[];
  labels: Record<SeriesKey, string>;
  currency: string;
  locale: FinanceLocale;
}) {
  if (points.length < 2 || !series.length) return null;
  const width = 720;
  const height = 260;
  const padX = 16;
  const padTop = 18;
  const padBottom = 34;
  const values = series.flatMap((key) => points.map((point) => layerValue(point, key)));
  const rawMin = Math.min(...values);
  const rawMax = Math.max(...values);
  const padding = Math.max(1, (rawMax - rawMin || Math.abs(rawMax) || 100) * 0.08);
  const domainMin = rawMin - padding;
  const domainMax = rawMax + padding;
  const span = domainMax - domainMin || 1;
  const pointTimes = points.map((point) => Date.parse(`${point.as_of_date.slice(0, 10)}T12:00:00Z`));
  const firstTime = pointTimes[0];
  const timeSpan = Math.max(1, pointTimes.at(-1)! - firstTime);
  const x = (index: number) => padX + ((pointTimes[index] - firstTime) / timeSpan) * (width - padX * 2);
  const y = (value: number) => padTop + (1 - (value - domainMin) / span) * (height - padTop - padBottom);
  const summary = series.map((key) => {
    const first = layerValue(points[0], key);
    const last = layerValue(points.at(-1)!, key);
    return `${labels[key]} ${formatMoney(first, currency, locale)} to ${formatMoney(last, currency, locale)}`;
  }).join(". ");

  return (
    <svg className="finance-net-worth-chart" viewBox={`0 0 ${width} ${height}`} role="img" aria-label={summary}>
      {domainMin < 0 && domainMax > 0 ? <line className="finance-net-worth-zero" x1={padX} x2={width - padX} y1={y(0)} y2={y(0)} /> : null}
      {series.map((key) => {
        const path = points.map((point, index) => `${index === 0 ? "M" : "L"} ${x(index).toFixed(1)} ${y(layerValue(point, key)).toFixed(1)}`).join(" ");
        return <g key={key}><path className={`finance-net-worth-series ${seriesClass(key)}`} d={path} fill="none" /><circle className={`finance-net-worth-last ${seriesClass(key)}`} cx={x(points.length - 1)} cy={y(layerValue(points.at(-1)!, key))} r={4} /></g>;
      })}
      <text className="finance-net-worth-axis-label" x={padX} y={height - 8}>{formatDay(points[0].as_of_date, locale)}</text>
      <text className="finance-net-worth-axis-label" x={width - padX} y={height - 8} textAnchor="end">{formatDay(points.at(-1)!.as_of_date, locale)}</text>
    </svg>
  );
});

function fallbackTotal(accounts: FinanceAccount[], spaceID: string, currency: string) {
  return accounts
    .filter((account) => account.space_id === spaceID && account.currency === currency && account.include_in_net_worth)
    .reduce((total, account) => {
      const value = account.balance?.booked_minor ?? 0;
      return total + (account.account_type === "CREDIT_CARD" ? -Math.abs(value) : value);
    }, 0);
}

export function FinanceNetWorthPanel({
  spaceID,
  currency,
  accounts,
  locale,
  onAskAbout,
}: {
  spaceID: string;
  currency: string;
  accounts: FinanceAccount[];
  locale: FinanceLocale;
  onAskAbout: (question: string) => void;
}) {
  const assetCopy = useMemo(() => getFinanceAdultStrings(locale).assets, [locale]);
  const [days, setDays] = useState(365);
  const [reloadKey, setReloadKey] = useState(0);
  const [state, setState] = useState<LoadState>("loading");
  const [history, setHistory] = useState<FinanceNetWorthHistory | null>(null);
  const [selectedLayers, setSelectedLayers] = useState<FinanceAssetClass[]>([]);
  const [breakdownOpen, setBreakdownOpen] = useState(false);
  const [historyPage, setHistoryPage] = useState(0);
  const historyCache = useRef(new Map<string, FinanceNetWorthHistory>());

  useEffect(() => {
    if (!spaceID || !currency) {
      setHistory(null);
      setState("fallback");
      return;
    }
    const cacheKey = `${spaceID}:${currency}:${days}`;
    const cached = historyCache.current.get(cacheKey);
    if (cached) {
      setHistory(cached);
      setHistoryPage(0);
      setState("ready");
      return;
    }
    const controller = new AbortController();
    let active = true;
    setState("loading");
    setHistory(null);
    async function loadHistory() {
      try {
        const loaded = await api<FinanceNetWorthHistory>(
          `/finance/assets/net-worth-history?space_id=${encodeURIComponent(spaceID)}&currency=${encodeURIComponent(currency)}&days=${days}`,
          { signal: controller.signal },
          true,
          false,
        );
        if (!active || loaded.space_id !== spaceID || loaded.currency !== currency) return;
        historyCache.current.set(cacheKey, loaded);
        while (historyCache.current.size > MAX_CACHED_RANGES) {
          historyCache.current.delete(historyCache.current.keys().next().value!);
        }
        setHistory(loaded);
        setHistoryPage(0);
        setState("ready");
      } catch {
        if (!active) return;
        setHistory(null);
        setState("fallback");
      }
    }
    void loadHistory();
    return () => { active = false; controller.abort(); };
  }, [spaceID, currency, days, reloadKey]);

  const fallback = fallbackTotal(accounts, spaceID, currency);
  const current = history?.current_total_minor ?? fallback;
  const change = history?.change_minor ?? 0;
  const availableLayers = useMemo(
    () => INCLUDED_LAYERS.filter((layer) => history?.points.some((point) => layerValue(point, layer) !== 0)),
    [history],
  );
  const visibleSeries = useMemo<SeriesKey[]>(
    () => ["TOTAL", ...selectedLayers.filter((layer) => availableLayers.includes(layer))],
    [availableLayers, selectedLayers],
  );
  const currentPoint = history?.points.at(-1) ?? null;
  const unknownCount = currentPoint?.unknown_component_count ?? 0;
  const headlineLabel = unknownCount > 0
    ? (locale === "de" ? "Bekannter Teil des Nettovermögens" : "Known net worth")
    : (locale === "de" ? "Nettovermögen" : "Net worth");
  const labels = useMemo<Record<SeriesKey, string>>(
    () => ({ TOTAL: headlineLabel, ...assetCopy.layers }),
    [assetCopy.layers, headlineLabel],
  );
  const pageCount = Math.max(1, Math.ceil((history?.points.length ?? 0) / HISTORY_PAGE_SIZE));
  const visibleHistoryPoints = history?.points.slice(
    historyPage * HISTORY_PAGE_SIZE,
    (historyPage + 1) * HISTORY_PAGE_SIZE,
  ) ?? [];

  function toggleLayer(layer: FinanceAssetClass) {
    setSelectedLayers((currentLayers) => {
      if (currentLayers.includes(layer)) {
        return currentLayers.filter((item) => item !== layer);
      }
      return [...currentLayers, layer];
    });
  }

  function askAboutNetWorth() {
    const from = history?.points[0]?.as_of_date;
    const to = history?.points.at(-1)?.as_of_date;
    onAskAbout(locale === "de"
      ? `Erkläre die Veränderung meines Nettovermögens${from && to ? ` von ${from} bis ${to}` : ""}. Trenne Einzahlungen, Auszahlungen und Marktbewegung.`
      : `Explain the change in my net worth${from && to ? ` from ${from} to ${to}` : ""}. Separate contributions, withdrawals and market movement.`);
  }

  function retryHistory() {
    historyCache.current.clear();
    setReloadKey((value) => value + 1);
  }

  return (
    <section className="finance-net-worth-history" aria-labelledby="finance-net-worth-history-title">
      <header className="finance-net-worth-history-heading">
        <div><span><BarChart3 aria-hidden="true" size={16} /> {headlineLabel}</span><h3 id="finance-net-worth-history-title">{formatMoney(current, currency, locale)}</h3><p>{history ? `${change >= 0 ? "+" : ""}${formatMoney(change, currency, locale)} ${locale === "de" ? "im gewählten Zeitraum" : "over the selected period"}` : (locale === "de" ? "Aus den aktuell gespeicherten Kontosalden" : "From the account balances saved now")}</p>{unknownCount > 0 ? <small className="finance-net-worth-unknown">+ {unknownCount} {locale === "de" ? (unknownCount === 1 ? "Wert noch ohne Preis" : "Werte noch ohne Preis") : (unknownCount === 1 ? "value not yet priced" : "values not yet priced")}</small> : null}</div>
        <div className="finance-net-worth-range" role="group" aria-label={locale === "de" ? "Zeitraum" : "Time range"}>{[{ value: 365, label: "1Y" }, { value: 1095, label: "3Y" }, { value: 3650, label: "10Y" }].map((option) => <button type="button" key={option.value} aria-pressed={days === option.value} className={days === option.value ? "is-active" : undefined} onClick={() => setDays(option.value)}>{option.label}</button>)}</div>
      </header>

      {state === "loading" && !history ? <div className="finance-net-worth-skeleton" aria-label={locale === "de" ? "Nettovermögen wird geladen" : "Loading net worth"} aria-busy="true"><div /><div /></div> : history ? <>
        {!history.holdings.length && history.current_total_minor === 0 ? <p className="finance-net-worth-empty">{locale === "de" ? "Noch keine Werte gespeichert. Füge ein Konto, einen HL-Bericht oder einen Hauswert hinzu, um das Gesamtbild aufzubauen." : "No values saved yet. Add an account, an HL report or a home value to build the full picture."}</p> : null}
        <NetWorthLineChart points={history.points} series={visibleSeries} labels={labels} currency={currency} locale={locale} />
        {availableLayers.length ? <fieldset className="finance-net-worth-series-picker"><legend>{locale === "de" ? "Mit dem Gesamtwert vergleichen" : "Compare with the total"}</legend>{availableLayers.map((layer) => <label key={layer}><input type="checkbox" checked={selectedLayers.includes(layer)} onChange={() => toggleLayer(layer)} /><span className={`finance-net-worth-series-swatch ${seriesClass(layer)}`} aria-hidden="true" />{labels[layer]}</label>)}</fieldset> : null}

        <div className="finance-net-worth-flow-heading"><h4>{locale === "de" ? "Veränderung der Anlagen" : "Investment change"}</h4><p>{locale === "de" ? "Einzahlungen und Auszahlungen sind von der Marktbewegung getrennt." : "Contributions and withdrawals are separate from market movement."}</p></div>
        <div className="finance-net-worth-flow-summary">
          <article><span>{locale === "de" ? "Eingezahlt" : "Contributed"}</span><strong>{formatMoney(history.period_contributions_minor, currency, locale)}</strong></article>
          <article><span>{locale === "de" ? "Ausgezahlt" : "Withdrawn"}</span><strong>{formatMoney(history.period_withdrawals_minor, currency, locale)}</strong></article>
          <article><span>{locale === "de" ? "Marktbewegung" : "Market movement"}</span><strong>{formatMoney(history.period_market_movement_minor, currency, locale, true)}</strong></article>
        </div>

        <details className="finance-net-worth-breakdown" open={breakdownOpen}>
          <summary onClick={(event) => {
            event.preventDefault();
            setBreakdownOpen((open) => !open);
          }}>{locale === "de" ? "Vollständige Aufschlüsselung" : "Full breakdown"}</summary>
          {breakdownOpen ? <>
            {currentPoint ? <dl className="finance-net-worth-layer-list">{currentPoint.layers.filter((layer) => layer.amount_minor !== 0).map((layer) => <div key={layer.layer}><dt>{labels[layer.layer]}{layer.layer === "PROTECTED_RESERVE" ? <small>{locale === "de" ? "Teil des Bargelds oben; nicht doppelt gezählt" : "Part of the cash above; not counted twice"}</small> : null}</dt><dd>{formatMoney(layer.amount_minor, currency, locale)}</dd></div>)}</dl> : null}
            {history.holdings.length ? <div className="finance-net-worth-holdings" role="region" tabIndex={0} aria-label={locale === "de" ? "Anlagen und Werte; horizontal scrollbar" : "Holdings and values; scroll horizontally for more columns"}><table><thead><tr><th>{locale === "de" ? "Anlage" : "Holding"}</th><th>{locale === "de" ? "Bereich" : "Part of net worth"}</th><th>{locale === "de" ? "Wert" : "Value"}</th><th>{locale === "de" ? "Stand" : "As of"}</th></tr></thead><tbody>{history.holdings.map((holding) => <tr key={holding.key}><th scope="row">{holding.name}<small>{holding.quantity ? `${holding.quantity} ${holding.quantity_unit ?? ""}` : holding.source_label}{holding.instrument_id ? ` · ${holding.instrument_id_kind} ${holding.instrument_id}` : ""}</small></th><td>{labels[holding.layer]}</td><td>{formatMoney(holding.value_minor, currency, locale)}</td><td>{formatDay(holding.as_of_at, locale)}<small>{holding.price_source}</small></td></tr>)}</tbody></table></div> : null}
            <h4 className="finance-net-worth-point-history">{locale === "de" ? "Wertverlauf" : "Valuation history"}</h4>
            {pageCount > 1 ? <div className="finance-net-worth-history-pagination" role="group" aria-label={locale === "de" ? "Seiten des Wertverlaufs" : "Valuation history pages"}>
              <button type="button" className="button button--secondary" disabled={historyPage === 0} onClick={() => setHistoryPage((page) => Math.max(0, page - 1))}>{locale === "de" ? "Zurück" : "Previous"}</button>
              <span aria-live="polite">{locale === "de" ? `Seite ${historyPage + 1} von ${pageCount}` : `Page ${historyPage + 1} of ${pageCount}`}</span>
              <button type="button" className="button button--secondary" disabled={historyPage >= pageCount - 1} onClick={() => setHistoryPage((page) => Math.min(pageCount - 1, page + 1))}>{locale === "de" ? "Weiter" : "Next"}</button>
            </div> : null}
            <div className="finance-net-worth-holdings" role="region" tabIndex={0} aria-label={locale === "de" ? "Wertverlauf; horizontal scrollbar" : "Valuation history; scroll horizontally for more columns"}><table><thead><tr><th>{locale === "de" ? "Datum" : "Date"}</th><th>{locale === "de" ? "Gesamt" : "Total"}</th><th>{locale === "de" ? "Eingezahlt" : "Contributed"}</th><th>{locale === "de" ? "Ausgezahlt" : "Withdrawn"}</th><th>{locale === "de" ? "Marktbewegung" : "Market movement"}</th></tr></thead><tbody>{visibleHistoryPoints.map((point) => <tr key={point.as_of_date}><th scope="row">{formatDay(point.as_of_date, locale)}</th><td>{formatMoney(point.total_minor, currency, locale)}</td><td>{formatMoney(point.contributions_minor, currency, locale)}</td><td>{formatMoney(point.withdrawals_minor, currency, locale)}</td><td>{point.market_movement_minor == null ? "—" : formatMoney(point.market_movement_minor, currency, locale, true)}</td></tr>)}</tbody></table></div>
            <p className="finance-net-worth-price-note">{history.price_observed_at ? `${locale === "de" ? "Anlagekurse bis" : "Investment prices through"} ${formatDay(history.price_observed_at, locale)}${history.price_sources.length ? ` · ${history.price_sources.join(", ")}` : ""}.` : (locale === "de" ? "Anlagen nutzen die zuletzt gespeicherten Berichtswerte." : "Investments use the latest saved report values.")}</p>
          </> : null}
        </details>
        <button type="button" className="button button--secondary finance-net-worth-ask" onClick={askAboutNetWorth}><MessageCircleMore aria-hidden="true" size={17} /> {locale === "de" ? "Dazu fragen" : "Ask about this"}</button>
      </> : <div className="finance-net-worth-fallback"><p>{locale === "de" ? "Aktueller Kontowert" : "Current account value"}: <strong>{formatMoney(fallback, currency, locale)}</strong></p><button type="button" className="button button--secondary" onClick={retryHistory}>{locale === "de" ? "Diagramm aktualisieren" : "Update graph"}</button></div>}
    </section>
  );
}
