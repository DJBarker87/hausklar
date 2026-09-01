import { Camera, FileText, LoaderCircle, Mic, Plus, Sparkles, Square, Trash2 } from "lucide-react";
import { useEffect, useRef, useState, type FormEvent } from "react";

import { api, localISODateTime } from "../api";
import type { CaptureProposal, CaptureResponse, FamilyMember } from "../types";
import { AIConsentPrompt, useAIConsent } from "./AIConsent";
import {
  DOCUMENT_FILE_ACCEPT,
  DOCUMENT_IMAGE_ACCEPT,
  supportedDocumentFile,
} from "./DocumentAttachmentField";
import { Modal, Segmented } from "./ui";

type CaptureMode = "plan" | "document";
type ProposalDuration = "none" | "15" | "30" | "60" | "custom";
type EditableProposal = CaptureProposal & { included: boolean; saved: boolean };
type ProposalOperation = {
  id: string;
  fingerprint: string;
  timestamp: string;
  kind: CaptureProposal["kind"];
};

type CalendarCreatePayload = {
  title: string;
  description: string | null;
  start_time: string;
  end_time: string | null;
  all_day: boolean;
  assigned_to: string | null;
  family_member_ids: string[] | null;
};

type TaskCreatePayload = {
  title: string;
  description: string | null;
  due_date: string | null;
  assigned_to: string | null;
  category: "other";
  priority: 2;
};

type SpeechResultEvent = {
  results: {
    length: number;
    [index: number]: { [index: number]: { transcript: string } };
  };
};

type BrowserSpeechRecognition = {
  continuous: boolean;
  interimResults: boolean;
  lang: string;
  onresult: ((event: SpeechResultEvent) => void) | null;
  onerror: ((event: { error: string }) => void) | null;
  onend: (() => void) | null;
  start: () => void;
  stop: () => void;
  abort: () => void;
};

type SpeechRecognitionWindow = Window & {
  SpeechRecognition?: new () => BrowserSpeechRecognition;
  webkitSpeechRecognition?: new () => BrowserSpeechRecognition;
};

function speechRecognitionConstructor() {
  if (typeof window === "undefined") return null;
  const browser = window as SpeechRecognitionWindow;
  return browser.SpeechRecognition ?? browser.webkitSpeechRecognition ?? null;
}

function dateTimeInput(value?: string | null): string {
  if (!value) return "";
  if (value.length === 10) return `${value}T09:00`;
  const parsed = new Date(value);
  if (Number.isNaN(parsed.getTime())) return "";
  const offset = parsed.getTimezoneOffset() * 60_000;
  return new Date(parsed.getTime() - offset).toISOString().slice(0, 16);
}

function dateInput(value?: string | null): string {
  return dateTimeInput(value).slice(0, 10);
}

function apiDateTime(value: string): string | null {
  if (!value) return null;
  const parsed = new Date(value);
  return Number.isNaN(parsed.getTime()) ? null : localISODateTime(parsed);
}

function nextWholeHour(): string {
  const date = new Date();
  date.setMinutes(0, 0, 0);
  date.setHours(date.getHours() + 1);
  return localISODateTime(date);
}

function defaultEndTime(startTime?: string | null): string {
  const start = startTime ? new Date(startTime) : new Date();
  const safeStart = Number.isNaN(start.getTime()) ? new Date() : start;
  return localISODateTime(new Date(safeStart.getTime() + 15 * 60 * 1_000));
}

function manualProposal(kind: CaptureProposal["kind"]): EditableProposal {
  const startTime = kind === "event" ? nextWholeHour() : null;
  return {
    id: `manual-${crypto.randomUUID()}`,
    kind,
    title: "",
    details: null,
    start_time: startTime,
    end_time: startTime ? defaultEndTime(startTime) : null,
    due_date: null,
    all_day: kind === "task",
    assigned_to: null,
    assigned_to_name: null,
    confidence: 1,
    included: true,
    saved: false,
  };
}

function proposalDuration(proposal: CaptureProposal): ProposalDuration {
  if (!proposal.end_time || !proposal.start_time) return "none";
  const minutes = Math.round((new Date(proposal.end_time).getTime() - new Date(proposal.start_time).getTime()) / 60_000);
  if (minutes === 15 || minutes === 30 || minutes === 60) return String(minutes) as ProposalDuration;
  return "custom";
}

export function CaptureDialog({
  open,
  initialMode,
  initialText = "",
  members,
  onOpenChange,
  onCreated,
  notify,
  onContinueInBismarck,
}: {
  open: boolean;
  initialMode: CaptureMode;
  initialText?: string;
  members: FamilyMember[];
  onOpenChange: (open: boolean) => void;
  onCreated: () => void;
  notify: (message: string) => void;
  onContinueInBismarck?: (text: string) => void;
}) {
  const [mode, setMode] = useState<CaptureMode>(initialMode);
  const [text, setText] = useState("");
  const [isListening, setIsListening] = useState(false);
  const [dictationLanguage, setDictationLanguage] = useState<"en-GB" | "de-DE">(
    () => typeof navigator !== "undefined" && navigator.language.toLowerCase().startsWith("de") ? "de-DE" : "en-GB",
  );
  const [useBismarck, setUseBismarck] = useState(false);
  const [showAIConsent, setShowAIConsent] = useState(false);
  const [reviewing, setReviewing] = useState(false);
  const [proposals, setProposals] = useState<EditableProposal[]>([]);
  const [warning, setWarning] = useState<string | null>(null);
  const [file, setFile] = useState<File | null>(null);
  const [documentSource, setDocumentSource] = useState<"scan" | "photo" | "file">("file");
  const [documentTitle, setDocumentTitle] = useState("");
  const [category, setCategory] = useState("other");
  const [notes, setNotes] = useState("");
  const [extractedText, setExtractedText] = useState("");
  const [selectedPeople, setSelectedPeople] = useState<string[]>([]);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const proposalOperations = useRef<Record<string, ProposalOperation>>({});
  const recognitionRef = useRef<BrowserSpeechRecognition | null>(null);
  const dictationPrefixRef = useRef("");
  const documentUploadOperation = useRef<{ id: string; fingerprint: string | null } | null>(null);
  const scanFileInput = useRef<HTMLInputElement>(null);
  const uploadFileInput = useRef<HTMLInputElement>(null);
  const aiConsent = useAIConsent(open && mode === "document");
  const speechSupported = Boolean(speechRecognitionConstructor());

  useEffect(() => () => recognitionRef.current?.abort(), []);

  useEffect(() => {
    if (open) {
      setMode(initialMode);
      if (initialText) setText(initialText);
    }
  }, [open, initialMode, initialText]);

  useEffect(() => {
    if (open && mode === "plan") return;
    recognitionRef.current?.abort();
    recognitionRef.current = null;
    setIsListening(false);
  }, [mode, open]);

  function stopDictation() {
    recognitionRef.current?.stop();
    recognitionRef.current = null;
    setIsListening(false);
  }

  function toggleDictation() {
    if (isListening) {
      stopDictation();
      return;
    }
    const Recognition = speechRecognitionConstructor();
    if (!Recognition) {
      setError("Voice dictation is not available in this browser.");
      return;
    }
    setError(null);
    const recognition = new Recognition();
    recognition.lang = dictationLanguage;
    recognition.continuous = true;
    recognition.interimResults = true;
    dictationPrefixRef.current = text.trimEnd();
    recognition.onresult = (event) => {
      let transcript = "";
      for (let index = 0; index < event.results.length; index += 1) {
        transcript += event.results[index]?.[0]?.transcript ?? "";
      }
      const prefix = dictationPrefixRef.current;
      setText(`${prefix}${prefix && transcript.trim() ? " " : ""}${transcript.trimStart()}`);
    };
    recognition.onerror = (event) => {
      if (event.error !== "aborted") {
        setError(event.error === "not-allowed"
          ? "Allow microphone access to dictate what you need."
          : "Voice dictation stopped unexpectedly.");
      }
    };
    recognition.onend = () => {
      recognitionRef.current = null;
      setIsListening(false);
    };
    recognitionRef.current = recognition;
    try {
      recognition.start();
      setIsListening(true);
    } catch {
      recognitionRef.current = null;
      setError("Voice dictation could not be started.");
    }
  }

  function updateProposal(id: string, patch: Partial<EditableProposal>) {
    setProposals((items) => items.map((item) => (item.id === id ? { ...item, ...patch } : item)));
  }

  function setProposalStart(id: string, inputValue: string, allDay: boolean) {
    setProposals((items) => items.map((item) => {
      if (item.id !== id) return item;
      const nextStart = apiDateTime(allDay ? `${inputValue}T00:00` : inputValue);
      if (!nextStart || allDay || !item.end_time || !item.start_time) {
        return { ...item, start_time: nextStart, end_time: allDay ? null : item.end_time };
      }
      const oldStart = new Date(item.start_time);
      const oldEnd = new Date(item.end_time);
      const interval = oldEnd > oldStart ? oldEnd.getTime() - oldStart.getTime() : 15 * 60_000;
      return {
        ...item,
        start_time: nextStart,
        end_time: localISODateTime(new Date(new Date(nextStart).getTime() + interval)),
      };
    }));
  }

  function setProposalDuration(id: string, duration: ProposalDuration) {
    setProposals((items) => items.map((item) => {
      if (item.id !== id) return item;
      if (duration === "none") return { ...item, end_time: null };
      if (duration === "custom") {
        const start = item.start_time ? new Date(item.start_time) : null;
        const end = item.end_time ? new Date(item.end_time) : null;
        return start && end && end > start
          ? item
          : { ...item, end_time: defaultEndTime(item.start_time) };
      }
      if (!item.start_time) return item;
      return {
        ...item,
        end_time: localISODateTime(
          new Date(new Date(item.start_time).getTime() + Number(duration) * 60_000),
        ),
      };
    }));
  }

  async function parseCapture(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (!text.trim()) return;
    if (isListening) stopDictation();
    setBusy(true);
    setError(null);
    try {
      const response = await api<CaptureResponse>("/capture/parse", {
        method: "POST",
        timeoutMs: 130_000,
        body: JSON.stringify({
          text: text.trim(),
          use_hermes: false,
          client_now: new Date().toISOString(),
          timezone: Intl.DateTimeFormat().resolvedOptions().timeZone,
        }),
      });
      setProposals(response.proposals.map((proposal) => ({ ...proposal, included: true, saved: false })));
      proposalOperations.current = {};
      setWarning(response.warning ?? null);
      setReviewing(true);
    } catch (requestError) {
      setError(requestError instanceof Error ? requestError.message : "Couldn't read that capture.");
    } finally {
      setBusy(false);
    }
  }

  function addProposal(kind: CaptureProposal["kind"]) {
    setError(null);
    setProposals((items) => [...items, manualProposal(kind)]);
  }

  function continueInBismarck() {
    const content = text.trim();
    if (!content || !onContinueInBismarck) return;
    onContinueInBismarck(content);
  }

  function removeProposal(id: string) {
    if (proposalOperations.current[id]) {
      setError("This item has already been sent. Retry it before removing it.");
      return;
    }
    setProposals((items) => items.filter((item) => item.id !== id));
  }

  function changeProposalKind(id: string, kind: CaptureProposal["kind"]) {
    if (proposalOperations.current[id]?.kind !== undefined && proposalOperations.current[id].kind !== kind) {
      setError("This item has already been sent. Retry it before changing its type.");
      return;
    }
    setError(null);
    setProposals((items) => items.map((item) => {
      if (item.id !== id || item.kind === kind) return item;
      if (kind === "event") {
        const convertedStart = item.due_date ? apiDateTime(dateTimeInput(item.due_date)) : null;
        const startTime = convertedStart ?? nextWholeHour();
        return {
          ...item,
          kind,
          start_time: startTime,
          end_time: defaultEndTime(startTime),
          due_date: null,
          all_day: false,
        };
      }
      return {
        ...item,
        kind,
        start_time: null,
        end_time: null,
        due_date: item.start_time ?? null,
        all_day: true,
      };
    }));
  }

  function setProposalAllDay(id: string, allDay: boolean) {
    setProposals((items) => items.map((item) => {
      if (item.id !== id) return item;
      const date = dateInput(item.start_time) || dateInput(nextWholeHour());
      const startTime = apiDateTime(`${date}T${allDay ? "00:00" : "09:00"}`);
      return {
        ...item,
        all_day: allDay,
        start_time: startTime,
        end_time: allDay ? null : defaultEndTime(startTime),
      };
    }));
  }

  async function saveProposals() {
    const selected = proposals.filter((proposal) => proposal.included && !proposal.saved);
    if (!selected.length) return;
    setBusy(true);
    setError(null);
    try {
      for (const proposal of selected) {
        const title = proposal.title.trim();
        if (!title) throw new Error("Add a title for every selected item.");
        if (proposal.kind === "event") {
          if (!proposal.start_time) throw new Error(`Add a date for “${proposal.title}”.`);
          const start = new Date(proposal.start_time);
          const end = proposal.end_time ? new Date(proposal.end_time) : null;
          if (Number.isNaN(start.getTime())) throw new Error(`Add a valid start date for “${proposal.title}”.`);
          if (end && (Number.isNaN(end.getTime()) || end <= start)) {
            throw new Error(`The end time for “${proposal.title}” must be after its start time.`);
          }
          const createPayload: CalendarCreatePayload = {
            title,
            description: proposal.details || null,
            start_time: proposal.start_time,
            end_time: proposal.all_day ? null : proposal.end_time || null,
            all_day: proposal.all_day,
            assigned_to: proposal.assigned_to || null,
            family_member_ids: proposal.assigned_to ? [proposal.assigned_to] : null,
          };
          const fingerprint = JSON.stringify(createPayload);
          const operation = proposalOperations.current[proposal.id]
            ?? { id: crypto.randomUUID(), fingerprint, timestamp: new Date().toISOString(), kind: proposal.kind };
          proposalOperations.current[proposal.id] = operation;
          await api("/calendar/", {
            method: "POST",
            body: JSON.stringify({
              id: operation.id,
              ...createPayload,
              client_id: operation.id,
              client_timestamp: operation.timestamp,
            }),
          });
        } else {
          if (proposal.due_date && Number.isNaN(new Date(proposal.due_date).getTime())) {
            throw new Error(`Add a valid due date for “${proposal.title}”.`);
          }
          const createPayload: TaskCreatePayload = {
            title,
            description: proposal.details || null,
            due_date: proposal.due_date || null,
            assigned_to: proposal.assigned_to || null,
            category: "other",
            priority: 2,
          };
          const fingerprint = JSON.stringify(createPayload);
          const operation = proposalOperations.current[proposal.id]
            ?? { id: crypto.randomUUID(), fingerprint, timestamp: new Date().toISOString(), kind: proposal.kind };
          proposalOperations.current[proposal.id] = operation;
          await api("/tasks/", {
            method: "POST",
            body: JSON.stringify({
              id: operation.id,
              ...createPayload,
              client_id: operation.id,
              client_timestamp: operation.timestamp,
            }),
          });
        }
        delete proposalOperations.current[proposal.id];
        updateProposal(proposal.id, { saved: true });
      }
      notify(selected.length === 1 ? "Added to HausKlar." : `${selected.length} items added to HausKlar.`);
      onCreated();
      onOpenChange(false);
      setText("");
      setProposals([]);
      setReviewing(false);
      proposalOperations.current = {};
    } catch (requestError) {
      setError(requestError instanceof Error ? requestError.message : "Couldn't save every item.");
    } finally {
      setBusy(false);
    }
  }

  function selectFile(nextFile: File | null, source: "scan" | "file") {
    if (!nextFile) return;
    const accepted = supportedDocumentFile(nextFile);
    if (!accepted || (source === "scan" && !accepted.type.startsWith("image/"))) {
      setFile(null);
      documentUploadOperation.current = null;
      setError("Use a JPEG, PNG, TIFF, HEIC, PDF or plain-text file.");
      return;
    }
    setError(null);
    setFile(accepted);
    documentUploadOperation.current = { id: crypto.randomUUID(), fingerprint: null };
    setDocumentSource(source === "file" && accepted.type.startsWith("image/") ? "photo" : source);
    if (!documentTitle) {
      setDocumentTitle(accepted.name.replace(/\.[^.]+$/, "").replace(/[-_]+/g, " "));
    }
  }

  function togglePerson(personID: string) {
    setSelectedPeople((ids) =>
      ids.includes(personID) ? ids.filter((id) => id !== personID) : [...ids, personID],
    );
  }

  function chooseBismarck(enabled: boolean) {
    if (!enabled) {
      setUseBismarck(false);
      setShowAIConsent(false);
      return;
    }
    if (aiConsent.status?.consented) {
      setUseBismarck(true);
      return;
    }
    setShowAIConsent(true);
  }

  async function uploadDocument(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (!file) {
      setError("Choose a photo, scan or file first.");
      return;
    }
    if (!documentTitle.trim()) {
      setError("Add a document title.");
      return;
    }
    setBusy(true);
    setError(null);
    const uploadFingerprint = JSON.stringify({
      file: [file.name, file.size, file.type, file.lastModified],
      title: documentTitle.trim(),
      source: documentSource,
      category,
      notes,
      extractedText,
      selectedPeople,
      useBismarck,
    });
    let uploadOperation = documentUploadOperation.current;
    if (!uploadOperation || (uploadOperation.fingerprint && uploadOperation.fingerprint !== uploadFingerprint)) {
      uploadOperation = { id: crypto.randomUUID(), fingerprint: uploadFingerprint };
      documentUploadOperation.current = uploadOperation;
    } else {
      uploadOperation.fingerprint = uploadFingerprint;
    }
    const form = new FormData();
    form.set("document_id", uploadOperation.id);
    form.set("file", file);
    form.set("title", documentTitle.trim());
    form.set("source", documentSource);
    form.set("category", category);
    form.set("notes", notes);
    form.set("extracted_text", extractedText);
    form.set("person_ids", JSON.stringify(selectedPeople));
    form.set("suggestions", "[]");
    form.set("use_hermes", useBismarck ? "true" : "false");
    try {
      await api("/documents/", { method: "POST", body: form, timeoutMs: 120_000 });
      notify("Document added to the capture inbox.");
      onCreated();
      onOpenChange(false);
      setFile(null);
      documentUploadOperation.current = null;
      setDocumentSource("file");
      setDocumentTitle("");
      setNotes("");
      setExtractedText("");
      setSelectedPeople([]);
    } catch (requestError) {
      setError(requestError instanceof Error ? requestError.message : "Couldn't upload that document.");
    } finally {
      setBusy(false);
    }
  }

  return (
    <Modal
      open={open}
      onOpenChange={(nextOpen) => {
        if (!nextOpen && isListening) stopDictation();
        onOpenChange(nextOpen);
      }}
      title="Add"
      description="Review everything before it is added."
      size="wide"
    >
      <Segmented
        value={mode}
        onChange={setMode}
        label="What are you adding?"
        options={[
          { value: "plan", label: "Event or task" },
          { value: "document", label: "Letter or file" },
        ]}
      />
      {mode === "plan" ? (
        reviewing ? (
          <div className="capture-review">
            {warning ? <div className="form-warning">{warning}</div> : null}
            {error ? <div className="form-error" role="alert">{error}</div> : null}
            <div className="proposal-review-toolbar">
              <div>
                <strong>Review drafts</strong>
                <span>Check every detail before adding it to HausKlar.</span>
              </div>
              <div className="proposal-add-actions" role="group" aria-label="Add another item">
                <button type="button" className="button button--secondary button--compact" disabled={busy} onClick={() => addProposal("event")}>
                  <Plus aria-hidden="true" size={16} /> Event
                </button>
                <button type="button" className="button button--secondary button--compact" disabled={busy} onClick={() => addProposal("task")}>
                  <Plus aria-hidden="true" size={16} /> Task
                </button>
              </div>
            </div>
            {!proposals.length ? (
              <div className="capture-review-empty" role="status">
                <strong>No draft items yet</strong>
                <span>Add an event or task, then fill in the details.</span>
              </div>
            ) : null}
            <div className="proposal-list">
              {proposals.map((proposal, index) => (
                <fieldset className="proposal-row" key={proposal.id} disabled={proposal.saved}>
                  <legend className="sr-only">Captured item {index + 1}</legend>
                  <div className="proposal-row-header">
                    <label className="check-row proposal-toggle">
                      <input
                        type="checkbox"
                        checked={proposal.included}
                        disabled={proposal.saved || Boolean(proposalOperations.current[proposal.id])}
                        onChange={(event) => updateProposal(proposal.id, { included: event.target.checked })}
                      />
                      <span>{proposal.included ? "Include" : "Excluded"}</span>
                    </label>
                    <button
                      type="button"
                      className="icon-button icon-button--danger"
                      aria-label={`Remove item ${index + 1}`}
                      disabled={proposal.saved}
                      onClick={() => removeProposal(proposal.id)}
                    >
                      <Trash2 aria-hidden="true" size={17} />
                    </button>
                  </div>

                  <div className="proposal-main-fields">
                    <div className="field proposal-kind">
                      <span className="field-label">Type</span>
                      <Segmented
                        value={proposal.kind}
                        onChange={(kind) => changeProposalKind(proposal.id, kind)}
                        label={`Item ${index + 1} type`}
                        options={[{ value: "event", label: "Event" }, { value: "task", label: "Task" }]}
                      />
                    </div>
                    <div className="field proposal-title">
                      <label htmlFor={`proposal-${proposal.id}`}>Title</label>
                      <input
                        id={`proposal-${proposal.id}`}
                        value={proposal.title}
                        maxLength={300}
                        onChange={(event) => updateProposal(proposal.id, { title: event.target.value })}
                      />
                    </div>
                  </div>

                  <div className="field proposal-notes">
                    <label htmlFor={`proposal-notes-${proposal.id}`}>Notes (optional)</label>
                    <textarea
                      id={`proposal-notes-${proposal.id}`}
                      rows={2}
                      maxLength={10_000}
                      value={proposal.details ?? ""}
                      onChange={(event) => updateProposal(proposal.id, { details: event.target.value || null })}
                    />
                  </div>

                  <div className="proposal-fields">
                    {proposal.kind === "event" ? (
                      <>
                        <label className="check-row proposal-all-day">
                          <input
                            type="checkbox"
                            checked={proposal.all_day}
                            onChange={(event) => setProposalAllDay(proposal.id, event.target.checked)}
                          />
                          <span>All day</span>
                        </label>
                        <div className="field">
                          <label htmlFor={`proposal-start-${proposal.id}`}>{proposal.all_day ? "Date" : "Starts"}</label>
                          <input
                            id={`proposal-start-${proposal.id}`}
                            type={proposal.all_day ? "date" : "datetime-local"}
                            value={proposal.all_day ? dateInput(proposal.start_time) : dateTimeInput(proposal.start_time)}
                            onChange={(event) => setProposalStart(proposal.id, event.target.value, proposal.all_day)}
                            required={proposal.included}
                          />
                        </div>
                        {!proposal.all_day ? (
                          <>
                            <div className="field proposal-has-end">
                              <label htmlFor={`proposal-duration-${proposal.id}`}>Duration (optional)</label>
                              <select id={`proposal-duration-${proposal.id}`} value={proposalDuration(proposal)} onChange={(event) => setProposalDuration(proposal.id, event.target.value as ProposalDuration)}>
                                <option value="15">15 minutes</option>
                                <option value="30">30 minutes</option>
                                <option value="60">1 hour</option>
                                <option value="custom">Custom end time</option>
                                <option value="none">No duration</option>
                              </select>
                            </div>
                            {proposal.end_time ? (
                              <div className="field">
                                <label htmlFor={`proposal-end-${proposal.id}`}>Ends</label>
                                <input
                                  id={`proposal-end-${proposal.id}`}
                                  type="datetime-local"
                                  min={dateTimeInput(proposal.start_time)}
                                  value={dateTimeInput(proposal.end_time)}
                                  onChange={(event) => updateProposal(proposal.id, { end_time: apiDateTime(event.target.value) })}
                                  required={proposal.included}
                                />
                              </div>
                            ) : null}
                          </>
                        ) : null}
                      </>
                    ) : (
                      <div className="field">
                        <label htmlFor={`proposal-due-${proposal.id}`}>Due (optional)</label>
                        <input
                          id={`proposal-due-${proposal.id}`}
                          type="datetime-local"
                          value={dateTimeInput(proposal.due_date)}
                          onChange={(event) => updateProposal(proposal.id, { due_date: apiDateTime(event.target.value) })}
                        />
                      </div>
                    )}
                    <div className="field proposal-person">
                      <label htmlFor={`proposal-person-${proposal.id}`}>For</label>
                      <select
                        id={`proposal-person-${proposal.id}`}
                        value={proposal.assigned_to ?? ""}
                        onChange={(event) => updateProposal(proposal.id, { assigned_to: event.target.value || null })}
                      >
                        <option value="">Whole family</option>
                        {members.map((member) => (
                          <option value={member.id} key={member.id}>{member.name}</option>
                        ))}
                      </select>
                    </div>
                  </div>
                </fieldset>
              ))}
            </div>
            <div className="dialog-actions">
              <button type="button" className="button button--secondary" disabled={busy} onClick={() => {
                if (Object.keys(proposalOperations.current).length) {
                  setError("An item may already have been added. Retry it before returning to the capture text.");
                  return;
                }
                setError(null);
                setReviewing(false);
              }}>
                Back
              </button>
              <button type="button" className="button button--primary" onClick={saveProposals} disabled={busy || !proposals.some((proposal) => proposal.included && !proposal.saved)}>
                {busy ? <LoaderCircle className="spin" aria-hidden="true" size={17} /> : null}
                Add selected
              </button>
            </div>
          </div>
        ) : (
          <form className="form-stack capture-form" onSubmit={parseCapture} aria-busy={busy}>
            {error ? <div className="form-error" role="alert">{error}</div> : null}
            <div className="field">
              <label htmlFor="capture-text">What do you need to add?</label>
              <textarea
                id="capture-text"
                rows={6}
                value={text}
                onChange={(event) => setText(event.target.value)}
                placeholder="Football for Rowan every Tuesday at 5pm, starting next week"
                required
              />
            </div>
            {speechSupported ? (
              <div className="capture-dictation" role="group" aria-label="Voice dictation">
                <button
                  type="button"
                  className="button button--secondary"
                  aria-pressed={isListening}
                  disabled={busy}
                  onClick={toggleDictation}
                >
                  {isListening
                    ? <Square aria-hidden="true" size={15} fill="currentColor" />
                    : <Mic aria-hidden="true" size={18} />}
                  {isListening ? "Stop dictation" : "Dictate"}
                </button>
                <button
                  type="button"
                  className="button button--secondary capture-dictation-language"
                  aria-label={`Dictation language: ${dictationLanguage === "en-GB" ? "English" : "German"}. Change language`}
                  disabled={busy || isListening}
                  onClick={() => setDictationLanguage((current) => current === "en-GB" ? "de-DE" : "en-GB")}
                >
                  {dictationLanguage === "en-GB" ? "EN" : "DE"}
                </button>
                <span>The transcript stays editable.</span>
              </div>
            ) : null}
            <div className="dialog-actions capture-entry-actions">
              <button type="button" className="button button--secondary" onClick={() => onOpenChange(false)}>
                Cancel
              </button>
              {onContinueInBismarck ? <button type="button" className="button button--secondary continue-bismarck" disabled={busy || !text.trim()} onClick={continueInBismarck}><Sparkles aria-hidden="true" size={17} /> Continue in Bismarck</button> : null}
              <button type="submit" className="button button--primary" disabled={busy || !text.trim()}>
                {busy ? <LoaderCircle className="spin" aria-hidden="true" size={17} /> : null}
                {busy ? "Reading…" : "Review drafts"}
              </button>
            </div>
          </form>
        )
      ) : (
        <form className="form-stack" onSubmit={uploadDocument} aria-busy={busy}>
          {error ? <div className="form-error" role="alert">{error}</div> : null}
          <div className="family-document-privacy" role="note">
            <strong>Shared family document</strong>
            <p>Everyone in your HausKlar family can open this file. Its category and person labels do not make it private.</p>
            <a href="/?view=finance&section=setup#private-finance-files">Upload a financial file to Private Finance instead</a>
          </div>
          <div className="file-drop document-source-picker">
            {file?.type.startsWith("image/") ? <Camera aria-hidden="true" size={24} /> : <FileText aria-hidden="true" size={24} />}
            <strong>{file ? file.name : "Add the original photo or document"}</strong>
            <span>PDF, image or text file, up to 25 MB</span>
            <div className="attachment-picker-actions">
              <button type="button" className="button button--secondary" onClick={() => scanFileInput.current?.click()}><Camera aria-hidden="true" size={17} /> Scan document</button>
              <button type="button" className="button button--secondary" onClick={() => uploadFileInput.current?.click()}><FileText aria-hidden="true" size={17} /> Upload photo or file</button>
            </div>
            <input
              ref={scanFileInput}
              className="sr-only"
              type="file"
              aria-hidden="true"
              tabIndex={-1}
              accept={DOCUMENT_IMAGE_ACCEPT}
              capture="environment"
              aria-label="Scan document with camera"
              onChange={(event) => { selectFile(event.target.files?.[0] ?? null, "scan"); event.target.value = ""; }}
            />
            <input
              ref={uploadFileInput}
              className="sr-only"
              type="file"
              aria-hidden="true"
              tabIndex={-1}
              accept={DOCUMENT_FILE_ACCEPT}
              aria-label="Upload photo or document"
              onChange={(event) => { selectFile(event.target.files?.[0] ?? null, "file"); event.target.value = ""; }}
            />
          </div>
          <div className="form-grid">
            <div className="field">
              <label htmlFor="document-title">Title</label>
              <input id="document-title" value={documentTitle} onChange={(event) => setDocumentTitle(event.target.value)} required />
            </div>
            <div className="field">
              <label htmlFor="document-category">Category</label>
              <select id="document-category" value={category} onChange={(event) => setCategory(event.target.value)}>
                {[
                  "school",
                  "medical",
                  "childcare",
                  "identity",
                  "finance",
                  "activities",
                  "household",
                  "other",
                ].map((value) => <option value={value} key={value}>{value === "finance" ? "Household financial document" : value[0].toUpperCase() + value.slice(1)}</option>)}
              </select>
            </div>
          </div>
          <fieldset className="people-fieldset">
            <legend>Tag for (does not control access)</legend>
            <div className="people-options">
              {members.map((member) => (
                <label className="check-row" key={member.id}>
                  <input
                    type="checkbox"
                    checked={selectedPeople.includes(member.id)}
                    onChange={() => togglePerson(member.id)}
                  />
                  <span>{member.name}</span>
                </label>
              ))}
            </div>
          </fieldset>
          <div className="field">
            <label htmlFor="document-notes">Notes</label>
            <textarea id="document-notes" rows={2} value={notes} onChange={(event) => setNotes(event.target.value)} />
          </div>
          <details className="details-field">
            <summary>Extracted or copied text</summary>
            <div className="field">
              <label htmlFor="document-text">Document text</label>
              <textarea id="document-text" rows={5} value={extractedText} onChange={(event) => setExtractedText(event.target.value)} />
            </div>
          </details>
          <label className="check-row bismarck-option">
            <input
              type="checkbox"
              checked={useBismarck}
              disabled={aiConsent.loading || !aiConsent.status}
              onChange={(event) => chooseBismarck(event.target.checked)}
            />
            <Sparkles aria-hidden="true" size={18} />
            <span>Find action drafts with Bismarck (OpenAI)</span>
          </label>
          {aiConsent.loading ? <p className="field-help">Checking your AI privacy choice…</p> : null}
          {aiConsent.error && !showAIConsent ? <div className="form-error" role="alert">{aiConsent.error}</div> : null}
          {showAIConsent && aiConsent.status && !aiConsent.status.consented ? (
            <AIConsentPrompt
              status={aiConsent.status}
              busy={aiConsent.busy}
              error={aiConsent.error}
              onAllow={async () => {
                if (await aiConsent.grant()) {
                  setUseBismarck(true);
                  setShowAIConsent(false);
                }
              }}
              onDecline={() => {
                setUseBismarck(false);
                setShowAIConsent(false);
              }}
            />
          ) : null}
          <div className="dialog-actions">
            <button type="button" className="button button--secondary" onClick={() => onOpenChange(false)}>Cancel</button>
            <button type="submit" className="button button--primary" disabled={busy}>
              {busy ? <LoaderCircle className="spin" aria-hidden="true" size={17} /> : null}
              {busy ? "Uploading…" : "Add to inbox"}
            </button>
          </div>
        </form>
      )}
    </Modal>
  );
}
