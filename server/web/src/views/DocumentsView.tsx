import {
  Archive,
  Check,
  CheckCircle2,
  Clipboard,
  Edit3,
  FileText,
  Inbox,
  Link2,
  ListTodo,
  Plus,
  Search,
  Settings2,
  Trash2,
  X,
} from "lucide-react";
import { useCallback, useEffect, useMemo, useRef, useState, type FormEvent } from "react";
import { format, parseISO } from "date-fns";

import { api, localISODateTime } from "../api";
import type { DocumentSuggestion, FamilyDocument, FamilyMember, LinkedDocument } from "../types";
import { DocumentViewer } from "../components/DocumentViewer";
import { ExistingRecordLinker } from "../components/ExistingRecordLinker";
import { EmptyState, ErrorState, Modal, Segmented, SkeletonList, cn } from "../components/ui";

type InboxFilter = "inbox" | "filed";
type ActionDraft = Pick<
  DocumentSuggestion,
  "kind" | "title" | "details" | "start_time" | "end_time" | "due_date" | "all_day" | "assigned_to"
>;

const categories = ["school", "medical", "childcare", "identity", "finance", "activities", "household", "other"];
const PAGE_SIZE = 30;

const categoryLabels: Record<string, string> = {
  school: "School",
  medical: "Medical",
  childcare: "Childcare",
  identity: "Identity",
  finance: "Household finance",
  activities: "Activities",
  household: "Household",
  other: "Uncategorised",
};

function fileSize(bytes: number): string {
  if (bytes < 1024 * 1024) return `${Math.max(1, Math.round(bytes / 1024))} KB`;
  return `${(bytes / (1024 * 1024)).toFixed(1)} MB`;
}

function displayDate(document: FamilyDocument): string {
  const value = document.document_date ?? document.created_at;
  const parsed = parseISO(value);
  return Number.isNaN(parsed.getTime()) ? value : format(parsed, "d MMM yyyy");
}

function dateTimeInput(value?: string | null): string {
  if (!value) return "";
  if (value.length === 10) return `${value}T09:00`;
  const parsed = new Date(value);
  if (Number.isNaN(parsed.getTime())) return "";
  const offset = parsed.getTimezoneOffset() * 60_000;
  return new Date(parsed.getTime() - offset).toISOString().slice(0, 16);
}

function actionPayload(draft: ActionDraft) {
  return {
    kind: draft.kind,
    title: draft.title.trim(),
    details: draft.details?.trim() || null,
    start_time: draft.kind === "event" ? draft.start_time || null : null,
    end_time: draft.kind === "event" ? draft.end_time || null : null,
    due_date: draft.kind === "task" ? draft.due_date || null : null,
    all_day: draft.kind === "event" ? draft.all_day : true,
    assigned_to: draft.assigned_to || null,
  };
}

function visibleSuggestions(document: FamilyDocument): DocumentSuggestion[] {
  return document.suggestions.filter((suggestion) => suggestion.status !== "dismissed");
}

function actionStatusLabel(suggestion: DocumentSuggestion): string {
  if (suggestion.result_status === "pending") return "Needs review";
  if (suggestion.result_status === "open") return "To do";
  if (suggestion.result_status === "completed") return "Completed";
  if (suggestion.result_status === "scheduled") return "On calendar";
  return "Link unavailable";
}

export function DocumentsView({
  members,
  revision,
  initialPersonId,
  onAddDocument,
  onDataChanged,
  notify,
}: {
  members: FamilyMember[];
  revision: number;
  initialPersonId?: string | null;
  onAddDocument: () => void;
  onDataChanged: () => void;
  notify: (message: string) => void;
}) {
  const [documents, setDocuments] = useState<FamilyDocument[]>([]);
  const [selected, setSelected] = useState<FamilyDocument | null>(null);
  const [viewingDocument, setViewingDocument] = useState<LinkedDocument | null>(null);
  const [previewReturnDocument, setPreviewReturnDocument] = useState<FamilyDocument | null>(null);
  const [linkingDocument, setLinkingDocument] = useState<FamilyDocument | null>(null);
  const [filter, setFilter] = useState<InboxFilter>("inbox");
  const [personFilter, setPersonFilter] = useState(initialPersonId ?? "");
  const [categoryFilter, setCategoryFilter] = useState("");
  const [search, setSearch] = useState("");
  const [emailAddress, setEmailAddress] = useState<string | null>(null);
  const [hasMore, setHasMore] = useState(false);
  const [loadingMore, setLoadingMore] = useState(false);
  const [managementOpen, setManagementOpen] = useState(false);
  const [managementLoading, setManagementLoading] = useState(false);
  const [managementError, setManagementError] = useState<string | null>(null);
  const [archivedDocuments, setArchivedDocuments] = useState<FamilyDocument[]>([]);
  const [archiveHasMore, setArchiveHasMore] = useState(false);
  const [documentStats, setDocumentStats] = useState<{ storage_bytes: number; storage_quota_bytes: number } | null>(null);
  const [loading, setLoading] = useState(true);
  const [detailLoading, setDetailLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [working, setWorking] = useState<string | null>(null);
  const [editingDocument, setEditingDocument] = useState(false);
  const [editingAction, setEditingAction] = useState<DocumentSuggestion | "new" | null>(null);
  const [confirmDelete, setConfirmDelete] = useState(false);
  const [documentDraft, setDocumentDraft] = useState({ title: "", category: "other", documentDate: "", notes: "", personIds: [] as string[] });
  const loadGeneration = useRef(0);

  const load = useCallback(async (background = false) => {
    const generation = ++loadGeneration.current;
    if (!background) setLoading(true);
    setError(null);
    try {
      const makePath = (status: InboxFilter, offset = 0) => {
        const query = new URLSearchParams();
        query.set("status", status);
        if (personFilter) query.set("person_id", personFilter);
        if (categoryFilter) query.set("category", categoryFilter);
        if (search.trim()) query.set("search", search.trim());
        query.set("offset", String(offset));
        query.set("limit", String(PAGE_SIZE));
        return `/documents/?${query.toString()}`;
      };
      const group = await api<FamilyDocument[]>(makePath(filter));
      if (generation !== loadGeneration.current) return;
      setDocuments(group);
      setHasMore(group.length === PAGE_SIZE);
    } catch (requestError) {
      if (generation !== loadGeneration.current) return;
      setError(requestError instanceof Error ? requestError.message : "The inbox is unavailable.");
    } finally {
      if (generation === loadGeneration.current) setLoading(false);
    }
  }, [categoryFilter, filter, personFilter, search]);

  async function loadMore() {
    if (loadingMore || !hasMore) return;
    setLoadingMore(true);
    try {
      const query = new URLSearchParams({ status: filter, offset: String(documents.length), limit: String(PAGE_SIZE) });
      if (personFilter) query.set("person_id", personFilter);
      if (categoryFilter) query.set("category", categoryFilter);
      if (search.trim()) query.set("search", search.trim());
      const next = await api<FamilyDocument[]>(`/documents/?${query.toString()}`);
      setDocuments((current) => {
        const unique = new Map([...current, ...next].map((document) => [document.id, document]));
        return [...unique.values()];
      });
      setHasMore(next.length === PAGE_SIZE);
    } catch (requestError) {
      setError(requestError instanceof Error ? requestError.message : "More documents could not be loaded.");
    } finally {
      setLoadingMore(false);
    }
  }

  const lastRevision = useRef(revision);
  useEffect(() => {
    const background = revision !== lastRevision.current;
    lastRevision.current = revision;
    const timeout = window.setTimeout(() => { void load(background); }, search.trim() ? 250 : 0);
    return () => window.clearTimeout(timeout);
  }, [load, revision, search]);

  useEffect(() => {
    const refreshWhenVisible = () => {
      if (document.visibilityState === "visible") void load(true);
    };
    document.addEventListener("visibilitychange", refreshWhenVisible);
    return () => document.removeEventListener("visibilitychange", refreshWhenVisible);
  }, [load]);

  const visible = useMemo(() => {
    return documents.filter((document) => !personFilter || document.people.some((person) => person.person_id === personFilter));
  }, [documents, personFilter]);
  const needsAttention = useMemo(
    () => filter === "inbox" ? visible.filter((document) => !document.ready_for_batch_filing) : [],
    [filter, visible],
  );
  const readyToFile = useMemo(
    () => filter === "inbox" ? visible.filter((document) => document.ready_for_batch_filing) : [],
    [filter, visible],
  );

  function editDraft(document: FamilyDocument) {
    return {
      title: document.title,
      category: document.category,
      documentDate: document.document_date?.slice(0, 10) ?? "",
      notes: document.notes ?? "",
      personIds: document.people.map((person) => person.person_id),
    };
  }

  // Push notifications link straight to a document via ?document=<id>.
  const openedFromLink = useRef(false);
  useEffect(() => {
    if (openedFromLink.current) return;
    const url = new URL(window.location.href);
    const identifier = url.searchParams.get("document");
    if (!identifier) return;
    openedFromLink.current = true;
    url.searchParams.delete("document");
    window.history.replaceState({}, "", url);
    setDetailLoading(true);
    api<FamilyDocument>(`/documents/${identifier}`)
      .then((detail) => {
        setSelected(detail);
        setDocumentDraft(editDraft(detail));
      })
      .catch(() => setError("That document could not be opened."))
      .finally(() => setDetailLoading(false));
  }, []);

  async function openDocument(document: FamilyDocument) {
    setSelected(document);
    setDetailLoading(true);
    setError(null);
    try {
      const detail = await api<FamilyDocument>(`/documents/${document.id}`);
      setSelected(detail);
      setDocumentDraft(editDraft(detail));
    } catch (requestError) {
      setError(requestError instanceof Error ? requestError.message : "The document could not be opened.");
    } finally {
      setDetailLoading(false);
    }
  }

  async function refreshDocument(documentID: string) {
    const detail = await api<FamilyDocument>(`/documents/${documentID}`);
    setSelected(detail);
    setDocumentDraft(editDraft(detail));
    await load();
  }

  async function saveDocument(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (!selected || !documentDraft.title.trim()) return;
    setWorking("document"); setError(null);
    try {
      const updated = await api<FamilyDocument>(`/documents/${selected.id}`, {
        method: "PATCH",
        body: JSON.stringify({
          title: documentDraft.title.trim(),
          category: documentDraft.category,
          document_date: documentDraft.documentDate || null,
          notes: documentDraft.notes.trim() || null,
          person_ids: documentDraft.personIds,
        }),
      });
      setSelected(updated); setEditingDocument(false); notify("Document details saved."); onDataChanged(); await load();
    } catch (requestError) {
      setError(requestError instanceof Error ? requestError.message : "The document could not be updated.");
    } finally { setWorking(null); }
  }

  async function updateStatus(status: "inbox" | "filed" | "archived") {
    if (!selected) return;
    setWorking(status); setError(null);
    try {
      await api(`/documents/${selected.id}`, { method: "PATCH", body: JSON.stringify({ status }) });
      notify(status === "archived" ? "Document archived." : status === "filed" ? "Document filed." : "Document returned to inbox.");
      onDataChanged(); setSelected(null); await load();
    } catch (requestError) { setError(requestError instanceof Error ? requestError.message : "The status could not be changed."); }
    finally { setWorking(null); }
  }

  async function saveAction(draft: ActionDraft) {
    if (!selected) return;
    const payload = actionPayload(draft);
    setWorking("action"); setError(null);
    try {
      let suggestionID: string;
      if (editingAction === "new") {
        const created = await api<DocumentSuggestion>(`/documents/${selected.id}/suggestions`, {
          method: "POST", body: JSON.stringify({ ...payload, confidence: 1 }),
        });
        suggestionID = created.id;
      } else if (editingAction) {
        suggestionID = editingAction.id;
      } else return;
      await api(`/documents/${selected.id}/suggestions/${suggestionID}/accept`, {
        method: "POST", body: JSON.stringify(payload),
      });
      notify(editingAction === "new" ? "Action added and linked to this document." : "Action confirmed and added.");
      setEditingAction(null); onDataChanged(); await refreshDocument(selected.id);
    } catch (requestError) { setError(requestError instanceof Error ? requestError.message : "The action could not be saved."); }
    finally { setWorking(null); }
  }

  async function acceptAllSuggestions() {
    if (!selected) return;
    setWorking("accept-all"); setError(null);
    try {
      const outcome = await api<{ accepted: unknown[]; skipped: Array<{ reason: string }> }>(
        `/documents/${selected.id}/suggestions/accept-all`,
        { method: "POST" },
      );
      const added = outcome.accepted.length;
      notify(
        outcome.skipped.length
          ? `${added} added; ${outcome.skipped.length} need${outcome.skipped.length === 1 ? "s" : ""} review: ${outcome.skipped[0].reason}`
          : `${added} action${added === 1 ? "" : "s"} added to the family plan.`,
      );
      onDataChanged(); await refreshDocument(selected.id);
    } catch (requestError) { setError(requestError instanceof Error ? requestError.message : "The actions could not be added."); }
    finally { setWorking(null); }
  }

  async function dismissSuggestion(suggestionID: string) {
    if (!selected) return;
    setWorking(suggestionID); setError(null);
    try {
      await api(`/documents/${selected.id}/suggestions/${suggestionID}/dismiss`, { method: "POST" });
      notify("Draft dismissed."); onDataChanged(); await refreshDocument(selected.id);
    } catch (requestError) { setError(requestError instanceof Error ? requestError.message : "The draft could not be dismissed."); }
    finally { setWorking(null); }
  }

  async function completeAction(suggestion: DocumentSuggestion) {
    if (!selected || !suggestion.result_id) return;
    setWorking(suggestion.id); setError(null);
    try {
      await api(`/tasks/${suggestion.result_id}/complete`, { method: "PATCH", body: JSON.stringify({}) });
      notify("Linked task completed."); onDataChanged(); await refreshDocument(selected.id);
    } catch (requestError) { setError(requestError instanceof Error ? requestError.message : "The linked task could not be completed."); }
    finally { setWorking(null); }
  }

  async function deleteDocument() {
    if (!selected) return;
    setWorking("delete"); setError(null);
    try {
      await api(`/documents/${selected.id}`, { method: "DELETE" });
      notify("Document deleted."); onDataChanged(); setConfirmDelete(false); setSelected(null); await load();
    } catch (requestError) { setError(requestError instanceof Error ? requestError.message : "The document could not be deleted."); }
    finally { setWorking(null); }
  }

  async function copyEmail() {
    if (!emailAddress) return;
    try {
      await navigator.clipboard.writeText(emailAddress);
      notify("Capture email copied.");
    } catch {
      setError("The capture email could not be copied. Select it and copy it manually.");
    }
  }

  async function openManagement() {
    setManagementOpen(true);
    setManagementLoading(true);
    setManagementError(null);
    try {
      const archiveQuery = new URLSearchParams({ status: "archived", offset: "0", limit: String(PAGE_SIZE) });
      if (personFilter) archiveQuery.set("person_id", personFilter);
      if (categoryFilter) archiveQuery.set("category", categoryFilter);
      if (search.trim()) archiveQuery.set("search", search.trim());
      const [stats, email, archived] = await Promise.all([
        api<{ storage_bytes: number; storage_quota_bytes: number }>("/documents/stats"),
        api<{ configured: boolean; address: string | null }>("/documents/email-address"),
        api<FamilyDocument[]>(`/documents/?${archiveQuery.toString()}`),
      ]);
      setDocumentStats(stats);
      setEmailAddress(email.configured ? email.address : null);
      setArchivedDocuments(archived);
      setArchiveHasMore(archived.length === PAGE_SIZE);
    } catch (requestError) {
      setManagementError(requestError instanceof Error ? requestError.message : "Document management could not be loaded.");
    } finally {
      setManagementLoading(false);
    }
  }

  async function loadMoreArchived() {
    if (managementLoading || !archiveHasMore) return;
    setManagementLoading(true);
    try {
      const query = new URLSearchParams({ status: "archived", offset: String(archivedDocuments.length), limit: String(PAGE_SIZE) });
      if (personFilter) query.set("person_id", personFilter);
      if (categoryFilter) query.set("category", categoryFilter);
      if (search.trim()) query.set("search", search.trim());
      const next = await api<FamilyDocument[]>(`/documents/?${query.toString()}`);
      setArchivedDocuments((current) => [...current, ...next]);
      setArchiveHasMore(next.length === PAGE_SIZE);
    } catch (requestError) {
      setManagementError(requestError instanceof Error ? requestError.message : "More archived documents could not be loaded.");
    } finally {
      setManagementLoading(false);
    }
  }

  async function restoreDocument(document: FamilyDocument) {
    setWorking(`restore-${document.id}`);
    setManagementError(null);
    try {
      await api(`/documents/${document.id}`, { method: "PATCH", body: JSON.stringify({ status: "filed" }) });
      setArchivedDocuments((current) => current.filter((item) => item.id !== document.id));
      notify(`“${document.title}” restored to Filed.`);
      onDataChanged();
      await load(true);
    } catch (requestError) {
      setManagementError(requestError instanceof Error ? requestError.message : "The document could not be restored.");
    } finally {
      setWorking(null);
    }
  }

  async function fileReady(documentIDs = readyToFile.map((document) => document.id)) {
    if (!documentIDs.length) return;
    setWorking("file-ready");
    setError(null);
    try {
      const result = await api<{ filed_ids: string[]; skipped_ids: string[] }>("/documents/file-ready", {
        method: "POST",
        body: JSON.stringify({ document_ids: documentIDs }),
      });
      notify(result.skipped_ids.length
        ? `${result.filed_ids.length} filed; ${result.skipped_ids.length} still need review.`
        : `${result.filed_ids.length} document${result.filed_ids.length === 1 ? "" : "s"} filed.`);
      onDataChanged();
      await load(true);
    } catch (requestError) {
      setError(requestError instanceof Error ? requestError.message : "The documents could not be filed.");
    } finally {
      setWorking(null);
    }
  }

  async function unlinkRecord(kind: "event" | "task", recordID: string) {
    if (!selected) return;
    setWorking(`unlink-${recordID}`);
    setError(null);
    try {
      await api(kind === "event" ? `/calendar/${recordID}` : `/tasks/${recordID}`, {
        method: "PUT",
        body: JSON.stringify({ source_document_id: null }),
      });
      notify(`${kind === "event" ? "Event" : "Task"} unlinked. The document is still saved.`);
      onDataChanged();
      await refreshDocument(selected.id);
    } catch (requestError) {
      setError(requestError instanceof Error ? requestError.message : "The link could not be removed.");
    } finally {
      setWorking(null);
    }
  }

  function previewDocument(document: FamilyDocument) {
    setPreviewReturnDocument(document);
    setSelected(null);
    setViewingDocument(document);
  }

  function closeDocumentPreview() {
    setViewingDocument(null);
    if (previewReturnDocument) setSelected(previewReturnDocument);
    setPreviewReturnDocument(null);
  }

  function openExistingLinker(sourceDocument: FamilyDocument) {
    setLinkingDocument(sourceDocument);
    setSelected(null);
  }

  function closeExistingLinker() {
    const sourceDocument = linkingDocument;
    setLinkingDocument(null);
    if (sourceDocument) setSelected(sourceDocument);
  }

  async function existingRecordLinked(kind: "event" | "task", title: string) {
    const sourceDocument = linkingDocument;
    if (!sourceDocument) return;
    setLinkingDocument(null);
    try {
      const detail = await api<FamilyDocument>(`/documents/${sourceDocument.id}`);
      setSelected(detail);
      setDocumentDraft(editDraft(detail));
    } catch {
      setSelected(sourceDocument);
      setError("The attachment was saved, but this document could not be refreshed yet.");
    }
    notify(`${kind === "event" ? "Event" : "Task"} “${title}” attached.`);
    onDataChanged();
    void load(true);
  }

  function reviewLabel(document: FamilyDocument): string {
    if (document.pending_suggestion_count) {
      return `${document.pending_suggestion_count} action${document.pending_suggestion_count === 1 ? "" : "s"} to review`;
    }
    const uncertain: string[] = [];
    if (document.category_confidence != null && document.category_confidence < 0.8) uncertain.push("filing");
    if (document.document_date_confidence != null && document.document_date_confidence < 0.8) uncertain.push("date");
    return uncertain.length ? `Check ${uncertain.join(" and ")}` : "Check details";
  }

  function documentRow(document: FamilyDocument, archived = false) {
    return <article className="document-queue-row" key={document.id}>
      <button type="button" className="document-row" onClick={() => void openDocument(document)}>
        <span className="document-icon"><FileText aria-hidden="true" size={21} /></span>
        <span className="document-main"><strong>{document.title}</strong><span>{displayDate(document)} · {categoryLabels[document.category] ?? document.category} · {fileSize(document.file_size)}</span><span className="person-line">{document.people.length ? document.people.map((person) => person.person_name).join(", ") : "Whole family"}</span></span>
        {!archived && filter === "inbox" && !document.ready_for_batch_filing ? <span className="action-count">{reviewLabel(document)}</span> : null}
      </button>
      {archived ? <button type="button" className="button button--secondary button--compact" disabled={working === `restore-${document.id}`} onClick={() => void restoreDocument(document)}>{working === `restore-${document.id}` ? "Restoring…" : "Restore"}</button> : null}
    </article>;
  }

  return (
    <div className="standard-page documents-page">
      <header className="page-header"><div><p className="page-eyebrow">Shared family files</p><h1>Documents</h1><p>{filter === "inbox" ? "Only paperwork that still needs a decision stays here." : "Filed letters and records, ready when you need them."}</p></div><div className="row-actions"><button type="button" className="button button--secondary" onClick={() => void openManagement()}><Settings2 aria-hidden="true" size={17} /> Manage</button><button type="button" className="button button--primary" onClick={onAddDocument}><Plus aria-hidden="true" size={18} /> Add document</button></div></header>
      <div className="list-toolbar document-toolbar">
        <Segmented value={filter} onChange={(value) => setFilter(value as InboxFilter)} label="Document view" options={[{ value: "inbox", label: "Needs attention" }, { value: "filed", label: "Filed" }]} />
        <label className="document-category-filter"><span>Category</span><select value={categoryFilter} onChange={(event) => setCategoryFilter(event.target.value)}><option value="">All categories</option>{categories.map((category) => <option value={category} key={category}>{categoryLabels[category]}</option>)}</select></label>
        <label className="search-field"><span className="sr-only">Search documents</span><Search aria-hidden="true" size={17} /><input type="search" value={search} onChange={(event) => setSearch(event.target.value)} placeholder="Search documents" /></label>
      </div>
      <div className="filter-chips" role="group" aria-label="Filter documents by person"><button type="button" className={cn(!personFilter && "is-active")} aria-pressed={!personFilter} onClick={() => setPersonFilter("")}>Everyone</button>{members.map((member) => <button type="button" className={cn(personFilter === member.id && "is-active")} aria-pressed={personFilter === member.id} onClick={() => setPersonFilter(member.id)} key={member.id}>{member.name}</button>)}</div>
      {error ? <ErrorState message={error} retry={load} /> : null}
      {loading ? <SkeletonList rows={6} /> : null}
      {!loading && !error && !visible.length ? <EmptyState title={search || categoryFilter || personFilter ? "No matching documents" : filter === "inbox" ? "Nothing needs your attention" : "No filed documents"} detail={search || categoryFilter || personFilter ? "Change or clear a filter." : filter === "inbox" ? "New scans and forwarded letters will appear here only until they are sorted." : "Documents you file will be kept here."} action={search || categoryFilter || personFilter ? () => { setSearch(""); setCategoryFilter(""); setPersonFilter(""); } : onAddDocument} actionLabel={search || categoryFilter || personFilter ? "Clear filters" : "Add a document"} /> : null}
      {!loading && !error && filter === "inbox" && needsAttention.length ? <section className="document-list document-queue-section" aria-labelledby="documents-review-heading"><div className="section-heading"><div><p className="page-eyebrow">First</p><h2 id="documents-review-heading">Needs your attention</h2></div><span>{needsAttention.length}</span></div>{needsAttention.map((document) => documentRow(document))}</section> : null}
      {!loading && !error && filter === "inbox" && readyToFile.length ? <section className="document-list document-queue-section" aria-labelledby="documents-ready-heading"><div className="section-heading"><div><p className="page-eyebrow">Checked</p><h2 id="documents-ready-heading">Ready to file</h2></div><button type="button" className="button button--primary button--compact" disabled={working === "file-ready"} onClick={() => void fileReady()}><Check aria-hidden="true" size={16} /> {working === "file-ready" ? "Filing…" : `File ${readyToFile.length}`}</button></div>{readyToFile.map((document) => documentRow(document))}</section> : null}
      {!loading && !error && filter === "filed" ? <section className="document-list" aria-label="Filed documents">{visible.map((document) => documentRow(document))}</section> : null}
      {!loading && !error && hasMore ? <div className="load-more-row"><button type="button" className="button button--secondary" disabled={loadingMore} onClick={() => void loadMore()}>{loadingMore ? "Loading…" : "Load more"}</button></div> : null}

      <Modal open={managementOpen} onOpenChange={setManagementOpen} title="Manage documents" description="Archive, storage and email filing live here so the everyday inbox stays quiet." size="wide">
        {managementLoading && !documentStats ? <SkeletonList rows={4} /> : null}
        {managementError ? <ErrorState message={managementError} retry={openManagement} /> : null}
        {documentStats ? <div className="document-management"><section><h2>Storage</h2><div className="storage-summary"><strong>{fileSize(documentStats.storage_bytes)} used</strong><span>of {fileSize(documentStats.storage_quota_bytes)}</span></div><progress value={documentStats.storage_bytes} max={documentStats.storage_quota_bytes} aria-label="Document storage used" /></section>{emailAddress ? <section><h2>Email filing</h2><div className="inbox-email"><Inbox aria-hidden="true" size={18} /><div><span>Forward family email to</span><strong>{emailAddress}</strong><small>Only active family account addresses are accepted.</small></div><button type="button" className="icon-button" aria-label="Copy capture email" onClick={copyEmail}><Clipboard aria-hidden="true" size={18} /></button></div></section> : null}<section><div className="section-heading"><div><h2>Archive</h2><p>Open an old file or restore it to Filed.</p></div></div>{archivedDocuments.length ? <div className="document-list">{archivedDocuments.map((document) => documentRow(document, true))}</div> : <p className="muted-copy">No archived documents.</p>}{archiveHasMore ? <div className="load-more-row"><button type="button" className="button button--secondary" disabled={managementLoading} onClick={() => void loadMoreArchived()}>{managementLoading ? "Loading…" : "Load more archive"}</button></div> : null}</section><p className="muted-copy">Family documents are shared with the household. Use Private Finance for adult-only financial files.</p><a href="/?view=finance&section=setup#private-finance-files">Open Private Finance filing</a></div> : null}
      </Modal>

      <Modal open={Boolean(selected)} onOpenChange={(open) => { if (!open) { setSelected(null); setEditingDocument(false); } }} title={selected?.title ?? "Document"} size="wide">
        {detailLoading ? <SkeletonList rows={5} /> : null}
        {selected && !detailLoading ? <div className="document-detail">
          <div className="document-facts"><span>{selected.document_date ? displayDate(selected) : "No document date"}</span><span>{categoryLabels[selected.category] ?? selected.category}</span><span>{fileSize(selected.file_size)}</span></div>
          {selected.people.length ? <div className="person-chips">{selected.people.map((person) => <span key={person.id}>{person.person_name}</span>)}</div> : null}
          {selected.notes ? <p className="document-notes">{selected.notes}</p> : null}
          <div className="document-command-row"><button type="button" className="button button--secondary" onClick={() => previewDocument(selected)}><FileText aria-hidden="true" size={17} /> Open file</button><button type="button" className="button button--secondary" onClick={() => setEditingDocument((value) => !value)}><Edit3 aria-hidden="true" size={16} /> Edit details</button>{selected.status === "inbox" ? selected.ready_for_batch_filing ? <button type="button" className="button button--primary" disabled={Boolean(working)} onClick={() => void updateStatus("filed")}><Check aria-hidden="true" size={16} /> File</button> : <button type="button" className="button button--primary" onClick={() => setEditingDocument(true)}><Edit3 aria-hidden="true" size={16} /> Review filing</button> : selected.status === "archived" ? <button type="button" className="button button--primary" disabled={Boolean(working)} onClick={() => void updateStatus("filed")}><Check aria-hidden="true" size={16} /> Restore to Filed</button> : <button type="button" className="button button--secondary" disabled={Boolean(working)} onClick={() => void updateStatus("inbox")}><Inbox aria-hidden="true" size={16} /> Needs attention</button>}{selected.status !== "archived" ? <button type="button" className="icon-button" aria-label={`Archive ${selected.title}`} disabled={Boolean(working)} onClick={() => void updateStatus("archived")}><Archive aria-hidden="true" size={17} /></button> : null}<button type="button" className="icon-button icon-button--danger" aria-label={`Delete ${selected.title}`} disabled={Boolean(working)} onClick={() => setConfirmDelete(true)}><Trash2 aria-hidden="true" size={17} /></button></div>
          {editingDocument ? <form className="document-edit-form" onSubmit={saveDocument}><div className="field"><label htmlFor="document-edit-title">Title</label><input id="document-edit-title" value={documentDraft.title} onChange={(event) => setDocumentDraft((draft) => ({ ...draft, title: event.target.value }))} required /></div><div className="field"><label htmlFor="document-edit-category">Category</label><select id="document-edit-category" value={documentDraft.category} onChange={(event) => setDocumentDraft((draft) => ({ ...draft, category: event.target.value }))}>{categories.map((category) => <option value={category} key={category}>{categoryLabels[category]}</option>)}</select>{selected.category_confidence != null ? <small>{selected.category_confidence >= 0.8 ? "Suggested filing — looks reliable. Saving confirms it." : "Suggested filing — please check it before saving."}</small> : null}</div><div className="field"><label htmlFor="document-edit-date">Document date</label><input id="document-edit-date" type="date" value={documentDraft.documentDate} onChange={(event) => setDocumentDraft((draft) => ({ ...draft, documentDate: event.target.value }))} />{selected.document_date_confidence != null ? <small>{selected.document_date_confidence >= 0.8 ? "Suggested date — looks reliable. Saving confirms it." : "This may only be the email date. Check it or leave it blank."}</small> : null}</div><div className="field document-edit-notes"><label htmlFor="document-edit-notes">Notes</label><textarea id="document-edit-notes" rows={3} value={documentDraft.notes} onChange={(event) => setDocumentDraft((draft) => ({ ...draft, notes: event.target.value }))} /></div><fieldset className="people-fieldset"><legend>File for</legend><p className="field-help">This helps you find the file; it does not change who can open it.</p><div className="person-check-grid">{members.map((member) => <label className="check-row" key={member.id}><input type="checkbox" checked={documentDraft.personIds.includes(member.id)} onChange={() => setDocumentDraft((draft) => ({ ...draft, personIds: draft.personIds.includes(member.id) ? draft.personIds.filter((id) => id !== member.id) : [...draft.personIds, member.id] }))} /><span>{member.name}</span></label>)}</div></fieldset><div className="dialog-actions"><button type="button" className="button button--secondary" onClick={() => setEditingDocument(false)}>Cancel</button><button type="submit" className="button button--primary" disabled={working === "document"}>{working === "document" ? "Saving…" : "Save details"}</button></div></form> : null}
          {selected.extracted_text ? <details className="document-text"><summary>Document text</summary><pre>{selected.extracted_text}</pre></details> : null}
          <section className="document-linked-records"><div className="section-heading"><div><p className="page-eyebrow">Attached to</p><h2>Events and tasks</h2></div><button type="button" className="button button--secondary button--compact" onClick={() => openExistingLinker(selected)}><Link2 aria-hidden="true" size={16} /> Attach existing</button></div>{!(selected.linked_events ?? []).length && !(selected.linked_tasks ?? []).length ? <p className="muted-copy">This document is not attached to an event or task yet.</p> : null}{(selected.linked_events ?? []).map((event) => <article className="linked-record-row" key={`event-${event.id}`}><a href={`?view=planner&event=${encodeURIComponent(event.id)}&event_date=${format(parseISO(event.start_time), "yyyy-MM-dd")}`}><Link2 aria-hidden="true" size={17} /><span><strong>{event.title}</strong><small>{format(parseISO(event.start_time), "d MMM yyyy")}</small></span></a><button type="button" className="icon-button" aria-label={`Unlink event ${event.title}`} disabled={working === `unlink-${event.id}`} onClick={() => void unlinkRecord("event", event.id)}><X aria-hidden="true" size={17} /></button></article>)}{(selected.linked_tasks ?? []).map((task) => <article className="linked-record-row" key={`task-${task.id}`}><a href={`?view=tasks&task=${encodeURIComponent(task.id)}${task.completed_at ? "&task_status=completed" : ""}`}><ListTodo aria-hidden="true" size={17} /><span><strong>{task.title}</strong><small>{task.completed_at ? "Completed" : task.due_date ? `Due ${format(parseISO(task.due_date), "d MMM yyyy")}` : "Open task"}</small></span></a><button type="button" className="icon-button" aria-label={`Unlink task ${task.title}`} disabled={working === `unlink-${task.id}`} onClick={() => void unlinkRecord("task", task.id)}><X aria-hidden="true" size={17} /></button></article>)}</section>
          <section className="document-actions">
            <div className="section-heading">
              <div><p className="page-eyebrow">Linked work</p><h2>Actions</h2></div>
              <div className="row-actions">
                {visibleSuggestions(selected).filter((suggestion) => suggestion.status === "pending").length > 1 ? <button type="button" className="button button--primary button--compact" disabled={working === "accept-all"} onClick={() => void acceptAllSuggestions()}><CheckCircle2 aria-hidden="true" size={16} /> {working === "accept-all" ? "Adding…" : `Add all ${visibleSuggestions(selected).filter((suggestion) => suggestion.status === "pending").length}`}</button> : null}
                <button type="button" className="button button--secondary button--compact" onClick={() => setEditingAction("new")}><Plus aria-hidden="true" size={16} /> Create linked event or task</button>
              </div>
            </div>
            {!visibleSuggestions(selected).length ? <p className="muted-copy">No actions attached.</p> : null}
            {visibleSuggestions(selected).map((suggestion) => <article className="document-action-row" key={suggestion.id}><div><strong>{suggestion.title}</strong><span>{suggestion.kind === "event" ? "Calendar event" : "Task"} · {suggestion.assigned_to_name ?? "Whole family"} · {actionStatusLabel(suggestion)}</span></div>{suggestion.status === "pending" ? <div className="row-actions"><button type="button" className="button button--primary button--compact" disabled={working === suggestion.id} onClick={() => setEditingAction(suggestion)}><Edit3 aria-hidden="true" size={15} /> Review</button><button type="button" className="icon-button" aria-label={`Dismiss ${suggestion.title}`} disabled={working === suggestion.id} onClick={() => void dismissSuggestion(suggestion.id)}><X aria-hidden="true" size={17} /></button></div> : suggestion.kind === "task" && suggestion.result_status === "open" ? <button type="button" className="button button--secondary button--compact" disabled={working === suggestion.id} onClick={() => void completeAction(suggestion)}><CheckCircle2 aria-hidden="true" size={16} /> Complete</button> : <span className="status-pill">{actionStatusLabel(suggestion)}</span>}</article>)}
          </section>
        </div> : null}
      </Modal>

      <DocumentViewer document={viewingDocument} onOpenChange={(open) => !open && closeDocumentPreview()} />
      <Modal open={Boolean(linkingDocument)} onOpenChange={(open) => !open && closeExistingLinker()} title="Attach to an existing item" description={linkingDocument ? `Choose where to attach “${linkingDocument.title}”.` : undefined} size="wide">{linkingDocument ? <ExistingRecordLinker sourceDocument={linkingDocument} onCancel={closeExistingLinker} onLinked={existingRecordLinked} /> : null}</Modal>
      <Modal open={Boolean(editingAction)} onOpenChange={(open) => !open && setEditingAction(null)} title={editingAction === "new" ? "Add document action" : "Review document action"} size="wide">{editingAction ? <ActionEditor key={editingAction === "new" ? "new" : editingAction.id} initial={editingAction === "new" ? null : editingAction} members={members} busy={working === "action"} onCancel={() => setEditingAction(null)} onSave={saveAction} /> : null}</Modal>
      <Modal open={confirmDelete} onOpenChange={setConfirmDelete} title="Delete document?"><div className="confirm-delete"><p>{selected ? `Delete “${selected.title}” and its capture drafts? Linked calendar events and tasks will remain.` : ""}</p><div className="dialog-actions"><button type="button" className="button button--secondary" onClick={() => setConfirmDelete(false)}>Cancel</button><button type="button" className="button button--danger" disabled={working === "delete"} onClick={() => void deleteDocument()}>Delete</button></div></div></Modal>
    </div>
  );
}

function ActionEditor({ initial, members, busy, onCancel, onSave }: { initial: DocumentSuggestion | null; members: FamilyMember[]; busy: boolean; onCancel: () => void; onSave: (draft: ActionDraft) => void | Promise<void> }) {
  const [draft, setDraft] = useState<ActionDraft>({ kind: initial?.kind ?? "task", title: initial?.title ?? "", details: initial?.details ?? "", start_time: initial?.start_time ?? null, end_time: initial?.end_time ?? null, due_date: initial?.due_date ?? null, all_day: initial?.all_day ?? true, assigned_to: initial?.assigned_to ?? null });
  const [validation, setValidation] = useState<string | null>(null);
  function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (!draft.title.trim()) { setValidation("Add an action title."); return; }
    if (draft.kind === "event" && !draft.start_time) { setValidation("Add a date for this event."); return; }
    void onSave(draft);
  }
  function setWhen(field: "start_time" | "end_time" | "due_date", value: string) {
    setDraft((current) => ({ ...current, [field]: value ? localISODateTime(new Date(value)) : null }));
  }
  return <form className="form-stack document-action-editor" onSubmit={submit}><Segmented value={draft.kind} onChange={(kind) => setDraft((current) => ({ ...current, kind }))} label="Action type" options={[{ value: "task", label: "Task" }, { value: "event", label: "Calendar event" }]} />{validation ? <div className="form-error" role="alert">{validation}</div> : null}<div className="field"><label htmlFor="action-title">Title</label><input id="action-title" value={draft.title} onChange={(event) => setDraft((current) => ({ ...current, title: event.target.value }))} autoFocus required /></div><div className="field"><label htmlFor="action-person">For</label><select id="action-person" value={draft.assigned_to ?? ""} onChange={(event) => setDraft((current) => ({ ...current, assigned_to: event.target.value || null }))}><option value="">Whole family</option>{members.map((member) => <option value={member.id} key={member.id}>{member.name}</option>)}</select></div>{draft.kind === "event" ? <div className="proposal-fields"><div className="field"><label htmlFor="action-start">Starts</label><input id="action-start" type="datetime-local" value={dateTimeInput(draft.start_time)} onChange={(event) => setWhen("start_time", event.target.value)} required /></div><div className="field"><label htmlFor="action-end">Ends</label><input id="action-end" type="datetime-local" value={dateTimeInput(draft.end_time)} onChange={(event) => setWhen("end_time", event.target.value)} /></div><label className="check-row"><input type="checkbox" checked={draft.all_day} onChange={(event) => setDraft((current) => ({ ...current, all_day: event.target.checked }))} /><span>All day</span></label></div> : <div className="field"><label htmlFor="action-due">Due</label><input id="action-due" type="datetime-local" value={dateTimeInput(draft.due_date)} onChange={(event) => setWhen("due_date", event.target.value)} /></div>}<div className="field"><label htmlFor="action-details">Notes</label><textarea id="action-details" rows={3} value={draft.details ?? ""} onChange={(event) => setDraft((current) => ({ ...current, details: event.target.value }))} /></div><div className="dialog-actions"><button type="button" className="button button--secondary" onClick={onCancel}>Cancel</button><button type="submit" className="button button--primary" disabled={busy}>{initial ? "Confirm action" : "Add and link"}</button></div></form>;
}
