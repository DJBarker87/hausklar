import {
  AlertTriangle,
  Clock3,
  Copy,
  Eye,
  EyeOff,
  House,
  KeyRound,
  PawPrint,
  Phone,
  Plus,
  ShieldCheck,
  Trash2,
  UserRoundCheck,
  Wifi,
} from "lucide-react";
import { format, parseISO } from "date-fns";
import { useCallback, useEffect, useRef, useState, type FormEvent } from "react";

import { EmptyState, ErrorState, Modal, Segmented, SkeletonList } from "../components/ui";
import "./caregiver.css";

type HouseHandover = {
  address: string | null;
  wifi_name: string | null;
  wifi_password: string | null;
  emergency_instructions: string | null;
  house_instructions: string | null;
  dog_instructions: string | null;
};
type ChildHandover = {
  id?: string | null;
  child_id: string;
  child_name: string;
  care_notes: string | null;
  allergies: string | null;
  food: string | null;
  comfort: string | null;
  toileting: string | null;
  bedtime: string | null;
};
type ContactHandover = {
  id?: string;
  name: string;
  phone: string;
  relationship: string | null;
  priority: number;
};
type ReadinessItem = { key: string; label: string; ready: boolean; child_id?: string | null };
type Handover = {
  id?: string | null;
  house: HouseHandover;
  children: ChildHandover[];
  contacts: ContactHandover[];
  readiness: { ready: boolean; complete_count: number; total_count: number; items: ReadinessItem[] };
  updated_at?: string | null;
};
type Booking = {
  id: string;
  label: string;
  starts_at: string;
  expires_at: string;
  child_ids: string[];
  child_names: string[];
  status: "active" | "upcoming" | "expired" | "revoked";
  created_at: string;
  revoked_at?: string | null;
  last_accessed_at?: string | null;
};
type CreatedBooking = Booking & { share_url: string };

class CaregiverRequestError extends Error {
  constructor(message: string, readonly status: number) {
    super(message);
    this.name = "CaregiverRequestError";
  }
}

type SessionView = {
  booking: { label: string; starts_at: string; expires_at: string };
  now: {
    children: Array<{
      child_id: string;
      name: string;
      age: number;
      care_notes: string;
      allergies: string;
      food: string;
      comfort: string;
      toileting: string;
      bedtime: string;
    }>;
    active_naps: Array<{ child_name: string; started_at: string; location?: string | null }>;
    medicine_schedule: Array<{
      child_name: string;
      medicine_name: string;
      dosage_notes?: string | null;
      last_given_at?: string | null;
      last_given_by?: string | null;
      next_dose_allowed_at?: string | null;
    }>;
  };
  next: { events: Array<{ title: string; start_time: string; end_time: string; location?: string | null }> };
  emergency: {
    address: string;
    instructions: string;
    contacts: ContactHandover[];
    allergies: Array<{ child_name: string; details: string }>;
  };
  house: {
    wifi_name?: string | null;
    wifi_password: string;
    house_instructions: string;
    dog_instructions?: string | null;
  };
  read_only: true;
  medicine_disclaimer: string;
};

async function caregiverRequest<T>(path: string, init: RequestInit = {}): Promise<T> {
  const headers = new Headers(init.headers);
  if (init.body && !(init.body instanceof FormData)) headers.set("Content-Type", "application/json");
  const response = await fetch(`/api/babysitter${path}`, {
    ...init,
    headers,
    credentials: "include",
    cache: "no-store",
  });
  if (!response.ok) {
    const body = await response.json().catch(() => ({})) as { detail?: string };
    throw new CaregiverRequestError(
      body.detail || "The caregiver handover is unavailable.",
      response.status,
    );
  }
  if (response.status === 204) return undefined as T;
  return response.json() as Promise<T>;
}

function inputDateTime(date: Date): string {
  const local = new Date(date.getTime() - date.getTimezoneOffset() * 60_000);
  return local.toISOString().slice(0, 16);
}

function responseDraft(handover: Handover): Handover {
  return JSON.parse(JSON.stringify(handover)) as Handover;
}

export function CaregiverSetupView() {
  const [handover, setHandover] = useState<Handover | null>(null);
  const [bookings, setBookings] = useState<Booking[]>([]);
  const [draft, setDraft] = useState<Handover | null>(null);
  const [editing, setEditing] = useState(false);
  const [bookingOpen, setBookingOpen] = useState(false);
  const [createdBooking, setCreatedBooking] = useState<CreatedBooking | null>(null);
  const [bookingToRevoke, setBookingToRevoke] = useState<Booking | null>(null);
  const [bookingDraft, setBookingDraft] = useState(() => ({
    label: "Babysitter",
    startsAt: inputDateTime(new Date()),
    expiresAt: inputDateTime(new Date(Date.now() + 5 * 60 * 60 * 1_000)),
    childIds: [] as string[],
  }));
  const [loading, setLoading] = useState(true);
  const [working, setWorking] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [notice, setNotice] = useState<string | null>(null);
  const [showWifiPassword, setShowWifiPassword] = useState(false);

  const load = useCallback(async () => {
    setLoading(true);
    setError(null);
    try {
      const [nextHandover, nextBookings] = await Promise.all([
        caregiverRequest<Handover>("/handover"),
        caregiverRequest<Booking[]>("/bookings"),
      ]);
      setHandover(nextHandover);
      setDraft(responseDraft(nextHandover));
      setBookings(nextBookings);
      setBookingDraft((current) => ({
        ...current,
        childIds: current.childIds.length ? current.childIds : nextHandover.children.map((child) => child.child_id),
      }));
    } catch (requestError) {
      setError(requestError instanceof Error ? requestError.message : "The caregiver handover is unavailable.");
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => { void load(); }, [load]);

  async function saveHandover(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (!draft) return;
    setWorking("handover");
    setError(null);
    try {
      const saved = await caregiverRequest<Handover>("/handover", {
        method: "PUT",
        body: JSON.stringify({
          house: draft.house,
          children: draft.children.map(({ child_id, care_notes, allergies, food, comfort, toileting, bedtime }) => ({
            child_id, care_notes, allergies, food, comfort, toileting, bedtime,
          })),
          contacts: draft.contacts.map(({ name, phone, relationship, priority }) => ({ name, phone, relationship, priority })),
        }),
      });
      setHandover(saved);
      setDraft(responseDraft(saved));
      setEditing(false);
      setNotice(saved.readiness.ready ? "Handover ready." : "Saved. The readiness list shows what is still needed.");
    } catch (requestError) {
      setError(requestError instanceof Error ? requestError.message : "The handover could not be saved.");
    } finally {
      setWorking(null);
    }
  }

  async function createBooking(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    setWorking("booking");
    setError(null);
    try {
      const created = await caregiverRequest<CreatedBooking>("/bookings", {
        method: "POST",
        body: JSON.stringify({
          label: bookingDraft.label.trim(),
          starts_at: new Date(bookingDraft.startsAt).toISOString(),
          expires_at: new Date(bookingDraft.expiresAt).toISOString(),
          child_ids: bookingDraft.childIds,
        }),
      });
      setBookings((current) => [created, ...current]);
      setBookingOpen(false);
      setCreatedBooking(created);
    } catch (requestError) {
      setError(requestError instanceof Error ? requestError.message : "The caregiver link could not be created.");
    } finally {
      setWorking(null);
    }
  }

  async function revoke(booking: Booking) {
    setWorking(booking.id);
    setError(null);
    try {
      await caregiverRequest(`/bookings/${booking.id}`, { method: "DELETE" });
      setBookings((current) => current.map((item) => item.id === booking.id ? { ...item, status: "revoked" } : item));
      setBookingToRevoke(null);
      setNotice("Caregiver access revoked.");
    } catch (requestError) {
      setError(requestError instanceof Error ? requestError.message : "Caregiver access could not be revoked.");
    } finally {
      setWorking(null);
    }
  }

  function setHouse<K extends keyof HouseHandover>(key: K, value: HouseHandover[K]) {
    setDraft((current) => current ? { ...current, house: { ...current.house, [key]: value } } : current);
  }

  function setChild<K extends keyof ChildHandover>(childId: string, key: K, value: ChildHandover[K]) {
    setDraft((current) => current ? {
      ...current,
      children: current.children.map((child) => child.child_id === childId ? { ...child, [key]: value } : child),
    } : current);
  }

  const missing = handover?.readiness.items.filter((item) => !item.ready) ?? [];
  const activeBookings = bookings.filter((booking) => booking.status === "active" || booking.status === "upcoming");

  if (loading) return <div className="standard-page"><SkeletonList rows={7} /></div>;
  if (!handover || !draft) return <div className="standard-page"><ErrorState message={error ?? "The handover is unavailable."} retry={load} /></div>;

  const bookingMissing = handover.readiness.items.filter((item) => (
    !item.ready && (!item.child_id || bookingDraft.childIds.includes(item.child_id))
  ));
  const sharedDetailsReady = handover.readiness.items
    .filter((item) => !item.child_id)
    .every((item) => item.ready);
  const atLeastOneChildReady = handover.children.some((child) => handover.readiness.items
    .filter((item) => item.child_id === child.child_id)
    .every((item) => item.ready));
  const canStartBooking = sharedDetailsReady && atLeastOneChildReady;
  const bookingStarts = new Date(bookingDraft.startsAt).getTime();
  const bookingEnds = new Date(bookingDraft.expiresAt).getTime();
  const bookingWindowValid = Number.isFinite(bookingStarts)
    && Number.isFinite(bookingEnds)
    && bookingEnds > bookingStarts
    && bookingEnds > Date.now()
    && bookingEnds - bookingStarts <= 7 * 24 * 60 * 60 * 1_000;

  return (
    <div className="standard-page caregiver-setup-page">
      <header className="page-header"><div><p className="page-eyebrow">Ready when someone steps in</p><h1>Babysitter handover</h1><p>Parent-owned care details, shared only for one booking.</p></div></header>
      {error ? <ErrorState message={error} /> : null}
      {notice ? <p className="notice-banner" role="status">{notice}</p> : null}

      <section className={`caregiver-readiness ${handover.readiness.ready ? "is-ready" : ""}`}>
        <div><ShieldCheck aria-hidden="true" size={28} /><div><p className="page-eyebrow">Readiness</p><h2>{handover.readiness.ready ? "Ready to share" : `${handover.readiness.complete_count} of ${handover.readiness.total_count} ready`}</h2></div></div>
        {!handover.readiness.ready ? <div className="caregiver-missing">{missing.slice(0, 5).map((item) => <span key={item.key}>{item.label}</span>)}{missing.length > 5 ? <span>+{missing.length - 5} more</span> : null}</div> : <p>Everything required for a booking is present. You choose the children and exact access window next.</p>}
        <button type="button" className="button button--secondary" onClick={() => { setError(null); setEditing(true); }}>Edit handover</button>
      </section>

      <section className="routine-section caregiver-booking-section">
        <div className="section-heading"><div><p className="page-eyebrow">Share only when needed</p><h2>Bookings</h2></div><button type="button" className="button button--primary button--compact" disabled={!canStartBooking} onClick={() => { setError(null); setBookingOpen(true); }}><KeyRound aria-hidden="true" size={16} />Create sitter link</button></div>
        {!canStartBooking ? <p className="section-help">Finish the shared emergency details and at least one child's handover before creating access.</p> : null}
        {!activeBookings.length ? <EmptyState title="No open caregiver access" detail="Create a time-limited link when a sitter is due." /> : <div className="caregiver-booking-list">{activeBookings.map((booking) => <article key={booking.id}><div><strong>{booking.label}</strong><span>{booking.child_names.join(" & ")} · {format(parseISO(booking.starts_at), "d MMM, HH:mm")}–{format(parseISO(booking.expires_at), "HH:mm")}</span><small>{booking.status === "active" ? "Active now" : "Upcoming"}{booking.last_accessed_at ? ` · Opened ${format(parseISO(booking.last_accessed_at), "HH:mm")}` : " · Not opened"}</small></div><button type="button" className="button button--danger button--compact" disabled={working === booking.id} onClick={() => { setError(null); setBookingToRevoke(booking); }}>Revoke</button></article>)}</div>}
      </section>

      <details className="caregiver-past-access"><summary>Past and revoked access</summary><div>{bookings.filter((booking) => !activeBookings.includes(booking)).map((booking) => <p key={booking.id}><strong>{booking.label}</strong><span>{booking.status} · {format(parseISO(booking.expires_at), "d MMM yyyy, HH:mm")}</span></p>)}</div></details>

      <Modal open={editing} onOpenChange={setEditing} title="Edit babysitter handover" size="wide">
        <form className="form-stack caregiver-editor" onSubmit={saveHandover}>
          {error ? <p className="form-error" role="alert">{error}</p> : null}
          <div><p className="page-eyebrow">Children</p><h3>What helps each child</h3></div>
          {draft.children.map((child) => <fieldset className="caregiver-child-editor" key={child.child_id}><legend>{child.child_name}</legend><div className="form-grid"><div className="field"><label htmlFor={`care-${child.child_id}`}>Care and routine</label><textarea id={`care-${child.child_id}`} value={child.care_notes ?? ""} onChange={(event) => setChild(child.child_id, "care_notes", event.target.value)} /></div><div className="field"><label htmlFor={`allergies-${child.child_id}`}>Allergies (write “None known” if none)</label><textarea id={`allergies-${child.child_id}`} value={child.allergies ?? ""} onChange={(event) => setChild(child.child_id, "allergies", event.target.value)} /></div><div className="field"><label htmlFor={`food-${child.child_id}`}>Food and drinks</label><textarea id={`food-${child.child_id}`} value={child.food ?? ""} onChange={(event) => setChild(child.child_id, "food", event.target.value)} /></div><div className="field"><label htmlFor={`comfort-${child.child_id}`}>Comfort and calming</label><textarea id={`comfort-${child.child_id}`} value={child.comfort ?? ""} onChange={(event) => setChild(child.child_id, "comfort", event.target.value)} /></div><div className="field"><label htmlFor={`toileting-${child.child_id}`}>Toileting</label><textarea id={`toileting-${child.child_id}`} value={child.toileting ?? ""} onChange={(event) => setChild(child.child_id, "toileting", event.target.value)} /></div><div className="field"><label htmlFor={`bedtime-${child.child_id}`}>Bedtime</label><textarea id={`bedtime-${child.child_id}`} value={child.bedtime ?? ""} onChange={(event) => setChild(child.child_id, "bedtime", event.target.value)} /></div></div></fieldset>)}
          <div><p className="page-eyebrow">Home & emergency</p><h3>Only what the sitter needs</h3></div>
          <div className="form-grid"><div className="field"><label htmlFor="caregiver-address">Home address</label><textarea id="caregiver-address" value={draft.house.address ?? ""} onChange={(event) => setHouse("address", event.target.value)} /></div><div className="field"><label htmlFor="caregiver-emergency">Emergency instructions</label><textarea id="caregiver-emergency" value={draft.house.emergency_instructions ?? ""} onChange={(event) => setHouse("emergency_instructions", event.target.value)} /></div><div className="field"><label htmlFor="caregiver-house">House instructions</label><textarea id="caregiver-house" value={draft.house.house_instructions ?? ""} onChange={(event) => setHouse("house_instructions", event.target.value)} /></div><div className="field"><label htmlFor="caregiver-dog">Dog instructions (optional)</label><textarea id="caregiver-dog" value={draft.house.dog_instructions ?? ""} onChange={(event) => setHouse("dog_instructions", event.target.value)} /></div><div className="field"><label htmlFor="caregiver-wifi-name">Wi-Fi name (optional)</label><input id="caregiver-wifi-name" value={draft.house.wifi_name ?? ""} onChange={(event) => setHouse("wifi_name", event.target.value)} /></div><div className="field"><label htmlFor="caregiver-wifi-password">Wi-Fi password</label><div className="password-field"><input id="caregiver-wifi-password" type={showWifiPassword ? "text" : "password"} value={draft.house.wifi_password ?? ""} onChange={(event) => setHouse("wifi_password", event.target.value)} autoComplete="off" spellCheck={false} /><button type="button" className="password-toggle" aria-label={showWifiPassword ? "Hide Wi-Fi password" : "Show Wi-Fi password"} onClick={() => setShowWifiPassword((shown) => !shown)}>{showWifiPassword ? <EyeOff aria-hidden="true" size={18} /> : <Eye aria-hidden="true" size={18} />}</button></div></div></div>
          <div className="section-heading"><div><h3>Emergency contacts</h3></div><button type="button" className="button button--secondary button--compact" onClick={() => setDraft((current) => current ? { ...current, contacts: [...current.contacts, { name: "", phone: "", relationship: "", priority: current.contacts.length }] } : current)}><Plus aria-hidden="true" size={16} />Add contact</button></div>
          {draft.contacts.map((contact, index) => <div className="caregiver-contact-editor" key={contact.id ?? index}><div className="field"><label htmlFor={`contact-name-${index}`}>Name</label><input id={`contact-name-${index}`} value={contact.name} onChange={(event) => setDraft((current) => current ? { ...current, contacts: current.contacts.map((item, itemIndex) => itemIndex === index ? { ...item, name: event.target.value } : item) } : current)} required /></div><div className="field"><label htmlFor={`contact-phone-${index}`}>Phone</label><input id={`contact-phone-${index}`} type="tel" value={contact.phone} onChange={(event) => setDraft((current) => current ? { ...current, contacts: current.contacts.map((item, itemIndex) => itemIndex === index ? { ...item, phone: event.target.value } : item) } : current)} required /></div><div className="field"><label htmlFor={`contact-relation-${index}`}>Relationship</label><input id={`contact-relation-${index}`} value={contact.relationship ?? ""} onChange={(event) => setDraft((current) => current ? { ...current, contacts: current.contacts.map((item, itemIndex) => itemIndex === index ? { ...item, relationship: event.target.value } : item) } : current)} /></div><button type="button" className="icon-button icon-button--danger" aria-label={`Remove ${contact.name || "contact"}`} onClick={() => setDraft((current) => current ? { ...current, contacts: current.contacts.filter((_, itemIndex) => itemIndex !== index) } : current)}><Trash2 aria-hidden="true" size={17} /></button></div>)}
          <div className="dialog-actions"><button type="button" className="button button--secondary" onClick={() => { setDraft(responseDraft(handover)); setEditing(false); }}>Cancel</button><button type="submit" className="button button--primary" disabled={working === "handover"}>{working === "handover" ? "Saving…" : "Save handover"}</button></div>
        </form>
      </Modal>

      <Modal open={bookingOpen} onOpenChange={setBookingOpen} title="Create sitter access" description="The link works only for these children and this time window.">
        <form className="form-stack" onSubmit={createBooking}>{error ? <p className="form-error" role="alert">{error}</p> : null}<div className="field"><label htmlFor="booking-label">Booking name</label><input id="booking-label" value={bookingDraft.label} onChange={(event) => setBookingDraft((current) => ({ ...current, label: event.target.value }))} required /></div><div className="form-grid"><div className="field"><label htmlFor="booking-start">Starts</label><input id="booking-start" type="datetime-local" value={bookingDraft.startsAt} onChange={(event) => setBookingDraft((current) => ({ ...current, startsAt: event.target.value }))} required /></div><div className="field"><label htmlFor="booking-end">Ends</label><input id="booking-end" type="datetime-local" value={bookingDraft.expiresAt} onChange={(event) => setBookingDraft((current) => ({ ...current, expiresAt: event.target.value }))} required /></div></div>{!bookingWindowValid ? <p className="form-error" role="alert">Choose an end time after the start, within seven days, and still in the future.</p> : null}<fieldset className="people-fieldset"><legend>Children in this handover</legend><div className="caregiver-child-choice">{handover.children.map((child) => <label key={child.child_id}><input type="checkbox" checked={bookingDraft.childIds.includes(child.child_id)} onChange={(event) => setBookingDraft((current) => ({ ...current, childIds: event.target.checked ? [...current.childIds, child.child_id] : current.childIds.filter((id) => id !== child.child_id) }))} />{child.child_name}</label>)}</div></fieldset>{bookingMissing.length ? <div className="caregiver-missing" role="status">{bookingMissing.slice(0, 4).map((item) => <span key={item.key}>{item.label}</span>)}</div> : null}<p className="section-help">The first opening exchanges the link for a private browser session. You can revoke it at any time.</p><button type="submit" className="button button--primary" disabled={working === "booking" || !bookingDraft.childIds.length || Boolean(bookingMissing.length) || !bookingWindowValid}>{working === "booking" ? "Creating…" : "Create private link"}</button></form>
      </Modal>

      <Modal open={Boolean(bookingToRevoke)} onOpenChange={(open) => !open && setBookingToRevoke(null)} title="Revoke caregiver access?">
        <div className="form-stack">{error ? <p className="form-error" role="alert">{error}</p> : null}<p>The sitter's open session will stop working immediately.</p><div className="dialog-actions"><button type="button" className="button button--secondary" onClick={() => setBookingToRevoke(null)}>Keep access</button><button type="button" className="button button--danger" disabled={!bookingToRevoke || working === bookingToRevoke.id} onClick={() => bookingToRevoke && void revoke(bookingToRevoke)}>{bookingToRevoke && working === bookingToRevoke.id ? "Revoking…" : "Revoke now"}</button></div></div>
      </Modal>

      <Modal open={Boolean(createdBooking)} onOpenChange={(open) => !open && setCreatedBooking(null)} title="Sitter link ready" description="Send this privately. It can be opened once, then works on that device until the booking ends or you revoke it.">
        {createdBooking ? <div className="form-stack caregiver-share">{error ? <p className="form-error" role="alert">{error}</p> : null}<div className="caregiver-share-link"><KeyRound aria-hidden="true" size={20} /><span>{createdBooking.label}<small>{createdBooking.child_names.join(" & ")} · ends {format(parseISO(createdBooking.expires_at), "HH:mm")}</small></span></div><button type="button" className="button button--primary" onClick={() => void navigator.clipboard.writeText(createdBooking.share_url).then(() => setNotice("Private link copied.")).catch(() => setError("The private link could not be copied. Use Share instead."))}><Copy aria-hidden="true" size={17} />Copy private link</button>{typeof navigator.share === "function" ? <button type="button" className="button button--secondary" onClick={() => void navigator.share({ title: "HausKlar sitter handover", url: createdBooking.share_url }).catch((shareError: unknown) => { if (!(shareError instanceof DOMException && shareError.name === "AbortError")) setError("The private link could not be shared."); })}>Share…</button> : null}<p className="section-help"><strong>Share it before closing this window:</strong> for safety, HausKlar cannot show this exact link again. The secret stays in the link fragment and is never sent in a page request or stored in HausKlar logs. For a QR code, use the iPhone app.</p></div> : null}
      </Modal>
    </div>
  );
}

type SessionArea = "now" | "next" | "emergency";

export function CaregiverSessionView() {
  const [data, setData] = useState<SessionView | null>(null);
  const [area, setArea] = useState<SessionArea>("now");
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [showSessionWifiPassword, setShowSessionWifiPassword] = useState(false);
  const opening = useRef<Promise<SessionView> | null>(null);

  useEffect(() => {
    let subscribed = true;
    if (!opening.current) {
      opening.current = (async () => {
        const fragment = new URLSearchParams(window.location.hash.replace(/^#/, ""));
        const code = fragment.get("invite");
        window.history.replaceState({}, "", `${window.location.pathname}?caregiver=1`);
        if (code) {
          await caregiverRequest<{ status: string }>("/sessions/exchange", {
            method: "POST",
            body: JSON.stringify({ code }),
          });
        }
        return caregiverRequest<SessionView>("/sessions/view");
      })();
    }
    setLoading(true);
    void opening.current
      .then((view) => { if (subscribed) setData(view); })
      .catch((requestError: unknown) => {
        if (subscribed) setError(requestError instanceof Error ? requestError.message : "This caregiver link is unavailable.");
      })
      .finally(() => { if (subscribed) setLoading(false); });
    return () => { subscribed = false; };
  }, []);

  const sessionReady = data !== null;
  useEffect(() => {
    if (!sessionReady) return undefined;
    const refresh = window.setInterval(() => {
      void caregiverRequest<SessionView>("/sessions/view")
        .then((view) => {
          setData(view);
          setError(null);
        })
        .catch((requestError: unknown) => {
          if (requestError instanceof CaregiverRequestError && [401, 403, 409].includes(requestError.status)) {
            setData(null);
            setError(requestError.message);
          } else {
            setError("Connection lost. Showing the last confirmed handover while HausKlar reconnects.");
          }
        });
    }, 60_000);
    return () => window.clearInterval(refresh);
  }, [sessionReady]);

  if (loading) return <main className="caregiver-session-shell"><SkeletonList rows={6} /></main>;
  if (!data) return <main className="caregiver-session-shell"><div className="caregiver-session-error"><AlertTriangle aria-hidden="true" size={38} /><h1>Ask the parent to check access</h1><p>{error ?? "This caregiver access is no longer available."}</p><p>Access may have ended, been revoked, or need an updated handover.</p></div></main>;

  return (
    <main className="caregiver-session-shell">
      <header className="caregiver-session-header"><div><p>HausKlar handover</p><h1>{data.booking.label}</h1><span>Read-only · ends {format(parseISO(data.booking.expires_at), "EEEE, HH:mm")}</span></div><ShieldCheck aria-label="Private, time-limited access" size={30} /></header>
      {error ? <p className="notice-banner" role="status">{error}</p> : null}
      <Segmented value={area} onChange={setArea} label="Handover section" options={[{ value: "now", label: "Now" }, { value: "next", label: "Next" }, { value: "emergency", label: "Emergency" }]} />

      {area === "now" ? <div className="caregiver-session-sections"><section><div className="section-heading"><div><p className="page-eyebrow">Right now</p><h2>The children</h2></div></div>{data.now.children.map((child) => <article className="caregiver-child-card" key={child.child_id}><div><UserRoundCheck aria-hidden="true" size={22} /><h3>{child.name}, {child.age}</h3></div><dl><div><dt>Care</dt><dd>{child.care_notes}</dd></div><div><dt>Food</dt><dd>{child.food}</dd></div><div><dt>Comfort</dt><dd>{child.comfort}</dd></div><div><dt>Toileting</dt><dd>{child.toileting}</dd></div><div><dt>Bedtime</dt><dd>{child.bedtime}</dd></div></dl></article>)}</section>{data.now.active_naps.length ? <section><h2>Sleeping now</h2>{data.now.active_naps.map((nap) => <p className="caregiver-live-row" key={`${nap.child_name}:${nap.started_at}`}><Clock3 aria-hidden="true" size={18} /><span><strong>{nap.child_name}</strong> asleep since {format(parseISO(nap.started_at), "HH:mm")}{nap.location ? ` · ${nap.location}` : ""}</span></p>)}</section> : null}<section><h2>Medicine record</h2>{data.now.medicine_schedule.length ? data.now.medicine_schedule.map((medicine) => <article className="caregiver-medicine-record" key={`${medicine.child_name}:${medicine.medicine_name}`}><strong>{medicine.medicine_name} · {medicine.child_name}</strong>{medicine.dosage_notes ? <p>{medicine.dosage_notes}</p> : null}<span>{medicine.last_given_at ? `Last recorded ${format(parseISO(medicine.last_given_at), "HH:mm")}${medicine.last_given_by ? ` by ${medicine.last_given_by}` : ""}` : "No recorded dose"}</span></article>) : <p>No medicine records for these children.</p>}<p className="caregiver-safety-note"><AlertTriangle aria-hidden="true" size={17} />{data.medicine_disclaimer}</p></section><section><h2>House</h2><div className="caregiver-house-grid"><p><Wifi aria-hidden="true" size={18} /><span><strong>{data.house.wifi_name || "Wi-Fi"}</strong>{showSessionWifiPassword ? data.house.wifi_password : "••••••••"}<button type="button" className="button button--quiet button--compact" onClick={() => setShowSessionWifiPassword((shown) => !shown)}>{showSessionWifiPassword ? <EyeOff aria-hidden="true" size={15} /> : <Eye aria-hidden="true" size={15} />}{showSessionWifiPassword ? "Hide password" : "Show password"}</button></span></p><p><House aria-hidden="true" size={18} /><span><strong>House instructions</strong>{data.house.house_instructions}</span></p>{data.house.dog_instructions ? <p><PawPrint aria-hidden="true" size={18} /><span><strong>Dog</strong>{data.house.dog_instructions}</span></p> : null}</div></section></div> : null}

      {area === "next" ? <div className="caregiver-session-sections"><section><div className="section-heading"><div><p className="page-eyebrow">During this booking</p><h2>Next</h2></div></div>{data.next.events.length ? data.next.events.map((event) => <article className="caregiver-next-event" key={`${event.title}:${event.start_time}`}><time>{format(parseISO(event.start_time), "HH:mm")}</time><div><strong>{event.title}</strong><span>Until {format(parseISO(event.end_time), "HH:mm")}{event.location ? ` · ${event.location}` : ""}</span></div></article>) : <EmptyState title="Nothing scheduled" detail="There are no child-linked calendar commitments during this booking." />}</section></div> : null}

      {area === "emergency" ? <div className="caregiver-session-sections caregiver-emergency"><section><div className="section-heading"><div><p className="page-eyebrow">If something is wrong</p><h2>Emergency</h2></div></div><p className="caregiver-address"><House aria-hidden="true" size={20} /><span><strong>Home address</strong>{data.emergency.address}</span></p><p>{data.emergency.instructions}</p></section><section><h2>Call</h2>{data.emergency.contacts.map((contact) => <a href={`tel:${contact.phone.replace(/\s/g, "")}`} className="caregiver-contact" key={contact.id ?? contact.phone}><Phone aria-hidden="true" size={20} /><span><strong>{contact.name}</strong><small>{contact.relationship || "Emergency contact"}</small></span><b>{contact.phone}</b></a>)}</section><section><h2>Allergies</h2>{data.emergency.allergies.map((allergy) => <p key={allergy.child_name}><strong>{allergy.child_name}</strong> · {allergy.details}</p>)}</section></div> : null}
    </main>
  );
}
