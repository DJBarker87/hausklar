import { CalendarDays, CheckCircle2, Trash2 } from "lucide-react";
import { useEffect, useId, useMemo, useRef, useState, type FormEvent } from "react";

import { api } from "../api";
import type { FinanceCalendarItem, FinanceCalendarItemPrefill, FinanceProjectionPreferences, FinanceSpace } from "../types";

type DeliveryKind = FinanceCalendarItem["item_kind"];

function localDateTime(value: string) {
  const parsed = new Date(value);
  if (Number.isNaN(parsed.valueOf())) return "";
  const local = new Date(parsed.valueOf() - parsed.getTimezoneOffset() * 60_000);
  return local.toISOString().slice(0, 16);
}

function reviewedTime(value: string) {
  return new Date(value).toISOString();
}

export function FinanceDeliveryCalendarAction({
  sourceID,
  sourceSpaceID,
  sourceKind,
  lineKind,
  description,
  spaces,
  locale,
}: {
  sourceID: string;
  sourceSpaceID: string;
  sourceKind?: string | null;
  lineKind?: string | null;
  description: string;
  spaces: FinanceSpace[];
  locale: "en" | "de";
}) {
  const fieldID = useId();
  const isTesco = sourceKind === "tesco_batch";
  const looksLikeDelivery = isTesco
    || lineKind === "delivery"
    || /\b(delivery|parcel|shipment|dispatch|shipping|tesco)\b/i.test(description);
  const itemKind: DeliveryKind = isTesco ? "GROCERY_DELIVERY" : "PARCEL_DELIVERY";
  const [items, setItems] = useState<FinanceCalendarItem[]>([]);
  const [destinationID, setDestinationID] = useState(sourceSpaceID);
  const [allDay, setAllDay] = useState(false);
  const [startsAt, setStartsAt] = useState("");
  const [endsAt, setEndsAt] = useState("");
  const [preferences, setPreferences] = useState<FinanceProjectionPreferences | null>(null);
  const [suggested, setSuggested] = useState(false);
  const [deliveryFound, setDeliveryFound] = useState(looksLikeDelivery);
  const [loading, setLoading] = useState(false);
  const [working, setWorking] = useState<"save" | "remove" | "visibility" | null>(null);
  const [notice, setNotice] = useState("");
  const [error, setError] = useState("");
  const editedRef = useRef(false);
  const selectedItem = useMemo(
    () => items.find((item) => item.space_id === destinationID && item.item_kind === itemKind) ?? null,
    [destinationID, itemKind, items],
  );
  const activeItems = items.filter((item) => item.item_kind === itemKind && item.status === "ACTIVE");

  function text(english: string, german: string) {
    return locale === "de" ? german : english;
  }

  function applyItem(item: FinanceCalendarItem) {
    setDestinationID(item.space_id);
    setAllDay(item.all_day);
    setStartsAt(item.all_day ? item.starts_at.slice(0, 10) : localDateTime(item.starts_at));
    setEndsAt(item.ends_at && !item.all_day ? localDateTime(item.ends_at) : "");
  }

  useEffect(() => {
    if (!sourceID) return;
    const controller = new AbortController();
    let active = true;
    editedRef.current = false;
    setItems([]);
    setDestinationID(spaces.some((space) => space.id === sourceSpaceID) ? sourceSpaceID : (spaces[0]?.id ?? ""));
    setAllDay(false);
    setStartsAt("");
    setEndsAt("");
    setSuggested(false);
    setDeliveryFound(looksLikeDelivery);
    setLoading(true);
    setError("");
    Promise.all([
      api<FinanceCalendarItem[]>(
        `/finance/calendar-items?source_id=${encodeURIComponent(sourceID)}`,
        { signal: controller.signal },
        true,
        false,
      ),
      api<FinanceProjectionPreferences>(
        "/finance/projection-preferences",
        { signal: controller.signal },
        true,
        false,
      ),
      api<FinanceCalendarItemPrefill | null>(
        `/finance/calendar-items/prefill?source_id=${encodeURIComponent(sourceID)}`,
        { signal: controller.signal },
        true,
        false,
      ),
    ])
      .then(([loadedItems, loadedPreferences, prefill]) => {
        if (!active) return;
        setItems(loadedItems);
        setPreferences(loadedPreferences);
        const current = loadedItems.find((item) => item.item_kind === itemKind && item.status === "ACTIVE")
          ?? loadedItems.find((item) => item.item_kind === itemKind);
        setDeliveryFound(Boolean(current || prefill) || looksLikeDelivery);
        if (current && !editedRef.current) {
          applyItem(current);
        } else if (!current && prefill?.item_kind === itemKind && !editedRef.current) {
          setAllDay(prefill.all_day);
          setStartsAt(prefill.all_day ? prefill.starts_at.slice(0, 10) : localDateTime(prefill.starts_at));
          setEndsAt(prefill.ends_at && !prefill.all_day ? localDateTime(prefill.ends_at) : "");
          setSuggested(true);
        }
      })
      .catch((caught: unknown) => {
        if (!active || (caught instanceof DOMException && caught.name === "AbortError")) return;
        setError(text("The saved delivery date could not be loaded.", "Der gespeicherte Liefertermin konnte nicht geladen werden."));
      })
      .finally(() => { if (active) setLoading(false); });
    return () => {
      active = false;
      controller.abort();
    };
  }, [sourceID, sourceSpaceID, itemKind, looksLikeDelivery]);

  if (!deliveryFound) return null;

  async function save(event: FormEvent) {
    event.preventDefault();
    if (!startsAt || !destinationID || working) return;
    setWorking("save");
    setError("");
    setNotice("");
    try {
      const saved = await api<FinanceCalendarItem>(
        "/finance/calendar-items",
        {
          method: "POST",
          body: JSON.stringify({
            reviewed: true,
            space_id: destinationID,
            item_kind: itemKind,
            source_id: sourceID,
            starts_at: allDay ? startsAt : reviewedTime(startsAt),
            ends_at: endsAt ? (allDay ? endsAt : reviewedTime(endsAt)) : null,
            all_day: allDay,
          }),
        },
        true,
        false,
      );
      const oldItems = activeItems.filter((item) => item.space_id !== destinationID);
      for (const item of oldItems) {
        await api(`/finance/calendar-items/${encodeURIComponent(item.id)}`, { method: "DELETE" }, true, false);
      }
      setItems((current) => [
        { ...saved, source_id: sourceID },
        ...current
          .filter((item) => item.id !== saved.id)
          .map((item) => oldItems.some((old) => old.id === item.id) ? { ...item, status: "CANCELLED" as const } : item),
      ]);
      setSuggested(false);
      setNotice(text("Delivery added to Calendar.", "Lieferung zum Kalender hinzugefügt."));
    } catch {
      setError(text("The delivery date could not be saved.", "Der Liefertermin konnte nicht gespeichert werden."));
    } finally {
      setWorking(null);
    }
  }

  async function remove() {
    const item = selectedItem?.status === "ACTIVE" ? selectedItem : activeItems[0];
    if (!item || working) return;
    setWorking("remove");
    setError("");
    setNotice("");
    try {
      await api(`/finance/calendar-items/${encodeURIComponent(item.id)}`, { method: "DELETE" }, true, false);
      setItems((current) => current.map((candidate) => candidate.id === item.id ? { ...candidate, status: "CANCELLED" as const } : candidate));
      setNotice(text("Delivery removed from Calendar.", "Lieferung aus dem Kalender entfernt."));
    } catch {
      setError(text("The delivery could not be removed.", "Die Lieferung konnte nicht entfernt werden."));
    } finally {
      setWorking(null);
    }
  }

  async function setCalendarVisibility(showDeliveries: boolean) {
    if (!preferences || working) return;
    setWorking("visibility");
    setError("");
    try {
      const saved = await api<FinanceProjectionPreferences>(
        "/finance/projection-preferences",
        {
          method: "PATCH",
          body: JSON.stringify({ show_money: preferences.show_money, show_deliveries: showDeliveries }),
        },
        true,
        false,
      );
      setPreferences(saved);
    } catch {
      setError(text("The Calendar setting could not be changed.", "Die Kalendereinstellung konnte nicht geändert werden."));
    } finally {
      setWorking(null);
    }
  }

  return (
    <section className="finance-delivery-calendar" aria-labelledby={`${fieldID}-title`} aria-busy={loading || Boolean(working)}>
      <header>
        <div>
          <span>{text("Deliveries", "Lieferungen")}</span>
          <h4 id={`${fieldID}-title`}><CalendarDays aria-hidden="true" size={18} /> {isTesco ? text("Tesco delivery", "Tesco-Lieferung") : text("Parcel delivery", "Paketlieferung")}</h4>
          <p>{text("Check the date, then choose whose Calendar should show it.", "Prüfe den Termin und wähle dann den passenden Kalender.")}</p>
        </div>
        {activeItems.length ? <strong className="finance-delivery-calendar__status"><CheckCircle2 aria-hidden="true" size={16} /> {text("On Calendar", "Im Kalender")}</strong> : null}
      </header>

      <form onSubmit={(event) => void save(event)}>
        <div className="field">
          <label htmlFor={`${fieldID}-calendar`}>{text("Show for", "Anzeigen für")}</label>
          <select id={`${fieldID}-calendar`} value={destinationID} onChange={(event) => {
            const nextID = event.target.value;
            setDestinationID(nextID);
            const nextItem = items.find((item) => item.space_id === nextID && item.item_kind === itemKind && item.status === "ACTIVE");
            if (nextItem) applyItem(nextItem);
          }} required>
            {spaces.map((space) => <option key={space.id} value={space.id}>{space.kind === "personal" ? text("Personal", "Persönlich") : text("Household", "Haushalt")}</option>)}
          </select>
        </div>
        <label className="finance-delivery-calendar__all-day"><input type="checkbox" checked={allDay} onChange={(event) => { editedRef.current = true; setSuggested(false); setAllDay(event.target.checked); setStartsAt(""); setEndsAt(""); }} /> {text("All day", "Ganztägig")}</label>
        <div className="field">
          <label htmlFor={`${fieldID}-start`}>{allDay ? text("Date", "Datum") : text("Starts", "Beginn")}</label>
          <input id={`${fieldID}-start`} type={allDay ? "date" : "datetime-local"} value={startsAt} onChange={(event) => { editedRef.current = true; setSuggested(false); setStartsAt(event.target.value); }} required />
        </div>
        {!allDay ? <div className="field">
          <label htmlFor={`${fieldID}-end`}>{text("Ends (optional)", "Ende (optional)")}</label>
          <input id={`${fieldID}-end`} type="datetime-local" min={startsAt || undefined} value={endsAt} onChange={(event) => { editedRef.current = true; setSuggested(false); setEndsAt(event.target.value); }} />
        </div> : null}
        <div className="finance-delivery-calendar__actions">
          <button type="submit" className="button button--primary" disabled={loading || Boolean(working) || !startsAt || !destinationID}>{working === "save" ? text("Saving…", "Speichern…") : activeItems.length ? text("Update Calendar", "Kalender aktualisieren") : text("Add to Calendar", "Zum Kalender hinzufügen")}</button>
          {activeItems.length ? <button type="button" className="button button--secondary" disabled={Boolean(working)} onClick={() => void remove()}><Trash2 aria-hidden="true" size={16} /> {text("Remove", "Entfernen")}</button> : null}
        </div>
      </form>

      {suggested ? <p className="finance-delivery-calendar__suggestion">{text("Suggested from the order. Check it before adding it.", "Aus der Bestellung vorgeschlagen. Vor dem Hinzufügen prüfen.")}</p> : null}

      {preferences ? <label className="finance-delivery-calendar__visibility"><input type="checkbox" checked={preferences.show_deliveries} disabled={Boolean(working)} onChange={(event) => void setCalendarVisibility(event.target.checked)} /> {text("Show Deliveries in Calendar", "Lieferungen im Kalender anzeigen")}</label> : null}
      {notice ? <p className="form-notice" role="status">{notice}</p> : null}
      {error ? <p className="form-error" role="alert">{error}</p> : null}
    </section>
  );
}
