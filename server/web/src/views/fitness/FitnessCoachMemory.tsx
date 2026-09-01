import {
  Check,
  ChevronRight,
  Clock3,
  Edit3,
  LoaderCircle,
  LockKeyhole,
  MessageCirclePlus,
  Plus,
  ShieldCheck,
  Trash2,
} from "lucide-react";
import { useCallback, useEffect, useState } from "react";

import { api } from "../../api";
import { asFitnessArray, type FitnessCoachConversation, type FitnessCoachConversationMessage, type FitnessCoachConversationSummary, type FitnessCoachMemory, type FitnessCoachMemoryCandidate, type FitnessCoachMemoryClearResponse, type FitnessCoachMemorySettings } from "../../fitness/contract";
import { FitnessCard, errorMessage, formatFitnessDateTime } from "./shared";

function promptStorageKey(ownerKey: string): string {
  return `hausklar:fitness-coach-memory-prompt:${encodeURIComponent(ownerKey)}`;
}

function promptWasSeen(ownerKey: string): boolean {
  try {
    return window.localStorage.getItem(promptStorageKey(ownerKey)) === "seen";
  } catch {
    return false;
  }
}

function markPromptSeen(ownerKey: string): void {
  try {
    window.localStorage.setItem(promptStorageKey(ownerKey), "seen");
  } catch {
    // The switch still works when private-browser storage is unavailable.
  }
}

function conversationTitle(conversation: FitnessCoachConversationSummary): string {
  return conversation.title?.trim() || "Untitled conversation";
}

function memoryCategory(category?: string | null): string {
  return category?.trim() || "General";
}

export function FitnessCoachMemoryPanel({
  online,
  ownerKey,
  revision,
  dataRevision,
  activeConversationId,
  onEnabledChange,
  onOpenConversation,
  onNewConversation,
  onDetachConversation,
  onStoredDataChanged,
}: {
  online: boolean;
  ownerKey: string;
  revision: number;
  dataRevision?: number;
  activeConversationId: string | null;
  onEnabledChange: (enabled: boolean) => void;
  onOpenConversation: (conversation: FitnessCoachConversation, resume: boolean) => void;
  onNewConversation: (conversationId: string | null) => void;
  onDetachConversation: () => void;
  onStoredDataChanged: () => void;
}) {
  const [settings, setSettings] = useState<FitnessCoachMemorySettings | null>(null);
  const [settingsLoading, setSettingsLoading] = useState(true);
  const [settingsBusy, setSettingsBusy] = useState(false);
  const [settingsError, setSettingsError] = useState<string | null>(null);
  const [settingsNonce, setSettingsNonce] = useState(0);
  const [promptSeen, setPromptSeen] = useState(() => promptWasSeen(ownerKey));
  const [conversations, setConversations] = useState<FitnessCoachConversationSummary[]>([]);
  const [memories, setMemories] = useState<FitnessCoachMemory[]>([]);
  const [dataLoading, setDataLoading] = useState(false);
  const [dataError, setDataError] = useState<string | null>(null);
  const [dataNonce, setDataNonce] = useState(0);
  const [conversationBusy, setConversationBusy] = useState<string | null>(null);
  const [conversationToDelete, setConversationToDelete] = useState<string | null>(null);
  const [memoryBusy, setMemoryBusy] = useState<string | null>(null);
  const [memoryToForget, setMemoryToForget] = useState<string | null>(null);
  const [editingMemory, setEditingMemory] = useState<string | null>(null);
  const [editContent, setEditContent] = useState("");
  const [editCategory, setEditCategory] = useState("");
  const [addingMemory, setAddingMemory] = useState(false);
  const [newContent, setNewContent] = useState("");
  const [newCategory, setNewCategory] = useState("");
  const [clearConfirm, setClearConfirm] = useState(false);
  const [notice, setNotice] = useState<string | null>(null);
  const [recentOpen, setRecentOpen] = useState(true);

  const reloadData = useCallback(() => setDataNonce((value) => value + 1), []);

  useEffect(() => {
    let cancelled = false;
    setPromptSeen(promptWasSeen(ownerKey));
    setSettings(null);
    setConversations([]);
    setMemories([]);
    setSettingsError(null);
    setDataError(null);
    onEnabledChange(false);
    if (!online) {
      setSettingsLoading(false);
      return () => { cancelled = true; };
    }
    setSettingsLoading(true);
    void api<FitnessCoachMemorySettings>("/fitness/coach/memory/settings", {}, true, false)
      .then((response) => {
        if (cancelled) return;
        setSettings(response);
        onEnabledChange(response.enabled);
        if (response.enabled) {
          markPromptSeen(ownerKey);
          setPromptSeen(true);
        }
      })
      .catch((requestError) => { if (!cancelled) setSettingsError(errorMessage(requestError)); })
      .finally(() => { if (!cancelled) setSettingsLoading(false); });
    return () => { cancelled = true; };
  }, [online, ownerKey, revision, settingsNonce]);

  useEffect(() => {
    let cancelled = false;
    if (!online || settings === null) {
      setDataLoading(false);
      return () => { cancelled = true; };
    }
    setDataLoading(true);
    setDataError(null);
    void Promise.all([
      api<FitnessCoachConversationSummary[] | { items?: FitnessCoachConversationSummary[] }>("/fitness/coach/conversations", {}, true, false),
      api<FitnessCoachMemory[] | { items?: FitnessCoachMemory[] }>("/fitness/coach/memories", {}, true, false),
    ]).then(([conversationResponse, memoryResponse]) => {
      if (cancelled) return;
      setConversations(asFitnessArray(conversationResponse));
      setMemories(asFitnessArray(memoryResponse));
    }).catch((requestError) => {
      if (!cancelled) setDataError(errorMessage(requestError));
    }).finally(() => { if (!cancelled) setDataLoading(false); });
    return () => { cancelled = true; };
  }, [dataNonce, dataRevision, online, ownerKey, settings?.enabled]);

  function keepTemporary() {
    markPromptSeen(ownerKey);
    setPromptSeen(true);
    setNotice("Chats will stay in this page only. You can turn on private NUC storage later.");
  }

  async function setMemoryEnabled(enabled: boolean) {
    if (!online || settingsBusy) return;
    const wasEnabled = settings?.enabled === true;
    setSettingsBusy(true);
    setSettingsError(null);
    setNotice(null);
    try {
      const response = await api<FitnessCoachMemorySettings>("/fitness/coach/memory/settings", {
        method: "PUT",
        body: JSON.stringify({ enabled }),
      }, true, false);
      markPromptSeen(ownerKey);
      setPromptSeen(true);
      setSettings(response);
      onEnabledChange(response.enabled);
      if (!response.enabled) {
        onDetachConversation();
      } else if (!wasEnabled) {
        // A temporary transcript must never look as though it was retroactively stored.
        onNewConversation(null);
      }
      setNotice(response.enabled
        ? "Conversation memory is on for this account. Your earlier temporary chat was not saved; this is a fresh chat. Nothing suggested by Coach is remembered without your confirmation."
        : "Conversation memory is off. The chat already open on this page remains here, but new messages will not be stored.");
      if (response.enabled) reloadData();
    } catch (requestError) {
      setSettingsError(errorMessage(requestError));
    } finally {
      setSettingsBusy(false);
    }
  }

  async function startNewConversation() {
    setNotice(null);
    if (!settings?.enabled) {
      onNewConversation(null);
      return;
    }
    if (!online || conversationBusy) return;
    setConversationBusy("new");
    try {
      const conversation = await api<FitnessCoachConversationSummary>("/fitness/coach/conversations", {
        method: "POST",
        body: JSON.stringify({}),
      }, true, false);
      onNewConversation(conversation.id);
      reloadData();
    } catch (requestError) {
      setDataError(errorMessage(requestError));
    } finally {
      setConversationBusy(null);
    }
  }

  async function openConversation(id: string) {
    if (!online || !settings || conversationBusy) return;
    setConversationBusy(id);
    setDataError(null);
    try {
      const conversation = await api<FitnessCoachConversation>(`/fitness/coach/conversations/${encodeURIComponent(id)}`, {}, true, false);
      onOpenConversation(conversation, settings.enabled);
      if (!settings.enabled) {
        setNotice("Showing a saved transcript as a read-only copy. Any new reply stays temporary and will not update the saved conversation.");
      }
    } catch (requestError) {
      setDataError(errorMessage(requestError));
    } finally {
      setConversationBusy(null);
    }
  }

  async function deleteConversation(id: string) {
    if (!online || conversationBusy) return;
    setConversationBusy(id);
    setDataError(null);
    try {
      await api<void>(`/fitness/coach/conversations/${encodeURIComponent(id)}`, { method: "DELETE" }, true, false);
      setConversations((current) => current.filter((conversation) => conversation.id !== id));
      if (activeConversationId === id) onDetachConversation();
      setConversationToDelete(null);
      setNotice("Saved conversation deleted. Any chat still visible on this page remains temporary.");
      onStoredDataChanged();
    } catch (requestError) {
      setDataError(errorMessage(requestError));
    } finally {
      setConversationBusy(null);
    }
  }

  async function addMemory() {
    const content = newContent.trim();
    const category = newCategory.trim();
    if (!content || !online || !settings?.enabled || memoryBusy) return;
    setMemoryBusy("new");
    setDataError(null);
    try {
      await api<FitnessCoachMemory>("/fitness/coach/memories", {
        method: "POST",
        body: JSON.stringify({ content, ...(category ? { category } : {}) }),
      }, true, false);
      setNewContent("");
      setNewCategory("");
      setAddingMemory(false);
      setNotice("Memory added for this account.");
      reloadData();
      onStoredDataChanged();
    } catch (requestError) {
      setDataError(errorMessage(requestError));
    } finally {
      setMemoryBusy(null);
    }
  }

  function beginEdit(memory: FitnessCoachMemory) {
    setEditingMemory(memory.id);
    setEditContent(memory.content);
    setEditCategory(memory.category ?? "");
    setMemoryToForget(null);
  }

  async function saveMemory(memory: FitnessCoachMemory) {
    const content = editContent.trim();
    const category = editCategory.trim();
    if (!content || !online || memoryBusy) return;
    setMemoryBusy(memory.id);
    setDataError(null);
    try {
      const updated = await api<FitnessCoachMemory>(`/fitness/coach/memories/${encodeURIComponent(memory.id)}`, {
        method: "PATCH",
        body: JSON.stringify({ content, category: category || null }),
      }, true, false);
      setMemories((current) => current.map((item) => item.id === memory.id ? updated : item));
      setEditingMemory(null);
      setNotice("Memory updated.");
      onStoredDataChanged();
    } catch (requestError) {
      setDataError(errorMessage(requestError));
    } finally {
      setMemoryBusy(null);
    }
  }

  async function forgetMemory(id: string) {
    if (!online || memoryBusy) return;
    setMemoryBusy(id);
    setDataError(null);
    try {
      await api<void>(`/fitness/coach/memories/${encodeURIComponent(id)}`, { method: "DELETE" }, true, false);
      setMemories((current) => current.filter((memory) => memory.id !== id));
      setMemoryToForget(null);
      setNotice("Memory forgotten.");
      onStoredDataChanged();
    } catch (requestError) {
      setDataError(errorMessage(requestError));
    } finally {
      setMemoryBusy(null);
    }
  }

  async function clearStoredMemory() {
    if (!online || memoryBusy) return;
    setMemoryBusy("clear");
    setDataError(null);
    try {
      const result = await api<FitnessCoachMemoryClearResponse>("/fitness/coach/memory/clear", { method: "POST" }, true, false);
      setConversations([]);
      setMemories([]);
      setClearConfirm(false);
      onNewConversation(null);
      onStoredDataChanged();
      setNotice(`Cleared ${result.conversations} saved ${result.conversations === 1 ? "conversation" : "conversations"} and ${result.memories} confirmed ${result.memories === 1 ? "memory" : "memories"}. The current page chat was cleared too.`);
    } catch (requestError) {
      setDataError(errorMessage(requestError));
    } finally {
      setMemoryBusy(null);
    }
  }

  return <FitnessCard title="Conversation memory" detail="Private memory on your HausKlar NUC. Nothing is remembered unless you switch it on or confirm a suggested memory." className="is-wide fitness-module__coach-memory-card">
    {settingsLoading ? <p className="fitness-module__form-status" role="status"><LoaderCircle className="is-spinning" aria-hidden="true" size={16} /> Checking conversation memory…</p> : null}
    {settingsError ? <div className="fitness-module__notice fitness-module__notice--error" role="alert"><span>{settingsError}</span>{online ? <button type="button" className="button button--secondary" onClick={() => setSettingsNonce((value) => value + 1)}>Try again</button> : null}</div> : null}
    {!online && !settingsLoading ? <div className="fitness-module__notice" role="status">Reconnect to check or change private conversation storage. Any chat already open remains in this page.</div> : null}

    {!settingsLoading && !settingsError && online && !settings?.enabled && !promptSeen ? <div className="fitness-module__coach-memory-choice">
      <span className="fitness-module__cycle-icon" aria-hidden="true"><LockKeyhole size={20} /></span>
      <div><strong>Save Coach conversations privately on your NUC?</strong><p>Off by default. Turning it on lets this account resume chats and explicitly confirm useful memories. Other signed-in accounts cannot see them.</p></div>
      <div className="fitness-module__button-row"><button type="button" className="button button--primary" disabled={settingsBusy} onClick={() => void setMemoryEnabled(true)}>Turn on memory</button><button type="button" className="button button--secondary" onClick={keepTemporary}>Keep chats temporary</button></div>
    </div> : null}

    {!settingsLoading && !settingsError && (!online || promptSeen || settings?.enabled) ? <div className="fitness-module__coach-memory-status">
      <span className={settings?.enabled ? "is-enabled" : undefined} aria-hidden="true">{settings?.enabled ? <Check size={16} /> : <LockKeyhole size={16} />}</span>
      <div><strong>{settings?.enabled ? "Private conversation memory on" : "Temporary chat"}</strong><small>{settings?.enabled ? "Saved for this account on your NUC" : "Conversation stays in this page only"}</small></div>
      {online ? <button type="button" className="button button--secondary button--compact" disabled={settingsBusy} onClick={() => void setMemoryEnabled(!settings?.enabled)}>{settings?.enabled ? "Turn off" : "Turn on"}</button> : null}
    </div> : null}

    {notice ? <p className="fitness-module__form-status is-saved" role="status">{notice}</p> : null}
    {dataError ? <div className="fitness-module__notice fitness-module__notice--error" role="alert"><span>{dataError}</span>{settings && online ? <button type="button" className="button button--secondary" onClick={reloadData}>Try again</button> : null}</div> : null}

    {!settingsLoading && !settingsError && promptSeen ? <div className="fitness-module__coach-memory-actions">
      <button type="button" className="button button--secondary" disabled={conversationBusy !== null || !online} onClick={() => void startNewConversation()}>{conversationBusy === "new" ? <LoaderCircle className="is-spinning" aria-hidden="true" size={16} /> : <MessageCirclePlus aria-hidden="true" size={16} />} {settings?.enabled ? "New chat" : "New temporary chat"}</button>
      {!online ? <small>Reconnect to start or resume Coach.</small> : null}
    </div> : null}

    {settings && (settings.enabled || dataLoading || conversations.length > 0 || memories.length > 0) ? <>
      <details className="fitness-module__coach-memory-details" open={recentOpen} onToggle={(event) => setRecentOpen(event.currentTarget.open)}>
        <summary><span><Clock3 aria-hidden="true" size={17} /> Recent conversations <small>{conversations.length}</small></span><ChevronRight aria-hidden="true" size={17} /></summary>
        {!settings.enabled && conversations.length ? <p className="fitness-module__muted">Saved conversations remain private while memory is off. Open one as a read-only copy; any new reply stays temporary and does not update it.</p> : null}
        {dataLoading ? <p className="fitness-module__form-status" role="status"><LoaderCircle className="is-spinning" aria-hidden="true" size={16} /> Loading saved conversations…</p> : conversations.length ? <ul className="fitness-module__coach-conversation-list">{conversations.slice(0, 12).map((conversation) => <li className={conversation.id === activeConversationId ? "is-active" : undefined} key={conversation.id}>
          <button type="button" disabled={conversationBusy !== null} aria-current={conversation.id === activeConversationId ? "true" : undefined} onClick={() => void openConversation(conversation.id)}><strong>{conversationTitle(conversation)}</strong><small>{conversation.last_message_at ? formatFitnessDateTime(conversation.last_message_at) : "No messages yet"}</small></button>
          {conversationToDelete === conversation.id ? <span className="fitness-module__coach-memory-confirm"><span>Delete?</span><button type="button" onClick={() => setConversationToDelete(null)}>Cancel</button><button type="button" className="is-danger" disabled={conversationBusy !== null} onClick={() => void deleteConversation(conversation.id)}>Delete</button></span> : <button type="button" className="icon-button" aria-label={`Delete conversation ${conversationTitle(conversation)}`} onClick={() => setConversationToDelete(conversation.id)}><Trash2 aria-hidden="true" size={15} /></button>}
        </li>)}</ul> : <div className="fitness-module__empty"><MessageCirclePlus aria-hidden="true" size={22} /><strong>No saved conversations yet</strong><span>{settings.enabled ? "Start a new chat or send a message; only this account can resume it." : "Memory is off, so new chats stay temporary."}</span></div>}
      </details>

      <details className="fitness-module__coach-memory-details">
        <summary><span><ShieldCheck aria-hidden="true" size={17} /> What Coach remembers <small>{memories.length}</small></span><ChevronRight aria-hidden="true" size={17} /></summary>
        <div className="fitness-module__coach-memory-manager">
          <p>{settings.enabled ? "Only items you explicitly remembered appear here. Edit or forget them at any time." : "Existing confirmed memories remain private while memory is off. You can still edit, forget, or clear them."}</p>
          {settings.enabled ? (addingMemory ? <form className="fitness-module__coach-memory-form" onSubmit={(event) => { event.preventDefault(); void addMemory(); }}><label className="fitness-module__field">Memory<textarea required maxLength={1_000} value={newContent} onChange={(event) => setNewContent(event.target.value)} /></label><label className="fitness-module__field">Category (optional)<input type="text" maxLength={80} value={newCategory} onChange={(event) => setNewCategory(event.target.value)} /></label><div className="fitness-module__button-row"><button type="submit" className="button button--primary" disabled={!newContent.trim() || memoryBusy !== null}>Remember</button><button type="button" className="button button--secondary" onClick={() => { setAddingMemory(false); setNewContent(""); setNewCategory(""); }}>Cancel</button></div></form> : <button type="button" className="button button--secondary button--compact" onClick={() => setAddingMemory(true)}><Plus aria-hidden="true" size={15} /> Add memory</button>) : null}
          {memories.length ? <ul className="fitness-module__coach-memory-list">{memories.map((memory) => <li key={memory.id}>
            {editingMemory === memory.id ? <form className="fitness-module__coach-memory-form" onSubmit={(event) => { event.preventDefault(); void saveMemory(memory); }}><label className="fitness-module__field">Memory<textarea required maxLength={1_000} value={editContent} onChange={(event) => setEditContent(event.target.value)} /></label><label className="fitness-module__field">Category (optional)<input type="text" maxLength={80} value={editCategory} onChange={(event) => setEditCategory(event.target.value)} /></label><div className="fitness-module__button-row"><button type="submit" className="button button--primary" disabled={!editContent.trim() || memoryBusy !== null}>Save</button><button type="button" className="button button--secondary" onClick={() => setEditingMemory(null)}>Cancel</button></div></form> : <><div><span className="fitness-module__pill is-neutral">{memoryCategory(memory.category)}</span><p>{memory.content}</p></div>{memoryToForget === memory.id ? <span className="fitness-module__coach-memory-confirm"><span>Forget?</span><button type="button" onClick={() => setMemoryToForget(null)}>Cancel</button><button type="button" className="is-danger" disabled={memoryBusy !== null} onClick={() => void forgetMemory(memory.id)}>Forget</button></span> : <span className="fitness-module__coach-memory-row-actions"><button type="button" className="icon-button" aria-label={`Edit memory ${memory.content}`} onClick={() => beginEdit(memory)}><Edit3 aria-hidden="true" size={15} /></button><button type="button" className="icon-button" aria-label={`Forget memory ${memory.content}`} onClick={() => setMemoryToForget(memory.id)}><Trash2 aria-hidden="true" size={15} /></button></span>}</>}
          </li>)}</ul> : !dataLoading ? <p className="fitness-module__muted">Nothing confirmed yet.</p> : null}
          <div className="fitness-module__coach-memory-clear">{clearConfirm ? <div role="group" aria-label="Confirm clear Coach memory"><p>Delete every saved Coach conversation, stored message, and confirmed memory for this account? This cannot be undone.</p><div className="fitness-module__button-row"><button type="button" className="button button--secondary" onClick={() => setClearConfirm(false)}>Cancel</button><button type="button" className="button button--danger" disabled={memoryBusy !== null} onClick={() => void clearStoredMemory()}>{memoryBusy === "clear" ? "Clearing…" : "Clear all"}</button></div></div> : <button type="button" className="button button--secondary button--compact" onClick={() => setClearConfirm(true)}>Clear saved conversations and memories</button>}</div>
        </div>
      </details>
    </> : null}
  </FitnessCard>;
}

export function FitnessCoachMemoryCandidates({
  candidates,
  online,
  onRemember,
}: {
  candidates: FitnessCoachMemoryCandidate[];
  online: boolean;
  onRemember: (candidate: FitnessCoachMemoryCandidate) => Promise<void>;
}) {
  const [busy, setBusy] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  if (!candidates.length) return null;
  return <section className="fitness-module__coach-memory-candidates" aria-labelledby="fitness-coach-memory-candidates-title">
    <header><div><strong id="fitness-coach-memory-candidates-title">Worth remembering?</strong><small>Suggestions only. Nothing is saved until you choose Remember.</small></div></header>
    <div>{candidates.slice(0, 3).map((candidate) => {
      const key = `${candidate.category ?? "general"}:${candidate.content}`;
      return <article key={key}><span className="fitness-module__pill is-neutral">{memoryCategory(candidate.category)}</span><p>{candidate.content}</p><button type="button" className="button button--secondary button--compact" disabled={!online || busy !== null} onClick={() => { setBusy(key); setError(null); void onRemember(candidate).catch((requestError) => setError(errorMessage(requestError))).finally(() => setBusy(null)); }}>{busy === key ? <LoaderCircle className="is-spinning" aria-hidden="true" size={14} /> : <Check aria-hidden="true" size={14} />} Remember</button></article>;
    })}</div>
    {error ? <p className="fitness-module__form-status is-error" role="alert">{error}</p> : null}
  </section>;
}

export function storedCoachMessages(messages: FitnessCoachConversationMessage[]) {
  return messages.slice(-200).map((message) => ({
    id: message.id,
    role: message.role,
    content: message.content,
    evidence: message.evidence ?? [],
    recommendation: message.recommendation ?? null,
    proposal: message.proposal ?? null,
  }));
}
