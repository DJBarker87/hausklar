import * as DialogPrimitive from "@radix-ui/react-dialog";
import {
  CalendarPlus,
  Check,
  CheckCircle2,
  Dumbbell,
  ExternalLink,
  Lightbulb,
  ListPlus,
  LoaderCircle,
  Mic,
  Pencil,
  Send,
  ShoppingCart,
  Sparkles,
  Square,
  X,
} from "lucide-react";
import { format, parseISO } from "date-fns";
import { useEffect, useRef, useState, type FormEvent } from "react";

import { api, localISODateTime } from "../api";
import type {
  AssistantAction,
  AssistantActionKind,
  AssistantActionPreview,
  AssistantMessage,
  FamilyMember,
  TaskCategory,
} from "../types";
import { AIConsentPrompt, useAIConsent } from "./AIConsent";
import { cn } from "./ui";

const prompts = [
  "What needs my attention this week?",
  "Add milk and nappies to the shopping list.",
  "Put swimming on Thursday at 4pm.",
  "Remind Morgan to return the nursery form tomorrow.",
];

type RepeatChoice = "never" | "daily" | "weekly" | "monthly" | "yearly" | "custom";

function repeatChoice(rule?: string | null): RepeatChoice {
  if (!rule) return "never";
  const frequency = rule.match(/(?:^|;)FREQ=(DAILY|WEEKLY|MONTHLY|YEARLY)(?:;|$)/i)?.[1]?.toLowerCase();
  if (frequency === "daily" || frequency === "weekly" || frequency === "monthly" || frequency === "yearly") return frequency;
  return "custom";
}

function recurrenceRule(choice: RepeatChoice, current?: string | null): string | null {
  if (choice === "never") return null;
  if (choice === "custom") return current ?? null;
  return `FREQ=${choice.toUpperCase()}`;
}

type SpeechResultEvent = {
  resultIndex: number;
  results: {
    length: number;
    [index: number]: { isFinal: boolean; [index: number]: { transcript: string } };
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
  const browser = window as SpeechRecognitionWindow;
  return browser.SpeechRecognition ?? browser.webkitSpeechRecognition;
}

function actionIcon(kind: AssistantActionKind) {
  if (kind === "calendar_event") return CalendarPlus;
  if (kind === "home_lights") return Lightbulb;
  if (kind === "shopping_item") return ShoppingCart;
  if (kind === "complete_task") return CheckCircle2;
  return ListPlus;
}

function destination(kind: AssistantActionKind): string {
  if (kind === "calendar_event") return "Calendar";
  if (kind === "create_task" || kind === "complete_task") return "Tasks";
  if (kind === "shopping_item") return "Shopping";
  return "House";
}

function viewLabel(kind: AssistantActionKind): string {
  if (kind === "calendar_event") return "View in Calendar";
  if (kind === "create_task" || kind === "complete_task") return "View tasks";
  if (kind === "shopping_item") return "Open shopping list";
  return "Open House";
}

function dateTimeInput(value?: string | null): string {
  if (!value) return "";
  if (value.length === 10) return `${value}T09:00`;
  const parsed = parseISO(value);
  if (Number.isNaN(parsed.getTime())) return "";
  const offset = parsed.getTimezoneOffset() * 60_000;
  return new Date(parsed.getTime() - offset).toISOString().slice(0, 16);
}

function apiDateTime(value: string): string | null {
  if (!value) return null;
  const parsed = new Date(value);
  return Number.isNaN(parsed.getTime()) ? null : localISODateTime(parsed);
}

function readableDate(value?: string | null, allDay = false): string | null {
  if (!value) return null;
  const parsed = parseISO(value);
  if (Number.isNaN(parsed.getTime())) return null;
  return format(parsed, allDay || value.length === 10 ? "EEE d MMM" : "EEE d MMM, HH:mm");
}

function actionDetails(action: AssistantAction, members: FamilyMember[]): string[] {
  const preview = action.preview;
  if (!preview) return [];
  const memberName = "assigned_to" in preview && preview.assigned_to
    ? members.find((member) => member.id === preview.assigned_to)?.name
    : null;
  if (preview.kind === "calendar_event") {
    return [
      readableDate(preview.start_time, preview.all_day),
      memberName ? `For ${memberName}` : "Whole family",
    ].filter((item): item is string => Boolean(item));
  }
  if (preview.kind === "create_task") {
    return [
      preview.due_date ? `Due ${readableDate(preview.due_date)}` : "No due date",
      memberName ? `For ${memberName}` : "Whole family",
    ].filter((item): item is string => Boolean(item));
  }
  return [preview.quantity, preview.category].filter((item): item is string => Boolean(item));
}

function ActionEditForm({
  preview,
  members,
  online,
  busy,
  error,
  onChange,
  onCancel,
  onSave,
}: {
  preview: AssistantActionPreview;
  members: FamilyMember[];
  online: boolean;
  busy: boolean;
  error?: string;
  onChange: (preview: AssistantActionPreview) => void;
  onCancel: () => void;
  onSave: () => void;
}) {
  return (
    <form className="assistant-action-edit" onSubmit={(event) => { event.preventDefault(); onSave(); }} aria-busy={busy}>
      {error ? <div className="form-error" role="alert">{error}</div> : null}
      {preview.kind === "calendar_event" ? (
        <>
          <div className="field">
            <label htmlFor={`assistant-title-${preview.kind}`}>Title</label>
            <input id={`assistant-title-${preview.kind}`} value={preview.title} maxLength={300} required onChange={(event) => onChange({ ...preview, title: event.target.value })} />
          </div>
          <div className="field">
            <label htmlFor={`assistant-description-${preview.kind}`}>Notes (optional)</label>
            <textarea id={`assistant-description-${preview.kind}`} rows={2} value={preview.description ?? ""} onChange={(event) => onChange({ ...preview, description: event.target.value || null })} />
          </div>
          <label className="check-row"><input type="checkbox" checked={preview.all_day} onChange={(event) => onChange({ ...preview, all_day: event.target.checked, start_time: event.target.checked ? preview.start_time.slice(0, 10) : (apiDateTime(dateTimeInput(preview.start_time)) ?? preview.start_time), end_time: event.target.checked ? null : preview.end_time })} /><span>All day</span></label>
          <div className="assistant-edit-grid">
            <div className="field">
              <label htmlFor="assistant-event-start">{preview.all_day ? "Date" : "Starts"}</label>
              <input id="assistant-event-start" type={preview.all_day ? "date" : "datetime-local"} value={preview.all_day ? preview.start_time.slice(0, 10) : dateTimeInput(preview.start_time)} required onChange={(event) => onChange({ ...preview, start_time: preview.all_day ? event.target.value : (apiDateTime(event.target.value) ?? preview.start_time) })} />
            </div>
            {!preview.all_day ? <div className="field"><label htmlFor="assistant-event-end">Ends (optional)</label><input id="assistant-event-end" type="datetime-local" min={dateTimeInput(preview.start_time)} value={dateTimeInput(preview.end_time)} onChange={(event) => onChange({ ...preview, end_time: apiDateTime(event.target.value) })} /></div> : null}
          </div>
          <div className="assistant-edit-grid">
            <div className="field"><label htmlFor="assistant-event-for">For</label><select id="assistant-event-for" value={preview.assigned_to ?? ""} onChange={(event) => onChange({ ...preview, assigned_to: event.target.value || null })}><option value="">Whole family</option>{members.map((member) => <option value={member.id} key={member.id}>{member.name}</option>)}</select></div>
            <div className="field"><label htmlFor="assistant-event-repeat">Repeat</label><select id="assistant-event-repeat" value={repeatChoice(preview.recurrence_rule)} onChange={(event) => onChange({ ...preview, recurrence_rule: recurrenceRule(event.target.value as RepeatChoice, preview.recurrence_rule) })}><option value="never">Never</option><option value="daily">Daily</option><option value="weekly">Weekly</option><option value="monthly">Monthly</option><option value="yearly">Yearly</option>{repeatChoice(preview.recurrence_rule) === "custom" ? <option value="custom">Custom schedule (keep)</option> : null}</select>{repeatChoice(preview.recurrence_rule) === "custom" ? <small>This detailed schedule will be kept unless you choose a simpler repeat.</small> : null}</div>
          </div>
          <label className="check-row"><input type="checkbox" checked={preview.term_time_only ?? false} onChange={(event) => onChange({ ...preview, term_time_only: event.target.checked })} /><span>Term time only</span></label>
        </>
      ) : null}
      {preview.kind === "create_task" ? (
        <>
          <div className="field"><label htmlFor="assistant-task-title">Title</label><input id="assistant-task-title" value={preview.title} maxLength={300} required onChange={(event) => onChange({ ...preview, title: event.target.value })} /></div>
          <div className="field"><label htmlFor="assistant-task-description">Notes (optional)</label><textarea id="assistant-task-description" rows={2} value={preview.description ?? ""} onChange={(event) => onChange({ ...preview, description: event.target.value || null })} /></div>
          <div className="assistant-edit-grid">
            <div className="field"><label htmlFor="assistant-task-due">Due (optional)</label><input id="assistant-task-due" type="datetime-local" value={dateTimeInput(preview.due_date)} onChange={(event) => onChange({ ...preview, due_date: apiDateTime(event.target.value) })} /></div>
            <div className="field"><label htmlFor="assistant-task-for">For</label><select id="assistant-task-for" value={preview.assigned_to ?? ""} onChange={(event) => onChange({ ...preview, assigned_to: event.target.value || null })}><option value="">Whole family</option>{members.map((member) => <option value={member.id} key={member.id}>{member.name}</option>)}</select></div>
            <div className="field"><label htmlFor="assistant-task-category">Category</label><select id="assistant-task-category" value={preview.category} onChange={(event) => onChange({ ...preview, category: event.target.value as TaskCategory })}>{["other", "household", "shopping", "admin", "bins"].map((category) => <option value={category} key={category}>{category[0].toUpperCase() + category.slice(1)}</option>)}</select></div>
            <div className="field"><label htmlFor="assistant-task-priority">Priority</label><select id="assistant-task-priority" value={preview.priority} onChange={(event) => onChange({ ...preview, priority: Number(event.target.value) })}><option value={1}>Low</option><option value={2}>Normal</option><option value={3}>Important</option></select></div>
            <div className="field"><label htmlFor="assistant-task-repeat">Repeat</label><select id="assistant-task-repeat" value={repeatChoice(preview.recurrence_rule)} onChange={(event) => onChange({ ...preview, recurrence_rule: recurrenceRule(event.target.value as RepeatChoice, preview.recurrence_rule) })}><option value="never">Never</option><option value="daily">Daily</option><option value="weekly">Weekly</option><option value="monthly">Monthly</option><option value="yearly">Yearly</option>{repeatChoice(preview.recurrence_rule) === "custom" ? <option value="custom">Custom schedule (keep)</option> : null}</select>{repeatChoice(preview.recurrence_rule) === "custom" ? <small>This detailed schedule will be kept unless you choose a simpler repeat.</small> : null}</div>
          </div>
        </>
      ) : null}
      {preview.kind === "shopping_item" ? (
        <>
          <div className="field"><label htmlFor="assistant-shopping-name">Item</label><input id="assistant-shopping-name" value={preview.name} maxLength={200} required onChange={(event) => onChange({ ...preview, name: event.target.value })} /></div>
          <div className="assistant-edit-grid"><div className="field"><label htmlFor="assistant-shopping-quantity">Quantity (optional)</label><input id="assistant-shopping-quantity" value={preview.quantity ?? ""} onChange={(event) => onChange({ ...preview, quantity: event.target.value || null })} /></div><div className="field"><label htmlFor="assistant-shopping-category">Category (optional)</label><input id="assistant-shopping-category" value={preview.category ?? ""} onChange={(event) => onChange({ ...preview, category: event.target.value || null })} /></div></div>
        </>
      ) : null}
      <div className="assistant-edit-actions">
        <button type="button" className="button button--secondary button--compact" disabled={busy} onClick={onCancel}>Cancel</button>
        <button type="submit" className="button button--primary button--compact" disabled={busy || !online}>{busy ? <LoaderCircle className="spin" aria-hidden="true" size={16} /> : null}{busy ? "Saving…" : "Save changes"}</button>
      </div>
      {!online ? <p className="assistant-offline-note">Reconnect to save proposal changes.</p> : null}
    </form>
  );
}

export function BismarckChat({
  open,
  onOpenChange,
  online,
  members,
  onDataChanged,
  onViewResult,
  onOpenFitnessCoach,
  initialDraft,
  onInitialDraftConsumed,
}: {
  open: boolean;
  onOpenChange: (open: boolean) => void;
  online: boolean;
  members: FamilyMember[];
  onDataChanged: () => void;
  onViewResult: (kind: AssistantActionKind, resultID?: string | null) => void;
  onOpenFitnessCoach?: (draft: string) => void;
  initialDraft?: { text: string; nonce: number } | null;
  onInitialDraftConsumed?: () => void;
}) {
  const [messages, setMessages] = useState<AssistantMessage[]>([]);
  const [input, setInput] = useState("");
  const [sending, setSending] = useState(false);
  const [thinkingStatus, setThinkingStatus] = useState("Checking the family plan…");
  const [error, setError] = useState<string | null>(null);
  const [failedMessage, setFailedMessage] = useState<string | null>(null);
  const [editingAction, setEditingAction] = useState<string | null>(null);
  const [editDrafts, setEditDrafts] = useState<Record<string, AssistantActionPreview>>({});
  const [savingAction, setSavingAction] = useState<string | null>(null);
  const [actionErrors, setActionErrors] = useState<Record<string, string>>({});
  const thinkingTimers = useRef<number[]>([]);
  const resolvingActions = useRef(new Set<string>());
  const [isListening, setIsListening] = useState(false);
  const [dictationLanguage, setDictationLanguage] = useState<"en-GB" | "de-DE">("en-GB");
  const recognitionRef = useRef<BrowserSpeechRecognition | null>(null);
  const dictationPrefixRef = useRef("");
  const consumedDraft = useRef<number | null>(null);
  const messagesEndRef = useRef<HTMLDivElement | null>(null);
  const speechSupported = Boolean(speechRecognitionConstructor());
  const aiConsent = useAIConsent(open);

  useEffect(() => () => {
    recognitionRef.current?.abort();
    thinkingTimers.current.forEach((timer) => window.clearTimeout(timer));
  }, []);

  useEffect(() => {
    if (!initialDraft || initialDraft.nonce === consumedDraft.current) return;
    consumedDraft.current = initialDraft.nonce;
    setInput(initialDraft.text);
    onInitialDraftConsumed?.();
  }, [initialDraft, onInitialDraftConsumed]);

  useEffect(() => {
    if (!open) return;
    const frame = window.requestAnimationFrame(() => {
      const reducedMotion = window.matchMedia?.("(prefers-reduced-motion: reduce)").matches ?? false;
      messagesEndRef.current?.scrollIntoView?.({ behavior: reducedMotion ? "auto" : "smooth", block: "nearest" });
    });
    return () => window.cancelAnimationFrame(frame);
  }, [actionErrors, editingAction, messages, open, sending, thinkingStatus]);

  function replaceAction(messageID: string, actionID: string, patch: Partial<AssistantAction>) {
    setMessages((current) => current.map((message) => message.id === messageID ? {
      ...message,
      actions: message.actions.map((action) => action.id === actionID ? { ...action, ...patch } : action),
    } : message));
  }

  function startThinkingStatus() {
    thinkingTimers.current.forEach((timer) => window.clearTimeout(timer));
    setThinkingStatus("Checking the family plan…");
    thinkingTimers.current = [
      window.setTimeout(() => setThinkingStatus("Pulling the useful bits together…"), 2_000),
      window.setTimeout(() => setThinkingStatus("Finishing the answer…"), 5_000),
    ];
  }

  function stopThinkingStatus() {
    thinkingTimers.current.forEach((timer) => window.clearTimeout(timer));
    thinkingTimers.current = [];
  }

  function stopDictation() {
    recognitionRef.current?.stop();
    recognitionRef.current = null;
    setIsListening(false);
  }

  function openFitnessCoach() {
    if (!onOpenFitnessCoach) return;
    if (isListening) stopDictation();
    const draft = input;
    onOpenChange(false);
    onOpenFitnessCoach(draft);
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
    dictationPrefixRef.current = input.trimEnd();
    recognition.onresult = (event) => {
      let transcript = "";
      for (let index = 0; index < event.results.length; index += 1) transcript += event.results[index]?.[0]?.transcript ?? "";
      const prefix = dictationPrefixRef.current;
      setInput(`${prefix}${prefix && transcript.trim() ? " " : ""}${transcript.trimStart()}`);
    };
    recognition.onerror = (event) => {
      if (event.error !== "aborted") setError(event.error === "not-allowed" ? "Allow microphone access to dictate a message." : "Voice dictation stopped unexpectedly.");
    };
    recognition.onend = () => { recognitionRef.current = null; setIsListening(false); };
    recognitionRef.current = recognition;
    try { recognition.start(); setIsListening(true); } catch { recognitionRef.current = null; setError("Voice dictation could not be started."); }
  }

  async function send(messageText?: string, appendUser = true) {
    const content = (messageText ?? input).trim();
    if (!content || sending || !online || !aiConsent.status?.consented) return;
    if (isListening) stopDictation();
    const existingHistory = messages.slice(-12);
    const historyMessages = !appendUser && existingHistory.at(-1)?.role === "user" && existingHistory.at(-1)?.content === content
      ? existingHistory.slice(0, -1)
      : existingHistory;
    const history = historyMessages.map((message) => ({ role: message.role, content: message.content }));
    if (appendUser) setMessages((current) => [...current, { id: crypto.randomUUID(), role: "user", content, actions: [] }]);
    setInput("");
    setSending(true);
    startThinkingStatus();
    setError(null);
    setFailedMessage(null);
    try {
      const response = await api<{ answer: string; actions: AssistantAction[] }>("/assistant/message", {
        method: "POST",
        timeoutMs: 130_000,
        body: JSON.stringify({ message: content, history, client_now: new Date().toISOString(), timezone: Intl.DateTimeFormat().resolvedOptions().timeZone }),
      });
      setMessages((current) => [...current, { id: crypto.randomUUID(), role: "assistant", content: response.answer, actions: response.actions }]);
    } catch (requestError) {
      setInput(content);
      setFailedMessage(content);
      setError(requestError instanceof Error ? requestError.message : "Bismarck couldn't answer just now.");
    } finally {
      stopThinkingStatus();
      setSending(false);
    }
  }

  async function resolve(messageID: string, action: AssistantAction, decision: "execute" | "decline") {
    if (!online || action.status !== "pending" || resolvingActions.current.has(action.id)) return;
    resolvingActions.current.add(action.id);
    setActionErrors((current) => ({ ...current, [action.id]: "" }));
    replaceAction(messageID, action.id, { status: "executing" });
    try {
      const response = await api<{ status: AssistantAction["status"]; message: string; result_id?: string | null }>(`/assistant/actions/${action.id}/${decision}`, { method: "POST", body: JSON.stringify({}) });
      replaceAction(messageID, action.id, { status: response.status, message: response.message, result_id: response.result_id ?? action.result_id });
      if (response.status === "executed") onDataChanged();
    } catch (requestError) {
      setActionErrors((current) => ({ ...current, [action.id]: requestError instanceof Error ? requestError.message : "That action couldn't be completed." }));
      replaceAction(messageID, action.id, { status: "pending" });
    } finally {
      resolvingActions.current.delete(action.id);
    }
  }

  function beginEdit(action: AssistantAction) {
    if (!online || !action.preview) return;
    setEditDrafts((current) => ({ ...current, [action.id]: { ...action.preview! } }));
    setActionErrors((current) => ({ ...current, [action.id]: "" }));
    setEditingAction(action.id);
  }

  async function saveEdit(messageID: string, action: AssistantAction) {
    const draft = editDrafts[action.id];
    if (!online || !draft || draft.kind !== action.kind) return;
    setSavingAction(action.id);
    setActionErrors((current) => ({ ...current, [action.id]: "" }));
    try {
      const updated = await api<AssistantAction>(`/assistant/actions/${action.id}`, { method: "PATCH", body: JSON.stringify(draft) });
      setMessages((current) => current.map((message) => message.id === messageID ? { ...message, actions: message.actions.map((item) => item.id === action.id ? updated : item) } : message));
      setEditingAction(null);
    } catch (requestError) {
      setActionErrors((current) => ({ ...current, [action.id]: requestError instanceof Error ? requestError.message : "Those changes could not be saved." }));
    } finally {
      setSavingAction(null);
    }
  }

  return (
    <DialogPrimitive.Root open={open} onOpenChange={(nextOpen) => { if (!nextOpen) stopDictation(); onOpenChange(nextOpen); }}>
      <DialogPrimitive.Portal>
        <DialogPrimitive.Overlay className="chat-overlay" />
        <DialogPrimitive.Content className="chat-panel">
          <header className="chat-header">
            <span className="bismarck-avatar"><Sparkles aria-hidden="true" size={18} /></span>
            <div><DialogPrimitive.Title>Bismarck</DialogPrimitive.Title><DialogPrimitive.Description>Uses OpenAI with your permission</DialogPrimitive.Description></div>
            <DialogPrimitive.Close asChild><button type="button" className="icon-button" aria-label="Close Bismarck"><X aria-hidden="true" size={19} /></button></DialogPrimitive.Close>
          </header>
          <div className="chat-messages" aria-live="polite">
            {aiConsent.loading ? <div className="chat-consent-loading" role="status"><LoaderCircle className="spin" aria-hidden="true" size={20} />Checking your AI privacy choice…</div> : null}
            {!aiConsent.loading && !aiConsent.status ? <div className="chat-offline" role="alert"><strong>AI privacy settings could not be loaded</strong><p>{aiConsent.error ?? "Try again when HausKlar is connected."}</p><button type="button" className="button button--secondary" onClick={() => void aiConsent.reload()}>Try again</button></div> : null}
            {aiConsent.status && !aiConsent.status.consented ? <AIConsentPrompt status={aiConsent.status} busy={aiConsent.busy} error={aiConsent.error} onAllow={() => void aiConsent.grant()} onDecline={() => onOpenChange(false)} /> : null}
            {aiConsent.status?.consented && !online ? <div className="chat-offline" role="status"><strong>Bismarck needs a connection</strong><p>Existing family information remains available. Reconnect to add or change anything.</p></div> : null}
            {aiConsent.status?.consented && !messages.length ? <div className="chat-welcome"><strong>Hi, I'm Bismarck</strong><p>Ask a question or tell me what the family needs doing. I will show every change before it is made.</p><div className="chat-prompts">{prompts.map((prompt) => <button type="button" key={prompt} disabled={!online || sending} onClick={() => void send(prompt)}>{prompt}</button>)}</div></div> : null}
            {aiConsent.status?.consented ? messages.map((message) => <div className={cn("chat-message", `chat-message--${message.role}`)} key={message.id}>
              {message.role === "assistant" ? <span className="bismarck-avatar"><Sparkles aria-hidden="true" size={15} /></span> : null}
              <div className="chat-message-content"><p>{message.content}</p>{message.actions.map((action) => {
                const ActionIcon = actionIcon(action.kind);
                const draft = editDrafts[action.id];
                const details = actionDetails(action, members);
                return <article className="assistant-action" key={action.id} aria-label={`${destination(action.kind)} proposal`}>
                  <div className="assistant-action-destination"><ActionIcon aria-hidden="true" size={17} /><span>{destination(action.kind)}</span></div>
                  <div className="assistant-action-summary"><strong>{action.summary}</strong>{details.length ? <span>{details.join(" · ")}</span> : null}</div>
                  {editingAction === action.id && draft ? <ActionEditForm preview={draft} members={members} online={online} busy={savingAction === action.id} error={actionErrors[action.id]} onChange={(preview) => setEditDrafts((current) => ({ ...current, [action.id]: preview }))} onCancel={() => setEditingAction(null)} onSave={() => void saveEdit(message.id, action)} /> : null}
                  {editingAction !== action.id && action.message ? <span className={`action-status action-status--${action.status}`}>{action.message}</span> : null}
                  {editingAction !== action.id && actionErrors[action.id] ? <div className="assistant-action-error" role="alert">{actionErrors[action.id]}</div> : null}
                  {editingAction !== action.id && action.status === "pending" ? <><div className="assistant-action-buttons"><button type="button" className="button button--primary button--compact" disabled={!online} onClick={() => void resolve(message.id, action, "execute")}><Check aria-hidden="true" size={16} /> Confirm</button>{action.editable && action.preview ? <button type="button" className="button button--secondary button--compact" disabled={!online} onClick={() => beginEdit(action)}><Pencil aria-hidden="true" size={15} /> Edit</button> : null}<button type="button" className="button button--secondary button--compact" disabled={!online} onClick={() => void resolve(message.id, action, "decline")}>Dismiss</button></div>{!online ? <p className="assistant-offline-note">Reconnect to confirm, edit or dismiss this proposal.</p> : null}</> : null}
                  {action.status === "executing" ? <span className="action-working"><LoaderCircle className="spin" aria-hidden="true" size={16} /> Working…</span> : null}
                  {action.status === "executed" && action.result_id && action.kind !== "home_lights" ? <button type="button" className="assistant-result-link" onClick={() => onViewResult(action.kind, action.result_id)}>{viewLabel(action.kind)} <ExternalLink aria-hidden="true" size={15} /></button> : null}
                </article>;
              })}</div>
            </div>) : null}
            {aiConsent.status?.consented && sending ? <div className="chat-thinking"><LoaderCircle className="spin" aria-hidden="true" size={17} /> {thinkingStatus}</div> : null}
            <div ref={messagesEndRef} aria-hidden="true" />
          </div>
          {aiConsent.status?.consented && error ? <div className="chat-error" role="alert"><span>{error}</span>{failedMessage && online ? <button type="button" onClick={() => void send(failedMessage, false)}>Try again</button> : null}</div> : null}
          {aiConsent.status?.consented && onOpenFitnessCoach ? <div className="chat-coach-handoff"><button type="button" className="button button--secondary" onClick={openFitnessCoach}><Dumbbell aria-hidden="true" size={17} /> Open Fitness Coach</button></div> : null}
          {aiConsent.status?.consented ? <form className={cn("chat-composer", speechSupported && "has-voice")} onSubmit={(event: FormEvent<HTMLFormElement>) => { event.preventDefault(); void send(undefined, input.trim() !== failedMessage); }}>
            <label htmlFor="bismarck-message" className="sr-only">Message Bismarck</label>
            <textarea id="bismarck-message" rows={1} value={input} disabled={!online} onChange={(event) => setInput(event.target.value)} placeholder={online ? "Message Bismarck" : "Reconnect to message Bismarck"} onKeyDown={(event) => { if (event.key === "Enter" && !event.shiftKey) { event.preventDefault(); void send(undefined, input.trim() !== failedMessage); } }} />
            {speechSupported ? <><button type="button" className="chat-language" aria-label={`Dictation language: ${dictationLanguage === "en-GB" ? "English" : "German"}. Change language`} title="Change dictation language" disabled={isListening || !online} onClick={() => setDictationLanguage((current) => current === "en-GB" ? "de-DE" : "en-GB")}>{dictationLanguage === "en-GB" ? "EN" : "DE"}</button><button type="button" className={cn("chat-dictate", isListening && "is-listening")} aria-label={isListening ? "Stop dictation" : "Dictate message"} aria-pressed={isListening} title={isListening ? "Stop dictation" : "Dictate message"} disabled={sending || !online} onClick={toggleDictation}>{isListening ? <Square aria-hidden="true" size={15} fill="currentColor" /> : <Mic aria-hidden="true" size={18} />}</button></> : null}
            <button type="submit" className="chat-send" aria-label="Send message" disabled={!online || !input.trim() || sending}><Send aria-hidden="true" size={18} /></button>
          </form> : null}
        </DialogPrimitive.Content>
      </DialogPrimitive.Portal>
    </DialogPrimitive.Root>
  );
}
