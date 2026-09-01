import {
  AlertTriangle,
  BookHeart,
  BookOpen,
  CakeSlice,
  Camera,
  Check,
  ChevronLeft,
  ChevronRight,
  Dog,
  Edit3,
  Files,
  Gift,
  Palette,
  Trash2,
  HeartPulse,
  Moon,
  PawPrint,
  Pill,
  Plus,
  RefreshCw,
  ShieldCheck,
  Star,
  Thermometer,
  TrendingUp,
  UsersRound,
} from "lucide-react";
import { differenceInYears, format, parseISO } from "date-fns";
import { lazy, Suspense, useCallback, useEffect, useMemo, useRef, useState, type FormEvent } from "react";

import { api } from "../api";
import type { CalendarEvent, Child, FamilyMember } from "../types";
import { PersonAvatar, PersonAvatarEditor } from "../components/PersonAvatar";
import { EmptyState, ErrorState, Modal, SkeletonList, cn } from "../components/ui";

const HealthView = lazy(() => import("./HealthView").then((module) => ({ default: module.HealthView })));
const HomeworkView = lazy(() => import("./HomeworkView").then((module) => ({ default: module.HomeworkView })));
const PresentsView = lazy(() => import("./PresentsView").then((module) => ({ default: module.PresentsView })));
const ArtworkPanel = lazy(() => import("./ArtworkPanel").then((module) => ({ default: module.ArtworkPanel })));
const PhotosPanel = lazy(() => import("./PhotosPanel").then((module) => ({ default: module.PhotosPanel })));
const BirthdaysPanel = lazy(() => import("./BirthdaysPanel").then((module) => ({ default: module.BirthdaysPanel })));
const CaregiverSetupView = lazy(() => import("./CaregiverView").then((module) => ({ default: module.CaregiverSetupView })));
const DogCarePanel = lazy(() => import("./DogCarePanel").then((module) => ({ default: module.DogCarePanel })));
const YearbookView = lazy(() => import("./YearbookView").then((module) => ({ default: module.YearbookView })));

export type FamilyArea = "overview" | "stars" | "sleep" | "medicine" | "illness" | "learning" | "growth" | "presents" | "birthdays" | "dog" | "artwork" | "photos" | "yearbook" | "health" | "caregiver";

const CHILD_FOCUSED_AREAS: FamilyArea[] = ["stars", "sleep", "medicine", "illness", "learning", "growth", "presents", "artwork", "photos", "yearbook", "health"];

type NapRecord = {
  id: string;
  child_id: string;
  started_at: string;
  ended_at?: string | null;
  duration_minutes?: number | null;
  sleep_type: string;
};

type StarRecord = { id: string; row_index: number; col_index: number };
type StarChart = {
  id: string;
  child_id: string;
  title: string;
  grid_rows: number;
  grid_columns: number;
  stars_count: number;
  total_cells: number;
  reward_amount_pence: number;
  completed_at?: string | null;
  stars: StarRecord[];
};
type Balance = { child_id: string; balance_pence: number; balance_display: string };
type CompletedChartResponse = {
  chart: StarChart;
  reward_amount_pence: number;
  new_balance_pence: number;
  new_balance_display: string;
};
type MedicineType = {
  id: string;
  name: string;
  child_id: string;
  min_hours_between_doses: number;
  max_doses_24h: number;
  default_dose_amount?: string | null;
  notes?: string | null;
};
type MedicineDose = {
  id: string;
  child_id: string;
  medicine_type_id?: string | null;
  medicine_name?: string | null;
  medicine_name_display?: string | null;
  dose_amount?: string | null;
  given_at: string;
};
type Illness = { id: string; child_id: string; started_at: string; ended_at?: string | null; notes?: string | null };
type TodayRoutine = { routine_item_id: string; person_id: string; person_name: string; name: string; color: string; date: string };
type TodayMedicine = {
  child_id?: string | null;
  child_name: string;
  medicine_name: string;
  next_safe_at?: string | null;
  is_safe_now: boolean;
  last_given_at?: string | null;
};
type FamilyTodayDashboard = {
  events: CalendarEvent[];
  naps: NapRecord[];
  illnesses: Illness[];
  routines: TodayRoutine[];
  medicine: TodayMedicine[];
  unavailable: string[];
};
type TemperatureReading = { id: string; child_id: string; illness_id?: string | null; value_celsius: number; recorded_at: string; notes?: string | null };
type NextDoseTime = {
  medicine_type_id: string;
  medicine_name: string;
  next_safe_at?: string | null;
  is_safe_now: boolean;
  default_dose_amount?: string | null;
  last_given_at?: string | null;
};
type IllnessDetail = {
  illness: Illness;
  temperature_readings: TemperatureReading[];
  medicine_doses: MedicineDose[];
  next_dose_times: NextDoseTime[];
};
type GrowthRecord = {
  id: string;
  child_id: string;
  date: string;
  height_cm?: number | null;
  weight_kg?: number | null;
};
type MedicineWarning = { type: string; message: string; next_safe_at?: string | null };
type MedicineDoseResult = { dose: MedicineDose; warnings: MedicineWarning[] };

function localDateTimeInputValue(date = new Date()): string {
  const year = date.getFullYear();
  const month = String(date.getMonth() + 1).padStart(2, "0");
  const day = String(date.getDate()).padStart(2, "0");
  const hours = String(date.getHours()).padStart(2, "0");
  const minutes = String(date.getMinutes()).padStart(2, "0");
  return `${year}-${month}-${day}T${hours}:${minutes}`;
}

function localDateInputValue(date = new Date()): string {
  return localDateTimeInputValue(date).slice(0, 10);
}

function when(value: string): string {
  return format(parseISO(value), "d MMM, HH:mm");
}

function childAge(dateOfBirth: string): string {
  const years = differenceInYears(new Date(), parseISO(dateOfBirth));
  return years === 1 ? "1 year" : `${years} years`;
}

function activityLabel(value: string): string {
  return value.replaceAll("_", " ").replace(/^./, (letter) => letter.toUpperCase());
}

function nextDoseIsReady(nextDose: NextDoseTime, now = Date.now()): boolean {
  if (nextDose.is_safe_now) return true;
  if (!nextDose.next_safe_at) return false;
  const nextSafeAt = new Date(nextDose.next_safe_at).getTime();
  return Number.isFinite(nextSafeAt) && nextSafeAt <= now;
}

function doseCountdown(nextDose: NextDoseTime, now: number): string {
  if (nextDoseIsReady(nextDose, now)) return "Minimum interval passed";
  if (!nextDose.next_safe_at) return "Timing unavailable";
  const nextSafeAt = new Date(nextDose.next_safe_at).getTime();
  if (!Number.isFinite(nextSafeAt)) return "Timing unavailable";
  const remainingSeconds = Math.max(0, Math.ceil((nextSafeAt - now) / 1_000));
  const hours = Math.floor(remainingSeconds / 3_600);
  const minutes = Math.floor((remainingSeconds % 3_600) / 60);
  const seconds = remainingSeconds % 60;
  return hours > 0
    ? `Interval ends in ${hours}:${String(minutes).padStart(2, "0")}:${String(seconds).padStart(2, "0")}`
    : `Interval ends in ${minutes}:${String(seconds).padStart(2, "0")}`;
}

// Owns the 1-second countdown tick so only the dose rows re-render each second.
function IllnessDoseList({ detail, working, onReview }: { detail: IllnessDetail; working: string | null; onReview: (nextDose: NextDoseTime) => void }) {
  const [now, setNow] = useState(() => Date.now());
  useEffect(() => {
    const nextDoses = detail.next_dose_times;
    if (nextDoses.every((nextDose) => nextDoseIsReady(nextDose))) return;
    setNow(Date.now());
    const timer = window.setInterval(() => {
      const current = Date.now();
      setNow(current);
      if (nextDoses.every((nextDose) => nextDoseIsReady(nextDose, current))) window.clearInterval(timer);
    }, 1_000);
    return () => window.clearInterval(timer);
  }, [detail]);
  return (
    <div className="illness-dose-list">
      {detail.next_dose_times.map((nextDose) => {
        const readyNow = nextDoseIsReady(nextDose, now);
        const timing = doseCountdown(nextDose, now);
        return (
          <div className="illness-dose-row" key={nextDose.medicine_type_id}>
            <div>
              <strong>{nextDose.medicine_name}</strong>
              <span>{nextDose.default_dose_amount ?? "Dose amount not set"}</span>
              <small className={readyNow ? "is-ready" : ""}>{timing}{nextDose.last_given_at ? ` · Last given ${when(nextDose.last_given_at)}` : ""}</small>
            </div>
            <button
              type="button"
              className="button button--primary button--compact"
              aria-label={`Review ${nextDose.medicine_name} dose entry`}
              disabled={Boolean(working)}
              onClick={() => onReview(nextDose)}
            >
              Review dose
            </button>
          </div>
        );
      })}
    </div>
  );
}

function TemperatureTimeline({ detail }: { detail: IllnessDetail }) {
  const readings = detail.temperature_readings
    .map((reading) => ({ reading, time: new Date(reading.recorded_at).getTime() }))
    .filter((item) => Number.isFinite(item.time));
  const medicineDoses = detail.medicine_doses
    .map((dose) => ({ dose, time: new Date(dose.given_at).getTime() }))
    .filter((item) => Number.isFinite(item.time));
  if (!readings.length) return null;

  const width = 720;
  const height = 230;
  const plot = { left: 48, right: 16, top: 32, bottom: 30 };
  const allTimes = [...readings.map((item) => item.time), ...medicineDoses.map((item) => item.time)];
  let firstTime = Math.min(...allTimes);
  let lastTime = Math.max(...allTimes);
  if (firstTime === lastTime) {
    firstTime -= 30 * 60 * 1_000;
    lastTime += 30 * 60 * 1_000;
  }
  const plotWidth = width - plot.left - plot.right;
  const plotHeight = height - plot.top - plot.bottom;
  const x = (time: number) => plot.left + ((time - firstTime) / (lastTime - firstTime)) * plotWidth;
  const y = (temperature: number) => plot.top + ((42 - Math.min(42, Math.max(35, temperature))) / 7) * plotHeight;
  const points = readings.map(({ reading, time }) => `${x(time)},${y(reading.value_celsius)}`).join(" ");
  const timeLabel = (time: number) => format(new Date(time), lastTime - firstTime > 24 * 60 * 60 * 1_000 ? "d MMM HH:mm" : "HH:mm");

  return (
    <section className="temperature-timeline" aria-labelledby="temperature-timeline-heading">
      <div className="temperature-timeline-heading">
        <div><h4 id="temperature-timeline-heading">Temperature timeline</h4><p>Medicine markers show when doses were recorded during this illness.</p></div>
        <span>35–42 °C</span>
      </div>
      <div className="temperature-chart-scroll" tabIndex={0} aria-label="Scrollable temperature chart">
        <svg
          className="temperature-chart"
          viewBox={`0 0 ${width} ${height}`}
          role="img"
          aria-label={`Temperature and medicine timeline with ${readings.length} temperature ${readings.length === 1 ? "reading" : "readings"} and ${medicineDoses.length} medicine ${medicineDoses.length === 1 ? "dose" : "doses"}`}
        >
          <title>Temperature and medicine timeline</title>
          {[35, 37.5, 39, 42].map((temperature) => (
            <g className={temperature === 37.5 ? "temperature-chart__fever" : "temperature-chart__grid"} key={temperature}>
              <line x1={plot.left} x2={width - plot.right} y1={y(temperature)} y2={y(temperature)} />
              <text x={plot.left - 8} y={y(temperature) + 4} textAnchor="end">{temperature}°</text>
            </g>
          ))}
          <text className="temperature-chart__fever-label" x={width - plot.right} y={y(37.5) - 6} textAnchor="end">Fever threshold</text>
          {medicineDoses.map(({ dose, time }, index) => (
            <g className="temperature-chart__dose" key={dose.id}>
              <title>{`${dose.medicine_name_display ?? dose.medicine_name ?? "Medicine"}, ${when(dose.given_at)}`}</title>
              <line x1={x(time)} x2={x(time)} y1={plot.top} y2={height - plot.bottom} />
              <text x={x(time)} y={14 + (index % 2) * 12} textAnchor="middle">{(dose.medicine_name_display ?? dose.medicine_name ?? "Medicine").slice(0, 18)}</text>
            </g>
          ))}
          <polyline className="temperature-chart__line" points={points} />
          {readings.map(({ reading, time }) => (
            <g className="temperature-chart__reading" key={reading.id}>
              <title>{`${reading.value_celsius.toFixed(1)} °C, ${when(reading.recorded_at)}`}</title>
              <circle cx={x(time)} cy={y(reading.value_celsius)} r={4} />
              {readings.length <= 8 ? <text x={x(time)} y={y(reading.value_celsius) - 8} textAnchor="middle">{reading.value_celsius.toFixed(1)}°</text> : null}
            </g>
          ))}
          <g className="temperature-chart__axis">
            <text x={plot.left} y={height - 8} textAnchor="start">{timeLabel(firstTime)}</text>
            <text x={width - plot.right} y={height - 8} textAnchor="end">{timeLabel(lastTime)}</text>
          </g>
        </svg>
      </div>
    </section>
  );
}

export function FamilyView({
  members,
  revision,
  onDataChanged,
  initialArea = "overview",
  initialChildId = null,
  initialHomeworkId = null,
  initialReadingId = null,
  initialPresentId = null,
  initialBirthdayId = null,
  initialPhotoId = null,
  initialArtworkId = null,
  initialHealthTab,
  initialVaccinationKey = null,
  requestedAction,
  onRequestedActionConsumed,
  onOpenDocuments,
  onOpenBirthdayTask,
  onOpenBirthdayEvent,
  onOpenBirthdayPresents,
  onAreaChange,
  onChildChange,
  onMemberUpdated,
}: {
  members: FamilyMember[];
  revision: number;
  onDataChanged: () => void;
  initialArea?: FamilyArea;
  initialChildId?: string | null;
  initialHomeworkId?: string | null;
  initialReadingId?: string | null;
  initialPresentId?: string | null;
  initialBirthdayId?: string | null;
  initialPhotoId?: string | null;
  initialArtworkId?: string | null;
  initialHealthTab?: "growth" | "illnesses" | "summary" | "vaccinations";
  initialVaccinationKey?: string | null;
  requestedAction?: { kind: "medicine"; nonce: number } | null;
  onRequestedActionConsumed?: () => void;
  onOpenDocuments?: (childId?: string) => void;
  onOpenBirthdayTask?: (taskId: string) => void;
  onOpenBirthdayEvent?: (eventId: string, date: string) => void;
  onOpenBirthdayPresents?: (birthdayId: string) => void;
  onAreaChange?: (area: FamilyArea) => void;
  onChildChange?: (childId: string | null) => void;
  onMemberUpdated?: (member: FamilyMember) => void;
}) {
  const [area, setArea] = useState<FamilyArea>(initialArea);
  const [selectedChild, setSelectedChild] = useState<string>(initialChildId ?? "all");
  const [children, setChildren] = useState<Child[]>([]);
  const [childHub, setChildHub] = useState<Child | null>(null);
  const [naps, setNaps] = useState<NapRecord[]>([]);
  const [charts, setCharts] = useState<StarChart[]>([]);
  const [balances, setBalances] = useState<Record<string, Balance>>({});
  const [medicineTypes, setMedicineTypes] = useState<MedicineType[]>([]);
  const [doses, setDoses] = useState<MedicineDose[]>([]);
  const [illnesses, setIllnesses] = useState<Illness[]>([]);
  const [todayEvents, setTodayEvents] = useState<CalendarEvent[]>([]);
  const [todayRoutines, setTodayRoutines] = useState<TodayRoutine[]>([]);
  const [todayMedicine, setTodayMedicine] = useState<TodayMedicine[]>([]);
  const [todayAvailable, setTodayAvailable] = useState(false);
  const [starProgressAvailable, setStarProgressAvailable] = useState(false);
  const [temperatures, setTemperatures] = useState<TemperatureReading[]>([]);
  const [illnessDetail, setIllnessDetail] = useState<IllnessDetail | null>(null);
  const [illnessDetailLoading, setIllnessDetailLoading] = useState(false);
  const [illnessDetailError, setIllnessDetailError] = useState<string | null>(null);
  const [growth, setGrowth] = useState<GrowthRecord[]>([]);
  const [avatarMember, setAvatarMember] = useState<FamilyMember | null>(null);
  const [avatarNotice, setAvatarNotice] = useState<string | null>(null);
  const consumedRequestedAction = useRef<number | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [partial, setPartial] = useState(false);
  const [working, setWorking] = useState<string | null>(null);
  const [actionError, setActionError] = useState<string | null>(null);
  const [showCreateChart, setShowCreateChart] = useState(false);
  const [showAdjustBalance, setShowAdjustBalance] = useState(false);
  const [chartTitle, setChartTitle] = useState("Star Chart");
  const [chartRows, setChartRows] = useState(5);
  const [chartColumns, setChartColumns] = useState(5);
  const [chartReward, setChartReward] = useState("5.00");
  const [adjustmentType, setAdjustmentType] = useState<"payout" | "bonus" | "correction">("payout");
  const [adjustmentAmount, setAdjustmentAmount] = useState("");
  const [adjustmentNotes, setAdjustmentNotes] = useState("");
  const [celebration, setCelebration] = useState<{ reward: number; balance: string } | null>(null);
  const [temperatureValue, setTemperatureValue] = useState("");
  const [temperatureRecordedAt, setTemperatureRecordedAt] = useState(() => localDateTimeInputValue());
  const [temperatureNotes, setTemperatureNotes] = useState("");
  const [showIllnessStart, setShowIllnessStart] = useState(false);
  const [editingIllness, setEditingIllness] = useState<Illness | null>(null);
  const [illnessStartedAt, setIllnessStartedAt] = useState(() => localDateTimeInputValue());
  const [illnessNotes, setIllnessNotes] = useState("");
  const [showMedicineEntry, setShowMedicineEntry] = useState(false);
  const [medicineChild, setMedicineChild] = useState("");
  const [medicineTypeID, setMedicineTypeID] = useState("other");
  const [medicineName, setMedicineName] = useState("");
  const [doseAmount, setDoseAmount] = useState("");
  const [medicineGivenAt, setMedicineGivenAt] = useState(() => localDateTimeInputValue());
  const [medicineNotes, setMedicineNotes] = useState("");
  const [medicineOperation, setMedicineOperation] = useState<{ id: string; fingerprint: string } | null>(null);
  const [medicineFeedback, setMedicineFeedback] = useState<{ warnings: MedicineWarning[] } | null>(null);
  const [showMedicineTypeEditor, setShowMedicineTypeEditor] = useState(false);
  const [editingMedicineType, setEditingMedicineType] = useState<MedicineType | null>(null);
  const [medicineTypeDraft, setMedicineTypeDraft] = useState({ childId: "", name: "", defaultDose: "", minHours: "4", maxDoses: "4", notes: "" });
  const [medicineTypeOperationID, setMedicineTypeOperationID] = useState<string | null>(null);
  const [showGrowthEntry, setShowGrowthEntry] = useState(false);
  const [growthChild, setGrowthChild] = useState("");
  const [growthDate, setGrowthDate] = useState(() => localDateInputValue());
  const [heightCM, setHeightCM] = useState("");
  const [weightKG, setWeightKG] = useState("");
  const [growthNotes, setGrowthNotes] = useState("");

  const load = useCallback(async (background = false) => {
    if (!background) setLoading(true);
    setError(null);
    setPartial(false);
    try {
      // Start the child list alongside area fetches that don't depend on it.
      const childrenPromise = api<Child[]>("/children/");
      let missedOptionalFeed = false;
      async function optional<T>(path: string, fallback: T): Promise<T> {
        try {
          return await api<T>(path);
        } catch {
          missedOptionalFeed = true;
          return fallback;
        }
      }
      const finishChildren = (childItems: Child[]) => {
        setChildren(childItems);
        setSelectedChild((current) => {
          if (current !== "all" && childItems.some((child) => child.id === current)) return current;
          return CHILD_FOCUSED_AREAS.includes(area) && childItems[0] ? childItems[0].id : "all";
        });
        return childItems;
      };

      if (area === "overview") {
        const timezoneName = Intl.DateTimeFormat().resolvedOptions().timeZone || "Europe/London";
        const [childItems, dashboard, chartItems] = await Promise.all([
          childrenPromise,
          optional<FamilyTodayDashboard | null>(`/briefing/dashboard?timezone=${encodeURIComponent(timezoneName)}`, null),
          optional<StarChart[] | null>("/star-charts/?active=true&limit=200", null),
        ]);
        finishChildren(childItems);
        if (dashboard) {
          setNaps(dashboard.naps);
          setIllnesses(dashboard.illnesses);
          setTodayEvents(dashboard.events);
          setTodayRoutines(dashboard.routines);
          setTodayMedicine(dashboard.medicine);
          const dailySummaryFeeds = new Set(["events", "naps", "illnesses", "routines", "medicine"]);
          setTodayAvailable(!dashboard.unavailable.some((feed) => dailySummaryFeeds.has(feed)));
          const familySummaryFeeds = new Set([...dailySummaryFeeds, "family_members"]);
          if (dashboard.unavailable.some((feed) => familySummaryFeeds.has(feed))) missedOptionalFeed = true;
        } else setTodayAvailable(false);
        if (chartItems) {
          setStarProgressAvailable(true);
          setCharts(chartItems);
        } else setStarProgressAvailable(false);
      } else if (area === "stars") {
        const [childItems, chartItems] = await Promise.all([
          childrenPromise,
          optional<StarChart[]>("/star-charts/?limit=50", []),
        ]);
        finishChildren(childItems);
        const childBalances = await Promise.all(
          childItems.map((child) => optional<Balance | null>(`/star-charts/balance/${child.id}`, null)),
        );
        setCharts(chartItems);
        setBalances(
          Object.fromEntries(childBalances.filter((item): item is Balance => Boolean(item)).map((item) => [item.child_id, item])),
        );
      } else if (area === "sleep") {
        const [childItems, napItems] = await Promise.all([
          childrenPromise,
          optional<NapRecord[]>("/naps/?limit=50", []),
        ]);
        finishChildren(childItems);
        setNaps(napItems);
      } else if (area === "medicine") {
        const [childItems, typeItems, doseItems] = await Promise.all([
          childrenPromise,
          optional<MedicineType[]>("/medicine/types?limit=200", []),
          optional<MedicineDose[]>("/medicine/doses?limit=50", []),
        ]);
        finishChildren(childItems);
        setMedicineTypes(typeItems);
        setDoses(doseItems);
      } else if (area === "illness") {
        const [childItems, illnessItems, temperatureItems, typeItems] = await Promise.all([
          childrenPromise,
          optional<Illness[]>("/illness/?limit=50", []),
          optional<TemperatureReading[]>("/illness/temperature?limit=50", []),
          optional<MedicineType[]>("/medicine/types?limit=200", []),
        ]);
        finishChildren(childItems);
        setIllnesses(illnessItems);
        setTemperatures(temperatureItems);
        setMedicineTypes(typeItems);
      } else if (area === "learning") {
        finishChildren(await childrenPromise);
      } else if (area === "growth") {
        const [childItems, growthItems] = await Promise.all([
          childrenPromise,
          optional<GrowthRecord[]>("/growth/?limit=50", []),
        ]);
        finishChildren(childItems);
        setGrowth(growthItems);
      } else if (area === "artwork") {
        finishChildren(await childrenPromise);
      } else if (area === "photos") {
        finishChildren(await childrenPromise);
      } else if (area === "presents") {
        finishChildren(await childrenPromise);
      } else if (area === "dog") {
        finishChildren(await childrenPromise);
      } else if (area === "birthdays") {
        finishChildren(await childrenPromise);
      } else {
        finishChildren(await childrenPromise);
      }
      setPartial(missedOptionalFeed);
    } catch (requestError) {
      setError(requestError instanceof Error ? requestError.message : "Family information is unavailable.");
    } finally {
      setLoading(false);
    }
  }, [area]);

  const lastRevision = useRef(revision);
  useEffect(() => {
    const background = revision !== lastRevision.current;
    lastRevision.current = revision;
    void load(background);
  }, [load, revision]);

  useEffect(() => {
    setArea(initialArea);
  }, [initialArea]);

  useEffect(() => {
    if (initialChildId) setSelectedChild(initialChildId);
  }, [initialChildId]);

  useEffect(() => {
    if (area !== "illness" || selectedChild === "all") {
      setIllnessDetail(null);
      setIllnessDetailLoading(false);
      setIllnessDetailError(null);
      return;
    }

    const activeIllness = illnesses.find((illness) => illness.child_id === selectedChild && !illness.ended_at);
    if (!activeIllness) {
      setIllnessDetail(null);
      setIllnessDetailLoading(false);
      setIllnessDetailError(null);
      return;
    }

    let cancelled = false;
    setIllnessDetailLoading(true);
    setIllnessDetailError(null);
    void api<IllnessDetail>(`/illness/${activeIllness.id}/detail`)
      .then((detail) => {
        if (!cancelled) setIllnessDetail(detail);
      })
      .catch(() => {
        if (!cancelled) {
          setIllnessDetail(null);
          setIllnessDetailError("Medicine timing could not be loaded. You can still record a dose with the full form.");
        }
      })
      .finally(() => {
        if (!cancelled) setIllnessDetailLoading(false);
      });

    return () => {
      cancelled = true;
    };
  }, [area, illnesses, selectedChild]);

  const childNames = useMemo(() => new Map(children.map((child) => [child.id, child.name])), [children]);
  const medicineNames = useMemo(() => new Map(medicineTypes.map((type) => [type.id, type.name])), [medicineTypes]);
  const applies = (childID: string) => selectedChild === "all" || childID === selectedChild;
  const activeNaps = naps.filter((nap) => !nap.ended_at && applies(nap.child_id));
  const filteredCharts = charts.filter((chart) => applies(chart.child_id));
  const activeCharts = filteredCharts.filter((chart) => !chart.completed_at);
  const completedCharts = filteredCharts.filter((chart) => Boolean(chart.completed_at));
  const filteredDoses = doses.filter((dose) => applies(dose.child_id));
  const filteredMedicineTypes = medicineTypes.filter((medicine) => applies(medicine.child_id));
  const filteredIllnesses = illnesses.filter((illness) => applies(illness.child_id));
  const filteredTemperatures = temperatures.filter((reading) => applies(reading.child_id));
  const filteredGrowth = growth.filter((record) => applies(record.child_id));

  useEffect(() => {
    if (
      requestedAction?.kind !== "medicine"
      || requestedAction.nonce === consumedRequestedAction.current
      || area !== "medicine"
      || loading
      || !children.length
    ) return;
    consumedRequestedAction.current = requestedAction.nonce;
    openMedicineForm();
    onRequestedActionConsumed?.();
  }, [area, children.length, loading, onRequestedActionConsumed, requestedAction]);

  async function runAction(key: string, action: () => Promise<unknown>): Promise<boolean> {
    setWorking(key);
    setActionError(null);
    try {
      await action();
      onDataChanged();
      return true;
    } catch (requestError) {
      setActionError(requestError instanceof Error ? requestError.message : "That family update could not be saved.");
      return false;
    } finally {
      setWorking(null);
    }
  }

  function preferredChildID(): string {
    return selectedChild !== "all" ? selectedChild : children[0]?.id ?? "";
  }

  function openNewMedicineType() {
    setEditingMedicineType(null);
    setMedicineTypeDraft({ childId: preferredChildID(), name: "", defaultDose: "", minHours: "4", maxDoses: "4", notes: "" });
    setMedicineTypeOperationID(null);
    setActionError(null);
    setShowMedicineTypeEditor(true);
  }

  function openEditMedicineType(medicine: MedicineType) {
    setEditingMedicineType(medicine);
    setMedicineTypeDraft({
      childId: medicine.child_id,
      name: medicine.name,
      defaultDose: medicine.default_dose_amount ?? "",
      minHours: String(medicine.min_hours_between_doses),
      maxDoses: String(medicine.max_doses_24h),
      notes: medicine.notes ?? "",
    });
    setMedicineTypeOperationID(null);
    setActionError(null);
    setShowMedicineTypeEditor(true);
  }

  function closeMedicineTypeEditor() {
    setShowMedicineTypeEditor(false);
    setEditingMedicineType(null);
    setMedicineTypeOperationID(null);
  }

  async function saveMedicineType(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    const name = medicineTypeDraft.name.trim();
    const minHours = Number(medicineTypeDraft.minHours);
    const maxDoses = Number(medicineTypeDraft.maxDoses);
    if (!medicineTypeDraft.childId || !name) {
      setActionError("Choose a child and enter the medicine name.");
      return;
    }
    if (!Number.isFinite(minHours) || minHours < 0.25 || minHours > 168) {
      setActionError("Minimum time between doses must be between 0.25 and 168 hours.");
      return;
    }
    if (!Number.isInteger(maxDoses) || maxDoses < 1 || maxDoses > 24) {
      setActionError("Maximum doses must be a whole number between 1 and 24.");
      return;
    }

    setWorking("medicine-type");
    setActionError(null);
    const payload = {
      child_id: medicineTypeDraft.childId,
      name,
      default_dose_amount: medicineTypeDraft.defaultDose.trim() || null,
      min_hours_between_doses: minHours,
      max_doses_24h: maxDoses,
      notes: medicineTypeDraft.notes.trim() || null,
    };
    try {
      if (editingMedicineType) {
        await api(`/medicine/types/${editingMedicineType.id}`, { method: "PUT", body: JSON.stringify(payload) });
      } else {
        const operationID = medicineTypeOperationID ?? crypto.randomUUID();
        setMedicineTypeOperationID(operationID);
        await api("/medicine/types", { method: "POST", body: JSON.stringify({ id: operationID, ...payload }) });
      }
      closeMedicineTypeEditor();
      onDataChanged();
      await load();
    } catch (requestError) {
      setActionError(requestError instanceof Error ? requestError.message : "The medicine settings could not be saved.");
    } finally {
      setWorking(null);
    }
  }

  function openMedicineForm() {
    const childID = preferredChildID();
    const firstType = medicineTypes.find((item) => item.child_id === childID);
    setMedicineChild(childID);
    setMedicineTypeID(firstType?.id ?? "other");
    setDoseAmount(firstType?.default_dose_amount ?? "");
    setMedicineName("");
    setMedicineGivenAt(localDateTimeInputValue());
    setMedicineNotes("");
    setMedicineOperation(null);
    setMedicineFeedback(null);
    setShowMedicineEntry(true);
  }

  function reviewIllnessMedicine(nextDose: NextDoseTime) {
    if (selectedChild === "all") return;
    setMedicineChild(selectedChild);
    setMedicineTypeID(nextDose.medicine_type_id);
    setDoseAmount(nextDose.default_dose_amount ?? "");
    setMedicineName("");
    setMedicineGivenAt(localDateTimeInputValue());
    setMedicineNotes("");
    setMedicineOperation(null);
    setMedicineFeedback(null);
    setActionError(null);
    setShowMedicineEntry(true);
  }

  async function recordMedicine(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (!medicineChild) return;
    if (medicineTypeID === "other" && !medicineName.trim()) {
      setActionError("Enter the medicine name.");
      return;
    }
    const givenAt = new Date(medicineGivenAt);
    if (Number.isNaN(givenAt.getTime())) {
      setActionError("Enter a valid time for the dose.");
      return;
    }
    setWorking("record-medicine");
    setActionError(null);
    const dosePayload = {
      child_id: medicineChild,
      medicine_type_id: medicineTypeID === "other" ? null : medicineTypeID,
      medicine_name: medicineTypeID === "other" ? medicineName.trim() : null,
      dose_amount: doseAmount.trim() || null,
      given_at: givenAt.toISOString(),
      notes: medicineNotes.trim() || null,
    };
    const fingerprint = JSON.stringify(dosePayload);
    const operation = medicineOperation ?? { id: crypto.randomUUID(), fingerprint };
    setMedicineOperation(operation);
    try {
      const result = await api<MedicineDoseResult>("/medicine/doses", {
        method: "POST",
        body: JSON.stringify({
          id: operation.id,
          ...dosePayload,
        }),
      });
      setMedicineOperation(null);
      setMedicineFeedback({ warnings: result.warnings });
      setShowMedicineEntry(false);
      onDataChanged();
      await load();
    } catch (requestError) {
      setActionError(requestError instanceof Error ? requestError.message : "The medicine dose could not be recorded.");
    } finally {
      setWorking(null);
    }
  }

  function medicineFeedbackBanner() {
    if (!medicineFeedback) return null;
    return medicineFeedback.warnings.length ? (
      <div className="medicine-feedback medicine-feedback--warning" role="alert">
        <AlertTriangle aria-hidden="true" size={20} />
        <div><strong>Dose recorded with a saved-limit warning</strong>{medicineFeedback.warnings.map((warning, index) => <p key={`${warning.type}-${index}`}>{warning.message}</p>)}</div>
      </div>
    ) : <div className="medicine-feedback medicine-feedback--ok" role="status"><Check aria-hidden="true" size={19} /><strong>Dose recorded</strong></div>;
  }

  function openGrowthForm() {
    setGrowthChild(preferredChildID());
    setGrowthDate(localDateInputValue());
    setHeightCM("");
    setWeightKG("");
    setGrowthNotes("");
    setShowGrowthEntry(true);
  }

  async function recordGrowth(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    const height = heightCM.trim() ? Number(heightCM) : null;
    const weight = weightKG.trim() ? Number(weightKG) : null;
    if (height == null && weight == null) {
      setActionError("Enter a height or weight.");
      return;
    }
    if ((height != null && (!Number.isFinite(height) || height <= 0)) || (weight != null && (!Number.isFinite(weight) || weight <= 0))) {
      setActionError("Enter valid positive measurements.");
      return;
    }
    const saved = await runAction("record-growth", () => api("/growth/", {
      method: "POST",
      body: JSON.stringify({
        child_id: growthChild,
        date: growthDate,
        height_cm: height,
        weight_kg: weight,
        notes: growthNotes.trim() || null,
      }),
    }));
    if (saved) setShowGrowthEntry(false);
  }

  function chooseArea(nextArea: FamilyArea) {
    if (CHILD_FOCUSED_AREAS.includes(nextArea) && selectedChild === "all" && children[0]) {
      selectChild(children[0].id);
    }
    setArea(nextArea);
    onAreaChange?.(nextArea);
  }

  function selectChild(childId: string) {
    setSelectedChild(childId);
    onChildChange?.(childId === "all" ? null : childId);
  }

  function chooseChildArea(child: Child, nextArea: FamilyArea) {
    selectChild(child.id);
    setChildHub(null);
    chooseArea(nextArea);
  }

  async function placeStar(chart: StarChart, row: number, column: number) {
    const key = `star-${chart.id}-${row}-${column}`;
    setWorking(key);
    setActionError(null);
    try {
      const result = await api<StarRecord | CompletedChartResponse>(`/star-charts/${chart.id}/stars`, {
        method: "POST",
        body: JSON.stringify({ row_index: row, col_index: column }),
      });
      if ("chart" in result) {
        setCelebration({ reward: result.reward_amount_pence, balance: result.new_balance_display });
      }
      onDataChanged();
    } catch (requestError) {
      setActionError(requestError instanceof Error ? requestError.message : "The star could not be added.");
    } finally {
      setWorking(null);
    }
  }

  async function createChart(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (selectedChild === "all") return;
    const rewardPence = Math.round(Number(chartReward) * 100);
    if (!Number.isFinite(rewardPence) || rewardPence < 0) {
      setActionError("Enter a valid reward amount.");
      return;
    }
    const created = await runAction("create-chart", () => api("/star-charts/", {
      method: "POST",
      body: JSON.stringify({
        child_id: selectedChild,
        title: chartTitle.trim() || "Star Chart",
        grid_rows: chartRows,
        grid_columns: chartColumns,
        reward_amount_pence: rewardPence,
      }),
    }));
    if (!created) return;
    setShowCreateChart(false);
    setChartTitle("Star Chart");
    setChartRows(5);
    setChartColumns(5);
    setChartReward("5.00");
  }

  async function adjustBalance(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (selectedChild === "all") return;
    const rawPence = Math.round(Number(adjustmentAmount) * 100);
    if (!Number.isFinite(rawPence) || rawPence <= 0) {
      setActionError("Enter an amount greater than zero.");
      return;
    }
    const currentBalance = balances[selectedChild]?.balance_pence ?? 0;
    if (adjustmentType === "payout" && rawPence > currentBalance) {
      setActionError("The payout cannot be greater than the current balance.");
      return;
    }
    const adjusted = await runAction("adjust-balance", () => api(`/star-charts/balance/${selectedChild}/adjust`, {
      method: "POST",
      body: JSON.stringify({
        amount_pence: adjustmentType === "payout" ? -rawPence : rawPence,
        reason: adjustmentType === "payout" ? "payout" : "manual_adjustment",
        notes: adjustmentNotes.trim() || adjustmentType,
      }),
    }));
    if (!adjusted) return;
    setShowAdjustBalance(false);
    setAdjustmentAmount("");
    setAdjustmentNotes("");
    setAdjustmentType("payout");
  }

  function openIllnessStartForm() {
    setIllnessStartedAt(localDateTimeInputValue());
    setIllnessNotes("");
    setActionError(null);
    setShowIllnessStart(true);
  }

  function openIllnessNotes(illness: Illness) {
    setIllnessNotes(illness.notes ?? "");
    setActionError(null);
    setEditingIllness(illness);
  }

  async function startIllnessMode(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (selectedChild === "all") return;
    const startedAt = new Date(illnessStartedAt);
    if (Number.isNaN(startedAt.getTime())) {
      setActionError("Enter a valid start time for the illness.");
      return;
    }
    const created = await runAction(`illness-${selectedChild}`, () => api("/illness/", {
      method: "POST",
      body: JSON.stringify({
        child_id: selectedChild,
        started_at: startedAt.toISOString(),
        notes: illnessNotes.trim() || null,
      }),
    }));
    if (created) setShowIllnessStart(false);
  }

  async function updateIllnessNotes(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (!editingIllness) return;
    const updated = await runAction(`illness-notes-${editingIllness.id}`, () => api(`/illness/${editingIllness.id}`, {
      method: "PUT",
      body: JSON.stringify({ notes: illnessNotes.trim() || null }),
    }));
    if (updated) setEditingIllness(null);
  }

  async function endIllnessMode(illness: Illness) {
    await runAction(`illness-${illness.id}`, () => api(`/illness/${illness.id}`, {
      method: "PUT",
      body: JSON.stringify({ ended_at: new Date().toISOString() }),
    }));
  }

  async function logTemperature(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (selectedChild === "all") return;
    const value = Number(temperatureValue);
    if (!Number.isFinite(value) || value < 35 || value > 42) {
      setActionError("Enter a temperature between 35.0 and 42.0 °C.");
      return;
    }
    const recordedAt = new Date(temperatureRecordedAt);
    if (Number.isNaN(recordedAt.getTime())) {
      setActionError("Enter a valid time for the temperature reading.");
      return;
    }
    const activeIllness = illnesses.find((illness) => illness.child_id === selectedChild && !illness.ended_at);
    const logged = await runAction(`temperature-${selectedChild}`, () => api("/illness/temperature", {
      method: "POST",
      body: JSON.stringify({
        child_id: selectedChild,
        illness_id: activeIllness?.id ?? null,
        value_celsius: value,
        recorded_at: recordedAt.toISOString(),
        notes: temperatureNotes.trim() || null,
      }),
    }));
    if (logged) {
      setTemperatureValue("");
      setTemperatureRecordedAt(localDateTimeInputValue());
      setTemperatureNotes("");
    }
  }

  async function startNap(child: Child) {
    const startedAt = new Date().toISOString();
    await runAction(`nap-${child.id}`, () => api("/naps/start", {
      method: "POST",
      body: JSON.stringify({ id: crypto.randomUUID(), child_id: child.id, started_at: startedAt, sleep_type: "nap" }),
    }));
  }

  async function endNap(nap: NapRecord) {
    const endedAt = new Date().toISOString();
    await runAction(`nap-${nap.id}`, () => api(`/naps/${nap.id}/end`, {
      method: "PATCH",
      body: JSON.stringify({ ended_at: endedAt }),
    }));
  }

  function childCareSummary(child: Child): { text: string; tone: string; icon: typeof Star } | null {
    if (!todayAvailable) return { text: "Today's care could not be loaded", tone: "quiet", icon: RefreshCw };
    const nap = naps.find((item) => item.child_id === child.id && !item.ended_at);
    if (nap) return { text: `Sleeping since ${when(nap.started_at)}`, tone: "sleep", icon: Moon };
    if (illnesses.some((item) => item.child_id === child.id && !item.ended_at)) {
      return { text: "Illness mode is active", tone: "illness", icon: Thermometer };
    }
    const medicine = todayMedicine.find((item) => item.child_id === child.id || item.child_name === child.name);
    if (medicine?.is_safe_now) return { text: `${medicine.medicine_name} can be recorded now`, tone: "medicine", icon: Pill };
    if (medicine?.next_safe_at) {
      const nextTime = parseISO(medicine.next_safe_at);
      const label = Number.isNaN(nextTime.getTime()) ? "later" : format(nextTime, "HH:mm");
      return { text: `${medicine.medicine_name} from ${label}`, tone: "medicine", icon: Pill };
    }
    return null;
  }

  function childPlanItems(childId: string): string[] {
    if (!todayAvailable) return [];
    const routinesForChild = todayRoutines.filter((item) => item.person_id === childId).map((item) => item.name);
    const eventsForChild = todayEvents
      .filter((event) => event.assigned_to === childId || event.family_member_ids?.includes(childId) || event.affected_member_ids?.includes(childId))
      .map((event) => {
        if (event.all_day || event.start_time.length === 10) return event.title;
        const startsAt = parseISO(event.start_time);
        return Number.isNaN(startsAt.getTime()) ? event.title : `${format(startsAt, "HH:mm")} · ${event.title}`;
      });
    return [...new Set([...routinesForChild, ...eventsForChild])];
  }

  function activeChartFor(childId: string): StarChart | undefined {
    if (!starProgressAvailable) return undefined;
    return charts.find((chart) => chart.child_id === childId && !chart.completed_at);
  }

  function childNextAction(child: Child): { label: string; area: FamilyArea | null; icon: typeof Star } {
    if (todayAvailable && naps.some((item) => item.child_id === child.id && !item.ended_at)) return { label: "Open sleep", area: "sleep", icon: Moon };
    if (todayAvailable && illnesses.some((item) => item.child_id === child.id && !item.ended_at)) return { label: "Open illness mode", area: "illness", icon: Thermometer };
    if (todayAvailable && todayMedicine.some((item) => (item.child_id === child.id || item.child_name === child.name) && item.is_safe_now)) {
      return { label: "Record medicine", area: "medicine", icon: Pill };
    }
    if (activeChartFor(child.id)) return { label: "Award a star", area: "stars", icon: Star };
    return { label: `Open ${child.name}'s page`, area: null, icon: UsersRound };
  }

  return (
    <div className={cn("family-page", area === "overview" && "is-overview")}>
      <header className="page-header family-header">
        <div>
          {area !== "overview" ? <button type="button" className="nested-back" onClick={() => chooseArea("overview")}><ChevronLeft aria-hidden="true" size={18} /> Family</button> : <p className="page-eyebrow">Your household</p>}
          <h1>{area === "overview" ? "Family" : area === "stars" ? "Star Charts" : area === "learning" ? "Homework" : area === "caregiver" ? "Babysitter handover" : area[0].toUpperCase() + area.slice(1)}</h1>
        </div>
        <button type="button" className="icon-button" aria-label="Refresh family" onClick={() => void load()}>
          <RefreshCw aria-hidden="true" size={18} />
        </button>
      </header>

      {error ? <ErrorState message={error} retry={load} /> : null}
      {partial ? <div className="family-summary-recovery" role="status"><span>A few family details could not be loaded.</span><button type="button" className="button button--secondary button--compact" onClick={() => void load()}>Try again</button></div> : null}
      {actionError ? <div className="form-error" role="alert">{actionError}</div> : null}
      {loading ? <SkeletonList rows={7} /> : null}

      {!loading && !error ? (
        <>
          {area === "overview" ? <section className="family-people" aria-labelledby="family-people-heading">
            <div className="section-heading family-section-title">
              <div><p className="page-eyebrow">At a glance</p><h2 id="family-people-heading">Today by person</h2><p>Care, plans and the next useful thing — together.</p></div>
            </div>
            {avatarNotice ? <div className="inline-success" role="status">{avatarNotice}</div> : null}
            {members.some((member) => member.member_type === "user") ? <div className="family-adults" aria-label="Adults">
              <h3>Adults</h3>
              <div>{members.filter((member) => member.member_type === "user").map((member) => <div className="family-adult" key={member.id}>
                <button type="button" className="roster-avatar-button" aria-label={`Change photo for ${member.name}`} onClick={() => setAvatarMember(member)}>
                  <PersonAvatar member={member} />
                  <span className="roster-avatar-camera"><Camera aria-hidden="true" size={12} /></span>
                </button>
                <span><strong>{member.name}</strong><small>Adult</small></span>
              </div>)}</div>
            </div> : null}
            <div className="family-person-grid">
              {children.map((child) => {
                const member = members.find((item) => item.id === child.id);
                const avatar = member ?? { id: child.id, name: child.name, member_type: "child" as const };
                const care = childCareSummary(child);
                const CareIcon = care?.icon;
                const plans = childPlanItems(child.id);
                const chart = activeChartFor(child.id);
                const action = childNextAction(child);
                const ActionIcon = action.icon;
                return <article className="family-person-card" key={child.id}>
                  <header className="family-person-card__header">
                    {member ? <button type="button" className="roster-avatar-button" aria-label={`Change photo for ${child.name}`} onClick={() => setAvatarMember(member)}>
                      <PersonAvatar member={avatar} className="is-child" />
                      <span className="roster-avatar-camera"><Camera aria-hidden="true" size={11} /></span>
                    </button> : <PersonAvatar member={avatar} className="is-child" />}
                    <button type="button" className="family-person-open" onClick={() => { selectChild(child.id); setChildHub(child); }} aria-label={`Open ${child.name}'s family page`}>
                      <span><strong>{child.name}</strong><small>{childAge(child.date_of_birth)} · Care, school & memories</small></span>
                      <ChevronRight aria-hidden="true" size={18} />
                    </button>
                  </header>
                  {care && CareIcon ? <div className={`family-person-care is-${care.tone}`}><CareIcon aria-hidden="true" size={17} /><strong>{care.text}</strong></div> : null}
                  <div className="family-person-today">
                    <span>Today</span>
                    {!todayAvailable ? <p>Today's plans could not be loaded.</p> : plans.length ? <ul>{plans.slice(0, 2).map((item) => <li key={item}>{item}</li>)}{plans.length > 2 ? <li className="is-more">+{plans.length - 2} more today</li> : null}</ul> : <p>Nothing is linked just to {child.name} today.</p>}
                  </div>
                  {!starProgressAvailable || chart ? <div className="family-person-stars">
                    {!starProgressAvailable ? <span><RefreshCw aria-hidden="true" size={15} />Star progress could not be loaded</span> : chart ? <><div><span><Star aria-hidden="true" size={15} fill="currentColor" />{chart.title}</span><strong>{chart.stars_count} of {chart.total_cells}</strong></div><progress aria-label={`${chart.title} star progress`} max={Math.max(chart.total_cells, 1)} value={chart.stars_count} /></> : null}
                  </div> : null}
                  <button type="button" className="family-person-action" onClick={() => action.area ? chooseChildArea(child, action.area) : setChildHub(child)}>
                    <ActionIcon aria-hidden="true" size={17} />{action.label}<ChevronRight aria-hidden="true" size={17} />
                  </button>
                </article>;
              })}
            </div>
            {!children.length ? <EmptyState title="No children yet" detail="Children added to your family will appear here." /> : null}
          </section> : null}

          {avatarMember ? <PersonAvatarEditor
            member={avatarMember}
            open
            onOpenChange={(open) => { if (!open) setAvatarMember(null); }}
            onSaved={(updated) => {
              onMemberUpdated?.(updated);
              setAvatarNotice(`${updated.name}'s photo is now updated.`);
              setAvatarMember(null);
            }}
          /> : null}

          {area !== "overview" && area !== "birthdays" && area !== "dog" && area !== "yearbook" && area !== "health" && area !== "caregiver" ? <div className="child-filter" role="group" aria-label="Choose child">
            {area !== "learning" && area !== "presents" ? <button type="button" className={selectedChild === "all" ? "is-active" : ""} onClick={() => selectChild("all")}>All children</button> : null}
            {children.map((child) => (
              <button type="button" className={selectedChild === child.id ? "is-active" : ""} onClick={() => selectChild(child.id)} key={child.id}>
                {child.name}
              </button>
            ))}
          </div> : null}

          <section className="family-workspace" aria-live="polite">
            {area === "overview" ? (
              <div className="hausklar">
                <div className="section-heading family-section-title"><div><p className="page-eyebrow">Shared</p><h2>Household</h2></div></div>
                <button type="button" className="family-feature-link is-documents" onClick={() => onOpenDocuments?.()}><Files aria-hidden="true" size={28} /><div><strong>Letters & documents</strong><span>Scan paperwork and review suggested actions</span></div><ChevronRight aria-hidden="true" size={20} /></button>
                <div className="family-tile-grid">
                  <FamilyTile title="Dog" icon={PawPrint} tone="brown" onClick={() => chooseArea("dog")} />
                  <FamilyTile title="Birthdays" icon={CakeSlice} tone="purple" onClick={() => chooseArea("birthdays")} />
                  <FamilyTile title="Presents" icon={Gift} tone="pink" onClick={() => chooseArea("presents")} />
                  <FamilyTile title="Babysitter" icon={ShieldCheck} tone="green" onClick={() => chooseArea("caregiver")} />
                </div>
              </div>
            ) : null}

            {area === "stars" ? (
              <div className="family-record-section">
                <div className="section-heading family-section-title">
                  <div><p className="page-eyebrow">Rewards</p><h2>{childNames.get(selectedChild) ?? "Star charts"}</h2></div>
                  <button type="button" className="button button--primary button--compact" onClick={() => setShowCreateChart(true)}><Plus aria-hidden="true" size={17} /> New chart</button>
                </div>
                <div className="star-balance-band">
                  <div><span>Owed</span><strong>{balances[selectedChild]?.balance_display ?? "£0.00"}</strong></div>
                  <button type="button" className="button button--secondary button--compact" onClick={() => setShowAdjustBalance(true)}>Adjust balance</button>
                </div>
                {!activeCharts.length ? <EmptyState title="No active star charts" detail="Create a chart for this child to start awarding stars." action={() => setShowCreateChart(true)} actionLabel="Create chart" /> : null}
                <div className="star-chart-list">
                  {activeCharts.map((chart) => {
                    const awarded = new Set(chart.stars.map((star) => `${star.row_index}:${star.col_index}`));
                    return (
                      <article className="web-star-chart" key={chart.id}>
                        <header><div><strong>{chart.title}</strong><span>Reward: £{(chart.reward_amount_pence / 100).toFixed(2)}</span></div><b>{chart.stars_count}/{chart.total_cells} stars</b></header>
                        <div className="star-progress" role="progressbar" aria-label={`${chart.title} progress`} aria-valuemin={0} aria-valuemax={chart.total_cells} aria-valuenow={chart.stars_count}><span style={{ width: `${chart.total_cells ? (chart.stars_count / chart.total_cells) * 100 : 0}%` }} /></div>
                        <div className="interactive-star-grid" style={{ gridTemplateColumns: `repeat(${chart.grid_columns}, minmax(44px, 1fr))` }}>
                          {Array.from({ length: chart.total_cells }).map((_, index) => {
                            const row = Math.floor(index / chart.grid_columns);
                            const column = index % chart.grid_columns;
                            const earned = awarded.has(`${row}:${column}`);
                            const actionKey = `star-${chart.id}-${row}-${column}`;
                            return (
                              <button
                                type="button"
                                className={cn(earned && "is-earned", working === actionKey && "is-placing")}
                                disabled={earned || Boolean(working)}
                                aria-label={`${childNames.get(chart.child_id) ?? "Child"}, ${chart.title}, row ${row + 1}, column ${column + 1}, ${earned ? "earned" : "not earned"}`}
                                onClick={() => void placeStar(chart, row, column)}
                                key={index}
                              >
                                <Star aria-hidden="true" size={22} fill={earned ? "currentColor" : "none"} />
                              </button>
                            );
                          })}
                        </div>
                      </article>
                    );
                  })}
                </div>
                {completedCharts.length ? (
                  <details className="completed-charts"><summary>Completed charts ({completedCharts.length})</summary>{completedCharts.map((chart) => <div key={chart.id}><Star aria-hidden="true" size={16} fill="currentColor" /><span>{chart.title}</span><strong>£{(chart.reward_amount_pence / 100).toFixed(2)}</strong></div>)}</details>
                ) : null}
              </div>
            ) : null}

            {area === "sleep" ? (
              <div className="family-record-section">
                <div className="section-heading family-section-title"><div><p className="page-eyebrow">Sleep</p><h2>Naps and bedtimes</h2></div></div>
                <div className="quick-family-actions">
                  {children.filter((child) => applies(child.id)).map((child) => {
                    const active = naps.find((nap) => nap.child_id === child.id && !nap.ended_at);
                    return active ? (
                      <button type="button" className="button button--primary" disabled={Boolean(working)} onClick={() => void endNap(active)} key={child.id}><Check aria-hidden="true" size={17} /> End {child.name}'s sleep</button>
                    ) : (
                      <button type="button" className="button button--secondary" disabled={Boolean(working)} onClick={() => void startNap(child)} key={child.id}><Moon aria-hidden="true" size={17} /> Start {child.name}'s nap</button>
                    );
                  })}
                </div>
                <div className="record-list">
                  {naps.filter((nap) => applies(nap.child_id)).map((nap) => (
                    <div className="record-row" key={nap.id}><Moon aria-hidden="true" size={18} /><div><strong>{childNames.get(nap.child_id)} · {activityLabel(nap.sleep_type)}</strong><span>{nap.ended_at ? `${Math.round(nap.duration_minutes ?? 0)} minutes` : "Sleeping now"} · {when(nap.started_at)}</span></div></div>
                  ))}
                </div>
              </div>
            ) : null}

            {area === "medicine" || area === "illness" || area === "growth" ? (
              <div className="family-record-section">
                <div className="section-heading family-section-title">
                  <div><p className="page-eyebrow">Health records</p><h2>{area === "medicine" ? "Medicine" : area === "illness" ? "Illness mode" : "Growth"}</h2></div>
                  {area === "medicine" ? <div className="section-actions"><button type="button" className="button button--secondary button--compact" disabled={!children.length} onClick={openNewMedicineType}><Plus aria-hidden="true" size={17} /> Add medicine</button><button type="button" className="button button--primary button--compact" disabled={!children.length} onClick={openMedicineForm}><Pill aria-hidden="true" size={17} /> Record medicine</button></div> : null}
                  {area === "growth" ? <button type="button" className="button button--primary button--compact" disabled={!children.length} onClick={openGrowthForm}><Plus aria-hidden="true" size={17} /> Add measurement</button> : null}
                </div>
                <p className="medical-note">HausKlar provides reminders and record-keeping only, not medical advice.</p>
                {area === "illness" && selectedChild !== "all" ? (() => {
                  const activeIllness = illnesses.find((illness) => illness.child_id === selectedChild && !illness.ended_at);
                  return (
                    <section className={cn("illness-mode", activeIllness && "is-active")} aria-labelledby="illness-mode-heading">
                      <div className="illness-mode-heading">
                        <div><span>{activeIllness ? "Active now" : "Not active"}</span><h3 id="illness-mode-heading">Illness mode</h3><p>{activeIllness ? `Started ${when(activeIllness.started_at)}${activeIllness.notes ? ` · ${activeIllness.notes}` : ""}` : `Start a focused health log for ${childNames.get(selectedChild)}.`}</p></div>
                        {activeIllness ? (
                          <div className="section-actions"><button type="button" className="button button--secondary button--compact" disabled={Boolean(working)} onClick={() => openIllnessNotes(activeIllness)}><Edit3 aria-hidden="true" size={16} /> Edit notes</button><button type="button" className="button button--secondary button--compact" disabled={Boolean(working)} onClick={() => void endIllnessMode(activeIllness)}>End illness mode</button></div>
                        ) : (
                          <button type="button" className="button button--primary" disabled={Boolean(working)} onClick={openIllnessStartForm}><HeartPulse aria-hidden="true" size={17} /> Start illness mode</button>
                        )}
                      </div>
                      {activeIllness ? (
                        <>
                          {medicineFeedbackBanner()}
                          <section className="illness-medicine" aria-labelledby="illness-medicine-heading">
                            <div className="illness-medicine-heading">
                              <div><h4 id="illness-medicine-heading">Medicine</h4><p>Timing is checked against doses already recorded for {childNames.get(selectedChild)}.</p></div>
                              <button type="button" className="button button--secondary button--compact" disabled={Boolean(working)} onClick={openMedicineForm}><Pill aria-hidden="true" size={17} /> Record medicine</button>
                            </div>
                            {illnessDetailLoading ? <div className="illness-medicine-state" role="status">Checking medicine timing…</div> : null}
                            {illnessDetailError ? <div className="partial-notice inline-recovery"><span role="alert">{illnessDetailError}</span><button type="button" className="button button--secondary button--compact" onClick={() => void load()}>Try again</button></div> : null}
                            {!illnessDetailLoading && !illnessDetailError && illnessDetail?.next_dose_times.length ? (
                              <IllnessDoseList detail={illnessDetail} working={working} onReview={reviewIllnessMedicine} />
                            ) : null}
                            {!illnessDetailLoading && !illnessDetailError && illnessDetail && !illnessDetail.next_dose_times.length ? <div className="illness-medicine-state">No configured medicines for this child. Use Record medicine to add a dose record.</div> : null}
                          </section>
                          <form className="temperature-form" onSubmit={logTemperature}>
                            <div className="field"><label htmlFor="temperature-value">Temperature (°C)</label><input id="temperature-value" type="number" min="35" max="42" step="0.1" inputMode="decimal" value={temperatureValue} onChange={(event) => setTemperatureValue(event.target.value)} placeholder="37.5" required /></div>
                            <div className="field"><label htmlFor="temperature-time">Recorded at</label><input id="temperature-time" type="datetime-local" value={temperatureRecordedAt} onChange={(event) => setTemperatureRecordedAt(event.target.value)} required /></div>
                            <div className="field temperature-notes"><label htmlFor="temperature-notes">Notes (optional)</label><input id="temperature-notes" value={temperatureNotes} maxLength={2_000} onChange={(event) => setTemperatureNotes(event.target.value)} placeholder="Symptoms or context" /></div>
                            <button type="submit" className="button button--primary" disabled={working === `temperature-${selectedChild}`}>Log temperature</button>
                          </form>
                          {illnessDetail ? <TemperatureTimeline detail={illnessDetail} /> : null}
                        </>
                      ) : null}
                      {filteredTemperatures.slice(0, 5).map((reading) => <div className="temperature-row" key={reading.id}><strong>{reading.value_celsius.toFixed(1)} °C</strong><span>{when(reading.recorded_at)}{reading.notes ? ` · ${reading.notes}` : ""}</span></div>)}
                    </section>
                  );
                })() : null}
                {area === "illness" && selectedChild === "all" ? <div className="partial-notice">Choose a child above to enter illness mode.</div> : null}
                {area === "medicine" ? <>
                  {medicineFeedbackBanner()}
                  <h3>Configured medicines</h3><div className="record-list">
                    {filteredMedicineTypes.map((medicine) => <div className="configured-medicine-row" key={medicine.id}><Pill aria-hidden="true" size={18} /><div><strong>{childNames.get(medicine.child_id)} · {medicine.name}</strong><span>{medicine.default_dose_amount ? `${medicine.default_dose_amount} · ` : ""}Every {medicine.min_hours_between_doses}h · Child One {medicine.max_doses_24h} in 24h</span></div><button type="button" className="icon-button" aria-label={`Edit ${medicine.name}`} onClick={() => openEditMedicineType(medicine)}><Edit3 aria-hidden="true" size={17} /></button></div>)}
                    {!filteredMedicineTypes.length ? <EmptyState title="No medicines configured" detail="Add the reminder intervals and count limits copied from the label or prescriber." action={openNewMedicineType} actionLabel="Add medicine" /> : null}
                  </div>
                  <h3>Recent medicine</h3><div className="record-list">
                  {filteredDoses.map((dose) => <div className="record-row" key={dose.id}><HeartPulse aria-hidden="true" size={18} /><div><strong>{childNames.get(dose.child_id)} · {dose.medicine_name ?? medicineNames.get(dose.medicine_type_id ?? "") ?? "Medicine"}</strong><span>{dose.dose_amount ?? "Dose not recorded"} · {when(dose.given_at)}</span></div></div>)}
                  {!filteredDoses.length ? <EmptyState title="No medicine records" detail="No doses match this child selection." action={openMedicineForm} actionLabel="Record medicine" /> : null}
                </div></> : null}
                {area === "illness" ? <><h3>History</h3><div className="record-list">
                  {filteredIllnesses.map((illness) => <div className="record-row" key={illness.id}><HeartPulse aria-hidden="true" size={18} /><div><strong>{childNames.get(illness.child_id)} · {illness.ended_at ? "Recovered" : "Ongoing"}</strong><span>Started {when(illness.started_at)}{illness.notes ? ` · ${illness.notes}` : ""}</span></div></div>)}
                  {!filteredIllnesses.length ? <EmptyState title="No illness records" detail="No illnesses match this child selection." /> : null}
                </div></> : null}
                {area === "growth" ? <><h3>Measurements</h3><div className="record-list">
                  {filteredGrowth.map((record) => <div className="record-row" key={record.id}><UsersRound aria-hidden="true" size={18} /><div><strong>{childNames.get(record.child_id)} · {format(parseISO(record.date), "d MMM yyyy")}</strong><span>{[record.height_cm != null ? `${record.height_cm} cm` : null, record.weight_kg != null ? `${record.weight_kg} kg` : null].filter(Boolean).join(" · ") || "Measurement notes only"}</span></div></div>)}
                  {!filteredGrowth.length ? <EmptyState title="No growth records" detail="Measurements added in HausKlar will appear here." action={openGrowthForm} actionLabel="Add measurement" /> : null}
                </div></> : null}
              </div>
            ) : null}

            {area === "learning" ? (
              selectedChild !== "all" ? <Suspense fallback={<SkeletonList rows={6} />}><HomeworkView children={children} selectedChild={selectedChild} revision={revision} initialHomeworkId={initialHomeworkId} initialReadingId={initialReadingId} onDataChanged={onDataChanged} /></Suspense> : null
            ) : null}

            {area === "presents" ? (
              selectedChild !== "all" ? <Suspense fallback={<SkeletonList rows={6} />}><PresentsView
                children={children}
                members={members}
                selectedChild={selectedChild}
                revision={revision}
                initialPresentId={initialPresentId}
                initialBirthdayId={initialBirthdayId}
                onDataChanged={onDataChanged}
              /></Suspense> : null
            ) : null}

            {area === "birthdays" ? (
              <Suspense fallback={<SkeletonList rows={6} />}>
                <BirthdaysPanel
                  revision={revision}
                  initialBirthdayId={initialBirthdayId}
                  onDataChanged={onDataChanged}
                  onOpenTask={onOpenBirthdayTask}
                  onOpenEvent={onOpenBirthdayEvent}
                  onOpenPresents={(birthdayId) => {
                    if (onOpenBirthdayPresents) onOpenBirthdayPresents(birthdayId);
                    else chooseArea("presents");
                  }}
                />
              </Suspense>
            ) : null}

            {area === "artwork" ? (
              <Suspense fallback={<SkeletonList rows={6} />}>
                <ArtworkPanel children={children} selectedChild={selectedChild} revision={revision} initialArtworkId={initialArtworkId} onDataChanged={onDataChanged} />
              </Suspense>
            ) : null}

            {area === "photos" ? (
              <Suspense fallback={<SkeletonList rows={7} />}>
                <PhotosPanel children={children} selectedChild={selectedChild} revision={revision} initialPhotoId={initialPhotoId} onDataChanged={onDataChanged} />
              </Suspense>
            ) : null}

            {area === "yearbook" ? <Suspense fallback={<SkeletonList rows={7} />}><YearbookView children={children} initialChildId={selectedChild === "all" ? null : selectedChild} onChildChange={(childId) => selectChild(childId)} /></Suspense> : null}

            {area === "health" ? <Suspense fallback={<SkeletonList rows={7} />}><HealthView children={children} initialChildId={selectedChild === "all" ? null : selectedChild} initialTab={initialHealthTab} initialVaccinationKey={initialVaccinationKey} onChildChange={(childId) => selectChild(childId)} /></Suspense> : null}

            {area === "dog" ? <Suspense fallback={<SkeletonList rows={7} />}><DogCarePanel members={members} revision={revision} onDataChanged={onDataChanged} /></Suspense> : null}

            {area === "caregiver" ? <Suspense fallback={<SkeletonList rows={7} />}><CaregiverSetupView /></Suspense> : null}
          </section>

          <Modal open={showCreateChart} onOpenChange={setShowCreateChart} title="New star chart" description={childNames.get(selectedChild) ?? undefined}>
            <form className="form-stack" onSubmit={createChart}>
              <div className="field"><label htmlFor="chart-title">Title</label><input id="chart-title" value={chartTitle} onChange={(event) => setChartTitle(event.target.value)} required /></div>
              <div className="form-grid">
                <div className="field"><label htmlFor="chart-rows">Rows</label><input id="chart-rows" type="number" min={1} max={10} value={chartRows} onChange={(event) => setChartRows(Number(event.target.value))} required /></div>
                <div className="field"><label htmlFor="chart-columns">Columns</label><input id="chart-columns" type="number" min={1} max={10} value={chartColumns} onChange={(event) => setChartColumns(Number(event.target.value))} required /></div>
              </div>
              <div className="field"><label htmlFor="chart-reward">Reward (£)</label><input id="chart-reward" type="number" min={0} step="0.01" value={chartReward} onChange={(event) => setChartReward(event.target.value)} required /></div>
              <p className="form-summary">Total: {chartRows * chartColumns} stars</p>
              <div className="dialog-actions"><button type="submit" className="button button--primary" disabled={working === "create-chart"}>{working === "create-chart" ? "Creating…" : "Create chart"}</button></div>
            </form>
          </Modal>

          <Modal open={showAdjustBalance} onOpenChange={setShowAdjustBalance} title="Adjust balance" description={`Current balance: ${balances[selectedChild]?.balance_display ?? "£0.00"}`}>
            <form className="form-stack" onSubmit={adjustBalance}>
              <div className="segmented balance-segmented" role="group" aria-label="Adjustment type">
                {(["payout", "bonus", "correction"] as const).map((value) => <button type="button" className={adjustmentType === value ? "segmented-item is-active" : "segmented-item"} aria-pressed={adjustmentType === value} onClick={() => setAdjustmentType(value)} key={value}>{activityLabel(value)}</button>)}
              </div>
              <div className="field"><label htmlFor="balance-amount">Amount (£)</label><input id="balance-amount" type="number" min="0.01" step="0.01" max={adjustmentType === "payout" ? ((balances[selectedChild]?.balance_pence ?? 0) / 100).toFixed(2) : undefined} value={adjustmentAmount} onChange={(event) => setAdjustmentAmount(event.target.value)} required /></div>
              <div className="field"><label htmlFor="balance-notes">Notes (optional)</label><textarea id="balance-notes" rows={2} value={adjustmentNotes} onChange={(event) => setAdjustmentNotes(event.target.value)} /></div>
              <div className="dialog-actions"><button type="submit" className="button button--primary" disabled={working === "adjust-balance"}>{working === "adjust-balance" ? "Applying…" : "Apply"}</button></div>
            </form>
          </Modal>

          <Modal open={showIllnessStart} onOpenChange={setShowIllnessStart} title="Start illness mode" description={selectedChild === "all" ? undefined : childNames.get(selectedChild)}>
            <form className="form-stack" onSubmit={startIllnessMode}>
              <div className="field"><label htmlFor="illness-started-at">Started at</label><input id="illness-started-at" type="datetime-local" value={illnessStartedAt} onChange={(event) => setIllnessStartedAt(event.target.value)} required /></div>
              <div className="field"><label htmlFor="illness-notes">Symptoms or notes (optional)</label><textarea id="illness-notes" rows={3} maxLength={2_000} value={illnessNotes} onChange={(event) => setIllnessNotes(event.target.value)} /></div>
              <div className="dialog-actions"><button type="button" className="button button--secondary" disabled={Boolean(working)} onClick={() => setShowIllnessStart(false)}>Cancel</button><button type="submit" className="button button--primary" disabled={Boolean(working)}>{working === `illness-${selectedChild}` ? "Starting…" : "Start illness mode"}</button></div>
            </form>
          </Modal>

          <Modal open={Boolean(editingIllness)} onOpenChange={(open) => { if (!open) setEditingIllness(null); }} title="Edit illness notes" description={editingIllness ? childNames.get(editingIllness.child_id) : undefined}>
            <form className="form-stack" onSubmit={updateIllnessNotes}>
              <div className="field"><label htmlFor="active-illness-notes">Symptoms or notes</label><textarea id="active-illness-notes" rows={4} maxLength={2_000} value={illnessNotes} onChange={(event) => setIllnessNotes(event.target.value)} autoFocus /></div>
              <div className="dialog-actions"><button type="button" className="button button--secondary" disabled={Boolean(working)} onClick={() => setEditingIllness(null)}>Cancel</button><button type="submit" className="button button--primary" disabled={Boolean(working)}>{editingIllness && working === `illness-notes-${editingIllness.id}` ? "Saving…" : "Save notes"}</button></div>
            </form>
          </Modal>

          <Modal open={showMedicineTypeEditor} onOpenChange={(open) => { if (!open) closeMedicineTypeEditor(); }} title={editingMedicineType ? "Edit medicine" : "Add medicine"} description="Copy reminder values from the label or prescriber. HausKlar does not calculate or recommend a dose.">
            <form className="form-stack" onSubmit={saveMedicineType}>
              <div className="field"><label htmlFor="medicine-settings-child">Child</label><select id="medicine-settings-child" value={medicineTypeDraft.childId} onChange={(event) => setMedicineTypeDraft((draft) => ({ ...draft, childId: event.target.value }))} required>{children.map((child) => <option value={child.id} key={child.id}>{child.name}</option>)}</select></div>
              <div className="field"><label htmlFor="medicine-settings-name">Medicine name</label><input id="medicine-settings-name" value={medicineTypeDraft.name} maxLength={200} onChange={(event) => setMedicineTypeDraft((draft) => ({ ...draft, name: event.target.value }))} placeholder="Calpol" required autoFocus /></div>
              <div className="field"><label htmlFor="medicine-settings-dose">Saved dose amount (optional — copy from label)</label><input id="medicine-settings-dose" value={medicineTypeDraft.defaultDose} maxLength={100} onChange={(event) => setMedicineTypeDraft((draft) => ({ ...draft, defaultDose: event.target.value }))} placeholder="Copy from label or prescriber" /></div>
              <div className="form-grid">
                <div className="field"><label htmlFor="medicine-settings-hours">Minimum hours between doses</label><input id="medicine-settings-hours" type="number" inputMode="decimal" min="0.25" max="168" step="0.25" value={medicineTypeDraft.minHours} onChange={(event) => setMedicineTypeDraft((draft) => ({ ...draft, minHours: event.target.value }))} required /></div>
                <div className="field"><label htmlFor="medicine-settings-maximum">Maximum doses in 24 hours</label><input id="medicine-settings-maximum" type="number" inputMode="numeric" min="1" max="24" step="1" value={medicineTypeDraft.maxDoses} onChange={(event) => setMedicineTypeDraft((draft) => ({ ...draft, maxDoses: event.target.value }))} required /></div>
              </div>
              <div className="field"><label htmlFor="medicine-settings-notes">Notes (optional)</label><textarea id="medicine-settings-notes" rows={3} maxLength={2_000} value={medicineTypeDraft.notes} onChange={(event) => setMedicineTypeDraft((draft) => ({ ...draft, notes: event.target.value }))} /></div>
              <div className="dialog-actions"><button type="button" className="button button--secondary" disabled={working === "medicine-type"} onClick={closeMedicineTypeEditor}>Cancel</button><button type="submit" className="button button--primary" disabled={working === "medicine-type"}>{working === "medicine-type" ? "Saving…" : editingMedicineType ? "Save changes" : "Add medicine"}</button></div>
            </form>
          </Modal>

          <Modal open={showMedicineEntry} onOpenChange={setShowMedicineEntry} title="Record medicine" description="Record a dose that was actually given">
            <form className="form-stack" onSubmit={recordMedicine}>
              <div className="field"><label htmlFor="medicine-child">Child</label><select id="medicine-child" value={medicineChild} onChange={(event) => {
                const childID = event.target.value;
                const firstType = medicineTypes.find((item) => item.child_id === childID);
                setMedicineChild(childID);
                setMedicineTypeID(firstType?.id ?? "other");
                setDoseAmount(firstType?.default_dose_amount ?? "");
              }} required>{children.map((child) => <option value={child.id} key={child.id}>{child.name}</option>)}</select></div>
              <div className="field"><label htmlFor="medicine-type">Medicine</label><select id="medicine-type" value={medicineTypeID} onChange={(event) => {
                const typeID = event.target.value;
                setMedicineTypeID(typeID);
                setDoseAmount(medicineTypes.find((item) => item.id === typeID)?.default_dose_amount ?? "");
              }}>
                {medicineTypes.filter((item) => item.child_id === medicineChild).map((type) => <option value={type.id} key={type.id}>{type.name}</option>)}
                <option value="other">Other medicine</option>
              </select></div>
              {medicineTypeID === "other" ? <div className="field"><label htmlFor="medicine-name">Medicine name</label><input id="medicine-name" value={medicineName} maxLength={120} onChange={(event) => setMedicineName(event.target.value)} autoComplete="off" required /></div> : null}
              <div className="form-grid">
                <div className="field"><label htmlFor="medicine-dose">Dose</label><input id="medicine-dose" value={doseAmount} maxLength={80} onChange={(event) => setDoseAmount(event.target.value)} placeholder="e.g. 5 ml" /></div>
                <div className="field"><label htmlFor="medicine-time">Given at</label><input id="medicine-time" type="datetime-local" value={medicineGivenAt} onChange={(event) => setMedicineGivenAt(event.target.value)} required /></div>
              </div>
              <div className="field"><label htmlFor="medicine-notes">Notes (optional)</label><textarea id="medicine-notes" rows={2} maxLength={500} value={medicineNotes} onChange={(event) => setMedicineNotes(event.target.value)} /></div>
              <p className="form-summary">Saved-limit comparisons use the actual dose time, including backdated records. HausKlar does not recommend a dose.</p>
              <div className="dialog-actions"><button type="submit" className="button button--primary" disabled={working === "record-medicine"}>{working === "record-medicine" ? "Recording…" : "Record dose"}</button></div>
            </form>
          </Modal>

          <Modal open={showGrowthEntry} onOpenChange={setShowGrowthEntry} title="Add measurement">
            <form className="form-stack" onSubmit={recordGrowth}>
              <div className="field"><label htmlFor="growth-child">Child</label><select id="growth-child" value={growthChild} onChange={(event) => setGrowthChild(event.target.value)} required>{children.map((child) => <option value={child.id} key={child.id}>{child.name}</option>)}</select></div>
              <div className="field"><label htmlFor="growth-date">Date</label><input id="growth-date" type="date" value={growthDate} onChange={(event) => setGrowthDate(event.target.value)} required /></div>
              <div className="form-grid">
                <div className="field"><label htmlFor="growth-height">Height (cm)</label><input id="growth-height" type="number" inputMode="decimal" min="1" max="250" step="0.1" value={heightCM} onChange={(event) => setHeightCM(event.target.value)} /></div>
                <div className="field"><label htmlFor="growth-weight">Weight (kg)</label><input id="growth-weight" type="number" inputMode="decimal" min="0.1" max="300" step="0.1" value={weightKG} onChange={(event) => setWeightKG(event.target.value)} /></div>
              </div>
              <div className="field"><label htmlFor="growth-notes">Notes (optional)</label><textarea id="growth-notes" rows={2} maxLength={1_000} value={growthNotes} onChange={(event) => setGrowthNotes(event.target.value)} /></div>
              <div className="dialog-actions"><button type="submit" className="button button--primary" disabled={working === "record-growth"}>{working === "record-growth" ? "Saving…" : "Save measurement"}</button></div>
            </form>
          </Modal>

          {celebration ? (
            <div className="star-celebration" role="dialog" aria-modal="true" aria-labelledby="celebration-title">
              <Star aria-hidden="true" size={84} fill="currentColor" />
              <h2 id="celebration-title">Chart complete!</h2>
              <strong>£{(celebration.reward / 100).toFixed(2)} added</strong>
              <p>New balance: {celebration.balance}</p>
              <button type="button" className="button button--primary" onClick={() => setCelebration(null)}>Continue</button>
            </div>
          ) : null}
        </>
      ) : null}

      {childHub ? <Modal open onOpenChange={(open) => { if (!open) setChildHub(null); }} title={childHub.name} description="Today and everything you keep for them.">
        <div className="child-hub-groups">
          <section><h3>Care</h3><div className="child-module-grid">
            <button type="button" onClick={() => chooseChildArea(childHub, "medicine")}><Pill aria-hidden="true" size={20} />Medicine<ChevronRight aria-hidden="true" size={16} /></button>
            <button type="button" onClick={() => chooseChildArea(childHub, "sleep")}><Moon aria-hidden="true" size={20} />Sleep<ChevronRight aria-hidden="true" size={16} /></button>
            <button type="button" onClick={() => chooseChildArea(childHub, "illness")}><Thermometer aria-hidden="true" size={20} />Illness<ChevronRight aria-hidden="true" size={16} /></button>
          </div></section>
          <section><h3>School</h3><div className="child-module-grid">
            <button type="button" onClick={() => chooseChildArea(childHub, "stars")}><Star aria-hidden="true" size={20} />Star Charts<ChevronRight aria-hidden="true" size={16} /></button>
            <button type="button" onClick={() => chooseChildArea(childHub, "learning")}><BookOpen aria-hidden="true" size={20} />Homework<ChevronRight aria-hidden="true" size={16} /></button>
          </div></section>
          <section><h3>Plans</h3><div className="child-module-grid">
            <button type="button" onClick={() => chooseChildArea(childHub, "presents")}><Gift aria-hidden="true" size={20} />Gifts<ChevronRight aria-hidden="true" size={16} /></button>
          </div></section>
          <section><h3>Memories</h3><div className="child-module-grid">
            <button type="button" onClick={() => chooseChildArea(childHub, "artwork")}><Palette aria-hidden="true" size={20} />Artwork<ChevronRight aria-hidden="true" size={16} /></button>
            <button type="button" onClick={() => chooseChildArea(childHub, "photos")}><Camera aria-hidden="true" size={20} />Photos<ChevronRight aria-hidden="true" size={16} /></button>
            <button type="button" onClick={() => chooseChildArea(childHub, "yearbook")}><BookHeart aria-hidden="true" size={20} />Yearbook<ChevronRight aria-hidden="true" size={16} /></button>
          </div></section>
          <section><h3>Records</h3><div className="child-module-grid">
            <button type="button" onClick={() => chooseChildArea(childHub, "health")}><HeartPulse aria-hidden="true" size={20} />Health<ChevronRight aria-hidden="true" size={16} /></button>
            <button type="button" onClick={() => chooseChildArea(childHub, "growth")}><TrendingUp aria-hidden="true" size={20} />Growth<ChevronRight aria-hidden="true" size={16} /></button>
            <button type="button" onClick={() => onOpenDocuments?.(childHub.id)}><Files aria-hidden="true" size={20} />Documents<ChevronRight aria-hidden="true" size={16} /></button>
          </div></section>
        </div>
      </Modal> : null}
    </div>
  );
}

function FamilyTile({ title, icon: Icon, tone, onClick }: { title: string; icon: typeof Star; tone: string; onClick: () => void }) {
  return (
    <button type="button" className={`family-tool-tile is-${tone}`} onClick={onClick}>
      <Icon aria-hidden="true" size={22} />
      <strong>{title}</strong>
    </button>
  );
}
