import {
  CalendarDays,
  Check,
  ChevronLeft,
  ChevronRight,
  Clock3,
  Dumbbell,
  HeartPulse,
  LoaderCircle,
} from "lucide-react";
import {
  type ReactNode,
  useEffect,
  useMemo,
  useRef,
  useState,
} from "react";

import { api } from "../../api";
import type {
  FitnessOnboardingAvailability,
  FitnessOnboardingConfirmation,
  FitnessOnboardingDay,
  FitnessOnboardingDraft,
  FitnessOnboardingProfile,
  FitnessOnboardingWeekPreview,
} from "../../fitness/contract";
import { FitnessCard, errorMessage } from "./shared";

const stepLabels = ["Outcome", "Time", "Activities", "Your week"] as const;
const days: FitnessOnboardingDay[] = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"];
const outcomes: NonNullable<FitnessOnboardingDraft["main_outcome"]>[] = [
  "Feel fitter",
  "Build strength",
  "Run further",
  "Improve energy",
  "Support my weight",
  "Move consistently",
];
const activities: FitnessOnboardingDraft["activities"] = ["Walking", "Running", "Strength", "Cycling", "Swimming", "Mobility"];

type FitnessOnboardingStatus = FitnessOnboardingProfile["status"] | null;
let latestOnboardingStatus: FitnessOnboardingStatus = null;
const onboardingStatusListeners = new Set<() => void>();
const OPEN_FITNESS_ONBOARDING_EVENT = "hausklar:open-fitness-onboarding";

function publishOnboardingStatus(status: FitnessOnboardingStatus) {
  if (latestOnboardingStatus === status) return;
  latestOnboardingStatus = status;
  onboardingStatusListeners.forEach((listener) => listener());
}

export function currentFitnessOnboardingStatus(): FitnessOnboardingStatus {
  return latestOnboardingStatus;
}

export function subscribeFitnessOnboardingStatus(listener: () => void): () => void {
  onboardingStatusListeners.add(listener);
  return () => onboardingStatusListeners.delete(listener);
}

export function openFitnessOnboarding(): void {
  window.dispatchEvent(new Event(OPEN_FITNESS_ONBOARDING_EVENT));
}

function profileDraft(profile: FitnessOnboardingProfile): FitnessOnboardingDraft {
  return {
    main_outcome: profile.main_outcome,
    availability: profile.availability,
    activities: profile.activities,
    equipment: profile.equipment,
    food_preferences: profile.food_preferences,
    source_connections: profile.source_connections,
    coach_style: profile.coach_style,
    use_family_calendar: profile.use_family_calendar,
    use_household_meals: profile.use_household_meals,
    use_weather: profile.use_weather,
    memory_enabled: profile.memory_enabled,
  };
}

function setupStepKey(profileId: string): string {
  return `hausklar:fitness:onboarding-step:${profileId}`;
}

function rememberedStep(profileId: string): number {
  try {
    const parsed = Number(window.localStorage.getItem(setupStepKey(profileId)) ?? "0");
    return Number.isInteger(parsed) && parsed >= 0 && parsed < stepLabels.length ? parsed : 0;
  } catch {
    return 0;
  }
}

function rememberStep(profileId: string, step: number): void {
  try {
    window.localStorage.setItem(setupStepKey(profileId), String(step));
  } catch {
    // Setup still works when browser storage is unavailable.
  }
}

function clearRememberedStep(profileId: string): void {
  try {
    window.localStorage.removeItem(setupStepKey(profileId));
  } catch {
    // Nothing else is required.
  }
}

function updateList<T extends string>(list: T[], value: T, enabled: boolean): T[] {
  if (enabled) return list.includes(value) ? list : [...list, value];
  return list.filter((item) => item !== value);
}

function availabilityForDay(availability: FitnessOnboardingAvailability[], day: FitnessOnboardingDay) {
  return availability.find((item) => item.day === day) ?? null;
}

function SetupChoice({
  checked,
  label,
  onChange,
}: {
  checked: boolean;
  label: string;
  onChange: (checked: boolean) => void;
}) {
  return (
    <label className="fitness-setup__choice">
      <input type="checkbox" checked={checked} onChange={(event) => onChange(event.target.checked)} />
      <span>{label}</span>
      {checked ? <Check aria-hidden="true" size={17} /> : null}
    </label>
  );
}

function FitnessOnboardingSetup({
  profile,
  onProfileChange,
  onConfirmed,
  onSkipped,
}: {
  profile: FitnessOnboardingProfile;
  onProfileChange: (profile: FitnessOnboardingProfile) => void;
  onConfirmed: (confirmation: FitnessOnboardingConfirmation) => void;
  onSkipped: (profile: FitnessOnboardingProfile) => void;
}) {
  const [draft, setDraft] = useState(() => profileDraft(profile));
  const [step, setStep] = useState(() => rememberedStep(profile.id));
  const [preview, setPreview] = useState<FitnessOnboardingWeekPreview | null>(profile.preview);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const stepHeadingRef = useRef<HTMLHeadingElement>(null);
  const previousStepRef = useRef(step);

  useEffect(() => {
    if (previousStepRef.current !== step) {
      stepHeadingRef.current?.focus();
      previousStepRef.current = step;
    }
  }, [step]);

  const canContinue = useMemo(() => {
    if (step === 0) return draft.main_outcome !== null;
    if (step === 1) return draft.availability.length > 0;
    if (step === 2) return draft.activities.length > 0;
    return true;
  }, [draft.activities.length, draft.availability.length, draft.main_outcome, step]);

  function firstWeekDraft() {
    return {
      main_outcome: draft.main_outcome,
      availability: draft.availability,
      activities: draft.activities,
    };
  }

  async function saveAndContinue() {
    if (!canContinue) return;
    setBusy(true);
    setError(null);
    try {
      const saved = await api<FitnessOnboardingProfile>(
        "/fitness/onboarding",
        { method: "PUT", body: JSON.stringify(firstWeekDraft()) },
        true,
        false,
      );
      onProfileChange(saved);
      setDraft(profileDraft(saved));
      if (step === 2) {
        const week = await api<FitnessOnboardingWeekPreview>(
          "/fitness/onboarding/preview-week",
          { method: "POST", body: JSON.stringify({}) },
          true,
          false,
        );
        setPreview(week);
      }
      const nextStep = Math.min(step + 1, stepLabels.length - 1);
      setStep(nextStep);
      rememberStep(profile.id, nextStep);
    } catch (requestError) {
      setError(errorMessage(requestError));
    } finally {
      setBusy(false);
    }
  }

  async function buildWeek() {
    setBusy(true);
    setError(null);
    try {
      const saved = await api<FitnessOnboardingProfile>(
        "/fitness/onboarding",
        { method: "PUT", body: JSON.stringify(firstWeekDraft()) },
        true,
        false,
      );
      onProfileChange(saved);
      setDraft(profileDraft(saved));
      const week = await api<FitnessOnboardingWeekPreview>(
        "/fitness/onboarding/preview-week",
        { method: "POST", body: JSON.stringify({}) },
        true,
        false,
      );
      setPreview(week);
      window.requestAnimationFrame(() => stepHeadingRef.current?.focus());
    } catch (requestError) {
      setError(errorMessage(requestError));
    } finally {
      setBusy(false);
    }
  }

  async function skipForNow() {
    setBusy(true);
    setError(null);
    try {
      const skipped = await api<FitnessOnboardingProfile>(
        "/fitness/onboarding/skip",
        { method: "POST" },
        true,
        false,
      );
      clearRememberedStep(profile.id);
      onSkipped(skipped);
    } catch (requestError) {
      setError(errorMessage(requestError));
    } finally {
      setBusy(false);
    }
  }

  async function confirmWeek() {
    if (!preview) return;
    setBusy(true);
    setError(null);
    try {
      const confirmation = await api<FitnessOnboardingConfirmation>(
        "/fitness/onboarding/confirm",
        { method: "POST", body: JSON.stringify({ preview_id: preview.preview_id }) },
        true,
        false,
      );
      clearRememberedStep(profile.id);
      onConfirmed(confirmation);
    } catch (requestError) {
      setError(errorMessage(requestError));
    } finally {
      setBusy(false);
    }
  }

  function goBack() {
    const previous = Math.max(0, step - 1);
    setStep(previous);
    rememberStep(profile.id, previous);
    setError(null);
  }

  function toggleDay(day: FitnessOnboardingDay, checked: boolean) {
    setDraft((current) => ({
      ...current,
      availability: checked
        ? [...current.availability, { day, time_of_day: "Evening", duration_minutes: 30 }]
        : current.availability.filter((item) => item.day !== day),
    }));
  }

  function updateAvailability(day: FitnessOnboardingDay, patch: Partial<FitnessOnboardingAvailability>) {
    setDraft((current) => ({
      ...current,
      availability: current.availability.map((item) => item.day === day ? { ...item, ...patch } : item),
    }));
  }

  return (
    <section className="fitness-setup" aria-labelledby="fitness-setup-title">
      <header className="fitness-setup__header">
        <div>
          <span>Step {step + 1} of {stepLabels.length}</span>
          <h2 id="fitness-setup-title">Set up Fitness</h2>
          <p>A useful week in a few quick choices.</p>
        </div>
        <button type="button" className="button button--secondary" disabled={busy} onClick={() => void skipForNow()}>Finish later</button>
      </header>

      <ol className="fitness-setup__steps" aria-label="Setup progress">
        {stepLabels.map((label, index) => (
          <li className={index === step ? "is-current" : index < step ? "is-complete" : undefined} aria-current={index === step ? "step" : undefined} key={label}>
            <span>{index < step ? <Check aria-hidden="true" size={13} /> : index + 1}</span>
            <small>{label}</small>
          </li>
        ))}
      </ol>

      <FitnessCard className="fitness-setup__card">
        <h3 ref={stepHeadingRef} className="sr-only" tabIndex={-1} aria-live="polite">Step {step + 1} of {stepLabels.length}: {step === 3 ? "Your week, ready to review" : stepLabels[step]}</h3>
        {step === 0 ? (
          <fieldset className="fitness-setup__fieldset">
            <legend>What would make Fitness useful right now?</legend>
            <p>Pick the outcome you care about most. You can change it later.</p>
            <div className="fitness-setup__choice-grid">
              {outcomes.map((outcome) => (
                <label className="fitness-setup__choice" key={outcome}>
                  <input type="radio" name="fitness-main-outcome" value={outcome} checked={draft.main_outcome === outcome} onChange={() => setDraft((current) => ({ ...current, main_outcome: outcome }))} />
                  <span>{outcome}</span>
                  {draft.main_outcome === outcome ? <Check aria-hidden="true" size={17} /> : null}
                </label>
              ))}
            </div>
          </fieldset>
        ) : null}

        {step === 1 ? (
          <div className="fitness-setup__stack">
            <fieldset className="fitness-setup__fieldset">
              <legend>When can you realistically move?</legend>
              <p>Choose a few openings. HausKlar will shape the week around them.</p>
              <div className="fitness-setup__availability">
                {days.map((day) => {
                  const slot = availabilityForDay(draft.availability, day);
                  return (
                    <div className={slot ? "is-selected" : undefined} key={day}>
                      <SetupChoice label={day} checked={Boolean(slot)} onChange={(checked) => toggleDay(day, checked)} />
                      {slot ? (
                        <div className="fitness-setup__availability-fields">
                          <label>{day} time
                            <select value={slot.time_of_day} onChange={(event) => updateAvailability(day, { time_of_day: event.target.value as FitnessOnboardingAvailability["time_of_day"] })}>
                              <option>Morning</option><option>Lunchtime</option><option>Evening</option><option>Flexible</option>
                            </select>
                          </label>
                          <label>{day} minutes
                            <input type="text" inputMode="numeric" pattern="[0-9]*" value={slot.duration_minutes} onChange={(event) => updateAvailability(day, { duration_minutes: Math.min(180, Math.max(10, Number(event.target.value) || 10)) })} />
                          </label>
                        </div>
                      ) : null}
                    </div>
                  );
                })}
              </div>
            </fieldset>
          </div>
        ) : null}

        {step === 2 ? (
          <fieldset className="fitness-setup__fieldset">
            <legend>What do you actually enjoy?</legend>
            <p>Choose the activities you would be happy to see in your first week.</p>
            <div className="fitness-setup__choice-grid">
              {activities.map((activity) => <SetupChoice key={activity} label={activity} checked={draft.activities.includes(activity)} onChange={(checked) => setDraft((current) => ({ ...current, activities: updateList(current.activities, activity, checked) }))} />)}
            </div>
          </fieldset>
        ) : null}

        {step === 3 ? (
          <div className="fitness-setup__review">
            <div><span className="fitness-module__pill">Ready to review</span><h3>Your first week</h3><p>{preview?.summary ?? "Build the week when you are ready."}</p></div>
            {preview ? (
              <ol className="fitness-setup__week">
                {preview.sessions.map((session) => (
                  <li key={`${session.date}:${session.start_time}:${session.title}`}>
                    <div className="fitness-setup__week-date"><strong>{session.day.slice(0, 3)}</strong><span>{new Date(`${session.date}T12:00:00`).getDate()}</span></div>
                    <div><strong>{session.title}</strong><span><Clock3 aria-hidden="true" size={14} /> {session.start_time} · {session.duration_minutes} min · {session.activity}</span><small>{session.reason}</small></div>
                  </li>
                ))}
              </ol>
            ) : (
              <button type="button" className="button button--primary" disabled={busy} onClick={() => void buildWeek()}><CalendarDays aria-hidden="true" size={18} /> Build my week</button>
            )}
            <div className="fitness-setup__confirm-note"><HeartPulse aria-hidden="true" size={18} /><span>Nothing is added to your plan until you confirm.</span></div>
          </div>
        ) : null}

        {error ? <p className="fitness-module__form-status is-error" role="alert">{error}</p> : null}

        <footer className="fitness-setup__footer">
          {step > 0 ? <button type="button" className="button button--secondary" disabled={busy} onClick={goBack}><ChevronLeft aria-hidden="true" size={17} /> Back</button> : <span />}
          <div>
            {step < 3 ? <button type="button" className="button button--primary" aria-busy={busy} disabled={busy || !canContinue} onClick={() => void saveAndContinue()}>{busy ? "Saving…" : "Continue"} <ChevronRight aria-hidden="true" size={17} /></button> : preview ? <button type="button" className="button button--primary button--large" aria-busy={busy} disabled={busy} onClick={() => void confirmWeek()}><Dumbbell aria-hidden="true" size={18} /> {busy ? "Adding your week…" : "Confirm my week"}</button> : null}
          </div>
        </footer>
      </FitnessCard>
    </section>
  );
}

export function FitnessOnboardingGate({
  children,
  onDataChanged,
  onOpenOverview,
  onOpenChange,
}: {
  children: ReactNode;
  onDataChanged: () => void;
  onOpenOverview: () => void;
  onOpenChange?: (open: boolean) => void;
}) {
  const [profile, setProfile] = useState<FitnessOnboardingProfile | null>(null);
  const [setupOpen, setSetupOpen] = useState(false);
  const [resolved, setResolved] = useState(false);
  const [resumeBusy, setResumeBusy] = useState(false);
  const [resumeError, setResumeError] = useState<string | null>(null);

  useEffect(() => {
    let cancelled = false;
    void api<FitnessOnboardingProfile>("/fitness/onboarding", {}, true, false)
      .then((next) => {
        if (cancelled) return;
        setProfile(next);
        setSetupOpen(next.status === "draft");
      })
      .catch(() => {
        // Fitness remains usable if first-run setup cannot be loaded.
      })
      .finally(() => { if (!cancelled) setResolved(true); });
    return () => { cancelled = true; };
  }, []);

  useEffect(() => {
    publishOnboardingStatus(profile?.status ?? null);
  }, [profile?.status]);

  useEffect(() => {
    onOpenChange?.(!resolved || setupOpen);
    return () => onOpenChange?.(false);
  }, [onOpenChange, resolved, setupOpen]);

  async function resumeSetup() {
    setResumeBusy(true);
    setResumeError(null);
    try {
      const resumed = await api<FitnessOnboardingProfile>(
        "/fitness/onboarding",
        { method: "PUT", body: JSON.stringify({}) },
        true,
        false,
      );
      setProfile(resumed);
      setSetupOpen(true);
    } catch (requestError) {
      setResumeError(errorMessage(requestError));
    } finally {
      setResumeBusy(false);
    }
  }

  useEffect(() => {
    const openSetup = () => {
      if (profile?.status === "draft") setSetupOpen(true);
      if (profile?.status === "skipped") void resumeSetup();
    };
    window.addEventListener(OPEN_FITNESS_ONBOARDING_EVENT, openSetup);
    return () => window.removeEventListener(OPEN_FITNESS_ONBOARDING_EVENT, openSetup);
  }, [profile?.status]);

  if (setupOpen && profile) {
    return <FitnessOnboardingSetup profile={profile} onProfileChange={setProfile} onSkipped={(skipped) => { setProfile(skipped); setSetupOpen(false); onOpenOverview(); }} onConfirmed={() => { setProfile((current) => current ? { ...current, status: "complete" } : current); setSetupOpen(false); onDataChanged(); onOpenOverview(); }} />;
  }

  if (!resolved) {
    return <div className="fitness-setup__loading" role="status"><LoaderCircle className="is-spinning" aria-hidden="true" size={20} /><span>Opening Fitness…</span></div>;
  }

  return <>{resumeError ? <p className="fitness-module__form-status is-error" role="alert">{resumeError}</p> : null}{children}</>;
}
