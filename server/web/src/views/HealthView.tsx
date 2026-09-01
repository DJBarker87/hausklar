import {
  Baby,
  Check,
  Copy,
  Plus,
  Printer,
  Ruler,
  Stethoscope,
  Syringe,
  Trash2,
} from "lucide-react";
import { format, parseISO, subDays } from "date-fns";
import { useCallback, useEffect, useMemo, useRef, useState, type FormEvent } from "react";

import { api, localISODate } from "../api";
import type { Child } from "../types";
import { EmptyState, ErrorState, Modal, Segmented, SkeletonList, cn } from "../components/ui";

type HealthTab = "growth" | "illnesses" | "summary" | "vaccinations";

type VaccinationStatus = "given" | "overdue" | "due" | "upcoming";
type Vaccination = {
  key: string;
  name: string;
  due_age_label: string;
  due_date: string | null;
  status: VaccinationStatus;
  given_on: string | null;
  is_standard?: boolean;
};
type VaccinationsResponse = { vaccinations: Vaccination[]; disclaimer: string };

type Illness = {
  id: string;
  child_id: string;
  started_at: string;
  ended_at: string | null;
  notes: string | null;
};

type Measurement = {
  date: string;
  age_months: number;
  height_cm: number | null;
  weight_kg: number | null;
  height_centile: number | null;
  weight_centile: number | null;
};
type ReferencePoint = { age_months: number; p2: number; p9: number; p25: number; p50: number; p75: number; p91: number; p98: number };
type GrowthCentiles = {
  sex: "male" | "female" | null;
  measurements: Measurement[];
  weight_reference: ReferencePoint[];
  height_reference: ReferencePoint[];
  disclaimer: string;
  note: string | null;
};

type SummaryIllness = { started_at: string; ended_at: string | null; notes: string | null };
type SummaryTemperature = { recorded_at: string; value_celsius: number };
type SummaryDose = { given_at: string; name: string; dose_amount: string | null };
type Summary = {
  since: string;
  until: string;
  illnesses: SummaryIllness[];
  temperatures: SummaryTemperature[];
  medicine_doses: SummaryDose[];
  report: string;
  disclaimer: string | null;
};

const SUMMARY_DISCLAIMER = "A record of what you logged at home, not a medical assessment. Bring anything that concerns you to your GP or health visitor.";
const ILLNESS_DISCLAIMER = "Keep a simple history of sick days. This is a family record, not medical advice.";

const PERCENTILE_KEYS = ["p2", "p9", "p25", "p50", "p75", "p91", "p98"] as const;
const PERCENTILE_LABELS: Record<(typeof PERCENTILE_KEYS)[number], string> = {
  p2: "2nd", p9: "9th", p25: "25th", p50: "50th", p75: "75th", p91: "91st", p98: "98th",
};

function ordinal(value: number): string {
  const rounded = Math.round(value);
  const mod100 = rounded % 100;
  if (mod100 >= 11 && mod100 <= 13) return `${rounded}th`;
  const mod10 = rounded % 10;
  if (mod10 === 1) return `${rounded}st`;
  if (mod10 === 2) return `${rounded}nd`;
  if (mod10 === 3) return `${rounded}rd`;
  return `${rounded}th`;
}

function ageLabel(months: number): string {
  if (months < 1) return "newborn";
  if (months < 24) return `${months} ${months === 1 ? "month" : "months"}`;
  const years = Math.floor(months / 12);
  const rem = months % 12;
  return rem ? `${years} yr ${rem} mth` : `${years} ${years === 1 ? "year" : "years"}`;
}

type PlottedPoint = { age_months: number; value: number; centile: number };

// height_cm/weight_kg (and their centiles) are independently nullable — a weight-only
// or height-only entry is valid. Keep only the measurements that carry BOTH the value
// and the centile for this metric so a chart never plots a null/0th point (mirrors the
// iOS compactMap/guard behaviour).
function measurementPoints(
  measurements: Measurement[],
  value: (measurement: Measurement) => number | null,
  centile: (measurement: Measurement) => number | null,
): PlottedPoint[] {
  return measurements
    .map((measurement) => ({ age_months: measurement.age_months, value: value(measurement), centile: centile(measurement) }))
    .filter((point): point is PlottedPoint => point.value !== null && point.centile !== null);
}

// A dependency-free, print-friendly centile chart. Reference percentile bands are
// drawn over age (x, months) with the child's own measurements overlaid.
function CentileChart({ title, unit, reference, points }: {
  title: string;
  unit: string;
  reference: ReferencePoint[];
  points: PlottedPoint[];
}) {
  if (reference.length < 2) {
    return <p className="health-muted">Reference data is unavailable for this chart.</p>;
  }
  const width = 560;
  const height = 340;
  const pad = { left: 44, right: 52, top: 18, bottom: 40 };
  const ages = reference.map((point) => point.age_months);
  const xMin = Math.min(...ages, ...points.map((point) => point.age_months));
  const xMax = Math.max(...ages, ...points.map((point) => point.age_months));
  const values = reference.flatMap((point) => [point.p2, point.p98]).concat(points.map((point) => point.value));
  let yMin = Math.min(...values);
  let yMax = Math.max(...values);
  const yPad = (yMax - yMin) * 0.08 || 1;
  yMin -= yPad;
  yMax += yPad;

  const plotWidth = width - pad.left - pad.right;
  const plotHeight = height - pad.top - pad.bottom;
  const x = (age: number) => pad.left + (xMax === xMin ? 0.5 : (age - xMin) / (xMax - xMin)) * plotWidth;
  const y = (value: number) => pad.top + (yMax === yMin ? 0.5 : (yMax - value) / (yMax - yMin)) * plotHeight;

  const linePath = (key: (typeof PERCENTILE_KEYS)[number]) =>
    reference.map((point, index) => `${index === 0 ? "M" : "L"}${x(point.age_months).toFixed(1)},${y(point[key]).toFixed(1)}`).join(" ");

  const bandPath = [
    ...reference.map((point, index) => `${index === 0 ? "M" : "L"}${x(point.age_months).toFixed(1)},${y(point.p98).toFixed(1)}`),
    ...[...reference].reverse().map((point) => `L${x(point.age_months).toFixed(1)},${y(point.p2).toFixed(1)}`),
    "Z",
  ].join(" ");

  const childPath = points.map((point, index) => `${index === 0 ? "M" : "L"}${x(point.age_months).toFixed(1)},${y(point.value).toFixed(1)}`).join(" ");

  const tickCount = 5;
  const xTicks = Array.from({ length: tickCount }, (_, index) => xMin + ((xMax - xMin) * index) / (tickCount - 1));
  const yTicks = Array.from({ length: 4 }, (_, index) => yMin + ((yMax - yMin) * index) / 3);
  const latest = points[points.length - 1] ?? null;
  const previous = points.length >= 2 ? points[points.length - 2] : null;
  const unitLabel = unit === "kg" ? "kg" : "cm";
  const valueLabel = (value: number) => `${value}${unit === "kg" ? " kg" : " cm"}`;
  const trend = latest && previous
    ? latest.centile > previous.centile + 0.5
      ? ", tracking upwards"
      : latest.centile < previous.centile - 0.5
        ? ", tracking downwards"
        : ", holding steady"
    : "";
  const ariaLabel = latest
    ? `${title}, latest ${valueLabel(latest.value)}, ${ordinal(latest.centile)} centile${trend}.`
    : `${title}. Reference percentile bands, no measurements plotted yet.`;

  return (
    <figure className="centile-chart-figure">
      <figcaption>{title}</figcaption>
      <svg className="centile-chart" viewBox={`0 0 ${width} ${height}`} role="img" aria-label={ariaLabel}>
        <path className="centile-band" d={bandPath} />
        {PERCENTILE_KEYS.map((key) => (
          <path key={key} className={cn("centile-ref", key === "p50" && "is-median")} d={linePath(key)} />
        ))}
        {(["p98", "p50", "p2"] as const).map((key) => (
          <text key={key} className="centile-plabel" x={width - pad.right + 4} y={y(reference[reference.length - 1][key]) + 3}>
            {PERCENTILE_LABELS[key]}
          </text>
        ))}
        {yTicks.map((tick) => (
          <g key={`y-${tick}`}>
            <line className="centile-grid" x1={pad.left} y1={y(tick)} x2={width - pad.right} y2={y(tick)} />
            <text className="centile-axis-label" x={pad.left - 6} y={y(tick) + 3} textAnchor="end">{Math.round(tick)}</text>
          </g>
        ))}
        {xTicks.map((tick) => (
          <text key={`x-${tick}`} className="centile-axis-label" x={x(tick)} y={height - pad.bottom + 16} textAnchor="middle">{Math.round(tick)}</text>
        ))}
        <text className="centile-axis-title" x={pad.left + plotWidth / 2} y={height - 6} textAnchor="middle">Age (months)</text>
        <text className="centile-axis-title" transform={`translate(12 ${pad.top + plotHeight / 2}) rotate(-90)`} textAnchor="middle">{unit}</text>
        {points.length ? <path className="centile-child-line" d={childPath} /> : null}
        {points.map((point, index) => (
          <circle key={index} className="centile-child-dot" cx={x(point.age_months)} cy={y(point.value)} r={4} />
        ))}
      </svg>
      {latest ? (
        <p className="centile-latest">Latest: <strong>{latest.value}{unit === "kg" ? " kg" : " cm"}</strong> · {ordinal(latest.centile)} centile</p>
      ) : null}
      {points.length ? (
        <table className="sr-only centile-data-table">
          <caption>{title} — plotted measurements ({unitLabel} and centile by age)</caption>
          <thead>
            <tr>
              <th scope="col">Age</th>
              <th scope="col">{unit === "kg" ? "Weight" : "Height"}</th>
              <th scope="col">Centile</th>
            </tr>
          </thead>
          <tbody>
            {points.map((point, index) => (
              <tr key={index}>
                <td>{ageLabel(point.age_months)}</td>
                <td>{valueLabel(point.value)}</td>
                <td>{ordinal(point.centile)} centile</td>
              </tr>
            ))}
          </tbody>
        </table>
      ) : null}
    </figure>
  );
}

export function HealthView({ children, initialChildId = null, initialTab = "growth", initialVaccinationKey = null, onChildChange }: { children: Child[]; initialChildId?: string | null; initialTab?: HealthTab; initialVaccinationKey?: string | null; onChildChange?: (childId: string) => void }) {
  const [selectedChild, setSelectedChild] = useState<string>(initialChildId ?? "");
  const [tab, setTab] = useState<HealthTab>(initialTab);
  const [vaccinations, setVaccinations] = useState<VaccinationsResponse | null>(null);
  const [growth, setGrowth] = useState<GrowthCentiles | null>(null);
  const [illnesses, setIllnesses] = useState<Illness[]>([]);
  const [summary, setSummary] = useState<Summary | null>(null);
  const [since, setSince] = useState<string>(() => localISODate(subDays(new Date(), 90)));
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [working, setWorking] = useState<string | null>(null);
  const [actionError, setActionError] = useState<string | null>(null);
  const [copied, setCopied] = useState(false);
  const [growthFormOpen, setGrowthFormOpen] = useState(false);
  const [growthDate, setGrowthDate] = useState(() => localISODate(new Date()));
  const [growthHeight, setGrowthHeight] = useState("");
  const [growthWeight, setGrowthWeight] = useState("");
  const [growthHeadCircumference, setGrowthHeadCircumference] = useState("");
  const [growthNotes, setGrowthNotes] = useState("");
  const [illnessFormOpen, setIllnessFormOpen] = useState(false);
  const [illnessStart, setIllnessStart] = useState(() => localISODate(new Date()));
  const [illnessEnd, setIllnessEnd] = useState(() => localISODate(new Date()));
  const [illnessOngoing, setIllnessOngoing] = useState(false);
  const [illnessNotes, setIllnessNotes] = useState("");
  const [illnessToDelete, setIllnessToDelete] = useState<Illness | null>(null);
  const [vaccineFormOpen, setVaccineFormOpen] = useState(false);
  const [vaccineName, setVaccineName] = useState("");
  const [vaccineDate, setVaccineDate] = useState(() => localISODate(new Date()));
  const vaccinationRows = useRef(new Map<string, HTMLLIElement>());
  const openedVaccination = useRef<string | null>(null);

  useEffect(() => {
    if (initialChildId && children.some((child) => child.id === initialChildId)) {
      setSelectedChild(initialChildId);
      return;
    }
    setSelectedChild((current) => children.some((child) => child.id === current) ? current : children[0]?.id ?? "");
  }, [children, initialChildId]);

  function selectChild(childId: string) {
    setSelectedChild(childId);
    onChildChange?.(childId);
  }

  const load = useCallback(async () => {
    if (!selectedChild) return;
    setLoading(true);
    setError(null);
    setActionError(null);
    try {
      if (tab === "growth") {
        setGrowth(await api<GrowthCentiles>(`/health-record/${selectedChild}/growth-centiles`));
      } else if (tab === "illnesses") {
        setIllnesses(await api<Illness[]>(`/illness/?child_id=${encodeURIComponent(selectedChild)}&limit=200`));
      } else if (tab === "vaccinations") {
        setVaccinations(await api<VaccinationsResponse>(`/health-record/${selectedChild}/vaccinations`));
      } else {
        setSummary(await api<Summary>(`/health-record/${selectedChild}/summary?since=${since}`));
      }
    } catch (requestError) {
      setError(requestError instanceof Error ? requestError.message : "This health record could not be loaded.");
    } finally {
      setLoading(false);
    }
  }, [selectedChild, tab, since]);

  useEffect(() => {
    void load();
  }, [load]);

  useEffect(() => {
    if (tab !== "vaccinations" || !initialVaccinationKey || openedVaccination.current === initialVaccinationKey) return;
    const row = vaccinationRows.current.get(initialVaccinationKey);
    if (!row) return;
    openedVaccination.current = initialVaccinationKey;
    const reducedMotion = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
    row.scrollIntoView({ block: "center", behavior: reducedMotion ? "auto" : "smooth" });
    row.focus({ preventScroll: true });
  }, [initialVaccinationKey, tab, vaccinations]);

  async function toggleVaccination(vaccine: Vaccination) {
    setWorking(`vaccine-${vaccine.key}`);
    setActionError(null);
    try {
      if (vaccine.status === "given") {
        await api<void>(`/health-record/${selectedChild}/vaccinations/${encodeURIComponent(vaccine.key)}`, { method: "DELETE" });
      } else {
        await api(`/health-record/${selectedChild}/vaccinations`, {
          method: "POST",
          body: JSON.stringify({ vaccine_key: vaccine.key, given_on: localISODate(new Date()) }),
        });
      }
      setVaccinations(await api<VaccinationsResponse>(`/health-record/${selectedChild}/vaccinations`));
    } catch (requestError) {
      setActionError(requestError instanceof Error ? requestError.message : "That vaccination could not be updated.");
    } finally {
      setWorking(null);
    }
  }

  function openGrowthForm() {
    setGrowthDate(localISODate(new Date()));
    setGrowthHeight("");
    setGrowthWeight("");
    setGrowthHeadCircumference("");
    setGrowthNotes("");
    setActionError(null);
    setGrowthFormOpen(true);
  }

  async function addGrowthMeasurement(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    const height = optionalDecimal(growthHeight);
    const weight = optionalDecimal(growthWeight);
    const headCircumference = optionalDecimal(growthHeadCircumference);
    if (height === undefined || weight === undefined || headCircumference === undefined) {
      setActionError("Use numbers for measurements, for example 82.5.");
      return;
    }
    if (height == null && weight == null) {
      setActionError("Enter a height or weight.");
      return;
    }
    if ((height != null && (height < 1 || height > 250))
      || (weight != null && (weight < 0.1 || weight > 300))
      || (headCircumference != null && (headCircumference < 1 || headCircumference > 100))) {
      setActionError("Check the measurements and try again.");
      return;
    }
    setWorking("growth");
    setActionError(null);
    try {
      await api("/growth/", {
        method: "POST",
        body: JSON.stringify({
          child_id: selectedChild,
          date: growthDate,
          height_cm: height,
          weight_kg: weight,
          head_circumference_cm: headCircumference,
          notes: growthNotes.trim() || null,
        }),
      });
      setGrowth(await api<GrowthCentiles>(`/health-record/${selectedChild}/growth-centiles`));
      setGrowthFormOpen(false);
    } catch (requestError) {
      setActionError(requestError instanceof Error ? requestError.message : "That measurement could not be added.");
    } finally {
      setWorking(null);
    }
  }

  async function addCustomVaccination(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    const cleanName = vaccineName.trim();
    if (!cleanName) return;
    setWorking("custom-vaccine");
    setActionError(null);
    try {
      await api(`/health-record/${selectedChild}/vaccinations`, {
        method: "POST",
        body: JSON.stringify({ vaccine_name: cleanName, given_on: vaccineDate }),
      });
      setVaccinations(await api<VaccinationsResponse>(`/health-record/${selectedChild}/vaccinations`));
      setVaccineName("");
      setVaccineFormOpen(false);
    } catch (requestError) {
      setActionError(requestError instanceof Error ? requestError.message : "That vaccination could not be added.");
    } finally {
      setWorking(null);
    }
  }

  function openIllnessForm() {
    const today = localISODate(new Date());
    setIllnessStart(today);
    setIllnessEnd(today);
    setIllnessOngoing(false);
    setIllnessNotes("");
    setActionError(null);
    setIllnessFormOpen(true);
  }

  async function addIllness(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (!illnessOngoing && illnessEnd < illnessStart) {
      setActionError("The last sick day cannot be before the first sick day.");
      return;
    }
    setWorking("illness");
    setActionError(null);
    try {
      await api("/illness/", {
        method: "POST",
        body: JSON.stringify({
          child_id: selectedChild,
          started_at: illnessStart,
          ended_at: illnessOngoing ? null : illnessEnd,
          notes: illnessNotes.trim() || null,
        }),
      });
      setIllnesses(await api<Illness[]>(`/illness/?child_id=${encodeURIComponent(selectedChild)}&limit=200`));
      setIllnessFormOpen(false);
    } catch (requestError) {
      setActionError(requestError instanceof Error ? requestError.message : "That illness record could not be added.");
    } finally {
      setWorking(null);
    }
  }

  async function deleteIllness() {
    if (!illnessToDelete) return;
    const illness = illnessToDelete;
    setWorking(`illness-${illness.id}`);
    setActionError(null);
    try {
      await api(`/illness/${illness.id}`, { method: "DELETE" });
      setIllnesses((current) => current.filter((item) => item.id !== illness.id));
      setIllnessToDelete(null);
    } catch (requestError) {
      setActionError(requestError instanceof Error ? requestError.message : "That illness record could not be deleted.");
    } finally {
      setWorking(null);
    }
  }

  async function setSex(sex: "male" | "female") {
    setWorking("sex");
    setActionError(null);
    try {
      await api(`/health-record/${selectedChild}/sex`, { method: "PATCH", body: JSON.stringify({ sex }) });
      setGrowth(await api<GrowthCentiles>(`/health-record/${selectedChild}/growth-centiles`));
    } catch (requestError) {
      setActionError(requestError instanceof Error ? requestError.message : "The sex could not be saved.");
    } finally {
      setWorking(null);
    }
  }

  async function copyReport() {
    if (!summary) return;
    try {
      await navigator.clipboard.writeText(summary.report);
      setCopied(true);
      window.setTimeout(() => setCopied(false), 2500);
    } catch {
      setActionError("The summary could not be copied — select the text to copy it manually.");
    }
  }

  const disclaimer = useMemo(() => {
    if (tab === "vaccinations") return vaccinations?.disclaimer;
    if (tab === "growth") return growth?.disclaimer;
    if (tab === "illnesses") return ILLNESS_DISCLAIMER;
    return summary ? summary.disclaimer ?? SUMMARY_DISCLAIMER : undefined;
  }, [tab, vaccinations, growth, summary]);

  const weightPoints = measurementPoints(growth?.measurements ?? [], (m) => m.weight_kg, (m) => m.weight_centile);
  const heightPoints = measurementPoints(growth?.measurements ?? [], (m) => m.height_cm, (m) => m.height_centile);

  return (
    <div className="health-view family-record-section">
      <h1 className="sr-only">Health record</h1>
      {children.length ? (
        <div className="child-filter" role="group" aria-label="Choose child">
          {children.map((child) => (
            <button type="button" className={selectedChild === child.id ? "is-active" : ""} onClick={() => selectChild(child.id)} key={child.id}>
              {child.name}
            </button>
          ))}
        </div>
      ) : null}

      <Segmented
        value={tab}
        onChange={setTab}
        label="Health record section"
        options={[
          { value: "growth", label: "Growth" },
          { value: "illnesses", label: "Illnesses" },
          { value: "summary", label: "GP summary" },
          { value: "vaccinations", label: "Vaccinations" },
        ]}
      />

      {disclaimer ? (
        <p className="health-disclaimer" role="note">{disclaimer}</p>
      ) : null}

      {actionError && !growthFormOpen && !illnessFormOpen && !vaccineFormOpen && !illnessToDelete ? <div className="form-error" role="alert">{actionError}</div> : null}
      {error ? <ErrorState message={error} retry={load} /> : null}
      {loading ? <SkeletonList rows={6} /> : null}

      {!loading && !error && !children.length ? (
        <EmptyState title="No children yet" detail="Add a child in HausKlar to keep their health record." />
      ) : null}

      {!loading && !error && children.length && tab === "illnesses" ? (
        <section className="health-illnesses" aria-label="Illness history">
          <div className="section-heading">
            <div><p className="page-eyebrow">Sick-day record</p><h2>Illness history</h2></div>
            <button type="button" className="button button--primary button--compact" onClick={openIllnessForm}><Plus aria-hidden="true" size={16} /> Add illness</button>
          </div>
          {illnesses.length ? (
            <ul className="health-checklist">
              {illnesses.map((illness) => {
                const start = format(parseISO(illness.started_at.slice(0, 10)), "d MMM yyyy");
                const end = illness.ended_at ? format(parseISO(illness.ended_at.slice(0, 10)), "d MMM yyyy") : null;
                return (
                  <li className="health-check-row" key={illness.id}>
                    <Stethoscope aria-hidden="true" size={18} />
                    <div className="health-check-body">
                      <strong>{end ? (end === start ? start : `${start} – ${end}`) : `Since ${start}`}</strong>
                      <span>{illness.ended_at ? "Recovered" : "Ongoing"}{illness.notes ? ` · ${illness.notes}` : ""}</span>
                    </div>
                    <button type="button" className="icon-button" aria-label={`Delete illness from ${start}`} disabled={working === `illness-${illness.id}`} onClick={() => setIllnessToDelete(illness)}><Trash2 aria-hidden="true" size={16} /></button>
                  </li>
                );
              })}
            </ul>
          ) : <EmptyState title="No illnesses recorded" detail="Add past or ongoing sick days to keep a simple family health history." />}
        </section>
      ) : null}

      {!loading && !error && children.length && tab === "vaccinations" && vaccinations ? (
        <section className="health-vaccinations" aria-label="Vaccination schedule">
          <div className="section-heading">
            <div><p className="page-eyebrow">Vaccination record</p><h2>Vaccinations</h2></div>
            <button type="button" className="button button--primary button--compact" onClick={() => { setVaccineName(""); setVaccineDate(localISODate(new Date())); setActionError(null); setVaccineFormOpen(true); }}><Plus aria-hidden="true" size={16} /> Add vaccination</button>
          </div>
          <ul className="health-checklist">
            {vaccinations.vaccinations.map((vaccine) => (
              <li
                key={vaccine.key}
                ref={(node) => {
                  if (node) vaccinationRows.current.set(vaccine.key, node);
                  else vaccinationRows.current.delete(vaccine.key);
                }}
                tabIndex={-1}
                aria-current={vaccine.key === initialVaccinationKey ? "true" : undefined}
                className={cn("health-check-row", `is-${vaccine.status}`, vaccine.key === initialVaccinationKey && "is-search-result")}
              >
                <button
                  type="button"
                  className={cn("health-check", vaccine.status === "given" && "is-checked")}
                  aria-pressed={vaccine.status === "given"}
                  aria-label={vaccine.status === "given" ? `Mark ${vaccine.name} as not given` : `Mark ${vaccine.name} as given`}
                  disabled={working === `vaccine-${vaccine.key}`}
                  onClick={() => void toggleVaccination(vaccine)}
                >
                  {vaccine.status === "given" ? <Check aria-hidden="true" size={16} /> : <Syringe aria-hidden="true" size={14} />}
                </button>
                <div className="health-check-body">
                  <strong>{vaccine.name}</strong>
                  <span>
                    {vaccine.status === "given" && vaccine.given_on ? `Given ${format(parseISO(vaccine.given_on.slice(0, 10)), "d MMM yyyy")}` : vaccine.due_age_label}
                    {vaccine.status !== "given" && vaccine.due_date ? ` · due ${format(parseISO(vaccine.due_date.slice(0, 10)), "d MMM yyyy")}` : ""}
                  </span>
                </div>
                {vaccine.status !== "given" ? <span className={cn("health-status-tag", vaccine.status === "overdue" ? "is-notrecorded" : `is-${vaccine.status}`)}>{vaccine.status === "overdue" ? "Not recorded" : vaccine.status === "due" ? "Due now" : "Upcoming"}</span> : null}
              </li>
            ))}
          </ul>
          {vaccinations.vaccinations.some((vaccine) => vaccine.is_standard !== false) ? <p className="health-source">Routine entries: NHS vaccination schedule</p> : null}
          {!vaccinations.vaccinations.length ? <EmptyState title="No vaccinations to show" detail="The NHS schedule for this age will appear here." /> : null}
        </section>
      ) : null}

      {!loading && !error && children.length && tab === "growth" && growth ? (
        <section className="health-growth" aria-label="Growth centiles">
          <div className="section-heading health-no-print">
            <div><p className="page-eyebrow">Growth record</p><h2>Measurements</h2></div>
            <button type="button" className="button button--primary button--compact" disabled={working === "growth"} onClick={openGrowthForm}><Plus aria-hidden="true" size={16} /> Add measurement</button>
          </div>
          {growth.sex === null ? (
            <div className="health-set-sex">
              <p>{growth.note ?? "Centile charts use sex-specific reference data."}</p>
              <div className="health-sex-buttons">
                <button type="button" className="button button--secondary" disabled={working === "sex"} onClick={() => void setSex("female")}>Set as girl</button>
                <button type="button" className="button button--secondary" disabled={working === "sex"} onClick={() => void setSex("male")}>Set as boy</button>
              </div>
            </div>
          ) : !weightPoints.length && !heightPoints.length ? (
            <EmptyState title="No measurements yet" detail="Add a height or weight and the centile charts will appear here." action={openGrowthForm} actionLabel="Add measurement" />
          ) : (
            <>
              <div className="centile-charts">
                <CentileChart
                  title="Weight for age"
                  unit="kg"
                  reference={growth.weight_reference}
                  points={weightPoints}
                />
                <CentileChart
                  title="Height for age"
                  unit="cm"
                  reference={growth.height_reference}
                  points={heightPoints}
                />
              </div>
              <p className="health-source">Source: WHO Child Growth Standards</p>
            </>
          )}
        </section>
      ) : null}

      {!loading && !error && children.length && tab === "summary" && summary ? (
        <section className="health-summary" aria-label="GP summary">
          <div className="health-summary-controls health-no-print">
            <label className="field health-since">
              <span>Since</span>
              <input type="date" value={since} max={localISODate(new Date())} onChange={(event) => setSince(event.target.value)} />
            </label>
            <div className="health-summary-actions">
              <button type="button" className="button button--secondary button--compact" onClick={() => void copyReport()}>
                <Copy aria-hidden="true" size={15} /> {copied ? "Copied" : "Copy"}
              </button>
              <button type="button" className="button button--secondary button--compact" onClick={() => window.print()}>
                <Printer aria-hidden="true" size={15} /> Print
              </button>
            </div>
          </div>
          <p className="health-summary-range">{format(parseISO(summary.since.slice(0, 10)), "d MMM yyyy")} – {format(parseISO(summary.until.slice(0, 10)), "d MMM yyyy")}</p>
          <pre className="health-report">{summary.report}</pre>

          <div className="health-timeline">
            <div className="health-timeline-block">
              <h2><Stethoscope aria-hidden="true" size={16} /> Illnesses</h2>
              {summary.illnesses.length ? (
                <ul>
                  {summary.illnesses.map((illness, index) => (
                    <li key={index}>
                      <span>{format(parseISO(illness.started_at), "d MMM")}{illness.ended_at ? `–${format(parseISO(illness.ended_at), "d MMM")}` : " (ongoing)"}</span>
                      {illness.notes ? <p>{illness.notes}</p> : null}
                    </li>
                  ))}
                </ul>
              ) : <p className="health-muted">None recorded in this period.</p>}
            </div>
            <div className="health-timeline-block">
              <h2><Ruler aria-hidden="true" size={16} /> Temperatures</h2>
              {summary.temperatures.length ? (
                <ul>
                  {summary.temperatures.map((temperature, index) => (
                    <li key={index}><span>{format(parseISO(temperature.recorded_at), "d MMM HH:mm")}</span><p>{temperature.value_celsius}°C</p></li>
                  ))}
                </ul>
              ) : <p className="health-muted">None recorded in this period.</p>}
            </div>
            <div className="health-timeline-block">
              <h2><Baby aria-hidden="true" size={16} /> Medicine</h2>
              {summary.medicine_doses.length ? (
                <ul>
                  {summary.medicine_doses.map((dose, index) => (
                    <li key={index}><span>{format(parseISO(dose.given_at), "d MMM HH:mm")}</span><p>{dose.name}{dose.dose_amount ? ` · ${dose.dose_amount}` : ""}</p></li>
                  ))}
                </ul>
              ) : <p className="health-muted">None recorded in this period.</p>}
            </div>
          </div>
        </section>
      ) : null}

      <Modal
        open={growthFormOpen}
        onOpenChange={(open) => {
          setGrowthFormOpen(open);
          if (!open) setActionError(null);
        }}
        title="Add measurement"
        description="Record a height or weight. You can add the other measurement later."
      >
        <form className="form-stack" onSubmit={addGrowthMeasurement} aria-busy={working === "growth"}>
          <div className="field"><label htmlFor="health-growth-date">Measured on</label><input id="health-growth-date" type="date" max={localISODate(new Date())} value={growthDate} onChange={(event) => setGrowthDate(event.target.value)} required /></div>
          <div className="form-grid">
            <div className="field"><label htmlFor="health-growth-height">Height (cm)</label><input id="health-growth-height" type="text" inputMode="decimal" value={growthHeight} onChange={(event) => setGrowthHeight(event.target.value)} placeholder="82.5" /></div>
            <div className="field"><label htmlFor="health-growth-weight">Weight (kg)</label><input id="health-growth-weight" type="text" inputMode="decimal" value={growthWeight} onChange={(event) => setGrowthWeight(event.target.value)} placeholder="11.4" /></div>
          </div>
          <div className="field"><label htmlFor="health-growth-head">Head circumference (cm, optional)</label><input id="health-growth-head" type="text" inputMode="decimal" value={growthHeadCircumference} onChange={(event) => setGrowthHeadCircumference(event.target.value)} placeholder="47.2" /></div>
          <div className="field"><label htmlFor="health-growth-notes">Notes (optional)</label><textarea id="health-growth-notes" rows={2} maxLength={2_000} value={growthNotes} onChange={(event) => setGrowthNotes(event.target.value)} placeholder="For example, measured at home" /></div>
          {actionError ? <div className="form-error" role="alert">{actionError}</div> : null}
          <div className="dialog-actions"><button type="button" className="button button--secondary" disabled={working === "growth"} onClick={() => { setGrowthFormOpen(false); setActionError(null); }}>Cancel</button><button type="submit" className="button button--primary" disabled={working === "growth"}>{working === "growth" ? "Saving…" : "Save measurement"}</button></div>
        </form>
      </Modal>

      <Modal open={illnessFormOpen} onOpenChange={setIllnessFormOpen} title="Add illness" description="Record past sick days or an illness that is still ongoing.">
        <form className="form-stack" onSubmit={addIllness}>
          <div className="form-grid">
            <div className="field"><label htmlFor="health-illness-start">First sick day</label><input id="health-illness-start" type="date" max={localISODate(new Date())} value={illnessStart} onChange={(event) => { setIllnessStart(event.target.value); if (illnessEnd < event.target.value) setIllnessEnd(event.target.value); }} required /></div>
            {!illnessOngoing ? <div className="field"><label htmlFor="health-illness-end">Last sick day</label><input id="health-illness-end" type="date" min={illnessStart} max={localISODate(new Date())} value={illnessEnd} onChange={(event) => setIllnessEnd(event.target.value)} required /></div> : null}
          </div>
          <label className="check-row" htmlFor="health-illness-ongoing"><input id="health-illness-ongoing" type="checkbox" checked={illnessOngoing} onChange={(event) => setIllnessOngoing(event.target.checked)} /><span>Still unwell</span></label>
          <div className="field"><label htmlFor="health-illness-notes">Symptoms or notes (optional)</label><textarea id="health-illness-notes" rows={3} maxLength={2_000} value={illnessNotes} onChange={(event) => setIllnessNotes(event.target.value)} /></div>
          {actionError ? <div className="form-error" role="alert">{actionError}</div> : null}
          <div className="dialog-actions"><button type="button" className="button button--secondary" disabled={working === "illness"} onClick={() => setIllnessFormOpen(false)}>Cancel</button><button type="submit" className="button button--primary" disabled={working === "illness"}>{working === "illness" ? "Saving…" : "Save illness"}</button></div>
        </form>
      </Modal>

      <Modal open={vaccineFormOpen} onOpenChange={setVaccineFormOpen} title="Add vaccination" description="Add a vaccination outside the routine schedule, such as chickenpox or a travel vaccine.">
        <form className="form-stack" onSubmit={addCustomVaccination}>
          <div className="field"><label htmlFor="health-vaccine-name">Vaccination</label><input id="health-vaccine-name" value={vaccineName} onChange={(event) => setVaccineName(event.target.value)} maxLength={120} placeholder="Chickenpox" autoFocus required /></div>
          <div className="field"><label htmlFor="health-vaccine-date">Date given</label><input id="health-vaccine-date" type="date" value={vaccineDate} max={localISODate(new Date())} onChange={(event) => setVaccineDate(event.target.value)} required /></div>
          {actionError ? <div className="form-error" role="alert">{actionError}</div> : null}
          <div className="dialog-actions"><button type="button" className="button button--secondary" disabled={working === "custom-vaccine"} onClick={() => setVaccineFormOpen(false)}>Cancel</button><button type="submit" className="button button--primary" disabled={working === "custom-vaccine"}>{working === "custom-vaccine" ? "Saving…" : "Add vaccination"}</button></div>
        </form>
      </Modal>

      <Modal open={Boolean(illnessToDelete)} onOpenChange={(open) => { if (!open) setIllnessToDelete(null); }} title="Delete illness record?" description="This removes the sick-day entry from the family record.">
        {actionError ? <div className="form-error" role="alert">{actionError}</div> : null}
        <div className="dialog-actions"><button type="button" className="button button--secondary" disabled={Boolean(working)} onClick={() => setIllnessToDelete(null)}>Cancel</button><button type="button" className="button button--danger" disabled={Boolean(working)} onClick={() => void deleteIllness()}><Trash2 aria-hidden="true" size={16} />{working?.startsWith("illness-") ? "Deleting…" : "Delete record"}</button></div>
      </Modal>
    </div>
  );
}

function optionalDecimal(value: string): number | null | undefined {
  const trimmed = value.trim();
  if (!trimmed) return null;
  const parsed = Number(trimmed.replace(",", "."));
  return Number.isFinite(parsed) ? parsed : undefined;
}
