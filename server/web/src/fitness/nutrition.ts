import type {
  FitnessFood,
  FitnessFoodLogEntry,
  FitnessNutritionMeasurementQuality,
  FitnessFoodVersion,
  FitnessMealKey,
  FitnessMealTemplate,
  FitnessNutritionNutrients,
  FitnessNutritionQuickPick,
  FitnessRecipeComponent,
} from "./contract";

export type FitnessPortionOption = {
  key: string;
  label: string;
  enteredUnit: string;
  defaultAmount: number;
  canonicalAmount: number;
  canonicalUnit: string;
  measurementQuality: FitnessNutritionMeasurementQuality;
};

export const FITNESS_NUTRIENT_KEYS = [
  "calories_kcal",
  "protein_g",
  "carbohydrate_g",
  "fibre_g",
  "fat_g",
  "saturated_fat_g",
  "sugars_g",
  "salt_g",
] as const;

export type FitnessNutrientKey = typeof FITNESS_NUTRIENT_KEYS[number];

type NutritionHighlightValues = Pick<
  Partial<FitnessNutritionNutrients>,
  "calories_kcal" | "protein_g" | "fibre_g"
>;

function compactNutrientValue(value: number): string {
  return Number.isInteger(value)
    ? value.toFixed(0)
    : value.toFixed(1).replace(/\.0$/, "");
}

/** A small, factual reward after logging food; protein wins, then fibre, then energy. */
export function nutritionAddedHighlight(values?: NutritionHighlightValues | null): string | null {
  const protein = values?.protein_g;
  if (typeof protein === "number" && Number.isFinite(protein) && protein >= 5) {
    return `${compactNutrientValue(protein)} g protein`;
  }
  const fibre = values?.fibre_g;
  if (typeof fibre === "number" && Number.isFinite(fibre) && fibre >= 2) {
    return `${compactNutrientValue(fibre)} g fibre`;
  }
  if (typeof protein === "number" && Number.isFinite(protein) && protein > 0) {
    return `${compactNutrientValue(protein)} g protein`;
  }
  const calories = values?.calories_kcal;
  if (typeof calories === "number" && Number.isFinite(calories) && calories > 0) {
    return `${Math.round(calories)} kcal logged`;
  }
  return null;
}

export function currentFoodVersion(food?: FitnessFood | null): FitnessFoodVersion | null {
  return food?.current_version ?? food?.latest_version ?? food?.version ?? null;
}

export function foodPortionOptions(food: FitnessFood): FitnessPortionOption[] {
  const version = currentFoodVersion(food);
  if (!version) return [];
  const base: FitnessPortionOption = {
    key: `base:${version.reference_unit}`,
    label: version.reference_unit,
    enteredUnit: version.reference_unit,
    defaultAmount: version.reference_amount,
    canonicalAmount: version.reference_amount,
    canonicalUnit: version.reference_unit,
    measurementQuality: "estimated",
  };
  const seenUnits = new Set([version.reference_unit]);
  const servings = (food.servings ?? []).flatMap((serving): FitnessPortionOption[] => {
    if (serving.active === false || serving.amount <= 0 || serving.canonical_amount <= 0 || seenUnits.has(serving.unit)) return [];
    seenUnits.add(serving.unit);
    return [{
      key: `serving:${serving.id}`,
      label: serving.name.localeCompare(serving.unit, undefined, { sensitivity: "accent" }) === 0
        ? serving.unit
        : `${serving.name} (${serving.unit})`,
      enteredUnit: serving.unit,
      defaultAmount: serving.amount,
      canonicalAmount: serving.canonical_amount,
      canonicalUnit: serving.canonical_unit,
      measurementQuality: serving.measurement_quality,
    }];
  });
  return [base, ...servings];
}

export function defaultFoodPortion(food: FitnessFood): { amount: number; option: FitnessPortionOption } | null {
  const options = foodPortionOptions(food);
  const base = options[0];
  if (!base) return null;
  const quickAmounts = [
    [food.quick_use?.usual_amount, food.quick_use?.usual_unit],
    [food.quick_use?.last_amount, food.quick_use?.last_unit],
  ] as const;
  for (const [amount, unit] of quickAmounts) {
    if (amount == null || amount <= 0 || !unit) continue;
    const option = options.find((candidate) => candidate.enteredUnit === unit);
    if (!option || option.canonicalUnit !== base.canonicalUnit) continue;
    return {
      amount: amount / option.defaultAmount * option.canonicalAmount,
      option: base,
    };
  }
  return { amount: base.defaultAmount, option: base };
}

export function canonicalPortion(
  option: FitnessPortionOption,
  amount: number,
): { amount: number; unit: string; quality: FitnessNutritionMeasurementQuality } {
  return {
    amount: amount / option.defaultAmount * option.canonicalAmount,
    unit: option.canonicalUnit,
    quality: option.measurementQuality,
  };
}

export function authoritativeCalories({
  caloriesKcal,
  sourceEnergyValue,
  sourceEnergyUnit,
}: {
  caloriesKcal?: number | null;
  sourceEnergyValue?: number | null;
  sourceEnergyUnit?: "kcal" | "kj" | null;
}): number | null {
  if (caloriesKcal != null) return caloriesKcal;
  if (sourceEnergyValue == null) return null;
  if (sourceEnergyUnit === "kcal") return sourceEnergyValue;
  if (sourceEnergyUnit === "kj") return sourceEnergyValue / 4.184;
  return null;
}

function nutrientFromVersion(version: FitnessFoodVersion, key: FitnessNutrientKey): number | null {
  const value = version[key];
  return typeof value === "number" && Number.isFinite(value) ? value : null;
}

export function nutrientsForFoodAmount(
  version: FitnessFoodVersion,
  canonicalAmount: number,
): FitnessNutritionNutrients {
  const scale = version.reference_amount > 0 ? canonicalAmount / version.reference_amount : 0;
  return Object.fromEntries(FITNESS_NUTRIENT_KEYS.map((key) => {
    const value = nutrientFromVersion(version, key);
    return [key, value == null ? null : value * scale];
  })) as FitnessNutritionNutrients;
}

/** The single rule for which nutrition day a diary entry belongs to. */
export function foodLogEntryIsOnDate(entry: FitnessFoodLogEntry, nutritionDate: string): boolean {
  if (entry?.nutrition_date) return entry.nutrition_date === nutritionDate;
  return typeof entry?.logged_at_utc === "string"
    && entry.logged_at_utc.slice(0, 10) === nutritionDate;
}

export function nutrientsForLogEntry(
  entry: FitnessFoodLogEntry,
  foods: FitnessFood[],
): FitnessNutritionNutrients {
  const food = foods.find((candidate) => (
    candidate.id === entry.food_id
    || candidate.versions?.some((version) => version.id === entry.food_version_id)
    || currentFoodVersion(candidate)?.id === entry.food_version_id
  ));
  const version = food?.versions?.find((candidate) => candidate.id === entry.food_version_id)
    ?? currentFoodVersion(food);
  const fallback = version ? nutrientsForFoodAmount(version, entry.canonical_amount) : null;
  return Object.fromEntries(FITNESS_NUTRIENT_KEYS.map((key) => {
    if (key in entry) {
      const value = entry[key];
      return [key, typeof value === "number" && Number.isFinite(value) ? value : null];
    }
    return [key, fallback?.[key] ?? null];
  })) as FitnessNutritionNutrients;
}

export function aggregateNutritionEntries(
  entries: FitnessFoodLogEntry[],
  foods: FitnessFood[],
): { totals: FitnessNutritionNutrients; uncertain: FitnessNutrientKey[] } {
  const values = entries.map((entry) => nutrientsForLogEntry(entry, foods));
  const totals = Object.fromEntries(FITNESS_NUTRIENT_KEYS.map((key) => {
    const nutrientValues = values.map((item) => item[key]);
    const known = nutrientValues.filter((value): value is number => value != null);
    // A day total is not exact if any contributing entry lacks this nutrient.
    return [key, nutrientValues.some((value) => value == null) || known.length === 0
      ? null
      : known.reduce((sum, value) => sum + value, 0)];
  })) as FitnessNutritionNutrients;
  const uncertain = FITNESS_NUTRIENT_KEYS.filter((key) => values.some((item) => item[key] == null));
  return { totals, uncertain };
}

export function nutritionDateForLocalInput(localDateTime: string, dayStartMinutes: number): string {
  const parsed = new Date(localDateTime);
  if (Number.isNaN(parsed.valueOf())) throw new Error("Choose a valid food time.");
  parsed.setMinutes(parsed.getMinutes() - dayStartMinutes);
  const year = parsed.getFullYear();
  const month = String(parsed.getMonth() + 1).padStart(2, "0");
  const day = String(parsed.getDate()).padStart(2, "0");
  return `${year}-${month}-${day}`;
}

function localTimeParts(value: string): { hours: number; minutes: number; seconds: number } {
  const date = new Date(value);
  return Number.isNaN(date.valueOf())
    ? { hours: 12, minutes: 0, seconds: 0 }
    : { hours: date.getHours(), minutes: date.getMinutes(), seconds: date.getSeconds() };
}

export function repeatFoodLogPayloads(
  entries: FitnessFoodLogEntry[],
  targetDate: string,
  targetTimezone: string,
  nutritionDayStartMinutes: number,
  mealKey?: FitnessMealKey | string,
): Array<Record<string, unknown>> {
  return entries
    .filter((entry) => !mealKey || entry.meal_key === mealKey)
    .map((entry) => {
      const time = localTimeParts(entry.logged_at_utc);
      const localInput = `${targetDate}T${String(time.hours).padStart(2, "0")}:${String(time.minutes).padStart(2, "0")}:${String(time.seconds).padStart(2, "0")}`;
      const local = new Date(localInput);
      return {
        food_version_id: entry.food_version_id ?? null,
        recipe_version_id: entry.recipe_version_id ?? null,
        logged_at_utc: local.toISOString(),
        local_timezone: targetTimezone,
        meal_key: entry.meal_key,
        entered_amount: entry.entered_amount,
        entered_unit: entry.entered_unit,
        canonical_amount: entry.canonical_amount,
        canonical_unit: entry.canonical_unit,
        measurement_quality: entry.measurement_quality ?? "estimated",
        notes: entry.notes ?? null,
        context_tags: entry.context_tags ?? entry.context_tags_json ?? [],
        nutrition_date: nutritionDateForLocalInput(localInput, nutritionDayStartMinutes),
      };
    });
}

export function templateLogPayloads(
  template: FitnessMealTemplate,
  loggedAtUtc: string,
  localTimezone: string,
  amounts: Record<string, number> = {},
): Array<Record<string, unknown>> {
  return template.items.map((item, index) => ({
    food_version_id: item.food_version_id ?? null,
    recipe_version_id: item.recipe_version_id ?? null,
    logged_at_utc: loggedAtUtc,
    local_timezone: localTimezone,
    meal_key: template.meal_key,
    entered_amount: amounts[item.id ?? String(index)] ?? item.amount,
    entered_unit: item.unit,
    canonical_amount: (amounts[item.id ?? String(index)] ?? item.amount) / item.amount * item.canonical_amount,
    canonical_unit: item.canonical_unit,
    measurement_quality: item.measurement_quality,
    context_tags: [],
  }));
}

export function quickNutritionPicks(
  foods: FitnessFood[],
  templates: FitnessMealTemplate[],
  mealKey: FitnessMealKey | string,
): FitnessNutritionQuickPick[] {
  const picks: FitnessNutritionQuickPick[] = [];
  for (const template of templates.filter((item) => item.active !== false)) {
    if (!template.favourite && template.meal_key !== mealKey && template.time_relevance !== mealKey) continue;
    picks.push({
      key: `template:${template.id}`,
      kind: "template",
      label: template.name,
      reason: template.favourite ? "favourite" : "time_relevant",
      template_id: template.id,
    });
  }
  for (const food of foods.filter((item) => item.active !== false && currentFoodVersion(item)?.id)) {
    const quick = food.quick_use;
    const reason = quick?.recent_meal_keys?.includes(mealKey as FitnessMealKey)
      ? "recent"
      : food.favourite
        ? "favourite"
        : (quick?.frequency_count ?? 0) > 1
          ? "frequent"
          : quick?.usual_amount != null
            ? "usual"
            : null;
    if (!reason) continue;
    const version = currentFoodVersion(food);
    picks.push({
      key: `food:${food.id}`,
      kind: "food",
      label: food.name,
      reason,
      food_id: food.id,
      food_version_id: version?.id,
      amount: quick?.usual_amount ?? quick?.last_amount ?? version?.reference_amount ?? null,
      unit: quick?.usual_unit ?? quick?.last_unit ?? version?.reference_unit ?? null,
    });
  }
  return picks.slice(0, 12);
}

export function calculateRecipeNutrition(
  components: FitnessRecipeComponent[],
  versions: Map<string, FitnessFoodVersion>,
  finishedWeightG?: number | null,
): { totals: FitnessNutritionNutrients; per100g: FitnessNutritionNutrients | null } {
  const totals = Object.fromEntries(FITNESS_NUTRIENT_KEYS.map((key) => {
    const scaled = components.map((component) => {
      const version = versions.get(component.food_version_id);
      if (!version || version.reference_amount <= 0) return null;
      const value = nutrientFromVersion(version, key);
      return value == null ? null : value * component.canonical_amount / version.reference_amount;
    });
    return [key, scaled.some((value) => value == null)
      ? null
      : scaled.reduce<number>((sum, value) => sum + (value ?? 0), 0)];
  })) as FitnessNutritionNutrients;
  const per100g = finishedWeightG && finishedWeightG > 0
    ? Object.fromEntries(FITNESS_NUTRIENT_KEYS.map((key) => [
      key,
      totals[key] == null ? null : totals[key] * 100 / finishedWeightG,
    ])) as FitnessNutritionNutrients
    : null;
  return { totals, per100g };
}
