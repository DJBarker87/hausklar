import {
  AlertTriangle,
  Archive,
  Camera,
  CheckCircle2,
  ChevronLeft,
  ChevronRight,
  Copy,
  Heart,
  Image as ImageIcon,
  MoreHorizontal,
  Pencil,
  Plus,
  RefreshCw,
  Search,
  Star,
  Trash2,
  Undo2,
  X,
} from "lucide-react";
import { useCallback, useEffect, useMemo, useRef, useState } from "react";

import { api } from "../../api";
import type {
  FitnessFood,
  FitnessFoodBarcodeLookup,
  FitnessFoodLogEntry,
  FitnessFoodMergePreview,
  FitnessFoodServing,
  FitnessFoodVersion,
  FitnessMealKey,
  FitnessMealTemplate,
  FitnessMealTemplateItem,
  FitnessNutritionDay,
  FitnessNutritionAnalysis,
  FitnessNutritionMeasurementQuality,
  FitnessNutritionNutrients,
  FitnessNutritionSettings,
  FitnessNutritionTarget,
  FitnessNutritionTargetMode,
  FitnessPhase,
  FitnessRecipe,
  FitnessRecipeComponent,
  FitnessRecipeVersion,
} from "../../fitness/contract";
import {
  FITNESS_NUTRIENT_KEYS,
  aggregateNutritionEntries,
  authoritativeCalories,
  calculateRecipeNutrition,
  currentFoodVersion,
  foodLogEntryIsOnDate,
  nutritionDateForLocalInput,
  nutrientsForLogEntry,
  quickNutritionPicks,
  repeatFoodLogPayloads,
  templateLogPayloads,
  type FitnessNutrientKey,
} from "../../fitness/nutrition";
import * as fitnessOffline from "../../fitness/offlineStore";
import type { FitnessViewProps } from "./FitnessModuleView";
import {
  FitnessCard,
  FitnessFormStatus,
  FitnessLoadingOrError,
  FitnessStat,
  errorMessage,
  formatFitnessDate,
  formatFitnessDateTime,
  localDateTimeValue,
  localDateValue,
  localTimeZone,
  submitForm,
  useFitnessBatchSave,
  useFitnessCollection,
  useFitnessEndpoint,
  useFitnessSave,
  utcFromLocalInput,
} from "./shared";

const mealOptions: Array<{ key: FitnessMealKey; label: string }> = [
  { key: "breakfast", label: "Breakfast" },
  { key: "lunch", label: "Lunch" },
  { key: "dinner", label: "Dinner" },
  { key: "snack", label: "Snack" },
  { key: "drink", label: "Drink" },
  { key: "pre_workout", label: "Pre-workout" },
  { key: "during_workout", label: "During workout" },
  { key: "post_workout", label: "Post-workout" },
  { key: "other", label: "Other" },
];

const diaryMealGroups: Array<{ key: "breakfast" | "lunch" | "dinner" | "snacks"; label: string; addAs: FitnessMealKey; entryKeys: FitnessMealKey[] }> = [
  { key: "breakfast", label: "Breakfast", addAs: "breakfast", entryKeys: ["breakfast"] },
  { key: "lunch", label: "Lunch", addAs: "lunch", entryKeys: ["lunch"] },
  { key: "dinner", label: "Dinner", addAs: "dinner", entryKeys: ["dinner"] },
  { key: "snacks", label: "Snacks", addAs: "snack", entryKeys: ["snack", "drink", "pre_workout", "during_workout", "post_workout", "other"] },
];

const DEFAULT_NUTRITION_DAY_START_MINUTES = 240;
const NUTRITION_DAY_START_CACHE_KEY = "hausklar:fitness:nutrition-day-start-minutes";

function validNutritionDayStartMinutes(value: number): boolean {
  return Number.isInteger(value) && value >= 0 && value <= 480;
}

function cachedNutritionDayStartMinutes(): number {
  if (typeof window === "undefined") return DEFAULT_NUTRITION_DAY_START_MINUTES;
  try {
    const stored = window.localStorage.getItem(NUTRITION_DAY_START_CACHE_KEY);
    if (stored == null) return DEFAULT_NUTRITION_DAY_START_MINUTES;
    const parsed = Number(stored);
    return validNutritionDayStartMinutes(parsed) ? parsed : DEFAULT_NUTRITION_DAY_START_MINUTES;
  } catch {
    return DEFAULT_NUTRITION_DAY_START_MINUTES;
  }
}

function rememberNutritionDayStartMinutes(value: number): void {
  if (typeof window === "undefined" || !validNutritionDayStartMinutes(value)) return;
  try {
    window.localStorage.setItem(NUTRITION_DAY_START_CACHE_KEY, String(value));
  } catch {
    // A blocked storage API must not prevent diary use.
  }
}

function currentNutritionDate(boundaryMinutes: number, now = new Date()): string {
  const shifted = new Date(now);
  shifted.setMinutes(shifted.getMinutes() - boundaryMinutes);
  return localDateValue(shifted);
}

function offsetLocalDate(value: string, days: number): string {
  const date = new Date(`${value}T12:00:00`);
  date.setDate(date.getDate() + days);
  return localDateValue(date);
}

const qualityOptions: Array<{ key: FitnessNutritionMeasurementQuality; label: string }> = [
  { key: "weighed", label: "Weighed" },
  { key: "measured", label: "Measured" },
  { key: "standard_serving", label: "Standard serving" },
  { key: "estimated", label: "Estimated" },
  { key: "restaurant_estimate", label: "Restaurant estimate" },
];

const nutrientLabels: Record<FitnessNutrientKey, string> = {
  calories_kcal: "Calories",
  protein_g: "Protein",
  carbohydrate_g: "Carbohydrate",
  fibre_g: "Fibre",
  fat_g: "Fat",
  saturated_fat_g: "Saturated fat",
  sugars_g: "Sugar",
  salt_g: "Salt",
};

const nutrientUnits: Record<FitnessNutrientKey, string> = {
  calories_kcal: "kcal",
  protein_g: "g",
  carbohydrate_g: "g",
  fibre_g: "g",
  fat_g: "g",
  saturated_fat_g: "g",
  sugars_g: "g",
  salt_g: "g",
};

const periodContributorKeys = ["calories_kcal", "protein_g", "fibre_g", "sugars_g", "saturated_fat_g", "salt_g"] as const;
type PeriodContributorKey = typeof periodContributorKeys[number];

function numberOrNull(value: string): number | null {
  if (!value.trim()) return null;
  const parsed = Number(value);
  return Number.isFinite(parsed) ? parsed : null;
}

function titleCase(value: string): string {
  return value.replaceAll("_", " ").replace(/\b\w/g, (letter) => letter.toLocaleUpperCase());
}

function formatNutrient(value: number | null | undefined, key: FitnessNutrientKey): string {
  if (value == null) return "Unknown";
  const digits = key === "calories_kcal" ? 0 : value < 10 ? 1 : 0;
  return `${value.toLocaleString(undefined, { maximumFractionDigits: digits })} ${nutrientUnits[key]}`;
}

function emptyNutrients(): FitnessNutritionNutrients {
  return {
    calories_kcal: null,
    protein_g: null,
    carbohydrate_g: null,
    fibre_g: null,
    fat_g: null,
    saturated_fat_g: null,
    sugars_g: null,
    salt_g: null,
  };
}

function emptyNutritionDay(date: string): FitnessNutritionDay {
  return {
    nutrition_date: date,
    entries: [],
    totals: emptyNutrients(),
    targets: {},
    remaining: {},
    meal_totals: {},
    contributors: [],
    uncertain_nutrients: [],
    measured_share: null,
    estimated_share: null,
  };
}

function normaliseNutritionDay(value: Partial<FitnessNutritionDay> | null, date: string): FitnessNutritionDay {
  const fallback = emptyNutritionDay(date);
  return {
    ...fallback,
    ...value,
    nutrition_date: value?.nutrition_date ?? value?.date ?? date,
    entries: value?.entries ?? [],
    totals: { ...fallback.totals, ...(value?.totals ?? {}) },
    targets: value?.targets ?? {},
    remaining: value?.remaining ?? {},
    meal_totals: value?.meal_totals ?? {},
    contributors: value?.contributors ?? [],
    uncertain_nutrients: value?.uncertain_nutrients ?? [],
    measured_share: value?.measured_share ?? value?.measured_ratio ?? null,
  };
}

function useNutritionDay(date: string, revision: number) {
  const [data, setData] = useState(() => emptyNutritionDay(date));
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [fromCache, setFromCache] = useState(false);
  const [nonce, setNonce] = useState(0);
  const shownDate = useRef<string | null>(null);
  const reload = useCallback(() => setNonce((value) => value + 1), []);

  useEffect(() => {
    let cancelled = false;
    // Refreshing a day already on screen keeps the diary visible; only a day
    // with nothing to show yet gets the loading state.
    if (shownDate.current !== date) setLoading(true);
    setError(null);
    void (async () => {
      const requestStartedAt = new Date().toISOString();
      try {
        if (!navigator.onLine) throw new TypeError("Offline");
        const response = await api<FitnessNutritionDay | Partial<FitnessNutritionDay>>(
          `/fitness/food-log?date=${encodeURIComponent(date)}`,
          {},
          true,
          false,
        );
        const next = normaliseNutritionDay(response, date);
        await fitnessOffline.cacheFitnessFoodLogDay(date, next.entries, requestStartedAt).catch(() => undefined);
        // The cache now holds the server's own list plus this device's queued
        // work, so it decides the diary. An empty cached day means the day is
        // empty, never that removed entries should reappear from the response.
        const cached = await fitnessOffline.cachedFitnessFoodLogDay(date).catch(() => null);
        if (!cancelled) {
          setData({ ...next, entries: cached ?? next.entries });
          setFromCache(false);
        }
      } catch (requestError) {
        const dayEntries = await fitnessOffline.cachedFitnessFoodLogDay(date).catch(() => null) ?? [];
        if (!cancelled) {
          setData({ ...emptyNutritionDay(date), entries: dayEntries });
          setFromCache(dayEntries.length > 0);
          if (navigator.onLine && dayEntries.length === 0) setError(errorMessage(requestError));
        }
      } finally {
        if (!cancelled) {
          shownDate.current = date;
          setLoading(false);
        }
      }
    })();
    return () => { cancelled = true; };
  }, [date, nonce, revision]);

  // Removing an entry shows immediately; the day totals catch up on reload.
  const removeEntries = useCallback((ids: string[]) => {
    setData((current) => ({
      ...current,
      entries: current.entries.filter((entry) => !ids.includes(entry.id)),
    }));
  }, []);

  return { data, loading, error, fromCache, reload, removeEntries };
}

function targetForMetric(targets: FitnessNutritionTarget[], key: FitnessNutrientKey): FitnessNutritionTarget | null {
  return targets.find((target) => target.metric_key === key && target.active !== false) ?? null;
}

function targetValue(target: FitnessNutritionTarget | null, isTrainingDay = false): number | null {
  if (!target) return null;
  if (target.target_type === "range") return target.target_max ?? target.target_min ?? null;
  if (target.target_type === "training_rest") return isTrainingDay
    ? target.training_day_value ?? null
    : target.rest_day_value ?? null;
  return target.target_value ?? null;
}

function effectiveTarget(
  serverTargets: Partial<FitnessNutritionNutrients> | undefined,
  targets: FitnessNutritionTarget[],
  key: FitnessNutrientKey,
): number | null {
  return serverTargets?.[key] ?? targetValue(targetForMetric(targets, key));
}

type DailyNutritionImprovement = {
  key: "protein_g" | "fibre_g" | "calories_kcal";
  target: number;
  logged: number;
  remaining: number;
  contributor: { label: string; value: number };
  measuredShare: number;
  estimatedShare: number;
};

function topNutritionContributor(
  day: FitnessNutritionDay,
  entries: FitnessFoodLogEntry[],
  foods: FitnessFood[],
  key: DailyNutritionImprovement["key"],
): DailyNutritionImprovement["contributor"] | null {
  const serverContributor = [...(day.contributors ?? [])]
    .filter((item) => item.nutrient_key === key && Number.isFinite(item.value) && item.value > 0)
    .sort((left, right) => right.value - left.value)[0];
  if (serverContributor) return { label: serverContributor.label, value: serverContributor.value };

  const local = new Map<string, number>();
  for (const entry of entries) {
    const food = foods.find((candidate) => candidate.id === entry.food_id
      || candidate.versions?.some((version) => version.id === entry.food_version_id)
      || currentFoodVersion(candidate)?.id === entry.food_version_id);
    const label = entry.food_name ?? food?.name;
    const value = nutrientsForLogEntry(entry, foods)[key];
    if (!label || value == null || !Number.isFinite(value)) continue;
    local.set(label, (local.get(label) ?? 0) + value);
  }
  const [label, value] = [...local.entries()].sort((left, right) => right[1] - left[1])[0] ?? [];
  return label && value != null ? { label, value } : null;
}

function dailyNutritionImprovement({
  day,
  entries,
  foods,
  targets,
  totals,
  uncertain,
  measuredShare,
  estimatedShare,
}: {
  day: FitnessNutritionDay;
  entries: FitnessFoodLogEntry[];
  foods: FitnessFood[];
  targets: FitnessNutritionTarget[];
  totals: FitnessNutritionNutrients;
  uncertain: Set<string>;
  measuredShare: number | null;
  estimatedShare: number | null;
}): DailyNutritionImprovement | null {
  if (!entries.length || measuredShare == null || estimatedShare == null) return null;
  const candidates = ["protein_g", "fibre_g", "calories_kcal"] as const;
  for (const key of candidates) {
    const target = effectiveTarget(day.targets, targets, key);
    const logged = totals[key];
    if (target == null || logged == null || target <= 0 || uncertain.has(key)) continue;
    const remaining = target - logged;
    const minimumUsefulGap = key === "calories_kcal" ? 25 : 1;
    if (key !== "calories_kcal" && remaining < minimumUsefulGap) continue;
    if (key === "calories_kcal" && Math.abs(remaining) < minimumUsefulGap) continue;
    const contributor = topNutritionContributor(day, entries, foods, key);
    if (!contributor) continue;
    return { key, target, logged, remaining, contributor, measuredShare, estimatedShare };
  }
  return null;
}

function nutritionImprovementOption(improvement: DailyNutritionImprovement): string {
  if (improvement.key !== "calories_kcal") {
    return `This diary day is ${formatNutrient(improvement.remaining, improvement.key)} below the saved ${nutrientLabels[improvement.key].toLocaleLowerCase()} target. This is a record of the gap; the saved diary stays unchanged.`;
  }
  if (improvement.remaining >= 0) {
    return `This diary day has ${formatNutrient(improvement.remaining, improvement.key)} left against the saved target. Exercise Calories are not added automatically.`;
  }

  const gap = Math.abs(improvement.remaining);
  const measurementNote = improvement.estimatedShare > 0
    ? ` ${Math.round(improvement.estimatedShare * 100)}% of entries are estimated, so the total depends on those recorded portions.`
    : " All entries use measured or standard-serving amounts.";
  return `This diary day is ${formatNutrient(gap, improvement.key)} over the saved target.${measurementNote} The saved diary stays unchanged.`;
}

function foodIdentityPayload(food: FitnessFood, overrides: Partial<FitnessFood> = {}): Record<string, unknown> {
  const value = { ...food, ...overrides };
  return {
    name: value.name,
    brand: value.brand ?? null,
    category_key: value.category_key ?? null,
    barcode: value.barcode ?? null,
    notes: value.notes ?? null,
    household_shared: value.household_shared ?? false,
    favourite: value.favourite ?? false,
    active: value.active ?? true,
  };
}

function recipeIdentityPayload(recipe: FitnessRecipe, overrides: Partial<FitnessRecipe> = {}): Record<string, unknown> {
  const value = { ...recipe, ...overrides };
  return {
    name: value.name,
    notes: value.notes ?? null,
    household_shared: value.household_shared ?? false,
    favourite: value.favourite ?? false,
    active: value.active ?? true,
  };
}

type LogFormState = {
  // Minted when the form opens, so re-submitting the same intent — a second
  // click, or a retry after an error — upserts one entry instead of adding another.
  entryId: string;
  source: string;
  loggedAt: string;
  meal: FitnessMealKey;
  amount: string;
  unit: string;
  servingId: string;
  quality: FitnessNutritionMeasurementQuality;
  notes: string;
};

function newLogForm(): LogFormState {
  return {
    entryId: crypto.randomUUID(),
    source: "",
    loggedAt: localDateTimeValue(),
    meal: "breakfast",
    amount: "100",
    unit: "g",
    servingId: "",
    quality: "weighed",
    notes: "",
  };
}

export function FitnessNutritionDiaryPanel({
  online,
  revision,
  onDataChanged,
  openLogRequest,
  onOpenCatalogue,
  onOpenTemplates,
}: FitnessViewProps & { openLogRequest: number; onOpenCatalogue?: () => void; onOpenRecipes?: () => void; onOpenTemplates: () => void }) {
  const [initialBoundary] = useState(cachedNutritionDayStartMinutes);
  const [date, setDate] = useState(() => currentNutritionDate(initialBoundary));
  const [followingCurrentDay, setFollowingCurrentDay] = useState(true);
  const [analysisDays, setAnalysisDays] = useState<7 | 14 | 28 | 90>(14);
  const [contributorMetric, setContributorMetric] = useState<PeriodContributorKey>("calories_kcal");
  const day = useNutritionDay(date, revision);
  const analysisStart = offsetLocalDate(date, -(analysisDays - 1));
  const analysis = useFitnessEndpoint<FitnessNutritionAnalysis>(
    `/fitness/nutrition/analysis?start=${encodeURIComponent(analysisStart)}&end=${encodeURIComponent(date)}`,
    {
      start: analysisStart,
      end: date,
      sample_days: 0,
      calendar_days: 28,
      completeness: 0,
      contributors: [],
      recommendation: null,
    },
    revision,
  );
  const foods = useFitnessCollection<FitnessFood>("/fitness/foods", "food", revision);
  const recipes = useFitnessCollection<FitnessRecipe>("/fitness/recipes", "recipe", revision);
  const templates = useFitnessCollection<FitnessMealTemplate>("/fitness/meal-templates", "meal_template", revision);
  const targets = useFitnessCollection<FitnessNutritionTarget>(`/fitness/nutrition/targets?date=${encodeURIComponent(date)}`, "nutrition_target", revision);
  const settings = useFitnessEndpoint<FitnessNutritionSettings>("/fitness/nutrition/settings", {
    id: "nutrition-settings",
    timezone: localTimeZone(),
    nutrition_day_start_minutes: initialBoundary,
  }, revision);
  const logSave = useFitnessSave(() => { onDataChanged(); day.reload(); });
  const batchSave = useFitnessBatchSave(() => { onDataChanged(); day.reload(); });
  const templateSave = useFitnessSave(onDataChanged);
  const recommendationServingSave = useFitnessSave(() => { onDataChanged(); foods.reload(); });
  const [logForm, setLogForm] = useState<LogFormState | null>(null);
  const [editingEntry, setEditingEntry] = useState<FitnessFoodLogEntry | null>(null);
  const [confirmDelete, setConfirmDelete] = useState<FitnessFoodLogEntry | null>(null);
  const [deleting, setDeleting] = useState(false);
  const [deleteError, setDeleteError] = useState<string | null>(null);
  const [repeatTargetDate, setRepeatTargetDate] = useState(() => offsetLocalDate(date, 1));
  const [repeatError, setRepeatError] = useState<string | null>(null);
  const [copyingYesterdayBreakfast, setCopyingYesterdayBreakfast] = useState(false);
  const [templateMeal, setTemplateMeal] = useState<FitnessMealKey | null>(null);
  const [templateName, setTemplateName] = useState("");
  const [catalogueQuery, setCatalogueQuery] = useState("");
  const [quickMeal, setQuickMeal] = useState<FitnessMealKey>(() => newLogForm().meal);
  const [lastQuickLog, setLastQuickLog] = useState<{ records: Array<{ id: string; revision?: number }>; label: string } | null>(null);
  const quickLogUndoRef = useRef<HTMLButtonElement>(null);
  const previousOpenRequest = useRef(0);

  useEffect(() => {
    if (lastQuickLog) quickLogUndoRef.current?.focus();
  }, [lastQuickLog]);

  useEffect(() => {
    rememberNutritionDayStartMinutes(settings.data.nutrition_day_start_minutes);
    if (followingCurrentDay) {
      setDate(currentNutritionDate(settings.data.nutrition_day_start_minutes));
    }
  }, [followingCurrentDay, settings.data.nutrition_day_start_minutes]);

  useEffect(() => {
    setRepeatTargetDate(offsetLocalDate(date, 1));
    setRepeatError(null);
  }, [date]);

  useEffect(() => {
    if (openLogRequest > previousOpenRequest.current) {
      setEditingEntry(null);
      setLogForm(newLogForm());
      setCatalogueQuery("");
      previousOpenRequest.current = openLogRequest;
    }
  }, [openLogRequest]);

  const entries = day.data.entries;
  const localAggregate = useMemo(() => aggregateNutritionEntries(entries, foods.data), [entries, foods.data]);
  const totals = localAggregate.totals;
  const uncertain = new Set([...localAggregate.uncertain, ...(day.data.uncertain_nutrients ?? [])]);
  const measuredEntries = entries.filter((entry) => ["weighed", "measured", "standard_serving"].includes(entry.measurement_quality ?? ""));
  const estimatedEntries = entries.filter((entry) => ["estimated", "restaurant_estimate"].includes(entry.measurement_quality ?? ""));
  const measuredShare = day.data.measured_share ?? (entries.length ? measuredEntries.length / entries.length : null);
  const estimatedShare = day.data.estimated_share ?? (entries.length ? estimatedEntries.length / entries.length : null);
  const improvement = dailyNutritionImprovement({
    day: day.data,
    entries,
    foods: foods.data,
    targets: targets.data,
    totals,
    uncertain,
    measuredShare,
    estimatedShare,
  });
  const recommendation = analysis.loading || analysis.error ? null : analysis.data.recommendation ?? null;
  const periodContributors = (analysis.data.contributors ?? [])
    .filter((item) => item.nutrient_key === contributorMetric)
    .slice(0, 5);

  const selectedFoodId = logForm?.source.startsWith("food:")
    ? logForm.source.slice(5)
    : logForm?.source.startsWith("recipe:")
      ? ""
      : logForm?.source ?? "";
  const selectedRecipeId = logForm?.source.startsWith("recipe:") ? logForm.source.slice(7) : "";
  const selectedFood = foods.data.find((food) => food.id === selectedFoodId) ?? null;
  const selectedRecipe = recipes.data.find((recipe) => recipe.id === selectedRecipeId) ?? null;
  const selectedVersion = currentFoodVersion(selectedFood);
  const selectedRecipeVersion = selectedRecipe?.current_version ?? selectedRecipe?.latest_version ?? null;
  const selectedServing = selectedFood?.servings?.find((serving) => serving.id === logForm?.servingId) ?? null;
  const quickPicks = useMemo(
    () => quickNutritionPicks(foods.data, templates.data, quickMeal),
    [foods.data, quickMeal, templates.data],
  );
  const searchedFoods = useMemo(() => {
    const query = catalogueQuery.trim().toLocaleLowerCase();
    if (!query) return foods.data.filter((food) => food.active !== false && currentFoodVersion(food)?.id).slice(0, 12);
    return foods.data.filter((food) => food.active !== false && currentFoodVersion(food)?.id && [food.name, food.brand, ...(food.search_aliases ?? [])].some((value) => value?.toLocaleLowerCase().includes(query))).slice(0, 20);
  }, [catalogueQuery, foods.data]);
  const searchedRecipes = useMemo(() => {
    const query = catalogueQuery.trim().toLocaleLowerCase();
    if (!query) return recipes.data.filter((recipe) => recipe.active !== false && recipe.favourite && (recipe.current_version ?? recipe.latest_version)?.id).slice(0, 6);
    return recipes.data.filter((recipe) => recipe.active !== false && (recipe.current_version ?? recipe.latest_version)?.id && recipe.name.toLocaleLowerCase().includes(query)).slice(0, 8);
  }, [catalogueQuery, recipes.data]);

  function openAddFood(meal: FitnessMealKey) {
    const next = newLogForm();
    const now = new Date();
    next.meal = meal;
    next.loggedAt = `${date}T${String(now.getHours()).padStart(2, "0")}:${String(now.getMinutes()).padStart(2, "0")}`;
    setEditingEntry(null);
    setCatalogueQuery("");
    setLogForm(next);
  }

  function setLogSource(value: string) {
    const food = value.startsWith("food:")
      ? foods.data.find((item) => item.id === value.slice(5))
      : !value.startsWith("recipe:")
        ? foods.data.find((item) => item.id === value)
        : null;
    const recipe = value.startsWith("recipe:") ? recipes.data.find((item) => item.id === value.slice(7)) : null;
    const version = currentFoodVersion(food);
    const recipeVersion = recipe?.current_version ?? recipe?.latest_version;
    const usual = food?.quick_use?.usual_amount ?? food?.quick_use?.last_amount;
    setLogForm((current) => current ? {
      ...current,
      source: value,
      amount: String(usual ?? version?.reference_amount ?? (recipeVersion?.finished_weight_g ? 100 : 1)),
      unit: food?.quick_use?.usual_unit ?? food?.quick_use?.last_unit ?? version?.reference_unit ?? (recipeVersion?.finished_weight_g ? "g" : "serving"),
      servingId: "",
    } : current);
  }

  function useServing(servingId: string) {
    const serving = selectedFood?.servings?.find((item) => item.id === servingId);
    setLogForm((current) => current ? {
      ...current,
      servingId,
      amount: serving ? String(serving.amount) : String(selectedVersion?.reference_amount ?? 100),
      unit: serving?.unit ?? selectedVersion?.reference_unit ?? "g",
      quality: serving?.measurement_quality ?? current.quality,
    } : current);
  }

  async function saveLog() {
    if (!logForm) return;
    const enteredAmount = Number(logForm.amount);
    if (!Number.isFinite(enteredAmount) || enteredAmount <= 0) return;
    let canonicalAmount = enteredAmount;
    let canonicalUnit = logForm.unit;
    if (selectedServing) {
      canonicalAmount = enteredAmount / selectedServing.amount * selectedServing.canonical_amount;
      canonicalUnit = selectedServing.canonical_unit;
    }
    const payload = {
      food_version_id: selectedVersion?.id ?? null,
      recipe_version_id: selectedRecipeVersion?.id ?? null,
      logged_at_utc: utcFromLocalInput(logForm.loggedAt),
      local_timezone: localTimeZone(),
      nutrition_date: nutritionDateForLocalInput(logForm.loggedAt, settings.data.nutrition_day_start_minutes),
      meal_key: logForm.meal,
      entered_amount: enteredAmount,
      entered_unit: logForm.unit,
      canonical_amount: canonicalAmount,
      canonical_unit: canonicalUnit,
      measurement_quality: logForm.quality,
      notes: logForm.notes.trim() || null,
      context_tags: [],
    };
    const saved = await logSave.save("food_log_entry", payload, {
      entityId: editingEntry ? editingEntry.id : logForm.entryId,
      baseRevision: editingEntry ? editingEntry.revision ?? null : null,
    });
    if (!editingEntry) setLastQuickLog({ records: [{ id: saved.id, revision: saved.revision }], label: selectedFood?.name ?? selectedRecipe?.name ?? "Food" });
    setLogForm(null);
    setEditingEntry(null);
  }

  function editEntry(entry: FitnessFoodLogEntry) {
    const food = foods.data.find((item) => (
      currentFoodVersion(item)?.id === entry.food_version_id
      || item.versions?.some((version) => version.id === entry.food_version_id)
    ));
    const recipe = recipes.data.find((item) => item.versions?.some((version) => version.id === entry.recipe_version_id) || item.current_version?.id === entry.recipe_version_id);
    const local = new Date(entry.logged_at_utc);
    setEditingEntry(entry);
    setLogForm({
      entryId: entry.id,
      source: food ? food.id : recipe ? `recipe:${recipe.id}` : "",
      loggedAt: Number.isNaN(local.valueOf()) ? localDateTimeValue() : `${localDateValue(local)}T${String(local.getHours()).padStart(2, "0")}:${String(local.getMinutes()).padStart(2, "0")}`,
      meal: entry.meal_key as FitnessMealKey,
      amount: String(entry.entered_amount),
      unit: entry.entered_unit,
      servingId: "",
      quality: (entry.measurement_quality ?? "estimated") as FitnessNutritionMeasurementQuality,
      notes: entry.notes ?? "",
    });
  }

  async function deleteEntry(entry: FitnessFoodLogEntry) {
    if (deleting) return;
    setDeleting(true);
    setDeleteError(null);
    try {
      await fitnessOffline.deleteFitnessRecord("food_log_entry", entry.id, entry.revision ?? null);
    } catch (error) {
      setDeleteError(errorMessage(error));
      return;
    } finally {
      setDeleting(false);
    }
    // The removal is already durable on this device, so the row goes now
    // rather than after a round trip. The reload only refreshes day totals.
    day.removeEntries([entry.id]);
    setConfirmDelete(null);
    onDataChanged();
    day.reload();
  }

  async function quickLogFood(foodId: string, amount?: number | null, unit?: string | null, meal = quickMeal) {
    const food = foods.data.find((item) => item.id === foodId);
    const version = currentFoodVersion(food);
    if (!food || !version?.id || logSave.saving) return;
    const enteredAmount = amount ?? food.quick_use?.usual_amount ?? food.quick_use?.last_amount ?? version.reference_amount;
    const enteredUnit = unit ?? food.quick_use?.usual_unit ?? food.quick_use?.last_unit ?? version.reference_unit;
    const serving = food.servings?.find((item) => item.active !== false && item.unit === enteredUnit && Math.abs(item.amount - enteredAmount) < 0.0001);
    const canonicalAmount = serving ? enteredAmount / serving.amount * serving.canonical_amount : enteredAmount;
    const canonicalUnit = serving?.canonical_unit ?? enteredUnit;
    const now = new Date();
    const localLoggedAt = `${date}T${String(now.getHours()).padStart(2, "0")}:${String(now.getMinutes()).padStart(2, "0")}`;
    const saved = await logSave.save("food_log_entry", {
      food_version_id: version.id,
      recipe_version_id: null,
      logged_at_utc: utcFromLocalInput(localLoggedAt),
      local_timezone: localTimeZone(),
      nutrition_date: nutritionDateForLocalInput(localLoggedAt, settings.data.nutrition_day_start_minutes),
      meal_key: meal,
      entered_amount: enteredAmount,
      entered_unit: enteredUnit,
      canonical_amount: canonicalAmount,
      canonical_unit: canonicalUnit,
      measurement_quality: serving?.measurement_quality ?? "standard_serving",
      notes: null,
      context_tags: [],
    });
    setLastQuickLog({ records: [{ id: saved.id, revision: saved.revision }], label: food.name });
  }

  async function quickLogRecipe(recipeId: string) {
    const recipe = recipes.data.find((item) => item.id === recipeId);
    const version = recipe?.current_version ?? recipe?.latest_version;
    if (!recipe || !version?.id || logSave.saving) return;
    const enteredAmount = version.finished_weight_g ? 100 : 1;
    const enteredUnit = version.finished_weight_g ? "g" : "serving";
    const now = new Date();
    const localLoggedAt = `${date}T${String(now.getHours()).padStart(2, "0")}:${String(now.getMinutes()).padStart(2, "0")}`;
    const saved = await logSave.save("food_log_entry", {
      food_version_id: null,
      recipe_version_id: version.id,
      logged_at_utc: utcFromLocalInput(localLoggedAt),
      local_timezone: localTimeZone(),
      nutrition_date: nutritionDateForLocalInput(localLoggedAt, settings.data.nutrition_day_start_minutes),
      meal_key: quickMeal,
      entered_amount: enteredAmount,
      entered_unit: enteredUnit,
      canonical_amount: enteredAmount,
      canonical_unit: enteredUnit,
      measurement_quality: "standard_serving",
      notes: null,
      context_tags: [],
    });
    setLastQuickLog({ records: [{ id: saved.id, revision: saved.revision }], label: recipe.name });
  }

  async function quickLogTemplate(templateId: string) {
    const template = templates.data.find((item) => item.id === templateId);
    if (!template || batchSave.saving) return;
    const now = new Date();
    const localLoggedAt = `${date}T${String(now.getHours()).padStart(2, "0")}:${String(now.getMinutes()).padStart(2, "0")}`;
    const payloads = templateLogPayloads(template, utcFromLocalInput(localLoggedAt), localTimeZone());
    const saved = await batchSave.save(payloads.map((payload) => ({ entityType: "food_log_entry", payload: { ...payload, nutrition_date: nutritionDateForLocalInput(localLoggedAt, settings.data.nutrition_day_start_minutes), meal_key: quickMeal } })));
    setLastQuickLog({ records: saved.map((record) => ({ id: record.id })), label: template.name });
  }

  async function undoQuickLog() {
    if (!lastQuickLog) return;
    await Promise.all(lastQuickLog.records.map((record) => fitnessOffline.deleteFitnessRecord("food_log_entry", record.id, record.revision ?? null)));
    setLastQuickLog(null);
    onDataChanged();
    day.reload();
  }

  function repeatPayloads(source: FitnessFoodLogEntry[], targetDate: string, mealKey?: FitnessMealKey) {
    const foodVersions = new Set(foods.data.flatMap((food) => [currentFoodVersion(food)?.id, ...(food.versions?.map((version) => version.id) ?? [])]).filter(Boolean));
    const recipeVersions = new Set(recipes.data.flatMap((recipe) => [recipe.current_version?.id, ...(recipe.versions?.map((version) => version.id) ?? [])]).filter(Boolean));
    const missing = source.some((entry) => (
      entry.food_version_id ? !foodVersions.has(entry.food_version_id) : !entry.recipe_version_id || !recipeVersions.has(entry.recipe_version_id)
    ));
    if (missing) throw new Error("Cache every referenced food or recipe version before repeating this selection offline.");
    return repeatFoodLogPayloads(
      source,
      targetDate,
      localTimeZone(),
      settings.data.nutrition_day_start_minutes,
      mealKey,
    );
  }

  function repeatInputs(meal?: FitnessMealKey | FitnessMealKey[]) {
    const mealKeys = meal == null ? null : Array.isArray(meal) ? meal : [meal];
    const source = mealKeys ? entries.filter((entry) => mealKeys.includes(entry.meal_key as FitnessMealKey)) : entries;
    return repeatPayloads(source, repeatTargetDate, mealKeys?.length === 1 ? mealKeys[0] : undefined);
  }

  async function repeat(meal?: FitnessMealKey | FitnessMealKey[]) {
    setRepeatError(null);
    try {
      const payloads = repeatInputs(meal);
      if (!payloads.length) throw new Error("There is nothing in that selection to repeat.");
      await batchSave.save(payloads.map((payload) => ({ entityType: "food_log_entry", payload })));
    } catch (error) {
      setRepeatError(errorMessage(error));
    }
  }

  async function copyYesterdayBreakfast() {
    setRepeatError(null);
    setCopyingYesterdayBreakfast(true);
    try {
      const yesterday = offsetLocalDate(date, -1);
      let source: FitnessFoodLogEntry[];
      if (online) {
        const response = await api<FitnessNutritionDay | Partial<FitnessNutritionDay>>(`/fitness/food-log?date=${encodeURIComponent(yesterday)}`, {}, true, false);
        source = normaliseNutritionDay(response, yesterday).entries;
        await fitnessOffline.cacheFitnessRecords("food_log_entry", source).catch(() => undefined);
      } else {
        source = (await fitnessOffline.cachedFitnessRecords<FitnessFoodLogEntry>("food_log_entry")).filter((entry) => entry.nutrition_date === yesterday || (!entry.nutrition_date && entry.logged_at_utc.slice(0, 10) === yesterday));
      }
      const payloads = repeatPayloads(source.filter((entry) => entry.meal_key === "breakfast"), date, "breakfast");
      if (!payloads.length) throw new Error("No breakfast was logged yesterday.");
      await batchSave.save(payloads.map((payload) => ({ entityType: "food_log_entry", payload })));
    } catch (error) {
      setRepeatError(errorMessage(error));
    } finally {
      setCopyingYesterdayBreakfast(false);
    }
  }

  async function saveMealTemplate() {
    if (!templateMeal || !templateName.trim()) return;
    const mealEntries = entries.filter((entry) => entry.meal_key === templateMeal);
    await templateSave.save("meal_template", {
      name: templateName.trim(),
      meal_key: templateMeal,
      time_relevance: templateMeal,
      favourite: false,
      active: true,
      items: mealEntries.map((entry, sequence) => ({
        id: crypto.randomUUID(),
        food_version_id: entry.food_version_id ?? null,
        recipe_version_id: entry.recipe_version_id ?? null,
        amount: entry.entered_amount,
        unit: entry.entered_unit,
        canonical_amount: entry.canonical_amount,
        canonical_unit: entry.canonical_unit,
        measurement_quality: entry.measurement_quality ?? "estimated",
        sequence,
      })),
    });
    setTemplateMeal(null);
    setTemplateName("");
  }

  function useRecommendedPortion() {
    if (!recommendation) return;
    const next = newLogForm();
    const now = new Date();
    next.source = recommendation.item_kind === "recipe" ? `recipe:${recommendation.item_id}` : recommendation.item_id;
    next.meal = recommendation.meal_key as FitnessMealKey;
    next.amount = String(recommendation.proposed_change.resulting_amount);
    next.unit = recommendation.proposed_change.unit;
    next.loggedAt = `${date}T${String(now.getHours()).padStart(2, "0")}:${String(now.getMinutes()).padStart(2, "0")}`;
    setEditingEntry(null);
    setLogForm(next);
  }

  const recommendedFood = recommendation?.item_kind === "food" ? foods.data.find((food) => food.id === recommendation.item_id) ?? null : null;
  const recommendedVersion = currentFoodVersion(recommendedFood);
  const recommendedUnit = recommendation?.proposed_change.unit ?? "";
  const recommendedAmount = recommendation?.proposed_change.resulting_amount ?? null;
  const recommendedUnitServing = recommendedFood?.servings?.find((serving) => serving.active !== false && serving.unit === recommendedUnit) ?? null;
  const canSaveRecommendedServing = Boolean(
    recommendation && recommendedFood && recommendedFood.editable !== false && recommendedVersion
    && recommendedAmount != null
    && (recommendedUnit === recommendedVersion.reference_unit || recommendedUnitServing),
  );

  async function saveRecommendedServing() {
    if (!recommendation || !recommendedFood || recommendedAmount == null || !canSaveRecommendedServing) return;
    const existing = recommendedFood.servings?.find((serving) => serving.name.trim().toLocaleLowerCase() === "recommended portion") ?? null;
    const canonicalAmount = recommendedUnitServing
      ? recommendedAmount / recommendedUnitServing.amount * recommendedUnitServing.canonical_amount
      : recommendedAmount;
    await recommendationServingSave.save("food_serving", {
      food_id: recommendedFood.id,
      name: "Recommended portion",
      amount: recommendedAmount,
      unit: recommendedUnit,
      canonical_amount: canonicalAmount,
      canonical_unit: recommendedUnitServing?.canonical_unit ?? recommendedUnit,
      measurement_quality: "standard_serving",
      is_default: true,
      active: true,
    }, existing ? { entityId: existing.id, baseRevision: existing.revision ?? null } : undefined);
  }

  const loading = day.loading || foods.loading;

  return <div className="fitness-module__nutrition-stack">
    {!online ? <div className="fitness-module__notice" role="status">Diary edits, repeats, and saved templates stay available offline. Changes sync automatically when you reconnect.</div> : null}

    <FitnessCard title="Log food" detail="Search first, or use a saved usual serving in one tap." className="fitness-module__quick-log-card">
      <div className="fitness-module__quick-log-toolbar">
        <label className="fitness-module__field"><span><Search aria-hidden="true" size={15} /> Search foods and recipes</span><input type="search" value={catalogueQuery} onChange={(event) => setCatalogueQuery(event.target.value)} placeholder="Oats, yoghurt, chicken bowl…" /></label>
        <label className="fitness-module__field">Meal<select value={quickMeal} onChange={(event) => setQuickMeal(event.target.value as FitnessMealKey)}>{mealOptions.map((item) => <option value={item.key} key={item.key}>{item.label}</option>)}</select></label>
      </div>
      <div className="fitness-module__quick-grid" aria-label={catalogueQuery.trim() ? "Food and recipe search results" : "Recent and favourite foods, recipes and templates"}>
        {catalogueQuery.trim() ? <>{searchedFoods.map((food) => { const amount = food.quick_use?.usual_amount ?? food.quick_use?.last_amount ?? currentFoodVersion(food)?.reference_amount; const unit = food.quick_use?.usual_unit ?? food.quick_use?.last_unit ?? currentFoodVersion(food)?.reference_unit; return <button type="button" disabled={logSave.saving} key={food.id} aria-label={`Log ${food.name}, ${amount ?? "usual"} ${unit ?? "serving"}`} onClick={() => void quickLogFood(food.id, amount, unit)}><strong>{food.name}</strong><small>Log {amount ?? "usual"} {unit ?? "serving"} · {food.brand ?? "saved food"}</small></button>; })}{searchedRecipes.map((recipe) => <button type="button" disabled={logSave.saving} key={`recipe:${recipe.id}`} onClick={() => void quickLogRecipe(recipe.id)}><strong>{recipe.name}</strong><small>Log saved recipe · {recipe.favourite ? "Favourite" : "Search result"}</small></button>)}</> : <>{quickPicks.map((pick) => pick.kind === "food" && pick.food_id ? <button type="button" disabled={logSave.saving} key={pick.key} aria-label={`Log ${pick.label}, ${pick.amount ?? "usual"} ${pick.unit ?? "serving"}`} onClick={() => void quickLogFood(pick.food_id!, pick.amount, pick.unit)}><strong>{pick.label}</strong><small>Log {pick.amount ?? "usual"} {pick.unit ?? "serving"} · {titleCase(pick.reason)}</small></button> : pick.template_id ? <button type="button" disabled={batchSave.saving} key={pick.key} onClick={() => void quickLogTemplate(pick.template_id!)}><strong>{pick.label}</strong><small>Log meal template · {titleCase(pick.reason)}</small></button> : null)}{searchedRecipes.map((recipe) => <button type="button" disabled={logSave.saving} key={`recipe:${recipe.id}`} onClick={() => void quickLogRecipe(recipe.id)}><strong>{recipe.name}</strong><small>Log saved recipe · Favourite</small></button>)}</>}
      </div>
      {!catalogueQuery.trim() && !quickPicks.length && !searchedRecipes.length ? <p className="fitness-module__muted">Log an item once or mark it as a favourite and it will appear here.</p> : null}
      {catalogueQuery.trim() && !searchedFoods.length && !searchedRecipes.length ? <p className="fitness-module__muted">No saved item matches. Add it once, then quick-log it here.</p> : null}
      <div className="fitness-module__button-row"><button type="button" className="button button--secondary" onClick={() => openAddFood(quickMeal)}><Plus aria-hidden="true" size={15} /> Add with details</button><button type="button" className="button button--secondary" onClick={onOpenTemplates}>Meal templates</button><button type="button" className="button button--secondary" onClick={onOpenCatalogue}><Camera aria-hidden="true" size={14} /> Barcode or label</button></div>
      {lastQuickLog ? <div className="fitness-module__quick-log-undo" role="status"><span><strong>{lastQuickLog.label} logged.</strong> Saved to {mealOptions.find((item) => item.key === quickMeal)?.label ?? quickMeal}.</span><button ref={quickLogUndoRef} type="button" className="button button--secondary button--compact" onClick={() => void undoQuickLog()}><Undo2 aria-hidden="true" size={15} /> Undo</button></div> : null}
      <FitnessFormStatus saving={logSave.saving} saved={logSave.saved} error={logSave.saveError} />
      <FitnessFormStatus saving={batchSave.saving} saved={batchSave.saved} error={batchSave.saveError} />
    </FitnessCard>

    {logForm ? <FitnessCard title={editingEntry ? "Edit diary entry" : `Add food to ${mealOptions.find((item) => item.key === logForm.meal)?.label ?? "diary"}`} detail="Search and shortcuts stay here until you choose a saved food or recipe." className="fitness-module__diary-add">
      <form className="fitness-module__form" onSubmit={submitForm(saveLog)}>
        <div className="fitness-module__fields">
          <label className="fitness-module__field is-wide">Food<select required autoFocus value={logForm.source} onChange={(event) => setLogSource(event.target.value)}><option value="">Choose a food or recipe</option><optgroup label="Foods">{foods.data.filter((food) => food.active !== false && currentFoodVersion(food)?.id).map((food) => <option key={food.id} value={food.id}>{food.name}{food.brand ? ` · ${food.brand}` : ""}</option>)}</optgroup>{recipes.data.length ? <optgroup label="Recipes">{recipes.data.filter((recipe) => recipe.active !== false && (recipe.current_version ?? recipe.latest_version)?.id).map((recipe) => <option key={recipe.id} value={`recipe:${recipe.id}`}>{recipe.name}</option>)}</optgroup> : null}</select></label>
          <label className="fitness-module__field">Meal<select value={logForm.meal} onChange={(event) => setLogForm({ ...logForm, meal: event.target.value as FitnessMealKey })}>{mealOptions.map((item) => <option value={item.key} key={item.key}>{item.label}</option>)}</select></label>
          {selectedFood?.servings?.length ? <label className="fitness-module__field">Serving<select value={logForm.servingId} onChange={(event) => useServing(event.target.value)}><option value="">Base amount</option>{selectedFood.servings.filter((serving) => serving.active !== false).map((serving) => <option value={serving.id} key={serving.id}>{serving.name}{serving.is_default ? " · default" : ""}</option>)}</select></label> : null}
          <label className="fitness-module__field">Amount ({logForm.unit})<input type="text" inputMode="decimal" pattern="(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)" required value={logForm.amount} onChange={(event) => setLogForm({ ...logForm, amount: event.target.value })} /></label>
        </div>
        <details className="fitness-module__details"><summary>Timing, quality and notes</summary><div className="fitness-module__fields"><label className="fitness-module__field">When<input type="datetime-local" required value={logForm.loggedAt} onChange={(event) => setLogForm({ ...logForm, loggedAt: event.target.value })} /></label><label className="fitness-module__field">Measurement quality<select value={logForm.quality} onChange={(event) => setLogForm({ ...logForm, quality: event.target.value as FitnessNutritionMeasurementQuality })}>{qualityOptions.map((item) => <option value={item.key} key={item.key}>{item.label}</option>)}</select></label><label className="fitness-module__field is-wide">Notes (optional)<input value={logForm.notes} onChange={(event) => setLogForm({ ...logForm, notes: event.target.value })} /></label></div></details>
        {selectedFood?.quick_use ? <div className="fitness-module__button-row"><span className="fitness-module__muted">Quick amount:</span>{selectedFood.quick_use.last_amount != null ? <button type="button" className="button button--secondary button--compact" onClick={() => setLogForm({ ...logForm, amount: String(selectedFood.quick_use?.last_amount), unit: selectedFood.quick_use?.last_unit ?? logForm.unit })}>Last · {selectedFood.quick_use.last_amount} {selectedFood.quick_use.last_unit}</button> : null}{selectedFood.quick_use.usual_amount != null ? <button type="button" className="button button--secondary button--compact" onClick={() => setLogForm({ ...logForm, amount: String(selectedFood.quick_use?.usual_amount), unit: selectedFood.quick_use?.usual_unit ?? logForm.unit })}>Usual · {selectedFood.quick_use.usual_amount} {selectedFood.quick_use.usual_unit}</button> : null}</div> : null}
        <div className="fitness-module__form-footer"><button type="submit" className="button button--primary" disabled={logSave.saving || (!selectedVersion?.id && !selectedRecipeVersion?.id) || !Number.isFinite(Number(logForm.amount)) || Number(logForm.amount) <= 0}>{editingEntry ? "Save diary edit" : "Add to diary"}</button><button type="button" className="button button--secondary" onClick={() => { setLogForm(null); setEditingEntry(null); }}>Cancel</button><FitnessFormStatus saving={logSave.saving} saved={logSave.saved} error={logSave.saveError} /></div>
      </form>
    </FitnessCard> : null}

    <FitnessLoadingOrError loading={loading} error={day.error ?? foods.error} retry={() => { day.reload(); foods.reload(); }} />

    {!loading ? <>
      <FitnessCard title="Daily summary" detail={`One diary day · boundary ${String(Math.floor(settings.data.nutrition_day_start_minutes / 60)).padStart(2, "0")}:${String(settings.data.nutrition_day_start_minutes % 60).padStart(2, "0")}`} className="is-wide fitness-module__diary-summary">
        <div className="fitness-module__diary-date-nav"><button type="button" className="button button--secondary button--compact" aria-label="Previous nutrition day" onClick={() => { setFollowingCurrentDay(false); setDate(offsetLocalDate(date, -1)); }}><ChevronLeft aria-hidden="true" size={16} /> Previous</button><label className="fitness-module__field">Nutrition day<input type="date" value={date} onChange={(event) => { setFollowingCurrentDay(false); setDate(event.target.value); }} /></label><button type="button" className="button button--secondary button--compact" disabled={date === currentNutritionDate(settings.data.nutrition_day_start_minutes)} onClick={() => { setFollowingCurrentDay(true); setDate(currentNutritionDate(settings.data.nutrition_day_start_minutes)); }}>Today</button><button type="button" className="button button--secondary button--compact" aria-label="Next nutrition day" onClick={() => { setFollowingCurrentDay(false); setDate(offsetLocalDate(date, 1)); }}>Next <ChevronRight aria-hidden="true" size={16} /></button></div>
        <div className="fitness-module__stats">{(["calories_kcal", "protein_g", "carbohydrate_g", "fat_g"] as FitnessNutrientKey[]).map((key) => { const target = effectiveTarget(day.data.targets, targets.data, key); const value = totals[key]; const remaining = day.data.remaining?.[key] ?? (target != null && value != null ? target - value : null); const remainingDetail = (key === "calories_kcal" || key === "protein_g") && target != null && remaining != null ? `${formatNutrient(target, key)} target · ${remaining >= 0 ? `${formatNutrient(remaining, key)} remaining` : `${formatNutrient(Math.abs(remaining), key)} over`}` : target != null ? `${formatNutrient(target, key)} target` : uncertain.has(key) ? "Some values unknown" : undefined; return <FitnessStat key={key} label={nutrientLabels[key]} value={formatNutrient(value, key)} detail={remainingDetail} />; })}</div>
        <div className="fitness-module__quality-row" aria-label="Measurement quality"><span><CheckCircle2 aria-hidden="true" size={16} /> Measured {measuredShare == null ? "—" : `${Math.round(measuredShare * 100)}%`}</span><span><AlertTriangle aria-hidden="true" size={16} /> Estimated {estimatedShare == null ? "—" : `${Math.round(estimatedShare * 100)}%`}</span>{day.fromCache ? <span>Showing this device’s saved diary</span> : null}</div>
        {improvement ? <div className="fitness-module__callout fitness-module__nutrition-improvement">
          <strong>This diary day</strong>
          <p>{nutritionImprovementOption(improvement)}</p>
          <details className="fitness-module__details"><summary>How this was calculated</summary><p><strong>{improvement.contributor.label}</strong> is this diary day’s largest recorded {nutrientLabels[improvement.key].toLocaleLowerCase()} contributor at {formatNutrient(improvement.contributor.value, improvement.key)}.</p><p>{improvement.remaining >= 0
            ? `${formatNutrient(improvement.target, improvement.key)} target − ${formatNutrient(improvement.logged, improvement.key)} logged = ${formatNutrient(improvement.remaining, improvement.key)} remaining.`
            : `${formatNutrient(improvement.logged, improvement.key)} logged − ${formatNutrient(improvement.target, improvement.key)} target = ${formatNutrient(Math.abs(improvement.remaining), improvement.key)} over.`} {Math.round(improvement.measuredShare * 100)}% of entries use measured or standard-serving amounts; {Math.round(improvement.estimatedShare * 100)}% are estimated. This describes this day only; it does not claim what caused a longer-term change.</p></details>
        </div> : null}
        <details className="fitness-module__details fitness-module__nutrition-pattern">
          <summary>{recommendation
            ? `${recommendation.observation_period.calendar_days}-day pattern: reduce ${recommendation.food_or_meal} by ${recommendation.proposed_change.amount.toLocaleString(undefined, { maximumFractionDigits: 1 })} ${recommendation.proposed_change.unit}`
            : analysis.loading
              ? `${analysisDays}-day pattern: checking…`
              : analysis.error
                ? `${analysisDays}-day pattern unavailable`
                : `${analysisDays}-day pattern: no calculated change`}</summary>
          <div className="fitness-module__diary-more-body">
            <label className="fitness-module__field fitness-module__nutrition-period">Pattern evidence period<select aria-label="Pattern evidence period" value={analysisDays} onChange={(event) => setAnalysisDays(Number(event.target.value) as 7 | 14 | 28 | 90)}>{([7, 14, 28, 90] as const).map((days) => <option value={days} key={days}>{days} days</option>)}</select><small>Ends on the selected nutrition day.</small></label>
            {recommendation ? <div className="fitness-module__callout fitness-module__nutrition-improvement">
              <strong>A repeated, calculated option</strong>
              <p>{recommendation.proposed_change.description}</p>
              <div className="fitness-module__button-row"><button type="button" className="button button--primary" onClick={useRecommendedPortion}>Use this portion next time</button>{canSaveRecommendedServing ? <button type="button" className="button button--secondary" disabled={recommendationServingSave.saving || recommendationServingSave.saved} onClick={() => void saveRecommendedServing()}>{recommendationServingSave.saved ? "Default serving saved" : "Make this the default serving"}</button> : null}</div>
              <FitnessFormStatus saving={recommendationServingSave.saving} saved={recommendationServingSave.saved} error={recommendationServingSave.saveError} />
              <p><strong>Calculation.</strong> Recorded intake averaged {recommendation.calculation.observed_average_calories_kcal.toLocaleString(undefined, { maximumFractionDigits: 1 })} kcal across logged days against a saved target of {recommendation.calculation.target_average_calories_kcal.toLocaleString(undefined, { maximumFractionDigits: 1 })} kcal on average: a {recommendation.calculation.average_gap_calories_kcal.toLocaleString(undefined, { maximumFractionDigits: 1 })} kcal gap ({recommendation.calculation.observed_average_calories_kcal.toLocaleString(undefined, { maximumFractionDigits: 1 })} − {recommendation.calculation.target_average_calories_kcal.toLocaleString(undefined, { maximumFractionDigits: 1 })} = {recommendation.calculation.average_gap_calories_kcal.toLocaleString(undefined, { maximumFractionDigits: 1 })}). Targets were available on {recommendation.calculation.target_days} logged {recommendation.calculation.target_days === 1 ? "day" : "days"}; the gap must be at least {recommendation.calculation.minimum_material_gap_calories_kcal.toLocaleString(undefined, { maximumFractionDigits: 1 })} kcal before an option is shown.</p>
              <p>At the recorded frequency, the calculation is about {recommendation.expected_effect.per_occurrence_calories_kcal.toLocaleString(undefined, { maximumFractionDigits: 1 })} kcal each time, {recommendation.expected_effect.period_calories_kcal.toLocaleString(undefined, { maximumFractionDigits: 1 })} kcal across this period, or {recommendation.expected_effect.weekly_calories_kcal.toLocaleString(undefined, { maximumFractionDigits: 1 })} kcal per week. Past diary entries stay unchanged.</p>
              <details className="fitness-module__details"><summary>Evidence and uncertainty</summary><div className="fitness-module__diary-more-body">
            <p><strong>Observation period.</strong> {formatFitnessDate(recommendation.observation_period.start)} to {formatFitnessDate(recommendation.observation_period.end)}: {recommendation.observation_period.logged_days} logged {recommendation.observation_period.logged_days === 1 ? "day" : "days"} across {recommendation.observation_period.calendar_days} calendar days.</p>
            <p><strong>Recorded pattern.</strong> {recommendation.food_or_meal} appears {recommendation.frequency.entries} {recommendation.frequency.entries === 1 ? "time" : "times"} across {recommendation.frequency.days} {recommendation.frequency.days === 1 ? "day" : "days"} ({recommendation.frequency.per_week.toLocaleString(undefined, { maximumFractionDigits: 1 })} times per week), typically {recommendation.typical_amount.value.toLocaleString(undefined, { maximumFractionDigits: 1 })} {recommendation.typical_amount.unit}.</p>
            <p><strong>Why this option.</strong> {recommendation.why_practical}</p>
            <p><strong>Uncertainty.</strong> {recommendation.uncertainty.description} Calories are present for {Math.round(recommendation.uncertainty.nutrient_completeness * 100)}% of entries; {Math.round(recommendation.uncertainty.diary_day_completeness * 100)}% of days in the window have diary entries; targets cover {Math.round(recommendation.uncertainty.target_day_coverage * 100)}% of logged days; {Math.round(recommendation.uncertainty.estimated_entry_share * 100)}% of entries are estimated{recommendation.uncertainty.estimated_calorie_share != null ? `; and those estimates account for ${Math.round(recommendation.uncertainty.estimated_calorie_share * 100)}% of recorded calories.` : "."}</p>
            <div><label className="fitness-module__field fitness-module__contributor-filter">Contributor nutrient<select aria-label="Contributor nutrient" value={contributorMetric} onChange={(event) => setContributorMetric(event.target.value as PeriodContributorKey)}>{periodContributorKeys.map((key) => <option value={key} key={key}>{nutrientLabels[key]}</option>)}</select></label><h4>Largest recorded {contributorMetric === "calories_kcal" ? "Calorie" : nutrientLabels[contributorMetric]} contributors</h4>{periodContributors.length ? <ul className="fitness-module__list">{periodContributors.map((item) => <li key={`${item.item_kind}:${item.item_id}:${item.meal_key}`}><div><strong>{item.label}</strong><small>{titleCase(item.meal_key)} · {item.entry_count} {item.entry_count === 1 ? "entry" : "entries"} across {item.sample_days} {item.sample_days === 1 ? "day" : "days"}{item.typical_amount != null && item.typical_unit ? ` · typical ${item.typical_amount.toLocaleString(undefined, { maximumFractionDigits: 1 })} ${item.typical_unit}` : ""}</small></div><span>{item.total.toLocaleString(undefined, { maximumFractionDigits: 1 })} {nutrientUnits[contributorMetric]}{item.share != null ? ` · ${Math.round(item.share * 100)}%` : ""}</span></li>)}</ul> : <p className="fitness-module__muted">No exact {nutrientLabels[contributorMetric].toLocaleLowerCase()} contributors are available for this period.</p>}</div>
              </div></details>
            </div> : analysis.loading ? <p className="fitness-module__muted" role="status">Checking the selected diary period…</p> : analysis.error ? <div className="fitness-module__notice fitness-module__notice--error" role="alert"><span>Diary patterns for this period could not be loaded.</span><button type="button" className="button button--secondary button--compact" onClick={analysis.reload}>Try again</button></div> : <p className="fitness-module__muted">No calculated change is shown for this period. HausKlar needs enough complete diary days, saved targets for those days, and an average that is clearly above them before suggesting one.</p>}
          </div>
        </details>
        <details className="fitness-module__details"><summary>Fibre and other nutrients</summary><div className="fitness-module__stats">{(["fibre_g", "saturated_fat_g", "sugars_g", "salt_g"] as FitnessNutrientKey[]).map((key) => <FitnessStat key={key} label={nutrientLabels[key]} value={formatNutrient(totals[key], key)} detail={uncertain.has(key) ? "Some entries are unknown" : undefined} />)}</div></details>
      </FitnessCard>

      <div className="fitness-module__diary-meals">
        {diaryMealGroups.map((group) => {
          const mealEntries = entries.filter((entry) => group.entryKeys.includes(entry.meal_key as FitnessMealKey));
          const mealTotals = aggregateNutritionEntries(mealEntries, foods.data).totals;
          return <FitnessCard className="fitness-module__diary-meal" key={group.key}>
            <header className="fitness-module__diary-meal-heading"><div><h3>{group.label}</h3><p>{formatNutrient(mealTotals.calories_kcal, "calories_kcal")} · {formatNutrient(mealTotals.protein_g, "protein_g")} protein</p></div><button type="button" className="button button--secondary" onClick={() => openAddFood(group.addAs)}><Plus aria-hidden="true" size={15} /> Add food</button></header>
            {mealEntries.length ? <ul className="fitness-module__list fitness-module__diary-entry-list">{mealEntries.map((entry) => { const food = foods.data.find((candidate) => currentFoodVersion(candidate)?.id === entry.food_version_id || candidate.versions?.some((version) => version.id === entry.food_version_id)); const recipe = recipes.data.find((candidate) => candidate.current_version?.id === entry.recipe_version_id || candidate.versions?.some((version) => version.id === entry.recipe_version_id)); const nutrients = aggregateNutritionEntries([entry], foods.data).totals; const label = entry.food_name ?? food?.name ?? recipe?.name ?? "Saved item"; return <li key={entry.id}><div><strong>{label}</strong><small>{entry.entered_amount} {entry.entered_unit}{group.key === "snacks" ? ` · ${titleCase(entry.meal_key)}` : ""} · {titleCase(entry.measurement_quality ?? "unknown")}</small>{entry.queued_offline ? <small>Saved on this device · waiting to sync</small> : null}</div><div className="fitness-module__list-actions"><span>{formatNutrient(nutrients.calories_kcal, "calories_kcal")}</span><details className="fitness-module__row-menu"><summary aria-label={`More actions for ${label}`}><MoreHorizontal aria-hidden="true" size={18} /></summary><div className="fitness-module__row-menu-actions"><button type="button" className="button button--secondary button--compact" aria-label={`Edit ${label}`} onClick={() => editEntry(entry)}><Pencil aria-hidden="true" size={14} /> Edit</button><button type="button" className="button button--secondary button--compact" aria-label={`Delete ${label}`} onClick={() => setConfirmDelete(entry)}><Trash2 aria-hidden="true" size={14} /> Remove</button></div></details></div></li>; })}</ul> : <div className="fitness-module__diary-empty"><span>Nothing logged.</span><button type="button" onClick={() => openAddFood(group.addAs)}>Add {group.label.toLocaleLowerCase()}</button></div>}
            {mealEntries.length || group.key === "breakfast" ? <details className="fitness-module__details"><summary>Meal actions</summary><div className="fitness-module__button-row">{group.key === "breakfast" ? <button type="button" className="button button--secondary button--compact" disabled={copyingYesterdayBreakfast || batchSave.saving} onClick={() => void copyYesterdayBreakfast()}><Copy aria-hidden="true" size={14} /> {copyingYesterdayBreakfast ? "Copying…" : "Copy yesterday’s breakfast"}</button> : null}{mealEntries.length ? <><button type="button" className="button button--secondary button--compact" disabled={batchSave.saving} onClick={() => void repeat(group.entryKeys)}>Repeat {group.label.toLocaleLowerCase()}</button><button type="button" className="button button--secondary button--compact" onClick={() => { setTemplateMeal(group.addAs); setTemplateName(`${group.label} template`); }}>Save as template</button></> : null}</div></details> : null}
          </FitnessCard>;
        })}
      </div>

      {entries.length ? <FitnessCard className="fitness-module__diary-more"><details className="fitness-module__details"><summary>More diary actions and evidence</summary><div className="fitness-module__diary-more-body"><div className="fitness-module__repeat-row"><label className="fitness-module__field">Repeat into<input type="date" value={repeatTargetDate} onChange={(event) => setRepeatTargetDate(event.target.value)} /></label><button type="button" className="button button--secondary" disabled={batchSave.saving} onClick={() => void repeat()}>Repeat whole day</button></div>{day.data.contributors?.length ? <div><h4>What contributed</h4><ul className="fitness-module__list">{day.data.contributors.slice(0, 8).map((item) => <li key={`${item.nutrient_key}:${item.key}`}><div><strong>{item.label}</strong><small>{titleCase(item.kind)} · {item.entry_count ?? 1} entries</small></div><span>{item.value.toLocaleString(undefined, { maximumFractionDigits: 1 })} {item.nutrient_key === "calories_kcal" ? "kcal" : "g"}</span></li>)}</ul></div> : null}</div></details>{repeatError ? <p className="fitness-module__form-status is-error" role="alert">{repeatError}</p> : null}<FitnessFormStatus saving={batchSave.saving} saved={batchSave.saved} error={batchSave.saveError} /></FitnessCard> : null}
    </> : null}

    {confirmDelete ? <FitnessCard title="Remove diary entry?" detail="Past history is kept after removal."><p>{confirmDelete.food_name ?? "This saved item"} will disappear from the diary after you confirm.</p><div className="fitness-module__button-row"><button type="button" className="button button--danger" disabled={deleting} onClick={() => void deleteEntry(confirmDelete)}>{deleting ? "Removing…" : "Remove entry"}</button><button type="button" className="button button--secondary" disabled={deleting} onClick={() => { setConfirmDelete(null); setDeleteError(null); }}>Keep it</button></div>{deleteError ? <p className="fitness-module__form-status is-error" role="alert">{deleteError}</p> : null}</FitnessCard> : null}

    {templateMeal ? <FitnessCard title="Save current meal as a template" detail="Logging the template later still creates separate analysable diary entries."><form className="fitness-module__form" onSubmit={submitForm(saveMealTemplate)}><div className="fitness-module__fields"><label className="fitness-module__field is-wide">Template name<input required autoFocus value={templateName} onChange={(event) => setTemplateName(event.target.value)} /></label></div><div className="fitness-module__form-footer"><button type="submit" className="button button--primary" disabled={templateSave.saving || !templateName.trim()}>Save meal template</button><button type="button" className="button button--secondary" onClick={() => setTemplateMeal(null)}>Cancel</button><FitnessFormStatus saving={templateSave.saving} saved={templateSave.saved} error={templateSave.saveError} /></div></form></FitnessCard> : null}
  </div>;
}

type FoodEditorState = {
  mode: "create" | "duplicate" | "version";
  name: string;
  brand: string;
  category: string;
  barcode: string;
  notes: string;
  householdShared: boolean;
  favourite: boolean;
  referenceAmount: string;
  referenceUnit: "g" | "ml" | "item" | "serving" | "custom";
  energyMode: "printed_kcal" | "kj_only" | "unknown";
  calories: string;
  labelKj: string;
  protein: string;
  carbohydrate: string;
  sugars: string;
  fat: string;
  saturatedFat: string;
  fibre: string;
  salt: string;
  sourceType: string;
  sourceNote: string;
  confidence: string;
};

type DetectedBarcode = { rawValue: string };
type BrowserBarcodeDetector = {
  detect(source: HTMLVideoElement): Promise<DetectedBarcode[]>;
};
type BrowserBarcodeDetectorConstructor = {
  new(options?: { formats?: string[] }): BrowserBarcodeDetector;
  getSupportedFormats?: () => Promise<string[]>;
};

function barcodeDetectorConstructor(): BrowserBarcodeDetectorConstructor | null {
  if (typeof window === "undefined") return null;
  return (window as unknown as { BarcodeDetector?: BrowserBarcodeDetectorConstructor }).BarcodeDetector ?? null;
}

export function FitnessBarcodeScanner({
  onDetected,
  onClose,
}: {
  onDetected: (barcode: string) => void;
  onClose: () => void;
}) {
  const videoRef = useRef<HTMLVideoElement>(null);
  const [error, setError] = useState<string | null>(null);
  const [status, setStatus] = useState("Starting the rear camera…");

  useEffect(() => {
    let stopped = false;
    let frame = 0;
    let stream: MediaStream | null = null;

    const stopStream = () => {
      stopped = true;
      if (frame) window.cancelAnimationFrame(frame);
      stream?.getTracks().forEach((track) => track.stop());
      stream = null;
      if (videoRef.current) videoRef.current.srcObject = null;
    };

    const start = async () => {
      const Detector = barcodeDetectorConstructor();
      if (!Detector || !navigator.mediaDevices?.getUserMedia) {
        setError("Camera barcode scanning is not supported by this browser. Enter the digits instead.");
        return;
      }
      try {
        const preferredFormats = ["ean_13", "ean_8", "upc_a", "upc_e", "itf", "code_128"];
        const supportedFormats = Detector.getSupportedFormats ? await Detector.getSupportedFormats() : preferredFormats;
        const formats = preferredFormats.filter((format) => supportedFormats.includes(format));
        const detector = formats.length ? new Detector({ formats }) : new Detector();
        const nextStream = await navigator.mediaDevices.getUserMedia({
          audio: false,
          video: { facingMode: { ideal: "environment" } },
        });
        if (stopped) {
          nextStream.getTracks().forEach((track) => track.stop());
          return;
        }
        stream = nextStream;
        const video = videoRef.current;
        if (!video) {
          stopStream();
          return;
        }
        video.srcObject = stream;
        await video.play();
        setStatus("Point the rear camera at the product barcode.");

        const scan = async () => {
          if (stopped) return;
          try {
            const matches = await detector.detect(video);
            const barcode = matches
              .map((match) => match.rawValue.replaceAll(" ", ""))
              .find((value) => /^\d{8,14}$/.test(value));
            if (barcode) {
              stopStream();
              onDetected(barcode);
              return;
            }
          } catch {
            // Individual frames can be unreadable while the camera is moving.
          }
          if (!stopped) frame = window.requestAnimationFrame(() => void scan());
        };
        frame = window.requestAnimationFrame(() => void scan());
      } catch {
        stopStream();
        setError("The camera could not be opened. Check browser permission, or enter the barcode digits instead.");
      }
    };

    const onKeyDown = (event: KeyboardEvent) => {
      if (event.key !== "Escape") return;
      event.preventDefault();
      onClose();
    };
    document.addEventListener("keydown", onKeyDown);
    void start();
    return () => {
      document.removeEventListener("keydown", onKeyDown);
      stopStream();
    };
  }, [onClose, onDetected]);

  return <div className="fitness-module__barcode-scanner" role="region" aria-labelledby="fitness-barcode-scanner-title">
    <div className="fitness-module__barcode-scanner-heading"><div><strong id="fitness-barcode-scanner-title">Scan a barcode</strong><small>Nothing is saved until you review the returned food and choose Save.</small></div><button type="button" className="button button--secondary button--compact" autoFocus onClick={onClose}>Stop camera</button></div>
    <video ref={videoRef} muted playsInline aria-label="Live rear-camera barcode view" />
    {error ? <p className="fitness-module__form-status is-error" role="alert">{error}</p> : <p className="fitness-module__muted" role="status">{status}</p>}
  </div>;
}

function blankFoodEditor(): FoodEditorState {
  return {
    mode: "create",
    name: "",
    brand: "",
    category: "",
    barcode: "",
    notes: "",
    householdShared: false,
    favourite: false,
    referenceAmount: "100",
    referenceUnit: "g",
    energyMode: "printed_kcal",
    calories: "",
    labelKj: "",
    protein: "",
    carbohydrate: "",
    sugars: "",
    fat: "",
    saturatedFat: "",
    fibre: "",
    salt: "",
    sourceType: "manual",
    sourceNote: "",
    confidence: "measured",
  };
}

function editorFromFood(food: FitnessFood, mode: FoodEditorState["mode"]): FoodEditorState {
  const version = currentFoodVersion(food);
  return {
    ...blankFoodEditor(),
    mode,
    name: mode === "duplicate" ? `${food.name} copy` : food.name,
    brand: food.brand ?? "",
    category: food.category_key ?? "",
    barcode: mode === "duplicate" ? "" : food.barcode ?? "",
    notes: food.notes ?? "",
    householdShared: mode === "duplicate" ? false : food.household_shared ?? false,
    favourite: mode === "duplicate" ? false : food.favourite ?? false,
    referenceAmount: String(version?.reference_amount ?? 100),
    referenceUnit: (version?.reference_unit as FoodEditorState["referenceUnit"]) ?? "g",
    energyMode: version?.source_energy_unit === "kj" && version.calories_kcal != null && Math.abs(version.calories_kcal - (version.source_energy_value ?? 0) / 4.184) < 0.001 ? "kj_only" : version?.calories_kcal == null ? "unknown" : "printed_kcal",
    calories: version?.calories_kcal == null ? "" : String(version.calories_kcal),
    labelKj: version?.source_energy_unit === "kj" && version.source_energy_value != null ? String(version.source_energy_value) : "",
    protein: version?.protein_g == null ? "" : String(version.protein_g),
    carbohydrate: version?.carbohydrate_g == null ? "" : String(version.carbohydrate_g),
    sugars: version?.sugars_g == null ? "" : String(version.sugars_g),
    fat: version?.fat_g == null ? "" : String(version.fat_g),
    saturatedFat: version?.saturated_fat_g == null ? "" : String(version.saturated_fat_g),
    fibre: version?.fibre_g == null ? "" : String(version.fibre_g),
    salt: version?.salt_g == null ? "" : String(version.salt_g),
    sourceType: version?.source_type ?? "manual",
    sourceNote: version?.source_note ?? "",
    confidence: version?.confidence ?? "measured",
  };
}

function foodVersionPayload(editor: FoodEditorState): Record<string, unknown> {
  const printedKcal = numberOrNull(editor.calories);
  const sourceKj = numberOrNull(editor.labelKj);
  const caloriesKcal = editor.energyMode === "unknown"
    ? null
    : authoritativeCalories({
      caloriesKcal: editor.energyMode === "printed_kcal" ? printedKcal : null,
      sourceEnergyValue: editor.energyMode === "kj_only" ? sourceKj : null,
      sourceEnergyUnit: editor.energyMode === "kj_only" ? "kj" : null,
    });
  return {
    reference_amount: Number(editor.referenceAmount),
    reference_unit: editor.referenceUnit,
    calories_kcal: caloriesKcal,
    source_energy_value: editor.energyMode === "unknown" ? null : editor.energyMode === "kj_only" ? sourceKj : sourceKj ?? printedKcal,
    source_energy_unit: editor.energyMode === "unknown" ? null : editor.energyMode === "kj_only" || sourceKj != null ? "kj" : "kcal",
    protein_g: numberOrNull(editor.protein),
    carbohydrate_g: numberOrNull(editor.carbohydrate),
    sugars_g: numberOrNull(editor.sugars),
    fat_g: numberOrNull(editor.fat),
    saturated_fat_g: numberOrNull(editor.saturatedFat),
    fibre_g: numberOrNull(editor.fibre),
    salt_g: numberOrNull(editor.salt),
    sodium_mg: null,
    micronutrients: {},
    source_type: editor.sourceType,
    source_note: editor.sourceNote.trim() || null,
    confidence: editor.confidence,
  };
}

function foodPayload(editor: FoodEditorState): Record<string, unknown> {
  return {
    name: editor.name.trim(),
    brand: editor.brand.trim() || null,
    category_key: editor.category.trim() || null,
    barcode: editor.barcode.trim() || null,
    notes: editor.notes.trim() || null,
    household_shared: editor.householdShared,
    favourite: editor.favourite,
    active: true,
    version: { id: crypto.randomUUID(), ...foodVersionPayload(editor) },
  };
}

export function FitnessFoodCataloguePanel({ online, revision, onDataChanged, openCreateRequest }: FitnessViewProps & { openCreateRequest: number }) {
  const foods = useFitnessCollection<FitnessFood>("/fitness/foods", "food", revision);
  const foodSave = useFitnessSave(() => { onDataChanged(); foods.reload(); });
  const servingSave = useFitnessSave(() => { onDataChanged(); foods.reload(); });
  const [query, setQuery] = useState("");
  const [includeArchived, setIncludeArchived] = useState(false);
  const [selectedId, setSelectedId] = useState<string | null>(null);
  const [editor, setEditor] = useState<FoodEditorState | null>(null);
  const [labelFile, setLabelFile] = useState<File | null>(null);
  const [identityEdit, setIdentityEdit] = useState(false);
  const [identityName, setIdentityName] = useState("");
  const [identityBrand, setIdentityBrand] = useState("");
  const [identityNotes, setIdentityNotes] = useState("");
  const [servingForm, setServingForm] = useState(false);
  const [servingName, setServingName] = useState("");
  const [servingAmount, setServingAmount] = useState("1");
  const [servingUnit, setServingUnit] = useState("slice");
  const [servingCanonicalAmount, setServingCanonicalAmount] = useState("");
  const [servingCanonicalUnit, setServingCanonicalUnit] = useState("g");
  const [servingQuality, setServingQuality] = useState<FitnessNutritionMeasurementQuality>("standard_serving");
  const [servingDefault, setServingDefault] = useState(false);
  const [confirmArchive, setConfirmArchive] = useState(false);
  const [mergeTargetId, setMergeTargetId] = useState("");
  const [mergePreview, setMergePreview] = useState<FitnessFoodMergePreview | null>(null);
  const [mergeBusy, setMergeBusy] = useState(false);
  const [mergeError, setMergeError] = useState<string | null>(null);
  const [labels, setLabels] = useState<fitnessOffline.FitnessPendingNutritionLabel[]>([]);
  const [localError, setLocalError] = useState<string | null>(null);
  const [barcodeLookupBusy, setBarcodeLookupBusy] = useState(false);
  const [barcodeLookupError, setBarcodeLookupError] = useState<string | null>(null);
  const [barcodeWarnings, setBarcodeWarnings] = useState<string[]>([]);
  const [barcodeScannerOpen, setBarcodeScannerOpen] = useState(false);
  const previousCreateRequest = useRef(0);
  const barcodeScanButtonRef = useRef<HTMLButtonElement>(null);

  const refreshLabels = useCallback(() => {
    if (typeof fitnessOffline.fitnessNutritionLabelsOnDevice !== "function") return;
    void fitnessOffline.fitnessNutritionLabelsOnDevice().then(setLabels).catch(() => undefined);
  }, []);

  useEffect(() => {
    const changed = () => refreshLabels();
    window.addEventListener("hausklar:fitness-nutrition-labels-changed", changed);
    refreshLabels();
    if (online && typeof fitnessOffline.flushFitnessNutritionLabels === "function") {
      void fitnessOffline.flushFitnessNutritionLabels().then(setLabels).catch(() => undefined);
    }
    return () => window.removeEventListener("hausklar:fitness-nutrition-labels-changed", changed);
  }, [online, refreshLabels]);

  useEffect(() => {
    if (openCreateRequest > previousCreateRequest.current) {
      setEditor(blankFoodEditor());
      setSelectedId(null);
      previousCreateRequest.current = openCreateRequest;
    }
  }, [openCreateRequest]);

  useEffect(() => {
    if (!editor) setBarcodeScannerOpen(false);
  }, [editor]);

  const displayedFoods = useMemo(() => {
    const normalised = query.trim().toLocaleLowerCase();
    return [...foods.data]
      .filter((food) => includeArchived || food.active !== false)
      .filter((food) => !normalised || [food.name, food.brand, ...(food.search_aliases ?? food.aliases ?? [])].filter(Boolean).join(" ").toLocaleLowerCase().includes(normalised))
      .sort((left, right) => Number(Boolean(right.favourite)) - Number(Boolean(left.favourite)) || left.name.localeCompare(right.name));
  }, [foods.data, includeArchived, query]);
  const selected = foods.data.find((food) => food.id === selectedId) ?? null;

  function closeBarcodeScanner() {
    setBarcodeScannerOpen(false);
    window.requestAnimationFrame(() => barcodeScanButtonRef.current?.focus({ preventScroll: true }));
  }

  function selectFood(food: FitnessFood) {
    setSelectedId(food.id);
    setEditor(null);
    setIdentityEdit(false);
    setServingForm(false);
    setIdentityName(food.name);
    setIdentityBrand(food.brand ?? "");
    setIdentityNotes(food.notes ?? "");
    setMergeTargetId("");
    setMergePreview(null);
    setConfirmArchive(false);
  }

  async function saveFoodEditor() {
    if (!editor) return;
    if (editor.mode === "version" && selected?.editable === false) return;
    setLocalError(null);
    const versionId = crypto.randomUUID();
    try {
      if (editor.mode === "version" && selected) {
        const payload = { id: versionId, food_id: selected.id, ...foodVersionPayload(editor) };
        if (labelFile && typeof fitnessOffline.queueFitnessNutritionLabel === "function") {
          await fitnessOffline.queueFitnessNutritionLabel(labelFile, { entityType: "food_version", payload, options: { entityId: versionId } });
          onDataChanged();
        } else {
          await foodSave.save("food_version", payload, { entityId: versionId });
        }
      } else {
        const payload = foodPayload(editor);
        const foodId = crypto.randomUUID();
        if (labelFile && typeof fitnessOffline.queueFitnessNutritionLabel === "function") {
          await fitnessOffline.queueFitnessNutritionLabel(labelFile, { entityType: "food", payload, options: { entityId: foodId } });
          onDataChanged();
        } else {
          await foodSave.save("food", payload, { entityId: foodId });
        }
        setSelectedId(foodId);
      }
      setEditor(null);
      setLabelFile(null);
      foods.reload();
      refreshLabels();
    } catch (error) {
      setLocalError(errorMessage(error));
    }
  }

  async function lookUpBarcode(barcodeOverride?: string) {
    const barcode = (barcodeOverride ?? editor?.barcode ?? "").trim();
    if (!editor || !/^\d{8,14}$/.test(barcode) || barcodeLookupBusy) return;
    setBarcodeLookupBusy(true);
    setBarcodeLookupError(null);
    setBarcodeWarnings([]);
    try {
      const result = await api<FitnessFoodBarcodeLookup>(`/fitness/food-lookup/barcode/${encodeURIComponent(barcode)}`, {}, true, false);
      const nutrient = (value?: number | null) => value == null ? "" : String(value);
      setEditor((current) => current ? {
        ...current,
        name: result.name,
        brand: result.brand ?? "",
        barcode: result.barcode,
        referenceAmount: String(result.reference_amount),
        referenceUnit: result.reference_unit,
        energyMode: result.nutrients.calories_kcal == null ? "unknown" : "printed_kcal",
        calories: nutrient(result.nutrients.calories_kcal),
        protein: nutrient(result.nutrients.protein_g),
        carbohydrate: nutrient(result.nutrients.carbohydrate_g),
        sugars: nutrient(result.nutrients.sugars_g),
        fat: nutrient(result.nutrients.fat_g),
        saturatedFat: nutrient(result.nutrients.saturated_fat_g),
        fibre: nutrient(result.nutrients.fibre_g),
        salt: nutrient(result.nutrients.salt_g),
        sourceType: result.source,
        sourceNote: result.source_url,
        confidence: "copied",
      } : current);
      setBarcodeWarnings([
        ...result.warnings,
        ...(result.serving ? [`Reported serving: ${result.serving.name}, ${result.serving.amount} ${result.serving.unit}. Review before saving.`] : []),
      ]);
    } catch (requestError) {
      setBarcodeLookupError(errorMessage(requestError));
    } finally {
      setBarcodeLookupBusy(false);
    }
  }

  async function saveIdentity() {
    if (!selected || selected.editable === false || !identityName.trim()) return;
    await foodSave.save("food", foodIdentityPayload(selected, {
      name: identityName.trim(),
      brand: identityBrand.trim() || null,
      notes: identityNotes.trim() || null,
    }), { entityId: selected.id, baseRevision: selected.revision ?? null });
    setIdentityEdit(false);
  }

  async function toggleFavourite(food: FitnessFood) {
    if (food.editable === false) return;
    await foodSave.save("food", foodIdentityPayload(food, { favourite: !food.favourite }), {
      entityId: food.id,
      baseRevision: food.revision ?? null,
    });
  }

  async function archiveFood() {
    if (!selected || selected.editable === false) return;
    await foodSave.save("food", foodIdentityPayload(selected, { active: false }), {
      entityId: selected.id,
      baseRevision: selected.revision ?? null,
    });
    setConfirmArchive(false);
  }

  async function addServing() {
    if (!selected || selected.editable === false) return;
    await servingSave.save("food_serving", {
      food_id: selected.id,
      name: servingName.trim(),
      amount: Number(servingAmount),
      unit: servingUnit.trim(),
      canonical_amount: Number(servingCanonicalAmount),
      canonical_unit: servingCanonicalUnit,
      measurement_quality: servingQuality,
      is_default: servingDefault,
      active: true,
    });
    setServingForm(false);
    setServingName("");
    setServingCanonicalAmount("");
  }

  async function previewMerge() {
    const target = foods.data.find((food) => food.id === mergeTargetId);
    if (!selected || selected.editable === false || !target || target.editable === false) return;
    setMergeBusy(true);
    setMergeError(null);
    setMergePreview(null);
    try {
      setMergePreview(await api<FitnessFoodMergePreview>("/fitness/foods/merge/preview", {
        method: "POST",
        body: JSON.stringify({ source_id: selected.id, target_id: mergeTargetId }),
      }, true, false));
    } catch (error) {
      setMergeError(errorMessage(error));
    } finally {
      setMergeBusy(false);
    }
  }

  async function confirmMerge() {
    if (!mergePreview) return;
    const source = foods.data.find((food) => food.id === mergePreview.source_id);
    const target = foods.data.find((food) => food.id === mergePreview.target_id);
    if (!source || source.editable === false || !target || target.editable === false) return;
    setMergeBusy(true);
    setMergeError(null);
    try {
      await api<FitnessFoodMergePreview>("/fitness/foods/merge", {
        method: "POST",
        body: JSON.stringify({ source_id: mergePreview.source_id, target_id: mergePreview.target_id }),
      }, true, false);
      setSelectedId(mergePreview.target_id);
      setMergePreview(null);
      setMergeTargetId("");
      onDataChanged();
      foods.reload();
    } catch (error) {
      setMergeError(errorMessage(error));
    } finally {
      setMergeBusy(false);
    }
  }

  const energyPreview = editor ? authoritativeCalories({
    caloriesKcal: editor.energyMode === "printed_kcal" ? numberOrNull(editor.calories) : null,
    sourceEnergyValue: editor.energyMode === "kj_only" ? numberOrNull(editor.labelKj) : null,
    sourceEnergyUnit: editor.energyMode === "kj_only" ? "kj" : null,
  }) : null;

  return <div className="fitness-module__nutrition-stack">

    {editor ? <FitnessCard title={editor.mode === "create" ? "Add food" : editor.mode === "duplicate" ? "Duplicate food" : "Update nutrition details"} detail="Copy the package values you use. Existing diary entries stay unchanged.">
      <form className="fitness-module__form" onSubmit={submitForm(saveFoodEditor)}>
        {editor.mode !== "version" ? <div className="fitness-module__fields">
          <label className="fitness-module__field">Food name<input required autoFocus value={editor.name} onChange={(event) => setEditor({ ...editor, name: event.target.value })} placeholder="Greek yoghurt" /></label>
          <label className="fitness-module__field">Brand (optional)<input value={editor.brand} onChange={(event) => setEditor({ ...editor, brand: event.target.value })} /></label>
          <label className="fitness-module__field">Category (optional)<input value={editor.category} onChange={(event) => setEditor({ ...editor, category: event.target.value })} /></label>
          <div className="fitness-module__field"><label htmlFor="fitness-food-barcode">Barcode (optional)</label><div className="fitness-module__button-row"><input id="fitness-food-barcode" inputMode="numeric" pattern="[0-9]{8,14}" value={editor.barcode} onChange={(event) => { const barcode = event.target.value; setEditor({ ...editor, barcode, ...(editor.sourceType === "open_food_facts" ? { sourceType: "manual", sourceNote: "", confidence: "measured" } : {}) }); setBarcodeLookupError(null); setBarcodeWarnings([]); }} /><button type="button" className="button button--secondary button--compact" disabled={!online || barcodeLookupBusy || !/^\d{8,14}$/.test(editor.barcode.trim())} onClick={() => void lookUpBarcode()}>{barcodeLookupBusy ? "Looking up…" : "Look up"}</button>{barcodeDetectorConstructor() && typeof navigator.mediaDevices?.getUserMedia === "function" ? <button ref={barcodeScanButtonRef} type="button" className="button button--secondary button--compact" onClick={() => setBarcodeScannerOpen(true)}><Camera aria-hidden="true" size={15} /> Scan</button> : null}</div><small>Type 8–14 digits, or use the rear camera where supported.</small></div>
          <label className="fitness-module__field is-wide">Notes (optional)<input value={editor.notes} onChange={(event) => setEditor({ ...editor, notes: event.target.value })} /></label>
          <label className="fitness-module__check"><input type="checkbox" checked={editor.favourite} onChange={(event) => setEditor({ ...editor, favourite: event.target.checked })} /> Add to favourites</label>
          <label className="fitness-module__check"><input type="checkbox" checked={editor.householdShared} onChange={(event) => setEditor({ ...editor, householdShared: event.target.checked })} /> Share this definition with the household</label>
        </div> : <div className="fitness-module__callout"><strong>{selected?.name}</strong><p>Only nutrition changes. Existing diary entries keep their copied totals and old version.</p></div>}
        {barcodeScannerOpen ? <FitnessBarcodeScanner onClose={closeBarcodeScanner} onDetected={(barcode) => { setEditor((current) => current ? { ...current, barcode } : current); closeBarcodeScanner(); void lookUpBarcode(barcode); }} /> : null}
        <div className="fitness-module__fields">
          <label className="fitness-module__field">Nutrition basis<input type="number" inputMode="decimal" min="0.01" step="any" required value={editor.referenceAmount} onChange={(event) => setEditor({ ...editor, referenceAmount: event.target.value })} /></label>
          <label className="fitness-module__field">Basis unit<select value={editor.referenceUnit} onChange={(event) => setEditor({ ...editor, referenceUnit: event.target.value as FoodEditorState["referenceUnit"] })}><option value="g">grams</option><option value="ml">millilitres</option><option value="item">item</option><option value="serving">serving</option><option value="custom">custom</option></select></label>
          <label className="fitness-module__field">Energy shown<select value={editor.energyMode} onChange={(event) => setEditor({ ...editor, energyMode: event.target.value as FoodEditorState["energyMode"] })}><option value="printed_kcal">Calories/kcal</option><option value="kj_only">kJ only</option><option value="unknown">Not shown</option></select></label>
          {editor.energyMode === "printed_kcal" ? <label className="fitness-module__field">Calories (kcal)<input type="number" inputMode="decimal" min="0" step="any" required value={editor.calories} onChange={(event) => setEditor({ ...editor, calories: event.target.value })} /></label> : null}
          {editor.energyMode !== "unknown" ? <label className="fitness-module__field">Printed kJ (optional{editor.energyMode === "kj_only" ? ", required" : ""})<input type="number" inputMode="decimal" min="0" step="any" required={editor.energyMode === "kj_only"} value={editor.labelKj} onChange={(event) => setEditor({ ...editor, labelKj: event.target.value })} /></label> : null}
          {editor.energyMode === "kj_only" && energyPreview != null ? <div className="fitness-module__field"><span>Calories</span><strong>{energyPreview.toLocaleString(undefined, { maximumFractionDigits: 2 })} kcal</strong><small>Converted from the package kJ value.</small></div> : null}
          <label className="fitness-module__field">Protein (g)<input type="number" inputMode="decimal" min="0" step="any" value={editor.protein} onChange={(event) => setEditor({ ...editor, protein: event.target.value })} /></label>
          <label className="fitness-module__field">Carbohydrate (g)<input type="number" inputMode="decimal" min="0" step="any" value={editor.carbohydrate} onChange={(event) => setEditor({ ...editor, carbohydrate: event.target.value })} /></label>
          <label className="fitness-module__field">Sugar (g)<input type="number" inputMode="decimal" min="0" step="any" value={editor.sugars} onChange={(event) => setEditor({ ...editor, sugars: event.target.value })} /></label>
          <label className="fitness-module__field">Fat (g)<input type="number" inputMode="decimal" min="0" step="any" value={editor.fat} onChange={(event) => setEditor({ ...editor, fat: event.target.value })} /></label>
          <label className="fitness-module__field">Saturated fat (g)<input type="number" inputMode="decimal" min="0" step="any" value={editor.saturatedFat} onChange={(event) => setEditor({ ...editor, saturatedFat: event.target.value })} /></label>
          <label className="fitness-module__field">Fibre (g)<input type="number" inputMode="decimal" min="0" step="any" value={editor.fibre} onChange={(event) => setEditor({ ...editor, fibre: event.target.value })} /></label>
          <label className="fitness-module__field">Salt (g)<input type="number" inputMode="decimal" min="0" step="any" value={editor.salt} onChange={(event) => setEditor({ ...editor, salt: event.target.value })} /></label>
          <label className="fitness-module__field is-wide"><span><Camera aria-hidden="true" size={16} /> Nutrition-label photo (optional)</span><input type="file" accept="image/jpeg,image/png,image/heic,image/heif,.jpg,.jpeg,.png,.heic,.heif" onChange={(event) => setLabelFile(event.target.files?.[0] ?? null)} /><small>Attach the label you used so you can check it later.</small></label>
        </div>
        {barcodeWarnings.length ? <div className="fitness-module__notice" role="status"><strong>Review lookup values</strong><ul>{barcodeWarnings.map((warning) => <li key={warning}>{warning}</li>)}</ul></div> : null}
        {barcodeLookupError ? <div className="fitness-module__notice fitness-module__notice--error" role="alert">{barcodeLookupError}</div> : null}
        {editor.householdShared ? <p className="fitness-module__privacy-note"><Heart aria-hidden="true" size={16} /> Only the reusable definition is shared. Your consumption and diary remain private.</p> : null}
        <div className="fitness-module__form-footer"><button type="submit" className="button button--primary" disabled={foodSave.saving || !editor.referenceAmount || (editor.mode !== "version" && !editor.name.trim()) || (editor.energyMode === "printed_kcal" && !editor.calories) || (editor.energyMode === "kj_only" && !editor.labelKj)}>Save food</button><button type="button" className="button button--secondary" onClick={() => { setEditor(null); setLabelFile(null); }}>Cancel</button><FitnessFormStatus saving={foodSave.saving} saved={foodSave.saved} error={foodSave.saveError ?? localError} /></div>
      </form>
    </FitnessCard> : null}

    <FitnessLoadingOrError loading={foods.loading} error={foods.error} retry={foods.reload} />
    {!foods.loading ? <div className="fitness-module__nutrition-split">
      <FitnessCard title="Food catalogue" detail={`${displayedFoods.length} matching ${displayedFoods.length === 1 ? "food" : "foods"}`}>
        <div className="fitness-module__fields"><label className="fitness-module__field is-wide"><span><Search aria-hidden="true" size={15} /> Search foods and old aliases</span><input type="search" value={query} onChange={(event) => setQuery(event.target.value)} placeholder="Name, brand, or merged alias" /></label><label className="fitness-module__check"><input type="checkbox" checked={includeArchived} onChange={(event) => setIncludeArchived(event.target.checked)} /> Show archived</label></div>
        {displayedFoods.length ? <ul className="fitness-module__catalogue-list">{displayedFoods.map((food) => { const version = currentFoodVersion(food); return <li key={food.id}><button type="button" className={selectedId === food.id ? "is-active" : undefined} onClick={() => selectFood(food)}><span><strong>{food.name}</strong><small>{food.editable === false ? `${food.brand ? `${food.brand} · ` : ""}Household definition` : food.brand || "Private food"}{food.search_aliases?.length ? ` · ${food.search_aliases.length} aliases` : ""}</small><small>{version ? `${formatNutrient(version.calories_kcal, "calories_kcal")} per ${version.reference_amount} ${version.reference_unit}` : "Awaiting first version"}</small></span><span>{food.favourite ? <Star aria-label="Favourite" size={16} fill="currentColor" /> : null}{food.active === false ? <Archive aria-label="Archived" size={16} /> : <ChevronRight aria-hidden="true" size={16} />}</span></button></li>; })}</ul> : <div className="fitness-module__empty"><strong>No matching food</strong><span>Add it once, then reuse its saved nutrition details.</span></div>}
      </FitnessCard>

      <div className="fitness-module__nutrition-detail">
        {selected ? <>
          <FitnessCard title={selected.name} detail={selected.editable === false ? "Household definition · readable and loggable, owned by another family member" : selected.brand ?? "Owner-private definition"}>
            {selected.editable === false ? <><div className="fitness-module__notice" role="status"><Heart aria-hidden="true" size={16} /><span>This shared definition can be logged, but only its owner can change versions, servings, favourites, archive state, or merge it.</span></div><div className="fitness-module__button-row"><button type="button" className="button button--primary" onClick={() => setEditor(editorFromFood(selected, "duplicate"))}><Copy aria-hidden="true" size={15} /> Copy to my foods</button></div>{selected.notes ? <p>{selected.notes}</p> : null}</> : identityEdit ? <form className="fitness-module__form" onSubmit={submitForm(saveIdentity)}><div className="fitness-module__fields"><label className="fitness-module__field">Name<input required autoFocus value={identityName} onChange={(event) => setIdentityName(event.target.value)} /></label><label className="fitness-module__field">Brand<input value={identityBrand} onChange={(event) => setIdentityBrand(event.target.value)} /></label><label className="fitness-module__field is-wide">Notes<input value={identityNotes} onChange={(event) => setIdentityNotes(event.target.value)} /></label></div><div className="fitness-module__form-footer"><button type="submit" className="button button--primary" disabled={foodSave.saving}>Save details</button><button type="button" className="button button--secondary" onClick={() => setIdentityEdit(false)}>Cancel</button></div></form> : <><div className="fitness-module__button-row"><button type="button" className="button button--secondary" onClick={() => setIdentityEdit(true)}><Pencil aria-hidden="true" size={15} /> Edit details</button><button type="button" className="button button--secondary" onClick={() => void toggleFavourite(selected)}>{selected.favourite ? <><X aria-hidden="true" size={15} /> Unfavourite</> : <><Star aria-hidden="true" size={15} /> Favourite</>}</button><button type="button" className="button button--secondary" onClick={() => setEditor(editorFromFood(selected, "duplicate"))}><Copy aria-hidden="true" size={15} /> Duplicate</button><button type="button" className="button button--secondary" onClick={() => setConfirmArchive(true)}><Archive aria-hidden="true" size={15} /> Archive</button></div>{selected.notes ? <p>{selected.notes}</p> : null}{selected.household_shared ? <p className="fitness-module__privacy-note"><Heart aria-hidden="true" size={16} /> Definition shared intentionally; consumption remains private.</p> : null}</>}
          </FitnessCard>

          <FitnessCard title="Past nutrition updates" detail="Older diary entries keep the numbers they were logged with.">
            {selected.editable !== false ? <div className="fitness-module__button-row"><button type="button" className="button button--primary" onClick={() => setEditor(editorFromFood(selected, "version"))}><Plus aria-hidden="true" size={15} /> New version</button></div> : null}
            {selected.versions?.length ? <ol className="fitness-module__timeline">{selected.versions.map((version) => <li key={version.id}><div><strong>{formatFitnessDate(version.effective_from ?? version.created_at)}</strong><p>{formatNutrient(version.calories_kcal, "calories_kcal")} · {formatNutrient(version.protein_g, "protein_g")} per {version.reference_amount} {version.reference_unit}</p>{version.label_asset_id ? <a className="fitness-module__asset-link" href={`/api/fitness/files/private/${encodeURIComponent(version.label_asset_id)}`} target="_blank" rel="noreferrer"><ImageIcon aria-hidden="true" size={14} /> View label photo</a> : null}</div></li>)}</ol> : <div className="fitness-module__empty"><strong>No previous update</strong><span>Add nutrition details when the package changes.</span></div>}
          </FitnessCard>

          <FitnessCard title="Serving sizes" detail="Save the amounts you use most often.">
            {selected.servings?.length ? <ul className="fitness-module__list">{selected.servings.map((serving) => <li key={serving.id}><div><strong>{serving.name}{serving.is_default ? " · default" : ""}</strong><small>{serving.amount} {serving.unit} · {titleCase(serving.measurement_quality)}</small></div></li>)}</ul> : <div className="fitness-module__empty"><strong>No serving sizes</strong><span>Add a slice, scoop, bowl, or other amount you actually use.</span></div>}
            {selected.editable !== false ? <button type="button" className="button button--secondary" onClick={() => setServingForm(true)}><Plus aria-hidden="true" size={15} /> Add serving</button> : null}
            {servingForm && selected.editable !== false ? <form className="fitness-module__form" onSubmit={submitForm(addServing)}><div className="fitness-module__fields"><label className="fitness-module__field">Serving name<input required autoFocus value={servingName} onChange={(event) => setServingName(event.target.value)} placeholder="one slice" /></label><label className="fitness-module__field">Serving amount<input type="number" min="0.01" step="any" required value={servingAmount} onChange={(event) => setServingAmount(event.target.value)} /></label><label className="fitness-module__field">Serving unit<input required value={servingUnit} onChange={(event) => setServingUnit(event.target.value)} /></label><label className="fitness-module__field">Equivalent amount<input type="number" min="0.01" step="any" required value={servingCanonicalAmount} onChange={(event) => setServingCanonicalAmount(event.target.value)} /></label><label className="fitness-module__field">Measured in<select value={servingCanonicalUnit} onChange={(event) => setServingCanonicalUnit(event.target.value)}><option value="g">g</option><option value="ml">ml</option><option value="item">item</option><option value="serving">serving</option></select></label><label className="fitness-module__field">How measured<select value={servingQuality} onChange={(event) => setServingQuality(event.target.value as FitnessNutritionMeasurementQuality)}>{qualityOptions.map((item) => <option value={item.key} key={item.key}>{item.label}</option>)}</select></label><label className="fitness-module__check"><input type="checkbox" checked={servingDefault} onChange={(event) => setServingDefault(event.target.checked)} /> Default serving</label></div><div className="fitness-module__form-footer"><button type="submit" className="button button--primary" disabled={servingSave.saving || !servingName.trim() || !servingCanonicalAmount}>Save serving</button><button type="button" className="button button--secondary" onClick={() => setServingForm(false)}>Cancel</button><FitnessFormStatus saving={servingSave.saving} saved={servingSave.saved} error={servingSave.saveError} /></div></form> : null}
          </FitnessCard>

          {selected.editable !== false ? <FitnessCard title="Merge duplicate" detail="Preview first. Past diary entries keep the food you logged.">
            <div className="fitness-module__fields"><label className="fitness-module__field is-wide">Merge {selected.name} into<select value={mergeTargetId} disabled={!online} onChange={(event) => { setMergeTargetId(event.target.value); setMergePreview(null); }}><option value="">Choose the food to keep</option>{foods.data.filter((food) => food.id !== selected.id && food.active !== false && food.editable !== false).map((food) => <option value={food.id} key={food.id}>{food.name}{food.brand ? ` · ${food.brand}` : ""}</option>)}</select></label></div>
            <button type="button" className="button button--secondary" disabled={!online || !mergeTargetId || mergeBusy} onClick={() => void previewMerge()}>{mergeBusy ? "Checking…" : "Preview merge"}</button>
            {mergePreview ? <div className="fitness-module__merge-preview" role="region" aria-label="Food merge preview"><strong>{mergePreview.already_merged ? "Already linked to this food" : "Review affected records"}</strong><ul><li>{mergePreview.versions} saved nutrition versions move</li><li>{mergePreview.servings} serving names move</li>{mergePreview.affected_log_entries != null ? <li>{mergePreview.affected_log_entries} diary entries remain linked</li> : null}{mergePreview.affected_recipe_components != null ? <li>{mergePreview.affected_recipe_components} recipe ingredients remain linked</li> : null}{mergePreview.affected_template_items != null ? <li>{mergePreview.affected_template_items} template items remain linked</li> : null}</ul>{mergePreview.warnings?.map((warning) => <p key={warning}>{warning}</p>)}<div className="fitness-module__button-row"><button type="button" className="button button--danger" disabled={mergeBusy || mergePreview.already_merged} onClick={() => void confirmMerge()}>Confirm merge</button><button type="button" className="button button--secondary" onClick={() => setMergePreview(null)}>Cancel</button></div></div> : null}
            {mergeError ? <p className="fitness-module__form-status is-error" role="alert">{mergeError}</p> : null}
          </FitnessCard> : null}

          {confirmArchive && selected.editable !== false ? <FitnessCard title="Archive this food?" detail="Past diary records stay intact."><p>{selected.name} will leave normal search and quick logging.</p><div className="fitness-module__button-row"><button type="button" className="button button--danger" onClick={() => void archiveFood()}>Archive food</button><button type="button" className="button button--secondary" onClick={() => setConfirmArchive(false)}>Keep active</button></div></FitnessCard> : null}
        </> : <FitnessCard><div className="fitness-module__empty"><strong>Choose a food</strong><span>Update nutrition, add a serving, or combine a duplicate.</span></div></FitnessCard>}
      </div>
    </div> : null}

  </div>;
}

type RecipeEditorComponent = {
  key: string;
  foodVersionId: string;
  amount: string;
  unit: string;
};

type RecipeEditorState = {
  mode: "create" | "duplicate" | "version";
  name: string;
  notes: string;
  householdShared: boolean;
  favourite: boolean;
  prepared: boolean;
  components: RecipeEditorComponent[];
  finishedWeight: string;
  servings: string;
  bestCalories: string;
  lowerCalories: string;
  upperCalories: string;
  confidence: string;
  sourceNote: string;
};

function blankRecipeEditor(): RecipeEditorState {
  return {
    mode: "create",
    name: "",
    notes: "",
    householdShared: false,
    favourite: false,
    prepared: false,
    components: [],
    finishedWeight: "",
    servings: "",
    bestCalories: "",
    lowerCalories: "",
    upperCalories: "",
    confidence: "calculated",
    sourceNote: "",
  };
}

function recipeVersion(recipe?: FitnessRecipe | null): FitnessRecipeVersion | null {
  return recipe?.current_version ?? recipe?.latest_version ?? recipe?.versions?.[0] ?? null;
}

function editorFromRecipe(recipe: FitnessRecipe, mode: RecipeEditorState["mode"]): RecipeEditorState {
  const version = recipeVersion(recipe);
  return {
    ...blankRecipeEditor(),
    mode,
    name: mode === "duplicate" ? `${recipe.name} copy` : recipe.name,
    notes: recipe.notes ?? "",
    householdShared: mode === "duplicate" ? false : recipe.household_shared ?? false,
    favourite: mode === "duplicate" ? false : recipe.favourite ?? false,
    prepared: !version?.components?.length,
    components: (version?.components ?? []).map((component) => ({
      key: crypto.randomUUID(),
      foodVersionId: component.food_version_id,
      amount: String(component.canonical_amount),
      unit: component.canonical_unit,
    })),
    finishedWeight: version?.finished_weight_g == null ? "" : String(version.finished_weight_g),
    servings: version?.servings == null ? "" : String(version.servings),
    bestCalories: version?.calories_kcal == null ? "" : String(version.calories_kcal),
    lowerCalories: version?.lower_calories_kcal == null ? "" : String(version.lower_calories_kcal),
    upperCalories: version?.upper_calories_kcal == null ? "" : String(version.upper_calories_kcal),
    confidence: version?.confidence ?? "calculated",
    sourceNote: version?.source_note ?? "",
  };
}

function recipeEditorComponents(editor: RecipeEditorState): FitnessRecipeComponent[] {
  return editor.components.filter((component) => component.foodVersionId && Number(component.amount) > 0).map((component, sequence) => ({
    id: crypto.randomUUID(),
    food_version_id: component.foodVersionId,
    amount: Number(component.amount),
    unit: component.unit,
    canonical_amount: Number(component.amount),
    canonical_unit: component.unit,
    sequence,
  }));
}

function recipeVersionPayload(editor: RecipeEditorState): Record<string, unknown> {
  const components = editor.prepared ? [] : recipeEditorComponents(editor);
  return {
    components,
    finished_weight_g: numberOrNull(editor.finishedWeight),
    servings: numberOrNull(editor.servings),
    calories_kcal: editor.prepared ? numberOrNull(editor.bestCalories) : null,
    protein_g: null,
    carbohydrate_g: null,
    sugars_g: null,
    fat_g: null,
    saturated_fat_g: null,
    fibre_g: null,
    salt_g: null,
    lower_calories_kcal: editor.prepared ? numberOrNull(editor.lowerCalories) : null,
    upper_calories_kcal: editor.prepared ? numberOrNull(editor.upperCalories) : null,
    confidence: editor.confidence,
    source_note: editor.sourceNote.trim() || null,
  };
}

export function FitnessRecipesPanel({ online, revision, onDataChanged }: FitnessViewProps) {
  const foods = useFitnessCollection<FitnessFood>("/fitness/foods", "food", revision);
  const recipes = useFitnessCollection<FitnessRecipe>("/fitness/recipes", "recipe", revision);
  const recipeSave = useFitnessSave(() => { onDataChanged(); recipes.reload(); });
  const [selectedId, setSelectedId] = useState<string | null>(null);
  const [editor, setEditor] = useState<RecipeEditorState | null>(null);
  const [ingredientFoodId, setIngredientFoodId] = useState("");
  const [ingredientAmount, setIngredientAmount] = useState("100");
  const [query, setQuery] = useState("");
  const [confirmArchive, setConfirmArchive] = useState(false);
  const selected = recipes.data.find((recipe) => recipe.id === selectedId) ?? null;
  const versionMap = useMemo(() => new Map(foods.data.flatMap((food) => {
    const versions = food.versions?.length ? food.versions : currentFoodVersion(food) ? [currentFoodVersion(food)!] : [];
    return versions.map((version) => [version.id, version] as const);
  })), [foods.data]);
  const previewComponents = editor ? recipeEditorComponents(editor) : [];
  const preview = editor && !editor.prepared
    ? calculateRecipeNutrition(previewComponents, versionMap, numberOrNull(editor.finishedWeight))
    : null;
  const displayedRecipes = recipes.data.filter((recipe) => !query.trim() || recipe.name.toLocaleLowerCase().includes(query.trim().toLocaleLowerCase()));

  function addIngredient() {
    const food = foods.data.find((item) => item.id === ingredientFoodId);
    const version = currentFoodVersion(food);
    if (!version?.id) return;
    setEditor((current) => current ? {
      ...current,
      components: [...current.components, {
        key: crypto.randomUUID(),
        foodVersionId: version.id,
        amount: ingredientAmount,
        unit: version.reference_unit,
      }],
    } : current);
    setIngredientFoodId("");
    setIngredientAmount("100");
  }

  async function saveRecipeEditor() {
    if (!editor) return;
    if (editor.mode === "version" && selected?.editable === false) return;
    const versionId = crypto.randomUUID();
    const versionPayload = { id: versionId, ...recipeVersionPayload(editor) };
    if (editor.mode === "version" && selected) {
      await recipeSave.save("recipe_version", { ...versionPayload, recipe_id: selected.id }, { entityId: versionId });
    } else {
      const recipeId = crypto.randomUUID();
      await recipeSave.save("recipe", {
        name: editor.name.trim(),
        notes: editor.notes.trim() || null,
        household_shared: editor.householdShared,
        favourite: editor.favourite,
        active: true,
        version: versionPayload,
      }, { entityId: recipeId });
      setSelectedId(recipeId);
    }
    setEditor(null);
  }

  async function toggleRecipeFavourite(recipe: FitnessRecipe) {
    if (recipe.editable === false) return;
    await recipeSave.save("recipe", recipeIdentityPayload(recipe, { favourite: !recipe.favourite }), {
      entityId: recipe.id,
      baseRevision: recipe.revision ?? null,
    });
  }

  async function archiveRecipe() {
    if (!selected || selected.editable === false) return;
    await recipeSave.save("recipe", recipeIdentityPayload(selected, { active: false }), {
      entityId: selected.id,
      baseRevision: selected.revision ?? null,
    });
    setConfirmArchive(false);
  }

  return <div className="fitness-module__nutrition-stack">
    <div className="fitness-module__button-row"><button type="button" className="button button--primary" onClick={() => { setEditor(blankRecipeEditor()); setSelectedId(null); }}><Plus aria-hidden="true" size={16} /> New recipe or prepared meal</button></div>

    {editor ? <FitnessCard title={editor.mode === "version" ? "Update recipe details" : editor.mode === "duplicate" ? "Duplicate recipe" : "New recipe or prepared meal"} detail="Add ingredients for a home recipe, or a practical range for a prepared meal.">
      <form className="fitness-module__form" onSubmit={submitForm(saveRecipeEditor)}>
        {editor.mode !== "version" ? <div className="fitness-module__fields"><label className="fitness-module__field is-wide">Recipe name<input required autoFocus value={editor.name} onChange={(event) => setEditor({ ...editor, name: event.target.value })} placeholder="Chicken rice bowl" /></label><label className="fitness-module__field is-wide">Notes<input value={editor.notes} onChange={(event) => setEditor({ ...editor, notes: event.target.value })} /></label><label className="fitness-module__check"><input type="checkbox" checked={editor.favourite} onChange={(event) => setEditor({ ...editor, favourite: event.target.checked })} /> Favourite</label><label className="fitness-module__check"><input type="checkbox" checked={editor.householdShared} onChange={(event) => setEditor({ ...editor, householdShared: event.target.checked })} /> Share definition with household</label></div> : <div className="fitness-module__callout"><strong>{selected?.name}</strong><p>The previous ingredient list and diary totals remain unchanged.</p></div>}
        <div className="fitness-module__segmented" role="group" aria-label="Recipe type"><button type="button" className={!editor.prepared ? "is-active" : undefined} aria-pressed={!editor.prepared} onClick={() => setEditor({ ...editor, prepared: false, confidence: "calculated" })}>Ingredient recipe</button><button type="button" className={editor.prepared ? "is-active" : undefined} aria-pressed={editor.prepared} onClick={() => setEditor({ ...editor, prepared: true, confidence: "estimated" })}>Prepared / restaurant estimate</button></div>
        {!editor.prepared ? <>
          <div className="fitness-module__fields"><label className="fitness-module__field is-wide">Ingredient<select value={ingredientFoodId} onChange={(event) => { const id = event.target.value; setIngredientFoodId(id); const version = currentFoodVersion(foods.data.find((food) => food.id === id)); if (version) setIngredientAmount(String(version.reference_amount)); }}><option value="">Choose a food</option>{foods.data.filter((food) => currentFoodVersion(food)?.id && food.active !== false).map((food) => <option value={food.id} key={food.id}>{food.name}</option>)}</select></label><label className="fitness-module__field">Amount in recipe<input type="number" min="0.01" step="any" value={ingredientAmount} onChange={(event) => setIngredientAmount(event.target.value)} /></label><button type="button" className="button button--secondary" disabled={!ingredientFoodId || !ingredientAmount} onClick={addIngredient}>Add ingredient</button></div>
          {editor.components.length ? <ol className="fitness-module__list">{editor.components.map((component, index) => { const food = foods.data.find((item) => currentFoodVersion(item)?.id === component.foodVersionId || item.versions?.some((candidate) => candidate.id === component.foodVersionId)); return <li key={component.key}><div><strong>{food?.name ?? "Saved food"}</strong><small>{component.amount} {component.unit}</small></div><div className="fitness-module__list-actions"><label className="fitness-module__compact-input"><span className="sr-only">Amount for {food?.name}</span><input type="number" min="0.01" step="any" value={component.amount} onChange={(event) => setEditor({ ...editor, components: editor.components.map((item, itemIndex) => itemIndex === index ? { ...item, amount: event.target.value } : item) })} /> {component.unit}</label><button type="button" className="button button--secondary button--compact" aria-label={`Remove ${food?.name ?? "ingredient"}`} onClick={() => setEditor({ ...editor, components: editor.components.filter((item) => item.key !== component.key) })}><X aria-hidden="true" size={14} /> Remove</button></div></li>; })}</ol> : <div className="fitness-module__empty"><strong>No ingredients yet</strong><span>Add the foods used in this recipe.</span></div>}
          <div className="fitness-module__fields"><label className="fitness-module__field">Finished cooked weight (g)<input type="number" min="0.01" step="any" value={editor.finishedWeight} onChange={(event) => setEditor({ ...editor, finishedWeight: event.target.value })} /></label><label className="fitness-module__field">Servings (optional)<input type="number" min="0.01" step="any" value={editor.servings} onChange={(event) => setEditor({ ...editor, servings: event.target.value })} /></label><label className="fitness-module__field is-wide">Cooking note (optional)<input value={editor.sourceNote} onChange={(event) => setEditor({ ...editor, sourceNote: event.target.value })} /></label></div>
          {preview ? <div className="fitness-module__recipe-preview"><strong>Recipe totals</strong><div className="fitness-module__stats"><FitnessStat label="Whole recipe Calories" value={formatNutrient(preview.totals.calories_kcal, "calories_kcal")} detail={preview.totals.calories_kcal == null ? "Add nutrition for each ingredient" : undefined} /><FitnessStat label="Protein" value={formatNutrient(preview.totals.protein_g, "protein_g")} /><FitnessStat label="Per 100 g" value={preview.per100g ? formatNutrient(preview.per100g.calories_kcal, "calories_kcal") : "Add cooked weight"} /></div></div> : null}
        </> : <div className="fitness-module__fields">
          <label className="fitness-module__field">Best estimate Calories<input type="number" inputMode="decimal" min="0" step="any" required value={editor.bestCalories} onChange={(event) => setEditor({ ...editor, bestCalories: event.target.value })} /></label>
          <label className="fitness-module__field">Lower estimate<input type="number" inputMode="decimal" min="0" step="any" value={editor.lowerCalories} onChange={(event) => setEditor({ ...editor, lowerCalories: event.target.value })} /></label>
          <label className="fitness-module__field">Upper estimate<input type="number" inputMode="decimal" min="0" step="any" value={editor.upperCalories} onChange={(event) => setEditor({ ...editor, upperCalories: event.target.value })} /></label>
          <label className="fitness-module__field">Finished amount / weight (optional)<input type="number" min="0.01" step="any" value={editor.finishedWeight} onChange={(event) => setEditor({ ...editor, finishedWeight: event.target.value })} /></label>
          <label className="fitness-module__field is-wide">Notes about this portion<input value={editor.sourceNote} onChange={(event) => setEditor({ ...editor, sourceNote: event.target.value })} placeholder="Restaurant menu and portion size" /></label>
        </div>}
        {editor.householdShared ? <p className="fitness-module__privacy-note"><Heart aria-hidden="true" size={16} /> Recipe definition shared; individual consumption remains private.</p> : null}
        <div className="fitness-module__form-footer"><button type="submit" className="button button--primary" disabled={recipeSave.saving || (editor.mode !== "version" && !editor.name.trim()) || (!editor.prepared && !editor.components.length) || (editor.prepared && !editor.bestCalories)}>Save recipe</button><button type="button" className="button button--secondary" onClick={() => setEditor(null)}>Cancel</button><FitnessFormStatus saving={recipeSave.saving} saved={recipeSave.saved} error={recipeSave.saveError} /></div>
      </form>
    </FitnessCard> : null}

    <FitnessLoadingOrError loading={recipes.loading || foods.loading} error={recipes.error ?? foods.error} retry={() => { recipes.reload(); foods.reload(); }} />
    {!recipes.loading ? <div className="fitness-module__nutrition-split">
      <FitnessCard title="Recipes" detail="Separate from meal templates">
        <label className="fitness-module__field"><span><Search aria-hidden="true" size={15} /> Search recipes</span><input type="search" value={query} onChange={(event) => setQuery(event.target.value)} /></label>
        {displayedRecipes.length ? <ul className="fitness-module__catalogue-list">{displayedRecipes.map((recipe) => {
          const version = recipeVersion(recipe);
          return <li key={recipe.id}><button type="button" className={selectedId === recipe.id ? "is-active" : undefined} onClick={() => { setSelectedId(recipe.id); setEditor(null); setConfirmArchive(false); }}><span><strong>{recipe.name}</strong><small>{recipe.editable === false ? "Household recipe · " : ""}{version?.components?.length ? `${version.components.length} ingredients` : "Prepared estimate"}</small><small>{formatNutrient(version?.calories_kcal, "calories_kcal")}{version?.lower_calories_kcal != null || version?.upper_calories_kcal != null ? ` · range ${version.lower_calories_kcal ?? "?"}–${version.upper_calories_kcal ?? "?"} kcal` : ""}</small></span><ChevronRight aria-hidden="true" size={16} /></button></li>;
        })}</ul> : <div className="fitness-module__empty"><strong>No recipes yet</strong><span>Create an ingredient recipe or a prepared-meal estimate.</span></div>}
      </FitnessCard>
      <div className="fitness-module__nutrition-detail">{selected ? <>
        <FitnessCard title={selected.name} detail={selected.editable === false ? "Household recipe · readable and loggable, owned by another family member" : selected.notes ?? "Saved recipe"}>
          {selected.editable === false ? <><div className="fitness-module__notice" role="status"><Heart aria-hidden="true" size={16} /><span>This shared recipe can be logged, but only its owner can change versions, favourites, or archive state.</span></div><div className="fitness-module__button-row"><button type="button" className="button button--primary" onClick={() => setEditor(editorFromRecipe(selected, "duplicate"))}><Copy aria-hidden="true" size={15} /> Copy to my recipes</button></div></> : <div className="fitness-module__button-row"><button type="button" className="button button--primary" onClick={() => setEditor(editorFromRecipe(selected, "version"))}><Plus aria-hidden="true" size={15} /> New version</button><button type="button" className="button button--secondary" onClick={() => setEditor(editorFromRecipe(selected, "duplicate"))}><Copy aria-hidden="true" size={15} /> Duplicate</button><button type="button" className="button button--secondary" onClick={() => void toggleRecipeFavourite(selected)}>{selected.favourite ? "Unfavourite" : "Favourite"}</button><button type="button" className="button button--secondary" onClick={() => setConfirmArchive(true)}><Archive aria-hidden="true" size={15} /> Archive</button></div>}
        </FitnessCard>
        <FitnessCard title="Past recipe updates" detail="Older diary entries keep the recipe they were logged with.">
          {selected.versions?.length ? <ol className="fitness-module__timeline">{selected.versions.map((version) => <li key={version.id}><div><strong>{formatFitnessDate(version.created_at)}</strong>{version.components?.length ? <p>{version.components.length} ingredients · {formatNutrient(version.calories_kcal, "calories_kcal")} total{version.finished_weight_g ? ` · ${formatNutrient(version.per_100_g?.calories_kcal ?? (version.calories_kcal == null ? null : version.calories_kcal * 100 / version.finished_weight_g), "calories_kcal")} per 100 g` : ""}</p> : <div className="fitness-module__estimate-range"><strong>{formatNutrient(version.calories_kcal, "calories_kcal")}</strong><span>{version.lower_calories_kcal ?? "?"}–{version.upper_calories_kcal ?? "?"} kcal</span></div>}</div></li>)}</ol> : <div className="fitness-module__empty"><strong>No previous update</strong><span>Update the recipe when ingredients or portions change.</span></div>}
        </FitnessCard>
        {confirmArchive && selected.editable !== false ? <FitnessCard title="Archive this recipe?" detail="Diary entries using old versions remain intact."><div className="fitness-module__button-row"><button type="button" className="button button--danger" onClick={() => void archiveRecipe()}>Archive recipe</button><button type="button" className="button button--secondary" onClick={() => setConfirmArchive(false)}>Keep active</button></div></FitnessCard> : null}
      </> : <FitnessCard><div className="fitness-module__empty"><strong>Choose a recipe</strong><span>Update it, duplicate it, or add a new recipe.</span></div></FitnessCard>}</div>
    </div> : null}
  </div>;
}

type TemplateEditorState = {
  id?: string;
  revision?: number;
  name: string;
  meal: FitnessMealKey;
  timeRelevance: string;
  favourite: boolean;
  items: FitnessMealTemplateItem[];
};

function blankTemplateEditor(): TemplateEditorState {
  return { name: "", meal: "breakfast", timeRelevance: "breakfast", favourite: false, items: [] };
}

export function FitnessMealTemplatesPanel({ online, revision, onDataChanged }: FitnessViewProps) {
  const [initialBoundary] = useState(cachedNutritionDayStartMinutes);
  const foods = useFitnessCollection<FitnessFood>("/fitness/foods", "food", revision);
  const recipes = useFitnessCollection<FitnessRecipe>("/fitness/recipes", "recipe", revision);
  const templates = useFitnessCollection<FitnessMealTemplate>("/fitness/meal-templates", "meal_template", revision);
  const settings = useFitnessEndpoint<FitnessNutritionSettings>("/fitness/nutrition/settings", {
    id: "nutrition-settings",
    timezone: localTimeZone(),
    nutrition_day_start_minutes: initialBoundary,
  }, revision);
  const templateSave = useFitnessSave(() => { onDataChanged(); templates.reload(); });
  const batchSave = useFitnessBatchSave(onDataChanged);
  const [editor, setEditor] = useState<TemplateEditorState | null>(null);
  const [source, setSource] = useState("");
  const [servingId, setServingId] = useState("");
  const [itemAmount, setItemAmount] = useState("100");
  const [itemQuality, setItemQuality] = useState<FitnessNutritionMeasurementQuality>("standard_serving");
  const [logTemplate, setLogTemplate] = useState<FitnessMealTemplate | null>(null);
  const [logAmounts, setLogAmounts] = useState<Record<string, number>>({});
  const [loggedAt, setLoggedAt] = useState(localDateTimeValue());
  const [confirmArchive, setConfirmArchive] = useState<FitnessMealTemplate | null>(null);
  const [localError, setLocalError] = useState<string | null>(null);

  useEffect(() => {
    rememberNutritionDayStartMinutes(settings.data.nutrition_day_start_minutes);
  }, [settings.data.nutrition_day_start_minutes]);

  useEffect(() => {
    const url = new URL(window.location.href);
    const target = url.searchParams.get("fitness-meal-template");
    if (!target || templates.loading) return;
    const card = document.getElementById(`fitness-meal-template-${target}`);
    if (!card) return;
    url.searchParams.delete("fitness-meal-template");
    window.history.replaceState({}, "", url);
    window.requestAnimationFrame(() => {
      card.scrollIntoView({ block: "center", behavior: "smooth" });
      card.focus({ preventScroll: true });
    });
  }, [templates.data, templates.loading]);

  const sourceFood = source.startsWith("food:") ? foods.data.find((food) => food.id === source.slice(5)) ?? null : null;
  const sourceRecipe = source.startsWith("recipe:") ? recipes.data.find((recipe) => recipe.id === source.slice(7)) ?? null : null;
  const sourceFoodVersion = currentFoodVersion(sourceFood);
  const sourceRecipeVersion = recipeVersion(sourceRecipe);
  const sourceServing = sourceFood?.servings?.find((serving) => serving.id === servingId) ?? null;

  function selectTemplateSource(value: string) {
    setSource(value);
    setServingId("");
    const food = value.startsWith("food:") ? foods.data.find((item) => item.id === value.slice(5)) : null;
    const recipe = value.startsWith("recipe:") ? recipes.data.find((item) => item.id === value.slice(7)) : null;
    const version = currentFoodVersion(food);
    const recipeCurrent = recipeVersion(recipe);
    setItemAmount(String(version?.reference_amount ?? (recipeCurrent?.finished_weight_g ? 100 : 1)));
  }

  function chooseTemplateServing(value: string) {
    setServingId(value);
    const serving = sourceFood?.servings?.find((item) => item.id === value);
    if (serving) {
      setItemAmount(String(serving.amount));
      setItemQuality(serving.measurement_quality);
    } else if (sourceFoodVersion) {
      setItemAmount(String(sourceFoodVersion.reference_amount));
    }
  }

  function addTemplateItem() {
    if (!editor || (!sourceFoodVersion?.id && !sourceRecipeVersion?.id)) return;
    const amount = Number(itemAmount);
    if (!Number.isFinite(amount) || amount <= 0) return;
    const canonicalAmount = sourceServing
      ? amount / sourceServing.amount * sourceServing.canonical_amount
      : amount;
    const canonicalUnit = sourceServing?.canonical_unit
      ?? sourceFoodVersion?.reference_unit
      ?? (sourceRecipeVersion?.finished_weight_g ? "g" : "serving");
    const unit = sourceServing?.unit ?? sourceFoodVersion?.reference_unit ?? canonicalUnit;
    setEditor({
      ...editor,
      items: [...editor.items, {
        id: crypto.randomUUID(),
        food_version_id: sourceFoodVersion?.id ?? null,
        recipe_version_id: sourceRecipeVersion?.id ?? null,
        label: sourceFood?.name ?? sourceRecipe?.name ?? null,
        amount,
        unit,
        canonical_amount: canonicalAmount,
        canonical_unit: canonicalUnit,
        measurement_quality: itemQuality,
        sequence: editor.items.length,
      }],
    });
    setSource("");
    setServingId("");
    setItemAmount("100");
  }

  async function saveTemplateEditor() {
    if (!editor) return;
    const entityId = editor.id ?? crypto.randomUUID();
    await templateSave.save("meal_template", {
      name: editor.name.trim(),
      meal_key: editor.meal,
      time_relevance: editor.timeRelevance || null,
      favourite: editor.favourite,
      active: true,
      items: editor.items.map((item, sequence) => ({ ...item, sequence })),
    }, { entityId, baseRevision: editor.revision ?? null });
    setEditor(null);
  }

  function editTemplate(template: FitnessMealTemplate) {
    setEditor({
      id: template.id,
      revision: template.revision,
      name: template.name,
      meal: template.meal_key as FitnessMealKey,
      timeRelevance: template.time_relevance ?? String(template.meal_key),
      favourite: template.favourite ?? false,
      items: template.items.map((item, sequence) => ({ ...item, sequence })),
    });
  }

  function duplicateTemplate(template: FitnessMealTemplate) {
    setEditor({
      name: `${template.name} copy`,
      meal: template.meal_key as FitnessMealKey,
      timeRelevance: template.time_relevance ?? String(template.meal_key),
      favourite: false,
      items: template.items.map((item, sequence) => ({ ...item, id: crypto.randomUUID(), sequence })),
    });
  }

  function openTemplateLog(template: FitnessMealTemplate) {
    setLogTemplate(template);
    setLoggedAt(localDateTimeValue());
    setLogAmounts(Object.fromEntries(template.items.map((item, index) => [item.id ?? String(index), item.amount])));
    setLocalError(null);
  }

  async function logSelectedTemplate() {
    if (!logTemplate) return;
    setLocalError(null);
    try {
      const payloads = templateLogPayloads(logTemplate, utcFromLocalInput(loggedAt), localTimeZone(), logAmounts).map((payload) => ({
        ...payload,
        nutrition_date: nutritionDateForLocalInput(loggedAt, settings.data.nutrition_day_start_minutes),
      }));
      await batchSave.save(payloads.map((payload) => ({ entityType: "food_log_entry", payload })));
      setLogTemplate(null);
    } catch (error) {
      setLocalError(errorMessage(error));
    }
  }

  async function archiveTemplate(template: FitnessMealTemplate) {
    await templateSave.save("meal_template", {
      name: template.name,
      meal_key: template.meal_key,
      time_relevance: template.time_relevance ?? null,
      favourite: template.favourite ?? false,
      active: false,
      items: template.items,
    }, { entityId: template.id, baseRevision: template.revision ?? null });
    setConfirmArchive(null);
  }

  return <div className="fitness-module__nutrition-stack">
    <div className="fitness-module__button-row"><button type="button" className="button button--primary" onClick={() => setEditor(blankTemplateEditor())}><Plus aria-hidden="true" size={16} /> New meal template</button></div>

    {editor ? <FitnessCard title={editor.id ? "Amend meal template" : "Create meal template"} detail="A template is a shortcut, not a combined recipe: logging creates separate diary entries.">
      <form className="fitness-module__form" onSubmit={submitForm(saveTemplateEditor)}>
        <div className="fitness-module__fields"><label className="fitness-module__field is-wide">Template name<input required autoFocus value={editor.name} onChange={(event) => setEditor({ ...editor, name: event.target.value })} placeholder="Workday breakfast" /></label><label className="fitness-module__field">Meal<select value={editor.meal} onChange={(event) => setEditor({ ...editor, meal: event.target.value as FitnessMealKey })}>{mealOptions.map((item) => <option value={item.key} key={item.key}>{item.label}</option>)}</select></label><label className="fitness-module__field">Time relevance<select value={editor.timeRelevance} onChange={(event) => setEditor({ ...editor, timeRelevance: event.target.value })}><option value="">Any time</option>{mealOptions.map((item) => <option value={item.key} key={item.key}>{item.label}</option>)}</select></label><label className="fitness-module__check"><input type="checkbox" checked={editor.favourite} onChange={(event) => setEditor({ ...editor, favourite: event.target.checked })} /> Favourite template</label></div>
        <div className="fitness-module__fields"><label className="fitness-module__field is-wide">Food or recipe<select value={source} onChange={(event) => selectTemplateSource(event.target.value)}><option value="">Choose an item</option><optgroup label="Foods">{foods.data.filter((food) => currentFoodVersion(food)?.id).map((food) => <option value={`food:${food.id}`} key={food.id}>{food.name}</option>)}</optgroup>{recipes.data.length ? <optgroup label="Recipes">{recipes.data.filter((recipe) => recipeVersion(recipe)?.id).map((recipe) => <option value={`recipe:${recipe.id}`} key={recipe.id}>{recipe.name}</option>)}</optgroup> : null}</select></label>{sourceFood?.servings?.length ? <label className="fitness-module__field">Serving alias<select value={servingId} onChange={(event) => chooseTemplateServing(event.target.value)}><option value="">Base unit</option>{sourceFood.servings.map((serving) => <option value={serving.id} key={serving.id}>{serving.name}</option>)}</select></label> : null}<label className="fitness-module__field">Usual amount ({sourceServing?.unit ?? sourceFoodVersion?.reference_unit ?? (sourceRecipeVersion?.finished_weight_g ? "g" : "serving")})<input type="number" min="0.01" step="any" value={itemAmount} onChange={(event) => setItemAmount(event.target.value)} /></label><label className="fitness-module__field">Quality<select value={itemQuality} onChange={(event) => setItemQuality(event.target.value as FitnessNutritionMeasurementQuality)}>{qualityOptions.map((item) => <option value={item.key} key={item.key}>{item.label}</option>)}</select></label><button type="button" className="button button--secondary" disabled={!source || !itemAmount} onClick={addTemplateItem}>Add item</button></div>
        {editor.items.length ? <ol className="fitness-module__list">{editor.items.map((item, index) => <li key={item.id ?? index}><div><strong>{item.label ?? "Saved item"}</strong><small>{item.amount} {item.unit} · {titleCase(item.measurement_quality)}</small></div><div className="fitness-module__list-actions"><button type="button" className="button button--secondary button--compact" aria-label={`Move ${item.label ?? "item"} up`} disabled={index === 0} onClick={() => { const next = [...editor.items]; [next[index - 1], next[index]] = [next[index], next[index - 1]]; setEditor({ ...editor, items: next }); }}>↑</button><button type="button" className="button button--secondary button--compact" aria-label={`Move ${item.label ?? "item"} down`} disabled={index === editor.items.length - 1} onClick={() => { const next = [...editor.items]; [next[index + 1], next[index]] = [next[index], next[index + 1]]; setEditor({ ...editor, items: next }); }}>↓</button><button type="button" className="button button--secondary button--compact" onClick={() => setEditor({ ...editor, items: editor.items.filter((_, itemIndex) => itemIndex !== index) })}><X aria-hidden="true" size={14} /> Remove</button></div></li>)}</ol> : <div className="fitness-module__empty"><strong>No template items</strong><span>Add the foods or recipes you usually have together.</span></div>}
        <div className="fitness-module__form-footer"><button type="submit" className="button button--primary" disabled={templateSave.saving || !editor.name.trim() || !editor.items.length}>Save template</button><button type="button" className="button button--secondary" onClick={() => setEditor(null)}>Cancel</button><FitnessFormStatus saving={templateSave.saving} saved={templateSave.saved} error={templateSave.saveError} /></div>
      </form>
    </FitnessCard> : null}

    <FitnessLoadingOrError loading={templates.loading || foods.loading || recipes.loading} error={templates.error ?? foods.error ?? recipes.error} retry={() => { templates.reload(); foods.reload(); recipes.reload(); }} />
    {!templates.loading ? <div className="fitness-module__grid">{templates.data.filter((template) => template.active !== false).map((template) => <div id={`fitness-meal-template-${template.id}`} className="fitness-module__destination" tabIndex={-1} key={template.id}><FitnessCard title={template.name} detail={`${titleCase(String(template.meal_key))} · ${template.items.length} ${template.items.length === 1 ? "item" : "items"}`}><ul className="fitness-module__list">{template.items.map((item, index) => <li key={item.id ?? index}><div><strong>{item.label ?? "Saved version"}</strong><small>{item.amount} {item.unit} · {titleCase(item.measurement_quality)}</small></div></li>)}</ul><div className="fitness-module__button-row"><button type="button" className="button button--primary" onClick={() => openTemplateLog(template)}>Log template</button><button type="button" className="button button--secondary" onClick={() => editTemplate(template)}><Pencil aria-hidden="true" size={15} /> Amend</button><button type="button" className="button button--secondary" onClick={() => duplicateTemplate(template)}><Copy aria-hidden="true" size={15} /> Duplicate</button><button type="button" className="button button--secondary" onClick={() => setConfirmArchive(template)}><Archive aria-hidden="true" size={15} /> Archive</button></div></FitnessCard></div>)}{!templates.data.some((template) => template.active !== false) ? <FitnessCard><div className="fitness-module__empty"><strong>No meal templates</strong><span>Create one from here or save a meal from the diary.</span></div></FitnessCard> : null}</div> : null}

    {logTemplate ? <FitnessCard title={`Log ${logTemplate.name}`} detail="Check the portions, then add the items to today’s diary together."><form className="fitness-module__form" onSubmit={submitForm(logSelectedTemplate)}><div className="fitness-module__fields"><label className="fitness-module__field">When<input type="datetime-local" required value={loggedAt} onChange={(event) => setLoggedAt(event.target.value)} /></label></div><ul className="fitness-module__list">{logTemplate.items.map((item, index) => { const key = item.id ?? String(index); return <li key={key}><div><strong>{item.label ?? "Saved item"}</strong><small>Usual portion: {item.amount} {item.unit}</small></div><label className="fitness-module__compact-input"><span className="sr-only">Amount for {item.label ?? "item"}</span><input type="number" min="0.01" step="any" value={logAmounts[key] ?? item.amount} onChange={(event) => setLogAmounts({ ...logAmounts, [key]: Number(event.target.value) })} /> {item.unit}</label></li>; })}</ul><div className="fitness-module__form-footer"><button type="submit" className="button button--primary" disabled={batchSave.saving}>Log {logTemplate.items.length} entries</button><button type="button" className="button button--secondary" onClick={() => setLogTemplate(null)}>Cancel</button><FitnessFormStatus saving={batchSave.saving} saved={batchSave.saved} error={batchSave.saveError ?? localError} /></div></form></FitnessCard> : null}

    {confirmArchive ? <FitnessCard title="Archive this meal template?" detail="Past diary entries are independent and remain intact."><p>{confirmArchive.name} will leave quick logging.</p><div className="fitness-module__button-row"><button type="button" className="button button--danger" onClick={() => void archiveTemplate(confirmArchive)}>Archive template</button><button type="button" className="button button--secondary" onClick={() => setConfirmArchive(null)}>Keep active</button></div></FitnessCard> : null}
  </div>;
}

export function FitnessNutritionTargetsPanel({ online, revision, onDataChanged }: FitnessViewProps) {
  const [initialBoundary] = useState(cachedNutritionDayStartMinutes);
  const settings = useFitnessEndpoint<FitnessNutritionSettings>("/fitness/nutrition/settings", {
    id: "nutrition-settings",
    timezone: localTimeZone(),
    nutrition_day_start_minutes: initialBoundary,
  }, revision);
  const targets = useFitnessCollection<FitnessNutritionTarget>("/fitness/nutrition/targets", "nutrition_target", revision);
  const phases = useFitnessCollection<FitnessPhase>("/fitness/phases", "training_phase", revision);
  const targetSave = useFitnessSave(() => { onDataChanged(); targets.reload(); });
  const [boundary, setBoundary] = useState(initialBoundary);
  const [heartRateZones, setHeartRateZones] = useState(["120", "140", "155", "170"]);
  const [heartRateBusy, setHeartRateBusy] = useState(false);
  const [heartRateResult, setHeartRateResult] = useState<string | null>(null);
  const [heartRateError, setHeartRateError] = useState<string | null>(null);
  const [rebucketBusy, setRebucketBusy] = useState(false);
  const [rebucketResult, setRebucketResult] = useState<string | null>(null);
  const [rebucketError, setRebucketError] = useState<string | null>(null);
  const [targetForm, setTargetForm] = useState(false);
  const [metric, setMetric] = useState<FitnessNutrientKey>("calories_kcal");
  const [targetType, setTargetType] = useState<FitnessNutritionTargetMode>("fixed");
  const [targetValueInput, setTargetValueInput] = useState("");
  const [targetMin, setTargetMin] = useState("");
  const [targetMax, setTargetMax] = useState("");
  const [trainingValue, setTrainingValue] = useState("");
  const [restValue, setRestValue] = useState("");
  const [phaseId, setPhaseId] = useState("");
  const [effectiveFrom, setEffectiveFrom] = useState(localDateValue());
  const [effectiveUntil, setEffectiveUntil] = useState("");
  const [confirmArchive, setConfirmArchive] = useState<FitnessNutritionTarget | null>(null);

  useEffect(() => {
    rememberNutritionDayStartMinutes(settings.data.nutrition_day_start_minutes);
    setBoundary(settings.data.nutrition_day_start_minutes);
  }, [settings.data.nutrition_day_start_minutes]);
  useEffect(() => setHeartRateZones((settings.data.heart_rate_zone_boundaries_bpm?.length === 4
    ? settings.data.heart_rate_zone_boundaries_bpm
    : [120, 140, 155, 170]).map(String)), [settings.data.heart_rate_zone_boundaries_bpm]);

  useEffect(() => {
    const url = new URL(window.location.href);
    const target = url.searchParams.get("fitness-nutrition-target");
    if (!target || targets.loading) return;
    const row = document.getElementById(`fitness-nutrition-target-${target}`);
    if (!row) return;
    url.searchParams.delete("fitness-nutrition-target");
    window.history.replaceState({}, "", url);
    window.requestAnimationFrame(() => {
      row.scrollIntoView({ block: "center", behavior: "smooth" });
      row.focus({ preventScroll: true });
    });
  }, [targets.data, targets.loading]);

  const parsedHeartRateZones = heartRateZones.map(Number);
  const heartRateZonesValid = parsedHeartRateZones.length === 4
    && parsedHeartRateZones.every((value) => Number.isInteger(value) && value >= 60 && value <= 240)
    && parsedHeartRateZones.every((value, index) => index === 0 || value > parsedHeartRateZones[index - 1]);

  async function saveHeartRateZones() {
    if (!online || !heartRateZonesValid) return;
    setHeartRateBusy(true);
    setHeartRateError(null);
    setHeartRateResult(null);
    try {
      await api("/fitness/nutrition/settings", {
        method: "PATCH",
        body: JSON.stringify({
          nutrition_day_start_minutes: settings.data.nutrition_day_start_minutes,
          timezone: settings.data.timezone || localTimeZone(),
          heart_rate_zone_boundaries_bpm: parsedHeartRateZones,
        }),
      }, true, false);
      setHeartRateResult("Heart-rate boundaries saved for future FIT analysis.");
      onDataChanged();
      settings.reload();
    } catch (error) {
      setHeartRateError(errorMessage(error));
    } finally {
      setHeartRateBusy(false);
    }
  }

  async function rebucketDiary() {
    setRebucketBusy(true);
    setRebucketError(null);
    setRebucketResult(null);
    try {
      const result = await api<{ nutrition_day_start_minutes: number; affected_entries?: number; status?: string }>(
        "/fitness/nutrition/settings/rebucket",
        {
          method: "POST",
          body: JSON.stringify({ nutrition_day_start_minutes: boundary, timezone: localTimeZone() }),
        },
        true,
        false,
      );
      rememberNutritionDayStartMinutes(result.nutrition_day_start_minutes);
      setRebucketResult(`${result.affected_entries ?? 0} diary ${result.affected_entries === 1 ? "entry" : "entries"} checked and regrouped.`);
      onDataChanged();
      settings.reload();
    } catch (error) {
      setRebucketError(errorMessage(error));
    } finally {
      setRebucketBusy(false);
    }
  }

  async function saveTarget() {
    await targetSave.save("nutrition_target", {
      metric_key: metric,
      target_type: targetType,
      target_value: targetType === "fixed" || targetType === "weekly_average" || targetType === "phase" ? numberOrNull(targetValueInput) : null,
      target_min: targetType === "range" ? numberOrNull(targetMin) : null,
      target_max: targetType === "range" ? numberOrNull(targetMax) : null,
      training_day_value: targetType === "training_rest" ? numberOrNull(trainingValue) : null,
      rest_day_value: targetType === "training_rest" ? numberOrNull(restValue) : null,
      phase_id: targetType === "phase" ? phaseId || null : null,
      effective_from: effectiveFrom,
      effective_until: effectiveUntil || null,
      active: true,
    });
    setTargetForm(false);
    setTargetValueInput("");
    setTargetMin("");
    setTargetMax("");
    setTrainingValue("");
    setRestValue("");
  }

  async function archiveTarget(target: FitnessNutritionTarget) {
    await targetSave.save("nutrition_target", {
      metric_key: target.metric_key,
      target_type: target.target_type,
      target_value: target.target_value ?? null,
      target_min: target.target_min ?? null,
      target_max: target.target_max ?? null,
      training_day_value: target.training_day_value ?? null,
      rest_day_value: target.rest_day_value ?? null,
      phase_id: target.phase_id ?? null,
      effective_from: target.effective_from ?? localDateValue(),
      effective_until: target.effective_until ?? null,
      active: false,
    }, { entityId: target.id, baseRevision: target.revision ?? null });
    setConfirmArchive(null);
  }

  function targetDescription(target: FitnessNutritionTarget): string {
    const unit = target.metric_key === "calories_kcal" ? "kcal" : "g";
    if (target.target_type === "range") return `${target.target_min ?? "?"}–${target.target_max ?? "?"} ${unit}`;
    if (target.target_type === "training_rest") return `${target.training_day_value ?? "?"} ${unit} training · ${target.rest_day_value ?? "?"} ${unit} rest`;
    return `${target.target_value ?? "?"} ${unit}${target.target_type === "weekly_average" ? " weekly average" : ""}`;
  }

  const needsValue = ["fixed", "weekly_average", "phase"].includes(targetType);
  const targetValid = targetType === "range"
    ? Boolean(targetMin && targetMax && Number(targetMin) <= Number(targetMax))
    : targetType === "training_rest"
      ? Boolean(trainingValue && restValue)
      : Boolean(targetValueInput) && (targetType !== "phase" || Boolean(phaseId));

  return <div className="fitness-module__nutrition-stack">
    <FitnessLoadingOrError loading={settings.loading || targets.loading} error={settings.error ?? targets.error} retry={() => { settings.reload(); targets.reload(); }} />
    <div className="fitness-module__grid">
      <FitnessCard title="Nutrition day boundary" detail="Entries before the boundary belong to the preceding nutrition day.">
        <div className="fitness-module__fields"><label className="fitness-module__field">Day starts at<input type="time" min="00:00" max="08:00" step="900" value={`${String(Math.floor(boundary / 60)).padStart(2, "0")}:${String(boundary % 60).padStart(2, "0")}`} onChange={(event) => { const [hours, minutes] = event.target.value.split(":").map(Number); setBoundary(Math.min(480, Math.max(0, hours * 60 + minutes))); }} /><small>Allowed range 00:00–08:00; default 04:00.</small></label></div>
        <div className="fitness-module__callout"><strong>Explicit regrouping</strong><p>Changing this setting can move early-morning entries between diary days. Nutrient totals on each entry do not change.</p></div>
        <button type="button" className="button button--primary" disabled={!online || rebucketBusy || boundary === settings.data.nutrition_day_start_minutes} onClick={() => void rebucketDiary()}>{rebucketBusy ? "Regrouping…" : "Save boundary and rebucket diary"}</button>
        {rebucketResult ? <p className="fitness-module__form-status is-saved" role="status"><CheckCircle2 aria-hidden="true" size={16} /> {rebucketResult}</p> : null}{rebucketError ? <p className="fitness-module__form-status is-error" role="alert">{rebucketError}</p> : null}
      </FitnessCard>

      <FitnessCard title="Nutrition targets" detail="Fixed, range, weekly-average, training/rest, and accepted phase targets.">
        <button type="button" className="button button--primary" onClick={() => setTargetForm(true)}><Plus aria-hidden="true" size={16} /> Add target</button>
        {targets.data.filter((target) => target.active !== false).length ? <ul className="fitness-module__list">{targets.data.filter((target) => target.active !== false).map((target) => <li id={`fitness-nutrition-target-${target.id}`} tabIndex={-1} key={target.id}><div><strong>{nutrientLabels[target.metric_key as FitnessNutrientKey] ?? titleCase(target.metric_key)}</strong><small>{targetDescription(target)} · {titleCase(target.target_type)}</small><small>{formatFitnessDate(target.effective_from)}{target.effective_until ? ` – ${formatFitnessDate(target.effective_until)}` : " onwards"}</small></div><button type="button" className="button button--secondary button--compact" onClick={() => setConfirmArchive(target)}><Archive aria-hidden="true" size={14} /> Archive</button></li>)}</ul> : <div className="fitness-module__empty"><strong>No active nutrition targets</strong><span>The diary still works without one and never adds wearable exercise Calories automatically.</span></div>}
      </FitnessCard>
    </div>

    {targetForm ? <FitnessCard title="Add nutrition target" detail="Phase and coach-proposed changes become active only after explicit acceptance here."><form className="fitness-module__form" onSubmit={submitForm(saveTarget)}><div className="fitness-module__fields"><label className="fitness-module__field">Nutrient<select value={metric} onChange={(event) => setMetric(event.target.value as FitnessNutrientKey)}>{FITNESS_NUTRIENT_KEYS.map((key) => <option value={key} key={key}>{nutrientLabels[key]}</option>)}</select></label><label className="fitness-module__field">Target form<select value={targetType} onChange={(event) => setTargetType(event.target.value as FitnessNutritionTargetMode)}><option value="fixed">Fixed daily</option><option value="range">Daily range</option><option value="weekly_average">Weekly average</option><option value="training_rest">Training vs rest day</option><option value="phase">Phase-based</option></select></label>{needsValue ? <label className="fitness-module__field">Target ({metric === "calories_kcal" ? "kcal" : "g"})<input type="number" min="0" step="any" required value={targetValueInput} onChange={(event) => setTargetValueInput(event.target.value)} /></label> : null}{targetType === "range" ? <><label className="fitness-module__field">Minimum<input type="number" min="0" step="any" required value={targetMin} onChange={(event) => setTargetMin(event.target.value)} /></label><label className="fitness-module__field">Maximum<input type="number" min="0" step="any" required value={targetMax} onChange={(event) => setTargetMax(event.target.value)} /></label></> : null}{targetType === "training_rest" ? <><label className="fitness-module__field">Training-day target<input type="number" min="0" step="any" required value={trainingValue} onChange={(event) => setTrainingValue(event.target.value)} /></label><label className="fitness-module__field">Rest-day target<input type="number" min="0" step="any" required value={restValue} onChange={(event) => setRestValue(event.target.value)} /></label></> : null}{targetType === "phase" ? <label className="fitness-module__field">Accepted phase<select required value={phaseId} onChange={(event) => setPhaseId(event.target.value)}><option value="">Choose a phase</option>{phases.data.filter((phase) => phase.active !== false).map((phase) => <option value={phase.id} key={phase.id}>{phase.name}</option>)}</select></label> : null}<label className="fitness-module__field">Effective from<input type="date" required value={effectiveFrom} onChange={(event) => setEffectiveFrom(event.target.value)} /></label><label className="fitness-module__field">Effective until (optional)<input type="date" min={effectiveFrom} value={effectiveUntil} onChange={(event) => setEffectiveUntil(event.target.value)} /></label></div><p className="fitness-module__privacy-note"><AlertTriangle aria-hidden="true" size={16} /> Targets use logged intake. Wearable exercise Calories are not automatically added.</p><div className="fitness-module__form-footer"><button type="submit" className="button button--primary" disabled={targetSave.saving || !targetValid}>Save target</button><button type="button" className="button button--secondary" onClick={() => setTargetForm(false)}>Cancel</button><FitnessFormStatus saving={targetSave.saving} saved={targetSave.saved} error={targetSave.saveError} /></div></form></FitnessCard> : null}

    {confirmArchive ? <FitnessCard title="Archive this target?" detail="Historical diary data stays unchanged."><p>{nutrientLabels[confirmArchive.metric_key as FitnessNutrientKey] ?? confirmArchive.metric_key}: {targetDescription(confirmArchive)}</p><div className="fitness-module__button-row"><button type="button" className="button button--danger" onClick={() => void archiveTarget(confirmArchive)}>Archive target</button><button type="button" className="button button--secondary" onClick={() => setConfirmArchive(null)}>Keep active</button></div></FitnessCard> : null}
  </div>;
}
