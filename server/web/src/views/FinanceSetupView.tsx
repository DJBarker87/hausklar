import {
  AlertCircle,
  Building2,
  CheckCircle2,
  CircleDashed,
  FileSpreadsheet,
  Landmark,
  Pencil,
  Plus,
  RefreshCw,
  ShieldCheck,
  Unplug,
  Upload,
} from "lucide-react";
import { useEffect, useMemo, useState, type FormEvent } from "react";

import { api, isOfflineQueuedResult } from "../api";
import type { FinanceLocale, FinanceStrings } from "../financeStrings";
import type {
  FinanceAccount,
  FinanceAccountType,
  FinanceAccountPurpose,
  FinanceConnection,
  FinanceConnectionSyncResult,
  FinanceCoachingReport,
  FinanceEmailAddress,
  FinanceEmailAddresses,
  FinanceEmailHealth,
  FinanceImportPreview,
  FinanceImportResult,
  FinancePurchaseEvidenceUploadResponse,
  FinanceReportPreference,
  FinanceSpace,
} from "../types";
import { cn, ConfirmDialog, Modal } from "../components/ui";

type SetupData = {
  connections: FinanceConnection[];
  accounts: FinanceAccount[];
  connectionsUnavailable: boolean;
  accountsUnavailable: boolean;
};

type SetupLoadState =
  | { status: "loading" }
  | { status: "ready"; data: SetupData }
  | { status: "error" };

type ImportSourceKind = "CSV" | "OFX";
type SignConvention = "DEBIT_NEGATIVE" | "DEBIT_POSITIVE";

function isAbortError(error: unknown) {
  return error instanceof DOMException && error.name === "AbortError";
}

function formatCurrency(minor: number, currency: string, locale: FinanceLocale) {
  return new Intl.NumberFormat(locale === "de" ? "de-DE" : "en-GB", {
    style: "currency",
    currency,
  }).format(minor / 100);
}

function formatDate(value: string, locale: FinanceLocale) {
  const parsed = new Date(value.includes("T") ? value : `${value}T00:00:00`);
  if (Number.isNaN(parsed.valueOf())) return value;
  return new Intl.DateTimeFormat(locale === "de" ? "de-DE" : "en-GB", {
    dateStyle: "medium",
  }).format(parsed);
}

function formatDateTime(value: string, locale: FinanceLocale) {
  const parsed = new Date(value);
  if (Number.isNaN(parsed.valueOf())) return value;
  return new Intl.DateTimeFormat(locale === "de" ? "de-DE" : "en-GB", {
    dateStyle: "medium",
    timeStyle: "short",
  }).format(parsed);
}

function decimalToMinor(value: string) {
  const match = /^(\d+)(?:[.,](\d{1,2}))?$/.exec(value.trim());
  if (!match) throw new Error("invalid amount");
  const minor = BigInt(match[1]) * 100n + BigInt((match[2] ?? "").padEnd(2, "0") || "0");
  if (minor > BigInt(Number.MAX_SAFE_INTEGER)) throw new Error("amount too large");
  return Number(minor);
}

function signedDecimalToMinor(value: string) {
  const match = /^(-?)(\d+)(?:[.,](\d{1,2}))?$/.exec(value.trim());
  if (!match) throw new Error("invalid amount");
  const sign = match[1] === "-" ? -1n : 1n;
  const minor = sign * (BigInt(match[2]) * 100n + BigInt((match[3] ?? "").padEnd(2, "0") || "0"));
  if (minor > BigInt(Number.MAX_SAFE_INTEGER) || minor < BigInt(Number.MIN_SAFE_INTEGER)) throw new Error("amount too large");
  return Number(minor);
}

function AccountCreateDialog({ spaces, accounts, locale, onClose, onSaved }: { spaces: FinanceSpace[]; accounts: FinanceAccount[]; locale: FinanceLocale; onClose: () => void; onSaved: (account: FinanceAccount) => void }) {
  const savedCurrencies = [...new Set(accounts.map((account) => account.currency))].sort();
  const [form, setForm] = useState({ spaceID: spaces.find((space) => space.kind === "personal")?.id ?? spaces[0]?.id ?? "", label: "", institution: "", type: "CURRENT" as FinanceAccountType, currency: savedCurrencies[0] ?? "GBP", lastFour: "", cashflow: true, netWorth: true, minimum: "0", currentBalance: "", balanceObservedAt: new Date(Date.now() - new Date().getTimezoneOffset() * 60_000).toISOString().slice(0, 16) });
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState("");
  const copy = locale === "de" ? {
    title: "Manuelles Konto hinzufügen", detail: "Füge ein Konto ohne Bankverbindung hinzu. HausKlar erhält keine Zugangsdaten und kann kein Geld bewegen.", finances: "Finanzen", label: "Kontoname", institution: "Institut (optional)", type: "Kontotyp", currency: "Währung", lastFour: "Letzte vier Ziffern (optional)", cashflow: "In den Geldfluss einbeziehen", netWorth: "Im Nettovermögen berücksichtigen", minimum: "Mindestbestand", currentBalance: "Aktueller Kontostand", balanceObservedAt: "Stand geprüft am", balanceHelp: "Dieser datierte Stand macht Ausblicke nutzbar. Überziehung als negativen Betrag eingeben.", save: "Konto hinzufügen", saving: "Wird hinzugefügt…", cancel: "Abbrechen", error: "Das Konto konnte nicht hinzugefügt werden. Prüfe Name, Währung, Beträge, Datum und die letzten vier Ziffern.", types: { CURRENT: "Girokonto", SAVINGS: "Sparkonto", CREDIT_CARD: "Kreditkarte", CASH: "Bargeld", INVESTMENT: "Anlagekonto", CRYPTO: "Krypto" },
  } : {
    title: "Add a manual account", detail: "Add an account without connecting a bank. HausKlar receives no credentials and cannot move money.", finances: "Finances", label: "Account name", institution: "Institution (optional)", type: "Account type", currency: "Currency", lastFour: "Last four digits (optional)", cashflow: "Include in cashflow", netWorth: "Include in net worth", minimum: "Minimum balance", currentBalance: "Current balance", balanceObservedAt: "Balance checked at", balanceHelp: "This dated balance makes forecasts usable. Enter an overdraft as a negative amount.", save: "Add account", saving: "Adding…", cancel: "Cancel", error: "The account could not be added. Check its name, currency, amounts, date and last four digits.", types: { CURRENT: "Current account", SAVINGS: "Savings", CREDIT_CARD: "Credit card", CASH: "Cash wallet", INVESTMENT: "Investment", CRYPTO: "Crypto" },
  };

  async function submit(event: FormEvent) {
    event.preventDefault();
    let minimum: number;
    let currentBalance: number;
    let balanceObservedAt: string;
    try {
      minimum = decimalToMinor(form.minimum);
      currentBalance = signedDecimalToMinor(form.currentBalance);
      const observed = new Date(form.balanceObservedAt);
      if (Number.isNaN(observed.valueOf())) throw new Error("invalid date");
      balanceObservedAt = observed.toISOString();
    } catch { setError(copy.error); return; }
    if (saving || !spaces.some((space) => space.id === form.spaceID) || !form.label.trim() || !/^[A-Za-z]{3}$/.test(form.currency.trim()) || form.lastFour && !/^\d{4}$/.test(form.lastFour)) { setError(copy.error); return; }
    setSaving(true); setError("");
    try {
      const saved = await api<FinanceAccount>(`/finance/accounts?space_id=${encodeURIComponent(form.spaceID)}`, { method: "POST", body: JSON.stringify({ label: form.label.trim(), institution: form.institution.trim() || null, account_type: form.type, currency: form.currency.trim().toUpperCase(), last_four: form.lastFour || null, include_in_cashflow: form.cashflow, include_in_net_worth: form.netWorth, minimum_balance_minor: minimum, current_balance_minor: currentBalance, balance_observed_at: balanceObservedAt }) }, true, false);
      if (saved.space_id !== form.spaceID) throw new Error(copy.error);
      onSaved(saved);
    } catch (caught) { setError(caught instanceof Error && caught.message ? caught.message : copy.error); }
    finally { setSaving(false); }
  }

  return <Modal open onOpenChange={(open) => { if (!open && !saving) onClose(); }} title={copy.title} description={copy.detail}><form className="finance-account-edit-form" onSubmit={(event) => void submit(event)} aria-busy={saving}>{error ? <p className="form-error" role="alert">{error}</p> : null}{spaces.length > 1 ? <div className="field"><label htmlFor="finance-new-account-space">{copy.finances}</label><select id="finance-new-account-space" value={form.spaceID} onChange={(event) => setForm({ ...form, spaceID: event.target.value })}>{spaces.map((space) => <option value={space.id} key={space.id}>{space.name}</option>)}</select></div> : null}<div className="field"><label htmlFor="finance-new-account-label">{copy.label}</label><input id="finance-new-account-label" maxLength={120} autoComplete="off" value={form.label} onChange={(event) => setForm({ ...form, label: event.target.value })} required /></div><div className="field"><label htmlFor="finance-new-account-institution">{copy.institution}</label><input id="finance-new-account-institution" maxLength={120} autoComplete="off" value={form.institution} onChange={(event) => setForm({ ...form, institution: event.target.value })} /></div><div className="field"><label htmlFor="finance-new-account-type">{copy.type}</label><select id="finance-new-account-type" value={form.type} onChange={(event) => setForm({ ...form, type: event.target.value as FinanceAccountType })}>{Object.entries(copy.types).map(([value, label]) => <option value={value} key={value}>{label}</option>)}</select></div><div className="field"><label htmlFor="finance-new-account-currency">{copy.currency}</label><input id="finance-new-account-currency" type="text" list="finance-saved-currencies" maxLength={3} autoCapitalize="characters" spellCheck={false} value={form.currency} onChange={(event) => setForm({ ...form, currency: event.target.value.toUpperCase() })} required /><datalist id="finance-saved-currencies">{savedCurrencies.map((currency) => <option value={currency} key={currency} />)}</datalist></div><div className="field"><label htmlFor="finance-new-account-last-four">{copy.lastFour}</label><input id="finance-new-account-last-four" type="text" inputMode="numeric" maxLength={4} value={form.lastFour} onChange={(event) => setForm({ ...form, lastFour: event.target.value.replace(/\D/g, "") })} /></div><div className="field"><label htmlFor="finance-new-account-minimum">{copy.minimum}</label><input id="finance-new-account-minimum" type="text" inputMode="decimal" value={form.minimum} onChange={(event) => setForm({ ...form, minimum: event.target.value })} required /></div><div className="field"><label htmlFor="finance-new-account-balance">{copy.currentBalance}</label><input id="finance-new-account-balance" type="text" inputMode="decimal" value={form.currentBalance} onChange={(event) => setForm({ ...form, currentBalance: event.target.value })} required /></div><div className="field"><label htmlFor="finance-new-account-observed">{copy.balanceObservedAt}</label><input id="finance-new-account-observed" type="datetime-local" value={form.balanceObservedAt} onChange={(event) => setForm({ ...form, balanceObservedAt: event.target.value })} required /><small>{copy.balanceHelp}</small></div><label className="check-row"><input type="checkbox" checked={form.cashflow} onChange={(event) => setForm({ ...form, cashflow: event.target.checked })} /><span>{copy.cashflow}</span></label><label className="check-row"><input type="checkbox" checked={form.netWorth} onChange={(event) => setForm({ ...form, netWorth: event.target.checked })} /><span>{copy.netWorth}</span></label><div className="dialog-actions"><button type="button" className="button button--secondary" disabled={saving} onClick={onClose}>{copy.cancel}</button><button type="submit" className="button button--primary" disabled={saving} aria-busy={saving}>{saving ? copy.saving : copy.save}</button></div></form></Modal>;
}

function AccountEditDialog({
  account,
  accounts,
  locale,
  copy,
  onClose,
  onSaved,
}: {
  account: FinanceAccount;
  accounts: FinanceAccount[];
  locale: FinanceLocale;
  copy: FinanceStrings;
  onClose: () => void;
  onSaved: (account: FinanceAccount) => void;
}) {
  const [label, setLabel] = useState(account.label);
  const [purpose, setPurpose] = useState<FinanceAccountPurpose>(account.purpose);
  const [cashflow, setCashflow] = useState(account.include_in_cashflow);
  const [netWorth, setNetWorth] = useState(account.include_in_net_worth);
  const [primarySpending, setPrimarySpending] = useState(account.primary_spending_account);
  const [minimumBalance, setMinimumBalance] = useState((account.minimum_balance_minor / 100).toFixed(2));
  const [cardPaidInFull, setCardPaidInFull] = useState(account.card_paid_in_full);
  const [cardSettlementAccountID, setCardSettlementAccountID] = useState(account.card_settlement_account_id ?? "");
  const [cardStatementCloseDay, setCardStatementCloseDay] = useState(account.card_statement_close_day?.toString() ?? "");
  const [cardRepaymentDay, setCardRepaymentDay] = useState(account.card_repayment_day?.toString() ?? "");
  const [errors, setErrors] = useState<{ label?: string; minimum?: string; card?: string }>({});
  const [requestError, setRequestError] = useState("");
  const [saving, setSaving] = useState(false);

  let parsedMinimum: number | null = null;
  try {
    parsedMinimum = decimalToMinor(minimumBalance);
  } catch {
    parsedMinimum = null;
  }
  const allowedPurposes: FinanceAccountPurpose[] = account.account_type === "CREDIT_CARD"
    ? ["CREDIT_CARD", "IGNORED"]
    : account.account_type === "INVESTMENT" || account.account_type === "CRYPTO"
      ? ["INVESTMENT_LIKE", "IGNORED"]
      : ["OPERATING_CURRENT", "SAVINGS", "GOAL", "IGNORED"];
  const canBePrimarySpending = cashflow
    && ["CURRENT", "SAVINGS", "CASH"].includes(account.account_type)
    && purpose !== "IGNORED"
    && purpose !== "INVESTMENT_LIKE";
  const effectivePrimarySpending = canBePrimarySpending && primarySpending;
  const isCreditCard = account.account_type === "CREDIT_CARD";
  const supportsMinimumBalance = ["CURRENT", "SAVINGS", "CASH"].includes(account.account_type);
  const eligibleSettlementAccounts = accounts.filter((candidate) => (
    candidate.id !== account.id
    && candidate.space_id === account.space_id
    && candidate.currency === account.currency
    && ["CURRENT", "SAVINGS", "CASH"].includes(candidate.account_type)
    && candidate.include_in_cashflow
    && ["OPERATING_CURRENT", "SAVINGS", "GOAL"].includes(candidate.purpose)
  ));
  const parsedStatementCloseDay = Number(cardStatementCloseDay);
  const parsedRepaymentDay = Number(cardRepaymentDay);
  const validCardDay = (value: number, raw: string) => /^\d{1,2}$/.test(raw) && Number.isInteger(value) && value >= 1 && value <= 31;
  const changed = label.trim() !== account.label
    || purpose !== account.purpose
    || cashflow !== account.include_in_cashflow
    || netWorth !== account.include_in_net_worth
    || effectivePrimarySpending !== account.primary_spending_account
    || (supportsMinimumBalance && parsedMinimum !== account.minimum_balance_minor)
    || (isCreditCard && (
      cardPaidInFull !== account.card_paid_in_full
      || (cardPaidInFull ? cardSettlementAccountID : null) !== account.card_settlement_account_id
      || (cardPaidInFull ? parsedStatementCloseDay : null) !== account.card_statement_close_day
      || (cardPaidInFull ? parsedRepaymentDay : null) !== account.card_repayment_day
    ));

  async function save(event: FormEvent) {
    event.preventDefault();
    const nextErrors: typeof errors = {};
    if (!label.trim()) nextErrors.label = copy.accountLabelRequired;
    if (supportsMinimumBalance && parsedMinimum === null) nextErrors.minimum = copy.minimumBalanceInvalid;
    if (isCreditCard && cardPaidInFull && (
      !eligibleSettlementAccounts.some((candidate) => candidate.id === cardSettlementAccountID)
      || !validCardDay(parsedStatementCloseDay, cardStatementCloseDay)
      || !validCardDay(parsedRepaymentDay, cardRepaymentDay)
    )) nextErrors.card = copy.cardSettingsRequired;
    setErrors(nextErrors);
    if (Object.keys(nextErrors).length || (supportsMinimumBalance && parsedMinimum === null) || !changed) return;
    setSaving(true);
    setRequestError("");
    try {
      const saved = await api<FinanceAccount>(
        `/finance/accounts/${encodeURIComponent(account.id)}?space_id=${encodeURIComponent(account.space_id)}`,
        {
          method: "PATCH",
          body: JSON.stringify({
            label: label.trim(),
            purpose,
            include_in_cashflow: cashflow,
            include_in_net_worth: netWorth,
            primary_spending_account: effectivePrimarySpending,
            ...(supportsMinimumBalance ? { minimum_balance_minor: parsedMinimum } : {}),
            ...(isCreditCard ? {
              card_paid_in_full: cardPaidInFull,
              card_settlement_account_id: cardPaidInFull ? cardSettlementAccountID : null,
              card_statement_close_day: cardPaidInFull ? parsedStatementCloseDay : null,
              card_repayment_day: cardPaidInFull ? parsedRepaymentDay : null,
            } : {}),
          }),
        },
        true,
        false,
      );
      if (saved.id !== account.id || saved.space_id !== account.space_id) {
        throw new Error(copy.accountSaveError);
      }
      onSaved(saved);
    } catch (error) {
      setRequestError(error instanceof Error && error.message ? error.message : copy.accountSaveError);
    } finally {
      setSaving(false);
    }
  }

  return (
    <Modal
      open
      onOpenChange={(open) => { if (!open && !saving) onClose(); }}
      title={copy.editAccount}
      description={[account.institution, account.currency, account.last_four ? `${copy.endingIn} ${account.last_four}` : null].filter(Boolean).join(" · ")}
    >
      <form className="finance-account-edit-form" onSubmit={(event) => void save(event)} aria-busy={saving}>
        {requestError ? <p className="form-error" role="alert">{requestError}</p> : null}
        <div className="field">
          <label htmlFor="finance-account-label">{copy.accountLabel}</label>
          <input
            id="finance-account-label"
            type="text"
            autoComplete="off"
            spellCheck={false}
            maxLength={120}
            value={label}
            aria-invalid={errors.label ? "true" : undefined}
            aria-describedby={errors.label ? "finance-account-label-error" : undefined}
            onChange={(event) => { setLabel(event.target.value); setErrors((current) => ({ ...current, label: undefined })); }}
          />
          {errors.label ? <p id="finance-account-label-error" className="field-error">{errors.label}</p> : null}
        </div>
        <div className="field">
          <label htmlFor="finance-account-purpose">{copy.accountPurpose}</label>
          <select id="finance-account-purpose" value={purpose} onChange={(event) => {
            const value = event.target.value as FinanceAccountPurpose;
            setPurpose(value);
            if (value === "IGNORED") {
              setCashflow(false);
              setNetWorth(false);
              setPrimarySpending(false);
            }
          }}>
            {allowedPurposes.map((value) => (
              <option value={value} key={value}>{copy.accountPurposes[value]}</option>
            ))}
          </select>
        </div>
        <fieldset className="finance-account-counts">
          <legend>{copy.countsToward}</legend>
          <label>
            <input type="checkbox" checked={cashflow} onChange={(event) => setCashflow(event.target.checked)} />
            <span><strong>{copy.includeCashflow}</strong><small>{copy.includeCashflowDetail}</small></span>
          </label>
          <label>
            <input type="checkbox" checked={netWorth} onChange={(event) => setNetWorth(event.target.checked)} />
            <span><strong>{copy.includeNetWorth}</strong><small>{copy.includeNetWorthDetail}</small></span>
          </label>
        </fieldset>
        {supportsMinimumBalance ? <div className="field">
          <label htmlFor="finance-account-minimum">{copy.minimumBalance}</label>
          <div className="finance-money-input">
            <input
              id="finance-account-minimum"
              type="text"
              inputMode="decimal"
              autoComplete="off"
              value={minimumBalance}
              aria-invalid={errors.minimum ? "true" : undefined}
              aria-describedby={errors.minimum ? "finance-account-minimum-error" : "finance-account-minimum-help"}
              onChange={(event) => { setMinimumBalance(event.target.value); setErrors((current) => ({ ...current, minimum: undefined })); }}
            />
            <span>{account.currency}</span>
          </div>
          <p id="finance-account-minimum-help" className="field-help">{copy.minimumBalanceDetail}</p>
          {errors.minimum ? <p id="finance-account-minimum-error" className="field-error">{errors.minimum}</p> : null}
        </div> : null}
        {canBePrimarySpending ? (
          <label className="finance-account-primary">
            <input type="checkbox" checked={primarySpending} onChange={(event) => setPrimarySpending(event.target.checked)} />
            <span><strong>{copy.primarySpending}</strong><small>{copy.primarySpendingDetail}</small></span>
          </label>
        ) : null}
        {isCreditCard ? (
          <fieldset className="finance-card-settings" aria-describedby={errors.card ? "finance-card-settings-error" : undefined}>
            <legend>{copy.accountPurposes.CREDIT_CARD}</legend>
            <label className="finance-account-primary">
              <input type="checkbox" checked={cardPaidInFull} onChange={(event) => { setCardPaidInFull(event.target.checked); setErrors((current) => ({ ...current, card: undefined })); }} />
              <span><strong>{copy.cardPaidInFull}</strong><small>{copy.cardPaidInFullDetail}</small></span>
            </label>
            {cardPaidInFull ? eligibleSettlementAccounts.length ? (
              <div className="finance-card-setting-fields">
                <div className="field">
                  <label htmlFor="finance-card-settlement-account">{copy.cardSettlementAccount}</label>
                  <select id="finance-card-settlement-account" value={cardSettlementAccountID} aria-invalid={errors.card ? "true" : undefined} onChange={(event) => { setCardSettlementAccountID(event.target.value); setErrors((current) => ({ ...current, card: undefined })); }}>
                    <option value="">—</option>
                    {eligibleSettlementAccounts.map((candidate) => <option value={candidate.id} key={candidate.id}>{candidate.label}</option>)}
                  </select>
                </div>
                <div className="field">
                  <label htmlFor="finance-card-close-day">{copy.cardStatementCloseDay}</label>
                  <input id="finance-card-close-day" type="text" inputMode="numeric" pattern="[0-9]*" autoComplete="off" value={cardStatementCloseDay} aria-invalid={errors.card ? "true" : undefined} aria-describedby="finance-card-day-help" onChange={(event) => { setCardStatementCloseDay(event.target.value); setErrors((current) => ({ ...current, card: undefined })); }} />
                </div>
                <div className="field">
                  <label htmlFor="finance-card-repayment-day">{copy.cardRepaymentDay}</label>
                  <input id="finance-card-repayment-day" type="text" inputMode="numeric" pattern="[0-9]*" autoComplete="off" value={cardRepaymentDay} aria-invalid={errors.card ? "true" : undefined} aria-describedby="finance-card-day-help" onChange={(event) => { setCardRepaymentDay(event.target.value); setErrors((current) => ({ ...current, card: undefined })); }} />
                </div>
                <p id="finance-card-day-help" className="field-help">{copy.cardDayHelp}</p>
              </div>
            ) : <p className="finance-setup-inline-error"><AlertCircle aria-hidden="true" size={17} /> {copy.noCardSettlementAccounts}</p> : null}
            {errors.card ? <p id="finance-card-settings-error" className="field-error">{errors.card}</p> : null}
          </fieldset>
        ) : null}
        <div className="dialog-actions">
          <button type="button" className="button button--secondary" onClick={onClose} disabled={saving}>{copy.cancel}</button>
          <button type="submit" className="button button--primary" disabled={saving || !changed}>
            {saving ? copy.savingAccount : copy.saveAccount}
          </button>
        </div>
      </form>
    </Modal>
  );
}

function appendImportSettings(
  form: FormData,
  values: {
    sourceKind: ImportSourceKind;
    account: FinanceAccount;
    currency: string;
    sign: SignConvention;
    dateFormat: "%d/%m/%Y" | "%Y-%m-%d";
    delimiter: "," | ";" | "\t";
    encoding: "utf-8" | "utf-8-sig";
    bookingDateColumn: string;
    amountColumn: string;
    descriptionColumn: string;
    currencyColumn: string;
    transactionIdColumn: string;
    valueDateColumn: string;
    statusColumn: string;
  },
) {
  form.append("source_kind", values.sourceKind);
  form.append("space_id", values.account.space_id);
  form.append("account_id", values.account.id);
  form.append("currency", values.currency);
  form.append("confirmed", "true");
  if (values.sourceKind === "CSV") {
    form.append("sign_convention", values.sign);
    form.append("csv_date_format", values.dateFormat);
    form.append("csv_delimiter", values.delimiter);
    form.append("csv_encoding", values.encoding);
    form.append("csv_booking_date_column", values.bookingDateColumn.trim());
    form.append("csv_amount_column", values.amountColumn.trim());
    form.append("csv_description_column", values.descriptionColumn.trim());
    if (values.currencyColumn.trim()) form.append("csv_currency_column", values.currencyColumn.trim());
    if (values.transactionIdColumn.trim()) form.append("csv_transaction_id_column", values.transactionIdColumn.trim());
    if (values.valueDateColumn.trim()) form.append("csv_value_date_column", values.valueDateColumn.trim());
    if (values.statusColumn.trim()) form.append("csv_status_column", values.statusColumn.trim());
  }
}

function StatementImportDialog({
  accounts,
  spaces,
  locale,
  copy,
  onClose,
}: {
  accounts: FinanceAccount[];
  spaces: FinanceSpace[];
  locale: FinanceLocale;
  copy: FinanceStrings;
  onClose: () => void;
}) {
  const currencies = useMemo(
    () => [...new Set(accounts.map((account) => account.currency))].sort(),
    [accounts],
  );
  const [sourceKind, setSourceKind] = useState<ImportSourceKind>("CSV");
  const [currency, setCurrency] = useState(currencies[0] ?? "GBP");
  const eligibleAccounts = accounts.filter((account) => account.currency === currency);
  const [accountID, setAccountID] = useState(eligibleAccounts[0]?.id ?? accounts[0]?.id ?? "");
  const [file, setFile] = useState<File | null>(null);
  const [sign, setSign] = useState<SignConvention>("DEBIT_NEGATIVE");
  const [dateFormat, setDateFormat] = useState<"%d/%m/%Y" | "%Y-%m-%d">("%d/%m/%Y");
  const [delimiter, setDelimiter] = useState<"," | ";" | "\t">(",");
  const [encoding, setEncoding] = useState<"utf-8" | "utf-8-sig">("utf-8-sig");
  const [bookingDateColumn, setBookingDateColumn] = useState("Date");
  const [amountColumn, setAmountColumn] = useState("Amount");
  const [descriptionColumn, setDescriptionColumn] = useState("Description");
  const [currencyColumn, setCurrencyColumn] = useState("");
  const [transactionIdColumn, setTransactionIdColumn] = useState("");
  const [valueDateColumn, setValueDateColumn] = useState("");
  const [statusColumn, setStatusColumn] = useState("");
  const [preview, setPreview] = useState<FinanceImportPreview | null>(null);
  const [result, setResult] = useState<FinanceImportResult | null>(null);
  const [busy, setBusy] = useState<"preview" | "confirm" | null>(null);
  const [error, setError] = useState("");
  const spaceNames = new Map(spaces.map((space) => [space.id, space.name]));
  const selectedAccount = accounts.find((account) => account.id === accountID && account.currency === currency)
    ?? eligibleAccounts[0]
    ?? null;

  function invalidatePreview() {
    setPreview(null);
    setResult(null);
    setError("");
  }

  function chooseCurrency(value: string) {
    const first = accounts.find((account) => account.currency === value);
    setCurrency(value);
    setAccountID(first?.id ?? "");
    invalidatePreview();
  }

  function settings() {
    if (!selectedAccount) return null;
    return {
      sourceKind,
      account: selectedAccount,
      currency,
      sign,
      dateFormat,
      delimiter,
      encoding,
      bookingDateColumn,
      amountColumn,
      descriptionColumn,
      currencyColumn,
      transactionIdColumn,
      valueDateColumn,
      statusColumn,
    };
  }

  async function requestPreview(event: FormEvent) {
    event.preventDefault();
    const selectedSettings = settings();
    if (
      !file
      || !selectedSettings
      || (sourceKind === "CSV" && (!bookingDateColumn.trim() || !amountColumn.trim() || !descriptionColumn.trim()))
    ) {
      setError(copy.importFormError);
      return;
    }
    setBusy("preview");
    setError("");
    try {
      const form = new FormData();
      form.append("file", file, file.name);
      appendImportSettings(form, selectedSettings);
      const loaded = await api<FinanceImportPreview>(
        "/finance/imports/preview",
        { method: "POST", body: form },
        true,
        false,
      );
      if (loaded.account_id !== selectedAccount.id || loaded.space_id !== selectedAccount.space_id) {
        throw new Error(copy.importFormError);
      }
      setPreview(loaded);
    } catch (requestError) {
      setError(requestError instanceof Error && requestError.message ? requestError.message : copy.importFormError);
    } finally {
      setBusy(null);
    }
  }

  async function confirmImport() {
    const selectedSettings = settings();
    if (!file || !selectedSettings || !preview?.can_confirm || busy) return;
    setBusy("confirm");
    setError("");
    try {
      const form = new FormData();
      form.append("file", file, file.name);
      form.append("preview_batch_id", preview.batch_id);
      appendImportSettings(form, selectedSettings);
      const imported = await api<FinanceImportResult>(
        "/finance/imports/confirm",
        { method: "POST", body: form },
        true,
        false,
      );
      setResult(imported);
    } catch (requestError) {
      setError(requestError instanceof Error && requestError.message ? requestError.message : copy.importFormError);
    } finally {
      setBusy(null);
    }
  }

  return (
    <Modal open onOpenChange={(open) => { if (!open && !busy) onClose(); }} title={copy.importTitle} description={copy.importDetail} size="wide">
      {result ? (
        <div className="finance-import-complete" role="status">
          <CheckCircle2 aria-hidden="true" size={34} />
          <h3>{copy.importCompleteTitle}</h3>
          <p>{copy.importCompleteDetail}</p>
          <dl>
            <div><dt>{copy.importedTransactions}</dt><dd>{result.canonical_created}</dd></div>
            <div><dt>{copy.skippedDuplicates}</dt><dd>{result.duplicates}</dd></div>
          </dl>
          <button type="button" className="button button--primary" onClick={onClose}>{copy.close}</button>
        </div>
      ) : (
        <form className="finance-import-form" onSubmit={(event) => void requestPreview(event)} aria-busy={busy !== null}>
          {error ? <p className="form-error" role="alert">{error}</p> : null}
          <div className="finance-import-grid">
            <div className="field">
              <label htmlFor="finance-import-file">{copy.statementFile}</label>
              <input
                id="finance-import-file"
                type="file"
                accept=".csv,.ofx,.qfx,text/csv,application/x-ofx"
                onChange={(event) => {
                  const next = event.target.files?.[0] ?? null;
                  setFile(next);
                  if (next && /\.(ofx|qfx)$/i.test(next.name)) setSourceKind("OFX");
                  if (next && /\.csv$/i.test(next.name)) setSourceKind("CSV");
                  invalidatePreview();
                }}
              />
              <p className="field-help">{copy.statementFileHelp}</p>
            </div>
            <div className="field">
              <label htmlFor="finance-import-format">{copy.statementFormat}</label>
              <select id="finance-import-format" value={sourceKind} onChange={(event) => { setSourceKind(event.target.value as ImportSourceKind); invalidatePreview(); }}>
                <option value="CSV">CSV</option>
                <option value="OFX">OFX / QFX</option>
              </select>
            </div>
            <div className="field">
              <label htmlFor="finance-import-currency">{copy.statementCurrency}</label>
              <select id="finance-import-currency" value={currency} onChange={(event) => chooseCurrency(event.target.value)}>
                {currencies.map((value) => <option value={value} key={value}>{value}</option>)}
              </select>
            </div>
            <div className="field">
              <label htmlFor="finance-import-account">{copy.statementAccount}</label>
              <select id="finance-import-account" value={selectedAccount?.id ?? ""} onChange={(event) => { setAccountID(event.target.value); invalidatePreview(); }}>
                {eligibleAccounts.map((account) => (
                  <option value={account.id} key={account.id}>{account.label} · {spaceNames.get(account.space_id)}</option>
                ))}
              </select>
            </div>
          </div>

          {sourceKind === "CSV" ? (
            <>
              <fieldset className="finance-import-sign">
                <legend>{copy.statementSign}</legend>
                <label><input type="radio" name="statement-sign" value="DEBIT_NEGATIVE" checked={sign === "DEBIT_NEGATIVE"} onChange={() => { setSign("DEBIT_NEGATIVE"); invalidatePreview(); }} /><span>{copy.debitNegative}</span></label>
                <label><input type="radio" name="statement-sign" value="DEBIT_POSITIVE" checked={sign === "DEBIT_POSITIVE"} onChange={() => { setSign("DEBIT_POSITIVE"); invalidatePreview(); }} /><span>{copy.debitPositive}</span></label>
              </fieldset>
              <div className="finance-import-grid is-three">
                <div className="field"><label htmlFor="finance-import-date-format">{copy.csvDateFormat}</label><select id="finance-import-date-format" value={dateFormat} onChange={(event) => { setDateFormat(event.target.value as typeof dateFormat); invalidatePreview(); }}><option value="%d/%m/%Y">DD/MM/YYYY</option><option value="%Y-%m-%d">YYYY-MM-DD</option></select></div>
                <div className="field"><label htmlFor="finance-import-delimiter">{copy.csvDelimiter}</label><select id="finance-import-delimiter" value={delimiter} onChange={(event) => { setDelimiter(event.target.value as typeof delimiter); invalidatePreview(); }}><option value=",">{copy.comma}</option><option value=";">{copy.semicolon}</option><option value={"\t"}>{copy.tab}</option></select></div>
                <div className="field"><label htmlFor="finance-import-encoding">{copy.csvEncoding}</label><select id="finance-import-encoding" value={encoding} onChange={(event) => { setEncoding(event.target.value as typeof encoding); invalidatePreview(); }}><option value="utf-8-sig">UTF-8</option><option value="utf-8">UTF-8 (no BOM)</option></select></div>
              </div>
              <fieldset className="finance-import-columns">
                <legend>{copy.requiredColumns}</legend>
                <div className="finance-import-grid is-three">
                  <div className="field"><label htmlFor="finance-import-booking-column">{copy.bookingDateColumn}</label><input id="finance-import-booking-column" type="text" autoComplete="off" spellCheck={false} value={bookingDateColumn} onChange={(event) => { setBookingDateColumn(event.target.value); invalidatePreview(); }} /></div>
                  <div className="field"><label htmlFor="finance-import-amount-column">{copy.amountColumn}</label><input id="finance-import-amount-column" type="text" autoComplete="off" spellCheck={false} value={amountColumn} onChange={(event) => { setAmountColumn(event.target.value); invalidatePreview(); }} /></div>
                  <div className="field"><label htmlFor="finance-import-description-column">{copy.descriptionColumn}</label><input id="finance-import-description-column" type="text" autoComplete="off" spellCheck={false} value={descriptionColumn} onChange={(event) => { setDescriptionColumn(event.target.value); invalidatePreview(); }} /></div>
                </div>
              </fieldset>
              <details className="finance-import-optional">
                <summary>{copy.optionalColumns}</summary>
                <div className="finance-import-grid">
                  {[
                    ["currency", copy.currencyColumn, currencyColumn, setCurrencyColumn],
                    ["transaction-id", copy.transactionIdColumn, transactionIdColumn, setTransactionIdColumn],
                    ["value-date", copy.valueDateColumn, valueDateColumn, setValueDateColumn],
                    ["status", copy.statusColumn, statusColumn, setStatusColumn],
                  ].map(([id, label, value, setter]) => (
                    <div className="field" key={id as string}>
                      <label htmlFor={`finance-import-${id}`}>{label as string}</label>
                      <input id={`finance-import-${id}`} type="text" autoComplete="off" spellCheck={false} value={value as string} placeholder={copy.noColumn} onChange={(event) => { (setter as (value: string) => void)(event.target.value); invalidatePreview(); }} />
                    </div>
                  ))}
                </div>
              </details>
            </>
          ) : <p className="finance-import-ofx-note"><ShieldCheck aria-hidden="true" size={17} /> {copy.ofxSign}</p>}

          {!preview ? (
            <button type="submit" className="button button--primary" disabled={busy !== null || !file || !selectedAccount}>
              <FileSpreadsheet aria-hidden="true" size={17} /> {busy === "preview" ? copy.previewingImport : copy.previewImport}
            </button>
          ) : (
            <section className="finance-import-preview" aria-labelledby="finance-import-preview-title">
              <header>
                <h3 id="finance-import-preview-title">{copy.importPreviewTitle}</h3>
                <p className={cn("finance-import-repair", preview.repair.relationship === "OVERLAP" && "is-warning")}>
                  {copy.importRelationship[preview.repair.relationship]}
                  {preview.repair.relationship === "OVERLAP" && preview.repair.overlap_start && preview.repair.overlap_end
                    ? ` ${copy.overlapPeriod}: ${formatDate(preview.repair.overlap_start, locale)}–${formatDate(preview.repair.overlap_end, locale)}.`
                    : ""}
                </p>
              </header>
              <dl className="finance-import-stats">
                <div><dt>{copy.totalRows}</dt><dd>{preview.total_rows}</dd></div>
                <div><dt>{copy.importableRows}</dt><dd>{preview.importable_rows}</dd></div>
                <div><dt>{copy.invalidRows}</dt><dd>{preview.invalid_rows}</dd></div>
                <div><dt>{copy.duplicateRows}</dt><dd>{preview.duplicate_rows}</dd></div>
              </dl>
              {preview.issues.length ? (
                <div className="finance-import-issues">
                  <h4>{copy.importIssuesTitle}</h4>
                  <ul>{preview.issues.map((issue, index) => <li className={issue.severity === "ERROR" ? "is-error" : ""} key={`${issue.code}:${issue.row_number ?? index}`}>{issue.row_number ? `${issue.row_number}: ` : ""}{issue.message}</li>)}</ul>
                  {preview.issues_truncated ? <p>{copy.importIssuesTruncated}</p> : null}
                </div>
              ) : null}
              {preview.sample_rows.length ? (
                <div className="finance-import-sample">
                  <h4>{copy.importSampleTitle}</h4>
                  <div className="finance-import-table-scroll">
                    <table><thead><tr><th>{copy.bookingDateColumn}</th><th>{copy.descriptionColumn}</th><th>{copy.amountColumn}</th></tr></thead><tbody>{preview.sample_rows.map((row) => <tr key={row.row_number}><td>{formatDate(row.booking_date, locale)}</td><td>{row.description}</td><td>{formatCurrency(row.amount_minor, row.currency, locale)}</td></tr>)}</tbody></table>
                  </div>
                </div>
              ) : null}
              <div className="dialog-actions">
                <button type="button" className="button button--secondary" disabled={busy !== null} onClick={() => setPreview(null)}>{copy.cancel}</button>
                <button type="button" className="button button--primary" disabled={!preview.can_confirm || busy !== null} onClick={() => void confirmImport()}>
                  <Upload aria-hidden="true" size={17} /> {busy === "confirm" ? copy.importingStatement : copy.confirmImport}
                </button>
              </div>
            </section>
          )}
        </form>
      )}
    </Modal>
  );
}

export function FinanceSetupView({
  spaces,
  locale,
  copy,
  onBankRedirect = (url) => window.location.assign(url),
}: {
  spaces: FinanceSpace[];
  locale: FinanceLocale;
  copy: FinanceStrings;
  onBankRedirect?: (url: string) => void;
}) {
  const [state, setState] = useState<SetupLoadState>({ status: "loading" });
  const [retryKey, setRetryKey] = useState(0);
  const [destination, setDestination] = useState(spaces.find((space) => space.kind === "personal")?.id ?? spaces[0]?.id ?? "");
  const [working, setWorking] = useState<string | null>(null);
  const [actionError, setActionError] = useState("");
  const [notice, setNotice] = useState("");
  const [pendingDisconnect, setPendingDisconnect] = useState<FinanceConnection | null>(null);
  const [editingAccount, setEditingAccount] = useState<FinanceAccount | null>(null);
  const [showAccountCreate, setShowAccountCreate] = useState(false);
  const [showImport, setShowImport] = useState(false);
  const [emailState, setEmailState] = useState<FinanceEmailAddresses | null>(null);
  const [emailUnavailable, setEmailUnavailable] = useState(false);
  const [emailHealth, setEmailHealth] = useState<Record<string, FinanceEmailHealth>>({});
  const [enrollmentDrafts, setEnrollmentDrafts] = useState<Record<string, { forwarder: string; domain: string }>>({});
  const [preference, setPreference] = useState<FinanceReportPreference | null>(null);
  const [setupWorking, setSetupWorking] = useState<"email" | "notification" | "upload" | null>(null);
  const [firstReportState, setFirstReportState] = useState<"waiting" | "checking" | "ready" | "error">("waiting");
  const [firstReportRetryKey, setFirstReportRetryKey] = useState(0);
  const [privateUpload, setPrivateUpload] = useState<{ file: File | null; title: string }>({ file: null, title: "" });
  const [otherWaysOpen, setOtherWaysOpen] = useState(window.location.hash === "#private-finance-files");
  const selectionKey = JSON.stringify(spaces.map((space) => space.id));
  const spaceNames = new Map(spaces.map((space) => [space.id, space.name]));
  const setupSpace = spaces[0] ?? null;
  const setupAccountKey = state.status === "ready" && setupSpace
    ? state.data.accounts.filter((account) => account.space_id === setupSpace.id).map((account) => account.id).sort().join(":")
    : "";

  useEffect(() => {
    if (spaces.some((space) => space.id === destination)) return;
    setDestination(spaces.find((space) => space.kind === "personal")?.id ?? spaces[0]?.id ?? "");
  }, [selectionKey]);

  useEffect(() => {
    const controller = new AbortController();
    let active = true;
    setState({ status: "loading" });
    Promise.all(spaces.map(async (space) => {
      const ownerAware = space.kind === "household" && spaces.some((candidate) => candidate.kind === "personal") ? "&exclude_own_shared_copies=true" : "";
      const connectionRequest = api<FinanceConnection[]>(
        `/finance/connections?space_id=${encodeURIComponent(space.id)}`,
        { signal: controller.signal },
        true,
        false,
      )
        .then((loaded) => ({ data: loaded.filter((connection) => connection.space_id === space.id), error: false }))
        .catch((error: unknown) => {
          if (isAbortError(error)) throw error;
          return { data: [] as FinanceConnection[], error: true };
        });
      const accountRequest = api<FinanceAccount[]>(
        `/finance/accounts?space_id=${encodeURIComponent(space.id)}${ownerAware}`,
        { signal: controller.signal },
        true,
        false,
      )
        .then((loaded) => ({ data: loaded.filter((account) => account.space_id === space.id), error: false }))
        .catch((error: unknown) => {
          if (isAbortError(error)) throw error;
          return { data: [] as FinanceAccount[], error: true };
        });
      const [connections, accounts] = await Promise.all([connectionRequest, accountRequest]);
      return {
        connections: connections.data,
        accounts: accounts.data,
        connectionsError: connections.error,
        accountsError: accounts.error,
      };
    }))
      .then((results) => {
        if (!active) return;
        if (results.every((result) => result.connectionsError && result.accountsError)) {
          setState({ status: "error" });
          return;
        }
        const connections = new Map<string, FinanceConnection>();
        const accounts = new Map<string, FinanceAccount>();
        for (const result of results) {
          for (const connection of result.connections) if (!connections.has(connection.id)) connections.set(connection.id, connection);
          for (const account of result.accounts) if (!accounts.has(account.id)) accounts.set(account.id, account);
        }
        setState({
          status: "ready",
          data: {
            connections: [...connections.values()].sort((left, right) => left.institution.localeCompare(right.institution) || left.id.localeCompare(right.id)),
            accounts: [...accounts.values()].sort((left, right) => left.label.localeCompare(right.label) || left.id.localeCompare(right.id)),
            connectionsUnavailable: results.some((result) => result.connectionsError),
            accountsUnavailable: results.some((result) => result.accountsError),
          },
        });
      })
      .catch((error: unknown) => {
        if (!active || isAbortError(error)) return;
        setState({ status: "error" });
      });
    return () => { active = false; controller.abort(); };
  }, [selectionKey, retryKey]);

  useEffect(() => {
    if (state.status !== "ready" || !setupSpace) return;
    if (!setupAccountKey) {
      setFirstReportState("waiting");
      return;
    }
    const controller = new AbortController();
    let active = true;
    setFirstReportState("checking");
    void (async () => {
      try {
        const existing = await api<FinanceCoachingReport[]>(
          `/finance/reports?space_id=${encodeURIComponent(setupSpace.id)}&report_kind=DAILY&limit=1`,
          { signal: controller.signal },
          true,
          false,
        );
        if (!active) return;
        if (!Array.isArray(existing) || existing.length === 0) {
          await api<FinanceCoachingReport>(
            `/finance/reports/DAILY/refresh?space_id=${encodeURIComponent(setupSpace.id)}`,
            { method: "POST", signal: controller.signal },
            true,
            false,
          );
        }
        if (active) setFirstReportState("ready");
      } catch (caught) {
        if (!active || isAbortError(caught)) return;
        setFirstReportState("error");
      }
    })();
    return () => {
      active = false;
      controller.abort();
    };
  }, [state.status, setupSpace?.id, setupAccountKey, firstReportRetryKey]);

  useEffect(() => {
    if (!emailState?.addresses.length) {
      setEmailHealth({});
      return;
    }
    const controller = new AbortController();
    let active = true;
    Promise.all(emailState.addresses.map((address) => api<FinanceEmailHealth>(
      `/finance/email-addresses/${encodeURIComponent(address.id)}/health`,
      { signal: controller.signal },
      true,
      false,
    ).then((health) => [address.id, health] as const).catch(() => null)))
      .then((results) => {
        if (!active) return;
        setEmailHealth(Object.fromEntries(results.filter((result): result is readonly [string, FinanceEmailHealth] => result !== null)));
      });
    return () => { active = false; controller.abort(); };
  }, [emailState?.addresses.map((address) => `${address.id}:${address.last_received_at}:${address.last_parsed_at}`).join("|")]);

  useEffect(() => {
    const controller = new AbortController();
    let active = true;
    setEmailUnavailable(false);
    Promise.all([
      api<FinanceEmailAddresses>("/finance/email-addresses", { signal: controller.signal }, true, false),
      setupSpace ? api<FinanceReportPreference>(`/finance/report-preferences?space_id=${encodeURIComponent(setupSpace.id)}`, { signal: controller.signal }, true, false).catch(() => null) : Promise.resolve(null),
    ]).then(([addresses, loadedPreference]) => {
      if (!active) return;
      setEmailState(addresses && setupSpace ? { ...addresses, addresses: addresses.addresses.filter((address) => address.space_id === setupSpace.id) } : addresses);
      setPreference(loadedPreference);
    }).catch((error: unknown) => {
      if (!active || isAbortError(error)) return;
      setEmailUnavailable(true);
    });
    return () => { active = false; controller.abort(); };
  }, [selectionKey, retryKey]);

  async function startApproval(spaceID: string, connectionID?: string) {
    if (working || !spaceID) return;
    setWorking(`start:${connectionID ?? spaceID}`);
    setActionError("");
    setNotice("");
    try {
      const response = await api<{ redirect_url: string }>(
        "/finance/connections/truelayer/start",
        {
          method: "POST",
          body: JSON.stringify({
            space_id: spaceID,
            ...(connectionID ? { connection_id: connectionID } : {}),
          }),
        },
        true,
        false,
      );
      const rawAuthority = response.redirect_url.match(/^https:\/\/([^/?#]+)(?=[/?#]|$)/i)?.[1];
      const redirect = new URL(response.redirect_url);
      if (
        rawAuthority?.toLowerCase() !== "auth.truelayer.com"
        ||
        redirect.protocol !== "https:"
        || redirect.hostname !== "auth.truelayer.com"
        || redirect.port
        || redirect.username
        || redirect.password
      ) throw new Error(copy.bankActionError);
      onBankRedirect(redirect.toString());
    } catch (error) {
      setActionError(error instanceof Error && error.message ? error.message : copy.bankActionError);
      setWorking(null);
    }
  }

  async function refreshConnection(connection: FinanceConnection) {
    if (working || state.status !== "ready") return;
    setWorking(connection.id);
    setActionError("");
    setNotice("");
    try {
      await api<FinanceConnectionSyncResult>(
        `/finance/connections/${encodeURIComponent(connection.id)}/sync`,
        { method: "POST" },
        true,
        false,
      );
      setNotice(copy.bankRefreshed);
      setRetryKey((key) => key + 1);
    } catch (error) {
      setActionError(error instanceof Error && error.message ? error.message : copy.bankActionError);
    } finally {
      setWorking(null);
    }
  }

  async function disconnectConnection() {
    if (!pendingDisconnect || working || state.status !== "ready") return;
    const connection = pendingDisconnect;
    setWorking(connection.id);
    setActionError("");
    try {
      await api(
        `/finance/connections/${encodeURIComponent(connection.id)}`,
        { method: "DELETE" },
        true,
        false,
      );
      setState((current) => current.status === "ready" ? {
        status: "ready",
        data: {
          ...current.data,
          connections: current.data.connections.map((item) => item.id === connection.id ? { ...item, status: "DISCONNECTED" } : item),
        },
      } : current);
      setPendingDisconnect(null);
      setNotice(copy.bankDisconnected);
    } catch (error) {
      setActionError(error instanceof Error && error.message ? error.message : copy.bankActionError);
      setPendingDisconnect(null);
    } finally {
      setWorking(null);
    }
  }

  async function saveNotificationMode(mode: "ACTION_ONLY" | "DAILY" | "NEVER") {
    if (!setupSpace || setupWorking) return;
    setSetupWorking("notification");
    setActionError("");
    try {
      const current = preference;
      const saved = await api<FinanceReportPreference>(
        `/finance/report-preferences?space_id=${encodeURIComponent(setupSpace.id)}`,
        {
          method: "PUT",
          body: JSON.stringify({
            locale,
            daily_time: current?.daily_time ?? "07:00:00",
            enabled: mode !== "NEVER",
            notification_channel: current?.notification_channel ?? "IN_APP",
            notification_mode: mode,
            show_more_by_default: current?.show_more_by_default ?? false,
            quiet_hours_start: current?.quiet_hours_start ?? null,
            quiet_hours_end: current?.quiet_hours_end ?? null,
            underfunded_commitment_threshold_minor: current?.underfunded_commitment_threshold_minor ?? 5000,
            goal_movement_threshold_minor: current?.goal_movement_threshold_minor ?? 5000,
            missed_payday_alerts: current?.missed_payday_alerts ?? true,
            selected_return_deadline_alerts: current?.selected_return_deadline_alerts ?? true,
            tone: current?.tone ?? "BALANCED",
            default_spend_account_id: current?.default_spend_account_id ?? null,
            extra_cash_buffer_minor: current?.extra_cash_buffer_minor ?? 0,
            writing_mode: current?.writing_mode ?? "LOCAL",
            allow_dated_estimates: current?.allow_dated_estimates ?? true,
          }),
        },
        true,
        false,
      );
      setPreference(saved);
      setNotice(locale === "de" ? "Benachrichtigungen gespeichert." : "Notifications saved.");
    } catch {
      setActionError(locale === "de" ? "Die Benachrichtigungsauswahl konnte nicht gespeichert werden." : "The notification choice could not be saved.");
    } finally {
      setSetupWorking(null);
    }
  }

  async function createHouseholdEmail() {
    if (setupWorking) return;
    setSetupWorking("email");
    setActionError("");
    try {
      const created = await api<FinanceEmailAddress>("/finance/email-addresses/household", { method: "POST" }, true, false);
      setEmailState((current) => current ? { ...current, addresses: [...current.addresses.filter((address) => address.id !== created.id), created] } : current);
      setNotice(locale === "de" ? "Gemeinsame Finanzadresse erstellt." : "Household Finance address created.");
    } catch {
      setActionError(locale === "de" ? "Die Finanzadresse konnte nicht erstellt werden." : "The Finance address could not be created.");
    } finally {
      setSetupWorking(null);
    }
  }

  async function testEmail(address: FinanceEmailAddress) {
    if (setupWorking) return;
    setSetupWorking("email");
    setActionError("");
    try {
      await api(`/finance/email-addresses/${encodeURIComponent(address.id)}/send-test`, { method: "POST" }, true, false);
      setEmailState((current) => current ? { ...current, addresses: current.addresses.map((item) => item.id === address.id ? { ...item, last_test_sent_at: new Date().toISOString() } : item) } : current);
      setNotice(locale === "de" ? "Test gesendet." : "Test sent.");
    } catch {
      setActionError(locale === "de" ? "Der Test konnte nicht gesendet werden." : "The test could not be sent.");
    } finally {
      setSetupWorking(null);
    }
  }

  async function replaceEmail(address: FinanceEmailAddress) {
    if (setupWorking) return;
    setSetupWorking("email");
    setActionError("");
    try {
      const replacement = await api<FinanceEmailAddress>(`/finance/email-addresses/${encodeURIComponent(address.id)}/rotate`, { method: "POST" }, true, false);
      setEmailState((current) => current ? { ...current, addresses: current.addresses.map((item) => item.id === address.id ? replacement : item) } : current);
      setNotice(locale === "de" ? "Adresse ersetzt. Aktualisiere deine Weiterleitung." : "Address replaced. Update your forwarding rule.");
    } catch {
      setActionError(locale === "de" ? "Die Adresse konnte nicht ersetzt werden." : "The address could not be replaced.");
    } finally {
      setSetupWorking(null);
    }
  }

  async function copyEmailAddress(address: FinanceEmailAddress) {
    try {
      await navigator.clipboard.writeText(address.address);
      setNotice(locale === "de" ? "Adresse kopiert." : "Address copied.");
    } catch {
      setActionError(locale === "de" ? "Die Adresse konnte nicht kopiert werden." : "The address could not be copied.");
    }
  }

  async function addEmailEnrollment(address: FinanceEmailAddress) {
    const draft = enrollmentDrafts[address.id] ?? { forwarder: "", domain: "" };
    if (!draft.forwarder.trim() || !draft.domain.trim() || setupWorking) return;
    setSetupWorking("email");
    setActionError("");
    try {
      await api(
        `/finance/email-addresses/${encodeURIComponent(address.id)}/enrollments`,
        { method: "POST", body: JSON.stringify({ expected_forwarder_address: draft.forwarder.trim(), retailer_domain: draft.domain.trim(), transport_marker: null }) },
        true,
        false,
      );
      const health = await api<FinanceEmailHealth>(`/finance/email-addresses/${encodeURIComponent(address.id)}/health`, {}, true, false);
      setEmailHealth((current) => ({ ...current, [address.id]: health }));
      setEnrollmentDrafts((current) => ({ ...current, [address.id]: { forwarder: "", domain: "" } }));
      setNotice(locale === "de" ? "Weiterleitung hinzugefügt. Sie wartet auf die erste geprüfte Nachricht." : "Forwarding added. It is waiting for the first verified message.");
    } catch {
      setActionError(locale === "de" ? "Die Weiterleitung konnte nicht hinzugefügt werden." : "The forwarding rule could not be added.");
    } finally {
      setSetupWorking(null);
    }
  }

  function retryFirstReport() {
    if (!setupAccountKey || firstReportState === "checking") return;
    setFirstReportRetryKey((value) => value + 1);
  }

  async function uploadPrivateFile(event: FormEvent) {
    event.preventDefault();
    const personalSpace = spaces.find((space) => space.kind === "personal") ?? null;
    if (!personalSpace || !privateUpload.file || !privateUpload.title.trim() || setupWorking) return;
    setSetupWorking("upload");
    setActionError("");
    const form = new FormData();
    form.set("file", privateUpload.file);
    form.set("title", privateUpload.title.trim());
    try {
      const saved = await api<FinancePurchaseEvidenceUploadResponse>(
        `/finance/purchases/evidence/upload?space_id=${encodeURIComponent(personalSpace.id)}`,
        { method: "POST", body: form },
      );
      if (!isOfflineQueuedResult(saved) && saved.source.space_id !== personalSpace.id) throw new Error("Wrong Finance area");
      setPrivateUpload({ file: null, title: "" });
      setNotice(isOfflineQueuedResult(saved)
        ? (locale === "de" ? "Datei offline gespeichert und wartet auf Synchronisierung." : "File saved offline and waiting to sync.")
        : (locale === "de" ? "Datei privat gespeichert." : "File saved privately."));
    } catch {
      setActionError(locale === "de" ? "Die private Datei konnte nicht gespeichert werden." : "The private file could not be saved.");
    } finally {
      setSetupWorking(null);
    }
  }

  function saveAccount(saved: FinanceAccount) {
    setState((current) => current.status === "ready" ? {
      status: "ready",
      data: {
        ...current.data,
        accounts: current.data.accounts.map((account) => {
          if (account.id === saved.id) return saved;
          if (saved.primary_spending_account && account.space_id === saved.space_id && account.currency === saved.currency) {
            return { ...account, primary_spending_account: false };
          }
          return account;
        }),
      },
    } : current);
    setEditingAccount(null);
    setNotice(copy.accountSaved);
  }

  function addAccount(saved: FinanceAccount) {
    setState((current) => current.status === "ready" ? {
      status: "ready",
      data: {
        ...current.data,
        accounts: [...current.data.accounts, saved].sort((left, right) => left.label.localeCompare(right.label) || left.id.localeCompare(right.id)),
      },
    } : current);
    setShowAccountCreate(false);
    setNotice(locale === "de" ? "Konto hinzugefügt." : "Account added.");
  }

  if (state.status === "loading") {
    return <div className="finance-setup-skeleton" aria-label={copy.setupLoading} aria-busy="true"><div /><div /><div /></div>;
  }
  if (state.status === "error") {
    return (
      <div className="finance-empty-panel is-error" role="alert">
        <AlertCircle aria-hidden="true" size={34} />
        <h2>{copy.setupErrorTitle}</h2><p>{copy.setupErrorDetail}</p>
        <button type="button" className="button button--secondary" onClick={() => setRetryKey((key) => key + 1)}>{copy.retry}</button>
      </div>
    );
  }
  const reconnectCandidate = state.data.connections.find((connection) => (
    connection.can_manage
      && connection.space_id === destination
      && connection.provider === "TRUELAYER"
      && ["EXPIRED", "REAUTH_REQUIRED", "DISCONNECTED"].includes(connection.status)
  ));

  return (
    <div className="finance-section-content finance-setup-view">
      <header className="finance-setup-heading">
        <div><h2>{locale === "de" ? "Finanzen einrichten" : "Set up Finance"}</h2><p>{setupSpace?.kind === "household"
          ? (locale === "de" ? "Du richtest gemeinsame Finanzen ein. Verbundene oder importierte Daten hier sind für beide Erwachsenen sichtbar; private Konten gehören in „Meine Finanzen“." : "You are setting up Household Finance. Anything connected or imported here is visible to both adults; private accounts belong in My finances.")
          : (locale === "de" ? "Verbinde zuerst eine Bank. Du kannst auch ein Konto hinzufügen oder einen Kontoauszug importieren." : "Connect a bank to get started. You can also add an account or import a statement.")}</p></div>
      </header>
      {notice ? <p className="finance-plan-notice" role="status">{notice}</p> : null}
      {actionError ? <p className="form-error" role="alert">{actionError}</p> : null}

      <section className="finance-data-section finance-setup-section" aria-labelledby="finance-bank-connections-title">
        <header><div><span className="finance-setup-step-number">1</span><h2 id="finance-bank-connections-title">{copy.connectBank}</h2><p>{copy.bankConnectionsDetail}</p></div></header>
        <form className="finance-bank-connect-form" onSubmit={(event) => {
          event.preventDefault();
          void startApproval(destination, reconnectCandidate?.id);
        }} aria-busy={working?.startsWith("start:") ?? false}>
          {spaces.length > 1 ? <div className="field"><label htmlFor="finance-bank-destination">{copy.destination}</label><select id="finance-bank-destination" value={destination} onChange={(event) => setDestination(event.target.value)}>{spaces.map((space) => <option value={space.id} key={space.id}>{space.name}</option>)}</select></div> : null}
          <p><ShieldCheck aria-hidden="true" size={18} /> {copy.bankApprovalNotice}</p>
          <button type="submit" className="button button--primary" disabled={Boolean(working) || !destination} aria-busy={working?.startsWith("start:") ?? false}><Landmark aria-hidden="true" size={17} /> {working?.startsWith("start:") ? copy.startingBank : reconnectCandidate ? copy.reconnectBank : state.data.connections.some((connection) => connection.space_id === destination) ? copy.addAnotherBank : copy.leaveForBank}</button>
        </form>
        <div className="finance-setup-import-actions">
          <button type="button" className="button button--secondary" disabled={state.data.accountsUnavailable} onClick={() => setShowAccountCreate(true)}><Plus aria-hidden="true" size={16} /> {locale === "de" ? "Manuelles Konto hinzufügen" : "Add manual account"}</button>
          <button type="button" className="button button--secondary" disabled={!state.data.accounts.length} onClick={() => setShowImport(true)}><Upload aria-hidden="true" size={17} /> {copy.importStatement}</button>
        </div>

        {state.data.connectionsUnavailable ? <p className="finance-setup-inline-error" role="alert"><AlertCircle aria-hidden="true" size={18} /> {copy.bankConnectionsUnavailable}</p> : null}
        {state.data.connections.length ? (
          <div className="finance-connection-list">
            {state.data.connections.map((connection) => {
              const reconnect = connection.status === "EXPIRED" || connection.status === "REAUTH_REQUIRED" || connection.status === "DISCONNECTED";
              const historyOnly = reconnect && !connection.can_manage;
              const canReconnectHere = reconnect && connection.can_manage && connection.provider === "TRUELAYER";
              const canRefreshHere = !reconnect && connection.can_manage;
              return (
                <article key={connection.id} className="finance-connection-card">
                  <header>
                    <span className="finance-account-icon"><Landmark aria-hidden="true" size={18} /></span>
                    <div><h3>{connection.institution}</h3><p>{spaceNames.get(connection.space_id)}</p></div>
                    <span className={cn("finance-connection-status", `is-${connection.status.toLowerCase()}`)}>{historyOnly ? copy.connectionHistoryOnly : copy.connectionStatuses[connection.status]}</span>
                  </header>
                  <p className="finance-connection-detail">{historyOnly ? copy.otherAdultConnectionDetail : reconnect && connection.provider !== "TRUELAYER" ? copy.olderConnectionDetail : copy.connectionStatusDetails[connection.status]}</p>
                  <dl>
                    <div><dt>{copy.readOnlyAccess}</dt><dd>{copy.readOnlyAccessDetail}</dd></div>
                    <div><dt>{copy.lastBankRefresh}</dt><dd>{connection.last_success_at ? formatDateTime(connection.last_success_at, locale) : copy.neverRefreshed}</dd></div>
                  </dl>
                  <div className="finance-connection-actions">
                    {canReconnectHere ? (
                      <button type="button" className="button button--primary" disabled={Boolean(working)} aria-busy={working === `start:${connection.id}`} onClick={() => void startApproval(connection.space_id, connection.id)}>{working === `start:${connection.id}` ? copy.startingBank : connection.status === "DISCONNECTED" ? copy.connectAgain : copy.reconnectBank}</button>
                    ) : canRefreshHere ? (
                      <button type="button" className="button button--secondary" disabled={Boolean(working)} onClick={() => void refreshConnection(connection)}><RefreshCw aria-hidden="true" size={16} /> {working === connection.id ? copy.refreshingBank : copy.refreshBank}</button>
                    ) : null}
                    {connection.can_manage && connection.status !== "DISCONNECTED" ? <button type="button" className="button button--secondary" disabled={Boolean(working)} onClick={() => setPendingDisconnect(connection)}><Unplug aria-hidden="true" size={16} /> {copy.disconnectBank}</button> : null}
                  </div>
                </article>
              );
            })}
          </div>
        ) : !state.data.connectionsUnavailable ? (
          <div className="finance-setup-empty"><Building2 aria-hidden="true" size={28} /><strong>{copy.noConnectionsTitle}</strong><p>{copy.noConnectionsDetail}</p></div>
        ) : null}
      </section>

      <section className="finance-data-section finance-setup-section finance-setup-guided" aria-labelledby="finance-privacy-check-title">
        <header><div><span className="finance-setup-step-number">2</span><h2 id="finance-privacy-check-title">{locale === "de" ? "Kontozuordnung" : "Account ownership"}</h2></div></header>
        <ul className="finance-setup-space-summary">
          {spaces.map((space) => {
            const count = state.data.accounts.filter((account) => account.space_id === space.id).length;
            return <li key={space.id}><div><strong>{space.name}</strong><span>{space.kind === "personal" ? (locale === "de" ? "Privat" : "Private") : (locale === "de" ? "Gemeinsam" : "Household")}</span></div><p>{locale === "de" ? `${count} ${count === 1 ? "Konto" : "Konten"} in diesem Bereich` : `${count} ${count === 1 ? "account" : "accounts"} in this area`}</p></li>;
          })}
        </ul>
        <a href="#finance-account-settings" onClick={() => setOtherWaysOpen(true)}>{locale === "de" ? "Kontozuordnung und Regeln prüfen" : "Review account ownership and rules"}</a>
      </section>

      <section className="finance-data-section finance-setup-section finance-setup-guided finance-first-report" aria-labelledby="finance-first-report-title">
        <header><div><span className="finance-setup-step-number">3</span><h2 id="finance-first-report-title">{setupSpace?.kind === "household" ? (locale === "de" ? "Erster gemeinsamer Überblick" : "Your first household overview") : (locale === "de" ? "Dein erster Überblick" : "Your first overview")}</h2><p>{setupSpace?.kind === "household"
          ? (locale === "de" ? "Sobald ein gemeinsames Konto bereit ist, erstellt HausKlar automatisch einen Überblick, den beide Erwachsenen sehen können. Private Daten bleiben draußen." : "As soon as a household account is ready, HausKlar creates an overview both adults can see. Private data stays out.")
          : (locale === "de" ? "Sobald ein privates Konto bereit ist, erstellt HausKlar automatisch den ersten Überblick. Es bewegt kein Geld und teilt nichts mit dem anderen Erwachsenen." : "As soon as a private account is ready, HausKlar creates the first overview automatically. It cannot move money and shares nothing with the other adult.")}</p></div></header>
        {firstReportState === "waiting" ? <p className="finance-setup-inline-state"><CircleDashed aria-hidden="true" size={18} /> {setupSpace?.kind === "household" ? (locale === "de" ? "Verbinde oder importiere oben zuerst ein gemeinsames Konto." : "Connect or import a household account above first.") : (locale === "de" ? "Verbinde oder importiere oben zuerst ein privates Konto." : "Connect or import a private account above first.")}</p> : null}
        {firstReportState === "checking" ? <div className="finance-first-report-progress" role="status" aria-live="polite"><RefreshCw aria-hidden="true" size={18} /><span>{locale === "de" ? "Überblick wird automatisch erstellt…" : "Creating your overview automatically…"}</span></div> : null}
        {firstReportState === "ready" ? <div className="finance-first-report-ready" role="status"><CheckCircle2 aria-hidden="true" size={20} /><span>{setupSpace?.kind === "household" ? (locale === "de" ? "Der gemeinsame Überblick ist bereit." : "Your household overview is ready.") : (locale === "de" ? "Dein Überblick ist bereit." : "Your overview is ready.")}</span><a className="button button--primary" href="/?view=finance&section=coach">{locale === "de" ? "Überblick öffnen" : "Open overview"}</a></div> : null}
        {firstReportState === "error" ? <div className="finance-setup-inline-error" role="alert"><AlertCircle aria-hidden="true" size={18} /><span>{locale === "de" ? "Der Überblick konnte noch nicht erstellt werden. Deine Kontodaten bleiben unverändert." : "The overview could not be created yet. Your account data is unchanged."}</span><button type="button" className="button button--secondary" onClick={retryFirstReport}>{locale === "de" ? "Erneut versuchen" : "Try again"}</button></div> : null}
      </section>

      <details className="finance-setup-optional">
        <summary><span className="finance-setup-step-number">4</span><span><strong>{locale === "de" ? "Optional: Weiterleitungen und Benachrichtigungen" : "Optional: forwarding and notifications"}</strong><small>{locale === "de" ? "Richte dies jetzt ein oder komme später zurück." : "Set these up now or come back later."}</small></span></summary>
      <section className="finance-data-section finance-setup-section finance-setup-guided" aria-labelledby="finance-notification-choice-title">
        <header><div><h2 id="finance-notification-choice-title">{locale === "de" ? "Wann soll HausKlar dich informieren?" : "When should HausKlar tell you?"}</h2><p>{locale === "de" ? "Gewöhnliche Einkäufe bleiben still. Du kannst dies später ändern." : "Ordinary purchases stay quiet. You can change this later."}</p></div></header>
        <div className="finance-setup-choice-grid">
          {([
            ["ACTION_ONLY", locale === "de" ? "Nur wenn etwas zu tun ist" : "Only when action is needed", locale === "de" ? "Empfohlen" : "Recommended"],
            ["DAILY", locale === "de" ? "Tägliche Zusammenfassung" : "Daily summary", ""],
            ["NEVER", locale === "de" ? "Keine Benachrichtigungen" : "No notifications", ""],
          ] as const).map(([mode, label, badge]) => <button type="button" key={mode} className={cn("finance-setup-choice", preference?.notification_mode === mode && "is-selected")} aria-pressed={preference?.notification_mode === mode} disabled={setupWorking === "notification"} onClick={() => void saveNotificationMode(mode)}><strong>{label}</strong>{badge ? <span>{badge}</span> : null}</button>)}
        </div>
        <a href="/?view=finance&section=settings">{locale === "de" ? "Zeit und Ton genauer einstellen" : "Change the time and tone"}</a>
      </section>

      <section className="finance-data-section finance-setup-section finance-setup-guided" aria-labelledby="finance-forwarding-title">
        <header><div><h2 id="finance-forwarding-title">{setupSpace?.kind === "household" ? (locale === "de" ? "Gemeinsame Belege weiterleiten" : "Forward household receipts") : (locale === "de" ? "Private Belege weiterleiten" : "Forward private receipts")}</h2><p>{setupSpace?.kind === "household"
          ? (locale === "de" ? "Diese gemeinsame Adresse ist nur für Finanzdaten gedacht, die beide Erwachsenen sehen sollen. Private Belege gehören in „Meine Finanzen“." : "Use this household address only for Finance records both adults should see. Private receipts belong in My finances.")
          : (locale === "de" ? "Diese private Adresse landet nur in deinen Finanzen. Nutze gemeinsame Finanzen nur für Belege, die beide Erwachsene sehen sollen." : "This private address goes only to your Finance area. Use Household Finance only for receipts both adults should see.")}</p></div></header>
        {emailUnavailable || (emailState && !emailState.configured) ? <p className="finance-setup-inline-error"><AlertCircle aria-hidden="true" size={18} /> {locale === "de" ? "E-Mail-Weiterleitung ist auf diesem Server noch nicht eingerichtet." : "Email forwarding is not configured on this server yet."}</p> : null}
        {emailState?.addresses.length ? <div className="finance-email-address-list">{emailState.addresses.map((address) => {
          const health = emailHealth[address.id];
          const needsAttention = !address.enabled || Boolean(health?.open_exception_count) || Boolean(health?.health.some((item) => item.health_status !== "HEALTHY")) || Boolean(health?.enrollments.some((item) => item.status === "DISABLED"));
          const ready = !needsAttention && Boolean(health?.enrollments.some((item) => item.status === "ACTIVE"));
          const statusLabel = needsAttention ? (locale === "de" ? "Prüfen" : "Needs attention") : ready ? (locale === "de" ? "Bereit" : "Ready") : (locale === "de" ? "Wartet" : "Waiting");
          return <article key={address.id}>
            <header><div><strong>{address.alias_kind === "PERSONAL" ? (locale === "de" ? "Private Finanzen" : "Private Finance") : (locale === "de" ? "Gemeinsame Finanzen" : "Household Finance")}</strong><code>{address.address}</code></div><span className={ready ? "is-ready" : needsAttention ? "is-attention" : ""}>{statusLabel}</span></header>
            <dl><div><dt>{locale === "de" ? "Letzter Eingang" : "Last received"}</dt><dd>{address.last_received_at ? formatDateTime(address.last_received_at, locale) : (locale === "de" ? "Noch keiner" : "None yet")}</dd></div><div><dt>{locale === "de" ? "Zuletzt gelesen" : "Last parsed"}</dt><dd>{address.last_parsed_at ? formatDateTime(address.last_parsed_at, locale) : (locale === "de" ? "Noch nicht" : "Not yet")}</dd></div><div><dt>{locale === "de" ? "Weiterleitung" : "Forwarding"}</dt><dd>{health?.enrollments.length ? health.enrollments.map((item) => `${item.retailer_domain}: ${item.status === "ACTIVE" ? (locale === "de" ? "bestätigt" : "verified") : item.status === "PENDING" ? (locale === "de" ? "wartet" : "waiting") : (locale === "de" ? "aus" : "off")}`).join(" · ") : (locale === "de" ? "Noch nicht hinzugefügt" : "Not added yet")}</dd></div></dl>
            <div className="finance-email-actions"><button type="button" className="button button--secondary" onClick={() => void copyEmailAddress(address)}>{locale === "de" ? "Adresse kopieren" : "Copy address"}</button><button type="button" className="button button--secondary" disabled={Boolean(setupWorking)} onClick={() => void testEmail(address)}>{locale === "de" ? "Test senden" : "Send test"}</button><button type="button" className="button button--secondary" disabled={Boolean(setupWorking)} onClick={() => void replaceEmail(address)}>{locale === "de" ? "Adresse ersetzen" : "Replace address"}</button></div>
          </article>;
        })}</div> : null}
        {emailState?.configured && !emailState.addresses.some((address) => address.alias_kind === "HOUSEHOLD") ? <button type="button" className="button button--secondary" disabled={Boolean(setupWorking)} onClick={() => void createHouseholdEmail()}>{locale === "de" ? "Gemeinsame Finanzadresse erstellen" : "Create household Finance address"}</button> : null}
        {emailState?.configured ? <details className="finance-forwarding-help"><summary>{locale === "de" ? "Weiterleitung in Gmail oder Outlook einrichten" : "Set up forwarding in Gmail or Outlook"}</summary><h3>Gmail</h3><p>{emailState.gmail_instructions}</p><h3>Outlook</h3><p>{emailState.outlook_instructions}</p><h3>{locale === "de" ? "Händler bestätigen" : "Verify a retailer"}</h3><p>{locale === "de" ? "Füge die Familien-E-Mail hinzu, die weiterleitet, und die Händler-Domain. Die erste korrekt geprüfte Nachricht aktiviert sie." : "Add the family email that forwards the message and the retailer domain. The first verified message activates it."}</p>{emailState.addresses.map((address) => { const draft = enrollmentDrafts[address.id] ?? { forwarder: "", domain: "" }; return <div className="finance-email-enrolment" key={address.id}><strong>{address.alias_kind === "PERSONAL" ? (locale === "de" ? "Private Finanzen" : "Private Finance") : (locale === "de" ? "Gemeinsame Finanzen" : "Household Finance")}</strong><div className="field"><label htmlFor={`finance-forwarder-${address.id}`}>{locale === "de" ? "Weiterleitende E-Mail" : "Forwarding email"}</label><input id={`finance-forwarder-${address.id}`} type="email" value={draft.forwarder} onChange={(event) => setEnrollmentDrafts((current) => ({ ...current, [address.id]: { ...draft, forwarder: event.target.value } }))} /></div><div className="field"><label htmlFor={`finance-domain-${address.id}`}>{locale === "de" ? "Händler-Domain" : "Retailer domain"}</label><input id={`finance-domain-${address.id}`} placeholder="tesco.com" value={draft.domain} onChange={(event) => setEnrollmentDrafts((current) => ({ ...current, [address.id]: { ...draft, domain: event.target.value } }))} /></div><button type="button" className="button button--secondary" disabled={Boolean(setupWorking) || !draft.forwarder.trim() || !draft.domain.trim()} onClick={() => void addEmailEnrollment(address)}>{locale === "de" ? "Weiterleitung hinzufügen" : "Add forwarding"}</button></div>; })}</details> : null}
      </section>
      </details>

      <details className="finance-setup-other-ways" open={otherWaysOpen} onToggle={(event) => setOtherWaysOpen(event.currentTarget.open)}>
        <summary>{locale === "de" ? "Andere Möglichkeiten" : "Other ways"}</summary>
        <p>{locale === "de" ? "Füge ein Konto manuell hinzu oder importiere einen Kontoauszug, wenn du keine Bank verbinden möchtest." : "Add an account manually or import a statement if you do not want to connect a bank."}</p>

      {setupSpace?.kind === "personal" ? <section id="private-finance-files" className="finance-data-section finance-setup-section finance-private-file-setup" aria-labelledby="private-finance-files-title">
        <header><div><h2 id="private-finance-files-title">{locale === "de" ? "Private Finanzdatei" : "Private Finance file"}</h2><p><ShieldCheck aria-hidden="true" size={17} /> {locale === "de" ? "Nur du kannst diese Datei in deinen privaten Finanzen öffnen. Sie wird nicht zu den gemeinsamen Familien-Dokumenten hinzugefügt." : "Only you can open this file in your Private Finance area. It is not added to shared family Documents."}</p></div></header>
        <form className="finance-private-file-form" onSubmit={(event) => void uploadPrivateFile(event)}>
          <div className="field"><label htmlFor="finance-private-file-title">{locale === "de" ? "Titel" : "Title"}</label><input id="finance-private-file-title" value={privateUpload.title} onChange={(event) => setPrivateUpload((current) => ({ ...current, title: event.target.value }))} maxLength={300} /></div>
          <div className="field"><label htmlFor="finance-private-file-input">{locale === "de" ? "PDF, Foto oder Textdatei" : "PDF, photo or text file"}</label><input id="finance-private-file-input" type="file" accept="application/pdf,image/jpeg,image/png,image/heic,image/heif,image/tiff,text/plain" onChange={(event) => setPrivateUpload((current) => ({ ...current, file: event.target.files?.[0] ?? null }))} /></div>
          <button type="submit" className="button button--secondary" disabled={setupWorking === "upload" || !privateUpload.file || !privateUpload.title.trim()}><Upload aria-hidden="true" size={16} /> {setupWorking === "upload" ? (locale === "de" ? "Wird gespeichert…" : "Saving…") : (locale === "de" ? "Privat speichern" : "Save privately")}</button>
        </form>
      </section> : null}

      <section id="finance-account-settings" className="finance-data-section finance-setup-section" aria-labelledby="finance-account-settings-title">
        <header><div><h2 id="finance-account-settings-title">{copy.accountsSetupTitle}</h2><p>{copy.accountsSetupDetail}</p></div><button type="button" className="button button--primary" disabled={state.data.accountsUnavailable} onClick={() => setShowAccountCreate(true)}><Plus aria-hidden="true" size={16} /> {locale === "de" ? "Konto hinzufügen" : "Add account"}</button></header>
        {state.data.accountsUnavailable ? <p className="finance-setup-inline-error" role="alert"><AlertCircle aria-hidden="true" size={18} /> {copy.accountsUnavailable}</p> : null}
        {state.data.accounts.length ? (
          <div className="finance-setup-account-list">
            {state.data.accounts.map((account) => {
              const sourceConnection = state.data.connections.find((connection) => connection.space_id === account.space_id && connection.status !== "DISCONNECTED") ?? null;
              const omitted = account.provider_presence_status === "OMITTED";
              return <article key={account.id}>
                <div className="finance-account-heading"><span className="finance-account-icon"><Landmark aria-hidden="true" size={18} /></span><div><h3>{account.label}</h3><p>{[account.institution, account.last_four ? `${copy.endingIn} ${account.last_four}` : null, account.currency].filter(Boolean).join(" · ")}</p></div></div>
                <div className="finance-setup-account-tags"><span>{copy.accountPurposes[account.purpose]}</span>{account.primary_spending_account ? <span className="is-primary">{copy.primarySpending}</span> : null}{account.account_type === "CREDIT_CARD" && account.card_paid_in_full ? <span className="is-primary">{copy.cardPaidInFull}</span> : null}</div>
                {omitted ? <p className="finance-connection-detail">{locale === "de" ? "Dieses Konto wurde bei der letzten Bankaktualisierung nicht geliefert. Es kann nicht geändert werden, solange es fehlt. Aktualisiere die Bankverbindung oder verbinde sie erneut." : "This account was omitted from the latest bank refresh. It cannot be changed while it is omitted. Refresh or reconnect the bank to restore it."}</p> : null}
                <dl><div><dt>{copy.includeCashflow}</dt><dd>{account.include_in_cashflow ? "✓" : "—"}</dd></div><div><dt>{copy.includeNetWorth}</dt><dd>{account.include_in_net_worth ? "✓" : "—"}</dd></div>{["CURRENT", "SAVINGS", "CASH"].includes(account.account_type) ? <div><dt>{copy.minimumBalance}</dt><dd>{formatCurrency(account.minimum_balance_minor, account.currency, locale)}</dd></div> : null}</dl>
                {omitted ? sourceConnection ? <div className="finance-connection-actions">{["CONNECTED", "PARTIAL", "PROVIDER_DOWN"].includes(sourceConnection.status) ? <button type="button" className="button button--secondary" disabled={Boolean(working)} onClick={() => void refreshConnection(sourceConnection)}><RefreshCw aria-hidden="true" size={16} /> {copy.refreshBank}</button> : null}{sourceConnection.provider === "TRUELAYER" && ["EXPIRED", "REAUTH_REQUIRED", "DISCONNECTED"].includes(sourceConnection.status) ? <button type="button" className="button button--secondary" disabled={Boolean(working)} onClick={() => void startApproval(sourceConnection.space_id, sourceConnection.id)}>{copy.reconnectBank}</button> : null}</div> : <p>{locale === "de" ? "Verbinde die Bank oben erneut." : "Reconnect the bank above."}</p> : <button type="button" className="button button--secondary" onClick={() => setEditingAccount(account)}><Pencil aria-hidden="true" size={16} /> {copy.editAccount}</button>}
              </article>;
            })}
          </div>
        ) : !state.data.accountsUnavailable ? <div className="finance-setup-empty"><CircleDashed aria-hidden="true" size={28} /><strong>{copy.noSetupAccountsTitle}</strong><p>{copy.noSetupAccountsDetail}</p></div> : null}
      </section>

      </details>

      <ConfirmDialog open={pendingDisconnect !== null} onOpenChange={(open) => { if (!open && !working) setPendingDisconnect(null); }} title={copy.disconnectBankTitle} description={copy.disconnectBankDetail} confirmLabel={copy.disconnectBankConfirm} destructive busy={Boolean(pendingDisconnect && working === pendingDisconnect.id)} onConfirm={() => void disconnectConnection()} />
      {showAccountCreate ? <AccountCreateDialog spaces={spaces} accounts={state.data.accounts} locale={locale} onClose={() => setShowAccountCreate(false)} onSaved={addAccount} /> : null}
      {editingAccount ? <AccountEditDialog account={editingAccount} accounts={state.data.accounts} locale={locale} copy={copy} onClose={() => setEditingAccount(null)} onSaved={saveAccount} /> : null}
      {showImport ? <StatementImportDialog accounts={state.data.accounts} spaces={spaces} locale={locale} copy={copy} onClose={() => setShowImport(false)} /> : null}
    </div>
  );
}
