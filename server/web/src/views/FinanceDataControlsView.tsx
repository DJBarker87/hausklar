import { Clock3, Download, History } from "lucide-react";
import { useEffect, useState } from "react";

import { api } from "../api";
import type { FinanceLocale } from "../financeStrings";
import type { FinanceHistoryEntry, FinanceHistoryPage } from "../types";

type HistoryState =
  | { status: "loading"; items: FinanceHistoryEntry[] }
  | { status: "ready"; items: FinanceHistoryEntry[]; hasMore: boolean }
  | { status: "error"; items: FinanceHistoryEntry[]; hasMore: boolean };

function isAbortError(error: unknown) {
  return error instanceof DOMException && error.name === "AbortError";
}

function formatDateTime(value: string, locale: FinanceLocale) {
  const date = new Date(value);
  return Number.isNaN(date.valueOf()) ? value : new Intl.DateTimeFormat(
    locale === "de" ? "de-DE" : "en-GB",
    { dateStyle: "medium", timeStyle: "short" },
  ).format(date);
}

function readableName(value: string, singular = false) {
  const parts = value.split("_");
  if (singular) {
    const last = parts.at(-1) ?? "";
    const irregular = ({ addresses: "address", analyses: "analysis", statuses: "status" } as Record<string, string>)[last];
    if (irregular) parts[parts.length - 1] = irregular;
    else if (last.endsWith("ies")) parts[parts.length - 1] = `${last.slice(0, -3)}y`;
    else if (last.endsWith("s") && !last.endsWith("ss")) parts[parts.length - 1] = last.slice(0, -1);
  }
  const label = parts.join(" ");
  return label.replace(/^./, (first) => first.toUpperCase());
}

function displayValue(value: string | number | boolean | null, locale: FinanceLocale) {
  if (value === null || value === "") return locale === "de" ? "Nicht gesetzt" : "Not set";
  if (typeof value === "boolean") return value ? (locale === "de" ? "Ja" : "Yes") : (locale === "de" ? "Nein" : "No");
  return String(value);
}

export function FinanceDataControlsView({
  scope,
  locale,
}: {
  scope: "mine" | "household";
  locale: FinanceLocale;
}) {
  const [state, setState] = useState<HistoryState>({ status: "loading", items: [] });
  const [offset, setOffset] = useState(0);
  const [retryKey, setRetryKey] = useState(0);
  const pageSize = 50;

  useEffect(() => {
    const controller = new AbortController();
    let active = true;
    setState({ status: "loading", items: [] });
    setOffset(0);
    api<FinanceHistoryPage>(
      `/finance/history?scope=${scope}&offset=0&limit=${pageSize}`,
      { signal: controller.signal },
      true,
      false,
    ).then((page) => {
      if (active && page.scope === scope) setState({ status: "ready", items: page.items, hasMore: page.has_more });
    }).catch((error: unknown) => {
      if (active && !isAbortError(error)) setState({ status: "error", items: [], hasMore: false });
    });
    return () => { active = false; controller.abort(); };
  }, [scope, retryKey]);

  async function loadMore() {
    if ((state.status !== "ready" && state.status !== "error") || !state.hasMore) return;
    const nextOffset = offset + pageSize;
    const currentItems = state.items;
    setState({ status: "loading", items: currentItems });
    try {
      const page = await api<FinanceHistoryPage>(
        `/finance/history?scope=${scope}&offset=${nextOffset}&limit=${pageSize}`,
        undefined,
        true,
        false,
      );
      if (page.scope !== scope) throw new Error("Unexpected Finance history scope");
      setOffset(nextOffset);
      setState({ status: "ready", items: [...currentItems, ...page.items], hasMore: page.has_more });
    } catch {
      setState({ status: "error", items: currentItems, hasMore: true });
    }
  }

  return (
    <section className="finance-data-controls" aria-labelledby="finance-data-controls-title">
      <header>
        <div>
          <span className="finance-status-label"><History aria-hidden="true" size={15} /> {locale === "de" ? "Deine Daten" : "Your data"}</span>
          <h2 id="finance-data-controls-title">{locale === "de" ? "Export und Änderungsverlauf" : "Export and change history"}</h2>
          <p>{scope === "mine"
            ? (locale === "de" ? "Der Export enthält deine privaten Finanzdaten und die Haushaltsdaten, auf die du zugreifen darfst – niemals private Daten eines anderen Erwachsenen." : "The export includes your private Finance records and Household records you can access—never another adult's private records.")
            : (locale === "de" ? "Der Verlauf zeigt nur Änderungen im Haushalt. Der Export enthält außerdem deine privaten Finanzdaten, aber niemals private Daten eines anderen Erwachsenen." : "The history shows Household changes only. The export also includes your private Finance records, but never another adult's private records.")}</p>
        </div>
        <a className="button button--secondary" href="/api/finance/export" download>
          <Download aria-hidden="true" size={17} /> {locale === "de" ? "Finanzdaten exportieren" : "Export Finance data"}
        </a>
      </header>

      <div className="finance-history" aria-labelledby="finance-history-title">
        <h3 id="finance-history-title"><Clock3 aria-hidden="true" size={17} /> {locale === "de" ? "Letzte Änderungen" : "Recent changes"}</h3>
        {state.items.length ? <ol>{state.items.map((entry) => {
          const values = Object.entries(entry.previous_values);
          return <li key={entry.id}><div><strong>{readableName(entry.record_type, true)}</strong><span>{formatDateTime(entry.changed_at, locale)} · {entry.changed_by_current_user ? (locale === "de" ? "von dir" : "by you") : entry.changed_by_name ?? (locale === "de" ? "von einem Familienmitglied" : "by a family member")}</span></div>{values.length ? <details><summary>{locale === "de" ? "Vorherige Werte" : "Previous values"}</summary><dl>{values.map(([key, value]) => <div key={key}><dt>{readableName(key)}</dt><dd>{displayValue(value, locale)}</dd></div>)}</dl></details> : null}</li>;
        })}</ol> : state.status === "loading" ? <p role="status">{locale === "de" ? "Änderungen werden geladen…" : "Loading changes…"}</p> : state.status === "error" ? <><p className="form-error" role="alert">{locale === "de" ? "Der Änderungsverlauf konnte nicht geladen werden." : "Change history could not be loaded."}</p><button type="button" className="button button--secondary" onClick={() => setRetryKey((key) => key + 1)}>{locale === "de" ? "Erneut versuchen" : "Try again"}</button></> : <p>{locale === "de" ? "Noch keine Änderungen vorhanden." : "No changes recorded yet."}</p>}
        {state.status === "ready" && state.hasMore ? <button type="button" className="button button--secondary" onClick={() => void loadMore()}>{locale === "de" ? "Mehr laden" : "Load more"}</button> : null}
        {state.status === "loading" && state.items.length ? <p role="status">{locale === "de" ? "Weitere Änderungen werden geladen…" : "Loading more changes…"}</p> : null}
        {state.status === "error" && state.items.length ? <button type="button" className="button button--secondary" onClick={() => void loadMore()}>{locale === "de" ? "Erneut versuchen" : "Try again"}</button> : null}
      </div>
    </section>
  );
}
