import {
  Bell,
  ChevronDown,
  ChevronUp,
  CircleStop,
  Clock3,
  Copy,
  Pencil,
  Play,
  Plus,
  Save,
  SkipForward,
  Square,
  TimerReset,
} from "lucide-react";
import { useEffect, useMemo, useRef, useState } from "react";

import { Modal } from "../../components/ui";
import type {
  FitnessBodyLocation,
  FitnessExercise,
  FitnessPlannedSession,
  FitnessStrengthSession,
  FitnessStrengthSessionExercise,
  FitnessStrengthSetComponent,
  FitnessStrengthSetGroup,
} from "../../fitness/contract";
import {
  formatStrengthClock,
  normalizedStrengthLoad,
  plannedStrengthTarget,
  previousComparableComponents,
  previousPerformanceLabel,
  strengthRepetitionLabel,
  strengthSetupLoadLabel,
  strengthTemplateItems,
  strengthWorkoutExportText,
  strengthWorkoutVersion,
} from "../../fitness/strengthWorkout";
import { nextCompoundGroupStatus } from "../../fitness/strengthSemantics";
import type { SaveFitnessRecordInput } from "../../fitness/offlineStore";
import type { FitnessStrengthWorkspace } from "./FitnessStrengthView";
import {
  FitnessCard,
  FitnessFormStatus,
  FitnessStat,
  formatFitnessDateTime,
  localTimeZone,
  submitForm,
  useFitnessBatchSave,
  useFitnessEndpoint,
  useFitnessSave,
} from "./shared";

type StartKind = "blank" | "plan" | "template" | "previous";
type PlannedExercise = NonNullable<FitnessPlannedSession["exercise_items"]>[number];
type PlannedSet = PlannedExercise["planned_sets"][number];

type StartItem = {
  sourceId: string | null;
  exerciseId: string;
  setupId: string | null;
  sequence: number;
  supersetKey: string | null;
  notes: string | null;
  plannedSets: Array<PlannedSet & { sourceIsPlan: boolean }>;
};

type SetDraft = {
  structure: FitnessStrengthSetGroup["structure_type"];
  role: FitnessStrengthSetGroup["training_role"];
  status: FitnessStrengthSetComponent["component_status"];
  reps: string;
  repsLeft: string;
  repsRight: string;
  load: string;
  duration: string;
  distance: string;
  rir: string;
  rpe: string;
  rest: string;
  bodyweight: string;
  tempo: string;
  notes: string;
  amrap: boolean;
  failure: "none" | "technical" | "muscular" | "unknown";
  stoppedForIssue: boolean;
  appendGroupId: string;
};

const EMPTY_SET: SetDraft = {
  structure: "straight",
  role: "working",
  status: "completed",
  reps: "",
  repsLeft: "",
  repsRight: "",
  load: "",
  duration: "",
  distance: "",
  rir: "",
  rpe: "",
  rest: "120",
  bodyweight: "",
  tempo: "",
  notes: "",
  amrap: false,
  failure: "none",
  stoppedForIssue: false,
  appendGroupId: "",
};

const BODYWEIGHT_MARKER = /\[bodyweight_snapshot=(unknown|\d+(?:\.\d+)?)\]/;

type RecordedSetEdit = {
  group: FitnessStrengthSetGroup;
  component: FitnessStrengthSetComponent;
};

async function copyPlainText(value: string) {
  if (navigator.clipboard?.writeText) {
    await navigator.clipboard.writeText(value);
    return;
  }
  const textarea = document.createElement("textarea");
  textarea.value = value;
  textarea.style.position = "fixed";
  textarea.style.opacity = "0";
  document.body.appendChild(textarea);
  textarea.select();
  document.execCommand("copy");
  textarea.remove();
}

function bodyweightFromSession(session?: FitnessStrengthSession | null): string {
  const match = session?.notes?.match(BODYWEIGHT_MARKER)?.[1];
  return match && match !== "unknown" ? match : "";
}

function sessionNotesWithBodyweight(existing: string | null | undefined, bodyweight: number | null, userNotes?: string | null): string {
  const marker = `[bodyweight_snapshot=${bodyweight == null ? "unknown" : bodyweight}]`;
  const retained = (existing ?? "").replace(BODYWEIGHT_MARKER, "").trim();
  return [marker, userNotes?.trim() || retained || null].filter(Boolean).join("\n");
}

function numberOrNull(value: string): number | null {
  if (value.trim() === "") return null;
  const parsed = Number(value);
  return Number.isFinite(parsed) ? parsed : null;
}

function bodyLocationDisplay(key: string, locations: FitnessBodyLocation[]): string {
  return locations.find((item) => item.location_key === key)?.display_name
    ?? `Custom/legacy: ${key.replaceAll("_", " ")}`;
}

function exercisePayload(exercise: FitnessStrengthSessionExercise) {
  return {
    activity_id: exercise.activity_id,
    exercise_id: exercise.exercise_id,
    exercise_setup_id: exercise.exercise_setup_id ?? null,
    planned_exercise_id: exercise.planned_exercise_id ?? null,
    sequence: exercise.sequence,
    superset_group_key: exercise.superset_group_key ?? null,
    variation_note: exercise.variation_note ?? null,
    notes: exercise.notes ?? null,
  };
}

function groupPayload(group: FitnessStrengthSetGroup) {
  return {
    activity_id: group.activity_id,
    session_exercise_id: group.session_exercise_id,
    planned_set_id: group.planned_set_id ?? null,
    sequence: group.sequence,
    training_role: group.training_role,
    structure_type: group.structure_type,
    status: group.status,
    is_amrap: group.is_amrap ?? false,
    failure_state: group.failure_state ?? "none",
    started_at_utc: group.started_at_utc ?? null,
    completed_at_utc: group.completed_at_utc ?? null,
    notes: group.notes ?? null,
  };
}

function sessionPayload(session: FitnessStrengthSession, overrides: Partial<FitnessStrengthSession> = {}) {
  const next = { ...session, ...overrides };
  return {
    title: next.title,
    started_at_utc: next.started_at_utc,
    local_timezone: next.local_timezone,
    planned_session_id: next.planned_session_id ?? null,
    status: next.status,
    ended_at_utc: next.ended_at_utc ?? null,
    rest_timer_deadline_utc: next.rest_timer_deadline_utc ?? null,
    session_rpe: next.session_rpe ?? null,
    perceived_performance: next.perceived_performance ?? null,
    matched_plan_key: next.matched_plan_key ?? null,
    notes: next.notes ?? null,
  };
}

function planPayload(plan: FitnessPlannedSession, sessionId: string, status: "completed" | "partially_completed" | "cancelled") {
  return {
    sport_key: plan.sport_key,
    title: plan.title,
    status,
    session_source: plan.session_source ?? "user",
    scheduled_start_utc: plan.scheduled_start_utc ?? null,
    time_window_start_utc: plan.time_window_start_utc ?? null,
    time_window_end_utc: plan.time_window_end_utc ?? null,
    local_timezone: plan.local_timezone ?? localTimeZone(),
    scheduled_date: plan.scheduled_date ?? null,
    expected_duration_s: plan.expected_duration_s ?? null,
    priority: plan.priority ?? 1,
    movable: plan.movable ?? true,
    visibility: plan.visibility ?? "private",
    shared_title: plan.shared_title ?? null,
    training_programme_id: plan.training_programme_id ?? null,
    workout_version_id: plan.workout_version_id ?? null,
    expected_distance_m: plan.expected_distance_m ?? null,
    reason_for_placement: plan.reason_for_placement ?? null,
    completion_activity_id: sessionId,
    completion_state: status === "completed" ? "completed" : status === "partially_completed" ? "partial" : "aborted",
    intended_gear_ids: plan.intended_gear_ids ?? [],
    goal_links: plan.goal_links ?? [],
    exercise_items: plan.exercise_items ?? [],
  };
}

function targetText(set: PlannedSet): string {
  const reps = set.reps_min == null && set.reps_max == null
    ? null
    : `${set.reps_min ?? "?"}${set.reps_max != null && set.reps_max !== set.reps_min ? `–${set.reps_max}` : ""} reps`;
  const load = set.load_min == null && set.load_max == null
    ? null
    : `${set.load_min ?? "?"}${set.load_max != null && set.load_max !== set.load_min ? `–${set.load_max}` : ""} ${set.load_unit ?? "kg"}`;
  const effort = set.rir_min != null ? `RIR ${set.rir_min}` : set.rpe_min != null ? `RPE ${set.rpe_min}` : null;
  return [reps, load, effort, set.notes].filter(Boolean).join(" · ");
}

async function notifyRestComplete() {
  if (typeof Notification === "undefined" || Notification.permission !== "granted") return;
  if ("serviceWorker" in navigator) {
    const registration = await navigator.serviceWorker.ready.catch(() => null);
    if (registration) {
      await registration.showNotification("Rest complete", { body: "Your next strength set is ready.", tag: "fitness-rest-timer" });
      return;
    }
  }
  new Notification("Rest complete", { body: "Your next strength set is ready." });
}

export function FitnessStrengthWorkoutPanel({
  workspace,
  online,
  onDataChanged,
}: {
  workspace: FitnessStrengthWorkspace;
  online: boolean;
  onDataChanged: () => void;
}) {
  const batch = useFitnessBatchSave(onDataChanged);
  const single = useFitnessSave(onDataChanged);
  const bodyLocations = useFitnessEndpoint<FitnessBodyLocation[]>("/fitness/body-locations", [], 0);
  const [startKind, setStartKind] = useState<StartKind>("blank");
  const [sourceId, setSourceId] = useState("");
  const [title, setTitle] = useState("Strength workout");
  const [readiness, setReadiness] = useState("");
  const [energy, setEnergy] = useState("");
  const [soreness, setSoreness] = useState("");
  const [motivation, setMotivation] = useState("");
  const [advancedCheckin, setAdvancedCheckin] = useState(false);
  const [selectedExerciseId, setSelectedExerciseId] = useState("");
  const [addExerciseId, setAddExerciseId] = useState("");
  const [exerciseQuery, setExerciseQuery] = useState("");
  const [substituteId, setSubstituteId] = useState("");
  const [setDraft, setSetDraft] = useState<SetDraft>(EMPTY_SET);
  const [finishOpen, setFinishOpen] = useState(false);
  const finishButtonRef = useRef<HTMLButtonElement>(null);
  const [finishStatus, setFinishStatus] = useState<"completed" | "partial" | "aborted">("completed");
  const [sessionRpe, setSessionRpe] = useState("");
  const [performance, setPerformance] = useState("");
  const [finishNotes, setFinishNotes] = useState("");
  const [issueLocation, setIssueLocation] = useState("");
  const [issueSide, setIssueSide] = useState<"left" | "right" | "bilateral" | "midline" | "not_applicable" | "unknown">("unknown");
  const [issueSeverity, setIssueSeverity] = useState("3");
  const [templateName, setTemplateName] = useState("");
  const [activeSetStartedAt, setActiveSetStartedAt] = useState<string | null>(null);
  const [activeSetGroupId, setActiveSetGroupId] = useState<string | null>(null);
  const [restStartedAt, setRestStartedAt] = useState<string | null>(null);
  const [editingSet, setEditingSet] = useState<RecordedSetEdit | null>(null);
  const [copyNotice, setCopyNotice] = useState<string | null>(null);
  const [now, setNow] = useState(Date.now());
  const notifiedDeadline = useRef<string | null>(null);

  const session = workspace.activeSession;
  const activeExercise = workspace.activeExercises.find((item) => item.id === selectedExerciseId)
    ?? workspace.activeExercises[0]
    ?? null;
  const exercise = workspace.exercises.find((item) => item.id === activeExercise?.exercise_id) ?? null;
  const setup = workspace.setups.find((item) => item.id === activeExercise?.exercise_setup_id) ?? null;
  const exerciseGroups = workspace.activeGroups.filter((item) => item.session_exercise_id === activeExercise?.id);
  const sourcePlan = workspace.plans.find((item) => item.id === session?.planned_session_id) ?? null;
  const sourcePlanItem = sourcePlan?.exercise_items?.find((item) => item.id === activeExercise?.planned_exercise_id) ?? null;
  const acceptedSubstitutions = sourcePlanItem?.substitution_exercise_ids?.length
    ? sourcePlanItem.substitution_exercise_ids
      .map((id) => workspace.exercises.find((item) => item.id === id && item.active !== false))
      .filter((item): item is FitnessExercise => item != null && item.id !== exercise?.id)
    : workspace.exercises.filter((item) => item.active !== false && item.id !== exercise?.id);
  const comparable = activeExercise
    ? previousComparableComponents(workspace.sessions, activeExercise.exercise_id, activeExercise.exercise_setup_id, session?.id)
    : null;
  const timerSeconds = session?.rest_timer_deadline_utc
    ? Math.max(0, Math.ceil((Date.parse(session.rest_timer_deadline_utc) - now) / 1000))
    : null;
  const elapsedSeconds = session ? Math.max(0, Math.floor((now - Date.parse(session.started_at_utc)) / 1000)) : 0;
  const activeSetSeconds = activeSetStartedAt
    ? Math.max(0, Math.floor((now - Date.parse(activeSetStartedAt)) / 1_000))
    : 0;
  const latestCompletedAt = workspace.activeComponents
    .map((item) => item.completed_at_utc)
    .filter((value): value is string => Boolean(value))
    .sort()
    .at(-1) ?? null;
  const effectiveRestStartedAt = restStartedAt ?? (session?.rest_timer_deadline_utc ? latestCompletedAt : null);
  const restElapsedSeconds = effectiveRestStartedAt
    ? Math.max(0, Math.floor((now - Date.parse(effectiveRestStartedAt)) / 1_000))
    : null;
  const latestCanonicalWeight = useMemo(() => workspace.bodyMeasurements
    .filter((item) => item.metric_key === "body.weight_kg" && !["duplicate", "excluded"].includes(item.canonical_state ?? "canonical") && Date.parse(item.measured_at_utc) <= (session ? Date.parse(session.started_at_utc) : Date.now()))
    .sort((left, right) => right.measured_at_utc.localeCompare(left.measured_at_utc))[0] ?? null, [session, workspace.bodyMeasurements]);

  useEffect(() => {
    if (!session) return undefined;
    const interval = window.setInterval(() => setNow(Date.now()), 1_000);
    return () => window.clearInterval(interval);
  }, [session]);

  useEffect(() => {
    const deadline = session?.rest_timer_deadline_utc ?? null;
    if (!deadline || Date.parse(deadline) > now || notifiedDeadline.current === deadline) return;
    notifiedDeadline.current = deadline;
    void notifyRestComplete();
  }, [now, session?.rest_timer_deadline_utc]);

  useEffect(() => {
    if (!selectedExerciseId && workspace.activeExercises[0]) setSelectedExerciseId(workspace.activeExercises[0].id);
    if (selectedExerciseId && !workspace.activeExercises.some((item) => item.id === selectedExerciseId)) {
      setSelectedExerciseId(workspace.activeExercises[0]?.id ?? "");
    }
  }, [selectedExerciseId, workspace.activeExercises]);

  useEffect(() => {
    const stored = bodyweightFromSession(session) || (latestCanonicalWeight ? String(latestCanonicalWeight.value) : "");
    if (stored) setSetDraft((current) => current.bodyweight ? current : { ...current, bodyweight: stored });
  }, [latestCanonicalWeight, session]);

  useEffect(() => {
    if (session) return;
    const url = new URL(window.location.href);
    const planId = url.searchParams.get("fitness-strength-plan");
    if (!planId) return;
    const plan = workspace.plans.find((item) => item.id === planId);
    if (!plan) return;
    url.searchParams.delete("fitness-strength-plan");
    window.history.replaceState({}, "", url);
    if (!["accepted", "scheduled", "in_progress"].includes(plan.status)) return;
    setStartKind("plan");
    setSourceId(plan.id);
    setTitle(plan.title);
  }, [session, workspace.plans]);

  const startSources = useMemo(() => {
    if (startKind === "plan") return workspace.plans.filter((item) => ["accepted", "scheduled", "in_progress"].includes(item.status));
    if (startKind === "template") return workspace.templates;
    if (startKind === "previous") return workspace.sessions.filter((item) => item.status === "completed");
    return [];
  }, [startKind, workspace.plans, workspace.sessions, workspace.templates]);

  function defaultSetupId(exerciseId: string, preferred?: string | null) {
    if (preferred && workspace.setups.some((item) => item.id === preferred && item.exercise_id === exerciseId)) return preferred;
    return workspace.setups.find((item) => item.exercise_id === exerciseId && item.is_default)?.id
      ?? workspace.setups.find((item) => item.exercise_id === exerciseId)?.id
      ?? null;
  }

  function startItems(selectedKind: StartKind = startKind, selectedSourceId = sourceId): StartItem[] {
    if (selectedKind === "plan") {
      const plan = workspace.plans.find((item) => item.id === selectedSourceId);
      const definition = plan?.workout_version_id
        ? workspace.templates.find((item) => strengthWorkoutVersion(item, plan.workout_version_id))
        : null;
      const prescription = plan?.workout_version_id && definition
        ? strengthTemplateItems(definition, plan.workout_version_id)
        : plan?.exercise_items ?? [];
      return prescription.map((item) => ({
        sourceId: item.id,
        exerciseId: item.exercise_id,
        setupId: defaultSetupId(item.exercise_id, item.exercise_setup_id),
        sequence: item.sequence,
        supersetKey: item.superset_group_key ?? null,
        notes: item.notes ?? null,
        plannedSets: item.planned_sets.map((set) => ({ ...set, sourceIsPlan: true })),
      }));
    }
    if (selectedKind === "template") {
      const definition = workspace.templates.find((item) => item.id === selectedSourceId);
      return strengthTemplateItems(definition).map((item) => ({
        sourceId: null,
        exerciseId: item.exercise_id,
        setupId: defaultSetupId(item.exercise_id, item.exercise_setup_id),
        sequence: item.sequence,
        supersetKey: item.superset_group_key ?? null,
        notes: item.notes ?? null,
        plannedSets: item.planned_sets.map((set) => ({ ...set, sourceIsPlan: false })),
      }));
    }
    if (selectedKind === "previous") {
      const previous = workspace.sessions.find((item) => item.id === selectedSourceId);
      return (previous?.exercises ?? []).map((item) => ({
        sourceId: null,
        exerciseId: item.exercise_id,
        setupId: defaultSetupId(item.exercise_id, item.exercise_setup_id),
        sequence: item.sequence,
        supersetKey: item.superset_group_key ?? null,
        notes: item.notes ?? null,
        plannedSets: (item.set_groups ?? []).map((group) => {
          const component = group.components?.find((candidate) => candidate.component_status !== "skipped");
          return {
            id: crypto.randomUUID(),
            sequence: group.sequence,
            training_role: group.training_role,
            structure_type: group.structure_type,
            component_count: Math.max(1, group.components?.length ?? 1),
            reps_min: component?.reps ?? component?.reps_left ?? null,
            reps_max: component?.reps ?? component?.reps_right ?? null,
            load_min: component?.load_value ?? null,
            load_max: component?.load_value ?? null,
            load_unit: component?.load_unit ?? null,
            rpe_min: component?.rpe ?? null,
            rpe_max: component?.rpe ?? null,
            rir_min: component?.rir ?? null,
            rir_max: component?.rir ?? null,
            rest_s: component?.rest_before_s ?? null,
            is_amrap: group.is_amrap ?? false,
            notes: "Copied from the previous workout",
            sourceIsPlan: false,
          };
        }),
      }));
    }
    return [];
  }

  async function startWorkout(request?: { kind: StartKind; sourceId: string; title: string }) {
    const selectedKind = request?.kind ?? startKind;
    const selectedSourceId = request?.sourceId ?? sourceId;
    const selectedTitle = request?.title ?? title;
    const sessionId = crypto.randomUUID();
    const startedAt = new Date().toISOString();
    const items = startItems(selectedKind, selectedSourceId);
    const plan = selectedKind === "plan" ? workspace.plans.find((item) => item.id === selectedSourceId) : null;
    const definition = selectedKind === "template" ? workspace.templates.find((item) => item.id === selectedSourceId) : null;
    const previous = selectedKind === "previous" ? workspace.sessions.find((item) => item.id === selectedSourceId) : null;
    const sessionBodyweight = latestCanonicalWeight?.value ?? null;
    const inputs: SaveFitnessRecordInput[] = [{
      entityType: "strength_session",
      options: { entityId: sessionId },
      payload: {
        title: selectedTitle.trim() || plan?.title || definition?.name || previous?.title || "Strength workout",
        planned_session_id: plan?.id ?? null,
        status: "in_progress",
        started_at_utc: startedAt,
        local_timezone: localTimeZone(),
        ended_at_utc: null,
        rest_timer_deadline_utc: null,
        session_rpe: null,
        perceived_performance: null,
        matched_plan_key: selectedKind,
        notes: sessionNotesWithBodyweight(null, sessionBodyweight),
      },
    }];
    if ([readiness, energy, soreness, motivation].some(Boolean)) {
      inputs.push({ entityType: "session_checkin", payload: {
        planned_session_id: plan?.id ?? null,
        activity_id: sessionId,
        timing: "pre",
        captured_at_utc: startedAt,
        capture_quality: "contemporaneous",
        captured_before_activity_start: true,
        readiness_1_5: numberOrNull(readiness),
        energy_1_5: numberOrNull(energy),
        soreness_1_5: numberOrNull(soreness),
        motivation_1_5: numberOrNull(motivation),
        session_rpe_1_10: null,
        notes: null,
      } });
    }
    for (const item of items) {
      const sessionExerciseId = crypto.randomUUID();
      inputs.push({ entityType: "strength_session_exercise", options: { entityId: sessionExerciseId }, payload: {
        activity_id: sessionId,
        exercise_id: item.exerciseId,
        exercise_setup_id: item.setupId,
        planned_exercise_id: selectedKind === "plan" ? item.sourceId : null,
        sequence: item.sequence,
        superset_group_key: item.supersetKey,
        variation_note: null,
        notes: item.notes,
      } });
      item.plannedSets.forEach((set) => inputs.push({ entityType: "strength_set_group", payload: {
        activity_id: sessionId,
        session_exercise_id: sessionExerciseId,
        planned_set_id: set.sourceIsPlan ? set.id : null,
        sequence: set.sequence,
        training_role: set.training_role,
        structure_type: set.structure_type,
        status: "planned",
        is_amrap: set.is_amrap,
        failure_state: "none",
        started_at_utc: null,
        completed_at_utc: null,
        notes: targetText(set) ? `Target: ${targetText(set)}` : set.notes ?? null,
      } }));
    }
    await batch.save(inputs);
    setSourceId("");
  }

  useEffect(() => {
    const url = new URL(window.location.href);
    const planId = url.searchParams.get("fitness-strength-start");
    if (!planId) return;
    if (session) {
      url.searchParams.delete("fitness-strength-start");
      window.history.replaceState({}, "", url);
      return;
    }
    if (planId === "blank") {
      // Consume the intent first so Strict Mode and workspace refreshes cannot
      // turn one Today tap into two active workouts.
      url.searchParams.delete("fitness-strength-start");
      window.history.replaceState({}, "", url);
      setStartKind("blank");
      setSourceId("");
      setTitle("Strength workout");
      void startWorkout({ kind: "blank", sourceId: "", title: "Strength workout" }).catch(() => undefined);
      return;
    }
    const plan = workspace.plans.find((item) => item.id === planId);
    if (!plan) return;
    if (plan.workout_version_id && !plan.exercise_items?.length && !workspace.templates.some((item) => strengthWorkoutVersion(item, plan.workout_version_id))) return;

    // Consume the route intent before starting so rerenders and Strict Mode
    // cannot create a second workout from the same tap.
    url.searchParams.delete("fitness-strength-start");
    window.history.replaceState({}, "", url);
    if (!["accepted", "scheduled", "in_progress"].includes(plan.status)) return;
    setStartKind("plan");
    setSourceId(plan.id);
    setTitle(plan.title);
    void startWorkout({ kind: "plan", sourceId: plan.id, title: plan.title }).catch(() => undefined);
  }, [session, workspace.plans, workspace.templates]);

  async function saveSessionDeadline(seconds: number | null) {
    if (!session) return;
    const deadline = seconds == null ? null : new Date(Date.now() + seconds * 1_000).toISOString();
    await single.save("strength_session", sessionPayload(session, { rest_timer_deadline_utc: deadline }), {
      entityId: session.id,
      baseRevision: session.revision ?? null,
    });
  }

  async function requestNotifications() {
    if (typeof Notification === "undefined") return;
    await Notification.requestPermission();
    setNow(Date.now());
  }

  async function reorderExercise(index: number, direction: -1 | 1) {
    const swap = index + direction;
    if (swap < 0 || swap >= workspace.activeExercises.length) return;
    const first = workspace.activeExercises[index];
    const second = workspace.activeExercises[swap];
    await batch.save([
      { entityType: "strength_session_exercise", payload: { ...exercisePayload(first), sequence: second.sequence }, options: { entityId: first.id, baseRevision: first.revision ?? null } },
      { entityType: "strength_session_exercise", payload: { ...exercisePayload(second), sequence: first.sequence }, options: { entityId: second.id, baseRevision: second.revision ?? null } },
    ]);
  }

  async function addExercise() {
    if (!session || !addExerciseId) return;
    const setupId = defaultSetupId(addExerciseId);
    const saved = await single.save("strength_session_exercise", {
      activity_id: session.id,
      exercise_id: addExerciseId,
      exercise_setup_id: setupId,
      planned_exercise_id: null,
      sequence: workspace.activeExercises.length,
      superset_group_key: null,
      variation_note: null,
      notes: null,
    });
    setSelectedExerciseId(String(saved.id));
    setAddExerciseId("");
  }

  async function substituteExercise() {
    if (!activeExercise || !substituteId) return;
    const oldName = workspace.exercises.find((item) => item.id === activeExercise.exercise_id)?.name ?? "planned exercise";
    await single.save("strength_session_exercise", {
      ...exercisePayload(activeExercise),
      exercise_id: substituteId,
      exercise_setup_id: defaultSetupId(substituteId),
      variation_note: `Substituted for ${oldName}`,
    }, { entityId: activeExercise.id, baseRevision: activeExercise.revision ?? null });
    setSubstituteId("");
  }

  async function skipExercise() {
    if (!session || !activeExercise) return;
    const pending = exerciseGroups.filter((group) => ["planned", "in_progress"].includes(group.status));
    const inputs: SaveFitnessRecordInput[] = pending.length ? pending.map((group) => ({
      entityType: "strength_set_group",
      payload: { ...groupPayload(group), status: "skipped", completed_at_utc: new Date().toISOString(), notes: [group.notes, "Exercise skipped"].filter(Boolean).join(" · ") },
      options: { entityId: group.id, baseRevision: group.revision ?? null },
    })) : [{ entityType: "strength_set_group", payload: {
      activity_id: session.id,
      session_exercise_id: activeExercise.id,
      planned_set_id: null,
      sequence: 0,
      training_role: "other",
      structure_type: "straight",
      status: "skipped",
      is_amrap: false,
      failure_state: "none",
      started_at_utc: null,
      completed_at_utc: new Date().toISOString(),
      notes: "Exercise skipped",
    } }];
    await batch.save(inputs);
    const currentIndex = workspace.activeExercises.findIndex((item) => item.id === activeExercise.id);
    setSelectedExerciseId(workspace.activeExercises[currentIndex + 1]?.id ?? workspace.activeExercises[0]?.id ?? "");
  }

  async function startSet() {
    if (!session || !activeExercise || !exercise || activeSetStartedAt) return;
    const startedAt = new Date().toISOString();
    const nextPlannedGroup = exerciseGroups.find((item) => item.status === "planned"
      && !workspace.activeComponents.some((component) => component.set_group_id === item.id));
    setActiveSetStartedAt(startedAt);
    setActiveSetGroupId(nextPlannedGroup?.id ?? null);
    setRestStartedAt(null);
    try {
      if (session.rest_timer_deadline_utc) await saveSessionDeadline(null);
      if (nextPlannedGroup) {
        await single.save("strength_set_group", {
          ...groupPayload(nextPlannedGroup),
          status: "in_progress",
          started_at_utc: startedAt,
          completed_at_utc: null,
        }, { entityId: nextPlannedGroup.id, baseRevision: nextPlannedGroup.revision ?? null });
      }
    } catch (error) {
      setActiveSetStartedAt(null);
      setActiveSetGroupId(null);
      throw error;
    }
  }

  async function stopSet() {
    if (!activeSetStartedAt) return;
    const completedAt = new Date().toISOString();
    await logSet({ startedAt: activeSetStartedAt, completedAt, groupId: activeSetGroupId });
    setActiveSetStartedAt(null);
    setActiveSetGroupId(null);
    setRestStartedAt(completedAt);
  }

  async function logSet(timing?: { startedAt: string; completedAt: string; groupId: string | null }) {
    if (!session || !activeExercise || !exercise) return;
    const completedAt = timing?.completedAt ?? new Date().toISOString();
    const startedAt = timing?.startedAt ?? completedAt;
    const nextPlannedGroup = exerciseGroups.find((item) => item.status === "planned"
      && !workspace.activeComponents.some((component) => component.set_group_id === item.id));
    const existingGroup = timing?.groupId
      ? exerciseGroups.find((item) => item.id === timing.groupId)
      : setDraft.appendGroupId
      ? exerciseGroups.find((item) => item.id === setDraft.appendGroupId)
      : nextPlannedGroup;
    const existingComponents = existingGroup
      ? workspace.activeComponents.filter((item) => item.set_group_id === existingGroup.id)
      : [];
    const groupId = existingGroup?.id ?? crypto.randomUUID();
    const componentStatus = setDraft.status;
    const groupStatus = nextCompoundGroupStatus(existingComponents, componentStatus);
    const load = numberOrNull(setDraft.load);
    const normalized = load == null ? null : normalizedStrengthLoad(load, setup, exercise);
    const restSeconds = numberOrNull(setDraft.rest);
    const inputs: SaveFitnessRecordInput[] = [];
    if (!existingGroup) {
      inputs.push({ entityType: "strength_set_group", options: { entityId: groupId }, payload: {
        activity_id: session.id,
        session_exercise_id: activeExercise.id,
        planned_set_id: null,
        sequence: Math.max(-1, ...exerciseGroups.map((item) => item.sequence)) + 1,
        training_role: setDraft.role,
        structure_type: setDraft.structure,
        status: groupStatus,
        is_amrap: setDraft.amrap,
        failure_state: setDraft.stoppedForIssue ? "stopped_for_body_issue" : setDraft.failure,
        started_at_utc: startedAt,
        completed_at_utc: completedAt,
        notes: null,
      } });
    } else {
      inputs.push({ entityType: "strength_set_group", options: { entityId: existingGroup.id, baseRevision: existingGroup.revision ?? null }, payload: {
        ...groupPayload(existingGroup),
        status: groupStatus,
        is_amrap: existingGroup.is_amrap || setDraft.amrap,
        failure_state: setDraft.stoppedForIssue ? "stopped_for_body_issue" : setDraft.failure === "none" ? existingGroup.failure_state ?? "none" : setDraft.failure,
        started_at_utc: existingGroup.started_at_utc ?? startedAt,
        completed_at_utc: completedAt,
      } });
    }
    inputs.push({ entityType: "strength_set_component", payload: {
      set_group_id: groupId,
      component_index: existingComponents.length,
      component_status: componentStatus,
      reps: exercise.rep_count_mode === "left_right_separate" ? null : numberOrNull(setDraft.reps),
      reps_left: exercise.rep_count_mode === "left_right_separate" ? numberOrNull(setDraft.repsLeft) : null,
      reps_right: exercise.rep_count_mode === "left_right_separate" ? numberOrNull(setDraft.repsRight) : null,
      load_value: load,
      load_unit: load == null ? null : exercise.default_unit ?? "kg",
      load_entry_mode_snapshot: setup?.load_entry_mode ?? exercise.load_entry_mode ?? "total_external",
      normalized_external_load_kg: normalized,
      added_load_kg: (setup?.load_entry_mode ?? exercise.load_entry_mode) === "added_bodyweight" ? load : null,
      assistance_kg: (setup?.load_entry_mode ?? exercise.load_entry_mode) === "assistance" ? load : null,
      bodyweight_kg_snapshot: exercise.bodyweight_involved ? numberOrNull(setDraft.bodyweight) : null,
      duration_s: numberOrNull(setDraft.duration)
        ?? (needsDuration ? Math.max(0, Math.round((Date.parse(completedAt) - Date.parse(startedAt)) / 1_000)) : null),
      distance_m: numberOrNull(setDraft.distance),
      rir: numberOrNull(setDraft.rir),
      rpe: numberOrNull(setDraft.rpe),
      rest_before_s: null,
      tempo_text: setDraft.tempo.trim() || null,
      completed_at_utc: completedAt,
      notes: setDraft.notes.trim() || null,
      extra_metrics: restSeconds == null ? {} : { next_rest_timer_s: restSeconds },
    } });
    if (restSeconds && restSeconds > 0) {
      inputs.push({ entityType: "strength_session", options: { entityId: session.id, baseRevision: session.revision ?? null }, payload: sessionPayload(session, {
        rest_timer_deadline_utc: new Date(Date.now() + restSeconds * 1_000).toISOString(),
      }) });
    }
    await batch.save(inputs);
    setSetDraft((current) => ({
      ...EMPTY_SET,
      reps: current.reps,
      repsLeft: current.repsLeft,
      repsRight: current.repsRight,
      load: current.load,
      rest: current.rest,
      bodyweight: current.bodyweight,
    }));
  }

  function beginEditSet(group: FitnessStrengthSetGroup, component: FitnessStrengthSetComponent) {
    setEditingSet({ group, component });
    setSetDraft((current) => ({
      ...current,
      reps: component.reps == null ? "" : String(component.reps),
      repsLeft: component.reps_left == null ? "" : String(component.reps_left),
      repsRight: component.reps_right == null ? "" : String(component.reps_right),
      load: component.load_value == null ? "" : String(component.load_value),
      duration: component.duration_s == null ? "" : String(component.duration_s),
      distance: component.distance_m == null ? "" : String(component.distance_m),
      rir: component.rir == null ? "" : String(component.rir),
      rpe: component.rpe == null ? "" : String(component.rpe),
      tempo: component.tempo_text ?? "",
      notes: component.notes ?? "",
      failure: group.failure_state === "muscular" || group.failure_state === "technical" ? group.failure_state : "none",
    }));
  }

  async function saveEditedSet() {
    if (!editingSet || !exercise) return;
    const { group, component } = editingSet;
    const load = numberOrNull(setDraft.load);
    await batch.save([
      {
        entityType: "strength_set_group",
        options: { entityId: group.id, baseRevision: group.revision ?? null },
        payload: {
          ...groupPayload(group),
          failure_state: setDraft.failure,
        },
      },
      {
        entityType: "strength_set_component",
        options: { entityId: component.id, baseRevision: component.revision ?? null },
        payload: {
          set_group_id: group.id,
          component_index: component.component_index,
          component_status: component.component_status,
          reps: exercise.rep_count_mode === "left_right_separate" ? null : numberOrNull(setDraft.reps),
          reps_left: exercise.rep_count_mode === "left_right_separate" ? numberOrNull(setDraft.repsLeft) : null,
          reps_right: exercise.rep_count_mode === "left_right_separate" ? numberOrNull(setDraft.repsRight) : null,
          load_value: load,
          load_unit: load == null ? null : component.load_unit ?? exercise.default_unit ?? "kg",
          load_entry_mode_snapshot: component.load_entry_mode_snapshot ?? setup?.load_entry_mode ?? exercise.load_entry_mode ?? "total_external",
          normalized_external_load_kg: load == null ? null : normalizedStrengthLoad(load, setup, exercise),
          added_load_kg: component.added_load_kg != null ? load : null,
          assistance_kg: component.assistance_kg != null ? load : null,
          bodyweight_kg_snapshot: component.bodyweight_kg_snapshot ?? null,
          duration_s: numberOrNull(setDraft.duration),
          distance_m: numberOrNull(setDraft.distance),
          rir: numberOrNull(setDraft.rir),
          rpe: numberOrNull(setDraft.rpe),
          rest_before_s: component.rest_before_s ?? null,
          tempo_text: setDraft.tempo.trim() || null,
          completed_at_utc: component.completed_at_utc ?? group.completed_at_utc ?? new Date().toISOString(),
          notes: setDraft.notes.trim() || null,
          extra_metrics: component.extra_metrics ?? component.extra_metrics_json ?? {},
        },
      },
    ]);
    setEditingSet(null);
  }

  async function copyWorkout(sessionToCopy: FitnessStrengthSession) {
    await copyPlainText(strengthWorkoutExportText(sessionToCopy));
    setCopyNotice("Workout copied — ready to paste into an LLM.");
  }

  async function finishWorkout() {
    if (!session) return;
    const endedAt = new Date().toISOString();
    const inputs: SaveFitnessRecordInput[] = [{
      entityType: "strength_session",
      options: { entityId: session.id, baseRevision: session.revision ?? null },
      payload: sessionPayload(session, {
        status: finishStatus,
        ended_at_utc: endedAt,
        rest_timer_deadline_utc: null,
        session_rpe: numberOrNull(sessionRpe),
        perceived_performance: numberOrNull(performance),
        notes: sessionNotesWithBodyweight(session.notes, numberOrNull(bodyweightFromSession(session)) ?? latestCanonicalWeight?.value ?? null, finishNotes.trim() || null),
      }),
    }, {
      entityType: "session_checkin",
      payload: {
        planned_session_id: session.planned_session_id ?? null,
        activity_id: session.id,
        timing: "post",
        captured_at_utc: endedAt,
        capture_quality: "contemporaneous",
        captured_before_activity_start: false,
        readiness_1_5: null,
        energy_1_5: null,
        soreness_1_5: null,
        motivation_1_5: null,
        session_rpe_1_10: numberOrNull(sessionRpe),
        perceived_performance_1_5: numberOrNull(performance),
        matched_plan_key: session.matched_plan_key ?? null,
        notes: finishNotes.trim() || null,
      },
    }];
    if (sourcePlan) {
      const planStatus = finishStatus === "completed" ? "completed" : finishStatus === "partial" ? "partially_completed" : "cancelled";
      inputs.push({ entityType: "planned_session", options: { entityId: sourcePlan.id, baseRevision: sourcePlan.revision ?? null }, payload: planPayload(sourcePlan, session.id, planStatus) });
    }
    if (issueLocation.trim()) {
      inputs.push({ entityType: "body_issue", payload: {
        planned_session_id: session.planned_session_id ?? null,
        activity_id: session.id,
        observed_at_utc: endedAt,
        issue_type_key: "discomfort",
        body_location_key: issueLocation,
        side: issueSide,
        severity_0_10: Number(issueSeverity),
        timing: "during",
        changed_session: finishStatus !== "completed",
        session_change_key: finishStatus === "aborted" ? "stopped" : finishStatus === "partial" ? "reduced_load" : "none",
        trend_key: "unknown",
        status: "active",
        resolved_at_utc: null,
        notes: finishNotes.trim() || null,
      } });
    }
    await batch.save(inputs);
    setFinishOpen(false);
  }

  async function saveTemplate() {
    if (!session || !templateName.trim()) return;
    const exerciseItems = workspace.activeExercises.map((item) => ({
      id: crypto.randomUUID(),
      exercise_id: item.exercise_id,
      exercise_setup_id: item.exercise_setup_id ?? null,
      sequence: item.sequence,
      superset_group_key: item.superset_group_key ?? null,
      substitution_exercise_ids: sourcePlan?.exercise_items?.find((planned) => planned.id === item.planned_exercise_id)?.substitution_exercise_ids ?? [],
      notes: item.notes ?? null,
      planned_sets: workspace.activeGroups.filter((group) => group.session_exercise_id === item.id).map((group) => {
        const component = workspace.activeComponents.find((candidate) => candidate.set_group_id === group.id && candidate.component_status !== "skipped");
        return {
          id: crypto.randomUUID(),
          sequence: group.sequence,
          training_role: group.training_role,
          structure_type: group.structure_type,
          component_count: Math.max(1, workspace.activeComponents.filter((candidate) => candidate.set_group_id === group.id).length),
          reps_min: component?.reps ?? component?.reps_left ?? null,
          reps_max: component?.reps ?? component?.reps_right ?? null,
          load_min: component?.load_value ?? null,
          load_max: component?.load_value ?? null,
          load_unit: component?.load_unit ?? null,
          rpe_min: component?.rpe ?? null,
          rpe_max: component?.rpe ?? null,
          rir_min: component?.rir ?? null,
          rir_max: component?.rir ?? null,
          rest_s: component?.rest_before_s
            ?? (typeof component?.extra_metrics?.next_rest_timer_s === "number" ? component.extra_metrics.next_rest_timer_s : null),
          is_amrap: group.is_amrap ?? false,
          notes: group.notes?.startsWith("Target:") ? group.notes.slice(7).trim() : null,
        };
      }),
    }));
    await single.save("workout_definition", {
      sport_key: "strength",
      name: templateName.trim(),
      description: `Saved from ${session.title}`,
      active: true,
      version: {
        id: crypto.randomUUID(),
        title: templateName.trim(),
        purpose: null,
        estimated_duration_s: Math.max(0, Math.floor((Date.now() - Date.parse(session.started_at_utc)) / 1_000)),
        estimated_distance_m: null,
        structured_summary: {},
        version_source: "user",
        accepted_at: new Date().toISOString(),
        exercise_items: exerciseItems,
        run_steps: [],
        run_cues: [],
      },
    });
    setTemplateName("");
  }

  if (!session) {
    return (
      <div className="fitness-module__strength-workout">
        {workspace.bodyIssues.length ? <div className="fitness-module__notice" role="status">Before you start: {workspace.bodyIssues.map((item) => `${bodyLocationDisplay(item.body_location_key, bodyLocations.data ?? [])} ${item.side ?? ""} (${item.severity_0_10}/10)`).join(", ")} is active. Substitute or reduce work if it changes the session.</div> : null}
        <FitnessCard title="Start a workout" detail="Choose a source, optionally check in, then keep logging if the connection drops.">
          <div className="fitness-module__segmented" role="group" aria-label="Workout source">
            {(["blank", "plan", "template", "previous"] as const).map((kind) => (
              <button className={startKind === kind ? "is-active" : ""} key={kind} onClick={() => { setStartKind(kind); setSourceId(""); }} type="button">
                {kind === "previous" ? "Previous workout" : kind[0].toUpperCase() + kind.slice(1)}
              </button>
            ))}
          </div>
          <form className="fitness-module__form" onSubmit={submitForm(startWorkout)}>
            <div className="fitness-module__fields">
              <label className="fitness-module__field is-wide">Workout title
                <input value={title} onChange={(event) => setTitle(event.target.value)} required />
              </label>
              {startKind !== "blank" ? (
                <label className="fitness-module__field is-wide">{startKind === "plan" ? "Planned session" : startKind === "template" ? "Template" : "Completed session"}
                  <select value={sourceId} onChange={(event) => setSourceId(event.target.value)} required>
                    <option value="">Choose…</option>
                    {startSources.map((item) => <option value={item.id} key={item.id}>{"name" in item ? item.name : item.title}</option>)}
                  </select>
                </label>
              ) : null}
            </div>
            <div>
              <strong>How ready do you feel?</strong>
              <div className="fitness-module__readiness fitness-module__readiness--choices" role="group" aria-label="Readiness from one to five">
                {[1, 2, 3, 4, 5].map((value) => <button className={readiness === String(value) ? "is-active" : ""} key={value} onClick={() => setReadiness(String(value))} type="button">{value}</button>)}
              </div>
              <button className="button button--secondary button--compact" type="button" onClick={() => setAdvancedCheckin((value) => !value)}>{advancedCheckin ? "Hide details" : "Add energy, soreness and motivation"}</button>
            </div>
            {advancedCheckin ? (
              <div className="fitness-module__fields">
                {[["Energy", energy, setEnergy], ["Soreness", soreness, setSoreness], ["Motivation", motivation, setMotivation]].map(([label, value, setter]) => (
                  <label className="fitness-module__field" key={label as string}>{label as string} (1–5)
                    <input type="number" min="1" max="5" value={value as string} onChange={(event) => (setter as (next: string) => void)(event.target.value)} />
                  </label>
                ))}
              </div>
            ) : null}
            <div className="fitness-module__form-footer">
              <button className="button button--primary" disabled={batch.saving || (startKind !== "blank" && !sourceId)} type="submit"><Plus size={16} aria-hidden="true" /> Start workout</button>
              <FitnessFormStatus saving={batch.saving} saved={batch.saved} error={batch.saveError} />
            </div>
          </form>
        </FitnessCard>
        <FitnessCard title="Recent strength sessions" detail="Reuse a completed session from the source selector above.">
          {workspace.sessions.filter((item) => item.status === "completed").length ? <ul className="fitness-module__list">
            {workspace.sessions.filter((item) => item.status === "completed").slice(0, 6).map((item) => <li key={item.id}><div><strong>{item.title}</strong><small>{formatFitnessDateTime(item.started_at_utc)} · {item.status}</small></div><button className="button button--secondary button--compact" type="button" onClick={() => void copyWorkout(item)}><Copy size={15} aria-hidden="true" /> Copy</button></li>)}
          </ul> : <div className="fitness-module__empty">Your completed workouts will appear here.</div>}
          {copyNotice ? <div className="fitness-module__notice fitness-module__notice--success" role="status">{copyNotice}</div> : null}
        </FitnessCard>
      </div>
    );
  }

  const nextExercise = workspace.activeExercises.find((item) => {
    const groups = workspace.activeGroups.filter((group) => group.session_exercise_id === item.id);
    return groups.length === 0 || groups.some((group) => ["planned", "in_progress"].includes(group.status));
  });
  const presentExerciseIds = new Set(workspace.activeExercises.map((item) => item.exercise_id));
  const matchesExerciseQuery = (item: FitnessExercise) => !exerciseQuery.trim() || [item.name, ...(item.aliases ?? []), item.movement_pattern_key, item.equipment_type].filter(Boolean).join(" ").toLocaleLowerCase().includes(exerciseQuery.trim().toLocaleLowerCase());
  const plannedPicker = (sourcePlan?.exercise_items ?? []).map((item) => workspace.exercises.find((exerciseItem) => exerciseItem.id === item.exercise_id)).filter((item): item is FitnessExercise => item != null).filter((item) => !presentExerciseIds.has(item.id) && matchesExerciseQuery(item));
  const plannedPickerIds = new Set(plannedPicker.map((item) => item.id));
  const favouritePicker = workspace.exercises.filter((item) => item.favourite && !presentExerciseIds.has(item.id) && !plannedPickerIds.has(item.id) && matchesExerciseQuery(item));
  const favouritePickerIds = new Set(favouritePicker.map((item) => item.id));
  const recentIds = [...new Set(workspace.sessions.filter((item) => item.status === "completed").sort((left, right) => right.started_at_utc.localeCompare(left.started_at_utc)).flatMap((item) => item.exercises?.map((entry) => entry.exercise_id) ?? []))];
  const recentPicker = recentIds.map((id) => workspace.exercises.find((item) => item.id === id)).filter((item): item is FitnessExercise => item != null).filter((item) => !presentExerciseIds.has(item.id) && !plannedPickerIds.has(item.id) && !favouritePickerIds.has(item.id) && matchesExerciseQuery(item));
  const categorizedIds = new Set([...plannedPickerIds, ...favouritePickerIds, ...recentPicker.map((item) => item.id)]);
  const cataloguePicker = workspace.exercises.filter((item) => !presentExerciseIds.has(item.id) && !categorizedIds.has(item.id) && matchesExerciseQuery(item)).sort((left, right) => left.name.localeCompare(right.name));
  const loadMode = setup?.load_entry_mode ?? exercise?.load_entry_mode ?? "total_external";
  const measurementMode = exercise?.measurement_mode ?? "reps_load";
  const needsReps = ["reps_load", "reps_only"].includes(measurementMode);
  const needsDuration = ["duration", "duration_load"].includes(measurementMode);
  const needsDistance = ["distance", "distance_load"].includes(measurementMode);
  const needsLoad = !["bodyweight_only", "none"].includes(loadMode) && !["reps_only", "duration", "distance"].includes(measurementMode);

  return (
    <div className="fitness-module__strength-workout">
      <section className="fitness-module__workout-bar" aria-label="Active workout summary">
        <div><span>Active workout</span><strong>{session.title}</strong><small>{online ? "Syncing when saved" : "Offline · changes stay on this device"}</small></div>
        <FitnessStat label="Elapsed" value={formatStrengthClock(elapsedSeconds)} />
        <FitnessStat label="Next" value={workspace.exercises.find((item) => item.id === nextExercise?.exercise_id)?.name ?? "Complete"} />
        <div className="fitness-module__button-row">
          <button className="button button--secondary" type="button" onClick={() => void copyWorkout(session)}><Copy size={16} aria-hidden="true" /> Copy workout</button>
          <button ref={finishButtonRef} className="button button--primary" type="button" onClick={() => setFinishOpen(true)}><CircleStop size={16} aria-hidden="true" /> Finish</button>
        </div>
      </section>

      {copyNotice ? <div className="fitness-module__notice fitness-module__notice--success" role="status">{copyNotice}</div> : null}

      {workspace.bodyIssues.length ? <div className="fitness-module__notice" role="status">Active body issue: {workspace.bodyIssues.map((item) => `${bodyLocationDisplay(item.body_location_key, bodyLocations.data ?? [])} (${item.severity_0_10}/10)`).join(", ")}. Adjust or stop if needed.</div> : null}

      <FitnessCard className="fitness-module__rest-card" title="Rest" detail="Starts automatically when you stop a set.">
        <div className="fitness-module__rest-timer"><Clock3 aria-hidden="true" /><div><span>{restElapsedSeconds == null ? "Stop a set to begin" : "Rest elapsed"}</span><strong>{restElapsedSeconds == null ? "—" : formatStrengthClock(restElapsedSeconds)}</strong>{timerSeconds != null ? <small>{timerSeconds > 0 ? `${formatStrengthClock(timerSeconds)} to target` : "Target reached"}</small> : null}</div></div>
        <details className="fitness-module__details"><summary>Adjust rest target</summary><div className="fitness-module__button-row">
          {[60, 90, 120, 180].map((seconds) => <button className="button button--secondary button--compact" key={seconds} type="button" onClick={() => { setRestStartedAt(new Date().toISOString()); void saveSessionDeadline(seconds); }}>{seconds}s</button>)}
          {timerSeconds != null ? <button className="button button--secondary button--compact" type="button" onClick={() => { setRestStartedAt(null); void saveSessionDeadline(null); }}><TimerReset size={15} aria-hidden="true" /> Dismiss</button> : null}
          {typeof Notification !== "undefined" && Notification.permission !== "granted" ? <button className="button button--secondary button--compact" type="button" onClick={() => void requestNotifications()}><Bell size={15} aria-hidden="true" /> Allow rest alerts</button> : null}
        </div></details>
      </FitnessCard>

      <div className="fitness-module__strength-layout">
        <aside className="fitness-module__exercise-rail" aria-label="Workout exercises">
          {workspace.activeExercises.map((item, index) => {
            const itemExercise = workspace.exercises.find((candidate) => candidate.id === item.exercise_id);
            const itemGroups = workspace.activeGroups.filter((group) => group.session_exercise_id === item.id);
            const performed = itemGroups.filter((group) => ["completed", "partial"].includes(group.status)).length;
            return <div className={item.id === activeExercise?.id ? "is-active" : ""} key={item.id}>
              <button type="button" onClick={() => setSelectedExerciseId(item.id)}><strong>{itemExercise?.name ?? "Exercise"}</strong><small>{performed}/{Math.max(performed, itemGroups.length)} sets · {item.variation_note ?? "planned setup"}</small></button>
              <span>
                <button aria-label={`Move ${itemExercise?.name ?? "exercise"} up`} disabled={index === 0} type="button" onClick={() => void reorderExercise(index, -1)}><ChevronUp size={15} /></button>
                <button aria-label={`Move ${itemExercise?.name ?? "exercise"} down`} disabled={index === workspace.activeExercises.length - 1} type="button" onClick={() => void reorderExercise(index, 1)}><ChevronDown size={15} /></button>
              </span>
            </div>;
          })}
          <div className="fitness-module__rail-add">
            <label className="fitness-module__field">Exercise<select aria-label="Exercise to add" value={addExerciseId} onChange={(event) => setAddExerciseId(event.target.value)}>
              <option value="">Choose exercise…</option>
              {plannedPicker.length ? <optgroup label="Planned remaining">{plannedPicker.map((item) => <option key={item.id} value={item.id}>{item.name}</option>)}</optgroup> : null}
              {favouritePicker.length ? <optgroup label="Favourites">{favouritePicker.map((item) => <option key={item.id} value={item.id}>{item.name}</option>)}</optgroup> : null}
              {recentPicker.length ? <optgroup label="Recent">{recentPicker.map((item) => <option key={item.id} value={item.id}>{item.name}</option>)}</optgroup> : null}
              {cataloguePicker.length ? <optgroup label="Catalogue">{cataloguePicker.map((item) => <option key={item.id} value={item.id}>{item.name}</option>)}</optgroup> : null}
            </select></label>
            <button className="button button--secondary button--compact" disabled={!addExerciseId} type="button" onClick={() => void addExercise()}><Plus size={15} /> Add</button>
            <details className="fitness-module__details"><summary>Find another exercise</summary><input aria-label="Search exercises to add" placeholder="Search by name" type="search" value={exerciseQuery} onChange={(event) => setExerciseQuery(event.target.value)} /></details>
          </div>
        </aside>

        <main className="fitness-module__exercise-workspace">
          {activeExercise && exercise ? <>
            <FitnessCard title={exercise.name} detail={`${setup?.name ?? "No named setup"} · enter ${strengthSetupLoadLabel(setup, exercise)}`}>
              <div className="fitness-module__target-grid">
                <div><span>Planned target</span><strong>{plannedStrengthTarget(sourcePlanItem) ?? exerciseGroups.find((item) => item.notes?.startsWith("Target:"))?.notes?.replace(/^Target:\s*/, "") ?? "No fixed target"}</strong></div>
                <div><span>Previous comparable work</span><strong>{previousPerformanceLabel(comparable) ?? "No comparable set yet"}</strong></div>
              </div>
              <details className="fitness-module__details"><summary>Change or skip exercise</summary><div className="fitness-module__button-row">
                <select aria-label="Substitute exercise" value={substituteId} onChange={(event) => setSubstituteId(event.target.value)}>
                  <option value="">Choose substitution…</option>
                  {acceptedSubstitutions.map((item) => <option value={item.id} key={item.id}>{item.name}</option>)}
                </select>
                <button className="button button--secondary button--compact" disabled={!substituteId} onClick={() => void substituteExercise()} type="button">Substitute</button>
                <button className="button button--secondary button--compact" onClick={() => void skipExercise()} type="button"><SkipForward size={15} /> Skip exercise</button>
              </div></details>
              {sourcePlanItem?.substitution_exercise_ids?.length ? <small className="fitness-module__muted">Showing the acceptable substitutions saved with this plan.</small> : null}
            </FitnessCard>

            <FitnessCard title="Recorded logical sets" detail="Drops, rest-pause and clusters stay grouped instead of inflating set counts.">
              {exerciseGroups.length ? <ol className="fitness-module__set-list">
                {exerciseGroups.map((group) => {
                  const components = workspace.activeComponents.filter((item) => item.set_group_id === group.id);
                  return <li key={group.id}>
                    <div><strong>{group.training_role} · {group.structure_type.replaceAll("_", " ")}</strong><small>{group.status}{group.is_amrap ? " · AMRAP" : ""}{group.failure_state && group.failure_state !== "none" ? ` · ${group.failure_state} failure` : ""}</small>{group.notes ? <small>{group.notes}</small> : null}</div>
                    <div className="fitness-module__component-chips">{components.length ? components.map((component) => <span key={component.id}>{component.load_value != null ? `${component.load_value} ${component.load_unit ?? "kg"} × ` : ""}{component.reps_left != null || component.reps_right != null ? `${component.reps_left ?? "?"}/${component.reps_right ?? "?"}` : component.reps ?? (component.duration_s != null ? `${component.duration_s}s` : component.distance_m != null ? `${component.distance_m}m` : component.component_status)}{component.rir != null ? ` @${component.rir} RIR` : component.rpe != null ? ` @${component.rpe} RPE` : ""}<button type="button" aria-label={`Edit set ${group.sequence + 1}`} onClick={() => beginEditSet(group, component)}><Pencil size={14} aria-hidden="true" /> Edit</button></span>) : <span>Target shell · not performed</span>}</div>
                  </li>;
                })}
              </ol> : <div className="fitness-module__empty">Log the first set below.</div>}
            </FitnessCard>

            <FitnessCard title="Next set" detail="Enter the work, start, then stop. Rest begins automatically.">
              <form className="fitness-module__form" onSubmit={submitForm(activeSetStartedAt ? stopSet : startSet)}>
                <div className="fitness-module__quick-set">
                  {needsLoad ? <label className="fitness-module__field">Weight ({strengthSetupLoadLabel(setup, exercise)})<input disabled={Boolean(activeSetStartedAt)} inputMode="decimal" min="0" step="any" value={setDraft.load} onChange={(event) => setSetDraft((value) => ({ ...value, load: event.target.value }))} /></label> : null}
                  {needsReps && exercise.rep_count_mode === "left_right_separate" ? <><label className="fitness-module__field">Left reps<input disabled={Boolean(activeSetStartedAt)} inputMode="numeric" min="0" type="number" value={setDraft.repsLeft} onChange={(event) => setSetDraft((value) => ({ ...value, repsLeft: event.target.value }))} /></label><label className="fitness-module__field">Right reps<input disabled={Boolean(activeSetStartedAt)} inputMode="numeric" min="0" type="number" value={setDraft.repsRight} onChange={(event) => setSetDraft((value) => ({ ...value, repsRight: event.target.value }))} /></label></> : needsReps ? <label className="fitness-module__field">{strengthRepetitionLabel(setup, exercise)}<input disabled={Boolean(activeSetStartedAt)} inputMode="numeric" min="0" type="number" value={setDraft.reps} onChange={(event) => setSetDraft((value) => ({ ...value, reps: event.target.value }))} /></label> : null}
                  <div className="fitness-module__set-clock" aria-live="polite"><span>{activeSetStartedAt ? "Set running" : "Ready"}</span><strong>{formatStrengthClock(activeSetSeconds)}</strong></div>
                  <button className={activeSetStartedAt ? "button fitness-module__stop-set" : "button button--primary"} disabled={batch.saving || single.saving} type="submit">{activeSetStartedAt ? <><Square size={18} aria-hidden="true" /> Stop set</> : <><Play size={18} aria-hidden="true" /> Start set</>}</button>
                  <button aria-pressed={setDraft.failure === "muscular"} className={setDraft.failure === "muscular" ? "button fitness-module__failure is-active" : "button fitness-module__failure"} disabled={Boolean(activeSetStartedAt)} type="button" onClick={() => setSetDraft((value) => ({ ...value, failure: value.failure === "muscular" ? "none" : "muscular" }))}>Failure{setDraft.failure === "muscular" ? " recorded" : ""}</button>
                </div>
                <details className="fitness-module__details fitness-module__set-details"><summary>More set details</summary><div className="fitness-module__fields">
                  <label className="fitness-module__field">Set type<select value={setDraft.structure} onChange={(event) => setSetDraft((value) => ({ ...value, structure: event.target.value as SetDraft["structure"] }))}><option value="straight">Straight</option><option value="drop">Drop</option><option value="rest_pause">Rest-pause</option><option value="cluster">Cluster</option><option value="other">Other</option></select></label>
                  <label className="fitness-module__field">Role<select value={setDraft.role} onChange={(event) => setSetDraft((value) => ({ ...value, role: event.target.value as SetDraft["role"] }))}><option value="warmup">Warm-up</option><option value="working">Working</option><option value="backoff">Back-off</option><option value="technique">Technique</option><option value="test">Test</option><option value="other">Other</option></select></label>
                  {needsDistance ? <label className="fitness-module__field">Distance (metres)<input inputMode="decimal" min="0" step="any" value={setDraft.distance} onChange={(event) => setSetDraft((value) => ({ ...value, distance: event.target.value }))} /></label> : null}
                  <label className="fitness-module__field">Reps in reserve<input inputMode="decimal" min="0" max="10" step="0.5" value={setDraft.rir} onChange={(event) => setSetDraft((value) => ({ ...value, rir: event.target.value, rpe: "" }))} /></label>
                  <label className="fitness-module__field">RPE<input inputMode="decimal" min="0" max="10" step="0.5" value={setDraft.rpe} onChange={(event) => setSetDraft((value) => ({ ...value, rpe: event.target.value, rir: "" }))} /></label>
                  <label className="fitness-module__field">Rest target (seconds)<input inputMode="numeric" min="0" type="number" value={setDraft.rest} onChange={(event) => setSetDraft((value) => ({ ...value, rest: event.target.value }))} /></label>
                  <label className="fitness-module__field">Tempo<input placeholder="e.g. 3-1-1-0" value={setDraft.tempo} onChange={(event) => setSetDraft((value) => ({ ...value, tempo: event.target.value }))} /></label>
                  <label className="fitness-module__field">Result<select value={setDraft.status} onChange={(event) => setSetDraft((value) => ({ ...value, status: event.target.value as SetDraft["status"] }))}><option value="completed">Completed</option><option value="partial">Partial</option><option value="skipped">Skipped</option></select></label>
                  <label className="fitness-module__check"><input checked={setDraft.amrap} type="checkbox" onChange={(event) => setSetDraft((value) => ({ ...value, amrap: event.target.checked }))} /> AMRAP</label>
                  <label className="fitness-module__check is-wide"><input checked={setDraft.stoppedForIssue} type="checkbox" onChange={(event) => setSetDraft((value) => ({ ...value, stoppedForIssue: event.target.checked }))} /> A body issue ended the set</label>
                  <label className="fitness-module__field is-wide">Notes<textarea value={setDraft.notes} onChange={(event) => setSetDraft((value) => ({ ...value, notes: event.target.value }))} /></label>
                </div></details>
                <FitnessFormStatus saving={batch.saving || single.saving} saved={batch.saved || single.saved} error={batch.saveError ?? single.saveError} />
              </form>
            </FitnessCard>
          </> : <FitnessCard><div className="fitness-module__empty">Add an exercise to begin logging.</div></FitnessCard>}
        </main>
      </div>

      <details className="fitness-module__maintenance"><summary>Save this workout as a template</summary><div className="fitness-module__maintenance-body"><form className="fitness-module__form" onSubmit={submitForm(saveTemplate)}><div className="fitness-module__form-footer"><label className="fitness-module__field"><span>Template name</span><input value={templateName} onChange={(event) => setTemplateName(event.target.value)} required /></label><button className="button button--secondary" disabled={single.saving} type="submit"><Save size={16} /> Save template</button></div></form></div></details>

      <Modal open={editingSet != null} onOpenChange={(open) => { if (!open) setEditingSet(null); }} title="Edit completed set" description="Correct the weight, reps or failure flag after stopping."><form className="fitness-module__form" onSubmit={submitForm(saveEditedSet)}><div className="fitness-module__fields">
        {needsLoad ? <label className="fitness-module__field">Weight ({strengthSetupLoadLabel(setup, exercise)})<input inputMode="decimal" min="0" step="any" value={setDraft.load} onChange={(event) => setSetDraft((value) => ({ ...value, load: event.target.value }))} /></label> : null}
        {needsReps && exercise?.rep_count_mode === "left_right_separate" ? <><label className="fitness-module__field">Left reps<input inputMode="numeric" min="0" type="number" value={setDraft.repsLeft} onChange={(event) => setSetDraft((value) => ({ ...value, repsLeft: event.target.value }))} /></label><label className="fitness-module__field">Right reps<input inputMode="numeric" min="0" type="number" value={setDraft.repsRight} onChange={(event) => setSetDraft((value) => ({ ...value, repsRight: event.target.value }))} /></label></> : needsReps ? <label className="fitness-module__field">Reps<input inputMode="numeric" min="0" type="number" value={setDraft.reps} onChange={(event) => setSetDraft((value) => ({ ...value, reps: event.target.value }))} /></label> : null}
      </div><button aria-pressed={setDraft.failure === "muscular"} className={setDraft.failure === "muscular" ? "button fitness-module__failure is-active" : "button fitness-module__failure"} type="button" onClick={() => setSetDraft((value) => ({ ...value, failure: value.failure === "muscular" ? "none" : "muscular" }))}>Failure{setDraft.failure === "muscular" ? " recorded" : ""}</button><div className="fitness-module__form-footer"><button className="button button--primary" disabled={batch.saving} type="submit">Save changes</button><button className="button button--secondary" type="button" onClick={() => setEditingSet(null)}>Cancel</button><FitnessFormStatus saving={batch.saving} saved={batch.saved} error={batch.saveError} /></div></form></Modal>

      <Modal open={finishOpen} onOpenChange={setFinishOpen} returnFocusRef={finishButtonRef} size="wide" title="Finish workout" description="Record the outcome and any body issue before closing the session."><form className="fitness-module__form" onSubmit={submitForm(finishWorkout)}><div className="fitness-module__fields">
        <label className="fitness-module__field">Outcome<select value={finishStatus} onChange={(event) => setFinishStatus(event.target.value as typeof finishStatus)}><option value="completed">Completed</option><option value="partial">Partially completed</option><option value="aborted">Stopped</option></select></label>
        <label className="fitness-module__field">Session RPE (1–10)<input min="1" max="10" step="0.5" type="number" value={sessionRpe} onChange={(event) => setSessionRpe(event.target.value)} /></label>
        <label className="fitness-module__field">Perceived performance (1–5)<input min="1" max="5" type="number" value={performance} onChange={(event) => setPerformance(event.target.value)} /></label>
        <label className="fitness-module__field">Body issue region (optional)<select value={issueLocation} disabled={bodyLocations.loading} onChange={(event) => setIssueLocation(event.target.value)}><option value="">No issue</option>{(bodyLocations.data ?? []).filter((item) => item.active).map((item) => <option value={item.location_key} key={item.location_key}>{item.display_name}</option>)}</select></label>
        {issueLocation ? <label className="fitness-module__field">Side<select value={issueSide} onChange={(event) => setIssueSide(event.target.value as typeof issueSide)}><option value="left">Left</option><option value="right">Right</option><option value="bilateral">Both sides</option><option value="midline">Midline</option><option value="not_applicable">Not applicable</option><option value="unknown">Unknown</option></select></label> : null}
        {issueLocation ? <label className="fitness-module__field">Issue severity (0–10)<input min="0" max="10" type="number" value={issueSeverity} onChange={(event) => setIssueSeverity(event.target.value)} /></label> : null}
        <label className="fitness-module__field is-wide">Notes<textarea value={finishNotes} onChange={(event) => setFinishNotes(event.target.value)} /></label>
      </div>{bodyLocations.error ? <div className="fitness-module__notice fitness-module__notice--error" role="alert"><span>{bodyLocations.error}</span><button className="button button--secondary" type="button" onClick={bodyLocations.reload}>Try again</button></div> : null}<div className="fitness-module__form-footer"><button className="button button--primary" disabled={batch.saving} type="submit"><CircleStop size={16} /> Finish workout</button><button className="button button--secondary" onClick={() => setFinishOpen(false)} type="button">Keep training</button><FitnessFormStatus saving={batch.saving} saved={batch.saved} error={batch.saveError} /></div></form></Modal>
    </div>
  );
}
