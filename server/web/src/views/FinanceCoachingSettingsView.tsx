import { AlertCircle, Bell, CheckCircle2, Cloud, ShieldCheck } from "lucide-react";
import { useEffect, useMemo, useRef, useState, type FormEvent } from "react";

import { api } from "../api";
import { getFinanceAdultStrings } from "../financeAdultStrings";
import type { FinanceLocale } from "../financeStrings";
import type {
  FinanceAIConsent,
  FinanceAccount,
  FinanceReportPreference,
  FinanceSpace,
  PushStatus,
  ReminderPreferences,
} from "../types";

type LoadState = "loading" | "ready" | "error";

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

function amountInput(minor: number) {
  return (minor / 100).toFixed(2);
}

function shortTime(value: string, fallback: string) {
  return value ? value.slice(0, 5) : fallback;
}

export function FinanceCoachingSettingsView({
  spaces,
  accounts,
  consents,
  locale,
}: {
  spaces: FinanceSpace[];
  accounts: FinanceAccount[];
  consents: FinanceAIConsent[];
  locale: FinanceLocale;
}) {
  const copy = getFinanceAdultStrings(locale).settings;
  const calm = locale === "de" ? {
    reminders: "Geld-Erinnerungen",
    actionOnly: "Nur wenn ich handeln muss",
    actionOnlyDetail: "Die normale Wahl. Höchstens eine private Erinnerung an einem Tag, an dem etwas zu tun ist.",
    daily: "Täglicher Geld-Check",
    dailyDetail: "Jeden Tag eine private Erinnerung, sobald der Check bereit ist.",
    never: "Nie",
    neverDetail: "Keine Finanz-Erinnerungen. Dein privater Check bleibt in HausKlar sichtbar.",
    inApp: "Aktionskarten bleiben privat in HausKlar sichtbar. Aktiviere Browser-Erinnerungen im Konto, wenn du sie außerhalb der App möchtest.",
    quiet: "HausKlar-Ruhezeiten",
    quietFrom: "Ruhe von",
    until: "bis",
    change: "Im Konto ändern",
    more: "Weitere Finanz-Einstellungen",
    showMore: "Zusätzliche Finanzdetails automatisch öffnen",
    silent: "Gewöhnliche Einkäufe bleiben still. Kleine Punkte warten auf den wöchentlichen Haushalts-Check.",
  } : {
    reminders: "Money reminders",
    actionOnly: "Only when I need to act",
    actionOnlyDetail: "The normal choice. One private reminder at most on a day when something needs doing.",
    daily: "Daily money check",
    dailyDetail: "A private reminder every day when the check is ready.",
    never: "Never",
    neverDetail: "No Finance reminders. Your private check still appears in HausKlar.",
    inApp: "Action cards still appear privately in HausKlar. Turn on browser reminders in Account if you want them outside the app.",
    quiet: "HausKlar quiet hours",
    quietFrom: "Quiet from",
    until: "to",
    change: "Change in Account",
    more: "More Finance choices",
    showMore: "Open extra Finance detail automatically",
    silent: "Routine purchases stay silent. Small matters wait for the weekly Household check.",
  };
  const [spaceID, setSpaceID] = useState(spaces[0]?.id ?? "");
  const [state, setState] = useState<LoadState>("loading");
  const [retryKey, setRetryKey] = useState(0);
  const [preference, setPreference] = useState<FinanceReportPreference | null>(null);
  const [push, setPush] = useState<PushStatus | null>(null);
  const [reminders, setReminders] = useState<ReminderPreferences | null>(null);
  const [buffer, setBuffer] = useState("");
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState("");
  const [notice, setNotice] = useState("");
  const errorRef = useRef<HTMLParagraphElement>(null);
  const selectionKey = spaces.map((space) => space.id).join(":");
  const allowedSpaceIDs = useMemo(
    () => new Set(spaces.map((space) => space.id)),
    [selectionKey],
  );
  const eligibleAccounts = accounts.filter((account) => (
    account.space_id === spaceID
    && account.include_in_cashflow
    && ["CURRENT", "CASH"].includes(account.account_type)
    && account.purpose === "OPERATING_CURRENT"
  ));
  const consent = consents.find((item) => item.space_id === spaceID) ?? null;

  useEffect(() => {
    if (!allowedSpaceIDs.has(spaceID)) setSpaceID(spaces[0]?.id ?? "");
  }, [selectionKey]);

  useEffect(() => {
    if (!spaceID || !allowedSpaceIDs.has(spaceID)) return;
    const controller = new AbortController();
    let active = true;
    setState("loading");
    setError("");
    Promise.all([
      api<FinanceReportPreference>(`/finance/report-preferences?space_id=${encodeURIComponent(spaceID)}`, { signal: controller.signal }, true, false),
      api<PushStatus>("/reminders/push", { signal: controller.signal }, true, false),
      api<ReminderPreferences>("/reminders/preferences", { signal: controller.signal }, true, false),
    ])
      .then(([loaded, loadedPush, loadedReminders]) => {
        if (!active || loaded.space_id !== spaceID) return;
        setPreference(loaded);
        setPush(loadedPush);
        setReminders(loadedReminders);
        setBuffer(amountInput(loaded.extra_cash_buffer_minor));
        setState("ready");
      })
      .catch((caught: unknown) => {
        if (!active || isAbortError(caught)) return;
        setState("error");
      });
    return () => { active = false; controller.abort(); };
  }, [spaceID, retryKey]);

  async function save(event: FormEvent) {
    event.preventDefault();
    if (!preference || !push || saving) return;
    const bufferMinor = amountToMinor(buffer);
    if (bufferMinor === null || (preference.writing_mode === "CLOUD_WITH_CONSENT" && !consent?.consented)) {
      setError(copy.saveError);
      window.requestAnimationFrame(() => errorRef.current?.focus());
      return;
    }
    setSaving(true);
    setError("");
    setNotice("");
    try {
      const body = {
        locale: preference.locale,
        daily_time: preference.daily_time.length === 5 ? `${preference.daily_time}:00` : preference.daily_time,
        enabled: true,
        notification_channel: preference.notification_mode !== "NEVER" && push.subscribed ? "BROWSER" : "IN_APP",
        notification_mode: preference.notification_mode,
        show_more_by_default: preference.show_more_by_default,
        quiet_hours_start: null,
        quiet_hours_end: null,
        underfunded_commitment_threshold_minor: preference.underfunded_commitment_threshold_minor,
        goal_movement_threshold_minor: preference.goal_movement_threshold_minor,
        missed_payday_alerts: preference.missed_payday_alerts,
        selected_return_deadline_alerts: preference.selected_return_deadline_alerts,
        tone: preference.tone,
        default_spend_account_id: preference.default_spend_account_id || null,
        extra_cash_buffer_minor: bufferMinor,
        writing_mode: preference.writing_mode,
        allow_dated_estimates: true,
      };
      const updated = await api<FinanceReportPreference>(
        `/finance/report-preferences?space_id=${encodeURIComponent(spaceID)}`,
        { method: "PUT", body: JSON.stringify(body) },
        true,
        false,
      );
      if (updated.space_id !== spaceID || updated.ordinary_purchase_alerts !== false || updated.group_related_alerts !== true) throw new Error(copy.saveError);
      setPreference(updated);
      setNotice(copy.saved);
    } catch {
      setError(copy.saveError);
      window.requestAnimationFrame(() => errorRef.current?.focus());
    } finally {
      setSaving(false);
    }
  }

  if (state === "loading") return <div className="finance-adult-skeleton" aria-label={copy.loading} aria-busy="true"><div /><div /><div /></div>;
  if (state === "error" || !preference || !push || !reminders) return <div className="finance-adult-state is-error" role="alert"><AlertCircle aria-hidden="true" size={24} /><div><strong>{copy.errorTitle}</strong><p>{copy.errorDetail}</p></div><button type="button" className="button button--secondary" onClick={() => setRetryKey((value) => value + 1)}>{copy.retry}</button></div>;

  const reminderChoices: Array<{ value: FinanceReportPreference["notification_mode"]; title: string; detail: string }> = [
    { value: "ACTION_ONLY", title: calm.actionOnly, detail: calm.actionOnlyDetail },
    { value: "DAILY", title: calm.daily, detail: calm.dailyDetail },
    { value: "NEVER", title: calm.never, detail: calm.neverDetail },
  ];

  return <div className="finance-adult-page finance-coaching-settings">
    <header className="finance-adult-heading"><div><span className="finance-status-label"><Bell aria-hidden="true" size={15} /> {copy.title}</span><h2>{copy.title}</h2><p>{copy.detail}</p></div><div className="field"><label htmlFor="finance-settings-space">{copy.finances}</label><select id="finance-settings-space" value={spaceID} onChange={(event) => setSpaceID(event.target.value)}>{spaces.map((space) => <option value={space.id} key={space.id}>{space.name}</option>)}</select></div></header>
    <form onSubmit={(event) => void save(event)} aria-busy={saving}>
      <fieldset className="finance-notification-fieldset">
        <legend id="finance-notification-settings-title"><CheckCircle2 aria-hidden="true" size={18} /> {calm.reminders}</legend>
        <div className="finance-notification-choices">
          {reminderChoices.map((choice) => {
            const detailID = `finance-notification-${choice.value.toLowerCase()}-detail`;
            return <label className="finance-notification-choice" key={choice.value}><input type="radio" name="finance-notification-mode" value={choice.value} checked={preference.notification_mode === choice.value} aria-describedby={detailID} onChange={() => setPreference({ ...preference, notification_mode: choice.value })} /><span><strong>{choice.title}</strong><small id={detailID}>{choice.detail}</small></span></label>;
          })}
        </div>
        {preference.notification_mode === "DAILY" ? <div className="finance-settings-grid"><div className="field"><label htmlFor="finance-report-time">{copy.reportTime}</label><input id="finance-report-time" type="time" autoComplete="off" value={shortTime(preference.daily_time, "07:00")} onChange={(event) => setPreference({ ...preference, daily_time: event.target.value })} /></div><div className="field"><label htmlFor="finance-report-language">{copy.language}</label><select id="finance-report-language" value={preference.locale} onChange={(event) => setPreference({ ...preference, locale: event.target.value as "en" | "de" })}><option value="en">{copy.english}</option><option value="de">{copy.german}</option></select></div></div> : null}
        {!push.subscribed && preference.notification_mode !== "NEVER" ? <p className="finance-settings-note">{calm.inApp}</p> : <p className="finance-settings-note">{copy.pushReady}</p>}
      </fieldset>

      <section className="finance-shared-quiet" aria-labelledby="finance-shared-quiet-title"><div><h3 id="finance-shared-quiet-title">{calm.quiet}</h3><p>{calm.quietFrom} <strong>{reminders.quiet_start}</strong> {calm.until} <strong>{reminders.quiet_end}</strong>.</p></div><a className="button button--secondary" href="/?view=account">{calm.change}</a></section>

      <label className="finance-checkbox"><input type="checkbox" checked={preference.show_more_by_default} onChange={(event) => setPreference({ ...preference, show_more_by_default: event.target.checked })} /><span>{calm.showMore}</span></label>

      <details className="finance-settings-more"><summary>{calm.more}</summary><div>
        <section aria-labelledby="finance-coaching-choice-title"><h3 id="finance-coaching-choice-title"><ShieldCheck aria-hidden="true" size={18} /> {copy.coaching}</h3><div className="finance-settings-grid"><div className="field"><label htmlFor="finance-bluntness">{copy.bluntness}</label><select id="finance-bluntness" value={preference.tone} onChange={(event) => setPreference({ ...preference, tone: event.target.value as FinanceReportPreference["tone"] })}><option value="GENTLE">{copy.gentle}</option><option value="BALANCED">{copy.balanced}</option><option value="BLUNT">{copy.blunt}</option></select></div><div className="field"><label htmlFor="finance-default-account">{copy.defaultAccount}</label><select id="finance-default-account" value={preference.default_spend_account_id ?? ""} onChange={(event) => setPreference({ ...preference, default_spend_account_id: event.target.value || null })}><option value="">—</option>{eligibleAccounts.map((account) => <option value={account.id} key={account.id}>{account.label}</option>)}</select></div><div className="field"><label htmlFor="finance-extra-buffer">{copy.buffer}</label><input id="finance-extra-buffer" value={buffer} inputMode="decimal" autoComplete="off" onChange={(event) => setBuffer(event.target.value)} /></div></div></section>
        <section aria-labelledby="finance-ai-settings-title"><h3 id="finance-ai-settings-title"><Cloud aria-hidden="true" size={18} /> {copy.calculations}</h3><label className="finance-radio"><input type="radio" name="finance-data-mode" checked={preference.writing_mode === "LOCAL"} onChange={() => setPreference({ ...preference, writing_mode: "LOCAL" })} /><span>{copy.localOnly}</span></label><label className="finance-radio"><input type="radio" name="finance-data-mode" checked={preference.writing_mode === "CLOUD_WITH_CONSENT"} disabled={!consent?.consented} onChange={() => setPreference({ ...preference, writing_mode: "CLOUD_WITH_CONSENT" })} /><span>{copy.cloudWithConsent}</span></label>{!consent?.consented ? <p>{copy.consentNeeded}</p> : null}<p className="finance-coach-basis-note">{copy.estimates}</p></section>
      </div></details>

      <p className="finance-settings-silent"><ShieldCheck aria-hidden="true" size={18} /> {calm.silent}</p>
      {error ? <p className="form-error" role="alert" tabIndex={-1} ref={errorRef}>{error}</p> : null}
      {notice ? <p className="form-success" role="status" aria-live="polite">{notice}</p> : null}
      <button type="submit" className="button button--primary" disabled={saving}>{saving ? copy.saving : copy.save}</button>
    </form>
  </div>;
}
