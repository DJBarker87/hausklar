import { fireEvent, render, screen, waitFor } from "@testing-library/react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import { api } from "../api";
import {
  cachedFitnessFoodLogDay,
  deleteFitnessRecord,
  queueFitnessNutritionLabel,
  saveFitnessRecord,
  saveFitnessRecords,
} from "../fitness/offlineStore";
import {
  FitnessFoodCataloguePanel,
  FitnessMealTemplatesPanel,
  FitnessNutritionDiaryPanel,
  FitnessNutritionTargetsPanel,
  FitnessRecipesPanel,
} from "../views/fitness/FitnessNutritionPanels";

vi.mock("../api", () => ({
  api: vi.fn(),
  ApiError: class ApiError extends Error {
    status: number;
    constructor(message: string, status: number) { super(message); this.status = status; }
  },
}));

vi.mock("../fitness/offlineStore", () => ({
  cacheFitnessRecords: vi.fn().mockResolvedValue(undefined),
  cacheFitnessFoodLogDay: vi.fn().mockResolvedValue(undefined),
  cachedFitnessFoodLogDay: vi.fn().mockResolvedValue(null),
  cachedFitnessRecords: vi.fn().mockResolvedValue([]),
  saveFitnessRecord: vi.fn(),
  saveFitnessRecords: vi.fn(),
  deleteFitnessRecord: vi.fn().mockResolvedValue(undefined),
  fitnessNutritionLabelsOnDevice: vi.fn().mockResolvedValue([]),
  flushFitnessNutritionLabels: vi.fn().mockResolvedValue([]),
  queueFitnessNutritionLabel: vi.fn(),
  retryFitnessNutritionLabel: vi.fn().mockResolvedValue(undefined),
}));

const apiMock = vi.mocked(api);
const saveMock = vi.mocked(saveFitnessRecord);
const saveManyMock = vi.mocked(saveFitnessRecords);
const deleteMock = vi.mocked(deleteFitnessRecord);
const cachedDayMock = vi.mocked(cachedFitnessFoodLogDay);
const queueLabelMock = vi.mocked(queueFitnessNutritionLabel);

const food = {
  id: "00000000-0000-4000-8000-000000000101",
  revision: 4,
  name: "Porridge",
  active: true,
  current_version: {
    id: "00000000-0000-4000-8000-000000000102",
    version_number: 2,
    reference_amount: 100,
    reference_unit: "g",
    calories_kcal: 200,
    protein_g: 10,
    carbohydrate_g: 32,
    fibre_g: 4,
    fat_g: 4,
    saturated_fat_g: 1,
    sugars_g: 2,
    salt_g: 0.2,
  },
  versions: [],
  servings: [{
    id: "00000000-0000-4000-8000-000000000103",
    food_id: "00000000-0000-4000-8000-000000000101",
    name: "one bowl",
    amount: 1,
    unit: "bowl",
    canonical_amount: 240,
    canonical_unit: "g",
    measurement_quality: "standard_serving",
    active: true,
  }],
};
food.versions = [food.current_version] as never;

const otherFood = {
  ...food,
  id: "00000000-0000-4000-8000-000000000201",
  name: "Oatmeal",
  current_version: { ...food.current_version, id: "00000000-0000-4000-8000-000000000202" },
  versions: [{ ...food.current_version, id: "00000000-0000-4000-8000-000000000202" }],
  servings: [],
};

const template = {
  id: "00000000-0000-4000-8000-000000000301",
  name: "Early breakfast",
  meal_key: "breakfast",
  time_relevance: "breakfast",
  active: true,
  items: [{
    id: "00000000-0000-4000-8000-000000000302",
    food_version_id: food.current_version.id,
    label: food.name,
    amount: 1,
    unit: "bowl",
    canonical_amount: 240,
    canonical_unit: "g",
    measurement_quality: "standard_serving",
  }],
};

const props = {
  online: true,
  revision: 0,
  onDataChanged: vi.fn(),
  onSectionChange: vi.fn(),
};

function dateFromFoodLogPath(path: string) {
  return new URLSearchParams(path.split("?")[1] ?? "").get("date") ?? "2026-08-02";
}

function offsetDate(value: string, days: number) {
  const date = new Date(`${value}T12:00:00`);
  date.setDate(date.getDate() + days);
  return `${date.getFullYear()}-${String(date.getMonth() + 1).padStart(2, "0")}-${String(date.getDate()).padStart(2, "0")}`;
}

function installApi(foodLogOverrides: Record<string, unknown> = {}, analysisOverrides: Record<string, unknown> = {}) {
  apiMock.mockImplementation(async (path, init) => {
    const requestPath = String(path);
    if (requestPath === "/fitness/foods") return [food, otherFood] as never;
    if (requestPath === "/fitness/recipes") return [] as never;
    if (requestPath === "/fitness/meal-templates") return [template] as never;
    if (requestPath === "/fitness/nutrition/settings") return {
      id: "nutrition-settings",
      timezone: "Europe/Berlin",
      nutrition_day_start_minutes: 480,
    } as never;
    if (requestPath.startsWith("/fitness/nutrition/targets")) return [] as never;
    if (requestPath === "/fitness/phases") return [{
      id: "phase-1",
      phase_type: "build",
      name: "Autumn build",
      starts_on: "2026-08-01",
      active: true,
    }] as never;
    if (requestPath.startsWith("/fitness/food-log?")) {
      const date = dateFromFoodLogPath(requestPath);
      return {
        nutrition_date: date,
        entries: [{
          id: "00000000-0000-4000-8000-000000000401",
          revision: 7,
          food_version_id: food.current_version.id,
          food_name: food.name,
          logged_at_utc: `${date}T09:00:00.000Z`,
          local_timezone: "Europe/Berlin",
          nutrition_date: date,
          meal_key: "breakfast",
          entered_amount: 120,
          entered_unit: "g",
          canonical_amount: 120,
          canonical_unit: "g",
          calories_kcal: 240,
          protein_g: 12,
          carbohydrate_g: 38.4,
          fibre_g: 4.8,
          fat_g: 4.8,
          saturated_fat_g: 1.2,
          sugars_g: 2.4,
          salt_g: 0.24,
          measurement_quality: "weighed",
        }],
        totals: {},
        targets: { calories_kcal: 2000, protein_g: 30 },
        remaining: { calories_kcal: 1760, protein_g: 18 },
        contributors: [{ key: food.id, label: food.name, kind: "food", nutrient_key: "protein_g", value: 12, entry_count: 1 }],
        measured_share: 1,
        estimated_share: 0,
        ...foodLogOverrides,
      } as never;
    }
    if (requestPath.startsWith("/fitness/nutrition/analysis?")) {
      const params = new URLSearchParams(requestPath.split("?")[1] ?? "");
      const start = params.get("start") ?? "2026-07-07";
      const end = params.get("end") ?? "2026-08-03";
      return {
        start,
        end,
        sample_days: 0,
        calendar_days: 28,
        completeness: 0,
        contributors: [],
        recommendation: null,
        ...analysisOverrides,
      } as never;
    }
    if (requestPath === "/fitness/foods/merge/preview") return {
      source_id: food.id,
      target_id: otherFood.id,
      already_merged: false,
      versions: 2,
      servings: 1,
      affected_log_entries: 3,
      affected_recipe_components: 1,
      affected_template_items: 1,
      warnings: ["Oatmeal remains the food used everywhere."],
    } as never;
    if (requestPath === "/fitness/foods/merge") return JSON.parse(String(init?.body)) as never;
    if (requestPath === "/fitness/nutrition/settings/rebucket") return {
      nutrition_day_start_minutes: 420,
      affected_entries: 2,
      status: "complete",
    } as never;
    throw new Error(`Unexpected Nutrition request: ${requestPath}`);
  });
}

describe("Fitness Nutrition completion workflows", () => {
  beforeEach(() => {
    // Keep boundary-sensitive diary expectations independent of the calendar
    // date on which the suite happens to run.
    vi.useFakeTimers({ toFake: ["Date"] });
    vi.setSystemTime(new Date(2026, 7, 20, 12, 0));
    apiMock.mockReset();
    saveMock.mockReset();
    saveManyMock.mockReset();
    deleteMock.mockClear();
    deleteMock.mockResolvedValue(undefined);
    cachedDayMock.mockReset();
    cachedDayMock.mockResolvedValue(null);
    queueLabelMock.mockReset();
    props.onDataChanged.mockReset();
    window.localStorage.removeItem("hausklar:fitness:nutrition-day-start-minutes");
    Object.defineProperty(window.navigator, "onLine", { configurable: true, value: true });
    installApi();
    saveMock.mockImplementation(async (_entityType, payload, options) => ({
      ...payload,
      id: options?.entityId ?? crypto.randomUUID(),
      queued_offline: true,
    }));
    saveManyMock.mockImplementation(async (inputs) => inputs.map((input) => ({
      ...input.payload,
      id: input.options?.entityId ?? crypto.randomUUID(),
      queued_offline: true,
    })));
  });

  afterEach(() => {
    vi.useRealTimers();
    window.localStorage.removeItem("hausklar:fitness:nutrition-day-start-minutes");
  });

  it("opens the current nutrition day before 04:00, preserves navigation, and makes Today boundary-aware", async () => {
    vi.setSystemTime(new Date(2026, 7, 3, 1, 30));
    window.localStorage.setItem("hausklar:fitness:nutrition-day-start-minutes", "240");

    const baseImplementation = apiMock.getMockImplementation();
    let resolveSettings: ((value: unknown) => void) | undefined;
    const settingsResponse = new Promise((resolve) => { resolveSettings = resolve; });
    apiMock.mockImplementation((path, init) => {
      if (String(path) === "/fitness/nutrition/settings") return settingsResponse as never;
      if (!baseImplementation) throw new Error("Nutrition API fixture is missing");
      return baseImplementation(path, init);
    });

    render(<FitnessNutritionDiaryPanel {...props} openLogRequest={0} onOpenTemplates={vi.fn()} />);
    const dateInput = await screen.findByLabelText("Nutrition day");
    expect(dateInput).toHaveValue("2026-08-02");
    expect(screen.getByLabelText("Repeat into")).toHaveValue("2026-08-03");
    expect(apiMock).toHaveBeenCalledWith("/fitness/food-log?date=2026-08-02", {}, true, false);

    fireEvent.click(screen.getByRole("button", { name: "Previous nutrition day" }));
    expect(await screen.findByLabelText("Nutrition day")).toHaveValue("2026-08-01");
    await waitFor(() => expect(screen.getByLabelText("Repeat into")).toHaveValue("2026-08-02"));

    resolveSettings?.({
      id: "nutrition-settings",
      timezone: "Europe/Berlin",
      nutrition_day_start_minutes: 0,
    });
    await waitFor(() => expect(window.localStorage.getItem("hausklar:fitness:nutrition-day-start-minutes")).toBe("0"));
    expect(await screen.findByLabelText("Nutrition day")).toHaveValue("2026-08-01");

    fireEvent.click(screen.getByRole("button", { name: "Today" }));
    expect(await screen.findByLabelText("Nutrition day")).toHaveValue("2026-08-03");
    await waitFor(() => expect(screen.getByLabelText("Repeat into")).toHaveValue("2026-08-04"));
  });

  it("edits, soft-deletes, and atomically repeats immutable diary entries", async () => {
    render(<FitnessNutritionDiaryPanel {...props} openLogRequest={0} onOpenTemplates={vi.fn()} />);
    expect((await screen.findAllByText("Porridge")).length).toBeGreaterThan(0);
    expect(screen.getByText("Measured 100%")).toBeInTheDocument();
    expect(screen.getByText(/This diary day is 18 g below the saved protein target/)).toBeInTheDocument();
    expect(screen.getByText(/the saved diary stays unchanged/)).toBeInTheDocument();
    expect(screen.getByText(/largest recorded protein contributor at 12 g/)).toBeInTheDocument();
    fireEvent.click(screen.getByText("How this was calculated"));
    expect(screen.getByText(/30 g target − 12 g logged = 18 g remaining/)).toBeInTheDocument();

    fireEvent.click(screen.getByRole("button", { name: "Edit Porridge" }));
    fireEvent.change(screen.getByLabelText("Amount (g)"), { target: { value: "150" } });
    fireEvent.change(screen.getByRole("combobox", { name: "Measurement quality" }), { target: { value: "estimated" } });
    fireEvent.click(screen.getByRole("button", { name: "Save diary edit" }));
    await waitFor(() => expect(saveMock).toHaveBeenCalledWith("food_log_entry", expect.objectContaining({
      food_version_id: food.current_version.id,
      entered_amount: 150,
      canonical_amount: 150,
      measurement_quality: "estimated",
    }), { entityId: "00000000-0000-4000-8000-000000000401", baseRevision: 7 }));

    fireEvent.click(await screen.findByRole("button", { name: "Repeat whole day" }));
    await waitFor(() => expect(saveManyMock).toHaveBeenCalledWith([
      expect.objectContaining({
        entityType: "food_log_entry",
        payload: expect.objectContaining({
          food_version_id: food.current_version.id,
          local_timezone: expect.any(String),
          nutrition_date: expect.any(String),
        }),
      }),
    ]));

    fireEvent.click(screen.getByRole("button", { name: "Delete Porridge" }));
    fireEvent.click(screen.getByRole("button", { name: "Remove entry" }));
    await waitFor(() => expect(deleteMock).toHaveBeenCalledWith(
      "food_log_entry",
      "00000000-0000-4000-8000-000000000401",
      7,
    ));
  });

  it("removes a diary entry from view as soon as the device has saved the removal", async () => {
    const entryId = "00000000-0000-4000-8000-000000000401";
    const baseImplementation = apiMock.getMockImplementation()!;
    const day = await (baseImplementation as (path: string) => Promise<{
      entries: Array<Record<string, unknown>>;
    }>)("/fitness/food-log?date=2026-08-02");
    let foodLogRequests = 0;
    apiMock.mockImplementation((path, init) => {
      if (String(path).startsWith("/fitness/food-log?")) {
        foodLogRequests += 1;
        // The refreshed day is still in flight; the diary must not wait for it.
        if (foodLogRequests > 1) return new Promise(() => undefined) as never;
      }
      return baseImplementation(path, init);
    });
    let removedOnDevice = false;
    cachedDayMock.mockImplementation(async () => (removedOnDevice ? [] : day.entries as never));
    let saveRemoval: (() => void) | undefined;
    deleteMock.mockImplementation(() => new Promise<void>((resolve) => {
      saveRemoval = () => { removedOnDevice = true; resolve(); };
    }));

    render(<FitnessNutritionDiaryPanel {...props} openLogRequest={0} onOpenTemplates={vi.fn()} />);
    fireEvent.click(await screen.findByRole("button", { name: "Delete Porridge" }));
    fireEvent.click(screen.getByRole("button", { name: "Remove entry" }));

    const progress = await screen.findByRole("button", { name: "Removing…" });
    expect(progress).toBeDisabled();
    saveRemoval?.();

    await waitFor(() => expect(screen.queryByRole("button", { name: "Delete Porridge" })).not.toBeInTheDocument());
    expect(deleteMock).toHaveBeenCalledWith("food_log_entry", entryId, 7);
    expect(screen.queryByRole("button", { name: "Remove entry" })).not.toBeInTheDocument();
    // The rest of the diary stays on screen while the refreshed day is fetched.
    expect(screen.getByRole("button", { name: "Previous nutrition day" })).toBeInTheDocument();
  });

  it("shows past-day calorie arithmetic without inventing a long-term portion change", async () => {
    installApi({
      targets: { calories_kcal: 200 },
      remaining: { calories_kcal: -40 },
      contributors: [{ key: food.id, label: food.name, kind: "food", nutrient_key: "calories_kcal", value: 240, entry_count: 1 }],
      measured_share: 1,
      estimated_share: 0,
    });
    render(<FitnessNutritionDiaryPanel {...props} openLogRequest={0} onOpenTemplates={vi.fn()} />);
    await screen.findByText(/This diary day is 40 kcal over the saved target/);

    fireEvent.click(screen.getByRole("button", { name: "Previous nutrition day" }));
    expect(await screen.findByText(/This diary day is 40 kcal over the saved target/)).toBeInTheDocument();
    expect(screen.getByText(/All entries use measured or standard-serving amounts/)).toBeInTheDocument();
    expect(screen.queryByText(/reducing Porridge’s recorded portion/)).not.toBeInTheDocument();
    expect(screen.queryByText(/checking those portions/i)).not.toBeInTheDocument();
    expect(screen.queryByText(/Today’s diary/i)).not.toBeInTheDocument();
  });

  it("shows the server-calculated repeated recommendation with progressive evidence", async () => {
    installApi({}, {
      sample_days: 13,
      completeness: 13 / 28,
      contributors: [{
        item_id: food.id,
        item_kind: "food",
        label: "Synthetic public demo record 8",
        meal_key: "dinner",
        nutrient_key: "calories_kcal",
        total: 9360,
        share: 0.42,
        entry_count: 13,
        sample_days: 13,
        typical_amount: 1,
        typical_unit: "serving",
      }, {
        item_id: otherFood.id,
        item_kind: "food",
        label: "Greek yoghurt",
        meal_key: "breakfast",
        nutrient_key: "protein_g",
        total: 182,
        share: 0.31,
        entry_count: 13,
        sample_days: 13,
        typical_amount: 170,
        typical_unit: "g",
      }],
      recommendation: {
        food_or_meal: "Synthetic public demo record 8",
        item_id: food.id,
        item_kind: "food",
        meal_key: "dinner",
        observation_period: { start: "2026-07-21", end: "2026-08-03", calendar_days: 14, logged_days: 13 },
        calculation: {
          observed_average_calories_kcal: 2240,
          target_average_calories_kcal: 2100,
          average_gap_calories_kcal: 140,
          minimum_material_gap_calories_kcal: 25,
          target_days: 13,
        },
        frequency: { entries: 13, days: 13, per_week: 6.5 },
        typical_amount: { value: 1, unit: "serving" },
        proposed_change: {
          kind: "reduce_portion",
          fraction: 0.1,
          amount: 0.1,
          unit: "serving",
          resulting_amount: 0.9,
          description: "On a similar future dinner, reduce the recorded Synthetic public demo record 8 portion by 10% from its typical 1 serving.",
        },
        expected_effect: {
          per_occurrence_calories_kcal: 72,
          period_calories_kcal: 936,
          weekly_calories_kcal: 468,
        },
        uncertainty: {
          nutrient_completeness: 1,
          diary_day_completeness: 13 / 14,
          target_day_coverage: 1,
          estimated_entry_share: 0.08,
          estimated_calorie_share: 0.06,
          description: "The arithmetic uses the recorded portions; estimated entries elsewhere may change the wider comparison.",
        },
        why_practical: "Synthetic public demo record 8 appeared on 13 of 13 logged days, so a modest portion change preserves a familiar dinner.",
      },
    });

    render(<FitnessNutritionDiaryPanel {...props} openLogRequest={0} onOpenTemplates={vi.fn()} />);
    const patternSummary = await screen.findByText(/14-day pattern: reduce Synthetic public demo record 8 by 0.1 serving/);
    const patternDetails = patternSummary.closest("details");
    expect(patternDetails).not.toHaveAttribute("open");
    fireEvent.click(patternSummary);
    expect(patternDetails).toHaveAttribute("open");
    expect(screen.getByText("A repeated, calculated option")).toBeInTheDocument();
    const selectedDate = (screen.getByLabelText("Nutrition day") as HTMLInputElement).value;
    const periodSelect = screen.getByLabelText("Pattern evidence period");
    expect(periodSelect).toHaveValue("14");
    expect(screen.getByRole("option", { name: "7 days" })).toBeInTheDocument();
    expect(screen.getByRole("option", { name: "28 days" })).toBeInTheDocument();
    expect(screen.getByRole("option", { name: "90 days" })).toBeInTheDocument();
    expect(apiMock).toHaveBeenCalledWith(
      `/fitness/nutrition/analysis?start=${offsetDate(selectedDate, -13)}&end=${selectedDate}`,
      { signal: expect.any(AbortSignal) },
      true,
      false,
    );
    expect(screen.getByText(/reduce the recorded Synthetic public demo record 8 portion by 10%/)).toBeInTheDocument();
    expect(screen.getByText(/averaged 2,240 kcal across logged days against a saved target of 2,100 kcal on average: a 140 kcal gap/)).toBeInTheDocument();
    expect(screen.getByText(/about 72 kcal each time, 936 kcal across this period, or 468 kcal per week/)).toBeInTheDocument();

    const evidenceSummary = screen.getByText("Evidence and uncertainty");
    const evidence = evidenceSummary.closest("details");
    expect(evidence).not.toHaveAttribute("open");
    fireEvent.click(evidenceSummary);
    expect(evidence).toHaveAttribute("open");
    expect(screen.getByText(/appears 13 times across 13 days \(6.5 times per week\), typically 1 serving/)).toBeInTheDocument();
    expect(screen.getByText(/2,240 − 2,100 = 140/)).toBeInTheDocument();
    expect(screen.getByText(/Calories are present for 100% of entries; 93% of days in the window have diary entries; targets cover 100% of logged days; 8% of entries are estimated; and those estimates account for 6% of recorded calories/)).toBeInTheDocument();
    expect(screen.getByText("Largest recorded Calorie contributors")).toBeInTheDocument();
    fireEvent.change(screen.getByLabelText("Contributor nutrient"), { target: { value: "protein_g" } });
    expect(screen.getByText("Largest recorded Protein contributors")).toBeInTheDocument();
    expect(screen.getByText("Greek yoghurt")).toBeInTheDocument();
    expect(screen.getByText(/182 g · 31%/)).toBeInTheDocument();

    fireEvent.change(periodSelect, { target: { value: "7" } });
    await waitFor(() => expect(apiMock).toHaveBeenCalledWith(
      `/fitness/nutrition/analysis?start=${offsetDate(selectedDate, -6)}&end=${selectedDate}`,
      { signal: expect.any(AbortSignal) },
      true,
      false,
    ));
    expect(periodSelect).toHaveValue("7");
  });

  it("queues a private label with printed kcal authority and previews an explicit merge", async () => {
    queueLabelMock.mockImplementation(async (_file, input) => ({
      record: { ...input.payload, id: input.options?.entityId ?? "food-new", queued_offline: true },
      label: {
        id: "label-1",
        assetId: "asset-1",
        dependentEntityType: input.entityType,
        dependentEntityId: input.options?.entityId ?? "food-new",
        dependentMutationId: "mutation-1",
        fileName: "label.jpg",
        fileSize: 4,
        fileType: "image/jpeg",
        fileLastModified: 0,
        state: "pending_upload",
        uploadAcknowledged: false,
        dependentAcknowledged: false,
        error: null,
        attempts: 0,
        createdAt: "2026-08-02T08:00:00Z",
        updatedAt: "2026-08-02T08:00:00Z",
        hasLocalOriginal: true,
      },
    }));
    const { rerender } = render(<FitnessFoodCataloguePanel {...props} openCreateRequest={1} />);
    expect(await screen.findByRole("heading", { name: "Add food" })).toBeInTheDocument();
    fireEvent.change(screen.getByLabelText("Food name"), { target: { value: "Label oats" } });
    fireEvent.change(screen.getByLabelText("Calories (kcal)"), { target: { value: "123" } });
    fireEvent.change(screen.getByLabelText("Printed kJ (optional)"), { target: { value: "900" } });
    fireEvent.change(screen.getByLabelText(/Nutrition-label photo/), {
      target: { files: [new File([new Uint8Array([1, 2, 3, 4])], "label.jpg", { type: "image/jpeg" })] },
    });
    fireEvent.click(screen.getByRole("button", { name: "Save food" }));
    await waitFor(() => expect(queueLabelMock).toHaveBeenCalledWith(expect.any(File), expect.objectContaining({
      entityType: "food",
      payload: expect.objectContaining({
        name: "Label oats",
        version: expect.objectContaining({
          calories_kcal: 123,
          source_energy_value: 900,
          source_energy_unit: "kj",
        }),
      }),
    })));

    rerender(<FitnessFoodCataloguePanel {...props} openCreateRequest={1} />);
    fireEvent.click(await screen.findByRole("button", { name: /Porridge/ }));
    fireEvent.change(screen.getByLabelText("Merge Porridge into"), { target: { value: otherFood.id } });
    fireEvent.click(screen.getByRole("button", { name: "Preview merge" }));
    expect(await screen.findByText("2 saved nutrition versions move")).toBeInTheDocument();
    expect(screen.getByText("3 diary entries remain linked")).toBeInTheDocument();
    fireEvent.click(screen.getByRole("button", { name: "Confirm merge" }));
    await waitFor(() => expect(apiMock).toHaveBeenCalledWith("/fitness/foods/merge", {
      method: "POST",
      body: JSON.stringify({ source_id: food.id, target_id: otherFood.id }),
    }, true, false));
  });

  it("keeps household food and recipe definitions loggable but owner-read-only", async () => {
    const sharedFood = {
      ...otherFood,
      id: "00000000-0000-4000-8000-000000000211",
      name: "Family yoghurt",
      household_shared: true,
      editable: false,
      current_version: { ...otherFood.current_version, id: "00000000-0000-4000-8000-000000000212" },
      versions: [{ ...otherFood.current_version, id: "00000000-0000-4000-8000-000000000212" }],
    };
    const sharedRecipe = {
      id: "00000000-0000-4000-8000-000000000221",
      name: "Family curry",
      household_shared: true,
      editable: false,
      active: true,
      current_version: {
        id: "00000000-0000-4000-8000-000000000222",
        components: [],
        calories_kcal: 720,
        lower_calories_kcal: 650,
        upper_calories_kcal: 800,
        confidence: "estimated",
      },
      versions: [],
    };
    sharedRecipe.versions = [sharedRecipe.current_version] as never;
    apiMock.mockImplementation(async (path) => {
      if (path === "/fitness/foods") return [{ ...food, editable: true }, sharedFood] as never;
      if (path === "/fitness/recipes") return [sharedRecipe] as never;
      throw new Error(`Unexpected request: ${String(path)}`);
    });

    const foodView = render(<FitnessFoodCataloguePanel {...props} openCreateRequest={0} />);
    fireEvent.click(await screen.findByRole("button", { name: /Family yoghurt/ }));
    expect(screen.getByText(/readable and loggable, owned by another family member/)).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "Copy to my foods" })).toBeInTheDocument();
    expect(screen.queryByRole("button", { name: "Edit details" })).not.toBeInTheDocument();
    expect(screen.queryByRole("button", { name: "Favourite" })).not.toBeInTheDocument();
    expect(screen.queryByRole("button", { name: "New version" })).not.toBeInTheDocument();
    expect(screen.queryByRole("button", { name: "Add serving" })).not.toBeInTheDocument();
    expect(screen.queryByLabelText("Merge Family yoghurt into")).not.toBeInTheDocument();
    fireEvent.click(screen.getByRole("button", { name: "Copy to my foods" }));
    expect(screen.getByLabelText("Share this definition with the household")).not.toBeChecked();
    fireEvent.click(screen.getByRole("button", { name: "Cancel" }));
    fireEvent.click(screen.getByRole("button", { name: /Porridge/ }));
    expect(screen.queryByRole("option", { name: /Family yoghurt/ })).not.toBeInTheDocument();
    foodView.unmount();

    render(<FitnessRecipesPanel {...props} />);
    fireEvent.click(await screen.findByRole("button", { name: /Family curry/ }));
    expect(screen.getByRole("button", { name: "Copy to my recipes" })).toBeInTheDocument();
    expect(screen.queryByRole("button", { name: "New version" })).not.toBeInTheDocument();
    expect(screen.queryByRole("button", { name: "Favourite" })).not.toBeInTheDocument();
    expect(screen.queryByRole("button", { name: "Archive" })).not.toBeInTheDocument();
    fireEvent.click(screen.getByRole("button", { name: "Copy to my recipes" }));
    expect(screen.getByLabelText("Share definition with household")).not.toBeChecked();
  });

  it("logs templates as separate entries using the configured early-morning boundary", async () => {
    render(<FitnessMealTemplatesPanel {...props} />);
    fireEvent.click(await screen.findByRole("button", { name: "Log template" }));
    fireEvent.change(screen.getByLabelText("When"), { target: { value: "2026-08-02T07:30" } });
    fireEvent.change(screen.getByRole("spinbutton", { name: /^Amount for Porridge/ }), { target: { value: "1.5" } });
    fireEvent.click(screen.getByRole("button", { name: "Log 1 entries" }));

    await waitFor(() => expect(saveManyMock).toHaveBeenCalledWith([
      expect.objectContaining({
        entityType: "food_log_entry",
        payload: expect.objectContaining({
          entered_amount: 1.5,
          canonical_amount: 360,
          nutrition_date: "2026-08-01",
        }),
      }),
    ]));
  });

  it("saves prepared ranges, canonical training/rest targets, and an explicit rebucket", async () => {
    const { unmount } = render(<FitnessRecipesPanel {...props} />);
    fireEvent.click(await screen.findByRole("button", { name: /New recipe or prepared meal/ }));
    fireEvent.click(screen.getByRole("button", { name: "Prepared / restaurant estimate" }));
    fireEvent.change(screen.getByLabelText("Recipe name"), { target: { value: "Restaurant curry" } });
    fireEvent.change(screen.getByLabelText("Best estimate Calories"), { target: { value: "850" } });
    fireEvent.change(screen.getByLabelText("Lower estimate"), { target: { value: "700" } });
    fireEvent.change(screen.getByLabelText("Upper estimate"), { target: { value: "1050" } });
    fireEvent.click(screen.getByRole("button", { name: "Save recipe" }));
    await waitFor(() => expect(saveMock).toHaveBeenCalledWith("recipe", expect.objectContaining({
      name: "Restaurant curry",
      version: expect.objectContaining({
        calories_kcal: 850,
        lower_calories_kcal: 700,
        upper_calories_kcal: 1050,
        confidence: "estimated",
      }),
    }), expect.objectContaining({ entityId: expect.any(String) })));
    unmount();

    render(<FitnessNutritionTargetsPanel {...props} />);
    await screen.findByText("No active nutrition targets");
    fireEvent.click(screen.getByRole("button", { name: "Add target" }));
    fireEvent.change(screen.getByLabelText("Target form"), { target: { value: "training_rest" } });
    fireEvent.change(screen.getByLabelText("Training-day target"), { target: { value: "2400" } });
    fireEvent.change(screen.getByLabelText("Rest-day target"), { target: { value: "2100" } });
    fireEvent.click(screen.getByRole("button", { name: "Save target" }));
    await waitFor(() => expect(saveMock).toHaveBeenCalledWith("nutrition_target", expect.objectContaining({
      target_type: "training_rest",
      target_value: null,
      training_day_value: 2400,
      rest_day_value: 2100,
    }), undefined));

    fireEvent.change(screen.getByLabelText(/^Day starts at/), { target: { value: "07:00" } });
    fireEvent.click(screen.getByRole("button", { name: "Save boundary and rebucket diary" }));
    expect(await screen.findByText("2 diary entries checked and regrouped.")).toBeInTheDocument();
    expect(apiMock).toHaveBeenCalledWith("/fitness/nutrition/settings/rebucket", {
      method: "POST",
      body: expect.stringContaining('"nutrition_day_start_minutes":420'),
    }, true, false);
  });
});
