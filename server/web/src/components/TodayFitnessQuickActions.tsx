import {
  Activity,
  CheckCircle2,
  Clock3,
  Copy,
  Dumbbell,
  ExternalLink,
  RefreshCw,
  Utensils,
} from "lucide-react";
import { useCallback, useEffect, useMemo, useRef, useState } from "react";

import { api } from "../api";
import type {
  FitnessFood,
  FitnessFoodBarcodeLookup,
  FitnessFoodLogEntry,
  FitnessMealTemplate,
  FitnessNutritionMeasurementQuality,
  FitnessNutritionDay,
  FitnessRecipe,
} from "../fitness/contract";
import {
  canonicalPortion,
  currentFoodVersion,
  defaultFoodPortion,
  foodPortionOptions,
  type FitnessPortionOption,
} from "../fitness/nutrition";
import {
  cacheFitnessRecords,
  cachedFitnessRecords,
  flushFitnessSync,
  saveFitnessRecords,
} from "../fitness/offlineStore";
import {
  cachedFitnessQuickEntryPreferences,
  cachedFitnessViSchedule,
  DEFAULT_FITNESS_QUICK_ENTRY_PREFERENCES,
  FITNESS_QUICK_ENTRY_PREFERENCES_EVENT,
  fitnessQuickMealLabel,
  mealNearTime,
  rememberFitnessQuickEntryPreferences,
  rememberFitnessViSchedule,
  type FitnessQuickEntryPreferences,
  type FitnessQuickMeal,
  type FitnessStrengthAvailability,
  type FitnessViSchedule,
  validFitnessViSchedule,
  validFitnessQuickEntryPreferences,
  validStrengthAvailability,
} from "../fitness/quickEntry";
import { Modal, SkeletonList, cn } from "./ui";

type ExerciseKind = "running" | "strength";
type CatalogueChoice =
  | { key: string; kind: "food"; label: string; food: FitnessFood }
  | { key: string; kind: "recipe"; label: string; recipe: FitnessRecipe }
  | { key: string; kind: "template"; label: string; template: FitnessMealTemplate };

type MealDraftItem = {
  id: string;
  label: string;
  foodVersionId: string | null;
  recipeVersionId: string | null;
  amount: string;
  unitKey: string;
  units: FitnessPortionOption[];
};

function validMeasurementQuality(value: string | null | undefined): FitnessNutritionMeasurementQuality {
  switch (value) {
    case "weighed":
    case "measured":
    case "standard_serving":
    case "restaurant_estimate":
      return value;
    default:
      return "estimated";
  }
}

function localDateValue(date: Date): string {
  const year = date.getFullYear();
  const month = String(date.getMonth() + 1).padStart(2, "0");
  const day = String(date.getDate()).padStart(2, "0");
  return `${year}-${month}-${day}`;
}

function offsetDate(value: Date, days: number): Date {
  const next = new Date(value);
  next.setDate(next.getDate() + days);
  return next;
}

function roundedCurrentTime(value: Date): string {
  const rounded = new Date(value);
  rounded.setMinutes(Math.round(rounded.getMinutes() / 5) * 5, 0, 0);
  return `${String(rounded.getHours()).padStart(2, "0")}:${String(rounded.getMinutes()).padStart(2, "0")}`;
}

function localTimeZone(): string {
  return Intl.DateTimeFormat().resolvedOptions().timeZone || "UTC";
}

function errorMessage(error: unknown, fallback: string): string {
  return error instanceof Error ? error.message : fallback;
}

function checkedAtLabel(value: string | null): string {
  if (!value) return "earlier";
  const checkedAt = new Date(value);
  if (Number.isNaN(checkedAt.getTime())) return "earlier";
  return checkedAt.toLocaleString("en-GB", {
    weekday: "short",
    hour: "2-digit",
    minute: "2-digit",
  });
}

function nutritionEntries(value: FitnessNutritionDay | Partial<FitnessNutritionDay> | null | undefined): FitnessFoodLogEntry[] {
  return Array.isArray(value?.entries) ? value.entries : [];
}

function entryDate(entry: FitnessFoodLogEntry): string {
  return entry.nutrition_date ?? localDateValue(new Date(entry.logged_at_utc));
}

function entryLabel(entry: FitnessFoodLogEntry): string | null {
  const recipeName = (entry as FitnessFoodLogEntry & { recipe_name?: string | null }).recipe_name;
  return entry.food_name ?? recipeName ?? null;
}

function yesterdaySummary(entries: FitnessFoodLogEntry[]): string {
  const labels = [...new Set(entries.map(entryLabel).filter((label): label is string => Boolean(label)))];
  if (!labels.length) return `${entries.length} ${entries.length === 1 ? "item" : "items"}`;
  if (labels.length === 1) return labels[0];
  return `${labels[0]} + ${labels.length - 1} more`;
}

function currentRecipeVersion(recipe: FitnessRecipe) {
  return recipe.current_version ?? recipe.latest_version ?? recipe.versions?.[recipe.versions.length - 1] ?? null;
}

function catalogueChoices(
  foods: FitnessFood[],
  recipes: FitnessRecipe[],
  templates: FitnessMealTemplate[],
  meal: FitnessQuickMeal,
): CatalogueChoice[] {
  return [
    ...templates
      .filter((template) => template.active !== false && (template.meal_key === meal || template.time_relevance === meal))
      .map((template): CatalogueChoice => ({ key: `template:${template.id}`, kind: "template", label: template.name, template })),
    ...foods
      .filter((food) => food.active !== false && Boolean(currentFoodVersion(food)?.id))
      .map((food): CatalogueChoice => ({ key: `food:${food.id}`, kind: "food", label: food.name, food })),
    ...recipes
      .filter((recipe) => recipe.active !== false && Boolean(currentRecipeVersion(recipe)?.id))
      .map((recipe): CatalogueChoice => ({ key: `recipe:${recipe.id}`, kind: "recipe", label: recipe.name, recipe })),
  ];
}

function portionOptionsForChoice(choice: CatalogueChoice): FitnessPortionOption[] {
  if (choice.kind === "food") return foodPortionOptions(choice.food);
  if (choice.kind !== "recipe") return [];
  const version = currentRecipeVersion(choice.recipe);
  const options: FitnessPortionOption[] = [];
  if (version?.finished_weight_g && version.finished_weight_g > 0) {
    options.push({ key: "recipe:g", label: "g", enteredUnit: "g", defaultAmount: 100, canonicalAmount: 100, canonicalUnit: "g", measurementQuality: "estimated" });
  }
  if (version?.servings && version.servings > 0) {
    options.push({ key: "recipe:serving", label: "serving", enteredUnit: "serving", defaultAmount: 1, canonicalAmount: 1, canonicalUnit: "serving", measurementQuality: "standard_serving" });
  }
  return options;
}

function useOnline(): boolean {
  const [online, setOnline] = useState(() => navigator.onLine);
  useEffect(() => {
    const update = () => setOnline(navigator.onLine);
    window.addEventListener("online", update);
    window.addEventListener("offline", update);
    return () => {
      window.removeEventListener("online", update);
      window.removeEventListener("offline", update);
    };
  }, []);
  return online;
}

export function TodayFitnessQuickActions({
  ownerID,
  revision,
  onDataChanged,
  onOpenFullFoodLog,
  now: fixedNow,
}: {
  ownerID: string;
  revision: number;
  onDataChanged: () => void;
  onOpenFullFoodLog: () => void;
  now?: Date;
}) {
  const online = useOnline();
  const [clock, setClock] = useState(() => fixedNow ?? new Date());
  const [preferences, setPreferences] = useState<FitnessQuickEntryPreferences>(() => (
    cachedFitnessQuickEntryPreferences(ownerID) ?? DEFAULT_FITNESS_QUICK_ENTRY_PREFERENCES
  ));
  const [preferencesLoading, setPreferencesLoading] = useState(true);

  useEffect(() => {
    if (fixedNow) {
      setClock(fixedNow);
      return;
    }
    const timer = window.setInterval(() => setClock(new Date()), 60_000);
    return () => window.clearInterval(timer);
  }, [fixedNow]);

  useEffect(() => {
    const applyChange = (event: Event) => {
      const detail = (event as CustomEvent<{ ownerID?: string; value?: unknown }>).detail;
      if (detail?.ownerID === ownerID && validFitnessQuickEntryPreferences(detail.value)) {
        setPreferences(detail.value);
      }
    };
    window.addEventListener(FITNESS_QUICK_ENTRY_PREFERENCES_EVENT, applyChange);
    return () => window.removeEventListener(FITNESS_QUICK_ENTRY_PREFERENCES_EVENT, applyChange);
  }, [ownerID]);

  useEffect(() => {
    let active = true;
    setPreferencesLoading(true);
    void (async () => {
      if (!online) {
        const cached = cachedFitnessQuickEntryPreferences(ownerID);
        if (active) {
          setPreferences(cached ?? DEFAULT_FITNESS_QUICK_ENTRY_PREFERENCES);
          setPreferencesLoading(false);
        }
        return;
      }
      try {
        const loaded = await api<FitnessQuickEntryPreferences>(
          "/fitness/quick-entry-preferences",
          {},
          true,
          false,
        );
        if (!validFitnessQuickEntryPreferences(loaded)) throw new Error("Meal times were returned in an unexpected format.");
        rememberFitnessQuickEntryPreferences(ownerID, loaded);
        if (active) setPreferences(loaded);
      } catch {
        const cached = cachedFitnessQuickEntryPreferences(ownerID);
        if (active) {
          setPreferences(cached ?? DEFAULT_FITNESS_QUICK_ENTRY_PREFERENCES);
        }
      } finally {
        if (active) setPreferencesLoading(false);
      }
    })();
    return () => { active = false; };
  }, [online, ownerID, revision]);

  const meal = mealNearTime(clock, preferences);

  return (
    <>
      {meal && !preferencesLoading ? (
        <TodayMealQuickEntry
          meal={meal}
          now={clock}
          online={online}
          revision={revision}
          onDataChanged={onDataChanged}
          onOpenFullFoodLog={onOpenFullFoodLog}
        />
      ) : meal && preferencesLoading ? (
        <div className="today-quick-card today-quick-card--loading" aria-label="Loading meal shortcut"><SkeletonList rows={2} /></div>
      ) : null}
    </>
  );
}

export function TodayViAvailabilityCard({
  ownerID,
  onDataChanged,
  now: fixedNow,
}: {
  ownerID: string;
  onDataChanged: () => void;
  now?: Date;
}) {
  const online = useOnline();
  const today = localDateValue(fixedNow ?? new Date());
  const [schedule, setSchedule] = useState(() => {
    const cached = cachedFitnessViSchedule(ownerID);
    return {
      ownerID,
      value: cached?.schedule ?? null,
      cachedAt: cached?.cached_at ?? null,
      cached: Boolean(cached),
    };
  });
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [nonce, setNonce] = useState(0);
  const [bookingBusy, setBookingBusy] = useState<string | null>(null);
  const [bookingError, setBookingError] = useState<string | null>(null);
  const [bookingNotice, setBookingNotice] = useState<string | null>(null);
  const bookingIDs = useRef(new Map<string, string>());
  const viSchedule = schedule.ownerID === ownerID ? schedule.value : null;

  useEffect(() => {
    let active = true;
    const cached = cachedFitnessViSchedule(ownerID);
    setSchedule({
      ownerID,
      value: cached?.schedule ?? null,
      cachedAt: cached?.cached_at ?? null,
      cached: Boolean(cached),
    });
    setError(null);
    if (!online) {
      setLoading(false);
      return;
    }
    setLoading(true);
    void api<FitnessViSchedule>(
      `/fitness/vi-schedule?start=${encodeURIComponent(today)}&end=${encodeURIComponent(today)}`,
      {},
      true,
      false,
    )
      .then((response) => {
        if (!validFitnessViSchedule(response)) throw new Error("Vi’s schedule was returned in an unexpected format.");
        const cachedAt = new Date().toISOString();
        rememberFitnessViSchedule(ownerID, response, cachedAt);
        if (active) setSchedule({ ownerID, value: response, cachedAt, cached: false });
      })
      .catch((requestError) => {
        if (active) setError(errorMessage(requestError, "Today’s Vi schedule could not be loaded."));
      })
      .finally(() => { if (active) setLoading(false); });
    return () => { active = false; };
  }, [nonce, online, ownerID, today]);

  if (!viSchedule?.relevant) return null;

  const day = viSchedule.days.find((candidate) => candidate.date === today) ?? null;
  const bookableURL = viSchedule.source_url ?? null;
  const stale = schedule.cached || !online || Boolean(error) || Boolean(viSchedule.unavailable_reason);
  const checked = checkedAtLabel(schedule.cachedAt);

  async function confirmBooked(window: NonNullable<typeof day>["classes"][number]) {
    const key = `${today}:${window.start}:${window.end}:${window.label ?? "class"}`;
    const id = bookingIDs.current.get(key) ?? crypto.randomUUID();
    bookingIDs.current.set(key, id);
    setBookingBusy(key);
    setBookingError(null);
    setBookingNotice(null);
    try {
      const result = await api<{ status: "booked"; title: string; start_time: string }>(
        "/fitness/vi-bookings",
        {
          method: "POST",
          body: JSON.stringify({
            id,
            date: today,
            start: window.start,
            end: window.end,
            label: window.label ?? "Strength class",
            classification: window.classification,
            provider: "vi_training",
            client_id: "hausklar-web",
            client_timestamp: new Date().toISOString(),
          }),
        },
        true,
        false,
      );
      setBookingNotice(`${result.title} added to your calendar at ${window.start}.`);
      onDataChanged();
    } catch (requestError) {
      setBookingError(errorMessage(requestError, "That Vi booking could not be recorded. Your booking with Vi is unchanged."));
    } finally {
      setBookingBusy(null);
    }
  }

  return (
    <section className="today-vi-card" aria-labelledby="today-vi-title">
      <div className="today-vi-card__heading">
        <span className="today-facility-icon"><Dumbbell aria-hidden="true" size={20} /></span>
        <div><small>My Fitness · Vi</small><h2 id="today-vi-title">Classes today</h2><span>{viSchedule.source_title}</span></div>
      </div>
      {!online ? (
        <div className="today-vi-stale" role="status">
          <span>Offline · showing the Vi schedule saved {checked}. Check Vi for current availability.</span>
        </div>
      ) : error ? (
        <div className="today-vi-stale today-vi-stale--error" role="alert">
          <span>Couldn’t refresh Vi. Showing the schedule saved {checked}. Check Vi before booking.</span>
          <button type="button" className="button button--secondary button--compact" disabled={loading} onClick={() => setNonce((value) => value + 1)}>
            <RefreshCw aria-hidden="true" size={15} /> {loading ? "Trying…" : "Try again"}
          </button>
        </div>
      ) : loading && schedule.cached ? (
        <div className="today-vi-stale" role="status"><span>Refreshing Vi · showing the schedule saved {checked}.</span></div>
      ) : viSchedule.unavailable_reason && day?.covered && day.classes.length ? (
        <div className="today-vi-stale" role="status">
          <span>{viSchedule.unavailable_reason} Check Vi before booking.</span>
        </div>
      ) : null}
      {bookingNotice ? <p className="form-success" role="status" aria-live="polite">{bookingNotice}</p> : null}
      {bookingError ? <p className="form-error" role="alert">{bookingError} Press Booked to try again.</p> : null}
      {day?.covered && day.classes.length ? (
        <ul className="today-vi-classes">
          {day.classes.map((window) => {
            const key = `${today}:${window.start}:${window.end}:${window.label ?? "class"}`;
            const url = stale ? bookableURL ?? window.booking_url ?? null : window.booking_url ?? bookableURL;
            return (
              <li key={key}>
                <div><strong>{window.label ?? "Strength class"}</strong><time>{window.start}–{window.end}</time></div>
                <div>
                  {url ? <a className="button button--primary button--compact" href={url} target="_blank" rel="noreferrer"><ExternalLink aria-hidden="true" size={15} /> {stale ? "Check in Vi" : "Book in Vi"}</a> : <span className="today-vi-no-link">Booking link unavailable</span>}
                  <button type="button" className="button button--secondary button--compact" disabled={!online || bookingBusy !== null} aria-busy={bookingBusy === key} onClick={() => void confirmBooked(window)}>{bookingBusy === key ? "Saving…" : "Booked"}</button>
                </div>
              </li>
            );
          })}
        </ul>
      ) : (
        <div className="today-vi-empty">
          <p>{viSchedule.unavailable_reason ?? "No Vi classes are listed for today."}</p>
          {bookableURL ? <a className="button button--secondary button--compact" href={bookableURL} target="_blank" rel="noreferrer">Check Vi schedule <ExternalLink aria-hidden="true" size={15} /></a> : null}
        </div>
      )}
      {!online ? <p className="today-quick-offline">Reconnect before marking a Vi booking as added to the calendar.</p> : null}
    </section>
  );
}

function TodayMealQuickEntry({
  meal,
  now,
  online,
  revision,
  onDataChanged,
  onOpenFullFoodLog,
}: {
  meal: FitnessQuickMeal;
  now: Date;
  online: boolean;
  revision: number;
  onDataChanged: () => void;
  onOpenFullFoodLog: () => void;
}) {
  const today = localDateValue(now);
  const yesterday = localDateValue(offsetDate(now, -1));
  const mealLabel = fitnessQuickMealLabel(meal);
  const [currentEntries, setCurrentEntries] = useState<FitnessFoodLogEntry[]>([]);
  const [yesterdayEntries, setYesterdayEntries] = useState<FitnessFoodLogEntry[]>([]);
  const [loading, setLoading] = useState(true);
  const [loadError, setLoadError] = useState<string | null>(null);
  const [fromCache, setFromCache] = useState(false);
  const [loadNonce, setLoadNonce] = useState(0);
  const [busy, setBusy] = useState(false);
  const [notice, setNotice] = useState<string | null>(null);
  const [actionError, setActionError] = useState<string | null>(null);
  const [fillOpen, setFillOpen] = useState(false);
  const [completed, setCompleted] = useState(false);
  const [seedEntries, setSeedEntries] = useState<FitnessFoodLogEntry[]>([]);

  useEffect(() => {
    let active = true;
    setLoading(true);
    setLoadError(null);
    void (async () => {
      try {
        if (!online) throw new TypeError("Offline");
        const [current, previous, completions] = await Promise.all([
          api<FitnessNutritionDay | Partial<FitnessNutritionDay>>(`/fitness/food-log?date=${encodeURIComponent(today)}`, {}, true, false),
          api<FitnessNutritionDay | Partial<FitnessNutritionDay>>(`/fitness/food-log?date=${encodeURIComponent(yesterday)}`, {}, true, false),
          api<Array<{ meal_key: FitnessQuickMeal }>>(`/fitness/nutrition/meal-completions?date=${encodeURIComponent(today)}`, {}, true, false),
        ]);
        const currentDayEntries = nutritionEntries(current);
        const previousDayEntries = nutritionEntries(previous);
        await cacheFitnessRecords("food_log_entry", [...currentDayEntries, ...previousDayEntries]).catch(() => undefined);
        if (active) {
          setCurrentEntries(currentDayEntries.filter((entry) => entry.meal_key === meal));
          setYesterdayEntries(previousDayEntries.filter((entry) => entry.meal_key === meal));
          setCompleted(completions.some((item) => item.meal_key === meal));
          setFromCache(false);
        }
      } catch (requestError) {
        const cached = await cachedFitnessRecords<FitnessFoodLogEntry>("food_log_entry").catch(() => []);
        if (active) {
          setCurrentEntries(cached.filter((entry) => entryDate(entry) === today && entry.meal_key === meal));
          setYesterdayEntries(cached.filter((entry) => entryDate(entry) === yesterday && entry.meal_key === meal));
          setFromCache(cached.length > 0);
          if (!cached.length && online) setLoadError(errorMessage(requestError, `${mealLabel} could not be checked.`));
        }
      } finally {
        if (active) setLoading(false);
      }
    })();
    return () => { active = false; };
  }, [loadNonce, meal, mealLabel, online, revision, today, yesterday]);

  const saveInputs = useCallback(async (payloads: Array<Record<string, unknown>>, label: string) => {
    setBusy(true);
    setNotice(null);
    setActionError(null);
    try {
      const saved = await saveFitnessRecords(payloads.map((payload) => ({ entityType: "food_log_entry", payload })));
      let synced = false;
      if (online) {
        try {
          await flushFitnessSync();
          synced = true;
        } catch {
          // The local outbox remains authoritative until the next reconnect.
        }
      }
      setCurrentEntries((entries) => [...entries, ...saved as unknown as FitnessFoodLogEntry[]]);
      setNotice(synced ? `${label} added to ${mealLabel.toLocaleLowerCase()}.` : `${label} saved on this device and will sync.`);
      onDataChanged();
      return true;
    } catch (requestError) {
      setActionError(errorMessage(requestError, `${mealLabel} could not be saved.`));
      return false;
    } finally {
      setBusy(false);
    }
  }, [mealLabel, onDataChanged, online]);

  async function completeMeal() {
    setBusy(true);
    setActionError(null);
    try {
      await api("/fitness/nutrition/meal-completions", {
        method: "POST",
        body: JSON.stringify({
          id: crypto.randomUUID(),
          nutrition_date: today,
          meal_key: meal,
        }),
      });
      setCompleted(true);
      setFillOpen(false);
      onDataChanged();
      return true;
    } catch (requestError) {
      setActionError(errorMessage(requestError, `${mealLabel} could not be completed.`));
      return false;
    } finally {
      setBusy(false);
    }
  }

  if (completed) return null;

  return (
    <section className="module-action-card today-quick-card today-meal-quick" aria-labelledby={`today-quick-${meal}`}>
      <div className="today-quick-card__heading">
        <span className="today-money-icon"><Utensils aria-hidden="true" size={20} /></span>
        <div>
          <span>My Fitness · {preferencesTimeCopy(mealLabel)}</span>
          <h2 id={`today-quick-${meal}`}>{currentEntries.length ? `${mealLabel} started` : `Fill in ${mealLabel.toLocaleLowerCase()}`}</h2>
          <p>{currentEntries.length ? `${currentEntries.length} ${currentEntries.length === 1 ? "item" : "items"} logged so far.` : "Use what you had yesterday, or add a saved food or meal."}</p>
        </div>
      </div>
      {loading ? <div className="today-quick-inline-state"><SkeletonList rows={2} /></div> : null}
      {!loading && loadError ? (
        <div className="today-quick-inline-state is-error" role="alert">
          <span>{loadError}</span>
          <button type="button" className="button button--secondary button--compact" onClick={() => setLoadNonce((value) => value + 1)}><RefreshCw aria-hidden="true" size={15} /> Try again</button>
        </div>
      ) : null}
      {!loading && !loadError && yesterdayEntries.length ? (
        <p className="today-quick-context"><strong>Yesterday:</strong> {yesterdaySummary(yesterdayEntries)}</p>
      ) : !loading && !loadError ? <p className="today-quick-context">Nothing was logged for yesterday’s {mealLabel.toLocaleLowerCase()}.</p> : null}
      {fromCache ? <p className="today-quick-offline">Using the meal history saved on this device.</p> : null}
      {notice ? <p className="form-success" role="status" aria-live="polite"><CheckCircle2 aria-hidden="true" size={16} /> {notice}</p> : null}
      {actionError ? <p className="form-error" role="alert">{actionError}</p> : null}
      <div className="today-quick-card__actions">
        <button type="button" className="button button--secondary" disabled={busy || !yesterdayEntries.length} onClick={() => { setSeedEntries(yesterdayEntries); setFillOpen(true); }}>
          <Copy aria-hidden="true" size={16} /> Use yesterday’s {mealLabel.toLocaleLowerCase()}
        </button>
        <button type="button" className="button button--primary" disabled={busy} onClick={() => { setActionError(null); setSeedEntries([]); setFillOpen(true); }}>{currentEntries.length ? "Add more food" : "Add food"}</button>
      </div>
      <MealFillDialog
        open={fillOpen}
        onOpenChange={setFillOpen}
        meal={meal}
        today={today}
        now={now}
        online={online}
        currentEntryCount={currentEntries.length}
        seedEntries={seedEntries}
        onSave={saveInputs}
        onComplete={completeMeal}
        onOpenFullFoodLog={() => { setFillOpen(false); onOpenFullFoodLog(); }}
      />
    </section>
  );
}

function preferencesTimeCopy(mealLabel: string): string {
  return `${mealLabel} time`;
}

function MealFillDialog({
  open,
  onOpenChange,
  meal,
  today,
  now,
  online,
  currentEntryCount,
  seedEntries,
  onSave,
  onComplete,
  onOpenFullFoodLog,
}: {
  open: boolean;
  onOpenChange: (open: boolean) => void;
  meal: FitnessQuickMeal;
  today: string;
  now: Date;
  online: boolean;
  currentEntryCount: number;
  seedEntries: FitnessFoodLogEntry[];
  onSave: (payloads: Array<Record<string, unknown>>, label: string) => Promise<boolean>;
  onComplete: () => Promise<boolean>;
  onOpenFullFoodLog: () => void;
}) {
  const mealLabel = fitnessQuickMealLabel(meal);
  const [foods, setFoods] = useState<FitnessFood[]>([]);
  const [recipes, setRecipes] = useState<FitnessRecipe[]>([]);
  const [templates, setTemplates] = useState<FitnessMealTemplate[]>([]);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [nonce, setNonce] = useState(0);
  const [query, setQuery] = useState("");
  const [source, setSource] = useState("");
  const [externalSelection, setExternalSelection] = useState<FitnessFoodBarcodeLookup | null>(null);
  const [lookupResults, setLookupResults] = useState<FitnessFoodBarcodeLookup[]>([]);
  const [lookupBusy, setLookupBusy] = useState(false);
  const [amount, setAmount] = useState("");
  const [unitKey, setUnitKey] = useState("");
  const [drafts, setDrafts] = useState<MealDraftItem[]>([]);
  const [logsSaved, setLogsSaved] = useState(false);
  const [saving, setSaving] = useState(false);
  const [validationError, setValidationError] = useState<string | null>(null);
  const [notice, setNotice] = useState<string | null>(null);
  const seededRef = useRef(false);

  useEffect(() => {
    if (!open) return;
    let active = true;
    setLoading(true);
    setError(null);
    setQuery("");
    setSource("");
    setExternalSelection(null);
    setLookupResults([]);
    setAmount("");
    setUnitKey("");
    setDrafts([]);
    setLogsSaved(false);
    setValidationError(null);
    setNotice(null);
    seededRef.current = false;
    void (async () => {
      try {
        if (!online) throw new TypeError("Offline");
        const [nextFoods, nextRecipes, nextTemplates] = await Promise.all([
          api<FitnessFood[]>("/fitness/foods", {}, true, false),
          api<FitnessRecipe[]>("/fitness/recipes", {}, true, false),
          api<FitnessMealTemplate[]>("/fitness/meal-templates", {}, true, false),
        ]);
        await Promise.all([
          cacheFitnessRecords("food", nextFoods),
          cacheFitnessRecords("recipe", nextRecipes),
          cacheFitnessRecords("meal_template", nextTemplates),
        ]).catch(() => undefined);
        if (active) {
          setFoods(nextFoods);
          setRecipes(nextRecipes);
          setTemplates(nextTemplates);
        }
      } catch (requestError) {
        const [nextFoods, nextRecipes, nextTemplates] = await Promise.all([
          cachedFitnessRecords<FitnessFood>("food").catch(() => []),
          cachedFitnessRecords<FitnessRecipe>("recipe").catch(() => []),
          cachedFitnessRecords<FitnessMealTemplate>("meal_template").catch(() => []),
        ]);
        if (active) {
          setFoods(nextFoods);
          setRecipes(nextRecipes);
          setTemplates(nextTemplates);
          if (!nextFoods.length && !nextRecipes.length && !nextTemplates.length) {
            setError(online
              ? errorMessage(requestError, "Saved foods and meals could not be loaded.")
              : "No saved foods or meals are available on this device yet.");
          }
        }
      } finally {
        if (active) setLoading(false);
      }
    })();
    return () => { active = false; };
  }, [nonce, online, open]);

  const choices = useMemo(() => catalogueChoices(foods, recipes, templates, meal), [foods, meal, recipes, templates]);
  const selected = choices.find((choice) => choice.key === source) ?? null;
  const unitOptions = useMemo((): FitnessPortionOption[] => {
    if (externalSelection) {
      const base: FitnessPortionOption = {
        key: "lookup:base",
        label: externalSelection.reference_unit,
        enteredUnit: externalSelection.reference_unit,
        defaultAmount: externalSelection.reference_amount,
        canonicalAmount: externalSelection.reference_amount,
        canonicalUnit: externalSelection.reference_unit,
        measurementQuality: "estimated",
      };
      const serving = externalSelection.serving;
      return serving ? [base, {
        key: "lookup:serving",
        label: serving.name,
        enteredUnit: serving.unit,
        defaultAmount: serving.amount,
        canonicalAmount: serving.amount,
        canonicalUnit: externalSelection.reference_unit,
        measurementQuality: "standard_serving",
      }] : [base];
    }
    return selected ? portionOptionsForChoice(selected) : [];
  }, [externalSelection, selected]);
  const selectedUnit = unitOptions.find((option) => option.key === unitKey) ?? null;
  const matchingChoices = useMemo(() => {
    const value = query.trim().toLocaleLowerCase();
    if (!value) return [];
    return choices.filter((choice) => choice.label.toLocaleLowerCase().includes(value)).slice(0, 8);
  }, [choices, query]);

  useEffect(() => {
    if (!open || loading || seededRef.current || !seedEntries.length || !choices.length) return;
    const seeded = seedEntries.flatMap((entry): MealDraftItem[] => {
      const choice = choices.find((candidate) => candidate.kind !== "template" && (
        candidate.kind === "food"
          ? currentFoodVersion(candidate.food)?.id === entry.food_version_id
          : currentRecipeVersion(candidate.recipe)?.id === entry.recipe_version_id
      ));
      if (!choice || choice.kind === "template") return [];
      const available = portionOptionsForChoice(choice);
      const existing = available.find((option) => option.enteredUnit === entry.entered_unit);
      const option: FitnessPortionOption = existing ?? {
        key: `history:${entry.id}`,
        label: entry.entered_unit,
        enteredUnit: entry.entered_unit,
        defaultAmount: entry.entered_amount,
        canonicalAmount: entry.canonical_amount,
        canonicalUnit: entry.canonical_unit,
        measurementQuality: validMeasurementQuality(entry.measurement_quality),
      };
      return [{
        id: crypto.randomUUID(),
        label: entryLabel(entry) ?? choice.label,
        foodVersionId: entry.food_version_id ?? null,
        recipeVersionId: entry.recipe_version_id ?? null,
        amount: String(entry.entered_amount),
        unitKey: option.key,
        units: existing ? available : [option, ...available],
      }];
    });
    setDrafts(seeded);
    if (seeded.length !== seedEntries.length) {
      setValidationError("Some foods from yesterday are no longer available. Review the items below before completing the meal.");
    }
    seededRef.current = true;
  }, [choices, loading, open, seedEntries]);

  function chooseSource(value: string) {
    setSource(value);
    setExternalSelection(null);
    setValidationError(null);
    setNotice(null);
    const choice = choices.find((item) => item.key === value);
    if (!choice || choice.kind === "template") {
      setAmount("");
      setUnitKey("");
      return;
    }
    const options = portionOptionsForChoice(choice);
    const portion = choice.kind === "food" ? defaultFoodPortion(choice.food) : null;
    const option = portion?.option ?? options[0];
    setUnitKey(option?.key ?? "");
    setAmount(String(portion?.amount ?? option?.defaultAmount ?? ""));
  }

  function chooseUnit(key: string) {
    const option = unitOptions.find((candidate) => candidate.key === key);
    setUnitKey(key);
    if (option) setAmount(String(option.defaultAmount));
    setValidationError(null);
  }

  function resetSearch() {
    setQuery("");
    setSource("");
    setExternalSelection(null);
    setLookupResults([]);
    setAmount("");
    setUnitKey("");
  }

  async function lookUpFood() {
    const value = query.trim();
    if (value.length < 2 || lookupBusy) return;
    setLookupBusy(true);
    setValidationError(null);
    setLookupResults([]);
    try {
      const results = await api<FitnessFoodBarcodeLookup[]>(
        `/fitness/food-lookup/search?q=${encodeURIComponent(value)}`,
        {},
        true,
        false,
      );
      setLookupResults(results);
      if (!results.length) setValidationError(`No packaged foods matched “${value}”. You can add it manually.`);
    } catch (requestError) {
      setValidationError(errorMessage(requestError, "Food lookup is unavailable."));
    } finally {
      setLookupBusy(false);
    }
  }

  function chooseLookup(result: FitnessFoodBarcodeLookup) {
    setSource("");
    setExternalSelection(result);
    setAmount(String(result.reference_amount));
    setUnitKey("lookup:base");
    setValidationError(null);
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

  async function addSelected(event?: React.FormEvent<HTMLFormElement>) {
    event?.preventDefault();
    if (!selected && !externalSelection) {
      setValidationError("Search for a food first.");
      return;
    }
    if (selected?.kind === "template") {
      const items = selected.template.items.map((item): MealDraftItem => {
        const option: FitnessPortionOption = {
          key: `template:${selected.template.id}:${item.id}`,
          label: item.unit,
          enteredUnit: item.unit,
          defaultAmount: item.amount,
          canonicalAmount: item.canonical_amount,
          canonicalUnit: item.canonical_unit,
          measurementQuality: validMeasurementQuality(item.measurement_quality),
        };
        return {
          id: crypto.randomUUID(), label: item.label ?? selected.label,
          foodVersionId: item.food_version_id ?? null,
          recipeVersionId: item.recipe_version_id ?? null,
          amount: String(item.amount), unitKey: option.key, units: [option],
        };
      });
      setDrafts((current) => [...current, ...items]);
      setNotice(`${selected.label} added. You can adjust each amount before completing.`);
      resetSearch();
      return;
    }
    const enteredAmount = Number(amount);
    if (!Number.isFinite(enteredAmount) || enteredAmount <= 0 || !selectedUnit) {
      setValidationError("Enter an amount and choose a unit.");
      return;
    }
    setSaving(true);
    try {
      let foodVersionId: string | null = null;
      let recipeVersionId: string | null = null;
      let label = externalSelection?.name ?? selected?.label ?? "Food";
      if (externalSelection) {
        const created = await createLookupFood(externalSelection);
        const version = currentFoodVersion(created);
        if (!version?.id) throw new Error("The looked-up food was saved without usable nutrition details.");
        foodVersionId = version.id;
        label = created.name;
        setFoods((current) => [...current, created]);
      } else if (selected?.kind === "food") {
        foodVersionId = currentFoodVersion(selected.food)?.id ?? null;
      } else if (selected?.kind === "recipe") {
        recipeVersionId = currentRecipeVersion(selected.recipe)?.id ?? null;
      }
      if (!foodVersionId && !recipeVersionId) throw new Error("That food has no usable nutrition details.");
      setDrafts((current) => [...current, {
        id: crypto.randomUUID(), label, foodVersionId, recipeVersionId,
        amount: String(enteredAmount), unitKey: selectedUnit.key, units: unitOptions,
      }]);
      setNotice(`${label} added. Search for another food or complete the meal.`);
      resetSearch();
    } catch (requestError) {
      setValidationError(errorMessage(requestError, "That food could not be added."));
    } finally {
      setSaving(false);
    }
  }

  function updateDraft(id: string, changes: Partial<MealDraftItem>) {
    setDrafts((current) => current.map((item) => item.id === id ? { ...item, ...changes } : item));
  }

  async function complete() {
    setSaving(true);
    setValidationError(null);
    const loggedAt = new Date(now);
    const localInput = `${today}T${String(loggedAt.getHours()).padStart(2, "0")}:${String(loggedAt.getMinutes()).padStart(2, "0")}`;
    try {
      const payloads = drafts.map((draft) => {
        const value = Number(draft.amount);
        const option = draft.units.find((candidate) => candidate.key === draft.unitKey);
        if (!Number.isFinite(value) || value <= 0 || !option) throw new Error(`Check the amount for ${draft.label}.`);
        const canonical = canonicalPortion(option, value);
        return {
          food_version_id: draft.foodVersionId,
          recipe_version_id: draft.recipeVersionId,
          logged_at_utc: new Date(localInput).toISOString(),
          local_timezone: localTimeZone(), nutrition_date: today, meal_key: meal,
          entered_amount: value, entered_unit: option.enteredUnit,
          canonical_amount: canonical.amount, canonical_unit: canonical.unit,
          measurement_quality: canonical.quality, notes: null, context_tags: [],
        };
      });
      if (payloads.length && !logsSaved) {
        if (!await onSave(payloads, mealLabel)) return;
        setLogsSaved(true);
      }
      if (!await onComplete()) return;
      onOpenChange(false);
    } catch (requestError) {
      setValidationError(errorMessage(requestError, `${mealLabel} could not be completed.`));
    } finally {
      setSaving(false);
    }
  }

  return (
    <Modal
      open={open}
      onOpenChange={(nextOpen) => { if (!saving) onOpenChange(nextOpen); }}
      title={`Add ${mealLabel.toLocaleLowerCase()} foods`}
      description="Search your saved foods first. Add as many as you need, adjust the amounts, then complete the meal."
    >
      {loading ? <SkeletonList rows={4} /> : null}
      {!loading && error ? (
        <div className="today-quick-dialog-state is-error" role="alert">
          <strong>Saved items aren’t available</strong>
          <p>{error}</p>
          <div className="today-quick-card__actions">
            {online ? <button type="button" className="button button--secondary" onClick={() => setNonce((value) => value + 1)}><RefreshCw aria-hidden="true" size={16} /> Try again</button> : null}
            <button type="button" className="button button--secondary" onClick={onOpenFullFoodLog}>Add a food manually</button>
          </div>
        </div>
      ) : null}
      {!loading && !error ? (
        <div className="today-quick-form" aria-busy={saving}>
          {drafts.length ? <div className="today-meal-drafts"><h3>Foods in this meal</h3>{drafts.map((draft) => <div className="today-meal-draft" key={draft.id}><strong>{draft.label}</strong><label>Amount<input type="text" inputMode="decimal" disabled={logsSaved} value={draft.amount} onChange={(event) => updateDraft(draft.id, { amount: event.target.value })} /></label><label>Unit<select value={draft.unitKey} disabled={logsSaved} onChange={(event) => { const option = draft.units.find((candidate) => candidate.key === event.target.value); updateDraft(draft.id, { unitKey: event.target.value, ...(option ? { amount: String(option.defaultAmount) } : {}) }); }}>{draft.units.map((option) => <option value={option.key} key={option.key}>{option.label}</option>)}</select></label><button type="button" className="button button--secondary button--compact" disabled={logsSaved} aria-label={`Remove ${draft.label}`} onClick={() => setDrafts((current) => current.filter((item) => item.id !== draft.id))}>Remove</button></div>)}</div> : currentEntryCount ? <p className="today-quick-context">{currentEntryCount} saved {currentEntryCount === 1 ? "food is" : "foods are"} already in this meal. Add more or complete it.</p> : null}
          {logsSaved ? <p className="form-success" role="status">The foods are saved. Finish completing the meal below.</p> : null}
          {notice ? <p className="form-success" role="status">{notice}</p> : null}
          {!logsSaved ? <><div className="field">
            <label htmlFor={`today-${meal}-search`}>Search foods</label>
            <input id={`today-${meal}-search`} type="search" autoComplete="off" value={query} placeholder="e.g. porridge or yoghurt" onChange={(event) => { setQuery(event.target.value); setSource(""); setExternalSelection(null); setLookupResults([]); setValidationError(null); }} />
          </div>
          {query.trim() && !selected && !externalSelection ? <div className="today-food-search-results">{matchingChoices.map((choice) => <button type="button" key={choice.key} onClick={() => chooseSource(choice.key)}><strong>{choice.label}</strong><span>{choice.kind === "template" ? "Saved meal" : choice.kind === "recipe" ? "Recipe" : "Saved food"}</span></button>)}{!matchingChoices.length ? <button type="button" className="button button--secondary" disabled={!online || lookupBusy || query.trim().length < 2} onClick={() => void lookUpFood()}>{lookupBusy ? "Looking up…" : `Look up “${query.trim()}”`}</button> : null}{lookupResults.map((result) => <button type="button" key={result.barcode} onClick={() => chooseLookup(result)}><strong>{result.name}</strong><span>{[result.brand, "Open Food Facts"].filter(Boolean).join(" · ")}</span></button>)}{!matchingChoices.length && !lookupResults.length ? <button type="button" className="button button--secondary" onClick={onOpenFullFoodLog}>Add it manually</button> : null}</div> : null}
          {((selected && selected.kind !== "template") || externalSelection) ? (
            <form className="today-food-amount" onSubmit={(event) => void addSelected(event)}>
              <div className="today-selected-food"><strong>{externalSelection?.name ?? selected?.label}</strong><button type="button" className="button button--secondary button--compact" onClick={resetSearch}>Change</button></div>
              <div className="field">
                <label htmlFor={`today-${meal}-amount`}>Amount</label>
                <input id={`today-${meal}-amount`} type="text" inputMode="decimal" autoComplete="off" value={amount} required aria-invalid={validationError ? "true" : undefined} aria-describedby={validationError ? `today-${meal}-error` : undefined} onChange={(event) => { setAmount(event.target.value); setValidationError(null); }} />
              </div>
              <div className="field">
                <label htmlFor={`today-${meal}-unit`}>Unit</label>
                <select id={`today-${meal}-unit`} value={unitKey} required onChange={(event) => chooseUnit(event.target.value)}>
                  <option value="">Choose a unit</option>
                  {unitOptions.map((option) => <option value={option.key} key={option.key}>{option.label}</option>)}
                </select>
              </div>
              {externalSelection?.warnings.length ? <p className="today-quick-context">{externalSelection.warnings.join(" ")}</p> : null}
              <button type="submit" className="button button--primary" disabled={saving || !selectedUnit}>{saving ? "Adding…" : "Add food"}</button>
            </form>
          ) : null}
          {selected?.kind === "template" ? <button type="button" className="button button--primary" onClick={() => void addSelected()}>Add saved meal</button> : null}</> : null}
          {validationError ? <p id={`today-${meal}-error`} className="form-error" role="alert">{validationError}</p> : null}
          <div className="dialog-actions">
            <button type="button" className="button button--secondary" disabled={saving} onClick={() => onOpenChange(false)}>Cancel</button>
            <button type="button" className="button button--primary" disabled={saving || (!drafts.length && currentEntryCount === 0)} aria-busy={saving} onClick={() => void complete()}>{saving ? "Saving…" : "Complete meal"}</button>
          </div>
        </div>
      ) : null}
    </Modal>
  );
}

export function TodayExerciseQuickAction({
  now,
  online,
  onDataChanged,
}: {
  now: Date;
  online: boolean;
  onDataChanged: () => void;
}) {
  const today = localDateValue(now);
  const [kind, setKind] = useState<ExerciseKind>("running");
  const [startTime, setStartTime] = useState(() => roundedCurrentTime(now));
  const [availability, setAvailability] = useState<FitnessStrengthAvailability | null>(null);
  const [availabilityLoading, setAvailabilityLoading] = useState(false);
  const [availabilityError, setAvailabilityError] = useState<string | null>(null);
  const [availabilityNonce, setAvailabilityNonce] = useState(0);
  const [saving, setSaving] = useState(false);
  const [saved, setSaved] = useState<string | null>(null);
  const [saveError, setSaveError] = useState<string | null>(null);

  useEffect(() => {
    if (kind !== "strength") return;
    let active = true;
    setAvailability(null);
    setAvailabilityError(null);
    if (!online) {
      setAvailabilityLoading(false);
      setAvailabilityError("Connect to check today’s strength availability. You can still choose a start time.");
      return;
    }
    setAvailabilityLoading(true);
    void api<FitnessStrengthAvailability>(
      `/fitness/strength-availability?start=${encodeURIComponent(today)}&end=${encodeURIComponent(today)}`,
      {},
      true,
      false,
    )
      .then((response) => {
        if (!validStrengthAvailability(response)) throw new Error("Strength availability was returned in an unexpected format.");
        if (active) setAvailability(response);
      })
      .catch((requestError) => {
        if (active) setAvailabilityError(errorMessage(requestError, "Today’s strength availability could not be loaded. You can still choose a start time."));
      })
      .finally(() => { if (active) setAvailabilityLoading(false); });
    return () => { active = false; };
  }, [availabilityNonce, kind, online, today]);

  const dayAvailability = availability?.days.find((day) => day.date === today) ?? null;

  async function submit(event: React.FormEvent<HTMLFormElement>) {
    event.preventDefault();
    setSaving(true);
    setSaveError(null);
    setSaved(null);
    const start = new Date(`${today}T${startTime}`);
    if (Number.isNaN(start.getTime())) {
      setSaveError("Choose a valid start time.");
      setSaving(false);
      return;
    }
    const label = kind === "running" ? "Run" : "Strength";
    try {
      await saveFitnessRecords([{
        entityType: "planned_session",
        payload: {
          sport_key: kind,
          title: label,
          local_timezone: localTimeZone(),
          status: "accepted",
          session_source: "user",
          scheduled_start_utc: start.toISOString(),
          scheduled_date: today,
          time_window_start_utc: null,
          time_window_end_utc: null,
          expected_duration_s: null,
          expected_distance_m: null,
          expected_pace_s_per_km: null,
          priority: 1,
          movable: false,
          visibility: "private",
          shared_title: null,
          reason_for_placement: "Added from Today",
          goal_links: [],
          exercise_items: [],
          intended_gear_ids: [],
        },
      }]);
      let synced = false;
      if (online) {
        try {
          await flushFitnessSync();
          synced = true;
        } catch {
          // The local outbox will retry without losing this quick entry.
        }
      }
      setSaved(synced ? `${label} added for ${startTime}.` : `${label} saved on this device for ${startTime} and will sync.`);
      onDataChanged();
    } catch (requestError) {
      setSaveError(errorMessage(requestError, `${label} could not be added.`));
    } finally {
      setSaving(false);
    }
  }

  return (
    <section className="module-action-card today-quick-card today-exercise-quick" aria-labelledby="today-add-exercise-title">
      <div className="today-quick-card__heading">
        <span className="today-money-icon"><Activity aria-hidden="true" size={20} /></span>
        <div>
          <span>My Fitness · Today</span>
          <h2 id="today-add-exercise-title">Add exercise</h2>
          <p>Plan a run or strength session for later today.</p>
        </div>
      </div>
      {saved ? (
        <div className="today-quick-success" role="status" aria-live="polite">
          <CheckCircle2 aria-hidden="true" size={20} />
          <span><strong>{saved}</strong><small>It is in your private Fitness plan.</small></span>
          <button type="button" className="button button--secondary button--compact" onClick={() => setSaved(null)}>Add another</button>
        </div>
      ) : (
        <form className="today-exercise-form" aria-busy={saving} onSubmit={(event) => void submit(event)}>
          <fieldset className="today-exercise-kind">
            <legend>Activity</legend>
            <div role="group" aria-label="Exercise type">
              <button type="button" className={cn(kind === "running" && "is-active")} aria-pressed={kind === "running"} onClick={() => setKind("running")}><Activity aria-hidden="true" size={17} /> Run</button>
              <button type="button" className={cn(kind === "strength" && "is-active")} aria-pressed={kind === "strength"} onClick={() => setKind("strength")}><Dumbbell aria-hidden="true" size={17} /> Strength</button>
            </div>
          </fieldset>
          <div className="field today-exercise-start">
            <label htmlFor="today-exercise-start">Start time</label>
            <span><Clock3 aria-hidden="true" size={17} /><input id="today-exercise-start" type="time" required value={startTime} onChange={(event) => setStartTime(event.target.value)} /></span>
          </div>
          {kind === "strength" ? (
            <div className="today-strength-availability" aria-live="polite">
              {availabilityLoading ? <div aria-label="Loading strength availability"><SkeletonList rows={2} /></div> : null}
              {!availabilityLoading && dayAvailability?.covered && dayAvailability.windows.length ? (
                <>
                  <div className="today-strength-availability__heading"><strong>{availability?.source_title}</strong>{availability?.source_url ? <a href={availability.source_url} target="_blank" rel="noreferrer">View source <ExternalLink aria-hidden="true" size={14} /></a> : null}</div>
                  <p>Today’s available windows</p>
                  <div className="today-strength-windows">
                    {dayAvailability.windows.map((window) => (
                      <button type="button" className={cn(startTime === window.start && "is-selected")} aria-pressed={startTime === window.start} onClick={() => setStartTime(window.start)} key={`${window.start}-${window.end}`}>
                        <strong>{window.start}–{window.end}</strong>{window.label ? <small>{window.label}</small> : null}
                      </button>
                    ))}
                  </div>
                </>
              ) : null}
              {!availabilityLoading && (!dayAvailability?.covered || !dayAvailability.windows.length) ? (
                <div className="today-strength-unavailable">
                  <span>{availability?.unavailable_reason ?? availabilityError ?? "No owner-specific strength timetable covers today yet."}</span>
                  {availability?.source_url ? <a href={availability.source_url} target="_blank" rel="noreferrer">Check {availability.source_title} <ExternalLink aria-hidden="true" size={14} /></a> : null}
                  {online && availabilityError ? <button type="button" className="button button--secondary button--compact" onClick={() => setAvailabilityNonce((value) => value + 1)}><RefreshCw aria-hidden="true" size={15} /> Try again</button> : null}
                  <small>You can still use your own start time.</small>
                </div>
              ) : null}
            </div>
          ) : null}
          {saveError ? <p className="form-error" role="alert">{saveError}</p> : null}
          <button type="submit" className="button button--primary today-exercise-submit" disabled={saving} aria-busy={saving}>{saving ? "Adding…" : `Add ${kind === "running" ? "run" : "strength"}`}</button>
        </form>
      )}
    </section>
  );
}
