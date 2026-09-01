import type { FitnessMealKey } from "./contract";

export type FitnessQuickMeal = Extract<FitnessMealKey, "breakfast" | "lunch" | "dinner">;

export type FitnessQuickEntryPreferences = {
  meal_times: Record<FitnessQuickMeal, string>;
};

export type FitnessStrengthAvailabilityWindow = {
  start: string;
  end: string;
  label?: string | null;
  booking_url?: string | null;
};

export type FitnessStrengthAvailabilityDay = {
  date: string;
  covered: boolean;
  windows: FitnessStrengthAvailabilityWindow[];
};

export type FitnessStrengthAvailability = {
  provider: "school_weights_room" | "vi_training";
  source_title: string;
  source_url?: string | null;
  unavailable_reason?: string | null;
  days: FitnessStrengthAvailabilityDay[];
};

export type FitnessViClass = {
  start: string;
  end: string;
  label: string;
  classification: "strength" | "run" | "conditioning" | "mobility" | "other";
  booking_url: string | null;
};

export type FitnessViSchedule = {
  relevant: boolean;
  provider: "vi_training";
  source_title: string;
  source_url: string | null;
  unavailable_reason: string | null;
  days: Array<{
    date: string;
    covered: boolean;
    classes: FitnessViClass[];
  }>;
};

export type CachedFitnessViSchedule = {
  schedule: FitnessViSchedule;
  cached_at: string;
};

export const DEFAULT_FITNESS_QUICK_ENTRY_PREFERENCES: FitnessQuickEntryPreferences = {
  meal_times: {
    breakfast: "08:00",
    lunch: "12:30",
    dinner: "18:30",
  },
};

export const FITNESS_QUICK_ENTRY_PREFERENCES_EVENT = "hausklar:fitness-quick-entry-preferences-changed";

const TIME_PATTERN = /^(?:[01]\d|2[0-3]):[0-5]\d$/;

export function validFitnessQuickEntryPreferences(value: unknown): value is FitnessQuickEntryPreferences {
  if (!value || typeof value !== "object") return false;
  const mealTimes = (value as { meal_times?: unknown }).meal_times;
  if (!mealTimes || typeof mealTimes !== "object") return false;
  return (["breakfast", "lunch", "dinner"] as const).every((meal) => (
    typeof (mealTimes as Record<string, unknown>)[meal] === "string"
    && TIME_PATTERN.test((mealTimes as Record<string, string>)[meal])
  ));
}

function quickEntryPreferenceStorageKey(ownerID: string): string {
  return `hausklar:fitness-quick-entry-preferences:${ownerID}`;
}

function viScheduleStorageKey(ownerID: string): string {
  return `hausklar:fitness-vi-schedule:${ownerID}`;
}

export function cachedFitnessQuickEntryPreferences(ownerID: string): FitnessQuickEntryPreferences | null {
  if (!ownerID || typeof window === "undefined") return null;
  try {
    const parsed = JSON.parse(window.localStorage.getItem(quickEntryPreferenceStorageKey(ownerID)) ?? "null");
    return validFitnessQuickEntryPreferences(parsed) ? parsed : null;
  } catch {
    return null;
  }
}

export function rememberFitnessQuickEntryPreferences(ownerID: string, value: FitnessQuickEntryPreferences): void {
  if (!ownerID || typeof window === "undefined") return;
  try {
    window.localStorage.setItem(quickEntryPreferenceStorageKey(ownerID), JSON.stringify(value));
  } catch {
    // A locked-down or private browser can disable local storage.
  }
}

export function cachedFitnessViSchedule(ownerID: string): CachedFitnessViSchedule | null {
  if (!ownerID || typeof window === "undefined") return null;
  try {
    const parsed = JSON.parse(window.localStorage.getItem(viScheduleStorageKey(ownerID)) ?? "null") as Partial<CachedFitnessViSchedule> | null;
    return parsed
      && typeof parsed.cached_at === "string"
      && validFitnessViSchedule(parsed.schedule)
      ? { schedule: parsed.schedule, cached_at: parsed.cached_at }
      : null;
  } catch {
    return null;
  }
}

export function rememberFitnessViSchedule(
  ownerID: string,
  schedule: FitnessViSchedule,
  cachedAt = new Date().toISOString(),
): void {
  if (!ownerID || typeof window === "undefined" || !validFitnessViSchedule(schedule)) return;
  try {
    window.localStorage.setItem(viScheduleStorageKey(ownerID), JSON.stringify({
      schedule,
      cached_at: cachedAt,
    } satisfies CachedFitnessViSchedule));
  } catch {
    // A locked-down or private browser can disable local storage.
  }
}

export function announceFitnessQuickEntryPreferences(ownerID: string, value: FitnessQuickEntryPreferences): void {
  if (typeof window === "undefined") return;
  window.dispatchEvent(new CustomEvent(FITNESS_QUICK_ENTRY_PREFERENCES_EVENT, {
    detail: { ownerID, value },
  }));
}

function minutesFromTime(value: string): number | null {
  if (!TIME_PATTERN.test(value)) return null;
  const [hours, minutes] = value.split(":").map(Number);
  return hours * 60 + minutes;
}

export function mealNearTime(
  now: Date,
  preferences: FitnessQuickEntryPreferences,
  windowMinutes = 90,
): FitnessQuickMeal | null {
  const currentMinutes = now.getHours() * 60 + now.getMinutes();
  const candidates = (["breakfast", "lunch", "dinner"] as const)
    .map((meal) => ({ meal, minutes: minutesFromTime(preferences.meal_times[meal]) }))
    .filter((candidate): candidate is { meal: FitnessQuickMeal; minutes: number } => candidate.minutes != null)
    .map((candidate) => ({ ...candidate, distance: Math.abs(candidate.minutes - currentMinutes) }))
    .filter((candidate) => candidate.distance <= windowMinutes)
    .sort((left, right) => left.distance - right.distance);
  return candidates[0]?.meal ?? null;
}

export function fitnessQuickMealLabel(meal: FitnessQuickMeal): string {
  return meal[0].toLocaleUpperCase() + meal.slice(1);
}

export function validStrengthAvailability(value: unknown): value is FitnessStrengthAvailability {
  if (!value || typeof value !== "object") return false;
  const candidate = value as Partial<FitnessStrengthAvailability>;
  return (candidate.provider === "school_weights_room" || candidate.provider === "vi_training")
    && typeof candidate.source_title === "string"
    && Array.isArray(candidate.days)
    && candidate.days.every((day) => (
      typeof day?.date === "string"
      && typeof day?.covered === "boolean"
      && Array.isArray(day.windows)
      && day.windows.every((window) => TIME_PATTERN.test(window.start) && TIME_PATTERN.test(window.end))
    ));
}

export function validFitnessViSchedule(value: unknown): value is FitnessViSchedule {
  if (!value || typeof value !== "object") return false;
  const candidate = value as Partial<FitnessViSchedule>;
  const classifications = new Set(["strength", "run", "conditioning", "mobility", "other"]);
  return typeof candidate.relevant === "boolean"
    && candidate.provider === "vi_training"
    && typeof candidate.source_title === "string"
    && (candidate.source_url == null || typeof candidate.source_url === "string")
    && (candidate.unavailable_reason == null || typeof candidate.unavailable_reason === "string")
    && Array.isArray(candidate.days)
    && candidate.days.every((day) => (
      typeof day?.date === "string"
      && typeof day?.covered === "boolean"
      && Array.isArray(day.classes)
      && day.classes.every((entry) => (
        TIME_PATTERN.test(entry.start)
        && TIME_PATTERN.test(entry.end)
        && typeof entry.label === "string"
        && classifications.has(entry.classification)
        && (entry.booking_url == null || typeof entry.booking_url === "string")
      ))
    ));
}
