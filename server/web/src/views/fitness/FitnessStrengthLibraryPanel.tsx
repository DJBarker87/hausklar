import { Archive, Copy, GitMerge, Plus, Star } from "lucide-react";
import { useMemo, useState } from "react";

import { api } from "../../api";
import type {
  FitnessExercise,
  FitnessExerciseMergePreview,
  FitnessExerciseSetup,
  FitnessExerciseSetupMergePreview,
} from "../../fitness/contract";
import type { SaveFitnessRecordInput } from "../../fitness/offlineStore";
import { strengthSetupLoadLabel } from "../../fitness/strengthWorkout";
import type { FitnessStrengthWorkspace } from "./FitnessStrengthView";
import {
  FitnessCard,
  FitnessFormStatus,
  errorMessage,
  submitForm,
  useFitnessBatchSave,
  useFitnessSave,
} from "./shared";

type ExerciseForm = {
  name: string;
  aliases: string;
  movement: string;
  measurement: string;
  repMode: string;
  loadMode: string;
  equipment: string;
  primaryMuscles: string;
  secondaryMuscles: string;
  bodyweight: boolean;
  favourite: boolean;
  setupName: string;
};

const EMPTY_EXERCISE: ExerciseForm = {
  name: "",
  aliases: "",
  movement: "other",
  measurement: "reps_load",
  repMode: "total",
  loadMode: "total_external",
  equipment: "",
  primaryMuscles: "",
  secondaryMuscles: "",
  bodyweight: false,
  favourite: false,
  setupName: "Default",
};

function splitTerms(value: string): string[] {
  return [...new Set(value.split(",").map((item) => item.trim()).filter(Boolean))];
}

function exerciseSavePayload(exercise: FitnessExercise, overrides: Partial<FitnessExercise> = {}) {
  const next = { ...exercise, ...overrides };
  return {
    seed_key: next.seed_key ?? null,
    name: next.name,
    aliases: next.aliases ?? [],
    movement_pattern_key: next.movement_pattern_key ?? "other",
    measurement_mode: next.measurement_mode ?? "reps_load",
    rep_count_mode: next.rep_count_mode ?? "total",
    load_entry_mode: next.load_entry_mode ?? "total_external",
    default_unit: next.default_unit ?? "kg",
    unilateral_mode: next.unilateral_mode ?? "bilateral",
    equipment_type: next.equipment_type ?? null,
    bodyweight_involved: next.bodyweight_involved ?? false,
    progression_direction: next.progression_direction ?? "higher",
    notes: null,
    favourite: next.favourite ?? false,
    active: next.active ?? true,
    muscle_roles: next.muscle_roles ?? [],
  };
}

function setupSavePayload(setup: FitnessExerciseSetup, overrides: Partial<FitnessExerciseSetup> = {}) {
  const next = { ...setup, ...overrides };
  return {
    exercise_id: next.exercise_id,
    name: next.name,
    location: next.location ?? null,
    equipment_identifier: next.equipment_identifier ?? null,
    load_entry_mode: next.load_entry_mode ?? null,
    rep_count_mode: next.rep_count_mode ?? null,
    unilateral_mode: next.unilateral_mode ?? null,
    bar_weight_kg: next.bar_weight_kg ?? null,
    machine_base_load_kg: next.machine_base_load_kg ?? null,
    side_multiplier: next.side_multiplier ?? null,
    notes: next.notes ?? null,
    is_default: next.is_default ?? false,
    active: next.active ?? true,
  };
}

export function FitnessStrengthLibraryPanel({
  workspace,
  online,
  onDataChanged,
}: {
  workspace: FitnessStrengthWorkspace;
  online: boolean;
  onDataChanged: () => void;
}) {
  const save = useFitnessSave(onDataChanged);
  const batch = useFitnessBatchSave(onDataChanged);
  const [query, setQuery] = useState("");
  const [includeArchived, setIncludeArchived] = useState(false);
  const [selectedId, setSelectedId] = useState(workspace.exercises[0]?.id ?? "");
  const [showCreate, setShowCreate] = useState(false);
  const [form, setForm] = useState<ExerciseForm>(EMPTY_EXERCISE);
  const [setupName, setSetupName] = useState("");
  const [setupLocation, setSetupLocation] = useState("");
  const [setupLoadMode, setSetupLoadMode] = useState("");
  const [barWeight, setBarWeight] = useState("");
  const [sideMultiplier, setSideMultiplier] = useState("2");
  const [exerciseMergeTarget, setExerciseMergeTarget] = useState("");
  const [exerciseMerge, setExerciseMerge] = useState<FitnessExerciseMergePreview | null>(null);
  const [setupSource, setSetupSource] = useState("");
  const [setupTarget, setSetupTarget] = useState("");
  const [setupMerge, setSetupMerge] = useState<FitnessExerciseSetupMergePreview | null>(null);
  const [mergeBusy, setMergeBusy] = useState(false);
  const [mergeError, setMergeError] = useState<string | null>(null);

  const allExercises = useMemo(() => {
    const normalized = query.trim().toLocaleLowerCase();
    return [...workspace.exercises]
      .filter((item) => includeArchived || item.active !== false)
      .filter((item) => !normalized || [item.name, ...(item.aliases ?? []), item.movement_pattern_key, item.equipment_type].filter(Boolean).join(" ").toLocaleLowerCase().includes(normalized))
      .sort((left, right) => Number(Boolean(right.favourite)) - Number(Boolean(left.favourite)) || left.name.localeCompare(right.name));
  }, [includeArchived, query, workspace.exercises]);
  const selected = workspace.exercises.find((item) => item.id === selectedId) ?? allExercises[0] ?? null;
  const selectedSetups = workspace.setups.filter((item) => item.exercise_id === selected?.id);

  async function createExercise() {
    const exerciseId = crypto.randomUUID();
    const inputs: SaveFitnessRecordInput[] = [{ entityType: "exercise", options: { entityId: exerciseId }, payload: {
      seed_key: null,
      name: form.name.trim(),
      aliases: splitTerms(form.aliases),
      movement_pattern_key: form.movement,
      measurement_mode: form.measurement,
      rep_count_mode: form.repMode,
      load_entry_mode: form.loadMode,
      default_unit: "kg",
      unilateral_mode: form.repMode === "left_right_separate" ? "unilateral_separate_sets" : "bilateral",
      equipment_type: form.equipment.trim() || null,
      bodyweight_involved: form.bodyweight,
      progression_direction: form.loadMode === "assistance" ? "lower" : "higher",
      notes: null,
      favourite: form.favourite,
      active: true,
      muscle_roles: [
        ...splitTerms(form.primaryMuscles).map((key) => ({ muscle_group_key: key.toLowerCase().replaceAll(" ", "_"), role: "primary", contribution_weight: 1 })),
        ...splitTerms(form.secondaryMuscles).map((key) => ({ muscle_group_key: key.toLowerCase().replaceAll(" ", "_"), role: "secondary", contribution_weight: 0.5 })),
      ],
    } }];
    if (form.setupName.trim()) inputs.push({ entityType: "exercise_setup", payload: {
      exercise_id: exerciseId,
      name: form.setupName.trim(),
      location: null,
      equipment_identifier: null,
      load_entry_mode: form.loadMode,
      rep_count_mode: form.repMode,
      unilateral_mode: form.repMode === "left_right_separate" ? "unilateral_separate_sets" : "bilateral",
      bar_weight_kg: null,
      machine_base_load_kg: null,
      side_multiplier: form.loadMode === "per_side" ? 2 : null,
      notes: null,
      is_default: true,
      active: true,
    } });
    await batch.save(inputs);
    setSelectedId(exerciseId);
    setForm(EMPTY_EXERCISE);
    setShowCreate(false);
  }

  async function duplicateExercise(exercise: FitnessExercise) {
    const exerciseId = crypto.randomUUID();
    const inputs: SaveFitnessRecordInput[] = [{ entityType: "exercise", options: { entityId: exerciseId }, payload: exerciseSavePayload(exercise, { name: `${exercise.name} copy`, seed_key: null }) }];
    workspace.setups.filter((item) => item.exercise_id === exercise.id).forEach((setup) => inputs.push({
      entityType: "exercise_setup",
      payload: setupSavePayload(setup, { exercise_id: exerciseId }),
    }));
    await batch.save(inputs);
    setSelectedId(exerciseId);
  }

  async function addSetup() {
    if (!selected || !setupName.trim()) return;
    await save.save("exercise_setup", {
      exercise_id: selected.id,
      name: setupName.trim(),
      location: setupLocation.trim() || null,
      equipment_identifier: null,
      load_entry_mode: setupLoadMode || (selected.load_entry_mode ?? null),
      rep_count_mode: selected.rep_count_mode ?? null,
      unilateral_mode: selected.unilateral_mode ?? null,
      bar_weight_kg: barWeight ? Number(barWeight) : null,
      machine_base_load_kg: null,
      side_multiplier: sideMultiplier ? Number(sideMultiplier) : null,
      notes: null,
      is_default: selectedSetups.length === 0,
      active: true,
    });
    setSetupName("");
    setSetupLocation("");
    setBarWeight("");
  }

  async function previewExerciseMerge() {
    if (!selected || !exerciseMergeTarget || !online) return;
    setMergeBusy(true); setMergeError(null);
    try {
      setExerciseMerge(await api<FitnessExerciseMergePreview>("/fitness/exercises/merge/preview", {
        method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ source_id: selected.id, target_id: exerciseMergeTarget }),
      }, true, false));
    } catch (error) { setMergeError(errorMessage(error)); }
    finally { setMergeBusy(false); }
  }

  async function confirmExerciseMerge() {
    if (!exerciseMerge || !online) return;
    setMergeBusy(true); setMergeError(null);
    try {
      await api("/fitness/exercises/merge", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ source_id: exerciseMerge.source_id, target_id: exerciseMerge.target_id }) }, true, false);
      setSelectedId(exerciseMerge.target_id); setExerciseMerge(null); onDataChanged();
    } catch (error) { setMergeError(errorMessage(error)); }
    finally { setMergeBusy(false); }
  }

  async function previewSetupMerge() {
    if (!setupSource || !setupTarget || !online) return;
    setMergeBusy(true); setMergeError(null);
    try {
      setSetupMerge(await api<FitnessExerciseSetupMergePreview>("/fitness/exercise-setups/merge/preview", {
        method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ source_id: setupSource, target_id: setupTarget }),
      }, true, false));
    } catch (error) { setMergeError(errorMessage(error)); }
    finally { setMergeBusy(false); }
  }

  async function confirmSetupMerge() {
    if (!setupMerge || !online) return;
    setMergeBusy(true); setMergeError(null);
    try {
      await api("/fitness/exercise-setups/merge", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ source_id: setupMerge.source_id, target_id: setupMerge.target_id }) }, true, false);
      setSetupMerge(null); setSetupSource(""); setSetupTarget(""); onDataChanged();
    } catch (error) { setMergeError(errorMessage(error)); }
    finally { setMergeBusy(false); }
  }

  return (
    <div className="fitness-module__nutrition-split">
      <FitnessCard title="Exercise catalogue" detail="Favourites first, then aliases and movement patterns.">
        <div className="fitness-module__fields"><label className="fitness-module__field is-wide">Search<input type="search" placeholder="Name, alias, muscle or equipment" value={query} onChange={(event) => setQuery(event.target.value)} /></label></div>
        <label className="fitness-module__check"><input checked={includeArchived} type="checkbox" onChange={(event) => setIncludeArchived(event.target.checked)} /> Include archived exercises</label>
        <button className="button button--primary" type="button" onClick={() => setShowCreate(true)}><Plus size={16} /> New exercise</button>
        <ul className="fitness-module__catalogue-list">{allExercises.map((item) => <li key={item.id}><button className={selected?.id === item.id ? "is-active" : ""} type="button" onClick={() => { setSelectedId(item.id); setExerciseMerge(null); }}><span><strong>{item.favourite ? "★ " : ""}{item.name}</strong><small>{item.movement_pattern_key?.replaceAll("_", " ") ?? "other"} · {item.aliases?.join(", ") || "no aliases"}</small></span><span className={`fitness-module__pill ${item.active === false ? "is-warning" : "is-neutral"}`}>{item.active === false ? "Archived" : item.measurement_mode?.replaceAll("_", " ")}</span></button></li>)}</ul>
      </FitnessCard>

      <div className="fitness-module__nutrition-detail">
        {showCreate ? <FitnessCard title="Create exercise" detail="Identity and measurement semantics stay separate from gym-specific setups."><form className="fitness-module__form" onSubmit={submitForm(createExercise)}><div className="fitness-module__fields">
          <label className="fitness-module__field is-wide">Name<input autoFocus value={form.name} onChange={(event) => setForm((value) => ({ ...value, name: event.target.value }))} required /></label>
          <label className="fitness-module__field is-wide">Aliases, comma-separated<input value={form.aliases} onChange={(event) => setForm((value) => ({ ...value, aliases: event.target.value }))} /></label>
          <label className="fitness-module__field">Movement pattern<input placeholder="squat" value={form.movement} onChange={(event) => setForm((value) => ({ ...value, movement: event.target.value }))} /></label>
          <label className="fitness-module__field">Equipment<input placeholder="barbell" value={form.equipment} onChange={(event) => setForm((value) => ({ ...value, equipment: event.target.value }))} /></label>
          <label className="fitness-module__field">Measurement<select value={form.measurement} onChange={(event) => setForm((value) => ({ ...value, measurement: event.target.value }))}><option value="reps_load">Repetitions + load</option><option value="reps_only">Repetitions only</option><option value="duration">Duration</option><option value="duration_load">Duration + load</option><option value="distance">Distance</option><option value="distance_load">Distance + load</option><option value="custom">Custom metric</option></select></label>
          <label className="fitness-module__field">Repetition mode<select value={form.repMode} onChange={(event) => setForm((value) => ({ ...value, repMode: event.target.value }))}><option value="total">Total</option><option value="per_side">Per side</option><option value="left_right_separate">Left/right separately</option><option value="not_applicable">Not applicable</option></select></label>
          <label className="fitness-module__field">Load entry<select value={form.loadMode} onChange={(event) => setForm((value) => ({ ...value, loadMode: event.target.value }))}><option value="total_external">Total external</option><option value="per_hand">Per hand</option><option value="per_side">Per side</option><option value="machine_stack">Machine stack</option><option value="machine_level">Machine level</option><option value="added_bodyweight">Added bodyweight</option><option value="assistance">Assistance</option><option value="bodyweight_only">Bodyweight only</option><option value="none">No load</option></select></label>
          <label className="fitness-module__field">Default setup name<input value={form.setupName} onChange={(event) => setForm((value) => ({ ...value, setupName: event.target.value }))} /></label>
          <label className="fitness-module__field is-wide">Primary muscles, comma-separated<input placeholder="quadriceps, glutes" value={form.primaryMuscles} onChange={(event) => setForm((value) => ({ ...value, primaryMuscles: event.target.value }))} /></label>
          <label className="fitness-module__field is-wide">Secondary muscles, comma-separated<input value={form.secondaryMuscles} onChange={(event) => setForm((value) => ({ ...value, secondaryMuscles: event.target.value }))} /></label>
          <label className="fitness-module__check"><input checked={form.bodyweight} type="checkbox" onChange={(event) => setForm((value) => ({ ...value, bodyweight: event.target.checked }))} /> Bodyweight involved</label><label className="fitness-module__check"><input checked={form.favourite} type="checkbox" onChange={(event) => setForm((value) => ({ ...value, favourite: event.target.checked }))} /> Favourite</label>
        </div><div className="fitness-module__form-footer"><button className="button button--primary" disabled={batch.saving} type="submit">Create exercise</button><button className="button button--secondary" type="button" onClick={() => setShowCreate(false)}>Cancel</button><FitnessFormStatus saving={batch.saving} saved={batch.saved} error={batch.saveError} /></div></form></FitnessCard> : null}

        {selected ? <>
          <FitnessCard title={selected.name} detail={`${selected.measurement_mode?.replaceAll("_", " ")} · ${selected.muscle_roles?.map((item) => `${item.muscle_group_key.replaceAll("_", " ")} (${item.role})`).join(", ") || "No muscle roles"}`}>
            <div className="fitness-module__button-row"><button className="button button--secondary button--compact" type="button" onClick={() => void save.save("exercise", exerciseSavePayload(selected, { favourite: !selected.favourite }), { entityId: selected.id, baseRevision: selected.revision ?? null })}><Star size={15} /> {selected.favourite ? "Remove favourite" : "Favourite"}</button><button className="button button--secondary button--compact" type="button" onClick={() => void duplicateExercise(selected)}><Copy size={15} /> Duplicate</button><button className="button button--secondary button--compact" type="button" onClick={() => void save.save("exercise", exerciseSavePayload(selected, { active: selected.active === false }), { entityId: selected.id, baseRevision: selected.revision ?? null })}><Archive size={15} /> {selected.active === false ? "Restore" : "Archive"}</button></div>
          </FitnessCard>

          <FitnessCard title="Setups" detail="Labels match how the equipment is actually loaded.">
            {selectedSetups.length ? <ul className="fitness-module__list">{selectedSetups.map((item) => <li key={item.id}><div><strong>{item.name}{item.is_default ? " · default" : ""}</strong><small>{item.location ?? "Any location"} · {strengthSetupLoadLabel(item, selected)}{item.bar_weight_kg != null ? ` · ${item.bar_weight_kg} kg bar` : ""}</small></div></li>)}</ul> : <div className="fitness-module__empty">No named setup yet.</div>}
            <form className="fitness-module__form" onSubmit={submitForm(addSetup)}><div className="fitness-module__fields"><label className="fitness-module__field">Setup name<input value={setupName} onChange={(event) => setSetupName(event.target.value)} required /></label><label className="fitness-module__field">Location<input value={setupLocation} onChange={(event) => setSetupLocation(event.target.value)} /></label><label className="fitness-module__field">Load mode<select value={setupLoadMode} onChange={(event) => setSetupLoadMode(event.target.value)}><option value="">Use exercise default</option><option value="total_external">kg total</option><option value="per_hand">kg each</option><option value="per_side">kg per side</option><option value="machine_stack">stack kg</option><option value="machine_level">machine level</option><option value="added_bodyweight">added kg</option><option value="assistance">assistance kg</option><option value="bodyweight_only">bodyweight only</option><option value="none">no load</option></select></label><label className="fitness-module__field">Bar weight (kg)<input min="0" step="any" type="number" value={barWeight} onChange={(event) => setBarWeight(event.target.value)} /></label>{setupLoadMode === "per_side" ? <label className="fitness-module__field">Side multiplier<input min="1" step="any" type="number" value={sideMultiplier} onChange={(event) => setSideMultiplier(event.target.value)} /></label> : null}</div><div className="fitness-module__form-footer"><button className="button button--secondary" type="submit"><Plus size={15} /> Add setup</button></div></form>
          </FitnessCard>

          <FitnessCard title="Merge duplicate exercises" detail="Preview every affected workout before choosing the exercise to keep.">
            <div className="fitness-module__fields"><label className="fitness-module__field is-wide">Keep this exercise<select value={exerciseMergeTarget} onChange={(event) => { setExerciseMergeTarget(event.target.value); setExerciseMerge(null); }}><option value="">Choose target…</option>{workspace.exercises.filter((item) => item.id !== selected.id).map((item) => <option key={item.id} value={item.id}>{item.name}</option>)}</select></label></div>
            <button className="button button--secondary" disabled={!online || !exerciseMergeTarget || mergeBusy} type="button" onClick={() => void previewExerciseMerge()}><GitMerge size={16} /> Preview merge</button>{!online ? <p className="fitness-module__muted">Reconnect before merging so every existing workout can follow the exercise you keep.</p> : null}
            {exerciseMerge ? <div className="fitness-module__merge-preview"><strong>{exerciseMerge.already_merged ? "Already merged" : "Affected references"}</strong><ul><li>{exerciseMerge.planned_exercises} planned exercises</li><li>{exerciseMerge.session_exercises} logged exercises</li><li>{exerciseMerge.moved_setups} setups move to the target</li></ul><div className="fitness-module__button-row"><button className="button button--danger" disabled={exerciseMerge.already_merged || mergeBusy} type="button" onClick={() => void confirmExerciseMerge()}>Confirm exercise merge</button><button className="button button--secondary" type="button" onClick={() => setExerciseMerge(null)}>Cancel</button></div></div> : null}
          </FitnessCard>

          {selectedSetups.length > 1 ? <FitnessCard title="Merge duplicate setups" detail="Old workouts keep their original meaning and follow the setup you choose."><div className="fitness-module__fields"><label className="fitness-module__field">Source setup<select value={setupSource} onChange={(event) => { setSetupSource(event.target.value); setSetupMerge(null); }}><option value="">Choose…</option>{selectedSetups.map((item) => <option key={item.id} value={item.id}>{item.name}</option>)}</select></label><label className="fitness-module__field">Setup to keep<select value={setupTarget} onChange={(event) => { setSetupTarget(event.target.value); setSetupMerge(null); }}><option value="">Choose…</option>{selectedSetups.filter((item) => item.id !== setupSource).map((item) => <option key={item.id} value={item.id}>{item.name}</option>)}</select></label></div><button className="button button--secondary" disabled={!online || !setupSource || !setupTarget || mergeBusy} type="button" onClick={() => void previewSetupMerge()}>Preview setup merge</button>{setupMerge ? <div className="fitness-module__merge-preview"><strong>Affected references</strong><ul><li>{setupMerge.planned_exercises} planned exercises</li><li>{setupMerge.session_exercises} logged exercises</li></ul><div className="fitness-module__button-row"><button className="button button--danger" disabled={setupMerge.already_merged || mergeBusy} type="button" onClick={() => void confirmSetupMerge()}>Confirm setup merge</button><button className="button button--secondary" type="button" onClick={() => setSetupMerge(null)}>Cancel</button></div></div> : null}</FitnessCard> : null}
          {mergeError ? <div className="fitness-module__notice fitness-module__notice--error" role="alert">{mergeError}</div> : null}
          <FitnessFormStatus saving={save.saving || batch.saving} saved={save.saved || batch.saved} error={save.saveError || batch.saveError} />
        </> : <FitnessCard><div className="fitness-module__empty">Create or select an exercise to manage its setups.</div></FitnessCard>}
      </div>
    </div>
  );
}
