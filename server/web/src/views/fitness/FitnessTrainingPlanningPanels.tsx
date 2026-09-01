import { AlertTriangle, CheckCircle2, Download, ExternalLink, Eye, EyeOff, FileOutput, Layers3, Link2, LoaderCircle, RefreshCw, Send, Unlink, WifiOff } from "lucide-react";
import { useEffect, useMemo, useState } from "react";

import { api } from "../../api";
import {
  cancelIntervalsWorkout,
  connectIntervalsWithApiKey,
  disconnectIntervals,
  loadIntervalsConnection,
  loadIntervalsWorkoutDelivery,
  sendIntervalsWorkout,
  startIntervalsOAuth,
  syncIntervalsActivities,
  testIntervalsConnection,
  updateIntervalsActivityImport,
} from "../../fitness/intervalsDelivery";
import type {
  FitnessGarminExport,
  FitnessGoal,
  FitnessIntervalsConnectionStatus,
  FitnessIntervalsWorkoutDelivery,
  FitnessPhase,
  FitnessPlanAdherence,
  FitnessPlannedSession,
  FitnessTrainingProgramme,
  FitnessWorkoutDefinition,
} from "../../fitness/contract";
import {
  FitnessCard,
  FitnessFormStatus,
  FitnessStat,
  errorMessage,
  formatFitnessDate,
  formatFitnessDateTime,
  useFitnessSave,
} from "./shared";

export function FitnessProgrammeEditor({
  goals,
  phases,
  programmes,
  onDataChanged,
  onClose,
}: {
  goals: FitnessGoal[];
  phases: FitnessPhase[];
  programmes: FitnessTrainingProgramme[];
  onDataChanged: () => void;
  onClose: () => void;
}) {
  const save = useFitnessSave(onDataChanged);
  const [name, setName] = useState("");
  const [purpose, setPurpose] = useState("");
  const [startsOn, setStartsOn] = useState(new Date().toISOString().slice(0, 10));
  const [endsOn, setEndsOn] = useState("");
  const [phaseId, setPhaseId] = useState("");
  const [primaryGoalId, setPrimaryGoalId] = useState("");
  const [secondaryGoalIds, setSecondaryGoalIds] = useState<string[]>([]);

  async function create() {
    await save.save("training_programme", {
      name: name.trim(),
      purpose: purpose.trim() || null,
      starts_on: startsOn,
      ends_on: endsOn || null,
      status: "active",
      phase_id: phaseId || null,
      programme_source: "user",
      goal_links: [
        ...(primaryGoalId ? [{ goal_id: primaryGoalId, role: "primary" }] : []),
        ...secondaryGoalIds.filter((id) => id !== primaryGoalId).map((goalId) => ({ goal_id: goalId, role: "secondary" })),
      ],
    });
    onClose();
  }

  return <FitnessCard title="Create a training programme" detail="A programme groups weeks of accepted sessions without changing the workout versions you already agreed.">
    <form className="fitness-module__form" onSubmit={(event) => { event.preventDefault(); void create(); }}>
      <div className="fitness-module__fields">
        <label className="fitness-module__field is-wide">Programme name<input autoFocus required value={name} onChange={(event) => setName(event.target.value)} placeholder="Autumn 10K and strength block" /></label>
        <label className="fitness-module__field is-wide">Purpose<textarea value={purpose} onChange={(event) => setPurpose(event.target.value)} /></label>
        <label className="fitness-module__field">Starts<input type="date" required value={startsOn} onChange={(event) => setStartsOn(event.target.value)} /></label>
        <label className="fitness-module__field">Ends<input type="date" min={startsOn} value={endsOn} onChange={(event) => setEndsOn(event.target.value)} /></label>
        <label className="fitness-module__field">Training phase<select value={phaseId} onChange={(event) => setPhaseId(event.target.value)}><option value="">No phase</option>{phases.map((phase) => <option value={phase.id} key={phase.id}>{phase.name}</option>)}</select></label>
        <label className="fitness-module__field">Primary goal<select value={primaryGoalId} onChange={(event) => setPrimaryGoalId(event.target.value)}><option value="">No primary goal</option>{goals.filter((goal) => goal.status === "active").map((goal) => <option value={goal.id} key={goal.id}>{goal.name}</option>)}</select></label>
        <fieldset className="fitness-module__field is-wide"><legend>Supporting goals</legend>{goals.filter((goal) => goal.status === "active").map((goal) => <label className="fitness-module__check" key={goal.id}><input type="checkbox" disabled={goal.id === primaryGoalId} checked={secondaryGoalIds.includes(goal.id)} onChange={(event) => setSecondaryGoalIds((current) => event.target.checked ? [...current, goal.id] : current.filter((id) => id !== goal.id))} /> {goal.name}</label>)}</fieldset>
      </div>
      <div className="fitness-module__form-footer"><button type="submit" className="button button--primary" disabled={save.saving || !name.trim()}>Create programme</button><button type="button" className="button button--secondary" onClick={onClose}>Cancel</button><FitnessFormStatus saving={save.saving} saved={save.saved} error={save.saveError} /></div>
    </form>
    {programmes.length ? <p className="fitness-module__privacy-note"><Layers3 aria-hidden="true" size={16} /> {programmes.length} programme{programmes.length === 1 ? "" : "s"} already saved; this creates a separate block.</p> : null}
  </FitnessCard>;
}

function latestVersion(definition: FitnessWorkoutDefinition) {
  return definition.current_version ?? definition.version ?? definition.versions?.at(-1) ?? null;
}

function deliverableRunningSession(session: FitnessPlannedSession): boolean {
  return session.sport_key === "running"
    && ["accepted", "scheduled"].includes(session.status)
    && Boolean(session.workout_version_id)
    && Boolean(session.scheduled_start_utc || session.scheduled_date || session.time_window_start_utc);
}

function deliveryLabel(delivery: FitnessIntervalsWorkoutDelivery | null): string {
  if (!delivery || delivery.state === "not_sent") return "Not sent";
  if (delivery.state === "pending") return "Updating Intervals.icu…";
  if (delivery.state === "sent") return "Sent to Intervals.icu";
  if (delivery.state === "cancelled") return "Not on Intervals.icu";
  if (delivery.state === "error") return "Send needs attention";
  return delivery.state.replaceAll("_", " ");
}

function deliveryPillClass(delivery: FitnessIntervalsWorkoutDelivery | null): string {
  if (delivery?.state === "sent") return "is-success";
  if (delivery?.state === "error") return "is-warning";
  return "is-neutral";
}

export function FitnessIntervalsGarminPanel({
  definitions,
  sessions,
  online,
}: {
  definitions: FitnessWorkoutDefinition[];
  sessions: FitnessPlannedSession[];
  online: boolean;
}) {
  const eligibleSessions = useMemo(() => sessions.filter(deliverableRunningSession).sort((left, right) => (
    left.scheduled_start_utc ?? left.scheduled_date ?? left.time_window_start_utc ?? ""
  ).localeCompare(right.scheduled_start_utc ?? right.scheduled_date ?? right.time_window_start_utc ?? "")), [sessions]);
  const eligibleSessionKey = eligibleSessions.map((session) => [
    session.id,
    session.revision,
    session.status,
    session.workout_version_id,
    session.scheduled_start_utc,
    session.scheduled_date,
    session.time_window_start_utc,
  ].join(":")).join("|");
  const [connection, setConnection] = useState<FitnessIntervalsConnectionStatus | null>(null);
  const [deliveries, setDeliveries] = useState<Record<string, FitnessIntervalsWorkoutDelivery>>({});
  const [deliveryErrors, setDeliveryErrors] = useState<Record<string, string>>({});
  const [loading, setLoading] = useState(online);
  const [busy, setBusy] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [notice, setNotice] = useState<string | null>(null);
  const [apiKey, setApiKey] = useState("");
  const [showApiKey, setShowApiKey] = useState(false);
  const [confirmingDisconnect, setConfirmingDisconnect] = useState(false);
  const [confirmingRemoval, setConfirmingRemoval] = useState<string | null>(null);
  const [callbackResult] = useState(() => new URL(window.location.href).searchParams.get("intervals"));

  async function loadDeliveries() {
    const results = await Promise.all(eligibleSessions.map(async (session) => {
      try {
        return { sessionId: session.id, delivery: await loadIntervalsWorkoutDelivery(session.id), error: null };
      } catch (requestError) {
        return { sessionId: session.id, delivery: null, error: errorMessage(requestError) };
      }
    }));
    setDeliveries(Object.fromEntries(results.flatMap((result) => result.delivery ? [[result.sessionId, result.delivery]] : [])));
    setDeliveryErrors(Object.fromEntries(results.flatMap((result) => result.error ? [[result.sessionId, result.error]] : [])));
  }

  async function load() {
    if (!online) { setLoading(false); return; }
    setLoading(true);
    setError(null);
    try {
      const next = await loadIntervalsConnection();
      setConnection(next);
      if (next.connected) await loadDeliveries();
      else { setDeliveries({}); setDeliveryErrors({}); }
    } catch (requestError) {
      setError(errorMessage(requestError));
    } finally {
      setLoading(false);
    }
  }

  useEffect(() => { void load(); }, [online, eligibleSessionKey]);

  useEffect(() => {
    if (!callbackResult) return;
    const url = new URL(window.location.href);
    url.searchParams.delete("intervals");
    window.history.replaceState(window.history.state, "", url);
  }, [callbackResult]);

  async function connectWithKey() {
    if (!apiKey.trim()) return;
    setBusy("connect"); setError(null); setNotice(null);
    try {
      const next = await connectIntervalsWithApiKey(apiKey.trim());
      setConnection(next); setApiKey(""); setShowApiKey(false);
      if (next.connected) await loadDeliveries();
      setNotice("Intervals.icu connected.");
    } catch (requestError) {
      setError(errorMessage(requestError));
    } finally { setBusy(null); }
  }

  async function connectWithOAuth() {
    setBusy("oauth"); setError(null); setNotice(null);
    try {
      const response = await startIntervalsOAuth();
      window.location.assign(response.authorization_url);
    } catch (requestError) {
      setError(errorMessage(requestError)); setBusy(null);
    }
  }

  async function testConnection() {
    setBusy("test"); setError(null); setNotice(null);
    try {
      const next = await testIntervalsConnection();
      setConnection(next);
      setNotice(next.connected ? "Intervals.icu connection checked." : "Intervals.icu needs to be reconnected.");
    } catch (requestError) {
      setError(errorMessage(requestError));
    } finally { setBusy(null); }
  }

  async function setActivityImport(enabled: boolean) {
    setBusy("activity-import"); setError(null); setNotice(null);
    try {
      const next = await updateIntervalsActivityImport(enabled);
      setConnection(next);
      if (enabled) {
        const result = await syncIntervalsActivities();
        setConnection(result.status);
        setNotice(result.queued_count
          ? `${result.queued_count} Garmin ${result.queued_count === 1 ? "activity is" : "activities are"} being imported.`
          : "Garmin activities are up to date.");
      } else {
        setNotice("Garmin activity import is off.");
      }
    } catch (requestError) {
      setError(errorMessage(requestError));
    } finally { setBusy(null); }
  }

  async function importActivitiesNow() {
    setBusy("activity-sync"); setError(null); setNotice(null);
    try {
      const result = await syncIntervalsActivities();
      setConnection(result.status);
      setNotice(result.queued_count
        ? `${result.queued_count} Garmin ${result.queued_count === 1 ? "activity is" : "activities are"} being imported.`
        : "Garmin activities are up to date.");
    } catch (requestError) {
      setError(errorMessage(requestError));
    } finally { setBusy(null); }
  }

  async function disconnect() {
    setBusy("disconnect"); setError(null); setNotice(null);
    try {
      await disconnectIntervals();
      setConnection((current) => current ? { ...current, connected: false, status: "disconnected", auth_method: null, athlete_id: null, athlete_name: null, garmin_training_connected: null, activity_read_authorized: false, activity_import_enabled: false } : current);
      setDeliveries({}); setDeliveryErrors({}); setConfirmingDisconnect(false);
      setNotice("Intervals.icu disconnected. Previously sent workouts stay on Intervals.icu.");
    } catch (requestError) {
      setError(errorMessage(requestError));
    } finally { setBusy(null); }
  }

  async function refreshDelivery(sessionId: string) {
    setBusy(`status:${sessionId}`);
    setDeliveryErrors((current) => { const next = { ...current }; delete next[sessionId]; return next; });
    try {
      const result = await loadIntervalsWorkoutDelivery(sessionId);
      setDeliveries((current) => ({ ...current, [sessionId]: result }));
    } catch (requestError) {
      setDeliveryErrors((current) => ({ ...current, [sessionId]: errorMessage(requestError) }));
    } finally { setBusy(null); }
  }

  async function sendWorkout(sessionId: string) {
    setBusy(`send:${sessionId}`); setNotice(null);
    setDeliveryErrors((current) => { const next = { ...current }; delete next[sessionId]; return next; });
    try {
      const result = await sendIntervalsWorkout(sessionId);
      setDeliveries((current) => ({ ...current, [sessionId]: result }));
      setNotice(result.state === "sent" ? "Sent to Intervals.icu." : result.state === "pending" ? "Workout update queued for Intervals.icu." : null);
    } catch (requestError) {
      setDeliveryErrors((current) => ({ ...current, [sessionId]: errorMessage(requestError) }));
    } finally { setBusy(null); }
  }

  async function removeWorkout(sessionId: string) {
    setBusy(`remove:${sessionId}`); setNotice(null);
    try {
      const result = await cancelIntervalsWorkout(sessionId);
      setDeliveries((current) => ({ ...current, [sessionId]: result }));
      setConfirmingRemoval(null);
      setNotice("Removed from Intervals.icu. The accepted HausKlar plan is unchanged.");
    } catch (requestError) {
      setDeliveryErrors((current) => ({ ...current, [sessionId]: errorMessage(requestError) }));
    } finally { setBusy(null); }
  }

  const apiKeyForm = <form className="fitness-module__form" onSubmit={(event) => { event.preventDefault(); void connectWithKey(); }}>
    <div className="fitness-module__field is-wide"><label htmlFor="intervals-api-key">Personal API key</label>
      <div className="password-field"><input id="intervals-api-key" type={showApiKey ? "text" : "password"} autoComplete="off" spellCheck={false} required value={apiKey} aria-describedby="intervals-api-key-help" onChange={(event) => setApiKey(event.target.value)} /><button type="button" className="password-toggle" aria-label={showApiKey ? "Hide API key" : "Show API key"} onClick={() => setShowApiKey((current) => !current)}>{showApiKey ? <EyeOff aria-hidden="true" size={18} /> : <Eye aria-hidden="true" size={18} />}</button></div>
      <small id="intervals-api-key-help">Copy this from Intervals.icu. HausKlar saves it on your server, not in this browser.</small>
    </div>
    <button type="submit" className="button button--primary" disabled={!online || busy != null || !apiKey.trim()} aria-busy={busy === "connect"}>{busy === "connect" ? <LoaderCircle className="is-spinning" aria-hidden="true" size={17} /> : <Link2 aria-hidden="true" size={17} />} {busy === "connect" ? "Connecting…" : "Connect Intervals.icu"}</button>
  </form>;

  return <>
    <FitnessCard title="Garmin" detail="Send planned workouts and import completed activities through Intervals.icu." className="is-wide">
      <p className="fitness-module__muted">Connect once, then choose whether completed Garmin activities should come back into HausKlar.</p>
      {callbackResult === "connected" ? <div className="fitness-module__notice fitness-module__notice--success" role="status">Intervals.icu returned successfully. Checking the connection…</div> : callbackResult === "cancelled" ? <div className="fitness-module__notice" role="status">Intervals.icu connection cancelled.</div> : callbackResult === "failed" ? <div className="fitness-module__notice fitness-module__notice--error" role="alert">Intervals.icu could not be connected. Try again when ready.</div> : null}
      {!online ? <div className="fitness-module__notice" role="status"><WifiOff aria-hidden="true" size={17} /><span>Reconnect to manage Garmin.</span></div> : null}
      {loading ? <div className="fitness-module__visual-loading"><LoaderCircle className="is-spinning" aria-hidden="true" size={20} /> Checking Intervals.icu…</div> : null}
      {error ? <div className="fitness-module__notice fitness-module__notice--error" role="alert"><span>{error}</span><button type="button" className="button button--secondary" disabled={!online || loading} onClick={() => void load()}>Try again</button></div> : null}
      {notice ? <div className="fitness-module__notice fitness-module__notice--success" role="status"><CheckCircle2 aria-hidden="true" size={17} /><span>{notice}</span></div> : null}
      {!loading && connection?.connected ? <>
        <ul className="fitness-module__list" aria-label="Garmin delivery connection status">
          <li><div><strong>Intervals.icu</strong><small>{connection.athlete_name ? `Connected as ${connection.athlete_name}` : "Connected"}{connection.last_tested_at ? ` · checked ${formatFitnessDateTime(connection.last_tested_at)}` : ""}</small></div><span className="fitness-module__pill is-success">Connected</span></li>
          <li><div><strong>Garmin training</strong><small>{connection.garmin_training_connected ? "Garmin is linked and planned-workout upload is enabled in Intervals.icu." : connection.garmin_training_connected === false ? "Link Garmin and enable planned-workout upload in Intervals.icu before expecting watch sync." : "Intervals.icu has not confirmed Garmin workout-upload readiness yet."}</small></div><span className={`fitness-module__pill ${connection.garmin_training_connected ? "is-success" : "is-warning"}`}>{connection.garmin_training_connected ? "Ready" : "Not ready"}</span></li>
        </ul>
        <div className="fitness-module__callout">
          <strong>Import Garmin activities</strong>
          <p>Bring completed activities, routes, laps, heart rate and running metrics into Fitness.</p>
          <label className="fitness-module__check"><input type="checkbox" checked={connection.activity_import_enabled} disabled={!online || busy != null || !connection.activity_read_authorized} onChange={(event) => void setActivityImport(event.target.checked)} /> Import automatically</label>
          {!connection.activity_read_authorized && connection.oauth_available ? <button type="button" className="button button--secondary" disabled={!online || busy != null} onClick={() => void connectWithOAuth()}><Link2 aria-hidden="true" size={16} /> Reconnect to enable imports</button> : null}
          {connection.activity_import_enabled ? <div className="fitness-module__button-row"><button type="button" className="button button--secondary" disabled={!online || busy != null} onClick={() => void importActivitiesNow()}><RefreshCw className={busy === "activity-sync" ? "is-spinning" : undefined} aria-hidden="true" size={16} /> {busy === "activity-sync" ? "Importing…" : "Import now"}</button><small>{connection.activity_imported_count} imported{connection.activity_import_pending_count ? ` · ${connection.activity_import_pending_count} processing` : ""}{connection.last_activity_import_at ? ` · checked ${formatFitnessDateTime(connection.last_activity_import_at)}` : ""}</small></div> : null}
          {connection.activity_import_enabled && connection.last_activity_import_error_code ? <small>Last import needs another try.</small> : null}
          {connection.activity_import_enabled ? <small>Activity data may include data from Garmin devices.</small> : null}
        </div>
        {connection.last_error_code ? <div className="fitness-module__notice fitness-module__notice--error" role="alert">Intervals.icu reported {connection.last_error_code.replaceAll("_", " ")}.</div> : null}
        <div className="fitness-module__button-row"><a className="button button--secondary" href="https://intervals.icu/settings" target="_blank" rel="noreferrer">Intervals.icu settings <ExternalLink aria-hidden="true" size={15} /></a><button type="button" className="button button--secondary" disabled={!online || busy != null} onClick={() => void testConnection()}><RefreshCw aria-hidden="true" size={16} /> {busy === "test" ? "Checking…" : "Check connection"}</button><button type="button" className="button button--secondary" disabled={!online || busy != null} onClick={() => setConfirmingDisconnect(true)}><Unlink aria-hidden="true" size={16} /> Disconnect</button></div>
        {confirmingDisconnect ? <div className="fitness-module__notice fitness-module__notice--error" role="alert"><span><strong>Disconnect Intervals.icu?</strong> Previously sent workouts stay on Intervals.icu.</span><div className="fitness-module__button-row"><button type="button" className="button button--danger" disabled={busy != null} onClick={() => void disconnect()}>{busy === "disconnect" ? "Disconnecting…" : "Disconnect"}</button><button type="button" className="button button--secondary" disabled={busy != null} onClick={() => setConfirmingDisconnect(false)}>Cancel</button></div></div> : null}
        <div aria-live="polite">
          <h4>Scheduled running workouts</h4>
          {eligibleSessions.length ? <ul className="fitness-module__list">{eligibleSessions.map((session) => {
            const delivery = deliveries[session.id] ?? null;
            const rowError = deliveryErrors[session.id];
            const canSend = !delivery || ["not_sent", "cancelled", "error"].includes(delivery.state);
            const sending = busy === `send:${session.id}`;
            const removable = delivery && ["sent", "pending"].includes(delivery.state);
            const removing = busy === `remove:${session.id}`;
            return <li key={session.id}><div><strong>{session.title}</strong><small>{formatFitnessDateTime(session.scheduled_start_utc ?? session.time_window_start_utc ?? session.scheduled_date)} · {deliveryLabel(delivery)}{delivery?.sent_at ? ` · ${formatFitnessDateTime(delivery.sent_at)}` : ""}</small>{delivery?.state === "pending" ? <small>HausKlar retries this automatic update in the background.</small> : null}{delivery?.push_errors.length ? <div className="fitness-module__notice fitness-module__notice--error" role="alert"><AlertTriangle aria-hidden="true" size={16} /><span><strong>Workout delivery warning</strong><ul>{delivery.push_errors.map((item) => <li key={item}>{item}</li>)}</ul></span></div> : null}{delivery?.state === "error" && delivery.last_error_code ? <small>Intervals.icu error: {delivery.last_error_code.replaceAll("_", " ")}.</small> : null}{rowError ? <div className="fitness-module__notice fitness-module__notice--error" role="alert"><span>{rowError}</span><button type="button" className="button button--secondary" disabled={!online || busy != null} onClick={() => void refreshDelivery(session.id)}>Check again</button></div> : null}{confirmingRemoval === session.id ? <div className="fitness-module__notice fitness-module__notice--error" role="alert"><span><strong>Remove this workout from Intervals.icu?</strong> The accepted HausKlar plan stays unchanged.</span><div className="fitness-module__button-row"><button type="button" className="button button--danger" disabled={busy != null} onClick={() => void removeWorkout(session.id)}>{removing ? "Removing…" : "Remove"}</button><button type="button" className="button button--secondary" disabled={busy != null} onClick={() => setConfirmingRemoval(null)}>Keep workout</button></div></div> : null}</div><div className="fitness-module__button-row"><span className={`fitness-module__pill ${deliveryPillClass(delivery)}`}>{deliveryLabel(delivery)}</span>{canSend && !rowError ? <button type="button" className="button button--primary" disabled={!online || busy != null} aria-busy={sending} onClick={() => void sendWorkout(session.id)}><Send aria-hidden="true" size={16} /> {sending ? "Sending…" : delivery?.state === "error" ? "Retry" : "Send to Garmin"}</button> : null}{removable ? <button type="button" className="button button--secondary" disabled={!online || busy != null} onClick={() => setConfirmingRemoval(session.id)}>Remove from Intervals.icu</button> : null}</div></li>;
          })}</ul> : <div className="fitness-module__empty"><strong>No accepted run is scheduled</strong><span>Accept and schedule a structured running workout before sending it.</span></div>}
        </div>
      </> : null}
      {!loading && connection && !connection.connected && online ? <>
        {connection.status === "reauth_required" || connection.status === "provider_down" ? <div className="fitness-module__notice fitness-module__notice--error" role="alert">{connection.status === "reauth_required" ? "Intervals.icu needs to be reconnected." : "Intervals.icu is temporarily unavailable."}</div> : null}
        {connection.configured && connection.oauth_available ? <div className="fitness-module__button-row"><button type="button" className="button button--primary" disabled={busy != null} onClick={() => void connectWithOAuth()}><Link2 aria-hidden="true" size={17} /> {busy === "oauth" ? "Opening Intervals.icu…" : "Connect with Intervals.icu"}</button></div> : null}
        {connection.personal_api_key_available ? connection.oauth_available ? <details className="fitness-module__details"><summary>Use a personal API key instead</summary>{apiKeyForm}</details> : apiKeyForm : null}
        {!connection.configured && !connection.personal_api_key_available ? <div className="fitness-module__empty"><strong>Intervals.icu connection is not configured</strong><span>HausKlar’s server setup must be completed before workouts can be sent.</span></div> : null}
      </> : null}
    </FitnessCard>
    <details className="fitness-module__maintenance"><summary>Advanced fallback: download a Garmin FIT file</summary><div className="fitness-module__maintenance-body"><p className="fitness-module__muted">Use the file route only when Intervals.icu delivery is unavailable. It is not required for the normal Garmin flow.</p><FitnessGarminExportPanel definitions={definitions} online={online} /></div></details>
  </>;
}

export function FitnessGarminExportPanel({
  definitions,
  online,
}: {
  definitions: FitnessWorkoutDefinition[];
  online: boolean;
}) {
  const acceptedDefinitions = useMemo(() => definitions.filter((definition) => definition.sport_key === "running" && latestVersion(definition)?.accepted_at), [definitions]);
  const [definitionId, setDefinitionId] = useState(acceptedDefinitions[0]?.id ?? "");
  const [exportRecord, setExportRecord] = useState<FitnessGarminExport | null>(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const definition = acceptedDefinitions.find((item) => item.id === definitionId) ?? acceptedDefinitions[0];
  const version = definition ? latestVersion(definition) : null;

  useEffect(() => {
    if (!definitionId && acceptedDefinitions[0]) setDefinitionId(acceptedDefinitions[0].id);
  }, [acceptedDefinitions, definitionId]);

  async function generate() {
    if (!version?.id) return;
    setBusy(true);
    setError(null);
    try {
      const result = await api<FitnessGarminExport>(`/fitness/workout-versions/${encodeURIComponent(version.id)}/garmin-exports`, { method: "POST" }, true, false);
      setExportRecord(result);
    } catch (requestError) {
      setError(errorMessage(requestError));
    } finally {
      setBusy(false);
    }
  }

  async function refresh() {
    if (!exportRecord) return;
    setBusy(true);
    setError(null);
    try {
      setExportRecord(await api<FitnessGarminExport>(`/fitness/garmin-exports/${encodeURIComponent(exportRecord.id)}`, {}, true, false));
    } catch (requestError) {
      setError(errorMessage(requestError));
    } finally {
      setBusy(false);
    }
  }

  return <FitnessCard title="Garmin FIT export" detail="Export the exact accepted version. A failed export never changes or loses the plan.">
    {acceptedDefinitions.length ? <div className="fitness-module__fields"><label className="fitness-module__field is-wide">Accepted running workout<select value={definition?.id ?? ""} onChange={(event) => { setDefinitionId(event.target.value); setExportRecord(null); }}><option value="">Choose a workout</option>{acceptedDefinitions.map((item) => <option value={item.id} key={item.id}>{item.name}</option>)}</select></label></div> : <div className="fitness-module__empty"><strong>No accepted run version</strong><span>Accept and schedule a structured run before exporting.</span></div>}
    {version ? <div className="fitness-module__callout"><strong>{version.title}</strong><p>{version.estimated_distance_m ? `${(version.estimated_distance_m / 1000).toFixed(2)} km` : "Open distance"} · {version.estimated_duration_s ? `${Math.round(version.estimated_duration_s / 60)} min` : "Open duration"}</p></div> : null}
    {error ? <div className="fitness-module__notice fitness-module__notice--error" role="alert">{error}</div> : null}
    {version && !exportRecord ? <button type="button" className="button button--primary" disabled={!online || busy} onClick={() => void generate()}><FileOutput aria-hidden="true" size={17} /> {busy ? "Generating…" : "Generate Garmin FIT"}</button> : null}
    {exportRecord ? <div className="fitness-module__garmin-export">
      <div className="fitness-module__callout"><strong>{exportRecord.status === "ready" ? "FIT file ready" : exportRecord.status === "error" ? "Export needs attention" : "Generating FIT file"}</strong><p>{exportRecord.last_error ?? "The accepted plan remains unchanged."}</p></div>
      {exportRecord.mapping_report?.length ? <div className="fitness-module__table-wrap"><table className="fitness-module__table"><thead><tr><th>Field</th><th>Mapping</th><th>Detail</th></tr></thead><tbody>{exportRecord.mapping_report.map((item) => <tr key={`${item.field}-${item.status}`}><td>{item.field}</td><td>{item.status}</td><td>{item.detail}</td></tr>)}</tbody></table></div> : null}
      <div className="fitness-module__button-row">{exportRecord.status === "ready" ? <a className="button button--primary" href={`/api/fitness/garmin-exports/${encodeURIComponent(exportRecord.id)}/download`} download={exportRecord.file_name ?? true}><Download aria-hidden="true" size={17} /> Download FIT</a> : <button type="button" className="button button--secondary" disabled={!online || busy} onClick={() => void refresh()}><RefreshCw aria-hidden="true" size={16} /> Refresh</button>}{exportRecord.status === "error" ? <button type="button" className="button button--secondary" disabled={!online || busy} onClick={() => void generate()}>Retry export</button> : null}</div>
    </div> : null}
    <p className="fitness-module__privacy-note"><CheckCircle2 aria-hidden="true" size={16} /> Targets, durations, order, and repeats are mapped. Custom cue text stays in HausKlar when standard FIT cannot carry it; watch and audio behaviour still needs checking on the Forerunner 970.</p>
  </FitnessCard>;
}

export function FitnessPlanAdherencePanel({ sessions }: { sessions: FitnessPlannedSession[] }) {
  const candidates = sessions.filter((session) => session.completion_activity_id || ["completed", "partially_completed"].includes(session.status));
  const [sessionId, setSessionId] = useState(candidates[0]?.id ?? "");
  const [adherence, setAdherence] = useState<FitnessPlanAdherence | null>(null);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);

  async function load() {
    if (!sessionId) return;
    setLoading(true);
    setError(null);
    try {
      setAdherence(await api<FitnessPlanAdherence>(`/fitness/planned-sessions/${encodeURIComponent(sessionId)}/adherence`, {}, true, false));
    } catch (requestError) {
      setError(errorMessage(requestError));
    } finally {
      setLoading(false);
    }
  }

  return <FitnessCard title="Plan adherence" detail="Execution is shown step by step and never reduced to a moral score.">
    {candidates.length ? <div className="fitness-module__fields"><label className="fitness-module__field is-wide">Completed planned session<select value={sessionId} onChange={(event) => { setSessionId(event.target.value); setAdherence(null); }}>{candidates.map((session) => <option value={session.id} key={session.id}>{session.title} · {formatFitnessDate(session.scheduled_date ?? session.scheduled_start_utc)}</option>)}</select></label><button type="button" className="button button--secondary" disabled={loading} onClick={() => void load()}>{loading ? "Loading…" : "Inspect execution"}</button></div> : <div className="fitness-module__empty"><strong>No linked completion yet</strong><span>When an activity is linked, adherence appears here without changing the accepted plan.</span></div>}
    {error ? <div className="fitness-module__notice fitness-module__notice--error" role="alert">{error}</div> : null}
    {adherence ? <><div className="fitness-module__stats"><FitnessStat label="Distance" value={adherence.completed_distance_m != null ? `${((adherence.completed_distance_m ?? 0) / 1000).toFixed(2)} / ${((adherence.planned_distance_m ?? 0) / 1000).toFixed(2)} km` : "—"} /><FitnessStat label="Duration" value={adherence.completed_duration_s != null ? `${Math.round(adherence.completed_duration_s / 60)} / ${Math.round((adherence.planned_duration_s ?? 0) / 60)} min` : "—"} /><FitnessStat label="Time in target" value={adherence.target_time_s ? `${Math.round((adherence.time_in_target_s ?? 0) / adherence.target_time_s * 100)}%` : "—"} /></div>{adherence.steps?.length ? <ul className="fitness-module__list">{adherence.steps.map((step) => <li key={step.id}><div><strong>{step.label}</strong><small>{step.actual} · planned {step.planned}</small></div><span className="fitness-module__pill is-neutral">{step.state}</span></li>)}</ul> : null}{adherence.explanation ? <p>{adherence.explanation}</p> : null}</> : null}
  </FitnessCard>;
}
