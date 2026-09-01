import {
  CalendarDays,
  CheckCircle2,
  ChevronRight,
  ExternalLink,
  Gift,
  LockKeyhole,
  PackageCheck,
  Pencil,
  Plus,
  RotateCcw,
  Trash2,
  UserRound,
} from "lucide-react";
import { format, parseISO } from "date-fns";
import { useCallback, useEffect, useMemo, useRef, useState, type FormEvent } from "react";

import { api } from "../api";
import { EmptyState, ErrorState, Modal, SkeletonList, cn } from "../components/ui";
import type { Child, FamilyMember } from "../types";
import "./presents.css";

type PresentStatus = "idea" | "shortlist" | "assigned" | "bought" | "arrived" | "wrapped" | "stashed" | "given";

type PresentHistory = {
  id: string;
  from_status?: PresentStatus | null;
  to_status: PresentStatus;
  changed_at: string;
  changed_by_name?: string | null;
};

export type PresentIdea = {
  id: string;
  child_id: string;
  recipient_name?: string | null;
  title: string;
  occasion: string;
  event_year: number;
  birthday_id?: string | null;
  status: PresentStatus;
  status_updated_at?: string | null;
  owner_id?: string | null;
  owner_name?: string | null;
  notes?: string | null;
  url?: string | null;
  retailer?: string | null;
  budget_minor?: number | null;
  price_minor?: number | null;
  currency: string;
  deadline?: string | null;
  hiding_location?: string | null;
  recipient_can_see: boolean;
  status_history: PresentHistory[];
};

type Draft = {
  title: string;
  occasion: string;
  status: PresentStatus;
  ownerID: string;
  deadline: string;
  url: string;
  retailer: string;
  budget: string;
  price: string;
  hidingLocation: string;
  notes: string;
  hiddenFromRecipient: boolean;
  birthdayID: string | null;
};

type DuplicateMatch = Pick<PresentIdea, "id" | "title" | "occasion" | "event_year" | "status">;
type UndoNotice = { id: string; title: string };

const STATUSES: PresentStatus[] = ["idea", "shortlist", "assigned", "bought", "arrived", "wrapped", "stashed", "given"];

const STATUS_LABEL: Record<PresentStatus, string> = {
  idea: "Ideas",
  shortlist: "Shortlist",
  assigned: "Assigned",
  bought: "Bought",
  arrived: "Arrived",
  wrapped: "Wrapped",
  stashed: "Stashed",
  given: "Given",
};

function blankDraft(birthdayID: string | null): Draft {
  return {
    title: "",
    occasion: birthdayID ? "birthday" : "christmas",
    status: "idea",
    ownerID: "",
    deadline: "",
    url: "",
    retailer: "",
    budget: "",
    price: "",
    hidingLocation: "",
    notes: "",
    hiddenFromRecipient: true,
    birthdayID,
  };
}

function ideaDraft(idea: PresentIdea): Draft {
  return {
    title: idea.title,
    occasion: idea.occasion,
    status: idea.status,
    ownerID: idea.owner_id ?? "",
    deadline: idea.deadline ?? "",
    url: idea.url ?? "",
    retailer: idea.retailer ?? "",
    budget: minorToInput(idea.budget_minor),
    price: minorToInput(idea.price_minor),
    hidingLocation: idea.hiding_location ?? "",
    notes: idea.notes ?? "",
    hiddenFromRecipient: !idea.recipient_can_see,
    birthdayID: idea.birthday_id ?? null,
  };
}

function minorToInput(value?: number | null): string {
  return value == null ? "" : (value / 100).toFixed(2);
}

function inputToMinor(value: string): number | null {
  if (!value.trim()) return null;
  const parsed = Number(value);
  return Number.isFinite(parsed) && parsed >= 0 ? Math.round(parsed * 100) : null;
}

function money(value: number | null | undefined, currency = "GBP"): string | null {
  if (value == null) return null;
  return new Intl.NumberFormat("en-GB", { style: "currency", currency }).format(value / 100);
}

function dateLabel(value: string): string {
  const parsed = parseISO(value);
  return Number.isNaN(parsed.getTime()) ? value : format(parsed, "d MMM yyyy");
}

function dateTimeLabel(value: string): string {
  const parsed = parseISO(value);
  return Number.isNaN(parsed.getTime()) ? value : format(parsed, "d MMM · HH:mm");
}

function nextStatus(status: PresentStatus): PresentStatus | null {
  const index = STATUSES.indexOf(status);
  return index >= 0 && index < STATUSES.length - 1 ? STATUSES[index + 1] : null;
}

function nextAction(status: PresentStatus): string {
  switch (status) {
    case "idea": return "Shortlist";
    case "shortlist": return "Assign";
    case "assigned": return "Mark bought";
    case "bought": return "Mark arrived";
    case "arrived": return "Mark wrapped";
    case "wrapped": return "Mark stashed";
    case "stashed": return "Mark given";
    case "given": return "Given";
  }
}

function requestBody(draft: Draft) {
  return {
    title: draft.title.trim(),
    occasion: draft.occasion.trim(),
    status: draft.status,
    owner_id: draft.ownerID || null,
    birthday_id: draft.birthdayID,
    deadline: draft.deadline || null,
    url: draft.url.trim() || null,
    retailer: draft.retailer.trim() || null,
    budget_minor: inputToMinor(draft.budget),
    price_minor: inputToMinor(draft.price),
    currency: "GBP",
    hiding_location: draft.hidingLocation.trim() || null,
    notes: draft.notes.trim() || null,
    recipient_can_see: !draft.hiddenFromRecipient,
  };
}

function replaceByID(items: PresentIdea[], next: PresentIdea): PresentIdea[] {
  return items.some((item) => item.id === next.id)
    ? items.map((item) => item.id === next.id ? next : item)
    : [next, ...items];
}

export function PresentsView({
  children,
  members,
  selectedChild,
  revision,
  initialPresentId,
  initialBirthdayId,
  onDataChanged,
}: {
  children: Child[];
  members: FamilyMember[];
  selectedChild: string;
  revision: number;
  initialPresentId?: string | null;
  initialBirthdayId?: string | null;
  onDataChanged: () => void;
}) {
  const [ideas, setIdeas] = useState<PresentIdea[]>([]);
  const [loading, setLoading] = useState(true);
  const [loadError, setLoadError] = useState<string | null>(null);
  const [actionError, setActionError] = useState<string | null>(null);
  const [busy, setBusy] = useState<string | null>(null);
  const [quickTitle, setQuickTitle] = useState("");
  const [showGiven, setShowGiven] = useState(false);
  const [editor, setEditor] = useState<PresentIdea | "new" | null>(null);
  const [draft, setDraft] = useState<Draft>(() => blankDraft(initialBirthdayId ?? null));
  const [detailID, setDetailID] = useState<string | null>(null);
  const [duplicates, setDuplicates] = useState<DuplicateMatch[]>([]);
  const [pendingCreate, setPendingCreate] = useState<{ draft: Draft; fromQuickAdd: boolean } | null>(null);
  const [undo, setUndo] = useState<UndoNotice | null>(null);
  const lastLoad = useRef<{ child: string; revision: number; birthday: string | null } | null>(null);
  const consumedFocus = useRef<string | null>(null);

  const adults = useMemo(() => members.filter((member) => member.member_type === "user"), [members]);
  const childName = children.find((child) => child.id === selectedChild)?.name ?? "Recipient";
  const visibleIdeas = showGiven ? ideas : ideas.filter((idea) => idea.status !== "given");
  const detail = ideas.find((idea) => idea.id === detailID) ?? null;

  const load = useCallback(async (background = false) => {
    if (!selectedChild || selectedChild === "all") {
      setIdeas([]);
      setLoading(false);
      return;
    }
    if (!background) setLoading(true);
    setLoadError(null);
    try {
      const params = new URLSearchParams({ child_id: selectedChild, include_given: "true", limit: "200" });
      if (initialBirthdayId) params.set("birthday_id", initialBirthdayId);
      setIdeas(await api<PresentIdea[]>(`/children/presents/ideas?${params.toString()}`));
    } catch (requestError) {
      if (!background) {
        setLoadError(requestError instanceof Error ? requestError.message : "Gift plans could not be loaded.");
      }
    } finally {
      setLoading(false);
    }
  }, [initialBirthdayId, selectedChild]);

  useEffect(() => {
    const birthday = initialBirthdayId ?? null;
    const previous = lastLoad.current;
    const background = previous?.child === selectedChild
      && previous.birthday === birthday
      && previous.revision !== revision;
    lastLoad.current = { child: selectedChild, revision, birthday };
    void load(background);
  }, [initialBirthdayId, load, revision, selectedChild]);

  useEffect(() => {
    if (!initialPresentId || consumedFocus.current === initialPresentId) return;
    if (!ideas.some((idea) => idea.id === initialPresentId)) return;
    consumedFocus.current = initialPresentId;
    setDetailID(initialPresentId);
  }, [ideas, initialPresentId]);

  useEffect(() => {
    if (!undo) return;
    const timeout = window.setTimeout(() => setUndo(null), 8_000);
    return () => window.clearTimeout(timeout);
  }, [undo]);

  function openNew(title = "") {
    setDraft({ ...blankDraft(initialBirthdayId ?? null), title });
    setEditor("new");
  }

  function openEdit(idea: PresentIdea) {
    setDraft(ideaDraft(idea));
    setEditor(idea);
  }

  async function checkAndCreate(nextDraft: Draft, fromQuickAdd: boolean) {
    if (!selectedChild || selectedChild === "all") return;
    setBusy(fromQuickAdd ? "quick-add" : "save-new");
    setActionError(null);
    try {
      const result = await api<{ matches: DuplicateMatch[] }>("/children/presents/ideas/check-duplicate", {
        method: "POST",
        body: JSON.stringify({
          child_id: selectedChild,
          title: nextDraft.title.trim(),
          url: nextDraft.url.trim() || null,
        }),
      });
      if (result.matches.length) {
        setDuplicates(result.matches);
        setPendingCreate({ draft: nextDraft, fromQuickAdd });
        return;
      }
      await create(nextDraft, fromQuickAdd, false);
    } catch (requestError) {
      setActionError(requestError instanceof Error ? requestError.message : "The gift could not be saved.");
    } finally {
      setBusy(null);
    }
  }

  async function create(nextDraft: Draft, fromQuickAdd: boolean, allowDuplicate: boolean) {
    if (!selectedChild || selectedChild === "all") return;
    const created = await api<PresentIdea>("/children/presents/ideas", {
      method: "POST",
      body: JSON.stringify({
        child_id: selectedChild,
        event_year: new Date().getFullYear(),
        ...requestBody(nextDraft),
        allow_duplicate: allowDuplicate,
      }),
    });
    setIdeas((items) => [created, ...items]);
    if (fromQuickAdd) setQuickTitle("");
    else setEditor(null);
    setDuplicates([]);
    setPendingCreate(null);
    onDataChanged();
  }

  async function saveEditor(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (!draft.title.trim()) return;
    if (editor === "new") {
      await checkAndCreate(draft, false);
      return;
    }
    if (!editor) return;
    setBusy(`edit-${editor.id}`);
    setActionError(null);
    try {
      const updated = await api<PresentIdea>(`/children/presents/ideas/${editor.id}`, {
        method: "PUT",
        body: JSON.stringify(requestBody(draft)),
      });
      setIdeas((items) => replaceByID(items, updated));
      setEditor(null);
      onDataChanged();
    } catch (requestError) {
      setActionError(requestError instanceof Error ? requestError.message : "The gift could not be updated.");
    } finally {
      setBusy(null);
    }
  }

  async function quickAdd(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    const title = quickTitle.trim();
    if (!title) return;
    await checkAndCreate({ ...blankDraft(initialBirthdayId ?? null), title }, true);
  }

  async function setStatus(idea: PresentIdea, status: PresentStatus) {
    setBusy(`status-${idea.id}`);
    setActionError(null);
    try {
      const updated = await api<PresentIdea>(`/children/presents/ideas/${idea.id}/status`, {
        method: "PATCH",
        body: JSON.stringify({ status }),
      });
      setIdeas((items) => replaceByID(items, updated));
      onDataChanged();
    } catch (requestError) {
      setActionError(requestError instanceof Error ? requestError.message : "That status change did not save.");
    } finally {
      setBusy(null);
    }
  }

  async function deleteIdea(idea: PresentIdea) {
    setBusy(`delete-${idea.id}`);
    setActionError(null);
    try {
      await api<void>(`/children/presents/ideas/${idea.id}`, { method: "DELETE" });
      setIdeas((items) => items.filter((item) => item.id !== idea.id));
      setDetailID((current) => current === idea.id ? null : current);
      setUndo({ id: idea.id, title: idea.title });
      onDataChanged();
    } catch (requestError) {
      setActionError(requestError instanceof Error ? requestError.message : "The gift could not be removed.");
    } finally {
      setBusy(null);
    }
  }

  async function restore() {
    if (!undo) return;
    setBusy("undo");
    try {
      const restored = await api<PresentIdea>(`/children/presents/ideas/${undo.id}/restore`, { method: "POST" });
      setIdeas((items) => replaceByID(items, restored));
      setUndo(null);
      onDataChanged();
    } catch (requestError) {
      setActionError(requestError instanceof Error ? requestError.message : "Undo could not be completed.");
    } finally {
      setBusy(null);
    }
  }

  if (loading && !ideas.length) return <SkeletonList rows={5} />;
  if (loadError && !ideas.length) return <ErrorState message={loadError} retry={() => void load()} />;

  return <div className="gift-planner">
    <div className="gift-planner__heading">
      <div>
        <p className="page-eyebrow">Private gift plan</p>
        <h2>Gifts for {childName}</h2>
        <p>Capture first. Add buying and hiding details only when they matter.</p>
      </div>
      <div className="gift-planner__heading-actions">
        <label className="gift-switch">
          <input type="checkbox" checked={showGiven} onChange={(event) => setShowGiven(event.target.checked)} />
          Show given
        </label>
        <button type="button" className="button button--primary" onClick={() => openNew()}>
          <Plus aria-hidden="true" size={17} /> Add gift
        </button>
      </div>
    </div>

    {initialBirthdayId ? <div className="gift-birthday-context">
      <CalendarDays aria-hidden="true" size={18} />
      Showing gifts linked to this birthday.
    </div> : null}

    <form className="gift-quick-add" onSubmit={quickAdd}>
      <Gift aria-hidden="true" size={20} />
      <label className="sr-only" htmlFor="gift-quick-title">Gift idea</label>
      <input
        id="gift-quick-title"
        value={quickTitle}
        onChange={(event) => setQuickTitle(event.target.value)}
        placeholder={`Gift idea for ${childName}`}
        maxLength={300}
      />
      <button type="submit" className="button button--primary button--compact" disabled={!quickTitle.trim() || busy === "quick-add"}>
        {busy === "quick-add" ? "Adding…" : "Add"}
      </button>
    </form>
    <p className="gift-quick-add__hint">We’ll warn you if the same idea is already active.</p>

    {actionError ? <div className="gift-inline-error" role="alert">
      <span>{actionError}</span>
      <button type="button" onClick={() => setActionError(null)}>Dismiss</button>
    </div> : null}

    {!visibleIdeas.length ? <EmptyState
      title={showGiven ? "No gifts yet" : "No active gifts"}
      detail="Save the thought before it disappears; the logistics can come later."
      action={() => openNew()}
      actionLabel="Add gift"
    /> : <div className="gift-stages">
      {STATUSES.map((status) => {
        const stageIdeas = visibleIdeas.filter((idea) => idea.status === status);
        if (!stageIdeas.length) return null;
        return <section className="gift-stage" key={status} aria-labelledby={`gift-stage-${status}`}>
          <div className="gift-stage__heading">
            <h3 id={`gift-stage-${status}`}>{STATUS_LABEL[status]}</h3>
            <span>{stageIdeas.length}</span>
          </div>
          <div className="gift-stage__cards">
            {stageIdeas.map((idea) => {
              const next = nextStatus(idea.status);
              return <article className={cn("gift-card", `gift-card--${idea.status}`)} key={idea.id}>
                <button type="button" className="gift-card__open" onClick={() => setDetailID(idea.id)}>
                  <span>
                    <strong>{idea.title}</strong>
                    <small>{idea.occasion}</small>
                  </span>
                  <ChevronRight aria-hidden="true" size={18} />
                </button>
                <div className="gift-card__meta">
                  {idea.owner_name ? <span><UserRound aria-hidden="true" size={14} /> {idea.owner_name}</span> : null}
                  {idea.deadline ? <span className="is-due"><CalendarDays aria-hidden="true" size={14} /> {dateLabel(idea.deadline)}</span> : null}
                  {money(idea.price_minor, idea.currency) ? <span>{money(idea.price_minor, idea.currency)}</span> : null}
                </div>
                <div className="gift-card__actions">
                  {next ? <button
                    type="button"
                    className="button button--secondary button--compact"
                    disabled={busy === `status-${idea.id}`}
                    onClick={() => void setStatus(idea, next)}
                  >
                    <PackageCheck aria-hidden="true" size={15} /> {nextAction(idea.status)}
                  </button> : <span className="gift-complete"><CheckCircle2 aria-hidden="true" size={15} /> Complete</span>}
                  <button type="button" className="icon-button" aria-label={`Edit ${idea.title}`} onClick={() => openEdit(idea)}>
                    <Pencil aria-hidden="true" size={16} />
                  </button>
                  <button type="button" className="icon-button icon-button--danger" aria-label={`Delete ${idea.title}`} onClick={() => void deleteIdea(idea)}>
                    <Trash2 aria-hidden="true" size={16} />
                  </button>
                </div>
              </article>;
            })}
          </div>
        </section>;
      })}
    </div>}

    <Modal
      open={editor !== null}
      onOpenChange={(open) => { if (!open) setEditor(null); }}
      title={editor === "new" ? `New gift for ${childName}` : "Edit gift"}
      description="Only the useful details are required. Everything else can wait."
      size="wide"
    >
      <form className="gift-editor" onSubmit={saveEditor}>
        <div className="gift-editor__primary">
          <div className="field field--wide">
            <label htmlFor="gift-title">Gift</label>
            <input id="gift-title" autoFocus value={draft.title} maxLength={300} onChange={(event) => setDraft((value) => ({ ...value, title: event.target.value }))} required />
          </div>
          <div className="field">
            <label htmlFor="gift-occasion">Occasion</label>
            <input id="gift-occasion" list="gift-occasions" value={draft.occasion} maxLength={100} onChange={(event) => setDraft((value) => ({ ...value, occasion: event.target.value }))} required />
            <datalist id="gift-occasions"><option value="birthday" /><option value="christmas" /><option value="easter" /></datalist>
          </div>
          <div className="field">
            <label htmlFor="gift-status">Status</label>
            <select id="gift-status" value={draft.status} onChange={(event) => setDraft((value) => ({ ...value, status: event.target.value as PresentStatus }))}>
              {STATUSES.map((status) => <option value={status} key={status}>{STATUS_LABEL[status]}</option>)}
            </select>
          </div>
          <div className="field">
            <label htmlFor="gift-owner">Owner</label>
            <select id="gift-owner" value={draft.ownerID} onChange={(event) => setDraft((value) => ({ ...value, ownerID: event.target.value }))}>
              <option value="">Unassigned</option>
              {adults.map((adult) => <option value={adult.id} key={adult.id}>{adult.name}</option>)}
            </select>
          </div>
          <div className="field">
            <label htmlFor="gift-deadline">Needed by</label>
            <input id="gift-deadline" type="date" value={draft.deadline} onChange={(event) => setDraft((value) => ({ ...value, deadline: event.target.value }))} />
          </div>
        </div>

        <details className="gift-editor__details">
          <summary>More details</summary>
          <div className="gift-editor__detail-grid">
            <div className="field field--wide">
              <label htmlFor="gift-url">Shop link</label>
              <input id="gift-url" type="url" placeholder="https://…" value={draft.url} maxLength={2_000} onChange={(event) => setDraft((value) => ({ ...value, url: event.target.value }))} />
            </div>
            <div className="field">
              <label htmlFor="gift-retailer">Retailer</label>
              <input id="gift-retailer" value={draft.retailer} maxLength={200} onChange={(event) => setDraft((value) => ({ ...value, retailer: event.target.value }))} />
            </div>
            <div className="field">
              <label htmlFor="gift-budget">Budget (£)</label>
              <input id="gift-budget" inputMode="decimal" type="number" min="0" step="0.01" value={draft.budget} onChange={(event) => setDraft((value) => ({ ...value, budget: event.target.value }))} />
            </div>
            <div className="field">
              <label htmlFor="gift-price">Price paid (£)</label>
              <input id="gift-price" inputMode="decimal" type="number" min="0" step="0.01" value={draft.price} onChange={(event) => setDraft((value) => ({ ...value, price: event.target.value }))} />
            </div>
            <div className="field">
              <label htmlFor="gift-hiding">Hiding place</label>
              <input id="gift-hiding" value={draft.hidingLocation} maxLength={500} onChange={(event) => setDraft((value) => ({ ...value, hidingLocation: event.target.value }))} />
            </div>
            <div className="field field--wide">
              <label htmlFor="gift-notes">Notes</label>
              <textarea id="gift-notes" rows={3} value={draft.notes} maxLength={2_000} onChange={(event) => setDraft((value) => ({ ...value, notes: event.target.value }))} />
            </div>
            <label className="gift-privacy field--wide">
              <input type="checkbox" checked={draft.hiddenFromRecipient} onChange={(event) => setDraft((value) => ({ ...value, hiddenFromRecipient: event.target.checked }))} />
              <span><LockKeyhole aria-hidden="true" size={18} /><strong>Keep hidden from recipient</strong><small>Gift plans and hiding places are private by default.</small></span>
            </label>
          </div>
        </details>

        <div className="dialog-actions">
          <button type="button" className="button button--secondary" onClick={() => setEditor(null)}>Cancel</button>
          <button type="submit" className="button button--primary" disabled={!draft.title.trim() || !draft.occasion.trim() || busy?.startsWith("edit-") || busy === "save-new"}>
            {busy?.startsWith("edit-") || busy === "save-new" ? "Saving…" : "Save gift"}
          </button>
        </div>
      </form>
    </Modal>

    <Modal open={detail !== null} onOpenChange={(open) => { if (!open) setDetailID(null); }} title={detail?.title ?? "Gift"} size="wide">
      {detail ? <div className="gift-detail">
        <div className="gift-detail__status">
          <span className={cn("gift-status", `gift-status--${detail.status}`)}>{STATUS_LABEL[detail.status]}</span>
          <label>
            <span className="sr-only">Correct status</span>
            <select value={detail.status} onChange={(event) => void setStatus(detail, event.target.value as PresentStatus)}>
              {STATUSES.map((status) => <option value={status} key={status}>{STATUS_LABEL[status]}</option>)}
            </select>
          </label>
        </div>
        <dl className="gift-detail__facts">
          <div><dt>Recipient</dt><dd>{detail.recipient_name ?? childName}</dd></div>
          <div><dt>Occasion</dt><dd>{detail.occasion}</dd></div>
          {detail.owner_name ? <div><dt>Owner</dt><dd>{detail.owner_name}</dd></div> : null}
          {detail.deadline ? <div><dt>Needed by</dt><dd>{dateLabel(detail.deadline)}</dd></div> : null}
          {money(detail.budget_minor, detail.currency) ? <div><dt>Budget</dt><dd>{money(detail.budget_minor, detail.currency)}</dd></div> : null}
          {money(detail.price_minor, detail.currency) ? <div><dt>Price paid</dt><dd>{money(detail.price_minor, detail.currency)}</dd></div> : null}
          {detail.retailer ? <div><dt>Retailer</dt><dd>{detail.retailer}</dd></div> : null}
          {detail.hiding_location ? <div><dt>Hiding place</dt><dd>{detail.hiding_location}</dd></div> : null}
        </dl>
        {detail.url ? <a className="button button--secondary gift-detail__link" href={detail.url} target="_blank" rel="noreferrer">
          <ExternalLink aria-hidden="true" size={16} /> Open shop link
        </a> : null}
        {detail.notes ? <div className="gift-detail__notes"><strong>Notes</strong><p>{detail.notes}</p></div> : null}
        {detail.status_history.length ? <div className="gift-history">
          <h3>History</h3>
          <ol>
            {[...detail.status_history].reverse().map((entry) => <li key={entry.id}>
              <span className={cn("gift-history__dot", `gift-history__dot--${entry.to_status}`)} />
              <div><strong>{STATUS_LABEL[entry.to_status]}</strong><small>{entry.changed_by_name ?? "Family"} · {dateTimeLabel(entry.changed_at)}</small></div>
            </li>)}
          </ol>
        </div> : null}
        <div className="dialog-actions">
          <button type="button" className="button button--secondary" onClick={() => { setDetailID(null); openEdit(detail); }}><Pencil aria-hidden="true" size={16} /> Edit</button>
          {nextStatus(detail.status) ? <button type="button" className="button button--primary" onClick={() => void setStatus(detail, nextStatus(detail.status)!)}>{nextAction(detail.status)}</button> : null}
        </div>
      </div> : null}
    </Modal>

    <Modal open={duplicates.length > 0} onOpenChange={(open) => { if (!open) { setDuplicates([]); setPendingCreate(null); } }} title="Possible duplicate" description="A similar active gift already exists for this recipient.">
      <div className="gift-duplicates">
        {duplicates.map((match) => <button type="button" key={match.id} onClick={() => { setDuplicates([]); setPendingCreate(null); setEditor(null); setDetailID(match.id); }}>
          <span><strong>{match.title}</strong><small>{match.occasion} · {STATUS_LABEL[match.status]}</small></span>
          <ChevronRight aria-hidden="true" size={18} />
        </button>)}
      </div>
      <div className="dialog-actions">
        <button type="button" className="button button--secondary" onClick={() => { setDuplicates([]); setPendingCreate(null); }}>Review list</button>
        <button type="button" className="button button--primary" onClick={() => {
          if (!pendingCreate) return;
          setBusy("force-create");
          void create(pendingCreate.draft, pendingCreate.fromQuickAdd, true)
            .catch((error: unknown) => setActionError(error instanceof Error ? error.message : "The gift could not be saved."))
            .finally(() => setBusy(null));
        }} disabled={busy === "force-create"}>{busy === "force-create" ? "Adding…" : "Add anyway"}</button>
      </div>
    </Modal>

    {undo ? <div className="gift-undo" role="status">
      <span>Removed {undo.title}</span>
      <button type="button" onClick={() => void restore()} disabled={busy === "undo"}><RotateCcw aria-hidden="true" size={15} /> Undo</button>
    </div> : null}
  </div>;
}
