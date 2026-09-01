import { Activity, Dumbbell, TrendingUp } from "lucide-react";
import { useMemo, useState } from "react";

import type {
  FitnessStrengthComparisonKey,
  FitnessStrengthExerciseProgress,
  FitnessStrengthMuscleSummary,
  FitnessStrengthObservedSet,
  FitnessStrengthSuggestion,
  FitnessStrengthSuggestionsResponse,
} from "../../fitness/contract";
import { strengthProgressionSuggestion, strengthSetupLoadLabel } from "../../fitness/strengthWorkout";
import { isPerformedStrengthComponent } from "../../fitness/strengthSemantics";
import type { FitnessStrengthWorkspace } from "./FitnessStrengthView";
import {
  FitnessCard,
  FitnessLoadingOrError,
  FitnessStat,
  formatFitnessDateTime,
  useFitnessEndpoint,
} from "./shared";

type Range = "4" | "8" | "12" | "all";
type Comparison = "recent" | "same_load" | "same_reps" | "effort";

function repetitions(set: FitnessStrengthObservedSet): number | null {
  if (set.reps != null) return set.reps;
  const sides = [set.reps_left, set.reps_right].filter((value): value is number => value != null);
  if (sides.length) return Math.min(...sides);
  return null;
}

function observedSetLabel(set?: FitnessStrengthObservedSet | null): string {
  if (!set) return "No record";
  const reps = set.reps_left != null || set.reps_right != null
    ? `${set.reps_left ?? "?"}/${set.reps_right ?? "?"}`
    : set.reps ?? (set.duration_s != null ? `${set.duration_s}s` : set.distance_m != null ? `${set.distance_m}m` : "work");
  const load = set.normalized_external_load_kg ?? set.load_value;
  return `${load == null ? "No external load" : `${load} kg`} × ${reps}`;
}

function withinRange(value: string, range: Range): boolean {
  if (range === "all") return true;
  return Date.parse(value) >= Date.now() - Number(range) * 7 * 86_400_000;
}

function inDateWindow(value: string, start?: string | null, end?: string | null): boolean {
  const day = value.slice(0, 10);
  return (!start || day >= start) && (!end || day <= end);
}

function progressionActionLabel(action: FitnessStrengthSuggestion["progression"]["action"]): string {
  if (action === "increase_load") return "Increase load candidate";
  if (action === "hold_load") return "Hold load";
  if (action === "hold_or_reduce") return "Hold or reduce";
  return "More context needed";
}

function candidateEvidenceLabel(evidence: FitnessStrengthSuggestion["recent_evidence"][number]): string {
  const component = evidence.components[0];
  const repetitions = component?.reps ?? (component?.reps_left != null || component?.reps_right != null ? `${component.reps_left ?? "?"}/${component.reps_right ?? "?"}` : "work");
  const load = component?.load_kg == null ? "no external load" : `${component.load_kg} kg`;
  const effort = component?.rir != null ? `RIR ${component.rir}` : component?.rpe != null ? `RPE ${component.rpe}` : "effort unknown";
  return `${evidence.activity_title} · ${formatFitnessDateTime(evidence.performed_at)} · ${evidence.source_setup_label} · ${load} × ${repetitions} · ${effort}`;
}

function comparisonKeyId(key: FitnessStrengthComparisonKey): string {
  return JSON.stringify([key.exercise_id, key.setup_id, key.load_entry_mode, key.rep_count_mode, key.unilateral_mode]);
}

function scopedStrengthRecords(observed: FitnessStrengthObservedSet[]) {
  const loaded = observed.filter((item) => item.normalized_external_load_kg != null && (repetitions(item) ?? 0) > 0);
  const heaviest = loaded.reduce<FitnessStrengthObservedSet | null>((best, item) => !best || (item.normalized_external_load_kg ?? 0) > (best.normalized_external_load_kg ?? 0) ? item : best, null);
  const bestByRepBand: Record<string, FitnessStrengthObservedSet | null> = {};
  for (const [label, lower, upper] of [["1-3", 1, 3], ["4-6", 4, 6], ["7-10", 7, 10], ["11-15", 11, 15]] as const) {
    bestByRepBand[label] = loaded.filter((item) => {
      const count = repetitions(item) ?? 0;
      return count >= lower && count <= upper;
    }).reduce<FitnessStrengthObservedSet | null>((best, item) => !best || (item.normalized_external_load_kg ?? 0) > (best.normalized_external_load_kg ?? 0) ? item : best, null);
  }
  return { heaviest, best_by_rep_band: bestByRepBand };
}

function ExerciseProgress({
  exerciseId,
  revision,
  range,
  workspace,
  serverSuggestion,
  serverContext,
  suggestionServiceAvailable,
}: {
  exerciseId: string;
  revision: number;
  range: Range;
  workspace: FitnessStrengthWorkspace;
  serverSuggestion: FitnessStrengthSuggestion | null;
  serverContext: FitnessStrengthSuggestionsResponse | null;
  suggestionServiceAvailable: boolean;
}) {
  const [comparison, setComparison] = useState<Comparison>("recent");
  const [comparisonKey, setComparisonKey] = useState("");
  const resource = useFitnessEndpoint<FitnessStrengthExerciseProgress | null>(`/fitness/strength/exercises/${encodeURIComponent(exerciseId)}/progress`, null, revision);
  const data = resource.data;
  const comparisonOptions = useMemo(() => {
    const unique = new Map<string, { id: string; key: FitnessStrengthComparisonKey; label: string }>();
    [...(data?.observed_sets ?? [])].sort((left, right) => right.started_at_utc.localeCompare(left.started_at_utc)).forEach((item) => {
      if (!item.comparison_key) return;
      const id = comparisonKeyId(item.comparison_key);
      if (unique.has(id)) return;
      const setupLabel = item.source_setup_label ?? "Archived or unnamed setup";
      unique.set(id, { id, key: item.comparison_key, label: `${setupLabel} · ${item.comparison_key.load_entry_mode.replaceAll("_", " ")} · ${item.comparison_key.rep_count_mode.replaceAll("_", " ")} reps · ${item.comparison_key.unilateral_mode.replaceAll("_", " ")}` });
    });
    return [...unique.values()];
  }, [data?.observed_sets]);
  const selectedComparison = comparisonOptions.find((item) => item.id === comparisonKey) ?? comparisonOptions[0] ?? null;
  const observed = useMemo(() => (data?.observed_sets ?? [])
    .filter((item) => !selectedComparison || comparisonKeyId(item.comparison_key) === selectedComparison.id)
    .filter((item) => withinRange(item.started_at_utc, range))
    .sort((left, right) => right.started_at_utc.localeCompare(left.started_at_utc)), [data?.observed_sets, range, selectedComparison]);
  const groups = useMemo(() => (data?.logical_set_groups ?? []).filter((item) => {
    const started = (item as typeof item & { started_at_utc?: string }).started_at_utc;
    return (!selectedComparison || (item.comparison_key && comparisonKeyId(item.comparison_key) === selectedComparison.id)) && (!started || withinRange(started, range));
  }), [data?.logical_set_groups, range, selectedComparison]);
  const estimates = useMemo(() => (data?.estimated_1rm ?? []).filter((item) => (!selectedComparison || comparisonKeyId(item.source_set.comparison_key) === selectedComparison.id) && withinRange(item.source_set.started_at_utc, range)), [data?.estimated_1rm, range, selectedComparison]);
  const records = useMemo(() => scopedStrengthRecords(observed), [observed]);
  const anchor = observed[0] ?? null;
  const activeSession = anchor ? workspace.sessions.find((item) => item.id === anchor.activity_id) ?? null : null;
  const plan = activeSession?.planned_session_id ? workspace.plans.find((item) => item.id === activeSession.planned_session_id) ?? null : null;
  const planItem = plan?.exercise_items?.find((item) => item.exercise_id === exerciseId && (!selectedComparison || !item.exercise_setup_id || item.exercise_setup_id === selectedComparison.key.setup_id)) ?? null;
  const scopedData = data ? { ...data, observed_sets: observed, logical_set_groups: groups, estimated_1rm: estimates, records } : null;
  const localSuggestion = strengthProgressionSuggestion(scopedData, planItem);
  const contextualSuggestion = serverSuggestion && (!selectedComparison || serverSuggestion.exercise_setup_id === selectedComparison.key.setup_id) ? serverSuggestion : null;
  const maximumEstimate = estimates.length ? Math.max(...estimates.map((item) => item.estimated_1rm_kg)) : null;
  const activePhase = anchor ? workspace.phases.find((phase) => inDateWindow(anchor.started_at_utc, phase.starts_on, phase.ends_on)) ?? null : null;
  const actualGroups = activeSession ? groups.filter((group) => group.activity_id === activeSession.id && (group.summary?.working_sets ?? 0) > 0) : [];
  const comparisonSets = useMemo(() => {
    if (!anchor || comparison === "recent") return observed;
    if (comparison === "same_load") {
      const load = anchor.normalized_external_load_kg;
      return load == null ? [] : observed.filter((item) => item.normalized_external_load_kg != null && Math.abs(item.normalized_external_load_kg - load) < 0.01);
    }
    if (comparison === "same_reps") {
      const reps = repetitions(anchor);
      return reps == null ? [] : observed.filter((item) => repetitions(item) === reps);
    }
    const anchorEffort = anchor.rir ?? (anchor.rpe != null ? 10 - anchor.rpe : null);
    return anchorEffort == null ? [] : observed.filter((item) => {
      const effort = item.rir ?? (item.rpe != null ? 10 - item.rpe : null);
      return effort != null && Math.abs(effort - anchorEffort) <= 1;
    });
  }, [anchor, comparison, observed]);

  return <>
    <FitnessLoadingOrError loading={resource.loading} error={resource.error} retry={resource.reload} />
    {!resource.loading && !resource.error && data ? <>
      {data.redirect ? <div className="fitness-module__notice">This exercise was merged with another entry; all historical sets are included.</div> : null}
      {comparisonOptions.length ? <FitnessCard title="Comparable setup" detail="Records and comparisons use one exact setup, load mode, repetition mode and unilateral mode at a time."><label className="fitness-module__field is-wide">Setup and comparison key<select aria-label="Strength setup comparison" value={selectedComparison?.id ?? ""} onChange={(event) => setComparisonKey(event.target.value)}>{comparisonOptions.map((item) => <option key={item.id} value={item.id}>{item.label}</option>)}</select></label></FitnessCard> : null}
      <div className="fitness-module__stats">
        <FitnessStat label="Observed sets" value={observed.length} detail={`${range === "all" ? "All history" : `${range} weeks`} · working/back-off/test`} />
        <FitnessStat label="Logical groups" value={groups.length} detail="Compound components counted together" />
        <FitnessStat label="Heaviest" value={observedSetLabel(records.heaviest)} />
        <FitnessStat label="Best eligible e1RM" value={maximumEstimate == null ? "Not enough evidence" : `${maximumEstimate.toFixed(1)} kg`} />
      </div>

      {contextualSuggestion ? <FitnessCard title={`${contextualSuggestion.exercise_name}: ${progressionActionLabel(contextualSuggestion.progression.action)}`} detail="Guidance based on the planned session, comparable sets, and available training context.">
        <p>{contextualSuggestion.progression.reason}</p>
        <ul className="fitness-module__evidence-list">
          {contextualSuggestion.reasons.map((reason, index) => <li key={`reason-${index}`}>{reason}</li>)}
          {contextualSuggestion.recent_evidence.slice(0, 3).map((evidence) => <li key={evidence.group_id}>{candidateEvidenceLabel(evidence)}</li>)}
          <li>{serverContext?.planned_session ? `Plan: ${serverContext.planned_session.title} (${serverContext.planned_session.status}), with ${contextualSuggestion.estimated_minutes} minutes estimated for this exercise.` : "No planned Strength session was available; this candidate came from the private exercise library."}</li>
          <li>{serverContext?.recent_running_load.session_count ? `Running load over ${serverContext.recent_running_load.window_days} days: ${serverContext.recent_running_load.session_count} session(s), ${(serverContext.recent_running_load.distance_m / 1000).toFixed(1)} km and ${Math.round(serverContext.recent_running_load.duration_s / 60)} minutes.` : `No completed running session was found in the last ${serverContext?.recent_running_load.window_days ?? 7} days.`}</li>
          <li>{contextualSuggestion.active_body_issues.length ? `Active body issues: ${contextualSuggestion.active_body_issues.map((item) => `${item.body_location_key.replaceAll("_", " ")} ${item.side ?? ""} (${item.severity_0_10}/10)`).join(", ")}.` : "No active structured body issue is recorded."}</li>
        </ul>
        {!contextualSuggestion.included_in_time_budget ? <div className="fitness-module__notice">This exercise falls outside the supplied time budget and is not included in the session candidate.</div> : null}
        {[...new Set([...(serverContext?.missing_context ?? []), ...contextualSuggestion.progression.missing_context])].length ? <p className="fitness-module__muted">Missing context: {[...new Set([...(serverContext?.missing_context ?? []), ...contextualSuggestion.progression.missing_context])].join(", ")}.</p> : null}
      </FitnessCard> : localSuggestion ? <FitnessCard title={localSuggestion.title} detail="Recorded-set fallback; cross-domain server context is unavailable for this exercise."><p>{localSuggestion.reason}</p><ul className="fitness-module__evidence-list">
        <li>{anchor ? `Most recent evidence: ${observedSetLabel(anchor)} on ${formatFitnessDateTime(anchor.started_at_utc)} at ${anchor.rir != null ? `RIR ${anchor.rir}` : anchor.rpe != null ? `RPE ${anchor.rpe}` : "unknown effort"}.` : "No recent performed set is available."}</li>
        <li>{workspace.bodyIssues.length ? `Active body issue context: ${workspace.bodyIssues.map((item) => `${item.body_location_key.replaceAll("_", " ")} ${item.side ?? ""} (${item.severity_0_10}/10)`).join(", ")}; progression should be reviewed.` : "No active body issue is recorded."}</li>
        <li>{plan ? `Plan context: ${plan.title}, ${plan.expected_duration_s ? `${Math.round(plan.expected_duration_s / 60)} minutes` : "no time cap"}.` : "No linked plan or time constraint is available for the latest session."}</li>
        <li>{activePhase ? `Training phase: ${activePhase.name}.` : "No phase context overlaps the latest recorded set."}</li>
        <li>Running-load context is unavailable to this fallback, so it does not claim to account for it.</li>
      </ul>{!suggestionServiceAvailable ? <p className="fitness-module__muted">Cross-domain suggestion service unavailable; using local recorded sets.</p> : null}</FitnessCard> : null}

      <FitnessCard title="Plan versus actual" detail="The latest session keeps planned logical sets linked to what was performed.">
        {planItem && activeSession ? <div className="fitness-module__stats"><FitnessStat label="Planned logical sets" value={planItem.planned_sets.length} detail={planItem.planned_sets.map((item) => item.training_role).join(", ")} /><FitnessStat label="Performed logical sets" value={actualGroups.length} detail={activeSession.title} /><FitnessStat label="Bodyweight context" value={anchor?.bodyweight_kg_snapshot == null ? "Not recorded" : `${anchor.bodyweight_kg_snapshot} kg`} /><FitnessStat label="Phase" value={activePhase?.name ?? "No matching phase"} /></div> : <div className="fitness-module__empty">The latest comparable set is not linked to a planned strength exercise. Actual performance remains visible without inventing a target.</div>}
      </FitnessCard>

      <div className="fitness-module__grid">
        <FitnessCard title="Observed performance" detail="Compare real load, repetitions and effort without collapsing them into one score.">
          <div className="fitness-module__segmented" role="group" aria-label="Performance comparison">
            {(["recent", "same_load", "same_reps", "effort"] as const).map((item) => <button className={comparison === item ? "is-active" : ""} key={item} type="button" onClick={() => setComparison(item)}>{item === "recent" ? "Recent" : item === "same_load" ? "Same load: reps" : item === "same_reps" ? "Same reps: load" : "Comparable effort"}</button>)}
          </div>
          {comparisonSets.length ? <ul className="fitness-module__list">{comparisonSets.slice(0, 20).map((item) => {
            const setup = workspace.setups.find((candidate) => candidate.id === item.setup_id);
            const sourceSetupLabel = item.source_setup_label ?? setup?.name ?? "Archived or unnamed setup";
            const sourceMode = item.comparison_key?.load_entry_mode ?? item.load_entry_mode_snapshot;
            return <li key={item.id}><div><strong>{observedSetLabel(item)}</strong><small>{formatFitnessDateTime(item.started_at_utc)} · {sourceSetupLabel} ({sourceMode ? strengthSetupLoadLabel({ load_entry_mode: sourceMode } as never, data.exercise) : strengthSetupLoadLabel(setup, data.exercise)}) · {item.training_role} · {item.structure_type.replaceAll("_", " ")}{item.rir != null ? ` · RIR ${item.rir}` : item.rpe != null ? ` · RPE ${item.rpe}` : " · effort unknown"}</small></div></li>;
          })}</ul> : <div className="fitness-module__empty">No observed sets match this comparison. The view will not mix incomparable setups or fabricate a trend.</div>}
        </FitnessCard>
        <FitnessCard title="Record bands" detail="Best normalized external load within each repetition band.">
          <ul className="fitness-module__list">{Object.entries(records.best_by_rep_band).map(([band, item]) => <li key={band}><div><strong>{band} reps</strong><small>{observedSetLabel(item)}</small></div></li>)}</ul>
          <details className="fitness-module__details"><summary>Estimated one-rep-max details</summary>{estimates.length ? <ul className="fitness-module__list">{estimates.sort((left, right) => right.source_set.started_at_utc.localeCompare(left.source_set.started_at_utc)).map((item) => <li key={`${item.source_set.activity_id}-${item.source_set.id}`}><div><strong>{item.estimated_1rm_kg.toFixed(1)} kg</strong><small>From {observedSetLabel(item.source_set)} · {formatFitnessDateTime(item.source_set.started_at_utc)}</small></div></li>)}</ul> : <p className="fitness-module__muted">Only straight, performed, near-hard sets with comparable external load and at most ten effective repetitions qualify.</p>}</details>
        </FitnessCard>
      </div>
    </> : null}
  </>;
}

type MusclePeriodRow = {
  key: string;
  planned: number;
  completed: number;
  indirect: number;
  hard: number;
  unknown: number;
  dates: Set<string>;
  contributors: Set<string>;
  last: string | null;
};

export function FitnessStrengthProgressPanel({ workspace, revision }: { workspace: FitnessStrengthWorkspace; revision: number }) {
  const [selectedId, setSelectedId] = useState(workspace.exercises[0]?.id ?? "");
  const [range, setRange] = useState<Range>("8");
  const [phaseId, setPhaseId] = useState("");
  const muscles = useFitnessEndpoint<FitnessStrengthMuscleSummary[]>("/fitness/strength/muscle-groups", [], revision);
  const suggestions = useFitnessEndpoint<FitnessStrengthSuggestionsResponse | null>("/fitness/strength/suggestions", null, revision);
  const selectedExerciseId = workspace.exercises.some((item) => item.id === selectedId) ? selectedId : workspace.exercises[0]?.id ?? "";
  const selectedPhase = workspace.phases.find((item) => item.id === phaseId) ?? null;
  const periodStart = selectedPhase?.starts_on ?? (range === "all" ? null : new Date(Date.now() - Number(range) * 7 * 86_400_000).toISOString().slice(0, 10));
  const periodEnd = selectedPhase?.ends_on ?? null;
  const selectedSuggestion = suggestions.data?.exercise_candidates.find((item) => item.exercise_id === selectedExerciseId) ?? null;

  const muscleRows = useMemo(() => {
    const values = new Map<string, MusclePeriodRow>();
    const row = (key: string) => {
      if (!values.has(key)) values.set(key, { key, planned: 0, completed: 0, indirect: 0, hard: 0, unknown: 0, dates: new Set(), contributors: new Set(), last: null });
      return values.get(key)!;
    };
    muscles.data.forEach((item) => row(item.muscle_group_key));
    workspace.plans.filter((plan) => ["proposed", "accepted", "scheduled", "in_progress"].includes(plan.status) && inDateWindow(plan.scheduled_start_utc ?? plan.scheduled_date ?? "", periodStart, periodEnd)).forEach((plan) => {
      plan.exercise_items?.forEach((item) => {
        const exercise = workspace.exercises.find((candidate) => candidate.id === item.exercise_id);
        const count = item.planned_sets.filter((set) => ["working", "backoff", "test"].includes(set.training_role)).length;
        exercise?.muscle_roles?.forEach((role) => {
          if (role.role === "primary") row(role.muscle_group_key).planned += count;
          else row(role.muscle_group_key).planned += count * (role.contribution_weight ?? 0.5);
        });
      });
    });
    workspace.sessions.filter((session) => ["completed", "partial"].includes(session.status) && inDateWindow(session.started_at_utc, periodStart, periodEnd)).forEach((session) => {
      session.exercises?.forEach((sessionExercise) => {
        const exercise = workspace.exercises.find((candidate) => candidate.id === sessionExercise.exercise_id);
        sessionExercise.set_groups?.filter((group) => ["working", "backoff", "test"].includes(group.training_role)).forEach((group) => {
          const components = group.components ?? [];
          if (!components.some(isPerformedStrengthComponent)) return;
          const effortKnown = ["technical", "muscular"].includes(group.failure_state ?? "") || components.some((component) => component.rir != null || component.rpe != null);
          const hard = ["technical", "muscular"].includes(group.failure_state ?? "") || components.some((component) => (component.rir != null && component.rir <= 3) || (component.rpe != null && component.rpe >= 7));
          exercise?.muscle_roles?.forEach((role) => {
            const target = row(role.muscle_group_key);
            if (role.role === "primary") {
              target.completed += 1;
              if (hard) target.hard += 1;
              else if (!effortKnown) target.unknown += 1;
            } else target.indirect += role.contribution_weight ?? 0.5;
            target.dates.add(session.started_at_utc.slice(0, 10));
            target.contributors.add(sessionExercise.exercise_id);
            if (!target.last || session.started_at_utc > target.last) target.last = session.started_at_utc;
          });
        });
      });
    });
    return [...values.values()].sort((left, right) => left.key.localeCompare(right.key));
  }, [muscles.data, periodEnd, periodStart, workspace.exercises, workspace.plans, workspace.sessions]);

  return <div className="fitness-module__strength-progress">
    <FitnessCard title="Exercise progress" detail="Review observed sets, records and bounded progression evidence.">
      <div className="fitness-module__fields"><label className="fitness-module__field">Exercise<select value={selectedExerciseId} onChange={(event) => setSelectedId(event.target.value)}><option value="">Choose an exercise…</option>{workspace.exercises.map((item) => <option key={item.id} value={item.id}>{item.name}</option>)}</select></label><label className="fitness-module__field">Training phase<select value={phaseId} onChange={(event) => setPhaseId(event.target.value)}><option value="">No phase filter</option>{workspace.phases.map((item) => <option key={item.id} value={item.id}>{item.name}</option>)}</select></label></div>
      <div className="fitness-module__segmented" role="group" aria-label="Progress timeframe">{(["4", "8", "12", "all"] as const).map((item) => <button className={range === item && !phaseId ? "is-active" : ""} key={item} type="button" onClick={() => { setRange(item); setPhaseId(""); }}>{item === "all" ? "All time" : `${item} weeks`}</button>)}</div>
    </FitnessCard>
    {selectedExerciseId ? <ExerciseProgress exerciseId={selectedExerciseId} revision={revision} range={phaseId ? "all" : range} workspace={workspace} serverSuggestion={selectedSuggestion} serverContext={suggestions.data} suggestionServiceAvailable={Boolean(suggestions.data) && !suggestions.error} /> : <div className="fitness-module__empty">Create an exercise and complete a workout to see progress.</div>}

    <FitnessCard title="Muscle view" detail={`Planned and completed work are separate for ${selectedPhase ? selectedPhase.name : range === "all" ? "all history" : `the last ${range} weeks`}.`}>
      <FitnessLoadingOrError loading={muscles.loading} error={muscles.error} retry={muscles.reload} />
      {!muscles.loading && !muscles.error && muscleRows.length ? <div className="fitness-module__muscle-grid">{muscleRows.map((muscle) => {
        const contributors = [...muscle.contributors].map((id) => workspace.exercises.find((item) => item.id === id)?.name ?? "Archived exercise");
        const daysAgo = muscle.last ? Math.max(0, Math.floor((Date.now() - Date.parse(muscle.last)) / 86_400_000)) : null;
        return <article key={muscle.key}><header><div><Activity size={17} aria-hidden="true" /><strong>{muscle.key.replaceAll("_", " ")}</strong></div><span className={`fitness-module__pill ${daysAgo == null || daysAgo > 7 ? "is-warning" : "is-neutral"}`}>{daysAgo == null ? "No completed work" : `${daysAgo}d ago`}</span></header><div className="fitness-module__muscle-stats"><span><Dumbbell size={14} /> {muscle.completed} completed direct</span><span>{muscle.planned.toFixed(1)} planned equivalents</span><span>{muscle.indirect.toFixed(1)} completed indirect</span><span><TrendingUp size={14} /> {muscle.hard} hard · {muscle.unknown} unknown</span><span>{muscle.dates.size} training days</span></div><small>Contributors: {contributors.join(", ") || "None in this period"}</small></article>;
      })}</div> : !muscles.loading && !muscles.error ? <div className="fitness-module__empty">Muscle summaries appear after completed strength work with exercise muscle roles.</div> : null}
    </FitnessCard>
  </div>;
}
