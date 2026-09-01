import { format, parseISO } from "date-fns";
import { Check, LoaderCircle } from "lucide-react";
import { useEffect, useMemo, useRef, useState, type FormEvent } from "react";

import { api, localISODate, localISODateTime } from "../api";
import type { FamilyMember, FamilyTask, TaskCategory } from "../types";
import {
  taskRecurrenceRule,
  taskRepeatOption,
  type TaskRepeatOption,
} from "../taskRecurrence";
import {
  DocumentAttachmentField,
  uploadPendingDocument,
  type PendingDocumentAttachment,
} from "./DocumentAttachmentField";
import { Modal, Segmented } from "./ui";

const categories: Array<{ value: TaskCategory; label: string }> = [
  { value: "bins", label: "Bins" },
  { value: "household", label: "Household" },
  { value: "shopping", label: "Shopping" },
  { value: "admin", label: "Admin" },
  { value: "other", label: "Other" },
];

type PriorityOption = "1" | "2" | "3";

function datePart(value?: string | null): string {
  if (!value) return localISODate(new Date());
  const parsed = parseISO(value);
  return Number.isNaN(parsed.getTime()) ? localISODate(new Date()) : localISODate(parsed);
}

function timePart(value?: string | null): string {
  if (!value) return format(new Date(), "HH:mm");
  const parsed = parseISO(value);
  return Number.isNaN(parsed.getTime()) ? "09:00" : format(parsed, "HH:mm");
}

function sameDateTime(left?: string | null, right?: string | null): boolean {
  if (!left || !right) return left === right;
  const leftDate = parseISO(left);
  const rightDate = parseISO(right);
  if (Number.isNaN(leftDate.getTime()) || Number.isNaN(rightDate.getTime())) return left === right;
  return leftDate.getTime() === rightDate.getTime();
}

function taskAssigneeIDs(task: FamilyTask | null): string[] {
  if (!task) return [];
  return [...new Set([
    ...task.assignees.map((assignee) => assignee.assignee_id),
    ...(task.assigned_to ? [task.assigned_to] : []),
  ])].sort();
}

export function TaskEditorDialog({
  open,
  task,
  members,
  onOpenChange,
  onSaved,
  notify,
}: {
  open: boolean;
  task: FamilyTask | null;
  members: FamilyMember[];
  onOpenChange: (open: boolean) => void;
  onSaved: (task: FamilyTask) => void;
  notify: (message: string) => void;
}) {
  const [title, setTitle] = useState("");
  const [description, setDescription] = useState("");
  const [category, setCategory] = useState<TaskCategory>("other");
  const [priority, setPriority] = useState<PriorityOption>("2");
  const [hasDueDate, setHasDueDate] = useState(false);
  const [dueDate, setDueDate] = useState(localISODate(new Date()));
  const [dueTime, setDueTime] = useState("18:00");
  const [repeat, setRepeat] = useState<TaskRepeatOption>("never");
  const [hasActionableFrom, setHasActionableFrom] = useState(false);
  const [actionableDate, setActionableDate] = useState(localISODate(new Date()));
  const [actionableTime, setActionableTime] = useState("09:00");
  const [assigneeIDs, setAssigneeIDs] = useState<Set<string>>(new Set());
  const [attachmentDocumentID, setAttachmentDocumentID] = useState<string | null>(null);
  const [pendingAttachment, setPendingAttachment] = useState<PendingDocumentAttachment | null>(null);
  const [attachmentUploadBlocked, setAttachmentUploadBlocked] = useState(false);
  const attachmentDocumentIDRef = useRef<string | null>(null);
  const pendingAttachmentRef = useRef<PendingDocumentAttachment | null>(null);
  const uploadedDocumentIDRef = useRef<string | null>(null);
  const [submitting, setSubmitting] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [showMore, setShowMore] = useState(false);
  const [createOperation, setCreateOperation] = useState<{ id: string; fingerprint: string; timestamp: string } | null>(null);

  useEffect(() => {
    if (!open) return;
    setTitle(task?.title ?? "");
    setDescription(task?.description ?? "");
    setCategory(task?.category ?? "other");
    setPriority(String(task?.priority ?? 2) as PriorityOption);
    setHasDueDate(Boolean(task?.due_date));
    setDueDate(datePart(task?.due_date));
    setDueTime(task?.due_date ? timePart(task.due_date) : "18:00");
    setRepeat(taskRepeatOption(task?.recurrence_rule));
    setHasActionableFrom(Boolean(task?.actionable_from));
    setActionableDate(datePart(task?.actionable_from));
    setActionableTime(task?.actionable_from ? timePart(task.actionable_from) : "09:00");
    setAssigneeIDs(new Set(taskAssigneeIDs(task)));
    const initialDocumentID = task?.source_document_id ?? null;
    attachmentDocumentIDRef.current = initialDocumentID;
    pendingAttachmentRef.current = null;
    uploadedDocumentIDRef.current = null;
    setAttachmentDocumentID(initialDocumentID);
    setPendingAttachment(null);
    setAttachmentUploadBlocked(false);
    setSubmitting(false);
    setError(null);
    setShowMore(Boolean(task));
    setCreateOperation(null);
  }, [open, task]);

  const selectedMembers = useMemo(
    () => members.filter((member) => assigneeIDs.has(member.id)),
    [assigneeIDs, members],
  );

  function toggleAssignee(id: string) {
    setAssigneeIDs((current) => {
      const next = new Set(current);
      if (next.has(id)) next.delete(id);
      else next.add(id);
      return next;
    });
  }

  async function resolveSourceDocumentID(): Promise<string | null> {
    if (!pendingAttachmentRef.current) return attachmentDocumentIDRef.current;
    if (uploadedDocumentIDRef.current) return uploadedDocumentIDRef.current;
    const uploaded = await uploadPendingDocument(pendingAttachmentRef.current);
    uploadedDocumentIDRef.current = uploaded.id;
    attachmentDocumentIDRef.current = uploaded.id;
    setAttachmentDocumentID(uploaded.id);
    return uploaded.id;
  }

  async function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    const cleanTitle = title.trim();
    if (!cleanTitle) {
      setError("Add a task title first.");
      return;
    }

    const cleanDescription = description.trim() || null;
    const dueValue = hasDueDate ? localISODateTime(new Date(`${dueDate}T${dueTime}:00`)) : null;
    if (repeat !== "never" && !hasDueDate) {
      setError("Choose a due date for the repeating task.");
      return;
    }
    const dueDateChanged = task ? dueDate !== datePart(task.due_date) : true;
    const recurrenceValue = task
      && repeat === taskRepeatOption(task.recurrence_rule)
      && !dueDateChanged
      ? task.recurrence_rule ?? null
      : taskRecurrenceRule(repeat, new Date(`${dueDate}T${dueTime}:00`));
    const actionableValue = hasActionableFrom
      ? localISODateTime(new Date(`${actionableDate}T${actionableTime}:00`))
      : null;
    if (dueValue && actionableValue && new Date(actionableValue) > new Date(dueValue)) {
      setError("Hide until must be before the due date.");
      return;
    }
    const assignees = selectedMembers.map((member) => ({
      assignee_id: member.id,
      assignee_type: member.member_type,
    }));

    setSubmitting(true);
    setError(null);
    try {
      const sourceDocumentID = await resolveSourceDocumentID();
      let saved: FamilyTask;
      if (task) {
        const updates: Record<string, unknown> = {};
        if (cleanTitle !== task.title) updates.title = cleanTitle;
        if (cleanDescription !== (task.description ?? null)) updates.description = cleanDescription;
        if (category !== task.category) updates.category = category;
        if (Number(priority) !== task.priority) updates.priority = Number(priority);
        if (!sameDateTime(dueValue, task.due_date ?? null)) updates.due_date = dueValue;
        if (recurrenceValue !== (task.recurrence_rule ?? null)) {
          updates.recurrence_rule = recurrenceValue;
        }
        if (!sameDateTime(actionableValue, task.actionable_from ?? null)) updates.actionable_from = actionableValue;
        if (sourceDocumentID !== (task.source_document_id ?? null)) {
          updates.source_document_id = sourceDocumentID;
        }
        const previousIDs = taskAssigneeIDs(task);
        const nextIDs = selectedMembers.map((member) => member.id).sort();
        if (previousIDs.join("|") !== nextIDs.join("|")) {
          updates.assignees = assignees;
          updates.assigned_to = null;
        }
        saved = Object.keys(updates).length
          ? await api<FamilyTask>(`/tasks/${task.id}`, { method: "PUT", body: JSON.stringify(updates) })
          : task;
      } else {
        const createPayload = {
          title: cleanTitle,
          description: cleanDescription,
          category,
          priority: Number(priority),
          due_date: dueValue,
          recurrence_rule: recurrenceValue,
          actionable_from: actionableValue,
          assignees,
          source_document_id: sourceDocumentID,
        };
        const fingerprint = JSON.stringify(createPayload);
        const operation = createOperation
          ?? { id: crypto.randomUUID(), fingerprint, timestamp: new Date().toISOString() };
        setCreateOperation(operation);
        saved = await api<FamilyTask>("/tasks/", {
          method: "POST",
          body: JSON.stringify({
            id: operation.id,
            ...createPayload,
            client_id: operation.id,
            client_timestamp: operation.timestamp,
          }),
        });
        setCreateOperation(null);
      }
      onSaved(saved);
      notify(task ? "Task updated." : "Task created.");
      onOpenChange(false);
    } catch (requestError) {
      setError(requestError instanceof Error ? requestError.message : "The task could not be saved.");
    } finally {
      setSubmitting(false);
    }
  }

  return (
    <Modal
      open={open}
      onOpenChange={onOpenChange}
      title={task ? "Edit task" : "New task"}
      description={task ? "Update this shared task." : "Add something for the family to get done."}
      size="wide"
    >
      <form className="form-stack task-editor-form" onSubmit={submit} aria-busy={submitting}>
        {error ? <div className="form-error" role="alert">{error}</div> : null}
        <div className="field">
          <label htmlFor="task-title">Title</label>
          <input id="task-title" value={title} onChange={(event) => setTitle(event.target.value)} maxLength={300} autoFocus required />
        </div>

        <fieldset className="task-assignee-picker">
          <legend>Owner</legend>
          <div>
            {members.map((member) => (
              <label className="task-assignee-option" key={member.id}>
                <input type="checkbox" checked={assigneeIDs.has(member.id)} onChange={() => toggleAssignee(member.id)} />
                <span className={`task-avatar is-${member.member_type}`} aria-hidden="true">{member.name.slice(0, 1).toUpperCase()}</span>
                <span>{member.name}</span>
                {assigneeIDs.has(member.id) ? <Check aria-hidden="true" size={17} /> : null}
              </label>
            ))}
          </div>
        </fieldset>

        <fieldset className="task-editor-due-date">
          <label className="check-row" htmlFor="task-has-due"><input id="task-has-due" type="checkbox" checked={hasDueDate} onChange={(event) => { const checked = event.target.checked; setHasDueDate(checked); if (!checked) setRepeat("never"); }} /> Add a due date</label>
          {hasDueDate ? <div className="form-grid"><div className="field"><label htmlFor="task-due-date">Date</label><input id="task-due-date" type="date" value={dueDate} onChange={(event) => setDueDate(event.target.value)} required /></div><div className="field"><label htmlFor="task-due-time">Time</label><input id="task-due-time" type="time" value={dueTime} onChange={(event) => setDueTime(event.target.value)} required /></div></div> : null}
          <div className="field">
            <label htmlFor="task-repeat">Repeat</label>
            <select id="task-repeat" value={repeat} onChange={(event) => { const option = event.target.value as TaskRepeatOption; setRepeat(option); if (option !== "never") setHasDueDate(true); }}>
              <option value="never">Never</option>
              <option value="daily">Every day</option>
              <option value="weekly">Every week</option>
              <option value="monthly">Every month</option>
              <option value="yearly">Every year</option>
            </select>
            {repeat !== "never" ? <small>Repeats from the due date.</small> : null}
          </div>
        </fieldset>

        <button type="button" className="task-editor-more-toggle" aria-expanded={showMore} onClick={() => setShowMore((current) => !current)}>{showMore ? "Less" : "More"}</button>

        {showMore ? <div className="task-editor-more">
          <div className="field">
            <label htmlFor="task-description">Description (optional)</label>
            <textarea id="task-description" value={description} onChange={(event) => setDescription(event.target.value)} rows={3} maxLength={10_000} />
          </div>

          <div className="task-editor-options">
            <div className="field">
              <label htmlFor="task-category">Category</label>
              <select id="task-category" value={category} onChange={(event) => setCategory(event.target.value as TaskCategory)}>
                {categories.map((option) => <option value={option.value} key={option.value}>{option.label}</option>)}
              </select>
            </div>
            <div className="field">
              <span className="field-label">Priority</span>
              <Segmented value={priority} onChange={setPriority} label="Task priority" options={[
                { value: "1", label: "Low" },
                { value: "2", label: "Medium" },
                { value: "3", label: "High" },
              ]} />
            </div>
          </div>

          <fieldset className="task-editor-hide-until">
            <label className="check-row" htmlFor="task-has-actionable"><input id="task-has-actionable" type="checkbox" checked={hasActionableFrom} onChange={(event) => setHasActionableFrom(event.target.checked)} /> Hide until</label>
            {hasActionableFrom ? <div className="form-grid"><div className="field"><label htmlFor="task-actionable-date">Date</label><input id="task-actionable-date" type="date" value={actionableDate} onChange={(event) => setActionableDate(event.target.value)} required /></div><div className="field"><label htmlFor="task-actionable-time">Time</label><input id="task-actionable-time" type="time" value={actionableTime} onChange={(event) => setActionableTime(event.target.value)} required /></div></div> : null}
          </fieldset>

          <DocumentAttachmentField
            active={open}
            idPrefix="task-editor"
            currentDocument={task?.source_document}
            selectedDocumentID={attachmentDocumentID}
            pending={pendingAttachment}
            disabled={submitting}
            onSelect={(documentID) => {
              attachmentDocumentIDRef.current = documentID;
              pendingAttachmentRef.current = null;
              uploadedDocumentIDRef.current = null;
              setAttachmentDocumentID(documentID);
              setPendingAttachment(null);
            }}
            onPending={(nextPending) => {
              if (!nextPending) {
                attachmentDocumentIDRef.current = null;
                setAttachmentDocumentID(null);
              }
              pendingAttachmentRef.current = nextPending;
              uploadedDocumentIDRef.current = null;
              setPendingAttachment(nextPending);
            }}
            onUploadBlockedChange={setAttachmentUploadBlocked}
          />
        </div> : null}

        <div className="dialog-actions">
          <button type="button" className="button button--secondary" onClick={() => onOpenChange(false)}>Cancel</button>
          <button type="submit" className="button button--primary" disabled={submitting || !title.trim() || attachmentUploadBlocked} aria-describedby={attachmentUploadBlocked ? "task-editor-attachment-offline" : undefined}>
            {submitting ? <LoaderCircle className="spin" aria-hidden="true" size={17} /> : null}
            {submitting ? "Saving…" : task ? "Save changes" : "Create task"}
          </button>
        </div>
      </form>
    </Modal>
  );
}
