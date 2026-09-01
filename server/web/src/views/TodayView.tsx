import {
  AlertTriangle,
  Backpack,
  BookOpen,
  CakeSlice,
  CalendarClock,
  CalendarDays,
  CalendarPlus,
  Check,
  CheckCircle2,
  ChevronDown,
  ChevronRight,
  CircleAlert,
  Clock3,
  CloudRain,
  Dumbbell,
  ExternalLink,
  Gift,
  MoonStar,
  Pill,
  Plus,
  RefreshCw,
  Thermometer,
  Utensils,
  UserRoundCheck,
  UsersRound,
  WalletCards,
  Waves,
  X,
} from "lucide-react";
import {
  format,
  isBefore,
  isToday,
  parseISO,
  startOfDay,
} from "date-fns";
import { type FormEvent, useCallback, useEffect, useMemo, useRef, useState } from "react";

import { api, type ApiReadSource } from "../api";
import { prepPackAction, type PrepPackSuggestion } from "../prepPacks";
import { recordSwimmingBookingOpen } from "../usageMonitor";
import type { CalendarEvent, FamilyMember, FamilyTask, FinanceTodayAction, TomorrowCard } from "../types";
import { ErrorState, Modal, SkeletonList, cn } from "../components/ui";
import {
  SwimmingBookingDialog,
  type SwimmingBookingSelection,
  WeightsBookingDialog,
  type WeightsBookingSelection,
} from "../components/SwimmingBookingDialog";
import { TodayExerciseQuickAction, TodayFitnessQuickActions, TodayViAvailabilityCard } from "../components/TodayFitnessQuickActions";
import { PlansToSortCard } from "../components/PlansToSortCard";
import {
  familySwimmingLabel,
  facilityWindowLabel,
  weightsRoomLabel,
  type FacilityDaySummary,
  type FacilityQuickFact,
} from "../facilities";
import "./today.css";

type Nap = {
  id: string;
  child_id: string;
  started_at: string;
  sleep_type: string;
};

type Illness = {
  id: string;
  child_id: string;
  started_at: string;
  notes?: string | null;
};

type ActiveRoutine = {
  routine_item_id: string;
  person_id: string;
  person_name: string;
  name: string;
  color: string;
  date: string;
};

type Weather = {
  description: string;
  temp_high: number;
  temp_low: number;
  rain_chance: number;
};

type DailyBriefing = {
  weather?: Weather | null;
};

type GlanceMedicine = {
  child_name: string;
  medicine_name: string;
  next_safe_at?: string | null;
  is_safe_now: boolean;
  last_given_at?: string | null;
};

type FamilyGlance = { medicine: GlanceMedicine[] };
type Birthday = { id: string; person_name: string; days_until: number; age: number | null };
type TodayHomework = {
  id: string;
  child_id: string;
  child_name: string;
  test_date: string;
  word_count: number;
  practice_count: number;
  status: "upcoming" | "due" | "overdue";
};
type TodayPresent = {
  id: string;
  child_id: string;
  recipient_name?: string | null;
  title: string;
  deadline: string;
  days_until_due: number;
  status: string;
  owner_id?: string | null;
  owner_name?: string | null;
  action: string;
};

type TodayDashboard = {
  generated_at: string;
  date: string;
  events: CalendarEvent[];
  tasks: FamilyTask[];
  naps: Nap[];
  illnesses: Illness[];
  routines: ActiveRoutine[];
  coordination: TomorrowCard | null;
  memories: PhotoMemory[];
  insights: FamilyInsight[];
  prep_suggestions: PrepPackSuggestion[];
  medicine: FamilyGlance["medicine"];
  birthdays: Birthday[];
  weather: Weather | null;
  finance_action: FinanceTodayAction | null;
  facility_quick_fact?: FacilityQuickFact | null;
  homework?: TodayHomework[];
  presents?: TodayPresent[];
  unavailable: string[];
};

export type FitnessTodayAction = {
  kind: "resume_activity" | "start_strength" | "start_session" | "open_session" | "move_session" | "log_food";
  label: string;
  destination: "overview" | "log" | "plan" | "progress" | "coach";
  target_id: string | null;
};

export type FitnessTodaySession = {
  id: string;
  kind: "planned_session" | "active_activity";
  title: string;
  sport_key: string;
  status: "accepted" | "scheduled" | "in_progress";
  starts_at: string | null;
  scheduled_date: string | null;
  duration_minutes: number | null;
  movable: boolean;
};

type FitnessTodayCard = {
  date: string;
  has_completed_activity_today?: boolean;
  session: FitnessTodaySession | null;
  primary_action: FitnessTodayAction | null;
  secondary_action: FitnessTodayAction | null;
  nutrition: {
    calories_kcal: number;
    calorie_target_kcal: number | null;
    protein_g: number;
    protein_target_g: number | null;
    entry_count: number;
    calories_complete: boolean;
    protein_complete: boolean;
  } | null;
};

type NutritionTargetRecord = {
  id: string;
  metric_key: string;
  target_type: "fixed" | "range" | "weekly_average" | "training_rest" | "phase";
  target_value: number | null;
  target_min: number | null;
  target_max: number | null;
  training_day_value: number | null;
  rest_day_value: number | null;
  effective_from: string;
  effective_until: string | null;
  active: boolean;
};

const SCHOOL_SWIMMING_BOOKING_URL = "https://bookings.example.invalid";

function greeting(): string {
  const hour = new Date().getHours();
  if (hour < 12) return "Good morning";
  if (hour < 18) return "Good afternoon";
  return "Good evening";
}

function eventTime(event: CalendarEvent): string {
  if (event.all_day || event.start_time.length === 10) return "All day";
  return format(parseISO(event.start_time), "HH:mm");
}

function isSchoolMilestone(event: Pick<CalendarEvent, "event_type">): boolean {
  return event.event_type === "school_milestone";
}

function fitnessSessionDetail(session: FitnessTodaySession): string {
  const start = session.starts_at ? parseISO(session.starts_at) : null;
  const timeLabel = start && !Number.isNaN(start.getTime()) ? format(start, "HH:mm") : "Any time";
  return session.duration_minutes ? `${timeLabel} · ${session.duration_minutes} min` : timeLabel;
}

function eventPrimaryParticipant(event: CalendarEvent, members: FamilyMember[]): string | null {
  const participantIDs = new Set(
    [event.assigned_to, ...(event.family_member_ids ?? [])]
      .filter((id): id is string => Boolean(id)),
  );
  return members.find((member) => participantIDs.has(member.id))?.id ?? null;
}

function prepEventTime(value: string, allDay: boolean): string {
  const eventDate = parseISO(value);
  if (Number.isNaN(eventDate.getTime())) return "Coming up";
  if (allDay) return isToday(eventDate) ? "Today" : format(eventDate, "EEEE");
  return isToday(eventDate) ? `Today at ${format(eventDate, "HH:mm")}` : format(eventDate, "EEEE 'at' HH:mm");
}

function taskDue(task: FamilyTask): string | null {
  if (!task.due_date) return null;
  const dateOnly = /^\d{4}-\d{2}-\d{2}$/.test(task.due_date);
  const due = parseISO(task.due_date);
  if (Number.isNaN(due.getTime())) return null;
  if (isToday(due)) return dateOnly ? "Due today" : `Due ${format(due, "HH:mm")}`;
  if (isBefore(due, startOfDay(new Date()))) return "Overdue";
  return format(due, "EEE d MMM");
}

function homeworkDateLabel(value: string): string {
  const due = parseISO(value);
  return Number.isNaN(due.getTime()) ? value : format(due, "d MMM");
}

function napDuration(startedAt: string): string {
  const minutes = Math.max(0, Math.floor((Date.now() - parseISO(startedAt).getTime()) / 60_000));
  if (minutes < 60) return `${minutes} min`;
  return `${Math.floor(minutes / 60)} hr ${minutes % 60} min`;
}

function eventOverlapsDay(event: CalendarEvent, day: string): boolean {
  const dayStart = parseISO(day);
  if (Number.isNaN(dayStart.getTime())) return false;
  const dayEnd = new Date(dayStart);
  dayEnd.setDate(dayEnd.getDate() + 1);
  const startsAt = parseISO(event.start_time);
  if (Number.isNaN(startsAt.getTime()) || startsAt >= dayEnd) return false;
  if (!event.end_time) return startsAt >= dayStart;
  const endsAt = parseISO(event.end_time);
  return !Number.isNaN(endsAt.getTime()) && endsAt > dayStart;
}

type PhotoMemory = { asset_id: string; taken_at: string | null; years_ago: number; thumbnail_url: string };
type FamilyInsight = {
  id: string;
  kind: string;
  message: string;
  detail?: string | null;
  target_date?: string | null;
  suggested_task_title?: string | null;
};

function memoryDate(value: string | null): string | null {
  if (!value) return null;
  const parsed = parseISO(value);
  return Number.isNaN(parsed.getTime()) ? null : format(parsed, "d MMMM yyyy");
}

function insightIcon(kind: string): typeof CalendarClock {
  if (kind === "missing_event") return CalendarClock;
  if (kind === "prep") return Backpack;
  if (kind === "weather") return CloudRain;
  return AlertTriangle;
}

export function TodayView({
  userName,
  userID = userName,
  members,
  revision,
  onAddEvent,
  onAddTask,
  onOpenCalendar,
  onOpenFamily,
  onOpenHomework,
  onOpenPresent,
  onOpenLists,
  onOpenFinanceAction,
  onOpenFinancePurchase,
  onOpenFitnessAction,
  onOpenCommitments = () => undefined,
  onDataChanged,
  fitnessEnabled = true,
}: {
  userName: string;
  userID?: string;
  members: FamilyMember[];
  revision: number;
  onAddEvent: () => void;
  onAddTask: () => void;
  onOpenCalendar: () => void;
  onOpenFamily: (area: "sleep" | "medicine" | "illness" | "dog") => void;
  onOpenHomework?: (childID: string, homeworkID: string) => void;
  onOpenPresent?: (childID: string, presentID: string) => void;
  onOpenLists: (area: "tasks" | "meals" | "routines" | "prep") => void;
  onOpenFinanceAction: (actionID: string, scope: "mine" | "household") => void;
  onOpenFinancePurchase: (lineID: string, scope: "mine" | "household") => void;
  onOpenFitnessAction: (action: FitnessTodayAction, session?: FitnessTodaySession) => void;
  onOpenCommitments?: (commitmentID?: string) => void;
  onDataChanged: () => void;
  fitnessEnabled?: boolean;
}) {
  const [events, setEvents] = useState<CalendarEvent[]>([]);
  const [tasks, setTasks] = useState<FamilyTask[]>([]);
  const [naps, setNaps] = useState<Nap[]>([]);
  const [illnesses, setIllnesses] = useState<Illness[]>([]);
  const [routines, setRoutines] = useState<ActiveRoutine[]>([]);
  const [briefing, setBriefing] = useState<DailyBriefing | null>(null);
  const [medicineAttention, setMedicineAttention] = useState<GlanceMedicine[]>([]);
  const [birthdaysToday, setBirthdaysToday] = useState<Birthday[]>([]);
  const [homework, setHomework] = useState<TodayHomework[]>([]);
  const [presents, setPresents] = useState<TodayPresent[]>([]);
  const [financeAction, setFinanceAction] = useState<FinanceTodayAction | null>(null);
  const [fitnessCard, setFitnessCard] = useState<FitnessTodayCard | null>(null);
  const [nutritionGoalsOpen, setNutritionGoalsOpen] = useState(false);
  const [facilityQuickFact, setFacilityQuickFact] = useState<FacilityQuickFact | null>(null);
  const [facilityDetailsOpen, setFacilityDetailsOpen] = useState(false);
  const [facilityTimetable, setFacilityTimetable] = useState<FacilityDaySummary[] | null>(null);
  const [facilityTimetableLoading, setFacilityTimetableLoading] = useState(false);
  const [facilityTimetableError, setFacilityTimetableError] = useState("");
  const [swimmingBooking, setSwimmingBooking] = useState<SwimmingBookingSelection | null>(null);
  const [weightsBooking, setWeightsBooking] = useState<WeightsBookingSelection | null>(null);
  const [facilityNotice, setFacilityNotice] = useState("");
  const [financeBusy, setFinanceBusy] = useState(false);
  const [financeNotice, setFinanceNotice] = useState("");
  const [financeError, setFinanceError] = useState("");
  const financeErrorRef = useRef<HTMLParagraphElement>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [medicineTimingUnavailable, setMedicineTimingUnavailable] = useState(false);
  const [completing, setCompleting] = useState<string | null>(null);
  const [coordination, setCoordination] = useState<TomorrowCard | null>(null);
  const [coordinationBusy, setCoordinationBusy] = useState<string | null>(null);
  const [coordinationError, setCoordinationError] = useState<string | null>(null);
  const [memory, setMemory] = useState<PhotoMemory | null>(null);
  const [insights, setInsights] = useState<FamilyInsight[]>([]);
  const [insightBusy, setInsightBusy] = useState<string | null>(null);
  const [insightNotice, setInsightNotice] = useState<{ message: string; error: boolean } | null>(null);
  const [prepSuggestions, setPrepSuggestions] = useState<PrepPackSuggestion[]>([]);
  const [prepBusy, setPrepBusy] = useState<string | null>(null);
  const [prepNotice, setPrepNotice] = useState<{ message: string; error: boolean } | null>(null);
  const [showMoreToday, setShowMoreToday] = useState(false);
  const [wideLayout, setWideLayout] = useState(false);
  const fitnessCardGeneration = useRef(0);
  const facilityTimetableGeneration = useRef(0);
  const hasDashboardData = useRef(false);

  useEffect(() => {
    const query = window.matchMedia("(min-width: 1100px)");
    const update = () => setWideLayout(query.matches);
    update();
    query.addEventListener("change", update);
    return () => query.removeEventListener("change", update);
  }, []);

  const load = useCallback(async (background = false) => {
    const fitnessGeneration = ++fitnessCardGeneration.current;
    if (fitnessEnabled) {
      void api<FitnessTodayCard>("/fitness/today-card")
        .then((card) => {
          if (fitnessGeneration === fitnessCardGeneration.current) {
            setFitnessCard(card.date === format(new Date(), "yyyy-MM-dd") ? card : null);
          }
        })
        .catch(() => {
          if (!background && fitnessGeneration === fitnessCardGeneration.current) setFitnessCard(null);
        });
    } else {
      setFitnessCard(null);
    }
    if (!background) setLoading(true);
    setError(null);
    try {
      const timezoneName = Intl.DateTimeFormat().resolvedOptions().timeZone || "Europe/London";
      let readSource: ApiReadSource = "network";
      const dashboard = await api<TodayDashboard>(
        `/briefing/dashboard?timezone=${encodeURIComponent(timezoneName)}`,
        { onReadSource: (source) => { readSource = source; } },
      );
      const unavailable = new Set(dashboard.unavailable);
      const today = format(new Date(), "yyyy-MM-dd");
      const isCurrentDay = dashboard.date === today;
      const currentEvents = dashboard.events
        .filter((event) => eventOverlapsDay(event, today))
        .sort((left, right) => left.start_time.localeCompare(right.start_time));

      if (isCurrentDay) {
        if (!unavailable.has("events")) setEvents(currentEvents);
        if (!unavailable.has("routines")) setRoutines(dashboard.routines);
        if (!unavailable.has("weather")) setBriefing({ weather: dashboard.weather });
        if (!unavailable.has("coordination")) setCoordination(dashboard.coordination);
        if (!unavailable.has("prep_suggestions")) setPrepSuggestions(dashboard.prep_suggestions);
        if (!unavailable.has("birthdays")) {
          setBirthdaysToday(dashboard.birthdays.filter((birthday) => birthday.days_until === 0));
        }
        if (!unavailable.has("facility_quick_fact")) {
          setFacilityQuickFact(dashboard.facility_quick_fact ?? null);
        }
      } else {
        setEvents([]);
        setRoutines([]);
        setBriefing(null);
        setCoordination(null);
        setPrepSuggestions([]);
        setBirthdaysToday([]);
        setFacilityQuickFact(null);
      }

      if (!unavailable.has("tasks")) setTasks(dashboard.tasks);
      if (!unavailable.has("illnesses")) setIllnesses(dashboard.illnesses);
      if (!unavailable.has("memories")) setMemory(dashboard.memories[0] ?? null);
      if (!unavailable.has("insights")) setInsights(dashboard.insights);
      if (!unavailable.has("homework")) setHomework(dashboard.homework ?? []);
      if (!unavailable.has("presents")) setPresents(dashboard.presents ?? []);
      if (!unavailable.has("finance_action")) setFinanceAction(dashboard.finance_action);

      const medicineIsTrusted = readSource === "network"
        && isCurrentDay
        && !unavailable.has("medicine");
      const napStateIsTrusted = readSource === "network"
        && isCurrentDay
        && !unavailable.has("naps");
      setMedicineAttention(medicineIsTrusted ? dashboard.medicine : []);
      setMedicineTimingUnavailable(!medicineIsTrusted);
      setNaps(napStateIsTrusted ? dashboard.naps : []);
      hasDashboardData.current = true;
    } catch (requestError) {
      setMedicineAttention([]);
      setNaps([]);
      setMedicineTimingUnavailable(hasDashboardData.current);
      if (!hasDashboardData.current) {
        setError(requestError instanceof Error ? requestError.message : "Today's plan is unavailable.");
      }
    } finally {
      setLoading(false);
    }
  }, [fitnessEnabled]);

  const lastRevision = useRef(revision);
  useEffect(() => {
    const background = revision !== lastRevision.current;
    lastRevision.current = revision;
    void load(background);
  }, [load, revision]);

  const names = useMemo(() => new Map(members.map((member) => [member.id, member.name])), [members]);
  const financeScope = financeAction?.space_kind === "HOUSEHOLD" ? "household" : "mine";
  const financeAmount = financeAction?.amount_minor != null && financeAction.currency
    ? new Intl.NumberFormat("en-GB", { style: "currency", currency: financeAction.currency }).format(financeAction.amount_minor / 100)
    : null;
  async function addInsightTask(insight: FamilyInsight) {
    setInsightBusy(insight.id);
    setInsightNotice(null);
    try {
      const result = await api<{ title: string }>(`/insights/${insight.id}/add-task`, {
        method: "POST",
      });
      setInsights((current) => current.filter((item) => item.id !== insight.id));
      setInsightNotice({ message: `Task added: ${result.title}`, error: false });
      onDataChanged();
    } catch (requestError) {
      setInsightNotice({
        message: requestError instanceof Error ? requestError.message : "The task could not be added.",
        error: true,
      });
    } finally {
      setInsightBusy(null);
    }
  }

  async function toggleFacilityTimetable() {
    if (facilityTimetable) {
      setFacilityTimetable(null);
      setFacilityTimetableError("");
      return;
    }
    if (!facilityQuickFact || facilityTimetableLoading) return;
    const generation = ++facilityTimetableGeneration.current;
    setFacilityTimetableLoading(true);
    setFacilityTimetableError("");
    try {
      const days = await api<FacilityDaySummary[]>(
        `/facilities/timetable?start=${encodeURIComponent(facilityQuickFact.today.date)}&days=14`,
      );
      if (generation === facilityTimetableGeneration.current) setFacilityTimetable(days);
    } catch (requestError) {
      if (generation === facilityTimetableGeneration.current) {
        setFacilityTimetableError(
          requestError instanceof Error
            ? requestError.message
            : "The two-week timetable could not be loaded.",
        );
      }
    } finally {
      if (generation === facilityTimetableGeneration.current) {
        setFacilityTimetableLoading(false);
      }
    }
  }

  function changeFacilityDetailsOpen(open: boolean) {
    setFacilityDetailsOpen(open);
    if (!open) {
      facilityTimetableGeneration.current += 1;
      setFacilityTimetable(null);
      setFacilityTimetableError("");
      setFacilityTimetableLoading(false);
      setSwimmingBooking(null);
      setWeightsBooking(null);
      setFacilityNotice("");
    }
  }

  async function applyPrepPack(suggestion: PrepPackSuggestion) {
    setPrepBusy(suggestion.id);
    setPrepNotice(null);
    try {
      const result = await api<{ task_ids: string[] }>("/prep-packs/apply", {
        method: "POST",
        body: JSON.stringify(prepPackAction(suggestion)),
      });
      setPrepSuggestions((current) => current.filter((item) => item.id !== suggestion.id));
      setInsights((current) => current.filter((item) => item.kind !== "prep"));
      setPrepNotice({
        message: `${result.task_ids.length} ${result.task_ids.length === 1 ? "task" : "tasks"} added for ${suggestion.event_title}.`,
        error: false,
      });
      onDataChanged();
    } catch (requestError) {
      setPrepNotice({ message: requestError instanceof Error ? requestError.message : "The preparation tasks could not be added.", error: true });
    } finally {
      setPrepBusy(null);
    }
  }

  async function dismissPrepPack(suggestion: PrepPackSuggestion) {
    setPrepBusy(suggestion.id);
    setPrepNotice(null);
    try {
      await api("/prep-packs/dismiss", { method: "POST", body: JSON.stringify(prepPackAction(suggestion)) });
      setPrepSuggestions((current) => current.filter((item) => item.id !== suggestion.id));
    } catch (requestError) {
      setPrepNotice({ message: requestError instanceof Error ? requestError.message : "That suggestion could not be dismissed.", error: true });
    } finally {
      setPrepBusy(null);
    }
  }
  const routineGroups = useMemo(() => {
    const groups = new Map<string, ActiveRoutine[]>();
    routines.forEach((routine) => groups.set(routine.person_id, [...(groups.get(routine.person_id) ?? []), routine]));
    return [...groups.entries()];
  }, [routines]);
  const weather = briefing?.weather;
  const relevantEvents = useMemo(() => {
    const now = Date.now();
    return events.filter((event) => {
      if (isSchoolMilestone(event)) return true;
      if (event.all_day || event.start_time.length === 10) return true;
      const boundary = parseISO(event.end_time ?? event.start_time).getTime();
      return !Number.isNaN(boundary) && boundary >= now;
    });
  }, [events]);
  const nextEvent = relevantEvents.find(isSchoolMilestone)
    ?? relevantEvents.find((event) => !event.all_day && event.start_time.length !== 10)
    ?? relevantEvents[0]
    ?? null;
  const remainingEventCount = Math.max(0, relevantEvents.length - (nextEvent ? 1 : 0));
  const visibleInsights = insights.filter((insight) => insight.kind !== "prep" || !prepSuggestions.length);
  const showTomorrowDecision = Boolean(
    coordination
    && (coordination.visible || new URLSearchParams(window.location.search).has("tomorrow"))
    && !coordination.acknowledged,
  );

  async function completeTask(task: FamilyTask) {
    setCompleting(task.id);
    setTasks((current) => current.filter((item) => item.id !== task.id));
    try {
      await api(`/tasks/${task.id}/complete`, { method: "PATCH" });
      onDataChanged();
    } catch (requestError) {
      setTasks((current) => [task, ...current]);
      setError(requestError instanceof Error ? requestError.message : "That task could not be completed.");
    } finally {
      setCompleting(null);
    }
  }

  async function finishFinanceAction() {
    if (!financeAction || financeAction.kind !== "PAYDAY_TRANSFER" || financeBusy) return;
    setFinanceBusy(true);
    setFinanceError("");
    setFinanceNotice("");
    try {
      await api(`/finance/payday-actions/${encodeURIComponent(financeAction.id)}/resolve`, {
        method: "POST",
        body: JSON.stringify({ status: "DONE", changed_amount_minor: null, note: null }),
      });
      setFinanceAction(null);
      setFinanceNotice("Marked done. HausKlar will check after the bank updates.");
      onDataChanged();
    } catch (requestError) {
      setFinanceError(
        requestError instanceof Error
          ? requestError.message
          : "That money action could not be finished.",
      );
      window.requestAnimationFrame(() => financeErrorRef.current?.focus());
    } finally {
      setFinanceBusy(false);
    }
  }

  async function acknowledgeTomorrow() {
    if (!coordination) return;
    setCoordinationBusy("ack"); setCoordinationError(null);
    try {
      await api("/coordination/tomorrow/ack", { method: "POST", body: JSON.stringify({ target_date: coordination.target_date }) });
      setCoordination({ ...coordination, acknowledged: true });
    } catch (requestError) {
      setCoordinationError(requestError instanceof Error ? requestError.message : "Tomorrow's plan could not be confirmed.");
    } finally { setCoordinationBusy(null); }
  }

  async function assignLoad(member: FamilyMember) {
    const prompt = coordination?.load_prompt;
    if (!prompt) return;
    setCoordinationBusy(member.id); setCoordinationError(null);
    try {
      await api(`/coordination/load/${prompt.task_id}/assign`, {
        method: "POST",
        body: JSON.stringify({ assignee_id: member.id }),
      });
      setCoordination({ ...coordination!, load_prompt: null });
      onDataChanged();
    } catch (requestError) {
      setCoordinationError(requestError instanceof Error ? requestError.message : "That responsibility could not be assigned.");
    } finally { setCoordinationBusy(null); }
  }

  async function deferLoad() {
    const prompt = coordination?.load_prompt;
    if (!prompt) return;
    setCoordinationBusy("later"); setCoordinationError(null);
    try {
      await api(`/coordination/load/${prompt.task_id}/later`, { method: "POST" });
      setCoordination({ ...coordination!, load_prompt: null });
    } catch (requestError) {
      setCoordinationError(requestError instanceof Error ? requestError.message : "That prompt could not be put aside.");
    } finally { setCoordinationBusy(null); }
  }

  return (
    <div className="today-page">
      <header className="today-titlebar">
        <div>
          <h1>Today</h1>
          <button type="button" className="refresh-link" onClick={() => void load()} aria-label="Refresh today"><RefreshCw aria-hidden="true" size={17} /> Refresh</button>
        </div>
      </header>

      <div className="today-column">
        <section className="day-heading" aria-label="Today at a glance">
          <h2>{format(new Date(), "EEEE, d MMMM")}</h2>
          <p>{greeting()}, {userName}</p>
          {weather ? (
            <div className="weather-line"><CloudRain aria-hidden="true" size={18} /><span>{weather.description} · {Math.round(weather.temp_high)}° / {Math.round(weather.temp_low)}°</span></div>
          ) : null}
        </section>

        {error ? <ErrorState message={error} retry={load} /> : null}
        {medicineTimingUnavailable ? (
          <div className="partial-notice inline-recovery" role="alert">
            <span>Medicine timing needs checking</span>
            <button type="button" className="button button--secondary button--compact" onClick={() => onOpenFamily("medicine")}>Review</button>
          </div>
        ) : null}
        {loading ? <SkeletonList rows={8} /> : null}

        {!loading && !error ? (
          <>
            <div className="today-workspace">
            <div className="today-primary">
            {coordinationError ? <div className="coordination-error" role="alert">{coordinationError}<button type="button" onClick={() => setCoordinationError(null)}>Dismiss</button></div> : null}
            {illnesses.length || naps.length || medicineAttention.length || birthdaysToday.length ? (
              <TodaySection title="Needs attention" icon={CircleAlert}>
                {illnesses.map((illness) => (
                  <TodayLinkRow
                    key={illness.id}
                    icon={Thermometer}
                    tone="danger"
                    title={`${names.get(illness.child_id) ?? "Child"} is unwell`}
                    detail={illness.notes ?? "Open the illness tracker"}
                    onClick={() => onOpenFamily("illness")}
                  />
                ))}
                {naps.map((nap) => (
                  <TodayLinkRow
                    key={nap.id}
                    icon={MoonStar}
                    tone="sleep"
                    title={`${names.get(nap.child_id) ?? "Child"} is sleeping`}
                    detail={`${nap.sleep_type === "nap" ? "Nap" : "Sleep"} · ${napDuration(nap.started_at)}`}
                    onClick={() => onOpenFamily("sleep")}
                  />
                ))}
                {medicineAttention.map((medicine) => {
                  const nextSafe = medicine.next_safe_at ? parseISO(medicine.next_safe_at) : null;
                  const safeTime = nextSafe && !Number.isNaN(nextSafe.getTime()) ? format(nextSafe, "HH:mm") : null;
                  return (
                    <TodayLinkRow
                      key={`${medicine.child_name}-${medicine.medicine_name}`}
                      icon={Pill}
                      tone={medicine.is_safe_now ? "medicine" : "warning"}
                      title={medicine.is_safe_now ? `${medicine.medicine_name}: minimum interval has passed` : `${medicine.medicine_name}: minimum interval has not passed`}
                      detail={`${medicine.child_name}${safeTime && !medicine.is_safe_now ? ` · Minimum interval ends at ${safeTime}` : " · Check before recording"}`}
                      onClick={() => onOpenFamily("medicine")}
                    />
                  );
                })}
                {birthdaysToday.map((birthday) => (
                  <TodayInfoRow
                    key={birthday.id}
                    icon={CakeSlice}
                    tone="birthday"
                    title={`${birthday.person_name}'s birthday`}
                    detail={birthday.age == null ? "Birthday today" : `Today · Turns ${birthday.age}`}
                  />
                ))}
              </TodaySection>
            ) : null}

            <TodaySection title="Up next" icon={Clock3}>
              <PlansToSortCard revision={revision} onOpen={onOpenCommitments} />
              {fitnessEnabled ? (
                <TodayFitnessQuickActions
                  ownerID={userID}
                  revision={revision}
                  onDataChanged={onDataChanged}
                  onOpenFullFoodLog={() => onOpenFitnessAction({ kind: "log_food", label: "Log food", destination: "log", target_id: null })}
                />
              ) : null}
              {fitnessCard?.nutrition ? (
                <section className="module-action-card today-fitness-nutrition" aria-labelledby="today-nutrition-title">
                  <div className="today-fitness-nutrition__heading">
                    <span className="today-money-icon"><Utensils aria-hidden="true" size={20} /></span>
                    <div>
                      <span>My Fitness · running total</span>
                      <h2 id="today-nutrition-title">Nutrition today</h2>
                    </div>
                    <button
                      type="button"
                      className="button button--secondary button--compact today-fitness-nutrition__goals"
                      onClick={() => setNutritionGoalsOpen(true)}
                    >
                      {fitnessCard.nutrition.calorie_target_kcal == null
                        || fitnessCard.nutrition.protein_target_g == null
                        ? "Set goals"
                        : "Edit goals"}
                    </button>
                  </div>
                  <div className="today-fitness-nutrition__metrics">
                    {([
                      {
                        label: "Calories",
                        value: fitnessCard.nutrition.calories_kcal,
                        target: fitnessCard.nutrition.calorie_target_kcal,
                        unit: "kcal",
                        complete: fitnessCard.nutrition.calories_complete,
                      },
                      {
                        label: "Protein",
                        value: fitnessCard.nutrition.protein_g,
                        target: fitnessCard.nutrition.protein_target_g,
                        unit: "g",
                        complete: fitnessCard.nutrition.protein_complete,
                      },
                    ] as const).map((metric) => {
                      const target = metric.target ?? 0;
                      const hasTarget = target > 0;
                      return (
                        <div key={metric.label}>
                          <span><strong>{metric.complete ? "" : "≥ "}{Math.round(metric.value).toLocaleString()} {metric.unit}</strong><small>{hasTarget ? `of ${Math.round(target).toLocaleString()} ${metric.unit}` : "Set a goal"}</small></span>
                          <progress
                            className={metric.label === "Calories" ? "is-calories" : "is-protein"}
                            max={hasTarget ? target : 1}
                            value={hasTarget ? Math.min(metric.value, target) : 0}
                            aria-label={hasTarget
                              ? `${metric.label}: ${metric.complete ? "" : "at least "}${Math.round(metric.value)} of ${Math.round(target)} ${metric.unit}`
                              : `${metric.label} goal not set`}
                          />
                        </div>
                      );
                    })}
                  </div>
                  <button
                    type="button"
                    className="button button--secondary"
                    onClick={() => onOpenFitnessAction({ kind: "log_food", label: "Log food", destination: "log", target_id: null })}
                  >
                    Log food
                  </button>
                </section>
              ) : null}
              {fitnessCard?.primary_action && (fitnessCard.session || fitnessCard.primary_action.kind === "start_strength") ? (
                <section className="module-action-card today-money-card today-fitness-card" aria-labelledby="today-fitness-title">
                  <div className="today-money-heading">
                    <span className="today-money-icon"><Dumbbell aria-hidden="true" size={20} /></span>
                    <div>
                      <span>{fitnessCard.session ? `My Fitness · ${fitnessSessionDetail(fitnessCard.session)}` : "My Fitness · Nothing logged today"}</span>
                      <h2 id="today-fitness-title">{fitnessCard.session?.title ?? "Strength workout"}</h2>
                    </div>
                  </div>
                  <div className="dialog-actions">
                    {fitnessCard.secondary_action && fitnessCard.session ? (
                      <button type="button" className="button button--secondary" onClick={() => onOpenFitnessAction(fitnessCard.secondary_action!, fitnessCard.session!)}>
                        {fitnessCard.secondary_action.label}
                      </button>
                    ) : null}
                    <button type="button" className="button button--primary today-money-action" onClick={() => onOpenFitnessAction(fitnessCard.primary_action!, fitnessCard.session ?? undefined)}>
                      {fitnessCard.primary_action.label}
                    </button>
                  </div>
                </section>
              ) : null}
              {nextEvent ? (
                <button type="button" className={cn("today-event-row", isSchoolMilestone(nextEvent) && "is-school-milestone")} onClick={onOpenCalendar} key={nextEvent.id}>
                  {isSchoolMilestone(nextEvent) ? <span className="today-milestone-sprinkles" aria-hidden="true" /> : null}
                  <time>{eventTime(nextEvent)}</time>
                  <span className={cn("event-marker", `member-color-${Math.max(0, members.findIndex((member) => member.id === eventPrimaryParticipant(nextEvent, members))) % 5}`)} style={nextEvent.source_color ? { background: nextEvent.source_color } : undefined} />
                  <div><strong>{nextEvent.title}</strong>{nextEvent.location ? <small>{nextEvent.location}</small> : null}</div>
                  <b>Next</b>
                  <ChevronRight aria-hidden="true" size={16} />
                </button>
              ) : fitnessCard?.session ? null : (
                <TodayEmpty icon={CalendarPlus} title={events.length ? "Nothing else scheduled today" : "Nothing scheduled yet"} actionLabel="Add event" onAction={onAddEvent} />
              )}
              {remainingEventCount ? <button type="button" className="today-more" onClick={onOpenCalendar}>{remainingEventCount} more today <ChevronRight aria-hidden="true" size={15} /></button> : null}
            </TodaySection>

            {facilityQuickFact?.today.covered ? (
              <button
                type="button"
                className="today-facility-fact"
                onClick={() => setFacilityDetailsOpen(true)}
                aria-label="See Example School swimming and weights times for today and tomorrow"
              >
                <span className="today-facility-icon"><Waves aria-hidden="true" size={20} /></span>
                <span>
                  <small>Example School today</small>
                  <strong>{familySwimmingLabel(facilityQuickFact.today)}</strong>
                  <span>
                    {[weightsRoomLabel(facilityQuickFact.today), `Tomorrow: ${familySwimmingLabel(facilityQuickFact.tomorrow)}`, weightsRoomLabel(facilityQuickFact.tomorrow)]
                      .filter(Boolean)
                      .join(" · ")}
                  </span>
                </span>
                <ChevronRight aria-hidden="true" size={17} />
              </button>
            ) : null}

            {financeNotice ? (
              <p className="today-money-notice" role="status" aria-live="polite">
                {financeNotice}
              </p>
            ) : null}
            {financeAction ? (
              <section className="module-action-card today-money-card" aria-labelledby="today-money-title">
                <div className="today-money-heading">
                  <span className="today-money-icon"><WalletCards aria-hidden="true" size={20} /></span>
                  <div>
                    <span>Money · {financeAction.space_kind === "PERSONAL" ? "Personal" : "Household"}</span>
                    <h2 id="today-money-title">
                      {financeAction.kind === "PAYDAY_TRANSFER"
                        ? `Move ${financeAmount ?? "the protected money"} from ${financeAction.source_account_label ?? "the spending account"} to ${financeAction.destination_account_label ?? "the protected account"}`
                        : financeAction.title ?? (financeAction.kind === "PURCHASE_REVIEW" ? "Review the selected purchase" : "Review the current money habit")}
                    </h2>
                    <p>
                      {financeAction.space_kind === "PERSONAL"
                        ? `Only you can see this for ${financeAction.space_name}. HausKlar records your confirmation; it never moves money.`
                        : "Everyone with access to household money can see this. HausKlar records your confirmation; it never moves money."}
                    </p>
                  </div>
                </div>
                {financeError ? (
                  <p
                    className="form-error"
                    role="alert"
                    tabIndex={-1}
                    ref={financeErrorRef}
                  >
                    {financeError}
                  </p>
                ) : null}
                <button
                  type="button"
                  className="button button--primary today-money-action"
                  disabled={financeBusy}
                  onClick={() => {
                    if (financeAction.kind === "PAYDAY_TRANSFER") {
                      void finishFinanceAction();
                    } else if (financeAction.kind === "PURCHASE_REVIEW" && financeAction.line_id) {
                      onOpenFinancePurchase(financeAction.line_id, financeScope);
                    } else {
                      onOpenFinanceAction(financeAction.id, financeScope);
                    }
                  }}
                >
                  {financeAction.kind === "PAYDAY_TRANSFER"
                    ? (financeBusy ? "Saving…" : "I moved it")
                    : financeAction.kind === "PURCHASE_REVIEW" ? "Review purchase" : "Review now"}
                </button>
              </section>
            ) : null}

            {homework.length ? <TodaySection title="School" icon={BookOpen}>
              {homework.map((item) => {
                const due = item.status === "overdue" ? `Overdue · ${homeworkDateLabel(item.test_date)}` : item.status === "due" ? "Due today" : `Due ${homeworkDateLabel(item.test_date)}`;
                const practice = item.practice_count ? `Practised ${item.practice_count} ${item.practice_count === 1 ? "time" : "times"}` : "Not practised yet";
                return <TodayLinkRow
                  key={item.id}
                  icon={BookOpen}
                  tone={item.status === "overdue" ? "danger" : "school"}
                  title={`${item.child_name}'s spellings · ${due}`}
                  detail={`${item.word_count} words · ${practice}`}
                  onClick={() => onOpenHomework?.(item.child_id, item.id)}
                />;
              })}
            </TodaySection> : null}

            {presents.length ? <TodaySection title="Gifts" icon={Gift}>
              {presents.map((item) => {
                const due = item.days_until_due < 0
                  ? `Overdue by ${Math.abs(item.days_until_due)} ${Math.abs(item.days_until_due) === 1 ? "day" : "days"}`
                  : item.days_until_due === 0
                    ? "Due today"
                    : item.days_until_due === 1
                      ? "Due tomorrow"
                      : `Due in ${item.days_until_due} days`;
                const recipient = item.recipient_name ?? names.get(item.child_id) ?? "Recipient";
                return <TodayLinkRow
                  key={item.id}
                  icon={Gift}
                  tone="birthday"
                  title={item.action}
                  detail={`${recipient} · ${due}${item.owner_name ? ` · ${item.owner_name}` : ""}`}
                  onClick={() => onOpenPresent?.(item.child_id, item.id)}
                />;
              })}
            </TodaySection> : null}

            <TodaySection title="To do" icon={CheckCircle2}>
              {tasks.length ? tasks.slice(0, 3).map((task) => (
                <div className="today-task-row" key={task.id}>
                  <button type="button" className="today-task-check" disabled={completing === task.id} aria-label={`Complete ${task.title}`} onClick={() => void completeTask(task)}><Check aria-hidden="true" size={17} /></button>
                  <button type="button" className="today-task-main" onClick={() => onOpenLists("tasks")}><strong>{task.title}</strong><small className={taskDue(task) === "Overdue" ? "is-overdue" : undefined}>{taskDue(task) ?? task.category}</small></button>
                </div>
              )) : <TodayEmpty icon={CheckCircle2} title="Nothing needs doing" actionLabel="Add task" onAction={onAddTask} />}
              {tasks.length > 3 ? <button type="button" className="today-more" onClick={() => onOpenLists("tasks")}>View {tasks.length - 3} more <ChevronRight aria-hidden="true" size={15} /></button> : null}
            </TodaySection>

            {coordination?.load_prompt ? (
              <LoadPromptCard prompt={coordination.load_prompt} members={members.filter((member) => member.member_type === "user")} busy={coordinationBusy} onAssign={(member) => void assignLoad(member)} onLater={() => void deferLoad()} />
            ) : showTomorrowDecision && coordination ? (
              <TomorrowSortedCard card={coordination} facility={facilityQuickFact?.tomorrow ?? null} busy={coordinationBusy === "ack"} onConfirm={() => void acknowledgeTomorrow()} onFix={coordination.events.length ? onOpenCalendar : () => onOpenLists("tasks")} />
            ) : null}
            {fitnessEnabled && fitnessCard && !fitnessCard.session && !fitnessCard.primary_action && !fitnessCard.has_completed_activity_today ? (
              <TodayExerciseQuickAction now={new Date()} online={navigator.onLine} onDataChanged={onDataChanged} />
            ) : null}
            </div>

            <aside className="today-secondary" aria-label="More today">
            <button type="button" className="more-today-toggle" aria-expanded={showMoreToday || wideLayout} aria-controls="more-today-content" onClick={() => setShowMoreToday((shown) => !shown)}>
              <span><strong>More today</strong><small>Routines, suggestions and family moments</small></span>
              <ChevronDown aria-hidden="true" size={20} />
            </button>

            {showMoreToday || wideLayout ? (
              <div className="more-today-content" id="more-today-content">
                {coordination?.load_prompt && showTomorrowDecision && coordination ? (
                  <TomorrowSortedCard
                    card={coordination}
                    facility={facilityQuickFact?.tomorrow ?? null}
                    busy={coordinationBusy === "ack"}
                    onConfirm={() => void acknowledgeTomorrow()}
                    onFix={coordination.events.length ? onOpenCalendar : () => onOpenLists("tasks")}
                  />
                ) : null}

                <TodayViAvailabilityCard key={userID} ownerID={userID} onDataChanged={onDataChanged} />

                {prepNotice ? (
                  <div className={cn(prepNotice.error ? "form-error" : "form-success", "insight-notice")} role={prepNotice.error ? "alert" : "status"}>
                    {prepNotice.message}
                  </div>
                ) : null}
                {prepSuggestions.length ? (
                  <section className="prep-suggestions" aria-label="Packing suggestions">
                    {prepSuggestions.map((suggestion) => (
                      <article className="prep-suggestion-card" key={suggestion.id}>
                        <div className="prep-suggestion-heading">
                          <Backpack aria-hidden="true" size={21} />
                          <div><span>{prepEventTime(suggestion.event_start, suggestion.event_all_day)}</span><h2>Things to pack for {suggestion.event_title}</h2></div>
                        </div>
                        <ul>{suggestion.items.map((item) => <li key={item}><Check aria-hidden="true" size={15} />{item}</li>)}</ul>
                        <div className="prep-suggestion-actions">
                          <button type="button" className="button button--primary" disabled={prepBusy !== null} onClick={() => void applyPrepPack(suggestion)}>
                            <Plus aria-hidden="true" size={17} />
                            {prepBusy === suggestion.id ? "Adding…" : `Add ${suggestion.items.length} ${suggestion.items.length === 1 ? "task" : "tasks"}`}
                          </button>
                          <button type="button" className="button button--secondary" disabled={prepBusy !== null} onClick={() => void dismissPrepPack(suggestion)}>Not this time</button>
                          <button type="button" className="prep-edit-link" disabled={prepBusy !== null} onClick={() => onOpenLists("prep")}>Edit packing list</button>
                        </div>
                      </article>
                    ))}
                  </section>
                ) : null}

                {insightNotice ? (
                  <div className={cn(insightNotice.error ? "form-error" : "form-success", "insight-notice")} role="status">{insightNotice.message}</div>
                ) : null}
                {visibleInsights.length ? (
                  <section className="today-insights" aria-label="Things HausKlar noticed">
                    {visibleInsights.slice(0, 3).map((insight) => {
                      const InsightIcon = insightIcon(insight.kind);
                      return (
                        <div className="insight-row" key={insight.id}>
                          <InsightIcon aria-hidden="true" size={19} />
                          <div>
                            <strong>{insight.message}</strong>
                            {insight.detail ? <small>{insight.detail}</small> : null}
                            {insight.suggested_task_title ? (
                              <button type="button" className="insight-action" disabled={insightBusy === insight.id} onClick={() => void addInsightTask(insight)}>
                                <Plus aria-hidden="true" size={15} />
                                {insightBusy === insight.id ? "Adding…" : insight.suggested_task_title}
                              </button>
                            ) : null}
                          </div>
                          <button
                            type="button"
                            className="icon-button"
                            aria-label="Dismiss this notice"
                            onClick={() => {
                              setInsights((current) => current.filter((item) => item.id !== insight.id));
                              void api(`/insights/${insight.id}/dismiss`, { method: "POST" }).catch(() => undefined);
                            }}
                          >
                            <X aria-hidden="true" size={17} />
                          </button>
                        </div>
                      );
                    })}
                  </section>
                ) : null}

                {routineGroups.length ? (
                  <TodaySection title="Prepare" icon={Backpack}>
                    {routineGroups.map(([personID, personRoutines]) => (
                      <button type="button" className="today-routine-row" onClick={() => onOpenLists("routines")} key={personID}>
                        <span style={{ backgroundColor: personRoutines[0]?.color || "var(--primary)" }} />
                        <div><strong>{names.get(personID) ?? personRoutines[0]?.person_name ?? "Family"}</strong><small>{personRoutines.map((routine) => routine.name).join(", ")}</small></div>
                        <ChevronRight aria-hidden="true" size={16} />
                      </button>
                    ))}
                  </TodaySection>
                ) : null}
                {memory ? (
                  <section className="memory-tile" aria-label="A photo memory">
                    <img src={`/api${memory.thumbnail_url}`} alt={`Family photo from ${memory.years_ago === 1 ? "one year" : `${memory.years_ago} years`} ago`} loading="lazy" />
                    <div className="memory-caption">
                      <strong>{memory.years_ago === 1 ? "One year ago" : `${memory.years_ago} years ago`}</strong>
                      {memoryDate(memory.taken_at) ? <span>{memoryDate(memory.taken_at)}</span> : null}
                    </div>
                  </section>
                ) : null}
              </div>
            ) : null}
            </aside>
            </div>

            <Modal
              open={facilityDetailsOpen}
              onOpenChange={changeFacilityDetailsOpen}
              title="Example School swimming & weights"
              description={facilityQuickFact?.current_to ? `Current timetable to ${format(parseISO(facilityQuickFact.current_to), "d MMMM")}.` : undefined}
            >
              {facilityQuickFact ? (
                <div className="facility-detail-days">
                  <div className="dialog-actions facility-detail-actions">
                    <button
                      type="button"
                      className="button button--secondary"
                      disabled={facilityTimetableLoading}
                      aria-busy={facilityTimetableLoading}
                      onClick={() => void toggleFacilityTimetable()}
                    >
                      <CalendarDays aria-hidden="true" size={17} />
                      {facilityTimetableLoading
                        ? "Loading timetable…"
                        : facilityTimetable
                          ? "Today & tomorrow"
                          : "Next 2 weeks"}
                    </button>
                    <a
                      className="button button--primary"
                      href={SCHOOL_SWIMMING_BOOKING_URL}
                      target="_blank"
                      rel="noreferrer"
                    >
                      <ExternalLink aria-hidden="true" size={17} />
                      Book swimming
                    </a>
                  </div>
                  {facilityTimetableError ? (
                    <p className="form-error facility-timetable-error" role="alert">
                      {facilityTimetableError} Press Next 2 weeks to try again.
                    </p>
                  ) : null}
                  {facilityNotice ? <p className="form-success" role="status">{facilityNotice}</p> : null}
                  {facilityTimetable ? (
                    <>
                      <p className="facility-timetable-heading">Next 2 weeks</p>
                      {facilityTimetable.map((day) => (
                        <FacilityDayDetail
                          key={day.date}
                          label={format(parseISO(day.date), "EEEE")}
                          day={day}
                          onSwimmingBooked={setSwimmingBooking}
                          onWeightsBooked={setWeightsBooking}
                        />
                      ))}
                    </>
                  ) : (
                    <>
                      <FacilityDayDetail
                        label="Today"
                        day={facilityQuickFact.today}
                        onSwimmingBooked={setSwimmingBooking}
                        onWeightsBooked={setWeightsBooking}
                      />
                      <FacilityDayDetail
                        label="Tomorrow"
                        day={facilityQuickFact.tomorrow}
                        onSwimmingBooked={setSwimmingBooking}
                        onWeightsBooked={setWeightsBooking}
                      />
                    </>
                  )}
                  {facilityQuickFact.update_due ? <p className="facility-update-note">A new timetable will be needed soon.</p> : null}
                </div>
              ) : null}
            </Modal>
            <SwimmingBookingDialog
              selection={swimmingBooking}
              onOpenChange={(open) => { if (!open) setSwimmingBooking(null); }}
              onBooked={(message) => {
                setFacilityNotice(message);
                onDataChanged();
              }}
            />
            <WeightsBookingDialog
              selection={weightsBooking}
              onOpenChange={(open) => { if (!open) setWeightsBooking(null); }}
              onBooked={(message) => {
                setFacilityNotice(message);
                onDataChanged();
              }}
            />
            <NutritionGoalsDialog
              open={nutritionGoalsOpen}
              date={fitnessCard?.date ?? format(new Date(), "yyyy-MM-dd")}
              calories={fitnessCard?.nutrition?.calorie_target_kcal ?? null}
              protein={fitnessCard?.nutrition?.protein_target_g ?? null}
              onOpenChange={setNutritionGoalsOpen}
              onSaved={() => {
                void load(true);
                onDataChanged();
              }}
            />
          </>
        ) : null}
      </div>
    </div>
  );
}

function NutritionGoalsDialog({
  open,
  date,
  calories,
  protein,
  onOpenChange,
  onSaved,
}: {
  open: boolean;
  date: string;
  calories: number | null;
  protein: number | null;
  onOpenChange: (open: boolean) => void;
  onSaved: () => void;
}) {
  const [calorieValue, setCalorieValue] = useState("");
  const [proteinValue, setProteinValue] = useState("");
  const [targets, setTargets] = useState<NutritionTargetRecord[]>([]);
  const [loadingTargets, setLoadingTargets] = useState(false);
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState("");

  useEffect(() => {
    if (!open) return;
    let cancelled = false;
    setCalorieValue(calories == null ? "" : String(Math.round(calories)));
    setProteinValue(protein == null ? "" : String(Math.round(protein)));
    setError("");
    setLoadingTargets(true);
    void api<NutritionTargetRecord[]>(
      `/fitness/nutrition/targets?date=${encodeURIComponent(date)}`,
    ).then((records) => {
      if (cancelled) return;
      setTargets(records.filter((record) => record.active));
    }).catch((requestError) => {
      if (!cancelled) {
        setError(requestError instanceof Error ? requestError.message : "Goals could not be loaded.");
      }
    }).finally(() => {
      if (!cancelled) setLoadingTargets(false);
    });
    return () => { cancelled = true; };
  }, [calories, date, open, protein]);

  async function saveGoals(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    const calorieGoal = Number(calorieValue);
    const proteinGoal = Number(proteinValue);
    if (!Number.isFinite(calorieGoal) || calorieGoal <= 0
      || !Number.isFinite(proteinGoal) || proteinGoal <= 0) {
      setError("Enter both daily goals.");
      return;
    }
    setSaving(true);
    setError("");
    try {
      await Promise.all([
        saveNutritionGoal("calories_kcal", calorieGoal),
        saveNutritionGoal("protein_g", proteinGoal),
      ]);
      onOpenChange(false);
      onSaved();
    } catch (requestError) {
      setError(requestError instanceof Error ? requestError.message : "Goals could not be saved.");
    } finally {
      setSaving(false);
    }
  }

  async function saveNutritionGoal(metricKey: string, value: number) {
    const existing = targets.find(
      (target) => target.metric_key.replace(/^nutrition\./, "") === metricKey,
    );
    await api(existing
      ? `/fitness/nutrition/targets/${existing.id}`
      : "/fitness/nutrition/targets", {
      method: existing ? "PUT" : "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        metric_key: metricKey,
        target_type: "fixed",
        target_value: value,
        effective_from: existing?.effective_from ?? date,
        active: true,
      }),
    });
  }

  return (
    <Modal
      open={open}
      onOpenChange={onOpenChange}
      title="Daily goals"
    >
      <form className="today-nutrition-goals" aria-busy={saving} onSubmit={(event) => void saveGoals(event)}>
        <label htmlFor="today-calorie-goal">
          <span>Calories</span>
          <span><input id="today-calorie-goal" autoComplete="off" inputMode="numeric" pattern="[0-9]*" type="text" value={calorieValue} onChange={(event) => setCalorieValue(event.target.value)} required /> kcal</span>
        </label>
        <label htmlFor="today-protein-goal">
          <span>Protein</span>
          <span><input id="today-protein-goal" autoComplete="off" inputMode="numeric" pattern="[0-9]*" type="text" value={proteinValue} onChange={(event) => setProteinValue(event.target.value)} required /> g</span>
        </label>
        {error ? <p className="form-error" role="alert">{error}</p> : null}
        <div className="dialog-actions">
          <button type="button" className="button button--secondary" onClick={() => onOpenChange(false)}>Cancel</button>
          <button type="submit" className="button button--primary" disabled={loadingTargets || saving}>{saving ? "Saving…" : "Save"}</button>
        </div>
      </form>
    </Modal>
  );
}

function TomorrowSortedCard({ card, facility, busy, onConfirm, onFix }: { card: TomorrowCard; facility: FacilityDaySummary | null; busy: boolean; onConfirm: () => void; onFix: () => void }) {
  const date = parseISO(card.target_date);
  const firstItems = [
    ...card.events.slice(0, 3).map((event) => ({ id: `event-${event.id}`, time: eventTime(event as CalendarEvent), title: event.title, milestone: isSchoolMilestone(event) })),
    ...card.tasks.slice(0, Math.max(0, 3 - card.events.length)).map((task) => ({ id: `task-${task.id}`, time: "To do", title: task.title, milestone: false })),
  ];
  const remaining = card.events.length + card.tasks.length - firstItems.length;
  const facilityItems = facility?.covered ? [
    { id: "facility-swimming", time: "Swim", title: familySwimmingLabel(facility), milestone: false },
    ...(weightsRoomLabel(facility) ? [{ id: "facility-weights", time: "Weights", title: weightsRoomLabel(facility)!, milestone: false }] : []),
  ] : [];
  return (
    <section className="tomorrow-card" aria-labelledby="tomorrow-card-title">
      <div className="tomorrow-card-heading"><MoonStar aria-hidden="true" size={21} /><div><span>{format(date, "EEEE")}</span><h2 id="tomorrow-card-title">Tomorrow, sorted</h2></div></div>
      {firstItems.length || facilityItems.length ? <ul>{[...firstItems, ...facilityItems].map((item) => <li className={cn(item.milestone && "is-school-milestone")} key={item.id}>{item.milestone ? <span className="today-milestone-sprinkles" aria-hidden="true" /> : null}<time>{item.time}</time><strong>{item.title}</strong></li>)}</ul> : <p className="tomorrow-clear">Nothing's in the calendar for tomorrow yet.</p>}
      {remaining > 0 ? <p className="tomorrow-more">Plus {remaining} more {remaining === 1 ? "item" : "items"}.</p> : null}
      <div className="tomorrow-actions">
        <button type="button" className="button button--primary" disabled={busy} onClick={onConfirm}><Check aria-hidden="true" size={17} />{busy ? "Confirming…" : "Looks right"}</button>
        <button type="button" className="button button--secondary" disabled={busy} onClick={onFix}>Fix something</button>
      </div>
    </section>
  );
}

function FacilityDayDetail({
  label,
  day,
  onSwimmingBooked,
  onWeightsBooked,
}: {
  label: string;
  day: FacilityDaySummary;
  onSwimmingBooked: (selection: SwimmingBookingSelection) => void;
  onWeightsBooked: (selection: WeightsBookingSelection) => void;
}) {
  return (
    <section className="facility-detail-day" aria-labelledby={`facility-${day.date}`}>
      <div><span>{label}</span><strong id={`facility-${day.date}`}>{format(parseISO(day.date), "EEEE, d MMMM")}</strong></div>
      {day.covered ? (
        <dl>
          <div>
            <dt>Family swimming</dt>
            {day.family_swimming.length ? (
              <dd className="facility-bookable-windows">
                {day.family_swimming.map((window) => (
                  <span key={`${window.start}-${window.end}`}>
                    <span>{window.start}–{window.end}</span>
                    <button
                      type="button"
                      className="button button--secondary button--compact"
                      aria-label={`Booked swimming on ${format(parseISO(day.date), "EEEE, d MMMM")} within ${window.start}–${window.end}`}
                      onClick={() => {
                        recordSwimmingBookingOpen("today_facilities");
                        onSwimmingBooked({
                          date: day.date,
                          ...window,
                          sourceSurface: "today_facilities",
                        });
                      }}
                    >
                      Booked
                    </button>
                  </span>
                ))}
              </dd>
            ) : <dd>{day.pool_closed ? "Closed" : "None"}</dd>}
          </div>
          {day.lane_swimming.length ? <div><dt>Lane swimming</dt><dd>{facilityWindowLabel(day.lane_swimming)}</dd></div> : null}
          {day.weights_relevant ? (
            <div>
              <dt>Weights room</dt>
              {day.weights_room.length ? (
                <dd className="facility-bookable-windows">
                  {day.weights_room.map((window) => (
                    <span key={`${window.start}-${window.end}`}>
                      <span>{window.start}–{window.end}</span>
                      <button
                        type="button"
                        className="button button--secondary button--compact"
                        aria-label={`Plan strength on ${format(parseISO(day.date), "EEEE, d MMMM")} within ${window.start}–${window.end}`}
                        onClick={() => onWeightsBooked({ date: day.date, ...window })}
                      >
                        Book
                      </button>
                    </span>
                  ))}
                </dd>
              ) : <dd>{day.weights_room_status === "closed" ? "Closed" : "Times unavailable"}</dd>}
            </div>
          ) : null}
        </dl>
      ) : <p>No timetable covers this date yet.</p>}
    </section>
  );
}

function LoadPromptCard({ prompt, members, busy, onAssign, onLater }: { prompt: NonNullable<TomorrowCard["load_prompt"]>; members: FamilyMember[]; busy: string | null; onAssign: (member: FamilyMember) => void; onLater: () => void }) {
  return (
    <section className="load-prompt-card" aria-labelledby="load-prompt-title">
      <div className="load-prompt-icon"><UsersRound aria-hidden="true" size={20} /></div>
      <div className="load-prompt-content">
        <span>Needs an owner</span>
        <h2 id="load-prompt-title">Who’s handling “{prompt.title}”?</h2>
        <div className="load-prompt-actions">
          {members.map((member) => <button type="button" disabled={busy !== null} onClick={() => onAssign(member)} key={member.id}><UserRoundCheck aria-hidden="true" size={16} />{busy === member.id ? "Assigning…" : member.name}</button>)}
          <button type="button" disabled={busy !== null} onClick={onLater}>{busy === "later" ? "Saving…" : "Later"}</button>
        </div>
      </div>
    </section>
  );
}

function TodaySection({ title, icon: Icon, children }: { title: string; icon: typeof Clock3; children: React.ReactNode }) {
  return (
    <section className="today-section" aria-labelledby={`today-${title.replaceAll(" ", "-").toLowerCase()}`}>
      <h2 id={`today-${title.replaceAll(" ", "-").toLowerCase()}`}><Icon aria-hidden="true" size={19} />{title}</h2>
      <div className="today-section-body">{children}</div>
    </section>
  );
}

function TodayLinkRow({ icon: Icon, tone, title, detail, onClick }: { icon: typeof MoonStar; tone: string; title: string; detail: string; onClick: () => void }) {
  return (
    <button type="button" className={`today-link-row is-${tone}`} onClick={onClick}>
      <Icon aria-hidden="true" size={20} />
      <div><strong>{title}</strong><small>{detail}</small></div>
      <ChevronRight aria-hidden="true" size={16} />
    </button>
  );
}

function TodayInfoRow({ icon: Icon, tone, title, detail }: { icon: typeof MoonStar; tone: string; title: string; detail: string }) {
  return (
    <div className={`today-link-row is-${tone}`}>
      <Icon aria-hidden="true" size={20} />
      <div><strong>{title}</strong><small>{detail}</small></div>
    </div>
  );
}

function TodayEmpty({ icon: Icon, title, actionLabel, onAction }: { icon: typeof Plus; title: string; actionLabel: string; onAction: () => void }) {
  return (
    <div className="today-empty">
      <Icon aria-hidden="true" size={22} />
      <strong>{title}</strong>
      <button type="button" className="button button--secondary button--compact" onClick={onAction}><Plus aria-hidden="true" size={16} />{actionLabel}</button>
    </div>
  );
}
