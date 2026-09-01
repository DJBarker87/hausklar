import type { FitnessRunWorkoutStep } from "./contract";

export type FitnessRunPlanTotals = {
  distanceM: number;
  durationS: number;
  hasOpenDuration: boolean;
};

export type FitnessRunPlanValidation = {
  errors: string[];
  warnings: string[];
  totals: FitnessRunPlanTotals;
};

function multipliedTotals(totals: FitnessRunPlanTotals, multiplier: number): FitnessRunPlanTotals {
  return {
    distanceM: totals.distanceM * multiplier,
    durationS: totals.durationS * multiplier,
    hasOpenDuration: totals.hasOpenDuration,
  };
}

export function fitnessRunPlanTotals(steps: FitnessRunWorkoutStep[]): FitnessRunPlanTotals {
  return steps.reduce<FitnessRunPlanTotals>((total, step) => {
    let current: FitnessRunPlanTotals;
    if (step.step_kind === "repeat_block") {
      current = multipliedTotals(fitnessRunPlanTotals(step.children ?? []), step.repeat_count ?? 0);
    } else {
      current = {
        distanceM: step.duration_type === "distance_m" ? step.duration_value ?? 0 : 0,
        durationS: step.duration_type === "time_s" ? step.duration_value ?? 0 : 0,
        hasOpenDuration: step.duration_type === "open" || step.duration_type === "lap_button",
      };
    }
    return {
      distanceM: total.distanceM + current.distanceM,
      durationS: total.durationS + current.durationS,
      hasOpenDuration: total.hasOpenDuration || current.hasOpenDuration,
    };
  }, { distanceM: 0, durationS: 0, hasOpenDuration: false });
}

export function flattenFitnessRunSteps(steps: FitnessRunWorkoutStep[]): FitnessRunWorkoutStep[] {
  return steps.flatMap((step) => [step, ...flattenFitnessRunSteps(step.children ?? [])]);
}

export function validateFitnessRunPlan(
  steps: FitnessRunWorkoutStep[],
  options: { cuesRequested?: boolean; planningContextReviewed?: boolean } = {},
): FitnessRunPlanValidation {
  const errors: string[] = [];
  const warnings: string[] = [];
  const allSteps = flattenFitnessRunSteps(steps);
  if (!steps.length) errors.push("Add at least one workout step.");
  for (const step of allSteps) {
    if (!step.display_name.trim()) errors.push("Every workout step needs a name.");
    if (step.step_kind === "repeat_block") {
      if (!Number.isInteger(step.repeat_count) || (step.repeat_count ?? 0) < 1) {
        errors.push(`${step.display_name || "Repeat block"} needs a finite repeat count.`);
      }
      if (!step.children?.length) errors.push(`${step.display_name || "Repeat block"} needs at least one child step.`);
      continue;
    }
    if (["distance_m", "time_s", "calories"].includes(step.duration_type) && !(Number(step.duration_value) > 0)) {
      errors.push(`${step.display_name || "Step"} needs a positive duration value.`);
    }
    if (step.target_type !== "none") {
      if (step.target_low == null || step.target_high == null) {
        errors.push(`${step.display_name || "Step"} needs both ends of its target range.`);
      } else if (step.target_low > step.target_high) {
        errors.push(`${step.display_name || "Step"} has its target range in the wrong order.`);
      }
      if (step.target_type === "pace_s_per_km" && step.target_unit !== "s/km") {
        errors.push(`${step.display_name || "Step"} must store pace targets in s/km.`);
      }
    }
    if (options.cuesRequested && !step.mental_cue_text?.trim()) {
      errors.push(`${step.display_name || "Step"} needs the requested mental cue.`);
    }
    if (step.mental_cue_text || step.spoken_cue_text) {
      warnings.push(`${step.display_name}: Garmin FIT may omit or shorten custom cue text.`);
    }
  }
  const kilometreNumbers = allSteps
    .filter((step) => step.step_kind === "step")
    .map((step) => step.kilometre_index ?? Number(step.display_name.match(/^kilometre\s+(\d+)$/i)?.[1] ?? Number.NaN))
    .filter(Number.isFinite);
  if (kilometreNumbers.length) {
    const unique = new Set(kilometreNumbers);
    const largest = Math.max(...kilometreNumbers);
    if (unique.size !== kilometreNumbers.length || largest !== kilometreNumbers.length) {
      errors.push("Kilometre steps must run from 1 without gaps or duplicates.");
    }
  }
  if (!options.planningContextReviewed) {
    errors.push("Review recent running and active body issues before accepting this plan.");
  }
  return { errors: [...new Set(errors)], warnings: [...new Set(warnings)], totals: fitnessRunPlanTotals(steps) };
}

export function paceTextFromSeconds(seconds: number | null | undefined): string {
  if (seconds == null || !Number.isFinite(seconds)) return "—";
  const minutes = Math.floor(seconds / 60);
  return `${minutes}:${String(Math.round(seconds - minutes * 60)).padStart(2, "0")}/km`;
}

export function secondsFromPaceText(value: string): number | null {
  const match = value.trim().match(/^(\d{1,2}):(\d{2})$/);
  if (!match) return null;
  const seconds = Number(match[1]) * 60 + Number(match[2]);
  return Number(match[2]) < 60 && seconds > 0 ? seconds : null;
}
