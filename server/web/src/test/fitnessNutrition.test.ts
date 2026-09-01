import { describe, expect, it } from "vitest";

import type {
  FitnessFood,
  FitnessFoodLogEntry,
  FitnessFoodVersion,
  FitnessMealTemplate,
  FitnessRecipeComponent,
} from "../fitness/contract";
import {
  aggregateNutritionEntries,
  authoritativeCalories,
  calculateRecipeNutrition,
  nutritionAddedHighlight,
  nutritionDateForLocalInput,
  repeatFoodLogPayloads,
  templateLogPayloads,
} from "../fitness/nutrition";

function foodVersion(overrides: Partial<FitnessFoodVersion> = {}): FitnessFoodVersion {
  return {
    id: "version-1",
    reference_amount: 100,
    reference_unit: "g",
    calories_kcal: 200,
    protein_g: 10,
    carbohydrate_g: 20,
    sugars_g: 4,
    fat_g: 8,
    saturated_fat_g: 2,
    fibre_g: 3,
    salt_g: 0.5,
    ...overrides,
  };
}

function logEntry(overrides: Partial<FitnessFoodLogEntry> = {}): FitnessFoodLogEntry {
  return {
    id: "entry-1",
    food_version_id: "version-1",
    logged_at_utc: "2026-08-01T05:30:00.000Z",
    local_timezone: "Europe/London",
    meal_key: "breakfast",
    entered_amount: 100,
    entered_unit: "g",
    canonical_amount: 100,
    canonical_unit: "g",
    measurement_quality: "weighed",
    ...overrides,
  };
}

describe("Fitness Nutrition arithmetic and repeat semantics", () => {
  it("celebrates the most useful known nutrition fact after a food is added", () => {
    expect(nutritionAddedHighlight({ calories_kcal: 420, protein_g: 30, fibre_g: 8 })).toBe("30 g protein");
    expect(nutritionAddedHighlight({ calories_kcal: 180, protein_g: 0, fibre_g: 4.25 })).toBe("4.3 g fibre");
    expect(nutritionAddedHighlight({ calories_kcal: 97, protein_g: null, fibre_g: null })).toBe("97 kcal logged");
    expect(nutritionAddedHighlight({ calories_kcal: null, protein_g: null, fibre_g: null })).toBeNull();
  });

  it("uses printed kcal when both kcal and kJ exist, and converts kJ only when needed", () => {
    expect(authoritativeCalories({
      caloriesKcal: 123,
      sourceEnergyValue: 900,
      sourceEnergyUnit: "kj",
    })).toBe(123);
    expect(authoritativeCalories({
      caloriesKcal: null,
      sourceEnergyValue: 418.4,
      sourceEnergyUnit: "kj",
    })).toBeCloseTo(100);
  });

  it("never presents a partial nutrient sum as an exact daily total", () => {
    const known = foodVersion();
    const incomplete = foodVersion({ id: "version-2", protein_g: null });
    const foods: FitnessFood[] = [
      { id: "food-1", name: "Known", current_version: known, versions: [known] },
      { id: "food-2", name: "Incomplete", current_version: incomplete, versions: [incomplete] },
    ];
    const result = aggregateNutritionEntries([
      logEntry(),
      logEntry({ id: "entry-2", food_version_id: "version-2" }),
    ], foods);

    expect(result.totals.calories_kcal).toBe(400);
    expect(result.totals.protein_g).toBeNull();
    expect(result.uncertain).toContain("protein_g");
  });

  it("propagates unknown recipe nutrients and applies cooked yield to per-100g values", () => {
    const versions = new Map<string, FitnessFoodVersion>([
      ["known", foodVersion({ id: "known", calories_kcal: 300, protein_g: 12 })],
      ["unknown", foodVersion({ id: "unknown", calories_kcal: 100, protein_g: null })],
    ]);
    const components: FitnessRecipeComponent[] = [
      { food_version_id: "known", amount: 100, unit: "g", canonical_amount: 100, canonical_unit: "g" },
      { food_version_id: "unknown", amount: 100, unit: "g", canonical_amount: 100, canonical_unit: "g" },
    ];

    const result = calculateRecipeNutrition(components, versions, 400);
    expect(result.totals.calories_kcal).toBe(400);
    expect(result.per100g?.calories_kcal).toBe(100);
    expect(result.totals.protein_g).toBeNull();
    expect(result.per100g?.protein_g).toBeNull();
  });

  it("repeats immutable references into the current timezone and recalculates the boundary day", () => {
    const [payload] = repeatFoodLogPayloads(
      [logEntry({ meal_key: "breakfast", context_tags: ["pre-school"] })],
      "2026-08-10",
      "Europe/Berlin",
      480,
      "breakfast",
    );

    expect(payload).toMatchObject({
      food_version_id: "version-1",
      local_timezone: "Europe/Berlin",
      meal_key: "breakfast",
      nutrition_date: nutritionDateForLocalInput("2026-08-10T07:30:00", 480),
      context_tags: ["pre-school"],
    });
  });

  it("scales a template's canonical amount even when its display unit differs", () => {
    const template: FitnessMealTemplate = {
      id: "template-1",
      name: "Breakfast",
      meal_key: "breakfast",
      items: [{
        id: "item-1",
        food_version_id: "version-1",
        amount: 1,
        unit: "bowl",
        canonical_amount: 240,
        canonical_unit: "g",
        measurement_quality: "standard_serving",
      }],
    };
    const [payload] = templateLogPayloads(
      template,
      "2026-08-02T07:00:00.000Z",
      "Europe/Berlin",
      { "item-1": 1.5 },
    );

    expect(payload).toMatchObject({
      entered_amount: 1.5,
      entered_unit: "bowl",
      canonical_amount: 360,
      canonical_unit: "g",
    });
  });
});
