import { CalendarDays, Link2, ListTodo, LoaderCircle, RefreshCw, Search } from "lucide-react";
import { addDays, format, parseISO } from "date-fns";
import { useCallback, useEffect, useMemo, useRef, useState, type FormEvent } from "react";

import { api } from "../api";
import type { CalendarEvent, FamilyDocument, FamilyTask } from "../types";
import { Segmented, cn } from "./ui";

type LinkKind = "event" | "task";
type LinkCandidate = {
  id: string;
  title: string;
  detail: string;
};

function documentAnchor(sourceDocument: FamilyDocument): Date {
  const parsed = parseISO(sourceDocument.document_date ?? sourceDocument.created_at);
  return Number.isNaN(parsed.getTime()) ? new Date() : parsed;
}

function eventListPath(sourceDocument: FamilyDocument): string {
  const anchor = documentAnchor(sourceDocument);
  const start = format(addDays(anchor, -180), "yyyy-MM-dd");
  const end = format(addDays(anchor, 180), "yyyy-MM-dd");
  return `/calendar/?start=${start}&end=${end}&limit=200`;
}

function eventCandidates(events: CalendarEvent[], sourceDocument: FamilyDocument): LinkCandidate[] {
  const alreadyLinked = new Set((sourceDocument.linked_events ?? []).map((event) => event.id));
  const unique = new Map<string, LinkCandidate>();
  const anchorTime = documentAnchor(sourceDocument).getTime();
  const ordered = [...events].sort((left, right) => (
    Math.abs(parseISO(left.start_time).getTime() - anchorTime)
    - Math.abs(parseISO(right.start_time).getTime() - anchorTime)
  ));
  for (const event of ordered) {
    const id = event.series_id ?? event.id;
    if (alreadyLinked.has(id) || alreadyLinked.has(event.id) || event.source_document_id) continue;
    if (!unique.has(id)) {
      const date = parseISO(event.start_time);
      unique.set(id, {
        id,
        title: event.title,
        detail: Number.isNaN(date.getTime())
          ? event.start_time
          : format(date, event.all_day ? "d MMM yyyy" : "d MMM yyyy, HH:mm"),
      });
    }
  }
  return [...unique.values()];
}

function taskCandidates(tasks: FamilyTask[], sourceDocument: FamilyDocument): LinkCandidate[] {
  const alreadyLinked = new Set((sourceDocument.linked_tasks ?? []).map((task) => task.id));
  return tasks
    .filter((task) => task.created_by !== "bin-scraper" && !alreadyLinked.has(task.id) && !task.source_document_id)
    .map((task) => {
      const due = task.due_date ? parseISO(task.due_date) : null;
      const dueLabel = due && !Number.isNaN(due.getTime()) ? format(due, "d MMM yyyy") : null;
      return {
        id: task.id,
        title: task.title,
        detail: task.completed_at
          ? `Completed${dueLabel ? ` · due ${dueLabel}` : ""}`
          : dueLabel ? `Due ${dueLabel}` : "No due date",
      };
    });
}

async function fetchCandidates(kind: LinkKind, sourceDocument: FamilyDocument): Promise<LinkCandidate[]> {
  if (kind === "event") {
    const events = await api<CalendarEvent[]>(eventListPath(sourceDocument));
    return eventCandidates(Array.isArray(events) ? events : [], sourceDocument);
  }
  const tasks = await api<FamilyTask[]>("/tasks/?limit=200");
  return taskCandidates(Array.isArray(tasks) ? tasks : [], sourceDocument);
}

export function ExistingRecordLinker({
  sourceDocument,
  onCancel,
  onLinked,
}: {
  sourceDocument: FamilyDocument;
  onCancel: () => void;
  onLinked: (kind: LinkKind, title: string) => void | Promise<void>;
}) {
  const [kind, setKind] = useState<LinkKind>("event");
  const [query, setQuery] = useState("");
  const [candidates, setCandidates] = useState<LinkCandidate[]>([]);
  const [selectedID, setSelectedID] = useState("");
  const [loading, setLoading] = useState(true);
  const [submitting, setSubmitting] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const loadGeneration = useRef(0);

  const load = useCallback(async () => {
    const generation = ++loadGeneration.current;
    setLoading(true);
    setError(null);
    setSelectedID("");
    try {
      const result = await fetchCandidates(kind, sourceDocument);
      if (generation === loadGeneration.current) setCandidates(result);
    } catch (requestError) {
      if (generation === loadGeneration.current) {
        setCandidates([]);
        setError(requestError instanceof Error ? requestError.message : "Family items could not be loaded.");
      }
    } finally {
      if (generation === loadGeneration.current) setLoading(false);
    }
  }, [kind, sourceDocument]);

  useEffect(() => {
    void load();
  }, [load]);

  const visible = useMemo(() => {
    const term = query.trim().toLocaleLowerCase();
    if (!term) return candidates;
    return candidates.filter((candidate) => `${candidate.title} ${candidate.detail}`.toLocaleLowerCase().includes(term));
  }, [candidates, query]);

  async function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    const chosen = candidates.find((candidate) => candidate.id === selectedID);
    if (!chosen) {
      setError(`Choose ${kind === "event" ? "an event" : "a task"} first.`);
      return;
    }
    setSubmitting(true);
    setError(null);
    try {
      // Refresh immediately before the update so a deleted, linked, or changed
      // result cannot be selected from a stale dialog snapshot.
      const fresh = await fetchCandidates(kind, sourceDocument);
      const current = fresh.find((candidate) => candidate.id === selectedID);
      if (!current) {
        setCandidates(fresh);
        setSelectedID("");
        setError(`That ${kind} is no longer available. Choose another one.`);
        return;
      }
      await api(kind === "event" ? `/calendar/${current.id}` : `/tasks/${current.id}`, {
        method: "PUT",
        body: JSON.stringify({ source_document_id: sourceDocument.id }),
      });
      await onLinked(kind, current.title);
    } catch (requestError) {
      setError(requestError instanceof Error ? requestError.message : `The ${kind} could not be attached.`);
    } finally {
      setSubmitting(false);
    }
  }

  const itemLabel = kind === "event" ? "event" : "task";
  return (
    <form className="form-stack existing-record-linker" onSubmit={submit} aria-busy={loading || submitting}>
      <Segmented
        value={kind}
        onChange={(nextKind) => { setKind(nextKind); setQuery(""); }}
        label="Item type"
        options={[{ value: "event", label: "Calendar event" }, { value: "task", label: "Task" }]}
      />
      <p className="field-help">Only items without another document attached are shown.</p>
      <label className="search-field" htmlFor="existing-record-search">
        <span className="sr-only">Search existing {itemLabel}s</span>
        <Search aria-hidden="true" size={17} />
        <input
          id="existing-record-search"
          type="search"
          value={query}
          onChange={(event) => setQuery(event.target.value)}
          placeholder={`Search ${itemLabel}s`}
          autoComplete="off"
        />
      </label>
      {error ? <div className="attachment-error" role="alert"><span>{error}</span>{!submitting && !candidates.length ? <button type="button" className="button button--secondary button--compact" onClick={() => void load()}><RefreshCw aria-hidden="true" size={15} /> Retry</button> : null}</div> : null}
      {loading ? <div className="existing-link-loading" role="status"><LoaderCircle className="spin" aria-hidden="true" size={18} /> Loading {itemLabel}s…</div> : null}
      {!loading && !error && !visible.length ? <div className="existing-link-empty"><strong>{query ? `No matching ${itemLabel}s` : `No unattached ${itemLabel}s`}</strong><span>{query ? "Try another search." : `Create a new ${itemLabel}, or remove another document attachment first.`}</span></div> : null}
      {!loading && visible.length ? (
        <fieldset className="existing-link-results">
          <legend className="sr-only">Choose {kind === "event" ? "an event" : "a task"}</legend>
          {visible.map((candidate) => (
            <label className={cn("existing-link-option", selectedID === candidate.id && "is-selected")} key={candidate.id}>
              <input type="radio" name="existing-record" value={candidate.id} checked={selectedID === candidate.id} onChange={() => setSelectedID(candidate.id)} />
              {kind === "event" ? <CalendarDays aria-hidden="true" size={18} /> : <ListTodo aria-hidden="true" size={18} />}
              <span><strong>{candidate.title}</strong><small>{candidate.detail}</small></span>
            </label>
          ))}
        </fieldset>
      ) : null}
      <div className="dialog-actions">
        <button type="button" className="button button--secondary" disabled={submitting} onClick={onCancel}>Cancel</button>
        <button type="submit" className="button button--primary" disabled={loading || submitting || !selectedID}>
          {submitting ? <LoaderCircle className="spin" aria-hidden="true" size={16} /> : <Link2 aria-hidden="true" size={16} />}
          {submitting ? "Checking…" : `Attach to ${itemLabel}`}
        </button>
      </div>
    </form>
  );
}
