import { CakeSlice, CalendarPlus, Check, ClipboardPaste, Edit3, Gift, ListPlus, Plus, RotateCcw, Trash2 } from "lucide-react";
import { useCallback, useEffect, useMemo, useState, type FormEvent } from "react";

import { api } from "../api";
import { ConfirmDialog, EmptyState, ErrorState, Modal, SkeletonList } from "../components/ui";
import "./birthday-panel.css";

export type BirthdayRecord = {
  id: string;
  person_name: string;
  date_of_birth: string | null;
  birth_month: number;
  birth_day: number;
  year_known: boolean;
  relationship: string;
  reminder_days_before: number;
  age: number | null;
  turning_age: number | null;
  next_birthday: string;
  days_until: number;
  preparation_due: boolean;
};

type LinkedItem = { id: string; title: string; completed: boolean };
type BirthdayPreparation = {
  birthday: BirthdayRecord;
  occurrence_year: number;
  card_status: "not_started" | "to_buy" | "bought" | "written" | "sent";
  card_message: string | null;
  celebration_status: "not_started" | "planning" | "planned";
  notes: string | null;
  tasks: LinkedItem[];
  calendar_event: LinkedItem | null;
  gifts_total: number;
  gifts_remaining: number;
};

type ImportDraft = {
  line_number: number;
  source_line: string;
  person_name: string | null;
  date_of_birth: string | null;
  birth_month: number | null;
  birth_day: number | null;
  duplicate_id: string | null;
  issue: string | null;
};

type BirthdayDraft = {
  name: string;
  hasYear: boolean;
  date: string;
  month: string;
  day: string;
  relationship: string;
  leadDays: string;
};

const monthNames = Array.from({ length: 12 }, (_, index) =>
  new Intl.DateTimeFormat(undefined, { month: "long", timeZone: "UTC" }).format(new Date(Date.UTC(2000, index, 1))),
);

function emptyDraft(): BirthdayDraft {
  const today = new Date();
  return {
    name: "",
    hasYear: true,
    date: today.toISOString().slice(0, 10),
    month: String(today.getMonth() + 1),
    day: String(today.getDate()),
    relationship: "friend",
    leadDays: "14",
  };
}

function monthDay(month: number, day: number): string {
  return `${day} ${monthNames[month - 1] ?? month}`;
}

function countdown(days: number): string {
  if (days === 0) return "Today";
  if (days === 1) return "Tomorrow";
  return `in ${days} days`;
}

function daysInMonth(month: number): number {
  return new Date(Date.UTC(2000, month, 0)).getUTCDate();
}

export function BirthdaysPanel({
  revision = 0,
  initialBirthdayId = null,
  onOpenPresents,
  onOpenTask,
  onOpenEvent,
  onDataChanged,
}: {
  revision?: number;
  initialBirthdayId?: string | null;
  onOpenPresents?: (birthdayId: string) => void;
  onOpenTask?: (taskId: string) => void;
  onOpenEvent?: (eventId: string, date: string) => void;
  onDataChanged?: () => void;
}) {
  const [birthdays, setBirthdays] = useState<BirthdayRecord[]>([]);
  const [selected, setSelected] = useState<BirthdayRecord | null>(null);
  const [preparation, setPreparation] = useState<BirthdayPreparation | null>(null);
  const [loading, setLoading] = useState(true);
  const [working, setWorking] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [editorOpen, setEditorOpen] = useState(false);
  const [editing, setEditing] = useState<BirthdayRecord | null>(null);
  const [draft, setDraft] = useState<BirthdayDraft>(emptyDraft);
  const [duplicatePrompt, setDuplicatePrompt] = useState(false);
  const [removePrompt, setRemovePrompt] = useState(false);
  const [removed, setRemoved] = useState<BirthdayRecord | null>(null);
  const [importOpen, setImportOpen] = useState(false);
  const [importText, setImportText] = useState("");
  const [importDrafts, setImportDrafts] = useState<ImportDraft[]>([]);
  const [selectedLines, setSelectedLines] = useState<Set<number>>(new Set());
  const [cardMessage, setCardMessage] = useState("");
  const [taskOpen, setTaskOpen] = useState(false);
  const [taskTitle, setTaskTitle] = useState("");
  const [taskLead, setTaskLead] = useState("7");

  const load = useCallback(async () => {
    const hadContent = birthdays.length > 0;
    if (!hadContent) setLoading(true);
    try {
      const values = await api<BirthdayRecord[]>("/birthdays/");
      setBirthdays(values);
      setError(null);
      setSelected((current) => current
        ? values.find((item) => item.id === current.id) ?? null
        : values.find((item) => item.id === initialBirthdayId) ?? null);
      if (initialBirthdayId && values.some((item) => item.id === initialBirthdayId)) {
        const url = new URL(window.location.href);
        url.searchParams.delete("birthday");
        window.history.replaceState({}, "", url);
      }
    } catch (requestError) {
      if (!hadContent) setError(requestError instanceof Error ? requestError.message : "Birthdays could not be opened.");
    } finally {
      setLoading(false);
    }
  }, [birthdays.length, initialBirthdayId]);

  useEffect(() => { void load(); }, [load, revision]);

  useEffect(() => {
    if (!selected) {
      setPreparation(null);
      return;
    }
    let cancelled = false;
    setPreparation(null);
    void api<BirthdayPreparation>(`/birthdays/${selected.id}/preparation`)
      .then((value) => {
        if (cancelled) return;
        setPreparation(value);
        setCardMessage(value.card_message ?? "");
      })
      .catch((requestError) => {
        if (!cancelled) setError(requestError instanceof Error ? requestError.message : "The birthday plan could not be opened.");
      });
    return () => { cancelled = true; };
  }, [selected]);

  const due = useMemo(() => birthdays.filter((item) => item.preparation_due), [birthdays]);
  const later = useMemo(() => birthdays.filter((item) => !item.preparation_due), [birthdays]);

  function openNew() {
    setEditing(null);
    setDraft(emptyDraft());
    setDuplicatePrompt(false);
    setEditorOpen(true);
  }

  function openEdit(birthday: BirthdayRecord) {
    const fallbackDate = `2000-${String(birthday.birth_month).padStart(2, "0")}-${String(birthday.birth_day).padStart(2, "0")}`;
    setEditing(birthday);
    setDraft({
      name: birthday.person_name,
      hasYear: birthday.year_known,
      date: birthday.date_of_birth ?? fallbackDate,
      month: String(birthday.birth_month),
      day: String(birthday.birth_day),
      relationship: birthday.relationship,
      leadDays: String(birthday.reminder_days_before),
    });
    setEditorOpen(true);
  }

  function mutationBody(allowDuplicate: boolean) {
    const parsedDate = draft.hasYear ? new Date(`${draft.date}T00:00:00Z`) : null;
    return {
      person_name: draft.name.trim(),
      date_of_birth: draft.hasYear ? draft.date : null,
      birth_month: parsedDate ? parsedDate.getUTCMonth() + 1 : Number(draft.month),
      birth_day: parsedDate ? parsedDate.getUTCDate() : Number(draft.day),
      relationship: draft.relationship,
      reminder_days_before: Number(draft.leadDays),
      allow_duplicate: allowDuplicate,
    };
  }

  async function saveBirthday(event?: FormEvent, allowDuplicate = false) {
    event?.preventDefault();
    if (!draft.name.trim()) return;
    setWorking(true);
    setError(null);
    try {
      const saved = editing
        ? await api<BirthdayRecord>(`/birthdays/${editing.id}`, { method: "PUT", body: JSON.stringify(mutationBody(allowDuplicate)) })
        : await api<BirthdayRecord>("/birthdays/", { method: "POST", body: JSON.stringify(mutationBody(allowDuplicate)) });
      setBirthdays((current) => [...current.filter((item) => item.id !== saved.id), saved].sort((a, b) => a.days_until - b.days_until));
      setSelected((current) => current?.id === saved.id ? saved : current);
      setEditorOpen(false);
      setDuplicatePrompt(false);
      onDataChanged?.();
    } catch (requestError) {
      const message = requestError instanceof Error ? requestError.message : "The birthday could not be saved.";
      if (/conflict|already/i.test(message)) setDuplicatePrompt(true);
      else setError(message);
    } finally {
      setWorking(false);
    }
  }

  async function removeBirthday() {
    if (!editing) return;
    setWorking(true);
    try {
      await api(`/birthdays/${editing.id}`, { method: "DELETE" });
      setBirthdays((current) => current.filter((item) => item.id !== editing.id));
      setRemoved(editing);
      setSelected(null);
      setEditorOpen(false);
      setRemovePrompt(false);
      onDataChanged?.();
    } catch (requestError) {
      setError(requestError instanceof Error ? requestError.message : "The birthday could not be removed.");
    } finally {
      setWorking(false);
    }
  }

  async function undoRemove() {
    if (!removed) return;
    try {
      const restored = await api<BirthdayRecord>(`/birthdays/${removed.id}/restore`, { method: "POST" });
      setBirthdays((current) => [...current, restored].sort((a, b) => a.days_until - b.days_until));
      setRemoved(null);
      onDataChanged?.();
    } catch (requestError) {
      setError(requestError instanceof Error ? requestError.message : "The birthday could not be restored.");
    }
  }

  async function updatePreparation(changes: Record<string, string | null>) {
    if (!selected) return;
    setWorking(true);
    try {
      const value = await api<BirthdayPreparation>(`/birthdays/${selected.id}/preparation`, { method: "PUT", body: JSON.stringify(changes) });
      setPreparation(value);
      setCardMessage(value.card_message ?? "");
      onDataChanged?.();
    } catch (requestError) {
      setError(requestError instanceof Error ? requestError.message : "That part of the plan could not be saved.");
    } finally {
      setWorking(false);
    }
  }

  async function addEvent() {
    if (!selected) return;
    setWorking(true);
    try {
      const value = await api<BirthdayPreparation>(`/birthdays/${selected.id}/preparation/event`, { method: "POST", body: JSON.stringify({}) });
      setPreparation(value);
      onDataChanged?.();
    } catch (requestError) {
      setError(requestError instanceof Error ? requestError.message : "The birthday could not be added to Planner.");
    } finally {
      setWorking(false);
    }
  }

  async function addTask(event: FormEvent) {
    event.preventDefault();
    if (!selected || !taskTitle.trim()) return;
    setWorking(true);
    try {
      const value = await api<BirthdayPreparation>(`/birthdays/${selected.id}/preparation/task`, {
        method: "POST",
        body: JSON.stringify({ title: taskTitle.trim(), due_days_before: Number(taskLead) }),
      });
      setPreparation(value);
      setTaskTitle("");
      setTaskOpen(false);
      onDataChanged?.();
    } catch (requestError) {
      setError(requestError instanceof Error ? requestError.message : "The task could not be added.");
    } finally {
      setWorking(false);
    }
  }

  async function previewImport() {
    if (!importText.trim()) return;
    setWorking(true);
    try {
      const result = await api<{ drafts: ImportDraft[] }>("/birthdays/import-preview", { method: "POST", body: JSON.stringify({ text: importText }) });
      setImportDrafts(result.drafts);
      setSelectedLines(new Set(result.drafts.filter((item) => !item.issue && !item.duplicate_id && item.person_name && item.birth_month && item.birth_day).map((item) => item.line_number)));
    } catch (requestError) {
      setError(requestError instanceof Error ? requestError.message : "Those birthdays could not be read.");
    } finally {
      setWorking(false);
    }
  }

  async function importSelected() {
    const chosen = importDrafts.filter((item) => selectedLines.has(item.line_number));
    if (!chosen.length) return;
    setWorking(true);
    try {
      const created: BirthdayRecord[] = [];
      for (const item of chosen) {
        if (!item.person_name || !item.birth_month || !item.birth_day) continue;
        created.push(await api<BirthdayRecord>("/birthdays/", {
          method: "POST",
          body: JSON.stringify({
            person_name: item.person_name,
            date_of_birth: item.date_of_birth,
            birth_month: item.birth_month,
            birth_day: item.birth_day,
            relationship: "friend",
            reminder_days_before: 14,
          }),
        }));
      }
      setBirthdays((current) => [...current, ...created].sort((a, b) => a.days_until - b.days_until));
      setImportOpen(false);
      setImportText("");
      setImportDrafts([]);
      onDataChanged?.();
    } catch (requestError) {
      setError(requestError instanceof Error ? requestError.message : "Not every selected birthday could be saved.");
      await load();
    } finally {
      setWorking(false);
    }
  }

  if (loading && !birthdays.length) return <SkeletonList rows={5} />;
  if (error && !birthdays.length) return <ErrorState message={error} retry={() => void load()} />;

  return (
    <section className="birthday-panel" aria-labelledby="birthdays-title">
      <header className="birthday-panel__header">
        <div><p className="page-eyebrow">Stay ahead</p><h2 id="birthdays-title">Birthdays</h2></div>
        <div className="birthday-panel__actions">
          <button type="button" className="button button--secondary button--compact" onClick={() => setImportOpen(true)}><ClipboardPaste aria-hidden="true" size={16} /> Paste a list</button>
          <button type="button" className="button button--primary button--compact" onClick={openNew}><Plus aria-hidden="true" size={16} /> Add birthday</button>
        </div>
      </header>

      {selected ? (
        <BirthdayPlan
          birthday={selected}
          preparation={preparation}
          cardMessage={cardMessage}
          setCardMessage={setCardMessage}
          working={working}
          onBack={() => setSelected(null)}
          onEdit={() => openEdit(selected)}
          onOpenPresents={() => onOpenPresents?.(selected.id)}
          onUpdate={updatePreparation}
          onAddEvent={addEvent}
          onOpenEvent={onOpenEvent}
          onAddTask={() => setTaskOpen(true)}
          onOpenTask={onOpenTask}
        />
      ) : birthdays.length ? (
        <div className="birthday-groups">
          {due.length ? <BirthdayGroup title="Prepare now" values={due} onChoose={setSelected} /> : null}
          {later.length ? <BirthdayGroup title="Later" values={later} onChoose={setSelected} /> : null}
        </div>
      ) : (
        <EmptyState title="Keep birthdays quietly in hand" detail="Add a birthday and HausKlar will bring it forward when there is something to prepare." action={openNew} actionLabel="Add birthday" />
      )}

      {error && birthdays.length ? <div className="inline-error" role="alert">{error}<button type="button" onClick={() => setError(null)}>Dismiss</button></div> : null}
      {removed ? <div className="undo-toast" role="status"><span>Removed {removed.person_name}'s birthday</span><button type="button" onClick={() => void undoRemove()}><RotateCcw aria-hidden="true" size={15} /> Undo</button></div> : null}

      <Modal open={editorOpen} onOpenChange={setEditorOpen} title={editing ? "Edit birthday" : "Add birthday"}>
        <form className="form-stack" onSubmit={(event) => void saveBirthday(event)}>
          <div className="field"><label htmlFor="birthday-name">Name</label><input id="birthday-name" value={draft.name} maxLength={200} onChange={(event) => setDraft((current) => ({ ...current, name: event.target.value }))} required autoFocus /></div>
          <label className="checkbox-row"><input type="checkbox" checked={draft.hasYear} onChange={(event) => setDraft((current) => ({ ...current, hasYear: event.target.checked }))} /> I know the birth year</label>
          {draft.hasYear ? <div className="field"><label htmlFor="birthday-date">Date of birth</label><input id="birthday-date" type="date" max={new Date().toISOString().slice(0, 10)} value={draft.date} onChange={(event) => setDraft((current) => ({ ...current, date: event.target.value }))} required /></div> : <div className="form-grid form-grid--two"><div className="field"><label htmlFor="birthday-month">Month</label><select id="birthday-month" value={draft.month} onChange={(event) => setDraft((current) => ({ ...current, month: event.target.value, day: String(Math.min(Number(current.day), daysInMonth(Number(event.target.value)))) }))}>{monthNames.map((name, index) => <option value={index + 1} key={name}>{name}</option>)}</select></div><div className="field"><label htmlFor="birthday-day">Day</label><select id="birthday-day" value={draft.day} onChange={(event) => setDraft((current) => ({ ...current, day: event.target.value }))}>{Array.from({ length: daysInMonth(Number(draft.month)) }, (_, index) => <option value={index + 1} key={index + 1}>{index + 1}</option>)}</select></div></div>}
          <div className="field"><label htmlFor="birthday-lead">Show when preparation is due</label><select id="birthday-lead" value={draft.leadDays} onChange={(event) => setDraft((current) => ({ ...current, leadDays: event.target.value }))}>{[0, 3, 7, 14, 21, 30, 60, 90].map((days) => <option value={days} key={days}>{days === 0 ? "On the day" : `${days} days before`}</option>)}</select><small>Until then it stays quietly in Later.</small></div>
          <details><summary>More</summary><div className="field"><label htmlFor="birthday-relationship">Relationship</label><select id="birthday-relationship" value={draft.relationship} onChange={(event) => setDraft((current) => ({ ...current, relationship: event.target.value }))}><option value="family">Family</option><option value="friend">Friend</option><option value="school">School</option></select></div></details>
          <div className="dialog-actions">{editing ? <button type="button" className="button button--danger" onClick={() => setRemovePrompt(true)}><Trash2 aria-hidden="true" size={16} /> Remove</button> : null}<button type="submit" className="button button--primary" disabled={working || !draft.name.trim()}>{working ? "Saving…" : "Save"}</button></div>
        </form>
      </Modal>

      <ConfirmDialog open={duplicatePrompt} onOpenChange={setDuplicatePrompt} title="Keep both birthdays?" description="A birthday with this name and date is already saved." confirmLabel="Keep both" busy={working} onConfirm={() => void saveBirthday(undefined, true)} />
      <ConfirmDialog open={removePrompt} onOpenChange={setRemovePrompt} title={`Remove ${editing?.person_name ?? "this birthday"}?`} description="It will leave the list. You can undo this afterwards." confirmLabel="Remove" destructive busy={working} onConfirm={() => void removeBirthday()} />

      <Modal open={importOpen} onOpenChange={setImportOpen} title="Import birthdays" description="Nothing is saved until you review it.">
        {!importDrafts.length ? <div className="form-stack"><div className="field"><label htmlFor="birthday-import">One person per line</label><textarea id="birthday-import" rows={8} value={importText} placeholder="Grandma, 15 June 1955&#10;Coach, 3 September" onChange={(event) => setImportText(event.target.value)} /><small>Leave off the year if you do not know it.</small></div><div className="dialog-actions"><button type="button" className="button button--primary" disabled={working || !importText.trim()} onClick={() => void previewImport()}>Review</button></div></div> : <div className="form-stack"><div className="birthday-import-list">{importDrafts.map((item) => { const selectable = !item.issue && !item.duplicate_id && item.person_name && item.birth_month && item.birth_day; return <label className="birthday-import-row" key={item.line_number}><input type="checkbox" disabled={!selectable} checked={selectedLines.has(item.line_number)} onChange={(event) => setSelectedLines((current) => { const next = new Set(current); if (event.target.checked) next.add(item.line_number); else next.delete(item.line_number); return next; })} /><span><strong>{item.person_name ?? item.source_line}</strong>{item.birth_month && item.birth_day ? <small>{monthDay(item.birth_month, item.birth_day)}{item.date_of_birth ? "" : " · year unknown"}</small> : null}{item.duplicate_id ? <small>Already saved</small> : item.issue ? <small>{item.issue}</small> : null}</span></label>; })}</div><div className="dialog-actions"><button type="button" className="button button--secondary" onClick={() => setImportDrafts([])}>Edit list</button><button type="button" className="button button--primary" disabled={working || !selectedLines.size} onClick={() => void importSelected()}>Save selected</button></div></div>}
      </Modal>

      <Modal open={taskOpen} onOpenChange={setTaskOpen} title="Add birthday task">
        <form className="form-stack" onSubmit={(event) => void addTask(event)}><div className="field"><label htmlFor="birthday-task-title">What needs doing?</label><input id="birthday-task-title" value={taskTitle} onChange={(event) => setTaskTitle(event.target.value)} required autoFocus /></div><div className="field"><label htmlFor="birthday-task-lead">Due</label><select id="birthday-task-lead" value={taskLead} onChange={(event) => setTaskLead(event.target.value)}>{[0, 3, 5, 7, 14, 21, 30].map((days) => <option value={days} key={days}>{days === 0 ? "On the birthday" : `${days} days before`}</option>)}</select></div><div className="dialog-actions"><button type="submit" className="button button--primary" disabled={working || !taskTitle.trim()}><ListPlus aria-hidden="true" size={16} /> Add task</button></div></form>
      </Modal>
    </section>
  );
}

function BirthdayGroup({ title, values, onChoose }: { title: string; values: BirthdayRecord[]; onChoose: (birthday: BirthdayRecord) => void }) {
  return <section className="birthday-group"><h3>{title}</h3><div className="birthday-list">{values.map((birthday) => <button type="button" className="birthday-row" onClick={() => onChoose(birthday)} key={birthday.id}><CakeSlice aria-hidden="true" size={21} /><span><strong>{birthday.person_name}</strong><small>{monthDay(birthday.birth_month, birthday.birth_day)}{birthday.turning_age == null ? "" : ` · turning ${birthday.turning_age}`}</small></span><em>{countdown(birthday.days_until)}</em></button>)}</div></section>;
}

function BirthdayPlan({ birthday, preparation, cardMessage, setCardMessage, working, onBack, onEdit, onOpenPresents, onUpdate, onAddEvent, onOpenEvent, onAddTask, onOpenTask }: {
  birthday: BirthdayRecord;
  preparation: BirthdayPreparation | null;
  cardMessage: string;
  setCardMessage: (value: string) => void;
  working: boolean;
  onBack: () => void;
  onEdit: () => void;
  onOpenPresents: () => void;
  onUpdate: (changes: Record<string, string | null>) => Promise<void>;
  onAddEvent: () => Promise<void>;
  onOpenEvent?: (eventId: string, date: string) => void;
  onAddTask: () => void;
  onOpenTask?: (taskId: string) => void;
}) {
  return <div className="birthday-plan"><div className="birthday-plan__top"><button type="button" className="button button--secondary button--compact" onClick={onBack}>← Birthdays</button><button type="button" className="button button--secondary button--compact" onClick={onEdit}><Edit3 aria-hidden="true" size={15} /> Edit</button></div><div className="birthday-plan__hero"><CakeSlice aria-hidden="true" size={30} /><div><h3>{birthday.person_name}</h3><p>{monthDay(birthday.birth_month, birthday.birth_day)}{birthday.turning_age == null ? "" : ` · turning ${birthday.turning_age}`} · {countdown(birthday.days_until).toLowerCase()}</p><small>Shown from {birthday.reminder_days_before} days beforehand.</small></div></div>{!preparation ? <SkeletonList rows={4} /> : <div className="birthday-plan__grid"><section><h4>Present</h4><button type="button" className="birthday-plan-row" onClick={onOpenPresents}><Gift aria-hidden="true" size={20} /><span><strong>{preparation.gifts_total ? preparation.gifts_remaining ? "Present" : "Present ready" : "Choose a present"}</strong><small>{preparation.gifts_total ? preparation.gifts_remaining ? `${preparation.gifts_remaining} still to prepare` : "All sorted" : "Open Presents"}</small></span></button></section><section><h4>Card</h4><div className="field"><label htmlFor="birthday-card-status">Card</label><select id="birthday-card-status" value={preparation.card_status} disabled={working} onChange={(event) => void onUpdate({ card_status: event.target.value })}><option value="not_started">Not started</option><option value="to_buy">Need to buy</option><option value="bought">Bought</option><option value="written">Written</option><option value="sent">Sent</option></select></div><div className="field"><label htmlFor="birthday-card-message">Message idea</label><textarea id="birthday-card-message" rows={3} value={cardMessage} onChange={(event) => setCardMessage(event.target.value)} /></div>{cardMessage !== (preparation.card_message ?? "") ? <button type="button" className="button button--secondary button--compact" disabled={working} onClick={() => void onUpdate({ card_message: cardMessage })}>Save message</button> : null}</section><section><h4>Celebration</h4>{preparation.calendar_event ? <button type="button" className="birthday-plan-row" onClick={() => onOpenEvent?.(preparation.calendar_event!.id, birthday.next_birthday)}><CalendarPlus aria-hidden="true" size={20} /><span><strong>{preparation.calendar_event.title}</strong><small>In Planner</small></span></button> : <button type="button" className="button button--secondary" disabled={working} onClick={() => void onAddEvent()}><CalendarPlus aria-hidden="true" size={16} /> Add to Planner</button>}<div className="field"><label htmlFor="birthday-celebration">Preparation</label><select id="birthday-celebration" value={preparation.celebration_status} disabled={working} onChange={(event) => void onUpdate({ celebration_status: event.target.value })}><option value="not_started">Not started</option><option value="planning">Planning</option><option value="planned">Planned</option></select></div></section><section><h4>Things to do</h4>{preparation.tasks.map((task) => <button type="button" className="birthday-plan-row" onClick={() => onOpenTask?.(task.id)} key={task.id}>{task.completed ? <Check aria-hidden="true" size={20} /> : <ListPlus aria-hidden="true" size={20} />}<span><strong>{task.title}</strong><small>{task.completed ? "Done" : "Open task"}</small></span></button>)}<button type="button" className="button button--secondary" onClick={onAddTask}><Plus aria-hidden="true" size={16} /> Add task</button></section></div>}</div>;
}
