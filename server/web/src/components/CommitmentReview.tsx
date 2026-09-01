import {
  CalendarPlus,
  Check,
  CheckCircle2,
  ChevronLeft,
  ClipboardList,
  ExternalLink,
  ListPlus,
  MapPin,
  PackageCheck,
  Plus,
  Save,
  Trash2,
  TriangleAlert,
  RefreshCw,
  UserRound,
} from "lucide-react";
import { useEffect, useMemo, useRef, useState, type FormEvent } from "react";

import { api, isOfflineQueuedResult, localISODateTime } from "../api";
import {
  commitmentKindLabel,
  type Commitment,
  type CommitmentEventDraft,
  type CommitmentExternalAction,
  type CommitmentPreparationDraft,
  type CommitmentSource,
  type CommitmentTaskDraft,
} from "../commitments/contract";
import type { FamilyDocument, FamilyMember } from "../types";
import { cn } from "./ui";

function cloneCommitment(value: Commitment): Commitment {
  return JSON.parse(JSON.stringify(value)) as Commitment;
}

function formFingerprint(value: Commitment): string {
  return JSON.stringify({
    visibility: value.visibility,
    title: value.title,
    summary: value.summary ?? null,
    sources: value.sources,
    plan: value.plan,
    group_key: value.group_key ?? null,
  });
}

function localDateTimeInput(value?: string | null): string {
  if (!value) return "";
  if (value.length === 10) return value;
  const parsed = new Date(value);
  if (Number.isNaN(parsed.getTime())) return "";
  const offset = parsed.getTimezoneOffset() * 60_000;
  return new Date(parsed.getTime() - offset).toISOString().slice(0, 16);
}

function apiDateTime(value: string): string {
  return localISODateTime(new Date(value));
}

function tomorrowAtNine(): string {
  const value = new Date();
  value.setDate(value.getDate() + 1);
  value.setHours(9, 0, 0, 0);
  return localISODateTime(value);
}

function mutationID(ref: React.MutableRefObject<Map<string, string>>, key: string): string {
  const existing = ref.current.get(key);
  if (existing) return existing;
  const id = crypto.randomUUID();
  ref.current.set(key, id);
  return id;
}

function externalHref(action: CommitmentExternalAction): string | null {
  if (action.target_type === "https") {
    try {
      const url = new URL(action.target);
      return url.protocol === "https:" ? url.toString() : null;
    } catch {
      return null;
    }
  }
  if (action.target_type === "email" && /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(action.target)) return `mailto:${action.target}`;
  if (action.target_type === "phone" && /^\+?[0-9 ()-]{5,30}$/.test(action.target)) return `tel:${action.target.replace(/[^+\d]/g, "")}`;
  return null;
}

function outcomeFor(action: CommitmentExternalAction): "accepted" | "booked" | "replied" | "completed" | "other" {
  if (action.kind === "book" || action.kind === "register") return "booked";
  if (action.kind === "rsvp") return "replied";
  if (action.kind === "contact") return "replied";
  if (action.kind === "pay") return "completed";
  return "other";
}

function errorCopy(error: unknown, fallback: string): string {
  return error instanceof Error ? error.message : fallback;
}

export function CommitmentReview({
  commitment,
  currentUserID,
  members,
  onBack,
  onUpdated,
  onQueued,
}: {
  commitment: Commitment;
  currentUserID: string;
  members: FamilyMember[];
  onBack: () => void;
  onUpdated: (commitment: Commitment) => void;
  onQueued: (message: string) => void;
}) {
  const [draft, setDraft] = useState(() => cloneCommitment(commitment));
  const [savedFingerprint, setSavedFingerprint] = useState(() => formFingerprint(commitment));
  const [busy, setBusy] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [notice, setNotice] = useState<string | null>(null);
  const [declining, setDeclining] = useState(false);
  const [declineReason, setDeclineReason] = useState("");
  const [documents, setDocuments] = useState<FamilyDocument[]>([]);
  const [documentsLoading, setDocumentsLoading] = useState(false);
  const [documentsLoaded, setDocumentsLoaded] = useState(false);
  const [documentsError, setDocumentsError] = useState<string | null>(null);
  const operationIDs = useRef(new Map<string, string>());

  useEffect(() => {
    setDraft(cloneCommitment(commitment));
    setSavedFingerprint(formFingerprint(commitment));
    setError(null);
  }, [commitment]);

  const fingerprint = useMemo(() => formFingerprint(draft), [draft]);
  const dirty = fingerprint !== savedFingerprint;
  const action = draft.plan.external_action ?? null;
  const actionHref = action ? externalHref(action) : null;
  const ownsCommitment = draft.owner_user_id === currentUserID;
  const actionBlocksConfirm = Boolean(action?.requires_completion_before_confirm && draft.external_action_status !== "completed");
  const canConfirm = !dirty
    && !draft.review_issues.length
    && !actionBlocksConfirm
    && draft.visibility === "family"
    && busy === null;
  const adultMembers = useMemo(() => members.filter((member) => member.member_type === "user"), [members]);

  function updateEvent(index: number, patch: Partial<CommitmentEventDraft>) {
    setDraft((current) => ({ ...current, plan: { ...current.plan, events: current.plan.events.map((item, itemIndex) => itemIndex === index ? { ...item, ...patch } : item) } }));
  }

  function removeEvent(index: number) {
    setDraft((current) => {
      const eventID = current.plan.events[index]?.id;
      return { ...current, plan: { ...current.plan, events: current.plan.events.filter((_, itemIndex) => itemIndex !== index), preparations: current.plan.preparations.filter((item) => item.event_id !== eventID) } };
    });
  }

  function addEvent() {
    setDraft((current) => ({ ...current, plan: { ...current.plan, events: [...current.plan.events, {
      id: crypto.randomUUID(), title: "New event", description: null, start_time: tomorrowAtNine(), end_time: null, all_day: false, location: null, person_ids: [], affected_adult_ids: [], assigned_to: null, event_type: current.kind === "childcare" ? "childcare" : current.kind, document_ids: [],
    }] } }));
  }

  function toggleEventPerson(index: number, personID: string) {
    const event = draft.plan.events[index];
    const selected = event.person_ids.includes(personID);
    updateEvent(index, {
      person_ids: selected ? event.person_ids.filter((id) => id !== personID) : [...event.person_ids, personID],
      affected_adult_ids: selected ? event.affected_adult_ids : event.affected_adult_ids.filter((id) => id !== personID),
    });
  }

  function toggleAffectedAdult(index: number, personID: string) {
    const event = draft.plan.events[index];
    const selected = event.affected_adult_ids.includes(personID);
    updateEvent(index, {
      affected_adult_ids: selected ? event.affected_adult_ids.filter((id) => id !== personID) : [...event.affected_adult_ids, personID],
      person_ids: selected ? event.person_ids : event.person_ids.filter((id) => id !== personID),
      assigned_to: !selected && event.assigned_to === personID ? null : event.assigned_to,
    });
  }

  async function loadDocuments(force = false) {
    if (documentsLoading || (documentsLoaded && !force)) return;
    setDocumentsLoading(true);
    setDocumentsError(null);
    try {
      const loaded = await api<FamilyDocument[]>("/documents/?offset=0&limit=100");
      setDocuments(Array.isArray(loaded) ? loaded.filter((document) => document.status !== "archived") : []);
      setDocumentsLoaded(true);
    } catch (requestError) {
      setDocumentsError(errorCopy(requestError, "Documents could not be loaded."));
    } finally {
      setDocumentsLoading(false);
    }
  }

  function updateTask(index: number, patch: Partial<CommitmentTaskDraft>) {
    setDraft((current) => ({ ...current, plan: { ...current.plan, tasks: current.plan.tasks.map((item, itemIndex) => itemIndex === index ? { ...item, ...patch } : item) } }));
  }

  function addTask() {
    setDraft((current) => ({ ...current, plan: { ...current.plan, tasks: [...current.plan.tasks, { id: crypto.randomUUID(), title: "New task", description: null, due_date: null, actionable_from: null, assigned_to: null, priority: 2, document_id: null }] } }));
  }

  function updatePreparation(index: number, patch: Partial<CommitmentPreparationDraft>) {
    setDraft((current) => ({ ...current, plan: { ...current.plan, preparations: current.plan.preparations.map((item, itemIndex) => itemIndex === index ? { ...item, ...patch } : item) } }));
  }

  function addPreparation() {
    const eventID = draft.plan.events[0]?.id;
    if (!eventID) return;
    setDraft((current) => ({ ...current, plan: { ...current.plan, preparations: [...current.plan.preparations, { id: crypto.randomUUID(), event_id: eventID, name: "Preparation", items: ["Add what needs preparing"], lead_hours: 24, assigned_to: null }] } }));
  }

  function updateSource(index: number, patch: Partial<CommitmentSource>) {
    setDraft((current) => ({ ...current, sources: current.sources.map((item, itemIndex) => itemIndex === index ? { ...item, ...patch } : item) }));
  }

  function updateExternalAction(patch: Partial<CommitmentExternalAction>) {
    setDraft((current) => current.plan.external_action ? ({
      ...current,
      plan: {
        ...current.plan,
        external_action: { ...current.plan.external_action, ...patch },
      },
    }) : current);
  }

  async function save(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    setBusy("save");
    setError(null);
    setNotice(null);
    const timestamp = new Date().toISOString();
    const offlineID = mutationID(operationIDs, `save:${draft.revision}:${fingerprint}`);
    try {
      const updated = await api<Commitment>(`/commitments/${encodeURIComponent(draft.id)}`, {
        method: "PATCH",
        offlineOperationId: offlineID,
        body: JSON.stringify({
          expected_revision: draft.revision,
          visibility: draft.visibility,
          title: draft.title.trim(),
          summary: draft.summary?.trim() || null,
          sources: draft.sources,
          plan: draft.plan,
          group_key: draft.group_key?.trim() || null,
          client_id: "hausklar-web",
          client_timestamp: timestamp,
        }),
      });
      if (isOfflineQueuedResult(updated)) {
        onQueued("Your plan edits are saved on this device. Reopen the plan after they sync before confirming it.");
        return;
      }
      setDraft(cloneCommitment(updated));
      setSavedFingerprint(formFingerprint(updated));
      setNotice("Plan changes saved. Nothing has been added to the calendar yet.");
      onUpdated(updated);
    } catch (requestError) {
      setError(errorCopy(requestError, "Plan changes could not be saved."));
    } finally {
      setBusy(null);
    }
  }

  async function markActionDone() {
    if (!action || dirty) return;
    setBusy("action");
    setError(null);
    setNotice(null);
    const timestamp = new Date().toISOString();
    try {
      const updated = await api<Commitment>(`/commitments/${encodeURIComponent(draft.id)}/external-action/complete`, {
        method: "POST",
        offlineOperationId: mutationID(operationIDs, `action:${draft.revision}`),
        body: JSON.stringify({ expected_revision: draft.revision, completed: true, outcome: outcomeFor(action), client_id: "hausklar-web", client_timestamp: timestamp }),
      });
      if (isOfflineQueuedResult(updated)) {
        onQueued("Done is saved on this device. Reopen the plan after it syncs before confirming it.");
        return;
      }
      setNotice("Outside step marked done. HausKlar did not contact the provider.");
      onUpdated(updated);
    } catch (requestError) {
      setError(errorCopy(requestError, "That outside step could not be marked done."));
    } finally {
      setBusy(null);
    }
  }

  async function confirm() {
    if (!canConfirm) return;
    setBusy("confirm");
    setError(null);
    setNotice(null);
    const timestamp = new Date().toISOString();
    try {
      const updated = await api<Commitment>(`/commitments/${encodeURIComponent(draft.id)}/confirm`, {
        method: "POST",
        offlineOperationId: mutationID(operationIDs, `confirm:${draft.revision}`),
        body: JSON.stringify({ expected_revision: draft.revision, confirmed: true, client_id: "hausklar-web", client_timestamp: timestamp }),
      });
      if (isOfflineQueuedResult(updated)) {
        onQueued("Confirmation is saved on this device and will create the reviewed calendar and task items when it syncs.");
        return;
      }
      onUpdated(updated);
    } catch (requestError) {
      setError(errorCopy(requestError, "This plan could not be confirmed."));
    } finally {
      setBusy(null);
    }
  }

  async function decline() {
    setBusy("decline");
    setError(null);
    const timestamp = new Date().toISOString();
    try {
      const updated = await api<Commitment>(`/commitments/${encodeURIComponent(draft.id)}/decline`, {
        method: "POST",
        offlineOperationId: mutationID(operationIDs, `decline:${draft.revision}`),
        body: JSON.stringify({ expected_revision: draft.revision, reason: declineReason.trim() || null, client_id: "hausklar-web", client_timestamp: timestamp }),
      });
      if (isOfflineQueuedResult(updated)) {
        onQueued("Decline is saved on this device and will sync when you reconnect.");
        return;
      }
      onUpdated(updated);
    } catch (requestError) {
      setError(errorCopy(requestError, "This plan could not be declined."));
    } finally {
      setBusy(null);
    }
  }

  return (
    <form className="commitment-review" aria-busy={busy !== null} onSubmit={(event) => void save(event)}>
      <button type="button" className="commitments-back" onClick={onBack}><ChevronLeft aria-hidden="true" size={17} /> All plans</button>
      <header className="commitment-review__hero">
        <div><span className={`commitment-kind-mark is-${draft.kind}`}>{commitmentKindLabel(draft.kind).slice(0, 1)}</span><p>{commitmentKindLabel(draft.kind)} · revision {draft.revision}</p><h2>{draft.title}</h2><small>{draft.visibility === "family" ? "Shared family plan" : "Private to its owner until shared"}</small></div>
        <span className={cn("commitment-status", `is-${draft.status}`)}>{draft.status === "action_required" ? "Outside step needed" : draft.status === "ready" ? "Ready to confirm" : "Draft"}</span>
      </header>

      {draft.review_issues.length ? <section className="commitment-review-issues" aria-labelledby="commitment-issues-title"><TriangleAlert aria-hidden="true" size={20} /><div><h3 id="commitment-issues-title">Check before confirming</h3><ul>{draft.review_issues.map((issue) => <li key={issue}>{issue}</li>)}</ul>{dirty ? <small>Save your edits to refresh this check.</small> : null}</div></section> : null}
      {draft.supersedes_id ? <section className="commitment-change-summary" aria-labelledby="commitment-change-title"><RefreshCw aria-hidden="true" size={20} /><div><h3 id="commitment-change-title">What changed from the earlier plan</h3>{draft.change_summary.length ? <ul>{draft.change_summary.map((change) => <li key={change}>{change}</li>)}</ul> : <p>No material plan changes were detected. Review the source and dates before confirming.</p>}<small>The earlier plan has not been altered or removed.</small></div></section> : null}
      {notice ? <p className="form-success" role="status"><CheckCircle2 aria-hidden="true" size={17} /> {notice}</p> : null}
      {error ? <p className="form-error" role="alert">{error}</p> : null}

      <section className="commitment-review-section" aria-labelledby="commitment-basics-title">
        <header><ClipboardList aria-hidden="true" size={20} /><div><h3 id="commitment-basics-title">Plan basics</h3><p>Keep the summary short enough to scan later.</p></div></header>
        <div className="commitment-form-grid">
          <div className="field is-wide"><label htmlFor="commitment-title">Title</label><input id="commitment-title" required maxLength={300} value={draft.title} onChange={(event) => setDraft((current) => ({ ...current, title: event.target.value }))} /></div>
          <div className="field"><label htmlFor="commitment-visibility">Who can see it?</label><select id="commitment-visibility" value={draft.visibility} disabled={!ownsCommitment} onChange={(event) => setDraft((current) => ({ ...current, visibility: event.target.value as Commitment["visibility"] }))}><option value="family">Family</option><option value="owner">Just its owner</option></select>{!ownsCommitment ? <small>Only the person who started this plan can change who sees it.</small> : null}</div>
          {draft.kind === "travel" ? <div className="field"><label htmlFor="commitment-group">Trip group or reference</label><input id="commitment-group" value={draft.group_key ?? ""} maxLength={200} placeholder="ABC123" onChange={(event) => setDraft((current) => ({ ...current, group_key: event.target.value }))} /></div> : null}
          <div className="field is-wide"><label htmlFor="commitment-summary">Summary <span>(optional)</span></label><textarea id="commitment-summary" rows={4} maxLength={10000} value={draft.summary ?? ""} onChange={(event) => setDraft((current) => ({ ...current, summary: event.target.value }))} /></div>
        </div>
        <details className="commitment-sources"><summary>Sources and references ({draft.sources.length})</summary><div>{draft.sources.map((source, index) => <article key={source.id}><strong>{source.kind === "document" ? "Document" : "Source"} {index + 1}</strong><div className="commitment-form-grid"><div className="field"><label htmlFor={`source-label-${source.id}`}>Label</label><input id={`source-label-${source.id}`} value={source.label ?? ""} onChange={(event) => updateSource(index, { label: event.target.value || null })} /></div><div className="field"><label htmlFor={`source-reference-${source.id}`}>Reference <span>(optional)</span></label><input id={`source-reference-${source.id}`} value={source.provider_reference ?? ""} onChange={(event) => updateSource(index, { provider_reference: event.target.value || null })} /></div></div></article>)}</div></details>
      </section>

      <section className="commitment-review-section" aria-labelledby="commitment-events-title">
        <header><CalendarPlus aria-hidden="true" size={20} /><div><h3 id="commitment-events-title">Events</h3><p>{draft.kind === "travel" ? "Keep every journey, connection and stay in this one trip." : "These dates reach the family calendar only after confirmation."}</p></div><button type="button" className="button button--secondary" onClick={addEvent}><Plus aria-hidden="true" size={16} /> Add event</button></header>
        {draft.plan.events.length ? <div className="commitment-edit-list">{draft.plan.events.map((item, index) => <article key={item.id}>
          <div className="commitment-edit-list__heading"><strong>Event {index + 1}</strong><button type="button" className="icon-button" aria-label={`Remove event ${index + 1}`} onClick={() => removeEvent(index)}><Trash2 aria-hidden="true" size={17} /></button></div>
          <div className="commitment-form-grid">
            <div className="field is-wide"><label htmlFor={`event-title-${item.id}`}>Title</label><input id={`event-title-${item.id}`} required value={item.title} onChange={(event) => updateEvent(index, { title: event.target.value })} /></div>
            <label className="commitment-check"><input type="checkbox" checked={item.all_day} onChange={(event) => {
              const allDay = event.target.checked;
              const startDate = item.start_time.slice(0, 10);
              updateEvent(index, { all_day: allDay, start_time: allDay ? startDate : apiDateTime(`${startDate}T09:00`), end_time: null });
            }} /><span><strong>All day</strong><small>Use a date without inventing a time</small></span></label>
            <div className="field"><label htmlFor={`event-start-${item.id}`}>{item.all_day ? "Date" : "Starts"}</label><input id={`event-start-${item.id}`} type={item.all_day ? "date" : "datetime-local"} required value={localDateTimeInput(item.start_time)} onChange={(event) => updateEvent(index, { start_time: item.all_day ? event.target.value : apiDateTime(event.target.value) })} /></div>
            <div className="field"><label htmlFor={`event-end-${item.id}`}>Ends <span>(optional)</span></label><input id={`event-end-${item.id}`} type={item.all_day ? "date" : "datetime-local"} value={localDateTimeInput(item.end_time)} onChange={(event) => updateEvent(index, { end_time: event.target.value ? (item.all_day ? event.target.value : apiDateTime(event.target.value)) : null })} /></div>
            <div className="field is-wide"><label htmlFor={`event-location-${item.id}`}><MapPin aria-hidden="true" size={15} /> Location <span>(optional)</span></label><input id={`event-location-${item.id}`} value={item.location ?? ""} onChange={(event) => updateEvent(index, { location: event.target.value || null })} /></div>
          </div>
          <fieldset className="commitment-people is-compact"><legend>People</legend><div>{members.map((member) => <label key={member.id}><input type="checkbox" checked={item.person_ids.includes(member.id)} onChange={() => toggleEventPerson(index, member.id)} /><span>{member.name}</span></label>)}</div></fieldset>
          <details className="commitment-item-more">
            <summary>More event details{item.affected_adult_ids.length ? ` · ${item.affected_adult_ids.length} affected` : ""}</summary>
            <div className="commitment-form-grid">
              <div className="field is-wide"><label htmlFor={`event-description-${item.id}`}>Notes <span>(optional)</span></label><textarea id={`event-description-${item.id}`} rows={3} maxLength={10000} value={item.description ?? ""} onChange={(event) => updateEvent(index, { description: event.target.value || null })} /></div>
              <div className="field"><label htmlFor={`event-assigned-${item.id}`}>Lead person <span>(optional)</span></label><select id={`event-assigned-${item.id}`} value={item.assigned_to ?? ""} onChange={(event) => { const assignedTo = event.target.value || null; updateEvent(index, { assigned_to: assignedTo, affected_adult_ids: assignedTo ? item.affected_adult_ids.filter((id) => id !== assignedTo) : item.affected_adult_ids }); }}><option value="">No lead person</option>{members.map((member) => <option value={member.id} key={member.id}>{member.name}</option>)}</select><small>This person is included in the calendar event when the plan is confirmed.</small></div>
              {adultMembers.length ? <fieldset className="commitment-people is-compact is-wide"><legend>Affected adults</legend><div>{adultMembers.map((member) => <label key={member.id}><input type="checkbox" checked={item.affected_adult_ids.includes(member.id)} onChange={() => toggleAffectedAdult(index, member.id)} /><span>{member.name}</span></label>)}</div><small>Choose an adult whose availability or family cover changes, but who is not attending.</small></fieldset> : null}
            </div>
          </details>
        </article>)}</div> : <p className="commitment-inline-empty">No event yet. Add only the date HausKlar genuinely needs.</p>}
      </section>

      <section className="commitment-review-section" aria-labelledby="commitment-tasks-title">
        <header><ListPlus aria-hidden="true" size={20} /><div><h3 id="commitment-tasks-title">Tasks</h3><p>Actions that need doing, separate from what needs packing.</p></div><button type="button" className="button button--secondary" onClick={addTask}><Plus aria-hidden="true" size={16} /> Add task</button></header>
        {draft.plan.tasks.length ? <div className="commitment-edit-list is-compact">{draft.plan.tasks.map((item, index) => {
          const currentDocumentMissing = Boolean(item.document_id && !documents.some((document) => document.id === item.document_id));
          return <article key={item.id}><div className="commitment-edit-list__heading"><strong>Task {index + 1}</strong><button type="button" className="icon-button" aria-label={`Remove task ${index + 1}`} onClick={() => setDraft((current) => ({ ...current, plan: { ...current.plan, tasks: current.plan.tasks.filter((_, itemIndex) => itemIndex !== index) } }))}><Trash2 aria-hidden="true" size={17} /></button></div><div className="commitment-form-grid"><div className="field is-wide"><label htmlFor={`task-title-${item.id}`}>Title</label><input id={`task-title-${item.id}`} required value={item.title} onChange={(event) => updateTask(index, { title: event.target.value })} /></div><div className="field"><label htmlFor={`task-due-${item.id}`}>Due <span>(optional)</span></label><input id={`task-due-${item.id}`} type="date" value={item.due_date?.slice(0, 10) ?? ""} onChange={(event) => { const dueDate = event.target.value || null; updateTask(index, { due_date: dueDate, actionable_from: dueDate && item.actionable_from && item.actionable_from > dueDate ? dueDate : item.actionable_from }); }} /></div><div className="field"><label htmlFor={`task-person-${item.id}`}>For <span>(optional)</span></label><select id={`task-person-${item.id}`} value={item.assigned_to ?? ""} onChange={(event) => updateTask(index, { assigned_to: event.target.value || null })}><option value="">Anyone</option>{members.map((member) => <option value={member.id} key={member.id}>{member.name}</option>)}</select></div></div>
            <details className="commitment-item-more" onToggle={(event) => { if (event.currentTarget.open) void loadDocuments(); }}>
              <summary>More task details</summary>
              <div className="commitment-form-grid">
                <div className="field is-wide"><label htmlFor={`task-description-${item.id}`}>Notes <span>(optional)</span></label><textarea id={`task-description-${item.id}`} rows={3} maxLength={10000} value={item.description ?? ""} onChange={(event) => updateTask(index, { description: event.target.value || null })} /></div>
                <div className="field"><label htmlFor={`task-actionable-${item.id}`}>Available from <span>(optional)</span></label><input id={`task-actionable-${item.id}`} type="date" max={item.due_date?.slice(0, 10) || undefined} value={item.actionable_from?.slice(0, 10) ?? ""} onChange={(event) => updateTask(index, { actionable_from: event.target.value || null })} /><small>Keep this date-only so it behaves consistently in Tasks.</small></div>
                <div className="field"><label htmlFor={`task-priority-${item.id}`}>Priority</label><select id={`task-priority-${item.id}`} value={item.priority} onChange={(event) => updateTask(index, { priority: Number(event.target.value) })}><option value="1">Low</option><option value="2">Normal</option><option value="3">Important</option></select></div>
                <div className="field is-wide"><label htmlFor={`task-document-${item.id}`}>Linked document <span>(optional)</span></label><select id={`task-document-${item.id}`} value={item.document_id ?? ""} disabled={documentsLoading} onChange={(event) => updateTask(index, { document_id: event.target.value || null })}><option value="">No linked document</option>{currentDocumentMissing ? <option value={item.document_id ?? ""}>Current linked document</option> : null}{documents.map((document) => <option value={document.id} key={document.id}>{document.title}</option>)}</select>{documentsLoading ? <small role="status">Loading documents…</small> : documentsError ? <small className="commitment-field-error">{documentsError} <button type="button" onClick={() => void loadDocuments(true)}>Try again</button></small> : <small>The document remains linked to the task created on confirmation.</small>}</div>
              </div>
            </details>
          </article>;
        })}</div> : <p className="commitment-inline-empty">No separate tasks.</p>}
      </section>

      <section className="commitment-review-section" aria-labelledby="commitment-prep-title">
        <header><PackageCheck aria-hidden="true" size={20} /><div><h3 id="commitment-prep-title">Preparation</h3><p>Things to pack or prepare appear as linked tasks at the right time.</p></div><button type="button" className="button button--secondary" disabled={!draft.plan.events.length} onClick={addPreparation}><Plus aria-hidden="true" size={16} /> Add preparation</button></header>
        {draft.plan.preparations.length ? <div className="commitment-edit-list is-compact">{draft.plan.preparations.map((item, index) => <article key={item.id}><div className="commitment-edit-list__heading"><strong>Preparation {index + 1}</strong><button type="button" className="icon-button" aria-label={`Remove preparation ${index + 1}`} onClick={() => setDraft((current) => ({ ...current, plan: { ...current.plan, preparations: current.plan.preparations.filter((_, itemIndex) => itemIndex !== index) } }))}><Trash2 aria-hidden="true" size={17} /></button></div><div className="commitment-form-grid"><div className="field"><label htmlFor={`prep-name-${item.id}`}>Group name</label><input id={`prep-name-${item.id}`} required value={item.name} onChange={(event) => updatePreparation(index, { name: event.target.value })} /></div><div className="field"><label htmlFor={`prep-event-${item.id}`}>For event</label><select id={`prep-event-${item.id}`} value={item.event_id} onChange={(event) => updatePreparation(index, { event_id: event.target.value })}>{draft.plan.events.map((event) => <option value={event.id} key={event.id}>{event.title}</option>)}</select></div><div className="field is-wide"><label htmlFor={`prep-items-${item.id}`}>Items <span>(one per line)</span></label><textarea id={`prep-items-${item.id}`} required rows={4} value={item.items.join("\n")} onChange={(event) => updatePreparation(index, { items: event.target.value.split("\n").map((value) => value.trim()).filter(Boolean) })} /></div><div className="field"><label htmlFor={`prep-lead-${item.id}`}>Start preparing</label><select id={`prep-lead-${item.id}`} value={item.lead_hours} onChange={(event) => updatePreparation(index, { lead_hours: Number(event.target.value) })}><option value="0">At the event</option><option value="12">12 hours before</option><option value="24">1 day before</option><option value="48">2 days before</option><option value="168">1 week before</option></select></div><div className="field"><label htmlFor={`prep-person-${item.id}`}>For <span>(optional)</span></label><select id={`prep-person-${item.id}`} value={item.assigned_to ?? ""} onChange={(event) => updatePreparation(index, { assigned_to: event.target.value || null })}><option value="">Anyone</option>{members.map((member) => <option value={member.id} key={member.id}>{member.name}</option>)}</select></div></div></article>)}</div> : <p className="commitment-inline-empty">No preparation items.</p>}
      </section>

      <section className="commitment-review-section" aria-labelledby="commitment-action-title">
        <header><ExternalLink aria-hidden="true" size={20} /><div><h3 id="commitment-action-title">Outside HausKlar</h3><p>Booking, replying and paying still happen with the provider. HausKlar records only your acknowledgement.</p></div></header>
        <label className="commitment-check"><input type="checkbox" checked={Boolean(action)} onChange={(event) => setDraft((current) => ({ ...current, external_action_status: event.target.checked ? "pending" : "not_required", plan: { ...current.plan, external_action: event.target.checked ? { kind: "other", label: "Complete the outside step", target_type: "manual", target: "Follow the instructions in the source", due_at: null, requires_completion_before_confirm: false } : null } }))} /><span><strong>This plan has an outside step</strong><small>HausKlar will never press the provider’s button for you.</small></span></label>
        {action ? (
          <div className="commitment-external-card">
            <div className="commitment-form-grid">
              <div className="field"><label htmlFor="action-kind">Action</label><select id="action-kind" value={action.kind} onChange={(event) => updateExternalAction({ kind: event.target.value as CommitmentExternalAction["kind"] })}><option value="rsvp">RSVP</option><option value="book">Book</option><option value="register">Register or check in</option><option value="contact">Contact</option><option value="pay">Pay</option><option value="other">Other</option></select></div>
              <div className="field"><label htmlFor="action-due">Due <span>(optional)</span></label><input id="action-due" type="date" value={action.due_at?.slice(0, 10) ?? ""} onChange={(event) => updateExternalAction({ due_at: event.target.value || null })} /></div>
              <div className="field is-wide"><label htmlFor="action-label">Button label</label><input id="action-label" required value={action.label} onChange={(event) => updateExternalAction({ label: event.target.value })} /></div>
              <div className="field"><label htmlFor="action-target-kind">How it opens</label><select id="action-target-kind" value={action.target_type} onChange={(event) => updateExternalAction({ target_type: event.target.value as CommitmentExternalAction["target_type"] })}><option value="https">Website</option><option value="email">Email</option><option value="phone">Phone</option><option value="manual">Instructions only</option></select></div>
              <div className="field is-wide"><label htmlFor="action-target">Destination or instructions</label><input id="action-target" required type={action.target_type === "https" ? "url" : "text"} value={action.target} onChange={(event) => updateExternalAction({ target: event.target.value })} /></div>
              <label className="commitment-check is-wide"><input type="checkbox" checked={action.requires_completion_before_confirm} onChange={(event) => updateExternalAction({ requires_completion_before_confirm: event.target.checked })} /><span><strong>Must be done before confirming</strong><small>Useful when a calendar entry would be misleading before the booking or RSVP succeeds.</small></span></label>
            </div>
            <div className="commitment-external-actions">
              {actionHref ? <a className="button button--primary" href={actionHref} target={action.target_type === "https" ? "_blank" : undefined} rel={action.target_type === "https" ? "noreferrer" : undefined}>{action.label} <ExternalLink aria-hidden="true" size={16} /></a> : <p>{action.target}</p>}
              <button type="button" className="button button--secondary" disabled={dirty || busy !== null || draft.external_action_status === "completed"} onClick={() => void markActionDone()}><Check aria-hidden="true" size={16} /> {draft.external_action_status === "completed" ? "Done" : busy === "action" ? "Saving…" : "Mark Done"}</button>
            </div>
            {dirty ? <small>Save edited action details before marking it done.</small> : null}
          </div>
        ) : null}
      </section>

      <footer className="commitment-review-actions">
        <div>{dirty ? <span>Unsaved changes</span> : <span><CheckCircle2 aria-hidden="true" size={16} /> Review saved</span>}</div>
        <button type="submit" className="button button--secondary" disabled={!dirty || busy !== null}><Save aria-hidden="true" size={16} /> {busy === "save" ? "Saving…" : "Save changes"}</button>
        <button type="button" className="button button--primary" disabled={!canConfirm} onClick={() => void confirm()}>{busy === "confirm" ? "Confirming…" : "Confirm plan"}</button>
        <button type="button" className="commitment-decline-link" disabled={busy !== null} onClick={() => setDeclining(true)}>Decline</button>
      </footer>
      {draft.visibility === "owner" ? <p className="commitment-confirm-help"><UserRound aria-hidden="true" size={16} /> Share this plan with the family and save before creating shared calendar or task items.</p> : dirty ? <p className="commitment-confirm-help">Save your edits before confirming.</p> : actionBlocksConfirm ? <p className="commitment-confirm-help">Complete the outside step, then mark it Done.</p> : draft.review_issues.length ? <p className="commitment-confirm-help">Resolve the checks above and save the plan.</p> : null}

      {declining ? <section className="commitment-decline" aria-labelledby="commitment-decline-title"><h3 id="commitment-decline-title">Decline this plan?</h3><p>Nothing from it will be added to the calendar or tasks.</p><div className="field"><label htmlFor="commitment-decline-reason">Reason <span>(optional)</span></label><textarea id="commitment-decline-reason" rows={3} maxLength={1000} value={declineReason} onChange={(event) => setDeclineReason(event.target.value)} /></div><div><button type="button" className="button button--secondary" disabled={busy !== null} onClick={() => setDeclining(false)}>Keep reviewing</button><button type="button" className="button button--danger" disabled={busy !== null} onClick={() => void decline()}>{busy === "decline" ? "Declining…" : "Decline plan"}</button></div></section> : null}
    </form>
  );
}
