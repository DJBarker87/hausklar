import {
  AlertCircle,
  BarChart3,
  BellRing,
  Building2,
  CalendarDays,
  CheckCircle2,
  ChevronRight,
  CircleDashed,
  ClockAlert,
  ExternalLink,
  Gauge,
  Landmark,
  LockKeyhole,
  MessageCircleMore,
  MoreHorizontal,
  PiggyBank,
  Pencil,
  Plus,
  ReceiptText,
  Search,
  Send,
  Settings2,
  Share2,
  SlidersHorizontal,
  ShieldCheck,
  ShieldX,
  Sparkles,
  Target,
  Trash2,
  WalletCards,
} from "lucide-react";
import { lazy, Suspense, useEffect, useRef, useState, type FormEvent } from "react";

import { api, ApiError, invalidateFinanceRequestCache } from "../api";
import {
  financeLocale,
  getFinanceStrings,
  type FinanceLocale,
  type FinanceStrings,
} from "../financeStrings";
import type {
  FinanceAccount,
  FinanceAIConsent,
  FinanceCoachAnswer,
  FinanceCurrencySummary,
  FinanceCommitment,
  FinanceContributionShareRequest,
  FinanceGoal,
  FinanceLedgerSummary,
  FinanceOverview,
  FinancePurchaseDetail,
  FinancePurchaseEvidence,
  FinancePurchaseException,
  FinancePurchaseSummary,
  FinancePaymentHandling,
  FinanceReserve,
  FinanceShare,
  FinanceSharePreview,
  FinanceSpace,
  FinanceTransaction,
  FamilyMember,
} from "../types";
import { cn, Modal } from "../components/ui";
import { FundingRing, Waterfall, type WaterfallStep } from "../components/FinanceCharts";
import "./finance.css";

const loadFinanceDeliveryCalendarAction = () => import("../components/FinanceDeliveryCalendarAction");
const loadFinanceOverviewView = () => import("./FinanceOverviewView");
const loadFinanceSetupView = () => import("./FinanceSetupView");
const loadFinanceAnalysisView = () => import("./FinanceAnalysisView");
const loadFinancePurchaseReviewView = () => import("./FinancePurchaseReviewView");
const loadFinanceMaterialQuestionsView = () => import("./FinanceMaterialQuestionsView");
const loadFinanceCoachHomeView = () => import("./FinanceCoachHomeView");
const loadFinancePlansView = () => import("./FinancePlansView");
const loadFinanceOutlookView = () => import("./FinanceOutlookView");
const loadFinanceAssetsProductsView = () => import("./FinanceAssetsProductsView");
const loadFinanceCoachingSettingsView = () => import("./FinanceCoachingSettingsView");
const loadFinanceDataControlsView = () => import("./FinanceDataControlsView");
const loadFinanceCapturePanel = () => import("./FinanceCapturePanel");

const FinanceDeliveryCalendarAction = lazy(() => loadFinanceDeliveryCalendarAction().then((module) => ({ default: module.FinanceDeliveryCalendarAction })));
const FinanceSetupView = lazy(() => loadFinanceSetupView().then((module) => ({ default: module.FinanceSetupView })));
const FinanceOverviewView = lazy(() => loadFinanceOverviewView().then((module) => ({ default: module.FinanceOverviewView })));
const FinanceAnalysisView = lazy(() => loadFinanceAnalysisView().then((module) => ({ default: module.FinanceAnalysisView })));
const FinancePurchaseReviewView = lazy(() => loadFinancePurchaseReviewView().then((module) => ({ default: module.FinancePurchaseReviewView })));
const FinanceMaterialQuestionsView = lazy(() => loadFinanceMaterialQuestionsView().then((module) => ({ default: module.FinanceMaterialQuestionsView })));
const FinanceCoachHomeView = lazy(() => loadFinanceCoachHomeView().then((module) => ({ default: module.FinanceCoachHomeView })));
const FinancePlansView = lazy(() => loadFinancePlansView().then((module) => ({ default: module.FinancePlansView })));
const FinanceOutlookView = lazy(() => loadFinanceOutlookView().then((module) => ({ default: module.FinanceOutlookView })));
const FinanceAssetsProductsView = lazy(() => loadFinanceAssetsProductsView().then((module) => ({ default: module.FinanceAssetsProductsView })));
const FinanceCoachingSettingsView = lazy(() => loadFinanceCoachingSettingsView().then((module) => ({ default: module.FinanceCoachingSettingsView })));
const FinanceDataControlsView = lazy(() => loadFinanceDataControlsView().then((module) => ({ default: module.FinanceDataControlsView })));
const FinanceCapturePanel = lazy(() => loadFinanceCapturePanel().then((module) => ({ default: module.FinanceCapturePanel })));
export type FinanceSection = "overview" | "goals" | "activity" | "more" | "planning" | "coach" | "explore" | "assets" | "settings" | "setup";
export type FinanceScope = "mine" | "household";

function preloadFinanceSection(section: FinanceSection): void {
  let request: Promise<unknown> | null = null;
  if (section === "overview") request = loadFinanceOverviewView();
  else if (section === "coach") request = loadFinanceCoachHomeView();
  else if (section === "goals") request = loadFinancePlansView();
  else if (section === "planning") request = loadFinanceOutlookView();
  else if (section === "explore") request = loadFinanceAnalysisView();
  else if (section === "assets") request = loadFinanceAssetsProductsView();
  else if (section === "settings") request = Promise.all([
    loadFinanceCoachingSettingsView(),
    loadFinanceDataControlsView(),
  ]);
  else if (section === "setup") request = loadFinanceSetupView();
  // Review and data-quality tools intentionally wait until their disclosures
  // open so a closed Activity screen performs no hidden analysis.
  if (request) void request.catch(() => undefined);
}

type SpacesLoadState =
  | { status: "idle" }
  | { status: "loading" }
  | { status: "ready"; spaces: FinanceSpace[] }
  | { status: "error" };

type FinanceData = {
  accounts: FinanceAccount[];
  summary: Omit<FinanceLedgerSummary, "space_id">;
  spaceData: FinanceSpaceData[];
  transactions: FinanceTransaction[];
  commitments: FinanceCommitment[];
  reserves: FinanceReserve[];
  goals: FinanceGoal[];
};

type FinanceSpaceData = {
  accounts: FinanceAccount[];
  summary: FinanceLedgerSummary;
  transactions: FinanceTransaction[];
  commitments: FinanceCommitment[];
  reserves: FinanceReserve[];
  goals: FinanceGoal[];
};

type DataLoadState =
  | { status: "idle" }
  | { status: "loading"; selectionKey: string }
  | { status: "ready"; selectionKey: string; data: FinanceData }
  | { status: "error"; selectionKey: string };

type OverviewLoadState =
  | { status: "idle" }
  | { status: "loading"; scope: FinanceScope }
  | { status: "ready"; scope: FinanceScope; data: FinanceOverview }
  | { status: "error"; scope: FinanceScope };

type PurchaseData = {
  accounts: FinanceAccount[];
  transactions: FinanceTransaction[];
  purchases: FinancePurchaseSummary[];
  exceptions: FinancePurchaseException[];
};

type TransactionPageState = {
  nextOffset: number;
  hasMore: boolean;
  ownerAware: string;
};

type PurchaseSpaceData = PurchaseData & {
  transactionPage: TransactionPageState;
  purchasePage: TransactionPageState;
  spaceID: string;
};

type PurchaseLoadState =
  | { status: "idle" }
  | { status: "loading"; selectionKey: string }
  | {
      status: "ready";
      selectionKey: string;
      data: PurchaseData;
      transactionPages: Record<string, TransactionPageState>;
      purchasePages: Record<string, TransactionPageState>;
      loadingOlder: boolean;
      olderError: boolean;
      loadingOlderPurchases: boolean;
      olderPurchasesError: boolean;
    }
  | { status: "error"; selectionKey: string };

type ConsentLoadState =
  | { status: "idle" }
  | { status: "loading" }
  | { status: "ready"; consents: FinanceAIConsent[] }
  | { status: "error" };

type CoachAnswerState =
  | { status: "idle" }
  | { status: "sending" }
  | { status: "ready"; answer: FinanceCoachAnswer }
  | { status: "error"; kind: "consent" | "unavailable" | "request" };

type CoachExchange = { question: string; answer: FinanceCoachAnswer };

type CurrencyBalance = {
  currency: string;
  bookedMinor: number | null;
  availableMinor: number | null;
  summary: FinanceCurrencySummary | null;
};

const RECENT_TRANSACTION_LIMIT = 12;

const sections: Array<{ id: FinanceSection; icon: typeof MessageCircleMore }> = [
  { id: "overview", icon: Gauge },
  { id: "goals", icon: Target },
  { id: "activity", icon: ReceiptText },
];

const moreSections: Array<{ id: FinanceSection; icon: typeof MessageCircleMore }> = [
  { id: "planning", icon: CalendarDays },
  { id: "coach", icon: MessageCircleMore },
  { id: "explore", icon: BarChart3 },
  { id: "assets", icon: WalletCards },
  { id: "settings", icon: SlidersHorizontal },
  { id: "setup", icon: Settings2 },
];

function storedFinanceChoice(key: string) {
  try {
    return window.localStorage.getItem(key);
  } catch {
    return null;
  }
}

function rememberFinanceChoice(key: string, value: string) {
  try {
    window.localStorage.setItem(key, value);
  } catch {
    // Private browsing or a locked-down browser can disable local storage.
  }
}

function selectedFinanceSpaces(spaces: FinanceSpace[], scope: FinanceScope) {
  const household = spaces.find((space) => space.kind === "household") ?? null;
  if (scope === "household") return household ? [household] : [];
  const personal = spaces.find((space) => space.kind === "personal" && space.is_default)
    ?? spaces.find((space) => space.kind === "personal")
    ?? null;
  return [personal, household].filter((space): space is FinanceSpace => space !== null);
}

function isAbortError(error: unknown) {
  return error instanceof DOMException && error.name === "AbortError";
}

function formatCurrency(
  minor: number,
  currency: string,
  locale: FinanceLocale,
  signed = false,
) {
  return new Intl.NumberFormat(locale === "de" ? "de-DE" : "en-GB", {
    style: "currency",
    currency,
    currencyDisplay: "symbol",
    signDisplay: signed ? "exceptZero" : "auto",
  }).format(minor / 100);
}

function formatDate(value: string, locale: FinanceLocale) {
  const parsed = new Date(`${value}T00:00:00`);
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

function financeSourceLabel(sourceKind: string, locale: FinanceLocale) {
  const labels: Record<string, [string, string]> = {
    tesco_batch: ["Tesco order", "Tesco-Bestellung"],
    resend_email: ["Retailer email", "Händler-E-Mail"],
    email: ["Retailer email", "Händler-E-Mail"],
    upload_image: ["Receipt upload", "Beleg-Upload"],
    upload_pdf: ["Receipt upload", "Beleg-Upload"],
    document: ["Receipt upload", "Beleg-Upload"],
    csv: ["Bank statement", "Kontoauszug"],
    ofx: ["Bank statement", "Kontoauszug"],
    provider: ["Connected bank", "Verbundene Bank"],
    manual: ["Manual entry", "Manueller Eintrag"],
    shared_copy: ["Shared Household copy", "Geteilte Haushaltskopie"],
  };
  return labels[sourceKind.toLowerCase()]?.[locale === "de" ? 1 : 0]
    ?? (locale === "de" ? "Gespeicherte Finanzquelle" : "Saved Finance source");
}

function oldestTimestamp(values: Array<string | null>) {
  return values.filter((value): value is string => Boolean(value)).reduce<string | null>(
    (oldest, value) => {
      if (!oldest) return value;
      const timestamp = Date.parse(value);
      const oldestValue = Date.parse(oldest);
      if (Number.isNaN(timestamp)) return oldest;
      if (Number.isNaN(oldestValue)) return value;
      return timestamp < oldestValue ? value : oldest;
    },
    null,
  );
}

function mergeFinanceSpaceData(results: FinanceSpaceData[]): FinanceData {
  const accounts = new Map<string, FinanceAccount>();
  const transactions = new Map<string, FinanceTransaction>();
  const commitments = new Map<string, FinanceCommitment>();
  const reserves = new Map<string, FinanceReserve>();
  const goals = new Map<string, FinanceGoal>();
  const currencies = new Map<string, FinanceCurrencySummary>();
  for (const result of results) {
    for (const account of result.accounts) {
      if (!accounts.has(account.id)) accounts.set(account.id, account);
    }
    for (const transaction of result.transactions) {
      if (!transactions.has(transaction.id)) transactions.set(transaction.id, transaction);
    }
    for (const commitment of result.commitments) {
      if (!commitments.has(commitment.id)) commitments.set(commitment.id, commitment);
    }
    for (const reserve of result.reserves) {
      if (!reserves.has(reserve.id)) reserves.set(reserve.id, reserve);
    }
    for (const goal of result.goals) {
      if (!goals.has(goal.id)) goals.set(goal.id, goal);
    }
    for (const summary of result.summary.currencies) {
      const current = currencies.get(summary.currency);
      currencies.set(summary.currency, current ? {
        currency: summary.currency,
        account_movement_minor: current.account_movement_minor + summary.account_movement_minor,
        income_minor: current.income_minor + summary.income_minor,
        gross_spending_minor: current.gross_spending_minor + summary.gross_spending_minor,
        refunds_minor: current.refunds_minor + summary.refunds_minor,
        reimbursements_minor: current.reimbursements_minor + summary.reimbursements_minor,
        fees_minor: current.fees_minor + summary.fees_minor,
        net_household_cost_minor:
          current.net_household_cost_minor + summary.net_household_cost_minor,
      } : { ...summary });
    }
  }
  return {
    accounts: [...accounts.values()].sort(
      (left, right) => left.label.localeCompare(right.label) || left.id.localeCompare(right.id),
    ),
    summary: {
      data_through_at: oldestTimestamp(results.map((result) => result.summary.data_through_at)),
      currencies: [...currencies.values()].sort(
        (left, right) => left.currency.localeCompare(right.currency),
      ),
    },
    spaceData: results,
    transactions: [...transactions.values()].sort(
      (left, right) => right.canonical_date.localeCompare(left.canonical_date)
        || left.id.localeCompare(right.id),
    ),
    commitments: [...commitments.values()].sort((left, right) => {
      const leftDate = left.next_due_date ?? left.reviewed_dates[0] ?? "9999-12-31";
      const rightDate = right.next_due_date ?? right.reviewed_dates[0] ?? "9999-12-31";
      return leftDate.localeCompare(rightDate)
        || left.name.localeCompare(right.name)
        || left.id.localeCompare(right.id);
    }),
    reserves: [...reserves.values()].sort(
      (left, right) => left.name.localeCompare(right.name) || left.id.localeCompare(right.id),
    ),
    goals: [...goals.values()].sort(
      (left, right) => left.deadline.localeCompare(right.deadline)
        || left.name.localeCompare(right.name)
        || left.id.localeCompare(right.id),
    ),
  };
}

function mergePurchaseData(results: PurchaseData[]): PurchaseData {
  const accounts = new Map<string, FinanceAccount>();
  const transactions = new Map<string, FinanceTransaction>();
  const purchases = new Map<string, FinancePurchaseSummary>();
  const exceptions = new Map<string, FinancePurchaseException>();
  for (const result of results) {
    for (const account of result.accounts) {
      if (!accounts.has(account.id)) accounts.set(account.id, account);
    }
    for (const transaction of result.transactions) {
      if (!transactions.has(transaction.id)) transactions.set(transaction.id, transaction);
    }
    for (const purchase of result.purchases) {
      if (!purchases.has(purchase.id)) purchases.set(purchase.id, purchase);
    }
    for (const exception of result.exceptions) {
      if (!exceptions.has(exception.id)) exceptions.set(exception.id, exception);
    }
  }
  return {
    accounts: [...accounts.values()].sort((left, right) => left.label.localeCompare(right.label)),
    transactions: [...transactions.values()].sort(
      (left, right) => right.canonical_date.localeCompare(left.canonical_date)
        || left.id.localeCompare(right.id),
    ),
    purchases: [...purchases.values()].sort(
      (left, right) => right.purchased_on.localeCompare(left.purchased_on)
        || right.created_at.localeCompare(left.created_at)
        || left.id.localeCompare(right.id),
    ),
    exceptions: [...exceptions.values()].sort(
      (left, right) => right.priority - left.priority
        || right.created_at.localeCompare(left.created_at)
        || left.id.localeCompare(right.id),
    ),
  };
}

function currencyBalances(data: FinanceData, spaceID: string): CurrencyBalance[] {
  const accountsForSpace = data.accounts.filter((account) => account.space_id === spaceID);
  const spaceSummary = data.spaceData.find((item) => item.summary.space_id === spaceID)?.summary ?? null;
  const currencies = new Set([
    ...(spaceSummary?.currencies ?? []).map((summary) => summary.currency),
    ...accountsForSpace.map((account) => account.currency),
  ]);
  return [...currencies].sort().map((currency) => {
    const accounts = accountsForSpace.filter((account) => account.currency === currency);
    const booked = accounts.flatMap((account) => (
      account.balance ? [account.balance.booked_minor] : []
    ));
    const available = accounts.flatMap((account) => (
      account.balance?.available_minor == null ? [] : [account.balance.available_minor]
    ));
    return {
      currency,
      bookedMinor: booked.length ? booked.reduce((total, amount) => total + amount, 0) : null,
      availableMinor: available.length
        ? available.reduce((total, amount) => total + amount, 0)
        : null,
      summary: spaceSummary?.currencies.find((summary) => summary.currency === currency) ?? null,
    };
  });
}

function EmptyPanel({
  icon: Icon,
  title,
  detail,
}: {
  icon: typeof CircleDashed;
  title: string;
  detail: string;
}) {
  return (
    <div className="finance-empty-panel">
      <Icon aria-hidden="true" size={34} />
      <h2>{title}</h2>
      <p>{detail}</p>
    </div>
  );
}

type ShareableRecordKind = "accounts" | "transactions" | "commitments" | "goals";

function FinanceShareButton({ kind, recordID, space, locale }: { kind: ShareableRecordKind; recordID: string; space: FinanceSpace | null; locale: FinanceLocale }) {
  const [state, setState] = useState<"idle" | "previewing" | "sharing" | "shared" | "error">("idle");
  const [preview, setPreview] = useState<FinanceSharePreview | null>(null);
  if (space?.kind !== "personal") return null;
  const shareLabel = locale === "de" ? "Mit Haushalt teilen" : "Share with Household";
  const sharedLabel = locale === "de" ? "Mit Haushalt geteilt" : "Shared with Household";
  const errorLabel = locale === "de" ? "Konnte nicht geteilt werden" : "Could not share";
  const previewLabel = locale === "de" ? "Freigabe prüfen" : "Review sharing";
  const confirmLabel = locale === "de" ? "Jetzt teilen" : "Share now";
  const cancelLabel = locale === "de" ? "Abbrechen" : "Cancel";
  const onceLabel = locale === "de" ? "Einmal geteilt" : "Shared once";
  const automaticLabel = locale === "de" ? "Wird automatisch aktualisiert" : "Updates automatically";
  const detail = locale === "de"
    ? kind === "accounts" ? "Teilt Kontoverlauf und künftige Kontostände; jederzeit stoppbar." : kind === "transactions" ? "Teilt nur Betrag, Datum und Beschreibung – keine Belegartikel." : "Kopiert diesen Eintrag einmalig in den Haushalt."
    : kind === "accounts" ? "Shares account history and future balance updates; you can stop later." : kind === "transactions" ? "Shares amount, date and description only — never receipt items." : "Copies this record to Household once.";

  async function loadPreview() {
    if (state !== "idle" && state !== "error") return;
    setState("previewing");
    try {
      const kindByPath = { accounts: "ACCOUNT", transactions: "TRANSACTION", commitments: "COMMITMENT", goals: "GOAL" } as const;
      const loaded = await api<FinanceSharePreview>("/finance/shares/preview", { method: "POST", body: JSON.stringify({ kind: kindByPath[kind], source_record_id: recordID }) }, true, false);
      setPreview(loaded);
      setState("idle");
    } catch {
      setState("error");
    }
  }

  async function share() {
    if (state === "sharing" || state === "shared") return;
    setState("sharing");
    try {
      const saved = await api<FinanceShare>(`/finance/shares/${kind}/${encodeURIComponent(recordID)}`, { method: "POST" }, true, false);
      if (saved.status === "STOPPED") throw new Error(errorLabel);
      setState("shared");
      setPreview(null);
    } catch {
      setState("error");
    }
  }

  return <div className="finance-share-action"><button type="button" className="button button--secondary" disabled={state === "previewing" || state === "sharing" || state === "shared"} onClick={() => void loadPreview()}><Share2 aria-hidden="true" size={15} /> {state === "previewing" ? `${previewLabel}…` : state === "sharing" ? `${shareLabel}…` : state === "shared" ? sharedLabel : shareLabel}</button><small>{detail}</small>{preview ? <div className="finance-share-preview" role="dialog" aria-label={previewLabel}><strong>{preview.label}</strong><span>{preview.sharing_mode === "AUTOMATIC" ? automaticLabel : onceLabel}</span>{preview.included.length ? <ul>{preview.included.map((item) => <li key={item}>{item}</li>)}</ul> : null}<div><button type="button" className="button button--primary" disabled={state === "sharing"} onClick={() => void share()}>{confirmLabel}</button><button type="button" className="button button--secondary" disabled={state === "sharing"} onClick={() => setPreview(null)}>{cancelLabel}</button></div></div> : null}{state === "error" ? <small role="alert">{errorLabel}</small> : null}</div>;
}

function FinanceSharingPanel({ data, spaces, locale }: { data: FinanceData; spaces: FinanceSpace[]; locale: FinanceLocale }) {
  const personal = spaces.find((space) => space.kind === "personal") ?? null;
  const household = spaces.find((space) => space.kind === "household") ?? null;
  const currencies = [...new Set(data.accounts.filter((account) => account.space_id === personal?.id).map((account) => account.currency))].sort();
  const [shares, setShares] = useState<FinanceShare[]>([]);
  const [loading, setLoading] = useState(true);
  const [working, setWorking] = useState("");
  const [notice, setNotice] = useState("");
  const [error, setError] = useState("");
  const [pending, setPending] = useState<"contribution" | "rule" | null>(null);
  const [contribution, setContribution] = useState({ amount: "", currency: currencies[0] ?? "", date: "" });
  const [rule, setRule] = useState({ target: "TRANSACTION" as "TRANSACTION" | "PURCHASE", merchant: "" });
  const text = locale === "de" ? {
    title: "Gezielt mit dem Haushalt teilen", detail: "Private Finanzen bleiben getrennt. Prüfe vor jeder Freigabe genau, was der Haushalt sehen wird.", contribution: "Haushaltsbeitrag erklären", rule: "Künftige Händlerregel", ruleDetail: "Neue passende Einträge künftig automatisch teilen.", amount: "Betrag", currency: "Währung", date: "Datum", target: "Eintragstyp", transaction: "Umsatz", purchase: "Einkauf", merchant: "Händler", preview: "Vorschau", confirmOnce: "Einmal teilen", confirmAutomatic: "Automatische Freigabe bestätigen", cancel: "Abbrechen", history: "Freigabeverlauf", current: "Aktuell", past: "Vergangen", once: "Einmal geteilt", automatic: "Wird automatisch aktualisiert", included: "Enthalten", stopped: "Gestoppt", stop: "Künftige Freigabe stoppen", stale: "Die geteilte Kopie ist älter als der private Eintrag.", replace: "Geteilte Version ersetzen", none: "Noch nichts geteilt.", saved: "Freigabe gespeichert.", error: "Die Freigabe konnte nicht geändert werden.",
  } : {
    title: "Share deliberately with Household", detail: "Private finances stay separate. Check exactly what Household will see before every share.", contribution: "Declare a Household contribution", rule: "Future merchant rule", ruleDetail: "Automatically share new matching records in future.", amount: "Amount", currency: "Currency", date: "Date", target: "Record type", transaction: "Transaction", purchase: "Purchase", merchant: "Merchant", preview: "Preview", confirmOnce: "Share once", confirmAutomatic: "Confirm automatic sharing", cancel: "Cancel", history: "Sharing history", current: "Current", past: "Past", once: "Shared once", automatic: "Updates automatically", included: "Included", stopped: "Stopped", stop: "Stop future sharing", stale: "The shared copy is older than the private record.", replace: "Replace shared version", none: "Nothing has been shared yet.", saved: "Sharing saved.", error: "Sharing could not be changed.",
  };

  useEffect(() => {
    if (!personal || !household) { setLoading(false); return; }
    const controller = new AbortController();
    let active = true;
    setLoading(true);
    api<FinanceShare[]>("/finance/shares", { signal: controller.signal }, true, false)
      .then((loaded) => { if (active) setShares(loaded); })
      .catch((caught: unknown) => { if (active && !isAbortError(caught)) setError(text.error); })
      .finally(() => { if (active) setLoading(false); });
    return () => { active = false; controller.abort(); };
  }, [personal?.id, household?.id]);

  if (!personal || !household) return <section className="finance-sharing-panel"><h2>{text.title}</h2><p>{locale === "de" ? "Wähle Persönlich, um private Einträge mit dem Haushalt zu teilen." : "Choose My finances to share private records with Household."}</p></section>;

  async function saveContribution(event: FormEvent) {
    event.preventDefault();
    if (working || !contribution.date || !contribution.currency) return;
    let amountMinor: number;
    try { amountMinor = financeDecimalToMinor(contribution.amount); if (amountMinor <= 0) throw new Error(); }
    catch { setError(text.error); return; }
    if (pending !== "contribution") { setPending("contribution"); setError(""); return; }
    setWorking("contribution"); setError(""); setNotice("");
    try {
      const saved = await api<FinanceShare>("/finance/shares/contributions", { method: "POST", body: JSON.stringify({ id: crypto.randomUUID(), amount_minor: amountMinor, currency: contribution.currency, contribution_date: contribution.date } satisfies FinanceContributionShareRequest) }, true, false);
      setShares((current) => [saved, ...current]); setContribution({ amount: "", currency: contribution.currency, date: "" }); setPending(null); setNotice(text.saved);
    } catch { setError(text.error); }
    finally { setWorking(""); }
  }

  async function saveRule(event: FormEvent) {
    event.preventDefault();
    if (working || !rule.merchant.trim()) return;
    if (pending !== "rule") { setPending("rule"); setError(""); return; }
    setWorking("rule"); setError(""); setNotice("");
    try {
      const saved = await api<FinanceShare>("/finance/share-rules", { method: "POST", body: JSON.stringify({ target: rule.target, merchant: rule.merchant.trim() }) }, true, false);
      setShares((current) => [saved, ...current]); setRule((current) => ({ ...current, merchant: "" })); setPending(null); setNotice(text.saved);
    } catch { setError(text.error); }
    finally { setWorking(""); }
  }

  async function stopShare(share: FinanceShare) {
    if (working) return;
    setWorking(share.id); setError(""); setNotice("");
    try {
      const stopped = await api<FinanceShare>(`/finance/shares/${encodeURIComponent(share.id)}/stop`, { method: "POST" }, true, false);
      setShares((current) => current.map((item) => item.id === stopped.id ? stopped : item)); setNotice(text.saved);
    } catch { setError(text.error); }
    finally { setWorking(""); }
  }

  async function replaceShare(share: FinanceShare) {
    if (working) return;
    setWorking(share.id); setError(""); setNotice("");
    try {
      const replacement = await api<FinanceShare>(`/finance/shares/${encodeURIComponent(share.id)}/replace`, { method: "POST" }, true, false);
      setShares((current) => current.map((item) => item.id === share.id ? replacement : item)); setNotice(text.saved);
    } catch { setError(text.error); }
    finally { setWorking(""); }
  }

  function shareList(items: FinanceShare[]) {
    if (!items.length) return <p>{text.none}</p>;
    return <ul>{items.map((share) => <li key={`${share.id}-${share.version_state}`} className={cn(share.stale && "is-stale")}><div><strong>{share.label || (share.kind === "RULE" ? `${text.rule}: ${share.rule_match_value ?? text.merchant}` : share.kind)}</strong><span>{share.sharing_mode === "AUTOMATIC" ? text.automatic : text.once}{share.status === "STOPPED" ? ` · ${text.stopped}` : ""}</span>{share.included.length ? <small>{text.included}: {share.included.join(", ")}</small> : null}<small>{formatDateTime(share.created_at, locale)}</small>{share.stale ? <p className="finance-share-stale"><ClockAlert aria-hidden="true" size={16} /> {text.stale}</p> : null}</div><div>{share.stale && share.version_state === "CURRENT" ? <button type="button" className="button button--primary" disabled={Boolean(working)} onClick={() => void replaceShare(share)}>{text.replace}</button> : null}{share.status === "ACTIVE" && share.sharing_mode === "AUTOMATIC" ? <button type="button" className="button button--secondary" disabled={Boolean(working)} onClick={() => void stopShare(share)}>{text.stop}</button> : null}</div></li>)}</ul>;
  }

  const current = shares.filter((share) => share.version_state === "CURRENT" && share.status !== "STOPPED");
  const past = shares.filter((share) => share.version_state === "PAST" || share.status === "STOPPED");
  return <section className="finance-sharing-panel" aria-labelledby="finance-sharing-title"><header><div><span className="finance-status-label"><Share2 aria-hidden="true" size={15} /> {text.title}</span><h2 id="finance-sharing-title">{text.title}</h2><p>{text.detail}</p></div></header>{notice ? <p className="form-success" role="status" aria-live="polite">{notice}</p> : null}{error ? <p className="form-error" role="alert">{error}</p> : null}<div className="finance-sharing-forms"><form onSubmit={(event) => void saveContribution(event)}><h3>{text.contribution}</h3><div className="field"><label htmlFor="finance-share-amount-new">{text.amount}</label><input id="finance-share-amount-new" inputMode="decimal" value={contribution.amount} onChange={(event) => { setPending(null); setContribution({ ...contribution, amount: event.target.value }); }} required /></div><div className="field"><label htmlFor="finance-share-currency-new">{text.currency}</label><select id="finance-share-currency-new" value={contribution.currency} onChange={(event) => { setPending(null); setContribution({ ...contribution, currency: event.target.value }); }}>{currencies.map((currency) => <option value={currency} key={currency}>{currency}</option>)}</select></div><div className="field"><label htmlFor="finance-share-date-new">{text.date}</label><input id="finance-share-date-new" type="date" value={contribution.date} onChange={(event) => { setPending(null); setContribution({ ...contribution, date: event.target.value }); }} required /></div>{pending === "contribution" ? <div className="finance-share-preview" role="status"><strong>{text.preview}</strong><p>{formatCurrency(financeDecimalToMinor(contribution.amount), contribution.currency, locale)} · {formatDate(contribution.date, locale)}</p><span>{text.once}</span></div> : null}<div className="finance-share-form-actions"><button type="submit" className="button button--primary" disabled={Boolean(working) || !currencies.length}>{pending === "contribution" ? text.confirmOnce : text.preview}</button>{pending === "contribution" ? <button type="button" className="button button--secondary" onClick={() => setPending(null)}>{text.cancel}</button> : null}</div></form><form onSubmit={(event) => void saveRule(event)}><h3>{text.rule}</h3><p>{text.ruleDetail}</p><div className="field"><label htmlFor="finance-share-target-new">{text.target}</label><select id="finance-share-target-new" value={rule.target} onChange={(event) => { setPending(null); setRule({ ...rule, target: event.target.value as typeof rule.target }); }}><option value="TRANSACTION">{text.transaction}</option><option value="PURCHASE">{text.purchase}</option></select></div><div className="field"><label htmlFor="finance-share-merchant-new">{text.merchant}</label><input id="finance-share-merchant-new" value={rule.merchant} onChange={(event) => { setPending(null); setRule({ ...rule, merchant: event.target.value }); }} required /></div>{pending === "rule" ? <div className="finance-share-preview" role="status"><strong>{text.preview}</strong><p>{rule.target === "PURCHASE" ? text.purchase : text.transaction} · {rule.merchant}</p><span>{text.automatic}</span></div> : null}<div className="finance-share-form-actions"><button type="submit" className="button button--primary" disabled={Boolean(working) || !rule.merchant.trim()}>{pending === "rule" ? text.confirmAutomatic : text.preview}</button>{pending === "rule" ? <button type="button" className="button button--secondary" onClick={() => setPending(null)}>{text.cancel}</button> : null}</div></form></div><section className="finance-sharing-history" aria-labelledby="finance-sharing-history-title"><h3 id="finance-sharing-history-title">{text.history}</h3>{loading ? <div className="finance-data-skeleton" aria-busy="true"><div /><div /></div> : <><h4>{text.current}</h4>{shareList(current)}{past.length ? <details><summary>{text.past} ({past.length})</summary>{shareList(past)}</details> : null}</>}</section></section>;
}

type PlanningKind = "commitment" | "reserve" | "goal";
type PlanningField = "name" | "amount" | "allocated" | "date" | "destination";

export function financeDecimalToMinor(value: string): number {
  const match = /^(\d+)(?:[.,](\d{1,2}))?$/.exec(value.trim());
  if (!match) throw new Error("invalid amount");
  const minor = BigInt(match[1]) * 100n + BigInt((match[2] ?? "").padEnd(2, "0") || "0");
  if (minor > BigInt(Number.MAX_SAFE_INTEGER)) throw new Error("amount too large");
  return Number(minor);
}

function defaultPlanningSpace(spaces: FinanceSpace[], scope: FinanceScope) {
  if (scope === "household") {
    return spaces.find((space) => space.kind === "household")?.id ?? "";
  }
  return spaces.find((space) => space.kind === "personal")?.id
    ?? spaces.find((space) => space.kind === "household")?.id
    ?? "";
}

function PlanningCreateDialog({
  kind,
  spaces,
  members,
  currencies,
  scope,
  locale,
  copy,
  onClose,
  onCreated,
}: {
  kind: PlanningKind;
  spaces: FinanceSpace[];
  members: FamilyMember[];
  currencies: string[];
  scope: FinanceScope;
  locale: FinanceLocale;
  copy: FinanceStrings;
  onClose: () => void;
  onCreated: (kind: PlanningKind) => void;
}) {
  const initialDestination = defaultPlanningSpace(spaces, scope);
  const [name, setName] = useState("");
  const [amount, setAmount] = useState("");
  const [allocated, setAllocated] = useState("");
  const [currency, setCurrency] = useState(currencies[0] ?? "");
  const [date, setDate] = useState("");
  const [destination, setDestination] = useState(initialDestination);
  const [paymentHandling, setPaymentHandling] = useState<Exclude<FinancePaymentHandling, "UNSPECIFIED">>("AUTOMATIC");
  const [showInCalendar, setShowInCalendar] = useState(kind === "commitment" && spaces.find((space) => space.id === initialDestination)?.kind === "household");
  const [responsibleUserID, setResponsibleUserID] = useState("");
  const [showInTasks, setShowInTasks] = useState(false);
  const [errors, setErrors] = useState<Partial<Record<PlanningField, string>>>({});
  const [requestError, setRequestError] = useState("");
  const [saving, setSaving] = useState(false);
  const nameRef = useRef<HTMLInputElement>(null);
  const amountRef = useRef<HTMLInputElement>(null);
  const allocatedRef = useRef<HTMLInputElement>(null);
  const dateRef = useRef<HTMLInputElement>(null);
  const destinationRef = useRef<HTMLSelectElement>(null);
  const needsDate = kind !== "reserve";
  const householdCommitment = kind === "commitment" && spaces.find((space) => space.id === destination)?.kind === "household";
  const adults = members.filter((member) => member.member_type === "user");

  function focusError(field: PlanningField) {
    const fields = {
      name: nameRef,
      amount: amountRef,
      allocated: allocatedRef,
      date: dateRef,
      destination: destinationRef,
    };
    fields[field].current?.focus();
  }

  async function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (saving) return;
    const nextErrors: Partial<Record<PlanningField, string>> = {};
    let amountMinor = 0;
    let allocatedMinor = 0;
    if (!name.trim()) nextErrors.name = copy.nameRequired;
    try {
      amountMinor = financeDecimalToMinor(amount);
      if (kind === "goal" && amountMinor === 0) {
        nextErrors.amount = copy.positiveAmountRequired;
      }
    } catch {
      nextErrors.amount = copy.amountRequired;
    }
    if (allocated.trim()) {
      try {
        allocatedMinor = financeDecimalToMinor(allocated);
      } catch {
        nextErrors.allocated = copy.allocatedInvalid;
      }
    }
    if (needsDate && !date) nextErrors.date = copy.dateRequired;
    if (!spaces.some((space) => space.id === destination)) {
      nextErrors.destination = copy.destinationRequired;
    }
    setErrors(nextErrors);
    setRequestError("");
    const firstError = (["name", "amount", "allocated", "date", "destination"] as PlanningField[])
      .find((field) => nextErrors[field]);
    if (firstError) {
      focusError(firstError);
      return;
    }

    const body = kind === "commitment" ? {
      name: name.trim(),
      amount_mode: "EXACT",
      exact_minor: amountMinor,
      currency,
      recurrence: "ONE_OFF",
      reviewed_dates: [date],
      priority: "IMPORTANT",
      funding_account_id: null,
      already_reserved_minor: allocatedMinor,
      status: "ACTIVE",
      payment_handling: householdCommitment ? paymentHandling : "UNSPECIFIED",
      show_in_calendar: householdCommitment && showInCalendar,
      show_in_tasks: householdCommitment && showInTasks,
      responsible_user_id: householdCommitment && showInTasks ? responsibleUserID : null,
      notes: null,
    } : kind === "reserve" ? {
      name: name.trim(),
      allocated_minor: allocatedMinor,
      target_minor: amountMinor,
      currency,
      linked_account_id: null,
      status: "ACTIVE",
    } : {
      name: name.trim(),
      target_minor: amountMinor,
      deadline: date,
      currently_allocated_minor: allocatedMinor,
      currency,
      priority: "IMPORTANT",
      allowed_funding_sources: [],
      emergency_buffer_minor: 0,
      status: "ACTIVE",
      notes: null,
    };
    const endpoint = kind === "commitment" ? "commitments" : kind === "reserve" ? "reserves" : "goals";
    setSaving(true);
    try {
      await api(
        `/finance/${endpoint}?space_id=${encodeURIComponent(destination)}`,
        { method: "POST", body: JSON.stringify(body) },
        true,
        false,
      );
      onCreated(kind);
    } catch (error) {
      setRequestError(error instanceof Error && error.message ? error.message : copy.createError);
      setSaving(false);
    }
  }

  const idPrefix = `finance-${kind}`;
  return (
    <Modal
      open
      onOpenChange={(open) => { if (!open && !saving) onClose(); }}
      title={copy.createTitles[kind]}
      description={copy.createDescriptions[kind]}
    >
      <form className="form-stack finance-planning-form" onSubmit={submit} aria-busy={saving}>
        {requestError ? <div className="form-error" role="alert">{requestError}</div> : null}
        <div className="field">
          <label htmlFor={`${idPrefix}-name`}>{copy.nameLabel}</label>
          <input
            ref={nameRef}
            id={`${idPrefix}-name`}
            value={name}
            onChange={(event) => setName(event.target.value)}
            autoComplete="off"
            autoFocus
            required
            aria-invalid={Boolean(errors.name)}
            aria-describedby={errors.name ? `${idPrefix}-name-error` : undefined}
          />
          {errors.name ? <span className="finance-field-error" id={`${idPrefix}-name-error`}>{errors.name}</span> : null}
        </div>
        <div className="form-grid">
          <div className="field">
            <label htmlFor={`${idPrefix}-amount`}>
              {kind === "commitment" ? copy.amountLabel : copy.targetAmount}
            </label>
            <input
              ref={amountRef}
              id={`${idPrefix}-amount`}
              type="text"
              inputMode="decimal"
              value={amount}
              onChange={(event) => setAmount(event.target.value)}
              placeholder="0.00"
              autoComplete="off"
              required
              aria-invalid={Boolean(errors.amount)}
              aria-describedby={errors.amount ? `${idPrefix}-amount-error` : undefined}
            />
            {errors.amount ? <span className="finance-field-error" id={`${idPrefix}-amount-error`}>{errors.amount}</span> : null}
          </div>
          <div className="field">
            <label htmlFor={`${idPrefix}-allocated`}>
              {kind === "commitment" ? copy.reservedLabel : copy.allocated}
            </label>
            <input
              ref={allocatedRef}
              id={`${idPrefix}-allocated`}
              type="text"
              inputMode="decimal"
              value={allocated}
              onChange={(event) => setAllocated(event.target.value)}
              placeholder="0.00"
              autoComplete="off"
              aria-invalid={Boolean(errors.allocated)}
              aria-describedby={errors.allocated ? `${idPrefix}-allocated-error` : undefined}
            />
            {errors.allocated ? <span className="finance-field-error" id={`${idPrefix}-allocated-error`}>{errors.allocated}</span> : null}
          </div>
        </div>
        <div className="form-grid">
          <div className="field">
            <label htmlFor={`${idPrefix}-currency`}>{copy.currencyLabel}</label>
            <select
              id={`${idPrefix}-currency`}
              value={currency}
              onChange={(event) => setCurrency(event.target.value)}
            >
              {currencies.map((currencyCode) => <option value={currencyCode} key={currencyCode}>{currencyCode}</option>)}
            </select>
          </div>
          {needsDate ? (
            <div className="field">
              <label htmlFor={`${idPrefix}-date`}>
                {kind === "commitment" ? copy.dueDateLabel : copy.deadlineLabel}
              </label>
              <input
                ref={dateRef}
                id={`${idPrefix}-date`}
                type="date"
                value={date}
                onChange={(event) => setDate(event.target.value)}
                required
                aria-invalid={Boolean(errors.date)}
                aria-describedby={errors.date ? `${idPrefix}-date-error` : undefined}
              />
              {errors.date ? <span className="finance-field-error" id={`${idPrefix}-date-error`}>{errors.date}</span> : null}
            </div>
          ) : null}
        </div>
        <div className="field">
          <label htmlFor={`${idPrefix}-destination`}>{copy.destination}</label>
          <select
            ref={destinationRef}
            id={`${idPrefix}-destination`}
            value={destination}
            onChange={(event) => {
              const nextDestination = event.target.value;
              const nextIsHousehold = spaces.find((space) => space.id === nextDestination)?.kind === "household";
              setDestination(nextDestination);
              setShowInCalendar(kind === "commitment" && nextIsHousehold);
              if (!nextIsHousehold) {
                setResponsibleUserID("");
                setShowInTasks(false);
              }
            }}
            required
            aria-invalid={Boolean(errors.destination)}
            aria-describedby={errors.destination ? `${idPrefix}-destination-error` : undefined}
          >
            {spaces.map((space) => <option value={space.id} key={space.id}>{space.name}</option>)}
          </select>
          {errors.destination ? <span className="finance-field-error" id={`${idPrefix}-destination-error`}>{errors.destination}</span> : null}
        </div>
        {householdCommitment ? (
          <fieldset className="finance-commitment-projections">
            <legend>{locale === "de" ? "Auch anzeigen in …" : "Also show this in…"}</legend>
            <div className="field">
              <label htmlFor={`${idPrefix}-payment-handling`}>{locale === "de" ? "Wie wird bezahlt?" : "How is it paid?"}</label>
              <select id={`${idPrefix}-payment-handling`} value={paymentHandling} onChange={(event) => setPaymentHandling(event.target.value as Exclude<FinancePaymentHandling, "UNSPECIFIED">)}>
                <option value="AUTOMATIC">{locale === "de" ? "Automatisch" : "Automatic payment"}</option>
                <option value="MANUAL">{locale === "de" ? "Manuell" : "Manual payment"}</option>
                <option value="RENEWAL">{locale === "de" ? "Verlängerung" : "Renewal"}</option>
              </select>
            </div>
            <label className="check-row"><input type="checkbox" checked={showInCalendar} onChange={(event) => setShowInCalendar(event.target.checked)} /><span>{locale === "de" ? "Im Kalender anzeigen" : "Show in Calendar"}</span></label>
            <div className="field">
              <label htmlFor={`${idPrefix}-responsible`}>{locale === "de" ? "Verantwortliche Person" : "Responsible adult"}</label>
              <select id={`${idPrefix}-responsible`} value={responsibleUserID} onChange={(event) => { setResponsibleUserID(event.target.value); if (!event.target.value) setShowInTasks(false); }}>
                <option value="">{locale === "de" ? "Erst Person auswählen" : "Choose an adult first"}</option>
                {adults.map((member) => <option value={member.id} key={member.id}>{member.name}</option>)}
              </select>
            </div>
            <label className={cn("check-row", !responsibleUserID && "is-disabled")}><input type="checkbox" checked={showInTasks} disabled={!responsibleUserID} onChange={(event) => setShowInTasks(event.target.checked)} /><span>{locale === "de" ? "Als Aufgabe anzeigen" : "Show as a task"}</span></label>
          </fieldset>
        ) : null}
        <div className="dialog-actions">
          <button type="button" className="button button--secondary" onClick={onClose} disabled={saving}>
            {copy.cancel}
          </button>
          <button type="submit" className="button button--primary" disabled={saving || !currency}>
            {saving ? copy.savingPlan : copy.savePlan}
          </button>
        </div>
      </form>
    </Modal>
  );
}

function minorInput(value: number | null | undefined) {
  return value == null ? "" : (value / 100).toFixed(2);
}

function CommitmentEditDialog({
  commitment,
  members,
  space,
  locale,
  onClose,
  onChanged,
}: {
  commitment: FinanceCommitment;
  members: FamilyMember[];
  space: FinanceSpace;
  locale: FinanceLocale;
  onClose: () => void;
  onChanged: (message: string) => void;
}) {
  const text = (english: string, german: string) => locale === "de" ? german : english;
  const initialDate = commitment.next_due_date ?? commitment.reviewed_dates[0] ?? "";
  const [name, setName] = useState(commitment.name);
  const [exactAmount, setExactAmount] = useState(minorInput(commitment.exact_minor));
  const [expectedAmount, setExpectedAmount] = useState(minorInput(commitment.expected_minor));
  const [lowAmount, setLowAmount] = useState(minorInput(commitment.low_minor));
  const [highAmount, setHighAmount] = useState(minorInput(commitment.high_minor));
  const [allocated, setAllocated] = useState(minorInput(commitment.already_reserved_minor));
  const [dueDate, setDueDate] = useState(initialDate);
  const [paymentHandling, setPaymentHandling] = useState<FinancePaymentHandling>(commitment.payment_handling ?? "UNSPECIFIED");
  const [showInCalendar, setShowInCalendar] = useState(Boolean(commitment.show_in_calendar));
  const [showInTasks, setShowInTasks] = useState(Boolean(commitment.show_in_tasks));
  const [responsibleUserID, setResponsibleUserID] = useState(commitment.responsible_user_id ?? "");
  const [error, setError] = useState("");
  const [working, setWorking] = useState<"save" | "delete" | null>(null);
  const [confirmDelete, setConfirmDelete] = useState(false);
  const nameRef = useRef<HTMLInputElement>(null);
  const isHousehold = space.kind === "household";
  const adults = members.filter((member) => member.member_type === "user");

  function updatedDates() {
    if (dueDate === initialDate) return commitment.reviewed_dates;
    const changed = commitment.reviewed_dates.map((value) => value === initialDate ? dueDate : value);
    return [...new Set(changed)].sort();
  }

  async function save(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (working) return;
    if (!name.trim()) {
      setError(text("Enter a name.", "Gib einen Namen ein."));
      nameRef.current?.focus();
      return;
    }
    if (!dueDate) {
      setError(text("Choose a due date.", "Wähle ein Fälligkeitsdatum."));
      return;
    }
    let alreadyReservedMinor: number;
    const body: Record<string, unknown> = {
      name: name.trim(),
      payment_handling: isHousehold ? paymentHandling : "UNSPECIFIED",
      show_in_calendar: isHousehold && showInCalendar,
      show_in_tasks: isHousehold && showInTasks,
      responsible_user_id: isHousehold && showInTasks ? responsibleUserID || null : null,
    };
    if (dueDate !== initialDate) body.reviewed_dates = updatedDates();
    try {
      alreadyReservedMinor = financeDecimalToMinor(allocated || "0");
      body.already_reserved_minor = alreadyReservedMinor;
      if (commitment.amount_mode === "EXACT") {
        body.exact_minor = financeDecimalToMinor(exactAmount);
      } else if (commitment.amount_mode === "FORECAST") {
        body.expected_minor = financeDecimalToMinor(expectedAmount);
      } else {
        const low = financeDecimalToMinor(lowAmount);
        const high = financeDecimalToMinor(highAmount);
        if (low > high) throw new Error("range");
        body.low_minor = low;
        body.high_minor = high;
        body.expected_minor = expectedAmount.trim() ? financeDecimalToMinor(expectedAmount) : null;
      }
    } catch {
      setError(text("Check the amounts and use no more than two decimal places.", "Prüfe die Beträge und verwende höchstens zwei Nachkommastellen."));
      return;
    }
    if (isHousehold && (showInCalendar || showInTasks) && paymentHandling === "UNSPECIFIED") {
      setError(text("Choose how this commitment is handled before showing it outside Finance.", "Wähle zuerst, wie diese Verpflichtung behandelt wird."));
      return;
    }
    if (isHousehold && showInTasks && !responsibleUserID) {
      setError(text("Choose a responsible adult for the task.", "Wähle eine verantwortliche Person für die Aufgabe."));
      return;
    }
    setWorking("save");
    setError("");
    try {
      await api<FinanceCommitment>(
        `/finance/commitments/${encodeURIComponent(commitment.id)}`,
        { method: "PATCH", body: JSON.stringify(body) },
        true,
        false,
      );
      onChanged(text("Commitment updated.", "Verpflichtung aktualisiert."));
    } catch (caught) {
      setError(caught instanceof Error && caught.message ? caught.message : text("The commitment could not be updated.", "Die Verpflichtung konnte nicht aktualisiert werden."));
      setWorking(null);
    }
  }

  async function remove() {
    if (working) return;
    setWorking("delete");
    setError("");
    try {
      await api(
        `/finance/commitments/${encodeURIComponent(commitment.id)}`,
        { method: "DELETE" },
        true,
        false,
      );
      onChanged(text("Commitment removed.", "Verpflichtung entfernt."));
    } catch (caught) {
      setError(caught instanceof Error && caught.message ? caught.message : text("The commitment could not be removed.", "Die Verpflichtung konnte nicht entfernt werden."));
      setConfirmDelete(false);
      setWorking(null);
    }
  }

  const idPrefix = `finance-commitment-edit-${commitment.id}`;
  return (
    <Modal
      open
      onOpenChange={(open) => { if (!open && !working) onClose(); }}
      title={confirmDelete ? text("Remove commitment?", "Verpflichtung entfernen?") : text("Edit commitment", "Verpflichtung bearbeiten")}
      description={confirmDelete
        ? text("Its Calendar dates and tasks will also disappear.", "Die Kalendertermine und Aufgaben verschwinden ebenfalls.")
        : text("Update the saved plan and where its due date or task appears.", "Aktualisiere den Plan und wo Fälligkeitsdatum oder Aufgabe angezeigt werden.")}
    >
      {confirmDelete ? (
        <div className="confirm-delete" aria-busy={working === "delete"}>
          {error ? <p className="form-error" role="alert">{error}</p> : null}
          <p>{text(`Remove “${commitment.name}”?`, `„${commitment.name}“ entfernen?`)}</p>
          <div className="dialog-actions">
            <button type="button" className="button button--secondary" disabled={Boolean(working)} onClick={() => setConfirmDelete(false)}>{text("Cancel", "Abbrechen")}</button>
            <button type="button" className="button button--danger" disabled={Boolean(working)} onClick={() => void remove()}><Trash2 aria-hidden="true" size={16} /> {working === "delete" ? text("Removing…", "Wird entfernt…") : text("Remove", "Entfernen")}</button>
          </div>
        </div>
      ) : (
        <form className="form-stack finance-planning-form" onSubmit={(event) => void save(event)} aria-busy={working === "save"}>
          {error ? <p className="form-error" role="alert">{error}</p> : null}
          <div className="field">
            <label htmlFor={`${idPrefix}-name`}>{text("Name", "Name")}</label>
            <input ref={nameRef} id={`${idPrefix}-name`} value={name} onChange={(event) => setName(event.target.value)} autoComplete="off" required />
          </div>
          <div className="form-grid">
            {commitment.amount_mode === "EXACT" ? <div className="field"><label htmlFor={`${idPrefix}-exact`}>{text("Amount", "Betrag")}</label><input id={`${idPrefix}-exact`} type="text" inputMode="decimal" autoComplete="off" value={exactAmount} onChange={(event) => setExactAmount(event.target.value)} required /></div> : null}
            {commitment.amount_mode !== "EXACT" ? <div className="field"><label htmlFor={`${idPrefix}-expected`}>{text("Expected amount", "Erwarteter Betrag")}</label><input id={`${idPrefix}-expected`} type="text" inputMode="decimal" autoComplete="off" value={expectedAmount} onChange={(event) => setExpectedAmount(event.target.value)} required={commitment.amount_mode === "FORECAST"} /></div> : null}
            {commitment.amount_mode === "RANGE" ? <><div className="field"><label htmlFor={`${idPrefix}-low`}>{text("Low estimate", "Niedrige Schätzung")}</label><input id={`${idPrefix}-low`} type="text" inputMode="decimal" autoComplete="off" value={lowAmount} onChange={(event) => setLowAmount(event.target.value)} required /></div><div className="field"><label htmlFor={`${idPrefix}-high`}>{text("High estimate", "Hohe Schätzung")}</label><input id={`${idPrefix}-high`} type="text" inputMode="decimal" autoComplete="off" value={highAmount} onChange={(event) => setHighAmount(event.target.value)} required /></div></> : null}
            <div className="field"><label htmlFor={`${idPrefix}-allocated`}>{text("Already reserved", "Bereits zurückgelegt")}</label><input id={`${idPrefix}-allocated`} type="text" inputMode="decimal" autoComplete="off" value={allocated} onChange={(event) => setAllocated(event.target.value)} /></div>
            <div className="field"><label htmlFor={`${idPrefix}-date`}>{text("Due date", "Fälligkeitsdatum")}</label><input id={`${idPrefix}-date`} type="date" value={dueDate} onChange={(event) => setDueDate(event.target.value)} required /></div>
          </div>
          {isHousehold ? <fieldset className="finance-commitment-projections"><legend>{text("Calendar and Tasks", "Kalender und Aufgaben")}</legend><div className="field"><label htmlFor={`${idPrefix}-handling`}>{text("How is it handled?", "Wie wird sie behandelt?")}</label><select id={`${idPrefix}-handling`} value={paymentHandling} onChange={(event) => setPaymentHandling(event.target.value as FinancePaymentHandling)}><option value="UNSPECIFIED">{text("Not decided", "Noch nicht entschieden")}</option><option value="AUTOMATIC">{text("Automatic payment", "Automatische Zahlung")}</option><option value="MANUAL">{text("Manual payment", "Manuelle Zahlung")}</option><option value="RENEWAL">{text("Review or renew first", "Zuerst prüfen oder verlängern")}</option></select></div><label className="check-row"><input type="checkbox" checked={showInCalendar} onChange={(event) => setShowInCalendar(event.target.checked)} /><span>{text("Show the due date in Calendar", "Fälligkeitsdatum im Kalender anzeigen")}</span></label><div className="field"><label htmlFor={`${idPrefix}-responsible`}>{text("Responsible adult", "Verantwortliche Person")}</label><select id={`${idPrefix}-responsible`} value={responsibleUserID} onChange={(event) => { setResponsibleUserID(event.target.value); if (!event.target.value) setShowInTasks(false); }}><option value="">{text("Not assigned", "Nicht zugewiesen")}</option>{adults.map((member) => <option value={member.id} key={member.id}>{member.name}</option>)}</select></div><label className={cn("check-row", !responsibleUserID && "is-disabled")}><input type="checkbox" checked={showInTasks} disabled={!responsibleUserID} onChange={(event) => setShowInTasks(event.target.checked)} /><span>{text("Create a payment or review task", "Zahlungs- oder Prüfaufgabe erstellen")}</span></label></fieldset> : <p className="finance-plan-edit-note">{text("Private commitments stay inside Finance and do not appear in the family Calendar or Tasks.", "Private Verpflichtungen bleiben in Finance und erscheinen nicht im Familienkalender oder in Aufgaben.")}</p>}
          <div className="dialog-actions">
            <button type="button" className="button button--danger" disabled={Boolean(working)} onClick={() => { setError(""); setConfirmDelete(true); }}><Trash2 aria-hidden="true" size={16} /> {text("Remove", "Entfernen")}</button>
            <button type="button" className="button button--secondary" disabled={Boolean(working)} onClick={onClose}>{text("Cancel", "Abbrechen")}</button>
            <button type="submit" className="button button--primary" disabled={Boolean(working)}>{working === "save" ? text("Saving…", "Wird gespeichert…") : text("Save changes", "Änderungen speichern")}</button>
          </div>
        </form>
      )}
    </Modal>
  );
}

function PlanningView({
  data,
  spaces,
  members,
  scope,
  locale,
  copy,
  notice,
  onCreated,
  onCommitmentChanged,
}: {
  data: FinanceData;
  spaces: FinanceSpace[];
  members: FamilyMember[];
  scope: FinanceScope;
  locale: FinanceLocale;
  copy: FinanceStrings;
  notice: string;
  onCreated: (kind: PlanningKind) => void;
  onCommitmentChanged: (message: string) => void;
}) {
  const [createKind, setCreateKind] = useState<PlanningKind | null>(null);
  const [editingCommitment, setEditingCommitment] = useState<FinanceCommitment | null>(null);
  const spaceNames = new Map(spaces.map((space) => [space.id, space.name]));
  const spaceByID = new Map(spaces.map((space) => [space.id, space]));
  const memberNames = new Map(members.map((member) => [member.id, member.name]));
  const paymentLabels: Record<Exclude<FinancePaymentHandling, "UNSPECIFIED">, string> = locale === "de"
    ? { AUTOMATIC: "Automatische Zahlung", MANUAL: "Manuelle Zahlung", RENEWAL: "Verlängerung" }
    : { AUTOMATIC: "Automatic payment", MANUAL: "Manual payment", RENEWAL: "Renewal" };
  const currencies = [...new Set([
    ...data.accounts.map((account) => account.currency),
    ...data.commitments.map((commitment) => commitment.currency),
    ...data.reserves.map((reserve) => reserve.currency),
    ...data.goals.map((goal) => goal.currency),
  ])];

  useEffect(() => {
    const commitmentID = new URLSearchParams(window.location.search).get("commitment");
    if (!commitmentID) return;
    const commitment = data.commitments.find((item) => item.id === commitmentID);
    if (commitment) setEditingCommitment(commitment);
  }, [data.commitments]);

  function openCommitment(commitment: FinanceCommitment) {
    setEditingCommitment(commitment);
    const url = new URL(window.location.href);
    url.searchParams.set("commitment", commitment.id);
    window.history.replaceState({}, "", url);
  }

  function closeCommitment() {
    setEditingCommitment(null);
    const url = new URL(window.location.href);
    url.searchParams.delete("commitment");
    window.history.replaceState({}, "", url);
  }
  return (
    <section className="finance-data-section finance-planning" aria-labelledby="finance-plans-title">
      <header>
        <div>
          <h2 id="finance-plans-title">{copy.plansTitle}</h2>
          <p>{copy.plansDetail}</p>
        </div>
        <div className="finance-plan-actions">
          <button type="button" className="button button--secondary" onClick={() => setCreateKind("commitment")}>
            <Plus aria-hidden="true" size={16} /> {copy.addCommitment}
          </button>
          <button type="button" className="button button--secondary" onClick={() => setCreateKind("reserve")}>
            <Plus aria-hidden="true" size={16} /> {copy.addReserve}
          </button>
          <button type="button" className="button button--secondary" onClick={() => setCreateKind("goal")}>
            <Plus aria-hidden="true" size={16} /> {copy.addGoal}
          </button>
        </div>
      </header>
      {notice ? <div className="finance-plan-notice" role="status">{notice}</div> : null}
      <div className="finance-plan-groups">
        <section aria-labelledby="finance-commitments-title">
          <h3 id="finance-commitments-title"><CalendarDays aria-hidden="true" size={18} /> {copy.commitmentsTitle}</h3>
          {data.commitments.length ? (
            <div className="finance-plan-list">
              {data.commitments.map((commitment) => {
                const dueDate = commitment.next_due_date ?? commitment.reviewed_dates[0];
                return (
                  <article className="finance-plan-card" key={commitment.id}>
                    <header><strong>{commitment.name}</strong><span>{spaceNames.get(commitment.space_id)}</span></header>
                    {dueDate ? (
                      <div className="finance-plan-date">
                        <span>{copy.dueDate}</span>
                        <time dateTime={dueDate}>{formatDate(dueDate, locale)}</time>
                      </div>
                    ) : null}
                    {commitment.payment_handling && commitment.payment_handling !== "UNSPECIFIED" ? <div className="finance-plan-projection-status"><span>{paymentLabels[commitment.payment_handling]}</span>{commitment.show_in_calendar ? <span><CalendarDays aria-hidden="true" size={15} /> {locale === "de" ? "Kalender" : "Calendar"}</span> : null}{commitment.show_in_tasks ? <span><CheckCircle2 aria-hidden="true" size={15} /> {locale === "de" ? "Aufgabe" : "Task"}{commitment.responsible_user_id && memberNames.get(commitment.responsible_user_id) ? ` · ${memberNames.get(commitment.responsible_user_id)}` : ""}</span> : null}</div> : null}
                    <div className="finance-plan-card-summary">
                      <FundingRing allocatedMinor={commitment.already_reserved_minor} targetMinor={commitment.required_minor} currency={commitment.currency} locale={locale} tone={commitment.funding_status === "FUNDED" ? "positive" : commitment.funding_status === "UNFUNDED" ? "warning" : "accent"} />
                      <dl>
                        <div><dt>{copy.required}</dt><dd>{formatCurrency(commitment.required_minor, commitment.currency, locale)}</dd></div>
                        <div><dt>{copy.allocated}</dt><dd>{formatCurrency(commitment.already_reserved_minor, commitment.currency, locale)}</dd></div>
                        <div><dt>{copy.remaining}</dt><dd>{formatCurrency(commitment.remaining_minor, commitment.currency, locale)}</dd></div>
                      </dl>
                    </div>
                    <span className={cn("finance-plan-status", `is-${commitment.funding_status.toLowerCase()}`)}>
                      {copy.fundingStatuses[commitment.funding_status]}
                    </span>
                    <div className="finance-plan-card-actions">
                      <button type="button" className="button button--secondary" onClick={() => openCommitment(commitment)}>
                        <Pencil aria-hidden="true" size={16} /> {locale === "de" ? "Bearbeiten" : "Edit"}
                      </button>
                      <FinanceShareButton kind="commitments" recordID={commitment.id} space={spaceByID.get(commitment.space_id) ?? null} locale={locale} />
                    </div>
                  </article>
                );
              })}
            </div>
          ) : <p className="finance-plan-empty">{copy.noCommitments}</p>}
        </section>
        <section aria-labelledby="finance-reserves-title">
          <h3 id="finance-reserves-title"><PiggyBank aria-hidden="true" size={18} /> {copy.reservesTitle}</h3>
          {data.reserves.length ? (
            <div className="finance-plan-list">
              {data.reserves.map((reserve) => (
                <article className="finance-plan-card" key={reserve.id}>
                  <header><strong>{reserve.name}</strong><span>{spaceNames.get(reserve.space_id)}</span></header>
                  <div className="finance-plan-card-summary">
                    <FundingRing allocatedMinor={reserve.allocated_minor} targetMinor={reserve.target_minor} currency={reserve.currency} locale={locale} tone={reserve.funding_status === "FUNDED" || reserve.funding_status === "OVERFUNDED" ? "positive" : reserve.funding_status === "UNFUNDED" ? "warning" : reserve.funding_status === "UNTARGETED" ? "neutral" : "accent"} />
                    <dl>
                      <div><dt>{copy.targetAmount}</dt><dd>{reserve.target_minor == null ? "—" : formatCurrency(reserve.target_minor, reserve.currency, locale)}</dd></div>
                      <div><dt>{copy.allocated}</dt><dd>{formatCurrency(reserve.allocated_minor, reserve.currency, locale)}</dd></div>
                      <div><dt>{copy.remaining}</dt><dd>{reserve.remaining_minor == null ? "—" : formatCurrency(reserve.remaining_minor, reserve.currency, locale)}</dd></div>
                    </dl>
                  </div>
                  <span className={cn("finance-plan-status", `is-${reserve.funding_status.toLowerCase()}`)}>
                    {copy.fundingStatuses[reserve.funding_status]}
                  </span>
                </article>
              ))}
            </div>
          ) : <p className="finance-plan-empty">{copy.noReserves}</p>}
        </section>
        <section aria-labelledby="finance-goals-title">
          <h3 id="finance-goals-title"><Target aria-hidden="true" size={18} /> {copy.goalsTitle}</h3>
          {data.goals.length ? (
            <div className="finance-plan-list">
              {data.goals.map((goal) => (
                <article className="finance-plan-card" key={goal.id}>
                  <header><strong>{goal.name}</strong><span>{spaceNames.get(goal.space_id)}</span></header>
                  <div className="finance-plan-date">
                    <span>{copy.deadline}</span>
                    <time dateTime={goal.deadline}>{formatDate(goal.deadline, locale)}</time>
                  </div>
                  <div className="finance-plan-card-summary">
                    <FundingRing allocatedMinor={goal.currently_allocated_minor} targetMinor={goal.target_minor} currency={goal.currency} locale={locale} tone={goal.feasibility === "ACHIEVED" ? "positive" : goal.feasibility === "INFEASIBLE" ? "warning" : "accent"} />
                    <dl>
                      <div><dt>{copy.targetAmount}</dt><dd>{formatCurrency(goal.target_minor, goal.currency, locale)}</dd></div>
                      <div><dt>{copy.allocated}</dt><dd>{formatCurrency(goal.currently_allocated_minor, goal.currency, locale)}</dd></div>
                      <div><dt>{copy.remaining}</dt><dd>{formatCurrency(goal.remaining_minor, goal.currency, locale)}</dd></div>
                    </dl>
                  </div>
                  <span className={cn("finance-plan-status", `is-${goal.feasibility.toLowerCase()}`)}>
                    {copy.goalFeasibility[goal.feasibility]}
                  </span>
                  <FinanceShareButton kind="goals" recordID={goal.id} space={spaceByID.get(goal.space_id) ?? null} locale={locale} />
                </article>
              ))}
            </div>
          ) : <p className="finance-plan-empty">{copy.noGoals}</p>}
        </section>
      </div>
      {createKind ? (
        <PlanningCreateDialog
          kind={createKind}
          spaces={spaces}
          members={members}
          currencies={currencies}
          scope={scope}
          locale={locale}
          copy={copy}
          onClose={() => setCreateKind(null)}
          onCreated={(createdKind) => {
            setCreateKind(null);
            onCreated(createdKind);
          }}
        />
      ) : null}
      {editingCommitment && spaceByID.get(editingCommitment.space_id) ? (
        <CommitmentEditDialog
          commitment={editingCommitment}
          members={members}
          space={spaceByID.get(editingCommitment.space_id)!}
          locale={locale}
          onClose={closeCommitment}
          onChanged={(message) => {
            closeCommitment();
            onCommitmentChanged(message);
          }}
        />
      ) : null}
    </section>
  );
}

function consentedForScope(
  consents: FinanceAIConsent[],
  spaces: FinanceSpace[],
  scope: FinanceScope,
) {
  const required = scope === "household"
    ? spaces.filter((space) => space.kind === "household")
    : spaces;
  return required.length > 0 && required.every((space) => (
    consents.some((consent) => consent.space_id === space.id && consent.consented)
  ));
}

function CoachConsentPanel({
  state,
  spaces,
  locale,
  copy,
  workingSpaceID,
  actionError,
  onRetry,
  onChange,
}: {
  state: ConsentLoadState;
  spaces: FinanceSpace[];
  locale: FinanceLocale;
  copy: FinanceStrings;
  workingSpaceID: string | null;
  actionError: string;
  onRetry: () => void;
  onChange: (consent: FinanceAIConsent, accepted: boolean) => void;
}) {
  // The parent has already resolved the exact scope-safe spaces. My finances
  // contains the current adult's personal space plus Household, so consent is
  // shown and checked separately for each without widening to a partner space.
  const allowedSpaces = spaces;
  const allowedIDs = new Set(allowedSpaces.map((space) => space.id));
  const spaceNames = new Map(allowedSpaces.map((space) => [space.id, space.name]));
  return (
    <section className="finance-consent-panel" aria-labelledby="finance-consent-title">
      <header>
        <div>
          <h3 id="finance-consent-title">{copy.aiNoticeTitle}</h3>
          <p>{copy.aiNoticeDetail}</p>
        </div>
      </header>
      {state.status === "idle" || state.status === "loading" ? (
        <div className="finance-consent-skeleton" aria-label={copy.consentLoading} aria-busy="true">
          <div />
          <div />
        </div>
      ) : state.status === "error" ? (
        <div className="finance-coach-inline-state is-error" role="alert">
          <AlertCircle aria-hidden="true" size={20} />
          <div><strong>{copy.consentErrorTitle}</strong><p>{copy.consentErrorDetail}</p></div>
          <button type="button" className="button button--secondary" onClick={onRetry}>{copy.retry}</button>
        </div>
      ) : (() => {
        const consents = state.consents.filter((consent) => allowedIDs.has(consent.space_id));
        if (!consents.length) return <p className="finance-consent-empty">{copy.consentEmpty}</p>;
        const providerUnavailable = consents.every((consent) => consent.provider === "off");
        return (
          <>
            <div className="finance-disclosure">
              <strong>{copy.disclosureLabel}</strong>
              <p>{consents[0].disclosure}</p>
              <span><ShieldCheck aria-hidden="true" size={15} /> {copy.noStorageDetail}</span>
            </div>
            {providerUnavailable ? (
              <div className="finance-coach-inline-state is-warning" role="status">
                <AlertCircle aria-hidden="true" size={20} />
                <p>{copy.coachProviderUnavailable}</p>
              </div>
            ) : null}
            {actionError ? <div className="form-error" role="alert">{actionError}</div> : null}
            <div className="finance-consent-list">
              {consents.map((consent) => {
                const name = spaceNames.get(consent.space_id) ?? consent.space_kind;
                const busy = workingSpaceID === consent.space_id;
                return (
                  <article key={consent.space_id}>
                    <div>
                      <strong>{name}</strong>
                      <span className={cn("finance-consent-status", consent.consented && "is-consented")}>
                        {consent.consented ? copy.consentedStatus : copy.notConsentedStatus}
                      </span>
                      {consent.consented_at ? (
                        <small>{copy.consentedAt}: {formatDateTime(consent.consented_at, locale)}</small>
                      ) : null}
                    </div>
                    <button
                      type="button"
                      className={cn("button", consent.consented ? "button--secondary" : "button--primary")}
                      disabled={workingSpaceID !== null || providerUnavailable}
                      aria-busy={busy}
                      onClick={() => onChange(consent, !consent.consented)}
                    >
                      {consent.consented ? copy.withdrawFor : copy.agreeFor} {name}
                    </button>
                  </article>
                );
              })}
            </div>
          </>
        );
      })()}
    </section>
  );
}

function CoachAnswer({
  state,
  locale,
  scope,
  copy,
  headingID = "finance-coach-answer-title",
}: {
  state: CoachAnswerState;
  locale: FinanceLocale;
  scope: FinanceScope;
  copy: FinanceStrings;
  headingID?: string;
}) {
  if (state.status === "idle") {
    return (
      <div className="finance-coach-answer-empty">
        <MessageCircleMore aria-hidden="true" size={28} />
        <div><strong>{copy.answerEmptyTitle}</strong><p>{copy.answerEmptyDetail}</p></div>
      </div>
    );
  }
  if (state.status === "sending") {
    return (
      <div className="finance-coach-answer-skeleton" aria-label={copy.answerLoading} aria-busy="true">
        <div />
        <div />
        <div />
      </div>
    );
  }
  if (state.status === "error") {
    const message = state.kind === "consent"
      ? copy.coachConsentRequired
      : state.kind === "unavailable"
        ? copy.coachProviderUnavailable
        : copy.coachRequestError;
    return (
      <div className={cn("finance-coach-inline-state", state.kind === "unavailable" ? "is-warning" : "is-error")} role="alert">
        <AlertCircle aria-hidden="true" size={20} />
        <div><p>{message}</p>{state.kind === "unavailable" ? <div className="finance-coach-fallback-links"><a className="button button--secondary" href={`/?view=finance&section=explore${scope === "household" ? "&scope=household" : ""}`}>{copy.fallbackExplore}</a><a className="button button--secondary" href={`/?view=finance&section=goals${scope === "household" ? "&scope=household" : ""}`}>{copy.fallbackPlans}</a></div> : null}</div>
      </div>
    );
  }

  const { answer } = state;
  return (
    <article className="finance-coach-answer" aria-labelledby={headingID}>
      <header>
        <h3 id={headingID}>{answer.headline}</h3>
      </header>
      <p className="finance-coach-answer-text">{answer.answer}</p>
      {answer.analysis_view_id ? (
        <a className="button button--secondary finance-coach-analysis-link" href={`/?view=finance&section=explore${scope === "household" ? "&scope=household" : ""}&analysis=${encodeURIComponent(answer.analysis_view_id)}`}>
          <BarChart3 aria-hidden="true" size={17} /> {locale === "de" ? "Passende Auswertung öffnen" : "Open matching analysis"}
        </a>
      ) : null}
      {answer.draft ? <section className="finance-coach-draft" aria-label={copy.returnedDraft} role="status" aria-live="polite"><span>{copy.returnedDraft}</span><h4>{answer.draft.title}</h4><p>{answer.draft.summary}</p>{answer.draft.fields?.length ? <dl>{answer.draft.fields.map((field) => <div key={`${field.label}-${field.value}`}><dt>{field.label}</dt><dd>{field.value}</dd></div>)}</dl> : null}<small>{copy.draftNotSaved}</small></section> : null}
      <details className="finance-coach-answer-details">
        <summary>{locale === "de" ? "So wurde die Antwort berechnet" : "How this was worked out"}</summary>
        <div className="finance-answer-support">
        <section aria-labelledby="finance-answer-claims-title">
          <h4 id="finance-answer-claims-title"><CheckCircle2 aria-hidden="true" size={16} /> {copy.checkedClaimsTitle}</h4>
          {answer.claims.length ? (
            <ul>{answer.claims.map((claim, index) => <li key={`${index}-${claim.text}`}><span>{claim.text}</span><div className="finance-evidence-links" aria-label={copy.evidenceTitle}>{claim.evidence_ids.map((evidenceID, evidenceIndex) => { const [kind, id] = evidenceID.split(":", 2); const href = kind === "transaction" && id ? `/?view=finance&section=activity${scope === "household" ? "&scope=household" : ""}&transaction=${encodeURIComponent(id)}` : kind === "purchase-line" && id ? `/?view=finance&section=more${scope === "household" ? "&scope=household" : ""}&line=${encodeURIComponent(id)}` : null; const label = kind === "transaction" ? `${locale === "de" ? "Bankeintrag" : "Bank entry"} ${evidenceIndex + 1}` : kind === "purchase-line" ? `${locale === "de" ? "Belegposition" : "Receipt item"} ${evidenceIndex + 1}` : `${locale === "de" ? "Beleg" : "Supporting record"} ${evidenceIndex + 1}`; return href ? <a key={evidenceID} href={href}><span>{label}</span><span>{copy.openEvidence}</span></a> : <span key={evidenceID}>{label}</span>; })}</div></li>)}</ul>
          ) : <p>{copy.noCheckedClaims}</p>}
        </section>
        <section aria-labelledby="finance-answer-estimates-title">
          <h4 id="finance-answer-estimates-title">{copy.estimatesTitle}</h4>
          {answer.estimates.length ? (
            <div className="finance-estimate-list">
              {answer.estimates.map((estimate, index) => (
                <article key={`${index}-${estimate.text}`}>
                  <strong>{estimate.text}</strong>
                  {estimate.low_minor != null && estimate.high_minor != null && estimate.currency ? (
                    <span>{formatCurrency(estimate.low_minor, estimate.currency, locale)}–{formatCurrency(estimate.high_minor, estimate.currency, locale)}</span>
                  ) : null}
                  <div><small>{copy.assumptionsTitle}</small><ul>{estimate.assumptions.map((assumption) => <li key={assumption}>{assumption}</li>)}</ul></div>
                </article>
              ))}
            </div>
          ) : <p>{copy.noEstimates}</p>}
        </section>
        <section aria-labelledby="finance-answer-actions-title">
          <h4 id="finance-answer-actions-title">{copy.suggestedActionsTitle}</h4>
          {answer.suggested_actions.length ? (
            <ul>{answer.suggested_actions.map((action) => <li key={action}>{action}</li>)}</ul>
          ) : <p>{copy.noSuggestedActions}</p>}
        </section>
        </div>
      </details>
      <p className="finance-answer-basis-note"><small>{answer.answer_mode === "ESTIMATE" || answer.answer_mode === "PARTIAL" ? `${locale === "de" ? "Beste aktuelle Schätzung" : "Best current estimate"} · ` : ""}{answer.data_through
        ? `${locale === "de" ? "basierend auf Einträgen bis" : "based on records through"} ${formatDateTime(answer.data_through, locale)}.`
        : (locale === "de" ? "Basierend auf den zuletzt gespeicherten Einträgen." : "Based on the latest saved records.")}</small></p>
    </article>
  );
}

function CoachQuestionPanel({
  question,
  answerState,
  exchanges,
  providerUnavailable,
  canAsk,
  online,
  scope,
  locale,
  copy,
  onQuestionChange,
  onAsk,
  onStartOver,
}: {
  question: string;
  answerState: CoachAnswerState;
  exchanges: CoachExchange[];
  providerUnavailable: boolean;
  canAsk: boolean;
  online: boolean;
  scope: FinanceScope;
  locale: FinanceLocale;
  copy: FinanceStrings;
  onQuestionChange: (question: string) => void;
  onAsk: () => void;
  onStartOver: () => void;
}) {
  const sending = answerState.status === "sending";
  return (
    <section className="finance-question-panel" aria-labelledby="finance-question-title">
      <header><div><h3 id="finance-question-title">{copy.questionTitle}</h3><p>{copy.questionDetail}</p><small>{copy.currentTabConversation}</small></div>{exchanges.length || answerState.status !== "idle" ? <button type="button" className="button button--secondary" onClick={onStartOver}>{copy.startOver}</button> : null}</header>
      {providerUnavailable ? <CoachAnswer state={{ status: "error", kind: "unavailable" }} locale={locale} scope={scope} copy={copy} /> : null}
      {exchanges.length ? <div className="finance-coach-conversation">{exchanges.map((exchange, index) => <div className="finance-coach-exchange" key={`${index}-${exchange.question}`}><p><strong>{copy.yourQuestion}:</strong> {exchange.question}</p><CoachAnswer state={{ status: "ready", answer: exchange.answer }} locale={locale} scope={scope} copy={copy} headingID={`finance-coach-answer-title-${index}`} /></div>)}</div> : null}
      <form
        className="finance-question-form"
        onSubmit={(event) => { event.preventDefault(); onAsk(); }}
        aria-busy={sending}
      >
        <div className="field">
          <label htmlFor="finance-coach-question">{copy.questionLabel}</label>
          <textarea
            id="finance-coach-question"
            rows={3}
            maxLength={4000}
            value={question}
            onChange={(event) => onQuestionChange(event.target.value)}
            placeholder={copy.questionPlaceholder}
            autoComplete="off"
          />
          {!canAsk && !providerUnavailable ? <span className="finance-question-hint">{scope === "mine" ? copy.consentNeededMine : copy.consentNeededHousehold}</span> : null}
        </div>
        <button
          type="submit"
          className="button button--primary"
          disabled={!online || sending || !canAsk || !question.trim()}
          aria-busy={sending}
        >
          <Send aria-hidden="true" size={16} /> {sending ? copy.sendingQuestion : copy.sendQuestion}
        </button>
      </form>
      {!providerUnavailable && (answerState.status !== "idle" || !exchanges.length) ? <CoachAnswer state={answerState} locale={locale} scope={scope} copy={copy} /> : null}
    </section>
  );
}

function CashflowSnapshot({
  data,
  spaces,
  locale,
  copy,
}: {
  data: FinanceData;
  spaces: FinanceSpace[];
  locale: FinanceLocale;
  copy: FinanceStrings;
}) {
  const summaries = data.spaceData.flatMap((spaceData) => {
    const space = spaces.find((candidate) => candidate.id === spaceData.summary.space_id);
    return spaceData.summary.currencies.map((summary) => ({ space, summary }));
  });
  return (
    <section className="module-card finance-overview-cashflow" aria-labelledby="finance-overview-cashflow-title">
      <header>
        <div>
          <h2 id="finance-overview-cashflow-title">{copy.exploreTitle}</h2>
          <p>{spaces.length > 1
            ? (locale === "de" ? "Private und gemeinsame Geldflüsse werden getrennt angezeigt." : "Private and Household cash flow stay separate.")
            : (locale === "de" ? "Einnahmen, Ausgaben und was im gewählten Zeitraum übrig blieb." : "Income, spending and what was left over in the selected period.")}</p>
        </div>
      </header>
      {summaries.length ? (
        <div className="finance-summary-grid">
          {summaries.map(({ space, summary: currencySummary }) => (
            <article className="finance-summary-card" key={`${space?.id ?? "space"}:${currencySummary.currency}`}>
              <h3>{spaces.length > 1 ? `${space?.name ?? "Finance"} · ` : ""}{currencySummary.currency}</h3>
              <Waterfall
                currency={currencySummary.currency}
                locale={locale}
                steps={[
                  { key: "income", label: copy.income, deltaMinor: currencySummary.income_minor },
                  { key: "spend", label: copy.grossSpend, deltaMinor: -currencySummary.gross_spending_minor },
                  ...(currencySummary.refunds_minor ? [{ key: "refunds", label: copy.refunds, deltaMinor: currencySummary.refunds_minor }] : []),
                  ...(currencySummary.reimbursements_minor ? [{ key: "reimb", label: copy.reimbursements, deltaMinor: currencySummary.reimbursements_minor }] : []),
                  ...(currencySummary.fees_minor ? [{ key: "fees", label: copy.fees, deltaMinor: -currencySummary.fees_minor }] : []),
                  { key: "net", label: copy.movement, deltaMinor: 0, isTotal: true, totalMinor: currencySummary.account_movement_minor },
                ] satisfies WaterfallStep[]}
              />
              <dl>
                <div><dt>{copy.income}</dt><dd>{formatCurrency(currencySummary.income_minor, currencySummary.currency, locale)}</dd></div>
                <div><dt>{copy.grossSpend}</dt><dd>{formatCurrency(currencySummary.gross_spending_minor, currencySummary.currency, locale)}</dd></div>
                <div className="is-total"><dt>{copy.movement}</dt><dd>{formatCurrency(currencySummary.account_movement_minor, currencySummary.currency, locale, true)}</dd></div>
              </dl>
            </article>
          ))}
        </div>
      ) : (
        <EmptyPanel icon={BarChart3} title={copy.noSummaryTitle} detail={copy.noSummaryDetail} />
      )}
    </section>
  );
}

function CoachView({
  data,
  spaces,
  scope,
  online,
  locale,
  copy,
  consentState,
  consentWorkingSpaceID,
  consentActionError,
  onConsentRetry,
  onConsentChange,
  question,
  answerState,
  exchanges,
  onQuestionChange,
  onAsk,
  onStartOver,
}: {
  data: FinanceData;
  spaces: FinanceSpace[];
  scope: FinanceScope;
  online: boolean;
  locale: FinanceLocale;
  copy: FinanceStrings;
  consentState: ConsentLoadState;
  consentWorkingSpaceID: string | null;
  consentActionError: string;
  onConsentRetry: () => void;
  onConsentChange: (consent: FinanceAIConsent, accepted: boolean) => void;
  question: string;
  answerState: CoachAnswerState;
  exchanges: CoachExchange[];
  onQuestionChange: (question: string) => void;
  onAsk: () => void;
  onStartOver: () => void;
}) {
  const [askOpen, setAskOpen] = useState(true);
  const [captureOpen, setCaptureOpen] = useState(false);
  const balanceGroups = spaces.map((space) => ({
    space,
    balances: currencyBalances(data, space.id),
  })).filter((group) => group.balances.length);
  const canAsk = consentState.status === "ready"
    && consentedForScope(consentState.consents, spaces, scope)
    && spaces.every((space) => consentState.consents.some((consent) => (
      consent.space_id === space.id && consent.provider !== "off"
    )));
  const providerUnavailable = consentState.status === "ready" && spaces.some((space) => consentState.consents.some((consent) => consent.space_id === space.id && consent.provider === "off"));

  useEffect(() => {
    if (question.trim()) setAskOpen(true);
  }, [question]);

  return (
    <div className="finance-section-content">
      <Suspense fallback={<FinanceDataSkeleton label={copy.loadingData} />}>
        <FinanceCoachHomeView
          spaces={spaces}
          scope={scope}
          commitments={data.commitments}
          goals={data.goals}
          locale={locale}
        />
      </Suspense>

      <details
        id="finance-coach-disclosure"
        className="module-disclosure finance-coach-disclosure"
        open={askOpen}
        onToggle={(event) => setAskOpen(event.currentTarget.open)}
      >
        <summary role="button" aria-expanded={askOpen}>
          <span><Sparkles aria-hidden="true" size={17} /> {locale === "de" ? "Finance Coach fragen" : "Ask Finance Coach"}</span>
          <ChevronRight aria-hidden="true" size={18} />
        </summary>
        <section className="finance-coach-panel" aria-labelledby="finance-coach-panel-title">
          <header>
            <div>
              <span className="finance-status-label"><Sparkles aria-hidden="true" size={15} /> {copy.coach}</span>
              <h2 id="finance-coach-panel-title">{copy.coachPanelTitle}</h2>
              <p>{copy.coachPanelDetail}</p>
            </div>
          </header>
          <CoachConsentPanel
            state={consentState}
            spaces={spaces}
            locale={locale}
            copy={copy}
            workingSpaceID={consentWorkingSpaceID}
            actionError={consentActionError}
            onRetry={onConsentRetry}
            onChange={onConsentChange}
          />
          <CoachQuestionPanel
            question={question}
            answerState={answerState}
            exchanges={exchanges}
            providerUnavailable={providerUnavailable}
            canAsk={canAsk}
            online={online}
            scope={scope}
            locale={locale}
            copy={copy}
            onQuestionChange={onQuestionChange}
            onAsk={onAsk}
            onStartOver={onStartOver}
          />
        </section>
      </details>

      <CashflowSnapshot data={data} spaces={spaces} locale={locale} copy={copy} />

      <div className="finance-overview-actions">
        <button
          type="button"
          className="button button--secondary"
          aria-expanded={captureOpen}
          aria-controls="finance-overview-capture"
          onClick={() => setCaptureOpen((open) => !open)}
        >
          <Plus aria-hidden="true" size={17} /> {spaces[0]?.kind === "personal"
            ? (locale === "de" ? "Einkauf, Rechnung oder Beleg erfassen" : "Capture a purchase, bill or receipt")
            : (locale === "de" ? "Einkauf oder Rechnung erfassen" : "Capture a purchase or bill")}
        </button>
      </div>

      {captureOpen ? (
        <div id="finance-overview-capture" className="finance-context-capture">
          <Suspense fallback={<FinanceDataSkeleton label={copy.loadingData} />}>
            <FinanceCapturePanel
              spaces={spaces.slice(0, 1)}
              accounts={data.accounts}
              locale={locale}
              conversation={[]}
              context={{ screen: "coach", selected_transaction_id: null, selected_purchase_id: null, selected_purchase_line_id: null, selected_account_id: null }}
            />
          </Suspense>
        </div>
      ) : null}

      <details className="finance-calm-details finance-calm-account-details">
        <summary><span><strong>{locale === "de" ? "Konten und Salden" : "Accounts and balances"}</strong><small>{locale === "de" ? "Nur öffnen, wenn du die Einzelheiten brauchst" : "Open only when you need the detail"}</small></span><ChevronRight aria-hidden="true" size={18} /></summary>
      <section className="finance-data-section" aria-labelledby="finance-balances-title">
        <header>
          <div>
            <h2 id="finance-balances-title">{copy.balancesTitle}</h2>
            <p>{copy.balancesDetail}</p>
          </div>
        </header>
        {balanceGroups.length ? (
          <div className="finance-currency-grid">
            {balanceGroups.flatMap(({ space, balances }) => balances.map((balance) => (
              <article className="finance-currency-card" key={`${space.id}:${balance.currency}`}>
                <h3>{spaces.length > 1 ? `${space.name} · ` : ""}{balance.currency}</h3>
                <dl>
                  <div>
                    <dt>{copy.bookedBalance}</dt>
                    <dd>
                      {balance.bookedMinor == null
                        ? copy.balanceUnavailable
                        : formatCurrency(balance.bookedMinor, balance.currency, locale)}
                    </dd>
                  </div>
                  {balance.availableMinor == null ? null : (
                    <div>
                      <dt>{copy.availableBalance}</dt>
                      <dd>{formatCurrency(balance.availableMinor, balance.currency, locale)}</dd>
                    </div>
                  )}
                  <div>
                    <dt>{copy.movement}</dt>
                    <dd>
                      {formatCurrency(
                        balance.summary?.account_movement_minor ?? 0,
                        balance.currency,
                        locale,
                        true,
                      )}
                    </dd>
                  </div>
                  <div>
                    <dt>{copy.grossSpend}</dt>
                    <dd>
                      {formatCurrency(
                        balance.summary?.gross_spending_minor ?? 0,
                        balance.currency,
                        locale,
                      )}
                    </dd>
                  </div>
                </dl>
              </article>
            )))}
          </div>
        ) : (
          <EmptyPanel
            icon={WalletCards}
            title={copy.noBalanceDataTitle}
            detail={copy.noBalanceDataDetail}
          />
        )}
      </section>

      <section className="finance-data-section" aria-labelledby="finance-accounts-title">
        <header>
          <h2 id="finance-accounts-title">{copy.accountsTitle}</h2>
        </header>
        {data.accounts.length ? (
          <div className="finance-account-grid">
            {data.accounts.map((account) => (
              <article className="finance-account-card" key={account.id}>
                <div className="finance-account-heading">
                  <span className="finance-account-icon"><Landmark aria-hidden="true" size={18} /></span>
                  <div>
                    <h3>{account.label}</h3>
                    <p>
                      {account.institution ?? copy.accountTypes[account.account_type]}
                      {account.last_four ? ` · ${copy.endingIn} ${account.last_four}` : ""}
                    </p>
                  </div>
                </div>
                <strong className="finance-account-balance">
                  {account.balance
                    ? formatCurrency(account.balance.booked_minor, account.currency, locale)
                    : copy.balanceUnavailable}
                </strong>
                {account.balance?.available_minor == null ? null : (
                  <span className="finance-account-available">
                    {copy.available}: {formatCurrency(
                      account.balance.available_minor,
                      account.currency,
                      locale,
                    )}
                  </span>
                )}
                {account.provider_presence_status === "OMITTED" ? <span className="finance-account-available">{locale === "de" ? "Anbieterkennzeichen der privaten Quelle werden nicht geteilt." : "Provider identifiers from the private source are not shared."}</span> : null}
              </article>
            ))}
          </div>
        ) : (
          <EmptyPanel
            icon={Building2}
            title={copy.noAccountsTitle}
            detail={copy.noAccountsDetail}
          />
        )}
      </section>
      </details>
    </div>
  );
}

type PurchaseDetailLoadState =
  | { status: "idle" }
  | { status: "loading"; purchaseID: string }
  | { status: "error"; purchaseID: string };

type PurchaseCandidateState =
  | { status: "idle" }
  | { status: "loading" }
  | { status: "ready"; transactions: FinanceTransaction[] }
  | { status: "error" };

function PurchaseMatchReview({
  detail,
  locale,
  copy,
  onMatched,
}: {
  detail: FinancePurchaseDetail;
  locale: FinanceLocale;
  copy: FinanceStrings;
  onMatched: (detail: FinancePurchaseDetail) => void;
}) {
  const [open, setOpen] = useState(false);
  const [candidateState, setCandidateState] = useState<PurchaseCandidateState>({ status: "idle" });
  const [retryKey, setRetryKey] = useState(0);
  const [allocations, setAllocations] = useState<Record<string, string>>({});
  const [saving, setSaving] = useState(false);
  const [saveError, setSaveError] = useState("");

  const confirmedNonBank = detail.payment_allocations.filter((allocation) => (
    allocation.status === "CONFIRMED" && allocation.transaction_id === null
  ));
  const purchaseRequired = Math.max(
    0,
    detail.final_total_minor - confirmedNonBank.reduce(
      (total, allocation) => total + Math.max(0, allocation.allocated_minor),
      0,
    ),
  );
  const refundRequired = Math.max(
    0,
    detail.refunded_minor - confirmedNonBank.reduce(
      (total, allocation) => total + Math.max(0, -allocation.allocated_minor),
      0,
    ),
  );

  useEffect(() => {
    if (!open) return;
    const controller = new AbortController();
    let active = true;
    setCandidateState({ status: "loading" });
    api<FinanceTransaction[]>(
      `/finance/transactions?space_id=${encodeURIComponent(detail.space_id)}&offset=0&limit=200`,
      { signal: controller.signal },
      true,
      false,
    )
      .then((transactions) => {
        if (!active) return;
        setCandidateState({
          status: "ready",
          transactions: transactions.filter((transaction) => (
            transaction.space_id === detail.space_id
            && transaction.currency === detail.currency
            && transaction.state === "POSTED"
            && transaction.amount_minor !== 0
          )),
        });
      })
      .catch((error: unknown) => {
        if (!active || isAbortError(error)) return;
        setCandidateState({ status: "error" });
      });
    return () => {
      active = false;
      controller.abort();
    };
  }, [open, retryKey, detail.id, detail.space_id, detail.currency]);

  const parsedAllocations = Object.entries(allocations).flatMap(([transactionID, value]) => {
    try {
      return [{ transactionID, amountMinor: financeDecimalToMinor(value) }];
    } catch {
      return [];
    }
  });
  const allSelectedValid = parsedAllocations.length === Object.keys(allocations).length;
  const transactionByID = new Map(
    candidateState.status === "ready"
      ? candidateState.transactions.map((transaction) => [transaction.id, transaction])
      : [],
  );
  const purchaseAllocated = parsedAllocations.reduce((total, allocation) => {
    const transaction = transactionByID.get(allocation.transactionID);
    return transaction && transaction.amount_minor < 0
      ? total + allocation.amountMinor
      : total;
  }, 0);
  const refundAllocated = parsedAllocations.reduce((total, allocation) => {
    const transaction = transactionByID.get(allocation.transactionID);
    return transaction && transaction.amount_minor > 0
      ? total + allocation.amountMinor
      : total;
  }, 0);
  const purchaseRemaining = purchaseRequired - purchaseAllocated;
  const refundRemaining = refundRequired - refundAllocated;
  const selectedAmountsWithinBounds = parsedAllocations.every((allocation) => {
    const transaction = transactionByID.get(allocation.transactionID);
    return Boolean(
      transaction
      && allocation.amountMinor > 0
      && allocation.amountMinor <= Math.abs(transaction.amount_minor),
    );
  });
  const exact = allSelectedValid
    && parsedAllocations.length > 0
    && selectedAmountsWithinBounds
    && purchaseRemaining === 0
    && refundRemaining === 0;

  function toggleTransaction(transaction: FinanceTransaction, checked: boolean) {
    setSaveError("");
    setAllocations((current) => {
      if (!checked) {
        const { [transaction.id]: removed, ...remaining } = current;
        void removed;
        return remaining;
      }
      const directionRemaining = transaction.amount_minor < 0
        ? Math.max(0, purchaseRequired - purchaseAllocated)
        : Math.max(0, refundRequired - refundAllocated);
      const amount = Math.min(Math.abs(transaction.amount_minor), directionRemaining);
      return { ...current, [transaction.id]: (amount / 100).toFixed(2) };
    });
  }

  async function submitMatch(event: FormEvent) {
    event.preventDefault();
    if (!exact || saving) return;
    setSaving(true);
    setSaveError("");
    try {
      const updated = await api<FinancePurchaseDetail>(
        `/finance/purchases/${encodeURIComponent(detail.id)}/match`,
        {
          method: "POST",
          body: JSON.stringify({
            reviewed: true,
            allocations: parsedAllocations.map((allocation) => ({
              transaction_id: allocation.transactionID,
              allocated_minor:
                (transactionByID.get(allocation.transactionID)?.amount_minor ?? 0) < 0
                  ? allocation.amountMinor
                  : -allocation.amountMinor,
            })),
          }),
        },
        true,
        false,
      );
      if (
        updated.id !== detail.id
        || updated.space_id !== detail.space_id
        || updated.evidence.space_id !== detail.space_id
      ) {
        throw new Error(copy.purchaseMatchError);
      }
      onMatched(updated);
    } catch (error) {
      setSaveError(error instanceof Error && error.message ? error.message : copy.purchaseMatchError);
    } finally {
      setSaving(false);
    }
  }

  return (
    <details
      className="finance-purchase-match-review"
      onToggle={(event) => setOpen(event.currentTarget.open)}
    >
      <summary>{copy.purchaseMatchReviewTitle}</summary>
      <div>
        <p>{copy.purchaseMatchReviewDetail}</p>
        {candidateState.status === "idle" || candidateState.status === "loading" ? (
          <div className="finance-purchase-match-state" aria-label={copy.purchaseMatchLoading} aria-busy="true">
            <CircleDashed aria-hidden="true" size={18} /> {copy.purchaseMatchLoading}
          </div>
        ) : candidateState.status === "error" ? (
          <div className="finance-purchase-match-state is-error" role="alert">
            <AlertCircle aria-hidden="true" size={18} />
            <span>{copy.purchaseMatchLoadError}</span>
            <button type="button" className="button button--secondary" onClick={() => setRetryKey((key) => key + 1)}>{copy.retry}</button>
          </div>
        ) : candidateState.transactions.length === 0 ? (
          <p className="finance-purchase-muted">{copy.purchaseMatchNoCandidates}</p>
        ) : (
          <form className="finance-purchase-match-form" onSubmit={(event) => void submitMatch(event)}>
            <ul className="finance-purchase-candidate-list">
              {candidateState.transactions.map((transaction) => {
                const selected = transaction.id in allocations;
                const isRefund = transaction.amount_minor > 0;
                const directionNeeded = isRefund ? refundRequired > 0 : purchaseRequired > 0;
                return (
                  <li key={transaction.id}>
                    <label>
                      <input
                        type="checkbox"
                        checked={selected}
                        disabled={!directionNeeded || saving}
                        onChange={(event) => toggleTransaction(transaction, event.target.checked)}
                        aria-label={`${copy.purchaseSelectTransaction}: ${transaction.merchant_text ?? transaction.description}`}
                      />
                      <span>
                        <strong>{transaction.merchant_text ?? transaction.description}</strong>
                        <small>{isRefund ? copy.purchaseRefundPayment : copy.purchaseFunding} · {formatDate(transaction.canonical_date, locale)}</small>
                      </span>
                      <strong>{formatCurrency(Math.abs(transaction.amount_minor), transaction.currency, locale)}</strong>
                    </label>
                    {selected ? (
                      <label className="finance-purchase-allocation-field">
                        <span>{copy.purchaseAllocationAmount}</span>
                        <input
                          type="text"
                          inputMode="decimal"
                          autoComplete="off"
                          aria-label={copy.purchaseAllocationAmount}
                          value={allocations[transaction.id]}
                          disabled={saving}
                          onChange={(event) => {
                            setSaveError("");
                            setAllocations((current) => ({ ...current, [transaction.id]: event.target.value }));
                          }}
                        />
                        <span>{detail.currency}</span>
                      </label>
                    ) : null}
                  </li>
                );
              })}
            </ul>
            <div className={cn("finance-purchase-match-remaining", exact && "is-exact")} role="status">
              <strong>{copy.purchaseRemaining}</strong>
              <span>{copy.purchaseFunding}: {formatCurrency(purchaseRemaining, detail.currency, locale, true)}</span>
              {detail.refunded_minor > 0 ? <span>{copy.purchaseRefundPayment}: {formatCurrency(refundRemaining, detail.currency, locale, true)}</span> : null}
            </div>
            {Object.keys(allocations).length > 0 && (!allSelectedValid || !selectedAmountsWithinBounds) ? (
              <p className="finance-purchase-match-error" role="alert">{copy.purchaseAllocationInvalid}</p>
            ) : null}
            {saveError ? <p className="finance-purchase-match-error" role="alert">{saveError}</p> : null}
            <button type="submit" className="button button--primary" disabled={!exact || saving}>
              {saving ? copy.purchaseSavingMatch : copy.purchaseSaveMatch}
            </button>
          </form>
        )}
      </div>
    </details>
  );
}

function PurchaseDetailDialog({
  purchase,
  space,
  availableSpaces,
  focusedLineID,
  detail,
  loadState,
  locale,
  copy,
  onClose,
  onRetry,
  onMatched,
  onAskAbout,
}: {
  purchase: FinancePurchaseSummary;
  space: FinanceSpace;
  availableSpaces: FinanceSpace[];
  focusedLineID: string | null;
  detail: FinancePurchaseDetail | null;
  loadState: PurchaseDetailLoadState;
  locale: FinanceLocale;
  copy: FinanceStrings;
  onClose: () => void;
  onRetry: () => void;
  onMatched: (detail: FinancePurchaseDetail) => void;
  onAskAbout: (question: string) => void;
}) {
  const [captureOpen, setCaptureOpen] = useState(false);
  const [captureLineID, setCaptureLineID] = useState<string | null>(null);
  const [shareLineIDs, setShareLineIDs] = useState<string[]>([]);
  const [shareState, setShareState] = useState<"idle" | "sharing" | "shared" | "error">("idle");
  const [sharePreview, setSharePreview] = useState<FinanceSharePreview | null>(null);
  const [shareMode, setShareMode] = useState<"FULL" | "SELECTED_LINES" | null>(null);
  const focusedLineRef = useRef<HTMLLIElement>(null);
  const captureCopy = locale === "de" ? {
    purchase: "Diesen Einkauf per Text ergänzen",
    line: "Diesen Artikel per Text ergänzen",
    close: "Texterfassung schließen",
  } : {
    purchase: "Update this purchase with text",
    line: "Update this item with text",
    close: "Close text capture",
  };
  const shareCopy = locale === "de" ? {
    title: "Diesen Einkauf mit dem Haushalt teilen",
    detail: "Teile entweder den vollständigen Einkauf oder nur ausgewählte Artikel. Ausgewählte Artikel werden als eigenständiger Haushaltseinkauf mit genau ihrer Summe gespeichert.",
    full: "Vollständigen Einkauf teilen",
    selected: "Ausgewählte Artikel teilen",
    exactOnly: "Nur Artikel mit einem genauen Nettobetrag können einzeln geteilt werden.",
    total: "Geteilte Summe",
    shared: "Mit dem Haushalt geteilt.",
    error: "Der Einkauf konnte nicht geteilt werden.",
    preview: "Freigabe prüfen",
    confirm: "Jetzt teilen",
    cancel: "Abbrechen",
    once: "Einmal geteilt",
  } : {
    title: "Share this purchase with Household",
    detail: "Share either the full purchase or selected items only. Selected items become a standalone Household purchase with exactly their combined total.",
    full: "Share full purchase",
    selected: "Share selected items",
    exactOnly: "Only items with an exact net amount can be shared individually.",
    total: "Shared total",
    shared: "Shared with Household.",
    error: "The purchase could not be shared.",
    preview: "Review sharing",
    confirm: "Share now",
    cancel: "Cancel",
    once: "Shared once",
  };
  const description = [
    formatDate(purchase.purchased_on, locale),
    purchase.order_reference
      ? `${copy.purchaseOrderReference} ${purchase.order_reference}`
      : null,
  ].filter(Boolean).join(" · ");
  const evidenceStatus = detail?.evidence.extraction_status === "UNSUPPORTED"
    ? copy.purchaseExceptionKinds.UNSUPPORTED_SOURCE
    : detail?.evidence.extraction_status === "QUARANTINED"
      ? copy.purchaseExceptionKinds.QUARANTINED_EVIDENCE
      : copy.purchaseEvidenceParsed;
  const selectedShareMinor = detail?.lines.filter((line) => shareLineIDs.includes(line.id)).reduce((sum, line) => sum + (line.line_net_minor ?? 0), 0) ?? 0;

  useEffect(() => {
    if (!focusedLineID || !detail?.lines.some((line) => line.id === focusedLineID)) return;
    focusedLineRef.current?.focus();
  }, [detail, focusedLineID]);

  async function previewPurchaseShare(mode: "FULL" | "SELECTED_LINES") {
    if (!detail || !mode || space.kind !== "personal" || shareState === "sharing" || mode === "SELECTED_LINES" && !shareLineIDs.length) return;
    setShareState("sharing");
    try {
      const preview = await api<FinanceSharePreview>("/finance/shares/preview", { method: "POST", body: JSON.stringify({ kind: "PURCHASE", source_record_id: detail.id, purchase: { mode, line_ids: mode === "SELECTED_LINES" ? shareLineIDs : [] } }) }, true, false);
      setSharePreview(preview);
      setShareMode(mode);
      setShareState("idle");
    } catch {
      setShareState("error");
    }
  }

  async function sharePurchase() {
    const mode = shareMode;
    if (!detail || !mode || space.kind !== "personal" || shareState === "sharing" || mode === "SELECTED_LINES" && !shareLineIDs.length) return;
    setShareState("sharing");
    try {
      const saved = await api<FinanceShare>(`/finance/shares/purchases/${encodeURIComponent(detail.id)}`, { method: "POST", body: JSON.stringify({ mode, line_ids: mode === "SELECTED_LINES" ? shareLineIDs : [] }) }, true, false);
      if (saved.status === "STOPPED") throw new Error(shareCopy.error);
      setShareState("shared");
      setSharePreview(null);
      setShareMode(null);
    } catch {
      setShareState("error");
    }
  }

  return (
    <Modal open onOpenChange={(open) => { if (!open) onClose(); }} title={purchase.merchant} description={description} size="wide">
      {!detail && loadState.status === "error" ? (
        <div className="finance-purchase-detail-state is-error" role="alert">
          <AlertCircle aria-hidden="true" size={28} />
          <h3>{copy.purchaseDetailErrorTitle}</h3>
          <p>{copy.purchaseDetailErrorDetail}</p>
          <button type="button" className="button button--secondary" onClick={onRetry}>
            {copy.retry}
          </button>
        </div>
      ) : !detail ? (
        <div className="finance-purchase-detail-skeleton" aria-label={copy.purchaseDetailLoading} aria-busy="true">
          <div />
          <div />
          <div />
        </div>
      ) : (
        <div className="finance-purchase-detail">
          <section className="finance-purchase-evidence" aria-labelledby="finance-purchase-evidence-title">
            <div>
              <h3 id="finance-purchase-evidence-title">{copy.purchaseEvidenceTitle}</h3>
              <span className={cn(
                "finance-purchase-evidence-status",
                detail.evidence.extraction_status !== "PARSED" && "is-warning",
              )}>
                {evidenceStatus}
              </span>
            </div>
            <p>{copy.purchaseSource}: <span>{financeSourceLabel(detail.source_kind, locale)}</span></p>
            <div className="finance-evidence-actions">
              {detail.evidence.files?.filter((file) => file.storage_status === "STORED").map((file) => <a className="button button--secondary" href={`/api/finance/purchases/evidence/${encodeURIComponent(detail.evidence.id)}/files/${encodeURIComponent(file.id)}`} target="_blank" rel="noreferrer" key={file.id}><ExternalLink aria-hidden="true" size={16} /> {locale === "de" ? "Originalbeleg öffnen" : "Open original evidence"}</a>)}
              <button type="button" className="button button--secondary" onClick={() => onAskAbout(`${locale === "de" ? "Was sollte ich über diesen Einkauf wissen" : "What should I know about this purchase"}: ${purchase.merchant}?`)}><MessageCircleMore aria-hidden="true" size={16} /> {locale === "de" ? "Danach fragen" : "Ask about this"}</button>
            </div>
            {detail.evidence.issues.length ? (
              <ul>
                {detail.evidence.issues.map((issue) => (
                  <li key={`${issue.code}:${issue.message}`}>{issue.message}</li>
                ))}
              </ul>
            ) : null}
            <Suspense fallback={<FinanceDataSkeleton label={copy.loadingData} />}>
              <FinanceDeliveryCalendarAction
                sourceID={detail.evidence.id}
                sourceSpaceID={detail.space_id}
                sourceKind={detail.source_kind}
                lineKind={detail.lines.find((line) => line.line_kind === "delivery")?.line_kind}
                description={`${detail.merchant} ${detail.evidence.email_subject ?? ""} ${detail.lines.map((line) => line.raw_description).join(" ")}`}
                spaces={availableSpaces}
                locale={locale}
              />
            </Suspense>
          </section>

          <dl className="finance-purchase-totals">
            <div><dt>{copy.purchaseSubtotal}</dt><dd>{formatCurrency(detail.lines_subtotal_minor, detail.currency, locale)}</dd></div>
            <div><dt>{copy.purchaseDelivery}</dt><dd>{formatCurrency(detail.shipping_minor, detail.currency, locale)}</dd></div>
            <div><dt>{copy.purchaseDiscount}</dt><dd>{formatCurrency(detail.order_discount_minor, detail.currency, locale)}</dd></div>
            <div><dt>{copy.purchaseVatMemo}</dt><dd>{formatCurrency(detail.vat_included_minor, detail.currency, locale)}</dd></div>
            <div className="is-total"><dt>{copy.purchaseTotal}</dt><dd>{formatCurrency(detail.final_total_minor, detail.currency, locale)}</dd></div>
            <div><dt>{copy.purchaseRefund}</dt><dd>{formatCurrency(detail.refunded_minor, detail.currency, locale)}</dd></div>
            <div className="is-net"><dt>{copy.purchaseNet}</dt><dd>{formatCurrency(detail.behavioural_net_minor, detail.currency, locale)}</dd></div>
          </dl>

          <section className="finance-purchase-detail-section" aria-labelledby="finance-purchase-items-title">
            <header><h3 id="finance-purchase-items-title">{copy.purchaseItems} ({detail.lines.length})</h3><button type="button" className="button button--secondary" onClick={() => { setCaptureLineID(null); setCaptureOpen(true); }}>{captureCopy.purchase}</button></header>
            {detail.lines.length ? (
              <ul className="finance-purchase-line-list">
                {detail.lines.map((line) => (
                  <li
                    key={line.id}
                    ref={line.id === focusedLineID ? focusedLineRef : undefined}
                    className={cn(line.id === focusedLineID && "is-focused")}
                    tabIndex={line.id === focusedLineID ? -1 : undefined}
                  >
                    <div className="finance-purchase-line-heading">
                      <strong>{line.raw_description}</strong>
                      {line.line_net_minor == null ? null : (
                        <span aria-label={`${copy.purchaseLineNet}: ${formatCurrency(line.line_net_minor, detail.currency, locale)}`}>
                          {formatCurrency(line.line_net_minor, detail.currency, locale)}
                        </span>
                      )}
                    </div>
                    <dl>
                      <div><dt>{copy.purchaseQuantity}</dt><dd>{line.quantity_decimal}{line.unit_description ? ` ${line.unit_description}` : ""}</dd></div>
                      {line.unit_price_minor == null ? null : <div><dt>{copy.purchaseUnitPrice}</dt><dd>{formatCurrency(line.unit_price_minor, detail.currency, locale)}</dd></div>}
                      {line.line_gross_minor == null ? null : <div><dt>{copy.purchaseGross}</dt><dd>{formatCurrency(line.line_gross_minor, detail.currency, locale)}</dd></div>}
                      {line.line_discount_minor == null ? null : <div><dt>{copy.purchaseLineDiscount}</dt><dd>{formatCurrency(line.line_discount_minor, detail.currency, locale)}</dd></div>}
                    </dl>
                    <button type="button" className="button button--secondary" onClick={() => { setCaptureLineID(line.id); setCaptureOpen(true); }}>{captureCopy.line}</button>
                  </li>
                ))}
              </ul>
            ) : <p className="finance-purchase-muted">{copy.purchaseNoItems}</p>}
          </section>

          {space.kind === "personal" ? <section className="finance-purchase-share" aria-labelledby="finance-purchase-share-title"><header><div><h3 id="finance-purchase-share-title"><Share2 aria-hidden="true" size={18} /> {shareCopy.title}</h3><p>{shareCopy.detail}</p></div><button type="button" className="button button--secondary" disabled={shareState === "sharing"} onClick={() => void previewPurchaseShare("FULL")}>{shareCopy.full}</button></header><fieldset><legend>{shareCopy.selected}</legend>{detail.lines.map((line) => <label key={line.id}><input type="checkbox" checked={shareLineIDs.includes(line.id)} disabled={line.line_net_minor === null || shareState === "sharing"} onChange={(event) => { setSharePreview(null); setShareMode(null); setShareLineIDs((current) => event.target.checked ? [...current, line.id] : current.filter((id) => id !== line.id)); }} /><span>{line.raw_description}</span><strong>{line.line_net_minor === null ? "—" : formatCurrency(line.line_net_minor, detail.currency, locale)}</strong></label>)}</fieldset><p><span>{shareCopy.total}: </span><strong>{formatCurrency(selectedShareMinor, detail.currency, locale)}</strong></p><small>{shareCopy.exactOnly}</small><button type="button" className="button button--primary" disabled={shareState === "sharing" || !shareLineIDs.length} onClick={() => void previewPurchaseShare("SELECTED_LINES")}>{shareCopy.selected}</button>{sharePreview ? <div className="finance-share-preview" role="dialog" aria-label={shareCopy.preview}><strong>{sharePreview.label}</strong><span>{shareCopy.once}</span>{sharePreview.included.length ? <ul>{sharePreview.included.map((item) => <li key={item}>{item}</li>)}</ul> : null}<div><button type="button" className="button button--primary" disabled={shareState === "sharing"} onClick={() => void sharePurchase()}>{shareCopy.confirm}</button><button type="button" className="button button--secondary" disabled={shareState === "sharing"} onClick={() => { setSharePreview(null); setShareMode(null); }}>{shareCopy.cancel}</button></div></div> : null}{shareState === "shared" ? <p className="form-success" role="status">{shareCopy.shared}</p> : shareState === "error" ? <p className="form-error" role="alert">{shareCopy.error}</p> : null}</section> : null}

          <div className="finance-purchase-detail-columns">
            <section className="finance-purchase-detail-section" aria-labelledby="finance-purchase-refunds-title">
              <h3 id="finance-purchase-refunds-title">{copy.purchaseRefundsTitle}</h3>
              {detail.refunds.length ? (
                <ul className="finance-purchase-compact-list">
                  {detail.refunds.map((refund) => (
                    <li key={refund.id}>
                      <strong>{formatCurrency(refund.amount_minor, detail.currency, locale)}</strong>
                      <span>{refund.quantity_decimal ? `${copy.purchaseQuantity} ${refund.quantity_decimal}` : (locale === "de" ? "Erstatteter Artikel" : "Refunded item")}</span>
                    </li>
                  ))}
                </ul>
              ) : <p className="finance-purchase-muted">{copy.purchaseNoRefunds}</p>}
            </section>

            <section className="finance-purchase-detail-section" aria-labelledby="finance-purchase-tenders-title">
              <h3 id="finance-purchase-tenders-title">{copy.purchaseTendersTitle}</h3>
              {detail.tenders.length ? (
                <ul className="finance-purchase-compact-list">
                  {detail.tenders.map((tender) => (
                    <li key={tender.id}>
                      <strong>{copy.purchaseTenderKinds[tender.tender_kind]} · {formatCurrency(tender.amount_minor, detail.currency, locale)}</strong>
                      {tender.card_suffix ? <span>{copy.purchaseCardEnding} {tender.card_suffix}</span> : null}
                    </li>
                  ))}
                </ul>
              ) : <p className="finance-purchase-muted">{copy.purchaseNoTenders}</p>}
            </section>
          </div>

          <section className="finance-purchase-detail-section" aria-labelledby="finance-purchase-payments-title">
            <h3 id="finance-purchase-payments-title">{copy.purchasePaymentsTitle}</h3>
            {detail.payment_allocations.length ? (
              <ul className="finance-purchase-payment-list">
                {detail.payment_allocations.map((payment) => (
                  <li key={payment.id}>
                    <div>
                      <strong>{formatCurrency(payment.allocated_minor, detail.currency, locale)}</strong>
                      <span>{copy.purchaseMatchMethods[payment.match_method]} · {copy.purchasePaymentStatuses[payment.status]}</span>
                    </div>
                    <dl>
                      {payment.transaction_date ? <div><dt>{copy.purchaseTransactionDate}</dt><dd>{formatDate(payment.transaction_date, locale)}</dd></div> : null}
                      {payment.transaction_amount_minor == null ? null : <div><dt>{copy.purchaseTransactionAmount}</dt><dd>{formatCurrency(payment.transaction_amount_minor, detail.currency, locale)}</dd></div>}
                    </dl>
                  </li>
                ))}
              </ul>
            ) : <p className="finance-purchase-muted">{copy.purchaseNoPayments}</p>}
          </section>
          {detail.match_status !== "MATCHED" && detail.evidence.extraction_status === "PARSED" ? (
            <PurchaseMatchReview detail={detail} locale={locale} copy={copy} onMatched={onMatched} />
          ) : null}
          {captureOpen ? <div className="finance-context-capture"><button type="button" className="button button--secondary" onClick={() => setCaptureOpen(false)}>{captureCopy.close}</button><Suspense fallback={<FinanceDataSkeleton label={copy.loadingData} />}><FinanceCapturePanel spaces={[space]} accounts={[]} locale={locale} conversation={[]} context={{ screen: "purchases", selected_transaction_id: null, selected_purchase_id: detail.id, selected_purchase_line_id: captureLineID, selected_account_id: null }} /></Suspense></div> : null}
        </div>
      )}
    </Modal>
  );
}

function ActivityTransactions({
  data,
  spaces,
  locale,
  copy,
  onAskAbout,
  hasOlder,
  loadingOlder,
  olderError,
  onLoadOlder,
}: {
  data: PurchaseData;
  spaces: FinanceSpace[];
  locale: FinanceLocale;
  copy: FinanceStrings;
  onAskAbout: (question: string) => void;
  hasOlder: boolean;
  loadingOlder: boolean;
  olderError: boolean;
  onLoadOlder: () => void;
}) {
  const [search, setSearch] = useState("");
  const [accountID, setAccountID] = useState("");
  const [direction, setDirection] = useState<"all" | "spending" | "income">("all");
  const [stateFilter, setStateFilter] = useState<"all" | "posted" | "pending">("all");
  const [visibleCount, setVisibleCount] = useState(20);
  const [selectedID, setSelectedID] = useState<string | null>(() => new URLSearchParams(window.location.search).get("transaction"));
  const [correcting, setCorrecting] = useState(false);
  const accountByID = new Map(data.accounts.map((account) => [account.id, account]));
  const selected = selectedID ? data.transactions.find((transaction) => transaction.id === selectedID) ?? null : null;
  const selectedSpace = selected ? spaces.find((space) => space.id === selected.space_id) ?? null : null;

  const filtered = data.transactions.filter((transaction) => {
    const query = search.trim().toLocaleLowerCase();
    const matchesSearch = !query || `${transaction.merchant_text ?? ""} ${transaction.description} ${accountByID.get(transaction.account_id)?.label ?? ""}`.toLocaleLowerCase().includes(query);
    const matchesAccount = !accountID || transaction.account_id === accountID;
    const matchesDirection = direction === "all" || (direction === "spending" ? transaction.amount_minor < 0 : transaction.amount_minor > 0);
    const matchesState = stateFilter === "all" || transaction.state === stateFilter.toUpperCase();
    return matchesSearch && matchesAccount && matchesDirection && matchesState;
  });

  useEffect(() => setVisibleCount(20), [search, accountID, direction, stateFilter]);

  const hasActiveFilter = Boolean(search.trim() || accountID || direction !== "all" || stateFilter !== "all");

  useEffect(() => {
    if (hasActiveFilter && !filtered.length && hasOlder && !loadingOlder && !olderError) {
      onLoadOlder();
    }
  }, [hasActiveFilter, filtered.length, hasOlder, loadingOlder, olderError, onLoadOlder]);

  useEffect(() => {
    if (selectedID && !selected && hasOlder && !loadingOlder) onLoadOlder();
  }, [selectedID, selected, hasOlder, loadingOlder, onLoadOlder]);

  function openTransaction(transaction: FinanceTransaction) {
    setSelectedID(transaction.id);
    setCorrecting(false);
    const url = new URL(window.location.href);
    url.searchParams.set("transaction", transaction.id);
    window.history.replaceState({}, "", url);
  }

  function closeTransaction() {
    setSelectedID(null);
    setCorrecting(false);
    const url = new URL(window.location.href);
    url.searchParams.delete("transaction");
    window.history.replaceState({}, "", url);
  }

  const text = locale === "de" ? {
    title: "Bankaktivität", detail: "Suche und öffne den genauen Eintrag. Jede Ausgabe zeigt ihre Einordnung.", search: "Aktivität durchsuchen", account: "Konto", allAccounts: "Alle Konten", direction: "Richtung", all: "Alle", spending: "Ausgaben", income: "Einnahmen", state: "Status", posted: "Gebucht", pending: "Ausstehend", loadMore: "Mehr laden", source: "Quelle", classification: "Einordnung", correction: "Korrigieren", ask: "Danach fragen", split: "Aufteilung", category: "Kategorie", categories: "Kategorien", standard: "Gewöhnlicher Umsatz", fee: "Gebühr", cash: "Bargeldabhebung", uncategorised: "Nicht kategorisiert", transfer: "Umbuchung",
  } : {
    title: "Bank activity", detail: "Search and open the exact entry. Every spend shows its classification.", search: "Search activity", account: "Account", allAccounts: "All accounts", direction: "Direction", all: "All", spending: "Spending", income: "Income", state: "Status", posted: "Posted", pending: "Pending", loadMore: "Load more", source: "Source", classification: "Classification", correction: "Correct it", ask: "Ask about this", split: "Split", category: "category", categories: "categories", standard: "Standard entry", fee: "Fee", cash: "Cash withdrawal", uncategorised: "Uncategorised", transfer: "Transfer",
  };
  const kindLabels = { CASEY: text.standard, FEE: text.fee, CASH_WITHDRAWAL: text.cash };
  const spendingTypeLabels = locale === "de"
    ? { FIXED: "Fix", FLEXIBLE: "Flexibel", DISCRETIONARY: "Optional", UNCATEGORISED: text.uncategorised }
    : { FIXED: "Fixed", FLEXIBLE: "Flexible", DISCRETIONARY: "Discretionary", UNCATEGORISED: text.uncategorised };
  const neutralRelationTypes = new Set(["INTERNAL_TRANSFER", "CREDIT_CARD_REPAYMENT", "FX_LEG"]);
  const isNeutralMovement = (transaction: FinanceTransaction) => Boolean(transaction.relations?.some((relation) => (
    relation.status === "CONFIRMED" && neutralRelationTypes.has(relation.relation_type)
  )));
  const splitClassification = (transaction: FinanceTransaction) => {
    if (!transaction.splits?.length) return null;
    const categories = new Set(transaction.splits.map((split) => (
      split.category_id ?? `${split.spending_type}:${split.category_name.trim().toLocaleLowerCase()}`
    )));
    const count = categories.size;
    return `${text.split} · ${count} ${count === 1 ? text.category : text.categories}`;
  };
  const selectedIsNeutral = selected ? isNeutralMovement(selected) : false;
  const selectedIsIncome = Boolean(selected && selected.amount_minor >= 0 && !selectedIsNeutral);
  const selectedSplitClassification = selected && !selectedIsNeutral && !selectedIsIncome ? splitClassification(selected) : null;

  return (
    <section className="finance-data-section finance-activity" aria-labelledby="finance-activity-title">
      <header><div><h2 id="finance-activity-title">{text.title}</h2><p>{text.detail}</p></div></header>
      <div className="finance-activity-filters">
        <div className="field"><label htmlFor="finance-activity-search">{text.search}</label><div className="finance-search-field"><Search aria-hidden="true" size={17} /><input id="finance-activity-search" type="search" value={search} onChange={(event) => setSearch(event.target.value)} /></div></div>
        <div className="field"><label htmlFor="finance-activity-account">{text.account}</label><select id="finance-activity-account" value={accountID} onChange={(event) => setAccountID(event.target.value)}><option value="">{text.allAccounts}</option>{data.accounts.map((account) => <option key={account.id} value={account.id}>{account.label}</option>)}</select></div>
        <div className="field"><label htmlFor="finance-activity-direction">{text.direction}</label><select id="finance-activity-direction" value={direction} onChange={(event) => setDirection(event.target.value as typeof direction)}><option value="all">{text.all}</option><option value="spending">{text.spending}</option><option value="income">{text.income}</option></select></div>
        <div className="field"><label htmlFor="finance-activity-state">{text.state}</label><select id="finance-activity-state" value={stateFilter} onChange={(event) => setStateFilter(event.target.value as typeof stateFilter)}><option value="all">{text.all}</option><option value="posted">{text.posted}</option><option value="pending">{text.pending}</option></select></div>
      </div>
      {filtered.length ? (
        <ul className="finance-transaction-list finance-activity-list">
          {filtered.slice(0, visibleCount).map((transaction) => {
            const category = transaction.primary_category_name?.trim() || text.uncategorised;
            const neutralMovement = isNeutralMovement(transaction);
            const splitLabel = transaction.amount_minor < 0 && !neutralMovement ? splitClassification(transaction) : null;
            return (
              <li key={transaction.id}>
                <a
                  href={"/?view=finance&section=activity" + (spaces.find((space) => space.id === transaction.space_id)?.kind === "household" ? "&scope=household" : "") + "&transaction=" + encodeURIComponent(transaction.id)}
                  onClick={(event) => { event.preventDefault(); openTransaction(transaction); }}
                >
                  <div className="finance-transaction-description">
                    <strong>{transaction.merchant_text ?? transaction.description}</strong>
                    <span><time dateTime={transaction.canonical_date}>{formatDate(transaction.canonical_date, locale)}</time>{accountByID.get(transaction.account_id) ? " · " + accountByID.get(transaction.account_id)!.label : ""}</span>
                    {transaction.amount_minor < 0 && !neutralMovement ? <span className={cn("finance-transaction-classification", !splitLabel && transaction.primary_spending_type === "UNCATEGORISED" && "is-uncategorised")}>{splitLabel ?? category}</span> : null}
                  </div>
                  <div className="finance-transaction-value"><strong className={cn(transaction.amount_minor < 0 && "is-spend")}>{formatCurrency(transaction.amount_minor, transaction.currency, locale, true)}</strong><span className={cn("finance-transaction-state", "is-" + transaction.state.toLowerCase())}>{copy.transactionStates[transaction.state]}</span></div>
                  <ChevronRight aria-hidden="true" size={18} />
                </a>
              </li>
            );
          })}
        </ul>
      ) : <EmptyPanel icon={ReceiptText} title={hasOlder || loadingOlder ? (locale === "de" ? "Ältere Aktivität wird durchsucht" : "Searching older activity") : copy.noTransactionsTitle} detail={hasOlder || loadingOlder ? (locale === "de" ? "In der geladenen Aktivität gibt es noch keinen Treffer. Ältere Einträge werden weiter durchsucht." : "There is no match in the loaded activity yet. Older entries are still being searched.") : copy.noTransactionsDetail} />}
      {visibleCount < filtered.length || hasOlder ? <button type="button" className="button button--secondary finance-load-more" disabled={loadingOlder} onClick={() => { setVisibleCount((count) => count + 20); if (hasOlder) onLoadOlder(); }}>{loadingOlder ? (locale === "de" ? "Ältere werden geladen…" : "Loading older…") : text.loadMore}</button> : null}
      {olderError ? <p className="form-error" role="alert">{locale === "de" ? "Ältere Aktivität konnte nicht geladen werden." : "Older activity could not be loaded."}</p> : null}
      {selected && selectedSpace ? (
        <Modal open onOpenChange={(open) => { if (!open) closeTransaction(); }} title={selected.merchant_text ?? selected.description} description={formatDate(selected.canonical_date, locale) + " · " + formatCurrency(selected.amount_minor, selected.currency, locale, true)} size="wide">
          <div className="finance-activity-detail">
            <dl>
              <div><dt>{text.account}</dt><dd>{accountByID.get(selected.account_id)?.label ?? text.allAccounts}</dd></div>
              <div><dt>{text.source}</dt><dd>{financeSourceLabel(selected.source_kind, locale)}</dd></div>
              <div><dt>{text.classification}</dt><dd><strong>{selectedIsNeutral ? text.transfer : selectedIsIncome ? text.income : selectedSplitClassification ?? (selected.primary_category_name?.trim() || text.uncategorised)}</strong><span>{selectedIsNeutral || selectedIsIncome ? "" : `${selectedSplitClassification ? "" : `${spendingTypeLabels[selected.primary_spending_type]} · `}${kindLabels[selected.transaction_kind]} · ${copy.transactionStates[selected.state]}`}</span></dd></div>
              {!selectedIsNeutral && !selectedIsIncome ? selected.splits?.map((split, index) => {
                const category = split.category_name.trim() || text.uncategorised;
                return <div key={split.id}><dt>{text.split} {index + 1}</dt><dd className="finance-activity-split"><div><strong>{category}</strong><strong>{formatCurrency(split.amount_minor, selected.currency, locale, true)}</strong></div><span>{spendingTypeLabels[split.spending_type]}{split.label ? ` · ${split.label}` : ""}</span></dd></div>;
              }) : null}
            </dl>
            <div className="finance-activity-actions">
              <button type="button" className="button button--secondary" onClick={() => setCorrecting((open) => !open)}>{text.correction}</button>
              <button type="button" className="button button--secondary" onClick={() => onAskAbout((locale === "de" ? "Was sollte ich über diesen Umsatz wissen" : "What should I know about this transaction") + ": " + (selected.merchant_text ?? selected.description) + "?")}><MessageCircleMore aria-hidden="true" size={16} /> {text.ask}</button>
              <FinanceShareButton kind="transactions" recordID={selected.id} space={selectedSpace} locale={locale} />
            </div>
            {correcting ? <Suspense fallback={<FinanceDataSkeleton label={copy.loadingData} />}><FinanceCapturePanel spaces={[selectedSpace]} accounts={data.accounts.filter((account) => account.space_id === selected.space_id)} locale={locale} conversation={[]} context={{ screen: "transactions", selected_transaction_id: selected.id, selected_purchase_id: null, selected_purchase_line_id: null, selected_account_id: selected.account_id }} /></Suspense> : null}
          </div>
        </Modal>
      ) : null}
    </section>
  );
}

function PurchasesView({
  data,
  spaces,
  availableSpaces,
  selectionKey,
  locale,
  copy,
  onMatched,
  onAskAbout,
  focusEvidenceID,
  focusReviewLineID,
  onReviewFocusConsumed,
  hasOlderPurchases,
  loadingOlderPurchases,
  olderPurchasesError,
  onLoadOlderPurchases,
}: {
  data: PurchaseData;
  spaces: FinanceSpace[];
  availableSpaces: FinanceSpace[];
  selectionKey: string;
  locale: FinanceLocale;
  copy: FinanceStrings;
  onMatched: (detail: FinancePurchaseDetail) => void;
  onAskAbout: (question: string) => void;
  focusEvidenceID: string | null;
  focusReviewLineID: string | null;
  onReviewFocusConsumed: () => void;
  hasOlderPurchases: boolean;
  loadingOlderPurchases: boolean;
  olderPurchasesError: boolean;
  onLoadOlderPurchases: () => void;
}) {
  const [selectedPurchaseID, setSelectedPurchaseID] = useState<string | null>(null);
  const [detailCache, setDetailCache] = useState<Record<string, FinancePurchaseDetail>>({});
  const [detailLoadState, setDetailLoadState] = useState<PurchaseDetailLoadState>({ status: "idle" });
  const [detailRetryKey, setDetailRetryKey] = useState(0);
  const [focusedEvidence, setFocusedEvidence] = useState<FinancePurchaseEvidence | null>(null);
  const [evidenceError, setEvidenceError] = useState(false);
  const focusedEvidenceRef = useRef<HTMLElement>(null);
  const [purchaseSearch, setPurchaseSearch] = useState("");
  const [purchaseMatch, setPurchaseMatch] = useState<"ALL" | FinancePurchaseSummary["match_status"]>("ALL");
  const [visiblePurchases, setVisiblePurchases] = useState(20);
  const [reviewOpen, setReviewOpen] = useState(Boolean(focusReviewLineID));
  const selectedDetail = selectedPurchaseID ? detailCache[selectedPurchaseID] ?? null : null;
  const selectedPurchase = selectedPurchaseID
    ? data.purchases.find((purchase) => purchase.id === selectedPurchaseID) ?? selectedDetail
    : null;
  const allowedSpaceIDs = spaces.map((space) => space.id);
  const spaceNames = new Map(spaces.map((space) => [space.id, space.name]));
  const focusedEvidenceID = focusEvidenceID;
  const exceptions = [...data.exceptions].sort((left, right) => (
    Number(right.source_id === focusedEvidenceID) - Number(left.source_id === focusedEvidenceID)
      || Math.abs(right.amount_minor ?? 0) - Math.abs(left.amount_minor ?? 0)
      || right.priority - left.priority
      || right.created_at.localeCompare(left.created_at)
  ));
  const purchaseQuery = purchaseSearch.trim().toLocaleLowerCase();
  const filteredPurchases = data.purchases.filter((purchase) => {
    const searchable = `${purchase.merchant} ${(purchase.item_descriptions ?? []).join(" ")}`.toLocaleLowerCase();
    return (!purchaseQuery || searchable.includes(purchaseQuery))
      && (purchaseMatch === "ALL" || purchase.match_status === purchaseMatch);
  });

  useEffect(() => setVisiblePurchases(20), [purchaseSearch, purchaseMatch]);

  useEffect(() => {
    if (focusReviewLineID) setReviewOpen(true);
  }, [focusReviewLineID]);

  const hasPurchaseFilter = Boolean(purchaseSearch.trim() || purchaseMatch !== "ALL");

  useEffect(() => {
    if (hasPurchaseFilter && !filteredPurchases.length && hasOlderPurchases && !loadingOlderPurchases && !olderPurchasesError) {
      onLoadOlderPurchases();
    }
  }, [hasPurchaseFilter, filteredPurchases.length, hasOlderPurchases, loadingOlderPurchases, olderPurchasesError, onLoadOlderPurchases]);

  useEffect(() => {
    if (focusedEvidence) focusedEvidenceRef.current?.focus();
  }, [focusedEvidence]);

  useEffect(() => {
    const query = new URLSearchParams(window.location.search);
    const purchaseID = query.get("purchase");
    if (purchaseID && data.purchases.some((purchase) => purchase.id === purchaseID)) {
      setSelectedPurchaseID(purchaseID);
    }
    if (!focusedEvidenceID) { setFocusedEvidence(null); setEvidenceError(false); return; }
    const controller = new AbortController();
    let active = true;
    setEvidenceError(false);
    const detailPath = `/finance/purchases/by-source/${encodeURIComponent(focusedEvidenceID)}`;
    api<FinancePurchaseDetail>(detailPath, { signal: controller.signal }, true, false)
      .then((detail) => {
        if (!active || !allowedSpaceIDs.includes(detail.space_id) || detail.evidence.space_id !== detail.space_id) return;
        setDetailCache((current) => ({ ...current, [detail.id]: detail }));
        setSelectedPurchaseID(detail.id);
        if (focusedEvidenceID) setFocusedEvidence(detail.evidence);
      })
      .catch(async (error: unknown) => {
        if (!active || isAbortError(error)) return;
        if (focusedEvidenceID && error instanceof ApiError && error.status === 404) {
          try {
            const evidence = await api<FinancePurchaseEvidence>(`/finance/purchases/evidence/${encodeURIComponent(focusedEvidenceID)}`, { signal: controller.signal }, true, false);
            if (active && allowedSpaceIDs.includes(evidence.space_id)) setFocusedEvidence(evidence);
            return;
          } catch (fallbackError) {
            if (!active || isAbortError(fallbackError)) return;
          }
        }
        if (focusedEvidenceID) setEvidenceError(true);
      });
    return () => { active = false; controller.abort(); };
  }, [focusedEvidenceID, selectionKey, data.purchases]);

  useEffect(() => {
    if (!selectedPurchase || selectedDetail) return;
    const controller = new AbortController();
    let active = true;
    const purchaseID = selectedPurchase.id;
    setDetailLoadState({ status: "loading", purchaseID });
    api<FinancePurchaseDetail>(
      `/finance/purchases/${encodeURIComponent(purchaseID)}`,
      { signal: controller.signal },
      true,
      false,
    )
      .then((detail) => {
        if (!active) return;
        if (
          detail.id !== purchaseID
          || !allowedSpaceIDs.includes(detail.space_id)
          || detail.evidence.space_id !== detail.space_id
        ) {
          setDetailLoadState({ status: "error", purchaseID });
          return;
        }
        setDetailCache((current) => ({ ...current, [purchaseID]: detail }));
        setDetailLoadState({ status: "idle" });
      })
      .catch((error: unknown) => {
        if (!active || isAbortError(error)) return;
        setDetailLoadState({ status: "error", purchaseID });
      });
    return () => {
      active = false;
      controller.abort();
    };
  }, [selectedPurchase, selectedDetail, detailRetryKey, selectionKey]);

  return (
    <div className="finance-section-content">
      {exceptions.length ? (
        <section className="finance-data-section" aria-labelledby="finance-purchase-exceptions-title">
          <header>
            <div>
              <h2 id="finance-purchase-exceptions-title">{copy.purchaseExceptionsTitle}</h2>
              <p>{copy.purchaseExceptionsDetail}</p>
            </div>
          </header>
          <ul className="finance-purchase-exception-list">
            {exceptions.map((exception) => (
              <li key={exception.id} className={cn(exception.source_id === focusedEvidenceID && "is-focused")}>
                <div>
                  <span className={cn(
                    "finance-purchase-exception-kind",
                    (exception.exception_kind === "UNSUPPORTED_SOURCE" || exception.exception_kind === "QUARANTINED_EVIDENCE") && "is-warning",
                  )}>
                    {copy.purchaseExceptionKinds[exception.exception_kind]}
                  </span>
                  <strong>{exception.title}</strong>
                  <p>{exception.detail}</p>
                </div>
                <div className="finance-purchase-exception-meta">
                  {exception.amount_minor != null && exception.currency
                    ? <strong>{formatCurrency(exception.amount_minor, exception.currency, locale)}</strong>
                    : null}
                  <span>{spaceNames.get(exception.space_id)}</span>
                </div>
              </li>
            ))}
          </ul>
        </section>
      ) : null}

      {focusedEvidence ? <section ref={focusedEvidenceRef} className="finance-focused-evidence" aria-labelledby="finance-focused-evidence-title" tabIndex={-1}><div><span>{locale === "de" ? "Aus Kalender geöffnet" : "Opened from Calendar"}</span><h2 id="finance-focused-evidence-title">{financeSourceLabel(focusedEvidence.source_kind, locale)}</h2><p>{focusedEvidence.email_subject ?? (locale === "de" ? "Geprüfte Liefer- oder Einkaufsquelle" : "Reviewed delivery or purchase source")}</p></div><div className="finance-evidence-actions">{focusedEvidence.files?.filter((file) => file.storage_status === "STORED").map((file) => <a className="button button--secondary" key={file.id} href={`/api/finance/purchases/evidence/${encodeURIComponent(focusedEvidence.id)}/files/${encodeURIComponent(file.id)}`} target="_blank" rel="noreferrer"><ExternalLink aria-hidden="true" size={16} /> {locale === "de" ? "Original öffnen" : "Open original evidence"}</a>)}</div><Suspense fallback={<FinanceDataSkeleton label={copy.loadingData} />}><FinanceDeliveryCalendarAction sourceID={focusedEvidence.id} sourceSpaceID={focusedEvidence.space_id} sourceKind={focusedEvidence.source_kind} description={focusedEvidence.email_subject ?? ""} spaces={availableSpaces} locale={locale} /></Suspense></section> : evidenceError ? <p className="form-error" role="alert">{locale === "de" ? "Diese Finanzquelle konnte nicht geöffnet werden." : "That Finance evidence could not be opened."}</p> : null}

      <details
        className="finance-calm-details finance-activity-review"
        open={reviewOpen}
        onToggle={(event) => setReviewOpen(event.currentTarget.open)}
      >
        <summary>
          <span><strong>{locale === "de" ? "Einkäufe prüfen" : "Review purchases"}</strong><small>{locale === "de" ? "Nur öffnen, wenn etwas eingeordnet werden muss" : "Open when a purchase needs your input"}</small></span>
          <ChevronRight aria-hidden="true" size={18} />
        </summary>
        {reviewOpen ? (
          <Suspense fallback={<FinanceDataSkeleton label={copy.purchasesLoading} />}>
            <FinancePurchaseReviewView
              spaces={spaces}
              locale={locale}
              focusLineID={focusReviewLineID}
              onFocusConsumed={onReviewFocusConsumed}
            />
          </Suspense>
        ) : null}
      </details>

      <section className="finance-data-section" aria-labelledby="finance-purchases-title">
        <header>
          <div>
            <h2 id="finance-purchases-title">{copy.purchasesTitle}</h2>
            <p>{copy.purchasesDetail}</p>
          </div>
        </header>
        {data.purchases.length ? (
          <>
          <div className="finance-purchase-filters">
            <div className="field">
              <label htmlFor="finance-purchase-search">{locale === "de" ? "Händler oder Artikel suchen" : "Search merchant or item"}</label>
              <div className="finance-search-field"><Search aria-hidden="true" size={17} /><input id="finance-purchase-search" type="search" value={purchaseSearch} onChange={(event) => setPurchaseSearch(event.target.value)} /></div>
            </div>
            <div className="field">
              <label htmlFor="finance-purchase-match-filter">{locale === "de" ? "Zahlungsabgleich" : "Payment match"}</label>
              <select id="finance-purchase-match-filter" value={purchaseMatch} onChange={(event) => setPurchaseMatch(event.target.value as typeof purchaseMatch)}>
                <option value="ALL">{locale === "de" ? "Alle" : "All"}</option>
                <option value="MATCHED">{copy.purchaseMatchStatuses.MATCHED}</option>
                <option value="PARTIAL">{copy.purchaseMatchStatuses.PARTIAL}</option>
                <option value="UNMATCHED">{copy.purchaseMatchStatuses.UNMATCHED}</option>
              </select>
            </div>
          </div>
          {filteredPurchases.length ? <ul className="finance-purchase-list">
            {filteredPurchases.slice(0, visiblePurchases).map((purchase) => {
              const detail = detailCache[purchase.id];
              return (
                <li key={purchase.id}>
                  <button
                    type="button"
                    onClick={() => { setSelectedPurchaseID(purchase.id); const url = new URL(window.location.href); url.searchParams.set("purchase", purchase.id); window.history.replaceState({}, "", url); }}
                    aria-label={`${copy.openPurchase}: ${purchase.merchant}`}
                  >
                    <div className="finance-purchase-heading">
                      <div>
                        <strong>{purchase.merchant}</strong>
                        <span><time dateTime={purchase.purchased_on}>{formatDate(purchase.purchased_on, locale)}</time> · {spaceNames.get(purchase.space_id)}</span>
                      </div>
                      <span className={cn(
                        "finance-purchase-match",
                        purchase.match_status === "PARTIAL" && "is-partial",
                        purchase.match_status === "UNMATCHED" && "is-unmatched",
                      )}>
                        {copy.purchaseMatchStatuses[purchase.match_status]}
                      </span>
                    </div>
                    <dl className="finance-purchase-row-totals">
                      <div><dt>{copy.purchaseTotal}</dt><dd>{formatCurrency(purchase.final_total_minor, purchase.currency, locale)}</dd></div>
                      <div><dt>{copy.purchaseRefund}</dt><dd>{formatCurrency(purchase.refunded_minor, purchase.currency, locale)}</dd></div>
                      <div><dt>{copy.purchaseNet}</dt><dd>{formatCurrency(purchase.behavioural_net_minor, purchase.currency, locale)}</dd></div>
                      {detail ? <div><dt>{copy.purchaseItems}</dt><dd>{detail.lines.length} {detail.lines.length === 1 ? copy.purchaseItem : copy.purchaseItemsCount}</dd></div> : null}
                    </dl>
                    <ChevronRight aria-hidden="true" size={20} />
                  </button>
                </li>
              );
            })}
          </ul> : <p className="finance-plan-empty">{hasOlderPurchases || loadingOlderPurchases ? (locale === "de" ? "Noch kein Treffer in den geladenen Einkäufen. Ältere Einkäufe werden durchsucht." : "No match in the loaded purchases yet. Older purchases are still being searched.") : (locale === "de" ? "Keine passenden Einkäufe gefunden." : "No matching purchases found.")}</p>}
          {visiblePurchases < filteredPurchases.length || hasOlderPurchases ? <button type="button" className="button button--secondary finance-load-more" disabled={loadingOlderPurchases} onClick={() => { setVisiblePurchases((count) => count + 20); if (hasOlderPurchases) onLoadOlderPurchases(); }}>{loadingOlderPurchases ? (locale === "de" ? "Ältere werden geladen…" : "Loading older…") : (locale === "de" ? "Mehr laden" : "Load more")}</button> : null}
          {olderPurchasesError ? <p className="form-error" role="alert">{locale === "de" ? "Ältere Einkäufe konnten nicht geladen werden." : "Older purchases could not be loaded."}</p> : null}
          </>
        ) : (
          <EmptyPanel icon={ReceiptText} title={copy.purchasesEmptyTitle} detail={copy.purchasesEmptyDetail} />
        )}
      </section>

      {selectedPurchase ? (
        <PurchaseDetailDialog
          purchase={selectedPurchase}
          space={spaces.find((space) => space.id === selectedPurchase.space_id)!}
          availableSpaces={availableSpaces}
          focusedLineID={null}
          detail={selectedDetail}
          loadState={detailLoadState}
          locale={locale}
          copy={copy}
          onClose={() => { setSelectedPurchaseID(null); const url = new URL(window.location.href); url.searchParams.delete("purchase"); url.searchParams.delete("line"); url.searchParams.delete("evidence"); window.history.replaceState({}, "", url); }}
          onRetry={() => setDetailRetryKey((key) => key + 1)}
          onMatched={(updated) => {
            setDetailCache((current) => ({ ...current, [updated.id]: updated }));
            onMatched(updated);
          }}
          onAskAbout={onAskAbout}
        />
      ) : null}
    </div>
  );
}

function ExploreView({
  data,
  spaces,
  scope,
  locale,
  copy,
  onAskAbout,
}: {
  data: FinanceData;
  spaces: FinanceSpace[];
  scope: FinanceScope;
  locale: FinanceLocale;
  copy: FinanceStrings;
  onAskAbout: (question: string) => void;
}) {
  return (
    <div className="finance-section-content">
      <Suspense fallback={<FinanceDataSkeleton label={copy.loadingData} />}>
        <FinanceAnalysisView
          accounts={data.accounts}
          transactions={data.transactions}
          spaces={spaces}
          scope={scope}
          locale={locale}
          onAskAbout={onAskAbout}
        />
      </Suspense>
    </div>
  );
}

function FinanceDataSkeleton({ label }: { label: string }) {
  return (
    <div className="finance-data-skeleton" aria-label={label} aria-busy="true">
      <div />
      <div />
      <div />
    </div>
  );
}

export function FinanceView({
  hasFamilyAccount,
  online,
  section,
  scope,
  onSectionChange,
  onScopeChange,
  onOpenRenewals = () => undefined,
  onBankRedirect,
  members = [],
  revision = 0,
  onDataChanged = () => undefined,
  notify = () => undefined,
  locale = financeLocale(),
  preferenceOwner = "browser",
}: {
  hasFamilyAccount: boolean;
  online: boolean;
  section: FinanceSection;
  scope: FinanceScope;
  onSectionChange: (section: FinanceSection) => void;
  onScopeChange: (scope: FinanceScope) => void;
  onOpenRenewals?: () => void;
  onBankRedirect?: (url: string) => void;
  members?: FamilyMember[];
  revision?: number;
  onDataChanged?: () => void;
  notify?: (message: string) => void;
  locale?: FinanceLocale;
  simpleDefault?: boolean;
  preferenceOwner?: string;
}) {
  const copy = getFinanceStrings(locale);
  const scopeStorageKey = `hausklar:finance:${preferenceOwner}:scope`;
  const [spacesState, setSpacesState] = useState<SpacesLoadState>({ status: "idle" });
  const [overviewState, setOverviewState] = useState<OverviewLoadState>({ status: "idle" });
  const [dataState, setDataState] = useState<DataLoadState>({ status: "idle" });
  const [purchaseState, setPurchaseState] = useState<PurchaseLoadState>({ status: "idle" });
  const [spacesRetryKey, setSpacesRetryKey] = useState(0);
  const [overviewRetryKey, setOverviewRetryKey] = useState(0);
  const [dataRetryKey, setDataRetryKey] = useState(0);
  const [purchaseRetryKey, setPurchaseRetryKey] = useState(0);
  const [planNotice, setPlanNotice] = useState("");
  const [consentState, setConsentState] = useState<ConsentLoadState>({ status: "idle" });
  const [consentRetryKey, setConsentRetryKey] = useState(0);
  const [consentWorkingSpaceID, setConsentWorkingSpaceID] = useState<string | null>(null);
  const [consentActionError, setConsentActionError] = useState("");
  const [question, setQuestion] = useState("");
  const [activityReviewLineID, setActivityReviewLineID] = useState<string | null>(() => new URLSearchParams(window.location.search).get("line"));
  const [activityEvidenceID, setActivityEvidenceID] = useState<string | null>(() => new URLSearchParams(window.location.search).get("evidence"));
  const [advancedReviewOpen, setAdvancedReviewOpen] = useState(() => {
    const query = new URLSearchParams(window.location.search);
    return query.has("line") || query.has("evidence") || query.has("purchase");
  });
  const [dataQualityOpen, setDataQualityOpen] = useState(false);
  const [answerState, setAnswerState] = useState<CoachAnswerState>({ status: "idle" });
  const [exchanges, setExchanges] = useState<CoachExchange[]>([]);
  const [sharedGoals, setSharedGoals] = useState<FinanceGoal[]>([]);
  const scopeRestored = useRef(false);
  const previousRevision = useRef(revision);
  const [bankCallback, setBankCallback] = useState<"connected" | "cancelled" | "failed" | null>(() => {
    const marker = new URLSearchParams(window.location.search).get("bank");
    return marker === "connected" || marker === "cancelled" || marker === "failed" ? marker : null;
  });
  const commitmentDeepLinkID = new URLSearchParams(window.location.search).get("commitment");
  const selectedSpaces = spacesState.status === "ready"
    ? selectedFinanceSpaces(spacesState.spaces, scope)
    : [];
  const selectionKey = JSON.stringify(selectedSpaces.map((space) => space.id));
  const moreSelected = section === "more" || moreSections.some(({ id }) => id === section);
  const topLabels: Record<string, string> = locale === "de"
    ? { overview: "Übersicht", goals: "Ziele", activity: "Aktivität" }
    : { overview: "Overview", goals: "Goals", activity: "Activity" };
  const moreLabels: Record<string, string> = locale === "de"
    ? { planning: "Prognose und Verpflichtungen", coach: "Finanz-Coach", explore: "Analyse", assets: "Vermögen", settings: "Einstellungen", setup: "Konten und Einrichtung" }
    : { planning: "Forecast and commitments", coach: "Finance coach", explore: "Analysis", assets: "Assets", settings: "Settings", setup: "Accounts and setup" };
  const personalSpace = spacesState.status === "ready"
    ? spacesState.spaces.find((space) => space.kind === "personal" && space.is_default)
      ?? spacesState.spaces.find((space) => space.kind === "personal")
      ?? null
    : null;
  const householdSpace = spacesState.status === "ready"
    ? spacesState.spaces.find((space) => space.kind === "household") ?? null
    : null;
  const planSpaces = selectedSpaces;

  useEffect(() => {
    preloadFinanceSection(section);
  }, [section]);

  useEffect(() => {
    if (previousRevision.current === revision) return;
    previousRevision.current = revision;
    invalidateFinanceRequestCache();
    // Reload spaces first; the selected-space data effects follow from the
    // resulting scope-safe space list without starting duplicate requests.
    setSpacesRetryKey((key) => key + 1);
  }, [revision]);

  useEffect(() => setPlanNotice(""), [selectionKey]);

  useEffect(() => {
    if (spacesState.status !== "ready" || scopeRestored.current) return;
    scopeRestored.current = true;
    const stored = storedFinanceChoice(scopeStorageKey);
    if (stored === "household" && scope !== "household") {
      onScopeChange("household");
      return;
    }
    rememberFinanceChoice(scopeStorageKey, scope);
  }, [spacesState, scope, scopeStorageKey, onScopeChange]);

  useEffect(() => {
    if (!scopeRestored.current) return;
    rememberFinanceChoice(scopeStorageKey, scope);
  }, [scope, scopeStorageKey]);

  useEffect(() => {
    if (scope !== "mine" || !householdSpace || !["coach", "goals", "planning"].includes(section)) {
      setSharedGoals([]);
      return;
    }
    const controller = new AbortController();
    let active = true;
    api<FinanceGoal[]>(
      `/finance/goals?space_id=${encodeURIComponent(householdSpace.id)}`,
      { signal: controller.signal },
      true,
      false,
    )
      .then((goals) => {
        if (!active) return;
        setSharedGoals(goals
          .filter((goal) => goal.space_id === householdSpace.id && goal.status === "ACTIVE")
          .sort((left, right) => left.deadline.localeCompare(right.deadline)));
      })
      .catch((error: unknown) => {
        if (!active || isAbortError(error)) return;
        setSharedGoals([]);
      });
    return () => {
      active = false;
      controller.abort();
    };
  }, [online, scope, section, householdSpace?.id]);

  function changeScope(nextScope: FinanceScope) {
    scopeRestored.current = true;
    rememberFinanceChoice(scopeStorageKey, nextScope);
    onScopeChange(nextScope);
  }

  useEffect(() => {
    const query = new URLSearchParams(window.location.search);
    setActivityReviewLineID(query.get("line"));
    setActivityEvidenceID(query.get("evidence"));
    if (section === "more" && (query.has("line") || query.has("evidence") || query.has("purchase"))) {
      setAdvancedReviewOpen(true);
    }
  }, [section, selectionKey]);

  useEffect(() => {
    if (!bankCallback) return;
    const url = new URL(window.location.href);
    url.searchParams.delete("bank");
    url.searchParams.delete("connection");
    window.history.replaceState({}, "", url);
  }, [bankCallback]);

  useEffect(() => {
    setQuestion("");
    setAnswerState({ status: "idle" });
    setExchanges([]);
  }, [scope]);

  useEffect(() => {
    if (!hasFamilyAccount || !online) {
      setSpacesState({ status: "idle" });
      setOverviewState({ status: "idle" });
      setDataState({ status: "idle" });
      return;
    }
    const controller = new AbortController();
    let active = true;
    setSpacesState({ status: "loading" });
    api<FinanceSpace[]>("/finance/spaces", { signal: controller.signal }, true, false)
      .then((spaces) => {
        if (active) setSpacesState({ status: "ready", spaces });
      })
      .catch((error: unknown) => {
        if (!active || isAbortError(error)) return;
        setSpacesState({ status: "error" });
      });
    return () => {
      active = false;
      controller.abort();
    };
  }, [hasFamilyAccount, online, spacesRetryKey]);

  useEffect(() => {
    if (!hasFamilyAccount || section !== "overview" || spacesState.status !== "ready") {
      setOverviewState({ status: "idle" });
      return;
    }
    const controller = new AbortController();
    let active = true;
    setOverviewState({ status: "loading", scope });
    api<FinanceOverview>(
      `/finance/overview?scope=${encodeURIComponent(scope)}`,
      { signal: controller.signal },
      true,
      false,
    )
      .then((overview) => {
        if (!active) return;
        setOverviewState(overview.scope === scope
          ? { status: "ready", scope, data: overview }
          : { status: "error", scope });
      })
      .catch((error: unknown) => {
        if (!active || isAbortError(error)) return;
        setOverviewState({ status: "error", scope });
      });
    return () => {
      active = false;
      controller.abort();
    };
  }, [hasFamilyAccount, online, section, spacesState, scope, overviewRetryKey, revision]);

  useEffect(() => {
    if (!hasFamilyAccount || section === "overview" || section === "activity" || section === "setup" || section === "more" || spacesState.status !== "ready") {
      setDataState({ status: "idle" });
      return;
    }
    const requestSpaces = selectedFinanceSpaces(spacesState.spaces, scope);
    const requestKey = JSON.stringify(requestSpaces.map((space) => space.id));
    if (!requestSpaces.length) {
      setDataState({ status: "idle" });
      return;
    }
    const controller = new AbortController();
    let active = true;
    setDataState({ status: "loading", selectionKey: requestKey });
    Promise.all(requestSpaces.map(async (requestSpace): Promise<FinanceSpaceData> => {
      const spaceID = encodeURIComponent(requestSpace.id);
      const ownerAware = scope === "mine" && requestSpace.kind === "household" ? "&exclude_own_shared_copies=true" : "";
      const needsSummary = section === "coach" || section === "goals" || section === "planning" || section === "explore" || section === "settings";
      const needsTransactions = section === "explore";
      const needsCommitments = section === "coach" || section === "goals" || section === "planning";
      const needsReserves = section === "goals" || section === "planning";
      const needsGoals = section === "coach" || section === "goals" || section === "planning";
      const [accounts, summary, transactions, commitments, reserves, goals] = await Promise.all([
        api<FinanceAccount[]>(
          `/finance/accounts?space_id=${spaceID}${ownerAware}`,
          { signal: controller.signal },
          true,
          false,
        ),
        needsSummary ? api<FinanceLedgerSummary>(
          `/finance/summary?space_id=${spaceID}${ownerAware}`,
          { signal: controller.signal },
          true,
          false,
        ) : Promise.resolve({ space_id: requestSpace.id, data_through_at: null, currencies: [] }),
        needsTransactions ? api<FinanceTransaction[]>(
          `/finance/transactions?space_id=${spaceID}&limit=${RECENT_TRANSACTION_LIMIT}${ownerAware}`,
          { signal: controller.signal },
          true,
          false,
        ) : Promise.resolve([]),
        needsCommitments ? api<FinanceCommitment[]>(
          `/finance/commitments?space_id=${spaceID}${ownerAware}`,
          { signal: controller.signal },
          true,
          false,
        ) : Promise.resolve([]),
        needsReserves ? api<FinanceReserve[]>(
          `/finance/reserves?space_id=${spaceID}${ownerAware}`,
          { signal: controller.signal },
          true,
          false,
        ) : Promise.resolve([]),
        needsGoals ? api<FinanceGoal[]>(
          `/finance/goals?space_id=${spaceID}${ownerAware}`,
          { signal: controller.signal },
          true,
          false,
        ) : Promise.resolve([]),
      ]);
      return { accounts, summary, transactions, commitments, reserves, goals };
    }))
      .then((results) => {
        if (active) {
          setDataState({
            status: "ready",
            selectionKey: requestKey,
            data: mergeFinanceSpaceData(results),
          });
        }
      })
      .catch((error: unknown) => {
        if (!active || isAbortError(error)) return;
        setDataState({ status: "error", selectionKey: requestKey });
      });
    return () => {
      active = false;
      controller.abort();
    };
  }, [hasFamilyAccount, online, section, spacesState, scope, dataRetryKey]);

  useEffect(() => {
    if (!hasFamilyAccount || !["activity", "more"].includes(section) || (section === "more" && !advancedReviewOpen && !dataQualityOpen) || spacesState.status !== "ready") {
      setPurchaseState({ status: "idle" });
      return;
    }
    const requestSpaces = selectedFinanceSpaces(spacesState.spaces, scope);
    const requestKey = JSON.stringify(requestSpaces.map((space) => space.id));
    if (!requestSpaces.length) {
      setPurchaseState({ status: "idle" });
      return;
    }
    const controller = new AbortController();
    let active = true;
    setPurchaseState({ status: "loading", selectionKey: requestKey });
    Promise.all(requestSpaces.map(async (requestSpace): Promise<PurchaseSpaceData> => {
      const spaceID = encodeURIComponent(requestSpace.id);
      const ownerAware = scope === "mine" && requestSpace.kind === "household" ? "&exclude_own_shared_copies=true" : "";
      const needsReviewData = section === "more";
      const [accounts, transactions, purchases, exceptions] = await Promise.all([
        api<FinanceAccount[]>(
          `/finance/accounts?space_id=${spaceID}${ownerAware}`,
          { signal: controller.signal },
          true,
          false,
        ),
        api<FinanceTransaction[]>(
          `/finance/transactions?space_id=${spaceID}&offset=0&limit=200${ownerAware}`,
          { signal: controller.signal },
          true,
          false,
        ),
        needsReviewData ? api<FinancePurchaseSummary[]>(
          `/finance/purchases?space_id=${spaceID}&offset=0&limit=50${ownerAware}`,
          { signal: controller.signal },
          true,
          false,
        ) : Promise.resolve([]),
        needsReviewData ? api<FinancePurchaseException[]>(
          `/finance/purchases/inbox?space_id=${spaceID}&offset=0&limit=50${ownerAware}`,
          { signal: controller.signal },
          true,
          false,
        ) : Promise.resolve([]),
      ]);
      return {
        spaceID: requestSpace.id,
        transactionPage: {
          nextOffset: transactions.length,
          hasMore: transactions.length === 200,
          ownerAware,
        },
        purchasePage: {
          nextOffset: purchases.length,
          hasMore: purchases.length === 50,
          ownerAware,
        },
        accounts: accounts.filter((account) => account.space_id === requestSpace.id),
        transactions: transactions.filter((transaction) => transaction.space_id === requestSpace.id),
        purchases: purchases.filter((purchase) => purchase.space_id === requestSpace.id),
        exceptions: exceptions.filter((exception) => exception.space_id === requestSpace.id),
      };
    }))
      .then((results) => {
        if (!active) return;
        setPurchaseState({
          status: "ready",
          selectionKey: requestKey,
          data: mergePurchaseData(results),
          transactionPages: Object.fromEntries(results.map((result) => [result.spaceID, result.transactionPage])),
          purchasePages: Object.fromEntries(results.map((result) => [result.spaceID, result.purchasePage])),
          loadingOlder: false,
          olderError: false,
          loadingOlderPurchases: false,
          olderPurchasesError: false,
        });
      })
      .catch((error: unknown) => {
        if (!active || isAbortError(error)) return;
        setPurchaseState({ status: "error", selectionKey: requestKey });
      });
    return () => {
      active = false;
      controller.abort();
    };
  }, [hasFamilyAccount, online, section, advancedReviewOpen, dataQualityOpen, spacesState, scope, purchaseRetryKey]);

  function loadOlderTransactions() {
    if (purchaseState.status !== "ready" || purchaseState.selectionKey !== selectionKey || purchaseState.loadingOlder) return;
    const pages = Object.entries(purchaseState.transactionPages).filter(([, page]) => page.hasMore);
    if (!pages.length) return;
    const requestKey = purchaseState.selectionKey;
    setPurchaseState({ ...purchaseState, loadingOlder: true, olderError: false });
    Promise.all(pages.map(async ([spaceID, page]) => {
      const transactions = await api<FinanceTransaction[]>(
        `/finance/transactions?space_id=${encodeURIComponent(spaceID)}&offset=${page.nextOffset}&limit=200${page.ownerAware}`,
        {},
        true,
        false,
      );
      const allowed = transactions.filter((transaction) => transaction.space_id === spaceID);
      return { spaceID, page, transactions: allowed, received: transactions.length };
    }))
      .then((results) => {
        setPurchaseState((current) => {
          if (current.status !== "ready" || current.selectionKey !== requestKey) return current;
          const transactionByID = new Map(current.data.transactions.map((transaction) => [transaction.id, transaction]));
          const transactionPages = { ...current.transactionPages };
          results.forEach(({ spaceID, page, transactions, received }) => {
            transactions.forEach((transaction) => transactionByID.set(transaction.id, transaction));
            transactionPages[spaceID] = {
              ...page,
              nextOffset: page.nextOffset + received,
              hasMore: received === 200,
            };
          });
          return {
            ...current,
            data: {
              ...current.data,
              transactions: [...transactionByID.values()].sort((left, right) => right.canonical_date.localeCompare(left.canonical_date)),
            },
            transactionPages,
            loadingOlder: false,
            olderError: false,
          };
        });
      })
      .catch(() => {
        setPurchaseState((current) => current.status === "ready" && current.selectionKey === requestKey
          ? { ...current, loadingOlder: false, olderError: true }
          : current);
      });
  }

  function loadOlderPurchases() {
    if (purchaseState.status !== "ready" || purchaseState.selectionKey !== selectionKey || purchaseState.loadingOlderPurchases) return;
    const pages = Object.entries(purchaseState.purchasePages).filter(([, page]) => page.hasMore);
    if (!pages.length) return;
    const requestKey = purchaseState.selectionKey;
    setPurchaseState({ ...purchaseState, loadingOlderPurchases: true, olderPurchasesError: false });
    Promise.all(pages.map(async ([spaceID, page]) => {
      const purchases = await api<FinancePurchaseSummary[]>(
        `/finance/purchases?space_id=${encodeURIComponent(spaceID)}&offset=${page.nextOffset}&limit=50${page.ownerAware}`,
        {},
        true,
        false,
      );
      const allowed = purchases.filter((purchase) => purchase.space_id === spaceID);
      return { spaceID, page, purchases: allowed, received: purchases.length };
    }))
      .then((results) => {
        setPurchaseState((current) => {
          if (current.status !== "ready" || current.selectionKey !== requestKey) return current;
          const purchasePages = { ...current.purchasePages };
          const additions: FinancePurchaseSummary[] = [];
          results.forEach(({ spaceID, page, purchases, received }) => {
            additions.push(...purchases);
            purchasePages[spaceID] = {
              ...page,
              nextOffset: page.nextOffset + received,
              hasMore: received === 50,
            };
          });
          return {
            ...current,
            data: mergePurchaseData([
              current.data,
              { accounts: [], transactions: [], purchases: additions, exceptions: [] },
            ]),
            purchasePages,
            loadingOlderPurchases: false,
            olderPurchasesError: false,
          };
        });
      })
      .catch(() => {
        setPurchaseState((current) => current.status === "ready" && current.selectionKey === requestKey
          ? { ...current, loadingOlderPurchases: false, olderPurchasesError: true }
          : current);
      });
  }

  function updateMatchedPurchase(updated: FinancePurchaseDetail) {
    setPurchaseState((current) => current.status === "ready" ? {
      ...current,
      data: {
        accounts: current.data.accounts,
        transactions: current.data.transactions,
        purchases: current.data.purchases.map((purchase) => (
          purchase.id === updated.id ? { ...purchase, ...updated } : purchase
        )),
        exceptions: current.data.exceptions.filter((exception) => !(
          exception.purchase_id === updated.id
          && ["AMBIGUOUS_MATCH", "UNMATCHED_PURCHASE"].includes(exception.exception_kind)
        )),
      },
    } : current);
  }

  useEffect(() => {
    if (!hasFamilyAccount) {
      setConsentState({ status: "idle" });
      setConsentActionError("");
      return;
    }
    if (!["coach", "settings"].includes(section) || spacesState.status !== "ready") return;
    if (!selectedFinanceSpaces(spacesState.spaces, scope).length) return;
    const controller = new AbortController();
    let active = true;
    setConsentState({ status: "loading" });
    setConsentActionError("");
    api<FinanceAIConsent[]>(
      "/finance/ai-consent",
      { signal: controller.signal },
      true,
      false,
    )
      .then((consents) => {
        if (active) setConsentState({ status: "ready", consents });
      })
      .catch((error: unknown) => {
        if (!active || isAbortError(error)) return;
        setConsentState({ status: "error" });
      });
    return () => {
      active = false;
      controller.abort();
    };
  }, [hasFamilyAccount, online, section, spacesState, scope, consentRetryKey]);

  async function changeConsent(consent: FinanceAIConsent, accepted: boolean) {
    if (!online || consentWorkingSpaceID) return;
    const allowedIDs = new Set(selectedSpaces.map((space) => space.id));
    if (!allowedIDs.has(consent.space_id)) return;
    setConsentWorkingSpaceID(consent.space_id);
    setConsentActionError("");
    try {
      const updated = accepted
        ? await api<FinanceAIConsent>(
            "/finance/ai-consent",
            {
              method: "PUT",
              body: JSON.stringify({
                space_id: consent.space_id,
                accepted: true,
                consent_version: consent.consent_version,
              }),
            },
            true,
            false,
          )
        : await api<FinanceAIConsent>(
            `/finance/ai-consent?space_id=${encodeURIComponent(consent.space_id)}`,
            { method: "DELETE" },
            true,
            false,
          );
      setConsentState((current) => current.status === "ready" ? {
        status: "ready",
        consents: current.consents.map((item) => (
          item.space_id === updated.space_id ? updated : item
        )),
      } : current);
      setAnswerState({ status: "idle" });
      setExchanges([]);
    } catch (error) {
      if (error instanceof ApiError && error.status === 409) {
        setConsentState({ status: "error" });
      } else {
        setConsentActionError(
          error instanceof ApiError && error.status === 503
            ? copy.coachProviderUnavailable
            : copy.consentUpdateError,
        );
      }
    } finally {
      setConsentWorkingSpaceID(null);
    }
  }

  async function askCoach() {
    const trimmedQuestion = question.trim();
    const canAsk = consentState.status === "ready"
      && consentedForScope(consentState.consents, selectedSpaces, scope)
      && selectedSpaces.every((space) => consentState.consents.some((consent) => (
        consent.space_id === space.id && consent.provider !== "off"
      )));
    if (!online || !trimmedQuestion || !canAsk || answerState.status === "sending") return;
    setAnswerState({ status: "sending" });
    try {
      const answer = await api<FinanceCoachAnswer>(
        "/finance/coach/ask",
        { method: "POST", body: JSON.stringify({ question: trimmedQuestion, scope, space_id: selectedSpaces[0]?.id, conversation: exchanges.flatMap((exchange) => [{ role: "user", text: exchange.question.slice(0, 1_500) }, { role: "assistant", text: `${exchange.answer.headline}\n${exchange.answer.answer}`.slice(0, 1_500) }]).slice(-8) }) },
        true,
        false,
      );
      setExchanges((current) => [...current, { question: trimmedQuestion, answer }].slice(-4));
      setQuestion("");
      setAnswerState({ status: "idle" });
    } catch (error) {
      if (error instanceof ApiError && error.status === 428) {
        setAnswerState({ status: "error", kind: "consent" });
        setConsentRetryKey((key) => key + 1);
      } else if (error instanceof ApiError && error.status === 503) {
        setAnswerState({ status: "error", kind: "unavailable" });
      } else {
        setAnswerState({ status: "error", kind: "request" });
      }
    }
  }

  if (!hasFamilyAccount) {
    return (
      <section className="finance-access-state" aria-labelledby="finance-unavailable-title">
        <LockKeyhole aria-hidden="true" size={32} />
        <h1 id="finance-unavailable-title">{copy.unavailableTitle}</h1>
        <p>{copy.unavailableDetail}</p>
      </section>
    );
  }

  if (!online) {
    return (
      <section className="finance-access-state" aria-labelledby="finance-offline-title">
        <LockKeyhole aria-hidden="true" size={32} />
        <h1 id="finance-offline-title">{copy.offlineTitle}</h1>
        <p>{copy.offlineDetail}</p>
      </section>
    );
  }

  if (spacesState.status === "idle" || spacesState.status === "loading") {
    return (
      <section className="finance-view" aria-label={copy.loadingSpaces} aria-busy="true">
        <div className="finance-heading-skeleton" />
        <div className="finance-tabs-skeleton" />
        <div className="finance-card-skeleton" />
      </section>
    );
  }

  if (spacesState.status === "error") {
    return (
      <section className="finance-access-state is-error" role="alert" aria-labelledby="finance-error-title">
        <AlertCircle aria-hidden="true" size={32} />
        <h1 id="finance-error-title">{copy.errorTitle}</h1>
        <p>{copy.errorDetail}</p>
        <button
          type="button"
          className="button button--secondary"
          onClick={() => setSpacesRetryKey((key) => key + 1)}
        >
          {copy.retry}
        </button>
      </section>
    );
  }

  if (spacesState.spaces.length === 0) {
    return (
      <section className="finance-access-state" aria-labelledby="finance-setup-title">
        <ShieldCheck aria-hidden="true" size={32} />
        <h1 id="finance-setup-title">{copy.setupTitle}</h1>
        <p>{copy.setupDetail}</p>
      </section>
    );
  }

  return (
    <section className="finance-view" aria-labelledby="finance-title">
      <header className="finance-header">
        <div className="finance-header-copy">
          <h1 id="finance-title">{copy.title}</h1>
          <p>{copy.subtitle}</p>
        </div>
        <div className="finance-header-controls">
          <fieldset className="finance-space-switch">
            <legend>{locale === "de" ? "Ansicht" : "View"}</legend>
            <div>
              <button
                type="button"
                aria-label={copy.myFinances}
                aria-pressed={scope === "mine"}
                disabled={!personalSpace}
                onClick={() => changeScope("mine")}
              >
                <LockKeyhole aria-hidden="true" size={16} />
                <span>{copy.myFinances}</span>
              </button>
              <button
                type="button"
                aria-label={copy.household}
                aria-pressed={scope === "household"}
                onClick={() => changeScope("household")}
              >
                <Building2 aria-hidden="true" size={16} />
                <span>{copy.household}</span>
              </button>
            </div>
          </fieldset>
        </div>
      </header>

      {bankCallback ? (
        <div className={cn("finance-bank-callback", bankCallback === "failed" && "is-error")} role="status">
          {bankCallback === "connected" ? <CheckCircle2 aria-hidden="true" size={20} /> : <AlertCircle aria-hidden="true" size={20} />}
          <span>{bankCallback === "connected" ? copy.bankCallbackConnected : bankCallback === "cancelled" ? copy.bankCallbackCancelled : copy.bankCallbackFailed}</span>
          <button type="button" className="button button--secondary" onClick={() => { setBankCallback(null); onSectionChange("setup"); }}>{copy.manageBankConnections}</button>
        </div>
      ) : null}

      <nav className="finance-section-nav is-primary" aria-label={copy.sectionNavigation}>
        {sections.map(({ id, icon: Icon }) => (
          <button
            type="button"
            key={id}
            className={cn(section === id && "is-active")}
            aria-current={section === id ? "page" : undefined}
            onClick={() => onSectionChange(id)}
          >
            <Icon aria-hidden="true" size={18} />
            {topLabels[id]}
          </button>
        ))}
        <button
          type="button"
          className={cn(moreSelected && "is-active")}
          aria-current={moreSelected ? "page" : undefined}
          onClick={() => onSectionChange("more")}
        >
          <MoreHorizontal aria-hidden="true" size={18} />
          <span>{locale === "de" ? "Mehr" : "More"}</span>
        </button>
      </nav>

      {!selectedSpaces.length && section !== "overview" ? (
        <div className="finance-empty-panel">
          <ShieldX aria-hidden="true" size={34} />
          <h2>{copy.scopeUnavailableTitle}</h2>
          <p>
            {scope === "mine" ? copy.scopeUnavailableMine : copy.scopeUnavailableHousehold}
          </p>
        </div>
      ) : section === "overview" && overviewState.status === "error" && overviewState.scope === scope ? (
        <div className="finance-empty-panel is-error" role="alert">
          <AlertCircle aria-hidden="true" size={34} />
          <h2>{locale === "de" ? "Übersicht konnte nicht geladen werden" : "Couldn't load your overview"}</h2>
          <p>{locale === "de" ? "Versuche es gleich noch einmal." : "This is usually a brief connection problem. Try again."}</p>
          <button type="button" className="button button--secondary" onClick={() => setOverviewRetryKey((key) => key + 1)}>{copy.retry}</button>
        </div>
      ) : section === "overview" && (overviewState.status !== "ready" || overviewState.scope !== scope) ? (
        <div className="finance-overview-skeleton" aria-label={locale === "de" ? "Finanzübersicht wird geladen" : "Loading Finance overview"} aria-busy="true"><div /><div /><div /><div /></div>
      ) : section === "overview" && overviewState.status === "ready" ? (
        <Suspense fallback={<div className="finance-overview-skeleton" aria-label={locale === "de" ? "Finanzübersicht wird geladen" : "Loading Finance overview"} aria-busy="true"><div /><div /><div /><div /></div>}>
          <FinanceOverviewView overview={overviewState.data} locale={locale} onOpenGoals={() => onSectionChange("goals")} />
        </Suspense>
      ) : section === "more" ? (
        <div className="finance-more-page">
          <header><span>{locale === "de" ? "Bei Bedarf" : "When you need it"}</span><h2>{locale === "de" ? "Weitere Finanzwerkzeuge" : "More Finance tools"}</h2><p>{locale === "de" ? "Planung, Analyse, Einrichtung und Prüfwerkzeuge bleiben griffbereit, ohne den Alltag zu überladen." : "Planning, analysis, setup and review tools stay close without crowding the everyday view."}</p></header>
          <nav aria-label={locale === "de" ? "Erweiterte Finanzwerkzeuge" : "Advanced Finance tools"}>
            <ul>{moreSections.map(({ id, icon: Icon }) => <li key={id}><button type="button" onClick={() => onSectionChange(id)}><Icon aria-hidden="true" size={18} /><span><strong>{moreLabels[id]}</strong><small>{id === "planning" ? (locale === "de" ? "Prognose, Verpflichtungen und Rücklagen" : "Forecast, commitments and reserves") : id === "coach" ? (locale === "de" ? "Fragen zu deinen gespeicherten Zahlen" : "Ask about your saved figures") : id === "explore" ? (locale === "de" ? "Eigene Auswertungen erstellen" : "Build your own analysis") : id === "assets" ? (locale === "de" ? "Vermögen und Produktpreise" : "Net worth and product prices") : id === "settings" ? (locale === "de" ? "Teilen, Datenschutz und Coaching" : "Sharing, privacy and coaching") : (locale === "de" ? "Konten und Datenquellen" : "Accounts and data sources")}</small></span><ChevronRight aria-hidden="true" size={18} /></button></li>)}</ul>
          </nav>
          <details className="finance-calm-details finance-advanced-review" open={advancedReviewOpen} onToggle={(event) => setAdvancedReviewOpen(event.currentTarget.open)}>
            <summary><span><strong>{locale === "de" ? "Belege und Einkäufe prüfen" : "Review receipts and purchases"}</strong><small>{locale === "de" ? "Zahlungsabgleich und Korrekturen" : "Payment matching and corrections"}</small></span><ChevronRight aria-hidden="true" size={18} /></summary>
            {advancedReviewOpen ? purchaseState.status === "error" && purchaseState.selectionKey === selectionKey ? <div className="finance-empty-panel is-error" role="alert"><AlertCircle aria-hidden="true" size={28} /><h3>{copy.purchasesErrorTitle}</h3><p>{copy.purchasesErrorDetail}</p><button type="button" className="button button--secondary" onClick={() => setPurchaseRetryKey((key) => key + 1)}>{copy.retry}</button></div> : purchaseState.status !== "ready" || purchaseState.selectionKey !== selectionKey ? <FinanceDataSkeleton label={copy.purchasesLoading} /> : <PurchasesView key={selectionKey} data={purchaseState.data} spaces={selectedSpaces} availableSpaces={spacesState.spaces} selectionKey={selectionKey} locale={locale} copy={copy} focusEvidenceID={activityEvidenceID} focusReviewLineID={activityReviewLineID} onReviewFocusConsumed={() => undefined} hasOlderPurchases={Object.values(purchaseState.purchasePages).some((page) => page.hasMore)} loadingOlderPurchases={purchaseState.loadingOlderPurchases} olderPurchasesError={purchaseState.olderPurchasesError} onLoadOlderPurchases={loadOlderPurchases} onMatched={updateMatchedPurchase} onAskAbout={(contextQuestion) => { setQuestion(contextQuestion); setAnswerState({ status: "idle" }); onSectionChange("coach"); }} /> : null}
          </details>
          <details className="finance-calm-details finance-activity-data-quality" open={dataQualityOpen} onToggle={(event) => setDataQualityOpen(event.currentTarget.open)}>
            <summary><span><strong>{locale === "de" ? "Datenqualität prüfen" : "Check data quality"}</strong><small>{locale === "de" ? "Seltene Fragen zu Gehalt, Karten oder großen Einkäufen" : "Occasional questions about salary, cards or large purchases"}</small></span><ChevronRight aria-hidden="true" size={18} /></summary>
            {dataQualityOpen && purchaseState.status === "ready" ? <Suspense fallback={<FinanceDataSkeleton label={copy.loadingData} />}><FinanceMaterialQuestionsView spaces={selectedSpaces} accounts={purchaseState.data.accounts} locale={locale} onOpenSetup={() => onSectionChange("setup")} onOpenPurchases={(sourceID) => { const url = new URL(window.location.href); if (sourceID) url.searchParams.set("evidence", sourceID); else url.searchParams.delete("evidence"); window.history.replaceState({}, "", url); setActivityEvidenceID(sourceID); setAdvancedReviewOpen(true); }} /></Suspense> : null}
          </details>
          <button type="button" className="finance-more-renewals" onClick={onOpenRenewals}><BellRing aria-hidden="true" size={18} /><span><strong>{locale === "de" ? "Verträge und Fristen" : "Renewals and important dates"}</strong><small>{locale === "de" ? "Unter Listen öffnen" : "Open in Lists"}</small></span><ChevronRight aria-hidden="true" size={18} /></button>
        </div>
      ) : section === "setup" ? (
        <Suspense fallback={<FinanceDataSkeleton label={copy.loadingData} />}>
          <FinanceSetupView
            key={selectionKey}
            spaces={selectedSpaces}
            locale={locale}
            copy={copy}
            onBankRedirect={onBankRedirect}
          />
        </Suspense>
      ) : section === "activity" && purchaseState.status === "error" && purchaseState.selectionKey === selectionKey ? (
        <div className="finance-empty-panel is-error" role="alert">
          <AlertCircle aria-hidden="true" size={34} />
          <h2>{locale === "de" ? "Aktivität konnte nicht geladen werden" : "Couldn't load bank activity"}</h2>
          <p>{locale === "de" ? "Versuche es gleich noch einmal." : "Try again in a moment."}</p>
          <button
            type="button"
            className="button button--secondary"
            onClick={() => setPurchaseRetryKey((key) => key + 1)}
          >
            {copy.retry}
          </button>
        </div>
      ) : section === "activity" && (purchaseState.status !== "ready" || purchaseState.selectionKey !== selectionKey) ? (
        <FinanceDataSkeleton label={locale === "de" ? "Aktivität wird geladen" : "Loading bank activity"} />
      ) : section === "activity" && purchaseState.status === "ready" ? (
        <div className="finance-section-content">
          <ActivityTransactions
            data={purchaseState.data}
            spaces={selectedSpaces}
            locale={locale}
            copy={copy}
            onAskAbout={(contextQuestion) => {
              setQuestion(contextQuestion);
              setAnswerState({ status: "idle" });
              onSectionChange("coach");
            }}
            hasOlder={Object.values(purchaseState.transactionPages).some((page) => page.hasMore)}
            loadingOlder={purchaseState.loadingOlder}
            olderError={purchaseState.olderError}
            onLoadOlder={loadOlderTransactions}
          />
        </div>
      ) : dataState.status === "error" && dataState.selectionKey === selectionKey ? (
        <div className="finance-empty-panel is-error" role="alert">
          <AlertCircle aria-hidden="true" size={34} />
          <h2>{copy.dataErrorTitle}</h2>
          <p>{copy.dataErrorDetail}</p>
          <button
            type="button"
            className="button button--secondary"
            onClick={() => setDataRetryKey((key) => key + 1)}
          >
            {copy.retry}
          </button>
        </div>
      ) : dataState.status !== "ready" || dataState.selectionKey !== selectionKey ? (
        <FinanceDataSkeleton label={copy.loadingData} />
      ) : section === "goals" ? (
        <div className="finance-section-content">
          <Suspense fallback={<FinanceDataSkeleton label={copy.loadingData} />}>
            <FinancePlansView
              key={`${selectionKey}:${planSpaces.map((space) => space.id).join(":")}`}
              spaces={planSpaces}
              accounts={dataState.data.accounts}
              goals={[...dataState.data.goals, ...sharedGoals.filter((sharedGoal) => !dataState.data.goals.some((goal) => goal.id === sharedGoal.id))]}
              monthlySpaceIDs={selectedSpaces.map((space) => space.id)}
              locale={locale}
              showDeepTools={false}
            />
          </Suspense>
        </div>
      ) : section === "planning" ? (
        <div className="finance-section-content finance-advanced-page">
          <header className="finance-advanced-heading"><button type="button" className="button button--secondary" onClick={() => onSectionChange("more")}>{locale === "de" ? "Zurück zu Mehr" : "Back to More"}</button><div><span>{locale === "de" ? "Erweitert" : "Advanced"}</span><h2>{locale === "de" ? "Prognose und Verpflichtungen" : "Forecast and commitments"}</h2></div></header>
          <Suspense fallback={<FinanceDataSkeleton label={copy.loadingData} />}>
            <FinanceOutlookView accounts={dataState.data.accounts} spaces={selectedSpaces} online={online} locale={locale} copy={copy} />
          </Suspense>
          <details className="finance-calm-details finance-plan-assumptions" open={Boolean(commitmentDeepLinkID) || undefined}>
            <summary>
              <span><strong>{locale === "de" ? "Verpflichtungen, Rücklagen und Annahmen" : "Commitments, reserves and assumptions"}</strong><small>{locale === "de" ? "Details für Rechnungen und zurückgelegtes Geld" : "Detailed bills and money set aside"}</small></span>
              <ChevronRight aria-hidden="true" size={18} />
            </summary>
            <PlanningView
              data={dataState.data}
              spaces={selectedSpaces}
              members={members}
              scope={scope}
              locale={locale}
              copy={copy}
              notice={planNotice}
              onCreated={(kind) => { setPlanNotice(copy.createdMessages[kind]); setDataRetryKey((key) => key + 1); }}
              onCommitmentChanged={(message) => { setPlanNotice(message); setDataRetryKey((key) => key + 1); }}
            />
          </details>
        </div>
      ) : section === "assets" ? (
        <Suspense fallback={<FinanceDataSkeleton label={copy.loadingData} />}>
          <FinanceAssetsProductsView
            key={selectionKey}
            spaces={selectedSpaces}
            accounts={dataState.data.accounts}
            locale={locale}
          />
        </Suspense>
      ) : section === "settings" ? (
        <div className="finance-section-content">
          <Suspense fallback={<FinanceDataSkeleton label={copy.loadingData} />}>
            <FinanceCoachingSettingsView key={selectionKey} spaces={selectedSpaces} accounts={dataState.data.accounts} consents={consentState.status === "ready" ? consentState.consents : []} locale={locale} />
          </Suspense>
          <FinanceSharingPanel data={dataState.data} spaces={selectedSpaces} locale={locale} />
          <Suspense fallback={<FinanceDataSkeleton label={copy.loadingData} />}>
            <FinanceDataControlsView key={`${selectionKey}:${scope}`} scope={scope} locale={locale} />
          </Suspense>
        </div>
      ) : section === "coach" ? (
        <CoachView
          data={dataState.data}
          spaces={selectedSpaces}
          scope={scope}
          online={online}
          locale={locale}
          copy={copy}
          consentState={consentState}
          consentWorkingSpaceID={consentWorkingSpaceID}
          consentActionError={consentActionError}
          onConsentRetry={() => setConsentRetryKey((key) => key + 1)}
          onConsentChange={(consent, accepted) => void changeConsent(consent, accepted)}
          question={question}
          answerState={answerState}
          exchanges={exchanges}
          onQuestionChange={setQuestion}
          onAsk={() => void askCoach()}
          onStartOver={() => { setQuestion(""); setAnswerState({ status: "idle" }); setExchanges([]); }}
        />
      ) : (
        <ExploreView
          data={dataState.data}
          spaces={selectedSpaces}
          scope={scope}
          locale={locale}
          copy={copy}
          onAskAbout={(contextQuestion) => {
            setQuestion(contextQuestion);
            setAnswerState({ status: "idle" });
            onSectionChange("coach");
          }}
        />
      )}
    </section>
  );
}
