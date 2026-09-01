import { CalendarPlus, CheckCircle2, ChevronRight, Copy, UsersRound, X } from "lucide-react";
import { useEffect, useState, type FormEvent } from "react";

import { api } from "../api";
import type { FamilyInvite, OnboardingModule, OnboardingStatus, ReminderPreferences, User } from "../types";
import { QRCode } from "./QRCode";
import "../views/account-settings.css";

const defaultReminderChoices: ReminderPreferences = {
  event_reminders_enabled: true, event_minutes_before: 30, task_reminders_enabled: true,
  morning_summary_enabled: true, morning_summary_time: "07:00", evening_summary_enabled: true,
  evening_summary_time: "19:00", quiet_start: "21:00", quiet_end: "07:00", privacy_mode: true,
};

const optionalAreas: Array<{ id: OnboardingModule; label: string; detail: string }> = [
  { id: "fitness", label: "Fitness", detail: "A private adult training and health workspace" },
];

export function OnboardingGuide({ user, initialStatus, onComplete, onEnableFitness }: {
  user: User;
  initialStatus: OnboardingStatus;
  onComplete: (status: OnboardingStatus) => void;
  onEnableFitness?: () => Promise<void>;
}) {
  const [step, setStep] = useState(0);
  const [status, setStatus] = useState(initialStatus);
  const [invite, setInvite] = useState<FamilyInvite | null>(null);
  const [childName, setChildName] = useState("");
  const [childDOB, setChildDOB] = useState("");
  const [eventTitle, setEventTitle] = useState("");
  const [eventWhen, setEventWhen] = useState("");
  const [eventDurationMinutes, setEventDurationMinutes] = useState(30);
  const [reminders, setReminders] = useState<ReminderPreferences>(defaultReminderChoices);
  const [remindersLoaded, setRemindersLoaded] = useState(false);
  const [selectedModules, setSelectedModules] = useState<OnboardingModule[]>(initialStatus.selected_modules);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [firstSuccess, setFirstSuccess] = useState(initialStatus.first_success);

  useEffect(() => {
    if (step !== 3 || remindersLoaded) return;
    let active = true;
    void api<ReminderPreferences>("/reminders/preferences")
      .then((loaded) => { if (active) setReminders(loaded); })
      .catch(() => undefined)
      .finally(() => { if (active) setRemindersLoaded(true); });
    return () => { active = false; };
  }, [remindersLoaded, step]);

  async function refreshStatus() {
    const refreshed = await api<OnboardingStatus>("/auth/onboarding");
    setStatus(refreshed);
    return refreshed;
  }

  async function dismiss() {
    setBusy(true);
    try { onComplete(await api<OnboardingStatus>("/auth/onboarding", { method: "PATCH", body: JSON.stringify({ dismissed: true, selected_modules: selectedModules }) })); }
    finally { setBusy(false); }
  }

  async function generateInvite() {
    setBusy(true); setError(null);
    try { setInvite(await api<FamilyInvite>("/auth/invite", { method: "POST" })); }
    catch (requestError) { setError(requestError instanceof Error ? requestError.message : "Invitation could not be created."); }
    finally { setBusy(false); }
  }

  async function addChild(event: FormEvent) {
    event.preventDefault(); setBusy(true); setError(null);
    try {
      await api("/children/", { method: "POST", body: JSON.stringify({ id: crypto.randomUUID(), name: childName, date_of_birth: childDOB }) });
      setChildName(""); setChildDOB(""); await refreshStatus();
    } catch (requestError) { setError(requestError instanceof Error ? requestError.message : "Child profile could not be added."); }
    finally { setBusy(false); }
  }

  async function addFirstCommitment(event: FormEvent) {
    event.preventDefault(); setBusy(true); setError(null);
    try {
      const start = new Date(eventWhen);
      await api("/calendar/", { method: "POST", body: JSON.stringify({ id: crypto.randomUUID(), title: eventTitle, start_time: start.toISOString(), end_time: new Date(start.getTime() + eventDurationMinutes * 60 * 1_000).toISOString(), family_member_ids: null }) });
      const refreshed = await refreshStatus(); setFirstSuccess(true); setStatus(refreshed); setStep(2);
    } catch (requestError) { setError(requestError instanceof Error ? requestError.message : "The first commitment could not be added."); }
    finally { setBusy(false); }
  }

  async function finish() {
    setBusy(true); setError(null);
    try {
      await api<ReminderPreferences>("/reminders/preferences", { method: "PUT", body: JSON.stringify(reminders) });
      if (selectedModules.includes("fitness")) await onEnableFitness?.();
      const completed = await api<OnboardingStatus>("/auth/onboarding", { method: "PATCH", body: JSON.stringify({ selected_modules: selectedModules, completed: true }) });
      setStatus(completed); setStep(4);
    } catch (requestError) { setError(requestError instanceof Error ? requestError.message : "Setup choices could not be saved."); }
    finally { setBusy(false); }
  }

  function toggleModule(module: OnboardingModule) {
    setSelectedModules((current) => current.includes(module) ? current.filter((item) => item !== module) : [...current, module]);
  }

  return <section className="onboarding-guide" aria-labelledby="onboarding-title">
    <header className="onboarding-header"><div><span>Getting started · {Math.min(step + 1, 4)} of 4</span><h1 id="onboarding-title">{step === 0 ? "Welcome to your family’s shared plan" : step === 1 ? "Put the first real thing in the planner" : step === 2 ? "Who should HausKlar understand?" : step === 3 ? "Choose a useful level of help" : "You know what’s happening today"}</h1></div>{step < 4 ? <button type="button" className="icon-button" aria-label="Skip setup" disabled={busy} onClick={() => void dismiss()}><X size={19} /></button> : null}</header>

    {error ? <div className="form-error" role="alert">{error}</div> : null}

    {step === 0 ? <div className="onboarding-step"><img src="/icons/hausklar-192.png" width="80" height="80" alt="" /><p className="onboarding-promise">Know what’s happening today.</p><p>HausKlar keeps the detail your family may need—people, commitments, documents and specialist records—behind one calm daily plan. We’ll establish only the useful core now.</p><dl className="onboarding-existing"><div><dt>Household</dt><dd>{status.family_name}</dd></div><div><dt>People already here</dt><dd>{status.people_count}</dd></div><div><dt>Planner commitments</dt><dd>{status.calendar_commitment_count}</dd></div></dl><button type="button" className="button button--primary button--large" onClick={() => setStep(1)}>Set up the useful core <ChevronRight size={18} /></button></div> : null}

    {step === 2 ? <div className="onboarding-step">{status.first_success || firstSuccess ? <div className="onboarding-first-success"><CheckCircle2 size={28} /><div><strong>Your family plan has started</strong><p>The first commitment is already waiting in Today.</p></div></div> : null}<p>Adults have their own secure sign-in. Children have profiles managed by the adults; they do not get accounts or see private adult areas.</p><div className="onboarding-choice-grid">{user.role === "admin" ? <article><UsersRound size={24} /><strong>Invite the other adult</strong><p>Single-use, secure and valid for 24 hours.</p><button type="button" className="button button--secondary" disabled={busy} onClick={() => void generateInvite()}>{invite ? "Replace invitation" : "Create invitation"}</button>{invite ? <div className="onboarding-invite"><QRCode value={invite.join_url} label="QR code to join this household" size={180} /><code>{invite.invite_code}</code><button type="button" className="button button--secondary" onClick={() => void navigator.clipboard.writeText(invite.join_url)}><Copy size={15} /> Copy link</button></div> : null}</article> : null}<article><UserRoundIcon /><strong>Add a child profile</strong><form className="form-stack" onSubmit={addChild}><div className="field"><label htmlFor="onboarding-child-name">Name</label><input id="onboarding-child-name" value={childName} onChange={(event) => setChildName(event.target.value)} autoComplete="name" required /></div><div className="field"><label htmlFor="onboarding-child-dob">Date of birth</label><input id="onboarding-child-dob" type="date" max={new Date().toISOString().slice(0, 10)} value={childDOB} onChange={(event) => setChildDOB(event.target.value)} required /></div><button className="button button--secondary" disabled={busy}>Add child</button></form></article></div><p className="onboarding-status-line"><CheckCircle2 size={17} /> {status.people_count} {status.people_count === 1 ? "person" : "people"} established</p><div className="onboarding-actions"><button type="button" className="button button--secondary" onClick={() => setStep(1)}>Back</button><button type="button" className="button button--primary" onClick={() => setStep(3)}>Continue <ChevronRight size={17} /></button></div></div> : null}

    {step === 1 ? <div className="onboarding-step"><p>This is the first moment HausKlar becomes useful. Add one real commitment; you can import school, work or shared calendars later under Settings → Connections.</p>{status.first_success || firstSuccess ? <div className="onboarding-first-success"><CheckCircle2 size={28} /><div><strong>Your family plan has started</strong><p>HausKlar can now answer the question that matters: what’s happening today?</p></div></div> : <form className="form-stack onboarding-commitment" onSubmit={addFirstCommitment}><div className="field"><label htmlFor="first-event-title">What’s happening?</label><input id="first-event-title" value={eventTitle} onChange={(event) => setEventTitle(event.target.value)} placeholder="School pickup" required /></div><div className="field"><label htmlFor="first-event-when">When?</label><input id="first-event-when" type="datetime-local" value={eventWhen} onChange={(event) => setEventWhen(event.target.value)} required /></div><div className="field"><label htmlFor="first-event-duration">How long?</label><select id="first-event-duration" value={eventDurationMinutes} onChange={(event) => setEventDurationMinutes(Number(event.target.value))}><option value={15}>15 minutes</option><option value={30}>30 minutes</option><option value={60}>1 hour</option><option value={90}>1½ hours</option></select></div><button className="button button--primary button--large" disabled={busy}><CalendarPlus size={18} /> {busy ? "Adding…" : "Add first commitment"}</button></form>}<div className="onboarding-actions"><button type="button" className="button button--secondary" onClick={() => setStep(0)}>Back</button><button type="button" className="button button--secondary" onClick={() => setStep(2)}>Do this later</button></div></div> : null}

    {step === 3 ? <div className="onboarding-step"><p>Start quiet. These choices save automatically when setup finishes; notification permission is requested only when you deliberately enable this device in Settings.</p><fieldset className="onboarding-reminders"><legend>Useful reminders</legend><label className="reminder-toggle"><input type="checkbox" checked={reminders.event_reminders_enabled} onChange={(event) => setReminders({ ...reminders, event_reminders_enabled: event.target.checked })} /><span><strong>Upcoming commitments</strong><small>30 minutes before</small></span></label><label className="reminder-toggle"><input type="checkbox" checked={reminders.task_reminders_enabled} onChange={(event) => setReminders({ ...reminders, task_reminders_enabled: event.target.checked })} /><span><strong>Due tasks</strong><small>Shared and assigned tasks at 09:00</small></span></label><label className="reminder-toggle"><input type="checkbox" checked={reminders.morning_summary_enabled} onChange={(event) => setReminders({ ...reminders, morning_summary_enabled: event.target.checked })} /><span><strong>Morning summary</strong><small>A calm view of today at 07:00</small></span></label><label className="reminder-toggle"><input type="checkbox" checked={reminders.evening_summary_enabled} onChange={(event) => setReminders({ ...reminders, evening_summary_enabled: event.target.checked })} /><span><strong>Tomorrow, sorted</strong><small>One evening check at 19:00</small></span></label></fieldset>{onEnableFitness ? <fieldset className="onboarding-areas"><legend>Optional private workspace</legend><p>Fitness is personal to this adult and appears only if you enable it.</p>{optionalAreas.map((area) => <label key={area.id}><input type="checkbox" checked={selectedModules.includes(area.id)} onChange={() => toggleModule(area.id)} /><span><strong>{area.label}</strong><small>{area.detail}</small></span></label>)}</fieldset> : null}<div className="onboarding-actions"><button type="button" className="button button--secondary" onClick={() => setStep(2)}>Back</button><button type="button" className="button button--primary" disabled={busy} onClick={() => void finish()}>{busy ? "Saving…" : "Finish setup"}</button></div></div> : null}

    {step === 4 ? <div className="onboarding-step onboarding-complete"><CheckCircle2 size={52} /><p className="onboarding-promise">Know what’s happening today.</p><p>{status.first_success || firstSuccess ? "Your first commitment is in the shared planner. The detail is there when you need it; Today stays calm." : "Your choices are saved. Add the first real commitment when it becomes useful."}</p><button type="button" className="button button--primary button--large" onClick={() => onComplete(status)}>Open Today</button></div> : null}
  </section>;
}

function UserRoundIcon() { return <UsersRound size={24} aria-hidden="true" />; }
