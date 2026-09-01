import { Backpack, Check, Pencil, Plus, Trash2 } from "lucide-react";
import { type FormEvent, useCallback, useEffect, useState } from "react";

import { api } from "../api";
import { EmptyState, ErrorState, Modal, SkeletonList, cn } from "../components/ui";
import type { PrepPackTemplate } from "../prepPacks";
import type { FamilyMember } from "../types";

type Draft = {
  name: string;
  matchTerms: string;
  items: string;
  leadHours: string;
  assignedTo: string;
};

const emptyDraft: Draft = {
  name: "",
  matchTerms: "",
  items: "",
  leadHours: "24",
  assignedTo: "",
};

function draftFor(template: PrepPackTemplate): Draft {
  return {
    name: template.name,
    matchTerms: template.match_terms.join(", "),
    items: template.items.join("\n"),
    leadHours: String(template.lead_hours),
    assignedTo: template.assigned_to ?? "",
  };
}

export function PrepPacksView({
  members,
  revision,
  onDataChanged,
  notify,
}: {
  members: FamilyMember[];
  revision: number;
  onDataChanged: () => void;
  notify: (message: string) => void;
}) {
  const [templates, setTemplates] = useState<PrepPackTemplate[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [editing, setEditing] = useState<PrepPackTemplate | "new" | null>(null);
  const [draft, setDraft] = useState<Draft>(emptyDraft);
  const [formError, setFormError] = useState<string | null>(null);
  const [saving, setSaving] = useState(false);
  const [removing, setRemoving] = useState<PrepPackTemplate | null>(null);
  const [workingId, setWorkingId] = useState<string | null>(null);

  const load = useCallback(async () => {
    setLoading(true);
    setError(null);
    try {
      setTemplates(await api<PrepPackTemplate[]>("/prep-packs/templates"));
    } catch (requestError) {
      setError(requestError instanceof Error ? requestError.message : "Preparation packs could not be loaded.");
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => { void load(); }, [load, revision]);

  function openEditor(template?: PrepPackTemplate) {
    setEditing(template ?? "new");
    setDraft(template ? draftFor(template) : emptyDraft);
    setFormError(null);
  }

  async function save(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (!editing) return;
    const editingId = editing === "new" ? null : editing.id;
    const matchTerms = draft.matchTerms.split(",").map((item) => item.trim()).filter(Boolean);
    const items = draft.items.split("\n").map((item) => item.trim()).filter(Boolean);
    if (!draft.name.trim() || !matchTerms.length || !items.length) {
      setFormError("Add a name, at least one matching phrase and at least one checklist item.");
      return;
    }
    setSaving(true);
    setFormError(null);
    const body = JSON.stringify({
      name: draft.name.trim(),
      match_terms: matchTerms,
      items,
      lead_hours: Number(draft.leadHours),
      assigned_to: draft.assignedTo || null,
    });
    try {
      const saved = editingId === null
        ? await api<PrepPackTemplate>("/prep-packs/templates", { method: "POST", body })
        : await api<PrepPackTemplate>(`/prep-packs/templates/${editingId}`, { method: "PATCH", body });
      setTemplates((current) => [...current.filter((item) => item.id !== saved.id), saved].sort((a, b) => a.name.localeCompare(b.name)));
      setEditing(null);
      notify(editingId === null ? "Preparation pack added." : "Preparation pack updated.");
      onDataChanged();
    } catch (requestError) {
      setFormError(requestError instanceof Error ? requestError.message : "The preparation pack could not be saved.");
    } finally {
      setSaving(false);
    }
  }

  async function toggle(template: PrepPackTemplate) {
    setWorkingId(template.id);
    try {
      const updated = await api<PrepPackTemplate>(`/prep-packs/templates/${template.id}`, {
        method: "PATCH",
        body: JSON.stringify({ enabled: !template.enabled }),
      });
      setTemplates((current) => current.map((item) => item.id === updated.id ? updated : item));
      notify(updated.enabled ? `${updated.name} suggestions enabled.` : `${updated.name} suggestions paused.`);
      onDataChanged();
    } catch (requestError) {
      notify(requestError instanceof Error ? requestError.message : "That pack could not be updated.");
    } finally {
      setWorkingId(null);
    }
  }

  async function remove() {
    if (!removing) return;
    setWorkingId(removing.id);
    try {
      await api(`/prep-packs/templates/${removing.id}`, { method: "DELETE" });
      setTemplates((current) => current.filter((item) => item.id !== removing.id));
      notify("Preparation pack removed.");
      setRemoving(null);
      onDataChanged();
    } catch (requestError) {
      notify(requestError instanceof Error ? requestError.message : "That pack could not be removed.");
    } finally {
      setWorkingId(null);
    }
  }

  if (loading) return <SkeletonList rows={4} />;
  if (error) return <ErrorState message={error} retry={() => void load()} />;

  return (
    <div className="prep-packs-page standard-page">
      <header className="page-header">
        <div><p className="page-eyebrow">Be ready before you leave</p><h1>Packing lists</h1><p>HausKlar matches these checklists to calendar events.</p></div>
        <button type="button" className="button button--primary" onClick={() => openEditor()}><Plus aria-hidden="true" size={17} /> Add pack</button>
      </header>
      {!templates.length ? <EmptyState title="No preparation packs" detail="Add an activity and HausKlar will offer its checklist before matching events." action={() => openEditor()} actionLabel="Add your first pack" /> : (
        <div className="prep-template-list">
          {templates.map((template) => (
            <article className={cn("prep-template-card", !template.enabled && "is-paused")} key={template.id}>
              <div className="prep-template-heading"><Backpack aria-hidden="true" size={21} /><div><h2>{template.name}</h2><p>Matches {template.match_terms.join(", ")} · {template.lead_hours === 0 ? "at event time" : `${template.lead_hours} hours before`}</p></div></div>
              <ul>{template.items.map((item) => <li key={item}><Check aria-hidden="true" size={15} />{item}</li>)}</ul>
              <div className="prep-template-actions">
                <button type="button" className="button button--secondary button--compact" disabled={workingId !== null} onClick={() => openEditor(template)}><Pencil aria-hidden="true" size={15} /> Edit</button>
                <button type="button" className="button button--secondary button--compact" disabled={workingId !== null} aria-pressed={template.enabled} onClick={() => void toggle(template)}>{workingId === template.id ? "Saving…" : template.enabled ? "Pause" : "Enable"}</button>
                <button type="button" className="button button--ghost button--compact is-danger" disabled={workingId !== null} onClick={() => setRemoving(template)}><Trash2 aria-hidden="true" size={15} /> Remove</button>
              </div>
            </article>
          ))}
        </div>
      )}

      {editing ? <Modal open onOpenChange={(open) => { if (!open) setEditing(null); }} title={editing === "new" ? "Add preparation pack" : `Edit ${editing.name}`} description="Use ordinary words that appear in the calendar title.">
        <form className="form-stack" onSubmit={save} aria-busy={saving}>
          {formError ? <div className="form-error" role="alert">{formError}</div> : null}
          <div className="field"><label htmlFor="prep-name">Activity name</label><input id="prep-name" value={draft.name} onChange={(event) => setDraft((current) => ({ ...current, name: event.target.value }))} placeholder="Ballet" autoComplete="off" required /></div>
          <div className="field"><label htmlFor="prep-matches">Calendar title contains</label><input id="prep-matches" value={draft.matchTerms} onChange={(event) => setDraft((current) => ({ ...current, matchTerms: event.target.value }))} placeholder="ballet, dance class" autoComplete="off" required /><small>Separate alternatives with commas.</small></div>
          <div className="field"><label htmlFor="prep-items">Checklist</label><textarea id="prep-items" rows={5} value={draft.items} onChange={(event) => setDraft((current) => ({ ...current, items: event.target.value }))} placeholder={"Pack ballet shoes\nFill water bottle"} required /><small>One task per line.</small></div>
          <div className="field"><label htmlFor="prep-lead">Offer this pack</label><select id="prep-lead" value={draft.leadHours} onChange={(event) => setDraft((current) => ({ ...current, leadHours: event.target.value }))}><option value="0">At event time</option><option value="12">12 hours before</option><option value="24">24 hours before</option><option value="36">36 hours before</option><option value="48">2 days before</option><option value="72">3 days before</option></select></div>
          <div className="field"><label htmlFor="prep-assignee">Usually assign to</label><select id="prep-assignee" value={draft.assignedTo} onChange={(event) => setDraft((current) => ({ ...current, assignedTo: event.target.value }))}><option value="">Nobody yet</option>{members.filter((member) => member.member_type === "user").map((member) => <option value={member.id} key={member.id}>{member.name}</option>)}</select></div>
          <button type="submit" className="button button--primary" disabled={saving}>{saving ? "Saving…" : "Save pack"}</button>
        </form>
      </Modal> : null}

      {removing ? <Modal open onOpenChange={(open) => { if (!open && workingId === null) setRemoving(null); }} title={`Remove ${removing.name}?`} description="Future matching events will no longer offer this checklist."><div className="confirm-actions"><button type="button" className="button button--secondary" disabled={workingId !== null} onClick={() => setRemoving(null)}>Keep pack</button><button type="button" className="button button--danger" disabled={workingId !== null} onClick={() => void remove()}>{workingId === removing.id ? "Removing…" : "Remove pack"}</button></div></Modal> : null}
    </div>
  );
}
