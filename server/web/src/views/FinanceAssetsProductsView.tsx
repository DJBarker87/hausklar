import { AlertCircle, BarChart3, Building2, CheckCircle2, Coins, Plus, RefreshCw, Search, ShieldCheck, Trash2, WalletCards } from "lucide-react";
import { useEffect, useMemo, useState, type FormEvent } from "react";

import { api } from "../api";
import { getFinanceAdultStrings } from "../financeAdultStrings";
import { todayInTimeZone } from "../financeDate";
import { CompositionBar } from "../components/FinanceCharts";
import type { FinanceLocale } from "../financeStrings";
import type { FinanceAccount, FinanceAssetHoldingInput, FinanceAssetPriceRefresh, FinanceAssetSnapshot, FinanceAssetSource, FinanceHLActivityInput, FinanceHLPreview, FinanceNetWorth, FinanceOpportunityAction, FinanceProductComparison, FinanceProductHistory, FinanceRetailerResearchResult, FinanceSettings, FinanceSpace } from "../types";

type LoadState = "loading" | "ready" | "error";
type WorkKind = "" | "preview" | "confirm" | "address" | "refresh" | "stop" | "rebuild" | "compare" | "accept";

type HoldingForm = {
  name: string;
  assetClass: "BROKERAGE_INVESTMENT" | "PENSION_LOCKED";
  quantity: string;
  unit: string;
  value: string;
  source: string;
  identifierKind: "ISIN" | "SEDOL" | "TICKER" | "OTHER";
  identifier: string;
  quoteSymbol: string;
  quoteCurrency: string;
};

type ActivityForm = {
  type: FinanceHLActivityInput["activity_type"];
  date: string;
  amount: string;
  description: string;
};

function isAbortError(error: unknown) {
  return error instanceof DOMException && error.name === "AbortError";
}

function amountToMinor(value: string) {
  const normalized = value.trim().replace(",", ".");
  if (!/^(?:0|[1-9]\d*)(?:\.\d{1,2})?$/.test(normalized)) return null;
  const [whole, fraction = ""] = normalized.split(".");
  const minor = Number(whole) * 100 + Number(fraction.padEnd(2, "0"));
  return Number.isSafeInteger(minor) ? minor : null;
}

function signedAmountToMinor(value: string) {
  const normalized = value.trim().replace(",", ".");
  if (!/^-?(?:0|[1-9]\d*)(?:\.\d{1,2})?$/.test(normalized)) return null;
  const sign = normalized.startsWith("-") ? -1 : 1;
  const [whole, fraction = ""] = normalized.replace("-", "").split(".");
  const minor = sign * (Number(whole) * 100 + Number(fraction.padEnd(2, "0")));
  return Number.isSafeInteger(minor) ? minor : null;
}

function formatCurrency(minor: number, currency: string, locale: FinanceLocale) {
  return new Intl.NumberFormat(locale === "de" ? "de-DE" : "en-GB", { style: "currency", currency }).format(minor / 100);
}

function formatDate(value: string, locale: FinanceLocale) {
  const parsed = new Date(`${value.slice(0, 10)}T12:00:00Z`);
  return Number.isNaN(parsed.valueOf()) ? value : new Intl.DateTimeFormat(locale === "de" ? "de-DE" : "en-GB", { dateStyle: "medium", timeZone: "UTC" }).format(parsed);
}

function subtractDays(value: string, days: number) {
  const parsed = new Date(`${value}T12:00:00Z`);
  parsed.setUTCDate(parsed.getUTCDate() - days);
  return parsed.toISOString().slice(0, 10);
}

function holdingKey(holding: HoldingForm, index: number) {
  if (holding.identifier.trim()) {
    return `${holding.identifierKind.toLowerCase()}:${holding.identifier.trim()}`;
  }
  const slug = holding.name.trim().toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-|-$/g, "").slice(0, 80);
  return `hl.${slug || "holding"}.${index + 1}`;
}

const emptyHolding = (): HoldingForm => ({ name: "", assetClass: "BROKERAGE_INVESTMENT", quantity: "", unit: "units", value: "", source: "", identifierKind: "ISIN", identifier: "", quoteSymbol: "", quoteCurrency: "" });
const emptyActivity = (date = ""): ActivityForm => ({ type: "CONTRIBUTION", date, amount: "", description: "" });

export function FinanceAssetsProductsView({ spaces, accounts, locale }: { spaces: FinanceSpace[]; accounts: FinanceAccount[]; locale: FinanceLocale }) {
  const copy = getFinanceAdultStrings(locale).assets;
  const params = useMemo(() => new URL(window.location.href).searchParams, []);
  const initialSpaceID = params.get("space");
  const itemID = params.get("item") ?? "";
  const initialResearchResultID = params.get("research") ?? "";
  const [spaceID, setSpaceID] = useState(spaces.some((space) => space.id === initialSpaceID) ? initialSpaceID! : spaces[0]?.id ?? "");
  const [defaultCurrency, setDefaultCurrency] = useState("");
  const currencies = useMemo(() => [...new Set([...accounts.filter((account) => account.space_id === spaceID).map((account) => account.currency), ...(defaultCurrency ? [defaultCurrency] : [])])].sort(), [accounts, spaceID, defaultCurrency]);
  const [currency, setCurrency] = useState(currencies[0] ?? "");
  const [state, setState] = useState<LoadState>("loading");
  const [retryKey, setRetryKey] = useState(0);
  const [netWorth, setNetWorth] = useState<FinanceNetWorth | null>(null);
  const [today, setToday] = useState("");
  const [work, setWork] = useState<WorkKind>("");
  const [error, setError] = useState("");
  const [notice, setNotice] = useState("");
  const [hl, setHL] = useState({ label: "", wrapper: "ISA" as "ISA" | "SIPP" | "GENERAL" | "JUNIOR_ISA" | "OTHER", reportDate: "", cash: "0", reportedTotal: "" });
  const [holdings, setHoldings] = useState<HoldingForm[]>([emptyHolding()]);
  const [activities, setActivities] = useState<ActivityForm[]>([]);
  const [preview, setPreview] = useState<FinanceHLPreview | null>(null);
  const [sources, setSources] = useState<FinanceAssetSource[]>([]);
  const [address, setAddress] = useState({ kind: "SOLANA_PUBLIC" as "SOLANA_PUBLIC" | "HYPERLIQUID_PUBLIC", label: "", value: "" });
  const [history, setHistory] = useState<FinanceProductHistory | null>(null);
  const [researchResults, setResearchResults] = useState<FinanceRetailerResearchResult[]>([]);
  const [researchResultID, setResearchResultID] = useState(initialResearchResultID);
  const [productState, setProductState] = useState<"idle" | "loading" | "ready" | "error">(itemID ? "loading" : "idle");
  const [comparison, setComparison] = useState<FinanceProductComparison | null>(null);
  const [period, setPeriod] = useState({ start: "", end: "" });
  const [habit, setHabit] = useState({ trigger: "", target: "", reviewDate: "" });
  const selectedResearch = researchResults.find((result) => result.id === researchResultID) ?? null;
  const selectionKey = spaces.map((space) => space.id).join(":");

  useEffect(() => {
    if (spaces.some((space) => space.id === spaceID)) return;
    setSpaceID(spaces[0]?.id ?? "");
  }, [selectionKey, spaceID]);

  useEffect(() => {
    if (currencies.includes(currency)) return;
    setCurrency(currencies[0] ?? "");
  }, [currencies.join(":"), currency]);

  useEffect(() => {
    if (!spaceID) {
      setState("ready");
      setNetWorth(null);
      return;
    }
    const controller = new AbortController();
    let active = true;
    setState("loading");
    const settingsRequest = api<FinanceSettings>("/finance/settings", { signal: controller.signal }, true, false);
    const requestedCurrencyRequest = currency
      ? Promise.resolve(currency)
      : settingsRequest.then((settings) => settings.default_currency);
    const summaryRequest = requestedCurrencyRequest.then((requestedCurrency) => api<FinanceNetWorth>(
      `/finance/assets/summary?space_id=${encodeURIComponent(spaceID)}&currency=${encodeURIComponent(requestedCurrency)}`,
      { signal: controller.signal },
      true,
      false,
    ));
    const sourcesRequest = api<FinanceAssetSource[]>(
      `/finance/assets/sources?space_id=${encodeURIComponent(spaceID)}`,
      { signal: controller.signal },
      true,
      false,
    );
    Promise.all([settingsRequest, requestedCurrencyRequest, summaryRequest, sourcesRequest]).then(([settings, requestedCurrency, loaded, loadedSources]) => {
      if (!active || loaded.space_id !== spaceID || loaded.currency !== requestedCurrency) return;
      const householdToday = todayInTimeZone(settings.household_timezone);
      setDefaultCurrency(settings.default_currency);
      setCurrency(requestedCurrency);
      setNetWorth(loaded);
      setSources(loadedSources.filter((source) => source.space_id === spaceID && source.status === "ACTIVE"));
      setToday(householdToday);
      setHL((current) => ({ ...current, reportDate: current.reportDate || householdToday }));
      setPeriod((current) => ({ start: current.start || subtractDays(householdToday, 90), end: current.end || householdToday }));
      setHabit((current) => ({ ...current, reviewDate: current.reviewDate || subtractDays(householdToday, -30) }));
      setState("ready");
    }).catch((caught: unknown) => {
      if (!active || isAbortError(caught)) return;
      setState("error");
    });
    return () => { active = false; controller.abort(); };
  }, [spaceID, currency, retryKey]);

  useEffect(() => {
    if (!itemID || !spaceID) {
      setProductState("idle");
      setHistory(null);
      return;
    }
    const controller = new AbortController();
    let active = true;
    setProductState("loading");
    Promise.all([
      api<FinanceProductHistory>(`/finance/items/${encodeURIComponent(itemID)}/product-price-history?space_id=${encodeURIComponent(spaceID)}&limit=200`, { signal: controller.signal }, true, false),
      api<FinanceRetailerResearchResult[]>(`/finance/items/${encodeURIComponent(itemID)}/retailer-research-results?space_id=${encodeURIComponent(spaceID)}&limit=50`, { signal: controller.signal }, true, false),
    ])
      .then(([loaded, results]) => { if (active && loaded.normalized_item_id === itemID) { setHistory(loaded); setResearchResults(results); setResearchResultID((current) => results.some((result) => result.id === current) ? current : results[0]?.id ?? ""); setProductState("ready"); } })
      .catch((caught: unknown) => { if (active && !isAbortError(caught)) setProductState("error"); });
    return () => { active = false; controller.abort(); };
  }, [itemID, spaceID, retryKey]);

  function clearMessages() {
    setError("");
    setNotice("");
  }

  async function refreshNetWorth() {
    setRetryKey((value) => value + 1);
  }

  async function refreshPortfolioPrices() {
    const hlSources = sources.filter((source) => source.source_kind === "HL_REPORT");
    if (!hlSources.length || work) return;
    clearMessages();
    setWork("refresh");
    try {
      await api<FinanceAssetPriceRefresh[]>(
        `/finance/assets/hl/refresh-prices?space_id=${encodeURIComponent(spaceID)}`,
        { method: "POST" },
        true,
        false,
      );
      setNotice(copy.portfolioPricesRefreshed);
      await refreshNetWorth();
    } catch {
      setError(copy.portfolioPricesError);
    } finally {
      setWork("");
    }
  }

  async function previewHL(event: FormEvent) {
    event.preventDefault();
    if (!spaceID || !currency || work) return;
    const cash = amountToMinor(hl.cash);
    const reported = hl.reportedTotal ? amountToMinor(hl.reportedTotal) : null;
    const mapped: FinanceAssetHoldingInput[] = [];
    const mappedActivities: FinanceHLActivityInput[] = [];
    for (const [index, holding] of holdings.entries()) {
      if (!holding.name.trim() && !holding.quantity.trim() && !holding.value.trim()) continue;
      const value = holding.value ? amountToMinor(holding.value) : null;
      if (!holding.name.trim() || !holding.quantity.trim() || !holding.unit.trim() || value === null && holding.value.trim() || value !== null && !holding.source.trim() || holding.quoteCurrency.trim() && !holding.quoteSymbol.trim()) {
        setError(copy.previewError);
        return;
      }
      mapped.push({ asset_key: holdingKey(holding, index), asset_name: holding.name.trim(), asset_class: holding.assetClass, position_kind: "HOLDING", include_in_net_worth: true, quantity: holding.quantity.trim(), quantity_unit: holding.unit.trim(), value_minor: value, unit_price_minor: null, price_source: value === null ? null : holding.source.trim(), instrument_id_kind: holding.identifier.trim() ? holding.identifierKind : null, instrument_id: holding.identifier.trim() || null, quote_symbol: holding.quoteSymbol.trim() || null, quote_currency: holding.quoteSymbol.trim() ? holding.quoteCurrency.trim() || currency : null });
    }
    for (const activity of activities) {
      const amount = signedAmountToMinor(activity.amount);
      if (!activity.date || amount === null || !activity.description.trim()) {
        setError(copy.previewError);
        return;
      }
      mappedActivities.push({ activity_type: activity.type, occurred_on: activity.date, amount_minor: amount, currency, description: activity.description.trim() });
    }
    if (!hl.label.trim() || !hl.reportDate || cash === null || reported === null && Boolean(hl.reportedTotal) || cash === 0 && !mapped.length) {
      setError(copy.previewError);
      return;
    }
    clearMessages();
    setWork("preview");
    try {
      const loaded = await api<FinanceHLPreview>(`/finance/assets/hl/import-preview?space_id=${encodeURIComponent(spaceID)}`, { method: "POST", body: JSON.stringify({ label: hl.label.trim(), account_wrapper: hl.wrapper, as_of_date: hl.reportDate, currency, cash_value_minor: cash, reported_total_minor: reported, holdings: mapped, activities: mappedActivities }) }, true, false);
      setPreview(loaded);
    } catch {
      setError(copy.previewError);
    } finally {
      setWork("");
    }
  }

  async function confirmHL() {
    if (!preview?.can_confirm || work) return;
    clearMessages();
    setWork("confirm");
    try {
      await api<FinanceAssetSnapshot>(`/finance/assets/hl/previews/${encodeURIComponent(preview.id)}/confirm`, { method: "POST", body: JSON.stringify({ reviewed: true }) }, true, false);
      setPreview(null);
      setHL({ label: "", wrapper: "ISA", reportDate: today, cash: "0", reportedTotal: "" });
      setHoldings([emptyHolding()]);
      setActivities([]);
      setNotice(copy.reportConfirmed);
      await refreshNetWorth();
    } catch {
      setError(copy.previewError);
    } finally {
      setWork("");
    }
  }

  async function addAddress(event: FormEvent) {
    event.preventDefault();
    if (!spaceID || work || !address.label.trim() || !address.value.trim()) return;
    clearMessages();
    setWork("address");
    try {
      const created = await api<FinanceAssetSource>(`/finance/assets/watch-addresses?space_id=${encodeURIComponent(spaceID)}`, { method: "POST", body: JSON.stringify({ source_kind: address.kind, label: address.label.trim(), public_address: address.value.trim() }) }, true, false);
      setSources((current) => [created, ...current.filter((source) => source.id !== created.id)]);
      setAddress((current) => ({ ...current, label: "", value: "" }));
      setNotice(copy.addressAdded);
    } catch {
      setError(copy.addressError);
    } finally {
      setWork("");
    }
  }

  async function refreshSource(source: FinanceAssetSource) {
    if (work) return;
    clearMessages();
    setWork("refresh");
    try {
      await api<FinanceAssetSnapshot>(`/finance/assets/sources/${encodeURIComponent(source.id)}/refresh`, { method: "POST" }, true, false);
      setNotice(copy.refreshed);
      await refreshNetWorth();
    } catch {
      setError(copy.addressError);
    } finally {
      setWork("");
    }
  }

  async function stopWatching(source: FinanceAssetSource) {
    if (work || source.source_kind === "HL_REPORT") return;
    clearMessages();
    setWork("stop");
    try {
      const updated = await api<FinanceAssetSource>(`/finance/assets/sources/${encodeURIComponent(source.id)}`, { method: "DELETE" }, true, false);
      if (updated.id !== source.id || updated.status !== "PAUSED") throw new Error(copy.addressError);
      setSources((current) => current.filter((item) => item.id !== source.id));
      setNotice(copy.stoppedWatching);
    } catch {
      setError(copy.addressError);
    } finally {
      setWork("");
    }
  }

  async function rebuildPrices() {
    if (!itemID || work) return;
    clearMessages();
    setWork("rebuild");
    try {
      await api<{ updated_observation_count: number }>(`/finance/product-prices/rebuild?space_id=${encodeURIComponent(spaceID)}`, { method: "POST" }, true, false);
      setRetryKey((value) => value + 1);
    } catch {
      setError(copy.productError);
    } finally {
      setWork("");
    }
  }

  async function compareProduct(event: FormEvent) {
    event.preventDefault();
    if (!itemID || !researchResultID || !period.start || !period.end || period.end < period.start || work) return;
    clearMessages();
    setWork("compare");
    try {
      const created = await api<FinanceProductComparison>(`/finance/product-comparisons?space_id=${encodeURIComponent(spaceID)}`, { method: "POST", body: JSON.stringify({ normalized_item_id: itemID, research_result_id: researchResultID, period_start: period.start, period_end: period.end }) }, true, false);
      setComparison(created);
    } catch {
      setError(copy.productError);
    } finally {
      setWork("");
    }
  }

  async function acceptComparison(kind: "PREFERENCE" | "HABIT_EXPERIMENT") {
    if (!comparison || work || kind === "HABIT_EXPERIMENT" && (!habit.trigger.trim() || !habit.target.trim() || !habit.reviewDate)) return;
    clearMessages();
    setWork("accept");
    try {
      await api<FinanceOpportunityAction>(`/finance/product-comparisons/${encodeURIComponent(comparison.id)}/accept`, { method: "POST", body: JSON.stringify(kind === "PREFERENCE" ? { action_kind: kind, review_date: null, trigger: null, target: null } : { action_kind: kind, review_date: habit.reviewDate, trigger: habit.trigger.trim(), target: habit.target.trim() }) }, true, false);
      setComparison((current) => current ? { ...current, status: "ACCEPTED" } : null);
      setNotice(copy.accepted);
    } catch {
      setError(copy.productError);
    } finally {
      setWork("");
    }
  }

  if (state === "loading") return <div className="finance-adult-skeleton" aria-label={copy.loading} aria-busy="true"><div /><div /><div /></div>;
  if (state === "error") return <div className="finance-adult-state is-error" role="alert"><AlertCircle aria-hidden="true" size={24} /><div><strong>{copy.errorTitle}</strong><p>{copy.errorDetail}</p></div><button type="button" className="button button--secondary" onClick={() => setRetryKey((value) => value + 1)}>{copy.retry}</button></div>;

  return (
    <div className="finance-adult-page finance-assets-page">
      <header className="finance-adult-heading"><div><span className="finance-status-label"><WalletCards aria-hidden="true" size={15} /> {copy.title}</span><h2>{copy.title}</h2><p>{copy.detail}</p></div><div className="finance-assets-selectors"><div className="field"><label htmlFor="finance-assets-space">{copy.finances}</label><select id="finance-assets-space" value={spaceID} onChange={(event) => setSpaceID(event.target.value)}>{spaces.map((space) => <option value={space.id} key={space.id}>{space.name}</option>)}</select></div><div className="field"><label htmlFor="finance-assets-currency">{copy.currency}</label><select id="finance-assets-currency" value={currency} onChange={(event) => setCurrency(event.target.value)}>{currencies.map((code) => <option value={code} key={code}>{code}</option>)}</select></div></div></header>
      {error ? <p className="form-error" role="alert">{error}</p> : null}{notice ? <p className="form-success" role="status"><CheckCircle2 aria-hidden="true" size={16} /> {notice}</p> : null}
      {selectedResearch ? <section className="finance-product-alternative" aria-label={copy.alternative}><div className="field"><label htmlFor="finance-research-result">{copy.alternative}</label><select id="finance-research-result" value={researchResultID} onChange={(event) => { setResearchResultID(event.target.value); setComparison(null); }}>{researchResults.map((result) => <option value={result.id} key={result.id}>{result.retailer_name} · {result.product_name} · {formatCurrency(result.price_minor, result.currency, locale)}</option>)}</select></div><article><strong>{selectedResearch.retailer_name} · {selectedResearch.product_name}</strong><p>{selectedResearch.pack_quantity} {selectedResearch.pack_unit} → {selectedResearch.comparable_quantity} {selectedResearch.unit_basis}</p><dl><div><dt>{copy.price}</dt><dd>{formatCurrency(selectedResearch.price_minor, selectedResearch.currency, locale)} · {formatDate(selectedResearch.observed_on, locale)}</dd></div><div><dt>{copy.whatBasedOn}</dt><dd>{selectedResearch.source_label}</dd></div><div><dt>{copy.inconvenience}</dt><dd>{selectedResearch.inconvenience_note}</dd></div></dl></article></section> : null}
      {itemID ? <section className="finance-retailer-research" aria-labelledby="finance-retailer-research-title"><header><h3 id="finance-retailer-research-title"><Search aria-hidden="true" size={18} /> {locale === "de" ? "Händlerpreise" : "Retailer prices"}</h3><p>{locale === "de" ? "Automatische Preisprüfungen sind noch nicht verfügbar. Die hier gezeigten Preise stammen aus datierten Händlerbelegen. HausKlar schätzt keine Preise." : "Automatic price checks are not available yet. Prices shown here come from dated retailer receipts. HausKlar does not guess prices."}</p></header></section> : null}

      <section className="finance-net-worth" aria-labelledby="finance-net-worth-title"><header><div><h3 id="finance-net-worth-title"><Coins aria-hidden="true" size={19} /> {copy.netWorth}</h3><p>{copy.notSpendable}</p></div>{sources.some((source) => source.source_kind === "HL_REPORT") ? <button type="button" className="button button--secondary" disabled={Boolean(work)} onClick={() => void refreshPortfolioPrices()}><RefreshCw aria-hidden="true" size={16} /> {copy.refreshPortfolioPrices}</button> : null}<button type="button" className="button button--secondary" onClick={() => void refreshNetWorth()}><RefreshCw aria-hidden="true" size={16} /> {copy.refresh}</button></header>{netWorth ? <><div className="finance-net-worth-total"><span>{netWorth.total_net_worth_minor === null ? copy.knownTotal : copy.completeTotal}</span><strong>{formatCurrency(netWorth.total_net_worth_minor ?? netWorth.known_net_worth_minor, netWorth.currency, locale)}</strong>{netWorth.total_net_worth_minor === null ? <p>{copy.unknownTotal}</p> : null}</div><CompositionBar segments={netWorth.layers.filter((layer) => layer.included_in_total && (layer.amount_minor ?? layer.known_components_minor) > 0).map((layer) => ({ key: layer.layer, label: copy.layers[layer.layer], amountMinor: layer.amount_minor ?? layer.known_components_minor }))} currency={netWorth.currency} locale={locale} emptyLabel={copy.notSpendable} /><div className="finance-net-worth-layers">{netWorth.layers.map((layer) => <article key={layer.layer}><div><strong>{copy.layers[layer.layer]}</strong>{layer.data_through ? <small>{formatDate(layer.data_through, locale)}</small> : null}</div><span>{layer.amount_minor === null ? `${formatCurrency(layer.known_components_minor, netWorth.currency, locale)} + ${layer.unknown_component_count} ${copy.unknownValues}` : formatCurrency(layer.amount_minor, netWorth.currency, locale)}</span>{layer.note ? <p>{layer.note}</p> : null}</article>)}</div></> : <p className="finance-adult-empty">—</p>}</section>

      <details className="finance-hl-activities finance-hl-price-details">
        <summary><strong>{locale === "de" ? "Kurse zuordnen (optional)" : "Match public prices (optional)"}</strong><span>{locale === "de" ? "Kennung und Kurssymbol aus derselben Anlagezeile" : "Identifier and symbol from the same holding line"}</span></summary>
        {holdings.map((holding, index) => <fieldset key={`quote-${index}`}><legend>{holding.name.trim() || `${copy.holdingName} ${index + 1}`}</legend><div className="field"><label htmlFor={`finance-holding-id-kind-${index}`}>{copy.instrumentKind}</label><select id={`finance-holding-id-kind-${index}`} value={holding.identifierKind} onChange={(event) => setHoldings((current) => current.map((item, itemIndex) => itemIndex === index ? { ...item, identifierKind: event.target.value as HoldingForm["identifierKind"] } : item))}>{["ISIN", "SEDOL", "TICKER", "OTHER"].map((kind) => <option value={kind} key={kind}>{kind}</option>)}</select></div><div className="field"><label htmlFor={`finance-holding-id-${index}`}>{copy.instrumentID}</label><input id={`finance-holding-id-${index}`} autoCapitalize="characters" spellCheck={false} autoComplete="off" value={holding.identifier} onChange={(event) => setHoldings((current) => current.map((item, itemIndex) => itemIndex === index ? { ...item, identifier: event.target.value.trim() } : item))} /></div><div className="field"><label htmlFor={`finance-holding-symbol-${index}`}>{copy.quoteSymbol}</label><input id={`finance-holding-symbol-${index}`} autoCapitalize="characters" spellCheck={false} autoComplete="off" value={holding.quoteSymbol} onChange={(event) => setHoldings((current) => current.map((item, itemIndex) => itemIndex === index ? { ...item, quoteSymbol: event.target.value.trim() } : item))} /></div><div className="field"><label htmlFor={`finance-holding-quote-currency-${index}`}>{copy.quoteCurrency}</label><select id={`finance-holding-quote-currency-${index}`} value={holding.quoteCurrency || currency} onChange={(event) => setHoldings((current) => current.map((item, itemIndex) => itemIndex === index ? { ...item, quoteCurrency: event.target.value } : item))}><option value={currency}>{currency}</option>{currency === "GBP" ? <option value="GBX">GBX</option> : null}</select><small>{copy.quoteHelp}</small></div></fieldset>)}
      </details>

      <section className="finance-hl-activities" aria-label={copy.addActivity}>
        <header><h3>{copy.addActivity}</h3><button type="button" className="button button--secondary" onClick={() => setActivities((current) => [...current, emptyActivity(hl.reportDate || today)])}><Plus aria-hidden="true" size={16} /> {copy.addActivity}</button></header>
        {activities.map((activity, index) => <fieldset key={index}><div className="field"><label htmlFor={`finance-activity-type-${index}`}>{copy.activityType}</label><select id={`finance-activity-type-${index}`} value={activity.type} onChange={(event) => setActivities((current) => current.map((item, itemIndex) => itemIndex === index ? { ...item, type: event.target.value as ActivityForm["type"] } : item))}>{Object.entries(copy.activityTypes).map(([value, label]) => <option value={value} key={value}>{label}</option>)}</select></div><div className="field"><label htmlFor={`finance-activity-date-${index}`}>{copy.activityDate}</label><input id={`finance-activity-date-${index}`} type="date" max={hl.reportDate || today} value={activity.date} onChange={(event) => setActivities((current) => current.map((item, itemIndex) => itemIndex === index ? { ...item, date: event.target.value } : item))} /></div><div className="field"><label htmlFor={`finance-activity-amount-${index}`}>{copy.activityAmount}</label><input id={`finance-activity-amount-${index}`} inputMode="decimal" autoComplete="off" value={activity.amount} onChange={(event) => setActivities((current) => current.map((item, itemIndex) => itemIndex === index ? { ...item, amount: event.target.value } : item))} /></div><div className="field"><label htmlFor={`finance-activity-description-${index}`}>{copy.activityDescription}</label><input id={`finance-activity-description-${index}`} autoComplete="off" value={activity.description} onChange={(event) => setActivities((current) => current.map((item, itemIndex) => itemIndex === index ? { ...item, description: event.target.value } : item))} /></div><button type="button" className="icon-button" aria-label={copy.removeActivity} onClick={() => setActivities((current) => current.filter((_, itemIndex) => itemIndex !== index))}><Trash2 aria-hidden="true" size={17} /></button></fieldset>)}
      </section>

      <div className="finance-assets-work-grid">
        <section className="finance-hl-import" aria-labelledby="finance-hl-title"><header><h3 id="finance-hl-title"><Building2 aria-hidden="true" size={19} /> {copy.hlTitle}</h3><p>{copy.hlDetail}</p></header><form onSubmit={(event) => void previewHL(event)}><div className="finance-settings-grid"><div className="field"><label htmlFor="finance-hl-label">{copy.label}</label><input id="finance-hl-label" autoComplete="off" value={hl.label} onChange={(event) => setHL({ ...hl, label: event.target.value })} /></div><div className="field"><label htmlFor="finance-hl-wrapper">{copy.wrapper}</label><select id="finance-hl-wrapper" value={hl.wrapper} onChange={(event) => setHL({ ...hl, wrapper: event.target.value as typeof hl.wrapper })}>{["ISA", "SIPP", "GENERAL", "JUNIOR_ISA", "OTHER"].map((wrapper) => <option key={wrapper} value={wrapper}>{wrapper.replaceAll("_", " ")}</option>)}</select></div><div className="field"><label htmlFor="finance-hl-date">{copy.reportDate}</label><input id="finance-hl-date" type="date" max={today} value={hl.reportDate} onChange={(event) => setHL({ ...hl, reportDate: event.target.value })} /></div><div className="field"><label htmlFor="finance-hl-cash">{copy.cash}</label><input id="finance-hl-cash" inputMode="decimal" autoComplete="off" value={hl.cash} onChange={(event) => setHL({ ...hl, cash: event.target.value })} /></div><div className="field"><label htmlFor="finance-hl-total">{copy.reportedTotal}</label><input id="finance-hl-total" inputMode="decimal" autoComplete="off" value={hl.reportedTotal} onChange={(event) => setHL({ ...hl, reportedTotal: event.target.value })} /></div></div><div className="finance-holding-list">{holdings.map((holding, index) => <fieldset key={index}><div className="field"><label htmlFor={`finance-holding-name-${index}`}>{copy.holdingName}</label><input id={`finance-holding-name-${index}`} autoComplete="off" value={holding.name} onChange={(event) => setHoldings((current) => current.map((item, itemIndex) => itemIndex === index ? { ...item, name: event.target.value } : item))} /></div><div className="field"><label htmlFor={`finance-holding-class-${index}`}>{copy.holdingClass}</label><select id={`finance-holding-class-${index}`} value={holding.assetClass} onChange={(event) => setHoldings((current) => current.map((item, itemIndex) => itemIndex === index ? { ...item, assetClass: event.target.value as HoldingForm["assetClass"] } : item))}><option value="BROKERAGE_INVESTMENT">{copy.layers.BROKERAGE_INVESTMENT}</option><option value="PENSION_LOCKED">{copy.layers.PENSION_LOCKED}</option></select></div><div className="field"><label htmlFor={`finance-holding-quantity-${index}`}>{copy.quantity}</label><input id={`finance-holding-quantity-${index}`} inputMode="decimal" autoComplete="off" value={holding.quantity} onChange={(event) => setHoldings((current) => current.map((item, itemIndex) => itemIndex === index ? { ...item, quantity: event.target.value } : item))} /></div><div className="field"><label htmlFor={`finance-holding-unit-${index}`}>{copy.quantityUnit}</label><input id={`finance-holding-unit-${index}`} autoComplete="off" value={holding.unit} onChange={(event) => setHoldings((current) => current.map((item, itemIndex) => itemIndex === index ? { ...item, unit: event.target.value } : item))} /></div><div className="field"><label htmlFor={`finance-holding-value-${index}`}>{copy.holdingValue}</label><input id={`finance-holding-value-${index}`} inputMode="decimal" autoComplete="off" value={holding.value} onChange={(event) => setHoldings((current) => current.map((item, itemIndex) => itemIndex === index ? { ...item, value: event.target.value } : item))} /></div><div className="field"><label htmlFor={`finance-holding-source-${index}`}>{copy.valueSource}</label><input id={`finance-holding-source-${index}`} autoComplete="off" value={holding.source} disabled={!holding.value} onChange={(event) => setHoldings((current) => current.map((item, itemIndex) => itemIndex === index ? { ...item, source: event.target.value } : item))} /></div><button type="button" className="icon-button" aria-label={copy.removeHolding} disabled={holdings.length === 1} onClick={() => setHoldings((current) => current.filter((_, itemIndex) => itemIndex !== index))}><Trash2 aria-hidden="true" size={17} /></button></fieldset>)}</div><button type="button" className="button button--secondary" onClick={() => setHoldings((current) => [...current, emptyHolding()])}><Plus aria-hidden="true" size={16} /> {copy.addHolding}</button><button type="submit" className="button button--primary" disabled={Boolean(work) || !currency}>{work === "preview" ? copy.previewing : copy.preview}</button></form>{preview ? <article className="finance-hl-preview"><dl><div><dt>{copy.calculated}</dt><dd>{formatCurrency(preview.calculated_known_total_minor, preview.currency, locale)}</dd></div>{preview.reconciliation_difference_minor !== null ? <div><dt>{copy.difference}</dt><dd>{formatCurrency(preview.reconciliation_difference_minor, preview.currency, locale)}</dd></div> : null}<div><dt>{copy.unknownHoldings}</dt><dd>{preview.unknown_value_count}</dd></div></dl><button type="button" className="button button--primary" disabled={!preview.can_confirm || Boolean(work)} onClick={() => void confirmHL()}><ShieldCheck aria-hidden="true" size={16} /> {copy.confirmReport}</button></article> : null}</section>

        <section className="finance-watch-address" aria-labelledby="finance-watch-title"><header><h3 id="finance-watch-title"><ShieldCheck aria-hidden="true" size={19} /> {copy.watchTitle}</h3><p>{copy.watchDetail}</p></header><form onSubmit={(event) => void addAddress(event)}><div className="field"><label htmlFor="finance-watch-kind">{copy.sourceKind}</label><select id="finance-watch-kind" value={address.kind} onChange={(event) => setAddress({ ...address, kind: event.target.value as typeof address.kind })}><option value="SOLANA_PUBLIC">{copy.solana}</option><option value="HYPERLIQUID_PUBLIC">{copy.hyperliquid}</option></select></div><div className="field"><label htmlFor="finance-watch-label">{copy.addressLabel}</label><input id="finance-watch-label" autoComplete="off" value={address.label} onChange={(event) => setAddress({ ...address, label: event.target.value })} /></div><div className="field"><label htmlFor="finance-watch-address">{copy.publicAddress}</label><input id="finance-watch-address" spellCheck={false} autoCapitalize="none" autoComplete="off" value={address.value} onChange={(event) => setAddress({ ...address, value: event.target.value })} /></div><button type="submit" className="button button--primary" disabled={Boolean(work)}>{copy.addAddress}</button></form>{sources.filter((source) => source.public_address).map((source) => <article className="finance-watch-source" key={source.id}><div><strong>{source.label}</strong><code>{source.public_address}</code></div><div><button type="button" className="button button--secondary" disabled={Boolean(work)} onClick={() => void refreshSource(source)}><RefreshCw aria-hidden="true" size={16} /> {work === "refresh" ? copy.refreshing : copy.refresh}</button><button type="button" className="button button--secondary" disabled={Boolean(work)} onClick={() => void stopWatching(source)}>{copy.stopWatching}</button></div></article>)}</section>
      </div>

      <section className="finance-product-history" aria-labelledby="finance-product-title"><header><div><h3 id="finance-product-title"><BarChart3 aria-hidden="true" size={19} /> {copy.productTitle}</h3><p>{copy.productDetail}</p></div>{itemID ? <button type="button" className="button button--secondary" disabled={Boolean(work)} onClick={() => void rebuildPrices()}><RefreshCw aria-hidden="true" size={16} /> {work === "rebuild" ? copy.rebuilding : copy.rebuild}</button> : null}</header>{!itemID ? <p className="finance-adult-empty">{copy.noProduct}</p> : productState === "loading" ? <div className="finance-adult-skeleton" aria-busy="true"><div /><div /></div> : productState === "error" ? <p className="form-error" role="alert">{copy.productError}</p> : history?.observations.length ? <><h4>{history.normalized_item_name}</h4><div className="finance-price-table" role="table"><div role="row"><strong role="columnheader">{copy.observed}</strong><strong role="columnheader">{copy.price}</strong><strong role="columnheader">{copy.whatBasedOn}</strong></div>{history.observations.map((observation) => <div role="row" key={observation.id}><time role="cell" dateTime={observation.observed_on}>{formatDate(observation.observed_on, locale)}</time><span role="cell">{formatCurrency(observation.price_minor, observation.currency, locale)}</span><span role="cell">{observation.retailer_name} · {observation.product_name}<small>{copy.packBasis}: {observation.pack_quantity} {observation.pack_unit} → {observation.comparable_quantity} {observation.unit_basis}</small></span></div>)}</div></> : <p className="finance-adult-empty">{copy.noPrices}</p>}{itemID && researchResultID ? <form className="finance-product-compare-form" onSubmit={(event) => void compareProduct(event)}><div className="field"><label htmlFor="finance-comparison-start">{copy.observed}</label><input id="finance-comparison-start" type="date" max={period.end} value={period.start} onChange={(event) => setPeriod({ ...period, start: event.target.value })} /></div><div className="field"><label htmlFor="finance-comparison-end">{copy.reviewDate}</label><input id="finance-comparison-end" type="date" min={period.start} max={today} value={period.end} onChange={(event) => setPeriod({ ...period, end: event.target.value })} /></div><button type="submit" className="button button--primary" disabled={Boolean(work)}>{copy.compare}</button></form> : itemID ? <p className="finance-adult-empty">{copy.comparisonPending}</p> : null}{comparison ? <article className="finance-product-comparison"><h4>{copy.comparisonTitle}</h4><dl><div><dt>{copy.actualSpend}</dt><dd>{formatCurrency(comparison.actual_spend_minor, comparison.currency, locale)}</dd></div><div><dt>{copy.alternative}</dt><dd>{formatCurrency(comparison.candidate_low_minor, comparison.currency, locale)}–{formatCurrency(comparison.candidate_high_minor, comparison.currency, locale)}</dd></div><div><dt>{copy.likelySaving}</dt><dd>{formatCurrency(comparison.saving_low_minor, comparison.currency, locale)}–{formatCurrency(comparison.saving_high_minor, comparison.currency, locale)}</dd></div><div><dt>{copy.priceDate}</dt><dd>{formatDate(comparison.price_observed_on, locale)}</dd></div><div><dt>{copy.comparisonDataThrough}</dt><dd>{formatDate(comparison.data_through, locale)}</dd></div><div><dt>{copy.confidence}</dt><dd>{copy.confidenceLevels[comparison.confidence_bps >= 8000 ? "HIGH" : comparison.confidence_bps >= 5000 ? "MEDIUM" : "LOW"]}</dd></div><div><dt>{copy.unmatched}</dt><dd>{comparison.unmatched_observation_count}</dd></div><div><dt>{copy.inconvenience}</dt><dd>{comparison.inconvenience_note}</dd></div></dl>{comparison.evidence_refs.length ? <div className="finance-evidence-links"><strong>{copy.evidence}</strong>{comparison.evidence_refs.map((reference, index) => { const [kind, id] = reference.split(":", 2); const href = kind === "transaction" && id ? `/?view=finance&section=activity&transaction=${encodeURIComponent(id)}` : kind === "purchase-line" && id ? `/?view=finance&section=more&line=${encodeURIComponent(id)}` : null; return href ? <a key={reference} href={href}><span>{kind === "transaction" ? (locale === "de" ? "Bankeintrag " : "Bank entry ") : (locale === "de" ? "Belegartikel " : "Receipt item ")}{index + 1}</span><span>{copy.openEvidence}</span></a> : <span key={reference}>{locale === "de" ? "Gespeicherter Eintrag" : "Saved record"} {index + 1}</span>; })}</div> : null}{comparison.status === "OPEN" ? <><button type="button" className="button button--secondary" disabled={Boolean(work)} onClick={() => void acceptComparison("PREFERENCE")}>{copy.acceptPreference}</button><div className="finance-habit-accept"><div className="field"><label htmlFor="finance-product-trigger">{copy.trigger}</label><input id="finance-product-trigger" autoComplete="off" value={habit.trigger} onChange={(event) => setHabit({ ...habit, trigger: event.target.value })} /></div><div className="field"><label htmlFor="finance-product-target">{copy.target}</label><input id="finance-product-target" autoComplete="off" value={habit.target} onChange={(event) => setHabit({ ...habit, target: event.target.value })} /></div><div className="field"><label htmlFor="finance-product-review-date">{copy.reviewDate}</label><input id="finance-product-review-date" type="date" min={today} value={habit.reviewDate} onChange={(event) => setHabit({ ...habit, reviewDate: event.target.value })} /></div><button type="button" className="button button--primary" disabled={Boolean(work) || !habit.trigger.trim() || !habit.target.trim()} onClick={() => void acceptComparison("HABIT_EXPERIMENT")}>{copy.acceptHabit}</button></div></> : null}</article> : null}</section>
    </div>
  );
}
