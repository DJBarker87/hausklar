import {
  ArrowLeft,
  BookOpen,
  Check,
  CheckCircle2,
  ChevronRight,
  ExternalLink,
  FileText,
  Link2,
  Pencil,
  Play,
  Plus,
  RotateCcw,
  Trash2,
} from "lucide-react";
import { format, parseISO } from "date-fns";
import { useCallback, useEffect, useMemo, useRef, useState, type FormEvent } from "react";

import { api } from "../api";
import {
  DocumentAttachmentField,
  uploadPendingDocument,
  type PendingDocumentAttachment,
} from "../components/DocumentAttachmentField";
import { DocumentViewer } from "../components/DocumentViewer";
import { EmptyState, ErrorState, Modal, SkeletonList, cn } from "../components/ui";
import type { Child, LinkedDocument } from "../types";

type ReadingLog = {
  id: string;
  child_id: string;
  book_title: string;
  minutes: number;
  date: string;
  notes?: string | null;
  created_at: string;
  updated_at: string;
};

type SpellingAttempt = { word: string; correct: boolean };
type SpellingPractice = {
  id: string;
  practised_at: string;
  attempts: SpellingAttempt[];
  correct_count: number;
  total_count: number;
};
type SpellingMastery = {
  word: string;
  attempts: number;
  correct_attempts: number;
  mastered: boolean;
  needs_practice: boolean;
};
type Spellings = {
  id: string;
  child_id: string;
  word_list: string[];
  test_date: string;
  score?: number | null;
  practice_count: number;
  completed_at?: string | null;
  notes?: string | null;
  link_url?: string | null;
  source_document_id?: string | null;
  source_document?: LinkedDocument | null;
  status: "upcoming" | "due" | "overdue" | "completed";
  practice_sessions: SpellingPractice[];
  mastery: SpellingMastery[];
  created_at: string;
  updated_at: string;
};

type UndoNotice = {
  kind: "reading" | "spellings";
  id: string;
  message: string;
};

type PracticeState = {
  spellingID: string;
  index: number;
  phase: "prompt" | "hidden" | "result";
  attempts: SpellingAttempt[];
};

type CorrectionState = {
  spellingID: string;
  sessionID: string;
  practisedAt: string;
  attempts: SpellingAttempt[];
};

function localDateValue(date = new Date()): string {
  const year = date.getFullYear();
  const month = String(date.getMonth() + 1).padStart(2, "0");
  const day = String(date.getDate()).padStart(2, "0");
  return `${year}-${month}-${day}`;
}

function dateLabel(value: string): string {
  const parsed = parseISO(value);
  return Number.isNaN(parsed.getTime()) ? value : format(parsed, "d MMM yyyy");
}

function dateTimeLabel(value: string): string {
  const parsed = parseISO(value);
  return Number.isNaN(parsed.getTime()) ? value : format(parsed, "d MMM · HH:mm");
}

function dueLabel(item: Spellings): string {
  if (item.status === "overdue") return `Overdue · ${dateLabel(item.test_date)}`;
  if (item.status === "due") return "Due today";
  if (item.status === "completed") return `Test ${dateLabel(item.test_date)}`;
  return `Due ${dateLabel(item.test_date)}`;
}

function parseWords(value: string): string[] {
  const seen = new Set<string>();
  return value
    .split(/[\n,]+/)
    .map((word) => word.trim())
    .filter((word) => {
      const key = word.toLocaleLowerCase();
      if (!word || seen.has(key)) return false;
      seen.add(key);
      return true;
    });
}

function replaceByID<T extends { id: string }>(items: T[], next: T): T[] {
  const exists = items.some((item) => item.id === next.id);
  return exists ? items.map((item) => item.id === next.id ? next : item) : [next, ...items];
}

export function HomeworkView({
  children,
  selectedChild,
  revision,
  initialHomeworkId,
  initialReadingId,
  onDataChanged,
}: {
  children: Child[];
  selectedChild: string;
  revision: number;
  initialHomeworkId?: string | null;
  initialReadingId?: string | null;
  onDataChanged: () => void;
}) {
  const [reading, setReading] = useState<ReadingLog[]>([]);
  const [spellings, setSpellings] = useState<Spellings[]>([]);
  const [loading, setLoading] = useState(true);
  const [loadError, setLoadError] = useState<string | null>(null);
  const [actionError, setActionError] = useState<string | null>(null);
  const [busy, setBusy] = useState<string | null>(null);
  const [readingEditor, setReadingEditor] = useState<ReadingLog | "new" | null>(null);
  const [readingDraft, setReadingDraft] = useState({ book: "", minutes: "10", date: localDateValue(), notes: "" });
  const [spellingEditor, setSpellingEditor] = useState<Spellings | "new" | null>(null);
  const [spellingDraft, setSpellingDraft] = useState({ words: "", testDate: localDateValue(new Date(Date.now() + 7 * 86_400_000)), notes: "", link: "", documentID: null as string | null });
  const [pendingDocument, setPendingDocument] = useState<PendingDocumentAttachment | null>(null);
  const [schoolDetailsOpen, setSchoolDetailsOpen] = useState(false);
  const [detailID, setDetailID] = useState<string | null>(null);
  const [viewingDocument, setViewingDocument] = useState<LinkedDocument | null>(null);
  const [practice, setPractice] = useState<PracticeState | null>(null);
  const [correction, setCorrection] = useState<CorrectionState | null>(null);
  const [completion, setCompletion] = useState<{ spellingID: string; score: string } | null>(null);
  const [undo, setUndo] = useState<UndoNotice | null>(null);
  const lastLoad = useRef<{ child: string; revision: number } | null>(null);
  const consumedFocus = useRef<string | null>(null);

  const childName = children.find((child) => child.id === selectedChild)?.name ?? "Child";

  const load = useCallback(async (background = false) => {
    if (!selectedChild || selectedChild === "all") {
      setReading([]);
      setSpellings([]);
      setLoading(false);
      return;
    }
    if (!background) setLoading(true);
    setLoadError(null);
    try {
      const child = encodeURIComponent(selectedChild);
      const [nextReading, nextSpellings] = await Promise.all([
        api<ReadingLog[]>(`/homework/reading?child_id=${child}&limit=100`),
        api<Spellings[]>(`/homework/spellings?child_id=${child}&limit=100`),
      ]);
      setReading(nextReading);
      setSpellings(nextSpellings);
    } catch (requestError) {
      if (!background) {
        setLoadError(requestError instanceof Error ? requestError.message : "Homework could not be loaded.");
      }
    } finally {
      setLoading(false);
    }
  }, [selectedChild]);

  useEffect(() => {
    const previous = lastLoad.current;
    const background = previous?.child === selectedChild && previous.revision !== revision;
    lastLoad.current = { child: selectedChild, revision };
    void load(background);
  }, [load, revision, selectedChild]);

  useEffect(() => {
    if (!initialHomeworkId || consumedFocus.current === initialHomeworkId) return;
    if (!spellings.some((item) => item.id === initialHomeworkId)) return;
    consumedFocus.current = initialHomeworkId;
    setDetailID(initialHomeworkId);
  }, [initialHomeworkId, spellings]);

  useEffect(() => {
    if (!initialReadingId || consumedFocus.current === initialReadingId) return;
    const item = reading.find((entry) => entry.id === initialReadingId);
    if (!item) return;
    consumedFocus.current = initialReadingId;
    beginReadingEditor(item);
    const url = new URL(window.location.href);
    url.searchParams.delete("reading");
    window.history.replaceState({}, "", url);
  // beginReadingEditor only copies the selected row into local form state.
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [initialReadingId, reading]);

  useEffect(() => {
    if (!undo) return;
    const timeout = window.setTimeout(() => setUndo(null), 8_000);
    return () => window.clearTimeout(timeout);
  }, [undo]);

  const latestReading = reading[0] ?? null;
  const upcoming = spellings.filter((item) => !item.completed_at);
  const completed = spellings.filter((item) => Boolean(item.completed_at));
  const detail = spellings.find((item) => item.id === detailID) ?? null;
  const practiceList = practice ? spellings.find((item) => item.id === practice.spellingID) ?? null : null;
  const recentPractice = useMemo(() => spellings
    .flatMap((item) => item.practice_sessions.map((session) => ({ item, session })))
    .sort((left, right) => right.session.practised_at.localeCompare(left.session.practised_at))
    .slice(0, 6), [spellings]);

  function beginReadingEditor(item?: ReadingLog) {
    setActionError(null);
    if (item) {
      setReadingEditor(item);
      setReadingDraft({ book: item.book_title, minutes: String(item.minutes), date: item.date, notes: item.notes ?? "" });
    } else {
      setReadingEditor("new");
      setReadingDraft({ book: latestReading?.book_title ?? "", minutes: String(latestReading?.minutes ?? 10), date: localDateValue(), notes: "" });
    }
  }

  async function saveReading(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (!readingEditor) return;
    const minutes = Number(readingDraft.minutes);
    if (!Number.isInteger(minutes) || minutes < 1 || minutes > 600) {
      setActionError("Enter reading time between 1 and 600 minutes.");
      return;
    }
    setBusy("reading-save");
    setActionError(null);
    try {
      const payload = {
        book_title: readingDraft.book.trim(),
        minutes,
        date: readingDraft.date,
        notes: readingDraft.notes.trim() || null,
      };
      const result = readingEditor === "new"
        ? await api<ReadingLog>("/homework/reading", { method: "POST", body: JSON.stringify({ child_id: selectedChild, ...payload }) })
        : await api<ReadingLog>(`/homework/reading/${readingEditor.id}`, { method: "PUT", body: JSON.stringify(payload) });
      setReading((items) => replaceByID(items, result).sort((a, b) => b.date.localeCompare(a.date)));
      setReadingEditor(null);
      onDataChanged();
    } catch (requestError) {
      setActionError(requestError instanceof Error ? requestError.message : "That reading session could not be saved.");
    } finally {
      setBusy(null);
    }
  }

  async function quickLogReading() {
    if (!latestReading) return beginReadingEditor();
    setBusy("reading-quick");
    setActionError(null);
    try {
      const result = await api<ReadingLog>("/homework/reading", {
        method: "POST",
        body: JSON.stringify({
          child_id: selectedChild,
          book_title: latestReading.book_title,
          minutes: latestReading.minutes,
          date: localDateValue(),
          notes: null,
        }),
      });
      setReading((items) => [result, ...items]);
      onDataChanged();
    } catch (requestError) {
      setActionError(requestError instanceof Error ? requestError.message : "Reading could not be logged.");
    } finally {
      setBusy(null);
    }
  }

  async function removeReading(item: ReadingLog) {
    setBusy(`reading-delete-${item.id}`);
    setActionError(null);
    try {
      await api<void>(`/homework/reading/${item.id}`, { method: "DELETE" });
      setReading((items) => items.filter((entry) => entry.id !== item.id));
      setReadingEditor(null);
      setUndo({ kind: "reading", id: item.id, message: "Reading session removed" });
      onDataChanged();
    } catch (requestError) {
      setActionError(requestError instanceof Error ? requestError.message : "That reading session could not be removed.");
    } finally {
      setBusy(null);
    }
  }

  function beginSpellingEditor(item?: Spellings) {
    setActionError(null);
    setPendingDocument(null);
    if (item) {
      setSpellingEditor(item);
      setSpellingDraft({
        words: item.word_list.join("\n"),
        testDate: item.test_date,
        notes: item.notes ?? "",
        link: item.link_url ?? "",
        documentID: item.source_document_id ?? null,
      });
      setSchoolDetailsOpen(Boolean(item.notes || item.link_url || item.source_document_id));
    } else {
      setSpellingEditor("new");
      setSpellingDraft({ words: "", testDate: localDateValue(new Date(Date.now() + 7 * 86_400_000)), notes: "", link: "", documentID: null });
      setSchoolDetailsOpen(false);
    }
  }

  async function saveSpellings(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (!spellingEditor) return;
    const words = parseWords(spellingDraft.words);
    if (!words.length) {
      setActionError("Paste at least one spelling word.");
      return;
    }
    setBusy("spellings-save");
    setActionError(null);
    try {
      const uploaded = pendingDocument ? await uploadPendingDocument(pendingDocument) : null;
      const payload = {
        word_list: words,
        test_date: spellingDraft.testDate,
        notes: spellingDraft.notes.trim() || null,
        link_url: spellingDraft.link.trim() || null,
        source_document_id: uploaded?.id ?? spellingDraft.documentID,
      };
      const result = spellingEditor === "new"
        ? await api<Spellings>("/homework/spellings", { method: "POST", body: JSON.stringify({ child_id: selectedChild, ...payload }) })
        : await api<Spellings>(`/homework/spellings/${spellingEditor.id}`, { method: "PUT", body: JSON.stringify(payload) });
      setSpellings((items) => replaceByID(items, result));
      setSpellingEditor(null);
      setPendingDocument(null);
      setDetailID(result.id);
      onDataChanged();
    } catch (requestError) {
      setActionError(requestError instanceof Error ? requestError.message : "That spelling list could not be saved.");
    } finally {
      setBusy(null);
    }
  }

  function beginPractice(item: Spellings) {
    setDetailID(null);
    setActionError(null);
    setPractice({ spellingID: item.id, index: 0, phase: "prompt", attempts: [] });
  }

  async function answerPractice(correct: boolean) {
    if (!practice || !practiceList) return;
    const word = practiceList.word_list[practice.index];
    const attempts = [...practice.attempts.filter((attempt) => attempt.word !== word), { word, correct }];
    if (practice.index < practiceList.word_list.length - 1) {
      setPractice({ ...practice, index: practice.index + 1, phase: "prompt", attempts });
      return;
    }
    setBusy("practice-save");
    setActionError(null);
    try {
      const ordered = practiceList.word_list.map((practiceWord) => attempts.find((attempt) => attempt.word === practiceWord)!);
      const result = await api<Spellings>(`/homework/spellings/${practiceList.id}/practice`, {
        method: "POST",
        body: JSON.stringify({ attempts: ordered }),
      });
      setSpellings((items) => replaceByID(items, result));
      setPractice(null);
      setDetailID(result.id);
      onDataChanged();
    } catch (requestError) {
      setActionError(requestError instanceof Error ? requestError.message : "This practice could not be saved.");
    } finally {
      setBusy(null);
    }
  }

  function beginCorrection(item: Spellings, session: SpellingPractice) {
    setDetailID(null);
    setActionError(null);
    setCorrection({ spellingID: item.id, sessionID: session.id, practisedAt: session.practised_at, attempts: session.attempts.map((attempt) => ({ ...attempt })) });
  }

  async function saveCorrection(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (!correction) return;
    setBusy("correction-save");
    setActionError(null);
    try {
      const result = await api<Spellings>(`/homework/spellings/${correction.spellingID}/practice/${correction.sessionID}`, {
        method: "PUT",
        body: JSON.stringify({ attempts: correction.attempts, practised_at: correction.practisedAt }),
      });
      setSpellings((items) => replaceByID(items, result));
      setCorrection(null);
      setDetailID(result.id);
      onDataChanged();
    } catch (requestError) {
      setActionError(requestError instanceof Error ? requestError.message : "That correction could not be saved.");
    } finally {
      setBusy(null);
    }
  }

  async function completeSpellings(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (!completion) return;
    const item = spellings.find((entry) => entry.id === completion.spellingID);
    if (!item) return;
    const score = completion.score.trim() ? Number(completion.score) : null;
    if (score != null && (!Number.isInteger(score) || score < 0 || score > item.word_list.length)) {
      setActionError(`Enter a score from 0 to ${item.word_list.length}, or leave it blank.`);
      return;
    }
    setBusy("completion-save");
    setActionError(null);
    try {
      const result = await api<Spellings>(`/homework/spellings/${item.id}/complete`, {
        method: "POST",
        body: JSON.stringify({ score }),
      });
      setSpellings((items) => replaceByID(items, result));
      setCompletion(null);
      setDetailID(result.id);
      onDataChanged();
    } catch (requestError) {
      setActionError(requestError instanceof Error ? requestError.message : "The test result could not be saved.");
    } finally {
      setBusy(null);
    }
  }

  async function reopenSpellings(item: Spellings) {
    setBusy(`reopen-${item.id}`);
    setActionError(null);
    try {
      const result = await api<Spellings>(`/homework/spellings/${item.id}/reopen`, { method: "POST" });
      setSpellings((items) => replaceByID(items, result));
      onDataChanged();
    } catch (requestError) {
      setActionError(requestError instanceof Error ? requestError.message : "That completion could not be undone.");
    } finally {
      setBusy(null);
    }
  }

  async function removeSpellings(item: Spellings) {
    setBusy(`spellings-delete-${item.id}`);
    setActionError(null);
    try {
      await api<void>(`/homework/spellings/${item.id}`, { method: "DELETE" });
      setSpellings((items) => items.filter((entry) => entry.id !== item.id));
      setDetailID(null);
      setUndo({ kind: "spellings", id: item.id, message: "Spelling list removed" });
      onDataChanged();
    } catch (requestError) {
      setActionError(requestError instanceof Error ? requestError.message : "That spelling list could not be removed.");
    } finally {
      setBusy(null);
    }
  }

  async function undoRemoval() {
    if (!undo) return;
    setBusy("undo-homework");
    setActionError(null);
    try {
      if (undo.kind === "reading") {
        const restored = await api<ReadingLog>(`/homework/reading/${undo.id}/restore`, { method: "POST" });
        setReading((items) => replaceByID(items, restored).sort((a, b) => b.date.localeCompare(a.date)));
      } else {
        const restored = await api<Spellings>(`/homework/spellings/${undo.id}/restore`, { method: "POST" });
        setSpellings((items) => replaceByID(items, restored));
      }
      setUndo(null);
      onDataChanged();
    } catch (requestError) {
      setActionError(requestError instanceof Error ? requestError.message : "That item could not be restored.");
    } finally {
      setBusy(null);
    }
  }

  if (loading) return <SkeletonList rows={6} />;
  if (loadError) return <ErrorState message={loadError} retry={() => void load()} />;

  return (
    <div className="family-record-section homework-panel">
      <div className="section-heading family-section-title">
        <div><p className="page-eyebrow">School</p><h2>Reading and spellings</h2><p>What {childName} needs next, with the detail ready when you need it.</p></div>
        <div className="section-actions">
          <button type="button" className="button button--secondary button--compact" onClick={() => beginReadingEditor()}><BookOpen aria-hidden="true" size={16} /> Log reading</button>
          <button type="button" className="button button--primary button--compact" onClick={() => beginSpellingEditor()}><Plus aria-hidden="true" size={16} /> Add spellings</button>
        </div>
      </div>

      {actionError && !readingEditor && !spellingEditor && !practice && !correction && !completion ? <div className="homework-inline-error" role="alert">{actionError}</div> : null}

      <section className="homework-reading-card" aria-labelledby="read-now-heading">
        <div className="homework-section-icon"><BookOpen aria-hidden="true" size={21} /></div>
        <div>
          <span className="homework-kicker" id="read-now-heading">Read now</span>
          {latestReading ? <><strong>{latestReading.book_title}</strong><small>Usual session · {latestReading.minutes} minutes</small></> : <><strong>What are you reading?</strong><small>Save the current book once, then the usual session is one tap.</small></>}
        </div>
        <button type="button" className="button button--primary" disabled={busy === "reading-quick"} aria-busy={busy === "reading-quick"} onClick={() => void quickLogReading()}>
          {busy === "reading-quick" ? "Logging…" : latestReading ? `Log ${latestReading.minutes} min` : "Log first reading"}
        </button>
        {latestReading ? <button type="button" className="homework-text-action" onClick={() => beginReadingEditor()}>Change book, time or note</button> : null}
      </section>

      <section className="homework-section" aria-labelledby="homework-due-heading">
        <div className="homework-section-heading"><div><span className="homework-kicker">School work</span><h3 id="homework-due-heading">Due next</h3></div>{upcoming.length ? <span>{upcoming.length} {upcoming.length === 1 ? "list" : "lists"}</span> : null}</div>
        {upcoming.length ? <div className="homework-due-list">{upcoming.map((item) => {
          const needsPractice = item.practice_count > 0 ? item.mastery.filter((word) => word.needs_practice).map((word) => word.word) : [];
          return <article className={cn("homework-due-card", item.status === "overdue" && "is-overdue", item.status === "due" && "is-due")} key={item.id}>
            <button type="button" className="homework-card-main" onClick={() => setDetailID(item.id)}>
              <span className="homework-status">{dueLabel(item)}</span>
              <strong>{item.word_list.length} spelling words</strong>
              <small>{item.practice_count ? `Practised ${item.practice_count} ${item.practice_count === 1 ? "time" : "times"}` : "Not practised yet"}</small>
              {needsPractice.length ? <em>Next: {needsPractice.slice(0, 3).join(", ")}{needsPractice.length > 3 ? ` +${needsPractice.length - 3}` : ""}</em> : null}
              <ChevronRight aria-hidden="true" size={18} />
            </button>
            <button type="button" className="button button--primary" onClick={() => beginPractice(item)}><Play aria-hidden="true" size={15} /> Start practice</button>
          </article>;
        })}</div> : <EmptyState title="No spelling work due" detail="Paste the next teacher list when it arrives." action={() => beginSpellingEditor()} actionLabel="Add spelling list" />}
      </section>

      <section className="homework-section" aria-labelledby="homework-history-heading">
        <div className="homework-section-heading"><div><span className="homework-kicker">Recent</span><h3 id="homework-history-heading">What we practised</h3></div></div>
        {!reading.length && !recentPractice.length ? <EmptyState title="Nothing practised yet" detail="Reading and spelling practice will appear here." /> : <div className="homework-history-grid">
          <div className="homework-history-list">
            {reading.slice(0, 6).map((item) => <button type="button" className="homework-history-row" onClick={() => beginReadingEditor(item)} key={item.id}>
              <BookOpen aria-hidden="true" size={18} /><span><strong>{item.book_title}</strong><small>{item.minutes} min · {dateLabel(item.date)}</small></span><Pencil aria-hidden="true" size={15} />
            </button>)}
          </div>
          <div className="homework-history-list">
            {recentPractice.map(({ item, session }) => <button type="button" className="homework-history-row" onClick={() => setDetailID(item.id)} key={session.id}>
              <CheckCircle2 aria-hidden="true" size={18} /><span><strong>Spelling practice</strong><small>{session.correct_count} of {session.total_count} · {dateTimeLabel(session.practised_at)}</small></span><ChevronRight aria-hidden="true" size={15} />
            </button>)}
          </div>
        </div>}
      </section>

      {completed.length ? <section className="homework-section" aria-labelledby="homework-completed-heading">
        <div className="homework-section-heading"><div><span className="homework-kicker">History</span><h3 id="homework-completed-heading">Completed tests</h3></div></div>
        <div className="homework-completed-list">{completed.slice(0, 8).map((item) => <button type="button" className="homework-history-row" onClick={() => setDetailID(item.id)} key={item.id}>
          <CheckCircle2 aria-hidden="true" size={18} /><span><strong>{dueLabel(item)}</strong><small>{item.score == null ? "Marked done" : `Score ${item.score} of ${item.word_list.length}`}</small></span><ChevronRight aria-hidden="true" size={15} />
        </button>)}</div>
      </section> : null}

      {undo ? <div className="homework-undo" role="status"><span>{undo.message}</span><button type="button" disabled={busy === "undo-homework"} onClick={() => void undoRemoval()}><RotateCcw aria-hidden="true" size={16} /> {busy === "undo-homework" ? "Restoring…" : "Undo"}</button></div> : null}

      <Modal open={Boolean(readingEditor)} onOpenChange={(open) => { if (!open) { setReadingEditor(null); setActionError(null); } }} title={readingEditor === "new" ? "Log reading" : "Correct reading"} description={`${childName}'s reading session`}>
        <form className="form-stack" onSubmit={saveReading}>
          <div className="field"><label htmlFor="homework-reading-book">Book title</label><input id="homework-reading-book" value={readingDraft.book} maxLength={300} autoComplete="off" onChange={(event) => setReadingDraft((draft) => ({ ...draft, book: event.target.value }))} required /></div>
          <div className="form-grid">
            <div className="field"><label htmlFor="homework-reading-minutes">Minutes</label><input id="homework-reading-minutes" type="text" inputMode="numeric" pattern="[0-9]*" value={readingDraft.minutes} onChange={(event) => setReadingDraft((draft) => ({ ...draft, minutes: event.target.value }))} required /></div>
            <div className="field"><label htmlFor="homework-reading-date">Date</label><input id="homework-reading-date" type="date" value={readingDraft.date} onChange={(event) => setReadingDraft((draft) => ({ ...draft, date: event.target.value }))} required /></div>
          </div>
          <div className="field"><label htmlFor="homework-reading-notes">How did it go? (optional)</label><textarea id="homework-reading-notes" rows={3} maxLength={2_000} value={readingDraft.notes} onChange={(event) => setReadingDraft((draft) => ({ ...draft, notes: event.target.value }))} /></div>
          {actionError ? <div className="form-error" role="alert">{actionError}</div> : null}
          <div className="dialog-actions">
            {readingEditor && readingEditor !== "new" ? <button type="button" className="button button--danger" disabled={Boolean(busy)} onClick={() => void removeReading(readingEditor)}><Trash2 aria-hidden="true" size={16} /> Remove</button> : null}
            <button type="submit" className="button button--primary" disabled={busy === "reading-save"} aria-busy={busy === "reading-save"}>{busy === "reading-save" ? "Saving…" : "Save reading"}</button>
          </div>
        </form>
      </Modal>

      <Modal open={Boolean(spellingEditor)} onOpenChange={(open) => { if (!open) { setSpellingEditor(null); setPendingDocument(null); setActionError(null); } }} title={spellingEditor === "new" ? "Add spellings" : "Correct spellings"} description="Paste the teacher list, then review it before saving" size="wide">
        <form className="form-stack" onSubmit={saveSpellings}>
          <div className="field"><label htmlFor="homework-spelling-words">Words</label><textarea id="homework-spelling-words" rows={8} maxLength={10_000} value={spellingDraft.words} onChange={(event) => setSpellingDraft((draft) => ({ ...draft, words: event.target.value }))} placeholder={"because\nbeautiful\ndifferent"} required /><span className="field-help">One per line or comma-separated · {parseWords(spellingDraft.words).length} words</span></div>
          <div className="field"><label htmlFor="homework-spelling-date">Test date</label><input id="homework-spelling-date" type="date" value={spellingDraft.testDate} onChange={(event) => setSpellingDraft((draft) => ({ ...draft, testDate: event.target.value }))} required /></div>
          <details className="homework-school-details" open={schoolDetailsOpen} onToggle={(event) => setSchoolDetailsOpen(event.currentTarget.open)}>
            <summary>More school details</summary>
            <div className="homework-school-fields">
              <div className="field"><label htmlFor="homework-spelling-note">Teacher note (optional)</label><textarea id="homework-spelling-note" rows={3} maxLength={2_000} value={spellingDraft.notes} onChange={(event) => setSpellingDraft((draft) => ({ ...draft, notes: event.target.value }))} /></div>
              <div className="field"><label htmlFor="homework-spelling-link">School link (optional)</label><input id="homework-spelling-link" type="url" inputMode="url" autoComplete="url" spellCheck={false} placeholder="https://…" value={spellingDraft.link} onChange={(event) => setSpellingDraft((draft) => ({ ...draft, link: event.target.value }))} /></div>
              <DocumentAttachmentField
                active={schoolDetailsOpen}
                idPrefix="homework-spellings"
                currentDocument={spellingEditor && spellingEditor !== "new" ? spellingEditor.source_document : null}
                selectedDocumentID={spellingDraft.documentID}
                pending={pendingDocument}
                disabled={busy === "spellings-save"}
                onSelect={(documentID) => setSpellingDraft((draft) => ({ ...draft, documentID }))}
                onPending={setPendingDocument}
              />
            </div>
          </details>
          {actionError ? <div className="form-error" role="alert">{actionError}</div> : null}
          <div className="dialog-actions"><button type="submit" className="button button--primary" disabled={busy === "spellings-save"} aria-busy={busy === "spellings-save"}>{busy === "spellings-save" ? "Saving…" : "Save spelling list"}</button></div>
        </form>
      </Modal>

      <Modal open={Boolean(detail)} onOpenChange={(open) => { if (!open) { setDetailID(null); setActionError(null); } }} title="Spellings" description={detail ? `${childName} · ${dueLabel(detail)}` : undefined} size="wide">
        {detail ? <div className="homework-detail">
          <div className="homework-detail-summary"><span><strong>{detail.word_list.length}</strong><small>Words</small></span><span><strong>{detail.practice_count}</strong><small>Practices</small></span><span><strong>{detail.score == null ? "—" : `${detail.score}/${detail.word_list.length}`}</strong><small>Result</small></span></div>
          <section><h3>Words</h3><div className="homework-word-list">{detail.word_list.map((word) => {
            const mastery = detail.mastery.find((entry) => entry.word === word);
            return <div className={cn("homework-word", mastery?.mastered && "is-mastered")} key={word}><span>{word}</span>{mastery?.mastered ? <small><Check aria-hidden="true" size={14} /> Mastered</small> : mastery?.attempts ? <small>Keep practising</small> : null}</div>;
          })}</div></section>
          {detail.notes || detail.link_url || detail.source_document ? <section><h3>School details</h3>{detail.notes ? <p className="homework-note">{detail.notes}</p> : null}<div className="homework-resource-list">{detail.link_url ? <a className="button button--secondary" href={detail.link_url} target="_blank" rel="noreferrer"><Link2 aria-hidden="true" size={16} /> Open school link <ExternalLink aria-hidden="true" size={14} /></a> : null}{detail.source_document ? <button type="button" className="button button--secondary" onClick={() => setViewingDocument(detail.source_document ?? null)}><FileText aria-hidden="true" size={16} /> {detail.source_document.title}</button> : null}</div></section> : null}
          {detail.practice_sessions.length ? <section><h3>Practice history</h3><div className="homework-session-list">{detail.practice_sessions.map((session) => <div className="homework-session-row" key={session.id}><span><strong>{session.correct_count} of {session.total_count} correct</strong><small>{dateTimeLabel(session.practised_at)}</small></span><button type="button" className="button button--secondary button--compact" onClick={() => beginCorrection(detail, session)}>Correct</button></div>)}</div></section> : null}
          {actionError ? <div className="form-error" role="alert">{actionError}</div> : null}
          <div className="homework-detail-actions">
            {detail.completed_at ? <><button type="button" className="button button--secondary" onClick={() => setCompletion({ spellingID: detail.id, score: detail.score == null ? "" : String(detail.score) })}><Pencil aria-hidden="true" size={16} /> Correct result</button><button type="button" className="button button--secondary" disabled={busy === `reopen-${detail.id}`} onClick={() => void reopenSpellings(detail)}><RotateCcw aria-hidden="true" size={16} /> Reopen list</button></> : <><button type="button" className="button button--primary" onClick={() => beginPractice(detail)}><Play aria-hidden="true" size={16} /> Start practice</button><button type="button" className="button button--secondary" onClick={() => { setDetailID(null); setCompletion({ spellingID: detail.id, score: "" }); }}>Mark test done</button></>}
            <button type="button" className="button button--secondary" onClick={() => { setDetailID(null); beginSpellingEditor(detail); }}><Pencil aria-hidden="true" size={16} /> Correct details</button>
            <button type="button" className="button button--danger" disabled={busy === `spellings-delete-${detail.id}`} onClick={() => void removeSpellings(detail)}><Trash2 aria-hidden="true" size={16} /> Remove list</button>
          </div>
        </div> : null}
      </Modal>

      <Modal open={Boolean(practice && practiceList)} onOpenChange={(open) => { if (!open && busy !== "practice-save") { setPractice(null); setActionError(null); } }} title="Spelling practice" description={practiceList ? `${childName} · word ${(practice?.index ?? 0) + 1} of ${practiceList.word_list.length}` : undefined}>
        {practice && practiceList ? <div className="homework-practice" aria-busy={busy === "practice-save"}>
          <progress max={practiceList.word_list.length} value={practice.index + 1} aria-label={`Word ${practice.index + 1} of ${practiceList.word_list.length}`} />
          <div className="homework-practice-card">
            {practice.phase === "prompt" ? <><span>Say this word aloud</span><strong>{practiceList.word_list[practice.index]}</strong><button type="button" className="button button--primary button--large" onClick={() => setPractice({ ...practice, phase: "hidden" })}>Hide word and ask</button></> : null}
            {practice.phase === "hidden" ? <><span className="homework-hidden-word">Word hidden</span><p>Ask {childName} to spell it aloud or write it down.</p><button type="button" className="button button--primary button--large" onClick={() => setPractice({ ...practice, phase: "result" })}>Reveal spelling</button></> : null}
            {practice.phase === "result" ? <><span>The spelling is</span><strong>{practiceList.word_list[practice.index]}</strong><div className="homework-answer-actions"><button type="button" className="button button--secondary" disabled={busy === "practice-save"} onClick={() => void answerPractice(false)}><RotateCcw aria-hidden="true" size={16} /> Try again</button><button type="button" className="button button--primary" disabled={busy === "practice-save"} onClick={() => void answerPractice(true)}><Check aria-hidden="true" size={16} /> Got it</button></div></> : null}
          </div>
          {practice.index > 0 && busy !== "practice-save" ? <button type="button" className="homework-text-action" onClick={() => setPractice({ ...practice, index: practice.index - 1, phase: "prompt" })}><ArrowLeft aria-hidden="true" size={15} /> Previous word</button> : null}
          {actionError ? <div className="form-error" role="alert">{actionError}</div> : null}
        </div> : null}
      </Modal>

      <Modal open={Boolean(correction)} onOpenChange={(open) => { if (!open) { setCorrection(null); setActionError(null); } }} title="Correct practice" description={correction ? dateTimeLabel(correction.practisedAt) : undefined}>
        {correction ? <form className="form-stack" onSubmit={saveCorrection}><fieldset className="homework-correction-list"><legend>Which words were correct?</legend>{correction.attempts.map((attempt, index) => <label key={attempt.word}><input type="checkbox" checked={attempt.correct} onChange={(event) => setCorrection((current) => current ? { ...current, attempts: current.attempts.map((entry, entryIndex) => entryIndex === index ? { ...entry, correct: event.target.checked } : entry) } : null)} /><span>{attempt.word}</span></label>)}</fieldset>{actionError ? <div className="form-error" role="alert">{actionError}</div> : null}<div className="dialog-actions"><button type="submit" className="button button--primary" disabled={busy === "correction-save"}>{busy === "correction-save" ? "Saving…" : "Save correction"}</button></div></form> : null}
      </Modal>

      <Modal open={Boolean(completion)} onOpenChange={(open) => { if (!open) { setCompletion(null); setActionError(null); } }} title="Mark test done" description={completion ? `Optional score out of ${spellings.find((item) => item.id === completion.spellingID)?.word_list.length ?? 0}` : undefined}>
        {completion ? <form className="form-stack" onSubmit={completeSpellings}><div className="field"><label htmlFor="homework-test-score">Score (optional)</label><input id="homework-test-score" type="text" inputMode="numeric" pattern="[0-9]*" value={completion.score} onChange={(event) => setCompletion({ ...completion, score: event.target.value })} /><span className="field-help">Leave blank if you only need to mark it done.</span></div>{actionError ? <div className="form-error" role="alert">{actionError}</div> : null}<div className="dialog-actions"><button type="submit" className="button button--primary" disabled={busy === "completion-save"}>{busy === "completion-save" ? "Saving…" : "Save result"}</button></div></form> : null}
      </Modal>

      <DocumentViewer document={viewingDocument} onOpenChange={(open) => { if (!open) setViewingDocument(null); }} />
    </div>
  );
}
