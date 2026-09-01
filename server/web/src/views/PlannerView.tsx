import {
  addDays,
  addMonths,
  addWeeks,
  addYears,
  eachDayOfInterval,
  endOfMonth,
  endOfYear,
  endOfWeek,
  format,
  isBefore,
  isSameDay,
  isSameMonth,
  isToday,
  parseISO,
  startOfDay,
  startOfMonth,
  startOfYear,
  startOfWeek,
} from "date-fns";
import {
  CalendarPlus,
  CalendarHeart,
  Activity,
  Check,
  Clock3,
  ChevronDown,
  ChevronLeft,
  ChevronRight,
  Edit3,
  Dumbbell,
  MapPin,
  Navigation,
  Paperclip,
  Plus,
  Repeat2,
  SlidersHorizontal,
  School,
  Trash2,
  Truck,
  Upload,
  WalletCards,
  Waves,
  X,
} from "lucide-react";
import { useCallback, useEffect, useMemo, useRef, useState, type CSSProperties } from "react";

import { api, localISODate, localISODateTime } from "../api";
import { eventCalendarDayKeys, eventTimeLabelForDay } from "../calendarDays";
import type {
  CalendarEvent,
  CalendarRecurrenceMutationScope,
  FamilyMember,
  FamilyTask,
  FinanceProjectionPreferences,
  LinkedDocument,
} from "../types";
import { DocumentViewer } from "../components/DocumentViewer";
import { QuickAddDialog } from "../components/QuickAddDialog";
import {
  SwimmingBookingDialog,
  type SwimmingBookingSelection,
  WeightsBookingDialog,
  type WeightsBookingSelection,
} from "../components/SwimmingBookingDialog";
import { EmptyState, ErrorState, IconButton, Modal, Segmented, SkeletonList, cn } from "../components/ui";
import type { FitnessCalendarLayerItem, FitnessPlannedSession } from "../fitness/contract";
import { cachedFitnessRecords, deleteFitnessRecord } from "../fitness/offlineStore";
import { currentOfflineQueueOwner } from "../offlineQueue";
import { prepPackAction, type PrepPackSuggestion } from "../prepPacks";
import { recordSwimmingBookingOpen } from "../usageMonitor";
import "./planner.css";
import type {
  FacilityCalendarLayerItem,
  FacilityCalendarPreferences,
  FacilityImportPreview,
  FacilityImportResult,
} from "../facilities";
import { familySwimmingLabel, weightsRoomLabel } from "../facilities";

type PlannerMode = "day" | "week" | "month" | "agenda" | "year";
type MemberFilter = "all" | "kids" | "shared" | string;
type RecurringEventAction = "edit" | "delete";

const recurrenceScopeOptions: Array<{
  value: CalendarRecurrenceMutationScope;
  label: string;
  detail: string;
}> = [
  { value: "only_this", label: "Only this event", detail: "The rest of the series stays unchanged." },
  { value: "this_and_later", label: "This and later events", detail: "Earlier events stay unchanged." },
  { value: "entire_series", label: "Every event in series", detail: "Change the complete repeating series." },
];

type ActiveRoutine = {
  routine_item_id: string;
  person_id: string;
  person_name: string;
  name: string;
  color: string;
  date: string;
  time?: string | null;
  time_of_day?: string | null;
  location?: string | null;
  preparation_note?: string | null;
  prep_template_id?: string | null;
  reminder_minutes?: number | null;
};

type HandoffKind = "pickup" | "work_departure";
type HandoffOccurrence = {
  id: string;
  handoff_id: string;
  kind: HandoffKind;
  date: string;
  time_of_day: string;
  term_person_id: string;
  term_person_name: string;
  owner_user_id: string;
  owner_name: string;
  label: string;
  is_override: boolean;
};
type HandoffScheduleItem = {
  id: string;
  kind: HandoffKind;
  weekday: number;
  time_of_day: string;
  term_person_id: string;
  owner_user_id: string;
};
type HandoffScheduleItemRequest = Omit<HandoffScheduleItem, "id" | "owner_user_id"> & {
  owner_user_id?: string;
};
type HandoffSchedule = { items: HandoffScheduleItem[] };
type HandoffDayDraft = {
  weekday: number;
  time: string;
};
type HandoffPersonDraft = {
  kind: HandoffKind;
  personId: string;
  personName: string;
  days: HandoffDayDraft[];
};

type SchoolClub = {
  id: string;
  name: string;
  child_id: string;
  child_name: string;
  weekday: number;
  start_time: string;
  end_time: string;
  active_from: string;
  active_until?: string | null;
  location?: string | null;
  color: string;
};
type SchoolClubDraft = {
  name: string;
  childId: string;
  weekday: number;
  startTime: string;
  endTime: string;
};
type ToastImportChanges = { added: number; changed: number; removed: number; unchanged: number };
type ToastImportPreview = {
  sha256: string;
  source_title: string;
  child_id: string;
  child_name: string;
  valid_from: string;
  valid_to: string;
  base_start_time: string;
  booked_days: number;
  until_1630: number;
  until_1730: number;
  changes: ToastImportChanges;
  already_imported: boolean;
  can_confirm: boolean;
};
type ToastImportResult = { import_id: string; imported: boolean; preview: ToastImportPreview };
type ToastImportStatus = {
  import_id: string;
  child_id: string;
  child_name: string;
  source_title: string;
  valid_from: string;
  valid_to: string;
  booked_days: number;
  imported_at: string;
};

type TermDate = { id: string; person_id: string; label?: string | null; start_date: string; end_date: string };
type HolidayDate = { id: string; person_id: string; date: string; label?: string | null };
type FitnessCalendarPreferences = { show_planned: boolean; show_completed: boolean };

type DayPlanItem =
  | { kind: "event"; at: number; event: CalendarEvent }
  | { kind: "coordination"; at: number; handoffs: HandoffOccurrence[]; toast: CalendarEvent[] }
  | { kind: "fitness"; at: number; fitness: FitnessCalendarLayerItem }
  | { kind: "routine"; at: number; routine: ActiveRoutine; timeLabel: string }
  | { kind: "task"; at: number; task: FamilyTask; timeLabel: string }
  | { kind: "prep"; at: number; prep: PrepPackSuggestion; timeLabel: string };

const handoffWeekdays = ["Mon", "Tue", "Wed", "Thu", "Fri"];

function isToastEvent(event: CalendarEvent): boolean {
  return event.event_type === "toast_club" || event.event_type === "toast_club_conflict";
}

function isSchoolClubEvent(event: CalendarEvent): boolean {
  return event.event_type === "school_club" || event.event_type === "school_club_cancelled";
}

function isSchoolMilestone(event: CalendarEvent): boolean {
  return event.event_type === "school_milestone";
}

function toastChildLabel(event: CalendarEvent): string {
  return event.title.split("·").at(-1)?.trim() || event.title;
}

function localTimeOnDay(day: Date, value: string): number {
  const parsed = new Date(`${localISODate(day)}T${value}:00`);
  return Number.isNaN(parsed.getTime()) ? startOfDay(day).valueOf() : parsed.valueOf();
}

function timeMinutes(value: string): number {
  const [hours, minutes] = value.split(":").map(Number);
  return Number.isFinite(hours) && Number.isFinite(minutes) ? hours * 60 + minutes : 0;
}

type CoordinationWindow = { start: number; end: number; label: string; conflict: boolean };
type CoordinationMarker = { at: number; label: string; kind: HandoffKind };
type CoordinationLane = {
  id: string;
  name: string;
  colorIndex: number;
  windows: CoordinationWindow[];
  markers: CoordinationMarker[];
};

function coordinationLanes(
  handoffs: HandoffOccurrence[],
  toast: CalendarEvent[],
  members: FamilyMember[],
): CoordinationLane[] {
  const memberIndex = new Map(members.map((member, index) => [member.id, index % 5]));
  const lanes = new Map<string, CoordinationLane>();
  const lane = (personID: string, personName: string) => {
    const existing = lanes.get(personID);
    if (existing) return existing;
    const created = {
      id: personID,
      name: personName,
      colorIndex: memberIndex.get(personID) ?? 0,
      windows: [],
      markers: [],
    };
    lanes.set(personID, created);
    return created;
  };
  for (const event of toast) {
    const childID = [...eventParticipantIDs(event)].find((id) => members.some((member) => member.id === id && member.member_type === "child"));
    const childName = childID
      ? members.find((member) => member.id === childID)?.name ?? toastChildLabel(event)
      : toastChildLabel(event);
    const start = eventTime(event) === "All day" ? 15 * 60 + 30 : timeMinutes(eventTime(event));
    const parsedEnd = event.end_time ? parseISO(event.end_time) : null;
    const end = parsedEnd && !Number.isNaN(parsedEnd.valueOf()) ? parsedEnd.getHours() * 60 + parsedEnd.getMinutes() : start;
    const target = lane(childID ?? `toast:${childName}`, childName);
    const same = target.windows.find((window) => window.start === start && window.end === end && window.conflict === (event.event_type === "toast_club_conflict"));
    if (!same) target.windows.push({ start, end, label: "Toast", conflict: event.event_type === "toast_club_conflict" });
  }

  for (const handoff of handoffs) {
    const personID = handoff.kind === "pickup" ? handoff.term_person_id : handoff.owner_user_id;
    const personName = handoff.kind === "pickup" ? handoff.term_person_name : handoff.owner_name;
    const target = lane(personID, personName);
    const label = handoff.kind === "work_departure" ? "leaves work" : "pickup";
    target.markers.push({ at: timeMinutes(handoff.time_of_day), label, kind: handoff.kind });
  }

  return [...lanes.values()].sort((left, right) => {
    const leftTime = Math.min(...left.markers.map((item) => item.at), ...left.windows.map((item) => item.start));
    const rightTime = Math.min(...right.markers.map((item) => item.at), ...right.windows.map((item) => item.start));
    return leftTime - rightTime || left.name.localeCompare(right.name);
  });
}

function CoordinationTimelineCard({
  handoffs,
  toast,
  members,
  compact = false,
  onOpen,
}: {
  handoffs: HandoffOccurrence[];
  toast: CalendarEvent[];
  members: FamilyMember[];
  compact?: boolean;
  onOpen: () => void;
}) {
  const lanes = coordinationLanes(handoffs, toast, members);
  const moments = lanes.flatMap((item) => [
    ...item.markers.map((marker) => marker.at),
    ...item.windows.flatMap((window) => [window.start, window.end]),
  ]);
  const start = Math.min(15 * 60, ...moments) - 15;
  const end = Math.max(18 * 60, ...moments) + 15;
  const span = Math.max(60, end - start);
  const position = (value: number) => `${Math.max(0, Math.min(100, ((value - start) / span) * 100))}%`;
  const details = lanes.flatMap((item) => [
    ...item.markers.map((marker) => `${item.name} ${marker.label} at ${String(Math.floor(marker.at / 60)).padStart(2, "0")}:${String(marker.at % 60).padStart(2, "0")}`),
    ...item.windows.map((window) => `${item.name} can be collected ${String(Math.floor(window.start / 60)).padStart(2, "0")}:${String(window.start % 60).padStart(2, "0")} to ${String(Math.floor(window.end / 60)).padStart(2, "0")}:${String(window.end % 60).padStart(2, "0")}`),
  ]).join("; ");

  return (
    <button type="button" className={cn("coordination-card", compact && "is-compact")} aria-label={`Leave and pickup. ${details}`} onClick={onOpen}>
      <span className="coordination-card-heading"><strong>Leave &amp; pickup</strong><ChevronRight aria-hidden="true" size={15} /></span>
      <span className="coordination-axis" aria-hidden="true">{[15, 16, 17, 18].map((hour) => <i style={{ left: position(hour * 60) }} key={hour}>{hour > 12 ? hour - 12 : hour}pm</i>)}</span>
      <span className="coordination-lanes">
        {lanes.map((item) => <span className={cn("coordination-lane", `member-color-${item.colorIndex}`)} key={item.id}>
          <strong>{item.name}</strong>
          <span className="coordination-track">
            {item.windows.map((window) => <span
              className={cn("coordination-window", window.conflict && "is-conflict")}
              style={{ left: position(window.start), width: `max(8px, ${((window.end - window.start) / span) * 100}%)` }}
              key={`${window.start}-${window.end}-${window.label}`}
            ><b>{window.label}</b></span>)}
            {item.markers.map((marker) => <span className={cn("coordination-marker", `is-${marker.kind}`)} style={{ left: position(marker.at) }} key={`${marker.kind}-${marker.at}-${marker.label}`}><i /><b>{marker.label}</b></span>)}
          </span>
        </span>)}
      </span>
    </button>
  );
}

function eventInterval(event: CalendarEvent): { start: number; end: number } {
  const start = eventDate(event).valueOf();
  const defaultDuration = event.all_day || event.start_time.length === 10 ? 86_400_000 : 1;
  const parsedEnd = event.end_time ? parseISO(event.end_time).valueOf() : start + defaultDuration;
  return { start, end: Number.isNaN(parsedEnd) ? start + defaultDuration : parsedEnd };
}

type PlannerProps = {
  members: FamilyMember[];
  revision: number;
  onAddEvent: () => void;
  onOpenCycleTracking?: () => void;
  onDataChanged: () => void;
  financeEnabled?: boolean;
};

function isFinanceManaged(item: CalendarEvent | FamilyTask): boolean {
  return Boolean(item.managed_source?.kind.startsWith("finance_"));
}

function isFacilityManaged(event: CalendarEvent): boolean {
  return event.event_type?.startsWith("facility_") === true;
}

function facilitySwimmingSelection(event: CalendarEvent): SwimmingBookingSelection | null {
  if (event.event_type !== "facility_family_swimming" || !event.end_time) return null;
  const start = parseISO(event.start_time);
  const end = parseISO(event.end_time);
  if (Number.isNaN(start.valueOf()) || Number.isNaN(end.valueOf())) return null;
  return {
    date: format(start, "yyyy-MM-dd"),
    start: format(start, "HH:mm"),
    end: format(end, "HH:mm"),
    sourceSurface: "calendar_event",
  };
}

function facilityWeightsSelection(event: CalendarEvent): WeightsBookingSelection | null {
  if (event.event_type !== "facility_weights_room" || !event.end_time) return null;
  const start = parseISO(event.start_time);
  const end = parseISO(event.end_time);
  if (Number.isNaN(start.valueOf()) || Number.isNaN(end.valueOf())) return null;
  return {
    date: format(start, "yyyy-MM-dd"),
    start: format(start, "HH:mm"),
    end: format(end, "HH:mm"),
  };
}

function facilityCalendarEvent(item: FacilityCalendarLayerItem): CalendarEvent {
  return {
    id: `facility-layer-${item.id}`,
    title: item.display_title,
    start_time: item.start_time,
    end_time: item.end_time,
    all_day: false,
    location: item.location,
    assigned_to: item.owner_user_id,
    family_member_ids: item.owner_user_id ? [item.owner_user_id] : null,
    event_type: `facility_${item.layer_kind}`,
    source_name: "Example School facilities",
    read_only: true,
    source_document_id: item.source_document_id,
  };
}

function eventDate(event: CalendarEvent): Date {
  return parseISO(event.start_time);
}

function eventTime(event: CalendarEvent): string {
  if (event.all_day || event.start_time.length === 10) return "All day";
  return format(eventDate(event), "HH:mm");
}

function eventTimeRange(event: CalendarEvent): string {
  const start = eventTime(event);
  if (start === "All day" || !event.end_time) return start;
  const end = parseISO(event.end_time);
  if (Number.isNaN(end.getTime())) return start;
  if (!isSameDay(eventDate(event), end)) return `${start} – ${format(end, "d MMM, HH:mm")}`;
  return `${start} – ${format(end, "HH:mm")}`;
}

function eventAccentStyle(event: CalendarEvent): CSSProperties | undefined {
  if (!event.source_color) return undefined;
  return {
    "--member-color": event.source_color,
    "--member-soft": `color-mix(in srgb, ${event.source_color} 12%, var(--surface))`,
  } as CSSProperties;
}

function dueLabel(value?: string | null): string {
  if (!value) return "No due date";
  const parsed = parseISO(value);
  if (isToday(parsed)) return `Today, ${format(parsed, "HH:mm")}`;
  return format(parsed, "EEE d MMM");
}

function recurrenceLabel(rule?: string | null): string | null {
  const frequency = rule?.match(/(?:^|;)FREQ=(DAILY|WEEKLY|MONTHLY|YEARLY)(?:;|$)/i)?.[1]?.toLowerCase();
  if (!frequency) return null;
  return `${frequency[0].toUpperCase()}${frequency.slice(1)}`;
}

function attachmentRoleLabel(role: string): string {
  return ({
    ticket: "Ticket",
    booking: "Booking",
    school_letter: "School letter",
    insurance: "Insurance",
    other: "Other",
  } as Record<string, string>)[role] ?? "Other";
}

function eventParticipantIDs(event: CalendarEvent): Set<string> {
  return new Set(
    [event.assigned_to, ...(event.family_member_ids ?? [])]
      .filter((id): id is string => Boolean(id)),
  );
}

function calendarRangeValue(date: Date): string {
  // `+` must be escaped or URLSearchParams semantics turn it into a space.
  // Colons remain readable and valid in a query value.
  return encodeURIComponent(localISODateTime(date)).replaceAll("%3A", ":");
}

function plannerAnchorFromURL(): Date {
  const fallback = startOfDay(new Date());
  const value = new URL(window.location.href).searchParams.get("event_date");
  if (!value || !/^\d{4}-\d{2}-\d{2}$/.test(value)) return fallback;
  const parsed = parseISO(value);
  return Number.isNaN(parsed.getTime()) ? fallback : startOfDay(parsed);
}

function fitnessLayerPreferenceKey(): string {
  const owner = currentOfflineQueueOwner();
  return `hausklar:fitness-calendar-layer:${owner?.familyId ?? "signed-out"}:${owner?.userId ?? "unknown"}`;
}

function readFitnessLayerPreference(): { training: boolean; completed: boolean } {
  try {
    const parsed = JSON.parse(window.localStorage.getItem(fitnessLayerPreferenceKey()) ?? "null") as { training?: unknown; completed?: unknown } | null;
    return { training: parsed?.training !== false, completed: parsed?.completed === true };
  } catch {
    return { training: true, completed: false };
  }
}

function fitnessLayerDate(item: FitnessCalendarLayerItem): Date {
  const value = item.scheduled_start_utc ?? item.time_window_start_utc;
  return value ? new Date(value) : parseISO(item.scheduled_date ?? "1970-01-01");
}

function fitnessLayerTime(item: FitnessCalendarLayerItem): string {
  if (item.scheduled_start_utc) return format(new Date(item.scheduled_start_utc), "HH:mm");
  if (item.time_window_start_utc && item.time_window_end_utc) return `${format(new Date(item.time_window_start_utc), "HH:mm")}–${format(new Date(item.time_window_end_utc), "HH:mm")}`;
  return "Any time";
}

export function PlannerView({ members, revision, onOpenCycleTracking, onDataChanged, financeEnabled = false }: PlannerProps) {
  const signedInUserId = currentOfflineQueueOwner()?.userId ?? null;
  const [mode, setMode] = useState<PlannerMode>("week");
  const [anchor, setAnchor] = useState(plannerAnchorFromURL);
  const [memberFilter, setMemberFilter] = useState<MemberFilter>("all");
  const [events, setEvents] = useState<CalendarEvent[]>([]);
  const [tasks, setTasks] = useState<FamilyTask[]>([]);
  const [routines, setRoutines] = useState<ActiveRoutine[]>([]);
  const [handoffs, setHandoffs] = useState<HandoffOccurrence[]>([]);
  const [prepSuggestions, setPrepSuggestions] = useState<PrepPackSuggestion[]>([]);
  const [termDates, setTermDates] = useState<TermDate[]>([]);
  const [holidayDates, setHolidayDates] = useState<HolidayDate[]>([]);
  const initialFitnessLayer = useMemo(readFitnessLayerPreference, []);
  const [showFitnessTraining, setShowFitnessTraining] = useState(initialFitnessLayer.training);
  const [showFitnessCompleted, setShowFitnessCompleted] = useState(initialFitnessLayer.completed);
  const [fitnessItems, setFitnessItems] = useState<FitnessCalendarLayerItem[]>([]);
  const [facilityPreferences, setFacilityPreferences] = useState<FacilityCalendarPreferences>({
    show_family_swimming: false,
    show_personal_facilities: false,
  });
  const [facilityPreferenceBusy, setFacilityPreferenceBusy] = useState(false);
  const [facilityImportOpen, setFacilityImportOpen] = useState(false);
  const [facilityImportFile, setFacilityImportFile] = useState<File | null>(null);
  const [facilityImportPreview, setFacilityImportPreview] = useState<FacilityImportPreview | null>(null);
  const [facilityImportBusy, setFacilityImportBusy] = useState(false);
  const [facilityImportError, setFacilityImportError] = useState<string | null>(null);
  const [handoffSetupOpen, setHandoffSetupOpen] = useState(false);
  const [handoffScheduleBusy, setHandoffScheduleBusy] = useState(false);
  const [handoffScheduleError, setHandoffScheduleError] = useState<string | null>(null);
  const [handoffPeople, setHandoffPeople] = useState<HandoffPersonDraft[]>([]);
  const [pickupPersonTab, setPickupPersonTab] = useState("");
  const [workPersonTab, setWorkPersonTab] = useState("");
  const [coordinationDate, setCoordinationDate] = useState<Date | null>(null);
  const [editingHandoff, setEditingHandoff] = useState<HandoffOccurrence | null>(null);
  const [handoffEditTime, setHandoffEditTime] = useState("");
  const [handoffEditBusy, setHandoffEditBusy] = useState(false);
  const [clubsOpen, setClubsOpen] = useState(false);
  const [clubs, setClubs] = useState<SchoolClub[]>([]);
  const [clubsBusy, setClubsBusy] = useState(false);
  const [clubsError, setClubsError] = useState<string | null>(null);
  const [editingClub, setEditingClub] = useState<SchoolClub | null | "new">(null);
  const [clubDraft, setClubDraft] = useState<SchoolClubDraft>({ name: "", childId: "", weekday: 0, startTime: "15:30", endTime: "16:30" });
  const [clubToDelete, setClubToDelete] = useState<SchoolClub | null>(null);
  const [clubOccurrenceBusy, setClubOccurrenceBusy] = useState(false);
  const [toastOpen, setToastOpen] = useState(false);
  const [toastStatus, setToastStatus] = useState<ToastImportStatus[]>([]);
  const [toastFile, setToastFile] = useState<File | null>(null);
  const [toastPreview, setToastPreview] = useState<ToastImportPreview | null>(null);
  const [toastBusy, setToastBusy] = useState(false);
  const [toastError, setToastError] = useState<string | null>(null);
  const [calendarDisplayOpen, setCalendarDisplayOpen] = useState(false);
  const [selectedEvent, setSelectedEvent] = useState<CalendarEvent | null>(null);
  const [selectedFitnessItem, setSelectedFitnessItem] = useState<FitnessCalendarLayerItem | null>(null);
  const [fitnessItemToDelete, setFitnessItemToDelete] = useState<FitnessCalendarLayerItem | null>(null);
  const [fitnessDeleteBusy, setFitnessDeleteBusy] = useState(false);
  const [swimmingBooking, setSwimmingBooking] = useState<SwimmingBookingSelection | null>(null);
  const [weightsBooking, setWeightsBooking] = useState<WeightsBookingSelection | null>(null);
  const [prepBusyId, setPrepBusyId] = useState<string | null>(null);
  const [viewingDocument, setViewingDocument] = useState<LinkedDocument | null>(null);
  const [previewReturnEvent, setPreviewReturnEvent] = useState<CalendarEvent | null>(null);
  const [editorOpen, setEditorOpen] = useState(false);
  const [editingEvent, setEditingEvent] = useState<CalendarEvent | null>(null);
  const [editingRecurrenceScope, setEditingRecurrenceScope] = useState<CalendarRecurrenceMutationScope | null>(null);
  const [recurrencePrompt, setRecurrencePrompt] = useState<{
    event: CalendarEvent;
    action: RecurringEventAction;
  } | null>(null);
  const [editorDate, setEditorDate] = useState(startOfDay(new Date()));
  const [eventToDelete, setEventToDelete] = useState<CalendarEvent | null>(null);
  const [deleting, setDeleting] = useState(false);
  const [rugbyVenueBusy, setRugbyVenueBusy] = useState(false);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [actionError, setActionError] = useState<string | null>(null);
  const [notice, setNotice] = useState<string | null>(null);
  const [showMoney, setShowMoney] = useState(true);
  const [showDeliveries, setShowDeliveries] = useState(true);
  const [projectionPreferenceBusy, setProjectionPreferenceBusy] = useState(false);
  const loadGeneration = useRef(0);
  const loadAbort = useRef<AbortController | null>(null);
  const fitnessPreferenceGeneration = useRef(0);
  const facilityPreferenceGeneration = useRef(0);
  const facilityFileInputRef = useRef<HTMLInputElement>(null);
  const toastFileInputRef = useRef<HTMLInputElement>(null);
  const calendarDisplayRef = useRef<HTMLDivElement>(null);
  const calendarDisplayTriggerRef = useRef<HTMLButtonElement>(null);

  useEffect(() => {
    if (!calendarDisplayOpen) return;
    function closeOnEscape(event: KeyboardEvent) {
      if (event.key !== "Escape") return;
      setCalendarDisplayOpen(false);
      calendarDisplayTriggerRef.current?.focus();
    }
    function closeOnOutsidePress(event: PointerEvent) {
      if (calendarDisplayRef.current?.contains(event.target as Node)) return;
      setCalendarDisplayOpen(false);
    }
    document.addEventListener("keydown", closeOnEscape);
    document.addEventListener("pointerdown", closeOnOutsidePress);
    return () => {
      document.removeEventListener("keydown", closeOnEscape);
      document.removeEventListener("pointerdown", closeOnOutsidePress);
    };
  }, [calendarDisplayOpen]);

  useEffect(() => {
    if (!financeEnabled) return;
    let active = true;
    setProjectionPreferenceBusy(true);
    api<FinanceProjectionPreferences>("/finance/projection-preferences")
      .then((preference) => {
        if (active) {
          setShowMoney(preference.show_money);
          setShowDeliveries(preference.show_deliveries);
        }
      })
      .catch((requestError: unknown) => {
        if (active) setActionError(requestError instanceof Error ? requestError.message : "The money and deliveries setting could not be loaded.");
      })
      .finally(() => {
        if (active) setProjectionPreferenceBusy(false);
      });
    return () => {
      active = false;
    };
  }, [financeEnabled]);

  useEffect(() => {
    const generation = ++fitnessPreferenceGeneration.current;
    void api<FitnessCalendarPreferences>("/fitness/calendar-preferences")
      .then((preference) => {
        if (
          generation === fitnessPreferenceGeneration.current
          && typeof preference.show_planned === "boolean"
          && typeof preference.show_completed === "boolean"
        ) {
          setShowFitnessTraining(preference.show_planned);
          setShowFitnessCompleted(preference.show_completed);
        }
      })
      .catch(() => undefined);
  }, []);

  useEffect(() => {
    const generation = ++facilityPreferenceGeneration.current;
    void api<FacilityCalendarPreferences>("/facilities/calendar-preferences")
      .then((preference) => {
        if (
          generation === facilityPreferenceGeneration.current
          && typeof preference.show_family_swimming === "boolean"
          && typeof preference.show_personal_facilities === "boolean"
        ) {
          setFacilityPreferences(preference);
        }
      })
      .catch(() => undefined);
  }, []);

  useEffect(() => {
    window.localStorage.setItem(fitnessLayerPreferenceKey(), JSON.stringify({
      training: showFitnessTraining,
      completed: showFitnessCompleted,
    }));
  }, [showFitnessCompleted, showFitnessTraining]);

  useEffect(() => {
    const identifier = new URL(window.location.href).searchParams.get("event");
    if (!identifier || selectedEvent) return;
    const match = events.find((event) => event.id === identifier)
      ?? events.find((event) => event.series_id === identifier);
    if (match) {
      setSelectedEvent(match);
      const url = new URL(window.location.href);
      url.searchParams.delete("event");
      url.searchParams.delete("event_date");
      window.history.replaceState({}, "", url);
    }
  }, [events, selectedEvent]);

  const interval = useMemo(() => {
    if (mode === "day") return { start: startOfDay(anchor), end: startOfDay(anchor) };
    if (mode === "year") return { start: startOfYear(anchor), end: endOfYear(anchor) };
    if (mode === "month") {
      return {
        start: startOfWeek(startOfMonth(anchor), { weekStartsOn: 1 }),
        end: endOfWeek(endOfMonth(anchor), { weekStartsOn: 1 }),
      };
    }
    if (mode === "agenda") return { start: startOfDay(anchor), end: addDays(startOfDay(anchor), 59) };
    return {
      start: startOfWeek(anchor, { weekStartsOn: 1 }),
      end: endOfWeek(anchor, { weekStartsOn: 1 }),
    };
  }, [anchor, mode]);

  const load = useCallback(async (background = false) => {
    loadAbort.current?.abort();
    const controller = new AbortController();
    loadAbort.current = controller;
    const generation = ++loadGeneration.current;
    if (!background) setLoading(true);
    setError(null);
    try {
      if (mode === "year") {
        const [termItems, holidayItems, taskItems] = await Promise.all([
          api<TermDate[]>("/routines/terms", { signal: controller.signal }),
          api<HolidayDate[]>(`/routines/holidays?year=${anchor.getFullYear()}`, { signal: controller.signal }),
          api<FamilyTask[]>("/tasks/?status=pending&limit=200", { signal: controller.signal }),
        ]);
        if (generation !== loadGeneration.current) return;
        setTermDates(termItems);
        setHolidayDates(holidayItems);
        setTasks(taskItems);
        setEvents([]);
        setRoutines([]);
        setHandoffs([]);
        setPrepSuggestions([]);
        setFitnessItems([]);
      } else {
        async function optional<T>(path: string): Promise<T[]> {
          try {
            return await api<T[]>(path, { signal: controller.signal });
          } catch {
            return [];
          }
        }
        const start = localISODate(interval.start);
        const end = localISODate(interval.end);
        const calendarStart = calendarRangeValue(startOfDay(interval.start));
        const calendarEnd = calendarRangeValue(addDays(startOfDay(interval.end), 1));
        async function fitnessLayer(): Promise<FitnessCalendarLayerItem[]> {
          if (!showFitnessTraining && !showFitnessCompleted) return [];
          try {
            const query = new URLSearchParams({
              start,
              end,
              include_completed: String(showFitnessCompleted),
            });
            const items = await api<FitnessCalendarLayerItem[]>(
              `/fitness/calendar-layer?${query.toString()}`,
              { signal: controller.signal },
              true,
              false,
            );
            return items.filter((item) => (
              item.layer_kind === "planned" ? showFitnessTraining : showFitnessCompleted
            ));
          } catch {
            if (controller.signal.aborted || !showFitnessTraining) return [];
            const cached = await cachedFitnessRecords<FitnessPlannedSession>("planned_session").catch(() => []);
            return cached
              .filter((session) => session.status !== "cancelled" && session.status !== "skipped")
              .filter((session) => {
                const day = session.scheduled_date ?? session.scheduled_start_utc?.slice(0, 10) ?? session.time_window_start_utc?.slice(0, 10);
                return Boolean(day && day >= start && day <= end);
              })
              .map((session) => ({
                id: session.id,
                owner_user_id: currentOfflineQueueOwner()?.userId ?? "",
                layer_kind: "planned" as const,
                display_title: session.title,
                sport_key: session.sport_key,
                status: session.status,
                scheduled_start_utc: session.scheduled_start_utc,
                scheduled_date: session.scheduled_date,
                time_window_start_utc: session.time_window_start_utc,
                time_window_end_utc: session.time_window_end_utc,
                duration_s: session.expected_duration_s,
                detail_id: session.id,
              }));
          }
        }
        async function facilityLayer(): Promise<FacilityCalendarLayerItem[]> {
          if (!facilityPreferences.show_family_swimming && !facilityPreferences.show_personal_facilities) return [];
          try {
            return await api<FacilityCalendarLayerItem[]>(
              `/facilities/calendar-layer?start=${start}&end=${end}`,
              { signal: controller.signal },
            );
          } catch {
            return [];
          }
        }
        const timezone = Intl.DateTimeFormat().resolvedOptions().timeZone || "Europe/London";
        const coreRequest = Promise.all([
          api<CalendarEvent[]>(
            `/calendar/?start=${calendarStart}&end=${calendarEnd}&limit=200`,
            { signal: controller.signal },
          ),
          api<FamilyTask[]>("/tasks/?status=pending&limit=200", { signal: controller.signal }),
        ]);
        const optionalRequest = Promise.all([
          optional<ActiveRoutine>(`/routines/active?start=${start}&end=${end}`),
          optional<HandoffOccurrence>(`/routines/handoffs?start=${start}&end=${end}`),
          optional<PrepPackSuggestion>(`/prep-packs/suggestions?timezone=${encodeURIComponent(timezone)}&horizon_days=14`),
          fitnessLayer(),
          facilityLayer(),
        ]);
        const [calendarItems, taskItems] = await coreRequest;
        if (generation !== loadGeneration.current) return;
        setEvents(calendarItems);
        setTasks(taskItems);
        setLoading(false);
        const [routineItems, handoffItems, prepItems, nextFitnessItems, facilityItems] = await optionalRequest;
        if (generation !== loadGeneration.current) return;
        setEvents([...calendarItems, ...facilityItems.map(facilityCalendarEvent)]);
        setRoutines(routineItems);
        setHandoffs(handoffItems);
        setPrepSuggestions(prepItems);
        setFitnessItems(nextFitnessItems);
        setTermDates([]);
        setHolidayDates([]);
      }
    } catch (requestError) {
      if (controller.signal.aborted) return;
      if (generation !== loadGeneration.current) return;
      setError(requestError instanceof Error ? requestError.message : "The planner is unavailable.");
    } finally {
      if (generation === loadGeneration.current) setLoading(false);
    }
  }, [anchor, facilityPreferences.show_family_swimming, facilityPreferences.show_personal_facilities, interval.end, interval.start, mode, showFitnessCompleted, showFitnessTraining]);

  const lastRevision = useRef(revision);
  useEffect(() => {
    // Revision bumps come from dialog-driven mutations; refresh without
    // blanking the calendar to a skeleton.
    const background = revision !== lastRevision.current;
    lastRevision.current = revision;
    void load(background);
  }, [load, revision]);

  useEffect(() => () => loadAbort.current?.abort(), []);

  useEffect(() => {
    if (!notice) return;
    const timeout = window.setTimeout(() => setNotice(null), 3_500);
    return () => window.clearTimeout(timeout);
  }, [notice]);

  const memberIndex = useMemo(
    () => new Map(members.map((member, index) => [member.id, index % 5])),
    [members],
  );
  const childIDs = useMemo(() => new Set(members.filter((member) => member.member_type === "child").map((member) => member.id)), [members]);

  function participantLabel(event: CalendarEvent): string {
    const participantIDs = eventParticipantIDs(event);
    if (!participantIDs.size) return "Everyone";
    const names = members.filter((member) => participantIDs.has(member.id)).map((member) => member.name);
    return names.length ? names.join(" & ") : "Family members";
  }

  function affectedLabel(event: CalendarEvent): string | null {
    const names = members
      .filter((member) => event.affected_member_ids?.includes(member.id))
      .map((member) => member.name);
    return names.length ? names.join(" & ") : null;
  }

  function eventColorIndex(event: CalendarEvent): number {
    const firstParticipant = members.find((member) => eventParticipantIDs(event).has(member.id));
    return memberIndex.get(firstParticipant?.id ?? "") ?? 0;
  }

  const eventMatchesFilter = useCallback((event: CalendarEvent) => {
    if (!showMoney && event.event_type === "finance_commitment") return false;
    if (!showDeliveries && event.event_type === "finance_delivery") return false;
    if (memberFilter === "all") return true;
    const assignments = eventParticipantIDs(event);
    if (memberFilter === "shared") return assignments.size === 0;
    if (memberFilter === "kids") return [...assignments].some((id) => childIDs.has(id as string));
    return assignments.has(memberFilter) || Boolean(event.affected_member_ids?.includes(memberFilter));
  }, [childIDs, memberFilter, showDeliveries, showMoney]);

  const taskMatchesFilter = useCallback((task: FamilyTask) => {
    if (memberFilter === "all") return true;
    const assignments = new Set([task.assigned_to, ...task.assignees.map((assignee) => assignee.assignee_id)].filter(Boolean));
    if (memberFilter === "shared") return assignments.size === 0;
    if (memberFilter === "kids") return [...assignments].some((id) => childIDs.has(id as string));
    return assignments.has(memberFilter);
  }, [childIDs, memberFilter]);

  const visibleEvents = useMemo(() => events.filter(eventMatchesFilter), [eventMatchesFilter, events]);
  const visibleRoutines = useMemo(() => routines.filter((routine) => {
    if (memberFilter === "all") return true;
    if (memberFilter === "shared") return false;
    if (memberFilter === "kids") return childIDs.has(routine.person_id);
    return routine.person_id === memberFilter;
  }), [childIDs, memberFilter, routines]);
  const eventsByDay = useMemo(() => {
    const map = new Map<string, CalendarEvent[]>();
    for (const event of visibleEvents) {
      for (const key of eventCalendarDayKeys(event, interval.start, interval.end)) {
        const list = map.get(key);
        if (list) list.push(event);
        else map.set(key, [event]);
      }
    }
    for (const list of map.values()) {
      list.sort((left, right) => {
        if (left.all_day !== right.all_day) return left.all_day ? -1 : 1;
        return left.start_time.localeCompare(right.start_time);
      });
    }
    return map;
  }, [interval.end, interval.start, visibleEvents]);
  const routinesByDay = useMemo(() => {
    const map = new Map<string, ActiveRoutine[]>();
    for (const routine of visibleRoutines) {
      const list = map.get(routine.date);
      if (list) list.push(routine);
      else map.set(routine.date, [routine]);
    }
    return map;
  }, [visibleRoutines]);
  const handoffsByDay = useMemo(() => {
    const map = new Map<string, HandoffOccurrence[]>();
    for (const handoff of handoffs) {
      const list = map.get(handoff.date);
      if (list) list.push(handoff);
      else map.set(handoff.date, [handoff]);
    }
    for (const list of map.values()) list.sort((left, right) => left.time_of_day.localeCompare(right.time_of_day));
    return map;
  }, [handoffs]);
  const prepByDay = useMemo(() => {
    const map = new Map<string, PrepPackSuggestion[]>();
    for (const prep of prepSuggestions) {
      const key = localISODate(parseISO(prep.event_start));
      const list = map.get(key);
      if (list) list.push(prep);
      else map.set(key, [prep]);
    }
    return map;
  }, [prepSuggestions]);
  const visibleFitnessItems = useMemo(() => fitnessItems.filter((item) => {
    if (memberFilter === "all") return true;
    if (memberFilter === "kids" || memberFilter === "shared") return false;
    return (item.owner_user_id || signedInUserId) === memberFilter;
  }), [fitnessItems, memberFilter, signedInUserId]);
  const fitnessByDay = useMemo(() => {
    const map = new Map<string, FitnessCalendarLayerItem[]>();
    for (const item of visibleFitnessItems) {
      const key = localISODate(fitnessLayerDate(item));
      const list = map.get(key);
      if (list) list.push(item);
      else map.set(key, [item]);
    }
    for (const list of map.values()) list.sort((left, right) => fitnessLayerDate(left).valueOf() - fitnessLayerDate(right).valueOf());
    return map;
  }, [visibleFitnessItems]);
  const eventsForDay = useCallback((day: Date) => eventsByDay.get(localISODate(day)) ?? [], [eventsByDay]);
  const routinesForDay = useCallback((day: Date) => routinesByDay.get(localISODate(day)) ?? [], [routinesByDay]);
  const handoffsForDay = useCallback((day: Date) => handoffsByDay.get(localISODate(day)) ?? [], [handoffsByDay]);
  const prepForDay = useCallback((day: Date) => prepByDay.get(localISODate(day)) ?? [], [prepByDay]);
  const fitnessForDay = useCallback((day: Date) => fitnessByDay.get(localISODate(day)) ?? [], [fitnessByDay]);
  const tasksForDay = useCallback((day: Date) => tasks
    .filter(taskMatchesFilter)
    .filter((task) => task.due_date && isSameDay(parseISO(task.due_date), day))
    .sort((left, right) => (left.due_date ?? "9999").localeCompare(right.due_date ?? "9999")), [taskMatchesFilter, tasks]);

  function openFitnessLayerItem(item: FitnessCalendarLayerItem) {
    setActionError(null);
    setSelectedFitnessItem(item);
  }

  function openFitnessDestination(item: FitnessCalendarLayerItem) {
    const url = new URL(window.location.href);
    url.searchParams.set("view", "fitness");
    url.searchParams.set("section", item.layer_kind === "completed" ? "activity" : "training");
    url.searchParams.delete("event");
    url.searchParams.delete("event_date");
    if (item.layer_kind === "completed") url.searchParams.set("activity", item.detail_id);
    else url.searchParams.set("session", item.detail_id);
    window.history.pushState({}, "", url);
    window.dispatchEvent(new PopStateEvent("popstate"));
  }

  async function deletePlannedFitnessItem() {
    const item = fitnessItemToDelete;
    if (!item || item.layer_kind !== "planned" || fitnessDeleteBusy) return;
    setFitnessDeleteBusy(true);
    setActionError(null);
    try {
      await deleteFitnessRecord("planned_session", item.detail_id);
      setFitnessItems((current) => current.filter((candidate) => candidate.id !== item.id));
      setSelectedFitnessItem(null);
      setFitnessItemToDelete(null);
      setNotice(`“${item.display_title}” deleted.`);
      onDataChanged();
    } catch (requestError) {
      setActionError(requestError instanceof Error ? requestError.message : "The planned exercise could not be deleted.");
    } finally {
      setFitnessDeleteBusy(false);
    }
  }

  function fitnessOwnerLabel(item: FitnessCalendarLayerItem): string {
    const ownerId = item.owner_user_id || signedInUserId;
    return members.find((member) => member.id === ownerId)?.name ?? "You";
  }

  function fitnessColorIndex(item: FitnessCalendarLayerItem): number {
    const ownerId = item.owner_user_id || signedInUserId;
    return memberIndex.get(ownerId ?? "") ?? 0;
  }

  function fitnessKindLabel(item: FitnessCalendarLayerItem): string {
    return item.sport_key.replaceAll("_", " ");
  }

  const yearMembers = useMemo(() => members.filter((member) => {
    if (memberFilter === "all") return true;
    if (memberFilter === "kids") return member.member_type === "child";
    if (memberFilter === "shared") return false;
    return member.id === memberFilter;
  }), [memberFilter, members]);

  function move(direction: -1 | 1) {
    setAnchor((current) => {
      if (mode === "day") return addDays(current, direction);
      if (mode === "month") return addMonths(current, direction);
      if (mode === "agenda") return addDays(current, direction * 30);
      if (mode === "year") return addYears(current, direction);
      return addWeeks(current, direction);
    });
  }

  function openDay(day: Date) {
    setAnchor(startOfDay(day));
    setMode("day");
  }

  function openNewEvent(day = anchor) {
    setActionError(null);
    setSelectedEvent(null);
    setEditingEvent(null);
    setEditingRecurrenceScope(null);
    setEditorDate(day);
    setEditorOpen(true);
  }

  function needsRecurrenceScope(event: CalendarEvent): boolean {
    return event.is_generated_occurrence === true && Boolean(event.series_id);
  }

  function requestRecurringAction(event: CalendarEvent, action: RecurringEventAction) {
    setSelectedEvent(null);
    setActionError(null);
    if (needsRecurrenceScope(event)) {
      setRecurrencePrompt({ event, action });
      return;
    }
    if (action === "edit") openEditEvent(event);
    else setEventToDelete(event);
  }

  function openEditEvent(
    event: CalendarEvent,
    recurrenceScope: CalendarRecurrenceMutationScope | null = null,
  ) {
    setActionError(null);
    setSelectedEvent(null);
    setEditingEvent(event);
    setEditingRecurrenceScope(recurrenceScope);
    setEditorDate(eventDate(event));
    setEditorOpen(true);
  }

  async function completeTask(task: FamilyTask) {
    setTasks((current) => current.filter((item) => item.id !== task.id));
    try {
      await api(`/tasks/${task.id}/complete`, { method: "PATCH" });
    } catch (requestError) {
      setTasks((current) => [task, ...current]);
      setActionError(requestError instanceof Error ? requestError.message : "That task could not be completed.");
    }
  }

  async function changeRugbyVenue(event: CalendarEvent) {
    if (!event.rugby_venue || rugbyVenueBusy) return;
    const nextVenue = event.rugby_venue === "home" ? "away" : "home";
    setRugbyVenueBusy(true);
    setActionError(null);
    try {
      const updated = await api<CalendarEvent>(`/calendar/rugby/fixtures/${event.id}/venue`, {
        method: "PUT",
        body: JSON.stringify({ venue: nextVenue }),
      });
      setEvents((current) => current.map((item) => item.id === updated.id ? updated : item));
      setSelectedEvent(updated);
      setNotice(`Fixture marked ${nextVenue.toUpperCase()}.`);
      onDataChanged();
    } catch (requestError) {
      setActionError(requestError instanceof Error ? requestError.message : "The fixture venue could not be changed.");
    } finally {
      setRugbyVenueBusy(false);
    }
  }

  async function toggleProjectionPreference(kind: "money" | "deliveries") {
    if (!financeEnabled || projectionPreferenceBusy) return;
    const previousMoney = showMoney;
    const previousDeliveries = showDeliveries;
    const nextMoney = kind === "money" ? !showMoney : showMoney;
    const nextDeliveries = kind === "deliveries" ? !showDeliveries : showDeliveries;
    setProjectionPreferenceBusy(true);
    setActionError(null);
    setShowMoney(nextMoney);
    setShowDeliveries(nextDeliveries);
    try {
      const updated = await api<FinanceProjectionPreferences>("/finance/projection-preferences", {
        method: "PATCH",
        body: JSON.stringify({ show_money: nextMoney, show_deliveries: nextDeliveries }),
      });
      setShowMoney(updated.show_money);
      setShowDeliveries(updated.show_deliveries);
      if (
        (kind === "money" && updated.show_money)
        || (kind === "deliveries" && updated.show_deliveries)
      ) await load(true);
    } catch (requestError) {
      setShowMoney(previousMoney);
      setShowDeliveries(previousDeliveries);
      setActionError(requestError instanceof Error ? requestError.message : "The money and deliveries setting could not be saved.");
    } finally {
      setProjectionPreferenceBusy(false);
    }
  }

  function toggleFitnessLayerPreference(kind: "training" | "completed") {
    const previousTraining = showFitnessTraining;
    const previousCompleted = showFitnessCompleted;
    const nextTraining = kind === "training" ? !showFitnessTraining : showFitnessTraining;
    const nextCompleted = kind === "completed" ? !showFitnessCompleted : showFitnessCompleted;
    setShowFitnessTraining(nextTraining);
    setShowFitnessCompleted(nextCompleted);
    const generation = ++fitnessPreferenceGeneration.current;
    void api<FitnessCalendarPreferences>("/fitness/calendar-preferences", {
      method: "PATCH",
      body: JSON.stringify({
        show_planned: nextTraining,
        show_completed: nextCompleted,
      }),
    }).then((preference) => {
      if (generation !== fitnessPreferenceGeneration.current) return;
      if (typeof preference.show_planned !== "boolean" || typeof preference.show_completed !== "boolean") {
        throw new Error("Invalid Fitness Calendar preference response");
      }
      setShowFitnessTraining(preference.show_planned);
      setShowFitnessCompleted(preference.show_completed);
    }).catch(() => {
      if (generation !== fitnessPreferenceGeneration.current) return;
      setShowFitnessTraining(previousTraining);
      setShowFitnessCompleted(previousCompleted);
    });
  }

  async function toggleFacilityPreference(kind: "family" | "personal") {
    if (facilityPreferenceBusy) return;
    const previous = facilityPreferences;
    const next = {
      show_family_swimming: kind === "family"
        ? !previous.show_family_swimming
        : previous.show_family_swimming,
      show_personal_facilities: kind === "personal"
        ? !previous.show_personal_facilities
        : previous.show_personal_facilities,
    };
    const generation = ++facilityPreferenceGeneration.current;
    setFacilityPreferences(next);
    setFacilityPreferenceBusy(true);
    setActionError(null);
    try {
      const saved = await api<FacilityCalendarPreferences>("/facilities/calendar-preferences", {
        method: "PATCH",
        body: JSON.stringify(next),
      });
      if (generation === facilityPreferenceGeneration.current) setFacilityPreferences(saved);
    } catch (requestError) {
      if (generation === facilityPreferenceGeneration.current) setFacilityPreferences(previous);
      setActionError(requestError instanceof Error ? requestError.message : "Example School calendar visibility could not be saved.");
    } finally {
      if (generation === facilityPreferenceGeneration.current) setFacilityPreferenceBusy(false);
    }
  }

  async function previewFacilityImport(file: File) {
    setCalendarDisplayOpen(false);
    setFacilityImportFile(file);
    setFacilityImportPreview(null);
    setFacilityImportError(null);
    setFacilityImportOpen(true);
    setFacilityImportBusy(true);
    try {
      const form = new FormData();
      form.append("file", file);
      const preview = await api<FacilityImportPreview>("/facilities/example_school/preview", {
        method: "POST",
        body: form,
        timeoutMs: 60_000,
      }, true, false);
      setFacilityImportPreview(preview);
    } catch (requestError) {
      setFacilityImportError(requestError instanceof Error ? requestError.message : "The timetable could not be read.");
    } finally {
      setFacilityImportBusy(false);
    }
  }

  async function openHandoffSetup() {
    setCalendarDisplayOpen(false);
    setHandoffSetupOpen(true);
    setHandoffScheduleBusy(true);
    setHandoffScheduleError(null);
    try {
      const schedule = await api<HandoffSchedule>("/routines/handoffs/schedule");
      const adults = members.filter((member) => member.member_type === "user");
      const children = members.filter((member) => member.member_type === "child");
      const fallbackWorkOwner = adults.find((member) => member.id === signedInUserId)?.id
        ?? adults[0]?.id
        ?? "";
      setPickupPersonTab((current) => current && children.some((child) => child.id === current) ? current : children[0]?.id ?? "");
      setWorkPersonTab((current) => current && adults.some((adult) => adult.id === current) ? current : fallbackWorkOwner);
      setHandoffPeople([
        ...children.map((child): HandoffPersonDraft => {
          const personItems = schedule.items.filter((item) => item.kind === "pickup" && item.term_person_id === child.id);
          return {
            kind: "pickup",
            personId: child.id,
            personName: child.name,
            days: handoffWeekdays.map((_, weekday) => {
              const item = personItems.find((candidate) => candidate.weekday === weekday);
              return { weekday, time: item?.time_of_day ?? "" };
            }),
          };
        }),
        ...adults.map((adult): HandoffPersonDraft => ({
          kind: "work_departure",
          personId: adult.id,
          personName: adult.name,
          days: handoffWeekdays.map((_, weekday) => {
            const item = schedule.items.find((candidate) => candidate.kind === "work_departure" && candidate.term_person_id === adult.id && candidate.weekday === weekday);
            return { weekday, time: item?.time_of_day ?? "" };
          }),
        })),
      ]);
    } catch (requestError) {
      setHandoffScheduleError(requestError instanceof Error ? requestError.message : "Handoffs could not be loaded.");
    } finally {
      setHandoffScheduleBusy(false);
    }
  }

  function updateHandoffDay(kind: HandoffKind, personId: string, weekday: number, values: Partial<HandoffDayDraft>) {
    setHandoffPeople((current) => current.map((person) => person.kind === kind && person.personId === personId
      ? { ...person, days: person.days.map((day) => day.weekday === weekday ? { ...day, ...values } : day) }
      : person));
  }

  async function saveHandoffSchedule() {
    setHandoffScheduleBusy(true);
    setHandoffScheduleError(null);
    const items = handoffPeople.flatMap((person) => person.days
      .filter((day) => day.time)
      .map((day): HandoffScheduleItemRequest => {
        const item: HandoffScheduleItemRequest = {
          kind: person.kind,
          weekday: day.weekday,
          time_of_day: day.time,
          term_person_id: person.personId,
        };
        if (person.kind === "work_departure") item.owner_user_id = person.personId;
        return item;
      }));
    try {
      await api<HandoffSchedule>("/routines/handoffs/schedule", {
        method: "PUT",
        body: JSON.stringify({
          items,
          client_id: "web",
          client_timestamp: new Date().toISOString(),
        }),
      });
      setHandoffSetupOpen(false);
      setNotice("Handoffs updated.");
      await load(true);
    } catch (requestError) {
      setHandoffScheduleError(requestError instanceof Error ? requestError.message : "Handoffs could not be saved.");
    } finally {
      setHandoffScheduleBusy(false);
    }
  }

  function openHandoffEditor(handoff: HandoffOccurrence) {
    setCoordinationDate(null);
    setHandoffEditTime(handoff.time_of_day);
    setEditingHandoff(handoff);
  }

  async function saveHandoffDay(isCancelled = false) {
    if (!editingHandoff || !handoffEditTime) return;
    setHandoffEditBusy(true);
    setActionError(null);
    try {
      await api<HandoffOccurrence | null>(
        `/routines/handoffs/${editingHandoff.handoff_id}/dates/${editingHandoff.date}`,
        {
          method: "PUT",
          body: JSON.stringify({
            time_of_day: handoffEditTime,
            owner_user_id: editingHandoff.kind === "work_departure"
              ? editingHandoff.term_person_id
              : undefined,
            is_cancelled: isCancelled,
            client_id: "web",
            client_timestamp: new Date().toISOString(),
          }),
        },
      );
      setEditingHandoff(null);
      setNotice(isCancelled ? "Handoff hidden for that day." : "Handoff changed for that day.");
      await load(true);
    } catch (requestError) {
      setActionError(requestError instanceof Error ? requestError.message : "That handoff could not be changed.");
    } finally {
      setHandoffEditBusy(false);
    }
  }

  async function clearHandoffDayChange() {
    if (!editingHandoff?.is_override) return;
    setHandoffEditBusy(true);
    setActionError(null);
    try {
      await api<HandoffOccurrence | null>(
        `/routines/handoffs/${editingHandoff.handoff_id}/dates/${editingHandoff.date}`,
        { method: "DELETE" },
      );
      setEditingHandoff(null);
      setNotice("Weekly time restored.");
      await load(true);
    } catch (requestError) {
      setActionError(requestError instanceof Error ? requestError.message : "The weekly time could not be restored.");
    } finally {
      setHandoffEditBusy(false);
    }
  }

  async function confirmFacilityImport() {
    if (!facilityImportFile || !facilityImportPreview?.can_confirm || facilityImportBusy) return;
    setFacilityImportBusy(true);
    setFacilityImportError(null);
    try {
      const form = new FormData();
      form.append("file", facilityImportFile);
      form.append("expected_sha256", facilityImportPreview.sha256);
      const result = await api<FacilityImportResult>("/facilities/example_school/import", {
        method: "POST",
        body: form,
        timeoutMs: 90_000,
      }, true, false);
      setFacilityImportOpen(false);
      setFacilityImportFile(null);
      setFacilityImportPreview(null);
      setNotice(result.imported ? "Example School swimming and weights times updated." : "That Example School timetable is already current.");
      await load(true);
      onDataChanged();
    } catch (requestError) {
      setFacilityImportError(requestError instanceof Error ? requestError.message : "The timetable could not be imported.");
    } finally {
      setFacilityImportBusy(false);
    }
  }

  async function openClubs() {
    setCalendarDisplayOpen(false);
    setClubsOpen(true);
    setClubsBusy(true);
    setClubsError(null);
    try {
      setClubs(await api<SchoolClub[]>("/clubs/"));
    } catch (requestError) {
      setClubsError(requestError instanceof Error ? requestError.message : "Clubs could not be loaded.");
    } finally {
      setClubsBusy(false);
    }
  }

  function newClub() {
    const firstChild = members.find((member) => member.member_type === "child");
    setClubDraft({ name: "", childId: firstChild?.id ?? "", weekday: 0, startTime: "15:30", endTime: "16:30" });
    setClubsError(null);
    setEditingClub("new");
  }

  function editClub(club: SchoolClub) {
    setClubDraft({ name: club.name, childId: club.child_id, weekday: club.weekday, startTime: club.start_time, endTime: club.end_time });
    setClubsError(null);
    setEditingClub(club);
  }

  async function saveClub() {
    if (!clubDraft.name.trim() || !clubDraft.childId || !clubDraft.startTime || !clubDraft.endTime || clubsBusy) return;
    if (clubDraft.endTime <= clubDraft.startTime) {
      setClubsError("End time must be later than start time.");
      return;
    }
    setClubsBusy(true);
    setClubsError(null);
    const editing = editingClub !== "new" ? editingClub : null;
    const id = editing?.id ?? crypto.randomUUID();
    const body = {
      ...(editing ? {} : { id }),
      name: clubDraft.name.trim(),
      child_id: clubDraft.childId,
      weekday: clubDraft.weekday,
      start_time: clubDraft.startTime,
      end_time: clubDraft.endTime,
      client_id: `web:${id}`,
      client_timestamp: new Date().toISOString(),
    };
    try {
      const saved = await api<SchoolClub | { queued_offline: true }>(editing ? `/clubs/${id}` : "/clubs/", {
        method: editing ? "PUT" : "POST",
        body: JSON.stringify(body),
      });
      const childName = members.find((member) => member.id === clubDraft.childId)?.name ?? "Child";
      const next: SchoolClub = "queued_offline" in saved ? {
        id,
        name: body.name,
        child_id: body.child_id,
        child_name: childName,
        weekday: body.weekday,
        start_time: body.start_time,
        end_time: body.end_time,
        active_from: editing?.active_from ?? localISODate(new Date()),
        active_until: editing?.active_until,
        location: editing?.location,
        color: editing?.color ?? "#2563EB",
      } : saved;
      setClubs((current) => [...current.filter((club) => club.id !== id), next].sort((left, right) => left.child_name.localeCompare(right.child_name) || left.weekday - right.weekday || left.start_time.localeCompare(right.start_time)));
      setEditingClub(null);
      setNotice(editing ? "Club updated." : "Club added.");
      await load(true);
      onDataChanged();
    } catch (requestError) {
      setClubsError(requestError instanceof Error ? requestError.message : "The club could not be saved.");
    } finally {
      setClubsBusy(false);
    }
  }

  async function deleteClub() {
    if (!clubToDelete || clubsBusy) return;
    setClubsBusy(true);
    setClubsError(null);
    try {
      await api(`/clubs/${clubToDelete.id}`, { method: "DELETE" });
      setClubs((current) => current.filter((club) => club.id !== clubToDelete.id));
      setClubToDelete(null);
      setNotice("Club removed.");
      await load(true);
      onDataChanged();
    } catch (requestError) {
      setClubsError(requestError instanceof Error ? requestError.message : "The club could not be removed.");
    } finally {
      setClubsBusy(false);
    }
  }

  async function changeClubOccurrence(event: CalendarEvent) {
    const clubID = event.managed_source?.source_id;
    if (!clubID || clubOccurrenceBusy) return;
    const day = localISODate(eventDate(event));
    const restoring = event.event_type === "school_club_cancelled";
    setClubOccurrenceBusy(true);
    setActionError(null);
    try {
      await api(`/clubs/${clubID}/dates/${day}/cancel`, restoring ? { method: "DELETE" } : {
        method: "PUT",
        body: JSON.stringify({ client_id: `web:${clubID}:${day}`, client_timestamp: new Date().toISOString() }),
      });
      setSelectedEvent(null);
      setNotice(restoring ? "Club restored." : "Club marked cancelled.");
      await load(true);
      onDataChanged();
    } catch (requestError) {
      setActionError(requestError instanceof Error ? requestError.message : "That club date could not be changed.");
    } finally {
      setClubOccurrenceBusy(false);
    }
  }

  async function openToast() {
    setCalendarDisplayOpen(false);
    setToastOpen(true);
    setToastBusy(true);
    setToastError(null);
    try {
      setToastStatus(await api<ToastImportStatus[]>("/toast-club/status"));
    } catch (requestError) {
      setToastError(requestError instanceof Error ? requestError.message : "Toast bookings could not be loaded.");
    } finally {
      setToastBusy(false);
    }
  }

  async function previewToastImport(file: File) {
    setToastOpen(true);
    setToastFile(file);
    setToastPreview(null);
    setToastError(null);
    setToastBusy(true);
    try {
      const form = new FormData();
      form.append("file", file);
      setToastPreview(await api<ToastImportPreview>("/toast-club/preview", {
        method: "POST",
        body: form,
        timeoutMs: 60_000,
      }, true, false));
    } catch (requestError) {
      setToastError(requestError instanceof Error ? requestError.message : "The Toast form could not be read.");
    } finally {
      setToastBusy(false);
    }
  }

  async function confirmToastImport() {
    if (!toastFile || !toastPreview?.can_confirm || toastBusy) return;
    setToastBusy(true);
    setToastError(null);
    try {
      const form = new FormData();
      form.append("file", toastFile);
      form.append("expected_sha256", toastPreview.sha256);
      form.append("client_id", `web:${crypto.randomUUID()}`);
      form.append("client_timestamp", new Date().toISOString());
      const result = await api<ToastImportResult>("/toast-club/import", {
        method: "POST",
        body: form,
        timeoutMs: 90_000,
      }, true, false);
      setToastPreview(null);
      setToastFile(null);
      setToastStatus(await api<ToastImportStatus[]>("/toast-club/status"));
      setNotice(result.imported ? `${result.preview.child_name}’s Toast dates added.` : "That Toast form is already current.");
      await load(true);
      onDataChanged();
    } catch (requestError) {
      setToastError(requestError instanceof Error ? requestError.message : "The Toast form could not be imported.");
    } finally {
      setToastBusy(false);
    }
  }

  function attentionTaskContent(task: FamilyTask) {
    const content = <><strong>{task.title}</strong><span>{dueLabel(task.due_date)}</span></>;
    return task.managed_source
      ? <a href={task.managed_source.deep_link} aria-label={`Open ${task.title} in Finance`}>{content}</a>
      : <div>{content}</div>;
  }

  async function deleteEvent(
    event: CalendarEvent | null = eventToDelete,
    recurrenceScope: CalendarRecurrenceMutationScope | null = null,
  ) {
    if (!event) return;
    const eventID = event.series_id ?? event.id;
    const scopedOccurrence = needsRecurrenceScope(event);
    if (scopedOccurrence && !recurrenceScope) {
      setActionError("Choose which repeating events to delete.");
      return;
    }
    setDeleting(true);
    setActionError(null);
    try {
      if (scopedOccurrence) {
        await api(`/calendar/${eventID}/occurrences/delete`, {
          method: "POST",
          body: JSON.stringify({
            scope: recurrenceScope,
            occurrence_start: event.start_time,
            client_id: crypto.randomUUID(),
            client_timestamp: new Date().toISOString(),
          }),
        }, true, false);
      } else {
        await api(`/calendar/${eventID}`, { method: "DELETE" });
      }
      setEvents((current) => current.filter((candidate) => {
        if (!scopedOccurrence || recurrenceScope === "entire_series") {
          return candidate.id !== eventID && candidate.series_id !== eventID;
        }
        if (candidate.id === event.id) return false;
        if (recurrenceScope === "this_and_later" && candidate.series_id === eventID) {
          return eventDate(candidate) < eventDate(event);
        }
        return true;
      }));
      setEventToDelete(null);
      setRecurrencePrompt(null);
      setNotice(scopedOccurrence || event.recurrence_rule ? "Repeating event deleted." : "Event deleted.");
      onDataChanged();
    } catch (requestError) {
      setActionError(requestError instanceof Error ? requestError.message : "The event could not be deleted.");
    } finally {
      setDeleting(false);
    }
  }

  const days = useMemo(() => eachDayOfInterval(interval), [interval]);
  const attentionTasks = useMemo(() => tasks
    .filter(taskMatchesFilter)
    .filter((task) => !task.actionable_from || !isBefore(new Date(), parseISO(task.actionable_from)))
    .filter((task) => !task.due_date || parseISO(task.due_date) <= endOfWeek(new Date(), { weekStartsOn: 1 }))
    .sort((left, right) => (left.due_date ?? "9999").localeCompare(right.due_date ?? "9999")), [taskMatchesFilter, tasks]);
  const planItemsForDay = useCallback((day: Date): DayPlanItem[] => {
    const items: DayPlanItem[] = [];
    const dayEvents = eventsForDay(day);
    const toastEvents = dayEvents.filter(isToastEvent).sort((left, right) => left.start_time.localeCompare(right.start_time));
    const dayHandoffs = handoffsForDay(day);
    if (toastEvents.length || dayHandoffs.length) items.push({
      kind: "coordination",
      at: Math.min(
        ...toastEvents.map((event) => eventDate(event).valueOf()),
        ...dayHandoffs.map((handoff) => localTimeOnDay(day, handoff.time_of_day)),
      ),
      handoffs: dayHandoffs,
      toast: toastEvents,
    });
    for (const event of dayEvents.filter((item) => !isToastEvent(item))) {
      items.push({
        kind: "event",
        at: event.all_day || event.start_time.length === 10
          ? startOfDay(day).valueOf()
          : eventDate(event).valueOf(),
        event,
      });
    }
    for (const fitness of fitnessForDay(day)) {
      items.push({ kind: "fitness", at: fitnessLayerDate(fitness).valueOf(), fitness });
    }
    for (const routine of routinesForDay(day)) {
      const routineTime = routine.time ?? routine.time_of_day;
      items.push({
        kind: "routine",
        at: routineTime ? localTimeOnDay(day, routineTime) : localTimeOnDay(day, "23:55"),
        routine,
        timeLabel: routineTime ?? "Any time",
      });
    }
    for (const task of tasksForDay(day)) {
      const parsed = task.due_date ? parseISO(task.due_date) : null;
      const timed = Boolean(task.due_date && task.due_date.length > 10 && parsed && !Number.isNaN(parsed.getTime()));
      items.push({
        kind: "task",
        at: timed && parsed ? parsed.valueOf() : localTimeOnDay(day, "17:00"),
        task,
        timeLabel: timed && parsed ? format(parsed, "HH:mm") : "Due today",
      });
    }
    for (const prep of prepForDay(day)) {
      const eventStart = parseISO(prep.event_start);
      const timed = !prep.event_all_day && !Number.isNaN(eventStart.getTime());
      items.push({
        kind: "prep",
        at: timed ? eventStart.valueOf() - 1 : localTimeOnDay(day, "07:30"),
        prep,
        timeLabel: timed ? `Before ${format(eventStart, "HH:mm")}` : "Prepare",
      });
    }
    const kindOrder: Record<DayPlanItem["kind"], number> = {
      prep: 0,
      event: 1,
      coordination: 2,
      fitness: 3,
      routine: 4,
      task: 5,
    };
    return items.sort((left, right) => left.at - right.at || kindOrder[left.kind] - kindOrder[right.kind]);
  }, [eventsForDay, fitnessForDay, handoffsForDay, prepForDay, routinesForDay, tasksForDay]);
  const dayPlan = useMemo(() => planItemsForDay(anchor), [anchor, planItemsForDay]);
  const pickupDraft = handoffPeople.find((person) => person.kind === "pickup" && person.personId === pickupPersonTab);
  const workDraft = handoffPeople.find((person) => person.kind === "work_departure" && person.personId === workPersonTab);
  const coordinationHandoffs = coordinationDate ? handoffsForDay(coordinationDate) : [];
  const coordinationToast = coordinationDate ? eventsForDay(coordinationDate).filter(isToastEvent) : [];

  const selectedEventAttachments = useMemo(() => {
    if (!selectedEvent) return [];
    if (selectedEvent.attachments?.length) return selectedEvent.attachments;
    return selectedEvent.source_document ? [{
      ...selectedEvent.source_document,
      relation_id: `legacy:${selectedEvent.id}:${selectedEvent.source_document.id}`,
      role: "other" as const,
      position: 0,
    }] : [];
  }, [selectedEvent]);
  const selectedEventBaseID = selectedEvent?.series_id ?? selectedEvent?.id;
  const selectedEventTasks = useMemo(() => {
    if (!selectedEventBaseID || !selectedEvent) return [];
    return tasks.filter((task) => {
      if (task.source_event_id !== selectedEventBaseID) return false;
      if (!task.prep_occurrence_id) return true;
      if (!task.prep_occurrence_start) return !selectedEvent.series_id;
      const occurrence = parseISO(task.prep_occurrence_start).valueOf();
      const selectedStart = parseISO(selectedEvent.start_time).valueOf();
      return !Number.isNaN(occurrence) && occurrence === selectedStart;
    });
  }, [selectedEvent, selectedEventBaseID, tasks]);
  const selectedEventRelatedTasks = useMemo(
    () => selectedEventTasks.filter((task) => !task.prep_occurrence_id),
    [selectedEventTasks],
  );
  const selectedEventPackingTasks = useMemo(
    () => selectedEventTasks.filter((task) => Boolean(task.prep_occurrence_id)),
    [selectedEventTasks],
  );
  const selectedEventPrep = useMemo(
    () => selectedEventBaseID && selectedEvent ? prepSuggestions.filter((prep) => {
      if (prep.event_id !== selectedEventBaseID) return false;
      if (!selectedEvent.series_id) return true;
      const occurrence = parseISO(prep.occurrence_start).valueOf();
      const selectedStart = parseISO(selectedEvent.start_time).valueOf();
      return !Number.isNaN(occurrence) && occurrence === selectedStart;
    }) : [],
    [prepSuggestions, selectedEvent, selectedEventBaseID],
  );
  const selectedEventClashes = useMemo(() => {
    if (!selectedEvent) return [];
    const selectedInterval = eventInterval(selectedEvent);
    const selectedPeople = eventParticipantIDs(selectedEvent);
    return visibleEvents.filter((candidate) => {
      if (candidate.id === selectedEvent.id) return false;
      if ((isToastEvent(selectedEvent) && isSchoolClubEvent(candidate))
        || (isSchoolClubEvent(selectedEvent) && isToastEvent(candidate))) return false;
      const candidateInterval = eventInterval(candidate);
      if (candidateInterval.start >= selectedInterval.end || candidateInterval.end <= selectedInterval.start) return false;
      const candidatePeople = eventParticipantIDs(candidate);
      return !selectedPeople.size || !candidatePeople.size
        || [...selectedPeople].some((personID) => candidatePeople.has(personID));
    });
  }, [selectedEvent, visibleEvents]);

  function openPrepEvent(prep: PrepPackSuggestion) {
    const exact = events.find((event) => event.id === prep.event_id && event.start_time === prep.event_start)
      ?? events.find((event) => event.series_id === prep.event_id && event.start_time === prep.event_start)
      ?? events.find((event) => event.id === prep.event_id || event.series_id === prep.event_id);
    if (exact) setSelectedEvent(exact);
  }

  async function applyPrepSuggestion(prep: PrepPackSuggestion) {
    if (prepBusyId) return;
    setPrepBusyId(prep.id);
    setActionError(null);
    try {
      await api("/prep-packs/apply", {
        method: "POST",
        body: JSON.stringify(prepPackAction(prep)),
      });
      setPrepSuggestions((current) => current.filter((item) => item.id !== prep.id));
      await load(true);
      setNotice(`${prep.template_name} checklist added.`);
      onDataChanged();
    } catch (requestError) {
      setActionError(requestError instanceof Error ? requestError.message : "The checklist could not be added.");
    } finally {
      setPrepBusyId(null);
    }
  }

  function dayPlanRow(item: DayPlanItem, day: Date) {
    if (item.kind === "coordination") {
      return <CoordinationTimelineCard handoffs={item.handoffs} toast={item.toast} members={members} onOpen={() => setCoordinationDate(day)} key={`coordination-${localISODate(day)}`} />;
    }
    if (item.kind === "event") {
      const event = item.event;
      return <button type="button" className={cn("planner-day-event planner-plan-item", `member-color-${eventColorIndex(event)}`, event.rugby_venue === "away" && "is-away-rugby", isSchoolClubEvent(event) && "is-school-club", event.event_type === "school_club_cancelled" && "is-cancelled", isSchoolMilestone(event) && "is-school-milestone")} style={eventAccentStyle(event)} onClick={() => setSelectedEvent(event)} key={`event-${event.id}`}>{isSchoolMilestone(event) ? <span className="milestone-sprinkles" aria-hidden="true" /> : null}<time>{eventTimeLabelForDay(event, day)}</time><div><strong>{event.title}</strong><span>{[event.location, participantLabel(event), affectedLabel(event) ? `Affects ${affectedLabel(event)}` : null].filter(Boolean).join(" · ")}</span></div><ChevronRight aria-hidden="true" size={17} /></button>;
    }
    if (item.kind === "fitness") {
      return <button type="button" className={cn("planner-day-event planner-plan-item is-fitness", `member-color-${fitnessColorIndex(item.fitness)}`)} onClick={() => openFitnessLayerItem(item.fitness)} key={`fitness-${item.fitness.id}`}><time>{fitnessLayerTime(item.fitness)}</time><div><strong>{item.fitness.display_title}</strong><span className="fitness-event-meta"><Dumbbell aria-hidden="true" size={13} />{fitnessOwnerLabel(item.fitness)} · {fitnessKindLabel(item.fitness)}</span></div><ChevronRight aria-hidden="true" size={17} /></button>;
    }
    if (item.kind === "routine") {
      return <div className="planner-day-event planner-plan-item is-routine" style={{ borderLeftColor: item.routine.color }} key={`routine-${item.routine.routine_item_id}-${item.routine.date}`}><time>{item.timeLabel}</time><div><strong>{item.routine.name}</strong><span>{[`Routine · ${item.routine.person_name}`, item.routine.location, item.routine.preparation_note].filter(Boolean).join(" · ")}</span></div><Repeat2 aria-hidden="true" size={17} /></div>;
    }
    if (item.kind === "task") {
      return <div className="planner-day-event planner-plan-item is-task" key={`task-${item.task.id}`}><time>{item.timeLabel}</time><div><strong>{item.task.title}</strong><span>Task · {item.task.assignees.map((assignee) => assignee.assignee_name).filter(Boolean).join(" & ") || "Family"}</span></div><button type="button" className="task-check" aria-label={`Complete ${item.task.title}`} onClick={() => void completeTask(item.task)}><Check aria-hidden="true" size={17} /></button></div>;
    }
    return <button type="button" className="planner-day-event planner-plan-item is-prep" key={`prep-${item.prep.id}`} onClick={() => openPrepEvent(item.prep)}><time>{item.timeLabel}</time><div><strong>Prepare for {item.prep.event_title}</strong><span>{item.prep.items.join(" · ")}</span></div><ChevronRight aria-hidden="true" size={17} /></button>;
  }

  const heading = mode === "day"
    ? format(anchor, "EEEE, d MMMM yyyy")
    : mode === "year"
      ? format(anchor, "yyyy")
    : mode === "month"
      ? format(anchor, "MMMM yyyy")
      : `${format(interval.start, "d MMM")} – ${format(interval.end, "d MMM yyyy")}`;

  const filterOptions = useMemo<Array<{ id: MemberFilter; label: string; colorIndex?: number }>>(() => [
    { id: "all", label: "Family" },
    ...members.map((member, index) => ({ id: member.id, label: member.name, colorIndex: index % 5 })),
    ...(childIDs.size > 1 ? [{ id: "kids", label: "Kids" }] : []),
    { id: "shared", label: "Shared" },
  ], [childIDs.size, members]);

  return (
    <div className="planner-page">
      <header className="page-header planner-header">
        <div className="planner-title"><p className="page-eyebrow">Calendar</p><h1>{heading}</h1></div>
        <div className="planner-header-actions">
          {onOpenCycleTracking ? <IconButton label="Cycle" icon={CalendarHeart} onClick={onOpenCycleTracking} /> : null}
          <button type="button" className="button button--primary planner-new-event" aria-label="New event" onClick={() => openNewEvent()}><Plus aria-hidden="true" size={18} /><span>New event</span></button>
        </div>
      </header>

      <div className="planner-toolbar" aria-label="Calendar navigation">
        <div className="planner-date-controls">
          <button type="button" className="planner-today-button" onClick={() => setAnchor(startOfDay(new Date()))}>Today</button>
          <div className="planner-arrows"><IconButton label="Previous period" icon={ChevronLeft} onClick={() => move(-1)} /><IconButton label="Next period" icon={ChevronRight} onClick={() => move(1)} /></div>
        </div>
        <label className="planner-mobile-select planner-mobile-view">
          <span>View</span>
          <select aria-label="Calendar view" value={mode} onChange={(event) => setMode(event.target.value as PlannerMode)}>
            <option value="day">Day</option>
            <option value="week">Week</option>
            <option value="month">Month</option>
            <option value="agenda">Agenda</option>
            <option value="year">Year</option>
          </select>
        </label>
        <Segmented value={mode} onChange={setMode} label="Calendar view" options={[
          { value: "day", label: "Day" },
          { value: "week", label: "Week" },
          { value: "month", label: "Month" },
          { value: "agenda", label: "Agenda" },
          { value: "year", label: "Year" },
        ]} />
      </div>

      <div className="planner-filter-row">
        <label className="planner-mobile-select planner-mobile-person">
          <span>Show</span>
          <select aria-label="Filter calendar by family member" value={memberFilter} onChange={(event) => setMemberFilter(event.target.value)}>
            {filterOptions.map((option) => <option value={option.id} key={option.id}>{option.label}</option>)}
          </select>
        </label>
        <div className="planner-people-filter" role="group" aria-label="Filter calendar by family member">
          {filterOptions.map((option) => <button type="button" className={cn(memberFilter === option.id && "is-active", option.colorIndex != null && `member-color-${option.colorIndex}`)} aria-pressed={memberFilter === option.id} onClick={() => setMemberFilter(option.id)} key={option.id}>{option.colorIndex != null ? <span aria-hidden="true" /> : null}{option.label}</button>)}
        </div>
        <div className="planner-display-control" ref={calendarDisplayRef}>
          <button
            type="button"
            className={cn("planner-display-trigger", calendarDisplayOpen && "is-open")}
            aria-label="Choose calendars"
            aria-expanded={calendarDisplayOpen}
            aria-controls="planner-calendar-display"
            ref={calendarDisplayTriggerRef}
            onClick={() => setCalendarDisplayOpen((open) => !open)}
          >
            <SlidersHorizontal aria-hidden="true" size={16} />
            <span>Calendars</span>
            <ChevronDown aria-hidden="true" size={15} />
          </button>
          {calendarDisplayOpen ? <div className="planner-display-menu" id="planner-calendar-display" role="dialog" aria-labelledby="planner-calendar-display-title">
            <header>
              <div><strong id="planner-calendar-display-title">Calendars</strong><span>Choose what appears</span></div>
              <button type="button" className="planner-display-close" aria-label="Close calendar choices" onClick={() => { setCalendarDisplayOpen(false); calendarDisplayTriggerRef.current?.focus(); }}><X aria-hidden="true" size={17} /></button>
            </header>
            <div className="planner-layer-options">
              {financeEnabled ? <>
                <button type="button" className={cn("planner-layer-option", showMoney && "is-active")} aria-label="Money" aria-pressed={showMoney} aria-busy={projectionPreferenceBusy} disabled={projectionPreferenceBusy} onClick={() => void toggleProjectionPreference("money")}><span className="planner-layer-icon"><WalletCards aria-hidden="true" size={17} /></span><span><strong>Money</strong><small>Payments and renewals</small></span><span className="planner-layer-state" aria-hidden="true">{showMoney ? <Check size={15} /> : null}</span></button>
                <button type="button" className={cn("planner-layer-option", showDeliveries && "is-active")} aria-label="Deliveries" aria-pressed={showDeliveries} aria-busy={projectionPreferenceBusy} disabled={projectionPreferenceBusy} onClick={() => void toggleProjectionPreference("deliveries")}><span className="planner-layer-icon"><Truck aria-hidden="true" size={17} /></span><span><strong>Deliveries</strong><small>Expected arrivals</small></span><span className="planner-layer-state" aria-hidden="true">{showDeliveries ? <Check size={15} /> : null}</span></button>
              </> : null}
              <button type="button" className={cn("planner-layer-option", showFitnessTraining && "is-active")} aria-label="My training" aria-pressed={showFitnessTraining} onClick={() => toggleFitnessLayerPreference("training")}><span className="planner-layer-icon"><Dumbbell aria-hidden="true" size={17} /></span><span><strong>Training</strong><small>Planned sessions</small></span><span className="planner-layer-state" aria-hidden="true">{showFitnessTraining ? <Check size={15} /> : null}</span></button>
              <button type="button" className={cn("planner-layer-option", showFitnessCompleted && "is-active")} aria-label="Completed activity" aria-pressed={showFitnessCompleted} onClick={() => toggleFitnessLayerPreference("completed")}><span className="planner-layer-icon"><Activity aria-hidden="true" size={17} /></span><span><strong>Workouts</strong><small>Completed activities</small></span><span className="planner-layer-state" aria-hidden="true">{showFitnessCompleted ? <Check size={15} /> : null}</span></button>
              <button type="button" className={cn("planner-layer-option", facilityPreferences.show_family_swimming && "is-active")} aria-label="Family swimming" aria-pressed={facilityPreferences.show_family_swimming} aria-busy={facilityPreferenceBusy} disabled={facilityPreferenceBusy} onClick={() => void toggleFacilityPreference("family")}><span className="planner-layer-icon"><Waves aria-hidden="true" size={17} /></span><span><strong>Family swimming</strong><small>Example School pool availability</small></span><span className="planner-layer-state" aria-hidden="true">{facilityPreferences.show_family_swimming ? <Check size={15} /> : null}</span></button>
              <button type="button" className={cn("planner-layer-option", facilityPreferences.show_personal_facilities && "is-active")} aria-label="My Example School facilities" aria-pressed={facilityPreferences.show_personal_facilities} aria-busy={facilityPreferenceBusy} disabled={facilityPreferenceBusy} onClick={() => void toggleFacilityPreference("personal")}><span className="planner-layer-icon"><Dumbbell aria-hidden="true" size={17} /></span><span><strong>My Example School facilities</strong><small>Lane swim and weights</small></span><span className="planner-layer-state" aria-hidden="true">{facilityPreferences.show_personal_facilities ? <Check size={15} /> : null}</span></button>
            </div>
            <button type="button" className="planner-timetable-upload" onClick={() => void openHandoffSetup()}><Navigation aria-hidden="true" size={16} /><span><strong>Handoffs</strong><small>Pickup and leaving work</small></span></button>
            <button type="button" className="planner-timetable-upload" onClick={() => void openClubs()}><School aria-hidden="true" size={16} /><span><strong>Clubs</strong><small>Term-time activities</small></span></button>
            <button type="button" className="planner-timetable-upload" onClick={() => void openToast()}><Clock3 aria-hidden="true" size={16} /><span><strong>Toast Club</strong><small>Bookings and pickup windows</small></span></button>
            <button type="button" className="planner-timetable-upload" onClick={() => facilityFileInputRef.current?.click()}><Upload aria-hidden="true" size={16} /><span><strong>Update Example School timetable</strong><small>Upload the latest staff .docx</small></span></button>
          </div> : null}
          <input
            ref={facilityFileInputRef}
            className="sr-only"
            type="file"
            aria-label="Choose Example School timetable file"
            accept=".docx,application/vnd.openxmlformats-officedocument.wordprocessingml.document"
            onChange={(event) => {
              const file = event.target.files?.[0];
              event.target.value = "";
              if (file) void previewFacilityImport(file);
            }}
          />
          <input
            ref={toastFileInputRef}
            className="sr-only"
            type="file"
            aria-label="Choose Toast booking form"
            accept=".docx,application/vnd.openxmlformats-officedocument.wordprocessingml.document"
            onChange={(event) => {
              const file = event.target.files?.[0];
              event.target.value = "";
              if (file) void previewToastImport(file);
            }}
          />
        </div>
      </div>

      {error ? <ErrorState message={error} retry={load} /> : null}
      {actionError ? <div className="form-error planner-action-error" role="alert">{actionError}</div> : null}
      {notice ? <div className="form-success planner-notice" role="status">{notice}</div> : null}
      <div className={cn("planner-layout", mode === "year" && "is-year")}>
        <section className="calendar-surface" aria-label="Family calendar">
          {loading ? <SkeletonList rows={6} /> : null}

          {!loading && !error && mode === "day" ? (
            <div className="planner-day-view">
              <header><div><p className="page-eyebrow">Daily schedule</p><h2>{format(anchor, "EEEE, d MMMM")}</h2></div><button type="button" className="button button--primary button--compact" onClick={() => openNewEvent(anchor)}><CalendarPlus aria-hidden="true" size={17} /> Add event</button></header>
              <section aria-labelledby="day-plan-heading">
                <h3 id="day-plan-heading">The day</h3>
                {routinesForDay(anchor).length ? <h3 className="sr-only">Household plan</h3> : null}
                {!dayPlan.length ? <EmptyState title="Nothing planned" detail="This day is clear." action={() => openNewEvent(anchor)} actionLabel="Add an event" /> : null}
                <div className="planner-day-events planner-day-plan">
                  {dayPlan.map((item) => dayPlanRow(item, anchor))}
                </div>
              </section>
            </div>
          ) : null}

          {!loading && !error && mode === "week" ? (
            <div className="week-grid">
              {days.map((day) => {
                const dayEvents = eventsForDay(day);
                const toastEvents = dayEvents.filter(isToastEvent);
                const standardEvents = dayEvents.filter((event) => !isToastEvent(event));
                const dayRoutines = routinesForDay(day);
                const dayHandoffs = handoffsForDay(day);
                const dayFitness = fitnessForDay(day);
                return (
                  <section className={cn("week-day", isToday(day) && "is-today")} key={day.toISOString()}>
                    <button type="button" className="week-day-heading" aria-label={`Open ${format(day, "EEEE, d MMMM")}`} onClick={() => openDay(day)}><span>{format(day, "EEE")}</span><strong>{format(day, "d")}</strong></button>
                    <div className="day-events">
                      {dayHandoffs.length || toastEvents.length ? <CoordinationTimelineCard handoffs={dayHandoffs} toast={toastEvents} members={members} compact onOpen={() => setCoordinationDate(day)} /> : null}
                      {standardEvents.map((event) => <button type="button" className={cn("event-item", `member-color-${eventColorIndex(event)}`, event.rugby_venue === "away" && "is-away-rugby", isSchoolClubEvent(event) && "is-school-club", event.event_type === "school_club_cancelled" && "is-cancelled", isSchoolMilestone(event) && "is-school-milestone")} style={eventAccentStyle(event)} key={event.id} onClick={() => setSelectedEvent(event)}>{isSchoolMilestone(event) ? <span className="milestone-sprinkles" aria-hidden="true" /> : null}<time>{eventTimeLabelForDay(event, day)}</time><span>{event.title}</span></button>)}
                      {dayFitness.map((item) => <button type="button" className={cn("event-item is-fitness", `member-color-${fitnessColorIndex(item)}`)} key={`fitness-${item.id}`} onClick={() => openFitnessLayerItem(item)}><time>{fitnessLayerTime(item)}</time><span>{item.display_title}</span><small className="fitness-event-meta"><Dumbbell aria-hidden="true" size={12} />{fitnessOwnerLabel(item)}</small></button>)}
                      {dayRoutines.map((routine) => <div className="planner-context-item is-routine" style={{ borderLeftColor: routine.color }} key={`${routine.routine_item_id}-${routine.date}`}><small>Routine · {routine.person_name}</small><strong>{routine.name}</strong></div>)}
                      {!dayHandoffs.length && !dayEvents.length && !dayFitness.length && !dayRoutines.length ? <button type="button" className="day-empty" onClick={() => openNewEvent(day)}>Add event</button> : null}
                    </div>
                  </section>
                );
              })}
            </div>
          ) : null}

          {!loading && !error && mode === "month" ? (
            <div className="month-grid">
              {[
                "Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun",
              ].map((day) => <span className="month-weekday" key={day}>{day}</span>)}
              {days.map((day) => {
                const dayItems = planItemsForDay(day);
                const visibleItems = dayItems.slice(0, 3);
                const hiddenCount = dayItems.length - visibleItems.length;
                return <section className={cn("month-day", !isSameMonth(day, anchor) && "is-outside", isToday(day) && "is-today")} key={day.toISOString()}><button type="button" className="month-day-number" aria-label={`Open ${format(day, "EEEE, d MMMM")}`} onClick={() => openDay(day)}>{format(day, "d")}</button>{visibleItems.map((item) => {
                  if (item.kind === "coordination") return <button type="button" key={`coordination-${localISODate(day)}`} onClick={() => setCoordinationDate(day)} className="month-plan-context is-coordination"><span>Pickup</span>Leave &amp; collect</button>;
                  if (item.kind === "event") return <button type="button" key={`event-${item.event.id}`} onClick={() => setSelectedEvent(item.event)} className={cn("month-event", `member-color-${eventColorIndex(item.event)}`, item.event.rugby_venue === "away" && "is-away-rugby", isSchoolClubEvent(item.event) && "is-school-club", item.event.event_type === "school_club_cancelled" && "is-cancelled", isSchoolMilestone(item.event) && "is-school-milestone")} style={eventAccentStyle(item.event)}>{isSchoolMilestone(item.event) ? <span className="milestone-sprinkles" aria-hidden="true" /> : null}{item.event.title}</button>;
                  if (item.kind === "fitness") return <button type="button" key={`fitness-${item.fitness.id}`} onClick={() => openFitnessLayerItem(item.fitness)} className={cn("month-event is-fitness", `member-color-${fitnessColorIndex(item.fitness)}`)}>{item.fitness.display_title}</button>;
                  if (item.kind === "routine") return <button type="button" key={`routine-${item.routine.routine_item_id}`} onClick={() => openDay(day)} className="month-plan-context"><span>Routine</span>{item.routine.name}</button>;
                  if (item.kind === "task") return <button type="button" key={`task-${item.task.id}`} onClick={() => openDay(day)} className="month-plan-context"><span>Task</span>{item.task.title}</button>;
                  return <button type="button" key={`prep-${item.prep.id}`} onClick={() => openPrepEvent(item.prep)} className="month-plan-context"><span>Prep</span>{item.prep.event_title}</button>;
                })}{hiddenCount > 0 ? <button type="button" className="month-more" onClick={() => openDay(day)}>+{hiddenCount} more</button> : null}</section>;
              })}
            </div>
          ) : null}

          {!loading && !error && mode === "agenda" ? (
            <div className="agenda-list">
              {days.map((day) => {
                const dayEvents = eventsForDay(day);
                const toastEvents = dayEvents.filter(isToastEvent);
                const standardEvents = dayEvents.filter((event) => !isToastEvent(event));
                const dayFitness = fitnessForDay(day);
                const dayHandoffs = handoffsForDay(day);
                if (!dayEvents.length && !dayFitness.length && !dayHandoffs.length) return null;
                return <section className="agenda-day" key={day.toISOString()}><button type="button" className="agenda-day-heading" onClick={() => openDay(day)}><strong>{format(day, "EEEE")}</strong><span>{format(day, "d MMMM")}</span></button><div>{dayHandoffs.length || toastEvents.length ? <CoordinationTimelineCard handoffs={dayHandoffs} toast={toastEvents} members={members} onOpen={() => setCoordinationDate(day)} /> : null}{standardEvents.map((event) => <button type="button" className={cn("agenda-event", event.source_color && "has-source-color", event.rugby_venue === "away" && "is-away-rugby", isSchoolClubEvent(event) && "is-school-club", event.event_type === "school_club_cancelled" && "is-cancelled", isSchoolMilestone(event) && "is-school-milestone")} style={eventAccentStyle(event)} key={event.id} onClick={() => setSelectedEvent(event)}>{isSchoolMilestone(event) ? <span className="milestone-sprinkles" aria-hidden="true" /> : null}<time>{eventTimeLabelForDay(event, day)}</time><span>{event.title}</span><small>{participantLabel(event)}{affectedLabel(event) ? ` · Affects ${affectedLabel(event)}` : ""}</small></button>)}{dayFitness.map((item) => <button type="button" className={cn("agenda-event is-fitness", `member-color-${fitnessColorIndex(item)}`)} key={`fitness-${item.id}`} onClick={() => openFitnessLayerItem(item)}><time>{fitnessLayerTime(item)}</time><span>{item.display_title}</span><small className="fitness-event-meta"><Dumbbell aria-hidden="true" size={12} />{fitnessOwnerLabel(item)} · {fitnessKindLabel(item)}</small></button>)}</div></section>;
              })}
              {!eventsByDay.size && !fitnessByDay.size && !handoffsByDay.size ? <EmptyState title="Nothing planned" detail="This period is clear for this filter." action={() => openNewEvent(anchor)} actionLabel="Add an event" /> : null}
            </div>
          ) : null}

          {!loading && !error && mode === "year" ? (
            <div className="year-overview" aria-label={`Family year overview for ${anchor.getFullYear()}`}>
              <div className="year-overview-legend" aria-label="Year overview legend"><span className="is-term">Term</span><span className="is-day-off">Day off</span></div>
              {!yearMembers.length ? <EmptyState title="No people in this view" detail="Choose Family, Kids, or a person to see term and holiday dates." /> : null}
              {yearMembers.map((member) => {
                const memberTerms = termDates.filter((term) => term.person_id === member.id);
                const memberHolidays = holidayDates.filter((holiday) => holiday.person_id === member.id);
                return (
                  <section className="year-person" aria-labelledby={`year-person-${member.id}`} key={member.id}>
                    <h3 id={`year-person-${member.id}`}>{member.name}</h3>
                    <div className="year-month-grid">
                      {Array.from({ length: 12 }, (_, month) => {
                        const monthStart = new Date(anchor.getFullYear(), month, 1);
                        const monthEnd = new Date(anchor.getFullYear(), month + 1, 0);
                        const daysInMonth = monthEnd.getDate();
                        const terms = memberTerms.filter((term) => parseISO(term.start_date) <= monthEnd && parseISO(term.end_date) >= monthStart);
                        const holidays = memberHolidays.filter((holiday) => {
                          const date = parseISO(holiday.date);
                          return date >= monthStart && date <= monthEnd;
                        });
                        const descriptions = [
                          ...terms.map((term) => term.label || "Term"),
                          ...holidays.map((holiday) => holiday.label || "Day off"),
                        ];
                        return (
                          <div className="year-month" role="img" aria-label={`${member.name}, ${format(monthStart, "MMMM")}${descriptions.length ? `: ${descriptions.join(", ")}` : ": no dates"}`} key={month}>
                            <span>{format(monthStart, "MMM")}</span>
                            <div className="year-month-track" aria-hidden="true">
                              {terms.map((term) => {
                                const termStart = parseISO(term.start_date);
                                const termEnd = parseISO(term.end_date);
                                const startDay = termStart < monthStart ? 1 : termStart.getDate();
                                const endDay = termEnd > monthEnd ? daysInMonth : termEnd.getDate();
                                return <i className="year-term-segment" style={{ left: `${((startDay - 1) / daysInMonth) * 100}%`, width: `${((endDay - startDay + 1) / daysInMonth) * 100}%` }} key={term.id} />;
                              })}
                              {holidays.map((holiday) => {
                                const date = parseISO(holiday.date);
                                return <i className="year-holiday-marker" style={{ left: `${((date.getDate() - 0.5) / daysInMonth) * 100}%` }} key={holiday.id} />;
                              })}
                            </div>
                          </div>
                        );
                      })}
                    </div>
                  </section>
                );
              })}
            </div>
          ) : null}
        </section>

        {mode !== "year" && attentionTasks.length ? <aside className="attention-panel" aria-label="Tasks needing attention">
          <div className="section-heading"><div><p className="page-eyebrow">Tasks</p><h2>Coming up</h2></div><span className="count-badge">{attentionTasks.length}</span></div>
          <div className="attention-list">{attentionTasks.slice(0, 7).map((task) => <div className="attention-row" key={task.id}><button type="button" className="task-check" aria-label={`Complete ${task.title}`} onClick={() => void completeTask(task)}><Check aria-hidden="true" size={17} /></button>{attentionTaskContent(task)}</div>)}</div>
        </aside> : null}
      </div>

      <Modal
        open={Boolean(selectedFitnessItem)}
        onOpenChange={(open) => !open && setSelectedFitnessItem(null)}
        title={selectedFitnessItem?.display_title ?? "Fitness"}
      >
        {selectedFitnessItem ? (
          <div className="event-detail">
            <div className="event-detail-hero">
              <div className="event-detail-date">
                <Dumbbell aria-hidden="true" size={20} />
                <div>
                  <strong>{format(fitnessLayerDate(selectedFitnessItem), "EEEE, d MMMM yyyy")}</strong>
                  <span>{fitnessLayerTime(selectedFitnessItem)} · {fitnessKindLabel(selectedFitnessItem)}</span>
                </div>
              </div>
              <div className="event-detail-people"><div><span>For</span><strong>{fitnessOwnerLabel(selectedFitnessItem)}</strong></div></div>
            </div>
            <div className="dialog-actions">
              <button type="button" className="button button--secondary" onClick={() => { const item = selectedFitnessItem; setSelectedFitnessItem(null); openFitnessDestination(item); }}>
                {selectedFitnessItem.layer_kind === "completed" ? "Open workout" : "Open training"}
              </button>
              {selectedFitnessItem.layer_kind === "planned" ? (
                <button type="button" className="button button--danger" onClick={() => { setFitnessItemToDelete(selectedFitnessItem); setSelectedFitnessItem(null); }}>
                  <Trash2 aria-hidden="true" size={16} /> Delete planned exercise
                </button>
              ) : null}
            </div>
          </div>
        ) : null}
      </Modal>

      <Modal
        open={Boolean(fitnessItemToDelete)}
        onOpenChange={(open) => { if (!open && !fitnessDeleteBusy) setFitnessItemToDelete(null); }}
        title="Delete planned exercise?"
        description="This removes the session from your training plan and calendar."
      >
        <div className="confirm-delete">
          <p>{fitnessItemToDelete ? `Delete “${fitnessItemToDelete.display_title}”?` : ""}</p>
          <div className="dialog-actions">
            <button type="button" className="button button--secondary" disabled={fitnessDeleteBusy} onClick={() => setFitnessItemToDelete(null)}>Cancel</button>
            <button type="button" className="button button--danger" disabled={fitnessDeleteBusy} onClick={() => void deletePlannedFitnessItem()}>
              <Trash2 aria-hidden="true" size={16} /> {fitnessDeleteBusy ? "Deleting…" : "Delete"}
            </button>
          </div>
        </div>
      </Modal>

      <Modal open={Boolean(selectedEvent)} onOpenChange={(open) => !open && setSelectedEvent(null)} title={selectedEvent?.title ?? "Event"} size="wide">
        {selectedEvent ? (
          <div className="event-detail event-commitment-detail">
            <div className={cn("event-detail-hero", isSchoolMilestone(selectedEvent) && "is-school-milestone")}>
              {isSchoolMilestone(selectedEvent) ? <span className="milestone-sprinkles" aria-hidden="true" /> : null}
              <div className="event-detail-date"><CalendarPlus aria-hidden="true" size={20} /><div><strong>{format(eventDate(selectedEvent), "EEEE, d MMMM yyyy")}</strong><span>{eventTimeRange(selectedEvent)}</span></div></div>
              {!isFinanceManaged(selectedEvent) && selectedEvent.location && !selectedEvent.rugby_venue ? (
                <div className="event-detail-location">
                  <div className="event-detail-date"><MapPin aria-hidden="true" size={20} /><span>{selectedEvent.location}</span></div>
                  <a className="button button--secondary button--compact" href={`https://www.google.com/maps/search/?api=1&query=${encodeURIComponent(selectedEvent.location)}`} target="_blank" rel="noreferrer"><Navigation aria-hidden="true" size={16} /> Directions</a>
                </div>
              ) : null}
              {!isFinanceManaged(selectedEvent) ? <div className="event-detail-people"><div><span>Going</span><strong>{participantLabel(selectedEvent)}</strong></div>{affectedLabel(selectedEvent) ? <div><span>Coverage</span><strong>{affectedLabel(selectedEvent)}</strong></div> : null}</div> : null}
              {!isFinanceManaged(selectedEvent) && selectedEvent.description ? <p className="event-detail-notes">{selectedEvent.description}</p> : null}
            </div>

            {selectedEvent.rugby_venue ? (
              <section className={cn("event-detail-section rugby-venue-control", selectedEvent.rugby_venue === "away" && "is-away")} aria-labelledby="rugby-venue-heading">
                <div><span className="rugby-venue-label">{selectedEvent.rugby_venue.toUpperCase()}</span><div><h3 id="rugby-venue-heading">{selectedEvent.rugby_venue === "away" ? "Away fixture — travel blocked out" : "Home fixture"}</h3><p>Reserved in the planner from 1:00 to 7:00 pm.{selectedEvent.rugby_venue_overridden ? " This venue was changed in HausKlar." : ""}</p></div></div>
                <button type="button" className={cn("button", selectedEvent.rugby_venue === "home" ? "button--danger" : "button--secondary")} disabled={rugbyVenueBusy} onClick={() => void changeRugbyVenue(selectedEvent)}>{rugbyVenueBusy ? "Changing…" : `Mark as ${selectedEvent.rugby_venue === "home" ? "AWAY" : "HOME"}`}</button>
              </section>
            ) : null}

            {selectedEventClashes.length ? (
              <section className="event-detail-section event-detail-clashes" aria-labelledby="event-clashes-heading"><h3 id="event-clashes-heading">Clashes</h3>{selectedEventClashes.map((clash) => <button type="button" key={clash.id} onClick={() => setSelectedEvent(clash)}><span>{eventTimeRange(clash)}</span><strong>{clash.title}</strong></button>)}</section>
            ) : null}

            {facilitySwimmingSelection(selectedEvent) ? (
              <section className="event-detail-section" aria-labelledby="facility-booking-heading">
                <h3 id="facility-booking-heading">Booked a swim?</h3>
                <p className="event-series-note">Add the exact slot so it appears in the family calendar.</p>
                <button
                  type="button"
                  className="button button--primary"
                  onClick={() => {
                    recordSwimmingBookingOpen("calendar_event");
                    setSwimmingBooking(facilitySwimmingSelection(selectedEvent));
                  }}
                >
                  <CalendarPlus aria-hidden="true" size={17} /> Booked
                </button>
              </section>
            ) : null}

            {facilityWeightsSelection(selectedEvent) ? (
              <section className="event-detail-section" aria-labelledby="weights-booking-heading">
                <h3 id="weights-booking-heading">Strength session</h3>
                <button
                  type="button"
                  className="button button--primary"
                  onClick={() => setWeightsBooking(facilityWeightsSelection(selectedEvent))}
                >
                  <CalendarPlus aria-hidden="true" size={17} /> Plan strength
                </button>
              </section>
            ) : null}

            {isSchoolClubEvent(selectedEvent) ? (
              <section className="event-detail-section managed-club-actions" aria-labelledby="school-club-heading">
                <div><h3 id="school-club-heading">{selectedEvent.event_type === "school_club_cancelled" ? "Cancelled this date" : "Term-time club"}</h3><p>{selectedEvent.event_type === "school_club_cancelled" ? "It stays visible so nobody expects it to run." : "If Toast is booked, its pickup window starts when this club ends."}</p></div>
                <div className="dialog-actions"><button type="button" className="button button--secondary" disabled={clubOccurrenceBusy} onClick={() => void changeClubOccurrence(selectedEvent)}>{clubOccurrenceBusy ? "Saving…" : selectedEvent.event_type === "school_club_cancelled" ? "Restore this date" : "Cancel this date"}</button><button type="button" className="button button--secondary" onClick={() => { setSelectedEvent(null); void openClubs(); }}>Manage clubs</button></div>
              </section>
            ) : null}

            {isToastEvent(selectedEvent) ? (
              <section className="event-detail-section managed-toast-detail" aria-labelledby="toast-window-heading"><div><h3 id="toast-window-heading">Pickup window</h3><p>{selectedEvent.event_type === "toast_club_conflict" ? selectedEvent.description : "Pickup any time in this window."}</p></div><button type="button" className="button button--secondary" onClick={() => { setSelectedEvent(null); void openToast(); }}>Toast bookings</button></section>
            ) : null}

            {selectedEventRelatedTasks.length ? (
              <section className="event-detail-section" aria-labelledby="event-tasks-heading"><h3 id="event-tasks-heading">Related tasks</h3>{selectedEventRelatedTasks.map((task) => <div className="event-related-task" key={task.id}><button type="button" className="task-check" aria-label={`Complete ${task.title}`} onClick={() => void completeTask(task)}><Check aria-hidden="true" size={17} /></button><span><strong>{task.title}</strong><small>{dueLabel(task.due_date)}</small></span></div>)}</section>
            ) : null}

            {selectedEventPackingTasks.length || selectedEventPrep.length ? (
              <section className="event-detail-section event-preparation-checklist" aria-labelledby="event-prep-heading">
                <div className="event-prep-heading"><h3 id="event-prep-heading">Packing & preparation</h3>{selectedEventPackingTasks.length ? <span className="count-badge">{selectedEventPackingTasks.length} remaining</span> : null}</div>
                {selectedEventPackingTasks.map((task) => <div className="event-related-task" key={task.id}><button type="button" className="task-check" aria-label={`Pack ${task.title}`} onClick={() => void completeTask(task)}><Check aria-hidden="true" size={17} /></button><span><strong>{task.title}</strong><small>{task.assignees.map((assignee) => assignee.assignee_name).filter(Boolean).join(" & ") || "Family"}</small></span></div>)}
                {!selectedEventPackingTasks.length ? selectedEventPrep.map((prep) => <div className="event-prep-pack" key={prep.id}><div><strong>{prep.template_name}</strong><span>{prep.items.length} things · {prep.assigned_to ? members.find((member) => member.id === prep.assigned_to)?.name ?? "Assigned" : "Family"}</span><span className="event-prep-summary sr-only">{prep.items.join(" · ")}</span></div><ul aria-label={`${prep.template_name} checklist`}>{prep.items.map((item) => <li key={item}>{item}</li>)}</ul><button type="button" className="button button--primary button--compact" disabled={Boolean(prepBusyId)} onClick={() => void applyPrepSuggestion(prep)}>{prepBusyId === prep.id ? "Adding…" : "Use checklist"}</button></div>) : null}
              </section>
            ) : null}

            {!isFinanceManaged(selectedEvent) && selectedEventAttachments.length ? (
              <section className="event-detail-section" aria-labelledby="event-documents-heading"><h3 id="event-documents-heading">Documents</h3><div className="event-document-grid">{selectedEventAttachments.map((document) => <button type="button" className="linked-document-card" key={document.relation_id} onClick={() => { setPreviewReturnEvent(selectedEvent); setViewingDocument(document); setSelectedEvent(null); }}><Paperclip aria-hidden="true" size={18} /><span><small>{attachmentRoleLabel(document.role)}</small><strong>{document.title}</strong><small>{document.original_filename}</small></span></button>)}</div></section>
            ) : null}

            <details className="event-detail-more">
              <summary>Event details</summary>
              <div>
                {recurrenceLabel(selectedEvent.recurrence_rule) ? <p><Repeat2 aria-hidden="true" size={17} /> Repeats {recurrenceLabel(selectedEvent.recurrence_rule)?.toLowerCase()}</p> : null}
                {isFinanceManaged(selectedEvent) && selectedEvent.managed_source ? <><p className="event-series-note">This read-only date is managed in Finance. Financial details stay there.</p><a className="button button--secondary" href={selectedEvent.managed_source.deep_link}><WalletCards aria-hidden="true" size={16} /> Open {selectedEvent.managed_source.label}</a></> : isSchoolClubEvent(selectedEvent) ? <p className="event-series-note">Created from the term-time club.</p> : isToastEvent(selectedEvent) ? <p className="event-series-note">Created from the confirmed Toast booking form.</p> : isFacilityManaged(selectedEvent) ? <p className="event-series-note">Read-only availability from the confirmed Example School timetable.</p> : selectedEvent.rugby_venue ? <p className="event-series-note">Kept up to date from Example School College Sports. You can change HOME or AWAY here without changing Example School’s calendar.</p> : selectedEvent.event_type?.startsWith("cycle_") ? <p className="event-series-note">Calculated by cycle tracking.</p> : selectedEvent.source_name ? <p className="event-series-note">Imported from {selectedEvent.source_name}. Editing makes a HausKlar override without changing the source calendar.</p> : null}
                {selectedEvent.series_id && !isFinanceManaged(selectedEvent) ? <p className="event-series-note">This occurrence belongs to a repeating series. HausKlar asks which events to change before editing or deleting.</p> : null}
              </div>
            </details>
            {!selectedEvent.event_type?.startsWith("cycle_") && !selectedEvent.rugby_venue && !isFinanceManaged(selectedEvent) && !isFacilityManaged(selectedEvent) && !isSchoolClubEvent(selectedEvent) && !isToastEvent(selectedEvent) ? <div className="dialog-actions"><button type="button" className="button button--secondary" onClick={() => requestRecurringAction(selectedEvent, "edit")}><Edit3 aria-hidden="true" size={16} /> Edit</button>{!selectedEvent.read_only ? <button type="button" className="button button--danger" onClick={() => requestRecurringAction(selectedEvent, "delete")}><Trash2 aria-hidden="true" size={16} /> Delete</button> : null}</div> : null}
          </div>
        ) : null}
      </Modal>

      <SwimmingBookingDialog
        selection={swimmingBooking}
        onOpenChange={(open) => { if (!open) setSwimmingBooking(null); }}
        onBooked={(message) => {
          setNotice(message);
          setSelectedEvent(null);
          void load(true);
          onDataChanged();
        }}
      />

      <WeightsBookingDialog
        selection={weightsBooking}
        onOpenChange={(open) => { if (!open) setWeightsBooking(null); }}
        onBooked={(message) => {
          setNotice(message);
          setSelectedEvent(null);
          void load(true);
          onDataChanged();
        }}
      />

      <Modal
        open={clubsOpen}
        onOpenChange={(open) => {
          if (clubsBusy) return;
          setClubsOpen(open);
          if (!open) {
            setEditingClub(null);
            setClubsError(null);
          }
        }}
        title="Clubs"
        description="Term time only. Sessions appear in Calendar."
      >
        <div className="club-manager">
          {clubsError ? <div className="form-error" role="alert">{clubsError}</div> : null}
          {clubsBusy && !clubs.length && !editingClub ? <div className="facility-import-loading" role="status"><span className="spinner" aria-hidden="true" />Loading…</div> : null}
          {editingClub ? <form className="club-editor" aria-busy={clubsBusy} onSubmit={(event) => { event.preventDefault(); void saveClub(); }}>
            <label className="club-name"><span>Club</span><input value={clubDraft.name} maxLength={120} placeholder="Football" autoComplete="off" required onChange={(event) => setClubDraft((current) => ({ ...current, name: event.target.value }))} /></label>
            <label><span>Child</span><select value={clubDraft.childId} required onChange={(event) => setClubDraft((current) => ({ ...current, childId: event.target.value }))}>{members.filter((member) => member.member_type === "child").map((member) => <option value={member.id} key={member.id}>{member.name}</option>)}</select></label>
            <label><span>Day</span><select value={clubDraft.weekday} required onChange={(event) => setClubDraft((current) => ({ ...current, weekday: Number(event.target.value) }))}>{handoffWeekdays.map((day, weekday) => <option value={weekday} key={day}>{day}</option>)}</select></label>
            <label><span>Starts</span><input type="time" value={clubDraft.startTime} required onChange={(event) => setClubDraft((current) => ({ ...current, startTime: event.target.value }))} /></label>
            <label><span>Ends</span><input type="time" value={clubDraft.endTime} required onChange={(event) => setClubDraft((current) => ({ ...current, endTime: event.target.value }))} /></label>
            <div className="dialog-actions"><button type="button" className="button button--secondary" disabled={clubsBusy} onClick={() => setEditingClub(null)}>Cancel</button><button type="submit" className="button button--primary" disabled={clubsBusy || !clubDraft.name.trim() || !clubDraft.childId || !clubDraft.startTime || !clubDraft.endTime}>{clubsBusy ? "Saving…" : "Save"}</button></div>
          </form> : <>
            <div className="club-list">
              {clubs.map((club) => <article key={club.id}><span className="club-list-icon" style={{ color: club.color }}><School aria-hidden="true" size={18} /></span><div><strong>{club.name}</strong><small>{club.child_name} · {handoffWeekdays[club.weekday] ?? "Club"} · {club.start_time}–{club.end_time}</small></div><button type="button" className="icon-button" aria-label={`Edit ${club.name}`} onClick={() => editClub(club)}><Edit3 aria-hidden="true" size={16} /></button><button type="button" className="icon-button" aria-label={`Delete ${club.name}`} onClick={() => setClubToDelete(club)}><Trash2 aria-hidden="true" size={16} /></button></article>)}
              {!clubsBusy && !clubs.length ? <p className="club-empty">No clubs yet.</p> : null}
            </div>
            <div className="dialog-actions"><button type="button" className="button button--secondary" onClick={() => setClubsOpen(false)}>Done</button><button type="button" className="button button--primary" onClick={newClub}><Plus aria-hidden="true" size={16} /> Add club</button></div>
          </>}
        </div>
      </Modal>

      <Modal
        open={toastOpen}
        onOpenChange={(open) => {
          if (toastBusy) return;
          setToastOpen(open);
          if (!open) {
            setToastFile(null);
            setToastPreview(null);
            setToastError(null);
          }
        }}
        title="Toast Club"
        description="Booking forms become pickup windows."
      >
        <div className="toast-manager">
          {toastBusy && !toastPreview ? <div className="facility-import-loading" role="status"><span className="spinner" aria-hidden="true" />Reading…</div> : null}
          {toastError ? <div className="form-error" role="alert">{toastError}</div> : null}
          {toastPreview ? <>
            <section className="toast-import-summary" aria-label="Toast form summary"><div><span>Child</span><strong>{toastPreview.child_name}</strong></div><div><span>Dates</span><strong>{format(parseISO(toastPreview.valid_from), "d MMM")} – {format(parseISO(toastPreview.valid_to), "d MMM yyyy")}</strong></div><div><span>Booked</span><strong>{toastPreview.booked_days} days</strong></div><div><span>Pickup by</span><strong>{toastPreview.until_1630} × 4:30 · {toastPreview.until_1730} × 5:30</strong></div></section>
            <p className="toast-import-change">{toastPreview.already_imported ? "This form is already in use." : `${toastPreview.changes.added} new, ${toastPreview.changes.changed} changed, ${toastPreview.changes.removed} removed.`}</p>
          </> : toastStatus.length ? <div className="toast-status-list">{toastStatus.map((status) => <article key={status.import_id}><span><strong>{status.child_name}</strong><small>{format(parseISO(status.valid_from), "d MMM")} – {format(parseISO(status.valid_to), "d MMM yyyy")}</small></span><b>{status.booked_days} days</b></article>)}</div> : !toastBusy ? <p className="club-empty">No booking forms yet.</p> : null}
          <div className="dialog-actions"><button type="button" className="button button--secondary" disabled={toastBusy} onClick={() => setToastOpen(false)}>Done</button><button type="button" className="button button--secondary" disabled={toastBusy} onClick={() => toastFileInputRef.current?.click()}><Upload aria-hidden="true" size={16} /> {toastPreview ? "Choose another" : "Add booking form"}</button>{toastPreview?.can_confirm && !toastPreview.already_imported ? <button type="button" className="button button--primary" disabled={toastBusy} onClick={() => void confirmToastImport()}><Check aria-hidden="true" size={16} /> Use these dates</button> : null}</div>
        </div>
      </Modal>

      <Modal open={Boolean(clubToDelete)} onOpenChange={(open) => !open && !clubsBusy && setClubToDelete(null)} title="Remove club?" description="Future calendar sessions will disappear.">
        <div className="confirm-delete"><p>{clubToDelete?.name}</p><div className="dialog-actions"><button type="button" className="button button--secondary" disabled={clubsBusy} onClick={() => setClubToDelete(null)}>Cancel</button><button type="button" className="button button--danger" disabled={clubsBusy} onClick={() => void deleteClub()}><Trash2 aria-hidden="true" size={16} /> {clubsBusy ? "Removing…" : "Remove"}</button></div></div>
      </Modal>

      <Modal
        open={Boolean(coordinationDate)}
        onOpenChange={(open) => { if (!open) setCoordinationDate(null); }}
        title={coordinationDate ? `Leave & pickup · ${format(coordinationDate, "EEE d MMM")}` : "Leave & pickup"}
      >
        <div className="coordination-detail">
          {coordinationHandoffs.map((handoff) => <button type="button" onClick={() => openHandoffEditor(handoff)} key={handoff.id}>
            <span className={cn("coordination-detail-dot", `member-color-${memberIndex.get(handoff.kind === "pickup" ? handoff.term_person_id : handoff.owner_user_id) ?? 0}`)} />
            <span><strong>{handoff.kind === "pickup" ? `${handoff.term_person_name} pickup` : `${handoff.owner_name} leaves work`}</strong>{handoff.is_override ? <small>Changed today</small> : null}</span>
            <time>{handoff.time_of_day}</time><Edit3 aria-hidden="true" size={15} />
          </button>)}
          {coordinationToast.map((event) => <button type="button" onClick={() => { setCoordinationDate(null); setSelectedEvent(event); }} key={event.id}>
            <span className="coordination-detail-window" />
            <span><strong>{toastChildLabel(event)} · Toast</strong><small>Pickup window</small></span>
            <time>{eventTimeRange(event).replace(" – ", "–")}</time><ChevronRight aria-hidden="true" size={15} />
          </button>)}
          <div className="dialog-actions"><button type="button" className="button button--secondary" onClick={() => setCoordinationDate(null)}>Done</button><button type="button" className="button button--primary" onClick={() => { setCoordinationDate(null); void openHandoffSetup(); }}><Edit3 aria-hidden="true" size={15} /> Edit week</button></div>
        </div>
      </Modal>

      <Modal
        open={handoffSetupOpen}
        onOpenChange={(open) => { if (!handoffScheduleBusy) setHandoffSetupOpen(open); }}
        title="Leave & pickup"
        description="Each person follows their own term dates."
        size="wide"
      >
        <form className="handoff-schedule-editor" aria-busy={handoffScheduleBusy} onSubmit={(event) => { event.preventDefault(); void saveHandoffSchedule(); }}>
          {handoffScheduleBusy && !handoffPeople.length ? <div className="facility-import-loading" role="status"><span className="spinner" aria-hidden="true" />Loading…</div> : null}
          {handoffScheduleError ? <div className="form-error" role="alert">{handoffScheduleError}</div> : null}
          {handoffPeople.length ? <>
            <section className="handoff-person-section">
              <header><div><strong>Pickup</strong><small>{pickupDraft?.personName}’s term</small></div><div className="handoff-person-tabs" role="group" aria-label="Child pickup timetable">{handoffPeople.filter((person) => person.kind === "pickup").map((person) => <button type="button" className={pickupPersonTab === person.personId ? "is-active" : ""} aria-pressed={pickupPersonTab === person.personId} onClick={() => setPickupPersonTab(person.personId)} key={person.personId}>{person.personName}</button>)}</div></header>
              {pickupDraft ? <div className="handoff-week-grid" role="group" aria-label={`${pickupDraft.personName} pickup times`}>
                <div className="handoff-week-heading is-simple" aria-hidden="true"><span>Day</span><span>Time</span></div>
                {pickupDraft.days.map((day) => <div className="handoff-week-row is-simple" key={day.weekday}>
                  <strong>{handoffWeekdays[day.weekday]}</strong>
                  <label><span className="sr-only">{handoffWeekdays[day.weekday]} {pickupDraft.personName} pickup time</span><input type="time" value={day.time} onChange={(event) => updateHandoffDay("pickup", pickupDraft.personId, day.weekday, { time: event.target.value })} /></label>
                </div>)}
              </div> : null}
            </section>
            <section className="handoff-person-section">
              <header><div><strong>Leaves work</strong><small>{workDraft?.personName}’s term</small></div><div className="handoff-person-tabs" role="group" aria-label="Work departure timetable">{handoffPeople.filter((person) => person.kind === "work_departure").map((person) => <button type="button" className={workPersonTab === person.personId ? "is-active" : ""} aria-pressed={workPersonTab === person.personId} onClick={() => setWorkPersonTab(person.personId)} key={person.personId}>{person.personName}</button>)}</div></header>
              {workDraft ? <div className="handoff-week-grid" role="group" aria-label={`${workDraft.personName} work departure times`}>
                <div className="handoff-week-heading is-simple" aria-hidden="true"><span>Day</span><span>Time</span></div>
                {workDraft.days.map((day) => <div className="handoff-week-row is-simple" key={day.weekday}>
                  <strong>{handoffWeekdays[day.weekday]}</strong>
                  <label><span className="sr-only">{workDraft.personName} leaves work on {handoffWeekdays[day.weekday]}</span><input type="time" value={day.time} onChange={(event) => updateHandoffDay("work_departure", workDraft.personId, day.weekday, { time: event.target.value })} /></label>
                </div>)}
              </div> : null}
            </section>
          </> : null}
          <div className="dialog-actions"><button type="button" className="button button--secondary" disabled={handoffScheduleBusy} onClick={() => setHandoffSetupOpen(false)}>Cancel</button><button type="submit" className="button button--primary" disabled={handoffScheduleBusy}>{handoffScheduleBusy ? "Saving…" : "Save"}</button></div>
        </form>
      </Modal>

      <Modal
        open={Boolean(editingHandoff)}
        onOpenChange={(open) => { if (!open && !handoffEditBusy) setEditingHandoff(null); }}
        title={editingHandoff ? `${editingHandoff.kind === "pickup" ? `${editingHandoff.term_person_name} pickup` : `${editingHandoff.owner_name} leaves work`} · ${format(parseISO(editingHandoff.date), "EEE d MMM")}` : "Handoff"}
      >
        {editingHandoff ? <form className="handoff-day-editor" aria-busy={handoffEditBusy} onSubmit={(event) => { event.preventDefault(); void saveHandoffDay(); }}>
          <label><span>Time</span><input type="time" value={handoffEditTime} onChange={(event) => setHandoffEditTime(event.target.value)} autoFocus /></label>
          <div className="handoff-day-options"><button type="button" className="button button--secondary button--compact" disabled={handoffEditBusy} onClick={() => void saveHandoffDay(true)}>Not this day</button>{editingHandoff.is_override ? <button type="button" className="button button--secondary button--compact" disabled={handoffEditBusy} onClick={() => void clearHandoffDayChange()}>Use weekly time</button> : null}</div>
          <div className="dialog-actions"><button type="button" className="button button--secondary" disabled={handoffEditBusy} onClick={() => setEditingHandoff(null)}>Cancel</button><button type="submit" className="button button--primary" disabled={handoffEditBusy || !handoffEditTime}>{handoffEditBusy ? "Saving…" : "Save for this day"}</button></div>
        </form> : null}
      </Modal>

      <Modal
        open={facilityImportOpen}
        onOpenChange={(open) => {
          if (facilityImportBusy) return;
          setFacilityImportOpen(open);
          if (!open) {
            setFacilityImportFile(null);
            setFacilityImportPreview(null);
            setFacilityImportError(null);
          }
        }}
        title="Update Example School timetable"
        description="HausKlar reads the staff timetable deterministically. Nothing changes until you confirm this review."
      >
        <div className="facility-import-review">
          {facilityImportBusy && !facilityImportPreview ? <div className="facility-import-loading" role="status"><span className="spinner" aria-hidden="true" />Reading timetable…</div> : null}
          {facilityImportError ? <div className="form-error" role="alert">{facilityImportError}</div> : null}
          {facilityImportPreview ? <>
            <section className="facility-import-summary" aria-label="Timetable import summary">
              <div><span>Date range</span><strong>{format(parseISO(facilityImportPreview.valid_from), "d MMM")} – {format(parseISO(facilityImportPreview.valid_to), "d MMM yyyy")}</strong></div>
              <div><span>Family swims</span><strong>{facilityImportPreview.counts.family_swimming_sessions}</strong></div>
              <div><span>Lane swims</span><strong>{facilityImportPreview.counts.lane_swimming_sessions}</strong></div>
              <div><span>Weights open</span><strong>{facilityImportPreview.counts.weights_room_open_days} days</strong></div>
            </section>
            <p className="facility-import-change">
              {facilityImportPreview.already_imported
                ? "This exact timetable is already in use."
                : `${facilityImportPreview.changes.added_days} new, ${facilityImportPreview.changes.changed_days} changed and ${facilityImportPreview.changes.removed_days} removed days.`}
            </p>
            {facilityImportPreview.sample_days.length ? (
              <section className="facility-import-samples" aria-labelledby="facility-import-samples-title">
                <h3 id="facility-import-samples-title">Spot check</h3>
                <ul>
                  {facilityImportPreview.sample_days.slice(0, 6).map((day) => (
                    <li key={day.date}>
                      <time dateTime={day.date}>{format(parseISO(day.date), "EEE d MMM")}</time>
                      <span>{familySwimmingLabel(day)}</span>
                      {weightsRoomLabel(day) ? <small>{weightsRoomLabel(day)}</small> : null}
                    </li>
                  ))}
                </ul>
              </section>
            ) : null}
            <p className="facility-import-owner">Family swimming is shared. Lane swimming and weights are shown only to Alex.</p>
          </> : null}
          <div className="dialog-actions">
            <button type="button" className="button button--secondary" disabled={facilityImportBusy} onClick={() => setFacilityImportOpen(false)}>Cancel</button>
            {facilityImportError && !facilityImportPreview ? <button type="button" className="button button--secondary" disabled={facilityImportBusy} onClick={() => facilityFileInputRef.current?.click()}>Choose another file</button> : null}
            {facilityImportPreview?.can_confirm ? <button type="button" className="button button--primary" disabled={facilityImportBusy} onClick={() => void confirmFacilityImport()}><Check aria-hidden="true" size={17} />{facilityImportBusy ? "Importing…" : "Use this timetable"}</button> : null}
          </div>
        </div>
      </Modal>

      <DocumentViewer document={viewingDocument} onOpenChange={(open) => { if (!open) { setViewingDocument(null); if (previewReturnEvent) setSelectedEvent(previewReturnEvent); setPreviewReturnEvent(null); } }} />

      <Modal
        open={Boolean(recurrencePrompt)}
        onOpenChange={(open) => {
          if (!open && !deleting) setRecurrencePrompt(null);
        }}
        title={recurrencePrompt?.action === "delete" ? "Delete repeating event?" : "Edit repeating event?"}
        description={recurrencePrompt ? `Choose how much of “${recurrencePrompt.event.title}” to ${recurrencePrompt.action}.` : undefined}
      >
        <div className="recurrence-scope-options" aria-busy={deleting}>
          {actionError ? <div className="form-error" role="alert">{actionError}</div> : null}
          {recurrenceScopeOptions.map((scope) => (
            <button
              type="button"
              className={cn("button button--secondary recurrence-scope-option", recurrencePrompt?.action === "delete" && "is-destructive")}
              disabled={deleting}
              key={scope.value}
              onClick={() => {
                if (!recurrencePrompt) return;
                if (recurrencePrompt.action === "edit") {
                  const event = recurrencePrompt.event;
                  setRecurrencePrompt(null);
                  openEditEvent(event, scope.value);
                } else {
                  void deleteEvent(recurrencePrompt.event, scope.value);
                }
              }}
            >
              <strong>{scope.label}</strong>
              <span>{scope.detail}</span>
            </button>
          ))}
          <button type="button" className="button button--secondary" disabled={deleting} onClick={() => setRecurrencePrompt(null)}>Cancel</button>
        </div>
      </Modal>

      <Modal open={Boolean(eventToDelete)} onOpenChange={(open) => !open && setEventToDelete(null)} title={eventToDelete?.recurrence_rule ? "Delete repeating series?" : "Delete event?"} description={eventToDelete?.recurrence_rule ? "Every occurrence in this series will be removed." : "This event will be removed from the family calendar."}>
        <div className="confirm-delete"><p>{eventToDelete ? `Delete “${eventToDelete.title}”?` : ""}</p><div className="dialog-actions"><button type="button" className="button button--secondary" disabled={deleting} onClick={() => setEventToDelete(null)}>Cancel</button><button type="button" className="button button--danger" disabled={deleting} onClick={() => void deleteEvent()}><Trash2 aria-hidden="true" size={16} />{deleting ? "Deleting…" : "Delete"}</button></div></div>
      </Modal>

      <QuickAddDialog
        open={editorOpen}
        initialKind="event"
        eventOnly
        initialEvent={editingEvent}
        initialDate={editorDate}
        recurrenceScope={editingRecurrenceScope}
        members={members}
        onOpenChange={(open) => {
          setEditorOpen(open);
          if (!open) setEditingRecurrenceScope(null);
        }}
        onCreated={onDataChanged}
        notify={setNotice}
      />
    </div>
  );
}
