import { fireEvent, render, screen, waitFor, within } from "@testing-library/react";
import { beforeEach, describe, expect, it, vi } from "vitest";

import { api } from "../api";
import {
  deleteFitnessRecord,
  fitnessLogUndo,
  rememberFitnessLogUndo,
  removeFitnessPlannedMealLogFromDevice,
  saveFitnessPlannedMealLog,
  saveFitnessRecord,
  saveFitnessRecords,
} from "../fitness/offlineStore";
import { FitnessHouseholdMealsPanel, FitnessLogView } from "../views/fitness/FitnessLogView";
import { localDateValue } from "../views/fitness/shared";

vi.mock("../api", () => ({
  api: vi.fn(),
  ApiError: class ApiError extends Error {
    status: number;
    constructor(message: string, status: number) { super(message); this.status = status; }
  },
}));

vi.mock("../fitness/offlineStore", () => ({
  cacheFitnessPlannedMeals: vi.fn().mockResolvedValue(undefined),
  cacheFitnessRecords: vi.fn().mockResolvedValue(undefined),
  cacheFitnessFoodLogDay: vi.fn().mockResolvedValue(undefined),
  cachedFitnessFoodLogDay: vi.fn().mockResolvedValue(null),
  cachedFitnessPlannedMeals: vi.fn().mockResolvedValue([]),
  cachedFitnessRecords: vi.fn().mockResolvedValue([]),
  deleteFitnessRecord: vi.fn().mockResolvedValue(undefined),
  fitnessLogUndo: vi.fn().mockResolvedValue(null),
  rememberFitnessLogUndo: vi.fn().mockResolvedValue(undefined),
  removeFitnessPlannedMealLogFromDevice: vi.fn().mockResolvedValue(false),
  saveFitnessPlannedMealLog: vi.fn(),
  saveFitnessRecord: vi.fn(),
  saveFitnessRecords: vi.fn(),
}));

const food = {
  id: "food-1",
  name: "Greek yoghurt",
  active: true,
  favourite: true,
  quick_use: { usual_amount: 170, usual_unit: "g", recent_meal_keys: ["breakfast"], frequency_count: 5 },
  current_version: { id: "food-version-1", reference_amount: 100, reference_unit: "g", calories_kcal: 97, protein_g: 9 },
};
const banana = {
  id: "food-2",
  name: "Banana",
  active: true,
  current_version: { id: "food-version-2", reference_amount: 1, reference_unit: "item", calories_kcal: 105, protein_g: 1 },
};
const recipe = {
  id: "recipe-1",
  name: "Porridge",
  active: true,
  favourite: true,
  household_shared: true,
  current_version: { id: "recipe-version-1", servings: 2, components: [] },
};
const privateRecipe = {
  id: "recipe-private",
  name: "Private snack",
  active: true,
  household_shared: false,
  current_version: { id: "recipe-version-private", servings: 1, components: [] },
};
const plannedMeal = {
  meal_plan_id: "meal-plan-1",
  date: "2026-08-03",
  meal_type: "dinner",
  meal_id: "meal-1",
  meal_name: "Family pasta night",
  link_id: "link-1",
  recipe_id: recipe.id,
  recipe_version_id: recipe.current_version.id,
  recipe_name: "Tomato pasta",
  suggested_portion: 1,
  suggested_unit: "serving",
} as const;

const apiMock = vi.mocked(api);
const saveMock = vi.mocked(saveFitnessRecord);
const saveManyMock = vi.mocked(saveFitnessRecords);
const deleteMock = vi.mocked(deleteFitnessRecord);
const undoReadMock = vi.mocked(fitnessLogUndo);
const undoWriteMock = vi.mocked(rememberFitnessLogUndo);
const removePlannedMock = vi.mocked(removeFitnessPlannedMealLogFromDevice);
const plannedSaveMock = vi.mocked(saveFitnessPlannedMealLog);

const props = {
  online: true,
  revision: 0,
  onDataChanged: vi.fn(),
  onSectionChange: vi.fn(),
};

function renderFoodLog() {
  return render(<FitnessLogView {...props} mode="food" onModeChange={vi.fn()} onCreateFood={vi.fn()} />);
}

async function chooseSavedFood(name: string) {
  fireEvent.change(screen.getByRole("searchbox", { name: "Search foods" }), { target: { value: name } });
  const result = await screen.findByRole("group", { name });
  fireEvent.click(within(result).getAllByRole("button")[0]);
}

describe("Fitness Wave 3 Log", () => {
  beforeEach(() => {
    props.onDataChanged.mockReset();
    props.onSectionChange.mockReset();
    Object.defineProperty(window.navigator, "onLine", { configurable: true, value: true });
    Object.defineProperty(window, "SpeechRecognition", { configurable: true, value: undefined });
    apiMock.mockReset();
    apiMock.mockImplementation(async (path) => {
      if (path === "/fitness/foods") return [food, banana] as never;
      if (path === "/fitness/recipes") return [recipe, privateRecipe] as never;
      if (String(path).startsWith("/fitness/food-log?date=")) return { nutrition_date: "2026-08-03", entries: [], totals: {} } as never;
      if (String(path).startsWith("/fitness/planned-meals?date=")) return [plannedMeal] as never;
      throw new Error(`Unexpected request: ${String(path)}`);
    });
    saveMock.mockReset();
    saveMock.mockImplementation(async (_type, payload) => ({ ...payload, id: "food-log-1", revision: 3, queued_offline: true }));
    saveManyMock.mockReset();
    saveManyMock.mockImplementation(async (inputs) => inputs.map((input, index) => ({ ...input.payload, id: `food-log-batch-${index + 1}`, revision: 1, queued_offline: true })));
    deleteMock.mockReset(); deleteMock.mockResolvedValue(undefined);
    undoReadMock.mockReset(); undoReadMock.mockResolvedValue(null);
    undoWriteMock.mockReset(); undoWriteMock.mockResolvedValue(undefined);
    removePlannedMock.mockReset(); removePlannedMock.mockResolvedValue(false);
    plannedSaveMock.mockReset();
    plannedSaveMock.mockResolvedValue({
      id: "planned-log-1",
      source_meal_plan_id: plannedMeal.meal_plan_id,
      household_meal_link_id: plannedMeal.link_id,
      recipe_version_id: plannedMeal.recipe_version_id,
      logged_at_utc: "2026-08-03T17:00:00Z",
      local_timezone: "Europe/Berlin",
      nutrition_date: "2026-08-03",
      meal_key: "dinner",
      entered_amount: 1,
      entered_unit: "serving",
      canonical_amount: 1,
      canonical_unit: "serving",
      measurement_quality: "standard_serving",
    });
  });

  it("keeps food search and today’s diary in view, focuses Undo, and restores Undo after reopening", async () => {
    const view = renderFoodLog();
    expect(await screen.findByRole("heading", { name: "Add food" })).toBeInTheDocument();
    expect(screen.getByRole("heading", { name: "Today’s diary" })).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "Add food to Breakfast" })).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "Add food to Lunch" })).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "Add food to Dinner" })).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "Add food to Snacks" })).toBeInTheDocument();
    fireEvent.change(screen.getByRole("combobox", { name: "Meal" }), { target: { value: "breakfast" } });
    await chooseSavedFood("Greek yoghurt");
    expect(screen.getByRole("textbox", { name: "Amount" })).toHaveValue("170");
    fireEvent.click(screen.getByRole("button", { name: "Add to breakfast" }));

    const undoButton = await screen.findByRole("button", { name: "Undo" });
    await waitFor(() => expect(undoButton).toHaveFocus());
    expect(saveMock).toHaveBeenCalledWith("food_log_entry", expect.objectContaining({
      food_version_id: "food-version-1",
      entered_amount: 170,
      entered_unit: "g",
    }), { entityId: expect.any(String), baseRevision: null });
    expect(undoWriteMock).toHaveBeenCalledWith(expect.objectContaining({
      label: "Greek yoghurt",
      highlight: "15.3 g protein",
      records: [{ id: "food-log-1", revision: 3 }],
    }));
    expect(screen.getByText("15.3 g protein")).toBeInTheDocument();

    view.unmount();
    undoReadMock.mockResolvedValue({ nutritionDate: localDateValue(), label: "Greek yoghurt", records: [{ id: "food-log-1", revision: 3 }], createdAt: "2026-08-03T10:00:00Z" });
    renderFoodLog();
    const restoredUndo = await screen.findByRole("button", { name: "Undo" });
    expect(screen.getByText("Greek yoghurt logged.")).toBeInTheDocument();
    fireEvent.click(restoredUndo);
    await waitFor(() => expect(deleteMock).toHaveBeenCalledWith("food_log_entry", "food-log-1", 3));
    expect(undoWriteMock).toHaveBeenLastCalledWith(null);
  });

  it("keeps full database search available beside saved matches and jumps meal Add actions to search", async () => {
    renderFoodLog();
    await screen.findByRole("heading", { name: "Add food" });
    fireEvent.click(screen.getByRole("button", { name: "Add food to Lunch" }));
    await waitFor(() => expect(screen.getByRole("searchbox", { name: "Search foods" })).toHaveFocus());
    expect(screen.getByRole("combobox", { name: "Meal" })).toHaveValue("lunch");

    fireEvent.change(screen.getByRole("searchbox", { name: "Search foods" }), { target: { value: "Greek" } });
    expect(screen.getByRole("group", { name: "Greek yoghurt" })).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "Search full food database" })).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "Add it manually" })).toBeInTheDocument();
  });

  it("lets a saved food portion be changed before logging it", async () => {
    renderFoodLog();
    await screen.findByRole("heading", { name: "Add food" });
    await chooseSavedFood("Greek yoghurt");
    const portion = screen.getByLabelText("Amount");
    expect(portion).toHaveValue("170");
    fireEvent.change(portion, { target: { value: "225" } });
    fireEvent.click(screen.getByRole("button", { name: /^Add to / }));

    await waitFor(() => expect(saveMock).toHaveBeenCalledWith(
      "food_log_entry",
      expect.objectContaining({
        food_version_id: "food-version-1",
        entered_amount: 225,
        entered_unit: "g",
      }),
      { entityId: expect.any(String), baseRevision: null },
    ));
  });

  it("quick-adds a saved food once and keeps the logging intent stable", async () => {
    renderFoodLog();
    await screen.findByRole("heading", { name: "Add food" });
    fireEvent.change(screen.getByRole("searchbox", { name: "Search foods" }), { target: { value: "Greek yoghurt" } });
    const result = await screen.findByRole("group", { name: "Greek yoghurt" });
    const quickAdd = within(result).getByRole("button", { name: "Quick add" });
    fireEvent.click(quickAdd);
    fireEvent.click(quickAdd);

    await waitFor(() => expect(saveMock).toHaveBeenCalledTimes(1));
    expect(saveMock).toHaveBeenCalledWith(
      "food_log_entry",
      expect.objectContaining({ food_version_id: "food-version-1", entered_amount: 170 }),
      { entityId: expect.any(String), baseRevision: null },
    );
    expect(await screen.findByText("15.3 g protein")).toBeInTheDocument();
  });

  it("edits an existing diary quantity without creating a duplicate", async () => {
    apiMock.mockImplementation(async (path) => {
      if (path === "/fitness/foods") return [food, banana] as never;
      if (path === "/fitness/recipes") return [recipe, privateRecipe] as never;
      if (String(path).startsWith("/fitness/food-log?date=")) return {
        nutrition_date: localDateValue(),
        totals: { calories_kcal: 165 },
        entries: [{
          id: "entry-yoghurt",
          revision: 4,
          food_version_id: "food-version-1",
          recipe_version_id: null,
          food_name: "Greek yoghurt",
          logged_at_utc: "2026-08-12T07:30:00Z",
          local_timezone: "Europe/London",
          meal_key: "breakfast",
          entered_amount: 170,
          entered_unit: "g",
          canonical_amount: 170,
          canonical_unit: "g",
          measurement_quality: "weighed",
        }],
      } as never;
      if (String(path).startsWith("/fitness/planned-meals?date=")) return [] as never;
      throw new Error(`Unexpected request: ${String(path)}`);
    });
    renderFoodLog();
    fireEvent.click(await screen.findByRole("button", { name: "Edit portion for Greek yoghurt" }));
    expect(screen.getByRole("heading", { name: "Edit food" })).toBeInTheDocument();
    fireEvent.change(screen.getByLabelText("Amount"), { target: { value: "200" } });
    fireEvent.click(screen.getByRole("button", { name: "Save changes" }));

    await waitFor(() => expect(saveMock).toHaveBeenCalledWith(
      "food_log_entry",
      expect.objectContaining({
        food_version_id: "food-version-1",
        entered_amount: 200,
        logged_at_utc: "2026-08-12T07:30:00Z",
      }),
      { entityId: "entry-yoghurt", baseRevision: 4 },
    ));
  });

  it("keeps the meal-grouped diary ahead of planned dinner suggestions, independent of Coach context", async () => {
    renderFoodLog();
    const quickHeading = await screen.findByRole("heading", { name: "Add food" });
    const plannedHeading = screen.getByRole("heading", { name: "From the family meal plan" });
    const diaryHeading = screen.getByRole("heading", { name: "Today’s diary" });
    expect(quickHeading.compareDocumentPosition(diaryHeading) & Node.DOCUMENT_POSITION_FOLLOWING).toBeTruthy();
    expect(diaryHeading.compareDocumentPosition(plannedHeading) & Node.DOCUMENT_POSITION_FOLLOWING).toBeTruthy();
    expect(screen.getByText("Log the suggested portion, or adjust it first.")).toBeInTheDocument();
    expect(screen.queryByText(/privacy|only your own/i)).not.toBeInTheDocument();

    fireEvent.click(screen.getByRole("button", { name: "Edit portion" }));
    fireEvent.change(screen.getByLabelText("Portion"), { target: { value: "1.5" } });
    fireEvent.click(screen.getByRole("button", { name: "Log portion" }));
    await waitFor(() => expect(plannedSaveMock).toHaveBeenCalledWith(expect.objectContaining({
      meal: plannedMeal,
      portion: 1.5,
      unit: "serving",
    })));
    expect(apiMock.mock.calls.map(([path]) => String(path))).not.toEqual(expect.arrayContaining([
      "/fitness/onboarding",
      "/fitness/coach/preferences",
    ]));
    expect(screen.queryByText(/Alex|Morgan|child/i)).not.toBeInTheDocument();
  });

  it("turns speech into editable text and requires Review before a correctable batch save", async () => {
    class FakeRecognition {
      continuous = false;
      interimResults = false;
      lang = "";
      onresult: ((event: { results: ArrayLike<{ 0: { transcript: string } }> }) => void) | null = null;
      onerror: (() => void) | null = null;
      onend: (() => void) | null = null;
      start() {
        this.onresult?.({ results: [{ 0: { transcript: "two bowls of porridge and one banana" } }] });
        this.onend?.();
      }
      stop() {}
    }
    Object.defineProperty(window, "SpeechRecognition", { configurable: true, value: FakeRecognition });
    renderFoodLog();
    await screen.findByRole("heading", { name: "Add food" });
    fireEvent.click(screen.getByRole("button", { name: "Type or speak" }));
    fireEvent.click(screen.getByRole("button", { name: "Speak" }));
    const transcript = screen.getByLabelText("What did you eat?");
    expect(transcript).toHaveValue("two bowls of porridge and one banana");
    fireEvent.change(transcript, { target: { value: "one bowl of porridge and two banana" } });
    expect(saveManyMock).not.toHaveBeenCalled();
    fireEvent.click(screen.getByRole("button", { name: "Review items" }));

    const portions = screen.getAllByLabelText("Portion");
    expect(portions).toHaveLength(2);
    fireEvent.change(portions[0], { target: { value: "1.5" } });
    expect(saveManyMock).not.toHaveBeenCalled();
    fireEvent.click(screen.getByRole("button", { name: "Save 2 items" }));
    await waitFor(() => expect(saveManyMock).toHaveBeenCalledTimes(1));
    expect(saveManyMock.mock.calls[0][0]).toEqual(expect.arrayContaining([
      expect.objectContaining({ entityType: "food_log_entry", payload: expect.objectContaining({ recipe_version_id: "recipe-version-1", entered_amount: 1.5 }) }),
      expect.objectContaining({ entityType: "food_log_entry", payload: expect.objectContaining({ food_version_id: "food-version-2", entered_amount: 2 }) }),
    ]));
  });

  it("uses a meal photo only as a reviewed local draft and discards it after save", async () => {
    const createObjectUrl = vi.fn(() => "blob:meal-photo");
    const revokeObjectUrl = vi.fn();
    Object.defineProperty(URL, "createObjectURL", { configurable: true, value: createObjectUrl });
    Object.defineProperty(URL, "revokeObjectURL", { configurable: true, value: revokeObjectUrl });
    renderFoodLog();
    await screen.findByRole("heading", { name: "Add food" });
    fireEvent.click(screen.getByRole("button", { name: "Meal photo" }));
    const file = new File(["local pixels"], "dinner.jpg", { type: "image/jpeg" });
    fireEvent.change(screen.getByLabelText("Meal photo"), { target: { files: [file] } });
    expect(createObjectUrl).toHaveBeenCalledWith(file);
    fireEvent.change(screen.getByLabelText("Food or recipe"), { target: { value: "recipe:recipe-1" } });
    fireEvent.change(screen.getByLabelText("Portion"), { target: { value: "1.25" } });
    expect(saveManyMock).not.toHaveBeenCalled();

    fireEvent.click(screen.getByRole("button", { name: "Review meal" }));
    expect(screen.getByText("1.25 serving")).toBeInTheDocument();
    expect(saveManyMock).not.toHaveBeenCalled();
    fireEvent.click(screen.getByRole("button", { name: "Save meal" }));
    await waitFor(() => expect(saveManyMock).toHaveBeenCalledTimes(1));
    expect(revokeObjectUrl).toHaveBeenCalledWith("blob:meal-photo");
    expect(screen.queryByRole("img", { name: "Meal photo preview" })).not.toBeInTheDocument();
    expect(apiMock.mock.calls.some(([, options]) => String(options?.body ?? "").includes("local pixels") || String(options?.body ?? "").includes("dinner.jpg"))).toBe(false);
    expect(document.body.textContent).not.toMatch(/recognised|detected|analysed/i);
  });
});

describe("Fitness family meal links", () => {
  beforeEach(() => {
    Object.defineProperty(window.navigator, "onLine", { configurable: true, value: true });
    props.onDataChanged.mockReset();
    apiMock.mockReset();
  });

  it("links only a shared immutable recipe version and keeps private portions out of the family link", async () => {
    let links = [{ id: "link-1", meal_id: "meal-1", meal_name: "Family pasta night", recipe_id: recipe.id, recipe_version_id: recipe.current_version.id, recipe_name: recipe.name, linked_at: "2026-08-03T09:00:00Z" }];
    apiMock.mockImplementation(async (path, options = {}) => {
      if (path === "/meals/") return [{ id: "meal-1", name: "Family pasta night" }] as never;
      if (path === "/fitness/recipes") return [recipe, privateRecipe] as never;
      if (path === "/fitness/household-meals") return links as never;
      if (path === "/fitness/household-meals/meal-1" && options.method === "PUT") return links[0] as never;
      if (path === "/fitness/household-meals/meal-1" && options.method === "DELETE") { links = []; return { status: "deleted" } as never; }
      throw new Error(`Unexpected request: ${String(path)}`);
    });
    render(<FitnessHouseholdMealsPanel {...props} />);
    await screen.findByRole("heading", { name: "Connect family meals" });
    const sharedSelect = screen.getByLabelText("Shared recipe");
    expect(within(sharedSelect).getByRole("option", { name: "Porridge" })).toBeInTheDocument();
    expect(within(sharedSelect).queryByRole("option", { name: "Private snack" })).not.toBeInTheDocument();
    fireEvent.change(screen.getByLabelText("Family meal"), { target: { value: "meal-1" } });
    fireEvent.change(sharedSelect, { target: { value: "recipe-version-1" } });
    fireEvent.click(screen.getByRole("button", { name: "Change recipe" }));
    await waitFor(() => expect(apiMock).toHaveBeenCalledWith(
      "/fitness/household-meals/meal-1",
      { method: "PUT", body: expect.any(String) },
      true,
      false,
    ));
    const putCall = apiMock.mock.calls.find(([path, options]) => path === "/fitness/household-meals/meal-1" && options?.method === "PUT");
    expect(JSON.parse(String(putCall?.[1]?.body))).toEqual({ id: expect.any(String), recipe_version_id: "recipe-version-1" });
    expect(String(putCall?.[1]?.body)).not.toMatch(/portion|diary|owner/i);

    fireEvent.click(await screen.findByRole("button", { name: "Unlink" }));
    fireEvent.click(await screen.findByRole("button", { name: "Unlink" }));
    await waitFor(() => expect(apiMock).toHaveBeenCalledWith("/fitness/household-meals/meal-1", { method: "DELETE" }, true, false));
  });

  it("keeps a failed family-link change inline beside the form", async () => {
    apiMock.mockImplementation(async (path, options = {}) => {
      if (path === "/meals/") return [{ id: "meal-1", name: "Family pasta night" }] as never;
      if (path === "/fitness/recipes") return [recipe] as never;
      if (path === "/fitness/household-meals") return [] as never;
      if (path === "/fitness/household-meals/meal-1" && options.method === "PUT") throw new Error("Could not connect this meal");
      throw new Error(`Unexpected request: ${String(path)}`);
    });
    render(<FitnessHouseholdMealsPanel {...props} />);
    await screen.findByRole("heading", { name: "Connect family meals" });
    fireEvent.change(screen.getByLabelText("Family meal"), { target: { value: "meal-1" } });
    fireEvent.change(screen.getByLabelText("Shared recipe"), { target: { value: "recipe-version-1" } });
    fireEvent.click(screen.getByRole("button", { name: "Connect meal" }));
    expect(await screen.findByRole("alert")).toHaveTextContent("Could not connect this meal");
    expect(screen.getByLabelText("Family meal")).toHaveValue("meal-1");
    expect(screen.getByLabelText("Shared recipe")).toHaveValue("recipe-version-1");
  });
});
