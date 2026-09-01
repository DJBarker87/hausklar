import {
  Check,
  ChevronDown,
  Dog,
  Edit3,
  FileText,
  HeartPulse,
  Loader2,
  PawPrint,
  Plus,
  Scale,
  StopCircle,
  Syringe,
  Trash2,
  Undo2,
  Utensils,
} from "lucide-react";
import { format, parseISO } from "date-fns";
import { useCallback, useEffect, useMemo, useRef, useState, type FormEvent } from "react";

import { api } from "../api";
import { DocumentViewer } from "../components/DocumentViewer";
import { ConfirmDialog, EmptyState, ErrorState, Modal, SkeletonList, cn } from "../components/ui";
import type { FamilyMember, LinkedDocument } from "../types";

import "./dog-care.css";

type DogCareState = "upcoming" | "due" | "overdue" | "done";
type DogActivityType = "walk" | "feed" | "feed_breakfast" | "feed_dinner" | "vet" | "medication";
type DogDocumentRole = "insurance" | "vet" | "microchip" | "medicine" | "other";

type DogActivity = {
  id: string;
  activity_type: DogActivityType;
  started_at: string;
  ended_at?: string | null;
  notes?: string | null;
  is_active: boolean;
  done_by?: string | null;
};

type DogStatus = {
  walked_today: boolean;
  fed_breakfast_today: boolean;
  fed_dinner_today: boolean;
  last_walk?: DogActivity | null;
  last_feed_breakfast?: DogActivity | null;
  last_feed_dinner?: DogActivity | null;
  active_walk?: DogActivity | null;
  dog_name: string;
  walk_state: DogCareState;
  breakfast_state: DogCareState;
  dinner_state: DogCareState;
};

type DogProfile = {
  id?: string | null;
  name: string;
  date_of_birth?: string | null;
  breed?: string | null;
  microchip_number?: string | null;
  insurance_provider?: string | null;
  insurance_policy_number?: string | null;
  vet_name?: string | null;
  vet_phone?: string | null;
  allergies?: string | null;
  medicine_notes?: string | null;
  breakfast_window_start: string;
  breakfast_window_end: string;
  walk_window_start: string;
  walk_window_end: string;
  dinner_window_start: string;
  dinner_window_end: string;
};

type DogWeight = {
  id: string;
  measured_on: string;
  weight_kg: number;
  notes?: string | null;
};

type DogVaccination = {
  id: string;
  vaccine_name: string;
  given_on: string;
  next_due_on?: string | null;
  notes?: string | null;
};

type DogDocument = {
  id: string;
  document_id: string;
  role: DogDocumentRole;
  title: string;
  original_filename: string;
  media_type: string;
  file_size: number;
  download_url: string;
};

type DocumentCandidate = LinkedDocument & { status: "inbox" | "filed" | "archived" | "failed" };

type ActivityDraft = {
  id?: string;
  type: DogActivityType;
  startedAt: string;
  endedAt: string;
  notes: string;
  wasActive: boolean;
};

type WeightDraft = { id?: string; measuredOn: string; weight: string; notes: string };
type VaccinationDraft = { id?: string; name: string; givenOn: string; nextDueOn: string; notes: string };
type ProfileDraft = Omit<DogProfile, "id">;

type DeleteTarget =
  | { kind: "activity"; record: DogActivity }
  | { kind: "weight"; record: DogWeight }
  | { kind: "vaccination"; record: DogVaccination }
  | { kind: "document"; record: DogDocument };

type UndoState =
  | { kind: "activity"; record: DogActivity; label: string }
  | { kind: "weight"; record: DogWeight; label: string }
  | { kind: "vaccination"; record: DogVaccination; label: string };

const emptyProfile: DogProfile = {
  name: "Dog",
  date_of_birth: null,
  breed: null,
  microchip_number: null,
  insurance_provider: null,
  insurance_policy_number: null,
  vet_name: null,
  vet_phone: null,
  allergies: null,
  medicine_notes: null,
  breakfast_window_start: "07:00",
  breakfast_window_end: "09:00",
  walk_window_start: "10:00",
  walk_window_end: "14:00",
  dinner_window_start: "17:00",
  dinner_window_end: "19:00",
};

const activityOptions: Array<{ value: DogActivityType; label: string }> = [
  { value: "walk", label: "Walk" },
  { value: "feed_breakfast", label: "Breakfast" },
  { value: "feed_dinner", label: "Dinner" },
  { value: "vet", label: "Vet visit" },
  { value: "medication", label: "Medicine" },
];

const documentRoles: Array<{ value: DogDocumentRole; label: string }> = [
  { value: "insurance", label: "Insurance" },
  { value: "vet", label: "Vet record" },
  { value: "microchip", label: "Microchip" },
  { value: "medicine", label: "Medicine" },
  { value: "other", label: "Other pet record" },
];

function localDateValue(date = new Date()): string {
  const local = new Date(date.getTime() - date.getTimezoneOffset() * 60_000);
  return local.toISOString().slice(0, 10);
}

function localDateTimeValue(value: string | Date = new Date()): string {
  const date = typeof value === "string" ? new Date(value) : value;
  if (Number.isNaN(date.getTime())) return "";
  const local = new Date(date.getTime() - date.getTimezoneOffset() * 60_000);
  return local.toISOString().slice(0, 16);
}

function utcValue(value: string): string {
  return new Date(value).toISOString();
}

function activityLabel(type: DogActivityType): string {
  return activityOptions.find((option) => option.value === type)?.label ?? "Care record";
}

function documentRoleLabel(role: DogDocumentRole): string {
  return documentRoles.find((option) => option.value === role)?.label ?? "Pet record";
}

function careStateLabel(state: DogCareState): string {
  if (state === "done") return "Done";
  if (state === "overdue") return "Overdue";
  if (state === "due") return "Due now";
  return "Later";
}

function readableDate(value: string): string {
  const parsed = parseISO(value.slice(0, 10));
  return Number.isNaN(parsed.getTime()) ? value : format(parsed, "d MMM yyyy");
}

function readableDateTime(value: string): string {
  const parsed = parseISO(value);
  return Number.isNaN(parsed.getTime()) ? value : format(parsed, "d MMM · HH:mm");
}

function elapsedLabel(startedAt: string, now: number): string {
  const start = parseISO(startedAt).getTime();
  if (Number.isNaN(start)) return "In progress";
  const seconds = Math.max(0, Math.floor((now - start) / 1_000));
  const hours = Math.floor(seconds / 3_600);
  const minutes = Math.floor((seconds % 3_600) / 60);
  const remainder = seconds % 60;
  return hours ? `${hours}:${String(minutes).padStart(2, "0")}:${String(remainder).padStart(2, "0")}` : `${minutes}:${String(remainder).padStart(2, "0")}`;
}

function dogDocumentAsLinked(document: DogDocument): LinkedDocument {
  return {
    id: document.document_id,
    title: document.title,
    original_filename: document.original_filename,
    media_type: document.media_type,
    file_size: document.file_size,
    download_url: document.download_url,
  };
}

function profileDraft(profile: DogProfile): ProfileDraft {
  return {
    name: profile.name,
    date_of_birth: profile.date_of_birth ?? "",
    breed: profile.breed ?? "",
    microchip_number: profile.microchip_number ?? "",
    insurance_provider: profile.insurance_provider ?? "",
    insurance_policy_number: profile.insurance_policy_number ?? "",
    vet_name: profile.vet_name ?? "",
    vet_phone: profile.vet_phone ?? "",
    allergies: profile.allergies ?? "",
    medicine_notes: profile.medicine_notes ?? "",
    breakfast_window_start: profile.breakfast_window_start,
    breakfast_window_end: profile.breakfast_window_end,
    walk_window_start: profile.walk_window_start,
    walk_window_end: profile.walk_window_end,
    dinner_window_start: profile.dinner_window_start,
    dinner_window_end: profile.dinner_window_end,
  };
}

function optionalText(value: string | null | undefined): string | null {
  return value?.trim() || null;
}

export function DogCarePanel({
  members,
  revision,
  onDataChanged,
}: {
  members: FamilyMember[];
  revision: number;
  onDataChanged: () => void;
}) {
  const [status, setStatus] = useState<DogStatus | null>(null);
  const [profile, setProfile] = useState<DogProfile>(emptyProfile);
  const [activities, setActivities] = useState<DogActivity[]>([]);
  const [weights, setWeights] = useState<DogWeight[]>([]);
  const [vaccinations, setVaccinations] = useState<DogVaccination[]>([]);
  const [documents, setDocuments] = useState<DogDocument[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [actionError, setActionError] = useState<string | null>(null);
  const [busy, setBusy] = useState<string | null>(null);
  const [now, setNow] = useState(Date.now());

  const [profileEditorOpen, setProfileEditorOpen] = useState(false);
  const [profileForm, setProfileForm] = useState<ProfileDraft>(() => profileDraft(emptyProfile));
  const [activityForm, setActivityForm] = useState<ActivityDraft | null>(null);
  const [weightForm, setWeightForm] = useState<WeightDraft | null>(null);
  const [vaccinationForm, setVaccinationForm] = useState<VaccinationDraft | null>(null);
  const [deleteTarget, setDeleteTarget] = useState<DeleteTarget | null>(null);
  const [duplicateFeed, setDuplicateFeed] = useState<"feed_breakfast" | "feed_dinner" | null>(null);
  const [undo, setUndo] = useState<UndoState | null>(null);
  const undoButtonRef = useRef<HTMLButtonElement>(null);

  const [documentPickerOpen, setDocumentPickerOpen] = useState(false);
  const [documentCandidates, setDocumentCandidates] = useState<DocumentCandidate[]>([]);
  const [documentCandidatesLoading, setDocumentCandidatesLoading] = useState(false);
  const [documentCandidateID, setDocumentCandidateID] = useState("");
  const [documentRole, setDocumentRole] = useState<DogDocumentRole>("other");
  const [viewingDocument, setViewingDocument] = useState<LinkedDocument | null>(null);

  const timezone = useMemo(
    () => Intl.DateTimeFormat().resolvedOptions().timeZone || "Europe/London",
    [],
  );
  const memberNames = useMemo(() => new Map(members.map((member) => [member.id, member.name])), [members]);

  const load = useCallback(async (background = false) => {
    if (!background) setLoading(true);
    setError(null);
    try {
      const [[loadedStatus, loadedProfile], optionalResults] = await Promise.all([
        Promise.all([
          api<DogStatus>(`/dog/status?timezone=${encodeURIComponent(timezone)}`),
          api<DogProfile>("/dog/profile"),
        ]),
        Promise.allSettled([
          api<DogActivity[]>(`/dog/activities?limit=50&timezone=${encodeURIComponent(timezone)}`),
          api<DogWeight[]>("/dog/weights?limit=50"),
          api<DogVaccination[]>("/dog/vaccinations?limit=50"),
          api<DogDocument[]>("/dog/documents"),
        ]),
      ]);
      setStatus(loadedStatus);
      setProfile(loadedProfile);
      const [activityResult, weightResult, vaccinationResult, documentResult] = optionalResults;
      if (activityResult.status === "fulfilled") setActivities(activityResult.value);
      if (weightResult.status === "fulfilled") setWeights(weightResult.value);
      if (vaccinationResult.status === "fulfilled") setVaccinations(vaccinationResult.value);
      if (documentResult.status === "fulfilled") setDocuments(documentResult.value);
      if (optionalResults.some((result) => result.status === "rejected")) {
        setActionError("Today’s care is available. Some pet-record history could not be refreshed.");
      }
    } catch (requestError) {
      setError(requestError instanceof Error ? requestError.message : "Dog care could not be loaded.");
    } finally {
      setLoading(false);
    }
  }, [timezone]);

  useEffect(() => {
    void load(revision > 0);
  }, [load, revision]);

  useEffect(() => {
    if (!status?.active_walk) return;
    setNow(Date.now());
    const timer = window.setInterval(() => setNow(Date.now()), 1_000);
    return () => window.clearInterval(timer);
  }, [status?.active_walk]);

  useEffect(() => {
    if (undo) undoButtonRef.current?.focus();
  }, [undo]);

  async function refreshStatusAfterChange() {
    try {
      const next = await api<DogStatus>(`/dog/status?timezone=${encodeURIComponent(timezone)}`);
      setStatus(next);
    } catch {
      setActionError("The change was saved, but today's care status could not refresh. Refresh to check the latest state.");
    }
  }

  async function perform(key: string, action: () => Promise<void>, fallback: string) {
    setBusy(key);
    setActionError(null);
    try {
      await action();
      onDataChanged();
    } catch (requestError) {
      setActionError(requestError instanceof Error ? requestError.message : fallback);
    } finally {
      setBusy(null);
    }
  }

  async function toggleWalk() {
    const activeWalk = status?.active_walk;
    await perform("walk", async () => {
      if (activeWalk) {
        const updated = await api<DogActivity>(`/dog/activities/${activeWalk.id}`, {
          method: "PUT",
          body: JSON.stringify({ ended_at: new Date().toISOString(), is_active: false }),
        });
        setActivities((current) => [updated, ...current.filter((item) => item.id !== updated.id)]);
        setStatus((current) => current ? { ...current, active_walk: null, walked_today: true, walk_state: "done", last_walk: updated } : current);
      } else {
        const created = await api<DogActivity>("/dog/activities", {
          method: "POST",
          body: JSON.stringify({ activity_type: "walk", started_at: new Date().toISOString(), is_active: true }),
        });
        setActivities((current) => [created, ...current]);
        setStatus((current) => current ? { ...current, active_walk: created } : current);
      }
      await refreshStatusAfterChange();
    }, activeWalk ? "The walk could not be ended." : "The walk could not be started.");
  }

  async function logFeed(type: "feed_breakfast" | "feed_dinner") {
    setDuplicateFeed(null);
    await perform(type, async () => {
      const created = await api<DogActivity>("/dog/activities", {
        method: "POST",
        body: JSON.stringify({ activity_type: type, started_at: new Date().toISOString() }),
      });
      setActivities((current) => [created, ...current]);
      setStatus((current) => current ? {
        ...current,
        ...(type === "feed_breakfast"
          ? { fed_breakfast_today: true, breakfast_state: "done" as const, last_feed_breakfast: created }
          : { fed_dinner_today: true, dinner_state: "done" as const, last_feed_dinner: created }),
      } : current);
      await refreshStatusAfterChange();
    }, "That feed could not be recorded.");
  }

  function feedAction(type: "feed_breakfast" | "feed_dinner") {
    const alreadyDone = type === "feed_breakfast" ? status?.fed_breakfast_today : status?.fed_dinner_today;
    if (alreadyDone) setDuplicateFeed(type);
    else void logFeed(type);
  }

  function openProfileEditor() {
    setProfileForm(profileDraft(profile));
    setActionError(null);
    setProfileEditorOpen(true);
  }

  async function saveProfile(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    await perform("profile", async () => {
      const saved = await api<DogProfile>("/dog/profile", {
        method: "PUT",
        body: JSON.stringify({
          ...profileForm,
          name: profileForm.name.trim(),
          date_of_birth: optionalText(profileForm.date_of_birth),
          breed: optionalText(profileForm.breed),
          microchip_number: optionalText(profileForm.microchip_number),
          insurance_provider: optionalText(profileForm.insurance_provider),
          insurance_policy_number: optionalText(profileForm.insurance_policy_number),
          vet_name: optionalText(profileForm.vet_name),
          vet_phone: optionalText(profileForm.vet_phone),
          allergies: optionalText(profileForm.allergies),
          medicine_notes: optionalText(profileForm.medicine_notes),
        }),
      });
      setProfile(saved);
      setProfileEditorOpen(false);
      await refreshStatusAfterChange();
    }, "The pet record could not be saved.");
  }

  function newActivity() {
    setActionError(null);
    setActivityForm({ type: "vet", startedAt: localDateTimeValue(), endedAt: "", notes: "", wasActive: false });
  }

  function editActivity(activity: DogActivity) {
    setActionError(null);
    setActivityForm({
      id: activity.id,
      type: activity.activity_type,
      startedAt: localDateTimeValue(activity.started_at),
      endedAt: activity.ended_at ? localDateTimeValue(activity.ended_at) : "",
      notes: activity.notes ?? "",
      wasActive: activity.is_active,
    });
  }

  async function saveActivity(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (!activityForm) return;
    const startedAt = utcValue(activityForm.startedAt);
    const endedAt = activityForm.endedAt ? utcValue(activityForm.endedAt) : null;
    if (endedAt && endedAt < startedAt) {
      setActionError("End time cannot be before start time.");
      return;
    }
    await perform("activity", async () => {
      const body = {
        activity_type: activityForm.type,
        started_at: startedAt,
        ended_at: endedAt,
        notes: optionalText(activityForm.notes),
        is_active: activityForm.wasActive && activityForm.type === "walk" && !endedAt,
      };
      const saved = activityForm.id
        ? await api<DogActivity>(`/dog/activities/${activityForm.id}`, { method: "PUT", body: JSON.stringify(body) })
        : await api<DogActivity>("/dog/activities", { method: "POST", body: JSON.stringify(body) });
      setActivities((current) => [saved, ...current.filter((item) => item.id !== saved.id)]);
      setActivityForm(null);
      await refreshStatusAfterChange();
    }, "The care record could not be saved.");
  }

  function newWeight() {
    setActionError(null);
    setWeightForm({ measuredOn: localDateValue(), weight: "", notes: "" });
  }

  function editWeight(weight: DogWeight) {
    setActionError(null);
    setWeightForm({ id: weight.id, measuredOn: weight.measured_on, weight: String(weight.weight_kg), notes: weight.notes ?? "" });
  }

  async function saveWeight(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (!weightForm) return;
    const value = Number(weightForm.weight);
    if (!Number.isFinite(value) || value <= 0) {
      setActionError("Enter a valid weight.");
      return;
    }
    await perform("weight", async () => {
      const body = JSON.stringify({ measured_on: weightForm.measuredOn, weight_kg: value, notes: optionalText(weightForm.notes) });
      const saved = weightForm.id
        ? await api<DogWeight>(`/dog/weights/${weightForm.id}`, { method: "PATCH", body })
        : await api<DogWeight>("/dog/weights", { method: "POST", body });
      setWeights((current) => [saved, ...current.filter((item) => item.id !== saved.id)]
        .sort((left, right) => right.measured_on.localeCompare(left.measured_on)));
      setWeightForm(null);
    }, "The weight record could not be saved.");
  }

  function newVaccination() {
    setActionError(null);
    setVaccinationForm({ name: "", givenOn: localDateValue(), nextDueOn: "", notes: "" });
  }

  function editVaccination(vaccination: DogVaccination) {
    setActionError(null);
    setVaccinationForm({
      id: vaccination.id,
      name: vaccination.vaccine_name,
      givenOn: vaccination.given_on,
      nextDueOn: vaccination.next_due_on ?? "",
      notes: vaccination.notes ?? "",
    });
  }

  async function saveVaccination(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (!vaccinationForm) return;
    if (vaccinationForm.nextDueOn && vaccinationForm.nextDueOn < vaccinationForm.givenOn) {
      setActionError("Next due date cannot be before the date given.");
      return;
    }
    await perform("vaccination", async () => {
      const body = JSON.stringify({
        vaccine_name: vaccinationForm.name.trim(),
        given_on: vaccinationForm.givenOn,
        next_due_on: vaccinationForm.nextDueOn || null,
        notes: optionalText(vaccinationForm.notes),
      });
      const saved = vaccinationForm.id
        ? await api<DogVaccination>(`/dog/vaccinations/${vaccinationForm.id}`, { method: "PATCH", body })
        : await api<DogVaccination>("/dog/vaccinations", { method: "POST", body });
      setVaccinations((current) => [saved, ...current.filter((item) => item.id !== saved.id)]
        .sort((left, right) => right.given_on.localeCompare(left.given_on)));
      setVaccinationForm(null);
    }, "The vaccination record could not be saved.");
  }

  async function removeTarget() {
    if (!deleteTarget) return;
    const target = deleteTarget;
    await perform(`delete-${target.kind}`, async () => {
      if (target.kind === "activity") {
        await api(`/dog/activities/${target.record.id}`, { method: "DELETE" });
        setActivities((current) => current.filter((item) => item.id !== target.record.id));
        setUndo({ kind: "activity", record: target.record, label: `${activityLabel(target.record.activity_type)} removed` });
        await refreshStatusAfterChange();
      } else if (target.kind === "weight") {
        await api(`/dog/weights/${target.record.id}`, { method: "DELETE" });
        setWeights((current) => current.filter((item) => item.id !== target.record.id));
        setUndo({ kind: "weight", record: target.record, label: "Weight removed" });
      } else if (target.kind === "vaccination") {
        await api(`/dog/vaccinations/${target.record.id}`, { method: "DELETE" });
        setVaccinations((current) => current.filter((item) => item.id !== target.record.id));
        setUndo({ kind: "vaccination", record: target.record, label: "Vaccination removed" });
      } else {
        await api(`/dog/documents/${target.record.id}`, { method: "DELETE" });
        setDocuments((current) => current.filter((item) => item.id !== target.record.id));
      }
      setDeleteTarget(null);
    }, "That record could not be removed.");
  }

  async function undoRemoval() {
    if (!undo) return;
    const currentUndo = undo;
    await perform("undo", async () => {
      if (currentUndo.kind === "activity") {
        const restored = await api<DogActivity>(`/dog/activities/${currentUndo.record.id}/restore`, { method: "POST" });
        setActivities((current) => [restored, ...current.filter((item) => item.id !== restored.id)]);
        await refreshStatusAfterChange();
      } else if (currentUndo.kind === "weight") {
        const restored = await api<DogWeight>(`/dog/weights/${currentUndo.record.id}/restore`, { method: "POST" });
        setWeights((current) => [restored, ...current.filter((item) => item.id !== restored.id)]);
      } else {
        const restored = await api<DogVaccination>(`/dog/vaccinations/${currentUndo.record.id}/restore`, { method: "POST" });
        setVaccinations((current) => [restored, ...current.filter((item) => item.id !== restored.id)]);
      }
      setUndo(null);
    }, "That record could not be restored.");
  }

  async function openDocumentPicker() {
    setDocumentPickerOpen(true);
    setDocumentCandidatesLoading(true);
    setActionError(null);
    setDocumentCandidateID("");
    setDocumentRole("other");
    try {
      const candidates = await api<DocumentCandidate[]>("/documents/?status=filed&offset=0&limit=200");
      setDocumentCandidates(candidates.filter((candidate) => !documents.some((linked) => linked.document_id === candidate.id)));
    } catch (requestError) {
      setActionError(requestError instanceof Error ? requestError.message : "Documents could not be loaded.");
    } finally {
      setDocumentCandidatesLoading(false);
    }
  }

  async function linkDocument(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (!documentCandidateID) return;
    await perform("document", async () => {
      const linked = await api<DogDocument>("/dog/documents", {
        method: "POST",
        body: JSON.stringify({ document_id: documentCandidateID, role: documentRole }),
      });
      setDocuments((current) => [linked, ...current.filter((item) => item.document_id !== linked.document_id)]);
      setDocumentPickerOpen(false);
    }, "The document could not be added to the pet record.");
  }

  const visibleProfileDetails = [
    ["Breed", profile.breed],
    ["Born", profile.date_of_birth ? readableDate(profile.date_of_birth) : null],
    ["Microchip", profile.microchip_number],
    ["Insurance", [profile.insurance_provider, profile.insurance_policy_number].filter(Boolean).join(" · ")],
    ["Vet", [profile.vet_name, profile.vet_phone].filter(Boolean).join(" · ")],
    ["Allergies", profile.allergies],
    ["Medicine", profile.medicine_notes],
  ].filter((detail): detail is string[] => Boolean(detail[1]));

  if (loading && !status) return <SkeletonList rows={7} />;
  if (error && !status) return <ErrorState message={error} retry={() => void load()} />;

  return (
    <div className="dog-care">
      <section className="dog-care__hero" aria-labelledby="dog-care-title">
        <div className="dog-care__hero-copy">
          <span className="dog-care__avatar"><Dog aria-hidden="true" size={30} /></span>
          <div>
            <p className="page-eyebrow">Dog care</p>
            <h2 id="dog-care-title">{profile.name}</h2>
            <p>Shared care, one reliable record.</p>
          </div>
        </div>
        <button type="button" className="button button--secondary button--compact" onClick={newActivity}>
          <Plus aria-hidden="true" size={16} /> Add care record
        </button>
      </section>

      {actionError ? <div className="dog-care__error" role="alert">{actionError}<button type="button" onClick={() => setActionError(null)}>Dismiss</button></div> : null}

      <section className="dog-care__today" aria-labelledby="dog-care-today-title">
        <div className="dog-care__section-heading">
          <div><p className="page-eyebrow">Today</p><h3 id="dog-care-today-title">Care at a glance</h3></div>
          <span>Based on your saved care times</span>
        </div>
        <div className="dog-care__status-grid">
          <button
            type="button"
            className={cn("dog-care__status", `is-${status?.active_walk ? "active" : status?.walk_state ?? "upcoming"}`)}
            disabled={busy !== null}
            onClick={() => void toggleWalk()}
          >
            {status?.active_walk ? <StopCircle aria-hidden="true" size={24} /> : status?.walk_state === "done" ? <Check aria-hidden="true" size={24} /> : <PawPrint aria-hidden="true" size={24} />}
            <strong>{status?.active_walk ? "Walking now" : `Walk ${careStateLabel(status?.walk_state ?? "upcoming").toLowerCase()}`}</strong>
            <span>{status?.active_walk
              ? `${elapsedLabel(status.active_walk.started_at, now)} · End walk`
              : status?.walk_state === "done" && status.last_walk
                ? `${readableDateTime(status.last_walk.started_at)} · Start another walk`
                : `${profile.walk_window_start}–${profile.walk_window_end} · Start walk`}</span>
          </button>
          <button
            type="button"
            className={cn("dog-care__status", `is-${status?.breakfast_state ?? "upcoming"}`)}
            disabled={busy !== null}
            onClick={() => feedAction("feed_breakfast")}
          >
            {status?.breakfast_state === "done" ? <Check aria-hidden="true" size={24} /> : <Utensils aria-hidden="true" size={24} />}
            <strong>Breakfast {careStateLabel(status?.breakfast_state ?? "upcoming").toLowerCase()}</strong>
            <span>{status?.last_feed_breakfast && status.fed_breakfast_today ? `${readableDateTime(status.last_feed_breakfast.started_at)} · Review` : `${profile.breakfast_window_start}–${profile.breakfast_window_end} · Mark fed`}</span>
          </button>
          <button
            type="button"
            className={cn("dog-care__status", `is-${status?.dinner_state ?? "upcoming"}`)}
            disabled={busy !== null}
            onClick={() => feedAction("feed_dinner")}
          >
            {status?.dinner_state === "done" ? <Check aria-hidden="true" size={24} /> : <Utensils aria-hidden="true" size={24} />}
            <strong>Dinner {careStateLabel(status?.dinner_state ?? "upcoming").toLowerCase()}</strong>
            <span>{status?.last_feed_dinner && status.fed_dinner_today ? `${readableDateTime(status.last_feed_dinner.started_at)} · Review` : `${profile.dinner_window_start}–${profile.dinner_window_end} · Mark fed`}</span>
          </button>
        </div>
      </section>

      <section className="dog-care__section" aria-labelledby="dog-care-history-title">
        <div className="dog-care__section-heading">
          <div><p className="page-eyebrow">Care history</p><h3 id="dog-care-history-title">Recent activity</h3></div>
          <span>Tap a record to correct it</span>
        </div>
        {activities.length ? (
          <div className="dog-care__record-list">
            {activities.map((activity) => (
              <button type="button" className="dog-care__record" onClick={() => editActivity(activity)} key={activity.id}>
                <span className={cn("dog-care__record-icon", activity.is_active && "is-active")}><PawPrint aria-hidden="true" size={18} /></span>
                <span>
                  <strong>{activity.is_active ? "Walk in progress" : activityLabel(activity.activity_type)}</strong>
                  <small>{readableDateTime(activity.started_at)}{activity.done_by ? ` · ${memberNames.get(activity.done_by) ?? "Family"}` : ""}{activity.notes ? ` · ${activity.notes}` : ""}</small>
                </span>
                <Edit3 aria-hidden="true" size={17} />
              </button>
            ))}
          </div>
        ) : <EmptyState title="No care recorded yet" detail="Walks, feeds, vet visits and medicine will appear here." action={newActivity} actionLabel="Add care record" />}
      </section>

      <details className="dog-care__record-book">
        <summary>
          <span className="dog-care__record-book-icon"><HeartPulse aria-hidden="true" size={22} /></span>
          <span><strong>Pet record</strong><small>Vet, insurance, health and documents</small></span>
          <ChevronDown aria-hidden="true" size={20} />
        </summary>
        <div className="dog-care__record-book-body">
          <section className="dog-care__subsection" aria-labelledby="dog-profile-heading">
            <div className="dog-care__subsection-heading">
              <div><h3 id="dog-profile-heading">Important details</h3><p>The information you need during a vet call.</p></div>
              <button type="button" className="button button--secondary button--compact" onClick={openProfileEditor}><Edit3 aria-hidden="true" size={15} /> Edit</button>
            </div>
            {visibleProfileDetails.length ? (
              <dl className="dog-care__details">
                {visibleProfileDetails.map(([label, value]) => <div key={label}><dt>{label}</dt><dd>{value}</dd></div>)}
              </dl>
            ) : <p className="dog-care__quiet">Add the details you would want during a vet call.</p>}
          </section>

          <section className="dog-care__subsection" aria-labelledby="dog-weight-heading">
            <div className="dog-care__subsection-heading">
              <div><h3 id="dog-weight-heading">Weight</h3><p>A simple health trend, with the exact record behind it.</p></div>
              <button type="button" className="button button--secondary button--compact" onClick={newWeight}><Plus aria-hidden="true" size={15} /> Add</button>
            </div>
            {weights.length ? <div className="dog-care__compact-list">{weights.map((weight) => (
              <button type="button" onClick={() => editWeight(weight)} key={weight.id}>
                <Scale aria-hidden="true" size={17} />
                <span><strong>{weight.weight_kg.toLocaleString(undefined, { maximumFractionDigits: 1 })} kg</strong><small>{readableDate(weight.measured_on)}{weight.notes ? ` · ${weight.notes}` : ""}</small></span>
                <Edit3 aria-hidden="true" size={16} />
              </button>
            ))}</div> : <p className="dog-care__quiet">No weight recorded.</p>}
          </section>

          <section className="dog-care__subsection" aria-labelledby="dog-vaccinations-heading">
            <div className="dog-care__subsection-heading">
              <div><h3 id="dog-vaccinations-heading">Vaccinations</h3><p>Given dates and the next booster together.</p></div>
              <button type="button" className="button button--secondary button--compact" onClick={newVaccination}><Plus aria-hidden="true" size={15} /> Add</button>
            </div>
            {vaccinations.length ? <div className="dog-care__compact-list">{vaccinations.map((vaccination) => (
              <button type="button" onClick={() => editVaccination(vaccination)} key={vaccination.id}>
                <Syringe aria-hidden="true" size={17} />
                <span><strong>{vaccination.vaccine_name}</strong><small>Given {readableDate(vaccination.given_on)}{vaccination.next_due_on ? ` · Next due ${readableDate(vaccination.next_due_on)}` : ""}</small></span>
                <Edit3 aria-hidden="true" size={16} />
              </button>
            ))}</div> : <p className="dog-care__quiet">No vaccinations recorded.</p>}
          </section>

          <section className="dog-care__subsection" aria-labelledby="dog-documents-heading">
            <div className="dog-care__subsection-heading">
              <div><h3 id="dog-documents-heading">Documents</h3><p>Insurance, microchip and vet files, where you expect them.</p></div>
              <button type="button" className="button button--secondary button--compact" onClick={() => void openDocumentPicker()}><Plus aria-hidden="true" size={15} /> Add</button>
            </div>
            {documents.length ? <div className="dog-care__document-list">{documents.map((document) => (
              <div className="dog-care__document" key={document.id}>
                <button type="button" onClick={() => setViewingDocument(dogDocumentAsLinked(document))}>
                  <FileText aria-hidden="true" size={18} />
                  <span><strong>{document.title}</strong><small>{documentRoleLabel(document.role)}</small></span>
                </button>
                <button type="button" className="icon-button" aria-label={`Remove ${document.title} from the pet record`} onClick={() => setDeleteTarget({ kind: "document", record: document })}><Trash2 aria-hidden="true" size={16} /></button>
              </div>
            ))}</div> : <p className="dog-care__quiet">No documents linked yet.</p>}
          </section>
        </div>
      </details>

      {undo ? (
        <div className="dog-care__undo" role="status" aria-live="polite">
          <span>{undo.label}</span>
          <button ref={undoButtonRef} type="button" className="button button--secondary button--compact" disabled={busy === "undo"} onClick={() => void undoRemoval()}><Undo2 aria-hidden="true" size={15} /> {busy === "undo" ? "Restoring…" : "Undo"}</button>
        </div>
      ) : null}

      <Modal open={profileEditorOpen} onOpenChange={setProfileEditorOpen} title={`Edit ${profile.name}'s pet record`} description="Daily reminders use these care times; important details stay together for when you need them." size="wide">
        <form className="dog-care__form" onSubmit={saveProfile}>
          <div className="form-grid">
            <label className="field">Name<input value={profileForm.name} maxLength={80} required onChange={(event) => setProfileForm({ ...profileForm, name: event.target.value })} /></label>
            <label className="field">Date of birth (optional)<input type="date" max={localDateValue()} value={profileForm.date_of_birth ?? ""} onChange={(event) => setProfileForm({ ...profileForm, date_of_birth: event.target.value })} /></label>
            <label className="field">Breed (optional)<input value={profileForm.breed ?? ""} maxLength={120} onChange={(event) => setProfileForm({ ...profileForm, breed: event.target.value })} /></label>
            <label className="field">Microchip number (optional)<input value={profileForm.microchip_number ?? ""} maxLength={80} autoComplete="off" onChange={(event) => setProfileForm({ ...profileForm, microchip_number: event.target.value })} /></label>
            <label className="field">Insurance provider (optional)<input value={profileForm.insurance_provider ?? ""} maxLength={160} onChange={(event) => setProfileForm({ ...profileForm, insurance_provider: event.target.value })} /></label>
            <label className="field">Policy number (optional)<input value={profileForm.insurance_policy_number ?? ""} maxLength={120} autoComplete="off" onChange={(event) => setProfileForm({ ...profileForm, insurance_policy_number: event.target.value })} /></label>
            <label className="field">Vet (optional)<input value={profileForm.vet_name ?? ""} maxLength={160} onChange={(event) => setProfileForm({ ...profileForm, vet_name: event.target.value })} /></label>
            <label className="field">Vet phone (optional)<input type="tel" value={profileForm.vet_phone ?? ""} maxLength={80} onChange={(event) => setProfileForm({ ...profileForm, vet_phone: event.target.value })} /></label>
          </div>
          <label className="field">Allergies (optional)<textarea rows={2} maxLength={2_000} value={profileForm.allergies ?? ""} onChange={(event) => setProfileForm({ ...profileForm, allergies: event.target.value })} /></label>
          <label className="field">Medicine notes (optional)<textarea rows={2} maxLength={2_000} value={profileForm.medicine_notes ?? ""} onChange={(event) => setProfileForm({ ...profileForm, medicine_notes: event.target.value })} /></label>
          <fieldset className="dog-care__care-times">
            <legend>Usual care windows</legend>
            {(["breakfast", "walk", "dinner"] as const).map((care) => (
              <div key={care}>
                <strong>{care[0].toUpperCase() + care.slice(1)}</strong>
                <label>From<input type="time" required value={profileForm[`${care}_window_start`]} onChange={(event) => setProfileForm({ ...profileForm, [`${care}_window_start`]: event.target.value })} /></label>
                <label>Until<input type="time" required value={profileForm[`${care}_window_end`]} onChange={(event) => setProfileForm({ ...profileForm, [`${care}_window_end`]: event.target.value })} /></label>
              </div>
            ))}
          </fieldset>
          {actionError ? <div className="form-error" role="alert">{actionError}</div> : null}
          <div className="dialog-actions"><button type="button" className="button button--secondary" disabled={busy === "profile"} onClick={() => setProfileEditorOpen(false)}>Cancel</button><button type="submit" className="button button--primary" disabled={busy === "profile"}>{busy === "profile" ? "Saving…" : "Save pet record"}</button></div>
        </form>
      </Modal>

      <Modal open={Boolean(activityForm)} onOpenChange={(open) => { if (!open) setActivityForm(null); }} title={activityForm?.id ? "Correct care record" : "Add care record"} description="Keep the fast buttons simple; use this form when the exact detail matters.">
        {activityForm ? <form className="dog-care__form" onSubmit={saveActivity}>
          <label className="field">Care type<select value={activityForm.type} disabled={activityForm.wasActive} onChange={(event) => setActivityForm({ ...activityForm, type: event.target.value as DogActivityType })}>{activityOptions.map((option) => <option value={option.value} key={option.value}>{option.label}</option>)}</select></label>
          <div className="form-grid">
            <label className="field">Started<input type="datetime-local" required value={activityForm.startedAt} onChange={(event) => setActivityForm({ ...activityForm, startedAt: event.target.value })} /></label>
            <label className="field">Ended (optional)<input type="datetime-local" min={activityForm.startedAt} value={activityForm.endedAt} onChange={(event) => setActivityForm({ ...activityForm, endedAt: event.target.value })} /></label>
          </div>
          <label className="field">Notes (optional)<textarea rows={3} maxLength={2_000} value={activityForm.notes} onChange={(event) => setActivityForm({ ...activityForm, notes: event.target.value })} /></label>
          {actionError ? <div className="form-error" role="alert">{actionError}</div> : null}
          <div className="dog-care__form-actions">
            {activityForm.id ? <button type="button" className="button button--danger" disabled={busy === "activity"} onClick={() => { const record = activities.find((item) => item.id === activityForm.id); if (record) { setActivityForm(null); setDeleteTarget({ kind: "activity", record }); } }}><Trash2 aria-hidden="true" size={16} /> Remove</button> : <span />}
            <div className="dialog-actions"><button type="button" className="button button--secondary" disabled={busy === "activity"} onClick={() => setActivityForm(null)}>Cancel</button><button type="submit" className="button button--primary" disabled={busy === "activity"}>{busy === "activity" ? "Saving…" : activityForm.id ? "Save correction" : "Add record"}</button></div>
          </div>
        </form> : null}
      </Modal>

      <Modal open={Boolean(weightForm)} onOpenChange={(open) => { if (!open) setWeightForm(null); }} title={weightForm?.id ? "Correct weight" : "Add weight"} description="Record the measured value and where it came from.">
        {weightForm ? <form className="dog-care__form" onSubmit={saveWeight}>
          <div className="form-grid">
            <label className="field">Date<input type="date" required max={localDateValue()} value={weightForm.measuredOn} onChange={(event) => setWeightForm({ ...weightForm, measuredOn: event.target.value })} /></label>
            <label className="field">Weight (kg)<input type="number" inputMode="decimal" min="0.1" max="200" step="0.1" required value={weightForm.weight} onChange={(event) => setWeightForm({ ...weightForm, weight: event.target.value })} /></label>
          </div>
          <label className="field">Notes (optional)<textarea rows={2} maxLength={2_000} value={weightForm.notes} onChange={(event) => setWeightForm({ ...weightForm, notes: event.target.value })} placeholder="For example, vet scales" /></label>
          {actionError ? <div className="form-error" role="alert">{actionError}</div> : null}
          <div className="dog-care__form-actions">
            {weightForm.id ? <button type="button" className="button button--danger" onClick={() => { const record = weights.find((item) => item.id === weightForm.id); if (record) { setWeightForm(null); setDeleteTarget({ kind: "weight", record }); } }}><Trash2 aria-hidden="true" size={16} /> Remove</button> : <span />}
            <div className="dialog-actions"><button type="button" className="button button--secondary" onClick={() => setWeightForm(null)}>Cancel</button><button type="submit" className="button button--primary" disabled={busy === "weight"}>{busy === "weight" ? "Saving…" : weightForm.id ? "Save correction" : "Add weight"}</button></div>
          </div>
        </form> : null}
      </Modal>

      <Modal open={Boolean(vaccinationForm)} onOpenChange={(open) => { if (!open) setVaccinationForm(null); }} title={vaccinationForm?.id ? "Correct vaccination" : "Add vaccination"} description="Keep the date given and the next booster due date together.">
        {vaccinationForm ? <form className="dog-care__form" onSubmit={saveVaccination}>
          <label className="field">Vaccination<input required maxLength={120} value={vaccinationForm.name} onChange={(event) => setVaccinationForm({ ...vaccinationForm, name: event.target.value })} /></label>
          <div className="form-grid">
            <label className="field">Date given<input type="date" max={localDateValue()} required value={vaccinationForm.givenOn} onChange={(event) => setVaccinationForm({ ...vaccinationForm, givenOn: event.target.value })} /></label>
            <label className="field">Next due (optional)<input type="date" min={vaccinationForm.givenOn} value={vaccinationForm.nextDueOn} onChange={(event) => setVaccinationForm({ ...vaccinationForm, nextDueOn: event.target.value })} /></label>
          </div>
          <label className="field">Notes (optional)<textarea rows={3} maxLength={2_000} value={vaccinationForm.notes} onChange={(event) => setVaccinationForm({ ...vaccinationForm, notes: event.target.value })} /></label>
          {actionError ? <div className="form-error" role="alert">{actionError}</div> : null}
          <div className="dog-care__form-actions">
            {vaccinationForm.id ? <button type="button" className="button button--danger" onClick={() => { const record = vaccinations.find((item) => item.id === vaccinationForm.id); if (record) { setVaccinationForm(null); setDeleteTarget({ kind: "vaccination", record }); } }}><Trash2 aria-hidden="true" size={16} /> Remove</button> : <span />}
            <div className="dialog-actions"><button type="button" className="button button--secondary" onClick={() => setVaccinationForm(null)}>Cancel</button><button type="submit" className="button button--primary" disabled={busy === "vaccination"}>{busy === "vaccination" ? "Saving…" : vaccinationForm.id ? "Save correction" : "Add vaccination"}</button></div>
          </div>
        </form> : null}
      </Modal>

      <Modal open={documentPickerOpen} onOpenChange={setDocumentPickerOpen} title="Add pet document" description="Choose a document already filed in HausKlar, then say where it belongs.">
        <form className="dog-care__form" onSubmit={linkDocument}>
          {documentCandidatesLoading ? <div className="dog-care__loading" role="status"><Loader2 className="spin" aria-hidden="true" size={18} /> Loading documents…</div> : documentCandidates.length ? (
            <label className="field">Document<select required value={documentCandidateID} onChange={(event) => setDocumentCandidateID(event.target.value)}><option value="">Choose a document</option>{documentCandidates.map((document) => <option value={document.id} key={document.id}>{document.title}</option>)}</select></label>
          ) : <EmptyState title="No filed documents to add" detail="File the document in Documents first, then return here to link it." />}
          <label className="field">Type<select value={documentRole} onChange={(event) => setDocumentRole(event.target.value as DogDocumentRole)}>{documentRoles.map((role) => <option value={role.value} key={role.value}>{role.label}</option>)}</select></label>
          {actionError ? <div className="form-error" role="alert">{actionError}</div> : null}
          <div className="dialog-actions"><button type="button" className="button button--secondary" onClick={() => setDocumentPickerOpen(false)}>Cancel</button><button type="submit" className="button button--primary" disabled={busy === "document" || !documentCandidateID}>{busy === "document" ? "Adding…" : "Add document"}</button></div>
        </form>
      </Modal>

      <ConfirmDialog
        open={Boolean(deleteTarget)}
        onOpenChange={(open) => { if (!open) setDeleteTarget(null); }}
        title={deleteTarget?.kind === "document" ? "Remove this document link?" : "Remove this record?"}
        description={deleteTarget?.kind === "document" ? "The original stays safely filed in Documents." : "You can undo immediately if this was a mistake."}
        confirmLabel={deleteTarget?.kind === "document" ? "Remove link" : "Remove record"}
        destructive
        busy={busy?.startsWith("delete-")}
        onConfirm={() => void removeTarget()}
      />

      <ConfirmDialog
        open={Boolean(duplicateFeed)}
        onOpenChange={(open) => { if (!open) setDuplicateFeed(null); }}
        title={duplicateFeed === "feed_breakfast" ? "Breakfast is already logged" : "Dinner is already logged"}
        description="The existing record is shown in the care history. Add another only if this was a separate feed."
        confirmLabel="Log another feed"
        busy={busy === duplicateFeed}
        onConfirm={() => { if (duplicateFeed) void logFeed(duplicateFeed); }}
      />

      <DocumentViewer document={viewingDocument} onOpenChange={(open) => { if (!open) setViewingDocument(null); }} />
    </div>
  );
}
