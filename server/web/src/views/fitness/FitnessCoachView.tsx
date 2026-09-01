import {
  Bell,
  CalendarRange,
  Check,
  ClipboardList,
  CloudSun,
  Dumbbell,
  Footprints,
  LoaderCircle,
  MessageCircle,
  Pencil,
  RefreshCw,
  Send,
  Settings2,
  ShoppingBasket,
  Sparkles,
  Undo2,
  Utensils,
  X,
} from "lucide-react";
import { useEffect, useLayoutEffect, useMemo, useRef, useState } from "react";

import { ApiError, api } from "../../api";
import { AIConsentPrompt, useAIConsent } from "../../components/AIConsent";
import { SkeletonList, cn } from "../../components/ui";
import { currentOfflineQueueOwner } from "../../offlineQueue";
import {
  asFitnessArray,
  type FitnessCoachEvidence,
  type FitnessCoachConversation,
  type FitnessCoachContextPreferences,
  type FitnessCoachFeedback,
  type FitnessCoachIntent,
  type FitnessCoachMemoryCandidate,
  type FitnessCoachMemorySettings,
  type FitnessCoachMessageResponse,
  type FitnessCoachPreferences,
  type FitnessCoachProposal,
  type FitnessCoachProposalDestination,
  type FitnessCoachProposalDecision,
  type FitnessCoachProposalUndo,
  type FitnessCoachRecommendation,
  type FitnessCoachReminder,
  type FitnessCoachStatus,
} from "../../fitness/contract";
import type { FitnessViewProps } from "./FitnessModuleView";
import "./fitness-wave5.css";
import {
  FitnessCard,
  FitnessFormStatus,
  FitnessPageHeading,
  errorMessage,
  formatFitnessDate,
  formatFitnessDateTime,
  useFitnessEndpoint,
} from "./shared";
import {
  FitnessCoachMemoryCandidates,
  FitnessCoachMemoryPanel,
  storedCoachMessages,
} from "./FitnessCoachMemory";

type CoachMessage = {
  id: string;
  role: "user" | "assistant";
  content: string;
  evidence: FitnessCoachEvidence[];
  recommendation: FitnessCoachRecommendation | null;
  proposal: FitnessCoachProposal | null;
  proposalDecision?: FitnessCoachProposalDecision | null;
  proposalUndo?: FitnessCoachProposalUndo | null;
};

const emptyCoachStatus: FitnessCoachStatus = { status: "unavailable", provider: null, model: null, message: null, intents: [] };
const starterPrompts: Array<{ intent: FitnessCoachIntent; label: string; prompt: string; icon: typeof MessageCircle }> = [
  { intent: "weekly", label: "Review my week", prompt: "Review this week and give me the one change that matters most.", icon: ClipboardList },
  { intent: "run_plan", label: "Plan a run", prompt: "Plan a run that fits around my family week.", icon: Footprints },
  { intent: "strength_plan", label: "Plan strength", prompt: "Plan a practical strength session for this week.", icon: Dumbbell },
  { intent: "discussion", label: "What should I do today?", prompt: "What is the most useful thing I can do for my fitness today?", icon: Sparkles },
];
const feedbackOptions: Array<{ key: FitnessCoachFeedback; label: string }> = [
  { key: "accepted", label: "Accepted" },
  { key: "rejected", label: "Rejected" },
  { key: "tried_worked", label: "Tried — worked" },
  { key: "tried_too_hard", label: "Tried — too hard" },
  { key: "tried_too_hungry", label: "Tried — too hungry" },
  { key: "unavailable", label: "Could not do it" },
  { key: "disliked", label: "Disliked" },
  { key: "analysis_inaccurate", label: "That looked wrong" },
  { key: "other", label: "Other" },
];

type CoachPreferencesForm = Omit<FitnessCoachPreferences, "custom_instruction"> & { custom_instruction: string };

const defaultCoachPreferences: CoachPreferencesForm = {
  personality_preset: "balanced_supportive",
  directness: 3,
  challenge_bias: "balanced",
  detail_level: "standard",
  custom_instruction: "",
};

function normalisePreferences(preferences: FitnessCoachPreferences): CoachPreferencesForm {
  return { ...preferences, custom_instruction: preferences.custom_instruction ?? "" };
}

const preferencePresets: Array<{
  key: FitnessCoachPreferences["personality_preset"];
  label: string;
  detail: string;
  defaults: Pick<FitnessCoachPreferences, "directness" | "challenge_bias" | "detail_level">;
}> = [
  { key: "scientific_hard_driving", label: "Scientific & hard-driving", detail: "Direct, ambitious and detailed.", defaults: { directness: 5, challenge_bias: "ambitious", detail_level: "detailed" } },
  { key: "balanced_supportive", label: "Balanced & supportive", detail: "Clear challenge with proportionate support.", defaults: { directness: 3, challenge_bias: "balanced", detail_level: "standard" } },
  { key: "calm_encouraging", label: "Calm & encouraging", detail: "Gentler delivery with conservative challenge.", defaults: { directness: 2, challenge_bias: "conservative", detail_level: "standard" } },
  { key: "custom", label: "Custom", detail: "Set each communication preference yourself.", defaults: { directness: 3, challenge_bias: "balanced", detail_level: "standard" } },
];

export function FitnessCoachPreferencesCard({ online, revision }: { online: boolean; revision: number }) {
  const resource = useFitnessEndpoint<FitnessCoachPreferences | null>("/fitness/coach/preferences", null, revision);
  const [editing, setEditing] = useState(false);
  const [form, setForm] = useState<CoachPreferencesForm>(defaultCoachPreferences);
  const [saving, setSaving] = useState(false);
  const [saved, setSaved] = useState(false);
  const [saveError, setSaveError] = useState<string | null>(null);
  const presetGridRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    if (!resource.data) return;
    setForm(normalisePreferences(resource.data));
  }, [resource.data]);

  function selectPreset(preset: typeof preferencePresets[number]) {
    setForm((current) => ({ ...current, personality_preset: preset.key, ...preset.defaults }));
  }

  function toggleEditor() {
    if (editing) {
      setEditing(false);
      return;
    }
    setEditing(true);
    window.requestAnimationFrame(() => {
      if (!window.matchMedia?.("(max-width: 440px)").matches) return;
      const selected = presetGridRef.current?.querySelector<HTMLElement>("button[aria-pressed='true']");
      selected?.focus({ preventScroll: true });
      selected?.scrollIntoView?.({ block: "center" });
    });
  }

  async function savePreferences() {
    if (!online || saving) return;
    setSaving(true); setSaved(false); setSaveError(null);
    try {
      const result = await api<FitnessCoachPreferences>("/fitness/coach/preferences", {
        method: "PATCH",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          personality_preset: form.personality_preset,
          directness: form.directness,
          challenge_bias: form.challenge_bias,
          detail_level: form.detail_level,
          custom_instruction: form.custom_instruction.trim(),
        }),
      }, true, false);
      setForm(normalisePreferences(result));
      setSaved(true);
      setEditing(false);
      resource.reload();
    } catch (requestError) {
      setSaveError(errorMessage(requestError));
    } finally {
      setSaving(false);
    }
  }

  const selectedPreset = preferencePresets.find((item) => item.key === form.personality_preset) ?? preferencePresets[1];
  return <FitnessCard title="Coach style" detail="Choose how direct and detailed Coach should be.">
    {resource.loading ? <p className="fitness-module__form-status"><LoaderCircle className="is-spinning" size={15} aria-hidden="true" /> Loading style…</p> : null}
    {!resource.loading && resource.error ? <div className="fitness-module__notice fitness-module__notice--error" role="alert"><span>{resource.error}</span><button className="button button--secondary" type="button" onClick={resource.reload}>Try again</button></div> : null}
    {!resource.loading && !resource.error && !resource.data ? <div className="fitness-module__notice" role="status"><span>{online ? "Your saved coach style is unavailable right now." : "Reconnect to load the coach style you saved. HausKlar won’t guess a replacement."}</span>{online ? <button className="button button--secondary" type="button" onClick={resource.reload}>Try again</button> : null}</div> : null}
    {!resource.loading && !resource.error && resource.data ? <>
      <div className="fitness-module__coach-style-summary"><Settings2 size={19} aria-hidden="true" /><div><strong>{selectedPreset.label}</strong><small>Directness {form.directness}/5 · {form.challenge_bias} challenge · {form.detail_level} detail</small></div><button className="button button--secondary button--compact" type="button" onClick={toggleEditor}>{editing ? "Close" : "Personalise"}</button></div>
      {editing ? <form className="fitness-module__form" onSubmit={(event) => { event.preventDefault(); void savePreferences(); }}><div className="fitness-module__choice-grid fitness-module__coach-style-presets" ref={presetGridRef}>{preferencePresets.map((preset) => { const selected = form.personality_preset === preset.key; return <button aria-pressed={selected} className={selected ? "is-active" : ""} key={preset.key} type="button" onClick={() => selectPreset(preset)}><strong>{preset.label}</strong><small>{preset.detail}</small>{selected ? <span className="fitness-module__choice-selected">Selected</span> : null}</button>; })}</div><div className="fitness-module__fields">
        <label className="fitness-module__field">Directness: {form.directness}/5<input aria-label="Coach directness" min="1" max="5" step="1" type="range" value={form.directness} onChange={(event) => setForm((current) => ({ ...current, personality_preset: "custom", directness: Number(event.target.value) as FitnessCoachPreferences["directness"] }))} /></label>
        <label className="fitness-module__field">Challenge bias<select value={form.challenge_bias} onChange={(event) => setForm((current) => ({ ...current, personality_preset: "custom", challenge_bias: event.target.value as FitnessCoachPreferences["challenge_bias"] }))}><option value="conservative">Conservative</option><option value="balanced">Balanced</option><option value="ambitious">Ambitious</option></select></label>
        <label className="fitness-module__field">Level of detail<select value={form.detail_level} onChange={(event) => setForm((current) => ({ ...current, personality_preset: "custom", detail_level: event.target.value as FitnessCoachPreferences["detail_level"] }))}><option value="brief">Brief</option><option value="standard">Standard</option><option value="detailed">Detailed</option></select></label>
        <label className="fitness-module__field is-wide">Custom instruction <small>{form.custom_instruction.length}/500</small><textarea maxLength={500} placeholder="For example: challenge vague excuses, but keep race-week advice concise." value={form.custom_instruction} onChange={(event) => setForm((current) => ({ ...current, personality_preset: "custom", custom_instruction: event.target.value }))} /></label>
      </div><div className="fitness-module__form-footer"><button className="button button--primary" disabled={!online || saving} type="submit">Save coach style</button><button className="button button--secondary" type="button" onClick={() => { setForm(normalisePreferences(resource.data!)); setEditing(false); }}>Cancel</button><FitnessFormStatus saving={saving} saved={saved} error={saveError} /></div>{!online ? <p className="fitness-module__muted">Reconnect to save your coach style.</p> : null}</form> : null}
    </> : null}
  </FitnessCard>;
}

const defaultContextPreferences: FitnessCoachContextPreferences = {
  family_calendar: false,
  household_meals: false,
  weather: false,
};

export function FitnessCoachContextPreferencesCard({ online, revision }: { online: boolean; revision: number }) {
  const resource = useFitnessEndpoint<FitnessCoachContextPreferences | null>("/fitness/coach/context-preferences", null, revision);
  const [form, setForm] = useState(defaultContextPreferences);
  const [saving, setSaving] = useState(false);
  const [saved, setSaved] = useState(false);
  const [saveError, setSaveError] = useState<string | null>(null);

  useLayoutEffect(() => {
    if (resource.data) setForm(resource.data);
  }, [resource.data]);

  async function save() {
    if (!online || saving || !resource.data) return;
    setSaving(true);
    setSaved(false);
    setSaveError(null);
    try {
      const result = await api<FitnessCoachContextPreferences>("/fitness/coach/context-preferences", {
        method: "PATCH",
        body: JSON.stringify(form),
      }, true, false);
      setForm(result);
      setSaved(true);
      resource.reload();
    } catch (requestError) {
      setSaveError(errorMessage(requestError));
    } finally {
      setSaving(false);
    }
  }

  const dirty = Boolean(resource.data) && (
    form.family_calendar !== resource.data?.family_calendar
    || form.household_meals !== resource.data?.household_meals
    || form.weather !== resource.data?.weather
  );
  const options = [
    { key: "family_calendar" as const, label: "Family Calendar", detail: "Fit training around the next seven days.", icon: CalendarRange },
    { key: "household_meals" as const, label: "Household meals", detail: "Use this week’s shared meal plan.", icon: Utensils },
    { key: "weather" as const, label: "Weather", detail: "Consider relevant local weather.", icon: CloudSun },
  ];

  return <FitnessCard title="Use alongside Fitness" detail="Choose what Coach may use when you press Send.">
    {resource.loading ? <SkeletonList rows={3} /> : null}
    {!resource.loading && resource.error ? <div className="fitness-module__notice fitness-module__notice--error" role="alert"><span>{resource.error}</span><button type="button" className="button button--secondary" onClick={resource.reload}>Try again</button></div> : null}
    {!resource.loading && !resource.error && !resource.data ? <div className="fitness-module__empty"><strong>These choices are unavailable</strong><span>Try again when HausKlar is connected.</span><button type="button" className="button button--secondary" onClick={resource.reload}>Try again</button></div> : null}
    {!resource.loading && !resource.error && resource.data ? <form className="fitness-wave5__personalise-form" onSubmit={(event) => { event.preventDefault(); void save(); }}>
      <fieldset className="fitness-wave5__toggle-list"><legend className="sr-only">Information Coach may use</legend>{options.map((option) => { const Icon = option.icon; return <label key={option.key}><input type="checkbox" checked={form[option.key]} onChange={(event) => setForm((current) => ({ ...current, [option.key]: event.target.checked }))} /><Icon aria-hidden="true" size={19} /><span><strong>{option.label}</strong><small>{option.detail}</small></span></label>; })}</fieldset>
      <div className="fitness-module__form-footer"><button type="submit" className="button button--primary" aria-busy={saving} disabled={!online || saving || !dirty}>{saving ? "Saving…" : "Save choices"}</button><FitnessFormStatus saving={false} saved={saved} error={saveError} /></div>
    </form> : null}
  </FitnessCard>;
}

export function FitnessCoachRemindersCard({ online, revision, focusReminderId }: { online: boolean; revision: number; focusReminderId?: string | null }) {
  const resource = useFitnessEndpoint<FitnessCoachReminder[]>("/fitness/coach/reminders", [], revision);
  const [confirmRemove, setConfirmRemove] = useState<string | null>(null);
  const [removeError, setRemoveError] = useState<string | null>(null);
  const [busy, setBusy] = useState<string | null>(null);
  const removing = useRef(new Set<string>());

  useEffect(() => {
    if (!focusReminderId || resource.loading) return;
    const url = new URL(window.location.href);
    url.searchParams.delete("fitness-reminder");
    url.searchParams.delete("fitness-personalise");
    window.history.replaceState(window.history.state, "", url);
    window.requestAnimationFrame(() => {
      const target = document.getElementById(`fitness-coach-reminder-${focusReminderId}`) ?? document.getElementById("fitness-coach-reminders");
      const reducedMotion = window.matchMedia?.("(prefers-reduced-motion: reduce)").matches ?? false;
      target?.scrollIntoView({ block: "center", behavior: reducedMotion ? "auto" : "smooth" });
      target?.focus({ preventScroll: true });
    });
  }, [focusReminderId, resource.loading]);

  async function remove(reminder: FitnessCoachReminder) {
    if (!online || removing.current.has(reminder.id)) return;
    removing.current.add(reminder.id);
    setBusy(reminder.id);
    setRemoveError(null);
    try {
      await api(`/fitness/coach/reminders/${encodeURIComponent(reminder.id)}`, { method: "DELETE" }, true, false);
      setConfirmRemove(null);
      resource.reload();
    } catch (requestError) {
      setRemoveError(errorMessage(requestError));
    } finally {
      removing.current.delete(reminder.id);
      setBusy(null);
    }
  }

  const reminders = [...resource.data].sort((left, right) => left.remind_at_utc.localeCompare(right.remind_at_utc));
  return <FitnessCard title="Private reminders" detail="Small prompts created through Coach stay visible only to you." className="fitness-wave5__reminders">
    <div id="fitness-coach-reminders" tabIndex={-1} />
    {resource.loading ? <SkeletonList rows={2} /> : null}
    {!resource.loading && resource.error ? <div className="fitness-module__notice fitness-module__notice--error" role="alert"><span>{resource.error}</span><button type="button" className="button button--secondary" onClick={resource.reload}>Try again</button></div> : null}
    {!resource.loading && !resource.error ? reminders.length ? <ul>{reminders.map((reminder) => <li id={`fitness-coach-reminder-${reminder.id}`} tabIndex={-1} key={reminder.id}><div><strong>{reminder.title}</strong><span>{formatFitnessDateTime(reminder.remind_at_utc)}</span>{reminder.notes ? <small>{reminder.notes}</small> : null}</div>{confirmRemove === reminder.id ? <div className="fitness-module__button-row" role="group" aria-label={`Remove ${reminder.title}?`}><button type="button" className="button button--danger button--compact" aria-busy={busy === reminder.id} disabled={!online || busy === reminder.id} onClick={() => void remove(reminder)}>{busy === reminder.id ? "Removing…" : "Remove reminder"}</button><button type="button" className="button button--secondary button--compact" disabled={busy === reminder.id} onClick={() => setConfirmRemove(null)}>Keep</button></div> : <button type="button" className="button button--secondary button--compact" onClick={() => setConfirmRemove(reminder.id)}>Remove</button>}</li>)}</ul> : <div className="fitness-module__empty"><Bell aria-hidden="true" size={23} /><strong>No private reminders</strong><span>Ask Coach to create one when a nudge would help.</span></div> : null}
    {removeError ? <div className="fitness-module__notice fitness-module__notice--error" role="alert"><span>{removeError}</span></div> : null}
  </FitnessCard>;
}

function textField(payload: Record<string, unknown>, key: string): string | null {
  const value = payload[key];
  return typeof value === "string" && value.trim() ? value : null;
}

function numberField(payload: Record<string, unknown>, key: string): number | null {
  const value = payload[key];
  return typeof value === "number" && Number.isFinite(value) ? value : null;
}

function recordArray(payload: Record<string, unknown>, key: string): Array<Record<string, unknown>> {
  const value = payload[key];
  return Array.isArray(value) ? value.filter((item): item is Record<string, unknown> => Boolean(item) && typeof item === "object" && !Array.isArray(item)) : [];
}

function recordField(payload: Record<string, unknown>, key: string): Record<string, unknown> | null {
  const value = payload[key];
  return value && typeof value === "object" && !Array.isArray(value) ? value as Record<string, unknown> : null;
}

function recordValue(value: unknown): Record<string, unknown> | null {
  return value && typeof value === "object" && !Array.isArray(value) ? value as Record<string, unknown> : null;
}

function durationLabel(seconds: number | null): string | null {
  if (seconds == null) return null;
  const hours = Math.floor(seconds / 3600);
  const minutes = Math.round((seconds % 3600) / 60);
  return hours ? `${hours}h ${minutes}m` : `${minutes} min`;
}

function distanceLabel(metres: number | null): string | null {
  if (metres == null) return null;
  return metres >= 1000 ? `${(metres / 1000).toFixed(metres % 1000 ? 1 : 0)} km` : `${Math.round(metres)} m`;
}

function boundedRunSteps(steps: Array<Record<string, unknown>>, limit = 60, maxDepth = 4) {
  const rows: Array<{ step: Record<string, unknown>; depth: number; path: string }> = [];
  function visit(items: Array<Record<string, unknown>>, depth: number, parentPath: string) {
    if (depth > maxDepth) return;
    for (let index = 0; index < items.length && rows.length < limit; index += 1) {
      const step = items[index];
      const path = parentPath ? `${parentPath}.${index + 1}` : `${index + 1}`;
      rows.push({ step, depth, path });
      visit(recordArray(step, "children"), depth + 1, path);
    }
  }
  visit(steps, 0, "");
  return rows;
}

function runProposalPreviewComplete(payload: Record<string, unknown>): boolean {
  const sourceSteps = payload.steps;
  if (!Array.isArray(sourceSteps) || sourceSteps.length === 0) return false;
  let count = 0;
  function visit(items: unknown[], depth: number): boolean {
    if (depth > 4) return items.length === 0;
    for (const value of items) {
      const item = recordValue(value);
      if (!item) return false;
      count += 1;
      if (count > 60) return false;
      const rawChildren = item.children;
      if (rawChildren != null && !Array.isArray(rawChildren)) return false;
      const children = Array.isArray(rawChildren) ? rawChildren : [];
      if (!textField(item, "display_name") && !textField(item, "name") && !textField(item, "duration_type") && children.length === 0) return false;
      if (!visit(children, depth + 1)) return false;
    }
    return true;
  }
  return visit(sourceSteps, 0) && count > 0;
}

function strengthProposalPreviewComplete(payload: Record<string, unknown>): boolean {
  const sourceExercises = payload.exercises;
  if (!Array.isArray(sourceExercises) || sourceExercises.length === 0 || sourceExercises.length > 24) return false;
  return sourceExercises.every((value) => {
    const exercise = recordValue(value);
    if (!exercise || (!textField(exercise, "exercise_name") && !textField(exercise, "name"))) return false;
    const rawSets = exercise.sets;
    if (rawSets != null && !Array.isArray(rawSets)) return false;
    const sets = Array.isArray(rawSets) ? rawSets : [];
    if (sets.length > 12) return false;
    return sets.every((setValue) => {
      const set = recordValue(setValue);
      if (!set) return false;
      const rawComponents = set.components;
      if (rawComponents != null && !Array.isArray(rawComponents)) return false;
      const components = Array.isArray(rawComponents) ? rawComponents : [];
      if (components.length > 12 || components.some((component) => !recordValue(component))) return false;
      return Boolean(
        textField(set, "training_role")
        || numberField(set, "reps") != null
        || numberField(set, "reps_target") != null
        || numberField(set, "reps_min") != null
        || numberField(set, "load_value") != null
        || numberField(set, "load_min") != null
        || components.length
      );
    });
  });
}

const knownProposalKinds = new Set<string>([
  "run_workout", "strength_workout", "training_week", "nutrition_change",
  "goal_adjustment", "calendar_change", "family_calendar_event", "planned_meal_log",
  "shopping_list", "family_task", "fitness_reminder", "chart",
]);

function proposalPreviewComplete(proposal: FitnessCoachProposal): boolean {
  if (!knownProposalKinds.has(String(proposal.kind))) return false;
  if (["family_calendar_event", "planned_meal_log", "shopping_list", "family_task", "fitness_reminder"].includes(proposal.kind)) {
    const preview = proposal.preview;
    return Boolean(
      preview
      && preview.change.length > 0
      && preview.change.length <= 80
      && preview.change.every((row) => typeof row === "string" && row.trim().length > 0 && row.trim().length <= 1_200)
      && (preview.visibility === "Private to you" || preview.visibility === "Visible to your family")
    );
  }
  const payload = recordValue(proposal.payload);
  if (!payload) return false;
  if (proposal.kind === "run_workout") return runProposalPreviewComplete(payload);
  if (proposal.kind === "strength_workout") return strengthProposalPreviewComplete(payload);
  if (proposal.kind === "training_week") {
    const sourceSessions = payload.sessions;
    if (!Array.isArray(sourceSessions) || sourceSessions.length === 0 || sourceSessions.length > 14) return false;
    return sourceSessions.every((value) => {
      const session = recordValue(value);
      if (!session || !textField(session, "title") || !textField(session, "scheduled_date")) return false;
      const sport = textField(session, "sport_key");
      if (sport === "running") return runProposalPreviewComplete(session);
      if (sport === "strength") return strengthProposalPreviewComplete(session);
      return false;
    });
  }
  if (proposal.kind === "nutrition_change") return Boolean(textField(payload, "food_or_meal") && textField(payload, "proposed_change") && textField(payload, "expected_effect"));
  if (proposal.kind === "goal_adjustment") {
    const proposed = textField(payload, "proposed_target") ?? textField(payload, "proposed_target_date");
    return Boolean(textField(payload, "goal_name") && textField(payload, "reason") && (proposed || numberField(payload, "proposed_target_value") != null));
  }
  if (proposal.kind === "calendar_change") return Boolean(textField(payload, "title") && textField(payload, "proposed_start_utc") && textField(payload, "reason"));
  if (proposal.kind === "chart") return Boolean(textField(payload, "name") && textField(payload, "measure_key") && textField(payload, "dimension_key") && textField(payload, "chart_type_key") && numberField(payload, "date_window_days") != null);
  return false;
}

function ProposalSummaryRows({ payload, keys }: { payload: Record<string, unknown>; keys: Array<{ key: string; label: string; format?: "date" | "datetime" | "duration" | "distance" | "number" }> }) {
  const rows = keys.flatMap(({ key, label, format }) => {
    const raw = format === "duration" || format === "distance" || format === "number" ? numberField(payload, key) : textField(payload, key);
    if (raw == null) return [];
    const value = format === "date" ? formatFitnessDate(String(raw)) : format === "datetime" ? formatFitnessDateTime(String(raw)) : format === "duration" ? durationLabel(Number(raw)) : format === "distance" ? distanceLabel(Number(raw)) : format === "number" ? Number(raw).toLocaleString(undefined, { maximumFractionDigits: 2 }) : String(raw).replaceAll("_", " ");
    return value ? [{ key, label, value }] : [];
  });
  if (!rows.length) return null;
  return <dl className="fitness-module__coach-proposal-summary">{rows.map((row) => <div key={row.key}><dt>{row.label}</dt><dd>{row.value}</dd></div>)}</dl>;
}

function RunProposalPreview({ payload }: { payload: Record<string, unknown> }) {
  const sourceSteps = recordArray(payload, "steps");
  const steps = boundedRunSteps(sourceSteps);
  return <>
    <ProposalSummaryRows payload={payload} keys={[
      { key: "title", label: "Workout" }, { key: "purpose", label: "Purpose" }, { key: "scheduled_start_utc", label: "Scheduled", format: "datetime" },
      { key: "scheduled_date", label: "Date", format: "date" }, { key: "estimated_duration_s", label: "Planned duration", format: "duration" },
      { key: "estimated_distance_m", label: "Planned distance", format: "distance" }, { key: "expected_difficulty", label: "Expected difficulty" },
      { key: "route_assumption", label: "Route assumption" }, { key: "terrain_assumption", label: "Terrain" }, { key: "goal_reason", label: "Goal support" },
    ]} />
    {steps.length ? <ol className="fitness-module__coach-steps">{steps.map(({ step, depth, path }) => {
      const name = textField(step, "display_name") ?? textField(step, "name") ?? `Step ${path}`;
      const durationType = textField(step, "duration_type");
      const durationValue = numberField(step, "duration_value");
      const repeatCount = numberField(step, "repeat_count");
      const targetLow = numberField(step, "target_low");
      const targetHigh = numberField(step, "target_high");
      const targetUnit = textField(step, "target_unit") ?? "";
      const target = targetLow != null || targetHigh != null ? `${targetLow ?? "—"}–${targetHigh ?? "—"} ${targetUnit}`.trim() : null;
      return <li className={depth ? "is-nested" : undefined} style={{ marginLeft: `${Math.min(depth, 4) * 14}px` }} key={path}><div><strong>{path}. {name}</strong><small>{repeatCount != null ? `Repeat ${repeatCount}×` : durationValue != null ? `${durationValue} ${durationType?.replaceAll("_", " ") ?? ""}` : "Open step"}{target ? ` · ${target}` : ""}</small></div>{textField(step, "instruction_text") ? <p>{textField(step, "instruction_text")}</p> : null}{textField(step, "mental_cue_text") || textField(step, "spoken_cue_text") ? <p><b>Cue:</b> {textField(step, "mental_cue_text") ?? textField(step, "spoken_cue_text")}</p> : null}</li>;
    })}</ol> : null}
  </>;
}

function StrengthProposalPreview({ payload }: { payload: Record<string, unknown> }) {
  const exercises = recordArray(payload, "exercises").slice(0, 24);
  return <>
    <ProposalSummaryRows payload={payload} keys={[
      { key: "title", label: "Session" }, { key: "purpose", label: "Purpose" }, { key: "scheduled_start_utc", label: "Scheduled", format: "datetime" },
      { key: "scheduled_date", label: "Date", format: "date" }, { key: "estimated_duration_s", label: "Planned duration", format: "duration" },
      { key: "location", label: "Location" }, { key: "goal_reason", label: "Goal support" },
    ]} />
    {exercises.length ? <ol className="fitness-module__coach-steps">{exercises.map((exercise, index) => {
      const name = textField(exercise, "exercise_name") ?? textField(exercise, "name") ?? `Exercise ${index + 1}`;
      const setup = textField(exercise, "setup_name");
      const sets = recordArray(exercise, "sets").slice(0, 12);
      return <li key={`${name}-${index}`}><div><strong>{name}</strong><small>{setup ? `Setup: ${setup}` : "Compatible setup selected on confirmation"}</small></div>{sets.length ? <ul>{sets.map((set, setIndex) => {
        const loadMin = numberField(set, "load_min") ?? numberField(set, "load_value");
        const loadMax = numberField(set, "load_max") ?? numberField(set, "load_value");
        const repsMin = numberField(set, "reps_min") ?? numberField(set, "reps") ?? numberField(set, "reps_target");
        const repsMax = numberField(set, "reps_max") ?? numberField(set, "reps") ?? numberField(set, "reps_target");
        const rirMin = numberField(set, "rir_min") ?? numberField(set, "rir");
        const rirMax = numberField(set, "rir_max") ?? numberField(set, "rir");
        const loadLabel = loadMin != null || loadMax != null ? `${loadMin ?? "—"}${loadMax != null && loadMax !== loadMin ? `–${loadMax}` : ""} ${textField(set, "load_unit") ?? ""}`.trim() : "load open";
        const repsLabel = repsMin != null || repsMax != null ? `${repsMin ?? "—"}${repsMax != null && repsMax !== repsMin ? `–${repsMax}` : ""} reps` : "reps open";
        const rirLabel = rirMin != null || rirMax != null ? `RIR ${rirMin ?? "—"}${rirMax != null && rirMax !== rirMin ? `–${rirMax}` : ""}` : null;
        const structure = textField(set, "structure_type")?.replaceAll("_", " ");
        const components = numberField(set, "component_count");
        return <li key={setIndex}>{textField(set, "training_role")?.replaceAll("_", " ") ?? "working"} · {structure ?? "straight"}{components != null ? ` (${components} components)` : ""} · {loadLabel} × {repsLabel}{rirLabel ? ` · ${rirLabel}` : ""}</li>;
      })}</ul> : <p>Ask Coach to add the set details before saving.</p>}</li>;
    })}</ol> : null}
  </>;
}

function OtherProposalPreview({ proposal }: { proposal: FitnessCoachProposal }) {
  const payload = proposal.payload;
  if (proposal.kind === "training_week") {
    const sessions = recordArray(payload, "sessions").slice(0, 14);
    return <><ProposalSummaryRows payload={payload} keys={[{ key: "name", label: "Week" }, { key: "purpose", label: "Purpose" }, { key: "starts_on", label: "Starts", format: "date" }]} />{sessions.length ? <ol className="fitness-module__coach-steps">{sessions.map((session, index) => {
      const sport = textField(session, "sport_key");
      const previewPayload = {
        ...session,
        estimated_duration_s: numberField(session, "expected_duration_s"),
        estimated_distance_m: numberField(session, "expected_distance_m"),
      };
      return <li key={index}><div><strong>{index + 1}. {textField(session, "title") ?? `Session ${index + 1}`}</strong><small>{sport ?? "training"}{textField(session, "scheduled_date") ? ` · ${formatFitnessDate(textField(session, "scheduled_date"))}` : ""}</small></div>{sport === "running" ? <RunProposalPreview payload={previewPayload} /> : sport === "strength" ? <StrengthProposalPreview payload={previewPayload} /> : <p>Executable session details are unavailable.</p>}</li>;
    })}</ol> : null}</>;
  }
  if (proposal.kind === "nutrition_change") {
    const target = recordField(payload, "nutrition_target");
    const meal = recordField(payload, "meal_template");
    return <><ProposalSummaryRows payload={payload} keys={[{ key: "food_or_meal", label: "Food or meal" }, { key: "observation_period", label: "Period" }, { key: "proposed_change", label: "Change" }, { key: "expected_effect", label: "Expected effect" }]} />{target ? <div className="fitness-module__coach-proposal-detail"><strong>Nutrition target</strong><ProposalSummaryRows payload={target} keys={[{ key: "target_value", label: "Target", format: "number" }, { key: "target_min", label: "Minimum", format: "number" }, { key: "target_max", label: "Maximum", format: "number" }, { key: "training_day_value", label: "Training day", format: "number" }, { key: "rest_day_value", label: "Rest day", format: "number" }, { key: "effective_from", label: "From", format: "date" }, { key: "effective_until", label: "Until", format: "date" }]} /></div> : null}{meal ? <div className="fitness-module__coach-proposal-detail"><strong>Meal template</strong><ProposalSummaryRows payload={meal} keys={[{ key: "name", label: "Name" }, { key: "meal_key", label: "Meal" }, { key: "time_relevance", label: "Best time" }]} /><p className="fitness-module__privacy-note">{recordArray(meal, "items").length} {recordArray(meal, "items").length === 1 ? "item" : "items"}</p></div> : null}</>;
  }
  if (proposal.kind === "goal_adjustment") {
    const unit = textField(payload, "unit_key");
    const currentValue = numberField(payload, "current_target_value");
    const proposedValue = numberField(payload, "proposed_target_value");
    return <><ProposalSummaryRows payload={payload} keys={[{ key: "action_type", label: "Action" }, { key: "goal_name", label: "Goal" }, { key: "current_target", label: "Current target" }, { key: "proposed_target", label: "Proposed target" }, { key: "current_target_date", label: "Current date", format: "date" }, { key: "proposed_target_date", label: "Proposed date", format: "date" }, { key: "reason", label: "Reason" }]} />{currentValue != null || proposedValue != null ? <dl className="fitness-module__coach-proposal-summary"><div><dt>Typed target</dt><dd>{currentValue ?? "—"}{unit ? ` ${unit}` : ""} → {proposedValue ?? "—"}{unit ? ` ${unit}` : ""}</dd></div></dl> : null}</>;
  }
  if (proposal.kind === "calendar_change") return <ProposalSummaryRows payload={payload} keys={[{ key: "title", label: "Session" }, { key: "current_start_utc", label: "Current time", format: "datetime" }, { key: "proposed_start_utc", label: "Proposed time", format: "datetime" }, { key: "reason", label: "Reason" }]} />;
  if (proposal.kind === "chart") return <ProposalSummaryRows payload={payload} keys={[{ key: "name", label: "Chart" }, { key: "measure_key", label: "Shows" }, { key: "dimension_key", label: "Compared by" }, { key: "chart_type_key", label: "Style" }, { key: "date_window_days", label: "Days", format: "number" }]} />;
  return null;
}

const proposalLabels: Record<FitnessCoachProposal["kind"], string> = {
  run_workout: "Run",
  strength_workout: "Strength session",
  training_week: "Training week",
  nutrition_change: "Nutrition change",
  goal_adjustment: "Goal change",
  calendar_change: "Training time",
  family_calendar_event: "Family Calendar event",
  planned_meal_log: "Planned meal",
  shopping_list: "Shopping list",
  family_task: "Family task",
  fitness_reminder: "Private reminder",
  chart: "Fitness chart",
};

const serverPreviewKinds = new Set<FitnessCoachProposal["kind"]>([
  "family_calendar_event",
  "planned_meal_log",
  "shopping_list",
  "family_task",
  "fitness_reminder",
]);

function ServerProposalPreview({ proposal }: { proposal: FitnessCoachProposal }) {
  if (!proposal.preview) return null;
  return <div className="fitness-wave5__proposal-preview">
    <ul>{proposal.preview.change.map((change, index) => <li key={`${index}:${change}`}>{change}</li>)}</ul>
    <span>{proposal.preview.visibility}</span>
  </div>;
}

type ProposalFailure = { decision: "confirm" | "decline" | "undo"; message: string };

function ProposalPreview({ proposal, decision, undo, busy, online, error, onDecision, onEdit, onOpen, onRetry }: {
  proposal: FitnessCoachProposal;
  decision?: FitnessCoachProposalDecision | null;
  undo?: FitnessCoachProposalUndo | null;
  busy: "confirm" | "decline" | "undo" | null;
  online: boolean;
  error?: ProposalFailure | null;
  onDecision: (decision: "confirm" | "decline" | "undo") => void;
  onEdit: () => void;
  onOpen: (destination: FitnessCoachProposalDestination) => void;
  onRetry: () => void;
}) {
  const knownKind = knownProposalKinds.has(String(proposal.kind));
  const completePreview = proposalPreviewComplete(proposal);
  const expiresAt = Date.parse(typeof proposal.expires_at === "string" ? proposal.expires_at : "");
  const active = Number.isFinite(expiresAt) && expiresAt > Date.now();
  const canConfirm = knownKind && proposal.validation?.valid === true && proposal.confirmable === true && completePreview && active;
  const canEdit = knownKind && completePreview;
  const destinations = decision?.next_destinations ?? [];
  const undone = undo?.status === "undone" || undo?.status === "already_undone";
  const payload = recordValue(proposal.payload) ?? {};
  const label = proposalLabels[proposal.kind] ?? "Coach suggestion";
  const title = completePreview ? textField(payload, "title") ?? textField(payload, "name") ?? label : label;
  return <article className="fitness-module__coach-proposal" aria-label={`${label} proposal`}>
    <header><div><span className="fitness-module__eyebrow"><ClipboardList aria-hidden="true" size={14} /> Review before saving</span><h4>{title}</h4></div></header>
    {completePreview ? serverPreviewKinds.has(proposal.kind) ? <ServerProposalPreview proposal={proposal} /> : proposal.kind === "run_workout" ? <RunProposalPreview payload={payload} /> : proposal.kind === "strength_workout" ? <StrengthProposalPreview payload={payload} /> : <OtherProposalPreview proposal={{ ...proposal, payload }} /> : null}
    {!completePreview && !decision ? <p className="fitness-wave5__proposal-help">Ask Coach to make this suggestion again before saving it.</p> : null}
    {error ? <div className="fitness-module__notice fitness-module__notice--error" role="alert"><span>{error.message}</span><button type="button" className="button button--secondary button--compact" disabled={!online || busy != null} onClick={onRetry}>Try again</button></div> : null}
    {decision ? <>
      <div className={cn("fitness-module__coach-decision", decision.status === "confirmed" && !undone && "is-confirmed")} role="status"><strong>{decision.status === "confirmed" ? "Saved" : decision.status === "declined" ? "Discarded" : "Not saved"}</strong></div>
      {decision.status === "confirmed" && !undone ? <div className="fitness-module__button-row">{destinations.map((destination, index) => <button type="button" className={index === 0 ? "button button--primary" : "button button--secondary"} key={`${destination.kind}:${destination.target}`} onClick={() => onOpen(destination)}>{destination.label}</button>)}<button type="button" className="button button--secondary" disabled={!online || busy != null} onClick={() => onDecision("undo")}>{busy === "undo" ? <LoaderCircle className="is-spinning" aria-hidden="true" size={16} /> : <Undo2 aria-hidden="true" size={16} />} {busy === "undo" ? "Undoing…" : "Undo"}</button></div> : null}
      {undo ? <div className={cn("fitness-module__coach-decision", undone && "is-confirmed")} role="status"><strong>{undone ? "Undone" : "Could not undo"}</strong></div> : null}
    </> : <div className="fitness-module__form-footer">
      {canConfirm ? <button type="button" className="button button--primary" disabled={!online || busy != null} onClick={() => onDecision("confirm")}>{busy === "confirm" ? <LoaderCircle className="is-spinning" aria-hidden="true" size={16} /> : <Check aria-hidden="true" size={16} />} {busy === "confirm" ? "Confirming…" : "Confirm"}</button> : null}
      <button type="button" className="button button--secondary" disabled={busy != null || !canEdit} onClick={onEdit}><Pencil aria-hidden="true" size={16} /> Edit</button>
      <button type="button" className="button button--secondary" disabled={!online || busy != null} onClick={() => onDecision("decline")}>{busy === "decline" ? <LoaderCircle className="is-spinning" aria-hidden="true" size={16} /> : <X aria-hidden="true" size={16} />} {busy === "decline" ? "Discarding…" : "Discard"}</button>
    </div>}
  </article>;
}

function CoachRecommendations({ online, revision }: { online: boolean; revision: number }) {
  const resource = useFitnessEndpoint<FitnessCoachRecommendation[] | { items?: FitnessCoachRecommendation[] }>("/fitness/coach/recommendations", [], revision);
  const recommendations = asFitnessArray(resource.data);
  const [selections, setSelections] = useState<Record<string, FitnessCoachFeedback>>({});
  const [working, setWorking] = useState<string | null>(null);
  const [feedbackError, setFeedbackError] = useState<string | null>(null);

  async function submitFeedback(recommendation: FitnessCoachRecommendation) {
    if (!online || working) return;
    const feedback = selections[recommendation.id] ?? recommendation.user_feedback ?? "accepted";
    setWorking(recommendation.id);
    setFeedbackError(null);
    try {
      await api(`/fitness/coach/recommendations/${encodeURIComponent(recommendation.id)}/feedback`, { method: "POST", body: JSON.stringify({ feedback }) }, true, false);
      resource.reload();
    } catch (requestError) {
      setFeedbackError(errorMessage(requestError));
    } finally {
      setWorking(null);
    }
  }

  return <FitnessCard title="Recommendation outcomes" detail="Tell the coach what happened so later suggestions can use your actual response.">
    {resource.loading ? <p className="fitness-module__form-status"><LoaderCircle className="is-spinning" aria-hidden="true" size={15} /> Loading recommendations…</p> : null}
    {recommendations.length ? <ul className="fitness-module__coach-recommendations">{recommendations.slice(0, 12).map((recommendation) => <li key={recommendation.id}><div><strong>{recommendation.recommendation_text}</strong>{recommendation.outcome_review ? <p>Outcome: {recommendation.outcome_review}</p> : null}</div><div className="fitness-module__form-footer"><label className="fitness-module__field">Outcome<select aria-label={`Outcome for ${recommendation.recommendation_text}`} value={selections[recommendation.id] ?? recommendation.user_feedback ?? "accepted"} onChange={(event) => setSelections((current) => ({ ...current, [recommendation.id]: event.target.value as FitnessCoachFeedback }))}>{feedbackOptions.map((option) => <option value={option.key} key={option.key}>{option.label}</option>)}</select></label><button type="button" className="button button--secondary" disabled={!online || working === recommendation.id} onClick={() => void submitFeedback(recommendation)}>{working === recommendation.id ? "Saving…" : "Save outcome"}</button></div></li>)}</ul> : !resource.loading ? <div className="fitness-module__empty"><strong>No recorded recommendations yet</strong><span>Useful recommendations appear here after a coaching response.</span></div> : null}
    {resource.error || feedbackError ? <p className="fitness-module__form-status is-error" role="alert">{feedbackError ?? resource.error}</p> : null}
  </FitnessCard>;
}

function CoachWorkspace({ online, revision, messages, setMessages, memoryEnabled, conversationId, onConversationIdChange, memoryCandidates, onMemoryCandidatesChange, onRememberCandidate, onConsentRequired, onDataChanged, coachDraft, onCoachDraftConsumed, onOpenCoachDestination }: {
  online: boolean;
  revision: number;
  messages: CoachMessage[];
  setMessages: React.Dispatch<React.SetStateAction<CoachMessage[]>>;
  memoryEnabled: boolean;
  conversationId: string | null;
  onConversationIdChange: (conversationId: string | null) => void;
  memoryCandidates: FitnessCoachMemoryCandidate[];
  onMemoryCandidatesChange: (candidates: FitnessCoachMemoryCandidate[]) => void;
  onRememberCandidate: (candidate: FitnessCoachMemoryCandidate) => Promise<void>;
  onConsentRequired: () => void;
  onDataChanged: () => void;
  coachDraft?: FitnessViewProps["coachDraft"];
  onCoachDraftConsumed?: FitnessViewProps["onCoachDraftConsumed"];
  onOpenCoachDestination?: FitnessViewProps["onOpenCoachDestination"];
}) {
  const status = useFitnessEndpoint<FitnessCoachStatus>("/fitness/coach/status", emptyCoachStatus, revision);
  const [intent, setIntent] = useState<FitnessCoachIntent>("discussion");
  const [input, setInput] = useState("");
  const [sending, setSending] = useState(false);
  const [sendError, setSendError] = useState<string | null>(null);
  const [failedMessage, setFailedMessage] = useState<string | null>(null);
  const [runtimeUnavailable, setRuntimeUnavailable] = useState<string | null>(null);
  const [pendingContextIds, setPendingContextIds] = useState<string[]>([]);
  const [proposalBusy, setProposalBusy] = useState<Record<string, "confirm" | "decline" | "undo" | null>>({});
  const [proposalErrors, setProposalErrors] = useState<Record<string, ProposalFailure | null>>({});
  const resolvingProposals = useRef(new Set<string>());
  const consumedDraftNonce = useRef<number | null>(null);
  const inputRef = useRef<HTMLTextAreaElement>(null);
  const messagesEndRef = useRef<HTMLDivElement>(null);

  const visiblePrompts = status.data.intents?.length ? starterPrompts.filter((item) => status.data.intents?.includes(item.intent)) : starterPrompts;

  useEffect(() => {
    if (!coachDraft || consumedDraftNonce.current === coachDraft.nonce) return;
    consumedDraftNonce.current = coachDraft.nonce;
    if (!input.trim()) {
      setInput(coachDraft.text);
      setPendingContextIds(coachDraft.contextIds ?? []);
    }
    onCoachDraftConsumed?.();
  }, [coachDraft, input, onCoachDraftConsumed]);

  useEffect(() => {
    if (!messages.length) return;
    const frame = window.requestAnimationFrame(() => {
      const reducedMotion = window.matchMedia?.("(prefers-reduced-motion: reduce)").matches ?? false;
      const scrollIntoView = messagesEndRef.current?.scrollIntoView;
      if (typeof scrollIntoView === "function") {
        scrollIntoView.call(messagesEndRef.current, { behavior: reducedMotion ? "auto" : "smooth", block: "end" });
      }
    });
    return () => window.cancelAnimationFrame(frame);
  }, [messages.length]);

  async function send(messageText?: string, appendUser = true) {
    const content = (messageText ?? input).trim();
    if (!content || sending || !online || status.data.status !== "available") return;
    const recent = messages.slice(-8);
    const historyMessages = !appendUser && recent.at(-1)?.role === "user" && recent.at(-1)?.content === content ? recent.slice(0, -1) : recent;
    const history = historyMessages.map(({ role, content: turnContent }) => ({ role, content: turnContent })).slice(-8);
    if (appendUser) setMessages((current) => [...current, {
      id: crypto.randomUUID(),
      role: "user",
      content,
      evidence: [],
      recommendation: null,
      proposal: null,
    } satisfies CoachMessage].slice(memoryEnabled ? -200 : -8));
    setInput("");
    setSending(true);
    setSendError(null);
    setRuntimeUnavailable(null);
    setFailedMessage(null);
    try {
      const response = await api<FitnessCoachMessageResponse>("/fitness/coach/message", {
        method: "POST",
        timeoutMs: 130_000,
        body: JSON.stringify({ message: content, intent, ...(memoryEnabled && conversationId ? { conversation_id: conversationId } : {}), history, timezone: Intl.DateTimeFormat().resolvedOptions().timeZone || "UTC", client_now: new Date().toISOString(), context_ids: pendingContextIds }),
      }, true, false);
      if (response.status === "unavailable") {
        setRuntimeUnavailable(response.answer || "The coach is temporarily unavailable. Your Fitness records and calculated views still work.");
      } else {
        setMessages((current) => [...current, {
          id: crypto.randomUUID(),
          role: "assistant",
          content: response.answer,
          evidence: response.evidence,
          recommendation: response.recommendation ?? null,
          proposal: response.proposal ?? null,
        } satisfies CoachMessage].slice(memoryEnabled ? -200 : -8));
        if (memoryEnabled && response.conversation_id) onConversationIdChange(response.conversation_id);
        onMemoryCandidatesChange(memoryEnabled ? (response.memory_candidates ?? []).slice(0, 3) : []);
        setPendingContextIds([]);
      }
    } catch (requestError) {
      setFailedMessage(content);
      if (requestError instanceof ApiError && requestError.status === 428) {
        setSendError("Allow Fitness Coach before sending your message.");
        onConsentRequired();
      } else if (requestError instanceof ApiError && (requestError.status === 429 || requestError.status === 503 || requestError.status >= 500)) {
        setRuntimeUnavailable(requestError.status === 429 ? "Coach is busy just now. Try again in a moment." : "Coach is temporarily unavailable.");
      } else {
        setSendError(errorMessage(requestError));
      }
    } finally {
      setSending(false);
    }
  }

  async function decide(message: CoachMessage, decision: "confirm" | "decline" | "undo") {
    const proposal = message.proposal;
    if (!proposal || !online || resolvingProposals.current.has(proposal.id)) return;
    resolvingProposals.current.add(proposal.id);
    setProposalBusy((current) => ({ ...current, [proposal.id]: decision }));
    setProposalErrors((current) => ({ ...current, [proposal.id]: null }));
    try {
      if (decision === "undo") {
        const response = await api<FitnessCoachProposalUndo>(`/fitness/coach/proposals/${encodeURIComponent(proposal.id)}/undo`, { method: "POST" }, true, false);
        setMessages((current) => current.map((item) => item.id === message.id ? { ...item, proposalUndo: response } : item));
        if (response.status === "undone") onDataChanged();
      } else {
        const response = await api<FitnessCoachProposalDecision>(`/fitness/coach/proposals/${encodeURIComponent(proposal.id)}/${decision}`, { method: "POST" }, true, false);
        setMessages((current) => current.map((item) => item.id === message.id ? { ...item, proposalDecision: response } : item));
        if (response.status === "confirmed") {
          onDataChanged();
        }
      }
    } catch (requestError) {
      const action = decision === "confirm" ? "save" : decision === "decline" ? "discard" : "undo";
      setProposalErrors((current) => ({ ...current, [proposal.id]: { decision, message: `Could not ${action} this yet.` } }));
    } finally {
      resolvingProposals.current.delete(proposal.id);
      setProposalBusy((current) => ({ ...current, [proposal.id]: null }));
    }
  }

  function editProposal(proposal: FitnessCoachProposal) {
    const payload = recordValue(proposal.payload) ?? {};
    const review = serverPreviewKinds.has(proposal.kind)
      ? proposal.preview?.change[0]
      : textField(payload, "title") ?? textField(payload, "name") ?? proposalLabels[proposal.kind];
    setInput(`Please revise this suggestion: ${review ?? "Coach suggestion"}.`);
    window.requestAnimationFrame(() => {
      inputRef.current?.focus();
      inputRef.current?.scrollIntoView({ block: "center" });
    });
  }

  const unavailable = !online || status.data.status === "unavailable" || Boolean(runtimeUnavailable);
  return <div className="fitness-module__coach-workspace">
    <FitnessCard title="Ask Coach" detail="Get a useful answer or a ready-to-review plan." className="is-wide fitness-wave5__coach-card">
      <div className="fitness-wave5__starter-prompts" role="group" aria-label="Start with a prompt">{visiblePrompts.map((item) => { const Icon = item.icon; return <button type="button" onClick={() => { setIntent(item.intent); setInput(item.prompt); inputRef.current?.focus(); }} key={item.label}><Icon aria-hidden="true" size={17} /><span>{item.label}</span></button>; })}</div>
      {pendingContextIds.length ? <p className="fitness-module__form-status" role="status"><MessageCircle aria-hidden="true" size={15} /> Using this activity and nearby sessions as context</p> : null}
      <form className="fitness-module__coach-composer fitness-wave5__composer" onSubmit={(event) => { event.preventDefault(); void send(); }}><label className="sr-only" htmlFor="fitness-coach-message">Message your Fitness coach</label><textarea ref={inputRef} id="fitness-coach-message" rows={3} maxLength={2_000} value={input} onChange={(event) => setInput(event.target.value)} placeholder="Ask Coach about training, food, recovery or your week…" /><button type="submit" className="button button--primary" disabled={sending || !input.trim() || unavailable || status.loading || Boolean(status.error)}>{sending ? <LoaderCircle className="is-spinning" aria-hidden="true" size={17} /> : <Send aria-hidden="true" size={17} />} {sending ? "Thinking…" : "Send"}</button></form>
      <p className="fitness-wave5__disclaimer">Reminders and coaching only — not medical advice.</p>
      {status.loading ? <p className="fitness-module__form-status"><LoaderCircle className="is-spinning" aria-hidden="true" size={16} /> Getting Coach ready…</p> : null}
      {status.error ? <div className="fitness-module__notice fitness-module__notice--error" role="alert"><span>Coach could not connect.</span><button type="button" className="button button--secondary" onClick={status.reload}>Try again</button></div> : null}
      {!status.loading && !status.error && unavailable ? <div className="fitness-module__notice" role="status"><strong>{!online ? "Coach needs a connection" : "Coach is taking a break"}</strong><span>{runtimeUnavailable ?? "Try again shortly."}</span>{online ? <button type="button" className="button button--secondary" onClick={() => { setRuntimeUnavailable(null); status.reload(); }}><RefreshCw aria-hidden="true" size={15} /> Try again</button> : null}</div> : null}
      {sendError ? <div className="fitness-module__notice fitness-module__notice--error" role="alert"><span>{sendError}</span>{failedMessage && online && status.data.status === "available" ? <button type="button" className="button button--secondary" onClick={() => void send(failedMessage, false)}>Try again</button> : null}</div> : null}
      {messages.length ? <div className="fitness-module__coach-messages" aria-live="polite">{messages.map((message) => <article className={cn("fitness-module__coach-message", `is-${message.role}`)} key={message.id}><header>{message.role === "assistant" ? <span><Sparkles aria-hidden="true" size={14} /> Coach</span> : <span>You</span>}</header><p>{message.content}</p>{message.role === "assistant" && message.proposal ? <ProposalPreview proposal={message.proposal} decision={message.proposalDecision} undo={message.proposalUndo} busy={proposalBusy[message.proposal.id] ?? null} error={proposalErrors[message.proposal.id] ?? null} online={online} onDecision={(next) => void decide(message, next)} onEdit={() => editProposal(message.proposal!)} onOpen={(destination) => onOpenCoachDestination?.(destination)} onRetry={() => { const failure = proposalErrors[message.proposal!.id]; if (failure) void decide(message, failure.decision); }} /> : null}</article>)}<div className="fitness-wave5__messages-end" ref={messagesEndRef} aria-hidden="true" /></div> : null}
      {memoryEnabled ? <FitnessCoachMemoryCandidates candidates={memoryCandidates} online={online} onRemember={onRememberCandidate} /> : null}
    </FitnessCard>
  </div>;
}

function coachOwnerKey(): string {
  const owner = currentOfflineQueueOwner();
  return owner ? `${owner.familyId}:${owner.userId}` : "current-session";
}

export function FitnessCoachView(props: FitnessViewProps) {
  const ownerKey = coachOwnerKey();
  return <FitnessCoachOwnerView key={ownerKey} {...props} ownerKey={ownerKey} />;
}

function FitnessCoachOwnerView({ online, revision, onDataChanged, ownerKey, coachDraft, onCoachDraftConsumed, onOpenCoachDestination }: FitnessViewProps & { ownerKey: string }) {
  const aiConsent = useAIConsent(true);
  const [messages, setMessages] = useState<CoachMessage[]>([]);
  const [memoryEnabled, setMemoryEnabled] = useState(false);
  const [conversationId, setConversationId] = useState<string | null>(null);
  const [memoryCandidates, setMemoryCandidates] = useState<FitnessCoachMemoryCandidate[]>([]);
  const [memoryRevision, setMemoryRevision] = useState(0);
  const [personaliseOpen, setPersonaliseOpen] = useState(() => new URL(window.location.href).searchParams.get("fitness-personalise") === "reminders");
  const focusReminderId = new URL(window.location.href).searchParams.get("fitness-reminder");

  useEffect(() => {
    let active = true;
    if (!online || !aiConsent.status?.consented) {
      setMemoryEnabled(false);
      setMemoryCandidates([]);
      return () => { active = false; };
    }
    void api<FitnessCoachMemorySettings>("/fitness/coach/memory/settings", {}, true, false)
      .then((settings) => {
        if (active) setMemoryEnabled(settings.enabled === true);
      })
      .catch(() => {
        if (active) setMemoryEnabled(false);
      });
    return () => { active = false; };
  }, [aiConsent.status?.consented, online, ownerKey]);

  async function rememberCandidate(candidate: FitnessCoachMemoryCandidate) {
    await api("/fitness/coach/memories", {
      method: "POST",
      body: JSON.stringify({ content: candidate.content, ...(candidate.category ? { category: candidate.category } : {}) }),
    }, true, false);
    setMemoryCandidates((current) => current.filter((item) => item !== candidate));
    setMemoryRevision((value) => value + 1);
  }

  function openStoredConversation(conversation: FitnessCoachConversation, resume: boolean) {
    setConversationId(resume ? conversation.id : null);
    setMemoryCandidates([]);
    setMessages(storedCoachMessages(conversation.messages));
  }

  const consentPanel = useMemo(() => {
    if (aiConsent.loading) return <div className="fitness-module__notice" role="status"><LoaderCircle className="is-spinning" aria-hidden="true" size={17} /> Checking your OpenAI privacy choice…</div>;
    if (!aiConsent.status) return <div className="fitness-module__notice fitness-module__notice--error" role="alert"><strong>AI privacy settings could not be loaded</strong><span>{aiConsent.error ?? "Try again when HausKlar is connected."}</span><button type="button" className="button button--secondary" onClick={() => void aiConsent.reload()}>Try again</button></div>;
    if (!aiConsent.status.consented) return <AIConsentPrompt
      title="Allow Fitness Coach to use OpenAI?"
      summary="When you press Send, HausKlar shares your message and the relevant Fitness records needed for the answer."
      assurances={[
        "Private conversation memory stays off unless you enable it",
        "No plan or record changes automatically; every write requires confirmation",
        "Withdraw permission at any time in Settings",
      ]}
      status={aiConsent.status}
      busy={aiConsent.busy}
      error={aiConsent.error}
      onAllow={() => void aiConsent.grant()}
    />;
    return null;
  }, [aiConsent]);

  return <section aria-label="Coach">
    <FitnessPageHeading title="Coach" detail="Personal coaching that fits your training and family week." />
    {consentPanel}
    {aiConsent.status?.consented ? <>
      <CoachWorkspace online={online} revision={revision} messages={messages} setMessages={setMessages} memoryEnabled={memoryEnabled} conversationId={conversationId} onConversationIdChange={setConversationId} memoryCandidates={memoryCandidates} onMemoryCandidatesChange={setMemoryCandidates} onRememberCandidate={rememberCandidate} onConsentRequired={() => void aiConsent.reload()} onDataChanged={onDataChanged} coachDraft={coachDraft} onCoachDraftConsumed={onCoachDraftConsumed} onOpenCoachDestination={onOpenCoachDestination} />
    </> : null}
    <details className="fitness-module__maintenance fitness-module__coach-personalise" open={personaliseOpen} onToggle={(event) => setPersonaliseOpen(event.currentTarget.open)}><summary>Personalise coach</summary><div className="fitness-module__maintenance-body">{personaliseOpen ? <><FitnessCoachContextPreferencesCard online={online} revision={revision} /><FitnessCoachRemindersCard online={online} revision={revision} focusReminderId={focusReminderId} /><FitnessCoachPreferencesCard online={online} revision={revision} /><CoachRecommendations online={online} revision={revision} />{aiConsent.status?.consented ? <FitnessCoachMemoryPanel online={online} ownerKey={ownerKey} revision={revision} dataRevision={memoryRevision} activeConversationId={conversationId} onEnabledChange={(enabled) => { setMemoryEnabled(enabled); if (!enabled) setMemoryCandidates([]); }} onOpenConversation={openStoredConversation} onNewConversation={(nextConversationId) => { setConversationId(nextConversationId); setMemoryCandidates([]); setMessages([]); }} onDetachConversation={() => { setConversationId(null); setMemoryCandidates([]); }} onStoredDataChanged={() => setMemoryRevision((value) => value + 1)} /> : null}</> : null}</div></details>
  </section>;
}
