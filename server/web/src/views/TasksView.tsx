import {
  CalendarClock,
  Check,
  CheckCircle2,
  ChevronRight,
  Clock3,
  Edit3,
  Library,
  ListTodo,
  Paperclip,
  Plus,
  Repeat2,
  RotateCcw,
  Search,
  SlidersHorizontal,
  Trash2,
  UsersRound,
  WalletCards,
} from "lucide-react";
import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { addDays, format, isBefore, isToday, parseISO, startOfDay } from "date-fns";

import { api } from "../api";
import { useAuth } from "../AuthContext";
import { TaskEditorDialog } from "../components/TaskEditorDialog";
import { DocumentViewer } from "../components/DocumentViewer";
import type { FamilyMember, FamilyTask, LinkedDocument, TaskCategory } from "../types";
import { taskRecurrenceLabel } from "../taskRecurrence";
import { EmptyState, ErrorState, Modal, Segmented, SkeletonList, cn } from "../components/ui";

type OwnerView = "mine" | "all";
type CategoryView = "all" | TaskCategory;
type PriorityView = "all" | "1" | "2" | "3";
type TaskGroupKey = "today" | "soon" | "waiting" | "completed";

const categories: Array<{ value: CategoryView; label: string }> = [
  { value: "all", label: "All" },
  { value: "bins", label: "Bins" },
  { value: "household", label: "Household" },
  { value: "shopping", label: "Shopping" },
  { value: "admin", label: "Admin" },
  { value: "other", label: "Other" },
];

function taskDate(value?: string | null): Date | null {
  if (!value) return null;
  const parsed = parseISO(value);
  return Number.isNaN(parsed.getTime()) ? null : parsed;
}

function isDateOnly(value?: string | null): boolean {
  return Boolean(value && /^\d{4}-\d{2}-\d{2}$/.test(value));
}

function taskDescription(task: FamilyTask): string | null {
  if (task.managed_source && !isLibraryManaged(task)) return null;
  if (!task.description) return null;
  if (task.category !== "bins") return task.description;
  const labels: Record<string, string> = {
    black: "refuse",
    blue: "recycling",
    green: "garden",
  };
  const descriptions = task.description
    .split(",")
    .map((value) => value.trim())
    .filter(Boolean)
    .map((value) => labels[value] ?? value);
  if (!descriptions.length) return null;
  const result = descriptions.join(", ");
  return result.slice(0, 1).toUpperCase() + result.slice(1);
}

function dueText(task: FamilyTask): string {
  const due = taskDate(task.due_date);
  if (!due) return "No due date";
  if (isDateOnly(task.due_date)) return isToday(due) ? "Today" : format(due, "EEE d MMM");
  if (isToday(due)) return `Today at ${format(due, "HH:mm")}`;
  return format(due, "EEE d MMM, HH:mm");
}

function hideUntilText(task: FamilyTask): string | null {
  const actionable = taskDate(task.actionable_from);
  if (!actionable) return null;
  if (isToday(actionable)) return `Hide until today at ${format(actionable, "HH:mm")}`;
  return `Hide until ${format(actionable, "EEE d MMM, HH:mm")}`;
}

function categoryLabel(category: TaskCategory): string {
  return category.slice(0, 1).toUpperCase() + category.slice(1);
}

function isLibraryManaged(task: FamilyTask): boolean {
  return task.managed_source?.kind === "library_loan";
}

function taskCategoryLabel(task: FamilyTask): string {
  if (isLibraryManaged(task)) return "Library";
  if (task.managed_source) return "Money";
  return categoryLabel(task.category);
}

function priorityLabel(priority: number): string {
  if (priority === 3) return "High";
  if (priority === 1) return "Low";
  return "Medium";
}

function taskGroup(task: FamilyTask, now = new Date()): TaskGroupKey {
  if (task.completed_at) return "completed";
  const actionable = taskDate(task.actionable_from);
  if (actionable && actionable.getTime() > now.getTime()) return "waiting";
  const due = taskDate(task.due_date);
  if (due && isBefore(due, startOfDay(addDays(now, 1)))) return "today";
  return "soon";
}

function compareTasks(left: FamilyTask, right: FamilyTask, group: TaskGroupKey): number {
  if (group === "completed") return (right.completed_at ?? "").localeCompare(left.completed_at ?? "");
  if (group === "waiting" && left.actionable_from !== right.actionable_from) {
    return (left.actionable_from ?? "9999").localeCompare(right.actionable_from ?? "9999");
  }
  if (left.due_date !== right.due_date) return (left.due_date ?? "9999").localeCompare(right.due_date ?? "9999");
  if (left.priority !== right.priority) return right.priority - left.priority;
  return left.title.localeCompare(right.title);
}

export function TasksView({
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
  const { user } = useAuth();
  const [tasks, setTasks] = useState<FamilyTask[]>([]);
  const [ownerView, setOwnerView] = useState<OwnerView>("mine");
  const [categoryView, setCategoryView] = useState<CategoryView>("all");
  const [priorityView, setPriorityView] = useState<PriorityView>("all");
  const [filtersOpen, setFiltersOpen] = useState(false);
  const [search, setSearch] = useState("");
  const [selectedTask, setSelectedTask] = useState<FamilyTask | null>(null);
  const [viewingDocument, setViewingDocument] = useState<LinkedDocument | null>(null);
  const [previewReturnTask, setPreviewReturnTask] = useState<FamilyTask | null>(null);
  const [editingTask, setEditingTask] = useState<FamilyTask | null>(null);
  const [editorOpen, setEditorOpen] = useState(false);
  const [taskToDelete, setTaskToDelete] = useState<FamilyTask | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [actionError, setActionError] = useState<string | null>(null);
  const [completing, setCompleting] = useState<string | null>(null);
  const [reopening, setReopening] = useState<string | null>(null);
  const [completingAssignment, setCompletingAssignment] = useState<string | null>(null);
  const [deleting, setDeleting] = useState(false);
  const loadGeneration = useRef(0);
  const focusTaskID = new URL(window.location.href).searchParams.get("task");

  const memberNames = useMemo(() => new Map(members.map((member) => [member.id, member.name])), [members]);

  useEffect(() => {
    if (!focusTaskID) return;
    setOwnerView("all");
    setCategoryView("all");
    setPriorityView("all");
    setSearch("");
  }, [focusTaskID]);

  const load = useCallback(async (background = false) => {
    const generation = ++loadGeneration.current;
    if (!background) setLoading(true);
    setError(null);
    try {
      const params = new URLSearchParams({ order: "attention", limit: "200" });
      const result = await api<FamilyTask[]>(`/tasks/?${params.toString()}`);
      if (generation !== loadGeneration.current) return;
      setTasks(result);
    } catch (requestError) {
      if (generation !== loadGeneration.current) return;
      setError(requestError instanceof Error ? requestError.message : "Tasks are unavailable.");
    } finally {
      if (generation === loadGeneration.current) setLoading(false);
    }
  }, []);

  const lastRevision = useRef(revision);
  useEffect(() => {
    const background = revision !== lastRevision.current;
    lastRevision.current = revision;
    void load(background);
  }, [load, revision]);

  useEffect(() => {
    if (!focusTaskID || loading) return;
    const match = tasks.find((task) => task.id === focusTaskID);
    if (!match) return;
    setSelectedTask(match);
    const url = new URL(window.location.href);
    url.searchParams.delete("task");
    url.searchParams.delete("task_status");
    window.history.replaceState({}, "", url);
  }, [focusTaskID, loading, tasks]);

  const visibleTasks = useMemo(() => {
    const query = search.trim().toLowerCase();
    return tasks
      .filter((task) => {
        if (ownerView === "all" || !user) return true;
        if (task.created_by === "bin-scraper") return true;
        const hasAssignments = task.assignees.length > 0 || Boolean(task.assigned_to);
        return task.assignees.some((assignee) => assignee.assignee_id === user.id)
          || task.assigned_to === user.id
          || task.created_by === user.id
          || !hasAssignments;
      })
      .filter((task) => !query
        || task.title.toLowerCase().includes(query)
        || taskDescription(task)?.toLowerCase().includes(query)
        || task.assignees.some((assignee) => assignee.assignee_name?.toLowerCase().includes(query)))
      .filter((task) => categoryView === "all" || task.category === categoryView)
      .filter((task) => priorityView === "all" || task.priority === Number(priorityView));
  }, [categoryView, ownerView, priorityView, search, tasks, user]);

  const taskGroups = ([
    { key: "today", title: "Today & overdue" },
    { key: "soon", title: "Soon" },
    { key: "waiting", title: "Waiting" },
    { key: "completed", title: "Completed" },
  ] as const)
    .map((group) => ({ ...group, tasks: visibleTasks.filter((task) => taskGroup(task) === group.key).sort((left, right) => compareTasks(left, right, group.key)) }))
    .filter((group) => group.tasks.length > 0);

  function replaceTask(updated: FamilyTask) {
    setTasks((current) => current.map((task) => task.id === updated.id ? updated : task));
    setSelectedTask((current) => current?.id === updated.id ? updated : current);
  }

  function openNewTask() {
    setActionError(null);
    setEditingTask(null);
    setEditorOpen(true);
  }

  function openEditTask(task: FamilyTask) {
    setActionError(null);
    setSelectedTask(null);
    setEditingTask(task);
    setEditorOpen(true);
  }

  function savedTask(saved: FamilyTask) {
    setTasks((current) => current.some((task) => task.id === saved.id)
      ? current.map((task) => task.id === saved.id ? saved : task)
      : [saved, ...current]);
    onDataChanged();
  }

  async function complete(task: FamilyTask) {
    setCompleting(task.id);
    setActionError(null);
    try {
      const updated = await api<FamilyTask>(`/tasks/${task.id}/complete`, { method: "PATCH" });
      replaceTask(updated);
      notify("Task completed.");
      onDataChanged();
    } catch (requestError) {
      setActionError(requestError instanceof Error ? requestError.message : "Couldn't complete that task.");
    } finally {
      setCompleting(null);
    }
  }

  async function completeForPerson(task: FamilyTask, assigneeID: string) {
    const completionID = `${task.id}:${assigneeID}`;
    setCompletingAssignment(completionID);
    setActionError(null);
    try {
      const updated = await api<FamilyTask>(`/tasks/${task.id}/complete/${assigneeID}`, { method: "PATCH" });
      replaceTask(updated);
      notify("Assignment completed.");
      onDataChanged();
    } catch (requestError) {
      setActionError(requestError instanceof Error ? requestError.message : "Couldn't complete that assignment.");
    } finally {
      setCompletingAssignment(null);
    }
  }

  async function reopen(task: FamilyTask) {
    setReopening(task.id);
    setActionError(null);
    try {
      const updated = await api<FamilyTask>(`/tasks/${task.id}/reopen`, { method: "PATCH" });
      replaceTask(updated);
      notify("Task reopened.");
      onDataChanged();
    } catch (requestError) {
      setActionError(requestError instanceof Error ? requestError.message : "Couldn't reopen that task.");
    } finally {
      setReopening(null);
    }
  }

  async function deleteTask() {
    if (!taskToDelete) return;
    setDeleting(true);
    setActionError(null);
    try {
      await api(`/tasks/${taskToDelete.id}`, { method: "DELETE" });
      setTasks((current) => current.filter((task) => task.id !== taskToDelete.id));
      setTaskToDelete(null);
      notify("Task deleted.");
      onDataChanged();
    } catch (requestError) {
      setActionError(requestError instanceof Error ? requestError.message : "Couldn't delete that task.");
    } finally {
      setDeleting(false);
    }
  }

  const hasCustomFilters = ownerView === "all" || categoryView !== "all" || priorityView !== "all";
  const filterSummary = [
    ownerView === "mine" ? "Mine" : "Everyone",
    categoryView !== "all" ? categories.find((category) => category.value === categoryView)?.label : null,
    priorityView !== "all" ? `${priorityLabel(Number(priorityView))} priority` : null,
  ].filter(Boolean).join(" · ");

  function resetFilters() {
    setOwnerView("mine");
    setCategoryView("all");
    setPriorityView("all");
  }

  return (
    <div className="standard-page tasks-page">
      <header className="page-header">
        <div><p className="page-eyebrow">Shared list</p><h1>Tasks</h1></div>
        <button type="button" className="button button--primary" onClick={openNewTask}><Plus aria-hidden="true" size={18} /> New task</button>
      </header>

      <div className="task-filter-stack">
        <div className="list-toolbar task-list-toolbar">
          <button type="button" className={cn("button button--secondary task-filter-button", hasCustomFilters && "is-active")} onClick={() => setFiltersOpen(true)} aria-label={`Filters, ${filterSummary}`}><SlidersHorizontal aria-hidden="true" size={17} /><span>Filters</span><small>{filterSummary}</small></button>
          <label className="search-field"><span className="sr-only">Search tasks</span><Search aria-hidden="true" size={17} /><input type="search" value={search} onChange={(event) => setSearch(event.target.value)} placeholder="Search tasks" /></label>
        </div>
      </div>

      {error ? <ErrorState message={error} retry={load} /> : null}
      {actionError ? <div className="form-error task-action-error" role="alert">{actionError}</div> : null}
      {loading ? <SkeletonList rows={7} /> : null}
      {!loading && !error && !visibleTasks.length ? <EmptyState title={search ? "No matching tasks" : hasCustomFilters ? "No tasks match these filters" : "All caught up"} detail={search ? "Try a different search." : hasCustomFilters ? "Try widening the filters." : "There are no tasks to show."} action={search ? () => setSearch("") : hasCustomFilters ? resetFilters : openNewTask} actionLabel={search ? "Clear search" : hasCustomFilters ? "Clear filters" : "Create a task"} /> : null}

      {!loading && !error ? (
        <div className="task-priority-groups" role="region" aria-label="Tasks">
          {taskGroups.map((group) => (
            <section className="task-priority-section" aria-labelledby={`task-group-${group.key}`} key={group.key}>
              <div className="task-section-heading"><h2 id={`task-group-${group.key}`}>{group.title}</h2><span>{group.tasks.length}</span></div>
              <div className="task-list">
                {group.tasks.map((task) => {
                  const due = taskDate(task.due_date);
                  const overdue = Boolean(!task.completed_at && due && (isDateOnly(task.due_date) ? isBefore(due, startOfDay(new Date())) : isBefore(due, new Date())));
                  const completed = Boolean(task.completed_at);
                  return (
                    <article className={cn("task-row", completed && "is-completed")} key={task.id}>
                      {completed ? <button type="button" className="task-check task-check--large task-completed-icon" aria-label={`Reopen ${task.title}`} disabled={reopening === task.id} onClick={() => void reopen(task)}><RotateCcw aria-hidden="true" size={19} /></button> : <button type="button" className="task-check task-check--large" aria-label={`Complete ${task.title}`} disabled={completing === task.id} onClick={() => void complete(task)}><Check aria-hidden="true" size={18} /></button>}
                      <button type="button" className="task-main-button" aria-label={`Open task ${task.title}`} onClick={() => setSelectedTask(task)}>
                        <strong>{task.title}</strong>
                        {taskDescription(task) ? <p>{taskDescription(task)}</p> : null}
                        <span className="task-meta">
                          <span className={cn("task-category-badge", `is-${task.category}`)}>{taskCategoryLabel(task)}</span>
                          <span className={cn(overdue && "is-overdue")}><CalendarClock aria-hidden="true" size={13} />{dueText(task)}</span>
                          {taskRecurrenceLabel(task.recurrence_rule) ? <span><Repeat2 aria-hidden="true" size={13} />{taskRecurrenceLabel(task.recurrence_rule)}</span> : null}
                          {hideUntilText(task) ? <span><Clock3 aria-hidden="true" size={13} />{hideUntilText(task)}</span> : null}
                        </span>
                        <span className="task-assignee-summary">
                          {task.assignees.length ? <span className="task-avatar-stack" aria-hidden="true">{task.assignees.slice(0, 4).map((assignee) => <span className={cn("task-avatar", `is-${assignee.assignee_type}`, assignee.completed_at && "is-complete")} key={assignee.id}>{(assignee.assignee_name ?? "?").slice(0, 1).toUpperCase()}</span>)}</span> : <UsersRound aria-hidden="true" size={14} />}
                          {task.assignees.length ? task.assignees.map((assignee) => assignee.assignee_name ?? memberNames.get(assignee.assignee_id) ?? "Unknown").join(", ") : "Everyone"}
                        </span>
                      </button>
                      <div className="priority-indicator" aria-label={`${priorityLabel(task.priority)} priority`}>{Array.from({ length: 3 }).map((_, index) => <span className={cn(index < task.priority && "is-filled")} key={index} />)}</div>
                      <ChevronRight className="task-row-chevron" aria-hidden="true" size={18} />
                    </article>
                  );
                })}
              </div>
            </section>
          ))}
        </div>
      ) : null}

      {!loading && visibleTasks.length ? <p className="list-count"><ListTodo aria-hidden="true" size={16} /> {visibleTasks.length} {visibleTasks.length === 1 ? "task" : "tasks"}</p> : null}

      <Modal open={filtersOpen} onOpenChange={setFiltersOpen} title="Filter tasks" description="Choose whose tasks to show and what kind of job you need.">
        <div className="task-filter-dialog">
          <div className="field">
            <span className="field-label">Owner</span>
            <Segmented value={ownerView} onChange={setOwnerView} label="Task owner" options={[
              { value: "mine", label: "Mine" },
              { value: "all", label: "Everyone" },
            ]} />
          </div>
          <div className="field">
            <label htmlFor="task-filter-category">Category</label>
            <select id="task-filter-category" value={categoryView} onChange={(event) => setCategoryView(event.target.value as CategoryView)}>
              {categories.map((category) => <option value={category.value} key={category.value}>{category.value === "all" ? "Any category" : category.label}</option>)}
            </select>
          </div>
          <div className="field">
            <span className="field-label">Priority</span>
            <Segmented value={priorityView} onChange={setPriorityView} label="Task priority" options={[
              { value: "all", label: "Any" },
              { value: "3", label: "High" },
              { value: "2", label: "Normal" },
              { value: "1", label: "Low" },
            ]} />
          </div>
          <div className="dialog-actions">
            <button type="button" className="button button--secondary" onClick={resetFilters}>Reset</button>
            <button type="button" className="button button--primary" onClick={() => setFiltersOpen(false)}>Done</button>
          </div>
        </div>
      </Modal>

      <Modal open={Boolean(selectedTask)} onOpenChange={(open) => !open && setSelectedTask(null)} title={selectedTask?.title ?? "Task"} description={selectedTask ? `${priorityLabel(selectedTask.priority)} priority · ${taskCategoryLabel(selectedTask)}` : undefined}>
        {selectedTask ? (
          <div className="task-detail">
            {taskDescription(selectedTask) ? <p className="task-detail-description">{taskDescription(selectedTask)}</p> : null}
            {selectedTask.created_by === "bin-scraper" ? <p className="task-managed-note">Managed from the council schedule.</p> : null}
            {selectedTask.managed_source ? isLibraryManaged(selectedTask) ? <><p className="task-managed-note">Managed from the current library loans. Completing this shared task records that the listed books were dealt with; renewal stays explicit on the official catalogue.</p><a className="linked-document-card" href={selectedTask.managed_source.deep_link}><Library aria-hidden="true" size={18} /><span><strong>Open Library books</strong><small>See the listed books, current status and official renewal links</small></span></a></> : <><p className="task-managed-note">Managed in Finance. Financial details stay there.</p><a className="linked-document-card" href={selectedTask.managed_source.deep_link}><WalletCards aria-hidden="true" size={18} /><span><strong>Open {selectedTask.managed_source.label}</strong><small>View the source in Finance</small></span></a></> : null}
            <div className="task-detail-facts">
              <span><CalendarClock aria-hidden="true" size={17} /><strong>Due</strong>{dueText(selectedTask)}</span>
              {taskRecurrenceLabel(selectedTask.recurrence_rule) ? <span><Repeat2 aria-hidden="true" size={17} /><strong>Repeat</strong>{taskRecurrenceLabel(selectedTask.recurrence_rule)}</span> : null}
              {hideUntilText(selectedTask) ? <span><Clock3 aria-hidden="true" size={17} /><strong>Hide until</strong>{hideUntilText(selectedTask)?.replace(/^Hide until /, "")}</span> : null}
            </div>
            {selectedTask.source_document ? <button type="button" className="linked-document-card" onClick={() => { setPreviewReturnTask(selectedTask); setViewingDocument(selectedTask.source_document ?? null); setSelectedTask(null); }}><Paperclip aria-hidden="true" size={18} /><span><strong>{selectedTask.source_document.title}</strong><small>{selectedTask.source_document.original_filename}</small></span></button> : null}
            <section className="task-assignment-detail" aria-labelledby="task-assignees-heading">
              <h3 id="task-assignees-heading">Assigned to</h3>
              {!selectedTask.assignees.length ? <div className="task-shared-assignment"><UsersRound aria-hidden="true" size={18} /> Everyone</div> : null}
              {selectedTask.assignees.map((assignee) => {
                const completionID = `${selectedTask.id}:${assignee.assignee_id}`;
                const name = assignee.assignee_name ?? memberNames.get(assignee.assignee_id) ?? "Unknown";
                return <div className={cn("task-assignment-row", assignee.completed_at && "is-complete")} key={assignee.id}><span className={`task-avatar is-${assignee.assignee_type}`} aria-hidden="true">{name.slice(0, 1).toUpperCase()}</span><div><strong>{name}</strong><span>{assignee.completed_at ? "Completed" : "Not completed"}</span></div>{selectedTask.managed_source ? null : !selectedTask.completed_at ? <button type="button" className="task-person-check" aria-label={`Complete ${selectedTask.title} for ${name}`} disabled={Boolean(assignee.completed_at) || completingAssignment === completionID} onClick={() => void completeForPerson(selectedTask, assignee.assignee_id)}>{assignee.completed_at ? <CheckCircle2 aria-hidden="true" size={21} /> : <Check aria-hidden="true" size={18} />}</button> : <CheckCircle2 aria-label="Completed" size={21} />}</div>;
              })}
            </section>
            <div className="dialog-actions task-detail-actions">
              {!selectedTask.completed_at ? <button type="button" className="button button--primary" disabled={completing === selectedTask.id} onClick={() => void complete(selectedTask)}><Check aria-hidden="true" size={16} /> Complete task</button> : null}
              {selectedTask.completed_at ? <button type="button" className="button button--secondary" disabled={reopening === selectedTask.id} onClick={() => void reopen(selectedTask)}><RotateCcw aria-hidden="true" size={16} /> Reopen task</button> : null}
              {selectedTask.created_by !== "bin-scraper" && !selectedTask.read_only && !selectedTask.managed_source ? <button type="button" className="button button--secondary" onClick={() => openEditTask(selectedTask)}><Edit3 aria-hidden="true" size={16} /> Edit</button> : null}
              {selectedTask.created_by !== "bin-scraper" && !selectedTask.read_only && !selectedTask.managed_source ? <button type="button" className="button button--danger" onClick={() => { setSelectedTask(null); setTaskToDelete(selectedTask); }}><Trash2 aria-hidden="true" size={16} /> Delete</button> : null}
            </div>
          </div>
        ) : null}
      </Modal>

      <DocumentViewer document={viewingDocument} onOpenChange={(open) => { if (!open) { setViewingDocument(null); if (previewReturnTask) setSelectedTask(previewReturnTask); setPreviewReturnTask(null); } }} />

      <Modal open={Boolean(taskToDelete)} onOpenChange={(open) => !open && setTaskToDelete(null)} title="Delete task?" description="This task will be removed for everyone.">
        <div className="confirm-delete"><p>{taskToDelete ? `Delete “${taskToDelete.title}”?` : ""}</p><div className="dialog-actions"><button type="button" className="button button--secondary" disabled={deleting} onClick={() => setTaskToDelete(null)}>Cancel</button><button type="button" className="button button--danger" disabled={deleting} onClick={() => void deleteTask()}><Trash2 aria-hidden="true" size={16} />{deleting ? "Deleting…" : "Delete"}</button></div></div>
      </Modal>

      <TaskEditorDialog open={editorOpen} task={editingTask} members={members} onOpenChange={setEditorOpen} onSaved={savedTask} notify={notify} />
    </div>
  );
}
