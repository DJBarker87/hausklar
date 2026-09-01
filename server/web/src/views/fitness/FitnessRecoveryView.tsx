import {
  BedDouble,
  HeartPulse,
  MoonStar,
  Plus,
  SlidersHorizontal,
  TriangleAlert,
} from "lucide-react";
import { useEffect, useMemo, useState } from "react";

import { cn } from "../../components/ui";
import type {
  FitnessBodyIssue,
  FitnessBodyLocation,
  FitnessRecoveryObservation,
  FitnessRecoverySummary,
  FitnessSessionCheckin,
  FitnessSleepSession,
} from "../../fitness/contract";
import { FitnessCycleTracking } from "./FitnessCycleTracking";
import type { FitnessViewProps } from "./FitnessModuleView";
import "./fitness-wave4.css";
import {
  FitnessCard,
  FitnessFormStatus,
  FitnessLoadingOrError,
  FitnessPageHeading,
  formatFitnessDate,
  formatFitnessDateTime,
  localDateTimeValue,
  localDateValue,
  submitForm,
  useFitnessCollection,
  useFitnessEndpoint,
  useFitnessSave,
  utcFromLocalInput,
} from "./shared";

type RecoveryManagePanel = "signals" | "issues" | "cycles";

const emptySummary: FitnessRecoverySummary = {
  window: { from_date: "", to_date: "", expected_days: 0, days_with_sleep: 0 },
  sleep: {},
  baselines: [],
  relationships: [],
};

const observationChoices = {
  "recovery.resting_heart_rate_bpm": { label: "Resting heart rate", unit: "bpm", min: 20, max: 250 },
  "recovery.hrv_rmssd_ms": { label: "Heart-rate variability", unit: "ms", min: 0, max: 1000 },
  "sleep.quality": { label: "Sleep quality", unit: "/5", min: 1, max: 5 },
  general_fatigue: { label: "General fatigue", unit: "/5", min: 1, max: 5 },
  general_soreness: { label: "General soreness", unit: "/5", min: 1, max: 5 },
  "recovery.stress": { label: "Stress", unit: "/5", min: 1, max: 5 },
} as const;

type ObservationKey = keyof typeof observationChoices;

function formatDuration(seconds?: number | null): string {
  if (seconds == null || !Number.isFinite(seconds)) return "Not enough sleep logged";
  const hours = Math.floor(seconds / 3_600);
  const minutes = Math.round(seconds % 3_600 / 60);
  return hours ? `${hours}h ${minutes}m` : `${minutes}m`;
}

function formatClock(value?: number | null): string | null {
  if (value == null || !Number.isFinite(value)) return null;
  const minutes = ((Math.round(value) % 1_440) + 1_440) % 1_440;
  return `${String(Math.floor(minutes / 60)).padStart(2, "0")}:${String(minutes % 60).padStart(2, "0")}`;
}

function humanConnection(session: FitnessSleepSession): string {
  const connection = session.source;
  if (!connection) return "Manual entry";
  const known: Record<string, string> = { apple: "Apple Health", garmin: "Garmin", withings: "Withings", healthkit: "Apple Health" };
  return known[connection.origin_provider_key] ?? known[connection.transport_key] ?? connection.source_name ?? "Connected app";
}

function initialManagePanel(): RecoveryManagePanel {
  const query = new URLSearchParams(window.location.search);
  if (query.has("fitness-issue")) return "issues";
  if (query.get("cycle") === "1") return "cycles";
  return "signals";
}

function ReadinessChoice({ value, selected, onSelect }: { value: number; selected: number; onSelect: (value: number) => void }) {
  const labels = ["Very low", "Low", "Okay", "Good", "Excellent"];
  return <button type="button" className={cn(selected === value && "is-active")} aria-label={`Readiness ${value}, ${labels[value - 1]}`} aria-pressed={selected === value} onClick={() => onSelect(value)}><strong>{value}</strong><span>{labels[value - 1]}</span></button>;
}

function SleepTrend({ sessions }: { sessions: FitnessSleepSession[] }) {
  const visible = [...sessions].sort((left, right) => left.sleep_start_utc.localeCompare(right.sleep_start_utc)).slice(-10);
  if (!visible.length) return <div className="fitness-module__empty"><MoonStar aria-hidden="true" size={24} /><strong>No sleep logged yet</strong><span>Add last night’s sleep to begin a useful pattern.</span></div>;
  const average = visible.reduce((total, session) => total + session.duration_s, 0) / visible.length;
  const summary = `${visible.length} recent nights, averaging ${formatDuration(average)}.`;
  return <figure className="fitness-wave4__sleep-chart"><figcaption><span>Recent sleep</span><strong>{summary}</strong></figcaption><div role="img" aria-label={summary}>{visible.map((session) => <div key={session.id}><i style={{ height: `${Math.max(8, Math.min(100, session.duration_s / (10 * 3_600) * 100))}%` }} /><span>{new Intl.DateTimeFormat(undefined, { weekday: "narrow" }).format(new Date(session.sleep_start_utc))}</span></div>)}</div></figure>;
}

function ManualSleepForm({ onDataChanged, onClose }: { onDataChanged: () => void; onClose: () => void }) {
  const save = useFitnessSave(onDataChanged);
  const [start, setStart] = useState(() => localDateTimeValue(new Date(Date.now() - 8 * 3_600_000)));
  const [end, setEnd] = useState(localDateTimeValue());
  const [awakeMinutes, setAwakeMinutes] = useState("");
  const [note, setNote] = useState("");
  const [formError, setFormError] = useState<string | null>(null);

  async function record() {
    const startDate = new Date(start);
    const endDate = new Date(end);
    const duration = Math.round((endDate.valueOf() - startDate.valueOf()) / 1_000);
    if (!Number.isFinite(duration) || duration <= 0) { setFormError("Wake time must be after sleep start."); return; }
    setFormError(null);
    await save.save("sleep_session", {
      sleep_start_utc: startDate.toISOString(),
      sleep_end_utc: endDate.toISOString(),
      duration_s: duration,
      awake_duration_s: awakeMinutes ? Number(awakeMinutes) * 60 : null,
      source_quality: "manual",
      source_stages: [],
      source: null,
      notes: note.trim() || null,
    });
    onClose();
  }

  return <FitnessCard title="Add sleep" detail="Use the times you remember. You can keep the rest blank."><form className="fitness-module__form" onSubmit={submitForm(record)}><div className="fitness-module__fields"><label className="fitness-module__field">Sleep start<input type="datetime-local" required value={start} onChange={(event) => setStart(event.target.value)} /></label><label className="fitness-module__field">Wake time<input type="datetime-local" required value={end} onChange={(event) => setEnd(event.target.value)} /></label><label className="fitness-module__field">Minutes awake (optional)<input type="text" inputMode="numeric" pattern="[0-9]*" value={awakeMinutes} onChange={(event) => setAwakeMinutes(event.target.value)} /></label><label className="fitness-module__field is-wide">Note (optional)<textarea value={note} onChange={(event) => setNote(event.target.value)} /></label></div>{formError ? <p className="fitness-module__form-status is-error" role="alert">{formError}</p> : null}<div className="fitness-module__form-footer"><button type="submit" className="button button--primary" aria-busy={save.saving} disabled={save.saving}>Save sleep</button><button type="button" className="button button--secondary" onClick={onClose}>Cancel</button><FitnessFormStatus saving={save.saving} saved={save.saved} error={save.saveError} /></div></form></FitnessCard>;
}

function ReadinessLog({ onDataChanged }: { onDataChanged: () => void }) {
  const save = useFitnessSave(onDataChanged);
  const [readiness, setReadiness] = useState(3);
  const [energy, setEnergy] = useState("");
  const [soreness, setSoreness] = useState("");
  const [motivation, setMotivation] = useState("");
  const [note, setNote] = useState("");

  async function record() {
    await save.save("session_checkin", {
      timing: "pre",
      captured_at_utc: new Date().toISOString(),
      capture_quality: "contemporaneous",
      captured_before_activity_start: true,
      readiness_1_5: readiness,
      energy_1_5: energy ? Number(energy) : null,
      soreness_1_5: soreness ? Number(soreness) : null,
      motivation_1_5: motivation ? Number(motivation) : null,
      notes: note.trim() || null,
    });
    setNote("");
  }

  return <FitnessCard title="How ready do you feel?" detail="One tap is enough. Add context only when it helps." className="fitness-wave4__readiness-log"><form className="fitness-module__form" onSubmit={submitForm(record)}><fieldset><legend className="sr-only">Readiness from one to five</legend><div className="fitness-wave4__readiness-choices">{[1, 2, 3, 4, 5].map((value) => <ReadinessChoice key={value} value={value} selected={readiness} onSelect={setReadiness} />)}</div></fieldset><details className="fitness-module__details"><summary>Add energy, soreness, motivation or a note</summary><div className="fitness-module__fields"><label className="fitness-module__field">Energy (1–5)<input type="text" inputMode="numeric" pattern="[1-5]" value={energy} onChange={(event) => setEnergy(event.target.value)} /></label><label className="fitness-module__field">Soreness (1–5)<input type="text" inputMode="numeric" pattern="[1-5]" value={soreness} onChange={(event) => setSoreness(event.target.value)} /></label><label className="fitness-module__field">Motivation (1–5)<input type="text" inputMode="numeric" pattern="[1-5]" value={motivation} onChange={(event) => setMotivation(event.target.value)} /></label><label className="fitness-module__field is-wide">Note<textarea value={note} onChange={(event) => setNote(event.target.value)} /></label></div></details><div className="fitness-module__form-footer"><button type="submit" className="button button--primary" aria-busy={save.saving} disabled={save.saving}>Save readiness</button><FitnessFormStatus saving={save.saving} saved={save.saved} error={save.saveError} /></div></form></FitnessCard>;
}

function RecoverySignalsManager({ revision, online, summary, sleep, onDataChanged }: {
  revision: number;
  online: boolean;
  summary: FitnessRecoverySummary;
  sleep: FitnessSleepSession[];
  onDataChanged: () => void;
}) {
  const fromDate = localDateValue(new Date(Date.now() - 27 * 86_400_000));
  const toDate = localDateValue();
  const observations = useFitnessCollection<FitnessRecoveryObservation>(`/fitness/recovery/observations?from_date=${fromDate}&to_date=${toDate}`, "recovery_observation", revision);
  const save = useFitnessSave(onDataChanged);
  const [formOpen, setFormOpen] = useState(false);
  const [kind, setKind] = useState<ObservationKey>("sleep.quality");
  const [value, setValue] = useState("");
  const [observedAt, setObservedAt] = useState(localDateTimeValue());
  const [note, setNote] = useState("");
  const choice = observationChoices[kind];

  useEffect(() => {
    const targetKey = new URLSearchParams(window.location.search).get("fitness-recovery");
    if (!targetKey || !summary.baselines.some((item) => item.metric_key === targetKey)) return;
    const target = document.getElementById(`fitness-recovery-${targetKey}`);
    const reducedMotion = window.matchMedia?.("(prefers-reduced-motion: reduce)").matches ?? false;
    target?.scrollIntoView({ block: "center", behavior: reducedMotion ? "auto" : "smooth" });
    target?.focus({ preventScroll: true });
    const url = new URL(window.location.href);
    url.searchParams.delete("fitness-recovery");
    window.history.replaceState(window.history.state, "", url);
  }, [summary.baselines]);

  async function record() {
    await save.save("recovery_observation", { metric_key: kind, observed_at_utc: utcFromLocalInput(observedAt), value_number: Number(value), value_text: null, unit_key: choice.unit, source_quality: "manual", source: null, notes: note.trim() || null });
    setValue("");
    setNote("");
    setFormOpen(false);
  }

  const connections = [...new Set(sleep.filter((session) => session.source).map(humanConnection))];
  return <div className="fitness-wave4__manage-panel">
    <div className="fitness-module__button-row"><button type="button" className="button button--primary" onClick={() => setFormOpen((open) => !open)}><Plus aria-hidden="true" size={17} /> Add recovery note</button></div>
    {formOpen ? <FitnessCard title="Add a recovery value" detail="Record the number you know; leave anything else alone."><form className="fitness-module__form" onSubmit={submitForm(record)}><div className="fitness-module__fields"><label className="fitness-module__field">What are you recording?<select value={kind} onChange={(event) => { setKind(event.target.value as ObservationKey); setValue(""); }}>{Object.entries(observationChoices).map(([key, item]) => <option value={key} key={key}>{item.label}</option>)}</select></label><label className="fitness-module__field">Value ({choice.unit})<input type="text" inputMode="decimal" required value={value} aria-describedby="recovery-value-range" onChange={(event) => setValue(event.target.value)} /><small id="recovery-value-range">Between {choice.min} and {choice.max}</small></label><label className="fitness-module__field">When<input type="datetime-local" required value={observedAt} onChange={(event) => setObservedAt(event.target.value)} /></label><label className="fitness-module__field is-wide">Note (optional)<textarea value={note} onChange={(event) => setNote(event.target.value)} /></label></div><div className="fitness-module__form-footer"><button type="submit" className="button button--primary" disabled={save.saving || !value || Number(value) < choice.min || Number(value) > choice.max}>Save value</button><button type="button" className="button button--secondary" onClick={() => setFormOpen(false)}>Cancel</button><FitnessFormStatus saving={save.saving} saved={save.saved} error={save.saveError} /></div></form></FitnessCard> : null}
    <FitnessCard title="Personal signals" detail="Recent values compared with your usual range.">{summary.baselines.length ? <div className="fitness-wave4__signal-list">{summary.baselines.map((item) => <article id={`fitness-recovery-${item.metric_key}`} tabIndex={-1} key={item.metric_key}><div><strong>{item.label}</strong><small>{item.current_value != null ? `${item.current_value.toFixed(1)} ${item.unit_key ?? ""}` : "More readings needed"}</small></div><span className={cn("fitness-module__pill", item.status === "within_baseline" ? "is-success" : item.status === "insufficient_data" ? "is-neutral" : "is-warning")}>{item.status === "within_baseline" ? "Usual range" : item.status === "insufficient_data" ? "Building a pattern" : item.status === "above_baseline" ? "Above usual" : "Below usual"}</span></article>)}</div> : <div className="fitness-module__empty"><HeartPulse aria-hidden="true" size={24} /><strong>No personal pattern yet</strong><span>A few more readings will make this comparison useful.</span></div>}</FitnessCard>
    <FitnessCard title="Recent recovery values" detail="Values you added manually or chose to bring in."><FitnessLoadingOrError loading={observations.loading} error={observations.error} retry={observations.reload} />{!observations.loading && !observations.error && observations.data.length ? <ul className="fitness-module__list">{[...observations.data].sort((left, right) => right.observed_at_utc.localeCompare(left.observed_at_utc)).slice(0, 12).map((item) => <li key={item.id}><div><strong>{observationChoices[item.metric_key as ObservationKey]?.label ?? "Recovery value"}</strong><small>{formatFitnessDateTime(item.observed_at_utc)}</small></div><span className="fitness-module__pill is-neutral">{item.value_number ?? item.value_text ?? "—"} {item.unit_key ?? ""}</span></li>)}</ul> : !observations.loading && !observations.error ? <div className="fitness-module__empty"><strong>No recovery values yet</strong><span>Add one only when it helps explain how you feel.</span></div> : null}</FitnessCard>
    <FitnessCard title="Connected apps" detail="Recovery can use values you deliberately bring into HausKlar.">{connections.length ? <ul className="fitness-module__list">{connections.map((connection) => <li key={connection}><strong>{connection}</strong></li>)}</ul> : <div className="fitness-module__empty"><strong>No connected recovery app</strong><span>Manual sleep and readiness still work fully.</span></div>}{!online ? <p className="fitness-module__muted">Connect to the internet to refresh connected values.</p> : null}</FitnessCard>
    {summary.relationships.length ? <FitnessCard title="Recovery and training" detail="Patterns seen across comparable sessions."><ul className="fitness-module__list">{summary.relationships.map((relationship) => <li key={relationship.label}><div><strong>{relationship.label}</strong><p>{relationship.summary}</p><small>{relationship.sample_size} comparable sessions</small></div></li>)}</ul></FitnessCard> : null}
  </div>;
}

function bodyLocationLabel(key: string, locations: FitnessBodyLocation[]): string {
  return locations.find((item) => item.location_key === key)?.display_name ?? key.replaceAll("_", " ");
}

function BodyIssuesManager({ revision, onDataChanged }: { revision: number; onDataChanged: () => void }) {
  const issues = useFitnessCollection<FitnessBodyIssue>("/fitness/body-issues", "body_issue", revision);
  const locations = useFitnessEndpoint<FitnessBodyLocation[]>("/fitness/body-locations", [], revision);
  const save = useFitnessSave(onDataChanged);
  const [formOpen, setFormOpen] = useState(false);
  const [when, setWhen] = useState(localDateTimeValue());
  const [kind, setKind] = useState("pain");
  const [location, setLocation] = useState("");
  const [side, setSide] = useState("not_applicable");
  const [severity, setSeverity] = useState("3");
  const [changedSession, setChangedSession] = useState(false);
  const [note, setNote] = useState("");
  const loading = issues.loading || locations.loading;
  const error = issues.error ?? locations.error;

  useEffect(() => {
    if (loading || error) return;
    const issueId = new URLSearchParams(window.location.search).get("fitness-issue");
    if (!issueId) return;
    const target = document.getElementById(`fitness-issue-${issueId}`) ?? document.getElementById("fitness-body-issues");
    const reducedMotion = window.matchMedia?.("(prefers-reduced-motion: reduce)").matches ?? false;
    target?.scrollIntoView({ block: "center", behavior: reducedMotion ? "auto" : "smooth" });
    target?.focus({ preventScroll: true });
    const url = new URL(window.location.href);
    url.searchParams.delete("fitness-issue");
    window.history.replaceState(window.history.state, "", url);
  }, [error, issues.data, loading]);

  async function record() {
    await save.save("body_issue", { observed_at_utc: utcFromLocalInput(when), timing: "standalone", issue_type_key: kind, body_location_key: location, side, severity_0_10: Number(severity), changed_session: changedSession, session_change_key: changedSession ? "reduced_load" : "none", trend_key: "new", status: "active", resolved_at_utc: null, notes: note.trim() || null });
    setFormOpen(false);
    setLocation("");
    setNote("");
  }

  async function resolve(issue: FitnessBodyIssue) {
    await save.save("body_issue", { planned_session_id: issue.planned_session_id ?? null, activity_id: issue.activity_id ?? null, observed_at_utc: issue.observed_at_utc, timing: issue.timing, issue_type_key: issue.issue_type_key, body_location_key: issue.body_location_key, side: issue.side ?? "unknown", severity_0_10: issue.severity_0_10, changed_session: issue.changed_session, session_change_key: issue.session_change_key, trend_key: issue.trend_key ?? "unknown", status: "resolved", resolved_at_utc: new Date().toISOString(), notes: issue.notes ?? null }, { entityId: issue.id, baseRevision: issue.revision ?? null });
    issues.reload();
  }

  const active = issues.data.filter((issue) => issue.status !== "resolved").sort((left, right) => right.observed_at_utc.localeCompare(left.observed_at_utc));
  const resolved = issues.data.filter((issue) => issue.status === "resolved").sort((left, right) => right.observed_at_utc.localeCompare(left.observed_at_utc));
  return <div id="fitness-body-issues" tabIndex={-1} className="fitness-wave4__manage-panel"><FitnessLoadingOrError loading={loading} error={error} retry={() => { issues.reload(); locations.reload(); }} />{!loading && !error ? <>
    <button type="button" className="button button--primary" onClick={() => setFormOpen((open) => !open)}><TriangleAlert aria-hidden="true" size={17} /> Add body issue</button>
    {formOpen ? <FitnessCard title="Add a body issue" detail="Record what you noticed and whether it changed training."><form className="fitness-module__form" onSubmit={submitForm(record)}><div className="fitness-module__fields"><label className="fitness-module__field">When<input type="datetime-local" required value={when} onChange={(event) => setWhen(event.target.value)} /></label><label className="fitness-module__field">Type<select value={kind} onChange={(event) => setKind(event.target.value)}><option value="pain">Pain</option><option value="tightness">Tightness</option><option value="discomfort">Discomfort</option><option value="weakness">Weakness</option><option value="injury">Injury</option><option value="other">Other</option></select></label><label className="fitness-module__field">Body area<select required value={location} onChange={(event) => setLocation(event.target.value)}><option value="">Choose area</option>{locations.data.filter((item) => item.active).map((item) => <option value={item.location_key} key={item.location_key}>{item.display_name}</option>)}</select></label><label className="fitness-module__field">Side<select value={side} onChange={(event) => setSide(event.target.value)}><option value="not_applicable">Not applicable</option><option value="left">Left</option><option value="right">Right</option><option value="bilateral">Both sides</option><option value="midline">Midline</option></select></label><label className="fitness-module__field">Severity: {severity}/10<input type="range" min="0" max="10" value={severity} onChange={(event) => setSeverity(event.target.value)} /></label><label className="fitness-module__check"><input type="checkbox" checked={changedSession} onChange={(event) => setChangedSession(event.target.checked)} /> This changed a session</label><label className="fitness-module__field is-wide">Note (optional)<textarea value={note} onChange={(event) => setNote(event.target.value)} /></label></div><div className="fitness-module__form-footer"><button type="submit" className="button button--primary" disabled={save.saving || !location}>Save issue</button><button type="button" className="button button--secondary" onClick={() => setFormOpen(false)}>Cancel</button><FitnessFormStatus saving={save.saving} saved={save.saved} error={save.saveError} /></div></form></FitnessCard> : null}
    <FitnessCard title="Active body issues" detail="Keep only the observations that still affect what you can do.">{active.length ? <ul className="fitness-module__list">{active.map((issue) => <li id={`fitness-issue-${issue.id}`} tabIndex={-1} key={issue.id}><div><strong>{bodyLocationLabel(issue.body_location_key, locations.data)} · {issue.severity_0_10}/10</strong><small>{formatFitnessDateTime(issue.observed_at_utc)} · {issue.issue_type_key}</small></div><button type="button" className="button button--secondary button--compact" disabled={save.saving} onClick={() => void resolve(issue)}>Mark resolved</button></li>)}</ul> : <div className="fitness-module__empty"><strong>No active body issues</strong><span>Add one when it changes what you can sensibly do.</span></div>}{resolved.length ? <details className="fitness-module__details"><summary>Resolved history ({resolved.length})</summary><ul className="fitness-module__list">{resolved.map((issue) => <li id={`fitness-issue-${issue.id}`} tabIndex={-1} key={issue.id}><div><strong>{bodyLocationLabel(issue.body_location_key, locations.data)} · {issue.severity_0_10}/10</strong><small>{formatFitnessDateTime(issue.observed_at_utc)}</small></div></li>)}</ul></details> : null}</FitnessCard>
  </> : null}</div>;
}

export function FitnessRecoveryView({ online, revision, onDataChanged }: FitnessViewProps) {
  const fromDate = localDateValue(new Date(Date.now() - 27 * 86_400_000));
  const toDate = localDateValue();
  const range = `from_date=${encodeURIComponent(fromDate)}&to_date=${encodeURIComponent(toDate)}`;
  const sleep = useFitnessCollection<FitnessSleepSession>(`/fitness/sleep/sessions?${range}&limit=100&offset=0`, "sleep_session", revision);
  const summary = useFitnessEndpoint<FitnessRecoverySummary>(`/fitness/recovery/summary?${range}`, emptySummary, revision);
  const [sleepFormOpen, setSleepFormOpen] = useState(false);
  const [managePanel, setManagePanel] = useState<RecoveryManagePanel>(initialManagePanel);
  const [manageOpen, setManageOpen] = useState(() => {
    const query = new URLSearchParams(window.location.search);
    return query.has("fitness-issue") || query.has("fitness-recovery") || query.get("cycle") === "1";
  });
  const orderedSleep = useMemo(() => [...sleep.data].sort((left, right) => right.sleep_start_utc.localeCompare(left.sleep_start_utc)), [sleep.data]);
  const bedtime = formatClock(summary.data.sleep.average_bedtime_minutes);
  const wakeTime = formatClock(summary.data.sleep.average_wake_time_minutes);
  const loading = sleep.loading || summary.loading;
  const error = sleep.error ?? summary.error;

  function changeManagePanel(next: RecoveryManagePanel) {
    setManagePanel(next);
    setManageOpen(true);
    window.requestAnimationFrame(() => {
      const query = new URLSearchParams(window.location.search);
      const targetId = next === "issues" ? query.get("fitness-issue") : query.get("fitness-recovery");
      if (!targetId) return;
      const target = document.getElementById(next === "issues" ? `fitness-issue-${targetId}` : `fitness-recovery-${targetId}`);
      target?.scrollIntoView({ block: "center", behavior: window.matchMedia?.("(prefers-reduced-motion: reduce)").matches ? "auto" : "smooth" });
      target?.focus({ preventScroll: true });
    });
  }

  return <section aria-label="Recovery" className="fitness-wave4__recovery">
    <FitnessPageHeading title="Recovery" detail="Sleep, readiness and how you feel today." actions={<button type="button" className="button button--secondary" onClick={() => setSleepFormOpen((open) => !open)}><BedDouble aria-hidden="true" size={17} /> {sleepFormOpen ? "Close" : "Add sleep"}</button>} />
    {sleepFormOpen ? <ManualSleepForm onDataChanged={onDataChanged} onClose={() => setSleepFormOpen(false)} /> : null}
    <FitnessLoadingOrError loading={loading} error={error} retry={() => { sleep.reload(); summary.reload(); }} />
    {!loading && !error ? <FitnessCard className="fitness-wave4__recovery-summary"><div className="fitness-wave4__recovery-heading"><div><span>Last 4 weeks</span><h3>{formatDuration(summary.data.sleep.average_duration_s)} average sleep</h3><p>{summary.data.window.days_with_sleep ? `${summary.data.window.days_with_sleep} nights logged` : "Add sleep to begin your pattern"}{bedtime && wakeTime ? ` · usually ${bedtime}–${wakeTime}` : ""}</p></div>{summary.data.sleep.timing_regularity_minutes != null ? <div><strong>±{Math.round(summary.data.sleep.timing_regularity_minutes)}</strong><span>minutes around your usual timing</span></div> : null}</div><SleepTrend sessions={orderedSleep} /></FitnessCard> : null}
    <ReadinessLog onDataChanged={onDataChanged} />
    {!loading && !error && orderedSleep.length ? <FitnessCard title="Latest sleep" detail="Your most recent nights at a glance."><ul className="fitness-module__list">{orderedSleep.slice(0, 4).map((session) => <li key={session.id}><div><strong>{formatDuration(session.duration_s)}</strong><small>{formatFitnessDate(session.sleep_start_utc)} · {formatFitnessDateTime(session.sleep_start_utc)} to {new Intl.DateTimeFormat(undefined, { hour: "2-digit", minute: "2-digit" }).format(new Date(session.sleep_end_utc))}</small></div></li>)}</ul></FitnessCard> : null}
    <details className="fitness-module__maintenance fitness-wave4__recovery-manage" open={manageOpen} onToggle={(event) => setManageOpen(event.currentTarget.open)}><summary><SlidersHorizontal aria-hidden="true" size={17} /> Manage Recovery</summary>{manageOpen ? <div className="fitness-module__maintenance-body"><div className="fitness-wave4__manage-nav" role="group" aria-label="Manage Recovery"><button type="button" className={cn(managePanel === "signals" && "is-active")} onClick={() => changeManagePanel("signals")}><HeartPulse aria-hidden="true" size={17} /> Signals &amp; connections</button><button type="button" className={cn(managePanel === "issues" && "is-active")} onClick={() => changeManagePanel("issues")}><TriangleAlert aria-hidden="true" size={17} /> Body issues</button><button type="button" className={cn(managePanel === "cycles" && "is-active")} onClick={() => changeManagePanel("cycles")}><MoonStar aria-hidden="true" size={17} /> Cycle tracking</button></div>{managePanel === "signals" ? <RecoverySignalsManager revision={revision} online={online} summary={summary.data} sleep={sleep.data} onDataChanged={onDataChanged} /> : null}{managePanel === "issues" ? <BodyIssuesManager revision={revision} onDataChanged={onDataChanged} /> : null}{managePanel === "cycles" ? <FitnessCycleTracking online={online} revision={revision} onDataChanged={onDataChanged} forceVisible /> : null}</div> : null}</details>
  </section>;
}
