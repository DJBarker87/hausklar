import {
  CalendarClock,
  CalendarDays,
  CircleUserRound,
  Dumbbell,
  Ellipsis,
  House,
  ListChecks,
  LogOut,
  Moon,
  Search,
  Settings,
  Sun,
  UsersRound,
  WalletCards,
} from "lucide-react";
import { lazy, Suspense, useCallback, useEffect, useRef, useState } from "react";

import { api, flushOfflineQueue, offlineQueueSummary } from "./api";
import { useAuth } from "./AuthContext";
import { ActionRail } from "./components/ActionRail";
import { PersonAvatar } from "./components/PersonAvatar";
import { RouteErrorBoundary } from "./components/RouteErrorBoundary";
import type { AddHubDestination } from "./components/AddHub";
import { IconButton, Modal, SkeletonList, cn } from "./components/ui";
import { LoginScreen } from "./LoginScreen";
import type { FitnessCoachProposalDestination, FitnessWorkspacePreference } from "./fitness/contract";
import {
  heldQueuedMutations,
  queuedMutations,
  removeQueuedMutation,
  type QueuedMutation,
} from "./offlineQueue";
import type { AssistantActionKind, FamilyMember, OnboardingStatus, ShareDraft, User } from "./types";
import {
  recordUsageControl,
  recordUsageScreen,
  setUsageMonitoringIdentity,
} from "./usageMonitor";
import type { FamilyArea } from "./views/FamilyView";
import type { FinanceScope, FinanceSection } from "./views/FinanceView";
import type { FitnessSection } from "./views/fitness/FitnessModuleView";
import type { ListsArea } from "./views/ListsView";
import type { FitnessTodayAction, FitnessTodaySession } from "./views/TodayView";

const AccountView = lazy(() => import("./views/AccountView").then((module) => ({ default: module.AccountView })));
const AddHub = lazy(() => import("./components/AddHub").then((module) => ({ default: module.AddHub })));
const BismarckChat = lazy(() => import("./components/BismarckChat").then((module) => ({ default: module.BismarckChat })));
const CaptureDialog = lazy(() => import("./components/CaptureDialog").then((module) => ({ default: module.CaptureDialog })));
const CommitmentsHub = lazy(() => import("./components/CommitmentsHub").then((module) => ({ default: module.CommitmentsHub })));
const DocumentsView = lazy(() => import("./views/DocumentsView").then((module) => ({ default: module.DocumentsView })));
const FamilyView = lazy(() => import("./views/FamilyView").then((module) => ({ default: module.FamilyView })));
const FinanceView = lazy(() => import("./views/FinanceView").then((module) => ({ default: module.FinanceView })));
const FitnessModuleView = lazy(() => import("./views/fitness/FitnessModuleView").then((module) => ({ default: module.FitnessModuleView })));
const GlobalSearch = lazy(() => import("./components/GlobalSearch").then((module) => ({ default: module.GlobalSearch })));
const OnboardingGuide = lazy(() => import("./components/OnboardingGuide").then((module) => ({ default: module.OnboardingGuide })));
const HomeView = lazy(() => import("./views/HomeView").then((module) => ({ default: module.HomeView })));
const ListsView = lazy(() => import("./views/ListsView").then((module) => ({ default: module.ListsView })));
const PlannerView = lazy(() => import("./views/PlannerView").then((module) => ({ default: module.PlannerView })));
const QuickAddDialog = lazy(() => import("./components/QuickAddDialog").then((module) => ({ default: module.QuickAddDialog })));
const ShoppingItemDialog = lazy(() => import("./components/ShoppingItemDialog").then((module) => ({ default: module.ShoppingItemDialog })));
const TodayView = lazy(() => import("./views/TodayView").then((module) => ({ default: module.TodayView })));

export type ViewName = "today" | "calendar" | "fitness" | "family" | "lists" | "home" | "finance";
type FamilyRoute = FamilyArea | "documents";
type Appearance = "system" | "light" | "dark";

type FitnessCoachDestinationLocation = {
  view: ViewName;
  section?: string;
  focus: Record<string, string>;
  mealsTab?: "meals" | "tesco";
};

const fitnessCoachDestinationLocations: Record<
  FitnessCoachProposalDestination["kind"],
  (target: string) => FitnessCoachDestinationLocation
> = {
  planned_session: (target) => ({ view: "fitness", section: "training", focus: { session: target } }),
  nutrition_target: (target) => ({ view: "fitness", section: "nutrition", focus: { "fitness-nutrition-target": target } }),
  meal_template: (target) => ({ view: "fitness", section: "nutrition", focus: { "fitness-meal-template": target } }),
  goal: (target) => ({ view: "fitness", section: "training", focus: { "fitness-plan-manage": "goals", "fitness-goal": target } }),
  analysis_chart: (target) => ({ view: "fitness", section: "explore", focus: { "fitness-analysis-chart": target } }),
  calendar_event: (target) => ({ view: "calendar", focus: { event: target } }),
  food_log: (target) => ({ view: "fitness", section: "nutrition", focus: { "fitness-food-log": target } }),
  shopping: (target) => ({ view: "lists", section: "meals", focus: { shopping: target }, mealsTab: "tesco" }),
  task: (target) => ({ view: "lists", section: "tasks", focus: { task: target, task_status: "active" } }),
  fitness_reminder: (target) => ({ view: "fitness", section: "coach", focus: { "fitness-personalise": "reminders", "fitness-reminder": target } }),
};

export function fitnessCoachDestinationLocation(destination: FitnessCoachProposalDestination): FitnessCoachDestinationLocation | null {
  if (!destination.target.trim()) return null;
  const factory = (fitnessCoachDestinationLocations as Partial<Record<string, (target: string) => FitnessCoachDestinationLocation>>)[destination.kind];
  return factory ? factory(destination.target) : null;
}

function initialAppearance(): Appearance {
  const stored = localStorage.getItem("hausklar-theme");
  return stored === "light" || stored === "dark" || stored === "system" ? stored : "system";
}

function canonicalFitnessSection(section: string | null): FitnessSection {
  if (section === "today" || section === "more") return "today";
  if (section === "review") return "progress";
  if (section === "nutrition" || section === "log") return "nutrition";
  if (["training", "plan", "runPlans", "run-plans", "run_plans"].includes(section ?? "")) return "training";
  if (section === "strength") return "strength";
  if (section === "activity") return "activity";
  if (["progress", "measurements", "photos"].includes(section ?? "")) return "progress";
  if (section === "recovery") return "recovery";
  if (section === "explore" || section === "analysis") return "explore";
  if (section === "coach") return "coach";
  return "progress";
}

function canonicalFinanceSection(section: string | null, query: URLSearchParams): FinanceSection {
  if (["purchase", "line", "evidence"].some((parameter) => query.has(parameter))) return "more";
  if (["commitments", "goals", "plan", "proposals", "habits"].includes(section ?? "")) return "goals";
  if (section === "transactions") return "activity";
  if (["purchases", "items", "grocery", "purchase-inbox", "review", "capture"].includes(section ?? "")) return "more";
  if (section === "opportunities") return "explore";
  if (section === "agent") return "coach";
  if (section === "accounts") return query.has("asset") || query.has("product") || query.has("holding") ? "assets" : "setup";
  const current: FinanceSection[] = ["overview", "goals", "activity", "more", "planning", "coach", "explore", "assets", "settings", "setup"];
  return current.includes(section as FinanceSection) ? section as FinanceSection : "overview";
}

const financeFocusParameters = [
  "action",
  "analysis",
  "commitment",
  "evidence",
  "line",
  "purchase",
  "renewal",
  "transaction",
];

function normaliseFinanceLocation() {
  const url = new URL(window.location.href);
  if (url.searchParams.get("view") !== "finance") return;
  if (url.searchParams.has("renewal")) {
    url.searchParams.set("view", "lists");
    url.searchParams.set("section", "renewals");
    url.searchParams.delete("scope");
    window.history.replaceState({}, "", url);
    return;
  }
  const requested = url.searchParams.get("section");
  const canonical = canonicalFinanceSection(requested, url.searchParams);
  if (requested === canonical) return;
  url.searchParams.set("section", canonical);
  window.history.replaceState({}, "", url);
}

const navItems: Array<{ id: ViewName; label: string; icon: typeof CalendarDays }> = [
  { id: "today", label: "Today", icon: CalendarClock },
  { id: "calendar", label: "Calendar", icon: CalendarDays },
  { id: "fitness", label: "Fitness", icon: Dumbbell },
  { id: "family", label: "Family", icon: UsersRound },
  { id: "lists", label: "Lists", icon: ListChecks },
  { id: "home", label: "House", icon: House },
];

function fitnessWorkspaceStorageKey(user: User): string {
  return `hausklar:fitness-workspace:${user.family_id ?? "family"}:${user.id}`;
}

function cachedFitnessWorkspace(user: User): FitnessWorkspacePreference | null {
  try {
    const value = JSON.parse(localStorage.getItem(fitnessWorkspaceStorageKey(user)) ?? "null") as Partial<FitnessWorkspacePreference> | null;
    return typeof value?.enabled === "boolean" && typeof value?.pinned === "boolean"
      ? {
          enabled: value.enabled,
          pinned: value.pinned,
          show_nutrition_today: value.show_nutrition_today === true,
        }
      : null;
  } catch {
    return null;
  }
}

function rememberFinanceEntryScope(user: User, scope: FinanceScope) {
  try {
    window.localStorage.setItem(
      `hausklar:finance:${user.family_id ?? "family"}:${user.id}:scope`,
      scope,
    );
  } catch {
    // Private browsing or a locked-down browser can disable local storage.
  }
}

function FitnessWorkspaceWelcome({ busy, onEnable }: { busy: boolean; onEnable: () => void }) {
  return (
    <section className="account-page" aria-labelledby="fitness-welcome-title">
      <header className="page-header">
        <div><p className="page-eyebrow">Private to your account</p><h1 id="fitness-welcome-title">Fitness, when you want it</h1></div>
      </header>
      <div className="account-layout">
        <section className="account-section">
          <div className="account-section-heading"><Dumbbell aria-hidden="true" size={22} /><div><h2>Your personal workspace</h2><p>Plan realistic movement and keep your own health records in one place.</p></div></div>
          <p>Fitness stays out of the family navigation and Today screen until you enable it. Other family members cannot see your records.</p>
          <button type="button" className="button button--primary" disabled={busy} aria-busy={busy} onClick={onEnable}><Dumbbell aria-hidden="true" size={17} /> {busy ? "Enabling…" : "Enable and pin Fitness"}</button>
        </section>
      </div>
    </section>
  );
}

export function readLocation(): {
  view: ViewName;
  family: FamilyRoute;
  lists: ListsArea;
  fitness: FitnessSection;
  finance: FinanceSection;
  financeScope: FinanceScope;
  settings: boolean;
} {
  const query = new URLSearchParams(window.location.search);
  const requested = query.get("view");
  const section = query.get("section");
  const defaults = { finance: "overview" as const, financeScope: "mine" as const, fitness: "progress" as const };
  if (requested === "finance" && query.has("renewal")) {
    return { view: "lists", family: "overview", lists: "renewals", ...defaults, settings: false };
  }
  if (requested === "planner") return { view: "calendar", family: "overview", lists: "hub", ...defaults, settings: false };
  if (requested === "tasks") return { view: "lists", family: "overview", lists: "tasks", ...defaults, settings: false };
  if (requested === "documents") return { view: "family", family: "documents", lists: "hub", ...defaults, settings: false };
  if (requested === "account") return { view: "today", family: "overview", lists: "hub", ...defaults, settings: true };
  const view: ViewName = requested === "calendar" || requested === "fitness" || requested === "family" || requested === "lists" || requested === "home" || requested === "finance" ? requested : "today";
  const familyValues: FamilyRoute[] = ["overview", "stars", "sleep", "medicine", "illness", "learning", "growth", "presents", "birthdays", "dog", "artwork", "photos", "yearbook", "health", "caregiver", "documents"];
  const listValues: ListsArea[] = ["hub", "tasks", "meals", "routines", "renewals", "prep"];
  return {
    view,
    family: familyValues.includes(section as FamilyRoute) ? section as FamilyRoute : "overview",
    lists: listValues.includes(section as ListsArea) ? section as ListsArea : "hub",
    fitness: canonicalFitnessSection(section),
    finance: canonicalFinanceSection(section, query),
    financeScope: query.get("scope") === "household" ? "household" : "mine",
    settings: false,
  };
}

export default function App() {
  const { user, loading, signOut, updateUser } = useAuth();

  if (loading) return <main className="app-loading" aria-label="Loading HausKlar"><img src="/icons/hausklar-192.png" width="72" height="72" alt="" /><div className="loading-bar" /></main>;
  if (!user) return <LoginScreen />;
  if (user.must_change_password) return <div className="forced-account-shell"><header className="forced-account-brand"><img src="/icons/hausklar-192.png" width="40" height="40" alt="" /><strong>HausKlar</strong></header><main><Suspense fallback={<SkeletonList rows={4} />}><AccountView user={user} onUserUpdated={updateUser} onSignOut={() => void signOut()} /></Suspense></main></div>;

  const identity = `${user.family_id ?? "no-family"}:${user.id}`;
  return (
    <AuthenticatedApp
      key={identity}
      user={user}
      signOut={signOut}
      updateUser={updateUser}
    />
  );
}

function AuthenticatedApp({
  user,
  signOut,
  updateUser,
}: {
  user: User;
  signOut: () => Promise<void>;
  updateUser: (user: User) => void;
}) {
  const financeAvailable = Boolean(user.family_id);
  const initial = useRef(readLocation()).current;
  const [view, setView] = useState<ViewName>(initial.view);
  const [familyRoute, setFamilyRoute] = useState<FamilyRoute>(initial.family);
  const [familyChildID, setFamilyChildID] = useState<string | null>(() => new URLSearchParams(window.location.search).get("child"));
  const [listsRoute, setListsRoute] = useState<ListsArea>(initial.lists);
  const [fitnessSection, setFitnessSection] = useState<FitnessSection>(initial.fitness);
  const [financeSection, setFinanceSection] = useState<FinanceSection>(initial.finance);
  const [financeScope, setFinanceScope] = useState<FinanceScope>(initial.financeScope);
  const [showSettings, setShowSettings] = useState(initial.settings);
  const [mobileMoreOpen, setMobileMoreOpen] = useState(false);
  const [members, setMembers] = useState<FamilyMember[]>([]);
  const [revision, setRevision] = useState(0);
  const [quickAdd, setQuickAdd] = useState<{ open: boolean; kind: "event" | "task" }>({ open: false, kind: "event" });
  const [capture, setCapture] = useState<{ open: boolean; mode: "plan" | "document"; initialText?: string }>({ open: false, mode: "plan" });
  const [addHubOpen, setAddHubOpen] = useState(false);
  const [commitmentsHub, setCommitmentsHub] = useState<{ open: boolean; commitmentID?: string; create?: boolean }>({ open: false });
  const [bismarckOpen, setBismarckOpen] = useState(false);
  const [shoppingOpen, setShoppingOpen] = useState(false);
  const [initialMealsTab, setInitialMealsTab] = useState<"meals" | "tesco">("meals");
  const [familyRequestedAction, setFamilyRequestedAction] = useState<{ kind: "medicine"; nonce: number } | null>(null);
  const [bismarckDraft, setBismarckDraft] = useState<{ text: string; nonce: number } | null>(null);
  const [fitnessCoachDraft, setFitnessCoachDraft] = useState<{ text: string; nonce: number; contextIds?: string[] } | null>(null);
  const [globalSearchOpen, setGlobalSearchOpen] = useState(false);
  const [searchNavigationNonce, setSearchNavigationNonce] = useState(0);
  const [fitnessSetupOpen, setFitnessSetupOpen] = useState(false);
  const [fitnessWorkspace, setFitnessWorkspace] = useState<FitnessWorkspacePreference | null>(() => cachedFitnessWorkspace(user));
  const [fitnessWorkspaceBusy, setFitnessWorkspaceBusy] = useState(false);
  const [onboarding, setOnboarding] = useState<OnboardingStatus | null>(null);
  const claimedShare = useRef<string | null>(null);
  const [toast, setToast] = useState<string | null>(null);
  const [online, setOnline] = useState(navigator.onLine);
  const [queueSummary, setQueueSummary] = useState({ pending: 0, failed: 0, held: 0 });
  const [queueReviewOpen, setQueueReviewOpen] = useState(false);
  const [queuedChanges, setQueuedChanges] = useState<QueuedMutation[]>([]);
  const [heldChanges, setHeldChanges] = useState<QueuedMutation[]>([]);
  const [appearance, setAppearance] = useState<Appearance>(initialAppearance);
  const [systemDark, setSystemDark] = useState(() => window.matchMedia?.("(prefers-color-scheme: dark)").matches ?? false);
  const addTrigger = useRef<HTMLButtonElement | null>(null);
  const captureTrigger = useRef<HTMLButtonElement | null>(null);
  const bismarckTrigger = useRef<HTMLButtonElement | null>(null);

  useEffect(() => {
    setUsageMonitoringIdentity(`${user.family_id ?? "no-family"}:${user.id}`);
    return () => setUsageMonitoringIdentity(null);
  }, [user.family_id, user.id]);

  useEffect(() => { recordUsageScreen(view); }, [view]);

  useEffect(() => {
    normaliseFinanceLocation();
  }, []);

  useEffect(() => {
    if (!navigator.onLine) return;
    let active = true;
    void api<OnboardingStatus>("/auth/onboarding", {}, true, false)
      .then((loaded) => { if (active) setOnboarding(loaded); })
      .catch(() => undefined);
    return () => { active = false; };
  }, [user.id]);

  useEffect(() => {
    let active = true;
    void api<FitnessWorkspacePreference>("/fitness/workspace", {}, true, false)
      .then((preference) => {
        if (!active) return;
        setFitnessWorkspace(preference);
        localStorage.setItem(fitnessWorkspaceStorageKey(user), JSON.stringify(preference));
      })
      .catch(() => {
        if (!active) return;
        setFitnessWorkspace((current) => current ?? { enabled: false, pinned: false });
      });
    return () => { active = false; };
  }, [user]);

  const dark = appearance === "dark" || appearance === "system" && systemDark;

  useEffect(() => {
    const query = window.matchMedia?.("(prefers-color-scheme: dark)");
    if (!query) return;
    const updateSystemAppearance = () => setSystemDark(query.matches);
    updateSystemAppearance();
    query.addEventListener?.("change", updateSystemAppearance);
    return () => query.removeEventListener?.("change", updateSystemAppearance);
  }, []);

  useEffect(() => {
    document.documentElement.dataset.theme = dark ? "dark" : "light";
    localStorage.setItem("hausklar-theme", appearance);
  }, [appearance, dark]);

  useEffect(() => {
    const refreshQueue = () => {
      void offlineQueueSummary().then(setQueueSummary).catch(() => undefined);
    };
    const update = () => {
      setOnline(navigator.onLine);
      if (navigator.onLine) void flushOfflineQueue();
      refreshQueue();
    };
    const queueChanged = (event: Event) => {
      const detail = (event as CustomEvent<{ queued?: boolean; synced?: number }>).detail;
      refreshQueue();
      if (detail?.queued) setToast("Saved offline. HausKlar will sync this change when you reconnect.");
      if (detail?.synced) {
        setToast(`${detail.synced} offline ${detail.synced === 1 ? "change" : "changes"} synced.`);
        setRevision((value) => value + 1);
      }
    };
    window.addEventListener("online", update);
    window.addEventListener("offline", update);
    window.addEventListener("hausklar:queue-changed", queueChanged);
    refreshQueue();
    return () => {
      window.removeEventListener("online", update);
      window.removeEventListener("offline", update);
      window.removeEventListener("hausklar:queue-changed", queueChanged);
    };
  }, []);

  useEffect(() => {
    if (!user) return;
    api<FamilyMember[]>("/family/members").then(setMembers).catch(() => setToast("Family members couldn't be loaded."));
    if (navigator.onLine) void flushOfflineQueue();
  }, [user]);

  useEffect(() => {
    const restore = () => {
      const location = readLocation();
      setView(location.view);
      setFamilyRoute(location.family);
      setFamilyChildID(new URLSearchParams(window.location.search).get("child"));
      setListsRoute(location.lists);
      setFitnessSection(location.fitness);
      setFinanceSection(location.finance);
      setFinanceScope(location.financeScope);
      setShowSettings(location.settings);
      normaliseFinanceLocation();
      scrollToTop();
    };
    window.addEventListener("popstate", restore);
    return () => window.removeEventListener("popstate", restore);
  }, []);

  useEffect(() => {
    if (view !== "finance" && view !== "fitness") return;
    setAddHubOpen(false);
    setBismarckOpen(false);
  }, [view]);

  useEffect(() => {
    if (!user) return;
    const url = new URL(window.location.href);
    const identifier = url.searchParams.get("share");
    if (!identifier || claimedShare.current === identifier) return;
    claimedShare.current = identifier;
    api<ShareDraft>(`/coordination/shares/${identifier}`).then((draft) => {
      url.searchParams.delete("share");
      window.history.replaceState({}, "", url);
      setCapture({ open: true, mode: "plan", initialText: draft.text });
    }).catch((requestError) => {
      setToast(requestError instanceof Error ? requestError.message : "That shared item could not be opened.");
    });
  }, [user]);

  useEffect(() => {
    if (!toast) return;
    const timeout = window.setTimeout(() => setToast(null), 3500);
    return () => window.clearTimeout(timeout);
  }, [toast]);

  function writeLocation(
    nextView: ViewName,
    section?: string,
    mode: "push" | "replace" = "push",
    nextFinanceScope: FinanceScope = financeScope,
  ) {
    const url = new URL(window.location.href);
    url.searchParams.set("view", nextView);
    const defaultSection = section === "hub" || section === "today"
      || (section === "overview" && nextView !== "finance");
    if (section && !defaultSection) url.searchParams.set("section", section);
    else url.searchParams.delete("section");
    if (nextView === "finance" && nextFinanceScope === "household") url.searchParams.set("scope", "household");
    else url.searchParams.delete("scope");
    if (nextView === "family" && familyChildID) url.searchParams.set("child", familyChildID);
    else if (nextView !== "family") url.searchParams.delete("child");
    if (nextView !== "family" || section !== "presents") url.searchParams.delete("birthday");
    if (nextView !== "family" || section !== "presents") url.searchParams.delete("present");
    url.searchParams.delete("homework");
    financeFocusParameters.forEach((parameter) => url.searchParams.delete(parameter));
    if (nextView !== "fitness" || section !== "activity") url.searchParams.delete("activity");
    if (nextView !== "fitness" || section !== "training") url.searchParams.delete("session");
    if (nextView !== "fitness" || section !== "recovery") url.searchParams.delete("cycle");
    if (nextView !== "fitness" || section !== "strength") {
      url.searchParams.delete("fitness-strength-start");
      url.searchParams.delete("fitness-strength-plan");
    }
    if (url.href === window.location.href) return;
    window.history[mode === "push" ? "pushState" : "replaceState"]({}, "", url);
  }

  function scrollToTop() {
    const reducedMotion = window.matchMedia?.("(prefers-reduced-motion: reduce)").matches ?? false;
    window.scrollTo({ top: 0, behavior: reducedMotion ? "auto" : "smooth" });
  }

  function changeView(next: ViewName) {
    setView(next);
    if (next === "family") setFamilyRoute("overview");
    if (next === "lists") setListsRoute("hub");
    if (next === "fitness") setFitnessSection("progress");
    if (next === "finance") setFinanceSection("overview");
    writeLocation(next, next === "finance" ? "overview" : undefined);
    scrollToTop();
  }

  async function updateFitnessWorkspace(patch: Partial<FitnessWorkspacePreference>) {
    setFitnessWorkspaceBusy(true);
    try {
      const preference = await api<FitnessWorkspacePreference>(
        "/fitness/workspace",
        { method: "PATCH", body: JSON.stringify(patch) },
        true,
        false,
      );
      setFitnessWorkspace(preference);
      localStorage.setItem(fitnessWorkspaceStorageKey(user), JSON.stringify(preference));
      if (!preference.enabled && view === "fitness") changeView("today");
    } finally {
      setFitnessWorkspaceBusy(false);
    }
  }

  function openSearchResult(path: string) {
    if (!path.startsWith("?")) {
      setToast("That search result cannot be opened.");
      return;
    }
    const url = new URL(window.location.href);
    url.search = path.slice(1);
    window.history.pushState({}, "", url);
    const location = readLocation();
    setView(location.view);
    setFamilyRoute(location.family);
    setFamilyChildID(url.searchParams.get("child"));
    setListsRoute(location.lists);
    setFitnessSection(location.fitness);
    setFinanceSection(location.finance);
    setFinanceScope(location.financeScope);
    setShowSettings(false);
    setGlobalSearchOpen(false);
    setSearchNavigationNonce((value) => value + 1);
    scrollToTop();
  }

  function openFamily(route: FamilyRoute) {
    setView("family"); setFamilyRoute(route); writeLocation("family", route);
    scrollToTop();
  }

  function openHomework(childID: string, homeworkID: string) {
    setFamilyChildID(childID);
    setView("family");
    setFamilyRoute("learning");
    const url = new URL(window.location.href);
    url.searchParams.set("view", "family");
    url.searchParams.set("section", "learning");
    url.searchParams.set("child", childID);
    url.searchParams.set("homework", homeworkID);
    window.history.pushState({}, "", url);
    scrollToTop();
  }

  function openPresent(childID: string, presentID: string) {
    setFamilyChildID(childID);
    setView("family");
    setFamilyRoute("presents");
    const url = new URL(window.location.href);
    url.searchParams.set("view", "family");
    url.searchParams.set("section", "presents");
    url.searchParams.set("child", childID);
    url.searchParams.set("present", presentID);
    ["task", "task_status", "event", "event_date", "birthday", "homework", "scope"]
      .forEach((parameter) => url.searchParams.delete(parameter));
    financeFocusParameters.forEach((parameter) => url.searchParams.delete(parameter));
    window.history.pushState({}, "", url);
    scrollToTop();
  }

  function openFamilyDocuments(childId?: string) {
    const nextChildID = childId ?? null;
    setFamilyChildID(nextChildID);
    setView("family");
    setFamilyRoute("documents");
    const url = new URL(window.location.href);
    url.searchParams.set("view", "family");
    url.searchParams.set("section", "documents");
    if (nextChildID) url.searchParams.set("child", nextChildID);
    else url.searchParams.delete("child");
    window.history.pushState({}, "", url);
    scrollToTop();
  }

  function openLists(route: ListsArea) {
    setView("lists"); setListsRoute(route); writeLocation("lists", route);
    scrollToTop();
  }

  function openBirthdayTask(taskId: string) {
    setView("lists");
    setListsRoute("tasks");
    const url = new URL(window.location.href);
    url.searchParams.set("view", "lists");
    url.searchParams.set("section", "tasks");
    url.searchParams.set("task", taskId);
    ["event", "event_date", "birthday", "child", "homework", "scope"].forEach((parameter) => url.searchParams.delete(parameter));
    financeFocusParameters.forEach((parameter) => url.searchParams.delete(parameter));
    window.history.pushState({}, "", url);
    scrollToTop();
  }

  function openBirthdayEvent(eventId: string, date: string) {
    setView("calendar");
    const url = new URL(window.location.href);
    url.searchParams.set("view", "calendar");
    url.searchParams.delete("section");
    url.searchParams.set("event", eventId);
    url.searchParams.set("event_date", date);
    ["task", "task_status", "birthday", "child", "homework", "scope"].forEach((parameter) => url.searchParams.delete(parameter));
    financeFocusParameters.forEach((parameter) => url.searchParams.delete(parameter));
    window.history.pushState({}, "", url);
    scrollToTop();
  }

  function openBirthdayPresents(birthdayId: string) {
    setView("family");
    setFamilyRoute("presents");
    setFamilyChildID(null);
    const url = new URL(window.location.href);
    url.searchParams.set("view", "family");
    url.searchParams.set("section", "presents");
    url.searchParams.set("birthday", birthdayId);
    ["task", "task_status", "event", "event_date", "present", "child", "homework", "scope"].forEach((parameter) => url.searchParams.delete(parameter));
    financeFocusParameters.forEach((parameter) => url.searchParams.delete(parameter));
    window.history.pushState({}, "", url);
    scrollToTop();
  }

  function changeFitnessSection(nextSection: FitnessSection) {
    setFitnessSection(nextSection);
    writeLocation("fitness", nextSection, "replace");
    scrollToTop();
  }

  function openFitnessCycles() {
    setView("fitness");
    setFitnessSection("recovery");
    const url = new URL(window.location.href);
    url.searchParams.set("view", "fitness");
    url.searchParams.set("section", "recovery");
    url.searchParams.set("cycle", "1");
    url.searchParams.delete("event_date");
    window.history.pushState({}, "", url);
    scrollToTop();
  }

  function openFitnessTodayAction(action: FitnessTodayAction, session?: FitnessTodaySession) {
    if (action.kind === "log_food") {
      setView("fitness");
      setFitnessSection("nutrition");
      writeLocation("fitness", "nutrition");
      scrollToTop();
      return;
    }
    if (action.kind === "start_strength") {
      const url = new URL(window.location.href);
      ["activity", "session", "fitness-strength-plan", "cycle", "event", "event_date"].forEach((parameter) => url.searchParams.delete(parameter));
      financeFocusParameters.forEach((parameter) => url.searchParams.delete(parameter));
      url.searchParams.delete("scope");
      url.searchParams.set("view", "fitness");
      url.searchParams.set("section", "strength");
      url.searchParams.set("fitness-strength-start", "blank");
      setView("fitness");
      setFitnessSection("strength");
      window.history.pushState({}, "", url);
      scrollToTop();
      return;
    }
    if (!session) return;
    const targetID = action.target_id ?? session.id;
    let nextSection: FitnessSection = "training";
    const url = new URL(window.location.href);
    ["activity", "session", "fitness-strength-start", "fitness-strength-plan", "cycle", "event", "event_date"].forEach((parameter) => url.searchParams.delete(parameter));
    financeFocusParameters.forEach((parameter) => url.searchParams.delete(parameter));
    url.searchParams.delete("scope");

    if (action.kind === "resume_activity") {
      nextSection = session.sport_key === "strength" ? "strength" : "activity";
      url.searchParams.set("activity", targetID);
    } else if (action.kind === "start_session" && session.sport_key === "strength") {
      nextSection = "strength";
      url.searchParams.set("fitness-strength-start", targetID);
    } else {
      url.searchParams.set("session", targetID);
    }

    setView("fitness");
    setFitnessSection(nextSection);
    url.searchParams.set("view", "fitness");
    url.searchParams.set("section", nextSection);
    window.history.pushState({}, "", url);
    scrollToTop();
  }

  const changed = useCallback(() => { setRevision((value) => value + 1); }, []);

  function memberUpdated(updated: FamilyMember) {
    setMembers((current) => current.map((member) => member.id === updated.id ? updated : member));
    if (user && updated.id === user.id) updateUser({ ...user, avatar_url: updated.avatar_url });
  }

  function changeFamilyChild(childId: string | null) {
    setFamilyChildID(childId);
    const url = new URL(window.location.href);
    if (childId) url.searchParams.set("child", childId);
    else url.searchParams.delete("child");
    url.searchParams.delete("homework");
    url.searchParams.delete("present");
    window.history.replaceState({}, "", url);
  }

  function openAddHub(trigger: HTMLButtonElement) {
    recordUsageControl("open_add", view);
    addTrigger.current = trigger;
    setAddHubOpen(true);
  }

  function openCapture(trigger: HTMLButtonElement) {
    recordUsageControl("open_capture", view);
    captureTrigger.current = trigger;
    setCapture({ open: true, mode: "plan" });
  }

  function openGlobalSearch(_trigger?: HTMLButtonElement) {
    recordUsageControl("open_search", view);
    setGlobalSearchOpen(true);
  }

  function openFitnessLog() {
    recordUsageControl("open_fitness_log", view);
    setView("fitness");
    setFitnessSection("nutrition");
    writeLocation("fitness", "nutrition");
    scrollToTop();
  }

  function openFitnessCoach() {
    recordUsageControl("open_fitness_coach", view);
    setView("fitness");
    setFitnessSection("coach");
    writeLocation("fitness", "coach");
    scrollToTop();
  }

  function openFitnessCoachFromBismarck(draft: string) {
    setBismarckOpen(false);
    setFitnessCoachDraft({ text: draft, nonce: Date.now() });
    openFitnessCoach();
  }

  function openFitnessCoachForActivity(activityId: string, title: string) {
    const activityName = title.trim() ? `“${title.trim()}”` : "this activity";
    setFitnessCoachDraft({
      text: `Review ${activityName} in the context of the activities around it. What went well, what should I learn, and what should I do next?`,
      nonce: Date.now(),
      contextIds: [activityId],
    });
    openFitnessCoach();
  }

  function openFitnessCoachDestination(destination: FitnessCoachProposalDestination) {
    const location = fitnessCoachDestinationLocation(destination);
    if (!location) {
      setToast("That saved item cannot be opened from Coach.");
      return;
    }
    const url = new URL(window.location.href);
    [
      "activity", "session", "fitness-strength-start", "fitness-strength-plan", "cycle",
      "event", "event_date", "fitness-nutrition-target", "fitness-meal-template", "fitness-goal",
      "fitness-plan-manage", "fitness-analysis-chart", "fitness-food-log", "shopping", "task",
      "task_status", "fitness-personalise", "fitness-reminder",
    ].forEach((parameter) => url.searchParams.delete(parameter));
    financeFocusParameters.forEach((parameter) => url.searchParams.delete(parameter));
    url.searchParams.delete("scope");
    url.searchParams.set("view", location.view);
    if (location.section) url.searchParams.set("section", location.section);
    else url.searchParams.delete("section");
    Object.entries(location.focus).forEach(([key, value]) => url.searchParams.set(key, value));

    setView(location.view);
    if (location.view === "fitness") setFitnessSection(canonicalFitnessSection(location.section ?? null));
    if (location.view === "lists") setListsRoute(location.section as ListsArea);
    if (location.mealsTab) setInitialMealsTab(location.mealsTab);
    window.history.pushState({}, "", url);
    scrollToTop();
  }

  function openSettings() {
    const url = new URL(window.location.href);
    url.searchParams.set("view", "account");
    url.searchParams.delete("section");
    window.history.pushState({}, "", url);
    setShowSettings(true);
  }

  function closeSettings(open: boolean) {
    if (open) return;
    setShowSettings(false);
    const url = new URL(window.location.href);
    if (url.searchParams.get("view") === "account") {
      url.searchParams.set("view", view);
      const section = view === "family" ? familyRoute : view === "lists" ? listsRoute : view === "fitness" ? fitnessSection : view === "finance" ? financeSection : null;
      if (section && (view === "finance" || (section !== "overview" && section !== "hub"))) url.searchParams.set("section", section);
      else url.searchParams.delete("section");
      if (view === "finance" && financeScope === "household") url.searchParams.set("scope", "household");
      else url.searchParams.delete("scope");
      window.history.replaceState({}, "", url);
    }
  }

  async function openQueueReview() {
    const [owned, held] = await Promise.all([queuedMutations(), heldQueuedMutations()]);
    setQueuedChanges(owned);
    setHeldChanges(held);
    setQueueReviewOpen(true);
  }

  async function discardQueuedChange(id: string) {
    await removeQueuedMutation(id);
    const [changes, held, summary] = await Promise.all([
      queuedMutations(),
      heldQueuedMutations(),
      offlineQueueSummary(),
    ]);
    setQueuedChanges(changes);
    setHeldChanges(held);
    setQueueSummary(summary);
    if (!changes.some((change) => change.lastError) && !held.length) setQueueReviewOpen(false);
    setToast("Offline change discarded. Recreate it when you’re ready.");
  }

  function queuedChangeLabel(change: QueuedMutation): string {
    let data: Record<string, unknown> = {};
    try {
      data = change.body ? JSON.parse(change.body) as Record<string, unknown> : {};
    } catch {
      // A corrupt queue entry is still reviewable and discardable.
    }
    const isSwimmingBooking = change.path === "/facilities/swimming-bookings";
    const isWeightsBooking = change.path === "/facilities/weights-bookings";
    const kind = change.path === "/calendar/" || isSwimmingBooking
      ? "Event"
      : isWeightsBooking
        ? "Plan"
      : change.path === "/tasks/"
        ? "Task"
        : "Shopping item";
    const label = data.title
      ?? data.name
      ?? (isSwimmingBooking ? "Swimming" : isWeightsBooking ? "Strength" : undefined);
    return typeof label === "string" && label.trim() ? `${kind}: ${label}` : kind;
  }

  function queueBannerMessage(): string {
    if (!online) {
      const waiting = queueSummary.pending
        ? ` ${queueSummary.pending} ${queueSummary.pending === 1 ? "change is" : "changes are"} safely waiting to sync.`
        : " New events, tasks and shopping items will be saved on this device.";
      const held = queueSummary.held
        ? ` ${queueSummary.held} ${queueSummary.held === 1 ? "change is" : "changes are"} held for another account.`
        : "";
      return `HausKlar is offline.${waiting}${held}`;
    }
    if (queueSummary.held) {
      return `${queueSummary.held} offline ${queueSummary.held === 1 ? "change belongs" : "changes belong"} to another or older account and will not sync here.`;
    }
    if (queueSummary.failed) {
      return `${queueSummary.failed} offline ${queueSummary.failed === 1 ? "change needs" : "changes need"} attention.`;
    }
    return `Syncing ${queueSummary.pending} offline ${queueSummary.pending === 1 ? "change" : "changes"}…`;
  }

  function changeAddHubOpen(open: boolean) {
    setAddHubOpen(open);
    if (!open) window.requestAnimationFrame(() => addTrigger.current?.focus());
  }

  function changeBismarckOpen(open: boolean) {
    setBismarckOpen(open);
    if (!open) window.requestAnimationFrame(() => bismarckTrigger.current?.focus());
  }

  function changeCaptureOpen(open: boolean) {
    setCapture((current) => ({ ...current, open, initialText: open ? current.initialText : undefined }));
    if (!open) window.requestAnimationFrame(() => captureTrigger.current?.focus());
  }

  function chooseAddDestination(destination: AddHubDestination) {
    setAddHubOpen(false);
    if (destination === "commitment") {
      setCommitmentsHub({ open: true, create: true });
      return;
    }
    if (destination === "event" || destination === "task") {
      setQuickAdd({ open: true, kind: destination });
      return;
    }
    if (destination === "shopping") {
      setShoppingOpen(true);
      return;
    }
    if (destination === "medicine") {
      setFamilyRequestedAction({ kind: "medicine", nonce: Date.now() });
      openFamily("medicine");
      return;
    }
    if (destination === "nap") {
      openFamily("sleep");
      return;
    }
    captureTrigger.current = addTrigger.current;
    setCapture({ open: true, mode: destination === "document" ? "document" : "plan" });
  }

  function continueCaptureInBismarck(text: string) {
    setCapture((current) => ({ ...current, open: false, initialText: undefined }));
    bismarckTrigger.current = captureTrigger.current ?? addTrigger.current;
    setBismarckDraft({ text, nonce: Date.now() });
    setBismarckOpen(true);
  }

  function viewAssistantResult(kind: AssistantActionKind, resultID?: string | null) {
    if (!resultID) return;
    setBismarckOpen(false);
    const focusResult = (parameter: "event" | "task" | "shopping", status?: string) => {
      const url = new URL(window.location.href);
      ["event", "task", "shopping", "task_status"].forEach((key) => url.searchParams.delete(key));
      url.searchParams.set(parameter, resultID);
      if (status) url.searchParams.set("task_status", status);
      window.history.replaceState({}, "", url);
    };
    if (kind === "calendar_event") {
      changeView("calendar");
      focusResult("event");
    } else if (kind === "create_task" || kind === "complete_task") {
      openLists("tasks");
      focusResult("task", kind === "complete_task" ? "completed" : "active");
    } else if (kind === "shopping_item") {
      setInitialMealsTab("tesco");
      openLists("meals");
      focusResult("shopping");
    }
  }

  function changeFinanceSection(nextSection: FinanceSection) {
    setFinanceSection(nextSection);
    writeLocation("finance", nextSection, "replace");
    scrollToTop();
  }

  function openFinanceAction(actionID: string, nextScope: FinanceScope) {
    setView("finance");
    setFinanceSection("coach");
    setFinanceScope(nextScope);
    const url = new URL(window.location.href);
    financeFocusParameters.forEach((parameter) => url.searchParams.delete(parameter));
    url.searchParams.set("view", "finance");
    url.searchParams.set("section", "coach");
    url.searchParams.set("action", actionID);
    if (nextScope === "household") url.searchParams.set("scope", "household");
    else url.searchParams.delete("scope");
    window.history.pushState({}, "", url);
    scrollToTop();
  }

  function openFinancePurchase(lineID: string, nextScope: FinanceScope) {
    setView("finance");
    setFinanceSection("more");
    setFinanceScope(nextScope);
    const url = new URL(window.location.href);
    financeFocusParameters.forEach((parameter) => url.searchParams.delete(parameter));
    url.searchParams.set("view", "finance");
    url.searchParams.set("section", "more");
    url.searchParams.set("line", lineID);
    if (nextScope === "household") url.searchParams.set("scope", "household");
    else url.searchParams.delete("scope");
    window.history.pushState({}, "", url);
    scrollToTop();
  }

  function changeFinanceScope(nextScope: FinanceScope) {
    setFinanceScope(nextScope);
    writeLocation("finance", financeSection, "replace", nextScope);
    scrollToTop();
  }

  function openPrivateFinanceFromSettings() {
    closeSettings(false);
    rememberFinanceEntryScope(user, "mine");
    setView("finance");
    setFinanceSection("overview");
    setFinanceScope("mine");
    writeLocation("finance", "overview", "push", "mine");
    scrollToTop();
  }

  function chooseMobileMore(nextView: "home" | "finance" | "fitness") {
    setMobileMoreOpen(false);
    changeView(nextView);
  }

  function cycleAppearance() {
    setAppearance((current) => current === "system" ? "light" : current === "light" ? "dark" : "system");
  }

  // Keep the full Finance translation catalogue inside the lazy Finance route.
  // The navigation only needs this single, stable label.
  const financeNavigationCopy = navigator.language.toLowerCase().startsWith("de")
    ? { title: "Finanzen", subtitle: "Salden, Ausgaben und Pläne für das Geld, das du sehen kannst." }
    : { title: "Finance", subtitle: "Balances, spending and plans for the money you can see." };
  const financeNavItem = {
    id: "finance" as const,
    label: financeNavigationCopy.title,
    icon: WalletCards,
  };
  const personalNavItems = navItems.filter((item) => item.id !== "fitness" || fitnessWorkspace?.pinned);
  const primaryNavItems = personalNavItems.filter((item) => item.id !== "home");
  const secondaryNavItems = financeAvailable
    ? [personalNavItems.find((item) => item.id === "home")!, financeNavItem]
    : [personalNavItems.find((item) => item.id === "home")!];
  const visibleNavItems = [...primaryNavItems, ...secondaryNavItems];
  const mobileNavItems = personalNavItems.filter((item) => item.id !== "home");

  return (
    <div className="app-shell">
      <aside className="sidebar">
        <div className="sidebar-brand"><img src="/icons/hausklar-192.png" width="40" height="40" alt="" /><strong>HausKlar</strong></div>
        <button type="button" className="nav-item" onClick={(event) => openGlobalSearch(event.currentTarget)}><Search aria-hidden="true" size={20} /><span>Find anything</span></button>
        <nav className="primary-nav" aria-label="Main navigation">{primaryNavItems.map((item) => { const Icon = item.icon; return <button type="button" className={cn("nav-item", view === item.id && "is-active")} aria-current={view === item.id ? "page" : undefined} onClick={() => changeView(item.id)} key={item.id}><Icon aria-hidden="true" size={20} /><span>{item.label}</span></button>; })}</nav>
        {view !== "finance" && !(view === "fitness" && fitnessSetupOpen) ? <ActionRail placement="sidebar" onCapture={openCapture} onAdd={openAddHub} onSearch={openGlobalSearch} context={view === "fitness" ? "fitness" : "default"} onFitnessLog={openFitnessLog} onFitnessCoach={openFitnessCoach} /> : null}
        <div className="sidebar-spacer" />
        <nav className="primary-nav" aria-label="House and personal workspaces">{secondaryNavItems.map((item) => { const Icon = item.icon; return <button type="button" className={cn("nav-item", view === item.id && "is-active")} aria-current={view === item.id ? "page" : undefined} onClick={() => changeView(item.id)} key={item.id}><Icon aria-hidden="true" size={20} /><span>{item.label}</span></button>; })}</nav>
        <button type="button" className="sidebar-profile" aria-label="Settings and profile" onClick={openSettings}><PersonAvatar member={{ name: user.name, avatar_url: user.avatar_url }} className="user-avatar" /><div><strong>{user.name}</strong><span>{user.email}</span></div><Settings aria-hidden="true" size={18} /></button>
        <div className="sidebar-actions"><IconButton label={`Appearance: ${appearance}. Change appearance`} icon={dark ? Sun : Moon} onClick={cycleAppearance} /><IconButton label="Sign out" icon={LogOut} onClick={() => void signOut()} /></div>
      </aside>

      <header className="mobile-header">
        <div className="mobile-brand"><img src="/icons/hausklar-192.png" width="36" height="36" alt="" /><strong>{visibleNavItems.find((item) => item.id === view)?.label ?? (view === "finance" ? financeNavigationCopy.title : view === "fitness" ? "Fitness" : "HausKlar")}</strong></div>
        <div>
          <IconButton label="Find anything" icon={Search} onClick={() => openGlobalSearch()} />
          <IconButton label="More navigation and appearance" icon={Ellipsis} onClick={() => { recordUsageControl("open_more", view); setMobileMoreOpen(true); }} />
          <IconButton label="Settings and profile" icon={CircleUserRound} onClick={openSettings} />
        </div>
      </header>

      {view !== "fitness" && (!online || queueSummary.pending || queueSummary.held) ? <div className={cn("offline-banner", online && (queueSummary.failed > 0 || queueSummary.held > 0) && "has-error")} role="status">
        <span>{queueBannerMessage()}</span>
        {queueSummary.failed || queueSummary.held ? <button type="button" onClick={() => void openQueueReview()}>Review</button> : null}
      </div> : null}

      <main className="app-content" id="main-content">
        <RouteErrorBoundary key={searchNavigationNonce} resetKey={`${view}:${familyRoute}:${listsRoute}:${fitnessSection}:${financeSection}:${financeScope}:${revision}`}>
        <Suspense fallback={<SkeletonList rows={7} />}>
          {view === "today" ? <TodayView userName={user.name} userID={user.id} members={members} revision={revision} onAddEvent={() => setQuickAdd({ open: true, kind: "event" })} onAddTask={() => setQuickAdd({ open: true, kind: "task" })} onOpenCalendar={() => changeView("calendar")} onOpenFamily={openFamily} onOpenHomework={openHomework} onOpenPresent={openPresent} onOpenLists={openLists} onOpenFinanceAction={openFinanceAction} onOpenFinancePurchase={openFinancePurchase} onOpenFitnessAction={openFitnessTodayAction} onOpenCommitments={(commitmentID) => setCommitmentsHub({ open: true, commitmentID })} onDataChanged={changed} fitnessEnabled={fitnessWorkspace?.enabled ?? false} /> : null}
          {view === "calendar" ? <PlannerView members={members} revision={revision} onAddEvent={() => setQuickAdd({ open: true, kind: "event" })} onOpenCycleTracking={openFitnessCycles} onDataChanged={changed} financeEnabled={financeAvailable} /> : null}
          {view === "family" && familyRoute !== "documents" ? <FamilyView members={members} revision={revision} initialArea={familyRoute} initialChildId={familyChildID} initialHomeworkId={new URLSearchParams(window.location.search).get("homework")} initialReadingId={new URLSearchParams(window.location.search).get("reading")} initialPresentId={new URLSearchParams(window.location.search).get("present")} initialBirthdayId={new URLSearchParams(window.location.search).get("birthday")} initialPhotoId={new URLSearchParams(window.location.search).get("photo")} initialArtworkId={new URLSearchParams(window.location.search).get("artwork")} initialHealthTab={new URLSearchParams(window.location.search).has("vaccination") ? "vaccinations" : undefined} initialVaccinationKey={new URLSearchParams(window.location.search).get("vaccination")} requestedAction={familyRequestedAction} onRequestedActionConsumed={() => setFamilyRequestedAction(null)} onAreaChange={(area) => { setFamilyRoute(area); writeLocation("family", area); }} onChildChange={changeFamilyChild} onOpenDocuments={openFamilyDocuments} onOpenBirthdayTask={openBirthdayTask} onOpenBirthdayEvent={openBirthdayEvent} onOpenBirthdayPresents={openBirthdayPresents} onDataChanged={changed} onMemberUpdated={memberUpdated} /> : null}
          {view === "family" && familyRoute === "documents" ? <div className="nested-view"><button type="button" className="nested-back" onClick={() => openFamily("overview")}>← Family</button><DocumentsView members={members} revision={revision} initialPersonId={familyChildID} onAddDocument={() => setCapture({ open: true, mode: "document" })} onDataChanged={changed} notify={setToast} /></div> : null}
          {view === "lists" ? <ListsView members={members} revision={revision} initialArea={listsRoute} initialMealsTab={initialMealsTab} financeEnabled={financeAvailable} onAreaChange={(area) => { setListsRoute(area); writeLocation("lists", area); }} onAddTask={() => setQuickAdd({ open: true, kind: "task" })} onDataChanged={changed} notify={setToast} /> : null}
          {view === "fitness" && fitnessWorkspace === null ? <SkeletonList rows={4} /> : null}
          {view === "fitness" && fitnessWorkspace && !fitnessWorkspace.enabled ? <FitnessWorkspaceWelcome busy={fitnessWorkspaceBusy} onEnable={() => void updateFitnessWorkspace({ enabled: true, pinned: true })} /> : null}
          {view === "fitness" && fitnessWorkspace?.enabled ? <FitnessModuleView online={online} revision={revision} section={fitnessSection} onSectionChange={changeFitnessSection} onOpenCalendar={() => changeView("calendar")} onDataChanged={changed} onSetupOpenChange={setFitnessSetupOpen} coachDraft={fitnessCoachDraft} onCoachDraftConsumed={() => setFitnessCoachDraft(null)} onOpenCoachDestination={openFitnessCoachDestination} onAskCoachAboutActivity={openFitnessCoachForActivity} /> : null}
          {view === "home" ? <HomeView revision={revision} notify={setToast} /> : null}
          {view === "finance" ? <FinanceView hasFamilyAccount={financeAvailable} online={online} section={financeSection} scope={financeScope} members={members} revision={revision} onDataChanged={changed} notify={setToast} onSectionChange={changeFinanceSection} onScopeChange={changeFinanceScope} onOpenRenewals={() => openLists("renewals")} simpleDefault={user.role !== "admin"} preferenceOwner={`${user.family_id ?? "family"}:${user.id}`} /> : null}
        </Suspense>
        </RouteErrorBoundary>
      </main>

      {view !== "finance" && !(view === "fitness" && fitnessSetupOpen) ? <ActionRail placement="mobile" onCapture={openCapture} onAdd={openAddHub} onSearch={openGlobalSearch} context={view === "fitness" ? "fitness" : "default"} onFitnessLog={openFitnessLog} onFitnessCoach={openFitnessCoach} /> : null}
      <nav className="mobile-nav" aria-label="Main navigation">
        {mobileNavItems.map((item) => { const Icon = item.icon; return <button type="button" className={cn(view === item.id && "is-active")} aria-current={view === item.id ? "page" : undefined} onClick={() => changeView(item.id)} key={item.id}><Icon aria-hidden="true" size={21} /><span>{item.label}</span></button>; })}
      </nav>

      {mobileMoreOpen ? <Modal open onOpenChange={setMobileMoreOpen} title="More HausKlar">
        <div className="mobile-more-choices">
          <button type="button" onClick={() => chooseMobileMore("home")}><House aria-hidden="true" size={20} /><span><strong>House</strong><small>Home systems and household controls</small></span></button>
          {fitnessWorkspace?.enabled && !fitnessWorkspace.pinned ? <button type="button" onClick={() => chooseMobileMore("fitness")}><Dumbbell aria-hidden="true" size={20} /><span><strong>Fitness</strong><small>Your private training and health workspace</small></span></button> : null}
          {financeAvailable ? <button type="button" onClick={() => chooseMobileMore("finance")}><WalletCards aria-hidden="true" size={20} /><span><strong>{financeNavigationCopy.title}</strong><small>{financeNavigationCopy.subtitle}</small></span></button> : null}
          <div className="mobile-appearance" role="group" aria-label="Appearance">
            <strong>Appearance</strong>
            <div>
              <button type="button" aria-pressed={appearance === "system"} onClick={() => setAppearance("system")}><Settings aria-hidden="true" size={19} /><span><strong>System</strong></span></button>
              <button type="button" aria-pressed={appearance === "light"} onClick={() => setAppearance("light")}><Sun aria-hidden="true" size={19} /><span><strong>Light</strong></span></button>
              <button type="button" aria-pressed={appearance === "dark"} onClick={() => setAppearance("dark")}><Moon aria-hidden="true" size={19} /><span><strong>Dark</strong></span></button>
            </div>
          </div>
        </div>
      </Modal> : null}

      {addHubOpen ? <Suspense fallback={null}><AddHub open onOpenChange={changeAddHubOpen} onChoose={chooseAddDestination} /></Suspense> : null}
      {commitmentsHub.open ? <Suspense fallback={<div className="toast" role="status">Opening plans…</div>}><CommitmentsHub open initialCommitmentID={commitmentsHub.commitmentID} startCreate={commitmentsHub.create} currentUserID={user.id} members={members} onOpenChange={(open) => setCommitmentsHub((current) => ({ ...current, open }))} onDataChanged={changed} /></Suspense> : null}
      {quickAdd.open ? <Suspense fallback={null}><QuickAddDialog open initialKind={quickAdd.kind} members={members} onOpenChange={(open) => setQuickAdd((current) => ({ ...current, open }))} onCreated={changed} notify={setToast} /></Suspense> : null}
      {shoppingOpen ? <Suspense fallback={null}><ShoppingItemDialog open onOpenChange={setShoppingOpen} onCreated={changed} notify={setToast} /></Suspense> : null}
      {capture.open ? <Suspense fallback={null}><CaptureDialog open initialMode={capture.mode} initialText={capture.initialText} members={members} onOpenChange={changeCaptureOpen} onCreated={changed} notify={setToast} onContinueInBismarck={continueCaptureInBismarck} /></Suspense> : null}
      {globalSearchOpen ? <Suspense fallback={null}><GlobalSearch open onOpenChange={setGlobalSearchOpen} onOpenResult={openSearchResult} /></Suspense> : null}
      {onboarding?.should_show ? <div className="onboarding-overlay" role="dialog" aria-modal="true" aria-label="Set up HausKlar"><Suspense fallback={<SkeletonList rows={4} />}><OnboardingGuide user={user} initialStatus={onboarding} onComplete={setOnboarding} onEnableFitness={() => updateFitnessWorkspace({ enabled: true, pinned: true })} /></Suspense></div> : null}
      <Modal
        open={queueReviewOpen}
        onOpenChange={setQueueReviewOpen}
        title="Offline changes"
        description="Only changes created by this signed-in account can sync."
      >
        <div className="offline-change-list">
          {queuedChanges.filter((change) => change.lastError).map((change) => (
            <article key={change.id}>
              <div><strong>{queuedChangeLabel(change)}</strong><p>{change.lastError}</p></div>
              <button type="button" className="button button--secondary" onClick={() => void discardQueuedChange(change.id)}>Discard</button>
            </article>
          ))}
          {heldChanges.map((change) => (
            <article key={change.id}>
              <div>
                <strong>Change held for another account</strong>
                <p>Sign in with the account that created it to sync it, or discard it from this device.</p>
              </div>
              <button type="button" className="button button--secondary" onClick={() => void discardQueuedChange(change.id)}>Discard from device</button>
            </article>
          ))}
        </div>
      </Modal>
      {bismarckOpen && view !== "finance" && view !== "fitness" ? <Suspense fallback={null}><BismarckChat open onOpenChange={changeBismarckOpen} online={online} members={members} onDataChanged={changed} onViewResult={viewAssistantResult} onOpenFitnessCoach={openFitnessCoachFromBismarck} initialDraft={bismarckDraft} onInitialDraftConsumed={() => setBismarckDraft(null)} /></Suspense> : null}
      {showSettings ? <Modal open onOpenChange={closeSettings} title="Settings & profile" size="wide"><Suspense fallback={<SkeletonList rows={4} />}><AccountView user={user} onUserUpdated={updateUser} onSignOut={() => void signOut()} financeAvailable={financeAvailable} fitnessWorkspace={fitnessWorkspace} onFitnessWorkspaceChange={updateFitnessWorkspace} onOpenFinance={openPrivateFinanceFromSettings} onOpenFitness={() => { closeSettings(false); changeView("fitness"); }} /></Suspense></Modal> : null}
      {toast && view !== "fitness" ? <div className="toast" role="status">{toast}</div> : null}
    </div>
  );
}
