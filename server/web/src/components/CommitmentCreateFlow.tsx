import {
  Baby,
  BrainCircuit,
  CalendarSearch,
  Check,
  MapPinned,
  RefreshCw,
  Search,
  Sparkles,
} from "lucide-react";
import { useEffect, useRef, useState, type FormEvent } from "react";

import { api, isOfflineQueuedResult, localISODateTime } from "../api";
import type {
  ChildcareGap,
  Commitment,
  CommitmentFromSourceResponse,
  CommitmentKind,
  CommitmentVisibility,
  FreeWindowQueryResponse,
} from "../commitments/contract";
import type { FamilyDocument, FamilyMember } from "../types";
import { useAIConsent } from "./AIConsent";
import { SkeletonList } from "./ui";

function useOnline(): boolean {
  const [online, setOnline] = useState(() => navigator.onLine);
  useEffect(() => {
    const update = () => setOnline(navigator.onLine);
    window.addEventListener("online", update);
    window.addEventListener("offline", update);
    return () => {
      window.removeEventListener("online", update);
      window.removeEventListener("offline", update);
    };
  }, []);
  return online;
}

function timezone(): string {
  return Intl.DateTimeFormat().resolvedOptions().timeZone || "Europe/London";
}

function localInput(date: Date): string {
  const offset = date.getTimezoneOffset() * 60_000;
  return new Date(date.getTime() - offset).toISOString().slice(0, 16);
}

function apiTime(value: string): string {
  return localISODateTime(new Date(value));
}

function defaultRange(): { start: string; end: string } {
  const start = new Date();
  start.setDate(start.getDate() + 1);
  start.setHours(9, 0, 0, 0);
  const end = new Date(start);
  end.setHours(18, 0, 0, 0);
  return { start: localInput(start), end: localInput(end) };
}

function defaultDate(days: number): string {
  const value = new Date();
  value.setDate(value.getDate() + days);
  return `${value.getFullYear()}-${String(value.getMonth() + 1).padStart(2, "0")}-${String(value.getDate()).padStart(2, "0")}`;
}

function errorCopy(error: unknown, fallback: string): string {
  return error instanceof Error ? error.message : fallback;
}

type SourceOperation = { fingerprint: string; id: string; timestamp: string };
type TypedOperation = { id: string; sourceID: string; eventID: string; timestamp: string };

function sourceOperation(ref: React.MutableRefObject<SourceOperation | null>, fingerprint: string): SourceOperation {
  if (!ref.current || ref.current.fingerprint !== fingerprint) {
    ref.current = { fingerprint, id: crypto.randomUUID(), timestamp: new Date().toISOString() };
  }
  return ref.current;
}

function VisibilityChoice({
  idPrefix,
  value,
  onChange,
}: {
  idPrefix: string;
  value: CommitmentVisibility;
  onChange: (value: CommitmentVisibility) => void;
}) {
  return (
    <fieldset className="commitment-visibility-choice">
      <legend>Who can see this plan?</legend>
      <div>
        <label htmlFor={`${idPrefix}-family`}>
          <input id={`${idPrefix}-family`} type="radio" name={`${idPrefix}-visibility`} value="family" checked={value === "family"} onChange={() => onChange("family")} />
          <span><strong>Family</strong><small>Everyone in the family can review it. Confirmation can create shared calendar and task items.</small></span>
        </label>
        <label htmlFor={`${idPrefix}-owner`}>
          <input id={`${idPrefix}-owner`} type="radio" name={`${idPrefix}-visibility`} value="owner" checked={value === "owner"} onChange={() => onChange("owner")} />
          <span><strong>Just me</strong><small>Keep the draft private. Share it later before confirming calendar or task items.</small></span>
        </label>
      </div>
    </fieldset>
  );
}

export function CommitmentCreateFlow({
  kind,
  members,
  openPlans = [],
  onCreated,
  onQueued,
}: {
  kind: CommitmentKind;
  members: FamilyMember[];
  openPlans?: Commitment[];
  onCreated: (commitment: Commitment, notice?: string) => void;
  onQueued: (message: string) => void;
}) {
  if (kind === "outing") return <OutingCreate members={members} onCreated={onCreated} onQueued={onQueued} />;
  if (kind === "childcare") return <ChildcareCreate members={members} onCreated={onCreated} onQueued={onQueued} />;
  return <SourceCreate kind={kind} openPlans={openPlans.filter((plan) => plan.kind === kind)} onCreated={onCreated} />;
}

function SourceCreate({
  kind,
  openPlans,
  onCreated,
}: {
  kind: Exclude<CommitmentKind, "outing" | "childcare">;
  openPlans: Commitment[];
  onCreated: (commitment: Commitment, notice?: string) => void;
}) {
  const online = useOnline();
  const aiConsent = useAIConsent(true);
  const [documents, setDocuments] = useState<FamilyDocument[]>([]);
  const [documentsLoading, setDocumentsLoading] = useState(true);
  const [title, setTitle] = useState("");
  const [text, setText] = useState("");
  const [documentID, setDocumentID] = useState("");
  const [sourceLabel, setSourceLabel] = useState("");
  const [reference, setReference] = useState("");
  const [visibility, setVisibility] = useState<CommitmentVisibility>("family");
  const [supersedesID, setSupersedesID] = useState("");
  const [useHermes, setUseHermes] = useState(false);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const operation = useRef<SourceOperation | null>(null);
  const eligibleOpenPlans = openPlans.filter((plan) => plan.visibility === visibility);

  useEffect(() => {
    let active = true;
    setDocumentsLoading(true);
    void api<FamilyDocument[]>("/documents/?offset=0&limit=100")
      .then((loaded) => { if (active && Array.isArray(loaded)) setDocuments(loaded.filter((item) => item.status !== "archived")); })
      .catch(() => undefined)
      .finally(() => { if (active) setDocumentsLoading(false); });
    return () => { active = false; };
  }, []);

  useEffect(() => {
    if (!aiConsent.status?.consented) setUseHermes(false);
  }, [aiConsent.status?.consented]);

  function chooseDocument(id: string) {
    setDocumentID(id);
    const selected = documents.find((document) => document.id === id);
    if (selected?.extracted_text && !text.trim()) setText(selected.extracted_text);
    if (selected?.title && !title.trim()) setTitle(selected.title);
  }

  function chooseVisibility(nextVisibility: CommitmentVisibility) {
    setVisibility(nextVisibility);
    setSupersedesID((current) => (
      current && !openPlans.some((plan) => plan.id === current && plan.visibility === nextVisibility)
        ? ""
        : current
    ));
  }

  async function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (!online) {
      setError("Reconnect to interpret this reviewed source. Nothing has been sent or saved yet.");
      return;
    }
    if (!text.trim()) {
      setError("Review the source text before creating the plan.");
      return;
    }
    const fingerprint = JSON.stringify({ kind, title: title.trim(), text: text.trim(), documentID, sourceLabel: sourceLabel.trim(), reference: reference.trim(), visibility, supersedesID, useHermes });
    const requestOperation = sourceOperation(operation, fingerprint);
    setBusy(true);
    setError(null);
    try {
      const response = await api<CommitmentFromSourceResponse>(
        "/commitments/from-source",
        {
          method: "POST",
          body: JSON.stringify({
            id: requestOperation.id,
            kind,
            visibility,
            text: text.trim(),
            source_document_id: documentID || null,
            source_label: sourceLabel.trim() || "Reviewed message",
            provider_reference: reference.trim() || null,
            title: title.trim() || null,
            use_hermes: useHermes,
            client_now: requestOperation.timestamp,
            timezone: timezone(),
            supersedes_id: supersedesID || null,
            client_id: "hausklar-web",
            client_timestamp: requestOperation.timestamp,
          }),
        },
        true,
        false,
      );
      const processing = response.deduplicated
        ? "This source was already reviewed, so HausKlar reopened the existing plan. Nothing was duplicated."
        : response.warning
        ?? (response.processor === "hermes" ? "Bismarck helped interpret the reviewed text. Every result still needs your confirmation." : "HausKlar used its private basic parser. Check every date before confirming.");
      onCreated(response.commitment, processing);
    } catch (requestError) {
      setError(errorCopy(requestError, "That source could not be turned into a plan."));
    } finally {
      setBusy(false);
    }
  }

  return (
    <form className="commitment-source-form" aria-busy={busy} onSubmit={(event) => void submit(event)}>
      <header className="commitments-section-heading is-compact">
        <span><Sparkles aria-hidden="true" size={20} /></span>
        <div><h2>Review the {kind === "travel" ? "booking" : "message"}</h2><p>The text stays editable. HausKlar creates a draft only; it does not add calendar items yet.</p></div>
      </header>
      {!online ? <p className="commitments-offline" role="status">You’re offline. Reconnect before interpreting a message or document.</p> : null}
      <VisibilityChoice idPrefix="source-plan" value={visibility} onChange={chooseVisibility} />
      <div className="commitment-form-grid">
        <div className="field is-wide"><label htmlFor="commitment-source-title">Plan title <span>(optional)</span></label><input id="commitment-source-title" value={title} maxLength={300} placeholder={kind === "travel" ? "Summer trip to Germany" : "HausKlar can suggest this"} onChange={(event) => setTitle(event.target.value)} /></div>
        <div className="field"><label htmlFor="commitment-source-document">Source document <span>(optional)</span></label><select id="commitment-source-document" value={documentID} disabled={documentsLoading} onChange={(event) => chooseDocument(event.target.value)}><option value="">No attached document</option>{documents.map((document) => <option value={document.id} key={document.id}>{document.title}</option>)}</select></div>
        <div className="field"><label htmlFor="commitment-source-label">Source name <span>(optional)</span></label><input id="commitment-source-label" value={sourceLabel} maxLength={300} placeholder="School email" onChange={(event) => setSourceLabel(event.target.value)} /></div>
        <div className="field is-wide"><label htmlFor="commitment-source-reference">{kind === "travel" ? "Booking or trip reference" : "Message reference"} <span>(optional)</span></label><input id="commitment-source-reference" value={reference} maxLength={300} placeholder={kind === "travel" ? "BA booking ABC123 — groups this trip" : "Email subject or reference"} onChange={(event) => setReference(event.target.value)} /></div>
        {eligibleOpenPlans.length ? <div className="field is-wide"><label htmlFor="commitment-supersedes">This updates an existing plan <span>(optional)</span></label><select id="commitment-supersedes" value={supersedesID} onChange={(event) => setSupersedesID(event.target.value)}><option value="">This is a new plan</option>{eligibleOpenPlans.map((plan) => <option value={plan.id} key={plan.id}>{plan.title}</option>)}</select><small>Only plans with the same privacy are shown. Choose one when this message replaces or changes its details.</small></div> : null}
        <div className="field is-wide"><label htmlFor="commitment-source-text">Reviewed text</label><textarea id="commitment-source-text" value={text} rows={10} maxLength={100000} required placeholder="Paste the message, then correct anything that was copied badly…" onChange={(event) => setText(event.target.value)} /></div>
      </div>
      <label className="commitment-hermes-choice">
        <input type="checkbox" checked={useHermes} disabled={!online || aiConsent.loading || !aiConsent.status?.consented} onChange={(event) => setUseHermes(event.target.checked)} />
        <BrainCircuit aria-hidden="true" size={19} />
        <span><strong>Ask Bismarck to interpret this text</strong><small>{aiConsent.status?.consented ? "Off by default. Runs only for this message when you choose it." : "Off. External AI permission has not been granted in Privacy & AI settings."}</small></span>
      </label>
      {error ? <p className="form-error" role="alert">{error}</p> : null}
      <div className="commitment-form-actions"><button type="submit" className="button button--primary" disabled={busy || !online}>{busy ? "Creating draft…" : "Create plan to review"}</button></div>
    </form>
  );
}

function OutingCreate({
  members,
  onCreated,
  onQueued,
}: {
  members: FamilyMember[];
  onCreated: (commitment: Commitment, notice?: string) => void;
  onQueued: (message: string) => void;
}) {
  const online = useOnline();
  const initial = useRef(defaultRange()).current;
  const [personIDs, setPersonIDs] = useState<string[]>([]);
  const [rangeStart, setRangeStart] = useState(initial.start);
  const [rangeEnd, setRangeEnd] = useState(initial.end);
  const [minimumMinutes, setMinimumMinutes] = useState("60");
  const [candidateName, setCandidateName] = useState("");
  const [candidateStart, setCandidateStart] = useState(initial.start);
  const [candidateEnd, setCandidateEnd] = useState(initial.end);
  const [candidateMinutes, setCandidateMinutes] = useState("120");
  const [location, setLocation] = useState("");
  const [bookingURL, setBookingURL] = useState("");
  const [visibility, setVisibility] = useState<CommitmentVisibility>("family");
  const [results, setResults] = useState<FreeWindowQueryResponse | null>(null);
  const [busy, setBusy] = useState(false);
  const [savingID, setSavingID] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const candidateID = useRef(crypto.randomUUID());
  const createOperations = useRef(new Map<string, TypedOperation>());

  function invalidateResults() {
    setResults(null);
    setError(null);
  }

  function togglePerson(id: string) {
    setPersonIDs((current) => current.includes(id) ? current.filter((value) => value !== id) : [...current, id]);
    invalidateResults();
  }

  function outingOperationKey(result: FreeWindowQueryResponse["viable_outings"][number]): string {
    return JSON.stringify({
      candidate_id: result.candidate_id,
      title: result.title,
      proposed_start: result.proposed_start,
      proposed_end: result.proposed_end,
      location: result.location ?? null,
      booking_url: result.booking_url ?? null,
      person_ids: [...personIDs].sort(),
      visibility,
    });
  }

  async function search(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (!online) {
      setError("Reconnect to check the family calendar.");
      return;
    }
    if (!personIDs.length) {
      setError("Choose at least one person whose calendar needs to be free.");
      return;
    }
    setBusy(true);
    setError(null);
    setResults(null);
    try {
      setResults(await api<FreeWindowQueryResponse>("/commitments/free-windows/query", {
        method: "POST",
        body: JSON.stringify({
          start_time: apiTime(rangeStart),
          end_time: apiTime(rangeEnd),
          person_ids: [...personIDs].sort(),
          minimum_minutes: Number(minimumMinutes),
          candidates: [{
            id: candidateID.current,
            title: candidateName.trim(),
            available_start: apiTime(candidateStart),
            available_end: apiTime(candidateEnd),
            duration_minutes: Number(candidateMinutes),
            location: location.trim() || null,
            booking_url: bookingURL.trim() || null,
          }],
          timezone: timezone(),
        }),
      }, true, false));
    } catch (requestError) {
      setError(errorCopy(requestError, "Free time could not be checked."));
    } finally {
      setBusy(false);
    }
  }

  async function useOuting(result: FreeWindowQueryResponse["viable_outings"][number]) {
    const key = outingOperationKey(result);
    const ids = createOperations.current.get(key) ?? { id: crypto.randomUUID(), sourceID: crypto.randomUUID(), eventID: crypto.randomUUID(), timestamp: new Date().toISOString() };
    createOperations.current.set(key, ids);
    setSavingID(key);
    setError(null);
    const now = ids.timestamp;
    try {
      const saved = await api<Commitment>("/commitments/", {
        method: "POST",
        offlineOperationId: ids.id,
        body: JSON.stringify({
          id: ids.id,
          kind: "outing",
          visibility,
          title: result.title,
          summary: `A possible family outing found against the selected calendars.`,
          sources: [{ id: ids.sourceID, kind: result.booking_url ? "provider" : "manual", label: result.title, provider_reference: result.candidate_id, source_url: result.booking_url ?? null, observed_at: now }],
          plan: {
            events: [{ id: ids.eventID, title: result.title, description: null, start_time: result.proposed_start, end_time: result.proposed_end, all_day: false, location: result.location ?? null, person_ids: [...personIDs].sort(), affected_adult_ids: [], assigned_to: null, event_type: "outing", document_ids: [] }],
            tasks: [],
            preparations: [],
            external_action: result.booking_url ? { kind: "book", label: `Book ${result.title}`, target_type: "https", target: result.booking_url, due_at: null, requires_completion_before_confirm: true } : null,
          },
          group_key: null,
          client_id: "hausklar-web",
          client_timestamp: now,
        }),
      });
      if (isOfflineQueuedResult(saved)) onQueued("The outing draft is saved on this device and will appear here after it syncs.");
      else onCreated(saved);
    } catch (requestError) {
      setError(errorCopy(requestError, "That outing draft could not be saved."));
    } finally {
      setSavingID(null);
    }
  }

  return (
    <form className="commitment-search-form" aria-busy={busy} onSubmit={(event) => void search(event)}>
      <header className="commitments-section-heading is-compact"><span><MapPinned aria-hidden="true" size={20} /></span><div><h2>Find a family outing time</h2><p>HausKlar checks the selected calendars, then offers only a candidate that fits.</p></div></header>
      {!online ? <p className="commitments-offline" role="status">Reconnect to search family calendars. A search cannot be queued.</p> : null}
      <VisibilityChoice idPrefix="outing-plan" value={visibility} onChange={setVisibility} />
      <fieldset className="commitment-people"><legend>Who needs to be free?</legend><div>{members.map((member) => <label key={member.id}><input type="checkbox" checked={personIDs.includes(member.id)} onChange={() => togglePerson(member.id)} /><span>{member.name}</span></label>)}</div></fieldset>
      <div className="commitment-form-grid">
        <div className="field"><label htmlFor="outing-range-start">Search from</label><input id="outing-range-start" type="datetime-local" required value={rangeStart} onChange={(event) => { setRangeStart(event.target.value); invalidateResults(); }} /></div>
        <div className="field"><label htmlFor="outing-range-end">Search until</label><input id="outing-range-end" type="datetime-local" required value={rangeEnd} onChange={(event) => { setRangeEnd(event.target.value); invalidateResults(); }} /></div>
        <div className="field"><label htmlFor="outing-minimum">Minimum free time</label><select id="outing-minimum" value={minimumMinutes} onChange={(event) => { setMinimumMinutes(event.target.value); invalidateResults(); }}><option value="30">30 minutes</option><option value="60">1 hour</option><option value="120">2 hours</option><option value="180">3 hours</option></select></div>
      </div>
      <fieldset className="commitment-candidate"><legend>Place or activity to try</legend><div className="commitment-form-grid">
        <div className="field is-wide"><label htmlFor="outing-name">Name</label><input id="outing-name" required value={candidateName} placeholder="Example Town Castle" onChange={(event) => { setCandidateName(event.target.value); invalidateResults(); }} /></div>
        <div className="field"><label htmlFor="outing-available-start">Available from</label><input id="outing-available-start" type="datetime-local" required value={candidateStart} onChange={(event) => { setCandidateStart(event.target.value); invalidateResults(); }} /></div>
        <div className="field"><label htmlFor="outing-available-end">Available until</label><input id="outing-available-end" type="datetime-local" required value={candidateEnd} onChange={(event) => { setCandidateEnd(event.target.value); invalidateResults(); }} /></div>
        <div className="field"><label htmlFor="outing-duration">Visit length</label><select id="outing-duration" value={candidateMinutes} onChange={(event) => { setCandidateMinutes(event.target.value); invalidateResults(); }}><option value="60">1 hour</option><option value="90">1½ hours</option><option value="120">2 hours</option><option value="180">3 hours</option><option value="240">4 hours</option></select></div>
        <div className="field"><label htmlFor="outing-location">Location <span>(optional)</span></label><input id="outing-location" value={location} onChange={(event) => { setLocation(event.target.value); invalidateResults(); }} /></div>
        <div className="field is-wide"><label htmlFor="outing-booking">Booking page <span>(optional)</span></label><input id="outing-booking" type="url" inputMode="url" autoComplete="url" value={bookingURL} placeholder="https://…" onChange={(event) => { setBookingURL(event.target.value); invalidateResults(); }} /></div>
      </div></fieldset>
      {error ? <p className="form-error" role="alert">{error}</p> : null}
      <button type="submit" className="button button--primary" disabled={!online || busy}><Search aria-hidden="true" size={17} /> {busy ? "Checking calendars…" : "Find a time"}</button>
      {results ? <section className="commitment-search-results" aria-live="polite"><h3>Times that work</h3>{results.viable_outings.length ? <div>{results.viable_outings.map((result) => {
        const resultKey = outingOperationKey(result);
        return <article key={resultKey}><CalendarSearch aria-hidden="true" size={20} /><span><strong>{result.title}</strong><small>{new Date(result.proposed_start).toLocaleString("en-GB", { weekday: "short", day: "numeric", month: "short", hour: "2-digit", minute: "2-digit" })} · {Math.round((new Date(result.proposed_end).getTime() - new Date(result.proposed_start).getTime()) / 60000)} min{result.location ? ` · ${result.location}` : ""}</small></span><button type="button" className="button button--primary" disabled={savingID !== null} onClick={() => void useOuting(result)}>{savingID === resultKey ? "Saving…" : "Use this time"}</button></article>;
      })}</div> : <p>No candidate fits the selected calendars. Adjust the range or availability and search again.</p>}</section> : null}
    </form>
  );
}

function ChildcareCreate({
  members,
  onCreated,
  onQueued,
}: {
  members: FamilyMember[];
  onCreated: (commitment: Commitment, notice?: string) => void;
  onQueued: (message: string) => void;
}) {
  const online = useOnline();
  const children = members.filter((member) => member.member_type === "child");
  const [childID, setChildID] = useState(children[0]?.id ?? "");
  const [fromDate, setFromDate] = useState(defaultDate(0));
  const [toDate, setToDate] = useState(defaultDate(90));
  const [gaps, setGaps] = useState<ChildcareGap[] | null>(null);
  const [visibility, setVisibility] = useState<CommitmentVisibility>("family");
  const [busy, setBusy] = useState(false);
  const [savingDate, setSavingDate] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const operations = useRef(new Map<string, TypedOperation>());

  function invalidateGaps() {
    setGaps(null);
    setError(null);
  }

  async function find(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (!online) {
      setError("Reconnect to compare term dates with the family calendar.");
      return;
    }
    setBusy(true);
    setError(null);
    setGaps(null);
    try {
      const query = new URLSearchParams({ child_id: childID, from: fromDate, to: toDate, timezone: timezone() });
      let readSource: "network" | "cache" = "network";
      const loaded = await api<ChildcareGap[]>(`/commitments/childcare-gaps?${query.toString()}`, {
        cache: "reload",
        onReadSource: (source) => { readSource = source; },
      }, true, false);
      if (readSource !== "network") throw new Error("Reconnect to check childcare gaps against the current family calendar.");
      setGaps(loaded);
    } catch (requestError) {
      setError(errorCopy(requestError, "Childcare gaps could not be checked."));
    } finally {
      setBusy(false);
    }
  }

  async function chooseGap(gap: ChildcareGap) {
    const operationKey = JSON.stringify({ child_id: childID, date: gap.date, label: gap.label, source: gap.source, visibility });
    const ids = operations.current.get(operationKey) ?? { id: crypto.randomUUID(), sourceID: crypto.randomUUID(), eventID: crypto.randomUUID(), timestamp: new Date().toISOString() };
    operations.current.set(operationKey, ids);
    const child = children.find((member) => member.id === childID);
    const now = ids.timestamp;
    setSavingDate(gap.date);
    setError(null);
    try {
      const saved = await api<Commitment>("/commitments/", {
        method: "POST",
        offlineOperationId: ids.id,
        body: JSON.stringify({
          id: ids.id,
          kind: "childcare",
          visibility,
          title: `Childcare for ${child?.name ?? "child"}`,
          summary: `${gap.label} on ${gap.date} does not yet have full-day childcare coverage.`,
          sources: [{ id: ids.sourceID, kind: "manual", label: `${gap.label} gap check`, provider_reference: gap.source, observed_at: now }],
          plan: {
            events: [{ id: ids.eventID, title: `Childcare for ${child?.name ?? "child"}`, description: gap.label, start_time: gap.date, end_time: null, all_day: true, location: null, person_ids: [childID], affected_adult_ids: [], assigned_to: null, event_type: "childcare", document_ids: [] }],
            tasks: [], preparations: [], external_action: null,
          },
          group_key: null,
          client_id: "hausklar-web",
          client_timestamp: now,
        }),
      });
      if (isOfflineQueuedResult(saved)) onQueued("The childcare draft is saved on this device and will appear here after it syncs.");
      else onCreated(saved);
    } catch (requestError) {
      setError(errorCopy(requestError, "That childcare draft could not be saved."));
    } finally {
      setSavingDate(null);
    }
  }

  return (
    <form className="commitment-search-form" aria-busy={busy} onSubmit={(event) => void find(event)}>
      <header className="commitments-section-heading is-compact"><span><Baby aria-hidden="true" size={20} /></span><div><h2>Find a childcare gap</h2><p>HausKlar checks school holidays and existing childcare coverage. Nothing is booked automatically.</p></div></header>
      {!online ? <p className="commitments-offline" role="status">Reconnect to search term dates and calendar coverage. A search cannot be queued.</p> : null}
      <VisibilityChoice idPrefix="childcare-plan" value={visibility} onChange={setVisibility} />
      {!children.length ? <p className="commitments-offline">Add a child profile before checking childcare gaps.</p> : <div className="commitment-form-grid">
        <div className="field"><label htmlFor="childcare-child">Child</label><select id="childcare-child" value={childID} onChange={(event) => { setChildID(event.target.value); invalidateGaps(); }}>{children.map((child) => <option value={child.id} key={child.id}>{child.name}</option>)}</select></div>
        <div className="field"><label htmlFor="childcare-from">From</label><input id="childcare-from" type="date" required value={fromDate} onChange={(event) => { setFromDate(event.target.value); invalidateGaps(); }} /></div>
        <div className="field"><label htmlFor="childcare-to">To</label><input id="childcare-to" type="date" required value={toDate} onChange={(event) => { setToDate(event.target.value); invalidateGaps(); }} /></div>
      </div>}
      {error ? <p className="form-error" role="alert">{error}</p> : null}
      <button type="submit" className="button button--primary" disabled={!online || busy || !childID}><Search aria-hidden="true" size={17} /> {busy ? "Checking…" : "Find uncovered days"}</button>
      {busy ? <SkeletonList rows={3} /> : null}
      {gaps ? <section className="commitment-gap-results" aria-live="polite"><h3>{gaps.length ? `${gaps.length} uncovered ${gaps.length === 1 ? "day" : "days"}` : "No gaps found"}</h3>{gaps.length ? <div>{gaps.map((gap) => <article key={gap.date}><span><strong>{new Date(`${gap.date}T12:00:00`).toLocaleDateString("en-GB", { weekday: "long", day: "numeric", month: "long" })}</strong><small>{gap.label}</small></span><button type="button" className="button button--secondary" disabled={savingDate !== null} onClick={() => void chooseGap(gap)}>{savingDate === gap.date ? "Saving…" : <><Check aria-hidden="true" size={16} /> Plan childcare</>}</button></article>)}</div> : <p>The selected school-holiday dates already have explicit childcare coverage, or no term information covers this range.</p>}<button type="button" className="button button--secondary" onClick={() => setGaps(null)}><RefreshCw aria-hidden="true" size={16} /> Change search</button></section> : null}
    </form>
  );
}
