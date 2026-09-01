import {
  Bell, BrainCircuit, CalendarSync, CheckCircle2, ChevronRight, Copy, KeyRound,
  Download, Dumbbell, History, LogOut, PlugZap, RefreshCw, ShieldCheck, SlidersHorizontal, Trash2, UserRound, UsersRound, Utensils, WalletCards,
} from "lucide-react";
import { useEffect, useState, type FormEvent } from "react";

import { api } from "../api";
import { useAIConsent } from "../components/AIConsent";
import { QRCode } from "../components/QRCode";
import { ConfirmDialog } from "../components/ui";
import { purgeCurrentFitnessOwnerData } from "../fitness/offlineStore";
import type { FitnessWorkspacePreference } from "../fitness/contract";
import {
  announceFitnessQuickEntryPreferences,
  cachedFitnessQuickEntryPreferences,
  DEFAULT_FITNESS_QUICK_ENTRY_PREFERENCES,
  rememberFitnessQuickEntryPreferences,
  type FitnessQuickEntryPreferences,
  validFitnessQuickEntryPreferences,
} from "../fitness/quickEntry";
import { currentBrowserHasPushSubscription, revokeCurrentBrowserPushSubscription } from "../pushSubscriptions";
import { setUsageMonitoringConsent } from "../usageMonitor";
import type { CalendarFeedStatus, CalendarSource, SchoolRugbySettings, SchoolRugbyTeamList, FamilyInvite, FamilyMember, PushStatus, ReminderPreferences, ReminderPreviewItem, User } from "../types";
import "./account-settings.css";

type SettingsCategory = "account" | "notifications" | "workspaces" | "family" | "connections" | "privacy" | "advanced";
type HASettings = { dashboard_url: string | null; ha_url: string | null; token_configured: boolean; configured: boolean };
type HATest = { success: boolean; message: string };

const defaultReminders: ReminderPreferences = {
  event_reminders_enabled: true, event_minutes_before: 30, task_reminders_enabled: true,
  morning_summary_enabled: true, morning_summary_time: "07:00",
  evening_summary_enabled: true, evening_summary_time: "19:00", quiet_start: "21:00",
  quiet_end: "07:00", privacy_mode: true,
};

const categoryCopy: Array<{ id: SettingsCategory; title: string; description: string; icon: typeof UserRound }> = [
  { id: "account", title: "Account", description: "Profile, role and what your family can see", icon: UserRound },
  { id: "notifications", title: "Notifications", description: "Useful reminders and permission status", icon: Bell },
  { id: "workspaces", title: "Personal workspaces", description: "Money and optional Fitness", icon: WalletCards },
  { id: "family", title: "Family administration", description: "People and invitations", icon: UsersRound },
  { id: "connections", title: "Connections", description: "Calendars and home systems", icon: PlugZap },
  { id: "privacy", title: "Privacy & AI", description: "Explicit data-processing choices", icon: BrainCircuit },
  { id: "advanced", title: "Advanced", description: "Password, session and account controls", icon: SlidersHorizontal },
];

function applicationServerKey(value: string): Uint8Array<ArrayBuffer> {
  const padding = "=".repeat((4 - value.length % 4) % 4);
  const bytes = atob((value + padding).replace(/-/g, "+").replace(/_/g, "/"));
  return Uint8Array.from(bytes, (character) => character.charCodeAt(0));
}

function notificationSettingsTarget(): { url: string | null; instructions: string } {
  const agent = navigator.userAgent;
  if (/Firefox/i.test(agent)) return { url: "about:preferences#privacy", instructions: "Firefox Settings → Privacy & Security → Permissions → Notifications." };
  if (/Edg|Chrome|Chromium/i.test(agent)) return { url: "chrome://settings/content/notifications", instructions: "Browser Settings → Privacy and security → Site settings → Notifications → allow this HausKlar site." };
  if (/Macintosh|iPhone|iPad/i.test(agent)) return { url: "x-apple.systempreferences:com.apple.Notifications-Settings.extension", instructions: "System Settings → Notifications → your browser (or HausKlar) → Allow Notifications." };
  return { url: null, instructions: "Open your browser’s site permissions, choose Notifications, then allow this HausKlar site." };
}

type UsageModuleSummary = { module: string; actions: number; active_days: number };
type UsageScreenSummary = { module: string; surface: string; views: number; active_days: number };
type UsageControlSummary = { module: string; action: string; surface: string; presses: number; active_days: number };
type UsageWorkflowSummary = {
  module: string; workflow: string; action: string; starts: number; completions: number;
  failures: number; abandonments: number; queued_completions: number;
  average_interactions: number | null;
};
type UsageHistorySummary = {
  enabled: boolean;
  period_days: number;
  meaningful_actions: number;
  failed_actions: number;
  active_days: number;
  use_signal: "not_started" | "started" | "returning";
  repeat_modules: UsageModuleSummary[];
  both_adults_contributed: boolean;
  shared_family_actions: number;
  screen_views: UsageScreenSummary[];
  control_uses: UsageControlSummary[];
  workflows: UsageWorkflowSummary[];
  last_action_at: string | null;
};
type UsageHistoryExport = {
  generated_at: string;
  retention_days: number;
  events: Array<{
    module: string; action: string; outcome: string; entry_source: string;
    effort: string; app_version: string; recorded_at: string;
  }>;
};

const usageModuleNames: Record<string, string> = {
  artwork: "Artwork", calendar: "Planner", capture: "Capture", documents: "Documents",
  dog: "Dog care", facilities: "Facilities", family: "Family", finance: "Finance",
  fitness: "Fitness", homework: "Homework", house: "House", lists: "Lists", meals: "Meals",
  medicine: "Medicine", navigation: "Navigation", naps: "Naps", presents: "Presents",
  routines: "Routines", search: "Search", shopping: "Shopping", stars: "Star charts",
  tasks: "Tasks", today: "Today",
};

const usageActionNames: Record<string, string> = {
  open_capture: "Capture", open_add: "Add", open_search: "Search", open_more: "More",
  open_fitness_log: "Fitness log", open_fitness_coach: "Fitness coach",
  open_swimming_booking: "Swimming booking", book_swimming: "Swimming booking",
  pull_strava: "Strava pull", save_food_log: "Food logging", quick_log_food: "Food logging",
  save_meal_logs: "Food logging", log_planned_meal: "Food logging", log_meal_template: "Food logging",
};

function UsageHistoryPanel() {
  const [summary, setSummary] = useState<UsageHistorySummary | null>(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [showEnable, setShowEnable] = useState(false);
  const [showClear, setShowClear] = useState(false);

  async function loadSummary() {
    setError(null);
    try {
      const loaded = await api<UsageHistorySummary>("/usage-history/summary");
      const normalised = {
        ...loaded,
        screen_views: loaded.screen_views ?? [],
        control_uses: loaded.control_uses ?? [],
        workflows: loaded.workflows ?? [],
      };
      setSummary(normalised);
      setUsageMonitoringConsent(normalised.enabled);
    }
    catch (requestError) { setError(requestError instanceof Error ? requestError.message : "Your usage-summary choice could not be loaded."); }
  }

  useEffect(() => { void loadSummary(); }, []);

  async function setEnabled(enabled: boolean) {
    setBusy(true); setError(null);
    try {
      await api("/usage-history/preferences", { method: "PATCH", body: JSON.stringify({ enabled }) });
      setUsageMonitoringConsent(enabled);
      await loadSummary();
    } catch (requestError) { setError(requestError instanceof Error ? requestError.message : "That choice could not be saved."); }
    finally { setBusy(false); }
  }

  async function downloadHistory() {
    setBusy(true); setError(null);
    try {
      const exported = await api<UsageHistoryExport>("/usage-history/export");
      const url = URL.createObjectURL(new Blob([JSON.stringify(exported, null, 2)], { type: "application/json" }));
      const link = document.createElement("a");
      link.href = url; link.download = `hausklar-recent-use-${new Date().toISOString().slice(0, 10)}.json`;
      document.body.append(link); link.click(); link.remove(); URL.revokeObjectURL(url);
    } catch (requestError) { setError(requestError instanceof Error ? requestError.message : "Your history could not be exported."); }
    finally { setBusy(false); }
  }

  async function clearHistory() {
    setBusy(true); setError(null);
    try { await api("/usage-history/", { method: "DELETE" }); setShowClear(false); await loadSummary(); }
    catch (requestError) { setError(requestError instanceof Error ? requestError.message : "Your history could not be cleared."); }
    finally { setBusy(false); }
  }

  return <section className="account-section usage-history-section">
    <div className="account-section-heading"><History aria-hidden="true" size={22} /><div><h2>Optional usage insights</h2><p>Off by default · nothing is recorded</p></div></div>
    {!summary && !error ? <div className="reminder-skeleton" aria-label="Loading usage-summary choice"><span /><span /></div> : null}
    {error ? <div className="form-error" role="alert">{error} <button type="button" onClick={() => void loadSummary()}>Try again</button></div> : null}
    {summary ? <div className="usage-history-content">
      <label className="reminder-toggle"><input type="checkbox" checked={summary.enabled} disabled={busy} onChange={(event) => event.target.checked ? setShowEnable(true) : void setEnabled(false)} /><span><strong>Keep a private 28-day usage summary</strong><small>{summary.enabled ? "Turning this off stops collection and clears the active summary." : "Nothing is recorded until you explicitly allow it."}</small></span></label>
      {summary.enabled ? <>
        <div className="plain-language-panel">
          <strong>{summary.meaningful_actions ? `You completed ${summary.meaningful_actions} useful action${summary.meaningful_actions === 1 ? "" : "s"} across ${summary.active_days} day${summary.active_days === 1 ? "" : "s"}.` : "No completed actions are in your recent history."}</strong>
          {summary.use_signal === "returning" ? <p>HausKlar has helped on more than one day.</p> : summary.use_signal === "started" ? <p>Your first useful action is in this summary.</p> : null}
          {summary.repeat_modules.length ? <p>You returned to {summary.repeat_modules.map((item) => usageModuleNames[item.module] ?? item.module).join(", ")} on more than one day.</p> : <p>Repeat use will appear here after an area helps on more than one day.</p>}
          {summary.failed_actions ? <p>{summary.failed_actions} action{summary.failed_actions === 1 ? " didn’t" : "s didn’t"} finish. HausKlar does not keep the reason or what you entered.</p> : null}
          {summary.both_adults_contributed ? <p>Both adults completed shared family actions in this period.</p> : null}
          {summary.screen_views.length ? <p>Most opened: {summary.screen_views.slice(0, 5).map((item) => `${usageModuleNames[item.module] ?? item.module} ${item.views}`).join(", ")}.</p> : null}
          {summary.control_uses.length ? <p>Buttons pressed: {summary.control_uses.slice(0, 5).map((item) => `${usageActionNames[item.action] ?? item.action.replaceAll("_", " ")} ${item.presses}`).join(", ")}.</p> : null}
          {summary.workflows.slice(0, 5).map((workflow) => <p key={`${workflow.workflow}:${workflow.action}`}>{usageActionNames[workflow.action] ?? workflow.action.replaceAll("_", " ")}: {workflow.completions} of {workflow.starts} completed{workflow.failures + workflow.abandonments ? `; ${workflow.failures + workflow.abandonments} did not finish` : ""}{workflow.queued_completions ? `; ${workflow.queued_completions} saved offline` : ""}.</p>)}
        </div>
        <p className="usage-history-privacy">For 28 days, the server remembers only reviewed screen and button IDs, generic workflow stages linked by a random per-attempt ID, coarse duration and tap count, connectivity, iOS or web, app version and timestamp. It never stores names, notes, searches, food details, booking details or what an action was about. The facts are linked to your account for this private summary and used only to evaluate which HausKlar features help—never for advertising or cross-app tracking.</p>
        <div className="usage-history-actions"><button type="button" className="button button--secondary" disabled={busy} onClick={() => void downloadHistory()}><Download aria-hidden="true" size={17} /> Export my JSON</button><button type="button" className="button button--secondary" disabled={busy || (summary.meaningful_actions + summary.failed_actions === 0 && !summary.screen_views.length && !summary.control_uses.length && !summary.workflows.length)} onClick={() => setShowClear(true)}><Trash2 aria-hidden="true" size={17} /> Clear my history</button></div>
      </> : <p className="usage-history-privacy">If you choose Allow, content-free action facts will be linked to your account for a private summary and used only to understand which features help. There is no advertising or cross-app tracking.</p>}
    </div> : null}
    <ConfirmDialog open={showEnable} onOpenChange={(open) => { if (!busy) setShowEnable(open); }} title="Allow private usage summary?" description="Your HausKlar server will retain reviewed screen and button IDs, generic workflow stages linked by a random per-attempt ID, coarse duration and tap count, connectivity, iOS or web source, app version and timestamp for 28 days. These facts are linked to your account for your private summary and used only to evaluate which features help. Names, notes, searches, food and booking details, assistant messages, health values, document details, request bodies and response bodies are never recorded. There is no advertising or cross-app tracking. You can turn this off and clear the active summary at any time." confirmLabel="Allow 28-day summary" busy={busy} onConfirm={() => { setShowEnable(false); void setEnabled(true); }} />
    <ConfirmDialog open={showClear} onOpenChange={(open) => { if (!busy) setShowClear(open); }} title="Clear your recent HausKlar history?" description="This clears only the short summary shown here. It does not delete family records, Finance or Fitness data." confirmLabel="Clear my history" destructive busy={busy} onConfirm={() => void clearHistory()} />
  </section>;
}

function FitnessQuickEntrySettings({ ownerID, enabled }: { ownerID: string; enabled: boolean }) {
  const [preferences, setPreferences] = useState<FitnessQuickEntryPreferences>(() => (
    cachedFitnessQuickEntryPreferences(ownerID) ?? DEFAULT_FITNESS_QUICK_ENTRY_PREFERENCES
  ));
  const [loaded, setLoaded] = useState(false);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [notice, setNotice] = useState<string | null>(null);
  const [nonce, setNonce] = useState(0);

  useEffect(() => {
    if (!enabled) {
      setLoaded(true);
      return;
    }
    let active = true;
    setLoaded(false);
    setError(null);
    void api<FitnessQuickEntryPreferences>("/fitness/quick-entry-preferences", {}, true, false)
      .then((loadedPreferences) => {
        if (!validFitnessQuickEntryPreferences(loadedPreferences)) throw new Error("Meal times were returned in an unexpected format.");
        rememberFitnessQuickEntryPreferences(ownerID, loadedPreferences);
        if (active) setPreferences(loadedPreferences);
      })
      .catch((requestError) => {
        if (active) {
          const cached = cachedFitnessQuickEntryPreferences(ownerID);
          if (cached) setPreferences(cached);
          else setError(requestError instanceof Error ? requestError.message : "Meal times could not be loaded.");
        }
      })
      .finally(() => { if (active) setLoaded(true); });
    return () => { active = false; };
  }, [enabled, nonce, ownerID]);

  async function save(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    setBusy(true);
    setError(null);
    setNotice(null);
    try {
      const saved = await api<FitnessQuickEntryPreferences>(
        "/fitness/quick-entry-preferences",
        { method: "PATCH", body: JSON.stringify({ meal_times: preferences.meal_times }) },
        true,
        false,
      );
      if (!validFitnessQuickEntryPreferences(saved)) throw new Error("Meal times were saved in an unexpected format.");
      setPreferences(saved);
      rememberFitnessQuickEntryPreferences(ownerID, saved);
      announceFitnessQuickEntryPreferences(ownerID, saved);
      setNotice("Meal shortcut times saved.");
    } catch (requestError) {
      setError(requestError instanceof Error ? requestError.message : "Meal times could not be saved.");
    } finally {
      setBusy(false);
    }
  }

  return <div className="settings-quick-entry">
    <div className="settings-quick-entry__heading"><Utensils aria-hidden="true" size={20} /><span><strong>Food shortcuts on Today</strong><small>Show a quick nutrition entry around each meal, then stay out of the way.</small></span></div>
    {!enabled ? <p className="settings-workspace-empty">Enable Fitness to set your private meal shortcut times.</p> : !loaded ? <div className="reminder-skeleton" aria-label="Loading meal shortcut times"><span /><span /></div> : null}
    {enabled && loaded ? <form className="settings-quick-entry__form" aria-busy={busy} onSubmit={(event) => void save(event)}>
      <div className="field"><label htmlFor="fitness-breakfast-time">Breakfast</label><input id="fitness-breakfast-time" type="time" required value={preferences.meal_times.breakfast} onChange={(event) => setPreferences((current) => ({ ...current, meal_times: { ...current.meal_times, breakfast: event.target.value } }))} /></div>
      <div className="field"><label htmlFor="fitness-lunch-time">Lunch</label><input id="fitness-lunch-time" type="time" required value={preferences.meal_times.lunch} onChange={(event) => setPreferences((current) => ({ ...current, meal_times: { ...current.meal_times, lunch: event.target.value } }))} /></div>
      <div className="field"><label htmlFor="fitness-dinner-time">Dinner</label><input id="fitness-dinner-time" type="time" required value={preferences.meal_times.dinner} onChange={(event) => setPreferences((current) => ({ ...current, meal_times: { ...current.meal_times, dinner: event.target.value } }))} /></div>
      {error ? <div className="form-error" role="alert">{error} <button type="button" onClick={() => setNonce((value) => value + 1)}>Try again</button></div> : null}
      {notice ? <p className="form-success" role="status">{notice}</p> : null}
      <button type="submit" className="button button--secondary" disabled={busy}>{busy ? "Saving…" : "Save meal times"}</button>
    </form> : null}
  </div>;
}

function SchoolRugbyConnection() {
  const [settingsState, setSettingsState] = useState<SchoolRugbySettings | null>(null);
  const [teamList, setTeamList] = useState<SchoolRugbyTeamList | null>(null);
  const [selectedTeamID, setSelectedTeamID] = useState("");
  const [loaded, setLoaded] = useState(false);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [notice, setNotice] = useState<string | null>(null);
  const [reloadKey, setReloadKey] = useState(0);

  useEffect(() => {
    let active = true;
    setLoaded(false);
    setError(null);
    void Promise.all([
      api<SchoolRugbySettings>("/calendar/rugby"),
      api<SchoolRugbyTeamList>("/calendar/rugby/teams", { timeoutMs: 30_000 }),
    ])
      .then(([saved, published]) => {
        if (!active) return;
        setSettingsState(saved);
        setTeamList(published);
        setSelectedTeamID(saved.team_id ?? "");
      })
      .catch((requestError) => {
        if (active) setError(requestError instanceof Error ? requestError.message : "Example School rugby teams could not be loaded.");
      })
      .finally(() => { if (active) setLoaded(true); });
    return () => { active = false; };
  }, [reloadKey]);

  async function saveTeam(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (!selectedTeamID) return;
    setBusy(true); setError(null); setNotice(null);
    try {
      const saved = await api<SchoolRugbySettings>("/calendar/rugby", {
        method: "PUT",
        body: JSON.stringify({ team_id: selectedTeamID }),
        timeoutMs: 30_000,
      });
      setSettingsState(saved);
      setSelectedTeamID(saved.team_id ?? selectedTeamID);
      setNotice(saved.last_error
        ? "Team saved. The fixtures need another refresh."
        : `${saved.fixture_count} ${saved.team_name ?? "rugby"} fixture${saved.fixture_count === 1 ? "" : "s"} added to the planner.`);
    } catch (requestError) {
      setError(requestError instanceof Error ? requestError.message : "The rugby team could not be saved.");
    } finally {
      setBusy(false);
    }
  }

  async function refreshFixtures() {
    setBusy(true); setError(null); setNotice(null);
    try {
      await api("/calendar/rugby/sync", { method: "POST", timeoutMs: 30_000 });
      const refreshed = await api<SchoolRugbySettings>("/calendar/rugby");
      setSettingsState(refreshed);
      setNotice(`${refreshed.fixture_count} fixture${refreshed.fixture_count === 1 ? "" : "s"} checked against Example School.`);
    } catch (requestError) {
      setError(requestError instanceof Error ? requestError.message : "The rugby fixtures could not be refreshed.");
    } finally {
      setBusy(false);
    }
  }

  const currentTeamMissing = Boolean(
    settingsState?.team_id && !teamList?.teams.some((team) => team.id === settingsState.team_id),
  );

  return <div className="guided-connection example_school-rugby-connection">
    <div className="connection-title"><CalendarSync aria-hidden="true" size={20} /><div><strong>Example School rugby fixtures</strong><p>Choose the team HausKlar should keep in the family planner.</p></div><span>{settingsState?.configured ? `${settingsState.fixture_count} fixture${settingsState.fixture_count === 1 ? "" : "s"}` : "Not connected"}</span></div>
    {!loaded ? <div className="reminder-skeleton" aria-label="Loading Example School rugby teams"><span /><span /></div> : null}
    {error ? <div className="form-error" role="alert">{error} <button type="button" onClick={() => setReloadKey((value) => value + 1)}>Try again</button></div> : null}
    {loaded && teamList ? <form className="form-stack" aria-busy={busy} onSubmit={(event) => void saveTeam(event)}>
      <div className="field"><label htmlFor="example_school-rugby-team">Rugby team</label><select id="example_school-rugby-team" value={selectedTeamID} disabled={busy || !teamList.teams.length} required onChange={(event) => { setSelectedTeamID(event.target.value); setNotice(null); }}><option value="">Choose a team</option>{currentTeamMissing ? <option value={settingsState?.team_id ?? ""}>{settingsState?.team_name ?? "Current team"}</option> : null}{teamList.teams.map((team) => <option key={team.id} value={team.id}>{team.name}</option>)}</select><small>{teamList.season} season · sourced from Example School College Sports</small></div>
      <div className="rugby-calendar-rule"><strong>1:00–7:00 pm is reserved for every fixture.</strong><span><b>HOME</b> or <b className="is-away">AWAY</b> appears first. Away blocks are red throughout the planner.</span>{settingsState?.configured ? <span>{settingsState.owner_name ?? "The calendar owner"} is attending{settingsState.affected_names.length ? ` · affects ${settingsState.affected_names.join(" & ")}` : ""}.</span> : null}</div>
      {settingsState?.last_error ? <div className="connection-check is-error" role="alert"><span><strong>Last refresh did not finish</strong><small>{settingsState.last_error}</small></span></div> : null}
      {notice ? <p className="form-success" role="status">{notice}</p> : null}
      <div className="connection-actions"><button type="submit" className="button button--primary" disabled={busy || !selectedTeamID}>{busy ? "Saving…" : settingsState?.configured ? "Save team" : "Connect team"}</button>{settingsState?.configured ? <button type="button" className="button button--secondary" disabled={busy} onClick={() => void refreshFixtures()}><RefreshCw aria-hidden="true" size={17} /> Refresh fixtures</button> : null}</div>
      {settingsState?.last_success_at ? <small className="rugby-last-sync">Last checked <time dateTime={settingsState.last_success_at}>{new Date(settingsState.last_success_at).toLocaleString()}</time></small> : null}
    </form> : null}
  </div>;
}

export function AccountView({ user, onUserUpdated, onSignOut, financeAvailable = false, fitnessWorkspace, onFitnessWorkspaceChange, onOpenFinance, onOpenFitness }: {
  user: User;
  onUserUpdated: (user: User) => void;
  onSignOut: () => void;
  financeAvailable?: boolean;
  fitnessWorkspace?: FitnessWorkspacePreference | null;
  onFitnessWorkspaceChange?: (patch: Partial<FitnessWorkspacePreference>) => Promise<unknown>;
  onOpenFinance?: () => void;
  onOpenFitness?: () => void;
}) {
  const [category, setCategory] = useState<SettingsCategory | null>(user.must_change_password ? "advanced" : null);
  const [profileName, setProfileName] = useState(user.name);
  const [profileBusy, setProfileBusy] = useState(false);
  const [profileMessage, setProfileMessage] = useState<string | null>(null);
  const [currentPassword, setCurrentPassword] = useState("");
  const [newPassword, setNewPassword] = useState("");
  const [confirmation, setConfirmation] = useState("");
  const [showPasswords, setShowPasswords] = useState(false);
  const [submitting, setSubmitting] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [success, setSuccess] = useState<string | null>(null);
  const [members, setMembers] = useState<FamilyMember[]>([]);
  const [familyLoaded, setFamilyLoaded] = useState(false);
  const [familyError, setFamilyError] = useState<string | null>(null);
  const [invite, setInvite] = useState<FamilyInvite | null>(null);
  const [inviteBusy, setInviteBusy] = useState(false);
  const [sources, setSources] = useState<CalendarSource[]>([]);
  const [sourceName, setSourceName] = useState("");
  const [sourceUrl, setSourceUrl] = useState("");
  const [sourcePerson, setSourcePerson] = useState("");
  const [calendarBusy, setCalendarBusy] = useState(false);
  const [connectionsLoaded, setConnectionsLoaded] = useState(false);
  const [calendarError, setCalendarError] = useState<string | null>(null);
  const [calendarValidation, setCalendarValidation] = useState<{ hostname: string; event_count: number } | null>(null);
  const [feed, setFeed] = useState<CalendarFeedStatus>({ configured: false });
  const [newFeedUrl, setNewFeedUrl] = useState<string | null>(null);
  const [ha, setHA] = useState<HASettings>({ dashboard_url: null, ha_url: null, token_configured: false, configured: false });
  const [haDashboardURL, setHADashboardURL] = useState("");
  const [haURL, setHAURL] = useState("");
  const [haToken, setHAToken] = useState("");
  const [haCheck, setHACheck] = useState<HATest | null>(null);
  const [haBusy, setHABusy] = useState(false);
  const [reminders, setReminders] = useState<ReminderPreferences>(defaultReminders);
  const [push, setPush] = useState<PushStatus>({ configured: false, subscribed: false });
  const [reminderPreview, setReminderPreview] = useState<ReminderPreviewItem[]>([]);
  const [reminderBusy, setReminderBusy] = useState(false);
  const [reminderLoaded, setReminderLoaded] = useState(false);
  const [reminderError, setReminderError] = useState<string | null>(null);
  const [confirmPrivacyMode, setConfirmPrivacyMode] = useState<boolean | null>(null);
  const [pendingConfirmation, setPendingConfirmation] = useState<{ kind: "remove"; sourceId: string; sourceName: string } | { kind: "rotate" } | null>(null);
  const [showDeleteAccount, setShowDeleteAccount] = useState(false);
  const [deletingAccount, setDeletingAccount] = useState(false);
  const [deleteError, setDeleteError] = useState<string | null>(null);
  const aiConsent = useAIConsent(category === "privacy" && !user.must_change_password);

  useEffect(() => {
    if (category !== "notifications" || reminderLoaded) return;
    let active = true;
    Promise.all([api<ReminderPreferences>("/reminders/preferences"), api<PushStatus>("/reminders/push"), api<ReminderPreviewItem[]>("/reminders/preview")])
      .then(async ([preferences, pushStatus, preview]) => {
        if (!active) return;
        const subscribedHere = await currentBrowserHasPushSubscription();
        if (!active) return;
        setReminders(preferences); setPush({ ...pushStatus, subscribed: subscribedHere }); setReminderPreview(preview);
      })
      .catch((requestError) => { if (active) setReminderError(requestError instanceof Error ? requestError.message : "Reminders could not be loaded."); })
      .finally(() => { if (active) setReminderLoaded(true); });
    return () => { active = false; };
  }, [category, reminderLoaded]);

  useEffect(() => {
    if ((category !== "family" && category !== "connections") || familyLoaded) return;
    let active = true;
    void api<FamilyMember[]>("/family/members")
      .then((items) => { if (active) setMembers(items); })
      .catch((requestError) => { if (active) setFamilyError(requestError instanceof Error ? requestError.message : "Family members could not be loaded."); })
      .finally(() => { if (active) setFamilyLoaded(true); });
    return () => { active = false; };
  }, [category, familyLoaded]);

  useEffect(() => {
    if (category !== "connections" || user.role !== "admin" || connectionsLoaded) return;
    let active = true;
    Promise.all([api<CalendarSource[]>("/calendar/sources"), api<CalendarFeedStatus>("/calendar/feed"), api<HASettings>("/family/settings/ha")])
      .then(([loadedSources, loadedFeed, loadedHA]) => {
        if (!active) return;
        setSources(loadedSources); setFeed(loadedFeed); setHA(loadedHA);
        setHADashboardURL(loadedHA.dashboard_url ?? ""); setHAURL(loadedHA.ha_url ?? "");
      })
      .catch((requestError) => { if (active) setCalendarError(requestError instanceof Error ? requestError.message : "Connections could not be loaded."); })
      .finally(() => { if (active) setConnectionsLoaded(true); });
    return () => { active = false; };
  }, [category, connectionsLoaded, user.role]);

  async function saveProfile(event: FormEvent) {
    event.preventDefault(); setProfileBusy(true); setProfileMessage(null);
    try {
      const updated = await api<User>("/auth/me", { method: "PATCH", body: JSON.stringify({ name: profileName }) });
      setProfileName(updated.name); onUserUpdated(updated); setProfileMessage("Profile saved.");
    } catch (requestError) { setProfileMessage(requestError instanceof Error ? requestError.message : "Profile could not be saved."); }
    finally { setProfileBusy(false); }
  }

  async function persistReminders(next: ReminderPreferences, message = "Saved automatically.") {
    setReminders(next); setReminderBusy(true); setReminderError(null);
    try {
      const saved = await api<ReminderPreferences>("/reminders/preferences", { method: "PUT", body: JSON.stringify(next) });
      setReminders(saved); setReminderPreview(await api<ReminderPreviewItem[]>("/reminders/preview")); setSuccess(message);
    } catch (requestError) { setReminderError(requestError instanceof Error ? requestError.message : "Reminder settings could not be saved."); }
    finally { setReminderBusy(false); }
  }

  async function enableBrowserReminders() {
    setReminderBusy(true); setReminderError(null);
    try {
      if (!push.configured || !push.public_key) throw new Error("Browser reminders are not configured on this server yet.");
      const permission = await Notification.requestPermission();
      if (permission !== "granted") throw new Error("Notifications are blocked. Open the exact browser or system setting shown below.");
      const registration = await navigator.serviceWorker.ready;
      const subscription = await registration.pushManager.subscribe({ userVisibleOnly: true, applicationServerKey: applicationServerKey(push.public_key) });
      const json = subscription.toJSON();
      setPush(await api<PushStatus>("/reminders/push/subscriptions", { method: "POST", body: JSON.stringify({ endpoint: json.endpoint, p256dh: json.keys?.p256dh, auth: json.keys?.auth }) }));
      setSuccess("Browser reminders enabled.");
    } catch (requestError) { setReminderError(requestError instanceof Error ? requestError.message : "Browser reminders could not be enabled."); }
    finally { setReminderBusy(false); }
  }

  async function disableBrowserReminders() {
    setReminderBusy(true); setReminderError(null);
    try {
      const result = await revokeCurrentBrowserPushSubscription();
      if (result.hadSubscription && !result.unsubscribed) throw new Error("This browser could not turn off notifications. Please try again.");
      setPush((current) => ({ ...current, subscribed: false }));
    } catch (requestError) { setReminderError(requestError instanceof Error ? requestError.message : "Browser reminders could not be disabled."); }
    finally { setReminderBusy(false); }
  }

  async function generateInvite() {
    setInviteBusy(true); setFamilyError(null);
    try { setInvite(await api<FamilyInvite>("/auth/invite", { method: "POST" })); }
    catch (requestError) { setFamilyError(requestError instanceof Error ? requestError.message : "Invitation could not be created."); }
    finally { setInviteBusy(false); }
  }

  function changeCalendarCandidate(field: "name" | "url" | "person", value: string) {
    setCalendarValidation(null);
    if (field === "name") setSourceName(value); else if (field === "url") setSourceUrl(value); else setSourcePerson(value);
  }

  async function validateCalendar() {
    setCalendarBusy(true); setCalendarError(null);
    try {
      const checked = await api<{ valid: true; hostname: string; event_count: number }>("/calendar/sources/validate", { method: "POST", body: JSON.stringify({ name: sourceName, url: sourceUrl, assigned_to: sourcePerson || null }), timeoutMs: 30_000 });
      setCalendarValidation(checked);
    } catch (requestError) { setCalendarError(requestError instanceof Error ? requestError.message : "Calendar link could not be checked."); }
    finally { setCalendarBusy(false); }
  }

  async function addCalendarSource(event: FormEvent) {
    event.preventDefault(); if (!calendarValidation) return;
    setCalendarBusy(true); setCalendarError(null);
    try {
      const source = await api<CalendarSource>("/calendar/sources", { method: "POST", body: JSON.stringify({ name: sourceName, url: sourceUrl, assigned_to: sourcePerson || null }), timeoutMs: 30_000 });
      setSources((current) => [...current.filter((item) => item.id !== source.id), source].sort((a, b) => a.name.localeCompare(b.name)));
      setSourceName(""); setSourceUrl(""); setSourcePerson(""); setCalendarValidation(null);
    } catch (requestError) { setCalendarError(requestError instanceof Error ? requestError.message : "Calendar could not be added."); }
    finally { setCalendarBusy(false); }
  }

  async function syncSource(sourceId: string) {
    setCalendarBusy(true); setCalendarError(null);
    try { await api(`/calendar/sources/${sourceId}/sync`, { method: "POST", timeoutMs: 30_000 }); setSources(await api<CalendarSource[]>("/calendar/sources")); }
    catch (requestError) { setCalendarError(requestError instanceof Error ? requestError.message : "Calendar could not be refreshed."); }
    finally { setCalendarBusy(false); }
  }

  async function removeSource(sourceId: string) {
    setCalendarBusy(true);
    try { await api(`/calendar/sources/${sourceId}`, { method: "DELETE" }); setSources((current) => current.filter((source) => source.id !== sourceId)); setPendingConfirmation(null); }
    catch (requestError) { setCalendarError(requestError instanceof Error ? requestError.message : "Calendar could not be removed."); }
    finally { setCalendarBusy(false); }
  }

  async function rotateFeed() {
    setCalendarBusy(true);
    try { const created = await api<CalendarFeedStatus>("/calendar/feed/rotate", { method: "POST" }); setFeed(created); setNewFeedUrl(created.feed_url ?? null); setPendingConfirmation(null); }
    catch (requestError) { setCalendarError(requestError instanceof Error ? requestError.message : "Subscription link could not be created."); }
    finally { setCalendarBusy(false); }
  }

  async function testHA() {
    setHABusy(true); setHACheck(null);
    try {
      const body = haToken ? { ha_url: haURL, ha_token: haToken } : {};
      setHACheck(await api<HATest>("/family/settings/ha/test", { method: "POST", body: JSON.stringify(body) }));
    } catch (requestError) { setHACheck({ success: false, message: requestError instanceof Error ? requestError.message : "Home Assistant could not be checked." }); }
    finally { setHABusy(false); }
  }

  async function saveHA() {
    if (!haCheck?.success) return;
    setHABusy(true);
    try {
      const saved = await api<HASettings>("/family/settings/ha", { method: "PUT", body: JSON.stringify({ dashboard_url: haDashboardURL || null, ha_url: haURL || null, ha_token: haToken || null }) });
      setHA(saved); setHAToken(""); setHACheck(null); setSuccess("Home connection saved.");
    } catch (requestError) { setHACheck({ success: false, message: requestError instanceof Error ? requestError.message : "Home connection could not be saved." }); }
    finally { setHABusy(false); }
  }

  async function changePassword(event: FormEvent) {
    event.preventDefault(); setError(null); setSuccess(null);
    if (newPassword.length < 12) { setError("Use at least 12 characters for the new password."); return; }
    if (newPassword !== confirmation) { setError("The new passwords do not match."); return; }
    if (newPassword === currentPassword) { setError("Choose a password different from the current one."); return; }
    setSubmitting(true);
    try {
      const updated = await api<User>("/auth/web/change-password", { method: "POST", body: JSON.stringify({ current_password: currentPassword, new_password: newPassword }) });
      onUserUpdated(updated); setCurrentPassword(""); setNewPassword(""); setConfirmation(""); setSuccess("Password changed.");
    } catch (requestError) { setError(requestError instanceof Error ? requestError.message : "The password could not be changed."); }
    finally { setSubmitting(false); }
  }

  async function deleteAccount() {
    setDeletingAccount(true); setDeleteError(null);
    try { await api<void>("/auth/me", { method: "DELETE" }); await purgeCurrentFitnessOwnerData(); onSignOut(); }
    catch (requestError) { setDeleteError(requestError instanceof Error ? requestError.message : "Your account could not be deleted."); setShowDeleteAccount(false); }
    finally { setDeletingAccount(false); }
  }

  const inputType = showPasswords ? "text" : "password";
  const permissionRecovery = notificationSettingsTarget();

  return <div className="account-page account-page--progressive">
    <header className="page-header"><div><p className="page-eyebrow">Settings & profile</p><h1>{category ? categoryCopy.find((item) => item.id === category)?.title : "Settings"}</h1><p>{category ? <button type="button" className="settings-back" onClick={() => setCategory(null)}>← All settings</button> : "Clear status, one useful choice at a time."}</p></div></header>
    {user.must_change_password ? <div className="account-required" role="status"><ShieldCheck aria-hidden="true" size={22} /><div><strong>Replace your temporary password</strong><p>Choose a private password before continuing to use HausKlar.</p></div></div> : null}

    {!category && !user.must_change_password ? <div className="settings-category-list">{categoryCopy.map((item) => { const Icon = item.icon; const status = item.id === "account" ? `${user.name} · ${user.role === "admin" ? "Family administrator" : "Family member"}` : item.id === "notifications" ? "Open to review this device" : item.id === "workspaces" ? "Open to manage" : item.id === "family" ? user.role === "admin" ? "You can manage people" : "Shared household" : item.id === "connections" ? user.role === "admin" ? "Open to check connections" : "Managed by an administrator" : item.id === "privacy" ? "Review explicit permissions" : "Security and session"; return <button type="button" key={item.id} className="settings-category-card" onClick={() => setCategory(item.id)}><Icon aria-hidden="true" size={22} /><span><strong>{item.title}</strong><small>{item.description}</small><em>{status}</em></span><ChevronRight aria-hidden="true" size={19} /></button>; })}</div> : null}

    <div className="account-layout">
      {category === "account" ? <section className="account-section"><div className="account-section-heading"><UserRound aria-hidden="true" size={22} /><div><h2>Profile</h2><p>Your name appears beside family activity</p></div></div><form className="form-stack" onSubmit={saveProfile}><div className="field"><label htmlFor="profile-name">Name</label><input id="profile-name" value={profileName} onChange={(event) => setProfileName(event.target.value)} maxLength={100} required /></div><div className="field"><label>Email</label><input value={user.email} readOnly aria-readonly="true" /><small>Your email is your secure sign-in identity.</small></div><button className="button button--primary" disabled={profileBusy || profileName.trim() === user.name}>{profileBusy ? "Saving…" : "Save profile"}</button>{profileMessage ? <p role="status">{profileMessage}</p> : null}</form><div className="plain-language-panel"><strong>{user.role === "admin" ? "You are a family administrator" : "You are a family member"}</strong><p>{user.role === "admin" ? "You can invite adults and manage household connections. This does not give you access to another adult’s private Money or Fitness records." : "You can use the shared planner and family records. An administrator manages people and household connections; your private adult areas remain yours."}</p><p>Shared planner and family records are visible to both adults. Private adult areas stay private.</p></div></section> : null}

      {category === "workspaces" ? <section className="account-section">
        <div className="account-section-heading"><WalletCards aria-hidden="true" size={22} /><div><h2>Personal workspaces</h2><p>Money and Fitness</p></div></div>
        {financeAvailable && onOpenFinance ? <button type="button" className="settings-workspace-link" onClick={onOpenFinance}><WalletCards aria-hidden="true" size={22} /><span><strong>Money</strong><small>Budgets, goals and spending</small></span><ChevronRight aria-hidden="true" size={19} /></button> : null}
        {fitnessWorkspace !== undefined && onFitnessWorkspaceChange ? <div className="settings-workspace-control">
          <div className="settings-workspace-control__heading"><Dumbbell aria-hidden="true" size={22} /><span><strong>Fitness</strong><small>Training, recovery and nutrition</small></span></div>
          <label className="reminder-toggle"><input type="checkbox" aria-label="Use Fitness" checked={fitnessWorkspace?.enabled ?? false} onChange={(event) => void onFitnessWorkspaceChange({ enabled: event.target.checked })} /><span><strong>Use Fitness</strong><small>Keep the workspace ready for this account</small></span></label>
          <label className="reminder-toggle"><input type="checkbox" aria-label="Pin Fitness in navigation" checked={fitnessWorkspace?.pinned ?? false} disabled={!fitnessWorkspace?.enabled} onChange={(event) => void onFitnessWorkspaceChange({ pinned: event.target.checked })} /><span><strong>Pin Fitness in navigation</strong><small>Keep it beside the family’s daily destinations</small></span></label>
          <label className="reminder-toggle"><input type="checkbox" aria-label="Show nutrition progress on Today" checked={fitnessWorkspace?.show_nutrition_today ?? false} disabled={!fitnessWorkspace?.enabled} onChange={(event) => void onFitnessWorkspaceChange({ show_nutrition_today: event.target.checked })} /><span><strong>Show nutrition progress on Today</strong><small>Display your private calorie and protein running totals against today’s goals</small></span></label>
          <FitnessQuickEntrySettings ownerID={user.id} enabled={fitnessWorkspace?.enabled ?? false} />
          {fitnessWorkspace?.enabled && onOpenFitness ? <button type="button" className="button button--secondary" onClick={onOpenFitness}>Open Fitness</button> : null}
        </div> : null}
        {!financeAvailable && fitnessWorkspace === undefined ? <p className="settings-workspace-empty">No personal workspaces are available for this account yet.</p> : null}
      </section> : null}

      {category === "notifications" ? <section className="account-section reminder-section"><div className="account-section-heading"><Bell aria-hidden="true" size={22} /><div><h2>Notifications</h2><p>{push.subscribed ? "Enabled on this browser" : "Next: choose whether this device may notify you"}</p></div></div>{!reminderLoaded ? <div className="reminder-skeleton" aria-label="Loading reminder settings"><span /><span /><span /></div> : null}{reminderError ? <div className="form-error" role="alert">{reminderError}</div> : null}{reminderLoaded ? <div className="reminder-form"><fieldset disabled={reminderBusy}><legend>Useful nudges</legend>{([ ["event_reminders_enabled", "Upcoming events", "Events for you and the whole family"], ["task_reminders_enabled", "Due tasks", "Shared tasks and tasks assigned to you"], ["morning_summary_enabled", "Morning summary", "What matters today"], ["evening_summary_enabled", "Tomorrow, sorted", "One calm look at tomorrow"] ] as const).map(([key, label, detail]) => <label className="reminder-toggle" key={key}><input type="checkbox" checked={reminders[key]} onChange={(event) => void persistReminders({ ...reminders, [key]: event.target.checked })} /><span><strong>{label}</strong><small>{detail}</small></span></label>)}</fieldset><div className="reminder-fields"><div className="field"><label htmlFor="event-lead">Event warning</label><select id="event-lead" value={reminders.event_minutes_before} onChange={(event) => void persistReminders({ ...reminders, event_minutes_before: Number(event.target.value) })}><option value={10}>10 minutes before</option><option value={30}>30 minutes before</option><option value={60}>1 hour before</option><option value={1440}>1 day before</option></select></div><div className="field"><label htmlFor="morning-time">Morning summary</label><input id="morning-time" type="time" value={reminders.morning_summary_time} onChange={(event) => setReminders({ ...reminders, morning_summary_time: event.target.value })} onBlur={() => void persistReminders(reminders)} /></div><div className="field"><label htmlFor="quiet-start">Quiet from</label><input id="quiet-start" type="time" value={reminders.quiet_start} onChange={(event) => setReminders({ ...reminders, quiet_start: event.target.value })} onBlur={() => void persistReminders(reminders)} /></div></div><label className="reminder-toggle privacy-toggle"><input type="checkbox" checked={reminders.privacy_mode} onChange={(event) => setConfirmPrivacyMode(event.target.checked)} /><span><strong>Private lock-screen wording</strong><small>This security choice needs confirmation because turning it off can reveal family details on a locked screen.</small></span></label><div className="reminder-actions">{push.subscribed ? <><button type="button" className="button button--secondary" disabled={reminderBusy} onClick={() => void api("/reminders/test", { method: "POST" }).then(() => setSuccess("Test reminder sent."))}>Send test</button><button type="button" className="button button--secondary" disabled={reminderBusy} onClick={() => void disableBrowserReminders()}>Disable on this browser</button></> : <button type="button" className="button button--primary" disabled={reminderBusy || !push.configured || !("Notification" in window) || !("serviceWorker" in navigator)} onClick={() => void enableBrowserReminders()}>Enable on this browser</button>}</div>{typeof Notification !== "undefined" && Notification.permission === "denied" ? <div className="permission-recovery"><strong>Notifications are blocked</strong><p>{permissionRecovery.instructions}</p>{permissionRecovery.url ? <a className="button button--secondary" href={permissionRecovery.url} target="_blank" rel="noreferrer">Open notification settings</a> : null}</div> : null}<div className="reminder-preview"><strong>Coming up</strong>{reminderPreview.length ? <ul>{reminderPreview.slice(0, 4).map((item) => <li key={item.id}><span className="reminder-kind">{item.kind}</span><div><strong>{item.title}</strong><small>{item.detail}</small></div></li>)}</ul> : <p>All clear—there are no reminders in the next two days.</p>}</div></div> : null}</section> : null}

      {category === "family" ? <section className="account-section"><div className="account-section-heading"><UsersRound aria-hidden="true" size={22} /><div><h2>Family administration</h2><p>{members.length > 1 ? `${members.length} people connected` : "Next: invite the other adult or establish a child"}</p></div></div>{familyError ? <div className="form-error" role="alert">{familyError}</div> : null}{familyLoaded ? <ul className="settings-people-list">{members.map((member) => <li key={member.id}><UserRound aria-hidden="true" size={18} /><span><strong>{member.name}</strong><small>{member.member_type === "user" ? "Adult account" : "Child profile · managed by adults"}</small></span></li>)}</ul> : <div className="reminder-skeleton"><span /><span /></div>}{user.role === "admin" ? <div className="invite-panel"><div><strong>Invite the other adult</strong><p>The invitation is single-use, expires after 24 hours and opens the secure Join household screen.</p></div><button type="button" className="button button--primary" onClick={() => void generateInvite()} disabled={inviteBusy}>{inviteBusy ? "Creating…" : invite ? "Replace invitation" : "Create invitation"}</button>{invite ? <div className="invite-share"><QRCode value={invite.join_url} label="QR code to join this HausKlar household" /><code>{invite.invite_code}</code><div><button type="button" className="button button--secondary" onClick={() => void navigator.clipboard.writeText(invite.join_url)}><Copy size={16} /> Copy link</button>{typeof navigator.share === "function" ? <button type="button" className="button button--secondary" onClick={() => void navigator.share({ title: "Join our HausKlar household", url: invite.join_url })}>Share…</button> : null}</div><small>Expires {new Date(invite.expires_at).toLocaleString()}.</small></div> : null}</div> : <p>An administrator can invite another adult and manage connections.</p>}</section> : null}

      {category === "connections" ? <section className="account-section connections-section"><div className="account-section-heading"><PlugZap aria-hidden="true" size={22} /><div><h2>Connections</h2><p>{user.role === "admin" ? "Validate each connection before anything is saved" : "Managed by a family administrator"}</p></div></div>{user.role !== "admin" ? <p>Ask a family administrator to connect calendars or Home Assistant. You can use connected services without seeing their private tokens or links.</p> : !connectionsLoaded ? <div className="reminder-skeleton"><span /><span /><span /></div> : <><SchoolRugbyConnection /><div className="guided-connection"><div className="connection-title"><CalendarSync size={20} /><div><strong>Bring in a calendar</strong><p>Use a private ICS subscription link from Apple, Google, Outlook or school.</p></div><span>{sources.length ? `${sources.length} connected` : "Not connected"}</span></div><ol className="connection-steps"><li>Copy the private subscription link from the calendar provider.</li><li>Check that HausKlar can safely download and read it.</li><li>Only then add it to the family planner.</li></ol><form className="form-stack" onSubmit={addCalendarSource}><div className="field"><label htmlFor="calendar-source-name">Calendar name</label><input id="calendar-source-name" value={sourceName} onChange={(event) => changeCalendarCandidate("name", event.target.value)} placeholder="School calendar" required /></div><div className="field"><label htmlFor="calendar-source-url">Private ICS link</label><input id="calendar-source-url" type="url" value={sourceUrl} onChange={(event) => changeCalendarCandidate("url", event.target.value)} placeholder="https://…/calendar.ics" required /></div><div className="field"><label htmlFor="calendar-source-person">Who is it for?</label><select id="calendar-source-person" value={sourcePerson} onChange={(event) => changeCalendarCandidate("person", event.target.value)}><option value="">Whole family</option>{members.map((member) => <option key={member.id} value={member.id}>{member.name}</option>)}</select></div>{calendarError ? <div className="form-error" role="alert">{calendarError}</div> : null}{calendarValidation ? <div className="connection-check is-success"><CheckCircle2 size={18} /><span><strong>Connection works</strong><small>{calendarValidation.hostname} · {calendarValidation.event_count} upcoming event{calendarValidation.event_count === 1 ? "" : "s"} found</small></span></div> : null}<div className="connection-actions"><button type="button" className="button button--secondary" disabled={calendarBusy || !sourceName || !sourceUrl} onClick={() => void validateCalendar()}>{calendarBusy ? "Checking…" : "Check connection"}</button><button className="button button--primary" disabled={calendarBusy || !calendarValidation}>Add calendar</button></div></form>{sources.map((source) => <article className="calendar-source-row" key={source.id}><span className="calendar-source-swatch" style={{ background: source.color }} /><div><strong>{source.name}</strong><p>{source.hostname} · {source.last_success_at ? `Updated ${new Date(source.last_success_at).toLocaleString()}` : "Not synced yet"}</p>{source.last_error ? <p className="calendar-source-error">{source.last_error}</p> : null}</div><button type="button" className="icon-button" aria-label={`Refresh ${source.name}`} onClick={() => void syncSource(source.id)}><RefreshCw size={17} /></button><button type="button" className="icon-button icon-button--danger" aria-label={`Remove ${source.name}`} onClick={() => setPendingConfirmation({ kind: "remove", sourceId: source.id, sourceName: source.name })}><Trash2 size={17} /></button></article>)}<div className="calendar-feed-panel"><div><strong>Use HausKlar in another calendar</strong><p>Create a private read-only link. It is shown once.</p></div><button type="button" className="button button--secondary" onClick={() => feed.configured ? setPendingConfirmation({ kind: "rotate" }) : void rotateFeed()}>{feed.configured ? "Replace link" : "Create link"}</button>{newFeedUrl ? <div className="calendar-feed-url"><input aria-label="Calendar subscription link" value={newFeedUrl} readOnly /><button type="button" className="icon-button" aria-label="Copy subscription link" onClick={() => void navigator.clipboard.writeText(newFeedUrl)}><Copy size={17} /></button></div> : null}</div></div><div className="guided-connection"><div className="connection-title"><PlugZap size={20} /><div><strong>Home Assistant</strong><p>{ha.configured ? "Connected. Test replacement details before saving." : "Next: add the private server address and a long-lived access token."}</p></div><span>{ha.configured ? "Connected" : "Not connected"}</span></div><details><summary>Advanced connection details</summary><div className="form-stack"><div className="field"><label htmlFor="ha-dashboard">Dashboard address</label><input id="ha-dashboard" type="url" value={haDashboardURL} onChange={(event) => { setHADashboardURL(event.target.value); setHACheck(null); }} /></div><div className="field"><label htmlFor="ha-url">Home Assistant server address</label><input id="ha-url" type="url" value={haURL} onChange={(event) => { setHAURL(event.target.value); setHACheck(null); }} /></div><div className="field"><label htmlFor="ha-token">{ha.token_configured ? "Replacement access token" : "Long-lived access token"}</label><input id="ha-token" type="password" value={haToken} onChange={(event) => { setHAToken(event.target.value); setHACheck(null); }} autoComplete="off" /><small>The token is submitted to your HausKlar server and never returned to this browser.</small></div>{haCheck ? <div className={`connection-check ${haCheck.success ? "is-success" : "is-error"}`}><span><strong>{haCheck.success ? "Connection works" : "Connection failed"}</strong><small>{haCheck.message}</small></span></div> : null}<div className="connection-actions"><button type="button" className="button button--secondary" disabled={haBusy || !haURL || (!ha.token_configured && !haToken)} onClick={() => void testHA()}>{haBusy ? "Checking…" : "Check connection"}</button><button type="button" className="button button--primary" disabled={haBusy || !haCheck?.success} onClick={() => void saveHA()}>Save connection</button></div></div></details></div></>}</section> : null}

      {category === "privacy" && !user.must_change_password ? <section className="account-section ai-settings-section"><div className="account-section-heading"><BrainCircuit aria-hidden="true" size={22} /><div><h2>Privacy & AI</h2><p>Nothing changes without an explicit choice</p></div></div>{aiConsent.loading ? <div className="reminder-skeleton"><span /><span /></div> : null}{!aiConsent.loading && !aiConsent.status ? <div className="form-error" role="alert">{aiConsent.error ?? "AI privacy settings could not be loaded."}</div> : null}{aiConsent.status ? <div className="ai-settings-content"><div className={aiConsent.status.consented ? "ai-status is-enabled" : "ai-status"}><ShieldCheck size={17} /><strong>{aiConsent.status.consented ? "Permission granted" : "Permission not granted"}</strong></div><p>{aiConsent.status.disclosure}</p><p>HausKlar does not run unattended or nightly AI processing. Shared family and health records are sent only after an authenticated adult explicitly uses an AI feature.</p><a href="/privacy-policy" target="_blank" rel="noreferrer">Read the privacy policy</a>{aiConsent.status.consented ? <button type="button" className="button button--secondary" disabled={aiConsent.busy} onClick={() => void aiConsent.revoke()}>Withdraw AI permission</button> : <button type="button" className="button button--primary" disabled={aiConsent.busy} onClick={() => void aiConsent.grant()}>Allow OpenAI processing</button>}</div> : null}</section> : null}

      {category === "advanced" ? <><UsageHistoryPanel /><section className="account-section"><div className="account-section-heading"><KeyRound aria-hidden="true" size={22} /><div><h2>Change password</h2><p>Security changes always require your current password</p></div></div><form className="password-form" onSubmit={changePassword}>{error ? <div className="form-error" role="alert">{error}</div> : null}{success ? <div className="form-success" role="status">{success}</div> : null}<div className="field"><label htmlFor="account-current-password">Current password</label><input id="account-current-password" type={inputType} autoComplete="current-password" value={currentPassword} onChange={(event) => setCurrentPassword(event.target.value)} required /></div><div className="field"><label htmlFor="account-new-password">New password</label><input id="account-new-password" type={inputType} autoComplete="new-password" minLength={12} maxLength={128} value={newPassword} onChange={(event) => setNewPassword(event.target.value)} required /></div><div className="field"><label htmlFor="account-confirm-password">Confirm new password</label><input id="account-confirm-password" type={inputType} autoComplete="new-password" minLength={12} maxLength={128} value={confirmation} onChange={(event) => setConfirmation(event.target.value)} required /></div><label className="check-row"><input type="checkbox" checked={showPasswords} onChange={(event) => setShowPasswords(event.target.checked)} /><span>Show passwords</span></label><button type="submit" className="button button--primary" disabled={submitting}><KeyRound size={17} />{submitting ? "Changing…" : "Change password"}</button></form></section><section className="account-section account-section--signout"><div><h2>Session</h2><p>Sign out on this browser.</p></div><button type="button" className="button button--secondary" onClick={onSignOut}><LogOut size={17} /> Sign out</button></section><section className="account-section account-section--danger"><div><h2>Delete account</h2><p>Your account and private data are removed. Shared household records remain anonymously for other members.</p>{deleteError ? <div className="form-error" role="alert">{deleteError}</div> : null}</div><button type="button" className="button button--danger" disabled={deletingAccount} onClick={() => setShowDeleteAccount(true)}><Trash2 size={17} /> Delete account</button></section></> : null}
    </div>

    <ConfirmDialog open={confirmPrivacyMode !== null} onOpenChange={(open) => { if (!open) setConfirmPrivacyMode(null); }} title={confirmPrivacyMode ? "Hide family details on the lock screen?" : "Show family details on the lock screen?"} description={confirmPrivacyMode ? "Notifications will use neutral wording until HausKlar opens." : "Event and task names may be visible to anyone who can see this device’s lock screen."} confirmLabel={confirmPrivacyMode ? "Use private wording" : "Show details"} onConfirm={() => { if (confirmPrivacyMode !== null) void persistReminders({ ...reminders, privacy_mode: confirmPrivacyMode }, "Privacy choice saved."); setConfirmPrivacyMode(null); }} />
    <ConfirmDialog open={pendingConfirmation !== null} onOpenChange={(open) => { if (!open && !calendarBusy) setPendingConfirmation(null); }} title={pendingConfirmation?.kind === "remove" ? `Remove ${pendingConfirmation.sourceName}?` : "Replace subscription link?"} description={pendingConfirmation?.kind === "remove" ? "This removes the calendar connection and its imported events from HausKlar." : "The current private link will stop working in Apple, Google and Outlook."} confirmLabel={pendingConfirmation?.kind === "remove" ? "Remove calendar" : "Replace link"} destructive={pendingConfirmation?.kind === "remove"} busy={calendarBusy} onConfirm={() => { if (pendingConfirmation?.kind === "remove") void removeSource(pendingConfirmation.sourceId); if (pendingConfirmation?.kind === "rotate") void rotateFeed(); }} />
    <ConfirmDialog open={showDeleteAccount} onOpenChange={(open) => { if (!deletingAccount) setShowDeleteAccount(open); }} title="Permanently delete your account?" description="This cannot be undone. Your account, private settings and identity links are deleted immediately. Shared household records remain anonymously for other members. The final account also deletes all live family records and files. Isolated encrypted backups follow the retention policy described in Privacy." confirmLabel="Delete permanently" destructive busy={deletingAccount} onConfirm={() => void deleteAccount()} />
  </div>;
}
