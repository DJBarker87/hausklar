import {
  Apple,
  Camera,
  Check,
  ChevronLeft,
  ChevronRight,
  Clock3,
  HeartPulse,
  Mic,
  MoonStar,
  Pencil,
  Plus,
  Scale,
  Trash2,
  Undo2,
  Utensils,
  X,
} from "lucide-react";
import {
  type FormEvent,
  useCallback,
  useEffect,
  useMemo,
  useRef,
  useState,
} from "react";

import { api } from "../../api";
import { SkeletonList } from "../../components/ui";
import type {
  FitnessFood,
  FitnessFoodBarcodeLookup,
  FitnessFoodLogEntry,
  FitnessHouseholdMealLink,
  FitnessMealKey,
  FitnessNutritionDay,
  FitnessNutritionNutrients,
  FitnessPlannedHouseholdMeal,
  FitnessRecipe,
} from "../../fitness/contract";
import {
  canonicalPortion,
  currentFoodVersion,
  defaultFoodPortion,
  foodPortionOptions,
  nutritionAddedHighlight,
  type FitnessPortionOption,
} from "../../fitness/nutrition";
import {
  cacheFitnessFoodLogDay,
  cacheFitnessPlannedMeals,
  cachedFitnessFoodLogDay,
  cachedFitnessPlannedMeals,
  deleteFitnessRecord,
  fitnessLogUndo,
  rememberFitnessLogUndo,
  removeFitnessPlannedMealLogFromDevice,
  saveFitnessPlannedMealLog,
} from "../../fitness/offlineStore";
import type { FitnessLogUndoToken } from "../../fitness/offlineStore";
import type { FitnessViewProps } from "./FitnessModuleView";
import {
  FitnessCard,
  FitnessFormStatus,
  errorMessage,
  localDateTimeValue,
  localDateValue,
  localTimeZone,
  useFitnessBatchSave,
  useFitnessCollection,
  useFitnessSave,
  utcFromLocalInput,
} from "./shared";

export type FitnessLogMode = "food" | "measurement" | "sleep" | "issue";

type DraftSource = {
  key: string;
  kind: "food" | "recipe";
  label: string;
  sourceId: string;
  versionId: string;
  amount: number;
  unit: string;
  defaultUnitKey: string;
  units: FitnessPortionOption[];
  nutritionReferences: Array<{
    canonicalUnit: string;
    referenceAmount: number;
    nutrients: Pick<Partial<FitnessNutritionNutrients>, "calories_kcal" | "protein_g" | "fibre_g">;
  }>;
};

export type FitnessFoodDraftRow = {
  id: string;
  sourceKey: string;
  originalText: string;
  amount: string;
  unit: string;
  unitKey?: string;
};

type UndoState = Pick<FitnessLogUndoToken, "label" | "highlight" | "records">;

type BrowserSpeechRecognitionResult = { 0: { transcript: string } };
type BrowserSpeechRecognitionEvent = { results: ArrayLike<BrowserSpeechRecognitionResult> };
type BrowserSpeechRecognition = {
  continuous: boolean;
  interimResults: boolean;
  lang: string;
  onresult: ((event: BrowserSpeechRecognitionEvent) => void) | null;
  onerror: (() => void) | null;
  onend: (() => void) | null;
  start(): void;
  stop(): void;
};
type SpeechWindow = Window & {
  SpeechRecognition?: new () => BrowserSpeechRecognition;
  webkitSpeechRecognition?: new () => BrowserSpeechRecognition;
};

type HouseholdMeal = { id: string; name: string };

const logModes = [
  { id: "food", label: "Food", icon: Apple },
  { id: "measurement", label: "Measurement", icon: Scale },
  { id: "sleep", label: "Sleep", icon: MoonStar },
  { id: "issue", label: "Body issue", icon: HeartPulse },
] satisfies Array<{ id: FitnessLogMode; label: string; icon: typeof Apple }>;

const mealOptions: Array<{ key: FitnessMealKey; label: string }> = [
  { key: "breakfast", label: "Breakfast" },
  { key: "lunch", label: "Lunch" },
  { key: "dinner", label: "Dinner" },
  { key: "snack", label: "Snacks" },
];

function defaultMealKey(date = new Date()): FitnessMealKey {
  if (date.getHours() < 11) return "breakfast";
  if (date.getHours() < 15) return "lunch";
  if (date.getHours() < 21) return "dinner";
  return "snack";
}

function titleCase(value: string): string {
  return value.replaceAll("_", " ").replace(/\b\w/g, (letter) => letter.toLocaleUpperCase());
}

function shiftLocalDate(value: string, days: number): string {
  const [year, month, day] = value.split("-").map(Number);
  return localDateValue(new Date(year, month - 1, day + days, 12));
}

function diaryDateLabel(value: string): string {
  if (value === localDateValue()) return "Today";
  const [year, month, day] = value.split("-").map(Number);
  return new Date(year, month - 1, day, 12).toLocaleDateString(undefined, {
    weekday: "short",
    day: "numeric",
    month: "short",
  });
}

function emptyNutritionDay(date: string): FitnessNutritionDay {
  return {
    nutrition_date: date,
    entries: [],
    totals: {
      calories_kcal: null,
      protein_g: null,
      carbohydrate_g: null,
      sugars_g: null,
      fat_g: null,
      saturated_fat_g: null,
      fibre_g: null,
      salt_g: null,
    },
  };
}

function useCompactNutritionDay(date: string, revision: number) {
  const [data, setData] = useState<FitnessNutritionDay>(() => emptyNutritionDay(date));
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
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
        const response = await api<FitnessNutritionDay>(`/fitness/food-log?date=${encodeURIComponent(date)}`, {}, true, false);
        const next = { ...emptyNutritionDay(date), ...response, entries: response.entries ?? [] };
        await cacheFitnessFoodLogDay(date, next.entries, requestStartedAt).catch(() => undefined);
        // The cache holds the server's own list plus this device's queued work,
        // so it decides the diary. An empty cached day means the day is empty,
        // never that removed entries should reappear from the response.
        const cached = await cachedFitnessFoodLogDay(date).catch(() => null);
        if (!cancelled) setData({ ...next, entries: cached ?? next.entries });
      } catch (requestError) {
        const entries = await cachedFitnessFoodLogDay(date).catch(() => null) ?? [];
        if (!cancelled) {
          setData({ ...emptyNutritionDay(date), entries });
          if (navigator.onLine && entries.length === 0) setError(errorMessage(requestError));
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

  const addEntries = useCallback((entries: FitnessFoodLogEntry[]) => {
    setData((current) => ({
      ...current,
      entries: [...entries, ...current.entries.filter((item) => !entries.some((entry) => entry.id === item.id))],
    }));
  }, []);
  const removeEntries = useCallback((ids: string[]) => {
    setData((current) => ({ ...current, entries: current.entries.filter((entry) => !ids.includes(entry.id)) }));
  }, []);

  return { data, loading, error, reload, addEntries, removeEntries };
}

function usePlannedMeals(date: string, revision: number) {
  const [data, setData] = useState<FitnessPlannedHouseholdMeal[]>([]);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    let cancelled = false;
    setLoading(true);
    void (async () => {
      const cached = await cachedFitnessPlannedMeals(date).catch(() => []);
      if (!cancelled && cached.length) setData(cached);
      if (!navigator.onLine) {
        if (!cancelled) setLoading(false);
        return;
      }
      try {
        const meals = await api<FitnessPlannedHouseholdMeal[]>(`/fitness/planned-meals?date=${encodeURIComponent(date)}`, {}, true, false);
        await cacheFitnessPlannedMeals(date, meals).catch(() => undefined);
        if (!cancelled) setData(meals);
      } catch {
        // A missing household suggestion never blocks the private food diary.
      } finally {
        if (!cancelled) setLoading(false);
      }
    })();
    return () => { cancelled = true; };
  }, [date, revision]);

  return { data, loading };
}

function availableSources(foods: FitnessFood[], recipes: FitnessRecipe[]): DraftSource[] {
  const foodSources = foods.flatMap((food): DraftSource[] => {
    const version = currentFoodVersion(food);
    if (!version?.id || food.active === false) return [];
    const portion = defaultFoodPortion(food);
    const units = foodPortionOptions(food);
    if (!portion || !units.length) return [];
    return [{
      key: `food:${food.id}`,
      kind: "food",
      label: food.name,
      sourceId: food.id,
      versionId: version.id,
      amount: portion.amount,
      unit: portion.option.enteredUnit,
      defaultUnitKey: portion.option.key,
      units,
      nutritionReferences: [{
        canonicalUnit: version.reference_unit,
        referenceAmount: version.reference_amount,
        nutrients: version,
      }],
    }];
  });
  const recipeSources = recipes.flatMap((recipe): DraftSource[] => {
    const version = recipe.current_version ?? recipe.latest_version;
    if (!version?.id || recipe.active === false) return [];
    const units: FitnessPortionOption[] = [];
    if (version.finished_weight_g && version.finished_weight_g > 0) {
      units.push({ key: "recipe:g", label: "g", enteredUnit: "g", defaultAmount: 100, canonicalAmount: 100, canonicalUnit: "g", measurementQuality: "estimated" });
    }
    if (version.servings && version.servings > 0) {
      units.push({ key: "recipe:serving", label: "serving", enteredUnit: "serving", defaultAmount: 1, canonicalAmount: 1, canonicalUnit: "serving", measurementQuality: "standard_serving" });
    }
    const portion = units[0];
    if (!portion) return [];
    return [{
      key: `recipe:${recipe.id}`,
      kind: "recipe",
      label: recipe.name,
      sourceId: recipe.id,
      versionId: version.id,
      amount: portion.defaultAmount,
      unit: portion.enteredUnit,
      defaultUnitKey: portion.key,
      units,
      nutritionReferences: [
        ...(version.finished_weight_g && version.finished_weight_g > 0 ? [{
          canonicalUnit: "g",
          referenceAmount: version.finished_weight_g,
          nutrients: version,
        }] : []),
        ...(version.servings && version.servings > 0 ? [{
          canonicalUnit: "serving",
          referenceAmount: version.servings,
          nutrients: version,
        }] : []),
      ],
    }];
  });
  return [...foodSources, ...recipeSources].sort((left, right) => left.label.localeCompare(right.label));
}

function normalized(value: string): string {
  return value.toLocaleLowerCase().replace(/[^a-z0-9.]+/g, " ").trim();
}

function spokenNumber(value: string): number | null {
  const words: Record<string, number> = { a: 1, an: 1, one: 1, two: 2, three: 3, four: 4, half: 0.5 };
  if (value in words) return words[value];
  const number = Number(value);
  return Number.isFinite(number) && number > 0 ? number : null;
}

export function nutritionDraftRowsFromText(
  text: string,
  foods: FitnessFood[],
  recipes: FitnessRecipe[],
): FitnessFoodDraftRow[] {
  const sources = availableSources(foods, recipes).sort((left, right) => right.label.length - left.label.length);
  return text
    .split(/(?:\s+and\s+|\s+plus\s+|[,;\n]+)/i)
    .map((part) => part.trim())
    .filter(Boolean)
    .map((part) => {
      const words = normalized(part);
      const source = sources.find((item) => words.includes(normalized(item.label))) ?? null;
      const quantity = words.match(/(?:^|\s)(\d+(?:\.\d+)?|a|an|one|two|three|four|half)\s*(g|gram|grams|kg|ml|millilitres?|serving|servings|bowl|bowls|item|items)?(?:\s|$)/i);
      const amount = quantity ? spokenNumber(quantity[1]) : null;
      const unit = quantity?.[2]?.toLocaleLowerCase().replace(/^grams?$/, "g").replace(/^millilitres?$/, "ml").replace(/^servings$/, "serving").replace(/^bowls$/, "bowl").replace(/^items$/, "item");
      const portion = (unit ? source?.units.find((candidate) => candidate.enteredUnit === unit) : null)
        ?? source?.units.find((candidate) => candidate.key === source.defaultUnitKey);
      return {
        id: crypto.randomUUID(),
        sourceKey: source?.key ?? "",
        originalText: part,
        amount: String(amount ?? source?.amount ?? 1),
        unit: portion?.enteredUnit ?? unit ?? source?.unit ?? "",
        unitKey: portion?.key ?? "",
      };
    });
}

function canonicalAmount(source: DraftSource, amount: number, unitKey: string | undefined): { amount: number; unit: string; quality: FitnessPortionOption["measurementQuality"] } {
  const option = source.units.find((candidate) => candidate.key === unitKey);
  if (!option) throw new Error("Choose a valid unit for this food.");
  return canonicalPortion(option, amount);
}

function sourceNutrients(
  source: DraftSource | undefined,
  canonicalAmountValue: number,
  canonicalUnit: string,
): Pick<Partial<FitnessNutritionNutrients>, "calories_kcal" | "protein_g" | "fibre_g"> | null {
  const reference = source?.nutritionReferences.find((item) => item.canonicalUnit === canonicalUnit);
  if (!reference || reference.referenceAmount <= 0) return null;
  const scale = canonicalAmountValue / reference.referenceAmount;
  const scaled = (value: number | null | undefined) => (
    typeof value === "number" && Number.isFinite(value) ? value * scale : null
  );
  return {
    calories_kcal: scaled(reference.nutrients.calories_kcal),
    protein_g: scaled(reference.nutrients.protein_g),
    fibre_g: scaled(reference.nutrients.fibre_g),
  };
}

function lookupPortionOptions(result: FitnessFoodBarcodeLookup): FitnessPortionOption[] {
  const base: FitnessPortionOption = {
    key: "lookup:base",
    label: result.reference_unit,
    enteredUnit: result.reference_unit,
    defaultAmount: result.reference_amount,
    canonicalAmount: result.reference_amount,
    canonicalUnit: result.reference_unit,
    measurementQuality: "estimated",
  };
  return result.serving ? [base, {
    key: "lookup:serving",
    label: result.serving.name,
    enteredUnit: result.serving.unit,
    defaultAmount: result.serving.amount,
    canonicalAmount: result.serving.amount,
    canonicalUnit: result.reference_unit,
    measurementQuality: "standard_serving",
  }] : [base];
}

async function createLookupFood(result: FitnessFoodBarcodeLookup): Promise<FitnessFood> {
  return api<FitnessFood>("/fitness/foods", {
    method: "POST",
    body: JSON.stringify({
      id: crypto.randomUUID(),
      name: result.name,
      brand: result.brand ?? null,
      barcode: result.barcode,
      household_shared: false,
      favourite: false,
      active: true,
      version: {
        id: crypto.randomUUID(),
        reference_amount: result.reference_amount,
        reference_unit: result.reference_unit,
        calories_kcal: result.nutrients.calories_kcal,
        protein_g: result.nutrients.protein_g,
        carbohydrate_g: result.nutrients.carbohydrate_g,
        sugars_g: result.nutrients.sugars_g,
        fat_g: result.nutrients.fat_g,
        saturated_fat_g: result.nutrients.saturated_fat_g,
        fibre_g: result.nutrients.fibre_g,
        salt_g: result.nutrients.salt_g,
        sodium_mg: result.nutrients.sodium_mg,
        micronutrients: {},
        source_type: result.source,
        source_note: result.source_url,
        confidence: "copied",
      },
    }),
  });
}

function entryLabel(entry: FitnessFoodLogEntry, foods: FitnessFood[], recipes: FitnessRecipe[]): string {
  if (entry.food_name) return entry.food_name;
  const food = foods.find((item) => currentFoodVersion(item)?.id === entry.food_version_id || item.versions?.some((version) => version.id === entry.food_version_id));
  if (food) return food.name;
  const recipe = recipes.find((item) => (item.current_version ?? item.latest_version)?.id === entry.recipe_version_id || item.versions?.some((version) => version.id === entry.recipe_version_id));
  return recipe?.name ?? "Saved food";
}

function localEntryFromSaved(saved: Record<string, unknown>, label?: string): FitnessFoodLogEntry {
  return { ...saved, food_name: label ?? null } as unknown as FitnessFoodLogEntry;
}

function FitnessDraftRows({
  rows,
  sources,
  onChange,
  single = false,
}: {
  rows: FitnessFoodDraftRow[];
  sources: DraftSource[];
  onChange: (rows: FitnessFoodDraftRow[]) => void;
  single?: boolean;
}) {
  function changeSource(row: FitnessFoodDraftRow, sourceKey: string) {
    const source = sources.find((item) => item.key === sourceKey);
    onChange(rows.map((item) => item.id === row.id ? {
      ...item,
      sourceKey,
      amount: source ? String(source.amount) : item.amount,
      unit: source?.unit ?? "",
      unitKey: source?.defaultUnitKey ?? "",
    } : item));
  }

  function changeUnit(row: FitnessFoodDraftRow, unitKey: string) {
    const source = sources.find((item) => item.key === row.sourceKey);
    const option = source?.units.find((candidate) => candidate.key === unitKey);
    onChange(rows.map((item) => item.id === row.id ? {
      ...item,
      unitKey,
      unit: option?.enteredUnit ?? "",
      amount: option ? String(option.defaultAmount) : item.amount,
    } : item));
  }

  return (
    <div className="fitness-log__draft-rows">
      {rows.map((row, index) => (
        <fieldset key={row.id}>
          <legend>{single ? "Food" : `Item ${index + 1}`}</legend>
          {row.originalText ? <small>From “{row.originalText}”</small> : null}
          <label>Food or recipe
            <select required value={row.sourceKey} onChange={(event) => changeSource(row, event.target.value)}>
              <option value="">Choose an item</option>
              {sources.map((source) => <option value={source.key} key={source.key}>{source.label}</option>)}
            </select>
          </label>
          <label>Portion
            <input type="text" inputMode="decimal" pattern="(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)" required value={row.amount} onChange={(event) => onChange(rows.map((item) => item.id === row.id ? { ...item, amount: event.target.value } : item))} />
          </label>
          <label>Unit
            <select required value={row.unitKey ?? ""} onChange={(event) => changeUnit(row, event.target.value)}>
              <option value="">Choose a unit</option>
              {(sources.find((source) => source.key === row.sourceKey)?.units ?? []).map((option) => (
                <option value={option.key} key={option.key}>{option.label}</option>
              ))}
            </select>
          </label>
          {!single ? <button type="button" className="button button--secondary button--compact" aria-label={`Remove item ${index + 1}`} onClick={() => onChange(rows.filter((item) => item.id !== row.id))}><X aria-hidden="true" size={15} /> Remove</button> : null}
        </fieldset>
      ))}
      {!single ? <button type="button" className="button button--secondary" onClick={() => onChange([...rows, { id: crypto.randomUUID(), sourceKey: "", originalText: "", amount: "", unit: "", unitKey: "" }])}><Plus aria-hidden="true" size={16} /> Add item</button> : null}
    </div>
  );
}

function FitnessFoodLog({
  revision,
  onDataChanged,
  onCreateFood,
}: FitnessViewProps & { onCreateFood: () => void }) {
  const [date, setDate] = useState(localDateValue);
  const day = useCompactNutritionDay(date, revision);
  const plannedMeals = usePlannedMeals(date, revision);
  const foods = useFitnessCollection<FitnessFood>("/fitness/foods", "food", revision);
  const recipes = useFitnessCollection<FitnessRecipe>("/fitness/recipes", "recipe", revision);
  const logSave = useFitnessSave(onDataChanged);
  const batchSave = useFitnessBatchSave(onDataChanged);
  const [meal, setMeal] = useState<FitnessMealKey>(() => defaultMealKey());
  const [detailRow, setDetailRow] = useState<FitnessFoodDraftRow>(() => ({
    id: crypto.randomUUID(), sourceKey: "", originalText: "", amount: "", unit: "", unitKey: "",
  }));
  const [foodQuery, setFoodQuery] = useState("");
  const [lookupResults, setLookupResults] = useState<FitnessFoodBarcodeLookup[]>([]);
  const [lookupBusy, setLookupBusy] = useState(false);
  const [externalSelection, setExternalSelection] = useState<FitnessFoodBarcodeLookup | null>(null);
  const [editingEntry, setEditingEntry] = useState<FitnessFoodLogEntry | null>(null);
  const [captureMode, setCaptureMode] = useState<"text" | "photo" | null>(null);
  const [captureStage, setCaptureStage] = useState<"compose" | "review">("compose");
  const [transcript, setTranscript] = useState("");
  const [draftRows, setDraftRows] = useState<FitnessFoodDraftRow[]>([]);
  const [photoUrl, setPhotoUrl] = useState<string | null>(null);
  const [photoName, setPhotoName] = useState("");
  const [listening, setListening] = useState(false);
  const [localError, setLocalError] = useState<string | null>(null);
  const [plannedErrors, setPlannedErrors] = useState<Record<string, string>>({});
  const [plannedEdit, setPlannedEdit] = useState<{ id: string; portion: string; unit: "serving" | "g" } | null>(null);
  const [undo, setUndo] = useState<UndoState | null>(null);
  const [quickLoggingSourceKeys, setQuickLoggingSourceKeys] = useState<Set<string>>(() => new Set());
  const undoRef = useRef<HTMLButtonElement>(null);
  const foodSearchRef = useRef<HTMLInputElement>(null);
  const photoInputRef = useRef<HTMLInputElement>(null);
  const recognitionRef = useRef<BrowserSpeechRecognition | null>(null);
  const sources = useMemo(() => availableSources(foods.data, recipes.data), [foods.data, recipes.data]);
  const selectedSource = sources.find((source) => source.key === detailRow.sourceKey) ?? null;
  const detailUnits = externalSelection ? lookupPortionOptions(externalSelection) : selectedSource?.units ?? [];
  const matchingSources = useMemo(() => {
    const query = normalized(foodQuery);
    if (!query || detailRow.sourceKey || externalSelection) return [];
    return sources.filter((source) => normalized(source.label).includes(query)).slice(0, 8);
  }, [detailRow.sourceKey, externalSelection, foodQuery, sources]);
  const speechConstructor = typeof window === "undefined" ? null : (window as SpeechWindow).SpeechRecognition ?? (window as SpeechWindow).webkitSpeechRecognition ?? null;

  useEffect(() => {
    if (undo) undoRef.current?.focus();
  }, [undo]);

  useEffect(() => {
    let cancelled = false;
    setUndo(null);
    void fitnessLogUndo().then((saved) => {
      if (!cancelled && saved?.nutritionDate === date) {
        setUndo({ label: saved.label, highlight: saved.highlight, records: saved.records });
      }
    }).catch(() => undefined);
    return () => { cancelled = true; };
  }, [date]);

  useEffect(() => () => {
    recognitionRef.current?.stop();
    if (photoUrl) URL.revokeObjectURL(photoUrl);
  }, [photoUrl]);

  function showUndo(label: string, records: UndoState["records"], highlight?: string | null) {
    const next = { label, records, highlight: highlight ?? undefined };
    setUndo(next);
    void rememberFitnessLogUndo({
      ...next,
      nutritionDate: date,
      createdAt: new Date().toISOString(),
    }).catch(() => undefined);
  }

  function payloadForRow(row: FitnessFoodDraftRow, loggedAt = new Date().toISOString()) {
    const source = sources.find((item) => item.key === row.sourceKey);
    const amount = Number(row.amount);
    if (!source || !Number.isFinite(amount) || amount <= 0 || !row.unit.trim()) throw new Error("Choose each item and enter a valid amount.");
    const canonical = canonicalAmount(source, amount, row.unitKey);
    return {
      food_version_id: source.kind === "food" ? source.versionId : null,
      recipe_version_id: source.kind === "recipe" ? source.versionId : null,
      logged_at_utc: loggedAt,
      local_timezone: localTimeZone(),
      nutrition_date: date,
      meal_key: meal,
      entered_amount: amount,
      entered_unit: row.unit.trim(),
      canonical_amount: canonical.amount,
      canonical_unit: canonical.unit,
      measurement_quality: canonical.quality,
      notes: null,
      context_tags: [],
    };
  }

  function clearDetailSelection() {
    setDetailRow({ id: crypto.randomUUID(), sourceKey: "", originalText: "", amount: "", unit: "", unitKey: "" });
    setFoodQuery("");
    setLookupResults([]);
    setExternalSelection(null);
  }

  function selectDetailSource(source: DraftSource) {
    setDetailRow({
      id: crypto.randomUUID(),
      sourceKey: source.key,
      originalText: "",
      amount: String(source.amount),
      unit: source.unit,
      unitKey: source.defaultUnitKey,
    });
    setFoodQuery(source.label);
    setLookupResults([]);
    setExternalSelection(null);
    setLocalError(null);
  }

  function selectLookupResult(result: FitnessFoodBarcodeLookup) {
    const option = lookupPortionOptions(result)[0];
    setExternalSelection(result);
    setFoodQuery(result.name);
    setLookupResults([]);
    setDetailRow({
      id: crypto.randomUUID(),
      sourceKey: "lookup",
      originalText: "",
      amount: String(option.defaultAmount),
      unit: option.enteredUnit,
      unitKey: option.key,
    });
    setLocalError(null);
  }

  function changeDetailUnit(key: string) {
    const option = detailUnits.find((candidate) => candidate.key === key);
    setDetailRow((current) => ({
      ...current,
      unitKey: key,
      unit: option?.enteredUnit ?? "",
      amount: option ? String(option.defaultAmount) : current.amount,
    }));
  }

  async function lookupFood() {
    const query = foodQuery.trim();
    if (query.length < 2 || lookupBusy) return;
    setLookupBusy(true);
    setLookupResults([]);
    setLocalError(null);
    try {
      const results = await api<FitnessFoodBarcodeLookup[]>(
        `/fitness/food-lookup/search?q=${encodeURIComponent(query)}`,
        {},
        true,
        false,
      );
      setLookupResults(results);
      if (!results.length) setLocalError(`No packaged foods matched “${query}”. You can add it manually.`);
    } catch (requestError) {
      const message = errorMessage(requestError);
      setLocalError(message || "Food lookup is unavailable.");
    } finally {
      setLookupBusy(false);
    }
  }

  async function saveDetail(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    setLocalError(null);
    try {
      let source = sources.find((item) => item.key === detailRow.sourceKey);
      let payload: Record<string, unknown>;
      if (externalSelection) {
        const amount = Number(detailRow.amount);
        const option = detailUnits.find((candidate) => candidate.key === detailRow.unitKey);
        if (!Number.isFinite(amount) || amount <= 0 || !option) throw new Error("Enter an amount and choose a unit.");
        const food = await createLookupFood(externalSelection);
        const version = currentFoodVersion(food);
        if (!version?.id) throw new Error("The looked-up food was saved without usable nutrition details.");
        const canonical = canonicalPortion(option, amount);
        source = {
          key: `food:${food.id}`,
          kind: "food",
          label: food.name,
          sourceId: food.id,
          versionId: version.id,
          amount,
          unit: option.enteredUnit,
          defaultUnitKey: option.key,
          units: detailUnits,
          nutritionReferences: [{
            canonicalUnit: version.reference_unit,
            referenceAmount: version.reference_amount,
            nutrients: version,
          }],
        };
        payload = {
          food_version_id: version.id,
          recipe_version_id: null,
          logged_at_utc: editingEntry?.logged_at_utc ?? new Date().toISOString(),
          local_timezone: localTimeZone(),
          nutrition_date: date,
          meal_key: meal,
          entered_amount: amount,
          entered_unit: option.enteredUnit,
          canonical_amount: canonical.amount,
          canonical_unit: canonical.unit,
          measurement_quality: canonical.quality,
          notes: null,
          context_tags: [],
        };
      } else {
        payload = payloadForRow(detailRow, editingEntry?.logged_at_utc);
      }
      const saved = await logSave.save(
        "food_log_entry",
        payload,
        editingEntry
          ? { entityId: editingEntry.id, baseRevision: editingEntry.revision ?? null }
          // The draft row's own id keeps a retried save one entry, not two.
          : { entityId: detailRow.id, baseRevision: null },
      );
      const calculatedNutrients = sourceNutrients(
        source,
        Number(payload.canonical_amount),
        String(payload.canonical_unit),
      );
      const localEntry = {
        ...localEntryFromSaved(saved, source?.label),
        ...(calculatedNutrients ?? {}),
      };
      day.addEntries([localEntry]);
      if (!editingEntry) {
        showUndo(
          source?.label ?? "Food",
          [{ id: saved.id, revision: saved.revision }],
          nutritionAddedHighlight(localEntry),
        );
      }
      clearDetailSelection();
      setEditingEntry(null);
    } catch (requestError) {
      setLocalError(errorMessage(requestError));
    }
  }

  async function quickAddSource(source: DraftSource) {
    if (quickLoggingSourceKeys.has(source.key) || logSave.saving) return;
    setQuickLoggingSourceKeys((current) => new Set(current).add(source.key));
    setLocalError(null);
    const row: FitnessFoodDraftRow = {
      id: crypto.randomUUID(),
      sourceKey: source.key,
      originalText: "",
      amount: String(source.amount),
      unit: source.unit,
      unitKey: source.defaultUnitKey,
    };
    try {
      const payload = payloadForRow(row);
      const saved = await logSave.save(
        "food_log_entry",
        payload,
        { entityId: row.id, baseRevision: null },
      );
      const calculatedNutrients = sourceNutrients(
        source,
        Number(payload.canonical_amount),
        String(payload.canonical_unit),
      );
      const localEntry = {
        ...localEntryFromSaved(saved, source.label),
        ...(calculatedNutrients ?? {}),
      };
      day.addEntries([localEntry]);
      showUndo(
        source.label,
        [{ id: saved.id, revision: saved.revision }],
        nutritionAddedHighlight(localEntry),
      );
      clearDetailSelection();
    } catch (requestError) {
      setLocalError(errorMessage(requestError));
    } finally {
      setQuickLoggingSourceKeys((current) => {
        const next = new Set(current);
        next.delete(source.key);
        return next;
      });
    }
  }

  function startAddingToMeal(nextMeal: FitnessMealKey) {
    setMeal(nextMeal);
    setEditingEntry(null);
    clearDetailSelection();
    window.requestAnimationFrame(() => {
      foodSearchRef.current?.scrollIntoView?.({ behavior: "smooth", block: "center" });
      foodSearchRef.current?.focus({ preventScroll: true });
    });
  }

  async function saveDraft() {
    setLocalError(null);
    try {
      if (!draftRows.length) throw new Error("Add at least one item.");
      const loggedAt = new Date().toISOString();
      const inputs = draftRows.map((row) => ({
        entityType: "food_log_entry" as const,
        payload: payloadForRow(row, loggedAt),
        // Each row keeps its own id, so retrying a partly failed meal cannot
        // log the items that already saved a second time.
        options: { entityId: row.id, baseRevision: null },
      }));
      const saved = await batchSave.save(inputs);
      const entries = saved.map((record, index) => {
        const source = sources.find((item) => item.key === draftRows[index].sourceKey);
        return {
          ...localEntryFromSaved(record, source?.label),
          ...(sourceNutrients(
            source,
            Number(inputs[index].payload.canonical_amount),
            String(inputs[index].payload.canonical_unit),
          ) ?? {}),
        };
      });
      day.addEntries(entries);
      showUndo(
        entries.length === 1 ? entryLabel(entries[0], foods.data, recipes.data) : `${entries.length} items`,
        saved.map((record) => ({ id: record.id, revision: record.revision as number | undefined })),
        entries.length === 1 ? nutritionAddedHighlight(entries[0]) : null,
      );
      clearCapture();
    } catch (requestError) {
      setLocalError(errorMessage(requestError));
    }
  }

  function startListening() {
    if (!speechConstructor || listening) return;
    const recognition = new speechConstructor();
    recognition.continuous = false;
    recognition.interimResults = false;
    recognition.lang = document.documentElement.lang || navigator.language || "en-GB";
    recognition.onresult = (event) => {
      const spoken = Array.from(event.results).map((result) => result[0]?.transcript ?? "").join(" ").trim();
      if (spoken) setTranscript((current) => [current.trim(), spoken].filter(Boolean).join(" "));
    };
    recognition.onerror = () => { setListening(false); setLocalError("Speech could not be captured. You can keep typing."); };
    recognition.onend = () => setListening(false);
    recognitionRef.current = recognition;
    setListening(true);
    recognition.start();
  }

  function reviewTranscript() {
    const rows = nutritionDraftRowsFromText(transcript, foods.data, recipes.data);
    if (!rows.length) {
      setLocalError("Type at least one food before review.");
      return;
    }
    setLocalError(null);
    setDraftRows(rows);
    setCaptureStage("review");
  }

  function choosePhoto(file: File | null) {
    if (photoUrl) URL.revokeObjectURL(photoUrl);
    if (!file) {
      setPhotoUrl(null);
      setPhotoName("");
      return;
    }
    setPhotoUrl(URL.createObjectURL(file));
    setPhotoName(file.name);
    setDraftRows([{ id: crypto.randomUUID(), sourceKey: "", originalText: "", amount: "", unit: "", unitKey: "" }]);
    setCaptureStage("compose");
  }

  function clearCapture() {
    recognitionRef.current?.stop();
    recognitionRef.current = null;
    if (photoUrl) URL.revokeObjectURL(photoUrl);
    if (photoInputRef.current) photoInputRef.current.value = "";
    setCaptureMode(null);
    setCaptureStage("compose");
    setTranscript("");
    setDraftRows([]);
    setPhotoUrl(null);
    setPhotoName("");
    setListening(false);
  }

  async function logPlanned(mealPlan: FitnessPlannedHouseholdMeal, portion = mealPlan.suggested_portion, unit = mealPlan.suggested_unit) {
    setPlannedErrors((current) => ({ ...current, [mealPlan.meal_plan_id]: "" }));
    try {
      const saved = await saveFitnessPlannedMealLog({
        meal: mealPlan,
        portion,
        unit,
        loggedAtUtc: new Date().toISOString(),
        localTimezone: localTimeZone(),
      });
      day.addEntries([saved]);
      showUndo(
        mealPlan.recipe_name,
        [{ id: saved.id, revision: saved.revision }],
        nutritionAddedHighlight(saved),
      );
      setPlannedEdit(null);
      onDataChanged();
    } catch (requestError) {
      setPlannedErrors((current) => ({ ...current, [mealPlan.meal_plan_id]: errorMessage(requestError) }));
    }
  }

  async function undoEntries(records: UndoState["records"]) {
    setLocalError(null);
    try {
      for (const record of records) {
        const removedPendingPlan = await removeFitnessPlannedMealLogFromDevice(record.id);
        if (!removedPendingPlan) await deleteFitnessRecord("food_log_entry", record.id, record.revision ?? null);
      }
      day.removeEntries(records.map((record) => record.id));
      setUndo(null);
      await rememberFitnessLogUndo(null).catch(() => undefined);
      onDataChanged();
    } catch (requestError) {
      setLocalError(errorMessage(requestError));
    }
  }

  function editEntry(entry: FitnessFoodLogEntry) {
    const source = sources.find((item) => (
      item.kind === "food"
        ? item.versionId === entry.food_version_id
        : item.versionId === entry.recipe_version_id
    ));
    if (!source) {
      setLocalError("That saved item is no longer available to edit.");
      return;
    }
    setLocalError(null);
    setMeal(entry.meal_key as FitnessMealKey);
    setEditingEntry(entry);
    const unit = source.units.find((option) => option.enteredUnit === entry.entered_unit);
    setDetailRow({
      id: entry.id,
      sourceKey: source.key,
      originalText: "",
      amount: String(entry.entered_amount),
      unit: entry.entered_unit,
      unitKey: unit?.key ?? "",
    });
    setFoodQuery(source.label);
    setLookupResults([]);
    setExternalSelection(null);
  }

  const entries = [...day.data.entries].sort((left, right) => right.logged_at_utc.localeCompare(left.logged_at_utc));
  const loading = day.loading || foods.loading || recipes.loading;
  const mealGroups = mealOptions.map((option) => ({
    ...option,
    entries: entries.filter((entry) => (
      option.key === "snack"
        ? !["breakfast", "lunch", "dinner"].includes(entry.meal_key)
        : entry.meal_key === option.key
    )),
  }));
  const knownCalories = entries
    .map((entry) => entry.calories_kcal)
    .filter((value): value is number => typeof value === "number" && Number.isFinite(value));
  const knownProtein = entries
    .map((entry) => entry.protein_g)
    .filter((value): value is number => typeof value === "number" && Number.isFinite(value));
  const calorieTotal = day.data.totals.calories_kcal
    ?? (knownCalories.length ? knownCalories.reduce((sum, value) => sum + value, 0) : null);
  const proteinTotal = day.data.totals.protein_g
    ?? (knownProtein.length ? knownProtein.reduce((sum, value) => sum + value, 0) : null);
  const shownDateLabel = diaryDateLabel(date);

  return (
    <div className="fitness-log__food">
      <div className="fitness-log__date-navigation" aria-label="Diary date">
        <button type="button" className="button button--secondary" aria-label="Previous day" onClick={() => setDate((current) => shiftLocalDate(current, -1))}><ChevronLeft aria-hidden="true" size={18} /></button>
        <div><strong>{shownDateLabel}</strong>{date !== localDateValue() ? <button type="button" onClick={() => setDate(localDateValue())}>Back to today</button> : null}</div>
        <button type="button" className="button button--secondary" aria-label="Next day" onClick={() => setDate((current) => shiftLocalDate(current, 1))}><ChevronRight aria-hidden="true" size={18} /></button>
      </div>
      <div className="fitness-log__day-summary" aria-label={`${shownDateLabel} nutrition summary`}>
        <div>
          <span>Calories</span>
          <strong>{calorieTotal == null ? "—" : Math.round(calorieTotal).toLocaleString()}</strong>
          <small>{day.data.targets?.calories_kcal ? `of ${Math.round(day.data.targets.calories_kcal).toLocaleString()} kcal` : "kcal logged"}</small>
        </div>
        <div>
          <span>Protein</span>
          <strong>{proteinTotal == null ? "—" : `${Math.round(proteinTotal)} g`}</strong>
          <small>{day.data.targets?.protein_g ? `of ${Math.round(day.data.targets.protein_g)} g` : "logged today"}</small>
        </div>
      </div>

      <div className="fitness-log__first-view">
        <FitnessCard title={editingEntry ? "Edit food" : "Add food"} detail={editingEntry ? "Update this diary entry." : `${titleCase(meal)} is selected from the time of day.`} className="fitness-log__quick-card">
          <form className="fitness-log__detail-form" onSubmit={(event) => void saveDetail(event)}>
            <label>Meal<select value={meal} onChange={(event) => setMeal(event.target.value as FitnessMealKey)}>{mealOptions.map((option) => <option value={option.key} key={option.key}>{option.label}</option>)}</select></label>
            {!foods.loading && !recipes.loading ? <>
              {!selectedSource && !externalSelection ? <div className="fitness-log__food-search">
                <label>Search foods<input ref={foodSearchRef} type="search" autoComplete="off" value={foodQuery} placeholder="Search every saved or packaged food" onChange={(event) => { setFoodQuery(event.target.value); setLookupResults([]); setLocalError(null); }} /></label>
                {foodQuery.trim() ? <div className="fitness-log__food-results">
                  {matchingSources.map((source) => <div className="fitness-log__food-result" role="group" aria-label={source.label} key={source.key}><button type="button" className="fitness-log__food-result-main" onClick={() => selectDetailSource(source)}><strong>{source.label}</strong><span>{source.kind === "recipe" ? "Recipe" : "Saved food"}</span></button><button type="button" className="button button--secondary fitness-log__food-result-add" aria-label="Quick add" title={`Add ${source.label} to ${meal}`} disabled={logSave.saving || quickLoggingSourceKeys.has(source.key)} onClick={() => void quickAddSource(source)}><Plus aria-hidden="true" size={18} /></button></div>)}
                  <div className="fitness-log__database-actions">
                    <button type="button" className="button button--secondary" aria-label="Search full food database" disabled={!navigator.onLine || lookupBusy || foodQuery.trim().length < 2} onClick={() => void lookupFood()}>{lookupBusy ? "Searching full database…" : `Search full food database for “${foodQuery.trim()}”`}</button>
                    <button type="button" className="button button--secondary" onClick={onCreateFood}>Add it manually</button>
                  </div>
                  {lookupResults.map((result) => <button type="button" className="fitness-log__lookup-result" key={result.barcode} onClick={() => selectLookupResult(result)}><strong>{result.name}</strong><span>{[result.brand, "Open Food Facts"].filter(Boolean).join(" · ")}</span></button>)}
                </div> : null}
              </div> : <div className="fitness-log__selected-food"><div><strong>{externalSelection?.name ?? selectedSource?.label}</strong><span>{externalSelection ? "Looked up food" : selectedSource?.kind === "recipe" ? "Recipe" : "Saved food"}</span></div>{!editingEntry ? <button type="button" className="button button--secondary button--compact" onClick={clearDetailSelection}>Change</button> : null}</div>}
              {selectedSource || externalSelection ? <div className="fitness-log__portion-fields">
                <label>Amount<input type="text" inputMode="decimal" pattern="(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)" required value={detailRow.amount} onChange={(event) => setDetailRow((current) => ({ ...current, amount: event.target.value }))} /></label>
                <label>Unit<select required value={detailRow.unitKey ?? ""} onChange={(event) => changeDetailUnit(event.target.value)}><option value="">Choose a unit</option>{detailUnits.map((option) => <option value={option.key} key={option.key}>{option.label}</option>)}</select></label>
                {externalSelection?.warnings.length ? <p className="fitness-log__lookup-warning">{externalSelection.warnings.join(" ")}</p> : null}
              </div> : null}
            </> : <SkeletonList rows={3} />}
            <div className="fitness-log__actions">
              <button type="submit" className="button button--primary" disabled={logSave.saving || !detailRow.sourceKey || !detailRow.unitKey}>{editingEntry ? "Save changes" : `Add to ${mealOptions.find((option) => option.key === meal)?.label.toLocaleLowerCase()}`}</button>
              {editingEntry ? <button type="button" className="button button--secondary" onClick={() => { setEditingEntry(null); clearDetailSelection(); }}>Cancel</button> : null}
            </div>
          </form>
          <FitnessFormStatus saving={logSave.saving} saved={false} error={logSave.saveError} />
          {localError ? <p className="fitness-module__form-status is-error" role="alert">{localError}</p> : null}
        </FitnessCard>

        <FitnessCard title={date === localDateValue() ? "Today’s diary" : `${shownDateLabel} diary`} detail={entries.length ? `${entries.length} ${entries.length === 1 ? "item" : "items"}` : "Nothing logged yet"} className="fitness-log__diary-card">
          {!loading ? <div className="fitness-log__meal-sections">{mealGroups.map((group) => {
            const groupCalories = group.entries
              .map((entry) => entry.calories_kcal)
              .filter((value): value is number => typeof value === "number" && Number.isFinite(value))
              .reduce((sum, value) => sum + value, 0);
            return <section className="fitness-log__meal-section" aria-labelledby={`fitness-meal-${group.key}`} key={group.key}><div className="fitness-log__meal-heading"><div><h4 id={`fitness-meal-${group.key}`}>{group.label}</h4><span>{group.entries.length ? `${group.entries.length} ${group.entries.length === 1 ? "item" : "items"}${groupCalories > 0 ? ` · ${Math.round(groupCalories)} kcal` : ""}` : "Nothing logged"}</span></div><button type="button" className="button button--secondary button--compact" aria-label={`Add food to ${group.label}`} onClick={() => startAddingToMeal(group.key)}><Plus aria-hidden="true" size={16} /> Add food</button></div>{group.entries.length ? <ul className="fitness-log__diary-list">{group.entries.map((entry) => {
              const label = entryLabel(entry, foods.data, recipes.data);
              const nutrient = nutritionAddedHighlight(entry);
              return <li key={entry.id}><div><strong>{label}</strong><span>{entry.entered_amount} {entry.entered_unit}{nutrient ? ` · ${nutrient.replace(" logged", "")}` : ""}</span></div><div className="fitness-log__diary-actions"><button type="button" className="button button--secondary button--compact" aria-label={`Edit portion for ${label}`} onClick={() => editEntry(entry)}><Pencil aria-hidden="true" size={15} /> Edit</button><button type="button" className="button button--secondary button--compact" aria-label={`Remove ${label}`} onClick={() => void undoEntries([{ id: entry.id, revision: entry.revision }])}><Trash2 aria-hidden="true" size={15} /> Remove</button></div></li>;
            })}</ul> : null}</section>;
          })}</div> : <SkeletonList rows={4} />}
          {day.error ? <div className="fitness-log__inline-error" role="alert"><span>{day.error}</span><button type="button" className="button button--secondary button--compact" onClick={day.reload}>Try again</button></div> : null}
        </FitnessCard>
      </div>

      {!plannedMeals.loading && plannedMeals.data.length ? (
        <FitnessCard title="From the family meal plan" detail="Log the suggested portion, or adjust it first." className="fitness-log__planned-meals">
          <ul>{plannedMeals.data.map((planned) => {
            const logged = entries.find((entry) => entry.source_meal_plan_id === planned.meal_plan_id);
            const editing = plannedEdit?.id === planned.meal_plan_id;
            return <li key={planned.meal_plan_id}><div><span>{titleCase(planned.meal_type)}</span><strong>{planned.meal_name}</strong><small>{planned.recipe_name}</small></div>{logged ? <div className="fitness-log__planned-actions"><span><Check aria-hidden="true" size={15} /> Logged in your diary</span><button type="button" className="button button--secondary button--compact" onClick={() => void undoEntries([{ id: logged.id, revision: logged.revision }])}><Undo2 aria-hidden="true" size={15} /> Undo</button></div> : editing ? <form onSubmit={(event) => { event.preventDefault(); void logPlanned(planned, Number(plannedEdit.portion), plannedEdit.unit); }}><label>Portion<input type="text" inputMode="decimal" required value={plannedEdit.portion} onChange={(event) => setPlannedEdit({ ...plannedEdit, portion: event.target.value })} /></label><label>Unit<select value={plannedEdit.unit} onChange={(event) => setPlannedEdit({ ...plannedEdit, unit: event.target.value as "serving" | "g" })}><option value="serving">serving</option><option value="g">g</option></select></label><button type="submit" className="button button--primary">Log portion</button><button type="button" className="button button--secondary" onClick={() => setPlannedEdit(null)}>Cancel</button></form> : <div className="fitness-log__planned-actions"><button type="button" className="button button--primary" onClick={() => void logPlanned(planned)}>Log {planned.suggested_portion} {planned.suggested_unit}</button><button type="button" className="button button--secondary" onClick={() => setPlannedEdit({ id: planned.meal_plan_id, portion: String(planned.suggested_portion), unit: planned.suggested_unit })}>Edit portion</button></div>}{plannedErrors[planned.meal_plan_id] ? <p className="fitness-module__form-status is-error" role="alert">{plannedErrors[planned.meal_plan_id]}</p> : null}</li>;
          })}</ul>
        </FitnessCard>
      ) : null}

      <div className="fitness-log__secondary-tools" aria-label="Other ways to add food">
        <span>More ways to log</span>
        <div className="fitness-log__actions">
          <button type="button" className="button button--secondary" onClick={() => { clearCapture(); setCaptureMode("text"); }}><Mic aria-hidden="true" size={16} /> Type or speak</button>
          <button type="button" className="button button--secondary" onClick={() => { clearCapture(); setCaptureMode("photo"); }}><Camera aria-hidden="true" size={16} /> Meal photo</button>
        </div>
      </div>

      {captureMode === "text" ? (
        <FitnessCard title="Type or speak" detail="Review the editable text, then check every item before saving.">
          {captureStage === "compose" ? <div className="fitness-log__capture-compose"><label>What did you eat?<textarea rows={3} value={transcript} onChange={(event) => setTranscript(event.target.value)} placeholder="Two bowls of porridge and one banana" /></label>{speechConstructor ? <button type="button" className="button button--secondary" aria-pressed={listening} disabled={listening} onClick={startListening}><Mic aria-hidden="true" size={17} /> {listening ? "Listening…" : "Speak"}</button> : null}<div className="fitness-log__actions"><button type="button" className="button button--primary" onClick={reviewTranscript}>Review items</button><button type="button" className="button button--secondary" onClick={clearCapture}>Cancel</button></div></div> : <div className="fitness-log__capture-review"><FitnessDraftRows rows={draftRows} sources={sources} onChange={setDraftRows} /><label>Meal<select value={meal} onChange={(event) => setMeal(event.target.value as FitnessMealKey)}>{mealOptions.map((option) => <option value={option.key} key={option.key}>{option.label}</option>)}</select></label><div className="fitness-log__actions"><button type="button" className="button button--secondary" onClick={() => setCaptureStage("compose")}>Edit text</button><button type="button" className="button button--primary" disabled={batchSave.saving} onClick={() => void saveDraft()}>Save {draftRows.length} {draftRows.length === 1 ? "item" : "items"}</button><button type="button" className="button button--secondary" onClick={clearCapture}>Cancel</button></div></div>}
        </FitnessCard>
      ) : null}

      {captureMode === "photo" ? (
        <FitnessCard title="Meal photo draft" detail="Use the photo as a local reference while you list the meal.">
          {captureStage === "compose" ? <div className="fitness-log__photo-compose"><label>Meal photo<input ref={photoInputRef} type="file" accept="image/*" onChange={(event) => choosePhoto(event.target.files?.[0] ?? null)} /></label>{photoUrl ? <figure><img src={photoUrl} alt="Meal photo preview" /><figcaption>{photoName}</figcaption></figure> : null}{photoUrl ? <FitnessDraftRows rows={draftRows} sources={sources} onChange={setDraftRows} /> : null}<div className="fitness-log__actions"><button type="button" className="button button--primary" disabled={!photoUrl || !draftRows.length || draftRows.some((row) => !row.sourceKey || Number(row.amount) <= 0)} onClick={() => setCaptureStage("review")}>Review meal</button><button type="button" className="button button--secondary" onClick={clearCapture}>Cancel</button></div></div> : <div className="fitness-log__photo-review">{photoUrl ? <img src={photoUrl} alt="Meal photo preview" /> : null}<ul>{draftRows.map((row) => { const source = sources.find((item) => item.key === row.sourceKey); return <li key={row.id}><strong>{source?.label ?? "Choose an item"}</strong><span>{row.amount} {row.unit}</span></li>; })}</ul><div className="fitness-log__actions"><button type="button" className="button button--secondary" onClick={() => setCaptureStage("compose")}>Edit meal</button><button type="button" className="button button--primary" disabled={batchSave.saving} onClick={() => void saveDraft()}>Save meal</button><button type="button" className="button button--secondary" onClick={clearCapture}>Cancel</button></div></div>}
        </FitnessCard>
      ) : null}

      {undo ? <div className="fitness-log__undo" role="status"><span><strong>{undo.label} logged.</strong>{undo.highlight ? <small>{undo.highlight}</small> : <small>Saved to today’s diary.</small>}</span><button ref={undoRef} type="button" className="button button--secondary" onClick={() => void undoEntries(undo.records)}><Undo2 aria-hidden="true" size={16} /> Undo</button></div> : null}
      <FitnessFormStatus saving={batchSave.saving} saved={false} error={batchSave.saveError} />
    </div>
  );
}

function FitnessMeasurementLog({ onDataChanged }: FitnessViewProps) {
  const save = useFitnessSave(onDataChanged);
  const [metric, setMetric] = useState("body.weight_kg");
  const [value, setValue] = useState("");
  const [unit, setUnit] = useState("kg");
  const [measuredAt, setMeasuredAt] = useState(localDateTimeValue);

  function chooseMetric(next: string) {
    setMetric(next);
    setUnit(next === "body.weight_kg" ? "kg" : next === "body.waist_cm" || next === "body.height_cm" ? "cm" : "%");
  }

  async function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    await save.save("body_measurement", { metric_key: metric, measured_at_utc: utcFromLocalInput(measuredAt), local_timezone: localTimeZone(), value: Number(value), unit_key: unit, measurement_quality: "measured", canonical_state: "canonical", duplicate_of_measurement_id: null, notes: null });
    setValue("");
  }

  return <FitnessCard title="Record a measurement" detail="Add one reading and carry on."><form className="fitness-log__simple-form" onSubmit={(event) => void submit(event).catch(() => undefined)}><label>Measurement<select value={metric} onChange={(event) => chooseMetric(event.target.value)}><option value="body.weight_kg">Weight</option><option value="body.body_fat_pct">Body fat</option><option value="body.height_cm">Height</option><option value="body.waist_cm">Waist</option></select></label><label>Value<input type="text" inputMode="decimal" required value={value} onChange={(event) => setValue(event.target.value)} /></label><label>Unit<input required value={unit} onChange={(event) => setUnit(event.target.value)} /></label><label>When<input type="datetime-local" required value={measuredAt} onChange={(event) => setMeasuredAt(event.target.value)} /></label><div className="fitness-log__actions"><button type="submit" className="button button--primary" aria-busy={save.saving} disabled={save.saving || !Number.isFinite(Number(value))}>Save measurement</button></div><FitnessFormStatus saving={save.saving} saved={save.saved} error={save.saveError} /></form></FitnessCard>;
}

function FitnessSleepLog({ onDataChanged }: FitnessViewProps) {
  const save = useFitnessSave(onDataChanged);
  const [end, setEnd] = useState(localDateTimeValue);
  const [start, setStart] = useState(() => localDateTimeValue(new Date(Date.now() - 8 * 60 * 60 * 1000)));
  const [notes, setNotes] = useState("");
  const [localError, setLocalError] = useState<string | null>(null);

  async function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    const duration = Math.round((new Date(end).valueOf() - new Date(start).valueOf()) / 1000);
    if (!Number.isFinite(duration) || duration <= 0) { setLocalError("Wake time must be after sleep start."); return; }
    setLocalError(null);
    await save.save("sleep_session", { sleep_start_utc: utcFromLocalInput(start), sleep_end_utc: utcFromLocalInput(end), duration_s: duration, awake_duration_s: null, source_quality: "manual", source_stages: [], source: null, notes: notes.trim() || null });
    setNotes("");
  }

  return <FitnessCard title="Log sleep" detail="Start and wake time are enough."><form className="fitness-log__simple-form" onSubmit={(event) => void submit(event).catch(() => undefined)}><label>Sleep start<input type="datetime-local" required value={start} onChange={(event) => setStart(event.target.value)} /></label><label>Wake time<input type="datetime-local" required value={end} onChange={(event) => setEnd(event.target.value)} /></label><label className="is-wide">Notes (optional)<input value={notes} onChange={(event) => setNotes(event.target.value)} /></label><div className="fitness-log__actions"><button type="submit" className="button button--primary" aria-busy={save.saving} disabled={save.saving}>Save sleep</button></div>{localError ? <p className="fitness-module__form-status is-error" role="alert">{localError}</p> : null}<FitnessFormStatus saving={save.saving} saved={save.saved} error={save.saveError} /></form></FitnessCard>;
}

function FitnessIssueLog({ onDataChanged }: FitnessViewProps) {
  const save = useFitnessSave(onDataChanged);
  const [location, setLocation] = useState("");
  const [type, setType] = useState("discomfort");
  const [side, setSide] = useState("unknown");
  const [severity, setSeverity] = useState("3");
  const [notes, setNotes] = useState("");

  async function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    await save.save("body_issue", { observed_at_utc: new Date().toISOString(), timing: "standalone", issue_type_key: type, body_location_key: location.trim().toLocaleLowerCase().replace(/\s+/g, "_"), side, severity_0_10: Number(severity), changed_session: false, session_change_key: "none", trend_key: "new", status: "active", resolved_at_utc: null, notes: notes.trim() || null });
    setLocation(""); setNotes("");
  }

  return <FitnessCard title="Log a body issue" detail="A short record helps future sessions adapt."><form className="fitness-log__simple-form" onSubmit={(event) => void submit(event).catch(() => undefined)}><label>Where?<input required value={location} onChange={(event) => setLocation(event.target.value)} placeholder="Left knee" /></label><label>What?<select value={type} onChange={(event) => setType(event.target.value)}><option value="discomfort">Discomfort</option><option value="pain">Pain</option><option value="tightness">Tightness</option><option value="weakness">Weakness</option><option value="injury">Injury</option><option value="other">Other</option></select></label><label>Side<select value={side} onChange={(event) => setSide(event.target.value)}><option value="unknown">Not sure</option><option value="left">Left</option><option value="right">Right</option><option value="bilateral">Both</option><option value="midline">Centre</option><option value="not_applicable">Not applicable</option></select></label><label>Severity: {severity}/10<input type="range" min="0" max="10" value={severity} onChange={(event) => setSeverity(event.target.value)} /></label><label className="is-wide">Notes (optional)<input value={notes} onChange={(event) => setNotes(event.target.value)} /></label><div className="fitness-log__actions"><button type="submit" className="button button--primary" aria-busy={save.saving} disabled={save.saving || !location.trim()}>Save body issue</button></div><FitnessFormStatus saving={save.saving} saved={save.saved} error={save.saveError} /></form></FitnessCard>;
}

export function FitnessLogView({
  mode,
  onModeChange,
  onCreateFood,
  ...props
}: FitnessViewProps & {
  mode: FitnessLogMode;
  onModeChange: (mode: FitnessLogMode) => void;
  onCreateFood: () => void;
}) {
  return <div className="fitness-log"><div className="fitness-log__modes" role="tablist" aria-label="What to log">{logModes.map((item) => { const Icon = item.icon; return <button type="button" role="tab" aria-selected={mode === item.id} className={mode === item.id ? "is-active" : undefined} onClick={() => onModeChange(item.id)} key={item.id}><Icon aria-hidden="true" size={17} /> {item.label}</button>; })}</div><div role="tabpanel" aria-label={logModes.find((item) => item.id === mode)?.label}>{mode === "food" ? <FitnessFoodLog {...props} onCreateFood={onCreateFood} /> : null}{mode === "measurement" ? <FitnessMeasurementLog {...props} /> : null}{mode === "sleep" ? <FitnessSleepLog {...props} /> : null}{mode === "issue" ? <FitnessIssueLog {...props} /> : null}</div></div>;
}

export function FitnessHouseholdMealsPanel({ online, onDataChanged }: FitnessViewProps) {
  const [meals, setMeals] = useState<HouseholdMeal[]>([]);
  const [recipes, setRecipes] = useState<FitnessRecipe[]>([]);
  const [links, setLinks] = useState<FitnessHouseholdMealLink[]>([]);
  const [loading, setLoading] = useState(true);
  const [loadError, setLoadError] = useState<string | null>(null);
  const [mealId, setMealId] = useState("");
  const [versionId, setVersionId] = useState("");
  const [saving, setSaving] = useState(false);
  const [formError, setFormError] = useState<string | null>(null);
  const [confirmUnlink, setConfirmUnlink] = useState<string | null>(null);
  const [rowErrors, setRowErrors] = useState<Record<string, string>>({});
  const [nonce, setNonce] = useState(0);

  useEffect(() => {
    let cancelled = false;
    setLoading(true); setLoadError(null);
    if (!navigator.onLine) { setLoading(false); return () => { cancelled = true; }; }
    void Promise.all([
      api<HouseholdMeal[]>("/meals/", {}, true, false),
      api<FitnessRecipe[]>("/fitness/recipes", {}, true, false),
      api<FitnessHouseholdMealLink[]>("/fitness/household-meals", {}, true, false),
    ]).then(([nextMeals, nextRecipes, nextLinks]) => { if (!cancelled) { setMeals(nextMeals); setRecipes(nextRecipes); setLinks(nextLinks); } }).catch((requestError) => { if (!cancelled) setLoadError(errorMessage(requestError)); }).finally(() => { if (!cancelled) setLoading(false); });
    return () => { cancelled = true; };
  }, [nonce]);

  const sharedVersions = recipes.flatMap((recipe) => {
    if (!recipe.household_shared || recipe.active === false) return [];
    const version = recipe.current_version ?? recipe.latest_version;
    return version?.id ? [{ id: version.id, recipeId: recipe.id, name: recipe.name }] : [];
  });

  async function linkMeal(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    setSaving(true); setFormError(null);
    try {
      await api(`/fitness/household-meals/${encodeURIComponent(mealId)}`, { method: "PUT", body: JSON.stringify({ id: crypto.randomUUID(), recipe_version_id: versionId }) }, true, false);
      setMealId(""); setVersionId(""); setNonce((value) => value + 1); onDataChanged();
    } catch (requestError) {
      setFormError(errorMessage(requestError));
    } finally { setSaving(false); }
  }

  async function unlink(meal: FitnessHouseholdMealLink) {
    setRowErrors((current) => ({ ...current, [meal.meal_id]: "" }));
    try {
      await api(`/fitness/household-meals/${encodeURIComponent(meal.meal_id)}`, { method: "DELETE" }, true, false);
      setConfirmUnlink(null); setNonce((value) => value + 1); onDataChanged();
    } catch (requestError) {
      setRowErrors((current) => ({ ...current, [meal.meal_id]: errorMessage(requestError) }));
    }
  }

  return <div className="fitness-log__household-manage"><FitnessCard title="Connect family meals" detail="Choose the shared recipe used when a family meal appears in your private diary.">{loading ? <SkeletonList rows={3} /> : loadError ? <div className="fitness-log__inline-error" role="alert"><span>{loadError}</span><button type="button" className="button button--secondary" onClick={() => setNonce((value) => value + 1)}>Try again</button></div> : <><form className="fitness-log__household-form" onSubmit={(event) => void linkMeal(event)}><label>Family meal<select required value={mealId} onChange={(event) => setMealId(event.target.value)}><option value="">Choose a meal</option>{meals.map((meal) => <option value={meal.id} key={meal.id}>{meal.name}</option>)}</select></label><label>Shared recipe<select required value={versionId} onChange={(event) => setVersionId(event.target.value)}><option value="">Choose a recipe</option>{sharedVersions.map((recipe) => <option value={recipe.id} key={recipe.id}>{recipe.name}</option>)}</select></label><button type="submit" className="button button--primary" aria-busy={saving} disabled={!online || saving || !mealId || !versionId}>{saving ? "Connecting…" : links.some((link) => link.meal_id === mealId) ? "Change recipe" : "Connect meal"}</button>{!online ? <p>Connect to update family meal links.</p> : null}{formError ? <p className="fitness-module__form-status is-error" role="alert">{formError}</p> : null}</form>{links.length ? <ul className="fitness-log__household-links">{links.map((link) => <li key={link.id}><div><strong>{link.meal_name}</strong><span>{link.recipe_name}</span></div>{confirmUnlink === link.meal_id ? <div><button type="button" className="button button--danger button--compact" onClick={() => void unlink(link)}>Unlink</button><button type="button" className="button button--secondary button--compact" onClick={() => setConfirmUnlink(null)}>Cancel</button></div> : <div><button type="button" className="button button--secondary button--compact" onClick={() => { setMealId(link.meal_id); setVersionId(link.recipe_version_id); }}>Change</button><button type="button" className="button button--secondary button--compact" onClick={() => setConfirmUnlink(link.meal_id)}>Unlink</button></div>}{rowErrors[link.meal_id] ? <p className="fitness-module__form-status is-error" role="alert">{rowErrors[link.meal_id]}</p> : null}</li>)}</ul> : <div className="fitness-log__empty"><strong>No family meals connected</strong><span>Connect one when you want it to appear as a logging shortcut.</span></div>}</>}</FitnessCard></div>;
}
