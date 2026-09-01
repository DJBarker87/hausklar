import {
  BookOpen,
  CalendarPlus,
  CalendarDays,
  Check,
  ChefHat,
  ChevronLeft,
  ChevronRight,
  CirclePlus,
  Clock3,
  ExternalLink,
  FileDown,
  Heart,
  ListChecks,
  PackageOpen,
  Plus,
  Search,
  ShoppingCart,
  Sparkles,
  Trash2,
  Utensils,
} from "lucide-react";
import { addDays, addWeeks, format, parseISO, startOfWeek } from "date-fns";
import { useCallback, useEffect, useMemo, useRef, useState, type FormEvent } from "react";

import { api, localISODate } from "../api";
import { ShoppingItemDialog } from "../components/ShoppingItemDialog";
import { EmptyState, ErrorState, IconButton, Modal, Segmented, SkeletonList, cn } from "../components/ui";
import type { FinanceFinding, FinanceProductHistory, FinanceRetailerResearchResult, FinanceSpace } from "../types";
import "./meals.css";

type MealsTab = "tonight" | "week" | "shopping" | "library" | "pantry";
type Meal = {
  id: string;
  name: string;
  description?: string | null;
  recipe_url?: string | null;
  tags?: string | null;
  ingredients?: string | null;
  prep_minutes?: number | null;
  servings?: number | null;
  allergy_notes?: string | null;
  preference_notes?: string | null;
  not_for_us?: boolean;
  last_made_at?: string | null;
};
type MealPlan = { id: string; meal_id: string; date: string; meal_type: string; meal_name?: string | null; notes?: string | null };
type ShoppingItem = { id: string; name: string; quantity?: string | null; category?: string | null; checked: boolean };
type Stock = { grocery_item_id: string; item_name: string; category?: string | null; remaining: number; unit: string; earliest_use_by?: string | null; days_until_expiry?: number | null };
type Expiring = { grocery_item_id: string; item_name: string; use_by_date: string; remaining_qty: number; unit: string; days_left: number; alert_level: string };
type LowStock = { grocery_item_id: string; item_name: string; remaining: number; unit: string; threshold: number; reason: string };
type Recommendation = { meal_id: string; meal_name: string; tags: string[]; score: number; reasons: string[] };
type Recommendations = { recommendations: Recommendation[]; date: string };
type Ingredient = { name: string; quantity?: string | null; category?: string | null };
type PlanDiffItem = { key: string; name: string; quantity?: string | null; category?: string | null; meal_plan_ids: string[]; planned_meals: string[]; already_on_list: boolean; likely_at_home: boolean };
type PlanDiff = { start: string; end: string; items: PlanDiffItem[] };
type RecipePreview = { name: string; recipe_url?: string | null; ingredients: Ingredient[]; prep_minutes?: number | null; servings?: number | null; uncertain_fields: string[] };
type ShoppingSavingIdea = {
  findingId: string;
  comparisonId: string;
  itemName: string;
  retailer: string;
  productName: string;
  pack: string;
  currentUnitPrice: string | null;
  alternativeUnitPrice: string;
  savingLabel: string;
  savingPeriodLabel: string;
  qualityLabel: string;
  inconvenience: string;
  evidenceLabel: string;
  confidenceLabel: string;
};
type TescoHistoryUsual = {
  name: string;
  shop_count: number;
  last_bought: string;
  latest_price_pence?: number | null;
  previous_price_pence?: number | null;
};
type TescoHistorySummary = {
  shop_count: number;
  line_count: number;
  first_purchased_at?: string | null;
  last_purchased_at?: string | null;
  last_imported_at?: string | null;
  receipt_monitoring: boolean;
  price_rise_count: number;
  usuals: TescoHistoryUsual[];
};
type TescoHistoryPreview = {
  filename: string;
  sha256: string;
  order_count: number;
  line_count: number;
  first_purchased_at?: string | null;
  last_purchased_at?: string | null;
  sample_items: string[];
  issues: string[];
  already_imported: boolean;
  can_confirm: boolean;
};
type TescoHistoryImportResult = {
  imported: boolean;
  imported_orders: number;
  skipped_orders: number;
  preview: TescoHistoryPreview;
};

const emptyTescoHistory: TescoHistorySummary = {
  shop_count: 0,
  line_count: 0,
  receipt_monitoring: false,
  price_rise_count: 0,
  usuals: [],
};

const mealTypes = ["breakfast", "lunch", "dinner"] as const;

function parseTags(value?: string | null): string[] {
  if (!value) return [];
  try {
    const parsed: unknown = JSON.parse(value);
    return Array.isArray(parsed) ? parsed.filter((item): item is string => typeof item === "string") : [];
  } catch {
    return [];
  }
}

function parseIngredients(value?: string | null): Ingredient[] {
  if (!value) return [];
  try {
    const parsed: unknown = JSON.parse(value);
    return Array.isArray(parsed)
      ? parsed.filter((item): item is Ingredient => Boolean(item) && typeof item === "object" && typeof (item as Ingredient).name === "string")
      : [];
  } catch {
    return [];
  }
}

function ingredientsToText(items: Ingredient[]): string {
  return items.map((item) => [item.quantity, item.name, item.category].filter(Boolean).join(" | ")).join("\n");
}

function ingredientsFromText(value: string): Ingredient[] {
  return value.split("\n").map((line) => line.trim()).filter(Boolean).map((line) => {
    const parts = line.split("|").map((part) => part.trim());
    if (parts.length >= 2) return { quantity: parts[0] || null, name: parts[1], category: parts[2] || null };
    return { name: parts[0] };
  }).filter((item) => item.name.length > 0);
}

function shoppingTokens(value: string): string[] {
  return value
    .normalize("NFKD")
    .toLocaleLowerCase("en-GB")
    .replace(/[^a-z0-9]+/g, " ")
    .split(" ")
    .filter((token) => token.length >= 4 && !["pack", "packs", "bottle", "bottles", "usual"].includes(token));
}

function matchesShoppingItem(itemName: string, shoppingNames: string[]): boolean {
  const item = itemName.trim().toLocaleLowerCase("en-GB");
  const itemTokens = new Set(shoppingTokens(item));
  return shoppingNames.some((name) => {
    const shoppingName = name.trim().toLocaleLowerCase("en-GB");
    if (item.includes(shoppingName) || shoppingName.includes(item)) return true;
    return shoppingTokens(shoppingName).some((token) => itemTokens.has(token));
  });
}

function money(minor: number, currency: string): string {
  return new Intl.NumberFormat("en-GB", { style: "currency", currency }).format(minor / 100);
}

function unitPrice(priceMinor: number, quantityText: string, basis: string, currency: string): string {
  const quantity = Number(quantityText);
  if (!Number.isFinite(quantity) || quantity <= 0) return money(priceMinor, currency);
  const unitQuantity = basis === "g" || basis === "ml" ? 100 : 1;
  const label = basis === "g" ? "100g" : basis === "ml" ? "100ml" : "each";
  return `${money(Math.round(priceMinor * unitQuantity / quantity), currency)} / ${label}`;
}

function savingRange(finding: FinanceFinding): string {
  if (finding.saving_low_minor === finding.saving_high_minor) return money(finding.saving_high_minor, finding.currency);
  return `${money(finding.saving_low_minor, finding.currency)}–${money(finding.saving_high_minor, finding.currency)}`;
}

function qualityLabel(result: FinanceRetailerResearchResult): string {
  if (result.match_kind === "EXACT") return "Exact match";
  if (result.match_kind === "REALISTIC_SUBSTITUTE") return "Comparable substitute";
  return "Different way to buy";
}

function periodLabel(start: string, end: string): string {
  const formatter = new Intl.DateTimeFormat("en-GB", { month: "short", year: "numeric" });
  return `${formatter.format(new Date(`${start}T12:00:00`))}–${formatter.format(new Date(`${end}T12:00:00`))}`;
}

export function MealsView({ revision, initialTab = "meals", financeEnabled = false, onDataChanged, notify }: { revision: number; initialTab?: "meals" | "tesco"; financeEnabled?: boolean; onDataChanged: () => void; notify: (message: string) => void }) {
  const [tab, setTab] = useState<MealsTab>(initialTab === "tesco" ? "shopping" : "tonight");
  const [week, setWeek] = useState(startOfWeek(new Date(), { weekStartsOn: 1 }));
  const [meals, setMeals] = useState<Meal[]>([]);
  const [plans, setPlans] = useState<MealPlan[]>([]);
  const [shopping, setShopping] = useState<ShoppingItem[]>([]);
  const [stock, setStock] = useState<Stock[]>([]);
  const [expiring, setExpiring] = useState<Expiring[]>([]);
  const [lowStock, setLowStock] = useState<LowStock[]>([]);
  const [recommendations, setRecommendations] = useState<Recommendations | null>(null);
  const [search, setSearch] = useState("");
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [working, setWorking] = useState<string | null>(null);
  const [showMeal, setShowMeal] = useState(false);
  const [editingMealId, setEditingMealId] = useState<string | null>(null);
  const [selectedMeal, setSelectedMeal] = useState<Meal | null>(null);
  const [removedMeal, setRemovedMeal] = useState<Meal | null>(null);
  const [mealName, setMealName] = useState("");
  const [mealDescription, setMealDescription] = useState("");
  const [mealMinutes, setMealMinutes] = useState("");
  const [mealServings, setMealServings] = useState("");
  const [mealRecipeURL, setMealRecipeURL] = useState("");
  const [mealIngredients, setMealIngredients] = useState("");
  const [mealAllergies, setMealAllergies] = useState("");
  const [mealPreferences, setMealPreferences] = useState("");
  const [mealTags, setMealTags] = useState("");
  const [showRecipeImport, setShowRecipeImport] = useState(false);
  const [recipeImportText, setRecipeImportText] = useState("");
  const [recipeImportURL, setRecipeImportURL] = useState("");
  const [showShopping, setShowShopping] = useState(false);
  const [confirmClear, setConfirmClear] = useState(false);
  const [highlightedShoppingID, setHighlightedShoppingID] = useState<string | null>(null);
  const [slot, setSlot] = useState<{ date: string; type: string } | null>(null);
  const [slotMeal, setSlotMeal] = useState("");
  const [planDiff, setPlanDiff] = useState<PlanDiff | null>(null);
  const [selectedDiffKeys, setSelectedDiffKeys] = useState<Set<string>>(new Set());
  const [showPlanDiff, setShowPlanDiff] = useState(false);
  const [recommendationToPlan, setRecommendationToPlan] = useState<Recommendation | null>(null);
  const [recommendationDate, setRecommendationDate] = useState(localISODate(addDays(new Date(), 1)));
  const [savingIdeas, setSavingIdeas] = useState<ShoppingSavingIdea[]>([]);
  const [savingIdeasState, setSavingIdeasState] = useState<"idle" | "loading" | "ready">("idle");
  const [savingWork, setSavingWork] = useState<string | null>(null);
  const [savingNotice, setSavingNotice] = useState<string | null>(null);
  const [tescoHistory, setTescoHistory] = useState<TescoHistorySummary>(emptyTescoHistory);
  const [tescoHistoryOpen, setTescoHistoryOpen] = useState(initialTab === "tesco");
  const [tescoHistoryFile, setTescoHistoryFile] = useState<File | null>(null);
  const [tescoHistoryPreview, setTescoHistoryPreview] = useState<TescoHistoryPreview | null>(null);
  const [tescoHistoryBusy, setTescoHistoryBusy] = useState(false);
  const [tescoHistoryError, setTescoHistoryError] = useState<string | null>(null);
  const tescoHistoryInputRef = useRef<HTMLInputElement>(null);

  const days = useMemo(() => Array.from({ length: 7 }, (_, index) => addDays(week, index)), [week]);

  useEffect(() => {
    setTab(initialTab === "tesco" ? "shopping" : "tonight");
    if (initialTab === "tesco") setTescoHistoryOpen(true);
  }, [initialTab]);

  useEffect(() => {
    const identifier = new URL(window.location.href).searchParams.get("shopping");
    if (!identifier || loading || !shopping.some((item) => item.id === identifier)) return;
    setTab("shopping");
    setHighlightedShoppingID(identifier);
    const url = new URL(window.location.href);
    url.searchParams.delete("shopping");
    window.history.replaceState({}, "", url);
    window.requestAnimationFrame(() => {
      const reducedMotion = window.matchMedia?.("(prefers-reduced-motion: reduce)").matches ?? false;
      document.getElementById(`shopping-${identifier}`)?.scrollIntoView({ behavior: reducedMotion ? "auto" : "smooth", block: "center" });
    });
  }, [loading, shopping]);

  useEffect(() => {
    if (!highlightedShoppingID) return;
    const timeout = window.setTimeout(() => setHighlightedShoppingID(null), 4_000);
    return () => window.clearTimeout(timeout);
  }, [highlightedShoppingID]);

  const load = useCallback(async (background = false) => {
    if (!background) setLoading(true);
    setError(null);
    const start = localISODate(week);
    const end = localISODate(addDays(week, 6));
    async function optional<T>(path: string, fallback: T): Promise<T> {
      try { return await api<T>(path); } catch { return fallback; }
    }
    try {
      const [mealItems, planItems, shoppingItems, stockItems, expiringItems, lowItems, suggested, history] = await Promise.all([
        api<Meal[]>("/meals/"),
        api<MealPlan[]>(`/meals/plan?start=${start}&end=${end}`),
        api<ShoppingItem[]>("/meals/shopping"),
        optional<Stock[]>("/grocery/stock", []),
        optional<Expiring[]>("/grocery/expiring", []),
        optional<LowStock[]>("/grocery/critical-low", []),
        optional<Recommendations | null>(`/meals/recommendations?date=${localISODate(new Date())}&limit=8`, null),
        optional<TescoHistorySummary>("/grocery/tesco-history/summary", emptyTescoHistory),
      ]);
      setMeals(mealItems);
      setPlans(planItems);
      setShopping(shoppingItems);
      setStock(stockItems);
      setExpiring(expiringItems);
      setLowStock(lowItems);
      setRecommendations(suggested);
      setTescoHistory(history);
    } catch (requestError) {
      setError(requestError instanceof Error ? requestError.message : "Meals are unavailable.");
    } finally {
      setLoading(false);
    }
  }, [week]);

  const lastRevision = useRef(revision);
  useEffect(() => {
    const background = revision !== lastRevision.current;
    lastRevision.current = revision;
    void load(background);
  }, [load, revision]);

  const openShoppingNames = useMemo(
    () => shopping.filter((item) => !item.checked).map((item) => item.name.trim()).filter(Boolean),
    [shopping],
  );
  const openShoppingKey = openShoppingNames.map((name) => name.toLocaleLowerCase("en-GB")).sort().join("|");

  useEffect(() => {
    if (!financeEnabled || tab !== "shopping" || loading || !openShoppingKey) {
      setSavingIdeas([]);
      setSavingIdeasState("idle");
      return;
    }
    const controller = new AbortController();
    let active = true;
    setSavingIdeasState("loading");
    setSavingNotice(null);

    async function loadSavingIdeas() {
      try {
        const spaces = await api<FinanceSpace[]>("/finance/spaces", { signal: controller.signal }, true, false);
        const household = spaces.find((space) => space.kind === "household");
        if (!household) throw new Error("Household Finance is unavailable");
        const findings = await api<FinanceFinding[]>(
          `/finance/opportunities?space_id=${encodeURIComponent(household.id)}`,
          { signal: controller.signal },
          true,
          false,
        );
        const candidates = findings
          .filter((finding) => finding.status === "OPEN" && finding.saving_high_minor > 0)
          .map((finding) => {
            const comparisonId = typeof finding.baseline.comparison_id === "string" ? finding.baseline.comparison_id : null;
            const overlap = finding.overlap_group?.split(":") ?? [];
            const itemId = overlap[0] === "product" ? overlap[1] : null;
            const hintedName = finding.title.match(/^Compare\s+(.+?)\s+with\s+/i)?.[1] ?? "";
            const periodStart = overlap[2];
            const periodEnd = overlap[3];
            return comparisonId && itemId && periodStart && periodEnd && matchesShoppingItem(hintedName, openShoppingNames)
              ? { finding, comparisonId, itemId, periodStart, periodEnd }
              : null;
          })
          .filter((candidate): candidate is { finding: FinanceFinding; comparisonId: string; itemId: string; periodStart: string; periodEnd: string } => candidate !== null)
          .slice(0, 6);

        const loaded = await Promise.all(candidates.map(async ({ finding, comparisonId, itemId, periodStart, periodEnd }) => {
          try {
            const [history, results] = await Promise.all([
              api<FinanceProductHistory>(`/finance/items/${encodeURIComponent(itemId)}/product-price-history?space_id=${encodeURIComponent(household.id)}&limit=20`, { signal: controller.signal }, true, false),
              api<FinanceRetailerResearchResult[]>(`/finance/items/${encodeURIComponent(itemId)}/retailer-research-results?space_id=${encodeURIComponent(household.id)}&limit=20`, { signal: controller.signal }, true, false),
            ]);
            if (!matchesShoppingItem(history.normalized_item_name, openShoppingNames)) return null;
            const resultId = finding.evidence_refs.find((reference) => reference.startsWith("retailer-result:"))?.split(":", 2)[1];
            const result = results.find((candidate) => candidate.id === resultId);
            if (!result) return null;
            const current = history.observations.find((observation) => observation.source_kind === "PURCHASE_LINE" && observation.unit_basis === result.unit_basis);
            return {
              findingId: finding.id,
              comparisonId,
              itemName: history.normalized_item_name,
              retailer: result.retailer_name,
              productName: result.product_name,
              pack: `${result.pack_quantity} ${result.pack_unit}`,
              currentUnitPrice: current ? unitPrice(current.price_minor, current.comparable_quantity, current.unit_basis, current.currency) : null,
              alternativeUnitPrice: unitPrice(result.price_minor, result.comparable_quantity, result.unit_basis, result.currency),
              savingLabel: savingRange(finding),
              savingPeriodLabel: periodLabel(periodStart, periodEnd),
              qualityLabel: qualityLabel(result),
              inconvenience: result.inconvenience_note,
              evidenceLabel: `${result.source_label} · checked ${new Intl.DateTimeFormat("en-GB", { day: "numeric", month: "short", year: "numeric" }).format(new Date(`${result.observed_on}T12:00:00`))}`,
              confidenceLabel: `${Math.round(result.confidence_bps / 100)}% evidence confidence`,
            } satisfies ShoppingSavingIdea;
          } catch {
            return null;
          }
        }));
        if (!active) return;
        setSavingIdeas(loaded.filter((idea): idea is ShoppingSavingIdea => idea !== null).slice(0, 2));
        setSavingIdeasState("ready");
      } catch {
        if (!active) return;
        setSavingIdeas([]);
        setSavingIdeasState("ready");
      }
    }

    void loadSavingIdeas();
    return () => {
      active = false;
      controller.abort();
    };
  }, [financeEnabled, loading, openShoppingKey, tab]);

  function resetMealForm() {
    setEditingMealId(null);
    setMealName("");
    setMealDescription("");
    setMealMinutes("");
    setMealServings("");
    setMealRecipeURL("");
    setMealIngredients("");
    setMealAllergies("");
    setMealPreferences("");
    setMealTags("");
  }

  function openNewMeal() {
    resetMealForm();
    setShowMeal(true);
  }

  function openMealEditor(meal: Meal) {
    setEditingMealId(meal.id);
    setMealName(meal.name);
    setMealDescription(meal.description ?? "");
    setMealMinutes(meal.prep_minutes?.toString() ?? "");
    setMealServings(meal.servings?.toString() ?? "");
    setMealRecipeURL(meal.recipe_url ?? "");
    setMealIngredients(ingredientsToText(parseIngredients(meal.ingredients)));
    setMealAllergies(meal.allergy_notes ?? "");
    setMealPreferences(meal.preference_notes ?? "");
    setMealTags(parseTags(meal.tags).join(", "));
    setSelectedMeal(null);
    setShowMeal(true);
  }

  async function saveMeal(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    setWorking("meal");
    setError(null);
    try {
      const payload = {
        name: mealName.trim(),
        description: mealDescription.trim() || null,
        recipe_url: mealRecipeURL.trim() || null,
        prep_minutes: mealMinutes ? Number(mealMinutes) : null,
        servings: mealServings ? Number(mealServings) : null,
        ingredients: ingredientsFromText(mealIngredients),
        allergy_notes: mealAllergies.trim() || null,
        preference_notes: mealPreferences.trim() || null,
        tags: mealTags.split(",").map((tag) => tag.trim()).filter(Boolean),
      };
      if (editingMealId) await api(`/meals/${editingMealId}`, { method: "PUT", body: JSON.stringify(payload) });
      else await api("/meals/", { method: "POST", body: JSON.stringify(payload) });
      setShowMeal(false);
      notify(editingMealId ? "Meal updated." : "Meal added.");
      resetMealForm();
      onDataChanged();
    } catch (requestError) { setError(requestError instanceof Error ? requestError.message : "The meal could not be saved."); }
    finally { setWorking(null); }
  }

  async function previewRecipe(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    setWorking("recipe-preview");
    setError(null);
    try {
      const preview = await api<RecipePreview>("/meals/recipe-preview", {
        method: "POST",
        body: JSON.stringify({ text: recipeImportText.trim() || null, recipe_url: recipeImportURL.trim() || null }),
      });
      resetMealForm();
      setMealName(preview.name);
      setMealRecipeURL(preview.recipe_url ?? "");
      setMealMinutes(preview.prep_minutes?.toString() ?? "");
      setMealServings(preview.servings?.toString() ?? "");
      setMealIngredients(ingredientsToText(preview.ingredients));
      setShowRecipeImport(false);
      setShowMeal(true);
      setRecipeImportText("");
      setRecipeImportURL("");
    } catch (requestError) {
      setError(requestError instanceof Error ? requestError.message : "That recipe could not be read.");
    } finally {
      setWorking(null);
    }
  }

  async function removeMeal(meal: Meal) {
    setWorking(`remove-meal-${meal.id}`);
    setError(null);
    try {
      await api(`/meals/${meal.id}`, { method: "DELETE" });
      setMeals((current) => current.filter((candidate) => candidate.id !== meal.id));
      setSelectedMeal(null);
      setRemovedMeal(meal);
      notify(`${meal.name} removed.`);
      onDataChanged();
    } catch (requestError) {
      setError(requestError instanceof Error ? requestError.message : "The meal could not be removed.");
    } finally {
      setWorking(null);
    }
  }

  async function restoreMeal() {
    if (!removedMeal) return;
    const meal = removedMeal;
    setWorking("restore-meal");
    try {
      const restored = await api<Meal>(`/meals/${meal.id}/restore`, { method: "POST" });
      setMeals((current) => [...current, restored].sort((a, b) => a.name.localeCompare(b.name)));
      setRemovedMeal(null);
      notify(`${meal.name} is back.`);
      onDataChanged();
    } catch (requestError) {
      setError(requestError instanceof Error ? requestError.message : "The meal could not be restored.");
    } finally {
      setWorking(null);
    }
  }

  async function toggleMealSuggestions(meal: Meal) {
    setWorking(`suggestion-toggle-${meal.id}`);
    try {
      const updated = await api<Meal>(`/meals/${meal.id}`, {
        method: "PUT",
        body: JSON.stringify({ not_for_us: !meal.not_for_us }),
      });
      setMeals((current) => current.map((candidate) => candidate.id === meal.id ? updated : candidate));
      setSelectedMeal(updated);
      notify(updated.not_for_us ? `${meal.name} will stay out of dinner suggestions.` : `${meal.name} can be suggested again.`);
      onDataChanged();
    } catch (requestError) {
      setError(requestError instanceof Error ? requestError.message : "That preference could not be saved.");
    } finally {
      setWorking(null);
    }
  }

  async function openShoppingReview() {
    const start = localISODate(week);
    const end = localISODate(addDays(week, 6));
    setWorking("plan-diff");
    setError(null);
    try {
      const preview = await api<PlanDiff>(`/meals/shopping/plan-diff?start=${start}&end=${end}`);
      setPlanDiff(preview);
      setSelectedDiffKeys(new Set(preview.items.filter((item) => !item.already_on_list && !item.likely_at_home).map((item) => item.key)));
      setShowPlanDiff(true);
    } catch (requestError) {
      setError(requestError instanceof Error ? requestError.message : "The ingredients could not be checked.");
    } finally {
      setWorking(null);
    }
  }

  async function previewTescoHistory(file: File) {
    setTescoHistoryOpen(true);
    setTescoHistoryFile(file);
    setTescoHistoryPreview(null);
    setTescoHistoryError(null);
    setTescoHistoryBusy(true);
    try {
      const form = new FormData();
      form.append("file", file);
      const preview = await api<TescoHistoryPreview>("/grocery/tesco-history/preview", {
        method: "POST",
        body: form,
        timeoutMs: 60_000,
      }, true, false);
      setTescoHistoryPreview(preview);
    } catch (requestError) {
      setTescoHistoryError(requestError instanceof Error ? requestError.message : "The Tesco file could not be read.");
    } finally {
      setTescoHistoryBusy(false);
    }
  }

  async function confirmTescoHistory() {
    if (!tescoHistoryFile || !tescoHistoryPreview?.can_confirm) return;
    setTescoHistoryBusy(true);
    setTescoHistoryError(null);
    try {
      const form = new FormData();
      form.append("file", tescoHistoryFile);
      form.append("expected_sha256", tescoHistoryPreview.sha256);
      const result = await api<TescoHistoryImportResult>("/grocery/tesco-history/import", {
        method: "POST",
        body: form,
        timeoutMs: 60_000,
      }, true, false);
      const summary = await api<TescoHistorySummary>("/grocery/tesco-history/summary");
      setTescoHistory(summary);
      setTescoHistoryFile(null);
      setTescoHistoryPreview(null);
      notify(result.imported_orders ? `${result.imported_orders} Tesco ${result.imported_orders === 1 ? "shop" : "shops"} added.` : "Tesco history is already up to date.");
    } catch (requestError) {
      setTescoHistoryError(requestError instanceof Error ? requestError.message : "Tesco history could not be imported.");
    } finally {
      setTescoHistoryBusy(false);
    }
  }

  function toggleDiffItem(key: string) {
    setSelectedDiffKeys((current) => {
      const next = new Set(current);
      if (next.has(key)) next.delete(key);
      else next.add(key);
      return next;
    });
  }

  async function addReviewedIngredients() {
    if (!planDiff) return;
    setWorking("apply-diff");
    setError(null);
    try {
      const result = await api<{ created: ShoppingItem[]; skipped: number }>("/meals/shopping/plan-diff/apply", {
        method: "POST",
        body: JSON.stringify({ start: planDiff.start, end: planDiff.end, keys: [...selectedDiffKeys] }),
      });
      setShopping((current) => [...result.created, ...current]);
      setShowPlanDiff(false);
      notify(result.created.length ? `${result.created.length} ${result.created.length === 1 ? "ingredient" : "ingredients"} added to shopping.` : "Shopping already covers those ingredients.");
      onDataChanged();
    } catch (requestError) {
      setError(requestError instanceof Error ? requestError.message : "The ingredients could not be added.");
    } finally {
      setWorking(null);
    }
  }

  async function chooseRecommendation(item: Recommendation, action: "use_tonight" | "plan_another_day" | "not_for_us", date?: string) {
    setWorking(`recommendation-${item.meal_id}`);
    setError(null);
    try {
      const result = await api<{ message: string }>(`/meals/recommendations/${item.meal_id}/decision`, {
        method: "POST",
        body: JSON.stringify({ action, date: date ?? null }),
      });
      notify(result.message);
      setRecommendationToPlan(null);
      await load(true);
      onDataChanged();
    } catch (requestError) {
      setError(requestError instanceof Error ? requestError.message : "That dinner choice could not be saved.");
    } finally {
      setWorking(null);
    }
  }

  async function addPantryExceptionToShopping(name: string, quantity?: string) {
    setWorking(`pantry-${name}`);
    setError(null);
    try {
      const created = await api<ShoppingItem>("/meals/shopping", { method: "POST", body: JSON.stringify({ name, quantity: quantity || null }) });
      setShopping((current) => [created, ...current]);
      notify(`${name} added to shopping.`);
      onDataChanged();
    } catch (requestError) {
      setError(requestError instanceof Error ? requestError.message : "That item could not be added.");
    } finally {
      setWorking(null);
    }
  }

  async function toggleShopping(item: ShoppingItem) {
    setWorking(item.id);
    setShopping((current) => current.map((candidate) => candidate.id === item.id ? { ...candidate, checked: !candidate.checked } : candidate));
    try { await api(`/meals/shopping/${item.id}/check`, { method: "PATCH" }); onDataChanged(); }
    catch (requestError) { setShopping((current) => current.map((candidate) => candidate.id === item.id ? item : candidate)); setError(requestError instanceof Error ? requestError.message : "The shopping list could not be updated."); }
    finally { setWorking(null); }
  }

  async function deleteShopping(item: ShoppingItem) {
    setWorking(`delete-${item.id}`);
    setError(null);
    try {
      await api(`/meals/shopping/${item.id}`, { method: "DELETE" });
      setShopping((current) => current.filter((candidate) => candidate.id !== item.id));
      notify(`${item.name} removed from the shopping list.`);
      onDataChanged();
    } catch (requestError) {
      setError(requestError instanceof Error ? requestError.message : "The shopping item could not be removed.");
    } finally {
      setWorking(null);
    }
  }

  async function clearCompleted() {
    if (!checkedShopping.length) return;
    setWorking("clear-shopping");
    setError(null);
    try {
      for (const item of checkedShopping) {
        await api(`/meals/shopping/${item.id}`, { method: "DELETE" });
      }
      const completedIDs = new Set(checkedShopping.map((item) => item.id));
      setShopping((current) => current.filter((item) => !completedIDs.has(item.id)));
      setConfirmClear(false);
      notify(`${checkedShopping.length} completed ${checkedShopping.length === 1 ? "item" : "items"} cleared.`);
      onDataChanged();
    } catch (requestError) {
      setError(requestError instanceof Error ? requestError.message : "Completed shopping items could not be cleared.");
      await load(true);
    } finally {
      setWorking(null);
    }
  }

  async function chooseSavingIdea(idea: ShoppingSavingIdea, choice: "try" | "usual" | "unsuitable") {
    setSavingWork(`${idea.findingId}:${choice}`);
    setSavingNotice(null);
    try {
      if (choice === "try") {
        await api(`/finance/product-comparisons/${encodeURIComponent(idea.comparisonId)}/accept`, {
          method: "POST",
          body: JSON.stringify({ action_kind: "PREFERENCE", review_date: null, trigger: null, target: null }),
        }, true, false);
        notify("Saved as a Household Finance preference. Your shopping list was not changed.");
      } else {
        await api(`/finance/opportunities/${encodeURIComponent(idea.findingId)}/disposition`, {
          method: "POST",
          body: JSON.stringify({ status: choice === "usual" ? "SNOOZED" : "DISMISSED" }),
        }, true, false);
        notify(choice === "usual" ? "Kept the usual choice for now. Your shopping list was not changed." : "Marked as not suitable. Your shopping list was not changed.");
      }
      setSavingIdeas((current) => current.filter((candidate) => candidate.findingId !== idea.findingId));
      onDataChanged();
    } catch {
      setSavingNotice("That choice could not be saved. Your shopping list was not changed.");
    } finally {
      setSavingWork(null);
    }
  }

  async function assignSlot(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (!slot || !slotMeal) return;
    setWorking("slot");
    try {
      const existing = plans.find((plan) => plan.date === slot.date && plan.meal_type === slot.type);
      if (existing) await api(`/meals/plan/${existing.id}`, { method: "DELETE" });
      await api("/meals/plan", { method: "POST", body: JSON.stringify({ meal_id: slotMeal, date: slot.date, meal_type: slot.type }) });
      setSlot(null); setSlotMeal(""); notify("Meal plan updated."); onDataChanged();
    } catch (requestError) { setError(requestError instanceof Error ? requestError.message : "The meal could not be assigned."); }
    finally { setWorking(null); }
  }

  async function removePlan(plan: MealPlan) {
    setWorking(plan.id);
    try { await api(`/meals/plan/${plan.id}`, { method: "DELETE" }); notify("Meal removed from the plan."); onDataChanged(); }
    catch (requestError) { setError(requestError instanceof Error ? requestError.message : "The meal could not be removed."); }
    finally { setWorking(null); }
  }

  const filteredMeals = meals.filter((meal) => `${meal.name} ${meal.description ?? ""}`.toLowerCase().includes(search.trim().toLowerCase()));
  const openShopping = shopping.filter((item) => !item.checked);
  const checkedShopping = shopping.filter((item) => item.checked);
  const dinner = plans.find((plan) => plan.date === localISODate(new Date()) && plan.meal_type === "dinner");
  const dinnerMeal = meals.find((meal) => meal.id === dinner?.meal_id);
  const recommendationItems = Array.isArray(recommendations?.recommendations) ? recommendations.recommendations : [];

  return (
    <div className="standard-page meals-page">
      <header className="page-header"><div><p className="page-eyebrow">Dinner, the week and what to buy</p><h1>Meals &amp; shopping</h1></div>{tab === "library" ? <div className="page-header-actions"><button type="button" className="button button--secondary" onClick={() => setShowRecipeImport(true)}><BookOpen aria-hidden="true" size={18} /> Copy a recipe</button><button type="button" className="button button--primary" onClick={openNewMeal}><Plus aria-hidden="true" size={18} /> New meal</button></div> : tab === "shopping" ? <button type="button" className="button button--primary" onClick={() => setShowShopping(true)}><Plus aria-hidden="true" size={18} /> Add item</button> : null}</header>
      <Segmented value={tab} onChange={setTab} label="Meal section selector" options={[
        { value: "tonight", label: "Tonight" }, { value: "week", label: "This week" }, { value: "shopping", label: "Shopping" },
      ]} />
      <nav className="meal-secondary-nav" aria-label="Meal tools"><span>More</span><button type="button" className={cn(tab === "library" && "is-active")} aria-current={tab === "library" ? "page" : undefined} onClick={() => setTab("library")}><BookOpen aria-hidden="true" size={16} />Meal library</button><button type="button" className={cn(tab === "pantry" && "is-active")} aria-current={tab === "pantry" ? "page" : undefined} onClick={() => setTab("pantry")}><PackageOpen aria-hidden="true" size={16} />Pantry</button></nav>
      {error ? <ErrorState message={error} retry={load} /> : null}
      {loading ? <SkeletonList rows={7} /> : null}

      {removedMeal ? <div className="undo-banner" role="status"><span>{removedMeal.name} removed.</span><button type="button" disabled={working === "restore-meal"} onClick={() => void restoreMeal()}>Undo</button></div> : null}

      {!loading && tab === "library" ? <section className="meal-library" aria-label="Meal library">
        <label className="search-field"><span className="sr-only">Search meals</span><Search aria-hidden="true" size={17} /><input type="search" value={search} onChange={(event) => setSearch(event.target.value)} placeholder="Search meals" /></label>
        {!filteredMeals.length ? <EmptyState title={meals.length ? "No matching meals" : "No meals yet"} detail={meals.length ? "Try a different search." : "Add the meals your family returns to."} action={openNewMeal} actionLabel="Add meal" /> : null}
        <div className="meal-grid">{filteredMeals.map((meal) => <button type="button" className="meal-card" key={meal.id} onClick={() => setSelectedMeal(meal)}><ChefHat aria-hidden="true" size={21} /><strong>{meal.name}</strong>{meal.description ? <p>{meal.description}</p> : null}<div>{meal.prep_minutes ? <span><Clock3 aria-hidden="true" size={14} />{meal.prep_minutes} min</span> : null}{meal.servings ? <span>{meal.servings} people</span> : null}{meal.not_for_us ? <span>Skip in suggestions</span> : null}{parseTags(meal.tags).slice(0, 2).map((tag) => <span key={tag}>{tag}</span>)}</div></button>)}</div>
      </section> : null}

      {!loading && tab === "week" ? <section className="meal-plan-view" aria-label="Weekly meal plan">
        <div className="week-toolbar"><div className="week-switcher"><IconButton label="Previous week" icon={ChevronLeft} onClick={() => setWeek((value) => addWeeks(value, -1))} /><strong>{format(week, "d MMM")} – {format(addDays(week, 6), "d MMM yyyy")}</strong><IconButton label="Next week" icon={ChevronRight} onClick={() => setWeek((value) => addWeeks(value, 1))} /></div><button type="button" className="button button--secondary" disabled={working === "plan-diff" || !plans.length} onClick={() => void openShoppingReview()}><ListChecks aria-hidden="true" size={17} />Check what we need</button></div>
        <div className="meal-plan-scroll" aria-describedby="meal-plan-scroll-hint"><div className="meal-plan-days">{days.map((day) => <section className={cn("meal-plan-day", localISODate(day) === localISODate(new Date()) && "is-today")} key={day.toISOString()}><header><strong>{format(day, "EEEE")}</strong><span>{format(day, "d MMM")}</span></header>{mealTypes.map((type) => { const plan = plans.find((item) => item.date === localISODate(day) && item.meal_type === type); return <div className="meal-slot" key={type}><span>{type}</span>{plan ? <div><strong>{plan.meal_name ?? "Planned meal"}</strong><button type="button" aria-label={`Remove ${plan.meal_name ?? "meal"}`} disabled={working === plan.id} onClick={() => void removePlan(plan)}><Trash2 aria-hidden="true" size={15} /></button></div> : <button type="button" onClick={() => setSlot({ date: localISODate(day), type })}><CirclePlus aria-hidden="true" size={17} />Plan</button>}</div>; })}</section>)}</div></div>
        <p className="meal-plan-scroll-hint" id="meal-plan-scroll-hint">Swipe to see the rest of the week</p>
      </section> : null}

      {!loading && tab === "shopping" ? <section className="shopping-view" aria-label="Shopping list">
        <div className="shopping-toolbar"><div><strong>{openShopping.length ? `${openShopping.length} to buy` : "Nothing to buy"}</strong><span>Shared family list</span></div><div className="shopping-toolbar-actions"><button type="button" className="button button--secondary" onClick={() => setTescoHistoryOpen(true)}><FileDown aria-hidden="true" size={17} />Tesco history</button><button type="button" className="button button--secondary" disabled={working === "plan-diff" || !plans.length} onClick={() => void openShoppingReview()}><CalendarDays aria-hidden="true" size={17} />From this week</button></div></div>
        {savingIdeasState === "loading" ? <p className="muted-copy" role="status">Checking reviewed Household Finance prices for this list…</p> : null}
        {savingIdeas.length ? <section className="finance-product-alternative" aria-labelledby="shopping-savings-title">
          <header><div><p className="page-eyebrow">Optional savings</p><h2 id="shopping-savings-title">Worth a quick swap?</h2><p>Based only on reviewed Household Finance evidence. Nothing changes unless you choose.</p></div></header>
          {savingNotice ? <p className="form-error" role="alert">{savingNotice}</p> : null}
          {savingIdeas.map((idea) => <article key={idea.findingId}>
            <header><div><strong>{idea.itemName}: {idea.productName}</strong><p>{idea.retailer} · {idea.pack} · {idea.qualityLabel}</p></div><span className="status-pill">Save {idea.savingLabel} over {idea.savingPeriodLabel}</span></header>
            <dl>
              {idea.currentUnitPrice ? <div><dt>Usual observed price</dt><dd>{idea.currentUnitPrice}</dd></div> : null}
              <div><dt>Alternative unit price</dt><dd>{idea.alternativeUnitPrice}</dd></div>
              <div><dt>Evidence</dt><dd>{idea.evidenceLabel}</dd></div>
              <div><dt>Match</dt><dd>{idea.confidenceLabel}</dd></div>
            </dl>
            <p><strong>What to know:</strong> {idea.inconvenience}</p>
            <div className="dialog-actions">
              <button type="button" className="button button--primary" disabled={savingWork !== null} onClick={() => void chooseSavingIdea(idea, "try")}>{savingWork === `${idea.findingId}:try` ? "Saving…" : "Try next shop"}</button>
              <button type="button" className="button button--secondary" disabled={savingWork !== null} onClick={() => void chooseSavingIdea(idea, "usual")}>Keep usual</button>
              <button type="button" className="button button--secondary" disabled={savingWork !== null} onClick={() => void chooseSavingIdea(idea, "unsuitable")}>Not suitable</button>
            </div>
          </article>)}
        </section> : null}
        {!openShopping.length ? <EmptyState title="Shopping list is clear" detail="Add something now, or check this week's meals for missing ingredients." action={() => setShowShopping(true)} actionLabel="Add item" /> : null}
        <div className="shopping-items">{openShopping.map((item) => <div className={cn("shopping-row", highlightedShoppingID === item.id && "is-highlighted")} id={`shopping-${item.id}`} key={item.id}><button type="button" className="shopping-row-main" disabled={working === item.id} aria-label={`Mark ${item.name} as in trolley`} onClick={() => void toggleShopping(item)}><span className="shopping-check"><Check aria-hidden="true" size={16} /></span><span><strong>{item.name}</strong><small>{[item.quantity, item.category].filter(Boolean).join(" · ")}</small></span></button><IconButton className="shopping-delete" label={`Remove ${item.name}`} icon={Trash2} tone="danger" disabled={working === `delete-${item.id}`} onClick={() => void deleteShopping(item)} /></div>)}</div>
        {checkedShopping.length ? <details className="completed-charts"><summary>In trolley ({checkedShopping.length})</summary><div className="completed-shopping-heading"><span>Completed items</span><button type="button" className="button button--secondary button--compact" onClick={() => setConfirmClear(true)}>Clear completed</button></div>{checkedShopping.map((item) => <div className={cn("shopping-row is-checked", highlightedShoppingID === item.id && "is-highlighted")} id={`shopping-${item.id}`} key={item.id}><button type="button" className="shopping-row-main" disabled={working === item.id} aria-label={`Return ${item.name} to the shopping list`} onClick={() => void toggleShopping(item)}><Check aria-hidden="true" size={16} /><span>{item.name}</span></button><IconButton className="shopping-delete" label={`Remove ${item.name}`} icon={Trash2} tone="danger" disabled={working === `delete-${item.id}`} onClick={() => void deleteShopping(item)} /></div>)}</details> : null}
      </section> : null}

      {!loading && tab === "pantry" ? <section className="pantry-view" aria-label="Pantry and stock">
        <header className="pantry-intro"><div><p className="page-eyebrow">Only what needs attention</p><h2>Pantry</h2><p>HausKlar keeps the detailed stock record out of the way until something is running low or needs using.</p></div></header>
        {!expiring.length && !lowStock.length ? <EmptyState title="Nothing needs attention" detail="There are no low or use-soon items right now." /> : null}
        {expiring.length ? <div className="pantry-exception-group"><div className="section-heading"><div><p className="page-eyebrow">Use soon</p><h2>{expiring.some((item) => item.days_left < 0) ? "Use or replace" : "Worth using next"}</h2></div></div><div className="pantry-exceptions">{expiring.map((item) => <article key={`${item.grocery_item_id}-${item.use_by_date}`}><PackageOpen aria-hidden="true" size={20} /><div><strong>{item.item_name}</strong><span>{item.remaining_qty} {item.unit} · {item.days_left < 0 ? "past its use-by date" : item.days_left === 0 ? "use today" : `${item.days_left} days left`}</span></div><button type="button" className="button button--secondary button--compact" disabled={working === `pantry-${item.item_name}` || openShopping.some((shoppingItem) => shoppingItem.name.toLocaleLowerCase() === item.item_name.toLocaleLowerCase())} onClick={() => void addPantryExceptionToShopping(item.item_name, `${item.remaining_qty} ${item.unit}`)}>{openShopping.some((shoppingItem) => shoppingItem.name.toLocaleLowerCase() === item.item_name.toLocaleLowerCase()) ? "On list" : "Replace"}</button></article>)}</div></div> : null}
        {lowStock.length ? <div className="pantry-exception-group"><div className="section-heading"><div><p className="page-eyebrow">Running low</p><h2>Buy next time</h2></div></div><div className="pantry-exceptions">{lowStock.map((item) => <article key={item.grocery_item_id}><PackageOpen aria-hidden="true" size={20} /><div><strong>{item.item_name}</strong><span>{item.remaining.toFixed(1).replace(".0", "")} {item.unit} left</span></div><button type="button" className="button button--secondary button--compact" disabled={working === `pantry-${item.item_name}` || openShopping.some((shoppingItem) => shoppingItem.name.toLocaleLowerCase() === item.item_name.toLocaleLowerCase())} onClick={() => void addPantryExceptionToShopping(item.item_name)}>{openShopping.some((shoppingItem) => shoppingItem.name.toLocaleLowerCase() === item.item_name.toLocaleLowerCase()) ? "On list" : "Add"}</button></article>)}</div></div> : null}
        {stock.length ? <details className="pantry-full-stock"><summary>See everything at home ({stock.length})</summary><div className="stock-grid">{stock.map((item) => <article key={item.grocery_item_id}><strong>{item.item_name}</strong><span>{item.remaining.toFixed(1).replace(".0", "")} {item.unit}</span><small>{item.category ?? "Pantry"}</small></article>)}</div></details> : null}
      </section> : null}

      {!loading && tab === "tonight" ? <section className="tonight-view" aria-label="Tonight's meal">
        <div className="tonight-current"><Utensils aria-hidden="true" size={26} /><div><span>Tonight</span><h2>{dinner?.meal_name ?? "Dinner is not planned"}</h2>{dinnerMeal?.prep_minutes ? <p>{dinnerMeal.prep_minutes} minutes to prepare</p> : null}</div><div className="tonight-current-actions">{dinnerMeal?.recipe_url ? <a className="button button--secondary" href={dinnerMeal.recipe_url} target="_blank" rel="noreferrer"><ExternalLink aria-hidden="true" size={16} />Recipe</a> : null}<button type="button" className={cn("button", dinner ? "button--secondary" : "button--primary")} onClick={() => setSlot({ date: localISODate(new Date()), type: "dinner" })}><Plus aria-hidden="true" size={17} />{dinner ? "Change" : "Choose dinner"}</button></div></div>
        <div className="section-heading"><div><p className="page-eyebrow">Easy choices</p><h2>{dinner ? "Other good options" : "Choose dinner"}</h2></div><Sparkles aria-hidden="true" size={20} /></div>
        {!recommendationItems.length ? <EmptyState title="No suggestions yet" detail="Add a few family meals and HausKlar will make this decision quicker." action={() => setTab("library")} actionLabel="Open meal library" /> : <div className="recommendation-list">{recommendationItems.filter((item) => item.meal_id !== dinner?.meal_id).slice(0, 5).map((item) => { const meal = meals.find((candidate) => candidate.id === item.meal_id); return <article key={item.meal_id}><div className="recommendation-copy"><Sparkles aria-hidden="true" size={18} /><div><strong>{item.meal_name}</strong>{item.reasons[0] ? <span>{item.reasons[0]}</span> : null}</div></div><div className="recommendation-actions"><button type="button" className="button button--primary button--compact" disabled={working === `recommendation-${item.meal_id}`} onClick={() => void chooseRecommendation(item, "use_tonight")}>Use tonight</button><button type="button" className="button button--secondary button--compact" onClick={() => { setRecommendationToPlan(item); setRecommendationDate(localISODate(addDays(new Date(), 1))); }}><CalendarPlus aria-hidden="true" size={15} />Another day</button>{meal?.recipe_url ? <a className="button button--secondary button--compact" href={meal.recipe_url} target="_blank" rel="noreferrer"><ExternalLink aria-hidden="true" size={15} />Recipe</a> : <button type="button" className="button button--secondary button--compact" onClick={() => meal && setSelectedMeal(meal)}>Details</button>}<button type="button" className="button button--quiet button--compact" disabled={working === `recommendation-${item.meal_id}`} onClick={() => void chooseRecommendation(item, "not_for_us")}><Heart aria-hidden="true" size={15} />Skip next time</button></div></article>; })}</div>}
      </section> : null}

      <Modal
        open={tescoHistoryOpen}
        onOpenChange={(open) => {
          if (tescoHistoryBusy) return;
          setTescoHistoryOpen(open);
          if (!open) {
            setTescoHistoryFile(null);
            setTescoHistoryPreview(null);
            setTescoHistoryError(null);
          }
        }}
        title="Tesco history"
        description="HausKlar stores shops, not your Tesco login."
      >
        <div className="tesco-history-dialog">
          {tescoHistory.shop_count ? <>
            <section className="tesco-history-summary" aria-label="Tesco history summary"><div><strong>{tescoHistory.shop_count}</strong><span>shops</span></div><div><strong>{tescoHistory.line_count}</strong><span>items</span></div><div><strong>{tescoHistory.first_purchased_at && tescoHistory.last_purchased_at ? `${format(parseISO(tescoHistory.first_purchased_at), "MMM yy")}–${format(parseISO(tescoHistory.last_purchased_at), "MMM yy")}` : "—"}</strong><span>history</span></div></section>
            {tescoHistory.usuals.length ? <div className="tesco-usuals"><header><strong>Regulars</strong>{tescoHistory.receipt_monitoring ? <span className="status-pill">Receipts on</span> : null}</header>{tescoHistory.usuals.slice(0, 5).map((item) => { const change = item.latest_price_pence != null && item.previous_price_pence != null ? item.latest_price_pence - item.previous_price_pence : null; return <div key={item.name}><span><strong>{item.name}</strong><small>{item.shop_count} shops</small></span>{item.latest_price_pence != null ? <span><strong>{money(item.latest_price_pence, "GBP")}</strong>{change ? <small className={change > 0 ? "is-rise" : "is-fall"}>{change > 0 ? "+" : "−"}{Math.abs(change)}p</small> : null}</span> : null}</div>; })}</div> : null}
          </> : <div className="tesco-history-empty"><ShoppingCart aria-hidden="true" size={24} /><strong>No history yet</strong></div>}
          {tescoHistoryError ? <div className="form-error" role="alert">{tescoHistoryError}</div> : null}
          {tescoHistoryBusy && !tescoHistoryPreview ? <div className="facility-import-loading" role="status"><span className="spinner" aria-hidden="true" />Reading…</div> : null}
          {tescoHistoryPreview ? <section className="tesco-history-preview" aria-label="Tesco import review"><div><strong>{tescoHistoryPreview.order_count} shops</strong><span>{tescoHistoryPreview.line_count} items · {tescoHistoryPreview.first_purchased_at && tescoHistoryPreview.last_purchased_at ? `${format(parseISO(tescoHistoryPreview.first_purchased_at), "MMM yyyy")}–${format(parseISO(tescoHistoryPreview.last_purchased_at), "MMM yyyy")}` : "Dates unavailable"}</span></div>{tescoHistoryPreview.already_imported ? <span className="status-pill">Already imported</span> : null}{tescoHistoryPreview.sample_items.length ? <p>{tescoHistoryPreview.sample_items.join(" · ")}</p> : null}</section> : null}
          <div className="tesco-history-actions"><a className="button button--secondary" href="https://www.tesco.com/account/data-portability/en-GB/" target="_blank" rel="noreferrer"><ExternalLink aria-hidden="true" size={16} />Get Tesco file</a><button type="button" className="button button--secondary" disabled={tescoHistoryBusy} onClick={() => tescoHistoryInputRef.current?.click()}><FileDown aria-hidden="true" size={16} />Choose file</button><input ref={tescoHistoryInputRef} className="sr-only" type="file" accept=".json,.zip,application/json,application/zip" aria-label="Choose Tesco history file" onChange={(event) => { const file = event.target.files?.[0]; event.target.value = ""; if (file) void previewTescoHistory(file); }} /></div>
          {tescoHistoryPreview ? <div className="dialog-actions"><button type="button" className="button button--secondary" disabled={tescoHistoryBusy} onClick={() => { setTescoHistoryPreview(null); setTescoHistoryFile(null); }}>Cancel</button><button type="button" className="button button--primary" disabled={tescoHistoryBusy || !tescoHistoryPreview.can_confirm} onClick={() => { if (tescoHistoryPreview.already_imported) { setTescoHistoryPreview(null); setTescoHistoryFile(null); } else { void confirmTescoHistory(); } }}>{tescoHistoryBusy ? "Importing…" : tescoHistoryPreview.already_imported ? "Done" : "Import history"}</button></div> : null}
        </div>
      </Modal>

      <Modal open={showMeal} onOpenChange={(open) => { setShowMeal(open); if (!open) resetMealForm(); }} title={editingMealId ? "Edit meal" : "New meal"} description="Start with the useful bits. Family notes and ingredients are there when you need them."><form className="form-stack meal-form" onSubmit={saveMeal}><div className="field"><label htmlFor="meal-name">Meal</label><input id="meal-name" value={mealName} onChange={(event) => setMealName(event.target.value)} autoComplete="off" placeholder="Chicken curry" required /></div><div className="field"><label htmlFor="meal-description">Short description <span>Optional</span></label><textarea id="meal-description" rows={2} value={mealDescription} onChange={(event) => setMealDescription(event.target.value)} placeholder="The mild coconut one everyone eats" /></div><div className="form-grid form-grid--three"><div className="field"><label htmlFor="meal-minutes">Prep minutes</label><input id="meal-minutes" type="number" min={0} max={1440} inputMode="numeric" value={mealMinutes} onChange={(event) => setMealMinutes(event.target.value)} /></div><div className="field"><label htmlFor="meal-servings">Feeds</label><input id="meal-servings" type="number" min={1} max={100} inputMode="numeric" value={mealServings} onChange={(event) => setMealServings(event.target.value)} /></div><div className="field"><label htmlFor="meal-tags">Tags</label><input id="meal-tags" value={mealTags} onChange={(event) => setMealTags(event.target.value)} placeholder="fast, pasta" /></div></div><div className="field"><label htmlFor="meal-recipe-url">Recipe web address <span>Optional</span></label><input id="meal-recipe-url" type="url" value={mealRecipeURL} onChange={(event) => setMealRecipeURL(event.target.value)} placeholder="https://…" /></div><div className="field"><label htmlFor="meal-ingredients">Ingredients <span>One per line</span></label><textarea id="meal-ingredients" rows={6} value={mealIngredients} onChange={(event) => setMealIngredients(event.target.value)} placeholder={"500g | chicken | Meat\n1 tin | coconut milk | Tins\nspinach"} /><small>Quantity | ingredient | aisle. Only the ingredient is required.</small></div><details className="form-details"><summary>Allergies and family preferences</summary><div className="form-stack"><div className="field"><label htmlFor="meal-allergies">Safety notes</label><textarea id="meal-allergies" rows={2} value={mealAllergies} onChange={(event) => setMealAllergies(event.target.value)} placeholder="Contains nuts; use oat cream for…" /></div><div className="field"><label htmlFor="meal-preferences">What works for the children</label><textarea id="meal-preferences" rows={2} value={mealPreferences} onChange={(event) => setMealPreferences(event.target.value)} placeholder="Keep sauce separate for…" /></div></div></details><button type="submit" className="button button--primary" disabled={working === "meal"}>{working === "meal" ? "Saving…" : editingMealId ? "Save changes" : "Add meal"}</button></form></Modal>
      <Modal open={showRecipeImport} onOpenChange={setShowRecipeImport} title="Copy a recipe" description="Paste the recipe text, its web address, or both. Check every field before saving."><form className="form-stack" onSubmit={previewRecipe}><div className="field"><label htmlFor="recipe-import-url">Web address <span>Optional</span></label><input id="recipe-import-url" type="url" value={recipeImportURL} onChange={(event) => setRecipeImportURL(event.target.value)} placeholder="https://…" /></div><div className="field"><label htmlFor="recipe-import-text">Recipe text <span>Optional if you added an address</span></label><textarea id="recipe-import-text" rows={10} value={recipeImportText} onChange={(event) => setRecipeImportText(event.target.value)} placeholder={"Recipe name\nServes 5\nPrep time: 25 minutes\n\nIngredients\n500g chicken\n2 cloves garlic\n\nMethod…"} /></div><button type="submit" className="button button--primary" disabled={working === "recipe-preview" || (!recipeImportText.trim() && !recipeImportURL.trim())}>{working === "recipe-preview" ? "Reading…" : "Review recipe"}</button></form></Modal>
      <Modal open={Boolean(selectedMeal)} onOpenChange={(open) => { if (!open) setSelectedMeal(null); }} title={selectedMeal?.name ?? "Meal"}>{selectedMeal ? <div className="meal-detail"><div className="meal-detail-actions"><button type="button" className="button button--primary" onClick={() => openMealEditor(selectedMeal)}>Edit</button>{selectedMeal.recipe_url ? <a className="button button--secondary" href={selectedMeal.recipe_url} target="_blank" rel="noreferrer"><ExternalLink aria-hidden="true" size={16} />Open recipe</a> : null}</div>{selectedMeal.description ? <p>{selectedMeal.description}</p> : null}<dl>{selectedMeal.prep_minutes ? <div><dt>Preparation</dt><dd>{selectedMeal.prep_minutes} minutes</dd></div> : null}{selectedMeal.servings ? <div><dt>Feeds</dt><dd>{selectedMeal.servings}</dd></div> : null}</dl>{parseIngredients(selectedMeal.ingredients).length ? <section><h3>Ingredients</h3><ul>{parseIngredients(selectedMeal.ingredients).map((ingredient, index) => <li key={`${ingredient.name}-${index}`}><span>{ingredient.name}</span>{ingredient.quantity ? <strong>{ingredient.quantity}</strong> : null}</li>)}</ul></section> : null}{selectedMeal.allergy_notes ? <section><h3>Safety notes</h3><p>{selectedMeal.allergy_notes}</p></section> : null}{selectedMeal.preference_notes ? <section><h3>What works for the family</h3><p>{selectedMeal.preference_notes}</p></section> : null}<div className="meal-detail-footer"><button type="button" className="button button--secondary" disabled={working === `suggestion-toggle-${selectedMeal.id}`} onClick={() => void toggleMealSuggestions(selectedMeal)}>{selectedMeal.not_for_us ? "Allow dinner suggestions" : "Skip in dinner suggestions"}</button><button type="button" className="button button--danger" disabled={working === `remove-meal-${selectedMeal.id}`} onClick={() => void removeMeal(selectedMeal)}>Remove meal</button></div></div> : null}</Modal>
      <ShoppingItemDialog open={showShopping} onOpenChange={setShowShopping} onCreated={onDataChanged} notify={notify} />
      <Modal open={confirmClear} onOpenChange={setConfirmClear} title="Clear completed items?" description={`${checkedShopping.length} ${checkedShopping.length === 1 ? "item" : "items"} will be removed from the trolley.`}><div className="dialog-actions"><button type="button" className="button button--secondary" disabled={working === "clear-shopping"} onClick={() => setConfirmClear(false)}>Keep items</button><button type="button" className="button button--danger" disabled={working === "clear-shopping"} onClick={() => void clearCompleted()}>{working === "clear-shopping" ? "Clearing…" : "Clear completed"}</button></div></Modal>
      <Modal open={showPlanDiff} onOpenChange={setShowPlanDiff} title="What do we need?" description={planDiff ? `${format(parseISO(planDiff.start), "d MMM")}–${format(parseISO(planDiff.end), "d MMM")}. Untick anything you already have.` : undefined}>{planDiff ? <div className="plan-diff"><div className="plan-diff-list">{!planDiff.items.length ? <EmptyState title="No ingredients to add" detail="Add ingredients to meals in the library, then they will appear here." /> : planDiff.items.map((item) => <label className={cn("plan-diff-row", item.already_on_list && "is-covered")} key={item.key}><input type="checkbox" checked={selectedDiffKeys.has(item.key)} disabled={item.already_on_list} onChange={() => toggleDiffItem(item.key)} /><span><strong>{item.name}</strong><small>{[item.quantity, item.planned_meals.join(" · ")].filter(Boolean).join(" · ")}</small>{item.already_on_list ? <em>Already on shopping</em> : item.likely_at_home ? <em>Looks like it is at home</em> : null}</span></label>)}</div><div className="dialog-actions"><button type="button" className="button button--secondary" onClick={() => setShowPlanDiff(false)}>Cancel</button><button type="button" className="button button--primary" disabled={working === "apply-diff" || !selectedDiffKeys.size} onClick={() => void addReviewedIngredients()}>{working === "apply-diff" ? "Adding…" : `Add ${selectedDiffKeys.size || ""} to shopping`}</button></div></div> : null}</Modal>
      <Modal open={Boolean(recommendationToPlan)} onOpenChange={(open) => { if (!open) setRecommendationToPlan(null); }} title={recommendationToPlan ? `Plan ${recommendationToPlan.meal_name}` : "Plan another day"}><form className="form-stack" onSubmit={(event) => { event.preventDefault(); if (recommendationToPlan) void chooseRecommendation(recommendationToPlan, "plan_another_day", recommendationDate); }}><div className="field"><label htmlFor="recommendation-date">Day</label><input id="recommendation-date" type="date" value={recommendationDate} min={localISODate(new Date())} onChange={(event) => setRecommendationDate(event.target.value)} required /></div><button type="submit" className="button button--primary" disabled={!recommendationToPlan || working === `recommendation-${recommendationToPlan?.meal_id}`}>Add to the week</button></form></Modal>
      <Modal open={Boolean(slot)} onOpenChange={(open) => { if (!open) { setSlot(null); setSlotMeal(""); } }} title="Choose a meal" description={slot ? `${format(parseISO(slot.date), "EEEE, d MMMM")} · ${slot.type}` : undefined}><form className="form-stack" onSubmit={assignSlot}><div className="field"><label htmlFor="slot-meal">Meal</label><select id="slot-meal" value={slotMeal} onChange={(event) => setSlotMeal(event.target.value)} required><option value="">Choose a meal</option>{meals.filter((meal) => !meal.not_for_us).map((meal) => <option value={meal.id} key={meal.id}>{meal.name}</option>)}</select></div><button type="submit" className="button button--primary" disabled={working === "slot" || !slotMeal}>{working === "slot" ? "Saving…" : "Save meal"}</button><button type="button" className="button button--quiet" onClick={() => { setSlot(null); openNewMeal(); }}>Add a new meal instead</button></form></Modal>
    </div>
  );
}
