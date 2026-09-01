import {
  CalendarRange,
  Check,
  Clock3,
  Copy,
  Edit3,
  Plus,
  RefreshCw,
  Trash2,
} from "lucide-react";
import { endOfWeek, format, parseISO } from "date-fns";
import { useCallback, useEffect, useMemo, useRef, useState, type FormEvent } from "react";

import { api } from "../api";
import type { PrepPackTemplate } from "../prepPacks";
import type { FamilyMember } from "../types";
import { EmptyState, ErrorState, IconButton, Modal, Segmented, SkeletonList, cn } from "../components/ui";

type RoutineItem = {
  id: string;
  person_id: string;
  name: string;
  color: string;
  days_of_week: number[];
  sort_order: number;
  time_of_day?: string | null;
  location?: string | null;
  preparation_note?: string | null;
  prep_template_id?: string | null;
  reminder_minutes?: number | null;
  calendar_projection: boolean;
  term_only: boolean;
};
type TermDate = { id: string; person_id: string; label?: string | null; start_date: string; end_date: string; is_imported?: boolean; is_overridden?: boolean };
type OverrideMode = "auto" | "force_on" | "force_off";
type RoutineDraft = {
  name: string;
  color: string;
  days: Set<number>;
  time: string;
  location: string;
  preparationNote: string;
  prepTemplateId: string;
  reminderMinutes: string;
  calendarProjection: boolean;
  termOnly: boolean;
};

const dayNames = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"];
const colors = ["#ff6b6b", "#ffa94d", "#ffd43b", "#51cf66", "#22b8cf", "#339af0", "#845ef7", "#f06595"];
const quickActivities = ["PE", "Swimming", "Football", "Book change", "Fencing", "Little Gym"];

function blankRoutine(): RoutineDraft {
  return {
    name: "",
    color: colors[4],
    days: new Set([0, 1, 2, 3, 4]),
    time: "",
    location: "",
    preparationNote: "",
    prepTemplateId: "",
    reminderMinutes: "",
    calendarProjection: true,
    termOnly: true,
  };
}

function draftFor(item: RoutineItem): RoutineDraft {
  return {
    name: item.name,
    color: item.color,
    days: new Set(item.days_of_week),
    time: item.time_of_day ?? "",
    location: item.location ?? "",
    preparationNote: item.preparation_note ?? "",
    prepTemplateId: item.prep_template_id ?? "",
    reminderMinutes: item.reminder_minutes == null ? "" : String(item.reminder_minutes),
    calendarProjection: item.calendar_projection,
    termOnly: item.term_only,
  };
}

export function RoutinesView({ members, revision, onDataChanged, notify }: { members: FamilyMember[]; revision: number; onDataChanged: () => void; notify: (message: string) => void }) {
  const people = useMemo(() => [...members].sort((left, right) => Number(right.member_type === "child") - Number(left.member_type === "child")), [members]);
  const [selectedPerson, setSelectedPerson] = useState(people[0]?.id ?? "");
  const [items, setItems] = useState<RoutineItem[]>([]);
  const [terms, setTerms] = useState<TermDate[]>([]);
  const [templates, setTemplates] = useState<PrepPackTemplate[]>([]);
  const [mode, setMode] = useState<OverrideMode>("auto");
  const [overrideExpiry, setOverrideExpiry] = useState("");
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [working, setWorking] = useState<string | null>(null);
  const [showRoutine, setShowRoutine] = useState(false);
  const [editingRoutine, setEditingRoutine] = useState<RoutineItem | null>(null);
  const [routine, setRoutine] = useState<RoutineDraft>(blankRoutine);
  const [copyingRoutine, setCopyingRoutine] = useState<RoutineItem | null>(null);
  const [copyTarget, setCopyTarget] = useState("");
  const [showTerm, setShowTerm] = useState(false);
  const [editingTerm, setEditingTerm] = useState<TermDate | null>(null);
  const [termLabel, setTermLabel] = useState("");
  const [termStart, setTermStart] = useState("");
  const [termEnd, setTermEnd] = useState("");

  useEffect(() => { if (!selectedPerson && people[0]) setSelectedPerson(people[0].id); }, [people, selectedPerson]);

  const load = useCallback(async (background = false) => {
    if (!background) setLoading(true);
    setError(null);
    try {
      const [routineItems, termItems, packItems] = await Promise.all([
        api<RoutineItem[]>("/routines/items"),
        api<TermDate[]>("/routines/terms"),
        api<PrepPackTemplate[]>("/prep-packs/templates").catch(() => []),
      ]);
      setItems(routineItems);
      setTerms(termItems);
      setTemplates(packItems.filter((template) => template.enabled));
      if (selectedPerson) {
        try {
          const response = await api<{ mode: OverrideMode; expires_on?: string | null }>(`/routines/override/${selectedPerson}`);
          setMode(response.mode);
          setOverrideExpiry(response.expires_on ?? "");
        } catch {
          setMode("auto");
          setOverrideExpiry("");
        }
      }
    } catch (requestError) {
      setError(requestError instanceof Error ? requestError.message : "Routines are unavailable.");
    } finally {
      setLoading(false);
    }
  }, [selectedPerson]);

  const lastRevision = useRef(revision);
  useEffect(() => {
    const background = revision !== lastRevision.current;
    lastRevision.current = revision;
    void load(background);
  }, [load, revision]);

  const personItems = items
    .filter((item) => item.person_id === selectedPerson)
    .sort((left, right) => (left.time_of_day ?? "99:99").localeCompare(right.time_of_day ?? "99:99") || left.sort_order - right.sort_order);
  const personTerms = terms.filter((term) => term.person_id === selectedPerson);
  const selectedName = people.find((person) => person.id === selectedPerson)?.name ?? "this person";

  function openRoutine(item?: RoutineItem) {
    setEditingRoutine(item ?? null);
    setRoutine(item ? draftFor(item) : blankRoutine());
    setShowRoutine(true);
  }

  async function saveRoutine(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (!selectedPerson || !routine.days.size) return;
    setWorking("routine");
    const body = JSON.stringify({
      person_id: selectedPerson,
      name: routine.name.trim(),
      color: routine.color,
      days_of_week: [...routine.days].sort(),
      sort_order: editingRoutine?.sort_order ?? personItems.length,
      time_of_day: routine.time || null,
      location: routine.location.trim() || null,
      preparation_note: routine.preparationNote.trim() || null,
      prep_template_id: routine.prepTemplateId || null,
      reminder_minutes: routine.reminderMinutes ? Number(routine.reminderMinutes) : null,
      calendar_projection: routine.calendarProjection,
      term_only: routine.termOnly,
    });
    try {
      await api(editingRoutine ? `/routines/items/${editingRoutine.id}` : "/routines/items", {
        method: editingRoutine ? "PUT" : "POST",
        body,
      });
      setShowRoutine(false);
      setEditingRoutine(null);
      notify(editingRoutine ? "Routine updated." : "Routine added.");
      onDataChanged();
    } catch (requestError) {
      setError(requestError instanceof Error ? requestError.message : "The routine could not be saved.");
    } finally {
      setWorking(null);
    }
  }

  function openTerm(term?: TermDate) {
    setEditingTerm(term ?? null);
    setTermLabel(term?.label ?? "");
    setTermStart(term?.start_date ?? "");
    setTermEnd(term?.end_date ?? "");
    setShowTerm(true);
  }

  async function saveTerm(event: FormEvent<HTMLFormElement>) {
    event.preventDefault(); if (!selectedPerson) return; setWorking("term");
    try {
      await api(editingTerm ? `/routines/terms/${editingTerm.id}` : "/routines/terms", { method: editingTerm ? "PUT" : "POST", body: JSON.stringify({ ...(editingTerm ? {} : { person_id: selectedPerson }), label: termLabel.trim() || null, start_date: termStart, end_date: termEnd }) });
      setShowTerm(false); setEditingTerm(null); setTermLabel(""); setTermStart(""); setTermEnd(""); notify(editingTerm ? "Term dates updated." : "Term dates added."); onDataChanged();
    } catch (requestError) { setError(requestError instanceof Error ? requestError.message : "The term dates could not be added."); }
    finally { setWorking(null); }
  }

  async function remove(path: string, key: string, message: string) {
    setWorking(key);
    try { await api(path, { method: "DELETE" }); notify(message); onDataChanged(); }
    catch (requestError) { setError(requestError instanceof Error ? requestError.message : "The item could not be removed."); }
    finally { setWorking(null); }
  }

  async function duplicateRoutine() {
    if (!copyingRoutine || !copyTarget) return;
    setWorking("copy");
    try {
      await api(`/routines/items/${copyingRoutine.id}/duplicate`, { method: "POST", body: JSON.stringify({ target_person_id: copyTarget }) });
      notify(`${copyingRoutine.name} copied.`); setCopyingRoutine(null); setCopyTarget(""); onDataChanged();
    } catch (requestError) { setError(requestError instanceof Error ? requestError.message : "The routine could not be copied."); }
    finally { setWorking(null); }
  }

  async function changeMode(next: OverrideMode) {
    if (!selectedPerson) return;
    setMode(next); setWorking("mode");
    try {
      if (next === "auto") {
        await api(`/routines/override/${selectedPerson}`, { method: "DELETE" });
        setOverrideExpiry("");
      } else {
        const expiry = overrideExpiry || format(endOfWeek(new Date(), { weekStartsOn: 1 }), "yyyy-MM-dd");
        setOverrideExpiry(expiry);
        await api(`/routines/override/${selectedPerson}`, { method: "PUT", body: JSON.stringify({ is_active: next === "force_on", expires_on: expiry }) });
      }
      onDataChanged();
    } catch (requestError) { setError(requestError instanceof Error ? requestError.message : "The temporary term status could not be updated."); await load(); }
    finally { setWorking(null); }
  }

  async function updateOverrideExpiry(value: string) {
    setOverrideExpiry(value);
    if (mode === "auto" || !value) return;
    setWorking("mode");
    try {
      await api(`/routines/override/${selectedPerson}`, { method: "PUT", body: JSON.stringify({ is_active: mode === "force_on", expires_on: value }) });
    } catch (requestError) { setError(requestError instanceof Error ? requestError.message : "The temporary term status could not be updated."); }
    finally { setWorking(null); }
  }

  async function importSchoolDates() {
    setWorking("import");
    try { await api("/routines/terms/refresh", { method: "POST" }); notify("School dates imported."); onDataChanged(); }
    catch (requestError) { setError(requestError instanceof Error ? requestError.message : "School dates could not be imported."); }
    finally { setWorking(null); }
  }

  return (
    <div className="standard-page routines-page">
      <header className="page-header"><div><p className="page-eyebrow">A week that runs itself</p><h1>Routines</h1></div><IconButton label="Refresh routines" icon={RefreshCw} onClick={() => void load()} /></header>
      <div className="person-picker" role="group" aria-label="Choose family member">{people.map((person) => <button type="button" className={selectedPerson === person.id ? "is-active" : ""} onClick={() => setSelectedPerson(person.id)} key={person.id}><span>{person.name.slice(0, 1)}</span>{person.name}</button>)}</div>
      {error ? <ErrorState message={error} retry={load} /> : null}
      {loading ? <SkeletonList rows={6} /> : null}
      {!loading ? <>
        <ol className="routine-setup-steps" aria-label="Routine setup progress">
          <li className="is-complete"><Check aria-hidden="true" size={16} /><span><strong>1. Child</strong>{selectedName}</span></li>
          <li className={cn(personTerms.length > 0 && "is-complete")}><CalendarRange aria-hidden="true" size={16} /><span><strong>2. School dates</strong>{personTerms.length ? `${personTerms.length} date ${personTerms.length === 1 ? "range" : "ranges"}` : "Add term dates"}</span></li>
          <li className={cn(personItems.length > 0 && "is-complete")}><Clock3 aria-hidden="true" size={16} /><span><strong>3. Weekly activities</strong>{personItems.length ? `${personItems.length} set up` : "Build the week"}</span></li>
        </ol>

        <section className="routine-section routine-week-card">
          <div className="section-heading"><div><p className="page-eyebrow">Weekly preview</p><h2>{selectedName}&apos;s week</h2></div><button type="button" className="button button--primary button--compact" onClick={() => openRoutine()}><Plus aria-hidden="true" size={16} />Add activity</button></div>
          <div className="routine-week-preview">{dayNames.map((day, index) => {
            const dayItems = personItems.filter((item) => item.days_of_week.includes(index));
            return <div className="routine-week-day" key={day}><strong>{day}</strong>{dayItems.length ? dayItems.map((item) => <button type="button" onClick={() => openRoutine(item)} style={{ borderLeftColor: item.color }} key={item.id}><span>{item.time_of_day || "Any time"}</span><b>{item.name}</b></button>) : <span className="routine-week-empty">—</span>}</div>;
          })}</div>
          <p className="routine-carry-forward">Weekly activities carry forward automatically between terms. Only add what changed.</p>
        </section>

        <section className="routine-section"><div className="section-heading"><div><p className="page-eyebrow">Activities</p><h2>What happens each week</h2></div></div>
          {!personItems.length ? <EmptyState title="No weekly routine" detail={`Add school, clubs and regular commitments for ${selectedName}.`} action={() => openRoutine()} actionLabel="Add first activity" /> : <div className="routine-list">{personItems.map((item) => <article key={item.id}><span className="routine-color" style={{ backgroundColor: item.color }} /><div><strong>{item.name}</strong><span>{[item.time_of_day, item.location].filter(Boolean).join(" · ") || "Any time"}</span><div className="routine-days">{dayNames.map((day, index) => <span className={cn(item.days_of_week.includes(index) && "is-active")} key={day}>{day}</span>)}</div>{item.prep_template_id ? <small>Packing list: {templates.find((template) => template.id === item.prep_template_id)?.name ?? "Linked"}</small> : item.preparation_note ? <small>{item.preparation_note}</small> : null}</div><div className="routine-row-actions"><button type="button" className="icon-button" aria-label={`Edit ${item.name}`} onClick={() => openRoutine(item)}><Edit3 aria-hidden="true" size={17} /></button><button type="button" className="icon-button" aria-label={`Copy ${item.name}`} onClick={() => { setCopyingRoutine(item); setCopyTarget(people.find((person) => person.id !== selectedPerson)?.id ?? ""); }}><Copy aria-hidden="true" size={17} /></button><button type="button" className="icon-button icon-button--danger" aria-label={`Delete ${item.name}`} disabled={working === item.id} onClick={() => void remove(`/routines/items/${item.id}`, item.id, "Routine removed.")}><Trash2 aria-hidden="true" size={17} /></button></div></article>)}</div>}
        </section>

        <section className="routine-section"><div className="section-heading"><div><p className="page-eyebrow">School calendar</p><h2>Term dates</h2></div><button type="button" className="button button--secondary button--compact" onClick={() => openTerm()}><Plus aria-hidden="true" size={16} />Add dates</button></div>
          {!personTerms.length ? <EmptyState title="No term dates" detail="Add a date range so school-only activities pause in the holidays." action={() => openTerm()} actionLabel="Add term dates" /> : <div className="term-list">{personTerms.map((term) => <article key={term.id}><CalendarRange aria-hidden="true" size={20} /><div><strong>{term.label || "Term"}</strong><span>{format(parseISO(term.start_date), "d MMM yyyy")} – {format(parseISO(term.end_date), "d MMM yyyy")}{term.is_overridden ? " · Adjusted" : term.is_imported ? " · Imported" : ""}</span></div><div className="term-row-actions"><button type="button" className="icon-button" aria-label={`Edit ${term.label || "term"}`} onClick={() => openTerm(term)}><Edit3 aria-hidden="true" size={17} /></button><button type="button" className="icon-button icon-button--danger" aria-label={`Delete ${term.label || "term"}`} disabled={working === term.id} onClick={() => void remove(`/routines/terms/${term.id}`, term.id, "Term dates removed.")}><Trash2 aria-hidden="true" size={17} /></button></div></article>)}</div>}
        </section>

        <details className="routine-advanced"><summary>Advanced</summary><div><p>Import school dates or temporarily override the calculated term status. Temporary changes always have an end date.</p><button type="button" className="button button--secondary button--compact" disabled={working === "import"} onClick={() => void importSchoolDates()}><RefreshCw aria-hidden="true" size={16} />{working === "import" ? "Importing…" : "Import school dates"}</button><div className="term-mode"><span>Temporary term status</span><Segmented value={mode} onChange={(next) => void changeMode(next)} label="Temporary term status" options={[{ value: "auto", label: "Automatic" }, { value: "force_on", label: "In term" }, { value: "force_off", label: "Holiday" }]} /></div>{mode !== "auto" ? <div className="field"><label htmlFor="routine-override-expiry">Return to automatic after</label><input id="routine-override-expiry" type="date" min={format(new Date(), "yyyy-MM-dd")} value={overrideExpiry} onChange={(event) => void updateOverrideExpiry(event.target.value)} /></div> : null}</div></details>
      </> : null}

      <Modal open={showRoutine} onOpenChange={(open) => { setShowRoutine(open); if (!open) setEditingRoutine(null); }} title={editingRoutine ? `Edit ${editingRoutine.name}` : "Add weekly activity"} description={selectedName}>
        <form className="form-stack" onSubmit={saveRoutine}>
          {!editingRoutine ? <div className="routine-quick-picks" aria-label="Activity templates">{quickActivities.map((name) => <button type="button" onClick={() => setRoutine((current) => ({ ...current, name }))} key={name}>{name}</button>)}</div> : null}
          <div className="field"><label htmlFor="routine-name">Activity</label><input id="routine-name" value={routine.name} onChange={(event) => setRoutine((current) => ({ ...current, name: event.target.value }))} autoComplete="off" placeholder="Swimming" required /></div>
          <div className="field"><label htmlFor="routine-time">Time (optional)</label><input id="routine-time" type="time" value={routine.time} onChange={(event) => setRoutine((current) => ({ ...current, time: event.target.value }))} /></div>
          <fieldset className="people-fieldset"><legend>Days</legend><div className="day-picker">{dayNames.map((day, index) => <button type="button" className={routine.days.has(index) ? "is-active" : ""} aria-pressed={routine.days.has(index)} onClick={() => setRoutine((current) => { const days = new Set(current.days); if (days.has(index)) days.delete(index); else days.add(index); return { ...current, days }; })} key={day}>{day}</button>)}</div></fieldset>
          <details className="form-more"><summary>More</summary><div className="form-stack"><div className="field"><label htmlFor="routine-location">Location</label><input id="routine-location" value={routine.location} onChange={(event) => setRoutine((current) => ({ ...current, location: event.target.value }))} placeholder="School, pool, playing fields…" /></div><div className="field"><label htmlFor="routine-preparation">Preparation note</label><textarea id="routine-preparation" value={routine.preparationNote} onChange={(event) => setRoutine((current) => ({ ...current, preparationNote: event.target.value }))} placeholder="Costume under uniform" /></div><div className="field"><label htmlFor="routine-pack">Reusable packing list</label><select id="routine-pack" value={routine.prepTemplateId} onChange={(event) => setRoutine((current) => ({ ...current, prepTemplateId: event.target.value }))}><option value="">None</option>{templates.map((template) => <option value={template.id} key={template.id}>{template.name}</option>)}</select></div><div className="field"><label htmlFor="routine-reminder">Reminder</label><select id="routine-reminder" value={routine.reminderMinutes} onChange={(event) => setRoutine((current) => ({ ...current, reminderMinutes: event.target.value }))}><option value="">No reminder</option><option value="15">15 minutes before</option><option value="30">30 minutes before</option><option value="60">1 hour before</option><option value="1440">1 day before</option></select></div><label className="check-row"><input type="checkbox" checked={routine.calendarProjection} onChange={(event) => setRoutine((current) => ({ ...current, calendarProjection: event.target.checked }))} />Show in family planner</label><label className="check-row"><input type="checkbox" checked={routine.termOnly} onChange={(event) => setRoutine((current) => ({ ...current, termOnly: event.target.checked }))} />Only during term</label><fieldset className="people-fieldset"><legend>Colour</legend><div className="color-picker">{colors.map((color) => <button type="button" className={routine.color === color ? "is-active" : ""} aria-label={`Use ${color}`} aria-pressed={routine.color === color} style={{ backgroundColor: color }} onClick={() => setRoutine((current) => ({ ...current, color }))} key={color}>{routine.color === color ? <Check aria-hidden="true" size={15} /> : null}</button>)}</div></fieldset></div></details>
          <button type="submit" className="button button--primary" disabled={working === "routine" || !routine.days.size || !routine.name.trim()}>{working === "routine" ? "Saving…" : editingRoutine ? "Save changes" : "Add activity"}</button>
        </form>
      </Modal>

      <Modal open={showTerm} onOpenChange={(open) => { setShowTerm(open); if (!open) setEditingTerm(null); }} title={editingTerm ? "Edit term dates" : "Add term dates"} description={selectedName}><form className="form-stack" onSubmit={saveTerm}><div className="field"><label htmlFor="term-label">Label (optional)</label><input id="term-label" value={termLabel} onChange={(event) => setTermLabel(event.target.value)} placeholder="Autumn term" /></div><div className="form-grid"><div className="field"><label htmlFor="term-start">Starts</label><input id="term-start" type="date" value={termStart} onChange={(event) => setTermStart(event.target.value)} required /></div><div className="field"><label htmlFor="term-end">Ends</label><input id="term-end" type="date" min={termStart || undefined} value={termEnd} onChange={(event) => setTermEnd(event.target.value)} required /></div></div><button type="submit" className="button button--primary" disabled={working === "term" || !termStart || !termEnd}>{working === "term" ? "Saving…" : editingTerm ? "Save changes" : "Add term dates"}</button></form></Modal>

      <Modal open={Boolean(copyingRoutine)} onOpenChange={(open) => !open && setCopyingRoutine(null)} title={`Copy ${copyingRoutine?.name ?? "routine"}`} description="Keep the same days, time, preparation and packing list."><div className="form-stack"><div className="field"><label htmlFor="routine-copy-person">Copy to</label><select id="routine-copy-person" value={copyTarget} onChange={(event) => setCopyTarget(event.target.value)}>{people.filter((person) => person.id !== copyingRoutine?.person_id).map((person) => <option value={person.id} key={person.id}>{person.name}</option>)}</select></div><button type="button" className="button button--primary" disabled={!copyTarget || working === "copy"} onClick={() => void duplicateRoutine()}><Copy aria-hidden="true" size={16} />{working === "copy" ? "Copying…" : "Copy routine"}</button></div></Modal>
    </div>
  );
}
