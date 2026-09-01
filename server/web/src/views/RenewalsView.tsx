import {
  ArrowUpRight,
  BadgeCheck,
  CalendarDays,
  Car,
  Check,
  ChevronRight,
  CreditCard,
  FileText,
  HeartPulse,
  Library,
  Mail,
  Pencil,
  Plus,
  RefreshCw,
  RotateCcw,
  ShieldCheck,
  Tag,
  Trash2,
  UsersRound,
  WalletCards,
  Zap,
  type LucideIcon,
} from "lucide-react";
import { addMonths, format, parseISO } from "date-fns";
import { useCallback, useEffect, useMemo, useState, type FormEvent } from "react";

import { api, localISODate } from "../api";
import {
  DocumentAttachmentField,
  uploadPendingDocument,
  type PendingDocumentAttachment,
} from "../components/DocumentAttachmentField";
import { DocumentViewer } from "../components/DocumentViewer";
import { EmptyState, ErrorState, Modal, SkeletonList, cn } from "../components/ui";
import type {
  FamilyMember,
  FinancePaymentHandling,
  Renewal,
  RenewalCategory,
  RenewalDraftPreview,
  RenewalStatus,
  LibraryAccount,
  LibraryLoan,
  LibraryOverview,
} from "../types";
import "./renewals.css";

const CATEGORIES: Array<{ value: RenewalCategory; label: string; icon: LucideIcon }> = [
  { value: "document", label: "Document", icon: FileText },
  { value: "vehicle", label: "Vehicle", icon: Car },
  { value: "insurance", label: "Insurance", icon: ShieldCheck },
  { value: "subscription", label: "Subscription", icon: CreditCard },
  { value: "utility", label: "Utility", icon: Zap },
  { value: "membership", label: "Membership", icon: BadgeCheck },
  { value: "medical", label: "Medical", icon: HeartPulse },
  { value: "other", label: "Other", icon: Tag },
];

const CATEGORY_MAP = new Map(CATEGORIES.map((item) => [item.value, item]));

function categoryIcon(category: RenewalCategory): LucideIcon {
  return CATEGORY_MAP.get(category)?.icon ?? Tag;
}

function categoryLabel(category: RenewalCategory): string {
  return CATEGORY_MAP.get(category)?.label ?? "Other";
}

function statusLabel(status: RenewalStatus): string {
  if (status === "overdue") return "Overdue";
  if (status === "due_soon") return "Due soon";
  return "Upcoming";
}

function dueLabel(days: number): string {
  if (days === 0) return "Due today";
  if (days > 0) return `in ${days} ${days === 1 ? "day" : "days"}`;
  const past = Math.abs(days);
  return `${past} ${past === 1 ? "day" : "days"} ago`;
}

function pounds(pence: number): string {
  return `£${(pence / 100).toFixed(2)}`;
}

type Draft = {
  title: string;
  category: RenewalCategory;
  dueDate: string;
  recurrenceMonths: string;
  cost: string;
  reminderDays: string;
  provider: string;
  reference: string;
  actionURL: string;
  comparisonURL: string;
  contactURL: string;
  notes: string;
  sourceDocumentID: string | null;
  checklistText: string;
  remindersEnabled: boolean;
  escalateAfterDays: string;
  includeInHouseholdFinance: boolean;
  showInCalendar: boolean;
  showInTasks: boolean;
  responsibleUserID: string;
  paymentHandling: FinancePaymentHandling;
};

function emptyDraft(): Draft {
  return {
    title: "",
    category: "document",
    dueDate: localISODate(new Date()),
    recurrenceMonths: "",
    cost: "",
    reminderDays: "30",
    provider: "",
    reference: "",
    actionURL: "",
    comparisonURL: "",
    contactURL: "",
    notes: "",
    sourceDocumentID: null,
    checklistText: "",
    remindersEnabled: true,
    escalateAfterDays: "3",
    includeInHouseholdFinance: false,
    showInCalendar: false,
    showInTasks: false,
    responsibleUserID: "",
    paymentHandling: "UNSPECIFIED",
  };
}

function draftFromRenewal(renewal: Renewal): Draft {
  return {
    title: renewal.title,
    category: renewal.category,
    dueDate: renewal.due_date.slice(0, 10),
    recurrenceMonths: renewal.recurrence_months != null ? String(renewal.recurrence_months) : "",
    cost: renewal.cost_pence != null ? (renewal.cost_pence / 100).toFixed(2) : "",
    reminderDays: String(renewal.reminder_days_before),
    provider: renewal.provider ?? "",
    reference: renewal.reference ?? "",
    actionURL: renewal.action_url ?? "",
    comparisonURL: renewal.comparison_url ?? "",
    contactURL: renewal.contact_url ?? "",
    notes: renewal.notes ?? "",
    sourceDocumentID: renewal.source_document_id,
    checklistText: "",
    remindersEnabled: renewal.reminders_enabled ?? true,
    escalateAfterDays: renewal.escalate_after_days != null ? String(renewal.escalate_after_days) : "",
    includeInHouseholdFinance: Boolean(renewal.finance_commitment_id),
    showInCalendar: renewal.show_in_calendar ?? false,
    showInTasks: renewal.show_in_tasks ?? false,
    responsibleUserID: renewal.responsible_user_id ?? "",
    paymentHandling: renewal.payment_handling ?? "UNSPECIFIED",
  };
}

type Props = {
  members?: FamilyMember[];
  revision: number;
  onDataChanged: () => void;
  notify: (message: string) => void;
};

export function RenewalsView({ members = [], revision, onDataChanged, notify }: Props) {
  const [renewals, setRenewals] = useState<Renewal[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [working, setWorking] = useState<string | null>(null);
  const [formOpen, setFormOpen] = useState(false);
  const [editing, setEditing] = useState<Renewal | null>(null);
  const [detail, setDetail] = useState<Renewal | null>(null);
  const [draft, setDraft] = useState<Draft>(emptyDraft);
  const [pendingDocument, setPendingDocument] = useState<PendingDocumentAttachment | null>(null);
  const [formError, setFormError] = useState<string | null>(null);
  const [saving, setSaving] = useState(false);
  const [readingDocument, setReadingDocument] = useState(false);
  const [viewingDocument, setViewingDocument] = useState<Renewal["source_document"]>(null);
  const [checklistTitle, setChecklistTitle] = useState("");
  const [decision, setDecision] = useState<{ renewal: Renewal; outcome: "renewed" | "not_renewing" } | null>(null);
  const [decisionCost, setDecisionCost] = useState("");
  const [decisionNextDate, setDecisionNextDate] = useState("");
  const [decisionNotes, setDecisionNotes] = useState("");
  const [removed, setRemoved] = useState<Renewal | null>(null);
  const [library, setLibrary] = useState<LibraryOverview>({ accounts: [], loans: [] });
  const [libraryError, setLibraryError] = useState<string | null>(null);
  const [libraryFormOpen, setLibraryFormOpen] = useState(false);
  const [libraryLabel, setLibraryLabel] = useState("");
  const [libraryCard, setLibraryCard] = useState("");
  const [libraryPIN, setLibraryPIN] = useState("");
  const [libraryPINVisible, setLibraryPINVisible] = useState(false);
  const [libraryReminderDays, setLibraryReminderDays] = useState("7");
  const [librarySaving, setLibrarySaving] = useState(false);
  const [highlightedLibraryLoan, setHighlightedLibraryLoan] = useState<string | null>(null);

  const adults = useMemo(() => members.filter((member) => member.member_type === "user"), [members]);

  const load = useCallback(async (background = false) => {
    if (!background) setLoading(true);
    setError(null);
    try {
      const [renewalResult, libraryResult] = await Promise.allSettled([
        api<Renewal[]>("/renewals/"),
        api<LibraryOverview>("/library/"),
      ]);
      if (renewalResult.status === "rejected") throw renewalResult.reason;
      setRenewals(Array.isArray(renewalResult.value) ? renewalResult.value : []);
      if (libraryResult.status === "fulfilled") {
        setLibrary({
          accounts: Array.isArray(libraryResult.value?.accounts) ? libraryResult.value.accounts : [],
          loans: Array.isArray(libraryResult.value?.loans) ? libraryResult.value.loans : [],
        });
        setLibraryError(null);
      } else {
        setLibraryError(libraryResult.reason instanceof Error ? libraryResult.reason.message : "Library books could not be loaded.");
      }
    } catch (requestError) {
      setError(requestError instanceof Error ? requestError.message : "Renewals could not be loaded.");
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    void load(revision !== 0);
  }, [load, revision]);

  const sorted = useMemo(
    () => [...renewals].sort((left, right) => left.due_date.localeCompare(right.due_date)),
    [renewals],
  );

  useEffect(() => {
    if (loading) return;
    const identifier = new URL(window.location.href).searchParams.get("renewal");
    if (!identifier) return;
    const renewal = renewals.find((item) => item.id === identifier);
    if (!renewal) return;
    setDetail(renewal);
    const url = new URL(window.location.href);
    url.searchParams.delete("renewal");
    window.history.replaceState({}, "", url);
  }, [loading, renewals]);

  useEffect(() => {
    if (loading) return;
    const url = new URL(window.location.href);
    const identifier = url.searchParams.get("library");
    if (!identifier || !library.loans.some((loan) => loan.id === identifier)) return;
    setHighlightedLibraryLoan(identifier);
    url.searchParams.delete("library");
    window.history.replaceState({}, "", url);
    window.setTimeout(() => setHighlightedLibraryLoan(null), 4_000);
  }, [library.loans, loading]);

  function openLibraryForm() {
    setLibraryLabel("");
    setLibraryCard("");
    setLibraryPIN("");
    setLibraryPINVisible(false);
    setLibraryReminderDays("7");
    setLibraryError(null);
    setLibraryFormOpen(true);
  }

  async function connectLibrary(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (librarySaving) return;
    const reminderDays = Number(libraryReminderDays);
    if (!libraryLabel.trim() || !libraryCard.trim() || !libraryPIN.trim()) {
      setLibraryError("Enter a name, library barcode and PIN.");
      return;
    }
    if (!Number.isInteger(reminderDays) || reminderDays < 0 || reminderDays > 30) {
      setLibraryError("Choose a reminder between 0 and 30 days before the due date.");
      return;
    }
    setLibrarySaving(true);
    setLibraryError(null);
    try {
      const result = await api<LibraryOverview>("/library/accounts", {
        method: "POST",
        body: JSON.stringify({
          label: libraryLabel.trim(),
          card_number: libraryCard.replace(/\s+/g, ""),
          pin: libraryPIN,
          reminder_days_before: reminderDays,
        }),
      });
      setLibrary(result);
      setLibraryPIN("");
      setLibraryCard("");
      setLibraryFormOpen(false);
      notify("Library card connected and loans checked.");
    } catch (requestError) {
      setLibraryError(requestError instanceof Error ? requestError.message : "That library card could not be connected.");
    } finally {
      setLibrarySaving(false);
    }
  }

  async function syncLibraryAccount(account: LibraryAccount) {
    setWorking(`library-sync-${account.id}`);
    setLibraryError(null);
    try {
      const result = await api<LibraryOverview>(`/library/accounts/${account.id}/sync`, { method: "POST" });
      setLibrary(result);
      notify(`${account.label} library loans are up to date.`);
    } catch (requestError) {
      setLibraryError(requestError instanceof Error ? requestError.message : "Library loans could not be refreshed.");
    } finally {
      setWorking(null);
    }
  }

  async function disconnectLibraryAccount(account: LibraryAccount) {
    if (!window.confirm(`Disconnect ${account.label}'s library card? Saved credentials and its loan list will be removed.`)) return;
    setWorking(`library-delete-${account.id}`);
    try {
      await api<void>(`/library/accounts/${account.id}`, { method: "DELETE" });
      setLibrary((current) => ({
        accounts: current.accounts.filter((item) => item.id !== account.id),
        loans: current.loans.filter((item) => item.account_id !== account.id),
      }));
      notify(`${account.label}'s library card disconnected.`);
    } catch (requestError) {
      setLibraryError(requestError instanceof Error ? requestError.message : "That library card could not be disconnected.");
    } finally {
      setWorking(null);
    }
  }

  function libraryDueLabel(loan: LibraryLoan): string {
    if (loan.days_until < 0) return `${Math.abs(loan.days_until)} ${Math.abs(loan.days_until) === 1 ? "day" : "days"} overdue`;
    if (loan.days_until === 0) return "Due back today";
    if (loan.days_until === 1) return "Due back tomorrow";
    return `Due back in ${loan.days_until} days`;
  }

  function replaceRenewal(updated: Renewal) {
    setRenewals((current) => {
      const found = current.some((item) => item.id === updated.id);
      return found ? current.map((item) => item.id === updated.id ? updated : item) : [...current, updated];
    });
    setDetail((current) => current?.id === updated.id ? updated : current);
  }

  function openNew() {
    setEditing(null);
    setDraft({ ...emptyDraft(), responsibleUserID: adults[0]?.id ?? "" });
    setPendingDocument(null);
    setFormError(null);
    setFormOpen(true);
  }

  function openEdit(renewal: Renewal) {
    setEditing(renewal);
    setDraft(draftFromRenewal(renewal));
    setPendingDocument(null);
    setFormError(null);
    setDetail(null);
    setFormOpen(true);
  }

  function applyPreview(preview: RenewalDraftPreview) {
    setDraft((current) => ({
      ...current,
      title: preview.title ?? current.title,
      category: preview.category,
      dueDate: preview.due_date ?? current.dueDate,
      recurrenceMonths: preview.recurrence_months != null ? String(preview.recurrence_months) : current.recurrenceMonths,
      cost: preview.cost_pence != null ? (preview.cost_pence / 100).toFixed(2) : current.cost,
      provider: preview.provider ?? current.provider,
      reference: preview.reference ?? current.reference,
      actionURL: preview.action_url ?? current.actionURL,
      sourceDocumentID: preview.source_document_id ?? current.sourceDocumentID,
    }));
    if (preview.uncertain_fields.length) {
      setFormError(`Please check ${preview.uncertain_fields.join(", ")}. Nothing is saved until you press Save.`);
    } else {
      setFormError(null);
    }
  }

  async function fillFromDocument() {
    if (!draft.sourceDocumentID && !pendingDocument) {
      setFormError("Choose a document first.");
      return;
    }
    setReadingDocument(true);
    setFormError(null);
    try {
      let documentID = draft.sourceDocumentID;
      if (pendingDocument) {
        const uploaded = await uploadPendingDocument(pendingDocument);
        documentID = uploaded.id;
        setPendingDocument(null);
        setDraft((current) => ({ ...current, sourceDocumentID: uploaded.id }));
      }
      const preview = await api<RenewalDraftPreview>("/renewals/draft", {
        method: "POST",
        body: JSON.stringify({ document_id: documentID }),
      });
      applyPreview(preview);
    } catch (requestError) {
      setFormError(requestError instanceof Error ? requestError.message : "That document could not be read.");
    } finally {
      setReadingDocument(false);
    }
  }

  function parsedMoney(value: string): number | null {
    if (!value.trim()) return null;
    const parsed = Number(value);
    return Number.isFinite(parsed) && parsed >= 0 ? Math.round(parsed * 100) : Number.NaN;
  }

  async function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (saving) return;
    const title = draft.title.trim();
    const recurrence = draft.recurrenceMonths.trim() ? Number(draft.recurrenceMonths) : null;
    const cost = parsedMoney(draft.cost);
    const reminder = draft.reminderDays.trim() ? Number(draft.reminderDays) : 30;
    const escalation = draft.escalateAfterDays.trim() ? Number(draft.escalateAfterDays) : null;
    if (!title) return setFormError("Give this renewal a name.");
    if (!draft.dueDate) return setFormError("Choose a due date.");
    if (recurrence != null && (!Number.isInteger(recurrence) || recurrence <= 0)) return setFormError("Recurrence must be a number of months.");
    if (Number.isNaN(cost)) return setFormError("Enter the cost in pounds, for example 82.50.");
    if (draft.includeInHouseholdFinance && cost == null) return setFormError("Enter the cost before including it in Household Finance.");
    if (draft.includeInHouseholdFinance && draft.paymentHandling === "UNSPECIFIED") return setFormError("Choose how this renewal is paid or reviewed.");
    if ((draft.showInTasks || draft.remindersEnabled) && !draft.responsibleUserID) return setFormError("Choose the adult who will handle this.");
    if (escalation != null && (!Number.isInteger(escalation) || escalation < 0)) return setFormError("Escalation must be a number of days.");

    setSaving(true);
    setFormError(null);
    try {
      let sourceDocumentID = draft.sourceDocumentID;
      if (pendingDocument) sourceDocumentID = (await uploadPendingDocument(pendingDocument)).id;
      const body = {
        title,
        category: draft.category,
        due_date: draft.dueDate,
        recurrence_months: recurrence,
        cost_pence: cost,
        reminder_days_before: Number.isFinite(reminder) ? reminder : 30,
        provider: draft.provider.trim() || null,
        reference: draft.reference.trim() || null,
        action_url: draft.actionURL.trim() || null,
        comparison_url: draft.comparisonURL.trim() || null,
        contact_url: draft.contactURL.trim() || null,
        source_document_id: sourceDocumentID,
        notes: draft.notes.trim() || null,
        responsible_user_id: draft.responsibleUserID || null,
        reminders_enabled: draft.remindersEnabled,
        escalate_after_days: escalation,
        include_in_household_finance: draft.includeInHouseholdFinance,
        show_in_calendar: draft.showInCalendar,
        show_in_tasks: draft.showInTasks,
        payment_handling: draft.includeInHouseholdFinance ? draft.paymentHandling : "UNSPECIFIED",
        ...(!editing ? { checklist: draft.checklistText.split("\n").map((item) => item.trim()).filter(Boolean) } : {}),
      };
      const updated = editing
        ? await api<Renewal>(`/renewals/${editing.id}`, { method: "PATCH", body: JSON.stringify(body) })
        : await api<Renewal>("/renewals/", { method: "POST", body: JSON.stringify(body) });
      replaceRenewal(updated);
      setFormOpen(false);
      setPendingDocument(null);
      onDataChanged();
      await load(true);
    } catch (requestError) {
      setFormError(requestError instanceof Error ? requestError.message : "That renewal could not be saved.");
    } finally {
      setSaving(false);
    }
  }

  function openDecision(renewal: Renewal, outcome: "renewed" | "not_renewing") {
    setDecision({ renewal, outcome });
    setDecisionCost(renewal.cost_pence != null ? (renewal.cost_pence / 100).toFixed(2) : "");
    setDecisionNextDate(
      outcome === "renewed" && renewal.recurrence_months
        ? localISODate(addMonths(parseISO(renewal.due_date.slice(0, 10)), renewal.recurrence_months))
        : "",
    );
    setDecisionNotes("");
  }

  async function confirmDecision(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (!decision) return;
    const cost = parsedMoney(decisionCost);
    if (Number.isNaN(cost)) return notify("Enter the renewed price in pounds.");
    setWorking(`decision-${decision.renewal.id}`);
    try {
      const updated = await api<Renewal>(`/renewals/${decision.renewal.id}/decision`, {
        method: "POST",
        body: JSON.stringify({
          outcome: decision.outcome,
          cost_pence: cost,
          next_due_date: decisionNextDate || null,
          notes: decisionNotes.trim() || null,
        }),
      });
      const archived = decision.outcome === "not_renewing" || !decisionNextDate;
      if (archived) {
        setRenewals((current) => current.filter((item) => item.id !== decision.renewal.id));
        setRemoved(decision.renewal);
        setDetail(null);
      } else {
        replaceRenewal(updated);
      }
      notify(decision.outcome === "not_renewing" ? `${decision.renewal.title} will not renew.` : `${decision.renewal.title} is sorted.`);
      setDecision(null);
      onDataChanged();
    } catch (requestError) {
      notify(requestError instanceof Error ? requestError.message : "That renewal could not be updated.");
    } finally {
      setWorking(null);
    }
  }

  async function remove(renewal: Renewal) {
    setWorking(`delete-${renewal.id}`);
    try {
      await api<void>(`/renewals/${renewal.id}`, { method: "DELETE" });
      setRenewals((current) => current.filter((item) => item.id !== renewal.id));
      setRemoved(renewal);
      setDetail(null);
      onDataChanged();
    } catch (requestError) {
      notify(requestError instanceof Error ? requestError.message : "That renewal could not be removed.");
    } finally {
      setWorking(null);
    }
  }

  async function undoRemove() {
    if (!removed) return;
    setWorking(`restore-${removed.id}`);
    try {
      const restored = await api<Renewal>(`/renewals/${removed.id}/restore`, { method: "POST" });
      replaceRenewal(restored);
      setRemoved(null);
      onDataChanged();
    } catch (requestError) {
      notify(requestError instanceof Error ? requestError.message : "That renewal could not be restored.");
    } finally {
      setWorking(null);
    }
  }

  async function toggleChecklist(renewal: Renewal, item: NonNullable<Renewal["checklist"]>[number]) {
    setWorking(`check-${item.id}`);
    try {
      const updatedItem = await api<NonNullable<Renewal["checklist"]>[number]>(`/renewals/${renewal.id}/checklist/${item.id}`, {
        method: "PATCH",
        body: JSON.stringify({ checked: !item.checked_at }),
      });
      replaceRenewal({ ...renewal, checklist: (renewal.checklist ?? []).map((entry) => entry.id === item.id ? updatedItem : entry) });
    } catch (requestError) {
      notify(requestError instanceof Error ? requestError.message : "That step could not be updated.");
    } finally {
      setWorking(null);
    }
  }

  async function addChecklist(event: FormEvent<HTMLFormElement>, renewal: Renewal) {
    event.preventDefault();
    const title = checklistTitle.trim();
    if (!title) return;
    setWorking(`add-check-${renewal.id}`);
    try {
      const item = await api<NonNullable<Renewal["checklist"]>[number]>(`/renewals/${renewal.id}/checklist`, {
        method: "POST",
        body: JSON.stringify({ title }),
      });
      replaceRenewal({ ...renewal, checklist: [...(renewal.checklist ?? []), item] });
      setChecklistTitle("");
    } catch (requestError) {
      notify(requestError instanceof Error ? requestError.message : "That step could not be added.");
    } finally {
      setWorking(null);
    }
  }

  return (
    <div className="standard-page renewals-view">
      <header className="page-header">
        <div>
          <p className="page-eyebrow">Stay ahead</p>
          <h1>Renewals</h1>
          <p>Documents, decisions and dates together — before anything lapses.</p>
        </div>
        <button type="button" className="button button--primary button--compact" onClick={openNew}>
          <Plus aria-hidden="true" size={17} /> Add renewal
        </button>
      </header>

      {removed ? (
        <div className="renewal-undo" role="status">
          <span>{removed.title} removed.</span>
          <button type="button" className="button button--secondary button--compact" disabled={Boolean(working)} onClick={() => void undoRemove()}>
            <RotateCcw aria-hidden="true" size={15} /> Undo
          </button>
        </div>
      ) : null}
      {error ? <ErrorState message={error} retry={load} /> : null}
      {loading ? <SkeletonList rows={5} /> : null}

      {!loading ? (
        <section className="library-monitor" aria-labelledby="library-monitor-title">
          <header>
            <div className="library-monitor-heading">
              <span className="library-monitor-icon"><Library aria-hidden="true" size={20} /></span>
              <div><h2 id="library-monitor-title">Library books</h2><p>Example Town loans, checked automatically.</p></div>
            </div>
            <button type="button" className="button button--secondary button--compact" onClick={openLibraryForm}><Plus aria-hidden="true" size={15} /> Add library card</button>
          </header>
          {libraryError ? <div className="library-monitor-error" role="alert"><span>{libraryError}</span><button type="button" className="button button--secondary button--compact" onClick={() => void load(true)}>Try again</button></div> : null}
          {library.accounts.length ? (
            <div className="library-account-list" aria-label="Connected library cards">
              {library.accounts.map((account) => (
                <div className="library-account" key={account.id}>
                  <span><strong>{account.label}</strong><small>Card ending {account.card_last_four} · {account.status === "connected" ? "Connected" : account.status === "needs_attention" ? "Reconnect needed" : "Check pending"}</small></span>
                  <span className="library-account-actions">
                    <button type="button" className="button button--secondary button--compact" disabled={Boolean(working)} onClick={() => void syncLibraryAccount(account)}><RefreshCw aria-hidden="true" size={14} /> {working === `library-sync-${account.id}` ? "Checking…" : "Check now"}</button>
                    <button type="button" className="icon-button" aria-label={`Disconnect ${account.label} library card`} disabled={Boolean(working)} onClick={() => void disconnectLibraryAccount(account)}><Trash2 aria-hidden="true" size={15} /></button>
                  </span>
                  {account.error_message ? <small className="library-account-error">{account.error_message}</small> : null}
                </div>
              ))}
            </div>
          ) : (
            <div className="library-monitor-empty"><p>Connect a family library card once. HausKlar will keep the current physical loans and due dates here.</p><button type="button" className="button button--secondary button--compact" onClick={openLibraryForm}>Connect a card</button></div>
          )}
          {library.loans.length ? (
            <ul className="library-loan-list" aria-label="Current library loans">
              {library.loans.map((loan) => (
                <li key={loan.id} className={cn(`is-${loan.status.replace("_", "-")}`, highlightedLibraryLoan === loan.id && "is-highlighted")}>
                  <span><strong>{loan.title}</strong><small>{[loan.author, loan.account_label].filter(Boolean).join(" · ")}</small></span>
                  <span className="library-loan-due">
                    <span><strong>{libraryDueLabel(loan)}</strong><small>{format(parseISO(loan.due_date), "d MMM yyyy")}</small></span>
                    {loan.renew_url ? <a className="button button--secondary library-renew-link" href={loan.renew_url} target="_blank" rel="noreferrer">Renew online <ArrowUpRight aria-hidden="true" size={15} /></a> : null}
                  </span>
                </li>
              ))}
            </ul>
          ) : library.accounts.length ? <p className="library-no-loans">No books are currently on loan.</p> : null}
          <p className="library-read-only">Read-only: HausKlar never renews or changes a library account automatically.</p>
        </section>
      ) : null}

      {!loading && !error ? sorted.length ? (
        <ul className="renewal-list" aria-label="Upcoming renewals">
          {sorted.map((renewal) => {
            const Icon = categoryIcon(renewal.category);
            const checked = (renewal.checklist ?? []).filter((item) => item.checked_at).length;
            return (
              <li className={cn("renewal-row", `is-${renewal.status.replace("_", "-")}`)} key={renewal.id}>
                <span className="renewal-icon" aria-hidden="true"><Icon size={20} /></span>
                <button type="button" className="renewal-main renewal-open" onClick={() => setDetail(renewal)}>
                  <span className="renewal-title-row">
                    <strong>{renewal.title}</strong>
                    <span className={cn("renewal-badge", `is-${renewal.status.replace("_", "-")}`)}>{statusLabel(renewal.status)}</span>
                  </span>
                  <span className="renewal-meta">
                    <span>{renewal.provider || categoryLabel(renewal.category)}</span>
                    <span aria-hidden="true">·</span>
                    <span>{format(parseISO(renewal.due_date.slice(0, 10)), "d MMM yyyy")}</span>
                    <span aria-hidden="true">·</span>
                    <span className="renewal-when">{dueLabel(renewal.days_until)}</span>
                    {renewal.cost_pence != null ? <><span aria-hidden="true">·</span><span>{pounds(renewal.cost_pence)}</span></> : null}
                    {(renewal.checklist?.length ?? 0) > 0 ? <><span aria-hidden="true">·</span><span>{checked}/{renewal.checklist?.length} ready</span></> : null}
                  </span>
                </button>
                <button type="button" className="icon-button renewal-chevron" aria-label={`Open ${renewal.title}`} onClick={() => setDetail(renewal)}>
                  <ChevronRight aria-hidden="true" size={19} />
                </button>
              </li>
            );
          })}
        </ul>
      ) : (
        <EmptyState title="Nothing to renew yet" detail="Add a passport, MOT, insurance or membership and HausKlar will bring it back at the right time." action={openNew} actionLabel="Add renewal" />
      ) : null}

      {detail ? (
        <Modal open onOpenChange={(open) => { if (!open) setDetail(null); }} title={detail.title} description={`${statusLabel(detail.status)} · ${format(parseISO(detail.due_date.slice(0, 10)), "d MMMM yyyy")}`}>
          <div className="renewal-detail">
            <section className="renewal-summary-card">
              <div>
                <span>{dueLabel(detail.days_until)}</span>
                <strong>{detail.cost_pence != null ? pounds(detail.cost_pence) : "No price saved"}</strong>
                {detail.cost_change_pence != null && detail.cost_change_pence !== 0 ? (
                  <small>{detail.cost_change_pence > 0 ? "+" : "−"}{pounds(Math.abs(detail.cost_change_pence))} since last time</small>
                ) : null}
              </div>
              <dl>
                {detail.provider ? <div><dt>Provider</dt><dd>{detail.provider}</dd></div> : null}
                {detail.reference ? <div><dt>Reference</dt><dd>{detail.reference}</dd></div> : null}
                {detail.responsible_user_name ? <div><dt>Handled by</dt><dd>{detail.responsible_user_name}</dd></div> : null}
                {detail.recurrence_months ? <div><dt>Repeats</dt><dd>Every {detail.recurrence_months} {detail.recurrence_months === 1 ? "month" : "months"}</dd></div> : null}
              </dl>
            </section>

            <div className="renewal-job-actions">
              {detail.action_url ? <a className="button button--primary" href={detail.action_url} target="_blank" rel="noreferrer">Renew now <ArrowUpRight aria-hidden="true" size={16} /></a> : null}
              {detail.comparison_url ? <a className="button button--secondary" href={detail.comparison_url} target="_blank" rel="noreferrer">Compare <ArrowUpRight aria-hidden="true" size={16} /></a> : null}
              {detail.contact_url ? <a className="button button--secondary" href={detail.contact_url} target="_blank" rel="noreferrer"><Mail aria-hidden="true" size={16} /> Contact</a> : null}
              {detail.source_document ? <button type="button" className="button button--secondary" onClick={() => setViewingDocument(detail.source_document)}><FileText aria-hidden="true" size={16} /> Document</button> : null}
            </div>

            <section className="renewal-detail-section">
              <header><div><h3>Before it is sorted</h3><p>Tick these off as you go.</p></div></header>
              {(detail.checklist ?? []).length ? (
                <ul className="renewal-checklist">
                  {(detail.checklist ?? []).map((item) => (
                    <li key={item.id}>
                      <button type="button" disabled={Boolean(working)} onClick={() => void toggleChecklist(detail, item)} aria-label={`${item.checked_at ? "Reopen" : "Complete"} ${item.title}`}>
                        <span className={cn("renewal-check", item.checked_at && "is-done")}>{item.checked_at ? <Check aria-hidden="true" size={15} /> : null}</span>
                        <span className={cn(item.checked_at && "is-done")}>{item.title}</span>
                      </button>
                    </li>
                  ))}
                </ul>
              ) : <p className="renewal-empty-detail">No steps yet. Add only what will make this easier next time.</p>}
              <form className="renewal-checklist-add" onSubmit={(event) => void addChecklist(event, detail)}>
                <label className="sr-only" htmlFor="renewal-checklist-title">Add a step</label>
                <input id="renewal-checklist-title" value={checklistTitle} onChange={(event) => setChecklistTitle(event.target.value)} placeholder="Add a step" />
                <button className="button button--secondary button--compact" disabled={!checklistTitle.trim() || Boolean(working)}>Add</button>
              </form>
            </section>

            {detail.notes ? <section className="renewal-detail-section"><h3>Notes</h3><p>{detail.notes}</p></section> : null}

            {(detail.history ?? []).length ? (
              <details className="renewal-history">
                <summary>Previous renewals</summary>
                <ul>
                  {(detail.history ?? []).map((item) => (
                    <li key={item.id}>
                      <span>{format(parseISO(item.due_date), "d MMM yyyy")}</span>
                      <strong>{item.outcome === "renewed" ? "Renewed" : "Not renewed"}</strong>
                      {item.cost_pence != null ? <span>{pounds(item.cost_pence)}</span> : null}
                    </li>
                  ))}
                </ul>
              </details>
            ) : null}

            <div className="dialog-actions renewal-detail-actions">
              <button type="button" className="button button--secondary" onClick={() => openEdit(detail)}><Pencil aria-hidden="true" size={16} /> Edit</button>
              <button type="button" className="button button--secondary" onClick={() => openDecision(detail, "not_renewing")}>Not renewing</button>
              <button type="button" className="button button--primary" onClick={() => openDecision(detail, "renewed")}><RefreshCw aria-hidden="true" size={16} /> It’s renewed</button>
            </div>
            <button type="button" className="renewal-remove-link" disabled={Boolean(working)} onClick={() => void remove(detail)}><Trash2 aria-hidden="true" size={14} /> Remove this record</button>
          </div>
        </Modal>
      ) : null}

      {decision ? (
        <Modal open onOpenChange={(open) => { if (!open) setDecision(null); }} title={decision.outcome === "renewed" ? `Finish ${decision.renewal.title}` : `Do not renew ${decision.renewal.title}?`} description={decision.outcome === "renewed" ? "Save what happened so next time starts with the right date and price." : "This removes it from upcoming renewals. You can undo straight afterwards."}>
          <form className="renewal-form" onSubmit={(event) => void confirmDecision(event)}>
            {decision.outcome === "renewed" ? (
              <>
                <div className="field"><label htmlFor="decision-cost">Price paid (£)</label><input id="decision-cost" inputMode="decimal" value={decisionCost} onChange={(event) => setDecisionCost(event.target.value)} placeholder="Optional" /></div>
                {decision.renewal.recurrence_months ? <div className="field"><label htmlFor="decision-next">Next due date</label><input id="decision-next" type="date" value={decisionNextDate} onChange={(event) => setDecisionNextDate(event.target.value)} /></div> : null}
              </>
            ) : null}
            <div className="field"><label htmlFor="decision-notes">Note</label><textarea id="decision-notes" rows={2} value={decisionNotes} onChange={(event) => setDecisionNotes(event.target.value)} placeholder="Optional" /></div>
            <div className="dialog-actions">
              <button type="button" className="button button--secondary" onClick={() => setDecision(null)}>Cancel</button>
              <button type="submit" className={cn("button", decision.outcome === "renewed" ? "button--primary" : "button--danger")} disabled={Boolean(working)}>{decision.outcome === "renewed" ? "Save renewed" : "Do not renew"}</button>
            </div>
          </form>
        </Modal>
      ) : null}

      {libraryFormOpen ? (
        <Modal open onOpenChange={(open) => { setLibraryFormOpen(open); if (!open) { setLibraryPIN(""); setLibraryPINVisible(false); } }} title="Connect your library" description="HausKlar will read current physical loans and due dates from the Local authority catalogue.">
          <form className="renewal-form" onSubmit={(event) => void connectLibrary(event)}>
            <div className="field"><label htmlFor="library-label">Whose card?</label><input id="library-label" value={libraryLabel} onChange={(event) => setLibraryLabel(event.target.value)} placeholder="e.g. Children" autoComplete="name" /></div>
            <div className="field"><label htmlFor="library-card">Library card barcode</label><input id="library-card" value={libraryCard} onChange={(event) => setLibraryCard(event.target.value)} inputMode="numeric" autoComplete="username" spellCheck={false} /></div>
            <div className="field"><label htmlFor="library-pin">Catalogue PIN</label><div className="library-pin-field"><input id="library-pin" type={libraryPINVisible ? "text" : "password"} value={libraryPIN} onChange={(event) => setLibraryPIN(event.target.value.replace(/\D/g, "").slice(0, 6))} inputMode="numeric" autoComplete="current-password" maxLength={6} spellCheck={false} /><button type="button" className="button button--secondary" onClick={() => setLibraryPINVisible((visible) => !visible)} aria-label={libraryPINVisible ? "Hide catalogue PIN" : "Show catalogue PIN"}>{libraryPINVisible ? "Hide" : "Show"}</button></div></div>
            <div className="field"><label htmlFor="library-reminder-days">Remind us this many days before</label><input id="library-reminder-days" type="text" inputMode="numeric" pattern="[0-9]*" value={libraryReminderDays} onChange={(event) => setLibraryReminderDays(event.target.value.replace(/\D/g, "").slice(0, 2))} /></div>
            <p className="library-credential-note">The barcode and PIN are encrypted on your HausKlar server and are never shown again. Nothing is renewed automatically.</p>
            {libraryError ? <div className="library-monitor-error" role="alert">{libraryError}</div> : null}
            <div className="dialog-actions"><button type="button" className="button button--secondary" onClick={() => { setLibraryPIN(""); setLibraryPINVisible(false); setLibraryFormOpen(false); }}>Cancel</button><button type="submit" className="button button--primary" disabled={librarySaving} aria-busy={librarySaving}>{librarySaving ? "Checking…" : "Connect and check loans"}</button></div>
          </form>
        </Modal>
      ) : null}

      {formOpen ? (
        <Modal open onOpenChange={setFormOpen} title={editing ? "Edit renewal" : "Add renewal"} description="Keep the useful detail here; HausKlar will bring it back when it matters.">
          <form className="renewal-form" onSubmit={(event) => void submit(event)}>
            <DocumentAttachmentField
              active={formOpen}
              idPrefix="renewal"
              currentDocument={editing?.source_document}
              selectedDocumentID={draft.sourceDocumentID}
              pending={pendingDocument}
              disabled={saving || readingDocument}
              onSelect={(sourceDocumentID) => setDraft((current) => ({ ...current, sourceDocumentID }))}
              onPending={setPendingDocument}
            />
            {(draft.sourceDocumentID || pendingDocument) ? <button type="button" className="button button--secondary" disabled={readingDocument} onClick={() => void fillFromDocument()}>{readingDocument ? "Reading…" : "Fill details from this document"}</button> : null}

            <div className="field"><label htmlFor="renewal-title">Name</label><input id="renewal-title" value={draft.title} onChange={(event) => setDraft((current) => ({ ...current, title: event.target.value }))} placeholder="e.g. Car insurance" autoFocus /></div>
            <div className="form-grid">
              <div className="field"><label htmlFor="renewal-category">Category</label><select id="renewal-category" value={draft.category} onChange={(event) => setDraft((current) => ({ ...current, category: event.target.value as RenewalCategory }))}>{CATEGORIES.map((item) => <option value={item.value} key={item.value}>{item.label}</option>)}</select></div>
              <div className="field"><label htmlFor="renewal-due">Due date</label><input id="renewal-due" type="date" value={draft.dueDate} onChange={(event) => setDraft((current) => ({ ...current, dueDate: event.target.value }))} /></div>
              <div className="field"><label htmlFor="renewal-provider">Provider</label><input id="renewal-provider" value={draft.provider} onChange={(event) => setDraft((current) => ({ ...current, provider: event.target.value }))} placeholder="Optional" /></div>
              <div className="field"><label htmlFor="renewal-reference">Policy or reference</label><input id="renewal-reference" value={draft.reference} onChange={(event) => setDraft((current) => ({ ...current, reference: event.target.value }))} placeholder="Optional" /></div>
              <div className="field"><label htmlFor="renewal-recurrence">Repeats every (months)</label><input id="renewal-recurrence" inputMode="numeric" value={draft.recurrenceMonths} onChange={(event) => setDraft((current) => ({ ...current, recurrenceMonths: event.target.value }))} placeholder="Blank for one-off" /></div>
              <div className="field"><label htmlFor="renewal-cost">Expected cost (£)</label><input id="renewal-cost" inputMode="decimal" value={draft.cost} onChange={(event) => setDraft((current) => ({ ...current, cost: event.target.value }))} placeholder="Optional" /></div>
            </div>

            <details className="renewal-form-more">
              <summary>Useful links and notes</summary>
              <div className="renewal-form-more-body">
                <div className="field"><label htmlFor="renewal-action-url">Renew online</label><input id="renewal-action-url" type="url" value={draft.actionURL} onChange={(event) => setDraft((current) => ({ ...current, actionURL: event.target.value }))} placeholder="https://…" /></div>
                <div className="field"><label htmlFor="renewal-comparison-url">Comparison page</label><input id="renewal-comparison-url" type="url" value={draft.comparisonURL} onChange={(event) => setDraft((current) => ({ ...current, comparisonURL: event.target.value }))} placeholder="https://…" /></div>
                <div className="field"><label htmlFor="renewal-contact-url">Contact link</label><input id="renewal-contact-url" value={draft.contactURL} onChange={(event) => setDraft((current) => ({ ...current, contactURL: event.target.value }))} placeholder="https://…, mailto:… or tel:…" /></div>
                <div className="field"><label htmlFor="renewal-notes">Notes</label><textarea id="renewal-notes" rows={3} value={draft.notes} onChange={(event) => setDraft((current) => ({ ...current, notes: event.target.value }))} /></div>
                {!editing ? <div className="field"><label htmlFor="renewal-checklist">Steps for next time</label><textarea id="renewal-checklist" rows={3} value={draft.checklistText} onChange={(event) => setDraft((current) => ({ ...current, checklistText: event.target.value }))} placeholder={"Check cover\nCompare price\nConfirm payment"} /><span className="field-help">One step per line. You can change these later.</span></div> : null}
              </div>
            </details>

            <fieldset>
              <legend>Who handles it?</legend>
              <div className="field"><label htmlFor="renewal-responsible">Responsible adult</label><select id="renewal-responsible" value={draft.responsibleUserID} onChange={(event) => setDraft((current) => ({ ...current, responsibleUserID: event.target.value }))}><option value="">Not assigned</option>{adults.map((member) => <option value={member.id} key={member.id}>{member.name}</option>)}</select></div>
              <label className="check-row"><input type="checkbox" checked={draft.remindersEnabled} onChange={(event) => setDraft((current) => ({ ...current, remindersEnabled: event.target.checked }))} /><span><strong>Send a reminder</strong><small>To the responsible adult, opening this exact renewal.</small></span></label>
              {draft.remindersEnabled ? <div className="form-grid"><div className="field"><label htmlFor="renewal-reminder">First reminder (days before)</label><input id="renewal-reminder" inputMode="numeric" value={draft.reminderDays} onChange={(event) => setDraft((current) => ({ ...current, reminderDays: event.target.value }))} /></div><div className="field"><label htmlFor="renewal-escalation">Tell the other adult if overdue by</label><input id="renewal-escalation" inputMode="numeric" value={draft.escalateAfterDays} onChange={(event) => setDraft((current) => ({ ...current, escalateAfterDays: event.target.value }))} placeholder="Never" /></div></div> : null}
            </fieldset>

            <fieldset>
              <legend>Show elsewhere</legend>
              <label className="check-row"><input type="checkbox" checked={draft.showInCalendar} onChange={(event) => setDraft((current) => ({ ...current, showInCalendar: event.target.checked }))} /><span><CalendarDays aria-hidden="true" size={16} /> Show the due date in Calendar</span></label>
              <label className="check-row"><input type="checkbox" checked={draft.showInTasks} onChange={(event) => setDraft((current) => ({ ...current, showInTasks: event.target.checked }))} /><span><UsersRound aria-hidden="true" size={16} /> Add a task for the responsible adult</span></label>
              <label className="check-row"><input type="checkbox" checked={draft.includeInHouseholdFinance} onChange={(event) => setDraft((current) => ({ ...current, includeInHouseholdFinance: event.target.checked, paymentHandling: event.target.checked && current.paymentHandling === "UNSPECIFIED" ? "RENEWAL" : current.paymentHandling }))} /><span><WalletCards aria-hidden="true" size={16} /><strong>Include the cost in Household Finance</strong></span></label>
              {draft.includeInHouseholdFinance ? <div className="field"><label htmlFor="renewal-payment-handling">Payment</label><select id="renewal-payment-handling" value={draft.paymentHandling} onChange={(event) => setDraft((current) => ({ ...current, paymentHandling: event.target.value as FinancePaymentHandling }))}><option value="UNSPECIFIED">Not decided</option><option value="AUTOMATIC">Automatic payment</option><option value="MANUAL">Manual payment</option><option value="RENEWAL">Review or renew first</option></select></div> : null}
            </fieldset>

            {formError ? <div className={cn("form-error", formError.startsWith("Please check") && "is-review-note")} role="alert">{formError}</div> : null}
            <div className="dialog-actions"><button type="button" className="button button--secondary" onClick={() => setFormOpen(false)}>Cancel</button><button type="submit" className="button button--primary" disabled={saving}>{saving ? "Saving…" : editing ? "Save changes" : "Add renewal"}</button></div>
          </form>
        </Modal>
      ) : null}
      <DocumentViewer document={viewingDocument ?? null} onOpenChange={(open) => { if (!open) setViewingDocument(null); }} />
    </div>
  );
}
